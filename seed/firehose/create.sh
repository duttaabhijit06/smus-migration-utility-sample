#!/usr/bin/env bash
#
# seed/firehose/create.sh — Amazon Data Firehose Seed_Service_Module.
#
# Provisions two Firehose delivery streams that land Parquet files in
# the seed data bucket:
#
#   <prefix>-kinesis-to-s3-parquet    Source: kinesis stream <prefix>-events
#                                     Sink:   s3://<bucket>/raw/kinesis/dt=<hour>/
#                                     Schema-conv against Glue catalog table
#                                     <prefix>-db-raw.<prefix>_kinesis_events_parquet
#
#   <prefix>-msk-to-s3-parquet        Source: MSK topic <prefix>-events
#                                     Sink:   s3://<bucket>/raw/msk/dt=<hour>/
#                                     Schema-conv against Glue catalog table
#                                     <prefix>-db-raw.<prefix>_msk_events_parquet
#
# Required upstream state (read from seed.state.json):
#   .services.kinesis.resources.stream_arn
#   .services.msk.resources.cluster.arn
#   .services.glue.resources.data_bucket
#
# Resource-name prefix gating (Requirement 20.29): every name begins
# with `${SBX_SEED_NAME_PREFIX}-`.
#
# Bug fixes applied:
#   - 1a: state writes are gated behind sbx_apply_mode.
#   - 1b: every `--cli-input-json` invocation uses a real `mktemp` file.
#   - 1d: aws CLI captures bypass `sbx_aws` and emit STATUS manually.
#

set -euo pipefail

__firehose_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SBX_WORKDIR="${SBX_WORKDIR:-$(dirname "$(dirname "$__firehose_dir")")}"
export SBX_WORKDIR

# shellcheck source=../_lib/common.sh disable=SC1091
source "${SBX_WORKDIR}/seed/_lib/common.sh"

__SEED_CFG="$(sbx_config_path)"
if [ ! -f "$__SEED_CFG" ]; then
    sbx_status error config_missing
    exit 64
fi
if ! command -v jq >/dev/null 2>&1; then
    sbx_status error jq_required
    exit 64
fi
SBX_REGION="${SBX_REGION:-$(jq -r '.aws_region // empty' "$__SEED_CFG")}"
SBX_SOURCE_ACCOUNT_ID="${SBX_SOURCE_ACCOUNT_ID:-$(jq -r '.source_account_id // empty' "$__SEED_CFG")}"
SBX_SEED_NAME_PREFIX="${SBX_SEED_NAME_PREFIX:-$(jq -r '.seed_name_prefix // empty' "$__SEED_CFG")}"
export SBX_REGION SBX_SOURCE_ACCOUNT_ID SBX_SEED_NAME_PREFIX

sbx_init "firehose" "$@"
sbx_assert_same_account

# -----------------------------------------------------------------------------
# Names + constants.
# -----------------------------------------------------------------------------
ROLE_NAME="${SBX_SEED_NAME_PREFIX}-firehose-role"
INLINE_POLICY_NAME="firehose-write"
KINESIS_STREAM_NAME="${SBX_SEED_NAME_PREFIX}-kinesis-to-s3-parquet"
MSK_STREAM_NAME="${SBX_SEED_NAME_PREFIX}-msk-to-s3-parquet"

# Glue catalog tables Firehose's DataFormatConversionConfiguration
# references (registered by glue/create.sh phase 1).
__GLUE_TABLE_PREFIX="${SBX_SEED_NAME_PREFIX//-/_}"
DB_RAW="${SBX_SEED_NAME_PREFIX}-db-raw"
RAW_TABLE_KINESIS="${__GLUE_TABLE_PREFIX}_kinesis_events_parquet"
RAW_TABLE_MSK="${__GLUE_TABLE_PREFIX}_msk_events_parquet"

# Upstream MSK topic name (the data-gen Lambda writes to this topic
# and Firehose's MSK source binds to it).
MSK_TOPIC="${SBX_SEED_NAME_PREFIX}-events"

