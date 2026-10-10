#!/usr/bin/env bash
# Exercise 3: verdict computed from the route table and security group, never from names or tags.
# -e is deliberately NOT set: a missing field (None) is a normal state to classify, so one
# failing describe call must not abort the report. -u and pipefail still catch typos.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env" 2>/dev/null || true

none() { [ -z "$1" ] || [ "$1" = "None" ]; }

aws ec2 describe-instances --filters Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`]|[0].Value,SubnetId,VpcId,PrivateIpAddress,PublicIpAddress,SecurityGroups[0].GroupId]' \
  --output text | while read -r id name subnet vpc priv pub sg; do

  rt=$(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$subnet" \
        --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null)
  if none "$rt"; then   # no explicit association: the VPC's main route table applies
    rt=$(aws ec2 describe-route-tables \
          --filters "Name=vpc-id,Values=$vpc" "Name=association.main,Values=true" \
          --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null)
  fi
  igw=$(aws ec2 describe-route-tables --route-table-ids "$rt" \
        --query 'RouteTables[0].Routes[?starts_with(GatewayId, `igw-`)].GatewayId | [0]' \
        --output text 2>/dev/null)
  sg80=$(aws ec2 describe-security-groups --group-ids "$sg" \
        --query 'SecurityGroups[0].IpPermissions[?(FromPort==`80` || IpProtocol==`-1`) && IpRanges[?CidrIp==`0.0.0.0/0`]] | [0].IpProtocol' \
        --output text 2>/dev/null)

  if none "$igw"; then verdict=UNREACHABLE;  why="no igw route on subnet"
  elif none "$pub"; then verdict=NO-ADDRESS; why="igw route present but no public address"
  elif none "$sg80"; then verdict=BLOCKED;   why="igw route + address, but sg does not allow 80/tcp from 0.0.0.0/0"
  else verdict=REACHABLE; why="igw route + sg allows 80/tcp from 0.0.0.0/0"; fi

  printf '%-18s %-12s %-14s %-12s %s\n' "${name:-?}" "${priv:--}" "$(none "$pub" && echo - || echo "$pub")" "$verdict" "$why"
done
