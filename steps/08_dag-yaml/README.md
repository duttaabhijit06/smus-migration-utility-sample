# Step 08 — Optional DAG → YAML conversion for MWAA Serverless

> Validates: Requirements 5.3, 5.4, 6.3 (and implements 15.1–15.7, 19.4)

## 1. Purpose

Step 8 is an optional, gated post-process that runs after Step 7 (`07_mwaa-integrate`)
has succeeded. It AST-parses every DAG that Step 6 (`06_mwaa-extract`) committed
under `steps/06_mwaa-extract/outputs/dags/`, enumerates each DAG's operator class
names, and cross-checks them against an embedded allowlist of AWS-provider Apache
Airflow operators. Each DAG receives a deterministic verdict:

- `Convertible` — every operator the DAG references is in the AWS-provider
  allowlist; the step then invokes `python-to-yaml-dag-converter` (from the
  `python-to-yaml-dag-converter-mwaa-serverless` package) as a subprocess to
  emit a `<dag>.yaml` workflow definition under `outputs/yaml/`.
- `Blocked` — the DAG references at least one Non_AWS_Operator (an operator
  outside the allowlist), or the DAG references no operators at all (a
  malformed or trivial DAG cannot be safely converted). No YAML is emitted
  for `Blocked` DAGs.

The outputs land in two artifacts: `outputs/compatibility-report.md` (always)
and `outputs/yaml/<dag>.yaml` (one per `Convertible` DAG). Step 8 does not
re-run the converted workflows; deployment is the responsibility of Step 7
(`aws-smus-cicd deploy`) once the YAML files have been committed to the
configured code repository.

## 2. Gating flag

Step 8 is **off by default**. The orchestrator only invokes
`steps/08_dag-yaml/run.sh` when the user passes `--convert-dags` to the CLI;
otherwise the step is excluded from the resolved step range entirely.

The script also defends against accidental manual invocation by no-op-ing on
an empty Step 6 inventory: when `steps/06_mwaa-extract/outputs/dags/` does not
exist, or contains zero `*.py` files, the script logs `no DAG files to
convert; skipping`, emits `STATUS: ok`, and exits 0. This makes a `bash
run.sh` invocation safe on a fresh tree where Step 6 has not run yet.

## 3. Allowlist scope

The compatibility verdict for each DAG is computed against a fixed,
case-sensitive allowlist of AWS-provider operator class names baked into
`run.sh`. The allowlist groups by AWS service:

| AWS service | Allowlisted operator class names |
|---|---|
| AWS Glue | `GlueJobOperator`, `GlueCatalogPartitionSensor` |
| AWS Lambda | `LambdaInvokeFunctionOperator`, `LambdaCreateFunctionOperator` |
| Amazon S3 | `S3KeySensor`, `S3DeleteObjectsOperator`, `S3CreateBucketOperator` |
| Amazon SNS | `SnsPublishOperator` |
| Amazon Athena | `AthenaOperator` |
| Amazon EMR | `EmrCreateJobFlowOperator`, `EmrAddStepsOperator`, `EmrTerminateJobFlowOperator`, `EmrStepSensor`, `EmrServerlessStartJobOperator` |
| Amazon Redshift | `RedshiftSQLOperator`, `RedshiftDataOperator`, `RedshiftClusterSensor` |
| Amazon ECS | `EcsRunTaskOperator` |
| AWS Batch | `BatchOperator`, `BatchSensor` |
| Amazon SageMaker | `SageMakerProcessingOperator`, `SageMakerTrainingOperator`, `SageMakerEndpointOperator`, `SageMakerTransformOperator` |
| AWS Step Functions | `StepFunctionStartExecutionOperator` |
| Amazon Kinesis Data Analytics | `KinesisAnalyticsCreateApplicationOperator`, `KinesisAnalyticsStartApplicationOperator`, `KinesisAnalyticsStopApplicationOperator` |

