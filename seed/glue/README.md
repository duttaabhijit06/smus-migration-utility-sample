# `seed/glue/` — AWS Glue Seed_Service_Module (FOUR-PHASE create)

Source-account Glue surface that the Migration_Tool's Glue-aware steps
(Step 3 connection-reference rewrite, Step 4 catalog discovery, Step 4b
connection registration) discover and migrate. Four-phase `create.sh`,
single `teardown.sh`, AWS CLI only, dispatched through the `sbx_*`
helpers in `seed/_lib/common.sh`.

The seed and the Migration_Tool share a single AWS account
(Requirement 20.28). This module is the source-side counterpart that
populates Glue databases, connections, jobs, a crawler, and a sample
S3 bucket; the Migration_Tool then discovers and migrates that content
INTO the SMUS_Domain it creates in the same account.

Validates Requirements: **20.7, 20.13, 20.15, 20.16, 20.29, 20.30,
20.31, 20.32**.

## Four-phase contract — why it exists

`create.sh` is dispatched FOUR times from `seed/provision.sh` because
the seed has three independent ordering constraints that cannot all be
satisfied by a single pass:

1. The Glue jobs must run against REAL DATA (CSV in S3, rows in RDS),
   so the data has to land in S3 / RDS BEFORE the jobs run.
2. The Glue crawler must run against REAL DATA in the curated zone,
   so the jobs have to write Parquet BEFORE the crawler runs.
3. The KAFKA Glue connection's `KAFKA_BOOTSTRAP_SERVERS` is mandatory
   at create time, so it cannot be authored until MSK has persisted
   `bootstrap_brokers` to `seed.state.json`.

The four phases break the dispatch into the smallest steps that satisfy
all three:

