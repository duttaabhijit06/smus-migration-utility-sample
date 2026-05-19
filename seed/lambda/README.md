# Seed module: AWS Lambda

This Seed_Service_Module provisions a minimal pair of AWS Lambda functions
plus the IAM execution role they require, so the Migration_Tool's
inventory pass (`steps/inventory/lambda/`) has at least two real
functions to discover in the source account. Lambda is one of the
inventory-only services — the Migration_Tool does not move Lambda
functions into the SMUS_Domain (Requirement 8.3); this seed exists
strictly so the inventory step has live targets to enumerate.

The module satisfies Requirement 20.20 by creating exactly **two
ZIP-deployed Python 3.11 Lambda functions** at the smallest plausible
configuration (128 MB / 30 s — the Seed_Config_File defaults from
`design.md`).

## Resources created

| Resource | Name |
| --- | --- |
| IAM role | `${SBX_SEED_NAME_PREFIX}-lambda-exec-role` |
| Lambda function 1 | `${SBX_SEED_NAME_PREFIX}-fn-1` |
| Lambda function 2 | `${SBX_SEED_NAME_PREFIX}-fn-2` |

`${SBX_SEED_NAME_PREFIX}` is the `seed_name_prefix` from
`./seed/seed.config.json` (Requirement 20.29). Both functions share a
single inline `lambda_function.py` whose
`lambda_function.lambda_handler` returns the literal payload
`{"statusCode": 200}`. The deployment ZIP is rebuilt on every run
under `./seed/lambda/dist/lambda_function.zip` using `zip -j -X` so the
archive contains one top-level `lambda_function.py` and is
byte-identical across re-runs. The `dist/` directory is local-only build
output; it is safe to delete.

## IAM role contract

`create.sh` owns the IAM role lifecycle. The role is created with the
following trust policy (Lambda as the only allowed principal) and one
attached AWS-managed policy:

| Field | Value |
| --- | --- |
| Trust principal | `lambda.amazonaws.com` (`sts:AssumeRole`) |
| Attached managed policy | `arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole` |
| Inline policies | none |
| Tags | `sbx:seed-name-prefix=${SBX_SEED_NAME_PREFIX}` |

The basic-exec managed policy grants the function permission to write to
its `/aws/lambda/<function-name>` log group; that is the only IAM
permission either seed function needs.

After creating the role, `create.sh` waits 10 seconds for IAM
eventual-consistency before issuing the first `aws lambda
create-function` call. Without the wait, Lambda frequently rejects the
fresh role with `InvalidParameterValueException: The role defined for
the function cannot be assumed by Lambda`. Re-runs against an existing
role (`get-role` hit) skip the wait.

`teardown.sh` reverses the role lifecycle in the order IAM requires:

1. detach every managed policy returned by
   `aws iam list-attached-role-policies`,
2. delete every inline policy returned by `aws iam list-role-policies`
   (defensive — `create.sh` authors none, but an operator-side edit
   would otherwise block the role delete),
3. `aws iam delete-role`.

A role with attached managed or inline policies cannot be deleted
(`DeleteConflict`); steps 1 and 2 are mandatory preconditions for
step 3.

## Inputs (consumed from `seed.config.json`)

| Key | Source | Used for |
| --- | --- | --- |
| `aws_region` | top-level | `--region` on every Lambda CLI call |
| `source_account_id` | top-level | building the synthetic role ARN in dry-run; same-account check |
| `seed_name_prefix` | top-level | role + function names (Requirement 20.29) |
| `lambda.memory_mb` | (default 128) | hardcoded today; reserved for future override |
| `lambda.timeout_seconds` | (default 30) | hardcoded today; reserved for future override |

## AWS CLI commands issued

In the canonical happy path (apply mode, fresh account), `create.sh`
issues, in order:

```bash
# 1. Idempotency probe for the role
aws iam get-role --role-name "${SBX_SEED_NAME_PREFIX}-lambda-exec-role"

# 2. Create role + attach managed policy (only on get-role miss)
aws iam create-role \
    --role-name "${SBX_SEED_NAME_PREFIX}-lambda-exec-role" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    --tags "Key=sbx:seed-name-prefix,Value=${SBX_SEED_NAME_PREFIX}"

aws iam attach-role-policy \
    --role-name "${SBX_SEED_NAME_PREFIX}-lambda-exec-role" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

# 3. Per-function: probe, then create on miss
aws lambda get-function \
    --region "$SBX_REGION" \
    --function-name "${SBX_SEED_NAME_PREFIX}-fn-1"

aws lambda create-function \
    --region "$SBX_REGION" \
    --function-name "${SBX_SEED_NAME_PREFIX}-fn-1" \
    --runtime python3.11 \
    --role "<role-arn from step 2>" \
    --handler lambda_function.lambda_handler \
    --memory-size 128 \
    --timeout 30 \
    --zip-file "fileb://./seed/lambda/dist/lambda_function.zip" \
    --tags "sbx:seed-name-prefix=${SBX_SEED_NAME_PREFIX}"

# (same probe + create-function for ${SBX_SEED_NAME_PREFIX}-fn-2)
```

