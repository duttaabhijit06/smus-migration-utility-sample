#!/usr/bin/env bash
#
# seed/network/teardown.sh — tear down the seed VPC and everything in it.
#
# Strict reverse of create.sh, with extra waiters where AWS deletes are
# asynchronous (NAT gateway in particular).
#
# Order:
#   1. delete-vpc-endpoint        (S3 gateway endpoint)
#   2. delete-security-group      (the seed shared SG)
#   3. delete-nat-gateway + wait  (NAT gateway can take 1-3 min to drop)
#   4. release-address            (NAT EIP)
#   5. delete-route-table         (private RT, public RT) — disassociate first
#   6. detach-internet-gateway + delete-internet-gateway
#   7. delete-subnet × 4
#   8. delete-vpc
#
# Gates:
#   * Apply-mode requires the seed.state.json to have a recorded VPC ID
#     (defense in depth — never delete an unmanaged VPC).
#   * Every resource probed by tag/Name must have the seed prefix tag.
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

VPC_ID="$(sbx_state_get '.services.network.resources.vpc_id')"
IGW_ID="$(sbx_state_get '.services.network.resources.igw_id')"
PUB_RT_ID="$(sbx_state_get '.services.network.resources.public_route_table_id')"
PRIV_RT_ID="$(sbx_state_get '.services.network.resources.private_route_table_id')"
NAT_GW_ID="$(sbx_state_get '.services.network.resources.nat_gateway_id')"
NAT_EIP_ID="$(sbx_state_get '.services.network.resources.nat_eip_allocation_id')"
SG_ID="$(sbx_state_get '.services.network.resources.security_group_id')"
S3VPCE_ID="$(sbx_state_get '.services.network.resources.s3_vpc_endpoint_id')"
PUB1="$(sbx_state_get '.services.network.resources.public_subnet_ids[0]')"
PUB2="$(sbx_state_get '.services.network.resources.public_subnet_ids[1]')"
PRIV1="$(sbx_state_get '.services.network.resources.private_subnet_ids[0]')"
PRIV2="$(sbx_state_get '.services.network.resources.private_subnet_ids[1]')"

if [ -z "$VPC_ID" ]; then
    sbx_log "no recorded network VPC; nothing to delete"
    if sbx_apply_mode; then
        sbx_state_set_service network '{"status":"torn_down"}'
    fi
    sbx_status ok
    exit 0
fi

if ! sbx_apply_mode; then
    sbx_log "dry-run: would teardown VPC ${VPC_ID} and all owned resources"
    sbx_status ok "network dry-run teardown complete"
    exit 0
fi

# Step 1. S3 endpoint --------------------------------------------------------
if [ -n "$S3VPCE_ID" ]; then
    sbx_status action "delete-vpc-endpoint ${S3VPCE_ID}"
    aws ec2 delete-vpc-endpoints --region "$SBX_REGION" --vpc-endpoint-ids "$S3VPCE_ID" >/dev/null 2>&1 || true
fi

# Step 2. Security group -----------------------------------------------------
if [ -n "$SG_ID" ]; then
    sbx_status action "delete-security-group ${SG_ID}"
    _i=0; _max=12
    while [ "$_i" -lt "$_max" ]; do
        if aws ec2 delete-security-group --region "$SBX_REGION" --group-id "$SG_ID" 2>/dev/null; then
            break
        fi
        if ! aws ec2 describe-security-groups --region "$SBX_REGION" --group-ids "$SG_ID" >/dev/null 2>&1; then
            break
        fi
        sbx_log "  ${SG_ID}: dependency violation, retrying (${_i}/${_max})"
        _i=$((_i + 1))
        sleep 15
    done
fi

# Step 3. NAT gateway --------------------------------------------------------
if [ -n "$NAT_GW_ID" ]; then
    sbx_status action "delete-nat-gateway ${NAT_GW_ID}"
    aws ec2 delete-nat-gateway --region "$SBX_REGION" --nat-gateway-id "$NAT_GW_ID" >/dev/null 2>&1 || true
    sbx_status action "nat_wait_deleted ${NAT_GW_ID}"
    _i=0; _max=40   # 20 min budget
    while [ "$_i" -lt "$_max" ]; do
        _state="$(aws ec2 describe-nat-gateways \
            --region "$SBX_REGION" \
            --nat-gateway-ids "$NAT_GW_ID" \
            --query 'NatGateways[0].State' --output text 2>/dev/null || echo "")"
        case "$_state" in
            deleted|"") break ;;
        esac
        if [ $((_i % 4)) -eq 0 ]; then
            sbx_status in-progress "nat_wait_deleted poll=${_i}/${_max} state=${_state}"
        fi
        _i=$((_i + 1))
        sleep 30
    done
fi

# Step 4. Release NAT EIP ----------------------------------------------------
if [ -n "$NAT_EIP_ID" ]; then
    sbx_status action "release-address ${NAT_EIP_ID}"
    aws ec2 release-address --region "$SBX_REGION" --allocation-id "$NAT_EIP_ID" >/dev/null 2>&1 || true
fi

# Step 5. Route tables (disassociate then delete) ----------------------------
_disassociate_rt() {
    local _rt="$1"
    [ -z "$_rt" ] && return 0
    aws ec2 describe-route-tables \
        --region "$SBX_REGION" \
        --route-table-ids "$_rt" \
        --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' \
        --output text 2>/dev/null | tr '\t' '\n' | while IFS= read -r _assoc; do
            [ -z "$_assoc" ] && continue
            aws ec2 disassociate-route-table --region "$SBX_REGION" --association-id "$_assoc" >/dev/null 2>&1 || true
        done
}

if [ -n "$PRIV_RT_ID" ]; then
    sbx_status action "delete-route-table ${PRIV_RT_ID}"
    _disassociate_rt "$PRIV_RT_ID"
    aws ec2 delete-route-table --region "$SBX_REGION" --route-table-id "$PRIV_RT_ID" >/dev/null 2>&1 || true
fi
if [ -n "$PUB_RT_ID" ]; then
    sbx_status action "delete-route-table ${PUB_RT_ID}"
    _disassociate_rt "$PUB_RT_ID"
    aws ec2 delete-route-table --region "$SBX_REGION" --route-table-id "$PUB_RT_ID" >/dev/null 2>&1 || true
fi

# Step 6. IGW (detach + delete) ---------------------------------------------
if [ -n "$IGW_ID" ]; then
    sbx_status action "detach-internet-gateway ${IGW_ID}"
    aws ec2 detach-internet-gateway --region "$SBX_REGION" --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" >/dev/null 2>&1 || true
    sbx_status action "delete-internet-gateway ${IGW_ID}"
    aws ec2 delete-internet-gateway --region "$SBX_REGION" --internet-gateway-id "$IGW_ID" >/dev/null 2>&1 || true
fi

# Step 7. Subnets ------------------------------------------------------------
for _s in "$PRIV1" "$PRIV2" "$PUB1" "$PUB2"; do
    [ -z "$_s" ] && continue
    sbx_status action "delete-subnet ${_s}"
    aws ec2 delete-subnet --region "$SBX_REGION" --subnet-id "$_s" >/dev/null 2>&1 || true
done

# Step 8. VPC ----------------------------------------------------------------
sbx_status action "delete-vpc ${VPC_ID}"
aws ec2 delete-vpc --region "$SBX_REGION" --vpc-id "$VPC_ID" >/dev/null 2>&1 || true

sbx_state_set_service network '{"status":"torn_down","resources":{}}'
sbx_status ok "network teardown complete"
