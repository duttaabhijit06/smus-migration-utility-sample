#!/usr/bin/env bash
#
# add-glue-databases.sh — add one or more Glue databases to the SMUS
# admin project.
#
# Pulls the same end-to-end wire-up that `migrate.sh run` does for the
# seed databases, but scoped to a caller-supplied database list. Use
# this when you want to bring an additional Glue catalog database into
# the SMUS admin project AFTER the initial migration is complete.
#
# What it does for each named database:
#
#   1. Pre-flight: confirm DB exists, confirm SMUS setup is complete.
#   2. Lake Formation: revoke IAMAllowedPrincipals on DB + tables;
#      grant DESCRIBE/SELECT (+Grantable) to the project user role
#      and the manage-access role.
#   3. Register the unique S3 prefixes (one per table location) with
#      --with-federation --hybrid-access-enabled using the dedicated
#      LF registration role created by smus-setup.sh.
#   4. Add the DB to the project's Glue data source (creates the
#      data source if it doesn't exist) and trigger a sync run.
#   5. Auto-subscribe the admin project to the resulting listings so
#      they're queryable in Visual ETL / Athena / SMUS portal.
#   6. Grant DESCRIBE on the resulting resource links inside the
#      project's managed Glue DB.
#
# Usage:
#   ./scripts/add-glue-databases.sh --databases db1,db2,db3 \
#       --apply --profile smus-seed --yes
#
#   ./scripts/add-glue-databases.sh --databases mydb --dry-run \
#       --profile smus-seed
#
# Required:
#   --databases CSV           Comma-separated list of Glue database names.
#
# Optional:
#   --apply | --dry-run       Default dry-run.
#   --profile NAME            AWS CLI profile (or AWS_PROFILE env var).
#   --region  NAME            AWS region (default us-east-1).
#   --yes / -y                Skip the apply-mode confirmation prompt.
#   --data-source-name NAME   Override the data source name. Defaults to
#                             the migration tool's `migration-tool-glue-catalog`
#                             if it exists (so the new DBs get added to the
#                             same source); otherwise a new source named
#                             `migration-tool-glue-catalog-extra` is created.
#

set -uo pipefail
set +u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=_lib/common.sh
source "${ROOT_DIR}/_lib/common.sh"

MODE_FLAG=""
PROFILE=""
REGION=""
ASSUME_YES=0
DATABASES_CSV=""
DATA_SOURCE_NAME_OVERRIDE=""

usage() { sed -n '2,55p' "$0"; exit 64; }

# -----------------------------------------------------------------------------
# CLI parsing
# -----------------------------------------------------------------------------

if [ $# -eq 0 ]; then usage; fi

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)
            if [ "$MODE_FLAG" = "--dry-run" ]; then
                echo "ERROR: --apply and --dry-run are mutually exclusive" >&2
                exit 64
            fi
            MODE_FLAG="--apply"; shift ;;
        --dry-run)
            if [ "$MODE_FLAG" = "--apply" ]; then
                echo "ERROR: --apply and --dry-run are mutually exclusive" >&2
                exit 64
            fi
            MODE_FLAG="--dry-run"; shift ;;
        --profile)            PROFILE="$2"; shift 2 ;;
        --profile=*)          PROFILE="${1#*=}"; shift ;;
        --region)             REGION="$2"; shift 2 ;;
        --region=*)           REGION="${1#*=}"; shift ;;
        --yes|-y)             ASSUME_YES=1; shift ;;
        --databases)          DATABASES_CSV="$2"; shift 2 ;;
        --databases=*)        DATABASES_CSV="${1#*=}"; shift ;;
        --data-source-name)   DATA_SOURCE_NAME_OVERRIDE="$2"; shift 2 ;;
        --data-source-name=*) DATA_SOURCE_NAME_OVERRIDE="${1#*=}"; shift ;;
        -h|--help)            usage ;;
        *)
            echo "ERROR: unknown flag '$1'" >&2
            usage ;;
    esac
done

