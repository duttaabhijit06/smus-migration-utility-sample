#!/usr/bin/env bash
#
# migrate.sh — wrapper around the SageMaker Migration Tool.
#
# Mirrors the shape of ./seed.sh and ./nuke.sh: a single CLI that
# bundles the destructive-mode contract, prints a summary banner,
# forwards everything to the underlying tool, and writes a tee'd log.
#
# Default mode is dry-run; pass --apply to perform state-changing
# operations. Mutually exclusive with --dry-run.
#
# Usage:
#   ./migrate.sh run      [--apply|--dry-run] [--profile NAME] [--region NAME] [--yes] [migration-tool args...]
#   ./migrate.sh status
#   ./migrate.sh reset    [--yes]                              # wipes ./state/migration.state.json
#   ./migrate.sh teardown [--apply|--dry-run] [--yes] [--keep-cfn] [--keep-iam-roles]
#   ./migrate.sh -h | --help
#
# Action verbs:
#   run      — invoke `python -m migration_tool` with forwarded args
#   status   — pretty-print current run state from migration.state.json
#   reset    — clear migration state (asks for confirmation unless --yes)
#   teardown — reverse the bootstrap helpers and (by default) delete
#              the SMUS CFN stack so the next `run --apply` starts
#              from a clean slate. See `_action_teardown` for the
#              ordered list of unwinds.
#
# Forwarded migration-tool flags (see `python -m migration_tool --help`):
#   --apply, --dry-run, --step, --from, --to, --force, --reset (for steps),
#   --reconfigure, --set <k=v>, --convert-dags
#
# Wrapper-only flags:
#   --profile NAME    Set AWS_PROFILE for the underlying tool.
#   --region  NAME    Set AWS_DEFAULT_REGION for the underlying tool.
#   --yes / -y        Skip the apply-mode confirmation prompt.
#

set -uo pipefail
# Bash 3.2 + set -u + empty array `"${arr[@]}"` raises "unbound variable".
# Disable -u for the rest of the script; -o pipefail is preserved.
set +u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ACTION=""
MODE_FLAG=""           # --apply or --dry-run; empty = let migration tool default to dry-run
PROFILE=""
REGION=""
ASSUME_YES=0
TEARDOWN_KEEP_CFN=0    # --keep-cfn for the teardown action
TEARDOWN_KEEP_IAM=0    # --keep-iam-roles for the teardown action
PASSTHROUGH=()         # everything we hand to `python -m migration_tool`

usage() { sed -n '2,40p' "$0"; exit 64; }

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
        --keep-cfn)  TEARDOWN_KEEP_CFN=1; shift ;;
        --keep-iam-roles) TEARDOWN_KEEP_IAM=1; shift ;;
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

CONFIG_PATH="${ROOT_DIR}/config/migration.config.json"
STATE_PATH="${ROOT_DIR}/state/migration.state.json"
LOG_DIR="${ROOT_DIR}/logs"
mkdir -p "$LOG_DIR"

# -----------------------------------------------------------------------------
# Resolve a `python` executable that has the package installed.
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
# Apply-mode confirmation.
# -----------------------------------------------------------------------------
_confirm_apply() {
    [ "$MODE_FLAG" = "--apply" ] || return 0
    [ "$ASSUME_YES" -eq 1 ] && return 0
    if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
        echo "ERROR: --apply requires a TTY for confirmation; pass --yes for non-interactive runs" >&2
        exit 64
    fi
    {
        echo
        echo "WARNING: about to invoke the migration tool in APPLY mode."
        echo "         AWS_PROFILE=${AWS_PROFILE:-<unset>}"
        echo "         AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-<unset>}"
        echo "         config=${CONFIG_PATH}"
        echo "         state =${STATE_PATH}"
        echo
        printf "Type 'apply' to confirm: "
    } >/dev/tty
    typed=""
    IFS= read -r typed </dev/tty || typed=""
    if [ "$typed" != "apply" ]; then
        echo "ABORTED: confirmation mismatch; nothing changed." >/dev/tty
        exit 1
    fi
}

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

