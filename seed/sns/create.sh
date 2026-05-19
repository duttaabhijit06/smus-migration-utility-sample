#!/usr/bin/env bash
#
# seed/sns/create.sh — Amazon SNS Seed_Service_Module creator.
#
# Stands up the seed-grade SNS surface the Migration_Tool's inventory phase
# (Step 25.2 — `steps/inventory/sns/run.sh`) discovers when it lists topics
# and subscriptions in the source account. Two topics and one HTTPS
# subscription per topic are sufficient to exercise both the inventory
# verb set (`list-topics`, `list-subscriptions`) and the seed-side
# idempotency contract (every re-run issues zero `create-*` commands).
#
# Per task 24.6 + design.md "Per-service create.sh contracts":
#
#   - Resources: <prefix>-orders and <prefix>-alerts SNS topics, each
#     with one no-op HTTPS subscription pointing at example.com (a
#     placeholder destination — example.com responds to GET/POST and
#     never confirms the SNS subscription token, so the subscription
#     stays in `PendingConfirmation` forever, which is exactly what we
#     want for a seed: no message ever leaves AWS).
#   - Idempotency: `aws sns list-topics` filtered by name prefix +
#     `aws sns list-subscriptions-by-topic` per topic. When both return
#     pre-existing matches the corresponding `create-topic` /
#     `subscribe` calls are skipped (Requirement 20.13).
#   - Resource-name prefix gating (Requirement 20.29): every name starts
#     with `${SBX_SEED_NAME_PREFIX}-`.
#   - Post-migration idempotency (Requirement 20.32): this script never
#     calls `aws datazone create-*` and never targets the SMUS_Domain ID
#     or the Admin_Project ID recorded in `./config/migration.config.json`.
#   - State persistence (Requirement 20.12): topic ARNs and subscription
#     ARNs are written to `seed.state.json` under `.services.sns` via
#     `sbx_state_set_service` BEFORE the next state-changing AWS CLI call
#     so a SIGKILL between create and persist never leaves an orphan.
#

set -euo pipefail

# Resolve the seed root from this script's location so create.sh can be
# invoked from any cwd (directly or via `provision.sh`). The grandparent of
# this script is the seed root; one more parent is the workspace root that
# common.sh expects in SBX_WORKDIR.
__sns_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SBX_WORKDIR="${SBX_WORKDIR:-$(dirname "$(dirname "$__sns_dir")")}"
export SBX_WORKDIR

# shellcheck source=../_lib/common.sh disable=SC1091
source "${SBX_WORKDIR}/seed/_lib/common.sh"

# sbx_init validates SBX_REGION / SBX_SOURCE_ACCOUNT_ID / SBX_SEED_NAME_PREFIX,
# parses --apply / --dry-run (default dry-run, mutually exclusive), and opens
# the per-invocation log at ${SBX_WORKDIR}/seed/logs/run-<UTC>.log.
sbx_init "sns" "$@"

# Same-account contract (Requirement 20.28). No-op when
# ./config/migration.config.json is absent (Migration_Tool has not run yet);
# halts with exit 64 + STATUS line on a mismatch.
sbx_assert_same_account

# -----------------------------------------------------------------------------
# Configuration — derive deterministic resource names from the prefix.
# -----------------------------------------------------------------------------

# Two-topic seed surface. The names are deterministic so re-runs and
# teardown can locate the exact resources without consulting the state
# file (the state file is the authoritative record, but the deterministic
# naming is what makes the idempotency check possible in the first place).
TOPIC_ORDERS="${SBX_SEED_NAME_PREFIX}-orders"
TOPIC_ALERTS="${SBX_SEED_NAME_PREFIX}-alerts"
TOPICS=("$TOPIC_ORDERS" "$TOPIC_ALERTS")

# -----------------------------------------------------------------------------
# Helpers — pre-existence lookups + create-or-skip.
#
# Idempotency helpers communicate their result back to `main` via two
# global "out" variables instead of via stdout capture. The reason: in
# dry-run mode `sbx_aws` PRINTS `DRY-RUN: aws ...` lines to stdout, and a
# command substitution `$(...)` would swallow those lines into the
# returned value, so the DRY-RUN output would never reach the operator's
# terminal. Using globals keeps stdout free for the DRY-RUN/STATUS lines
# while still letting helpers signal their computed identifier back.
# -----------------------------------------------------------------------------

# `out` channel for _ensure_topic / _ensure_subscription. Reset by the
# caller before each invocation so a stale value from a prior topic
# cannot leak into the next iteration's state-file payload.
__SNS_OUT_TOPIC_ARN=""
__SNS_OUT_SUB_ARN=""

