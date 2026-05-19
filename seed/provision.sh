#!/usr/bin/env bash
#
# seed/provision.sh — Top-level Seed_Script orchestrator (task 24.3).
#
# Stands up lightweight, seed-grade versions of the seven source services
# the Migration_Tool migrates (AWS Glue, Amazon SNS, Apache Flink on Kinesis
# Data Analytics, Kafka / Amazon MSK, AWS Lambda, Amazon CloudWatch, Amazon
# QuickSight, and Amazon MWAA) inside the SAME AWS account that the
# Migration_Tool will later target. Bash-only; calls AWS CLI exclusively
# through the `sbx_aws` helper from `_lib/common.sh` — no Python at runtime
# beyond the inline python3 helper used for first-run config prompting and
# atomic JSON read/write below (Requirement 19.1, 20.10, 20.12).
#
# Independent of the Migration_Tool: separate config (./seed/seed.config.json),
# state (./seed/seed.state.json), logs (./seed/logs/), helper library
# (./seed/_lib/), and env-var prefix (SBX_*, read as "source-bootstrap"). The
# only permitted Seed → Migration interaction is a READ of `source_account_id`
# from `./config/migration.config.json` for the same-account contract check
# (Requirement 20.25, Requirement 20.28).
#
# Provisioning order (Requirement 20.7, encoded inline below — Property 22a):
#
#   glue --phase=foundation → rds → glue --phase=rds-bridge → sns → msk
#                          → kinesis → data-gen → firehose
#                          → glue --phase=crawler → glue --phase=kafka
#                          → lambda → cloudwatch → mwaa
#
# Phase ordering rationale:
#   * `glue --phase=foundation` lays down the data bucket + sample
#     CSVs, IAM roles, both Glue databases (raw + curated), the JDBC
#     connection (placeholder URL, RDS not yet up), the NETWORK
#     connection, and the glueetl + pythonshell Glue jobs. The two
#     foundation jobs are RUN synchronously so curated/orders_parquet
#     and curated/customers_csv_parquet exist before the crawler runs.
#   * `rds` provisions the postgres seed database AFTER glue
#     foundation so glue's JDBC connection placeholder can be rewired
#     to a real endpoint in the next phase.
#   * `glue --phase=rds-bridge` rewires the JDBC connection from
#     placeholder to the real RDS endpoint, registers the rds-to-parquet
#     Glue job, and runs that job synchronously so curated/customers/
#     and curated/products/ are populated.
#   * `kinesis`, `msk`, and `data-gen` come after rds-bridge so the
#     sources are real ARNs by the time firehose binds to them.
#   * `firehose` runs AFTER data-gen (so live events are flowing) and
#     PRE-REGISTERS the two raw Glue catalog tables that
#     DataFormatConversionConfiguration requires.
#   * `glue --phase=crawler` creates and runs the Glue crawler over
#     the now-populated curated zone, discovering real tables.
#   * `glue --phase=kafka` registers the KAFKA Glue connection bound
#     to MSK's bootstrap brokers; this is what flips glue to Available.
#   * `mwaa` is LAST because its provisioning is the long pole
#     (typically 20–30 min in apply mode).
#
# What this orchestrator does NOT do (Requirement 20.30):
#
#   - It does NOT create a SMUS_Domain. It NEVER invokes
#     `aws datazone create-domain`.
#   - It does NOT create an Admin_Project. It NEVER invokes
#     `aws datazone create-project`.
#   - It does NOT issue any AWS CLI command targeting the SMUS_Domain ID or
#     Admin_Project ID recorded in `./config/migration.config.json`
#     (Requirement 20.32). Those calls belong exclusively to the
#     Migration_Tool's Step 1.
#
# This file enforces 20.30 by construction: it never issues any `aws`
# invocation directly (every AWS call lives in a per-service create.sh) and
# the strings `aws datazone create-domain` / `aws datazone create-project`
# do not appear anywhere in this script — see the Property 22h static check
# in `tests/property/`.
#

set -euo pipefail

# -----------------------------------------------------------------------------
# Resolve absolute paths from this script's location so the orchestrator can
# be invoked from any cwd. The grandparent dir of provision.sh is the
# workspace root that hosts both ./seed/ and ./config/ (where the
# same-account check reads from). Setting SBX_WORKDIR before sourcing
# common.sh lets that library's __sbx_resolve_paths use it directly.
__provision_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SBX_WORKDIR="${SBX_WORKDIR:-$(dirname "$__provision_dir")}"
export SBX_WORKDIR

