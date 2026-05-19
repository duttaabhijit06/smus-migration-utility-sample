#!/usr/bin/env bash
#
# seed/data-gen/create.sh — Synthetic event-generator Lambdas.
#
# Provisions two Lambdas + an EventBridge rule that fire every minute
# to generate 100 synthetic events per invocation:
#
#   <prefix>-kinesis-data-gen   PutRecords into <prefix>-events kinesis stream
#   <prefix>-msk-data-gen       Produces to MSK topic <prefix>-events
#
# Both Lambdas share a single IAM role `<prefix>-data-gen-role` carrying
# inline policy `data-gen-write` granting:
#   - kinesis:PutRecord{,s} on the kinesis stream ARN
#   - kafka-cluster:Connect, DescribeTopic*, WriteData on the MSK ARN/topic
#   - kafka:GetBootstrapBrokers, DescribeCluster*
#
# The MSK Lambda's deployment package vendors:
#   - kafka-python                       (KafkaProducer + KafkaAdminClient)
#   - aws-msk-iam-sasl-signer-python     (MSK_IAM SASL/OAUTHBEARER token signer)
#
# These are installed into a temp dir via `pip install -t <dir>` and
# zipped alongside `lambda_function.py`. ~5 MB total.
#
# The kinesis Lambda is inline-zip only (boto3 is in the runtime).
#
# EventBridge rule `<prefix>-data-gen-schedule` (rate: 1 minute) targets
# both Lambdas.
#
# Bug fixes applied:
#   - 1a: state writes gated behind sbx_apply_mode.
#   - 1b: --cli-input-json uses tempfiles (mktemp).
#   - 1d: aws CLI captures bypass sbx_aws.
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

# -----------------------------------------------------------------------------
# Names + constants.
# -----------------------------------------------------------------------------
ROLE_NAME="${SBX_SEED_NAME_PREFIX}-data-gen-role"
INLINE_POLICY_NAME="data-gen-write"
KINESIS_FN_NAME="${SBX_SEED_NAME_PREFIX}-kinesis-data-gen"
MSK_FN_NAME="${SBX_SEED_NAME_PREFIX}-msk-data-gen"
RULE_NAME="${SBX_SEED_NAME_PREFIX}-data-gen-schedule"

LAMBDA_RUNTIME="python3.11"
LAMBDA_MEMORY_MB=256
LAMBDA_TIMEOUT_S=60

# Managed policies the role attaches.
LAMBDA_BASIC_EXEC_POLICY_ARN="arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
LAMBDA_VPC_EXEC_POLICY_ARN="arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"

KINESIS_STREAM_NAME="${SBX_SEED_NAME_PREFIX}-events"
MSK_TOPIC="${SBX_SEED_NAME_PREFIX}-events"

# Lambda VPC config — same subnets + SGs as MSK so the MSK Lambda can
# reach brokers over PrivateLink.
VPC_SUBNETS_JSON="$(jq -c '.msk.vpc_subnet_ids // []' "$__SEED_CFG")"
VPC_SGS_JSON="$(jq -c '.msk.security_group_ids // []' "$__SEED_CFG")"

sbx_status started

# -----------------------------------------------------------------------------
# Read upstream state. Apply mode hard-fails if any required input is
# missing; dry-run uses placeholders.
# -----------------------------------------------------------------------------
KINESIS_STREAM_ARN="$(sbx_state_get '.services.kinesis.resources.stream_arn')"
MSK_CLUSTER_ARN="$(sbx_state_get '.services.msk.resources.cluster.arn')"
MSK_BOOTSTRAP="$(sbx_state_get '.services.msk.resources.bootstrap_brokers')"

if sbx_apply_mode; then
    if [ -z "$KINESIS_STREAM_ARN" ]; then
        sbx_status error "dependency_not_provisioned (.services.kinesis.resources.stream_arn empty)"
        exit 64
    fi
    if [ -z "$MSK_CLUSTER_ARN" ]; then
        sbx_status error "dependency_not_provisioned (.services.msk.resources.cluster.arn empty)"
        exit 64
    fi
    if [ -z "$MSK_BOOTSTRAP" ]; then
        sbx_status error "dependency_not_provisioned (.services.msk.resources.bootstrap_brokers empty)"
        exit 64
    fi
