#!/usr/bin/env bash
#
# nuke.sh — single, self-contained foreground teardown for every AWS
# resource matching the seed prefix. Audits AWS directly; ignores the
# seed.state.json file. Synchronous: blocks the terminal until every
# delete is verified.
#
# Usage:
#   ./nuke.sh --apply --profile smus-seed --yes
#   ./nuke.sh --dry-run --profile smus-seed
#
# Flags:
#   --apply        Execute deletes (mutually exclusive with --dry-run).
#   --dry-run      Print what would be deleted; default if neither given.
#   --profile NAME AWS CLI profile (required unless AWS_PROFILE is set).
#   --region NAME  Override region (defaults from seed.config.json).
#   --prefix NAME  Override prefix (defaults from seed.config.json).
#   --yes          Skip confirmation prompt.
#
# Compatible with bash 3.2 (macOS default) — no mapfile, no associative
# arrays, no ${var,,} lowercasing.
#

set -uo pipefail
# Bash 3.2 + set -u + empty array `"${arr[@]}"` raises "unbound variable".
# Disable -u for the rest of the script; we still benefit from -o pipefail
# and explicit failure tracking.
set +u

# -----------------------------------------------------------------------------
# CLI parsing
# -----------------------------------------------------------------------------
PROFILE=""
REGION=""
PREFIX=""
MODE=""
ASSUME_YES=0

usage() { sed -n '2,30p' "$0"; exit 64; }

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)     MODE="apply"; shift ;;
        --dry-run)   MODE="dry-run"; shift ;;
        --profile)   PROFILE="$2"; shift 2 ;;
        --profile=*) PROFILE="${1#*=}"; shift ;;
        --region)    REGION="$2"; shift 2 ;;
        --region=*)  REGION="${1#*=}"; shift ;;
        --prefix)    PREFIX="$2"; shift 2 ;;
        --prefix=*)  PREFIX="${1#*=}"; shift ;;
        --yes|-y)    ASSUME_YES=1; shift ;;
        -h|--help)   usage ;;
        *) echo "unknown flag: $1" >&2; usage ;;
    esac
done
[ -z "$MODE" ] && MODE="dry-run"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED_CFG="${ROOT_DIR}/seed/seed.config.json"
if [ -f "$SEED_CFG" ] && command -v jq >/dev/null 2>&1; then
    [ -z "$REGION" ] && REGION="$(jq -r '.aws_region // empty' "$SEED_CFG")"
    [ -z "$PREFIX" ] && PREFIX="$(jq -r '.seed_name_prefix // empty' "$SEED_CFG")"
fi
[ -z "$REGION" ] && REGION="us-east-1"
[ -z "$PREFIX" ] && { echo "ERROR: --prefix not set and not found in ${SEED_CFG}" >&2; exit 64; }

AWS_ARGS=(--region "$REGION")
if [ -n "$PROFILE" ]; then
    AWS_ARGS+=(--profile "$PROFILE")
    export AWS_PROFILE="$PROFILE"
fi

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
ts()  { date +'%Y-%m-%dT%H:%M:%S'; }
log() { echo "[$(ts)] $*"; }
hdr() { echo; echo "=== $* ==="; }

# Run an AWS CLI command; in dry-run prints the would-be command.
run() {
    if [ "$MODE" = "dry-run" ]; then
        printf 'DRY-RUN:'
        printf ' %q' aws "$@" "${AWS_ARGS[@]}"
        printf '\n'
        return 0
    fi
    aws "$@" "${AWS_ARGS[@]}"
}

# Run an AWS CLI mutating command silently in apply mode (no-op in dry-run).
run_quiet() {
    if [ "$MODE" = "dry-run" ]; then
        return 0
    fi
    aws "$@" "${AWS_ARGS[@]}" >/dev/null 2>&1
}

# Always-on read-only AWS query (regardless of mode).
read_aws() {
    aws "$@" "${AWS_ARGS[@]}"
}

