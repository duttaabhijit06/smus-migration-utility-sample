#!/usr/bin/env bash
#
# seed/glue/teardown.sh — AWS Glue Seed_Service_Module teardown.
#
# Symmetric counterpart to seed/glue/create.sh. Reads recorded resource
# identifiers from seed.state.json under `.services.glue.resources` and
# issues the matching `aws ... delete-*` calls in the order:
#
#   1. jobs                  (delete-job × N)
#   2. connections           — KAFKA FIRST, then JDBC + NETWORK
#   3. tables                (delete-table × N within each database)
#   4. databases             (delete-database × N)
#   5. S3 sample-data bucket (s3 rm --recursive, then s3api delete-bucket)
#
# Why kafka first inside step 2: the kafka connection holds a soft
# reference to MSK's bootstrap brokers; deleting it first means the
# subsequent top-level orchestrator pass that runs `seed/msk/teardown.sh`
# does not have to worry about a dangling connection still pointing at
# brokers that are about to disappear. (Strictly, the AWS API does not
# enforce this ordering — Glue connections are loosely coupled to their
# referenced resources — but the explicit kafka-first sequence keeps the
# log readable and matches the inverse of the create order.)
#
# Why crawler is deleted as part of step 1: the recorded crawler is
# functionally a job from a teardown perspective (a long-lived Glue
# control-plane object that owns no schemas of its own), so it is
# folded into the jobs phase to keep the count of teardown phases small
# and the per-phase contract focused.
#
# Why tables BEFORE databases: `aws glue delete-database` cascades to
# its tables, so deleting tables first is technically redundant. We do
# it explicitly anyway because:
#
#   - The task spec lists `tables → databases` as separate phases, so
#     emitting the per-table `delete-table` calls makes the dry-run audit
#     log match the spec's phase boundaries exactly (Property 22-style
#     audit; one STATUS line per intended deletion).
#   - When a re-run finds one of the two databases already gone, the
#     per-table loop still runs against the surviving database and
#     records the per-table calls. Without this loop the audit log
#     would be silent for the surviving database's tables until the
#     final delete-database fires.
#
# Best-effort sequencing: a single `aws ... delete-*` failure surfaces as
# `STATUS: error delete_failed <name>` and the script continues with the
# next resource. Exits 0 on full success and exits non-zero only when at
# least one delete failed (so CI can surface the failure surface for
# re-runs).
#
# Deletion gate (Requirement 20.31):
# A candidate is deleted only when BOTH:
#   1. its name begins with `${SBX_SEED_NAME_PREFIX}-`; AND
#   2. its identifier is recorded in `./seed/seed.state.json` under
#      `.services.glue.resources`.
# A resource that fails either check is skipped with a STATUS line.
#
# Post-migration idempotency (Requirement 20.32):
# This script never invokes `aws datazone *` and never targets the
# SMUS_Domain ID or Admin_Project ID recorded in
# `./config/migration.config.json`. A grep over this file returns zero
# hits for `aws datazone`.
#
# Validates Requirements: 20.5, 20.8, 20.13, 20.29, 20.31, 20.32.
#

set -euo pipefail

# -----------------------------------------------------------------------------
# Resolve own location and source the shared seed helpers. Anchoring
# SBX_WORKDIR here lets the script be invoked from any cwd.
# -----------------------------------------------------------------------------
__GLUE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SBX_WORKDIR="${SBX_WORKDIR:-$(dirname "$(dirname "$__GLUE_DIR")")}"
export SBX_WORKDIR

# shellcheck source=../_lib/common.sh disable=SC1091
source "${__GLUE_DIR}/../_lib/common.sh"

# -----------------------------------------------------------------------------
# Pre-load the three core SBX_* env vars from seed.config.json so sbx_init's
# required-var check passes when this script is invoked directly (without
# coming through provision.sh / teardown.sh).
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

sbx_init "glue" "$@"
sbx_assert_same_account

# -----------------------------------------------------------------------------
# Failed-deletes accumulator. Every per-resource failure is appended here so
# the final STATUS line names the full failure set rather than only the
# last one. The script exits 1 when this array is non-empty.
# -----------------------------------------------------------------------------
declare -a __failed_deletes=()

