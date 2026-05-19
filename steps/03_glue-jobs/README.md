# Step 3 — Glue jobs to notebooks (with rewritten connection references)

> Validates: Requirements 5.3, 5.4, 6.3.

## 1. Purpose

Step 3 lists every AWS Glue job in the source AWS account, downloads the
script body for each job from its S3 `ScriptLocation`, generates a Jupyter
notebook for every `glueetl` and `pythonshell` job, and rewrites the
`Glue_Connection` references inside each produced `.py` script and `.ipynb`
notebook so the references resolve against the SMUS_Connection registered by
Step 4b. The rewrite is driven by the Connection_Mapping_File at
`./steps/04b_glue-connections/outputs/connection-mapping.json`.

The step's outputs are committed (in apply mode) under
`data-pipelines/glue-jobs/` on the configured code repository so the migrated
scripts and notebooks travel with the rest of the migration artifacts and so
later runs of `aws-smus-cicd-cli` can deploy them as Glue ETL resources inside
the SMUS_Domain. Dry-run mode produces every output under `outputs/` but never
calls AWS or touches the repo working tree.

## 2. Prerequisites

- The source AWS account credential resolved by the local AWS CLI grants
  `glue:GetJobs` on the source account and `s3:GetObject` on every Glue job's
  `ScriptLocation` S3 path. Without `glue:GetJobs` the step halts on the
  first command; without `s3:GetObject` for a given job the step records a
  per-job error and continues (see section 9).
- Step 4b has already run. When the Connection_Mapping_File at
  `./steps/04b_glue-connections/outputs/connection-mapping.json` is present,
  the rewrite path produces the SMUS_Connection-aware scripts and notebooks
  Step 9 needs. When the Connection_Mapping_File is absent the connection
  rewrite path is a no-op and a warning row is emitted to
  `outputs/errors.json` instructing the operator to run Step 4b and re-run
  Step 3 (Requirement 9.5; see section 7).
- The local AWS CLI is configured for the target account: `aws sts
  get-caller-identity` succeeds and returns the same `Account` value as
  `source_account_id` in the Config_File.

## 3. Configuration keys consumed

The Orchestrator forwards every Config_File value listed below as an `MT_*`
environment variable before invoking `run.sh`. Step 3 deliberately consumes a
single key — the AWS region — because the Glue job inventory and the script
downloads are fully discovered at runtime; nothing else needs to be prompted
or persisted by this step.

| Key          | Required for | Notes                                                                                                    |
|--------------|--------------|----------------------------------------------------------------------------------------------------------|
| `aws_region` | always       | Target AWS region for `aws glue get-jobs`. The per-job `aws s3 cp` calls inherit the region from the URL. |

## 4. AWS CLI commands issued

The step issues exactly the following AWS CLI invocations. Each invocation
flows through `mt_aws` (apply mode) or is rendered as `DRY-RUN: aws ...` (dry-
run mode); neither path ever shells out to `boto3` or any Python AWS SDK.

1. `aws glue get-jobs --region <aws_region>` — list every Glue job in the
   source account. The full response is written to
   `outputs/glue-jobs.json`.
2. `aws s3 cp <Job.Command.ScriptLocation> outputs/scripts/<job-name>.py` —
   one invocation per Glue job, downloading the job's Python script body
   from its S3 `ScriptLocation`. The job name is the value of the Glue
   `Job.Name` field; non-filesystem-safe characters in the job name are
   left untouched because Glue job names already conform to the
   single-line-string pattern that AWS Glue enforces (see the Citations
   section).

No other AWS CLI calls are made by Step 3. Notebook generation and Glue
connection rewrite are local subprocess tools (section 5) and never call AWS.

## 5. Subprocess tools invoked

After the AWS CLI inventory and the script downloads, Step 3 invokes two
local Python subprocess tools. Both tools are part of the Migration_Tool
package and are stdlib-only per Requirement 19.4 (no `boto3`, no third-party
AWS SDK).

1. `python -m migration_tool.tools.notebook_gen` — invoked once per Glue job
   whose `Job.Command.Name` is `glueetl` or `pythonshell`. Reads
   `outputs/scripts/<job-name>.py` plus a small in-memory metadata document
   (job name, role, default arguments) and writes
   `outputs/notebooks/<job-name>.ipynb` and `outputs/notebooks/<job-name>.metadata.json`.
   The notebook holds one code cell with the script body and one raw cell
   with a YAML frontmatter block that lists the job's name, role, default
   arguments, and connection references (Requirement 9.3).
