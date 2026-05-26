"""
SMUS post-deploy setup.

Runs as a CloudFormation Custom Resource on stack Create/Update,
AFTER the 5 child stacks (domain, blueprints, project profiles, policy
grants, project) have completed. The dynamic project user role
(`datazone_usr_role_<projectId>_<envId>`) is provisioned by SMUS during
the project create — by the time this Lambda fires it exists.

Bash equivalents (preserved here as section banners so the bash and
the Python stay aligned):

  Section 1: _lakeformation_bootstrap  — revoke IAMAllowedPrincipals on seed Glue,
                                         grant Describe/Select+Grantable to project
                                         user role + manage-access role.
  Section 2: _smus_session_bootstrap   — LF data-lake-settings (FGAC + session tags),
                                         WithFederation re-registration of seed S3
                                         prefixes, KMS key policy on tooling bucket,
                                         IAM inline policies on dynamic project role.
  Section 3: _smus_codecommit_grant    — codecommit:GitPull/GitPush inline on dynamic role.

Inputs (ResourceProperties):
  DomainId               - DataZone domain id (dzd-...)
  AdminProjectId         - DataZone admin project id
  LFRegistrationRoleArn  - ARN of CFN-created LF registration role
  ManageAccessRoleArn    - ARN of CFN-created manage-access role
  ToolingBucketName      - name of the tooling S3 bucket (CFN-created)
  RepoProvider           - 'codecommit' or 'github' or '' (controls whether section 3 runs)
  Region                 - AWS region (defaults to AWS_REGION env var)

Outputs (returned to CFN as Data):
  ToolingUserRoleArn     - the discovered datazone_usr_role_* ARN
  ProjectDb              - glue_db_<env_id> (for downstream reference)
"""

from __future__ import annotations

import json
import logging
import time
from typing import Any

import boto3

LOG = logging.getLogger()
LOG.setLevel("INFO")

# Authorized session-tag values that LF must accept for SMUS Spark sessions.
SESSION_TAG_VALUES = [
    "Amazon DataZone",
    "Amazon SageMaker",
    "Amazon SageMakerUnifiedStudio",
    "AWS Lake Formation Glue",
    "Amazon EMR",
    "Athena",
    "Amazon Athena",
]

# Inline IAM policies attached to the dynamic project user role.
LAKEFORMATION_FGAC_POLICY = {
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "LFGetTempCreds",
            "Effect": "Allow",
            "Action": [
                "lakeformation:GetDataAccess",
                "lakeformation:GetTemporaryGlueTableCredentials",
                "lakeformation:GetResourceLFTags",
                "lakeformation:GetWorkUnits",
                "lakeformation:StartQueryPlanning",
                "lakeformation:GetWorkUnitResults",
                "lakeformation:StartTransaction",
                "lakeformation:CommitTransaction",
                "lakeformation:CancelTransaction",
                "lakeformation:ExtendTransaction",
                "lakeformation:DescribeTransaction",
                "lakeformation:GetQueryState",
                "lakeformation:GetQueryStatistics",
            ],
            "Resource": "*",
        }
    ],
}

GLUE_CATALOG_READ_POLICY = {
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "GlueCatalogRead",
            "Effect": "Allow",
            "Action": [
                "glue:GetDatabase",
                "glue:GetDatabases",
                "glue:GetTable",
                "glue:GetTables",
                "glue:GetPartition",
                "glue:GetPartitions",
                "glue:SearchTables",
            ],
            "Resource": "*",
        }
    ],
}


def _mwaa_web_access_policy(account_id: str, region: str, env_name: str) -> dict:
    """Inline policy that lets the project user role browse + log into the
    MWAA env from the SMUS portal's Workflows tab.

    Why three statements: MWAA's IAM action surface is split across
    three resource types (per AWS service authorization reference):

      * ``airflow:ListEnvironments`` has NO resource constraint —
        it must use ``Resource: "*"``. Without it the Workflows tab's
        portal-side ``listEnvironments`` REST call returns 403 even if
        the operator's only env IS the one we just wired up.
      * ``airflow:GetEnvironment``, ``CreateCliToken``,
        ``InvokeRestApi``, ``ListTagsForResource`` accept the env ARN
        ``arn:aws:airflow:<r>:<a>:environment/<env>``.
      * ``airflow:CreateWebLoginToken`` accepts a DIFFERENT resource
        type — ``rbac-role`` — formatted as
        ``arn:aws:airflow:<r>:<a>:role/<env>/<RbacRole>``. The portal
        mints a Web UI token using the ``Admin`` rbac role for SMUS
        users by default; we wildcard the role suffix so the same
        policy works regardless of which rbac role the portal asks for.

    Without this policy, the SMUS portal's Workflows tab shows
    ``Error retrieving workflow environment <env>`` and the browser
    devtools console shows the failing GET to
    ``api.airflow.<region>.amazonaws.com/<env>/...``.
    """
    env_arn = f"arn:aws:airflow:{region}:{account_id}:environment/{env_name}"
    role_arn_pattern = f"arn:aws:airflow:{region}:{account_id}:role/{env_name}/*"
    return {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "MWAAListEnvironments",
                "Effect": "Allow",
                "Action": "airflow:ListEnvironments",
                "Resource": "*",
            },
            {
                "Sid": "MWAAEnvScopedRead",
                "Effect": "Allow",
                "Action": [
                    "airflow:GetEnvironment",
                    "airflow:ListTagsForResource",
                    "airflow:CreateCliToken",
                    "airflow:InvokeRestApi",
                ],
                "Resource": env_arn,
            },
            {
                "Sid": "MWAAWebUILogin",
                "Effect": "Allow",
                "Action": "airflow:CreateWebLoginToken",
                "Resource": role_arn_pattern,
            },
        ],
    }


