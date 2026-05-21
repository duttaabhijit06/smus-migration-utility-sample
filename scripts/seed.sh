#!/usr/bin/env bash
#
# seed.sh — Single-entry-point CLI for the SageMaker Seed_Script.
#
# Wraps the per-service modules under ./seed/<service>/{create,teardown}.sh
# so you can provision or tear down the seed surface in ONE command, with
# switches to pick which services to include or skip.
#
# The canonical order (Requirement 20.7) is preserved on every run:
#
#   provision: glue(foundation) → rds → glue(rds-bridge) → sns → msk → kinesis
#                       → data-gen → firehose → glue(crawler) → glue(kafka)
#                       → lambda → cloudwatch → mwaa
#   teardown:  strict reverse — single glue pass last
#
# Default mode is dry-run. Pass --apply to actually do it.
# Default service set is --all (every service in canonical order).
#
# Examples:
#   ./seed.sh provision --apply
#   ./seed.sh provision --skip-mwaa --apply             # everything except MWAA
#   ./seed.sh provision --glue --rds --apply            # only glue + rds
#   ./seed.sh provision --all --skip mwaa --skip msk    # everything except MWAA + MSK
#   ./seed.sh teardown  --all --apply
#   ./seed.sh teardown  --data-gen --mwaa --apply
#   ./seed.sh status                                    # show seed.state.json summary
#

set -uo pipefail
# Note: deliberately NOT using `set -e`. The dispatch loops below run
# multiple per-service scripts; a single non-zero from one service
# should NOT abort the whole pipeline. Failures are tallied and
# surfaced at the end via FAILED_SERVICES + a non-zero exit code.

# -----------------------------------------------------------------------------
# Canonical service order (Requirement 20.7).
#
# 13-step provision sequence (post-resequencing). Glue is dispatched
# FOUR times so jobs can run against real data BEFORE the crawler is
# created. The wrapper splits each "service:phase" entry on the first
# colon and passes `--phase=<value>` to the service's create.sh.
# -----------------------------------------------------------------------------
PROVISION_ORDER=(
    "network"
    "glue:foundation"
    "rds"
    "glue:rds-bridge"
    "sns"
    "msk"
    "kinesis"
    "data-gen"
    "firehose"
    "glue:crawler"
    "glue:kafka"
    "lambda"
    "cloudwatch"
    "mwaa"
)
# Strict reverse of provision, with the four glue phases collapsed into
# a single `glue` pass (seed/glue/teardown.sh is single-pass and deletes
# everything regardless of phase). data-gen now precedes firehose in
# provision (firehose has live data flowing through it), so teardown
# puts firehose BEFORE data-gen — firehose consumes from kinesis/msk;
# stopping it first halts ingestion before its sources go away.
TEARDOWN_ORDER=(
    "mwaa"
    "cloudwatch"
    "lambda"
    "firehose"
    "data-gen"
    "kinesis"
    "msk"
    "sns"
    "rds"
    "glue"
    "network"
)
ALL_SERVICES=(network glue rds sns msk kinesis firehose lambda data-gen cloudwatch mwaa)

