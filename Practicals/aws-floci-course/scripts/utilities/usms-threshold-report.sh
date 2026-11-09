#!/usr/bin/env bash
# Lab 13 Exercise 3 - are these thresholds defensible?
# For every alarm whose name begins usms-, print one JSON object with its
# configuration and what its metric actually did over the last 24 hours.
# Valid JSON on stdout only; diagnostics go to stderr. Runs from any directory.
#
# Composite alarms have no metric: they are reported with nulls. On a build
# without PutCompositeAlarm the composite is read from its template instead,
# and marked "source": "template".
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"

python3 - << 'PY'
import datetime, json, os, subprocess, sys

def aws(*args):
    r = subprocess.run(["aws", *args, "--output", "json"], capture_output=True, text=True)
    if r.returncode != 0:
        print("aws %s: %s" % (" ".join(args[:2]), r.stderr.strip().splitlines()[-1] if r.stderr.strip() else "failed"),
              file=sys.stderr)
        return {}
    return json.loads(r.stdout) if r.stdout.strip() else {}

now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
start = (now - datetime.timedelta(hours=24)).strftime("%Y-%m-%dT%H:%M:%SZ")
end = now.strftime("%Y-%m-%dT%H:%M:%SZ")

def breached(op, value, threshold):
    if value is None:
        return False
    return {"GreaterThanThreshold": value > threshold,
            "GreaterThanOrEqualToThreshold": value >= threshold,
            "LessThanThreshold": value < threshold,
            "LessThanOrEqualToThreshold": value <= threshold}.get(op, False)

report = []
for a in aws("cloudwatch", "describe-alarms", "--alarm-name-prefix", "usms-").get("MetricAlarms") or []:
    dims = ["Name=%s,Value=%s" % (d["Name"], d["Value"]) for d in a.get("Dimensions") or []]
    stats = aws("cloudwatch", "get-metric-statistics",
                "--namespace", a["Namespace"], "--metric-name", a["MetricName"],
                "--start-time", start, "--end-time", end, "--period", str(a.get("Period", 60)),
                "--statistics", "Minimum", "Average", "Maximum", "SampleCount", "Sum",
                *(["--dimensions", *dims] if dims else [])).get("Datapoints", [])
    observed = None
    if stats:
        n = sum(p["SampleCount"] for p in stats)
        observed = {"min": min(p["Minimum"] for p in stats),
                    "avg": round(sum(p["Sum"] for p in stats) / n, 3) if n else None,
                    "max": max(p["Maximum"] for p in stats),
                    "samples": int(n)}
    # Compare the alarm's own statistic per period with the threshold.
    stat_key = a.get("Statistic", "Average")
    ever = any(breached(a["ComparisonOperator"], p.get(stat_key), a["Threshold"]) for p in stats)
    report.append({
        "alarm": a["AlarmName"], "namespace": a["Namespace"], "metric": a["MetricName"],
        "statistic": a.get("Statistic"), "period": a.get("Period"),
        "evaluation_periods": a.get("EvaluationPeriods"),
        "datapoints_to_alarm": a.get("DatapointsToAlarm"),
        "threshold": a["Threshold"], "operator": a["ComparisonOperator"],
        "missing_data": a.get("TreatMissingData"), "observed": observed,
        "threshold_ever_breached": ever,
    })

composites = aws("cloudwatch", "describe-alarms", "--alarm-types", "CompositeAlarm",
                 "--alarm-name-prefix", "usms-").get("CompositeAlarms") or []
source = "cloudwatch"
if not composites and os.path.exists("templates/lab-13-composite-alarm.json"):
    composites = [json.load(open("templates/lab-13-composite-alarm.json"))]
    source = "template"
    print("composite alarms not stored on this build - reading templates/lab-13-composite-alarm.json",
          file=sys.stderr)
for c in composites:
    report.append({
        "alarm": c["AlarmName"], "namespace": None, "metric": None, "statistic": None,
        "period": None, "evaluation_periods": None, "datapoints_to_alarm": None,
        "threshold": None, "operator": None, "missing_data": None,
        "rule": c["AlarmRule"], "observed": None, "threshold_ever_breached": None,
        "source": source,
    })

print(json.dumps(report, indent=2))
PY
