"""
SMUS setup + teardown Lambda — Custom Resource entry point.

Responds to CloudFormation Custom Resource invocations
(`rPostDeploy`, `rPreDelete` in master-stack.yaml).

Dispatch:
    RequestType=Create + Action=setup     -> setup.run(props)
    RequestType=Update + Action=setup     -> setup.run(props)  (idempotent)
    RequestType=Delete + Action=setup     -> noop_success()    (rPostDeploy delete is a no-op)
    RequestType=Create + Action=teardown  -> noop_success()    (rPreDelete create is a no-op)
    RequestType=Update + Action=teardown  -> noop_success()
    RequestType=Delete + Action=teardown  -> teardown.run(props)

The split into two Custom Resources lets `rPostDeploy` block the rest of
the stack on Create (its DependsOn graph is reverse of `rPreDelete`'s,
and CFN deletes resources in reverse-dependency order — so `rPreDelete`
fires FIRST during stack delete).

CloudFormation expects `cfn_response.send` to be called within
`event['ResponseURL']`'s timeout (defaults to 1 hour). All long-running
operations are bounded; if any single boto3 call hangs the Lambda
timeout (15 min) is the backstop.
"""

from __future__ import annotations

import json
import logging
import os
import signal
import traceback

import cfn_response
import setup
import teardown

LOG = logging.getLogger()
LOG.setLevel(os.environ.get("LOG_LEVEL", "INFO"))


def _alarm_handler(signum, frame):  # type: ignore[no-untyped-def]
    """SIGALRM handler. Lambda kills the function at the timeout, but
    we set our own 60s-shorter alarm so we have time to send a FAILED
    response to CloudFormation before the kill — without this, CFN
    waits the full 1-hour ResponseURL timeout."""
    raise TimeoutError("Lambda alarm fired; about to be killed")


def handler(event, context):
    """CloudFormation Custom Resource entry point."""
    LOG.info("event=%s", json.dumps({k: v for k, v in event.items() if k != "ResponseURL"}))

    # Set an alarm slightly shorter than the Lambda timeout so we can
    # send a FAILED response before being killed.
    remaining_ms = context.get_remaining_time_in_millis()
    alarm_seconds = max(int(remaining_ms / 1000) - 30, 30)
    signal.signal(signal.SIGALRM, _alarm_handler)
    signal.alarm(alarm_seconds)

    request_type = event.get("RequestType", "")
    props = event.get("ResourceProperties", {}) or {}
    action = props.get("Action", "")

    try:
        if request_type in ("Create", "Update") and action == "setup":
            data = setup.run(props)
            cfn_response.send(event, context, cfn_response.SUCCESS, data, physical_id="rPostDeploy")
        elif request_type == "Delete" and action == "teardown":
            data = teardown.run(props)
            cfn_response.send(event, context, cfn_response.SUCCESS, data, physical_id="rPreDelete")
        else:
            # Create/Update on the teardown resource, or Delete on the
            # setup resource — both are no-ops by design.
            LOG.info("noop dispatch: request_type=%s action=%s", request_type, action)
            cfn_response.send(
                event, context, cfn_response.SUCCESS, {},
                physical_id=event.get("PhysicalResourceId") or f"noop-{action}",
            )
    except TimeoutError:
        LOG.error("Lambda alarm fired; sending FAILED response")
        cfn_response.send(
            event, context, cfn_response.FAILED,
            {"Error": "Lambda timed out before completing"},
            reason="Lambda timed out (see CloudWatch logs)",
        )
    except Exception as exc:
        LOG.exception("handler raised")
        cfn_response.send(
            event, context, cfn_response.FAILED,
            {"Error": str(exc), "Traceback": traceback.format_exc()},
            reason=f"{type(exc).__name__}: {exc}"[:1000],
        )
    finally:
        signal.alarm(0)
