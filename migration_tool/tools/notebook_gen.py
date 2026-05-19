"""Generate a Jupyter notebook (``.ipynb``) from a Glue script + metadata.

This module is invoked as a subprocess by ``steps/03_glue-jobs/run.sh``::

    python -m migration_tool.tools.notebook_gen \\
        --script   <path-to-glue.py> \\
        --output   <output.ipynb> \\
        --metadata <path-to-metadata.json>

It reads a Glue script body and a small metadata JSON document and writes
a hand-built ``nbformat=4`` (minor 5) notebook with exactly two cells:

1. A **code cell** whose ``source`` is the original script body, split into
   lines where each non-final line ends with ``\\n``. The final line keeps
   whatever terminator (or absence thereof) the original script had.
2. A **markdown cell** whose ``source`` is a YAML frontmatter-style block
   wrapped in a fenced code block. The YAML contains the metadata fields
   ``name``, ``role``, ``default_arguments``, and ``connection_references``.
   For each connection reference the YAML lists both the original
   Glue_Connection identifier and — when supplied — the matching
   SMUS_Connection name and ID. Uses markdown (not raw) for SMUS
   compatibility.

The metadata JSON document has the shape::

    {
      "name": "<glue-job-name>",
      "role": "<iam-role-arn>",
      "default_arguments": {"--TempDir": "...", "--connection-name": "..."},
      "connection_references": [
        {
          "original": "<glue-conn-name>",
          "smus_connection_name": "<smus-name>" | null,
          "smus_connection_id":   "<smus-id>"   | null
        },
        ...
      ]
    }

Missing top-level keys are tolerated (rendered as empty / null) so the
notebook is still well-formed when Step 3 hands in a sparse metadata
document; missing per-entry keys in ``connection_references`` are also
tolerated and emit ``null`` for the absent fields.

The module is intentionally stdlib-only (no ``nbformat``, no ``pyyaml``)
per Requirement 19.4: the orchestrator stays dependency-free, and the
YAML emission for the raw cell is hand-rolled because the metadata shape
is small and fully under our control.

The output file is written atomically: the JSON is first written to a
sibling temp file in the same directory and then ``os.replace``d onto
the final path, so a crashed run never leaves a half-written notebook
on disk.

Validates: Requirements 9.3, 19.4.
"""

from __future__ import annotations

import argparse
import datetime as _datetime
import json
import os
import pathlib
import sys
import tempfile
from typing import Any

from migration_tool.tools.glue_to_smus import build_glue_notebook

__all__ = ["main"]


# ---------------------------------------------------------------------------
# Notebook constants
# ---------------------------------------------------------------------------

_NBFORMAT: int = 4
_NBFORMAT_MINOR: int = 5
_NEWLINE: str = "\n"


# ---------------------------------------------------------------------------
# Cell construction
# ---------------------------------------------------------------------------


def _split_script_into_source(script_body: str) -> list[str]:
    """Split *script_body* into the line-array form expected by nbformat.

    Each line in the returned list is terminated by ``\\n`` except — per
    the task contract — the final line, which keeps the original
    terminator (or lack thereof). Empty input produces an empty list,
    which nbformat accepts as a valid empty source.
    """

    if not script_body:
        return []
    # ``splitlines(keepends=True)`` keeps the line terminator on each
    # line; if the body did not end with a newline, the final entry has
    # no trailing newline, which matches the contract verbatim.
    return script_body.splitlines(keepends=True)


def _code_cell(script_body: str) -> dict[str, Any]:
    """Build the single code cell that holds the Glue script body."""

    return {
        "cell_type": "code",
        "id": "glue-script",
        "metadata": {},
        "execution_count": None,
        "outputs": [],
        "source": _split_script_into_source(script_body),
    }


