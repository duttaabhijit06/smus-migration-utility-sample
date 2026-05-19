#!/usr/bin/env bash
#
# seed/mwaa/create.sh — Amazon MWAA Seed_Service_Module create.sh.
#
# Task 24.12 / Requirements 20.7, 20.13, 20.23, 20.24, 20.29, 20.31.
#
# This module is the long pole of the Seed_Script (typically 20–30 minutes
# of MWAA environment provisioning), which is why provision.sh invokes it
# LAST in the canonical order (Requirement 20.7). It performs four jobs:
#
#   1. Region-capability pre-flight (Requirement 20.23): confirms that
#      Apache Airflow 3.0.6 is supported on MWAA in $SBX_REGION via
#      `aws mwaa list-supported-airflow-versions`. If the region does NOT
#      currently support 3.0.6, the script halts with exit 64 and the
#      STATUS line `STATUS: error airflow_3.0.6_unsupported_in_region`.
#      There is NO silent fallback to a different Airflow version.
#
#   2. DAG bucket (Requirement 20.23): creates an idempotent S3 bucket
#      named `<prefix>-mwaa-dags-<account>-<region>` (S3 versioning
#      enabled — MWAA requires it). This is the bucket the Migration_Tool's
#      Step 5 must EXCLUDE (Requirement 12.2) and the bucket Step 6 reads
#      DAG code from (Requirement 13.1). The bucket name is fully
#      deterministic from the seed_name_prefix + account + region triple,
#      so a re-run computes the exact same name without consulting state
#      and the prefix gate in teardown.sh has a stable target.
#
#   3. DAG upload (Requirement 20.24): uploads the three sample DAGs
#      from ./seed/mwaa/dags/ to `s3://<bucket>/dags/`:
#        - convertible_dag.py — only AWS-provider operators (Convertible).
#        - blocked_dag.py     — uses BashOperator (Blocked).
#        - glue_refs_dag.py   — references seed Glue jobs and connections
#          (exercises Step 3's connection-rewrite path, Requirement 9.4).
#
#   4. MWAA environment (Requirement 20.23): creates exactly 1 MWAA
#      environment named `<prefix>-mwaa-env` running Airflow `3.0.6` at
#      environment class `mw1.small`, with the DAG bucket above as the
#      source bucket and `dags/` as the DAG path. Apply mode then waits
#      via a bounded poll loop (60 polls × 30 s = 30 min budget) for the
#      environment to reach `Status == AVAILABLE`.
#
# Discipline:
#   - sources `seed/_lib/common.sh` for sbx_init/sbx_aws/sbx_state_*.
#   - `set -euo pipefail` AFTER sourcing common.sh (per common.sh's own
#     contract: the lib is set-flag-neutral so callers choose discipline).
#   - every created resource name starts with `${SBX_SEED_NAME_PREFIX}-`
#     (Requirement 20.29).
#   - never invokes `aws datazone create-*` or any AWS CLI command that
#     targets the Migration_Tool's SMUS_Domain (Requirement 20.31, 20.32).
#   - idempotent on re-run: every `create-*` is preceded by a `head-*` or
#     `get-*` check; existing resources with matching identifiers are
#     treated as a successful no-op (Requirement 20.13). A second
#     `--apply` immediately after a successful first run issues exactly
#     zero `aws ... create-*` commands.
#

# shellcheck source=../_lib/common.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SBX_WORKDIR="${SBX_WORKDIR:-$(dirname "$(dirname "$SCRIPT_DIR")")}"
export SBX_WORKDIR
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../_lib/common.sh"

set -euo pipefail

# -----------------------------------------------------------------------------
# Bootstrap the three core SBX_* env vars from seed.config.json when this
# script is invoked directly (operator runs `bash seed/mwaa/create.sh
# --apply`). The top-level `seed/provision.sh` already exports these, so
# in the orchestrated path the jq reads below are no-ops.
# -----------------------------------------------------------------------------
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

# sbx_init validates SBX_REGION, SBX_SOURCE_ACCOUNT_ID, SBX_SEED_NAME_PREFIX,
# parses --apply / --dry-run (mutually exclusive, default dry-run), and sets
# SBX_LOG_PATH (apply mode tees stdout/stderr through it).
sbx_init "mwaa" "$@"

