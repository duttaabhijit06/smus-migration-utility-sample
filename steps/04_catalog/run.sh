#!/usr/bin/env bash
#
# steps/04_catalog/run.sh — Step 4: Glue Data Catalog → SageMaker Catalog.
#
# Enumerates the AWS Glue Data Catalog (databases + tables) in the source
# account, writes a deterministic catalog inventory file, and registers a
# Glue-typed DataZone data source on the Admin_Project of the SMUS_Domain
# so SageMaker Catalog can crawl every database on a 6-hour schedule.
#
# Behavior summary (Requirements 10.1, 10.2, 10.3, 10.4, 10.5, 3.6):
#   - In every mode the catalog inventory is written to
#     outputs/glue-catalog-inventory.json. In dry-run, the file is a
#     deterministic placeholder ({databases: [], dry_run: true}).
#   - Idempotency: in apply mode the script first calls
#     `aws datazone list-data-sources --type GLUE` and skips
#     `create-data-source` when a data source named
#     `migration-tool-glue-catalog` already exists, capturing the
#     existing dataSourceId for the initial run trigger.
#   - The would-be `aws datazone create-data-source` and
#     `aws datazone start-data-source-run` invocations are printed in
#     dry-run via `mt_aws`'s built-in DRY-RUN: line emission.
#   - The script halts (exit 64, `STATUS: missing_var <NAME>`) if any
#     of `MT_AWS_REGION`, `MT_SMUS_DOMAIN_ID`, or `MT_ADMIN_PROJECT_ID`
#     is missing — Step 1 must complete first per Requirement 10.5.
#
# This script does NOT call boto3 or any AWS SDK. Every AWS interaction
# flows through `mt_aws` from `steps/_lib/common.sh`.
#

# Source the shared helper library before enabling strict mode so the
# library's own conditional reads of optional MT_* env vars are not
# tripped by `set -u`.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../_lib/common.sh"

set -euo pipefail

mt_init "04_catalog" "$@"

# `jq` is required for JSON construction and parsing throughout this
# step. The orchestrator's environment is expected to have it; if not,
# halt with a clear status line so the user can install it.
if ! command -v jq >/dev/null 2>&1; then
    mt_status error "jq is required but not found on PATH"
    exit 64
fi

mt_require_var MT_AWS_REGION
mt_require_var MT_SMUS_DOMAIN_ID
mt_require_var MT_ADMIN_PROJECT_ID

mt_status started

# Save the script's stdout to fd 3 so the local _aws_capture helper
# below can route mt_aws's STATUS / DRY-RUN side-effect lines back to
# the orchestrator (and the run.log tee opened by mt_init in apply
# mode) without polluting our command-substitution captures of the
# AWS CLI's JSON payload.
exec 3>&1

# _aws_capture <aws-args...>
#
# Run `mt_aws "$@"`, separate the STATUS / DRY-RUN side-effect lines
# from the JSON payload, route the side-effect lines through fd 3
# (the script's real stdout) so the orchestrator still parses them,
# and emit only the JSON payload on fd 1 so callers can do:
#
#   OUT="$(_aws_capture <verb> <args>)"
#
# In dry-run mode mt_aws never invokes aws, so the captured output
# will be the STATUS + DRY-RUN lines only and the helper returns an
# empty string on fd 1.
_aws_capture() {
    local _raw
    _raw="$(mt_aws "$@")"
    printf '%s\n' "$_raw" | grep -E '^(STATUS:|DRY-RUN:)' >&3 || true
    printf '%s\n' "$_raw" | grep -vE '^(STATUS:|DRY-RUN:)' || true
}

# ---------------------------------------------------------------------------
# 1. Build the Glue catalog inventory.
# ---------------------------------------------------------------------------

INVENTORY_PATH="$(mt_outputs_path "glue-catalog-inventory.json")"
FETCHED_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

DBS_JSON="$(_aws_capture glue get-databases --region "$MT_AWS_REGION")"
if [ -z "$DBS_JSON" ]; then
    DBS_JSON='{"DatabaseList":[]}'
fi

