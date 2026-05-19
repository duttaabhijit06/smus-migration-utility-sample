"""Transform Glue job scripts to SMUS-compatible notebook format.

This module converts traditional AWS Glue ETL scripts to notebooks that can
run in SageMaker Unified Studio using the %%pyspark magic command.

Transformations applied:
1. Remove Glue boilerplate imports (GlueContext, Job, getResolvedOptions)
2. Remove SparkContext/GlueContext/Job initialization
3. Remove job.init() and job.commit() calls
4. Extract getResolvedOptions arguments and convert to notebook variables
5. Add %%pyspark magic command for SMUS execution
6. Preserve the core transformation logic

Note: In SMUS %%pyspark cells, `spark` (SparkSession) and `glueContext` are
automatically available, so GlueContext methods still work.
"""

from __future__ import annotations

import re
from typing import Any


# Imports to remove (Glue boilerplate)
GLUE_IMPORTS = {
    "from awsglue.context import GlueContext",
    "from awsglue.job import Job",
    "from awsglue.utils import getResolvedOptions",
    "from pyspark.context import SparkContext",
}

# Patterns to remove (initialization boilerplate)
REMOVE_PATTERNS = [
    # SparkContext creation
    r'^\s*sc\s*=\s*SparkContext\(\).*$',
    # GlueContext creation
    r'^\s*glue\s*=\s*GlueContext\(.*\).*$',
    r'^\s*glueContext\s*=\s*GlueContext\(.*\).*$',
    # Job creation
    r'^\s*job\s*=\s*Job\(.*\).*$',
    # job.init and job.commit
    r'^\s*job\.init\(.*\).*$',
    r'^\s*job\.commit\(.*\).*$',
    # getResolvedOptions (handled separately to extract args)
    r'^\s*args\s*=\s*getResolvedOptions\(.*\).*$',
    # spark = glueContext.spark_session (redundant - spark is pre-defined)
    r'^\s*spark\s*=\s*glueContext\.spark_session.*$',
    # if __name__ == "__main__" block
    r'^if\s+__name__\s*==\s*["\']__main__["\']\s*:.*$',
    r'^\s+main\(\).*$',
    # Empty def main(): wrapper (we'll inline the content)
    r'^def\s+main\(\)\s*:.*$',
]

# Variable renames for SMUS compatibility
VARIABLE_RENAMES = {
    'glue.': 'glueContext.',  # Common alias
    'sc.': 'spark.sparkContext.',  # SparkContext access
}


def extract_resolved_options(script: str) -> tuple[list[str], dict[str, str]]:
    """Extract argument names from getResolvedOptions call.

    Returns:
        Tuple of (arg_names, default_values) where arg_names is the list of
        arguments requested and default_values maps arg names to any default
        values found in the script.
    """
    # Pattern: getResolvedOptions(sys.argv, ["arg1", "arg2", ...])
    # Handle multi-line with re.DOTALL
    pattern = r'getResolvedOptions\s*\(\s*sys\.argv\s*,\s*\[(.*?)\]\s*,?\s*\)'
    match = re.search(pattern, script, re.DOTALL)

    if not match:
        return [], {}

    args_str = match.group(1)
    # Extract quoted strings (handles multi-line)
    arg_names = re.findall(r'["\']([^"\']+)["\']', args_str)

    # Filter out JOB_NAME as it's Glue-specific
    arg_names = [a for a in arg_names if a != "JOB_NAME"]

    # Try to find default values used in the script
    defaults = {}

    return arg_names, defaults


