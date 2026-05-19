#!/usr/bin/env bash
#
# seed/glue/create.sh — AWS Glue Seed_Service_Module (FOUR-PHASE).
#
# Source-account Glue surface. Dispatched FOUR times from
# `seed/provision.sh` so that Glue jobs can run against real data BEFORE
# the crawler is created. The four phases are:
#
#   --phase=foundation  Runs FIRST (before rds, before msk).
#       - S3 data bucket + sample CSV uploads
#       - IAM roles (crawler-role + job-role)
#       - Glue databases (raw + curated)
#       - JDBC connection (placeholder URL — RDS not yet up)
#       - NETWORK connection
#       - glueetl + pythonshell Glue jobs CREATED + RUN against the
#         sample CSVs, producing s3://<bucket>/curated/orders_parquet/
#         and s3://<bucket>/curated/customers_csv_parquet/
#       Persists status=foundation_done.
#
#   --phase=rds-bridge  Runs AFTER seed/rds/create.sh has provisioned the
#       seed Postgres instance.
#       - Re-creates the JDBC connection with the real RDS endpoint +
#         master password (replacing the placeholder URL from foundation)
#       - Registers `<prefix>-rds-to-parquet` Glue job
#       - RUNS that job synchronously, populating
#         s3://<bucket>/curated/customers/ and s3://<bucket>/curated/products/
#       Persists status=rds_bridge_done.
#
#   --phase=crawler  Runs LATE in the sequence, AFTER firehose has begun
#       writing raw events and after every curated zone has data.
#       - Creates the Glue crawler against `<prefix>-db-curated`
#       - Crawler S3 targets: curated/orders_parquet, curated/customers_csv_parquet,
#         curated/customers, curated/products
#       - Runs the crawler, polls until READY
#       - Captures discovered table names for state
#       - Lake Formation hardening: revokes the default
#         `IAMAllowedPrincipals` grant on every seed-created database
#         and table. Without this revoke the assets show up in SMUS
#         as "not LF-managed" and the portal flags them
#         "Asset cannot be queried with tools" even when S3 is
#         registered. The migration tool's
#         `_lakeformation_bootstrap` then grants DESCRIBE/SELECT to
#         the project user role and manage-access role on top of the
#         now-LF-enforced surface.
#       Persists status=crawler_done.
#
#   --phase=kafka  Runs LAST.
#       - KAFKA Glue connection bound to MSK's bootstrap broker string
#       Persists status=provisioned (terminal state).
#
# The two raw catalog tables (`<prefix>_kinesis_events_parquet`,
# `<prefix>_msk_events_parquet`) that Firehose's
# DataFormatConversionConfiguration needs are NO LONGER created here —
# they are pre-registered by `seed/firehose/create.sh` (it owns them
# now). The two curated catalog tables are no longer pre-registered
# either: the crawler in --phase=crawler discovers them after the jobs
# have written real Parquet.
#
# Backwards-compat aliases:
#   --phase=1   maps to --phase=foundation (with a STATUS warning)
#   --phase=2   maps to --phase=kafka      (with a STATUS warning)
#
# Resource-name catalogue (Requirement 20.29 — every name begins with
# `${SBX_SEED_NAME_PREFIX}-`):
#
#       <prefix>-glue-data-<account>-<region>  S3 sample-data bucket
#       <prefix>-db-raw                        Glue database (raw zone)
#       <prefix>-db-curated                    Glue database (curated zone)
#       <prefix>-crawler                       Glue crawler (phase=crawler)
#       <prefix>-jdbc-conn                     Glue JDBC connection
#       <prefix>-network-conn                  Glue NETWORK connection
#       <prefix>-kafka-conn                    Glue KAFKA connection (phase=kafka)
#       <prefix>-etl-job                       Glue job (glueetl)
#       <prefix>-pythonshell-job               Glue job (pythonshell)
#       <prefix>-rds-to-parquet                Glue job (rds → parquet, phase=rds-bridge)
#
# Idempotency contract (Requirement 20.13):
# Every `aws glue create-*` (and the bucket / RDS / S3 upload calls) is
# preceded by a matching `aws glue get-*` / `head-bucket` / `describe-*`
# lookup. When the lookup succeeds in apply mode the create is skipped;
# in dry-run both lines render as `DRY-RUN: aws ...` so the audit log
# captures the would-be sequence in full.
#
# State persistence (Requirement 20.12) gated behind sbx_apply_mode
# (bug fix 1a — dry-run never mutates seed.state.json).
#
# Same-account contract (Requirement 20.28):
# `sbx_assert_same_account` runs immediately after `sbx_init`.
#
# Validates Requirements: 20.7, 20.13, 20.15, 20.16, 20.29, 20.30, 20.32.
#

set -euo pipefail

# -----------------------------------------------------------------------------
# Resolve own location and source the shared seed helper library.
# -----------------------------------------------------------------------------
__GLUE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SBX_WORKDIR="${SBX_WORKDIR:-$(dirname "$(dirname "$__GLUE_DIR")")}"
export SBX_WORKDIR

# shellcheck source=../_lib/common.sh disable=SC1091
source "${__GLUE_DIR}/../_lib/common.sh"

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

# -----------------------------------------------------------------------------
# Phase parsing (BEFORE sbx_init).
#
# sbx_init's built-in --phase parser only accepts 1|2|all and rejects
# anything else with `STATUS: error invalid_phase`. The four-phase
# refactor uses string names (foundation, rds-bridge, crawler, kafka)
# so we MUST scrub or rewrite a string-typed --phase=… arg out of the
# argv before sbx_init sees it.
#
# Backwards-compat aliases:
#   --phase=1 → foundation (with a STATUS warning)
#   --phase=2 → kafka      (with a STATUS warning)
#
# We do this by:
#   1. Walking the argv, capturing the string-named phase into
#      GLUE_PHASE.
#   2. Rebuilding the argv WITHOUT the --phase=… token.
#   3. Letting sbx_init parse the rest.
# -----------------------------------------------------------------------------
GLUE_PHASE=""
__rebuilt_argv=()
for __arg in "$@"; do
    case "$__arg" in
        --phase=foundation|--phase=rds-bridge|--phase=crawler|--phase=kafka)
            GLUE_PHASE="${__arg#--phase=}"
            ;;
        --phase=1)
            GLUE_PHASE="foundation"
            sbx_status warning "deprecated_phase_alias --phase=1 → --phase=foundation"
            ;;
        --phase=2)
            GLUE_PHASE="kafka"
            sbx_status warning "deprecated_phase_alias --phase=2 → --phase=kafka"
            ;;
        --phase=all)
            # Direct operator invocation default; map to foundation so
            # the script still does something useful in the absence of
            # an orchestrator.
            GLUE_PHASE="foundation"
            ;;
        --phase=*)
            sbx_status error "invalid_phase ${__arg#--phase=} (expected: foundation | rds-bridge | crawler | kafka)"
            exit 64
            ;;
        *)
            __rebuilt_argv+=("$__arg")
            ;;
    esac
done
# Default phase when none was provided (direct operator run).
GLUE_PHASE="${GLUE_PHASE:-foundation}"

set -- "${__rebuilt_argv[@]+"${__rebuilt_argv[@]}"}"

sbx_init "glue" "$@"
sbx_assert_same_account

# -----------------------------------------------------------------------------
# Resource-name catalogue.
# -----------------------------------------------------------------------------
DB_RAW="${SBX_SEED_NAME_PREFIX}-db-raw"
DB_CURATED="${SBX_SEED_NAME_PREFIX}-db-curated"
CRAWLER_NAME="${SBX_SEED_NAME_PREFIX}-crawler"
JDBC_CONNECTION="${SBX_SEED_NAME_PREFIX}-jdbc-conn"
NETWORK_CONNECTION="${SBX_SEED_NAME_PREFIX}-network-conn"
KAFKA_CONNECTION="${SBX_SEED_NAME_PREFIX}-kafka-conn"
GLUEETL_JOB="${SBX_SEED_NAME_PREFIX}-etl-job"
PYTHONSHELL_JOB="${SBX_SEED_NAME_PREFIX}-pythonshell-job"
RDS_TO_PARQUET_JOB="${SBX_SEED_NAME_PREFIX}-rds-to-parquet"

