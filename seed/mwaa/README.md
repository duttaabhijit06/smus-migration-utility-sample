# Seed MWAA module

> **Task 24.12** · **Requirements: 20.7, 20.13, 20.23, 20.24, 20.29, 20.31**

This Seed_Service_Module provisions the Amazon MWAA pieces of the seed deployment: one DAG S3 bucket, three sample DAGs, and exactly **1** MWAA environment running Apache Airflow `3.0.6` at environment class `mw1.small`. MWAA is the long pole of `seed/provision.sh` (typically 20–30 minutes of environment provisioning), which is why the orchestrator invokes it **last** in the canonical order (Requirement 20.7).

The module never touches the SMUS_Domain, never calls `aws datazone create-*`, and never targets the SMUS_Domain ID or Admin_Project ID recorded in `./config/migration.config.json` (Requirements 20.31 and 20.32). It only creates the source-side MWAA resources that the Migration_Tool's Steps 5, 6, 7, and 8 later read.

## Resources created

Every name begins with `${SBX_SEED_NAME_PREFIX}-` (Requirement 20.29):

| Resource | Name | Notes |
| --- | --- | --- |
| S3 bucket | `<prefix>-mwaa-dags-<account>-<region>` | DAG source bucket; S3 Versioning **Enabled** (MWAA requirement). The bucket name is fully deterministic from the seed_name_prefix + AWS account ID + region triple, so a re-run computes the exact same name without consulting state and the prefix gate in `teardown.sh` has a stable target. This is the bucket the Migration_Tool's Step 5 must EXCLUDE per Requirement 12.2 and the bucket Step 6 reads DAG code from per Requirement 13.1. |
| MWAA environment | `<prefix>-mwaa-env` | Airflow `3.0.6`, class `mw1.small`. `--source-bucket-arn` = the DAG bucket above; `--dag-s3-path dags/`. |
| Sample DAG | `dags/convertible_dag.py` | AWS-provider operators only (`GlueJobOperator`, `LambdaInvokeFunctionOperator`-class, `S3KeySensor`, `SnsPublishOperator`-class). Verdict: **Convertible** per Step 8 / Requirement 15.4. |
| Sample DAG | `dags/blocked_dag.py` | Includes a `BashOperator` (Non_AWS_Operator). Verdict: **Blocked** per Step 8 / Requirement 15.4. |
| Sample DAG | `dags/glue_refs_dag.py` | References both seed Glue jobs AND seed Glue connection names from `seed/glue/` (JDBC, KAFKA, NETWORK). Exercises Step 3's connection-rewrite path per Requirement 9.4. |

## Region-capability pre-flight (Requirement 20.23)

`create.sh` calls `aws mwaa list-supported-airflow-versions --region $SBX_REGION` and asserts that Apache Airflow `3.0.6` is in the returned `AirflowVersions[]` array. If it is not, the script halts with **exit code `64`** and the STATUS line:

```
STATUS: error airflow_3.0.6_unsupported_in_region
```

There is **no silent fallback** to a different Airflow version. The version is pinned because the sample DAGs are authored against Airflow 3's import surface (`airflow.decorators.dag` / `airflow.decorators.task` / `airflow.providers.amazon.aws.*`), and Step 8's Convertible/Blocked verdict logic depends on that import surface staying stable across the seed.

In dry-run the pre-flight is emitted as a `DRY-RUN: aws mwaa list-supported-airflow-versions ...` line so the operator can review the plan; the actual capability assertion fires only in `--apply`.

## Operator prerequisites

`create.sh` does **not** create VPC infrastructure or the MWAA execution role — both are operator-supplied. The script reads them from environment variables OR from `seed.config.json`:

| Variable | seed.config.json field | Purpose | Format |
| --- | --- | --- | --- |
| `SBX_MWAA_EXECUTION_ROLE_ARN` | `.mwaa.execution_role_arn` | IAM role MWAA uses to read the DAG bucket and invoke seed Glue jobs / Lambda / SNS / etc. Trust policy must allow `airflow-env.amazonaws.com`. | `arn:aws:iam::<account>:role/<role-name>` |
| `SBX_MWAA_SUBNET_IDS` | `.mwaa.subnet_ids` | Two private subnets in different AZs (MWAA requirement). | comma-separated `subnet-aaa,subnet-bbb` (env), or array (config) |
| `SBX_MWAA_SECURITY_GROUP_IDS` | `.mwaa.security_group_ids` | Security groups attached to the environment. | comma-separated `sg-aaa,sg-bbb` (env), or array (config) |