def transform_glue_to_smus(script: str, metadata: dict[str, Any] | None = None) -> str:
    """Transform a Glue script to SMUS-compatible PySpark code.

    Args:
        script: The original Glue job script content
        metadata: Optional metadata dict with default_arguments

    Returns:
        Transformed script suitable for SMUS %%pyspark cells
    """
    # Extract arguments from getResolvedOptions BEFORE modifying the script
    arg_names, _ = extract_resolved_options(script)

    # Remove multi-line getResolvedOptions calls
    script = re.sub(
        r'args\s*=\s*getResolvedOptions\s*\(\s*sys\.argv\s*,\s*\[[^\]]*\]\s*,?\s*\)',
        '',
        script,
        flags=re.DOTALL
    )

    lines = script.split('\n')
    result_lines = []

    # Get default values from metadata if available
    default_args = {}
    if metadata and isinstance(metadata.get("default_arguments"), dict):
        for key, val in metadata["default_arguments"].items():
            # Strip -- prefix from argument names
            clean_key = key.lstrip('-')
            default_args[clean_key] = val

    in_main_function = False
    main_indent = 0
    skip_next_empty = False
    in_getresolved = False  # Track if we're inside a multi-line getResolvedOptions

    for line in lines:
        stripped = line.strip()

        # Skip empty lines after removed content
        if skip_next_empty and not stripped:
            skip_next_empty = False
            continue
        skip_next_empty = False

        # Check if this is an import to remove
        if any(imp in line for imp in GLUE_IMPORTS):
            skip_next_empty = True
            continue

        # Track multi-line getResolvedOptions
        if 'getResolvedOptions' in line or (in_getresolved and stripped):
            if 'getResolvedOptions' in line:
                in_getresolved = True
            if in_getresolved:
                if ')' in line and line.count(')') >= line.count('('):
                    in_getresolved = False
                skip_next_empty = True
                continue

        # Check if this line matches any removal pattern
        should_remove = False
        for pattern in REMOVE_PATTERNS:
            if re.match(pattern, line):
                should_remove = True
                skip_next_empty = True
                break

        if should_remove:
            # Track if we're entering main()
            if re.match(r'^def\s+main\(\)\s*:', line):
                in_main_function = True
                main_indent = len(line) - len(line.lstrip()) + 4  # Typical indent
            continue

        # Handle main function content - dedent it
        if in_main_function and line and not line.startswith('def '):
            current_indent = len(line) - len(line.lstrip())
            if current_indent >= main_indent:
                # Dedent the line
                line = line[main_indent:]
            elif stripped and current_indent < main_indent:
                # We've exited the main function
                in_main_function = False

        # Replace args["xxx"] with actual variable
        for arg in arg_names:
            patterns_to_replace = [
                (f'args["{arg}"]', arg),
                (f"args['{arg}']", arg),
                (f'args.get("{arg}"', f'{arg}  # args.get("{arg}"'),
                (f"args.get('{arg}'", f"{arg}  # args.get('{arg}'"),
            ]
            for old, new in patterns_to_replace:
                if old in line:
                    line = line.replace(old, new)

        # Rename variables for SMUS compatibility
        # 'glue.' -> 'glueContext.' (if using glue as alias)
        if 'glue.' in line and 'glueContext' not in line and 'awsglue' not in line:
            line = line.replace('glue.', 'glueContext.')

        result_lines.append(line)

    # Clean up multiple consecutive empty lines
    cleaned_lines = []
    prev_empty = False
    for line in result_lines:
        is_empty = not line.strip()
        if is_empty and prev_empty:
            continue
        cleaned_lines.append(line)
        prev_empty = is_empty

    # Remove leading/trailing empty lines
    while cleaned_lines and not cleaned_lines[0].strip():
        cleaned_lines.pop(0)
    while cleaned_lines and not cleaned_lines[-1].strip():
        cleaned_lines.pop()

    return '\n'.join(cleaned_lines)


