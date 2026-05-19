#!/usr/bin/env bash
#
# steps/03_glue-jobs/run.sh — Step 3: Glue jobs → notebooks (with rewritten
# connection references).
#
# Behaviour summary (Requirements 9.1–9.7, 3.6):
#
#   1. Lists every Glue job in the source account via `aws glue get-jobs`
#      and writes the result to outputs/glue-jobs.json. STATUS: / DRY-RUN:
#      lines emitted by mt_aws are stripped before the JSON is parsed.
#   2. For each job in `Jobs[]`, extracts Name, Role, DefaultArguments,
#      Connections.Connections, Command.Name, and Command.ScriptLocation.
#   3. Downloads the job's script via `aws s3 cp <ScriptLocation>
#      outputs/scripts/<Name>.py`. Per-job download failures (script
#      missing, denied, etc.) are appended to outputs/errors.json as
#      `{"job":"<name>","error":"<msg>"}` rows and the loop continues.
#   4. For glueetl / pythonshell jobs only, builds a metadata JSON file at
#      outputs/notebooks/<Name>.metadata.json with shape
#        {"name":"...","role":"...","default_arguments":{...},
#         "connection_references":[{"original":"<conn>",
#                                   "smus_connection_name":null,
#                                   "smus_connection_id":null}, ...]}
#      Each Glue connection name from Connections.Connections becomes one
#      entry in connection_references. The metadata JSON is built inline
#      via `jq -n` (no helper subprocess for this construction).
#   5. Invokes `python -m migration_tool.tools.notebook_gen` with the
#      script, output, and metadata paths to produce
#      outputs/notebooks/<Name>.ipynb.
#   6. After all jobs are processed, runs
#      `python -m migration_tool.tools.connection_rewrite` against the
#      Connection_Mapping_File at
#      ${MT_WORKDIR}/steps/04b_glue-connections/outputs/connection-mapping.json.
#      The tool gracefully no-ops with a warning when the mapping file is
#      absent (Requirement 9.5).
#   7. In apply mode AND when ${MT_WORKDIR}/.git exists, mirrors
#      outputs/scripts/ and outputs/notebooks/ into
#      ${MT_WORKDIR}/data-pipelines/glue-jobs/{scripts,notebooks}/, then
#      `git add` + `git commit`. Tolerates "nothing to commit" gracefully.
#
# This script never imports boto3. Every AWS interaction flows through
# `mt_aws` from steps/_lib/common.sh.

# Resolve MT_WORKDIR. The orchestrator sets it; if a developer runs the
# script directly we derive it from the script location so the `source`
# line below resolves cleanly without coupling to the caller's CWD.
if [ -z "${MT_WORKDIR:-}" ]; then
    MT_WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    export MT_WORKDIR
fi

# shellcheck source=../_lib/common.sh
# shellcheck disable=SC1091
source "${MT_WORKDIR}/steps/_lib/common.sh"

set -euo pipefail

mt_init "03_glue-jobs" -- "$@"
mt_status started

mt_require_var MT_AWS_REGION

# jq is required for JSON construction and parsing throughout this step.
if ! command -v jq >/dev/null 2>&1; then
    mt_status error "jq is required but not found on PATH"
    exit 64
fi

# -----------------------------------------------------------------------------
# Output paths.

SCRIPTS_DIR="$(mt_outputs_path scripts)"
NOTEBOOKS_DIR="$(mt_outputs_path notebooks)"
JOBS_JSON_PATH="$(mt_outputs_path glue-jobs.json)"
ERRORS_PATH="$(mt_outputs_path errors.json)"

mkdir -p "$SCRIPTS_DIR" "$NOTEBOOKS_DIR"

# Initialise errors.json as an empty JSON array. Per-job failures are
# appended via jq below; the connection_rewrite tool may overwrite this
# file with a structured warning when the Connection_Mapping_File is
# absent (Requirement 9.5) — that is the documented contract of the
# helper, not a bug in this step.
printf '%s\n' '[]' >"$ERRORS_PATH"

# -----------------------------------------------------------------------------
# Helpers (script-local).

