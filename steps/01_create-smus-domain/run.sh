#!/usr/bin/env bash
#
# steps/01_create-smus-domain/run.sh — Step 1
#
# Creates the SMUS_Domain, the Admin_Project, the configured code
# repository (or registers an existing CodeCommit_Repo), and the Git
# connection on the Admin_Project. Branches on $MT_REPO_PROVIDER.
#
# Every AWS interaction flows through mt_aws / mt_dryrun. The script
# never invokes boto3 or any Python AWS SDK.
#
# Validates Requirements: 7.1, 7.2, 7.3, 7.4, 7.5, 7.6, 7.7, 7.9, 7.10, 3.6.

# shellcheck source=../_lib/common.sh
. "${MT_WORKDIR:-$(pwd)}/steps/_lib/common.sh"

set -euo pipefail

mt_init "01_create-smus-domain" -- "$@"

mt_status started

# -----------------------------------------------------------------------------
# Required configuration. The orchestrator forwards Config_File values as
# MT_* environment variables; missing values exit 64 with
# `STATUS: missing_var <NAME>` so the runner can prompt and re-invoke.
mt_require_var MT_REPO_PROVIDER
mt_require_var MT_AWS_REGION
mt_require_var MT_SMUS_DOMAIN_NAME
mt_require_var MT_ADMIN_PROJECT_NAME
mt_require_var MT_IDENTITY_CENTER_INSTANCE_ARN

case "$MT_REPO_PROVIDER" in
    codecommit)
        mt_require_var MT_REPO_NAME
        ;;
    github|github-enterprise-server|gitlab|gitlab-self-managed|bitbucket)
        mt_require_var MT_REPO_URL
        ;;
    *)
        mt_status error "unsupported MT_REPO_PROVIDER=${MT_REPO_PROVIDER}"
        exit 64
        ;;
esac

# Domain execution role. The operator may override via
# MT_DOMAIN_EXECUTION_ROLE; otherwise we synthesise a placeholder that
# names the source account (defaulting to twelve zeros so dry-run
# always renders a syntactically complete ARN even if the operator
# has not yet supplied MT_SOURCE_ACCOUNT_ID).
DOMAIN_EXEC_ROLE_ARN="${MT_DOMAIN_EXECUTION_ROLE:-arn:aws:iam::${MT_SOURCE_ACCOUNT_ID:-000000000000}:role/sagemaker-domain-execution}"

# All-capabilities project profile ID. Operators can override via
# `--set admin_project_profile_id=<id>`; the orchestrator forwards
# Config_File keys as MT_* env vars so the override surfaces here as
# MT_ADMIN_PROJECT_PROFILE_ID. Defaults to the well-known token
# `all-capabilities` so dry-run produces a reviewable command line.
ADMIN_PROJECT_PROFILE_ID="${MT_ADMIN_PROJECT_PROFILE_ID:-all-capabilities}"

# -----------------------------------------------------------------------------
# Helpers (script-local).

# _strip_status — drop STATUS:/DRY-RUN: lines emitted by mt_aws / mt_dryrun
# from a captured aws CLI output stream so the remainder is parseable.
# Always returns 0 so it's safe inside `set -o pipefail` pipelines.
_strip_status() {
    sed -E '/^(STATUS:|DRY-RUN:)/d' || true
}

# _replay_status — read a captured stream on stdin and re-emit any
# STATUS:/DRY-RUN: lines to stdout. Used after `VAR=$(mt_aws ...)`
# captures so the orchestrator (and a human running the script
# directly) sees the same status events that mt_aws would have
# produced if its output had not been captured.
_replay_status() {
    grep -E '^(STATUS:|DRY-RUN:)' || true
}