# shellcheck source=./_lib/common.sh disable=SC1091
source "${__provision_dir}/_lib/common.sh"

# -----------------------------------------------------------------------------
# Inline python3 helper: prompt for missing fields, validate, atomically write
# (Requirement 20.10, 20.12). Run only when seed.config.json is absent.
#
# python3 is used here for three reasons:
#   1. Bullet-proof JSON construction (escapes whatever the operator types).
#   2. POSIX `os.replace` gives a true atomic rename so a SIGKILL between
#      write and rename never leaves a partial config on disk.
#   3. /dev/tty access for prompts that survive a piped invocation.
# -----------------------------------------------------------------------------

_bootstrap_seed_config() {
    local _cfg
    _cfg="$(sbx_config_path)"
    if [ -f "$_cfg" ]; then
        return 0
    fi

    printf 'seed.config.json not found at %s; running first-run prompts\n' "$_cfg" >&2
    mkdir -p "$(dirname "$_cfg")"

    SBX_CFG_PATH="$_cfg" python3 - <<'PY'
import json
import os
import re
import sys

cfg_path = os.environ["SBX_CFG_PATH"]
tmp_path = cfg_path + ".tmp"

# Prompts must come from /dev/tty so they cannot be silently swallowed by a
# piped invocation. Surface a clear failure when no controlling terminal is
# available (e.g. CI without `-it`) instead of hanging on stdin.
try:
    tty = open("/dev/tty", "r+")
except OSError:
    sys.stderr.write(
        "STATUS: error seed.config.json missing and no TTY available for first-run prompts\n"
    )
    sys.exit(64)


def _prompt(label, pattern, error_msg):
    """Loop until the operator types a value matching `pattern`."""
    rx = re.compile(pattern)
    while True:
        tty.write(label + ": ")
        tty.flush()
        line = tty.readline()
        if not line:
            sys.stderr.write("STATUS: error EOF on /dev/tty during prompt\n")
            sys.exit(64)
        value = line.strip()
        if rx.fullmatch(value):
            return value
        tty.write(error_msg + "\n")
        tty.flush()


# Requirement 20.10: validate seed_name_prefix (lowercase letters, digits,
# hyphens), aws_region (^[a-z]{2}-[a-z]+-\d$), source_account_id (12 digits).
prefix = _prompt(
    "seed_name_prefix (lowercase letters, digits, hyphens)",
    r"[a-z0-9][a-z0-9-]*",
    "invalid seed_name_prefix; expected ^[a-z0-9][a-z0-9-]*$",
)
region = _prompt(
    "aws_region (e.g. us-east-1)",
    r"[a-z]{2}-[a-z]+-\d",
    "invalid aws_region; expected ^[a-z]{2}-[a-z]+-\\d$",
)
account = _prompt(
    "source_account_id (12 digits)",
    r"\d{12}",
    "invalid source_account_id; expected exactly 12 digits",
)

# Build the JSON document and write atomically via temp + fsync + os.replace
# (Requirement 20.12 — durable persistence before any AWS CLI call).
doc = {
    "version": 1,
    "seed_name_prefix": prefix,
    "aws_region": region,
    "source_account_id": account,
}
with open(tmp_path, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2, sort_keys=True)
    f.write("\n")
    f.flush()
    os.fsync(f.fileno())
os.replace(tmp_path, cfg_path)
PY

    sbx_status set "seed.config.json bootstrapped at ${_cfg}"
}

# -----------------------------------------------------------------------------
# Load `seed_name_prefix`, `aws_region`, `source_account_id` from
# seed.config.json into SBX_* env vars so per-service modules see them
# (task 24.3 contract). The orchestrator then exports SBX_REGION,
# SBX_SOURCE_ACCOUNT_ID, and SBX_SEED_NAME_PREFIX.
#
# Robust JSON parsing routes through python3 (already a dependency of the
# atomic-write step above) so a stray quote in seed.config.json cannot
# corrupt the shell environment.
# -----------------------------------------------------------------------------

