#!/usr/bin/env bash
#
# seed/rds/create.sh — Amazon RDS Postgres Seed_Service_Module.
#
# Provisions a small db.t3.micro Postgres instance backing the seed
# `<prefix>-rds-to-parquet` Glue ETL job (registered in glue phase 1)
# that lifts RDS rows into curated S3 Parquet under
# `s3://<data-bucket>/curated/{customers,products}/`.
#
# Resource catalogue (Requirement 20.29 — every name begins with
# `${SBX_SEED_NAME_PREFIX}-`):
#
#   <prefix>-rds-subnet-group   DB subnet group covering the seed VPC subnets
#   <prefix>-rds-sg             Security group permitting 5432/tcp from the VPC CIDR
#   <prefix>-postgres           DB instance (postgres engine, db.t3.micro, 20 GiB GP3)
#   <prefix>-rds-seeder-role    IAM role for the one-shot seeder Lambda
#   <prefix>-rds-seeder         One-shot Lambda that loads schema + data, then is deleted
#
# Master credentials:
#   - Username: seedadmin (literal, deterministic)
#   - Password: a 24-char URL-safe random token, generated INSIDE the
#     create.sh script and persisted to seed.state.json under
#     `.services.rds.resources.master_password` — only when running in
#     apply mode (bug fix 1a + sensitive data caveat). Operators MUST
#     treat seed.state.json as sensitive; this is documented in
#     ./README.md.
#
# Data flow:
#   1. Create subnet group + security group.
#   2. Create db instance (db.t3.micro, single-AZ, Postgres 16, 20 GiB).
#   3. Wait for the instance to reach `available` (≤ 15 min budget).
#   4. Capture the endpoint and persist alongside the password in state.
#   5. Build a one-shot seeder Lambda (Python 3.11, pg8000 vendored)
#      attached to the same VPC + SG as the RDS instance.
#   6. Invoke the seeder; verify ExecutedFunctionError == None.
#   7. Delete the seeder Lambda and its IAM role; null the seeder_lambda_arn
#      slot in state to mark cleanup complete.
#
# Bug fixes applied:
#   - 1a: state writes happen ONLY in apply mode. The master password is
#         additionally guarded so dry-run never writes a real password.
#   - 1b: any `--cli-input-json` invocations use a real `mktemp` file
#         (not `/dev/stdin`).
#   - 1d: aws CLI captures bypass `sbx_aws` and emit STATUS manually.
#

set -euo pipefail

# Resolve seed root.
__rds_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SBX_WORKDIR="${SBX_WORKDIR:-$(dirname "$(dirname "$__rds_dir")")}"
export SBX_WORKDIR

# shellcheck source=../_lib/common.sh disable=SC1091
source "${SBX_WORKDIR}/seed/_lib/common.sh"

# Pre-load core SBX_* vars from seed.config.json.
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

# -----------------------------------------------------------------------------
# Names + constants.
# -----------------------------------------------------------------------------
SUBNET_GROUP_NAME="${SBX_SEED_NAME_PREFIX}-rds-subnet-group"
SECURITY_GROUP_NAME="${SBX_SEED_NAME_PREFIX}-rds-sg"
DB_INSTANCE_ID="${SBX_SEED_NAME_PREFIX}-postgres"
DB_NAME="seeddb"
DB_USERNAME="seedadmin"
DB_PORT=5432
DB_INSTANCE_CLASS="db.t3.micro"
DB_ALLOCATED_STORAGE=20
DB_STORAGE_TYPE="gp3"
DB_ENGINE="postgres"

SEEDER_LAMBDA_NAME="${SBX_SEED_NAME_PREFIX}-rds-seeder"
SEEDER_ROLE_NAME="${SBX_SEED_NAME_PREFIX}-rds-seeder-role"
LAMBDA_VPC_EXEC_POLICY_ARN="arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"