def build_glue_notebook_cells(
    script: str,
    metadata: dict[str, Any] | None = None,
    job_name: str = "glue-job",
    connection_name: str = "project.spark.compatibility",
) -> list[dict[str, Any]]:
    """Build Glue interactive session compatible notebook cells.

    Matches SMUS Visual ETL notebook format:
    1. Code cell with %%configure -n <connection> and full JSON config
    2. Code cell with %%pyspark <connection> for imports
    3. Code cell with %%pyspark <connection> for SparkContext/SparkSession init
    4. Code cell(s) with %%pyspark <connection> for the actual script logic
    """
    cells = []

    # Extract arguments from original script
    arg_names, _ = extract_resolved_options(script)

    # Get default values from metadata
    default_args = {}
    if metadata and isinstance(metadata.get("default_arguments"), dict):
        for key, val in metadata["default_arguments"].items():
            clean_key = key.lstrip('-')
            default_args[clean_key] = val

    # Cell 1: Configure cell with -n flag (not --name) and full JSON config
    config_lines = [
        f"%%configure -n {connection_name}\n",
        "{\n",
        '    "number_of_workers": 10,\n',
        '    "session_type": "etl",\n',
        '    "glue_version": "5.1",\n',
        '    "worker_type": "G.1X",\n',
        '    "idle_timeout": 15,\n',
        '    "timeout": 60,\n',
        '    "--enable-glue-datacatalog": "true",\n',
        '    "--enable-auto-scaling": "true"\n',
        "}\n",
    ]

    cells.append({
        "cell_type": "code",
        "id": "glue-config",
        "metadata": {},
        "execution_count": 0,
        "outputs": [],
        "source": config_lines,
    })

    # Cell 2: Imports cell with %%pyspark magic
    import_lines = [
        f"%%pyspark {connection_name}\n",
        "import sys\n",
        "from pyspark.context import SparkContext\n",
        "from pyspark.sql import SparkSession\n",
        "\n",
        "import json\n",
        "import boto3\n",
        "import logging\n",
        "from typing import Optional\n",
        "from awsglue.utils import getResolvedOptions\n",
        "from pyspark.sql.functions import *\n",
        "from awsglue.context import GlueContext\n",
        "from awsglue.job import Job\n",
    ]

    cells.append({
        "cell_type": "code",
        "id": "imports",
        "metadata": {},
        "execution_count": 0,
        "outputs": [],
        "source": import_lines,
    })

    # Cell 3: SparkContext/SparkSession initialization
    # Also bootstraps `glueContext` and the `glue` alias used by some
    # legacy Glue scripts as a parameter shorthand. Without these,
    # function calls like `_read_table(glue, args, ...)` lifted out of
    # the original `def main():` raise NameError at runtime.
    init_lines = [
        f"%%pyspark {connection_name}\n",
        "sc = SparkContext.getOrCreate()\n",
        "spark = SparkSession.builder.getOrCreate()\n",
        "glueContext = GlueContext(sc)\n",
        "glue = glueContext  # alias used by some original Glue scripts\n",
    ]

    cells.append({
        "cell_type": "code",
        "id": "spark-init",
        "metadata": {},
        "execution_count": 0,
        "outputs": [],
        "source": init_lines,
    })

    # Cell 4: Variables cell (if there are arguments to set).
    # In addition to the per-arg top-level vars (which match the
    # rewrites the transform applies to `args["..."]` references), we
    # also bundle the values into an `args` dict so that bare `args`
    # references in function calls (`_read_table(glue, args, ...)`)
    # also resolve. The dict mirrors the shape `getResolvedOptions`
    # would have returned in a Glue job runtime.
    if arg_names:
        var_lines = [f"%%pyspark {connection_name}\n"]
        var_lines.append("# Job parameters - modify as needed\n")
        for arg in arg_names:
            default_val = default_args.get(arg, f"<set-{arg}>")
            # Quote string values
            if isinstance(default_val, str):
                var_lines.append(f'{arg} = "{default_val}"\n')
            else:
                var_lines.append(f'{arg} = {default_val}\n')
        var_lines.append("\n")
        var_lines.append("# Bundle into args dict for getResolvedOptions-style scripts\n")
        var_lines.append("args = {\n")
        for arg in arg_names:
            var_lines.append(f'    "{arg}": {arg},\n')
        var_lines.append("}\n")

        cells.append({
            "cell_type": "code",
            "id": "job-variables",
            "metadata": {},
            "execution_count": 0,
            "outputs": [],
            "source": var_lines,
        })

    # Cell 5: Main code with %%pyspark magic
    transformed = transform_glue_to_smus(script, metadata)

    glue_lines = [f"%%pyspark {connection_name}\n"]

    # Add the transformed code
    for line in transformed.split('\n'):
        glue_lines.append(line + "\n" if line else "\n")

    cells.append({
        "cell_type": "code",
        "id": "glue-main",
        "metadata": {},
        "execution_count": 0,
        "outputs": [],
        "source": glue_lines,
    })

    return cells


def build_glue_notebook(
    script: str,
    metadata: dict[str, Any] | None = None,
    job_name: str = "glue-job",
    connection_name: str = "project.spark.compatibility",
) -> dict[str, Any]:
    """Build a Glue interactive session compatible notebook."""
    import datetime

    cells = build_glue_notebook_cells(script, metadata, job_name, connection_name)

    now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    timestamp = now.isoformat().replace("+00:00", "Z")

    return {
        "cells": cells,
        "metadata": {
            "kernelspec": {
                "display_name": "Python 3 (ipykernel)",
                "language": "python",
                "name": "python3",
            },
            "language_info": {
                "codemirror_mode": {
                    "name": "ipython",
                    "version": 3,
                },
                "file_extension": ".py",
                "mimetype": "text/x-python",
                "name": "python",
                "nbconvert_exporter": "python",
                "pygments_lexer": "ipython3",
                "version": "3.10.14",
            },
            "migration_tool": {
                "job_name": job_name,
                "format": "glue-interactive",
                "generated_at_utc": timestamp,
            },
        },
        "nbformat": 4,
        "nbformat_minor": 5,
    }