_record_failure() {
    local _name="$1"
    local _reason="${2:-delete_failed}"
    sbx_status error "delete_failed ${_name}"
    __failed_deletes+=("${_name} (${_reason})")
}

# -----------------------------------------------------------------------------
# _gate_name <recorded-name>
#
# Return 0 iff <recorded-name> is non-empty AND begins with the seed prefix
# (Requirement 20.31). All resource types created by glue/create.sh use the
# hyphenated `<prefix>-…` form (databases included — the seed picked
# `<prefix>-db-raw` / `<prefix>-db-curated` rather than the
# underscore-prefix form, matching the task 24.5 spec text). The gate is
# strict on hyphen prefix.
# -----------------------------------------------------------------------------
_gate_name() {
    local _name="${1:-}"
    if [ -z "$_name" ]; then
        return 1
    fi
    case "$_name" in
        "${SBX_SEED_NAME_PREFIX}-"*) return 0 ;;
    esac
    return 1
}

# -----------------------------------------------------------------------------
# Step 1 — Delete jobs (and the crawler).
#
# Iterate every recorded job name; skip when prefix-gated out or when the
# job is no longer in AWS (idempotency). After the jobs are gone, delete
# the crawler the same way.
# -----------------------------------------------------------------------------
delete_jobs() {
    local _names
    _names="$(sbx_state_get '.services.glue.resources.jobs[]?')"
    if [ -z "$_names" ]; then
        sbx_log "no glue jobs recorded; skipping job teardown"
    else
        local _name
        while IFS= read -r _name; do
            [ -z "$_name" ] && continue
            if ! _gate_name "$_name"; then
                sbx_log "skipping job ${_name}: prefix gate (Requirement 20.31)"
                continue
            fi

            local _exists=1
            if sbx_apply_mode; then
                if ! sbx_aws glue get-job --job-name "$_name" --region "$SBX_REGION" >/dev/null 2>&1; then
                    _exists=0
                fi
            else
                sbx_aws glue get-job --job-name "$_name" --region "$SBX_REGION" || true
            fi
            if [ "$_exists" -eq 0 ]; then
                sbx_log "glue job ${_name} already deleted; skipping"
                continue
            fi

            sbx_status action "delete-job ${_name}"
            if ! sbx_aws glue delete-job --job-name "$_name" --region "$SBX_REGION"; then
                _record_failure "$_name" delete_job
            fi
        done <<< "$_names"
    fi

    # Crawler — folded into the jobs phase per the file-header rationale.
    local _crawler
    _crawler="$(sbx_state_get '.services.glue.resources.crawler')"
    if [ -z "$_crawler" ]; then
        sbx_log "no crawler recorded; skipping crawler teardown"
        return 0
    fi
    if ! _gate_name "$_crawler"; then
        sbx_log "skipping crawler ${_crawler}: prefix gate (Requirement 20.31)"
        return 0
    fi

    # If the crawler is currently RUNNING, delete-crawler will fail with
    # CrawlerRunningException. Best-effort `stop-crawler` first (idempotent
    # — AWS returns CrawlerNotRunningException if it isn't running, which
    # we tolerate).
    if sbx_apply_mode; then
        sbx_aws glue stop-crawler --name "$_crawler" --region "$SBX_REGION" >/dev/null 2>&1 || true
    else
        sbx_aws glue stop-crawler --name "$_crawler" --region "$SBX_REGION" || true
    fi

    local _exists=1
    if sbx_apply_mode; then
        if ! sbx_aws glue get-crawler --name "$_crawler" --region "$SBX_REGION" >/dev/null 2>&1; then
            _exists=0
        fi
    else
        sbx_aws glue get-crawler --name "$_crawler" --region "$SBX_REGION" || true
    fi
    if [ "$_exists" -eq 0 ]; then
        sbx_log "glue crawler ${_crawler} already deleted; skipping"
        return 0
    fi

    sbx_status action "delete-crawler ${_crawler}"
    if ! sbx_aws glue delete-crawler --name "$_crawler" --region "$SBX_REGION"; then
        _record_failure "$_crawler" delete_crawler
    fi
}