# Read VPC config.
VPC_ID="$(jq -r '.rds.vpc_id // empty' "$__SEED_CFG")"
SUBNET_IDS_JSON="$(jq -c '.rds.subnet_ids // .msk.vpc_subnet_ids // []' "$__SEED_CFG")"
ENGINE_VERSION_PINNED="$(jq -r '.rds.engine_version // "16"' "$__SEED_CFG")"

if sbx_apply_mode; then
    if [ -z "$VPC_ID" ]; then
        sbx_status error "rds_vpc_id_required: set .rds.vpc_id in seed.config.json before --apply"
        exit 64
    fi
    if [ "$SUBNET_IDS_JSON" = "[]" ]; then
        sbx_status error "rds_subnets_required: set .rds.subnet_ids (or .msk.vpc_subnet_ids fallback) in seed.config.json before --apply"
        exit 64
    fi
fi

sbx_status started

sbx_log "rds: instance=${DB_INSTANCE_ID} engine=${DB_ENGINE} class=${DB_INSTANCE_CLASS} storage=${DB_ALLOCATED_STORAGE}GB"

# -----------------------------------------------------------------------------
# Step 1. Resolve engine version.
#
# The config pins a "major" prefix (e.g. "16"); RDS expects a full
# version string like "16.3". We use describe-db-engine-versions
# --default-only to find the current default for that major. Falls back
# to the pinned value if the lookup fails (offline / dry-run).
# -----------------------------------------------------------------------------
ENGINE_VERSION="$ENGINE_VERSION_PINNED"
if sbx_apply_mode; then
    sbx_status action "aws rds describe-db-engine-versions"
    _eng_json="$(aws rds describe-db-engine-versions \
        --region "$SBX_REGION" \
        --engine "$DB_ENGINE" \
        --default-only \
        --output json 2>/dev/null || echo '{}')"
    _resolved="$(printf '%s' "$_eng_json" | jq -r --arg major "$ENGINE_VERSION_PINNED" \
        '.DBEngineVersions[]? | select(.EngineVersion | startswith($major + ".") or . == $major) | .EngineVersion' \
        | head -n 1)"
    if [ -n "$_resolved" ]; then
        ENGINE_VERSION="$_resolved"
        sbx_log "resolved postgres engine version: ${ENGINE_VERSION}"
    fi
fi

# -----------------------------------------------------------------------------
# Step 2. Resolve VPC CIDR. Required for the security group's inbound
# rule (5432/tcp from the VPC CIDR). In dry-run we use a placeholder.
# -----------------------------------------------------------------------------
VPC_CIDR="0.0.0.0/0"
if sbx_apply_mode && [ -n "$VPC_ID" ]; then
    sbx_status action "aws ec2 describe-vpcs"
    _vpc_json="$(aws ec2 describe-vpcs \
        --region "$SBX_REGION" \
        --vpc-ids "$VPC_ID" \
        --output json 2>/dev/null || echo '{}')"
    _resolved_cidr="$(printf '%s' "$_vpc_json" | jq -r '.Vpcs[0].CidrBlock // empty')"
    if [ -n "$_resolved_cidr" ]; then
        VPC_CIDR="$_resolved_cidr"
        sbx_log "resolved VPC CIDR for ${VPC_ID}: ${VPC_CIDR}"
    else
        sbx_log "warning: could not resolve CIDR for VPC ${VPC_ID}; falling back to ${VPC_CIDR}"
    fi
elif ! sbx_apply_mode; then
    VPC_CIDR="10.0.0.0/16"  # placeholder for dry-run audit log
fi

# -----------------------------------------------------------------------------
# Step 3. DB subnet group.
# -----------------------------------------------------------------------------
SUBNET_GROUP_EXISTS=0
if sbx_apply_mode; then
    if aws rds describe-db-subnet-groups \
            --region "$SBX_REGION" \
            --db-subnet-group-name "$SUBNET_GROUP_NAME" \
            >/dev/null 2>&1; then
        SUBNET_GROUP_EXISTS=1
    fi
else
    sbx_aws rds describe-db-subnet-groups \
        --region "$SBX_REGION" \
        --db-subnet-group-name "$SUBNET_GROUP_NAME" || true
