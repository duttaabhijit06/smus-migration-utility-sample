#!/usr/bin/env bash
#
# steps/07_mwaa-integrate/run.sh — Step 7: MWAA → SMUS workflow integration.
#
# Generates outputs/manifest.yaml with one `mwaa-workflow` resource entry
# per Python DAG file extracted by Step 6 (under
# ${MT_WORKDIR}/steps/06_mwaa-extract/outputs/dags/) plus one `admin`
# stage entry that names the Admin_Project, the SMUS_Domain, and the
# source AWS account ID. In apply mode the script then invokes
# `aws-smus-cicd deploy --manifest <generated> --stage admin` (a
# subprocess to the third-party CLI per Requirement 19.4) and captures
# stdout+stderr to outputs/deploy.log. In dry-run mode the script prints
# the would-be deploy command via mt_dryrun.
#
# Halting precondition (Requirement 14.4): if Step 6's outputs/dags/
# directory is missing OR contains no `*.py` files, the script emits
# `STATUS: error Step 6 must complete first` and exits 1. The empty-
# directory and missing-directory cases are both treated as "Step 6
# did not run".
#
# This script does NOT call boto3, the AWS CLI, or any AWS SDK. The
# only external subprocess in apply mode is `aws-smus-cicd deploy`,
# which itself wraps the AWS APIs internally. When the `aws-smus-cicd`
# CLI is not installed on the operator's machine, the script logs a
# warning and skips the deploy WITHOUT failing the step — the manifest
# itself is the primary deliverable and is already on disk.
#
# Validates: Requirements 14.1, 14.2, 14.3, 14.4, 19.4.

# Source the shared helper library BEFORE enabling strict mode so the
# library's own conditional reads of optional MT_* env vars are not
# tripped by `set -u`.
# shellcheck source=../_lib/common.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${MT_WORKDIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}/steps/_lib/common.sh"

set -euo pipefail

mt_init "07_mwaa-integrate" -- "$@"

mt_status started

# Required configuration (Requirements 14.2, 19.1):
#   - MT_SMUS_DOMAIN_ID and MT_ADMIN_PROJECT_ID are filled by Step 1
#     and propagated by the orchestrator via `STATUS: set ...`.
#   - MT_SOURCE_ACCOUNT_ID is collected during interactive
#     configuration (Requirement 2.1).
mt_require_var MT_SMUS_DOMAIN_ID
mt_require_var MT_ADMIN_PROJECT_ID
mt_require_var MT_SOURCE_ACCOUNT_ID
mt_require_var MT_AWS_REGION
mt_require_var MT_ADMIN_PROJECT_NAME

# -----------------------------------------------------------------------------
# Halting precondition: Step 6's DAG output directory must exist AND
# contain at least one *.py file (Requirement 14.4).
WORKDIR="${MT_WORKDIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
DAGS_DIR="${WORKDIR}/steps/06_mwaa-extract/outputs/dags"

if [ ! -d "$DAGS_DIR" ]; then
    mt_status error "Step 6 must complete first"
    exit 1
fi

# `find ... -maxdepth 1 -type f -name '*.py'` enumerates the candidate
# DAG files. The `wc -l | tr -d '[:space:]'` pattern strips the leading
# whitespace `wc` emits on some platforms (notably macOS).
DAG_FILE_COUNT="$(find "$DAGS_DIR" -maxdepth 1 -type f -name '*.py' 2>/dev/null | wc -l | tr -d '[:space:]')"
if [ "${DAG_FILE_COUNT:-0}" = "0" ]; then
    mt_status error "Step 6 must complete first"
    exit 1
fi

mt_log "found ${DAG_FILE_COUNT} DAG file(s) under ${DAGS_DIR}"

MANIFEST_PATH="$(mt_outputs_path manifest.yaml)"
DEPLOY_LOG_PATH="$(mt_outputs_path deploy.log)"

# -----------------------------------------------------------------------------
# Manifest generation (Requirements 14.1, 14.2).
#
# We always WRITE the manifest, in both dry-run and apply mode. In
# dry-run the manifest is a side-effect under the step's outputs/
# folder (same discipline as Step 2's portability report), which is
# inside the tool's working directory and therefore allowed by
# Requirement 1.2. The orchestrator's run-log captures the file path
# so the operator can review the would-be deploy input before
# re-running with --apply.
#
# Format is a hand-rolled YAML emitted via printf so the step does not
# depend on a YAML serializer. The `python` stdlib `yaml` module is
# not part of the orchestrator's dependency surface, and pure-shell
# printf produces deterministic output that is trivially diffable
# across runs (Requirement 19.4 keeps third-party Python libraries out
# of the orchestration control flow).

mt_log "writing $MANIFEST_PATH"

# Manifest schema (validated by aws-smus-cicd-cli's
# application-manifest-schema.yaml):
#   applicationName: <pattern ^[A-Za-z0-9][A-Za-z0-9_-]*$>
#   content:
#     storage:
#       - name: workflows
#         connectionName: default.workflow_serverless
#         include: ["workflows/dags/"]
#   stages:
#     admin:
#       stage: admin
#       domain:
#         id: <dzd-...>
#         region: <region>
#       project:
#         name: <admin project name>
#         profileName: "All capabilities"
#
# The DAGs are wired in by storage content + the workflow_serverless
# connection (auto-created on the admin project by the All-capabilities
# profile). aws-smus-cicd-cli bundles the workflows/dags/ folder and
# pushes it to MWAA via the workflow_serverless connection.
ADMIN_PROJECT_NAME="${MT_ADMIN_PROJECT_NAME:-smus-admin}"
DOMAIN_REGION="${MT_AWS_REGION:-us-east-1}"