# _strip_status: drop STATUS:/DRY-RUN: lines emitted by mt_aws / mt_dryrun
# from a captured aws CLI output stream so the remainder is parseable as
# JSON. Always returns 0 so it is safe inside `set -o pipefail` pipelines.
_strip_status() {
    sed -E '/^(STATUS:|DRY-RUN:)/d' || true
}

# _replay_status: re-emit any STATUS:/DRY-RUN: lines from a captured
# stream so the orchestrator (and the run.log tee opened by mt_init in
# apply mode) sees the same status events that mt_aws would have
# produced if its output had not been captured.
_replay_status() {
    grep -E '^(STATUS:|DRY-RUN:)' || true
}

# _append_error <job-name> <error-message>: append a {job, error} row
# to outputs/errors.json. The update is atomic via tempfile + rename so
# a SIGKILL between the jq write and the move leaves the prior file
# untouched.
_append_error() {
    local _job="${1:-}"
    local _msg="${2:-}"
    local _tmp
    _tmp="$(mktemp)"
    jq --arg j "$_job" --arg e "$_msg" \
        '. + [{job: $j, error: $e}]' \
        "$ERRORS_PATH" >"$_tmp"
    mv "$_tmp" "$ERRORS_PATH"
}

# -----------------------------------------------------------------------------
# 1. List Glue jobs.

JOBS_RAW="$(mt_aws glue get-jobs --region "$MT_AWS_REGION" 2>&1 || true)"
printf '%s\n' "$JOBS_RAW" | _replay_status
JOBS_BODY="$(printf '%s\n' "$JOBS_RAW" | _strip_status)"

# In dry-run, mt_aws prints DRY-RUN: and returns no JSON, so the body
# after stripping is empty. Fall back to a deterministic empty Jobs
# list so jq parses cleanly and downstream consumers see a well-formed
# shape on disk.
if [ -z "$(printf '%s' "$JOBS_BODY" | tr -d '[:space:]')" ]; then
    JOBS_BODY='{"Jobs":[]}'
fi

printf '%s\n' "$JOBS_BODY" | jq '.' >"$JOBS_JSON_PATH"
mt_log "wrote $JOBS_JSON_PATH"

# -----------------------------------------------------------------------------
# 2. Per-job processing.

JOB_NAMES_LIST="$(printf '%s\n' "$JOBS_BODY" | jq -r '.Jobs[]?.Name // empty')"