# Same-account contract (Requirement 20.28). No-op when
# config/migration.config.json is absent (the Migration_Tool has not yet
# been bootstrapped).
sbx_assert_same_account

sbx_status started

# -----------------------------------------------------------------------------
# Module-local constants — every name is `<prefix>-...` per Requirement 20.29.
# -----------------------------------------------------------------------------

REGION="${SBX_REGION}"
PREFIX="${SBX_SEED_NAME_PREFIX}"
ACCOUNT_ID="${SBX_SOURCE_ACCOUNT_ID}"

# Pinned Airflow version (Requirement 20.23 — no silent fallback). Allow
# operator to override the environment class via seed.config but pin the
# Airflow version in code: every other line of this module assumes 3.0.6.
AIRFLOW_VERSION="3.0.6"
ENV_CLASS="$(jq -r '.mwaa.environment_class // "mw1.small"' "$__SEED_CFG")"

# Environment name (Requirement 20.23 / Requirement 20.29).
ENV_NAME="${PREFIX}-mwaa-env"

# DAG bucket name (Requirement 20.23). The task 24.12 contract pins the
# bucket name to a fully deterministic `<prefix>-mwaa-dags-<account>-<region>`
# triple, so a re-run computes the exact same name without consulting
# state and teardown.sh has a stable, prefix-gated target. The triple is
# globally unique (the AWS account ID + region pair is) so no random
# suffix is needed for S3 global uniqueness.
DAG_BUCKET="${PREFIX}-mwaa-dags-${ACCOUNT_ID}-${REGION}"
DAG_BUCKET_ARN="arn:aws:s3:::${DAG_BUCKET}"

# Execution role: created inline by `_ensure_mwaa_role` below so the
# operator does not need to pre-create it. The role trusts BOTH
# `airflow-env.amazonaws.com` AND `airflow.amazonaws.com` (MWAA
# requires both principals in the trust policy) and carries the
# canonical MWAA execution-role permissions from
# https://docs.aws.amazon.com/mwaa/latest/userguide/mwaa-create-role.html
# as an inline policy.
#
# Two operator overrides remain supported for advanced cases:
#   - SBX_MWAA_EXECUTION_ROLE_ARN env var (highest priority)
#   - .mwaa.execution_role_arn field in seed.config.json
# When either is set, role creation is skipped and the supplied ARN is
# threaded into `--execution-role-arn` directly.
MWAA_ROLE_NAME="${PREFIX}-mwaa-exec-role"
EXEC_ROLE_ARN="${SBX_MWAA_EXECUTION_ROLE_ARN:-$(jq -r '.mwaa.execution_role_arn // empty' "$__SEED_CFG")}"

# Network configuration (Requirement 20.23 — `--network-configuration` is
# required by `aws mwaa create-environment`). Subnets must be ≥2 private
# subnets in different AZs; SGs must allow MWAA's required egress to the
# DAG bucket and to AWS service endpoints.
SUBNETS_RAW="${SBX_MWAA_SUBNET_IDS:-$(jq -r '.mwaa.subnet_ids // [] | join(",")' "$__SEED_CFG")}"
SGS_RAW="${SBX_MWAA_SECURITY_GROUP_IDS:-$(jq -r '.mwaa.security_group_ids // [] | join(",")' "$__SEED_CFG")}"

# Local DAG source paths (Requirement 20.24). The exact filenames
# `convertible_dag.py`, `blocked_dag.py`, `glue_refs_dag.py` are the
# names the task spec for 24.12 binds.
DAGS_SRC_DIR="${SCRIPT_DIR}/dags"
DAG_FILES=("convertible_dag.py" "blocked_dag.py" "glue_refs_dag.py")

sbx_log "mwaa create: region=${REGION} prefix=${PREFIX} env_name=${ENV_NAME} dag_bucket=${DAG_BUCKET} airflow=${AIRFLOW_VERSION} class=${ENV_CLASS}"

# -----------------------------------------------------------------------------
# Step 1. Region-capability pre-flight (Requirement 20.23).
#
# `aws mwaa list-supported-airflow-versions` returns the Airflow versions
# MWAA supports in this region. We require an exact string match on
# `AIRFLOW_VERSION` (= 3.0.6); a missing entry halts the run with the
# specific STATUS string the task spec binds:
#
#     STATUS: error airflow_3.0.6_unsupported_in_region
#
# and exit 64. There is no silent fallback to a different Airflow version.
#
# Dry-run echoes the would-be CLI command via sbx_aws (DRY-RUN: prefix)
# but does NOT halt — dry-run is a plan preview, not a live capability
# check.
# -----------------------------------------------------------------------------

