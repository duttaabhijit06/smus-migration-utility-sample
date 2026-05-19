# Inventory — Amazon QuickSight

## 1. Purpose

Discover every Amazon QuickSight dashboard, dataset, and analysis in
the source account and write a canonical inventory document. The step
is read-only by construction and is part of the inventory phase under
`steps/inventory/`. It is addressable via `--step inventory.quicksight`
and never runs as part of the main `--from` / `--to` range.

## 2. AWS CLI commands issued

| Command | Mode | Notes |
|---|---|---|
| `aws sts get-caller-identity --query Account --output text` | conditional | Only when `MT_SOURCE_ACCOUNT_ID` is unset. The `get` verb is on the read-only allowlist (Requirement 18.1). Used solely to resolve `--aws-account-id` for the QuickSight calls below. |
| `aws quicksight list-dashboards --aws-account-id <id> --region "$MT_AWS_REGION"` | both | Read-only. Each entry surfaces with `kind: "dashboard"`. |
| `aws quicksight list-data-sets --aws-account-id <id> --region "$MT_AWS_REGION"` | both | Read-only. Each entry surfaces with `kind: "data-set"`. |
| `aws quicksight list-analyses --aws-account-id <id> --region "$MT_AWS_REGION"` | both | Read-only. Each entry surfaces with `kind: "analysis"`. |

The pre-execution scanner rejects any verb outside `{list, get, describe}` (Requirements 18.1, 18.2). All four verbs above are on the allowlist.

## 3. Inputs from `MT_*` env vars

| Variable | Required | Source | Use |
|---|---|---|---|
| `MT_AWS_REGION` | yes | `config/migration.config.json` (`aws_region`) | Passed to every QuickSight call. Missing → `STATUS: missing_var MT_AWS_REGION`, exit 64. |
| `MT_SOURCE_ACCOUNT_ID` | preferred | `config/migration.config.json` (`source_account_id`) | Used as `--aws-account-id` for every QuickSight call. When unset, the script falls back to `aws sts get-caller-identity --query Account --output text`. |
| `MT_WORKDIR` | optional | orchestrator | Resolves the `steps/_lib/common.sh` source path. Defaults to the script's repo root. |

## 4. Output schema

| Path | Shape |
|---|---|
| `steps/inventory/quicksight/outputs/inventory.json` | Canonical inventory document with merged dashboards + datasets + analyses. |

```json
{
  "service": "quicksight",
  "fetched_utc": "2026-05-04T18:22:11Z",
  "region": "us-east-1",
  "account_id": "111111111111",
  "items": [
    { "name": "<dashboard-name>", "arn": "<dashboard-arn>", "kind": "dashboard", "raw": { /* DashboardSummaryList[] entry */ } },
    { "name": "<data-set-name>",  "arn": "<data-set-arn>",  "kind": "data-set",  "raw": { /* DataSetSummaries[] entry */ } },
    { "name": "<analysis-name>",  "arn": "<analysis-arn>",  "kind": "analysis",  "raw": { /* AnalysisSummaryList[] entry */ } }
  ],
  "counts": {
    "total": 12,
    "dashboards": 4,
    "data_sets": 5,
    "analyses": 3
  }
}
```

In dry-run no inventory file is written; the script prints
`DRY-RUN: write <path>` instead so the run log records the intent
without on-disk side effects (Requirement 18.3). When dry-run is
combined with an unset `MT_SOURCE_ACCOUNT_ID`, the script renders the
would-be QuickSight calls with the placeholder `--aws-account-id ACCOUNT-ID-PLACEHOLDER` so the dry-run audit trail is still well-formed.

## 5. Recommendation

**Reference from SMUS workflows.** QuickSight is natively integrated
into SageMaker Unified Studio: the QuickSight blueprint, when enabled
on the SMUS_Domain, provisions a project-scoped QuickSight folder with
permission syncing and pre-configured Athena / Redshift data sources.
Existing dashboards, datasets, and analyses inventoried by this step
stay in their current QuickSight account; SMUS workflows reference
them either directly (via the integrated QuickSight folder) or by
refreshing the underlying datasets after ETL completes. There is no
need to re-create QuickSight assets inside SMUS.

## 6. Citations

- AWS_Docs_MCP: [Amazon QuickSight — What is Amazon QuickSight?](https://docs.aws.amazon.com/quicksight/latest/user/welcome.html) — canonical entry point for the QuickSight user guide; describes the dashboard, dataset, and analysis model and the `ListDashboards` / `ListDataSets` / `ListAnalyses` APIs used here.
- AWS_Docs_MCP: [Amazon QuickSight in SageMaker Unified Studio (Admin)](https://docs.aws.amazon.com/sagemaker-unified-studio/latest/adminguide/amazon-quicksight.html) — describes the QuickSight blueprint, the project-scoped folder, and the permission-syncing model that motivates the `Reference from SMUS workflows` recommendation.
- Reference_Document section: **"7. Integrating Unified Studio Workflows with QuickSight Dashboards"** in `SageMaker Unified Studio - Migration Answers.md`. This section is the canonical source for the recommendation: it documents that QuickSight is natively integrated into SMUS, that existing dashboards stay in QuickSight, and that ETL pipelines refresh the underlying datasets via standard QuickSight APIs from inside SMUS workflows.
- Reference_Document section: **"Inventory step responsibilities"** in `design.md` (the per-service inventory table that names `aws quicksight list-dashboards`, `list-data-sets`, and `list-analyses` for the QuickSight inventory step).