if [ -n "$JOB_NAMES_LIST" ]; then
    while IFS= read -r JOB_NAME; do
        [ -z "$JOB_NAME" ] && continue

        # Pull the job's full record back out so we can extract every
        # field we care about with a single jq pipeline.
        JOB_JSON="$(printf '%s\n' "$JOBS_BODY" | jq -c --arg n "$JOB_NAME" \
            '.Jobs[] | select(.Name == $n)')"
        if [ -z "$JOB_JSON" ]; then
            continue
        fi

        ROLE="$(printf '%s\n' "$JOB_JSON" | jq -r '.Role // ""')"
        DEFAULT_ARGS="$(printf '%s\n' "$JOB_JSON" | jq -c '.DefaultArguments // {}')"
        CONNECTIONS_LIST="$(printf '%s\n' "$JOB_JSON" | jq -c '.Connections.Connections // []')"
        COMMAND_NAME="$(printf '%s\n' "$JOB_JSON" | jq -r '.Command.Name // ""')"
        SCRIPT_LOC="$(printf '%s\n' "$JOB_JSON" | jq -r '.Command.ScriptLocation // ""')"

        SCRIPT_PATH="${SCRIPTS_DIR}/${JOB_NAME}.py"

        # A Glue job with no ScriptLocation is malformed; record the
        # error and continue with the remaining jobs (Requirement 9.7).
        if [ -z "$SCRIPT_LOC" ]; then
            _append_error "$JOB_NAME" "missing Command.ScriptLocation"
            continue
        fi

        # Download the script. In apply mode mt_aws executes `aws s3 cp`
        # and the exit code propagates; non-zero is recorded as a
        # per-job error and the loop continues. In dry-run mt_aws prints
        # DRY-RUN: and returns 0 — no file is written, which is fine
        # because the notebook_gen invocation below is also skipped in
        # dry-run.
        cp_exit=0
        mt_aws s3 cp "$SCRIPT_LOC" "$SCRIPT_PATH" --region "$MT_AWS_REGION" \
            || cp_exit=$?
        if [ "$cp_exit" -ne 0 ]; then
            _append_error "$JOB_NAME" \
                "aws s3 cp failed (exit=${cp_exit}) for ${SCRIPT_LOC}"
            continue
        fi

        # Notebook generation only for glueetl / pythonshell jobs. Other
        # Glue command types (e.g. gluestreaming) have their scripts
        # downloaded but are not converted to notebooks at this step.
        case "$COMMAND_NAME" in
            glueetl|pythonshell)
                # Build the connection_references list from
                # Connections.Connections. Each Glue connection name
                # becomes one entry; smus_connection_name and
                # smus_connection_id are null at this point because
                # Step 4b populates them downstream (the
                # connection_rewrite tool reads the mapping file and
                # rewrites both the script source and the notebook
                # metadata cell).
                CONN_REFS="$(printf '%s\n' "$CONNECTIONS_LIST" | jq -c \
                    '[.[] | {original: ., smus_connection_name: null, smus_connection_id: null}]')"

                META_PATH="${NOTEBOOKS_DIR}/${JOB_NAME}.metadata.json"
                jq -n \
                    --arg name "$JOB_NAME" \
                    --arg role "$ROLE" \
                    --argjson defargs "$DEFAULT_ARGS" \
                    --argjson refs "$CONN_REFS" \
                    '{name: $name, role: $role, default_arguments: $defargs, connection_references: $refs}' \
                    >"$META_PATH"
                mt_log "wrote $META_PATH"

                NB_PATH="${NOTEBOOKS_DIR}/${JOB_NAME}.ipynb"

                # In apply mode we invoke notebook_gen against the
                # downloaded script. In dry-run the script file does
                # not exist on disk, so we instead print the would-be
                # invocation via mt_dryrun.
                if mt_apply_mode; then
                    nbgen_exit=0
                    python -m migration_tool.tools.notebook_gen \
                        --script "$SCRIPT_PATH" \
                        --output "$NB_PATH" \
                        --metadata "$META_PATH" \
                        || nbgen_exit=$?
                    if [ "$nbgen_exit" -ne 0 ]; then
                        _append_error "$JOB_NAME" \
                            "notebook_gen failed (exit=${nbgen_exit})"
                    fi
                else
                    mt_dryrun "python -m migration_tool.tools.notebook_gen --script ${SCRIPT_PATH} --output ${NB_PATH} --metadata ${META_PATH}"
                fi
                ;;
            *)
                # Non-notebook command type: script downloaded, no
                # notebook produced. The job still appears in
                # outputs/glue-jobs.json so a downstream auditor can
                # see why no .ipynb was generated.
                :
                ;;
        esac
    done <<<"$JOB_NAMES_LIST"
fi

# -----------------------------------------------------------------------------
# 3. Connection-reference rewrite against Step 4b's Connection_Mapping_File.
#
# The helper is stdlib-only and gracefully no-ops with a structured
# warning when the mapping file is absent (Requirement 9.5). We invoke
# it in both modes; in dry-run we print the would-be command via
# mt_dryrun for parity with the rest of the script.

MAPPING_PATH="${MT_WORKDIR}/steps/04b_glue-connections/outputs/connection-mapping.json"
PY_DIR_ARG="$(mt_outputs_path scripts/)"
NB_DIR_ARG="$(mt_outputs_path notebooks/)"

if mt_apply_mode; then
    rewrite_exit=0
    python -m migration_tool.tools.connection_rewrite \
        --mapping "$MAPPING_PATH" \
        --target-py-dir "$PY_DIR_ARG" \
        --target-nb-dir "$NB_DIR_ARG" \
        --warnings-out "$ERRORS_PATH" \
        || rewrite_exit=$?
    if [ "$rewrite_exit" -ne 0 ]; then
        mt_log "WARN: connection_rewrite exited non-zero (${rewrite_exit}); continuing"
    fi
else
    mt_dryrun "python -m migration_tool.tools.connection_rewrite --mapping ${MAPPING_PATH} --target-py-dir ${PY_DIR_ARG} --target-nb-dir ${NB_DIR_ARG} --warnings-out ${ERRORS_PATH}"
fi

