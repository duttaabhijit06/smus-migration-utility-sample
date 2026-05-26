# MWAA Workflows Environment — Manual Patch Reference

> **Audience:** Operators with an existing SMUS domain stack who hit MWAA env
> creation errors before the latest CFN updates landed. New stacks deployed
> from `cfn/master-stack.yaml` already include all of these — you should not
> need this guide.

This page captures the four live patches the SMUS bootstrap team applied to
make the `OnDemand Workflows` environment creatable end-to-end and the
JupyterLab notebook session usable. The Create flow plus first-time
JupyterLab boot fail for four distinct reasons, all addressed here.

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

## Patch 2 — Switch the Tooling bucket from CMK to SSE-S3

**Symptom:**

> "KMS key used for encrypting S3 bucket
> `amazon-datazone-tooling-<ACCOUNT_ID>-<REGION>-...` is not compatible with
> the encryption configuration (null) of the environment. Consider providing
> the same KMS key for environment encryption or use Amazon S3 Key or AWS
> Managed Key for bucket encryption."

**Cause:** The Tooling bucket has CMK encryption (we used to set this in
`sus-blueprints-stack.yaml`), but DataZone provisions the MWAA env CFN stack
with `kmsKeyArn=""` regardless of what's set in the Workflows blueprint
regional parameters. We tested both `kmsKeyArn` and `KmsKeyArn` casing on
the blueprint config and a profile-level override — DataZone either silently
ignored the value or rejected it with "parameter not present in the
blueprint". Verified empirically by inspecting live env stack params (the
`kmsKeyArn` parameter is always empty even when set in blueprint config).

The fix MWAA's own error suggests is the only one that works: switch the
Tooling bucket to SSE-S3 (AWS-managed) instead of CMK.

```bash
aws s3api put-bucket-encryption \
  --profile <AWS_PROFILE> \
  --bucket <TOOLING_BUCKET> \
  --server-side-encryption-configuration '{
    "Rules": [
      {
        "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"},
        "BucketKeyEnabled": false
      }
    ]
  }'
```

> The latest CFN template (`cfn/child-stacks/sus-blueprints-stack.yaml`)
> creates the Tooling bucket with `SSEAlgorithm: AES256` directly, so new
> stacks need no manual patching here. The `rSUSBPToolingKMSKey` resource
> remains in the template — it is still useful for Athena workgroup
> encryption, EMR EBS encryption, and CloudWatch Logs encryption — but it
> is no longer wired to the bucket's default encryption.

---

## Patch 3 — Bump env class + worker/webserver counts on the project profile

**Symptoms (in order, as you fix them):**

1. `mw1.micro` is too small for non-trivial workloads — task queues stall.
2. `Resource handler returned message: "Invalid request provided: The web
   server count for environment class mw1.medium must be greater than 1."`
3. `Resource handler returned message: "Invalid request provided: Scheduler
   count must be greater than 1 for Airflow version 2.10.1."`

**Cause:** The blueprint defaults are `mw1.micro`, `maxWorkers=1`,
`min/maxWebservers=1`, `schedulers=1`. Any class >= `mw1.medium` requires
`>= 2` webservers, and Airflow 2.10.1 (the current MWAA default) requires
`>= 2` schedulers.

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
#      { "name": "maxWebservers",    "value": "2",          "isEditable": true },
#      { "name": "schedulers",       "value": "2",          "isEditable": true }
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

## Patch 4 — Set the `KmsKeyId` principal tag on the project user role

**Symptom:** JupyterLab in the SageMaker Studio space loads with
`S3 is unreachable. Please contact your admin.` Notebooks won't render
files under the project's prefix; sample DAGs in `<bucket>/<domain>/<project>/shared/`
fail to list.

**Cause:** The AWS-managed `SageMakerStudioProjectUserRolePolicy` has many
KMS statements scoped to
`arn:aws:kms:*:*:key/${aws:PrincipalTag/KmsKeyId}`. DataZone creates the
project user role with `KmsKeyId=""` (empty) whenever the Tooling env is
provisioned with `enableCmkSupport=false`, which is the default. With an
empty tag, the resource ARN evaluates to `arn:aws:kms:*:*:key/` and matches
no key, so the role can't `kms:Decrypt` any of the existing CMK-encrypted
objects in the Tooling bucket. JupyterLab surfaces the underlying
`AccessDenied` as the generic "S3 is unreachable" message.

`enableCmkSupport` is not a user-overridable parameter on the Tooling
blueprint, so we can't fix this via project profile. The only path is to
re-tag the role post-creation:

```bash
aws iam tag-role \
  --profile <AWS_PROFILE> \
  --role-name <PROJECT_USER_ROLE> \
  --tags Key=KmsKeyId,Value=<KMS_KEY_UUID>
```

> `<KMS_KEY_UUID>` is the short id (the UUID after `key/` in the KMS ARN).
> Pull it from the Tooling bucket's default encryption:
> ```bash
> aws s3api get-bucket-encryption \
>   --bucket <TOOLING_BUCKET> \
>   --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.KMSMasterKeyID' \
>   --output text
> ```
> If the bucket has been switched to SSE-S3 (Patch 2 above), this tag is
> not needed for new objects but is still required to decrypt any
> CMK-encrypted objects that pre-date the bucket-encryption change.

> The Lambda-managed `_tag_role_with_tooling_kms` (Section 2 of
> `setup.py`) handles this automatically on every deploy for new stacks.
> Existing stacks need the manual tag-role above the first time.

---

## Verification checklist

After applying all four patches:

- [ ] The project user role has the `MWAAWebAccess` inline policy attached.
- [ ] The project user role's `KmsKeyId` principal tag is set to the Tooling
      KMS key's UUID (or any other key the role's policies need to decrypt).
- [ ] `get-bucket-encryption` on the Tooling bucket returns
      `SSEAlgorithm: AES256` (SSE-S3) — not `aws:kms`.
- [ ] `get-project-profile` shows the five parameter overrides on
      `OnDemand Workflows` (`environmentClass`, `maxWorkers`, `minWebservers`,
      `maxWebservers`, `schedulers`).
- [ ] Creating an `OnDemand Workflows` env from the project succeeds and
      reaches `AVAILABLE` (allow ~25 minutes).
- [ ] Opening JupyterLab from the project's Tooling space loads without
      "S3 is unreachable".
