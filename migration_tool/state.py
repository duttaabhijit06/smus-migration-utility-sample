"""Per-step state machine and atomic State_File persistence.

This module owns the lifecycle of the State_File at
``./state/migration.state.json``: schema validation, the legal
transition graph, atomic write-temp-then-rename persistence, and the
``halt-after-failed`` predicate the orchestrator consults to gate
subsequent steps.

It implements the contract described in design.md ("State Manager") and
the acceptance criteria of Requirements 3.1-3.4:

* **3.1** — the State_File records, for each step, one of the values
  ``pending``, ``in_progress``, ``completed``, or ``failed``, plus the
  last run timestamp and the last error excerpt when one exists. The
  per-step record shape matches the design's Data Shapes section
  ("State (`state/migration.state.json`)").
* **3.2** — :meth:`StateManager.mark_in_progress` sets a step's status
  to ``in_progress`` and persists the State_File atomically *before*
  returning, so the bytes on disk reflect the new state before the
  caller invokes the step's bash script.
* **3.3** — :meth:`StateManager.mark_completed` sets a step's status to
  ``completed`` and persists the State_File atomically.
* **3.4** — :meth:`StateManager.mark_failed` sets a step's status to
  ``failed`` and records the supplied ``last_error_excerpt`` (the
  caller is responsible for truncating to the last 50 lines of stderr
  per the requirement); the orchestrator's
  :meth:`StateManager.is_failed_present` helper is the
  ``halt-after-failed`` predicate that prevents subsequent steps from
  running. Loading a State_File whose JSON is malformed or whose
  schema does not match the expected shape raises :class:`StateError`,
  satisfying the corrupted-state-file half of Requirement 3.4.

The module uses only Python's standard library (``datetime``,
``enum``, ``json``, ``os``, ``pathlib``, ``typing``) plus the in-tree
:class:`migration_tool.errors.StateError`. It does *not* import any
other ``migration_tool`` module so the dependency graph stays
one-directional from the higher-level orchestrator (runner, CLI) down
into ``state``.

Validates: Requirements 3.1, 3.2, 3.3, 3.4.
"""

from __future__ import annotations

import datetime
import enum
import json
import os
import pathlib
from typing import Any, Callable, FrozenSet, Optional, Tuple, Union

from migration_tool.errors import StateError

__all__ = [
    "DEFAULT_STATE_PATH",
    "LEGAL_TRANSITIONS",
    "StateManager",
    "Status",
]


# ---------------------------------------------------------------------------
# Status enum and legal transitions
# ---------------------------------------------------------------------------


class Status(str, enum.Enum):
    """Per-step status values recorded in the State_File.

    Inheriting from :class:`str` lets the enum members serialize as
    plain JSON strings (``"pending"``, ``"in_progress"``, etc.) without
    a custom encoder, and lets callers compare a member to its raw
    string form (``Status.PENDING == "pending"``) without an explicit
    ``.value`` lookup.

    Validates: Requirement 3.1 (status enumeration).
    """

    PENDING = "pending"
    IN_PROGRESS = "in_progress"
    COMPLETED = "completed"
    FAILED = "failed"


# Legal state transitions, taken verbatim from design.md and task 5.1.
# The orchestrator's ``--reset`` path goes through ``pending`` first
# (``COMPLETED|FAILED -> PENDING`` is performed by :meth:`StateManager.reset_step`,
# which bypasses the transition check), so the only ``PENDING -> ...``
# entry needed here is ``PENDING -> IN_PROGRESS``.
LEGAL_TRANSITIONS: FrozenSet[Tuple[Status, Status]] = frozenset(
    {
        (Status.PENDING, Status.IN_PROGRESS),
        (Status.IN_PROGRESS, Status.COMPLETED),
        (Status.IN_PROGRESS, Status.FAILED),
        (Status.FAILED, Status.IN_PROGRESS),
        (Status.COMPLETED, Status.IN_PROGRESS),
    }
)


# ---------------------------------------------------------------------------
# Defaults and constants
# ---------------------------------------------------------------------------

# Default State_File path, relative to the working directory. The
# :class:`StateManager` constructor accepts an explicit override so
# tests can point the manager at an alternate path without environment
# hackery.
DEFAULT_STATE_PATH = pathlib.Path("state/migration.state.json")

# Current State_File schema version. Bumped when the on-disk shape
# changes in a way that older readers cannot handle. Mismatches raise
# :class:`StateError` on load (Requirement 3.4 corrupted-state case).
_SCHEMA_VERSION = 1

# Top-level keys the State_File must contain. Any missing key raises
# :class:`StateError` on load.
_TOP_LEVEL_KEYS: Tuple[str, ...] = ("version", "steps")

# UTC reference used by the default ``now`` callable.
_UTC = datetime.timezone.utc


