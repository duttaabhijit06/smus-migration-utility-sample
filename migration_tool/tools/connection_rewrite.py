"""Rewrite Glue connection references in Step 3 outputs against the
Connection_Mapping_File produced by Step 4b.

This module is invoked as a subprocess by ``steps/03_glue-jobs/run.sh``::

    python -m migration_tool.tools.connection_rewrite \
        --mapping        <connection-mapping.json> \
        --target-py-dir  <dir-of-glue-py-scripts> \
        --target-nb-dir  <dir-of-glue-ipynb-notebooks> \
        --warnings-out   <errors.json>

The Connection_Mapping_File is the JSON document written by Step 4b at
``./steps/04b_glue-connections/outputs/connection-mapping.json``. Its
shape is::

    {
      "version": 1,
      "entries": [
        {
          "glue_connection_name": "...",
          "smus_connection_name": "...",
          "smus_connection_id":   "...",
          "status": "registered" | "skipped_unsupported" | "failed",
          ...
        },
        ...
      ]
    }

Only entries whose ``status`` is ``"registered"`` produce a substitution
rule. Each rule maps the source-account ``glue_connection_name`` to the
registered SMUS_Connection's name (and carries the SMUS_Connection ID so
the notebook metadata can record both identifiers).

Behavior contract
-----------------

* **Mapping file absent.** When ``--mapping`` points at a path that does
  not exist on disk, no rewrite is performed. Instead the tool emits a
  single structured warning row (JSON) both to stdout and to the
  ``--warnings-out`` file::

      {
        "step": "03_glue-jobs",
        "warning": "Connection_Mapping_File missing",
        "action": "run Step 4b and re-run Step 3"
      }

  The exit code is 0; this is a recoverable warning, not a failure
  (Requirement 9.5).

* **Mapping file present.** Every ``*.py`` file under ``--target-py-dir``
  has each registered Glue connection name rewritten to the matching
  SMUS_Connection name. The match is a word-boundary regex of the form
  ``\\b<name>\\b`` so the substitution does not touch a Glue connection
  name that appears as a substring inside an unrelated identifier. Each
  file is written back atomically via a temp-file-and-rename so a
  partial write cannot leave a half-rewritten script on disk.

  Every ``*.ipynb`` file under ``--target-nb-dir`` is parsed as JSON.
  For each cell whose ``cell_type == "code"``, the same word-boundary
  substitution is applied to the cell's ``source`` (which can be either
  a single string or a list of strings; both shapes are preserved on
  output).

  For each substitution made inside any cell of a notebook, the
  notebook's *metadata cell* is updated. The metadata cell is the LAST
  cell whose ``metadata.kind == "migration_tool_metadata"``. When no
  such cell exists, a fresh raw cell is appended at the end of the
  notebook with ``metadata.kind`` set to ``"migration_tool_metadata"``.
  The metadata cell's ``metadata.connection_references`` field is set
  (or replaced) with a list of substitution records of the form::

      {
        "glue_connection_name": "<original>",
        "smus_connection_name": "<rewritten-to>",
        "smus_connection_id":   "<smus-id>"
      }

  one entry per (rule, cell) substitution actually performed.

* **Summary.** On success, the tool prints a single-line JSON summary to
  stdout::

      {"files_rewritten": <N>, "substitutions_made": <N>}

  ``files_rewritten`` counts every ``*.py`` and ``*.ipynb`` file whose
  on-disk content changed as a result of the rewrite. ``substitutions_made``
  counts every individual ``\\b<name>\\b`` replacement performed across
  all targets, including the notebook metadata cell updates.

Imports are stdlib-only (``argparse``, ``json``, ``os``, ``pathlib``,
``re``, ``sys``) per Requirement 19.4: the orchestrator and its tools
ship without ``boto3`` or any third-party AWS SDK.

Validates: Requirements 9.4, 9.5, 19.4.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import sys

__all__ = ["main"]


# Marker placed on a notebook cell's ``metadata.kind`` field to identify
# the cell that holds Migration_Tool bookkeeping (the
# ``connection_references`` list, etc.). Kept as a module constant so
# both the read and write sides agree on the literal string.
_METADATA_CELL_KIND: str = "migration_tool_metadata"


# ---------------------------------------------------------------------------
# Mapping file loading and rule extraction
# ---------------------------------------------------------------------------


def _load_rules(mapping_path: pathlib.Path) -> list[dict[str, str]]:
    """Return the substitution rules derived from the mapping file.

    Each rule is a ``{"glue_connection_name": ..., "smus_connection_name":
    ..., "smus_connection_id": ...}`` dict. Only entries whose
    ``status == "registered"`` and whose three identifier fields are
    present and non-empty contribute a rule; every other row (including
    ``skipped_unsupported`` and ``failed``) is silently dropped.

    The caller is responsible for handling the "mapping path does not
    exist on disk" case before calling this function.
    """

    raw = mapping_path.read_text(encoding="utf-8")
    document = json.loads(raw)
    entries = document.get("entries") if isinstance(document, dict) else None
    if not isinstance(entries, list):
        return []

    rules: list[dict[str, str]] = []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        if entry.get("status") != "registered":
            continue
        glue_name = entry.get("glue_connection_name")
        smus_name = entry.get("smus_connection_name")
        smus_id = entry.get("smus_connection_id")
        if not (
            isinstance(glue_name, str)
            and glue_name
            and isinstance(smus_name, str)
            and smus_name
            and isinstance(smus_id, str)
            and smus_id
        ):
            continue
        rules.append(
            {
                "glue_connection_name": glue_name,
                "smus_connection_name": smus_name,
                "smus_connection_id": smus_id,
            }
        )
    return rules


# ---------------------------------------------------------------------------
# Atomic file write
# ---------------------------------------------------------------------------


def _atomic_write_text(path: pathlib.Path, text: str) -> None:
    """Write *text* to *path* atomically (temp file + rename).

    A SIGKILL between the temp-file write and the rename leaves the
    original file untouched, which matches the task's "atomic write"
    contract. The temp file is created in the same directory so the
    rename stays on the same filesystem.
    """

    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_name(path.name + ".tmp")
    tmp_path.write_text(text, encoding="utf-8")
    os.replace(tmp_path, path)


# ---------------------------------------------------------------------------
# Word-boundary substitution
# ---------------------------------------------------------------------------


def _substitute(text: str, rules: list[dict[str, str]]) -> tuple[str, int, list[dict[str, str]]]:
    """Apply every rule to *text* using a ``\\bNAME\\b`` regex.

    Returns a tuple of ``(new_text, total_substitutions, references)``
    where ``references`` is the list of substitution records (one entry
    per rule whose pattern actually matched at least once in *text*) for
    use in the notebook's metadata cell.

    The substitution iterates over rules in the order returned by
    :func:`_load_rules`. The replacement is delivered through a callable
    so any regex-special characters in the SMUS name are inserted
    verbatim rather than being interpreted as ``\\1``-style
    backreferences.
    """

    total = 0
    refs: list[dict[str, str]] = []
    for rule in rules:
        glue_name = rule["glue_connection_name"]
        smus_name = rule["smus_connection_name"]
        pattern = re.compile(r"\b" + re.escape(glue_name) + r"\b")
        new_text, count = pattern.subn(lambda _m, n=smus_name: n, text)
        if count:
            total += count
            refs.append(
                {
                    "glue_connection_name": glue_name,
                    "smus_connection_name": smus_name,
                    "smus_connection_id": rule["smus_connection_id"],
                }
            )
            text = new_text
    return text, total, refs


# ---------------------------------------------------------------------------
# .py rewrite
# ---------------------------------------------------------------------------


def _rewrite_py_file(path: pathlib.Path, rules: list[dict[str, str]]) -> int:
    """Rewrite a single ``*.py`` file in place. Returns the substitution count.

    The file is rewritten only when the new text differs from the
    original. The write is atomic (temp file + rename).
    """

    original = path.read_text(encoding="utf-8")
    new_text, count, _refs = _substitute(original, rules)
    if count and new_text != original:
        _atomic_write_text(path, new_text)
    return count


# ---------------------------------------------------------------------------
# .ipynb rewrite
# ---------------------------------------------------------------------------


def _rewrite_cell_source(source, rules: list[dict[str, str]]) -> tuple[object, int, list[dict[str, str]]]:
    """Apply :func:`_substitute` to a cell's ``source`` field.

    The nbformat schema allows ``source`` to be either a single string
    or a list of strings (each entry is one logical line). Both shapes
    are preserved on output: a list input yields a list output (joined
    for substitution then split back into one line per element with
    newline preserved on each line that originally had one), a string
    input yields a string output.

    Returns ``(new_source, substitutions_in_this_cell, references)``.
    """

    if isinstance(source, list):
        joined = "".join(source)
        new_joined, count, refs = _substitute(joined, rules)
        if count == 0:
            return source, 0, []
        # Re-split the rewritten text into the same line-array shape the
        # cell originally used. ``splitlines(keepends=True)`` preserves
        # the original line terminators; an empty rewrite (unlikely but
        # possible) produces an empty list, matching the convention
        # used by ``nbformat.write``.
        return new_joined.splitlines(keepends=True), count, refs

    if isinstance(source, str):
        new_text, count, refs = _substitute(source, rules)
        if count == 0:
            return source, 0, []
        return new_text, count, refs

    # Any other shape (None, dict, etc.) is not legal nbformat; leave
    # it untouched so a malformed cell does not crash the rewrite.
    return source, 0, []


def _merge_references(
    accumulated: list[dict[str, str]], new_refs: list[dict[str, str]]
) -> list[dict[str, str]]:
    """Merge per-cell substitution references into the notebook-wide list.

    Each reference is keyed by ``glue_connection_name``. If the same
    Glue_Connection appears in more than one cell, only one entry is
    kept in the final ``connection_references`` list — the metadata
    cell records the substitution rules that fired anywhere in the
    notebook, not a per-cell histogram.
    """

    seen = {ref["glue_connection_name"] for ref in accumulated}
    for ref in new_refs:
        if ref["glue_connection_name"] in seen:
            continue
        accumulated.append(ref)
        seen.add(ref["glue_connection_name"])
    return accumulated


def _find_metadata_cell_index(cells: list[dict]) -> int:
    """Return the index of the LAST migration_tool_metadata cell, or -1.

    The cell is identified by ``cell.metadata.kind ==
    "migration_tool_metadata"``. Searching from the end matches the
    task's "the LAST cell whose ..." rule and lets a notebook-author
    workflow append a fresh metadata cell to override an older one
    without having to delete the predecessor first.
    """

    for index in range(len(cells) - 1, -1, -1):
        cell = cells[index]
        if not isinstance(cell, dict):
            continue
        meta = cell.get("metadata")
        if isinstance(meta, dict) and meta.get("kind") == _METADATA_CELL_KIND:
            return index
    return -1


def _ensure_metadata_cell(notebook: dict, references: list[dict[str, str]]) -> None:
    """Insert or update the migration_tool_metadata cell.

    If a metadata cell already exists, its ``metadata.connection_references``
    field is overwritten with the new list. If none exists, a fresh raw
    cell is appended at the end of ``notebook["cells"]`` with
    ``metadata.kind`` set to ``"migration_tool_metadata"``. The cell is
    a ``raw`` cell (rather than ``code`` or ``markdown``) so it does not
    appear as runnable code or rendered prose to a notebook reader.
    """

    cells = notebook.get("cells")
    if not isinstance(cells, list):
        cells = []
        notebook["cells"] = cells

    index = _find_metadata_cell_index(cells)
    if index >= 0:
        cell = cells[index]
        meta = cell.get("metadata")
        if not isinstance(meta, dict):
            meta = {"kind": _METADATA_CELL_KIND}
            cell["metadata"] = meta
        meta["connection_references"] = references
        return

    cells.append(
        {
            "cell_type": "raw",
            "metadata": {
                "kind": _METADATA_CELL_KIND,
                "connection_references": references,
            },
            "source": [],
        }
    )


def _rewrite_notebook_file(path: pathlib.Path, rules: list[dict[str, str]]) -> int:
    """Rewrite a single ``*.ipynb`` file in place. Returns the substitution count.

    A non-JSON or non-dict notebook is skipped (the file is left
    untouched and the substitution count is 0). When the substitution
    count is non-zero, the notebook's metadata cell is updated and the
    file is rewritten atomically using the same JSON formatting
    conventions as ``nbformat`` (``indent=1``, trailing newline).
    """

    raw = path.read_text(encoding="utf-8")
    try:
        notebook = json.loads(raw)
    except json.JSONDecodeError:
        return 0
    if not isinstance(notebook, dict):
        return 0

    cells = notebook.get("cells")
    if not isinstance(cells, list):
        return 0

    total_subs = 0
    accumulated_refs: list[dict[str, str]] = []
    for cell in cells:
        if not isinstance(cell, dict):
            continue
        if cell.get("cell_type") != "code":
            continue
        new_source, count, refs = _rewrite_cell_source(cell.get("source", ""), rules)
        if count:
            cell["source"] = new_source
            total_subs += count
            _merge_references(accumulated_refs, refs)

    if total_subs == 0:
        return 0

    _ensure_metadata_cell(notebook, accumulated_refs)
    _atomic_write_text(
        path,
        json.dumps(notebook, indent=1, ensure_ascii=False) + "\n",
    )
    return total_subs


# ---------------------------------------------------------------------------
# Mapping-absent warning
# ---------------------------------------------------------------------------


def _emit_missing_mapping_warning(warnings_out: pathlib.Path | None) -> None:
    """Emit the structured "mapping file missing" warning row.

    The warning is written to stdout (always) and to the
    ``--warnings-out`` file (when supplied). The file write is atomic so
    a partial write cannot leave a half-formed errors.json on disk.
    """

    warning = {
        "step": "03_glue-jobs",
        "warning": "Connection_Mapping_File missing",
        "action": "run Step 4b and re-run Step 3",
    }
    payload = json.dumps(warning) + "\n"
    sys.stdout.write(payload)
    if warnings_out is not None:
        _atomic_write_text(warnings_out, payload)


# ---------------------------------------------------------------------------
# Argparse surface
# ---------------------------------------------------------------------------


def _build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m migration_tool.tools.connection_rewrite",
        description=(
            "Rewrite Glue connection references in Step 3's produced "
            ".py scripts and .ipynb notebooks against the "
            "Connection_Mapping_File written by Step 4b."
        ),
    )
    parser.add_argument(
        "--mapping",
        required=True,
        type=pathlib.Path,
        metavar="<connection-mapping.json>",
        help=(
            "Path to the Connection_Mapping_File "
            "(./steps/04b_glue-connections/outputs/connection-mapping.json). "
            "When this file is absent, the tool emits a structured "
            "warning and exits 0 without rewriting anything."
        ),
    )
    parser.add_argument(
        "--target-py-dir",
        required=True,
        type=pathlib.Path,
        metavar="<dir>",
        help="Directory containing the Glue *.py scripts to rewrite in place.",
    )
    parser.add_argument(
        "--target-nb-dir",
        required=True,
        type=pathlib.Path,
        metavar="<dir>",
        help="Directory containing the Glue *.ipynb notebooks to rewrite in place.",
    )
    parser.add_argument(
        "--warnings-out",
        required=True,
        type=pathlib.Path,
        metavar="<errors.json>",
        help=(
            "Path that receives a structured JSON warning row when the "
            "mapping file is absent. The same row is also printed to "
            "stdout."
        ),
    )
    return parser


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    """CLI entry point. See module docstring for the full contract.

    Returns 0 on success, including the mapping-file-missing case
    (Requirement 9.5). Non-zero exits propagate from underlying I/O or
    JSON parsing errors on the mapping file itself; per-file errors on
    the targets are not currently surfaced as non-zero exits because
    Step 3's batch loop logs and continues per Requirement 9.7.
    """

    args = _build_arg_parser().parse_args(argv)

    mapping_path: pathlib.Path = args.mapping
    target_py_dir: pathlib.Path = args.target_py_dir
    target_nb_dir: pathlib.Path = args.target_nb_dir
    warnings_out: pathlib.Path = args.warnings_out

    if not mapping_path.exists():
        _emit_missing_mapping_warning(warnings_out)
        return 0

    rules = _load_rules(mapping_path)

    files_rewritten = 0
    substitutions_made = 0

    if rules:
        # ``*.py`` rewrite pass. ``Path.glob("*.py")`` returns an empty
        # iterator when the directory does not exist or is empty, which
        # matches the "no files to rewrite" case.
        if target_py_dir.exists():
            for py_path in sorted(target_py_dir.glob("*.py")):
                if not py_path.is_file():
                    continue
                count = _rewrite_py_file(py_path, rules)
                if count:
                    files_rewritten += 1
                    substitutions_made += count

        # ``*.ipynb`` rewrite pass.
        if target_nb_dir.exists():
            for nb_path in sorted(target_nb_dir.glob("*.ipynb")):
                if not nb_path.is_file():
                    continue
                count = _rewrite_notebook_file(nb_path, rules)
                if count:
                    files_rewritten += 1
                    substitutions_made += count

    summary = {
        "files_rewritten": files_rewritten,
        "substitutions_made": substitutions_made,
    }
    sys.stdout.write(json.dumps(summary) + "\n")
    return 0


if __name__ == "__main__":  # pragma: no cover - CLI entry point
    sys.exit(main())