if [ -n "$PROFILE" ]; then export AWS_PROFILE="$PROFILE"; fi
if [ -n "$REGION" ];  then export AWS_DEFAULT_REGION="$REGION"; fi

if [ -z "$DATABASES_CSV" ]; then
    echo "ERROR: --databases is required (comma-separated list)" >&2
    exit 64
fi

# Normalize: split on commas, trim whitespace, drop empties.
DATABASES=()
IFS=',' read -ra _RAW_DBS <<< "$DATABASES_CSV"
for _db in "${_RAW_DBS[@]}"; do
    _db="${_db## }"; _db="${_db%% }"
    [ -n "$_db" ] && DATABASES+=("$_db")
done
if [ "${#DATABASES[@]}" -eq 0 ]; then
    echo "ERROR: --databases produced no valid database names from '${DATABASES_CSV}'" >&2
    exit 64
fi

LOG_DIR="${ROOT_DIR}/logs"
mkdir -p "$LOG_DIR"

# -----------------------------------------------------------------------------
# Banner + apply-mode confirmation
# -----------------------------------------------------------------------------

_print_banner "add-glue-databases"
echo "==> Databases: ${DATABASES[*]}"
echo

_confirm_apply
_aws_required || exit $?
_jq_required  || exit $?

# -----------------------------------------------------------------------------
# Pre-flight: read smus-setup state + config.
# -----------------------------------------------------------------------------

_setup_status="$(_smus_setup_state_status 2>/dev/null || true)"
if [ "$_setup_status" != "complete" ]; then
    echo "ERROR: SMUS setup is not complete (state status = '${_setup_status:-<missing>}')." >&2
    echo "       Run \`./scripts/smus-setup.sh setup --apply\` first." >&2
    exit 65
fi

REGION_RESOLVED="${AWS_DEFAULT_REGION:-us-east-1}"
DOMAIN_ID="$(_smus_setup_config_get smus_domain_id)"
PROJECT_ID="$(_smus_setup_config_get admin_project_id)"
TOOLING_USER_ROLE_ARN="$(_smus_setup_config_get tooling_user_role_arn)"
LF_REGISTRATION_ROLE_ARN="$(_smus_setup_config_get lf_registration_role_arn)"
MANAGED_ACCESS_ROLE_NAME="$(_smus_setup_config_get managed_access_role_name)"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")"

if [ -z "$DOMAIN_ID" ] || [ -z "$PROJECT_ID" ]; then
    echo "ERROR: smus_domain_id / admin_project_id missing from config/smus-setup.config.json" >&2
    exit 65
fi
if [ -z "$ACCOUNT_ID" ]; then
    echo "ERROR: could not resolve AWS account id (sts:GetCallerIdentity failed)" >&2
    exit 65
fi

MANAGED_ACCESS_ROLE_ARN=""
if [ -n "$MANAGED_ACCESS_ROLE_NAME" ]; then
    MANAGED_ACCESS_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${MANAGED_ACCESS_ROLE_NAME}"
fi

# `tooling_user_role_arn` and `lf_registration_role_arn` are not always
# in the config (older smus-setup runs didn't persist them). Fall back
# to discovery if missing.
if [ -z "$TOOLING_USER_ROLE_ARN" ]; then
    TOOLING_ENV_ID="$(aws datazone list-environments \
        --domain-identifier "$DOMAIN_ID" --project-identifier "$PROJECT_ID" \
        --region "$REGION_RESOLVED" --output json 2>/dev/null \
        | jq -r '.items[]? | select(.name == "Tooling") | .id' | head -n 1)"
    if [ -n "$TOOLING_ENV_ID" ]; then
        TOOLING_USER_ROLE_ARN="$(aws datazone get-environment \
            --domain-identifier "$DOMAIN_ID" --identifier "$TOOLING_ENV_ID" \
            --region "$REGION_RESOLVED" \
            --query 'provisionedResources[?name==`userRoleArn`].value | [0]' \
            --output text 2>/dev/null | grep -v '^None$' || true)"
    fi
