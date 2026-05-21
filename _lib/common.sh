# shellcheck shell=bash
#
# _lib/common.sh — shared scaffolding for `smus-setup.sh` and
# `migrate.sh`. Sourced via `source "${ROOT_DIR}/_lib/common.sh"`.
#
# What lives here:
#   * Apply-mode confirmation helper (`_confirm_apply`)
#   * Banner printer (`_print_banner`)
#   * SMUS setup state I/O (`_smus_setup_state_path`, `_smus_setup_state_get`)
#   * SMUS setup config I/O (`_smus_setup_config_path`, `_smus_setup_config_get`)
#   * Python resolver (`_resolve_python`) — used by migrate.sh
#   * LF dangling-admin cleanup (`_lf_strip_dangling_admins`)
#   * `_jq_required` / `_aws_required` guards
#
# Both wrapper scripts source this file early, immediately after they
# resolve `ROOT_DIR`. Common state schema:
#
#   config/smus-setup.config.json — written by smus-setup.sh, read by migrate.sh
#     {
#       "admin_group_name":               "...",
#       "de_group_name":                  "...",
#       "consumer_group_name":            "...",
#       "smus_domain_id":                 "dzd-...",
#       "admin_project_id":               "...",
#       "admin_project_profile_id":       "...",
#       "domain_service_role":            "arn:aws:iam:::role/...",
#       "tooling_user_role_arn":          "arn:aws:iam:::role/datazone_usr_role_...",
#       "lf_registration_role_arn":       "arn:aws:iam:::role/smus-seed-lf-registration-role",
#       "identity_center_instance_arn":   "arn:aws:sso:::instance/...",
#       "identity_center_identity_store_id": "d-..."
#     }
#
#   state/smus-setup.state.json — written by smus-setup.sh
#     { "status": "complete|failed|in_progress", "completed_at_utc": "..." }
#
#   config/migration.config.json — owned by the migration tool (Python)
#   state/migration.state.json — owned by the migration tool runner
#

# -----------------------------------------------------------------------------
# Path helpers
# -----------------------------------------------------------------------------

_smus_setup_config_path() {
    printf '%s/config/smus-setup.config.json' "${ROOT_DIR}"
}

_smus_setup_state_path() {
    printf '%s/state/smus-setup.state.json' "${ROOT_DIR}"
}

_migration_config_path() {
    printf '%s/config/migration.config.json' "${ROOT_DIR}"
}

_migration_state_path() {
    printf '%s/state/migration.state.json' "${ROOT_DIR}"
}

# -----------------------------------------------------------------------------
# Required-tool guards
# -----------------------------------------------------------------------------

_aws_required() {
    if ! command -v aws >/dev/null 2>&1; then
        echo "ERROR: aws CLI not found on PATH" >&2
        return 64
    fi
}

_jq_required() {
    if ! command -v jq >/dev/null 2>&1; then
        echo "ERROR: jq not found on PATH" >&2
        return 64
    fi
}

# -----------------------------------------------------------------------------
# Banner — prints the mode/profile/region header consistent across both
# wrappers so output looks the same.
# -----------------------------------------------------------------------------

_print_banner() {
    local _label="$1"
    echo "==> ${_label}"
    if [ -n "${MODE_FLAG:-}" ]; then
        echo "==> Mode:     ${MODE_FLAG}"
    else
        echo "==> Mode:     (default — dry-run)"
    fi
    echo "==> Profile:  ${AWS_PROFILE:-<unset>}"
    echo "==> Region:   ${AWS_DEFAULT_REGION:-<unset>}"
}

# -----------------------------------------------------------------------------
# Apply-mode confirmation. Caller sets MODE_FLAG and ASSUME_YES.
# -----------------------------------------------------------------------------