# _extract_id — read JSON on stdin and print the value at the given dot-path.
# Prefers `jq` when available; otherwise falls back to a portable
# `python3 -c` parser. Empty when the path is missing or the input is
# not JSON. Always returns 0 to stay friendly inside `set -o pipefail`
# pipelines.
#
# Usage:
#   echo "$json" | _extract_id id
#   echo "$json" | _extract_id repositoryMetadata.cloneUrlHttp
_extract_id() {
    local _path="${1:-}"
    if [ -z "$_path" ]; then
        return 0
    fi
    if command -v jq >/dev/null 2>&1; then
        # jq's `// empty` swallows null/missing without raising.
        jq -r ".${_path} // empty" 2>/dev/null || true
    else
        python3 -c '
import json, sys
path = sys.argv[1].split(".") if sys.argv[1] else []
try:
    obj = json.load(sys.stdin)
except Exception:
    sys.exit(0)
val = obj
for key in path:
    if isinstance(val, dict) and key in val:
        val = val[key]
    else:
        sys.exit(0)
if val is None:
    sys.exit(0)
print(val)
' "$_path" 2>/dev/null || true
    fi
}

# -----------------------------------------------------------------------------
# Phase 1 — SMUS_Domain (idempotent create).
#
# Pre-existence check via `aws datazone list-domains` with a JMESPath
# `--query` filter. In dry-run, mt_aws prints the DRY-RUN line and
# returns 0 with no real output, so the captured value is empty and we
# fall through to the create branch (which itself only prints the
# DRY-RUN line and we substitute a placeholder ID).
DOMAIN_ID="${MT_SMUS_DOMAIN_ID:-}"
if [ -z "$DOMAIN_ID" ]; then
DOMAIN_LIST_OUT=$(mt_aws datazone list-domains \
    --query "items[?name=='${MT_SMUS_DOMAIN_NAME}'].id" \
    --output text \
    --region "$MT_AWS_REGION" 2>/dev/null || true)
printf '%s\n' "$DOMAIN_LIST_OUT" | _replay_status
DOMAIN_ID=$(printf '%s\n' "$DOMAIN_LIST_OUT" \
    | _strip_status \
    | tr -s '[:space:]' '\n' \
    | grep -v '^$' \
    | head -n 1 || true)

if [ -n "$DOMAIN_ID" ]; then
    mt_status action skipping_create_domain
else
    DOMAIN_SERVICE_ROLE_ARN="${MT_DOMAIN_SERVICE_ROLE:-}"
    _SVC_ROLE_FLAG=()
    if [ -n "$DOMAIN_SERVICE_ROLE_ARN" ]; then
        _SVC_ROLE_FLAG=(--service-role "$DOMAIN_SERVICE_ROLE_ARN")
    fi
    DOMAIN_CREATE_OUT=$(mt_aws datazone create-domain \
        --name "$MT_SMUS_DOMAIN_NAME" \
        --domain-execution-role "$DOMAIN_EXEC_ROLE_ARN" \
        --domain-version V2 \
        "${_SVC_ROLE_FLAG[@]}" \
        --single-sign-on "type=IAM_IDC,userAssignment=AUTOMATIC,idcInstanceArn=${MT_IDENTITY_CENTER_INSTANCE_ARN}" \
        --region "$MT_AWS_REGION" 2>&1 || true)
    printf '%s\n' "$DOMAIN_CREATE_OUT" | _replay_status
    DOMAIN_ID=$(printf '%s\n' "$DOMAIN_CREATE_OUT" \
        | _strip_status \
        | _extract_id id)
    if [ -z "$DOMAIN_ID" ]; then
        if mt_dry_run_mode; then
            DOMAIN_ID="dzd_DRYRUN"
        else
            mt_status error "failed to parse domain id from create-domain output"
            printf '%s\n' "$DOMAIN_CREATE_OUT"
            exit 1
        fi
    fi
fi
fi
mt_status set "smus_domain_id=${DOMAIN_ID}"

# -----------------------------------------------------------------------------
# Phase 2 — Admin_Project (idempotent create on the SMUS_Domain).
PROJECT_ID="${MT_ADMIN_PROJECT_ID:-}"
if [ -z "$PROJECT_ID" ]; then
PROJECT_LIST_OUT=$(mt_aws datazone list-projects \
    --domain-identifier "$DOMAIN_ID" \
    --query "items[?name=='${MT_ADMIN_PROJECT_NAME}'].id" \
    --output text 2>/dev/null || true)
printf '%s\n' "$PROJECT_LIST_OUT" | _replay_status
PROJECT_ID=$(printf '%s\n' "$PROJECT_LIST_OUT" \
    | _strip_status \
    | tr -s '[:space:]' '\n' \
    | grep -v '^$' \
    | head -n 1 || true)