fi

if [ "$SUBNET_GROUP_EXISTS" -eq 1 ]; then
    sbx_log "db subnet group ${SUBNET_GROUP_NAME} already exists; skipping create"
else
    # Pass subnet IDs as space-separated tokens (the AWS CLI accepts
    # --subnet-ids subnet-a subnet-b) so SUBNET_IDS_JSON does not need
    # complex quoting on the command line.
    _subnet_args=()
    while IFS= read -r _s; do
        [ -z "$_s" ] && continue
        _subnet_args+=("$_s")
    done < <(printf '%s' "$SUBNET_IDS_JSON" | jq -r '.[]?')
    if [ "${#_subnet_args[@]}" -eq 0 ] && ! sbx_apply_mode; then
        _subnet_args=("subnet-PLACEHOLDER-1" "subnet-PLACEHOLDER-2")
    fi
    sbx_aws rds create-db-subnet-group \
        --region "$SBX_REGION" \
        --db-subnet-group-name "$SUBNET_GROUP_NAME" \
        --db-subnet-group-description "Seed RDS subnet group for ${SBX_SEED_NAME_PREFIX}" \
        --subnet-ids "${_subnet_args[@]}" \
        --tags "Key=sbx:seed-name-prefix,Value=${SBX_SEED_NAME_PREFIX}"
fi

# -----------------------------------------------------------------------------
# Step 4. Security group + ingress rule on 5432 from the VPC CIDR.
# -----------------------------------------------------------------------------
SECURITY_GROUP_ID=""
if sbx_apply_mode; then
    sbx_status action "aws ec2 describe-security-groups (lookup)"
    _sg_id="$(aws ec2 describe-security-groups \
        --region "$SBX_REGION" \
        --filters "Name=group-name,Values=${SECURITY_GROUP_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
        --query 'SecurityGroups[0].GroupId' \
        --output text 2>/dev/null || echo "")"
    if [ -n "$_sg_id" ] && [ "$_sg_id" != "None" ]; then
        SECURITY_GROUP_ID="$_sg_id"
        sbx_log "security group ${SECURITY_GROUP_NAME} already exists: ${SECURITY_GROUP_ID}"
    fi
else
    sbx_aws ec2 describe-security-groups \
        --region "$SBX_REGION" \
        --filters "Name=group-name,Values=${SECURITY_GROUP_NAME}" "Name=vpc-id,Values=${VPC_ID:-vpc-PLACEHOLDER}" || true
fi

if [ -z "$SECURITY_GROUP_ID" ]; then
    if sbx_apply_mode; then
        sbx_status action "aws ec2 create-security-group"
        SECURITY_GROUP_ID="$(aws ec2 create-security-group \
            --region "$SBX_REGION" \
            --group-name "$SECURITY_GROUP_NAME" \
            --description "Seed RDS security group for ${SBX_SEED_NAME_PREFIX}" \
            --vpc-id "$VPC_ID" \
            --tag-specifications "ResourceType=security-group,Tags=[{Key=sbx:seed-name-prefix,Value=${SBX_SEED_NAME_PREFIX}}]" \
            --query 'GroupId' \
            --output text)"

        # Ingress 5432 from VPC CIDR. Idempotent: AWS returns
        # InvalidPermission.Duplicate when the rule already exists, which
        # we tolerate.
        aws ec2 authorize-security-group-ingress \
            --region "$SBX_REGION" \
            --group-id "$SECURITY_GROUP_ID" \
            --protocol tcp \
            --port 5432 \
            --cidr "$VPC_CIDR" \
            >/dev/null 2>&1 || true
    else
        sbx_aws ec2 create-security-group \
            --region "$SBX_REGION" \
            --group-name "$SECURITY_GROUP_NAME" \
            --description "Seed RDS security group for ${SBX_SEED_NAME_PREFIX}" \
            --vpc-id "${VPC_ID:-vpc-PLACEHOLDER}"
        sbx_aws ec2 authorize-security-group-ingress \
            --region "$SBX_REGION" \
            --group-id "sg-PLACEHOLDER" \
            --protocol tcp \
            --port 5432 \
            --cidr "$VPC_CIDR"
        SECURITY_GROUP_ID="sg-PLACEHOLDER"
    fi
