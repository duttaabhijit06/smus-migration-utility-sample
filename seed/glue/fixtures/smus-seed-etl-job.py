"""Seed Glue ETL job — orders CSV → S3 curated Parquet.

Uploaded to ``s3://<data-bucket>/scripts/<prefix>-etl-job.py`` by
``seed/glue/create.sh`` (phase=foundation) and registered as the
``<prefix>-etl-job`` glueetl job (Glue 4.0).

This job reads the seed orders CSV from
``s3://<data_bucket>/orders/`` (header row), applies a minimal type
coercion, and writes Snappy-compressed Parquet to
``s3://<data_bucket>/curated/orders_parquet/``. The post-resequencing
crawler (phase=crawler) then discovers the resulting parquet folder and
catalogs the table.

Job parameters (passed through ``--default-arguments`` from create.sh):
    --JOB_NAME            (set automatically by Glue)
    --data_bucket         <prefix>-glue-data-<account>-<region>
"""

# pylint: disable=import-error
import sys

from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.transforms import ApplyMapping
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext


def main():
    args = getResolvedOptions(sys.argv, ["JOB_NAME", "data_bucket"])

    sc = SparkContext()
    glue = GlueContext(sc)
    job = Job(glue)
    job.init(args["JOB_NAME"], args)

    bucket = args["data_bucket"]
    source_path = f"s3://{bucket}/orders/"
    target_path = f"s3://{bucket}/curated/orders_parquet/"

    # Read orders CSV (header row, comma separator). DynamicFrame infers
    # the column types from the header + values.
    orders_dyf = glue.create_dynamic_frame.from_options(
        connection_type="s3",
        connection_options={"paths": [source_path], "recurse": True},
        format="csv",
        format_options={"withHeader": True, "separator": ","},
        transformation_ctx="read_orders_csv",
    )

    # Minimal type coercion: numeric columns from string → int/double so
    # the parquet output has typed columns rather than all-string.
    typed_dyf = ApplyMapping.apply(
        frame=orders_dyf,
        mappings=[
            ("order_id", "string", "order_id", "int"),
            ("customer_id", "string", "customer_id", "int"),
            ("order_date", "string", "order_date", "string"),
            ("sku", "string", "sku", "string"),
            ("quantity", "string", "quantity", "int"),
            ("unit_price_usd", "string", "unit_price_usd", "double"),
            ("status", "string", "status", "string"),
        ],
        transformation_ctx="orders_typed",
    )

    # Write Snappy-compressed Parquet to the curated zone.
    glue.write_dynamic_frame.from_options(
        frame=typed_dyf,
        connection_type="s3",
        format="parquet",
        connection_options={"path": target_path},
        format_options={"compression": "snappy"},
        transformation_ctx="write_orders_parquet",
    )

    job.commit()


if __name__ == "__main__":
    main()
