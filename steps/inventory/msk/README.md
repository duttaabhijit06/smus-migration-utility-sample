# Inventory — Amazon MSK / Apache Kafka

## 1. Purpose

Discover every Amazon MSK cluster (provisioned or serverless) in the
source account and write a canonical inventory document. The step is
read-only by construction and is part of the inventory phase under
`steps/inventory/`. It is addressable via `--step inventory.msk` and
never runs as part of the main `--from` / `--to` range.

## 2. AWS CLI commands issued

| Command | Mode | Notes |
|---|---|---|
| `aws kafka list-clusters-v2 --region "$MT_AWS_REGION"` | both | Read-only. The pre-execution scanner rejects any verb outside `{list, get, describe}` (Requirements 18.1, 18.2). The v2 surface returns provisioned and serverless clusters in a single response. |

No other AWS CLI commands are issued.

## 3. Inputs from `MT_*` env vars

| Variable | Required | Source | Use |
|---|---|---|---|
| `MT_AWS_REGION` | yes | `config/migration.config.json` (`aws_region`) | Passed to `aws kafka list-clusters-v2 --region`. Missing → `STATUS: missing_var MT_AWS_REGION`, exit 64. |
| `MT_SOURCE_ACCOUNT_ID` | optional | `config/migration.config.json` (`source_account_id`) | Populates `account_id` in the output JSON. When unset, the value is the literal string `"unknown"`. |
| `MT_WORKDIR` | optional | orchestrator | Resolves the `steps/_lib/common.sh` source path. Defaults to the script's repo root. |

## 4. Output schema

| Path | Shape |
|---|---|
| `steps/inventory/msk/outputs/inventory.json` | Canonical inventory document. |

```json
{
  "service": "msk",
  "fetched_utc": "2026-05-04T18:22:11Z",
  "region": "us-east-1",
  "account_id": "111111111111",
  "items": [
    {
      "name": "<cluster-name>",
      "arn":  "<cluster-arn>",
      "kind": "cluster",
      "raw":  { /* full record from aws kafka list-clusters-v2 ClusterInfoList[] */ }
    }
  ],
  "counts": { "total": 3 }
}
```

In dry-run no inventory file is written; the script prints
`DRY-RUN: write <path>` instead so the run log records the intent
without on-disk side effects (Requirement 18.3).

## 5. Recommendation

**Stay outside SMUS.** Amazon MSK is a managed messaging fabric. There
is no first-party SMUS onboarding path for Kafka clusters. Existing
producers and consumers continue to operate against the source account
directly; SMUS-managed Glue jobs that need to read from Kafka use the
`KAFKA`-typed SMUS_Connection registered by Step 4b (see
`steps/04b_glue-connections/README.md`), which references the same MSK
broker endpoints that the inventory captures here.

## 6. Citations

- AWS_Docs_MCP: [Amazon Managed Streaming for Apache Kafka — What is Amazon MSK?](https://docs.aws.amazon.com/msk/latest/developerguide/what-is-msk.html) — canonical entry point for the MSK developer guide; describes provisioned vs serverless clusters and the `ListClustersV2` API used here.
- Reference_Document section: **"Inventory step responsibilities"** in `design.md` (the per-service inventory table that names `aws kafka list-clusters-v2` for the MSK inventory step). The Reference_Document at `SageMaker Unified Studio - Migration Answers.md` lists Kafka / Amazon MSK in its Customer Context header and frames it as a service that continues to run outside SMUS — see section **"4. Best Path to Bring Existing Datasets, Glue Jobs, and ML Assets"** sub-heading **"Key Principle: No Migration Required for Running Workloads"**.