On a re-run after a successful first run, the `get-role` and
`get-function` probes succeed and the matching `create-*` calls are
skipped (Requirement 20.13: zero `create-*` commands for resources
whose identifiers are already recorded). The `attach-role-policy` call
runs unconditionally because re-attaching an already-attached managed
policy is a 200 no-op on the AWS side, which is cheaper than a guarded
`list-attached-role-policies` probe.

`teardown.sh` issues, in order:

```bash
# Per recorded function: delete-function (gated by prefix + state-file)
aws lambda delete-function \
    --region "$SBX_REGION" \
    --function-name "${SBX_SEED_NAME_PREFIX}-fn-1"
aws lambda delete-function \
    --region "$SBX_REGION" \
    --function-name "${SBX_SEED_NAME_PREFIX}-fn-2"

# Then role cleanup, in IAM-required order
aws iam list-attached-role-policies \
    --role-name "${SBX_SEED_NAME_PREFIX}-lambda-exec-role"
aws iam detach-role-policy \
    --role-name "${SBX_SEED_NAME_PREFIX}-lambda-exec-role" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

aws iam list-role-policies \
    --role-name "${SBX_SEED_NAME_PREFIX}-lambda-exec-role"
# (delete-role-policy per inline policy — none in the canonical setup)

aws iam delete-role \
    --role-name "${SBX_SEED_NAME_PREFIX}-lambda-exec-role"
```

Functions and roles failing the dual gate (name MUST begin with
`${SBX_SEED_NAME_PREFIX}-` AND identifier MUST appear in
`seed.state.json`) are skipped with a `STATUS:` line and never deleted
(Requirement 20.31).

## Persisted identifiers (written to `seed.state.json`)

After a successful `create.sh` run, `.services.lambda` looks like:

```json
{
  "status": "provisioned",
  "role_arn": "arn:aws:iam::<account>:role/<prefix>-lambda-exec-role",
  "function_arns": [
    "arn:aws:lambda:<region>:<account>:function:<prefix>-fn-1",
    "arn:aws:lambda:<region>:<account>:function:<prefix>-fn-2"
  ]
}
```

The CloudWatch log groups Lambda creates implicitly on first invocation
are named `/aws/lambda/${SBX_SEED_NAME_PREFIX}-fn-1` and
`/aws/lambda/${SBX_SEED_NAME_PREFIX}-fn-2` per AWS convention; they are
not pre-created here. The `seed/cloudwatch/create.sh` module
(task 24.10) consumes one of these log group names so Requirement 20.21
("at least 2 log groups, one fed by a Lambda function from 20.20 and
one fed by a Glue job from 20.15") has a real Lambda log group to point
at.

After a successful `teardown.sh` run, `.services.lambda` is rewritten
to:

```json
{
  "status": "torn_down",
  "role_arn": "",
  "function_arns": []
}
```

## Run modes (dry-run vs apply)

- **Dry-run (default):** every state-changing AWS CLI call is rendered
  with a `DRY-RUN:` prefix and never executed. Read-only probes
  (`get-role`, `get-function`, `list-attached-role-policies`,
  `list-role-policies`) always return non-hit in dry-run so the operator
  sees the full set of would-be `create-*` / `delete-*` commands. The
  state file is still written with the planned shape so the operator
  can preview the recorded identifiers before committing.
- **Apply (`--apply`):** AWS CLI calls run for real. The same-account
  contract (Requirement 20.28) is verified before any state-changing
  command. After a fresh `create-role`, the script sleeps 10 seconds
  for IAM propagation before the first `create-function` call.
- The flags `--apply` and `--dry-run` are mutually exclusive
  (Requirement 20.4); supplying both halts with exit code 64.

## Cross-module dependencies

- **Upstream:** none. Lambda is invoked by the orchestrator after the
  Glue phase 2 step in the canonical provisioning order
  (`glue --phase=2 → lambda → cloudwatch → quicksight → mwaa`), but it
  has no functional input from earlier modules.
- **Downstream:** `seed/cloudwatch/create.sh` reads
  `.services.lambda.function_arns[0]` from `seed.state.json` so its
  log-group creation step (Requirement 20.21) references a real Lambda
  log group (`/aws/lambda/<function-name>`).