_load_seed_config() {
    local _cfg
    _cfg="$(sbx_config_path)"
    if [ ! -f "$_cfg" ]; then
        sbx_status error "seed.config.json missing at ${_cfg}"
        exit 64
    fi

    # python3 prints exactly three lines, in known order. Use IFS= read -r
    # to capture each line verbatim with no field splitting or backslash
    # interpretation.
    local _values
    _values="$(SBX_CFG_PATH="$_cfg" python3 - <<'PY'
import json
import os
import sys

with open(os.environ["SBX_CFG_PATH"], encoding="utf-8") as f:
    doc = json.load(f)

print(doc.get("seed_name_prefix") or "")
print(doc.get("aws_region") or "")
print(doc.get("source_account_id") or "")
PY
)" || {
        sbx_status error "failed to parse ${_cfg} as JSON"
        exit 64
    }

    {
        IFS= read -r SBX_SEED_NAME_PREFIX
        IFS= read -r SBX_REGION
        IFS= read -r SBX_SOURCE_ACCOUNT_ID
    } <<EOF
${_values}
EOF
    export SBX_SEED_NAME_PREFIX SBX_REGION SBX_SOURCE_ACCOUNT_ID
}

# -----------------------------------------------------------------------------
# _enforce_same_account_contract
#
# Same-account contract (Requirement 20.28). The task spec for 24.3
# explicitly requires "a clear error message naming both values if they
# disagree", so this orchestrator-level wrapper supersedes the terser
# `sbx_assert_same_account` helper from common.sh: it prints both
# source_account_id values inline on mismatch so the operator can see the
# conflict directly in the STATUS line without inspecting two config files.
#
# Behaviour:
#   - migration.config.json absent → silent no-op (the Migration_Tool has
#     not run yet, so there is nothing to compare against).
#   - migration.config.json present but source_account_id unset (the
#     Migration_Tool's first-run prompt has not collected it) → silent
#     no-op; the contract only fails when BOTH files declare a value AND
#     they disagree.
#   - Both values declared and matching → silent no-op (well, one
#     `STATUS: ok same-account-check` line for log-stream readability).
#   - Both values declared and mismatched → `STATUS: error
#     same_account_contract_violated seed=<a> migration=<b>` and exit 65.
#
# Exit code 65 (rather than the bare 64 used elsewhere for input-validation
# failures) lets a parent CI distinguish a contract violation from a missing
# var or malformed flag set, while still being non-zero.
# -----------------------------------------------------------------------------

_enforce_same_account_contract() {
    local _seed_account="${SBX_SOURCE_ACCOUNT_ID:-}"
    local _migration_cfg="${SBX_WORKDIR}/config/migration.config.json"

    if [ -z "$_seed_account" ]; then
        # Defensive — sbx_init should already have rejected an empty value
        # via sbx_require_var. Surface it here too in case a future refactor
        # ever moves the check.
        sbx_status missing_var SBX_SOURCE_ACCOUNT_ID
        exit 64
    fi

    if [ ! -f "$_migration_cfg" ]; then
        sbx_status ok "same-account-check migration.config.json absent; seed source_account_id=${_seed_account}"
        return 0
    fi

    local _migration_account
    _migration_account="$(SBX_MIGRATION_CFG="$_migration_cfg" python3 - <<'PY'
import json
import os
import sys

try:
    with open(os.environ["SBX_MIGRATION_CFG"], encoding="utf-8") as f:
        doc = json.load(f)
except (OSError, json.JSONDecodeError):
    print("")
    sys.exit(0)

print(doc.get("source_account_id") or "")
PY
)"

    if [ -z "$_migration_account" ]; then
        sbx_status ok "same-account-check migration.config.json present but source_account_id unset; seed source_account_id=${_seed_account}"
        return 0
    fi

    if [ "$_seed_account" != "$_migration_account" ]; then
        # The STATUS line names BOTH values verbatim (task 24.3 spec) so a
        # human reading the log can see exactly which side has the wrong
        # account ID without rummaging through the two config files.
        sbx_status error "same_account_contract_violated seed.config.json source_account_id=${_seed_account} config/migration.config.json source_account_id=${_migration_account}; these MUST match (Requirement 20.28). Halting before any state-changing AWS CLI command."
        exit 65
    fi

    sbx_status ok "same-account-check source_account_id=${_seed_account} matches in seed.config.json and config/migration.config.json"
}