CODECOMMIT_POLICY = {
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "CodeCommitGitOps",
            "Effect": "Allow",
            "Action": [
                "codecommit:GitPull",
                "codecommit:GitPush",
                "codecommit:ListRepositories",
                "codecommit:GetRepository",
                "codecommit:GetBranch",
                "codecommit:ListBranches",
            ],
            "Resource": "*",
        }
    ],
}


def _codeconnections_policy(connection_arn: str) -> dict:
    """Inline policy that lets the project user role use a CodeConnections
    connection for Git ops on a 3P provider (GitHub, GitLab, Bitbucket).

    Scoped to the specific connection ARN — there's no GitPull/GitPush
    equivalent for 3P providers; SMUS uses `codeconnections:UseConnection`
    to mint short-lived credentials at clone/push time.
    """
    return {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "CodeConnectionsUse",
                "Effect": "Allow",
                "Action": [
                    "codeconnections:UseConnection",
                    "codeconnections:GetConnection",
                    "codeconnections:GetConnectionToken",
                    # Legacy alias still required by some clients.
                    "codestar-connections:UseConnection",
                    "codestar-connections:GetConnection",
                    "codestar-connections:GetConnectionToken",
                ],
                "Resource": connection_arn,
            }
        ],
    }


def run(props: dict) -> dict:
    """Top-level dispatch — returns dict of outputs for cfn_response.Data."""
    domain_id = props["DomainId"]
    admin_project_id = props["AdminProjectId"]
    lf_reg_role_arn = props["LFRegistrationRoleArn"]
    manage_access_role_arn = props["ManageAccessRoleArn"]
    tooling_bucket = props["ToolingBucketName"]
    repo_provider = (props.get("RepoProvider") or "").strip()
    repo_name = (props.get("RepoName") or "").strip()
    repo_url = (props.get("RepoUrl") or "").strip()
    codecommit_repo_arn = (props.get("CodeCommitRepoArn") or "").strip()
    connection_arn = (props.get("ConnectionArn") or "").strip()
    region = props.get("Region") or boto3.Session().region_name or "us-east-1"

    LOG.info(
        "setup.run domain=%s project=%s region=%s repo_provider=%s",
        domain_id, admin_project_id, region, repo_provider or "<unset>",
    )

    sts = boto3.client("sts", region_name=region)
    account_id = sts.get_caller_identity()["Account"]

    # Discover the dynamic project user role + lakehouse env id.
    project_user_role, lakehouse_env_id = _discover_project_runtime(
        domain_id, admin_project_id, region,
    )
    if not project_user_role:
        raise RuntimeError(
            f"could not discover project user role for project {admin_project_id}; "
            "is the Tooling environment fully provisioned?"
        )

    LOG.info("project_user_role=%s lakehouse_env=%s", project_user_role, lakehouse_env_id)

    # ------ Section 0: Orphan cleanup (idempotent self-heal) ------
    # Drop any glue_db_<envId> Glue databases left behind by previous
    # deploys whose teardown didn't reach Pass D (the rPreDelete
    # Lambda's orphan sweep). Without this, the migration tool's
    # step 04 inventory picks up these orphans even though the
    # filter was added — at least until a successful teardown
    # cleans them. Doing this on setup means each fresh deploy
    # leaves the Glue catalog clean regardless of past teardown
    # health.
    _drop_orphan_glue_dbs_on_setup(region)

    # ------ Section 1: Lake Formation bootstrap ------
    _lakeformation_bootstrap(
        region=region,
        project_user_role=project_user_role,
        manage_access_role=manage_access_role_arn,
    )

    # ------ Section 2: SMUS session bootstrap ------
    _smus_session_bootstrap(
        region=region,
        account_id=account_id,
        domain_id=domain_id,
        project_user_role=project_user_role,
        lf_reg_role_arn=lf_reg_role_arn,
        tooling_bucket=tooling_bucket,
    )

    # ------ Section 3: Repository access grant on the project user role ------
    # Branch on RepoProvider:
    #   * CodeCommit → inline `codecommit:GitPull/GitPush` (legacy default).
    #   * Any 3P (GitHub / GitLab / Bitbucket) AND ConnectionArn provided →
    #     inline `codeconnections:UseConnection` scoped to that ARN.
    #   * empty / unrecognized → no-op.
    repo_outputs: dict[str, str] = {}
    if repo_provider.lower() == "codecommit":
        _smus_codecommit_grant(project_user_role)
        repo_outputs["RepoProvider"] = "CodeCommit"
        repo_outputs["RepoName"] = repo_name
        repo_outputs["CodeCommitRepoArn"] = codecommit_repo_arn
    elif repo_provider and connection_arn:
        _smus_codeconnections_grant(project_user_role, connection_arn)
        # Best-effort: read the live connection state and surface it
        # through the CR Data so the operator can see "PENDING" /
        # "AVAILABLE" without leaving the CFN console.
        conn_state = _describe_connection_state(connection_arn, region)
        repo_outputs["RepoProvider"] = repo_provider
        repo_outputs["RepoName"] = repo_name
        repo_outputs["RepoUrl"] = repo_url
        repo_outputs["RepoConnectionArn"] = connection_arn
        repo_outputs["RepoConnectionState"] = conn_state
        if conn_state == "PENDING":
            LOG.warning(
                "ACTION REQUIRED: connection %s is PENDING. Open the AWS "
                "console -> Developer Tools -> Settings -> Connections, "
                "find '%s', and click 'Update pending connection' to "
                "complete the OAuth handshake. Until done, Git pulls will fail.",
                connection_arn, repo_name,
            )
    else:
        LOG.info(
            "section 3 skipped: repo_provider=%s connection_arn=%s",
            repo_provider or "<unset>", "<set>" if connection_arn else "<unset>",
        )

    return {
        "ToolingUserRoleArn": project_user_role,
        "ProjectDb": f"glue_db_{lakehouse_env_id}" if lakehouse_env_id else "",
        **repo_outputs,
    }


# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

def _discover_project_runtime(domain_id: str, project_id: str, region: str) -> tuple[str, str]:
    """Find the dynamic project user role ARN and the Lakehouse env id.

    Returns (project_user_role_arn, lakehouse_env_id). Either may be empty
    if the corresponding env hasn't finished provisioning yet.
    """
    dz = boto3.client("datazone", region_name=region)

    project_user_role = ""
    lakehouse_env_id = ""

    # Poll for ~5 minutes — SMUS provisions the Tooling env in the background
    # after the project sub-stack returns CREATE_COMPLETE.
    for attempt in range(30):
        envs = dz.list_environments(
            domainIdentifier=domain_id,
            projectIdentifier=project_id,
        ).get("items", [])

        for env in envs:
            if env["name"] == "Tooling" and env["status"] == "ACTIVE":
                env_detail = dz.get_environment(
                    domainIdentifier=domain_id,
                    identifier=env["id"],
                )
                for resource in env_detail.get("provisionedResources", []):
                    if resource.get("name") == "userRoleArn":
                        project_user_role = resource["value"]
                        break
            if env["name"] == "Lakehouse Database":
                lakehouse_env_id = env["id"]

        if project_user_role and lakehouse_env_id:
            return project_user_role, lakehouse_env_id

        LOG.info(
            "waiting for Tooling env (attempt %s/30): user_role=%s lakehouse=%s",
            attempt + 1, bool(project_user_role), bool(lakehouse_env_id),
        )
        time.sleep(10)

    return project_user_role, lakehouse_env_id


def _drop_orphan_glue_dbs_on_setup(region: str) -> None:
    """Setup-side mirror of teardown's Pass D: drop orphan glue_db_*.

    A glue_db_<envId> is an orphan when its `LocationUri` references
    a DataZone domain that no longer exists. The legitimate ones (the
    new domain this stack just created, plus any other live domains)
    are left alone.

    Same scope-and-decision rules as `teardown.py:_drop_orphan_glue_dbs`,
    but called from setup so a fresh deploy after a partial teardown
    self-heals. Without this, step 04's `relationalFilterConfigurations`
    builder would still see orphan databases through the `glue_db_`
    prefix and (until we added the prefix filter) try to crawl them.
    """
    LOG.info("Section 0: drop orphan glue_db_*")
    glue = boto3.client("glue", region_name=region)
    lf = boto3.client("lakeformation", region_name=region)
    dz = boto3.client("datazone", region_name=region)
    sts = boto3.client("sts", region_name=region)
    caller_arn = sts.get_caller_identity()["Arn"]
    if ":assumed-role/" in caller_arn:
        parts = caller_arn.split(":")
        role_name = parts[5].split("/")[1]
        principal = f"arn:aws:iam::{parts[4]}:role/{role_name}"
    else:
        principal = caller_arn

    active_domain_ids: set[str] = set()
    try:
        for d in dz.list_domains().get("items", []):
            active_domain_ids.add(d["id"])
    except dz.exceptions.ClientError as exc:
        LOG.warning("  list_domains failed; skipping orphan sweep: %s", exc)
        return
    LOG.info("  active domains in region: %s", sorted(active_domain_ids) or ["<none>"])

    paginator = glue.get_paginator("get_databases")
    for page in paginator.paginate():
        for db in page.get("DatabaseList", []):
            db_name = db["Name"]
            if not db_name.startswith("glue_db_"):
                continue
            location = db.get("LocationUri", "") or ""
            referenced = [d for d in active_domain_ids if d in location]
            if referenced:
                LOG.info("  = keeping %s (live domain %s)", db_name, referenced[0])
                continue
            LOG.info("  + dropping orphan %s (LocationUri=%s)", db_name, location)
            try:
                lf.grant_permissions(
                    Principal={"DataLakePrincipalIdentifier": principal},
                    Resource={"Database": {"Name": db_name}},
                    Permissions=["DROP"],
                )
            except lf.exceptions.ClientError:
                pass
            try:
                tpaginator = glue.get_paginator("get_tables")
                for tpage in tpaginator.paginate(DatabaseName=db_name):
                    for table in tpage.get("TableList", []):
                        try:
                            glue.delete_table(DatabaseName=db_name, Name=table["Name"])
                        except glue.exceptions.ClientError:
                            pass
                glue.delete_database(Name=db_name)
                LOG.info("    + dropped %s", db_name)
            except glue.exceptions.ClientError as exc:
                LOG.warning("    drop %s failed: %s", db_name, exc)


# ---------------------------------------------------------------------------
# Section 1: Lake Formation bootstrap
# ---------------------------------------------------------------------------

