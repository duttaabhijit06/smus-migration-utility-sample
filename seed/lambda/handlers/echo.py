"""Tiny event-echoing handler used by the seed Lambda module.

This handler is the second of the two ZIP-deployed seed Lambda functions
required by Requirement 20.20. It returns the inbound event verbatim so the
operator can verify, via `aws lambda invoke`, that:

  - the function deploys correctly,
  - the IAM execution role permits CloudWatch Logs writes (the function's
    invocation log records the echoed event),
  - and that downstream tooling that introspects Lambda return shapes (e.g.,
    Step Functions, EventBridge Pipes, the Migration_Tool's inventory
    pass) can deserialize the response.

The handler signature is the standard AWS Lambda Python contract:
`(event, context) -> Any`.
"""


def handler(event, context):  # noqa: ARG001 — context unused by design
    """Return the inbound event verbatim.

    Lambda accepts any JSON-serializable return value; echoing the event
    object preserves whatever shape the caller sent (dict, list, scalar,
    or `None`). No transformation is applied, by design — the seed
    function is meant to be the simplest possible round-trip target.
    """
    return event