sbx_status started

# -----------------------------------------------------------------------------
# Read upstream state. Apply-mode hard-fails if any of these are
# missing; dry-run uses placeholders so the audit log is coherent.
# -----------------------------------------------------------------------------
KINESIS_STREAM_ARN="$(sbx_state_get '.services.kinesis.resources.stream_arn')"
MSK_CLUSTER_ARN="$(sbx_state_get '.services.msk.resources.cluster.arn')"
DATA_BUCKET="$(sbx_state_get '.services.glue.resources.data_bucket')"

# Default the data bucket to the deterministic shape glue/create.sh uses
# when state is not yet recorded (first dry-run on a clean repo).
: "${DATA_BUCKET:=${SBX_SEED_NAME_PREFIX}-glue-data-${SBX_SOURCE_ACCOUNT_ID}-${SBX_REGION}}"

if sbx_apply_mode; then
    if [ -z "$KINESIS_STREAM_ARN" ]; then
        sbx_status error "dependency_not_provisioned (.services.kinesis.resources.stream_arn empty); run seed/kinesis/create.sh --apply first"
        exit 64
    fi
    if [ -z "$MSK_CLUSTER_ARN" ]; then
        sbx_status error "dependency_not_provisioned (.services.msk.resources.cluster.arn empty); run seed/msk/create.sh --apply first"
        exit 64
    fi
    if [ -z "$DATA_BUCKET" ]; then
        sbx_status error "dependency_not_provisioned (.services.glue.resources.data_bucket empty); run seed/glue/create.sh --apply --phase=1 first"
        exit 64
    fi
else
    : "${KINESIS_STREAM_ARN:=arn:aws:kinesis:${SBX_REGION}:${SBX_SOURCE_ACCOUNT_ID}:stream/${SBX_SEED_NAME_PREFIX}-events}"
    : "${MSK_CLUSTER_ARN:=arn:aws:kafka:${SBX_REGION}:${SBX_SOURCE_ACCOUNT_ID}:cluster/${SBX_SEED_NAME_PREFIX}-msk-cluster/PLACEHOLDER}"
fi

DATA_BUCKET_ARN="arn:aws:s3:::${DATA_BUCKET}"
RAW_BUCKET_KEYS_ARN="${DATA_BUCKET_ARN}/raw/*"
ROLE_ARN="arn:aws:iam::${SBX_SOURCE_ACCOUNT_ID}:role/${ROLE_NAME}"

sbx_log "firehose: kinesis_arn=${KINESIS_STREAM_ARN} msk_arn=${MSK_CLUSTER_ARN} bucket=${DATA_BUCKET}"

# -----------------------------------------------------------------------------
# Step 1. IAM role for Firehose.
# -----------------------------------------------------------------------------
FIREHOSE_TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"firehose.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

_role_freshly_created=0
_role_exists=0
if sbx_apply_mode; then
    if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
        _role_exists=1
        ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)"
    fi
fi

if [ "$_role_exists" -eq 0 ]; then
    _trust_tmp="$(mktemp -t "sbx-firehose-trust-XXXXXX.json")"
    printf '%s\n' "$FIREHOSE_TRUST_POLICY" > "$_trust_tmp"
    if sbx_apply_mode; then
        sbx_status action "aws iam create-role"
        ROLE_ARN="$(aws iam create-role \
            --role-name "$ROLE_NAME" \
            --assume-role-policy-document "file://${_trust_tmp}" \
            --tags "Key=sbx:seed-name-prefix,Value=${SBX_SEED_NAME_PREFIX}" \
            --query 'Role.Arn' \
            --output text)"
        _role_freshly_created=1
    else
        sbx_aws iam create-role \
            --role-name "$ROLE_NAME" \
            --assume-role-policy-document "file://${_trust_tmp}" \
            --tags "Key=sbx:seed-name-prefix,Value=${SBX_SEED_NAME_PREFIX}"
    fi
    rm -f "$_trust_tmp"