# -----------------------------------------------------------------------------
# IDC bootstrap.
#
# Looks up the account-local Identity Center instance (the one whose
# OwnerAccountId matches the caller's account, NOT any cross-account
# org-level instance) and ensures three seed groups, three seed users,
# and the three group memberships exist. Everything is idempotent —
# already-present resources are skipped.
#
# Side effects:
#   * Sets MT_IDENTITY_CENTER_INSTANCE_ARN and
#     MT_IDENTITY_CENTER_IDENTITY_STORE_ID env vars so the migration
#     tool can default its prompts to these values without re-asking.
#   * Logs each created/found resource to stdout.
#
# Skip rules:
#   * Skipped on dry-run mode (read-only orchestrator should not write).
#   * Skipped when the caller has no `aws sso-admin list-instances` permission.
#   * Skipped when the caller's account has no account-local IDC instance.
#
# Returns 0 on success or skip; never fails the parent run on its own.
# -----------------------------------------------------------------------------

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

    # Group + user definitions. Tuples kept inline so the contract is
    # visible at the call site rather than buried in a config file.
    local _groups=(
        "smus-admins|Seed group: SMUS admin role for migration testing"
        "smus-data-engineers|Seed group: SMUS data engineer role for migration testing"
        "smus-data-consumers|Seed group: SMUS data consumer role for migration testing"
    )
    local _users=(
        "smus-admin|SMUS|Admin|smus-admin@example.com|smus-admins"
        "smus-de|SMUS|DataEngineer|smus-de@example.com|smus-data-engineers"
        "smus-consumer|SMUS|Consumer|smus-consumer@example.com|smus-data-consumers"
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
    local _u _uname _given _family _email _ugroup _uid _existing_uid _payload
    for _u in "${_users[@]}"; do
        IFS='|' read -r _uname _given _family _email _ugroup <<<"$_u"
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

# -----------------------------------------------------------------------------
# IAM bootstrap.
#
# Step 1 of the migration tool calls `aws datazone create-domain`, which
# requires an IAM role that DataZone (and SageMaker) can assume. The
# canonical name for this role is `sagemaker-domain-execution` and it
# must trust both `datazone.amazonaws.com` and `sagemaker.amazonaws.com`,
# plus carry two managed policies:
#
#   * arn:aws:iam::aws:policy/AmazonDataZoneFullAccess
#   * arn:aws:iam::aws:policy/service-role/AmazonDataZoneDomainExecutionRolePolicy
#
# Idempotent:
#   * If the role already exists, the script ensures the two managed
#     policies are attached (re-attaching is a no-op).
#   * If the role is absent, it creates the role with the trust shown
#     above and attaches both policies.
#
# Skip rules:
#   * Skipped on dry-run mode (read-only orchestrator must not write).
#   * Skipped when `aws iam` calls fail for permissions reasons (the
#     migration tool will surface the original DataZone error later).
#
# Returns 0 on success or skip; never fails the parent run on its own.
# -----------------------------------------------------------------------------

_iam_bootstrap() {
    if [ "$MODE_FLAG" != "--apply" ]; then
        echo "==> IAM bootstrap: skipped (not in --apply mode)"
        return 0
    fi
    if ! command -v aws >/dev/null 2>&1; then
        echo "==> IAM bootstrap: skipped (aws CLI not on PATH)"
        return 0
    fi

    local _role_name="sagemaker-domain-execution"
    local _trust_path
    _trust_path="$(mktemp -t "mt-iam-trust-XXXXXX.json")"
    cat > "$_trust_path" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": [
          "datazone.amazonaws.com",
          "sagemaker.amazonaws.com"
        ]
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON

    local _role_arn=""
    local _existed=0
    if aws iam get-role --role-name "$_role_name" >/dev/null 2>&1; then
        _existed=1
        _role_arn="$(aws iam get-role --role-name "$_role_name" --query 'Role.Arn' --output text 2>/dev/null || echo "")"
        echo "==> IAM bootstrap: role ${_role_name} already exists (${_role_arn})"
        # Best-effort trust update — accepts both partners on every run.
        aws iam update-assume-role-policy --role-name "$_role_name" \
            --policy-document "file://${_trust_path}" >/dev/null 2>&1 || true
    else
        echo "==> IAM bootstrap: creating role ${_role_name}"
        _role_arn="$(aws iam create-role \
            --role-name "$_role_name" \
            --assume-role-policy-document "file://${_trust_path}" \
            --description "DataZone domain execution role (Step 1 prereq for the migration tool)" \
            --query 'Role.Arn' \
            --output text 2>/dev/null || echo "")"
        if [ -z "$_role_arn" ]; then
            echo "    WARN: failed to create role ${_role_name}; the migration tool's Step 1 will surface the underlying error"
            rm -f "$_trust_path"
            return 0
        fi
    fi
    rm -f "$_trust_path"

    # Attach the two canonical managed policies. attach-role-policy is
    # idempotent — re-attaching the same ARN is a no-op AWS-side.
    local _managed_policies=(
        "arn:aws:iam::aws:policy/AmazonDataZoneFullAccess"
        "arn:aws:iam::aws:policy/service-role/AmazonDataZoneDomainExecutionRolePolicy"
    )
    local _p
    for _p in "${_managed_policies[@]}"; do
        if aws iam list-attached-role-policies --role-name "$_role_name" \
                --query "AttachedPolicies[?PolicyArn==\`${_p}\`].PolicyArn" \
                --output text 2>/dev/null | grep -q "$_p"; then
            echo "    = policy attached: ${_p##*/}"
        else
            if aws iam attach-role-policy --role-name "$_role_name" \
                    --policy-arn "$_p" >/dev/null 2>&1; then
                echo "    + policy attached: ${_p##*/}"
            else
                echo "    WARN: failed to attach ${_p}; Step 1 may fail later"
            fi
        fi
    done

    # Newly-created roles need a few seconds for IAM propagation before
    # the DataZone control plane can assume them. We wait only when we
    # actually created the role this run.
    if [ "$_existed" -eq 0 ]; then
        echo "==> IAM bootstrap: waiting 10s for IAM role propagation"
        sleep 10
    fi

    # ---- Service role for V2 domains ---------------------------------------
    # DataZone V2 `create-domain` requires `--service-role` in addition
    # to `--domain-execution-role`. We provision a dedicated role
    # named `AmazonDataZoneServiceRole` trusted by datazone.amazonaws.com
    # and carrying the canonical managed policy.
    local _svc_role_name="AmazonDataZoneServiceRole"
    local _svc_trust_path
    _svc_trust_path="$(mktemp -t "mt-iam-svc-trust-XXXXXX.json")"
    cat > "$_svc_trust_path" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"Service": "datazone.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON
    local _svc_role_arn=""
    local _svc_existed=0
    if aws iam get-role --role-name "$_svc_role_name" >/dev/null 2>&1; then
        _svc_existed=1
        _svc_role_arn="$(aws iam get-role --role-name "$_svc_role_name" --query 'Role.Arn' --output text 2>/dev/null || echo "")"
        echo "==> IAM bootstrap: service role ${_svc_role_name} already exists (${_svc_role_arn})"
    else
        echo "==> IAM bootstrap: creating service role ${_svc_role_name}"
        _svc_role_arn="$(aws iam create-role \
            --role-name "$_svc_role_name" \
            --assume-role-policy-document "file://${_svc_trust_path}" \
            --description "DataZone V2 domain service role (Step 1 prereq for the migration tool)" \
            --query 'Role.Arn' \
            --output text 2>/dev/null || echo "")"
        if [ -z "$_svc_role_arn" ]; then
            echo "    WARN: failed to create ${_svc_role_name}; V2 domain creation will fail"
        fi
    fi
    rm -f "$_svc_trust_path"

    if [ -n "$_svc_role_arn" ]; then
        local _svc_policy="arn:aws:iam::aws:policy/service-role/SageMakerStudioDomainServiceRolePolicy"
        if aws iam list-attached-role-policies --role-name "$_svc_role_name" \
                --query "AttachedPolicies[?PolicyArn==\`${_svc_policy}\`].PolicyArn" \
                --output text 2>/dev/null | grep -q "$_svc_policy"; then
            echo "    = policy attached: ${_svc_policy##*/}"
        else
            if aws iam attach-role-policy --role-name "$_svc_role_name" \
                    --policy-arn "$_svc_policy" >/dev/null 2>&1; then
                echo "    + policy attached: ${_svc_policy##*/}"
            else
                echo "    WARN: failed to attach ${_svc_policy}; Step 1 may fail"
            fi
        fi
    fi

    if [ "$_svc_existed" -eq 0 ] && [ -n "$_svc_role_arn" ]; then
        echo "==> IAM bootstrap: waiting 10s for service role IAM propagation"
        sleep 10
    fi

    # Export so _action_run can inject as --set domain_service_role.
    export MT_DOMAIN_SERVICE_ROLE="$_svc_role_arn"

    # ---- Tooling blueprint prereqs ----------------------------------------
    # The Tooling blueprint needs three roles + one S3 bucket. We name them
    # deterministically and gate creates on `aws iam get-role` / `head-bucket`
    # so re-runs are no-ops.

    _ensure_role_with_trust_and_policies() {
        local _name="$1"
        local _trust_path="$2"
        local _description="$3"
        shift 3
        if aws iam get-role --role-name "$_name" >/dev/null 2>&1; then
            echo "    = role exists:    ${_name}"
        else
            echo "    + creating role:  ${_name}"
            if ! aws iam create-role --role-name "$_name" \
                    --assume-role-policy-document "file://${_trust_path}" \
                    --description "$_description" \
                    >/dev/null 2>&1; then
                echo "      WARN: create-role failed for ${_name}"
                return 1
            fi
        fi
        local _p
        for _p in "$@"; do
            if aws iam list-attached-role-policies --role-name "$_name" \
                    --query "AttachedPolicies[?PolicyArn==\`${_p}\`].PolicyArn" \
                    --output text 2>/dev/null | grep -q "$_p"; then
                echo "      = policy attached: ${_p##*/}"
            else
                if aws iam attach-role-policy --role-name "$_name" \
                        --policy-arn "$_p" >/dev/null 2>&1; then
                    echo "      + policy attached: ${_p##*/}"
                else
                    echo "      WARN: attach-role-policy failed for ${_p}"
                fi
            fi
        done
        return 0
    }

    # Provisioning role — DataZone assumes it to provision project resources.
    local _provisioning_trust
    _provisioning_trust="$(mktemp -t "mt-iam-prov-trust-XXXXXX.json")"
    cat > "$_provisioning_trust" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"Service": "datazone.amazonaws.com"},
      "Action": "sts:AssumeRole"
    },
    {
      "Effect": "Allow",
      "Principal": {"Service": "cloudformation.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON
    _ensure_role_with_trust_and_policies \
        "sagemaker-studio-provisioning-role" \
        "$_provisioning_trust" \
        "SageMaker Unified Studio Tooling provisioning role" \
        "arn:aws:iam::aws:policy/AmazonDataZoneSageMakerProvisioningRolePolicy" \
        "arn:aws:iam::aws:policy/AdministratorAccess" \
        || true
    rm -f "$_provisioning_trust"
    local _provisioning_arn
    _provisioning_arn="$(aws iam get-role --role-name "sagemaker-studio-provisioning-role" --query 'Role.Arn' --output text 2>/dev/null || echo "")"

    # Manage-access role — DataZone assumes it to publish/subscribe assets.
    local _manage_trust
    _manage_trust="$(mktemp -t "mt-iam-manage-trust-XXXXXX.json")"
    cat > "$_manage_trust" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"Service": "datazone.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON
    _ensure_role_with_trust_and_policies \
        "sagemaker-studio-manage-access-role" \
        "$_manage_trust" \
        "SageMaker Unified Studio Tooling manage-access role" \
        "arn:aws:iam::aws:policy/AmazonDataZoneSageMakerManageAccessRolePolicy" \
        || true
    rm -f "$_manage_trust"
    local _manage_arn
    _manage_arn="$(aws iam get-role --role-name "sagemaker-studio-manage-access-role" --query 'Role.Arn' --output text 2>/dev/null || echo "")"

    # Projects S3 bucket — must be prefixed with one of the SageMaker
    # Unified Studio recognised tokens. We use `amazon-datazone-projects-`.
    local _account_id
    _account_id="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")"
    local _region="${AWS_DEFAULT_REGION:-us-east-1}"
    local _projects_bucket="amazon-datazone-projects-${_account_id}-${_region}"
    if [ -n "$_account_id" ]; then
        if aws s3api head-bucket --bucket "$_projects_bucket" --region "$_region" >/dev/null 2>&1; then
            echo "    = bucket exists:  s3://${_projects_bucket}"
        else
            echo "    + creating bucket: s3://${_projects_bucket}"
            if [ "$_region" = "us-east-1" ]; then
                aws s3api create-bucket --bucket "$_projects_bucket" --region "$_region" >/dev/null 2>&1 || true
            else
                aws s3api create-bucket --bucket "$_projects_bucket" --region "$_region" \
                    --create-bucket-configuration "LocationConstraint=${_region}" >/dev/null 2>&1 || true
            fi
        fi
    fi

    # Export prereqs so Step 1 can pass them when enabling the Tooling
    # blueprint and creating the All-capabilities project profile.
    export MT_TOOLING_PROVISIONING_ROLE_ARN="$_provisioning_arn"
    export MT_TOOLING_MANAGE_ACCESS_ROLE_ARN="$_manage_arn"
    export MT_TOOLING_PROJECTS_BUCKET="$_projects_bucket"

    echo "==> IAM bootstrap: complete"
}

