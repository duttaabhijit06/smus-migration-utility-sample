#!/usr/bin/env bash
#
# steps/inventory/flink-kda/run.sh — Inventory step for Apache Flink /
# Amazon Kinesis Data Analytics for Apache Flink.
#
# Read-only by construction. The orchestrator's pre-execution scanner
# rejects any aws verb outside {list, get, describe}; this script only
# uses `list-applications`, satisfying Requirements 17.2 and 18.1.
#
# Behavior summary (Requirements 17.1, 17.5, 17.8, 18.1, 18.3, 3.6):
#   - Calls `aws kinesisanalyticsv2 list-applications` once per run via
#     mt_aws.
#   - For each application, builds an item record {name, arn, kind, raw}
#     where `raw` is the full per-application JSON object.
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

mt_init "inventory.flink-kda" "${MT_WORKDIR}/steps/inventory/flink-kda/outputs" -- "$@"
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
# 1. List Flink / KDA applications.
# ---------------------------------------------------------------------------

FETCHED_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ACCOUNT_ID="${MT_SOURCE_ACCOUNT_ID:-unknown}"
INVENTORY_PATH="$(mt_outputs_path inventory.json)"

APPS_JSON="$(_aws_capture kinesisanalyticsv2 list-applications --region "$MT_AWS_REGION")"
if [ -z "$(printf '%s' "$APPS_JSON" | tr -d '[:space:]')" ]; then
    APPS_JSON='{"ApplicationSummaries":[]}'
fi

# Build items: one record per application. The list-applications
# response returns `ApplicationSummaries[]`, each carrying
# ApplicationName and ApplicationARN.
ITEMS_JSON="$(printf '%s\n' "$APPS_JSON" | jq -c \
    '[.ApplicationSummaries[]? | {
        name: (.ApplicationName // ""),
        arn:  (.ApplicationARN  // ""),
        kind: "application",
        raw:  .
    }]')"
TOTAL="$(printf '%s\n' "$ITEMS_JSON" | jq 'length')"

# ---------------------------------------------------------------------------
# 2. Build canonical inventory document.
# ---------------------------------------------------------------------------

INVENTORY_JSON="$(jq -nc \
    --arg service "flink-kda" \
    --arg fetched "$FETCHED_UTC" \
    --arg region  "$MT_AWS_REGION" \
    --arg account "$ACCOUNT_ID" \
    --argjson items "$ITEMS_JSON" \
    --argjson total "$TOTAL" \
    '{service: $service, fetched_utc: $fetched, region: $region, account_id: $account, items: $items, counts: {total: $total}}')"

if mt_apply_mode; then
    printf '%s\n' "$INVENTORY_JSON" | jq '.' > "$INVENTORY_PATH"
    mt_log "wrote $INVENTORY_PATH (total=${TOTAL})"
else
    mt_dryrun "write $INVENTORY_PATH"
fi

mt_status ok
exit 0