# -----------------------------------------------------------------------------
# State-file progress helper.
#
# `_persist_module_status <service> <status>` deep-merges
# `{status, last_updated_utc}` into `.services.<service>` of seed.state.json
# via `sbx_state_set_service`'s atomic write. The deep-merge preserves any
# `resources` or `phase` sub-objects the per-service create.sh may have
# written under `.services.<service>.resources`, so the orchestrator's
# top-level status overlay is safe to apply between modules without
# clobbering per-module state (Requirement 20.12 — "persist resource
# identifiers before issuing any further state-changing AWS CLI command").
#
# Status vocabulary used by the orchestrator:
#   - "in_progress"      : module just started (after `STATUS: in-progress`)
#   - "provisioned"      : module reported Available
#   - "failed"           : module exited non-zero
#   - "<phase>_done"     : interim phase complete; Available will not be
#                          announced until the matching `final` phase also
#                          succeeds. Concrete values today: foundation_done,
#                          rds_bridge_done, crawler_done. The legacy
#                          phase1_done value is preserved for backwards
#                          compat with state files written before the
#                          four-phase glue refactor.
# -----------------------------------------------------------------------------

_utc_now() {
    date -u +'%Y-%m-%dT%H:%M:%SZ'
}

_persist_module_status() {
    local _service="$1"
    local _status="$2"
    # Bug fix 1a: state writes happen ONLY in apply mode. The
    # orchestrator's between-modules status overlay would otherwise
    # populate `.services.<svc>.status = "in_progress"` on a dry-run,
    # making `--skip-completed` flip future modules' decisions in ways
    # that don't match what AWS contains.
    if ! sbx_apply_mode; then
        return 0
    fi
    local _now
    _now="$(_utc_now)"
    # Build the JSON payload with python3 so the timestamp escaping and the
    # status-key encoding are bullet-proof (jq is also fine but python3 is
    # already a hard dep above). The payload is intentionally minimal: just
    # the two top-level fields. Nested resource maps come from per-service
    # create.sh writes and are preserved by sbx_state_set_service's `*`
    # deep-merge.
    local _payload
    _payload="$(SBX_STATUS="$_status" SBX_NOW="$_now" python3 -c 'import json, os; print(json.dumps({"status": os.environ["SBX_STATUS"], "last_updated_utc": os.environ["SBX_NOW"]}))')"
    sbx_state_set_service "$_service" "$_payload"
}

# -----------------------------------------------------------------------------
# _extract_phase_from_args
#
# Find the LAST `--phase=<value>` token in the argument list and echo its
# `<value>`. Used by `_run_module` to derive a phase-specific interim
# status string (e.g. `foundation_done`, `rds_bridge_done`,
# `crawler_done`) for the four-phase glue contract.
#
# Returns empty when no `--phase=` flag is present.
# -----------------------------------------------------------------------------
_extract_phase_from_args() {
    local _last=""
    local _arg
    for _arg in "$@"; do
        case "$_arg" in
            --phase=*) _last="${_arg#--phase=}" ;;
        esac
    done
    printf '%s' "$_last"
}

# -----------------------------------------------------------------------------
# _invoke_create_sh <service> [<extra args...>]
#
# Execute (apply mode) or print (dry-run mode) the per-service create.sh
# invocation. Threads the orchestrator's run mode through as the leading
# flag so each module honors exactly the mode the operator selected.
#
#   apply mode:  bash seed/<svc>/create.sh --apply [extra args]
#   dry-run:     prints `DRY-RUN: bash seed/<svc>/create.sh --dry-run [args]`
#                without executing the child. This matches the acceptance
#                criterion in task 24.3 and lets dry-run runs succeed even
#                before tasks 24.5–24.12 land their per-service create.sh
#                files.
#
# Returns the child's exit code in apply mode; 0 in dry-run mode.
# -----------------------------------------------------------------------------

_invoke_create_sh() {
    local _service="$1"
    shift
    local _create_sh="${SBX_SEED_DIR}/${_service}/create.sh"

    local _flag="--dry-run"
    if [ "${SBX_APPLY:-}" = "1" ]; then
        _flag="--apply"
    fi

    if [ "${SBX_DRY_RUN:-}" = "1" ]; then
        # Render a single DRY-RUN line listing the exact would-be child
        # invocation. Use an array of args so spaces/quotes are preserved
        # in the printed form.
        local _args=("$_create_sh" "$_flag" "$@")
        printf 'DRY-RUN: bash'
        local _arg
        for _arg in "${_args[@]}"; do
            printf ' %s' "$_arg"
        done
        printf '\n'
        return 0
    fi

    if [ ! -f "$_create_sh" ]; then
        sbx_status error "${_service} create.sh missing at ${_create_sh}"
        return 127
    fi

    # `bash <path>` rather than ./<path> so a freshly-cloned tree without
    # the executable bit set still works. SBX_* exports propagate to the
    # child (region, account ID, prefix, log path, apply/dry-run flags).
    bash "$_create_sh" "$_flag" "$@"
}