fi

# -----------------------------------------------------------------------------
# Step 5. Generate (or re-use) the master password.
#
# Sensitive: the password is generated only when freshly creating the
# instance. On a re-run we reuse the value already in state, so the
# downstream Glue JDBC connection password stays consistent. In dry-run
# we use a literal `<DRY-RUN-PLACEHOLDER>` so nothing leaks into the
# audit log even if SBX_LOG_PATH is shared.
# -----------------------------------------------------------------------------
RECORDED_PASSWORD="$(sbx_state_get '.services.rds.resources.master_password')"
MASTER_PASSWORD="${RECORDED_PASSWORD:-}"

if [ -z "$MASTER_PASSWORD" ]; then
    if sbx_apply_mode; then
        # 24-character URL-safe token. python3 secrets.token_urlsafe(18)
        # produces ~24 chars in [A-Za-z0-9_-], which is well within RDS
        # Postgres' 8–128 char range and excludes the / @ " ' chars RDS
        # disallows.
        MASTER_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')"
    else
        MASTER_PASSWORD="DRY-RUN-PLACEHOLDER"
    fi
fi

# -----------------------------------------------------------------------------
# Step 6. DB instance.
# -----------------------------------------------------------------------------
DB_INSTANCE_EXISTS=0
DB_ENDPOINT=""
if sbx_apply_mode; then
    if aws rds describe-db-instances \
            --region "$SBX_REGION" \
            --db-instance-identifier "$DB_INSTANCE_ID" \
            >/dev/null 2>&1; then
        DB_INSTANCE_EXISTS=1
        DB_ENDPOINT="$(aws rds describe-db-instances \
            --region "$SBX_REGION" \
            --db-instance-identifier "$DB_INSTANCE_ID" \
            --query 'DBInstances[0].Endpoint.Address' \
            --output text 2>/dev/null || echo "")"
    fi
else
    sbx_aws rds describe-db-instances \
        --region "$SBX_REGION" \
        --db-instance-identifier "$DB_INSTANCE_ID" || true
fi

if [ "$DB_INSTANCE_EXISTS" -eq 1 ]; then
    sbx_log "db instance ${DB_INSTANCE_ID} already exists; skipping create"
else
    if sbx_apply_mode; then
        sbx_status action "aws rds create-db-instance"
        aws rds create-db-instance \
            --region "$SBX_REGION" \
            --db-instance-identifier "$DB_INSTANCE_ID" \
            --db-instance-class "$DB_INSTANCE_CLASS" \
            --engine "$DB_ENGINE" \
            --engine-version "$ENGINE_VERSION" \
            --allocated-storage "$DB_ALLOCATED_STORAGE" \
            --storage-type "$DB_STORAGE_TYPE" \
            --master-username "$DB_USERNAME" \
            --master-user-password "$MASTER_PASSWORD" \
            --db-name "$DB_NAME" \
            --vpc-security-group-ids "$SECURITY_GROUP_ID" \
            --db-subnet-group-name "$SUBNET_GROUP_NAME" \
            --port "$DB_PORT" \
            --no-multi-az \
            --no-publicly-accessible \
            --backup-retention-period 0 \
            --tags "Key=sbx:seed-name-prefix,Value=${SBX_SEED_NAME_PREFIX}" \
            >/dev/null
    else
        sbx_aws rds create-db-instance \
            --region "$SBX_REGION" \
            --db-instance-identifier "$DB_INSTANCE_ID" \
            --db-instance-class "$DB_INSTANCE_CLASS" \
            --engine "$DB_ENGINE" \
            --engine-version "$ENGINE_VERSION" \
            --allocated-storage "$DB_ALLOCATED_STORAGE" \
            --storage-type "$DB_STORAGE_TYPE" \
            --master-username "$DB_USERNAME" \
            --master-user-password "<REDACTED>" \
            --db-name "$DB_NAME" \
            --vpc-security-group-ids "$SECURITY_GROUP_ID" \
            --db-subnet-group-name "$SUBNET_GROUP_NAME" \
            --port "$DB_PORT" \
            --no-multi-az \
            --no-publicly-accessible
    fi
