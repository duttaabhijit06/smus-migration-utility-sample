"""Configuration management for the SageMaker Migration Tool.

This module owns the lifecycle of the Config_File at
``./config/migration.config.json``: schema validation, atomic
persistence, lazy population, and the four provider-aware input
validators consumed by the prompter and CLI surface.

It implements the contract described in design.md ("Config Loader") and
the acceptance criteria of Requirements 2.2-2.11:

* **2.2 / 2.3** — collected values persist to ``config/migration.config.json``
  before any step runs; existing values are loaded on subsequent runs and
  not re-prompted.
* **2.4** — :meth:`ConfigLoader.reconfigure` wipes the file so the
  prompter can re-collect every input.
* **2.5** — :meth:`ConfigLoader.set` updates one key in place without
  prompting for the rest.
* **2.6** — :meth:`ConfigLoader.get` raises :class:`ConfigError`
  (with ``context={"key": <name>}``) when a step demands a value that is
  missing or empty (``None``, ``""``, ``[]``).
* **2.7** — :func:`validate_repo_provider` enforces the closed Repo_Provider
  set ``{codecommit, github, github-enterprise-server, gitlab,
  gitlab-self-managed, bitbucket}``.
* **2.8** — :func:`validate_repo_url` enforces the per-provider regex
  table; ``codecommit`` accepts ``None`` (the URL is filled by Step 1
  from CodeCommit's ``cloneUrlHttp``).
* **2.9** — the codecommit branch defers URL validation to Step 1.
* **2.10** — :func:`validate_aws_region` enforces ``^[a-z]{2}-[a-z]+-\\d$``.
* **2.11** — :func:`validate_account_id` enforces exactly 12 digits.

The module's only third-party dependency is :mod:`jsonschema`
(``Draft202012Validator``); its only in-tree dependency is
:class:`migration_tool.errors.ConfigError`. It does *not* import
``prompts``, ``runner``, ``state``, or any other orchestrator module —
keeping the dependency graph one-directional from prompts/CLI down into
``config``.

Validates: Requirements 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 2.8, 2.9, 2.10,
2.11.
"""

from __future__ import annotations

import json
import os
import pathlib
import re
import urllib.parse
from typing import Any, Optional, Union

from jsonschema import Draft202012Validator

from migration_tool.errors import ConfigError

__all__ = [
    "SCHEMA",
    "ConfigLoader",
    "validate_account_id",
    "validate_aws_region",
    "validate_repo_provider",
    "validate_repo_url",
]


# ---------------------------------------------------------------------------
# Validators
# ---------------------------------------------------------------------------

# The closed Repo_Provider set, ordered to match the Reference_Document
# section "2. Git Connections" and Requirement 2.7. Comparison is
# case-sensitive: ``GitHub`` is not accepted; the prompter is expected
# to supply lowercase tokens.
_REPO_PROVIDERS: tuple[str, ...] = (
    "codecommit",
    "github",
    "github-enterprise-server",
    "gitlab",
    "gitlab-self-managed",
    "bitbucket",
)

# Per-provider URL regexes. Keys exactly match the Repo_Provider tokens
# above. ``codecommit`` is intentionally absent: its URL is supplied by
# Step 1 from CodeCommit's ``cloneUrlHttp`` and is therefore validated
# only as "non-empty string or null" rather than against a pattern
# (Requirement 2.9).
_GITHUB_HTTPS = re.compile(r"^https://github\.com/[^/]+/[^/]+$")
_GITHUB_SSH = re.compile(r"^git@github\.com:[^/]+/[^/]+\.git$")

_GHES_HTTPS_SHAPE = re.compile(r"^https://[^/]+/[^/]+/[^/]+$")

_GITLAB_HTTPS = re.compile(r"^https://gitlab\.com/[^/]+(/[^/]+)+$")
_GITLAB_SM_SHAPE = re.compile(r"^https://[^/]+/[^/]+(/[^/]+)+$")

