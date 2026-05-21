"""
SMUS pre-delete teardown.

Runs as a CloudFormation Custom Resource on stack Delete, BEFORE the
rest of the stack is deleted. CFN deletes resources in reverse-dependency
order, so `rPreDelete` (which has no DependsOn from anything) fires
first.

What this Lambda does (the hardening passes from the bash teardown):

  Pass A:   Drain SMUS-managed VPC interface endpoints on Tooling SG.
  Pass A':  Force-detach + delete orphan DataZone-owned ENIs on Tooling SG.
  Pass A2:  Terminate active Athena Spark sessions on the project's
             workgroup (clears the common DataZone-Env-* delete blocker).
  Pass B:   Cross-SG ingress revoke on sibling SGs referencing Tooling SG.
  Pass C:   Drive each DataZone environment to GONE before parent delete.
  Pass D:   Drop orphaned `glue_db_<env_id>` Glue DBs.
  Pass E:   Force-delete the project with --skip-deletion-check.
  Pass F:   Strip dangling principals from LF data-lake admins (3x).
  Pass G:   Drain + delete the tooling S3 bucket (versions + delete-markers).
  Pass H:   Strip the AllowProjectUserRoleForSparkLogs KMS statement.
  Pass I:   Detach the IAM inline policies on the dynamic project user role.
  Pass E2:  Recovery retry for the project (polls + re-force-deletes if a
             SMUS-owned nested stack dragged the project back into
             DELETE_FAILED after the initial Pass E ran).

Note: the "retain-resources" hardening passes (rSUSDomainOwnerIAMRole,
rAddDataLakeAdministratorToLakeFormation) are NOT in the Lambda — those
are CloudFormation-side retries that the customer's `delete-stack` call
handles natively. CFN sees the failure, the operator re-issues
`delete-stack --retain-resources <id>`. We document this in the README
as the rare manual path.

Inputs (ResourceProperties):
  DomainId        - DataZone domain id
  AdminProjectId  - DataZone admin project id

The Lambda discovers everything else (project user role, Tooling SG,
tooling bucket, etc.) at runtime — by Delete time the props passed at
Create may be stale.
"""

from __future__ import annotations

import json
import logging
import time
from typing import Any

import boto3

LOG = logging.getLogger()
LOG.setLevel("INFO")

INLINE_POLICIES_TO_DETACH = [
    "GlueSparkLogsAccess",
    "GlueDataBucketAccess",
    "GlueConnectionAccess",
    "CodeCommitAccess",
    "CodeConnectionsAccess",
    "LakeFormationFGACAccess",
    "GlueCatalogReadAccess",
]


