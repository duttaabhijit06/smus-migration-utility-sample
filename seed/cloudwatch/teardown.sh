#!/usr/bin/env bash
#
# seed/cloudwatch/teardown.sh — Seed_Service_Module teardown for Amazon
# CloudWatch.
#
# Removes the resources `seed/cloudwatch/create.sh` provisioned, in the
# strict reverse of the create order (Requirement 20.8). create.sh creates
# log groups, then the alarms, then the dashboard, so teardown removes:
#
#   1. Dashboard via `aws cloudwatch delete-dashboards`
#   2. Alarms    via `aws cloudwatch delete-alarms`
#   3. Log groups via `aws logs delete-log-group` (one call per group)
#
# Deletion gating (Requirement 20.31 / task 24.10):
#   - Every resource name MUST begin with `${SBX_SEED_NAME_PREFIX}-` (or
#     embed the prefix in the AWS-mandated log-group namespace path
#     `/aws/lambda/${SBX_SEED_NAME_PREFIX}-`), AND
#   - Every resource ID MUST be recorded in `./seed/seed.state.json`
#     under `.services.cloudwatch.resources`.
#
# A candidate failing either check is skipped with a `STATUS: skip ...`
# line and is never deleted, even when it appears in the same account.
# This protects non-seed customer resources that share the seed AWS
# account.
#
# The Glue log group `/aws-glue/jobs/output` (the AWS-default Glue job
# stdout log group) is recorded by `create.sh` but its path does NOT
# include the seed prefix — that AWS-mandated path is shared across all
# Glue jobs in the account. Per Requirement 20.31, this teardown
# intentionally skips deleting it: removing the shared `/aws-glue/jobs/
# output` log group would destroy log streams from any non-seed Glue
# job in the same account. Operators who want it removed should do so
# manually after confirming there are no non-seed Glue jobs.
#
# Run modes (Requirement 20.2): default is dry-run; `--apply` issues the
# `aws ... delete-*` commands. Mutual exclusion of `--apply` and
# `--dry-run` is enforced by `sbx_init` (Requirement 20.4).
#

set -euo pipefail

__cw_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SBX_WORKDIR="${SBX_WORKDIR:-$(dirname "$(dirname "$__cw_dir")")}"
export SBX_WORKDIR

# shellcheck source=../_lib/common.sh disable=SC1091
source "${SBX_WORKDIR}/seed/_lib/common.sh"

sbx_init "cloudwatch" "$@"
sbx_require_var SBX_REGION
sbx_require_var SBX_SOURCE_ACCOUNT_ID
sbx_require_var SBX_SEED_NAME_PREFIX
sbx_assert_same_account

PREFIX="${SBX_SEED_NAME_PREFIX}-"

# -----------------------------------------------------------------------------
# Read recorded resource identifiers from `seed.state.json`. If the
# cloudwatch slot is absent (file missing or service not yet provisioned)
# OR already torn down, this teardown is a clean no-op.
# -----------------------------------------------------------------------------

CW_STATUS="$(sbx_state_get '.services.cloudwatch.status' || true)"
if [ -z "$CW_STATUS" ] || [ "$CW_STATUS" = "torn_down" ]; then
    sbx_status ok "cloudwatch teardown: no recorded state (status='${CW_STATUS}'); nothing to delete"
    exit 0
fi

# Pull recorded names. The dashboard slot is a single object
# (.services.cloudwatch.resources.dashboard.name); the alarms and
# log_groups slots are arrays. We use newline-separated strings + a
# `while read` loop below (rather than `mapfile`) so this works under
# bash 3.2 (the macOS system bash), matching the convention in sibling
# teardown.sh scripts (e.g. seed/glue/teardown.sh).
REC_DASHBOARD="$(sbx_state_get '.services.cloudwatch.resources.dashboard.name' 2>/dev/null || true)"
REC_ALARMS="$(sbx_state_get     '.services.cloudwatch.resources.alarms[]?.name'     2>/dev/null || true)"
REC_LOG_GROUPS="$(sbx_state_get '.services.cloudwatch.resources.log_groups[]?.name' 2>/dev/null || true)"

# -----------------------------------------------------------------------------
# Prefix gate (Requirement 20.31 second condition). A log-group name like
# `/aws/lambda/<prefix>-fn-1` does not START with `<prefix>-` because of
# the AWS-mandated namespace path, so the gate accepts:
#
#   * `<prefix>-...`            — direct prefix (alarms, dashboard)
#   * `/aws/lambda/<prefix>-...` — Lambda log groups
#
# Any other shape is treated as un-owned and skipped. This is what
# protects the AWS-shared `/aws-glue/jobs/output` log group from being
# deleted: it is recorded in state but its name has no seed prefix.
# -----------------------------------------------------------------------------

_is_seed_owned() {
    local _name="$1"
    case "$_name" in
        "${PREFIX}"*)                    return 0 ;;
        "/aws/lambda/${PREFIX}"*)        return 0 ;;
        *)                               return 1 ;;
    esac
}

# =============================================================================
# 1. Delete dashboard (reverse of create order — created last, deleted first).
# =============================================================================

if [ -n "$REC_DASHBOARD" ]; then
    if _is_seed_owned "$REC_DASHBOARD"; then
        sbx_aws cloudwatch delete-dashboards \
            --region "$SBX_REGION" \
            --dashboard-names "$REC_DASHBOARD"
    else
        sbx_status skip "dashboard '${REC_DASHBOARD}' does not match seed prefix; skipping"
    fi
fi

# =============================================================================
# 2. Delete alarms.
# =============================================================================

while IFS= read -r _alarm; do
    [ -z "$_alarm" ] && continue
    if ! _is_seed_owned "$_alarm"; then
        sbx_status skip "alarm '${_alarm}' does not match seed prefix; skipping"
        continue
    fi
    sbx_aws cloudwatch delete-alarms \
        --region "$SBX_REGION" \
        --alarm-names "$_alarm"
done < <(printf '%s\n' "$REC_ALARMS")

# =============================================================================
# 3. Delete log groups. One `delete-log-group` call per group: the AWS
#    CLI does not accept an array of log group names for delete.
#
#    The seed-default Glue log group `/aws-glue/jobs/output` is recorded
#    by create.sh but its name has no seed prefix, so the prefix gate
#    intentionally rejects it and this loop skips the delete. This is
#    correct — that path is shared with every Glue job in the account.
# =============================================================================

while IFS= read -r _lg; do
    [ -z "$_lg" ] && continue
    if ! _is_seed_owned "$_lg"; then
        sbx_status skip "log group '${_lg}' does not match seed prefix (shared/external); skipping"
        continue
    fi
    sbx_aws logs delete-log-group \
        --region "$SBX_REGION" \
        --log-group-name "$_lg"
done < <(printf '%s\n' "$REC_LOG_GROUPS")

# -----------------------------------------------------------------------------
# Mark the cloudwatch slot as torn down. We replace the resources
# sub-object with empty arrays / a null dashboard so a subsequent
# --apply re-creates from scratch with no stale identifiers, and we set
# status="torn_down" so a repeat teardown is a no-op (handled by the
# early-exit guard above). Apply-only — dry-run never mutates state.
# -----------------------------------------------------------------------------

if sbx_apply_mode; then
    sbx_state_set_service cloudwatch \
        '{"status":"torn_down","resources":{"log_groups":[],"alarms":[],"dashboard":null}}'
fi

sbx_status ok "cloudwatch teardown complete"
