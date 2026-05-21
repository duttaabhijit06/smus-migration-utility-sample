"""
Minimal cfn-response shim.

CloudFormation Custom Resources POST a JSON envelope back to a
pre-signed S3 URL passed in `event['ResponseURL']`. AWS publishes
`cfnresponse` for inline `ZipFile` Lambda code; for packaged code we
bundle our own minimal version here so we don't depend on an inline
runtime that may not be available.

See: https://docs.aws.amazon.com/cloudformation/latest/userguide/template-custom-resources-lambda.html
"""

from __future__ import annotations

import json
import logging
from typing import Any
from urllib.parse import urlparse
from urllib.request import Request, urlopen

LOG = logging.getLogger()

SUCCESS = "SUCCESS"
FAILED = "FAILED"


def send(  # noqa: PLR0913 — follows the published AWS shape
    event: dict,
    context: Any,
    status: str,
    data: dict | None = None,
    physical_id: str | None = None,
    reason: str | None = None,
    no_echo: bool = False,
) -> None:
    body = {
        "Status": status,
        "Reason": reason or f"See CloudWatch logs: {context.log_stream_name}",
        "PhysicalResourceId": physical_id or context.log_stream_name,
        "StackId": event["StackId"],
        "RequestId": event["RequestId"],
        "LogicalResourceId": event["LogicalResourceId"],
        "NoEcho": no_echo,
        "Data": data or {},
    }

    payload = json.dumps(body).encode("utf-8")
    headers = {
        "content-type": "",
        "content-length": str(len(payload)),
    }

    response_url = event["ResponseURL"]
    LOG.info("cfn_response status=%s host=%s", status, urlparse(response_url).netloc)

    req = Request(response_url, data=payload, headers=headers, method="PUT")
    with urlopen(req, timeout=20) as resp:  # noqa: S310 — caller-supplied URL is from CFN
        LOG.info("cfn_response http_status=%s", resp.status)
