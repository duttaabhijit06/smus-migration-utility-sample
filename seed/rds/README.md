# Seed RDS module

Provisions a small Amazon RDS Postgres instance (db.t3.micro, single-AZ, 20 GiB GP3) backing the seed `<prefix>-rds-to-parquet` Glue ETL job that lifts RDS rows into curated S3 Parquet under `s3://<data-bucket>/curated/{customers,products}/`. The fixture loaded into the database is `seed/rds/fixtures/seed.sql` — two tables (`customers` × 50 rows, `products` × 25 rows).

## Resources created

Every name begins with `${SBX_SEED_NAME_PREFIX}-`:

| Resource | Name | Notes |
| --- | --- | --- |
| DB subnet group | `<prefix>-rds-subnet-group` | Spans the seed VPC subnets read from `.rds.subnet_ids` (or `.msk.vpc_subnet_ids` as a fallback). |
| Security group | `<prefix>-rds-sg` | Allows `5432/tcp` ingress from the seed VPC's CIDR (read via `aws ec2 describe-vpcs`). |
| DB instance | `<prefix>-postgres` | Postgres `16.x` (default minor for the major), `db.t3.micro`, 20 GiB GP3, single-AZ, not publicly accessible. Master username `seedadmin`; master password generated via `python3 -m secrets.token_urlsafe(18)` and persisted to state. Skip-final-snapshot on delete. |
| IAM role | `<prefix>-rds-seeder-role` | Disposable. Attached to the seeder Lambda. Trusts `lambda.amazonaws.com`; carries `AWSLambdaVPCAccessExecutionRole`. Deleted at the end of `create.sh`. |
| Lambda function | `<prefix>-rds-seeder` | Disposable. Python 3.11, 256 MB, 60 s timeout, vendors `pg8000` (pure-Python Postgres client; chosen over `psycopg2` because no compiled wheels are needed and it packages cleanly from any host OS). VPC-attached to the same subnets + SG as the RDS instance. Invoked once synchronously to load the SQL fixture, then deleted. |

## AWS CLI verbs used

`create.sh`:

- `aws rds describe-db-engine-versions --engine postgres --default-only` — resolve the current default engine version for the configured major (e.g. `16` → `16.3`).
- `aws ec2 describe-vpcs` — read the seed VPC's CIDR for the SG rule.
- `aws rds describe-db-subnet-groups` / `aws rds create-db-subnet-group` — idempotent subnet group create.
- `aws ec2 describe-security-groups` / `aws ec2 create-security-group` / `aws ec2 authorize-security-group-ingress` — idempotent SG create + 5432 rule.
- `aws rds describe-db-instances` / `aws rds create-db-instance` — idempotent instance create.
- `aws rds describe-db-instances` (poll) — wait for `DBInstanceStatus == available` (≤ 15 min budget at 30 s intervals).
- `aws iam create-role` / `aws iam attach-role-policy` — disposable seeder role.
- `aws lambda create-function` (or `update-function-code` on re-run) — disposable seeder Lambda. The deployment package is built in a `mktemp -d` directory: `lambda_function.py` + `pip install -t <dir> pg8000`, then `zip -r`.
- `aws lambda invoke --invocation-type RequestResponse --payload file://<tempfile>` — synchronous one-shot invoke. The payload includes the host, port, db name, master username, master password, and the SQL fixture body. Tempfile (not `/dev/stdin`) per bug fix 1b.
- `aws lambda delete-function` + `aws iam delete-role` — clean up the disposable seeder.

`teardown.sh` (strict reverse):

- `aws lambda delete-function` + `aws iam delete-role` — best-effort cleanup of any seeder leftovers.
- `aws rds delete-db-instance --skip-final-snapshot --delete-automated-backups`.
- `aws rds describe-db-instances` (poll) — wait for `DBInstanceNotFoundFault` (≤ 15 min).
- `aws ec2 delete-security-group` — retry-with-backoff (12 attempts × 15 s) because RDS holds the SG ARN for ~2 min after `delete-db-instance` returns; the first attempt typically fails with `DependencyViolation`.
- `aws rds delete-db-subnet-group`.

## Persisted state shape

After `--apply` succeeds, `services.rds.resources` in `./seed/seed.state.json`:

```json
{
  "status": "provisioned",
  "resources": {
    "instance_id": "<prefix>-postgres",
    "endpoint": "<prefix>-postgres.<random>.<region>.rds.amazonaws.com",
    "port": 5432,
    "db_name": "seeddb",
    "master_username": "seedadmin",
    "master_password": "<24-char-url-safe-token>",
    "subnet_group_name": "<prefix>-rds-subnet-group",
    "security_group_id": "sg-...",
    "security_group_name": "<prefix>-rds-sg",
    "engine": "postgres",
    "engine_version": "16.3",
    "seeder_lambda_arn": null
  }
}
```

`seeder_lambda_arn` is held briefly during the seed-load phase and nulled in the final state write to document that the disposable resource was cleaned up.

### **`master_password` is sensitive**

The master password is stored in `./seed/seed.state.json` in plaintext (the seed deliberately avoids Secrets Manager to keep the bash-only contract simple). **Operators MUST treat `seed.state.json` as sensitive**: do not commit it, do not share it, and consider chmoding it `0600` on shared boxes. The downstream Glue JDBC connection (`<prefix>-jdbc-conn` from `seed/glue/`) reads the password from this state file when its `ConnectionProperties.PASSWORD` field is wired in.

## Dry-run vs apply

- **Default is dry-run.** `bash seed/rds/create.sh` prints every would-be AWS CLI command with the `DRY-RUN:` prefix and writes nothing to AWS or `seed.state.json`. The master password column is rendered as `<REDACTED>` in the dry-run audit log.
- **`--apply`** issues all of the verbs listed above, generates a real password via `python3 -m secrets.token_urlsafe(18)`, and persists state.
- `--apply` and `--dry-run` are mutually exclusive (Requirement 20.4).

State writes (including the master password) are gated behind `sbx_apply_mode` (project-wide bug fix 1a) — dry-run will not record `provisioned` or any password to the state file.

## Idempotency

A second `bash seed/rds/create.sh --apply` immediately after a successful first run issues exactly **zero** `aws rds create-*` and `aws ec2 create-security-group` commands. The seeder Lambda is rebuilt and re-invoked (the SQL fixture's `ON CONFLICT (id) DO NOTHING` clauses make the seed-load itself idempotent), and then the seeder is deleted again.

## Teardown safety + retry-with-backoff

Teardown is gated by **both** the prefix gate and the state-file gate (Requirement 20.31). The security-group delete is retried with backoff because RDS only releases its hold on the SG ARN a couple minutes after `delete-db-instance` returns — if the SG delete still fails after the 3-minute budget, the script logs a warning and continues so the subnet group and any other downstream resources still get cleaned up.
