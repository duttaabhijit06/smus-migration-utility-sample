#!/usr/bin/env bash
#
# seed/cloudwatch/create.sh — Seed_Service_Module for Amazon CloudWatch.
#
# Provisions the minimum CloudWatch surface area the Migration_Tool's
# inventory step (Requirement 17.6) needs to find when it later runs against
# this account. Per Requirement 20.21 and task 24.10 the module creates:
#
#   - 2 metric alarms on the AWS/Lambda `Errors` metric for the two seed
#     Lambda functions provisioned by `seed/lambda/create.sh` (task 24.9):
#         * `${SBX_SEED_NAME_PREFIX}-alarm-1` — bound to function 1
#         * `${SBX_SEED_NAME_PREFIX}-alarm-2` — bound to function 2
#     Function names are derived from `.services.lambda.function_arns` in
#     `./seed/seed.state.json` via `sbx_state_get`.
#
#   - 1 dashboard `${SBX_SEED_NAME_PREFIX}-dashboard` with a placeholder
#     text widget that names the seed.
#
#   - 2 log groups (Requirement 20.21 — one fed by Lambda from 20.20, one
#     fed by a Glue job from 20.15):
#         * `/aws/lambda/${SBX_SEED_NAME_PREFIX}-fn-1`
#           AWS Lambda auto-creates a function's log group on first
#           invocation at `/aws/lambda/<function-name>`. We materialise it
#           eagerly with `aws logs create-log-group` so the inventory step
#           always sees it, regardless of whether the function has been
#           invoked yet.
#         * `/aws-glue/jobs/output`
#           The AWS-standard log group that AWS Glue auto-writes ETL
#           job stdout/stderr to (the literal `output` stream is one of
#           the default streams Glue creates alongside `error` and
#           `logs-v2`). Materialised eagerly with `aws logs
#           create-log-group` so the inventory step can enumerate it
#           even before any Glue job has run. Because this path is the
#           AWS-shared default (not seed-prefixed), `teardown.sh`
#           records it in state but DOES NOT delete it — the prefix
#           gate intentionally rejects it so a teardown cannot destroy
#           log streams from non-seed Glue jobs that share this account.
#
# Dependencies (task 24.10):
#   - `seed/lambda/create.sh` MUST have run; this module reads BOTH
#     Lambda function ARNs from `.services.lambda.function_arns[]`.
#     If `[0]` or `[1]` is missing, this module halts with
#     `STATUS: error dependency_not_provisioned` BEFORE any state-changing
#     AWS CLI command, so a misordered invocation cannot strand a
#     partial CloudWatch surface.
#   - `seed/glue/create.sh` MUST have run; this module reads the seed
#     Glue job name from `.services.glue.resources.jobs[0].name` to
#     validate that there is a real Glue job that will write to the
#     `/aws-glue/jobs/output` log group it provisions. If
#     `.services.glue.resources.jobs[0].name` is missing, this module
#     halts with `STATUS: error dependency_not_provisioned` BEFORE any
#     state-changing AWS CLI command. The job name itself is not
#     embedded in the log-group path (Glue uses a single shared
#     `output` log group across all jobs in the account by default).
#
# Resource-name prefix gating (Requirement 20.29 / task 24.10):
#   - Direct names start with `${SBX_SEED_NAME_PREFIX}-`:
#         * alarm `${SBX_SEED_NAME_PREFIX}-alarm-1`
#         * alarm `${SBX_SEED_NAME_PREFIX}-alarm-2`
#         * dashboard `${SBX_SEED_NAME_PREFIX}-dashboard`
#   - Log-group paths embed the prefix in the AWS-mandated namespace:
#         * `/aws/lambda/${SBX_SEED_NAME_PREFIX}-fn-1`
#         * `/aws-glue/jobs/output` (the AWS-mandated default log
#           group for Glue ETL job stdout)
#
# Post-migration idempotency (Requirement 20.32 / task 24.10):
#   - This module issues zero `aws datazone create-*` commands.
#   - This module never targets the SMUS_Domain ID or Admin_Project ID
#     recorded in `./config/migration.config.json`. A re-run after the
#     Migration_Tool has completed has no effect on SMUS resources.
#
# Run modes (Requirements 20.2, 20.3, 20.4):
#   - `--apply`: actually create resources (skipping any that already
#     exist by name, per Requirement 20.13).
#   - `--dry-run` (default per Requirement 20.2): print the would-be AWS
#     CLI commands and write nothing to seed.state.json.
#