# -----------------------------------------------------------------------------
# 4. Mirror outputs into data-pipelines/glue-jobs/{scripts,notebooks}/ and
#    commit. Apply mode only, and only when the workspace is a git repo
#    (Requirement 9.6). "Nothing to commit" is tolerated gracefully.

if mt_apply_mode && [ -d "${MT_WORKDIR}/.git" ]; then
    DEST_BASE="${MT_WORKDIR}/data-pipelines/glue-jobs"
    DEST_SCRIPTS="${DEST_BASE}/scripts"
    DEST_NOTEBOOKS="${DEST_BASE}/notebooks"
    mkdir -p "$DEST_SCRIPTS" "$DEST_NOTEBOOKS"

    # find -mindepth 1 enumerates only files inside the source dir and
    # tolerates an empty source dir without erroring. cp -p preserves
    # mtime so re-runs that produce byte-identical content do not
    # cause spurious git diffs.
    if [ -d "$SCRIPTS_DIR" ]; then
        find "$SCRIPTS_DIR" -mindepth 1 -maxdepth 1 -type f \
            -exec cp -p {} "$DEST_SCRIPTS/" \;
    fi
    if [ -d "$NOTEBOOKS_DIR" ]; then
        find "$NOTEBOOKS_DIR" -mindepth 1 -maxdepth 1 -type f \
            -exec cp -p {} "$DEST_NOTEBOOKS/" \;
    fi

    # Run git inside a subshell so the cd does not affect the caller.
    # `|| true` on add and commit lets us tolerate "nothing to commit"
    # and any other non-fatal git state without aborting the step.
    (
        cd "$MT_WORKDIR" || exit 1
        git add data-pipelines/glue-jobs/ || true
        if git commit -m "Step 3: convert Glue jobs to notebooks (with rewritten connection refs)"; then
            mt_log "committed step 3 outputs to data-pipelines/glue-jobs/"
        else
            mt_log "git commit: nothing to commit (or commit declined gracefully)"
        fi
    )
fi

# -----------------------------------------------------------------------------
# 5. Add Glue Spark logs S3 permissions and Lake Formation permissions to the
#    SMUS tooling user role. Glue interactive sessions need to write Spark UI
#    logs to S3 and access data via Lake Formation.