fi

# Persist what we know BEFORE the long wait (Requirement 20.12).
# Bug fix 1a: only writes in apply mode. Note the password is included
# in the apply-mode payload because the README documents that the state
# file is sensitive and operators must treat it accordingly.
if sbx_apply_mode; then
    sbx_state_set_service rds "$(jq -n \
        --arg id "$DB_INSTANCE_ID" \
        --arg db "$DB_NAME" \
        --arg user "$DB_USERNAME" \
        --argjson port "$DB_PORT" \
        --arg sg "$SECURITY_GROUP_ID" \
        --arg sgname "$SECURITY_GROUP_NAME" \
        --arg sng "$SUBNET_GROUP_NAME" \
        --arg engine "$DB_ENGINE" \
        --arg ver "$ENGINE_VERSION" \
        --arg pw "$MASTER_PASSWORD" \
        '{
            status: "provisioning",
            resources: {
                instance_id: $id,
                db_name: $db,
                master_username: $user,
                master_password: $pw,
                port: $port,
                security_group_id: $sg,
                security_group_name: $sgname,
                subnet_group_name: $sng,
                engine: $engine,
                engine_version: $ver
            }
        }')"
fi

# -----------------------------------------------------------------------------
# Step 7. Wait for `available`. RDS is slow — 5–15 min typical for
# db.t3.micro. Budget 30 polls × 30 s = 15 min.
# -----------------------------------------------------------------------------
if sbx_apply_mode; then
    sbx_status action "rds_wait_available instance=${DB_INSTANCE_ID}"
    _state="UNKNOWN"
    _i=0
    _max_polls=30
    while [ "$_i" -lt "$_max_polls" ]; do
        _state="$(aws rds describe-db-instances \
            --region "$SBX_REGION" \
            --db-instance-identifier "$DB_INSTANCE_ID" \
            --query 'DBInstances[0].DBInstanceStatus' \
            --output text 2>/dev/null || echo "UNKNOWN")"
        if [ "$_state" = "available" ]; then
            DB_ENDPOINT="$(aws rds describe-db-instances \
                --region "$SBX_REGION" \
                --db-instance-identifier "$DB_INSTANCE_ID" \
                --query 'DBInstances[0].Endpoint.Address' \
                --output text 2>/dev/null || echo "")"
            break
        fi
        case "$_state" in
            failed|incompatible-network|incompatible-restore|incompatible-parameters)
                sbx_status error "rds_unhealthy state=${_state} instance=${DB_INSTANCE_ID}"
                sbx_state_set_service rds '{"status":"failed"}'
                exit 1
                ;;
        esac
        if [ $((_i % 4)) -eq 0 ]; then
            sbx_status in-progress "rds_wait_available poll=${_i}/${_max_polls} state=${_state}"
        fi
        _i=$((_i + 1))
        sleep 30
    done
    if [ "$_state" != "available" ]; then
        sbx_status error "rds_wait_available_timeout state=${_state} instance=${DB_INSTANCE_ID} polls=${_max_polls}"
        sbx_state_set_service rds '{"status":"failed"}'
        exit 1
    fi
    sbx_status ok "rds_available instance=${DB_INSTANCE_ID} endpoint=${DB_ENDPOINT}"
else
    DB_ENDPOINT="${DB_INSTANCE_ID}.dryrun-placeholder.${SBX_REGION}.rds.amazonaws.com"
    sbx_log "dry-run: would wait for instance to reach 'available' (~5-15 min apply-mode)"
fi