# -----------------------------------------------------------------------------
# CFN bootstrap.
#
# Deploys the SMUS bootstrap CloudFormation stack — the canonical
# end-to-end All-capabilities setup adapted from the AWS samples repo
# `aws-samples/sample-automate-sagemaker-unified-studio-using-iac`.
#
# Stack surface:
#   * Domain (V2) with KMS-encrypted storage, IDC SSO mode, both
#     domain-execution and domain-service IAM roles
#   * 3 blueprint configurations: Tooling, LakehouseCatalog, DataLake
#     (LakehouseDatabase) — each with the right managed-policy stack
#   * 3 project profiles: Tooling, LakeHouse-DB+Tooling,
#     All-capabilities (composes all three blueprints)
#   * Admin project owned by the IDC user and the automation IAM role
#   * Lake Formation data-lake admin entries
#
# After successful create-or-update, this function reads the stack
# outputs and exports them as MT_* env vars so the migration tool's
# Step 1 can pick them up via --set injection (see below in
# _action_run).
#
# Skip rules:
#   * Skipped on dry-run.
#   * Skipped if `aws cloudformation` is not on PATH.
#   * Skipped if no IDC user/group was discovered (require _idc_bootstrap
#     to run first).
#
# Idempotent: re-running a successful deploy is a no-op (CFN
# `update-stack` returns NoUpdates and we move on).
# -----------------------------------------------------------------------------

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
    local _stack_name="smus-seed"

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
        fi
        echo "==> CFN bootstrap: complete (no changes)"
        return 0
    fi

    # ---- Stack absent or in a non-healthy state — deploy from scratch. -----
    echo "==> CFN bootstrap: stack ${_stack_name} status=${_existing_status:-MISSING}; running deploy"

    # Discover the IDC user + group IDs we created in _idc_bootstrap.
    local _identity_store_id="${MT_IDENTITY_CENTER_IDENTITY_STORE_ID:-}"
    if [ -z "$_identity_store_id" ]; then
        echo "==> CFN bootstrap: skipped (MT_IDENTITY_CENTER_IDENTITY_STORE_ID not set; _idc_bootstrap must run first)"
        return 0
    fi
    local _sso_user_id _sso_group_id
    _sso_user_id="$(aws identitystore list-users \
        --identity-store-id "$_identity_store_id" \
        --filters 'AttributePath=UserName,AttributeValue=smus-admin' \
        --query 'Users[0].UserId' --output text 2>/dev/null | grep -v '^None$' || true)"
    _sso_group_id="$(aws identitystore list-groups \
        --identity-store-id "$_identity_store_id" \
        --filters 'AttributePath=DisplayName,AttributeValue=smus-admins' \
        --query 'Groups[0].GroupId' --output text 2>/dev/null | grep -v '^None$' || true)"
    if [ -z "$_sso_user_id" ] || [ -z "$_sso_group_id" ]; then
        echo "==> CFN bootstrap: WARN — could not resolve smus-admin user or smus-admins group; skipping"
        return 0
    fi

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
    sed \
        -e "s|{{account}}|${_account}|g" \
        -e "s|{{region}}|${_region}|g" \
        -e "s|{{vpc_id}}|${_vpc_id}|g" \
        -e "s|{{subnet_ids}}|${_subnet_csv}|g" \
        -e "s|{{sso_user_id}}|${_sso_user_id}|g" \
        -e "s|{{sso_group_id}}|${_sso_group_id}|g" \
        -e "s|{{sso_instance_arn}}|${MT_IDENTITY_CENTER_INSTANCE_ARN}|g" \
        "$_params_template" > "$_params_path"

    local _cfn_bucket="smus-seed-cfn-${_account}-${_region}"
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
    for _t in sus-domain-stack.yaml \
              sus-blueprints-stack.yaml \
              sus-project-profiles-stack.yaml \
              sus-policy-grant-stack.yaml \
              sus-project-stack.yaml; do
        echo "    + uploading ${_t}"
        aws s3 cp "${_template_dir}/${_t}" "s3://${_cfn_bucket}/${_t}" --region "$_region" >/dev/null
    done

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
    fi

    echo "==> CFN bootstrap: complete"
}

