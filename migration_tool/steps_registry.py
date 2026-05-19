"""Canonical step registry for the SageMaker Migration Tool orchestrator.

This module is the single source of truth for the ordered list of
migration steps the orchestrator can execute, plus the read-only
inventory phase that runs as a separate scope. It exposes:

* A pair sequence of ``(step_id, folder)`` tuples in canonical execution
  order (Step 1 ... Step 9, with the ``04b`` sub-step slotted between
  Step 4 and Step 5).
* The six inventory entries (``inventory.lambda`` etc.) appended after
  the canonical ordering. Inventory entries are reachable only via
  ``--step inventory.<service>`` and are intentionally excluded from
  ``--from`` / ``--to`` range expansion.
* A folder-name validator regex and a thin ``validate_step_folder_name``
  helper.
* A ``range_expand`` helper that turns the CLI selectors
  (``--from`` / ``--to`` / ``--step``) into the ordered list of step IDs
  the runner should execute.
* Convenience tuples ``STEP_IDS``, ``CANONICAL_STEP_IDS`` and
  ``INVENTORY_STEP_IDS`` plus a ``folder_for`` lookup helper.

The module has no third-party dependencies and intentionally does not
import from any other ``migration_tool`` module, so importing it is safe
from any layer of the orchestrator (CLI, runner, prompts, tests, etc.).

Validates: Requirement 5.1 (step folder naming convention and canonical
sequencing).
"""

from __future__ import annotations

import re
from typing import Final

__all__ = [
    "STEP_FOLDER_REGEX",
    "STEPS",
    "STEP_IDS",
    "CANONICAL_STEP_IDS",
    "INVENTORY_STEP_IDS",
    "validate_step_folder_name",
    "folder_for",
    "range_expand",
]


# ---------------------------------------------------------------------------
# Canonical ordering
# ---------------------------------------------------------------------------
#
# The non-inventory steps in the order the orchestrator runs them.
# Step 8 (``08_dag-yaml``) is present in the registry but is gated
# behind ``--convert-dags`` at CLI parse time; its inclusion here
# just makes it reachable via ``--step``, ``--from`` and ``--to``
# when the gate is open.
#
# Note: ``04b_glue-connections`` was previously registered between
# Step 4 and Step 5 (Requirement 11 / design.md) but has been
# intentionally removed from the registry. Step 3's connection
# rewrite is a graceful no-op when the Connection_Mapping_File is
# absent (Requirement 9.5), so dropping 04b leaves Step 3 working
# end-to-end without any code changes elsewhere.

_CANONICAL_STEPS: Final[tuple[tuple[str, str], ...]] = (
    ("01_create-smus-domain", "steps/01_create-smus-domain"),
    ("02_portability", "steps/02_portability"),
    ("03_glue-jobs", "steps/03_glue-jobs"),
    ("03b_lakeformation-setup", "steps/03b_lakeformation-setup"),
    ("04_catalog", "steps/04_catalog"),
    ("05_s3-data", "steps/05_s3-data"),
    ("06_mwaa-extract", "steps/06_mwaa-extract"),
    ("07_mwaa-integrate", "steps/07_mwaa-integrate"),
    ("08_dag-yaml", "steps/08_dag-yaml"),
    ("09_cicd", "steps/09_cicd"),
)


# ---------------------------------------------------------------------------
# Inventory phase
# ---------------------------------------------------------------------------
#
# The six inventory services run as a separate, read-only phase. They
# are addressable only via ``--step inventory.<service>``; they are
# never returned from ``range_expand`` when the caller specifies
# ``--from`` / ``--to`` (or neither), per the Requirement 5.1 / design
# contract.

_INVENTORY_STEPS: Final[tuple[tuple[str, str], ...]] = (
    ("inventory.lambda", "steps/inventory/lambda"),
    ("inventory.sns", "steps/inventory/sns"),
    ("inventory.msk", "steps/inventory/msk"),
    ("inventory.flink-kda", "steps/inventory/flink-kda"),
    ("inventory.cloudwatch", "steps/inventory/cloudwatch"),
    ("inventory.quicksight", "steps/inventory/quicksight"),
)


#: Full ordered tuple of ``(step_id, folder)`` pairs (canonical first,
#: inventory appended). Exposed for callers that need to iterate every
#: registered step in execution order.
STEPS: Final[tuple[tuple[str, str], ...]] = _CANONICAL_STEPS + _INVENTORY_STEPS


#: The ten non-inventory step IDs in canonical execution order. This is
#: the universe used by ``--from`` / ``--to`` range expansion.
CANONICAL_STEP_IDS: Final[tuple[str, ...]] = tuple(
    step_id for step_id, _ in _CANONICAL_STEPS
)


#: The six inventory step IDs in registration order. These are
#: addressable only via ``--step inventory.<service>``.
INVENTORY_STEP_IDS: Final[tuple[str, ...]] = tuple(
    step_id for step_id, _ in _INVENTORY_STEPS
)


#: Full ordered tuple of every registered step ID (canonical + inventory).
STEP_IDS: Final[tuple[str, ...]] = CANONICAL_STEP_IDS + INVENTORY_STEP_IDS


