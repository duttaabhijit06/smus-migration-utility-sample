#!/usr/bin/env bash
#
# seed/msk/create.sh — Task 24.8.
#
# Stand up a small Amazon MSK cluster (Serverless by default; provisioned
# with 2 kafka.t3.small brokers — the smallest broker count MSK accepts,
# one broker per AZ subnet — when seed.config.json sets
# `.msk.mode = "provisioned"`) and persist its identifiers — most
# importantly its bootstrap broker string — to ./seed/seed.state.json so
# `glue/create.sh --phase=2` can read it via:
#
#     SBX_MSK_BOOTSTRAP="$(sbx_state_get '.services.msk.resources.bootstrap_brokers')"
#
# Cross-cutting contracts honored by this module (Requirements 20.9, 20.13,
# 20.19, 20.29, 20.31):
#
#   * Resource-name prefix gating (20.29). The single created cluster name
#     and the deferred sample topic name both begin with the configured
#     ${SBX_SEED_NAME_PREFIX}-.
#
#   * Idempotency (20.13). Before any state-changing AWS CLI command this
#     module runs `aws kafka list-clusters-v2 --cluster-name-filter <name>`
#     and reuses an existing cluster with a matching name; it issues zero
#     `aws kafka create-*` commands when one already exists.
#
#   * Post-migration idempotency (20.32). This module never calls
#     `aws datazone create-*` and never references the SMUS_Domain ID or
#     Admin_Project ID recorded in ./config/migration.config.json. A re-run
#     after the Migration_Tool has run is a no-op for SMUS state.
#
#   * Same-account contract (20.28). `sbx_assert_same_account` runs before
#     any state-changing command and halts when ./seed/seed.config.json and
#     ./config/migration.config.json disagree on `source_account_id`.
#
#   * Default dry-run; `--apply` and `--dry-run` mutually exclusive
#     (Requirements 20.2, 20.3, 20.4 — enforced by `sbx_init` in
#     ./seed/_lib/common.sh).
#
# Topic-creation caveat (also documented in README.md): the AWS CLI does
# NOT currently expose a control-plane verb to create Kafka topics on an
# MSK cluster. Topic creation requires running `kafka-topics.sh` against
# the cluster's bootstrap brokers from a host inside the cluster VPC,
# authenticated with SASL/IAM (serverless) or the cluster's configured
# auth (provisioned). The seed therefore RECORDS the planned sample-topic
# name (`<prefix>-events`) in seed.state.json with `status:
# "deferred_to_operator"` and emits a STATUS line documenting the
# follow-up; the README spells out the exact `kafka-topics.sh` invocation.
#

set -euo pipefail

# -----------------------------------------------------------------------------
# Resolve own location and source the shared seed helpers BEFORE any
# `set -u`-sensitive use of SBX_* env vars; sbx_init validates the three
# core vars (SBX_REGION, SBX_SOURCE_ACCOUNT_ID, SBX_SEED_NAME_PREFIX) and
# parses --apply / --dry-run. (Per the lib's "Discipline" header,
# common.sh deliberately does not enable `set -e/-u`; each entry script
# chooses its own discipline AFTER sourcing.)
__SBX_MSK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib/common.sh disable=SC1091
source "${__SBX_MSK_DIR}/../_lib/common.sh"

sbx_init "msk" "$@"
sbx_assert_same_account

# -----------------------------------------------------------------------------
# Names — prefix-gated per Requirement 20.29. The cluster name is the
# spec-mandated `<prefix>-msk-cluster` (task 24.8) and the sample topic
# is `<prefix>-events`.
# -----------------------------------------------------------------------------
CLUSTER_NAME="${SBX_SEED_NAME_PREFIX}-msk-cluster"
SAMPLE_TOPIC="${SBX_SEED_NAME_PREFIX}-events"
SEED_CONFIG="$(sbx_config_path)"

