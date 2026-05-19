#!/usr/bin/env bash
#
# seed/msk/teardown.sh — Task 24.8.
#
# Tear down the Amazon MSK resources provisioned by ./seed/msk/create.sh.
# Resource set:
#   * 1 MSK cluster (Serverless or Provisioned) named ${SBX_SEED_NAME_PREFIX}-msk-cluster
#   * 1 sample topic ${SBX_SEED_NAME_PREFIX}-events (best-effort; see caveat)
#
# Cross-cutting contracts honored by this module (Requirements 20.5, 20.8,
# 20.13, 20.28, 20.31):
#
#   * Same-account contract (20.28) — `sbx_assert_same_account` runs
#     BEFORE any state-changing AWS CLI command and halts when
#     ./seed/seed.config.json and ./config/migration.config.json disagree
#     on `source_account_id`.
#
#   * Prefix + state-file deletion gating (20.31). Every `aws kafka
#     delete-cluster` (and any best-effort topic delete) must satisfy BOTH:
#       (a) the resource name begins with ${SBX_SEED_NAME_PREFIX}-, AND
#       (b) the resource ARN/ID is recorded in ./seed/seed.state.json.
#     The hard gate is `_assert_can_delete`, exported as a bash function by
#     the parent ./seed/teardown.sh; when this script is invoked directly
#     (without the top-level orchestrator first), we fall back to an
#     in-script gate with the same semantics.
#
#   * Topic-delete caveat. The AWS CLI does not currently expose a verb
#     to delete a Kafka topic on MSK; topic-delete requires running
#     `kafka-topics.sh --delete` against the bootstrap brokers from a
#     host inside the cluster VPC. Because the seed creates the topic
#     `deferred_to_operator` rather than directly (see create.sh), there
#     is nothing for this script to call `aws ... delete-*` on for the
#     topic; we emit a STATUS line documenting the required operator
#     follow-up and continue. (Cluster delete cascades the topic data on
#     the AWS side, so this asymmetry has no operational consequence.)
#

set -euo pipefail

# -----------------------------------------------------------------------------
# Resolve own location and source the shared seed helpers.
__SBX_MSK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib/common.sh disable=SC1091
source "${__SBX_MSK_DIR}/../_lib/common.sh"

sbx_init "msk" "$@"
sbx_assert_same_account

# -----------------------------------------------------------------------------
# In-script fallback for the prefix + state deletion gate.
#
# When the parent ./seed/teardown.sh invokes this script via `bash <child>`,
# it exports `_assert_can_delete` and `__state_has_arn` as bash functions
# in the environment so children inherit them. When this script is invoked
# directly (e.g. for unit-style verification), those exported helpers are
# absent. Define a same-semantics fallback so the gate is enforced either
# way. The fallback fails closed: missing prefix or missing state file
# means every candidate is skipped.
# -----------------------------------------------------------------------------
if ! declare -F _assert_can_delete >/dev/null 2>&1; then
    _state_has_arn() {
        local _t="${1:-}"
        if [ -z "$_t" ]; then return 1; fi
        local _p
        _p="$(sbx_state_path)"
        [ -f "$_p" ] || return 1
        command -v jq >/dev/null 2>&1 || return 1
        jq -e --arg t "$_t" '[.. | strings] | any(. == $t)' "$_p" >/dev/null 2>&1
    }
    _assert_can_delete() {
        local _kind="${1:-}" _name="${2:-}" _arn="${3:-}"
        if [ -z "${SBX_SEED_NAME_PREFIX:-}" ]; then
            sbx_status error "delete_blocked no_seed_name_prefix kind=${_kind} name=${_name}"
            exit 1
        fi
        case "$_name" in
            "${SBX_SEED_NAME_PREFIX}-"*) ;;
            *)
                sbx_status error "delete_blocked prefix_mismatch kind=${_kind} name=${_name} expected_prefix=${SBX_SEED_NAME_PREFIX}-"
                exit 1
                ;;
        esac
        if [ -z "$_arn" ] || ! _state_has_arn "$_arn"; then
            sbx_status error "delete_blocked state_missing kind=${_kind} name=${_name} arn=${_arn}"
            exit 1
        fi
        return 0
    }
fi

# -----------------------------------------------------------------------------
# Read the recorded MSK identifiers from seed.state.json. If the state file
# has nothing under .services.msk, there is nothing to tear down.
# -----------------------------------------------------------------------------
CLUSTER_NAME="$(sbx_state_get '.services.msk.resources.cluster.name')"
CLUSTER_ARN="$(sbx_state_get '.services.msk.resources.cluster.arn')"
SAMPLE_TOPIC="$(sbx_state_get '.services.msk.resources.topics[0].name')"

if [ -z "$CLUSTER_ARN" ] && [ -z "$CLUSTER_NAME" ]; then
    sbx_status skip "msk reason=nothing_in_state"
    exit 0
fi

# -----------------------------------------------------------------------------
# Topic delete (best-effort). The AWS CLI has no `aws kafka delete-topic`
# verb; topic deletion is a data-plane operation requiring kafka-topics.sh
# against the bootstrap brokers from inside the VPC. Because the seed
# never actually CREATED the topic (see create.sh's deferred_to_operator
# flow), there is no orphan to clean up here — but we emit a STATUS line
# so the operator log records that the asymmetry was acknowledged. If a
# future AWS CLI release adds a verb, replace this block with a real
# delete call gated by `_assert_can_delete topic ${SAMPLE_TOPIC} ${ARN}`.
# -----------------------------------------------------------------------------
if [ -n "$SAMPLE_TOPIC" ]; then
    sbx_status skip "msk_topic delete=not_supported_by_aws_cli name=${SAMPLE_TOPIC} (operator: kafka-topics.sh --delete --topic ${SAMPLE_TOPIC})"
fi

# -----------------------------------------------------------------------------
# Cluster delete. Hard-gated on prefix + state-file membership per 20.31.
# `aws kafka delete-cluster` accepts a cluster ARN and is the same verb
# for both Serverless and Provisioned clusters.
# -----------------------------------------------------------------------------
_assert_can_delete cluster "$CLUSTER_NAME" "$CLUSTER_ARN"

sbx_aws kafka delete-cluster \
    --region "$SBX_REGION" \
    --cluster-arn "$CLUSTER_ARN" >/dev/null || {
    sbx_status error "msk_delete_failed arn=${CLUSTER_ARN}"
    exit 1
}

sbx_status ok "msk_delete_initiated arn=${CLUSTER_ARN} name=${CLUSTER_NAME}"
sbx_log "msk: cluster delete initiated; AWS performs deletion asynchronously (typical 5–15 min)"