# -----------------------------------------------------------------------------
# Step 8. Build + invoke the one-shot seeder Lambda.
#
# The seeder loads schema + data from fixtures/seed.sql via pg8000.
# Because Lambda is in the same VPC + SG as RDS, it can reach the
# instance over its private endpoint. After invoke we delete the Lambda
# and the role.
# -----------------------------------------------------------------------------

SEEDER_TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

_run_seeder_apply() {
    # Build the Lambda zip.
    local _build_dir
    _build_dir="$(mktemp -d "${TMPDIR:-/tmp}/sbx-rds-seeder-XXXXXX")"
    cp "${__rds_dir}/fixtures/seeder_handler.py" "${_build_dir}/lambda_function.py"

    # Vendor pg8000. We use --target= without --platform so the wheel
    # picked is the pure-Python one (pg8000 is pure Python so a single
    # universal wheel works). --quiet avoids drowning the run log.
    if ! python3 -m pip install --quiet --target "$_build_dir" pg8000; then
        sbx_status error "seeder_lambda_build_failed: pip install pg8000 failed"
        rm -rf "$_build_dir"
        return 1
    fi

    local _zip_path
    _zip_path="$(mktemp -t "sbx-rds-seeder-XXXXXX.zip")"
    rm -f "$_zip_path"
    (cd "$_build_dir" && zip -r -q "$_zip_path" . -x "*.pyc" -x "*/__pycache__/*")

    # 1. Seeder IAM role.
    local _role_arn=""
    local _role_freshly_created=0
    if aws iam get-role --role-name "$SEEDER_ROLE_NAME" >/dev/null 2>&1; then
        _role_arn="$(aws iam get-role --role-name "$SEEDER_ROLE_NAME" --query 'Role.Arn' --output text)"
    else
        local _trust_tmp
        _trust_tmp="$(mktemp -t "sbx-rds-seeder-trust-XXXXXX.json")"
        printf '%s\n' "$SEEDER_TRUST_POLICY" > "$_trust_tmp"
        sbx_status action "aws iam create-role"
        _role_arn="$(aws iam create-role \
            --role-name "$SEEDER_ROLE_NAME" \
            --assume-role-policy-document "file://${_trust_tmp}" \
            --tags "Key=sbx:seed-name-prefix,Value=${SBX_SEED_NAME_PREFIX}" \
            --query 'Role.Arn' \
            --output text)"
        rm -f "$_trust_tmp"
        _role_freshly_created=1
    fi
    aws iam attach-role-policy \
        --role-name "$SEEDER_ROLE_NAME" \
        --policy-arn "$LAMBDA_VPC_EXEC_POLICY_ARN" >/dev/null 2>&1 || true
    if [ "$_role_freshly_created" = "1" ]; then
        sbx_log "waiting 10s for IAM seeder-role propagation"
        sleep 10
    fi

    # 2. Lambda function. VPC config matches the RDS instance.
    local _subnet_csv
    _subnet_csv="$(printf '%s' "$SUBNET_IDS_JSON" | jq -r '. | join(",")')"
    local _lambda_arn=""
    if aws lambda get-function --function-name "$SEEDER_LAMBDA_NAME" --region "$SBX_REGION" >/dev/null 2>&1; then
        # Re-use existing seeder Lambda (a previous run may have failed
        # mid-way through). Update the code so the latest handler runs.
        sbx_status action "aws lambda update-function-code"
        aws lambda update-function-code \
            --region "$SBX_REGION" \
            --function-name "$SEEDER_LAMBDA_NAME" \
            --zip-file "fileb://${_zip_path}" \
            --output json >/dev/null
        _lambda_arn="$(aws lambda get-function \
            --region "$SBX_REGION" \
            --function-name "$SEEDER_LAMBDA_NAME" \
            --query 'Configuration.FunctionArn' \
            --output text)"
        # Wait for Update to land.
        aws lambda wait function-updated \
            --region "$SBX_REGION" \
            --function-name "$SEEDER_LAMBDA_NAME" >/dev/null 2>&1 || true
    else
        sbx_status action "aws lambda create-function"
        _lambda_arn="$(aws lambda create-function \
            --region "$SBX_REGION" \
            --function-name "$SEEDER_LAMBDA_NAME" \
            --runtime "python3.11" \
            --role "$_role_arn" \
            --handler "lambda_function.lambda_handler" \
            --memory-size 256 \
            --timeout 60 \
            --zip-file "fileb://${_zip_path}" \
            --vpc-config "SubnetIds=${_subnet_csv},SecurityGroupIds=${SECURITY_GROUP_ID}" \
            --tags "sbx:seed-name-prefix=${SBX_SEED_NAME_PREFIX}" \
            --query 'FunctionArn' \
            --output text)"
        aws lambda wait function-active-v2 \
            --region "$SBX_REGION" \
            --function-name "$SEEDER_LAMBDA_NAME" >/dev/null 2>&1 || true
    fi

    # Persist the seeder ARN transiently (will be nulled after invoke).
    sbx_state_set_service rds "$(jq -n \
        --arg arn "$_lambda_arn" \
        '{resources:{seeder_lambda_arn:$arn}}')"

    # 3. Build the invoke payload from the fixture SQL.
    local _payload_tmp
    _payload_tmp="$(mktemp -t "sbx-rds-seeder-payload-XXXXXX.json")"
    jq -n \
        --arg host "$DB_ENDPOINT" \
        --argjson port "$DB_PORT" \
        --arg dbname "$DB_NAME" \
        --arg user "$DB_USERNAME" \
        --arg password "$MASTER_PASSWORD" \
        --rawfile sql "${__rds_dir}/fixtures/seed.sql" \
        '{host:$host, port:$port, dbname:$dbname, user:$user, password:$password, sql:$sql}' \
        > "$_payload_tmp"

    # 4. Invoke synchronously (RequestResponse). Use the tempfile pattern
    # from bug fix 1b — `--cli-input-json file://...` is more reliable
    # than `/dev/stdin` across CLI versions.
    local _resp_tmp
    _resp_tmp="$(mktemp -t "sbx-rds-seeder-resp-XXXXXX.json")"
    sbx_status action "aws lambda invoke (seeder)"
    local _invoke_rc=0
    aws lambda invoke \
        --region "$SBX_REGION" \
        --function-name "$SEEDER_LAMBDA_NAME" \
        --invocation-type RequestResponse \
        --cli-binary-format raw-in-base64-out \
        --payload "file://${_payload_tmp}" \
        "$_resp_tmp" \
        >/dev/null || _invoke_rc=$?

    if [ "$_invoke_rc" -ne 0 ]; then
        sbx_status error "seeder_invoke_failed rc=${_invoke_rc}"
        sbx_log "seeder response:"
        cat "$_resp_tmp" || true
        rm -f "$_payload_tmp" "$_resp_tmp" "$_zip_path"
        rm -rf "$_build_dir"
        return 1
    fi
    # Check the function-error envelope: a status code in the response
    # body other than 200 means the handler raised.
    local _executed
    _executed="$(jq -r '.executed_statements // empty' "$_resp_tmp" 2>/dev/null || echo "")"
    if [ -z "$_executed" ]; then
        sbx_status error "seeder_invoke_no_result: response did not contain executed_statements"
        sbx_log "seeder response:"
        cat "$_resp_tmp" || true
        rm -f "$_payload_tmp" "$_resp_tmp" "$_zip_path"
        rm -rf "$_build_dir"
        return 1
    fi
    sbx_log "seeder executed ${_executed} SQL statements against ${DB_ENDPOINT}"
    rm -f "$_payload_tmp" "$_resp_tmp" "$_zip_path"
    rm -rf "$_build_dir"

    # 5. Delete the seeder Lambda + role.
    sbx_status action "aws lambda delete-function (seeder cleanup)"
    aws lambda delete-function \
        --region "$SBX_REGION" \
        --function-name "$SEEDER_LAMBDA_NAME" >/dev/null 2>&1 || true
    aws iam detach-role-policy \
        --role-name "$SEEDER_ROLE_NAME" \
        --policy-arn "$LAMBDA_VPC_EXEC_POLICY_ARN" >/dev/null 2>&1 || true
    aws iam delete-role \
        --role-name "$SEEDER_ROLE_NAME" >/dev/null 2>&1 || true

    return 0
}