# Smallest viable provisioned-mode shape per task 24.8: 2 brokers of class
# kafka.t3.small. Two is the floor because MSK's provisioned-mode minimum
# is 1 broker per client subnet AZ and the smallest supported broker
# count is 2 (one broker each across two AZs); using a single broker is
# rejected by `aws kafka create-cluster` with "Number of broker nodes
# must be a multiple of the number of subnets". Serverless mode (the
# default) sidesteps this entirely — operators do not size brokers.
PROVISIONED_BROKER_COUNT=2
PROVISIONED_BROKER_INSTANCE="kafka.t3.small"

# -----------------------------------------------------------------------------
# Read mode + VPC config from seed.config.json.
#
# Defaults:
#   .msk.mode             = "serverless"
#   .msk.kafka_version    = "3.6.0" (only used in provisioned mode)
#   .msk.vpc_subnet_ids   = []
#   .msk.security_group_ids = []
#
# The two VPC arrays are required in apply mode (both serverless and
# provisioned MSK shapes need subnets + security groups). In dry-run we
# print the would-be command with empty arrays so the operator can see
# the missing fields without failing the dry-run.
# -----------------------------------------------------------------------------
MSK_MODE="serverless"
KAFKA_VERSION="3.6.0"
VPC_SUBNETS_JSON="[]"
VPC_SGS_JSON="[]"

if [ -f "$SEED_CONFIG" ] && command -v jq >/dev/null 2>&1; then
    _m="$(jq -r '.msk.mode // empty' "$SEED_CONFIG" 2>/dev/null || true)"
    [ -n "$_m" ] && MSK_MODE="$_m"
    _kv="$(jq -r '.msk.kafka_version // empty' "$SEED_CONFIG" 2>/dev/null || true)"
    [ -n "$_kv" ] && KAFKA_VERSION="$_kv"
    VPC_SUBNETS_JSON="$(jq -c '.msk.vpc_subnet_ids // []' "$SEED_CONFIG" 2>/dev/null || echo '[]')"
    VPC_SGS_JSON="$(jq -c '.msk.security_group_ids // []' "$SEED_CONFIG" 2>/dev/null || echo '[]')"
fi

case "$MSK_MODE" in
    serverless|provisioned) ;;
    *)
        sbx_status error "invalid_msk_mode ${MSK_MODE}; expected serverless|provisioned"
        exit 64
        ;;
esac

if sbx_apply_mode; then
    if [ "$VPC_SUBNETS_JSON" = "[]" ] || [ "$VPC_SGS_JSON" = "[]" ]; then
        sbx_status error "msk_vpc_config_required: set .msk.vpc_subnet_ids and .msk.security_group_ids in seed.config.json before --apply"
        exit 64
    fi
fi

sbx_log "msk: mode=${MSK_MODE} cluster=${CLUSTER_NAME} region=${SBX_REGION}"

# -----------------------------------------------------------------------------
# Idempotency lookup — discover an existing cluster matching CLUSTER_NAME.
#
# `aws kafka list-clusters-v2 --cluster-name-filter <name>` filters by
# name PREFIX, so a strict-equals filter is applied client-side via jq.
# Returns:
#   EXISTING_CLUSTER_ARN   ARN of an existing cluster with that exact name,
#                          or empty when none.
#   EXISTING_CLUSTER_TYPE  "Serverless" | "Provisioned" | empty.
# In dry-run, sbx_aws prints the would-be command and returns 0 without
# emitting JSON; we treat that as "no existing cluster" so the dry-run
# path prints every would-be create-* command the operator can audit.
# -----------------------------------------------------------------------------
EXISTING_CLUSTER_ARN=""
EXISTING_CLUSTER_TYPE=""

if sbx_apply_mode; then
    # Apply-mode capture: bypass sbx_aws so the STATUS line it would emit
    # to stdout does not pollute the JSON we are about to parse with jq.
    # We still emit the STATUS audit line manually so the run log records
    # the action.
    sbx_status action "aws kafka list-clusters-v2"
    _list_json="$(aws kafka list-clusters-v2 \
        --region "$SBX_REGION" \
        --cluster-name-filter "$CLUSTER_NAME" \
        --output json 2>/dev/null || echo '{}')"
    if command -v jq >/dev/null 2>&1; then
        EXISTING_CLUSTER_ARN="$(printf '%s' "$_list_json" | jq -r --arg n "$CLUSTER_NAME" \
            '(.ClusterInfoList // []) | map(select(.ClusterName == $n)) | (.[0].ClusterArn // "")')"
        EXISTING_CLUSTER_TYPE="$(printf '%s' "$_list_json" | jq -r --arg n "$CLUSTER_NAME" \
            '(.ClusterInfoList // []) | map(select(.ClusterName == $n)) | (.[0].ClusterType // "")')"
    fi