fi
if [ -z "$LF_REGISTRATION_ROLE_ARN" ]; then
    if aws iam get-role --role-name smus-seed-lf-registration-role >/dev/null 2>&1; then
        LF_REGISTRATION_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/smus-seed-lf-registration-role"
    fi
fi

if [ -z "$TOOLING_USER_ROLE_ARN" ]; then
    echo "ERROR: could not resolve project user role; is the Tooling env provisioned?" >&2
    exit 65
fi

echo "==> domain:                ${DOMAIN_ID}"
echo "==> project:               ${PROJECT_ID}"
echo "==> project user role:     ${TOOLING_USER_ROLE_ARN}"
echo "==> manage-access role:    ${MANAGED_ACCESS_ROLE_ARN:-<none>}"
echo "==> LF registration role:  ${LF_REGISTRATION_ROLE_ARN:-<none>}"
echo

APPLY=0
[ "$MODE_FLAG" = "--apply" ] && APPLY=1

_aws() {
    if [ "$APPLY" -eq 1 ]; then
        aws "$@"
    else
        echo "    DRY-RUN: aws $*" >&2
    fi
}

# =============================================================================
# Step 1: confirm every named database actually exists.
# =============================================================================

echo "==> Step 1: validating database list"
MISSING=()
for _db in "${DATABASES[@]}"; do
    if aws glue get-database --name "$_db" --region "$REGION_RESOLVED" \
            >/dev/null 2>&1; then
        echo "    + ${_db}: found in Glue"
    else
        echo "    WARN: ${_db}: NOT found in Glue"
        MISSING+=("$_db")
    fi
done
if [ "${#MISSING[@]}" -gt 0 ]; then
    echo "ERROR: ${#MISSING[@]} database(s) not found: ${MISSING[*]}" >&2
    exit 66
fi
echo

# =============================================================================
# Step 2: Lake Formation grants on each DB + its tables.
# =============================================================================

echo "==> Step 2: Lake Formation grants on each database"
for _db in "${DATABASES[@]}"; do
    echo "  -- ${_db}"
    # Database-level: DESCRIBE +Grantable to project user role + manage-access.
    for _principal in "$TOOLING_USER_ROLE_ARN" "$MANAGED_ACCESS_ROLE_ARN"; do
        [ -z "$_principal" ] && continue
        _aws lakeformation grant-permissions --region "$REGION_RESOLVED" \
            --principal "DataLakePrincipalIdentifier=${_principal}" \
            --resource "{\"Database\":{\"Name\":\"${_db}\"}}" \
            --permissions DESCRIBE \
            --permissions-with-grant-option DESCRIBE >/dev/null 2>&1 || true
    done
    # Table-level: revoke IAMAllowedPrincipals + grant SELECT/DESCRIBE.
    _tables_json="$(aws glue get-tables --database-name "$_db" \
        --region "$REGION_RESOLVED" --output json 2>/dev/null || echo '{"TableList":[]}')"
    while IFS= read -r _t; do
        [ -z "$_t" ] && continue
        # Best-effort revoke of IAMAllowedPrincipals.
        _aws lakeformation revoke-permissions --region "$REGION_RESOLVED" \
            --principal "DataLakePrincipalIdentifier=IAM_ALLOWED_PRINCIPALS" \
            --resource "{\"Table\":{\"DatabaseName\":\"${_db}\",\"Name\":\"${_t}\"}}" \
            --permissions ALL >/dev/null 2>&1 || true
        # Grant DESCRIBE/SELECT +Grantable to both principals.
        for _principal in "$TOOLING_USER_ROLE_ARN" "$MANAGED_ACCESS_ROLE_ARN"; do
            [ -z "$_principal" ] && continue
            _aws lakeformation grant-permissions --region "$REGION_RESOLVED" \
                --principal "DataLakePrincipalIdentifier=${_principal}" \
                --resource "{\"Table\":{\"DatabaseName\":\"${_db}\",\"Name\":\"${_t}\"}}" \
                --permissions DESCRIBE SELECT \
                --permissions-with-grant-option DESCRIBE SELECT >/dev/null 2>&1 || true
        done
    done < <(printf '%s' "$_tables_json" | jq -r '.TableList[]?.Name')
    echo "    + LF grants applied across ${_db}"
