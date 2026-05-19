#!/usr/bin/env bash
#
# steps/05_s3-data/run.sh — Step 5: Migrate data-related S3 buckets.
#
# Builds a candidate bucket list from the union of:
#   1) Buckets referenced by Glue jobs (any s3:// URI in
#      steps/03_glue-jobs/outputs/glue-jobs.json — covers source/target
#      paths, default arguments, and --TempDir).
#   2) Buckets backing Glue catalog tables (any s3:// URI under
#      tables[].StorageDescriptor.Location / tables[].location in
#      steps/04_catalog/outputs/glue-catalog-inventory.json).
#   3) Buckets named in MT_SOURCE_S3_INCLUSION_LIST (comma-separated).
#   4) S3 ARNs the MWAA environment response references via
#      `aws mwaa get-environment` (including Environment.SourceBucketArn,
#      which IS the DAG bucket and therefore gets excluded below).
#
# The MWAA_DAG_Bucket (MT_MWAA_DAG_BUCKET_NAME) is unconditionally
# excluded from the candidate set per Requirement 12.2; the exclusion
# is logged so an auditor can prove it from the run log.
#
# Behavior summary (Requirements 12.1, 12.2, 12.3, 12.4, 12.5, 12.6, 3.6):
#   - Both modes write outputs/buckets.json with the final, deduped,
#     DAG-bucket-excluded list as `{"buckets":["...","..."]}`.
#   - Per bucket: `aws s3api head-bucket` (mt_aws echoes in dry-run),
#     then `aws s3 sync s3://<bucket> s3://<smus-root>/<bucket>/`.
#   - In apply mode the per-bucket `aws s3 sync` runs in the
#     background and a heartbeat loop emits a `mt_log` line every 30s
#     while the sync is in flight (Requirement 12.5).
#   - Per-bucket failures (head-bucket OR sync) are appended as rows
#     to outputs/errors.json and the loop continues with the remaining
#     buckets (Requirement 12.6); we do NOT abort the step.
#   - Idempotency (Requirement 3.6): `aws s3api head-bucket` confirms
#     the bucket exists and is reachable before we sync, and
#     `aws s3 sync` is itself a copy-only-what-changed operation, so
#     re-runs naturally no-op when nothing has changed.
#
# This script never imports boto3. Every AWS interaction flows through
# `mt_aws` from `steps/_lib/common.sh`.

# Resolve MT_WORKDIR. The orchestrator sets it; if a developer runs
# the script directly we derive it from the script location so the
# `source` line below resolves cleanly without coupling to the caller's
# CWD.
if [ -z "${MT_WORKDIR:-}" ]; then
    MT_WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    export MT_WORKDIR
fi

# shellcheck source=../_lib/common.sh
# shellcheck disable=SC1091
source "${MT_WORKDIR}/steps/_lib/common.sh"

set -euo pipefail

mt_init "05_s3-data" -- "$@"
mt_status started

mt_require_var MT_AWS_REGION
mt_require_var MT_MWAA_ENVIRONMENT_NAME
mt_require_var MT_MWAA_DAG_BUCKET_NAME
mt_require_var MT_SOURCE_S3_INCLUSION_LIST

# jq is the only non-AWS dependency this step relies on for parsing
# upstream JSON inventories and for emitting buckets.json / errors.json.
if ! command -v jq >/dev/null 2>&1; then
    mt_status error "jq is required but not found on PATH"
    exit 64
fi

# -----------------------------------------------------------------------------
# Helpers for building the candidate bucket list. CANDIDATES collects
# raw bucket names; we dedup and exclude the DAG bucket later. Plain
# arrays + sort -u keep this bash-3.2 compatible (no associative
# arrays required for portability with macOS's stock bash).

CANDIDATES=()

add_bucket() {
    local b="${1:-}"
    [ -z "$b" ] && return 0
    CANDIDATES+=("$b")
}

# Strip leading and trailing whitespace from $1 and echo the result.
trim() {
    local s="${1:-}"
    # shellcheck disable=SC2001
    s="$(printf '%s' "$s" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    printf '%s' "$s"
}

# bucket_from_s3_uri  s3://bucket/path   -> bucket
bucket_from_s3_uri() {
    local uri="${1:-}"
    uri="${uri#s3://}"
    printf '%s' "${uri%%/*}"
}

