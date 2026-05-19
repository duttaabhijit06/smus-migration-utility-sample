#!/usr/bin/env bash
#
# steps/09_cicd/run.sh — Step 9: CI/CD enablement on the configured
# Repo_Provider, plus the production release tag `v1.0.0-prod`.
#
# Behaviour (Requirements 16.1–16.9, 3.6):
#
#   1. For Repo_Provider in {github, github-enterprise-server, gitlab,
#      gitlab-self-managed, bitbucket}, render a provider-native
#      pipeline file under outputs/ that triggers on default-branch
#      pushes plus a manually-dispatched event with a `stage` input
#      whose allowed values are dev/test/prod. Each pipeline installs
#      `aws-smus-cicd-cli` and runs
#      `aws-smus-cicd deploy --manifest ci-cd/manifest.yaml --stage <stage>`.
#   2. Aggregate Step 3's Glue jobs (one `glue-etl` entry per
#      `Job.Name` with `script_path: data-pipelines/glue-jobs/<job>.py`),
#      Step 4b's `Connection_Mapping_File` rows whose status is
#      `registered` (one `smus-connection` entry per row, keyed by
#      `smus_connection_name`), and Step 6's MWAA DAGs (one
#      `mwaa-workflow` entry per *.py file with
#      `dag_path: data-pipelines/workflows/dags/<file>`) into
#      outputs/ci-cd/manifest.yaml. The single `stages:` block at the
#      end carries `name: dev` plus a `config` map with
#      `domain_id`, `project_id`, and `account_id` resolved from the
#      MT_* environment.
#   3. For Repo_Provider == codecommit, skip pipeline file generation
#      AND manifest aggregation, write outputs/MANUAL-CI-WIRING.md,
#      emit `STATUS: manual_ci_wiring_required`, and exit 0 (no push,
#      no tag).
#   4. In apply mode (non-codecommit only):
#        - Initialise a working copy of the configured repository at
#          outputs/work-repo/. Clone if not already present; otherwise
#          `git fetch --all --tags` to refresh.
#        - `git ls-remote --heads <repo_url> migration/cicd-enable`. If
#          the branch is absent on the remote, branch from the default
#          branch's HEAD, copy outputs/<pipeline-file> and
#          outputs/ci-cd/manifest.yaml into the working tree at their
#          canonical repo-relative paths, `git add`, `git commit -m
#          "Step 9: enable CI/CD for SMUS deployments"`, and
#          `git push -u origin migration/cicd-enable`.
#        - `git ls-remote --tags <repo_url> v1.0.0-prod`. If the tag is
#          absent on the remote, `git tag -a v1.0.0-prod -m
#          "Production release v1.0.0"` on the branch's HEAD and
#          `git push origin v1.0.0-prod`.
#        - Halt with `STATUS: error` and exit 1 on any `git ls-remote`
#          or `git push` failure, naming the missing or invalid
#          credential (Requirement 16.9).
#   5. In dry-run mode:
#        - The manifest, the pipeline file, and (for codecommit)
#          MANUAL-CI-WIRING.md are NOT written to disk; the script
#          emits `DRY-RUN: write <path>` lines so the operator sees the
#          would-be writes without on-disk side effects.
#        - Each git command is rendered via `mt_dryrun "git ..."` so
#          the run-log records every would-be git invocation in order.
#
# AWS CLI dispatch discipline:
#
#   - This script does NOT call any AWS API directly. The only
#     subprocesses are `git`, `jq`, and standard POSIX utilities.
#   - The generated pipeline files install and invoke
#     `aws-smus-cicd-cli` at CI execution time, not here.

# Source the shared helper library before enabling strict mode so the
# library's own conditional reads of optional MT_* env vars are not
# tripped by `set -u`.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MT_WORKDIR="${MT_WORKDIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
# shellcheck source=../_lib/common.sh
# shellcheck disable=SC1091
source "${MT_WORKDIR}/steps/_lib/common.sh"

set -euo pipefail

mt_init "09_cicd" "$@"

mt_status started

# -----------------------------------------------------------------------------
# Required env vars (Requirement 2.6)
# -----------------------------------------------------------------------------

mt_require_var MT_REPO_PROVIDER

# -----------------------------------------------------------------------------
# Output paths
# -----------------------------------------------------------------------------

