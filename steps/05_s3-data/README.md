# Step 5 — Migrate data-related S3 buckets

## 1. Purpose

Step 5 migrates the data-bearing S3 buckets that downstream SMUS workflows
need to reach. The step builds a candidate bucket list by unioning four
sources — buckets referenced by Glue jobs, buckets backing Glue Data
Catalog table locations, MWAA data buckets associated with the configured
MWAA_Environment, and the operator-provided inclusion list — then
unconditionally excludes the configured MWAA_DAG_Bucket. The remaining
buckets are streamed into the SMUS-managed S3 location for the
Admin_Project with `aws s3 sync`.

The MWAA_DAG_Bucket exclusion is the central policy contract of this step:
DAG code is treated as source code (extracted in Step 6 and committed to
the configured code repository), so syncing the DAG bucket alongside data
buckets would conflict with the policy table from Step 2 and duplicate the
DAG payload. The exclusion is logged to the Run_Log so an auditor can
prove from the log alone that the DAG bucket was removed before any
`aws s3 sync` ran.

## 2. Prerequisites

- IAM permissions on the executing principal:
  - `s3:ListBucket` on every candidate bucket
  - `s3:GetObject` on every candidate bucket
  - `s3:PutObject` on the SMUS-managed Admin_Project S3 root
  - `s3api:HeadBucket` on every candidate bucket (for the per-bucket
    reachability probe before each sync)
  - `mwaa:GetEnvironment` on the configured MWAA_Environment
- `jq` installed locally and on `PATH`. Step 5 uses `jq` to extract
  `s3://...` URIs from the upstream JSON inventories produced by Steps 3
  and 4 and to emit the deterministic `buckets.json` / `errors.json`
  outputs. The step exits 64 with `STATUS: error` if `jq` is missing.

Step 5 does **not** require Step 1 to have completed. When
`MT_SMUS_MANAGED_S3_ROOT` is unset (Step 1 has not yet resolved the
SMUS-managed S3 root), the script falls back to a placeholder root so
dry-run remains demonstrable end-to-end. In Apply_Mode the orchestrator
ensures Step 1 has run before Step 5, so the resolved root is supplied.

## 3. Configuration keys consumed

The step reads the following keys from `config/migration.config.json` via
`MT_*` environment variables exported by the orchestrator:

| Config key | Env var | Used for |
|---|---|---|
| `aws_region` | `MT_AWS_REGION` | Region for `aws mwaa get-environment` and `aws s3 sync`. |
| `mwaa_environment_name` | `MT_MWAA_ENVIRONMENT_NAME` | Argument to `aws mwaa get-environment` when scanning for MWAA data bucket ARNs. |
| `mwaa_dag_bucket_name` | `MT_MWAA_DAG_BUCKET_NAME` | The single bucket name that is unconditionally excluded from the candidate list (Requirement 12.2). |
| `source_s3_inclusion_list` | `MT_SOURCE_S3_INCLUSION_LIST` | Comma-separated string of bucket names the operator added to the migration scope by hand. Whitespace around each name is trimmed; empty entries are ignored. |

The step also reads `MT_SMUS_MANAGED_S3_ROOT` when present (resolved by
Step 1) and falls back to `smus-managed-fallback` otherwise.

Required keys for which the orchestrator halts (and re-prompts) when
missing: `aws_region`, `mwaa_environment_name`, `mwaa_dag_bucket_name`,
`source_s3_inclusion_list`.

## 4. AWS CLI commands issued

Step 5 issues exactly three AWS CLI verbs. Every invocation flows through
`mt_aws` from `steps/_lib/common.sh`, so dry-run prints
`DRY-RUN: aws ...` and apply mode executes the command.

| Command | When | Effect |
|---|---|---|
| `aws mwaa get-environment --name "$MT_MWAA_ENVIRONMENT_NAME" --region "$MT_AWS_REGION"` | Always (both modes) | Retrieves the MWAA environment payload so the candidate-list builder can extract S3 ARNs (including `Environment.SourceBucketArn`, which is the DAG bucket and therefore filtered below). In dry-run the call returns no JSON; the candidate list is built purely from the upstream JSON inventories and the inclusion list. |
| `aws s3api head-bucket --bucket "<bucket>"` | Per candidate bucket, both modes | Confirms the bucket exists and is reachable before issuing the sync. A failure is recorded to `outputs/errors.json` and the loop continues with the next bucket. |
| `aws s3 sync s3://<bucket> s3://<smus-managed>/<bucket>/ --region "$MT_AWS_REGION"` | Per candidate bucket | Copies the bucket contents into the SMUS-managed Admin_Project S3 root. In dry-run `mt_aws` prints `DRY-RUN: aws s3 sync ...` and returns 0; in apply the command runs in the background with a 30-second progress heartbeat in the Run_Log. |

