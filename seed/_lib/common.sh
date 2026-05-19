# shellcheck shell=bash
#
# seed/_lib/common.sh — shared bash helpers for the Seed_Script.
#
# This is the seed-side counterpart to steps/_lib/common.sh. The two libraries
# are deliberately separate: the Seed_Script never sources the Migration_Tool's
# helper library and vice versa (Requirement 20.25 isolation rule, design.md
# "Isolation" section). The seed namespace uses the SBX_ env-var prefix
# (read as "source-bootstrap") so it cannot collide with the Migration_Tool's
# MT_ prefix.
#
# Public API (task 24.2):
#
#   sbx_init <module_name> [args...]        bootstrap a seed module's run
#   sbx_status <kind> [args...]             emit `STATUS: <kind> [args...]`
#   sbx_log <message>                       non-STATUS info line to stdout
#   sbx_dryrun <full-cmd>                   print `DRY-RUN: <full-cmd>`
#   sbx_aws <args...>                       aws CLI dispatch with apply gating
#   sbx_require_var <NAME>                  exit 64 + STATUS if NAME unset/empty
#   sbx_apply_mode | sbx_dry_run_mode       boolean guards (return 0/1)
#   sbx_state_get <jq-path>                 read seed.state.json
#   sbx_state_set_service <module> <json>   atomic deep-merge into .services.<m>
#   sbx_state_get_service_status <module>   echo .services.<m>.status
#   sbx_assert_same_account                 enforce same-account contract (20.28)
#
# Discipline:
#   - This file does NOT call `set -e` / `set -u` / `set -o pipefail`.
#     Each create.sh / provision.sh / teardown.sh chooses its own error
#     discipline AFTER sourcing this lib so an optional SBX_* config var the
#     orchestrator legitimately leaves unset cannot trip `set -u` here.
#   - Helpers `return` non-zero for soft failures and only `exit` for
#     unrecoverable conditions (missing required vars, mutually exclusive
#     run-mode flags, jq missing during state mutation, same-account
#     contract violation) so a helper accidentally invoked at library load
#     time cannot kill the host shell.
#   - This library never calls AWS APIs directly. Every aws invocation flows
#     through `sbx_aws`. Same-account enforcement is centralised here so
#     each create.sh need only call `sbx_assert_same_account`.
#

# -----------------------------------------------------------------------------
# Internal: resolve the seed library root and the workspace root from the
# location of this file. Done once at source time so callers can chdir freely
# without losing the anchor.
#
# BASH_SOURCE[0] is the path of this file (e.g. .../seed/_lib/common.sh).
# Resolving via cd+pwd gives an absolute path even when callers source via
# a relative path. The grandparent dir is the seed root; one more parent is
# the workspace root that hosts both ./seed/ and ./config/ (which the
# same-account check reads from).
__sbx_resolve_paths() {
    local _src
    _src="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
    SBX_LIB_DIR="$_src"
    SBX_SEED_DIR="$(dirname "$_src")"
    # Default workspace root sits one level above seed/. Callers may override
    # by exporting SBX_WORKDIR before sourcing.
    SBX_WORKDIR="${SBX_WORKDIR:-$(dirname "$SBX_SEED_DIR")}"
    export SBX_LIB_DIR SBX_SEED_DIR SBX_WORKDIR
}
__sbx_resolve_paths

# -----------------------------------------------------------------------------
# sbx_state_path / sbx_config_path
#
# Echo absolute paths to the Seed_State_File and Seed_Config_File. Built from
# SBX_WORKDIR so they are resilient to the caller's cwd.
sbx_state_path() {
    printf '%s/seed/seed.state.json\n' "${SBX_WORKDIR}"
}

sbx_config_path() {
    printf '%s/seed/seed.config.json\n' "${SBX_WORKDIR}"
}