else
    : "${KINESIS_STREAM_ARN:=arn:aws:kinesis:${SBX_REGION}:${SBX_SOURCE_ACCOUNT_ID}:stream/${KINESIS_STREAM_NAME}}"
    : "${MSK_CLUSTER_ARN:=arn:aws:kafka:${SBX_REGION}:${SBX_SOURCE_ACCOUNT_ID}:cluster/${SBX_SEED_NAME_PREFIX}-msk-cluster/PLACEHOLDER}"
    : "${MSK_BOOTSTRAP:=b-1.placeholder.example.com:9098,b-2.placeholder.example.com:9098}"
fi

# -----------------------------------------------------------------------------
# Step 1. Shared IAM role.
# -----------------------------------------------------------------------------
TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

ROLE_ARN="arn:aws:iam::${SBX_SOURCE_ACCOUNT_ID}:role/${ROLE_NAME}"
_role_freshly_created=0
if sbx_apply_mode; then
    if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
        sbx_log "iam role ${ROLE_NAME} already exists; skipping create"
        ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)"
    else
        _trust_tmp="$(mktemp -t "sbx-data-gen-trust-XXXXXX.json")"
        printf '%s\n' "$TRUST_POLICY" > "$_trust_tmp"
        sbx_status action "aws iam create-role"
        ROLE_ARN="$(aws iam create-role \
            --role-name "$ROLE_NAME" \
            --assume-role-policy-document "file://${_trust_tmp}" \
            --tags "Key=sbx:seed-name-prefix,Value=${SBX_SEED_NAME_PREFIX}" \
            --query 'Role.Arn' \
            --output text)"
        rm -f "$_trust_tmp"
        _role_freshly_created=1
    fi
else
    _trust_tmp="$(mktemp -t "sbx-data-gen-trust-XXXXXX.json")"
    printf '%s\n' "$TRUST_POLICY" > "$_trust_tmp"
    sbx_aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document "file://${_trust_tmp}" \
        --tags "Key=sbx:seed-name-prefix,Value=${SBX_SEED_NAME_PREFIX}"
    rm -f "$_trust_tmp"
fi

# Attach managed policies (idempotent on AWS side).
sbx_aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn "$LAMBDA_BASIC_EXEC_POLICY_ARN"
sbx_aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn "$LAMBDA_VPC_EXEC_POLICY_ARN"

# Inline data-gen-write policy.
#
# MSK IAM resource ARNs follow a specific shape:
#   cluster: arn:aws:kafka:<region>:<account>:cluster/<name>/<uuid>
#   topic:   arn:aws:kafka:<region>:<account>:topic/<name>/<uuid>/<topic-name>
#   group:   arn:aws:kafka:<region>:<account>:group/<name>/<uuid>/<group-name>
#
# Build them by splitting MSK_CLUSTER_ARN on `:cluster/`.
_msk_arn_prefix="${MSK_CLUSTER_ARN%:cluster/*}"
_msk_cluster_path="${MSK_CLUSTER_ARN##*:cluster/}"
_msk_topic_arn="${_msk_arn_prefix}:topic/${_msk_cluster_path}/${MSK_TOPIC}"
_msk_group_arn="${_msk_arn_prefix}:group/${_msk_cluster_path}/*"

_inline_tmp="$(mktemp -t "sbx-data-gen-policy-XXXXXX.json")"
jq -n \
    --arg kin_arn "$KINESIS_STREAM_ARN" \
    --arg msk_arn "$MSK_CLUSTER_ARN" \
    --arg msk_topic_arn "$_msk_topic_arn" \
    --arg msk_group_arn "$_msk_group_arn" \
    '{
        Version: "2012-10-17",
        Statement: [
            {
                Sid: "KinesisWrite",
                Effect: "Allow",
                Action: ["kinesis:PutRecord", "kinesis:PutRecords", "kinesis:DescribeStream"],
                Resource: $kin_arn
            },
            {
                Sid: "MSKControlPlane",
                Effect: "Allow",
                Action: [
                    "kafka:GetBootstrapBrokers",
                    "kafka:DescribeCluster",
                    "kafka:DescribeClusterV2"
                ],
                Resource: $msk_arn
            },
            {
                Sid: "MSKDataPlane",
                Effect: "Allow",
                Action: [
                    "kafka-cluster:Connect",
                    "kafka-cluster:DescribeTopic",
                    "kafka-cluster:DescribeTopicDynamicConfiguration",
                    "kafka-cluster:WriteData",
                    "kafka-cluster:CreateTopic",
                    "kafka-cluster:DescribeGroup"
                ],
                Resource: [$msk_arn, $msk_topic_arn, $msk_group_arn]
            }
        ]
    }' > "$_inline_tmp"