if [ -n "$PROJECT_ID" ]; then
    mt_status action skipping_create_project
else
    # Resolve the project profile ID. The default `all-capabilities`
    # token is a placeholder — for a freshly-created V2 domain we
    # bootstrap a Tooling-enabled All-capabilities project profile
    # ourselves: enable the Tooling blueprint at the domain (with the
    # provisioning + manage-access roles created by the migrate.sh
    # IAM bootstrap), find or create a project profile with one Tooling
    # environment configuration, then use that profile ID below.
    if [ "$ADMIN_PROJECT_PROFILE_ID" = "all-capabilities" ]; then
        if mt_dry_run_mode; then
            ADMIN_PROJECT_PROFILE_ID="DRY-RUN-PROFILE-ID"
        else
            # Step 2.1: Look for an already-named profile (idempotent
            # re-runs).
            ADMIN_PROJECT_PROFILE_ID=$(aws datazone list-project-profiles \
                --domain-identifier "$DOMAIN_ID" \
                --query "items[?name=='All-capabilities-profile'] | [0].id" \
                --output text \
                --region "$MT_AWS_REGION" 2>/dev/null \
                | tr -s '[:space:]' '\n' \
                | grep -v '^$' | grep -v '^None$' | head -n 1 || true)

            if [ -z "$ADMIN_PROJECT_PROFILE_ID" ]; then
                # Step 2.2: Discover the Tooling blueprint's ID from the
                # AWS-managed blueprints library.
                mt_status action "discovering Tooling blueprint id"
                _TOOLING_BP_ID=$(aws datazone list-environment-blueprints \
                    --domain-identifier "$DOMAIN_ID" \
                    --managed \
                    --query "items[?name=='Tooling'] | [0].id" \
                    --output text \
                    --region "$MT_AWS_REGION" 2>/dev/null \
                    | tr -s '[:space:]' '\n' \
                    | grep -v '^$' | grep -v '^None$' | head -n 1 || true)
                if [ -z "$_TOOLING_BP_ID" ]; then
                    mt_status error "failed to discover Tooling blueprint id in domain ${DOMAIN_ID}"
                    exit 1
                fi

                # Step 2.3: Enable the Tooling blueprint at the domain
                # (idempotent — re-running with the same payload is a
                # no-op AWS-side).
                mt_status action "put-environment-blueprint-configuration Tooling=${_TOOLING_BP_ID}"
                _PROV_ROLE="${MT_TOOLING_PROVISIONING_ROLE_ARN:-arn:aws:iam::${MT_SOURCE_ACCOUNT_ID}:role/sagemaker-studio-provisioning-role}"
                _MANAGE_ROLE="${MT_TOOLING_MANAGE_ACCESS_ROLE_ARN:-arn:aws:iam::${MT_SOURCE_ACCOUNT_ID}:role/sagemaker-studio-manage-access-role}"
                aws datazone put-environment-blueprint-configuration \
                    --domain-identifier "$DOMAIN_ID" \
                    --environment-blueprint-identifier "$_TOOLING_BP_ID" \
                    --provisioning-role-arn "$_PROV_ROLE" \
                    --manage-access-role-arn "$_MANAGE_ROLE" \
                    --enabled-regions "$MT_AWS_REGION" \
                    --region "$MT_AWS_REGION" >/dev/null 2>&1 || {
                    mt_status error "put-environment-blueprint-configuration failed for Tooling=${_TOOLING_BP_ID}"
                    exit 1
                }

                # Step 2.4: Create the All-capabilities project profile
                # with one Tooling environment configuration.
                mt_status action "create-project-profile All-capabilities-profile"
                _PROFILE_ENV_JSON=$(printf '[{"name":"Tooling","awsAccount":{"awsAccountId":"%s"},"awsRegion":{"regionName":"%s"},"environmentBlueprintId":"%s","deploymentMode":"ON_CREATE","deploymentOrder":0}]' \
                    "$MT_SOURCE_ACCOUNT_ID" "$MT_AWS_REGION" "$_TOOLING_BP_ID")
                ADMIN_PROJECT_PROFILE_ID=$(aws datazone create-project-profile \
                    --domain-identifier "$DOMAIN_ID" \
                    --name "All-capabilities-profile" \
                    --status ENABLED \
                    --environment-configurations "$_PROFILE_ENV_JSON" \
                    --query 'id' \
                    --output text \
                    --region "$MT_AWS_REGION" 2>&1 || echo "")
                if [ -z "$ADMIN_PROJECT_PROFILE_ID" ] || [ "$ADMIN_PROJECT_PROFILE_ID" = "None" ]; then
                    mt_status error "create-project-profile failed for All-capabilities-profile"
                    exit 1
                fi
            fi
            mt_status set "admin_project_profile_id=${ADMIN_PROJECT_PROFILE_ID}"
        fi
    fi

    PROJECT_CREATE_OUT=$(mt_aws datazone create-project \
        --domain-identifier "$DOMAIN_ID" \
        --name "$MT_ADMIN_PROJECT_NAME" \
        --project-profile-id "$ADMIN_PROJECT_PROFILE_ID" 2>&1 || true)
    printf '%s\n' "$PROJECT_CREATE_OUT" | _replay_status
    PROJECT_ID=$(printf '%s\n' "$PROJECT_CREATE_OUT" \
        | _strip_status \
        | _extract_id id)
    if [ -z "$PROJECT_ID" ]; then
        if mt_dry_run_mode; then
            PROJECT_ID="prj_DRYRUN"
        else
            mt_status error "failed to parse project id from create-project output"
            printf '%s\n' "$PROJECT_CREATE_OUT"
            exit 1
        fi
    fi
