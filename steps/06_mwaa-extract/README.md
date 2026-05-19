# Step 06 — MWAA Extract (DAGs, plugins, requirements)

> Validates: Requirements 5.3, 5.4, 6.3

## 1. Purpose

Step 6 reads the source `MWAA_Environment` named in the Config_File, recovers
its source S3 bucket plus the `DagS3Path`, optional `PluginsS3Path`, and
optional `RequirementsS3Path`, and syncs those artifacts out of the MWAA
source bucket into this step's `outputs/` folder. In apply mode the step
additionally mirrors `outputs/dags/` into the configured code repository
working tree at `data-pipelines/workflows/dags/`, copies `plugins.zip` and
`requirements.txt` next to it when present, and commits the result. The push
to the remote is intentionally deferred to Step 9 so credential-bound
operations are concentrated in the CI/CD step. A "nothing to commit" outcome
on re-runs against an unchanged DAG tree is tolerated as a successful no-op.

The step is the discovery half of the MWAA migration pair: Step 7
(`07_mwaa-integrate`) consumes `outputs/dags/` to render `manifest.yaml` for
`aws-smus-cicd deploy`, and Step 9 (`09_cicd`) re-uses the same DAG tree
under `data-pipelines/workflows/dags/` when it aggregates the CI/CD
manifest. Step 5 (`05_s3-data`) runs immediately before this step and uses
`MT_MWAA_DAG_BUCKET_NAME` to exclude the same bucket from the data-bucket
sync — DAG code is migrated as code by this step, not as data by Step 5.

## 2. Prerequisites

- Step 1 has completed and persisted `smus_domain_id`, `admin_project_id`,
  and `git_connection_id` to the Config_File. Step 6 itself does not read
  those values, but its apply-mode commit lands inside the working tree
  Step 1 wired up to the configured code repository.
- The local AWS CLI is configured for the source AWS account and the
  invoking principal carries the IAM permissions
  `mwaa:GetEnvironment` against the target `MWAA_Environment` and
  `s3:ListBucket` / `s3:GetObject` on the MWAA source bucket discovered
  via `Environment.SourceBucketArn`.
- `jq` is on `PATH`. The step parses the JSON returned by
  `aws mwaa get-environment` with `jq` and exits 64 with a
  `STATUS: error missing required tool: jq` line if it is absent.
- For apply-mode commits, `MT_WORKDIR` points at a checked-out clone of the
  configured code repository (i.e., `${MT_WORKDIR}/.git` exists). When the
  `.git` directory is absent the step skips the commit phase silently and
  still completes the sync; it is not this step's job to `git init` a
  repository on the operator's behalf.

## 3. Configuration keys consumed

The Orchestrator forwards each Config_File value listed below as an `MT_*`
environment variable before invoking `run.sh`. The step also reads the
standard `MT_WORKDIR` set by the Orchestrator for the code-repository
mirror phase.

| Key                       | Required | Notes                                                                                                         |
|---------------------------|----------|---------------------------------------------------------------------------------------------------------------|
| `aws_region`              | always   | Region passed to `aws mwaa get-environment`, `aws s3 sync`, and `aws s3 cp`.                                  |
| `mwaa_environment_name`   | always   | Name of the source `MWAA_Environment` passed to `aws mwaa get-environment --name`.                            |

`MT_MWAA_DAG_BUCKET_NAME` is not read by this step — Step 5 owns the DAG
bucket exclusion. Step 6 instead resolves the bucket dynamically from
`Environment.SourceBucketArn` returned by `aws mwaa get-environment`.

## 4. AWS CLI commands issued

The step issues exactly the following AWS CLI invocations, in this order.
Each invocation flows through `mt_aws` (apply mode) or its `DRY-RUN: aws ...`
echo (dry-run mode) provided by `steps/_lib/common.sh`; neither helper ever
calls `boto3` or any Python AWS SDK.

1. `aws mwaa get-environment --name <mwaa_environment_name> --region <aws_region>` —
   describe the source MWAA environment. The step parses the JSON payload
   with `jq` to extract `Environment.SourceBucketArn` (the MWAA source
   bucket; the well-known `arn:aws:s3:::` prefix is stripped to recover
   the bare bucket name), `Environment.DagS3Path` (always required;
   missing values cause the step to halt), and the optional
   `Environment.PluginsS3Path` and `Environment.RequirementsS3Path`.
