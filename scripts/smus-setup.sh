#!/usr/bin/env bash
#
# smus-setup.sh — single-purpose CFN bootstrapper for SageMaker Unified
# Studio.
#
# Stands up a complete SMUS domain + admin project in the target
# account using CloudFormation as the deployment surface, with a
# small set of post-deploy AWS CLI calls that CFN can't model
# (Lake Formation grants on existing Glue resources, KMS key policy
# additions for the dynamic project user role, IDC group/user
# provisioning, IAM inline policies on the project user role).
#
# What this script DOES:
#   * Interactive IDC group prompts (admin, DE, consumer)
#   * IDC group + seed user provisioning (defaults only)
#   * IAM bootstrap for SMUS domain execution / service / provisioning
#     / managed-access roles
#   * CFN stack deploy (master + 5 child stacks under cfn/)
#   * Lake Formation hardening: revoke IAMAllowedPrincipals, grant
#     project user role + manage-access role on every external Glue
#     DB/table
#   * SMUS session bootstrap: tooling-bucket LF hybrid mode, KMS key
#     policy, WithFederation re-registration of source S3 prefixes,
#     LF data-lake-settings (FGAC + session tags), `LakeFormationFGACAccess`
#     and `GlueCatalogReadAccess` inline policies on the project user role
#   * CodeCommit Git-ops grant on the project user role
#
# What this script DOES NOT do (`migrate.sh` owns those):
#   * The 9-step migration tool run
#   * Auto-subscribe to Glue assets
#   * Resource-link DESCRIBE grants
#   * Repo bootstrap / aws-smus-cicd-cli install
#
# Persists:
#   * config/smus-setup.config.json — group names + discovered IDs
#   * state/smus-setup.state.json — completion marker
#
# Usage:
#   ./smus-setup.sh setup    [MODE] [WHERE] [--yes] [CFN-PARAM-OVERRIDES...]
#   ./smus-setup.sh status
#   ./smus-setup.sh teardown [MODE] [--yes] [--keep-cfn] [--keep-iam-roles]
#   ./smus-setup.sh -h | --help
#
# MODE          : --apply | --dry-run             (default: dry-run)
# WHERE         : --profile NAME                  (or AWS_PROFILE env var)
#                 --region NAME                   (or AWS_DEFAULT_REGION env var)
#
# CFN PARAM OVERRIDES (all optional; resolved CLI > env > config file > default):
#   --domain-name NAME                 SMUS domain display name (default: smus-seed-domain)
#   --admin-project-name NAME          Admin project name        (default: smus-admin)
#   --admin-group NAME                 IDC group that owns the admin project
#                                                                (default: smus-admins, prompted on first run)
#   --de-group NAME                    IDC data-engineer group   (default: smus-data-engineers)
#   --consumer-group NAME              IDC data-consumer group   (default: smus-data-consumers)
#   --sso-instance-arn ARN             IDC instance ARN          (default: discovered via aws sso-admin list-instances)
#   --vpc-id ID                        Tooling-blueprint VPC ID  (default: from seed/seed.state.json)
#   --subnet-ids CSV                   Private subnet IDs CSV    (default: from seed/seed.state.json)
#   --tooling-bucket NAME              Tooling S3 bucket         (default: amazon-datazone-tooling-<acct>-<region>)
#   --templates-bucket NAME            CFN templates + Lambda source bucket
#                                                                (default: smus-seed-cfn-<acct>-<region>)
#   --lambda-source-prefix STR         Optional prefix in templates bucket
#                                                                (default: empty)
#   --domain-execution-role-name NAME  Domain execution IAM role (default: sagemaker-domain-execution)
#   --domain-service-role-name NAME    Domain service IAM role   (default: AmazonDataZoneServiceRole)
#   --automation-role-name NAME        In-stack Lambda role      (default: smus-seed-automation-role)
#   --automation-role-policy-name NAME Policy on automation role (default: smus-seed-automation-policy)
#   --managed-access-role-name NAME    Manage-access IAM role    (default: sagemaker-studio-manage-access-role)
#   --stack-name NAME                  Top-level CFN stack name  (default: smus-seed)
#
# Git repository / connection wiring (all optional):
#   --repo-provider PROV               CodeCommit | GitHub | GitLab | Bitbucket  (default: CodeCommit)
#   --repo-name NAME                   Name of the repo (CodeCommit) or connection (3P)
#                                                                (default: <domain-name>-migration)
#   --repo-url URL                     Required for 3P providers; e.g. https://github.com/<org>/<repo>.git
#   --repo-connection-arn ARN          Pre-existing AWS CodeConnections ARN — skips connection creation
#                                       in CFN (use this for GitHub Enterprise Server / GitLab Self-Managed,
#                                       which need a separate Host resource you create in the console first).
#

set -uo pipefail
set +u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=_lib/common.sh
source "${ROOT_DIR}/_lib/common.sh"

ACTION=""
MODE_FLAG=""
PROFILE=""
REGION=""
ASSUME_YES=0
TEARDOWN_KEEP_CFN=0
TEARDOWN_KEEP_IAM=0

# CLI overrides for CFN parameters. Each is empty until set by a flag;
# `_resolve_cfn_param` walks the priority chain (CLI > env > config > auto > default)
# at deploy time. See README "CloudFormation parameters" for details.
CLI_DOMAIN_NAME=""
CLI_ADMIN_PROJECT_NAME=""
CLI_ADMIN_GROUP=""
CLI_DE_GROUP=""
CLI_CONSUMER_GROUP=""
CLI_SSO_INSTANCE_ARN=""
CLI_VPC_ID=""
CLI_SUBNET_IDS=""
CLI_TOOLING_BUCKET=""
CLI_TEMPLATES_BUCKET=""
CLI_LAMBDA_SOURCE_PREFIX=""
CLI_DOMAIN_EXECUTION_ROLE_NAME=""
CLI_DOMAIN_SERVICE_ROLE_NAME=""
CLI_AUTOMATION_ROLE_NAME=""
CLI_AUTOMATION_ROLE_POLICY_NAME=""
CLI_MANAGED_ACCESS_ROLE_NAME=""
# Top-level CFN stack name. Defaults to "smus-seed" for the seed
# tutorial flow; customers running this against their own
# infrastructure can override (e.g. "acme-platform-smus") to keep
# stacks in their account namespaced.
CLI_STACK_NAME=""
# Git repository / connection wiring (managed at the domain level).
# CodeCommit (default) creates an in-account repo via CFN; any 3P value
# creates an AWS::CodeConnections::Connection that lands in PENDING and
# requires a one-time console authorize. See README "Git connection".
CLI_REPO_PROVIDER=""
CLI_REPO_NAME=""
CLI_REPO_URL=""
CLI_REPO_CONNECTION_ARN=""

usage() { sed -n '2,79p' "$0"; exit 64; }

# -----------------------------------------------------------------------------
# CLI parsing
# -----------------------------------------------------------------------------

if [ $# -eq 0 ]; then
    usage
fi

case "$1" in
    setup|status|teardown) ACTION="$1"; shift ;;
    -h|--help) usage ;;
    *)
        echo "ERROR: unknown action '$1' (valid: setup, status, teardown)" >&2
        usage
        ;;
esac

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)
            if [ "$MODE_FLAG" = "--dry-run" ]; then
                echo "ERROR: --apply and --dry-run are mutually exclusive" >&2
                exit 64
            fi
            MODE_FLAG="--apply"
            shift
            ;;
        --dry-run)
            if [ "$MODE_FLAG" = "--apply" ]; then
                echo "ERROR: --apply and --dry-run are mutually exclusive" >&2
                exit 64
            fi
            MODE_FLAG="--dry-run"
            shift
            ;;
        --profile)   PROFILE="$2"; shift 2 ;;
        --profile=*) PROFILE="${1#*=}"; shift ;;
        --region)    REGION="$2"; shift 2 ;;
        --region=*)  REGION="${1#*=}"; shift ;;
        --yes|-y)    ASSUME_YES=1; shift ;;
        --keep-cfn)  TEARDOWN_KEEP_CFN=1; shift ;;
        --keep-iam-roles) TEARDOWN_KEEP_IAM=1; shift ;;
        # ---- CFN parameter overrides (all optional). ----
        --domain-name)                  CLI_DOMAIN_NAME="$2"; shift 2 ;;
        --domain-name=*)                CLI_DOMAIN_NAME="${1#*=}"; shift ;;
        --admin-project-name)           CLI_ADMIN_PROJECT_NAME="$2"; shift 2 ;;
        --admin-project-name=*)         CLI_ADMIN_PROJECT_NAME="${1#*=}"; shift ;;
        --admin-group)                  CLI_ADMIN_GROUP="$2"; shift 2 ;;
        --admin-group=*)                CLI_ADMIN_GROUP="${1#*=}"; shift ;;
        --de-group)                     CLI_DE_GROUP="$2"; shift 2 ;;
        --de-group=*)                   CLI_DE_GROUP="${1#*=}"; shift ;;
        --consumer-group)               CLI_CONSUMER_GROUP="$2"; shift 2 ;;
        --consumer-group=*)             CLI_CONSUMER_GROUP="${1#*=}"; shift ;;
        --sso-instance-arn)             CLI_SSO_INSTANCE_ARN="$2"; shift 2 ;;
        --sso-instance-arn=*)           CLI_SSO_INSTANCE_ARN="${1#*=}"; shift ;;
        --vpc-id)                       CLI_VPC_ID="$2"; shift 2 ;;
        --vpc-id=*)                     CLI_VPC_ID="${1#*=}"; shift ;;
        --subnet-ids)                   CLI_SUBNET_IDS="$2"; shift 2 ;;
        --subnet-ids=*)                 CLI_SUBNET_IDS="${1#*=}"; shift ;;
        --tooling-bucket)               CLI_TOOLING_BUCKET="$2"; shift 2 ;;
        --tooling-bucket=*)             CLI_TOOLING_BUCKET="${1#*=}"; shift ;;
        --templates-bucket)             CLI_TEMPLATES_BUCKET="$2"; shift 2 ;;
        --templates-bucket=*)           CLI_TEMPLATES_BUCKET="${1#*=}"; shift ;;
        --lambda-source-prefix)         CLI_LAMBDA_SOURCE_PREFIX="$2"; shift 2 ;;
        --lambda-source-prefix=*)       CLI_LAMBDA_SOURCE_PREFIX="${1#*=}"; shift ;;
        --domain-execution-role-name)   CLI_DOMAIN_EXECUTION_ROLE_NAME="$2"; shift 2 ;;
        --domain-execution-role-name=*) CLI_DOMAIN_EXECUTION_ROLE_NAME="${1#*=}"; shift ;;
        --domain-service-role-name)     CLI_DOMAIN_SERVICE_ROLE_NAME="$2"; shift 2 ;;
        --domain-service-role-name=*)   CLI_DOMAIN_SERVICE_ROLE_NAME="${1#*=}"; shift ;;
        --automation-role-name)         CLI_AUTOMATION_ROLE_NAME="$2"; shift 2 ;;
        --automation-role-name=*)       CLI_AUTOMATION_ROLE_NAME="${1#*=}"; shift ;;
        --automation-role-policy-name)  CLI_AUTOMATION_ROLE_POLICY_NAME="$2"; shift 2 ;;
        --automation-role-policy-name=*) CLI_AUTOMATION_ROLE_POLICY_NAME="${1#*=}"; shift ;;
        --managed-access-role-name)     CLI_MANAGED_ACCESS_ROLE_NAME="$2"; shift 2 ;;
        --managed-access-role-name=*)   CLI_MANAGED_ACCESS_ROLE_NAME="${1#*=}"; shift ;;
        --stack-name)                   CLI_STACK_NAME="$2"; shift 2 ;;
        --stack-name=*)                 CLI_STACK_NAME="${1#*=}"; shift ;;
        # ---- Git repository / connection wiring. ----
        --repo-provider)                CLI_REPO_PROVIDER="$2"; shift 2 ;;
        --repo-provider=*)              CLI_REPO_PROVIDER="${1#*=}"; shift ;;
        --repo-name)                    CLI_REPO_NAME="$2"; shift 2 ;;
        --repo-name=*)                  CLI_REPO_NAME="${1#*=}"; shift ;;
        --repo-url)                     CLI_REPO_URL="$2"; shift 2 ;;
        --repo-url=*)                   CLI_REPO_URL="${1#*=}"; shift ;;
        --repo-connection-arn)          CLI_REPO_CONNECTION_ARN="$2"; shift 2 ;;
        --repo-connection-arn=*)        CLI_REPO_CONNECTION_ARN="${1#*=}"; shift ;;
        *)
            echo "ERROR: unknown flag '$1' for action '${ACTION}'" >&2
            usage
            ;;
    esac
done

if [ -n "$PROFILE" ]; then export AWS_PROFILE="$PROFILE"; fi
if [ -n "$REGION" ];  then export AWS_DEFAULT_REGION="$REGION"; fi

LOG_DIR="${ROOT_DIR}/logs"
mkdir -p "$LOG_DIR"

# =============================================================================
# Helper functions (extracted from migrate.sh).
# =============================================================================


# -----------------------------------------------------------------------------
# _prompt_idc_groups
#
# Interactive prompt for the three IDC group names that drive
# project ownership and seed user provisioning:
#
#   * MT_ADMIN_GROUP_NAME    — owns the admin project + root domain unit
#   * MT_DE_GROUP_NAME       — data-engineer role
#   * MT_CONSUMER_GROUP_NAME — data-consumer role
#
# Behaviour:
#   - Skipped on dry-run.
#   - Each env var, if already exported (via `--set <key>=<value>` or
#     a prior call), is taken as-is — no prompt.
#   - Otherwise, with a TTY: prompt with the default in brackets;
#     Enter accepts the default, any other input replaces it.
#   - Otherwise, with `--yes` and no TTY: silently use defaults.
#
# After collecting all three names, validate that every group exists
# in IDC. The default-named groups are auto-created in
# `_idc_bootstrap` if missing; operator-supplied custom names that
# don't exist are a HARD ERROR (exit 65). This prevents the migration
# from completing against a non-existent ownership target — the
# operator must create the group in IDC and re-run.
#
# Persists the three values into config/smus-setup.config.json so a
# subsequent `migrate.sh status` / re-run shows them and a
# `--reconfigure` re-prompts.
# -----------------------------------------------------------------------------

_prompt_idc_groups() {
    if [ "$MODE_FLAG" != "--apply" ]; then
        echo "==> IDC group prompt: skipped (not in --apply mode)"
        return 0
    fi

    # Defaults match the seed convention so a plain `--apply --yes`
    # behaves identically to the pre-prompt era.
    local _admin_default="smus-admins"
    local _de_default="smus-data-engineers"
    local _consumer_default="smus-data-consumers"

    # Read existing values from config/smus-setup.config.json so a
    # second run (without --reconfigure) reuses the operator's
    # previous choice.
    local _cfg="${ROOT_DIR}/config/smus-setup.config.json"
    local _cfg_admin _cfg_de _cfg_consumer
    if [ -f "$_cfg" ] && command -v jq >/dev/null 2>&1; then
        _cfg_admin="$(jq -r '.admin_group_name // empty' "$_cfg" 2>/dev/null)"
        _cfg_de="$(jq -r '.de_group_name // empty' "$_cfg" 2>/dev/null)"
        _cfg_consumer="$(jq -r '.consumer_group_name // empty' "$_cfg" 2>/dev/null)"
    fi

    # Resolution priority: env override > saved config > prompt > default.
    local _admin="${MT_ADMIN_GROUP_NAME:-${_cfg_admin:-}}"
    local _de="${MT_DE_GROUP_NAME:-${_cfg_de:-}}"
    local _consumer="${MT_CONSUMER_GROUP_NAME:-${_cfg_consumer:-}}"

    # Prompt for any value that isn't already pinned.
    local _have_tty=0
    [ -r /dev/tty ] && [ -w /dev/tty ] && _have_tty=1

    _prompt_one() {
        # Args: var-ref, label, default
        local _var="$1" _label="$2" _default="$3"
        local _current
        eval "_current=\${${_var}:-}"
        if [ -n "$_current" ]; then
            echo "==> ${_label}: ${_current} (already set)"
            return 0
        fi
        if [ "$_have_tty" -eq 1 ] && [ "$ASSUME_YES" -ne 1 ]; then
            local _typed=""
            {
                printf "%s [%s]: " "$_label" "$_default"
            } >/dev/tty
            IFS= read -r _typed </dev/tty || _typed=""
            _typed="$(printf '%s' "$_typed" | awk '{$1=$1; print}')"
            if [ -z "$_typed" ]; then
                _typed="$_default"
            fi
            if ! printf '%s' "$_typed" | grep -qE '^[A-Za-z0-9._-]{1,128}$'; then
                echo "==> ERROR: invalid group name '${_typed}' (must match [A-Za-z0-9._-]{1,128})" >&2
                exit 64
            fi
            eval "${_var}=\"\${_typed}\""
            echo "==> ${_label}: ${_typed}"
        else
            eval "${_var}=\"\${_default}\""
            echo "==> ${_label}: ${_default} (default; non-interactive)"
        fi
    }

    _prompt_one _admin    "Admin group name"          "$_admin_default"
    _prompt_one _de       "Data engineer group name"  "$_de_default"
    _prompt_one _consumer "Data consumer group name"  "$_consumer_default"

    # All three group names must be distinct so each role lands on a
    # separate IDC group; otherwise SMUS group resolution would be
    # ambiguous on shared memberships.
    if [ "$_admin" = "$_de" ] || [ "$_admin" = "$_consumer" ] || [ "$_de" = "$_consumer" ]; then
        echo "==> ERROR: admin / DE / consumer groups must all be distinct (got '${_admin}', '${_de}', '${_consumer}')" >&2
        exit 64
    fi

    export MT_ADMIN_GROUP_NAME="$_admin"
    export MT_DE_GROUP_NAME="$_de"
    export MT_CONSUMER_GROUP_NAME="$_consumer"

    # Halt-on-missing for any custom (non-default) group. Defaults are
    # tolerated because `_idc_bootstrap` will create them on the fly.
    # We need IDC env first; if `_idc_bootstrap` hasn't run yet
    # (which is the case at this point — we run BEFORE it), discover
    # the IDC instance ourselves so we can validate group existence.
    local _account _list_json _identity_store_id
    _account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")"
    if [ -z "$_account" ]; then
        echo "==> IDC group prompt: WARN — couldn't discover account; skipping group existence check"
        return 0
    fi
    _list_json="$(aws sso-admin list-instances --output json 2>/dev/null || echo '{}')"
    _identity_store_id="$(printf '%s' "$_list_json" | jq -r --arg acct "$_account" \
        '(.Instances // []) | map(select(.OwnerAccountId == $acct)) | (.[0].IdentityStoreId // "")')"
    if [ -z "$_identity_store_id" ]; then
        echo "==> IDC group prompt: WARN — no account-local IDC instance; skipping group existence check"
        return 0
    fi

    # Halt rule: any operator-provided (non-default) group name that
    # isn't present in IDC stops the run. Defaults are auto-created
    # by _idc_bootstrap and therefore tolerated as missing.
    local _g _gdefault _gname
    for _g in "admin|${_admin}|${_admin_default}" \
              "de|${_de}|${_de_default}" \
              "consumer|${_consumer}|${_consumer_default}"; do
        IFS='|' read -r _ _gname _gdefault <<<"$_g"
        if [ "$_gname" = "$_gdefault" ]; then
            continue
        fi
        local _gid
        _gid="$(aws identitystore list-groups \
            --identity-store-id "$_identity_store_id" \
            --filters "AttributePath=DisplayName,AttributeValue=${_gname}" \
            --query 'Groups[0].GroupId' --output text 2>/dev/null | grep -v '^None$' || true)"
        if [ -z "$_gid" ]; then
            echo "==> ERROR: idc_group_not_found ${_gname}" >&2
            echo "    The IDC instance ${_identity_store_id} (account ${_account}) does not contain a group" >&2
            echo "    named '${_gname}'. Create the group in IDC and re-run, or run with --reconfigure" >&2
            echo "    to pick a different name." >&2
            exit 65
        fi
        echo "    + verified ${_gname} exists in IDC (${_gid})"
    done

    # Persist for subsequent runs only AFTER existence check passes.
    # That way a halt-on-missing leaves config intact and the operator
    # doesn't have to manually unwind a bad value before re-running.
    if [ -d "$(dirname "$_cfg")" ] && command -v jq >/dev/null 2>&1; then
        local _existing='{}'
        [ -f "$_cfg" ] && _existing="$(cat "$_cfg")"
        local _merged
        _merged="$(printf '%s' "$_existing" | jq \
            --arg admin "$_admin" \
            --arg de "$_de" \
            --arg consumer "$_consumer" \
            '. + {admin_group_name: $admin, de_group_name: $de, consumer_group_name: $consumer}')"
        printf '%s\n' "$_merged" > "$_cfg"
    fi

    echo "==> IDC group prompt: complete (admin=${_admin}, de=${_de}, consumer=${_consumer})"
}