# bucket_from_s3_arn  arn:aws:s3:::bucket/path -> bucket
bucket_from_s3_arn() {
    local arn="${1:-}"
    arn="${arn#arn:aws:s3:::}"
    printf '%s' "${arn%%/*}"
}

# -----------------------------------------------------------------------------
# 1) Step 3 outputs (Glue jobs): walk the JSON for any s3:// string.
#    This captures ScriptLocation, default arguments referencing s3://
#    (including --TempDir), and any other s3:// URI a Glue job's
#    source/target definition may carry.

GLUE_JOBS_JSON="${MT_WORKDIR}/steps/03_glue-jobs/outputs/glue-jobs.json"
if [ -f "$GLUE_JOBS_JSON" ]; then
    mt_log "reading glue jobs: $GLUE_JOBS_JSON"
    while IFS= read -r uri; do
        [ -z "$uri" ] && continue
        add_bucket "$(bucket_from_s3_uri "$uri")"
    done < <(jq -r '.. | strings | select(startswith("s3://"))' "$GLUE_JOBS_JSON" 2>/dev/null || true)
else
    mt_log "skipping glue jobs scan: $GLUE_JOBS_JSON not present"
fi

# -----------------------------------------------------------------------------
# 2) Step 4 outputs (Glue catalog inventory): every
#    tables[].StorageDescriptor.Location (or the simplified
#    tables[].location form Step 4 actually writes) that begins with
#    s3://. We use the same generic-string walk as for Glue jobs so
#    schema variation between the raw `aws glue get-tables` shape and
#    Step 4's trimmed inventory shape both work.

CATALOG_INV="${MT_WORKDIR}/steps/04_catalog/outputs/glue-catalog-inventory.json"
if [ -f "$CATALOG_INV" ]; then
    mt_log "reading glue catalog inventory: $CATALOG_INV"
    while IFS= read -r loc; do
        [ -z "$loc" ] && continue
        add_bucket "$(bucket_from_s3_uri "$loc")"
    done < <(jq -r '.. | strings | select(startswith("s3://"))' "$CATALOG_INV" 2>/dev/null || true)
else
    mt_log "skipping glue catalog scan: $CATALOG_INV not present"
fi

# -----------------------------------------------------------------------------
# 3) Inclusion list (comma-separated string the orchestrator sets from
#    config.source_s3_inclusion_list).

INCLUSION=()
IFS=',' read -r -a INCLUSION <<<"$MT_SOURCE_S3_INCLUSION_LIST"
for raw in "${INCLUSION[@]:-}"; do
    name="$(trim "$raw")"
    add_bucket "$name"
done

# -----------------------------------------------------------------------------
# 4) MWAA environment: parse Environment.SourceBucketArn (the DAG
#    bucket, which gets filtered out below) plus any other S3 ARN the
#    response references. In dry-run, mt_aws prints DRY-RUN: lines and
#    returns no JSON, so this branch contributes zero buckets — that
#    is fine; the dry-run candidate set is built purely from the
#    inclusion list and the upstream JSON files.

MWAA_RAW="$(mt_aws mwaa get-environment \
    --name "$MT_MWAA_ENVIRONMENT_NAME" \
    --region "$MT_AWS_REGION" 2>/dev/null \
    | grep -v -E '^(STATUS:|DRY-RUN:)' || true)"
if [ -n "$MWAA_RAW" ]; then
    while IFS= read -r arn; do
        [ -z "$arn" ] && continue
        add_bucket "$(bucket_from_s3_arn "$arn")"
    done < <(printf '%s' "$MWAA_RAW" | jq -r '.. | strings | select(startswith("arn:aws:s3:::"))' 2>/dev/null || true)
fi

# -----------------------------------------------------------------------------
# Dedupe and exclude the MWAA DAG bucket (Requirement 12.2).

mt_log "excluding MWAA DAG bucket: $MT_MWAA_DAG_BUCKET_NAME"

FINAL=()
if [ "${#CANDIDATES[@]}" -gt 0 ]; then
    while IFS= read -r b; do
        [ -z "$b" ] && continue
        if [ "$b" != "$MT_MWAA_DAG_BUCKET_NAME" ]; then
            FINAL+=("$b")
        fi
    done < <(printf '%s\n' "${CANDIDATES[@]}" | sort -u)