done
echo

# =============================================================================
# Step 3: register unique S3 prefixes with WithFederation.
# =============================================================================

echo "==> Step 3: register S3 prefixes with WithFederation=true"
if [ -z "$LF_REGISTRATION_ROLE_ARN" ]; then
    echo "    WARN: LF_REGISTRATION_ROLE_ARN missing; skipping WithFederation registration"
else
    LOCATIONS=()
    for _db in "${DATABASES[@]}"; do
        _tables_json="$(aws glue get-tables --database-name "$_db" \
            --region "$REGION_RESOLVED" --output json 2>/dev/null || echo '{"TableList":[]}')"
        while IFS= read -r _loc; do
            [ -z "$_loc" ] && continue
            [[ "$_loc" != s3://* ]] && continue
            # Use the bucket-root S3 ARN to dedupe.
            _bucket_root="s3://${_loc#s3://}"
            _bucket_root="${_bucket_root%%/*}"
            LOCATIONS+=("$_bucket_root")
        done < <(printf '%s' "$_tables_json" | jq -r '.TableList[]?.StorageDescriptor.Location // empty')
    done
    # Dedupe.
    UNIQUE_LOCATIONS=()
    if [ "${#LOCATIONS[@]}" -gt 0 ]; then
        while IFS= read -r _loc; do
            UNIQUE_LOCATIONS+=("$_loc")
        done < <(printf '%s\n' "${LOCATIONS[@]}" | sort -u)
    fi
    echo "    + ${#UNIQUE_LOCATIONS[@]} unique S3 bucket(s) to (re-)register"
    for _loc in "${UNIQUE_LOCATIONS[@]}"; do
        _arn="${_loc/s3:\/\//arn:aws:s3:::}"
        # Best-effort deregister (safe to fail if not registered yet).
        _aws lakeformation deregister-resource --region "$REGION_RESOLVED" \
            --resource-arn "$_arn" >/dev/null 2>&1 || true
        # Register with WithFederation + HybridAccessEnabled.
        if _aws lakeformation register-resource --region "$REGION_RESOLVED" \
                --resource-arn "$_arn" \
                --role-arn "$LF_REGISTRATION_ROLE_ARN" \
                --with-federation \
                --hybrid-access-enabled >/dev/null 2>&1; then
            echo "    + registered ${_arn}"
        else
            # AlreadyExistsException is normal on re-registers; only warn
            # on apply mode where we actually issued the call.
            [ "$APPLY" -eq 1 ] && echo "    = ${_arn} already registered (or registration failed; check perms)"
        fi
    done
fi
echo

# =============================================================================
# Step 4: add to data source + trigger sync.
# =============================================================================

echo "==> Step 4: add to data source + trigger sync"

# Resolve target data source. Prefer the existing migration-tool source
# so new DBs land in the same publish target as the seed flow.
DEFAULT_DS_NAME="migration-tool-glue-catalog"
EXTRA_DS_NAME="migration-tool-glue-catalog-extra"

EXISTING_JSON="$(aws datazone list-data-sources \
    --domain-identifier "$DOMAIN_ID" --project-identifier "$PROJECT_ID" \
    --type GLUE --region "$REGION_RESOLVED" --output json 2>/dev/null || echo '{"items":[]}')"

if [ -n "$DATA_SOURCE_NAME_OVERRIDE" ]; then
    DS_NAME="$DATA_SOURCE_NAME_OVERRIDE"
else
    if printf '%s' "$EXISTING_JSON" | jq -e --arg n "$DEFAULT_DS_NAME" \
            '.items[]? | select(.name == $n)' >/dev/null 2>&1; then
        DS_NAME="$DEFAULT_DS_NAME"
    else
        DS_NAME="$EXTRA_DS_NAME"
    fi
fi
DS_ID="$(printf '%s' "$EXISTING_JSON" | jq -r --arg n "$DS_NAME" \
    '.items[]? | select(.name == $n) | .dataSourceId // .id // empty' | head -n 1)"
echo "    target data source: ${DS_NAME} (id=${DS_ID:-<new>})"

# Build the relationalFilterConfigurations array: one entry per DB,
# include all tables.
NEW_FILTERS="$(jq -nc --argjson dbs "$(printf '%s\n' "${DATABASES[@]}" | jq -R . | jq -s .)" \
    '[$dbs[] | {databaseName: ., filterExpressions: [{type: "INCLUDE", expression: "*"}]}]')"

if [ -z "$DS_ID" ]; then
    # Create new data source.
    LAKEHOUSE_CONN_ID="$(_smus_setup_config_get lakehouse_connection_id 2>/dev/null || true)"
    if [ -z "$LAKEHOUSE_CONN_ID" ]; then
        # Discover from the project's environments.
        LAKEHOUSE_CONN_ID="$(aws datazone list-connections \
            --domain-identifier "$DOMAIN_ID" --project-identifier "$PROJECT_ID" \
            --region "$REGION_RESOLVED" --output json 2>/dev/null \
            | jq -r '.items[]? | select(.name == "project.default_lakehouse") | .connectionId' \
            | head -n 1)"
    fi
    if [ -z "$LAKEHOUSE_CONN_ID" ]; then
        echo "    WARN: lakehouse connection id missing; cannot create data source"
        DS_ID=""
    else
        CONFIG_JSON="$(jq -nc --argjson filters "$NEW_FILTERS" \
            '{glueRunConfiguration: {relationalFilterConfigurations: $filters}}')"
        if [ "$APPLY" -eq 1 ]; then
            CREATE_OUT="$(aws datazone create-data-source \
                --domain-identifier  "$DOMAIN_ID" \
                --project-identifier "$PROJECT_ID" \
                --name "$DS_NAME" --type GLUE \
                --connection-identifier "$LAKEHOUSE_CONN_ID" \
                --configuration "$CONFIG_JSON" \
                --schedule '{"schedule":"cron(0 0 * * ? *)"}' \
                --publish-on-import \
                --region "$REGION_RESOLVED" --output json 2>/dev/null || echo '{}')"
            DS_ID="$(printf '%s' "$CREATE_OUT" | jq -r '.id // empty')"
            [ -n "$DS_ID" ] && echo "    + created data source ${DS_NAME} (id=${DS_ID})"
        else
            echo "    DRY-RUN: would create data source ${DS_NAME} with ${#DATABASES[@]} DB filter(s)"
        fi
    fi
else
    # Merge new DBs into the existing data source's filter list.
    CURRENT_CONFIG_JSON="$(aws datazone get-data-source \
        --domain-identifier "$DOMAIN_ID" --identifier "$DS_ID" \
        --region "$REGION_RESOLVED" --output json 2>/dev/null \
        | jq -c '.configuration')"
    MERGED_FILTERS="$(jq -nc \
        --argjson current "$CURRENT_CONFIG_JSON" \
        --argjson new     "$NEW_FILTERS" \
        '($current.glueRunConfiguration.relationalFilterConfigurations // []) as $cur
         | (($cur + $new) | unique_by(.databaseName))')"
    MERGED_CONFIG="$(jq -nc --argjson filters "$MERGED_FILTERS" \
        '{glueRunConfiguration: {relationalFilterConfigurations: $filters}}')"
    if [ "$APPLY" -eq 1 ]; then
        aws datazone update-data-source \
            --domain-identifier "$DOMAIN_ID" --identifier "$DS_ID" \
            --configuration "$MERGED_CONFIG" \
            --region "$REGION_RESOLVED" --output json >/dev/null 2>&1 \
            && echo "    + merged ${#DATABASES[@]} DB filter(s) into ${DS_NAME}"
    else
        echo "    DRY-RUN: would merge filters into ${DS_NAME}; merged size=$(printf '%s' "$MERGED_FILTERS" | jq 'length')"
    fi
fi

# Trigger a sync run on the data source.
if [ -n "$DS_ID" ] && [ "$APPLY" -eq 1 ]; then
    RUN_OUT="$(aws datazone start-data-source-run \
        --domain-identifier "$DOMAIN_ID" \
        --data-source-identifier "$DS_ID" \
        --region "$REGION_RESOLVED" --output json 2>/dev/null || echo '{}')"
    RUN_ID="$(printf '%s' "$RUN_OUT" | jq -r '.id // empty')"
    [ -n "$RUN_ID" ] && echo "    + sync run started (id=${RUN_ID})"
elif [ -n "$DS_ID" ]; then
    echo "    DRY-RUN: would start data source run on ${DS_ID}"
fi
echo

# =============================================================================
# Step 5: auto-subscribe the admin project to the new listings.
# =============================================================================
#
# After Step 4 publishes assets, SMUS registers them as listings the admin
# project can subscribe to. Without a subscription the assets are flagged
# "Asset cannot be queried with tools" in Visual ETL — exactly the symptom
# `migrate.sh`'s _smus_subscribe_assets fixes for the seed flow.
#
# Listings show up asynchronously (~30-60 seconds after the sync run
# completes). We poll for ~3 minutes; if nothing's published yet, we
# print a hint and exit cleanly. The operator can re-run the script
# when the sync finishes — the LF + register-resource steps are
# idempotent.

echo "==> Step 5: auto-subscribe to new listings"
if [ "$APPLY" -ne 1 ]; then
    echo "    DRY-RUN: would search for new listings owned by admin project and subscribe"
else
    SUBSCRIBED=0
    for _attempt in 1 2 3 4 5 6; do
        _listings_json="$(aws datazone search --domain-identifier "$DOMAIN_ID" \
            --search-scope ASSET --owning-project-identifier "$PROJECT_ID" \
            --region "$REGION_RESOLVED" --output json 2>/dev/null || echo '{}')"
        # Extract listing ids for assets whose source database is in our
        # new DB list.
        _matching="$(printf '%s' "$_listings_json" | jq -c \
            --argjson dbs "$(printf '%s\n' "${DATABASES[@]}" | jq -R . | jq -s .)" \
            '[.items[]? | .assetItem | select(.typeIdentifier == "amazon.datazone.GlueTableAssetType") | select((.externalIdentifier // "") as $eid | ($dbs | any(. as $d | $eid | contains("/" + $d + "/")))) | .identifier]')"
        _count="$(printf '%s' "$_matching" | jq -r 'length')"
        if [ "${_count:-0}" -gt 0 ]; then
            while IFS= read -r _asset_id; do
                [ -z "$_asset_id" ] && continue
                _listing_id="$(aws datazone get-asset --domain-identifier "$DOMAIN_ID" \
                    --identifier "$_asset_id" --region "$REGION_RESOLVED" --output json 2>/dev/null \
                    | jq -r '.listing.listingId // empty')"
                [ -z "$_listing_id" ] && continue
                _existing="$(aws datazone list-subscriptions \
                    --domain-identifier "$DOMAIN_ID" \
                    --subscribed-listing-id "$_listing_id" \
                    --region "$REGION_RESOLVED" --output json 2>/dev/null \
                    | jq -r --arg p "$PROJECT_ID" \
                        '[.items[]? | select(.subscribedPrincipal.project.id == $p) | select(.status == "APPROVED" or .status == "REVOKED" | not)] | length' \
                        2>/dev/null || echo "0")"
                if [ "${_existing:-0}" != "0" ]; then
                    echo "    = listing ${_listing_id} already subscribed"
                    continue
                fi
                if aws datazone create-subscription-request \
                        --domain-identifier "$DOMAIN_ID" \
                        --request-reason "add-glue-databases.sh auto-subscribe" \
                        --subscribed-listings "identifier=${_listing_id}" \
                        --subscribed-principals "project={identifier=${PROJECT_ID}}" \
                        --region "$REGION_RESOLVED" --output json >/dev/null 2>&1; then
                    echo "    + subscribed admin project to listing ${_listing_id}"
                    SUBSCRIBED=$((SUBSCRIBED + 1))
                fi
            done < <(printf '%s' "$_matching" | jq -r '.[]')
            break
        fi
        echo "    waiting for sync to publish listings (attempt ${_attempt}/6)…"
        sleep 30
    done
    if [ "$SUBSCRIBED" -eq 0 ]; then
        echo "    HINT: no listings published yet for the new DBs — re-run the script in ~5 min, or check the data source's run status in the SMUS portal"
    fi
fi
echo

# =============================================================================
# Step 6: grant DESCRIBE on resource links inside the project's managed DB.
# =============================================================================
#
# Subscriptions create resource links in `glue_db_<env_id>` but don't
# grant LF DESCRIBE on the link. Spark's catalog client needs DESCRIBE
# to resolve link names; without it queries fail with TABLE_OR_VIEW_NOT_FOUND.
# Same logic as `_smus_grant_resource_link_describe` in migrate.sh.

echo "==> Step 6: grant LF DESCRIBE on resource links"
LH_ENV_ID="$(aws datazone list-environments \
    --domain-identifier "$DOMAIN_ID" --project-identifier "$PROJECT_ID" \
    --region "$REGION_RESOLVED" --output json 2>/dev/null \
    | jq -r '.items[]? | select(.name == "Lakehouse Database") | .id' | head -n 1)"
if [ -n "$LH_ENV_ID" ]; then
    PROJECT_DB="glue_db_${LH_ENV_ID}"
    _links_json="$(aws glue get-tables --region "$REGION_RESOLVED" \
        --database-name "$PROJECT_DB" --output json 2>/dev/null \
        | jq -c '[.TableList[]? | select(.TargetTable != null) | .Name]' 2>/dev/null || echo '[]')"
    _link_count="$(printf '%s' "$_links_json" | jq -r 'length')"
    if [ "${_link_count:-0}" -gt 0 ]; then
        # DESCRIBE on the parent project DB (idempotent).
        _aws lakeformation grant-permissions --region "$REGION_RESOLVED" \
            --principal "DataLakePrincipalIdentifier=${TOOLING_USER_ROLE_ARN}" \
            --resource "{\"Database\":{\"Name\":\"${PROJECT_DB}\"}}" \
            --permissions DESCRIBE >/dev/null 2>&1 || true
        while IFS= read -r _link; do
            [ -z "$_link" ] && continue
            if _aws lakeformation grant-permissions --region "$REGION_RESOLVED" \
                    --principal "DataLakePrincipalIdentifier=${TOOLING_USER_ROLE_ARN}" \
                    --resource "{\"Table\":{\"DatabaseName\":\"${PROJECT_DB}\",\"Name\":\"${_link}\"}}" \
                    --permissions DESCRIBE >/dev/null 2>&1; then
                echo "    + DESCRIBE on resource link ${PROJECT_DB}.${_link}"
            fi
        done < <(printf '%s' "$_links_json" | jq -r '.[]')
    else
        echo "    = no resource links yet in ${PROJECT_DB}; re-run in a few minutes after the sync completes"
    fi
else
    echo "    WARN: Lakehouse Database environment not found; skipping link DESCRIBE"
fi
echo

echo "==> add-glue-databases complete"
if [ "$APPLY" -ne 1 ]; then
    echo "==> dry-run only; re-run with --apply to perform the operations above"
else
    echo "==> NOTE: it can take ~30-60 seconds after the data source sync run for"
    echo "          assets to appear in the SMUS portal. If subscriptions or"
    echo "          resource-link DESCRIBE grants didn't apply (Step 5 / Step 6),"
    echo "          re-run this script — every step is idempotent."
fi