2. `aws s3 sync s3://<source_bucket>/<dag_s3_path> outputs/dags/ --region <aws_region>` —
   sync the DAG folder into the step's `outputs/dags/` directory. The
   `aws s3 sync` semantics ensure re-runs only transfer changed objects.
3. `aws s3 cp s3://<source_bucket>/<plugins_s3_path> outputs/plugins.zip --region <aws_region>` —
   download the plugins archive **only when** `Environment.PluginsS3Path`
   is non-null and non-empty. Skipped silently when MWAA reports no
   plugins archive.
4. `aws s3 cp s3://<source_bucket>/<requirements_s3_path> outputs/requirements.txt --region <aws_region>` —
   download the requirements file **only when**
   `Environment.RequirementsS3Path` is non-null and non-empty. Skipped
   silently when MWAA reports no requirements file.

## 5. Artifacts produced

| Path                                                        | When produced                                                | Contents                                                                                                                       |
|-------------------------------------------------------------|--------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------|
| `steps/06_mwaa-extract/outputs/dags/`                       | Always (apply mode); empty in dry-run.                       | Mirror of `s3://<source_bucket>/<dag_s3_path>` produced by `aws s3 sync`. Includes any `.airflowignore` and DAG subdirectories. |
| `steps/06_mwaa-extract/outputs/plugins.zip`                 | Apply mode, only when `Environment.PluginsS3Path` is present. | Verbatim copy of the MWAA plugins archive.                                                                                      |
| `steps/06_mwaa-extract/outputs/requirements.txt`            | Apply mode, only when `Environment.RequirementsS3Path` is present. | Verbatim copy of the MWAA requirements file.                                                                                    |
| `steps/06_mwaa-extract/outputs/run.log`                     | Always.                                                      | Tee of every `mt_aws` invocation (apply) or `DRY-RUN: aws ...` line (dry-run) plus `STATUS:` and `mt_log` lines.                |

In apply mode and when `${MT_WORKDIR}/.git` exists, the step additionally
writes the following paths inside the configured code repository working
tree (see section 6 for the convention):

- `${MT_WORKDIR}/data-pipelines/workflows/dags/` — mirror of `outputs/dags/`.
- `${MT_WORKDIR}/data-pipelines/workflows/plugins.zip` — present only when
  `outputs/plugins.zip` was produced.
- `${MT_WORKDIR}/data-pipelines/workflows/requirements.txt` — present only
  when `outputs/requirements.txt` was produced.

## 6. Branch and path conventions

In apply mode and when `${MT_WORKDIR}/.git` exists, the step performs
exactly the following filesystem and git actions, in order, on the
operator's currently checked-out branch:

1. `mkdir -p ${MT_WORKDIR}/data-pipelines/workflows/dags/` —
   ensure the target directory tree exists.
2. `cp -a ${MT_WORKDIR}/steps/06_mwaa-extract/outputs/dags/. ${MT_WORKDIR}/data-pipelines/workflows/dags/` —
   copy the **contents** of `outputs/dags/` (the trailing `/.` form) into
   the repo's `dags/` directory, preserving dotfiles such as
   `.airflowignore` and subdirectories.
3. `cp -a outputs/plugins.zip ${MT_WORKDIR}/data-pipelines/workflows/plugins.zip` —
   only when `outputs/plugins.zip` exists.
4. `cp -a outputs/requirements.txt ${MT_WORKDIR}/data-pipelines/workflows/requirements.txt` —
   only when `outputs/requirements.txt` exists.
5. `git -C ${MT_WORKDIR} add data-pipelines/workflows/dags/` —
   stage the mirrored DAG tree (and, transitively via the parent path, any
   sibling `plugins.zip` / `requirements.txt` already copied in steps 3
   and 4 when they live under the same staging set in subsequent re-runs).
6. `git -C ${MT_WORKDIR} commit -m "Step 6: extract MWAA DAGs from <mwaa_environment_name>"` —
   commit the staged changes. A non-zero exit from `git commit` carrying
   the literal "nothing to commit" condition is **tolerated as a
   successful no-op** so re-runs against an unchanged DAG tree still
   complete cleanly. No other non-zero `git commit` outcome is suppressed.

