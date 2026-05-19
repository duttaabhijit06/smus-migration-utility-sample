"""Append-only run logger for the SageMaker Migration Tool.

This module implements Requirements 4.1, 4.2, and 4.3:

* **4.1** — every CLI invocation gets one ``logs/run-<UTC>.log`` file
  whose UTC timestamp uses the filesystem-friendly format
  ``YYYY-MM-DDTHH-MM-SSZ`` (colons replaced with hyphens so the path is
  portable across operating systems).
* **4.2** — every executed AWS CLI command record carries the full
  (redacted) command line, the truncated stdout (≤ 4096 bytes), the
  truncated stderr (≤ 4096 bytes), the exit code, and the elapsed time
  in milliseconds.
* **4.3** — in Dry_Run_Mode, the command line is emitted with a
  ``DRY-RUN: `` prefix and *no* stdout/stderr/exit/elapsed lines are
  written, because nothing actually ran.

Every command line and every line of the captured stdout/stderr blocks
is passed through :func:`migration_tool.redact.redact` before it is
written to disk, so secret-shaped values (Requirement 4.5) never reach
the run log.

The module uses only Python's standard library (``datetime``,
``pathlib``) plus the in-tree :mod:`migration_tool.redact` module.

Validates: Requirements 4.1, 4.2, 4.3.
"""

from __future__ import annotations

import datetime
import pathlib
from typing import Callable, Optional, Union

from migration_tool.redact import redact

__all__ = ["RunLogger"]


# UTC reference used for both the filename timestamp and the inline
# timestamp prefix that appears at the head of every record.
_UTC = datetime.timezone.utc

# Filesystem-friendly UTC timestamp used in the log file name. The task
# spec mandates the literal pattern ``YYYY-MM-DDTHH-MM-SSZ`` (hyphens
# rather than colons between hours/minutes/seconds) so the path is
# portable across operating systems whose filesystems disallow ``:``.
_FILENAME_STAMP_FMT = "%Y-%m-%dT%H-%M-%SZ"

# Inline timestamp used at the head of every record (e.g.
# ``[2026-05-04T18:22:11Z]``). Colons are fine here because this is
# the text body of a log line, not a filename.
_INLINE_STAMP_FMT = "%Y-%m-%dT%H:%M:%SZ"

# Maximum bytes of stdout/stderr captured per record (Requirement 4.2).
_MAX_CAPTURE_BYTES = 4096

# Indent applied to every line of the truncated stdout/stderr blocks.
# Matches the example in the design document where the body of each
# block is rendered four spaces from the left margin.
_BLOCK_INDENT = "    "

# Default ``now`` provider — a single canonical function that returns a
# tz-aware UTC datetime. Hoisted out so tests can monkey-patch the
# module attribute or, better, pass a custom ``now`` callable directly
# to the :class:`RunLogger` constructor.


def _default_now() -> datetime.datetime:
    """Return the current time as a tz-aware UTC ``datetime``."""

    return datetime.datetime.now(_UTC)


def _to_utc(stamp: datetime.datetime) -> datetime.datetime:
    """Coerce ``stamp`` to a tz-aware UTC ``datetime``.

    A naive ``datetime`` is assumed to already be in UTC (the default
    ``now`` provider always produces tz-aware UTC values; this branch
    only exists to defend against a test injecting a naive value).
    """

    if stamp.tzinfo is None:
        return stamp.replace(tzinfo=_UTC)
    return stamp.astimezone(_UTC)