GLUE_CRAWLER_ROLE_NAME="${SBX_SEED_NAME_PREFIX}-glue-crawler-role"
GLUE_JOB_ROLE_NAME="${SBX_SEED_NAME_PREFIX}-glue-job-role"
GLUE_SERVICE_MANAGED_POLICY_ARN="arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"

# Job-run polling budget. Each job is bounded at 30 polls × 30s = 15 min,
# which comfortably covers a cold Glue 4.0 driver start (~3 min) plus
# the small data the seed jobs handle.
JOB_RUN_MAX_POLLS=30
JOB_RUN_POLL_INTERVAL_S=30

# -----------------------------------------------------------------------------
# Sample-data S3 bucket name resolution. Same shape as the pre-refactor
# code — recorded value first, env override second, deterministic
# default last.
# -----------------------------------------------------------------------------
__resolve_data_bucket() {
    local _recorded
    _recorded="$(sbx_state_get '.services.glue.resources.data_bucket')"
    if [ -n "$_recorded" ]; then
        printf '%s\n' "$_recorded"
        return 0
    fi
    if [ -n "${SBX_SEED_GLUE_DATA_BUCKET:-}" ]; then
        printf '%s\n' "$SBX_SEED_GLUE_DATA_BUCKET"
        return 0
    fi
    printf '%s-glue-data-%s-%s\n' \
        "$SBX_SEED_NAME_PREFIX" \
        "$SBX_SOURCE_ACCOUNT_ID" \
        "$SBX_REGION"
}

DATA_BUCKET="$(__resolve_data_bucket)"

# =============================================================================
# Shared helpers (used across phases)
# =============================================================================

# Output channel for IAM role ARNs — set by phase_foundation_iam_roles
# and read by every job/crawler create.
__GLUE_OUT_CRAWLER_ROLE_ARN=""
__GLUE_OUT_JOB_ROLE_ARN=""

GLUE_TRUST_POLICY_JSON='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"glue.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

_glue_role_exists() {
    local _name="$1"
    if ! sbx_apply_mode; then
        return 1
    fi
    aws iam get-role --role-name "$_name" >/dev/null 2>&1
}

_ensure_glue_role() {
    local _role_name="$1"
    local _out_var="$2"
    local _arn=""
    local _freshly_created=0

    if _glue_role_exists "$_role_name"; then
        sbx_status ok "iam role ${_role_name} already exists; skipping create-role"
        _arn="$(aws iam get-role \
            --role-name "$_role_name" \
            --query 'Role.Arn' \
            --output text)"
    else
        local _trust_tmp
        _trust_tmp="$(mktemp -t "sbx-${_role_name}-trust-XXXXXX.json")"
        printf '%s\n' "$GLUE_TRUST_POLICY_JSON" > "$_trust_tmp"

        if sbx_apply_mode; then
            sbx_status action "aws iam create-role"
            _arn="$(aws iam create-role \
                --role-name "$_role_name" \
                --assume-role-policy-document "file://${_trust_tmp}" \
                --tags "Key=sbx:seed-name-prefix,Value=${SBX_SEED_NAME_PREFIX}" \
                --query 'Role.Arn' \
                --output text)"
            if [ -z "$_arn" ] || [ "$_arn" = "None" ]; then
                rm -f "$_trust_tmp"
                sbx_status error "create-role returned no ARN for ${_role_name}"
                exit 1
            fi
            _freshly_created=1
        else
            sbx_aws iam create-role \
                --role-name "$_role_name" \
                --assume-role-policy-document "file://${_trust_tmp}" \
                --tags "Key=sbx:seed-name-prefix,Value=${SBX_SEED_NAME_PREFIX}"
            _arn="arn:aws:iam::${SBX_SOURCE_ACCOUNT_ID}:role/${_role_name}"
        fi
        rm -f "$_trust_tmp"
    fi

    sbx_aws iam attach-role-policy \
        --role-name "$_role_name" \
        --policy-arn "$GLUE_SERVICE_MANAGED_POLICY_ARN"

    local _inline_tmp
    _inline_tmp="$(mktemp -t "sbx-${_role_name}-s3-XXXXXX.json")"
    jq -n \
        --arg bucket_arn "arn:aws:s3:::${DATA_BUCKET}" \
        --arg bucket_keys_arn "arn:aws:s3:::${DATA_BUCKET}/*" \
        '{
            Version: "2012-10-17",
            Statement: [
                {
                    Effect: "Allow",
                    Action: ["s3:GetObject", "s3:PutObject", "s3:ListBucket"],
                    Resource: [$bucket_arn, $bucket_keys_arn]
                }
            ]
        }' > "$_inline_tmp"

    sbx_aws iam put-role-policy \
        --role-name "$_role_name" \
        --policy-name "s3-data-access" \
        --policy-document "file://${_inline_tmp}"

    rm -f "$_inline_tmp"

    if [ "$_freshly_created" = "1" ]; then
        if sbx_apply_mode; then
            sbx_log "waiting 10s for IAM role propagation (${_role_name})"
            sleep 10
        else
            sbx_log "would wait 10s for IAM role propagation (${_role_name})"
        fi
    fi

    eval "${_out_var}=\"\${_arn}\""
}

# -----------------------------------------------------------------------------
# _hydrate_role_arns
#
# Populate __GLUE_OUT_{CRAWLER,JOB}_ROLE_ARN from previously-recorded
# state when this script is invoked for a non-foundation phase
# (rds-bridge, crawler, kafka). Without this, those phases would
# fall back to deterministic ARNs that are technically the same string
# but skip the apply-mode `aws iam get-role` short-circuit; populating
# from state keeps the audit log consistent.
# -----------------------------------------------------------------------------
_hydrate_role_arns() {
    local _crawler_recorded _job_recorded
    _crawler_recorded="$(sbx_state_get '.services.glue.resources.iam_roles.crawler_role_arn')"
    _job_recorded="$(sbx_state_get '.services.glue.resources.iam_roles.job_role_arn')"

    if [ -n "$_crawler_recorded" ]; then
        __GLUE_OUT_CRAWLER_ROLE_ARN="$_crawler_recorded"
    else
        __GLUE_OUT_CRAWLER_ROLE_ARN="arn:aws:iam::${SBX_SOURCE_ACCOUNT_ID}:role/${GLUE_CRAWLER_ROLE_NAME}"
    fi
    if [ -n "$_job_recorded" ]; then
        __GLUE_OUT_JOB_ROLE_ARN="$_job_recorded"
    else
        __GLUE_OUT_JOB_ROLE_ARN="arn:aws:iam::${SBX_SOURCE_ACCOUNT_ID}:role/${GLUE_JOB_ROLE_NAME}"
    fi
}