# list_to_var <varname> <cmd...>
# Captures the cmd's stdout, splits on whitespace/newlines, assigns to
# the named array. Bash-3.2 compatible (no mapfile). On error or empty
# output the array is set to an empty array.
list_to_var() {
    local _var="$1"; shift
    local _out
    _out="$("$@" 2>/dev/null)"
    # Normalise tabs/newlines/multispace to single \n; drop blanks.
    _out="$(printf '%s' "$_out" | tr '\t' '\n' | sed '/^[[:space:]]*$/d')"
    # Reset target to empty array.
    eval "${_var}=()"
    if [ -z "$_out" ]; then
        return 0
    fi
    local _line
    while IFS= read -r _line; do
        [ -z "$_line" ] && continue
        eval "${_var}+=(\"\$_line\")"
    done <<EOF
$_out
EOF
}

starts_with_prefix() {
    case "${1:-}" in
        "${PREFIX}-"*) return 0 ;;
        *) return 1 ;;
    esac
}

# wait_until <label> <max-polls> <interval-s> <aws-args...>
# Repeatedly runs the AWS read; returns 0 when it fails (resource gone),
# 1 on timeout. Skipped in dry-run.
wait_until() {
    local _label="$1"; shift
    local _max="$1"; shift
    local _interval="$1"; shift
    if [ "$MODE" = "dry-run" ]; then
        echo "DRY-RUN: would wait_until ${_label}"
        return 0
    fi
    local _i=0
    while [ "$_i" -lt "$_max" ]; do
        if ! aws "$@" "${AWS_ARGS[@]}" >/dev/null 2>&1; then
            log "  ${_label}: gone (poll ${_i}/${_max})"
            return 0
        fi
        if [ $((_i % 4)) -eq 0 ]; then
            log "  ${_label}: still present (poll ${_i}/${_max})"
        fi
        _i=$((_i + 1))
        sleep "$_interval"
    done
    log "  ${_label}: TIMED OUT after $((_max * _interval))s"
    return 1
}

# -----------------------------------------------------------------------------
# Banner & confirmation
# -----------------------------------------------------------------------------
cat <<EOF
nuke.sh
  region:   ${REGION}
  profile:  ${PROFILE:-<env>}
  prefix:   ${PREFIX}
  mode:     ${MODE}
EOF

if [ "$MODE" = "apply" ] && [ "$ASSUME_YES" -ne 1 ]; then
    if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
        echo "ERROR: --apply requires a TTY for confirmation; pass --yes for non-interactive runs" >&2
        exit 64
    fi
    {
        echo
        echo "WARNING: about to delete EVERY AWS resource matching:"
        echo "         prefix='${PREFIX}-'  in region=${REGION}"
        echo
        printf "Type '%s' to confirm: " "$PREFIX"
    } > /dev/tty
    typed=""
    IFS= read -r typed < /dev/tty || typed=""
    if [ "$typed" != "$PREFIX" ]; then
        echo "ABORTED: prefix mismatch; nothing deleted." > /dev/tty
        exit 1
    fi
fi

# -----------------------------------------------------------------------------
# Track failures across phases.
# -----------------------------------------------------------------------------
FAILURES=()
record_failure() { FAILURES+=("$1"); log "FAILURE recorded: $1"; }

# Verify caller identity.
hdr "Verifying AWS identity"
if ! read_aws sts get-caller-identity --output json; then
    echo "ERROR: aws sts get-caller-identity failed; check --profile/credentials" >&2
    exit 64
fi

# Pre-declare arrays so set -u doesn't bite when they're empty.
GLUE_CRAWLERS=(); GLUE_JOBS=(); LAMBDAS=(); EVENT_RULES=(); CW_ALARMS=()
MWAA_ENVS=(); FH_STREAMS=(); MSK_ARNS=(); RDS_INSTS=(); KIN_STREAMS=()
GLUE_CONNS=(); GLUE_DBS=(); SNS_TOPICS=(); BUCKETS=(); SEED_SGS=()
RDS_SNGS=(); IAM_ROLES=()

# =============================================================================
# Phase 1: Stop running Glue crawlers / jobs
# =============================================================================
hdr "Phase 1/18 — stop running Glue crawlers / jobs"

