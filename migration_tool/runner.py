"""Step runner for the SageMaker Migration Tool orchestrator.

This module owns the per-step execution loop. The runner accepts a list
of step IDs (already resolved by
:func:`migration_tool.steps_registry.range_expand` from the CLI flags)
and executes each step in order. For each step the runner:

1. Reads the step's current state. If ``completed`` and not in
   ``force_set``, the step is skipped.
2. Validates that every config key the step declares as required is
   present and non-empty. Missing keys raise :class:`ConfigError`
   *before* any subprocess starts (Requirement 2.6); the orchestrator's
   caller catches this and prompts mid-run via
   :meth:`migration_tool.prompts.Prompter.prompt_for_missing`, then
   retries.
3. Pre-execution validators (Requirement 1.7 and 18.2):

   * ``--apply`` and ``--dry-run`` together → :class:`ValidationError`
     before any subprocess.
   * For inventory steps (step IDs starting with ``"inventory."``),
     scan the step's ``run.sh`` and reject any ``aws <verb>`` token
     whose verb is outside the read-only allowlist
     ``{list, get, describe}``.

4. Sets state to ``in_progress`` (atomic persist via
   :meth:`migration_tool.state.StateManager.mark_in_progress`).
5. Spawns ``bash <folder>/run.sh [--apply | --dry-run]`` with the
   resolved environment. Config values are passed as ``MT_*`` env
   vars; the working directory is ``MT_WORKDIR``; the run mode is
   surfaced as ``MT_APPLY=1`` or ``MT_DRY_RUN=1`` so step scripts can
   choose paths if needed.
6. Streams stdout line-by-line. Lines beginning with ``STATUS:`` are
   recorded via :meth:`migration_tool.logger.RunLogger.log_event` AND
   parsed for special directives (``set <key>=<value>``,
   ``missing_var <NAME>``, ``error <message>``). Other stdout lines
   are forwarded to the run log as plain events.
7. On exit: 0 → mark_completed; non-0 → mark_failed with the last 50
   stderr lines, then raise :class:`StepError`.
8. Halt-after-failed: before processing each step in the list, check
   :meth:`migration_tool.state.StateManager.is_failed_present` so a
   fresh ``--from`` run after a prior failed step in a previous CLI
   invocation cannot silently skip past the failure.

Validates: Requirements 1.2, 1.3, 1.4, 1.5, 1.7, 2.6, 3.2, 3.3, 3.4,
3.5, 5.5, 18.1, 18.2, 18.3.
"""

from __future__ import annotations

import collections
import os
import pathlib
import re
import subprocess
import threading
import time
from typing import Callable, FrozenSet, Optional, Union

from migration_tool.config import ConfigLoader
from migration_tool.errors import (
    ConfigError,
    StepError,
    ValidationError,
)
from migration_tool.logger import RunLogger
from migration_tool.state import StateManager, Status
from migration_tool.steps_registry import INVENTORY_STEP_IDS, folder_for

__all__ = [
    "STEP_REQUIRED_CONFIG",
    "StepRunner",
    "required_config_for",
]


# ---------------------------------------------------------------------------
# Required-config declarations
# ---------------------------------------------------------------------------

# Static base of required-config keys per step. The dynamic
# ``repo_url`` / ``repo_name`` additions for steps 01 and 09 are
# layered on top by :func:`required_config_for` based on the resolved
# ``repo_provider`` value at call time. Inventory steps share a
# single requirement (``aws_region``) and are populated via a loop
# below so adding a new inventory service automatically picks up the
# same baseline.
STEP_REQUIRED_CONFIG: dict[str, list[str]] = {
    "01_create-smus-domain": [
        "repo_provider",
        "aws_region",
        "smus_domain_name",
        "admin_project_name",
        "identity_center_instance_arn",
    ],
    "02_portability": [],
    "03_glue-jobs": ["aws_region"],
    "03b_lakeformation-setup": [
        "aws_region",
        "smus_domain_id",
        "admin_project_id",
        "source_account_id",
        "tooling_user_role_arn",
        "source_s3_inclusion_list",
    ],
    "04_catalog": ["smus_domain_id", "admin_project_id"],
    "05_s3-data": [
        "aws_region",
        "mwaa_environment_name",
        "mwaa_dag_bucket_name",
        "source_s3_inclusion_list",
    ],
    "06_mwaa-extract": ["aws_region", "mwaa_environment_name"],
    "07_mwaa-integrate": [
        "smus_domain_id",
        "admin_project_id",
        "source_account_id",
    ],
    "08_dag-yaml": [],
    "09_cicd": ["repo_provider"],
}