set -euo pipefail

# -----------------------------------------------------------------------------
# Resolve the seed root from this script's location so the module can be
# invoked from any cwd. The grandparent dir (`seed/`) is the seed root and
# its parent is the workspace root that hosts both ./seed/ and ./config/
# (where the same-account check reads from).
__cw_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SBX_WORKDIR="${SBX_WORKDIR:-$(dirname "$(dirname "$__cw_dir")")}"
export SBX_WORKDIR

# shellcheck source=../_lib/common.sh disable=SC1091
source "${SBX_WORKDIR}/seed/_lib/common.sh"

# sbx_init parses --apply / --dry-run, validates the three core SBX_* env
# vars (region, source account ID, seed name prefix), opens the per-
# invocation log file, and exports SBX_APPLY / SBX_DRY_RUN.
sbx_init "cloudwatch" "$@"

# Re-state the required-var contract so a future refactor of sbx_init
# that loosens the check still surfaces the missing input here.
# sbx_require_var emits `STATUS: missing_var <NAME>` and exits 64 on empty.
sbx_require_var SBX_REGION
sbx_require_var SBX_SOURCE_ACCOUNT_ID
sbx_require_var SBX_SEED_NAME_PREFIX

# Same-account contract (Requirement 20.28). Halts with exit 64 + a
# `STATUS: error same_account_contract_violated` line if
# `./config/migration.config.json` exists and its `source_account_id`
# disagrees with `./seed/seed.config.json`. No-op when the migration
# config has not yet been created.
sbx_assert_same_account

# jq is mandatory: we both build dashboard JSON bodies and merge state.
# The state-merge helper enforces this too, but failing here gives a
# cleaner error before any AWS call.
if ! command -v jq >/dev/null 2>&1; then
    sbx_status error jq_required
    exit 64
fi

# -----------------------------------------------------------------------------
# Dependency gate — read BOTH upstream Lambda function ARNs from
# `seed.state.json` at `.services.lambda.function_arns[]` (the schema
# established by `seed/lambda/create.sh`, task 24.9). Each function NAME
# is the trailing segment of the ARN
# (`arn:aws:lambda:<region>:<account>:function:<NAME>`); we use them to
# parameterise the alarm dimensions. Also read the seed Glue job name
# from `.services.glue.resources.jobs[0].name` to validate that there
# is a real Glue job that will eventually write to the
# `/aws-glue/jobs/output` log group provisioned below. If any required
# upstream identifier is missing we halt before any aws command so a
# misordered invocation cannot create dangling resources.
# -----------------------------------------------------------------------------

LAMBDA_FN_1_ARN="$(sbx_state_get '.services.lambda.function_arns[0]' || true)"
LAMBDA_FN_2_ARN="$(sbx_state_get '.services.lambda.function_arns[1]' || true)"

if [ -z "${LAMBDA_FN_1_ARN}" ] || [ -z "${LAMBDA_FN_2_ARN}" ]; then
    if sbx_apply_mode; then
        sbx_status error "dependency_not_provisioned (.services.lambda.function_arns[0..1] empty); run seed/lambda/create.sh first"
        exit 64
    fi
    # Dry-run softening: per project bug fix 1a, lambda's state writes
    # are gated behind apply mode, so a dry-run sequenced run will see
    # empty state for upstream lambda even though lambda's create.sh
    # ran successfully. Substitute deterministic placeholder ARNs so
    # the audit log can render the would-be cloudwatch wiring.
    LAMBDA_FN_1_ARN="arn:aws:lambda:${SBX_REGION}:${SBX_SOURCE_ACCOUNT_ID}:function:${SBX_SEED_NAME_PREFIX}-fn-1"
    LAMBDA_FN_2_ARN="arn:aws:lambda:${SBX_REGION}:${SBX_SOURCE_ACCOUNT_ID}:function:${SBX_SEED_NAME_PREFIX}-fn-2"
    sbx_log "dry-run: .services.lambda.function_arns is empty; using placeholder ARNs"