# -----------------------------------------------------------------------------
# State.
# -----------------------------------------------------------------------------
ACTION=""
MODE_FLAG="--dry-run"          # default — never destroy by accident
SERVICES=()                     # explicit --<svc> selections
SKIPS=()                        # --skip / --skip-mwaa exclusions
PROFILE=""                      # --profile sets AWS_PROFILE for child scripts
REGION=""                       # --region sets AWS_DEFAULT_REGION
ASSUME_YES=0                    # --yes bypasses the destructive prompt on teardown --apply
SKIP_COMPLETED=1                # 1=skip services already provisioned (default); 0=run anyway
FAILED_SERVICES=()              # tally of services that failed in the dispatch loop

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# -----------------------------------------------------------------------------
# usage
# -----------------------------------------------------------------------------
usage() {
    cat <<'EOF'
seed.sh — Single-command CLI for the Seed_Script

Usage:
  ./seed.sh provision [options]    Create seed resources
  ./seed.sh teardown  [options]    Delete seed resources
  ./seed.sh status                 Print summary of seed/seed.state.json

Mode (provision/teardown):
  --apply                          Actually do it (state-changing AWS calls)
  --dry-run                        Print what would be done (default)

Service selection:
  --all                            All 10 services (default if no service flag)
  --glue                           Include glue
  --rds                            Include rds
  --sns                            Include sns
  --msk                            Include msk
  --kinesis                        Include kinesis
  --firehose                       Include firehose
  --lambda                         Include lambda
  --data-gen                       Include data-gen (event generator Lambdas)
  --cloudwatch                     Include cloudwatch
  --mwaa                           Include mwaa
  --skip <name>                    Exclude a service (repeatable)
  --skip-mwaa                      Shorthand: all services except mwaa
                                   (useful — MWAA is the long pole at 20–30 min)
  --skip-completed                 Skip services already finished per
                                   seed/seed.state.json (DEFAULT). On
                                   provision, skip status=provisioned;
                                   for glue, the four-phase lattice
                                   (foundation_done / rds_bridge_done /
                                   crawler_done / provisioned) is
                                   applied per phase. On teardown, skip
                                   status=torn_down.
  --no-skip-completed              Re-run services even when state shows
                                   they are done. The per-resource
                                   idempotency gates still prevent
                                   duplicate creates.
  --force                          Alias for --no-skip-completed.

AWS environment:
  --profile <name>                 Set AWS_PROFILE for child scripts
  --region <region>                Set AWS_DEFAULT_REGION

Safety:
  --yes                            Skip the destructive-confirmation prompt
                                   on teardown --apply (use with care)

Other:
  -h, --help                       Show this message

Examples:
  ./seed.sh provision --apply --profile smus-seed
  ./seed.sh provision --skip-mwaa --apply
  ./seed.sh provision --glue --rds --apply
  ./seed.sh provision --apply --no-skip-completed   # re-run everything
  ./seed.sh teardown --all --apply
  ./seed.sh status

The provisioning order is fixed (Requirement 20.7):
  glue(foundation) -> rds -> glue(rds-bridge) -> sns -> msk -> kinesis
              -> data-gen -> firehose -> glue(crawler) -> glue(kafka)
              -> lambda -> cloudwatch -> mwaa
Teardown order is the strict reverse (single glue pass).
EOF
}

# -----------------------------------------------------------------------------
# Argument parsing.
# -----------------------------------------------------------------------------
if [ $# -eq 0 ]; then
    usage
    exit 0
fi

ACTION="$1"
shift

case "$ACTION" in
    provision|teardown|status) ;;
    -h|--help) usage; exit 0 ;;
    *)
        echo "ERROR: unknown action '$ACTION' (expected: provision | teardown | status)" >&2
        echo "Run with -h for help." >&2
        exit 64
        ;;
esac

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)
            if [ "$MODE_FLAG" = "--dry-run-explicit" ]; then
                echo "ERROR: --apply and --dry-run are mutually exclusive" >&2
                exit 64
            fi
            MODE_FLAG="--apply"; shift ;;
        --dry-run)
            if [ "$MODE_FLAG" = "--apply" ]; then
                echo "ERROR: --apply and --dry-run are mutually exclusive" >&2
                exit 64
            fi
            MODE_FLAG="--dry-run-explicit"; shift ;;
        --all)        SERVICES=("${ALL_SERVICES[@]}"); shift ;;
        --glue)       SERVICES+=(glue); shift ;;
        --rds)        SERVICES+=(rds); shift ;;
        --network)    SERVICES+=(network); shift ;;
        --sns)        SERVICES+=(sns); shift ;;
        --msk)        SERVICES+=(msk); shift ;;
        --kinesis)    SERVICES+=(kinesis); shift ;;
        --firehose)   SERVICES+=(firehose); shift ;;
        --lambda)     SERVICES+=(lambda); shift ;;
        --data-gen)   SERVICES+=(data-gen); shift ;;
        --cloudwatch) SERVICES+=(cloudwatch); shift ;;
        --mwaa)       SERVICES+=(mwaa); shift ;;
        --skip-mwaa)  SERVICES=("${ALL_SERVICES[@]}"); SKIPS+=(mwaa); shift ;;
        --skip-completed)    SKIP_COMPLETED=1; shift ;;
        --no-skip-completed) SKIP_COMPLETED=0; shift ;;
        --force)             SKIP_COMPLETED=0; shift ;;
        --skip)
            if [ $# -lt 2 ]; then
                echo "ERROR: --skip requires a service name" >&2
                exit 64
            fi
            SKIPS+=("$2"); shift 2 ;;
        --profile)
            if [ $# -lt 2 ]; then
                echo "ERROR: --profile requires a name" >&2
                exit 64
            fi
            PROFILE="$2"; shift 2 ;;
        --region)
            if [ $# -lt 2 ]; then
                echo "ERROR: --region requires a region code" >&2
                exit 64
            fi
            REGION="$2"; shift 2 ;;
        --yes)        ASSUME_YES=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)
            echo "ERROR: unknown option '$1'" >&2
            echo "Run with -h for help." >&2
            exit 64
            ;;
    esac
