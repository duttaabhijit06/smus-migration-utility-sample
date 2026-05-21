"""CLI argument parsing and mode resolution for the orchestrator.

This module owns the ``argparse`` surface for ``python -m migration_tool``
and the mode-resolution logic that converts the parsed flags into the
canonical, validated :class:`argparse.Namespace` that the runner
consumes.

The CLI is deliberately split from ``__main__.py``: parsing and
validation live here so tests can drive :func:`parse_args` directly
without spawning a subprocess, while the orchestration glue (config
load, prompt loop, runner dispatch, summary print) lives in
``__main__.py`` (task 10.2).

Validation responsibilities discharged before any side effect:

* ``--apply`` and ``--dry-run`` may not appear together
  (Requirement 1.7).
* ``--step`` / ``--from`` / ``--to`` / ``--force`` / ``--reset`` values
  must name a step ID registered in
  :data:`migration_tool.steps_registry.STEP_IDS` (Requirement 5.1).
* ``--set`` values must match ``^[a-zA-Z_][a-zA-Z0-9_]*=.*$``
  (Requirement 2.5).

Every validation failure raises :class:`ValidationError` with a message
that names the offending flag/value, so the entry point in
``__main__.py`` can print a useful message and exit non-zero before any
orchestration runs (Requirement 1.7).

Validates: Requirements 1.1, 1.2, 1.3, 1.4, 1.5, 1.7, 2.4, 2.5, 3.5,
15.1.
"""

from __future__ import annotations

import argparse
import re
from typing import Final

from migration_tool.errors import ValidationError
from migration_tool.steps_registry import STEP_IDS

__all__ = [
    "build_parser",
    "parse_args",
]


# ---------------------------------------------------------------------------
# --set <key>=<value> validation
# ---------------------------------------------------------------------------
#
# Requirement 2.5 allows the user to update one config key without
# prompting for any other input via ``--set <key>=<value>``. The key
# must be a legal Python-style identifier (so it can safely double as a
# JSON key and as the suffix of an ``MT_*`` environment variable) and
# the value is everything after the first ``=`` (subsequent ``=`` signs
# inside the value are preserved verbatim, e.g. JDBC URLs).

_SET_OVERRIDE_REGEX: Final[re.Pattern[str]] = re.compile(
    r"^[a-zA-Z_][a-zA-Z0-9_]*=.*$"
)


def build_parser() -> argparse.ArgumentParser:
    """Construct the orchestrator's argparse parser.

    Exposed as a stand-alone helper so tests (and ``__main__.py``) can
    introspect the parser (default values, action types, ``dest``
    mappings) without invoking :func:`parse_args`. The returned parser
    performs only structural parsing; the semantic validation rules
    (mutual exclusion, step-ID membership, ``--set`` shape) are
    enforced by :func:`parse_args` so they can raise the typed
    :class:`ValidationError` rather than triggering argparse's
    ``SystemExit``.
    """

    parser = argparse.ArgumentParser(
        prog="migration_tool",
        description=(
            "SageMaker Migration Tool orchestrator. Default mode is "
            "dry-run; pass --apply to enable state-changing operations."
        ),
    )

    parser.add_argument(
        "--apply",
        action="store_true",
        default=False,
        help=(
            "Enable apply mode (state-changing operations). Mutually "
            "exclusive with --dry-run."
        ),
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        default=False,
        dest="dry_run",
        help=(
            "Force dry-run mode (read-only). Mutually exclusive with "
            "--apply. Default when neither flag is given."
        ),
    )
    parser.add_argument(
        "--step",
        metavar="<id>",
        default=None,
        help="Run only the named step.",
    )
    parser.add_argument(
        "--from",
        dest="from_id",
        metavar="<id>",
        default=None,
        help=(
            "Start from this step in the canonical ordering. Combine "
            "with --to to bound a range."
        ),
    )
    parser.add_argument(
        "--to",
        dest="to_id",
        metavar="<id>",
        default=None,
        help="Stop after this step in the canonical ordering.",
    )
    parser.add_argument(
        "--force",
        action="append",
        default=[],
        metavar="<id>",
        dest="force_raw",
        help=(
            "Re-run a step whose state is 'completed'. May be passed "
            "multiple times to force several steps."
        ),
    )
    parser.add_argument(
        "--reset",
        action="append",
        default=[],
        metavar="<id>",
        dest="reset_raw",
        help=(
            "Reset a step's state to 'pending'. May be passed multiple "
            "times to reset several steps."
        ),
    )
    parser.add_argument(
        "--reconfigure",
        action="store_true",
        default=False,
        help=(
            "Re-prompt for every config key and overwrite the config "
            "file."
        ),
    )
    parser.add_argument(
        "--set",
        action="append",
        default=[],
        dest="set_raw",
        metavar="<key>=<value>",
        help=(
            "Update one config key without prompting for any other "
            "input. May be passed multiple times to update several "
            "keys."
        ),
    )
    parser.add_argument(
        "--convert-dags",
        action="store_true",
        default=False,
        dest="convert_dags",
        help="Include Step 8 (Python DAG to YAML conversion).",
    )
    parser.add_argument(
        "--push-cicd",
        action="store_true",
        default=False,
        dest="push_cicd",
        help=(
            "Include Step 9 (CI/CD pipeline file generation + git push). "
            "Requires local Git credentials for 3P providers — see README."
        ),
    )

    return parser