def build_smus_notebook_cells(
    script: str,
    metadata: dict[str, Any] | None = None,
    job_name: str = "glue-job",
) -> list[dict[str, Any]]:
    """Build SMUS-compatible notebook cells from a Glue script.

    Returns a list of notebook cells:
    1. Markdown cell with job info and instructions
    2. Code cell with configuration/variables
    3. Code cell(s) with the transformed PySpark code
    """
    cells = []

    # Extract arguments
    arg_names, _ = extract_resolved_options(script)

    # Get default values from metadata
    default_args = {}
    if metadata and isinstance(metadata.get("default_arguments"), dict):
        for key, val in metadata["default_arguments"].items():
            clean_key = key.lstrip('-')
            default_args[clean_key] = val

    # Cell 1: Markdown header with job info
    md_lines = [
        f"# {job_name}\n",
        "\n",
        "**Migrated from AWS Glue job**\n",
        "\n",
    ]
    if metadata:
        if metadata.get("role"):
            md_lines.append(f"- Original IAM Role: `{metadata['role']}`\n")
        if metadata.get("connection_references"):
            md_lines.append("- Connections: ")
            refs = metadata["connection_references"]
            conn_names = [r.get("original", "unknown") for r in refs if isinstance(r, dict)]
            md_lines.append(", ".join(f"`{c}`" for c in conn_names) + "\n")

    md_lines.extend([
        "\n",
        "**Usage:** Run the configuration cell first, then run the PySpark cell.\n",
    ])

    cells.append({
        "cell_type": "markdown",
        "id": "job-header",
        "metadata": {},
        "source": md_lines,
    })

    # Cell 2: Configuration cell (optional Spark config)
    config_lines = [
        "%%configure --name project.spark.compatibility\n",
        "{\n",
        '    "number_of_workers": 2,\n',
        '    "worker_type": "G.1X"\n',
        "}\n",
    ]

    cells.append({
        "cell_type": "code",
        "id": "spark-config",
        "metadata": {},
        "execution_count": None,
        "outputs": [],
        "source": config_lines,
    })

    # Cell 3: Variables cell (if there are arguments to set)
    if arg_names:
        var_lines = ["# Job parameters - modify as needed\n"]
        for arg in arg_names:
            default_val = default_args.get(arg, f"<set-{arg}>")
            # Quote string values
            if isinstance(default_val, str):
                var_lines.append(f'{arg} = "{default_val}"\n')
            else:
                var_lines.append(f'{arg} = {default_val}\n')
        var_lines.append("\n")
        var_lines.append("# Send variables to Spark session\n")
        for arg in arg_names:
            var_lines.append(f"%send_to_remote --name project.spark.compatibility --language python --local {arg} --remote {arg}\n")

        cells.append({
            "cell_type": "code",
            "id": "job-variables",
            "metadata": {},
            "execution_count": None,
            "outputs": [],
            "source": var_lines,
        })

    # Cell 4: Main PySpark code
    transformed = transform_glue_to_smus(script, metadata)

    pyspark_lines = ["%%pyspark project.spark.compatibility\n"]
    pyspark_lines.append("# GlueContext is available as 'glueContext'\n")
    pyspark_lines.append("# SparkSession is available as 'spark'\n")
    pyspark_lines.append("\n")

    # Add the transformed code
    for line in transformed.split('\n'):
        pyspark_lines.append(line + "\n" if line else "\n")

    cells.append({
        "cell_type": "code",
        "id": "pyspark-main",
        "metadata": {},
        "execution_count": None,
        "outputs": [],
        "source": pyspark_lines,
    })

    return cells


def build_smus_notebook(
    script: str,
    metadata: dict[str, Any] | None = None,
    job_name: str = "glue-job",
) -> dict[str, Any]:
    """Build a complete SMUS-compatible notebook from a Glue script."""
    import datetime

    cells = build_smus_notebook_cells(script, metadata, job_name)

    now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    timestamp = now.isoformat().replace("+00:00", "Z")

    return {
        "cells": cells,
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
                "format": "smus",
                "generated_at_utc": timestamp,
            },
        },
        "nbformat": 4,
        "nbformat_minor": 5,
    }