# -----------------------------------------------------------------------------
# _wait_for_job_run <job-name> <run-id>
#
# Apply-mode: poll `aws glue get-job-run` every $JOB_RUN_POLL_INTERVAL_S
# seconds, up to $JOB_RUN_MAX_POLLS times, until JobRunState is one of
# SUCCEEDED, FAILED, STOPPED, TIMEOUT. On non-success the function logs
# the ErrorMessage from the response and returns 1 (the caller decides
# whether to exit). On success returns 0.
#
# Dry-run: this helper is never called; the caller renders the would-be
# get-job-run command via sbx_aws.
# -----------------------------------------------------------------------------
_wait_for_job_run() {
    local _job_name="$1"
    local _run_id="$2"
    local _i=0
    local _state="UNKNOWN"
    local _err=""

    while [ "$_i" -lt "$JOB_RUN_MAX_POLLS" ]; do
        local _resp
        _resp="$(aws glue get-job-run \
            --job-name "$_job_name" \
            --run-id "$_run_id" \
            --region "$SBX_REGION" \
            --output json 2>/dev/null || echo '{}')"
        _state="$(printf '%s' "$_resp" | jq -r '.JobRun.JobRunState // "UNKNOWN"')"
        case "$_state" in
            SUCCEEDED)
                sbx_log "job ${_job_name} run ${_run_id} SUCCEEDED"
                return 0
                ;;
            FAILED|STOPPED|TIMEOUT)
                _err="$(printf '%s' "$_resp" | jq -r '.JobRun.ErrorMessage // "(no error message)"')"
                local _state_lc
                _state_lc="$(printf '%s' "$_state" | tr '[:upper:]' '[:lower:]')"
                sbx_status error "job_run_${_state_lc} ${_job_name} run=${_run_id} message=${_err}"
                return 1
                ;;
        esac
        _i=$((_i + 1))
        sleep "$JOB_RUN_POLL_INTERVAL_S"
    done

    sbx_status error "job_run_timed_out ${_job_name} run=${_run_id} last_state=${_state} budget=$((JOB_RUN_MAX_POLLS * JOB_RUN_POLL_INTERVAL_S))s"
    return 1
}

# -----------------------------------------------------------------------------
# _run_glue_job_sync <job-name> <args-json>
#
# Idempotently start a Glue job and wait for it to reach SUCCEEDED. The
# args-json is a JSON object passed verbatim to start-job-run's
# --arguments. Apply-mode polls; dry-run prints the would-be commands.
# Returns the get-job-run exit code (0 on success, 1 on failure).
# -----------------------------------------------------------------------------
_run_glue_job_sync() {
    local _job_name="$1"
    local _args_json="$2"

    if ! sbx_apply_mode; then
        sbx_aws glue start-job-run \
            --job-name "$_job_name" \
            --region "$SBX_REGION" \
            --arguments "$_args_json"
        sbx_aws glue get-job-run \
            --job-name "$_job_name" \
            --run-id "DRY-RUN-RUN-ID" \
            --region "$SBX_REGION" || true
        return 0
    fi

    sbx_status action "aws glue start-job-run ${_job_name}"
    local _run_id
    _run_id="$(aws glue start-job-run \
        --job-name "$_job_name" \
        --region "$SBX_REGION" \
        --arguments "$_args_json" \
        --query 'JobRunId' \
        --output text 2>/dev/null || echo "")"
    if [ -z "$_run_id" ] || [ "$_run_id" = "None" ]; then
        sbx_status error "start-job-run failed for ${_job_name}"
        return 1
    fi
    sbx_log "job ${_job_name} run-id=${_run_id} started; polling for completion"

    if ! _wait_for_job_run "$_job_name" "$_run_id"; then
        return 1
    fi
    return 0
}

# =============================================================================
# Phase: foundation
# =============================================================================

phase_foundation_data_bucket() {
    sbx_status action "create-data-bucket ${DATA_BUCKET}"

    local _exists=0
    if sbx_apply_mode; then
        if sbx_aws s3api head-bucket --bucket "$DATA_BUCKET" --region "$SBX_REGION" >/dev/null 2>&1; then
            _exists=1
        fi
    else
        sbx_aws s3api head-bucket --bucket "$DATA_BUCKET" --region "$SBX_REGION" || true
    fi

    if [ "$_exists" -eq 1 ]; then
        sbx_log "data bucket ${DATA_BUCKET} already exists; skipping create-bucket"
    else
        if [ "$SBX_REGION" = "us-east-1" ]; then
            sbx_aws s3api create-bucket \
                --bucket "$DATA_BUCKET" \
                --region "$SBX_REGION"
        else
            sbx_aws s3api create-bucket \
                --bucket "$DATA_BUCKET" \
                --region "$SBX_REGION" \
                --create-bucket-configuration "LocationConstraint=${SBX_REGION}"
        fi
    fi

    local _csv_orders="${__GLUE_DIR}/fixtures/orders.csv"
    if [ -f "$_csv_orders" ]; then
        sbx_aws s3 cp "$_csv_orders" "s3://${DATA_BUCKET}/orders/orders.csv" --region "$SBX_REGION"
    else
        sbx_log "fixture missing: ${_csv_orders}; skipping orders CSV upload"
    fi

    local _csv_customers="${__GLUE_DIR}/fixtures/customers.csv"
    if [ -f "$_csv_customers" ]; then
        sbx_aws s3 cp "$_csv_customers" "s3://${DATA_BUCKET}/customers/customers.csv" --region "$SBX_REGION"
    else
        sbx_log "fixture missing: ${_csv_customers}; skipping customers CSV upload"
    fi
}

phase_foundation_iam_roles() {
    sbx_status action "ensure-glue-iam-roles ${GLUE_CRAWLER_ROLE_NAME} ${GLUE_JOB_ROLE_NAME}"
    _ensure_glue_role "$GLUE_CRAWLER_ROLE_NAME" __GLUE_OUT_CRAWLER_ROLE_ARN
    _ensure_glue_role "$GLUE_JOB_ROLE_NAME" __GLUE_OUT_JOB_ROLE_ARN
}

phase_foundation_databases() {
    local _db
    for _db in "$DB_RAW" "$DB_CURATED"; do
        sbx_status action "create-database ${_db}"

        local _exists=0
        if sbx_apply_mode; then
            if sbx_aws glue get-database --name "$_db" --region "$SBX_REGION" >/dev/null 2>&1; then
                _exists=1
            fi
        else
            sbx_aws glue get-database --name "$_db" --region "$SBX_REGION" || true
        fi

        if [ "$_exists" -eq 1 ]; then
            sbx_log "glue database ${_db} already exists; skipping create-database"
        else
            sbx_aws glue create-database \
                --region "$SBX_REGION" \
                --database-input "Name=${_db},Description=Seed database for ${SBX_SEED_NAME_PREFIX} (zone=$([ "$_db" = "$DB_RAW" ] && echo raw || echo curated))"
        fi
    done
}

# JDBC connection with placeholder URL. The real RDS endpoint is wired
# in --phase=rds-bridge after rds/create.sh runs.
phase_foundation_jdbc_connection() {
    sbx_status action "create-jdbc-connection ${JDBC_CONNECTION}"

    local _exists=0
    if sbx_apply_mode; then
        if sbx_aws glue get-connection \
                --name "$JDBC_CONNECTION" \
                --region "$SBX_REGION" >/dev/null 2>&1; then
            _exists=1
        fi
    else
        sbx_aws glue get-connection \
            --name "$JDBC_CONNECTION" \
            --region "$SBX_REGION" || true
    fi

    if [ "$_exists" -eq 1 ]; then
        sbx_log "glue connection ${JDBC_CONNECTION} already exists; skipping create-connection (rds-bridge phase will recreate)"
        return 0
    fi

    local _placeholder_url="${SBX_SEED_JDBC_URL:-jdbc:postgresql://placeholder.example.com:5432/seeddb}"
    local _placeholder_pw="ChangeMe-${SBX_SEED_NAME_PREFIX}-1!"

    local _req_tmp
    _req_tmp="$(mktemp -t "sbx-glue-jdbc-XXXXXX.json")"
    jq -n \
        --arg name "$JDBC_CONNECTION" \
        --arg url "$_placeholder_url" \
        --arg user "seedadmin" \
        --arg pw "$_placeholder_pw" \
        '{
            ConnectionInput: {
                Name: $name,
                ConnectionType: "JDBC",
                ConnectionProperties: {
                    JDBC_CONNECTION_URL: $url,
                    USERNAME: $user,
                    PASSWORD: $pw,
                    JDBC_ENFORCE_SSL: "true",
                    JDBC_DRIVER_CLASS_NAME: "org.postgresql.Driver"
                }
            }
        }' > "$_req_tmp"

    sbx_aws glue create-connection \
        --region "$SBX_REGION" \
        --cli-input-json "file://${_req_tmp}"

    rm -f "$_req_tmp"
}