The class-name match is exact and case-sensitive. The AST scan walks every
`ast.Call` in the DAG and treats the call's bare class name (whether referenced
as `ast.Name` or as the trailing `attr` of an `ast.Attribute`) as the operator
name; this captures both `from airflow.providers.amazon.aws.operators.glue
import GlueJobOperator` and fully qualified `aws.operators.glue.GlueJobOperator`
references without depending on the `from ... import ...` alias chain. Any
identifier whose suffix is `Operator` or `Sensor` and whose exact class name
is not in the table above marks the DAG as `Blocked`.

## 4. Configuration keys consumed

None. Step 8 reads no values from `config/migration.config.json`. The only
inputs are the `--apply` and `--dry-run` flags processed by
`steps/_lib/common.sh`, plus the `MT_WORKDIR` environment variable that the
orchestrator sets to the tool's working directory. The DAG inventory is
discovered on the filesystem under `steps/06_mwaa-extract/outputs/dags/`.

## 5. AWS CLI commands issued

None. Step 8 makes no AWS API calls in either dry-run or apply mode; the AST
scan, the verdict computation, the report rendering, and the YAML emission
are all local operations.

The step does invoke one external subprocess: `python-to-yaml-dag-converter`
(from the `python-to-yaml-dag-converter-mwaa-serverless` package). The
subprocess is called once per `Convertible` DAG with the form:

```
python-to-yaml-dag-converter <dag.py> --output outputs/yaml/
```

When the converter binary is not present on `PATH`, the step logs a warning
and skips YAML emission for the affected DAG; the DAG remains `Convertible`
in the report (the verdict is a property of the DAG, not the local toolchain).

The orchestrator's "no Python AWS SDK" rule (Requirement 19.4) is satisfied
because the converter is invoked as a subprocess and never imported into the
orchestrator's control flow.

## 6. Artifacts produced

| Path | Contents |
|---|---|
| `steps/08_dag-yaml/outputs/compatibility-report.md` | Markdown report with one row per scanned DAG and a summary line; always written. |
| `steps/08_dag-yaml/outputs/yaml/<dag-name>.yaml` | MWAA Serverless YAML workflow definition emitted by `python-to-yaml-dag-converter`. One file per `Convertible` DAG, in apply mode only when the converter is available. |
| `steps/08_dag-yaml/outputs/run.log` | Tee of the step's stdout and stderr (the standard step-local log written by every `run.sh` via the shared library). |

The compatibility report is overwritten on every run; its contents are
deterministic for a given DAG inventory because the scan walks the DAG files
in `LC_ALL=C`-sorted order and the verdict computation is pure.

## 7. Report layout

The generated `compatibility-report.md` contains exactly one H1 heading, one
markdown table, and one summary line.

The table columns are fixed:

| Column | Allowed values | Meaning |
|---|---|---|
| `DAG file` | The DAG's basename (e.g., `etl_pipeline.py`) | The file under `steps/06_mwaa-extract/outputs/dags/` that was scanned. |
| `Operators` | A comma-separated list of operator class names, sorted ascending; or `(none)` when no operator-shaped calls were found. | The operator class names the AST scan extracted from the DAG. |
| `Verdict` | `Convertible`; or `Blocked (no operators detected)`; or `Blocked (non-AWS-provider: <comma-separated offenders>)` | The conversion verdict. |

The summary line follows the table and has the exact shape:

```
**Summary:** Convertible: N, Blocked: N, Total operators: N
```

`Convertible` and `Blocked` are the per-DAG verdict counts (they sum to the
DAG file count). `Total operators` is the running total of every operator-shaped
call across every DAG, including operators contributed by `Blocked` DAGs, so
the number reflects the full operator surface area of the MWAA inventory and
not just the convertible portion.

## 8. Apply-mode commit

In apply mode (`--apply`), and only when both of the following hold, the step
copies the produced YAMLs into the working tree and creates a git commit
(satisfying Requirement 15.6):

- At least one YAML file landed in `outputs/yaml/` during this run, and
- A working git tree exists at `${MT_WORKDIR}/.git`.

