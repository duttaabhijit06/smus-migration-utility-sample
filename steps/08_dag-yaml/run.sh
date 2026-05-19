#!/usr/bin/env bash
#
# steps/08_dag-yaml/run.sh — Step 8: Optional DAG-to-YAML conversion for
# MWAA Serverless.
#
# Gated by --convert-dags at the orchestrator level; this script is
# only invoked when the gate is open. We additionally no-op
# defensively when the Step 6 DAG inventory is empty so manual
# `bash run.sh` invocations against a fresh tree do not error.
#
# Behavior (Requirements 15.1, 15.2, 15.3, 15.4, 15.5, 15.6, 15.7, 19.4):
#   - For every *.py under steps/06_mwaa-extract/outputs/dags/, AST-
#     parse the file and enumerate operator-like class names. A name
#     is "operator-like" when it ends in "Operator" or "Sensor" and
#     appears as the function in an ast.Call (either as ast.Name or
#     ast.Attribute), which captures both bare-name imports and
#     fully qualified attribute references.
#   - Compute a verdict per DAG against the AWS-provider operator
#     allowlist below: empty operator set → Blocked (no operators
#     detected); every operator in the allowlist → Convertible; any
#     operator outside the allowlist → Blocked (with the offending
#     operators surfaced in the report row).
#   - Always produce outputs/compatibility-report.md with one row per
#     DAG and a summary line.
#   - For Convertible DAGs, invoke `python-to-yaml-dag-converter` as
#     a subprocess (Requirement 19.4). When the converter binary is
#     not on PATH, log a warning via mt_log and skip YAML emission for
#     that DAG (the DAG remains marked Convertible in the report; the
#     step does not fail).
#   - In apply mode, when at least one YAML file landed in
#     outputs/yaml/ AND ${MT_WORKDIR}/.git exists, `git add` the
#     repo-root data-pipelines/workflows/yaml/ tree and `git commit`
#     (Requirement 15.6). "Nothing to commit" is tolerated as success.

# Source the shared helper library before enabling strict mode so the
# library's conditional reads of optional MT_* env vars are not tripped
# by `set -u`. The orchestrator sets MT_WORKDIR to the tool's working
# directory; manual invocations fall back to the script's parent tree.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MT_WORKDIR="${MT_WORKDIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
# shellcheck source=../_lib/common.sh
# shellcheck disable=SC1091
source "${MT_WORKDIR}/steps/_lib/common.sh"

set -euo pipefail

mt_init "08_dag-yaml" -- "$@"

mt_status started

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

DAG_DIR="${MT_WORKDIR}/steps/06_mwaa-extract/outputs/dags"
YAML_OUT_DIR="$(mt_outputs_path "yaml")"
REPORT_PATH="$(mt_outputs_path "compatibility-report.md")"

# ---------------------------------------------------------------------------
# Empty-inventory guard
# ---------------------------------------------------------------------------
#
# When Step 6 has not run (or produced no DAG files), the step is a
# no-op success. The orchestrator gates Step 8 behind --convert-dags;
# this guard makes manual `bash run.sh` invocations safe on a fresh
# tree as well.
if [ ! -d "$DAG_DIR" ]; then
    mt_log "no DAG files to convert; skipping"
    mt_status ok
    exit 0
fi

DAG_FILE_COUNT="$(find "$DAG_DIR" -maxdepth 1 -type f -name '*.py' 2>/dev/null | wc -l | tr -d '[:space:]')"
if [ "${DAG_FILE_COUNT:-0}" = "0" ]; then
    mt_log "no DAG files to convert; skipping"
    mt_status ok
    exit 0
fi

mkdir -p "$YAML_OUT_DIR"

# ---------------------------------------------------------------------------
# AWS-provider operator allowlist (case-sensitive class names)
# ---------------------------------------------------------------------------
#
# Operators referenced by a DAG that are NOT in this list cause the
# DAG to be marked Blocked in the compatibility report (Requirement
# 15.4). The list reflects the AWS-provider operators that
# MWAA Serverless YAML supports today; it is a fixed contract baked
# into the step rather than data fetched at runtime so audits can
# diff the allowlist with the report verdicts.
AWS_PROVIDER_OPERATORS=(
    GlueJobOperator
    GlueCatalogPartitionSensor
    LambdaInvokeFunctionOperator
    LambdaCreateFunctionOperator
    S3KeySensor
    S3DeleteObjectsOperator
    S3CreateBucketOperator
    SnsPublishOperator
    AthenaOperator
    EmrCreateJobFlowOperator
    EmrAddStepsOperator
    EmrTerminateJobFlowOperator
    EmrStepSensor
    EmrServerlessStartJobOperator
    RedshiftSQLOperator
    RedshiftDataOperator
    RedshiftClusterSensor
    EcsRunTaskOperator
    BatchOperator
    BatchSensor
    SageMakerProcessingOperator
    SageMakerTrainingOperator
    SageMakerEndpointOperator
    SageMakerTransformOperator
    StepFunctionStartExecutionOperator
    KinesisAnalyticsCreateApplicationOperator
    KinesisAnalyticsStartApplicationOperator
    KinesisAnalyticsStopApplicationOperator
)

