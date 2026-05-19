#!/usr/bin/env bash
#
# seed/kinesis/create.sh — Amazon Kinesis Data Stream Seed_Service_Module.
#
# Creates ONE on-demand Kinesis Data Stream named `<prefix>-events`. This
# stream is the SOURCE for the kinesis-to-Parquet Firehose delivery
# stream provisioned by `seed/firehose/create.sh` and the SINK for the
# `<prefix>-kinesis-data-gen` Lambda from `seed/data-gen/create.sh`.
#
# Resource catalogue (Requirement 20.29 — every name begins with
# `${SBX_SEED_NAME_PREFIX}-`):
#
#   <prefix>-events    (Kinesis Data Stream, ON_DEMAND mode)
#
# State persisted (Requirement 20.12) under `.services.kinesis.resources`:
#   - stream_name : "<prefix>-events"
#   - stream_arn  : "arn:aws:kinesis:<region>:<account>:stream/<prefix>-events"
#
# Idempotency (Requirement 20.13):
#   `aws kinesis describe-stream-summary` precedes `aws kinesis create-stream`.
#   When a stream with the matching name already exists the create is
#   skipped; tags and ARN are persisted from the describe-* response.
#
# Bug fixes applied (per the project's refactor contract):
#   - 1a: state writes are gated behind `sbx_apply_mode`. Dry-run never
#         writes `provisioned` to seed.state.json.
#   - 1b: any `aws ... --cli-input-json` here uses a real `mktemp` file
#         (not `/dev/stdin`). N/A in this module — kinesis create-stream
#         takes flat flags only — but the pattern is documented for
#         consistency with the rest of the seed.
#   - 1d: aws CLI captures bypass `sbx_aws` so the `STATUS: action` line
#         it would print does not pollute the JSON capture; the STATUS
#         line is emitted manually via `sbx_status action ...`.
#
# Same-account contract (Requirement 20.28): `sbx_assert_same_account`
# runs immediately after sbx_init.
#

set -euo pipefail

# Resolve the seed root from this script's location so create.sh works
# from any cwd. The grandparent is the seed root; one more is the
# workspace root that common.sh expects in SBX_WORKDIR.
__kinesis_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SBX_WORKDIR="${SBX_WORKDIR:-$(dirname "$(dirname "$__kinesis_dir")")}"
export SBX_WORKDIR

# shellcheck source=../_lib/common.sh disable=SC1091
source "${SBX_WORKDIR}/seed/_lib/common.sh"

# Pre-load core SBX_* vars from seed.config.json so direct invocations
# (without the orchestrator first) pass sbx_init's required-var check.
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

# -----------------------------------------------------------------------------
# Resource names + canonical ARN.
# -----------------------------------------------------------------------------

STREAM_NAME="${SBX_SEED_NAME_PREFIX}-events"
STREAM_ARN="arn:aws:kinesis:${SBX_REGION}:${SBX_SOURCE_ACCOUNT_ID}:stream/${STREAM_NAME}"

sbx_status started

# -----------------------------------------------------------------------------
# Idempotency probe — describe-stream-summary returns a small, stable
# payload (no shard list) and exits non-zero on ResourceNotFoundException.
# We bypass `sbx_aws` here (bug fix 1d) because we want to swallow the
# error output cleanly without the `STATUS: action` line interleaving
# with stderr, and we emit the STATUS audit line manually.
# -----------------------------------------------------------------------------
EXISTS=0

if sbx_apply_mode; then
    sbx_status action "aws kinesis describe-stream-summary"
    if aws kinesis describe-stream-summary \
            --region "$SBX_REGION" \
            --stream-name "$STREAM_NAME" \
            >/dev/null 2>&1; then
        EXISTS=1
    fi
else
    # Dry-run renders the would-be probe through sbx_aws so the audit log
    # captures `DRY-RUN: aws kinesis describe-stream-summary ...`.
    sbx_aws kinesis describe-stream-summary \
        --region "$SBX_REGION" \
        --stream-name "$STREAM_NAME" || true