In dry-run the script substitutes clearly-fake placeholders (`subnet-PLACEHOLDER-1,subnet-PLACEHOLDER-2`, `sg-PLACEHOLDER`, `arn:aws:iam::<account>:role/<prefix>-mwaa-exec-PLACEHOLDER`) so the printed plan is coherent end-to-end without the inputs set; in apply-mode the script requires them and exits `64` with `STATUS: error missing_var ...` if any are missing.

## AWS CLI commands issued

`create.sh`:

| Phase | Command | Idempotency check |
| --- | --- | --- |
| Pre-flight | `aws mwaa list-supported-airflow-versions --region $SBX_REGION` | n/a (read-only); halts with `airflow_3.0.6_unsupported_in_region` if the response does not contain `3.0.6`. |
| DAG bucket | `aws s3api create-bucket ...` | `aws s3api head-bucket ...` |
| DAG bucket | `aws s3api put-public-access-block ...` | run once on create |
| DAG bucket | `aws s3api put-bucket-versioning --versioning-configuration Status=Enabled` | always asserted (MWAA requirement; idempotent) |
| DAG upload | `aws s3 cp <local>/dags/<file>.py s3://<bucket>/dags/<file>.py` | `aws s3api head-object` per key |
| Environment | `aws mwaa create-environment --airflow-version 3.0.6 --environment-class mw1.small --source-bucket-arn <bucket-arn> --dag-s3-path dags/ --execution-role-arn <role-arn> --network-configuration <subnets+SGs>` | `aws mwaa get-environment ...` |
| Wait | `aws mwaa get-environment ...` polled every 30 s for up to 60 polls (30 min budget) until `Environment.Status == AVAILABLE`. Skipped in dry-run. | n/a |

`teardown.sh` (strict reverse, Requirement 20.5):

| Step | Command | Idempotency check |
| --- | --- | --- |
| 1 | `aws mwaa delete-environment --name <prefix>-mwaa-env` | `aws mwaa get-environment ...` |
| 2 | `aws s3api list-object-versions ...` + `aws s3api delete-objects ...` | best-effort version + delete-marker purge |
| 2 | `aws s3 rm s3://<bucket> --recursive` | empties current-version objects (no-op if none) |
| 2 | `aws s3api delete-bucket --bucket <bucket>` | `aws s3api head-bucket ...` (skipped if absent) |

Teardown is **gated** twice (Requirement 20.31): a name must (1) start with `${SBX_SEED_NAME_PREFIX}-` AND (2) be recorded in `./seed/seed.state.json` under `services.mwaa.resources`. A resource that fails either gate is left untouched.

## Persisted identifiers

After `--apply` succeeds, `services.mwaa.resources` in `./seed/seed.state.json` is the flat shape this task binds:

```json
{
  "status": "provisioned",
  "resources": {
    "environment_name": "<prefix>-mwaa-env",
    "environment_arn": "arn:aws:airflow:<region>:<account>:environment/<prefix>-mwaa-env",
    "airflow_version": "3.0.6",
    "environment_class": "mw1.small",
    "dag_bucket": "<prefix>-mwaa-dags-<account>-<region>",
    "dag_bucket_arn": "arn:aws:s3:::<prefix>-mwaa-dags-<account>-<region>",
    "dags_uploaded": [
      "dags/convertible_dag.py",
      "dags/blocked_dag.py",
      "dags/glue_refs_dag.py"
    ]
  }
}
```

The four task-required fields — `environment_name`, `environment_arn`, `airflow_version`, `dag_bucket` — are written via `sbx_state_set_service mwaa <payload>` from `seed/_lib/common.sh`. The bucket name is persisted **before** the DAG upload, and the environment ARN is persisted **before** the wait-for-AVAILABLE poll, so a SIGKILL between bucket-create and environment-AVAILABLE still leaves teardown able to identify and clean up partially-provisioned resources (Requirement 20.12). `teardown.sh` flips `status` to `torn_down` and leaves the rest of the resource block intact so a subsequent operator can audit what was previously provisioned.

## Idempotency

A second `bash seed/mwaa/create.sh --apply` immediately after a successful first run issues exactly **zero** `aws ... create-*` commands. Concretely:

