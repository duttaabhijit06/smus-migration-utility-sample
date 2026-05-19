#!/usr/bin/env bash
#
# seed/rds/teardown.sh — Amazon RDS Postgres teardown.
#
# Strict reverse of create.sh:
#
#   1. Best-effort delete the seeder Lambda + role (if still present).
#   2. delete-db-instance --skip-final-snapshot --delete-automated-backups
#   3. Wait for DBInstanceNotFoundFault (≤ 15 min budget).
#   4. delete-security-group (with retry-with-backoff because RDS holds
#      the SG ARN for a couple minutes after delete completes).
#   5. delete-db-subnet-group.
#
# Gated by Requirement 20.31 (prefix + state-file presence).
#

set -euo pipefail

__rds_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SBX_WORKDIR="${SBX_WORKDIR:-$(dirname "$(dirname "$__rds_dir")")}"
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

sbx_init "rds" "$@"
sbx_assert_same_account
sbx_status started

# Read recorded identifiers.
INSTANCE_ID="$(sbx_state_get '.services.rds.resources.instance_id')"
SUBNET_GROUP_NAME="$(sbx_state_get '.services.rds.resources.subnet_group_name')"
SECURITY_GROUP_ID="$(sbx_state_get '.services.rds.resources.security_group_id')"
SECURITY_GROUP_NAME="$(sbx_state_get '.services.rds.resources.security_group_name')"
SEEDER_LAMBDA_NAME="${SBX_SEED_NAME_PREFIX}-rds-seeder"
SEEDER_ROLE_NAME="${SBX_SEED_NAME_PREFIX}-rds-seeder-role"
LAMBDA_VPC_EXEC_POLICY_ARN="arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"

if [ -z "$INSTANCE_ID" ] && [ -z "$SUBNET_GROUP_NAME" ]; then
    sbx_log "no rds resources recorded in seed.state.json; nothing to delete"
    if sbx_apply_mode; then
        sbx_state_set_service rds '{"status":"torn_down"}'
    fi
    sbx_status ok
    exit 0
fi

_verify_prefix() {
    local _name="${1:-}"
    case "$_name" in
        "${SBX_SEED_NAME_PREFIX}-"*) return 0 ;;
        *) return 1 ;;
    esac
}

# -----------------------------------------------------------------------------
# Step 1. Best-effort seeder Lambda cleanup. The disposable seeder is
# normally deleted at the end of create.sh, but a failure between
# `aws lambda invoke` and `aws lambda delete-function` could leave it
# behind.
# -----------------------------------------------------------------------------
if sbx_apply_mode; then
    if aws lambda get-function --function-name "$SEEDER_LAMBDA_NAME" --region "$SBX_REGION" >/dev/null 2>&1; then
        sbx_aws lambda delete-function \
            --region "$SBX_REGION" \
            --function-name "$SEEDER_LAMBDA_NAME"
    fi
    if aws iam get-role --role-name "$SEEDER_ROLE_NAME" >/dev/null 2>&1; then
        aws iam detach-role-policy --role-name "$SEEDER_ROLE_NAME" \
            --policy-arn "$LAMBDA_VPC_EXEC_POLICY_ARN" >/dev/null 2>&1 || true
        sbx_aws iam delete-role --role-name "$SEEDER_ROLE_NAME"
    fi
else
    sbx_aws lambda delete-function \
        --region "$SBX_REGION" \
        --function-name "$SEEDER_LAMBDA_NAME"
    sbx_aws iam detach-role-policy \
        --role-name "$SEEDER_ROLE_NAME" \
        --policy-arn "$LAMBDA_VPC_EXEC_POLICY_ARN"
    sbx_aws iam delete-role --role-name "$SEEDER_ROLE_NAME"
fi

