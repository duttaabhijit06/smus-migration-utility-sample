#!/usr/bin/env bash
#
# steps/03b_lakeformation-setup/run.sh — Configure Lake Formation permissions
# for SMUS integration.
#
# This step sets up:
#   1. AmazonDataZoneGlueAccess role for the domain
#   2. Lake Formation admin roles
#   3. S3 location registration with hybrid access
#   4. DATA_LOCATION_ACCESS grants for project and Glue roles
#   5. Database and table permissions with grant option
#   6. IAM policies on the project role for S3 and Glue access

if [ -z "${MT_WORKDIR:-}" ]; then
    MT_WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    export MT_WORKDIR
fi

# shellcheck source=../_lib/common.sh
# shellcheck disable=SC1091
source "${MT_WORKDIR}/steps/_lib/common.sh"

set -euo pipefail

mt_init "03b_lakeformation-setup" -- "$@"
mt_status started

mt_require_var MT_AWS_REGION
mt_require_var MT_SMUS_DOMAIN_ID
mt_require_var MT_ADMIN_PROJECT_ID
mt_require_var MT_SOURCE_ACCOUNT_ID
mt_require_var MT_TOOLING_USER_ROLE_ARN

# Extract role name from ARN
TOOLING_ROLE_NAME="${MT_TOOLING_USER_ROLE_ARN##*/}"
DOMAIN_ID="${MT_SMUS_DOMAIN_ID}"
ACCOUNT_ID="${MT_SOURCE_ACCOUNT_ID}"
REGION="${MT_AWS_REGION}"

# Role names
DATAZONE_GLUE_ROLE="AmazonDataZoneGlueAccess-${REGION}-${DOMAIN_ID}"
DATAZONE_GLUE_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${DATAZONE_GLUE_ROLE}"

# -----------------------------------------------------------------------------
# 1. Create AmazonDataZoneGlueAccess role if it doesn't exist

mt_log "checking AmazonDataZoneGlueAccess role..."

if ! mt_aws iam get-role --role-name "$DATAZONE_GLUE_ROLE" --region "$REGION" >/dev/null 2>&1; then
    mt_log "creating role ${DATAZONE_GLUE_ROLE}..."

    TRUST_POLICY=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "datazone.amazonaws.com"
            },
            "Action": "sts:AssumeRole",
            "Condition": {
                "StringEquals": {
                    "aws:SourceAccount": "${ACCOUNT_ID}"
                },
                "ForAllValues:StringLike": {
                    "aws:TagKeys": "datazone*"
                }
            }
        }
    ]
}
EOF
)

    mt_aws iam create-role \
        --role-name "$DATAZONE_GLUE_ROLE" \
        --assume-role-policy-document "$TRUST_POLICY" \
        --region "$REGION"

    mt_aws iam attach-role-policy \
        --role-name "$DATAZONE_GLUE_ROLE" \
        --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonDataZoneGlueManageAccessRolePolicy" \
        --region "$REGION"

    mt_log "waiting 10s for IAM propagation..."
    sleep 10
else
    mt_log "role ${DATAZONE_GLUE_ROLE} already exists"
fi

# -----------------------------------------------------------------------------
# 2. Add roles as Lake Formation administrators

mt_log "configuring Lake Formation admins..."

if mt_apply_mode; then
    # Get current LF settings.
    # Use plain `aws` (not `mt_aws`) for read-only capture so the
    # `STATUS: action ...` prefix the wrapper emits doesn't get mixed
    # into the captured JSON and break the downstream jq.
    CURRENT_SETTINGS=$(aws lakeformation get-data-lake-settings --region "$REGION")

    # Roles to add as LF admins
    ADMIN_ROLES=(
        "${MT_TOOLING_USER_ROLE_ARN}"
        "${DATAZONE_GLUE_ROLE_ARN}"
        "arn:aws:iam::${ACCOUNT_ID}:role/AmazonDataZoneServiceRole"
    )

    # Build updated settings
    NEW_SETTINGS=$(echo "$CURRENT_SETTINGS" | jq '.DataLakeSettings')
    for role in "${ADMIN_ROLES[@]}"; do
        NEW_SETTINGS=$(echo "$NEW_SETTINGS" | jq --arg r "$role" \
            '.DataLakeAdmins += [{"DataLakePrincipalIdentifier":$r}] | .DataLakeAdmins |= unique')
    done

    echo "$NEW_SETTINGS" > /tmp/lf-settings.json
    mt_aws lakeformation put-data-lake-settings \
        --data-lake-settings file:///tmp/lf-settings.json \
        --region "$REGION" || true

    mt_log "Lake Formation admins configured"
