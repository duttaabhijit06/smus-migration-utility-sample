# Step 09 — CI/CD enablement and `v1.0.0-prod` release tag

> Validates: Requirements 5.3, 5.4, 6.3 (and implements 16.1–16.9, 3.6)

## 1. Purpose

Step 9 is the migration's release-engineering step. It emits the
provider-native CI/CD pipeline file for the `repo_provider` configured in
`config/migration.config.json`, generates the aggregated CI/CD deployment
manifest at `outputs/ci-cd/manifest.yaml`, and (in apply mode for every
provider other than `codecommit`) pushes branch `migration/cicd-enable`
to the configured code repository plus the annotated production release
tag `v1.0.0-prod` on the latest commit of that branch.

For `repo_provider == "codecommit"` the step intentionally **halts
without pushing**: it writes `outputs/MANUAL-CI-WIRING.md` describing
the two operator-driven wiring paths (Amazon CodePipeline and Amazon
CodeCatalyst), emits `STATUS: manual_ci_wiring_required`, and exits 0.
The clean exit is deliberate — the codecommit halt is a documented
end-state for the configured Repo_Provider, not a runtime error. No
native pipeline file is generated, no manifest is generated, no
branch is pushed, and no tag is created on the codecommit branch.

The rest of the workspace's release lifecycle is consolidated here:
Step 6 commits DAGs to `data-pipelines/workflows/dags/`, Step 8 (when
gated on by `--convert-dags`) commits YAMLs under
`data-pipelines/workflows/yaml/`, and Step 3 commits Glue scripts and
notebooks under `data-pipelines/glue-jobs/`, but **none** of those
steps push to the remote, create branches, or create tags. All
credential-bound git operations land in Step 9 so the operator only
has to set up provider tokens (or SSH keys, or
`git-remote-codecommit`) for one step.

## 2. Provider switch table

The single switch on `MT_REPO_PROVIDER` selects the artifact the step
emits and its trigger surface. Every emitted path is relative to
`steps/09_cicd/outputs/`:

| `repo_provider`                       | Emitted file                              | Trigger surface                                                                                       |
|---------------------------------------|-------------------------------------------|-------------------------------------------------------------------------------------------------------|
| `github` / `github-enterprise-server` | `outputs/.github/workflows/deploy.yml`    | GitHub Actions: `on: [push, workflow_dispatch]` with `workflow_dispatch.inputs.stage` ∈ `{dev, test, prod}` (default `dev`) |
| `gitlab` / `gitlab-self-managed`      | `outputs/.gitlab-ci.yml`                  | GitLab CI: `workflow:rules` for default-branch push and web pipelines, `variables.STAGE` ∈ `{dev, test, prod}` (default `dev`) |
| `bitbucket`                           | `outputs/bitbucket-pipelines.yml`         | Bitbucket Pipelines: `pipelines.default` for default-branch push, `pipelines.custom` keyed by `dev` / `test` / `prod`         |
| `codecommit`                          | `outputs/MANUAL-CI-WIRING.md` (no push, no tag, no manifest) | n/a — wiring is delegated to AWS CodePipeline or Amazon CodeCatalyst (see section 6)                  |

The five non-codecommit providers each emit exactly one pipeline file,
and they all install `aws-smus-cicd-cli` and run
`aws-smus-cicd deploy --manifest ci-cd/manifest.yaml --stage <stage>`
where `<stage>` is the trigger-supplied dev / test / prod value. The
path shapes match each provider's well-known on-disk convention so
the file can be committed straight into the repository tree without
rewriting paths.

The `stage` value selected by the trigger is forwarded verbatim to
`aws-smus-cicd deploy --stage <stage>`. Because the closed set
`{dev, test, prod}` is enforced in the pipeline file itself (a `type:
choice` input on GitHub Actions, an `options:` list on GitLab CI, and
the closed `pipelines.custom` key set on Bitbucket), an operator
cannot dispatch the pipeline against a stage that is not one of those
three values, which prevents typoed stage names from reaching
`aws-smus-cicd-cli` at deploy time.

## 3. Manifest aggregation rules

For every provider other than `codecommit`, the step also writes
`outputs/ci-cd/manifest.yaml`. The manifest aggregates entries from
exactly three upstream steps, with one entry per source artifact and
no de-duplication beyond what the upstream step already produced:

