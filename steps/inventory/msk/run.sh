#!/usr/bin/env bash
#
# steps/inventory/msk/run.sh — Inventory step for Amazon MSK / Apache Kafka.
#
# Read-only by construction. The orchestrator's pre-execution scanner
# rejects any aws verb outside {list, get, describe}; this script
# only uses `list-clusters-v2`, satisfying Requirements 17.2 and 18.1.
#
# Behavior summary (Requirements 17.1, 17.4, 17.8, 18.1, 18.3, 3.6):
#   - Calls `aws kafka list-clusters-v2` once per run via mt_aws.
#   - For each cluster, builds an item record {name, arn, kind, raw}
#     where `raw` is the full per-cluster JSON object.
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

mt_init "inventory.msk" "${MT_WORKDIR}/steps/inventory/msk/outputs" -- "$@"
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
# 1. List MSK clusters.
# ---------------------------------------------------------------------------

FETCHED_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ACCOUNT_ID="${MT_SOURCE_ACCOUNT_ID:-unknown}"
INVENTORY_PATH="$(mt_outputs_path inventory.json)"

CLUSTERS_JSON="$(_aws_capture kafka list-clusters-v2 --region "$MT_AWS_REGION")"
if [ -z "$(printf '%s' "$CLUSTERS_JSON" | tr -d '[:space:]')" ]; then
    CLUSTERS_JSON='{"ClusterInfoList":[]}'
fi

# Build items: one record per cluster. The list-clusters-v2 response
# returns clusters under `ClusterInfoList[]`; each entry carries
# ClusterName and ClusterArn fields regardless of whether it is a
# provisioned or serverless cluster.
ITEMS_JSON="$(printf '%s\n' "$CLUSTERS_JSON" | jq -c \
    '[.ClusterInfoList[]? | {
        name: (.ClusterName // ""),
        arn:  (.ClusterArn  // ""),
        kind: "cluster",
        raw:  .
    }]')"
TOTAL="$(printf '%s\n' "$ITEMS_JSON" | jq 'length')"

# ---------------------------------------------------------------------------
# 2. Build canonical inventory document.
# ---------------------------------------------------------------------------

INVENTORY_JSON="$(jq -nc \
    --arg service "msk" \
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
