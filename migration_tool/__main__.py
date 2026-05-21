"""Console entry point for the SageMaker Migration Tool.

Wires the orchestrator end-to-end so ``python -m migration_tool`` runs the
CLI: parse arguments, load (or first-run prompt) configuration, resolve the
step subset, dispatch the :class:`StepRunner`, and print the end-of-run
summary.

Behavior summary (matching the task contract):

1. Parse args via :func:`migration_tool.cli.parse_args`. On
   :class:`ValidationError`, print to stderr and exit with code 2.
2. Build a :class:`ConfigLoader` for ``./config/migration.config.json``.
3. Honour ``--reconfigure`` by calling :meth:`ConfigLoader.reconfigure`.
4. Apply ``--set`` overrides via :meth:`ConfigLoader.set` (literal string
   values; coercion happens in the runner / step scripts).
5. If the on-disk Config_File is empty, run :meth:`Prompter.prompt_first_run`.
6. Resolve the step subset from ``--step`` / ``--from`` / ``--to`` (or default
   to :data:`CANONICAL_STEP_IDS`); apply the Step 8 gate (drop unless
   ``--convert-dags`` is set, with a stdout notice).
7. Open a :class:`RunLogger` (``dry_run`` defaults to true unless ``--apply``).
8. Build a :class:`StateManager` for ``./state/migration.state.json``.
9. Build a :class:`StepRunner` rooted at the current working directory.
10. Apply ``--reset`` semantics, then drive a mid-run prompt loop that
    catches :class:`ConfigError` and retries (capped at 5 attempts).
    :class:`ValidationError` exits 2; :class:`StepError` exits 1;
    :class:`KeyboardInterrupt` exits 130.
11. On success, reload state + config and print
    :func:`migration_tool.reports.render_summary` to stdout.
12. Exit code 0 on success.

Validates: Requirements 2.1, 2.2, 2.3, 2.6, 4.1, 4.4.
"""

from __future__ import annotations

import os
import pathlib
import sys
from typing import Optional

from migration_tool.cli import parse_args
from migration_tool.config import ConfigLoader
from migration_tool.errors import ConfigError, StepError, ValidationError
from migration_tool.logger import RunLogger
from migration_tool.prompts import Prompter
from migration_tool.reports import render_summary
from migration_tool.runner import StepRunner
from migration_tool.state import StateManager
from migration_tool.steps_registry import CANONICAL_STEP_IDS, range_expand


# Canonical on-disk paths the CLI uses by default. Hoisted here so
# tests and integration harnesses can import them without re-deriving
# the strings.
_CONFIG_PATH = pathlib.Path("config/migration.config.json")
_STATE_PATH = pathlib.Path("state/migration.state.json")

# The canonical Step 8 ID, gated behind ``--convert-dags``.
_STEP_8_ID = "08_dag-yaml"

# The canonical Step 9 ID, gated behind ``--push-cicd``. Step 9
# generates the CI/CD pipeline file and (for non-CodeCommit providers)
# tries to ``git push`` to the configured repo. Pushing to GitHub /
# GitLab / Bitbucket needs local Git credentials (PAT, SSH key,
# ``gh auth``) — AWS CodeConnections does not authenticate local
# pushes. We make 09 opt-in for 3P providers so a default
# ``./scripts/migrate.sh run --apply`` doesn't fail at the last
# step on operators who don't have local Git auth set up.
_STEP_9_ID = "09_cicd"

# Cap on mid-run prompt retries. After this many ConfigError-driven
# retries in a row, the orchestrator gives up and exits non-zero.
_MAX_PROMPT_RETRIES = 5


def _print_err(message: str) -> None:
    """Write ``message`` to stderr with a trailing newline."""

    print(message, file=sys.stderr)


def _resolve_subset(args) -> list[str]:
    """Resolve the ordered step subset from the parsed CLI args.

    Returns the list the runner should execute, after the Step 8 gate has
    been applied. Raises :class:`ValidationError` (re-wrapped from any
    :class:`ValueError` produced by ``range_expand``) so the caller can
    treat unknown step IDs uniformly with other CLI validation failures.
    """

    if args.step is not None:
        subset: list[str] = [args.step]
    elif args.from_id is not None or args.to_id is not None:
        try:
            subset = range_expand(args.from_id, args.to_id, None)
        except ValueError as exc:
            raise ValidationError(
                str(exc),
                context={"from_id": args.from_id, "to_id": args.to_id},
            ) from exc
    else:
        subset = list(CANONICAL_STEP_IDS)

    # Step 8 gate: drop ``08_dag-yaml`` unless --convert-dags was passed.
    if _STEP_8_ID in subset and not args.convert_dags:
        subset = [step_id for step_id in subset if step_id != _STEP_8_ID]
        print(
            f"Note: Step {_STEP_8_ID} was skipped. "
            "Pass --convert-dags to include it."
        )

    # Step 9 gate: drop ``09_cicd`` unless --push-cicd was passed.
    # See the comment on _STEP_9_ID for why.
    if _STEP_9_ID in subset and not args.push_cicd:
        subset = [step_id for step_id in subset if step_id != _STEP_9_ID]
        print(
            f"Note: Step {_STEP_9_ID} was skipped. "
            "Pass --push-cicd to include it (requires local Git credentials "
            "for 3P providers — see README 'Step 9 prerequisites')."
        )

    return subset