# -----------------------------------------------------------------------------
# Repo bootstrap.
#
# Step 6 of the migration tool extracts MWAA DAGs and commits them to
# the configured code repository. It only commits when MT_WORKDIR is a
# git working tree; otherwise it falls back to printing dry-run-style
# `cp/git` lines and the DAGs never reach CodeCommit.
#
# This helper makes the project root a working tree of the
# `${MT_REPO_NAME}` CodeCommit repository so Step 6 can commit and a
# subsequent `git push` (Step 9 / manual) lands the DAGs in
# CodeCommit.
#
# Idempotency:
#   * If `.git` already exists, leave it alone (we don't clobber an
#     operator's existing setup).
#   * Otherwise: `git init`, configure user.email + user.name (CFN-
#     bootstrap-style — only set when missing), set the `origin`
#     remote to the CodeCommit clone URL, fetch, and check out
#     `main` (creating it as an empty branch if the remote is empty).
#
# Skip rules:
#   * Skipped on dry-run (we're not setting up real git plumbing).
#   * Skipped if `git` is not on PATH.
#   * Skipped if the CodeCommit repo doesn't exist (we expect Step 1
#     to have created it via `aws codecommit create-repository`, but
#     we tolerate the gap and just print a warning).
# -----------------------------------------------------------------------------

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

    # Discover the CodeCommit clone URL via aws-cli. Step 1 creates
    # the repo, but we may run before/after Step 1 — be tolerant.
    local _repo_name="${MT_REPO_NAME:-smus-seed-domain-migration}"
    local _region="${AWS_DEFAULT_REGION:-us-east-1}"
    local _clone_url
    _clone_url="$(aws codecommit get-repository --repository-name "$_repo_name" \
        --region "$_region" --query 'repositoryMetadata.cloneUrlHttp' --output text 2>/dev/null \
        | grep -v '^None$' || true)"
    if [ -z "$_clone_url" ]; then
        echo "==> Repo bootstrap: WARN — CodeCommit repo ${_repo_name} not found; Step 6 will fall back to dry-run lines"
        return 0
    fi

    echo "==> Repo bootstrap: initializing ${ROOT_DIR} as a working tree of ${_repo_name}"
    ( cd "$ROOT_DIR" && git init -q ) || {
        echo "    WARN: git init failed; skipping repo bootstrap"
        return 0
    }

    # Use AWS-CLI's CodeCommit credential helper for a passwordless
    # HTTPS push (the credential helper just uses the active AWS
    # profile/role).
    ( cd "$ROOT_DIR" \
        && git config --local credential.helper '!aws codecommit credential-helper $@' \
        && git config --local credential.UseHttpPath true ) || true

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

# -----------------------------------------------------------------------------
# Lake Formation bootstrap.
#
# The DataZone V2 Glue data source created by Step 4 is executed by a
# DataZone-managed user role (`datazone_usr_role_<project>_<env>`) that
# must have Lake Formation `DESCRIBE` on each Glue database it crawls
# and `DESCRIBE` + `SELECT` on the tables. Without these grants the
# data source's first run fails with
#   "Insufficient Lake Formation permission(s): Required Describe on
#    <database>"
# and the step's data source enters `lastRunStatus=FAILED`.
#
# This helper:
#   * Adds the caller's role to the Lake Formation data-lake admins
#     (idempotent — only added if missing).
#   * Discovers the project's data-access role (`userRoleArn`) AND the
#     SMUS manage-access role from the domain CFN outputs.
#   * For every external Glue database (skips `glue_db_*` SMUS-managed
#     ones):
#       - Revokes leftover IAMAllowedPrincipals grants — without this
#         the asset is "not managed by Lake Formation" and the SMUS
#         portal shows "Asset cannot be queried with tools".
#       - Grants DESCRIBE (+ DESCRIBE Grantable) on the database and
#         DESCRIBE+SELECT (+ Grantable) on every table to the project
#         user role AND the manage-access role. The grantable variants
#         are required per the SMUS Glue-asset access doc:
#           https://docs.aws.amazon.com/sagemaker-unified-studio/latest/userguide/grant-access-to-glue-asset.html
#
# Lessons baked in (from this round of debugging):
#   1. Even after publishing a Glue table as a DataZone asset, the
#      portal flags it "cannot be queried with tools" if any of:
#        a. IAMAllowedPrincipals is still on the table/DB
#        b. Project user role lacks DESCRIBE/SELECT GRANTABLE
#        c. Manage-access role has zero perms on the DB/table
#      All three are now handled in one pass.
#   2. The data preview path uses LF directly via the project user
#      role; the "queryable with tools" badge is a separate UI gate
#      driven by the manage-access role's grants. Both must be
#      provisioned for the asset to be fully usable in Visual ETL.
#
# Skip rules:
#   * Skipped on dry-run.
#   * Skipped if the project hasn't finished provisioning yet.
# -----------------------------------------------------------------------------

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
    # manage-access role ARN comes from the domain CFN stack output
    # `MT_TOOLING_MANAGE_ACCESS_ROLE_ARN` set by `_iam_bootstrap`.
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