class RunLogger:
    """Append-only run logger writing to ``<workdir>/logs/run-<UTC>.log``.

    The logger opens its log file in append mode at construction time,
    so the file is created (and the parent ``logs/`` directory is
    materialized) before the first record is written. Records are
    appended via :meth:`record_command` (per-AWS-CLI-invocation) and
    :meth:`log_event` (orchestrator-level events such as ``STATUS:``
    forwards from a step's ``run.sh``).

    The logger participates in the context-manager protocol so the
    typical use is::

        with RunLogger(workdir, dry_run=False) as logger:
            logger.record_command("04_catalog", "aws datazone ...", ...)

    On ``__exit__`` the underlying file is flushed and closed.
    """

    def __init__(
        self,
        workdir: Union[pathlib.Path, str, None] = None,
        *,
        dry_run: bool,
        now: Optional[Callable[[], datetime.datetime]] = None,
    ) -> None:
        """Open the run log file.

        Parameters
        ----------
        workdir:
            Root working directory. The log file is written under
            ``<workdir>/logs/``. Defaults to the current working
            directory when ``None``.
        dry_run:
            When ``True``, :meth:`record_command` writes only a single
            ``DRY-RUN: `` line per command (Requirement 4.3). When
            ``False``, the full multi-line apply-mode record is
            written (Requirement 4.2).
        now:
            Optional zero-argument callable returning the current
            ``datetime``. Provided for test injection. Defaults to
            ``datetime.datetime.now(datetime.timezone.utc)``.
        """

        self._dry_run = bool(dry_run)
        self._now: Callable[[], datetime.datetime] = (
            now if now is not None else _default_now
        )

        # Resolve the working directory. ``Path.cwd()`` is evaluated
        # lazily (here, not at module import) so test runners that
        # ``chdir`` into a temp dir get the right root.
        if workdir is None:
            self._workdir = pathlib.Path.cwd().resolve()
        else:
            self._workdir = pathlib.Path(workdir).resolve()

        # Compute the log file name from the construction timestamp.
        # The constructor explicitly opens in append mode, so a second
        # ``RunLogger`` constructed in the same UTC second simply
        # reopens the same file — which is correct: both invocations
        # belong to "the same second" and append-only semantics keep
        # the records ordered.
        construct_stamp = _to_utc(self._now())
        filename = "run-" + construct_stamp.strftime(_FILENAME_STAMP_FMT) + ".log"

        logs_dir = self._workdir / "logs"
        logs_dir.mkdir(parents=True, exist_ok=True)
        self._log_path = (logs_dir / filename).resolve()

        # Append mode + UTF-8 text. ``newline=""`` is intentionally
        # omitted: this is plain-text logging, not CSV.
        self._fh = open(self._log_path, "a", encoding="utf-8")

    # ------------------------------------------------------------------
    # Public surface
    # ------------------------------------------------------------------

    @property
    def log_path(self) -> pathlib.Path:
        """Absolute path of the log file this logger is writing to."""

        return self._log_path

    def __enter__(self) -> "RunLogger":
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()

    def close(self) -> None:
        """Flush and close the underlying log file (idempotent)."""

        if not self._fh.closed:
            try:
                self._fh.flush()
            finally:
                self._fh.close()

    def record_command(
        self,
        step_id: str,
        cmd: str,
        *,
        stdout: Union[bytes, str, None] = None,
        stderr: Union[bytes, str, None] = None,
        exit_code: Optional[int] = None,
        elapsed_ms: Optional[int] = None,
    ) -> None:
        """Append one per-command record to the run log.

        In Dry_Run_Mode (``dry_run=True``) the record is a single line
        of the form::

            [<UTC>] step=<step_id> cmd="DRY-RUN: <redacted-cmd>"

        with no stdout/stderr/exit/elapsed lines, per Requirement 4.3.

        In Apply_Mode (``dry_run=False``) the record spans multiple
        lines per Requirement 4.2::

            [<UTC>] step=<step_id> cmd="<redacted-cmd>"
              stdout (4096 bytes max):
                <redacted, truncated stdout>
              stderr (4096 bytes max):
                <redacted, truncated stderr>
              exit=<exit_code> elapsed_ms=<elapsed_ms>

        Both ``stdout`` and ``stderr`` are truncated to at most
        ``4096`` bytes each. ``bytes`` inputs are decoded as UTF-8 with
        ``errors="replace"`` before truncation. ``None`` or empty
        inputs render as a single empty (indented) placeholder line so
        the block is always present and aligned.

        Every line of the command and of the truncated stdout/stderr
        blocks is passed through :func:`migration_tool.redact.redact`
        before being written.
        """

        stamp = _to_utc(self._now()).strftime(_INLINE_STAMP_FMT)
        redacted_cmd = redact(cmd)

        if self._dry_run:
            # Dry-run records are a single line — no captured output
            # is possible because nothing actually executed.
            line = f'[{stamp}] step={step_id} cmd="DRY-RUN: {redacted_cmd}"\n'
            self._fh.write(line)
            self._fh.flush()
            return

        # Apply-mode: full multi-line record.
        stdout_block = self._format_stream_block(stdout)
        stderr_block = self._format_stream_block(stderr)

        record = (
            f'[{stamp}] step={step_id} cmd="{redacted_cmd}"\n'
            f"  stdout (4096 bytes max):\n"
            f"{stdout_block}\n"
            f"  stderr (4096 bytes max):\n"
            f"{stderr_block}\n"
            f"  exit={exit_code} elapsed_ms={elapsed_ms}\n"
        )
        self._fh.write(record)
        self._fh.flush()

    def log_event(self, message: str, *, step_id: str = "system") -> None:
        """Append one orchestrator-level event line to the run log.

        Used for ``STATUS:`` forwards from a step's ``run.sh`` and for
        bookkeeping events the orchestrator emits directly. ``step_id``
        defaults to ``"system"`` for orchestrator-level events.
        """

        stamp = _to_utc(self._now()).strftime(_INLINE_STAMP_FMT)
        redacted = redact(message)
        line = f'[{stamp}] step={step_id} event="{redacted}"\n'
        self._fh.write(line)
        self._fh.flush()

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _decode_and_truncate(data: Union[bytes, str, None]) -> str:
        """Decode and truncate a stdout/stderr capture to ≤ 4096 bytes.

        ``bytes`` inputs are sliced at the byte boundary first and then
        decoded as UTF-8 with ``errors="replace"`` so a truncation
        mid-multibyte-character cannot raise. ``str`` inputs are
        encoded to bytes for the same byte-accurate truncation, then
        decoded back. ``None`` and the empty string both produce an
        empty result.
        """

        if data is None or data == "" or data == b"":
            return ""
        if isinstance(data, bytes):
            return data[:_MAX_CAPTURE_BYTES].decode("utf-8", errors="replace")
        # ``str`` path — re-encode so the truncation is in bytes, not
        # Python characters, matching the Requirement 4.2 contract
        # ("first 4 KB" measured in bytes).
        encoded = data.encode("utf-8", errors="replace")
        return encoded[:_MAX_CAPTURE_BYTES].decode("utf-8", errors="replace")

    @classmethod
    def _format_stream_block(cls, data: Union[bytes, str, None]) -> str:
        """Build the indented, redacted body that follows a stream header.

        Each non-empty line of the truncated capture is redacted and
        prefixed with the standard 4-space block indent. ``None`` /
        empty captures render as a single bare-indent placeholder line
        so the block remains visually aligned with apply-mode records
        that *do* carry output.
        """

        text = cls._decode_and_truncate(data)
        if text == "":
            # Empty placeholder line under the header.
            return _BLOCK_INDENT
        lines = text.splitlines() or [""]
        return "\n".join(_BLOCK_INDENT + redact(line) for line in lines)