list_to_var GLUE_CRAWLERS \
    aws glue list-crawlers --output text \
    --query "CrawlerNames[?starts_with(@,'${PREFIX}-')]" "${AWS_ARGS[@]}"
for c in "${GLUE_CRAWLERS[@]}"; do
    log "stop-crawler ${c}"
    run_quiet glue stop-crawler --name "$c" || true
done

list_to_var GLUE_JOBS \
    aws glue list-jobs --output text \
    --query "JobNames[?starts_with(@,'${PREFIX}-')]" "${AWS_ARGS[@]}"
for j in "${GLUE_JOBS[@]}"; do
    RUNS=()
    list_to_var RUNS \
        aws glue get-job-runs --job-name "$j" --output text \
        --query "JobRuns[?JobRunState=='RUNNING' || JobRunState=='STARTING'].Id" "${AWS_ARGS[@]}"
    for r in "${RUNS[@]}"; do
        log "batch-stop-job-run ${j} ${r}"
        run_quiet glue batch-stop-job-run --job-name "$j" --job-run-ids "$r" || true
    done
done

# =============================================================================
# Phase 2: Lambda functions (release their VPC ENIs)
# =============================================================================
hdr "Phase 2/18 — Lambda functions"

list_to_var LAMBDAS \
    aws lambda list-functions --output text \
    --query "Functions[?starts_with(FunctionName,'${PREFIX}-')].FunctionName" "${AWS_ARGS[@]}"
log "found ${#LAMBDAS[@]} Lambda(s): ${LAMBDAS[*]:-<none>}"
for fn in "${LAMBDAS[@]}"; do
    starts_with_prefix "$fn" || { log "skip ${fn} (no prefix)"; continue; }
    ESM=()
    list_to_var ESM \
        aws lambda list-event-source-mappings --function-name "$fn" --output text \
        --query 'EventSourceMappings[].UUID' "${AWS_ARGS[@]}"
    for u in "${ESM[@]}"; do
        log "delete-event-source-mapping ${u}"
        run lambda delete-event-source-mapping --uuid "$u" >/dev/null || true
    done
    log "delete-function ${fn}"
    run lambda delete-function --function-name "$fn" || record_failure "lambda:${fn}"
done

# =============================================================================
# Phase 3: EventBridge rules + targets
# =============================================================================
hdr "Phase 3/18 — EventBridge rules"

list_to_var EVENT_RULES \
    aws events list-rules --name-prefix "${PREFIX}-" --output text \
    --query 'Rules[].Name' "${AWS_ARGS[@]}"
log "found ${#EVENT_RULES[@]} rule(s): ${EVENT_RULES[*]:-<none>}"
for rule in "${EVENT_RULES[@]}"; do
    starts_with_prefix "$rule" || continue
    TARGETS=()
    list_to_var TARGETS \
        aws events list-targets-by-rule --rule "$rule" --output text \
        --query 'Targets[].Id' "${AWS_ARGS[@]}"
    if [ "${#TARGETS[@]}" -gt 0 ]; then
        log "remove-targets ${rule} (${#TARGETS[@]})"
        run events remove-targets --rule "$rule" --ids "${TARGETS[@]}" >/dev/null || true
    fi
    log "delete-rule ${rule}"
    run events delete-rule --name "$rule" || record_failure "event-rule:${rule}"
done

# =============================================================================
# Phase 4: CloudWatch alarms
# =============================================================================
hdr "Phase 4/18 — CloudWatch alarms"

list_to_var CW_ALARMS \
    aws cloudwatch describe-alarms --alarm-name-prefix "${PREFIX}-" --output text \
    --query 'MetricAlarms[].AlarmName' "${AWS_ARGS[@]}"
log "found ${#CW_ALARMS[@]} alarm(s): ${CW_ALARMS[*]:-<none>}"
if [ "${#CW_ALARMS[@]}" -gt 0 ]; then
    log "delete-alarms ${CW_ALARMS[*]}"
    run cloudwatch delete-alarms --alarm-names "${CW_ALARMS[@]}" || record_failure "cw-alarms"
fi

