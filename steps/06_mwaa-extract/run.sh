#!/usr/bin/env bash
#
# steps/06_mwaa-extract/run.sh — Step 6: Extract MWAA DAG code, plugins, and
# requirements from the source MWAA_Environment to the step's outputs/ folder
# and (in apply mode) commit those artifacts into the configured code
# repository on the orchestrator's local working tree.
#
# Behavior (Requirements 13.1, 13.2, 13.3, 13.4, 13.5):
#   - `aws mwaa get-environment` for $MT_MWAA_ENVIRONMENT_NAME; parse
#     Environment.SourceBucketArn (strip the well-known `arn:aws:s3:::`
#     prefix to recover the bare bucket name), Environment.DagS3Path, and
#     the optional Environment.PluginsS3Path / Environment.RequirementsS3Path
#     with `jq`.
#   - Always sync the DAG S3 path into outputs/dags/ (or print the would-be
#     `aws s3 sync` line in dry-run via mt_aws's DRY-RUN: prefix).
#   - When PluginsS3Path is non-null and non-empty, download
#     outputs/plugins.zip; when RequirementsS3Path is non-null and non-empty,
#     download outputs/requirements.txt.
#   - In apply mode AND when $MT_WORKDIR/.git exists, mirror outputs/dags/
#     into $MT_WORKDIR/data-pipelines/workflows/dags/, copy plugins.zip and
#     requirements.txt next to dags/ when present, then `git add` and
#     `git commit`. "Nothing to commit" is tolerated as a successful no-op so
#     re-runs against an unchanged DAG tree still complete cleanly. The push
#     to the remote is intentionally deferred to Step 9.
#
# Why we filter `mt_aws`'s stdout via grep before parsing JSON:
#   `mt_aws` prints `STATUS: action ...` (and, in dry-run, `DRY-RUN: aws ...`)
#   on stdout before invoking the CLI, so a naive command substitution would
#   mix those control lines into the JSON jq must parse. Stripping any line
#   that starts with `STATUS:` or `DRY-RUN:` keeps the captured payload free
#   of orchestrator-control text in apply mode and yields an empty payload in
#   dry-run, which the placeholder block below handles deliberately.

# shellcheck source=../_lib/common.sh
# shellcheck disable=SC1091
source "${MT_WORKDIR:-$(pwd)}/steps/_lib/common.sh"

set -euo pipefail

mt_init "06_mwaa-extract" -- "$@"
mt_status started

mt_require_var MT_AWS_REGION
mt_require_var MT_MWAA_ENVIRONMENT_NAME

# jq is the only non-AWS dependency this step relies on. Fail fast with a
# parseable STATUS line if it is missing so the orchestrator can surface the
# environmental gap clearly.
if ! command -v jq >/dev/null 2>&1; then
    mt_status error "missing required tool: jq"
    exit 64
fi

DAGS_DIR="$(mt_outputs_path "dags/")"
PLUGINS_FILE="$(mt_outputs_path "plugins.zip")"
REQS_FILE="$(mt_outputs_path "requirements.txt")"
mkdir -p "$DAGS_DIR"

# ---- 1. Discover MWAA environment configuration ----------------------------
# `|| true` keeps `set -o pipefail` happy when grep returns 1 because every
# line was filtered (the dry-run case where stdout is purely control lines).
MWAA_RAW="$(mt_aws mwaa get-environment \
    --name "$MT_MWAA_ENVIRONMENT_NAME" \
    --region "$MT_AWS_REGION" \
    | grep -v -E '^(STATUS:|DRY-RUN:)' || true)"

if [ -n "$MWAA_RAW" ]; then
    SOURCE_BUCKET_ARN="$(printf '%s' "$MWAA_RAW" | jq -r '.Environment.SourceBucketArn // ""')"
    DAG_PATH="$(printf '%s' "$MWAA_RAW" | jq -r '.Environment.DagS3Path // ""')"
    PLUGINS_PATH="$(printf '%s' "$MWAA_RAW" | jq -r '.Environment.PluginsS3Path // ""')"
    REQS_PATH="$(printf '%s' "$MWAA_RAW" | jq -r '.Environment.RequirementsS3Path // ""')"
    if [ -z "$SOURCE_BUCKET_ARN" ] || [ -z "$DAG_PATH" ]; then
        mt_status error "aws mwaa get-environment response missing SourceBucketArn or DagS3Path"
        exit 1
    fi
    # SourceBucketArn is `arn:aws:s3:::<bucket>`; strip the well-known prefix
    # to recover the bare bucket name needed for s3:// URLs below.
    SOURCE_BUCKET="${SOURCE_BUCKET_ARN#arn:aws:s3:::}"