# Inventory steps all share the same single requirement. Materialise
# the entries here so a new inventory service registered in
# ``steps_registry`` automatically picks up the right baseline.
for _inv_id in INVENTORY_STEP_IDS:
    STEP_REQUIRED_CONFIG.setdefault(_inv_id, ["aws_region"])


def required_config_for(
    step_id: str,
    config: ConfigLoader,
) -> list[str]:
    """Return the list of config keys ``step_id`` needs at run time.

    Resolves the dynamic cases on top of :data:`STEP_REQUIRED_CONFIG`:

    * ``01_create-smus-domain`` adds ``repo_url`` when
      ``repo_provider != "codecommit"`` and ``repo_name`` when
      ``repo_provider == "codecommit"``. When ``repo_provider`` is not
      yet set, the helper returns the static list (unmodified) so the
      orchestrator's first pass can prompt for ``repo_provider`` and
      then re-call this helper to pick up the conditional addition.
    * ``09_cicd`` adds ``repo_url`` when ``repo_provider`` is not
      ``codecommit``; under codecommit the step generates a
      manual-wiring stub and does not need a URL.

    Unknown step IDs return an empty list rather than raising, so a
    caller iterating over an externally-provided step list does not
    have to special-case unrecognised entries.
    """

    base = list(STEP_REQUIRED_CONFIG.get(step_id, []))

    # Try to read the resolved provider, but tolerate the case where
    # it is not yet set (the very first first-run pass before the
    # prompter has collected anything).
    try:
        provider = config.get("repo_provider")
    except ConfigError:
        provider = None

    if step_id == "01_create-smus-domain":
        if provider is None:
            return base
        if provider == "codecommit":
            base.append("repo_name")
        else:
            base.append("repo_url")
        return base

    if step_id == "09_cicd":
        # Under codecommit the step writes a manual-wiring stub and
        # halts; no repo_url is needed. Under any other provider the
        # step needs the URL to wire the provider-native pipeline.
        if provider is not None and provider != "codecommit":
            base.append("repo_url")
        return base

    return base


# ---------------------------------------------------------------------------
# Inventory verb-allowlist scan
# ---------------------------------------------------------------------------

# Regex that captures the "verb" of an ``aws ...`` invocation. The
# verb is the LAST whitespace-separated token before the first option
# flag. The regex is intentionally permissive: it skips an optional
# leading service-or-group token (``[a-z0-9-]+\s+``) so command groups
# like ``aws logs describe-log-groups`` and plain forms like
# ``aws lambda list-functions`` both yield the verb in group 1. A few
# AWS CLI command groups (``aws logs ...``, ``aws kafka ...``,
# ``aws kinesisanalyticsv2 ...``) have the actual verb as the THIRD
# token; the simplification used here treats the third token as the
# verb in those cases too, which is exactly what we want.
_AWS_INVOKE_RE = re.compile(r"\baws\s+(?:[a-z0-9-]+\s+)?([a-z0-9-]+)")

# Single-quoted heredoc opener. The body of a single-quoted heredoc is
# literal (no expansion, no interpretation) so any ``aws`` mentions
# inside should not be flagged. Other heredoc forms are not handled
# here; the property test in 9.4 will exercise the pragmatic surface.
_HEREDOC_SQ_RE = re.compile(r"<<-?\s*'([^']+)'")

# Verbs whose first hyphen-separated segment is one of these are
# read-only and therefore allowed in inventory scripts (Requirement
# 18.1). Examples accepted: ``list``, ``list-functions``,
# ``list-clusters-v2``, ``get``, ``get-jobs``, ``describe-alarms``,
# ``describe-log-groups``.
_ALLOWED_VERB_HEADS: frozenset[str] = frozenset({"list", "get", "describe"})