sbx_aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name "$INLINE_POLICY_NAME" \
    --policy-document "file://${_inline_tmp}"
rm -f "$_inline_tmp"

if [ "$_role_freshly_created" = "1" ] && sbx_apply_mode; then
    sbx_log "waiting 10s for IAM role propagation (${ROLE_NAME})"
    sleep 10
fi

# -----------------------------------------------------------------------------
# Step 2. Lambda packaging.
#
# Two zips:
#   * kinesis_pkg.zip  — only lambda_function.py (boto3 is in the runtime)
#   * msk_pkg.zip      — lambda_function.py + vendored kafka-python +
#                        aws-msk-iam-sasl-signer-python
#
# We build into mktemp dirs so re-runs don't accumulate stale state.
# -----------------------------------------------------------------------------
_kinesis_zip=""
_msk_zip=""

_build_lambda_packages_apply() {
    if ! command -v zip >/dev/null 2>&1; then
        sbx_status error "zip command not found; required to build Lambda deployment packages"
        exit 64
    fi

    # Kinesis package — single file.
    local _kin_dir
    _kin_dir="$(mktemp -d "${TMPDIR:-/tmp}/sbx-data-gen-kin-XXXXXX")"
    cp "${__dg_dir}/fixtures/event_generator.py" "${_kin_dir}/lambda_function.py"
    _kinesis_zip="$(mktemp -t "sbx-data-gen-kin-XXXXXX.zip")"
    rm -f "$_kinesis_zip"
    (cd "$_kin_dir" && zip -q "$_kinesis_zip" lambda_function.py)
    rm -rf "$_kin_dir"

    # MSK package — handler + vendored deps. We use --only-binary=:none:
    # to avoid attempting to download Linux-specific wheels from a
    # non-Linux build host (the kafka-python and aws-msk-iam-sasl-signer
    # wheels are pure-Python or have a universal sdist, so this works).
    local _msk_dir
    _msk_dir="$(mktemp -d "${TMPDIR:-/tmp}/sbx-data-gen-msk-XXXXXX")"
    cp "${__dg_dir}/fixtures/event_generator.py" "${_msk_dir}/lambda_function.py"
    if ! python3 -m pip install --quiet --target "$_msk_dir" \
            "kafka-python>=2.0,<3.0" \
            "aws-msk-iam-sasl-signer-python"; then
        sbx_status error "msk_lambda_pip_install_failed"
        rm -rf "$_msk_dir"
        return 1
    fi
    _msk_zip="$(mktemp -t "sbx-data-gen-msk-XXXXXX.zip")"
    rm -f "$_msk_zip"
    (cd "$_msk_dir" && zip -r -q "$_msk_zip" . -x "*.pyc" -x "*/__pycache__/*")
    rm -rf "$_msk_dir"
}

if sbx_apply_mode; then
    if ! _build_lambda_packages_apply; then
        exit 1
    fi
else
    sbx_log "dry-run: would build kinesis Lambda zip from fixtures/event_generator.py"
    sbx_log "dry-run: would build msk Lambda zip with kafka-python + aws-msk-iam-sasl-signer-python via pip install -t"
fi

# -----------------------------------------------------------------------------
# Step 3. Create / update each Lambda function.
# -----------------------------------------------------------------------------
KINESIS_FN_ARN=""
MSK_FN_ARN=""

_subnet_csv="$(printf '%s' "$VPC_SUBNETS_JSON" | jq -r '. | join(",")')"
_sg_csv="$(printf '%s' "$VPC_SGS_JSON" | jq -r '. | join(",")')"