else
    sbx_log "iam role ${ROLE_NAME} already exists; skipping create-role"
fi

# Inline policy. Firehose needs:
#   s3:           PutObject + GetObject + GetBucketLocation + ListBucket on data bucket / raw/*
#   glue:         GetTable + GetTableVersion(s) on the catalog tables (schema conversion)
#   kinesis:      Get* + DescribeStream + ListShards on the kinesis source
#   kafka:        GetBootstrapBrokers + DescribeCluster + DescribeClusterV2
#   kafka-cluster:Connect + DescribeTopic* + ReadData on the MSK ARN/topic
#   logs:         CreateLogStream + PutLogEvents (firehose error logging)
#
# MSK IAM data-plane resource ARN shape:
#   cluster: arn:aws:kafka:<region>:<account>:cluster/<name>/<uuid>
#   topic:   arn:aws:kafka:<region>:<account>:topic/<name>/<uuid>/<topic-name>
#   group:   arn:aws:kafka:<region>:<account>:group/<name>/<uuid>/*
# Build them by splitting MSK_CLUSTER_ARN on `:cluster/`.
_msk_arn_prefix="${MSK_CLUSTER_ARN%:cluster/*}"
_msk_cluster_path="${MSK_CLUSTER_ARN##*:cluster/}"
_msk_topic_arn="${_msk_arn_prefix}:topic/${_msk_cluster_path}/${MSK_TOPIC}"
_msk_group_arn="${_msk_arn_prefix}:group/${_msk_cluster_path}/*"

_inline_tmp="$(mktemp -t "sbx-firehose-policy-XXXXXX.json")"
jq -n \
    --arg bucket_arn "$DATA_BUCKET_ARN" \
    --arg bucket_keys_arn "${DATA_BUCKET_ARN}/*" \
    --arg kin_arn "$KINESIS_STREAM_ARN" \
    --arg msk_arn "$MSK_CLUSTER_ARN" \
    --arg msk_topic_arn "$_msk_topic_arn" \
    --arg msk_group_arn "$_msk_group_arn" \
    --arg region "$SBX_REGION" \
    --arg account "$SBX_SOURCE_ACCOUNT_ID" \
    --arg db_raw "$DB_RAW" \
    --arg tbl_kin "$RAW_TABLE_KINESIS" \
    --arg tbl_msk "$RAW_TABLE_MSK" \
    '{
        Version: "2012-10-17",
        Statement: [
            {
                Sid: "S3WriteRaw",
                Effect: "Allow",
                Action: [
                    "s3:PutObject",
                    "s3:GetObject",
                    "s3:GetBucketLocation",
                    "s3:ListBucket"
                ],
                Resource: [$bucket_arn, $bucket_keys_arn]
            },
            {
                Sid: "GlueCatalogRead",
                Effect: "Allow",
                Action: [
                    "glue:GetTable",
                    "glue:GetTableVersion",
                    "glue:GetTableVersions"
                ],
                Resource: [
                    ("arn:aws:glue:" + $region + ":" + $account + ":catalog"),
                    ("arn:aws:glue:" + $region + ":" + $account + ":database/" + $db_raw),
                    ("arn:aws:glue:" + $region + ":" + $account + ":table/" + $db_raw + "/" + $tbl_kin),
                    ("arn:aws:glue:" + $region + ":" + $account + ":table/" + $db_raw + "/" + $tbl_msk)
                ]
            },
            {
                Sid: "KinesisRead",
                Effect: "Allow",
                Action: [
                    "kinesis:DescribeStream",
                    "kinesis:GetRecords",
                    "kinesis:GetShardIterator",
                    "kinesis:ListShards"
                ],
                Resource: $kin_arn
            },
            {
                Sid: "MSKRead",
                Effect: "Allow",
                Action: [
                    "kafka:GetBootstrapBrokers",
                    "kafka:DescribeCluster",
                    "kafka:DescribeClusterV2"
                ],
                Resource: $msk_arn
            },
            {
                Sid: "MSKDataPlane",
                Effect: "Allow",
                Action: [
                    "kafka-cluster:Connect",
                    "kafka-cluster:DescribeTopic",
                    "kafka-cluster:DescribeTopicDynamicConfiguration",
                    "kafka-cluster:ReadData",
                    "kafka-cluster:DescribeGroup"
                ],
                Resource: [$msk_arn, $msk_topic_arn, $msk_group_arn]
            },
            {
                Sid: "Logs",
                Effect: "Allow",
                Action: [
                    "logs:PutLogEvents",
                    "logs:CreateLogStream"
                ],
                Resource: ("arn:aws:logs:" + $region + ":" + $account + ":log-group:/aws/kinesisfirehose/*")
            }
        ]
    }' > "$_inline_tmp"

