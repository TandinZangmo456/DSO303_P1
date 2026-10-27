#!/usr/bin/env bash
# Export the USMS enrolment service's complete scaling configuration and history
# as ONE JSON document (default: outputs/lab-06-scaling-history.json).
#
# Covers: the scalable target (bounds + suspended state), every scaling policy,
# every scheduled action, every alarm involved (with its state), and every
# scaling activity including not-scaled ones.
#
# Works from any directory. Every identifier is discovered: the cluster and
# service from configs/ (or the first usms- cluster), the resource ID from the
# service ARN, policies/actions/alarms from the API. Nothing else is hard-coded.
#
# set -e is deliberately NOT used: on a build without Application Auto Scaling
# (Lab 06 support path C) the describe calls fail, and the export must still be
# written, with those sections marked "supported": false and the error recorded.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
for f in course lab-04 lab-06; do
  # shellcheck disable=SC1090
  source "configs/$f.env" 2>/dev/null || true
done

OUT="${1:-outputs/lab-06-scaling-history.json}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---- discover the cluster and service --------------------------------------
CLUSTER="${USMS_ECS_CLUSTER:-}"
if [ -z "$CLUSTER" ]; then
  CLUSTER=$(aws ecs list-clusters --output text --query 'clusterArns[]' \
    | tr '\t' '\n' | awk -F/ '$NF ~ /^usms-/ {print $NF; exit}')
fi
SERVICE="${USMS_ENROLMENT_SERVICE:-}"
if [ -z "$SERVICE" ]; then
  SERVICE=$(aws ecs list-services --cluster "$CLUSTER" --output text --query 'serviceArns[0]' \
    | awk -F/ '{print $NF}')
fi

SVC_ARN=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].serviceArn' --output text)
RID="${SVC_ARN##*:}"     # service/<cluster>/<service>

# ---- collect each section; a failed call is recorded, not fatal -------------
grab() {
  local name="$1"; shift
  if ! "$@" --output json > "$TMP/$name.json" 2> "$TMP/$name.err"; then
    echo null > "$TMP/$name.json"
  fi
}

grab service    aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE"
grab targets    aws application-autoscaling describe-scalable-targets  --service-namespace ecs --resource-ids "$RID"
grab policies   aws application-autoscaling describe-scaling-policies  --service-namespace ecs --resource-id "$RID"
grab scheduled  aws application-autoscaling describe-scheduled-actions --service-namespace ecs --resource-id "$RID"
grab activities aws application-autoscaling describe-scaling-activities --service-namespace ecs --resource-id "$RID" --include-not-scaled-activities
grab alarms     aws cloudwatch describe-alarms

# ---- assemble in python3 (also produces the UTC timestamp) ------------------
python3 - "$TMP" "$RID" "$SVC_ARN" "${USMS_METRIC_NAMESPACE:-USMS/}" "$OUT" << 'PY'
import json, sys, datetime, os
tmp, rid, svc_arn, metric_ns, out = sys.argv[1:6]

def load(name):
    with open(os.path.join(tmp, name + ".json")) as f:
        data = json.load(f)
    err = ""
    p = os.path.join(tmp, name + ".err")
    if os.path.exists(p):
        err = open(p).read().strip().splitlines()
        err = err[-1] if err else ""
    return data, err

def section(name, key):
    data, err = load(name)
    if data is None:
        return {"supported": False, "error": err, "items": []}
    return {"supported": True, "items": data.get(key) or []}

svc_data, _ = load("service")
svc = (svc_data or {}).get("services", [{}])
svc = svc[0] if svc else {}

targets    = section("targets", "ScalableTargets")
policies   = section("policies", "ScalingPolicies")
scheduled  = section("scheduled", "ScheduledActions")
activities = section("activities", "ScalingActivities")

# Alarms "involved": named by a policy, invoking a policy, managed for this
# resource (TargetTracking-<rid>...), or watching this course's custom namespace.
policy_arns  = {p.get("PolicyARN") for p in policies["items"]}
policy_alarm = {a.get("AlarmName") for p in policies["items"] for a in (p.get("Alarms") or [])}
alarms_raw, alarms_err = load("alarms")
alarms = []
for a in (alarms_raw or {}).get("MetricAlarms", []):
    name = a.get("AlarmName", "")
    if (name in policy_alarm
            or policy_arns & set(a.get("AlarmActions") or [])
            or name.startswith("TargetTracking-" + rid)
            or (a.get("Namespace") or "").startswith(metric_ns.rstrip("/").split("/")[0] + "/")):
        alarms.append({k: a.get(k) for k in (
            "AlarmName", "Namespace", "MetricName", "Dimensions", "Statistic", "Period",
            "EvaluationPeriods", "Threshold", "ComparisonOperator", "TreatMissingData",
            "AlarmActions", "StateValue", "StateReason", "StateUpdatedTimestamp")})

doc = {
    "generated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "resourceId": rid,
    "serviceArn": svc_arn,
    "service": {
        "desiredCount": svc.get("desiredCount"),
        "runningCount": svc.get("runningCount"),
        "pendingCount": svc.get("pendingCount"),
        "taskDefinition": svc.get("taskDefinition"),
    },
    "scalableTarget": targets,
    "scalingPolicies": policies,
    "scheduledActions": scheduled,
    "alarms": {"supported": alarms_raw is not None, "error": alarms_err if alarms_raw is None else "", "items": alarms},
    "scalingActivities": activities,
}
with open(out, "w") as f:
    json.dump(doc, f, indent=2, default=str)
print(f"wrote {out}")
PY