| Source step                       | Source artifact                                                       | Manifest entry shape                                                                                                              |
|-----------------------------------|-----------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------|
| Step 3 (`03_glue-jobs`)           | `outputs/glue-jobs.json` (one row per `Jobs[].Name`)                  | `type: glue-etl`, `name: <job-name>`, `script_path: data-pipelines/glue-jobs/<job-name>.py`                                       |
| Step 4b (`04b_glue-connections`)  | `outputs/connection-mapping.json` (the `Connection_Mapping_File`) — only rows whose `status` is `registered` | `type: smus-connection`, `name: <smus_connection_name>`, `connection_id: <smus_connection_id>` (when present), `connection_type: <datazone_connection_type>` (when present) |
| Step 6 (`06_mwaa-extract`)        | `outputs/dags/*.py` (one row per Python DAG file)                     | `type: mwaa-workflow`, `name: <dag-basename-without-.py>`, `dag_path: data-pipelines/workflows/dags/<dag-basename>.py`           |

Rows from Step 4b whose `status` is `skipped_unsupported` or `failed`
are **not** projected into the manifest — they would not be deployable
through `aws-smus-cicd deploy` and including them as broken entries
would force the deploy to fail on a clean run. The same applies to
upstream-step output that is missing entirely: when one of the three
source artifacts is absent, the step logs a warning to its run log,
omits that source's contribution from the manifest, and continues
with the remaining sources.

The manifest's trailing `stages:` block carries exactly one stage
entry, named `dev`, whose `config` map lists the SMUS_Domain ID, the
Admin_Project ID, and the source AWS account ID resolved from the
`MT_SMUS_DOMAIN_ID`, `MT_ADMIN_PROJECT_ID`, and `MT_SOURCE_ACCOUNT_ID`
environment variables that the orchestrator forwards from the
Config_File. The provider-native pipeline file in section 2 exposes
`dev` / `test` / `prod` as trigger choices; mapping the latter two
choices to real stage blocks is left to the operator's repository
(typically by adding `test` and `prod` blocks alongside this `dev`
baseline before the first `aws-smus-cicd deploy --stage test` or
`--stage prod` run).

A small example of the resulting `outputs/ci-cd/manifest.yaml`:

```yaml
application:
  name: migration-tool-cicd
  resources:
    - type: glue-etl
      name: raw-extract
      script_path: data-pipelines/glue-jobs/raw-extract.py
    - type: smus-connection
      name: orders-redshift
      connection_id: smus-conn-abc123
      connection_type: REDSHIFT
    - type: mwaa-workflow
      name: daily-pipeline
      dag_path: data-pipelines/workflows/dags/daily-pipeline.py
stages:
  - name: dev
    config:
      domain_id: dzd_aaaaaaaa
      project_id: prj_bbbbbbbb
      account_id: 111111111111
```

## 4. Branch and tag conventions

For every provider other than `codecommit`, the apply-mode contract is
exactly:

- **Branch**: `migration/cicd-enable`. The step pushes the generated
  pipeline file (section 2) and the aggregated manifest (section 3) on
  this branch. The branch name is fixed so the operator can locate the
  migration's CI/CD enablement commit in any repository the tool has
  touched. Re-runs are idempotent: `git ls-remote --heads <repo>
  migration/cicd-enable` is consulted before push, and an
  already-existing remote branch is treated as a successful no-op.
- **Tag**: annotated `v1.0.0-prod` on the latest commit of
  `migration/cicd-enable`. The tag is annotated (not lightweight) so
  it carries a tagger identity and a message — the message is
  literally `"Production release v1.0.0"`. Re-runs are idempotent here
  too: `git ls-remote --tags <repo> v1.0.0-prod` is consulted before
  tag creation, and an already-existing remote tag is treated as a
  successful no-op.

The branch and the tag are pushed in that order: branch first (so the
remote has the commit the tag will point at), then tag. A failure
between the two leaves the branch in place and is recoverable by
re-running the step in apply mode.