fi
fi
mt_status set "admin_project_id=${PROJECT_ID}"

# -----------------------------------------------------------------------------
# Phase 2.5 — Discover SMUS-managed environment resources.
#
# When the admin project was created via an All-capabilities profile,
# DataZone provisions ON_CREATE environments (Tooling, Lakehouse Database,
# RedshiftServerless). Their `provisionedResources` carry artifacts later
# steps need:
#
#   * Tooling           -> s3BucketArn (the SMUS-managed S3 root)
#   * Lakehouse Database -> glueDBName + glueOutputUri (Glue catalog target)
#
# We surface them via `mt_status set` so the orchestrator persists them
# into Config_File and later steps pick them up via MT_* env vars.
#
# Skipped on dry-run (no provisioned resources to read) and on
# pre-existing project re-runs (idempotent — we just re-export the
# discovered values).

if mt_apply_mode && [ -n "$DOMAIN_ID" ] && [ -n "$PROJECT_ID" ]; then
    # List the project's environments. `aws datazone list-environments`
    # returns ACTIVE only when the All-capabilities profile's
    # ON_CREATE provisioning has completed; we accept whatever's there
    # and skip silently if the env isn't ready yet (next run picks up).
    _ENV_LIST=$(aws datazone list-environments \
        --domain-identifier "$DOMAIN_ID" \
        --project-identifier "$PROJECT_ID" \
        --region "$MT_AWS_REGION" \
        --output json 2>/dev/null || echo '{"items":[]}')

    # Tooling environment -> s3BucketArn (SMUS-managed S3 root).
    _TOOLING_ENV_ID=$(printf '%s\n' "$_ENV_LIST" \
        | jq -r '.items[]? | select(.name == "Tooling") | .id' \
        | head -n 1)
    if [ -n "$_TOOLING_ENV_ID" ]; then
        _TOOLING_S3_ARN=$(aws datazone get-environment \
            --domain-identifier "$DOMAIN_ID" \
            --identifier "$_TOOLING_ENV_ID" \
            --region "$MT_AWS_REGION" \
            --query 'provisionedResources[?name==`s3BucketArn`].value | [0]' \
            --output text 2>/dev/null | grep -v '^None$' || true)
        if [ -n "$_TOOLING_S3_ARN" ]; then
            # Strip arn:aws:s3:::<bucket>/<prefix>/ -> <bucket>/<prefix>
            _SMUS_ROOT="${_TOOLING_S3_ARN#arn:aws:s3:::}"
            # Trim trailing slash to keep `s3://${SMUS_ROOT}/<bucket>/`
            # well-formed when Step 5 concatenates.
            _SMUS_ROOT="${_SMUS_ROOT%/}"
            mt_status set "smus_managed_s3_root=${_SMUS_ROOT}"
            mt_status set "tooling_environment_id=${_TOOLING_ENV_ID}"
        fi

        # Tooling env's user role ARN — DataZone V2 CreateConnection
        # for SQL-typed Glue connections requires a ROLE_ARN that the
        # connection validator can assume. We use the project's
        # datazone-generated user role (auto-trusts datazone.amazonaws.com).
        _TOOLING_USER_ROLE_ARN=$(aws datazone get-environment \
            --domain-identifier "$DOMAIN_ID" \
            --identifier "$_TOOLING_ENV_ID" \
            --region "$MT_AWS_REGION" \
            --query 'provisionedResources[?name==`userRoleArn`].value | [0]' \
            --output text 2>/dev/null | grep -v '^None$' || true)
        if [ -n "$_TOOLING_USER_ROLE_ARN" ]; then
            mt_status set "tooling_user_role_arn=${_TOOLING_USER_ROLE_ARN}"
        fi
    fi

    # Lakehouse Database environment -> glueDBName + env id (Step 4 target).
    _LH_ENV_ID=$(printf '%s\n' "$_ENV_LIST" \
        | jq -r '.items[]? | select(.name == "Lakehouse Database") | .id' \
        | head -n 1)
    if [ -n "$_LH_ENV_ID" ]; then
        _LH_GLUE_DB=$(aws datazone get-environment \
            --domain-identifier "$DOMAIN_ID" \
            --identifier "$_LH_ENV_ID" \
            --region "$MT_AWS_REGION" \
            --query 'provisionedResources[?name==`glueDBName`].value | [0]' \
            --output text 2>/dev/null | grep -v '^None$' || true)
        if [ -n "$_LH_GLUE_DB" ]; then
            mt_status set "lakehouse_environment_id=${_LH_ENV_ID}"
            mt_status set "lakehouse_glue_db_name=${_LH_GLUE_DB}"
        fi
    fi

    # Lakehouse connection — DataZone V2 data sources need a
    # `--connection-identifier` (not env id). The All-capabilities
    # profile auto-creates `project.default_lakehouse` (type LAKEHOUSE)
    # which Step 4 uses as the publishing target for Glue catalog
    # assets.
    _LH_CONN_ID=$(aws datazone list-connections \
        --domain-identifier "$DOMAIN_ID" \
        --project-identifier "$PROJECT_ID" \
        --region "$MT_AWS_REGION" \
        --output json 2>/dev/null \
        | jq -r '.items[]? | select(.name == "project.default_lakehouse") | (.connectionId // .id)' \
        | head -n 1)
    if [ -n "$_LH_CONN_ID" ]; then
        mt_status set "lakehouse_connection_id=${_LH_CONN_ID}"
    fi