def _is_empty_config(data: dict) -> bool:
    """Return True iff ``data`` represents an empty Config_File.

    Treats both ``{}`` and a dict whose every value is null/empty
    (``None``, ``""``, ``[]``) as empty per the task contract
    ("load returns {} OR all keys missing").
    """

    if not data:
        return True
    return all(value is None or value == "" or value == [] for value in data.values())


def main(argv: Optional[list[str]] = None) -> int:
    """Run the orchestrator end-to-end and return the process exit code."""

    if argv is None:
        argv = sys.argv[1:]

    # 1. Parse CLI args.
    try:
        args = parse_args(argv)
    except ValidationError as exc:
        _print_err(f"error: {exc}")
        return 2

    # 2. Build the ConfigLoader.
    config = ConfigLoader(_CONFIG_PATH)

    # 3. Reconfigure (idempotent if missing).
    if args.reconfigure:
        config.reconfigure()

    # 4. Apply --set overrides.
    #
    # Most values are literal strings. For schema fields whose type is
    # an array (e.g. source_s3_inclusion_list), the operator can pass
    # either a JSON array (e.g. '["a","b"]') or a comma-separated list
    # (e.g. 'a,b'). We try JSON first; on failure, fall back to
    # comma-split when the schema for the key declares it as an array.
    import json as _json  # local import to avoid widening the module surface
    from migration_tool.config import SCHEMA as _SCHEMA

    for key, value in args.set_overrides:
        coerced: object = value
        prop_schema = (_SCHEMA.get("properties") or {}).get(key) or {}
        prop_type = prop_schema.get("type")
        is_array = prop_type == "array" or (
            isinstance(prop_type, list) and "array" in prop_type
        )

        if is_array:
            # Try JSON first.
            decoded = None
            try:
                decoded = _json.loads(value)
            except (ValueError, TypeError):
                decoded = None
            if isinstance(decoded, list):
                coerced = decoded
            elif "," in value:
                coerced = [part.strip() for part in value.split(",") if part.strip()]
            else:
                coerced = [value] if value else []
        try:
            config.set(key, coerced)
        except ConfigError as exc:
            _print_err(f"error: invalid --set {key}={value}: {exc}")
            return 2

    # 5. First-run prompt if Config_File is empty.
    try:
        existing = config.load()
    except ConfigError as exc:
        _print_err(f"error: failed to load Config_File: {exc}")
        return 1

    if _is_empty_config(existing):
        prompter = Prompter(config)
        try:
            prompter.prompt_first_run()
        except ConfigError as exc:
            _print_err(f"error: {exc}")
            return 1

    # 6. Resolve the step subset (with Step 8 gate applied).
    try:
        subset = _resolve_subset(args)
    except ValidationError as exc:
        _print_err(f"error: {exc}")
        return 2

    workdir = pathlib.Path(os.getcwd()).resolve()

    # 7. Build the RunLogger as a context manager so the file is flushed
    # and closed even on errors.
    dry_run_for_log = bool(args.dry_run or not args.apply)
    with RunLogger(workdir=workdir, dry_run=dry_run_for_log) as logger:
        # 8. State manager.
        state = StateManager(_STATE_PATH)

        # 9. Step runner, rooted at the current working directory.
        runner = StepRunner(config, state, logger, workdir=workdir)

        # --reset semantics: clear the named steps before any runner.run
        # invocation so the runner sees them in pending state.
        for step_id in args.reset_set:
            try:
                state.reset_step(step_id)
            except Exception as exc:  # pragma: no cover - defensive
                _print_err(f"error: failed to reset step {step_id}: {exc}")
                return 1

        # 10. Mid-run prompt loop. Wrap ``runner.run`` so a ConfigError
        # raised either by the runner's required-config check or
        # forwarded from a step's ``STATUS: missing_var`` line drives
        # one round of :meth:`Prompter.prompt_for_missing` and a retry.
        prompter = Prompter(config)
        attempts = 0
        while True:
            try:
                runner.run(
                    subset,
                    apply=args.apply,
                    dry_run=args.dry_run,
                    force_set=args.force_set,
                )
                break
            except ConfigError as exc:
                attempts += 1
                if attempts > _MAX_PROMPT_RETRIES:
                    _print_err(
                        f"error: exceeded {_MAX_PROMPT_RETRIES} retries "
                        f"prompting for missing config: {exc}"
                    )
                    return 1
                key = (exc.context or {}).get("key") if exc.context else None
                if not key:
                    _print_err(f"error: {exc}")
                    return 1
                try:
                    prompter.prompt_for_missing([str(key)])
                except ConfigError as inner:
                    _print_err(f"error: {inner}")
                    return 1
                # Loop: re-invoke runner.run with the now-populated key.
                continue
            except ValidationError as exc:
                _print_err(f"error: {exc}")
                return 2
            except StepError as exc:
                ctx = exc.context or {}
                step_id = ctx.get("step_id", "<unknown>")
                exit_code = ctx.get("exit_code", "<unknown>")
                _print_err(
                    f"error: step {step_id} failed "
                    f"(exit code {exit_code}): {exc}"
                )
                return 1
            except KeyboardInterrupt:
                _print_err("Interrupted.")
                return 130

        # 11. Success path: reload state + config and render the summary.
        try:
            state_data = state.load()
            config_data = config.load()
        except ConfigError as exc:
            _print_err(
                f"error: failed to reload Config_File for summary: {exc}"
            )
            return 1

        summary = render_summary(state_data, config_data)
        # render_summary already terminates with a newline; suppress
        # the implicit one from ``print`` so the output is exact.
        print(summary, end="")

    # 12. Success.
    return 0


if __name__ == "__main__":
    sys.exit(main())