fi

# -----------------------------------------------------------------------------
# 3. Register S3 locations with hybrid access and grant permissions

mt_log "registering S3 locations in Lake Formation..."

# Get source S3 buckets from config (comma-separated list)
SOURCE_BUCKETS="${MT_SOURCE_S3_INCLUSION_LIST:-}"

if mt_apply_mode && [ -n "$SOURCE_BUCKETS" ]; then
    # Convert comma-separated to space-separated for iteration
    IFS=',' read -ra BUCKET_ARRAY <<< "$SOURCE_BUCKETS"
    for bucket in "${BUCKET_ARRAY[@]}"; do
        mt_log "processing bucket: $bucket"

        # Register bucket root with hybrid access
        mt_aws lakeformation register-resource \
            --resource-arn "arn:aws:s3:::${bucket}" \
            --use-service-linked-role \
            --hybrid-access-enabled \
            --region "$REGION" 2>/dev/null || true

        # Get all table locations from Glue databases
        DATABASES=$(aws glue get-databases --region "$REGION" 2>/dev/null | jq -r '.DatabaseList[].Name' || true)

        PREFIXES_REGISTERED=""
        for db in $DATABASES; do
            LOCATIONS=$(aws glue get-tables --database-name "$db" --region "$REGION" 2>/dev/null \
                | jq -r ".TableList[].StorageDescriptor.Location // empty" \
                | grep "s3://${bucket}/" \
                | sed "s|s3://${bucket}/||" \
                | cut -d'/' -f1-2 \
                | sort -u || true)

            for prefix in $LOCATIONS; do
                [ -z "$prefix" ] && continue

                # Skip if already registered this prefix
                if echo "$PREFIXES_REGISTERED" | grep -q "^${prefix}$"; then
                    continue
                fi
                PREFIXES_REGISTERED="${PREFIXES_REGISTERED}${prefix}
"

                RESOURCE_ARN="arn:aws:s3:::${bucket}/${prefix}"
                mt_log "  registering prefix: ${prefix}"

                # Register with hybrid access
                mt_aws lakeformation register-resource \
                    --resource-arn "$RESOURCE_ARN" \
                    --use-service-linked-role \
                    --hybrid-access-enabled \
                    --region "$REGION" 2>/dev/null || true

                # Grant DATA_LOCATION_ACCESS to project role
                mt_aws lakeformation grant-permissions \
                    --principal "{\"DataLakePrincipalIdentifier\":\"${MT_TOOLING_USER_ROLE_ARN}\"}" \
                    --resource "{\"DataLocation\":{\"ResourceArn\":\"${RESOURCE_ARN}\"}}" \
                    --permissions "DATA_LOCATION_ACCESS" \
                    --permissions-with-grant-option "DATA_LOCATION_ACCESS" \
                    --region "$REGION" 2>/dev/null || true

                # Grant DATA_LOCATION_ACCESS to DataZone Glue role
                mt_aws lakeformation grant-permissions \
                    --principal "{\"DataLakePrincipalIdentifier\":\"${DATAZONE_GLUE_ROLE_ARN}\"}" \
                    --resource "{\"DataLocation\":{\"ResourceArn\":\"${RESOURCE_ARN}\"}}" \
                    --permissions "DATA_LOCATION_ACCESS" \
                    --permissions-with-grant-option "DATA_LOCATION_ACCESS" \
                    --region "$REGION" 2>/dev/null || true
            done
        done

        # Grant on bucket root as well
        mt_aws lakeformation grant-permissions \
            --principal "{\"DataLakePrincipalIdentifier\":\"${MT_TOOLING_USER_ROLE_ARN}\"}" \
            --resource "{\"DataLocation\":{\"ResourceArn\":\"arn:aws:s3:::${bucket}\"}}" \
            --permissions "DATA_LOCATION_ACCESS" \
            --permissions-with-grant-option "DATA_LOCATION_ACCESS" \
            --region "$REGION" 2>/dev/null || true

        mt_aws lakeformation grant-permissions \
            --principal "{\"DataLakePrincipalIdentifier\":\"${DATAZONE_GLUE_ROLE_ARN}\"}" \
            --resource "{\"DataLocation\":{\"ResourceArn\":\"arn:aws:s3:::${bucket}\"}}" \
            --permissions "DATA_LOCATION_ACCESS" \
            --permissions-with-grant-option "DATA_LOCATION_ACCESS" \
            --region "$REGION" 2>/dev/null || true
    done