The commit sequence is:

1. `mkdir -p ${MT_WORKDIR}/data-pipelines/workflows/yaml`.
2. `cp outputs/yaml/*.yaml ${MT_WORKDIR}/data-pipelines/workflows/yaml/`.
3. `git -C ${MT_WORKDIR} add data-pipelines/workflows/yaml/`.
4. `git -C ${MT_WORKDIR} commit -m "Step 8: convert AWS-only DAGs to MWAA Serverless YAML"`.

A `git commit` exit whose stderr contains `nothing to commit` or `no changes
added to commit` is treated as a successful idempotent re-run (the destination
already mirrors `outputs/yaml/`); any other non-zero `git commit` exit causes
the step to fail with `STATUS: error git commit failed`.

When YAML files were produced but `${MT_WORKDIR}/.git` is absent, the step
logs `produced N YAML file(s) but ${MT_WORKDIR}/.git is absent; skipping
commit` and exits 0. The Migration_Tool does not initialise a git repository
on the user's behalf; that is delegated to whichever earlier step or pre-run
provisioning the operator chose.

## 9. Dry-run vs apply behavior

| Mode | Behavior |
|---|---|
| Dry-run (default) | AST-parses every DAG, computes verdicts, writes `outputs/compatibility-report.md`. For each `Convertible` DAG, prints the would-be converter command line as `DRY-RUN: python-to-yaml-dag-converter "<dag>" --output "<outputs/yaml>"` and **does not** invoke the converter, so no YAML files are written. No git commit is attempted. |
| Apply (`--apply`) | AST-parses every DAG, computes verdicts, writes `outputs/compatibility-report.md`. For each `Convertible` DAG, invokes `python-to-yaml-dag-converter` as a subprocess (when on `PATH`) to produce `outputs/yaml/<dag>.yaml`. When at least one YAML file is produced and `${MT_WORKDIR}/.git` exists, copies the YAMLs into `data-pipelines/workflows/yaml/` and runs `git add` + `git commit` per section 8. |

The step emits `STATUS: started` on entry, `STATUS: action scan <dag>` per
DAG scan, `STATUS: action convert <dag>` per converter invocation in apply
mode (or a `DRY-RUN: ...` line per `Convertible` DAG in dry-run mode),
`STATUS: action git add ...` and `STATUS: action git commit` on the apply-mode
commit branch, and `STATUS: ok` on success.

## 10. Citations

The following AWS documentation URL is MCP-cached: it has been fetched through
the AWS Documentation MCP server (`AWS_Docs_MCP`) and cached under
`./docs/cache/<sha256(url)[:16]>.json`, so a future regeneration of this README
is a cache hit and does not re-fetch the source.

- [Migrate Apache Airflow Python DAGs to MWAA Serverless YAML workflow definitions](https://docs.aws.amazon.com/mwaa/latest/mwaa-serverless-userguide/workflows-migrate.html)
  — MCP-cached; canonical source for the `python-to-yaml-dag-converter` CLI
  shape (`python-to-yaml-dag-converter <dag.py> --output <dir>`), for the set
  of AWS-provider operators that MWAA Serverless YAML workflows currently
  support, and for the "convertible vs blocked" distinction this step encodes
  in `outputs/compatibility-report.md`.

The matching Reference_Document section is **"5. Structuring Workflows in
Unified Studio (YAML, DAG Design, Concurrency)"** in `SageMaker Unified
Studio - Migration Answers.md`. That section is the canonical narrative for
how MWAA Serverless YAML workflows fit into a SageMaker Unified Studio
project, what operator surface YAML workflows can express today, and why a
Python-AST allowlist check is the correct gate for a one-shot conversion of
an existing MWAA (provisioned) DAG inventory: DAGs whose operators are all
AWS-provider operators are mechanically convertible, and DAGs that touch
Non_AWS_Operators are kept on the Step 7 provisioned-MWAA path rather than
forced into a partial YAML translation that would silently lose operator
behavior.
