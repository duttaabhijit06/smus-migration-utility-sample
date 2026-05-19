# Seed_Service_Module: Amazon CloudWatch (`seed/cloudwatch/`)

This module provisions a small CloudWatch surface so the Migration_Tool's
inventory phase (Requirement 17.6) can discover at least 2 alarms, 1
dashboard, and 2 log groups in the seed AWS account. It is part of the
top-level `./seed/provision.sh` orchestrator and runs after `seed/lambda/`
and `seed/glue/` have completed.

The module is bash-only and calls AWS CLI exclusively through the
`sbx_aws` helper from `seed/_lib/common.sh` (Requirement 19.1 / 20.1). It
reads BOTH upstream Lambda function ARNs from
`./seed/seed.state.json` at `.services.lambda.function_arns[]` to derive
the alarm dimensions, and persists every resource it creates back to
`./seed/seed.state.json` under `.services.cloudwatch.resources`.

## Dependencies on `seed/lambda/` and `seed/glue/`

This module depends on two upstream modules in the canonical run order
(Requirement 20.7: `glue(p1) → sns → msk → flink-kda → glue(p2) →
lambda → cloudwatch → quicksight → mwaa`):

- **`seed/lambda/create.sh`** (task 24.9, Requirement 20.20). Provisions
  the seed Lambda functions `${SBX_SEED_NAME_PREFIX}-fn-1` and
  `${SBX_SEED_NAME_PREFIX}-fn-2` and writes their ARNs to
  `.services.lambda.function_arns[0..1]` in `seed.state.json`. This
  module reads BOTH ARNs to derive:
    - alarm 1's dimensions
      (`Name=FunctionName,Value=<function-1-name>`),
    - alarm 2's dimensions
      (`Name=FunctionName,Value=<function-2-name>`), and
    - the Lambda log group path (which AWS Lambda would auto-create on
      first invocation at `/aws/lambda/<function-name>`; this module
      materialises it eagerly via `aws logs create-log-group` so the
      inventory step finds it without requiring a function invocation).
  If `.services.lambda.function_arns[0]` or `[1]` is missing or empty,
  this module halts with `STATUS: error dependency_not_provisioned`
  BEFORE any AWS CLI command.
- **`seed/glue/create.sh`** (task 24.5, Requirement 20.15). Provisions
  the seed Glue jobs and writes their names to
  `.services.glue.resources.jobs[]` in `seed.state.json`. This module
  reads `.services.glue.resources.jobs[0].name` (or, in the current
  seed-glue schema, `.services.glue.resources.jobs[0]` as a bare
  string) to verify a real Glue job exists that will eventually write
  to the shared `/aws-glue/jobs/output` log group provisioned below.
  If the entry is missing or empty, this module halts with
  `STATUS: error dependency_not_provisioned` BEFORE any AWS CLI
  command. The job NAME itself is not embedded in the log-group path —
  AWS Glue uses a single account-wide `/aws-glue/jobs/output` log
  group across all jobs by default.

## Resources created (Requirement 20.21)

`create.sh` provisions exactly:

| Kind       | Name                                                       | Notes                                                             |
| ---------- | ---------------------------------------------------------- | ----------------------------------------------------------------- |
| Log group  | `/aws/lambda/${SBX_SEED_NAME_PREFIX}-fn-1`                 | Materialised eagerly so inventory does not require an invocation  |
| Log group  | `/aws-glue/jobs/output`                                    | AWS-default Glue ETL job stdout log group; shared across the account |
| Alarm      | `${SBX_SEED_NAME_PREFIX}-alarm-1`                          | `AWS/Lambda` `Errors`, dimensions point at seed function 1        |
| Alarm      | `${SBX_SEED_NAME_PREFIX}-alarm-2`                          | `AWS/Lambda` `Errors`, dimensions point at seed function 2        |
| Dashboard  | `${SBX_SEED_NAME_PREFIX}-dashboard`                        | Single placeholder text widget; markdown-only                     |