_create_or_update_function() {
    local _name="$1" _zip="$2" _env_vars="$3"

    local _exists=0
    if sbx_apply_mode; then
        if aws lambda get-function \
                --region "$SBX_REGION" \
                --function-name "$_name" >/dev/null 2>&1; then
            _exists=1
        fi
    else
        sbx_aws lambda get-function \
            --region "$SBX_REGION" \
            --function-name "$_name" || true
    fi

    if [ "$_exists" -eq 1 ]; then
        sbx_log "lambda ${_name} already exists; updating code"
        if sbx_apply_mode; then
            sbx_status action "aws lambda update-function-code"
            aws lambda update-function-code \
                --region "$SBX_REGION" \
                --function-name "$_name" \
                --zip-file "fileb://${_zip}" \
                --output json >/dev/null
            aws lambda wait function-updated \
                --region "$SBX_REGION" \
                --function-name "$_name" >/dev/null 2>&1 || true
        else
            sbx_aws lambda update-function-code \
                --region "$SBX_REGION" \
                --function-name "$_name" \
                --zip-file "fileb://PLACEHOLDER.zip"
        fi
        return 0
    fi

    if sbx_apply_mode; then
        sbx_status action "aws lambda create-function"
        aws lambda create-function \
            --region "$SBX_REGION" \
            --function-name "$_name" \
            --runtime "$LAMBDA_RUNTIME" \
            --role "$ROLE_ARN" \
            --handler "lambda_function.lambda_handler" \
            --memory-size "$LAMBDA_MEMORY_MB" \
            --timeout "$LAMBDA_TIMEOUT_S" \
            --zip-file "fileb://${_zip}" \
            --vpc-config "SubnetIds=${_subnet_csv:-subnet-PLACEHOLDER},SecurityGroupIds=${_sg_csv:-sg-PLACEHOLDER}" \
            --environment "Variables={${_env_vars}}" \
            --tags "sbx:seed-name-prefix=${SBX_SEED_NAME_PREFIX}" \
            --output json >/dev/null
        aws lambda wait function-active-v2 \
            --region "$SBX_REGION" \
            --function-name "$_name" >/dev/null 2>&1 || true
    else
        sbx_aws lambda create-function \
            --region "$SBX_REGION" \
            --function-name "$_name" \
            --runtime "$LAMBDA_RUNTIME" \
            --role "$ROLE_ARN" \
            --handler "lambda_function.lambda_handler" \
            --memory-size "$LAMBDA_MEMORY_MB" \
            --timeout "$LAMBDA_TIMEOUT_S" \
            --zip-file "fileb://PLACEHOLDER.zip" \
            --vpc-config "SubnetIds=${_subnet_csv:-subnet-PLACEHOLDER},SecurityGroupIds=${_sg_csv:-sg-PLACEHOLDER}" \
            --environment "Variables={${_env_vars}}"
    fi
}

_create_or_update_function "$KINESIS_FN_NAME" "${_kinesis_zip:-/tmp/PLACEHOLDER.zip}" \
    "MODE=kinesis,STREAM_NAME=${KINESIS_STREAM_NAME}"

_create_or_update_function "$MSK_FN_NAME" "${_msk_zip:-/tmp/PLACEHOLDER.zip}" \
    "MODE=msk,STREAM_NAME=${KINESIS_STREAM_NAME},MSK_BOOTSTRAP_BROKERS=${MSK_BOOTSTRAP},MSK_TOPIC=${MSK_TOPIC}"

if sbx_apply_mode; then
    KINESIS_FN_ARN="$(aws lambda get-function \
        --region "$SBX_REGION" \
        --function-name "$KINESIS_FN_NAME" \
        --query 'Configuration.FunctionArn' \
        --output text 2>/dev/null || echo "")"
    MSK_FN_ARN="$(aws lambda get-function \
        --region "$SBX_REGION" \
        --function-name "$MSK_FN_NAME" \
        --query 'Configuration.FunctionArn' \
        --output text 2>/dev/null || echo "")"
else
    KINESIS_FN_ARN="arn:aws:lambda:${SBX_REGION}:${SBX_SOURCE_ACCOUNT_ID}:function:${KINESIS_FN_NAME}"
    MSK_FN_ARN="arn:aws:lambda:${SBX_REGION}:${SBX_SOURCE_ACCOUNT_ID}:function:${MSK_FN_NAME}"
fi

# Clean up the local zip files.
[ -n "$_kinesis_zip" ] && rm -f "$_kinesis_zip"
[ -n "$_msk_zip" ] && rm -f "$_msk_zip"