def run(props: dict) -> dict:
    domain_id = props.get("DomainId", "")
    admin_project_id = props.get("AdminProjectId", "")
    region = props.get("Region") or boto3.Session().region_name or "us-east-1"

    LOG.info("teardown.run domain=%s project=%s region=%s", domain_id, admin_project_id, region)

    # Discover runtime state at delete time (props may be stale).
    runtime = _discover_runtime(domain_id, admin_project_id, region)
    LOG.info("runtime=%s", json.dumps(runtime))

    # Pass H + I: KMS strip + IAM inline detach (fast, do these first
    # so even a partial run leaves the dynamic role unencumbered).
    if runtime["project_user_role"]:
        _strip_kms_statement(runtime["tooling_bucket"], runtime["project_user_role"], region)
        _detach_inline_policies(runtime["project_user_role"])

    # Pass A + A' + B: VPC endpoints, orphan ENIs, cross-SG ingress.
    if runtime["tooling_sg"]:
        _drain_vpc_endpoints(runtime["tooling_sg"], region)
        _drain_orphan_enis(runtime["tooling_sg"], region)
        _revoke_cross_sg_ingress(runtime["tooling_sg"], region)

    # Pass A2: Terminate active Athena Spark sessions on the project's
    # workgroup. SMUS auto-creates an `AthenaSparkWorkgroup` inside its
    # own nested env stack (`DataZone-Env-<envId>`). When the env stack
    # tries to delete that workgroup with active Spark sessions, the
    # Athena API returns 400 "Unable to delete workgroup with non
    # terminated sessions" and the env stack stays in DELETE_FAILED —
    # which then drags the parent project into DELETE_FAILED a few
    # minutes later, defeating Pass E. Terminating the sessions here
    # (before Pass C drains envs) clears the blocker.
    if admin_project_id:
        _drain_athena_sessions(admin_project_id, region)

    # Pass C + D: Drive envs to GONE + drop orphan glue_db_*.
    if domain_id and admin_project_id:
        _drain_environments(domain_id, admin_project_id, region)
        _drop_orphan_glue_dbs(domain_id, region)

    # Pass E: Force-delete the project if it's stuck.
    if domain_id and admin_project_id:
        _force_delete_project(domain_id, admin_project_id, region)

    # Pass F: Strip dangling LF admins. Pass the dynamic project user
    # role so it's pre-stripped — CFN's `rAddDataLakeAdministratorToLakeFormation`
    # delete handler runs ~4 min later, by which time the project sub-stack
    # has deleted the role, leaving a stale entry CFN can't remove.
    _strip_dangling_lf_admins(region, project_user_role=runtime["project_user_role"])

    # Pass G: Drain + delete tooling bucket. (Lf the BlueprintStack
    # has DeletionPolicy: Retain on this bucket, CFN won't delete it
    # — this Lambda must.)
    if runtime["tooling_bucket"]:
        _drain_and_delete_bucket(runtime["tooling_bucket"], region)

    # Pass E2: Recovery retry for the project. The rPreDelete Lambda
    # only runs once — at the *start* of CFN's stack-delete cascade.
    # If a SMUS-owned nested env stack (DataZone-Env-*) fails ~5 min
    # later and drags the project back into DELETE_FAILED, there's
    # nothing in the original Lambda invocation that catches that.
    # Pass E2 polls the project status one more time at the end of
    # the Lambda window and re-issues the force-delete if needed.
    # This is a best-effort recovery — Pass A2 above is the actual
    # fix for the common Athena-session blocker; Pass E2 is the
    # safety net for whatever else might race the project.
    if domain_id and admin_project_id:
        _retry_force_delete_project(domain_id, admin_project_id, region)

    return {"Status": "teardown complete"}


# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

def _discover_runtime(domain_id: str, project_id: str, region: str) -> dict[str, Any]:
    """Resolve project_user_role, tooling_sg, tooling_bucket — empty strings on miss."""
    out: dict[str, Any] = {
        "project_user_role": "",
        "tooling_sg": "",
        "tooling_bucket": "",
    }
    if not domain_id or not project_id:
        return out

    sts = boto3.client("sts", region_name=region)
    account_id = sts.get_caller_identity()["Account"]
    out["tooling_bucket"] = f"amazon-datazone-tooling-{account_id}-{region}"

    dz = boto3.client("datazone", region_name=region)
    try:
        envs = dz.list_environments(
            domainIdentifier=domain_id,
            projectIdentifier=project_id,
        ).get("items", [])
    except dz.exceptions.ClientError as exc:
        LOG.warning("list_environments failed: %s", exc)
        return out

    for env in envs:
        if env["name"] != "Tooling":
            continue
        try:
            detail = dz.get_environment(domainIdentifier=domain_id, identifier=env["id"])
        except dz.exceptions.ClientError:
            continue
        for resource in detail.get("provisionedResources", []):
            name = resource.get("name", "")
            value = resource.get("value", "")
            if name == "userRoleArn":
                out["project_user_role"] = value
            elif name == "securityGroup":
                out["tooling_sg"] = value
        break
    return out


# ---------------------------------------------------------------------------
# Pass A2: Athena Spark session drain
# ---------------------------------------------------------------------------