The push to the remote is intentionally deferred to Step 9
(`09_cicd`), where credential-bound operations are concentrated. This
step never invokes `git push`, never creates branches, and never creates
tags. The branch the commit lands on is whatever branch
`${MT_WORKDIR}` currently has checked out — typically `main` for a
fresh clone, or the migration working branch the operator created
manually when staging earlier migration steps.

When `${MT_WORKDIR}/.git` is **absent** (the operator pointed `MT_WORKDIR`
at a non-repo location, or has not yet cloned the configured code
repository), the step silently skips the commit phase and still completes
the sync. The step never runs `git init` on the operator's behalf.

## 7. Dry-run vs apply behavior

| Mode              | Behavior                                                                                                                                                                                                                                                                                                                                                                                                                                       |
|-------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Dry-run (default) | Prints every would-be `aws ...` invocation from section 4 prefixed with `DRY-RUN: ` and **never** calls AWS. Because `aws mwaa get-environment` is not actually executed, the step substitutes documented placeholders (`SOURCE_BUCKET=<mwaa-source-bucket>`, `DAG_PATH=<dag-s3-path>`) so the would-be `aws s3 sync` and `aws s3 cp` lines are still rendered for review. No artifacts are written. The git mirror and `git commit` phases are also rendered as `DRY-RUN: ...` echoes. |
| Apply (`--apply`) | Issues the section 4 commands against AWS in order. Writes `outputs/dags/`, and optionally `outputs/plugins.zip` and `outputs/requirements.txt`. When `${MT_WORKDIR}/.git` exists, mirrors the artifacts into `${MT_WORKDIR}/data-pipelines/workflows/` and runs `git add` + `git commit` per section 6. "Nothing to commit" is tolerated. The push is deferred to Step 9.                                                                                                            |

The step emits `STATUS: started` on entry, `STATUS: action git add data-pipelines/workflows/dags/` and `STATUS: action git commit` around the commit phase (apply mode only), and `STATUS: ok` on success. Missing required env vars produce `STATUS: missing_var <NAME>` and exit 64; a missing `jq` produces `STATUS: error missing required tool: jq` and exit 64; a malformed `aws mwaa get-environment` payload (missing `SourceBucketArn` or `DagS3Path`) produces `STATUS: error aws mwaa get-environment response missing SourceBucketArn or DagS3Path` and exit 1.

## 8. Citations

The following AWS documentation URLs are MCP-cached: each URL has been
fetched through the AWS Documentation MCP server (`AWS_Docs_MCP`) and
cached under `./docs/cache/<sha256(url)[:16]>.json`, so a future
regeneration of this README is a cache hit and does not re-fetch the
source.

- AWS_Docs_MCP: [Adding or updating DAGs (Configuring the DAG folder for an Amazon MWAA environment)](https://docs.aws.amazon.com/mwaa/latest/userguide/configuring-dag-folder.html)
  — canonical source for the contract that an MWAA environment's DAG
  folder is an S3 prefix on the environment's source bucket. The
  `aws s3 sync` invocation in section 4 is the recommended pattern for
  pulling that prefix off MWAA, and the same prefix is re-used as the
  layout for `data-pipelines/workflows/dags/` per section 6.
- AWS_Docs_MCP: [GetEnvironment — Amazon Managed Workflows for Apache Airflow API Reference](https://docs.aws.amazon.com/mwaa/latest/API/API_GetEnvironment.html)
  — canonical source for the response shape that the step parses with
  `jq`: `Environment.SourceBucketArn` (the bucket that holds DAGs,
  plugins, and requirements), `Environment.DagS3Path` (required;
  resolved to the S3 prefix `aws s3 sync` reads), and the optional
  `Environment.PluginsS3Path` / `Environment.RequirementsS3Path`
  (resolved to the optional `aws s3 cp` downloads).

The matching Reference_Document section is **"4. Best Path to Bring
Existing Datasets, Glue Jobs, and ML Assets"** in
`SageMaker Unified Studio - Migration Answers.md`. That section is the
source of truth for the principle that running workloads — including
Apache Airflow DAGs running on MWAA — are migrated as code via the
configured code repository rather than as service-to-service data
movement. Its "Method 2: Via GitHub Migration Scripts" sub-section
specifically frames DAG and Glue script onboarding as a Git-checked-in
artifact flow, which is exactly the contract this step encodes when it
mirrors `outputs/dags/` into `data-pipelines/workflows/dags/` for the
configured code repository to track.
