# Inventory — Amazon SNS

## 1. Purpose

Discover every Amazon SNS topic and subscription in the source account
and write a canonical inventory document. The step is read-only by
construction and is part of the inventory phase under
`steps/inventory/`. It is addressable via `--step inventory.sns` and
never runs as part of the main `--from` / `--to` range.

## 2. AWS CLI commands issued

| Command | Mode | Notes |
|---|---|---|
| `aws sns list-topics --region "$MT_AWS_REGION"` | both | Read-only. The pre-execution scanner rejects any verb outside `{list, get, describe}` (Requirements 18.1, 18.2). |
| `aws sns list-subscriptions --region "$MT_AWS_REGION"` | both | Read-only. |

No other AWS CLI commands are issued.

## 3. Inputs from `MT_*` env vars

| Variable | Required | Source | Use |
|---|---|---|---|
| `MT_AWS_REGION` | yes | `config/migration.config.json` (`aws_region`) | Passed to both `list-*` calls. Missing → `STATUS: missing_var MT_AWS_REGION`, exit 64. |
| `MT_SOURCE_ACCOUNT_ID` | optional | `config/migration.config.json` (`source_account_id`) | Populates `account_id` in the output JSON. When unset, the value is the literal string `"unknown"`. |
| `MT_WORKDIR` | optional | orchestrator | Resolves the `steps/_lib/common.sh` source path. Defaults to the script's repo root. |

## 4. Output schema

| Path | Shape |
|---|---|
| `steps/inventory/sns/outputs/inventory.json` | Canonical inventory document with merged topics + subscriptions. |

```json
{
  "service": "sns",
  "fetched_utc": "2026-05-04T18:22:11Z",
  "region": "us-east-1",
  "account_id": "111111111111",
  "items": [
    {
      "name": "<topic-name-from-arn>",
      "arn":  "arn:aws:sns:us-east-1:111111111111:my-topic",
      "kind": "topic",
      "raw":  { /* full record from aws sns list-topics */ }
    },
    {
      "name": "arn:aws:sns:us-east-1:111111111111:my-topic:abc-123",
      "arn":  "arn:aws:sns:us-east-1:111111111111:my-topic:abc-123",
      "kind": "subscription",
      "raw":  { /* full record from aws sns list-subscriptions */ }
    }
  ],
  "counts": { "total": 8, "topics": 5, "subscriptions": 3 }
}
```

In dry-run no inventory file is written; the script prints
`DRY-RUN: write <path>` instead so the run log records the intent
without on-disk side effects (Requirement 18.3).

## 5. Recommendation

**Stay outside SMUS.** Amazon SNS is an in-place messaging service.
There is no first-party SMUS onboarding path for SNS topics or
subscriptions. Existing SNS publishers and subscribers continue to
operate against the source account directly; SMUS-managed Airflow
DAGs publish or subscribe via the standard AWS-provider operators
(for example `SnsPublishOperator`) without any SMUS-side configuration.

## 6. Citations

- AWS_Docs_MCP: [Amazon Simple Notification Service — Welcome](https://docs.aws.amazon.com/sns/latest/dg/welcome.html) — canonical entry point for SNS's developer guide; describes the topic and subscription model and the `ListTopics` / `ListSubscriptions` APIs used here.
- Reference_Document section: **"Inventory step responsibilities"** in `design.md` (the per-service inventory table that names `aws sns list-topics` and `aws sns list-subscriptions` for the SNS inventory step). The Reference_Document at `SageMaker Unified Studio - Migration Answers.md` lists Amazon SNS in its Customer Context header and frames it as a service that continues to run outside SMUS — see section **"4. Best Path to Bring Existing Datasets, Glue Jobs, and ML Assets"** sub-heading **"Key Principle: No Migration Required for Running Workloads"**.