The working copy of the configured repository lives at
`steps/09_cicd/outputs/work-repo/`. On first apply-mode run the step
clones `MT_REPO_URL` into that directory; on subsequent apply-mode
runs the step calls `git fetch --all --tags` against the existing
clone instead of re-cloning, so partial work (a created branch that
failed to push, for instance) is preserved across re-runs.

## 5. CodeCommit halt + manual wiring path

When `repo_provider == "codecommit"`, Step 9 takes a different path:

1. It writes (or, in dry-run, would-be-writes)
   `outputs/MANUAL-CI-WIRING.md` describing the two AWS-native wiring
   options for a CodeCommit-hosted migration repo. Both options are
   documented because organisations select between them based on
   their CI/CD posture, not on tool capability:
   - **Amazon CodePipeline** — wire a CodePipeline pipeline that
     sources from the CodeCommit_Repo's `main` branch, runs a
     CodeBuild project that installs `aws-smus-cicd-cli` and invokes
     `aws-smus-cicd deploy --manifest ci-cd/manifest.yaml --stage
     <stage>`, and stages through `dev` / `test` / `prod` via approval
     actions.
   - **Amazon CodeCatalyst** — connect the CodeCommit_Repo to a
     CodeCatalyst space and use a CodeCatalyst workflow that installs
     `aws-smus-cicd-cli` and invokes the same deploy command. The
     workflow's `Triggers` section mirrors the push +
     manual-dispatch surface described in section 2.
2. It emits `STATUS: manual_ci_wiring_required` so the orchestrator
   records the halt in the run log.
3. It exits 0. The Step Runner records Step 9's state as
   `completed`, and the orchestrator surfaces the `manual_ci_wiring_required`
   status line in the end-of-run summary so the operator can act on
   the manual hand-off.
4. It **never** generates `outputs/.github/workflows/deploy.yml`,
   `outputs/.gitlab-ci.yml`, or `outputs/bitbucket-pipelines.yml`.
5. It **never** generates `outputs/ci-cd/manifest.yaml`. The manifest
   aggregation in section 3 is bypassed because there is no
   provider-native pipeline to feed it into.
6. It **never** invokes `git push`, `git tag`, or `git ls-remote`,
   never opens a working clone, and never reads any of the
   credentials in section 6 below.

The orchestrator distinguishes this halt-by-design from a runtime
failure by parsing the trailing `STATUS: manual_ci_wiring_required`
line on the script's stdout and treating the step's exit code 0 as
success.

## 6. Credential expectations

For every provider other than `codecommit`, the step's apply-mode git
operations (`git clone`, `git fetch`, `git ls-remote`, `git push`)
authenticate against the configured `repo_url`. The step reads no
provider tokens itself; instead it relies on whichever git
authentication the operator has already configured on the host:

| Provider                              | Recommended credential mechanism                                                                 |
|---------------------------------------|---------------------------------------------------------------------------------------------------|
| `github` / `github-enterprise-server` | HTTPS credential helper (`git config --global credential.helper`) holding a PAT with `repo` scope, OR an SSH agent if the configured `repo_url` is an `ssh://` URL |
| `gitlab` / `gitlab-self-managed`      | HTTPS credential helper holding a project / group access token with `write_repository` scope, OR an SSH agent for `ssh://` URLs |
| `bitbucket`                           | HTTPS credential helper holding an app password with `Repositories: Write`, OR an SSH agent for `ssh://` URLs |
| `codecommit`                          | n/a — Step 9 does not push or fetch on the codecommit branch. If a future operator wires CodePipeline (per section 5) and uses the local `git` CLI to interact with the CodeCommit_Repo separately, the canonical credential mechanism is `git-remote-codecommit` (`pip install git-remote-codecommit`) which signs requests with the locally configured AWS credentials |

The shared run-log redactor in `migration_tool/redact.py` uses the
case-insensitive `*token*`, `*secret*`, `*password*`, `*key*` glob set
to mask any token-shaped substring before the run log lands on disk
(Requirement 4.5), so even if the operator chose to surface a token
through an environment variable that the step happens to log, the
on-disk record will read `***REDACTED***`.

The step exposes a single, named-credential failure mode. If `git
clone`, `git fetch`, `git ls-remote`, or `git push` fails, the step
halts with a `STATUS: error` line whose message names the operation
that failed and the `repo_url` whose credentials need to be checked
(for example, `STATUS: error git push failed (auth or network); check
credentials for https://gitlab.com/example/group/repo`). The message
never echoes a token value.

