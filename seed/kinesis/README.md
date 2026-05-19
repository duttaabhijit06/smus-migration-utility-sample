# Seed Kinesis module

Provisions a single ON_DEMAND Amazon Kinesis Data Stream named
`<prefix>-events` so the seed deployment has a working source for both
the kinesis-to-Parquet Firehose delivery stream (`seed/firehose/`) and
the kinesis event-generator Lambda (`seed/data-gen/`).

## Resources created

| Resource | Name | Notes |
| --- | --- | --- |
| Kinesis Data Stream | `<prefix>-events` | ON_DEMAND mode (no shard count). Tagged with `sbx:seed-name-prefix=<prefix>`. |

## AWS CLI verbs used

`create.sh`:

- `aws kinesis describe-stream-summary` — idempotency probe (Requirement 20.13).
- `aws kinesis create-stream --stream-mode-details StreamMode=ON_DEMAND`.
- `aws kinesis add-tags-to-stream` — idempotent re-tag.
- `aws kinesis describe-stream-summary` — bounded poll (≤ 30 s) for `StreamStatus == ACTIVE`.

`teardown.sh`:

- `aws kinesis describe-stream-summary` — existence probe.
- `aws kinesis delete-stream --enforce-consumer-deletion`.

## Persisted state shape

After `--apply` succeeds, `services.kinesis.resources` in `./seed/seed.state.json`:

```json
{
  "status": "provisioned",
  "resources": {
    "stream_name": "<prefix>-events",
    "stream_arn": "arn:aws:kinesis:<region>:<account>:stream/<prefix>-events"
  }
}
```

## Dry-run vs apply

- **Default is dry-run.** `bash seed/kinesis/create.sh` prints every would-be AWS CLI command with the `DRY-RUN:` prefix and changes nothing in AWS or in `seed.state.json`.
- **`--apply`** issues the create + tag + wait-for-ACTIVE + state write.
- `--apply` and `--dry-run` are mutually exclusive (Requirement 20.4).

State writes are gated behind `sbx_apply_mode` (project-wide bug fix 1a) — dry-run will not record `provisioned` to the state file.

## Idempotency

A second `bash seed/kinesis/create.sh --apply` immediately after a successful first run issues exactly **zero** `aws kinesis create-stream` commands: the `describe-stream-summary` probe short-circuits the create. `aws kinesis add-tags-to-stream` is itself idempotent on the AWS side.

## Teardown safety

Teardown is gated by **both** the prefix gate (`<prefix>-`) and the state-file gate (`.services.kinesis.resources.stream_name` must be recorded). A stream that fails either gate is skipped — even if it appears in the same AWS account, it could belong to a non-seed customer workload.
