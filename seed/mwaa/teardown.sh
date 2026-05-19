#!/usr/bin/env bash
#
# seed/mwaa/teardown.sh — Amazon MWAA Seed_Service_Module teardown.sh.
#
# Task 24.12 / Requirements 20.5, 20.6, 20.13, 20.31.
#
# Removes the MWAA environment created by ./create.sh and the DAG bucket
# that backs it. Teardown is the strict reverse of create:
#
#   1. aws mwaa delete-environment      (long pole — typically minutes)
#   2. aws s3 rb --force                (empty + delete the DAG bucket)
#
# Safety (Requirement 20.31):
#   - Only resources whose name begins with `${SBX_SEED_NAME_PREFIX}-`
#     AND whose identifier is recorded in `./seed/seed.state.json` under
#     `services.mwaa.resources` are eligible for deletion. Anything else
#     is left alone — the seed account may host non-seed customer
#     resources, and an accidental teardown there could destroy data the
#     seed was never authorised to touch.
#   - Dry-run prints the would-be commands via sbx_aws (DRY-RUN: prefix)
#     and changes nothing in AWS.
#   - Apply mode requires the operator to have already typed the
#     seed_name_prefix at the top-level provision.sh / teardown.sh prompt
#     (Requirement 20.6); this per-service script does NOT re-prompt.
#

# shellcheck source=../_lib/common.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SBX_WORKDIR="${SBX_WORKDIR:-$(dirname "$(dirname "$SCRIPT_DIR")")}"
export SBX_WORKDIR
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../_lib/common.sh"

set -euo pipefail

# Bootstrap the three core SBX_* env vars from seed.config.json when this
# script is invoked directly. The top-level seed/teardown.sh wrapper
# already exports these.
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

sbx_init "mwaa" "$@"
sbx_assert_same_account
sbx_status started

REGION="${SBX_REGION}"
PREFIX="${SBX_SEED_NAME_PREFIX}"

# -----------------------------------------------------------------------------
# Read the state file. ONLY resources recorded here AND prefixed with
# `${PREFIX}-` are eligible for deletion (Requirement 20.31). Field shape
# matches the flat layout written by create.sh:
#
#   .services.mwaa.resources.environment_name
#   .services.mwaa.resources.dag_bucket
# -----------------------------------------------------------------------------

ENV_NAME="$(sbx_state_get '.services.mwaa.resources.environment_name')"
DAG_BUCKET="$(sbx_state_get '.services.mwaa.resources.dag_bucket')"

if [ -z "$ENV_NAME" ] && [ -z "$DAG_BUCKET" ]; then
    sbx_status ok "nothing to tear down: services.mwaa.resources is empty in $(sbx_state_path)"
    exit 0
fi

# Prefix gate: refuse to act on any name that does not start with
# `${PREFIX}-`. This is the second line of defence behind the state-file
# gate above.
prefix_check() {
    local name="${1:-}"
    local kind="${2:-resource}"
    if [ -z "$name" ]; then
        return 1
    fi
    case "$name" in
        "${PREFIX}-"*) return 0 ;;
        *)
            sbx_status error "${kind} ${name} does not start with seed prefix ${PREFIX}-; refusing to delete"
            return 1
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Step 1. Delete the MWAA environment.
#
# `aws mwaa delete-environment` is itself a long-running operation; we do
# NOT wait for the environment to fully drop here, because the next step
# (`aws s3 rb` on the DAG bucket) does not depend on the environment
# being gone — MWAA does not hold a reference to the bucket once delete
# is initiated. A subsequent re-run of teardown is idempotent: get-
# environment will return NotFound and the script skips.
# -----------------------------------------------------------------------------

if [ -n "$ENV_NAME" ]; then
    if prefix_check "$ENV_NAME" "MWAA environment"; then
        sbx_log "step 1/2: delete MWAA environment ${ENV_NAME}"
        if sbx_apply_mode; then
            set +e
            aws mwaa get-environment --name "$ENV_NAME" --region "$REGION" >/dev/null 2>&1
            GE_RC=$?
            set -e
            if [ "$GE_RC" -eq 0 ]; then
                sbx_aws mwaa delete-environment --name "$ENV_NAME" --region "$REGION"
                sbx_log "delete-environment submitted; environment teardown can take several minutes"
            else
                sbx_log "MWAA environment ${ENV_NAME} not found; skipping delete"
            fi
        else
            sbx_aws mwaa get-environment --name "$ENV_NAME" --region "$REGION"
            sbx_aws mwaa delete-environment --name "$ENV_NAME" --region "$REGION"
        fi
    fi