fi

# -----------------------------------------------------------------------------
# Create the stream when missing. ON_DEMAND mode means no shard count is
# needed; AWS auto-scales. The `--stream-mode-details StreamMode=ON_DEMAND`
# flag is the canonical way to request on-demand provisioning.
# -----------------------------------------------------------------------------
if [ "$EXISTS" -eq 1 ]; then
    sbx_log "kinesis stream ${STREAM_NAME} already exists; skipping create-stream"
else
    sbx_aws kinesis create-stream \
        --region "$SBX_REGION" \
        --stream-name "$STREAM_NAME" \
        --stream-mode-details "StreamMode=ON_DEMAND"
fi

# -----------------------------------------------------------------------------
# Tag the stream with the seed prefix marker. add-tags-to-stream is
# idempotent (re-tagging the same key is a 200 no-op), so we issue this
# on every run rather than gating it behind a list-tags probe.
# -----------------------------------------------------------------------------
sbx_aws kinesis add-tags-to-stream \
    --region "$SBX_REGION" \
    --stream-name "$STREAM_NAME" \
    --tags "sbx:seed-name-prefix=${SBX_SEED_NAME_PREFIX}"

# -----------------------------------------------------------------------------
# Bounded poll for ACTIVE. ON_DEMAND streams typically reach ACTIVE in
# under 30 s; the budget is 30 polls × 1 s = 30 s. Skipped entirely in
# dry-run because the stream does not exist yet.
# -----------------------------------------------------------------------------
if sbx_apply_mode; then
    sbx_status action "kinesis_wait_active stream=${STREAM_NAME}"
    _state="UNKNOWN"
    _i=0
    _max_polls=30
    while [ "$_i" -lt "$_max_polls" ]; do
        # Bypass sbx_aws (bug fix 1d) so stdout capture is clean.
        _summary_json="$(aws kinesis describe-stream-summary \
            --region "$SBX_REGION" \
            --stream-name "$STREAM_NAME" \
            --output json 2>/dev/null || echo '{}')"
        # `// empty` defensive jq fallback so a malformed response leaves
        # _state as "UNKNOWN" rather than tripping `set -e`.
        _state="$(printf '%s' "$_summary_json" | jq -r '.StreamDescriptionSummary.StreamStatus // "UNKNOWN"')"
        if [ "$_state" = "ACTIVE" ]; then
            break
        fi
        case "$_state" in
            DELETING)
                sbx_status error "kinesis_stream_deleting name=${STREAM_NAME}"
                exit 1
                ;;
        esac
        _i=$((_i + 1))
        sleep 1
    done
    if [ "$_state" != "ACTIVE" ]; then
        sbx_status error "kinesis_wait_active_timeout name=${STREAM_NAME} state=${_state} polls=${_max_polls}"
        exit 1
    fi
    sbx_status ok "kinesis_active name=${STREAM_NAME}"
fi

# -----------------------------------------------------------------------------
# Persist state ONLY in apply mode (bug fix 1a). Dry-run logs the planned
# write but does not mutate seed.state.json — this is what makes a
# `provision --dry-run` re-runnable without polluting state.
# -----------------------------------------------------------------------------
if sbx_apply_mode; then
    sbx_state_set_service kinesis "$(jq -n \
        --arg name "$STREAM_NAME" \
        --arg arn "$STREAM_ARN" \
        '{
            status: "provisioned",
            resources: {
                stream_name: $name,
                stream_arn: $arn
            }
        }')"
    sbx_status ok "kinesis_provisioned stream=${STREAM_NAME} arn=${STREAM_ARN}"
else
    sbx_log "dry-run: skipping state write (would record .services.kinesis.status=provisioned, stream=${STREAM_NAME})"
    sbx_status ok "kinesis_dry_run stream=${STREAM_NAME}"
fi
