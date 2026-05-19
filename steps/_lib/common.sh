# shellcheck shell=bash
#
# steps/_lib/common.sh — shared bash helpers for migration tool step run.sh files.
#
# Every per-step run.sh sources this library as its first action AFTER the
# `#!/usr/bin/env bash` shebang and BEFORE enabling its own
# `set -euo pipefail`. The helpers here centralise:
#
#   - argument parsing for --apply / --dry-run (default dry-run)
#   - the per-step outputs directory layout
#   - STATUS:/DRY-RUN: output conventions consumed by the orchestrator
#   - aws CLI dispatch with apply vs dry-run gating
#   - required env-var validation
#
# Discipline (Requirements 1.2, 1.3, 1.6, 4.3, 5.5):
#   - This file does NOT call `set -e` / `set -u` / `set -o pipefail`.
#     Each step's run.sh chooses its own error-handling discipline AFTER
#     sourcing this lib. This avoids tripping `set -u` on optional
#     MT_* config vars that the orchestrator may legitimately leave
#     unset.
#   - Functions return non-zero for soft failures and only `exit` for
#     unrecoverable conditions (missing required vars, mutually
#     exclusive run-mode flags) so a helper accidentally invoked at
#     library load time cannot kill the host shell.
#   - This library never calls AWS APIs. Every aws invocation flows
#     through `mt_aws` which the step body calls explicitly.
#

# -----------------------------------------------------------------------------
# mt_init <step_id> [outputs_dir] [--apply | --dry-run]
#
# Initialize a step's working state. MUST be the FIRST call after
# sourcing this library. Effects:
#
#   - Sets MT_STEP_ID="<step_id>" (used by other helpers).
#   - Computes MT_STEP_OUTPUTS_DIR. Default layout:
#       <MT_WORKDIR>/steps/<step_id>/outputs/
#     For inventory-style steps the caller passes the explicit outputs
#     dir as the optional second positional arg, e.g.:
#       mt_init "inventory.lambda" \
#         "${MT_WORKDIR}/steps/inventory/lambda/outputs"
#     MT_WORKDIR defaults to the current working directory when unset.
#   - Creates MT_STEP_OUTPUTS_DIR if missing.
#   - Parses --apply / --dry-run flags from the remaining arguments
#     and sets MT_APPLY=1 or MT_DRY_RUN=1 accordingly. Defaults to
#     dry-run when neither flag is given (matching the orchestrator's
#     default and Requirement 1.2).
#   - If MT_APPLY and MT_DRY_RUN both end up set (from inherited env
#     plus an explicit flag, etc.) the function exits 64 with a
#     `STATUS: error apply and dry-run are mutually exclusive` line so
#     the runner records the misuse (Requirement 1.7).
#   - In apply mode opens MT_STEP_OUTPUTS_DIR/run.log and tees stdout
#     and stderr through it so a persistent on-disk copy lands beside
#     the step's outputs while the orchestrator still sees the live
#     stream (Requirement 4.3).
mt_init() {
    if [ -z "${1:-}" ]; then
        printf 'STATUS: error mt_init requires a step_id argument\n'
        exit 64
    fi
    MT_STEP_ID="$1"
    shift

    # Resolve outputs dir. The optional second positional arg overrides
    # the default so inventory steps can point into
    # steps/inventory/<service>/outputs/ without a second helper.
    # We only treat the arg as an outputs dir when it is non-empty AND
    # does not start with `-` (to avoid swallowing a `--apply` that the
    # caller passed without an explicit outputs dir).
    if [ -n "${1:-}" ] && [ "${1#-}" = "$1" ]; then
        MT_STEP_OUTPUTS_DIR="$1"
        shift
    else
        local _mt_workdir
        _mt_workdir="${MT_WORKDIR:-$(pwd)}"
        MT_STEP_OUTPUTS_DIR="${_mt_workdir}/steps/${MT_STEP_ID}/outputs"
    fi
    export MT_STEP_ID MT_STEP_OUTPUTS_DIR

    mkdir -p "$MT_STEP_OUTPUTS_DIR"

    # Parse --apply / --dry-run from the remaining args. Unknown flags
    # are ignored here so step bodies can layer their own argument
    # parsing on top (e.g., a step-specific --skip-foo flag).
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --apply)
                MT_APPLY=1
                ;;
            --dry-run)
                MT_DRY_RUN=1
                ;;
            *)
                : # ignore; step body may parse its own additional flags
                ;;
        esac
        shift
    done

    # Default to dry-run when neither flag is set in env or args. This
    # matches the orchestrator's default mode (Requirement 1.2) and
    # gives every helper below a definitive marker to read.
    if [ -z "${MT_APPLY:-}" ] && [ -z "${MT_DRY_RUN:-}" ]; then
        MT_DRY_RUN=1
    fi

    # Mutual exclusion guard (Requirement 1.7). This catches the case
    # where an inherited MT_APPLY=1 from the orchestrator collides
    # with an explicit --dry-run flag, or vice versa.
    if [ -n "${MT_APPLY:-}" ] && [ -n "${MT_DRY_RUN:-}" ]; then
        printf 'STATUS: error apply and dry-run are mutually exclusive\n'
        exit 64
    fi
    export MT_APPLY MT_DRY_RUN

    # In apply mode, tee stdout and stderr through outputs/run.log so
    # the operator (and the orchestrator's stream parser) sees a real-
    # time copy while a persistent record lands on disk under the step
    # folder. The log is appended so re-runs accumulate history rather
    # than silently truncating prior runs.
    if [ "${MT_APPLY:-}" = "1" ]; then
        local _mt_runlog="${MT_STEP_OUTPUTS_DIR}/run.log"
        exec > >(tee -a "$_mt_runlog") 2>&1
    fi
}