# =============================================================================
# Phase 5: MWAA (initiate; long async)
# =============================================================================
hdr "Phase 5/18 — initiate MWAA delete"

list_to_var MWAA_ENVS \
    aws mwaa list-environments --output text \
    --query "Environments[?starts_with(@,'${PREFIX}-')]" "${AWS_ARGS[@]}"
log "found ${#MWAA_ENVS[@]} MWAA env(s): ${MWAA_ENVS[*]:-<none>}"
for env in "${MWAA_ENVS[@]}"; do
    starts_with_prefix "$env" || continue
    log "delete-environment ${env}"
    run mwaa delete-environment --name "$env" >/dev/null || record_failure "mwaa:${env}"
done

# =============================================================================
# Phase 6: Firehose (initiate)
# =============================================================================
hdr "Phase 6/18 — Firehose delivery streams"

list_to_var FH_STREAMS \
    aws firehose list-delivery-streams --output text \
    --query 'DeliveryStreamNames' "${AWS_ARGS[@]}"
for s in "${FH_STREAMS[@]}"; do
    starts_with_prefix "$s" || continue
    log "delete-delivery-stream ${s}"
    run firehose delete-delivery-stream --delivery-stream-name "$s" --allow-force-delete >/dev/null || record_failure "firehose:${s}"
done

# =============================================================================
# Phase 7: MSK (initiate)
# =============================================================================
hdr "Phase 7/18 — MSK clusters"

list_to_var MSK_ARNS \
    aws kafka list-clusters-v2 --output text \
    --query "ClusterInfoList[?starts_with(ClusterName,'${PREFIX}-')].ClusterArn" "${AWS_ARGS[@]}"
log "found ${#MSK_ARNS[@]} MSK cluster(s)"
for arn in "${MSK_ARNS[@]}"; do
    log "delete-cluster ${arn}"
    run kafka delete-cluster --cluster-arn "$arn" >/dev/null || record_failure "msk:${arn}"
done

# =============================================================================
# Phase 8: RDS instances (initiate)
# =============================================================================
hdr "Phase 8/18 — RDS instances"

list_to_var RDS_INSTS \
    aws rds describe-db-instances --output text \
    --query "DBInstances[?starts_with(DBInstanceIdentifier,'${PREFIX}-')].DBInstanceIdentifier" "${AWS_ARGS[@]}"
log "found ${#RDS_INSTS[@]} RDS instance(s): ${RDS_INSTS[*]:-<none>}"
for db in "${RDS_INSTS[@]}"; do
    starts_with_prefix "$db" || continue
    run_quiet rds modify-db-instance --db-instance-identifier "$db" --no-deletion-protection --apply-immediately || true
    log "delete-db-instance ${db}"
    run rds delete-db-instance --db-instance-identifier "$db" --skip-final-snapshot --delete-automated-backups >/dev/null || record_failure "rds:${db}"
done

# =============================================================================
# Phase 9: Kinesis (initiate)
# =============================================================================
hdr "Phase 9/18 — Kinesis streams"

list_to_var KIN_STREAMS \
    aws kinesis list-streams --output text \
    --query "StreamSummaries[?starts_with(StreamName,'${PREFIX}-')].StreamName" "${AWS_ARGS[@]}"
for s in "${KIN_STREAMS[@]}"; do
    starts_with_prefix "$s" || continue
    log "delete-stream ${s}"
    run kinesis delete-stream --stream-name "$s" --enforce-consumer-deletion >/dev/null || record_failure "kinesis:${s}"
done

# =============================================================================
# Phase 10: Glue (synchronous)
# =============================================================================
hdr "Phase 10/18 — Glue jobs / crawlers / connections / tables / databases"

list_to_var GLUE_JOBS \
    aws glue list-jobs --output text \
    --query "JobNames[?starts_with(@,'${PREFIX}-')]" "${AWS_ARGS[@]}"
for j in "${GLUE_JOBS[@]}"; do
    starts_with_prefix "$j" || continue
    log "delete-job ${j}"
    run glue delete-job --job-name "$j" >/dev/null || record_failure "glue-job:${j}"
done