2. `python -m migration_tool.tools.connection_rewrite` — invoked once after
   every notebook has been generated. Reads the Connection_Mapping_File at
   `./steps/04b_glue-connections/outputs/connection-mapping.json` and rewrites
   every `Glue_Connection` name reference inside `outputs/scripts/*.py` and
   `outputs/notebooks/*.ipynb` to the registered `smus_connection_name` from
   the mapping; for notebooks the metadata cell is updated to record both
   the original Glue_Connection identifier and the SMUS_Connection identifier.
   The full consumer contract is documented in section 7.

Both subprocess tools always run, regardless of `--apply` or `--dry-run`,
because they only ever touch this step's `outputs/` folder; the dry-run vs
apply distinction is meaningful only for AWS calls and for repository
commits (section 8).

## 6. Artifacts produced

| Path                                                      | Contents                                                                                                                                                                                                                                              |
|-----------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `outputs/glue-jobs.json`                                  | Raw `aws glue get-jobs` response for the source account.                                                                                                                                                                                              |
| `outputs/scripts/<job-name>.py`                           | One file per Glue job, downloaded from `Job.Command.ScriptLocation`. Connection references inside each file are rewritten by `connection_rewrite` when the Connection_Mapping_File is present.                                                          |
| `outputs/notebooks/<job-name>.ipynb`                      | One Jupyter notebook per `glueetl`/`pythonshell` Glue job, produced by `notebook_gen`. Holds one code cell (script body) and one raw metadata cell (job name, role, default arguments, connection references).                                          |
| `outputs/notebooks/<job-name>.metadata.json`              | One JSON metadata document per generated notebook, written alongside the `.ipynb` so re-runs of `notebook_gen` are deterministic (Requirement 9.3).                                                                                                     |
| `outputs/errors.json`                                     | Per-item warning and failure records: jobs whose script could not be read (Requirement 9.7), plus the "Connection_Mapping_File missing" warning row emitted by `connection_rewrite` when Step 4b has not yet produced the mapping (Requirement 9.5). |
| `outputs/run.log`                                         | Full tee of the step's stdout and stderr opened by `mt_init` in apply mode.                                                                                                                                                                           |

## 7. Connection-mapping consumer contract

This section is the formal contract for how Step 3 consumes the
Connection_Mapping_File produced by Step 4b at
`./steps/04b_glue-connections/outputs/connection-mapping.json`.

**When the mapping file is present.** `connection_rewrite.py` loads every
entry whose `status` is `registered` and builds one substitution rule per
entry mapping `glue_connection_name` to the registered `smus_connection_name`
(carrying `smus_connection_id` for notebook bookkeeping). Each rule is a
word-boundary regex of the form `\bGLUE_CONN\b` so a Glue connection name
that appears as a substring inside an unrelated identifier is not touched.
The rules are applied to every `outputs/scripts/*.py` file and to every code
cell of every `outputs/notebooks/*.ipynb` file. For each notebook in which
at least one substitution fires, the notebook's `migration_tool_metadata`
raw cell is updated (or appended when missing) so its
`metadata.connection_references` field lists both the original
`glue_connection_name` and the registered `smus_connection_name` plus
`smus_connection_id`. Each rewritten file is written back atomically (temp
file plus rename) so a SIGKILL between writes never leaves a half-rewritten
artifact on disk. Entries whose `status` is `skipped_unsupported` or `failed`
do not contribute a rule.

**When the mapping file is absent.** No rewrite is performed. Every
`outputs/scripts/*.py` and `outputs/notebooks/*.ipynb` is left byte-for-byte
unchanged. `connection_rewrite.py` instead emits a single structured warning
row to stdout and to `outputs/errors.json` of the form

```json
{"step": "03_glue-jobs", "warning": "Connection_Mapping_File missing", "action": "run Step 4b and re-run Step 3"}
```

`connection_rewrite.py` exits 0 because this is a recoverable warning, not a
failure. The rest of Step 3 still completes successfully and the `STATUS:
ok` line is still emitted, which is the behaviour Requirement 9.5 mandates:
the operator is expected to run Step 4b once it is available and re-run
Step 3 to refresh the rewritten outputs.

