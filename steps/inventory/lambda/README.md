# Inventory — AWS Lambda

## 1. Purpose

Discover every AWS Lambda function in the source account and write a
canonical inventory document. The step is read-only by construction
and is part of the inventory phase under `steps/inventory/`. It is
addressable via `--step inventory.lambda` and never runs as part of
the main `--from` / `--to` range.

## 2. AWS CLI commands issued

| Command | Mode | Notes |
|---|---|---|
| `aws lambda list-functions --region "$MT_AWS_REGION"` | both | Single read-only call. The pre-execution scanner in the runner rejects any verb outside `{list, get, describe}` (Requirements 18.1, 18.2). |

No other AWS CLI commands are issued.

## 3. Inputs from `MT_*` env vars

| Variable | Required | Source | Use |
|---|---|---|---|
| `MT_AWS_REGION` | yes | `config/migration.config.json` (`aws_region`) | Passed to `aws lambda list-functions --region`. Missing → `STATUS: missing_var MT_AWS_REGION`, exit 64. |
| `MT_SOURCE_ACCOUNT_ID` | optional | `config/migration.config.json` (`source_account_id`) | Populates `account_id` in the output JSON. When unset, the value is the literal string `"unknown"`. |
| `MT_WORKDIR` | optional | orchestrator | Resolves the `steps/_lib/common.sh` source path. Defaults to the script's repo root. |

The standard `--apply` / `--dry-run` flags are parsed by
`steps/_lib/common.sh`; default is dry-run when neither is given.

## 4. Output schema

The step writes one file in apply mode:

| Path | Shape |
|---|---|
| `steps/inventory/lambda/outputs/inventory.json` | Canonical inventory document (see below). |

```json
{
  "service": "lambda",
  "fetched_utc": "2026-05-04T18:22:11Z",
  "region": "us-east-1",
  "account_id": "111111111111",
  "items": [
    {
      "name": "<function-name>",
      "arn":  "<function-arn>",
      "kind": "function",
      "raw":  { /* full per-function record returned by aws lambda list-functions */ }
    }
  ],
  "counts": { "total": 42 }
}
```

In dry-run no inventory file is written; the script prints
`DRY-RUN: write <path>` instead so the run log records the intent
without on-disk side effects (Requirement 18.3).

## 5. Recommendation

**Reference from SMUS workflows.** Existing Lambda functions stay in
their current account and are referenced from SMUS-managed Airflow
DAGs (and other SMUS workflows) via `LambdaInvokeFunctionOperator` or
the Lambda HTTP/API surface. There is no first-party SMUS onboarding
path for Lambda runtime code; the inventory exists to give the
engineering team a documented list of every function the migrated
workflows may need to invoke.

## 6. Citations

- AWS_Docs_MCP: [AWS Lambda — Welcome](https://docs.aws.amazon.com/lambda/latest/dg/welcome.html) — canonical entry point for Lambda's developer guide; describes the function model, the `ListFunctions` API, and the runtime contract that SMUS workflows reference.
- Reference_Document section: **"Inventory step responsibilities"** in `design.md` (the per-service inventory table that names `aws lambda list-functions` for the Lambda inventory step). The Reference_Document at `SageMaker Unified Studio - Migration Answers.md` lists AWS Lambda in its Customer Context header and frames Lambda functions as resources that continue to run as-is alongside SMUS — see section **"4. Best Path to Bring Existing Datasets, Glue Jobs, and ML Assets"** sub-heading **"Key Principle: No Migration Required for Running Workloads"**.
