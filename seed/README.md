# Seed_Script — Same-Account Source-Resource Provisioning

> Top-level documentation for the bash provisioning tool under `./seed/`.
> Implements [Requirement 20](../.kiro/specs/sagemaker-migration-tool/requirements.md) of the SageMaker Migration Tool spec.
> Citations cover Requirements 20.1, 20.2, 20.7, 20.13, 20.28, 20.30, and 20.32.

---

## Purpose

The Seed_Script is a self-contained bash provisioning tool that stands up lightweight, seed-grade versions of the source services that the Migration_Tool migrates. It exists so the Migration_Tool can be exercised end-to-end against a realistic source environment without depending on pre-existing customer infrastructure.

The post-refactor scope is the data-flow surface the Migration_Tool's downstream paths exercise end-to-end:

`AWS Glue → Amazon RDS Postgres → Amazon SNS → Amazon MSK → Amazon Kinesis → Amazon Data Firehose → AWS Lambda → synthetic data-gen Lambdas → Amazon CloudWatch → Amazon MWAA`

The Seed_Script provisions these source resources INTO the **same AWS account** where the Migration_Tool's Step 1 will subsequently create the SMUS_Domain. Everything in S3 is **Parquet format with Glue catalog registration** — there is no Iceberg surface in the seed.

The Seed_Script is **bash-only** and uses AWS CLI directly. It never imports `boto3` and never invokes Python that targets AWS at runtime (Requirement 20.1). The two exceptions to "no Python at runtime" are:

- The disposable RDS seeder Lambda built and torn down inside `seed/rds/create.sh`. The seeder runs server-side under Lambda — never on the operator's host — and is deleted by the same script that created it.
- The two synthetic event generators in `seed/data-gen/`. They also run server-side under Lambda, on a 1-minute schedule, and write to Kinesis / MSK.

Both are deployment artifacts whose source is in `seed/<module>/fixtures/`. The bash side never imports them.

---

## Same-Account Contract (Requirement 20.28)

The Seed_Script and the Migration_Tool operate against the **same AWS account by design**. Concretely:

- `source_account_id` in `./seed/seed.config.json` MUST equal `source_account_id` in `./config/migration.config.json` whenever both files exist.
- If the two values disagree, both `seed/provision.sh` and `seed/teardown.sh` halt with a non-zero exit and an error message naming both values **before** any state-changing AWS CLI command is issued.
- When `./config/migration.config.json` is absent, or when its `source_account_id` has not yet been collected, the check is a no-op — the contract only fires when both files declare the value and the values disagree.

The reciprocal check is enforced from the Migration_Tool side as well: the Migration_Tool will halt on the same mismatch.

---

## No SMUS Creation (Requirement 20.30)

The Seed_Script **never** creates a SMUS_Domain or an Admin_Project. It never invokes `aws datazone create-domain` or `aws datazone create-project`. Those resources belong exclusively to the Migration_Tool's Step 1.

Re-runs of `./seed/provision.sh --apply` that follow a Migration_Tool run also have **zero state-changing effect** on Migration_Tool resources (Requirement 20.32):

- Zero `aws datazone create-*` commands.
- Zero AWS CLI commands targeting the SMUS_Domain ID or Admin_Project ID recorded in `./config/migration.config.json`.

The Seed_Script's role is strictly to populate the source services that the Migration_Tool subsequently migrates INTO the SMUS_Domain.

---

## Resource-Name Prefix

Every resource the Seed_Script creates is named `${SBX_SEED_NAME_PREFIX}-<resource>`. The prefix is collected on first run, persisted to `seed/seed.config.json` as `seed_name_prefix`, and exported to every per-service `create.sh` as `SBX_SEED_NAME_PREFIX`.

The prefix exists to guarantee two properties:

- Seed-created resources cannot collide with non-seed customer resources that already exist in the same AWS account.
- Seed-created resources cannot collide with the SMUS_Domain or any SMUS_Connection that the Migration_Tool subsequently creates in that same account.

Teardown deletes only resources matching **both**:

1. A name beginning with `${SBX_SEED_NAME_PREFIX}-`, **and**
2. An ARN or ID recorded in `./seed/seed.state.json`.

