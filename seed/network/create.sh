#!/usr/bin/env bash
#
# seed/network/create.sh — provision a self-contained VPC for the seed.
#
# Why a dedicated network module?
#
#   * MWAA refuses public subnets ("The subnets must be private").
#     Provisioning private subnets requires a NAT gateway, which in
#     turn requires a public subnet + IGW + EIP.
#   * Glue VPC jobs need an S3 endpoint or NAT egress (covered by both
#     the S3 gateway endpoint and the NAT gateway here).
#   * MSK Serverless, RDS, Lambda VPC ENIs all benefit from a stable,
#     known SG that the seed owns end-to-end.
#
# This module creates the entire network surface in one shot:
#
#   * 1 VPC (CIDR 10.220.0.0/16)
#   * IGW + attached
#   * 2 public subnets (10.220.0.0/24, 10.220.1.0/24) in 2 AZs
#   * 2 private subnets (10.220.10.0/24, 10.220.11.0/24) in same 2 AZs
#   * 1 EIP + 1 NAT gateway in public subnet 1
#   * 1 public route table (0.0.0.0/0 → IGW), associated with both
#     public subnets
#   * 1 private route table (0.0.0.0/0 → NAT), associated with both
#     private subnets
#   * 1 S3 gateway endpoint attached to BOTH route tables
#   * 1 security group (smus-seed-vpc-sg) allowing in-VPC traffic
#     (self-referential) and outbound all
#
# After successful provision, this script also rewrites
# `seed/seed.config.json` so downstream modules (msk, rds, glue, mwaa)
# pick up the new IDs automatically:
#
#   * msk.vpc_subnet_ids        ← private subnets
#   * msk.security_group_ids    ← [seed SG]
#   * rds.vpc_id                ← new VPC
#   * rds.subnet_ids            ← private subnets
#   * glue.network_subnet_id    ← private subnet 1
#   * glue.network_security_group_id ← seed SG
#   * glue.network_availability_zone ← AZ of private subnet 1
#   * mwaa.subnet_ids           ← private subnets
#   * mwaa.security_group_ids   ← [seed SG]
#
# All resource IDs are persisted to seed.state.json so teardown can
# reverse the provisioning in strict reverse order.
#

set -uo pipefail

__net_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SBX_WORKDIR="${SBX_WORKDIR:-$(dirname "$(dirname "$__net_dir")")}"
export SBX_WORKDIR

# shellcheck source=../_lib/common.sh disable=SC1091
source "${SBX_WORKDIR}/seed/_lib/common.sh"

__SEED_CFG="$(sbx_config_path)"
if [ ! -f "$__SEED_CFG" ]; then
    sbx_status error config_missing
    exit 64
fi
if ! command -v jq >/dev/null 2>&1; then
    sbx_status error jq_required
    exit 64
fi
SBX_REGION="${SBX_REGION:-$(jq -r '.aws_region // empty' "$__SEED_CFG")}"
SBX_SOURCE_ACCOUNT_ID="${SBX_SOURCE_ACCOUNT_ID:-$(jq -r '.source_account_id // empty' "$__SEED_CFG")}"
SBX_SEED_NAME_PREFIX="${SBX_SEED_NAME_PREFIX:-$(jq -r '.seed_name_prefix // empty' "$__SEED_CFG")}"
export SBX_REGION SBX_SOURCE_ACCOUNT_ID SBX_SEED_NAME_PREFIX

sbx_init network "$@"
sbx_assert_same_account
sbx_status started

# -----------------------------------------------------------------------------
# Configuration knobs.
# -----------------------------------------------------------------------------
VPC_NAME="${SBX_SEED_NAME_PREFIX}-vpc"
VPC_CIDR="${SBX_SEED_VPC_CIDR:-10.220.0.0/16}"
IGW_NAME="${SBX_SEED_NAME_PREFIX}-igw"
PUBLIC_RT_NAME="${SBX_SEED_NAME_PREFIX}-rt-public"
PRIVATE_RT_NAME="${SBX_SEED_NAME_PREFIX}-rt-private"
NAT_EIP_NAME="${SBX_SEED_NAME_PREFIX}-nat-eip"
NAT_GW_NAME="${SBX_SEED_NAME_PREFIX}-nat"
SG_NAME="${SBX_SEED_NAME_PREFIX}-vpc-sg"
S3_ENDPOINT_NAME="${SBX_SEED_NAME_PREFIX}-vpce-s3"