# -----------------------------------------------------------------------------
# _smus_session_bootstrap
#
# Fix the infrastructure-level issues that prevent Glue interactive
# sessions, Athena Spark workgroups, and notebook Spark cells from
# working in a fresh SMUS Tooling environment:
#
#   1. Lake Formation registrations on the DataZone tooling bucket
#      ----------------------------------------------------------------
#      SMUS auto-registers `arn:aws:s3:::amazon-datazone-tooling-<acct>-<region>`
#      and `…/<domain>/<project>/dev/glue` with the LF service-linked
#      role in STRICT mode. The Glue session driver writes Spark Live
#      UI logs to `…/<domain>/<project>/dev/glue/glue-spark-events-logs/`
#      which falls under those registrations. With strict mode the LF
#      credential resolver refuses to vend creds for any S3 path that
#      isn't backed by a registered Glue table — the session fails with:
#         "S3 bucket is not accessible for uploading Spark Live UI log."
#
#      Fix: deregister the SLR-managed strict registrations under the
#      project-scoped tooling path and (re-)register the project's
#      `…/<domain>/<project>/dev` prefix in HYBRID mode owned by the
#      project user role. Hybrid mode lets IAM creds flow through when
#      LF has no table covering the path.
#
#   1.5 Source S3 registrations need WithFederation=true for FGAC
#      ----------------------------------------------------------------
#      Athena Spark and Glue interactive sessions in fine-grained
#      access mode call `lakeformation:GetTemporaryGlueTableCredentials`.
#      LF returns `Access is not allowed` for any table whose
#      registered S3 path was created without `WithFederation=true`.
#      The default SLR-managed registrations cannot be updated to
#      add WithFederation (LF returns `Resource managed by Service
#      Linked Role`), so we create a dedicated registration role
#      (`smus-seed-lf-registration-role`) and re-register every
#      external Glue table's underlying S3 prefix using that role
#      with `--with-federation --hybrid-access-enabled`.
#
#   2. Customer-managed KMS encryption on the tooling bucket
#      ----------------------------------------------------------------
#      The bucket is SSE-KMS with a customer-managed CMK created by
#      the SUS Tooling Blueprint. The project user role's IAM policy
#      grants KMS access only on `${aws:PrincipalTag/KmsKeyId}` — and
#      that role tag is empty by default, so the role has no path to
#      use the CMK. PutObject for Spark logs fails with a generic S3
#      access error.
#
#      Fix: detect the CMK from the bucket's encryption config and
#      add a key policy statement allowing the project user role
#      Encrypt/Decrypt/ReEncrypt*/GenerateDataKey*/DescribeKey via
#      the s3 + glue services in the project's region.
#
#   3. LF data-lake settings need FGAC + every authorized session tag
#      ----------------------------------------------------------------
#      `AllowExternalDataFiltering`, `AllowFullTableExternalDataAccess`,
#      `ExternalDataFilteringAllowList` (account allow-list), and
#      `AuthorizedSessionTagValueList` (which includes "Amazon DataZone",
#      "Amazon SageMaker", "Athena", and four others) all need to be
#      set for FGAC notebook sessions to work. Section 0 below handles
#      this BEFORE the per-prefix registrations.
#
#   4. Project user role needs `lakeformation:GetTemporaryGlue*Credentials`
#      ----------------------------------------------------------------
#      The AWS-managed `SageMakerStudioProjectUserRolePolicy` only
#      grants the legacy `lakeformation:GetDataAccess`. FGAC needs the
#      `Temporary*` variants — attached as an inline `LakeFormationFGACAccess`
#      policy in section 0 below.
#
# Skip rules:
#   * Skipped on dry-run.
#   * Skipped if domain/project IDs are not yet known.
#   * Skipped if the tooling bucket doesn't exist (env not provisioned).
#
# Idempotency: every step is a get-then-mutate; re-running is a no-op.
# -----------------------------------------------------------------------------

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

    local _bucket="amazon-datazone-tooling-${_account}-${_region}"
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

    # 1.5a. Discover the dedicated registration role; create it if missing.
    local _reg_role_name="smus-seed-lf-registration-role"
    local _reg_role_arn="arn:aws:iam::${_account}:role/${_reg_role_name}"
    if ! aws iam get-role --role-name "$_reg_role_name" >/dev/null 2>&1; then
        local _reg_trust _reg_policy
        _reg_trust='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":["lakeformation.amazonaws.com","glue.amazonaws.com"]},"Action":"sts:AssumeRole"}]}'
        _reg_policy="$(jq -n '{
            Version: "2012-10-17",
            Statement: [
                {
                    Sid: "S3DataAccess",
                    Effect: "Allow",
                    Action: ["s3:GetObject","s3:PutObject","s3:DeleteObject","s3:ListBucket","s3:GetBucketLocation","s3:GetBucketAcl"],
                    Resource: "*"
                },
                {
                    Sid: "GlueAccess",
                    Effect: "Allow",
                    Action: ["glue:GetTable","glue:GetTables","glue:GetDatabase","glue:GetDatabases"],
                    Resource: "*"
                },
                {
                    Sid: "LakeFormationDataAccess",
                    Effect: "Allow",
                    Action: ["lakeformation:GetDataAccess","lakeformation:GrantPermissions"],
                    Resource: "*"
                }
            ]
        }')"
        if aws iam create-role --role-name "$_reg_role_name" \
                --assume-role-policy-document "$_reg_trust" \
                >/dev/null 2>&1; then
            aws iam put-role-policy --role-name "$_reg_role_name" \
                --policy-name LFRegistrationPolicy \
                --policy-document "$_reg_policy" >/dev/null 2>&1 || true
            echo "    + created LF registration role ${_reg_role_name}"
            # Brief pause so IAM consistency catches up before LF tries to
            # assume the new role during register-resource.
            sleep 8
        else
            echo "    WARN: failed to create ${_reg_role_name}; skipping WithFederation re-registration"
            _reg_role_arn=""
        fi
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

    echo "==> SMUS session bootstrap: complete"
}

# -----------------------------------------------------------------------------
# _smus_codecommit_grant
#
# Attach a CodeCommit Git-ops inline policy to the project user role so
# users in the JupyterLab Space can `git clone`, `git fetch`, and
# `git push` against the project's CodeCommit repo.
#
# Why this matters:
# The SMUS `SageMakerStudioProjectUserRolePolicy` AWS-managed policy
# attached to `datazone_usr_role_<project>_<env>` does NOT include
# `codecommit:GitPull` / `codecommit:GitPush`. Without these, users in
# the Space hit `403` from CodeCommit even when `git-remote-codecommit`
# is correctly configured — the helper successfully signs the request
# and CodeCommit rejects it.
#
# The grant is scoped to the migration's CodeCommit repo (resolved
# from `MT_REPO_NAME` / config) plus a global `ListRepositories` so
# the SMUS portal's Code tab can list repos.
#
# Skip rules:
#   * Skipped on dry-run.
#   * Skipped when the configured Repo_Provider is not codecommit.
#   * Skipped if domain/project IDs aren't set yet.
#   * Skipped if the project user role can't be discovered.
#
# Idempotency: `put-role-policy` is replace-or-create.
# -----------------------------------------------------------------------------

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

