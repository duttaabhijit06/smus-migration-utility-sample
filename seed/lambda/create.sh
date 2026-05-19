#!/usr/bin/env bash
#
# seed/lambda/create.sh — Provision the seed AWS Lambda module.
#
# Per Requirement 20.20, the Seed_Script's Lambda module creates at
# least 2 ZIP-deployed Lambda functions in the source account so the
# Migration_Tool's inventory pass (`steps/inventory/lambda/run.sh`) has
# real targets to enumerate. This module is the canonical implementation
# of that contract.
#
# Resources created
#
#   IAM role
#     name : ${SBX_SEED_NAME_PREFIX}-lambda-exec-role
#     trust: lambda.amazonaws.com
#     attached managed policy:
#         arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
#
#   Lambda functions (Python 3.11, 128 MB / 30 s)
#     ${SBX_SEED_NAME_PREFIX}-fn-1
#     ${SBX_SEED_NAME_PREFIX}-fn-2
#
#   Both functions ship a single inline `lambda_function.py` whose
#   handler `lambda_function.lambda_handler` returns the literal payload
#   `{"statusCode": 200}`. The deployment ZIP is built on-the-fly under
#   ./seed/lambda/dist/ and reused across both functions, so apply-mode
#   uploads two byte-identical archives.
#
# Idempotency contract (Requirement 20.13)
#
#   - `aws iam get-role` precedes `aws iam create-role`.
#   - `aws lambda get-function` precedes every `aws lambda create-function`
#     call. When a function whose name matches the prefix already exists,
#     create-function is skipped and the existing ARN is reused.
#   - `aws iam attach-role-policy` is intrinsically idempotent on the AWS
#     side (re-attaching an already-attached policy is a 200 no-op), so
#     we always issue the attach call after a get-role hit.
#   - On a successful re-run, zero `aws lambda create-function`, zero
#     `aws iam create-role`, and zero `aws lambda update-function-*`
#     commands are issued.
#
# Resource-name prefix gating (Requirement 20.29)
#
#   Every created resource name begins with `${SBX_SEED_NAME_PREFIX}-`.
#   The prefix is mandatory; an empty/unset prefix halts before any AWS
#   CLI call.
#
# Post-migration idempotency (Requirement 20.32)
#
#   This module never invokes `aws datazone create-*` and never targets
#   the SMUS_Domain ID or the Admin_Project ID recorded in
#   ./config/migration.config.json. Lambda lives wholly outside the
#   SMUS_Domain.
#
# State persistence (Requirement 20.12)
#
#   On successful create or detection of an existing resource, the
#   following are written to ./seed/seed.state.json under .services.lambda
#   via `sbx_state_set_service` BEFORE any subsequent state-changing AWS
#   CLI command:
#
#     .services.lambda.status         = "provisioned"
#     .services.lambda.role_arn       = "<role-arn>"
#     .services.lambda.function_arns  = ["<fn-1-arn>", "<fn-2-arn>"]
#
# Validates Requirements: 20.9, 20.13, 20.20, 20.29, 20.31, 20.32.
#

set -euo pipefail

# Resolve paths so this script works from any cwd. The grandparent of
# this file is the seed root; one more level up is the workspace root.
__lambda_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SBX_WORKDIR="${SBX_WORKDIR:-$(dirname "$(dirname "$__lambda_dir")")}"
export SBX_WORKDIR

# shellcheck source=../_lib/common.sh disable=SC1091
source "${SBX_WORKDIR}/seed/_lib/common.sh"

# sbx_init validates SBX_REGION / SBX_SOURCE_ACCOUNT_ID / SBX_SEED_NAME_PREFIX
# (Requirement 20.10), parses --apply / --dry-run (Requirements 20.2, 20.4),
# and sets up the per-invocation log under ./seed/logs/.
sbx_init lambda "$@"

# Same-account contract (Requirement 20.28). Must run BEFORE any
# state-changing AWS CLI call. No-op when ./config/migration.config.json
# is absent; halts on mismatch.
sbx_assert_same_account

# Defense-in-depth re-check of the prefix. sbx_init has already required
# it, but a downstream `unset` would silently produce a name like
# `-fn-1`; rejecting empty here keeps that hypothetical from reaching AWS.
if [ -z "${SBX_SEED_NAME_PREFIX:-}" ]; then
    sbx_status missing_var SBX_SEED_NAME_PREFIX
    exit 64
fi

if ! command -v jq >/dev/null 2>&1; then
    sbx_status error jq_required
    exit 64
fi

# -----------------------------------------------------------------------------
# Module-level constants.
#
# Function sizing matches the Seed_Config_File defaults from design.md
# ("lambda": { "memory_mb": 128, "timeout_seconds": 30 }). Runtime is
# pinned to python3.11 because (a) it is currently in AWS-supported
# status across every seed-target region and (b) the inline payload is
# pure-stdlib and version-portable.
# -----------------------------------------------------------------------------