fi

# Glue job name. `seed/glue/create.sh` writes
# `.services.glue.resources.jobs` as an array of strings (job names),
# not as an array of objects. We tolerate BOTH shapes — the bare-name
# array (current schema) and a future {name, arn} object array — so a
# downstream schema change does not silently break this dependency
# check. The `.[0]` selector falls through to `// .[0].name` when the
# entry is an object.
GLUE_JOB_NAME="$(sbx_state_get '(.services.glue.resources.jobs[0] | if type == "string" then . else .name // empty end)' || true)"

if [ -z "${GLUE_JOB_NAME}" ]; then
    if sbx_apply_mode; then
        sbx_status error "dependency_not_provisioned (.services.glue.resources.jobs[0] empty); run seed/glue/create.sh --phase=1 first"
        exit 64
    fi
    GLUE_JOB_NAME="${SBX_SEED_NAME_PREFIX}-etl-job"
    sbx_log "dry-run: .services.glue.resources.jobs is empty; using placeholder ${GLUE_JOB_NAME}"
fi

# Parse the function name out of each ARN. Tolerant of the
# `arn:aws:lambda:...:function:NAME` form and a bare name (defensive,
# in case a future seed/lambda/create.sh schema persists names rather
# than ARNs).
_fn_name_from_arn() {
    local _arn="$1"
    case "$_arn" in
        *":function:"*) printf '%s\n' "${_arn##*:function:}" ;;
        *)              printf '%s\n' "$_arn" ;;
    esac
}

LAMBDA_FN_1_NAME="$(_fn_name_from_arn "$LAMBDA_FN_1_ARN")"
LAMBDA_FN_2_NAME="$(_fn_name_from_arn "$LAMBDA_FN_2_ARN")"

if [ -z "$LAMBDA_FN_1_NAME" ] || [ -z "$LAMBDA_FN_2_NAME" ]; then
    sbx_status error "dependency_not_provisioned (could not parse function names from ARNs '${LAMBDA_FN_1_ARN}', '${LAMBDA_FN_2_ARN}')"
    exit 64
fi

# -----------------------------------------------------------------------------
# Resource names. Direct names start with the seed prefix; log-group
# paths embed the prefix in the AWS namespace path segment.
# -----------------------------------------------------------------------------

ALARM_1_NAME="${SBX_SEED_NAME_PREFIX}-alarm-1"
ALARM_2_NAME="${SBX_SEED_NAME_PREFIX}-alarm-2"
DASHBOARD_NAME="${SBX_SEED_NAME_PREFIX}-dashboard"
LAMBDA_LOG_GROUP="/aws/lambda/${SBX_SEED_NAME_PREFIX}-fn-1"
# AWS Glue's continuous-logging default writes ETL job stdout to
# `/aws-glue/jobs/output` (a single shared log group across every Glue
# job in the account). We materialise it eagerly so the inventory step
# (Requirement 17.6) finds it; the seed Glue job from `seed/glue/`
# validated above will write here on its first run.
GLUE_LOG_GROUP="/aws-glue/jobs/output"

# Deterministic log-group ARN shape (CloudWatch Logs). create-log-group
# does not echo back the ARN we want to persist, so we build it from the
# inputs we already validated. Trailing `:*` is the canonical shape AWS
# uses for log-group ARNs in IAM policies.
LAMBDA_LOG_GROUP_ARN="arn:aws:logs:${SBX_REGION}:${SBX_SOURCE_ACCOUNT_ID}:log-group:${LAMBDA_LOG_GROUP}:*"
GLUE_LOG_GROUP_ARN="arn:aws:logs:${SBX_REGION}:${SBX_SOURCE_ACCOUNT_ID}:log-group:${GLUE_LOG_GROUP}:*"

# -----------------------------------------------------------------------------
# Idempotency probes (Requirement 20.13).
#
# Each helper returns 0 iff the named resource already exists. In dry-run
# mode every probe is routed through `sbx_aws` (so the would-be describe/
# get/list call shows up in the log) and then returns "not exists" so the
# subsequent create command is also printed — the operator sees the full
# would-be sequence. In apply mode we additionally call `aws` directly to
# parse the response and decide whether to skip the create.
# -----------------------------------------------------------------------------