# -----------------------------------------------------------------------------
# _smus_subscribe_assets
#
# Auto-subscribe the admin project to every external Glue table asset
# it has published. SMUS treats project-managed and external Glue DBs
# differently: external tables (the `smus-seed-db-*` ones in this
# repo) are NEVER promoted to "queryable with tools" status until the
# subscribing project has an active subscription. Subscription causes
# SMUS to provision a Glue resource link in `glue_db_<env_id>` —
# Visual ETL then sees a managed path and clears the badge.
#
# Self-subscription (publisher == subscriber == admin project) is
# auto-approved by DataZone; no human approval step is needed.
#
# Skip rules:
#   * Skipped on dry-run.
#   * Skipped if domain/project IDs aren't set.
#   * Opt-out: set MT_SKIP_AUTO_SUBSCRIBE=1 to disable.
#
# Idempotency: skips listings the project is already subscribed to.
# -----------------------------------------------------------------------------

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
# -----------------------------------------------------------------------------
_action_run() {
    # Echo a banner so the operator sees the resolved environment before
    # anything starts.
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

    _confirm_apply

    # Idempotent IDC bootstrap (skipped on dry-run). Sets
    # MT_IDENTITY_CENTER_INSTANCE_ARN / MT_IDENTITY_CENTER_IDENTITY_STORE_ID
    # if an account-local instance is found.
    _idc_bootstrap

    # Idempotent IAM bootstrap (skipped on dry-run). Ensures the DataZone
    # domain execution role exists with the right trust + managed policies.
    _iam_bootstrap

    # Idempotent CFN bootstrap (skipped on dry-run). Deploys the SMUS
    # All-capabilities CloudFormation stack — domain, blueprints, project
    # profile, admin project, and project ownership for the IDC user
    # discovered by _idc_bootstrap. Sets MT_SMUS_DOMAIN_ID,
    # MT_ADMIN_PROJECT_ID, MT_ADMIN_PROJECT_PROFILE_ID env vars used by
    # the migration tool's Step 1.
    _cfn_bootstrap

    # Make the project root a working tree of the CodeCommit repo so
    # Step 6 can `git add` + `git commit` the extracted DAGs (and a
    # subsequent push lands them in CodeCommit).
    _repo_bootstrap

    # Install the aws-smus-cicd CLI required by Step 7 to deploy the
    # extracted DAGs into the admin project's MWAA environment.
    _cicd_cli_bootstrap

    # Grant Lake Formation Describe + Select on the seed Glue databases
    # to the DataZone data-access role so Step 4's data source crawl
    # can read their schemas. No-op if the project isn't fully
    # provisioned yet (the next run picks it up).
    _lakeformation_bootstrap

    # Fix two infrastructure-level snags that block Glue interactive
    # sessions in a fresh SMUS Tooling environment:
    #   1. Strict-mode LF registrations on the tooling bucket that
    #      reject Spark Live UI log writes.
    #   2. Customer-managed KMS encryption with the project user role
    #      missing key access.
    # Idempotent — re-running on a fixed env is a no-op.
    _smus_session_bootstrap

    # Attach a CodeCommit Git-ops inline policy to the project user
    # role so users in JupyterLab Spaces can `git clone` / `git push`
    # against the project's CodeCommit repo. The default
    # `SageMakerStudioProjectUserRolePolicy` doesn't include
    # codecommit:GitPull / GitPush, so without this the Space hits
    # 403 from CodeCommit. No-op when the configured Repo_Provider
    # is not codecommit.
    _smus_codecommit_grant

    # Auto-subscribe the admin project to its own published Glue
    # assets. Without this, external Glue tables in the seed DBs are
    # marked "Asset cannot be queried with tools" in Visual ETL even
    # after Lake Formation perms are correct. Subscription causes
    # SMUS to provision resource links in the project's managed Glue
    # DB and clears the badge. Set MT_SKIP_AUTO_SUBSCRIBE=1 to disable.
    _smus_subscribe_assets

    # Subscriptions create resource links in `glue_db_<env_id>` but
    # don't grant LF DESCRIBE on the link itself. Spark's catalog
    # client needs DESCRIBE on the link to resolve names like
    # `glue_db_<env_id>.<table>` — without it, queries fail with
    # `[TABLE_OR_VIEW_NOT_FOUND]` even though every other LF perm
    # in the chain is correct. This helper grants the missing
    # DESCRIBE on every resource link in the project's managed DB.
    _smus_grant_resource_link_describe

    log_path="${LOG_DIR}/migrate-$(date +%Y%m%d-%H%M%S).log"

    # Build the final argv for the migration tool. MODE_FLAG goes first
    # so it's visible at the top of the help-style output if anything
    # fails early.
    args=()
    [ -n "$MODE_FLAG" ] && args+=("$MODE_FLAG")

    # If the IDC bootstrap discovered an account-local instance and the
    # operator has not already overridden these values via --set on the
    # passthrough, inject them now so the migration tool's prompt loop
    # can default them and skip the corresponding questions. The
    # migration tool's Prompter does not read env vars; injecting via
    # --set is the documented escape hatch (Requirement 2.5).
    _has_set_for() {
        # Returns 0 if the passthrough already contains --set <key>=...
        local _key="$1"
        local _arg
        local _found=0
        for _arg in "${PASSTHROUGH[@]}"; do
            case "$_arg" in
                "--set=${_key}="*|"--set=${_key}=") _found=1; break ;;
            esac
        done
        # Also check for the two-token form: --set <key>=...
        local _i=0
        local _n="${#PASSTHROUGH[@]}"
        while [ "$_i" -lt "$_n" ]; do
            if [ "${PASSTHROUGH[$_i]:-}" = "--set" ]; then
                local _next="${PASSTHROUGH[$((_i+1))]:-}"
                case "$_next" in
                    "${_key}="*|"${_key}=") _found=1; break ;;
                esac
            fi
            _i=$((_i + 1))
        done
        [ "$_found" -eq 1 ]
    }

    if [ -n "${MT_IDENTITY_CENTER_INSTANCE_ARN:-}" ] && ! _has_set_for identity_center_instance_arn; then
        args+=("--set" "identity_center_instance_arn=${MT_IDENTITY_CENTER_INSTANCE_ARN}")
        echo "==> Pre-set:  identity_center_instance_arn=${MT_IDENTITY_CENTER_INSTANCE_ARN}"
    fi
    if [ -n "${MT_IDENTITY_CENTER_IDENTITY_STORE_ID:-}" ] && ! _has_set_for identity_center_identity_store_id; then
        args+=("--set" "identity_center_identity_store_id=${MT_IDENTITY_CENTER_IDENTITY_STORE_ID}")
        echo "==> Pre-set:  identity_center_identity_store_id=${MT_IDENTITY_CENTER_IDENTITY_STORE_ID}"
    fi
    if [ -n "${MT_DOMAIN_SERVICE_ROLE:-}" ] && ! _has_set_for domain_service_role; then
        args+=("--set" "domain_service_role=${MT_DOMAIN_SERVICE_ROLE}")
        echo "==> Pre-set:  domain_service_role=${MT_DOMAIN_SERVICE_ROLE}"
    fi
    if [ -n "${MT_SMUS_DOMAIN_ID:-}" ] && ! _has_set_for smus_domain_id; then
        args+=("--set" "smus_domain_id=${MT_SMUS_DOMAIN_ID}")
        echo "==> Pre-set:  smus_domain_id=${MT_SMUS_DOMAIN_ID}"
    fi
    if [ -n "${MT_ADMIN_PROJECT_ID:-}" ] && ! _has_set_for admin_project_id; then
        args+=("--set" "admin_project_id=${MT_ADMIN_PROJECT_ID}")
        echo "==> Pre-set:  admin_project_id=${MT_ADMIN_PROJECT_ID}"
    fi
    if [ -n "${MT_ADMIN_PROJECT_PROFILE_ID:-}" ] && ! _has_set_for admin_project_profile_id; then
        args+=("--set" "admin_project_profile_id=${MT_ADMIN_PROJECT_PROFILE_ID}")
        echo "==> Pre-set:  admin_project_profile_id=${MT_ADMIN_PROJECT_PROFILE_ID}"
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
# Reverse the bootstrap helpers added to `_action_run` so the next
# `migrate.sh run --apply` starts from a clean slate. Teardown is the
# inverse of the bootstrap chain — it walks the same env discovery
# logic to find resources owned by the admin project, then unwinds
# them in dependency-safe order.
#
# Order of unwind (everything is best-effort and idempotent):
#
#   1. Cancel/revoke every active subscription the admin project
#      holds. SMUS auto-tears the resource links in `glue_db_<env_id>`
#      when the subscription is revoked.
#   2. Revoke the LF DESCRIBE grants we added on resource links.
#   3. Remove the `AllowProjectUserRoleForSparkLogs` statement we
#      added to the tooling-bucket KMS key policy.
#   4. Detach the IAM inline policies Step 3 added to the project
#      user role (`GlueSparkLogsAccess`, `GlueDataBucketAccess`,
#      `GlueConnectionAccess`, `CodeCommitAccess`,
#      `LakeFormationFGACAccess`, `GlueCatalogReadAccess`). Skipped
#      when --keep-iam-roles.
#   5. Delete the SMUS CFN stack via the hardened
#      `_teardown_destroy_smus_stack` helper. Skipped when
#      --keep-cfn. The helper handles the five known SMUS
#      teardown failure modes (lingering VPC endpoints, cross-SG
#      ingress, env-stack drain, dangling LF admins, stuck
#      DataZone Owner CFN resource) before issuing delete-stack.
#   6. Wipe the migration state file (same as `reset`).
#
# Notes on what teardown DOESN'T touch:
#   * IAMAllowedPrincipals revokes on the seed DBs/tables: harmless
#     to leave revoked; new tables get the LF default automatically.
#   * LF Describe/Select Grantable on seed DBs/tables: scoped to
#     roles that get cleaned up in step 4 or 5 anyway.
#   * Tooling-bucket LF registrations: SMUS re-registers these on
#     the next deploy if missing.
#
# Skip rules:
#   * Skipped on dry-run (the helper still walks discovery and
#     prints the would-be destructive calls).
#
# Confirmation prompt mirrors `_action_reset`: requires the user to
# type `teardown` unless --yes is passed.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# _teardown_destroy_smus_stack <apply> <region> <domain_id> <project_id>
#
# Hardened SMUS CFN stack deletion that handles the six failure modes
# the bare `delete-stack` hits in practice:
#
#   1. The DataZone Tooling environment fails to delete because its
#      CFN sub-stack can't drop the Tooling Security Group while
#      SMUS-managed VPC interface endpoints (Glue, Lambda, Secrets
#      Manager) still reference it. The endpoints aren't in any CFN
#      stack — SMUS provisions them out-of-band on first project use.
#   2. Sibling Security Groups (seed VPC SG, RDS SG) carry ingress
#      rules that reference the Tooling SG. Even after VPC endpoints
#      drain, those cross-references keep the SG alive.
#   3. After the env's IAM user role is deleted, the Lake Formation
#      data-lake admins list still contains its ARN. CFN's
#      `AWS::LakeFormation::DataLakeSettings` delete handler then
#      fails with `InvalidInputException: Invalid principal`.
#   4. The DataZone domain root unit owner record
#      (`AWS::DataZone::Owner` for the automation IAM role) hits a
#      `ConditionalCheckFailed` on delete because the underlying
#      ownership row is already gone. CFN can't reconcile and aborts.
#   5. Sub-stacks finish deleting in stages, so the parent has to be
#      retried after each unblock.
#   6. SMUS auto-creates `glue_db_<env_id>` Glue databases for the
#      Lakehouse Database environment but doesn't include them in
#      any CFN stack. They survive teardown as orphaned DBs that show
#      up in the next deployment's Catalog tree pointing at long-gone
#      tables. We drop them here, scoped by domain-id match on
#      `LocationUri`.
#
# Strategy:
#
#   * BEFORE the first delete attempt:
#       - Drain the project's VPC endpoints (deletes them; they get
#         re-created when SMUS provisions the project again).
#       - Revoke ingress rules on sibling SGs that reference any
#         Tooling SG (cross-account references would skip).
#       - Issue `delete-environment` for any env still in
#         CREATED/DELETE_FAILED state, then wait for it to be GONE.
#       - Strip dangling principals from the LF data-lake admins.
#
#   * Then issue `delete-stack` and wait.
#
#   * If the wait fails:
#       - Inspect the failure reason. If it's `rSUSDomainOwnerIAMRole`
#         (failure mode 4), retry the domain sub-stack delete with
#         `--retain-resources rSUSDomainOwnerIAMRole`.
#       - Then retry the parent stack delete.
#
# All steps are idempotent; re-running on a partially-cleaned env is a
# no-op for anything that's already gone.
#
# Args:
#   $1 — _apply   1 for real apply, 0 for dry-run
#   $2 — _region  AWS region
#   $3 — _domain_id  DataZone domain id (may be empty if domain is gone)
#   $4 — _project_id DataZone project id (may be empty)
# -----------------------------------------------------------------------------

