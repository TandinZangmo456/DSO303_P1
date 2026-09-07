#!/usr/bin/env bash
# Classify every subnet in usms-vpc as PUBLIC, PRIVATE, or ISOLATED,
# based purely on its effective route table's default route target.
# Never hardcodes an ID; safe to run from any directory.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-02.env"

VPC_ID="$USMS_VPC_ID"

aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'sort_by(Subnets, &CidrBlock)[].SubnetId' \
  --output text | tr '\t' '\n' | while read -r subnet_id; do

  [ -z "$subnet_id" ] && continue

  name=$(aws ec2 describe-subnets --subnet-ids "$subnet_id" \
          --query 'Subnets[0].Tags[?Key==`Name`]|[0].Value' --output text)
  cidr=$(aws ec2 describe-subnets --subnet-ids "$subnet_id" \
          --query 'Subnets[0].CidrBlock' --output text)
  az=$(aws ec2 describe-subnets --subnet-ids "$subnet_id" \
          --query 'Subnets[0].AvailabilityZone' --output text)

  rt=$(aws ec2 describe-route-tables \
        --filters "Name=association.subnet-id,Values=$subnet_id" \
        --query 'RouteTables[0].RouteTableId' --output text)

  igw=$(aws ec2 describe-route-tables --route-table-ids "$rt" \
        --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId | [0]' \
        --output text 2>/dev/null)
  nat=$(aws ec2 describe-route-tables --route-table-ids "$rt" \
        --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].NatGatewayId | [0]' \
        --output text 2>/dev/null)

  if [ -n "$igw" ] && [ "$igw" != "None" ]; then
    printf '%-24s %-14s %-12s PUBLIC   via %s\n' "$name" "$cidr" "$az" "$igw"
  elif [ -n "$nat" ] && [ "$nat" != "None" ]; then
    printf '%-24s %-14s %-12s PRIVATE  via %s\n' "$name" "$cidr" "$az" "$nat"
  else
    printf '%-24s %-14s %-12s ISOLATED no default route\n' "$name" "$cidr" "$az"
  fi
done