# -----------------------------------------------------------------------------
# sbx_status <kind> [args...]
#
# Emit a STATUS line. Mirrors the migration tool's `mt_status` output forms
# so anything that already parses `STATUS:` lines on the migration side reads
# seed-side output without a separate grammar.
#
#   sbx_status started                  -> STATUS: started
#   sbx_status ok                       -> STATUS: ok
#   sbx_status action <name>            -> STATUS: action <name>
#   sbx_status error <message>          -> STATUS: error <message>
#   sbx_status set <key>=<value>        -> STATUS: set <key>=<value>
#
# Trailing tokens are forwarded verbatim, so callers can pass arbitrary text
# (e.g. `sbx_status missing_var SBX_REGION`) without re-quoting.
sbx_status() {
    if [ "$#" -eq 0 ]; then
        printf 'STATUS: error sbx_status called without arguments\n'
        return 1
    fi
    printf 'STATUS: %s\n' "$*"
}

# -----------------------------------------------------------------------------
# sbx_log <message>
#
# Plain stdout informational line. Forwarded by the apply-mode tee into the
# per-invocation log (Requirement 20.14).
sbx_log() {
    printf '%s\n' "$*"
}

# -----------------------------------------------------------------------------
# sbx_dryrun "<cmd>"
#
# Print `DRY-RUN: <cmd>` and return 0. Use this in explicit-echo contexts
# where you want the literal command rendered regardless of run mode (for
# example, a README-style would-be-command line in a generated file). For
# normal aws dispatch prefer `sbx_aws`, which already routes through dry-run
# when SBX_DRY_RUN=1.
sbx_dryrun() {
    printf 'DRY-RUN: %s\n' "$*"
    return 0
}

# -----------------------------------------------------------------------------
# sbx_require_var <NAME>
#
# Verify that the named environment variable is set and non-empty. On failure
# emit `STATUS: missing_var <NAME>` and exit 64 so the orchestrator surfaces
# the missing config value (Requirement 20.10).
sbx_require_var() {
    local _name="${1:-}"
    if [ -z "$_name" ]; then
        printf 'STATUS: error sbx_require_var called without a variable name\n'
        exit 64
    fi

    # Read the variable named by $_name without depending on bash's `${!var}`
    # indirect expansion. `eval` with a defaulted expansion is portable and
    # works the same way regardless of `set -u`.
    local _value
    eval "_value=\${${_name}:-}"
    if [ -z "$_value" ]; then
        printf 'STATUS: missing_var %s\n' "$_name"
        exit 64
    fi
}

# -----------------------------------------------------------------------------
# sbx_apply_mode / sbx_dry_run_mode
#
# Boolean guards. Each returns 0 iff the corresponding flag is set. Use as:
#
#   if sbx_apply_mode; then
#       sbx_aws s3api create-bucket ...
#   fi
sbx_apply_mode() {
    [ "${SBX_APPLY:-}" = "1" ]
}

sbx_dry_run_mode() {
    [ "${SBX_DRY_RUN:-}" = "1" ]
}

