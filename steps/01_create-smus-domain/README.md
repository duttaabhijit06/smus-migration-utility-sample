# Step 01 — Create SMUS Domain, Admin Project, and Git Connection

> Validates: Requirements 5.3, 5.4, 6.1, 6.3

## 1. Purpose

This step bootstraps the migration target environment. It creates the SMUS_Domain
(IAM Identity Center authentication mode) in the configured AWS region, creates
the Admin_Project inside that domain using the All-capabilities project profile,
and registers a Git connection on the Admin_Project pointing at the configured
code repository. When `repo_provider=codecommit`, the step also auto-creates the
underlying CodeCommit_Repo (or treats an existing repository with the configured
name as a successful no-op) and registers it as a CodeCommit-typed Git
connection. This is the first state-changing step in the migration sequence and
every later step depends on the SMUS_Domain ID, Admin_Project ID, and Git
connection ID it persists to the Config_File.

## 2. Prerequisites

- AWS IAM Identity Center is enabled in the source AWS account, and the IAM
  Identity Center instance ARN has been persisted to the Config_File as
  `identity_center_instance_arn`.
- The `domain_execution_role` IAM role referenced via `MT_DOMAIN_EXECUTION_ROLE`
  (default: `arn:aws:iam::<source_account_id>:role/sagemaker-domain-execution`)
  exists in the source AWS account and trusts `datazone.amazonaws.com`.
- The local AWS CLI is configured for the target account: `aws sts
  get-caller-identity` succeeds and returns the same `Account` value as
  `source_account_id` in the Config_File.
- The Orchestrator has previously persisted the Config_File at
  `./config/migration.config.json` (Step 1 will halt and prompt if any required
  key listed below is missing or empty).

## 3. Configuration keys consumed

The Orchestrator forwards every Config_File value listed below as an `MT_*`
environment variable before invoking `run.sh`.

| Key                            | Required for                                    | Notes                                                                                                                                                                |
|--------------------------------|-------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `repo_provider`                | always                                          | Closed set: one of `codecommit`, `github`, `github-enterprise-server`, `gitlab`, `gitlab-self-managed`, `bitbucket`. Selects the repository and Git-connection branch. |
| `repo_url`                     | every `repo_provider` except `codecommit`       | Validated against a provider-aware regex by the Orchestrator (see Requirement 2.8). For `codecommit`, this key is **populated** by Step 1 from the `cloneUrlHttp`.    |
| `repo_name`                    | `repo_provider=codecommit`                       | Defaults to `<smus_domain_name>-migration`. Used as the CodeCommit repository name passed to `aws codecommit get-repository` / `create-repository`.                  |
| `aws_region`                   | always                                          | Target AWS region for `aws datazone create-domain` and `aws codecommit create-repository`.                                                                            |
| `smus_domain_name`             | always                                          | Name of the SMUS_Domain to create (or reuse via `list-domains`).                                                                                                      |
| `admin_project_name`           | always                                          | Name of the Admin_Project to create (or reuse via `list-projects`) inside the SMUS_Domain.                                                                            |
| `identity_center_instance_arn` | always                                          | ARN of the IAM Identity Center instance, passed to `aws datazone create-domain --single-sign-on`.                                                                     |

## 4. AWS CLI commands issued

The step issues exactly the following AWS CLI invocations, in this order. Each
invocation flows through `mt_aws` (apply mode) or `mt_dryrun` (dry-run mode);
neither helper ever shells out to `boto3` or any Python AWS SDK.

1. `aws datazone list-domains --query "items[?name=='<smus_domain_name>'].id" --output text --region <aws_region>` — pre-existence check for the SMUS_Domain.
2. `aws datazone create-domain --name <smus_domain_name> --domain-execution-role <domain_execution_role_arn> --single-sign-on type=IAM_IDC,userAssignment=AUTOMATIC,idcInstanceArn=<identity_center_instance_arn> --region <aws_region>` — create the SMUS_Domain (only if step 1 returned no match).
3. `aws datazone list-projects --domain-identifier <domain_id> --query "items[?name=='<admin_project_name>'].id" --output text` — pre-existence check for the Admin_Project.
4. `aws datazone create-project --domain-identifier <domain_id> --name <admin_project_name> --project-profile-id <admin_project_profile_id>` — create the Admin_Project (only if step 3 returned no match).
5. `aws codecommit get-repository --repository-name <repo_name> --region <aws_region>` — **codecommit branch only**, pre-existence check for the CodeCommit_Repo.
6. `aws codecommit create-repository --repository-name <repo_name> --region <aws_region>` — **codecommit branch only**, create the CodeCommit_Repo (only if step 5 returned 404).
7. `aws datazone list-connections --domain-identifier <domain_id> --project-identifier <project_id> --query "items[?name=='<connection_name>'].connectionId" --output text` — pre-existence check for the Git connection.
8. `aws datazone create-connection --domain-identifier <domain_id> --project-identifier <project_id> --type GIT --name <connection_name> --props <provider_properties>` — create the Git connection (only if step 7 returned no match). The `<provider_properties>` payload is `codecommitProperties={repositoryArn=<arn>}` for the codecommit branch and `<provider>Properties={url=<repo_url>}` (e.g. `githubProperties`, `gitlabProperties`, `bitbucketProperties`, `githubEnterpriseServerProperties`, `gitlabSelfManagedProperties`) for every other provider.

## 5. Artifacts produced

- `outputs/run.log` — full tee of the step's stdout and stderr (apply mode tees
  every `mt_aws` invocation; dry-run mode tees every `DRY-RUN: aws ...` line).