# Returns 0 iff $1 appears in AWS_PROVIDER_OPERATORS.
_is_allowed_operator() {
    local op="$1"
    local allowed
    for allowed in "${AWS_PROVIDER_OPERATORS[@]}"; do
        if [ "$op" = "$allowed" ]; then
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# Converter binary discovery
# ---------------------------------------------------------------------------
#
# `command -v` returns non-zero when the binary is missing; the
# `|| true` keeps `set -e` from aborting the run because we treat a
# missing converter as a soft warning condition: the report is still
# produced, the DAG is still marked Convertible, and YAML emission is
# skipped for that DAG (the orchestrator's contract per Requirement
# 19.4 is about subprocess invocation, not about gating on the
# operator's local toolchain).
CONVERTER_BIN="$(command -v python-to-yaml-dag-converter || true)"
if [ -z "$CONVERTER_BIN" ]; then
    mt_log "warning: python-to-yaml-dag-converter not found on PATH; YAML emission will be skipped (Convertible DAGs still listed in report)"
fi

# ---------------------------------------------------------------------------
# Per-DAG scan and verdict
# ---------------------------------------------------------------------------
#
# We sort filenames so the report and the YAML output are
# deterministic across runs (helpful for diffs and for property tests
# that compare outputs across invocations).
DAG_FILES=()
while IFS= read -r f; do
    [ -n "$f" ] && DAG_FILES+=("$f")
done < <(find "$DAG_DIR" -maxdepth 1 -type f -name '*.py' 2>/dev/null | LC_ALL=C sort)

CONVERTIBLE_COUNT=0
BLOCKED_COUNT=0
TOTAL_OPERATOR_COUNT=0
REPORT_ROWS=()

for dag in "${DAG_FILES[@]}"; do
    dag_name="$(basename "$dag")"
    mt_status action "scan ${dag_name}"

    # AST scan via inline python -c. Walk the tree and collect every
    # ast.Call whose `func` is an ast.Name or ast.Attribute and whose
    # bare class name ends in "Operator" or "Sensor". This captures
    # both bare-name and qualified attribute forms; we never assume
    # `from ... import` aliases line up with the actual class names.
    # Parse failures degrade gracefully to an empty operator set so a
    # malformed DAG is still represented in the report (it will be
    # marked Blocked because the operator set is empty, which matches
    # the "no operators detected" rule in the task contract).
    operators_csv="$(python3 -c '
import ast, json, sys

path = sys.argv[1]
ops = set()
try:
    with open(path, "r", encoding="utf-8") as fh:
        tree = ast.parse(fh.read(), filename=path)
except Exception:
    print("")
    sys.exit(0)

for node in ast.walk(tree):
    if not isinstance(node, ast.Call):
        continue
    func = node.func
    if isinstance(func, ast.Name):
        name = func.id
    elif isinstance(func, ast.Attribute):
        name = func.attr
    else:
        continue
    if name.endswith("Operator") or name.endswith("Sensor"):
        ops.add(name)

print(",".join(sorted(ops)))
' "$dag")"

    # Bash splitting: an empty CSV must produce an empty array, not a
    # 1-element array containing the empty string. We inspect the
    # string emptiness explicitly before reading into the array.
    operators=()
    if [ -n "$operators_csv" ]; then
        IFS=',' read -ra operators <<<"$operators_csv"
    fi

    # Verdict computation:
    #   - empty operator set     → Blocked ("no operators detected")
    #   - every operator allowed → Convertible
    #   - any operator outside   → Blocked (offenders surfaced)
    verdict=""
    blocked_offenders=()
    if [ "${#operators[@]}" -eq 0 ]; then
        verdict="Blocked"
        blocked_reason="no operators detected"
    else
        for op in "${operators[@]}"; do
            TOTAL_OPERATOR_COUNT=$((TOTAL_OPERATOR_COUNT + 1))
            if ! _is_allowed_operator "$op"; then
                blocked_offenders+=("$op")
            fi
        done
        if [ "${#blocked_offenders[@]}" -gt 0 ]; then
            verdict="Blocked"
        else
            verdict="Convertible"
        fi
    fi

    # Render cells. Bash's `${arr[*]}` join uses only the first
    # character of IFS, so we use the default-IFS join (a single
    # space) and then s/space/, / via parameter expansion to get
    # the comma-space separator used in the design example.
    if [ "${#operators[@]}" -gt 0 ]; then
        operators_display="${operators[*]}"
        operators_display="${operators_display// /, }"
    else
        operators_display="(none)"
    fi

    if [ "$verdict" = "Blocked" ]; then
        if [ "${#blocked_offenders[@]}" -gt 0 ]; then
            offenders_display="${blocked_offenders[*]}"
            offenders_display="${offenders_display// /, }"
            verdict_display="Blocked (non-AWS-provider: ${offenders_display})"
        else
            verdict_display="Blocked (${blocked_reason})"
        fi
        BLOCKED_COUNT=$((BLOCKED_COUNT + 1))
    else
        verdict_display="Convertible"
        CONVERTIBLE_COUNT=$((CONVERTIBLE_COUNT + 1))
    fi

    REPORT_ROWS+=("| ${dag_name} | ${operators_display} | ${verdict_display} |")

    # Convertible DAGs trigger the converter subprocess. Apply mode
    # invokes the binary; dry-run mode prints the would-be command.
    # When the binary is not installed we log a warning and continue.
    if [ "$verdict" = "Convertible" ]; then
        if mt_apply_mode; then
            if [ -n "$CONVERTER_BIN" ]; then
                mt_status action "convert ${dag_name}"
                "$CONVERTER_BIN" "$dag" --output "$YAML_OUT_DIR"
            else
                mt_log "skipping YAML emission for ${dag_name}: python-to-yaml-dag-converter not installed"
            fi
        else
            mt_dryrun "python-to-yaml-dag-converter \"${dag}\" --output \"${YAML_OUT_DIR}\""
        fi
    fi
done

# ---------------------------------------------------------------------------
# Render the compatibility report
# ---------------------------------------------------------------------------
{
    printf '# DAG → YAML Compatibility Report\n\n'
    printf '| DAG file | Operators | Verdict |\n'
    printf '|---|---|---|\n'
    for row in "${REPORT_ROWS[@]}"; do
        printf '%s\n' "$row"
    done
    printf '\n**Summary:** Convertible: %s, Blocked: %s, Total operators: %s\n' \
        "$CONVERTIBLE_COUNT" "$BLOCKED_COUNT" "$TOTAL_OPERATOR_COUNT"
} >"$REPORT_PATH"
mt_log "wrote $REPORT_PATH"

# ---------------------------------------------------------------------------
# Apply-mode commit
# ---------------------------------------------------------------------------
#
# Conditions (Requirement 15.6):
#   - apply mode is active
#   - at least one YAML file landed in outputs/yaml/
#   - a working tree exists at ${MT_WORKDIR}/.git
#
# The git commit tolerates "nothing to commit" so a re-run that
# produces the same YAML set still records a successful step.
if mt_apply_mode; then
    yaml_files=()
    shopt -s nullglob
    for f in "$YAML_OUT_DIR"/*.yaml "$YAML_OUT_DIR"/*.yml; do
        yaml_files+=("$f")
    done
    shopt -u nullglob

    if [ "${#yaml_files[@]}" -gt 0 ] && [ -d "${MT_WORKDIR}/.git" ]; then
        DEST_DIR="${MT_WORKDIR}/data-pipelines/workflows/yaml"
        mkdir -p "$DEST_DIR"
        cp "${yaml_files[@]}" "$DEST_DIR/"
        mt_status action "git add data-pipelines/workflows/yaml/"
        (cd "$MT_WORKDIR" && git add data-pipelines/workflows/yaml/)
        mt_status action "git commit"
        # Tolerate "nothing to commit": git exits non-zero with a
        # message containing "nothing to commit" when there are no
        # staged changes, which is a normal idempotent re-run path.
        commit_out=""
        commit_rc=0
        commit_out="$(cd "$MT_WORKDIR" && git commit -m "Step 8: convert AWS-only DAGs to MWAA Serverless YAML" 2>&1)" || commit_rc=$?
        if [ "$commit_rc" -ne 0 ]; then
            if printf '%s' "$commit_out" | grep -q -E 'nothing to commit|no changes added to commit'; then
                mt_log "git commit: nothing to commit (idempotent re-run)"
            else
                printf '%s\n' "$commit_out" >&2
                mt_status error "git commit failed"
                exit 1
            fi
        else
            printf '%s\n' "$commit_out"
        fi
        mt_log "committed ${#yaml_files[@]} YAML file(s) to data-pipelines/workflows/yaml/"
    elif [ "${#yaml_files[@]}" -gt 0 ]; then
        mt_log "produced ${#yaml_files[@]} YAML file(s) but ${MT_WORKDIR}/.git is absent; skipping commit"
    else
        mt_log "no YAML files produced; skipping commit"
    fi
fi

mt_status ok
exit 0