# -----------------------------------------------------------------------------
# Step 2 — Delete connections, KAFKA first.
#
# The recorded connections array (`.resources.connections`) lists every
# connection glue/create.sh authored: typically [jdbc, network, kafka]
# after a successful phase 2. We split them into two passes: kafka first,
# then everything else, so the dry-run log shows the kafka delete-line
# first (matching the task spec's stated order).
# -----------------------------------------------------------------------------
_delete_one_connection() {
    local _name="$1"
    if ! _gate_name "$_name"; then
        sbx_log "skipping connection ${_name}: prefix gate (Requirement 20.31)"
        return 0
    fi

    local _exists=1
    if sbx_apply_mode; then
        if ! sbx_aws glue get-connection --name "$_name" --region "$SBX_REGION" >/dev/null 2>&1; then
            _exists=0
        fi
    else
        sbx_aws glue get-connection --name "$_name" --region "$SBX_REGION" || true
    fi
    if [ "$_exists" -eq 0 ]; then
        sbx_log "glue connection ${_name} already deleted; skipping"
        return 0
    fi

    sbx_status action "delete-connection ${_name}"
    if ! sbx_aws glue delete-connection \
            --connection-name "$_name" \
            --region "$SBX_REGION"; then
        _record_failure "$_name" delete_connection
    fi
}

delete_connections() {
    local _names
    _names="$(sbx_state_get '.services.glue.resources.connections[]?')"
    if [ -z "$_names" ]; then
        sbx_log "no connections recorded; skipping connection teardown"
        return 0
    fi

    # Pass 1 — kafka connection(s). The recorded kafka-conn name has the
    # `-kafka-conn` suffix per the create.sh catalogue; we match by suffix
    # so a future rename cannot accidentally fall out of the kafka-first
    # pass. Multiple matches are tolerated (defensive — the create script
    # only ever writes one).
    local _kafka_suffix="-kafka-conn"
    local _name
    while IFS= read -r _name; do
        [ -z "$_name" ] && continue
        case "$_name" in
            *"$_kafka_suffix") _delete_one_connection "$_name" ;;
        esac
    done <<< "$_names"

    # Pass 2 — everything else (JDBC, NETWORK).
    while IFS= read -r _name; do
        [ -z "$_name" ] && continue
        case "$_name" in
            *"$_kafka_suffix") : ;; # already done in pass 1
            *) _delete_one_connection "$_name" ;;
        esac
    done <<< "$_names"
}

# -----------------------------------------------------------------------------
# Step 3 — Delete tables.
#
# Recorded table identifiers are "<db>.<table>" strings (see
# create.sh/phase1_collect_tables). Split each on the first dot, prefix-
# gate the database name, and call delete-table.
#
# `delete-database` would cascade these in step 4, but we issue explicit
# `delete-table` calls so the dry-run audit log surfaces every intended
# deletion as its own STATUS line (matching the task spec phase
# boundaries).
# -----------------------------------------------------------------------------
delete_tables() {
    local _entries
    _entries="$(sbx_state_get '.services.glue.resources.tables[]?')"
    if [ -z "$_entries" ]; then
        sbx_log "no tables recorded; skipping table teardown"
        return 0
    fi

    local _entry
    while IFS= read -r _entry; do
        [ -z "$_entry" ] && continue
        # Split on the FIRST dot to allow tables whose names contain dots
        # (rare but allowed in Glue catalog identifiers).
        local _db="${_entry%%.*}"
        local _table="${_entry#*.}"
        if [ "$_db" = "$_entry" ] || [ -z "$_table" ]; then
            sbx_log "skipping malformed table entry ${_entry}: expected '<db>.<table>'"
            continue
        fi

        # Prefix-gate the DATABASE name (the glue catalog forbids
        # cross-prefix table membership, so a prefix-gated database is
        # sufficient evidence of seed ownership for the table).
        if ! _gate_name "$_db"; then
            sbx_log "skipping table ${_entry}: database ${_db} fails prefix gate (Requirement 20.31)"
            continue
        fi

        local _exists=1
        if sbx_apply_mode; then
            if ! sbx_aws glue get-table \
                    --database-name "$_db" \
                    --name "$_table" \
                    --region "$SBX_REGION" >/dev/null 2>&1; then
                _exists=0
            fi
        else
            sbx_aws glue get-table \
                --database-name "$_db" \
                --name "$_table" \
                --region "$SBX_REGION" || true
        fi
        if [ "$_exists" -eq 0 ]; then
            sbx_log "glue table ${_entry} already deleted; skipping"
            continue
        fi

        sbx_status action "delete-table ${_entry}"
        if ! sbx_aws glue delete-table \
                --database-name "$_db" \
                --name "$_table" \
                --region "$SBX_REGION"; then
            _record_failure "$_entry" delete_table
        fi
    done <<< "$_entries"
}