PUB_SUBNET_1_NAME="${SBX_SEED_NAME_PREFIX}-public-1"
PUB_SUBNET_2_NAME="${SBX_SEED_NAME_PREFIX}-public-2"
PRIV_SUBNET_1_NAME="${SBX_SEED_NAME_PREFIX}-private-1"
PRIV_SUBNET_2_NAME="${SBX_SEED_NAME_PREFIX}-private-2"

PUB_SUBNET_1_CIDR="${SBX_SEED_PUB_SUBNET_1_CIDR:-10.220.0.0/24}"
PUB_SUBNET_2_CIDR="${SBX_SEED_PUB_SUBNET_2_CIDR:-10.220.1.0/24}"
PRIV_SUBNET_1_CIDR="${SBX_SEED_PRIV_SUBNET_1_CIDR:-10.220.10.0/24}"
PRIV_SUBNET_2_CIDR="${SBX_SEED_PRIV_SUBNET_2_CIDR:-10.220.11.0/24}"

# -----------------------------------------------------------------------------
# Helpers.
# -----------------------------------------------------------------------------

# Find an existing tagged resource by Name tag. Returns the first match
# or empty string. Apply-mode only.
_find_tagged() {
    local _resource_type="$1"
    local _name="$2"
    aws ec2 describe-tags \
        --region "$SBX_REGION" \
        --filters "Name=resource-type,Values=${_resource_type}" \
                  "Name=key,Values=Name" \
                  "Name=value,Values=${_name}" \
        --query 'Tags[0].ResourceId' \
        --output text 2>/dev/null | grep -v '^None$' || true
}

_pick_two_azs() {
    aws ec2 describe-availability-zones \
        --region "$SBX_REGION" \
        --filters "Name=opt-in-status,Values=opt-in-not-required" \
        --query 'AvailabilityZones[?State==`available`] | [0:2].ZoneName' \
        --output text 2>/dev/null | tr '\t' ' '
}

# -----------------------------------------------------------------------------
# Main provision.
# -----------------------------------------------------------------------------

if ! sbx_apply_mode; then
    sbx_log "dry-run: would create VPC=${VPC_CIDR}, 2 public + 2 private subnets, IGW, NAT, SG, S3 endpoint"
    sbx_aws ec2 create-vpc --cidr-block "$VPC_CIDR" --region "$SBX_REGION" || true
    sbx_aws ec2 create-subnet --vpc-id "DRY-RUN-VPC" --cidr-block "$PUB_SUBNET_1_CIDR" --region "$SBX_REGION" || true
    sbx_aws ec2 create-subnet --vpc-id "DRY-RUN-VPC" --cidr-block "$PUB_SUBNET_2_CIDR" --region "$SBX_REGION" || true
    sbx_aws ec2 create-subnet --vpc-id "DRY-RUN-VPC" --cidr-block "$PRIV_SUBNET_1_CIDR" --region "$SBX_REGION" || true
    sbx_aws ec2 create-subnet --vpc-id "DRY-RUN-VPC" --cidr-block "$PRIV_SUBNET_2_CIDR" --region "$SBX_REGION" || true
    sbx_aws ec2 create-internet-gateway --region "$SBX_REGION" || true
    sbx_aws ec2 allocate-address --domain vpc --region "$SBX_REGION" || true
    sbx_aws ec2 create-nat-gateway --subnet-id "DRY-RUN-PUB-SUBNET" --allocation-id "DRY-RUN-EIP" --region "$SBX_REGION" || true
    sbx_aws ec2 create-route-table --vpc-id "DRY-RUN-VPC" --region "$SBX_REGION" || true
    sbx_aws ec2 create-security-group --vpc-id "DRY-RUN-VPC" --group-name "$SG_NAME" --description "seed VPC SG" --region "$SBX_REGION" || true
    sbx_aws ec2 create-vpc-endpoint --vpc-id "DRY-RUN-VPC" --service-name "com.amazonaws.${SBX_REGION}.s3" --vpc-endpoint-type Gateway --region "$SBX_REGION" || true
    sbx_status ok "network dry-run complete"
    exit 0
fi

