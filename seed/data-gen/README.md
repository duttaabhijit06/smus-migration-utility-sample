# Seed data-gen module

Provisions two on-schedule Lambdas that generate synthetic events into the seed Kinesis stream and MSK topic, plus an EventBridge rule firing every minute. The events are what populate the firehose-fed Parquet output in `s3://<data-bucket>/raw/{kinesis,msk}/dt=<hour>/`.

## Resources created

Every name begins with `${SBX_SEED_NAME_PREFIX}-`:

| Resource | Name | Notes |
| --- | --- | --- |
| IAM role | `<prefix>-data-gen-role` | Trusts `lambda.amazonaws.com`. Managed: `AWSLambdaBasicExecutionRole`, `AWSLambdaVPCAccessExecutionRole`. Inline `data-gen-write` (kinesis put + kafka cluster connect/write). |
| Lambda | `<prefix>-kinesis-data-gen` | Python 3.11, 256 MB, 60 s. VPC-attached (same subnets + SGs as MSK so it shares network policy). Env: `MODE=kinesis`, `STREAM_NAME=<prefix>-events`. |
| Lambda | `<prefix>-msk-data-gen` | Python 3.11, 256 MB, 60 s. Same VPC. Env: `MODE=msk`, `MSK_BOOTSTRAP_BROKERS=<...>`, `MSK_TOPIC=<prefix>-events`. Vendors `kafka-python` + `aws-msk-iam-sasl-signer-python`. |
| EventBridge rule | `<prefix>-data-gen-schedule` | `rate(1 minute)`. Two targets: the two Lambdas above. |

## Event shape

Every invocation generates 100 events of this shape:

```python
{
    "event_id": str(uuid.uuid4()),
    "event_type": random.choice(["click", "purchase", "view", "signup"]),
    "payload": "seed-payload-<NNNN>",
    "timestamp": "<iso-8601 utc with ms, trailing Z>",
}
```

The schema matches the Glue catalog tables `<prefix>_kinesis_events_parquet` and `<prefix>_msk_events_parquet` (registered by glue phase 1) — this is what makes Firehose's schema-converted Parquet output deserialise correctly.

## IAM permissions explained

`data-gen-write` (inline) policy:

| Statement | Actions | Resource | Purpose |
| --- | --- | --- | --- |
| `KinesisWrite` | `kinesis:PutRecord`, `kinesis:PutRecords`, `kinesis:DescribeStream` | `<kinesis-arn>` | The kinesis Lambda calls `boto3.client('kinesis').put_records(...)`. |
| `MSKControlPlane` | `kafka:GetBootstrapBrokers`, `kafka:DescribeCluster*` | `<msk-arn>` | `aws-msk-iam-sasl-signer-python` reads cluster metadata when minting an OAUTHBEARER token. |
| `MSKDataPlane` | `kafka-cluster:Connect`, `kafka-cluster:DescribeTopic*`, `kafka-cluster:WriteData`, `kafka-cluster:CreateTopic`, `kafka-cluster:DescribeGroup` | `<msk-arn>`, `<msk-arn>/<topic>/*` | `kafka-python`'s `KafkaAdminClient.create_topics` (idempotent, tolerates `TopicAlreadyExistsError`) and `KafkaProducer.send`. |