OUTPUTS_DIR="$MT_STEP_OUTPUTS_DIR"
MANIFEST_DIR="${OUTPUTS_DIR}/ci-cd"
MANIFEST_PATH="${MANIFEST_DIR}/manifest.yaml"
WORK_REPO_DIR="${OUTPUTS_DIR}/work-repo"

# Provider-specific pipeline file path (relative to outputs/).
PIPELINE_REL=""
PIPELINE_PATH=""
case "$MT_REPO_PROVIDER" in
    github|github-enterprise-server)
        PIPELINE_REL=".github/workflows/deploy.yml"
        ;;
    gitlab|gitlab-self-managed)
        PIPELINE_REL=".gitlab-ci.yml"
        ;;
    bitbucket)
        PIPELINE_REL="bitbucket-pipelines.yml"
        ;;
    codecommit)
        PIPELINE_REL=""
        ;;
    *)
        mt_status error "unsupported repo_provider: ${MT_REPO_PROVIDER}"
        exit 1
        ;;
esac

if [ -n "$PIPELINE_REL" ]; then
    PIPELINE_PATH="${OUTPUTS_DIR}/${PIPELINE_REL}"
fi

# -----------------------------------------------------------------------------
# Helpers (script-local)
# -----------------------------------------------------------------------------
#
# _write_or_dryrun <path>
#   Read stdin, then either write the buffered content to <path>
#   (apply mode) or emit `DRY-RUN: write <path>` and discard the
#   content (dry-run mode). Re-creates the parent directory in apply
#   mode so callers do not need to mkdir before each write.
_write_or_dryrun() {
    local _path="$1"
    local _content
    _content="$(cat)"
    if mt_apply_mode; then
        mkdir -p "$(dirname "$_path")"
        printf '%s' "$_content" >"$_path"
        mt_log "wrote $_path"
    else
        printf 'DRY-RUN: write %s\n' "$_path"
    fi
}

# _git_step <args...>
#   Apply mode: emit `STATUS: action git <args>` and exec `git <args>`.
#   Dry-run mode: emit `DRY-RUN: git <args>` (no git invocation).
#   Stdout from git in apply mode flows naturally to the caller (and
#   through the run.log tee opened by mt_init).
_git_step() {
    if mt_apply_mode; then
        mt_status action "git $*"
        git "$@"
        return $?
    fi
    mt_dryrun "git $*"
    return 0
}

# _git_capture <out_var> <args...>
#   Apply mode: capture `git <args>` stdout+stderr into the named
#   variable, returning git's exit code so the caller can branch on
#   success vs failure (used for ls-remote probes that care about
#   empty-vs-non-empty output).
#   Dry-run mode: emit `DRY-RUN: git <args>`, set the named variable
#   to the empty string, and return 0.
_git_capture() {
    local _out_var="$1"
    shift
    if mt_apply_mode; then
        mt_status action "git $*"
        local _captured _rc=0
        _captured="$(git "$@" 2>&1)" || _rc=$?
        printf -v "$_out_var" '%s' "$_captured"
        return "$_rc"
    fi
    mt_dryrun "git $*"
    printf -v "$_out_var" '%s' ""
    return 0
}

# -----------------------------------------------------------------------------
# CodeCommit branch — manual wiring stub, no manifest, no push, no tag.
# -----------------------------------------------------------------------------
#
# Per Requirement 16.4 and the task contract, codecommit halts with
# `STATUS: manual_ci_wiring_required` after writing (or would-be-
# writing) the manual-wiring stub. Exit code is 0 because the halt is
# the documented end-state for the codecommit Repo_Provider, not an
# error. The orchestrator distinguishes this from a failure by parsing
# the trailing STATUS: line.

if [ "$MT_REPO_PROVIDER" = "codecommit" ]; then
    MANUAL_PATH="${OUTPUTS_DIR}/MANUAL-CI-WIRING.md"

    # Resolve the optional persisted CodeCommit identifiers so the doc
    # references the actual repository values rather than placeholders
    # when Step 1 has populated them.
    cc_url="${MT_REPO_URL:-<repo_url not yet populated>}"
    cc_arn="${MT_CODECOMMIT_REPO_ARN:-<codecommit_repo_arn not yet populated>}"

    _write_or_dryrun "$MANUAL_PATH" <<MANUAL_EOF