LAMBDA_RUNTIME="python3.11"
LAMBDA_MEMORY_MB="128"
LAMBDA_TIMEOUT_S="30"

LAMBDA_ROLE_NAME="${SBX_SEED_NAME_PREFIX}-lambda-exec-role"
LAMBDA_BASIC_EXEC_POLICY_ARN="arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"

LAMBDA_FN_1_NAME="${SBX_SEED_NAME_PREFIX}-fn-1"
LAMBDA_FN_2_NAME="${SBX_SEED_NAME_PREFIX}-fn-2"

# ZIP build location. Lives next to the source so `rm -rf dist/` is a
# safe local clean step.
LAMBDA_DIST_DIR="${__lambda_dir}/dist"
LAMBDA_ZIP_PATH="${LAMBDA_DIST_DIR}/lambda_function.zip"

# Inline Lambda trust policy. Pinned literal (single-line JSON) so the
# string passed to `--assume-role-policy-document` is shell-safe and
# byte-identical across re-runs.
LAMBDA_TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

# -----------------------------------------------------------------------------
# Helpers communicate ARNs back to `main` via globals rather than via
# stdout capture. Reason: the helpers also emit `STATUS:` /  `DRY-RUN:`
# lines on stdout, and `$(_helper)` would swallow those into the
# captured value. The same pattern is used by sns/create.sh.
# -----------------------------------------------------------------------------
__LAMBDA_OUT_ROLE_ARN=""
__LAMBDA_OUT_FN_ARN=""

# -----------------------------------------------------------------------------
# _build_zip
#
# Build (or rebuild) ${LAMBDA_ZIP_PATH} containing exactly one top-level
# file `lambda_function.py` whose `lambda_handler(event, context)` returns
# `{"statusCode": 200}`.
#
# In apply mode, requires the `zip` CLI. In dry-run mode the would-be
# `zip` command is printed and a placeholder is touched so any downstream
# existence check sees the path; the placeholder is never sent to AWS
# because sbx_aws short-circuits in dry-run.
# -----------------------------------------------------------------------------
_build_zip() {
    mkdir -p "$LAMBDA_DIST_DIR"

    local _src="${LAMBDA_DIST_DIR}/lambda_function.py"

    # Inline handler. Kept tiny on purpose: a Lambda inventory entry is
    # all we need for Requirement 20.20, and a trivial body keeps cold
    # starts and CloudWatch noise to a minimum. The PYEOF marker is
    # quoted so no shell expansion runs against the embedded docstring.
    cat > "$_src" <<'PYEOF'
"""Seed Lambda handler — returns a constant 200 response.

Used by both seed Lambda functions; the two functions share this same
payload so the Migration_Tool's inventory pass has two distinct
functions to enumerate while the seed ZIPs remain byte-identical.
"""


def lambda_handler(event, context):  # noqa: ARG001
    return {"statusCode": 200}
PYEOF

    if sbx_apply_mode; then
        if ! command -v zip >/dev/null 2>&1; then
            sbx_status error "zip command not found; required to build Lambda deployment package"
            exit 64
        fi
        # `zip -j` junks paths so the archive contains `lambda_function.py`
        # at the root, matching Lambda's `<file>.<func>` handler resolution.
        # `-q` keeps the run log readable; `-X` strips extra file
        # attributes (uid/gid/mtime metadata) so re-runs produce
        # byte-identical archives.
        rm -f "$LAMBDA_ZIP_PATH"
        zip -j -q -X "$LAMBDA_ZIP_PATH" "$_src"
        sbx_log "built deployment package ${LAMBDA_ZIP_PATH} from ${_src}"
    else
        sbx_dryrun "zip -j -q -X ${LAMBDA_ZIP_PATH} ${_src}"
        : > "$LAMBDA_ZIP_PATH"
    fi
}

