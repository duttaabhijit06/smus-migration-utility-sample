#!/usr/bin/env bash
#
# seed/firehose/teardown.sh — Amazon Data Firehose teardown.
#
# Reverse of create.sh:
#
#   1. delete-delivery-stream <prefix>-msk-to-s3-parquet
#   2. delete-delivery-stream <prefix>-kinesis-to-s3-parquet
#   3. detach managed policies from the firehose role (none, but list+detach
#      defensively)
#   4. delete inline policies (firehose-write)
#   5. delete the role
#
# Each delete-delivery-stream call uses --allow-force-delete so a stream
# in CREATING/DELETING state still gets removed.
#
# Gates: prefix gate AND state-file presence (Requirement 20.31).
#

set -euo pipefail

__firehose_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SBX_WORKDIR="${SBX_WORKDIR:-$(dirname "$(dirname "$__firehose_dir")")}"
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

sbx_init "firehose" "$@"
sbx_assert_same_account
sbx_status started

KINESIS_STREAM_NAME="$(sbx_state_get '.services.firehose.resources.kinesis_stream_name')"
MSK_STREAM_NAME="$(sbx_state_get '.services.firehose.resources.msk_stream_name')"
ROLE_NAME="$(sbx_state_get '.services.firehose.resources.role_name')"
DB_RAW_RECORDED="$(sbx_state_get '.services.firehose.resources.glue_database_raw')"
KIN_TABLE_RECORDED="$(sbx_state_get '.services.firehose.resources.kinesis_table_name')"
MSK_TABLE_RECORDED="$(sbx_state_get '.services.firehose.resources.msk_table_name')"

if [ -z "$KINESIS_STREAM_NAME" ] && [ -z "$MSK_STREAM_NAME" ] && [ -z "$ROLE_NAME" ] && [ -z "$KIN_TABLE_RECORDED" ] && [ -z "$MSK_TABLE_RECORDED" ]; then
    sbx_log "no firehose resources recorded in seed.state.json; nothing to delete"
    if sbx_apply_mode; then
        sbx_state_set_service firehose '{"status":"torn_down"}'
    fi
    sbx_status ok
    exit 0
fi

_verify_prefix() {
    case "${1:-}" in
        "${SBX_SEED_NAME_PREFIX}-"*) return 0 ;;
        *) return 1 ;;
    esac
}

_delete_one_stream() {
    local _name="${1:-}"
    if [ -z "$_name" ]; then return 0; fi
    if ! _verify_prefix "$_name"; then
        sbx_status error "refusing to delete delivery-stream ${_name} (does not begin with ${SBX_SEED_NAME_PREFIX}-)"
        return 0
    fi
    local _exists=1
    if sbx_apply_mode; then
        if ! aws firehose describe-delivery-stream \
                --region "$SBX_REGION" \
                --delivery-stream-name "$_name" \
                >/dev/null 2>&1; then
            _exists=0
        fi
    else
        sbx_aws firehose describe-delivery-stream \
            --region "$SBX_REGION" \
            --delivery-stream-name "$_name" || true
    fi
    if [ "$_exists" -eq 0 ]; then
        sbx_log "firehose ${_name} not present in AWS; skipping delete"
        return 0
    fi
    sbx_aws firehose delete-delivery-stream \
        --region "$SBX_REGION" \
        --delivery-stream-name "$_name" \
        --allow-force-delete
}

# Reverse order (msk before kinesis purely for log readability — they
# are independent).
_delete_one_stream "$MSK_STREAM_NAME"
_delete_one_stream "$KINESIS_STREAM_NAME"

# -----------------------------------------------------------------------------
# Delete the two raw catalog tables (firehose owns them post-resequencing).
# -----------------------------------------------------------------------------
_delete_one_raw_table() {
    local _db="$1"
    local _table="$2"
    if [ -z "$_db" ] || [ -z "$_table" ]; then
        return 0
    fi
    if ! _verify_prefix "$_db"; then
        sbx_status error "refusing to delete catalog table ${_db}.${_table} (database does not begin with ${SBX_SEED_NAME_PREFIX}-)"
        return 0
    fi
    local _exists=1
    if sbx_apply_mode; then
        if ! aws glue get-table \
                --region "$SBX_REGION" \
                --database-name "$_db" \
                --name "$_table" \
                >/dev/null 2>&1; then
            _exists=0
        fi
    else
        sbx_aws glue get-table \
            --region "$SBX_REGION" \
            --database-name "$_db" \
            --name "$_table" || true
    fi
    if [ "$_exists" -eq 0 ]; then
        sbx_log "glue catalog table ${_db}.${_table} not present; skipping delete"
        return 0
    fi
    sbx_aws glue delete-table \
        --region "$SBX_REGION" \
        --database-name "$_db" \
        --name "$_table"
}

if [ -n "$DB_RAW_RECORDED" ]; then
    _delete_one_raw_table "$DB_RAW_RECORDED" "$KIN_TABLE_RECORDED"
    _delete_one_raw_table "$DB_RAW_RECORDED" "$MSK_TABLE_RECORDED"
fi

# IAM role cleanup.
if [ -n "$ROLE_NAME" ]; then
    if ! _verify_prefix "$ROLE_NAME"; then
        sbx_status error "refusing to delete iam role ${ROLE_NAME} (does not begin with ${SBX_SEED_NAME_PREFIX}-)"
    else
        _role_present=1
        if sbx_apply_mode; then
            if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
                _role_present=0
            fi
        fi
        if [ "$_role_present" -eq 0 ]; then
            sbx_log "iam role ${ROLE_NAME} not present in AWS; skipping role cleanup"
        else
            # Detach managed policies (defensive — create.sh attaches none).
            _attached_arns=""
            if sbx_apply_mode; then
                _attached_arns="$(aws iam list-attached-role-policies \
                    --role-name "$ROLE_NAME" \
                    --query 'AttachedPolicies[].PolicyArn' \
                    --output text 2>/dev/null | tr '\t' '\n' || true)"
            fi
            while IFS= read -r _p; do
                [ -z "$_p" ] && continue
                sbx_aws iam detach-role-policy \
                    --role-name "$ROLE_NAME" \
                    --policy-arn "$_p"
            done <<< "$_attached_arns"

            # Delete inline policies (the canonical one is firehose-write).
            _inline_names=""
            if sbx_apply_mode; then
                _inline_names="$(aws iam list-role-policies \
                    --role-name "$ROLE_NAME" \
                    --query 'PolicyNames' \
                    --output text 2>/dev/null | tr '\t' '\n' || true)"
            else
                _inline_names="firehose-write"
            fi
            while IFS= read -r _n; do
                [ -z "$_n" ] && continue
                sbx_aws iam delete-role-policy \
                    --role-name "$ROLE_NAME" \
                    --policy-name "$_n"
            done <<< "$_inline_names"

            sbx_aws iam delete-role --role-name "$ROLE_NAME"
        fi
    fi
fi

if sbx_apply_mode; then
    sbx_state_set_service firehose '{"status":"torn_down"}'
fi

sbx_status ok "firehose teardown complete"