_cw_alarm_exists() {
    local _name="$1"
    if ! sbx_apply_mode; then
        # Render the would-be probe through sbx_aws so the dry-run log
        # captures the `DRY-RUN: aws cloudwatch describe-alarms ...` line,
        # then fall through as "not exists" so the subsequent create
        # command also renders. Operator sees the full would-be sequence.
        sbx_aws cloudwatch describe-alarms \
            --region "$SBX_REGION" \
            --alarm-names "$_name"
        return 1
    fi
    sbx_status action "aws cloudwatch describe-alarms"
    local _found
    _found="$(aws cloudwatch describe-alarms \
        --region "$SBX_REGION" \
        --alarm-names "$_name" \
        --query 'MetricAlarms[].AlarmName' \
        --output text 2>/dev/null || true)"
    [ -n "$_found" ] && [ "$_found" != "None" ]
}

# `aws cloudwatch get-dashboard --dashboard-name <name>` returns the
# dashboard body on a hit and exits non-zero (ResourceNotFoundException)
# on a miss, which is exactly the per-resource probe shape Requirement
# 20.13 calls for. We do not use list-dashboards here because the user-
# facing contract names get-dashboard.
_cw_dashboard_exists() {
    local _name="$1"
    if ! sbx_apply_mode; then
        sbx_aws cloudwatch get-dashboard \
            --region "$SBX_REGION" \
            --dashboard-name "$_name"
        return 1
    fi
    sbx_status action "aws cloudwatch get-dashboard"
    aws cloudwatch get-dashboard \
        --region "$SBX_REGION" \
        --dashboard-name "$_name" \
        >/dev/null 2>&1
}

_cw_log_group_exists() {
    local _name="$1"
    if ! sbx_apply_mode; then
        sbx_aws logs describe-log-groups \
            --region "$SBX_REGION" \
            --log-group-name-prefix "$_name"
        return 1
    fi
    sbx_status action "aws logs describe-log-groups"
    local _found
    _found="$(aws logs describe-log-groups \
        --region "$SBX_REGION" \
        --log-group-name-prefix "$_name" \
        --query "logGroups[?logGroupName=='${_name}'].logGroupName" \
        --output text 2>/dev/null || true)"
    [ -n "$_found" ] && [ "$_found" != "None" ]
}

# -----------------------------------------------------------------------------
# Persisted-state helper — incremental writes to seed.state.json under
# `.services.cloudwatch.resources.{log_groups, alarms, dashboard}`. We
# deep-merge after each successful resource creation so a partial run
# (e.g. process killed between alarm and dashboard creation) leaves an
# accurate record of what was created (Requirement 20.12). Skipped in
# dry-run because no resources actually exist to record.
# -----------------------------------------------------------------------------

_cw_state_merge() {
    local _payload="$1"
    if ! sbx_apply_mode; then
        return 0
    fi
    sbx_state_set_service cloudwatch "$_payload"
}

# -----------------------------------------------------------------------------
# Dashboard body — a single placeholder text widget. The body is passed
# to `aws cloudwatch put-dashboard --dashboard-body` as a JSON string.
# We build it with `jq -n` so the seed name prefix is JSON-escaped
# correctly even if a future prefix value contains characters that need
# escaping.
# -----------------------------------------------------------------------------

_cw_build_dashboard_body() {
    jq -nc \
        --arg prefix "$SBX_SEED_NAME_PREFIX" \
        '{
            widgets: [
                {
                    type: "text",
                    x: 0, y: 0, width: 24, height: 3,
                    properties: {
                        markdown: ("# " + $prefix + " seed dashboard\nPlaceholder dashboard provisioned by seed/cloudwatch/create.sh.\nThis dashboard is created by the Seed_Script and is intended to be discovered by the Migration_Tool CloudWatch inventory step (Requirement 17.6).")
                    }
                }
            ]
        }'
}

# =============================================================================
# Main provisioning sequence.
# =============================================================================

sbx_status begin cloudwatch
sbx_status in-progress cloudwatch

