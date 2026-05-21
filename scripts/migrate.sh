#!/usr/bin/env bash
#
# migrate.sh — wrapper around the SageMaker Migration Tool.
#
# Runs the 9-step migration_tool against an SMUS environment. By default
# the script expects the environment to have been provisioned by
# `./scripts/smus-setup.sh setup --apply` and reads the post-setup IDs
# from `config/smus-setup.config.json`.
#
# Bring-your-own-domain (BYOD) mode supports running the migration
# against a SMUS domain provisioned by something else (the customer's
# own infra-as-code, an existing internal SMUS deployment, etc.).
# Pass `--bring-your-own` and either `--domain-name` + `--admin-project-name`
# (auto-discovery from AWS) or explicit IDs via `--smus-domain-id`,
# `--admin-project-id`, `--admin-project-profile-id`.
#
# Default mode is dry-run; pass --apply to perform state-changing
# operations. Mutually exclusive with --dry-run.
#
# Usage:
#   ./scripts/migrate.sh run      [MODE] [WHERE] [--yes] [BYOD flags] [migration-tool args...]
#   ./scripts/migrate.sh status
#   ./scripts/migrate.sh reset    [--yes]
#   ./scripts/migrate.sh teardown [MODE] [--yes]
#   ./scripts/migrate.sh -h | --help
#
# Action verbs:
#   run      — invoke `python -m migration_tool` with forwarded args
#   status   — pretty-print current run state from migration.state.json
#   reset    — clear migration state (asks for confirmation unless --yes)
#   teardown — reverse the migration-only side effects (subscriptions,
#              resource-link DESCRIBE grants) and wipe migration state.
#              Repo / connection cleanup is owned by the SMUS CFN stack —
#              run `./scripts/smus-setup.sh teardown` to remove it.
#
# MODE:                 --apply | --dry-run                 (default: dry-run)
# WHERE:                --profile NAME                      (or AWS_PROFILE env var)
#                       --region  NAME                      (or AWS_DEFAULT_REGION env var)
#                       --yes / -y                          Skip the apply-mode confirmation prompt.
#
# Bring-your-own-domain flags:
#   --bring-your-own                              Skip the smus-setup state gate; resolve IDs from AWS.
#   --domain-name NAME                            SMUS domain name to target (auto-discover ID).
#   --admin-project-name NAME                     Admin project name within the domain (auto-discover ID).
#   --smus-domain-id ID                           Explicit domain ID (skips auto-discovery).
#   --admin-project-id ID                         Explicit project ID.
#   --admin-project-profile-id ID                 Explicit project profile ID.
#
# Forwarded migration-tool flags (see `python -m migration_tool --help`):
#   --apply, --dry-run, --step, --from, --to, --force, --reset (for steps),
#   --reconfigure, --set <k=v>, --convert-dags, --push-cicd
#

set -uo pipefail
# Bash 3.2 + set -u + empty array `"${arr[@]}"` raises "unbound variable".
# Disable -u for the rest of the script; -o pipefail is preserved.
set +u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=_lib/common.sh
source "${ROOT_DIR}/_lib/common.sh"

ACTION=""
MODE_FLAG=""           # --apply or --dry-run; empty = let migration tool default to dry-run
PROFILE=""
REGION=""
ASSUME_YES=0
PASSTHROUGH=()         # everything we hand to `python -m migration_tool`

# Bring-your-own-domain mode. Lets `migrate.sh run` work against a
# pre-existing SMUS domain that was provisioned by something other than
# `./scripts/smus-setup.sh` (e.g. the customer's own infra-as-code).
# When --bring-your-own is set, the state-file gate is skipped and the
# script auto-discovers domain/project/profile IDs by name from AWS.
#
# Operators can also pass IDs directly (no AWS discovery) — useful in
# IAM-restricted environments where the runner can't list/get DataZone.
BRING_YOUR_OWN=0
CLI_DOMAIN_NAME=""
CLI_ADMIN_PROJECT_NAME=""
CLI_SMUS_DOMAIN_ID=""
CLI_ADMIN_PROJECT_ID=""
CLI_ADMIN_PROJECT_PROFILE_ID=""

usage() { sed -n '2,47p' "$0"; exit 64; }

# -----------------------------------------------------------------------------
# CLI parsing.
# -----------------------------------------------------------------------------

if [ $# -eq 0 ]; then
    usage
fi

# First positional is the action verb.
case "$1" in
    run|status|reset|teardown) ACTION="$1"; shift ;;
    -h|--help) usage ;;
    *)
        echo "ERROR: unknown action '$1' (valid: run, status, reset, teardown)" >&2
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
        # ---- Bring-your-own-domain flags (all optional). ----
        --bring-your-own)               BRING_YOUR_OWN=1; shift ;;
        --domain-name)                  CLI_DOMAIN_NAME="$2"; BRING_YOUR_OWN=1; shift 2 ;;
        --domain-name=*)                CLI_DOMAIN_NAME="${1#*=}"; BRING_YOUR_OWN=1; shift ;;
        --admin-project-name)           CLI_ADMIN_PROJECT_NAME="$2"; BRING_YOUR_OWN=1; shift 2 ;;
        --admin-project-name=*)         CLI_ADMIN_PROJECT_NAME="${1#*=}"; BRING_YOUR_OWN=1; shift ;;
        --smus-domain-id)               CLI_SMUS_DOMAIN_ID="$2"; BRING_YOUR_OWN=1; shift 2 ;;
        --smus-domain-id=*)             CLI_SMUS_DOMAIN_ID="${1#*=}"; BRING_YOUR_OWN=1; shift ;;
        --admin-project-id)             CLI_ADMIN_PROJECT_ID="$2"; BRING_YOUR_OWN=1; shift 2 ;;
        --admin-project-id=*)           CLI_ADMIN_PROJECT_ID="${1#*=}"; BRING_YOUR_OWN=1; shift ;;
        --admin-project-profile-id)     CLI_ADMIN_PROJECT_PROFILE_ID="$2"; BRING_YOUR_OWN=1; shift 2 ;;
        --admin-project-profile-id=*)   CLI_ADMIN_PROJECT_PROFILE_ID="${1#*=}"; BRING_YOUR_OWN=1; shift ;;
        --) shift; while [ $# -gt 0 ]; do PASSTHROUGH+=("$1"); shift; done ;;
        *)
            # Any other flag (including -h / --help) passes through to the
            # migration tool unchanged — the wrapper's own help is shown
            # only when invoked WITHOUT an action verb.
            PASSTHROUGH+=("$1")
            shift
            ;;
    esac