_confirm_apply() {
    [ "${MODE_FLAG:-}" = "--apply" ] || return 0
    [ "${ASSUME_YES:-0}" -eq 1 ] && return 0
    if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
        echo "ERROR: --apply requires a TTY for confirmation; pass --yes for non-interactive runs" >&2
        exit 64
    fi
    {
        echo "WARNING: about to run in --apply mode against AWS account $(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo '<unknown>')."
        printf "Type 'apply' to confirm: "
    } >/dev/tty
    local _typed=""
    IFS= read -r _typed </dev/tty || _typed=""
    if [ "$_typed" != "apply" ]; then
        echo "ABORTED: confirmation mismatch; nothing changed." >/dev/tty
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Atomic JSON writer for config/state files.
#
# Usage: _write_json_atomic <path> <json-string>
# -----------------------------------------------------------------------------

_write_json_atomic() {
    local _path="$1"
    local _payload="$2"
    mkdir -p "$(dirname "$_path")"
    local _tmp
    _tmp="$(mktemp -t "$(basename "$_path").XXXXXX")"
    printf '%s\n' "$_payload" > "$_tmp"
    mv "$_tmp" "$_path"
}

# -----------------------------------------------------------------------------
# Read a single key out of the SMUS setup config (returns empty string
# when the file or key is missing). Caller is expected to have jq.
# -----------------------------------------------------------------------------

_smus_setup_config_get() {
    local _key="$1"
    local _path
    _path="$(_smus_setup_config_path)"
    if [ ! -f "$_path" ] || ! command -v jq >/dev/null 2>&1; then
        return 0
    fi
    jq -r --arg k "$_key" '.[$k] // empty' "$_path" 2>/dev/null
}

# -----------------------------------------------------------------------------
# Merge a single key/value (string) into the SMUS setup config.
# -----------------------------------------------------------------------------

_smus_setup_config_set() {
    local _key="$1"
    local _value="$2"
    local _path
    _path="$(_smus_setup_config_path)"
    local _existing='{}'
    [ -f "$_path" ] && _existing="$(cat "$_path")"
    local _merged
    _merged="$(printf '%s' "$_existing" | jq \
        --arg k "$_key" --arg v "$_value" \
        '. + {($k): $v}')"
    _write_json_atomic "$_path" "$_merged"
}

# -----------------------------------------------------------------------------
# Read the SMUS setup state file's `status` field.
# -----------------------------------------------------------------------------

_smus_setup_state_status() {
    local _path
    _path="$(_smus_setup_state_path)"
    if [ ! -f "$_path" ] || ! command -v jq >/dev/null 2>&1; then
        return 0
    fi
    jq -r '.status // empty' "$_path" 2>/dev/null
}

# -----------------------------------------------------------------------------
# Mark setup state. Status values:
#   - in_progress
#   - complete
#   - failed
# -----------------------------------------------------------------------------

_smus_setup_state_mark() {
    local _status="$1"
    local _now
    _now="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    local _path
    _path="$(_smus_setup_state_path)"
    local _payload
    _payload="$(jq -n --arg s "$_status" --arg t "$_now" \
        '{status: $s, last_updated_utc: $t}')"
    _write_json_atomic "$_path" "$_payload"
}

# -----------------------------------------------------------------------------
# _lf_strip_dangling_admins <region>
#
# Walk the LF data-lake-admins list, drop every IAM-role principal
# whose underlying role no longer exists in IAM, and persist the
# cleaned list back. Idempotent — call any number of times.
# -----------------------------------------------------------------------------

_lf_strip_dangling_admins() {
    local _region="$1"
    local _admins_json _cleaned _changed=0
    _admins_json="$(aws lakeformation get-data-lake-settings \
        --query 'DataLakeSettings.DataLakeAdmins' \
        --region "$_region" --output json 2>/dev/null || echo '[]')"
    _cleaned="$(printf '%s' "$_admins_json" | jq '[]')"
    local _principal _bare
    while IFS= read -r _principal; do
        [ -z "$_principal" ] && continue
        if [[ "$_principal" == arn:aws:iam::*:role/* ]]; then
            _bare="${_principal##*/}"
            if ! aws iam get-role --role-name "$_bare" >/dev/null 2>&1; then
                echo "    + dropping dangling LF admin: ${_principal}"
                _changed=1
                continue
            fi
        fi
        _cleaned="$(printf '%s' "$_cleaned" | jq --arg p "$_principal" \
            '. + [{DataLakePrincipalIdentifier: $p}]')"
    done < <(printf '%s' "$_admins_json" | jq -r '.[].DataLakePrincipalIdentifier')
    if [ "$_changed" -eq 1 ]; then
        aws lakeformation put-data-lake-settings \
            --data-lake-settings "{\"DataLakeAdmins\": $_cleaned}" \
            --region "$_region" >/dev/null 2>&1 || \
            echo "    WARN: put-data-lake-settings cleanup failed"
    fi
}

# -----------------------------------------------------------------------------
# Resolve a usable `python` executable. Both wrappers may need a
# Python; smus-setup.sh uses it for atomic JSON merges, migrate.sh
# uses it to invoke the migration_tool package.
# -----------------------------------------------------------------------------

_resolve_python() {
    if [ -n "${MIGRATION_TOOL_PYTHON:-}" ]; then
        printf '%s' "$MIGRATION_TOOL_PYTHON"
        return 0
    fi
    if [ -x "${ROOT_DIR}/.venv/bin/python" ]; then
        printf '%s' "${ROOT_DIR}/.venv/bin/python"
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$(command -v python3)"
        return 0
    fi
    if command -v python >/dev/null 2>&1; then
        printf '%s' "$(command -v python)"
        return 0
    fi
    return 1
}