_BITBUCKET_HTTPS = re.compile(r"^https://bitbucket\.org/[^/]+/[^/]+$")

_AWS_REGION_PATTERN = re.compile(r"^[a-z]{2}-[a-z]+-\d$")
_ACCOUNT_ID_PATTERN = re.compile(r"^\d{12}$")


def validate_repo_provider(value: str) -> bool:
    """Return ``True`` iff ``value`` is one of the six Repo_Provider tokens.

    The match is case-sensitive — the orchestrator stores the canonical
    lowercase token in the Config_File, and the prompter re-prompts on
    any other input (Requirement 2.7).
    """

    return isinstance(value, str) and value in _REPO_PROVIDERS


def validate_repo_url(provider: str, url: Optional[str]) -> bool:
    """Return ``True`` iff ``url`` matches the regex for ``provider``.

    Implements the per-provider URL rules in Requirements 2.8 and 2.9
    (and the design's "Config Loader" provider-aware regex table):

    * ``codecommit`` — accept ``None`` or any string (the URL is filled
      by Step 1 from CodeCommit's ``cloneUrlHttp`` once the repository
      exists).
    * ``github`` — HTTPS form ``https://github.com/<owner>/<repo>`` or
      SSH form ``git@github.com:<owner>/<repo>.git``.
    * ``github-enterprise-server`` — HTTPS three-segment path on a host
      other than ``github.com``.
    * ``gitlab`` — HTTPS path on ``gitlab.com`` with at least two path
      segments (the second segment may itself contain nested
      sub-groups).
    * ``gitlab-self-managed`` — HTTPS path on a host other than
      ``gitlab.com`` with at least two path segments.
    * ``bitbucket`` — HTTPS form ``https://bitbucket.org/<owner>/<repo>``.

    Returns ``False`` for an unknown ``provider`` so callers can rely on
    a single boolean return without an extra ``provider``-shape check.
    """

    if provider == "codecommit":
        # The codecommit branch defers URL validation to Step 1; both
        # a pre-Step-1 ``None`` and any subsequent string (typically a
        # ``cloneUrlHttp`` returned by the AWS API) are accepted.
        return url is None or isinstance(url, str)

    if not isinstance(url, str):
        return False

    if provider == "github":
        return bool(_GITHUB_HTTPS.match(url) or _GITHUB_SSH.match(url))

    if provider == "github-enterprise-server":
        if not _GHES_HTTPS_SHAPE.match(url):
            return False
        host = urllib.parse.urlparse(url).hostname
        return host is not None and host.lower() != "github.com"

    if provider == "gitlab":
        return bool(_GITLAB_HTTPS.match(url))

    if provider == "gitlab-self-managed":
        if not _GITLAB_SM_SHAPE.match(url):
            return False
        host = urllib.parse.urlparse(url).hostname
        return host is not None and host.lower() != "gitlab.com"

    if provider == "bitbucket":
        return bool(_BITBUCKET_HTTPS.match(url))

    # Unknown provider — refuse rather than fall through.
    return False


def validate_aws_region(value: str) -> bool:
    """Return ``True`` iff ``value`` matches ``^[a-z]{2}-[a-z]+-\\d$``.

    Implements Requirement 2.10. The validator is intentionally lenient
    on the *content* of the region (it does not check that the partition
    or region code actually exists), only on the *shape* — AWS adds new
    regions regularly and a stricter allowlist would go stale.
    """

    return isinstance(value, str) and bool(_AWS_REGION_PATTERN.match(value))


def validate_account_id(value: str) -> bool:
    """Return ``True`` iff ``value`` is a 12-digit account ID.

    Implements Requirement 2.11. The validator accepts only ASCII
    digits; whitespace, hyphens, and other separators cause a refusal.
    """

    return isinstance(value, str) and bool(_ACCOUNT_ID_PATTERN.match(value))


# ---------------------------------------------------------------------------
# JSON Schema
# ---------------------------------------------------------------------------

