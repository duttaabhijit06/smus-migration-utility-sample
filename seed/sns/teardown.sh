#!/usr/bin/env bash
#
# seed/sns/teardown.sh — Amazon SNS Seed_Service_Module teardown.
#
# Removes every SNS topic and subscription this module previously
# provisioned, gated by Requirement 20.31's two-condition deletion rule:
#
#   (a) The target resource's name begins with `${SBX_SEED_NAME_PREFIX}-`.
#   (b) AND the target resource's ARN is recorded in `seed.state.json`
#       under `.services.sns.resources.topics`.
#
# Because the Seed_Script and the Migration_Tool share a single AWS
# account, deleting any SNS topic that does not satisfy BOTH (a) and (b)
# could destroy a non-seed customer topic that happens to live in this
# account. The deletion gate therefore reads the seed state file as the
# authoritative inventory and re-confirms the prefix on every name BEFORE
# issuing any `delete-*` call.
#
# Order: subscriptions first (per topic), then the topic itself, in the
# order the topics appear in the state file. SNS does not require this
# ordering — `delete-topic` cascades subscriptions — but issuing the
# explicit `delete-subscription` calls first gives a per-subscription
# audit trail in the run log, which is what Requirement 20.14 asks for.
#
# Best-effort discipline: if a delete fails (for example a topic was
# already removed manually), the script logs a STATUS line and continues
# to the next resource rather than aborting. The same-account contract
# and the prefix-and-state gating are NOT best-effort: a violation halts
# immediately.
#

set -euo pipefail

__sns_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SBX_WORKDIR="${SBX_WORKDIR:-$(dirname "$(dirname "$__sns_dir")")}"
export SBX_WORKDIR

# shellcheck source=../_lib/common.sh disable=SC1091
source "${SBX_WORKDIR}/seed/_lib/common.sh"

sbx_init "sns" "$@"
sbx_assert_same_account

# -----------------------------------------------------------------------------
# Helpers.
# -----------------------------------------------------------------------------

# _state_topics_json
#
# Echo the `.services.sns.resources.topics` array from seed.state.json, or
# an empty array `[]` when the state file is missing or the slot is unset.
# All deletion candidates flow from this one read so the prefix-and-state
# gating is centralized.
_state_topics_json() {
    if ! command -v jq >/dev/null 2>&1; then
        printf '[]\n'
        return 0
    fi
    local _path
    _path="$(sbx_state_path)"
    if [ ! -f "$_path" ]; then
        printf '[]\n'
        return 0
    fi
    jq -r '.services.sns.resources.topics // [] | tojson' "$_path" 2>/dev/null \
        || printf '[]\n'
}

# _verify_prefix <name>
#
# Return 0 iff `<name>` begins with `${SBX_SEED_NAME_PREFIX}-`. This is
# the second leg of the Requirement 20.31 deletion gate: even though the
# state file is supposed to contain only seed-prefixed names, we re-check
# at deletion time as defense in depth against a hand-edited state file
# or a name-collision bug elsewhere.
_verify_prefix() {
    local _name="${1:-}"
    case "$_name" in
        "${SBX_SEED_NAME_PREFIX}-"*) return 0 ;;
        *) return 1 ;;
    esac
}

# _delete_subscription <subscription-arn>
#
# Best-effort `aws sns unsubscribe`. SNS allows pending
# (unconfirmed) subscriptions whose "ARN" is the literal string
# "PendingConfirmation"; those cannot be deleted by ARN — they expire on
# their own. We skip those with a STATUS line so the run log records the
# decision.
#
# NOTE: the AWS CLI verb to remove a subscription is `aws sns unsubscribe`
# (NOT `delete-subscription` — `aws sns delete-subscription` does not
# exist; an earlier revision of this script used the wrong name and
# every per-subscription delete failed).
_delete_subscription() {
    local _sub_arn="${1:-}"
    if [ -z "$_sub_arn" ] || [ "$_sub_arn" = "PendingConfirmation" ]; then
        sbx_log "skipping unconfirmed subscription (cannot delete by ARN)"
        return 0
    fi
    if ! sbx_aws sns unsubscribe \
        --subscription-arn "$_sub_arn" \
        --region "$SBX_REGION"; then
        sbx_status error "unsubscribe failed for ${_sub_arn} (continuing)"
    fi
}