_idc_bootstrap() {
    if [ "$MODE_FLAG" != "--apply" ]; then
        echo "==> IDC bootstrap: skipped (not in --apply mode)"
        return 0
    fi
    if ! command -v aws >/dev/null 2>&1; then
        echo "==> IDC bootstrap: skipped (aws CLI not on PATH)"
        return 0
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo "==> IDC bootstrap: skipped (jq not on PATH)"
        return 0
    fi

    # Discover the caller's account so we can pick the right IDC instance.
    local _account
    _account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")"
    if [ -z "$_account" ]; then
        echo "==> IDC bootstrap: skipped (could not resolve caller account)"
        return 0
    fi

    # Find the account-local IDC instance (OwnerAccountId == caller).
    local _list_json
    _list_json="$(aws sso-admin list-instances --output json 2>/dev/null || echo '{}')"
    local _instance_arn _identity_store_id
    _instance_arn="$(printf '%s' "$_list_json" | jq -r --arg acct "$_account" \
        '(.Instances // []) | map(select(.OwnerAccountId == $acct)) | (.[0].InstanceArn // "")')"
    _identity_store_id="$(printf '%s' "$_list_json" | jq -r --arg acct "$_account" \
        '(.Instances // []) | map(select(.OwnerAccountId == $acct)) | (.[0].IdentityStoreId // "")')"

    if [ -z "$_instance_arn" ] || [ -z "$_identity_store_id" ]; then
        echo "==> IDC bootstrap: skipped (no account-local IDC instance for ${_account})"
        echo "    Visible instances:"
        printf '%s' "$_list_json" | jq -r '(.Instances // [])[] | "    - \(.InstanceArn) (owner=\(.OwnerAccountId))"' 2>/dev/null
        return 0
    fi

    echo "==> IDC bootstrap: account-local instance ${_instance_arn} (${_identity_store_id})"

    # Export so the migration tool's prompts can default to these.
    export MT_IDENTITY_CENTER_INSTANCE_ARN="$_instance_arn"
    export MT_IDENTITY_CENTER_IDENTITY_STORE_ID="$_identity_store_id"

    # Group + user definitions. Group names come from the operator's
    # interactive prompts (`_prompt_idc_groups`) which exported the
    # three MT_*_GROUP_NAME env vars. Defaults match the seed (so a
    # plain `migrate.sh run --apply --yes` provisions the same groups
    # and users as before). Operators who provide custom group names
    # are responsible for populating those groups themselves; we only
    # provision the seed users (smus-admin / smus-de / smus-consumer)
    # for groups whose name still matches the corresponding default.
    local _admin_group="${MT_ADMIN_GROUP_NAME:-smus-admins}"
    local _de_group="${MT_DE_GROUP_NAME:-smus-data-engineers}"
    local _consumer_group="${MT_CONSUMER_GROUP_NAME:-smus-data-consumers}"

    local _groups=(
        "${_admin_group}|SMUS admin role group"
        "${_de_group}|SMUS data engineer role group"
        "${_consumer_group}|SMUS data consumer role group"
    )
    # Seed user tuples are tagged with the GROUP-NAME-DEFAULT (the
    # canonical seed name) so we can decide later whether to provision
    # them. If the operator kept the default for that group, create
    # the seed user; otherwise skip.
    local _users=(
        "smus-admin|SMUS|Admin|smus-admin@example.com|${_admin_group}|smus-admins"
        "smus-de|SMUS|DataEngineer|smus-de@example.com|${_de_group}|smus-data-engineers"
        "smus-consumer|SMUS|Consumer|smus-consumer@example.com|${_consumer_group}|smus-data-consumers"
    )

    # Track group display-name -> group-id via two parallel arrays so
    # the helper works on bash 3.2 (no associative-array support).
    local -a _gname_keys=()
    local -a _gid_vals=()
    local _g _gname _gdesc _gid
    for _g in "${_groups[@]}"; do
        _gname="${_g%%|*}"
        _gdesc="${_g##*|}"
        _gid="$(aws identitystore list-groups \
            --identity-store-id "$_identity_store_id" \
            --filters "AttributePath=DisplayName,AttributeValue=${_gname}" \
            --query 'Groups[0].GroupId' --output text 2>/dev/null | grep -v '^None$' || true)"
        if [ -z "$_gid" ]; then
            _gid="$(aws identitystore create-group \
                --identity-store-id "$_identity_store_id" \
                --display-name "$_gname" \
                --description "$_gdesc" \
                --query 'GroupId' --output text 2>/dev/null || echo "")"
            if [ -z "$_gid" ]; then
                echo "    WARN: failed to create group ${_gname}; skipping"
                continue
            fi
            echo "    + group created: ${_gname} (${_gid})"
        else
            echo "    = group exists:  ${_gname} (${_gid})"
        fi
        _gname_keys+=("$_gname")
        _gid_vals+=("$_gid")
    done

    # Resolve a group ID by display name from the parallel arrays.
    _lookup_gid() {
        local _needle="$1"
        local _i=0
        while [ "$_i" -lt "${#_gname_keys[@]}" ]; do
            if [ "${_gname_keys[$_i]}" = "$_needle" ]; then
                printf '%s' "${_gid_vals[$_i]}"
                return 0
            fi
            _i=$((_i + 1))
        done
        return 1
    }

    # Users.
    local _u _uname _given _family _email _ugroup _udefault _uid _existing_uid _payload
    for _u in "${_users[@]}"; do
        IFS='|' read -r _uname _given _family _email _ugroup _udefault <<<"$_u"

        # Skip seed user provisioning when the operator picked a
        # custom group name. Their own group is theirs to populate;
        # we don't know who should be in it.
        if [ "$_ugroup" != "$_udefault" ]; then
            echo "    = skipping seed user ${_uname}; ${_ugroup} is operator-provided"
            continue
        fi

        _existing_uid="$(aws identitystore list-users \
            --identity-store-id "$_identity_store_id" \
            --filters "AttributePath=UserName,AttributeValue=${_uname}" \
            --query 'Users[0].UserId' --output text 2>/dev/null | grep -v '^None$' || true)"
        if [ -n "$_existing_uid" ]; then
            _uid="$_existing_uid"
            echo "    = user exists:   ${_uname} (${_uid})"
        else
            # JSON payload via tempfile keeps quoting predictable.
            local _utmp
            _utmp="$(mktemp -t "mt-idc-user-XXXXXX.json")"
            cat > "$_utmp" <<JSON
{
    "IdentityStoreId": "${_identity_store_id}",
    "UserName": "${_uname}",
    "DisplayName": "${_given} ${_family}",
    "Name": {"GivenName": "${_given}", "FamilyName": "${_family}"},
    "Emails": [{"Value": "${_email}", "Type": "work", "Primary": true}]
}
JSON
            _uid="$(aws identitystore create-user --cli-input-json "file://${_utmp}" \
                --query 'UserId' --output text 2>/dev/null || echo "")"
            rm -f "$_utmp"
            if [ -z "$_uid" ]; then
                echo "    WARN: failed to create user ${_uname}; skipping membership"
                continue
            fi
            echo "    + user created:  ${_uname} (${_uid})"
        fi

        # Wire membership to the group named in the tuple.
        _gid="$(_lookup_gid "$_ugroup" || true)"
        if [ -z "$_gid" ]; then
            echo "    WARN: group ${_ugroup} missing; cannot wire membership for ${_uname}"
            continue
        fi
        local _existing_member
        _existing_member="$(aws identitystore get-group-membership-id \
            --identity-store-id "$_identity_store_id" \
            --group-id "$_gid" \
            --member-id "UserId=${_uid}" \
            --query 'MembershipId' --output text 2>/dev/null | grep -v '^None$' || true)"
        if [ -n "$_existing_member" ]; then
            echo "    = membership:    ${_uname} -> ${_ugroup}"
        else
            aws identitystore create-group-membership \
                --identity-store-id "$_identity_store_id" \
                --group-id "$_gid" \
                --member-id "UserId=${_uid}" \
                --query 'MembershipId' --output text >/dev/null 2>&1 || true
            echo "    + membership:    ${_uname} -> ${_ugroup}"
        fi
    done

    echo "==> IDC bootstrap: complete"
}


_iam_bootstrap() {
    if [ "$MODE_FLAG" != "--apply" ]; then
        echo "==> IAM bootstrap: skipped (not in --apply mode)"
        return 0
    fi
    if ! command -v aws >/dev/null 2>&1; then
        echo "==> IAM bootstrap: skipped (aws CLI not on PATH)"
        return 0
    fi

    # NOTE: All four IAM roles previously created by this helper are now
    # owned by CloudFormation and live in `cfn/child-stacks/`:
    #
    #   * `sagemaker-domain-execution`           → sus-domain-stack.yaml (rSUSDomainExecutionRole)
    #   * `AmazonDataZoneServiceRole`            → sus-domain-stack.yaml (rSUSDomainServiceRole)
    #   * `sagemaker-studio-provisioning-role`   → sus-domain-stack.yaml (rSUSToolingProvisioningRole)
    #   * `sagemaker-studio-manage-access-role`  → sus-blueprints-stack.yaml (rSUSDomainManagedAccessRole)
    #
    # The `amazon-datazone-projects-<acct>-<region>` S3 bucket is also
    # CFN-managed (sus-domain-stack.yaml rSUSProjectsBucket).
    #
    # `_cfn_bootstrap` reads the resulting ARNs from the master stack's
    # nested-stack outputs and exports them as `MT_DOMAIN_SERVICE_ROLE`,
    # `MT_TOOLING_PROVISIONING_ROLE_ARN`, `MT_TOOLING_MANAGE_ACCESS_ROLE_ARN`,
    # and `MT_TOOLING_PROJECTS_BUCKET` for downstream helpers.
    #
    # Pre-flight: strip any dangling LF data-lake admins so that
    # `rAddDataLakeAdministratorToLakeFormation` (in the project
    # sub-stack) doesn't fail at create time on stale principals
    # left over from a previous teardown.
    _lf_strip_dangling_admins "${AWS_DEFAULT_REGION:-us-east-1}"

    # Pre-flight: delete any non-CFN-managed orphans of the four
    # role names + projects bucket that this stack will create.
    # Older runs of this script created these resources directly via
    # the AWS CLI; on accounts upgrading to the CFN-managed flow
    # those orphans would block CFN's `CreateRole` / `CreateBucket`
    # with `EntityAlreadyExists` / `BucketAlreadyExists`.
    _iam_purge_orphans

    echo "==> IAM bootstrap: roles + bucket are now CFN-managed (see sus-domain-stack.yaml + sus-blueprints-stack.yaml); skipping CLI provisioning"
    echo "==> IAM bootstrap: complete"
}


# -----------------------------------------------------------------------------
# _iam_purge_orphans
#
# Walk the four IAM roles + one S3 bucket that `cfn/child-stacks/` will
# create, and delete any that exist BUT are not CFN-managed. A role is
# considered CFN-managed when its tags include
# `aws:cloudformation:stack-name`; a bucket is CFN-managed when the
# same tag appears in `get-bucket-tagging`.
#
# CFN-managed resources are left untouched — they're owned by an
# active stack and a fresh deploy will be a no-op.
#
# Non-CFN orphans are typically left over from earlier `smus-setup.sh`
# versions that created these resources via `aws iam create-role`.
# This helper detaches all managed/inline policies, deletes the role
# (or empties + deletes the bucket), and prints what it did.
#
# Idempotent: re-running on a clean account is a no-op.
# -----------------------------------------------------------------------------

_iam_purge_orphans() {
    local _region="${AWS_DEFAULT_REGION:-us-east-1}"
    local _account_id
    _account_id="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")"

    # ----- IAM roles -----
    local _role
    for _role in sagemaker-domain-execution \
                 AmazonDataZoneServiceRole \
                 sagemaker-studio-provisioning-role \
                 sagemaker-studio-manage-access-role; do
        if ! aws iam get-role --role-name "$_role" >/dev/null 2>&1; then
            continue
        fi

        # CFN-managed roles carry an `aws:cloudformation:stack-name` tag.
        local _is_cfn
        _is_cfn="$(aws iam list-role-tags --role-name "$_role" \
            --query 'Tags[?Key==`aws:cloudformation:stack-name`].Value | [0]' \
            --output text 2>/dev/null | grep -v '^None$' || true)"
        if [ -n "$_is_cfn" ]; then
            echo "    = CFN-managed role left in place: ${_role} (stack: ${_is_cfn})"
            continue
        fi

        echo "    + purging non-CFN orphan role: ${_role}"
        # Detach managed policies.
        local _attached_policies _ap
        _attached_policies="$(aws iam list-attached-role-policies \
            --role-name "$_role" --query 'AttachedPolicies[].PolicyArn' \
            --output text 2>/dev/null || true)"
        for _ap in $_attached_policies; do
            [ -z "$_ap" ] || [ "$_ap" = "None" ] && continue
            aws iam detach-role-policy --role-name "$_role" \
                --policy-arn "$_ap" >/dev/null 2>&1 || true
        done
        # Delete inline policies.
        local _inline_policies _ip
        _inline_policies="$(aws iam list-role-policies \
            --role-name "$_role" --query 'PolicyNames' \
            --output text 2>/dev/null || true)"
        for _ip in $_inline_policies; do
            [ -z "$_ip" ] || [ "$_ip" = "None" ] && continue
            aws iam delete-role-policy --role-name "$_role" \
                --policy-name "$_ip" >/dev/null 2>&1 || true
        done
        # Delete instance profiles that still reference this role.
        # (Older bash flow occasionally created them; CFN doesn't.)
        local _profiles _prof
        _profiles="$(aws iam list-instance-profiles-for-role \
            --role-name "$_role" --query 'InstanceProfiles[].InstanceProfileName' \
            --output text 2>/dev/null || true)"
        for _prof in $_profiles; do
            [ -z "$_prof" ] || [ "$_prof" = "None" ] && continue
            aws iam remove-role-from-instance-profile \
                --instance-profile-name "$_prof" --role-name "$_role" >/dev/null 2>&1 || true
        done
        # Final delete.
        if aws iam delete-role --role-name "$_role" >/dev/null 2>&1; then
            echo "      + deleted role ${_role}"
        else
            echo "      WARN: failed to delete ${_role}; CFN deploy may hit EntityAlreadyExists"
        fi
    done

    # ----- S3 bucket: amazon-datazone-projects-<acct>-<region>-<stack> -----
    # The bucket name is now stack-suffixed (see sus-domain-stack.yaml).
    # We derive the same name here so this pre-deploy hygiene step
    # finds and cleans up the bucket from a previous run with the same
    # stack name. We use the same 14-char suffix cap as `_cfn_bootstrap`
    # so the names line up.
    if [ -n "$_account_id" ]; then
        local _stack_name_for_cleanup _stack_suffix_for_cleanup
        _stack_name_for_cleanup="$(_resolve_stack_name)"
        _stack_suffix_for_cleanup="$(printf '%s' "$_stack_name_for_cleanup" | cut -c1-14)"
        local _projects_bucket="amazon-datazone-projects-${_account_id}-${_region}-${_stack_suffix_for_cleanup}"
        if aws s3api head-bucket --bucket "$_projects_bucket" --region "$_region" >/dev/null 2>&1; then
            local _bucket_cfn
            _bucket_cfn="$(aws s3api get-bucket-tagging --bucket "$_projects_bucket" \
                --query 'TagSet[?Key==`aws:cloudformation:stack-name`].Value | [0]' \
                --output text 2>/dev/null | grep -v '^None$' || true)"
            if [ -n "$_bucket_cfn" ]; then
                echo "    = CFN-managed bucket left in place: ${_projects_bucket} (stack: ${_bucket_cfn})"
            else
                echo "    + purging non-CFN orphan bucket: ${_projects_bucket}"
                # Drain all object versions (versioned buckets can't be deleted with a single rm).
                if [ -x "${ROOT_DIR}/.scratch/empty_bucket.py" ] || [ -f "${ROOT_DIR}/.scratch/empty_bucket.py" ]; then
                    local _py
                    _py="$(_resolve_python)"
                    [ -n "$_py" ] && "$_py" "${ROOT_DIR}/.scratch/empty_bucket.py" \
                        "$_projects_bucket" "$_region" >/dev/null 2>&1 || true
                fi
                # Final s3 rb (handles non-versioned + drains anything
                # the python helper missed via --force).
                if aws s3 rb "s3://${_projects_bucket}" --region "$_region" --force >/dev/null 2>&1; then
                    echo "      + deleted bucket ${_projects_bucket}"
                else
                    echo "      WARN: failed to delete ${_projects_bucket}; CFN deploy may hit BucketAlreadyOwnedByYou"
                fi
            fi
        fi
    fi

    # ----- S3 bucket: amazon-datazone-tooling-<acct>-<region>-<stack> -----
    # CFN's BlueprintStack creates this with `DeletionPolicy: Retain`,
    # so it can survive past teardowns. On a fresh deploy CFN will hit
    # `BucketAlreadyOwnedByYou` if it exists. The standard teardown
    # already calls `_final_cleanup` which drains + deletes this
    # bucket, so this branch only triggers when an operator skipped
    # teardown or `--keep-cfn` was used previously. Bucket name is
    # stack-suffixed (see _cfn_bootstrap) so we compute it the same
    # way here.
    if [ -n "$_account_id" ]; then
        local _stack_name_for_tooling _stack_suffix_for_tooling _tooling_bucket
        _stack_name_for_tooling="$(_resolve_stack_name)"
        _stack_suffix_for_tooling="$(printf '%s' "$_stack_name_for_tooling" | cut -c1-14)"
        _tooling_bucket="$(_smus_setup_config_get tooling_bucket 2>/dev/null || true)"
        if [ -z "$_tooling_bucket" ]; then
            _tooling_bucket="amazon-datazone-tooling-${_account_id}-${_region}-${_stack_suffix_for_tooling}"
        fi
        if aws s3api head-bucket --bucket "$_tooling_bucket" --region "$_region" >/dev/null 2>&1; then
            local _tb_cfn
            _tb_cfn="$(aws s3api get-bucket-tagging --bucket "$_tooling_bucket" \
                --query 'TagSet[?Key==`aws:cloudformation:stack-name`].Value | [0]' \
                --output text 2>/dev/null | grep -v '^None$' || true)"
            if [ -n "$_tb_cfn" ]; then
                echo "    = CFN-managed tooling bucket left in place: ${_tooling_bucket} (stack: ${_tb_cfn})"
            else
                echo "    + purging non-CFN orphan tooling bucket: ${_tooling_bucket}"
                if [ -f "${ROOT_DIR}/.scratch/empty_bucket.py" ]; then
                    local _py
                    _py="$(_resolve_python)"
                    [ -n "$_py" ] && "$_py" "${ROOT_DIR}/.scratch/empty_bucket.py" \
                        "$_tooling_bucket" "$_region" >/dev/null 2>&1 || true
                fi
                if aws s3 rb "s3://${_tooling_bucket}" --region "$_region" --force >/dev/null 2>&1; then
                    echo "      + deleted bucket ${_tooling_bucket}"
                else
                    echo "      WARN: failed to delete ${_tooling_bucket}; CFN deploy may hit BucketAlreadyOwnedByYou"
                fi
            fi
        fi
    fi
}