If `repo_url` itself is missing from the Config_File when the step
starts (and `repo_provider != "codecommit"`), the step's
`mt_require_var MT_REPO_URL` check exits 64 with `STATUS: missing_var
MT_REPO_URL` before any git operation runs (Requirement 16.9). The
orchestrator's `required_config_for("09_cicd", config)` helper
computes `["repo_provider", "repo_url"]` for non-codecommit providers
so the prompter collects the URL on first run.

## 7. Configuration keys consumed

The Orchestrator forwards each Config_File value listed below as an
`MT_*` environment variable before invoking `run.sh`:

| Key                | Required when                                | Notes                                                                                  |
|--------------------|----------------------------------------------|----------------------------------------------------------------------------------------|
| `repo_provider`    | always                                       | The single switch that selects the emitted pipeline file (section 2) and the apply-mode push path (section 4). |
| `repo_url`         | every provider other than `codecommit`       | The git remote URL the step pushes branch `migration/cicd-enable` and tag `v1.0.0-prod` to. Validated by the prompter against the provider-specific regex in `migration_tool/config.py`. |
| `smus_domain_id`   | every provider other than `codecommit`       | Filled by Step 1 in apply mode. Embedded in the manifest's `stages[0].config.domain_id`. |
| `admin_project_id` | every provider other than `codecommit`       | Filled by Step 1 in apply mode. Embedded in the manifest's `stages[0].config.project_id`. |
| `source_account_id`| every provider other than `codecommit`       | Collected during interactive configuration (Requirement 2.1). Embedded in the manifest's `stages[0].config.account_id`. |

Step 9 reads no other Config_File keys directly. Stage-specific values
for `test` and `prod` (project IDs, account IDs, role ARNs) are not
embedded in the generated manifest and are left for the operator to
add when they wire the higher stages.

## 8. Artifacts produced

All artifacts are written under `steps/09_cicd/outputs/`. Which paths
exist on disk after a run depends on `repo_provider` and the run mode:

| Path                                              | Produced when                                              | Contents                                                                                         |
|---------------------------------------------------|------------------------------------------------------------|--------------------------------------------------------------------------------------------------|
| `outputs/.github/workflows/deploy.yml`            | `repo_provider in {github, github-enterprise-server}` AND apply mode | GitHub Actions workflow with the trigger surface from section 2. (Dry-run prints `DRY-RUN: write <path>`.) |
| `outputs/.gitlab-ci.yml`                          | `repo_provider in {gitlab, gitlab-self-managed}` AND apply mode | GitLab CI configuration with the trigger surface from section 2. (Dry-run prints `DRY-RUN: write <path>`.) |
| `outputs/bitbucket-pipelines.yml`                 | `repo_provider == bitbucket` AND apply mode                | Bitbucket Pipelines configuration with the trigger surface from section 2. (Dry-run prints `DRY-RUN: write <path>`.) |
| `outputs/ci-cd/manifest.yaml`                     | every `repo_provider` other than `codecommit` AND apply mode | Aggregated manifest per section 3. One file per run; deterministic for a given upstream input. (Dry-run prints `DRY-RUN: write <path>`.) |
| `outputs/MANUAL-CI-WIRING.md`                     | `repo_provider == codecommit` (only) AND apply mode        | Operator instructions for wiring CodePipeline or CodeCatalyst per section 5. (Dry-run prints `DRY-RUN: write <path>`.) |
| `outputs/work-repo/`                              | every `repo_provider` other than `codecommit` AND apply mode | The cloned working copy of `MT_REPO_URL`, refreshed via `git fetch --all --tags` on subsequent apply-mode runs. |
| `outputs/run.log`                                 | always (apply mode)                                        | Tee of the step's stdout/stderr, including `STATUS:` lines, `mt_log` lines, and (in apply) `git` invocations. Created by `mt_init`. |

Re-runs overwrite each of the file artifacts above in place. None of
them contain secrets — the manifest's stage block lists IDs from the
Config_File (which is operator-supplied and not secret-shaped), and
the run log is filtered through the redactor before any
`*_TOKEN`-shaped substring reaches disk.