phase_foundation_network_connection() {
    sbx_status action "create-network-connection ${NETWORK_CONNECTION}"

    local _exists=0
    if sbx_apply_mode; then
        if sbx_aws glue get-connection \
                --name "$NETWORK_CONNECTION" \
                --region "$SBX_REGION" >/dev/null 2>&1; then
            _exists=1
        fi
    else
        sbx_aws glue get-connection \
            --name "$NETWORK_CONNECTION" \
            --region "$SBX_REGION" || true
    fi

    if [ "$_exists" -eq 1 ]; then
        sbx_log "glue connection ${NETWORK_CONNECTION} already exists; skipping create-connection"
        return 0
    fi

    local _cfg_subnet=""
    local _cfg_sg=""
    local _cfg_az=""
    if [ -f "$__SEED_CFG" ] && command -v jq >/dev/null 2>&1; then
        _cfg_subnet="$(jq -r '.glue.network_subnet_id // empty' "$__SEED_CFG" 2>/dev/null || true)"
        _cfg_sg="$(jq -r '.glue.network_security_group_id // empty' "$__SEED_CFG" 2>/dev/null || true)"
        _cfg_az="$(jq -r '.glue.network_availability_zone // empty' "$__SEED_CFG" 2>/dev/null || true)"
    fi
    local _subnet="${SBX_SEED_NETWORK_SUBNET_ID:-${_cfg_subnet:-subnet-placeholder}}"
    local _sg="${SBX_SEED_NETWORK_SECURITY_GROUP_ID:-${_cfg_sg:-sg-placeholder}}"
    local _az="${SBX_SEED_NETWORK_AZ:-${_cfg_az:-${SBX_REGION}a}}"

    sbx_aws glue create-connection \
        --region "$SBX_REGION" \
        --connection-input "{\"Name\":\"${NETWORK_CONNECTION}\",\"ConnectionType\":\"NETWORK\",\"ConnectionProperties\":{},\"PhysicalConnectionRequirements\":{\"SubnetId\":\"${_subnet}\",\"SecurityGroupIdList\":[\"${_sg}\"],\"AvailabilityZone\":\"${_az}\"}}"
}

# -----------------------------------------------------------------------------
# phase_foundation_s3_endpoint
#
# Glue jobs running inside the seed VPC need a path to S3 (for the
# script bucket, the data bucket, and the Glue service log buckets).
# A subnet without a NAT gateway must therefore have an S3 Gateway VPC
# Endpoint attached to its route table — otherwise Glue refuses to
# launch the job with:
#
#   VPC S3 endpoint validation failed for SubnetId: <subnet>. Reason:
#   Could not find S3 endpoint or NAT gateway for subnetId: <subnet>
#
# This phase is idempotent:
#   1. Resolve the VPC ID from the configured glue.network_subnet_id.
#   2. Check whether ANY S3 gateway endpoint already exists in that VPC.
#   3. If yes, log + return.
#   4. If no, find every route table in the VPC and create one S3
#      gateway endpoint attached to all of them.
# -----------------------------------------------------------------------------
phase_foundation_s3_endpoint() {
    sbx_status action "ensure-s3-vpc-endpoint"

    local _cfg_subnet=""
    if [ -f "$__SEED_CFG" ] && command -v jq >/dev/null 2>&1; then
        _cfg_subnet="$(jq -r '.glue.network_subnet_id // empty' "$__SEED_CFG" 2>/dev/null || true)"
    fi
    local _subnet="${SBX_SEED_NETWORK_SUBNET_ID:-${_cfg_subnet:-}}"
    if [ -z "$_subnet" ] || [ "$_subnet" = "subnet-placeholder" ]; then
        sbx_log "no real network subnet configured; skipping S3 VPC endpoint check"
        return 0
    fi

    if ! sbx_apply_mode; then
        sbx_aws ec2 describe-subnets --subnet-ids "$_subnet" --region "$SBX_REGION" || true
        sbx_aws ec2 describe-vpc-endpoints \
            --filters "Name=vpc-id,Values=DRY-RUN-VPC" "Name=service-name,Values=com.amazonaws.${SBX_REGION}.s3" \
            --region "$SBX_REGION" || true
        sbx_aws ec2 create-vpc-endpoint \
            --vpc-id "DRY-RUN-VPC" \
            --service-name "com.amazonaws.${SBX_REGION}.s3" \
            --vpc-endpoint-type Gateway \
            --region "$SBX_REGION" || true
        return 0
    fi

    local _vpc_id
    _vpc_id="$(aws ec2 describe-subnets \
        --subnet-ids "$_subnet" \
        --region "$SBX_REGION" \
        --query 'Subnets[0].VpcId' \
        --output text 2>/dev/null || echo "")"
    if [ -z "$_vpc_id" ] || [ "$_vpc_id" = "None" ]; then
        sbx_status error "could not resolve VPC for subnet ${_subnet}"
        exit 1
    fi
    sbx_log "resolved VPC for ${_subnet}: ${_vpc_id}"

    local _service_name="com.amazonaws.${SBX_REGION}.s3"
    local _existing
    _existing="$(aws ec2 describe-vpc-endpoints \
        --filters "Name=vpc-id,Values=${_vpc_id}" \
                  "Name=service-name,Values=${_service_name}" \
                  "Name=vpc-endpoint-type,Values=Gateway" \
        --region "$SBX_REGION" \
        --query 'VpcEndpoints[0].VpcEndpointId' \
        --output text 2>/dev/null || echo "None")"
    if [ -n "$_existing" ] && [ "$_existing" != "None" ]; then
        sbx_log "S3 gateway endpoint ${_existing} already attached to ${_vpc_id}; skipping create"
        return 0
    fi

    local _rt_ids
    _rt_ids="$(aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=${_vpc_id}" \
        --region "$SBX_REGION" \
        --query 'RouteTables[].RouteTableId' \
        --output text 2>/dev/null || echo "")"
    if [ -z "$_rt_ids" ]; then
        sbx_status error "no route tables found in VPC ${_vpc_id}"
        exit 1
    fi

    sbx_log "creating S3 gateway endpoint for ${_vpc_id} attached to RTs: ${_rt_ids}"
    local _rt_array=()
    local _rt
    for _rt in $_rt_ids; do
        [ -n "$_rt" ] && _rt_array+=("$_rt")
    done
    sbx_aws ec2 create-vpc-endpoint \
        --vpc-id "$_vpc_id" \
        --service-name "$_service_name" \
        --vpc-endpoint-type Gateway \
        --route-table-ids "${_rt_array[@]}" \
        --region "$SBX_REGION" >/dev/null
}

