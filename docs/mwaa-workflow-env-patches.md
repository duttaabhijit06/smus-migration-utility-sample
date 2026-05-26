# MWAA Workflows Environment — Manual Patch Reference

> **Audience:** Operators with an existing SMUS domain stack who hit MWAA env
> creation errors before the latest CFN updates landed. New stacks deployed
> from `cfn/master-stack.yaml` already include all of these — you should not
> need this guide.

This page captures the three live patches the SMUS bootstrap team applied to
make the `OnDemand Workflows` environment creatable end-to-end. The Create
flow currently fails for three different reasons, all addressed here.

Replace the placeholders below with values from your account/domain:

| Placeholder           | Where to find it                                                                  |
| --------------------- | --------------------------------------------------------------------------------- |
| `<ACCOUNT_ID>`        | `aws sts get-caller-identity --query Account`                                     |
| `<REGION>`            | Region of the domain (e.g. `us-east-1`)                                           |
| `<DOMAIN_ID>`         | `aws datazone list-domains --query 'items[?name==\`<DOMAIN_NAME>\`].id'`          |
| `<PROFILE_ID>`        | `aws datazone list-project-profiles --domain-identifier <DOMAIN_ID>`              |
| `<WORKFLOWS_BP_ID>`   | `aws datazone list-environment-blueprints --domain-identifier <DOMAIN_ID> --managed --query 'items[?name==\`Workflows\`].id'` |
| `<PROJECT_USER_ROLE>` | `datazone_usr_role_<PROJECT_ID>_<ENV_ID>` (the IAM role attached to the project)  |
| `<PROJECT_ID>`        | The DataZone project id (e.g. `aws datazone list-projects ...`)                   |
| `<KMS_KEY_ARN>`       | `aws datazone get-environment-blueprint-configuration --domain-identifier <DOMAIN_ID> --environment-blueprint-identifier <TOOLING_BP_ID> --query 'regionalParameters."<REGION>".KmsKeyArn'` (or read from CFN output `oSUSBPToolingKMSKeyArn`) |
| `<TOOLING_BUCKET>`    | `amazon-datazone-tooling-<ACCOUNT_ID>-<REGION>-<STACK_SUFFIX>`                    |
| `<SUBNET_IDS>`        | Comma-joined private subnets (same as Tooling blueprint config)                   |
| `<VPC_ID>`            | VPC of the SMUS domain                                                            |

> All commands assume the AWS CLI v2 and a profile with admin-equivalent
> permissions over DataZone, IAM, and the Tooling KMS key.

---

## Patch 1 — Grant project user role MWAA web-access permissions

**Symptom:** The `Workflows` capability does not show up in the project's
"Compute" tab, or the env spinner never loads.

**Cause:** The default `datazone_usr_role_*` role is missing
`airflow:CreateWebLoginToken` and friends. SMUS' MWAA tile expects the project
user role to be able to mint web SSO tokens for the env.

```bash
aws iam put-role-policy \
  --profile <AWS_PROFILE> \
  --role-name <PROJECT_USER_ROLE> \
  --policy-name MWAAWebAccess \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Sid": "MWAAWebAccess",
        "Effect": "Allow",
        "Action": [
          "airflow:CreateWebLoginToken",
          "airflow:CreateCliToken",
          "airflow:GetEnvironment",
          "airflow:ListEnvironments",
          "airflow:ListTagsForResource"
        ],
        "Resource": "arn:aws:airflow:<REGION>:<ACCOUNT_ID>:environment/*"
      }
    ]
  }'
```

> The Lambda-managed `_attach_mwaa_web_access_policy` (Section 5 of
> `setup.py`) re-applies this policy and tag-filters it to envs tagged
> `AmazonDataZoneDomain=<DOMAIN_ID>` for new stacks. The block above is the
> broader equivalent if you are patching by hand.

---

## Patch 2 — Make the Workflows blueprint S3-encryption-aware

**Symptom:**

> "KMS key used for encrypting S3 bucket
> `amazon-datazone-tooling-<ACCOUNT_ID>-<REGION>-...` is not compatible with
> the encryption configuration (null) of the environment. Consider providing
> the same KMS key for environment encryption or use Amazon S3 Key or AWS
> Managed Key for bucket encryption."