# -----------------------------------------------------------------------------
# _run_module <service> [final|interim] [<extra args...>]
#
# Standard halt-on-fail wrapper around _invoke_create_sh. Honors the four
# STATUS transitions the task spec explicitly calls out (begin /
# in-progress / available / failed) and persists per-module progress to
# seed.state.json BETWEEN modules so a SIGKILL between two modules leaves
# a recoverable state file.
#
# Disposition modes (second positional, optional):
#   - "final" (default) : module is expected to be Available when create.sh
#                          returns 0. Persists `provisioned` and emits
#                          `STATUS: available <service>`.
#   - "interim"          : module is intentionally NOT Available yet —
#                          used for any phase of glue except the
#                          terminal `kafka` phase. Persists a
#                          phase-specific status (`<phase>_done` with
#                          dashes converted to underscores: e.g.
#                          `foundation_done`, `rds_bridge_done`,
#                          `crawler_done`). The `available` STATUS line
#                          is deferred until the matching `final` phase.
#
# Status flow (happy path, final disposition):
#   STATUS: begin <service>
#   STATUS: in-progress <service>
#   <child create.sh runs, writes its resources to seed.state.json>
#   STATUS: available <service>
#
# Status flow (failure):
#   STATUS: begin <service>
#   STATUS: in-progress <service>
#   <child create.sh returns non-zero>
#   STATUS: failed <service> exit=<code>
#   <orchestrator exits with the same code>
# -----------------------------------------------------------------------------