def _default_now() -> str:
    """Return the current time in ISO 8601 UTC with ``Z`` suffix.

    Format: ``YYYY-MM-DDTHH:MM:SSZ`` (seconds precision; the literal
    ``+00:00`` UTC offset is rewritten to ``Z`` for readability and to
    match the design's example timestamp shape).
    """

    return (
        datetime.datetime.now(_UTC)
        .isoformat(timespec="seconds")
        .replace("+00:00", "Z")
    )


def _default_step_record() -> dict:
    """Return a fresh per-step record with all fields at their defaults.

    The returned dict matches the design's Data Shapes section and is
    used both as the response of :meth:`StateManager.get_step` for
    unknown steps and as the cleared shape produced by
    :meth:`StateManager.reset_step`.
    """

    return {
        "status": Status.PENDING.value,
        "last_run_utc": None,
        "elapsed_seconds": 0.0,
        "last_error_excerpt": None,
        "log_path": None,
    }


# ---------------------------------------------------------------------------
# StateManager
# ---------------------------------------------------------------------------


class StateManager:
    """Read, validate, and atomically persist the Migration_Tool State_File.

    The manager is backed by a single JSON file on disk. Each public
    mutation (:meth:`set_status`, :meth:`reset_step`,
    :meth:`mark_in_progress`, :meth:`mark_completed`,
    :meth:`mark_failed`) re-reads the file, applies the change in
    memory, validates the transition against
    :data:`LEGAL_TRANSITIONS`, and writes the result atomically using
    the same write-temp-then-rename pattern as the config loader. The
    bytes on disk reflect the new state *before* the mutation method
    returns, so a SIGKILL between transitions never corrupts the
    record.

    Construction is cheap and does not touch the filesystem; the first
    :meth:`load` (or any of the mutation helpers, which call
    :meth:`load` internally) reads the file. A missing file is treated
    as ``{"version": 1, "steps": {}}`` and the parent directory is
    created lazily on the first :meth:`save`.
    """

    def __init__(
        self,
        path: Union[pathlib.Path, str] = DEFAULT_STATE_PATH,
        *,
        now: Optional[Callable[[], str]] = None,
    ) -> None:
        self._path: pathlib.Path = pathlib.Path(path)
        self._now: Callable[[], str] = now if now is not None else _default_now

    # ------------------------------------------------------------------
    # Properties
    # ------------------------------------------------------------------

    @property
    def path(self) -> pathlib.Path:
        """Filesystem path of the State_File this manager is bound to."""

        return self._path

    # ------------------------------------------------------------------
    # Load / save
    # ------------------------------------------------------------------

    def load(self) -> dict:
        """Read and validate the State_File, returning the parsed dict.

        Returns the parsed State_File dict. If the file does not exist,
        returns the canonical fresh-state shape
        ``{"version": 1, "steps": {}}`` without writing anything to
        disk; subsequent :meth:`save` calls are responsible for
        creating the file when there is something to persist.

        Raises
        ------
        StateError
            If the file exists but cannot be parsed as JSON, if the
            parsed JSON is not a dict, if any of the required top-level
            keys (``version``, ``steps``) is missing, if ``version``
            does not equal :data:`_SCHEMA_VERSION`, or if ``steps`` is
            not a JSON object.
        """

        if not self._path.exists():
            return {"version": _SCHEMA_VERSION, "steps": {}}

        try:
            raw = self._path.read_text(encoding="utf-8")
        except OSError as exc:
            raise StateError(
                f"Failed to read State_File at {self._path}: {exc}",
                context={"path": str(self._path)},
            ) from exc

        try:
            data = json.loads(raw) if raw.strip() else {}
        except json.JSONDecodeError as exc:
            raise StateError(
                f"State_File at {self._path} is not valid JSON: {exc.msg} "
                f"(line {exc.lineno}, column {exc.colno})",
                context={"path": str(self._path)},
            ) from exc

        if not isinstance(data, dict):
            raise StateError(
                f"State_File at {self._path} must contain a JSON object "
                f"at the top level (got {type(data).__name__})",
                context={"path": str(self._path)},
            )

        # An empty file (after ``raw.strip()`` short-circuits to ``{}``
        # above) is treated the same as a missing file: return the
        # canonical fresh-state shape so callers do not have to handle
        # an empty-dict edge case.
        if not data:
            return {"version": _SCHEMA_VERSION, "steps": {}}

        for key in _TOP_LEVEL_KEYS:
            if key not in data:
                raise StateError(
                    f"State_File at {self._path} is missing required "
                    f"top-level key '{key}'",
                    context={"path": str(self._path), "key": key},
                )

        if data["version"] != _SCHEMA_VERSION:
            raise StateError(
                f"State_File at {self._path} has unsupported version "
                f"{data['version']!r}; expected {_SCHEMA_VERSION}",
                context={
                    "path": str(self._path),
                    "version": data["version"],
                },
            )

        if not isinstance(data["steps"], dict):
            raise StateError(
                f"State_File at {self._path} 'steps' must be a JSON object "
                f"(got {type(data['steps']).__name__})",
                context={"path": str(self._path)},
            )

        return data

    def save(self, data: dict) -> None:
        """Atomically persist ``data`` to the State_File.

        The write goes to ``<path>.tmp`` first, is fsync'd, and then
        ``os.replace``'d into place. ``os.replace`` is atomic on POSIX
        and on modern Windows when the source and destination live on
        the same filesystem (which they always do here, because both
        share the same parent directory). The parent directory is
        created if missing so the very first ``save`` on a fresh
        checkout does not require the caller to pre-create
        ``state/``.
        """

        if not isinstance(data, dict):
            raise StateError(
                "State data must be a dict",
                context={"type": type(data).__name__},
            )

        parent = self._path.parent
        # The default ``state/migration.state.json`` lives directly
        # under ``state/``; the lone empty parent (``""``) of a path
        # like ``"migration.state.json"`` would still mkdir the
        # current directory, which is harmless.
        parent.mkdir(parents=True, exist_ok=True)

        tmp_path = self._path.with_name(self._path.name + ".tmp")
        # Stable formatting for human-readable diffs. ``sort_keys`` is
        # deliberately left at default (False) so step ordering inside
        # ``steps`` is preserved as inserted, which matches the order
        # in which the orchestrator visits steps.
        encoded = json.dumps(data, indent=2) + "\n"

        with open(tmp_path, "w", encoding="utf-8") as fh:
            fh.write(encoded)
            fh.flush()
            os.fsync(fh.fileno())

        os.replace(tmp_path, self._path)

    # ------------------------------------------------------------------
    # Per-step queries
    # ------------------------------------------------------------------

    def get_step(self, step_id: str) -> dict:
        """Return the per-step record for ``step_id``.

        If the step is unknown to the State_File (either because the
        file does not exist or because the file has no entry for this
        step), returns a fresh default record:

        ``{"status":"pending","last_run_utc":None,"elapsed_seconds":0.0,
        "last_error_excerpt":None,"log_path":None}``.

        The returned dict is always a fresh copy, so callers can mutate
        it without affecting the State_File or other in-memory state.
        """

        data = self.load()
        step = data["steps"].get(step_id)
        if step is None:
            return _default_step_record()
        # Return a shallow copy so the caller cannot accidentally mutate
        # the dict we just parsed off disk.
        return dict(step)

    def is_failed_present(self) -> bool:
        """Return ``True`` iff any step in the State_File has status ``failed``.

        Used by the orchestrator's halt-after-failed gate so subsequent
        steps do not run after a prior step's bash script has exited
        non-zero (Requirement 3.4 halt half).
        """

        data = self.load()
        for step in data["steps"].values():
            if isinstance(step, dict) and step.get("status") == Status.FAILED.value:
                return True
        return False

    # ------------------------------------------------------------------
    # Mutations
    # ------------------------------------------------------------------

    def set_status(
        self,
        step_id: str,
        new_status: Status,
        *,
        last_run_utc: Optional[str] = None,
        elapsed_seconds: Optional[float] = None,
        last_error_excerpt: Optional[str] = None,
        log_path: Optional[str] = None,
    ) -> None:
        """Transition ``step_id`` to ``new_status`` and persist atomically.

        Only fields explicitly passed are updated; the rest of the
        per-step record is preserved. The transition is validated
        against :data:`LEGAL_TRANSITIONS`; an illegal transition raises
        :class:`StateError` without touching the State_File.

        Parameters
        ----------
        step_id : str
            The step identifier (for example ``"01_create-smus-domain"``).
        new_status : Status
            The new status value. Must be a :class:`Status` member; raw
            strings are rejected with :class:`StateError`.
        last_run_utc, elapsed_seconds, last_error_excerpt, log_path
            Optional per-step record fields to update. Only fields
            whose argument is *not* ``None`` are written; passing
            ``None`` (the default) preserves the prior value. Callers
            that need to *clear* a field should use :meth:`reset_step`
            (which clears every field) or call :meth:`save` directly
            with a hand-built record.

        Raises
        ------
        StateError
            On an illegal transition, an unknown status type, or a
            corrupted State_File.
        """

        if not isinstance(new_status, Status):
            raise StateError(
                f"new_status must be a Status enum member, got "
                f"{type(new_status).__name__}",
                context={"step_id": step_id},
            )

        data = self.load()
        existing = data["steps"].get(step_id)

        if existing is None:
            current = Status.PENDING
            record = _default_step_record()
        else:
            try:
                current = Status(existing.get("status"))
            except ValueError as exc:
                raise StateError(
                    f"State_File entry for step '{step_id}' has unknown "
                    f"status {existing.get('status')!r}",
                    context={"step_id": step_id},
                ) from exc
            record = dict(existing)

        if (current, new_status) not in LEGAL_TRANSITIONS:
            raise StateError(
                f"Illegal state transition for step '{step_id}': "
                f"{current.value} -> {new_status.value}",
                context={
                    "step_id": step_id,
                    "from": current.value,
                    "to": new_status.value,
                },
            )

        record["status"] = new_status.value
        if last_run_utc is not None:
            record["last_run_utc"] = last_run_utc
        if elapsed_seconds is not None:
            record["elapsed_seconds"] = float(elapsed_seconds)
        if last_error_excerpt is not None:
            record["last_error_excerpt"] = last_error_excerpt
        if log_path is not None:
            record["log_path"] = log_path

        data["steps"][step_id] = record
        self.save(data)

    def reset_step(self, step_id: str) -> None:
        """Reset ``step_id`` to ``pending`` and clear its run metadata.

        Sets the step's status to :attr:`Status.PENDING` and clears
        ``last_run_utc``, ``elapsed_seconds``, ``last_error_excerpt``,
        and ``log_path``. This is the ``--reset`` implementation hook
        and bypasses the transition check (so a ``completed`` or
        ``failed`` step can be returned to ``pending`` regardless of
        :data:`LEGAL_TRANSITIONS`).

        Idempotent: resetting an unknown or already-pending step
        produces the canonical fresh record without raising.
        """

        data = self.load()
        data["steps"][step_id] = _default_step_record()
        self.save(data)

    def mark_in_progress(self, step_id: str, *, log_path: str) -> None:
        """Set ``step_id`` to ``in_progress``, stamp the run, persist.

        Convenience wrapper around :meth:`set_status` that fills in
        ``last_run_utc`` from the manager's ``now`` callable and the
        provided ``log_path``. The transition is validated; calling
        this method on a ``completed`` or ``failed`` step is allowed
        (re-run with ``--force`` or ``--reset`` semantics), but any
        other source state raises :class:`StateError`.
        """

        self.set_status(
            step_id,
            Status.IN_PROGRESS,
            last_run_utc=self._now(),
            log_path=log_path,
        )

    def mark_completed(
        self,
        step_id: str,
        *,
        elapsed_seconds: float,
        log_path: str,
    ) -> None:
        """Set ``step_id`` to ``completed`` and persist atomically.

        Convenience wrapper around :meth:`set_status` that records the
        elapsed wall-clock time and the path of the run log. The prior
        ``last_error_excerpt`` is cleared so a re-run that succeeds
        does not surface stale error text in summary reports
        (Requirement 4.4).

        Raises :class:`StateError` if the step is not in
        :attr:`Status.IN_PROGRESS` (the only legal predecessor for
        ``completed``).
        """

        # ``set_status`` only writes fields whose argument is not
        # ``None``, so to clear ``last_error_excerpt`` we have to read
        # the record, mutate, and re-save through ``save`` so the
        # transition check still runs first.
        data = self.load()
        existing = data["steps"].get(step_id)
        if existing is None:
            current = Status.PENDING
        else:
            try:
                current = Status(existing.get("status"))
            except ValueError as exc:
                raise StateError(
                    f"State_File entry for step '{step_id}' has unknown "
                    f"status {existing.get('status')!r}",
                    context={"step_id": step_id},
                ) from exc

        if (current, Status.COMPLETED) not in LEGAL_TRANSITIONS:
            raise StateError(
                f"Illegal state transition for step '{step_id}': "
                f"{current.value} -> {Status.COMPLETED.value}",
                context={
                    "step_id": step_id,
                    "from": current.value,
                    "to": Status.COMPLETED.value,
                },
            )

        record = dict(existing) if existing is not None else _default_step_record()
        record["status"] = Status.COMPLETED.value
        record["elapsed_seconds"] = float(elapsed_seconds)
        record["log_path"] = log_path
        record["last_error_excerpt"] = None

        data["steps"][step_id] = record
        self.save(data)

    def mark_failed(
        self,
        step_id: str,
        *,
        elapsed_seconds: float,
        last_error_excerpt: str,
        log_path: str,
    ) -> None:
        """Set ``step_id`` to ``failed`` and record the failure metadata.

        Convenience wrapper around :meth:`set_status`. The caller is
        responsible for truncating ``last_error_excerpt`` to the last
        50 lines of stderr per Requirement 3.4.

        Raises :class:`StateError` if the step is not in
        :attr:`Status.IN_PROGRESS` (the only legal predecessor for
        ``failed``).
        """

        self.set_status(
            step_id,
            Status.FAILED,
            elapsed_seconds=elapsed_seconds,
            last_error_excerpt=last_error_excerpt,
            log_path=log_path,
        )