phase_foundation_glueetl_job() {
    sbx_status action "create-glueetl-job ${GLUEETL_JOB}"

    local _exists=0
    if sbx_apply_mode; then
        if sbx_aws glue get-job \
                --job-name "$GLUEETL_JOB" \
                --region "$SBX_REGION" >/dev/null 2>&1; then
            _exists=1
        fi
    else
        sbx_aws glue get-job \
            --job-name "$GLUEETL_JOB" \
            --region "$SBX_REGION" || true
    fi

    local _script_loc="s3://${DATA_BUCKET}/scripts/${GLUEETL_JOB}.py"
    local _script_local="${__GLUE_DIR}/fixtures/${GLUEETL_JOB}.py"
    if [ ! -f "$_script_local" ]; then
        sbx_status error "missing_glueetl_script ${_script_local}"
        exit 1
    fi
    sbx_aws s3 cp "$_script_local" "$_script_loc" --region "$SBX_REGION"

    if [ "$_exists" -eq 1 ]; then
        sbx_log "glue job ${GLUEETL_JOB} already exists; skipping create-job"
        return 0
    fi

    local _role="${SBX_SEED_GLUE_JOB_ROLE_ARN:-${__GLUE_OUT_JOB_ROLE_ARN:-arn:aws:iam::${SBX_SOURCE_ACCOUNT_ID}:role/${GLUE_JOB_ROLE_NAME}}}"

    # --default-arguments for the etl job. We pass --data_bucket so the
    # job script doesn't have to derive it from the prefix. The foundation
    # etl-job is S3 -> S3 Parquet only; the JDBC connection is attached
    # to the separate rds-to-parquet job created by the rds-bridge phase
    # (which is the connection-rewrite target for Step 3).
    local _req_tmp
    _req_tmp="$(mktemp -t "sbx-glueetl-XXXXXX.json")"
    jq -n \
        --arg name "$GLUEETL_JOB" \
        --arg role "$_role" \
        --arg script "$_script_loc" \
        --arg bucket "$DATA_BUCKET" \
        '{
            Name: $name,
            Role: $role,
            Command: {
                Name: "glueetl",
                ScriptLocation: $script,
                PythonVersion: "3"
            },
            GlueVersion: "4.0",
            NumberOfWorkers: 2,
            WorkerType: "G.1X",
            MaxRetries: 1,
            DefaultArguments: {
                "--data_bucket": $bucket,
                "--enable-job-insights": "true",
                "--job-language": "python"
            }
        }' > "$_req_tmp"

    sbx_aws glue create-job \
        --region "$SBX_REGION" \
        --cli-input-json "file://${_req_tmp}"

    rm -f "$_req_tmp"
}

phase_foundation_pythonshell_job() {
    sbx_status action "create-pythonshell-job ${PYTHONSHELL_JOB}"

    local _exists=0
    if sbx_apply_mode; then
        if sbx_aws glue get-job \
                --job-name "$PYTHONSHELL_JOB" \
                --region "$SBX_REGION" >/dev/null 2>&1; then
            _exists=1
        fi
    else
        sbx_aws glue get-job \
            --job-name "$PYTHONSHELL_JOB" \
            --region "$SBX_REGION" || true
    fi

    local _script_loc="s3://${DATA_BUCKET}/scripts/${PYTHONSHELL_JOB}.py"
    local _script_local="${__GLUE_DIR}/fixtures/${PYTHONSHELL_JOB}.py"
    if [ ! -f "$_script_local" ]; then
        sbx_status error "missing_pythonshell_script ${_script_local}"
        exit 1
    fi
    sbx_aws s3 cp "$_script_local" "$_script_loc" --region "$SBX_REGION"

    if [ "$_exists" -eq 1 ]; then
        sbx_log "glue job ${PYTHONSHELL_JOB} already exists; skipping create-job"
        return 0
    fi

    local _role="${SBX_SEED_GLUE_JOB_ROLE_ARN:-${__GLUE_OUT_JOB_ROLE_ARN:-arn:aws:iam::${SBX_SOURCE_ACCOUNT_ID}:role/${GLUE_JOB_ROLE_NAME}}}"

    local _req_tmp
    _req_tmp="$(mktemp -t "sbx-pythonshell-XXXXXX.json")"
    jq -n \
        --arg name "$PYTHONSHELL_JOB" \
        --arg role "$_role" \
        --arg script "$_script_loc" \
        --arg bucket "$DATA_BUCKET" \
        '{
            Name: $name,
            Role: $role,
            Command: {
                Name: "pythonshell",
                ScriptLocation: $script,
                PythonVersion: "3.9"
            },
            GlueVersion: "3.0",
            MaxCapacity: 0.0625,
            MaxRetries: 1,
            DefaultArguments: {
                "--data_bucket": $bucket
            }
        }' > "$_req_tmp"

    sbx_aws glue create-job \
        --region "$SBX_REGION" \
        --cli-input-json "file://${_req_tmp}"

    rm -f "$_req_tmp"
}

# Run both foundation jobs serially. Serial is simpler than backgrounded
# parallel runs and the seed dataset is small enough that the wall-clock
# difference is negligible.
phase_foundation_run_jobs() {
    sbx_status action "run-foundation-jobs ${GLUEETL_JOB} ${PYTHONSHELL_JOB}"

    local _args_json
    _args_json="$(jq -n --arg b "$DATA_BUCKET" '{"--data_bucket": $b}')"

    if ! _run_glue_job_sync "$GLUEETL_JOB" "$_args_json"; then
        sbx_status error "foundation_etl_job_failed ${GLUEETL_JOB}"
        exit 1
    fi
    if ! _run_glue_job_sync "$PYTHONSHELL_JOB" "$_args_json"; then
        sbx_status error "foundation_pythonshell_job_failed ${PYTHONSHELL_JOB}"
        exit 1
    fi
}

phase_foundation_persist_state() {
    if ! sbx_apply_mode; then
        sbx_log "dry-run: skipping state write (would record .services.glue.status=foundation_done)"
        return 0
    fi

    local _payload
    _payload="$(jq -n \
        --arg phase "foundation" \
        --arg status "foundation_done" \
        --arg bucket "$DATA_BUCKET" \
        --arg dbs1 "$DB_RAW" \
        --arg dbs2 "$DB_CURATED" \
        --arg jdbc "$JDBC_CONNECTION" \
        --arg net "$NETWORK_CONNECTION" \
        --arg etl "$GLUEETL_JOB" \
        --arg ps "$PYTHONSHELL_JOB" \
        --arg crawler_role_arn "$__GLUE_OUT_CRAWLER_ROLE_ARN" \
        --arg job_role_arn "$__GLUE_OUT_JOB_ROLE_ARN" \
        '{
            phase: $phase,
            status: $status,
            resources: {
                data_bucket: $bucket,
                databases: [$dbs1, $dbs2],
                connections: [$jdbc, $net],
                jobs: [$etl, $ps],
                tables: [],
                iam_roles: {
                    crawler_role_arn: $crawler_role_arn,
                    job_role_arn: $job_role_arn
                }
            }
        }')"
    sbx_state_set_service glue "$_payload"
}

# =============================================================================
# Phase: rds-bridge
# =============================================================================