done

# Forward AWS env to the migration tool.
if [ -n "$PROFILE" ]; then export AWS_PROFILE="$PROFILE"; fi
if [ -n "$REGION" ];  then export AWS_DEFAULT_REGION="$REGION"; fi

CONFIG_PATH="$(_migration_config_path)"
STATE_PATH="$(_migration_state_path)"
LOG_DIR="${ROOT_DIR}/logs"
mkdir -p "$LOG_DIR"

# Resolve a python interpreter — uses helper from _lib/common.sh.
PY="$(_resolve_python)"
if [ -z "$PY" ]; then
    echo "ERROR: no python interpreter found (set MIGRATION_TOOL_PYTHON or install python3)" >&2
    exit 64
fi

# Make sure the venv's bin/ directory is on PATH so step subprocesses
# (notably Step 7's aws-smus-cicd-cli) can find venv-installed scripts
# without us needing to absolute-path them.
_PY_DIR="$(dirname "$PY")"
case ":${PATH}:" in
    *":${_PY_DIR}:"*) ;;  # already present
    *) export PATH="${_PY_DIR}:${PATH}" ;;
esac

# -----------------------------------------------------------------------------
# Action: status
# -----------------------------------------------------------------------------
_action_status() {
    if [ ! -f "$STATE_PATH" ]; then
        echo "No migration state at ${STATE_PATH} — nothing has been run yet."
        exit 0
    fi
    if command -v jq >/dev/null 2>&1; then
        echo "Migration state (${STATE_PATH}):"
        jq -r '
            "  schema_version: \(.schema_version // "?")",
            "  last_updated_utc: \(.last_updated_utc // "—")",
            "  steps:",
            (.steps // {} | to_entries[] |
                "    \(.key | tostring | (. + "                              " | .[0:30]))  status=\(.value.status // "?")  attempts=\(.value.attempts // 0)")
        ' "$STATE_PATH"
    else
        cat "$STATE_PATH"
    fi
}

# -----------------------------------------------------------------------------
# Action: reset
# -----------------------------------------------------------------------------
_action_reset() {
    if [ ! -f "$STATE_PATH" ]; then
        echo "No migration state to reset (${STATE_PATH} does not exist)."
        exit 0
    fi
    if [ "$ASSUME_YES" -ne 1 ]; then
        if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
            echo "ERROR: reset requires a TTY for confirmation; pass --yes for non-interactive use" >&2
            exit 64
        fi
        {
            echo "WARNING: about to wipe ${STATE_PATH}."
            printf "Type 'reset' to confirm: "
        } >/dev/tty
        typed=""
        IFS= read -r typed </dev/tty || typed=""
        if [ "$typed" != "reset" ]; then
            echo "ABORTED: confirmation mismatch; state unchanged." >/dev/tty
            exit 1
        fi
    fi
    backup="${STATE_PATH}.bak.$(date +%s)"
    cp "$STATE_PATH" "$backup"
    rm -f "$STATE_PATH"
    echo "Reset complete. Previous state saved to: ${backup}"
}