if mt_apply_mode; then
    TOOLING_USER_ROLE_ARN="${MT_TOOLING_USER_ROLE_ARN:-}"

    if [ -n "$TOOLING_USER_ROLE_ARN" ]; then
        # Extract role name from ARN
        ROLE_NAME="${TOOLING_USER_ROLE_ARN##*/}"
        SOURCE_ACCOUNT="${MT_SOURCE_ACCOUNT_ID:-}"

        if [ -n "$ROLE_NAME" ] && [ -n "$SOURCE_ACCOUNT" ]; then
            mt_log "adding Glue Spark logs S3 permissions to role ${ROLE_NAME}..."

            POLICY_DOC=$(cat <<EOFPOLICY
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::amazon-datazone-tooling-${SOURCE_ACCOUNT}-${MT_AWS_REGION}",
                "arn:aws:s3:::amazon-datazone-tooling-${SOURCE_ACCOUNT}-${MT_AWS_REGION}/*"
            ]
        }
    ]
}
EOFPOLICY
)
            mt_aws iam put-role-policy \
                --role-name "$ROLE_NAME" \
                --policy-name GlueSparkLogsAccess \
                --policy-document "$POLICY_DOC" \
                --region "$MT_AWS_REGION" || true

            mt_log "Glue Spark logs permissions added"

            # Register S3 locations with Lake Formation and grant permissions
            mt_log "configuring Lake Formation permissions for Glue interactive sessions..."

            # Register the DataZone tooling bucket with Lake Formation
            mt_aws lakeformation register-resource \
                --resource-arn "arn:aws:s3:::amazon-datazone-tooling-${SOURCE_ACCOUNT}-${MT_AWS_REGION}" \
                --use-service-linked-role \
                --region "$MT_AWS_REGION" 2>/dev/null || true

            # Grant data location access for tooling bucket
            mt_aws lakeformation grant-permissions \
                --principal "{\"DataLakePrincipalIdentifier\":\"${TOOLING_USER_ROLE_ARN}\"}" \
                --resource "{\"DataLocation\":{\"ResourceArn\":\"arn:aws:s3:::amazon-datazone-tooling-${SOURCE_ACCOUNT}-${MT_AWS_REGION}\"}}" \
                --permissions "DATA_LOCATION_ACCESS" \
                --region "$MT_AWS_REGION" 2>/dev/null || true

            # Register and grant access for each source S3 bucket (Lake Formation + IAM)
            S3_BUCKETS_JSON="["
            FIRST=true
            for bucket in ${MT_SOURCE_S3_BUCKETS:-}; do
                # Lake Formation registration and grants
                mt_aws lakeformation register-resource \
                    --resource-arn "arn:aws:s3:::${bucket}" \
                    --use-service-linked-role \
                    --region "$MT_AWS_REGION" 2>/dev/null || true

                mt_aws lakeformation grant-permissions \
                    --principal "{\"DataLakePrincipalIdentifier\":\"${TOOLING_USER_ROLE_ARN}\"}" \
                    --resource "{\"DataLocation\":{\"ResourceArn\":\"arn:aws:s3:::${bucket}\"}}" \
                    --permissions "DATA_LOCATION_ACCESS" \
                    --region "$MT_AWS_REGION" 2>/dev/null || true

                # Build JSON array for IAM policy
                if [ "$FIRST" = true ]; then
                    FIRST=false
                else
                    S3_BUCKETS_JSON="${S3_BUCKETS_JSON},"
                fi
                S3_BUCKETS_JSON="${S3_BUCKETS_JSON}\"arn:aws:s3:::${bucket}\",\"arn:aws:s3:::${bucket}/*\""
            done
            S3_BUCKETS_JSON="${S3_BUCKETS_JSON}]"

            # Add IAM policy for S3 access (Lake Formation alone isn't enough)
            if [ "$S3_BUCKETS_JSON" != "[]" ]; then
                DATA_BUCKET_POLICY=$(cat <<EOFPOLICY2
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:ListBucket",
                "s3:GetBucketLocation"
            ],
            "Resource": ${S3_BUCKETS_JSON}
        }
    ]
}
EOFPOLICY2
)
                mt_aws iam put-role-policy \
                    --role-name "$ROLE_NAME" \
                    --policy-name GlueDataBucketAccess \
                    --policy-document "$DATA_BUCKET_POLICY" \
                    --region "$MT_AWS_REGION" || true
            fi

            mt_log "Lake Formation and IAM permissions configured"
        fi
    fi
fi

# -----------------------------------------------------------------------------
# 6. Upload notebooks to the SMUS project's shared S3 location.
#    Apply mode only. Notebooks use Glue magic format (%glue_version, %%pyspark)
#    and can be opened from the Files section in SMUS.

if mt_apply_mode; then
    DOMAIN_ID="${MT_SMUS_DOMAIN_ID:-}"
    PROJECT_ID="${MT_ADMIN_PROJECT_ID:-}"

    if [ -n "$DOMAIN_ID" ] && [ -n "$PROJECT_ID" ]; then
        # Get the shared S3 location from the SMUS managed S3 root config
        SMUS_S3_ROOT="${MT_SMUS_MANAGED_S3_ROOT:-}"

        if [ -n "$SMUS_S3_ROOT" ]; then
            # Convert to shared path (replace /dev with /shared)
            S3_SHARED="s3://${SMUS_S3_ROOT%/dev}/shared"

            mt_log "uploading notebooks to ${S3_SHARED}/glue-jobs/..."

            for nb_file in "$NOTEBOOKS_DIR"/*.ipynb; do
                [ -f "$nb_file" ] || continue
                nb_name="$(basename "$nb_file")"
                mt_aws s3 cp "$nb_file" "${S3_SHARED}/glue-jobs/${nb_name}" \
                    --region "$MT_AWS_REGION"
            done

            mt_log "notebooks uploaded to ${S3_SHARED}/glue-jobs/"
        else
            mt_log "WARN: SMUS_MANAGED_S3_ROOT not set; skipping notebook upload"
        fi
    else
        mt_log "WARN: domain/project ID not set; skipping notebook upload"
    fi
fi

mt_status ok
exit 0
