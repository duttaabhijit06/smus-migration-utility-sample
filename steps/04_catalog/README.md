# Step 4 — Glue Data Catalog → SageMaker Catalog

This Step_Module enumerates the AWS Glue Data Catalog in the source account and
registers a Glue-typed DataZone data source on the Admin_Project of the
SMUS_Domain so the SageMaker Catalog crawls every database on a 6-hour schedule
and publishes assets on import.

## 1. Purpose

Step 4 walks the Glue_Catalog (every database and every table) in the configured
`aws_region`, writes a deterministic catalog inventory to disk, and — in apply
mode — creates one Glue-typed DataZone data source on the Admin_Project named
`migration-tool-glue-catalog`. The data source is configured with
`relationalFilterConfigurations` covering every discovered database, a
`cron(0 */6 * * ? *)` schedule, and `--publish-on-import` so SageMaker Catalog
re-crawls every database every six hours and assets become discoverable to
domain users on import. After creation (or idempotent reuse of an existing data
source), the step triggers one initial `start-data-source-run` so the first
crawl does not have to wait six hours.

## 2. Prerequisites

Step 1 (`01_create-smus-domain`) must have completed in apply mode so the
Config_File contains non-empty `smus_domain_id` and `admin_project_id` values.
The orchestrator passes these forward as `MT_SMUS_DOMAIN_ID` and
`MT_ADMIN_PROJECT_ID`; if either is empty when `run.sh` starts, the step halts
before any AWS call (see section 7).

The caller's AWS credentials must allow the following IAM actions in the
configured `aws_region`:

- `glue:GetDatabases`
- `glue:GetTables`
- `datazone:ListDataSources`
- `datazone:CreateDataSource`
- `datazone:StartDataSourceRun`

`jq` must be on `PATH`. The orchestrator sets `MT_*` environment variables for
every consumed config key.

## 3. Configuration keys consumed

The step reads exactly three keys from `./config/migration.config.json` (passed
through as the matching `MT_*` env vars by the runner):

| Config key         | Env var               | Purpose                                   |
|--------------------|-----------------------|-------------------------------------------|
| `aws_region`       | `MT_AWS_REGION`       | Region passed to every `aws` invocation.  |
| `smus_domain_id`   | `MT_SMUS_DOMAIN_ID`   | Target SMUS_Domain (filled by Step 1).    |
| `admin_project_id` | `MT_ADMIN_PROJECT_ID` | Target Admin_Project (filled by Step 1).  |

Each is required; an empty value triggers the halting precondition in section 7.

## 4. AWS CLI commands issued

The step runs no boto3, no Python SDK, and no provider SDK. Every AWS
interaction is a subprocess `aws` call from `run.sh`:

1. `aws glue get-databases --region "$MT_AWS_REGION"` — enumerates every
   database in the Glue_Catalog.
2. `aws glue get-tables --database-name <db> --region "$MT_AWS_REGION"` — once
   per discovered database, enumerates every table inside.
3. `aws datazone list-data-sources --domain-identifier "$MT_SMUS_DOMAIN_ID"
   --project-identifier "$MT_ADMIN_PROJECT_ID" --type GLUE` — idempotency
   check; if a data source named `migration-tool-glue-catalog` already exists,
   its `dataSourceId` is reused and the create call is skipped.
4. `aws datazone create-data-source --domain-identifier "$MT_SMUS_DOMAIN_ID"
   --project-identifier "$MT_ADMIN_PROJECT_ID" --name migration-tool-glue-catalog
   --type GLUE --configuration <json> --schedule '{"schedule":"cron(0 */6 * * ? *)"}'
   --publish-on-import` — creates the Glue-typed data source, where
   `<json>` carries one `relationalFilterConfigurations` entry per inventoried
   database with an `INCLUDE *` filter expression so every table is crawled.
5. `aws datazone start-data-source-run --domain-identifier "$MT_SMUS_DOMAIN_ID"
   --data-source-identifier <id>` — kicks off the initial crawl and records
   the resulting run ID.

## 5. Artifacts produced

All artifacts land under `./steps/04_catalog/outputs/`:

- `glue-catalog-inventory.json` — the deterministic catalog inventory
  (`{version: 1, fetched_utc, region, databases: [{name, tables: [{name,
  location}]}]}`). In dry-run mode the file is a placeholder
  (`{databases: [], dry_run: true}`) so downstream consumers always see a
  valid file.
- `datasource-run.json` — written in apply mode only; records the data source
  name, its ID, and the initial run ID
  (`{version: 1, recorded_utc, data_source_name, data_source_id, run_id}`).
