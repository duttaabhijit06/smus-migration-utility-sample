#!/usr/bin/env bash
#
# steps/inventory/quicksight/run.sh — Inventory step for Amazon QuickSight.
#
# Read-only by construction. The orchestrator's pre-execution scanner
# rejects any aws verb outside {list, get, describe}; this script uses
# only `list-dashboards`, `list-data-sets`, `list-analyses`, and the
# `get-caller-identity` fallback for resolving the account id.
# Requirements 17.2 and 18.1 are satisfied: every verb listed begins
# with `list` or `get`.
#
# Behavior summary (Requirements 17.1, 17.7, 17.8, 18.1, 18.3, 3.6):
#   - QuickSight requires --aws-account-id on every list call. The
#     account id is taken from MT_SOURCE_ACCOUNT_ID first; if that
#     env var is unset, the script falls back to
#     `aws sts get-caller-identity --query Account --output text`.
#     The `get` verb is on the allowlist.
#   - Calls `aws quicksight list-dashboards`, `list-data-sets`, and
#     `list-analyses` once per run via mt_aws.
#   - Combines the three sources into a single `items[]` array with a
#     `kind` field per source.
#   - In apply mode, writes outputs/inventory.json. In dry-run, prints
#     `DRY-RUN: write <path>` and creates no inventory file.
#

if [ -z "${MT_WORKDIR:-}" ]; then
    MT_WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
    export MT_WORKDIR
fi

# shellcheck source=../../_lib/common.sh
# shellcheck disable=SC1091
source "${MT_WORKDIR}/steps/_lib/common.sh"

set -euo pipefail

mt_init "inventory.quicksight" "${MT_WORKDIR}/steps/inventory/quicksight/outputs" -- "$@"
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
# 1. Resolve the AWS account id.
# ---------------------------------------------------------------------------
#
# QuickSight's list-* APIs all require --aws-account-id. We prefer
# MT_SOURCE_ACCOUNT_ID (set by the orchestrator from
# config.source_account_id); when unset, we call
# `aws sts get-caller-identity --query Account --output text`. The
# `get` verb is on the read-only allowlist so the pre-execution scanner
# accepts the call.
#
# In dry-run mt_aws does not invoke aws and returns no JSON; in that
# case we fall back to a placeholder account id so the would-be
# QuickSight calls below render with a well-formed `--aws-account-id`
# argument and the dry-run audit trail is faithful.

FETCHED_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
INVENTORY_PATH="$(mt_outputs_path inventory.json)"

ACCOUNT_ID="${MT_SOURCE_ACCOUNT_ID:-}"
if [ -z "$ACCOUNT_ID" ]; then
    STS_OUT="$(_aws_capture sts get-caller-identity --query Account --output text)"
    ACCOUNT_ID="$(printf '%s' "$STS_OUT" | tr -d '[:space:]')"
fi
if [ -z "$ACCOUNT_ID" ]; then
    if mt_dry_run_mode; then
        # Dry-run with no env-var account id: render a placeholder so
        # the would-be aws quicksight commands are still well-formed.
        ACCOUNT_ID="ACCOUNT-ID-PLACEHOLDER"
    else
        mt_status error "could not resolve AWS account id (set MT_SOURCE_ACCOUNT_ID or grant sts:GetCallerIdentity)"
        exit 64
    fi
fi

# ---------------------------------------------------------------------------
# 2. List QuickSight dashboards, data-sets, and analyses.
# ---------------------------------------------------------------------------

DASHBOARDS_JSON="$(_aws_capture quicksight list-dashboards \
    --aws-account-id "$ACCOUNT_ID" \
    --region "$MT_AWS_REGION")"
if [ -z "$(printf '%s' "$DASHBOARDS_JSON" | tr -d '[:space:]')" ]; then
    DASHBOARDS_JSON='{"DashboardSummaryList":[]}'
fi