sbx_aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name "$INLINE_POLICY_NAME" \
    --policy-document "file://${_inline_tmp}"
rm -f "$_inline_tmp"

if [ "$_role_freshly_created" = "1" ] && sbx_apply_mode; then
    sbx_log "waiting 10s for IAM role propagation (${ROLE_NAME})"
    sleep 10
fi

# -----------------------------------------------------------------------------
# Step 1b. Pre-register the two raw Glue catalog tables.
#
# Firehose's `DataFormatConversionConfiguration` REQUIRES a Glue catalog
# table to exist before `create-delivery-stream` will succeed. This used
# to live in glue/create.sh but that put the create order upside-down
# (glue had to know about the firehose-shaped raw tables); now firehose
# owns the two raw tables.
#
# The two pre-registered tables:
#   <prefix>-db-raw.<prefix>_kinesis_events_parquet → s3://<bucket>/raw/kinesis/
#   <prefix>-db-raw.<prefix>_msk_events_parquet     → s3://<bucket>/raw/msk/
#
# Both:
#   - partitioned by `dt` (string, format yyyy-MM-dd-HH) — Firehose
#     writes a `dt=...` partition prefix per ExtendedS3Destination
#     Configuration.Prefix
#   - schema: event_id string, event_type string, payload string,
#     timestamp timestamp (matches data-gen/fixtures/event_generator.py)
#   - Parameters.classification=parquet, ParquetHiveSerDe (the canonical
#     "Parquet table in the Glue catalog" shape that Athena and
#     Firehose both accept).
#
# Pre-flight: verify <prefix>-db-raw exists. Halt with
# `STATUS: error glue_database_missing` if not — the operator must run
# `seed/glue/create.sh --apply --phase=foundation` first.
# -----------------------------------------------------------------------------

__GLUE_TABLE_PREFIX_F="${SBX_SEED_NAME_PREFIX//-/_}"
RAW_TABLE_KINESIS_F="${__GLUE_TABLE_PREFIX_F}_kinesis_events_parquet"
RAW_TABLE_MSK_F="${__GLUE_TABLE_PREFIX_F}_msk_events_parquet"

# Confirm <prefix>-db-raw is present. In dry-run we render the would-be
# get-database call and proceed (the audit log still shows what would
# happen); in apply mode an empty database is a hard halt.
_db_present=1
if sbx_apply_mode; then
    if ! aws glue get-database \
            --name "$DB_RAW" \
            --region "$SBX_REGION" \
            >/dev/null 2>&1; then
        _db_present=0
    fi
else
    sbx_aws glue get-database --name "$DB_RAW" --region "$SBX_REGION" || true
fi
if sbx_apply_mode && [ "$_db_present" -eq 0 ]; then
    sbx_status error "glue_database_missing ${DB_RAW} (run seed/glue/create.sh --apply --phase=foundation first)"
    exit 64
fi