The managed `AWSLambdaVPCAccessExecutionRole` is required because both Lambdas attach to the seed VPC + SGs (matching MSK's networking). Without it, Lambda's ENI provisioning fails with `AccessDeniedException`.

## kafka-python + MSK IAM dependency

The MSK Lambda's deployment package vendors:

- `kafka-python>=2.0,<3.0` — pure Python, plays nicely with Lambda x86_64.
- `aws-msk-iam-sasl-signer-python` — pure Python; mints short-lived OAUTHBEARER tokens that the broker validates against IAM.

The handler wraps the signer in a `kafka.sasl.oauth.AbstractTokenProvider` subclass that calls the signer's free function and returns the token via `kafka-python`'s `sasl_oauth_token_provider` parameter:

```python
from kafka.sasl.oauth import AbstractTokenProvider
from aws_msk_iam_sasl_signer import MSKAuthTokenProvider

class _IAMTokenProvider(AbstractTokenProvider):
    def token(self):
        tok, _ = MSKAuthTokenProvider.generate_auth_token(region)
        return tok
```

Two import gotchas worth knowing:

1. `from aws_msk_iam_sasl_signer import MSKAuthTokenProvider` imports a **module**, not a class. You CANNOT subclass `MSKAuthTokenProvider` directly — Python raises `TypeError: module() takes at most 2 arguments`. Call `MSKAuthTokenProvider.generate_auth_token(region)` as a free function instead.
2. `kafka-python` 2.x asserts that `sasl_oauth_token_provider` IS-A `kafka.sasl.oauth.AbstractTokenProvider`. A duck-typed class with a `.token()` method passes runtime checks but fails the connection setup with `AssertionError: sasl_oauth_token_provider must implement kafka.sasl.oauth.AbstractTokenProvider`. Always inherit from `AbstractTokenProvider`.

## MSK IAM resource ARN shape

MSK IAM data-plane permissions (`kafka-cluster:*`) require **typed** resource ARNs that don't share the `cluster/...` shape:

| Resource | ARN shape |
| --- | --- |
| Cluster | `arn:aws:kafka:<region>:<account>:cluster/<name>/<uuid>` |
| Topic | `arn:aws:kafka:<region>:<account>:topic/<name>/<uuid>/<topic-name>` |
| Consumer group | `arn:aws:kafka:<region>:<account>:group/<name>/<uuid>/<group-name>` |

Common bug worth avoiding: deriving the topic ARN by trimming the cluster ARN's tail with `${MSK_ARN%/*/*}/<topic>` — that produces `cluster/<name>/<topic>` with the wrong service segment (`cluster` vs `topic`) and the cluster UUID stripped. The correct pattern splits on `:cluster/` and rebuilds:

```bash
_msk_arn_prefix="${MSK_CLUSTER_ARN%:cluster/*}"
_msk_cluster_path="${MSK_CLUSTER_ARN##*:cluster/}"
_msk_topic_arn="${_msk_arn_prefix}:topic/${_msk_cluster_path}/${MSK_TOPIC}"
_msk_group_arn="${_msk_arn_prefix}:group/${_msk_cluster_path}/*"
```

If the policy uses the wrong shape, the broker accepts the IAM-OAUTHBEARER auth (control-plane perms suffice for that) but `CreateTopic` / `WriteData` fail with `TopicAuthorizationFailedError [Error 29]: Authorization failed`.

## AWS CLI verbs used

`create.sh`:

- `aws iam get-role` / `aws iam create-role` (with `--assume-role-policy-document file://<tempfile>`).
- `aws iam attach-role-policy` (×2 for the two managed policies; idempotent).
- `aws iam put-role-policy` (`data-gen-write` inline policy from a `mktemp` file).
- `aws lambda get-function` / `aws lambda create-function --vpc-config ...` (or `update-function-code` on re-run).
- `aws lambda wait function-active-v2` / `function-updated`.
- `aws events describe-rule` / `aws events put-rule --schedule-expression "rate(1 minute)"`.
- `aws events put-targets --targets file://<tempfile>`.
- `aws lambda add-permission` (×2; tolerates `ResourceConflictException` on re-run).

`teardown.sh`:

- `aws events disable-rule`.
- `aws events remove-targets --ids kinesis-data-gen msk-data-gen`.
- `aws events delete-rule`.
- `aws lambda delete-function` (×2).
- `aws iam list-attached-role-policies` + `detach-role-policy` (×2 managed policies).
- `aws iam list-role-policies` + `delete-role-policy`.
- `aws iam delete-role`.

## How to disable the schedule

The seed's data-gen schedule fires every minute, which adds up over a long-lived seed deployment. Three ways to stop it without tearing down the whole module:

1. `aws events disable-rule --name <prefix>-data-gen-schedule` — pauses; `enable-rule` to resume. State file unchanged.
2. `aws events remove-targets --rule <prefix>-data-gen-schedule --ids kinesis-data-gen msk-data-gen` — keeps the rule but stops invocations. Re-run `seed/data-gen/create.sh --apply` to put the targets back.
3. Full teardown: `bash seed/data-gen/teardown.sh --apply` (or the orchestrator's `bash seed/teardown.sh --apply --data-gen` if your `seed.sh` shortcuts it).

## Persisted state shape

```json
{
  "status": "provisioned",
  "resources": {
    "role_arn": "...",
    "role_name": "<prefix>-data-gen-role",
    "kinesis_function_name": "<prefix>-kinesis-data-gen",
    "kinesis_function_arn": "...",
    "msk_function_name": "<prefix>-msk-data-gen",
    "msk_function_arn": "...",
    "eventbridge_rule_name": "<prefix>-data-gen-schedule",
    "eventbridge_rule_arn": "..."
  }
}
```

## Dry-run vs apply

- **Default is dry-run.** The dry-run audit log shows the would-be IAM calls, the would-be `pip install -t` invocation, the would-be `lambda create-function` calls, and the EventBridge plumbing. Nothing is built or uploaded.
- **`--apply`** builds both ZIPs (the MSK ZIP via `pip install -t <tmpdir>`), creates the Lambdas, the rule, and the targets.
- State writes are gated behind `sbx_apply_mode` (project-wide bug fix 1a).