_repo_bootstrap() {
    if [ "$MODE_FLAG" != "--apply" ]; then
        echo "==> Repo bootstrap: skipped (not in --apply mode)"
        return 0
    fi
    if ! command -v git >/dev/null 2>&1; then
        echo "==> Repo bootstrap: skipped (git not on PATH)"
        return 0
    fi

    if [ -d "${ROOT_DIR}/.git" ]; then
        echo "==> Repo bootstrap: ${ROOT_DIR}/.git already exists; leaving as-is"
        return 0
    fi

    # Resolve the clone URL. Priority:
    #   1. config/smus-setup.config.json `repo_url` (populated by
    #      `smus-setup.sh` from the CFN stack outputs).
    #   2. CodeCommit get-repository (legacy / BYOD path).
    # For 3P providers there's no in-account clone URL we can derive
    # — the repo lives on the customer's GitHub/GitLab/Bitbucket
    # tenant — so we politely skip the local-tree wiring.
    local _setup_cfg="${ROOT_DIR}/config/smus-setup.config.json"
    local _repo_provider _repo_provider_lc _clone_url
    _repo_provider=""
    _repo_provider_lc=""
    _clone_url=""
    if [ -f "$_setup_cfg" ] && command -v jq >/dev/null 2>&1; then
        _repo_provider="$(jq -r '.repo_provider // empty' "$_setup_cfg" 2>/dev/null)"
        _clone_url="$(jq -r '.repo_url // empty' "$_setup_cfg" 2>/dev/null)"
    fi
    _repo_provider_lc="$(printf '%s' "$_repo_provider" | tr '[:upper:]' '[:lower:]')"
    if [ -z "$_clone_url" ] && { [ -z "$_repo_provider_lc" ] || [ "$_repo_provider_lc" = "codecommit" ]; }; then
        # Legacy fallback: discover the CodeCommit clone URL via aws-cli.
        local _repo_name="${MT_REPO_NAME:-smus-seed-domain-migration}"
        local _region="${AWS_DEFAULT_REGION:-us-east-1}"
        _clone_url="$(aws codecommit get-repository --repository-name "$_repo_name" \
            --region "$_region" --query 'repositoryMetadata.cloneUrlHttp' --output text 2>/dev/null \
            | grep -v '^None$' || true)"
    fi
    if [ -z "$_clone_url" ]; then
        if [ -n "$_repo_provider_lc" ] && [ "$_repo_provider_lc" != "codecommit" ]; then
            echo "==> Repo bootstrap: SKIP — provider=${_repo_provider} (out-of-account); operator wires the local tree manually"
        else
            echo "==> Repo bootstrap: WARN — no clone URL discovered; Step 6 will fall back to dry-run lines"
        fi
        return 0
    fi

    echo "==> Repo bootstrap: initializing ${ROOT_DIR} as a working tree of ${_clone_url}"
    ( cd "$ROOT_DIR" && git init -q ) || {
        echo "    WARN: git init failed; skipping repo bootstrap"
        return 0
    }

    if [ -z "$_repo_provider_lc" ] || [ "$_repo_provider_lc" = "codecommit" ]; then
        # Use AWS-CLI's CodeCommit credential helper for a passwordless
        # HTTPS push (the credential helper just uses the active AWS
        # profile/role).
        ( cd "$ROOT_DIR" \
            && git config --local credential.helper '!aws codecommit credential-helper $@' \
            && git config --local credential.UseHttpPath true ) || true
    fi

    # Set user identity if missing — git refuses to commit without one.
    if [ -z "$(cd "$ROOT_DIR" && git config user.email 2>/dev/null)" ]; then
        ( cd "$ROOT_DIR" && git config --local user.email "migration-tool@example.com" ) || true
    fi
    if [ -z "$(cd "$ROOT_DIR" && git config user.name 2>/dev/null)" ]; then
        ( cd "$ROOT_DIR" && git config --local user.name "Migration Tool" ) || true
    fi

    # Configure the remote.
    if ( cd "$ROOT_DIR" && git remote get-url origin >/dev/null 2>&1 ); then
        ( cd "$ROOT_DIR" && git remote set-url origin "$_clone_url" ) || true
    else
        ( cd "$ROOT_DIR" && git remote add origin "$_clone_url" ) || true
    fi

    # Fetch (tolerate empty remote — CodeCommit returns 0 with no refs).
    ( cd "$ROOT_DIR" && git fetch origin --quiet 2>/dev/null ) || true

    # Initialise main branch — empty CodeCommit repo has no refs to
    # check out, so we create main locally.
    if ! ( cd "$ROOT_DIR" && git rev-parse --verify main >/dev/null 2>&1 ); then
        ( cd "$ROOT_DIR" && git checkout -q -b main ) || true
    fi

    echo "==> Repo bootstrap: ready (remote=origin → ${_clone_url})"
}

# -----------------------------------------------------------------------------
# CICD-CLI bootstrap.
#
# Step 7 of the migration tool deploys the extracted DAGs to the
# admin project's MWAA environment via the `aws-smus-cicd` CLI
# (`pip install aws-smus-cicd-cli`). When the CLI isn't installed,
# Step 7 falls back to a warning log and the DAGs never get deployed.
#
# This helper installs the CLI into the active python interpreter
# (preferring the project venv) when missing, idempotent on re-runs.
# -----------------------------------------------------------------------------

_cicd_cli_bootstrap() {
    if [ "$MODE_FLAG" != "--apply" ]; then
        echo "==> aws-smus-cicd bootstrap: skipped (not in --apply mode)"
        return 0
    fi

    if "$PY" -c 'import importlib.util,sys; sys.exit(0 if importlib.util.find_spec("smus_cicd") else 1)' 2>/dev/null \
        || command -v aws-smus-cicd-cli >/dev/null 2>&1; then
        echo "==> aws-smus-cicd bootstrap: CLI already installed"
        return 0
    fi

    echo "==> aws-smus-cicd bootstrap: installing aws-smus-cicd-cli into ${PY}"
    if "$PY" -m pip install --quiet aws-smus-cicd-cli >/dev/null 2>&1; then
        echo "    + installed"
    else
        echo "    WARN: pip install aws-smus-cicd-cli failed; Step 7 may skip deploy"
    fi
}