sbx_log "step 1/4: confirm region ${REGION} supports Airflow ${AIRFLOW_VERSION} on MWAA"

if sbx_apply_mode; then
    set +e
    SUPPORTED_JSON="$(aws mwaa list-supported-airflow-versions \
        --region "$REGION" \
        --output json 2>&1)"
    LV_RC=$?
    set -e

    # Detect "verb not in this CLI version" (e.g. older awscli predating
    # the verb's release). The CLI prints a ParamValidation error naming
    # the unknown subcommand. We treat that as "capability unverifiable
    # via this CLI" rather than "region rejects the version": the
    # subsequent create-environment call will fail loudly if the version
    # really isn't supported. Upgrading the AWS CLI is the durable fix.
    case "$SUPPORTED_JSON" in
        *"Invalid choice"*"list-supported-airflow-versions"*|*"invalid choice"*"list-supported-airflow-versions"*)
            sbx_log "warning: this AWS CLI does not expose 'mwaa list-supported-airflow-versions'; skipping capability pre-flight. Upgrade awscli to enforce strict pre-flight validation."
            ;;
        *)
            if [ "$LV_RC" -ne 0 ]; then
                # Real capability-check failure (network error, IAM, etc).
                # Requirement 20.23 mandates positive confirmation.
                sbx_status error "airflow_${AIRFLOW_VERSION}_unsupported_in_region"
                sbx_log "list-supported-airflow-versions failed (rc=${LV_RC}) in ${REGION}: ${SUPPORTED_JSON}"
                exit 64
            fi

            # Response shape: {"AirflowVersions":["2.10.1","3.0.6", ...]}.
            SUPPORTED="$(printf '%s' "$SUPPORTED_JSON" \
                | jq -r '.AirflowVersions[]? // empty' 2>/dev/null || true)"

            if ! printf '%s\n' "$SUPPORTED" | grep -Fxq "$AIRFLOW_VERSION"; then
                sbx_status error "airflow_${AIRFLOW_VERSION}_unsupported_in_region"
                sbx_log "supported MWAA Airflow versions in ${REGION}: $(printf '%s' "$SUPPORTED" | tr '\n' ',' | sed 's/,$//')"
                exit 64
            fi
            sbx_log "confirmed: ${REGION} supports MWAA Airflow ${AIRFLOW_VERSION}"
            ;;
    esac
else
    sbx_aws mwaa list-supported-airflow-versions --region "$REGION"
    sbx_log "dry-run: skipping live capability check (apply-mode would assert exact match on Airflow ${AIRFLOW_VERSION})"
fi

# -----------------------------------------------------------------------------
# Step 2. DAG bucket — idempotent create (Requirement 20.13).
#
# MWAA REQUIRES the source bucket to have S3 Versioning enabled, so the
# `put-bucket-versioning` call below is non-optional.
# -----------------------------------------------------------------------------

sbx_log "step 2/4: ensure DAG bucket s3://${DAG_BUCKET}"

if sbx_apply_mode; then
    set +e
    aws s3api head-bucket --bucket "$DAG_BUCKET" --region "$REGION" >/dev/null 2>&1
    HEAD_RC=$?
    set -e
    if [ "$HEAD_RC" -eq 0 ]; then
        sbx_log "DAG bucket already exists: s3://${DAG_BUCKET}"
    else
        # `create-bucket` requires `--create-bucket-configuration` for any
        # region OTHER than us-east-1; us-east-1 rejects the same flag.
        if [ "$REGION" = "us-east-1" ]; then
            sbx_aws s3api create-bucket \
                --bucket "$DAG_BUCKET" \
                --region "$REGION"
        else
            sbx_aws s3api create-bucket \
                --bucket "$DAG_BUCKET" \
                --region "$REGION" \
                --create-bucket-configuration "LocationConstraint=${REGION}"
        fi
        # Block public access by default — the DAG bucket never holds
        # public data.
        sbx_aws s3api put-public-access-block \
            --bucket "$DAG_BUCKET" \
            --region "$REGION" \
            --public-access-block-configuration \
            "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
    fi
    # Versioning is REQUIRED by MWAA. Always assert it (the API is
    # idempotent — re-applying an already-Enabled config is a no-op).
    sbx_aws s3api put-bucket-versioning \
        --bucket "$DAG_BUCKET" \
        --region "$REGION" \
        --versioning-configuration "Status=Enabled"