sbx_log "cloudwatch seed start: region=${SBX_REGION} prefix=${SBX_SEED_NAME_PREFIX} mode=$([ "${SBX_APPLY:-}" = "1" ] && echo apply || echo dry-run)"
sbx_log "cloudwatch seed dependencies: lambda function 1='${LAMBDA_FN_1_NAME}' (arn='${LAMBDA_FN_1_ARN}')"
sbx_log "cloudwatch seed dependencies: lambda function 2='${LAMBDA_FN_2_NAME}' (arn='${LAMBDA_FN_2_ARN}')"
sbx_log "cloudwatch seed dependencies: glue job (validated, not embedded in path)='${GLUE_JOB_NAME}'"

# -----------------------------------------------------------------------------
# 1. Log groups.
#
#    `/aws/lambda/${SBX_SEED_NAME_PREFIX}-fn-1`
#        AWS Lambda auto-creates this log group on first invocation, but
#        we materialise it eagerly so the inventory step (Requirement 17.6)
#        always finds it regardless of whether the function has been
#        invoked yet.
#
#    `/aws-glue/jobs/output`
#        The AWS-mandated default log group AWS Glue auto-writes ETL
#        job stdout/stderr to. Materialised eagerly here so the
#        inventory step finds it even before the first Glue job run.
#        Fed by the seed Glue job from `seed/glue/create.sh` (task
#        24.5, Requirement 20.15). Because the path is shared with all
#        Glue jobs in the account (not seed-prefixed), `teardown.sh`
#        records it but does NOT delete it.
# -----------------------------------------------------------------------------

if _cw_log_group_exists "$LAMBDA_LOG_GROUP"; then
    sbx_log "log group '${LAMBDA_LOG_GROUP}' already exists; skipping create-log-group"
else
    sbx_aws logs create-log-group \
        --region "$SBX_REGION" \
        --log-group-name "$LAMBDA_LOG_GROUP"
fi

if _cw_log_group_exists "$GLUE_LOG_GROUP"; then
    sbx_log "log group '${GLUE_LOG_GROUP}' already exists; skipping create-log-group"
else
    sbx_aws logs create-log-group \
        --region "$SBX_REGION" \
        --log-group-name "$GLUE_LOG_GROUP"
fi

# Persist log group identifiers BEFORE the next state-changing AWS CLI
# command (Requirement 20.12). The deep-merge in sbx_state_set_service
# keeps any prior entries (e.g. from a partial earlier run) intact;
# `feeds` records which upstream module each log group is tied to so
# teardown ordering and operator diagnostics have the linkage. Both the
# log-group name (the user-facing key teardown reads) and its ARN (per
# task 24.10's "persist log group ARNs" contract) are recorded.
_cw_state_merge "$(jq -nc \
    --arg lambda_lg     "$LAMBDA_LOG_GROUP" \
    --arg lambda_lg_arn "$LAMBDA_LOG_GROUP_ARN" \
    --arg glue_lg       "$GLUE_LOG_GROUP" \
    --arg glue_lg_arn   "$GLUE_LOG_GROUP_ARN" \
    '{
        status: "in-progress",
        resources: {
            log_groups: [
                {name: $lambda_lg, arn: $lambda_lg_arn, feeds: "lambda"},
                {name: $glue_lg,   arn: $glue_lg_arn,   feeds: "glue"}
            ]
        }
    }')"

# -----------------------------------------------------------------------------
# 2. Metric alarms — `${SBX_SEED_NAME_PREFIX}-alarm-1` and `-alarm-2` on
#    AWS/Lambda `Errors` for the two seed Lambda functions. Statistic=Sum,
#    Period=60s, EvaluationPeriods=1, Threshold=1, ComparisonOperator=
#    GreaterThanOrEqualToThreshold, TreatMissingData=notBreaching. These
#    are seed-grade defaults; the Migration_Tool's inventory step does
#    not depend on the threshold values, only on the alarms' existence.
# -----------------------------------------------------------------------------