_smus_subscribe_assets() {
    if [ "$MODE_FLAG" != "--apply" ]; then
        echo "==> SMUS auto-subscribe: skipped (not in --apply mode)"
        return 0
    fi
    if [ "${MT_SKIP_AUTO_SUBSCRIBE:-0}" = "1" ]; then
        echo "==> SMUS auto-subscribe: skipped (MT_SKIP_AUTO_SUBSCRIBE=1)"
        return 0
    fi
    if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        echo "==> SMUS auto-subscribe: skipped (aws/jq missing)"
        return 0
    fi

    local _domain_id="${MT_SMUS_DOMAIN_ID:-}"
    local _project_id="${MT_ADMIN_PROJECT_ID:-}"
    if [ -z "$_domain_id" ] || [ -z "$_project_id" ]; then
        echo "==> SMUS auto-subscribe: skipped (domain/project ID not set yet)"
        return 0
    fi

    local _region="${AWS_DEFAULT_REGION:-us-east-1}"

    # Find every active listing owned by the admin project. Limit to
    # GlueTableAssetType — this helper is scoped to the cannot-be-
    # queried-with-tools symptom that only applies to Glue assets.
    local _listings_json
    _listings_json="$(aws datazone search --domain-identifier "$_domain_id" \
        --search-scope ASSET --owning-project-identifier "$_project_id" \
        --region "$_region" --output json 2>/dev/null || echo '{}')"
    local _listing_ids
    _listing_ids="$(printf '%s' "$_listings_json" | jq -r \
        '.items[]? | .assetItem | select(.typeIdentifier == "amazon.datazone.GlueTableAssetType") | .identifier')"
    if [ -z "$_listing_ids" ]; then
        echo "==> SMUS auto-subscribe: no Glue table assets owned by admin project"
        return 0
    fi

    # Listings have a separate ID from the asset. Look them up via
    # search-listings (filter by name match, then keep the listing id).
    local _asset_id _listing_id _existing
    while IFS= read -r _asset_id; do
        [ -z "$_asset_id" ] && continue
        _listing_id="$(aws datazone get-asset --domain-identifier "$_domain_id" \
            --identifier "$_asset_id" --region "$_region" --output json 2>/dev/null \
            | jq -r '.listing.listingId // empty')"
        [ -z "$_listing_id" ] && continue

        # Skip if there's already an APPROVED/PENDING subscription for
        # this listing + project pair.
        _existing="$(aws datazone list-subscriptions \
            --domain-identifier "$_domain_id" \
            --subscribed-listing-id "$_listing_id" \
            --region "$_region" --output json 2>/dev/null \
            | jq -r --arg p "$_project_id" \
                '[.items[]? | select(.subscribedPrincipal.project.id == $p) | select(.status == "APPROVED" or .status == "REVOKED" | not)] | length' \
            2>/dev/null || echo "0")"
        if [ "${_existing:-0}" != "0" ]; then
            echo "    = listing ${_listing_id} already subscribed by admin project"
            continue
        fi

        if aws datazone create-subscription-request \
                --domain-identifier "$_domain_id" \
                --request-reason "auto-subscribe by migration tool" \
                --subscribed-listings "identifier=${_listing_id}" \
                --subscribed-principals "project={identifier=${_project_id}}" \
                --region "$_region" --output json >/dev/null 2>&1; then
            echo "    + subscribed admin project to listing ${_listing_id}"
        else
            echo "    WARN: create-subscription-request failed for listing ${_listing_id}"
        fi
    done <<<"$_listing_ids"

    echo "==> SMUS auto-subscribe: complete"
}

# -----------------------------------------------------------------------------
# _smus_grant_resource_link_describe
#
# Grant LF `DESCRIBE` on every Glue resource link in the project's
# managed Glue DB (`glue_db_<env_id>`) to the project user role.
#
# Why this matters:
# When SMUS approves a subscription, it provisions a Glue resource
# link in the project's managed DB pointing at the source table — and
# grants the project's perms on the source table. It does NOT,
# however, grant DESCRIBE on the resource link itself.
#
# Spark's catalog client resolves `glue_db_<env_id>.<table>` by first
# calling `glue:GetTable` against the link. Without `DESCRIBE` on the
# link, that call returns ENTITY_NOT_FOUND from LF and Spark surfaces
# `[TABLE_OR_VIEW_NOT_FOUND]` to the user — even though every other
# perm in the chain (target-table SELECT/DESCRIBE, parent-DB
# DESCRIBE, S3 location) is correct.
#
# Skip rules:
#   * Skipped on dry-run.
#   * Skipped if domain/project IDs aren't set.
#   * Skipped if the Lakehouse Database environment isn't provisioned.
#
# Idempotency: every grant is a best-effort call; if the project role
# already has DESCRIBE on a link, LF returns success and the helper
# moves on.
# -----------------------------------------------------------------------------

_smus_grant_resource_link_describe() {
    if [ "$MODE_FLAG" != "--apply" ]; then
        echo "==> SMUS resource-link DESCRIBE: skipped (not in --apply mode)"
        return 0
    fi
    if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        echo "==> SMUS resource-link DESCRIBE: skipped (aws/jq missing)"
        return 0
    fi

    local _domain_id="${MT_SMUS_DOMAIN_ID:-}"
    local _project_id="${MT_ADMIN_PROJECT_ID:-}"
    if [ -z "$_domain_id" ] || [ -z "$_project_id" ]; then
        echo "==> SMUS resource-link DESCRIBE: skipped (domain/project ID not set yet)"
        return 0
    fi

    local _region="${AWS_DEFAULT_REGION:-us-east-1}"

    # Find the Lakehouse Database environment id; that env id is what
    # SMUS uses as the suffix on the project's managed Glue DB.
    local _lh_env_id _project_db
    _lh_env_id="$(aws datazone list-environments \
        --domain-identifier "$_domain_id" \
        --project-identifier "$_project_id" \
        --region "$_region" --output json 2>/dev/null \
        | jq -r '.items[]? | select(.name == "Lakehouse Database") | .id' \
        | head -n 1)"
    if [ -z "$_lh_env_id" ]; then
        echo "==> SMUS resource-link DESCRIBE: WARN — Lakehouse Database env not found; skipping"
        return 0
    fi
    _project_db="glue_db_${_lh_env_id}"

    # Discover the project user role for the grant principal. Same
    # path as `_smus_session_bootstrap` uses for the Tooling env.
    local _tooling_env_id _project_user_role
    _tooling_env_id="$(aws datazone list-environments \
        --domain-identifier "$_domain_id" \
        --project-identifier "$_project_id" \
        --region "$_region" --output json 2>/dev/null \
        | jq -r '.items[]? | select(.name == "Tooling") | .id' | head -n 1)"
    if [ -z "$_tooling_env_id" ]; then
        echo "==> SMUS resource-link DESCRIBE: WARN — Tooling env not found; skipping"
        return 0
    fi
    _project_user_role="$(aws datazone get-environment \
        --domain-identifier "$_domain_id" \
        --identifier "$_tooling_env_id" \
        --region "$_region" \
        --query 'provisionedResources[?name==`userRoleArn`].value | [0]' \
        --output text 2>/dev/null | grep -v '^None$' || true)"
    if [ -z "$_project_user_role" ]; then
        echo "==> SMUS resource-link DESCRIBE: WARN — userRoleArn not yet provisioned; skipping"
        return 0
    fi

    # Enumerate every table in the project DB. Resource links surface
    # as `EXTERNAL_TABLE` rows with a non-null `TargetTable` field; we
    # filter on the latter (a real external table without a target
    # would not be inside the project-managed DB anyway, so this
    # filter is belt-and-braces). Grant DESCRIBE on every match.
    local _links_json
    _links_json="$(aws glue get-tables --region "$_region" \
        --database-name "$_project_db" --output json 2>/dev/null \
        | jq -c '[.TableList[]? | select(.TargetTable != null) | .Name]' 2>/dev/null || echo '[]')"
    local _link_count
    _link_count="$(printf '%s' "$_links_json" | jq -r 'length')"
    if [ "${_link_count:-0}" = "0" ]; then
        echo "==> SMUS resource-link DESCRIBE: no resource links in ${_project_db} yet"
        return 0
    fi

    # First, ensure DESCRIBE on the parent project DB. Spark's catalog
    # client also calls `glue:GetDatabase` before walking tables.
    aws lakeformation grant-permissions --region "$_region" \
        --principal "DataLakePrincipalIdentifier=${_project_user_role}" \
        --resource "{\"Database\":{\"Name\":\"${_project_db}\"}}" \
        --permissions DESCRIBE >/dev/null 2>&1 || true

    local _link
    while IFS= read -r _link; do
        [ -z "$_link" ] && continue
        if aws lakeformation grant-permissions --region "$_region" \
                --principal "DataLakePrincipalIdentifier=${_project_user_role}" \
                --resource "{\"Table\":{\"DatabaseName\":\"${_project_db}\",\"Name\":\"${_link}\"}}" \
                --permissions DESCRIBE >/dev/null 2>&1; then
            echo "    + DESCRIBE on resource link ${_project_db}.${_link} → ${_project_user_role##*/}"
        fi
    done < <(printf '%s' "$_links_json" | jq -r '.[]')

    echo "==> SMUS resource-link DESCRIBE: complete (${_link_count} resource links)"
}



