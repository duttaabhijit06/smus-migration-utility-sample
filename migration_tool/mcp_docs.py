"""AWS Documentation MCP cache reader/writer.

This module owns the on-disk documentation cache that backs every
Step_Module README citation. It runs in two distinct contexts:

* **Scaffold time** — when a step's README is generated, the README
  generator calls :func:`fetch_or_cache`. On a cache miss the supplied
  ``fetcher`` callable contacts the AWS Documentation MCP server and
  returns ``(title, content_md)``; the result is written to the cache
  atomically. On a cache hit the fetcher is never invoked.
* **Runtime** — during a migration run the orchestrator never calls
  the MCP server. It calls :func:`read_cached` and treats the cache as
  the source of truth. If a URL is missing from the cache at runtime,
  the caller (typically a step's README generator script) is
  responsible for invoking :func:`fetch_or_cache` instead, so the
  cache stays the only runtime path.

The cache layout is fixed by the design:

* Cache directory: ``docs/cache/`` (relative to the repository root,
  pre-created in Task 1.1 with a ``.gitkeep`` placeholder).
* Per-URL cache key: ``sha256(url.encode("utf-8")).hexdigest()[:16]``
  (16 hex characters).
* Per-URL cache file: ``docs/cache/<key>.json`` with the record
  schema::

      {
        "url": str,                # source URL
        "fetched_utc": str,        # ISO 8601 UTC, ends in "Z"
        "title": str,              # human-readable page title
        "content_md": str          # cached markdown content
      }

Atomic writes follow the standard write-temp-then-rename pattern: the
record is serialized to ``<key>.json.tmp`` in the same directory,
``os.fsync`` is called on the file descriptor before close, and
``os.replace`` swaps the temp file into the final path. ``os.replace``
is atomic on POSIX and on Windows, so a SIGKILL in the middle of a
write can never leave a half-written ``<key>.json`` on disk.

The module uses only Python's standard library and does not import
from any other ``migration_tool`` module, so it is safe to import from
any layer of the orchestrator and from the scaffold-time README
generator alike.

Validates: Requirements 6.1, 6.2, 6.3.
"""

from __future__ import annotations

import datetime
import hashlib
import json
import os
import pathlib
from typing import Any, Callable, Dict, Optional, Union

__all__ = [
    "cache_key",
    "cache_path",
    "read_cached",
    "write_cached",
    "fetch_or_cache",
]


# Default cache directory, relative to the repository root. Callers
# may override this via the ``cache_dir`` keyword on every public
# function. Kept as a string here so it composes cleanly with both
# ``str`` and ``pathlib.Path`` overrides.
_DEFAULT_CACHE_DIR = "docs/cache"

# Length of the truncated sha256 hex digest used as the cache key.
# 16 hex characters = 64 bits of entropy, more than enough to avoid
# collisions across the documentation URLs the tool consumes.
_CACHE_KEY_LENGTH = 16

# Type alias for the ``fetcher`` callable accepted by
# :func:`fetch_or_cache`. The fetcher takes a URL and returns the
# pair ``(title, content_md)``.
FetcherCallable = Callable[[str], "tuple[str, str]"]

# Type alias for the optional ``now`` callable. When supplied it must
# return an aware ``datetime.datetime`` in UTC; tests inject a fixed
# clock through this parameter so timestamps are deterministic.
NowCallable = Callable[[], datetime.datetime]


def _default_now() -> datetime.datetime:
    """Return the current time as an aware UTC ``datetime``.

    Wrapped in a private helper so :func:`write_cached` and
    :func:`fetch_or_cache` can default ``now`` to ``None`` and still
    produce a deterministic, testable call site.
    """
    return datetime.datetime.now(datetime.timezone.utc)


def _format_iso_utc(value: datetime.datetime) -> str:
    """Render ``value`` as ISO 8601 UTC with a trailing ``Z``.

    The implementation note pins the format to seconds precision and
    requires the trailing ``Z`` rather than ``+00:00``, matching the
    timestamp shape used elsewhere in the tool (run logs, state file,
    inventory outputs).
    """
    # ``isoformat(timespec="seconds")`` yields ``2026-05-04T18:22:11+00:00``
    # for a UTC-aware datetime; replacing the suffix gives the desired
    # ``...Z`` form.
    return value.isoformat(timespec="seconds").replace("+00:00", "Z")


def _coerce_cache_dir(cache_dir: Union[pathlib.Path, str]) -> pathlib.Path:
    """Coerce a ``str`` or ``Path`` cache directory to ``Path``."""
    if isinstance(cache_dir, pathlib.Path):
        return cache_dir
    return pathlib.Path(cache_dir)


def cache_key(url: str) -> str:
    """Return the 16-character sha256 hex digest used as the cache key.

    The key is deterministic, depends only on the URL bytes, and is
    short enough to be used directly as a filename component on every
    target filesystem.

    Validates: Requirement 6.2.
    """
    digest = hashlib.sha256(url.encode("utf-8")).hexdigest()
    return digest[:_CACHE_KEY_LENGTH]


