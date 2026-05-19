#!/usr/bin/env bash
#
# steps/02_portability/run.sh — Step 2: Portability classification.
#
# Pure file generation. This step never calls AWS. The portability rule
# table is policy (not data discovered at runtime), so the table is
# embedded inline and rendered verbatim to outputs/portability-report.md.
#
# Behavior (Requirements 8.1, 8.2, 8.3, 8.4, 8.5):
#   - Apply mode writes the markdown report to outputs/portability-report.md
#     using a heredoc so the file is byte-for-byte the design.md table.
#   - Dry-run prints `DRY-RUN: write <path>` and creates no file.
#   - The same content is produced regardless of source-account state, so
#     re-running the step is naturally idempotent.

# shellcheck source=../_lib/common.sh
. "${MT_WORKDIR:-$(pwd)}/steps/_lib/common.sh"

set -euo pipefail

mt_init "02_portability" -- "$@"

mt_status started

OUT_PATH="$(mt_outputs_path portability-report.md)"

if mt_apply_mode; then
    cat >"$OUT_PATH" <<'PORTABILITY_REPORT_EOF'
# Portability Report

| Service | Label | Recommendation | Reference |
|---|---|---|---|
| AWS Glue (jobs, catalog) | Full automation | — | Steps 3, 4 |
| AWS Glue Data Catalog | Full automation | — | Step 4 |
| AWS Glue Connection | Full automation | — | Step 4b |
| Amazon MWAA (provisioned) | Full automation | — | Steps 6, 7 |
| S3 data buckets | Full automation | — | Step 5 |
| MWAA DAG bucket | Excluded | DAG code is extracted in Step 6 and committed to the configured code repository | — |
| AWS Lambda | Inventory only | Reference from SMUS workflows | Inventory/lambda |
| Amazon SNS | Inventory only | Stay outside SMUS | Inventory/sns |
| Amazon MSK / Kafka | Inventory only | Stay outside SMUS | Inventory/msk |
| Apache Flink / KDA | Inventory only | Stay outside SMUS | Inventory/flink-kda |
| Amazon CloudWatch | Inventory only | Stay outside SMUS | Inventory/cloudwatch |
| Amazon QuickSight | Inventory only | Reference from SMUS workflows | Inventory/quicksight |
PORTABILITY_REPORT_EOF
    mt_log "wrote ${OUT_PATH}"
else
    mt_dryrun "write ${OUT_PATH}"
fi

mt_status ok
exit 0