def _scan_inventory_run_sh(text: str) -> list[str]:
    """Return any disallowed AWS verbs found in ``text``.

    The scan ignores commented-out lines (those whose first
    non-whitespace character is ``#``) and the body of single-quoted
    heredocs. Every other line is searched for ``aws <verb>`` tokens
    via :data:`_AWS_INVOKE_RE`; a verb whose first hyphen-separated
    segment is not in :data:`_ALLOWED_VERB_HEADS` is appended to the
    returned list. The list preserves the on-disk order of the
    offending occurrences.
    """

    disallowed: list[str] = []
    in_heredoc_token: Optional[str] = None

    for raw_line in text.splitlines():
        # If we are inside a single-quoted heredoc, only check for the
        # closing token and otherwise skip the line wholesale.
        if in_heredoc_token is not None:
            if raw_line.strip() == in_heredoc_token:
                in_heredoc_token = None
            continue

        stripped = raw_line.lstrip()
        # Skip whole-line comments. Trailing comments on a real
        # command line are still scanned; that is acceptable because
        # a trailing comment after an ``aws ...`` invocation does not
        # reliably hide the invocation from the verb check.
        if stripped.startswith("#"):
            continue

        # Detect a single-quoted heredoc opener on this line. We still
        # scan the same line for ``aws`` invocations *before* the
        # heredoc would start, because the heredoc body begins on the
        # NEXT line.
        heredoc_open = _HEREDOC_SQ_RE.search(raw_line)
        if heredoc_open is not None:
            in_heredoc_token = heredoc_open.group(1)

        for match in _AWS_INVOKE_RE.finditer(raw_line):
            verb = match.group(1)
            head = verb.split("-", 1)[0]
            if head not in _ALLOWED_VERB_HEADS:
                disallowed.append(verb)

    return disallowed


# ---------------------------------------------------------------------------
# StepRunner
# ---------------------------------------------------------------------------