def _lakeformation_bootstrap(*, region: str, project_user_role: str, manage_access_role: str) -> None:
    """Walk every external Glue DB, revoke IAMAllowedPrincipals, grant DESCRIBE/SELECT.

    Skips:
      - the system `default` Glue DB on revoke (LF rejects the operation
        on the system principal anyway)
      - any database starting with `glue_db_` (project-managed by SMUS)
    """
    LOG.info("Section 1: Lake Formation bootstrap")

    glue = boto3.client("glue", region_name=region)
    lf = boto3.client("lakeformation", region_name=region)

    paginator = glue.get_paginator("get_databases")
    for page in paginator.paginate():
        for db in page.get("DatabaseList", []):
            db_name = db["Name"]
            if db_name.startswith("glue_db_"):
                LOG.info("  skipping project-managed db: %s", db_name)
                continue

            # Database-level grants for project user role + manage-access role.
            for principal in (project_user_role, manage_access_role):
                try:
                    lf.grant_permissions(
                        Principal={"DataLakePrincipalIdentifier": principal},
                        Resource={"Database": {"Name": db_name}},
                        Permissions=["DESCRIBE"],
                        PermissionsWithGrantOption=["DESCRIBE"],
                    )
                    LOG.info("  + DESCRIBE (+Grantable) on db=%s -> %s", db_name, principal.split("/")[-1])
                except lf.exceptions.ClientError as exc:
                    LOG.warning("  grant DESCRIBE failed on %s -> %s: %s", db_name, principal, exc)

            # Table-level: revoke IAMAllowedPrincipals + grant SELECT.
            try:
                table_paginator = glue.get_paginator("get_tables")
                for tpage in table_paginator.paginate(DatabaseName=db_name):
                    for table in tpage.get("TableList", []):
                        table_name = table["Name"]
                        # Revoke IAMAllowedPrincipals (best-effort).
                        try:
                            lf.revoke_permissions(
                                Principal={"DataLakePrincipalIdentifier": "IAM_ALLOWED_PRINCIPALS"},
                                Resource={"Table": {"DatabaseName": db_name, "Name": table_name}},
                                Permissions=["ALL"],
                            )
                        except lf.exceptions.ClientError:
                            pass
                        # Grant SELECT/DESCRIBE +Grantable to both principals.
                        for principal in (project_user_role, manage_access_role):
                            try:
                                lf.grant_permissions(
                                    Principal={"DataLakePrincipalIdentifier": principal},
                                    Resource={"Table": {"DatabaseName": db_name, "Name": table_name}},
                                    Permissions=["DESCRIBE", "SELECT"],
                                    PermissionsWithGrantOption=["DESCRIBE", "SELECT"],
                                )
                            except lf.exceptions.ClientError as exc:
                                LOG.warning(
                                    "  grant SELECT failed on %s.%s -> %s: %s",
                                    db_name, table_name, principal.split("/")[-1], exc,
                                )
                LOG.info("  + IAMAllowedPrincipals revoked + grants applied across %s", db_name)
            except glue.exceptions.ClientError as exc:
                LOG.warning("  table walk failed on %s: %s", db_name, exc)

    LOG.info("Section 1: complete")


# ---------------------------------------------------------------------------
# Section 2: SMUS session bootstrap
# ---------------------------------------------------------------------------

def _smus_session_bootstrap(
    *,
    region: str,
    account_id: str,
    domain_id: str,
    project_user_role: str,
    lf_reg_role_arn: str,
    tooling_bucket: str,
) -> None:
    """LF data-lake-settings + KMS + WithFederation registrations + IAM inlines."""
    LOG.info("Section 2: SMUS session bootstrap")

    lf = boto3.client("lakeformation", region_name=region)
    iam = boto3.client("iam", region_name=region)
    s3 = boto3.client("s3", region_name=region)
    kms = boto3.client("kms", region_name=region)
    glue = boto3.client("glue", region_name=region)

    # 2a. LF data-lake-settings: external filtering + session tag list.
    settings = lf.get_data_lake_settings()["DataLakeSettings"]
    settings["AllowExternalDataFiltering"] = True
    settings["AllowFullTableExternalDataAccess"] = True
    settings["ExternalDataFilteringAllowList"] = [{"DataLakePrincipalIdentifier": account_id}]
    settings["AuthorizedSessionTagValueList"] = SESSION_TAG_VALUES
    lf.put_data_lake_settings(DataLakeSettings=settings)
    LOG.info("  + LF external-data-filtering enabled + account allow-listed + session tags set")

    # 2b. Inline IAM policies on the dynamic project user role.
    role_name = project_user_role.split("/")[-1]
    for policy_name, policy_doc in (
        ("LakeFormationFGACAccess", LAKEFORMATION_FGAC_POLICY),
        ("GlueCatalogReadAccess", GLUE_CATALOG_READ_POLICY),
    ):
        iam.put_role_policy(
            RoleName=role_name,
            PolicyName=policy_name,
            PolicyDocument=json.dumps(policy_doc),
        )
        LOG.info("  + %s inline policy applied to %s", policy_name, role_name)

    # 2b'. MWAA web-access inline policy. Attach one statement-set
    # per discovered MWAA env in the region so the SMUS portal's
    # Workflows tab can list + open every env the operator has
    # without us having to know names at deploy time.
    _attach_mwaa_web_access_policy(role_name, account_id, region)

    # 2b''. Re-tag the project user role with KmsKeyId.
    #
    # The default `SageMakerStudioProjectUserRolePolicy` (AWS-managed)
    # has many KMS statements scoped to
    # `arn:aws:kms:*:*:key/${aws:PrincipalTag/KmsKeyId}`. DataZone
    # creates the role with `KmsKeyId=""` whenever the Tooling env was
    # provisioned with `enableCmkSupport=false` (the default). With an
    # empty tag, the resource ARN resolves to `.../key/` and matches
    # no key — so JupyterLab fails with "S3 is unreachable" the moment
    # it tries to read CMK-encrypted objects (notebooks, sample DAGs,
    # Glue logs) under the project's prefix.
    #
    # We can't flip `enableCmkSupport` (not a user-param), so we patch
    # the tag post-creation. Idempotent — leaves the tag alone if a
    # value is already set, only fills empty.
    _tag_role_with_tooling_kms(role_name, tooling_bucket)

    # 2c. KMS key policy on tooling bucket CMK.
    try:
        enc = s3.get_bucket_encryption(Bucket=tooling_bucket)
        rules = enc["ServerSideEncryptionConfiguration"]["Rules"]
        kms_key_id = rules[0]["ApplyServerSideEncryptionByDefault"].get("KMSMasterKeyID", "")
        kms_key_short = kms_key_id.split("/")[-1] if kms_key_id else ""
        if kms_key_short:
            key_meta = kms.describe_key(KeyId=kms_key_short)["KeyMetadata"]
            if key_meta.get("KeyManager") == "CUSTOMER":
                _ensure_kms_statement(kms, kms_key_short, project_user_role, account_id, region)
            else:
                LOG.info("  = tooling bucket KMS is AWS-managed; skipping policy update")
    except (s3.exceptions.ClientError, kms.exceptions.NotFoundException) as exc:
        LOG.warning("  KMS policy update skipped: %s", exc)

    # 2d. Repair orphan LF registrations from prior deploys.
    # Different stack names get different LF-registration role names
    # (we suffix with the stack name for uniqueness — see comment on
    # rSUSLFRegistrationRole in sus-domain-stack.yaml). When a previous
    # stack was torn down without first deregistering its S3 prefixes,
    # those registrations stay in LF pointing at a now-deleted role.
    # The next deploy creates a new role with a different name; queries
    # against the orphan prefixes fail with `Unable to assume role`
    # because the role ARN is dead. This pass walks every LF
    # registration whose role no longer exists in IAM and rewrites it
    # to use the live registration role.
    _repair_orphan_lf_registrations(lf, lf_reg_role_arn, region)

    # 2e. Re-register source S3 prefixes with WithFederation=true.
    _reregister_s3_prefixes(glue, lf, lf_reg_role_arn, region)

    LOG.info("Section 2: complete")


