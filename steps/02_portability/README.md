# Step 2 — Portability classification

## 1. Purpose

Step 2 produces the portability classification for every source service that
falls within the migration scope. The output is a single markdown table that
labels each service with one value drawn from the closed label set
`{Full automation, Inventory only, Excluded}` and pairs each `Inventory only`
row with a one-line recommendation drawn from
`{Stay outside SMUS, Reference from SMUS workflows, Manual port}`.

The classification is **policy, not discovery**. The rule table is hard-coded
in `run.sh` and the report it renders is byte-for-byte deterministic across
runs against the same source account. Subsequent steps (Step 3 onward) consume
the labels implicitly: services labelled `Full automation` are the ones the
Migration_Tool moves into the SMUS_Domain; services labelled `Inventory only`
are handled by the read-only inventory phase under `steps/inventory/`; the
`Excluded` row documents the one bucket the tool deliberately leaves alone
(the MWAA_DAG_Bucket, whose contents are extracted as code in Step 6 and
committed to the configured code repository).

## 2. Prerequisites

None. Step 2 issues zero AWS CLI commands and reads no configuration values
besides the standard `MT_*` mode flags. It can run before Step 1 has created
the SMUS_Domain.

## 3. Configuration keys consumed

None. The step reads no values from `config/migration.config.json`. The only
inputs are the `--apply` and `--dry-run` flags processed by
`steps/_lib/common.sh`.

## 4. AWS CLI commands issued

None. Step 2 makes no AWS API calls in either dry-run or apply mode. This is
the only canonical step (1–9) with that property.

## 5. Artifacts produced

| Path | Contents |
|---|---|
| `steps/02_portability/outputs/portability-report.md` | Markdown file with one H1 heading and one classification table covering every in-scope source service. |

The report is overwritten on every apply-mode run; its contents are
deterministic, so re-running the step is a natural no-op for downstream
consumers.

## 6. Dry-run vs apply behavior

| Mode | Behavior |
|---|---|
| Dry-run (default) | Prints `DRY-RUN: write steps/02_portability/outputs/portability-report.md` and creates no file. |
| Apply (`--apply`) | Writes `steps/02_portability/outputs/portability-report.md` from the embedded heredoc. No AWS calls. |

The step emits `STATUS: started` on entry and `STATUS: ok` on success in both
modes so the orchestrator records the same state transitions it records for
every other step.

## 7. Report layout

The generated `portability-report.md` contains exactly one table with four
columns. The columns are fixed and the label column is restricted to a closed
set.

| Column | Allowed values | Meaning |
|---|---|---|
| Service | Free text drawn from the in-scope service list | The source service or sub-service the row classifies. |
| Label | One of `Full automation`, `Inventory only`, `Excluded` | The portability verdict. `Full automation` services move into the SMUS_Domain through later steps; `Inventory only` services receive a discovery sweep under `steps/inventory/`; `Excluded` services are intentionally not migrated. |
| Recommendation | One of `Stay outside SMUS`, `Reference from SMUS workflows`, `Manual port`, or `—` | One-line guidance. Required for every `Inventory only` row; rendered as `—` for `Full automation` rows; for `Excluded` rows it carries the exclusion rationale. |
| Reference | Free text | The migration step that handles the row (for `Full automation`) or the inventory module that owns it (for `Inventory only`). |

The fixed row set rendered by the step is:

| Service | Label | Recommendation | Reference |
|---|---|---|---|
| AWS Glue (jobs, catalog) | Full automation | — | Steps 3, 4 |
| AWS Glue Data Catalog | Full automation | — | Step 4 |
| AWS Glue Connection | Full automation | — | Step 4b |
| Amazon MWAA (provisioned) | Full automation | — | Steps 6, 7 |
| S3 data buckets | Full automation | — | Step 5 |
| MWAA DAG bucket | Excluded | DAG code is extracted in Step 6 and committed to the configured code repository | — |
| AWS Lambda | Inventory only | Reference from SMUS workflows | Inventory/lambda |
| Amazon SNS | Inventory only | Stay outside SMUS | Inventory/sns |
| Amazon MSK / Kafka | Inventory only | Stay outside SMUS | Inventory/msk |
| Apache Flink / KDA | Inventory only | Stay outside SMUS | Inventory/flink-kda |
| Amazon CloudWatch | Inventory only | Stay outside SMUS | Inventory/cloudwatch |
| Amazon QuickSight | Inventory only | Reference from SMUS workflows | Inventory/quicksight |

## 8. Citations

The portability rule table is grounded in AWS-recommended onboarding guidance
for SageMaker Unified Studio. Both AWS_Docs_MCP-cached URLs below and the
Reference_Document section title that supports them are included per
requirement 6.3.

- AWS_Docs_MCP: [Bringing existing resources into SageMaker Unified Studio](https://docs.aws.amazon.com/sagemaker-unified-studio/latest/userguide/bring-resources-scripts.html) — describes the supported in-place onboarding paths for AWS Glue Data Catalog, Amazon S3 data, Amazon Athena workgroups, Amazon EMR on EC2, Amazon Redshift, Amazon SageMaker AI, and IAM roles. The `Full automation` rows for AWS Glue (jobs, catalog), AWS Glue Data Catalog, AWS Glue Connection, and S3 data buckets follow this guidance.
- AWS_Docs_MCP: [Automated data onboarding for SageMaker Lakehouse](https://docs.aws.amazon.com/sagemaker-unified-studio/latest/adminguide/data-onboarding.html) — describes the domain-level onboarding flow with continuous metadata sync. Reinforces the `Full automation` verdict for the AWS Glue Data Catalog row driven by Step 4.
- Reference_Document section: **"4. Best Path to Bring Existing Datasets, Glue Jobs, and ML Assets"** in `SageMaker Unified Studio - Migration Answers.md`. This section is the canonical source for the `Full automation` verdicts in this report; it states that SMUS is designed to work with existing resources in place, that Glue Data Catalog metadata is imported without data movement, that S3 data is referenced in place, and that existing Glue ETL jobs can be brought via repository scripts or referenced from SMUS workflows. The `Excluded` MWAA_DAG_Bucket row and the `Inventory only` rows align with the same section's principle that running workloads do not require migration: services for which SMUS has no first-party onboarding path are kept in place and either referenced from SMUS workflows (`Reference from SMUS workflows`) or left alone (`Stay outside SMUS`).
