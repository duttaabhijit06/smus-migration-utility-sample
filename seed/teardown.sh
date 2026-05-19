#!/usr/bin/env bash
#
# seed/teardown.sh — Top-level Seed_Script teardown orchestrator (Task 24.4).
#
# Counterpart to seed/provision.sh. Invokes each Seed_Service_Module's
# teardown.sh in the EXACT REVERSE of the provisioning order from task 24.3
# / Requirement 20.7 (Requirement 20.8). Bash-only — calls AWS CLI through
# per-service teardown scripts; never invokes Python and never calls aws
# directly from this orchestrator (Requirement 19.1).
#
# Reverse-of-provision order (10 invocations; the four-phase glue
# contract from the resequencing refactor collapses into a single glue
# teardown call):
#
#     mwaa
#     cloudwatch
#     lambda
#     firehose          ← deleted BEFORE its sources (kinesis, msk, data-gen)
#                         so it stops consuming live records first
#     data-gen          ← stops generating new records into kinesis/msk
#     kinesis
#     msk
#     sns
#     rds
#     glue              ← single pass: kafka connection + JDBC + NETWORK
#                         + jobs + crawler + databases + S3 bucket. The
#                         pre-resequencing two-phase split is gone.
#
# This script is a thin sequencer. The hard work — discovering what was
# provisioned and gating each `aws ... delete-*` call against BOTH the
# `${SBX_SEED_NAME_PREFIX}-` name prefix AND the seed.state.json membership
# check (Requirement 20.31) — lives in each per-service teardown.sh. The
# orchestrator's responsibilities are:
#
#   1. Source `seed/_lib/common.sh`.
#   2. Read `seed/seed.config.json` (must exist; halt with
#      `STATUS: error config_missing` and exit 64 if not).
#   3. Export SBX_REGION / SBX_SOURCE_ACCOUNT_ID / SBX_SEED_NAME_PREFIX so
#      sbx_init's required-var checks pass and per-service teardown
#      subprocesses inherit them.
#   4. Call `sbx_init "teardown" "$@"` to parse --apply / --dry-run
#      (default dry-run, mutually exclusive — Requirement 20.4) and open
#      the per-invocation log under ./seed/logs/run-<UTC>.log
#      (Requirement 20.14).
#   5. Call `sbx_assert_same_account` (Requirement 20.28).
#   6. In apply mode, prompt the operator to retype the literal
#      `seed_name_prefix` from /dev/tty so the prompt cannot be piped past
#      (Requirement 20.6). Mismatch → `STATUS: error confirmation_mismatch`
#      and exit 64 BEFORE any per-service teardown runs.
#   7. Invoke each per-service teardown.sh in the strict reverse order
#      above (Requirement 20.8). Best-effort sequencing: a per-service
#      teardown.sh non-zero exit emits `STATUS: error teardown_failed
#      <module>` and the orchestrator CONTINUES with the remaining
#      services. Exit non-zero at the end iff any module failed.
#   8. Emit `STATUS: started` at the top and `STATUS: ok` only on full
#      success (no per-service failure).
#
# What this orchestrator does NOT do (Requirement 20.30, 20.32):
#
#   - It does NOT call AWS APIs directly. Every aws invocation flows
#     through a per-service teardown.sh.
#   - It does NOT delete the SMUS_Domain or any Admin_Project; those are
#     the Migration_Tool's responsibility.
#   - It does NOT issue any `aws datazone *` command.
#   - It does NOT delete `seed/seed.config.json` or `seed/seed.state.json`
#     after teardown. The operator can remove them out-of-band; keeping
#     them around lets a follow-up `--apply` re-run pick up resources the
#     first pass could not delete (e.g. a stuck MWAA environment).
#

set -euo pipefail

# -----------------------------------------------------------------------------
# Resolve the seed root from this script's location so the orchestrator can
# be invoked from any cwd. The grandparent dir of teardown.sh is the
# workspace root that hosts both ./seed/ and ./config/. Setting SBX_WORKDIR
# before sourcing common.sh lets that library's __sbx_resolve_paths use it
# directly without falling back to its own derivation.
__teardown_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SBX_WORKDIR="${SBX_WORKDIR:-$(dirname "$__teardown_dir")}"
export SBX_WORKDIR

# shellcheck source=./_lib/common.sh disable=SC1091
source "${__teardown_dir}/_lib/common.sh"

# -----------------------------------------------------------------------------
# Config-file existence check (BEFORE sbx_init).
#
# Teardown is meaningless without seed.config.json: the prefix confirmation
# prompt below depends on it, sbx_init's required-var validation reads
# values that ultimately come from this file, and sbx_assert_same_account
# reads source_account_id from this file. Halt with the literal STATUS form
# the task spec asks for so callers can grep on the canonical line.
__seed_config_path="$(sbx_config_path)"
if [ ! -f "$__seed_config_path" ]; then
    sbx_status error config_missing
    exit 64