# -----------------------------------------------------------------------------
# mt_status <kind> [args...]
#
# Emit a STATUS line that the orchestrator parses (Requirement 5.5).
# Forms recognised by the runner:
#
#   mt_status started                         -> STATUS: started
#   mt_status ok                              -> STATUS: ok
#   mt_status action <name>                   -> STATUS: action <name>
#   mt_status error "<message>"               -> STATUS: error <message>
#   mt_status set <key>=<value>               -> STATUS: set <key>=<value>
#   mt_status manual_ci_wiring_required       -> literal token used by
#                                                the Step 9 codecommit branch
#
# Any tokens after the verb are forwarded verbatim, so callers can pass
# arbitrary trailing text without re-quoting through `printf`.
mt_status() {
    if [ "$#" -eq 0 ]; then
        printf 'STATUS: error mt_status called without arguments\n'
        return 1
    fi
    printf 'STATUS: %s\n' "$*"
}

# -----------------------------------------------------------------------------
# mt_log <message>
#
# Write a non-STATUS informational line to stdout. The orchestrator
# forwards this to the run log as a plain event line (Requirement 4.3).
mt_log() {
    printf '%s\n' "$*"
}

# -----------------------------------------------------------------------------
# mt_dryrun <full-aws-cmd>
#
# Print the literal "DRY-RUN: <cmd>" line and return 0. Use this in
# explicit-echo contexts where you want the literal command rendered
# regardless of run mode (for example, the Step 9 codecommit branch
# that emits the would-be `aws codecommit create-repository` line into
# the manual-wiring stub). For normal aws dispatch prefer `mt_aws`,
# which already routes through dry-run when MT_DRY_RUN=1.
mt_dryrun() {
    printf 'DRY-RUN: %s\n' "$*"
    return 0
}

# -----------------------------------------------------------------------------
# mt_aws <args...>
#
# Wrapper around `aws ...`:
#
#   - Always emits `STATUS: action aws <verb>` BEFORE invoking,
#     where <verb> is the first positional token after `aws`. This
#     lets the orchestrator log every aws call against its source step
#     (Requirement 4.2 in concert with the runner).
#   - Apply mode (MT_APPLY=1): invokes `aws "$@"` directly. Stdout
#     flows naturally to the caller (and through the tee opened by
#     mt_init). On non-zero exit, the exit code is propagated.
#   - Dry-run mode (default): prints `DRY-RUN: aws <args>` to stdout
#     and returns 0 without executing (Requirements 1.2, 1.6, 4.3).
mt_aws() {
    local _mt_verb="${1:-}"
    if [ -n "$_mt_verb" ]; then
        mt_status action "aws ${_mt_verb}"
    else
        mt_status action "aws"
    fi

    if [ "${MT_APPLY:-}" = "1" ]; then
        aws "$@"
        return $?
    fi

    printf 'DRY-RUN: aws %s\n' "$*"
    return 0
}

# -----------------------------------------------------------------------------
# mt_require_var <NAME>
#
# Verify that the named environment variable is set and non-empty. On
# failure, emit `STATUS: missing_var <NAME>` and exit 64 so the
# orchestrator can prompt the user for the missing config value, persist
# it, and re-run the step (Requirement 2.6).
mt_require_var() {
    local _mt_name="${1:-}"
    if [ -z "$_mt_name" ]; then
        printf 'STATUS: error mt_require_var called without a variable name\n'
        exit 64
    fi

    # Read the variable named by $_mt_name without depending on bash's
    # `${!var}` indirect expansion; `eval` with a defaulted expansion
    # is equally portable across the bash versions we target and works
    # the same way regardless of `set -u`.
    local _mt_value
    eval "_mt_value=\${${_mt_name}:-}"
    if [ -z "$_mt_value" ]; then
        printf 'STATUS: missing_var %s\n' "$_mt_name"
        exit 64
    fi
}

# -----------------------------------------------------------------------------
# mt_outputs_path <filename>
#
# Echo the absolute path under MT_STEP_OUTPUTS_DIR/<filename>. Useful
# for building consistent paths to step artifacts without hardcoding
# the per-step layout.
mt_outputs_path() {
    printf '%s/%s\n' "${MT_STEP_OUTPUTS_DIR}" "${1:-}"
}

# -----------------------------------------------------------------------------
# mt_apply_mode
#
# Returns 0 iff MT_APPLY=1; returns 1 otherwise. Use as a guard:
#
#   if mt_apply_mode; then
#       mt_aws s3 sync ...
#   fi
mt_apply_mode() {
    [ "${MT_APPLY:-}" = "1" ]
}

# -----------------------------------------------------------------------------
# mt_dry_run_mode
#
# Returns 0 iff MT_DRY_RUN=1; returns 1 otherwise. Use as a guard:
#
#   if mt_dry_run_mode; then
#       mt_log "skipping side effect because we're in dry-run"
#   fi
mt_dry_run_mode() {
    [ "${MT_DRY_RUN:-}" = "1" ]
}