# The on-disk Config_File schema. The schema is permissive at the top
# level — every key is optional, because the file is populated lazily
# across runs as steps demand new values (Requirement 2.6 governs the
# "required at use time" half of that contract). Per-key shape is
# enforced via ``type``, ``enum``, and ``pattern`` so callers can rely
# on ``ConfigLoader.load`` returning a dict whose values either match
# the documented shape or are absent.
SCHEMA: dict[str, Any] = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "title": "SageMaker Migration Tool Config_File",
    "type": "object",
    "additionalProperties": True,
    "properties": {
        "repo_provider": {
            "type": "string",
            "enum": list(_REPO_PROVIDERS),
        },
        "repo_url": {
            "type": ["string", "null"],
        },
        "repo_name": {
            "type": ["string", "null"],
        },
        "codecommit_repo_arn": {
            "type": ["string", "null"],
        },
        "aws_region": {
            "type": "string",
            "pattern": r"^[a-z]{2}-[a-z]+-\d$",
        },
        "source_account_id": {
            "type": "string",
            "pattern": r"^\d{12}$",
        },
        "identity_center_instance_arn": {
            "type": "string",
        },
        "identity_center_identity_store_id": {
            "type": "string",
        },
        "smus_domain_name": {
            "type": "string",
        },
        "smus_domain_id": {
            "type": ["string", "null"],
        },
        "domain_service_role": {
            "type": ["string", "null"],
        },
        "admin_project_name": {
            "type": "string",
        },
        "admin_project_id": {
            "type": ["string", "null"],
        },
        "git_connection_id": {
            "type": ["string", "null"],
        },
        "mwaa_environment_name": {
            "type": "string",
        },
        "mwaa_dag_bucket_name": {
            "type": "string",
        },
        "source_s3_inclusion_list": {
            "type": "array",
            "items": {"type": "string"},
        },
        "smus_managed_s3_root": {
            "type": ["string", "null"],
        },
        "tooling_environment_id": {
            "type": ["string", "null"],
        },
        "tooling_user_role_arn": {
            "type": ["string", "null"],
        },
        "lakehouse_environment_id": {
            "type": ["string", "null"],
        },
        "lakehouse_glue_db_name": {
            "type": ["string", "null"],
        },
        "lakehouse_connection_id": {
            "type": ["string", "null"],
        },
    },
}


# Module-level validator instance. ``Draft202012Validator`` is cheap to
# construct but the cost is non-zero, so we cache it. ``check_schema``
# raises ``SchemaError`` at import time if SCHEMA itself is malformed,
# turning a typo here into a fast import-time failure rather than a
# late surprise during the first ``load()``.
Draft202012Validator.check_schema(SCHEMA)
_VALIDATOR = Draft202012Validator(SCHEMA)


def _json_pointer(absolute_path: Any) -> str:
    """Render a jsonschema ``absolute_path`` as a JSON Pointer (RFC 6901).

    ``absolute_path`` is a ``deque`` of path components (``str`` for
    object keys, ``int`` for array indices). An empty path points at
    the document root and is rendered as ``""`` per RFC 6901, but the
    caller hoists the offending top-level key into ``context["key"]``
    when one exists so this function only needs to produce the
    ``/``-joined form.
    """

    parts = []
    for part in absolute_path:
        # RFC 6901 token escaping: ``~`` -> ``~0``, ``/`` -> ``~1``.
        token = str(part).replace("~", "~0").replace("/", "~1")
        parts.append(token)
    return "/" + "/".join(parts) if parts else ""


# ---------------------------------------------------------------------------
# ConfigLoader
# ---------------------------------------------------------------------------

# Default Config_File path, relative to the working directory. The
# ``ConfigLoader`` constructor accepts an explicit override so tests
# (and the eventual ``--config`` CLI flag, if added) can point the
# loader at an alternate path without environment hackery.
DEFAULT_CONFIG_PATH = pathlib.Path("config/migration.config.json")