class StepRunner:
    """Execute a list of migration steps in order.

    The runner wires the :class:`ConfigLoader`, :class:`StateManager`,
    and :class:`RunLogger` together so each step's bash subprocess
    sees the right environment, the right state transitions, and the
    right log records. It does not call AWS APIs directly; every
    AWS-touching operation flows through the per-step ``run.sh``
    invoked here as a subprocess (Requirement 19.1, 19.3).
    """

    def __init__(
        self,
        config: ConfigLoader,
        state: StateManager,
        logger: RunLogger,
        *,
        workdir: Union[pathlib.Path, str, None] = None,
        # ``time_func`` is exposed as a constructor parameter purely
        # for test injection: unit tests can supply a deterministic
        # clock so ``elapsed_seconds`` is reproducible. Production
        # callers leave it at the default.
        time_func: Callable[[], float] = time.monotonic,
    ) -> None:
        self._config = config
        self._state = state
        self._logger = logger
        self._time = time_func
        if workdir is None:
            self._workdir = pathlib.Path.cwd().resolve()
        else:
            self._workdir = pathlib.Path(workdir).resolve()

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def run(
        self,
        step_ids: list[str],
        *,
        apply: bool,
        dry_run: bool,
        force_set: Union[FrozenSet[str], set[str]] = frozenset(),
    ) -> None:
        """Execute ``step_ids`` in order under the supplied modes.

        Parameters
        ----------
        step_ids:
            Ordered list of step IDs to execute. The list is
            authoritative; the runner does not re-resolve it from
            ``--from`` / ``--to`` / ``--step``.
        apply:
            When ``True``, the step's ``run.sh`` is invoked with
            ``--apply``. Mutually exclusive with ``dry_run``.
        dry_run:
            When ``True``, the step's ``run.sh`` is invoked with
            ``--dry-run``. Mutually exclusive with ``apply``.
        force_set:
            Set of step IDs that should be re-run even when their
            current state is ``completed`` (Requirement 3.5). Steps
            currently in the ``failed`` state are also re-runnable
            when listed here, by virtue of the
            ``failed → in_progress`` legal transition.

        Raises
        ------
        ValidationError:
            On pre-execution failures (mutually-exclusive flag combo,
            disallowed AWS verb in an inventory script).
        ConfigError:
            On a missing required config key (raised before any
            subprocess starts, or after the script signals
            ``STATUS: missing_var <NAME>``).
        StepError:
            When a step's ``run.sh`` exits non-zero, or when a prior
            run left a ``failed`` step in the State_File and the
            current invocation is not explicitly re-running it.
        """

        # Requirement 1.7 — apply and dry-run are mutually exclusive
        # and the check runs BEFORE any subprocess starts (and indeed
        # before any step is processed at all).
        if apply and dry_run:
            raise ValidationError(
                "--apply and --dry-run are mutually exclusive",
                context={"apply": apply, "dry_run": dry_run},
            )

        force_frozen: FrozenSet[str] = frozenset(force_set)

        # Cross-invocation halt-after-failed: if the State_File
        # already records a failed step from a previous CLI
        # invocation, refuse to start unless the user is explicitly
        # re-running that failed step under ``--force``.
        self._check_cross_invocation_halt(step_ids, force_frozen)

        for step_id in step_ids:
            # Intra-run halt-after-failed gate. The first failure in
            # ``run`` raises StepError, which exits this loop, so this
            # check is mostly defensive — it catches the case where a
            # caller suppressed the StepError of a prior step and
            # tries to push another one through the same runner.
            if self._state.is_failed_present():
                self._check_cross_invocation_halt(step_ids, force_frozen)

            self._run_one(
                step_id,
                apply=apply,
                dry_run=dry_run,
                force_set=force_frozen,
            )

    # ------------------------------------------------------------------
    # Per-step execution
    # ------------------------------------------------------------------

    def _run_one(
        self,
        step_id: str,
        *,
        apply: bool,
        dry_run: bool,
        force_set: FrozenSet[str],
    ) -> None:
        """Execute a single step end-to-end."""

        record = self._state.get_step(step_id)
        current_status = record.get("status")

        # Skip-completed (Requirement 3.5). A completed step that is
        # not explicitly forced is a successful no-op.
        if (
            current_status == Status.COMPLETED.value
            and step_id not in force_set
        ):
            self._logger.log_event(
                f"step '{step_id}' already completed, skipping",
                step_id=step_id,
            )
            return

        # Required-config validation (Requirement 2.6). Raises
        # ConfigError BEFORE any subprocess starts; the orchestrator's
        # caller catches this and prompts mid-run.
        self._check_required_config(step_id)

        # Inventory verb allowlist scan (Requirement 18.1, 18.2).
        # Raises ValidationError BEFORE any subprocess starts.
        folder = pathlib.Path(folder_for(step_id))
        if not folder.is_absolute():
            folder = self._workdir / folder
        run_sh = folder / "run.sh"

        if step_id.startswith("inventory."):
            self._scan_inventory_script(step_id, run_sh)

        # Transition pending → in_progress (Requirement 3.2).
        # ``mark_in_progress`` persists the State_File before this
        # call returns, so a SIGKILL between transitions cannot leave
        # the bytes on disk out of sync with our intent.
        log_path = str(self._logger.log_path)
        self._state.mark_in_progress(step_id, log_path=log_path)

        # Build the subprocess invocation.
        flags: list[str] = []
        if apply:
            flags.append("--apply")
        elif dry_run:
            flags.append("--dry-run")

        env = self._build_env(apply=apply, dry_run=dry_run)

        self._logger.log_event(
            f"step '{step_id}' starting (apply={apply}, dry_run={dry_run})",
            step_id=step_id,
        )

        start = self._time()
        result = self._execute_subprocess(
            step_id=step_id,
            run_sh=run_sh,
            flags=flags,
            env=env,
        )
        elapsed = max(0.0, self._time() - start)

        # Translate the captured stream state into an outcome.
        if result.missing_var is not None:
            # The script told us a required env var was missing.
            # Mark the step failed (the script exited non-zero on the
            # bash side) and surface a ConfigError so the caller can
            # prompt and retry.
            stderr_excerpt = "\n".join(result.stderr_tail) or (
                f"step exited because required config key "
                f"'{result.missing_var}' was missing"
            )
            self._state.mark_failed(
                step_id,
                elapsed_seconds=elapsed,
                last_error_excerpt=stderr_excerpt,
                log_path=log_path,
            )
            raise ConfigError(
                f"Step '{step_id}' requires config key "
                f"'{result.missing_var}'",
                context={"key": result.missing_var, "step_id": step_id},
            )

        if result.exit_code == 0:
            self._state.mark_completed(
                step_id,
                elapsed_seconds=elapsed,
                log_path=log_path,
            )
            self._logger.log_event(
                f"step '{step_id}' completed in {elapsed:.3f}s",
                step_id=step_id,
            )
            return

        # Non-zero exit (Requirement 3.4). Capture the last 50 lines
        # of stderr and the script's emitted ``STATUS: error``
        # message (when one was seen) into ``last_error_excerpt``.
        excerpt_parts: list[str] = []
        if result.error_message is not None:
            excerpt_parts.append(f"STATUS: error {result.error_message}")
        excerpt_parts.extend(result.stderr_tail)
        last_error_excerpt = "\n".join(excerpt_parts) or (
            f"step exited with code {result.exit_code}"
        )

        self._state.mark_failed(
            step_id,
            elapsed_seconds=elapsed,
            last_error_excerpt=last_error_excerpt,
            log_path=log_path,
        )

        raise StepError(
            f"Step '{step_id}' failed with exit code {result.exit_code}",
            context={
                "step_id": step_id,
                "exit_code": result.exit_code,
                "error_message": result.error_message,
            },
        )

    # ------------------------------------------------------------------
    # Pre-execution validators
    # ------------------------------------------------------------------

    def _check_required_config(self, step_id: str) -> None:
        """Raise :class:`ConfigError` for the first missing required key."""

        for key in required_config_for(step_id, self._config):
            try:
                self._config.get(key)
            except ConfigError:
                # Re-raise with a step-aware message so the caller can
                # tell which step demanded the key.
                raise ConfigError(
                    f"Step '{step_id}' requires config key '{key}'",
                    context={"key": key, "step_id": step_id},
                ) from None

    def _scan_inventory_script(
        self,
        step_id: str,
        run_sh: pathlib.Path,
    ) -> None:
        """Scan an inventory ``run.sh`` for disallowed AWS verbs."""

        try:
            text = run_sh.read_text(encoding="utf-8")
        except FileNotFoundError as exc:
            raise ValidationError(
                f"Inventory step '{step_id}' has no run.sh at {run_sh}",
                context={"step_id": step_id, "path": str(run_sh)},
            ) from exc
        except OSError as exc:
            raise ValidationError(
                f"Failed to read inventory run.sh at {run_sh}: {exc}",
                context={"step_id": step_id, "path": str(run_sh)},
            ) from exc

        offenders = _scan_inventory_run_sh(text)
        if offenders:
            raise ValidationError(
                f"Inventory step '{step_id}' uses disallowed AWS verb "
                f"'{offenders[0]}'; only list/get/describe verbs are "
                f"permitted",
                context={
                    "step_id": step_id,
                    "verb": offenders[0],
                    "all_offenders": offenders,
                },
            )

    def _check_cross_invocation_halt(
        self,
        step_ids: list[str],
        force_set: FrozenSet[str],
    ) -> None:
        """Raise :class:`StepError` if a previously-failed step blocks the run.

        A failed step in the State_File is *blocking* unless every
        failed step is also in ``step_ids`` and in ``force_set`` —
        i.e., the user is explicitly re-running each failure. This
        permits ``--step <failed> --force <failed>`` while refusing
        to silently skip past a failure with a fresh ``--from``.
        """

        data = self._state.load()
        failed_ids = [
            sid
            for sid, rec in data["steps"].items()
            if isinstance(rec, dict)
            and rec.get("status") == Status.FAILED.value
        ]
        if not failed_ids:
            return

        blocking = [
            sid
            for sid in failed_ids
            if sid not in step_ids or sid not in force_set
        ]
        if not blocking:
            return

        raise StepError(
            "Cannot proceed: previously failed step(s) "
            f"{blocking}. Re-run with --force or --reset.",
            context={"failed": blocking},
        )

    # ------------------------------------------------------------------
    # Environment construction
    # ------------------------------------------------------------------

    def _build_env(self, *, apply: bool, dry_run: bool) -> dict[str, str]:
        """Build the env dict passed to the step's bash subprocess.

        The runner inherits the current process environment and layers
        ``MT_*`` overrides on top:

        * ``MT_<KEY_UPPER>`` — one entry per non-empty config key.
          Lists are joined with ``,`` so step scripts can iterate them
          via ``IFS=,``. Booleans serialize as ``true`` / ``false``.
        * ``MT_WORKDIR`` — the resolved working directory.
        * ``MT_APPLY=1`` or ``MT_DRY_RUN=1`` — the run mode marker.
          When neither flag is set we default to ``MT_DRY_RUN=1`` so
          the bash side has a definitive marker to read.
        """

        env = dict(os.environ)

        # ``ConfigLoader.load`` returns ``{}`` when the file does not
        # exist yet, which is fine — we just have no MT_* overrides.
        try:
            config_data = self._config.load()
        except ConfigError:
            # A schema-broken config is surfaced elsewhere; in this
            # context we proceed with the inherited environment so
            # the subprocess can at least emit a structured failure.
            config_data = {}

        for key, value in config_data.items():
            if value is None or value == "" or value == []:
                continue
            env_key = f"MT_{key.upper()}"
            if isinstance(value, list):
                env[env_key] = ",".join(str(item) for item in value)
            elif isinstance(value, bool):
                env[env_key] = "true" if value else "false"
            else:
                env[env_key] = str(value)

        env["MT_WORKDIR"] = str(self._workdir)
        if apply:
            env["MT_APPLY"] = "1"
            env.pop("MT_DRY_RUN", None)
        else:
            # Default to dry-run when neither flag is set; matches the
            # bash side's own default and gives step scripts a
            # definitive marker to read.
            env["MT_DRY_RUN"] = "1"
            env.pop("MT_APPLY", None)

        return env

    # ------------------------------------------------------------------
    # Subprocess execution and stdout streaming
    # ------------------------------------------------------------------

    def _execute_subprocess(
        self,
        *,
        step_id: str,
        run_sh: pathlib.Path,
        flags: list[str],
        env: dict[str, str],
    ) -> "_SubprocessResult":
        """Spawn ``bash <run_sh> <flags>`` and stream its output.

        The stdout stream is parsed line-by-line in the foreground so
        ``STATUS:`` directives (config-set, missing-var, error) update
        orchestrator state in real time. The stderr stream is drained
        on a background thread into a ``deque(maxlen=50)`` so the
        runner can record the last 50 lines on failure (Requirement
        3.4) without buffering an unbounded amount of memory.
        """

        # Resolve to a string so subprocess gets a clean argv. The
        # ``bash`` lookup is left to the OS PATH; the design assumes
        # bash is available on the operator's machine (the tool is
        # explicitly hybrid Python + bash, Requirement 19.2).
        argv = ["bash", str(run_sh), *flags]

        proc = subprocess.Popen(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=str(self._workdir),
            env=env,
            text=True,
            bufsize=1,  # line-buffered so streaming sees lines promptly
        )

        # Drain stderr on a background thread so a chatty stderr
        # cannot block the stdout reader. The deque keeps only the
        # last 50 lines, which matches Requirement 3.4's
        # ``last_error_excerpt`` budget.
        stderr_tail: collections.deque[str] = collections.deque(maxlen=50)
        stderr_thread = threading.Thread(
            target=self._drain_stderr,
            args=(proc, stderr_tail),
            daemon=True,
        )
        stderr_thread.start()

        missing_var: Optional[str] = None
        error_message: Optional[str] = None

        try:
            assert proc.stdout is not None  # narrowed by Popen with PIPE
            for raw_line in proc.stdout:
                line = raw_line.rstrip("\r\n")
                if not line:
                    continue
                if line.startswith("STATUS:"):
                    # Always log the STATUS line first; directive
                    # interpretation runs after so a malformed
                    # directive cannot lose the original record.
                    self._logger.log_event(line, step_id=step_id)
                    parsed = self._handle_status_directive(line)
                    if parsed.missing_var is not None and missing_var is None:
                        missing_var = parsed.missing_var
                    if parsed.error_message is not None:
                        error_message = parsed.error_message
                else:
                    # Non-STATUS stdout — forward to the run log as a
                    # plain event line. The simplest correct path
                    # described in the task spec.
                    self._logger.log_event(line, step_id=step_id)
        finally:
            # Always wait for the process so the file descriptors are
            # released; otherwise a dangling Popen leaks resources.
            proc.wait()
            stderr_thread.join(timeout=5.0)

        return _SubprocessResult(
            exit_code=proc.returncode,
            stderr_tail=list(stderr_tail),
            missing_var=missing_var,
            error_message=error_message,
        )

    @staticmethod
    def _drain_stderr(
        proc: subprocess.Popen,
        tail: "collections.deque[str]",
    ) -> None:
        """Background-thread body: drain ``proc.stderr`` into ``tail``.

        Each line is appended after stripping the trailing newline.
        The bounded ``deque`` automatically discards older lines so
        only the last 50 survive, matching Requirement 3.4.
        """

        if proc.stderr is None:
            return
        for raw_line in proc.stderr:
            tail.append(raw_line.rstrip("\r\n"))

    # ------------------------------------------------------------------
    # STATUS directive parsing
    # ------------------------------------------------------------------

    def _handle_status_directive(
        self,
        line: str,
    ) -> "_ParsedStatus":
        """Parse one ``STATUS: ...`` line and apply its side effect.

        Recognised directives:

        * ``set <key>=<value>`` — call
          :meth:`ConfigLoader.set` so the orchestrator persists the
          new value before the next step.
        * ``missing_var <NAME>`` — capture the missing var name (with
          ``MT_`` prefix stripped and lowercased back to a config
          key) so the caller can re-raise as :class:`ConfigError`.
        * ``error <message>`` — capture the message; the runner
          folds it into ``last_error_excerpt`` on failure.
        * Anything else — recorded by the caller's
          :meth:`RunLogger.log_event` call but otherwise ignored.
        """

        # Strip the ``STATUS:`` prefix and any leading whitespace.
        body = line[len("STATUS:"):].strip()
        if not body:
            return _ParsedStatus()

        # Split off the directive verb from its payload.
        verb, _, payload = body.partition(" ")
        payload = payload.strip()

        if verb == "set" and payload:
            key, eq, value = payload.partition("=")
            if eq != "=":
                # Malformed ``set`` directive — log via the caller and
                # otherwise ignore so a typo on the bash side cannot
                # crash the run.
                return _ParsedStatus()
            key = key.strip()
            value = value.strip()
            if not key:
                return _ParsedStatus()
            try:
                self._config.set(key, value)
            except ConfigError:
                # Schema-violating ``set`` directives are recorded by
                # the caller but do not abort the stream loop; the
                # subsequent failure will surface through the normal
                # exit-code path.
                pass
            return _ParsedStatus()

        if verb == "missing_var" and payload:
            name = payload.strip()
            if name.startswith("MT_"):
                name = name[len("MT_"):].lower()
            return _ParsedStatus(missing_var=name)

        if verb == "error":
            return _ParsedStatus(error_message=payload)

        return _ParsedStatus()


# ---------------------------------------------------------------------------
# Internal value types
# ---------------------------------------------------------------------------


class _ParsedStatus:
    """Tiny value object describing the side effects of one STATUS line."""

    __slots__ = ("missing_var", "error_message")

    def __init__(
        self,
        *,
        missing_var: Optional[str] = None,
        error_message: Optional[str] = None,
    ) -> None:
        self.missing_var = missing_var
        self.error_message = error_message


class _SubprocessResult:
    """Tiny value object describing the outcome of a step subprocess."""

    __slots__ = ("exit_code", "stderr_tail", "missing_var", "error_message")

    def __init__(
        self,
        *,
        exit_code: int,
        stderr_tail: list[str],
        missing_var: Optional[str],
        error_message: Optional[str],
    ) -> None:
        self.exit_code = exit_code
        self.stderr_tail = stderr_tail
        self.missing_var = missing_var
        self.error_message = error_message