DB_NAMES_JSON="$(printf '%s\n' "$DBS_JSON" | jq -c '[.DatabaseList[]?.Name | select(. != null)]')"
DB_NAMES_LIST="$(printf '%s\n' "$DB_NAMES_JSON" | jq -r '.[]?')"

DB_ENTRIES='[]'
if [ -n "$DB_NAMES_LIST" ]; then
    while IFS= read -r DB_NAME; do
        [ -z "$DB_NAME" ] && continue
        TABLES_JSON="$(_aws_capture glue get-tables \
            --database-name "$DB_NAME" \
            --region "$MT_AWS_REGION")"
        if [ -z "$TABLES_JSON" ]; then
            TABLES_JSON='{"TableList":[]}'
        fi
        TABLES_TRIMMED="$(printf '%s\n' "$TABLES_JSON" | jq -c \
            '[.TableList[]? | {name: .Name, location: (.StorageDescriptor.Location // null)}]')"
        DB_ENTRIES="$(jq -nc \
            --arg name "$DB_NAME" \
            --argjson cur "$DB_ENTRIES" \
            --argjson tables "$TABLES_TRIMMED" \
            '$cur + [{name: $name, tables: $tables}]')"
    done <<< "$DB_NAMES_LIST"
fi

# In dry-run, the list calls returned nothing (mt_aws skips real AWS
# calls). Write a placeholder inventory with `databases: []` and a
# `dry_run: true` marker so the on-disk artifact is deterministic for
# downstream consumers and for run-to-run diffs.
if mt_dry_run_mode; then
    INVENTORY_JSON="$(jq -nc \
        --arg fetched "$FETCHED_UTC" \
        --arg region  "$MT_AWS_REGION" \
        '{version: 1, fetched_utc: $fetched, region: $region, databases: [], dry_run: true}')"
else
    INVENTORY_JSON="$(jq -nc \
        --arg fetched "$FETCHED_UTC" \
        --arg region  "$MT_AWS_REGION" \
        --argjson dbs "$DB_ENTRIES" \
        '{version: 1, fetched_utc: $fetched, region: $region, databases: $dbs}')"
fi

printf '%s\n' "$INVENTORY_JSON" | jq '.' > "$INVENTORY_PATH"
mt_log "wrote $INVENTORY_PATH"

# Sample DB list used ONLY to render a realistic --configuration JSON
# in dry-run mode so the would-be `aws datazone create-data-source`
# line includes a non-empty `relationalFilterConfigurations` array.
# The on-disk inventory above stays empty + dry_run: true.
RENDER_DB_NAMES_JSON="$DB_NAMES_JSON"
if mt_dry_run_mode && [ "$RENDER_DB_NAMES_JSON" = "[]" ]; then
    RENDER_DB_NAMES_JSON='["sample_db"]'
fi

# ---------------------------------------------------------------------------
# 2. Idempotency check: does the named GLUE data source already exist?
# ---------------------------------------------------------------------------

DATA_SOURCE_NAME="migration-tool-glue-catalog"
DATA_SOURCE_ID=""

EXISTING_JSON="$(_aws_capture datazone list-data-sources \
    --domain-identifier  "$MT_SMUS_DOMAIN_ID" \
    --project-identifier "$MT_ADMIN_PROJECT_ID" \
    --type GLUE)"
if [ -n "$EXISTING_JSON" ]; then
    DATA_SOURCE_ID="$(printf '%s\n' "$EXISTING_JSON" \
        | jq -r --arg name "$DATA_SOURCE_NAME" \
            '[.items[]? | select(.name == $name) | .dataSourceId // .id // empty][0] // empty')"
fi

# ---------------------------------------------------------------------------
# 3. Build the data source configuration and create it (if absent).
# ---------------------------------------------------------------------------

# Build relationalFilterConfigurations: one entry per inventoried
# database with an INCLUDE * filter so every table inside the database
# is crawled and published into the SageMaker Catalog.
FILTER_CONFIG="$(printf '%s\n' "$RENDER_DB_NAMES_JSON" | jq -c \
    '[.[] | {databaseName: ., filterExpressions: [{type: "INCLUDE", expression: "*"}]}]')"
CONFIG_JSON="$(jq -nc --argjson filters "$FILTER_CONFIG" \
    '{glueRunConfiguration: {relationalFilterConfigurations: $filters}}')"