**Cause:** The Workflows blueprint config did not pass `KmsKeyArn`, so MWAA's
`create-environment` left the env unencrypted, and the Tooling bucket has a
CMK requirement.

```bash
aws datazone put-environment-blueprint-configuration \
  --profile <AWS_PROFILE> \
  --region <REGION> \
  --domain-identifier <DOMAIN_ID> \
  --environment-blueprint-identifier <WORKFLOWS_BP_ID> \
  --enabled-regions <REGION> \
  --regional-parameters '{
    "<REGION>": {
      "S3Location": "s3://<TOOLING_BUCKET>",
      "Subnets":    "<SUBNET_IDS>",
      "VpcId":      "<VPC_ID>",
      "KmsKeyArn":  "<KMS_KEY_ARN>"
    }
  }' \
  --manage-access-role-arn arn:aws:iam::<ACCOUNT_ID>:role/<DOMAIN_MANAGE_ACCESS_ROLE> \
  --provisioning-role-arn  arn:aws:iam::<ACCOUNT_ID>:role/<DOMAIN_PROVISIONING_ROLE>
```

> If you already have the blueprint enabled and only want to update params,
> the call shape is the same — `put-environment-blueprint-configuration` is
> upsert-style.

---

## Patch 3 — Bump env class + worker/webserver counts on the project profile

**Symptoms (in order, as you fix them):**

1. `mw1.micro` is too small for non-trivial workloads — task queues stall.
2. `Resource handler returned message: "Invalid request provided: The web
   server count for environment class mw1.medium must be greater than 1."`

**Cause:** The blueprint defaults are `mw1.micro`, `maxWorkers=1`,
`min/maxWebservers=1`. Any class >= `mw1.medium` requires `>= 2` webservers.

The cleanest fix is a project-profile override (so every env created from this
profile inherits sane defaults). Profile updates via API are full-replace, so
fetch first, mutate, re-apply:

```bash
# 1. Snapshot the current profile
aws datazone get-project-profile \
  --profile <AWS_PROFILE> --region <REGION> \
  --domain-identifier <DOMAIN_ID> \
  --identifier <PROFILE_ID> \
  > current-profile.json

# 2. Edit current-profile.json — find the OnDemand Workflows entry under
#    environmentConfigurations[] and merge these into
#    configurationParameters.parameterOverrides:
#
#    [
#      { "name": "environmentClass", "value": "mw1.medium", "isEditable": true },
#      { "name": "maxWorkers",       "value": "5",          "isEditable": true },
#      { "name": "minWebservers",    "value": "2",          "isEditable": true },
#      { "name": "maxWebservers",    "value": "2",          "isEditable": true }
#    ]
#
#    Strip the read-only `resolvedParameters` block before re-submitting.
#    Drop the top-level `domainId`, `createdBy`, `createdAt`, `lastUpdatedAt`
#    fields and rename `id` -> `identifier` and `domainId` -> `domainIdentifier`
#    to match the update-project-profile shape.

# 3. Apply the patched payload
aws datazone update-project-profile \
  --profile <AWS_PROFILE> --region <REGION> \
  --cli-input-json file://current-profile.json
```

A reference Python helper that does the read/strip/patch/apply round-trip is
checked in at `.scratch/patch_profile.py` (replace the four constants at the
top).

> **Heads-up on portal editability:** Even with `IsEditable=true`, the SMUS
> portal honours the **blueprint**'s `isEditable` flag for these MWAA params,
> not the profile's. The portal still shows them as read-only. The override
> *is* respected when an env is provisioned from this profile, so the values
> above will be applied either way. CLI-based env creation can override
> further per-env.

---

## Verification checklist

After applying all three patches:

- [ ] The project user role has the `MWAAWebAccess` inline policy attached.
- [ ] `get-environment-blueprint-configuration` for `Workflows` returns a
      non-null `KmsKeyArn` matching the Tooling bucket CMK.
- [ ] `get-project-profile` shows the four parameter overrides on
      `OnDemand Workflows`.
- [ ] Creating an `OnDemand Workflows` env from the project succeeds and
      reaches `AVAILABLE` (allow ~25 minutes).
