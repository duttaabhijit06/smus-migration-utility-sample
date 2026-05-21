# SageMaker Unified Studio Migration Toolkit

A learning sample for migrating analytics workloads into [Amazon SageMaker Unified Studio (SMUS)](https://docs.aws.amazon.com/sagemaker-unified-studio/latest/userguide/). Read the scripts, run them in a test account, and copy the patterns into your own tooling.

---

## How it works in 30 seconds

You run four scripts in order:

```bash
./scripts/seed.sh provision --apply --profile <aws-profile> --yes      # 1. fake source data
./scripts/smus-setup.sh setup --apply --profile <aws-profile> --yes    # 2. build the SMUS domain
./scripts/migrate.sh run --apply --profile <aws-profile> --yes         # 3. migrate into SMUS
# ... use SMUS, tear down when done ...
./scripts/migrate.sh teardown --apply --profile <aws-profile> --yes    # 4. unwind migration
./scripts/smus-setup.sh teardown --apply --profile <aws-profile> --yes # 5. tear down SMUS
./scripts/nuke.sh --apply --profile <aws-profile> --yes                # 6. wipe fake source data
```

Each script defaults to dry-run. Pass `--apply` to actually do things.

---

## What you need before you start

1. **AWS account** you can experiment in (don't use production).
2. **AWS CLI** installed and configured with credentials.
3. **Python 3.12** with virtualenv: `python3 -m venv .venv && .venv/bin/pip install -e .`
4. **`jq`** installed (`brew install jq` or `apt-get install jq`).
5. **AWS Identity Center (IDC) enabled** in your target region — open the IAM Identity Center console once and click "Enable" if it isn't already.

---

## Layout

```
scripts/
  ├── seed.sh               # creates fake source data
  ├── smus-setup.sh         # builds the SMUS domain via CloudFormation
  ├── migrate.sh            # runs the 9-step migration
  ├── add-glue-databases.sh # adds Glue databases to the admin project (post-migration)
  └── nuke.sh               # wipes the fake source data

cfn/                  # CloudFormation templates the setup script deploys
  ├── master-stack.yaml
  ├── child-stacks/   # 6 child templates
  ├── lambda/handler/ # Lambda Python source (zipped by CodeBuild at deploy time)
  ├── params.json.template
  └── params.json     # rendered at deploy time (gitignored)

migration_tool/       # Python orchestrator for the migration steps
steps/                # bash scripts for each migration step
seed/                 # source-side seed data scripts
config/               # runtime config files (gitignored)
state/                # runtime state files (gitignored)
```

---

## What `seed.sh provision` creates

You don't have a real source account to test against — `seed.sh` builds one. It dispatches per-service modules under `seed/<service>/{create,teardown}.sh` in canonical order so a single command stands up the whole surface.

| What gets built | Why |
|---|---|
| **VPC + private subnets** in two AZs | Networking the SMUS Tooling environment will reuse |
| **Glue Data Catalog**: `smus-seed-db-raw` + `smus-seed-db-curated` (~6 tables) | Realistic source-side Glue catalog the migration walks |
| **S3 data buckets**: raw/, curated/, scripts/ | Backing storage for the Glue tables |
| **RDS** (Aurora MySQL) | Source database for the Glue→Iceberg ETL pattern |
| **MSK** + **Kinesis** + **Firehose** + **SNS** | Streaming services that show up in the migration's portability report |
| **Glue jobs** (PySpark, Python shell, RDS-to-Iceberg) | Source code the migration converts to SMUS notebooks |
| **MWAA Airflow environment** + DAG bucket | Source workflows the migration extracts and re-deploys into SMUS |
| **Lambda functions** + CloudWatch alarms | Inventory targets — surfaced in the portability report but not migrated |

Wall-clock: ~25 minutes (most of that is MWAA — it always takes 25+ minutes).

State is tracked in `seed/seed.state.json`. Run `./scripts/seed.sh status` any time to see what's been provisioned. After `smus-setup.sh` runs, the seed state file is also where the SMUS setup reads VPC and subnet IDs from.

---

## What `smus-setup.sh setup` builds

It creates everything via one CloudFormation deploy:

- A SMUS DataZone domain
- An admin project owned by an IDC group
- 17 environment blueprints + a Tooling environment + a Lakehouse Database environment
- Several IAM roles (domain execution, service, manage-access, automation, LF registration)
- A Lake Formation registration role + KMS key + S3 buckets
- A small Python Lambda (built inside the stack via CodeBuild) that runs post-deploy work and pre-delete cleanup

You can tweak every CloudFormation parameter — see the next section.

---

## CloudFormation parameter inputs

There are 21 inputs to the CloudFormation stack. **Every one is overridable.** The script resolves each through this priority chain:

```
CLI flag  >  environment variable  >  config/smus-setup.config.json  >  auto-discovered  >  hard-coded default
```

Three workflows:

1. **Plain run, no overrides** — defaults + auto-discovery do everything. First-time users.
2. **Interactive (CLI flags)** — pass `--domain-name foo` etc. on the command line. Resolved values are persisted, so the next run picks them up automatically.
3. **JSON / batch (env vars)** — set `SMUS_DOMAIN_NAME=foo` etc. in your shell or CI YAML. Same effect as CLI flags but easier to thread through automation.

### Full input parameter list

| What | CLI flag | Env var | Default / how auto-discovered |
|---|---|---|---|
| **SMUS domain name** | `--domain-name NAME` | `SMUS_DOMAIN_NAME` | `smus-seed-domain` |
| **Admin project name** | `--admin-project-name NAME` | `SMUS_ADMIN_PROJECT_NAME` | `smus-admin` |
| **Admin IDC group** (owns the admin project) | `--admin-group NAME` | `MT_ADMIN_GROUP_NAME` | Prompted on first run, default `smus-admins`. Resolved to a GUID-style ID via `aws identitystore list-groups`. |
| **Data engineer IDC group** | `--de-group NAME` | `MT_DE_GROUP_NAME` | Default `smus-data-engineers`. |
| **Data consumer IDC group** | `--consumer-group NAME` | `MT_CONSUMER_GROUP_NAME` | Default `smus-data-consumers`. |
| **IDC instance ARN** | `--sso-instance-arn ARN` | `MT_IDENTITY_CENTER_INSTANCE_ARN` | Discovered via `aws sso-admin list-instances` (the account-local instance). |
| **VPC ID** for the Tooling environment | `--vpc-id ID` | `SMUS_VPC_ID` | Read from `seed/seed.state.json` (`.services.network.resources.vpc_id`). |
| **Subnet IDs** (comma-separated, private) | `--subnet-ids CSV` | `SMUS_SUBNET_IDS` | Read from `seed/seed.state.json`. Two subnets, one per AZ. |
| **Tooling S3 bucket name** | `--tooling-bucket NAME` | `SMUS_TOOLING_BUCKET` | `amazon-datazone-tooling-<account>-<region>` |
| **Templates / Lambda source S3 bucket** | `--templates-bucket NAME` | `SMUS_TEMPLATES_BUCKET` | `smus-seed-cfn-<account>-<region>` |
| **Lambda source S3 prefix** (optional) | `--lambda-source-prefix STR` | `SMUS_LAMBDA_SOURCE_PREFIX` | `''` (empty) |
| **Domain execution IAM role name** | `--domain-execution-role-name NAME` | `SMUS_DOMAIN_EXECUTION_ROLE_NAME` | `sagemaker-domain-execution` |
| **Domain service IAM role name** | `--domain-service-role-name NAME` | `SMUS_DOMAIN_SERVICE_ROLE_NAME` | `AmazonDataZoneServiceRole` |
| **Automation Lambda IAM role name** | `--automation-role-name NAME` | `SMUS_AUTOMATION_ROLE_NAME` | `smus-seed-automation-role` |
| **Automation policy name** | `--automation-role-policy-name NAME` | `SMUS_AUTOMATION_ROLE_POLICY_NAME` | `smus-seed-automation-policy` |
| **Manage-access IAM role name** | `--managed-access-role-name NAME` | `SMUS_MANAGED_ACCESS_ROLE_NAME` | `sagemaker-studio-manage-access-role` |
| **CFN stack name** | `--stack-name NAME` | `SMUS_STACK_NAME` | `smus-seed`. Override to namespace stacks in your account (e.g. `acme-platform-smus`); persisted to `config/smus-setup.config.json` so subsequent setup / teardown runs reuse the same name. |
| **Git provider** | `--repo-provider PROV` | `SMUS_REPO_PROVIDER` | `CodeCommit` (alternatives: `GitHub`, `GitLab`, `Bitbucket`) |
| **Git repo / connection name** | `--repo-name NAME` | `SMUS_REPO_NAME` | `<domain-name>-migration` |
| **Git repo URL** (3P providers) | `--repo-url URL` | `SMUS_REPO_URL` | empty — required for 3P (e.g. `https://github.com/owner/repo.git`) |
| **Pre-existing connection ARN** | `--repo-connection-arn ARN` | `SMUS_REPO_CONNECTION_ARN` | empty — pin a connection you already created in the console (e.g. for GitHub Enterprise Server / GitLab Self-Managed) |

### Examples

**Default everything (first-time user)**:

```bash
./scripts/smus-setup.sh setup --apply --yes --profile smus-seed
```

**Interactive — change the domain and project names**:

```bash
./scripts/smus-setup.sh setup --apply --yes --profile smus-seed \
    --domain-name acme-prod-domain \
    --admin-project-name acme-platform-admin
```

**Use existing IDC groups** (the groups must already exist in IDC; the script halts with exit 65 if they don't):

```bash
./scripts/smus-setup.sh setup --apply --yes --profile smus-seed \
    --admin-group acme-platform-admins \
    --de-group acme-data-engineers \
    --consumer-group acme-data-consumers
```

**Specify VPC / subnets directly** (useful if you don't run `seed.sh` first):

```bash
./scripts/smus-setup.sh setup --apply --yes --profile smus-seed \
    --vpc-id vpc-0abc123 \
    --subnet-ids subnet-0aaa,subnet-0bbb
```

**Pin everything for a CI run**:

```bash
./scripts/smus-setup.sh setup --apply --yes --profile smus-seed \
    --domain-name acme-prod-domain \
    --admin-project-name acme-platform-admin \
    --admin-group acme-platform-admins \
    --de-group acme-data-engineers \
    --consumer-group acme-data-consumers \
    --sso-instance-arn arn:aws:sso:::instance/ssoins-... \
    --vpc-id vpc-0abc123 \
    --subnet-ids subnet-0aaa,subnet-0bbb \
    --tooling-bucket amazon-datazone-tooling-acme-prod \
    --templates-bucket acme-smus-templates-prod \
    --domain-execution-role-name acme-smus-domain-exec \
    --domain-service-role-name acme-smus-domain-svc \
    --automation-role-name acme-smus-automation \
    --managed-access-role-name acme-smus-manage-access
```

**Same thing via env vars** (CI YAML use case — set once, run multiple commands):

```bash
export AWS_PROFILE=smus-seed
export SMUS_DOMAIN_NAME=acme-prod-domain
export SMUS_ADMIN_PROJECT_NAME=acme-platform-admin
export MT_ADMIN_GROUP_NAME=acme-platform-admins
export MT_DE_GROUP_NAME=acme-data-engineers
export MT_CONSUMER_GROUP_NAME=acme-data-consumers
export SMUS_VPC_ID=vpc-0abc123
export SMUS_SUBNET_IDS=subnet-0aaa,subnet-0bbb
export SMUS_TEMPLATES_BUCKET=acme-smus-templates-prod
./scripts/smus-setup.sh setup --apply --yes
```

**Re-run with persisted values** — every value resolved on a previous run is saved to `config/smus-setup.config.json`. So this works:

```bash
# First run sets everything
./scripts/smus-setup.sh setup --apply --yes --profile smus-seed --domain-name acme-prod-domain

# Second run just uses what was saved last time — no flag needed
./scripts/smus-setup.sh setup --apply --yes --profile smus-seed
```

### Git connection (CodeCommit vs 3P)

Per the SageMaker Unified Studio admin guide, **Git connections attach at the domain level** (a CodeConnections resource that SMUS surfaces on the domain's Connections tab). The setup stack handles both flavors:

- **CodeCommit (default)** — CFN creates an `AWS::CodeCommit::Repository` named `<domain>-migration` (override with `--repo-name`). SMUS auto-provisions a default CodeCommit connection on every domain, so nothing else is needed. The repo is fully managed by the stack — `smus-setup.sh teardown` deletes it.
- **3P providers (GitHub / GitLab / Bitbucket)** — Pass `--repo-provider GitHub --repo-url https://github.com/owner/repo.git`. CFN creates an `AWS::CodeConnections::Connection` that lands in `PENDING` state and stays there until you complete the one-time OAuth handshake (see banner below).
- **GitHub Enterprise Server / GitLab Self-Managed** — These need a separate CodeConnections `Host` resource that itself requires an OAuth-style setup against the on-prem server. Easiest path is to create the Host + Connection in the AWS console once, then pass `--repo-connection-arn arn:aws:codeconnections:...` to skip the create entirely. The stack only grants the project user role permission to use the supplied ARN.

> ## ⚠️ ATTENTION — Two manual steps for 3P providers
>
> When `--repo-provider` is anything other than `CodeCommit`, two one-time clicks are required after stack create. **Both are by AWS design and cannot be automated** — there's no public AWS API for either.
>
> **Step 1 — Authorize the connection** (CodeConnections OAuth handshake):
>
> 1. Open: `https://<region>.console.aws.amazon.com/codesuite/settings/connections`
> 2. Find your connection by the name from `--repo-name` (Connection status column reads `Pending`)
> 3. Click **Update pending connection**
> 4. Sign in to GitHub / GitLab / Bitbucket and authorize the AWS app
> 5. Confirm the Connection status flips to `Available`
>
> **Step 2 — Enable the connection on the SMUS domain** (per-domain toggle):
>
> 1. Open: `https://<region>.console.aws.amazon.com/datazone/home?region=<region>#/domains`
> 2. Click your domain name → **Connections** tab
> 3. Select the connection row (Project status column reads `Disabled`)
> 4. Click **Enable** in the top-right toolbar and confirm in the popup
> 5. Refresh the page — Project status should read `Enabled`
>
> Until both steps are done, project members can't clone or push through this connection. The `aws-smus-cicd-cli` and JupyterLab Git panel will fail with auth errors.
>
> **Why two clicks:** AWS treats Step 1 (authorize) and Step 2 (per-domain enable) as separate trust boundaries. The OAuth handshake gives AWS read/write access to your 3P repos; the per-domain enable then explicitly grants every signed-in user in the AWS account access to that connection. Per the SMUS admin guide: *"When you enable a Git connection, all users who can sign in to any domain in the account have read and write access to all repositories on that connection."*
>
> **Verifying:** re-run `./scripts/smus-setup.sh setup --apply --yes` — it short-circuits (stack already healthy), reads the live connection state, and prints `repo_connection_state: AVAILABLE` instead of the banner. You can also check with:
>
> ```bash
> aws codeconnections get-connection \
>     --connection-arn $(jq -r .repo_connection_arn config/smus-setup.config.json) \
>     --query 'Connection.ConnectionStatus'
> ```
>
> The per-domain `Enabled` flag isn't readable through any public AWS API — verify visually on the domain's Connections tab.
>
> **Re-runs are safe:** the connection ARN, repo URL, and provider are persisted to `config/smus-setup.config.json` after each setup run. `migrate.sh` step 01 reads them automatically — no `--set git_connection_id=...` plumbing needed.
>
> **Teardown:** `./scripts/smus-setup.sh teardown` deletes the connection (and the CodeCommit repo when that branch was used) as part of the stack delete. The actual GitHub / GitLab / Bitbucket repository on the 3P side is left alone — it lives outside the AWS account.

```bash
# CodeCommit (default — nothing to pass)
./scripts/smus-setup.sh setup --apply --yes

# GitHub — landing connection in PENDING; authorize banner appears at end of run
./scripts/smus-setup.sh setup --apply --yes \
    --repo-provider GitHub \
    --repo-url https://github.com/acme-corp/data-platform.git

# Reuse a pre-existing CodeConnections connection (e.g. for GHES) — no banner,
# no manual step (assumes you already authorized when you created it)
./scripts/smus-setup.sh setup --apply --yes \
    --repo-provider GitHub \
    --repo-connection-arn arn:aws:codeconnections:us-east-1:111122223333:connection/abcd-...
```

Sample banner you'll see at the end of a 3P setup run while the connection is still `PENDING`:

```
    repo_provider:         GitHub
    repo_name:             smus-seed-domain-migration
    repo_connection_arn:   arn:aws:codeconnections:us-east-1:111122223333:connection/abcd-...
    repo_connection_state: PENDING

    ============================================================
    ACTION REQUIRED: Authorize the Git connection.
    1. Open: https://us-east-1.console.aws.amazon.com/codesuite/settings/connections
    2. Find connection 'smus-seed-domain-migration' (state: Pending)
    3. Click 'Update pending connection' and complete the OAuth flow.
    Until done, the connection cannot be used for Git pulls.
    ============================================================
```

---

## What `migrate.sh run` does

A wrapper around the Python migration tool that runs 9 steps in order. Each step does one specific job:

| # | Step | What it does |
|---|---|---|
| 01 | `create-smus-domain` | Confirm the domain `smus-setup.sh` built. Resolve repo / connection IDs from the setup config (CFN owns the repo and connection — this step just records the binding). |
| 02 | `portability` | Classify every AWS service: Full / Inventory-only / Excluded. Writes `portability-report.json`. |
| 03 | `glue-jobs` | Export every Glue job script, convert to a SageMaker notebook, commit to `data-pipelines/glue-jobs/`. |
| 03b | `lakeformation-setup` | Re-grant Lake Formation permissions on every seed database and table. |
| 04 | `catalog` | Tell SMUS to scan the seed Glue databases and publish their tables as searchable assets. |
| 05 | `s3-data` | Copy data files from source S3 buckets into the SMUS-managed location. |
| 06 | `mwaa-extract` | Pull DAGs, plugins, requirements out of the source MWAA bucket; commit DAGs to `data-pipelines/workflows/dags/`. |
| 07 | `mwaa-integrate` | Use `aws-smus-cicd-cli` to deploy DAGs into the admin project's MWAA. |
| 08 | `dag-yaml` | (Optional, `--convert-dags`.) Convert Python DAGs to SMUS YAML format where possible. |
| 09 | `cicd` | (Optional, `--push-cicd`.) Generate provider-native pipeline file (`deploy.yml` / `.gitlab-ci.yml` / etc.) and `git push` to the configured repo. **Requires local Git credentials for 3P providers** — see "Step 09 prerequisites" below. |

Each step writes its progress to `state/migration.state.json`, so a partial failure can be resumed by simply re-running the command — already-completed steps are skipped automatically.

Wall-clock: ~15-20 minutes if everything works first try.

Pre-run helpers (run by the wrapper before the migration tool fires):

- **Repo bootstrap** — initializes the project root as a Git working tree of the repo set up in CFN (CodeCommit clone URL, or a 3P URL discovered through the CodeConnections connection) so Step 6 can `git commit` extracted DAGs. Skips politely for 3P providers, where the operator wires the local tree manually after the OAuth handshake.
- **CICD CLI install** — `pip install aws-smus-cicd-cli` into the venv so Step 7 can deploy the DAGs.
- **Auto-subscribe** — subscribes the admin project to its own published Glue assets (clears the "Asset cannot be queried with tools" badge).
- **Resource-link DESCRIBE grants** — gives the project user role `DESCRIBE` on every resource link in `glue_db_<env_id>`.

### Step 09 prerequisites (`--push-cicd`, optional)

> ## ⚠️ ATTENTION — Step 09 needs local Git credentials for 3P providers
>
> Step 09 (`cicd`) does two things: generate a provider-native pipeline file (`deploy.yml` / `.gitlab-ci.yml` / `bitbucket-pipelines.yml`) and `git push` it to the configured repo.
>
> **Why it's now opt-in:** the AWS CodeConnections connection we wire up in CFN authenticates Git operations *inside* the SMUS portal (JupyterLab, Code Editor) — it does **not** authenticate `git push` calls made from the migration tool's local working tree. AWS has no equivalent of the CodeCommit credential helper for 3P providers; you need a personal access token, SSH key, or `gh auth login` set up locally.
>
> **For CodeCommit users:** Step 09 just works — the AWS CLI credential helper signs requests with the active AWS profile. No setup needed.
>
> **For GitHub / GitLab / Bitbucket users:** set up local Git auth before passing `--push-cicd`. Pick whichever fits your workflow:
>
> ```bash
> # Option A — GitHub CLI (interactive, easiest for personal accounts)
> gh auth login
>
> # Option B — Personal access token cached by the OS keychain
> git config --global credential.helper osxkeychain    # macOS
> # OR: git config --global credential.helper "cache --timeout=86400"  # Linux/WSL
> git push                                              # one push prompts for token, then it's cached
>
> # Option C — SSH (if your repo URL is the SSH form)
> ssh-keygen -t ed25519 -C "you@example.com"
> # add ~/.ssh/id_ed25519.pub to GitHub / GitLab / Bitbucket settings
> ```
>
> **Then run with the opt-in flag:**
>
> ```bash
> ./scripts/migrate.sh run --apply --yes -- --push-cicd
> ```
>
> **Or, run only Step 09 after a previous full migration:**
>
> ```bash
> ./scripts/migrate.sh run --apply --yes -- --step 09_cicd --push-cicd
> ```
>
> **Skipping Step 09 doesn't break the migration.** Steps 01-08 produce a fully working SMUS deployment with the data, Glue notebooks, and DAGs migrated. The pipeline file is a convenience artifact — you can `git push` the working tree manually any time, or skip CI/CD entirely if your team uses a different deployment system.

### Targeting an existing SMUS domain (bring-your-own)

If you already have a SMUS domain in your account — provisioned by your own infra-as-code, an internal SMUS deployment, or a previous run of this toolkit — skip `smus-setup.sh setup` and run `migrate.sh` directly against it with `--bring-your-own`.

**Auto-discover IDs from names** (most common):

```bash
./scripts/migrate.sh run --apply --yes --profile mycorp \
    --bring-your-own \
    --domain-name acme-platform-domain \
    --admin-project-name acme-migration-admin
```

The script looks up the domain ID, project ID, project profile ID, domain service role, and IDC instance ARN automatically and persists them to `config/smus-setup.config.json` for subsequent runs.

**Pass explicit IDs** (useful when the runner's IAM doesn't allow `datazone:ListDomains` or `datazone:ListProjects`):

```bash
./scripts/migrate.sh run --apply --yes --profile mycorp \
    --smus-domain-id dzd-abc123 \
    --admin-project-id xyz789 \
    --admin-project-profile-id pp-def456
```

Required IAM permissions for auto-discovery:
- `datazone:ListDomains`, `datazone:GetDomain`
- `datazone:ListProjects`, `datazone:GetProject`
- `sso-admin:ListInstances`
- `sts:GetCallerIdentity`

In BYOD mode the toolkit's `state/smus-setup.state.json` doesn't need to exist. The script:
1. Resolves the IDs (auto-discovery or explicit flags)
2. Persists them to `config/smus-setup.config.json` so re-runs work without flags
3. Proceeds with the same migration helpers + 9-step run as the seed flow

If you pass `--bring-your-own` but neither names nor IDs, defaults `smus-seed-domain` / `smus-admin` are used (same as the seed flow names).

---

## Adding more Glue databases later

Use `scripts/add-glue-databases.sh` to bring additional Glue catalog databases into the admin project after the initial migration is complete. Every step is idempotent — safe to re-run.

```bash
./scripts/add-glue-databases.sh \
    --databases mydb1,mydb2,mydb3 \
    --apply --profile smus-seed --yes
```

What it does for each named database:

1. Validates the DB exists in Glue.
2. Revokes `IAMAllowedPrincipals` on the DB + tables; grants `DESCRIBE/SELECT (+Grantable)` to the project user role and the manage-access role.
3. Registers the unique S3 prefixes (one per table location) with `--with-federation --hybrid-access-enabled`.
4. Adds the DB to the project's Glue data source (or creates a new one) and triggers a sync run.
5. Auto-subscribes the admin project to the resulting listings.
6. Grants `DESCRIBE` on the new resource links inside the project's managed Glue DB.

Required flag:

| Flag | What it does |
|---|---|
| `--databases CSV` | Comma-separated list of Glue database names. |

Optional flags:

| Flag | What it does |
|---|---|
| `--data-source-name NAME` | Override the data source name. Defaults to the migration tool's `migration-tool-glue-catalog` (if it exists) so the new DBs land in the same publish target as the seed flow. |
| `--apply` / `--dry-run` | Default dry-run. |
| `--profile NAME`, `--region NAME`, `--yes` | Standard. |

Wall-clock: ~1-2 minutes per database (most of that is waiting for the data source sync run to publish listings).

Re-run if subscriptions or resource-link grants don't take effect on the first try — the listings show up asynchronously after the sync.

---

## What `migrate.sh teardown` does

Reverses only the migration-side mutations — does NOT delete the SMUS domain.

1. Cancels every active subscription the admin project holds.
2. Revokes the Lake Formation `DESCRIBE` permissions on resource links.
3. Wipes the migration state file.

Wall-clock: ~30 seconds.

---

## What `smus-setup.sh teardown` does

Deletes the SMUS CloudFormation stack. The in-stack Lambda runs nine hardening passes BEFORE CFN deletes anything (orphan ENI drain, dangling LF admin strip, force-delete project, tooling bucket drain, etc.) — so a healthy delete-stack works end-to-end without manual intervention.

Repo cleanup is part of the stack delete:
- For **CodeCommit**, the in-stack `AWS::CodeCommit::Repository` is deleted (the entire commit history goes with it — back up first if you need to keep it).
- For **3P providers**, the `AWS::CodeConnections::Connection` is deleted, but the actual GitHub / GitLab / Bitbucket repository is left alone — those live outside the AWS account.

Wall-clock: ~10-15 minutes.

---

## What `nuke.sh` does

Wipes the fake source data created by `seed.sh`. Audits AWS directly (doesn't trust the seed state file) and deletes every resource whose name starts with the seed prefix (default `smus-seed-`).

Wall-clock: ~10 minutes.

Override the prefix or region with `--prefix NAME` and `--region NAME`.

---

## Other script flags

### Common flags (apply to all four scripts)

| Flag | Purpose |
|---|---|
| `--apply` | Actually do things in AWS. Required to make changes. |
| `--dry-run` | Show what WOULD happen but don't change anything. Default. |
| `--profile NAME` | AWS CLI profile (or set `AWS_PROFILE`). |
| `--region NAME` | AWS region (or set `AWS_DEFAULT_REGION`; defaults to `us-east-1`). |
| `--yes` / `-y` | Skip the confirmation prompt. |

### Action verbs

```
./scripts/seed.sh         provision | teardown | status
./scripts/smus-setup.sh   setup     | teardown | status
./scripts/migrate.sh      run       | teardown | status | reset
./scripts/nuke.sh         (no verb — just runs the wipe)
```

### Migration tool passthrough flags

`migrate.sh run` is a wrapper. Anything after `--` goes to `python -m migration_tool`:

| Flag | What it does |
|---|---|
| `--step <id>` | Run only that one step. Example: `--step 03_glue-jobs`. |
| `--from <id>` | Start from this step. |
| `--to <id>` | Stop after this step. |
| `--force <id>` | Re-run a step even if it's already marked completed. |
| `--reset <id>` | Reset a step's status to pending. |
| `--reconfigure` | Re-prompt for every config value. |
| `--set <key>=<value>` | Pre-set one config value. Multiple `--set` flags allowed. |
| `--convert-dags` | Include the optional Step 8 (Python DAG → YAML conversion). |
| `--push-cicd` | Include the optional Step 9 (CI/CD pipeline file + git push). 3P providers need local Git credentials — see "Step 09 prerequisites" above. |

Examples:

```bash
# Re-run only the Glue jobs step
./scripts/migrate.sh run --apply --yes -- --force 03_glue-jobs

# Run steps 3 through 6
./scripts/migrate.sh run --apply --yes -- --from 03_glue-jobs --to 06_mwaa-extract

# Pre-set the repo provider so the prompt doesn't appear
./scripts/migrate.sh run --apply --yes -- --set repo_provider=codecommit
```

The migration tool will prompt interactively for any config value it doesn't have. Pre-set values via `--set` to skip prompts. Persistent values live in `config/migration.config.json`.

---

## Common gotchas

**"My setup --apply prompted for IDC groups but I want to use my company's existing groups."**

Pass `--admin-group YOUR-GROUP --de-group YOUR-GROUP --consumer-group YOUR-GROUP`. The groups must exist in IDC; the script halts (exit 65) if they don't.

**"Setup failed with 'no account-local IDC instance found'."**

Open the IAM Identity Center console, click "Enable" for your region, then re-run.

**"Migration failed with 'SMUS setup is not complete'."**

You need to run `smus-setup.sh setup --apply` first. Migration won't run against a half-built domain.

**"I want to re-run only one migration step."**

```bash
./scripts/migrate.sh run --apply --yes -- --force 03_glue-jobs
```

**"How do I see what's in the state files?"**

```bash
./scripts/smus-setup.sh status   # what setup has done
./scripts/migrate.sh status      # what migration has done
./scripts/seed.sh status         # what seed has provisioned
```

**"Something failed mid-migration. How do I recover?"**

1. Look at the error in `logs/migrate-<timestamp>.log`.
2. Fix what's broken in AWS.
3. Re-run `./scripts/migrate.sh run --apply --yes`. Already-completed steps are skipped.

If a step is stuck `in_progress`:

```bash
./scripts/migrate.sh run --apply --yes -- --reset 05_s3-data
./scripts/migrate.sh run --apply --yes
```

---

## What's actually happening (advanced)

The setup splits naturally into "things CloudFormation can model" and "things that have to happen after CloudFormation finishes." The post-CloudFormation work runs inside the stack as a Lambda function — so from your point of view it's still one `aws cloudformation deploy`.

**Done by CloudFormation directly:**

| What | Template |
|---|---|
| SMUS DataZone domain | `cfn/child-stacks/sus-domain-stack.yaml` |
| Domain execution / service / provisioning IAM roles + LF registration role + projects S3 bucket | `cfn/child-stacks/sus-domain-stack.yaml` |
| 17 blueprints + Tooling S3 bucket + KMS key + manage-access role | `cfn/child-stacks/sus-blueprints-stack.yaml` |
| 4 project profiles | `cfn/child-stacks/sus-project-profiles-stack.yaml` |
| Policy grants | `cfn/child-stacks/sus-policy-grant-stack.yaml` |
| Admin project + group ownership | `cfn/child-stacks/sus-project-stack.yaml` |
| CodeBuild that zips the loose Python source into a Lambda zip | `cfn/child-stacks/sus-lambda-build-stack.yaml` |
| The post-deploy / pre-delete Lambda | `cfn/master-stack.yaml` |

**Done by the in-stack Lambda at create time** (after every other resource is in place):

- Walks every external Glue database, revokes `IAMAllowedPrincipals`, grants `DESCRIBE/SELECT (+Grantable)` to the project user role and the manage-access role.
- Sets Lake Formation `data-lake-settings` for SMUS Spark sessions (external data filtering, account allow-list, seven session-tag values).
- Adds `LakeFormationFGACAccess` and `GlueCatalogReadAccess` inline policies on the dynamic project user role (`datazone_usr_role_<projectId>_<envId>`).
- Adds an `AllowProjectUserRoleForSparkLogs` statement to the Tooling bucket's KMS key policy.
- Re-registers source S3 prefixes with `--with-federation --hybrid-access-enabled`.
- (Optional) Adds **CodeCommit Git-ops** permissions if `repo_provider=CodeCommit`, OR a `codeconnections:UseConnection` grant scoped to the specific connection ARN if `repo_provider` is a 3P (so the project user role can mint short-lived Git credentials at clone/push time).

**Done by the in-stack Lambda at delete time** (before CloudFormation deletes anything):

Nine hardening passes cover failure modes CloudFormation can't recover from:

1. Strip the KMS statement we added.
2. Detach the inline IAM policies on the dynamic project user role.
3. Drain SMUS-managed VPC endpoints on the Tooling SG.
4. Force-detach + delete orphan DataZone-owned ENIs.
5. Revoke cross-SG ingress rules.
6. Drive each DataZone environment to GONE.
7. Drop orphaned `glue_db_<env_id>` databases (including ones from previous teardowns).
8. Force-delete the project if stuck in `DELETE_FAILED`.
9. Pre-strip the project user role from Lake Formation data-lake admins (so CFN's `rAddDataLakeAdministratorToLakeFormation` delete handler doesn't trip later).
10. Drain + delete the Tooling S3 bucket (versions + delete markers).

**Why the in-stack Lambda exists:** several operations can't be expressed in CloudFormation — IDC group/user resources don't exist as CFN types; Lake Formation `data-lake-settings` only models the `Admins` field; `register-resource --with-federation` doesn't have a CFN parameter; the dynamic project user role's name isn't known at deploy time. These all run as boto3 calls inside the Lambda after the rest of the stack is up.

---

## Reference document

`SageMaker Unified Studio - Migration Answers.md` at the repository root is the canonical reference for AWS-recommended approaches.

Each per-step README under `steps/` cites at least one URL fetched from the AWS Documentation MCP server (cached under `docs/cache/`).