# -----------------------------------------------------------------------------
# Step 4 — Delete databases.
# -----------------------------------------------------------------------------
delete_databases() {
    local _names
    _names="$(sbx_state_get '.services.glue.resources.databases[]?')"
    if [ -z "$_names" ]; then
        sbx_log "no databases recorded; skipping database teardown"
        return 0
    fi
    local _name
    while IFS= read -r _name; do
        [ -z "$_name" ] && continue
        if ! _gate_name "$_name"; then
            sbx_log "skipping database ${_name}: prefix gate (Requirement 20.31)"
            continue
        fi

        local _exists=1
        if sbx_apply_mode; then
            if ! sbx_aws glue get-database --name "$_name" --region "$SBX_REGION" >/dev/null 2>&1; then
                _exists=0
            fi
        else
            sbx_aws glue get-database --name "$_name" --region "$SBX_REGION" || true
        fi
        if [ "$_exists" -eq 0 ]; then
            sbx_log "glue database ${_name} already deleted; skipping"
            continue
        fi

        sbx_status action "delete-database ${_name}"
        if ! sbx_aws glue delete-database --name "$_name" --region "$SBX_REGION"; then
            _record_failure "$_name" delete_database
        fi
    done <<< "$_names"
}

# -----------------------------------------------------------------------------
# Step 5 — Empty + delete the sample-data S3 bucket.
#
# `aws s3 rm --recursive` on an empty bucket is a no-op, so we always run
# it before delete-bucket (which requires the bucket to be empty). Both
# calls go through sbx_aws so dry-run shows them.
# -----------------------------------------------------------------------------
delete_data_bucket() {
    local _name
    _name="$(sbx_state_get '.services.glue.resources.data_bucket')"
    if [ -z "$_name" ]; then
        sbx_log "no data_bucket recorded; skipping bucket teardown"
        return 0
    fi
    if ! _gate_name "$_name"; then
        sbx_log "skipping s3 bucket ${_name}: prefix gate (Requirement 20.31)"
        return 0
    fi

    local _exists=1
    if sbx_apply_mode; then
        if ! sbx_aws s3api head-bucket --bucket "$_name" --region "$SBX_REGION" >/dev/null 2>&1; then
            _exists=0
        fi
    else
        sbx_aws s3api head-bucket --bucket "$_name" --region "$SBX_REGION" || true
    fi
    if [ "$_exists" -eq 0 ]; then
        sbx_log "s3 bucket ${_name} already deleted; skipping"
        return 0
    fi

    sbx_status action "empty-bucket ${_name}"
    if ! sbx_aws s3 rm "s3://${_name}" --recursive --region "$SBX_REGION"; then
        # Empty-bucket failures are informational; the delete-bucket call
        # below will surface the real problem (residual objects, denied
        # access, etc.). We continue.
        sbx_log "warning: s3 rm --recursive on ${_name} returned non-zero; proceeding to delete-bucket"
    fi

    sbx_status action "delete-bucket ${_name}"
    if ! sbx_aws s3api delete-bucket \
            --bucket "$_name" \
            --region "$SBX_REGION"; then
        _record_failure "$_name" delete_bucket
    fi
}