## 5. Artifacts produced

| Path | Contents |
|---|---|
| `steps/05_s3-data/outputs/buckets.json` | Final candidate bucket list as `{"buckets": ["<name>", "<name>", ...]}`, deduped and with the MWAA_DAG_Bucket already removed. Written in both modes. |
| `steps/05_s3-data/outputs/errors.json` | One JSON object per failed bucket with fields `bucket` and `error`. Written only when at least one per-bucket `aws s3api head-bucket` or `aws s3 sync` failure occurred. |
| `steps/05_s3-data/outputs/run.log` | Per-step run log tee'd from `mt_aws` in apply mode (the orchestrator's `logs/run-<UTC>.log` is the authoritative Run_Log, but each step also keeps a co-located copy under its own `outputs/run.log` for convenience). |

## 6. Bucket selection rules

The candidate list is the union of four input sources, deduped and then
filtered. Implementation lives in `run.sh`; this section documents the
contract.

1. **Glue jobs (Step 3 output).** The step walks
   `steps/03_glue-jobs/outputs/glue-jobs.json` with
   `jq -r '.. | strings | select(startswith("s3://"))'`. This generic
   string walk captures every `s3://` URI the Glue job inventory carries
   — `ScriptLocation`, source/target paths in default arguments,
   `--TempDir`, and any other `s3://` value the inventory shape contains.
   Each URI is reduced to its bucket component
   (`s3://<bucket>/<key...>` → `<bucket>`).
2. **Glue catalog (Step 4 output).** The step walks
   `steps/04_catalog/outputs/glue-catalog-inventory.json` with the same
   generic string walk so it works against both the raw `aws glue
   get-tables` shape and Step 4's trimmed inventory shape. This captures
   `tables[].StorageDescriptor.Location` and `tables[].location` values
   that begin with `s3://`.
3. **MWAA data buckets.** The step calls `aws mwaa get-environment`,
   filters out the orchestrator's `STATUS:` and `DRY-RUN:` lines from
   the captured stdout, and walks the remaining JSON for any
   `arn:aws:s3:::...` ARN. Each ARN is reduced to its bucket component
   (`arn:aws:s3:::<bucket>/<key...>` → `<bucket>`). Notably this picks
   up `Environment.SourceBucketArn` — which IS the DAG bucket, and
   therefore gets filtered out by the exclusion rule below.
4. **Operator inclusion list.** The step splits
   `MT_SOURCE_S3_INCLUSION_LIST` on commas, trims whitespace from each
   token, and ignores empty tokens. The remaining names are added to
   the candidate set verbatim.

After the four sources are accumulated, the step:

- **Dedupes** with `sort -u` so each bucket appears at most once
  regardless of how many sources contributed it.
- **Excludes** the bucket whose name equals `MT_MWAA_DAG_BUCKET_NAME`
  (see Section 7 below). The exclusion is logged to the Run_Log
  (`mt_log "excluding MWAA DAG bucket: <name>"`) so an auditor can prove
  from the log alone that the DAG bucket was removed before any `aws s3
  sync` ran.

When an upstream JSON inventory is missing (for example Step 3 has not
been run yet), the corresponding source contributes zero buckets and the
step logs `skipping ... not present`. The step does not halt on missing
upstream inventories; it simply produces a candidate list from whichever
sources are available.

## 7. Exclusion semantics

The MWAA_DAG_Bucket is **always** excluded from the candidate list. The
exclusion is unconditional: it does not depend on which of the four
input sources contributed the bucket name and it does not depend on the
mode (dry-run or apply).

Requirement 12.2 (verbatim from `requirements.md`):

> WHEN Step 5 runs, THE Migration_Tool SHALL exclude from the candidate
> bucket list any bucket whose ARN matches the configured MWAA_DAG_Bucket
> and SHALL log the exclusion in the Run_Log.

