#!/usr/bin/env bash
#
# steps/inventory/sns/run.sh — Inventory step for Amazon SNS.
#
# Read-only by construction. The orchestrator's pre-execution scanner
# rejects any aws verb outside {list, get, describe}; this script
# only uses `list-topics` and `list-subscriptions`, satisfying
# Requirements 17.2 and 18.1.
#
# Behavior summary (Requirements 17.1, 17.3, 17.8, 18.1, 18.3, 3.6):
#   - Calls `aws sns list-topics` and `aws sns list-subscriptions` once
#     per run via mt_aws.
#   - Combines the two sources into a single `items[]` array. Each
#     item carries a `kind` field of `"topic"` or `"subscription"` so
#     downstream consumers can distinguish them.
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

mt_init "inventory.sns" "${MT_WORKDIR}/steps/inventory/sns/outputs" -- "$@"
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
# 1. List topics and subscriptions.
# ---------------------------------------------------------------------------

FETCHED_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ACCOUNT_ID="${MT_SOURCE_ACCOUNT_ID:-unknown}"
INVENTORY_PATH="$(mt_outputs_path inventory.json)"

TOPICS_JSON="$(_aws_capture sns list-topics --region "$MT_AWS_REGION")"
if [ -z "$(printf '%s' "$TOPICS_JSON" | tr -d '[:space:]')" ]; then
    TOPICS_JSON='{"Topics":[]}'
fi

SUBS_JSON="$(_aws_capture sns list-subscriptions --region "$MT_AWS_REGION")"
if [ -z "$(printf '%s' "$SUBS_JSON" | tr -d '[:space:]')" ]; then
    SUBS_JSON='{"Subscriptions":[]}'
fi

# Topic items: derive `name` from the last segment of the TopicArn so
# downstream tooling has a human-readable label even though the SNS
# list-topics response only carries ARNs.
TOPIC_ITEMS="$(printf '%s\n' "$TOPICS_JSON" | jq -c \
    '[.Topics[]? | {
        name: ((.TopicArn // "") | split(":") | last // ""),
        arn:  (.TopicArn // ""),
        kind: "topic",
        raw:  .
    }]')"

# Subscription items: name = SubscriptionArn (the response carries no
# separate human label); arn = SubscriptionArn.
SUB_ITEMS="$(printf '%s\n' "$SUBS_JSON" | jq -c \
    '[.Subscriptions[]? | {
        name: (.SubscriptionArn // ""),
        arn:  (.SubscriptionArn // ""),
        kind: "subscription",
        raw:  .
    }]')"

ITEMS_JSON="$(jq -nc --argjson t "$TOPIC_ITEMS" --argjson s "$SUB_ITEMS" '$t + $s')"
TOTAL="$(printf '%s\n' "$ITEMS_JSON" | jq 'length')"
TOPICS_COUNT="$(printf '%s\n' "$TOPIC_ITEMS" | jq 'length')"
SUBS_COUNT="$(printf '%s\n' "$SUB_ITEMS" | jq 'length')"

# ---------------------------------------------------------------------------
# 2. Build canonical inventory document.
# ---------------------------------------------------------------------------

INVENTORY_JSON="$(jq -nc \
    --arg service "sns" \
    --arg fetched "$FETCHED_UTC" \
    --arg region  "$MT_AWS_REGION" \
    --arg account "$ACCOUNT_ID" \
    --argjson items "$ITEMS_JSON" \
    --argjson total "$TOTAL" \
    --argjson topics "$TOPICS_COUNT" \
    --argjson subs "$SUBS_COUNT" \
    '{service: $service, fetched_utc: $fetched, region: $region, account_id: $account, items: $items, counts: {total: $total, topics: $topics, subscriptions: $subs}}')"

if mt_apply_mode; then
    printf '%s\n' "$INVENTORY_JSON" | jq '.' > "$INVENTORY_PATH"
    mt_log "wrote $INVENTORY_PATH (total=${TOTAL}, topics=${TOPICS_COUNT}, subscriptions=${SUBS_COUNT})"
else
    mt_dryrun "write $INVENTORY_PATH"
fi

mt_status ok
exit 0