# Step 1. VPC ----------------------------------------------------------------
sbx_status action "ensure-vpc ${VPC_NAME} cidr=${VPC_CIDR}"
VPC_ID="$(_find_tagged vpc "$VPC_NAME")"
if [ -z "$VPC_ID" ]; then
    VPC_ID="$(aws ec2 create-vpc \
        --region "$SBX_REGION" \
        --cidr-block "$VPC_CIDR" \
        --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${VPC_NAME}},{Key=sbx:seed-name-prefix,Value=${SBX_SEED_NAME_PREFIX}}]" \
        --query 'Vpc.VpcId' --output text 2>/dev/null || echo "")"
    if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ]; then
        sbx_status error "create-vpc failed"
        exit 1
    fi
    aws ec2 modify-vpc-attribute --region "$SBX_REGION" --vpc-id "$VPC_ID" --enable-dns-support >/dev/null
    aws ec2 modify-vpc-attribute --region "$SBX_REGION" --vpc-id "$VPC_ID" --enable-dns-hostnames >/dev/null
    sbx_log "created VPC ${VPC_ID}"
else
    sbx_log "found existing VPC ${VPC_ID}"
fi

# Step 2. Subnets ------------------------------------------------------------
read -r AZ1 AZ2 <<<"$(_pick_two_azs)"
if [ -z "$AZ1" ] || [ -z "$AZ2" ]; then
    sbx_status error "could not resolve 2 AZs in ${SBX_REGION}"
    exit 1
fi
sbx_log "AZs: ${AZ1}, ${AZ2}"

_ensure_subnet() {
    local _name="$1" _cidr="$2" _az="$3" _public="$4"
    local _id
    _id="$(_find_tagged subnet "$_name")"
    if [ -z "$_id" ]; then
        sbx_status action "create-subnet ${_name} cidr=${_cidr} az=${_az}" >&2
        _id="$(aws ec2 create-subnet \
            --region "$SBX_REGION" \
            --vpc-id "$VPC_ID" \
            --cidr-block "$_cidr" \
            --availability-zone "$_az" \
            --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${_name}},{Key=sbx:seed-name-prefix,Value=${SBX_SEED_NAME_PREFIX}}]" \
            --query 'Subnet.SubnetId' --output text 2>/dev/null || echo "")"
        if [ -z "$_id" ] || [ "$_id" = "None" ]; then
            sbx_status error "create-subnet failed for ${_name}" >&2
            exit 1
        fi
        if [ "$_public" = "1" ]; then
            aws ec2 modify-subnet-attribute --region "$SBX_REGION" --subnet-id "$_id" --map-public-ip-on-launch >/dev/null
        fi
    fi
    printf '%s' "$_id"
}

PUB_SUBNET_1_ID="$(_ensure_subnet "$PUB_SUBNET_1_NAME"  "$PUB_SUBNET_1_CIDR"  "$AZ1" 1)"
PUB_SUBNET_2_ID="$(_ensure_subnet "$PUB_SUBNET_2_NAME"  "$PUB_SUBNET_2_CIDR"  "$AZ2" 1)"
PRIV_SUBNET_1_ID="$(_ensure_subnet "$PRIV_SUBNET_1_NAME" "$PRIV_SUBNET_1_CIDR" "$AZ1" 0)"
PRIV_SUBNET_2_ID="$(_ensure_subnet "$PRIV_SUBNET_2_NAME" "$PRIV_SUBNET_2_CIDR" "$AZ2" 0)"
sbx_log "subnets: pub1=${PUB_SUBNET_1_ID} pub2=${PUB_SUBNET_2_ID} priv1=${PRIV_SUBNET_1_ID} priv2=${PRIV_SUBNET_2_ID}"

# Step 3. IGW + attach -------------------------------------------------------
sbx_status action "ensure-igw ${IGW_NAME}"
IGW_ID="$(_find_tagged internet-gateway "$IGW_NAME")"
if [ -z "$IGW_ID" ]; then
    IGW_ID="$(aws ec2 create-internet-gateway \
        --region "$SBX_REGION" \
        --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${IGW_NAME}},{Key=sbx:seed-name-prefix,Value=${SBX_SEED_NAME_PREFIX}}]" \
        --query 'InternetGateway.InternetGatewayId' --output text 2>/dev/null || echo "")"
    if [ -z "$IGW_ID" ] || [ "$IGW_ID" = "None" ]; then
        sbx_status error "create-internet-gateway failed"
        exit 1
    fi