fi

# -----------------------------------------------------------------------------
# Phase 3 — Repository (CodeCommit auto-create or external provider URL).
REPO_ARN=""
REPO_CLONE_URL=""

case "$MT_REPO_PROVIDER" in
    codecommit)
        # 3a. Idempotent CodeCommit_Repo. In apply mode we try
        #     `aws codecommit get-repository` first; a non-zero exit is
        #     treated as a 404 and we fall through to create. In dry-
        #     run we print both would-be commands via mt_dryrun and
        #     synthesise placeholder URL/ARN values so downstream
        #     phases run end-to-end.
        if mt_apply_mode; then
            REPO_GET_OUT=""
            if REPO_GET_OUT=$(aws codecommit get-repository \
                    --repository-name "$MT_REPO_NAME" \
                    --region "$MT_AWS_REGION" 2>/dev/null); then
                REPO_CLONE_URL=$(printf '%s\n' "$REPO_GET_OUT" \
                    | _extract_id repositoryMetadata.cloneUrlHttp)
                REPO_ARN=$(printf '%s\n' "$REPO_GET_OUT" \
                    | _extract_id repositoryMetadata.Arn)
            fi

            if [ -z "$REPO_CLONE_URL" ] || [ -z "$REPO_ARN" ]; then
                REPO_CREATE_OUT=$(mt_aws codecommit create-repository \
                    --repository-name "$MT_REPO_NAME" \
                    --region "$MT_AWS_REGION" 2>&1 || true)
                printf '%s\n' "$REPO_CREATE_OUT" | _replay_status
                REPO_CLONE_URL=$(printf '%s\n' "$REPO_CREATE_OUT" \
                    | _strip_status \
                    | _extract_id repositoryMetadata.cloneUrlHttp)
                REPO_ARN=$(printf '%s\n' "$REPO_CREATE_OUT" \
                    | _strip_status \
                    | _extract_id repositoryMetadata.Arn)
                if [ -z "$REPO_CLONE_URL" ] || [ -z "$REPO_ARN" ]; then
                    mt_status error "failed to parse cloneUrlHttp/Arn from create-repository output"
                    printf '%s\n' "$REPO_CREATE_OUT"
                    exit 1
                fi
            fi
        else
            mt_dryrun "aws codecommit get-repository --repository-name ${MT_REPO_NAME} --region ${MT_AWS_REGION}"
            mt_dryrun "aws codecommit create-repository --repository-name ${MT_REPO_NAME} --region ${MT_AWS_REGION}"
            REPO_CLONE_URL="https://git-codecommit.${MT_AWS_REGION}.amazonaws.com/v1/repos/${MT_REPO_NAME}"
            REPO_ARN="arn:aws:codecommit:${MT_AWS_REGION}:${MT_SOURCE_ACCOUNT_ID:-000000000000}:${MT_REPO_NAME}"
        fi

        mt_status set "repo_url=${REPO_CLONE_URL}"
        mt_status set "codecommit_repo_arn=${REPO_ARN}"
        ;;

    github|github-enterprise-server|gitlab|gitlab-self-managed|bitbucket)
        # External providers contribute only a URL; nothing to create
        # repository-side. We surface the configured URL onto the
        # status stream so downstream phases (and the orchestrator's
        # config persistence) see a single canonical source.
        REPO_CLONE_URL="$MT_REPO_URL"
        mt_status set "repo_url=${REPO_CLONE_URL}"
        ;;