# -----------------------------------------------------------------------------
# sbx_init <module_name> [--apply | --dry-run] [--phase=1|2|all] [other-args...]
#
# Bootstrap a seed module's run. MUST be invoked once at the top of every
# Seed_Script entry point (provision.sh, teardown.sh, or each
# <service>/create.sh when run directly). Effects (task 24.2):
#
#   - Sets SBX_MODULE="<module_name>" (e.g. `glue`, `mwaa`).
#   - Validates the three core env vars (Requirement 20.10):
#       SBX_REGION, SBX_SOURCE_ACCOUNT_ID, SBX_SEED_NAME_PREFIX.
#     Missing/empty → `STATUS: missing_var <NAME>` and exit 64.
#   - Parses --apply / --dry-run. Defaults to dry-run when neither is given
#     (Requirement 20.2). --apply + --dry-run together exits 64 with
#     `STATUS: error apply and dry-run are mutually exclusive`
#     (Requirement 20.4).
#   - Parses --phase=1|2|all (used only by glue/) and exposes SBX_PHASE.
#     Defaults to `all`. Unknown values reject with exit 64 +
#     `STATUS: error invalid_phase <value>` so a typo cannot silently fall
#     into the catch-all branch.
#   - Creates seed/logs/ if missing and computes SBX_LOG_PATH=
#     seed/logs/run-<UTC>.log. In apply mode tees subsequent stdout and
#     stderr through that file (Requirement 20.14). The path is set
#     unconditionally so callers may reference SBX_LOG_PATH even in dry-run.
#
# Unknown trailing flags are ignored so callers can layer their own argument
# parsing on top (e.g. `glue/create.sh --phase=2 --apply` is fine, and a
# future `--skip-foo` step-local flag will not break sbx_init).
sbx_init() {
    if [ -z "${1:-}" ]; then
        printf 'STATUS: error sbx_init requires a module name\n'
        exit 64
    fi
    SBX_MODULE="$1"
    export SBX_MODULE
    shift

    # Validate core env vars BEFORE parsing flags so a missing region surfaces
    # the same error regardless of which flags the caller passed.
    sbx_require_var SBX_REGION
    sbx_require_var SBX_SOURCE_ACCOUNT_ID
    sbx_require_var SBX_SEED_NAME_PREFIX

    SBX_PHASE="${SBX_PHASE:-all}"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --apply)
                SBX_APPLY=1
                ;;
            --dry-run)
                SBX_DRY_RUN=1
                ;;
            --phase=1|--phase=2|--phase=all)
                SBX_PHASE="${1#--phase=}"
                ;;
            --phase=*)
                printf 'STATUS: error invalid_phase %s\n' "${1#--phase=}"
                exit 64
                ;;
            *)
                : # let callers parse their own additional flags
                ;;
        esac
        shift
    done

    # Default to dry-run when neither flag is set in env or args (20.2).
    if [ -z "${SBX_APPLY:-}" ] && [ -z "${SBX_DRY_RUN:-}" ]; then
        SBX_DRY_RUN=1
    fi

    # Mutual exclusion guard (Requirement 20.4). Catches both an inherited
    # SBX_APPLY=1 colliding with an explicit --dry-run flag and the inverse.
    if [ -n "${SBX_APPLY:-}" ] && [ -n "${SBX_DRY_RUN:-}" ]; then
        printf 'STATUS: error apply and dry-run are mutually exclusive\n'
        exit 64
    fi
    export SBX_APPLY SBX_DRY_RUN SBX_PHASE

    # Per-invocation log file. The path is set unconditionally so the
    # orchestrator and per-service modules can reference SBX_LOG_PATH
    # regardless of mode; only apply-mode tees stdout/stderr through it.
    local _log_dir="${SBX_WORKDIR}/seed/logs"
    mkdir -p "$_log_dir"
    local _utc
    _utc="$(date -u +'%Y-%m-%dT%H-%M-%SZ')"
    SBX_LOG_PATH="${_log_dir}/run-${_utc}.log"
    export SBX_LOG_PATH

    if [ "${SBX_APPLY:-}" = "1" ]; then
        # Append (don't truncate) so re-runs sharing a UTC second still
        # accumulate. The 1-second granularity makes real collisions
        # vanishingly rare in practice.
        exec > >(tee -a "$SBX_LOG_PATH") 2>&1
    fi
}