else
    sbx_aws kafka list-clusters-v2 \
        --region "$SBX_REGION" \
        --cluster-name-filter "$CLUSTER_NAME" \
        --output json >/dev/null || true
fi

# -----------------------------------------------------------------------------
# Build the create-cluster-v2 / create-cluster request and invoke it once,
# only when no existing cluster was found. The serverless and provisioned
# request shapes are constructed via jq so JSON escaping is handled
# correctly for any subnet/SG IDs the operator configures.
# -----------------------------------------------------------------------------
CLUSTER_ARN=""

if [ -n "$EXISTING_CLUSTER_ARN" ]; then
    sbx_status ok "msk_cluster_exists name=${CLUSTER_NAME} arn=${EXISTING_CLUSTER_ARN} type=${EXISTING_CLUSTER_TYPE}"
    CLUSTER_ARN="$EXISTING_CLUSTER_ARN"
    # Honor whatever mode the existing cluster reports rather than the
    # config's preferred mode, so a re-run that toggles the config knob
    # cannot misclassify what is already deployed.
    case "$EXISTING_CLUSTER_TYPE" in
        Serverless) MSK_MODE="serverless" ;;
        Provisioned) MSK_MODE="provisioned" ;;
    esac
else
    if [ "$MSK_MODE" = "serverless" ]; then
        # Serverless request shape: VpcConfigs is a list of
        # { SubnetIds, SecurityGroupIds }, ClientAuthentication.Sasl.Iam
        # is the only auth mode Serverless supports today.
        _req="$(jq -n \
            --arg name "$CLUSTER_NAME" \
            --argjson subnets "$VPC_SUBNETS_JSON" \
            --argjson sgs "$VPC_SGS_JSON" \
            '{
                ClusterName: $name,
                Serverless: {
                    VpcConfigs: [
                        { SubnetIds: $subnets, SecurityGroupIds: $sgs }
                    ],
                    ClientAuthentication: { Sasl: { Iam: { Enabled: true } } }
                },
                Tags: { "sbx:seed-name-prefix": "true" }
            }')"

        # Pass the request via a tempfile so embedded JSON cannot collide
        # with shell quoting. We previously tried `file:///dev/stdin` with
        # a piped stdin, but that path is unreliable across AWS CLI
        # versions (the CLI parses the file before stdin is fully read in
        # some shells, yielding "Invalid JSON received"). A real tempfile
        # avoids the race entirely and is what the AWS docs canonically
        # recommend for `--cli-input-json file://...`.
        if sbx_apply_mode; then
            sbx_status action "aws kafka create-cluster-v2"
            _req_tmp="$(mktemp -t "sbx-msk-create-v2-XXXXXX.json")"
            printf '%s' "$_req" > "$_req_tmp"
            _create_json="$(aws kafka create-cluster-v2 \
                --region "$SBX_REGION" \
                --cli-input-json "file://${_req_tmp}" \
                --output json)"
            rm -f "$_req_tmp"
            CLUSTER_ARN="$(printf '%s' "$_create_json" | jq -r '.ClusterArn // empty')"
        else
            sbx_aws kafka create-cluster-v2 \
                --region "$SBX_REGION" \
                --cluster-name "$CLUSTER_NAME" \
                --serverless "VpcConfigs=[{SubnetIds=${VPC_SUBNETS_JSON},SecurityGroupIds=${VPC_SGS_JSON}}],ClientAuthentication={Sasl={Iam={Enabled=true}}}" >/dev/null || true
        fi
    else
        # Provisioned shape: ${PROVISIONED_BROKER_COUNT} brokers of class
        # ${PROVISIONED_BROKER_INSTANCE} (the cheapest broker class MSK
        # currently lists). The seed deliberately uses the smallest viable
        # provisioned configuration because the cluster exists only to
        # exercise migration tool discovery paths, not to handle production
        # load. AWS requires NumberOfBrokerNodes >= number of client
        # subnets (one broker per subnet AZ) — see PROVISIONED_BROKER_COUNT
        # comment above.
        _req="$(jq -n \
            --arg name "$CLUSTER_NAME" \
            --arg version "$KAFKA_VERSION" \
            --arg instance "$PROVISIONED_BROKER_INSTANCE" \
            --argjson brokers "$PROVISIONED_BROKER_COUNT" \
            --argjson subnets "$VPC_SUBNETS_JSON" \
            --argjson sgs "$VPC_SGS_JSON" \
            '{
                ClusterName: $name,
                KafkaVersion: $version,
                NumberOfBrokerNodes: $brokers,
                BrokerNodeGroupInfo: {
                    InstanceType: $instance,
                    ClientSubnets: $subnets,
                    SecurityGroups: $sgs,
                    StorageInfo: { EBSStorageInfo: { VolumeSize: 10 } }
                },
                EncryptionInfo: {
                    EncryptionInTransit: { ClientBroker: "TLS", InCluster: true }
                },
                Tags: { "sbx:seed-name-prefix": "true" }
            }')"

        if sbx_apply_mode; then
            sbx_status action "aws kafka create-cluster"
            _req_tmp="$(mktemp -t "sbx-msk-create-XXXXXX.json")"
            printf '%s' "$_req" > "$_req_tmp"
            _create_json="$(aws kafka create-cluster \
                --region "$SBX_REGION" \
                --cli-input-json "file://${_req_tmp}" \
                --output json)"
            rm -f "$_req_tmp"
            CLUSTER_ARN="$(printf '%s' "$_create_json" | jq -r '.ClusterArn // empty')"
        else
            sbx_aws kafka create-cluster \
                --region "$SBX_REGION" \
                --cluster-name "$CLUSTER_NAME" \
                --kafka-version "$KAFKA_VERSION" \
                --number-of-broker-nodes "$PROVISIONED_BROKER_COUNT" \
                --broker-node-group-info "InstanceType=${PROVISIONED_BROKER_INSTANCE},ClientSubnets=${VPC_SUBNETS_JSON},SecurityGroups=${VPC_SGS_JSON},StorageInfo={EBSStorageInfo={VolumeSize=10}}" >/dev/null || true
        fi
    fi