| Phase | When | What |
|------:|------|------|
| `--phase=foundation` | First, before everything else | S3 data bucket + sample CSV uploads, IAM roles, two Glue databases (`-db-raw`, `-db-curated`), JDBC connection (placeholder URL), NETWORK connection, glueetl + pythonshell jobs, **and runs both jobs** so `curated/orders_parquet/` and `curated/customers_csv_parquet/` are populated. |
| `--phase=rds-bridge` | After `seed/rds/` provisions Postgres | Re-creates the JDBC connection with the real RDS endpoint + master password (replacing the placeholder), registers `<prefix>-rds-to-parquet`, and **runs that job** so `curated/customers/` and `curated/products/` are populated. |
| `--phase=crawler` | After `seed/firehose/` and `seed/data-gen/` (every curated/* path now has data) | Creates the Glue crawler over the curated zone, runs it, and captures the discovered tables in state. |
| `--phase=kafka` | After `seed/msk/create.sh` has persisted `bootstrap_brokers` | KAFKA Glue connection bound to MSK's bootstrap brokers (`KAFKA_SSL_ENABLED=true`). Flips `glue.status` to `provisioned`. |

`teardown.sh` runs in a single pass (no `--phase` flag) and deletes
everything regardless of phase.

### Backwards-compat aliases

For any older caller that still passes the legacy two-phase flags:

| Legacy flag | Maps to | Notes |
|---|---|---|
| `--phase=1` | `--phase=foundation` | Emits `STATUS: warning deprecated_phase_alias …` |
| `--phase=2` | `--phase=kafka` | Emits `STATUS: warning deprecated_phase_alias …` |
| `--phase=all` | `--phase=foundation` | Direct-operator default; unchanged behavior |

This is the only Seed_Service_Module that runs in more than one phase.

## Status flow (`.services.glue.status`)

```
absent → pending → foundation_done → rds_bridge_done → crawler_done → provisioned → torn_down
```

| Value | Set by | Meaning |
|-------|--------|---------|
| `pending` | `create.sh --phase=foundation` (BEFORE any AWS create-*) | Foundation phase has started; identifiers not yet recorded. |
| `foundation_done` | `create.sh --phase=foundation` (after the last foundation step + jobs ran) | Foundation complete; etl + pythonshell jobs have run; curated/orders_parquet and curated/customers_csv_parquet exist. |
| `rds_bridge_done` | `create.sh --phase=rds-bridge` | JDBC connection rewired to real RDS; rds-to-parquet job registered and ran; curated/customers and curated/products exist. |
| `crawler_done` | `create.sh --phase=crawler` | Crawler has discovered tables in `<prefix>-db-curated`. |
| `provisioned` | `create.sh --phase=kafka` | All four phases complete; the module is fully provisioned. |
| `torn_down` | `teardown.sh` | All recorded resources have been deleted; `resources` reset to `{}`. |

The `--skip-completed` flag in `seed.sh` understands this lattice: it skips a
given phase iff its terminal status (or any later one) is recorded.

## Resource-name prefix gate (Requirement 20.29)

Every resource name created by this module begins with
`${SBX_SEED_NAME_PREFIX}-`:

```
<prefix>-glue-data-<account>-<region>  S3 sample-data bucket
<prefix>-db-raw                        Glue database (raw zone)
<prefix>-db-curated                    Glue database (curated zone)
<prefix>-crawler                       Glue crawler   (phase=crawler)
<prefix>-jdbc-conn                     Glue JDBC connection
<prefix>-network-conn                  Glue NETWORK connection
<prefix>-kafka-conn                    Glue KAFKA connection (phase=kafka)
<prefix>-etl-job                       Glue job (glueetl, --connections=<jdbc>)
<prefix>-pythonshell-job               Glue job (pythonshell)
<prefix>-rds-to-parquet                Glue job (glueetl, phase=rds-bridge)
<prefix>-glue-crawler-role             IAM role (Glue crawler)
<prefix>-glue-job-role                 IAM role (Glue jobs)
```

Note: this module no longer registers Glue catalog tables directly. The
two raw catalog tables (`<prefix>_kinesis_events_parquet`,
`<prefix>_msk_events_parquet`) are owned by `seed/firehose/` (which
needs them at delivery-stream-create time). The curated tables are
discovered by the crawler in `--phase=crawler` after the jobs have
written real Parquet — there are no longer any pre-registered curated
tables.

`teardown.sh` enforces the prefix gate as a destructive-action
precondition (Requirement 20.31).

## Same-account contract (Requirement 20.28)

Both `create.sh` and `teardown.sh` call `sbx_assert_same_account`
immediately after `sbx_init`.

## What this module does NOT do

- It does **not** create a SMUS_Domain or an Admin_Project
  (Requirement 20.30).
- It does **not** invoke any `aws datazone *` command.
- It does **not** target the SMUS_Domain ID or the Admin_Project ID
  recorded in `./config/migration.config.json` (Requirement 20.32).
- It does **not** register the firehose-fed raw Glue catalog tables
  any longer — `seed/firehose/create.sh` owns those. See
  `seed/firehose/README.md`.
- It does **not** create any Kafka topic on the MSK cluster.

## AWS CLI commands issued

### Phase: foundation (`create.sh --phase=foundation`)

| Step | Idempotency lookup | Mutating call (when missing) |
|------|--------------------|------------------------------|
| Sample-data bucket | `aws s3api head-bucket` | `aws s3api create-bucket` |
| Sample fixtures | — | `aws s3 cp` (`orders.csv`, `customers.csv`; `<prefix>-etl-job.py`, `<prefix>-pythonshell-job.py`) |
| IAM roles (×2) | `aws iam get-role` | `aws iam create-role` + `attach-role-policy` (managed) + `put-role-policy` (inline `s3-data-access`) |
| Glue databases (×2) | `aws glue get-database` | `aws glue create-database` |
| Glue JDBC connection | `aws glue get-connection` | `aws glue create-connection` (URL `jdbc:postgresql://placeholder.example.com:5432/seeddb`; rewired in phase=rds-bridge) |
| Glue NETWORK connection | `aws glue get-connection` | `aws glue create-connection` |
| Glue `glueetl` job | `aws glue get-job` | `aws glue create-job` (`Connections=<prefix>-jdbc-conn`, `--data_bucket` arg) |
| Glue `pythonshell` job | `aws glue get-job` | `aws glue create-job` (`--data_bucket` arg) |
| **Run etl job** | — | `aws glue start-job-run` + poll `aws glue get-job-run` until `JobRunState=SUCCEEDED` (15 min budget) |
| **Run pythonshell job** | — | `aws glue start-job-run` + poll `aws glue get-job-run` until `JobRunState=SUCCEEDED` (15 min budget) |

The two job runs are serial. The etl job reads `s3://<bucket>/orders/`
(CSV), applies type coercion, and writes
`s3://<bucket>/curated/orders_parquet/`. The pythonshell job reads
`s3://<bucket>/customers/customers.csv` via boto3 + pandas and writes
`s3://<bucket>/curated/customers_csv_parquet/customers.parquet` via
`pandas.to_parquet`.

In dry-run, the start-job-run + get-job-run calls are rendered as
`DRY-RUN: aws ...` without polling.

### Phase: rds-bridge (`create.sh --phase=rds-bridge`)

| Step | Idempotency lookup | Mutating call (when missing) |
|------|--------------------|------------------------------|
| Read RDS state | `sbx_state_get '.services.rds.resources.{endpoint,master_password,db_name}'` | — (halts with `STATUS: error rds_dependency_missing` if any is empty) |
| Delete placeholder JDBC | `aws glue get-connection` | `aws glue delete-connection` (only if it exists) |
| Recreate JDBC | — | `aws glue create-connection` (real RDS URL + password) |
| Glue rds-to-parquet job | `aws glue get-job` | `aws glue create-job` (`Connections=<prefix>-jdbc-conn`, full DefaultArguments) |
| **Run rds-to-parquet job** | — | `aws glue start-job-run` + poll `aws glue get-job-run` until SUCCEEDED |

The rds-to-parquet job reads the seed Postgres `customers` and
`products` tables over the JDBC connection and writes
`s3://<bucket>/curated/customers/` + `s3://<bucket>/curated/products/`
as Snappy Parquet.

### Phase: crawler (`create.sh --phase=crawler`)

| Step | Idempotency lookup | Mutating call (when missing) |
|------|--------------------|------------------------------|
| Glue crawler | `aws glue get-crawler` | `aws glue create-crawler` (`--database-name <prefix>-db-curated`; S3Targets: `curated/orders_parquet/`, `curated/customers_csv_parquet/`, `curated/customers/`, `curated/products/`; `--table-prefix <prefix>_`) |
| **Run crawler** | — | `aws glue start-crawler` + poll `aws glue get-crawler` until `State=READY` (5 min budget) |
| Capture tables | `aws glue get-tables --database-name <each db>` | — (best-effort) |

After this phase, the crawler has discovered up to 4 tables in
`<prefix>-db-curated` (depending on whether the prior phases produced
parquet at all four target paths).

### Phase: kafka (`create.sh --phase=kafka`)

| Step | Idempotency lookup | Mutating call (when missing) |
|------|--------------------|------------------------------|
| Bootstrap-broker read | `sbx_state_get '.services.msk.resources.bootstrap_brokers'` | — (halts with clear error if empty in apply mode) |
| Glue KAFKA connection | `aws glue get-connection` | `aws glue create-connection` (`ConnectionType=KAFKA`, `KAFKA_BOOTSTRAP_SERVERS=<bootstrap>`, `KAFKA_SSL_ENABLED=true`) |

If the bootstrap-broker read returns empty, kafka phase halts with a
clear error message naming the prerequisite step.

### Teardown (`teardown.sh`)

Single-pass deletion (unchanged from pre-resequencing): jobs (incl.
crawler) → connections (kafka first) → tables → databases → S3 bucket
→ IAM roles. See `teardown.sh` header comments for the rationale.

## Run modes

Default mode is dry-run (Requirement 20.2). `--apply` and `--dry-run`
together exit 64 (Requirement 20.4).

```bash
# Dry-run:
bash seed/glue/create.sh --phase=foundation --dry-run
bash seed/glue/create.sh --phase=rds-bridge --dry-run
bash seed/glue/create.sh --phase=crawler --dry-run
bash seed/glue/create.sh --phase=kafka --dry-run

# Apply mode (state-changing):
bash seed/glue/create.sh --phase=foundation --apply
bash seed/glue/create.sh --phase=rds-bridge --apply
bash seed/glue/create.sh --phase=crawler --apply
bash seed/glue/create.sh --phase=kafka --apply

# Teardown:
bash seed/glue/teardown.sh --dry-run
bash seed/glue/teardown.sh --apply
```

A direct operator invocation of `create.sh` without `--phase=` defaults
to `--phase=foundation`.

## Inputs read from `seed/seed.config.json`

| Key | Type | Used for |
|-----|------|----------|
| `aws_region` | string | `--region` on every `aws` call |
| `source_account_id` | string (12 digits) | Same-account contract |
| `seed_name_prefix` | string | Prefix on every created resource name |
| `glue.network_subnet_id` / `glue.network_security_group_id` / `glue.network_availability_zone` | string | NETWORK connection PhysicalConnectionRequirements |

## Persisted identifiers schema (`seed/seed.state.json`)

After each phase succeeds, `.services.glue.status` advances and the
`resources` sub-object is deep-merged. After all four phases, the
final shape is:

```json
{
  "phase": "all",
  "status": "provisioned",
  "resources": {
    "data_bucket": "<prefix>-glue-data-<account>-<region>",
    "databases": ["<prefix>-db-raw", "<prefix>-db-curated"],
    "connections": [
      "<prefix>-jdbc-conn",
      "<prefix>-network-conn",
      "<prefix>-kafka-conn"
    ],
    "crawler": "<prefix>-crawler",
    "jobs": [
      "<prefix>-etl-job",
      "<prefix>-pythonshell-job",
      "<prefix>-rds-to-parquet"
    ],
    "tables": [
      "<prefix>-db-curated.<prefix>_orders_parquet",
      "<prefix>-db-curated.<prefix>_customers_csv_parquet",
      "<prefix>-db-curated.<prefix>_customers",
      "<prefix>-db-curated.<prefix>_products"
    ],
    "iam_roles": {
      "crawler_role_arn": "arn:aws:iam::<account>:role/<prefix>-glue-crawler-role",
      "job_role_arn": "arn:aws:iam::<account>:role/<prefix>-glue-job-role"
    }
  }
}
```

The exact set of `tables` depends on what the crawler discovers; it is
best-effort — a re-run picks up tables the prior pass missed.

## Idempotency on re-run (Requirement 20.13)

A second `--apply` invocation of any phase issues exactly zero
`aws ... create-*` commands when every recorded identifier is found.
For phase=foundation, the etl + pythonshell job runs are NOT
re-attempted on a second pass that finds the jobs already exist — the
get-job lookup short-circuits the create-job AND the run is
considered a foundation responsibility that's only fired the first
time the job is created. Operator can re-run by passing
`--no-skip-completed` and using `aws glue start-job-run` directly.
(TODO: a future refactor could add an explicit "always re-run" toggle.)

## Post-migration idempotency (Requirement 20.32)

A `--apply` re-run of this module after the Migration_Tool has run is
a no-op against the SMUS surface; SMUS resources are simply not
addressed. Zero hits for `aws datazone` in either shell script.

## Fixtures

- `fixtures/orders.csv` — small CSV (3 rows × 7 cols).
- `fixtures/customers.csv` — small CSV (3 rows × 7 cols).
- `fixtures/<prefix>-etl-job.py` — glueetl job that reads
  `s3://<bucket>/orders/` and writes
  `s3://<bucket>/curated/orders_parquet/` as Snappy Parquet.
- `fixtures/<prefix>-pythonshell-job.py` — pythonshell job that reads
  `customers/customers.csv` and writes
  `curated/customers_csv_parquet/customers.parquet` via
  `pandas.to_parquet`.
- `fixtures/<prefix>-rds-to-parquet.py` — glueetl job that reads the
  seed RDS `customers` + `products` tables over JDBC and writes
  `curated/{customers,products}/` as Snappy Parquet.
- `fixtures/parquet/` — placeholder folder; drop a real `*.parquet`
  file here before running `create.sh --apply` if you want
  parquet-flavoured discovery up front.

## References

- Requirements: 20.7, 20.13, 20.15, 20.16, 20.29, 20.30, 20.31, 20.32.
- AWS docs:
  [`aws glue create-job`](https://docs.aws.amazon.com/cli/latest/reference/glue/create-job.html),
  [`aws glue start-job-run`](https://docs.aws.amazon.com/cli/latest/reference/glue/start-job-run.html),
  [`aws glue create-crawler`](https://docs.aws.amazon.com/cli/latest/reference/glue/create-crawler.html),
  [`aws glue create-connection`](https://docs.aws.amazon.com/cli/latest/reference/glue/create-connection.html).