done

# Default service set when none specified.
if [ "${#SERVICES[@]}" -eq 0 ]; then
    SERVICES=("${ALL_SERVICES[@]}")
fi

# Validate every named service is real.
_is_known_service() {
    local needle="$1"
    for s in "${ALL_SERVICES[@]}"; do
        [ "$s" = "$needle" ] && return 0
    done
    return 1
}
for svc in "${SERVICES[@]}"; do
    if ! _is_known_service "$svc"; then
        echo "ERROR: unknown service '$svc' (valid: ${ALL_SERVICES[*]})" >&2
        exit 64
    fi
done
for svc in "${SKIPS[@]:-}"; do
    [ -z "$svc" ] && continue
    if ! _is_known_service "$svc"; then
        echo "ERROR: unknown --skip service '$svc' (valid: ${ALL_SERVICES[*]})" >&2
        exit 64
    fi
done

# Apply skip list and dedupe → ACTIVE is the resolved set.
ACTIVE=()
for svc in "${SERVICES[@]}"; do
    skip=0
    for s in "${SKIPS[@]:-}"; do
        if [ "$svc" = "$s" ]; then skip=1; break; fi
    done
    [ "$skip" -eq 1 ] && continue
    present=0
    for a in "${ACTIVE[@]:-}"; do
        if [ "$a" = "$svc" ]; then present=1; break; fi
    done
    [ "$present" -eq 0 ] && ACTIVE+=("$svc")
done

# Helper: is svc in ACTIVE?
_in_active() {
    local needle="$1"
    for a in "${ACTIVE[@]:-}"; do
        [ "$a" = "$needle" ] && return 0
    done
    return 1
}

# _state_status_for <service>
#
# Echo .services.<svc>.status from seed/seed.state.json, or empty when
# missing. Bracket-notation handles hyphenated service names like
# `flink-kda`. Returns silently on missing jq / missing state file —
# this is a best-effort read used only for the skip-completed gate.
_state_status_for() {
    local svc="$1"
    local state_file="${ROOT_DIR}/seed/seed.state.json"
    if [ ! -f "$state_file" ] || ! command -v jq >/dev/null 2>&1; then
        return 0
    fi
    jq -r --arg s "$svc" '.services[$s].status // empty' "$state_file" 2>/dev/null || true
}

# _should_skip_service <action> <service> [<phase>]
#
# Returns 0 (skip) when --skip-completed is on AND the recorded status
# in seed.state.json indicates the service is already done for the
# requested action.
#
# Glue four-phase status lattice (post-resequencing):
#   foundation  done → status=foundation_done
#   rds-bridge  done → status=rds_bridge_done
#   crawler     done → status=crawler_done
#   kafka       done → status=provisioned (terminal)
#
# Provision skip rules for glue:
#   - For phase=foundation: skip if status ∈ {foundation_done,
#     rds_bridge_done, crawler_done, provisioned}
#   - For phase=rds-bridge: skip if status ∈ {rds_bridge_done,
#     crawler_done, provisioned}
#   - For phase=crawler:    skip if status ∈ {crawler_done, provisioned}
#   - For phase=kafka:      skip if status == provisioned
#
# Provision skip rules for non-glue services:
#   - status=provisioned                → skip
#   - status=phase1_done AND no phase   → skip (legacy alias kept for
#                                          backwards compat with any
#                                          state file written by the
#                                          pre-resequencing code)
#   - any other status                  → run
#
# Teardown skip rules:
#   - status=torn_down                  → skip
#   - any other status                  → run
#
# Returns 1 (do not skip) when --no-skip-completed is set, when the
# state file is missing, or when status indicates pending/failed work.
_should_skip_service() {
    local action="$1" svc="$2" phase="${3:-}"
    [ "$SKIP_COMPLETED" -eq 1 ] || return 1

    local status
    status="$(_state_status_for "$svc")"
    [ -z "$status" ] && return 1

    if [ "$action" = "provision" ]; then
        # Glue uses the four-phase lattice.
        if [ "$svc" = "glue" ]; then
            case "$phase" in
                foundation)
                    case "$status" in
                        foundation_done|rds_bridge_done|crawler_done|provisioned) return 0 ;;
                        *) return 1 ;;
                    esac
                    ;;
                rds-bridge)
                    case "$status" in
                        rds_bridge_done|crawler_done|provisioned) return 0 ;;
                        *) return 1 ;;
                    esac
                    ;;
                crawler)
                    case "$status" in
                        crawler_done|provisioned) return 0 ;;
                        *) return 1 ;;
                    esac
                    ;;
                kafka)
                    case "$status" in
                        provisioned) return 0 ;;
                        *) return 1 ;;
                    esac
                    ;;
                *)
                    # Unknown / unrecognized phase — never skip.
                    return 1
                    ;;
            esac
        fi

        # Non-glue services: simple terminal-status skip.
        case "$status" in
            provisioned) return 0 ;;
            phase1_done)
                # Legacy alias from the pre-resequencing two-phase glue
                # contract; preserved for backwards compat with any
                # state file written before this refactor. Single-phase
                # services do not produce phase1_done themselves.
                return 0
                ;;
            *) return 1 ;;
        esac
    elif [ "$action" = "teardown" ]; then
        case "$status" in
            torn_down) return 0 ;;
            *)         return 1 ;;
        esac
    fi
    return 1
}

