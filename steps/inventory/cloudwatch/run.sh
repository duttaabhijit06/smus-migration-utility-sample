#!/usr/bin/env bash
#
# steps/inventory/cloudwatch/run.sh — Inventory step for Amazon CloudWatch.
#
# Read-only by construction. The orchestrator's pre-execution scanner
# rejects any aws verb outside {list, get, describe}; this script uses
# only `describe-alarms`, `list-dashboards`, and `describe-log-groups`,
# satisfying Requirements 17.2 and 18.1.
#
# Behavior summary (Requirements 17.1, 17.6, 17.8, 18.1, 18.3, 3.6):
#   - Calls `aws cloudwatch describe-alarms`,
#     `aws cloudwatch list-dashboards`, and `aws logs describe-log-groups`
#     once per run via mt_aws.
#   - Combines the three sources into a single `items[]` array. Each
#     item carries a `kind` field of `"alarm"`, `"dashboard"`, or
#     `"log-group"`.
#   - In apply mode, writes outputs/inventory.json. In dry-run, prints
#     `DRY-RUN: write <path>` and creates no inventory file.
#   - account_id is taken from MT_SOURCE_ACCOUNT_ID when set; otherwise
#     it is the literal string "unknown".
#

if [ -z "${MT_WORKDIR:-}" ]; then
    MT_WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
    export MT_WORKDIR
fi

# shellcheck source=../../_lib/common.sh
# shellcheck disable=SC1091
source "${MT_WORKDIR}/steps/_lib/common.sh"

set -euo pipefail

mt_init "inventory.cloudwatch" "${MT_WORKDIR}/steps/inventory/cloudwatch/outputs" -- "$@"
mt_status started

mt_require_var MT_AWS_REGION

if ! command -v jq >/dev/null 2>&1; then
    mt_status error "jq is required but not found on PATH"
    exit 64
fi

exec 3>&1

_aws_capture() {
    local _raw
    _raw="$(mt_aws "$@")"
    printf '%s\n' "$_raw" | grep -E '^(STATUS:|DRY-RUN:)' >&3 || true
    printf '%s\n' "$_raw" | grep -vE '^(STATUS:|DRY-RUN:)' || true
}

# ---------------------------------------------------------------------------
# 1. Discover alarms, dashboards, and log groups.
# ---------------------------------------------------------------------------

FETCHED_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ACCOUNT_ID="${MT_SOURCE_ACCOUNT_ID:-unknown}"
INVENTORY_PATH="$(mt_outputs_path inventory.json)"

ALARMS_JSON="$(_aws_capture cloudwatch describe-alarms --region "$MT_AWS_REGION")"
if [ -z "$(printf '%s' "$ALARMS_JSON" | tr -d '[:space:]')" ]; then
    ALARMS_JSON='{"MetricAlarms":[],"CompositeAlarms":[]}'
fi

DASHBOARDS_JSON="$(_aws_capture cloudwatch list-dashboards --region "$MT_AWS_REGION")"
if [ -z "$(printf '%s' "$DASHBOARDS_JSON" | tr -d '[:space:]')" ]; then
    DASHBOARDS_JSON='{"DashboardEntries":[]}'
fi

LOG_GROUPS_JSON="$(_aws_capture logs describe-log-groups --region "$MT_AWS_REGION")"
if [ -z "$(printf '%s' "$LOG_GROUPS_JSON" | tr -d '[:space:]')" ]; then
    LOG_GROUPS_JSON='{"logGroups":[]}'
fi

# Alarm items: describe-alarms returns both metric alarms and
# composite alarms in distinct top-level arrays. We merge them into
# a single `kind: "alarm"` series so consumers see one alarm list,
# preserving the per-alarm shape under `raw` for downstream auditing.
ALARM_ITEMS="$(printf '%s\n' "$ALARMS_JSON" | jq -c \
    '[(.MetricAlarms // [])[], (.CompositeAlarms // [])[] | {
        name: (.AlarmName // ""),
        arn:  (.AlarmArn  // ""),
        kind: "alarm",
        raw:  .
    }]')"

# Dashboard items: list-dashboards entries have `DashboardName` and
# `DashboardArn`.
DASHBOARD_ITEMS="$(printf '%s\n' "$DASHBOARDS_JSON" | jq -c \
    '[.DashboardEntries[]? | {
        name: (.DashboardName // ""),
        arn:  (.DashboardArn  // ""),
        kind: "dashboard",
        raw:  .
    }]')"

# Log group items: describe-log-groups entries have `logGroupName`
# and `arn` (lowercased keys, distinct from CloudWatch metric APIs).
LOG_GROUP_ITEMS="$(printf '%s\n' "$LOG_GROUPS_JSON" | jq -c \
    '[.logGroups[]? | {
        name: (.logGroupName // ""),
        arn:  (.arn // ""),
        kind: "log-group",
        raw:  .
    }]')"

ITEMS_JSON="$(jq -nc \
    --argjson a "$ALARM_ITEMS" \
    --argjson d "$DASHBOARD_ITEMS" \
    --argjson l "$LOG_GROUP_ITEMS" \
    '$a + $d + $l')"

TOTAL="$(printf '%s\n' "$ITEMS_JSON" | jq 'length')"
ALARMS_COUNT="$(printf '%s\n' "$ALARM_ITEMS" | jq 'length')"
DASHBOARDS_COUNT="$(printf '%s\n' "$DASHBOARD_ITEMS" | jq 'length')"
LOG_GROUPS_COUNT="$(printf '%s\n' "$LOG_GROUP_ITEMS" | jq 'length')"

# ---------------------------------------------------------------------------
# 2. Build canonical inventory document.
# ---------------------------------------------------------------------------

INVENTORY_JSON="$(jq -nc \
    --arg service "cloudwatch" \
    --arg fetched "$FETCHED_UTC" \
    --arg region  "$MT_AWS_REGION" \
    --arg account "$ACCOUNT_ID" \
    --argjson items "$ITEMS_JSON" \
    --argjson total "$TOTAL" \
    --argjson alarms "$ALARMS_COUNT" \
    --argjson dashboards "$DASHBOARDS_COUNT" \
    --argjson log_groups "$LOG_GROUPS_COUNT" \
    '{service: $service, fetched_utc: $fetched, region: $region, account_id: $account, items: $items, counts: {total: $total, alarms: $alarms, dashboards: $dashboards, log_groups: $log_groups}}')"

if mt_apply_mode; then
    printf '%s\n' "$INVENTORY_JSON" | jq '.' > "$INVENTORY_PATH"
    mt_log "wrote $INVENTORY_PATH (total=${TOTAL}, alarms=${ALARMS_COUNT}, dashboards=${DASHBOARDS_COUNT}, log_groups=${LOG_GROUPS_COUNT})"
else
    mt_dryrun "write $INVENTORY_PATH"
fi

mt_status ok
exit 0