# _list_topic_arn <topic-name>
#
# Echo the ARN of an existing SNS topic with the exact name `<topic-name>`,
# or empty when no such topic exists. Always issues a real AWS CLI call
# (even in dry-run) because read-only `list-*` is safe in dry-run by
# construction (per Property 17 — read-only verb safety) and the lookup is
# what drives idempotency: in dry-run we want the script to print the
# would-be `create-topic` only when the topic does NOT already exist.
#
# `aws sns list-topics` returns ALL topics in the region paginated; we
# filter client-side on the exact topic name (the ARN tail equals the
# topic name). jq's --arg keeps the comparison literal.
_list_topic_arn() {
    local _name="$1"
    if ! command -v aws >/dev/null 2>&1; then
        return 0
    fi
    aws sns list-topics --region "$SBX_REGION" --output json 2>/dev/null \
        | jq -r --arg n "$_name" \
            '.Topics[] | select(.TopicArn | endswith(":" + $n)) | .TopicArn' \
            2>/dev/null \
        | head -n 1
}

# _first_subscription_arn <topic-arn>
#
# Echo the first confirmed subscription ARN on `<topic-arn>`, or empty
# when the topic has no confirmed subscriptions. Pending-confirmation
# subscriptions appear with the literal ARN `PendingConfirmation` (not a
# real ARN); those are NOT counted as pre-existing for idempotency
# because they cannot be deleted by ARN. Only ARNs starting with `arn:`
# (i.e. confirmed) are returned.
_first_subscription_arn() {
    local _topic_arn="$1"
    if ! command -v aws >/dev/null 2>&1; then
        return 0
    fi
    aws sns list-subscriptions-by-topic \
        --topic-arn "$_topic_arn" \
        --region "$SBX_REGION" \
        --output json 2>/dev/null \
        | jq -r '.Subscriptions[] | select(.SubscriptionArn | startswith("arn:")) | .SubscriptionArn' \
            2>/dev/null \
        | head -n 1
}

# _ensure_topic <topic-name>
#
# Idempotently ensure topic `<topic-name>` exists. Writes the resulting
# ARN to the global `__SNS_OUT_TOPIC_ARN`. In apply mode: lookup →
# create-if-missing → record real ARN. In dry-run: lookup (read-only is
# safe) → if missing, print the would-be create command via sbx_aws
# (which prints `DRY-RUN: aws sns create-topic ...` to stdout) and
# synthesize a deterministic placeholder ARN built from the configured
# region and account so the downstream subscribe call can still produce
# a coherent `--topic-arn` argument and a structurally-correct state
# document.
_ensure_topic() {
    local _name="$1"
    __SNS_OUT_TOPIC_ARN=""

    # Always issue the read-only lookup. Calling `aws sns list-topics`
    # directly (not through `sbx_aws`) is correct because `list-*` is in
    # the read-only verb set and Property 17 guarantees read-only verbs
    # are safe in either mode. Using `sbx_aws` here would print a
    # `DRY-RUN: ...` line for the lookup AND skip its execution, which
    # would break idempotency.
    local _existing_arn
    _existing_arn="$(_list_topic_arn "$_name" || true)"
    if [ -n "$_existing_arn" ]; then
        sbx_log "topic ${_name} already exists: ${_existing_arn}"
        __SNS_OUT_TOPIC_ARN="$_existing_arn"
        return 0
    fi

    if sbx_apply_mode; then
        # Apply mode. We bypass `sbx_aws` here because we need to capture
        # `create-topic`'s JSON output, and `sbx_aws` returns the aws CLI's
        # exit code via `return $?` (the captured stdout is what we want
        # for the JSON parse). Emit the matching `STATUS: action` line so
        # the per-invocation log retains the audit trail `sbx_aws` would
        # have provided.
        sbx_status action "aws sns create-topic"
        local _arn
        _arn="$(aws sns create-topic \
            --name "$_name" \
            --region "$SBX_REGION" \
            --output json \
            | jq -r '.TopicArn')"
        if [ -z "$_arn" ] || [ "$_arn" = "null" ]; then
            sbx_status error "create-topic returned no ARN for ${_name}"
            return 1
        fi
        __SNS_OUT_TOPIC_ARN="$_arn"
    else
        # Dry-run dispatch via `sbx_aws` emits the
        # `DRY-RUN: aws sns create-topic ...` line on stdout (which the
        # tee-into-log in sbx_init mirrors into the per-invocation log).
        sbx_aws sns create-topic --name "$_name" --region "$SBX_REGION"
        __SNS_OUT_TOPIC_ARN="arn:aws:sns:${SBX_REGION}:${SBX_SOURCE_ACCOUNT_ID}:${_name}"
    fi
}