def _tag_role_with_tooling_kms(role_name: str, tooling_bucket: str) -> None:
    """Set the `KmsKeyId` principal tag on the project user role.

    Reads the Tooling bucket's default-encryption KMS key (if any)
    and writes its short id (UUID) into the role's `KmsKeyId` tag.
    The `SageMakerStudioProjectUserRolePolicy` managed policy uses
    this tag as a variable in its KMS resource ARNs — without a
    valid value, every KMS-scoped statement evaluates to an
    impossible ARN and JupyterLab can't decrypt existing
    CMK-encrypted objects in the bucket ("S3 is unreachable").

    No-ops when:
      * The bucket has SSE-S3 (no CMK to scope to).
      * The role already has a non-empty `KmsKeyId` tag (someone
        explicitly set it to a different key).
    """
    iam = boto3.client("iam")
    s3 = boto3.client("s3")

    try:
        enc = s3.get_bucket_encryption(Bucket=tooling_bucket)
        rules = enc["ServerSideEncryptionConfiguration"]["Rules"]
        kms_master = rules[0]["ApplyServerSideEncryptionByDefault"].get("KMSMasterKeyID", "")
    except s3.exceptions.ClientError as exc:
        LOG.warning("  KmsKeyId tag skipped: get-bucket-encryption failed: %s", exc)
        return

    if not kms_master:
        LOG.info("  = bucket uses SSE-S3; clearing KmsKeyId tag is a no-op")
        return

    kms_short = kms_master.split("/")[-1]

    try:
        existing = iam.list_role_tags(RoleName=role_name).get("Tags", [])
    except iam.exceptions.ClientError as exc:
        LOG.warning("  KmsKeyId tag skipped: list_role_tags failed: %s", exc)
        return

    cur = next((t["Value"] for t in existing if t["Key"] == "KmsKeyId"), None)
    if cur and cur != "":
        if cur == kms_short:
            LOG.info("  = role %s already tagged KmsKeyId=%s", role_name, kms_short)
        else:
            LOG.info("  = role %s has explicit KmsKeyId=%s; leaving as-is", role_name, cur)
        return

    iam.tag_role(RoleName=role_name, Tags=[{"Key": "KmsKeyId", "Value": kms_short}])
    LOG.info("  + role %s tagged KmsKeyId=%s", role_name, kms_short)