# -----------------------------------------------------------------------------
# Action: run
#
# Pre-flight: require `smus-setup.sh setup --apply` to have completed
# (state status == "complete"). Without that, the project user role,
# Lake Formation permissions, KMS key policy, and IAM inlines required
# by the migration tool's Step 4 / Step 7 don't exist yet.
#
# After the gate, runs the migration-only side helpers:
#   * `_repo_bootstrap`           — wire local working tree to CodeCommit
#   * `_cicd_cli_bootstrap`       — install aws-smus-cicd-cli for Step 7
#   * `_smus_subscribe_assets`    — auto-subscribe to seed Glue assets
#   * `_smus_grant_resource_link_describe` — DESCRIBE on resource links
# Then forwards to `python -m migration_tool` with the appropriate
# `--set <k>=<v>` flags injected from the SMUS setup config.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# _resolve_byod_or_die
#
# Resolve domain ID + admin project ID + admin project profile ID for
# bring-your-own-domain mode, then export them as MT_* env vars and
# persist to config/smus-setup.config.json so subsequent helpers and
# the migration tool's --set injection see them.
#
# Resolution order, highest priority first:
#
#   1. Explicit IDs passed via CLI (--smus-domain-id, --admin-project-id,
#      --admin-project-profile-id). No AWS calls.
#   2. Names passed via CLI (--domain-name, --admin-project-name) → look
#      up the IDs via `aws datazone list-domains` + `list-projects`.
#   3. Defaults (smus-seed-domain, smus-admin) → same lookup.
#
# Halts (exit 65) if anything can't be resolved.
# -----------------------------------------------------------------------------
_resolve_byod_or_die() {
    _aws_required || exit $?
    _jq_required  || exit $?

    local _region="${AWS_DEFAULT_REGION:-us-east-1}"
    local _domain_name="${CLI_DOMAIN_NAME:-smus-seed-domain}"
    local _project_name="${CLI_ADMIN_PROJECT_NAME:-smus-admin}"

    echo "==> Bring-your-own-domain mode"

    # ---- Resolve domain ID ----
    local _domain_id="$CLI_SMUS_DOMAIN_ID"
    if [ -z "$_domain_id" ]; then
        echo "    looking up domain by name: ${_domain_name}"
        _domain_id="$(aws datazone list-domains --region "$_region" \
            --query "items[?name=='${_domain_name}'] | [0].id" --output text 2>/dev/null \
            | grep -v '^None$' || true)"
        if [ -z "$_domain_id" ]; then
            echo "ERROR: SMUS domain '${_domain_name}' not found in region ${_region}" >&2
            echo "       Verify the domain exists, or pass --smus-domain-id ID directly." >&2
            exit 65
        fi
    fi
    echo "    + domain id:     ${_domain_id}"

    # ---- Resolve project ID ----
    local _project_id="$CLI_ADMIN_PROJECT_ID"
    if [ -z "$_project_id" ]; then
        echo "    looking up admin project by name: ${_project_name}"
        _project_id="$(aws datazone list-projects --domain-identifier "$_domain_id" --region "$_region" \
            --query "items[?name=='${_project_name}'] | [0].id" --output text 2>/dev/null \
            | grep -v '^None$' || true)"
        if [ -z "$_project_id" ]; then
            echo "ERROR: admin project '${_project_name}' not found in domain ${_domain_id}" >&2
            echo "       Verify the project exists, or pass --admin-project-id ID directly." >&2
            exit 65
        fi
    fi
    echo "    + project id:    ${_project_id}"

    # ---- Resolve project profile ID ----
    local _profile_id="$CLI_ADMIN_PROJECT_PROFILE_ID"
    if [ -z "$_profile_id" ]; then
        echo "    looking up project profile id from project metadata"
        _profile_id="$(aws datazone get-project --domain-identifier "$_domain_id" \
            --identifier "$_project_id" --region "$_region" \
            --query 'projectProfileId' --output text 2>/dev/null \
            | grep -v '^None$' || true)"
        if [ -z "$_profile_id" ]; then
            echo "ERROR: project profile id not on project ${_project_id} metadata" >&2
            echo "       Pass --admin-project-profile-id ID directly." >&2
            exit 65
        fi
    fi
    echo "    + profile id:    ${_profile_id}"

    # ---- Resolve domain service role + IDC instance arn from the domain ----
    local _service_role _sso_arn
    _service_role="$(aws datazone get-domain --identifier "$_domain_id" \
        --region "$_region" --query 'serviceRole' --output text 2>/dev/null \
        | grep -v '^None$' || true)"
    _sso_arn="$(aws datazone get-domain --identifier "$_domain_id" \
        --region "$_region" --query 'singleSignOn.idcInstanceArn' --output text 2>/dev/null \
        | grep -v '^None$' || true)"
    [ -n "$_service_role" ] && echo "    + service role: ${_service_role}"
    [ -n "$_sso_arn" ]      && echo "    + IDC instance: ${_sso_arn}"

    # Look up the identity store id from the IDC instance ARN.
    local _identity_store_id=""
    if [ -n "$_sso_arn" ]; then
        local _account
        _account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo '')"
        _identity_store_id="$(aws sso-admin list-instances --output json 2>/dev/null \
            | jq -r --arg arn "$_sso_arn" --arg acct "$_account" \
                '.Instances[]? | select(.OwnerAccountId == $acct) | select(.InstanceArn == $arn) | .IdentityStoreId' \
            | head -n 1)"
        [ -n "$_identity_store_id" ] && echo "    + identity store: ${_identity_store_id}"
    fi

    # Export for downstream bash helpers.
    export MT_SMUS_DOMAIN_ID="$_domain_id"
    export MT_ADMIN_PROJECT_ID="$_project_id"
    export MT_ADMIN_PROJECT_PROFILE_ID="$_profile_id"
    [ -n "$_service_role" ]      && export MT_DOMAIN_SERVICE_ROLE="$_service_role"
    [ -n "$_sso_arn" ]           && export MT_IDENTITY_CENTER_INSTANCE_ARN="$_sso_arn"
    [ -n "$_identity_store_id" ] && export MT_IDENTITY_CENTER_IDENTITY_STORE_ID="$_identity_store_id"

    # Persist into smus-setup.config.json so the existing --set injection
    # path (which reads from this config) picks them up. Mirrors what
    # smus-setup's `_cfn_bootstrap` does at deploy time, just with values
    # discovered from AWS instead of CFN outputs.
    _smus_setup_config_set smus_domain_id              "$_domain_id"
    _smus_setup_config_set admin_project_id            "$_project_id"
    _smus_setup_config_set admin_project_profile_id    "$_profile_id"
    [ -n "$_service_role" ]      && _smus_setup_config_set domain_service_role "$_service_role"
    [ -n "$_sso_arn" ]           && _smus_setup_config_set identity_center_instance_arn "$_sso_arn"
    [ -n "$_identity_store_id" ] && _smus_setup_config_set identity_center_identity_store_id "$_identity_store_id"

    echo "==> BYOD: persisted IDs to $(_smus_setup_config_path)"
}