In this step the comparison is implemented by name rather than by ARN —
the candidate set holds bucket names (S3 bucket names are globally
unique within the AWS partition, so the ARN form `arn:aws:s3:::<name>`
is a 1-to-1 function of the name). Concretely: the bucket whose name
equals `MT_MWAA_DAG_BUCKET_NAME` is removed from the deduped candidate
list, and the exclusion is emitted to the Run_Log via
`mt_log "excluding MWAA DAG bucket: $MT_MWAA_DAG_BUCKET_NAME"` before
the per-bucket head-bucket + sync loop begins. The exclusion line
appears in the Run_Log for every invocation of Step 5, in both
Dry_Run_Mode and Apply_Mode.

## 8. Dry-run vs apply behavior

Both modes write `outputs/buckets.json` from the same dedup + exclusion
pipeline; the difference is what the per-bucket loop does once the list
is built.

| Mode | Behavior |
|---|---|
| Dry-run (default) | For each candidate bucket, prints `DRY-RUN: aws s3api head-bucket --bucket <bucket>` followed by `DRY-RUN: aws s3 sync s3://<bucket> s3://<smus-managed>/<bucket>/ --region <region>`. No AWS state changes. No background processes, no heartbeat. |
| Apply (`--apply`) | For each candidate bucket, runs `aws s3api head-bucket` to confirm reachability, then runs `aws s3 sync s3://<bucket> s3://<smus-managed>/<bucket>/ --region <region>` in the background and emits a `mt_log "syncing <bucket>: in progress"` line every 30 seconds while the sync is in flight, per Requirement 12.5. The heartbeat is reaped when the sync exits. |

Idempotency contract: `aws s3 sync` only copies objects that are absent
or out of date in the destination, so re-running Step 5 in Apply_Mode
naturally no-ops for buckets whose contents have not changed since the
last run.

## 9. Per-bucket failure resilience

A failure on a single bucket — either a non-zero `aws s3api head-bucket`
exit (the bucket does not exist or is unreachable from the executing
principal) or a non-zero `aws s3 sync` exit (transient network failure,
denied object, capacity error) — is captured as a JSON row in
`outputs/errors.json` with the shape
`{"bucket": "<name>", "error": "<message>"}` and the loop continues
with the next bucket, per Requirement 12.6. The step does not abort on
a per-bucket failure; the operator can re-run Step 5 to retry the
buckets that errored, and the upstream `aws s3 sync` semantics ensure
already-synced buckets re-sync as no-ops.

`outputs/errors.json` is only written when at least one failure
occurred; the absence of the file means every candidate bucket
succeeded.

## 10. Citations

Both AWS_Docs_MCP-cached URLs below and the Reference_Document section
that supports them are included per requirements 5.4 and 6.3.

- AWS_Docs_MCP: [`aws s3 sync` reference](https://docs.aws.amazon.com/cli/latest/reference/s3/sync.html)
  — describes the directional sync semantics this step relies on:
  recursively copies new and updated files from the source to the
  destination, so re-runs are naturally incremental and treat already
  synced objects as no-ops. This grounds the apply-mode contract in
  Section 8 and the idempotency contract in Section 9.
- AWS_Docs_MCP: [Bringing existing resources into SageMaker Unified Studio](https://docs.aws.amazon.com/sagemaker-unified-studio/latest/userguide/bring-resources-scripts.html)
  — describes the supported in-place onboarding paths for AWS Glue Data
  Catalog, Amazon S3 data, Amazon Athena workgroups, Amazon EMR on EC2,
  Amazon Redshift, Amazon SageMaker AI, and IAM roles. The S3 portion
  of this guidance is the source for treating data buckets as
  first-class migration candidates while keeping DAG-bearing buckets
  out of the data-sync flow.
- Reference_Document section: **"4. Best Path to Bring Existing
  Datasets, Glue Jobs, and ML Assets"** in
  `SageMaker Unified Studio - Migration Answers.md`. This section is
  the canonical source for the data-bucket migration verdict in
  Step 2's portability report and for the exclusion of the
  MWAA_DAG_Bucket from data-bucket sync (DAG code is brought in via
  the configured code repository, not via `aws s3 sync`).
