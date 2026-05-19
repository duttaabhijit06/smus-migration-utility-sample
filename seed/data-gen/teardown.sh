#!/usr/bin/env bash
#
# seed/data-gen/teardown.sh — Reverse of seed/data-gen/create.sh.
#
#   1. disable EventBridge rule
#   2. remove targets
#   3. delete EventBridge rule
#   4. delete each Lambda function
#   5. detach managed policies from the role
#   6. delete inline policies (data-gen-write)
#   7. delete the role
#
# Gates: prefix gate AND state-file presence (Requirement 20.31).
#

set -euo pipefail

__dg_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SBX_WORKDIR="${SBX_WORKDIR:-$(dirname "$(dirname "$__dg_dir")")}"
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

sbx_init "data-gen" "$@"
sbx_assert_same_account
sbx_status started

# Read recorded identifiers; if all are empty, this is a no-op.
RULE_NAME="$(sbx_state_get '.services["data-gen"].resources.eventbridge_rule_name')"
KIN_FN="$(sbx_state_get '.services["data-gen"].resources.kinesis_function_name')"
MSK_FN="$(sbx_state_get '.services["data-gen"].resources.msk_function_name')"
ROLE_NAME="$(sbx_state_get '.services["data-gen"].resources.role_name')"

if [ -z "$RULE_NAME" ] && [ -z "$KIN_FN" ] && [ -z "$MSK_FN" ] && [ -z "$ROLE_NAME" ]; then
    sbx_log "no data-gen resources recorded; nothing to delete"
    if sbx_apply_mode; then
        sbx_state_set_service data-gen '{"status":"torn_down"}'
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

# -----------------------------------------------------------------------------
# Step 1+2+3. EventBridge rule lifecycle.
# -----------------------------------------------------------------------------
if [ -n "$RULE_NAME" ]; then
    if ! _verify_prefix "$RULE_NAME"; then
        sbx_status error "refusing to delete eventbridge rule ${RULE_NAME} (does not begin with ${SBX_SEED_NAME_PREFIX}-)"
    else
        _rule_exists=1
        if sbx_apply_mode; then
            if ! aws events describe-rule --name "$RULE_NAME" --region "$SBX_REGION" >/dev/null 2>&1; then
                _rule_exists=0
            fi
        fi
        if [ "$_rule_exists" -eq 0 ]; then
            sbx_log "eventbridge rule ${RULE_NAME} not present in AWS; skipping"
        else
            sbx_aws events disable-rule \
                --region "$SBX_REGION" \
                --name "$RULE_NAME"

            # remove-targets needs the IDs we put. The two canonical
            # IDs are kinesis-data-gen and msk-data-gen.
            sbx_aws events remove-targets \
                --region "$SBX_REGION" \
                --rule "$RULE_NAME" \
                --ids "kinesis-data-gen" "msk-data-gen"

            sbx_aws events delete-rule \
                --region "$SBX_REGION" \
                --name "$RULE_NAME"
        fi
    fi
fi

# -----------------------------------------------------------------------------
# Step 4. Delete Lambda functions.
# -----------------------------------------------------------------------------
_delete_one_fn() {
    local _name="${1:-}"
    if [ -z "$_name" ]; then return 0; fi
    if ! _verify_prefix "$_name"; then
        sbx_status error "refusing to delete lambda ${_name} (does not begin with ${SBX_SEED_NAME_PREFIX}-)"
        return 0
    fi
    local _exists=1
    if sbx_apply_mode; then
        if ! aws lambda get-function \
                --region "$SBX_REGION" \
                --function-name "$_name" \
                >/dev/null 2>&1; then
            _exists=0
        fi
    fi
    if [ "$_exists" -eq 0 ]; then
        sbx_log "lambda ${_name} not present in AWS; skipping"
        return 0
    fi
    sbx_aws lambda delete-function \
        --region "$SBX_REGION" \
        --function-name "$_name"
}
_delete_one_fn "$KIN_FN"
_delete_one_fn "$MSK_FN"

# -----------------------------------------------------------------------------
# Step 5+6+7. IAM role cleanup.
# -----------------------------------------------------------------------------
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
            _attached_arns=""
            if sbx_apply_mode; then
                _attached_arns="$(aws iam list-attached-role-policies \
                    --role-name "$ROLE_NAME" \
                    --query 'AttachedPolicies[].PolicyArn' \
                    --output text 2>/dev/null | tr '\t' '\n' || true)"
            else
                _attached_arns="arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
            fi
            while IFS= read -r _p; do
                [ -z "$_p" ] && continue
                sbx_aws iam detach-role-policy \
                    --role-name "$ROLE_NAME" \
                    --policy-arn "$_p"
            done <<< "$_attached_arns"

            _inline_names=""
            if sbx_apply_mode; then
                _inline_names="$(aws iam list-role-policies \
                    --role-name "$ROLE_NAME" \
                    --query 'PolicyNames' \
                    --output text 2>/dev/null | tr '\t' '\n' || true)"
            else
                _inline_names="data-gen-write"
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
    sbx_state_set_service data-gen '{"status":"torn_down"}'
fi

sbx_status ok "data-gen teardown complete"