# -----------------------------------------------------------------------------
# sbx_aws <args...>
#
# Wrapper around `aws ...`:
#
#   - Always emits `STATUS: action aws <verb>` BEFORE invoking, where <verb>
#     is the first positional token after `aws`. This lets the per-invocation
#     log audit every aws call against its source module (Requirement 20.14).
#   - Apply mode (SBX_APPLY=1): invokes `aws "$@"` directly. Stdout flows
#     naturally to the caller (and through the tee opened by sbx_init). The
#     aws CLI's exit code is propagated via `return $?`.
#   - Dry-run mode (default): prints `DRY-RUN: aws <args>` to stdout and
#     returns 0 without executing (Requirement 20.2).
sbx_aws() {
    local _verb="${1:-}"
    if [ -n "$_verb" ]; then
        sbx_status action "aws ${_verb}"
    else
        sbx_status action "aws"
    fi

    if [ "${SBX_APPLY:-}" = "1" ]; then
        aws "$@"
        return $?
    fi

    printf 'DRY-RUN: aws %s\n' "$*"
    return 0
}

# -----------------------------------------------------------------------------
# sbx_state_get <jq-path>
#
# Echo the value at <jq-path> from seed/seed.state.json. Returns empty for:
#   - missing state file
#   - missing/null jq result (`// empty` filter)
#   - jq not installed (graceful degradation per task 24.2 contract)
#
# Use as: `sbx_state_get '.services.msk.resources.bootstrap_brokers'`. Use
# bracket notation for module names containing characters jq treats as
# operators, e.g. `'.services["flink-kda"].status'`.
sbx_state_get() {
    local _expr="${1:-}"
    if [ -z "$_expr" ]; then
        printf 'STATUS: error sbx_state_get called without a jq expression\n'
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        return 0
    fi
    local _path
    _path="$(sbx_state_path)"
    if [ ! -f "$_path" ]; then
        return 0
    fi
    jq -r "(${_expr}) // empty" "$_path" 2>/dev/null
}

# -----------------------------------------------------------------------------
# sbx_state_set_service <module> <jq-merge-payload>
#
# Atomically deep-merge a JSON payload into seed/seed.state.json under
# `.services.<module>`. Implementation uses jq + a temp file + os.replace
# so a SIGKILL between write and rename never leaves the state file in a
# partial state (Requirement 20.12 — "persist resource identifiers before
# issuing any further state-changing AWS CLI command").
#
# Behaviour:
#   - If seed.state.json does not yet exist, it is created with the
#     bootstrap shape `{"version":1,"services":{}}` so the first call does
#     not need a separate init step.
#   - The merge uses jq's `*` operator so nested fields (e.g.
#     `.services.glue.resources.connections`) are deep-combined rather than
#     replaced wholesale. Repeated calls are therefore additive on
#     sub-objects. Arrays follow jq's `*` semantics (right operand wins),
#     which matches the per-service payload shape in design.md where each
#     create.sh writes the authoritative array for resources it owns.
#   - jq missing → `STATUS: error jq_required` and exit 64 (loud failure
#     per task 24.2 implementation note).
#   - python3 missing → fall back to `mv -f` (POSIX rename is atomic on
#     the same filesystem) so the helper still functions in environments
#     without python; the function name stays "os-replace" because that is
#     the contract callers depend on.
#
# Example:
#   sbx_state_set_service msk \
#     '{"status":"provisioned","resources":{"bootstrap_brokers":"b-1.example:9092"}}'
sbx_state_set_service() {
    local _module="${1:-}"
    local _payload="${2:-}"
    if [ -z "$_module" ] || [ -z "$_payload" ]; then
        printf 'STATUS: error sbx_state_set_service requires <module> <payload>\n'
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        sbx_status error jq_required
        exit 64
    fi
    local _path _tmp
    _path="$(sbx_state_path)"
    _tmp="${_path}.tmp"

    # Bootstrap the canonical shape on first write so callers don't need a
    # separate init step. Includes `version` so future schema migrations
    # have something to gate on.
    if [ ! -f "$_path" ]; then
        mkdir -p "$(dirname "$_path")"
        printf '{"version":1,"services":{}}\n' > "$_path"
    fi

    # Deep-merge payload into .services[<module>]. --argjson validates the
    # payload as JSON before any write, so a malformed payload fails fast
    # without touching the state file.
    if ! jq --arg m "$_module" --argjson p "$_payload" \
        '.services[$m] = ((.services[$m] // {}) * $p)' \
        "$_path" > "$_tmp" 2>/dev/null; then
        rm -f "$_tmp"
        return 1
    fi

    # Atomic rename. python3 gives a fsync-then-replace guarantee; mv -f is
    # the portable fallback when python3 is absent. Path values pass via env
    # vars so a future seed root containing spaces or quotes does not break
    # the inline command.
    if command -v python3 >/dev/null 2>&1; then
        SBX_TMP="$_tmp" SBX_DST="$_path" python3 -c 'import os; t=os.environ["SBX_TMP"]; d=os.environ["SBX_DST"]; f=open(t,"rb"); os.fsync(f.fileno()); f.close(); os.replace(t,d)'
    else
        mv -f "$_tmp" "$_path"
    fi
}

