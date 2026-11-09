#!/usr/bin/env bash
# Edge-readiness report: one JSON document describing every usms- Lambda
# function and whether it could be associated with CloudFront as Lambda@Edge.
#
# Usage:  usms-edge-report.sh            (runs from any directory)
# Output: JSON on stdout only; diagnostics go to stderr.
#
# edge_eligible is true only when ALL of these hold:
#   - runtime is Node.js or Python
#   - no environment variables
#   - no VPC configuration
#   - at least one published version
#   - memory <= 128 MB and timeout <= 5 s   if the name contains "viewer"
#     memory <= 10240 MB and timeout <= 30 s otherwise (origin triggers)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"

FUNCTIONS=$(aws lambda list-functions \
  --query 'Functions[?starts_with(FunctionName, `usms-`)].FunctionName' --output text) \
  || { echo "list-functions failed" >&2; exit 1; }

[ -n "$FUNCTIONS" ] || echo "no usms- functions found" >&2

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for fn in $FUNCTIONS; do
  echo "reading $fn" >&2
  aws lambda get-function-configuration --function-name "$fn" --output json > "$TMP/$fn.cfg"
  aws lambda list-versions-by-function --function-name "$fn" --output json > "$TMP/$fn.versions"
  aws lambda list-aliases --function-name "$fn" --output json > "$TMP/$fn.aliases"
done

python3 - "$TMP" $FUNCTIONS << 'PY'
import json, sys, os

tmp, names = sys.argv[1], sorted(sys.argv[2:])
report = []
for fn in names:
    cfg = json.load(open(os.path.join(tmp, fn + '.cfg')))
    versions = json.load(open(os.path.join(tmp, fn + '.versions'))).get('Versions', [])
    aliases = json.load(open(os.path.join(tmp, fn + '.aliases'))).get('Aliases', [])

    runtime = cfg.get('Runtime', '')
    memory = cfg.get('MemorySize', 0)
    timeout = cfg.get('Timeout', 0)
    env = (cfg.get('Environment') or {}).get('Variables') or {}
    subnets = (cfg.get('VpcConfig') or {}).get('SubnetIds') or []
    published = len([v for v in versions if v.get('Version') != '$LATEST'])

    mem_cap, timeout_cap = (128, 5) if 'viewer' in fn else (10240, 30)
    reasons = []
    if not runtime.startswith(('nodejs', 'python')):
        reasons.append('runtime %s not supported at the edge' % runtime)
    if env:
        reasons.append('%d environment variables set' % len(env))
    if subnets:
        reasons.append('attached to %d VPC subnets' % len(subnets))
    if published < 1:
        reasons.append('no published version')
    if memory > mem_cap:
        reasons.append('memory %d MB exceeds cap %d' % (memory, mem_cap))
    if timeout > timeout_cap:
        reasons.append('timeout %d s exceeds cap %d' % (timeout, timeout_cap))

    report.append({
        'name': fn,
        'runtime': runtime,
        'memory': memory,
        'timeout': timeout,
        'versions': published,
        'aliases': len(aliases),
        'env_vars': bool(env),
        'edge_eligible': not reasons,
        'not_eligible_because': reasons,
    })

print(json.dumps(report, indent=2))
PY