# -----------------------------------------------------------------------------
# _export_role_arns_from_substacks <parent-stack-name> <region>
#
# Reads the four role ARNs (+ projects bucket name) out of the master
# stack's nested-stack outputs and exports them as MT_* env vars and
# persists the values that are durable (`tooling_user_role_arn`,
# `lf_registration_role_arn`, etc are still discovered later in the
# session bootstrap because they depend on the dynamic project user
# role).
#
# Resolution path:
#   <parent>.DomainStack         -> oSUSDomainExecutionRoleArn,
#                                   oSUSDomainServiceRoleArn,
#                                   oSUSToolingProvisioningRoleArn,
#                                   oSUSLFRegistrationRoleArn,
#                                   oSUSProjectsBucketName
#   <parent>.BlueprintStack      -> rSUSDomainManagedAccessRole (via DescribeStackResource)
#
# Idempotent: re-running on a fully-deployed stack just re-exports.
# -----------------------------------------------------------------------------
_export_role_arns_from_substacks() {
    local _parent="$1"
    local _region="$2"

    # Find the DomainStack physical ID inside the parent.
    local _domain_stack
    _domain_stack="$(aws cloudformation describe-stack-resources \
        --stack-name "$_parent" --region "$_region" \
        --logical-resource-id DomainStack --output json 2>/dev/null \
        | jq -r '.StackResources[0].PhysicalResourceId' 2>/dev/null || true)"
    if [ -z "$_domain_stack" ] || [ "$_domain_stack" = "null" ]; then
        echo "    WARN: could not resolve DomainStack physical id; role exports skipped"
        return 0
    fi

    local _ds_outputs
    _ds_outputs="$(aws cloudformation describe-stacks --stack-name "$_domain_stack" \
        --region "$_region" --query 'Stacks[0].Outputs' --output json 2>/dev/null || echo '[]')"

    local _exec_arn _svc_arn _prov_arn _lfreg_arn _pbucket
    _exec_arn="$(printf '%s' "$_ds_outputs" | jq -r '.[]? | select(.OutputKey=="oSUSDomainExecutionRoleArn") | .OutputValue' 2>/dev/null || true)"
    _svc_arn="$(printf '%s' "$_ds_outputs" | jq -r '.[]? | select(.OutputKey=="oSUSDomainServiceRoleArn") | .OutputValue' 2>/dev/null || true)"
    _prov_arn="$(printf '%s' "$_ds_outputs" | jq -r '.[]? | select(.OutputKey=="oSUSToolingProvisioningRoleArn") | .OutputValue' 2>/dev/null || true)"
    _lfreg_arn="$(printf '%s' "$_ds_outputs" | jq -r '.[]? | select(.OutputKey=="oSUSLFRegistrationRoleArn") | .OutputValue' 2>/dev/null || true)"
    _pbucket="$(printf '%s' "$_ds_outputs" | jq -r '.[]? | select(.OutputKey=="oSUSProjectsBucketName") | .OutputValue' 2>/dev/null || true)"

    [ -n "$_exec_arn" ]   && export MT_DOMAIN_EXECUTION_ROLE="$_exec_arn"
    [ -n "$_svc_arn" ]    && export MT_DOMAIN_SERVICE_ROLE="$_svc_arn"
    [ -n "$_prov_arn" ]   && export MT_TOOLING_PROVISIONING_ROLE_ARN="$_prov_arn"
    [ -n "$_lfreg_arn" ]  && export MT_LF_REGISTRATION_ROLE_ARN="$_lfreg_arn"
    [ -n "$_pbucket" ]    && export MT_TOOLING_PROJECTS_BUCKET="$_pbucket"

    # Manage-access role lives in the Blueprint sub-stack — but we
    # already know its name (it's a stable input parameter), so we
    # synthesise the ARN locally and skip another describe-stacks.
    local _account_id
    _account_id="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")"
    if [ -n "$_account_id" ]; then
        export MT_TOOLING_MANAGE_ACCESS_ROLE_ARN="arn:aws:iam::${_account_id}:role/sagemaker-studio-manage-access-role"
    fi

    echo "    + role ARNs read from DomainStack outputs:"
    echo "        execution:    ${_exec_arn:-<missing>}"
    echo "        service:      ${_svc_arn:-<missing>}"
    echo "        provisioning: ${_prov_arn:-<missing>}"
    echo "        lf-reg:       ${_lfreg_arn:-<missing>}"
    echo "        manage-access: ${MT_TOOLING_MANAGE_ACCESS_ROLE_ARN:-<missing>}"
    echo "        projects-bkt: ${_pbucket:-<missing>}"
}


# -----------------------------------------------------------------------------
# _resolve_cfn_param <key> <cli_override> <env_override> <default>
#
# Walk the CFN-parameter priority chain for a single key and echo the
# resolved value. Priority (highest first):
#
#   1. CLI override        — what was passed via --domain-name, etc.
#   2. Env var override    — $SMUS_DOMAIN_NAME, $MT_*, etc.
#   3. Persisted config    — config/smus-setup.config.json (so re-runs are sticky)
#   4. Default             — the last positional argument to this function
#
# Empty strings count as "not set" — they fall through to the next level.
#
# Echoes the resolved value to stdout. Caller captures it with
# `_resolve_cfn_param ... | $(...)`.
# -----------------------------------------------------------------------------
_resolve_cfn_param() {
    local _key="$1"
    local _cli="$2"
    local _env="$3"
    local _default="$4"
    if [ -n "$_cli" ]; then
        printf '%s' "$_cli"
        return 0
    fi
    if [ -n "$_env" ]; then
        printf '%s' "$_env"
        return 0
    fi
    local _persisted
    _persisted="$(_smus_setup_config_get "$_key" 2>/dev/null || true)"
    if [ -n "$_persisted" ]; then
        printf '%s' "$_persisted"
        return 0
    fi
    printf '%s' "$_default"
}


# -----------------------------------------------------------------------------
# _resolve_stack_name
#
# Resolves the top-level CFN stack name through the standard priority
# chain (CLI > env > config > default). Used by `_cfn_bootstrap`,
# `_action_teardown_via_lambda`, and the legacy
# `_teardown_destroy_smus_stack` so a customer can override once via
# `--stack-name acme-platform-smus` or `SMUS_STACK_NAME=...` and have
# every subsequent invocation pick up the same name from
# `config/smus-setup.config.json`.
#
# Default is `smus-seed` to preserve the seed tutorial flow's behavior.
# -----------------------------------------------------------------------------
_resolve_stack_name() {
    _resolve_cfn_param stack_name \
        "$CLI_STACK_NAME" "${SMUS_STACK_NAME:-}" "smus-seed"
}


# -----------------------------------------------------------------------------
# _resolve_stack_derived_param <key> <cli_override> <env_override> <default>
#
# Variant of `_resolve_cfn_param` that SKIPS the persisted-config
# tier. Used for parameters whose default is derived from the stack
# name (e.g. `<stack-name>-automation-role`). Without this, a re-run
# with a new --stack-name would still pick up the old stack's
# persisted role names and try to create them inside the new stack,
# which is exactly what we're trying to prevent. Operators who
# explicitly set the value via CLI or env get their override
# honored as usual.
# -----------------------------------------------------------------------------
_resolve_stack_derived_param() {
    local _key="$1"
    local _cli="$2"
    local _env="$3"
    local _default="$4"
    if [ -n "$_cli" ]; then
        printf '%s' "$_cli"
        return 0
    fi
    if [ -n "$_env" ]; then
        printf '%s' "$_env"
        return 0
    fi
    # Skip config tier — always re-derive from current stack name.
    printf '%s' "$_default"
}


# -----------------------------------------------------------------------------
# _resolve_tooling_bucket
#
# Returns the canonical name of the SMUS tooling S3 bucket. Reads the
# persisted `tooling_bucket` from smus-setup.config.json first
# (populated by `_cfn_bootstrap` on deploy) and falls back to the
# stack-suffixed default if absent. Used by every helper that needs
# to head-bucket / drain / KMS-lookup the tooling bucket so the
# answer is consistent between deploy time and any later helper.
# -----------------------------------------------------------------------------
_resolve_tooling_bucket() {
    local _account="$1"
    local _region="$2"
    local _v
    _v="$(_smus_setup_config_get tooling_bucket 2>/dev/null || true)"
    if [ -n "$_v" ]; then
        printf '%s' "$_v"
        return 0
    fi
    local _stack _suffix
    _stack="$(_resolve_stack_name)"
    _suffix="$(printf '%s' "$_stack" | cut -c1-14)"
    printf 'amazon-datazone-tooling-%s-%s-%s' "$_account" "$_region" "$_suffix"
}


# -----------------------------------------------------------------------------
# _setup_auto_wipe_on_stack_change
#
# Detects when the operator passed a different `--stack-name` than the
# one persisted from a previous deploy, and wipes every config key
# whose value would otherwise leak from the old stack into the new
# one. Keeps operator-pinned choices that aren't stack-specific
# (group names, IDC instance ARN, VPC ID, subnet IDs).
#
# Also wipes migration-tool state in the same case — a new stack
# means a new SMUS domain, which means the migration tool can't
# meaningfully resume from a partial run against the old domain.
#
# Backups are kept at <path>.bak.<timestamp> so an operator can
# recover if they ran with the wrong --stack-name flag by accident.
#
# Skipped on dry-run (no destructive action allowed).
# -----------------------------------------------------------------------------
_setup_auto_wipe_on_stack_change() {
    if [ "$MODE_FLAG" != "--apply" ]; then
        return 0
    fi

    local _setup_cfg="${ROOT_DIR}/config/smus-setup.config.json"
    if [ ! -f "$_setup_cfg" ] || ! command -v jq >/dev/null 2>&1; then
        # No prior config or no jq — nothing to compare against.
        return 0
    fi

    local _persisted _resolved
    _persisted="$(jq -r '.stack_name // empty' "$_setup_cfg" 2>/dev/null)"
    _resolved="$(_resolve_stack_name)"

    if [ -z "$_persisted" ] || [ "$_persisted" = "$_resolved" ]; then
        # First deploy or same stack — nothing to wipe.
        return 0
    fi

    echo "==> Auto-wipe: stack name change detected (was '${_persisted}', now '${_resolved}')"
    echo "    Clearing stale stack-derived values from config + state files."

    local _ts
    _ts="$(date +%s)"

    # Stack-derived keys that MUST NOT carry over between stacks.
    # Group/IDC/VPC choices are operator-level and stay.
    local _stale_keys=(
        # Stack-derived names
        domain_name admin_project_name
        domain_execution_role_name domain_service_role_name
        automation_role_name automation_role_policy_name
        managed_access_role_name
        templates_bucket tooling_bucket projects_bucket
        # Stack-derived repo wiring
        repo_name repo_url codecommit_repo_arn repo_connection_arn
        # Discovered IDs from the previous deploy
        smus_domain_id admin_project_id admin_project_profile_id
        domain_service_role
    )
    local _filter='del('
    local _i=0
    for _k in "${_stale_keys[@]}"; do
        if [ "$_i" -gt 0 ]; then _filter="${_filter}, "; fi
        _filter="${_filter}.${_k}"
        _i=$((_i + 1))
    done
    _filter="${_filter})"

    # Backup + rewrite smus-setup.config.json with the stale keys removed.
    local _backup="${_setup_cfg}.bak.${_ts}"
    cp "$_setup_cfg" "$_backup"
    if jq "$_filter" "$_setup_cfg" > "${_setup_cfg}.tmp" 2>/dev/null; then
        mv "${_setup_cfg}.tmp" "$_setup_cfg"
        echo "    + cleared stale keys from smus-setup.config.json (backup: ${_backup})"
    else
        rm -f "${_setup_cfg}.tmp"
        echo "    WARN: failed to rewrite smus-setup.config.json; leaving as-is"
    fi

    # Migration-tool state + config: a new stack means a new domain,
    # so any migration progress against the old domain is meaningless.
    # Wipe both with backups.
    local _mt_state="${ROOT_DIR}/state/migration.state.json"
    local _mt_config="${ROOT_DIR}/config/migration.config.json"
    if [ -f "$_mt_state" ]; then
        mv "$_mt_state" "${_mt_state}.bak.${_ts}"
        echo "    + wiped migration.state.json (backup: ${_mt_state}.bak.${_ts})"
    fi
    if [ -f "$_mt_config" ]; then
        mv "$_mt_config" "${_mt_config}.bak.${_ts}"
        echo "    + wiped migration.config.json (backup: ${_mt_config}.bak.${_ts})"
    fi
    echo
}


# -----------------------------------------------------------------------------
# _surface_repo_info <outputs_json> <region>
#
# Reads repo / connection outputs from the master stack and:
#   * persists each value to config/smus-setup.config.json
#   * for 3P providers, queries the live ConnectionStatus and prints
#     the "ACTION REQUIRED" authorize banner if state==PENDING
#
# Called from both deploy paths (just-deployed and stack-already-up-to-date)
# so the operator sees the authorize URL on every run until they
# complete the OAuth flow.
# -----------------------------------------------------------------------------
_surface_repo_info() {
    local _outputs_json="$1"
    local _region="$2"

    local _out_repo_provider _out_repo_name _out_cc_arn _out_cc_url _out_conn_arn _out_authorize
    _out_repo_provider="$(printf '%s' "$_outputs_json" | jq -r '.[] | select(.OutputKey=="oRepoProvider") | .OutputValue' 2>/dev/null || true)"
    _out_repo_name="$(printf '%s' "$_outputs_json" | jq -r '.[] | select(.OutputKey=="oRepoName") | .OutputValue' 2>/dev/null || true)"
    _out_cc_arn="$(printf '%s' "$_outputs_json" | jq -r '.[] | select(.OutputKey=="oCodeCommitRepoArn") | .OutputValue' 2>/dev/null || true)"
    _out_cc_url="$(printf '%s' "$_outputs_json" | jq -r '.[] | select(.OutputKey=="oCodeCommitCloneUrlHttp") | .OutputValue' 2>/dev/null || true)"
    _out_conn_arn="$(printf '%s' "$_outputs_json" | jq -r '.[] | select(.OutputKey=="oRepoConnectionArn") | .OutputValue' 2>/dev/null || true)"
    _out_authorize="$(printf '%s' "$_outputs_json" | jq -r '.[] | select(.OutputKey=="oRepoConnectionAuthorizeUrl") | .OutputValue' 2>/dev/null || true)"

    [ -n "$_out_repo_provider" ] && _smus_setup_config_set repo_provider "$_out_repo_provider"
    [ -n "$_out_repo_name" ]     && _smus_setup_config_set repo_name     "$_out_repo_name"
    [ -n "$_out_cc_arn" ]        && _smus_setup_config_set codecommit_repo_arn "$_out_cc_arn"
    [ -n "$_out_cc_url" ]        && _smus_setup_config_set repo_url      "$_out_cc_url"
    [ -n "$_out_conn_arn" ]      && _smus_setup_config_set repo_connection_arn "$_out_conn_arn"

    if [ -n "$_out_repo_provider" ]; then
        echo "    repo_provider:         ${_out_repo_provider}"
        echo "    repo_name:             ${_out_repo_name:-<unset>}"
    fi
    if [ -n "$_out_cc_url" ]; then
        echo "    codecommit_clone_url:  ${_out_cc_url}"
    fi
    if [ -n "$_out_conn_arn" ]; then
        local _conn_state
        _conn_state="$(aws codeconnections get-connection \
            --connection-arn "$_out_conn_arn" \
            --region "$_region" \
            --query 'Connection.ConnectionStatus' \
            --output text 2>/dev/null | grep -v '^None$' || echo "UNKNOWN")"
        echo "    repo_connection_arn:   ${_out_conn_arn}"
        echo "    repo_connection_state: ${_conn_state}"
        # We can't read the per-domain "Enable" toggle through any
        # public API (the SageMaker management console uses an
        # internal endpoint), so we always show the action banner for
        # 3P providers — even when the OAuth handshake is done. The
        # operator visually confirms `Enabled` on the domain's
        # Connections tab.
        local _domain_id
        _domain_id="$(_smus_setup_config_get smus_domain_id 2>/dev/null || true)"
        echo
        echo "    ╔══════════════════════════════════════════════════════════════════╗"
        echo "    ║                                                                  ║"
        echo "    ║   ⚠️  ATTENTION — TWO MANUAL STEPS REQUIRED  ⚠️                  ║"
        echo "    ║                                                                  ║"
        echo "    ║   The 3P Git connection cannot be fully wired automatically.     ║"
        echo "    ║   Both steps below are by AWS design — no public API exists.     ║"
        echo "    ║                                                                  ║"
        echo "    ╚══════════════════════════════════════════════════════════════════╝"
        echo
        if [ "$_conn_state" = "PENDING" ]; then
            echo "    ┌─ STEP 1 ─ AUTHORIZE the CodeConnections connection ─────────────"
            echo "    │  Status: ⚠️  PENDING — needs OAuth handshake"
            echo "    │"
            echo "    │  a. Open: https://${_region}.console.aws.amazon.com/codesuite/settings/connections"
            echo "    │  b. Find connection '${_out_repo_name}' (Connection status: Pending)"
            echo "    │  c. Click 'Update pending connection' and complete OAuth"
            echo "    │  d. Confirm Connection status -> Available"
            echo "    └──────────────────────────────────────────────────────────────────"
            echo
        else
            echo "    ┌─ STEP 1 ─ AUTHORIZE the CodeConnections connection ─────────────"
            echo "    │  Status: ✅ DONE (Connection status: ${_conn_state})"
            echo "    └──────────────────────────────────────────────────────────────────"
            echo
        fi
        echo "    ┌─ STEP 2 ─ ENABLE the connection on the SMUS domain ─────────────"
        echo "    │  Status: ⚠️  REQUIRED (cannot verify via API)"
        echo "    │"
        echo "    │  a. Open: https://${_region}.console.aws.amazon.com/datazone/home?region=${_region}#/domains"
        if [ -n "$_domain_id" ]; then
            echo "    │     (your domain: ${_domain_id})"
        fi
        echo "    │  b. Click your domain name -> Connections tab"
        echo "    │  c. Select '${_out_repo_name}' (Project status: Disabled)"
        echo "    │  d. Click 'Enable' in the top-right toolbar and confirm"
        echo "    │  e. Refresh -> Project status should read Enabled"
        echo "    └──────────────────────────────────────────────────────────────────"
        echo
        echo "    Until BOTH steps are done, project members cannot clone or push."
        echo "    See README section 'Git connection (CodeCommit vs 3P)' for details."
        echo
    fi
}