Resources that match neither gate are skipped with a `STATUS:` line and never deleted, even when they appear in the same account.

> **Glue catalog table naming caveat.** AWS Glue catalog table names cannot contain hyphens. The seed builds catalog table names by replacing the hyphens in the prefix with underscores, so a `seed_name_prefix=smus-seed` yields catalog tables like `smus_seed_kinesis_events_parquet`. The DATABASE name keeps its hyphenated form (`smus-seed-db-raw`); only the table component is underscored.

---

## Directory Layout

```
seed/
├── README.md                      # this file (Requirement 20.26)
├── provision.sh                   # top-level orchestrator (provision)
├── teardown.sh                    # top-level orchestrator (teardown)
├── seed.config.json               # SBX_* config (created on first run)
├── seed.config.json.example       # documented example shape
├── seed.state.json                # per-service status + resource IDs
├── seed.state.json.example        # documented example shape
├── _lib/
│   └── common.sh                  # shared SBX_* bash helpers (sbx_aws, sbx_init, sbx_status, …)
├── logs/                          # one log per invocation: run-<UTC>.log (Requirement 20.14)
├── glue/                          # Seed_Service_Module: AWS Glue (two-phase)
│   ├── create.sh
│   ├── teardown.sh
│   ├── README.md
│   └── fixtures/                  # job scripts (etl, pythonshell, rds-to-parquet) + sample CSVs
├── rds/                           # Seed_Service_Module: Amazon RDS Postgres (NEW)
│   ├── create.sh
│   ├── teardown.sh
│   ├── README.md
│   └── fixtures/                  # seed.sql + seeder_handler.py
├── sns/                           # Seed_Service_Module: Amazon SNS
│   ├── create.sh
│   ├── teardown.sh
│   └── README.md
├── msk/                           # Seed_Service_Module: Amazon MSK
│   ├── create.sh
│   ├── teardown.sh
│   └── README.md
├── kinesis/                       # Seed_Service_Module: Amazon Kinesis Data Streams (NEW)
│   ├── create.sh
│   ├── teardown.sh
│   └── README.md
├── firehose/                      # Seed_Service_Module: Amazon Data Firehose (NEW)
│   ├── create.sh
│   ├── teardown.sh
│   └── README.md
├── lambda/                        # Seed_Service_Module: AWS Lambda
│   ├── create.sh
│   ├── teardown.sh
│   └── README.md
├── data-gen/                      # Seed_Service_Module: synthetic event generators (NEW)
│   ├── create.sh
│   ├── teardown.sh
│   ├── README.md
│   └── fixtures/                  # event_generator.py
├── cloudwatch/                    # Seed_Service_Module: Amazon CloudWatch
│   ├── create.sh
│   ├── teardown.sh
│   └── README.md
└── mwaa/                          # Seed_Service_Module: Amazon MWAA
    ├── create.sh
    ├── teardown.sh
    ├── README.md
    └── dags/                      # convertible_dag.py + blocked_dag.py + glue_refs_dag.py
```

Each `Seed_Service_Module` folder contains a `create.sh`, a `teardown.sh`, and a `README.md` that names the AWS CLI commands the module issues, the inputs it consumes from `seed.config.json` / `seed.state.json`, and the resource identifiers it persists to `seed.state.json` (Requirement 20.27).

The `flink-kda` and `quicksight` modules from earlier iterations are **gone**. The Migration_Tool's data-flow validation no longer requires either, and removing them simplifies the seed to a coherent kinesis/MSK → firehose → S3 Parquet → Glue catalog → MWAA chain.

---

## Provisioning Order (Requirement 20.7)

`seed/provision.sh` invokes the per-service modules in this exact 13-step dependency order. MWAA is **last** because its environment provisioning is the long pole (typically 20–30 minutes).

```
1.  glue --phase=foundation
2.  rds
3.  glue --phase=rds-bridge
4.  sns
5.  msk
6.  kinesis
7.  data-gen
8.  firehose
9.  glue --phase=crawler
10. glue --phase=kafka
11. lambda
12. cloudwatch
13. mwaa
```

In plain bullets:

1. **`glue --phase=foundation`** — data S3 bucket + sample CSV uploads (`orders.csv`, `customers.csv`), IAM roles (crawler + job), both Glue databases (`<prefix>-db-raw`, `<prefix>-db-curated`), JDBC connection (placeholder URL — RDS not yet up), NETWORK connection, glueetl + pythonshell jobs, **and runs both jobs synchronously** so `s3://<bucket>/curated/orders_parquet/` and `s3://<bucket>/curated/customers_csv_parquet/` contain real Parquet by the end of the phase.

2. **`rds`** — DB subnet group + security group + Postgres `db.t3.micro`. After the instance reaches `available`, a one-shot Lambda (`<prefix>-rds-seeder`) loads `seed/rds/fixtures/seed.sql` (50 customers + 25 products) and is then deleted.

3. **`glue --phase=rds-bridge`** — re-creates the JDBC connection with the real RDS endpoint + master password (replacing the placeholder URL from foundation), registers `<prefix>-rds-to-parquet`, and **runs that job synchronously** so `s3://<bucket>/curated/customers/` and `s3://<bucket>/curated/products/` contain real Parquet.

4. **`sns`** — `<prefix>-orders` and `<prefix>-alerts` topics with placeholder HTTPS subscriptions.

5. **`msk`** — small MSK cluster plus one sample topic. Persists `bootstrap_brokers` to `seed.state.json`.

6. **`kinesis`** — single ON_DEMAND Kinesis Data Stream named `<prefix>-events`.

7. **`data-gen`** — two on-schedule Lambdas (one writes to Kinesis, one writes to MSK) + an EventBridge rule firing every minute. **Runs BEFORE firehose** in the post-resequencing order so live events are flowing through the kinesis stream + MSK topic by the time firehose binds to them.

8. **`firehose`** — pre-registers the two raw Glue catalog tables (`<prefix>_kinesis_events_parquet`, `<prefix>_msk_events_parquet`) in `<prefix>-db-raw`, then creates the IAM role + two Firehose delivery streams. Both streams use Firehose's `DataFormatConversionConfiguration` against those raw catalog tables to land schema-converted Parquet at `raw/kinesis/dt=<hour>/` and `raw/msk/dt=<hour>/`. The two raw catalog tables are now owned by firehose (post-resequencing) — formerly registered by `glue --phase=1`.

9. **`glue --phase=crawler`** — creates and runs the Glue crawler over the curated zone (now that real data exists in `curated/orders_parquet/`, `curated/customers_csv_parquet/`, `curated/customers/`, and `curated/products/`). The crawler discovers up to four tables in `<prefix>-db-curated`.

10. **`glue --phase=kafka`** — KAFKA Glue connection bound to MSK's bootstrap broker string. Flips `glue.status` to `provisioned`.

11. **`lambda`** — two ZIP-deployed sample Lambda functions.

12. **`cloudwatch`** — alarms, dashboards, and log groups.

13. **`mwaa`** — exactly one MWAA environment running Apache Airflow 3.0.6 at `mw1.small`. Runs LAST.

**Why glue is split into FOUR phases** — three independent ordering constraints have to be satisfied simultaneously:
1. Glue jobs must run against REAL DATA (CSV, RDS rows). → foundation phase runs etl + pythonshell against the seed CSVs; rds-bridge phase runs rds-to-parquet against the seed Postgres tables.
2. The crawler must run against REAL DATA in the curated zone. → crawler phase runs LAST among glue phases (after the jobs have written Parquet).
3. The KAFKA Glue connection needs MSK's bootstrap brokers. → kafka phase runs after `seed/msk/`.

### Idempotency on re-runs (Requirement 20.13)

Every `create.sh` precedes each `aws ... create-*` call with a corresponding `aws ... list-*`, `get-*`, or `describe-*` lookup against the identifiers recorded in `seed.state.json`. A second `./seed/provision.sh --apply` invocation immediately following a successful first run issues **zero** `create-*` commands.

### State writes only in apply mode (bug fix 1a)

Every `create.sh` and `teardown.sh` gates state writes behind `sbx_apply_mode`. In dry-run, no `provisioned`, `<phase>_done`, or `torn_down` markers are written to `seed.state.json` — the seed file remains a true reflection of what AWS actually contains.

---

## Teardown Order