fi

# -----------------------------------------------------------------------------
# Persist what we know BEFORE waiting for ACTIVE. Requirement 20.12 says
# resource identifiers MUST be persisted before any further state-changing
# AWS CLI command, so this write must precede the wait/poll loop. The
# bootstrap_brokers field is set to empty for now and updated below once
# the cluster reaches ACTIVE; downstream consumers (glue phase 2) read
# from this exact path:
#
#     .services.msk.resources.bootstrap_brokers
#
# Bug fix 1a: state writes happen ONLY in apply mode. The previous
# revision wrote a `provisioning` stub during dry-run, which both lied
# about what AWS contained AND broke the orchestrator's --skip-completed
# logic on a follow-up `--apply` (the stale state stub would convince
# `_should_skip_service` that nothing was pending, even though no real
# AWS resource existed).
# -----------------------------------------------------------------------------
if sbx_apply_mode; then
    sbx_state_set_service msk "$(jq -n \
        --arg name "$CLUSTER_NAME" \
        --arg arn "${CLUSTER_ARN:-}" \
        --arg mode "$MSK_MODE" \
        --arg topic "$SAMPLE_TOPIC" \
        '{
            status: "provisioning",
            resources: {
                cluster: { name: $name, arn: $arn, mode: $mode },
                bootstrap_brokers: "",
                topics: [ { name: $topic, status: "deferred_to_operator" } ]
            }
        }')"
fi

