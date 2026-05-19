"""End-of-run summary table renderer.

This module renders a deterministic, plain-text summary suitable for printing
to stdout at the end of a Migration_Tool run. It is intentionally stdlib-only
(no third-party deps, no other ``migration_tool`` imports) so it can be used
from any reporting context, including failure paths and tests.

The summary has three sections:

1. A header block recording the resolved Repo_Provider and the resolved
   repository URL (falling back to the CodeCommit repository ARN for
   CodeCommit when no clone URL is available yet).
2. A plain-text aligned table with one row per step, showing ``Step ID``,
   ``Status``, ``Elapsed (s)``, and ``Log Path``.
3. A totals footer line summarizing counts of completed, failed, skipped,
   and pending steps.

Column widths are computed from ``max(len(value)`` over all values in each
column plus the header), and rendered with f-string left-padding so the
output is deterministic and easy to assert against in tests.

Validates: Requirement 4.4.
"""

from __future__ import annotations

from typing import Any, Dict, List

# Sentinel for null / missing values in the rendered table.
_NULL = "—"

# Table column headers, in display order.
_HEADERS: List[str] = ["Step ID", "Status", "Elapsed (s)", "Log Path"]

# Two-space gap between columns, matches a typical fixed-width layout.
_COL_SEP = "  "

# Status values counted in the totals footer (and the order they appear).
_TOTAL_STATUSES: List[str] = ["completed", "failed", "skipped", "pending"]


def _format_elapsed(value: Any) -> str:
    """Format ``elapsed_seconds`` to 2 decimals, or the null sentinel.

    A literal ``0`` (or ``0.0``) is a real elapsed time and is rendered as
    ``"0.00"``. Only ``None`` collapses to the null sentinel.
    """
    if value is None:
        return _NULL
    try:
        return f"{float(value):.2f}"
    except (TypeError, ValueError):
        return _NULL


def _format_log_path(value: Any) -> str:
    """Return the log path string, or the null sentinel for null/empty."""
    if value is None or value == "":
        return _NULL
    return str(value)


def _resolve_repo_url(config: Dict[str, Any]) -> str:
    """Resolve the URL/ARN value shown in the header block.

    Falls back to ``codecommit_repo_arn`` when ``repo_url`` is null (the
    CodeCommit case before Step 1 has run), and to the null sentinel when
    neither is available.
    """
    repo_url = config.get("repo_url")
    if repo_url:
        return str(repo_url)
    arn = config.get("codecommit_repo_arn")
    if arn:
        return str(arn)
    return _NULL


def _build_row(step_id: str, step: Dict[str, Any]) -> List[str]:
    """Build a single table row from one step's state record."""
    status = step.get("status") or "pending"
    return [
        str(step_id),
        str(status),
        _format_elapsed(step.get("elapsed_seconds")),
        _format_log_path(step.get("log_path")),
    ]


def _column_widths(headers: List[str], rows: List[List[str]]) -> List[int]:
    """Compute per-column display widths from headers + all row values."""
    widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            if len(cell) > widths[i]:
                widths[i] = len(cell)
    return widths


def _render_row(row: List[str], widths: List[int]) -> str:
    """Left-pad each cell to its column width and join with the separator."""
    padded = [f"{cell:<{widths[i]}}" for i, cell in enumerate(row)]
    # rstrip removes trailing spaces from the last column for a clean line.
    return _COL_SEP.join(padded).rstrip()


def _render_separator(widths: List[int]) -> str:
    """Render a dashed separator line aligned with column widths."""
    return _COL_SEP.join("-" * w for w in widths)


def _count_totals(steps: Dict[str, Dict[str, Any]]) -> Dict[str, int]:
    """Tally step counts by status for the footer line."""
    counts = {name: 0 for name in _TOTAL_STATUSES}
    for step in steps.values():
        status = (step.get("status") or "").lower()
        if status in counts:
            counts[status] += 1
    return counts


def render_summary(state: Dict[str, Any], config: Dict[str, Any]) -> str:
    """Render the end-of-run summary as a single printable string.

    Args:
        state: The parsed ``migration.state.json`` document. Only the
            ``steps`` mapping is consumed; iteration order follows the
            mapping's insertion order (Python 3.7+ guarantee), which the
            orchestrator builds from ``steps_registry`` in canonical order.
        config: The resolved configuration dict. Reads ``repo_provider``,
            ``repo_url``, and ``codecommit_repo_arn`` for the header block.

    Returns:
        A multi-line string ending with a newline, containing the header
        block, the per-step table, and the totals footer.
    """
    steps: Dict[str, Dict[str, Any]] = state.get("steps") or {}

    # Header block.
    repo_provider = config.get("repo_provider") or _NULL
    repo_url_value = _resolve_repo_url(config)
    header_lines = [
        f"Repo Provider: {repo_provider}",
        f"Repo URL / CodeCommit clone URL: {repo_url_value}",
        "",
    ]

    # Table body.
    rows = [_build_row(step_id, step) for step_id, step in steps.items()]
    widths = _column_widths(_HEADERS, rows)
    table_lines = [
        _render_row(_HEADERS, widths),
        _render_separator(widths),
    ]
    for row in rows:
        table_lines.append(_render_row(row, widths))

    # Totals footer.
    counts = _count_totals(steps)
    totals_line = "Totals: " + ", ".join(
        f"{name}={counts[name]}" for name in _TOTAL_STATUSES
    )

    all_lines = header_lines + table_lines + ["", totals_line]
    return "\n".join(all_lines) + "\n"


__all__ = ["render_summary"]