# Forward AWS env to child scripts.
if [ -n "$PROFILE" ]; then export AWS_PROFILE="$PROFILE"; fi
if [ -n "$REGION" ];  then export AWS_DEFAULT_REGION="$REGION"; fi

# Hydrate SBX_* env vars from seed.config.json so per-service scripts that
# don't bootstrap themselves (sns, msk, flink-kda, lambda, cloudwatch)
# inherit the region/account/prefix from a single source of truth.
# seed/provision.sh does the same hydration; we mirror it here so direct
# subset invocations through seed.sh see the same behavior.
__seed_cfg="${ROOT_DIR}/seed/seed.config.json"
if [ -f "$__seed_cfg" ] && command -v jq >/dev/null 2>&1; then
    : "${SBX_REGION:=$(jq -r '.aws_region // empty' "$__seed_cfg")}"
    : "${SBX_SOURCE_ACCOUNT_ID:=$(jq -r '.source_account_id // empty' "$__seed_cfg")}"
    : "${SBX_SEED_NAME_PREFIX:=$(jq -r '.seed_name_prefix // empty' "$__seed_cfg")}"
    export SBX_REGION SBX_SOURCE_ACCOUNT_ID SBX_SEED_NAME_PREFIX
fi

# Normalize the explicit-dry-run sentinel to the actual flag the per-
# service scripts expect.
if [ "$MODE_FLAG" = "--dry-run-explicit" ]; then
    MODE_FLAG="--dry-run"
fi


# -----------------------------------------------------------------------------
# status — print a quick summary of seed/seed.state.json.
# -----------------------------------------------------------------------------
if [ "$ACTION" = "status" ]; then
    state_file="${ROOT_DIR}/seed/seed.state.json"
    if [ ! -f "$state_file" ]; then
        echo "No state file at ${state_file} — nothing has been provisioned yet."
        exit 0
    fi
    if command -v jq >/dev/null 2>&1; then
        echo "Seed state (${state_file}):"
        jq -r '
            "  version: \(.version // "?")",
            (.services // {} | to_entries[] |
                "  \(.key | tostring | (. + "                    " | .[0:14]))  status=\(.value.status // "?")  last=\(.value.last_updated_utc // "—")")
        ' "$state_file"
    else
        cat "$state_file"
    fi
    exit 0
fi

# -----------------------------------------------------------------------------
# Destructive-confirmation prompt for teardown --apply.
#
# Mirrors the prompt in seed/teardown.sh so subset teardowns get the same
# safety net. Skipped on --yes (automation).
# -----------------------------------------------------------------------------
if [ "$ACTION" = "teardown" ] && [ "$MODE_FLAG" = "--apply" ] && [ "$ASSUME_YES" -ne 1 ]; then
    seed_cfg="${ROOT_DIR}/seed/seed.config.json"
    expected_prefix=""
    if [ -f "$seed_cfg" ] && command -v jq >/dev/null 2>&1; then
        expected_prefix="$(jq -r '.seed_name_prefix // empty' "$seed_cfg" 2>/dev/null || true)"
    fi
    if [ -z "$expected_prefix" ]; then
        echo "ERROR: cannot read seed_name_prefix from ${seed_cfg}; refusing to teardown without confirmation." >&2
        echo "       (Pass --yes to bypass the confirmation prompt; use only for automation.)" >&2
        exit 64
    fi
    if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
        echo "ERROR: teardown --apply requires a TTY for the confirmation prompt." >&2
        echo "       Pass --yes if you really intend to run non-interactively." >&2
        exit 64
    fi
    {
        echo
        echo "WARNING: about to delete seed resources in:"
        echo "         AWS_PROFILE=${AWS_PROFILE:-<unset>} (services: ${ACTIVE[*]})"
        echo "         seed_name_prefix=${expected_prefix}"
        echo
        printf "Type '%s' verbatim to confirm: " "$expected_prefix"
    } > /dev/tty
    typed=""
    IFS= read -r typed < /dev/tty || typed=""
    if [ "$typed" != "$expected_prefix" ]; then
        echo "ABORTED: prefix mismatch; nothing was deleted." > /dev/tty
        exit 1
    fi