_action_run() {
    echo "==> migration tool"
    echo "==> Action:   run"
    if [ -n "$MODE_FLAG" ]; then
        echo "==> Mode:     ${MODE_FLAG}"
    else
        echo "==> Mode:     (default — dry-run)"
    fi
    echo "==> Profile:  ${AWS_PROFILE:-<unset>}"
    echo "==> Region:   ${AWS_DEFAULT_REGION:-<unset>}"
    echo "==> Python:   ${PY}"
    echo "==> Config:   ${CONFIG_PATH}"
    echo "==> State:    ${STATE_PATH}"
    if [ "${#PASSTHROUGH[@]}" -gt 0 ]; then
        echo "==> Passing:  ${PASSTHROUGH[*]}"
    fi
    echo

    # Gate: in default mode require smus-setup completed; in BYOD
    # mode resolve the domain/project/profile IDs from AWS or from
    # the operator-supplied flags.
    if [ "$BRING_YOUR_OWN" -eq 1 ]; then
        _resolve_byod_or_die
        _confirm_apply
    else
        local _setup_status
        _setup_status="$(_smus_setup_state_status)"
        if [ "$_setup_status" != "complete" ]; then
            echo "ERROR: SMUS setup is not complete (state status = '${_setup_status:-<missing>}')." >&2
            echo "       Either run \`./scripts/smus-setup.sh setup --apply\` first," >&2
            echo "       OR pass --bring-your-own with --domain-name + --admin-project-name" >&2
            echo "       to target an existing SMUS domain provisioned outside this toolkit." >&2
            exit 65
        fi
        _confirm_apply

        # Hydrate MT_* env vars from the smus-setup config so the bash
        # helpers below (auto-subscribe, resource-link DESCRIBE) and
        # the migration tool's --set injection both see the same values.
        if [ -z "${MT_SMUS_DOMAIN_ID:-}" ]; then
            local _v
            _v="$(_smus_setup_config_get smus_domain_id)"
            [ -n "$_v" ] && export MT_SMUS_DOMAIN_ID="$_v"
        fi
        if [ -z "${MT_ADMIN_PROJECT_ID:-}" ]; then
            local _v
            _v="$(_smus_setup_config_get admin_project_id)"
            [ -n "$_v" ] && export MT_ADMIN_PROJECT_ID="$_v"
        fi
        if [ -z "${MT_ADMIN_PROJECT_PROFILE_ID:-}" ]; then
            local _v
            _v="$(_smus_setup_config_get admin_project_profile_id)"
            [ -n "$_v" ] && export MT_ADMIN_PROJECT_PROFILE_ID="$_v"
        fi
    fi

    _repo_bootstrap
    _cicd_cli_bootstrap
    _smus_subscribe_assets
    _smus_grant_resource_link_describe

    log_path="${LOG_DIR}/migrate-$(date +%Y%m%d-%H%M%S).log"

    # Build the final argv for the migration tool. MODE_FLAG goes first
    # so it's visible at the top of the help-style output if anything
    # fails early.
    args=()
    [ -n "$MODE_FLAG" ] && args+=("$MODE_FLAG")

    # Read post-setup IDs out of `config/smus-setup.config.json` and
    # inject them via `--set` so the migration tool's Prompter
    # auto-defaults to them. The Prompter does not read env vars;
    # `--set` is the documented escape hatch.
    _has_set_for() {
        local _key="$1"
        local _arg
        for _arg in "${PASSTHROUGH[@]}"; do
            case "$_arg" in
                "--set=${_key}="*|"--set=${_key}=") return 0 ;;
            esac
        done
        local _i=0
        local _n="${#PASSTHROUGH[@]}"
        while [ "$_i" -lt "$_n" ]; do
            if [ "${PASSTHROUGH[$_i]:-}" = "--set" ]; then
                local _next="${PASSTHROUGH[$((_i+1))]:-}"
                case "$_next" in
                    "${_key}="*|"${_key}=") return 0 ;;
                esac
            fi
            _i=$((_i + 1))
        done
        return 1
    }

    local _key _val
    for _key in identity_center_instance_arn identity_center_identity_store_id \
                domain_service_role smus_domain_id admin_project_id \
                admin_project_profile_id \
                repo_provider repo_name repo_url repo_connection_arn \
                codecommit_repo_arn; do
        _val="$(_smus_setup_config_get "$_key")"
        if [ -n "$_val" ] && ! _has_set_for "$_key"; then
            # smus-setup.config.json stores `repo_provider` in CFN's
            # title-case form (CodeCommit, GitHub, GitLab, Bitbucket)
            # — that's what `AWS::CodeConnections::Connection`'s
            # `ProviderType` accepts. The migration tool's config
            # schema uses the historical lowercase form (`github`,
            # `gitlab`, etc.) for backward compat with pre-CFN
            # deployments. Translate at this boundary so both sides
            # stay correct.
            if [ "$_key" = "repo_provider" ]; then
                _val="$(printf '%s' "$_val" | tr '[:upper:]' '[:lower:]')"
            fi
            args+=("--set" "${_key}=${_val}")
            echo "==> Pre-set:  ${_key}=${_val}"
        fi
    done

    # The migration tool's Prompter expects `git_connection_id` (the
    # historical key from when datazone create-connection was the API).
    # Map it from the new repo_connection_arn (3P) or synthesize for
    # codecommit. This avoids a Prompter prompt on first run after a
    # smus-setup deploy.
    if ! _has_set_for git_connection_id; then
        local _conn_arn _provider _gci
        _conn_arn="$(_smus_setup_config_get repo_connection_arn)"
        _provider="$(_smus_setup_config_get repo_provider)"
        if [ -n "$_conn_arn" ]; then
            _gci="$_conn_arn"
        elif [ "$(printf '%s' "${_provider}" | tr '[:upper:]' '[:lower:]')" = "codecommit" ]; then
            _gci="codecommit-$(_smus_setup_config_get repo_name)"
        else
            _gci=""
        fi
        if [ -n "$_gci" ]; then
            args+=("--set" "git_connection_id=${_gci}")
            echo "==> Pre-set:  git_connection_id=${_gci}"
        fi
    fi

    if [ "${#PASSTHROUGH[@]}" -gt 0 ]; then
        args+=("${PASSTHROUGH[@]}")
    fi

    # Step 7 invokes `aws-smus-cicd-cli` via PATH; the wheel installs
    # the binary into `${VENV}/bin` which isn't on the system PATH by
    # default. Prepend the venv bin directory so subprocess shells
    # spawned by the migration tool see the CLI.
    export PATH="${ROOT_DIR}/.venv/bin:${PATH}"

    "$PY" -m migration_tool "${args[@]}" 2>&1 | tee "$log_path"
    rc=${PIPESTATUS[0]}
    echo
    echo "==> migration tool exited with code ${rc}"
    echo "==> log: ${log_path}"
    exit "$rc"
}

