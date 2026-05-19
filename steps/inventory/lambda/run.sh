#!/usr/bin/env bash
#
# steps/inventory/lambda/run.sh — Inventory step for AWS Lambda.
#
# Read-only by construction. The orchestrator's pre-execution scanner
# rejects any aws verb outside {list, get, describe}; this script only
# uses `list-functions`, satisfying Requirements 17.2 and 18.1.
#
# Behavior summary (Requirements 17.1, 17.2, 17.8, 18.1, 18.3, 3.6):
#   - Calls `aws lambda list-functions` once per run via mt_aws so the
#     orchestrator records a STATUS: action line and so dry-run prints
#     a faithful DRY-RUN: line without invoking AWS.
#   - In apply mode, writes outputs/inventory.json in the canonical
#     inventory shape (service / fetched_utc / region / account_id /
#     items / counts). In dry-run, prints
#     `DRY-RUN: write <path>` and creates no inventory file (no on-disk
#     side effects beyond the outputs directory mt_init creates).
#   - account_id is taken from MT_SOURCE_ACCOUNT_ID when set; otherwise
#     it is the literal string "unknown".
#
# This script never calls boto3 or any AWS SDK. Every AWS interaction
# flows through `mt_aws` from `steps/_lib/common.sh`.
#

# Resolve MT_WORKDIR. The orchestrator sets it; if a developer runs
# the script directly we derive it from the script location so the
# `source` line below resolves cleanly without coupling to the caller's
# CWD.
if [ -z "${MT_WORKDIR:-}" ]; then
    MT_WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
    export MT_WORKDIR
fi

# shellcheck source=../../_lib/common.sh
# shellcheck disable=SC1091
source "${MT_WORKDIR}/steps/_lib/common.sh"

set -euo pipefail

mt_init "inventory.lambda" "${MT_WORKDIR}/steps/inventory/lambda/outputs" -- "$@"
mt_status started

mt_require_var MT_AWS_REGION

# jq is required for JSON construction and parsing throughout this
# step. The orchestrator's environment is expected to have it; if not,
# halt with a clear status line so the user can install it.
if ! command -v jq >/dev/null 2>&1; then
    mt_status error "jq is required but not found on PATH"
    exit 64
fi

# Save the script's stdout to fd 3 so the local _aws_capture helper
# can route mt_aws's STATUS / DRY-RUN side-effect lines back to the
# orchestrator (and the run.log tee opened by mt_init in apply mode)
# without polluting our command-substitution captures of the AWS CLI's
# JSON payload.
exec 3>&1

# _aws_capture <aws-args...>
#
# Run `mt_aws "$@"`, separate the STATUS / DRY-RUN side-effect lines
# from the JSON payload, route the side-effect lines through fd 3 so
# the orchestrator still parses them, and emit only the JSON payload
# on fd 1. In dry-run mt_aws never invokes aws, so the captured output
# is the STATUS + DRY-RUN lines only and the helper returns an empty
# string on fd 1.
_aws_capture() {
    local _raw
    _raw="$(mt_aws "$@")"
    printf '%s\n' "$_raw" | grep -E '^(STATUS:|DRY-RUN:)' >&3 || true
    printf '%s\n' "$_raw" | grep -vE '^(STATUS:|DRY-RUN:)' || true
}

# ---------------------------------------------------------------------------
# 1. List functions.
# ---------------------------------------------------------------------------

FETCHED_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ACCOUNT_ID="${MT_SOURCE_ACCOUNT_ID:-unknown}"
INVENTORY_PATH="$(mt_outputs_path inventory.json)"

FUNCTIONS_JSON="$(_aws_capture lambda list-functions --region "$MT_AWS_REGION")"
if [ -z "$(printf '%s' "$FUNCTIONS_JSON" | tr -d '[:space:]')" ]; then
    FUNCTIONS_JSON='{"Functions":[]}'
fi

# Build items: one record per function with name, arn, kind, raw.
ITEMS_JSON="$(printf '%s\n' "$FUNCTIONS_JSON" | jq -c \
    '[.Functions[]? | {
        name: (.FunctionName // ""),
        arn:  (.FunctionArn  // ""),
        kind: "function",
        raw:  .
    }]')"
TOTAL="$(printf '%s\n' "$ITEMS_JSON" | jq 'length')"

# ---------------------------------------------------------------------------
# 2. Build canonical inventory document.
# ---------------------------------------------------------------------------

INVENTORY_JSON="$(jq -nc \
    --arg service "lambda" \
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