else
    sbx_log "step 1/2: skipped (no environment name in state)"
fi

# -----------------------------------------------------------------------------
# Step 2. Empty + delete the DAG bucket via the two-call form the task
# 24.12 contract pins:
#
#   aws s3 rm s3://<bucket> --recursive    # empty current versions
#   aws s3api delete-bucket --bucket <bucket>  # remove the empty bucket
#
# create.sh enables S3 Versioning on the DAG bucket (MWAA requires it),
# so `aws s3 rm --recursive` alone does NOT remove non-current versions
# or delete markers — `aws s3api delete-bucket` would then fail with
# `BucketNotEmpty`. We therefore purge non-current versions and delete
# markers via `aws s3api delete-objects` BEFORE the `s3 rm` step. On an
# unversioned bucket the version listing is empty and the purge is a
# no-op, so the same teardown works against either bucket shape.
# -----------------------------------------------------------------------------

if [ -n "$DAG_BUCKET" ]; then
    if prefix_check "$DAG_BUCKET" "DAG bucket"; then
        sbx_log "step 2/2: empty + delete DAG bucket s3://${DAG_BUCKET}"
        if sbx_apply_mode; then
            set +e
            aws s3api head-bucket --bucket "$DAG_BUCKET" --region "$REGION" >/dev/null 2>&1
            HB_RC=$?
            set -e
            if [ "$HB_RC" -eq 0 ]; then
                # Purge non-current versions and delete markers so the
                # subsequent `aws s3api delete-bucket` succeeds. On an
                # unversioned bucket the list returns an empty payload
                # and this loop is a no-op.
                set +e
                VERSIONS_JSON="$(aws s3api list-object-versions --bucket "$DAG_BUCKET" --region "$REGION" --output json 2>/dev/null)"
                LV_RC=$?
                set -e
                if [ "$LV_RC" -eq 0 ] && [ -n "$VERSIONS_JSON" ]; then
                    DEL_PAYLOAD="$(printf '%s' "$VERSIONS_JSON" | jq -c '
                        {Objects: ([(.Versions // [])[], (.DeleteMarkers // [])[]]
                                   | map({Key: .Key, VersionId: .VersionId})),
                         Quiet: true}')"
                    OBJ_COUNT="$(printf '%s' "$DEL_PAYLOAD" | jq -r '.Objects | length')"
                    if [ "${OBJ_COUNT:-0}" -gt 0 ]; then
                        sbx_aws s3api delete-objects \
                            --bucket "$DAG_BUCKET" \
                            --region "$REGION" \
                            --delete "$DEL_PAYLOAD"
                    fi
                fi
                # Empty all current-version objects (recursive). On a
                # bucket with only versioned non-current objects this
                # is a no-op; on a bucket with current objects it is
                # the canonical "empty bucket" CLI form.
                sbx_aws s3 rm "s3://${DAG_BUCKET}" --recursive --region "$REGION"
                # Finally delete the now-empty bucket.
                sbx_aws s3api delete-bucket --bucket "$DAG_BUCKET" --region "$REGION"
            else
                sbx_log "DAG bucket s3://${DAG_BUCKET} not found; skipping delete"
            fi
        else
            sbx_aws s3api head-bucket --bucket "$DAG_BUCKET" --region "$REGION"
            sbx_aws s3api list-object-versions --bucket "$DAG_BUCKET" --region "$REGION"
            sbx_aws s3 rm "s3://${DAG_BUCKET}" --recursive --region "$REGION"
            sbx_aws s3api delete-bucket --bucket "$DAG_BUCKET" --region "$REGION"
        fi
    fi
else
    sbx_log "step 2/2: skipped (no DAG bucket name in state)"
fi

# -----------------------------------------------------------------------------
# Step 3. Delete the IAM execution role.
#
# IMPORTANT: `aws mwaa delete-environment` is ASYNC — the call returns
# immediately and the environment continues tearing down in the
# background, often for several minutes. While the environment is
# still in the DELETING state it holds a reference to the execution
# role and `aws iam delete-role` will fail with `DeleteConflict`
# (RoleHasAssociatedResources or similar).
#
# This step is therefore BEST EFFORT: we attempt the role deletion
# anyway because the environment may already be gone (e.g. on a re-run
# of teardown), but we do NOT wait for it. Failures here are logged
# and the script continues with the torn_down state write so a
# follow-up `bash seed/teardown.sh --apply` can sweep up the role
# once MWAA has fully released it. Operators may need to retry
# teardown after MWAA finishes its async drop (typically 5–10 min).
#
# Pattern mirrors seed/lambda/teardown.sh:
#   1. list-attached-role-policies → detach each
#   2. list-role-policies → delete each inline
#   3. delete-role
#   4. NoSuchEntity → idempotent skip
#
# Gate (Requirement 20.31): role NAME must begin with the seed prefix
# AND its ARN must be recorded in seed.state.json under
# `.services.mwaa.resources.execution_role_arn`.
# -----------------------------------------------------------------------------

EXEC_ROLE_ARN="$(sbx_state_get '.services.mwaa.resources.execution_role_arn')"
ROLE_NAME="${PREFIX}-mwaa-exec-role"

if [ -n "$EXEC_ROLE_ARN" ] && prefix_check "$ROLE_NAME" "MWAA execution role"; then
    sbx_log "step 3/3: best-effort delete of IAM role ${ROLE_NAME} (delete-environment is async; role may still be in use)"

    # Probe: does the role still exist?
    role_present=0
    if sbx_apply_mode; then
        if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
            role_present=1
        fi
    else
        role_present=1
    fi

    if [ "$role_present" = "0" ]; then
        sbx_log "iam role ${ROLE_NAME} not present in AWS; skipping role cleanup"
    else
        # Phase A: detach managed policies. The mwaa role is created
        # WITHOUT any managed policy (the canonical mwaa-exec policy is
        # inline), but we still query in apply mode so an operator-
        # attached policy doesn't block delete-role.
        attached_arns=""
        if sbx_apply_mode; then
            attached_arns="$(aws iam list-attached-role-policies \
                --role-name "$ROLE_NAME" \
                --query 'AttachedPolicies[].PolicyArn' \
                --output text 2>/dev/null | tr '\t' '\n' || true)"
        fi
        while IFS= read -r policy_arn; do
            [ -z "$policy_arn" ] && continue
            sbx_status action "detach-role-policy ${ROLE_NAME} ${policy_arn}"
            if ! sbx_aws iam detach-role-policy \
                    --role-name "$ROLE_NAME" \
                    --policy-arn "$policy_arn"; then
                sbx_log "warning: detach-role-policy failed for ${ROLE_NAME} ${policy_arn}; continuing"
            fi
        done <<< "$attached_arns"

        # Phase B: delete inline policies. The canonical inline policy
        # create.sh writes is `mwaa-exec`.
        inline_names=""
        if sbx_apply_mode; then
            inline_names="$(aws iam list-role-policies \
                --role-name "$ROLE_NAME" \
                --query 'PolicyNames' \
                --output text 2>/dev/null | tr '\t' '\n' || true)"
        else
            inline_names="mwaa-exec"
        fi
        while IFS= read -r inline_name; do
            [ -z "$inline_name" ] && continue
            sbx_status action "delete-role-policy ${ROLE_NAME} ${inline_name}"
            if ! sbx_aws iam delete-role-policy \
                    --role-name "$ROLE_NAME" \
                    --policy-name "$inline_name"; then
                sbx_log "warning: delete-role-policy failed for ${ROLE_NAME} ${inline_name}; continuing"
            fi
        done <<< "$inline_names"

        # Phase C: delete the role. Best effort — DeleteConflict here
        # typically means MWAA is still finishing its async environment
        # drop. The operator can re-run teardown to clean up.
        sbx_status action "delete-role ${ROLE_NAME}"
        if sbx_apply_mode; then
            if ! aws iam delete-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
                if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
                    sbx_log "warning: delete-role failed for ${ROLE_NAME} (likely still referenced by an in-progress MWAA environment delete); re-run 'bash seed/teardown.sh --apply' after MWAA finishes its async drop (typically 5–10 min)"
                else
                    sbx_log "iam role ${ROLE_NAME} no longer exists after detach; treating as deleted"
                fi
            fi
        else
            sbx_aws iam delete-role --role-name "$ROLE_NAME"
        fi
    fi
elif [ -z "$EXEC_ROLE_ARN" ]; then
    sbx_log "step 3/3: skipped (no execution_role_arn in state)"
fi

# -----------------------------------------------------------------------------
# Mark torn_down in state (Requirement 20.12). Resource identifiers are
# left intact so a subsequent operator can audit what was provisioned.
# -----------------------------------------------------------------------------

sbx_state_set_service "mwaa" '{"status":"torn_down"}'
sbx_log "marked services.mwaa.status = torn_down in $(sbx_state_path)"

sbx_status ok
exit 0