if sbx_apply_mode; then
    if ! _run_seeder_apply; then
        sbx_status error "rds_seed_failed instance=${DB_INSTANCE_ID}"
        sbx_state_set_service rds '{"status":"failed"}'
        exit 1
    fi
else
    # Dry-run: render the would-be commands so the audit log captures
    # the planned seeder lifecycle. We use sbx_aws so each line gets the
    # `DRY-RUN: ` prefix.
    sbx_aws iam create-role \
        --role-name "$SEEDER_ROLE_NAME" \
        --assume-role-policy-document "file:///tmp/PLACEHOLDER-trust.json"
    sbx_aws iam attach-role-policy \
        --role-name "$SEEDER_ROLE_NAME" \
        --policy-arn "$LAMBDA_VPC_EXEC_POLICY_ARN"
    sbx_aws lambda create-function \
        --region "$SBX_REGION" \
        --function-name "$SEEDER_LAMBDA_NAME" \
        --runtime "python3.11" \
        --role "arn:aws:iam::${SBX_SOURCE_ACCOUNT_ID}:role/${SEEDER_ROLE_NAME}" \
        --handler "lambda_function.lambda_handler" \
        --memory-size 256 \
        --timeout 60 \
        --zip-file "fileb://PLACEHOLDER.zip" \
        --vpc-config "SubnetIds=...,SecurityGroupIds=${SECURITY_GROUP_ID}"
    sbx_aws lambda invoke \
        --region "$SBX_REGION" \
        --function-name "$SEEDER_LAMBDA_NAME" \
        --invocation-type RequestResponse \
        --payload "file:///tmp/PLACEHOLDER-payload.json" \
        "/tmp/PLACEHOLDER-resp.json"
    sbx_aws lambda delete-function \
        --region "$SBX_REGION" \
        --function-name "$SEEDER_LAMBDA_NAME"
    sbx_aws iam delete-role \
        --role-name "$SEEDER_ROLE_NAME"