def _drain_athena_sessions(project_id: str, region: str) -> None:
    """Terminate active Athena Spark sessions on the project's workgroup.

    SMUS auto-creates an Athena workgroup for the Tooling environment with
    the well-known name pattern ``sagemaker-studio-spark-workgroup-<projectId>``
    inside the SMUS-owned ``DataZone-Env-<envId>`` nested stack. When the
    env stack tries to delete that workgroup with active Spark sessions,
    Athena returns 400 ``Unable to delete workgroup with non terminated
    sessions``, the env stack DELETE_FAILEDs, and the parent project
    eventually drops into DELETE_FAILED too.

    This pass enumerates Athena workgroups whose name matches the
    project pattern, lists their non-terminated sessions, and issues
    ``terminate-session`` on each. Session termination is async on
    Athena's side (state goes ``TERMINATED`` quickly), so we don't
    need to poll.

    Best-effort: no exception escalates to the caller — a session
    that can't be terminated will just get re-flagged when the env
    stack tries to delete the workgroup.
    """
    LOG.info("Pass A2: drain Athena Spark sessions for project %s", project_id)
    try:
        athena = boto3.client("athena", region_name=region)
    except Exception as exc:
        LOG.warning("  athena client init failed: %s", exc)
        return

    # SMUS workgroup names follow this pattern. Check both the explicit
    # known shape and a broader contains() fallback in case AWS adds a
    # version suffix down the line.
    expected_wg = f"sagemaker-studio-spark-workgroup-{project_id}"
    target_workgroups: list[str] = []
    try:
        paginator = athena.get_paginator("list_work_groups")
        for page in paginator.paginate():
            for wg in page.get("WorkGroups", []):
                name = wg.get("Name", "")
                if name == expected_wg or project_id in name:
                    target_workgroups.append(name)
    except athena.exceptions.ClientError as exc:
        LOG.warning("  list_work_groups failed: %s", exc)
        return

    if not target_workgroups:
        LOG.info("  = no Athena workgroups for project %s", project_id)
        return

    for wg in target_workgroups:
        # Only ACTIVE / IDLE / BUSY / CREATING / FAILED sessions block
        # workgroup delete; TERMINATED / TERMINATING are no-ops.
        try:
            session_pages = athena.get_paginator("list_sessions").paginate(
                WorkGroup=wg,
            )
        except athena.exceptions.ClientError as exc:
            LOG.warning("  list_sessions failed for %s: %s", wg, exc)
            continue

        terminated = 0
        for spage in session_pages:
            for session in spage.get("Sessions", []):
                state = (session.get("Status") or {}).get("State", "")
                if state in ("TERMINATED", "TERMINATING"):
                    continue
                sid = session.get("SessionId", "")
                if not sid:
                    continue
                try:
                    athena.terminate_session(SessionId=sid)
                    LOG.info("  + terminated %s session %s (state=%s)", wg, sid, state)
                    terminated += 1
                except athena.exceptions.ClientError as exc:
                    LOG.warning("  terminate_session failed on %s: %s", sid, exc)
        if terminated == 0:
            LOG.info("  = no live sessions on %s", wg)


# ---------------------------------------------------------------------------
# Pass A: VPC endpoint drain
# ---------------------------------------------------------------------------

def _drain_vpc_endpoints(sg_id: str, region: str) -> None:
    LOG.info("Pass A: drain VPC endpoints on SG %s", sg_id)
    ec2 = boto3.client("ec2", region_name=region)
    paginator = ec2.get_paginator("describe_vpc_endpoints")
    vpce_ids = []
    for page in paginator.paginate():
        for ep in page.get("VpcEndpoints", []):
            if any(g.get("GroupId") == sg_id for g in ep.get("Groups") or []):
                vpce_ids.append(ep["VpcEndpointId"])
    if vpce_ids:
        try:
            ec2.delete_vpc_endpoints(VpcEndpointIds=vpce_ids)
            LOG.info("  + drained %d VPC endpoint(s): %s", len(vpce_ids), vpce_ids)
        except ec2.exceptions.ClientError as exc:
            LOG.warning("  delete_vpc_endpoints failed: %s", exc)
    else:
        LOG.info("  = no VPC endpoints on SG")


# ---------------------------------------------------------------------------
# Pass A': Orphan ENI drain
# ---------------------------------------------------------------------------

def _drain_orphan_enis(sg_id: str, region: str) -> None:
    LOG.info("Pass A': drain orphan ENIs on SG %s", sg_id)
    ec2 = boto3.client("ec2", region_name=region)
    paginator = ec2.get_paginator("describe_network_interfaces")
    for page in paginator.paginate(Filters=[{"Name": "group-id", "Values": [sg_id]}]):
        for eni in page.get("NetworkInterfaces", []):
            eni_id = eni["NetworkInterfaceId"]
            attach = eni.get("Attachment") or {}
            if attach.get("AttachmentId"):
                try:
                    ec2.detach_network_interface(AttachmentId=attach["AttachmentId"], Force=True)
                    LOG.info("  + force-detached %s", eni_id)
                    time.sleep(8)  # let the detach settle
                except ec2.exceptions.ClientError as exc:
                    LOG.warning("  detach failed on %s: %s", eni_id, exc)
            try:
                ec2.delete_network_interface(NetworkInterfaceId=eni_id)
                LOG.info("  + deleted %s", eni_id)
            except ec2.exceptions.ClientError as exc:
                LOG.warning("  delete_network_interface failed on %s: %s", eni_id, exc)


