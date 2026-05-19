# seed/network — self-contained seed VPC

Provisions the VPC topology MWAA requires and every other seed module benefits from. Other modules read the values out of `seed.config.json` after this module runs and updates the config in place.

## Topology

```
VPC <prefix>-vpc 10.0.0.0/16
  IGW <prefix>-igw
  Public RT <prefix>-rt-public  (0.0.0.0/0 -> IGW)
    public-a 10.0.0.0/24  (AZ-A)
    public-b 10.0.1.0/24  (AZ-B)
      NAT GW <prefix>-natgw  (EIP <prefix>-natgw-eip)
  Private RT <prefix>-rt-private  (0.0.0.0/0 -> NAT GW)
    private-a 10.0.10.0/24 (AZ-A)
    private-b 10.0.11.0/24 (AZ-B)
  S3 Gateway VPC Endpoint  (attached to public + private RTs)
  Default SG <prefix>-default-sg  (intra-VPC ingress; default egress)
```

## Why

- MWAA refuses public subnets — its `CreateEnvironment` validation rejects subnets whose RT has `0.0.0.0/0 -> igw`.
- Glue jobs in private subnets need an S3 gateway endpoint or NAT to reach S3. We provide both.
- RDS, MSK, Lambda, Firehose all benefit from a single coherent VPC owned by the seed.

## Run

```bash
bash seed/network/create.sh --apply
bash seed/network/teardown.sh --apply
```

Or via the orchestrator:

```bash
./seed.sh provision --apply --network --profile <p> --yes
./seed.sh teardown  --apply --network --profile <p> --yes
```

## Config side-effect

On first apply, this module updates `seed/seed.config.json` so subsequent modules read the new private VPC values. The original is backed up to `seed/seed.config.json.bak.<unix-ts>`.

Fields rewritten:

```
msk.vpc_subnet_ids          -> [private-a, private-b]
msk.security_group_ids      -> [default-sg]
rds.vpc_id                  -> <new-vpc>
rds.subnet_ids              -> [private-a, private-b]
glue.network_subnet_id      -> private-a
glue.network_security_group_id -> default-sg
glue.network_availability_zone -> AZ-A
mwaa.subnet_ids             -> [private-a, private-b]
mwaa.security_group_ids     -> [default-sg]
```

## Cost

The single NAT gateway is the only billed resource. Roughly ~$0.045/hour + ~$0.045/GB. For seed-grade traffic, expect under $2/day while running. Tear down between sessions to keep cost negligible.

## Safety

- All resources tagged `seed:owned-by=<prefix>`. Teardown only acts on tagged IDs recorded in `seed.state.json`.
- No SMUS Domain or DataZone API calls (Requirement 20.30).