phase_rds_bridge_rewire_jdbc() {
    local _rds_endpoint _rds_password _rds_db
    _rds_endpoint="$(sbx_state_get '.services.rds.resources.endpoint')"
    _rds_password="$(sbx_state_get '.services.rds.resources.master_password')"
    _rds_db="$(sbx_state_get '.services.rds.resources.db_name')"

    if sbx_apply_mode; then
        if [ -z "$_rds_endpoint" ] || [ -z "$_rds_password" ] || [ -z "$_rds_db" ]; then
            sbx_status error "rds_dependency_missing (endpoint=${_rds_endpoint:-empty} db_name=${_rds_db:-empty} master_password=$([ -z "$_rds_password" ] && echo empty || echo present)); run seed/rds/create.sh --apply before glue --phase=rds-bridge"
            exit 65
        fi
    else
        # Dry-run placeholders so the audit log is end-to-end coherent.
        : "${_rds_endpoint:=placeholder.dry-run.rds.${SBX_REGION}.amazonaws.com}"
        : "${_rds_password:=DRY-RUN-PLACEHOLDER}"
        : "${_rds_db:=seeddb}"
    fi

    local _jdbc_url="jdbc:postgresql://${_rds_endpoint}:5432/${_rds_db}"
    sbx_log "rewiring ${JDBC_CONNECTION} to RDS endpoint ${_rds_endpoint}"

    # The placeholder URL written in foundation phase MUST be deleted
    # and recreated; aws glue update-connection is not supported on the
    # ConnectionType field but works for ConnectionProperties — we
    # delete + recreate so the audit log shows a clean before/after.
    sbx_status action "delete-jdbc-connection ${JDBC_CONNECTION} (placeholder → real)"
    local _exists=0
    if sbx_apply_mode; then
        if aws glue get-connection \
                --name "$JDBC_CONNECTION" \
                --region "$SBX_REGION" >/dev/null 2>&1; then
            _exists=1
        fi
    else
        sbx_aws glue get-connection \
            --name "$JDBC_CONNECTION" \
            --region "$SBX_REGION" || true
    fi
    if [ "$_exists" -eq 1 ]; then
        sbx_aws glue delete-connection \
            --connection-name "$JDBC_CONNECTION" \
            --region "$SBX_REGION"
    else
        sbx_log "jdbc connection ${JDBC_CONNECTION} not present; will create-connection directly"
    fi

    # Resolve VPC config to attach to the rewired JDBC connection so
    # Glue workers route through the VPC and can reach the private RDS
    # endpoint. Falls back to the same config the NETWORK connection
    # uses (glue.network_*).
    local _cfg_subnet=""
    local _cfg_sg=""
    local _cfg_az=""
    if [ -f "$__SEED_CFG" ] && command -v jq >/dev/null 2>&1; then
        _cfg_subnet="$(jq -r '.glue.network_subnet_id // empty' "$__SEED_CFG" 2>/dev/null || true)"
        _cfg_sg="$(jq -r '.glue.network_security_group_id // empty' "$__SEED_CFG" 2>/dev/null || true)"
        _cfg_az="$(jq -r '.glue.network_availability_zone // empty' "$__SEED_CFG" 2>/dev/null || true)"
    fi
    local _subnet="${SBX_SEED_NETWORK_SUBNET_ID:-${_cfg_subnet:-subnet-placeholder}}"
    local _sg="${SBX_SEED_NETWORK_SECURITY_GROUP_ID:-${_cfg_sg:-sg-placeholder}}"
    local _az="${SBX_SEED_NETWORK_AZ:-${_cfg_az:-${SBX_REGION}a}}"

    local _req_tmp
    _req_tmp="$(mktemp -t "sbx-glue-jdbc-rds-XXXXXX.json")"
    jq -n \
        --arg name "$JDBC_CONNECTION" \
        --arg url "$_jdbc_url" \
        --arg user "seedadmin" \
        --arg pw "$_rds_password" \
        --arg subnet "$_subnet" \
        --arg sg "$_sg" \
        --arg az "$_az" \
        '{
            ConnectionInput: {
                Name: $name,
                ConnectionType: "JDBC",
                ConnectionProperties: {
                    JDBC_CONNECTION_URL: $url,
                    USERNAME: $user,
                    PASSWORD: $pw,
                    JDBC_ENFORCE_SSL: "false",
                    JDBC_DRIVER_CLASS_NAME: "org.postgresql.Driver"
                },
                PhysicalConnectionRequirements: {
                    SubnetId: $subnet,
                    SecurityGroupIdList: [$sg],
                    AvailabilityZone: $az
                }
            }
        }' > "$_req_tmp"

    sbx_aws glue create-connection \
        --region "$SBX_REGION" \
        --cli-input-json "file://${_req_tmp}"

    rm -f "$_req_tmp"
}

phase_rds_bridge_register_job() {
    sbx_status action "create-glueetl-job ${RDS_TO_PARQUET_JOB}"

    local _exists=0
    if sbx_apply_mode; then
        if sbx_aws glue get-job \
                --job-name "$RDS_TO_PARQUET_JOB" \
                --region "$SBX_REGION" >/dev/null 2>&1; then
            _exists=1
        fi
    else
        sbx_aws glue get-job \
            --job-name "$RDS_TO_PARQUET_JOB" \
            --region "$SBX_REGION" || true
    fi

    local _script_loc="s3://${DATA_BUCKET}/scripts/${RDS_TO_PARQUET_JOB}.py"
    local _script_local="${__GLUE_DIR}/fixtures/${RDS_TO_PARQUET_JOB}.py"
    if [ -f "$_script_local" ]; then
        sbx_aws s3 cp "$_script_local" "$_script_loc" --region "$SBX_REGION"
    else
        sbx_log "warning: rds-to-parquet script missing at ${_script_local}; create-job will reference an empty S3 key"
    fi

    if [ "$_exists" -eq 1 ]; then
        sbx_log "glue job ${RDS_TO_PARQUET_JOB} already exists; skipping create-job"
        return 0
    fi

    local _role="${SBX_SEED_GLUE_JOB_ROLE_ARN:-${__GLUE_OUT_JOB_ROLE_ARN:-arn:aws:iam::${SBX_SOURCE_ACCOUNT_ID}:role/${GLUE_JOB_ROLE_NAME}}}"

    # Catalog table names the rds-to-parquet job's default-arguments
    # reference. With the post-resequencing crawler discovering tables
    # later, these are advisory rather than required — the job's own
    # writer addresses S3 paths directly. We retain them for backwards
    # compat with the existing fixture script.
    local _glue_table_prefix="${SBX_SEED_NAME_PREFIX//-/_}"
    local _customers_tbl="${_glue_table_prefix}_customers_parquet"
    local _products_tbl="${_glue_table_prefix}_products_parquet"

    local _req_tmp
    _req_tmp="$(mktemp -t "sbx-glue-rds2parquet-XXXXXX.json")"
    jq -n \
        --arg name "$RDS_TO_PARQUET_JOB" \
        --arg role "$_role" \
        --arg script "$_script_loc" \
        --arg jdbc_conn "$JDBC_CONNECTION" \
        --arg bucket "$DATA_BUCKET" \
        --arg rds_db "seeddb" \
        --arg cat_db_curated "$DB_CURATED" \
        --arg customers_tbl "$_customers_tbl" \
        --arg products_tbl "$_products_tbl" \
        '{
            Name: $name,
            Role: $role,
            Command: {
                Name: "glueetl",
                ScriptLocation: $script,
                PythonVersion: "3"
            },
            Connections: { Connections: [$jdbc_conn] },
            GlueVersion: "4.0",
            NumberOfWorkers: 2,
            WorkerType: "G.1X",
            DefaultArguments: {
                "--glue_connection_jdbc": $jdbc_conn,
                "--data_bucket":          $bucket,
                "--rds_database":         $rds_db,
                "--catalog_db_curated":   $cat_db_curated,
                "--customers_table":      $customers_tbl,
                "--products_table":       $products_tbl,
                "--enable-job-insights":  "true",
                "--job-language":         "python"
            }
        }' > "$_req_tmp"

    sbx_aws glue create-job \
        --region "$SBX_REGION" \
        --cli-input-json "file://${_req_tmp}"

    rm -f "$_req_tmp"
}

phase_rds_bridge_run_job() {
    sbx_status action "run-rds-to-parquet ${RDS_TO_PARQUET_JOB}"

    local _glue_table_prefix="${SBX_SEED_NAME_PREFIX//-/_}"
    local _customers_tbl="${_glue_table_prefix}_customers_parquet"
    local _products_tbl="${_glue_table_prefix}_products_parquet"

    local _args_json
    _args_json="$(jq -n \
        --arg jdbc_conn "$JDBC_CONNECTION" \
        --arg bucket "$DATA_BUCKET" \
        --arg rds_db "seeddb" \
        --arg cat_db_curated "$DB_CURATED" \
        --arg customers_tbl "$_customers_tbl" \
        --arg products_tbl "$_products_tbl" \
        '{
            "--glue_connection_jdbc": $jdbc_conn,
            "--data_bucket": $bucket,
            "--rds_database": $rds_db,
            "--catalog_db_curated": $cat_db_curated,
            "--customers_table": $customers_tbl,
            "--products_table": $products_tbl
        }')"

    if ! _run_glue_job_sync "$RDS_TO_PARQUET_JOB" "$_args_json"; then
        sbx_status error "rds_to_parquet_job_failed ${RDS_TO_PARQUET_JOB}"
        exit 1
    fi
}