Every name embeds the configured `seed_name_prefix` (Requirement 20.29)
either as a leading segment (alarms, dashboard) or inside the
AWS-mandated `/aws/lambda/` log-group namespace path. The
`/aws-glue/jobs/output` log group is a deliberate exception — that path
is the AWS-default Glue ETL stdout log group, shared across every Glue
job in the account. Requirement 20.21 names "one log group fed by a
Glue job from 20.15" without mandating that it be seed-prefixed, and
the AWS-default path is what real Glue jobs actually write to. The
`teardown.sh` deletion gate intentionally rejects this path so a
teardown cannot destroy log streams from non-seed Glue jobs.

## AWS CLI commands issued

`create.sh`:

- Idempotency probes (Requirement 20.13; always issued, even in dry-run,
  so the operator sees the would-be sequence):
    - `aws logs describe-log-groups --log-group-name-prefix /aws/lambda/<prefix>-fn-1`
    - `aws logs describe-log-groups --log-group-name-prefix /aws-glue/jobs/output`
    - `aws cloudwatch describe-alarms --alarm-names <prefix>-alarm-1`
    - `aws cloudwatch describe-alarms --alarm-names <prefix>-alarm-2`
    - `aws cloudwatch get-dashboard --dashboard-name <prefix>-dashboard`
- State-changing (only in `--apply`, gated by the corresponding probe):
    - `aws logs create-log-group` — creates each of the two log groups
    - `aws cloudwatch put-metric-alarm` — creates `<prefix>-alarm-1` and
      `<prefix>-alarm-2` with `--namespace AWS/Lambda --metric-name
      Errors --statistic Sum --period 60 --evaluation-periods 1
      --threshold 1 --comparison-operator
      GreaterThanOrEqualToThreshold --treat-missing-data notBreaching
      --dimensions Name=FunctionName,Value=<function-name>`
    - `aws cloudwatch put-dashboard` — creates `<prefix>-dashboard`

`teardown.sh` (reverse of create order, Requirement 20.8):

- `aws cloudwatch delete-dashboards --dashboard-names <recorded name>`
- `aws cloudwatch delete-alarms     --alarm-names     <recorded name>` (per alarm)
- `aws logs delete-log-group        --log-group-name  <recorded name>` (per group)

Every state-changing command is preceded by a `STATUS: action aws <verb>`
line emitted by `sbx_aws`, which the per-invocation log file at
`./seed/logs/run-<UTC>.log` captures (Requirement 20.14).

## Inputs consumed from `seed/seed.config.json`

This module does not introduce any cloudwatch-specific config keys. It
consumes the three Seed_Script-wide keys via the `SBX_*` environment
variables exported by `sbx_init`:

- `aws_region` → `SBX_REGION` (validated `^[a-z]{2}-[a-z]+-\d$`).
- `source_account_id` → `SBX_SOURCE_ACCOUNT_ID` (validated 12-digit).
- `seed_name_prefix` → `SBX_SEED_NAME_PREFIX` (prefixes every name).

Plus, from `./seed/seed.state.json`:

- `.services.lambda.function_arns[0]` — read via `sbx_state_get` to
  derive function 1's name (embedded in alarm 1's dimensions).
- `.services.lambda.function_arns[1]` — read via `sbx_state_get` to
  derive function 2's name (embedded in alarm 2's dimensions).
- `.services.glue.resources.jobs[0]` (the bare-string job-name array
  the current `seed/glue/create.sh` writes) — read via `sbx_state_get`
  with a defensive `if type == "string" then . else .name // empty
  end` selector that also tolerates a future `{name, arn}` object
  shape. The job NAME is read for validation only — its presence
  proves a real Glue job exists that will write to
  `/aws-glue/jobs/output`. The job name is not embedded in the
  log-group path.

## Identifiers persisted to `seed/seed.state.json`

After a successful `--apply` run, the `.services.cloudwatch` slot has:

```json
{
  "status": "provisioned",
  "resources": {
    "log_groups": [
      {
        "name": "/aws/lambda/<prefix>-fn-1",
        "arn":  "arn:aws:logs:<region>:<account>:log-group:/aws/lambda/<prefix>-fn-1:*",
        "feeds": "lambda"
      },
      {
        "name": "/aws-glue/jobs/output",
        "arn":  "arn:aws:logs:<region>:<account>:log-group:/aws-glue/jobs/output:*",
        "feeds": "glue"
      }
    ],
    "alarms": [
      {"name": "<prefix>-alarm-1", "function_name": "<prefix>-fn-1"},
      {"name": "<prefix>-alarm-2", "function_name": "<prefix>-fn-2"}
    ],
    "dashboard": {"name": "<prefix>-dashboard"}
  }
}
```