# -----------------------------------------------------------------------------
# Wait for ACTIVE. Bounded poll loop in apply mode only — dry-run skips
# the wait entirely so a dry-run never blocks for tens of minutes.
#
# MSK provisioned clusters routinely take 15–30 minutes to reach ACTIVE;
# Serverless typically reaches ACTIVE in 2–5 minutes. The poll budget
# below accommodates the slower of the two with 5% headroom (60 polls *
# 30 s = 30 min). The loop emits a STATUS line every 6 polls (~3 min) so
# the per-invocation log records progress without flooding stdout.
# -----------------------------------------------------------------------------
if sbx_apply_mode && [ -n "$CLUSTER_ARN" ]; then
    sbx_status action "msk_wait_active arn=${CLUSTER_ARN}"
    _state="UNKNOWN"
    _i=0
    _max_polls=60
    while [ "$_i" -lt "$_max_polls" ]; do
        _desc_json="$(aws kafka describe-cluster-v2 \
            --region "$SBX_REGION" \
            --cluster-arn "$CLUSTER_ARN" \
            --output json 2>/dev/null || echo '{}')"
        _state="$(printf '%s' "$_desc_json" | jq -r '.ClusterInfo.State // "UNKNOWN"')"
        case "$_state" in
            ACTIVE) break ;;
            FAILED|DELETING|UPDATING_FAILED)
                sbx_status error "msk_cluster_unhealthy state=${_state} arn=${CLUSTER_ARN}"
                sbx_state_set_service msk '{"status":"failed"}'
                exit 1
                ;;
        esac
        if [ $((_i % 6)) -eq 0 ]; then
            sbx_status in-progress "msk_wait_active poll=${_i}/${_max_polls} state=${_state}"
        fi
        _i=$((_i + 1))
        sleep 30
    done

    if [ "$_state" != "ACTIVE" ]; then
        sbx_status error "msk_wait_active_timeout state=${_state} arn=${CLUSTER_ARN} polls=${_max_polls}"
        sbx_state_set_service msk '{"status":"failed"}'
        exit 1
    fi
    sbx_status ok "msk_active arn=${CLUSTER_ARN}"
fi

# -----------------------------------------------------------------------------
# Attach a cluster resource policy that authorizes Amazon Data Firehose
# to create a VPC connection back to this MSK cluster. Required when a
# Firehose delivery stream uses MSK-as-source (post-resequencing flow):
# without this policy, Firehose's `kafka:CreateVpcConnection` call is
# denied and the delivery stream lands in CREATING_FAILED with reason
# CREATE_PRIVATE_LINK_FAILED.
#
# Idempotent: re-running put-cluster-policy on an existing identical
# document is a no-op AWS-side. The principal `firehose.amazonaws.com`
# is the canonical Firehose service principal; the resource conditions
# scope the grant to this specific cluster.
# -----------------------------------------------------------------------------
if sbx_apply_mode && [ -n "$CLUSTER_ARN" ]; then
    sbx_status action "msk_put_cluster_policy arn=${CLUSTER_ARN}"
    _policy_tmp="$(mktemp -t "sbx-msk-policy-XXXXXX.json")"
    jq -n \
        --arg cluster_arn "$CLUSTER_ARN" \
        '{
            Version: "2012-10-17",
            Statement: [
                {
                    Sid: "FirehoseVpcConnect",
                    Effect: "Allow",
                    Principal: { Service: "firehose.amazonaws.com" },
                    Action: [
                        "kafka:CreateVpcConnection",
                        "kafka:GetBootstrapBrokers",
                        "kafka:DescribeClusterV2"
                    ],
                    Resource: $cluster_arn
                }
            ]
        }' > "$_policy_tmp"
    if ! aws kafka put-cluster-policy \
            --region "$SBX_REGION" \
            --cluster-arn "$CLUSTER_ARN" \
            --policy "$(cat "$_policy_tmp")" >/dev/null 2>&1; then
        sbx_log "warning: put-cluster-policy returned non-zero; Firehose-MSK may need manual policy attachment"
    fi
    rm -f "$_policy_tmp"
elif [ -n "$CLUSTER_ARN" ]; then
    sbx_aws kafka put-cluster-policy \
        --region "$SBX_REGION" \
        --cluster-arn "$CLUSTER_ARN" \
        --policy '{"Version":"2012-10-17","Statement":[{"Sid":"FirehoseVpcConnect","Effect":"Allow","Principal":{"Service":"firehose.amazonaws.com"},"Action":["kafka:CreateVpcConnection","kafka:GetBootstrapBrokers","kafka:DescribeClusterV2"],"Resource":"<cluster-arn>"}]}'