# ---------------------------------------------------------------------------
# Pass B: cross-SG ingress revoke
# ---------------------------------------------------------------------------

def _revoke_cross_sg_ingress(sg_id: str, region: str) -> None:
    LOG.info("Pass B: revoke cross-SG ingress referencing %s", sg_id)
    ec2 = boto3.client("ec2", region_name=region)

    siblings: set[str] = set()
    paginator = ec2.get_paginator("describe_security_groups")
    for page in paginator.paginate(Filters=[{"Name": "ip-permission.group-id", "Values": [sg_id]}]):
        for grp in page.get("SecurityGroups", []):
            siblings.add(grp["GroupId"])
    siblings.discard(sg_id)  # don't iterate self

    for sib in siblings:
        try:
            rule_pages = ec2.describe_security_group_rules(
                Filters=[{"Name": "group-id", "Values": [sib]}],
            )["SecurityGroupRules"]
        except ec2.exceptions.ClientError:
            continue
        rules_to_revoke = [
            r["SecurityGroupRuleId"]
            for r in rule_pages
            if (r.get("ReferencedGroupInfo") or {}).get("GroupId") == sg_id
        ]
        if rules_to_revoke:
            try:
                ec2.revoke_security_group_ingress(
                    GroupId=sib,
                    SecurityGroupRuleIds=rules_to_revoke,
                )
                LOG.info("  + revoked %d ingress rule(s) on %s referencing %s", len(rules_to_revoke), sib, sg_id)
            except ec2.exceptions.ClientError as exc:
                LOG.warning("  revoke failed on %s: %s", sib, exc)


# ---------------------------------------------------------------------------
# Pass C: env drain
# ---------------------------------------------------------------------------

def _drain_environments(domain_id: str, project_id: str, region: str) -> None:
    LOG.info("Pass C: drain environments")
    dz = boto3.client("datazone", region_name=region)

    try:
        envs = dz.list_environments(
            domainIdentifier=domain_id,
            projectIdentifier=project_id,
        ).get("items", [])
    except dz.exceptions.ClientError as exc:
        LOG.warning("  list_environments failed: %s", exc)
        return

    for env in envs:
        env_id = env["id"]
        if env["status"] in ("DELETED", "DELETING"):
            continue
        try:
            dz.delete_environment(domainIdentifier=domain_id, identifier=env_id)
            LOG.info("  + delete-environment %s issued", env_id)
        except dz.exceptions.ClientError as exc:
            LOG.warning("  delete_environment %s failed: %s", env_id, exc)
            continue
        # Poll up to 5 min per env (Lambda budget aware).
        for _ in range(30):
            try:
                detail = dz.get_environment(domainIdentifier=domain_id, identifier=env_id)
                if detail["status"] in ("DELETED", "DELETE_FAILED"):
                    LOG.info("  = env %s status=%s", env_id, detail["status"])
                    break
            except dz.exceptions.ClientError:
                LOG.info("  = env %s gone", env_id)
                break
            time.sleep(10)


# ---------------------------------------------------------------------------
# Pass D: orphan glue_db_* drop
# ---------------------------------------------------------------------------

