# Step 7 — MWAA Integrate (`07_mwaa-integrate`)

## 1. Purpose

Step 7 generates an `aws-smus-cicd` deployment manifest covering every Apache
Airflow DAG that Step 6 extracted from the source MWAA_Environment, and (in
apply mode) deploys those DAGs to the `admin` stage on the SMUS Admin_Project
of the SMUS_Domain that Step 1 created.

The manifest is the durable artifact: one `mwaa-workflow` resource entry per
`*.py` file under `steps/06_mwaa-extract/outputs/dags/`, plus one `admin`
stage block that names the resolved Admin_Project ID, SMUS_Domain ID, and
source AWS account ID. The deploy itself is a subprocess call to the
third-party `aws-smus-cicd` CLI per Requirement 19.4 — the orchestrator never
imports the CLI as a Python library.

## 2. Prerequisites

1. **Step 6 has completed.** The directory `steps/06_mwaa-extract/outputs/dags/`
   must exist and contain at least one `*.py` file. An empty or missing
   directory triggers the halting precondition in section 7 below.
2. **`aws-smus-cicd-cli` is installed locally** (apply mode only). Install
   with `pip install aws-smus-cicd-cli`. If the CLI is not on `PATH` when the
   step runs in apply mode, the step logs a warning and skips the deploy
   without failing — see section 8.
3. **Step 1 has completed.** Step 1 populates `smus_domain_id` and
   `admin_project_id` in the Config_File; without those values the step
   cannot resolve the `admin` stage block and exits via `mt_require_var`.

## 3. Configuration keys consumed

The step reads the following keys from `config/migration.config.json` (passed
to `run.sh` as `MT_*` environment variables by the orchestrator):

| Config key             | Env var               | Source / purpose                                                  |
|------------------------|-----------------------|-------------------------------------------------------------------|
| `smus_domain_id`       | `MT_SMUS_DOMAIN_ID`   | Filled by Step 1; written into the `admin` stage's `domain_id`.   |
| `admin_project_id`     | `MT_ADMIN_PROJECT_ID` | Filled by Step 1; written into the `admin` stage's `project_id`.  |
| `source_account_id`    | `MT_SOURCE_ACCOUNT_ID`| Collected during interactive configuration (Requirement 2.1).     |

If any of these is missing or empty when the step starts, `mt_require_var`
exits 64 with `STATUS: missing_var <NAME>` so the orchestrator can prompt the
operator and persist the value before re-running.

## 4. AWS CLI commands issued

Step 7 issues **no AWS CLI commands directly**. Every AWS API interaction is
performed inside the third-party `aws-smus-cicd` CLI, which is invoked as a
subprocess in apply mode:

```
aws-smus-cicd deploy --manifest <outputs/manifest.yaml> --stage admin
```

This discipline keeps the per-step `aws ...` surface auditable in plain bash
for steps that talk to AWS directly (Steps 1, 3, 4, 4b, 5, 6) and keeps the
SMUS-specific deployment logic encapsulated in the AWS-published CLI for
Step 7 (Requirements 14.3, 19.4).

## 5. Artifacts produced

All artifacts are written under `steps/07_mwaa-integrate/outputs/`:

| Path             | Mode(s)        | Contents                                                                                  |
|------------------|----------------|-------------------------------------------------------------------------------------------|
| `manifest.yaml`  | dry-run, apply | Hand-rolled YAML manifest (see section 6) — one entry per DAG plus the `admin` stage.     |
| `deploy.log`     | apply          | Combined stdout+stderr from `aws-smus-cicd deploy`, or a skip-record if the CLI is absent.|
| `run.log`        | dry-run, apply | Step-local tee of the bash script's stdout/stderr (written by `mt_init` in `common.sh`).  |

The manifest is written in **both** dry-run and apply mode so the operator
can review the would-be deploy input before re-running with `--apply`. This
mirrors Step 2's portability-report discipline and stays inside the tool's
working directory per Requirement 1.2.

## 6. Manifest schema

The generated `outputs/manifest.yaml` has the following deterministic shape.
DAG entries are sorted with `LC_ALL=C sort` so re-runs produce identical
diffs:

