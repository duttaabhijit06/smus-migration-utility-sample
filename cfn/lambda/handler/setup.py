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

    # 2d. Re-register source S3 prefixes with WithFederation=true.
    _reregister_s3_prefixes(glue, lf, lf_reg_role_arn, region)

    LOG.info("Section 2: complete")


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