# Daily at 00:00 UTC. The DataZone CreateDataSource regex requires a
# literal numeric minute and hour (no `*/N` wildcard), so we pin both
# fields to 0 and let the `?` day-of-month placeholder cover the rest.
SCHEDULE_JSON='{"schedule":"cron(0 0 * * ? *)"}'

# Resolve the publishing target. DataZone V2 requires data sources to
# carry either `--connection-identifier` (preferred for V2) or
# `--environment-identifier` (legacy). V2 explicitly REJECTS env id;
# we use the project's `project.default_lakehouse` connection instead,
# discovered by Step 1 and forwarded as MT_LAKEHOUSE_CONNECTION_ID.
LAKEHOUSE_CONN_ID="${MT_LAKEHOUSE_CONNECTION_ID:-}"

if [ -n "$DATA_SOURCE_ID" ]; then
    mt_log "data source '$DATA_SOURCE_NAME' already exists (id=$DATA_SOURCE_ID); skipping create"
elif [ -z "$LAKEHOUSE_CONN_ID" ] && mt_apply_mode; then
    mt_status error "create-data-source needs MT_LAKEHOUSE_CONNECTION_ID; run Step 1 again after the All-capabilities profile finishes provisioning"
    exit 1
else
    _CONN_FLAG=()
    if [ -n "$LAKEHOUSE_CONN_ID" ]; then
        _CONN_FLAG=(--connection-identifier "$LAKEHOUSE_CONN_ID")
    fi
    CREATE_OUT="$(_aws_capture datazone create-data-source \
        --domain-identifier  "$MT_SMUS_DOMAIN_ID" \
        --project-identifier "$MT_ADMIN_PROJECT_ID" \
        --name "$DATA_SOURCE_NAME" \
        --type GLUE \
        "${_CONN_FLAG[@]}" \
        --configuration "$CONFIG_JSON" \
        --schedule "$SCHEDULE_JSON" \
        --publish-on-import)"
    if [ -n "$CREATE_OUT" ]; then
        DATA_SOURCE_ID="$(printf '%s\n' "$CREATE_OUT" | jq -r '.id // empty')"
    fi
    if [ -z "$DATA_SOURCE_ID" ] && mt_apply_mode; then
        mt_status error "create-data-source failed for ${DATA_SOURCE_NAME}"
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# 4. Trigger the initial sync run.
# ---------------------------------------------------------------------------

# In dry-run we won't have a real DATA_SOURCE_ID; pass a placeholder so
# the would-be `aws datazone start-data-source-run` line is still
# rendered with all required flags. In apply mode we skip the run
# trigger if no data source got created (the create branch above
# already failed loudly via mt_status error).
if mt_apply_mode && [ -z "$DATA_SOURCE_ID" ]; then
    mt_log "skipping start-data-source-run (no data source id available)"
    RUN_ID=""
else
    RUN_DS_ID="${DATA_SOURCE_ID:-PLACEHOLDER}"
    RUN_OUT="$(_aws_capture datazone start-data-source-run \
        --domain-identifier      "$MT_SMUS_DOMAIN_ID" \
        --data-source-identifier "$RUN_DS_ID")"
    RUN_ID=""
    if [ -n "$RUN_OUT" ]; then
        RUN_ID="$(printf '%s\n' "$RUN_OUT" | jq -r '.id // empty')"
    fi
fi

RUN_PATH="$(mt_outputs_path "datasource-run.json")"
RUN_JSON="$(jq -nc \
    --arg recorded "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg ds_name  "$DATA_SOURCE_NAME" \
    --arg ds_id    "${DATA_SOURCE_ID:-}" \
    --arg run_id   "${RUN_ID:-}" \
    '{version: 1, recorded_utc: $recorded, data_source_name: $ds_name, data_source_id: $ds_id, run_id: $run_id}')"

if mt_apply_mode; then
    printf '%s\n' "$RUN_JSON" | jq '.' > "$RUN_PATH"
    mt_log "wrote $RUN_PATH"
else
    mt_dryrun "write $RUN_PATH"
fi

mt_status ok
exit 0