# _firehose_create_parquet_table <db> <table> <s3-location> <columns-json> <partition-keys-json>
#
# Idempotent get-then-create for an EMPTY Parquet-shaped catalog table.
# Inlined here from the pre-resequencing glue/create.sh helper of the
# same intent (now removed from glue/create.sh).
_firehose_create_parquet_table() {
    local _db="$1"
    local _table="$2"
    local _location="$3"
    local _columns_json="$4"
    local _partition_keys_json="$5"

    local _exists=0
    if sbx_apply_mode; then
        if aws glue get-table \
                --region "$SBX_REGION" \
                --database-name "$_db" \
                --name "$_table" \
                >/dev/null 2>&1; then
            _exists=1
        fi
    else
        sbx_aws glue get-table \
            --region "$SBX_REGION" \
            --database-name "$_db" \
            --name "$_table" || true
    fi

    if [ "$_exists" -eq 1 ]; then
        sbx_log "glue catalog table ${_db}.${_table} already exists; skipping create-table"
        return 0
    fi

    local _req_tmp
    _req_tmp="$(mktemp -t "sbx-glue-table-XXXXXX.json")"
    jq -n \
        --arg db "$_db" \
        --arg name "$_table" \
        --arg location "$_location" \
        --argjson cols "$_columns_json" \
        --argjson pkeys "$_partition_keys_json" \
        '{
            DatabaseName: $db,
            TableInput: {
                Name: $name,
                TableType: "EXTERNAL_TABLE",
                Parameters: {
                    classification: "parquet",
                    "EXTERNAL": "TRUE"
                },
                StorageDescriptor: {
                    Columns: $cols,
                    Location: $location,
                    InputFormat: "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat",
                    OutputFormat: "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat",
                    Compressed: false,
                    SerdeInfo: {
                        SerializationLibrary: "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe",
                        Parameters: { "serialization.format": "1" }
                    }
                },
                PartitionKeys: $pkeys
            }
        }' > "$_req_tmp"

    sbx_aws glue create-table \
        --region "$SBX_REGION" \
        --cli-input-json "file://${_req_tmp}"

    rm -f "$_req_tmp"
}

sbx_status action "register-firehose-raw-tables ${RAW_TABLE_KINESIS_F} ${RAW_TABLE_MSK_F}"

# event_id / event_type / payload / timestamp matches the synthetic
# events the data-gen Lambdas emit (see seed/data-gen/fixtures/
# event_generator.py).
_events_cols='[
    {"Name":"event_id","Type":"string"},
    {"Name":"event_type","Type":"string"},
    {"Name":"payload","Type":"string"},
    {"Name":"timestamp","Type":"timestamp"}
]'
_events_pkeys='[{"Name":"dt","Type":"string"}]'

_firehose_create_parquet_table \
    "$DB_RAW" \
    "$RAW_TABLE_KINESIS_F" \
    "s3://${DATA_BUCKET}/raw/kinesis/" \
    "$_events_cols" \
    "$_events_pkeys"

_firehose_create_parquet_table \
    "$DB_RAW" \
    "$RAW_TABLE_MSK_F" \
    "s3://${DATA_BUCKET}/raw/msk/" \
    "$_events_cols" \
    "$_events_pkeys"

# -----------------------------------------------------------------------------
# Step 2. The two delivery streams.
#
# Both delivery streams share the same ExtendedS3DestinationConfiguration
# shape (same bucket, same buffering hints, schema-converted Parquet
# output). The only differences are the source configuration and the
# target Glue table name. We build them separately for clarity.
# -----------------------------------------------------------------------------