- `STATUS: set smus_domain_id=<id>` — interpreted by the Orchestrator and
  persisted to `config/migration.config.json` as `smus_domain_id`.
- `STATUS: set admin_project_id=<id>` — persisted to the Config_File as
  `admin_project_id`.
- `STATUS: set git_connection_id=<id>` — persisted to the Config_File as
  `git_connection_id`.
- `STATUS: set repo_url=<cloneUrlHttp>` — **codecommit branch only**, persisted
  as `repo_url`. For non-codecommit providers, `repo_url` is already in the
  Config_File from the prompt.
- `STATUS: set codecommit_repo_arn=<arn>` — **codecommit branch only**,
  persisted as `codecommit_repo_arn`.

The step writes nothing under `outputs/` other than `run.log`; the resource
identifiers are emitted as `STATUS:` lines and persisted to the Config_File by
the Orchestrator (never by the step itself).

## 6. Dry-run behavior

When invoked without `--apply` (the default), or with the explicit `--dry-run`
flag, the step:

- Prints every would-be `aws ...` invocation from section 4 prefixed with the
  literal string `DRY-RUN: ` and **never** calls AWS.
- Logs each `DRY-RUN: aws ...` line to `outputs/run.log` so the Orchestrator's
  Run_Log captures the same line via the runner's stdout tee.
- Synthesises placeholder identifiers (`dzd_DRYRUN`, `prj_DRYRUN`,
  `conn_DRYRUN`, and a deterministic CodeCommit clone URL / ARN constructed
  from `aws_region`, `source_account_id`, and `repo_name`) so every later
  phase can render a complete reviewable command line without contacting AWS.
- Emits the same `STATUS: set ...` lines as apply mode, but the values are
  the dry-run placeholders. The Orchestrator's Dry_Run_Mode contract suppresses
  Config_File writes for those placeholder values.
- Returns 0 exactly when every required `MT_*` variable is present.

## 7. Apply-mode behavior

When invoked with `--apply`, the step issues the same commands listed in
section 4 against AWS, in order, with idempotency short-circuits:

- The SMUS_Domain create is skipped when `aws datazone list-domains` returns a
  matching name; the existing domain ID is used for every later phase.
- The Admin_Project create is skipped when `aws datazone list-projects` returns
  a matching name on the resolved domain.
- The CodeCommit_Repo create is skipped when `aws codecommit get-repository`
  succeeds for the configured `repo_name`; the existing `cloneUrlHttp` and
  ARN are persisted as if the create had succeeded.
- The Git connection create is skipped when `aws datazone list-connections`
  returns a connection whose `name` matches the resolved connection name on
  the Admin_Project.

After every successful phase the step emits the corresponding `STATUS: set
<key>=<value>` line so the Orchestrator can persist `smus_domain_id`,
`admin_project_id`, `git_connection_id`, and (codecommit branch) `repo_url`
and `codecommit_repo_arn` to the Config_File before any later step runs.

## 8. Idempotency

Re-running this step in apply mode is a successful no-op when every target
resource already exists with a matching name on the configured domain or
account. Each create is gated behind a pre-existence check:

- `aws datazone list-domains` short-circuits `aws datazone create-domain`.
- `aws datazone list-projects` short-circuits `aws datazone create-project`.
- `aws codecommit get-repository` short-circuits `aws codecommit
  create-repository` on the codecommit branch (a non-zero exit from
  `get-repository` is treated as 404 and falls through to create).
- `aws datazone list-connections` short-circuits `aws datazone
  create-connection` for the Git connection.

A re-run after a partial failure picks up at the first phase whose pre-existence
check returns no match, so the step is safely re-runnable per Requirement 3.6
without duplicating resources.

## 9. Citations

The following AWS documentation URLs are MCP-cached: each URL has been fetched
through the AWS Documentation MCP server (`AWS_Docs_MCP`) and cached under
`./docs/cache/<sha256(url)[:16]>.json`, so a future regeneration of this README
is a cache hit and does not re-fetch the source.

- [Git Connections in SageMaker Unified Studio (Admin Guide)](https://docs.aws.amazon.com/sagemaker-unified-studio/latest/adminguide/git-connections.html)
  — MCP-cached; canonical source for the supported `repo_provider` set
  (`codecommit`, `github`, `github-enterprise-server`, `gitlab`,
  `gitlab-self-managed`, `bitbucket`) and the connection-type names used in
  `aws datazone create-connection --type GIT --props ...`.
- [Automated data onboarding for SageMaker Unified Studio domains](https://docs.aws.amazon.com/sagemaker-unified-studio/latest/adminguide/data-onboarding.html)
  — MCP-cached; canonical source for the `aws datazone create-domain` call shape
  with `--single-sign-on type=IAM_IDC,userAssignment=AUTOMATIC,idcInstanceArn=...`
  and the All-capabilities
  Admin_Project profile.
- [What is AWS CodeCommit?](https://docs.aws.amazon.com/codecommit/latest/userguide/welcome.html)
  — MCP-cached; canonical source for the `aws codecommit get-repository` /
  `create-repository` call shapes used on the codecommit branch of phase 3.

The matching Reference_Document section is **"2. Git Connections"** in
`SageMaker Unified Studio - Migration Answers.md`. That section enumerates the
six supported Git providers (AWS CodeCommit, GitHub, GitHub Enterprise Server,
GitLab, GitLab Self-Managed, Bitbucket) and the account-level Git connection
model that this step encodes via `aws datazone create-connection`.