# Manual CI/CD wiring required (CodeCommit)

The Migration_Tool selected \`codecommit\` as the Repo_Provider. AWS CodeCommit
does not have a native YAML-driven pipeline format that lives inside the
repository (the way GitHub Actions, GitLab CI, or Bitbucket Pipelines do).
This step therefore does NOT generate a pipeline file, does NOT push a
branch, and does NOT create a release tag. The CI/CD wiring needs to be
created manually against the CodeCommit_Repo created by Step 1.

## Persisted identifiers

- \`repo_url\`: \`${cc_url}\`
- \`codecommit_repo_arn\`: \`${cc_arn}\`

## Recommended path A — AWS CodePipeline

1. Create a CodePipeline pipeline in the same AWS region as the SMUS_Domain.
2. Add a Source stage of type \`CodeCommit\`. Set the repository name and the
   branch (\`main\`).
3. Add a Build stage of type \`CodeBuild\`. The build container should run:
   \`\`\`bash
   pip install aws-smus-cicd-cli
   aws-smus-cicd deploy --manifest ci-cd/manifest.yaml --stage prod
   \`\`\`
4. Stage through \`dev\` / \`test\` / \`prod\` via approval actions.

## Recommended path B — Amazon CodeCatalyst

1. Add the CodeCommit_Repo to a CodeCatalyst space as a linked source
   repository.
2. Create a CodeCatalyst workflow that triggers on push to \`main\` and on
   manual dispatch.
3. The workflow should run the same \`pip install aws-smus-cicd-cli\` and
   \`aws-smus-cicd deploy\` commands as path A.

## Why no manifest

The CI/CD manifest at \`outputs/ci-cd/manifest.yaml\` is intentionally not
generated for the codecommit Repo_Provider because the deploy is wired up
outside the repository. If you want the manifest as a starting point, re-run
the migration with a different Repo_Provider via \`--reconfigure\` or
\`--set repo_provider=<provider>\` and Step 9 will generate
\`ci-cd/manifest.yaml\` alongside the provider-native pipeline file.
MANUAL_EOF

    mt_status manual_ci_wiring_required
    exit 0
fi

# -----------------------------------------------------------------------------
# Non-codecommit providers — required env vars for manifest stage block.
# -----------------------------------------------------------------------------
#
# These are only required on the non-codecommit path because the
# manifest is the only consumer; the codecommit branch above never
# emits a manifest.

mt_require_var MT_REPO_URL
mt_require_var MT_SMUS_DOMAIN_ID
mt_require_var MT_ADMIN_PROJECT_ID
mt_require_var MT_SOURCE_ACCOUNT_ID

# `jq` is required for manifest aggregation. Fail loudly here rather
# than silently generating an empty manifest so the operator can
# install it before re-running.
if ! command -v jq >/dev/null 2>&1; then
    mt_status error "jq is required but was not found on PATH"
    exit 1
fi

# -----------------------------------------------------------------------------
# 1. Aggregate the CI/CD manifest.
# -----------------------------------------------------------------------------
#
# The manifest content is built into a single buffer and then routed
# to either an on-disk write (apply) or a `DRY-RUN: write <path>` line
# (dry-run). Sorting filenames with `LC_ALL=C sort` makes the manifest
# output deterministic across runs and stable for diffing and for
# property tests that check manifest aggregation completeness.

GLUE_JOBS_PATH="${MT_WORKDIR}/steps/03_glue-jobs/outputs/glue-jobs.json"
CONN_MAPPING_PATH="${MT_WORKDIR}/steps/04b_glue-connections/outputs/connection-mapping.json"
DAGS_DIR="${MT_WORKDIR}/steps/06_mwaa-extract/outputs/dags"

GLUE_JOB_COUNT=0
SMUS_CONN_COUNT=0
MWAA_DAG_COUNT=0

# Build the manifest body into a temp buffer so we can preview the
# aggregate counts in the run log even in dry-run mode (the buffer is
# discarded by `_write_or_dryrun` when MT_DRY_RUN=1).
MANIFEST_BUF="$(
    {
        printf 'application:\n'
        printf '  name: migration-tool-cicd\n'
        printf '  resources:\n'

        # 1a. Glue jobs from Step 3 (Requirement 16.5).
        if [ -f "$GLUE_JOBS_PATH" ]; then
            while IFS= read -r job_name; do
                [ -z "$job_name" ] && continue
                printf '    - type: glue-etl\n'
                printf '      name: %s\n' "$job_name"
                printf '      script_path: data-pipelines/glue-jobs/%s.py\n' "$job_name"
            done < <(jq -r '.Jobs[]?.Name // empty' "$GLUE_JOBS_PATH" 2>/dev/null | LC_ALL=C sort)
        fi

        # 1b. SMUS_Connection rows from the Step 4b Connection_Mapping_File
        #     (Requirement 16.5). Only entries with status == "registered"
        #     become manifest resources; skipped_unsupported and failed
        #     rows are intentionally dropped because they are not
        #     deployable through `aws-smus-cicd deploy`.
        if [ -f "$CONN_MAPPING_PATH" ]; then
            while IFS=$'\t' read -r conn_name conn_id dz_type; do
                [ -z "$conn_name" ] && continue
                printf '    - type: smus-connection\n'
                printf '      name: %s\n' "$conn_name"
                if [ -n "$conn_id" ]; then
                    printf '      connection_id: %s\n' "$conn_id"
                fi
                if [ -n "$dz_type" ]; then
                    printf '      connection_type: %s\n' "$dz_type"
                fi
            done < <(jq -r '
                (.entries // [])
                | map(select(.status == "registered"))
                | sort_by(.smus_connection_name // .glue_connection_name)
                | .[]
                | [
                    (.smus_connection_name // .glue_connection_name),
                    (.smus_connection_id // ""),
                    (.datazone_connection_type // "")
                  ]
                | @tsv
            ' "$CONN_MAPPING_PATH" 2>/dev/null)
        fi

        # 1c. MWAA workflows from the Step 6 extracted DAGs (Requirement 16.5).
        if [ -d "$DAGS_DIR" ]; then
            while IFS= read -r dag_path; do
                [ -z "$dag_path" ] && continue
                dag_basename="$(basename "$dag_path")"
                dag_name="${dag_basename%.py}"
                printf '    - type: mwaa-workflow\n'
                printf '      name: %s\n' "$dag_name"
                printf '      dag_path: data-pipelines/workflows/dags/%s\n' "$dag_basename"
            done < <(find "$DAGS_DIR" -maxdepth 1 -type f -name '*.py' 2>/dev/null | LC_ALL=C sort)
        fi

        # Stages block: a single `dev` stage carrying the resolved
        # SMUS_Domain ID, Admin_Project ID, and source AWS account ID.
        # The provider-native pipeline file in section 2 below exposes
        # `dev` / `test` / `prod` as trigger choices; mapping each
        # choice to a real stage block is left to the operator
        # (typically by adding `test` and `prod` blocks alongside
        # this `dev` baseline).
        printf 'stages:\n'
        printf '  - name: dev\n'
        printf '    config:\n'
        printf '      domain_id: %s\n' "$MT_SMUS_DOMAIN_ID"
        printf '      project_id: %s\n' "$MT_ADMIN_PROJECT_ID"
        printf '      account_id: %s\n' "$MT_SOURCE_ACCOUNT_ID"
    }
)"

# Recount aggregate sizes from the buffer so the run-log lines match
# whatever we just embedded (avoids drift between the iteration loops
# above and a separate counter pass).
GLUE_JOB_COUNT="$(printf '%s\n' "$MANIFEST_BUF" | grep -c '^    - type: glue-etl$' || true)"
SMUS_CONN_COUNT="$(printf '%s\n' "$MANIFEST_BUF" | grep -c '^    - type: smus-connection$' || true)"
MWAA_DAG_COUNT="$(printf '%s\n' "$MANIFEST_BUF" | grep -c '^    - type: mwaa-workflow$' || true)"
mt_log "aggregated ${GLUE_JOB_COUNT} Glue job entries"
mt_log "aggregated ${SMUS_CONN_COUNT} SMUS connection entries"
mt_log "aggregated ${MWAA_DAG_COUNT} MWAA workflow entries"

if [ ! -f "$GLUE_JOBS_PATH" ]; then
    mt_log "warning: ${GLUE_JOBS_PATH} not found; Glue job aggregation skipped"
fi
if [ ! -f "$CONN_MAPPING_PATH" ]; then
    mt_log "warning: ${CONN_MAPPING_PATH} not found; SMUS connection aggregation skipped"
fi
if [ ! -d "$DAGS_DIR" ]; then
    mt_log "warning: ${DAGS_DIR} not found; MWAA workflow aggregation skipped"
fi

printf '%s' "$MANIFEST_BUF" | _write_or_dryrun "$MANIFEST_PATH"

# -----------------------------------------------------------------------------
# 2. Generate the provider-native pipeline file.
# -----------------------------------------------------------------------------

case "$MT_REPO_PROVIDER" in
    github|github-enterprise-server)
        # GitHub Actions: push + workflow_dispatch with a `stage` choice
        # input whose allowed values are dev/test/prod (Requirements
        # 16.1, 16.8).
        _write_or_dryrun "$PIPELINE_PATH" <<'YAML'
# Generated by Step 9 of the SageMaker Migration Tool.
name: Deploy to SageMaker Unified Studio

on:
  push:
    branches: [main]
  workflow_dispatch:
    inputs:
      stage:
        description: Deployment stage
        required: true
        default: dev
        type: choice
        options:
          - dev
          - test
          - prod

permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"
      - name: Install aws-smus-cicd-cli
        run: pip install aws-smus-cicd-cli
      - name: Deploy
        run: aws-smus-cicd deploy --manifest ci-cd/manifest.yaml --stage "${{ inputs.stage || 'dev' }}"
YAML
        ;;
    gitlab|gitlab-self-managed)
        # GitLab CI: workflow:rules + variables.STAGE allowed values
        # dev/test/prod (Requirements 16.2, 16.8). The pipeline runs on
        # default-branch pushes and on manually triggered web pipelines
        # that supply STAGE via a CI variable.
        _write_or_dryrun "$PIPELINE_PATH" <<'YAML'
# Generated by Step 9 of the SageMaker Migration Tool.
workflow:
  rules:
    - if: $CI_PIPELINE_SOURCE == "push" && $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
    - if: $CI_PIPELINE_SOURCE == "web"

variables:
  STAGE:
    value: dev
    description: Deployment stage
    options:
      - dev
      - test
      - prod

stages:
  - deploy

deploy:
  stage: deploy
  image: python:3.11-slim
  script:
    - pip install aws-smus-cicd-cli
    - aws-smus-cicd deploy --manifest ci-cd/manifest.yaml --stage "$STAGE"
YAML
        ;;
    bitbucket)
        # Bitbucket Pipelines: `pipelines.custom` map keyed by stage
        # name with allowed keys dev/test/prod (Requirements 16.3,
        # 16.8). Default-branch pushes also trigger the dev pipeline so
        # day-to-day commits flow through CI automatically.
        _write_or_dryrun "$PIPELINE_PATH" <<'YAML'
# Generated by Step 9 of the SageMaker Migration Tool.
image: python:3.11-slim

pipelines:
  default:
    - step:
        name: Deploy (default branch / dev)
        script:
          - export STAGE=dev
          - pip install aws-smus-cicd-cli
          - aws-smus-cicd deploy --manifest ci-cd/manifest.yaml --stage "$STAGE"
  custom:
    dev:
      - step:
          name: Deploy (dev)
          script:
            - export STAGE=dev
            - pip install aws-smus-cicd-cli
            - aws-smus-cicd deploy --manifest ci-cd/manifest.yaml --stage "$STAGE"
    test:
      - step:
          name: Deploy (test)
          script:
            - export STAGE=test
            - pip install aws-smus-cicd-cli
            - aws-smus-cicd deploy --manifest ci-cd/manifest.yaml --stage "$STAGE"
    prod:
      - step:
          name: Deploy (prod)
          script:
            - export STAGE=prod
            - pip install aws-smus-cicd-cli
            - aws-smus-cicd deploy --manifest ci-cd/manifest.yaml --stage "$STAGE"
YAML
        ;;
esac

# -----------------------------------------------------------------------------
# 3. Apply-mode + dry-run git workflow (non-codecommit only).
# -----------------------------------------------------------------------------
#
# Apply mode:
#   - Initialise outputs/work-repo/ as a clone of MT_REPO_URL (clone if
#     not present, otherwise fetch). Halt with a named-credential
#     message on auth/network failure (Requirement 16.9).
#   - `git ls-remote --heads <repo> migration/cicd-enable`. If the
#     branch is absent, branch from the default branch's HEAD, copy
#     the generated pipeline file and the manifest into the working
#     tree, commit, and push.
#   - `git ls-remote --tags <repo> v1.0.0-prod`. If the tag is absent,
#     create the annotated tag on the branch's HEAD and push.
#
# Dry-run mode:
#   - Emit `DRY-RUN: git <args>` for every git invocation (clone,
#     fetch, ls-remote, checkout, add, commit, push, tag) so the
#     run-log records the full would-be sequence.

BRANCH="migration/cicd-enable"
TAG="v1.0.0-prod"
TAG_MESSAGE="Production release v1.0.0"

# 3a. Initialise the working copy of the configured repository.
if [ -d "${WORK_REPO_DIR}/.git" ]; then
    # Existing clone: fetch latest refs (heads + tags).
    fetch_out=""
    fetch_rc=0
    if mt_apply_mode; then
        _git_capture fetch_out -C "$WORK_REPO_DIR" fetch --all --tags || fetch_rc=$?
    else
        _git_step -C "$WORK_REPO_DIR" fetch --all --tags
    fi
    if [ "$fetch_rc" -ne 0 ]; then
        printf '%s\n' "$fetch_out" >&2
        mt_status error "git fetch failed (auth or network); check credentials for ${MT_REPO_URL}"
        exit 1
    fi
else
    # No existing clone: clone fresh into outputs/work-repo/.
    mkdir -p "$(dirname "$WORK_REPO_DIR")"
    clone_out=""
    clone_rc=0
    if mt_apply_mode; then
        _git_capture clone_out clone "$MT_REPO_URL" "$WORK_REPO_DIR" || clone_rc=$?
    else
        _git_step clone "$MT_REPO_URL" "$WORK_REPO_DIR"
    fi
    if [ "$clone_rc" -ne 0 ]; then
        printf '%s\n' "$clone_out" >&2
        mt_status error "git clone failed (auth or network); check credentials for ${MT_REPO_URL}"
        exit 1
    fi
fi

# 3b. Branch presence check + branch / commit / push.
branch_remote=""
ls_branch_rc=0
if mt_apply_mode; then
    _git_capture branch_remote ls-remote --heads "$MT_REPO_URL" "$BRANCH" || ls_branch_rc=$?
else
    _git_step ls-remote --heads "$MT_REPO_URL" "$BRANCH"
fi
if [ "$ls_branch_rc" -ne 0 ]; then
    printf '%s\n' "$branch_remote" >&2
    mt_status error "git ls-remote --heads failed (auth or network); check credentials for ${MT_REPO_URL}"
    exit 1
fi

if [ -z "$branch_remote" ]; then
    # Branch absent on remote: branch from the default branch's HEAD,
    # copy artefacts into the working tree, commit, and push.
    mt_log "branch ${BRANCH} not present on origin; creating, committing, pushing"

    if mt_apply_mode; then
        # Resolve the default branch from the clone's symbolic HEAD ref.
        default_branch=""
        default_branch_rc=0
        default_branch="$(git -C "$WORK_REPO_DIR" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)" || default_branch_rc=$?
        if [ "$default_branch_rc" -ne 0 ] || [ -z "$default_branch" ]; then
            # Fallback: use `main`. `git ls-remote --symref` is more
            # robust but the symbolic-ref fallback handles the
            # overwhelming majority of remotes set up by hosting
            # providers in 2025+.
            default_branch="origin/main"
        fi

        _git_step -C "$WORK_REPO_DIR" checkout -B "$BRANCH" "$default_branch"

        # Copy the generated pipeline file and the manifest into the
        # working tree at their canonical repo-relative paths.
        DEST_PIPELINE="${WORK_REPO_DIR}/${PIPELINE_REL}"
        DEST_MANIFEST_DIR="${WORK_REPO_DIR}/ci-cd"
        mkdir -p "$(dirname "$DEST_PIPELINE")"
        mkdir -p "$DEST_MANIFEST_DIR"
        cp "$PIPELINE_PATH" "$DEST_PIPELINE"
        cp "$MANIFEST_PATH" "${DEST_MANIFEST_DIR}/manifest.yaml"

        _git_step -C "$WORK_REPO_DIR" add "$PIPELINE_REL" "ci-cd/manifest.yaml"

        # `git commit` exits non-zero with stderr mentioning
        # "nothing to commit" on idempotent re-runs; tolerate that
        # case as success.
        commit_out=""
        commit_rc=0
        mt_status action "git commit"
        commit_out="$(git -C "$WORK_REPO_DIR" commit -m "Step 9: enable CI/CD for SMUS deployments" 2>&1)" || commit_rc=$?
        if [ "$commit_rc" -ne 0 ]; then
            if printf '%s' "$commit_out" | grep -q -E 'nothing to commit|no changes added to commit'; then
                mt_log "git commit: nothing to commit (idempotent re-run)"
            else
                printf '%s\n' "$commit_out" >&2
                mt_status error "git commit failed"
                exit 1
            fi
        else
            printf '%s\n' "$commit_out"
        fi

        push_out=""
        push_rc=0
        _git_capture push_out -C "$WORK_REPO_DIR" push -u origin "$BRANCH" || push_rc=$?
        if [ "$push_rc" -ne 0 ]; then
            printf '%s\n' "$push_out" >&2
            mt_status error "git push failed (auth or network); check credentials for ${MT_REPO_URL}"
            exit 1
        fi
        printf '%s\n' "$push_out"
    else
        # Dry-run: enumerate the would-be branch + commit + push
        # sequence as DRY-RUN: git lines.
        _git_step -C "$WORK_REPO_DIR" checkout -B "$BRANCH" origin/main
        _git_step -C "$WORK_REPO_DIR" add "$PIPELINE_REL" "ci-cd/manifest.yaml"
        _git_step -C "$WORK_REPO_DIR" commit -m "Step 9: enable CI/CD for SMUS deployments"
        _git_step -C "$WORK_REPO_DIR" push -u origin "$BRANCH"
    fi
else
    mt_log "branch ${BRANCH} already present on origin; skipping push (idempotent)"
fi

# 3c. Tag presence check + create + push.
tag_remote=""
ls_tag_rc=0
if mt_apply_mode; then
    _git_capture tag_remote ls-remote --tags "$MT_REPO_URL" "$TAG" || ls_tag_rc=$?
else
    _git_step ls-remote --tags "$MT_REPO_URL" "$TAG"
fi
if [ "$ls_tag_rc" -ne 0 ]; then
    printf '%s\n' "$tag_remote" >&2
    mt_status error "git ls-remote --tags failed (auth or network); check credentials for ${MT_REPO_URL}"
    exit 1
fi

if [ -z "$tag_remote" ]; then
    mt_log "tag ${TAG} not present on origin; creating + pushing"

    if mt_apply_mode; then
        # `git tag -a` exits non-zero with "tag already exists" on a
        # repeat local create; tolerate that case so we still attempt
        # the push.
        tag_out=""
        tag_rc=0
        mt_status action "git tag -a ${TAG}"
        tag_out="$(git -C "$WORK_REPO_DIR" tag -a "$TAG" -m "$TAG_MESSAGE" 2>&1)" || tag_rc=$?
        if [ "$tag_rc" -ne 0 ]; then
            if printf '%s' "$tag_out" | grep -q -E 'already exists'; then
                mt_log "tag ${TAG} already exists locally; will push existing tag"
            else
                printf '%s\n' "$tag_out" >&2
                mt_status error "git tag failed"
                exit 1
            fi
        fi

        push_tag_out=""
        push_tag_rc=0
        _git_capture push_tag_out -C "$WORK_REPO_DIR" push origin "$TAG" || push_tag_rc=$?
        if [ "$push_tag_rc" -ne 0 ]; then
            printf '%s\n' "$push_tag_out" >&2
            mt_status error "git push tag failed (auth or network); check credentials for ${MT_REPO_URL}"
            exit 1
        fi
        printf '%s\n' "$push_tag_out"
    else
        # Dry-run enumeration of the would-be tag + push pair.
        _git_step -C "$WORK_REPO_DIR" tag -a "$TAG" -m "$TAG_MESSAGE"
        _git_step -C "$WORK_REPO_DIR" push origin "$TAG"
    fi
else
    mt_log "tag ${TAG} already present on origin; skipping push (idempotent)"
fi

mt_status ok
exit 0
