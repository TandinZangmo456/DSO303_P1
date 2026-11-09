#!/usr/bin/env bash
# Terminal stand-in for the usms-overview CloudWatch dashboard (PutDashboard is
# unsupported on Floci 1.5.34). Reads templates/lab-13-dashboard.json - the same
# document real AWS would take - and draws each widget as text from live data:
#   text   -> the first markdown line
#   metric -> get-metric-statistics per series over the last N hours
#   alarm  -> describe-alarms, and the composite via usms-composite-eval.sh
#
# Usage: usms-dashboard-summary.sh [hours]   (default 3)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"

HOURS="${1:-3}"

python3 - "$HOURS" << 'PY'
import datetime, json, subprocess, sys

hours = int(sys.argv[1])
body = json.load(open("templates/lab-13-dashboard.json"))
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
start = (now - datetime.timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%SZ")
end = (now + datetime.timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ")

def aws(*args):
    r = subprocess.run(["aws", *args, "--output", "json"], capture_output=True, text=True)
    return json.loads(r.stdout) if r.returncode == 0 and r.stdout.strip() else None

print("usms-overview (terminal summary, last %dh, %s)" % (hours, now.isoformat()))
for w in sorted(body["widgets"], key=lambda w: (w["y"], w["x"])):
    p = w["properties"]
    print("\n[%s] %s  (x=%d y=%d %dx%d)" % (w["type"], p.get("title", ""), w["x"], w["y"], w["width"], w["height"]))
    if w["type"] == "text":
        print("   " + p["markdown"].splitlines()[0])
    elif w["type"] == "metric":
        for m in p["metrics"]:
            opts = m[-1] if isinstance(m[-1], dict) else {}
            ns, name, dims = m[0], m[1], [x for x in m[2:] if not isinstance(x, dict)]
            stat = opts.get("stat", p.get("stat", "Average"))
            dargs = ["Name=%s,Value=%s" % (dims[i], dims[i + 1]) for i in range(0, len(dims), 2)]
            res = aws("cloudwatch", "get-metric-statistics", "--namespace", ns, "--metric-name", name,
                      "--start-time", start, "--end-time", end, "--period", str(hours * 3600),
                      "--statistics", stat, *(["--dimensions", *dargs] if dargs else []))
            pts = (res or {}).get("Datapoints", [])
            val = pts[0][stat] if pts else None
            label = opts.get("label", stat)
            series = name + ("{" + ",".join(dims[1::2]) + "}" if dims else "")
            print("   %-44s %-4s %s" % (series, label, "no data" if val is None else round(val, 3)))
        for a in p.get("annotations", {}).get("horizontal", []):
            print("   ---- %s at %s" % (a["label"], a["value"]))
    elif w["type"] == "alarm":
        names = [arn.split(":alarm:")[1] for arn in p["alarms"]]
        res = aws("cloudwatch", "describe-alarms", "--alarm-names", *names) or {}
        states = {a["AlarmName"]: a["StateValue"] for a in res.get("MetricAlarms", [])}
        comp = subprocess.run(["./scripts/utilities/usms-composite-eval.sh"], capture_output=True, text=True)
        try:
            c = json.loads(comp.stdout)
            states[c["composite"]] = c["state"] + " (local eval)"
        except ValueError:
            pass
        for n in names:
            print("   %-34s %s" % (n, states.get(n, "MISSING")))
PY