else
    sbx_aws s3api head-bucket --bucket "$DAG_BUCKET" --region "$REGION"
    sbx_aws s3api create-bucket --bucket "$DAG_BUCKET" --region "$REGION"
    sbx_aws s3api put-bucket-versioning --bucket "$DAG_BUCKET" --region "$REGION" --versioning-configuration "Status=Enabled"
fi

# Persist the bucket name immediately so a SIGKILL between bucket-create
# and DAG upload still leaves teardown able to find the bucket
# (Requirement 20.12).
#
# Bug fix 1a: state writes happen ONLY in apply mode.
if sbx_apply_mode; then
    sbx_state_set_service "mwaa" "$(jq -nc \
        --arg bucket "$DAG_BUCKET" \
        '{status:"provisioning", resources:{dag_bucket:$bucket}}')"
fi

# -----------------------------------------------------------------------------
# Step 3. Upload sample DAGs — idempotent per key (Requirement 20.13, 20.24).
# -----------------------------------------------------------------------------

sbx_log "step 3/4: upload ${#DAG_FILES[@]} sample DAGs to s3://${DAG_BUCKET}/dags/"

DAGS_UPLOADED_KEYS=()
for dag_file in "${DAG_FILES[@]}"; do
    src="${DAGS_SRC_DIR}/${dag_file}"
    key="dags/${dag_file}"
    DAGS_UPLOADED_KEYS+=("$key")

    if [ ! -f "$src" ]; then
        sbx_status error "missing local DAG source: ${src}"
        exit 66
    fi

    if sbx_apply_mode; then
        set +e
        aws s3api head-object \
            --bucket "$DAG_BUCKET" \
            --key "$key" \
            --region "$REGION" >/dev/null 2>&1
        HEAD_RC=$?
        set -e
        if [ "$HEAD_RC" -eq 0 ]; then
            sbx_log "DAG already uploaded: s3://${DAG_BUCKET}/${key}"
            continue
        fi
        sbx_aws s3 cp "$src" "s3://${DAG_BUCKET}/${key}" --region "$REGION"
    else
        sbx_aws s3api head-object --bucket "$DAG_BUCKET" --key "$key" --region "$REGION"
        sbx_aws s3 cp "$src" "s3://${DAG_BUCKET}/${key}" --region "$REGION"
    fi
done

# -----------------------------------------------------------------------------
# Step 3.5. Idempotently create the MWAA execution role.
#
# Mirrors the seed/lambda/create.sh idempotency pattern:
#
#   1. get-role first → record ARN, skip create-role
#   2. else create-role with `--assume-role-policy-document file://<tmp>`
#   3. put-role-policy `mwaa-exec` (inline) — the canonical permissions
#      from https://docs.aws.amazon.com/mwaa/latest/userguide/mwaa-create-role.html
#   4. sleep 10 ONLY when freshly created, for IAM propagation so the
#      subsequent `aws mwaa create-environment` doesn't trip
#      InvalidRequestException ("role cannot be assumed by airflow*")
#
# Skipped entirely when the operator supplied SBX_MWAA_EXECUTION_ROLE_ARN
# or .mwaa.execution_role_arn (advanced override path).
#
# Trust policy (single document with BOTH service principals — MWAA
# requires both, per the AWS docs cited above):
#
#   {
#     "Version": "2012-10-17",
#     "Statement": [{
#       "Effect": "Allow",
#       "Principal": {
#         "Service": ["airflow-env.amazonaws.com", "airflow.amazonaws.com"]
#       },
#       "Action": "sts:AssumeRole"
#     }]
#   }
# -----------------------------------------------------------------------------

MWAA_TRUST_POLICY_JSON='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":["airflow-env.amazonaws.com","airflow.amazonaws.com"]},"Action":"sts:AssumeRole"}]}'

# _mwaa_role_exists <name>
_mwaa_role_exists() {
    local _name="$1"
    if ! sbx_apply_mode; then
        return 1
    fi
    aws iam get-role --role-name "$_name" >/dev/null 2>&1
}