fi

# -----------------------------------------------------------------------------
# Final state write — provisioned, with seeder_lambda_arn nulled to
# document that the disposable resource is gone (apply mode only).
# -----------------------------------------------------------------------------
if sbx_apply_mode; then
    sbx_state_set_service rds "$(jq -n \
        --arg id "$DB_INSTANCE_ID" \
        --arg endpoint "$DB_ENDPOINT" \
        --argjson port "$DB_PORT" \
        --arg db "$DB_NAME" \
        --arg user "$DB_USERNAME" \
        --arg pw "$MASTER_PASSWORD" \
        --arg sng "$SUBNET_GROUP_NAME" \
        --arg sg "$SECURITY_GROUP_ID" \
        --arg sgname "$SECURITY_GROUP_NAME" \
        --arg engine "$DB_ENGINE" \
        --arg ver "$ENGINE_VERSION" \
        '{
            status: "provisioned",
            resources: {
                instance_id: $id,
                endpoint: $endpoint,
                port: $port,
                db_name: $db,
                master_username: $user,
                master_password: $pw,
                subnet_group_name: $sng,
                security_group_id: $sg,
                security_group_name: $sgname,
                engine: $engine,
                engine_version: $ver,
                seeder_lambda_arn: null
            }
        }')"
    sbx_status ok "rds_provisioned instance=${DB_INSTANCE_ID} endpoint=${DB_ENDPOINT}"
else
    sbx_log "dry-run: skipping state write (would record .services.rds.status=provisioned, instance=${DB_INSTANCE_ID})"
    sbx_status ok "rds_dry_run instance=${DB_INSTANCE_ID}"
fi