def _drop_orphan_glue_dbs(domain_id: str, region: str) -> None:
    LOG.info("Pass D: drop orphan glue_db_*")
    glue = boto3.client("glue", region_name=region)
    lf = boto3.client("lakeformation", region_name=region)
    dz = boto3.client("datazone", region_name=region)
    sts = boto3.client("sts", region_name=region)
    caller_arn = sts.get_caller_identity()["Arn"]
    # Strip session suffix to get the role ARN.
    if ":assumed-role/" in caller_arn:
        # arn:aws:sts::ACCT:assumed-role/RoleName/SessionName
        parts = caller_arn.split(":")
        role_name = parts[5].split("/")[1]
        principal = f"arn:aws:iam::{parts[4]}:role/{role_name}"
    else:
        principal = caller_arn

    # Build the set of currently-active DataZone domain IDs in the
    # account/region. Any glue_db_* whose LocationUri references a
    # domain NOT in this set is an orphan from a prior teardown and
    # safe to drop. Includes the domain currently being torn down
    # (`domain_id`) so its DBs are also caught here.
    active_domain_ids: set[str] = set()
    try:
        for d in dz.list_domains().get("items", []):
            active_domain_ids.add(d["id"])
    except dz.exceptions.ClientError as exc:
        LOG.warning("  list_domains failed; falling back to current-domain-only scope: %s", exc)
        if domain_id:
            active_domain_ids.add("__SENTINEL_KEEP_NONE__")  # drop only DBs scoped to current domain below
    LOG.info("  active domains in region: %s", sorted(active_domain_ids) or ["<none>"])

    paginator = glue.get_paginator("get_databases")
    for page in paginator.paginate():
        for db in page.get("DatabaseList", []):
            db_name = db["Name"]
            location = db.get("LocationUri", "") or ""
            if not db_name.startswith("glue_db_"):
                continue
            # Decision rule:
            #   * If LocationUri references the domain currently being
            #     torn down: drop it (cleanup of own footprint).
            #   * If LocationUri references a domain not in the active
            #     set: drop it (orphan from a prior teardown that left
            #     it behind).
            #   * Otherwise (LocationUri references some OTHER active
            #     domain): leave it alone — that's some other live
            #     stack's data.
            should_drop = False
            if domain_id and domain_id in location:
                should_drop = True
                reason = "current domain"
            else:
                referenced = [d for d in active_domain_ids if d in location]
                if not referenced:
                    should_drop = True
                    reason = "orphan from gone domain"
                else:
                    reason = f"belongs to active domain {referenced[0]}"
            if not should_drop:
                LOG.info("  = keeping %s (%s)", db_name, reason)
                continue
            LOG.info("  + dropping %s (%s)", db_name, reason)
            # Grant DROP to ourselves (idempotent), then delete.
            try:
                lf.grant_permissions(
                    Principal={"DataLakePrincipalIdentifier": principal},
                    Resource={"Database": {"Name": db_name}},
                    Permissions=["DROP"],
                )
            except lf.exceptions.ClientError:
                pass
            try:
                # Delete tables first.
                tpaginator = glue.get_paginator("get_tables")
                for tpage in tpaginator.paginate(DatabaseName=db_name):
                    for table in tpage.get("TableList", []):
                        try:
                            glue.delete_table(DatabaseName=db_name, Name=table["Name"])
                        except glue.exceptions.ClientError:
                            pass
                glue.delete_database(Name=db_name)
                LOG.info("  + dropped %s", db_name)
            except glue.exceptions.ClientError as exc:
                LOG.warning("  drop %s failed: %s", db_name, exc)


# ---------------------------------------------------------------------------
# Pass E: force-delete project
# ---------------------------------------------------------------------------

def _force_delete_project(domain_id: str, project_id: str, region: str) -> None:
    LOG.info("Pass E: force-delete project %s", project_id)
    dz = boto3.client("datazone", region_name=region)
    try:
        detail = dz.get_project(domainIdentifier=domain_id, identifier=project_id)
    except dz.exceptions.ClientError as exc:
        LOG.info("  = project not found: %s", exc)
        return
    status = detail.get("projectStatus", "")
    # Only force-delete when the project is genuinely stuck in
    # DELETE_FAILED. On a healthy stack delete, the project will be
    # ACTIVE at this point — CFN's own `AWS::DataZone::Project` delete
    # handler will issue the delete normally. If we pre-delete here
    # via skipDeletionCheck, CFN's handler hits "Project already
    # DELETING" and the stack delete fails. The skip-deletion-check
    # path is reserved for the recovery case (project stuck after a
    # prior failed delete-stack attempt).
    if status != "DELETE_FAILED":
        LOG.info("  = project status=%s; skipping force delete (CFN will handle)", status)
        return
    try:
        dz.delete_project(
            domainIdentifier=domain_id,
            identifier=project_id,
            skipDeletionCheck=True,
        )
        LOG.info("  + delete-project --skip-deletion-check issued")
    except dz.exceptions.ClientError as exc:
        LOG.warning("  delete_project failed: %s", exc)