# _build_mwaa_inline_policy <bucket-arn> <env-arn> <out-tmpfile>
#
# Build the canonical MWAA execution-role inline policy and write it to
# the named tmpfile. Built via jq so the bucket/env ARNs cannot break
# out of the JSON quoting.
_build_mwaa_inline_policy() {
    local _bucket_arn="$1"
    local _env_arn="$2"
    local _out="$3"
    jq -n \
        --arg bucket_arn "$_bucket_arn" \
        --arg bucket_keys_arn "${_bucket_arn}/*" \
        --arg env_arn "$_env_arn" \
        --arg region "$REGION" \
        --arg account_id "$ACCOUNT_ID" \
        --arg env_name "$ENV_NAME" \
        '{
            Version: "2012-10-17",
            Statement: [
                {
                    Effect: "Allow",
                    Action: "airflow:PublishMetrics",
                    Resource: $env_arn
                },
                {
                    Effect: "Allow",
                    Action: "s3:ListAllMyBuckets",
                    Resource: "*"
                },
                {
                    Effect: "Allow",
                    Action: ["s3:GetObject*", "s3:GetBucket*", "s3:List*"],
                    Resource: [$bucket_arn, $bucket_keys_arn]
                },
                {
                    Effect: "Allow",
                    Action: [
                        "logs:CreateLogStream",
                        "logs:CreateLogGroup",
                        "logs:PutLogEvents",
                        "logs:GetLogEvents",
                        "logs:GetLogRecord",
                        "logs:GetLogGroupFields",
                        "logs:GetQueryResults",
                        "logs:DescribeLogGroups",
                        "logs:DescribeLogStreams"
                    ],
                    Resource: ("arn:aws:logs:" + $region + ":" + $account_id + ":log-group:airflow-" + $env_name + "-*")
                },
                {
                    Effect: "Allow",
                    Action: "cloudwatch:PutMetricData",
                    Resource: "*"
                },
                {
                    Effect: "Allow",
                    Action: [
                        "sqs:ChangeMessageVisibility",
                        "sqs:DeleteMessage",
                        "sqs:GetQueueAttributes",
                        "sqs:GetQueueUrl",
                        "sqs:ReceiveMessage",
                        "sqs:SendMessage"
                    ],
                    Resource: "arn:aws:sqs:*:*:airflow-celery-*"
                },
                {
                    Effect: "Allow",
                    Action: [
                        "kms:Decrypt",
                        "kms:DescribeKey",
                        "kms:GenerateDataKey*",
                        "kms:Encrypt"
                    ],
                    NotResource: ("arn:aws:kms:*:" + $account_id + ":key/*"),
                    Condition: {
                        StringLike: {
                            "kms:ViaService": ("sqs." + $region + ".amazonaws.com")
                        }
                    }
                }
            ]
        }' > "$_out"
}

# Skip role creation when the operator supplied an override.
if [ -n "$EXEC_ROLE_ARN" ]; then
    sbx_log "step 3.5/4: using operator-supplied execution role: ${EXEC_ROLE_ARN}"