fi

# jq is required to read JSON config and to drive sbx_assert_same_account.
# The whole Seed_Script's state mutations already depend on jq, so this is
# not a new dependency — just a clearer error than letting the jq invocation
# below fail with a less helpful message.
if ! command -v jq >/dev/null 2>&1; then
    sbx_status error jq_required
    exit 64
fi

# -----------------------------------------------------------------------------
# Export the three core SBX_* env vars from seed.config.json BEFORE sbx_init.
# sbx_init's first action is to validate them via sbx_require_var; populating
# them here means a teardown invocation does not have to drag the operator
# through interactive first-run prompts (which would be the wrong UX for a
# destructive command). Per-service teardown.sh subprocesses inherit these
# values without each having to re-parse seed.config.json.
SBX_REGION="$(jq -r '.aws_region // empty' "$__seed_config_path")"
SBX_SOURCE_ACCOUNT_ID="$(jq -r '.source_account_id // empty' "$__seed_config_path")"
SBX_SEED_NAME_PREFIX="$(jq -r '.seed_name_prefix // empty' "$__seed_config_path")"
export SBX_REGION SBX_SOURCE_ACCOUNT_ID SBX_SEED_NAME_PREFIX

# -----------------------------------------------------------------------------
# sbx_init parses --apply / --dry-run (default dry-run, Requirement 20.2),
# enforces mutual exclusion (Requirement 20.4), creates ./seed/logs/, sets
# SBX_LOG_PATH, and (in apply mode) tees stdout/stderr through it
# (Requirement 20.14). After this call SBX_APPLY / SBX_DRY_RUN reflect the
# resolved mode. Any of SBX_REGION / SBX_SOURCE_ACCOUNT_ID /
# SBX_SEED_NAME_PREFIX missing → `STATUS: missing_var <NAME>` + exit 64.
sbx_init "teardown" "$@"

# Tee dry-run output into the same per-invocation log so Requirement 20.14
# ("one timestamped log file per invocation") holds for both modes. sbx_init
# only opens the tee in apply mode; here we extend it to dry-run so the
# `DRY-RUN: ...` lines emitted by per-service teardown.sh subprocesses also
# land in the log.
if sbx_dry_run_mode; then
    exec > >(tee -a "$SBX_LOG_PATH") 2>&1
fi

# -----------------------------------------------------------------------------
# Same-account contract (Requirement 20.28).
#
# Reads source_account_id from seed.config.json AND from
# config/migration.config.json (when present). On mismatch halts with
# `STATUS: error same_account_contract_violated` and exit 64 BEFORE any
# state-changing AWS CLI command. Silent on the happy path. The library
# helper centralises this so each create.sh / teardown.sh need only call
# `sbx_assert_same_account`.
sbx_assert_same_account

# -----------------------------------------------------------------------------
# Apply-mode confirmation prompt (Requirement 20.6).
#
# Prompt the operator to retype the literal seed_name_prefix from
# seed.config.json BEFORE any per-service teardown.sh is invoked. Read from
# /dev/tty so a piped or redirected stdin (e.g. `yes | bash teardown.sh
# --apply`) cannot bypass the prompt. Mismatch → `STATUS: error
# confirmation_mismatch` and exit 64 BEFORE any per-service teardown runs.
# Dry-run mode skips the prompt entirely since no destructive command
# will run.
#
# A missing /dev/tty (no controlling terminal, e.g. running under a CI
# job) is treated as confirmation_mismatch — refusing rather than silently
# proceeding, since the prompt cannot be answered.
if sbx_apply_mode; then
    if [ ! -e /dev/tty ]; then
        # No controlling terminal → cannot prompt → refuse. Emit the
        # canonical STATUS line on stdout (mirrored by the apply-mode tee
        # into the per-invocation log).
        sbx_status error confirmation_mismatch
        exit 64
    fi

    printf 'WARNING: --apply teardown will delete every seed-created resource whose name begins with "%s-" AND whose ARN/ID is recorded in seed/seed.state.json.\n' \
        "$SBX_SEED_NAME_PREFIX" > /dev/tty
    printf 'Retype the seed_name_prefix EXACTLY to proceed (or anything else to abort): ' > /dev/tty

    # Default to empty so a `read` failure (EOF on /dev/tty) does not trip
    # `set -u`. `read -r` returns non-zero on EOF which would also trip
    # `set -e`, so we tolerate that with `|| true` and let the equality
    # check below decide whether to proceed.
    _typed=""
    IFS= read -r _typed < /dev/tty || true

    if [ "$_typed" != "$SBX_SEED_NAME_PREFIX" ]; then
        # Emit the canonical STATUS line on stdout (which the apply-mode
        # tee opened by sbx_init mirrors into the per-invocation log).
        # Also echo the same line to /dev/tty so the operator sees it on
        # the terminal even before the tee subshell drains its buffer at
        # exit — bash's `exec > >(tee -a ...)` redirection can otherwise
        # drop the last line on an immediate `exit` because the parent
        # shell does not `wait` for process substitutions.
        sbx_status error confirmation_mismatch
        printf 'STATUS: error confirmation_mismatch\n' > /dev/tty
        exit 64
    fi