- `run.log` — the per-step run log produced by `mt_init` / `mt_aws` in apply
  mode (the orchestrator's top-level run log under `./logs/run-<UTC>.log`
  receives the same records, redacted).

## 6. Dry-run vs apply

`run.sh` defaults to dry-run when neither `--apply` nor `--dry-run` is passed.

In dry-run mode the step:

- Skips every real AWS call. `mt_aws` emits one `DRY-RUN: aws ...` line per
  would-be invocation, including the resolved `--configuration`,
  `--schedule '{"schedule":"cron(0 */6 * * ? *)"}'`, and `--publish-on-import`
  flags so an operator can audit the exact command before any change occurs.
- Renders the configuration's `relationalFilterConfigurations` against a
  placeholder database list (`["sample_db"]`) when no live inventory exists,
  so the printed command is realistic.
- Writes `outputs/glue-catalog-inventory.json` with `dry_run: true` and an
  empty `databases` list.
- Does not write `outputs/datasource-run.json`; instead emits a
  `DRY-RUN: write outputs/datasource-run.json` line.

In apply mode the step:

- Calls `aws glue get-databases` and `aws glue get-tables` and writes the real
  inventory.
- Calls `aws datazone list-data-sources --type GLUE` for idempotency. If the
  named data source already exists, its ID is captured and `create-data-source`
  is skipped (Requirement 3.6).
- Otherwise calls `aws datazone create-data-source` with the inventory-derived
  configuration, the `cron(0 */6 * * ? *)` schedule, and `--publish-on-import`.
- Calls `aws datazone start-data-source-run` once and writes `datasource-run.json`
  with the resulting run ID.
- Tees stdout and stderr into the run log via `mt_aws`, with secret redaction
  applied by the orchestrator (Requirement 4.5).

## 7. Halting precondition

If `MT_SMUS_DOMAIN_ID` or `MT_ADMIN_PROJECT_ID` is unset or empty when
`run.sh` starts, the step writes `STATUS: missing_var <NAME>` to stdout and
exits with status 64 before any `aws` call is made. The orchestrator surfaces
the missing key and refuses to advance the run. Step 1
(`01_create-smus-domain`) must complete in apply mode first so those two IDs
are persisted to the Config_File. The same exit-64 / `STATUS: missing_var`
contract also covers an unset `MT_AWS_REGION`, and the step exits 64 with a
plain status line if `jq` is not available on `PATH`.

## 8. Citations

The procedure in this README is grounded in two sources:

- AWS Documentation MCP — cached at scaffold time under `./docs/cache/`:
  - [Create an Amazon SageMaker Unified Studio data source for AWS
    Glue](https://docs.aws.amazon.com/sagemaker-unified-studio/latest/userguide/data-source-glue.html)
    (cache key `d9f1b2616a2b5ab7`). Documents the `aws datazone
    create-data-source --type GLUE` payload shape — including the
    `glueRunConfiguration.relationalFilterConfigurations` list, the
    `schedule` block, the `enableSetting=ENABLED` flag, and the
    `publishOnImport=True` flag — that this step issues.
  - [Onboarding data in Amazon SageMaker Unified
    Studio](https://docs.aws.amazon.com/sagemaker-unified-studio/latest/adminguide/data-onboarding.html)
    (cache key `14b0cc71a1eec655`). Documents the catalog onboarding model
    (continuous metadata ingestion, publishing-for-discovery) that the
    `--publish-on-import` flag and 6-hour cron land on.

- Reference_Document section **"4. Best Path to Bring Existing Datasets, Glue
  Jobs, and ML Assets"** at the repository root
  (`SageMaker Unified Studio - Migration Answers.md`). Two verbatim passages
  from that section anchor the procedure:

  From the *Migration Paths by Asset Type* table:

  > AWS Glue Data Catalog (databases/tables) | Onboard via UI or scripts | ❌
  > No — metadata import only

  From *Method 3: Automated Data Onboarding (Domain-level)*:

  > Single-step onboarding from the SageMaker management console
  >
  > Continuous real-time metadata sync (no batch jobs)
  >
  > Real-time data quality metric synchronization
  >
  > Can be configured during domain creation or added later

  This step is the literal operationalization of that recommended path: no
  data movement, metadata-only import, every database covered by an
  `INCLUDE *` filter, a six-hour cron, publish-on-import enabled, and a
  follow-up `start-data-source-run` to bootstrap the first crawl.
