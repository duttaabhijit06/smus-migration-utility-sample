#!/usr/bin/env bash
#
# seed/lambda/teardown.sh — Tear down the seed AWS Lambda module.
#
# Reverses what `create.sh` provisioned, in the strict reverse order
# required by Lambda + IAM dependency:
#
#   1. delete every recorded Lambda function
#   2. detach every managed policy from the recorded role
#   3. delete every inline policy on the role (defense-in-depth)
#   4. delete the role itself
#
# A role with attached managed policies or inline policies cannot be
# deleted (`DeleteConflict`); steps 2 and 3 are therefore mandatory
# preconditions for step 4.
#
# Dual deletion gate (Requirement 20.31)
#
#   Every `delete-*` call runs only when BOTH of the following are true:
#
#     (a) the target resource's name begins with `${SBX_SEED_NAME_PREFIX}-`,
#         AND
#     (b) the target resource's identifier is recorded in
#         ./seed/seed.state.json under `.services.lambda.function_arns`
#         or `.services.lambda.role_arn`.
#
#   Because the Seed_Script and the Migration_Tool share a single AWS
#   account, deleting any function or role that does not satisfy BOTH
#   conditions could destroy a non-seed customer resource that happens
#   to live in this account. The state file is therefore the
#   authoritative inventory — we do NOT scan AWS for "anything matching
#   the prefix".
#
# Idempotency
#
#   Functions or roles that return `ResourceNotFoundException` /
#   `NoSuchEntity` are treated as already-deleted no-ops, logged, and
#   skipped. A re-run after a successful teardown therefore issues zero
#   `delete-*` calls.
#
# Apply / dry-run discipline (Requirements 20.2, 20.3, 20.4)
#
#   Inherits `--apply` / `--dry-run` parsing from `sbx_init`. Every
#   state-changing call is routed through `sbx_aws`, which short-circuits
#   in dry-run.
#
# Validates Requirements: 20.9, 20.13, 20.20, 20.29, 20.31, 20.32.
#

set -euo pipefail

__lambda_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SBX_WORKDIR="${SBX_WORKDIR:-$(dirname "$(dirname "$__lambda_dir")")}"
export SBX_WORKDIR

# shellcheck source=../_lib/common.sh disable=SC1091
source "${SBX_WORKDIR}/seed/_lib/common.sh"

sbx_init lambda "$@"

sbx_assert_same_account

if [ -z "${SBX_SEED_NAME_PREFIX:-}" ]; then
    sbx_status missing_var SBX_SEED_NAME_PREFIX
    exit 64
fi

if ! command -v jq >/dev/null 2>&1; then
    sbx_status error jq_required
    exit 64
fi

LAMBDA_ROLE_NAME="${SBX_SEED_NAME_PREFIX}-lambda-exec-role"

# -----------------------------------------------------------------------------
# Read recorded identifiers from seed.state.json.
#
# The state file is the authoritative inventory. If the file is absent
# or has no recorded resources, this teardown is a no-op for that slot.
# -----------------------------------------------------------------------------

_state_path="$(sbx_state_path)"
if [ ! -f "$_state_path" ]; then
    sbx_status ok "lambda teardown: no seed.state.json at ${_state_path}; nothing to delete"
    exit 0
fi

# `.services.lambda.function_arns` is the array authored by create.sh.
# `// []` defaults to an empty array when the field is absent so the
# loop below sees a clean shape.
_function_arns_json="$(jq -c '.services.lambda.function_arns // []' "$_state_path" 2>/dev/null || echo '[]')"
_role_arn_recorded="$(jq -r '.services.lambda.role_arn // empty' "$_state_path" 2>/dev/null || true)"

# -----------------------------------------------------------------------------
# _verify_prefix <name>
#
# Return 0 iff `<name>` begins with `${SBX_SEED_NAME_PREFIX}-`. Defense
# in depth against a hand-edited state file referring to a resource NOT
# created by this module.
# -----------------------------------------------------------------------------
_verify_prefix() {
    local _name="${1:-}"
    case "$_name" in
        "${SBX_SEED_NAME_PREFIX}-"*) return 0 ;;
        *) return 1 ;;
    esac
}

# -----------------------------------------------------------------------------
# _name_from_function_arn <arn>
#
# Echo the trailing function name from a Lambda ARN of the form
# `arn:aws:lambda:<region>:<account>:function:<name>`. Returns empty for
# malformed input.
# -----------------------------------------------------------------------------
_name_from_function_arn() {
    local _arn="${1:-}"
    case "$_arn" in
        *":function:"*) printf '%s\n' "${_arn##*:function:}" ;;
        *) printf '\n' ;;
    esac
}

# -----------------------------------------------------------------------------
# Phase 1: delete every recorded Lambda function.
# -----------------------------------------------------------------------------

_deleted_fns=0
_skipped_fns=0