def _retry_force_delete_project(domain_id: str, project_id: str, region: str) -> None:
    """Pass E2 — recovery retry for the project at end of Lambda window.

    Pass E (above) runs near the start of the Lambda invocation, when
    the project should still be ACTIVE on a healthy delete and we
    only act on a pre-existing DELETE_FAILED. But on this stack, a
    SMUS-owned nested env stack (DataZone-Env-*) can fail ~5 minutes
    later and drag the project into DELETE_FAILED *after* Pass E
    already ran — the in-stack Lambda has no signal for that.

    Pass E2 is the safety net: poll the project status briefly (up
    to ~3 minutes), and if it's now DELETE_FAILED, re-issue the
    force-delete. Pass A2 above is the actual fix for the most common
    blocker (Athena sessions); E2 catches whatever else might race.
    """
    LOG.info("Pass E2: recovery retry for project %s", project_id)
    dz = boto3.client("datazone", region_name=region)
    # Up to 18 polls * 10s = 3 minutes. Generous enough to catch a
    # SMUS-owned nested stack that DELETE_FAILEDs a few minutes after
    # Pass E ran, tight enough to fit comfortably in the 15-minute
    # Lambda budget alongside the other passes.
    for attempt in range(18):
        try:
            detail = dz.get_project(domainIdentifier=domain_id, identifier=project_id)
        except dz.exceptions.ClientError:
            LOG.info("  = project gone (attempt %s); recovery not needed", attempt + 1)
            return
        status = detail.get("projectStatus", "")
        if status in ("DELETED",):
            LOG.info("  = project DELETED (attempt %s); recovery not needed", attempt + 1)
            return
        if status == "DELETE_FAILED":
            LOG.info("  + project re-entered DELETE_FAILED at attempt %s; re-issuing force delete", attempt + 1)
            try:
                dz.delete_project(
                    domainIdentifier=domain_id,
                    identifier=project_id,
                    skipDeletionCheck=True,
                )
                LOG.info("  + delete-project --skip-deletion-check re-issued")
            except dz.exceptions.ClientError as exc:
                LOG.warning("  delete_project retry failed: %s", exc)
            # After re-issuing, give it a few seconds to flip to
            # DELETING, then exit (don't block the rest of Pass G/H/I
            # for the long delete tail).
            time.sleep(10)
            return
        if status == "DELETING":
            LOG.info("  = project DELETING (attempt %s); waiting", attempt + 1)
        else:
            LOG.info("  = project status=%s (attempt %s)", status, attempt + 1)
        time.sleep(10)
    LOG.info("  = no DELETE_FAILED seen during E2 window; exiting")


# ---------------------------------------------------------------------------
# Pass F: dangling LF admin strip
# ---------------------------------------------------------------------------

def _strip_dangling_lf_admins(region: str, project_user_role: str = "") -> None:
    """Strip stale principals from the LF data-lake admins list.

    Two classes of stale entries are removed:

      1. **Currently dangling**: any admin whose underlying IAM role no
         longer exists. `iam.get_role` is the truth.
      2. **About-to-be-dangling** (Fix 2): the dynamic project user role
         (`datazone_usr_role_<projectId>_<envId>`) that we know CFN will
         delete later in the same teardown. By the time CFN's
         `AWS::LakeFormation::DataLakeSettings` delete handler runs (4-5
         minutes after this Lambda fires), the project user role has
         already been deleted by the project sub-stack, leaving a fresh
         dangling entry. We pre-strip it here so CFN doesn't trip.

    Pass the dynamic project user role's ARN as ``project_user_role`` to
    enable the second class. When called from the run() flow we already
    have it discovered; when called from a recovery context we may not,
    in which case only class 1 applies.
    """
    LOG.info("Pass F: strip dangling LF admins")
    lf = boto3.client("lakeformation", region_name=region)
    iam = boto3.client("iam", region_name=region)
    settings = lf.get_data_lake_settings()["DataLakeSettings"]
    admins = settings.get("DataLakeAdmins", [])

    # Build the set of "must-strip" ARNs: currently dangling roles
    # plus the about-to-be-dangling project user role (if known).
    pre_strip = set()
    if project_user_role:
        pre_strip.add(project_user_role)
        LOG.info("  pre-stripping about-to-be-dangling project user role: %s", project_user_role)

    cleaned = []
    changed = False
    for admin in admins:
        principal = admin.get("DataLakePrincipalIdentifier", "")
        if principal in pre_strip:
            LOG.info("  + dropping pre-strip target: %s", principal)
            changed = True
            continue
        if principal.startswith("arn:aws:iam::") and ":role/" in principal:
            role_name = principal.split("/")[-1]
            try:
                iam.get_role(RoleName=role_name)
                cleaned.append(admin)
            except iam.exceptions.NoSuchEntityException:
                LOG.info("  + dropping dangling: %s", principal)
                changed = True
        else:
            cleaned.append(admin)
    if changed:
        settings["DataLakeAdmins"] = cleaned
        lf.put_data_lake_settings(DataLakeSettings=settings)
        LOG.info("  + LF data-lake admins updated")
    else:
        LOG.info("  = no LF admins to strip")


