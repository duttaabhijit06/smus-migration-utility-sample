# Seed Firehose module

Provisions two Amazon Data Firehose delivery streams that land schema-converted Parquet in the seed data bucket. Both streams use Firehose's `DataFormatConversionConfiguration` to read JSON records, convert them to Parquet using the schema of a pre-registered Glue catalog table, and write under hour-partitioned prefixes.

**Post-resequencing change:** This module now OWNS the two raw catalog tables that Firehose's schema-conversion needs. They were formerly registered by `seed/glue/create.sh` (phase 1), but Firehose's `DataFormatConversionConfiguration` hard-requires the tables at delivery-stream-create time, and the resequencing moved every other curated/raw catalog responsibility onto the late `glue --phase=crawler` pass. Co-locating the two raw tables with the only consumer that depends on them at create time keeps the dependency graph honest.

## Resources created

Every name begins with `${SBX_SEED_NAME_PREFIX}-`:

| Resource | Name | Notes |
| --- | --- | --- |
| **Glue catalog table** | `<prefix>-db-raw.<prefix>_kinesis_events_parquet` | EMPTY Parquet table at `s3://<data-bucket>/raw/kinesis/`, partitioned by `dt` (string). Schema: event_id, event_type, payload, timestamp. Created BEFORE the kinesis delivery stream. |
| **Glue catalog table** | `<prefix>-db-raw.<prefix>_msk_events_parquet` | EMPTY Parquet table at `s3://<data-bucket>/raw/msk/`, partitioned by `dt`. Same schema. Created BEFORE the msk delivery stream. |
| IAM role | `<prefix>-firehose-role` | Trust `firehose.amazonaws.com`. Inline `firehose-write` policy (s3, glue catalog read, kinesis read, kafka + kafka-cluster, logs). |
| Firehose delivery stream | `<prefix>-kinesis-to-s3-parquet` | Source: `<prefix>-events` Kinesis stream. Sink: `s3://<data-bucket>/raw/kinesis/dt=!{timestamp:yyyy-MM-dd-HH}/`. Schema-conv against `<prefix>-db-raw.<prefix>_kinesis_events_parquet`. |
| Firehose delivery stream | `<prefix>-msk-to-s3-parquet` | Source: MSK cluster + topic `<prefix>-events`, `Connectivity=PRIVATE`. Sink: `s3://<data-bucket>/raw/msk/dt=!{timestamp:yyyy-MM-dd-HH}/`. Schema-conv against `<prefix>-db-raw.<prefix>_msk_events_parquet`. |

## Required upstream state

This module reads four inputs from `seed.state.json` and refuses to apply when any are missing.

| Input | Source module | Source path |
| --- | --- | --- |
| `<prefix>-db-raw` exists | `seed/glue/` (phase=foundation) | `aws glue get-database` (verified at runtime) |
| Kinesis stream ARN | `seed/kinesis/` | `.services.kinesis.resources.stream_arn` |
| MSK cluster ARN | `seed/msk/` | `.services.msk.resources.cluster.arn` |
| Data bucket name | `seed/glue/` (phase=foundation) | `.services.glue.resources.data_bucket` |

Apply mode hard-fails with `STATUS: error glue_database_missing` when `<prefix>-db-raw` is not present (the operator must run `seed/glue/create.sh --apply --phase=foundation` first), and with `STATUS: error dependency_not_provisioned` when any of the three state inputs is missing. Dry-run substitutes deterministic placeholders so the audit log is end-to-end coherent.

## AWS CLI verbs used

`create.sh`:

- `aws iam get-role` / `aws iam create-role` — idempotent role create.
- `aws iam put-role-policy` — inline `firehose-write` policy.
- `aws glue get-database` — pre-flight check for `<prefix>-db-raw`.
- `aws glue get-table` / `aws glue create-table` — idempotent register of the two empty raw catalog tables.
- `aws firehose describe-delivery-stream` — idempotency probe.
- `aws firehose create-delivery-stream --cli-input-json file://<tempfile>` — once per stream.

`teardown.sh`:

- `aws firehose describe-delivery-stream` / `aws firehose delete-delivery-stream --allow-force-delete`.
- `aws glue get-table` / `aws glue delete-table` — clean up the two raw catalog tables AFTER the delivery streams are gone.
- `aws iam list-attached-role-policies` + `aws iam detach-role-policy`.
- `aws iam list-role-policies` + `aws iam delete-role-policy`.
- `aws iam delete-role`.

## Catalog-table contract