# -----------------------------------------------------------------------------
# Step 2 + 3. Delete DB instance + wait for it to be gone.
# -----------------------------------------------------------------------------
if [ -n "$INSTANCE_ID" ]; then
    if ! _verify_prefix "$INSTANCE_ID"; then
        sbx_status error "refusing to delete db instance ${INSTANCE_ID} (does not begin with ${SBX_SEED_NAME_PREFIX}-)"
        exit 1
    fi

    INSTANCE_EXISTS=1
    if sbx_apply_mode; then
        if ! aws rds describe-db-instances \
                --region "$SBX_REGION" \
                --db-instance-identifier "$INSTANCE_ID" \
                >/dev/null 2>&1; then
            INSTANCE_EXISTS=0
        fi
    else
        sbx_aws rds describe-db-instances \
            --region "$SBX_REGION" \
            --db-instance-identifier "$INSTANCE_ID" || true
    fi

    if [ "$INSTANCE_EXISTS" -eq 0 ]; then
        sbx_log "db instance ${INSTANCE_ID} not present in AWS; skipping delete"
    else
        sbx_aws rds delete-db-instance \
            --region "$SBX_REGION" \
            --db-instance-identifier "$INSTANCE_ID" \
            --skip-final-snapshot \
            --delete-automated-backups

        if sbx_apply_mode; then
            sbx_status action "rds_wait_deleted instance=${INSTANCE_ID}"
            _i=0
            _max_polls=30
            _gone=0
            while [ "$_i" -lt "$_max_polls" ]; do
                if ! aws rds describe-db-instances \
                        --region "$SBX_REGION" \
                        --db-instance-identifier "$INSTANCE_ID" \
                        >/dev/null 2>&1; then
                    _gone=1
                    break
                fi
                if [ $((_i % 4)) -eq 0 ]; then
                    sbx_status in-progress "rds_wait_deleted poll=${_i}/${_max_polls}"
                fi
                _i=$((_i + 1))
                sleep 30
            done
            if [ "$_gone" -ne 1 ]; then
                sbx_log "warning: rds instance ${INSTANCE_ID} did not finish deleting in $((_max_polls*30))s; continuing teardown"
            fi
        fi
    fi
fi

# -----------------------------------------------------------------------------
# Step 4. Delete security group with retry-with-backoff. RDS holds the
# SG ARN for ~2 min after delete-db-instance completes, so the first
# delete attempt frequently hits DependencyViolation. Retry up to 12
# times at 15 s intervals (~3 min total budget).
# -----------------------------------------------------------------------------
if [ -n "$SECURITY_GROUP_ID" ]; then
    if [ -n "$SECURITY_GROUP_NAME" ] && ! _verify_prefix "$SECURITY_GROUP_NAME"; then
        sbx_status error "refusing to delete security group ${SECURITY_GROUP_ID} (recorded name ${SECURITY_GROUP_NAME} does not begin with ${SBX_SEED_NAME_PREFIX}-)"
        exit 1
    fi

    if sbx_apply_mode; then
        sbx_status action "ec2_delete_security_group_with_backoff sg=${SECURITY_GROUP_ID}"
        _i=0
        _max_attempts=12
        _deleted=0
        while [ "$_i" -lt "$_max_attempts" ]; do
            if aws ec2 delete-security-group \
                    --region "$SBX_REGION" \
                    --group-id "$SECURITY_GROUP_ID" >/dev/null 2>&1; then
                _deleted=1
                break
            fi
            # Probe: maybe it's already gone.
            if ! aws ec2 describe-security-groups \
                    --region "$SBX_REGION" \
                    --group-ids "$SECURITY_GROUP_ID" \
                    >/dev/null 2>&1; then
                _deleted=1
                break
            fi
            sbx_log "delete-security-group ${SECURITY_GROUP_ID} attempt ${_i} returned non-zero (likely DependencyViolation while RDS releases the SG); retrying in 15s"
            _i=$((_i + 1))
            sleep 15
        done
        if [ "$_deleted" -ne 1 ]; then
            sbx_status error "delete_security_group_failed sg=${SECURITY_GROUP_ID} after ${_max_attempts} attempts"
            # Keep going — subnet group deletion is independent.
        fi
    else
        sbx_aws ec2 delete-security-group \
            --region "$SBX_REGION" \
            --group-id "$SECURITY_GROUP_ID"
    fi
fi

# -----------------------------------------------------------------------------
# Step 5. Delete DB subnet group.
# -----------------------------------------------------------------------------
if [ -n "$SUBNET_GROUP_NAME" ]; then
    if ! _verify_prefix "$SUBNET_GROUP_NAME"; then
        sbx_status error "refusing to delete db subnet group ${SUBNET_GROUP_NAME} (does not begin with ${SBX_SEED_NAME_PREFIX}-)"
        exit 1
    fi
    SNG_EXISTS=1
    if sbx_apply_mode; then
        if ! aws rds describe-db-subnet-groups \
                --region "$SBX_REGION" \
                --db-subnet-group-name "$SUBNET_GROUP_NAME" \
                >/dev/null 2>&1; then
            SNG_EXISTS=0
        fi
    fi
    if [ "$SNG_EXISTS" -eq 0 ]; then
        sbx_log "db subnet group ${SUBNET_GROUP_NAME} not present in AWS; skipping delete"
    else
        sbx_aws rds delete-db-subnet-group \
            --region "$SBX_REGION" \
            --db-subnet-group-name "$SUBNET_GROUP_NAME"
    fi
fi

if sbx_apply_mode; then
    sbx_state_set_service rds '{"status":"torn_down"}'
fi

sbx_status ok "rds teardown complete"