def cache_path(
    url: str,
    cache_dir: Union[pathlib.Path, str] = _DEFAULT_CACHE_DIR,
) -> pathlib.Path:
    """Return the absolute path to the per-URL cache file.

    Resolves the cache directory to an absolute path before composing
    the per-URL filename so callers receive the same path shape
    regardless of the current working directory.

    Validates: Requirement 6.2.
    """
    base = _coerce_cache_dir(cache_dir).resolve()
    return base / f"{cache_key(url)}.json"


def read_cached(
    url: str,
    cache_dir: Union[pathlib.Path, str] = _DEFAULT_CACHE_DIR,
) -> Optional[Dict[str, Any]]:
    """Return the parsed cache record for ``url``, or ``None`` on miss.

    A missing file is the cache miss signal and returns ``None``. A
    file that exists but cannot be parsed as JSON raises
    :class:`ValueError`; we want noisy failure on a corrupted cache so
    the caller (a scaffold-time README generator or a test harness)
    can surface the corruption instead of silently re-fetching.

    Validates: Requirements 6.1, 6.2.
    """
    path = cache_path(url, cache_dir=cache_dir)
    if not path.exists():
        return None
    raw = path.read_text(encoding="utf-8")
    try:
        record = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValueError(
            f"Corrupted MCP cache record at {path}: {exc}"
        ) from exc
    if not isinstance(record, dict):
        raise ValueError(
            f"Corrupted MCP cache record at {path}: expected a JSON "
            f"object, got {type(record).__name__}"
        )
    return record


def _atomic_write_json(
    destination: pathlib.Path,
    payload: Dict[str, Any],
) -> None:
    """Write ``payload`` to ``destination`` atomically.

    Implements the standard write-temp-then-rename pattern:
    1. Ensure the destination's parent directory exists.
    2. Serialize to ``<destination>.tmp`` in the same directory so the
       eventual ``os.replace`` is a same-filesystem operation.
    3. Flush and ``os.fsync`` the file descriptor before close so the
       JSON bytes hit the disk surface, not just the page cache.
    4. ``os.replace`` swaps the temp file into the final path
       atomically on POSIX and Windows.
    """
    destination.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = destination.with_suffix(destination.suffix + ".tmp")
    serialized = json.dumps(payload, ensure_ascii=False, indent=2)
    # ``open`` in text mode gives us the same encoding contract as
    # ``read_text`` above; we still need the raw fd to call ``fsync``.
    with open(tmp_path, "w", encoding="utf-8") as fh:
        fh.write(serialized)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp_path, destination)


def write_cached(
    url: str,
    *,
    title: str,
    content_md: str,
    cache_dir: Union[pathlib.Path, str] = _DEFAULT_CACHE_DIR,
    now: Optional[NowCallable] = None,
) -> Dict[str, Any]:
    """Write a cache record for ``url`` atomically and return it.

    The record dict has exactly the four documented keys (``url``,
    ``fetched_utc``, ``title``, ``content_md``) so a successful round
    trip through :func:`read_cached` returns the same shape that was
    written.

    The optional ``now`` callable injects a deterministic clock; when
    omitted it defaults to :func:`datetime.datetime.now` in UTC.

    Validates: Requirement 6.2.
    """
    clock = now if now is not None else _default_now
    record: Dict[str, Any] = {
        "url": url,
        "fetched_utc": _format_iso_utc(clock()),
        "title": title,
        "content_md": content_md,
    }
    _atomic_write_json(cache_path(url, cache_dir=cache_dir), record)
    return record


def fetch_or_cache(
    url: str,
    fetcher: FetcherCallable,
    *,
    cache_dir: Union[pathlib.Path, str] = _DEFAULT_CACHE_DIR,
    now: Optional[NowCallable] = None,
) -> Dict[str, Any]:
    """Return the cache record for ``url``, fetching on miss.

    Order of operations:

    1. Call :func:`read_cached`. If it returns a record, return it
       verbatim without invoking ``fetcher`` (cache hit short-circuit).
    2. Otherwise call ``fetcher(url)`` exactly once. ``fetcher`` is the
       only point at which an MCP server call may be made; the
       orchestrator never calls MCP at runtime, so this code path runs
       only at scaffold time when a step's README is being generated.
    3. Persist the freshly fetched ``(title, content_md)`` pair via
       :func:`write_cached` and return the written record.

    Validates: Requirements 6.1, 6.2.
    """
    cached = read_cached(url, cache_dir=cache_dir)
    if cached is not None:
        return cached
    title, content_md = fetcher(url)
    return write_cached(
        url,
        title=title,
        content_md=content_md,
        cache_dir=cache_dir,
        now=now,
    )