`seed/teardown.sh` invokes the per-service `teardown.sh` scripts in the **strict reverse** of the provisioning order, with the four glue phases collapsed into a single pass at the end:

```
mwaa  →  cloudwatch  →  lambda  →  firehose  →  data-gen  →  kinesis  →  msk  →  sns  →  rds  →  glue
```

`firehose` runs BEFORE `data-gen` (and BEFORE `kinesis`/`msk`) so it stops consuming from those sources before they are torn down. `firehose`'s teardown also deletes the two raw Glue catalog tables it owns (`<prefix>_kinesis_events_parquet`, `<prefix>_msk_events_parquet`) AFTER the delivery streams are gone but BEFORE `glue/teardown.sh` drops `<prefix>-db-raw`.

Two safety gates apply to **every** `aws ... delete-*` invocation issued by the teardown orchestrator and by every per-service `teardown.sh`:

- **Prefix gate** — the resource name MUST begin with `${SBX_SEED_NAME_PREFIX}-`.
- **State-file gate** — the resource ARN or ID MUST be recorded in `./seed/seed.state.json`.

Any candidate that fails either gate is skipped with a `STATUS:` line and never deleted, even when it appears in the same AWS account. Both gates exist precisely because the Seed_Script and the Migration_Tool share an AWS account; an accidental teardown could otherwise destroy non-seed customer resources.

In `--apply` teardown mode, the script prompts the operator to retype the literal `seed_name_prefix` from `seed.config.json` and aborts before any `aws ... delete-*` call if the confirmation does not match. In dry-run, the script prints every would-be `aws ... delete-*` invocation and changes nothing.

The RDS teardown is the longest pole on the destroy side: `delete-db-instance` takes 5–10 minutes, and the security-group delete then has to retry-with-backoff because RDS holds the SG ARN for a couple minutes after the instance is gone.

---

## Bootstrap

The Seed_Config_File at `./seed/seed.config.json` does not ship checked in. There are two equivalent ways to create it:

**Option A — copy the example and edit:**

```bash
cp seed/seed.config.json.example seed/seed.config.json
$EDITOR seed/seed.config.json     # set seed_name_prefix, aws_region, source_account_id, rds.*
```

**Option B — let `provision.sh` prompt for the required fields:**

```bash
bash seed/provision.sh
# On first run with no seed.config.json, the script prompts for:
#   - aws_region          (validated against ^[a-z]{2}-[a-z]+-\d$)
#   - source_account_id   (validated as exactly 12 digits)
#   - seed_name_prefix    (lowercase letters, digits, hyphens)
# The accepted values are persisted atomically (write-temp-then-rename)
# to seed/seed.config.json BEFORE any AWS CLI call is issued.
```

Subsequent runs read the file directly and never re-prompt. The RDS section of `seed.config.json` (vpc_id, subnet_ids, engine_version) does not have an interactive prompt — edit it directly before running RDS in apply mode.

---

## Command-Line Surface (Requirement 20.2)

Both `seed/provision.sh` and `seed/teardown.sh` accept the same two flags:

| Flag | Behavior |
|---|---|
| `--dry-run` | Default. Prints every AWS CLI command it would run with the `DRY-RUN: ` prefix. Changes nothing in AWS. |
| `--apply`   | Executes the AWS CLI commands required to create (or delete) the seed resources. |

`--apply` and `--dry-run` are **mutually exclusive**. Passing both flags exits non-zero with an error message, before any other side effect.

```bash
# Provision
bash seed/provision.sh                    # dry-run (default) — prints, changes nothing
bash seed/provision.sh --dry-run          # explicit dry-run
bash seed/provision.sh --apply            # actually create resources

# Teardown
bash seed/teardown.sh                     # dry-run (default) — prints would-be deletes
bash seed/teardown.sh --dry-run           # explicit dry-run
bash seed/teardown.sh --apply             # actually delete resources (after confirmation prompt)

# Both flags together → non-zero exit BEFORE any work
bash seed/provision.sh --apply --dry-run  # error: flags are mutually exclusive
```

The wrapper `./seed.sh` accepts the same flags plus per-service selectors (`--rds`, `--kinesis`, `--firehose`, `--data-gen`, etc.) so a subset run is one command:

```bash
./seed.sh provision --rds --kinesis --apply
./seed.sh teardown --data-gen --apply
```

