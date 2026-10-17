#!/usr/bin/env bash
# ECS configuration drift report for every service in the Lab 04 cluster.
#
# set -e is deliberately NOT used. An inventory must keep going when one
# service cannot be described; stopping at the first error would silently
# omit exactly the services we most want to see. -u and pipefail stay on so
# typos and broken pipes are still caught.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-04.env"

CLUSTER="$USMS_ECS_CLUSTER"
mkdir -p "$REPO_ROOT/outputs"
OUT_JSON="$REPO_ROOT/outputs/lab-04-ecs-inventory.json"
ROWS="$(mktemp)"
trap 'rm -f "$ROWS"' EXIT

for arn in $(aws ecs list-services --cluster "$CLUSTER" --query 'serviceArns[]' --output text); do
  [ "$arn" = "None" ] && continue
  name="${arn##*/}"

  svc="$(aws ecs describe-services --cluster "$CLUSTER" --services "$name" --output json 2>/dev/null)"
  if [ -z "$svc" ]; then
    printf '%-20s %s\n' "$name" "could not be described"
    jq -n --arg n "$name" '{service:$n,error:"could not be described"}' >> "$ROWS"
    continue
  fi

  desired="$(jq -r '.services[0].desiredCount // "N/A"' <<<"$svc")"
  running="$(jq -r '.services[0].runningCount // "N/A"' <<<"$svc")"
  td="$(jq -r '.services[0].taskDefinition // "N/A"' <<<"$svc")"
  tdname="${td##*/}"
  pubip_raw="$(jq -r '.services[0].networkConfiguration.awsvpcConfiguration.assignPublicIp // "N/A"' <<<"$svc")"

  case "$pubip_raw" in
    ENABLED)  publicip="RISK" ;;
    DISABLED) publicip="OK" ;;
    *)        publicip="N/A" ;;
  esac

  roles="N/A"
  if [ "$tdname" != "N/A" ]; then
    tdjson="$(aws ecs describe-task-definition --task-definition "$tdname" --output json 2>/dev/null)"
    exec_arn="$(jq -r '.taskDefinition.executionRoleArn // ""' <<<"$tdjson")"
    task_arn="$(jq -r '.taskDefinition.taskRoleArn // ""' <<<"$tdjson")"
    if [ -z "$exec_arn" ] || [ -z "$task_arn" ]; then
      roles="N/A"
    elif [ "$exec_arn" = "$task_arn" ]; then
      roles="SAME"
    else
      roles="SEPARATE"
    fi
  fi

  printf '%-20s desired=%-2s running=%-2s taskdef=%-20s roles=%-8s publicip=%s\n' \
    "$name" "$desired" "$running" "$tdname" "$roles" "$publicip"

  jq -n --arg n "$name" --arg d "$desired" --arg r "$running" --arg t "$tdname" \
        --arg ro "$roles" --arg p "$publicip" \
        '{service:$n,desired:$d,running:$r,taskdef:$t,roles:$ro,publicip:$p}' >> "$ROWS"
done

jq -s '.' "$ROWS" > "$OUT_JSON"
echo
echo "JSON written to $OUT_JSON"