_create_kinesis_delivery_stream() {
    local _exists=0
    if sbx_apply_mode; then
        if aws firehose describe-delivery-stream \
                --region "$SBX_REGION" \
                --delivery-stream-name "$KINESIS_STREAM_NAME" \
                >/dev/null 2>&1; then
            _exists=1
        fi
    else
        sbx_aws firehose describe-delivery-stream \
            --region "$SBX_REGION" \
            --delivery-stream-name "$KINESIS_STREAM_NAME" || true
    fi

    if [ "$_exists" -eq 1 ]; then
        sbx_log "firehose ${KINESIS_STREAM_NAME} already exists; skipping create"
        return 0
    fi

    local _req_tmp
    _req_tmp="$(mktemp -t "sbx-firehose-kin-XXXXXX.json")"
    jq -n \
        --arg name "$KINESIS_STREAM_NAME" \
        --arg role "$ROLE_ARN" \
        --arg kin_arn "$KINESIS_STREAM_ARN" \
        --arg bucket_arn "$DATA_BUCKET_ARN" \
        --arg region "$SBX_REGION" \
        --arg account "$SBX_SOURCE_ACCOUNT_ID" \
        --arg db_raw "$DB_RAW" \
        --arg tbl "$RAW_TABLE_KINESIS" \
        --arg prefix "$SBX_SEED_NAME_PREFIX" \
        '{
            DeliveryStreamName: $name,
            DeliveryStreamType: "KinesisStreamAsSource",
            KinesisStreamSourceConfiguration: {
                KinesisStreamARN: $kin_arn,
                RoleARN: $role
            },
            ExtendedS3DestinationConfiguration: {
                RoleARN: $role,
                BucketARN: $bucket_arn,
                Prefix: "raw/kinesis/dt=!{timestamp:yyyy-MM-dd-HH}/",
                ErrorOutputPrefix: "raw/kinesis-errors/!{firehose:error-output-type}/dt=!{timestamp:yyyy-MM-dd-HH}/",
                BufferingHints: {
                    IntervalInSeconds: 60,
                    SizeInMBs: 64
                },
                CompressionFormat: "UNCOMPRESSED",
                DataFormatConversionConfiguration: {
                    Enabled: true,
                    InputFormatConfiguration: {
                        Deserializer: { OpenXJsonSerDe: {} }
                    },
                    OutputFormatConfiguration: {
                        Serializer: { ParquetSerDe: { Compression: "SNAPPY" } }
                    },
                    SchemaConfiguration: {
                        RoleARN: $role,
                        CatalogId: $account,
                        DatabaseName: $db_raw,
                        TableName: $tbl,
                        Region: $region,
                        VersionId: "LATEST"
                    }
                },
                CloudWatchLoggingOptions: {
                    Enabled: true,
                    LogGroupName: ("/aws/kinesisfirehose/" + $name),
                    LogStreamName: "S3Delivery"
                }
            },
            Tags: [{ Key: "sbx:seed-name-prefix", Value: $prefix }]
        }' > "$_req_tmp"

    sbx_aws firehose create-delivery-stream \
        --region "$SBX_REGION" \
        --cli-input-json "file://${_req_tmp}"

    rm -f "$_req_tmp"
}