DATASETS_JSON="$(_aws_capture quicksight list-data-sets \
    --aws-account-id "$ACCOUNT_ID" \
    --region "$MT_AWS_REGION")"
if [ -z "$(printf '%s' "$DATASETS_JSON" | tr -d '[:space:]')" ]; then
    DATASETS_JSON='{"DataSetSummaries":[]}'
fi

ANALYSES_JSON="$(_aws_capture quicksight list-analyses \
    --aws-account-id "$ACCOUNT_ID" \
    --region "$MT_AWS_REGION")"
if [ -z "$(printf '%s' "$ANALYSES_JSON" | tr -d '[:space:]')" ]; then
    ANALYSES_JSON='{"AnalysisSummaryList":[]}'
fi

# Dashboard items: list-dashboards returns DashboardSummaryList[] with
# Name and Arn (capitalised to match the QuickSight API casing).
DASHBOARD_ITEMS="$(printf '%s\n' "$DASHBOARDS_JSON" | jq -c \
    '[.DashboardSummaryList[]? | {
        name: (.Name // ""),
        arn:  (.Arn  // ""),
        kind: "dashboard",
        raw:  .
    }]')"

# Data-set items: list-data-sets returns DataSetSummaries[] with Name
# and Arn.
DATASET_ITEMS="$(printf '%s\n' "$DATASETS_JSON" | jq -c \
    '[.DataSetSummaries[]? | {
        name: (.Name // ""),
        arn:  (.Arn  // ""),
        kind: "data-set",
        raw:  .
    }]')"

# Analysis items: list-analyses returns AnalysisSummaryList[] with
# Name and Arn.
ANALYSIS_ITEMS="$(printf '%s\n' "$ANALYSES_JSON" | jq -c \
    '[.AnalysisSummaryList[]? | {
        name: (.Name // ""),
        arn:  (.Arn  // ""),
        kind: "analysis",
        raw:  .
    }]')"

ITEMS_JSON="$(jq -nc \
    --argjson d "$DASHBOARD_ITEMS" \
    --argjson s "$DATASET_ITEMS" \
    --argjson a "$ANALYSIS_ITEMS" \
    '$d + $s + $a')"

TOTAL="$(printf '%s\n' "$ITEMS_JSON" | jq 'length')"
DASHBOARDS_COUNT="$(printf '%s\n' "$DASHBOARD_ITEMS" | jq 'length')"
DATASETS_COUNT="$(printf '%s\n' "$DATASET_ITEMS" | jq 'length')"
ANALYSES_COUNT="$(printf '%s\n' "$ANALYSIS_ITEMS" | jq 'length')"

# ---------------------------------------------------------------------------
# 3. Build canonical inventory document.
# ---------------------------------------------------------------------------

INVENTORY_JSON="$(jq -nc \
    --arg service "quicksight" \
    --arg fetched "$FETCHED_UTC" \
    --arg region  "$MT_AWS_REGION" \
    --arg account "$ACCOUNT_ID" \
    --argjson items "$ITEMS_JSON" \
    --argjson total "$TOTAL" \
    --argjson dashboards "$DASHBOARDS_COUNT" \
    --argjson data_sets "$DATASETS_COUNT" \
    --argjson analyses "$ANALYSES_COUNT" \
    '{service: $service, fetched_utc: $fetched, region: $region, account_id: $account, items: $items, counts: {total: $total, dashboards: $dashboards, data_sets: $data_sets, analyses: $analyses}}')"

if mt_apply_mode; then
    printf '%s\n' "$INVENTORY_JSON" | jq '.' > "$INVENTORY_PATH"
    mt_log "wrote $INVENTORY_PATH (total=${TOTAL}, dashboards=${DASHBOARDS_COUNT}, data_sets=${DATASETS_COUNT}, analyses=${ANALYSES_COUNT})"
else
    mt_dryrun "write $INVENTORY_PATH"
fi

mt_status ok
exit 0