_cfn_bootstrap() {
    if [ "$MODE_FLAG" != "--apply" ]; then
        echo "==> CFN bootstrap: skipped (not in --apply mode)"
        return 0
    fi
    if ! command -v aws >/dev/null 2>&1; then
        echo "==> CFN bootstrap: skipped (aws CLI not on PATH)"
        return 0
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo "==> CFN bootstrap: skipped (jq not on PATH — need it to render params)"
        return 0
    fi

    local _account="${AWS_ACCOUNT_ID:-}"
    if [ -z "$_account" ]; then
        _account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")"
    fi
    local _region="${AWS_DEFAULT_REGION:-us-east-1}"
    local _stack_name
    _stack_name="$(_resolve_stack_name)"
    # Persist immediately so a teardown invoked without flags reads
    # the same stack name back from config.
    _smus_setup_config_set stack_name "$_stack_name"

    # ---- Short-circuit when the stack is already in a healthy state. -------
    # Re-deploying every run wastes 1-2 minutes uploading templates and
    # waiting for `aws cloudformation deploy` to no-op. When the stack
    # is in CREATE_COMPLETE or UPDATE_COMPLETE we just read the
    # outputs and return.
    local _existing_status
    _existing_status="$(aws cloudformation describe-stacks --stack-name "$_stack_name" \
        --region "$_region" --query 'Stacks[0].StackStatus' --output text 2>/dev/null \
        | grep -v '^None$' || true)"
    if [ "$_existing_status" = "CREATE_COMPLETE" ] || [ "$_existing_status" = "UPDATE_COMPLETE" ]; then
        echo "==> CFN bootstrap: stack ${_stack_name} already ${_existing_status} — reading outputs"
        local _outputs_json
        _outputs_json="$(aws cloudformation describe-stacks --stack-name "$_stack_name" \
            --region "$_region" --query 'Stacks[0].Outputs' --output json 2>/dev/null || echo '[]')"
        local _domain_id _profile_id
        _domain_id="$(printf '%s' "$_outputs_json" | jq -r '.[] | select(.OutputKey=="oSUSDomainID") | .OutputValue' 2>/dev/null || true)"
        _profile_id="$(printf '%s' "$_outputs_json" | jq -r '.[] | select(.OutputKey=="oAllCapabilitiesProjectProfileId") | .OutputValue' 2>/dev/null || true)"

        if [ -n "$_domain_id" ]; then
            local _admin_project_id
            _admin_project_id="$(aws datazone list-projects \
                --domain-identifier "$_domain_id" \
                --query "items[?name=='smus-admin'] | [0].id" \
                --output text --region "$_region" 2>/dev/null | grep -v '^None$' || true)"
            export MT_SMUS_DOMAIN_ID="$_domain_id"
            export MT_ADMIN_PROJECT_ID="${_admin_project_id:-}"
            export MT_ADMIN_PROJECT_PROFILE_ID="${_profile_id:-}"
            echo "    domain_id=${_domain_id}"
            echo "    admin_project_id=${_admin_project_id}"
            echo "    admin_project_profile_id=${_profile_id}"

            # Export role ARNs from the domain sub-stack outputs so
            # downstream helpers (and `_action_run` --set injection)
            # see the same values whether or not we just deployed.
            _export_role_arns_from_substacks "$_stack_name" "$_region"

            # Persist the discovered IDs so subsequent migrate.sh runs
            # (and add-glue-databases.sh, status, teardown) read them
            # from config without having to re-discover via CFN/datazone.
            # Without this, the short-circuit path (re-run on a
            # healthy stack) would leave config null, even though the
            # IDs are right there in the stack outputs.
            [ -n "$_domain_id" ]        && _smus_setup_config_set smus_domain_id            "$_domain_id"
            [ -n "$_admin_project_id" ] && _smus_setup_config_set admin_project_id          "$_admin_project_id"
            [ -n "$_profile_id" ]       && _smus_setup_config_set admin_project_profile_id  "$_profile_id"
            if [ -n "${MT_DOMAIN_SERVICE_ROLE:-}" ]; then
                _smus_setup_config_set domain_service_role "$MT_DOMAIN_SERVICE_ROLE"
            fi
            if [ -n "${MT_IDENTITY_CENTER_INSTANCE_ARN:-}" ]; then
                _smus_setup_config_set identity_center_instance_arn "$MT_IDENTITY_CENTER_INSTANCE_ARN"
            fi
            if [ -n "${MT_IDENTITY_CENTER_IDENTITY_STORE_ID:-}" ]; then
                _smus_setup_config_set identity_center_identity_store_id "$MT_IDENTITY_CENTER_IDENTITY_STORE_ID"
            fi

            # Surface repo / Git connection info (with PENDING banner
            # when applicable) on every short-circuited re-run so the
            # operator keeps seeing the authorize URL until they act.
            _surface_repo_info "$_outputs_json" "$_region"
        fi
        echo "==> CFN bootstrap: complete (no changes)"
        return 0
    fi

    # ---- Stack absent or in a non-healthy state — deploy from scratch. -----
    echo "==> CFN bootstrap: stack ${_stack_name} status=${_existing_status:-MISSING}; running deploy"

    # Discover the IDC group ID for the chosen admin group. The
    # operator's name choice was validated by `_prompt_idc_groups`
    # before _cfn_bootstrap runs (see `_action_run`), so we trust the
    # env vars here and surface a clear error if the lookup fails
    # (which would only happen if the group was deleted between the
    # prompt and now).
    local _identity_store_id="${MT_IDENTITY_CENTER_IDENTITY_STORE_ID:-}"
    if [ -z "$_identity_store_id" ]; then
        echo "==> CFN bootstrap: skipped (MT_IDENTITY_CENTER_IDENTITY_STORE_ID not set; _idc_bootstrap must run first)"
        return 0
    fi
    local _admin_group_name="${MT_ADMIN_GROUP_NAME:-smus-admins}"
    local _sso_group_id
    _sso_group_id="$(aws identitystore list-groups \
        --identity-store-id "$_identity_store_id" \
        --filters "AttributePath=DisplayName,AttributeValue=${_admin_group_name}" \
        --query 'Groups[0].GroupId' --output text 2>/dev/null | grep -v '^None$' || true)"
    if [ -z "$_sso_group_id" ]; then
        echo "==> CFN bootstrap: ERROR — admin group '${_admin_group_name}' not found in IDC instance ${_identity_store_id}"
        echo "    Create the group in IDC or re-run with --reconfigure to pick a different one."
        exit 65
    fi
    echo "==> CFN bootstrap: admin group ${_admin_group_name} (${_sso_group_id})"

    # Resolve seed VPC + private subnet IDs from seed/seed.state.json.
    local _seed_state="${ROOT_DIR}/seed/seed.state.json"
    if [ ! -f "$_seed_state" ]; then
        echo "==> CFN bootstrap: WARN — seed/seed.state.json missing; can't resolve VPC/subnets"
        return 0
    fi
    local _vpc_id _subnet_csv
    _vpc_id="$(jq -r '.services.network.resources.vpc_id // empty' "$_seed_state")"
    _subnet_csv="$(jq -r '.services.network.resources.private_subnet_ids // [] | join(",")' "$_seed_state")"
    if [ -z "$_vpc_id" ] || [ -z "$_subnet_csv" ]; then
        echo "==> CFN bootstrap: WARN — VPC or private subnets missing in seed state; run seed.sh first"
        return 0
    fi

    # Render params from template.
    local _cfn_dir="${ROOT_DIR}/cfn"
    local _template_dir="${_cfn_dir}/child-stacks"
    local _params_template="${_cfn_dir}/params.json.template"
    local _params_path="${_cfn_dir}/params.json"
    if [ ! -f "$_params_template" ]; then
        echo "==> CFN bootstrap: WARN — params template missing at ${_params_template}"
        return 0
    fi

    # ---- Resolve every CFN parameter through the priority chain ----
    # Priority: CLI flag > env var > smus-setup.config.json > auto-discovered/default.
    # `_resolve_cfn_param` is defined below this function.
    #
    # Stack-derived parameters use `_resolve_stack_derived_param` instead,
    # which SKIPS the persisted-config tier so a `--stack-name` change
    # always re-derives the default. Operators who pin a value via
    # CLI / env get their override honored as usual.

    # Domain + admin project names track the stack name so a single
    # `--stack-name <foo>` flag yields a coherent deployment (stack
    # `<foo>`, domain `<foo>-domain`, repo `<foo>-domain-migration`).
    # Operators with multiple stacks against the same domain pin the
    # name explicitly via `--domain-name`.
    local _domain_name
    _domain_name="$(_resolve_stack_derived_param domain_name \
        "$CLI_DOMAIN_NAME" "${SMUS_DOMAIN_NAME:-}" "${_stack_name}-domain")"
    local _admin_project_name
    _admin_project_name="$(_resolve_stack_derived_param admin_project_name \
        "$CLI_ADMIN_PROJECT_NAME" "${SMUS_ADMIN_PROJECT_NAME:-}" "smus-admin")"
    local _domain_execution_role_name
    _domain_execution_role_name="$(_resolve_stack_derived_param domain_execution_role_name \
        "$CLI_DOMAIN_EXECUTION_ROLE_NAME" "${SMUS_DOMAIN_EXECUTION_ROLE_NAME:-}" "sagemaker-domain-execution-${_stack_name}")"
    local _domain_service_role_name
    _domain_service_role_name="$(_resolve_stack_derived_param domain_service_role_name \
        "$CLI_DOMAIN_SERVICE_ROLE_NAME" "${SMUS_DOMAIN_SERVICE_ROLE_NAME:-}" "AmazonDataZoneServiceRole-${_stack_name}")"
    local _automation_role_name
    _automation_role_name="$(_resolve_stack_derived_param automation_role_name \
        "$CLI_AUTOMATION_ROLE_NAME" "${SMUS_AUTOMATION_ROLE_NAME:-}" "${_stack_name}-automation-role")"
    local _automation_role_policy_name
    _automation_role_policy_name="$(_resolve_stack_derived_param automation_role_policy_name \
        "$CLI_AUTOMATION_ROLE_POLICY_NAME" "${SMUS_AUTOMATION_ROLE_POLICY_NAME:-}" "${_stack_name}-automation-policy")"
    local _managed_access_role_name
    _managed_access_role_name="$(_resolve_stack_derived_param managed_access_role_name \
        "$CLI_MANAGED_ACCESS_ROLE_NAME" "${SMUS_MANAGED_ACCESS_ROLE_NAME:-}" "sagemaker-studio-manage-access-role-${_stack_name}")"
    local _templates_bucket_resolved
    _templates_bucket_resolved="$(_resolve_stack_derived_param templates_bucket \
        "$CLI_TEMPLATES_BUCKET" "${SMUS_TEMPLATES_BUCKET:-}" "${_stack_name}-cfn-${_account}-${_region}")"
    # The tooling bucket name is constrained by S3's 63-char limit.
    # Account ID (12) + region (up to 14) + suffix already eats most
    # of the budget, so we cap the stack-name suffix at 14 chars to
    # leave headroom. CFN uses this name verbatim on the
    # `BucketName: !Ref pSUSBPToolingBucketName` resource.
    local _stack_suffix_short
    _stack_suffix_short="$(printf '%s' "$_stack_name" | cut -c1-14)"
    local _tooling_bucket
    _tooling_bucket="$(_resolve_stack_derived_param tooling_bucket \
        "$CLI_TOOLING_BUCKET" "${SMUS_TOOLING_BUCKET:-}" "amazon-datazone-tooling-${_account}-${_region}-${_stack_suffix_short}")"

    # The DataZone projects bucket has the same length constraint.
    # Same 14-char cap so it stays under 63.
    local _projects_bucket
    _projects_bucket="$(_resolve_stack_derived_param projects_bucket \
        "" "${SMUS_PROJECTS_BUCKET:-}" "amazon-datazone-projects-${_account}-${_region}-${_stack_suffix_short}")"
    local _lambda_source_prefix
    _lambda_source_prefix="$(_resolve_cfn_param lambda_source_prefix \
        "$CLI_LAMBDA_SOURCE_PREFIX" "${SMUS_LAMBDA_SOURCE_PREFIX:-}" "")"

    # Git repository / connection wiring. CodeCommit (default) creates
    # a repo via CFN; any 3P value creates a CodeConnections connection
    # that lands in PENDING and must be authorized once via the AWS
    # console. The Lambda Custom Resource emits the authorize URL via
    # the stack outputs; we surface it again at the end of this run.
    local _repo_provider
    _repo_provider="$(_resolve_cfn_param repo_provider \
        "$CLI_REPO_PROVIDER" "${SMUS_REPO_PROVIDER:-}" "CodeCommit")"
    # Default repo name is <domain-name>-migration (preserves the
    # historical convention from migrate.sh's old in-script create).
    local _repo_name
    _repo_name="$(_resolve_stack_derived_param repo_name \
        "$CLI_REPO_NAME" "${SMUS_REPO_NAME:-}" "${_domain_name}-migration")"
    local _repo_url
    _repo_url="$(_resolve_cfn_param repo_url \
        "$CLI_REPO_URL" "${SMUS_REPO_URL:-}" "")"
    local _repo_connection_arn
    _repo_connection_arn="$(_resolve_cfn_param repo_connection_arn \
        "$CLI_REPO_CONNECTION_ARN" "${SMUS_REPO_CONNECTION_ARN:-}" "")"

    # Validate: any 3P provider needs either a URL (so CFN creates the
    # connection) or a pre-existing connection ARN (which short-circuits
    # creation entirely). CodeCommit doesn't need either.
    if [ "$_repo_provider" != "CodeCommit" ] \
            && [ -z "$_repo_url" ] \
            && [ -z "$_repo_connection_arn" ]; then
        echo "==> CFN bootstrap: ERROR — repo_provider='${_repo_provider}' but neither --repo-url nor --repo-connection-arn was provided." >&2
        echo "    For 3P providers, pass either:" >&2
        echo "      --repo-url <https://github.com/owner/repo.git>   (CFN will create a CodeConnections connection in PENDING state)" >&2
        echo "      --repo-connection-arn <arn:aws:codeconnections:...>   (CFN will reuse a pre-existing connection)" >&2
        exit 64
    fi

    # `--vpc-id` / `--subnet-ids` / `--sso-instance-arn` override what was
    # auto-discovered from seed.state.json + IDC bootstrap. If a CLI flag
    # is set, use it; otherwise the values discovered above stand.
    if [ -n "$CLI_VPC_ID" ]; then
        _vpc_id="$CLI_VPC_ID"
    elif [ -n "${SMUS_VPC_ID:-}" ]; then
        _vpc_id="$SMUS_VPC_ID"
    fi
    if [ -n "$CLI_SUBNET_IDS" ]; then
        _subnet_csv="$CLI_SUBNET_IDS"
    elif [ -n "${SMUS_SUBNET_IDS:-}" ]; then
        _subnet_csv="$SMUS_SUBNET_IDS"
    fi
    local _sso_instance_arn="${MT_IDENTITY_CENTER_INSTANCE_ARN:-}"
    if [ -n "$CLI_SSO_INSTANCE_ARN" ]; then
        _sso_instance_arn="$CLI_SSO_INSTANCE_ARN"
    fi

    # Persist every resolved value into smus-setup.config.json so a
    # subsequent run with no flags reads them back from the config and
    # keeps the same SMUS deployment shape.
    _smus_setup_config_set domain_name                "$_domain_name"
    _smus_setup_config_set admin_project_name         "$_admin_project_name"
    _smus_setup_config_set domain_execution_role_name "$_domain_execution_role_name"
    _smus_setup_config_set domain_service_role_name   "$_domain_service_role_name"
    _smus_setup_config_set automation_role_name       "$_automation_role_name"
    _smus_setup_config_set automation_role_policy_name "$_automation_role_policy_name"
    _smus_setup_config_set managed_access_role_name   "$_managed_access_role_name"
    _smus_setup_config_set templates_bucket           "$_templates_bucket_resolved"
    _smus_setup_config_set tooling_bucket             "$_tooling_bucket"
    _smus_setup_config_set projects_bucket            "$_projects_bucket"
    _smus_setup_config_set lambda_source_prefix       "$_lambda_source_prefix"
    [ -n "$_vpc_id" ]            && _smus_setup_config_set vpc_id "$_vpc_id"
    [ -n "$_subnet_csv" ]        && _smus_setup_config_set subnet_ids "$_subnet_csv"
    [ -n "$_sso_instance_arn" ]  && _smus_setup_config_set sso_instance_arn "$_sso_instance_arn"
    _smus_setup_config_set repo_provider                "$_repo_provider"
    _smus_setup_config_set repo_name                    "$_repo_name"
    [ -n "$_repo_url" ]            && _smus_setup_config_set repo_url            "$_repo_url"
    [ -n "$_repo_connection_arn" ] && _smus_setup_config_set repo_connection_arn "$_repo_connection_arn"

    # Render the params file. We use `jq -n` to build a structurally
    # valid JSON array and feed it the resolved values, so that
    # template values containing characters that `sed` would treat
    # specially (slashes, ampersands) survive unchanged.
    jq -n \
        --arg templates_bucket             "$_templates_bucket_resolved" \
        --arg domain_name                  "$_domain_name" \
        --arg domain_execution_role_name   "$_domain_execution_role_name" \
        --arg domain_service_role_name     "$_domain_service_role_name" \
        --arg automation_role_name         "$_automation_role_name" \
        --arg automation_role_policy_name  "$_automation_role_policy_name" \
        --arg managed_access_role_name     "$_managed_access_role_name" \
        --arg vpc_id                       "$_vpc_id" \
        --arg subnet_ids                   "$_subnet_csv" \
        --arg tooling_bucket               "$_tooling_bucket" \
        --arg projects_bucket              "$_projects_bucket" \
        --arg sso_group_id                 "$_sso_group_id" \
        --arg sso_instance_arn             "$_sso_instance_arn" \
        --arg admin_project_name           "$_admin_project_name" \
        --arg lambda_source_bucket         "$_templates_bucket_resolved" \
        --arg lambda_source_prefix         "$_lambda_source_prefix" \
        --arg repo_provider                "$_repo_provider" \
        --arg repo_name                    "$_repo_name" \
        --arg repo_url                     "$_repo_url" \
        --arg repo_connection_arn          "$_repo_connection_arn" \
        '[
            {ParameterKey: "ChildStacksBucketName",          ParameterValue: $templates_bucket},
            {ParameterKey: "pSUSDomainName",                  ParameterValue: $domain_name},
            {ParameterKey: "pSUSDomainExecutionRoleName",     ParameterValue: $domain_execution_role_name},
            {ParameterKey: "pSUSDomainServiceRoleName",       ParameterValue: $domain_service_role_name},
            {ParameterKey: "pSUSAutomationRoleName",          ParameterValue: $automation_role_name},
            {ParameterKey: "pSUSDomainAutomationRolePolicyName", ParameterValue: $automation_role_policy_name},
            {ParameterKey: "pSUSDomainManagedAccessRoleName", ParameterValue: $managed_access_role_name},
            {ParameterKey: "pSUSToolingBPVpcId",              ParameterValue: $vpc_id},
            {ParameterKey: "pSUSToolingBPSubnets",            ParameterValue: $subnet_ids},
            {ParameterKey: "pSUSBPToolingBucketName",         ParameterValue: $tooling_bucket},
            {ParameterKey: "pSUSProjectsBucketName",          ParameterValue: $projects_bucket},
            {ParameterKey: "pSSOGroupID",                     ParameterValue: $sso_group_id},
            {ParameterKey: "pSSOInstanceArn",                 ParameterValue: $sso_instance_arn},
            {ParameterKey: "pAdminProjectName",               ParameterValue: $admin_project_name},
            {ParameterKey: "pLambdaSourceBucket",             ParameterValue: $lambda_source_bucket},
            {ParameterKey: "pLambdaSourcePrefix",             ParameterValue: $lambda_source_prefix},
            {ParameterKey: "pRepoProvider",                   ParameterValue: $repo_provider},
            {ParameterKey: "pRepoName",                       ParameterValue: $repo_name},
            {ParameterKey: "pRepoUrl",                        ParameterValue: $repo_url},
            {ParameterKey: "pRepoConnectionArn",              ParameterValue: $repo_connection_arn}
        ]' > "$_params_path"

    local _cfn_bucket="$_templates_bucket_resolved"
    echo "==> CFN bootstrap: bucket=${_cfn_bucket}, vpc=${_vpc_id}, subnets=${_subnet_csv}"

    # Create or reuse the CFN templates bucket.
    if aws s3api head-bucket --bucket "$_cfn_bucket" --region "$_region" >/dev/null 2>&1; then
        echo "    = bucket exists: ${_cfn_bucket}"
    else
        echo "    + creating bucket ${_cfn_bucket}"
        if [ "$_region" = "us-east-1" ]; then
            aws s3api create-bucket --bucket "$_cfn_bucket" --region "$_region" >/dev/null 2>&1 || true
        else
            aws s3api create-bucket --bucket "$_cfn_bucket" --region "$_region" \
                --create-bucket-configuration "LocationConstraint=${_region}" >/dev/null 2>&1 || true
        fi
        aws s3api put-bucket-versioning --bucket "$_cfn_bucket" \
            --versioning-configuration Status=Enabled --region "$_region" >/dev/null 2>&1 || true
    fi

    # Upload child templates. The 5 nested stacks (in order they're
    # composed by the master): domain, blueprints (17 EBPs + IAM +
    # Tooling S3+KMS), project profiles (4 incl. All-capabilities),
    # policy grants (17 blueprint grants + 3 profile grants), and
    # the admin project + IDC PROJECT_OWNER membership.
    # The lambda-build stack zips loose .py source into a Lambda zip
    # via CodeBuild during stack create — uploaded here too.
    for _t in sus-domain-stack.yaml \
              sus-blueprints-stack.yaml \
              sus-project-profiles-stack.yaml \
              sus-policy-grant-stack.yaml \
              sus-project-stack.yaml \
              sus-lambda-build-stack.yaml; do
        echo "    + uploading ${_t}"
        aws s3 cp "${_template_dir}/${_t}" "s3://${_cfn_bucket}/${_t}" --region "$_region" >/dev/null
    done

    # Upload the unzipped Lambda source. The LambdaBuildStack's
    # CodeBuild reads from `s3://${_cfn_bucket}/lambda/` and writes
    # the resulting zip to `s3://${_cfn_bucket}/setup_handler.zip`.
    # We deliberately upload UNZIPPED .py files because the customer
    # asked for the build step to run inside CFN, not on the operator's
    # machine.
    local _lambda_src="${ROOT_DIR}/cfn/lambda/handler"
    if [ -d "$_lambda_src" ]; then
        echo "    + uploading unzipped Lambda source"
        aws s3 cp "$_lambda_src/" "s3://${_cfn_bucket}/lambda/" \
            --recursive --exclude "*" --include "*.py" \
            --region "$_region" >/dev/null
    else
        echo "    WARN: $_lambda_src missing; CFN deploy will fail at LambdaBuildStack"
    fi

    # Deploy the master stack. `aws cloudformation deploy` is idempotent
    # (returns "No changes to deploy" when up to date) but exits non-zero
    # on that — capture both signals.
    echo "    + deploying master stack ${_stack_name}"
    local _deploy_out _deploy_rc=0
    _deploy_out="$(aws cloudformation deploy \
        --template-file "${_cfn_dir}/master-stack.yaml" \
        --stack-name "$_stack_name" \
        --parameter-overrides "file://${_params_path}" \
        --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
        --region "$_region" 2>&1)" || _deploy_rc=$?
    if [ "$_deploy_rc" -ne 0 ]; then
        if printf '%s' "$_deploy_out" | grep -q "No changes to deploy"; then
            echo "    = stack up to date"
        else
            echo "$_deploy_out" | tail -20
            echo "    WARN: cloudformation deploy returned ${_deploy_rc}; check stack events"
            return 0
        fi
    fi

    # Read stack outputs.
    local _outputs_json
    _outputs_json="$(aws cloudformation describe-stacks --stack-name "$_stack_name" \
        --region "$_region" --query 'Stacks[0].Outputs' --output json 2>/dev/null || echo '[]')"
    local _domain_id _profile_id
    _domain_id="$(printf '%s' "$_outputs_json" | jq -r '.[] | select(.OutputKey=="oSUSDomainID") | .OutputValue' 2>/dev/null || true)"
    _profile_id="$(printf '%s' "$_outputs_json" | jq -r '.[] | select(.OutputKey=="oAllCapabilitiesProjectProfileId") | .OutputValue' 2>/dev/null || true)"

    if [ -n "$_domain_id" ]; then
        # Look up the admin project ID directly from datazone (the
        # nested project-stack outputs aren't bubbled up to the master
        # stack outputs by default).
        local _admin_project_id
        _admin_project_id="$(aws datazone list-projects \
            --domain-identifier "$_domain_id" \
            --query "items[?name=='smus-admin'] | [0].id" \
            --output text --region "$_region" 2>/dev/null | grep -v '^None$' || true)"
        export MT_SMUS_DOMAIN_ID="$_domain_id"
        export MT_ADMIN_PROJECT_ID="${_admin_project_id:-}"
        export MT_ADMIN_PROJECT_PROFILE_ID="${_profile_id:-}"
        echo "    domain_id=${_domain_id}"
        echo "    admin_project_id=${_admin_project_id}"
        echo "    admin_project_profile_id=${_profile_id}"

        # Pull role ARNs out of the domain sub-stack outputs.
        _export_role_arns_from_substacks "$_stack_name" "$_region"

        # Persist discovered IDs to the SMUS setup config so
        # `migrate.sh run` can read them without re-deriving from CFN.
        [ -n "$_domain_id" ]        && _smus_setup_config_set smus_domain_id            "$_domain_id"
        [ -n "$_admin_project_id" ] && _smus_setup_config_set admin_project_id          "$_admin_project_id"
        [ -n "$_profile_id" ]       && _smus_setup_config_set admin_project_profile_id  "$_profile_id"

        # Domain service role ARN — now discovered from CFN outputs.
        if [ -n "${MT_DOMAIN_SERVICE_ROLE:-}" ]; then
            _smus_setup_config_set domain_service_role "$MT_DOMAIN_SERVICE_ROLE"
        fi
        # Identity Center identifiers — discovered by `_idc_bootstrap`.
        if [ -n "${MT_IDENTITY_CENTER_INSTANCE_ARN:-}" ]; then
            _smus_setup_config_set identity_center_instance_arn "$MT_IDENTITY_CENTER_INSTANCE_ARN"
        fi
        if [ -n "${MT_IDENTITY_CENTER_IDENTITY_STORE_ID:-}" ]; then
            _smus_setup_config_set identity_center_identity_store_id "$MT_IDENTITY_CENTER_IDENTITY_STORE_ID"
        fi

        # Surface repo / Git connection info. For 3P providers prints
        # the "ACTION REQUIRED" authorize banner when the connection is
        # in PENDING state (one-time OAuth handshake).
        _surface_repo_info "$_outputs_json" "$_region"
    fi

    echo "==> CFN bootstrap: complete"
}