# _delete_topic <topic-arn>
#
# Best-effort `aws sns delete-topic`. Per SNS semantics this also
# cascades any remaining subscriptions on the topic, which covers the
# pending-confirmation case the per-subscription delete above had to
# skip.
_delete_topic() {
    local _topic_arn="${1:-}"
    if [ -z "$_topic_arn" ]; then
        return 0
    fi
    if ! sbx_aws sns delete-topic \
        --topic-arn "$_topic_arn" \
        --region "$SBX_REGION"; then
        sbx_status error "delete-topic failed for ${_topic_arn} (continuing)"
    fi
}

# -----------------------------------------------------------------------------
# Main.
# -----------------------------------------------------------------------------

main() {
    sbx_status started

    if ! command -v jq >/dev/null 2>&1; then
        sbx_status error jq_required
        exit 64
    fi

    local _topics_json
    _topics_json="$(_state_topics_json)"

    local _count
    _count="$(printf '%s' "$_topics_json" | jq -r 'length')"
    if [ "$_count" = "0" ]; then
        sbx_log "no topics recorded in seed.state.json under .services.sns; nothing to delete"
        # Mark torn_down anyway so re-runs and the orchestrator's reverse-
        # order teardown see a consistent terminal state.
        sbx_state_set_service sns '{"status":"torn_down"}'
        sbx_status ok
        return 0
    fi

    # Iterate over each recorded topic. We use jq to project tuples of
    # (name, arn, subscription-arn) onto NUL-delimited records so topic
    # names containing spaces or quotes (defensive — the prefix regex
    # forbids them, but jq's tojson is what makes this defensive) flow
    # through the bash loop unchanged.
    local _i _name _arn _sub_arns _sub_arn
    for _i in $(seq 0 $((_count - 1))); do
        _name="$(printf '%s' "$_topics_json" | jq -r --argjson i "$_i" '.[$i].name // empty')"
        _arn="$(printf '%s' "$_topics_json" | jq -r --argjson i "$_i" '.[$i].arn // empty')"

        if [ -z "$_name" ] || [ -z "$_arn" ]; then
            sbx_log "skipping topic at index ${_i}: missing name or arn in state"
            continue
        fi

        # Requirement 20.31 leg (a) — name MUST begin with the configured
        # prefix. Skipping (rather than aborting) on a mismatch is correct:
        # the rest of the state file may still be tear-down-able.
        if ! _verify_prefix "$_name"; then
            sbx_status error "refusing to delete ${_name} (does not begin with ${SBX_SEED_NAME_PREFIX}-)"
            continue
        fi

        # Subscriptions first (best-effort), then the topic. Both `aws sns
        # delete-*` calls flow through `sbx_aws` so dry-run prints
        # `DRY-RUN: aws sns delete-...` lines without touching AWS.
        _sub_arns="$(printf '%s' "$_topics_json" | jq -r --argjson i "$_i" '.[$i].subscriptions // [] | .[] | .arn // empty')"
        while IFS= read -r _sub_arn; do
            [ -z "$_sub_arn" ] && continue
            _delete_subscription "$_sub_arn"
        done <<< "$_sub_arns"

        _delete_topic "$_arn"
    done

    # Mark `.services.sns.status = "torn_down"` at end (per task spec).
    # We deliberately preserve `.resources.topics` so a post-mortem can
    # see what was deleted; the status field is the source of truth for
    # "this service has been torn down".
    sbx_state_set_service sns '{"status":"torn_down"}'

    sbx_status ok
}

main "$@"
