"""Seed MWAA DAG — Convertible.

This DAG is uploaded to the seed MWAA environment's DAG S3 bucket by
``seed/mwaa/create.sh`` (Task 24.12). It is the canonical "Convertible"
sample DAG referenced by Requirement 20.24 and Requirement 15.4: every
operator it uses lives under ``airflow.providers.amazon.aws.*``, so when
the Migration_Tool runs Step 8 (``--convert-dags``) the DAG receives the
verdict ``Convertible`` and a YAML workflow definition is produced under
``steps/08_dag-yaml/outputs/yaml/<dag_name>.yaml``.

Airflow 3 import surface:
    * TaskFlow API (``airflow.decorators.dag`` / ``airflow.decorators.task``).
    * AWS provider operators under ``airflow.providers.amazon.aws.*``:
        - ``S3KeySensor``               (sensors.s3)
        - ``GlueJobOperator``           (operators.glue)
        - ``LambdaInvokeFunctionOperator`` (operators.lambda_function)
        - ``SnsPublishOperator``        (operators.sns)

These four operators are the canonical Convertible exemplars listed in
Task 24.12 / Requirement 20.24, so a single DAG covers the full
AWS-provider surface Step 8 must accept.

Resource references (resolved at DAG-parse time from environment
variables the MWAA environment exports):

    * ``SBX_SEED_NAME_PREFIX`` — the seed_name_prefix recorded in
      ``./seed/seed.config.json``. Defaults to ``smus-mig-seed`` so the
      DAG parses cleanly even before ``seed/provision.sh`` has run.
    * ``AWS_REGION`` — region of the seed deployment; defaults to
      ``us-east-1`` to match the example config.

The Glue job, Lambda function, SNS topic, and S3 paths referenced here
are the seed-prefixed resources created by the corresponding seed
modules (``seed/glue/create.sh``, ``seed/lambda/create.sh``,
``seed/sns/create.sh``). When those resources do not exist (for
example before ``seed/provision.sh`` has run), the DAG still parses —
Airflow's static parse only resolves operator imports and default
arguments; the live AWS calls fire only when MWAA executes the DAG.
"""

from __future__ import annotations

import os
from datetime import datetime

from airflow.decorators import dag, task
from airflow.providers.amazon.aws.operators.glue import GlueJobOperator
from airflow.providers.amazon.aws.operators.lambda_function import (
    LambdaInvokeFunctionOperator,
)
from airflow.providers.amazon.aws.operators.sns import SnsPublishOperator
from airflow.providers.amazon.aws.sensors.s3 import S3KeySensor

# DAG-parse-time configuration. Defaults align with seed.config.json.example
# so a DAG-parse smoke test (e.g. ``python -c "import dags.convertible_dag"``)
# succeeds without any seed-side environment variables present.
PREFIX = os.environ.get("SBX_SEED_NAME_PREFIX", "smus-mig-seed")
REGION = os.environ.get("AWS_REGION", "us-east-1")

# Seed resources (seed/glue/create.sh phase 1, seed/lambda/create.sh,
# seed/sns/create.sh — Requirements 20.15, 20.20, 20.17).
ETL_JOB = f"{PREFIX}-etl-job"
LAMBDA_FN = f"{PREFIX}-noop"
SNS_TOPIC_ARN_DEFAULT = f"arn:aws:sns:{REGION}:000000000000:{PREFIX}-orders"
SNS_TOPIC_ARN = os.environ.get("SBX_SNS_ORDERS_TOPIC_ARN", SNS_TOPIC_ARN_DEFAULT)

# Sample-data S3 bucket created by seed/glue/create.sh phase 1.
SAMPLE_DATA_BUCKET = f"{PREFIX}-sample-data-{REGION}"


@dag(
    dag_id=f"{PREFIX}_convertible",
    description="Seed Convertible DAG — only AWS-provider operators.",
    start_date=datetime(2025, 1, 1),
    schedule=None,
    catchup=False,
    tags=["seed", "convertible", "aws-only"],
)
def convertible_dag() -> None:
    """Sense an S3 manifest, run a Glue ETL job, invoke a Lambda, then publish to SNS."""

    wait_for_input = S3KeySensor(
        task_id="wait_for_input",
        bucket_name=SAMPLE_DATA_BUCKET,
        bucket_key="input/manifest.json",
        aws_conn_id="aws_default",
        timeout=60,
        poke_interval=10,
    )

    run_etl = GlueJobOperator(
        task_id="run_etl",
        job_name=ETL_JOB,
        region_name=REGION,
        aws_conn_id="aws_default",
        wait_for_completion=True,
    )

    invoke_postprocess = LambdaInvokeFunctionOperator(
        task_id="invoke_postprocess",
        function_name=LAMBDA_FN,
        aws_conn_id="aws_default",
        region_name=REGION,
    )

    publish_done = SnsPublishOperator(
        task_id="publish_done",
        target_arn=SNS_TOPIC_ARN,
        message=f"{PREFIX}_convertible: complete",
        aws_conn_id="aws_default",
        region=REGION,
    )

    @task
    def summarize() -> dict[str, str]:
        """Summary task implemented via the TaskFlow API."""
        return {
            "status": "complete",
            "prefix": PREFIX,
            "etl_job": ETL_JOB,
            "lambda_fn": LAMBDA_FN,
            "sns_topic_arn": SNS_TOPIC_ARN,
        }

    wait_for_input >> run_etl >> invoke_postprocess >> publish_done >> summarize()


convertible_dag()