def _markdown_metadata_cell(metadata: dict[str, Any]) -> dict[str, Any]:
    """Build the markdown cell that holds the YAML frontmatter metadata block.

    Uses markdown cell type instead of raw for SMUS compatibility - SMUS only
    supports 'code' and 'markdown' cell types. The YAML is wrapped in a
    fenced code block for readability.
    """

    yaml_lines = _build_yaml_frontmatter_lines(metadata)
    # Wrap in fenced code block for markdown rendering
    source_lines = ["```yaml\n"] + yaml_lines + ["```\n"]

    return {
        "cell_type": "markdown",
        "id": "glue-metadata",
        "metadata": {},
        "source": source_lines,
    }


# ---------------------------------------------------------------------------
# YAML frontmatter emission (stdlib-only)
# ---------------------------------------------------------------------------
#
# We emit a deliberately narrow subset of YAML 1.1: scalars are rendered
# either as ``null`` (for None) or as double-quoted strings with the
# minimal set of escapes that JSON also escapes (``\\``, ``"``, control
# chars). This is safe for the metadata shape the task documents and
# avoids the "do I need quoting?" classification that a real YAML
# emitter would do. JSON-style double-quoted strings round-trip through
# any YAML 1.1 parser unchanged.


def _yaml_scalar(value: Any) -> str:
    """Render a single scalar as a YAML double-quoted string or ``null``.

    ``None`` becomes the literal ``null``. Every other value is coerced
    to ``str`` and emitted as a JSON-style double-quoted string, which
    is a strict subset of YAML 1.1 flow scalars and therefore parses
    back to the same string under any YAML parser.
    """

    if value is None:
        return "null"
    # ``json.dumps`` produces a strictly-quoted string with the escapes
    # YAML accepts (``\\``, ``\"``, ``\n``, ``\t``, etc.). ``ensure_ascii``
    # is left at its default of True so non-ASCII bytes are escaped as
    # ``\\uXXXX``, which both JSON and YAML accept.
    return json.dumps(str(value))


def _emit_mapping_lines(
    mapping: dict[str, Any],
    indent: int,
    out: list[str],
) -> None:
    """Append YAML lines for a flat ``str -> scalar`` mapping to *out*.

    The mapping is rendered with sorted keys so two runs against the
    same metadata produce byte-identical notebooks. Each value is
    emitted via :func:`_yaml_scalar`; nested mappings are not supported
    here because the metadata schema only nests one level deep
    (``default_arguments`` is the only nested map and it is flat).
    """

    pad = " " * indent
    if not mapping:
        # Flow-style empty map keeps the YAML valid without forcing a
        # multi-line block. ``{}`` is the YAML 1.1 empty-mapping literal.
        out.append(pad + "{}" + _NEWLINE)
        return
    for key in sorted(mapping):
        out.append(f"{pad}{_yaml_scalar(key)}: {_yaml_scalar(mapping[key])}{_NEWLINE}")


def _emit_connection_refs_lines(
    refs: list[Any],
    indent: int,
    out: list[str],
) -> None:
    """Append YAML lines for the ``connection_references`` block.

    Each entry is rendered as a block-sequence item with three keys
    (``original``, ``smus_connection_name``, ``smus_connection_id``),
    in a fixed order so the diff is stable. Missing keys are emitted as
    ``null``. Non-dict entries are skipped defensively.
    """

    pad = " " * indent
    if not refs:
        out.append(pad + "[]" + _NEWLINE)
        return
    item_indent = indent + 2
    item_pad = " " * item_indent
    for entry in refs:
        if not isinstance(entry, dict):
            continue
        original = entry.get("original")
        smus_name = entry.get("smus_connection_name")
        smus_id = entry.get("smus_connection_id")
        # ``- original: "..."`` is the block-sequence head; subsequent
        # keys for this entry are indented to align with ``original``.
        out.append(f"{pad}- original: {_yaml_scalar(original)}{_NEWLINE}")
        out.append(f"{item_pad}smus_connection_name: {_yaml_scalar(smus_name)}{_NEWLINE}")
        out.append(f"{item_pad}smus_connection_id: {_yaml_scalar(smus_id)}{_NEWLINE}")