# ---------------------------------------------------------------------------
# Pass G: tooling bucket drain + delete
# ---------------------------------------------------------------------------

def _drain_and_delete_bucket(bucket: str, region: str) -> None:
    LOG.info("Pass G: drain + delete tooling bucket %s", bucket)
    s3 = boto3.client("s3", region_name=region)
    try:
        s3.head_bucket(Bucket=bucket)
    except s3.exceptions.ClientError:
        LOG.info("  = bucket %s already gone", bucket)
        return

    # Drain versions + delete-markers.
    paginator = s3.get_paginator("list_object_versions")
    drained = 0
    for page in paginator.paginate(Bucket=bucket):
        objects = []
        for v in page.get("Versions") or []:
            objects.append({"Key": v["Key"], "VersionId": v["VersionId"]})
        for m in page.get("DeleteMarkers") or []:
            objects.append({"Key": m["Key"], "VersionId": m["VersionId"]})
        if objects:
            for i in range(0, len(objects), 1000):
                chunk = objects[i:i + 1000]
                s3.delete_objects(Bucket=bucket, Delete={"Objects": chunk, "Quiet": True})
                drained += len(chunk)
    LOG.info("  + drained %d versions/markers", drained)
    try:
        s3.delete_bucket(Bucket=bucket)
        LOG.info("  + deleted bucket %s", bucket)
    except s3.exceptions.ClientError as exc:
        LOG.warning("  delete_bucket failed: %s", exc)


# ---------------------------------------------------------------------------
# Pass H: KMS statement strip
# ---------------------------------------------------------------------------

def _strip_kms_statement(bucket: str, role_arn: str, region: str) -> None:
    LOG.info("Pass H: strip AllowProjectUserRoleForSparkLogs from tooling KMS")
    if not bucket:
        return
    s3 = boto3.client("s3", region_name=region)
    kms = boto3.client("kms", region_name=region)
    try:
        enc = s3.get_bucket_encryption(Bucket=bucket)
    except s3.exceptions.ClientError:
        return
    rules = enc["ServerSideEncryptionConfiguration"]["Rules"]
    kms_key_id = (rules[0]["ApplyServerSideEncryptionByDefault"] or {}).get("KMSMasterKeyID", "")
    if not kms_key_id:
        return
    kms_key_short = kms_key_id.split("/")[-1]
    try:
        meta = kms.describe_key(KeyId=kms_key_short)["KeyMetadata"]
    except kms.exceptions.ClientError:
        return
    if meta.get("KeyManager") != "CUSTOMER":
        return
    policy = json.loads(kms.get_key_policy(KeyId=kms_key_short, PolicyName="default")["Policy"])
    statements = policy.get("Statement", [])
    new_statements = [s for s in statements if s.get("Sid") != "AllowProjectUserRoleForSparkLogs"]
    if len(new_statements) != len(statements):
        policy["Statement"] = new_statements
        try:
            kms.put_key_policy(KeyId=kms_key_short, PolicyName="default", Policy=json.dumps(policy))
            LOG.info("  + removed AllowProjectUserRoleForSparkLogs")
        except kms.exceptions.ClientError as exc:
            LOG.warning("  put_key_policy failed: %s", exc)


# ---------------------------------------------------------------------------
# Pass I: IAM inline policy detach
# ---------------------------------------------------------------------------

def _detach_inline_policies(role_arn: str) -> None:
    LOG.info("Pass I: detach inline policies from %s", role_arn)
    iam = boto3.client("iam")
    role_name = role_arn.split("/")[-1]
    for policy_name in INLINE_POLICIES_TO_DETACH:
        try:
            iam.delete_role_policy(RoleName=role_name, PolicyName=policy_name)
            LOG.info("  + deleted inline %s", policy_name)
        except iam.exceptions.NoSuchEntityException:
            pass
        except iam.exceptions.ClientError as exc:
            LOG.warning("  delete_role_policy %s failed: %s", policy_name, exc)
