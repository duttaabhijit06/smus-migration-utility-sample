"""Seed event generator Lambda handler.

Generates 100 synthetic events per invocation and writes them to either
the seed Kinesis stream or the seed MSK topic, depending on the value of
the `MODE` environment variable. This is what populates the firehose-fed
S3 Parquet output (see `seed/firehose/`).

Environment variables (set by `seed/data-gen/create.sh`):

    MODE                     "kinesis" | "msk"
    STREAM_NAME              kinesis stream name (kinesis mode)
    MSK_BOOTSTRAP_BROKERS    comma-separated SASL_SSL endpoints (msk mode)
    MSK_TOPIC                topic name (msk mode)
    AWS_REGION               injected by Lambda runtime; used to sign IAM auth

The MSK Lambda is shipped with `kafka-python` and
`aws-msk-iam-sasl-signer-python` vendored into the deployment package.
The kinesis Lambda only needs `boto3` (already in the runtime).

Invocation: triggered every minute by the EventBridge rule
`<prefix>-data-gen-schedule`. Each invocation handles exactly one batch
of 100 events; back-pressure is irrelevant for the seed scale.
"""

from __future__ import annotations

import datetime as _dt
import json
import logging
import os
import random
import uuid

logger = logging.getLogger()
logger.setLevel(logging.INFO)

EVENT_TYPES = ["click", "purchase", "view", "signup"]
BATCH_SIZE = 100


def _iso_utc_now() -> str:
    """Return RFC-3339 UTC timestamp with millisecond precision.

    Firehose's Glue-backed schema-conversion treats timestamp columns as
    `timestamp` Hive type; an ISO-8601 string with a trailing `Z` is the
    shape Firehose's OpenXJsonSerDe parses cleanly.
    """
    return _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="milliseconds").replace(
        "+00:00", "Z"
    )


def _build_event() -> dict:
    return {
        "event_id": str(uuid.uuid4()),
        "event_type": random.choice(EVENT_TYPES),
        "payload": f"seed-payload-{random.randint(1000, 9999)}",
        "timestamp": _iso_utc_now(),
    }


def _send_kinesis(events: list[dict]) -> int:
    import boto3  # part of the Lambda runtime

    stream_name = os.environ["STREAM_NAME"]
    client = boto3.client("kinesis")

    # Kinesis PutRecords accepts up to 500 records and 5 MB per call;
    # 100 small JSON records is well under both ceilings, so a single
    # call is sufficient.
    records = [
        {
            "Data": json.dumps(e).encode("utf-8"),
            "PartitionKey": e["event_id"],
        }
        for e in events
    ]
    resp = client.put_records(StreamName=stream_name, Records=records)
    failed = int(resp.get("FailedRecordCount", 0))
    if failed:
        logger.warning("kinesis put_records had %d failed records", failed)
    return len(records) - failed


def _ensure_msk_topic(brokers: str, topic: str) -> None:
    """Idempotent topic create; tolerates TopicAlreadyExistsError."""
    from kafka import KafkaAdminClient
    from kafka.admin import NewTopic
    from kafka.errors import TopicAlreadyExistsError
    from kafka.sasl.oauth import AbstractTokenProvider

    # The aws-msk-iam-sasl-signer-python package exports
    # MSKAuthTokenProvider as a *module* containing a top-level
    # `generate_auth_token(region)` function — NOT a class. We therefore
    # subclass kafka-python's AbstractTokenProvider and have it call
    # the module's free function. kafka-python 2.x asserts the provider
    # IS-A AbstractTokenProvider, so a plain duck-typed class fails.
    from aws_msk_iam_sasl_signer import MSKAuthTokenProvider

    region = os.environ.get("AWS_REGION", "us-east-1")

    class _IAMTokenProvider(AbstractTokenProvider):
        def token(self):
            tok, _ = MSKAuthTokenProvider.generate_auth_token(region)
            return tok

    admin = KafkaAdminClient(
        bootstrap_servers=brokers.split(","),
        security_protocol="SASL_SSL",
        sasl_mechanism="OAUTHBEARER",
        sasl_oauth_token_provider=_IAMTokenProvider(),
        client_id="seed-data-gen-admin",
    )
    try:
        admin.create_topics(
            new_topics=[NewTopic(name=topic, num_partitions=1, replication_factor=2)]
        )
        logger.info("created topic %s", topic)
    except TopicAlreadyExistsError:
        logger.info("topic %s already exists; skipping create", topic)
    finally:
        admin.close()


def _send_msk(events: list[dict]) -> int:
    from kafka import KafkaProducer
    from kafka.sasl.oauth import AbstractTokenProvider

    # See _ensure_msk_topic() above for why we DON'T subclass
    # MSKAuthTokenProvider — it's a module, not a class. kafka-python
    # requires the provider to be an AbstractTokenProvider subclass.
    from aws_msk_iam_sasl_signer import MSKAuthTokenProvider

    brokers = os.environ["MSK_BOOTSTRAP_BROKERS"]
    topic = os.environ["MSK_TOPIC"]
    region = os.environ.get("AWS_REGION", "us-east-1")

    _ensure_msk_topic(brokers, topic)

    class _IAMTokenProvider(AbstractTokenProvider):
        def token(self):
            tok, _ = MSKAuthTokenProvider.generate_auth_token(region)
            return tok

    # kafka-python's MSK_IAM auth uses the OAUTHBEARER SASL mechanism
    # backed by aws-msk-iam-sasl-signer-python. The signer mints a
    # short-lived token that the broker validates against IAM.
    producer = KafkaProducer(
        bootstrap_servers=brokers.split(","),
        security_protocol="SASL_SSL",
        sasl_mechanism="OAUTHBEARER",
        sasl_oauth_token_provider=_IAMTokenProvider(),
        client_id="seed-data-gen-producer",
        value_serializer=lambda v: json.dumps(v).encode("utf-8"),
        key_serializer=lambda k: k.encode("utf-8"),
    )

    sent = 0
    try:
        for event in events:
            producer.send(topic, key=event["event_id"], value=event)
            sent += 1
        producer.flush(timeout=30)
    finally:
        producer.close()
    return sent


def lambda_handler(event, context):  # noqa: ARG001
    mode = os.environ.get("MODE", "").lower()
    events = [_build_event() for _ in range(BATCH_SIZE)]

    if mode == "kinesis":
        sent = _send_kinesis(events)
    elif mode == "msk":
        sent = _send_msk(events)
    else:
        raise ValueError(f"unknown MODE={mode!r}; expected 'kinesis' or 'msk'")

    logger.info("seed event-generator: mode=%s sent=%d", mode, sent)
    return {"mode": mode, "sent": sent}