_lakeformation_bootstrap() {
    if [ "$MODE_FLAG" != "--apply" ]; then
        echo "==> Lake Formation bootstrap: skipped (not in --apply mode)"
        return 0
    fi
    if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        echo "==> Lake Formation bootstrap: skipped (aws/jq missing)"
        return 0
    fi

    local _domain_id="${MT_SMUS_DOMAIN_ID:-}"
    local _project_id="${MT_ADMIN_PROJECT_ID:-}"
    if [ -z "$_domain_id" ] || [ -z "$_project_id" ]; then
        echo "==> Lake Formation bootstrap: skipped (domain/project ID not set yet)"
        return 0
    fi

    local _region="${AWS_DEFAULT_REGION:-us-east-1}"

    # 1. Self-promote to data-lake admin so we can issue grants.
    local _caller_arn
    _caller_arn="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo "")"
    local _caller_role_arn=""
    if [[ "$_caller_arn" =~ ^arn:aws:sts::([0-9]+):assumed-role/([^/]+)/.*$ ]]; then
        _caller_role_arn="arn:aws:iam::${BASH_REMATCH[1]}:role/${BASH_REMATCH[2]}"
    elif [[ "$_caller_arn" =~ ^arn:aws:iam::[0-9]+:(role|user)/.*$ ]]; then
        _caller_role_arn="$_caller_arn"
    fi

    if [ -n "$_caller_role_arn" ]; then
        local _admins_json
        _admins_json="$(aws lakeformation get-data-lake-settings --region "$_region" \
            --query 'DataLakeSettings.DataLakeAdmins' --output json 2>/dev/null || echo '[]')"
        if ! printf '%s' "$_admins_json" | jq -e --arg p "$_caller_role_arn" \
                'map(.DataLakePrincipalIdentifier) | index($p)' >/dev/null 2>&1; then
            echo "==> Lake Formation bootstrap: adding ${_caller_role_arn} as data-lake admin"
            local _new_admins
            _new_admins="$(printf '%s' "$_admins_json" | jq --arg p "$_caller_role_arn" \
                '. + [{DataLakePrincipalIdentifier: $p}]')"
            aws lakeformation put-data-lake-settings --region "$_region" \
                --data-lake-settings "{\"DataLakeAdmins\": $_new_admins}" >/dev/null 2>&1 || \
                echo "    WARN: put-data-lake-settings failed; downstream grants may fail"
        else
            echo "==> Lake Formation bootstrap: caller already a data-lake admin"
        fi
    fi

    # 2. Discover the DataZone data-access role from the Lakehouse
    # Database environment's `userRoleArn` provisioned resource.
    local _lh_env_id _data_access_role
    _lh_env_id="$(aws datazone list-environments \
        --domain-identifier "$_domain_id" \
        --project-identifier "$_project_id" \
        --region "$_region" --output json 2>/dev/null \
        | jq -r '.items[]? | select(.name == "Lakehouse Database") | .id' \
        | head -n 1)"
    if [ -z "$_lh_env_id" ]; then
        echo "==> Lake Formation bootstrap: WARN — Lakehouse Database environment not found; skipping grants"
        return 0
    fi
    _data_access_role="$(aws datazone get-environment \
        --domain-identifier "$_domain_id" \
        --identifier "$_lh_env_id" \
        --region "$_region" \
        --query 'provisionedResources[?name==`userRoleArn`].value | [0]' \
        --output text 2>/dev/null | grep -v '^None$' || true)"
    if [ -z "$_data_access_role" ]; then
        echo "==> Lake Formation bootstrap: WARN — userRoleArn not yet provisioned; skipping grants"
        return 0
    fi
    echo "==> Lake Formation bootstrap: granting Describe/Select to ${_data_access_role}"

    # 3. Discover the SMUS manage-access role. The portal's
    # "queryable with tools" gate evaluates THIS role's grants — if
    # this role has zero perms on the DB/table, the asset is flagged
    # even when the project user role can preview the data fine. The
    # manage-access role ARN is exported by `_export_role_arns_from_substacks`
    # (called from `_cfn_bootstrap`) reading the CFN sub-stack outputs.
    local _manage_access_role="${MT_TOOLING_MANAGE_ACCESS_ROLE_ARN:-}"
    if [ -z "$_manage_access_role" ]; then
        # Best-effort fallback: derive from the SMUS naming convention
        # used by the seed/domain stack. Empty string disables the
        # manage-access grants (a warning is printed; the data-access
        # grants below still run).
        local _seed_prefix
        _seed_prefix="$(jq -r '.seed_name_prefix // empty' \
            "${ROOT_DIR}/seed/seed.config.json" 2>/dev/null || true)"
        if [ -n "$_seed_prefix" ]; then
            _manage_access_role="arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/${_seed_prefix}-managed-access-role"
            if ! aws iam get-role --role-name "${_seed_prefix}-managed-access-role" >/dev/null 2>&1; then
                _manage_access_role=""
            fi
        fi
    fi
    if [ -n "$_manage_access_role" ]; then
        echo "==> Lake Formation bootstrap: also granting Describe/Select Grantable to manage-access role ${_manage_access_role}"
    else
        echo "==> Lake Formation bootstrap: WARN — manage-access role unknown; the portal may flag assets as 'cannot be queried with tools'"
    fi

    # 4. Enumerate every external Glue database. For each:
    #    a. Revoke leftover IAMAllowedPrincipals (DB + every table).
    #       Without this the asset is "not managed by Lake Formation".
    #    b. Grant DESCRIBE (+ Grantable) on the DB to project + manage roles.
    #    c. Grant DESCRIBE+SELECT (+ Grantable) on every table to both.
    # Skip `glue_db_*` (SMUS-managed; already wired by SMUS itself).
    local _databases
    _databases="$(aws glue get-databases --region "$_region" --output json 2>/dev/null \
        | jq -r '.DatabaseList[]?.Name')"
    local _db
    while IFS= read -r _db; do
        [ -z "$_db" ] && continue
        case "$_db" in glue_db_*) continue ;; esac

        # 4a. Revoke IAMAllowedPrincipals on the database (ALL/DESCRIBE).
        # Suppress errors — the grant may not exist.
        aws lakeformation revoke-permissions --region "$_region" \
            --principal DataLakePrincipalIdentifier=IAM_ALLOWED_PRINCIPALS \
            --resource "{\"Database\":{\"Name\":\"${_db}\"}}" \
            --permissions ALL DESCRIBE >/dev/null 2>&1 || true

        # 4b. Grant DESCRIBE (+Grantable) on the database to both roles.
        local _principal
        for _principal in "$_data_access_role" "$_manage_access_role"; do
            [ -z "$_principal" ] && continue
            if aws lakeformation grant-permissions --region "$_region" \
                    --principal "DataLakePrincipalIdentifier=${_principal}" \
                    --resource "{\"Database\":{\"Name\":\"${_db}\"}}" \
                    --permissions DESCRIBE \
                    --permissions-with-grant-option DESCRIBE >/dev/null 2>&1; then
                echo "    + DESCRIBE (+Grantable) on database ${_db} → ${_principal##*/}"
            else
                echo "    = DESCRIBE on database ${_db} → ${_principal##*/} (already granted or no-op)"
            fi
        done

        # 4c. For every table: revoke IAMAllowedPrincipals, then grant
        # DESCRIBE+SELECT (+Grantable) to both roles.
        local _tables
        _tables="$(aws glue get-tables --region "$_region" --database-name "$_db" \
            --output json 2>/dev/null | jq -r '.TableList[]?.Name')"
        local _t
        while IFS= read -r _t; do
            [ -z "$_t" ] && continue

            aws lakeformation revoke-permissions --region "$_region" \
                --principal DataLakePrincipalIdentifier=IAM_ALLOWED_PRINCIPALS \
                --resource "{\"Table\":{\"DatabaseName\":\"${_db}\",\"Name\":\"${_t}\"}}" \
                --permissions ALL >/dev/null 2>&1 || true

            for _principal in "$_data_access_role" "$_manage_access_role"; do
                [ -z "$_principal" ] && continue
                aws lakeformation grant-permissions --region "$_region" \
                    --principal "DataLakePrincipalIdentifier=${_principal}" \
                    --resource "{\"Table\":{\"DatabaseName\":\"${_db}\",\"Name\":\"${_t}\"}}" \
                    --permissions DESCRIBE SELECT \
                    --permissions-with-grant-option DESCRIBE SELECT >/dev/null 2>&1 || true
            done
        done <<<"$_tables"

        echo "    + IAMAllowedPrincipals revoked + grants applied across ${_db} (table-level)"
    done <<<"$_databases"

    echo "==> Lake Formation bootstrap: complete"
}


_smus_session_bootstrap() {
    if [ "$MODE_FLAG" != "--apply" ]; then
        echo "==> SMUS session bootstrap: skipped (not in --apply mode)"
        return 0
    fi
    if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        echo "==> SMUS session bootstrap: skipped (aws/jq missing)"
        return 0
    fi

    local _domain_id="${MT_SMUS_DOMAIN_ID:-}"
    local _project_id="${MT_ADMIN_PROJECT_ID:-}"
    if [ -z "$_domain_id" ] || [ -z "$_project_id" ]; then
        echo "==> SMUS session bootstrap: skipped (domain/project ID not set yet)"
        return 0
    fi

    local _region="${AWS_DEFAULT_REGION:-us-east-1}"
    local _account
    _account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")"
    [ -z "$_account" ] && { echo "==> SMUS session bootstrap: skipped (no caller account)"; return 0; }

    local _bucket
    _bucket="$(_resolve_tooling_bucket "$_account" "$_region")"
    if ! aws s3api head-bucket --bucket "$_bucket" >/dev/null 2>&1; then
        echo "==> SMUS session bootstrap: skipped (tooling bucket ${_bucket} absent)"
        return 0
    fi

    # Locate the project's Tooling environment to derive the project
    # user role ARN. The Tooling env is the one with
    # `isDefaultToolingEnvironment=true` in its provisionedResources.
    local _tooling_env_id _project_user_role
    _tooling_env_id="$(aws datazone list-environments \
        --domain-identifier "$_domain_id" \
        --project-identifier "$_project_id" \
        --region "$_region" --output json 2>/dev/null \
        | jq -r '.items[]? | select(.name == "Tooling") | .id' | head -n 1)"
    if [ -z "$_tooling_env_id" ]; then
        echo "==> SMUS session bootstrap: WARN — Tooling environment not found; skipping"
        return 0
    fi
    _project_user_role="$(aws datazone get-environment \
        --domain-identifier "$_domain_id" \
        --identifier "$_tooling_env_id" \
        --region "$_region" \
        --query 'provisionedResources[?name==`userRoleArn`].value | [0]' \
        --output text 2>/dev/null | grep -v '^None$' || true)"
    if [ -z "$_project_user_role" ]; then
        echo "==> SMUS session bootstrap: WARN — userRoleArn not yet provisioned; skipping"
        return 0
    fi
    echo "==> SMUS session bootstrap: project user role ${_project_user_role##*/}"

    # ---- 0. Enable LF external data filtering for SMUS notebook sessions ---
    # SMUS Spark Connect (notebook) sessions call
    # `lakeformation:GetTemporaryGlueTableCredentials` to vend per-table
    # creds. Lake Formation refuses that call unless:
    #
    #   * `AllowExternalDataFiltering` is true at the data-lake-settings
    #     level, AND
    #   * the calling account (or an explicit principal) is in the
    #     `ExternalDataFilteringAllowList`, AND
    #   * the session tag value SMUS attaches ("Amazon DataZone") is in
    #     the `AuthorizedSessionTagValueList`.
    #
    # Without all three, notebooks see:
    #   org.apache.spark.fgac.error.AccessDeniedException:
    #   Failed to retrieve AWS Lake Formation temporary credentials...
    #
    # We also attach `lakeformation:GetTemporaryGlue*Credentials` to
    # the project user role; the AWS-managed policy has only the
    # legacy `GetDataAccess` perm, which is the IAM half of the same
    # problem.
    local _lf_now _lf_new _lf_changed=0
    _lf_now="$(aws lakeformation get-data-lake-settings --region "$_region" \
        --query 'DataLakeSettings' --output json 2>/dev/null || echo '{}')"
    _lf_new="$(printf '%s' "$_lf_now" | python3 -c '
import json, os, sys
s = json.load(sys.stdin)
acct = os.environ["MT_ACCOUNT"]
changed = False
if not s.get("AllowExternalDataFiltering"):
    s["AllowExternalDataFiltering"] = True
    changed = True
allow = s.get("ExternalDataFilteringAllowList") or []
if not any((p.get("DataLakePrincipalIdentifier") == acct) for p in allow):
    allow.append({"DataLakePrincipalIdentifier": acct})
    s["ExternalDataFilteringAllowList"] = allow
    changed = True
tags = s.get("AuthorizedSessionTagValueList") or []
# Authorized session-tag values cover every Spark/Athena engine SMUS
# can launch:
#   - "Amazon DataZone" / "Amazon SageMaker" / "Amazon SageMakerUnifiedStudio" — SMUS-managed Spark
#   - "AWS Lake Formation Glue" / "Amazon EMR" — Glue interactive sessions, EMR Serverless
#   - "Athena" / "Amazon Athena" — Athena Spark workgroups (notebook SQL cells set to "Athena (Spark)")
for v in ["Amazon DataZone", "Amazon SageMaker", "Amazon SageMakerUnifiedStudio", "AWS Lake Formation Glue", "Amazon EMR", "Athena", "Amazon Athena"]:
    if v not in tags:
        tags.append(v)
        changed = True
s["AuthorizedSessionTagValueList"] = tags
# AllowFullTableExternalDataAccess is required for Athena Spark and
# Glue interactive sessions to vend full-table credentials via
# `lakeformation:GetTemporaryGlueTableCredentials`. Without it, FGAC
# returns AccessDeniedException even when the principal has SELECT on
# the table.
if not s.get("AllowFullTableExternalDataAccess"):
    s["AllowFullTableExternalDataAccess"] = True
    changed = True
print(json.dumps(s))
print("CHANGED" if changed else "UNCHANGED", file=sys.stderr)
' 2>/tmp/_lf_changed_marker.txt || echo "{}")"
    if grep -q CHANGED /tmp/_lf_changed_marker.txt 2>/dev/null; then
        _lf_changed=1
    fi
    rm -f /tmp/_lf_changed_marker.txt
    if [ "$_lf_changed" -eq 1 ]; then
        local _lf_tmp
        _lf_tmp="$(mktemp -t "smus-lf-fgac-XXXXXX.json")"
        printf '%s' "$_lf_new" > "$_lf_tmp"
        if MT_ACCOUNT="$_account" aws lakeformation put-data-lake-settings \
                --data-lake-settings "file://${_lf_tmp}" \
                --region "$_region" >/dev/null 2>&1; then
            echo "    + LF external-data-filtering enabled + account ${_account} allow-listed + 'Amazon DataZone' session tag authorized"
        else
            echo "    WARN: put-data-lake-settings failed; FGAC notebook sessions may still see 'Access is not allowed'"
        fi
        rm -f "$_lf_tmp"
    else
        echo "    = LF external-data-filtering already enabled + account allow-listed"
    fi

    # IAM half: project user role needs lakeformation:GetTemporary*
    # Glue*Credentials — the AWS-managed
    # `SageMakerStudioProjectUserRolePolicy` has only the legacy
    # `lakeformation:GetDataAccess`, which doesn't cover FGAC.
    local _fgac_iam
    _fgac_iam="$(jq -n '{
        Version: "2012-10-17",
        Statement: [{
            Sid: "LakeFormationFGACCredentials",
            Effect: "Allow",
            Action: [
                "lakeformation:GetTemporaryGlueTableCredentials",
                "lakeformation:GetTemporaryGluePartitionCredentials"
            ],
            Resource: "*"
        }]
    }')"
    if aws iam put-role-policy \
            --role-name "${_project_user_role##*/}" \
            --policy-name LakeFormationFGACAccess \
            --policy-document "$_fgac_iam" >/dev/null 2>&1; then
        echo "    + LakeFormationFGACAccess inline policy applied to ${_project_user_role##*/}"
    fi

    # IAM half (continued): the AWS-managed `SageMakerStudioProjectUserRolePolicy`
    # gates `glue:GetTable*` on `glue:LakeFormationPermissions=Enabled`,
    # which evaluates to false when the table isn't fully LF-managed.
    # Glue interactive sessions (GlueJobRunnerSession) calling
    # `glue:GetTable` against external Glue tables then hit:
    #   "User: ... is not authorized to perform: glue:GetTable on
    #    resource: arn:aws:glue:...table/<db>/<table>"
    # We attach an unconditional Glue catalog read inline policy so
    # the session can resolve external table metadata regardless of
    # the LakeFormationPermissions condition.
    local _glue_read_iam
    _glue_read_iam="$(jq -n '{
        Version: "2012-10-17",
        Statement: [{
            Sid: "GlueCatalogReadUnconditional",
            Effect: "Allow",
            Action: [
                "glue:GetCatalog","glue:GetCatalogs",
                "glue:GetDatabase","glue:GetDatabases",
                "glue:GetTable","glue:GetTables",
                "glue:GetTableVersion","glue:GetTableVersions",
                "glue:GetPartition","glue:GetPartitions",
                "glue:BatchGetPartition","glue:SearchTables"
            ],
            Resource: [
                "arn:aws:glue:*:*:catalog",
                "arn:aws:glue:*:*:catalog/*",
                "arn:aws:glue:*:*:database/*",
                "arn:aws:glue:*:*:table/*/*"
            ]
        }]
    }')"
    if aws iam put-role-policy \
            --role-name "${_project_user_role##*/}" \
            --policy-name GlueCatalogReadAccess \
            --policy-document "$_glue_read_iam" >/dev/null 2>&1; then
        echo "    + GlueCatalogReadAccess inline policy applied to ${_project_user_role##*/}"
    fi

    # ---- 1. Lake Formation registrations on the tooling bucket -------------
    local _project_path="${_bucket}/dzd-${_domain_id#dzd-}/${_project_id}/dev"
    local _bucket_arn="arn:aws:s3:::${_bucket}"
    local _project_arn="arn:aws:s3:::${_project_path}"
    local _glue_subpath_arn="arn:aws:s3:::${_project_path}/glue"

    # Deregister SLR-managed strict-mode registrations that would
    # otherwise gate Spark log writes. These calls are idempotent:
    # ENTITY_NOT_FOUND on a missing registration is fine.
    local _arn
    for _arn in "$_bucket_arn" "$_glue_subpath_arn"; do
        if aws lakeformation describe-resource --resource-arn "$_arn" \
                --region "$_region" --output json >/dev/null 2>&1; then
            local _hybrid
            _hybrid="$(aws lakeformation describe-resource --resource-arn "$_arn" \
                --region "$_region" --query 'ResourceInfo.HybridAccessEnabled' \
                --output text 2>/dev/null || echo "false")"
            if [ "$_hybrid" != "True" ] && [ "$_hybrid" != "true" ]; then
                if aws lakeformation deregister-resource --resource-arn "$_arn" \
                        --region "$_region" >/dev/null 2>&1; then
                    echo "    + deregistered strict-mode LF resource ${_arn##*/}"
                fi
            fi
        fi
    done

    # Ensure the project's /dev prefix is registered in hybrid mode
    # owned by the project user role. update-resource is the idempotent
    # path; if it doesn't exist yet, register-resource creates it.
    if aws lakeformation describe-resource --resource-arn "$_project_arn" \
            --region "$_region" --output json >/dev/null 2>&1; then
        aws lakeformation update-resource --resource-arn "$_project_arn" \
            --role-arn "$_project_user_role" --hybrid-access-enabled \
            --region "$_region" >/dev/null 2>&1 || true
        echo "    + LF /dev hybrid mode confirmed (role=${_project_user_role##*/})"
    else
        aws lakeformation register-resource --resource-arn "$_project_arn" \
            --role-arn "$_project_user_role" --hybrid-access-enabled \
            --region "$_region" >/dev/null 2>&1 || \
            echo "    WARN: LF register-resource failed for ${_project_arn}"
        echo "    + LF /dev registered hybrid (role=${_project_user_role##*/})"
    fi

    # ---- 1.5 Source S3 registrations need WithFederation=true for FGAC ----
    # Athena Spark workgroups and Glue interactive sessions in FGAC mode
    # call `lakeformation:GetTemporaryGlueTableCredentials` to vend
    # per-table credentials. LF returns `AccessDeniedException: Access
    # is not allowed` for any table whose underlying S3 location is
    # registered without `WithFederation=true` — even when every other
    # FGAC requirement (allow-list, session tag, IAM perm, table grant)
    # is satisfied.
    #
    # The default SLR-managed registrations created by Glue jobs /
    # crawlers can NOT be updated with WithFederation (LF returns
    # `Resource managed by Service Linked Role`). Workaround:
    #   1. Ensure a dedicated registration role exists with S3 RW +
    #      glue:Get* + lakeformation:GetDataAccess perms and a trust
    #      policy that lets lakeformation.amazonaws.com assume it.
    #   2. For every seed S3 prefix backed by a Glue table, deregister
    #      the SLR-managed registration and re-register with the new
    #      role + --hybrid-access-enabled + --with-federation.
    #
    # Scope: we walk every Glue table in every external Glue DB, take
    # the unique set of S3 prefixes (bucket + bucket/prefix), and
    # re-register each. Skipping `glue_db_*` (project-managed) keeps us
    # away from the SMUS-managed lakehouse paths.

    # 1.5a. Discover the dedicated registration role. The role is
    # created declaratively by `cfn/child-stacks/sus-domain-stack.yaml`
    # (logical id `rSUSLFRegistrationRole`) — `_cfn_bootstrap` runs
    # before this helper, so the role is guaranteed to exist by the
    # time we get here. We still verify defensively so a hand-rolled
    # deploy that skipped the domain stack falls through cleanly.
    local _reg_role_name="smus-seed-lf-registration-role"
    local _reg_role_arn="arn:aws:iam::${_account}:role/${_reg_role_name}"
    if ! aws iam get-role --role-name "$_reg_role_name" >/dev/null 2>&1; then
        echo "    WARN: ${_reg_role_name} not found — expected to be created by sus-domain-stack.yaml; skipping WithFederation re-registration"
        _reg_role_arn=""
    fi

    # 1.5b. Walk every external Glue DB, collect unique S3 prefixes,
    # deregister + re-register with WithFederation=true.
    if [ -n "$_reg_role_arn" ]; then
        local _all_dbs _ext_db _all_locations
        _all_dbs="$(aws glue get-databases --region "$_region" --output json 2>/dev/null \
            | jq -r '.DatabaseList[]?.Name' 2>/dev/null || true)"
        # Collect every table location into a deduped set.
        _all_locations=""
        while IFS= read -r _ext_db; do
            [ -z "$_ext_db" ] && continue
            case "$_ext_db" in glue_db_*) continue ;; esac
            local _locs
            _locs="$(aws glue get-tables --region "$_region" \
                --database-name "$_ext_db" --output json 2>/dev/null \
                | jq -r '.TableList[]?.StorageDescriptor.Location // empty' \
                2>/dev/null || true)"
            _all_locations="${_all_locations}${_locs}