list_to_var GLUE_CRAWLERS \
    aws glue list-crawlers --output text \
    --query "CrawlerNames[?starts_with(@,'${PREFIX}-')]" "${AWS_ARGS[@]}"
for c in "${GLUE_CRAWLERS[@]}"; do
    starts_with_prefix "$c" || continue
    log "delete-crawler ${c}"
    run glue delete-crawler --name "$c" >/dev/null || record_failure "glue-crawler:${c}"
done

list_to_var GLUE_CONNS \
    aws glue get-connections --output text \
    --query "ConnectionList[?starts_with(Name,'${PREFIX}-')].Name" "${AWS_ARGS[@]}"
for cn in "${GLUE_CONNS[@]}"; do
    starts_with_prefix "$cn" || continue
    log "delete-connection ${cn}"
    run glue delete-connection --connection-name "$cn" >/dev/null || record_failure "glue-conn:${cn}"
done

list_to_var GLUE_DBS \
    aws glue get-databases --output text \
    --query "DatabaseList[?starts_with(Name,'${PREFIX}-')].Name" "${AWS_ARGS[@]}"
for db in "${GLUE_DBS[@]}"; do
    starts_with_prefix "$db" || continue
    TBLS=()
    list_to_var TBLS \
        aws glue get-tables --database-name "$db" --output text \
        --query 'TableList[].Name' "${AWS_ARGS[@]}"
    for t in "${TBLS[@]}"; do
        log "delete-table ${db}.${t}"
        run glue delete-table --database-name "$db" --name "$t" >/dev/null || true
    done
    log "delete-database ${db}"
    run glue delete-database --name "$db" >/dev/null || record_failure "glue-db:${db}"
done

# =============================================================================
# Phase 11: SNS
# =============================================================================
hdr "Phase 11/18 — SNS topics"

list_to_var SNS_TOPICS \
    aws sns list-topics --output text \
    --query "Topics[?contains(TopicArn,':${PREFIX}-')].TopicArn" "${AWS_ARGS[@]}"
for arn in "${SNS_TOPICS[@]}"; do
    log "delete-topic ${arn}"
    run sns delete-topic --topic-arn "$arn" >/dev/null || record_failure "sns:${arn}"
done

# =============================================================================
# Phase 12: S3 buckets
# =============================================================================
hdr "Phase 12/18 — S3 buckets"

list_to_var BUCKETS \
    aws s3api list-buckets --output text \
    --query "Buckets[?starts_with(Name,'${PREFIX}-')].Name" "${AWS_ARGS[@]}"