class ConfigLoader:
    """Read, validate, and persist the Migration_Tool Config_File.

    The loader is backed by a single JSON file on disk. The in-memory
    representation is a plain ``dict`` whose keys correspond to the
    SCHEMA properties; absent keys are simply absent from the dict
    (rather than mapped to ``None``), which is what
    :meth:`get` distinguishes from explicitly-null values when raising
    :class:`ConfigError` for missing required values.

    Construction is cheap and does not touch the filesystem. The first
    call to :meth:`load`, :meth:`get`, or :meth:`set` reads the file
    if it exists; if it does not, the loader treats the in-memory
    config as ``{}`` and remembers that no on-disk file has been
    written yet so :meth:`save` (and :meth:`set`, which calls it) will
    create the parent directories.
    """

    def __init__(
        self,
        path: Union[pathlib.Path, str] = DEFAULT_CONFIG_PATH,
    ) -> None:
        self._path: pathlib.Path = pathlib.Path(path)
        self._data: Optional[dict[str, Any]] = None
        # ``True`` once :meth:`load` has populated ``self._data`` (or
        # initialized it to ``{}`` for a missing file). Used to gate
        # lazy loading inside :meth:`get` / :meth:`set` without
        # forcing every caller to invoke :meth:`load` explicitly.
        self._loaded: bool = False

    # ------------------------------------------------------------------
    # Properties
    # ------------------------------------------------------------------

    @property
    def path(self) -> pathlib.Path:
        """Filesystem path of the Config_File this loader is bound to."""

        return self._path

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def load(self) -> dict[str, Any]:
        """Read the Config_File from disk and validate it.

        Returns the validated config dict. If the file does not exist,
        returns ``{}`` and remembers "no file yet" so subsequent
        :meth:`save` calls create the parent directories.

        Raises
        ------
        ConfigError
            If the file exists but cannot be parsed as JSON, or if the
            parsed JSON does not match :data:`SCHEMA`. The exception's
            ``context`` dict carries the offending top-level key (when
            available) and the JSON Pointer to the failing node.
        """

        if not self._path.exists():
            self._data = {}
            self._loaded = True
            return {}

        try:
            raw = self._path.read_text(encoding="utf-8")
        except OSError as exc:
            # Surface as a ConfigError so the orchestrator's
            # top-level handler can format it consistently with other
            # config-layer failures.
            raise ConfigError(
                f"Failed to read Config_File at {self._path}: {exc}",
                context={"path": str(self._path)},
            ) from exc

        try:
            data = json.loads(raw) if raw.strip() else {}
        except json.JSONDecodeError as exc:
            raise ConfigError(
                f"Config_File at {self._path} is not valid JSON: {exc.msg} "
                f"(line {exc.lineno}, column {exc.colno})",
                context={"path": str(self._path)},
            ) from exc

        if not isinstance(data, dict):
            raise ConfigError(
                f"Config_File at {self._path} must contain a JSON object "
                f"at the top level (got {type(data).__name__})",
                context={"path": str(self._path)},
            )

        self._validate(data)

        self._data = data
        self._loaded = True
        return data

    def save(self, data: dict[str, Any]) -> None:
        """Atomically persist ``data`` to the Config_File.

        The write goes to ``<path>.tmp`` first, is fsync'd, and then
        ``os.replace``'d into place. ``os.replace`` is atomic on POSIX
        and on modern Windows when the source and destination live on
        the same filesystem (which they always do here, because both
        share the same parent directory). The parent directory is
        created if missing so the very first ``save`` on a fresh
        checkout does not require the caller to pre-create
        ``config/``.

        Updates the in-memory cache so a subsequent ``get`` reflects
        the new values without an explicit ``load``.
        """

        if not isinstance(data, dict):
            raise ConfigError(
                "Config data must be a dict",
                context={"type": type(data).__name__},
            )

        # Validate before touching the disk so a bad payload does not
        # produce a partial or invalid file.
        self._validate(data)

        parent = self._path.parent
        parent.mkdir(parents=True, exist_ok=True)

        tmp_path = self._path.with_name(self._path.name + ".tmp")
        # Encode with stable formatting so diffs across runs stay
        # readable. ``sort_keys=True`` makes the on-disk byte order
        # deterministic for any given dict, which simplifies tests
        # that compare Config_File bytes across runs.
        encoded = json.dumps(data, indent=2, sort_keys=True) + "\n"

        # Write + fsync the tmp file, then atomically swap it into
        # place. The fsync ensures the bytes are on disk before
        # ``os.replace`` so a crash between rename and flush cannot
        # leave a zero-byte file under the canonical name.
        with open(tmp_path, "w", encoding="utf-8") as fh:
            fh.write(encoded)
            fh.flush()
            os.fsync(fh.fileno())

        os.replace(tmp_path, self._path)

        # Refresh the in-memory cache so the next ``get`` sees the
        # values that were just persisted.
        self._data = dict(data)
        self._loaded = True

    def get(self, key: str) -> Any:
        """Return the Config_File value for ``key``.

        Raises :class:`ConfigError` (with ``context={"key": key}``) if
        the key is missing or its value is "empty" — defined as
        ``None``, the empty string, or the empty list. This mirrors the
        orchestrator's "halt and prompt" behavior in Requirement 2.6:
        an empty placeholder means "ask me again", not "the operator
        wanted no value here".

        Lazily loads the Config_File on first access if :meth:`load`
        has not been called yet.
        """

        self._ensure_loaded()
        assert self._data is not None  # narrowed by _ensure_loaded()

        if key not in self._data:
            raise ConfigError(
                f"Required Config_File key '{key}' is missing",
                context={"key": key},
            )

        value = self._data[key]
        if value is None or value == "" or value == []:
            raise ConfigError(
                f"Required Config_File key '{key}' is empty",
                context={"key": key},
            )

        return value

    def set(self, key: str, value: Any) -> None:
        """Update one Config_File key and persist atomically.

        Lazily loads the Config_File first so the update is layered on
        top of the existing values rather than replacing them. The
        merged dict is re-validated against :data:`SCHEMA` (so this
        method enforces the schema on every write, not only the
        first-run :meth:`save`).
        """

        self._ensure_loaded()
        assert self._data is not None  # narrowed by _ensure_loaded()

        merged = dict(self._data)
        merged[key] = value
        # ``save`` validates and updates the in-memory cache.
        self.save(merged)

    def reconfigure(self) -> None:
        """Wipe the in-memory cache and delete the on-disk Config_File.

        Idempotent: calling :meth:`reconfigure` when the file does not
        exist is a successful no-op. This is the implementation hook
        for the ``--reconfigure`` CLI flag (Requirement 2.4); the
        prompter is responsible for re-collecting every input after
        this method returns.
        """

        self._data = None
        self._loaded = False
        try:
            self._path.unlink()
        except FileNotFoundError:
            # Idempotent: nothing to delete.
            pass

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _ensure_loaded(self) -> None:
        """Populate ``self._data`` from disk on first access."""

        if not self._loaded:
            self.load()

    @staticmethod
    def _validate(data: dict[str, Any]) -> None:
        """Validate ``data`` against :data:`SCHEMA`.

        Raises :class:`ConfigError` on the first error reported by the
        validator, with ``context`` carrying both the offending JSON
        Pointer and the top-level key (when one is available, so
        callers can use ``context["key"]`` directly per the public
        contract of :meth:`get`).
        """

        errors = sorted(
            _VALIDATOR.iter_errors(data),
            key=lambda err: list(err.absolute_path),
        )
        if not errors:
            return

        first = errors[0]
        pointer = _json_pointer(first.absolute_path)
        # The first element of ``absolute_path`` is the offending
        # top-level key; if the path is empty (root-level error) we
        # leave ``key`` out of the context.
        context: dict[str, Any] = {"pointer": pointer}
        if first.absolute_path:
            context["key"] = str(first.absolute_path[0])

        raise ConfigError(
            f"Config_File schema violation at {pointer or '<root>'}: "
            f"{first.message}",
            context=context,
        )