This contract is symmetric with the producer contract documented in Step 4b's
README and is the reason the Migration_Tool packages Step 4b as a dedicated
sub-step (`04b_glue-connections`) rather than folding it into Step 4: Step 3
must be re-runnable against a Connection_Mapping_File that did not exist on
its first invocation.

## 8. Dry-run vs apply

| Mode | Behaviour |
|------|-----------|
| Dry-run (default; either no flag or `--dry-run`) | Prints `DRY-RUN: aws glue get-jobs ...` and `DRY-RUN: aws s3 cp ...` for every would-be AWS invocation and never calls AWS. Synthesises a placeholder `outputs/glue-jobs.json` with an empty `Jobs` array so the rest of the pipeline can render a complete reviewable command list. The `notebook_gen` and `connection_rewrite` Python helpers always run because they only touch this step's `outputs/` folder; in dry-run mode they operate on the placeholder inventory and produce no committed work. The repository working tree is **not** modified — `git add` and `git commit` are not invoked. |
| Apply (`--apply`)                                  | Issues every command in section 4 against AWS, runs both subprocess tools (section 5) on the real per-job script bodies, and then `git add`s `outputs/scripts/` and `outputs/notebooks/` to `data-pipelines/glue-jobs/` on the configured working branch followed by a single `git commit` whose message names every Glue job whose script or notebook changed in this run (Requirement 9.6).                                                                                |

In both modes the step emits `STATUS: started` on entry and `STATUS: ok` on
success so the Orchestrator records the same state transitions for Step 3
as for every other step.

## 9. Per-item failure resilience

Step 3 is designed to absorb single-job failures rather than aborting the
whole inventory pass (Requirement 9.7):

- A Glue job whose `Job.Command.ScriptLocation` cannot be read (missing S3
  object, denied access, malformed S3 URI, network timeout) is recorded in
  `outputs/errors.json` with the job name and the captured stderr message,
  and the loop continues with the next job.
- A Glue job whose script downloads but whose notebook generation fails is
  recorded in the same file with the job name and the `notebook_gen` exit
  code, and the loop continues.
- The "Connection_Mapping_File missing" warning emitted by
  `connection_rewrite.py` (section 7) is appended to the same
  `outputs/errors.json` so the operator sees every actionable signal in one
  place.

The step exits 0 even when one or more jobs failed; the per-job failures are
surfaced via `outputs/errors.json` and via the run summary table the
Orchestrator prints at the end of the run.

## 10. Citations

The following AWS documentation URLs are MCP-cached: each URL has been
fetched through the AWS Documentation MCP server (`AWS_Docs_MCP`) and cached
under `./docs/cache/<sha256(url)[:16]>.json`, so a future regeneration of
this README is a cache hit and does not re-fetch the source.

- [AWS Glue API — Jobs](https://docs.aws.amazon.com/glue/latest/dg/aws-glue-api-jobs-job.html)
  — MCP-cached at `docs/cache/491808af397e5cd3.json`. Canonical source for the
  shape of the `aws glue get-jobs` response, the `Job.Command.Name` valid
  values (`glueetl`, `pythonshell`, `gluestreaming`, `gluerayetl`) that drive
  the notebook-generation branch, and the `Job.Command.ScriptLocation`
  field that section 4 reads to download each job's script body. The same
  reference documents the `Connections` (`ConnectionsList`) and
  `DefaultArguments` fields that the connection-rewrite path consumes.
- [Bringing existing resources into Amazon SageMaker Unified Studio](https://docs.aws.amazon.com/sagemaker-unified-studio/latest/userguide/bring-resources-scripts.html)
  — MCP-cached at `docs/cache/61bc827e30a30b92.json`. Canonical source for
  the in-place onboarding pattern Step 3 implements: existing Glue ETL job
  scripts are brought into SMUS via a code repository rather than being
  recreated, and the originating jobs continue to run in the source account.

The matching Reference_Document section is **"4. Best Path to Bring
Existing Datasets, Glue Jobs, and ML Assets"** in `SageMaker Unified Studio
- Migration Answers.md`. That section is the canonical statement of the
"reference existing Glue jobs from a repository, no data movement required"
pattern this step encodes; in particular it sets out the `data-pipelines/glue-jobs/`
repository layout that Step 3's apply-mode commit targets and the
broader principle that Glue Data Catalog metadata, S3 data references, and
Glue ETL scripts are portable in place into SMUS_Domain workflows.