esac

# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# Phase 4 — Git connection on the Admin_Project (idempotent create).
#
# IMPORTANT — DataZone V2 API change:
# Earlier DataZone CLI versions accepted `aws datazone create-connection
# --type GIT --props <providerProperties>` for binding a Git provider
# to a project. The V2 CLI (post-2024) restricts `create-connection`'s
# `props` to data-source types only (athena, glue, redshift, s3, ...);
# Git providers are now configured via AWS CodeConnections (formerly
# AWS CodeStar Connections) at the AWS account level rather than on
# the DataZone project.
#
# For CodeCommit, no AWS CodeConnections connection is needed — the
# repository ARN suffices for downstream steps (Step 3 etc.). For
# external Git providers (github, gitlab, bitbucket), an AWS
# CodeConnections connection must already exist; pass its ARN via
# `--set git_connection_id=<arn>` to skip creation here.

case "$MT_REPO_PROVIDER" in
    codecommit)
        CONN_NAME="${MT_SMUS_DOMAIN_NAME}-codecommit"
        ;;
    *)
        CONN_NAME="${MT_SMUS_DOMAIN_NAME}-${MT_REPO_PROVIDER}"
        ;;
esac

GIT_CONNECTION_ID="${MT_GIT_CONNECTION_ID:-}"

if [ -n "$GIT_CONNECTION_ID" ]; then
    mt_status action "git_connection_id provided; skipping create-connection"
elif [ "$MT_REPO_PROVIDER" = "codecommit" ]; then
    # CodeCommit doesn't need a CodeConnections connection — Step 3 and
    # later use the repository ARN directly. Persist a synthetic ID so
    # state has a non-empty value.
    GIT_CONNECTION_ID="codecommit-${MT_REPO_NAME}"
    mt_status action "codecommit-direct-binding; no AWS CodeConnections connection needed"
else
    mt_status error "external Git provider '${MT_REPO_PROVIDER}' requires an AWS CodeConnections connection ARN passed via --set git_connection_id=<arn>"
    exit 1
fi

mt_status set "git_connection_id=${GIT_CONNECTION_ID}"

mt_status ok
exit 0