_create_msk_delivery_stream() {
    local _exists=0
    if sbx_apply_mode; then
        if aws firehose describe-delivery-stream \
                --region "$SBX_REGION" \
                --delivery-stream-name "$MSK_STREAM_NAME" \
                >/dev/null 2>&1; then
            _exists=1
        fi
    else
        sbx_aws firehose describe-delivery-stream \
            --region "$SBX_REGION" \
            --delivery-stream-name "$MSK_STREAM_NAME" || true
    fi

    if [ "$_exists" -eq 1 ]; then
        sbx_log "firehose ${MSK_STREAM_NAME} already exists; skipping create"
        return 0
    fi

    local _req_tmp
    _req_tmp="$(mktemp -t "sbx-firehose-msk-XXXXXX.json")"
    jq -n \
        --arg name "$MSK_STREAM_NAME" \
        --arg role "$ROLE_ARN" \
        --arg msk_arn "$MSK_CLUSTER_ARN" \
        --arg topic "$MSK_TOPIC" \
        --arg bucket_arn "$DATA_BUCKET_ARN" \
        --arg region "$SBX_REGION" \
        --arg account "$SBX_SOURCE_ACCOUNT_ID" \
        --arg db_raw "$DB_RAW" \
        --arg tbl "$RAW_TABLE_MSK" \
        --arg prefix "$SBX_SEED_NAME_PREFIX" \
        '{
            DeliveryStreamName: $name,
            DeliveryStreamType: "MSKAsSource",
            MSKSourceConfiguration: {
                MSKClusterARN: $msk_arn,
                TopicName: $topic,
                AuthenticationConfiguration: {
                    RoleARN: $role,
                    Connectivity: "PRIVATE"
                }
            },
            ExtendedS3DestinationConfiguration: {
                RoleARN: $role,
                BucketARN: $bucket_arn,
                Prefix: "raw/msk/dt=!{timestamp:yyyy-MM-dd-HH}/",
                ErrorOutputPrefix: "raw/msk-errors/!{firehose:error-output-type}/dt=!{timestamp:yyyy-MM-dd-HH}/",
                BufferingHints: {
                    IntervalInSeconds: 60,
                    SizeInMBs: 64
                },
                CompressionFormat: "UNCOMPRESSED",
                DataFormatConversionConfiguration: {
                    Enabled: true,
                    InputFormatConfiguration: {
                        Deserializer: { OpenXJsonSerDe: {} }
                    },
                    OutputFormatConfiguration: {
                        Serializer: { ParquetSerDe: { Compression: "SNAPPY" } }
                    },
                    SchemaConfiguration: {
                        RoleARN: $role,
                        CatalogId: $account,
                        DatabaseName: $db_raw,
                        TableName: $tbl,
                        Region: $region,
                        VersionId: "LATEST"
                    }
                },
                CloudWatchLoggingOptions: {
                    Enabled: true,
                    LogGroupName: ("/aws/kinesisfirehose/" + $name),
                    LogStreamName: "S3Delivery"
                }
            },
            Tags: [{ Key: "sbx:seed-name-prefix", Value: $prefix }]
        }' > "$_req_tmp"

    sbx_aws firehose create-delivery-stream \
        --region "$SBX_REGION" \
        --cli-input-json "file://${_req_tmp}"

    rm -f "$_req_tmp"
}

_create_kinesis_delivery_stream
_create_msk_delivery_stream

# -----------------------------------------------------------------------------
# Persist state ONLY in apply mode (bug fix 1a).
# -----------------------------------------------------------------------------
if sbx_apply_mode; then
    sbx_state_set_service firehose "$(jq -n \
        --arg role_arn "$ROLE_ARN" \
        --arg role_name "$ROLE_NAME" \
        --arg kin_name "$KINESIS_STREAM_NAME" \
        --arg msk_name "$MSK_STREAM_NAME" \
        --arg kin_src "$KINESIS_STREAM_ARN" \
        --arg msk_src "$MSK_CLUSTER_ARN" \
        --arg db_raw "$DB_RAW" \
        --arg kin_tbl "$RAW_TABLE_KINESIS_F" \
        --arg msk_tbl "$RAW_TABLE_MSK_F" \
        '{
            status: "provisioned",
            resources: {
                role_arn: $role_arn,
                role_name: $role_name,
                kinesis_stream_name: $kin_name,
                msk_stream_name: $msk_name,
                kinesis_stream_arn: $kin_src,
                msk_stream_arn: $msk_src,
                glue_database_raw: $db_raw,
                kinesis_table_name: $kin_tbl,
                msk_table_name: $msk_tbl
            }
        }')"
    sbx_status ok "firehose_provisioned kinesis=${KINESIS_STREAM_NAME} msk=${MSK_STREAM_NAME} raw_tables=${RAW_TABLE_KINESIS_F},${RAW_TABLE_MSK_F}"
else
    sbx_log "dry-run: skipping state write (would record .services.firehose.status=provisioned with 2 delivery streams + 2 raw catalog tables)"
    sbx_status ok "firehose_dry_run kinesis=${KINESIS_STREAM_NAME} msk=${MSK_STREAM_NAME} raw_tables=${RAW_TABLE_KINESIS_F},${RAW_TABLE_MSK_F}"
fi
