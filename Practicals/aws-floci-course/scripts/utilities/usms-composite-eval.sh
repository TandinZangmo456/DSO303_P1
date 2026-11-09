#!/usr/bin/env bash
# Local stand-in for a CloudWatch composite alarm (PutCompositeAlarm is
# unsupported on Floci 1.5.34). Reads the rule from
# templates/lab-13-composite-alarm.json, fetches the REAL state of every child
# alarm it names, and evaluates the ALARM(...) / OR / AND / NOT expression.
#
# Proves: the rule is well formed, names existing alarms, and gives the right
# answer for the children's current states.
# Does NOT prove: CloudWatch evaluating it every period or invoking an action.
#
# Usage: usms-composite-eval.sh [template]
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"

TEMPLATE="${1:-templates/lab-13-composite-alarm.json}"

python3 - "$TEMPLATE" << 'PY'
import json, re, subprocess, sys

doc = json.load(open(sys.argv[1]))
rule = doc["AlarmRule"]
children = re.findall(r'(ALARM|OK|INSUFFICIENT_DATA)\("([^"]+)"\)', rule)
names = sorted({n for _, n in children})

out = subprocess.run(
    ["aws", "cloudwatch", "describe-alarms", "--alarm-names", *names,
     "--query", "MetricAlarms[].[AlarmName,StateValue]", "--output", "json"],
    capture_output=True, text=True, check=True)
states = dict(json.loads(out.stdout))

missing = [n for n in names if n not in states]
if missing:
    print(json.dumps({"composite": doc["AlarmName"], "error": "child alarm(s) do not exist",
                      "missing": missing}, indent=2))
    sys.exit(2)

expr = re.sub(r'(ALARM|OK|INSUFFICIENT_DATA)\("([^"]+)"\)',
              lambda m: str(states[m.group(2)] == m.group(1)), rule)
expr = expr.replace(" AND ", " and ").replace(" OR ", " or ").replace("NOT ", "not ")
fired = eval(expr, {"__builtins__": {}})

print(json.dumps({"composite": doc["AlarmName"], "rule": rule, "children": states,
                  "state": "ALARM" if fired else "OK",
                  "mode": "local evaluation - PutCompositeAlarm unsupported on this build"},
                 indent=2))
PY