_run_module() {
    local _service="$1"
    shift
    local _disposition="final"
    if [ "${1:-}" = "final" ] || [ "${1:-}" = "interim" ]; then
        _disposition="$1"
        shift
    fi

    sbx_status begin "$_service"
    _persist_module_status "$_service" in_progress
    sbx_status in-progress "$_service"

    # `|| _rc=$?` deliberately suppresses set -e for this single call so the
    # orchestrator can emit the failure STATUS line and propagate the exit
    # code itself. Without this suppression set -e would terminate the
    # script before sbx_status had a chance to record the failure.
    local _rc=0
    _invoke_create_sh "$_service" "$@" || _rc=$?

    if [ "$_rc" -ne 0 ]; then
        _persist_module_status "$_service" failed
        sbx_status failed "${_service} exit=${_rc}"
        exit "$_rc"
    fi

    if [ "$_disposition" = "interim" ]; then
        # Phase-X-style step: progress is acknowledged but the service is
        # not yet Available. The `available` STATUS line is intentionally
        # deferred until the matching `final` phase completes. Persist a
        # phase-specific status so a re-run's --skip-completed gate can
        # tell which phases are already done.
        local _phase
        _phase="$(_extract_phase_from_args "$@")"
        local _interim_status="phase1_done"
        if [ -n "$_phase" ]; then
            # Convert dashes in phase names to underscores so the
            # resulting status is a single token (e.g. rds-bridge →
            # rds_bridge_done). This matches the lattice _should_skip_service
            # in seed.sh hardcodes.
            _interim_status="${_phase//-/_}_done"
        fi
        _persist_module_status "$_service" "$_interim_status"
        sbx_log "${_service} interim phase=${_phase:-(unspecified)} complete; deferring 'available' until final phase (status=${_interim_status})"
    else
        _persist_module_status "$_service" provisioned
        sbx_status available "$_service"
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

# Step 1. Bootstrap config (prompt on first run) and load values into SBX_*
# env vars. This MUST happen before sbx_init, because sbx_init validates
# SBX_REGION / SBX_SOURCE_ACCOUNT_ID / SBX_SEED_NAME_PREFIX. The task spec
# explicitly forbids modifying _lib/common.sh, so the only working order is:
# read config → export vars → sbx_init.
_bootstrap_seed_config
_load_seed_config

# Step 2. sbx_init parses --apply / --dry-run from this script's argv,
# enforces the mutual-exclusion rule (Requirement 20.4 — `--apply` together
# with `--dry-run` exits 64), defaults to dry-run when neither is given
# (Requirement 20.2), creates ./seed/logs/, sets SBX_LOG_PATH for this
# invocation, and (in apply mode) tees stdout/stderr through it
# (Requirement 20.14). It also re-validates the three SBX_* vars we just
# loaded so a malformed seed.config.json surfaces a `STATUS: missing_var`
# line before any module runs.
sbx_init provision "$@"

sbx_status started

# Step 3. Same-account contract enforcement (Requirement 20.28). The
# orchestrator-level wrapper names BOTH source_account_id values on
# mismatch (task 24.3 spec: "clear error message naming both values if
# they disagree"); this supersedes the terser `sbx_assert_same_account`
# which is what each per-service create.sh uses for its own pre-flight
# check. No-op when migration.config.json is absent (the Migration_Tool
# has not run yet, so there is nothing to compare against).
_enforce_same_account_contract

# Step 4. Per-service modules in canonical order (Requirement 20.7).
#
# Post-resequencing 13-step provision sequence:
#
#   glue --phase=foundation  (interim)
#   rds                      (final)
#   glue --phase=rds-bridge  (interim)
#   sns                      (final)
#   msk                      (final)
#   kinesis                  (final)
#   data-gen                 (final)
#   firehose                 (final)
#   glue --phase=crawler     (interim)
#   glue --phase=kafka       (final — flips glue to provisioned)
#   lambda                   (final)
#   cloudwatch               (final)
#   mwaa                     (final, LAST — long pole)
#
# Notes on the ordering:
#   - `glue --phase=foundation` lays down S3 bucket + sample CSVs + IAM
#     roles + databases + JDBC + NETWORK connections + glueetl/pythonshell
#     jobs, and RUNS those jobs synchronously so the curated zone of
#     S3 actually contains real Parquet by the end of the phase.
#   - `rds` provisions the postgres seed instance; its endpoint and
#     master password get persisted to seed.state.json.
#   - `glue --phase=rds-bridge` rewires the JDBC connection from the
#     placeholder URL to the real RDS endpoint, then registers and runs
#     the rds-to-parquet Glue job. After this phase, every curated/*
#     prefix has data and the crawler will discover real tables.
#   - `data-gen` runs BEFORE `firehose` (post-resequencing): firehose
#     reads from kinesis + msk that data-gen writes to, so the firehose
#     delivery streams come up with live data already flowing.
#   - `firehose` pre-registers the two raw catalog tables
#     (<prefix>_kinesis_events_parquet, <prefix>_msk_events_parquet) in
#     <prefix>-db-raw before creating the delivery streams (Firehose's
#     DataFormatConversionConfiguration hard-requires a Glue table at
#     create time).
#   - `glue --phase=crawler` creates and runs the Glue crawler over the
#     curated zone now that real Parquet exists; the crawler discovers
#     <prefix>_orders_parquet, <prefix>_customers_csv_parquet, and the
#     two rds-to-parquet outputs.
#   - `glue --phase=kafka` registers the KAFKA Glue connection bound to
#     MSK's bootstrap broker string and flips glue to `provisioned`.
#   - `mwaa` runs LAST (Requirement 20.7) because its environment
#     provisioning is the long pole (typically 20–30 min in apply mode).
#
# Halt-on-fail: the first non-zero exit from any module emits
# `STATUS: failed <service> exit=<code>` and propagates the child exit
# code; later modules are skipped. Per-module progress is persisted to
# seed.state.json BETWEEN modules (in_progress / provisioned / failed /
# foundation_done / rds_bridge_done / crawler_done) so a re-run can
# resume from a known point.
#
# Reminder (Requirement 20.30): nothing below issues `aws datazone
# create-domain` or `aws datazone create-project`. The Seed_Script never
# creates a SMUS_Domain or Admin_Project; those are owned exclusively by
# the Migration_Tool's Step 1.

_run_module network
_run_module glue interim --phase=foundation
_run_module rds
_run_module glue interim --phase=rds-bridge
_run_module sns
_run_module msk
_run_module kinesis
_run_module data-gen
_run_module firehose
_run_module glue interim --phase=crawler
_run_module glue final --phase=kafka
_run_module lambda
_run_module cloudwatch
_run_module mwaa    # LAST — Requirement 20.7 (long pole)

sbx_status ok "seed provisioning complete; all 13 modules Available"