def _build_yaml_frontmatter_lines(metadata: dict[str, Any]) -> list[str]:
    """Build the raw cell's ``source`` as a list of newline-terminated lines.

    Layout::

        ---
        name: "<name>"
        role: "<role>"
        default_arguments:
          "<key>": "<value>"
          ...
        connection_references:
          - original: "<glue-conn>"
            smus_connection_name: "<smus-name>" | null
            smus_connection_id: "<smus-id>" | null
          ...
        ---

    The function tolerates missing top-level keys and missing per-entry
    keys: missing scalars are rendered as ``null``, missing maps as
    ``{}``, and a missing ``connection_references`` list as ``[]``.
    """

    name = metadata.get("name")
    role = metadata.get("role")
    default_args = metadata.get("default_arguments")
    refs = metadata.get("connection_references")

    if not isinstance(default_args, dict):
        default_args = {}
    if not isinstance(refs, list):
        refs = []

    lines: list[str] = []
    lines.append("---" + _NEWLINE)
    lines.append(f"name: {_yaml_scalar(name)}{_NEWLINE}")
    lines.append(f"role: {_yaml_scalar(role)}{_NEWLINE}")
    lines.append("default_arguments:" + _NEWLINE)
    _emit_mapping_lines(default_args, indent=2, out=lines)
    lines.append("connection_references:" + _NEWLINE)
    _emit_connection_refs_lines(refs, indent=2, out=lines)
    lines.append("---" + _NEWLINE)
    return lines


# ---------------------------------------------------------------------------
# Notebook envelope
# ---------------------------------------------------------------------------


def _utc_now_iso() -> str:
    """Return the current UTC timestamp formatted as ``YYYY-MM-DDTHH:MM:SSZ``.

    The ``Z`` suffix marks UTC explicitly and is accepted by every
    ISO 8601 / RFC 3339 parser.
    """

    now = _datetime.datetime.now(_datetime.timezone.utc).replace(microsecond=0)
    # ``isoformat()`` of a tz-aware datetime emits ``+00:00``; replace
    # with ``Z`` for the more conventional Zulu-time spelling.
    return now.isoformat().replace("+00:00", "Z")


def _build_notebook(
    script_body: str,
    metadata: dict[str, Any],
) -> dict[str, Any]:
    """Assemble the full notebook document as a Python dict."""

    job_name = metadata.get("name") if isinstance(metadata, dict) else None

    return {
        "cells": [
            _code_cell(script_body),
            _markdown_metadata_cell(metadata if isinstance(metadata, dict) else {}),
        ],
        "metadata": {
            "kernelspec": {
                "name": "python3",
                "display_name": "Python 3",
            },
            "language_info": {
                "name": "python",
            },
            "migration_tool": {
                "job_name": job_name,
                "generated_at_utc": _utc_now_iso(),
            },
        },
        "nbformat": _NBFORMAT,
        "nbformat_minor": _NBFORMAT_MINOR,
    }


# ---------------------------------------------------------------------------
# Atomic write
# ---------------------------------------------------------------------------