* `aws s3api head-bucket` returns `0` on the persisted bucket name → the script skips bucket creation and public-access-block configuration. (`put-bucket-versioning` is always asserted but is itself idempotent.)
* `aws s3api head-object` per DAG key returns `0` → the script skips the `aws s3 cp` for that key.
* `aws mwaa get-environment` returns the existing environment → the script skips `aws mwaa create-environment`. If the existing environment's `Status` is already `AVAILABLE` the wait-loop short-circuits on its first poll.

This is the source-of-truth contract Requirement 20.13 asserts, and it is what Property 22(b) verifies for the MWAA module.

## Dependency on lambda + glue state

This module is the **last** step of `seed/provision.sh` (Requirement 20.7), so by the time `mwaa/create.sh --apply` runs all upstream Seed_Service_Modules have already populated `./seed/seed.state.json`. The DAGs reference upstream resources by **name only** (resolved at DAG-parse time inside the MWAA scheduler from the same `SBX_SEED_NAME_PREFIX` envelope), so this module does NOT block on missing state — but the names are only meaningful when the upstream modules have run.

| Upstream module | State path read by | Resource referenced | Used by |
| --- | --- | --- | --- |
| `seed/glue/create.sh` (phase 1) | `.services.glue.resources.jobs[]` | `<prefix>-etl-job`, `<prefix>-pythonshell-job`, `<prefix>-rds-to-parquet` (Requirement 20.15; `rds-to-parquet` is the post-refactor RDS → curated Parquet ETL job) | `convertible_dag.py`, `glue_refs_dag.py`, `blocked_dag.py` (`GlueJobOperator.job_name`) |
| `seed/glue/create.sh` (phase 1) | `.services.glue.resources.connections[]` | `<prefix>-jdbc-conn` (now wired to the seed RDS Postgres endpoint), `<prefix>-network-conn` | `glue_refs_dag.py` (`script_args["--glue_connection_*"]`) — exercises Step 3's connection-rewrite path per Requirement 9.4 |
| `seed/glue/create.sh` (phase 2) | `.services.glue.resources.connections[]` | `<prefix>-kafka-conn` | `glue_refs_dag.py` (`script_args["--glue_connection_kafka"]`) |
| `seed/glue/create.sh` (phase 1) | `.services.glue.resources.tables[]` | `<prefix>_kinesis_events_parquet`, `<prefix>_msk_events_parquet` (in `<prefix>-db-raw`); `<prefix>_customers_parquet`, `<prefix>_products_parquet` (in `<prefix>-db-curated`) | DAG smoke tests querying the catalog through Athena (advanced; not part of the canonical sample DAGs) |
| `seed/glue/create.sh` (phase 1) | `.services.glue.resources.data_bucket` | `<prefix>-glue-data-<account>-<region>` (the seed data bucket; serves both raw and curated zones) | `convertible_dag.py` (`S3KeySensor.bucket_name`) |
| `seed/rds/create.sh` | `.services.rds.resources.endpoint` | `<prefix>-postgres` Postgres instance reachable at `<endpoint>:5432/seeddb`, populated by `seed/rds/fixtures/seed.sql` | The `<prefix>-rds-to-parquet` Glue job that the convertible DAG can invoke |
| `seed/kinesis/create.sh` | `.services.kinesis.resources.stream_arn` | `<prefix>-events` ON_DEMAND Kinesis Data Stream | Inputs of the kinesis-to-Parquet Firehose; observable via DAG-side audit |
| `seed/lambda/create.sh` | `.services.lambda.function_arns[]` | `<prefix>-fn-1`, `<prefix>-fn-2` (Requirement 20.20) | `convertible_dag.py` (`LambdaInvokeFunctionOperator.function_name`) |
| `seed/sns/create.sh` | `.services.sns.resources.topics[]` | `<prefix>-orders` topic ARN (Requirement 20.17) | `convertible_dag.py` (`SnsPublishOperator.target_arn`) |

The DAGs do not import these state paths directly — they parse the seed-prefixed names from `SBX_SEED_NAME_PREFIX` at DAG-parse time, so a DAG-parse smoke test (e.g. `python -c "import dags.convertible_dag"`) succeeds before any upstream module has run. The names only resolve to live AWS resources when MWAA executes the DAG against an account where the upstream Seed_Service_Modules have completed.