---

## Logs

Every invocation of `provision.sh` or `teardown.sh` writes one timestamped log file at:

```
./seed/logs/run-<UTC>.log
```

The log records every AWS CLI command issued (prefixed with `DRY-RUN: ` in dry-run), its truncated stdout, its truncated stderr, its exit code, and its elapsed time. Logs are written under `./seed/logs/` only; the Seed_Script never writes to the Migration_Tool's `./logs/` directory.

---

## Sensitive data in `seed.state.json`

The RDS module persists the master password under `.services.rds.resources.master_password` so the Glue JDBC connection (and operator-side debugging) can use it without a separate Secrets Manager round-trip. **`seed.state.json` should be treated as sensitive** — do not commit it, do not share it, and chmod it `0600` on shared boxes. The Seed_Script's `.gitignore` excludes it; if you copy or back up the file, take the same precautions you would with a `.env` containing a database password.

---

## Schemas

### `seed.config.json`

Persisted SBX_* configuration. The example template is in [`seed.config.json.example`](./seed.config.json.example).

```json
{
  "version": 1,
  "seed_name_prefix": "string (lowercase letters, digits, hyphens; matches ^[a-z0-9][a-z0-9-]*$)",
  "aws_region": "string (matches ^[a-z]{2}-[a-z]+-\\d$)",
  "source_account_id": "string (12 digits — must equal config/migration.config.json's source_account_id when that file exists)",
  "msk": {
    "mode": "serverless | provisioned",
    "kafka_version": "string (e.g. 3.6.0)",
    "vpc_subnet_ids": ["subnet-..."],
    "security_group_ids": ["sg-..."]
  },
  "rds": {
    "vpc_id": "vpc-...",
    "subnet_ids": ["subnet-...", "subnet-..."],
    "engine_version": "string (major; e.g. \"16\")"
  },
  "glue": {
    "network_subnet_id": "subnet-...",
    "network_security_group_id": "sg-...",
    "network_availability_zone": "string"
  },
  "lambda": {
    "memory_mb": "integer (e.g. 128)",
    "timeout_seconds": "integer (e.g. 30)"
  },
  "mwaa": {
    "environment_class": "string (e.g. mw1.small)",
    "airflow_version": "string (pinned to 3.0.6)",
    "subnet_ids": ["subnet-..."],
    "security_group_ids": ["sg-..."]
  }
}
```

The first three fields (`seed_name_prefix`, `aws_region`, `source_account_id`) are prompted on first run and validated before any AWS CLI command is issued. All other fields have safe defaults and may be edited directly.

### `seed.state.json`

Per-service provisioning status and resource identifiers. The example template is in [`seed.state.json.example`](./seed.state.json.example).

```json
{
  "version": 1,
  "last_updated_utc": "string | null (RFC-3339 UTC; advanced on every state write)",
  "services": {
    "glue":       { "status": "pending|provisioned|phase1_done|failed", "resources": { "/* databases, connections, jobs (incl. <prefix>-rds-to-parquet), data_bucket, tables (incl. raw + curated parquet), iam_roles, crawler */": "..." } },
    "rds":        { "status": "pending|provisioned|failed",                "resources": { "/* instance_id, endpoint, port, db_name, master_username, master_password, subnet_group_name, security_group_id, engine, engine_version */": "..." } },
    "sns":        { "status": "pending|provisioned|failed",                "resources": { "/* topic ARNs, subscription ARNs */": "..." } },
    "msk":        { "status": "pending|provisioned|failed",                "resources": { "/* cluster ARN, bootstrap_brokers (consumed by glue phase 2 + data-gen) */": "..." } },
    "kinesis":    { "status": "pending|provisioned|failed",                "resources": { "stream_name": "...", "stream_arn": "..." } },
    "firehose":   { "status": "pending|provisioned|failed",                "resources": { "/* role_arn, role_name, kinesis_stream_name, msk_stream_name, kinesis_stream_arn, msk_stream_arn */": "..." } },
    "lambda":     { "status": "pending|provisioned|failed",                "resources": { "/* function ARNs */": "..." } },
    "data-gen":   { "status": "pending|provisioned|failed",                "resources": { "/* role_arn, kinesis_function_arn, msk_function_arn, eventbridge_rule_arn */": "..." } },
    "cloudwatch": { "status": "pending|provisioned|failed",                "resources": { "/* alarm names, dashboard names, log-group ARNs */": "..." } },
    "mwaa":       { "status": "pending|provisioned|failed",                "resources": { "/* environment ARN, environment name, airflow_version, dag_bucket */": "..." } }
  }
}
```