phase_rds_bridge_persist_state() {
    if ! sbx_apply_mode; then
        sbx_log "dry-run: skipping state write (would record .services.glue.status=rds_bridge_done; append ${RDS_TO_PARQUET_JOB} to jobs)"
        return 0
    fi

    local _payload
    _payload="$(jq -n \
        --arg phase "rds-bridge" \
        --arg status "rds_bridge_done" \
        --arg etl "$GLUEETL_JOB" \
        --arg ps "$PYTHONSHELL_JOB" \
        --arg r2p "$RDS_TO_PARQUET_JOB" \
        '{
            phase: $phase,
            status: $status,
            resources: {
                jobs: [$etl, $ps, $r2p]
            }
        }')"
    sbx_state_set_service glue "$_payload"
}

# =============================================================================
# Phase: crawler
# =============================================================================

phase_crawler_create() {
    sbx_status action "create-crawler ${CRAWLER_NAME}"

    local _exists=0
    if sbx_apply_mode; then
        if sbx_aws glue get-crawler \
                --name "$CRAWLER_NAME" \
                --region "$SBX_REGION" >/dev/null 2>&1; then
            _exists=1
        fi
    else
        sbx_aws glue get-crawler \
            --name "$CRAWLER_NAME" \
            --region "$SBX_REGION" || true
    fi

    local _role="${SBX_SEED_GLUE_CRAWLER_ROLE_ARN:-${__GLUE_OUT_CRAWLER_ROLE_ARN:-arn:aws:iam::${SBX_SOURCE_ACCOUNT_ID}:role/${GLUE_CRAWLER_ROLE_NAME}}}"

    if [ "$_exists" -eq 0 ]; then
        # Crawler targets every curated/* prefix the prior phases have
        # populated:
        #   curated/orders_parquet/      ← phase_foundation_run_jobs (etl)
        #   curated/customers_csv_parquet/ ← phase_foundation_run_jobs (pythonshell)
        #   curated/customers/           ← phase_rds_bridge_run_job (rds-to-parquet)
        #   curated/products/            ← phase_rds_bridge_run_job (rds-to-parquet)
        sbx_aws glue create-crawler \
            --region "$SBX_REGION" \
            --name "$CRAWLER_NAME" \
            --role "$_role" \
            --database-name "$DB_CURATED" \
            --targets "{\"S3Targets\":[{\"Path\":\"s3://${DATA_BUCKET}/curated/orders_parquet/\"},{\"Path\":\"s3://${DATA_BUCKET}/curated/customers_csv_parquet/\"},{\"Path\":\"s3://${DATA_BUCKET}/curated/customers/\"},{\"Path\":\"s3://${DATA_BUCKET}/curated/products/\"}]}" \
            --table-prefix "${SBX_SEED_NAME_PREFIX//-/_}_"
    else
        sbx_log "glue crawler ${CRAWLER_NAME} already exists; skipping create-crawler"
    fi
}

phase_crawler_run() {
    if sbx_apply_mode; then
        sbx_aws glue start-crawler --name "$CRAWLER_NAME" --region "$SBX_REGION" >/dev/null 2>&1 || true

        sbx_status action "wait-crawler-ready ${CRAWLER_NAME}"
        local _i=0
        local _max_polls=30
        local _state="UNKNOWN"
        while [ "$_i" -lt "$_max_polls" ]; do
            _state="$(aws glue get-crawler \
                --name "$CRAWLER_NAME" \
                --region "$SBX_REGION" \
                --query 'Crawler.State' \
                --output text 2>/dev/null || echo UNKNOWN)"
            case "$_state" in
                READY) break ;;
            esac
            _i=$((_i + 1))
            sleep 10
        done
        if [ "$_state" != "READY" ]; then
            sbx_log "warning: crawler ${CRAWLER_NAME} did not reach READY in $((_max_polls * 10))s (state=${_state}); continuing"
        fi
    else
        sbx_aws glue start-crawler --name "$CRAWLER_NAME" --region "$SBX_REGION" || true
        sbx_aws glue get-crawler --name "$CRAWLER_NAME" --region "$SBX_REGION" || true
    fi
}

# Capture discovered table names; best-effort.
__GLUE_OUT_TABLES_JSON="[]"
phase_crawler_collect_tables() {
    __GLUE_OUT_TABLES_JSON="[]"
    local _db
    for _db in "$DB_RAW" "$DB_CURATED"; do
        local _names="[]"
        if sbx_apply_mode; then
            sbx_status action "aws glue get-tables"
            local _json
            _json="$(aws glue get-tables --database-name "$_db" --region "$SBX_REGION" --output json 2>/dev/null || echo '{}')"
            _names="$(printf '%s' "$_json" | jq -c '[.TableList[]?.Name | select(. != null)]' 2>/dev/null || echo '[]')"
        else
            sbx_aws glue get-tables --database-name "$_db" --region "$SBX_REGION" || true
        fi
        __GLUE_OUT_TABLES_JSON="$(jq -n \
            --argjson acc "$__GLUE_OUT_TABLES_JSON" \
            --arg db "$_db" \
            --argjson names "$_names" \
            '$acc + ($names | map($db + "." + .))')"
    done
}

phase_crawler_persist_state() {
    if ! sbx_apply_mode; then
        sbx_log "dry-run: skipping state write (would record .services.glue.status=crawler_done with discovered tables)"
        return 0
    fi

    local _payload
    _payload="$(jq -n \
        --arg phase "crawler" \
        --arg status "crawler_done" \
        --arg crawler "$CRAWLER_NAME" \
        --argjson tables "$__GLUE_OUT_TABLES_JSON" \
        '{
            phase: $phase,
            status: $status,
            resources: {
                crawler: $crawler,
                tables: $tables
            }
        }')"
    sbx_state_set_service glue "$_payload"
}

# -----------------------------------------------------------------------------
# phase_crawler_lakeformation_hardening
#
# Revoke leftover `IAMAllowedPrincipals` (LF-IAM-default) grants on
# every seed-created Glue database and table.
#
# Why this matters:
# When Glue creates a database or table without LF enforcement, LF
# auto-grants `IAMAllowedPrincipals` on it (ALL on the table,
# ALL+DESCRIBE on the DB). That grant is what tells the SMUS portal,
# Athena, and Visual ETL "this asset is not LF-managed" — and the
# portal then surfaces the asset with the badge:
#   "Asset cannot be queried with tools. Contact your admin to
#    register the S3 location in AWS Lake Formation."
# Even when the underlying S3 path IS registered.
#
# The revoke makes every seed table LF-enforced. After this phase,
# the migration tool's `_lakeformation_bootstrap` (which grants
# DESCRIBE/SELECT to the project user role and the manage-access
# role) is what unlocks query-with-tools.
#
# Safe to run regardless of whether SMUS is set up yet — this is a
# pure cleanup of LF default grants and depends on no SMUS state.
#
# Skip rules:
#   * Skipped on dry-run.
#   * Best-effort: each revoke suppresses errors so a missing grant
#     (already revoked, or never created on a re-run) is a no-op.
# -----------------------------------------------------------------------------