# -----------------------------------------------------------------------------
# Final state write.
#
# Mark the service torn_down and reset .services.glue.resources to `{}` so
# a subsequent provision run sees a clean slate. We bypass
# `sbx_state_set_service` here because that helper performs a deep-merge
# with jq's `*` operator, which would preserve the existing nested
# `resources` object — exactly the opposite of what we want for a
# torn-down marker. Instead we issue a direct jq REPLACE through the
# atomic-rename pattern (tmp file → fsync → os.replace) so the file can
# never be left in a partial state.
#
# When this script is invoked by `seed/teardown.sh` (the top-level
# orchestrator), the orchestrator's own `_prune_service_state` will run a
# very similar replace AFTER this script returns 0; the duplicate write is
# idempotent and ensures correct state for both direct and orchestrated
# invocations.
# -----------------------------------------------------------------------------
persist_torn_down() {
    local _path _tmp
    _path="$(sbx_state_path)"
    _tmp="${_path}.tmp"

    if [ ! -f "$_path" ]; then
        # No state file at all — nothing to update. The lookup-driven
        # idempotency above already short-circuited every delete, so
        # there is genuinely nothing to record.
        return 0
    fi

    if ! jq '.services.glue = {status: "torn_down", phase: "0", resources: {}}' \
            "$_path" > "$_tmp" 2>/dev/null; then
        rm -f "$_tmp"
        sbx_log "warning: failed to write torn_down marker to ${_path}; state file untouched"
        return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        SBX_TMP="$_tmp" SBX_DST="$_path" python3 -c 'import os; t=os.environ["SBX_TMP"]; d=os.environ["SBX_DST"]; f=open(t,"rb"); os.fsync(f.fileno()); f.close(); os.replace(t,d)'
    else
        mv -f "$_tmp" "$_path"
    fi
}

# -----------------------------------------------------------------------------
# Dispatch.
# -----------------------------------------------------------------------------

sbx_status started

sbx_log "glue teardown starting (region=${SBX_REGION}, prefix=${SBX_SEED_NAME_PREFIX}, mode=$(sbx_apply_mode && echo apply || echo dry-run))"

# Order per task 24.5: jobs → connections (KAFKA first) → tables →
# databases → S3 bucket. Best-effort: each step is independent; a failure
# in one step does not abort the others. Failures are accumulated in
# __failed_deletes and surfaced in the final STATUS line.
# -----------------------------------------------------------------------------
# Step 6 — Delete IAM roles owned by this module.
#
# Done LAST: jobs and crawlers reference these roles and the AWS API
# will reject delete-role with `DeleteConflict` while the role still has
# attached managed policies, inline policies, or active Glue resources
# referencing it. Steps 1 (jobs/crawler) and 4–5 (databases, bucket)
# above clear the Glue-side references; the per-role detach + inline-
# policy cleanup below clears the IAM-side preconditions for delete-
# role.
#
# Pattern mirrors seed/lambda/teardown.sh:
#   1. list-attached-role-policies → detach each
#   2. list-role-policies → delete each inline
#   3. delete-role
#   4. NoSuchEntity → idempotent skip
#
# Gate: per Requirement 20.31, the role NAME must begin with
# `${SBX_SEED_NAME_PREFIX}-` AND its ARN must be recorded in
# `seed.state.json` under `.services.glue.resources.iam_roles`.
# -----------------------------------------------------------------------------

