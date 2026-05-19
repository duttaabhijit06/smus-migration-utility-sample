"""Seed Glue ETL job — RDS Postgres → S3 curated Parquet.

This is the script body uploaded to ``s3://<data-bucket>/scripts/<prefix>-rds-to-parquet.py``
by ``seed/glue/create.sh`` and registered as the ``<prefix>-rds-to-parquet``
Glue job (glueetl, Glue version 4.0). The job reads the two seed RDS
tables (``customers`` and ``products``) over the seed JDBC Glue
connection and writes them as Parquet partitions into the curated zone
of the seed data bucket.

Outputs:
    s3://<data-bucket>/curated/customers/   -- Parquet
    s3://<data-bucket>/curated/products/    -- Parquet

The Glue catalog tables ``<prefix>_customers_parquet`` and
``<prefix>_products_parquet`` are pre-registered (empty) in the
``<prefix>-db-curated`` database by ``seed/glue/create.sh``. This job is
what populates them.

Job parameters (passed from create.sh via ``--default-arguments``):
    --JOB_NAME            (set automatically by Glue)
    --glue_connection_jdbc <prefix>-jdbc-conn
    --data_bucket         <prefix>-glue-data-<account>-<region>
    --rds_database        seeddb (the JDBC connection's database name)
    --catalog_db_curated  <prefix>-db-curated
    --customers_table     <prefix>_customers_parquet
    --products_table      <prefix>_products_parquet
"""

# pylint: disable=import-error
import sys

from awsglue.context import GlueContext
from awsglue.dynamicframe import DynamicFrame
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext


def _read_table(glue, args, table_name):
    """Read a single Postgres table over the seed JDBC connection.

    Returns a Glue DynamicFrame. The Glue connection's
    ``JDBC_CONNECTION_URL`` already names the database, so we only need
    to specify ``dbtable`` here.
    """
    return glue.create_dynamic_frame.from_options(
        connection_type="postgresql",
        connection_options={
            "useConnectionProperties": "true",
            "connectionName": args["glue_connection_jdbc"],
            "dbtable": f"public.{table_name}",
        },
        transformation_ctx=f"read_{table_name}",
    )


def _write_parquet(glue, dyf, args, prefix, db_table_name):
    """Write a DynamicFrame as Parquet under ``s3://<bucket>/curated/<prefix>/``.

    Updates the matching Glue catalog table on every run so a schema
    evolution in the source RDS automatically lands as a catalog
    update; without this, downstream queries against the curated table
    would see stale column metadata.
    """
    target = f"s3://{args['data_bucket']}/curated/{prefix}/"
    glue.write_dynamic_frame.from_options(
        frame=dyf,
        connection_type="s3",
        format="parquet",
        connection_options={"path": target},
        format_options={"compression": "snappy"},
        transformation_ctx=f"write_{prefix}",
    )


def main():
    args = getResolvedOptions(
        sys.argv,
        [
            "JOB_NAME",
            "glue_connection_jdbc",
            "data_bucket",
            "rds_database",
            "catalog_db_curated",
            "customers_table",
            "products_table",
        ],
    )

    sc = SparkContext()
    glue = GlueContext(sc)
    job = Job(glue)
    job.init(args["JOB_NAME"], args)

    customers_dyf = _read_table(glue, args, "customers")
    products_dyf = _read_table(glue, args, "products")

    _write_parquet(glue, customers_dyf, args, "customers", args["customers_table"])
    _write_parquet(glue, products_dyf, args, "products", args["products_table"])

    job.commit()


if __name__ == "__main__":
    main()