# -----------------------------------------------------------------------------
# Action: teardown
#
# Reverses ONLY the migration-tool side effects:
#
#   1. Cancel/revoke every active subscription the admin project holds.
#      SMUS auto-tears the resource links in `glue_db_<env_id>` when
#      the subscription is revoked.
#   2. Revoke the LF DESCRIBE grants we added on the resource links.
#   3. Wipe the migration state file (same as `reset`).
#
# What teardown DOES NOT do:
#   * KMS key policy unwind                          — `./scripts/smus-setup.sh teardown`
#   * IAM project-role inline policy detach          — `./scripts/smus-setup.sh teardown`
#   * LF registration role delete                    — `./scripts/smus-setup.sh teardown`
#   * SMUS CFN stack delete                          — `./scripts/smus-setup.sh teardown`
#   * Delete the in-account CodeCommit repository    — `./scripts/smus-setup.sh teardown`
#     (CFN owns the repo since the 2026-Q2 refactor; deleting it lives
#     in the SMUS stack delete path so the lifecycle is symmetric.)
#   * Delete the AWS CodeConnections connection      — `./scripts/smus-setup.sh teardown`
#
# The split mirrors the script ownership: smus-setup created CFN/IAM/KMS/repo;
# migrate.sh added subscriptions + resource-link DESCRIBE on top.
# -----------------------------------------------------------------------------