fi

# -----------------------------------------------------------------------------
# Banner.
# -----------------------------------------------------------------------------
echo "==> Action:   $ACTION"
echo "==> Mode:     $MODE_FLAG"
echo "==> Services: ${ACTIVE[*]}"
echo "==> Profile:  ${AWS_PROFILE:-<unset>}"
echo "==> Region:   ${AWS_DEFAULT_REGION:-<from seed.config.json>}"
if [ "$SKIP_COMPLETED" -eq 1 ]; then
    echo "==> Resume:   skip-completed=ON (services with status in {foundation_done,rds_bridge_done,crawler_done,provisioned,torn_down} will be skipped per phase; pass --no-skip-completed to re-run)"
else
    echo "==> Resume:   skip-completed=OFF (every selected service will run)"
fi
echo

# -----------------------------------------------------------------------------
# Dispatch.
#
# We invoke the per-service create.sh / teardown.sh scripts directly via
# `bash`, the same way seed/provision.sh and seed/teardown.sh do. Each
# per-service script enforces its own same-account contract and prefix
# gate via sbx_init + sbx_assert_same_account, so safety is preserved
# even when called outside the orchestrator.
# -----------------------------------------------------------------------------

if [ "$ACTION" = "provision" ]; then
    for entry in "${PROVISION_ORDER[@]}"; do
        svc="${entry%%:*}"
        phase=""
        if [[ "$entry" == *:* ]]; then
            phase="${entry#*:}"
        fi
        _in_active "$svc" || continue

        # Skip when the service (or phase) is already recorded done.
        if _should_skip_service provision "$svc" "$phase"; then
            current_status="$(_state_status_for "$svc")"
            if [ -n "$phase" ]; then
                echo "--- ${svc} (phase=${phase}) — SKIPPED (state=${current_status}; pass --no-skip-completed to force) ---"
            else
                echo "--- ${svc} — SKIPPED (state=${current_status}; pass --no-skip-completed to force) ---"
            fi
            echo
            continue
        fi

        script="${ROOT_DIR}/seed/${svc}/create.sh"
        if [ ! -f "$script" ]; then
            echo "WARN: ${script} not found; skipping ${svc}" >&2
            continue
        fi

        rc=0
        if [ -n "$phase" ]; then
            echo "--- ${svc} (phase=${phase}) ---"
            bash "$script" "$MODE_FLAG" "--phase=${phase}" || rc=$?
        else
            echo "--- ${svc} ---"
            bash "$script" "$MODE_FLAG" || rc=$?
        fi
        if [ "$rc" -ne 0 ]; then
            label="${svc}"
            [ -n "$phase" ] && label="${svc}(phase=${phase})"
            echo "ERROR: ${label} exited non-zero (rc=${rc}); halting provision (fail-fast)." >&2
            echo "       Re-run the same command to resume; --skip-completed will skip" >&2
            echo "       services already recorded as done." >&2
            exit "$rc"
        fi
        echo
    done

    echo "==> seed provision complete (${MODE_FLAG})"
    exit 0
fi

if [ "$ACTION" = "teardown" ]; then
    for svc in "${TEARDOWN_ORDER[@]}"; do
        _in_active "$svc" || continue

        if _should_skip_service teardown "$svc"; then
            current_status="$(_state_status_for "$svc")"
            echo "--- ${svc} teardown — SKIPPED (state=${current_status}; pass --no-skip-completed to force) ---"
            echo
            continue
        fi

        script="${ROOT_DIR}/seed/${svc}/teardown.sh"
        if [ ! -f "$script" ]; then
            echo "WARN: ${script} not found; skipping ${svc}" >&2
            continue
        fi

        echo "--- ${svc} teardown ---"
        rc=0
        bash "$script" "$MODE_FLAG" || rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "ERROR: ${svc} teardown exited non-zero (rc=${rc}); halting teardown (fail-fast)." >&2
            exit "$rc"
        fi
        echo
    done

    echo "==> seed teardown complete (${MODE_FLAG})"
    exit 0
fi