fi
# Attach (idempotent — second attach errors but we tolerate).
aws ec2 attach-internet-gateway \
    --region "$SBX_REGION" \
    --internet-gateway-id "$IGW_ID" \
    --vpc-id "$VPC_ID" >/dev/null 2>&1 || true
sbx_log "IGW ${IGW_ID} attached to ${VPC_ID}"

# Step 4. NAT EIP + NAT Gateway ---------------------------------------------
sbx_status action "ensure-nat-eip ${NAT_EIP_NAME}"
NAT_EIP_ALLOC_ID="$(aws ec2 describe-addresses \
    --region "$SBX_REGION" \
    --filters "Name=tag:Name,Values=${NAT_EIP_NAME}" \
    --query 'Addresses[0].AllocationId' --output text 2>/dev/null | grep -v '^None$' || true)"
if [ -z "$NAT_EIP_ALLOC_ID" ]; then
    NAT_EIP_ALLOC_ID="$(aws ec2 allocate-address \
        --region "$SBX_REGION" \
        --domain vpc \
        --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${NAT_EIP_NAME}},{Key=sbx:seed-name-prefix,Value=${SBX_SEED_NAME_PREFIX}}]" \
        --query 'AllocationId' --output text 2>/dev/null || echo "")"
    if [ -z "$NAT_EIP_ALLOC_ID" ]; then
        sbx_status error "allocate-address failed"
        exit 1
    fi
fi
sbx_log "NAT EIP allocation ${NAT_EIP_ALLOC_ID}"

sbx_status action "ensure-nat-gateway ${NAT_GW_NAME}"
NAT_GW_ID="$(aws ec2 describe-nat-gateways \
    --region "$SBX_REGION" \
    --filter "Name=tag:Name,Values=${NAT_GW_NAME}" "Name=state,Values=available,pending" \
    --query 'NatGateways[0].NatGatewayId' --output text 2>/dev/null | grep -v '^None$' || true)"
if [ -z "$NAT_GW_ID" ]; then
    NAT_GW_ID="$(aws ec2 create-nat-gateway \
        --region "$SBX_REGION" \
        --subnet-id "$PUB_SUBNET_1_ID" \
        --allocation-id "$NAT_EIP_ALLOC_ID" \
        --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${NAT_GW_NAME}},{Key=sbx:seed-name-prefix,Value=${SBX_SEED_NAME_PREFIX}}]" \
        --query 'NatGateway.NatGatewayId' --output text || echo "")"
    if [ -z "$NAT_GW_ID" ] || [ "$NAT_GW_ID" = "None" ]; then
        sbx_status error "create-nat-gateway failed"
        exit 1
    fi
fi
sbx_log "NAT gateway ${NAT_GW_ID}; waiting for available state"
sbx_status action "nat_wait_available ${NAT_GW_ID}"
_i=0
_max=40   # 20 min budget (40 polls × 30 s)
_state=""
while [ "$_i" -lt "$_max" ]; do
    _state="$(aws ec2 describe-nat-gateways \
        --region "$SBX_REGION" \
        --nat-gateway-ids "$NAT_GW_ID" \
        --query 'NatGateways[0].State' --output text 2>/dev/null || echo "")"
    case "$_state" in
        available) break ;;
        failed|deleted|deleting)
            sbx_status error "nat_gateway_unhealthy state=${_state} id=${NAT_GW_ID}"
            exit 1
            ;;
    esac
    if [ $((_i % 4)) -eq 0 ]; then
        sbx_status in-progress "nat_wait_available poll=${_i}/${_max} state=${_state}"
    fi
    _i=$((_i + 1))
    sleep 30
done
if [ "$_state" != "available" ]; then
    sbx_status error "nat_wait_available_timeout state=${_state} id=${NAT_GW_ID}"
    exit 1
fi
sbx_status ok "nat_available id=${NAT_GW_ID}"