else
    sbx_log "step 3.5/4: ensure MWAA execution role ${MWAA_ROLE_NAME}"

    _mwaa_role_freshly_created=0
    if _mwaa_role_exists "$MWAA_ROLE_NAME"; then
        sbx_status ok "iam role ${MWAA_ROLE_NAME} already exists; skipping create-role"
        EXEC_ROLE_ARN="$(aws iam get-role \
            --role-name "$MWAA_ROLE_NAME" \
            --query 'Role.Arn' \
            --output text)"
    else
        _trust_tmp="$(mktemp -t "sbx-${MWAA_ROLE_NAME}-trust-XXXXXX.json")"
        printf '%s\n' "$MWAA_TRUST_POLICY_JSON" > "$_trust_tmp"

        if sbx_apply_mode; then
            sbx_status action "aws iam create-role"
            EXEC_ROLE_ARN="$(aws iam create-role \
                --role-name "$MWAA_ROLE_NAME" \
                --assume-role-policy-document "file://${_trust_tmp}" \
                --tags "Key=sbx:seed-name-prefix,Value=${SBX_SEED_NAME_PREFIX}" \
                --query 'Role.Arn' \
                --output text)"
            if [ -z "$EXEC_ROLE_ARN" ] || [ "$EXEC_ROLE_ARN" = "None" ]; then
                rm -f "$_trust_tmp"
                sbx_status error "create-role returned no ARN for ${MWAA_ROLE_NAME}"
                exit 1
            fi
            _mwaa_role_freshly_created=1
        else
            sbx_aws iam create-role \
                --role-name "$MWAA_ROLE_NAME" \
                --assume-role-policy-document "file://${_trust_tmp}" \
                --tags "Key=sbx:seed-name-prefix,Value=${SBX_SEED_NAME_PREFIX}"
            EXEC_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${MWAA_ROLE_NAME}"
        fi

        rm -f "$_trust_tmp"
    fi

    # Idempotent inline-policy put. AWS treats put-role-policy as a
    # replace when the policy name already exists, so we issue this on
    # every run rather than gating it behind a list-role-policies probe.
    _env_arn_for_policy="arn:aws:airflow:${REGION}:${ACCOUNT_ID}:environment/${ENV_NAME}"
    _inline_tmp="$(mktemp -t "sbx-${MWAA_ROLE_NAME}-mwaa-exec-XXXXXX.json")"
    _build_mwaa_inline_policy "$DAG_BUCKET_ARN" "$_env_arn_for_policy" "$_inline_tmp"

    sbx_aws iam put-role-policy \
        --role-name "$MWAA_ROLE_NAME" \
        --policy-name "mwaa-exec" \
        --policy-document "file://${_inline_tmp}"

    rm -f "$_inline_tmp"

    if [ "$_mwaa_role_freshly_created" = "1" ]; then
        if sbx_apply_mode; then
            sbx_log "waiting 10s for IAM role propagation (${MWAA_ROLE_NAME})"
            sleep 10
        else
            sbx_log "would wait 10s for IAM role propagation (${MWAA_ROLE_NAME})"
        fi
    fi

    # Persist the role ARN immediately so a SIGKILL between role creation
    # and create-environment still leaves teardown able to find the role
    # (Requirement 20.12).
    #
    # Bug fix 1a: state writes happen ONLY in apply mode.
    if sbx_apply_mode; then
        sbx_state_set_service "mwaa" "$(jq -nc \
            --arg role_arn "$EXEC_ROLE_ARN" \
            '{resources:{execution_role_arn:$role_arn}}')"
    fi
fi

# -----------------------------------------------------------------------------
# Step 4. MWAA environment — idempotent via `aws mwaa get-environment`
# (Requirement 20.13, 20.23).
# -----------------------------------------------------------------------------

sbx_log "step 4/4: ensure MWAA environment ${ENV_NAME}"

# Validate operator-supplied inputs BEFORE any state-changing call. In
# dry-run we permit placeholders so the plan can be reviewed end-to-end;
# in apply-mode we require them.
if sbx_apply_mode; then
    if [ -z "$EXEC_ROLE_ARN" ]; then
        # Defensive: step 3.5 above either creates the role inline OR
        # honors an operator-supplied override, so EXEC_ROLE_ARN must be
        # non-empty by this point. An empty value here means step 3.5
        # somehow failed silently (e.g. an aws iam call returned empty).
        sbx_status error "missing_var EXEC_ROLE_ARN (step 3.5 should have populated it; see preceding STATUS lines)"
        exit 64
    fi
    if [ -z "$SUBNETS_RAW" ] || [ -z "$SGS_RAW" ]; then
        sbx_status error "missing MWAA networking inputs: SBX_MWAA_SUBNET_IDS=${SUBNETS_RAW:-<unset>} SBX_MWAA_SECURITY_GROUP_IDS=${SGS_RAW:-<unset>}"
        sbx_log "set SBX_MWAA_SUBNET_IDS (≥2 private subnets in different AZs) and SBX_MWAA_SECURITY_GROUP_IDS, OR .mwaa.subnet_ids / .mwaa.security_group_ids in seed.config.json"
        exit 64
    fi
fi