fi

# -----------------------------------------------------------------------------
# Write outputs/buckets.json (Requirement 12.3).

BUCKETS_PATH="$(mt_outputs_path "buckets.json")"

if [ "${#FINAL[@]}" -gt 0 ]; then
    jq -n --args '{buckets: $ARGS.positional}' -- "${FINAL[@]}" > "$BUCKETS_PATH"
else
    jq -n '{buckets: []}' > "$BUCKETS_PATH"
fi
mt_log "wrote $BUCKETS_PATH (count=${#FINAL[@]})"

# -----------------------------------------------------------------------------
# Per-bucket head-bucket + sync (Requirements 12.4, 12.5, 12.6, 3.6).
#
# MT_SMUS_MANAGED_S3_ROOT is filled in by Step 1 once the SMUS domain
# resolves its managed S3 root. When unset (Step 1 hasn't run yet)
# we fall back to the placeholder "smus-managed-fallback" so dry-run
# is still demonstrable end-to-end without coupling Step 5 to Step 1.

SMUS_ROOT="${MT_SMUS_MANAGED_S3_ROOT:-smus-managed-fallback}"

ERRORS_PATH="$(mt_outputs_path "errors.json")"
ERRORS=()

if [ "${#FINAL[@]}" -gt 0 ]; then
    for bucket in "${FINAL[@]}"; do
        mt_log "processing bucket: s3://${bucket}"

        # head-bucket. In apply mode this verifies the bucket exists
        # and is reachable; in dry-run mt_aws just echoes the would-be
        # command and returns 0.
        if ! mt_aws s3api head-bucket --bucket "$bucket"; then
            err_msg="head-bucket failed for s3://${bucket}"
            mt_log "ERROR: $err_msg"
            ERRORS+=("$(jq -nc --arg b "$bucket" --arg e "$err_msg" '{bucket: $b, error: $e}')")
            continue
        fi

        if mt_apply_mode; then
            # Run the sync in the background so we can attach a 30s
            # heartbeat (Requirement 12.5). Capturing the exit code via
            # `wait "$sync_pid" || sync_exit=$?` is set-e-safe.
            mt_aws s3 sync \
                "s3://${bucket}" \
                "s3://${SMUS_ROOT}/${bucket}/" \
                --region "$MT_AWS_REGION" &
            sync_pid=$!

            # shellcheck disable=SC2064
            ( while kill -0 "$sync_pid" 2>/dev/null; do
                  mt_log "syncing $bucket: in progress"
                  sleep 30
              done ) &
            heartbeat_pid=$!

            sync_exit=0
            wait "$sync_pid" || sync_exit=$?

            # Reap the heartbeat. It usually exits on its own once the
            # sync pid is gone, but we kill+wait defensively so a slow
            # `sleep` doesn't leave a zombie around.
            kill "$heartbeat_pid" 2>/dev/null || true
            wait "$heartbeat_pid" 2>/dev/null || true

            if [ "$sync_exit" -ne 0 ]; then
                err_msg="aws s3 sync failed for s3://${bucket} (exit=$sync_exit)"
                mt_log "ERROR: $err_msg"
                ERRORS+=("$(jq -nc --arg b "$bucket" --arg e "$err_msg" '{bucket: $b, error: $e}')")
                continue
            fi
        else
            # Dry-run: mt_aws prints `DRY-RUN: aws s3 sync ...` and
            # returns 0. No background processes, no heartbeat needed.
            mt_aws s3 sync \
                "s3://${bucket}" \
                "s3://${SMUS_ROOT}/${bucket}/" \
                --region "$MT_AWS_REGION"
        fi
    done
else
    mt_log "no candidate buckets to sync"
fi

# Persist errors.json only when at least one per-bucket failure
# occurred, matching the apply-mode contract in Requirement 12.6.
if [ "${#ERRORS[@]}" -gt 0 ]; then
    printf '%s\n' "${ERRORS[@]}" | jq -s . > "$ERRORS_PATH"
    mt_log "wrote $ERRORS_PATH (failures=${#ERRORS[@]})"
fi

mt_status ok
exit 0