def _atomic_write_text(path: pathlib.Path, payload: str) -> None:
    """Write *payload* to *path* atomically (temp file + ``os.replace``).

    The temp file is created in the same directory as *path* so the
    final ``os.replace`` is a same-filesystem rename, which is
    guaranteed to be atomic on POSIX and on NTFS. Parent directories
    are created on demand.
    """

    path.parent.mkdir(parents=True, exist_ok=True)
    # ``delete=False`` is required because we hand off the file to
    # ``os.replace`` after closing the handle; we then manage cleanup
    # explicitly in the except branch.
    fd, tmp_name = tempfile.mkstemp(
        prefix=path.name + ".",
        suffix=".tmp",
        dir=str(path.parent),
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(payload)
            # ``flush + fsync`` raises the durability bar so the rename
            # cannot expose a zero-length file on a crash. ``fsync`` is
            # a no-op on filesystems that do not implement it.
            handle.flush()
            try:
                os.fsync(handle.fileno())
            except OSError:
                pass
        os.replace(tmp_name, path)
    except BaseException:
        # Best-effort cleanup of the temp file when anything above
        # fails; the original target is left untouched by ``os.replace``
        # contract, so a partial run is observably a no-op.
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


# ---------------------------------------------------------------------------
# Argparse surface
# ---------------------------------------------------------------------------


def _build_parser() -> argparse.ArgumentParser:
    """Build the argparse parser for the ``notebook_gen`` CLI."""

    parser = argparse.ArgumentParser(
        prog="python -m migration_tool.tools.notebook_gen",
        description=(
            "Build a Jupyter notebook (.ipynb) from a Glue script and a "
            "small metadata JSON document. The notebook contains one "
            "code cell with the script body and one raw cell with a "
            "YAML frontmatter block listing the job name, role, default "
            "arguments, and connection references (Glue and, when "
            "supplied, the matching SMUS connection name and ID)."
        ),
    )
    parser.add_argument(
        "--script",
        required=True,
        metavar="<path-to-py>",
        help="Path to the Glue job's Python script.",
    )
    parser.add_argument(
        "--output",
        required=True,
        metavar="<path-to-ipynb>",
        help="Path to write the generated `.ipynb` file (atomic rename).",
    )
    parser.add_argument(
        "--metadata",
        required=True,
        metavar="<path-to-json>",
        help=(
            "Path to the metadata JSON document with keys `name`, "
            "`role`, `default_arguments`, and `connection_references`."
        ),
    )
    return parser


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    """Argparse entry point.

    Returns 0 on success. Returns 1 on expected I/O / parse failures
    (the exception message is written to ``stderr``). Unexpected
    exceptions propagate so ``run.sh`` can capture them in the step's
    run log.
    """

    args = _build_parser().parse_args(argv)

    script_path = pathlib.Path(args.script)
    output_path = pathlib.Path(args.output)
    metadata_path = pathlib.Path(args.metadata)

    try:
        script_body = script_path.read_text(encoding="utf-8")
    except OSError as exc:
        print(
            f"notebook_gen: cannot read script {script_path}: {exc}",
            file=sys.stderr,
        )
        return 1

    try:
        metadata_raw = metadata_path.read_text(encoding="utf-8")
    except OSError as exc:
        print(
            f"notebook_gen: cannot read metadata {metadata_path}: {exc}",
            file=sys.stderr,
        )
        return 1
    try:
        metadata = json.loads(metadata_raw)
    except json.JSONDecodeError as exc:
        print(
            f"notebook_gen: metadata file {metadata_path} is not valid JSON: {exc}",
            file=sys.stderr,
        )
        return 1
    if not isinstance(metadata, dict):
        # Defensive: per the task contract the metadata file holds a
        # JSON object. Anything else (top-level array, scalar) is
        # treated as an error rather than silently coerced.
        print(
            f"notebook_gen: metadata file {metadata_path} must contain a JSON object",
            file=sys.stderr,
        )
        return 1

    # Use Glue interactive session format with %glue_version and %%glue magics
    job_name = metadata.get("name", script_path.stem)
    notebook = build_glue_notebook(script_body, metadata, job_name)
    # ``indent=1`` mirrors the convention used by ``nbformat.write`` so
    # the output stays git-diff-friendly. ``ensure_ascii=False`` keeps
    # non-ASCII glue script content readable in the on-disk notebook.
    payload = json.dumps(notebook, indent=1, ensure_ascii=False) + _NEWLINE

    try:
        _atomic_write_text(output_path, payload)
    except OSError as exc:
        print(
            f"notebook_gen: cannot write notebook {output_path}: {exc}",
            file=sys.stderr,
        )
        return 1

    refs = metadata.get("connection_references")
    ref_count = len(refs) if isinstance(refs, list) else 0
    # Stdout summary line, matched verbatim to the task contract so
    # downstream tooling can grep for it in the step's run log.
    print(
        f"wrote {output_path} from {script_path} with {ref_count} connection references"
    )
    return 0


if __name__ == "__main__":  # pragma: no cover - CLI entry point
    sys.exit(main())