{
    printf 'applicationName: migration-tool-workflows\n'
    printf 'content:\n'
    printf '  storage:\n'
    printf '    - name: workflows\n'
    printf '      include:\n'
    # The bundler resolves include paths relative to the directory
    # containing the manifest. Step 7 places the manifest under
    # outputs/ so we walk up three levels to reach the project root
    # where data-pipelines/ lives.
    printf '        - "../../../data-pipelines/workflows/dags/"\n'
    printf '  workflows:\n'
    # Append one workflow entry per *.py file. The workflowName is the
    # DAG basename (no .py); connectionName is the auto-created MWAA
    # connection on the admin project (default.workflow_serverless).
    while IFS= read -r dag_path; do
        [ -z "$dag_path" ] && continue
        dag_basename="$(basename "$dag_path")"
        dag_name="${dag_basename%.py}"
        printf '    - workflowName: %s\n' "$dag_name"
        printf '      connectionName: default.workflow_serverless\n'
    done < <(find "$DAGS_DIR" -maxdepth 1 -type f -name '*.py' 2>/dev/null | LC_ALL=C sort)
    printf 'stages:\n'
    printf '  admin:\n'
    printf '    stage: admin\n'
    printf '    domain:\n'
    printf '      id: %s\n' "$MT_SMUS_DOMAIN_ID"
    printf '      region: %s\n' "$DOMAIN_REGION"
    printf '    project:\n'
    printf '      name: %s\n' "$ADMIN_PROJECT_NAME"
    # Stage-level deployment_configuration overrides the bundler's
    # default `bundle/<storage-name>/` target. SMUS-managed MWAA reads
    # DAGs from `workflows/dags/` under the project's shared S3 root,
    # so we redirect the storage upload there.
    printf '    deployment_configuration:\n'
    printf '      storage:\n'
    printf '        - name: workflows\n'
    printf '          connectionName: default.s3_shared\n'
    printf '          targetDirectory: workflows/dags\n'
} >"$MANIFEST_PATH"

mt_log "manifest written ($(wc -l <"$MANIFEST_PATH" | tr -d '[:space:]') lines)"

# -----------------------------------------------------------------------------
# Deploy (Requirement 14.3).
#
# Apply: emit `STATUS: action aws-smus-cicd-cli deploy --targets admin`
# (so the orchestrator records the action against this step) then
# invoke the CLI as a subprocess and capture stdout+stderr to
# outputs/deploy.log. If the CLI is not installed, log a warning
# naming the pip install command and skip the deploy WITHOUT failing
# the step — the manifest itself is the primary deliverable and is
# already on disk.
#
# Dry-run: print the would-be command via mt_dryrun.
#
# Note on CLI binary name: the `aws-smus-cicd-cli` PyPI package
# installs an entry point named `aws-smus-cicd-cli` (with the `-cli`
# suffix, not `aws-smus-cicd`). The deploy verb takes `--targets`,
# not `--stage`.
DEPLOY_CMD="aws-smus-cicd-cli deploy --manifest ${MANIFEST_PATH} --targets admin"

if mt_apply_mode; then
    mt_status action "aws-smus-cicd-cli deploy --targets admin"
    if command -v aws-smus-cicd-cli >/dev/null 2>&1; then
        # The CLI's deploy verb expects a bundle ZIP in ./artifacts.
        # We build the bundle locally first (--local reads from the
        # filesystem rather than pulling from a `dev` target), then
        # deploy. Both phases write to the persistent deploy.log.
        # `set -o pipefail` (already enabled) propagates non-zero
        # exits from either subprocess.
        #
        # NB: aws-smus-cicd-cli names the bundle ZIP after
        # `applicationName` (NOT the target), so the deploy step
        # needs to point at <applicationName>.zip explicitly.
        local_workdir="${WORKDIR}"
        artifacts_dir="$(mt_outputs_path artifacts)"
        bundle_zip="${artifacts_dir}/migration-tool-workflows.zip"
        ( cd "$local_workdir" && \
            aws-smus-cicd-cli bundle \
                --manifest "$MANIFEST_PATH" \
                --targets admin \
                --local \
                --output-dir "$artifacts_dir" \
            && aws-smus-cicd-cli deploy \
                --manifest "$MANIFEST_PATH" \
                --targets admin \
                --bundle-archive-path "$bundle_zip" \
        ) >"$DEPLOY_LOG_PATH" 2>&1 || {
            mt_log "warning: aws-smus-cicd-cli bundle/deploy failed; see $DEPLOY_LOG_PATH"
            tail -20 "$DEPLOY_LOG_PATH" >&2 || true
            mt_status error "aws-smus-cicd-cli bundle/deploy failed"
            exit 1
        }
    else
        mt_log "warning: aws-smus-cicd-cli CLI not found on PATH; skipping deploy"
        mt_log "warning: install with: pip install aws-smus-cicd-cli"
        mt_log "warning: re-run this step in apply mode after installation to deploy"
        # Record the intent in the deploy log so the operator has a
        # persistent record of why no deploy happened on this run.
        {
            printf 'aws-smus-cicd-cli CLI not installed; deploy skipped.\n'
            printf 'install with: pip install aws-smus-cicd-cli\n'
            printf 'would-be command: %s\n' "$DEPLOY_CMD"
        } >"$DEPLOY_LOG_PATH"
    fi
else
    mt_dryrun "$DEPLOY_CMD"
fi

mt_status ok
exit 0