_cw_put_alarm() {
    local _alarm_name="$1"
    local _fn_name="$2"

    if _cw_alarm_exists "$_alarm_name"; then
        sbx_log "alarm '${_alarm_name}' already exists; skipping put-metric-alarm"
        return 0
    fi
    sbx_aws cloudwatch put-metric-alarm \
        --region "$SBX_REGION" \
        --alarm-name "$_alarm_name" \
        --alarm-description "Seed alarm: ${_fn_name} errors >= 1 in any 60s window" \
        --namespace "AWS/Lambda" \
        --metric-name "Errors" \
        --statistic "Sum" \
        --period 60 \
        --evaluation-periods 1 \
        --threshold 1 \
        --comparison-operator "GreaterThanOrEqualToThreshold" \
        --treat-missing-data "notBreaching" \
        --dimensions "Name=FunctionName,Value=${_fn_name}"
}

_cw_put_alarm "$ALARM_1_NAME" "$LAMBDA_FN_1_NAME"
_cw_put_alarm "$ALARM_2_NAME" "$LAMBDA_FN_2_NAME"

_cw_state_merge "$(jq -nc \
    --arg alarm_1 "$ALARM_1_NAME" \
    --arg fn_1    "$LAMBDA_FN_1_NAME" \
    --arg alarm_2 "$ALARM_2_NAME" \
    --arg fn_2    "$LAMBDA_FN_2_NAME" \
    '{
        status: "in-progress",
        resources: {
            alarms: [
                {name: $alarm_1, function_name: $fn_1},
                {name: $alarm_2, function_name: $fn_2}
            ]
        }
    }')"

# -----------------------------------------------------------------------------
# 3. Dashboard — `${SBX_SEED_NAME_PREFIX}-dashboard` with a single
#    placeholder text widget. Idempotency probe is `aws cloudwatch
#    get-dashboard` (per the user's contract for task 24.10), which
#    returns the body on hit and ResourceNotFoundException on miss.
# -----------------------------------------------------------------------------

if _cw_dashboard_exists "$DASHBOARD_NAME"; then
    sbx_log "dashboard '${DASHBOARD_NAME}' already exists; skipping put-dashboard"
else
    DASHBOARD_BODY="$(_cw_build_dashboard_body)"
    sbx_aws cloudwatch put-dashboard \
        --region "$SBX_REGION" \
        --dashboard-name "$DASHBOARD_NAME" \
        --dashboard-body "$DASHBOARD_BODY"
fi

# -----------------------------------------------------------------------------
# Final state write — full resource inventory plus terminal status. The
# `*` deep-merge in sbx_state_set_service replaces the resources arrays
# with their authoritative final values (jq's `*` semantics on arrays
# prefer the right operand) and overwrites status to "provisioned".
#
# Schema note: the dashboard slot is a single object (`dashboard`), per
# the user's task 24.10 contract ("persist alarm names, dashboard name,
# log group ARNs to seed.state.json under .services.cloudwatch.resources.
# {alarms,dashboard,log_groups}"). The alarms and log_groups slots are
# arrays because the module creates two of each.
# -----------------------------------------------------------------------------

_cw_state_merge "$(jq -nc \
    --arg alarm_1       "$ALARM_1_NAME" \
    --arg fn_1          "$LAMBDA_FN_1_NAME" \
    --arg alarm_2       "$ALARM_2_NAME" \
    --arg fn_2          "$LAMBDA_FN_2_NAME" \
    --arg dashboard     "$DASHBOARD_NAME" \
    --arg lambda_lg     "$LAMBDA_LOG_GROUP" \
    --arg lambda_lg_arn "$LAMBDA_LOG_GROUP_ARN" \
    --arg glue_lg       "$GLUE_LOG_GROUP" \
    --arg glue_lg_arn   "$GLUE_LOG_GROUP_ARN" \
    '{
        status: "provisioned",
        resources: {
            log_groups: [
                {name: $lambda_lg, arn: $lambda_lg_arn, feeds: "lambda"},
                {name: $glue_lg,   arn: $glue_lg_arn,   feeds: "glue"}
            ],
            alarms: [
                {name: $alarm_1, function_name: $fn_1},
                {name: $alarm_2, function_name: $fn_2}
            ],
            dashboard: {name: $dashboard}
        }
    }')"

sbx_status available cloudwatch
sbx_status ok "cloudwatch seed complete: 2 log groups, 2 alarms, 1 dashboard"