The schema (per task 24.10's contract) is:

- `.services.cloudwatch.resources.alarms` — array of alarm names, with
  the function each alarm targets recorded for operator diagnostics.
- `.services.cloudwatch.resources.dashboard` — single object with the
  dashboard name (note: singular `dashboard`, not `dashboards`, because
  the module creates exactly one).
- `.services.cloudwatch.resources.log_groups` — array of log groups,
  each with its name AND its full ARN (per task 24.10's "persist log
  group ARNs" requirement) and a `feeds` tag identifying the upstream
  module.

Persistence is incremental: log groups are written first (after both
`create-log-group` calls succeed), then the alarm names are merged in,
then the dashboard. This satisfies Requirement 20.12's contract that
resource identifiers be persisted BEFORE any further state-changing AWS
CLI command, so a process killed mid-run leaves an accurate record of
what was actually created. After `teardown.sh` completes, `status` is
rewritten to `torn_down`, the alarm and log-group arrays are emptied,
and `dashboard` is set to `null`; a subsequent `teardown.sh` re-run is
a no-op.

## Idempotency contract (Requirements 20.13, 20.32)

- Re-running `create.sh --apply` after a previous successful run issues
  zero `aws logs create-log-group`, zero `aws cloudwatch
  put-metric-alarm`, and zero `aws cloudwatch put-dashboard` commands:
  each pre-existence probe matches the recorded identifier and the
  corresponding create command is skipped.
- This module issues zero `aws datazone create-*` commands and never
  targets the SMUS_Domain ID or Admin_Project ID recorded in
  `./config/migration.config.json`. A re-run after the Migration_Tool
  has completed has no effect on SMUS resources (Requirement 20.32).

## Deletion gating (Requirement 20.31)

`teardown.sh` only deletes a recorded resource when:

1. its name matches the seed prefix — `${SBX_SEED_NAME_PREFIX}-`
   directly (alarms, dashboard) or embedded in
   `/aws/lambda/${SBX_SEED_NAME_PREFIX}-` (Lambda log groups), AND
2. its name is recorded in `./seed/seed.state.json` under
   `.services.cloudwatch.resources`.

Any candidate failing either check is skipped with a `STATUS: skip ...`
line and is never deleted, even when present in the same AWS account.
The Glue log group `/aws-glue/jobs/output` is always recorded in state
but is intentionally always skipped by this gate — see the table-row
note above.

## Run

Both scripts default to dry-run (Requirement 20.2) and exit 64 if
`--apply` and `--dry-run` are passed together (Requirement 20.4). Every
invocation appends to `./seed/logs/run-<UTC>.log` (Requirement 20.14).

```sh
# Dry-run (default): prints would-be AWS CLI commands.
bash seed/cloudwatch/create.sh

# Apply: actually creates the log groups, alarms, and dashboard.
bash seed/cloudwatch/create.sh --apply

# Teardown — dry-run / apply, same flag semantics.
bash seed/cloudwatch/teardown.sh
bash seed/cloudwatch/teardown.sh --apply
```

## References

- Requirement 20.9 — per-service Seed_Service_Module folder layout.
- Requirement 20.13 — idempotency on re-run (`describe-alarms`,
  `get-dashboard`, `describe-log-groups` before each `create-*`).
- Requirement 20.21 — exact CloudWatch resource counts (≥1 alarm, ≥1
  dashboard, ≥2 log groups; one log group fed by a Lambda from 20.20
  and one fed by a Glue job from 20.15).
- Requirement 20.29 — `${SBX_SEED_NAME_PREFIX}-` prefix gating.
- Requirement 20.31 — deletion gating (prefix + state-file).
- Requirement 20.32 — post-migration idempotency (no SMUS targeting).
- AWS docs — `aws logs create-log-group`, `aws cloudwatch
  put-metric-alarm`, `aws cloudwatch put-dashboard`, `aws cloudwatch
  get-dashboard`, `aws logs describe-log-groups` reference pages.