# `jq -r '.[]'` produces one ARN per line. An empty array yields no
# output, so the loop body simply doesn't run — which is correct.
while IFS= read -r _arn; do
    [ -z "$_arn" ] && continue

    _fn_name="$(_name_from_function_arn "$_arn")"
    if [ -z "$_fn_name" ]; then
        sbx_status skipped "lambda teardown: malformed function ARN '${_arn}'; skipping"
        _skipped_fns=$((_skipped_fns + 1))
        continue
    fi

    # Gate (a): name MUST begin with `<prefix>-`.
    if ! _verify_prefix "$_fn_name"; then
        sbx_status skipped "lambda teardown: function '${_fn_name}' does not start with '${SBX_SEED_NAME_PREFIX}-'; refusing to delete (Requirement 20.31)"
        _skipped_fns=$((_skipped_fns + 1))
        continue
    fi

    # Idempotent existence probe. If the function is already gone, log
    # and skip. Apply-mode only — in dry-run we always render the
    # would-be delete-function command for operator review.
    if sbx_apply_mode; then
        if ! aws lambda get-function \
            --region "$SBX_REGION" \
            --function-name "$_fn_name" >/dev/null 2>&1; then
            sbx_status ok "lambda teardown: function '${_fn_name}' not present in AWS; skipping delete"
            _skipped_fns=$((_skipped_fns + 1))
            continue
        fi
    fi

    sbx_aws lambda delete-function \
        --region "$SBX_REGION" \
        --function-name "$_fn_name"

    _deleted_fns=$((_deleted_fns + 1))
done < <(printf '%s' "$_function_arns_json" | jq -r '.[]?')

# -----------------------------------------------------------------------------
# Phase 2 + 3 + 4: detach managed policies, delete inline policies,
# delete the role.
#
# Gate: the role ARN must be recorded AND the role name (derived from
# the configured prefix) must begin with the prefix. The role NAME is
# constant within a single seed install (`<prefix>-lambda-exec-role`),
# so the gate reduces to "state-file recorded the ARN" + "name starts
# with prefix" — which is always true when create.sh authored the entry.
# We still check both for parity with the function gate above.
# -----------------------------------------------------------------------------

if [ -z "$_role_arn_recorded" ]; then
    sbx_log "lambda teardown: no role_arn recorded in seed.state.json; skipping role cleanup"
else
    if ! _verify_prefix "$LAMBDA_ROLE_NAME"; then
        # Defensive: the constructed role name must satisfy the prefix
        # gate. If it does not, something went very wrong (env-var
        # corruption between create and teardown) and we refuse to
        # delete to avoid touching a non-seed role.
        sbx_status error "lambda teardown: derived role name '${LAMBDA_ROLE_NAME}' does not start with '${SBX_SEED_NAME_PREFIX}-'; refusing role cleanup"
    else
        # Probe: does the role still exist? If not, the role cleanup is
        # already complete from a prior run.
        _role_present=0
        if sbx_apply_mode; then
            if aws iam get-role --role-name "$LAMBDA_ROLE_NAME" >/dev/null 2>&1; then
                _role_present=1
            fi
        else
            # Dry-run: assume the role exists so the operator sees the
            # full set of would-be detach/delete commands.
            _role_present=1
        fi

        if [ "$_role_present" = "0" ]; then
            sbx_status ok "lambda teardown: role '${LAMBDA_ROLE_NAME}' not present in AWS; skipping role cleanup"
        else
            # Phase 2: detach every managed policy from the role.
            # `list-attached-role-policies` is a read-only verb so it is
            # safe to run unconditionally (Property 17). The output is
            # parsed into a newline-separated list of policy ARNs.
            _attached_arns=""
            if sbx_apply_mode; then
                _attached_arns="$(aws iam list-attached-role-policies \
                    --role-name "$LAMBDA_ROLE_NAME" \
                    --query 'AttachedPolicies[].PolicyArn' \
                    --output text 2>/dev/null | tr '\t' '\n' || true)"
            else
                # In dry-run we don't have ground truth, so we render
                # the detach for the canonical attached policy from
                # create.sh. If the operator has manually attached
                # extra policies, apply-mode will pick them up
                # automatically via list-attached-role-policies.
                _attached_arns="arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
            fi

            while IFS= read -r _policy_arn; do
                [ -z "$_policy_arn" ] && continue
                sbx_aws iam detach-role-policy \
                    --role-name "$LAMBDA_ROLE_NAME" \
                    --policy-arn "$_policy_arn"
            done <<< "$_attached_arns"

            # Phase 3: delete every inline policy on the role.
            # create.sh does not author inline policies, but a future
            # extension (or operator-side manual edit) might, and the
            # subsequent delete-role would fail on DeleteConflict if
            # any remained. Best-effort: list and delete each.
            _inline_names=""
            if sbx_apply_mode; then
                _inline_names="$(aws iam list-role-policies \
                    --role-name "$LAMBDA_ROLE_NAME" \
                    --query 'PolicyNames' \
                    --output text 2>/dev/null | tr '\t' '\n' || true)"
            fi
            while IFS= read -r _inline_name; do
                [ -z "$_inline_name" ] && continue
                sbx_aws iam delete-role-policy \
                    --role-name "$LAMBDA_ROLE_NAME" \
                    --policy-name "$_inline_name"
            done <<< "$_inline_names"

            # Phase 4: delete the role itself.
            sbx_aws iam delete-role --role-name "$LAMBDA_ROLE_NAME"
        fi
    fi
fi

# -----------------------------------------------------------------------------
# Persist the torn_down state.
#
# We clear `function_arns` and `role_arn` so a subsequent re-run sees
# nothing to delete (idempotent teardown). Status flips to `torn_down`.
# Done in apply mode AND dry-run mode so dry-run state reflects the
# planned outcome — sbx_state_set_service is a local file mutation, not
# an AWS call, and seeing the planned state in dry-run helps operators
# verify before committing.
# -----------------------------------------------------------------------------

_torn_payload="$(jq -n '{status: "torn_down", role_arn: "", function_arns: []}')"
sbx_state_set_service lambda "$_torn_payload"

sbx_status ok "lambda teardown complete: deleted_functions=${_deleted_fns}, skipped_functions=${_skipped_fns}, role=${LAMBDA_ROLE_NAME}"