def _attach_mwaa_web_access_policy(role_name: str, account_id: str, region: str) -> None:
    """Inline MWAA web-access policy onto the dynamic project user role.

    Discovers SMUS-managed MWAA envs in the region and attaches a
    consolidated policy that grants the role enough permission for the
    SMUS portal's Workflows tab to list + open them.

    SMUS-managed envs are identified by the presence of the
    `AmazonDataZoneDomain` tag (set by the Workflows blueprint when
    SMUS provisions an env). Legacy / source MWAA envs that exist in
    the same account but aren't owned by SMUS are deliberately
    excluded — granting project users access to them would be an
    over-scope (the seed environment that the migration *moves data
    out of* is a typical example).

    Per the MWAA Service Authorization Reference, three statement-types
    are needed:

      * `airflow:ListEnvironments` — Resource `*` (no resource constraint
        on this action; without it the portal's listEnvironments REST
        call returns 403 even with env-scoped read perms below).
      * `airflow:GetEnvironment / CreateCliToken / InvokeRestApi /
        ListTagsForResource` — env ARN per env.
      * `airflow:CreateWebLoginToken` — `rbac-role` ARN
        (arn:aws:airflow:..:role/<env>/<rbac-role>) per env, wildcarded
        on the rbac-role suffix to support whichever role the portal
        requests.

    Skipped silently when no SMUS-managed MWAA envs exist (e.g.
    operator hasn't clicked "Create" in the Workflows tab yet) so
    dry-run / partial deployments still work.
    """
    iam = boto3.client("iam")
    mwaa = boto3.client("mwaa", region_name=region)

    all_env_names: list[str] = []
    try:
        paginator = mwaa.get_paginator("list_environments")
        for page in paginator.paginate():
            all_env_names.extend(page.get("Environments", []))
    except mwaa.exceptions.ClientError as exc:
        LOG.warning("  + MWAA list_environments failed: %s; skipping web-access grant", exc)
        return

    if not all_env_names:
        LOG.info("  = no MWAA envs in %s; skipping MWAAWebAccess inline", region)
        return

    # Tag-filter to keep only SMUS-managed envs. The Workflows
    # blueprint stamps `AmazonDataZoneDomain` on every env it
    # provisions; legacy / source MWAA envs (e.g. the seed env that
    # this toolkit migrates DATA OUT OF) lack it and should NOT get
    # surfaced to project users.
    env_names: list[str] = []
    for name in all_env_names:
        env_arn = f"arn:aws:airflow:{region}:{account_id}:environment/{name}"
        try:
            tags = mwaa.list_tags_for_resource(ResourceArn=env_arn).get("Tags", {}) or {}
        except mwaa.exceptions.ClientError as exc:
            LOG.warning("  = list_tags failed for %s: %s; treating as non-SMUS", name, exc)
            continue
        if "AmazonDataZoneDomain" in tags:
            env_names.append(name)
            LOG.info("  + SMUS-managed env (tagged AmazonDataZoneDomain=%s): %s",
                     tags.get("AmazonDataZoneDomain"), name)
        else:
            LOG.info("  = skipping un-tagged MWAA env (likely external/legacy): %s", name)

    if not env_names:
        LOG.info("  = no SMUS-managed MWAA envs found in %s; skipping MWAAWebAccess inline", region)
        # Drop any stale inline left from a prior run that did grant access.
        try:
            iam.delete_role_policy(RoleName=role_name, PolicyName="MWAAWebAccess")
            LOG.info("  + dropped stale MWAAWebAccess inline (no SMUS envs to grant for)")
        except iam.exceptions.NoSuchEntityException:
            pass
        except iam.exceptions.ClientError:
            pass
        return

    env_arns = [
        f"arn:aws:airflow:{region}:{account_id}:environment/{name}"
        for name in env_names
    ]
    role_arn_patterns = [
        f"arn:aws:airflow:{region}:{account_id}:role/{name}/*"
        for name in env_names
    ]
    policy = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "MWAAListEnvironments",
                "Effect": "Allow",
                "Action": "airflow:ListEnvironments",
                "Resource": "*",
            },
            {
                "Sid": "MWAAEnvScopedRead",
                "Effect": "Allow",
                "Action": [
                    "airflow:GetEnvironment",
                    "airflow:ListTagsForResource",
                    "airflow:CreateCliToken",
                    "airflow:InvokeRestApi",
                ],
                "Resource": env_arns,
            },
            {
                "Sid": "MWAAWebUILogin",
                "Effect": "Allow",
                "Action": "airflow:CreateWebLoginToken",
                "Resource": role_arn_patterns,
            },
        ],
    }
    iam.put_role_policy(
        RoleName=role_name,
        PolicyName="MWAAWebAccess",
        PolicyDocument=json.dumps(policy),
    )
    LOG.info("  + MWAAWebAccess inline policy applied to %s (SMUS envs=%s)", role_name, env_names)


def _ensure_kms_statement(kms_client, key_id: str, role_arn: str, account_id: str, region: str) -> None:
    """Add `AllowProjectUserRoleForSparkLogs` statement to the tooling-bucket CMK policy."""
    policy_str = kms_client.get_key_policy(KeyId=key_id, PolicyName="default")["Policy"]
    policy = json.loads(policy_str)
    statements = policy.get("Statement", [])
    if any(s.get("Sid") == "AllowProjectUserRoleForSparkLogs" for s in statements):
        LOG.info("  = AllowProjectUserRoleForSparkLogs already present on KMS key")
        return
    statements.append({
        "Sid": "AllowProjectUserRoleForSparkLogs",
        "Effect": "Allow",
        "Principal": {"AWS": role_arn},
        "Action": [
            "kms:Encrypt",
            "kms:Decrypt",
            "kms:ReEncrypt*",
            "kms:GenerateDataKey*",
            "kms:DescribeKey",
        ],
        "Resource": "*",
        "Condition": {
            "StringLike": {
                "kms:ViaService": [
                    f"s3.{region}.amazonaws.com",
                    f"glue.{region}.amazonaws.com",
                ],
            },
        },
    })
    policy["Statement"] = statements
    kms_client.put_key_policy(KeyId=key_id, PolicyName="default", Policy=json.dumps(policy))
    LOG.info("  + KMS key policy now grants Encrypt/Decrypt/GenerateDataKey* to %s", role_arn.split("/")[-1])