`seed.state.json` is the source of truth for both idempotent re-runs (modules consult `list-*` / `get-*` / `describe-*` against the recorded identifiers and skip any `create-*` whose target already exists) and for the teardown state-file gate.

---

## Isolation from the Migration_Tool

The Seed_Script and the Migration_Tool live side by side but exchange nothing at runtime:

- The Seed_Script reads `./config/migration.config.json` **only** to enforce the same-account contract (Requirement 20.28). It never writes that file.
- The Seed_Script never reads or writes `./state/migration.state.json`.
- The Migration_Tool never invokes, imports, or references anything under `./seed/`.
- The Seed_Script's helper library at `./seed/_lib/common.sh` is independent of the Migration_Tool's `./steps/_lib/common.sh`. The two libraries do not source each other.
- The Seed_Script's environment-variable prefix is `SBX_` (read as "source-bootstrap"), distinct from the Migration_Tool's `MT_` prefix.

This isolation is enforced statically by the property-test suite in `tests/property/`.

---

## Apache Airflow Version

The MWAA module pins Apache Airflow to **3.0.6** at the smallest available environment class (`mw1.small`). Before creating the environment, `seed/mwaa/create.sh` runs a region-capability pre-flight to confirm that Airflow 3.0.6 is supported in the configured `aws_region`. If 3.0.6 is not supported in that region, the module halts with a non-zero exit and a clear error message. The module never silently falls back to a different Airflow version.

The pinned version flows through `seed.config.json` → `mwaa.airflow_version` → `seed/mwaa/create.sh` → `aws mwaa create-environment`, and is persisted in `seed.state.json` under `services.mwaa.resources.airflow_version`.

---

## Sample DAGs

`seed/mwaa/create.sh` uploads exactly **three sample DAGs** to the MWAA environment's DAG S3 bucket. The Convertible / Blocked / Glue-refs distinction is unchanged by the refactor:

| DAG | Operator profile | Migration_Tool path it exercises |
|---|---|---|
| **Convertible** | Uses only AWS-provider operators (e.g. `GlueJobOperator`, `LambdaInvokeFunctionOperator`, `S3KeySensor`, `SnsPublishOperator`). | Step 8 marks the DAG `Convertible` (Requirement 15.4) and the YAML converter produces a YAML workflow. |
| **Blocked** | Uses at least one Non_AWS_Operator (e.g. `BashOperator`). | Step 8 marks the DAG `Blocked` (Requirement 15.4) and emits no YAML for it. |
| **Glue-refs** | Tasks reference both the seed Glue jobs (now including `<prefix>-rds-to-parquet`) and the seed Glue connections from `seed/glue/`. | Step 3's connection-rewrite path (Requirement 9.4) runs and rewrites Glue connection references against the Connection_Mapping_File from Step 4b. |

The three DAGs collectively exercise the Convertible, Blocked, and connection-rewrite paths against deterministic, prefixed seed resources.

---

## Reference

The Seed_Script implements [Requirement 20](../.kiro/specs/sagemaker-migration-tool/requirements.md) of the SageMaker Migration Tool spec in full. Specific clauses referenced from this README:

- **20.1** — `./seed/` is bash-only and calls AWS CLI directly.
- **20.2** — `--apply` / `--dry-run` discipline; default is dry-run.
- **20.7** — provisioning order with MWAA last.
- **20.13** — idempotent re-runs via `list-*` / `get-*` / `describe-*` lookups.
- **20.28** — same-account contract on `source_account_id`.
- **20.30** — no SMUS_Domain or Admin_Project creation.
- **20.32** — zero state-changing effect on Migration_Tool resources after a migration run.

The full text of Requirement 20 is in [`.kiro/specs/sagemaker-migration-tool/requirements.md`](../.kiro/specs/sagemaker-migration-tool/requirements.md).