"
        done <<<"$_all_dbs"

        # Build the set of ARNs to register: each table's exact S3 prefix
        # (as ARN form) PLUS the bucket-root ARN. Deduplicate via sort -u.
        local _arns_to_register
        _arns_to_register="$(printf '%s' "$_all_locations" | python3 -c '
import sys
arns = set()
for line in sys.stdin:
    loc = line.strip()
    if not loc.startswith("s3://"):
        continue
    # Strip s3:// and trailing slash.
    body = loc[5:].rstrip("/")
    if not body:
        continue
    parts = body.split("/", 1)
    bucket = parts[0]
    arns.add(f"arn:aws:s3:::{bucket}")
    if len(parts) > 1 and parts[1]:
        arns.add(f"arn:aws:s3:::{bucket}/{parts[1]}")
for a in sorted(arns):
    print(a)
')"
        local _to_register_count
        _to_register_count="$(printf '%s' "$_arns_to_register" | grep -c . 2>/dev/null || echo 0)"

        if [ "${_to_register_count:-0}" != "0" ]; then
            echo "    + re-registering ${_to_register_count} source S3 prefix(es) with WithFederation=true"
            local _arn_to_reg _existing_role
            while IFS= read -r _arn_to_reg; do
                [ -z "$_arn_to_reg" ] && continue
                # If already registered with our custom role, leave it
                # alone (idempotent). Otherwise deregister + re-register.
                _existing_role="$(aws lakeformation describe-resource \
                    --resource-arn "$_arn_to_reg" --region "$_region" \
                    --query 'ResourceInfo.RoleArn' --output text 2>/dev/null \
                    | grep -v '^None$' || true)"
                if [ "$_existing_role" = "$_reg_role_arn" ]; then
                    continue
                fi
                if [ -n "$_existing_role" ]; then
                    aws lakeformation deregister-resource \
                        --resource-arn "$_arn_to_reg" --region "$_region" \
                        >/dev/null 2>&1 || true
                fi
                aws lakeformation register-resource \
                    --resource-arn "$_arn_to_reg" \
                    --role-arn "$_reg_role_arn" \
                    --hybrid-access-enabled \
                    --with-federation \
                    --region "$_region" >/dev/null 2>&1 || \
                    echo "    WARN: register-resource with-federation failed for ${_arn_to_reg##*/}"
            done <<<"$_arns_to_register"
            echo "    + WithFederation registrations complete"
        fi
    fi

    # ---- 2. KMS key policy on the tooling bucket's CMK ---------------------
    local _kms_key_id
    _kms_key_id="$(aws s3api get-bucket-encryption --bucket "$_bucket" \
        --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.KMSMasterKeyID' \
        --output text 2>/dev/null | grep -v '^None$' || true)"
    if [ -z "$_kms_key_id" ]; then
        echo "    = tooling bucket not KMS-encrypted; skipping key policy update"
        echo "==> SMUS session bootstrap: complete"
        return 0
    fi
    # Strip ARN prefix to get bare key id for kms calls.
    local _kms_key_short="${_kms_key_id##*/}"

    # Only customer-managed keys are mutable. Skip aws-managed keys.
    local _key_manager
    _key_manager="$(aws kms describe-key --key-id "$_kms_key_short" \
        --query 'KeyMetadata.KeyManager' --output text 2>/dev/null || echo "AWS")"
    if [ "$_key_manager" != "CUSTOMER" ]; then
        echo "    = tooling bucket KMS key is AWS-managed; nothing to update"
        echo "==> SMUS session bootstrap: complete"
        return 0
    fi

    local _policy_now
    _policy_now="$(aws kms get-key-policy --key-id "$_kms_key_short" \
        --policy-name default --query 'Policy' --output text 2>/dev/null || echo "")"
    if [ -z "$_policy_now" ]; then
        echo "    WARN: could not read KMS key policy; skipping"
        echo "==> SMUS session bootstrap: complete"
        return 0
    fi

    # Has the project user role already been added? Match by Sid.
    local _has_stmt
    _has_stmt="$(printf '%s' "$_policy_now" | jq \
        --arg sid "AllowProjectUserRoleForSparkLogs" \
        '[.Statement[]? | select(.Sid == $sid)] | length' 2>/dev/null || echo "0")"
    if [ "$_has_stmt" != "0" ]; then
        echo "    = KMS key policy already grants project user role"
        echo "==> SMUS session bootstrap: complete"
        return 0
    fi

    # Append the new statement and PUT the merged policy back.
    local _policy_new
    _policy_new="$(printf '%s' "$_policy_now" | jq \
        --arg role "$_project_user_role" \
        --arg s3svc "s3.${_region}.amazonaws.com" \
        --arg gluesvc "glue.${_region}.amazonaws.com" \
        '.Statement += [{
            Sid: "AllowProjectUserRoleForSparkLogs",
            Effect: "Allow",
            Principal: { AWS: $role },
            Action: [
                "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*",
                "kms:GenerateDataKey*", "kms:DescribeKey"
            ],
            Resource: "*",
            Condition: {
                StringLike: {
                    "kms:ViaService": [$s3svc, $gluesvc]
                }
            }
        }]')"
    if aws kms put-key-policy --key-id "$_kms_key_short" \
            --policy-name default --policy "$_policy_new" >/dev/null 2>&1; then
        echo "    + KMS key policy now grants Encrypt/Decrypt/GenerateDataKey* to ${_project_user_role##*/}"
    else
        echo "    WARN: KMS put-key-policy failed; Glue sessions may still see 'S3 bucket is not accessible'"
    fi

    # Persist discovered roles to the SMUS setup config so
    # `migrate.sh` (and audit tooling) can pick them up without
    # re-querying DataZone.
    if [ -n "${_project_user_role:-}" ]; then
        _smus_setup_config_set tooling_user_role_arn "$_project_user_role"
    fi
    if aws iam get-role --role-name smus-seed-lf-registration-role >/dev/null 2>&1; then
        local _lf_arn
        _lf_arn="$(aws iam get-role --role-name smus-seed-lf-registration-role \
            --query 'Role.Arn' --output text 2>/dev/null || true)"
        if [ -n "$_lf_arn" ]; then
            _smus_setup_config_set lf_registration_role_arn "$_lf_arn"
        fi
    fi

    echo "==> SMUS session bootstrap: complete"
}


_smus_codecommit_grant() {
    if [ "$MODE_FLAG" != "--apply" ]; then
        echo "==> SMUS CodeCommit grant: skipped (not in --apply mode)"
        return 0
    fi

    local _repo_provider="${MT_REPO_PROVIDER:-}"
    if [ -z "$_repo_provider" ] && command -v jq >/dev/null 2>&1; then
        _repo_provider="$(jq -r '.repo_provider // empty' \
            "${ROOT_DIR}/config/migration.config.json" 2>/dev/null || true)"
    fi
    if [ "$_repo_provider" != "codecommit" ]; then
        echo "==> SMUS CodeCommit grant: skipped (repo_provider=${_repo_provider:-unset})"
        return 0
    fi

    local _domain_id="${MT_SMUS_DOMAIN_ID:-}"
    local _project_id="${MT_ADMIN_PROJECT_ID:-}"
    if [ -z "$_domain_id" ] || [ -z "$_project_id" ]; then
        echo "==> SMUS CodeCommit grant: skipped (domain/project ID not set yet)"
        return 0
    fi

    local _region="${AWS_DEFAULT_REGION:-us-east-1}"
    local _account
    _account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")"
    if [ -z "$_account" ]; then
        echo "==> SMUS CodeCommit grant: skipped (no caller account)"
        return 0
    fi

    # Discover the project user role ARN via the Tooling environment.
    local _tooling_env_id _project_user_role
    _tooling_env_id="$(aws datazone list-environments \
        --domain-identifier "$_domain_id" \
        --project-identifier "$_project_id" \
        --region "$_region" --output json 2>/dev/null \
        | jq -r '.items[]? | select(.name == "Tooling") | .id' | head -n 1)"
    if [ -z "$_tooling_env_id" ]; then
        echo "==> SMUS CodeCommit grant: WARN — Tooling env not found; skipping"
        return 0
    fi
    _project_user_role="$(aws datazone get-environment \
        --domain-identifier "$_domain_id" \
        --identifier "$_tooling_env_id" \
        --region "$_region" \
        --query 'provisionedResources[?name==`userRoleArn`].value | [0]' \
        --output text 2>/dev/null | grep -v '^None$' || true)"
    if [ -z "$_project_user_role" ]; then
        echo "==> SMUS CodeCommit grant: WARN — userRoleArn not yet provisioned; skipping"
        return 0
    fi
    local _role_name="${_project_user_role##*/}"

    # Resolve the repo name from MT_REPO_NAME or migration.config.json.
    local _repo_name="${MT_REPO_NAME:-}"
    if [ -z "$_repo_name" ] && command -v jq >/dev/null 2>&1; then
        _repo_name="$(jq -r '.repo_name // empty' \
            "${ROOT_DIR}/config/migration.config.json" 2>/dev/null || true)"
    fi
    if [ -z "$_repo_name" ]; then
        echo "==> SMUS CodeCommit grant: WARN — repo_name not resolvable; skipping"
        return 0
    fi
    local _repo_arn="arn:aws:codecommit:${_region}:${_account}:${_repo_name}"

    # Build the inline policy: repo-scoped Git ops + account-wide
    # ListRepositories (needed by the SMUS portal's repo browser).
    local _policy_doc
    _policy_doc="$(jq -n \
        --arg arn "$_repo_arn" \
        '{
            Version: "2012-10-17",
            Statement: [
                {
                    Sid: "CodeCommitGitOps",
                    Effect: "Allow",
                    Action: [
                        "codecommit:GitPull",
                        "codecommit:GitPush",
                        "codecommit:GetRepository",
                        "codecommit:GetBranch",
                        "codecommit:GetReferences",
                        "codecommit:ListBranches",
                        "codecommit:CreateBranch",
                        "codecommit:UpdateDefaultBranch",
                        "codecommit:GetRepositoryTriggers",
                        "codecommit:BatchGetCommits",
                        "codecommit:GetCommit",
                        "codecommit:GetDifferences",
                        "codecommit:CreateCommit",
                        "codecommit:GetTree"
                    ],
                    Resource: $arn
                },
                {
                    Sid: "CodeCommitListRepos",
                    Effect: "Allow",
                    Action: ["codecommit:ListRepositories"],
                    Resource: "*"
                }
            ]
        }')"
    if aws iam put-role-policy \
            --role-name "$_role_name" \
            --policy-name CodeCommitAccess \
            --policy-document "$_policy_doc" >/dev/null 2>&1; then
        echo "==> SMUS CodeCommit grant: + inline CodeCommitAccess applied to ${_role_name} (repo=${_repo_arn})"
    else
        echo "==> SMUS CodeCommit grant: WARN — put-role-policy failed; users may see 403 from CodeCommit"
    fi
}


