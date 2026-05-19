"""Seed MWAA DAG — Blocked.

This DAG is uploaded to the seed MWAA environment's DAG S3 bucket by
``seed/mwaa/create.sh`` (Task 24.12). It is the canonical "Blocked" sample
DAG referenced by Requirement 20.24 and Requirement 15.4: it deliberately
includes at least one Non_AWS_Operator (``BashOperator`` from
``airflow.operators.bash``) so when the Migration_Tool runs Step 8
(``--convert-dags``) the DAG receives the verdict ``Blocked`` and NO YAML
workflow is produced for it.

Airflow 3 import surface:
    * TaskFlow API (``airflow.decorators.dag`` / ``airflow.decorators.task``).
    * AWS provider operators under ``airflow.providers.amazon.aws.*`` (used
      alongside the BashOperator so the Blocked verdict is asserted purely
      on the BashOperator presence, not on a missing AWS-provider chain).
    * ``airflow.operators.bash.BashOperator`` — the Non_AWS_Operator that
      drives the Blocked verdict.

The Glue job name is the seed-prefixed name created by
``seed/glue/create.sh`` (Task 24.5); the bash command runs against
container-local state so it does not require any external resource.
"""

from __future__ import annotations

import os
from datetime import datetime

from airflow.decorators import dag, task
from airflow.operators.bash import BashOperator
from airflow.providers.amazon.aws.operators.glue import GlueJobOperator

PREFIX = os.environ.get("SBX_SEED_NAME_PREFIX", "smus-mig-seed")
REGION = os.environ.get("AWS_REGION", "us-east-1")

PYTHONSHELL_JOB = f"{PREFIX}-pythonshell-job"


@dag(
    dag_id=f"{PREFIX}_blocked",
    description="Seed Blocked DAG — uses a non-AWS BashOperator.",
    start_date=datetime(2025, 1, 1),
    schedule=None,
    catchup=False,
    tags=["seed", "blocked", "non-aws-operator"],
)
def blocked_dag() -> None:
    """Run a bash side effect, then a seed Glue Python-shell job.

    The ``BashOperator`` is the Non_AWS_Operator that triggers the
    ``Blocked`` verdict from Step 8's compatibility scanner. The
    ``GlueJobOperator`` is included to demonstrate that a single
    Non_AWS_Operator anywhere in the DAG is sufficient for the Blocked
    verdict regardless of how many AWS-provider operators the DAG also
    uses.
    """

    bash_step = BashOperator(
        task_id="bash_side_effect",
        bash_command="echo 'seed: hello from BashOperator (non-AWS)'",
    )

    run_pythonshell = GlueJobOperator(
        task_id="run_pythonshell",
        job_name=PYTHONSHELL_JOB,
        region_name=REGION,
        aws_conn_id="aws_default",
        wait_for_completion=True,
    )

    @task
    def report_blocked() -> str:
        return f"{PREFIX}_blocked: blocked-verdict expected from Step 8"

    bash_step >> run_pythonshell >> report_blocked()


blocked_dag()