def _ensure_known_step(step_id: str, *, flag_name: str) -> None:
    """Raise :class:`ValidationError` if ``step_id`` is not registered.

    The message names both the offending value and the flag that
    introduced it so the user can fix the invocation without
    guesswork.
    """

    if step_id not in STEP_IDS:
        raise ValidationError(
            f"unknown step id {step_id!r} for {flag_name}",
            context={"flag": flag_name, "value": step_id},
        )


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """Parse and validate the orchestrator's CLI flags.

    The returned namespace exposes exactly these fields:

    * ``apply: bool``
    * ``dry_run: bool``
    * ``effective_mode: str`` — ``"apply"`` or ``"dry_run"``
    * ``step: str | None``
    * ``from_id: str | None``
    * ``to_id: str | None``
    * ``force_set: frozenset[str]``
    * ``reset_set: frozenset[str]``
    * ``reconfigure: bool``
    * ``set_overrides: list[tuple[str, str]]``
    * ``convert_dags: bool``
    * ``push_cicd: bool``

    Args:
        argv: optional argument vector. Defaults to ``sys.argv[1:]``
            when ``None`` (standard argparse behavior).

    Raises:
        ValidationError: when ``--apply`` and ``--dry-run`` appear
            together (Requirement 1.7); when any of ``--step`` /
            ``--from`` / ``--to`` / ``--force`` / ``--reset`` names a
            step ID that is not registered in
            :data:`migration_tool.steps_registry.STEP_IDS`; or when a
            ``--set`` value does not match the
            ``<identifier>=<value>`` shape required by Requirement 2.5.
    """

    parser = build_parser()
    namespace = parser.parse_args(argv)

    # --- Mutual exclusion (Requirement 1.7) ---------------------------------
    # Per Requirement 1.7 this conflict must be detected BEFORE any
    # orchestration runs. We deliberately avoid argparse's
    # ``add_mutually_exclusive_group`` because that path emits a bare
    # ``SystemExit``, which would bypass the typed exception hierarchy
    # the rest of the orchestrator relies on.
    if namespace.apply and namespace.dry_run:
        raise ValidationError(
            "--apply and --dry-run are mutually exclusive",
            context={"flags": ["--apply", "--dry-run"]},
        )

    # --- Step ID validation (Requirement 5.1 via STEP_IDS) ------------------
    if namespace.step is not None:
        _ensure_known_step(namespace.step, flag_name="--step")
    if namespace.from_id is not None:
        _ensure_known_step(namespace.from_id, flag_name="--from")
    if namespace.to_id is not None:
        _ensure_known_step(namespace.to_id, flag_name="--to")
    for forced in namespace.force_raw:
        _ensure_known_step(forced, flag_name="--force")
    for reset in namespace.reset_raw:
        _ensure_known_step(reset, flag_name="--reset")

    # --- --set <key>=<value> validation (Requirement 2.5) -------------------
    set_overrides: list[tuple[str, str]] = []
    for raw in namespace.set_raw:
        if not _SET_OVERRIDE_REGEX.fullmatch(raw):
            raise ValidationError(
                f"--set value {raw!r} is not of the form <key>=<value> "
                f"where <key> matches ^[a-zA-Z_][a-zA-Z0-9_]*$",
                context={"flag": "--set", "value": raw},
            )
        key, _, value = raw.partition("=")
        set_overrides.append((key, value))

    # --- Resolve derived fields --------------------------------------------
    namespace.force_set = frozenset(namespace.force_raw)
    namespace.reset_set = frozenset(namespace.reset_raw)
    namespace.set_overrides = set_overrides
    namespace.effective_mode = "apply" if namespace.apply else "dry_run"

    # Drop the intermediate raw-list attributes so the final namespace
    # exposes only the documented public fields. Callers that need the
    # validated, deduplicated form should use ``force_set`` /
    # ``reset_set`` / ``set_overrides``; keeping the raw lists around
    # would invite consumers to rely on un-normalized values.
    del namespace.force_raw
    del namespace.reset_raw
    del namespace.set_raw

    return namespace