phase_crawler_lakeformation_hardening() {
    if ! sbx_apply_mode; then
        sbx_log "dry-run: skipping LF hardening (would revoke IAMAllowedPrincipals on ${DB_RAW} + ${DB_CURATED} and their tables)"
        return 0
    fi

    sbx_status action "lakeformation-hardening revoke IAMAllowedPrincipals"

    # Self-promote to LF data-lake admin so revokes go through. The
    # check is idempotent — only mutates when our role is missing.
    local _caller_arn _caller_role_arn=""
    _caller_arn="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo "")"
    if [[ "$_caller_arn" =~ ^arn:aws:sts::([0-9]+):assumed-role/([^/]+)/.*$ ]]; then
        _caller_role_arn="arn:aws:iam::${BASH_REMATCH[1]}:role/${BASH_REMATCH[2]}"
    elif [[ "$_caller_arn" =~ ^arn:aws:iam::[0-9]+:(role|user)/.*$ ]]; then
        _caller_role_arn="$_caller_arn"
    fi
    if [ -n "$_caller_role_arn" ]; then
        local _admins_json
        _admins_json="$(aws lakeformation get-data-lake-settings --region "$SBX_REGION" \
            --query 'DataLakeSettings.DataLakeAdmins' --output json 2>/dev/null || echo '[]')"
        if ! printf '%s' "$_admins_json" | jq -e --arg p "$_caller_role_arn" \
                'map(.DataLakePrincipalIdentifier) | index($p)' >/dev/null 2>&1; then
            sbx_log "promoting ${_caller_role_arn} to LF data-lake admin"
            local _new_admins
            _new_admins="$(printf '%s' "$_admins_json" | jq --arg p "$_caller_role_arn" \
                '. + [{DataLakePrincipalIdentifier: $p}]')"
            aws lakeformation put-data-lake-settings --region "$SBX_REGION" \
                --data-lake-settings "{\"DataLakeAdmins\": $_new_admins}" >/dev/null 2>&1 || \
                sbx_log "warning: put-data-lake-settings failed; revokes below may fail"
        fi
    fi

    local _db
    for _db in "$DB_RAW" "$DB_CURATED"; do
        # 1. Revoke on the database itself (ALL + DESCRIBE).
        if aws lakeformation revoke-permissions --region "$SBX_REGION" \
                --principal DataLakePrincipalIdentifier=IAM_ALLOWED_PRINCIPALS \
                --resource "{\"Database\":{\"Name\":\"${_db}\"}}" \
                --permissions ALL DESCRIBE >/dev/null 2>&1; then
            sbx_log "revoked IAMAllowedPrincipals on database ${_db}"
        fi

        # 2. Revoke on every table in the database.
        local _tables
        _tables="$(aws glue get-tables --region "$SBX_REGION" --database-name "$_db" \
            --output json 2>/dev/null | jq -r '.TableList[]?.Name')"
        local _t
        while IFS= read -r _t; do
            [ -z "$_t" ] && continue
            if aws lakeformation revoke-permissions --region "$SBX_REGION" \
                    --principal DataLakePrincipalIdentifier=IAM_ALLOWED_PRINCIPALS \
                    --resource "{\"Table\":{\"DatabaseName\":\"${_db}\",\"Name\":\"${_t}\"}}" \
                    --permissions ALL >/dev/null 2>&1; then
                sbx_log "revoked IAMAllowedPrincipals on ${_db}.${_t}"
            fi
        done <<<"$_tables"
    done
}

# =============================================================================
# Phase: kafka
# =============================================================================

phase_kafka_connection() {
    local _bootstrap
    _bootstrap="$(sbx_state_get '.services.msk.resources.bootstrap_brokers')"
    if [ -z "$_bootstrap" ]; then
        if sbx_apply_mode; then
            sbx_status error "msk_not_provisioned: .services.msk.resources.bootstrap_brokers is empty in $(sbx_state_path); run seed/msk/create.sh --apply before glue --phase=kafka"
            exit 65
        fi
        _bootstrap="b-1.dry-run-placeholder.kafka.${SBX_REGION}.amazonaws.com:9098"
        sbx_log "dry-run: .services.msk.resources.bootstrap_brokers is empty; using placeholder ${_bootstrap}"
    fi

    sbx_status action "create-kafka-connection ${KAFKA_CONNECTION}"

    local _exists=0
    if sbx_apply_mode; then
        if sbx_aws glue get-connection \
                --name "$KAFKA_CONNECTION" \
                --region "$SBX_REGION" >/dev/null 2>&1; then
            _exists=1
        fi
    else
        sbx_aws glue get-connection \
            --name "$KAFKA_CONNECTION" \
            --region "$SBX_REGION" || true
    fi

    if [ "$_exists" -eq 0 ]; then
        sbx_aws glue create-connection \
            --region "$SBX_REGION" \
            --connection-input "{\"Name\":\"${KAFKA_CONNECTION}\",\"ConnectionType\":\"KAFKA\",\"ConnectionProperties\":{\"KAFKA_BOOTSTRAP_SERVERS\":\"${_bootstrap}\",\"KAFKA_SSL_ENABLED\":\"true\"}}"
    else
        sbx_log "glue connection ${KAFKA_CONNECTION} already exists; skipping create-connection"
    fi

    if ! sbx_apply_mode; then
        sbx_log "dry-run: skipping state write (would record .services.glue.status=provisioned with kafka connection)"
        return 0
    fi
    local _payload
    _payload="$(jq -n \
        --arg phase "all" \
        --arg status "provisioned" \
        --arg jdbc "$JDBC_CONNECTION" \
        --arg net "$NETWORK_CONNECTION" \
        --arg kafka "$KAFKA_CONNECTION" \
        '{
            phase: $phase,
            status: $status,
            resources: {
                connections: [$jdbc, $net, $kafka]
            }
        }')"
    sbx_state_set_service glue "$_payload"
}

# =============================================================================
# Dispatch
# =============================================================================

sbx_status started

case "$GLUE_PHASE" in
    foundation)
        sbx_log "glue phase=foundation starting (region=${SBX_REGION}, prefix=${SBX_SEED_NAME_PREFIX}, mode=$(sbx_apply_mode && echo apply || echo dry-run))"
        # Mark pending (apply mode only) so a SIGKILL leaves an honest marker.
        if sbx_apply_mode; then
            sbx_state_set_service glue '{"status":"pending","phase":"foundation"}'
        fi
        phase_foundation_data_bucket
        phase_foundation_iam_roles
        phase_foundation_databases
        phase_foundation_jdbc_connection
        phase_foundation_network_connection
        phase_foundation_s3_endpoint
        phase_foundation_glueetl_job
        phase_foundation_pythonshell_job
        phase_foundation_run_jobs
        phase_foundation_persist_state
        sbx_status ok "glue phase=foundation complete (status=foundation_done)"
        ;;
    rds-bridge)
        sbx_log "glue phase=rds-bridge starting (region=${SBX_REGION}, prefix=${SBX_SEED_NAME_PREFIX}, mode=$(sbx_apply_mode && echo apply || echo dry-run))"
        _hydrate_role_arns
        phase_rds_bridge_rewire_jdbc
        phase_rds_bridge_register_job
        phase_rds_bridge_run_job
        phase_rds_bridge_persist_state
        sbx_status ok "glue phase=rds-bridge complete (status=rds_bridge_done)"
        ;;
    crawler)
        sbx_log "glue phase=crawler starting (region=${SBX_REGION}, prefix=${SBX_SEED_NAME_PREFIX}, mode=$(sbx_apply_mode && echo apply || echo dry-run))"
        _hydrate_role_arns
        phase_crawler_create
        phase_crawler_run
        phase_crawler_collect_tables
        phase_crawler_persist_state
        phase_crawler_lakeformation_hardening
        sbx_status ok "glue phase=crawler complete (status=crawler_done)"
        ;;
    kafka)
        sbx_log "glue phase=kafka starting (region=${SBX_REGION}, prefix=${SBX_SEED_NAME_PREFIX}, mode=$(sbx_apply_mode && echo apply || echo dry-run))"
        phase_kafka_connection
        sbx_status ok "glue phase=kafka complete (status=provisioned)"
        ;;
    *)
        sbx_status error "invalid_phase ${GLUE_PHASE} (expected: foundation | rds-bridge | crawler | kafka)"
        exit 64
        ;;
esac

exit 0