Both raw tables are registered with the canonical "Parquet table in the Glue catalog" shape that Firehose's `DataFormatConversionConfiguration` expects:

```yaml
TableInput:
  Name: <prefix>_{kinesis,msk}_events_parquet
  TableType: EXTERNAL_TABLE
  Parameters:
    classification: parquet
    EXTERNAL: "TRUE"
  StorageDescriptor:
    Columns:
      - { Name: event_id,    Type: string    }
      - { Name: event_type,  Type: string    }
      - { Name: payload,     Type: string    }
      - { Name: timestamp,   Type: timestamp }
    Location: s3://<data-bucket>/raw/{kinesis,msk}/
    InputFormat:  org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat
    OutputFormat: org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat
    SerdeInfo:
      SerializationLibrary: org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe
  PartitionKeys:
    - { Name: dt, Type: string }
```

The 4-field schema (`event_id`, `event_type`, `payload`, `timestamp`) matches the synthetic events produced by `seed/data-gen/fixtures/event_generator.py`.

## Schema-conversion contract

Both delivery streams use the same DataFormatConversion shape:

```yaml
DataFormatConversionConfiguration:
  Enabled: true
  InputFormatConfiguration:
    Deserializer: { OpenXJsonSerDe: {} }
  OutputFormatConfiguration:
    Serializer: { ParquetSerDe: { Compression: SNAPPY } }
  SchemaConfiguration:
    RoleARN: <firehose role ARN>
    CatalogId: <account>
    DatabaseName: <prefix>-db-raw
    TableName: <prefix>_{kinesis,msk}_events_parquet
    Region: <region>
    VersionId: LATEST
```

Firehose reads the schema from the catalog table at start-up; without a pre-registered table, `create-delivery-stream` rejects the request. This is why this module pre-registers the catalog tables right before creating the delivery streams. The post-resequencing canonical order is:

```
glue --phase=foundation  →  rds  →  glue --phase=rds-bridge  →  sns
                  →  msk  →  kinesis  →  data-gen  →  firehose
                  →  glue --phase=crawler  →  glue --phase=kafka  →  ...
                                                  ↑
                                                  this module both
                                                  registers the raw
                                                  tables AND creates
                                                  the delivery streams
                                                  in a single pass
```

## Persisted state shape

After `--apply` succeeds, `services.firehose.resources` in `./seed/seed.state.json`:

```json
{
  "status": "provisioned",
  "resources": {
    "role_arn": "arn:aws:iam::<account>:role/<prefix>-firehose-role",
    "role_name": "<prefix>-firehose-role",
    "kinesis_stream_name": "<prefix>-kinesis-to-s3-parquet",
    "msk_stream_name": "<prefix>-msk-to-s3-parquet",
    "kinesis_stream_arn": "arn:aws:kinesis:<region>:<account>:stream/<prefix>-events",
    "msk_stream_arn": "arn:aws:kafka:<region>:<account>:cluster/<prefix>-msk-cluster/<uuid>",
    "glue_database_raw": "<prefix>-db-raw",
    "kinesis_table_name": "<prefix>_kinesis_events_parquet",
    "msk_table_name": "<prefix>_msk_events_parquet"
  }
}
```

The recorded `glue_database_raw` + table names let `teardown.sh` find and delete the catalog tables AFTER the delivery streams have been removed (Firehose holds a reference to them while the delivery stream exists, so the tables must be deleted last).

## Dry-run vs apply

- **Default is dry-run.** `bash seed/firehose/create.sh` prints every would-be AWS CLI command with the `DRY-RUN:` prefix, leaves `seed.state.json` untouched, and substitutes placeholder ARNs when upstream state is missing.
- **`--apply`** issues the create + state-write sequence.
- `--apply` and `--dry-run` are mutually exclusive (Requirement 20.4).

State writes are gated behind `sbx_apply_mode` (project-wide bug fix 1a).

## Idempotency

A re-run of `bash seed/firehose/create.sh --apply` immediately after a successful first run issues exactly **zero** `aws firehose create-*`, `aws glue create-table`, and `aws iam create-role` commands. `aws iam put-role-policy` is itself idempotent on the AWS side and is asserted on every run so a hand-edited inline policy is restored.

## Teardown safety

Teardown is gated by both the prefix gate (`<prefix>-`) and the state-file gate. Catalog tables are deleted AFTER the delivery streams; the database itself (`<prefix>-db-raw`) is owned by `seed/glue/` and is dropped by glue's teardown.
