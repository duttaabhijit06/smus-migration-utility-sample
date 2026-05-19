# Amazon SNS Seed_Service_Module

This Seed_Service_Module stands up a lightweight, seed-grade Amazon SNS
surface in the same AWS account that the Migration_Tool will later target.
It is invoked by `./seed/provision.sh` between the `glue` (phase 1) and
`msk` modules (per the design's Mermaid graph in `design.md` §"Provisioning
order graph").

The module satisfies Requirements **20.9**, **20.13**, **20.17**, **20.29**,
and **20.31** — see the matrix at the bottom of this document.

## Purpose

The Migration_Tool's inventory phase enumerates SNS topics and subscriptions
via `aws sns list-topics` and `aws sns list-subscriptions` (see
`steps/inventory/sns/run.sh`, task 25.2). To exercise that path end-to-end
without entangling seed state with non-seed customer resources, this module
creates exactly **2 SNS topics** with **1 HTTPS subscription each**, all
prefixed with `${SBX_SEED_NAME_PREFIX}-` so seed-created topics are
unambiguously identifiable.

The HTTPS subscriptions point at a placeholder endpoint on `example.com`
(IETF-reserved per RFC 2606). SNS will deliver subscription-confirmation
requests but the placeholder server never confirms, so the subscriptions
remain in `PendingConfirmation` forever and **zero customer messages
flow** out of AWS. That is exactly the seed contract: a discoverable
inventory surface that never delivers.

## Resources created

| Resource | Name | Notes |
| --- | --- | --- |
| SNS topic | `${SBX_SEED_NAME_PREFIX}-orders` | Discovered by `aws sns list-topics` in inventory step 25.2 |
| SNS topic | `${SBX_SEED_NAME_PREFIX}-alerts` | Discovered by `aws sns list-topics` in inventory step 25.2 |
| HTTPS subscription | endpoint `https://example.com/${SBX_SEED_NAME_PREFIX}-orders` | One per `orders` topic. Stays in `PendingConfirmation`. |
| HTTPS subscription | endpoint `https://example.com/${SBX_SEED_NAME_PREFIX}-alerts` | One per `alerts` topic. Stays in `PendingConfirmation`. |

The two-topic count meets Requirement **20.17** ("at least 2 sample SNS
topics with at least one email or HTTPS subscription each").

## AWS CLI commands

### `create.sh` — `aws sns ...`

| Verb | When | Purpose |
| --- | --- | --- |
| `list-topics` | always (read-only) | Idempotency lookup per topic name. Filtered client-side via `jq` on the topic-name suffix of the ARN. |
| `list-subscriptions-by-topic` | always (read-only) | Idempotency lookup per topic for any pre-existing confirmed subscription. |
| `create-topic --name <prefix>-<topic>` | apply mode AND topic missing | Creates the topic. Skipped when a topic with the exact name already exists in the region. |
| `subscribe --topic-arn <arn> --protocol https --notification-endpoint <https://example.com/...>` | apply mode AND no confirmed subscription on the topic | Creates the no-op HTTPS subscription. Skipped when a confirmed subscription already exists on the topic. |

The two read-only verbs (`list-topics`, `list-subscriptions-by-topic`)
are issued **even in dry-run** because they are safe by construction
(Property 17 — read-only verb safety) and they are what makes the
idempotency contract correctly observable in dry-run output: the script
only prints `DRY-RUN: aws sns create-topic ...` lines for topics that
do not already exist in the account.

### `teardown.sh` — `aws sns ...`

| Verb | When | Purpose |
| --- | --- | --- |
| `delete-subscription --subscription-arn <arn>` | apply mode, per recorded subscription, best-effort | Removes the HTTPS subscription. Confirmed-only; pending-confirmation subscriptions cannot be deleted by ARN and are left for SNS to expire. |
| `delete-topic --topic-arn <arn>` | apply mode, per recorded topic, best-effort | Removes the topic. SNS cascades any remaining subscriptions on the topic. |

## Inputs (read from `seed.config.json` via SBX_* env vars)

| Env var | Source key in `seed.config.json` | Required |
| --- | --- | --- |
| `SBX_REGION` | `aws_region` | yes (validated `^[a-z]{2}-[a-z]+-\d$`) |
| `SBX_SOURCE_ACCOUNT_ID` | `source_account_id` | yes (validated 12 digits, must match `./config/migration.config.json`) |
| `SBX_SEED_NAME_PREFIX` | `seed_name_prefix` | yes (used as the prefix for every created resource name) |

The module reads these via `sbx_init` from `_lib/common.sh` and rejects a
missing/empty value with `STATUS: missing_var <NAME>` and exit 64
(Requirement **20.10**).

## Persisted identifiers (written to `seed.state.json`)

`create.sh` writes the following payload under `.services.sns` via
`sbx_state_set_service` (atomic deep-merge):

```json
{
  "status": "provisioned",
  "resources": {
    "topics": [
      {
        "name": "<prefix>-orders",
        "arn": "arn:aws:sns:<region>:<account>:<prefix>-orders",
        "subscriptions": [{ "arn": "arn:aws:sns:<region>:<account>:<prefix>-orders:<sub-id>" }]
      },
      {
        "name": "<prefix>-alerts",
        "arn": "arn:aws:sns:<region>:<account>:<prefix>-alerts",
        "subscriptions": [{ "arn": "arn:aws:sns:<region>:<account>:<prefix>-alerts:<sub-id>" }]
      }
    ]
  }
}
```

In dry-run, the topic ARN is the deterministic
`arn:aws:sns:<region>:<account>:<prefix>-<topic>` shape and the
subscription ARN is the placeholder string `PendingConfirmation` (the
subscription has not actually been created yet). In apply-mode, both
ARNs are real values returned by SNS.

`teardown.sh` rewrites `.services.sns.status` to `"torn_down"` after
processing all recorded topics. The topic array is preserved as-is so a
post-mortem can see what was deleted.

## Idempotency contract

A re-run of `create.sh --apply` after a successful first run issues
**zero `aws sns create-topic` calls** and **zero `aws sns subscribe`
calls** (Requirement **20.13**). Both branches are gated by the
read-only lookups above; when both lookups return a pre-existing match,
the corresponding state-changing call is skipped and the existing ARN
is recorded in the state file unchanged.

## Post-migration idempotency

This module never invokes `aws datazone create-*` and never references
the SMUS_Domain ID or the Admin_Project ID recorded in
`./config/migration.config.json` (Requirement **20.32**). It is therefore
safe to re-run after the Migration_Tool has run; the SMUS_Domain and any
SMUS_Connections the Migration_Tool created are unaffected.

## Same-account contract

`create.sh` and `teardown.sh` both call `sbx_assert_same_account` from
`_lib/common.sh` BEFORE any state-changing AWS CLI command. When
`./config/migration.config.json` exists and its `source_account_id`
disagrees with `seed.config.json`'s `source_account_id`, the module
emits `STATUS: error same_account_contract_violated` and exits 64
without issuing any `create-*` or `delete-*` call (Requirement **20.28**).

## Deletion gating (teardown)

Per Requirement **20.31**, every `aws sns delete-*` invocation in
`teardown.sh` MUST satisfy BOTH:

1. The topic name begins with `${SBX_SEED_NAME_PREFIX}-`.
2. AND the topic ARN is recorded in `seed.state.json` under
   `.services.sns.resources.topics[].arn`.

The teardown loop reads the state file as the authoritative inventory
(condition 2) and re-checks the prefix (condition 1) on every name BEFORE
issuing any `delete-*` call. Candidates that fail either check are
skipped with a `STATUS:` line and never deleted.

## Run modes

Both scripts share the standard SBX_* run-mode surface:

```
bash seed/sns/create.sh             # dry-run (default)
bash seed/sns/create.sh --apply     # apply mode
bash seed/sns/create.sh --dry-run   # explicit dry-run
bash seed/sns/teardown.sh           # dry-run (default)
bash seed/sns/teardown.sh --apply   # apply mode
```

Passing `--apply` and `--dry-run` together exits 64 with
`STATUS: error apply and dry-run are mutually exclusive` (Requirement
**20.4**, enforced in `sbx_init`).

In dry-run, every state-changing AWS CLI call is printed as a
`DRY-RUN: aws sns ...` line without execution. Read-only lookups
(`list-topics`, `list-subscriptions-by-topic`) are still issued so the
DRY-RUN output reflects the same go/no-go decision an apply-mode run
would make.

## Logs

Per `sbx_init`, every invocation writes a timestamped log to
`./seed/logs/run-<UTC_TIMESTAMP>.log` (Requirement **20.14**) capturing
all `STATUS:` lines, all `DRY-RUN:` lines (in dry-run), and the full
stdout/stderr of every `aws ...` invocation (in apply mode).

## Requirement matrix

| Requirement | How this module satisfies it |
| --- | --- |
| **20.9** | Folder layout `./seed/sns/{create.sh,teardown.sh,README.md}` matches the per-service Seed_Service_Module convention. |
| **20.13** | `create.sh` precedes every `create-topic` with `list-topics` and every `subscribe` with `list-subscriptions-by-topic`; pre-existing matches skip the corresponding state-changing call. |
| **20.17** | Two SNS topics (`<prefix>-orders`, `<prefix>-alerts`) with one HTTPS subscription each. |
| **20.29** | Every created resource name is prefixed with `${SBX_SEED_NAME_PREFIX}-`. |
| **20.31** | `teardown.sh` only deletes topics whose name begins with `${SBX_SEED_NAME_PREFIX}-` AND whose ARN is recorded in `seed.state.json`. |