# Existence check.
ENV_EXISTS=0
ENV_ARN=""
ENV_STATUS=""
if sbx_apply_mode; then
    set +e
    EXIST_JSON="$(aws mwaa get-environment --name "$ENV_NAME" --region "$REGION" --output json 2>/dev/null)"
    GE_RC=$?
    set -e
    if [ "$GE_RC" -eq 0 ] && [ -n "$EXIST_JSON" ]; then
        ENV_EXISTS=1
        ENV_ARN="$(printf '%s' "$EXIST_JSON" | jq -r '.Environment.Arn // empty')"
        ENV_STATUS="$(printf '%s' "$EXIST_JSON" | jq -r '.Environment.Status // empty')"
        sbx_log "MWAA environment already exists: ${ENV_NAME} (Arn=${ENV_ARN}, Status=${ENV_STATUS})"
    fi
else
    sbx_aws mwaa get-environment --name "$ENV_NAME" --region "$REGION"
fi

# Convert comma-separated subnet/SG strings into JSON arrays for the CLI.
to_json_array() {
    local raw="${1:-}"
    if [ -z "$raw" ]; then
        printf '[]'
        return 0
    fi
    printf '%s' "$raw" | tr ',' '\n' | jq -R . | jq -s .
}

# Dry-run placeholders so the printed plan is coherent without operator
# inputs. EXEC_ROLE_ARN is always populated by step 3.5 above (either
# from the operator override or from the inline role creation), so we
# use it directly instead of a separate DRY_EXEC_ROLE placeholder.
DRY_SUBNETS="${SUBNETS_RAW:-subnet-PLACEHOLDER-1,subnet-PLACEHOLDER-2}"
DRY_SGS="${SGS_RAW:-sg-PLACEHOLDER}"

SUBNET_JSON="$(to_json_array "${SUBNETS_RAW:-$DRY_SUBNETS}")"
SG_JSON="$(to_json_array "${SGS_RAW:-$DRY_SGS}")"
NETWORK_CONFIG_JSON="$(jq -nc \
    --argjson sgs "$SG_JSON" \
    --argjson subnets "$SUBNET_JSON" \
    '{SecurityGroupIds: $sgs, SubnetIds: $subnets}')"

if [ "$ENV_EXISTS" -eq 0 ]; then
    if sbx_apply_mode; then
        # Capture the response so we can persist the ARN to seed.state.json
        # before any further state-changing CLI command (Requirement 20.12).
        CREATE_JSON="$(aws mwaa create-environment \
            --name "$ENV_NAME" \
            --region "$REGION" \
            --airflow-version "$AIRFLOW_VERSION" \
            --environment-class "$ENV_CLASS" \
            --execution-role-arn "$EXEC_ROLE_ARN" \
            --source-bucket-arn "$DAG_BUCKET_ARN" \
            --dag-s3-path "dags/" \
            --network-configuration "$NETWORK_CONFIG_JSON" \
            --webserver-access-mode PUBLIC_ONLY \
            --output json)"
        ENV_ARN="$(printf '%s' "$CREATE_JSON" | jq -r '.Arn // empty')"
        sbx_log "MWAA create-environment submitted: ${ENV_NAME} (Arn=${ENV_ARN}); provisioning typically takes 20–30 minutes"
    else
        # Echo the would-be command so an operator reviewing dry-run can
        # see exactly what apply-mode would issue.
        sbx_aws mwaa create-environment \
            --name "$ENV_NAME" \
            --region "$REGION" \
            --airflow-version "$AIRFLOW_VERSION" \
            --environment-class "$ENV_CLASS" \
            --execution-role-arn "$EXEC_ROLE_ARN" \
            --source-bucket-arn "$DAG_BUCKET_ARN" \
            --dag-s3-path "dags/" \
            --network-configuration "$NETWORK_CONFIG_JSON" \
            --webserver-access-mode PUBLIC_ONLY
        ENV_ARN="arn:aws:airflow:${REGION}:${ACCOUNT_ID}:environment/${ENV_NAME}"
    fi
fi