def _repair_orphan_lf_registrations(lf_client, lf_reg_role_arn: str, region: str) -> None:
    """Walk every LF registration and rewrite ones we own to use the live role.

    "Owned" registrations are those whose ResourceArn references either:

      1. A source data bucket — one that contains seed Glue tables.
         These bucket roots and ANY sub-prefix beneath them
         (`/raw`, `/raw/msk`, `/curated/customers`, etc.) belong to
         the data we're surfacing to SMUS.
      2. This stack's tooling or projects bucket — derived from the
         caller account ID and region (the stack-suffixed names are
         in the form `amazon-datazone-{tooling,projects}-<acct>-<region>-<stack14>`).

    For both kinds, we deregister the existing entry and re-register
    with the live `lf_reg_role_arn`. This means the role created by
    THIS stack create is the canonical principal LF uses to assume
    into our data — no matter what role a previous (torn-down) stack
    left behind.

    Registrations OUTSIDE our ownership zone (e.g., another live
    stack's tooling bucket in the same account) are left alone. If
    their role is missing from IAM, we deregister them as cleanup
    but don't try to "claim" them.

    All operations are best-effort — a failure on one registration
    is logged and skipped, never escalates to the caller.
    """
    LOG.info("  + repair pass: walk LF registrations + rewrite owned ones to %s",
             lf_reg_role_arn)

    iam = boto3.client("iam", region_name=region)
    glue = boto3.client("glue", region_name=region)

    # Build the set of source data buckets (those backing seed Glue
    # tables). Any registration whose path is on one of these buckets
    # — bucket root or sub-prefix — is in our ownership zone.
    source_buckets: set[str] = set()
    try:
        for page in glue.get_paginator("get_databases").paginate():
            for db in page.get("DatabaseList", []):
                if db["Name"].startswith("glue_db_"):
                    continue
                try:
                    for tpage in glue.get_paginator("get_tables").paginate(
                            DatabaseName=db["Name"]):
                        for table in tpage.get("TableList", []):
                            loc = (table.get("StorageDescriptor") or {}).get("Location", "")
                            if loc.startswith("s3://"):
                                source_buckets.add(loc[5:].split("/", 1)[0])
                except glue.exceptions.ClientError:
                    continue
    except glue.exceptions.ClientError as exc:
        LOG.warning("    repair pass: get_databases failed: %s", exc)

    # Stack-owned tooling/projects bucket name patterns.
    # We get the actual names by inspecting our own role ARN (it has
    # the suffix we use everywhere) and reconstructing the bucket
    # names. If the role name doesn't follow the pattern (operator
    # override), the patterns may not match — in which case those
    # registrations get the orphan-detection treatment below.
    role_name = lf_reg_role_arn.split("/")[-1]
    # Pattern: smus-seed-lf-registration-role-<stackname>
    stack_suffix = ""
    prefix_marker = "smus-seed-lf-registration-role-"
    if role_name.startswith(prefix_marker):
        stack_suffix = role_name[len(prefix_marker):]
    # Bucket names cap stack suffix at 14 chars (see scripts/smus-setup.sh).
    stack_suffix_short = stack_suffix[:14]

    sts = boto3.client("sts", region_name=region)
    account_id = sts.get_caller_identity()["Account"]
    owned_bucket_prefixes: list[str] = []
    if stack_suffix_short:
        owned_bucket_prefixes.append(
            f"amazon-datazone-tooling-{account_id}-{region}-{stack_suffix_short}")
        owned_bucket_prefixes.append(
            f"amazon-datazone-projects-{account_id}-{region}-{stack_suffix_short}")

    LOG.info("    repair pass: source buckets=%s, stack=%s",
             sorted(source_buckets), stack_suffix or "<unknown>")

    # Walk every registration. NOTE: list_resources is NOT paginated
    # by boto3 (the API supports NextToken but the client doesn't
    # expose a paginator). Same shape as Athena's list_work_groups
    # — manual NextToken loop required.
    rewritten = 0
    deregistered_orphans = 0
    skipped_other = 0
    all_resources: list = []
    next_token = None
    try:
        while True:
            kwargs = {}
            if next_token:
                kwargs["NextToken"] = next_token
            resp = lf_client.list_resources(**kwargs)
            all_resources.extend(resp.get("ResourceInfoList", []) or [])
            next_token = resp.get("NextToken")
            if not next_token:
                break
    except lf_client.exceptions.ClientError as exc:
        LOG.warning("    repair pass: list_resources failed: %s", exc)
        return

    for entry in all_resources:
        arn = entry.get("ResourceArn", "")
        cur_role = entry.get("RoleArn", "")
        if not arn.startswith("arn:aws:s3:::"):
            continue
        path = arn[len("arn:aws:s3:::"):]
        bucket = path.split("/", 1)[0]

        is_owned = (
            bucket in source_buckets
            or any(bucket == p or bucket.startswith(p) for p in owned_bucket_prefixes)
        )
        if cur_role == lf_reg_role_arn and is_owned:
            # Already correct — nothing to do.
            continue

        if is_owned:
            # Rewrite to use our live role.
            try:
                lf_client.deregister_resource(ResourceArn=arn)
            except lf_client.exceptions.EntityNotFoundException:
                pass
            except lf_client.exceptions.ClientError:
                pass
            try:
                lf_client.register_resource(
                    ResourceArn=arn,
                    UseServiceLinkedRole=False,
                    RoleArn=lf_reg_role_arn,
                    WithFederation=True,
                    HybridAccessEnabled=True,
                )
                LOG.info("    + claimed %s (was: %s)", arn, cur_role or "<no role>")
                rewritten += 1
            except lf_client.exceptions.AlreadyExistsException:
                pass
            except lf_client.exceptions.ClientError as exc:
                LOG.warning("    register_resource failed on %s: %s", arn, exc)
            continue

        # Not owned. If the current role is missing from IAM, this is
        # a straggler from a torn-down stack — deregister it.
        if cur_role and cur_role.startswith("arn:aws:iam::"):
            cur_role_name = cur_role.split("/")[-1]
            try:
                iam.get_role(RoleName=cur_role_name)
                # Role exists, leave the registration alone (likely
                # owned by another live stack).
                skipped_other += 1
                continue
            except iam.exceptions.NoSuchEntityException:
                # Orphan: role gone, registration stale.
                try:
                    lf_client.deregister_resource(ResourceArn=arn)
                    LOG.info("    + deregistered orphan %s (role %s missing)",
                             arn, cur_role_name)
                    deregistered_orphans += 1
                except lf_client.exceptions.ClientError as exc:
                    LOG.warning("    deregister_resource failed on %s: %s", arn, exc)

    LOG.info("    repair pass: claimed=%d, deregistered_orphans=%d, skipped_other=%d",
             rewritten, deregistered_orphans, skipped_other)