# Internal lookup table for ``folder_for``. Built once at import time to
# keep the helper O(1) and to avoid recomputing on every call.
_FOLDER_BY_ID: Final[dict[str, str]] = dict(STEPS)


# ---------------------------------------------------------------------------
# Folder-name validation
# ---------------------------------------------------------------------------
#
# Requirement 5.1: each step folder under ``./steps/`` is named
# ``<two-digit-ordinal>[<optional-lowercase-letter-suffix>]_<kebab-case-name>``.
# The optional letter suffix is reserved for sub-steps that share an
# ordinal with a parent step (for example ``04b_glue-connections`` is a
# sub-step of ``04_catalog``).
#
# Anchoring is performed by ``re.fullmatch`` at the call site so the
# regex itself does not need ``^`` / ``$`` anchors; we keep them in the
# pattern for clarity and so that ``re.search`` against this regex also
# behaves intuitively.

#: Regex that validates a step folder name. Use with ``fullmatch`` (or
#: ``validate_step_folder_name``) — never with ``search``-style partial
#: matching, since the regex is intentionally strict about the exact
#: shape of the name.
STEP_FOLDER_REGEX: Final[re.Pattern[str]] = re.compile(
    r"^\d{2}[a-z]?_[a-z][a-z0-9-]*$"
)


def validate_step_folder_name(name: str) -> bool:
    """Return ``True`` iff ``name`` is a legal step folder name.

    A legal name has exactly two leading digits, an optional single
    lowercase letter suffix (reserved for sub-steps such as
    ``04b_glue-connections``), an underscore, and a kebab-case slug
    that starts with a lowercase letter and contains only lowercase
    letters, digits, and hyphens.

    Examples accepted::

        01_create-smus-domain
        04b_glue-connections
        09_cicd

    Examples rejected::

        4_create               (single-digit ordinal)
        01-create              (missing underscore separator)
        01_Create              (uppercase in slug)
        01b2_glue              (multi-character ordinal suffix)
    """

    return STEP_FOLDER_REGEX.fullmatch(name) is not None


# ---------------------------------------------------------------------------
# Lookup helpers
# ---------------------------------------------------------------------------


def folder_for(step_id: str) -> str:
    """Return the folder path registered for ``step_id``.

    Raises:
        ValueError: if ``step_id`` is not a registered step ID. The
            message names the offending ID so the orchestrator and
            tests can surface a helpful error.
    """

    try:
        return _FOLDER_BY_ID[step_id]
    except KeyError:
        raise ValueError(f"unknown step id: {step_id}") from None


# ---------------------------------------------------------------------------
# Range expansion
# ---------------------------------------------------------------------------


def range_expand(
    from_id: str | None,
    to_id: str | None,
    step_id: str | None,
) -> list[str]:
    """Expand the CLI selectors into an ordered list of step IDs.

    The orchestrator's CLI exposes three mutually informing selectors
    (``--from`` / ``--to`` / ``--step``). This helper resolves them into
    the concrete, ordered list of step IDs the runner should execute.

    Resolution rules (Requirement 5.1):

    1. If ``step_id`` is given, return ``[step_id]`` after confirming it
       exists in the full registry (canonical + inventory). Inventory
       entries are reachable only through this branch.
    2. Otherwise, if ``from_id`` and/or ``to_id`` is given, return the
       contiguous closed slice of the canonical (non-inventory)
       ordering. ``from_id`` defaults to the first canonical step and
       ``to_id`` defaults to the last canonical step. Neither bound may
       reference an inventory entry.
    3. Otherwise, return the full canonical ordering of the
       registered non-inventory steps.

    Raises:
        ValueError: if ``step_id`` is given but unknown; if ``from_id``
            or ``to_id`` is given but is not a canonical step ID
            (including the case where it names an inventory entry); or
            if ``from_id`` appears after ``to_id`` in the canonical
            ordering.
    """

    # Branch 1: --step wins over --from/--to. The CLI is responsible
    # for rejecting the simultaneous use of --step with --from/--to;
    # this helper does not enforce that policy because doing so would
    # double-encode the rule and make the helper harder to test.
    if step_id is not None:
        if step_id not in _FOLDER_BY_ID:
            raise ValueError(f"unknown step id: {step_id}")
        return [step_id]

    # Branch 2/3: range over the canonical (non-inventory) ordering.
    # We work against ``CANONICAL_STEP_IDS`` exclusively here so an
    # inventory ID supplied as ``--from`` / ``--to`` raises rather than
    # silently producing a degenerate slice.
    if from_id is None:
        start_index = 0
    else:
        try:
            start_index = CANONICAL_STEP_IDS.index(from_id)
        except ValueError:
            raise ValueError(f"unknown step id: {from_id}") from None

    if to_id is None:
        end_index = len(CANONICAL_STEP_IDS) - 1
    else:
        try:
            end_index = CANONICAL_STEP_IDS.index(to_id)
        except ValueError:
            raise ValueError(f"unknown step id: {to_id}") from None

    if start_index > end_index:
        raise ValueError(
            f"--from step '{from_id}' appears after --to step '{to_id}' "
            f"in the canonical ordering"
        )

    return list(CANONICAL_STEP_IDS[start_index : end_index + 1])