_teardown_destroy_smus_stack() {
    local _apply="$1" _region="$2" _domain_id="$3" _project_id="$4"
    local _stack_name="smus-seed"

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

    # ---- C. Strip dangling principals from LF data-lake admins. --------
    # (failure mode 3.) Any principal whose underlying IAM role no
    # longer exists is a CFN-killer; remove it now.
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

    # ---- D. First parent delete attempt. -------------------------------
    aws cloudformation delete-stack --stack-name "$_stack_name" \
        --region "$_region" >/dev/null 2>&1
    echo "    + first delete-stack issued for ${_stack_name}; waiting (up to 30 min)"
    if aws cloudformation wait stack-delete-complete \
            --stack-name "$_stack_name" --region "$_region" >/dev/null 2>&1; then
        echo "    + ${_stack_name} deleted on first attempt"
        return 0
    fi
    if ! aws cloudformation describe-stacks --stack-name "$_stack_name" \
            --region "$_region" >/dev/null 2>&1; then
        echo "    + ${_stack_name} deleted"
        return 0
    fi

    # ---- E. Inspect failure; retry domain sub-stack with --retain-resources
    # ---- if rSUSDomainOwnerIAMRole is the blocker (failure mode 4). ----
    local _failed_resources _has_owner_failure
    _failed_resources="$(aws cloudformation describe-stack-events \
        --stack-name "$_stack_name" --max-items 30 \
        --region "$_region" --output json 2>/dev/null \
        | jq -r '.StackEvents[]? | select(.ResourceStatus == "DELETE_FAILED") | .ResourceStatusReason')"
    _has_owner_failure="$(printf '%s' "$_failed_resources" | grep -c rSUSDomainOwnerIAMRole || true)"
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

    # ---- F. Second parent delete attempt. ------------------------------
    aws cloudformation delete-stack --stack-name "$_stack_name" \
        --region "$_region" >/dev/null 2>&1
    echo "    + second delete-stack issued for ${_stack_name}; waiting (up to 30 min)"
    if aws cloudformation wait stack-delete-complete \
            --stack-name "$_stack_name" --region "$_region" >/dev/null 2>&1; then
        echo "    + ${_stack_name} deleted on second attempt"
        return 0
    fi

    if ! aws cloudformation describe-stacks --stack-name "$_stack_name" \
            --region "$_region" >/dev/null 2>&1; then
        echo "    + ${_stack_name} deleted"
        return 0
    fi

    local _final_status
    _final_status="$(aws cloudformation describe-stacks --stack-name "$_stack_name" \
        --region "$_region" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "?")"
    echo "    WARN: ${_stack_name} ended in ${_final_status}; check AWS console for failed resources"
    return 1
}

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
    if [ "$TEARDOWN_KEEP_CFN" -eq 1 ]; then
        echo "==> Keep:     CFN stack"
    fi
    if [ "$TEARDOWN_KEEP_IAM" -eq 1 ]; then
        echo "==> Keep:     IAM project-role inline policies"
    fi
    echo

    if [ "$MODE_FLAG" = "--apply" ] && [ "$ASSUME_YES" -ne 1 ]; then
        if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
            echo "ERROR: teardown --apply requires a TTY for confirmation; pass --yes for non-interactive use" >&2
            exit 64
        fi
        {
            echo "WARNING: teardown will revoke subscriptions, drop LF grants we added,"
            echo "         remove the KMS policy statement, detach IAM inline policies,"
            echo "         and (unless --keep-cfn) DELETE the SMUS CFN stack."
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
        echo "==> teardown 1/6: revoking subscriptions held by ${_project_id}"
        # `list-subscriptions` requires one of subscribedListingId,
        # owningProjectId, approverProjectId, or subscriptionRequestId.
        # In this repo publisher == subscriber == admin project, so
        # `--owning-project-id` returns the very rows we need to undo.
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

    # ---- 2. Revoke LF DESCRIBE on resource links + project DB. ----
    local _project_user_role=""
    if [ -n "$_project_id" ]; then
        echo "==> teardown 2/6: revoking LF DESCRIBE on resource links"
        local _lh_env_id _project_db _tooling_env_id
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

    # ---- 3. Remove the KMS key policy statement we added. ----
    echo "==> teardown 3/6: removing AllowProjectUserRoleForSparkLogs from tooling KMS key"
    local _account
    _account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")"
    if [ -n "$_account" ]; then
        local _bucket="amazon-datazone-tooling-${_account}-${_region}"
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

    # ---- 4. Detach IAM inline policies the migration added. ----
    if [ "$TEARDOWN_KEEP_IAM" -eq 1 ]; then
        echo "==> teardown 4/6: skipped (--keep-iam-roles)"
    elif [ -n "$_project_user_role" ]; then
        echo "==> teardown 4/6: detaching IAM inline policies from project user role"
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
        echo "==> teardown 4/6: project user role not discovered; skipping IAM cleanup"
    fi

    # ---- 4b. Delete the dedicated LF registration role we created. -----
    # `smus-seed-lf-registration-role` is created by `_smus_session_bootstrap`
    # so it can re-register source S3 prefixes with --with-federation.
    # The role outlives the CFN stack (it's not in any stack), so drop
    # it explicitly here unless --keep-iam-roles.
    if [ "$TEARDOWN_KEEP_IAM" -ne 1 ] && [ "$_apply" -eq 1 ]; then
        if aws iam get-role --role-name smus-seed-lf-registration-role \
                >/dev/null 2>&1; then
            aws iam delete-role-policy --role-name smus-seed-lf-registration-role \
                --policy-name LFRegistrationPolicy >/dev/null 2>&1 || true
            if aws iam delete-role --role-name smus-seed-lf-registration-role \
                    >/dev/null 2>&1; then
                echo "    + deleted LF registration role smus-seed-lf-registration-role"
            fi
        fi
    fi

    # ---- 5. Delete the SMUS CFN stack (with hardening passes). ----
    if [ "$TEARDOWN_KEEP_CFN" -eq 1 ]; then
        echo "==> teardown 5/6: skipped (--keep-cfn)"
    else
        echo "==> teardown 5/6: deleting SMUS CFN stack (with hardening passes)"
        _teardown_destroy_smus_stack \
            "$_apply" "$_region" "$_domain_id" "$_project_id"
    fi

    # ---- 6. Wipe migration state. ----
    echo "==> teardown 6/6: wiping migration state"
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