def _reregister_s3_prefixes(glue_client, lf_client, lf_reg_role_arn: str, region: str) -> None:
    """Walk seed Glue tables, deregister + re-register each S3 location with WithFederation."""
    locations: set[str] = set()
    paginator = glue_client.get_paginator("get_databases")
    for page in paginator.paginate():
        for db in page.get("DatabaseList", []):
            if db["Name"].startswith("glue_db_"):
                continue
            try:
                tpaginator = glue_client.get_paginator("get_tables")
                for tpage in tpaginator.paginate(DatabaseName=db["Name"]):
                    for table in tpage.get("TableList", []):
                        loc = (table.get("StorageDescriptor") or {}).get("Location", "")
                        if loc.startswith("s3://"):
                            # Use the bucket-level prefix to dedupe.
                            bucket_root = "s3://" + loc[5:].split("/", 1)[0]
                            locations.add(bucket_root)
            except glue_client.exceptions.ClientError:
                continue

    LOG.info("  + re-registering %d source S3 prefix(es) with WithFederation=true", len(locations))
    for loc in sorted(locations):
        # Best-effort deregister, then register fresh with WithFederation.
        try:
            lf_client.deregister_resource(ResourceArn=loc.replace("s3://", "arn:aws:s3:::"))
        except lf_client.exceptions.EntityNotFoundException:
            pass
        except lf_client.exceptions.ClientError:
            pass
        try:
            lf_client.register_resource(
                ResourceArn=loc.replace("s3://", "arn:aws:s3:::"),
                UseServiceLinkedRole=False,
                RoleArn=lf_reg_role_arn,
                WithFederation=True,
                HybridAccessEnabled=True,
            )
        except lf_client.exceptions.AlreadyExistsException:
            pass
        except lf_client.exceptions.ClientError as exc:
            LOG.warning("    register_resource failed on %s: %s", loc, exc)
    LOG.info("  + WithFederation registrations complete")


# ---------------------------------------------------------------------------
# Section 3: CodeCommit grant
# ---------------------------------------------------------------------------

def _smus_codecommit_grant(project_user_role: str) -> None:
    """Attach CodeCommit Git-ops inline policy to the dynamic project user role."""
    LOG.info("Section 3: CodeCommit grant")
    iam = boto3.client("iam")
    role_name = project_user_role.split("/")[-1]
    iam.put_role_policy(
        RoleName=role_name,
        PolicyName="CodeCommitAccess",
        PolicyDocument=json.dumps(CODECOMMIT_POLICY),
    )
    LOG.info("  + CodeCommitAccess inline policy applied to %s", role_name)
    LOG.info("Section 3: complete")


def _smus_codeconnections_grant(project_user_role: str, connection_arn: str) -> None:
    """Attach CodeConnections-Use inline policy scoped to the given connection.

    Used for 3P providers (GitHub, GitLab, Bitbucket). The connection
    ARN is captured at policy-write time so the project user role can
    only mint Git credentials for the specific connection this stack
    set up — not for any other CodeConnections resource in the account.
    """
    LOG.info("Section 3: CodeConnections grant for %s", connection_arn)
    iam = boto3.client("iam")
    role_name = project_user_role.split("/")[-1]
    # Drop the legacy CodeCommitAccess policy if it's still around from
    # a prior CodeCommit-mode deploy on the same project user role.
    try:
        iam.delete_role_policy(RoleName=role_name, PolicyName="CodeCommitAccess")
        LOG.info("  + dropped stale CodeCommitAccess inline (was set by prior CodeCommit run)")
    except iam.exceptions.NoSuchEntityException:
        pass
    except iam.exceptions.ClientError:
        pass
    iam.put_role_policy(
        RoleName=role_name,
        PolicyName="CodeConnectionsAccess",
        PolicyDocument=json.dumps(_codeconnections_policy(connection_arn)),
    )
    LOG.info("  + CodeConnectionsAccess inline policy applied to %s", role_name)
    LOG.info("Section 3: complete")


def _describe_connection_state(connection_arn: str, region: str) -> str:
    """Read the connection's ConnectionStatus. Returns 'PENDING' / 'AVAILABLE'
    / 'ERROR' / '' on lookup failure. Best-effort; failure to describe
    must NOT fail the stack create."""
    try:
        cc = boto3.client("codeconnections", region_name=region)
        return cc.get_connection(ConnectionArn=connection_arn) \
            .get("Connection", {}).get("ConnectionStatus", "")
    except Exception as exc:
        LOG.warning("get_connection failed for %s: %s", connection_arn, exc)
        return ""