# -----------------------------------------------------------------------------
# _role_exists
#
# Returns 0 iff `aws iam get-role --role-name ${LAMBDA_ROLE_NAME}` succeeds.
# IAM is a global service so the call carries no `--region`. In dry-run
# we conservatively return non-zero so the create path is exercised for
# operator review; the would-be create-role command is rendered through
# sbx_aws.
# -----------------------------------------------------------------------------
_role_exists() {
    if ! sbx_apply_mode; then
        return 1
    fi
    aws iam get-role --role-name "$LAMBDA_ROLE_NAME" >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# _ensure_role
#
# Idempotently provision ${LAMBDA_ROLE_NAME} with the Lambda trust policy
# and the AWSLambdaBasicExecutionRole managed policy attached. Writes
# the role ARN to __LAMBDA_OUT_ROLE_ARN.
#
# Apply-mode flow:
#
#   1. `aws iam get-role` — if hit, capture the ARN and proceed to step 3.
#   2. `aws iam create-role` with `--assume-role-policy-document` set
#      to the inline Lambda trust policy. Capture the ARN from the
#      response.
#   3. `aws iam attach-role-policy` for the basic-exec managed policy
#      (idempotent on the AWS side; re-attach is a 200 no-op).
#   4. Sleep ~10 s after a fresh create to let IAM propagate, otherwise
#      the immediately-following `aws lambda create-function` can fail
#      with `InvalidParameterValueException: The role defined for the
#      function cannot be assumed by Lambda`. Skipped on get-role hits.
#
# Dry-run flow:
#
#   1. Print `DRY-RUN: aws iam get-role ...` (read-only, harmless) via
#      sbx_aws so the run log shows the would-be probe.
#   2. Print the would-be create-role and attach-role-policy commands.
#   3. Synthesize a deterministic placeholder ARN built from the
#      configured account ID so the downstream create-function dry-run
#      output names a coherent role.
# -----------------------------------------------------------------------------
_ensure_role() {
    __LAMBDA_OUT_ROLE_ARN=""

    if _role_exists; then
        sbx_status ok "iam role ${LAMBDA_ROLE_NAME} already exists; skipping create"
        # apply-mode-only branch (sbx_apply_mode is true here because
        # _role_exists returns false in dry-run by construction).
        __LAMBDA_OUT_ROLE_ARN="$(aws iam get-role \
            --role-name "$LAMBDA_ROLE_NAME" \
            --query 'Role.Arn' \
            --output text)"
    else
        if sbx_apply_mode; then
            sbx_status action "aws iam create-role"
            __LAMBDA_OUT_ROLE_ARN="$(aws iam create-role \
                --role-name "$LAMBDA_ROLE_NAME" \
                --assume-role-policy-document "$LAMBDA_TRUST_POLICY" \
                --tags "Key=sbx:seed-name-prefix,Value=${SBX_SEED_NAME_PREFIX}" \
                --query 'Role.Arn' \
                --output text)"
            if [ -z "$__LAMBDA_OUT_ROLE_ARN" ] || [ "$__LAMBDA_OUT_ROLE_ARN" = "None" ]; then
                sbx_status error "create-role returned no ARN for ${LAMBDA_ROLE_NAME}"
                exit 1
            fi
            # IAM eventual-consistency: a freshly created role typically
            # takes a few seconds to be assumable by lambda.amazonaws.com.
            # Without the wait, the next create-function call frequently
            # fails. 10 s is the AWS-documented worst-case ceiling for
            # role propagation in most regions.
            sbx_log "waiting 10s for IAM role propagation"
            sleep 10
        else
            # Dry-run: render the would-be create-role command and
            # synthesize the deterministic ARN shape.
            sbx_aws iam create-role \
                --role-name "$LAMBDA_ROLE_NAME" \
                --assume-role-policy-document "$LAMBDA_TRUST_POLICY" \
                --tags "Key=sbx:seed-name-prefix,Value=${SBX_SEED_NAME_PREFIX}"
            __LAMBDA_OUT_ROLE_ARN="arn:aws:iam::${SBX_SOURCE_ACCOUNT_ID}:role/${LAMBDA_ROLE_NAME}"
        fi
    fi

    # Idempotent attach: AWS returns 200 even when the policy is already
    # attached, so we issue this on every run rather than gating it
    # behind a list-attached-role-policies probe. Cheaper and simpler.
    sbx_aws iam attach-role-policy \
        --role-name "$LAMBDA_ROLE_NAME" \
        --policy-arn "$LAMBDA_BASIC_EXEC_POLICY_ARN"
}

# -----------------------------------------------------------------------------
# _function_exists <name>
#
# Returns 0 iff `aws lambda get-function --function-name <name>` succeeds.
# Apply-mode-only check; in dry-run we always return non-zero so the
# create path is exercised for operator review.
# -----------------------------------------------------------------------------
_function_exists() {
    local _name="$1"
    if ! sbx_apply_mode; then
        return 1
    fi
    aws lambda get-function \
        --region "$SBX_REGION" \
        --function-name "$_name" >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# _ensure_function <name> <role-arn>
#
# Idempotent create-or-detect for a single Lambda function (Requirement
# 20.13). Writes the resulting function ARN to __LAMBDA_OUT_FN_ARN.
#
#   1. `aws lambda get-function` first.
#   2. If hit, record the existing ARN and return.
#   3. Otherwise `aws lambda create-function` with the shared
#      `lambda_function.zip`.
# -----------------------------------------------------------------------------
_ensure_function() {
    local _name="$1"
    local _role_arn="$2"
    __LAMBDA_OUT_FN_ARN=""

    if _function_exists "$_name"; then
        sbx_status ok "lambda function ${_name} already exists; skipping create"
        __LAMBDA_OUT_FN_ARN="$(aws lambda get-function \
            --region "$SBX_REGION" \
            --function-name "$_name" \
            --query 'Configuration.FunctionArn' \
            --output text)"
        return 0
    fi

    if sbx_apply_mode; then
        sbx_status action "aws lambda create-function"
        __LAMBDA_OUT_FN_ARN="$(aws lambda create-function \
            --region "$SBX_REGION" \
            --function-name "$_name" \
            --runtime "$LAMBDA_RUNTIME" \
            --role "$_role_arn" \
            --handler "lambda_function.lambda_handler" \
            --memory-size "$LAMBDA_MEMORY_MB" \
            --timeout "$LAMBDA_TIMEOUT_S" \
            --zip-file "fileb://${LAMBDA_ZIP_PATH}" \
            --tags "sbx:seed-name-prefix=${SBX_SEED_NAME_PREFIX}" \
            --query 'FunctionArn' \
            --output text)"
        if [ -z "$__LAMBDA_OUT_FN_ARN" ] || [ "$__LAMBDA_OUT_FN_ARN" = "None" ]; then
            sbx_status error "create-function returned no ARN for ${_name}"
            exit 1
        fi
    else
        sbx_aws lambda create-function \
            --region "$SBX_REGION" \
            --function-name "$_name" \
            --runtime "$LAMBDA_RUNTIME" \
            --role "$_role_arn" \
            --handler "lambda_function.lambda_handler" \
            --memory-size "$LAMBDA_MEMORY_MB" \
            --timeout "$LAMBDA_TIMEOUT_S" \
            --zip-file "fileb://${LAMBDA_ZIP_PATH}" \
            --tags "sbx:seed-name-prefix=${SBX_SEED_NAME_PREFIX}"
        __LAMBDA_OUT_FN_ARN="arn:aws:lambda:${SBX_REGION}:${SBX_SOURCE_ACCOUNT_ID}:function:${_name}"
    fi
}

# -----------------------------------------------------------------------------
# _persist_state <role-arn> <fn-1-arn> <fn-2-arn>
#
# Atomic deep-merge into .services.lambda. Per Requirement 20.12 this
# runs BEFORE the next state-changing AWS CLI call. Within this script
# the only "next" state-changing call after the last create-function is
# the orchestrator's NEXT module's create.sh (cloudwatch), so writing
# once at the end of provisioning meets the contract.
#
# Bug fix 1a: state writes happen ONLY in apply mode. In dry-run no AWS
# resource was actually created, so persisting status="provisioned"
# would mis-report the run. Dry-run instead emits a `STATUS: set` with
# the placeholder ARNs and skips the persistent write.
# -----------------------------------------------------------------------------
_persist_state() {
    local _role_arn="$1"
    local _fn_1_arn="$2"
    local _fn_2_arn="$3"

    if ! sbx_apply_mode; then
        sbx_log "dry-run: skipping state write (would record .services.lambda.status=provisioned with role=${_role_arn})"
        return 0
    fi

    local _payload
    _payload="$(jq -n \
        --arg role_arn "$_role_arn" \
        --arg fn1 "$_fn_1_arn" \
        --arg fn2 "$_fn_2_arn" \
        '{status: "provisioned", role_arn: $role_arn, function_arns: [$fn1, $fn2]}')"

    sbx_state_set_service lambda "$_payload"
    sbx_status set "lambda.role_arn=${_role_arn}"
    sbx_status set "lambda.function_arns=[${_fn_1_arn}, ${_fn_2_arn}]"
}

# -----------------------------------------------------------------------------
# Main.
# -----------------------------------------------------------------------------
main() {
    sbx_status started

    sbx_log "lambda module: region=${SBX_REGION}, prefix=${SBX_SEED_NAME_PREFIX}, mode=$([ "${SBX_APPLY:-}" = "1" ] && echo apply || echo dry-run)"

    _build_zip

    _ensure_role
    local _role_arn="$__LAMBDA_OUT_ROLE_ARN"

    _ensure_function "$LAMBDA_FN_1_NAME" "$_role_arn"
    local _fn_1_arn="$__LAMBDA_OUT_FN_ARN"

    _ensure_function "$LAMBDA_FN_2_NAME" "$_role_arn"
    local _fn_2_arn="$__LAMBDA_OUT_FN_ARN"

    _persist_state "$_role_arn" "$_fn_1_arn" "$_fn_2_arn"

    sbx_status ok "lambda module complete: role=${LAMBDA_ROLE_NAME}, functions=(${LAMBDA_FN_1_NAME}, ${LAMBDA_FN_2_NAME})"
}

main "$@"