log "found ${#BUCKETS[@]} bucket(s): ${BUCKETS[*]:-<none>}"
for b in "${BUCKETS[@]}"; do
    starts_with_prefix "$b" || continue

    if [ "$MODE" = "apply" ]; then
        ver_json="$(aws s3api list-object-versions --bucket "$b" "${AWS_ARGS[@]}" --output json 2>/dev/null || echo '{}')"
        if command -v jq >/dev/null 2>&1; then
            del_payload="$(printf '%s' "$ver_json" | jq -c '
                {Objects: ([(.Versions // [])[], (.DeleteMarkers // [])[]]
                          | map({Key: .Key, VersionId: .VersionId})),
                 Quiet: true}')"
            obj_count="$(printf '%s' "$del_payload" | jq -r '.Objects | length')"
            if [ "${obj_count:-0}" -gt 0 ]; then
                log "delete-objects ${b} (versions=${obj_count})"
                aws s3api delete-objects --bucket "$b" "${AWS_ARGS[@]}" --delete "$del_payload" >/dev/null || true
            fi
        fi
    fi

    log "s3 rm s3://${b} --recursive"
    run s3 rm "s3://${b}" --recursive >/dev/null || true
    log "delete-bucket ${b}"
    run s3api delete-bucket --bucket "$b" || record_failure "s3:${b}"
done

# =============================================================================
# Phase 13: WAIT for async deletes (MWAA / Firehose / MSK / RDS / Kinesis)
# =============================================================================
hdr "Phase 13/18 — wait for async deletes to finish"

if [ "$MODE" = "apply" ]; then
    for env in "${MWAA_ENVS[@]}"; do
        wait_until "mwaa/${env}" 60 30 mwaa get-environment --name "$env" || record_failure "mwaa-wait:${env}"
    done
    for s in "${FH_STREAMS[@]}"; do
        starts_with_prefix "$s" || continue
        wait_until "firehose/${s}" 30 10 firehose describe-delivery-stream --delivery-stream-name "$s" || record_failure "fh-wait:${s}"
    done
    for arn in "${MSK_ARNS[@]}"; do
        wait_until "msk/${arn##*/}" 60 30 kafka describe-cluster-v2 --cluster-arn "$arn" || record_failure "msk-wait:${arn}"
    done
    for db in "${RDS_INSTS[@]}"; do
        starts_with_prefix "$db" || continue
        wait_until "rds/${db}" 30 30 rds describe-db-instances --db-instance-identifier "$db" || record_failure "rds-wait:${db}"
    done
    for s in "${KIN_STREAMS[@]}"; do
        starts_with_prefix "$s" || continue
        wait_until "kinesis/${s}" 30 10 kinesis describe-stream-summary --stream-name "$s" || record_failure "kinesis-wait:${s}"
    done
fi

# =============================================================================
# Phase 14: Identify seed SGs & release stuck Lambda VPC ENIs
# =============================================================================
hdr "Phase 14/18 — release stale ENIs pinning seed SGs"

list_to_var SEED_SGS \
    aws ec2 describe-security-groups --output text \
    --query "SecurityGroups[?starts_with(GroupName,'${PREFIX}-')].GroupId" "${AWS_ARGS[@]}"
log "found ${#SEED_SGS[@]} seed SG(s): ${SEED_SGS[*]:-<none>}"

if [ "${#SEED_SGS[@]}" -gt 0 ]; then
    sg_filter_values="$(IFS=,; echo "${SEED_SGS[*]}")"
    eni_max=24    # 6 min budget
    eni_i=0
    while [ "$eni_i" -lt "$eni_max" ]; do
        eni_lines="$(aws ec2 describe-network-interfaces \
            --filters "Name=group-id,Values=${sg_filter_values}" \
            --output text \
            --query 'NetworkInterfaces[].[NetworkInterfaceId,Status,InterfaceType,Attachment.AttachmentId]' \
            "${AWS_ARGS[@]}" 2>/dev/null | sed '/^[[:space:]]*$/d')"
        if [ -z "$eni_lines" ]; then
            log "  no ENIs left referencing seed SGs"
            break
        fi
        any_acted=0
        # Bash-3.2 safe iteration over multi-line text.
        while IFS=$'\t' read -r eni_id status iftype attach; do
            [ -z "$eni_id" ] && continue
            if [ "$status" = "available" ]; then
                log "  delete-network-interface ${eni_id} (available)"
                run_quiet ec2 delete-network-interface --network-interface-id "$eni_id" || true
                any_acted=1
                continue
            fi
            if [ "$iftype" = "lambda" ] && [ -n "$attach" ] && [ "$attach" != "None" ]; then
                log "  detach-network-interface ${eni_id} (lambda) attachment=${attach}"
                run_quiet ec2 detach-network-interface --attachment-id "$attach" --force || true
                any_acted=1
                continue
            fi
            log "  ENI ${eni_id} status=${status} type=${iftype} attach=${attach} — leaving alone"
        done <<EOF
$eni_lines
EOF

        eni_i=$((eni_i + 1))
        if [ "$any_acted" -eq 0 ]; then
            log "  ENIs still attached and not Lambda-detachable; waiting (poll ${eni_i}/${eni_max})"
            sleep 15
        else
            sleep 5
        fi
    done
fi

# =============================================================================
# Phase 15: EC2 Security Groups (with backoff on DependencyViolation)
# =============================================================================
hdr "Phase 15/18 — EC2 security groups"

for sg in "${SEED_SGS[@]}"; do
    if [ "$MODE" = "dry-run" ]; then
        run ec2 delete-security-group --group-id "$sg" || true
        continue
    fi
    sg_attempts=0
    sg_max=12
    sg_deleted=0
    while [ "$sg_attempts" -lt "$sg_max" ]; do
        if aws ec2 delete-security-group --group-id "$sg" "${AWS_ARGS[@]}" 2>/dev/null; then
            sg_deleted=1
            break
        fi
        if ! aws ec2 describe-security-groups --group-ids "$sg" "${AWS_ARGS[@]}" >/dev/null 2>&1; then
            sg_deleted=1
            break
        fi
        log "  ${sg}: DependencyViolation (attempt ${sg_attempts}); sleeping 15s"
        sg_attempts=$((sg_attempts + 1))
        sleep 15
    done
    if [ "$sg_deleted" -eq 1 ]; then
        log "${sg}: deleted"
    else
        record_failure "sg:${sg}"
    fi
done

# =============================================================================
# Phase 16: RDS subnet groups
# =============================================================================
hdr "Phase 16/18 — RDS subnet groups"

list_to_var RDS_SNGS \
    aws rds describe-db-subnet-groups --output text \
    --query "DBSubnetGroups[?starts_with(DBSubnetGroupName,'${PREFIX}-')].DBSubnetGroupName" "${AWS_ARGS[@]}"
for g in "${RDS_SNGS[@]}"; do
    starts_with_prefix "$g" || continue
    log "delete-db-subnet-group ${g}"
    run rds delete-db-subnet-group --db-subnet-group-name "$g" || record_failure "rds-sng:${g}"
done

# =============================================================================
# Phase 17: IAM roles
# =============================================================================
hdr "Phase 17/18 — IAM roles"

list_to_var IAM_ROLES \
    aws iam list-roles --output text \
    --query "Roles[?starts_with(RoleName,'${PREFIX}-')].RoleName" "${AWS_ARGS[@]}"
log "found ${#IAM_ROLES[@]} role(s): ${IAM_ROLES[*]:-<none>}"
for role in "${IAM_ROLES[@]}"; do
    starts_with_prefix "$role" || continue

    IPROFS=()
    list_to_var IPROFS \
        aws iam list-instance-profiles-for-role --role-name "$role" --output text \
        --query 'InstanceProfiles[].InstanceProfileName' "${AWS_ARGS[@]}"
    for ip in "${IPROFS[@]}"; do
        log "remove-role-from-instance-profile ${ip} ${role}"
        run_quiet iam remove-role-from-instance-profile --instance-profile-name "$ip" --role-name "$role" || true
    done

    ATTACHED=()
    list_to_var ATTACHED \
        aws iam list-attached-role-policies --role-name "$role" --output text \
        --query 'AttachedPolicies[].PolicyArn' "${AWS_ARGS[@]}"
    for parn in "${ATTACHED[@]}"; do
        log "detach-role-policy ${role} ${parn}"
        run iam detach-role-policy --role-name "$role" --policy-arn "$parn" || true
    done

    INLINE=()
    list_to_var INLINE \
        aws iam list-role-policies --role-name "$role" --output text \
        --query 'PolicyNames' "${AWS_ARGS[@]}"
    for pn in "${INLINE[@]}"; do
        log "delete-role-policy ${role} ${pn}"
        run iam delete-role-policy --role-name "$role" --policy-name "$pn" || true
    done

    log "delete-role ${role}"
    run iam delete-role --role-name "$role" || record_failure "iam-role:${role}"
done

# =============================================================================
# Phase 18: Final audit
# =============================================================================
hdr "Phase 18/18 — final audit"

audit_count=0
audit_log() {
    local _label="$1"
    local _items="$2"
    if [ -n "$_items" ]; then
        echo "  STILL PRESENT — ${_label}: ${_items}"
        audit_count=$((audit_count + 1))
    fi
}

audit_log "Lambda functions" \
    "$(read_aws lambda list-functions --output text --query "Functions[?starts_with(FunctionName,'${PREFIX}-')].FunctionName" 2>/dev/null | tr '\t' ' ')"
audit_log "EventBridge rules" \
    "$(read_aws events list-rules --name-prefix "${PREFIX}-" --output text --query 'Rules[].Name' 2>/dev/null | tr '\t' ' ')"
audit_log "CloudWatch alarms" \
    "$(read_aws cloudwatch describe-alarms --alarm-name-prefix "${PREFIX}-" --output text --query 'MetricAlarms[].AlarmName' 2>/dev/null | tr '\t' ' ')"
audit_log "MWAA envs" \
    "$(read_aws mwaa list-environments --output text --query "Environments[?starts_with(@,'${PREFIX}-')]" 2>/dev/null | tr '\t' ' ')"
audit_log "Firehose streams" \
    "$(read_aws firehose list-delivery-streams --output text --query 'DeliveryStreamNames' 2>/dev/null | tr '\t' '\n' | grep "^${PREFIX}-" | tr '\n' ' ')"
audit_log "MSK clusters" \
    "$(read_aws kafka list-clusters-v2 --output text --query "ClusterInfoList[?starts_with(ClusterName,'${PREFIX}-')].ClusterName" 2>/dev/null | tr '\t' ' ')"
audit_log "RDS instances" \
    "$(read_aws rds describe-db-instances --output text --query "DBInstances[?starts_with(DBInstanceIdentifier,'${PREFIX}-')].DBInstanceIdentifier" 2>/dev/null | tr '\t' ' ')"
audit_log "RDS subnet groups" \
    "$(read_aws rds describe-db-subnet-groups --output text --query "DBSubnetGroups[?starts_with(DBSubnetGroupName,'${PREFIX}-')].DBSubnetGroupName" 2>/dev/null | tr '\t' ' ')"
audit_log "Kinesis streams" \
    "$(read_aws kinesis list-streams --output text --query "StreamSummaries[?starts_with(StreamName,'${PREFIX}-')].StreamName" 2>/dev/null | tr '\t' ' ')"
audit_log "Glue jobs" \
    "$(read_aws glue list-jobs --output text --query "JobNames[?starts_with(@,'${PREFIX}-')]" 2>/dev/null | tr '\t' ' ')"
audit_log "Glue crawlers" \
    "$(read_aws glue list-crawlers --output text --query "CrawlerNames[?starts_with(@,'${PREFIX}-')]" 2>/dev/null | tr '\t' ' ')"
audit_log "Glue connections" \
    "$(read_aws glue get-connections --output text --query "ConnectionList[?starts_with(Name,'${PREFIX}-')].Name" 2>/dev/null | tr '\t' ' ')"
audit_log "Glue databases" \
    "$(read_aws glue get-databases --output text --query "DatabaseList[?starts_with(Name,'${PREFIX}-')].Name" 2>/dev/null | tr '\t' ' ')"
audit_log "SNS topics" \
    "$(read_aws sns list-topics --output text --query "Topics[?contains(TopicArn,':${PREFIX}-')].TopicArn" 2>/dev/null | tr '\t' ' ')"
audit_log "S3 buckets" \
    "$(read_aws s3api list-buckets --output text --query "Buckets[?starts_with(Name,'${PREFIX}-')].Name" 2>/dev/null | tr '\t' ' ')"
audit_log "EC2 SGs" \
    "$(read_aws ec2 describe-security-groups --output text --query "SecurityGroups[?starts_with(GroupName,'${PREFIX}-')].GroupName" 2>/dev/null | tr '\t' ' ')"
audit_log "IAM roles" \
    "$(read_aws iam list-roles --output text --query "Roles[?starts_with(RoleName,'${PREFIX}-')].RoleName" 2>/dev/null | tr '\t' ' ')"

echo
if [ "${#FAILURES[@]}" -gt 0 ]; then
    echo "FAILURES during teardown:"
    for f in "${FAILURES[@]}"; do echo "  - $f"; done
fi

if [ "$audit_count" -eq 0 ] && [ "${#FAILURES[@]}" -eq 0 ]; then
    echo "==> nuke complete: nothing matching '${PREFIX}-' remains"
    exit 0
fi

echo "==> nuke FINISHED WITH ISSUES: ${audit_count} category(ies) still have residual resources, ${#FAILURES[@]} failure(s)"
exit 1