fi

# -----------------------------------------------------------------------------
# 4. Grant database and table permissions

mt_log "granting database and table permissions..."

if mt_apply_mode; then
    DATABASES=$(aws glue get-databases --region "$REGION" 2>/dev/null | jq -r '.DatabaseList[].Name' || true)

    for db in $DATABASES; do
        mt_log "  database: $db"

        # Grant database permissions to project role
        mt_aws lakeformation grant-permissions \
            --principal "{\"DataLakePrincipalIdentifier\":\"${MT_TOOLING_USER_ROLE_ARN}\"}" \
            --resource "{\"Database\":{\"Name\":\"${db}\"}}" \
            --permissions "DESCRIBE" "ALTER" "DROP" "CREATE_TABLE" \
            --permissions-with-grant-option "DESCRIBE" \
            --region "$REGION" 2>/dev/null || true

        # Grant database permissions to DataZone Glue role
        mt_aws lakeformation grant-permissions \
            --principal "{\"DataLakePrincipalIdentifier\":\"${DATAZONE_GLUE_ROLE_ARN}\"}" \
            --resource "{\"Database\":{\"Name\":\"${db}\"}}" \
            --permissions "DESCRIBE" "ALTER" "DROP" "CREATE_TABLE" \
            --permissions-with-grant-option "DESCRIBE" "ALTER" "DROP" "CREATE_TABLE" \
            --region "$REGION" 2>/dev/null || true

        # NOTE: We intentionally do NOT re-grant `IAM_ALLOWED_PRINCIPALS`
        # here. The migrate.sh `_lakeformation_bootstrap` helper revokes
        # this default LF grant on every external Glue DB/table so the
        # asset is "managed by Lake Formation" — restoring the grant
        # would re-trigger the "Asset cannot be queried with tools"
        # badge in SMUS Visual ETL. See migrate.sh comments for the
        # full rationale.

        # Grant table permissions
        TABLES=$(aws glue get-tables --database-name "$db" --region "$REGION" 2>/dev/null | jq -r '.TableList[].Name' || true)

        for table in $TABLES; do
            [ -z "$table" ] && continue

            # Project role
            mt_aws lakeformation grant-permissions \
                --principal "{\"DataLakePrincipalIdentifier\":\"${MT_TOOLING_USER_ROLE_ARN}\"}" \
                --resource "{\"Table\":{\"DatabaseName\":\"${db}\",\"Name\":\"${table}\"}}" \
                --permissions "SELECT" "DESCRIBE" "ALTER" "INSERT" "DELETE" "DROP" \
                --permissions-with-grant-option "SELECT" "DESCRIBE" \
                --region "$REGION" 2>/dev/null || true

            # DataZone Glue role (with full grant option for subscription management)
            mt_aws lakeformation grant-permissions \
                --principal "{\"DataLakePrincipalIdentifier\":\"${DATAZONE_GLUE_ROLE_ARN}\"}" \
                --resource "{\"Table\":{\"DatabaseName\":\"${db}\",\"Name\":\"${table}\"}}" \
                --permissions "SELECT" "DESCRIBE" "ALTER" "INSERT" "DELETE" "DROP" \
                --permissions-with-grant-option "SELECT" "DESCRIBE" "ALTER" "INSERT" "DELETE" "DROP" \
                --region "$REGION" 2>/dev/null || true

            # NOTE: Intentionally NOT re-granting IAM_ALLOWED_PRINCIPALS on
            # the table here. The migrate.sh `_lakeformation_bootstrap`
            # helper revokes this default LF grant on every external
            # Glue table so the table is "managed by Lake Formation".
            # Restoring it here would put the table back into legacy
            # IAM-default mode, which makes Iceberg's GlueCatalog treat
            # the table as invisible (Spark surfaces this as
            # `[TABLE_OR_VIEW_NOT_FOUND]` in Visual ETL).
        done
    done