fi

# -----------------------------------------------------------------------------
# Per-service teardown dispatch (best-effort sequencing).
# -----------------------------------------------------------------------------

# FAILED_MODULES accumulates a label per per-service failure. The
# orchestrator exits non-zero at the end iff this array is non-empty (per
# task spec: "Exit non-zero at the end if any module failed."). Declared
# up front so `set -u` is happy when the array is later inspected via
# ${#FAILED_MODULES[@]}.
declare -a FAILED_MODULES=()

# _invoke_teardown <module> [<extra args>...]
#
# Run `bash ./seed/<module>/teardown.sh --apply|--dry-run [extra args]`.
# Best-effort: a non-zero exit (or a missing per-service script) is recorded
# in FAILED_MODULES and the orchestrator continues with the next service
# (per task spec: "on any per-service teardown failure, log a `STATUS:
# error teardown_failed <module>` line but continue with the rest of the
# reverse order").
#
# The label argument joins the module name with any extra args (e.g.
# `glue --phase=2`) so the failure STATUS line names the exact phase. This
# is also what shows up in the final summary so a partial-success run is
# easy to triage.
_invoke_teardown() {
    local _module="$1"
    shift
    local _label="$_module"
    if [ "$#" -gt 0 ]; then
        _label="${_module} $*"
    fi

    local _path="${__teardown_dir}/${_module}/teardown.sh"
    if [ ! -f "$_path" ]; then
        # A missing per-service teardown.sh means the orchestrator cannot
        # fulfil the reverse-order contract for this module. Treat as a
        # failure for exit-code purposes but do NOT halt the overall run —
        # best-effort dispatch continues with the next module.
        sbx_status error "teardown_failed ${_label} (script missing at ${_path})"
        FAILED_MODULES+=("$_label")
        return 0
    fi

    local _flag="--dry-run"
    if sbx_apply_mode; then
        _flag="--apply"
    fi

    sbx_log "invoking teardown ${_module} ${_flag}$([ "$#" -gt 0 ] && printf ' %s' "$*" || true)"

    # Capture exit without tripping `set -e`. Using `|| _rc=$?` keeps the
    # command in a context where errexit is suppressed for the failing
    # branch and lets us report the failure with the correct status code.
    local _rc=0
    bash "$_path" "$_flag" "$@" || _rc=$?

    if [ "$_rc" -ne 0 ]; then
        sbx_status error "teardown_failed ${_label}"
        FAILED_MODULES+=("$_label")
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Main teardown sequence.
# -----------------------------------------------------------------------------

sbx_status started

sbx_log "seed teardown starting (region=${SBX_REGION}, account=${SBX_SOURCE_ACCOUNT_ID}, prefix=${SBX_SEED_NAME_PREFIX}, mode=$(sbx_apply_mode && echo apply || echo dry-run))"

# Strict reverse of the provisioning order (Requirement 20.7 / 20.8).
# The post-resequencing 13-step provision sequence is:
#   glue:foundation → rds → glue:rds-bridge → sns → msk → kinesis →
#   data-gen → firehose → glue:crawler → glue:kafka → lambda →
#   cloudwatch → mwaa
#
# The strict reverse, with the four glue phases collapsed into a single
# `glue` pass, is:
#   mwaa → cloudwatch → lambda → firehose → data-gen → kinesis → msk →
#   sns → rds → glue
#
# Glue runs ONCE here (not split by phase) because seed/glue/teardown.sh
# is a single-pass implementation that deletes everything regardless of
# phase. data-gen now runs BEFORE firehose in provision (firehose has
# live data flowing through it), so teardown puts firehose BEFORE
# data-gen — firehose consumes from kinesis/msk; deleting it first
# stops consumption before its sources go away.
_invoke_teardown mwaa
_invoke_teardown cloudwatch
_invoke_teardown lambda
_invoke_teardown firehose
_invoke_teardown data-gen
_invoke_teardown kinesis
_invoke_teardown msk
_invoke_teardown sns
_invoke_teardown rds
_invoke_teardown glue
_invoke_teardown network

# -----------------------------------------------------------------------------
# Summary.
# -----------------------------------------------------------------------------

if [ "${#FAILED_MODULES[@]}" -gt 0 ]; then
    # Surface a single summary STATUS line listing every failed module so a
    # caller parsing STATUS lines does not have to reconstruct the failure
    # set from the per-module `teardown_failed` lines emitted earlier.
    sbx_status error "teardown completed with failures: ${FAILED_MODULES[*]}"
    exit 1
fi

sbx_status ok