The Convertible / Blocked / Glue-refs distinction in the three sample DAGs is unchanged by the refactor: `blocked_dag.py` still includes `BashOperator` (Non_AWS_Operator → `Blocked` verdict), `convertible_dag.py` still uses only AWS-provider operators, and `glue_refs_dag.py` still passes JDBC/KAFKA/NETWORK connection names through `GlueJobOperator.script_args` so Step 3's connection-rewrite path runs.



`aws mwaa create-environment` returns immediately with `Environment.Status = CREATING`; the environment typically reaches `AVAILABLE` 20–30 minutes later. The apply-mode poll loop in `create.sh` calls `aws mwaa get-environment` every 30 seconds for up to 60 polls (30 minute budget) and:

* breaks out and writes `status: provisioned` on `AVAILABLE`;
* fails fast with `STATUS: error mwaa_environment_unhealthy state=<state>` and writes `status: failed` on a terminal-failure state (`CREATE_FAILED`, `UPDATE_FAILED`, `DELETING`, `DELETED`);
* fails with `STATUS: error mwaa_wait_available_timeout state=<state> polls=60` if the budget elapses without reaching `AVAILABLE`.

In dry-run the poll loop is **skipped entirely** so a dry-run never blocks for tens of minutes.

## Post-migration safety (Requirement 20.31)

Re-running `bash seed/mwaa/create.sh --apply` after the Migration_Tool has run:

* issues **zero** `aws datazone create-*` commands;
* issues **zero** AWS CLI commands targeting the SMUS_Domain ID or Admin_Project ID recorded in `./config/migration.config.json` — the module reads neither of those identifiers;
* leaves the seed MWAA environment untouched (it is already `AVAILABLE` and the get-environment check returns `0`).

The same-account contract from Requirement 20.28 is enforced by `sbx_assert_same_account` at the top of both `create.sh` and `teardown.sh`: when `./config/migration.config.json` exists and its `source_account_id` differs from `./seed/seed.config.json`, both scripts halt before any state-changing AWS CLI command.

## DAG inventory mapped to Step 3 / Step 8 verdicts

| File | Verdict (Step 8) | Operators | Step 3 path |
| --- | --- | --- | --- |
| `dags/convertible_dag.py` | **Convertible** | `S3KeySensor`, `GlueJobOperator`, TaskFlow `@task` | references the seed Glue ETL job and the seed sample-data S3 bucket |
| `dags/blocked_dag.py` | **Blocked** | `BashOperator` (Non_AWS_Operator), `GlueJobOperator`, TaskFlow `@task` | n/a — Blocked DAGs are not converted |
| `dags/glue_refs_dag.py` | **Convertible** *(also exercises Step 3)* | `GlueJobOperator` (×2), TaskFlow `@task` | passes JDBC, KAFKA, and NETWORK Glue connection names to the jobs via `script_args`; Step 3 rewrites those names to the registered SMUS_Connection names from the Connection_Mapping_File |

The DAG IDs (`<prefix>_convertible`, `<prefix>_blocked`, `<prefix>_glue_refs`) are seeded from `SBX_SEED_NAME_PREFIX` at DAG-parse time so multiple seed prefixes deployed to a single MWAA environment do not collide on `dag_id`.

## Usage

```bash
# Dry-run (default): print the plan; no AWS state changes.
bash seed/mwaa/create.sh --dry-run

# Apply: pre-flight + create bucket + upload DAGs + create environment +
# wait up to 30 minutes for AVAILABLE.
SBX_MWAA_EXECUTION_ROLE_ARN=arn:aws:iam::123456789012:role/smus-mig-seed-mwaa-exec \
SBX_MWAA_SUBNET_IDS=subnet-aaa,subnet-bbb \
SBX_MWAA_SECURITY_GROUP_IDS=sg-aaa \
bash seed/mwaa/create.sh --apply

# Teardown (apply): delete environment + s3 rb --force the DAG bucket.
bash seed/mwaa/teardown.sh --apply
```

`seed/provision.sh` invokes `bash seed/mwaa/create.sh --apply` (or `--dry-run`) as the **last** step of its canonical sequence (Requirement 20.7). The orchestrator's same-account check, log file path (`SBX_LOG_PATH`), and prefix gating (`SBX_SEED_NAME_PREFIX`) are inherited as exported environment variables, so this module never re-prompts for any of them.