else
    # Dry-run path: render documented placeholder URIs so an operator can
    # review the would-be s3 commands without pretending we know the real
    # bucket. Plugins/reqs paths stay empty so the optional-download blocks
    # below are correctly skipped.
    SOURCE_BUCKET="<mwaa-source-bucket>"
    DAG_PATH="<dag-s3-path>"
    PLUGINS_PATH=""
    REQS_PATH=""
fi

# ---- 2. Sync the DAG path into outputs/dags/ -------------------------------
mt_aws s3 sync "s3://${SOURCE_BUCKET}/${DAG_PATH}" "$DAGS_DIR" --region "$MT_AWS_REGION"

# ---- 3. Optional plugins archive -------------------------------------------
# `aws mwaa get-environment` returns the literal JSON `null` for an absent
# PluginsS3Path; jq's `// ""` collapses null to empty, but we also guard the
# string `"null"` defensively in case a future aws-cli release surfaces it
# verbatim.
if [ -n "$PLUGINS_PATH" ] && [ "$PLUGINS_PATH" != "null" ]; then
    mt_aws s3 cp "s3://${SOURCE_BUCKET}/${PLUGINS_PATH}" "$PLUGINS_FILE" --region "$MT_AWS_REGION"
fi

# ---- 4. Optional requirements file -----------------------------------------
if [ -n "$REQS_PATH" ] && [ "$REQS_PATH" != "null" ]; then
    mt_aws s3 cp "s3://${SOURCE_BUCKET}/${REQS_PATH}" "$REQS_FILE" --region "$MT_AWS_REGION"
fi

# ---- 5. Commit the artifacts into the code repository ----------------------
# Apply mode AND a `.git` directory at $MT_WORKDIR are both required: the
# orchestrator's workdir is the configured code repository's root, and a
# missing `.git` means the operator pointed the tool at a non-repo location
# (or hasn't checked out the repo yet). In that case we silently skip the
# commit rather than `git init` for them — it is not this step's job to
# materialize a new repository.
WORKDIR="${MT_WORKDIR:-$(pwd)}"
REPO_PARENT_DIR="${WORKDIR}/data-pipelines/workflows"
REPO_DAGS_DIR="${REPO_PARENT_DIR}/dags"
COMMIT_MESSAGE="Step 6: extract MWAA DAGs from $MT_MWAA_ENVIRONMENT_NAME"

if mt_apply_mode && [ -d "${WORKDIR}/.git" ]; then
    mkdir -p "$REPO_DAGS_DIR"
    # `cp -a "$DAGS_DIR/."` copies the *contents* of the dags/ folder into
    # the repo's dags/ folder rather than nesting an extra dags/ directory.
    # The dot form also copies dotfiles, which matters for typical Airflow
    # project layouts that include `.airflowignore` and similar.
    if [ -d "$DAGS_DIR" ]; then
        cp -a "${DAGS_DIR}/." "${REPO_DAGS_DIR}/"
    fi
    if [ -f "$PLUGINS_FILE" ]; then
        cp -a "$PLUGINS_FILE" "${REPO_PARENT_DIR}/"
    fi
    if [ -f "$REQS_FILE" ]; then
        cp -a "$REQS_FILE" "${REPO_PARENT_DIR}/"
    fi

    mt_status action "git add data-pipelines/workflows/dags/"
    ( cd "$WORKDIR" && git add "data-pipelines/workflows/dags/" )

    mt_status action "git commit"
    # `git commit` exits non-zero when there is nothing to commit. We treat
    # that as success so re-runs against an unchanged DAG tree still mark
    # the step `completed`. Push is intentionally deferred to Step 9.
    if ! ( cd "$WORKDIR" && git commit -m "$COMMIT_MESSAGE" ); then
        mt_log "git commit reported no changes — treating as successful no-op"
    fi
else
    mt_dryrun "mkdir -p $REPO_DAGS_DIR"
    mt_dryrun "cp -a ${DAGS_DIR}/. ${REPO_DAGS_DIR}/"
    mt_dryrun "git -C $WORKDIR add data-pipelines/workflows/dags/"
    mt_dryrun "git -C $WORKDIR commit -m \"$COMMIT_MESSAGE\""
fi

mt_status ok
exit 0