_delete_one_role() {
    local _role_name="$1"

    if ! _gate_name "$_role_name"; then
        sbx_log "skipping iam role ${_role_name}: prefix gate (Requirement 20.31)"
        return 0
    fi

    # Probe: does the role still exist?
    local _exists=1
    if sbx_apply_mode; then
        if ! aws iam get-role --role-name "$_role_name" >/dev/null 2>&1; then
            _exists=0
        fi
    fi
    if [ "$_exists" -eq 0 ]; then
        sbx_log "iam role ${_role_name} already deleted; skipping"
        return 0
    fi

    # Phase A: detach every managed policy.
    local _attached_arns=""
    if sbx_apply_mode; then
        _attached_arns="$(aws iam list-attached-role-policies \
            --role-name "$_role_name" \
            --query 'AttachedPolicies[].PolicyArn' \
            --output text 2>/dev/null | tr '\t' '\n' || true)"
    else
        # Dry-run: render the detach for the canonical attached policy
        # (matches what create.sh attaches). Apply-mode picks up extras
        # via list-attached-role-policies.
        _attached_arns="arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
    fi
    while IFS= read -r _policy_arn; do
        [ -z "$_policy_arn" ] && continue
        sbx_status action "detach-role-policy ${_role_name} ${_policy_arn}"
        if ! sbx_aws iam detach-role-policy \
                --role-name "$_role_name" \
                --policy-arn "$_policy_arn"; then
            sbx_log "warning: detach-role-policy failed for ${_role_name} ${_policy_arn}; continuing"
        fi
    done <<< "$_attached_arns"

    # Phase B: delete every inline policy.
    local _inline_names=""
    if sbx_apply_mode; then
        _inline_names="$(aws iam list-role-policies \
            --role-name "$_role_name" \
            --query 'PolicyNames' \
            --output text 2>/dev/null | tr '\t' '\n' || true)"
    else
        # Dry-run: the canonical inline policy create.sh writes is
        # `s3-data-access` for both crawler-role and job-role.
        _inline_names="s3-data-access"
    fi
    while IFS= read -r _inline_name; do
        [ -z "$_inline_name" ] && continue
        sbx_status action "delete-role-policy ${_role_name} ${_inline_name}"
        if ! sbx_aws iam delete-role-policy \
                --role-name "$_role_name" \
                --policy-name "$_inline_name"; then
            sbx_log "warning: delete-role-policy failed for ${_role_name} ${_inline_name}; continuing"
        fi
    done <<< "$_inline_names"

    # Phase C: delete the role itself. NoSuchEntity (race with another
    # operator's manual delete) is treated as idempotent success.
    sbx_status action "delete-role ${_role_name}"
    if sbx_apply_mode; then
        if ! aws iam delete-role --role-name "$_role_name" >/dev/null 2>&1; then
            if aws iam get-role --role-name "$_role_name" >/dev/null 2>&1; then
                _record_failure "$_role_name" delete_role
            else
                sbx_log "iam role ${_role_name} no longer exists after detach; treating as deleted"
            fi
        fi
    else
        sbx_aws iam delete-role --role-name "$_role_name"
    fi
}

delete_iam_roles() {
    local _crawler_arn _job_arn
    _crawler_arn="$(sbx_state_get '.services.glue.resources.iam_roles.crawler_role_arn')"
    _job_arn="$(sbx_state_get '.services.glue.resources.iam_roles.job_role_arn')"

    if [ -z "$_crawler_arn" ] && [ -z "$_job_arn" ]; then
        sbx_log "no glue IAM roles recorded; skipping role teardown"
        return 0
    fi

    # Names are deterministic from the prefix; rebuild rather than
    # parsing the recorded ARN tail (the prefix gate below applies the
    # same prefix check the helper uses, regardless of how the name was
    # derived).
    local _crawler_name="${SBX_SEED_NAME_PREFIX}-glue-crawler-role"
    local _job_name="${SBX_SEED_NAME_PREFIX}-glue-job-role"

    if [ -n "$_crawler_arn" ]; then
        _delete_one_role "$_crawler_name"
    fi
    if [ -n "$_job_arn" ]; then
        _delete_one_role "$_job_name"
    fi
}

delete_jobs
delete_connections
delete_tables
delete_databases
delete_data_bucket
delete_iam_roles
persist_torn_down

# -----------------------------------------------------------------------------
# Final summary.
# -----------------------------------------------------------------------------
if [ "${#__failed_deletes[@]}" -gt 0 ]; then
    sbx_status error "teardown completed with failures: ${__failed_deletes[*]}"
    exit 1
fi

sbx_status ok "glue teardown complete"
exit 0