# -----------------------------------------------------------------------------
# Step 4. EventBridge rule + targets.
# -----------------------------------------------------------------------------
RULE_ARN="arn:aws:events:${SBX_REGION}:${SBX_SOURCE_ACCOUNT_ID}:rule/${RULE_NAME}"

_rule_exists=0
if sbx_apply_mode; then
    if aws events describe-rule --name "$RULE_NAME" --region "$SBX_REGION" >/dev/null 2>&1; then
        _rule_exists=1
    fi
fi

if [ "$_rule_exists" -eq 1 ]; then
    sbx_log "eventbridge rule ${RULE_NAME} already exists; skipping put-rule"
else
    sbx_aws events put-rule \
        --region "$SBX_REGION" \
        --name "$RULE_NAME" \
        --schedule-expression "rate(1 minute)" \
        --state "ENABLED" \
        --description "Seed event-generator schedule (1/min) for ${SBX_SEED_NAME_PREFIX}"
fi

# Targets — both Lambdas. put-targets is idempotent; AWS dedupes by Id.
_targets_tmp="$(mktemp -t "sbx-data-gen-targets-XXXXXX.json")"
jq -n \
    --arg kin_arn "$KINESIS_FN_ARN" \
    --arg msk_arn "$MSK_FN_ARN" \
    '[{Id: "kinesis-data-gen", Arn: $kin_arn}, {Id: "msk-data-gen", Arn: $msk_arn}]' \
    > "$_targets_tmp"
sbx_aws events put-targets \
    --region "$SBX_REGION" \
    --rule "$RULE_NAME" \
    --targets "file://${_targets_tmp}"
rm -f "$_targets_tmp"

# Grant EventBridge permission to invoke each Lambda. add-permission is
# NOT idempotent — it returns ResourceConflictException when the
# statement-id already exists. Tolerate that and continue.
_grant_invoke() {
    local _fn="$1" _stmt_id="$2"
    if sbx_apply_mode; then
        aws lambda add-permission \
            --region "$SBX_REGION" \
            --function-name "$_fn" \
            --statement-id "$_stmt_id" \
            --action "lambda:InvokeFunction" \
            --principal "events.amazonaws.com" \
            --source-arn "$RULE_ARN" \
            >/dev/null 2>&1 || true
        sbx_status action "aws lambda add-permission ${_fn}"
    else
        sbx_aws lambda add-permission \
            --region "$SBX_REGION" \
            --function-name "$_fn" \
            --statement-id "$_stmt_id" \
            --action "lambda:InvokeFunction" \
            --principal "events.amazonaws.com" \
            --source-arn "$RULE_ARN"
    fi
}
_grant_invoke "$KINESIS_FN_NAME" "${SBX_SEED_NAME_PREFIX}-evb-invoke-kin"
_grant_invoke "$MSK_FN_NAME" "${SBX_SEED_NAME_PREFIX}-evb-invoke-msk"

# -----------------------------------------------------------------------------
# Persist state ONLY in apply mode (bug fix 1a).
# -----------------------------------------------------------------------------
if sbx_apply_mode; then
    sbx_state_set_service data-gen "$(jq -n \
        --arg role_arn "$ROLE_ARN" \
        --arg role_name "$ROLE_NAME" \
        --arg kin_fn "$KINESIS_FN_NAME" \
        --arg kin_arn "$KINESIS_FN_ARN" \
        --arg msk_fn "$MSK_FN_NAME" \
        --arg msk_arn "$MSK_FN_ARN" \
        --arg rule "$RULE_NAME" \
        --arg rule_arn "$RULE_ARN" \
        '{
            status: "provisioned",
            resources: {
                role_arn: $role_arn,
                role_name: $role_name,
                kinesis_function_name: $kin_fn,
                kinesis_function_arn: $kin_arn,
                msk_function_name: $msk_fn,
                msk_function_arn: $msk_arn,
                eventbridge_rule_name: $rule,
                eventbridge_rule_arn: $rule_arn
            }
        }')"
    sbx_status ok "data_gen_provisioned kinesis_fn=${KINESIS_FN_NAME} msk_fn=${MSK_FN_NAME} rule=${RULE_NAME}"
else
    sbx_log "dry-run: skipping state write (would record .services.data-gen.status=provisioned)"
    sbx_status ok "data_gen_dry_run kinesis_fn=${KINESIS_FN_NAME} msk_fn=${MSK_FN_NAME} rule=${RULE_NAME}"
fi
