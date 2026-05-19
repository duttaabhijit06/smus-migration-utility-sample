"""Seed MWAA DAG — Glue references (jobs + connections).

This DAG is uploaded to the seed MWAA environment's DAG S3 bucket by
``seed/mwaa/create.sh`` (Task 24.12). It is the canonical sample DAG that
references BOTH the seed Glue jobs AND the seed Glue connections so that
Step 3's connection-rewrite path (Requirement 9.4) is exercised end-to-end
when the Migration_Tool walks the seed deployment.

Airflow 3 import surface:
    * TaskFlow API (``airflow.decorators.dag`` / ``airflow.decorators.task``).
    * AWS provider operators under ``airflow.providers.amazon.aws.*`` only
      (so that this DAG is *also* a Convertible DAG by Step 8's verdict
      logic — but its primary role is to exercise the Step 3 rewrite path,
      not the Step 8 conversion path).

The DAG passes the Glue connection NAMES through ``GlueJobOperator``'s
``script_args`` (which Step 3 inspects when rewriting the Glue connection
references on the migrated job script). The Glue jobs and connections
referenced here are the seed-prefixed resources created by
``seed/glue/create.sh`` (Task 24.5):

    * Jobs (Requirement 20.15): ``<prefix>-etl-job`` (glueetl) and
      ``<prefix>-pythonshell-job`` (pythonshell). At least one of these
      jobs is wired to the JDBC connection on the Glue side
      (Requirement 20.16); this DAG additionally references the JDBC
      and KAFKA connection NAMES from MWAA so Step 3's rewrite path
      sees the same connection names from both the Glue job's
      ``Connections`` field AND from the DAG's ``script_args``.
    * Connections (Requirement 20.15): ``<prefix>-jdbc-conn`` (JDBC),
      ``<prefix>-kafka-conn`` (KAFKA), ``<prefix>-network-conn``
      (NETWORK — exercises the ``skipped_unsupported`` verdict per
      Requirement 11.4).
"""

from __future__ import annotations

import os
from datetime import datetime

from airflow.decorators import dag, task
from airflow.providers.amazon.aws.operators.glue import GlueJobOperator

PREFIX = os.environ.get("SBX_SEED_NAME_PREFIX", "smus-mig-seed")
REGION = os.environ.get("AWS_REGION", "us-east-1")

# Seed Glue job names (Requirement 20.15).
ETL_JOB = f"{PREFIX}-etl-job"
PYTHONSHELL_JOB = f"{PREFIX}-pythonshell-job"

# Seed Glue connection names (Requirement 20.15). These are the names
# Step 4b registers as SMUS_Connections and Step 3 rewrites in the
# migrated Glue scripts; passing them through script_args here is what
# guarantees the connection-rewrite path is exercised by the seed
# (Requirement 9.4 + Requirement 20.16 + Requirement 20.24).
JDBC_CONN = f"{PREFIX}-jdbc-conn"
KAFKA_CONN = f"{PREFIX}-kafka-conn"
NETWORK_CONN = f"{PREFIX}-network-conn"


@dag(
    dag_id=f"{PREFIX}_glue_refs",
    description=(
        "Seed Glue-references DAG — references both Glue jobs and "
        "Glue connections so Step 3's connection-rewrite path runs."
    ),
    start_date=datetime(2025, 1, 1),
    schedule=None,
    catchup=False,
    tags=["seed", "glue-refs", "connection-rewrite"],
)
def glue_refs_dag() -> None:
    """Run the JDBC-bound ETL job, then the pythonshell job, then summarize."""

    run_etl_jdbc = GlueJobOperator(
        task_id="run_etl_jdbc",
        job_name=ETL_JOB,
        region_name=REGION,
        aws_conn_id="aws_default",
        wait_for_completion=True,
        # Pass the Glue connection names through script_args. Step 3's
        # rewrite path inspects job-side params for these connection
        # names and rewrites them to the matching SMUS_Connection names
        # from the Connection_Mapping_File (Requirement 9.4).
        script_args={
            "--glue_connection_jdbc": JDBC_CONN,
            "--glue_connection_kafka": KAFKA_CONN,
            "--glue_connection_network": NETWORK_CONN,
        },
    )

    run_pythonshell = GlueJobOperator(
        task_id="run_pythonshell",
        job_name=PYTHONSHELL_JOB,
        region_name=REGION,
        aws_conn_id="aws_default",
        wait_for_completion=True,
        script_args={
            "--glue_connection_jdbc": JDBC_CONN,
        },
    )

    @task
    def report_connection_refs() -> dict[str, str]:
        """Echo the connection names so the rewrite is observable in MWAA logs."""
        return {
            "jdbc": JDBC_CONN,
            "kafka": KAFKA_CONN,
            "network": NETWORK_CONN,
        }

    run_etl_jdbc >> run_pythonshell >> report_connection_refs()


glue_refs_dag()
