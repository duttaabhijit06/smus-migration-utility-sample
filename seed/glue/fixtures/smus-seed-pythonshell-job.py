"""Seed Glue pythonshell job — customers CSV → S3 curated Parquet.

Uploaded to ``s3://<data-bucket>/scripts/<prefix>-pythonshell-job.py``
by ``seed/glue/create.sh`` (phase=foundation) and registered as the
``<prefix>-pythonshell-job`` Glue pythonshell job. Pythonshell jobs run
a single Python file with the standard library and a small set of
preinstalled wheels (boto3, pandas, numpy, pyarrow).

This job reads ``s3://<data_bucket>/customers/customers.csv`` via
boto3, parses it with pandas, and writes a Parquet file back to
``s3://<data_bucket>/curated/customers_csv_parquet/customers.parquet``
using ``pandas.DataFrame.to_parquet`` (Snappy by default with pyarrow).

The post-resequencing crawler (phase=crawler) then discovers the
``customers_csv_parquet/`` folder and catalogs the resulting table.

Job arguments (received via ``sys.argv``; pythonshell does NOT use
getResolvedOptions):

    --data_bucket         <prefix>-glue-data-<account>-<region>
"""

import argparse
import io
import sys

import boto3
import pandas as pd


def _parse_args(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--data_bucket", required=True)
    # JOB_NAME is auto-injected by Glue and harmless to ignore here.
    parser.add_argument("--JOB_NAME", default=None)
    # Tolerate any extra Glue-injected flags rather than failing on them.
    args, _ = parser.parse_known_args(argv)
    return args


def main():
    args = _parse_args(sys.argv[1:])
    bucket = args.data_bucket

    s3 = boto3.client("s3")
    src_key = "customers/customers.csv"
    dst_key = "curated/customers_csv_parquet/customers.parquet"

    # Pull the CSV into memory. The seed customers fixture is tiny
    # (~3 rows) so a single GetObject is sufficient.
    obj = s3.get_object(Bucket=bucket, Key=src_key)
    df = pd.read_csv(io.BytesIO(obj["Body"].read()))

    # Convert to Parquet in-memory and upload. pandas.to_parquet needs
    # pyarrow (preinstalled in the pythonshell runtime).
    parquet_buffer = io.BytesIO()
    df.to_parquet(parquet_buffer, engine="pyarrow", compression="snappy", index=False)
    parquet_buffer.seek(0)

    s3.put_object(Bucket=bucket, Key=dst_key, Body=parquet_buffer.getvalue())
    print(
        f"seed pythonshell job: wrote {len(df)} customers from "
        f"s3://{bucket}/{src_key} to s3://{bucket}/{dst_key}"
    )


if __name__ == "__main__":
    main()