fi

# -----------------------------------------------------------------------------
# 5. Add IAM policies to project role

mt_log "adding IAM policies to project role..."

if mt_apply_mode; then
    # GlueSparkLogsAccess - for Spark UI logs
    SPARK_LOGS_POLICY=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::amazon-datazone-tooling-${ACCOUNT_ID}-${REGION}",
                "arn:aws:s3:::amazon-datazone-tooling-${ACCOUNT_ID}-${REGION}/*"
            ]
        }
    ]
}
EOF
)

    mt_aws iam put-role-policy \
        --role-name "$TOOLING_ROLE_NAME" \
        --policy-name GlueSparkLogsAccess \
        --policy-document "$SPARK_LOGS_POLICY" \
        --region "$REGION" || true

    # GlueDataBucketAccess - for source data buckets
    if [ -n "$SOURCE_BUCKETS" ]; then
        # Build resource array
        RESOURCES="["
        FIRST=true
        for bucket in $SOURCE_BUCKETS; do
            if [ "$FIRST" = true ]; then
                FIRST=false
            else
                RESOURCES="${RESOURCES},"
            fi
            RESOURCES="${RESOURCES}\"arn:aws:s3:::${bucket}\",\"arn:aws:s3:::${bucket}/*\""
        done
        RESOURCES="${RESOURCES}]"

        DATA_BUCKET_POLICY=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:ListBucket",
                "s3:GetBucketLocation"
            ],
            "Resource": ${RESOURCES}
        }
    ]
}
EOF
)

        mt_aws iam put-role-policy \
            --role-name "$TOOLING_ROLE_NAME" \
            --policy-name GlueDataBucketAccess \
            --policy-document "$DATA_BUCKET_POLICY" \
            --region "$REGION" || true
    fi

    # GlueConnectionAccess - for Glue connections and secrets
    CONNECTION_POLICY=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "glue:GetConnection",
                "glue:GetConnections"
            ],
            "Resource": [
                "arn:aws:glue:${REGION}:${ACCOUNT_ID}:connection/*",
                "arn:aws:glue:${REGION}:${ACCOUNT_ID}:catalog"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "secretsmanager:GetSecretValue"
            ],
            "Resource": [
                "arn:aws:secretsmanager:${REGION}:${ACCOUNT_ID}:secret:smus-seed/*",
                "arn:aws:secretsmanager:${REGION}:${ACCOUNT_ID}:secret:SmusMigration/*",
                "arn:aws:secretsmanager:${REGION}:${ACCOUNT_ID}:secret:SageMakerUnifiedStudio-Glue-*"
            ]
        }
    ]
}
EOF
)

    mt_aws iam put-role-policy \
        --role-name "$TOOLING_ROLE_NAME" \
        --policy-name GlueConnectionAccess \
        --policy-document "$CONNECTION_POLICY" \
        --region "$REGION" || true

    mt_log "IAM policies added"
fi

# -----------------------------------------------------------------------------
# 6. Register DataZone tooling bucket locations

mt_log "registering DataZone tooling bucket locations..."

if mt_apply_mode; then
    TOOLING_BUCKET="amazon-datazone-tooling-${ACCOUNT_ID}-${REGION}"
    PROJECT_PATH="${DOMAIN_ID}/${MT_ADMIN_PROJECT_ID}/dev"

    # Register glue logs path
    mt_aws lakeformation register-resource \
        --resource-arn "arn:aws:s3:::${TOOLING_BUCKET}/${PROJECT_PATH}/glue" \
        --use-service-linked-role \
        --region "$REGION" 2>/dev/null || true

    mt_aws lakeformation grant-permissions \
        --principal "{\"DataLakePrincipalIdentifier\":\"${MT_TOOLING_USER_ROLE_ARN}\"}" \
        --resource "{\"DataLocation\":{\"ResourceArn\":\"arn:aws:s3:::${TOOLING_BUCKET}/${PROJECT_PATH}/glue\"}}" \
        --permissions "DATA_LOCATION_ACCESS" \
        --region "$REGION" 2>/dev/null || true
fi

mt_log "Lake Formation setup complete"
mt_status ok
exit 0
