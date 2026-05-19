"""Tiny no-op handler used by the seed Lambda module.

This handler is intentionally minimal: it returns a constant payload and never
inspects the event. It exists so that the seed AWS Lambda module
(`seed/lambda/create.sh`) can deploy at least one ZIP-packaged function with
the smallest plausible code surface, satisfying Requirement 20.20 ("at least 2
sample Lambda functions, at least one of which SHALL be ZIP-deployed").

The handler signature is the standard AWS Lambda Python contract:
`(event, context) -> Any`.
"""


def handler(event, context):  # noqa: ARG001 — context unused by design
    """Return a constant ok payload.

    The return value is shaped as a JSON-serializable dict so that direct
    invocations via `aws lambda invoke` produce a tiny, deterministic
    payload that the operator can use to smoke-test the function after
    deployment.
    """
    return {"ok": True}
