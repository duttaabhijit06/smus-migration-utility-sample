#!/usr/bin/env bash
#
# seed/kinesis/teardown.sh — Amazon Kinesis Data Stream teardown.
#
# Removes the single Kinesis stream provisioned by `seed/kinesis/create.sh`
# Gated by the dual deletion check (Requirement 20.31):
#
#   (a) the recorded stream name MUST begin with `${SBX_SEED_NAME_PREFIX}-`
#   (b) AND the stream identifier MUST be present in seed.state.json under
#       `.services.kinesis.resources.stream_name`.
#
# A name failing either gate is left alone.
#
# Idempotent: ResourceNotFoundException on delete-stream is treated as a
# successful no-op (the stream is already gone). Status flips to
# `torn_down` after the delete (apply mode only).
#

set -euo pipefail

__kinesis_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SBX_WORKDIR="${SBX_WORKDIR:-$(dirname "$(dirname "$__kinesis_dir")")}"
export SBX_WORKDIR

# shellcheck source=../_lib/common.sh disable=SC1091
source "${SBX_WORKDIR}/seed/_lib/common.sh"

__SEED_CFG="$(sbx_config_path)"
if [ ! -f "$__SEED_CFG" ]; then
    sbx_status error config_missing
    exit 64
fi
if ! command -v jq >/dev/null 2>&1; then
    sbx_status error jq_required
    exit 64
fi
SBX_REGION="${SBX_REGION:-$(jq -r '.aws_region // empty' "$__SEED_CFG")}"
SBX_SOURCE_ACCOUNT_ID="${SBX_SOURCE_ACCOUNT_ID:-$(jq -r '.source_account_id // empty' "$__SEED_CFG")}"
SBX_SEED_NAME_PREFIX="${SBX_SEED_NAME_PREFIX:-$(jq -r '.seed_name_prefix // empty' "$__SEED_CFG")}"
export SBX_REGION SBX_SOURCE_ACCOUNT_ID SBX_SEED_NAME_PREFIX

sbx_init "kinesis" "$@"
sbx_assert_same_account
sbx_status started

# -----------------------------------------------------------------------------
# Read recorded stream name from state. Empty → no-op.
# -----------------------------------------------------------------------------
STREAM_NAME="$(sbx_state_get '.services.kinesis.resources.stream_name')"

if [ -z "$STREAM_NAME" ]; then
    sbx_log "no stream recorded in seed.state.json under .services.kinesis; nothing to delete"
    if sbx_apply_mode; then
        sbx_state_set_service kinesis '{"status":"torn_down"}'
    fi
    sbx_status ok
    exit 0
fi

# Prefix gate (Requirement 20.31).
case "$STREAM_NAME" in
    "${SBX_SEED_NAME_PREFIX}-"*) ;;
    *)
        sbx_status error "refusing to delete kinesis stream ${STREAM_NAME} (does not begin with ${SBX_SEED_NAME_PREFIX}-)"
        exit 1
        ;;
esac

# -----------------------------------------------------------------------------
# Existence probe (idempotency). Apply-mode only — dry-run renders the
# would-be probe + delete commands.
# -----------------------------------------------------------------------------
EXISTS=1
if sbx_apply_mode; then
    if ! aws kinesis describe-stream-summary \
            --region "$SBX_REGION" \
            --stream-name "$STREAM_NAME" \
            >/dev/null 2>&1; then
        EXISTS=0
    fi
else
    sbx_aws kinesis describe-stream-summary \
        --region "$SBX_REGION" \
        --stream-name "$STREAM_NAME" || true
fi

if [ "$EXISTS" -eq 0 ]; then
    sbx_log "kinesis stream ${STREAM_NAME} not present in AWS; skipping delete"
else
    # `--enforce-consumer-deletion` makes delete-stream succeed even when
    # there are registered enhanced-fan-out consumers (rare for a seed
    # stream but defensive for re-runs after a Firehose failure).
    sbx_aws kinesis delete-stream \
        --region "$SBX_REGION" \
        --stream-name "$STREAM_NAME" \
        --enforce-consumer-deletion
fi

# Mark torn down (apply mode only — bug fix 1a).
if sbx_apply_mode; then
    sbx_state_set_service kinesis '{"status":"torn_down"}'
fi

sbx_status ok "kinesis teardown complete: stream=${STREAM_NAME}"