_action_teardown() {
    echo "==> migration tool"
    echo "==> Action:   teardown"
    if [ -n "$MODE_FLAG" ]; then
        echo "==> Mode:     ${MODE_FLAG}"
    else
        echo "==> Mode:     (default — dry-run)"
    fi
    echo "==> Profile:  ${AWS_PROFILE:-<unset>}"
    echo "==> Region:   ${AWS_DEFAULT_REGION:-<unset>}"
    echo

    if [ "$MODE_FLAG" = "--apply" ] && [ "$ASSUME_YES" -ne 1 ]; then
        if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
            echo "ERROR: teardown --apply requires a TTY for confirmation; pass --yes for non-interactive use" >&2
            exit 64
        fi
        {
            echo "WARNING: teardown will revoke subscriptions, drop LF DESCRIBE grants"
            echo "         on resource links, and wipe migration state."
            echo "         (For SMUS CFN / IAM / KMS / repo unwind use \`./scripts/smus-setup.sh teardown\`.)"
            printf "Type 'teardown' to confirm: "
        } >/dev/tty
        local typed=""
        IFS= read -r typed </dev/tty || typed=""
        if [ "$typed" != "teardown" ]; then
            echo "ABORTED: confirmation mismatch; nothing changed." >/dev/tty
            exit 1
        fi
    fi

    if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        echo "==> teardown: aws/jq missing; cannot proceed"
        exit 64
    fi

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

    # ---- 1. Cancel/revoke active subscriptions held by the project. ----
    if [ -n "$_project_id" ]; then
        echo "==> teardown 1/3: revoking subscriptions held by ${_project_id}"
        local _subs
        _subs="$(aws datazone list-subscriptions --domain-identifier "$_domain_id" \
            --owning-project-id "$_project_id" --region "$_region" \
            --output json 2>/dev/null \
            | jq -r --arg p "$_project_id" \
                '.items[]? | select(.status == "APPROVED") | select(.subscribedPrincipal.project.id == $p) | .id' \
            2>/dev/null || true)"
        local _sub
        while IFS= read -r _sub; do
            [ -z "$_sub" ] && continue
            if [ "$_apply" -eq 1 ]; then
                if aws datazone cancel-subscription --domain-identifier "$_domain_id" \
                        --identifier "$_sub" --region "$_region" >/dev/null 2>&1; then
                    echo "    + cancelled subscription ${_sub}"
                elif aws datazone revoke-subscription --domain-identifier "$_domain_id" \
                        --identifier "$_sub" --region "$_region" >/dev/null 2>&1; then
                    echo "    + revoked subscription ${_sub}"
                else
                    echo "    = subscription ${_sub} not in a cancellable state (or already gone)"
                fi
            else
                echo "    DRY-RUN: would revoke/cancel subscription ${_sub}"
            fi
        done <<<"$_subs"
    fi

    # ---- 2. Revoke LF DESCRIBE on resource links. ----
    if [ -n "$_project_id" ]; then
        echo "==> teardown 2/3: revoking LF DESCRIBE on resource links"
        local _project_user_role _lh_env_id _project_db _tooling_env_id
        _lh_env_id="$(aws datazone list-environments \
            --domain-identifier "$_domain_id" \
            --project-identifier "$_project_id" \
            --region "$_region" --output json 2>/dev/null \
            | jq -r '.items[]? | select(.name == "Lakehouse Database") | .id' | head -n 1)"
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
        if [ -n "$_lh_env_id" ] && [ -n "$_project_user_role" ]; then
            _project_db="glue_db_${_lh_env_id}"
            local _links_json
            _links_json="$(aws glue get-tables --region "$_region" \
                --database-name "$_project_db" --output json 2>/dev/null \
                | jq -c '[.TableList[]? | select(.TargetTable != null) | .Name]' 2>/dev/null || echo '[]')"
            local _link
            while IFS= read -r _link; do
                [ -z "$_link" ] && continue
                if [ "$_apply" -eq 1 ]; then
                    aws lakeformation revoke-permissions --region "$_region" \
                        --principal "DataLakePrincipalIdentifier=${_project_user_role}" \
                        --resource "{\"Table\":{\"DatabaseName\":\"${_project_db}\",\"Name\":\"${_link}\"}}" \
                        --permissions DESCRIBE >/dev/null 2>&1 || true
                    echo "    + revoked DESCRIBE on ${_project_db}.${_link}"
                else
                    echo "    DRY-RUN: would revoke DESCRIBE on ${_project_db}.${_link}"
                fi
            done < <(printf '%s' "$_links_json" | jq -r '.[]')
        else
            echo "    = no Lakehouse env / project user role discovered; skipping link revokes"
        fi
    fi

    # ---- 3. Wipe migration state. ----
    # The CodeCommit repo and CodeConnections connection are now owned
    # by the SMUS CFN stack (`smus-setup.sh`). Operators tear those down
    # as part of the stack delete, not here.
    echo "==> teardown 3/3: wiping migration state"
    if [ -f "$STATE_PATH" ]; then
        if [ "$_apply" -eq 1 ]; then
            local _backup="${STATE_PATH}.bak.$(date +%s)"
            cp "$STATE_PATH" "$_backup"
            rm -f "$STATE_PATH"
            echo "    + state wiped; previous file saved to ${_backup}"
        else
            echo "    DRY-RUN: would wipe ${STATE_PATH}"
        fi
    else
        echo "    = no state file at ${STATE_PATH}"
    fi

    echo
    echo "==> teardown complete"
    if [ "$_apply" -eq 0 ]; then
        echo "==> dry-run only; re-run with --apply to perform the operations above"
    fi
}

# -----------------------------------------------------------------------------
# Dispatch.
# -----------------------------------------------------------------------------
case "$ACTION" in
    run)      _action_run ;;
    status)   _action_status ;;
    reset)    _action_reset ;;
    teardown) _action_teardown ;;
    *) usage ;;
esac