fi

# -----------------------------------------------------------------------------
# Fetch bootstrap brokers and persist to seed.state.json.
#
# Both serverless and provisioned clusters expose bootstrap brokers via
# `aws kafka get-bootstrap-brokers`. Serverless clusters return only the
# SASL/IAM endpoint (`BootstrapBrokerStringSaslIam`); provisioned with
# TLS-in-transit returns `BootstrapBrokerStringTls`. We prefer SASL/IAM
# (covers serverless, and provisioned with IAM auth), falling back to
# TLS for plain-TLS provisioned clusters.
#
# The resulting string is the contract glue/create.sh --phase=2 reads via:
#     SBX_MSK_BOOTSTRAP="$(sbx_state_get '.services.msk.resources.bootstrap_brokers')"
# -----------------------------------------------------------------------------
BOOTSTRAP_BROKERS=""

if sbx_apply_mode && [ -n "$CLUSTER_ARN" ]; then
    sbx_status action "aws kafka get-bootstrap-brokers"
    _bb_json="$(aws kafka get-bootstrap-brokers \
        --region "$SBX_REGION" \
        --cluster-arn "$CLUSTER_ARN" \
        --output json 2>/dev/null || echo '{}')"
    BOOTSTRAP_BROKERS="$(printf '%s' "$_bb_json" | jq -r '
        .BootstrapBrokerStringSaslIam //
        .BootstrapBrokerStringTls //
        .BootstrapBrokerStringSaslScram //
        .BootstrapBrokerString //
        empty
    ')"
    if [ -z "$BOOTSTRAP_BROKERS" ]; then
        sbx_status error "msk_bootstrap_unavailable arn=${CLUSTER_ARN}"
        sbx_state_set_service msk '{"status":"failed"}'
        exit 1
    fi
    sbx_status set "msk.bootstrap_brokers (length=${#BOOTSTRAP_BROKERS})"
else
    sbx_aws kafka get-bootstrap-brokers \
        --region "$SBX_REGION" \
        --cluster-arn "${CLUSTER_ARN:-DRY-RUN-PLACEHOLDER-ARN}" >/dev/null || true
fi

# -----------------------------------------------------------------------------
# Sample topic — see the topic-creation caveat at the top of this file.
#
# AWS CLI does not expose a control-plane verb to create Kafka topics on
# MSK. The seed records the planned topic name and `status:
# "deferred_to_operator"` in seed.state.json; the README documents the
# follow-up `kafka-topics.sh` invocation. We emit a STATUS line so the
# expectation is visible in the per-invocation log.
# -----------------------------------------------------------------------------
sbx_status action "msk_topic_deferred name=${SAMPLE_TOPIC} reason=no_aws_cli_verb (operator must run kafka-topics.sh; see README.md)"

# -----------------------------------------------------------------------------
# Final state write — bootstrap_brokers is now authoritative.
#
# This is the contract write: glue phase 2 reads
# `.services.msk.resources.bootstrap_brokers` from this exact document.
# Status flips to `provisioned` to satisfy the orchestrator's "Available"
# expectation in 24.3.
# -----------------------------------------------------------------------------
if sbx_apply_mode; then
    sbx_state_set_service msk "$(jq -n \
        --arg name "$CLUSTER_NAME" \
        --arg arn "$CLUSTER_ARN" \
        --arg mode "$MSK_MODE" \
        --arg brokers "$BOOTSTRAP_BROKERS" \
        --arg topic "$SAMPLE_TOPIC" \
        '{
            status: "provisioned",
            resources: {
                cluster: { name: $name, arn: $arn, mode: $mode },
                bootstrap_brokers: $brokers,
                topics: [ { name: $topic, status: "deferred_to_operator" } ]
            }
        }')"
    sbx_status ok "msk_provisioned cluster=${CLUSTER_NAME} arn=${CLUSTER_ARN} mode=${MSK_MODE}"
else
    sbx_status ok "msk_dry_run cluster=${CLUSTER_NAME} mode=${MSK_MODE}"
fi