# -----------------------------------------------------------------------------
# sbx_state_get_service_status <module>
#
# Echo the `status` field of `.services.<module>` from the state file. The
# value is one of `provisioned`, `failed`, `torn_down`, or empty when the
# service has no recorded status yet. Empty for missing state file or jq
# absent (mirrors sbx_state_get's graceful-degradation contract).
#
# This is a thin convenience over sbx_state_get that uses jq's --arg so
# module names with hyphens (e.g. `flink-kda`) work without manual quoting.
sbx_state_get_service_status() {
    local _module="${1:-}"
    if [ -z "$_module" ]; then
        printf 'STATUS: error sbx_state_get_service_status requires a module name\n'
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        return 0
    fi
    local _path
    _path="$(sbx_state_path)"
    if [ ! -f "$_path" ]; then
        return 0
    fi
    jq -r --arg m "$_module" '.services[$m].status // empty' "$_path" 2>/dev/null
}

# -----------------------------------------------------------------------------
# sbx_assert_same_account
#
# Enforce the same-account contract (Requirement 20.28). Reads
# `source_account_id` from BOTH:
#
#   - ${SBX_WORKDIR}/seed/seed.config.json
#   - ${SBX_WORKDIR}/config/migration.config.json (when present)
#
# If config/migration.config.json does NOT exist, this function is a no-op:
# the migration tool has not run yet, so there is nothing to compare
# against. Each create.sh / teardown.sh is expected to invoke this BEFORE
# any state-changing aws call so a misconfigured account ID halts the run
# pre-side-effect.
#
# On a mismatch:
#   - emits `STATUS: error same_account_contract_violated`
#   - exits 64 (the same exit code used elsewhere for unrecoverable
#     pre-execution validation failures, so the orchestrator can
#     uniformly distinguish input errors from runtime AWS errors).
#
# Behaviour when source_account_id is missing on either side: the function
# treats an empty value the same as a literal mismatch with a non-empty
# value. Two empty values compare equal and the function returns silently;
# this is intentional so a fresh repo (both files just created with a
# scaffolding step) does not block the very first dry-run.
sbx_assert_same_account() {
    local _migration_config="${SBX_WORKDIR}/config/migration.config.json"
    if [ ! -f "$_migration_config" ]; then
        # No-op: the migration tool has not run yet, so there is nothing
        # to compare against (task 24.2 acceptance criterion).
        return 0
    fi
    if ! command -v jq >/dev/null 2>&1; then
        sbx_status error jq_required
        exit 64
    fi
    local _seed_config _seed _migration
    _seed_config="$(sbx_config_path)"
    _seed=""
    if [ -f "$_seed_config" ]; then
        _seed="$(jq -r '.source_account_id // empty' "$_seed_config" 2>/dev/null)"
    fi
    _migration="$(jq -r '.source_account_id // empty' "$_migration_config" 2>/dev/null)"

    if [ "$_seed" != "$_migration" ]; then
        sbx_status error same_account_contract_violated
        exit 64
    fi
}