_teardown_destroy_smus_stack() {
    local _apply="$1" _region="$2" _domain_id="$3" _project_id="$4"
    local _stack_name
    _stack_name="$(_resolve_stack_name)"

    # Inner helper invoked when the stack delete succeeds. Cleans up
    # resources that survive the CFN delete because they're either
    # SMUS-auto-provisioned (out of any stack) or carry a Retain
    # deletion policy:
    #   * The tooling bucket `amazon-datazone-tooling-<acct>-<region>`
    #     keeps every Spark log + notebook checkpoint and has versioning
    #     on. We drain ALL versions/markers (boto3 paginator) and then
    #     delete the bucket itself.
    #   * The orphaned `glue_db_<env_id>` is sometimes re-created by
    #     the env CFN sub-stack during its delete sequence. Section B'
    #     dropped it once but it can come back; check + drop again.
    _final_cleanup() {
        local _account
        _account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")"
        if [ -n "$_account" ]; then
            local _bucket
            _bucket="$(_resolve_tooling_bucket "$_account" "$_region")"
            if aws s3api head-bucket --bucket "$_bucket" >/dev/null 2>&1; then
                # Drain every version + delete-marker via boto3 (the AWS
                # CLI's `s3 rm --recursive` doesn't traverse versions on
                # versioned buckets reliably). Inline python so we don't
                # depend on a separate scratch script that might not
                # ship with a clean checkout.
                if command -v python3 >/dev/null 2>&1; then
                    AWS_REGION="$_region" python3 - "$_bucket" <<'PY' >/dev/null 2>&1 || true
import os, sys, boto3
bucket = sys.argv[1]
session = boto3.Session(
    profile_name=os.environ.get("AWS_PROFILE") or None,
    region_name=os.environ.get("AWS_REGION", "us-east-1"),
)
s3 = session.client("s3")
paginator = s3.get_paginator("list_object_versions")
for page in paginator.paginate(Bucket=bucket):
    keys = []
    for v in page.get("Versions") or []:
        keys.append({"Key": v["Key"], "VersionId": v["VersionId"]})
    for d in page.get("DeleteMarkers") or []:
        keys.append({"Key": d["Key"], "VersionId": d["VersionId"]})
    for chunk in (keys[i:i + 1000] for i in range(0, len(keys), 1000)):
        if not chunk:
            continue
        s3.delete_objects(Bucket=bucket, Delete={"Objects": chunk, "Quiet": True})
PY
                fi
                if aws s3api delete-bucket --bucket "$_bucket" \
                        >/dev/null 2>&1; then
                    echo "    + drained + deleted tooling bucket ${_bucket}"
                fi
            fi
        fi
        # Re-check for orphan glue_db_<env_id> created while the
        # env stacks were tearing down.
        if [ -n "$_domain_id" ]; then
            local _orphan_dbs _db
            _orphan_dbs="$(aws glue get-databases --region "$_region" \
                --output json 2>/dev/null \
                | jq -r --arg d "$_domain_id" \
                    '.DatabaseList[]? | select(.Name | startswith("glue_db_")) | select((.LocationUri // "") | contains($d)) | .Name' \
                2>/dev/null || true)"
            while IFS= read -r _db; do
                [ -z "$_db" ] && continue
                # Need LF DROP perm; grant Admin first then drop.
                local _caller_arn _caller_role
                _caller_arn="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo "")"
                if [[ "$_caller_arn" =~ ^arn:aws:sts::([0-9]+):assumed-role/([^/]+)/.*$ ]]; then
                    _caller_role="arn:aws:iam::${BASH_REMATCH[1]}:role/${BASH_REMATCH[2]}"
                    aws lakeformation grant-permissions --region "$_region" \
                        --principal "DataLakePrincipalIdentifier=${_caller_role}" \
                        --resource "{\"Database\":{\"Name\":\"${_db}\"}}" \
                        --permissions ALL DROP >/dev/null 2>&1 || true
                fi
                local _t
                for _t in $(aws glue get-tables --database-name "$_db" \
                        --region "$_region" --output json 2>/dev/null \
                        | jq -r '.TableList[]?.Name' 2>/dev/null); do
                    aws glue delete-table --database-name "$_db" --name "$_t" \
                        --region "$_region" >/dev/null 2>&1 || true
                done
                if aws glue delete-database --name "$_db" --region "$_region" \
                        >/dev/null 2>&1; then
                    echo "    + dropped re-created orphan project DB ${_db}"
                fi
            done <<<"$_orphan_dbs"
        fi
    }

    if ! aws cloudformation describe-stacks --stack-name "$_stack_name" \
            --region "$_region" >/dev/null 2>&1; then
        echo "    = CFN stack ${_stack_name} not found; nothing to delete"
        return 0
    fi

    if [ "$_apply" -ne 1 ]; then
        echo "    DRY-RUN: would run hardening passes (drain VPC endpoints, revoke cross-SG"
        echo "             ingress, delete environments, clean LF admins) and then"
        echo "             delete CFN stack ${_stack_name} with --retain-resources fallback"
        return 0
    fi

    # ---- A. Drain SMUS-managed VPC endpoints attached to the project's --
    # ---- Tooling SG (failure mode 1). -----------------------------------
    if [ -n "$_project_id" ] && [ -n "$_domain_id" ]; then
        local _tooling_envs _tooling_env_id
        _tooling_envs="$(aws datazone list-environments \
            --domain-identifier "$_domain_id" \
            --project-identifier "$_project_id" \
            --region "$_region" --output json 2>/dev/null \
            | jq -r '.items[]?.id' 2>/dev/null || true)"
        local _env_id
        while IFS= read -r _env_id; do
            [ -z "$_env_id" ] && continue
            local _sg_id
            _sg_id="$(aws datazone get-environment \
                --domain-identifier "$_domain_id" \
                --identifier "$_env_id" \
                --region "$_region" \
                --query 'provisionedResources[?name==`securityGroup`].value | [0]' \
                --output text 2>/dev/null | grep -v '^None$' || true)"
            [ -z "$_sg_id" ] && continue

            # Find every VPC endpoint attached to this SG and delete it.
            # SMUS-managed endpoints are not in any CFN stack and are
            # the documented source of failure mode 1.
            local _vpce_ids
            _vpce_ids="$(aws ec2 describe-vpc-endpoints \
                --filters "Name=group-id,Values=${_sg_id}" \
                --region "$_region" --output json 2>/dev/null \
                | jq -r '.VpcEndpoints[]?.VpcEndpointId' 2>/dev/null || true)"
            if [ -n "$_vpce_ids" ]; then
                # shellcheck disable=SC2086 # word-splitting intended
                local _vpce_array=($_vpce_ids)
                if [ "${#_vpce_array[@]}" -gt 0 ]; then
                    if aws ec2 delete-vpc-endpoints \
                            --vpc-endpoint-ids "${_vpce_array[@]}" \
                            --region "$_region" >/dev/null 2>&1; then
                        echo "    + drained ${#_vpce_array[@]} VPC endpoint(s) attached to env ${_env_id} SG ${_sg_id}"
                    fi
                fi
            fi

            # ---- A'. Drain orphan DataZone-managed ENIs on this SG. -----
            # SMUS provisions a DataZone-owned ENI with description
            # "[DO NOT DELETE] ENI managed by DataZone for ComputeEnvironment(...)"
            # for the project's compute environment. Even after VPC
            # endpoints, Spaces, MWAA workers, and Glue sessions are
            # gone, this single ENI can keep the Tooling SG alive and
            # blocks the env CFN sub-stack from deleting (failure mode 1b).
            #
            # The ENI is `RequesterId=386143666269` (DataZone service
            # account) but `OwnerId` is the customer account, which means
            # we own it and can force-detach + delete. SMUS does NOT
            # remove these ENIs as part of project teardown.
            local _orphan_enis _eni_id _attach_id
            _orphan_enis="$(aws ec2 describe-network-interfaces \
                --filters "Name=group-id,Values=${_sg_id}" \
                --region "$_region" --output json 2>/dev/null \
                | jq -r '.NetworkInterfaces[]?.NetworkInterfaceId' 2>/dev/null || true)"
            while IFS= read -r _eni_id; do
                [ -z "$_eni_id" ] && continue
                _attach_id="$(aws ec2 describe-network-interfaces \
                    --network-interface-ids "$_eni_id" --region "$_region" \
                    --query 'NetworkInterfaces[0].Attachment.AttachmentId' \
                    --output text 2>/dev/null | grep -v '^None$' || true)"
                if [ -n "$_attach_id" ]; then
                    if aws ec2 detach-network-interface \
                            --attachment-id "$_attach_id" --force \
                            --region "$_region" >/dev/null 2>&1; then
                        echo "    + force-detached ENI ${_eni_id} (was on SG ${_sg_id})"
                    fi
                    sleep 8
                fi
                if aws ec2 delete-network-interface \
                        --network-interface-id "$_eni_id" \
                        --region "$_region" >/dev/null 2>&1; then
                    echo "    + deleted orphan ENI ${_eni_id}"
                fi
            done <<<"$_orphan_enis"

            # Revoke ingress rules on sibling SGs that reference this
            # Tooling SG (failure mode 2). Cross-references prevent
            # the SG from being deleted even after ENIs drain.
            local _sibling_sgs _sibling_sg
            _sibling_sgs="$(aws ec2 describe-security-groups \
                --filters "Name=ip-permission.group-id,Values=${_sg_id}" \
                --region "$_region" --output json 2>/dev/null \
                | jq -r '.SecurityGroups[]?.GroupId' 2>/dev/null || true)"
            while IFS= read -r _sibling_sg; do
                [ -z "$_sibling_sg" ] && continue
                local _rule_ids _rule_id
                _rule_ids="$(aws ec2 describe-security-group-rules \
                    --filters "Name=group-id,Values=${_sibling_sg}" \
                    --region "$_region" --output json 2>/dev/null \
                    | jq -r --arg sg "$_sg_id" \
                        '.SecurityGroupRules[]? | select(.ReferencedGroupInfo.GroupId == $sg) | .SecurityGroupRuleId' \
                    2>/dev/null || true)"
                while IFS= read -r _rule_id; do
                    [ -z "$_rule_id" ] && continue
                    if aws ec2 revoke-security-group-ingress \
                            --group-id "$_sibling_sg" \
                            --security-group-rule-ids "$_rule_id" \
                            --region "$_region" >/dev/null 2>&1; then
                        echo "    + revoked ingress ${_rule_id} on ${_sibling_sg} (referenced ${_sg_id})"
                    fi
                done <<<"$_rule_ids"
            done <<<"$_sibling_sgs"
        done <<<"$_tooling_envs"
    fi

    # ---- B. Drive each environment to GONE before parent delete. --------
    if [ -n "$_project_id" ] && [ -n "$_domain_id" ]; then
        local _envs_json _env_id _env_status _env_max_polls
        _env_max_polls=40   # 40 * 30s = 20 min per env
        _envs_json="$(aws datazone list-environments \
            --domain-identifier "$_domain_id" \
            --project-identifier "$_project_id" \
            --region "$_region" --output json 2>/dev/null \
            | jq -r '.items[]?.id' 2>/dev/null || true)"
        while IFS= read -r _env_id; do
            [ -z "$_env_id" ] && continue
            _env_status="$(aws datazone get-environment \
                --domain-identifier "$_domain_id" \
                --identifier "$_env_id" \
                --region "$_region" --query 'status' --output text 2>/dev/null || echo "GONE")"
            if [ "$_env_status" = "GONE" ]; then
                continue
            fi
            # Issue delete (or re-issue if it was DELETE_FAILED).
            aws datazone delete-environment \
                --domain-identifier "$_domain_id" \
                --identifier "$_env_id" --region "$_region" >/dev/null 2>&1 || true
            echo "    + delete-environment ${_env_id} issued; waiting"
            local _i=0
            while [ "$_i" -lt "$_env_max_polls" ]; do
                _env_status="$(aws datazone get-environment \
                    --domain-identifier "$_domain_id" \
                    --identifier "$_env_id" \
                    --region "$_region" --query 'status' --output text 2>/dev/null || echo "GONE")"
                case "$_env_status" in
                    GONE) break ;;
                    DELETE_FAILED) break ;;
                esac
                _i=$((_i + 1))
                sleep 30
            done
            if [ "$_env_status" = "GONE" ]; then
                echo "    + env ${_env_id} deleted"
            else
                echo "    WARN: env ${_env_id} ended in ${_env_status}; CFN delete will likely fail again"
            fi
        done <<<"$_envs_json"
    fi

    # ---- B'. Drop orphaned project-managed Glue DBs (failure mode 6). ----
    # SMUS auto-creates `glue_db_<env_id>` for every Lakehouse Database
    # environment but doesn't include it in the env's CFN sub-stack —
    # so `delete-environment` leaves the Glue DB and its resource
    # links behind. They show up in the next deployment's SMUS
    # Catalog tree as confusing "ghost" entries pointing at long-gone
    # source tables.
    #
    # We identify project-managed DBs by `LocationUri` containing the
    # current domain id; that match is precise enough to avoid
    # touching unrelated Glue DBs in the same account.
    if [ -n "$_domain_id" ]; then
        local _orphan_dbs _db
        _orphan_dbs="$(aws glue get-databases --region "$_region" \
            --output json 2>/dev/null \
            | jq -r --arg d "$_domain_id" \
                '.DatabaseList[]? | select(.Name | startswith("glue_db_")) | select((.LocationUri // "") | contains($d)) | .Name' \
            2>/dev/null || true)"
        while IFS= read -r _db; do
            [ -z "$_db" ] && continue
            echo "    + dropping orphaned project DB ${_db}"
            local _t
            for _t in $(aws glue get-tables --database-name "$_db" \
                    --region "$_region" --output json 2>/dev/null \
                    | jq -r '.TableList[]?.Name' 2>/dev/null); do
                aws glue delete-table --database-name "$_db" --name "$_t" \
                    --region "$_region" >/dev/null 2>&1 || true
            done
            aws glue delete-database --name "$_db" --region "$_region" \
                >/dev/null 2>&1 || true
        done <<<"$_orphan_dbs"
    fi

    # ---- B''. Force project delete if it stuck in DELETE_FAILED. ------
    # Even after envs are gone, the DataZone project itself can be
    # in DELETE_FAILED (failure mode: "Project failed to stabilize
    # due to internal failure" or stale env-deletion error). The
    # `--skip-deletion-check` flag bypasses the cross-resource
    # validation and pushes the project to DELETING. The project's
    # CFN sub-stack (`smus-seed-ProjectStack-*`) then unblocks on
    # the next delete-stack attempt.
    if [ -n "$_project_id" ] && [ -n "$_domain_id" ]; then
        local _project_status
        _project_status="$(aws datazone get-project \
            --domain-identifier "$_domain_id" \
            --identifier "$_project_id" \
            --region "$_region" --query 'projectStatus' \
            --output text 2>/dev/null | grep -v '^None$' || true)"
        if [ "$_project_status" = "DELETE_FAILED" ]; then
            echo "    + project ${_project_id} stuck in DELETE_FAILED; force-deleting with --skip-deletion-check"
            aws datazone delete-project \
                --domain-identifier "$_domain_id" \
                --identifier "$_project_id" \
                --skip-deletion-check \
                --region "$_region" >/dev/null 2>&1 || true
            # Wait briefly for state to flip to DELETING — actual
            # deletion can take minutes; we don't block on it here
            # because the parent delete-stack will catch up.
            local _pwait=0
            while [ "$_pwait" -lt 6 ]; do
                _project_status="$(aws datazone get-project \
                    --domain-identifier "$_domain_id" \
                    --identifier "$_project_id" \
                    --region "$_region" --query 'projectStatus' \
                    --output text 2>/dev/null | grep -v '^None$' || echo "GONE")"
                if [ "$_project_status" = "GONE" ] || [ "$_project_status" = "DELETING" ]; then
                    break
                fi
                _pwait=$((_pwait + 1))
                sleep 10
            done
            echo "    + project status now: ${_project_status}"
        fi
    fi

    # ---- C. Strip dangling principals from LF data-lake admins. --------
    # (failure mode 3.) Any principal whose underlying IAM role no
    # longer exists is a CFN-killer; remove it now.
    #
    # NOTE: this cleanup runs THREE times during teardown:
    #   * Section C (here) — strips dangling roles before the first delete-stack
    #   * Before the second delete-stack — env CFN sub-stacks delete the
    #     project user role part-way through, leaving a fresh dangling
    #     entry that the first attempt added.
    #   * The function `_lf_strip_dangling_admins` makes this idempotent
    #     and safe to call any number of times.
    _lf_strip_dangling_admins "$_region"

    # ---- D. First parent delete attempt. -------------------------------
    aws cloudformation delete-stack --stack-name "$_stack_name" \
        --region "$_region" >/dev/null 2>&1
    echo "    + first delete-stack issued for ${_stack_name}; waiting (up to 30 min)"
    if aws cloudformation wait stack-delete-complete \
            --stack-name "$_stack_name" --region "$_region" >/dev/null 2>&1; then
        echo "    + ${_stack_name} deleted on first attempt"
        _final_cleanup
        return 0
    fi
    if ! aws cloudformation describe-stacks --stack-name "$_stack_name" \
            --region "$_region" >/dev/null 2>&1; then
        echo "    + ${_stack_name} deleted"
        _final_cleanup
        return 0
    fi

    # ---- E. Inspect failure; retry domain sub-stack with --retain-resources
    # ---- if rSUSDomainOwnerIAMRole is the blocker (failure mode 4). ----
    local _failed_resources _has_owner_failure _has_lf_admin_failure
    _failed_resources="$(aws cloudformation describe-stack-events \
        --stack-name "$_stack_name" --max-items 30 \
        --region "$_region" --output json 2>/dev/null \
        | jq -r '.StackEvents[]? | select(.ResourceStatus == "DELETE_FAILED") | .ResourceStatusReason')"
    _has_owner_failure="$(printf '%s' "$_failed_resources" | grep -c rSUSDomainOwnerIAMRole || true)"
    _has_lf_admin_failure="$(printf '%s' "$_failed_resources" | grep -c rAddDataLakeAdministratorToLakeFormation || true)"
    if [ "${_has_owner_failure:-0}" != "0" ]; then
        echo "    + rSUSDomainOwnerIAMRole blocked the domain sub-stack; retrying with --retain-resources"
        local _domain_substack
        _domain_substack="$(aws cloudformation describe-stack-resources \
            --stack-name "$_stack_name" --region "$_region" \
            --logical-resource-id DomainStack --output json 2>/dev/null \
            | jq -r '.StackResources[0].PhysicalResourceId' 2>/dev/null || true)"
        if [ -n "$_domain_substack" ] && [ "$_domain_substack" != "null" ]; then
            aws cloudformation delete-stack \
                --stack-name "$_domain_substack" \
                --retain-resources rSUSDomainOwnerIAMRole \
                --region "$_region" >/dev/null 2>&1 || true
            # Wait for the sub-stack to reach DELETE_COMPLETE.
            local _sub_max_polls=40
            local _sub_status _sj=0
            while [ "$_sj" -lt "$_sub_max_polls" ]; do
                _sub_status="$(aws cloudformation describe-stacks \
                    --stack-name "$_domain_substack" \
                    --region "$_region" --query 'Stacks[0].StackStatus' \
                    --output text 2>/dev/null || echo "GONE")"
                case "$_sub_status" in
                    GONE|DELETE_COMPLETE) break ;;
                    DELETE_FAILED) break ;;
                esac
                _sj=$((_sj + 1))
                sleep 30
            done
            echo "    + domain sub-stack ended in ${_sub_status}"
        fi
    fi

    # ---- E'. Retry project sub-stack with --retain-resources if -------
    # ---- rAddDataLakeAdministratorToLakeFormation is the blocker. ------
    # The project sub-stack's `AWS::LakeFormation::DataLakeSettings`
    # delete handler fails with "Invalid principal" when the LF admins
    # list contains a dangling project user role. We strip the
    # dangling admins first (Section C / F do this), but the LF admin
    # CFN resource itself can stay stuck until we retain it.
    if [ "${_has_lf_admin_failure:-0}" != "0" ]; then
        echo "    + rAddDataLakeAdministratorToLakeFormation blocked the project sub-stack; retrying with --retain-resources"
        # Strip dangling LF admins again — the failure may have left
        # a fresh stale principal that wasn't there before.
        _lf_strip_dangling_admins "$_region"
        local _project_substack
        _project_substack="$(aws cloudformation describe-stack-resources \
            --stack-name "$_stack_name" --region "$_region" \
            --logical-resource-id ProjectStack --output json 2>/dev/null \
            | jq -r '.StackResources[0].PhysicalResourceId' 2>/dev/null || true)"
        if [ -n "$_project_substack" ] && [ "$_project_substack" != "null" ]; then
            aws cloudformation delete-stack \
                --stack-name "$_project_substack" \
                --retain-resources rAddDataLakeAdministratorToLakeFormation \
                --region "$_region" >/dev/null 2>&1 || true
            local _ps_max_polls=40
            local _ps_status _pj=0
            while [ "$_pj" -lt "$_ps_max_polls" ]; do
                _ps_status="$(aws cloudformation describe-stacks \
                    --stack-name "$_project_substack" \
                    --region "$_region" --query 'Stacks[0].StackStatus' \
                    --output text 2>/dev/null || echo "GONE")"
                case "$_ps_status" in
                    GONE|DELETE_COMPLETE) break ;;
                    DELETE_FAILED) break ;;
                esac
                _pj=$((_pj + 1))
                sleep 30
            done
            echo "    + project sub-stack ended in ${_ps_status}"
        fi
    fi

    # ---- F. Second parent delete attempt. ------------------------------
    # Re-strip dangling LF admins. The first delete-stack attempt
    # almost always deletes the project user role part-way through,
    # leaving a NEW dangling principal that wasn't there during
    # Section C's pass. Without this, the LF DataLakeSettings delete
    # in the project sub-stack fails on the next attempt with
    # `Invalid principal`.
    _lf_strip_dangling_admins "$_region"

    aws cloudformation delete-stack --stack-name "$_stack_name" \
        --region "$_region" >/dev/null 2>&1
    echo "    + second delete-stack issued for ${_stack_name}; waiting (up to 30 min)"
    if aws cloudformation wait stack-delete-complete \
            --stack-name "$_stack_name" --region "$_region" >/dev/null 2>&1; then
        echo "    + ${_stack_name} deleted on second attempt"
        _final_cleanup
        return 0
    fi

    if ! aws cloudformation describe-stacks --stack-name "$_stack_name" \
            --region "$_region" >/dev/null 2>&1; then
        echo "    + ${_stack_name} deleted"
        _final_cleanup
        return 0
    fi

    local _final_status
    _final_status="$(aws cloudformation describe-stacks --stack-name "$_stack_name" \
        --region "$_region" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "?")"
    echo "    WARN: ${_stack_name} ended in ${_final_status}; check AWS console for failed resources"
    return 1
}