# Step 5. Public route table -------------------------------------------------
sbx_status action "ensure-public-rt ${PUBLIC_RT_NAME}"
PUBLIC_RT_ID="$(_find_tagged route-table "$PUBLIC_RT_NAME")"
if [ -z "$PUBLIC_RT_ID" ]; then
    PUBLIC_RT_ID="$(aws ec2 create-route-table \
        --region "$SBX_REGION" \
        --vpc-id "$VPC_ID" \
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PUBLIC_RT_NAME}},{Key=sbx:seed-name-prefix,Value=${SBX_SEED_NAME_PREFIX}}]" \
        --query 'RouteTable.RouteTableId' --output text 2>/dev/null || echo "")"
fi
# 0.0.0.0/0 → IGW (idempotent — second create fails with RouteAlreadyExists).
aws ec2 create-route \
    --region "$SBX_REGION" \
    --route-table-id "$PUBLIC_RT_ID" \
    --destination-cidr-block "0.0.0.0/0" \
    --gateway-id "$IGW_ID" >/dev/null 2>&1 || true
# Associate both public subnets (idempotent).
for _s in "$PUB_SUBNET_1_ID" "$PUB_SUBNET_2_ID"; do
    aws ec2 associate-route-table \
        --region "$SBX_REGION" \
        --route-table-id "$PUBLIC_RT_ID" \
        --subnet-id "$_s" >/dev/null 2>&1 || true
done

# Step 6. Private route table -----------------------------------------------
sbx_status action "ensure-private-rt ${PRIVATE_RT_NAME}"
PRIVATE_RT_ID="$(_find_tagged route-table "$PRIVATE_RT_NAME")"
if [ -z "$PRIVATE_RT_ID" ]; then
    PRIVATE_RT_ID="$(aws ec2 create-route-table \
        --region "$SBX_REGION" \
        --vpc-id "$VPC_ID" \
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PRIVATE_RT_NAME}},{Key=sbx:seed-name-prefix,Value=${SBX_SEED_NAME_PREFIX}}]" \
        --query 'RouteTable.RouteTableId' --output text 2>/dev/null || echo "")"
fi
# 0.0.0.0/0 → NAT (idempotent).
aws ec2 create-route \
    --region "$SBX_REGION" \
    --route-table-id "$PRIVATE_RT_ID" \
    --destination-cidr-block "0.0.0.0/0" \
    --nat-gateway-id "$NAT_GW_ID" >/dev/null 2>&1 || true
# Associate both private subnets.
for _s in "$PRIV_SUBNET_1_ID" "$PRIV_SUBNET_2_ID"; do
    aws ec2 associate-route-table \
        --region "$SBX_REGION" \
        --route-table-id "$PRIVATE_RT_ID" \
        --subnet-id "$_s" >/dev/null 2>&1 || true
done

# Step 7. Security group -----------------------------------------------------
sbx_status action "ensure-sg ${SG_NAME}"
SG_ID="$(aws ec2 describe-security-groups \
    --region "$SBX_REGION" \
    --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null | grep -v '^None$' || true)"
if [ -z "$SG_ID" ]; then
    SG_ID="$(aws ec2 create-security-group \
        --region "$SBX_REGION" \
        --vpc-id "$VPC_ID" \
        --group-name "$SG_NAME" \
        --description "Seed shared SG for ${SBX_SEED_NAME_PREFIX}" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${SG_NAME}},{Key=sbx:seed-name-prefix,Value=${SBX_SEED_NAME_PREFIX}}]" \
        --query 'GroupId' --output text 2>/dev/null || echo "")"
fi
# Self-referential ingress (in-VPC traffic).
aws ec2 authorize-security-group-ingress \
    --region "$SBX_REGION" \
    --group-id "$SG_ID" \
    --ip-permissions "IpProtocol=-1,UserIdGroupPairs=[{GroupId=${SG_ID}}]" >/dev/null 2>&1 || true
sbx_log "SG ${SG_ID}"

# Step 8. S3 gateway endpoint -----------------------------------------------
sbx_status action "ensure-s3-endpoint ${S3_ENDPOINT_NAME}"
S3_ENDPOINT_ID="$(aws ec2 describe-vpc-endpoints \
    --region "$SBX_REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
              "Name=service-name,Values=com.amazonaws.${SBX_REGION}.s3" \
              "Name=vpc-endpoint-type,Values=Gateway" \
    --query 'VpcEndpoints[0].VpcEndpointId' --output text 2>/dev/null | grep -v '^None$' || true)"
