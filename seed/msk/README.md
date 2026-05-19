# `seed/msk/` — Amazon MSK Seed_Service_Module

Stand up a small Amazon MSK cluster in the same AWS account the
Migration_Tool targets so the migration tool's MSK inventory step
(`steps/inventory/msk/`) and the AWS Glue `KAFKA` connection registered
by `seed/glue/create.sh --phase=2` have a real cluster and bootstrap
broker string to point at.

This module satisfies Requirements 20.9, 20.13, 20.19, 20.29, and 20.31
of the same-account seed provisioning spec.

## What this module creates

| Resource | Name | Notes |
|---|---|---|
| MSK cluster | `${SBX_SEED_NAME_PREFIX}-msk-cluster` | Mode is configurable via `seed.config.json`'s `.msk.mode`. Default `serverless` (cheapest); `provisioned` uses 2 brokers of class `kafka.t3.small` — the smallest broker count MSK accepts (one broker per AZ subnet) per Requirement 20.19 and task 24.8. |
| Sample Kafka topic | `${SBX_SEED_NAME_PREFIX}-events` | NOT created by this module; recorded in state with `status: "deferred_to_operator"`. See [Topic-creation caveat](#topic-creation-caveat). |

Both resource names begin with `${SBX_SEED_NAME_PREFIX}-` so this module
satisfies the resource-name prefix gate in Requirement 20.29.

## Bootstrap-broker contract (the glue/phase-2 contract)

The single most important output of this module is the Kafka bootstrap
broker string. After `create.sh` succeeds it persists this string to:

```
.services.msk.resources.bootstrap_brokers
```

inside `./seed/seed.state.json`. The `seed/glue/create.sh --phase=2`
script reads it via the seed library's state-get helper:

```bash
SBX_MSK_BOOTSTRAP="$(sbx_state_get '.services.msk.resources.bootstrap_brokers')"
```

and uses that string as the `KAFKA_BOOTSTRAP_SERVERS` property of the
`KAFKA` Glue connection it creates (see `design.md` §"Provisioning
order"). This is the only Seed_Script-internal data dependency between
two modules and is the reason `provision.sh` invokes
`glue/create.sh --phase=1 → … → msk/create.sh → … → glue/create.sh
--phase=2` rather than running glue in a single phase.

If you re-run `glue/create.sh --phase=2` before this module has
populated `bootstrap_brokers`, glue phase 2 halts with a clear error
naming the empty-state path; that failure is the contract working as
intended.

## AWS CLI commands the module issues

`create.sh` (in apply mode):

| Verb | Purpose |
|---|---|
| `aws kafka list-clusters-v2 --cluster-name-filter <name>` | Idempotency — discover an existing cluster with the prefix-gated name before any `create-*` (Requirement 20.13). |
| `aws kafka create-cluster-v2` | Serverless mode (default). Issued only when no existing cluster matched. |
| `aws kafka create-cluster` | Provisioned mode (`.msk.mode = "provisioned"`). 2 brokers of class `kafka.t3.small` (the smallest broker count MSK accepts — one broker per AZ subnet) per Requirement 20.19 and task 24.8. |
| `aws kafka describe-cluster-v2` | Bounded poll loop (60 polls × 30 s = up to 30 min) waiting for `State == ACTIVE`. Skipped in dry-run. |
| `aws kafka get-bootstrap-brokers` | Read the bootstrap broker string and persist it to `seed.state.json`. |

`teardown.sh` (in apply mode, gated by Requirement 20.31):

| Verb | Purpose |
|---|---|
| `aws kafka delete-cluster --cluster-arn <arn>` | Issued only after BOTH (a) the recorded cluster name begins with `${SBX_SEED_NAME_PREFIX}-`, AND (b) the recorded ARN is present in `seed.state.json`. |

In dry-run, every command above is printed with the `DRY-RUN: ` prefix
via the `sbx_aws` helper and not executed; the state file is not
mutated.

## Inputs from `seed/seed.config.json`

| Path | Type | Default | Purpose |
|---|---|---|---|
| `.aws_region` | string | required | Resolved into `SBX_REGION` by `provision.sh`. Used as `--region` on every `aws kafka` call. |
| `.source_account_id` | string | required | Same-account contract check (Requirement 20.28). |
| `.seed_name_prefix` | string | required | Prefixes every created resource name. |
| `.msk.mode` | `serverless` \| `provisioned` | `serverless` | Selects the request shape. |
| `.msk.kafka_version` | string | `3.6.0` | Used only in provisioned mode. |
| `.msk.vpc_subnet_ids` | string[] | `[]` | Required in apply mode (both modes). |
| `.msk.security_group_ids` | string[] | `[]` | Required in apply mode (both modes). |

The two VPC arrays are required in apply mode because both Serverless
and Provisioned MSK request shapes need subnets + security groups. In
dry-run an empty VPC config is acceptable so the operator can audit the
would-be commands before populating real subnet/SG IDs.

## Identifiers persisted to `seed/seed.state.json`

`create.sh` writes (using `sbx_state_set_service msk`):

```json
{
  "services": {
    "msk": {
      "status": "provisioned",
      "resources": {
        "cluster": {
          "name": "${SBX_SEED_NAME_PREFIX}-msk-cluster",
          "arn":  "arn:aws:kafka:<region>:<account>:cluster/...",
          "mode": "serverless"
        },
        "bootstrap_brokers": "b-1.<host>:9098,b-2.<host>:9098,...",
        "topics": [
          { "name": "${SBX_SEED_NAME_PREFIX}-events",
            "status": "deferred_to_operator" }
        ]
      }
    }
  }
}
```

`teardown.sh` does NOT itself prune state; the parent
`./seed/teardown.sh` orchestrator flips `services.msk.status` to
`torn_down` and clears `services.msk.resources` after this module
returns 0.

## Topic-creation caveat

The AWS CLI does not currently expose a control-plane verb to create
Kafka topics on an MSK cluster (neither `aws kafka create-topic` nor any
equivalent). Topic creation is a data-plane operation and requires
running the `kafka-topics.sh` script from a host inside the cluster's
VPC, authenticated against the cluster's chosen auth mode (SASL/IAM for
Serverless; SASL/IAM, SASL/SCRAM, or mTLS for Provisioned).

Because of that, this module **records the planned sample topic name in
`seed.state.json` with `status: "deferred_to_operator"` rather than
attempting to create it.** A `STATUS:` line on every `create.sh` run
documents the deferral in the per-invocation log. The Migration_Tool's
MSK inventory step (`steps/inventory/msk/`) only invokes
`aws kafka list-clusters-v2`, so the absence of an actual topic does not
affect migration-tool exercise.

If you need the topic for a downstream test (for example a Glue job that
actually reads from MSK), run the operator follow-up below from a host
inside the cluster VPC:

```bash
# Read the bootstrap brokers persisted by this module:
BOOTSTRAP="$(jq -r '.services.msk.resources.bootstrap_brokers' \
    ./seed/seed.state.json)"
TOPIC="$(jq -r '.services.msk.resources.topics[0].name' \
    ./seed/seed.state.json)"

# Create the topic (Serverless / SASL/IAM example):
kafka-topics.sh --bootstrap-server "$BOOTSTRAP" \
    --command-config /path/to/client.properties \
    --create --topic "$TOPIC" \
    --partitions 1 --replication-factor 3
```

`teardown.sh` does NOT explicitly delete the topic for the same reason —
there is no AWS CLI verb. `aws kafka delete-cluster` cascades all topic
data on the AWS side, so this asymmetry has no operational consequence.

## Idempotency (Requirement 20.13)

`create.sh` calls `aws kafka list-clusters-v2 --cluster-name-filter
${SBX_SEED_NAME_PREFIX}-msk-cluster` BEFORE any `create-cluster*` verb. When a
cluster with that exact name already exists, the module:

1. Reuses the existing ARN.
2. Adopts the existing cluster's `ClusterType` as the authoritative mode
   (so a config knob toggle cannot misclassify what is already deployed).
3. Skips the `create-cluster*` call entirely.
4. Still re-reads bootstrap brokers and re-writes
   `.services.msk.resources` so a subsequent dry-run / re-run sees
   freshly-validated state.

A second `--apply` invocation immediately after a successful first run
therefore issues zero `aws kafka create-*` commands.

## Post-migration idempotency (Requirement 20.32)

This module never invokes `aws datazone create-*` and never references
the SMUS_Domain ID or Admin_Project ID recorded in
`./config/migration.config.json`. A re-run of `create.sh` after the
Migration_Tool has run is a no-op for SMUS state.

## Same-account contract (Requirement 20.28)

`create.sh` and `teardown.sh` both call `sbx_assert_same_account`
immediately after `sbx_init`. That helper compares
`source_account_id` between `./seed/seed.config.json` and (when
present) `./config/migration.config.json` and halts with a non-zero
exit BEFORE any state-changing AWS CLI command if the values disagree.

## Run modes

```bash
# Dry-run (default):
bash ./seed/msk/create.sh

# Apply:
bash ./seed/msk/create.sh --apply

# Teardown (dry-run):
bash ./seed/msk/teardown.sh

# Teardown (apply, gated by prefix + state-file membership):
bash ./seed/msk/teardown.sh --apply
```

`--apply` and `--dry-run` are mutually exclusive (Requirement 20.4 —
enforced by `sbx_init` in `./seed/_lib/common.sh`); passing both exits
64.

## References

- Requirements 20.9 (Seed_Service_Module shape), 20.13 (idempotency on
  re-run), 20.19 (MSK seed sizing), 20.29 (resource-name prefix
  gating), 20.31 (prefix + state-file deletion gating).
- `design.md` §"`msk/create.sh`" and §"Provisioning order" for the
  glue-phase-2 bootstrap-broker contract.
- AWS docs:
  [`aws kafka create-cluster-v2`](https://docs.aws.amazon.com/cli/latest/reference/kafka/create-cluster-v2.html),
  [`aws kafka get-bootstrap-brokers`](https://docs.aws.amazon.com/cli/latest/reference/kafka/get-bootstrap-brokers.html).