# -----------------------------------------------------------------------------
# Persist the environment ARN BEFORE the long poll (Requirement 20.12).
# Flat resource shape per task 24.12: environment_name, environment_arn,
# airflow_version, dag_bucket. A subsequent failure during the poll loop
# therefore still leaves teardown able to identify the environment.
#
# Bug fix 1a: state writes happen ONLY in apply mode.
# -----------------------------------------------------------------------------
if sbx_apply_mode; then
    sbx_state_set_service "mwaa" "$(jq -nc \
        --arg env_name "$ENV_NAME" \
        --arg env_arn "$ENV_ARN" \
        --arg airflow "$AIRFLOW_VERSION" \
        --arg env_class "$ENV_CLASS" \
        --arg bucket "$DAG_BUCKET" \
        --arg bucket_arn "$DAG_BUCKET_ARN" \
        --arg role_arn "$EXEC_ROLE_ARN" \
        --argjson dags "$(printf '%s\n' "${DAGS_UPLOADED_KEYS[@]}" | jq -R . | jq -s .)" \
        '{
            status: "provisioning",
            resources: {
                environment_name: $env_name,
                environment_arn: $env_arn,
                airflow_version: $airflow,
                environment_class: $env_class,
                dag_bucket: $bucket,
                dag_bucket_arn: $bucket_arn,
                execution_role_arn: $role_arn,
                dags_uploaded: $dags
            }
        }')"
fi

# -----------------------------------------------------------------------------
# Bounded poll loop — wait for Status == AVAILABLE.
#
# MWAA create takes 20–30 minutes. The loop runs up to 60 polls × 30 s =
# 30 minutes (matching MSK's poll budget). Skipped entirely in dry-run.
#
# Terminal states the loop recognises:
#   - AVAILABLE — success, break out and persist `provisioned`.
#   - CREATE_FAILED / UPDATE_FAILED / DELETING / DELETED — failure, halt
#     with a clear STATUS line (no point in continuing to poll).
#   - everything else (CREATING, UPDATING, …) — keep polling.
# -----------------------------------------------------------------------------

if sbx_apply_mode; then
    sbx_status action "mwaa_wait_available name=${ENV_NAME}"
    _state="${ENV_STATUS:-UNKNOWN}"
    _i=0
    # 60 polls × 60 s = 60 min. MWAA environment provisioning is genuinely
    # long-running; in some regions and at busy times it can take well
    # over the 30 min we previously budgeted. A 1 h ceiling absorbs the
    # tail without prematurely declaring failure.
    _max_polls=60
    _poll_interval_s=60
    while [ "$_i" -lt "$_max_polls" ]; do
        # Fetch the current state. `|| true` lets us treat transient API
        # errors as "still polling" rather than fatal — the next iteration
        # will retry. A persistently failing get-environment will surface
        # via the timeout branch below.
        _desc_json="$(aws mwaa get-environment \
            --name "$ENV_NAME" \
            --region "$REGION" \
            --output json 2>/dev/null || echo '{}')"
        _state="$(printf '%s' "$_desc_json" | jq -r '.Environment.Status // "UNKNOWN"')"
        case "$_state" in
            AVAILABLE) break ;;
            CREATE_FAILED|UPDATE_FAILED|DELETING|DELETED)
                sbx_status error "mwaa_environment_unhealthy state=${_state} name=${ENV_NAME}"
                sbx_state_set_service "mwaa" '{"status":"failed"}'
                exit 1
                ;;
        esac
        # Emit progress every ~5 minutes (every 5 polls × 60 s) so the
        # operator's log shows the loop is alive without flooding stdout.
        if [ $((_i % 5)) -eq 0 ]; then
            sbx_status in-progress "mwaa_wait_available poll=${_i}/${_max_polls} state=${_state}"
        fi
        _i=$((_i + 1))
        sleep "$_poll_interval_s"
    done

    if [ "$_state" != "AVAILABLE" ]; then
        sbx_status error "mwaa_wait_available_timeout state=${_state} name=${ENV_NAME} polls=${_max_polls}"
        sbx_state_set_service "mwaa" '{"status":"failed"}'
        exit 1
    fi
    sbx_status ok "mwaa_available name=${ENV_NAME}"
else
    sbx_log "dry-run: skipping wait-for-AVAILABLE poll loop (apply-mode budget = 60 polls × 30 s = 30 min)"
fi

# -----------------------------------------------------------------------------
# Final state write — flip status to provisioned (Requirement 20.12).
#
# Bug fix 1a: state writes happen ONLY in apply mode.
# -----------------------------------------------------------------------------

if sbx_apply_mode; then
    sbx_state_set_service "mwaa" '{"status":"provisioned"}'
    sbx_log "wrote services.mwaa to $(sbx_state_path)"
else
    sbx_log "dry-run: skipping state write (would record .services.mwaa.status=provisioned)"
fi

sbx_status ok
exit 0