if [ -z "$S3_ENDPOINT_ID" ]; then
    S3_ENDPOINT_ID="$(aws ec2 create-vpc-endpoint \
        --region "$SBX_REGION" \
        --vpc-id "$VPC_ID" \
        --service-name "com.amazonaws.${SBX_REGION}.s3" \
        --vpc-endpoint-type Gateway \
        --route-table-ids "$PUBLIC_RT_ID" "$PRIVATE_RT_ID" \
        --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=${S3_ENDPOINT_NAME}},{Key=sbx:seed-name-prefix,Value=${SBX_SEED_NAME_PREFIX}}]" \
        --query 'VpcEndpoint.VpcEndpointId' --output text 2>/dev/null || echo "")"
fi
sbx_log "S3 endpoint ${S3_ENDPOINT_ID}"

# Step 9. Persist resource IDs to seed.state.json ----------------------------
_payload="$(jq -n \
    --arg vpc "$VPC_ID" \
    --arg cidr "$VPC_CIDR" \
    --arg igw "$IGW_ID" \
    --arg pub_rt "$PUBLIC_RT_ID" \
    --arg priv_rt "$PRIVATE_RT_ID" \
    --arg nat "$NAT_GW_ID" \
    --arg eip "$NAT_EIP_ALLOC_ID" \
    --arg pub1 "$PUB_SUBNET_1_ID" \
    --arg pub2 "$PUB_SUBNET_2_ID" \
    --arg priv1 "$PRIV_SUBNET_1_ID" \
    --arg priv2 "$PRIV_SUBNET_2_ID" \
    --arg sg "$SG_ID" \
    --arg s3vpce "$S3_ENDPOINT_ID" \
    --arg az1 "$AZ1" \
    --arg az2 "$AZ2" \
    '{
        status: "provisioned",
        resources: {
            vpc_id: $vpc,
            vpc_cidr: $cidr,
            igw_id: $igw,
            public_route_table_id: $pub_rt,
            private_route_table_id: $priv_rt,
            nat_gateway_id: $nat,
            nat_eip_allocation_id: $eip,
            public_subnet_ids: [$pub1, $pub2],
            private_subnet_ids: [$priv1, $priv2],
            availability_zones: [$az1, $az2],
            security_group_id: $sg,
            s3_vpc_endpoint_id: $s3vpce
        }
    }')"
sbx_state_set_service network "$_payload"

# Step 10. Patch seed.config.json with the new network IDs -------------------
# Downstream modules read VPC/subnet/SG values from this file. After the
# network module owns the VPC, we rewrite the file in-place so msk, rds,
# glue, mwaa pick up the new IDs on their next invocation.
sbx_log "patching seed.config.json with network IDs"
_cfg_tmp="$(mktemp -t "sbx-seed-cfg-XXXXXX.json")"
jq \
    --arg vpc "$VPC_ID" \
    --arg sg "$SG_ID" \
    --arg priv1 "$PRIV_SUBNET_1_ID" \
    --arg priv2 "$PRIV_SUBNET_2_ID" \
    --arg az1 "$AZ1" \
    '
        .msk.vpc_subnet_ids       = [$priv1, $priv2] |
        .msk.security_group_ids   = [$sg] |
        .rds.vpc_id               = $vpc |
        .rds.subnet_ids           = [$priv1, $priv2] |
        .glue.network_subnet_id   = $priv1 |
        .glue.network_security_group_id = $sg |
        .glue.network_availability_zone = $az1 |
        .mwaa.subnet_ids          = [$priv1, $priv2] |
        .mwaa.security_group_ids  = [$sg]
    ' "$__SEED_CFG" > "$_cfg_tmp"
if [ -s "$_cfg_tmp" ]; then
    mv -f "$_cfg_tmp" "$__SEED_CFG"
    sbx_log "seed.config.json updated"
else
    rm -f "$_cfg_tmp"
    sbx_status error "failed to rewrite seed.config.json"
    exit 1
fi

sbx_status ok "network_provisioned vpc=${VPC_ID} sg=${SG_ID} private=[${PRIV_SUBNET_1_ID},${PRIV_SUBNET_2_ID}] public=[${PUB_SUBNET_1_ID},${PUB_SUBNET_2_ID}] nat=${NAT_GW_ID}"
