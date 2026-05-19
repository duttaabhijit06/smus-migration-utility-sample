"""Typed exceptions for the SageMaker Migration Tool orchestrator.

This module defines the exception hierarchy used by the Python
orchestrator. Every exception raised by the orchestrator (config loader,
state manager, step runner, pre-execution validator, etc.) inherits from
:class:`MigrationToolError`, so a top-level handler can catch all
tool-originated failures with a single ``except`` clause while still
distinguishing categories programmatically when needed.

Each subclass optionally accepts a ``context`` keyword argument that
callers can use to attach structured metadata (for example, the offending
config key and value, the failing step ID, or the illegal state
transition). The metadata is stored on ``self.context`` and is *not*
folded into the formatted message, so ``str(exc)`` still returns the
human-readable message exactly as it was passed in.

The module intentionally has no third-party dependencies and does not
import from any other ``migration_tool`` module, so importing it is safe
from any layer of the orchestrator.
"""

from __future__ import annotations

__all__ = [
    "MigrationToolError",
    "ConfigError",
    "StateError",
    "StepError",
    "ValidationError",
]


class MigrationToolError(Exception):
    """Base class for every exception raised by the Migration Tool.

    All typed exceptions defined in this module inherit from this class,
    so callers can write ``except MigrationToolError`` to catch any
    tool-originated failure regardless of category.

    The optional ``context`` keyword argument accepts a ``dict`` of
    structured metadata that callers may attach to the exception (for
    example, ``{"key": "repo_provider", "value": "github-foo"}``). The
    metadata is stored verbatim on :attr:`context` and is not included
    in the formatted message; ``str(exc)`` returns the human-readable
    message that was passed as the first positional argument.
    """

    def __init__(
        self,
        message: str = "",
        *,
        context: dict | None = None,
    ) -> None:
        super().__init__(message)
        self.context: dict | None = context


class ConfigError(MigrationToolError):
    """Raised when a config value is invalid, missing, or off-schema.

    Examples include a Config_File that fails ``jsonschema`` validation,
    a required key that is missing or empty when a step demands it
    (Requirement 2.6), or a value that fails a provider-aware regex
    (Requirements 2.7-2.11).

    Validates: Requirement 2.6 (and the related schema/format rules in
    Requirement 2).
    """


class StateError(MigrationToolError):
    """Raised on illegal state transitions or a corrupted State_File.

    Examples include attempting to move a step from ``completed`` to
    ``in_progress`` without ``--force`` or ``--reset``, attempting any
    transition not in the legal set defined by the state machine, or
    loading a State_File whose JSON is malformed or whose schema does
    not match the expected shape (Requirement 3.4 corrupted-state
    case).

    Validates: Requirement 3.4 (state-machine integrity, including the
    corrupted-state-file case).
    """


class StepError(MigrationToolError):
    """Raised when a step's ``run.sh`` exits with a non-zero status.

    The Step_Runner wraps the failing subprocess invocation in this
    exception so the orchestrator can record the failure in the
    State_File, persist the last 50 lines of stderr as the
    ``last_error_excerpt``, and halt subsequent steps.

    Validates: Requirement 3.4 (step failure handling and propagation).
    """


class ValidationError(MigrationToolError):
    """Raised on pre-execution validation failures.

    Examples include the user supplying both ``--apply`` and
    ``--dry-run`` (mutually exclusive per Requirement 1.7), or an
    inventory step's ``run.sh`` containing an ``aws <verb>`` token
    outside the read-only allowlist ``{list, get, describe}``
    (Requirement 18.2). These checks run before any subprocess is
    spawned, so raising this exception aborts the run cleanly without
    any side effect on AWS or the local filesystem.

    Validates: Requirements 1.7 and 18.2.
    """
