# Inventory — Amazon CloudWatch

## 1. Purpose

Discover every CloudWatch alarm, dashboard, and log group in the
source account and write a canonical inventory document. The step is
read-only by construction and is part of the inventory phase under
`steps/inventory/`. It is addressable via `--step inventory.cloudwatch`
and never runs as part of the main `--from` / `--to` range.

## 2. AWS CLI commands issued

| Command | Mode | Notes |
|---|---|---|
| `aws cloudwatch describe-alarms --region "$MT_AWS_REGION"` | both | Read-only. Returns metric alarms (`MetricAlarms[]`) and composite alarms (`CompositeAlarms[]`); both are merged into the inventory under `kind: "alarm"`. |
| `aws cloudwatch list-dashboards --region "$MT_AWS_REGION"` | both | Read-only. Each entry surfaces with `kind: "dashboard"`. |
| `aws logs describe-log-groups --region "$MT_AWS_REGION"` | both | Read-only. CloudWatch Logs uses the `logs` command group; each entry surfaces with `kind: "log-group"`. |

The pre-execution scanner rejects any verb outside `{list, get, describe}` (Requirements 18.1, 18.2). All three verbs above are on the allowlist.

## 3. Inputs from `MT_*` env vars

| Variable | Required | Source | Use |
|---|---|---|---|
| `MT_AWS_REGION` | yes | `config/migration.config.json` (`aws_region`) | Passed to all three AWS calls. Missing → `STATUS: missing_var MT_AWS_REGION`, exit 64. |
| `MT_SOURCE_ACCOUNT_ID` | optional | `config/migration.config.json` (`source_account_id`) | Populates `account_id` in the output JSON. When unset, the value is the literal string `"unknown"`. |
| `MT_WORKDIR` | optional | orchestrator | Resolves the `steps/_lib/common.sh` source path. Defaults to the script's repo root. |

## 4. Output schema

| Path | Shape |
|---|---|
| `steps/inventory/cloudwatch/outputs/inventory.json` | Canonical inventory document with merged alarms + dashboards + log groups. |

```json
{
  "service": "cloudwatch",
  "fetched_utc": "2026-05-04T18:22:11Z",
  "region": "us-east-1",
  "account_id": "111111111111",
  "items": [
    { "name": "<alarm-name>",     "arn": "<alarm-arn>",     "kind": "alarm",     "raw": { /* MetricAlarms[] or CompositeAlarms[] entry */ } },
    { "name": "<dashboard-name>", "arn": "<dashboard-arn>", "kind": "dashboard", "raw": { /* DashboardEntries[] entry */ } },
    { "name": "<log-group-name>", "arn": "<log-group-arn>", "kind": "log-group", "raw": { /* logGroups[] entry */ } }
  ],
  "counts": {
    "total": 25,
    "alarms": 8,
    "dashboards": 4,
    "log_groups": 13
  }
}
```

In dry-run no inventory file is written; the script prints
`DRY-RUN: write <path>` instead so the run log records the intent
without on-disk side effects (Requirement 18.3).

## 5. Recommendation

**Stay outside SMUS.** CloudWatch is the AWS-native observability
plane and continues to capture metrics, logs, and alarms for every
service the Migration_Tool brings into SMUS. There is no first-party
SMUS onboarding path for alarms, dashboards, or log groups. Migrated
Glue jobs, MWAA workflows, and Lambda functions emit to the same
CloudWatch namespaces as before; SMUS users observe them through the
existing CloudWatch console (and through the SMUS UI's link-out, where
applicable).

## 6. Citations

- AWS_Docs_MCP: [Amazon CloudWatch — What is Amazon CloudWatch?](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/WhatIsCloudWatch.html) — canonical entry point for the CloudWatch user guide; describes the metric, alarm, and dashboard model and the `DescribeAlarms` / `ListDashboards` APIs used here.
- AWS_Docs_MCP: [Amazon CloudWatch Logs — What is Amazon CloudWatch Logs?](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/WhatIsCloudWatchLogs.html) — canonical entry point for the CloudWatch Logs user guide; describes the log group model and the `DescribeLogGroups` API used here.
- Reference_Document section: **"Inventory step responsibilities"** in `design.md` (the per-service inventory table that names `aws cloudwatch describe-alarms`, `aws cloudwatch list-dashboards`, and `aws logs describe-log-groups` for the CloudWatch inventory step). The Reference_Document at `SageMaker Unified Studio - Migration Answers.md` lists Amazon CloudWatch in its Customer Context header and frames it as observability infrastructure that continues to operate under SMUS — see section **"4. Best Path to Bring Existing Datasets, Glue Jobs, and ML Assets"** sub-heading **"Key Principle: No Migration Required for Running Workloads"** and the references to CloudWatch logs and Spark UI in the SMUS observability discussion.