## 9. Dry-run vs apply behavior

| Mode                | Behavior                                                                                                                                                                                              |
|---------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Dry-run (default)   | Aggregates the manifest in memory, decides which provider-native pipeline file to emit, and emits one `DRY-RUN: write <path>` line per file that would be written. No file artifacts land on disk. The git workflow is enumerated as `DRY-RUN: git clone …`, `DRY-RUN: git ls-remote …`, `DRY-RUN: git checkout -B …`, `DRY-RUN: git add …`, `DRY-RUN: git commit …`, `DRY-RUN: git push …`, `DRY-RUN: git tag -a …`, `DRY-RUN: git push origin v1.0.0-prod`, in that order. For `repo_provider == codecommit`, the script emits `DRY-RUN: write <outputs/MANUAL-CI-WIRING.md>` followed by `STATUS: manual_ci_wiring_required` and exits 0 without enumerating any git command. |
| Apply (`--apply`)   | Aggregates the manifest, writes `outputs/ci-cd/manifest.yaml`, writes the provider-native pipeline file under `outputs/`, clones (or fetches) `MT_REPO_URL` into `outputs/work-repo/`, checks `git ls-remote --heads` for `migration/cicd-enable`, branches + commits + pushes when the branch is absent, then checks `git ls-remote --tags` for `v1.0.0-prod`, and creates + pushes the annotated tag when it is absent. Halts with a named-credential `STATUS: error` and exits 1 on any git failure (Requirement 16.9). For `repo_provider == codecommit`, writes `outputs/MANUAL-CI-WIRING.md`, emits `STATUS: manual_ci_wiring_required`, and exits 0 without invoking git. |

The step emits `STATUS: started` on entry, `STATUS: action git <args>`
per executed (or would-be) git invocation in apply mode (or one
`DRY-RUN: git <args>` line per command in dry-run mode), and `STATUS:
ok` on success. The codecommit branch emits `STATUS:
manual_ci_wiring_required` instead of `STATUS: ok` to surface the
manual hand-off in the orchestrator's end-of-run summary.

## 10. Citations

The following AWS documentation URL is MCP-cached: it has been
fetched through the AWS Documentation MCP server (`AWS_Docs_MCP`) and
cached under `./docs/cache/<sha256(url)[:16]>.json`, so a future
regeneration of this README is a cache hit and does not re-fetch the
source (Requirement 6.2).

- AWS_Docs_MCP: [CI/CD for Amazon SageMaker Unified Studio (User Guide)](https://docs.aws.amazon.com/sagemaker-unified-studio/latest/userguide/cicd.html)
  — canonical source for the `aws-smus-cicd-cli` deploy command shape
  (`aws-smus-cicd deploy --manifest <path> --stage <stage>`), the
  `manifest.yaml` schema's `application.resources[*]` and `stages[*]`
  blocks (referenced in section 3 above), and the `dev` / `test` /
  `prod` three-stage convention (referenced in sections 2 and 3
  above).
- Open-source CLI repository: [aws/CICD-for-SageMakerUnifiedStudio](https://github.com/aws/CICD-for-SageMakerUnifiedStudio)
  — the `aws-smus-cicd-cli` is published as an open-source project
  at this repository. The repository is the install source for the
  `pip install aws-smus-cicd-cli` step embedded in every emitted
  provider-native pipeline file (section 2), and it is the canonical
  reference for the resource types the manifest's
  `application.resources[*]` list (section 3) supports today.

The matching Reference_Document section is **"3. CI/CD Approach for Unified Studio Projects"** in `SageMaker Unified Studio - Migration Answers.md`.
That section is the source of truth for the principle
that one `manifest.yaml` aggregates an application's Glue jobs, MWAA
workflows, and SageMaker Catalog assets across the dev / test / prod
stages — exactly the aggregation rule encoded in section 3 above —
and that each pipeline stage maps to an independent SMUS project for
full isolation between environments. The same Reference_Document
section also frames `aws-smus-cicd-cli` as the deployment tool that
provider-native CI systems (GitHub Actions, GitLab CI, Bitbucket
Pipelines, CodePipeline, CodeCatalyst) wrap with their own trigger
surfaces — which is exactly the provider-switch contract encoded in
section 2 above.