```yaml
application:
  name: migration-tool-workflows
  resources:
    - type: mwaa-workflow
      name: <dag-basename-without-.py>
      dag_path: data-pipelines/workflows/dags/<dag-basename>.py
    - type: mwaa-workflow
      name: <next-dag>
      dag_path: data-pipelines/workflows/dags/<next-dag>.py
    # ... one entry per *.py file under steps/06_mwaa-extract/outputs/dags/
stages:
  - name: admin
    project_id: <MT_ADMIN_PROJECT_ID>
    domain_id: <MT_SMUS_DOMAIN_ID>
    config:
      source_account_id: <MT_SOURCE_ACCOUNT_ID>
```

Notes on the schema:

- `application.name` is hard-coded to `migration-tool-workflows`. The
  manifest's `name` is a logical grouping label inside `aws-smus-cicd` and is
  not consumed by any other step.
- Every `resources[*]` entry uses `type: mwaa-workflow`; Step 7 covers MWAA
  DAG deployment only. Other resource types (`glue-etl`, `quicksight-dashboard`,
  etc.) are emitted by Step 9's aggregated CI/CD manifest, not here.
- `dag_path` points at `data-pipelines/workflows/dags/<basename>.py` because
  Step 6 commits the DAGs to that exact subtree of the configured code
  repository (Requirement 13.5).
- The `stages` list contains exactly one entry, `admin`. Multi-stage rollouts
  (`dev`, `test`, `prod`) are Step 9's responsibility, not Step 7's.

## 7. Halting precondition

Before doing anything else, `run.sh` checks the Step 6 DAG output directory:

- If `steps/06_mwaa-extract/outputs/dags/` does not exist, the script emits
  `STATUS: error Step 6 must complete first` and exits 1.
- If the directory exists but contains zero `*.py` files (counted with
  `find ... -maxdepth 1 -type f -name '*.py'`), the script emits the same
  status line and exits 1.

Both cases are treated as "Step 6 did not run" (Requirement 14.4). The
operator's recovery path is to run Step 6 (dry-run first, then apply) and
re-run Step 7.

## 8. Dry-run vs apply

**Dry-run (default).** The step writes `outputs/manifest.yaml` and prints the
would-be deploy command via `mt_dryrun`:

```
DRY-RUN: aws-smus-cicd deploy --manifest <outputs/manifest.yaml> --stage admin
```

No subprocess to `aws-smus-cicd` is started. `outputs/deploy.log` is not
written.

**Apply.** The step writes `outputs/manifest.yaml`, emits
`STATUS: action aws-smus-cicd deploy --stage admin` so the orchestrator
records the action against the step, then:

- If `aws-smus-cicd` is on `PATH`, invokes
  `aws-smus-cicd deploy --manifest <outputs/manifest.yaml> --stage admin` and
  redirects combined stdout+stderr to `outputs/deploy.log`. A non-zero exit
  from the CLI fails the step (`set -o pipefail` is active).
- If `aws-smus-cicd` is **not** on `PATH`, the step logs a warning naming the
  install command (`pip install aws-smus-cicd-cli`), writes a skip-record to
  `outputs/deploy.log` describing the would-be command, and **exits 0
  without failing the step**. The manifest is the primary deliverable and is
  already on disk; the deploy can be re-run by re-invoking Step 7 with
  `--apply` after installing the CLI.

This skip-on-missing-CLI behavior matches the design's stance on third-party
tooling: the manifest is reproducible from `outputs/manifest.yaml` alone, so
a missing operator-side CLI is a soft warning, not a hard failure.

## 9. Citations

This step's approach is grounded in the following sources (Requirements 5.4,
6.1, 6.3). The `aws-smus-cicd` CLI and its `manifest.yaml` schema are
documented at:

- AWS Documentation MCP-cached URL —
  [CI/CD for Amazon SageMaker Unified Studio (User Guide)](https://docs.aws.amazon.com/sagemaker-unified-studio/latest/userguide/cicd.html)
- Open-source CLI repository —
  [aws/CICD-for-SageMakerUnifiedStudio](https://github.com/aws/CICD-for-SageMakerUnifiedStudio)
- Reference_Document — `SageMaker Unified Studio - Migration Answers.md`,
  section **3. CI/CD Approach for Unified Studio Projects** (the canonical
  source for the manifest's `application.resources[*]` and `stages[*]` shape
  used in section 6 above).

The MCP-cached copy of the AWS doc URL is stored under `docs/cache/` keyed by
`sha256(url)[:16]` per `migration_tool/mcp_docs.py`, so subsequent scaffold
runs of this README do not re-fetch the upstream content (Requirement 6.2).

---

**Validates: Requirements 5.3, 5.4, 6.3.**