# =============================================================================
# Actions.
# =============================================================================

# -----------------------------------------------------------------------------
# Action: setup
#
# Drives the full SMUS bootstrap end-to-end:
#
#   1. Prompt for IDC group names + persist to setup config.
#   2. IDC bootstrap (groups, default seed users, memberships).
#   3. IAM bootstrap (DataZone roles trusted by datazone.amazonaws.com).
#   4. CFN bootstrap (master + 5 child stacks; persist domain + project IDs).
#   5. Lake Formation bootstrap (revoke IAMAllowedPrincipals, grant DESCRIBE/SELECT).
#   6. SMUS session bootstrap (FGAC settings, KMS, WithFederation, IAM inlines).
#   7. CodeCommit Git-ops grant on the project user role.
#
# On success, marks state as `complete` so `migrate.sh run` is unblocked.
# On any helper exit, marks state as `failed`. Re-running is idempotent —
# every helper does a get-then-mutate.
# -----------------------------------------------------------------------------

_action_setup() {
    _print_banner "smus-setup"
    echo "==> Config:   $(_smus_setup_config_path)"
    echo "==> State:    $(_smus_setup_state_path)"
    echo

    _confirm_apply
    _aws_required || exit $?
    _jq_required  || exit $?

    # Auto-wipe stale stack-derived values when the operator passed
    # a different `--stack-name` than the one persisted from the last
    # deploy. Without this, the resolver chain's config tier wins for
    # `domain_name`, `admin_project_name`, etc. — silently producing
    # a deployment under one stack name with the previous stack's
    # domain. See "Three targeted fixes" in the README operator notes.
    _setup_auto_wipe_on_stack_change

    if [ "$MODE_FLAG" = "--apply" ]; then
        _smus_setup_state_mark in_progress
    fi

    # CLI overrides for the three IDC groups feed the existing
    # MT_*_GROUP_NAME env vars that `_prompt_idc_groups` already reads.
    # If the operator passed --admin-group / --de-group / --consumer-group,
    # the prompt for that group is skipped and the supplied name is used
    # (still subject to the existence check inside _prompt_idc_groups).
    if [ -n "$CLI_ADMIN_GROUP" ];    then export MT_ADMIN_GROUP_NAME="$CLI_ADMIN_GROUP";    fi
    if [ -n "$CLI_DE_GROUP" ];       then export MT_DE_GROUP_NAME="$CLI_DE_GROUP";          fi
    if [ -n "$CLI_CONSUMER_GROUP" ]; then export MT_CONSUMER_GROUP_NAME="$CLI_CONSUMER_GROUP"; fi

    # `--sso-instance-arn` likewise feeds the env var that
    # `_idc_bootstrap` and `_cfn_bootstrap` already read.
    if [ -n "$CLI_SSO_INSTANCE_ARN" ]; then
        export MT_IDENTITY_CENTER_INSTANCE_ARN="$CLI_SSO_INSTANCE_ARN"
    fi

    # Helpers below are no-ops on dry-run (they print their own "skipped"
    # banners). Default flow:
    #   1. IDC group prompt + IDC bootstrap (groups, users, memberships)
    #   2. IAM bootstrap (just the LF dangling-admin pre-flight + orphan purge)
    #   3. CFN bootstrap (deploys the master stack; the in-stack rPostDeploy
    #      Lambda runs LF grants, KMS policy, IAM inlines, WithFederation
    #      re-registration, and the CodeCommit grant — see cfn/lambda/handler/)
    #
    # The bash helpers `_lakeformation_bootstrap`, `_smus_session_bootstrap`,
    # and `_smus_codecommit_grant` remain in this file as a documented
    # alternative — set `SMUS_USE_BASH_HELPERS=1` to fall back to the
    # legacy CLI-only path. Useful as an escape hatch and as the
    # "read the script to learn the patterns" reference.
    _prompt_idc_groups
    _idc_bootstrap
    _iam_bootstrap
    _cfn_bootstrap
    if [ "${SMUS_USE_BASH_HELPERS:-0}" = "1" ]; then
        echo "==> SMUS_USE_BASH_HELPERS=1 — running legacy bash post-deploy helpers"
        _lakeformation_bootstrap
        _smus_session_bootstrap
        _smus_codecommit_grant
    fi

    if [ "$MODE_FLAG" = "--apply" ]; then
        _smus_setup_state_mark complete
    fi

    echo
    echo "==> smus-setup complete"
    if [ "$MODE_FLAG" != "--apply" ]; then
        echo "==> dry-run only; re-run with --apply to perform the operations above"
    else
        echo "==> next: ./migrate.sh run --apply"
    fi
}

# -----------------------------------------------------------------------------
# Action: status
#
# Print the current setup state file in a human-readable form.
# -----------------------------------------------------------------------------

_action_status() {
    local _state_path
    _state_path="$(_smus_setup_state_path)"
    local _config_path
    _config_path="$(_smus_setup_config_path)"

    if [ ! -f "$_state_path" ]; then
        echo "No SMUS setup state at ${_state_path} — run \`./smus-setup.sh setup --apply\`."
        exit 0
    fi
    if command -v jq >/dev/null 2>&1; then
        echo "SMUS setup state (${_state_path}):"
        jq -r '
            "  status:           \(.status // "?")",
            "  last_updated_utc: \(.last_updated_utc // "—")"
        ' "$_state_path"
        if [ -f "$_config_path" ]; then
            echo
            echo "SMUS setup config (${_config_path}):"
            jq -r 'to_entries | map("  \(.key): \(.value)") | .[]' "$_config_path"
        fi
    else
        cat "$_state_path"
        [ -f "$_config_path" ] && { echo; cat "$_config_path"; }
    fi
}

# -----------------------------------------------------------------------------
# Action: teardown
#
# Inverse of `setup`. Walks the same discovery logic as the migrate-side
# teardown helper (and reuses `_teardown_destroy_smus_stack` verbatim) so
# the SMUS CFN stack and the dynamic IAM inlines/KMS policy/LF
# registration role we added on top of it all come down together.
#
# Skipped sections honour:
#   --keep-cfn        keep the CFN stack
#   --keep-iam-roles  keep the project-role inlines + LF registration role
#
# Confirmation: requires the user to type `teardown` unless --yes.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# _action_teardown_via_lambda
#
# Default teardown path — delegates the 9 hardening passes to the
# `rPreDelete` Custom Resource Lambda inside the stack. The operator
# only needs to run `aws cloudformation delete-stack` and wait.
#
# CFN deletes resources in reverse-dependency order. `rPreDelete` has
# no DependsOn, so it's deleted FIRST. CFN invokes the Lambda with
# RequestType=Delete; the Lambda does:
#
#   - Strip the AllowProjectUserRoleForSparkLogs KMS statement
#   - Detach the IAM inline policies on the dynamic project user role
#   - Drain orphan VPC endpoints + ENIs + cross-SG ingress
#   - Drive each DataZone environment to GONE
#   - Drop orphaned glue_db_*
#   - Force-delete the project with --skip-deletion-check
#   - Strip dangling LF admins
#   - Drain + delete the tooling bucket
#
# Then signals SUCCESS to CFN, which proceeds to delete the rest of
# the stack (now unblocked).
#
# Failure mode: if the Lambda hits an error and signals FAILED, the
# stack goes to DELETE_FAILED. The operator falls back to the legacy
# bash hardening passes by re-running with `SMUS_USE_BASH_HELPERS=1`.
# -----------------------------------------------------------------------------

_action_teardown_via_lambda() {
    if [ "$MODE_FLAG" = "--apply" ] && [ "$ASSUME_YES" -ne 1 ]; then
        if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
            echo "ERROR: teardown --apply requires a TTY for confirmation; pass --yes for non-interactive use" >&2
            exit 64
        fi
        local _stack_name_for_prompt
        _stack_name_for_prompt="$(_resolve_stack_name)"
        {
            echo "WARNING: teardown will issue 'aws cloudformation delete-stack ${_stack_name_for_prompt}'."
            echo "         The in-stack rPreDelete Lambda runs the 9 hardening passes,"
            echo "         then CFN deletes the rest of the stack."
            printf "Type 'teardown' to confirm: "
        } >/dev/tty
        local typed=""
        IFS= read -r typed </dev/tty || typed=""
        if [ "$typed" != "teardown" ]; then
            echo "ABORTED: confirmation mismatch; nothing changed." >/dev/tty
            exit 1
        fi
    fi

    _aws_required || exit $?
    _jq_required  || exit $?

    local _region="${AWS_DEFAULT_REGION:-us-east-1}"
    local _stack_name
    _stack_name="$(_resolve_stack_name)"
    local _apply=0
    [ "$MODE_FLAG" = "--apply" ] && _apply=1

    if ! aws cloudformation describe-stacks --stack-name "$_stack_name" \
            --region "$_region" >/dev/null 2>&1; then
        echo "==> teardown: stack ${_stack_name} not found — nothing to delete"
        _action_teardown_wipe_local_state "$_apply"
        return 0
    fi

    if [ "$_apply" -eq 0 ]; then
        echo "==> teardown 1/2: DRY-RUN — would issue 'aws cloudformation delete-stack ${_stack_name}'"
        echo "==> teardown 2/2: DRY-RUN — would wipe local config + state"
        return 0
    fi

    echo "==> teardown 1/2: issuing 'aws cloudformation delete-stack ${_stack_name}'"
    aws cloudformation delete-stack --stack-name "$_stack_name" --region "$_region"

    echo "    waiting for stack-delete-complete (rPreDelete Lambda runs 9 hardening passes,"
    echo "    then CFN proceeds with the rest of the stack delete; ETA ~10-15 min)"
    if aws cloudformation wait stack-delete-complete \
            --stack-name "$_stack_name" --region "$_region" 2>&1; then
        echo "    + ${_stack_name} deleted"
    else
        # Show the most recent failed event so the operator knows where to look.
        echo "    WARN: stack-delete-complete wait failed; recent events:"
        aws cloudformation describe-stack-events --stack-name "$_stack_name" \
            --region "$_region" --max-items 10 \
            --query 'StackEvents[?ResourceStatus==`DELETE_FAILED`].[LogicalResourceId,ResourceStatusReason]' \
            --output text 2>&1 | head -20
        echo
        echo "    HINT: check Lambda logs:  aws logs tail /aws/lambda/<rSetupHandler-physical-id> --since 30m"
        echo "    HINT: fall back to bash:  SMUS_USE_BASH_HELPERS=1 ./smus-setup.sh teardown --apply --yes"
        return 1
    fi

    _action_teardown_wipe_local_state "$_apply"
}

_action_teardown_wipe_local_state() {
    local _apply="$1"
    echo "==> teardown 2/2: wiping setup state and config"
    local _state_path _config_path
    _state_path="$(_smus_setup_state_path)"
    _config_path="$(_smus_setup_config_path)"
    if [ "$_apply" -eq 1 ]; then
        for _f in "$_state_path" "$_config_path"; do
            if [ -f "$_f" ]; then
                local _backup="${_f}.bak.$(date +%s)"
                cp "$_f" "$_backup"
                rm -f "$_f"
                echo "    + wiped ${_f}; backup at ${_backup}"
            fi
        done
    fi
    echo
    echo "==> smus-setup teardown complete"
}


_action_teardown() {
    _print_banner "smus-setup teardown"
    if [ "$TEARDOWN_KEEP_CFN" -eq 1 ]; then
        echo "==> Keep:     CFN stack"
    fi
    if [ "$TEARDOWN_KEEP_IAM" -eq 1 ]; then
        echo "==> Keep:     IAM project-role inline policies"
    fi
    echo

    # Default flow: delegate to the in-stack `rPreDelete` Lambda.
    # The operator only needs to run `aws cloudformation delete-stack`;
    # everything else (hardening passes, state cleanup) is handled
    # inside the stack and by `_action_teardown_via_lambda`.
    #
    # Operators fall back to the legacy bash hardening passes by setting
    # SMUS_USE_BASH_HELPERS=1 (escape hatch if Lambda has a bug or the
    # rPreDelete resource was somehow corrupted) or by passing --keep-cfn
    # (which keeps the CFN stack — incompatible with the Lambda flow).
    if [ "${SMUS_USE_BASH_HELPERS:-0}" != "1" ] && [ "$TEARDOWN_KEEP_CFN" -ne 1 ]; then
        _action_teardown_via_lambda
        return $?
    fi
    echo "==> teardown via legacy bash helpers (SMUS_USE_BASH_HELPERS=1 or --keep-cfn)"

    if [ "$MODE_FLAG" = "--apply" ] && [ "$ASSUME_YES" -ne 1 ]; then
        if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
            echo "ERROR: teardown --apply requires a TTY for confirmation; pass --yes for non-interactive use" >&2
            exit 64
        fi
        {
            echo "WARNING: teardown will revoke LF grants we added, remove the KMS"
            echo "         policy statement, detach IAM inline policies, and (unless"
            echo "         --keep-cfn) DELETE the SMUS CFN stack."
            printf "Type 'teardown' to confirm: "
        } >/dev/tty
        local typed=""
        IFS= read -r typed </dev/tty || typed=""
        if [ "$typed" != "teardown" ]; then
            echo "ABORTED: confirmation mismatch; nothing changed." >/dev/tty
            exit 1
        fi
    fi

    _aws_required || exit $?
    _jq_required  || exit $?

    local _region="${AWS_DEFAULT_REGION:-us-east-1}"
    local _domain_id _project_id
    _domain_id="$(aws datazone list-domains --region "$_region" \
        --query "items[?name=='smus-seed-domain'] | [0].id" --output text 2>/dev/null \
        | grep -v '^None$' || true)"
    if [ -z "$_domain_id" ]; then
        echo "==> teardown: domain 'smus-seed-domain' not found — nothing to do at the SMUS layer"
    else
        _project_id="$(aws datazone list-projects --domain-identifier "$_domain_id" --region "$_region" \
            --query "items[?name=='smus-admin'] | [0].id" --output text 2>/dev/null \
            | grep -v '^None$' || true)"
    fi

    local _apply=0
    [ "$MODE_FLAG" = "--apply" ] && _apply=1

    # Discover the project user role for steps 1-2 (KMS / IAM inlines).
    local _project_user_role=""
    if [ -n "$_project_id" ]; then
        local _tooling_env_id
        _tooling_env_id="$(aws datazone list-environments \
            --domain-identifier "$_domain_id" \
            --project-identifier "$_project_id" \
            --region "$_region" --output json 2>/dev/null \
            | jq -r '.items[]? | select(.name == "Tooling") | .id' | head -n 1)"
        if [ -n "$_tooling_env_id" ]; then
            _project_user_role="$(aws datazone get-environment \
                --domain-identifier "$_domain_id" \
                --identifier "$_tooling_env_id" \
                --region "$_region" \
                --query 'provisionedResources[?name==`userRoleArn`].value | [0]' \
                --output text 2>/dev/null | grep -v '^None$' || true)"
        fi
    fi

    # ---- 1. Remove the KMS key policy statement we added. ----
    echo "==> teardown 1/4: removing AllowProjectUserRoleForSparkLogs from tooling KMS key"
    local _account
    _account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")"
    if [ -n "$_account" ]; then
        local _bucket
        _bucket="$(_resolve_tooling_bucket "$_account" "$_region")"
        if aws s3api head-bucket --bucket "$_bucket" >/dev/null 2>&1; then
            local _kms_key_id
            _kms_key_id="$(aws s3api get-bucket-encryption --bucket "$_bucket" \
                --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.KMSMasterKeyID' \
                --output text 2>/dev/null | grep -v '^None$' || true)"
            local _kms_key_short="${_kms_key_id##*/}"
            if [ -n "$_kms_key_short" ]; then
                local _key_manager
                _key_manager="$(aws kms describe-key --key-id "$_kms_key_short" \
                    --query 'KeyMetadata.KeyManager' --output text 2>/dev/null || echo "AWS")"
                if [ "$_key_manager" = "CUSTOMER" ]; then
                    local _policy_now
                    _policy_now="$(aws kms get-key-policy --key-id "$_kms_key_short" \
                        --policy-name default --query 'Policy' --output text 2>/dev/null || echo "")"
                    if [ -n "$_policy_now" ]; then
                        local _has_stmt
                        _has_stmt="$(printf '%s' "$_policy_now" | jq \
                            '[.Statement[]? | select(.Sid == "AllowProjectUserRoleForSparkLogs")] | length' 2>/dev/null || echo "0")"
                        if [ "$_has_stmt" != "0" ]; then
                            local _policy_new
                            _policy_new="$(printf '%s' "$_policy_now" | jq \
                                '.Statement |= map(select(.Sid != "AllowProjectUserRoleForSparkLogs"))')"
                            if [ "$_apply" -eq 1 ]; then
                                if aws kms put-key-policy --key-id "$_kms_key_short" \
                                        --policy-name default --policy "$_policy_new" >/dev/null 2>&1; then
                                    echo "    + removed AllowProjectUserRoleForSparkLogs statement from KMS key policy"
                                fi
                            else
                                echo "    DRY-RUN: would remove AllowProjectUserRoleForSparkLogs from KMS key policy"
                            fi
                        else
                            echo "    = AllowProjectUserRoleForSparkLogs not present; nothing to remove"
                        fi
                    fi
                fi
            fi
        fi
    fi

    # ---- 2. Detach IAM inline policies the setup added. ----
    if [ "$TEARDOWN_KEEP_IAM" -eq 1 ]; then
        echo "==> teardown 2/4: skipped (--keep-iam-roles)"
    elif [ -n "$_project_user_role" ]; then
        echo "==> teardown 2/4: detaching IAM inline policies from project user role"
        local _role_name="${_project_user_role##*/}"
        local _pol
        for _pol in GlueSparkLogsAccess GlueDataBucketAccess GlueConnectionAccess CodeCommitAccess LakeFormationFGACAccess GlueCatalogReadAccess; do
            if [ "$_apply" -eq 1 ]; then
                if aws iam delete-role-policy --role-name "$_role_name" \
                        --policy-name "$_pol" >/dev/null 2>&1; then
                    echo "    + deleted inline policy ${_pol}"
                else
                    echo "    = inline policy ${_pol} not present"
                fi
            else
                echo "    DRY-RUN: would delete inline policy ${_pol}"
            fi
        done
    else
        echo "==> teardown 2/4: project user role not discovered; skipping IAM cleanup"
    fi

    # ---- 2b. LF registration role is owned by CFN now (sus-domain-stack.yaml). ----
    # Previously we created the role here in `_smus_session_bootstrap`
    # and had to delete it explicitly. Since the move to CFN, the
    # role is unwound by `delete-stack` along with the rest of the
    # domain sub-stack — no manual cleanup needed here.

    # ---- 3. Delete the SMUS CFN stack (with hardening passes). ----
    if [ "$TEARDOWN_KEEP_CFN" -eq 1 ]; then
        echo "==> teardown 3/4: skipped (--keep-cfn)"
    else
        echo "==> teardown 3/4: deleting SMUS CFN stack (with hardening passes)"
        _teardown_destroy_smus_stack \
            "$_apply" "$_region" "$_domain_id" "$_project_id"
    fi

    # ---- 4. Wipe setup state + config. ----
    echo "==> teardown 4/4: wiping setup state and config"
    local _state_path _config_path
    _state_path="$(_smus_setup_state_path)"
    _config_path="$(_smus_setup_config_path)"
    if [ "$_apply" -eq 1 ]; then
        for _f in "$_state_path" "$_config_path"; do
            if [ -f "$_f" ]; then
                local _backup="${_f}.bak.$(date +%s)"
                cp "$_f" "$_backup"
                rm -f "$_f"
                echo "    + wiped ${_f}; backup at ${_backup}"
            fi
        done
    else
        echo "    DRY-RUN: would wipe ${_state_path} and ${_config_path}"
    fi

    echo
    echo "==> smus-setup teardown complete"
    if [ "$_apply" -eq 0 ]; then
        echo "==> dry-run only; re-run with --apply to perform the operations above"
    fi
}

# =============================================================================
# Dispatch.
# =============================================================================
case "$ACTION" in
    setup)    _action_setup ;;
    status)   _action_status ;;
    teardown) _action_teardown ;;
    *) usage ;;
esac