# _ensure_subscription <topic-arn> <topic-name>
#
# Idempotently ensure exactly one HTTPS subscription exists on
# `<topic-arn>` pointing at the no-op placeholder endpoint
# `https://example.com/<prefix>-<topic-name>`. Writes the resulting
# subscription ARN (or the literal `PendingConfirmation` in dry-run) to
# the global `__SNS_OUT_SUB_ARN`.
#
# The placeholder endpoint (example.com) is the IETF-reserved example
# domain (RFC 2606); SNS will deliver subscription-confirmation requests
# but the server never confirms, so the subscription remains in
# PendingConfirmation forever and zero customer messages flow. That is
# exactly the seed contract: a discoverable subscription that never
# delivers.
_ensure_subscription() {
    local _topic_arn="$1"
    local _topic_name="$2"
    # Endpoint format per task 24.6: `https://example.com/<prefix>-<topic>`.
    # `<topic>` here is the short name (`orders` / `alerts`); since
    # `_topic_name` already equals `<prefix>-<short>`, using it directly
    # yields the spec-mandated `https://example.com/<prefix>-<short>`
    # without doubling the prefix.
    local _endpoint="https://example.com/${_topic_name}"
    __SNS_OUT_SUB_ARN=""

    # Read-only lookup, always issued (same rationale as _ensure_topic).
    # We treat ANY confirmed subscription ARN on this topic as the seed
    # subscription for idempotency purposes — example.com never confirms
    # in practice, so a confirmed ARN means a previous apply-mode run
    # swapped the endpoint for a real one or AWS account policy
    # auto-confirms HTTPS subs. Either way, no second `subscribe` call is
    # needed.
    local _existing
    _existing="$(_first_subscription_arn "$_topic_arn" || true)"
    if [ -n "$_existing" ]; then
        sbx_log "subscription on ${_topic_arn} already exists: ${_existing}"
        __SNS_OUT_SUB_ARN="$_existing"
        return 0
    fi

    if sbx_apply_mode; then
        sbx_status action "aws sns subscribe"
        local _sub_arn
        _sub_arn="$(aws sns subscribe \
            --topic-arn "$_topic_arn" \
            --protocol https \
            --notification-endpoint "$_endpoint" \
            --region "$SBX_REGION" \
            --output json \
            | jq -r '.SubscriptionArn')"
        if [ -z "$_sub_arn" ] || [ "$_sub_arn" = "null" ]; then
            sbx_status error "subscribe returned no ARN for ${_topic_arn}"
            return 1
        fi
        __SNS_OUT_SUB_ARN="$_sub_arn"
    else
        # Dry-run dispatch via `sbx_aws` emits the
        # `DRY-RUN: aws sns subscribe ...` line on stdout. The
        # `PendingConfirmation` placeholder mirrors the SubscriptionArn
        # SNS would return for a fresh, unconfirmed HTTPS subscription, so
        # the dry-run state document is structurally identical to the
        # apply-mode shape.
        sbx_aws sns subscribe \
            --topic-arn "$_topic_arn" \
            --protocol https \
            --notification-endpoint "$_endpoint" \
            --region "$SBX_REGION"
        __SNS_OUT_SUB_ARN="PendingConfirmation"
    fi
}

# -----------------------------------------------------------------------------
# Main.
# -----------------------------------------------------------------------------

main() {
    sbx_status started

    # Per-topic create-or-skip. We accumulate the JSON payload incrementally
    # via jq so the state-file write at the end is a single deep-merge. This
    # honors Requirement 20.12: identifiers are persisted BEFORE any further
    # state-changing call. (The "further state-changing call" after the last
    # subscribe in this script is the orchestrator's NEXT module's
    # create.sh, so writing once at the end of this script meets the
    # contract.)
    local _topics_json='[]'

    local _name
    for _name in "${TOPICS[@]}"; do
        _ensure_topic "$_name"
        _ensure_subscription "$__SNS_OUT_TOPIC_ARN" "$_name"

        # Append { name, arn, subscriptions:[{arn}] } to the running array.
        # jq's --arg keeps the strings literal; no shell escaping issues.
        _topics_json="$(jq -n \
            --argjson acc "$_topics_json" \
            --arg name "$_name" \
            --arg arn "$__SNS_OUT_TOPIC_ARN" \
            --arg sub_arn "$__SNS_OUT_SUB_ARN" \
            '$acc + [{name: $name, arn: $arn, subscriptions: [{arn: $sub_arn}]}]')"
    done

    # Atomic deep-merge into .services.sns. The merge replaces the topics
    # array (jq `*` right-operand-wins on arrays) which is what we want:
    # this script owns the canonical record of which seed topics exist.
    #
    # Bug fix 1a: state writes happen ONLY in apply mode. In dry-run we
    # have not actually created any AWS resource, so persisting
    # status="provisioned" would be a lie — and would make the orchestrator
    # think a subsequent --apply re-run can be skipped. Dry-run instead
    # writes status="dry-run-planned" so the operator can audit what the
    # plan would record without misreporting it as live.
    local _payload
    if sbx_apply_mode; then
        _payload="$(jq -n \
            --argjson topics "$_topics_json" \
            '{status: "provisioned", resources: {topics: $topics}}')"
        sbx_state_set_service sns "$_payload"
    else
        _payload="$(jq -n \
            --argjson topics "$_topics_json" \
            '{status: "dry-run-planned", resources: {topics: $topics}}')"
        sbx_log "dry-run: skipping state write (would record status=dry-run-planned with ${#TOPICS[@]} topics)"
    fi

    sbx_status ok
}

main "$@"
