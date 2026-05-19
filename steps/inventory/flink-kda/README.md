# Inventory — Apache Flink / Kinesis Data Analytics

## 1. Purpose

Discover every Apache Flink / Amazon Kinesis Data Analytics for Apache
Flink application in the source account and write a canonical
inventory document. The step is read-only by construction and is part
of the inventory phase under `steps/inventory/`. It is addressable via
`--step inventory.flink-kda` and never runs as part of the main
`--from` / `--to` range.

## 2. AWS CLI commands issued

| Command | Mode | Notes |
|---|---|---|
| `aws kinesisanalyticsv2 list-applications --region "$MT_AWS_REGION"` | both | Read-only. The pre-execution scanner rejects any verb outside `{list, get, describe}` (Requirements 18.1, 18.2). Covers both Apache Flink and SQL applications under the v2 API. |

No other AWS CLI commands are issued.

## 3. Inputs from `MT_*` env vars

| Variable | Required | Source | Use |
|---|---|---|---|
| `MT_AWS_REGION` | yes | `config/migration.config.json` (`aws_region`) | Passed to `aws kinesisanalyticsv2 list-applications --region`. Missing → `STATUS: missing_var MT_AWS_REGION`, exit 64. |
| `MT_SOURCE_ACCOUNT_ID` | optional | `config/migration.config.json` (`source_account_id`) | Populates `account_id` in the output JSON. When unset, the value is the literal string `"unknown"`. |
| `MT_WORKDIR` | optional | orchestrator | Resolves the `steps/_lib/common.sh` source path. Defaults to the script's repo root. |

## 4. Output schema

| Path | Shape |
|---|---|
| `steps/inventory/flink-kda/outputs/inventory.json` | Canonical inventory document. |

```json
{
  "service": "flink-kda",
  "fetched_utc": "2026-05-04T18:22:11Z",
  "region": "us-east-1",
  "account_id": "111111111111",
  "items": [
    {
      "name": "<application-name>",
      "arn":  "<application-arn>",
      "kind": "application",
      "raw":  { /* full record from aws kinesisanalyticsv2 list-applications ApplicationSummaries[] */ }
    }
  ],
  "counts": { "total": 2 }
}
```

In dry-run no inventory file is written; the script prints
`DRY-RUN: write <path>` instead so the run log records the intent
without on-disk side effects (Requirement 18.3).

## 5. Recommendation

**Stay outside SMUS.** Apache Flink / KDA applications are stream
processors that run continuously. There is no first-party SMUS
onboarding path for Flink applications. Existing applications continue
to run in the source account; SMUS-managed workflows do not need to
re-host them.

## 6. Citations

- AWS_Docs_MCP: [Amazon Managed Service for Apache Flink — What is Amazon Managed Service for Apache Flink?](https://docs.aws.amazon.com/managed-flink/latest/java/what-is.html) — canonical entry point for the (renamed) Kinesis Data Analytics for Apache Flink developer guide; describes the application model and the `ListApplications` API used here.
- Reference_Document section: **"Inventory step responsibilities"** in `design.md` (the per-service inventory table that names `aws kinesisanalyticsv2 list-applications` for the Flink/KDA inventory step). The Reference_Document at `SageMaker Unified Studio - Migration Answers.md` lists Apache Flink / Kinesis Data Analytics in its Customer Context header and frames it as a service that continues to run outside SMUS — see section **"4. Best Path to Bring Existing Datasets, Glue Jobs, and ML Assets"** sub-heading **"Key Principle: No Migration Required for Running Workloads"**.
