#!/usr/bin/env bash
# Draft the transcripts bucket policy - Lab 09 Exercise 5.
#
# Reads the identity inventory and every customer managed policy that names the
# transcripts bucket, works out which roles hold which s3: actions on it, and writes
#   outputs/lab-09-bucket-policy-draft.json   the resource policy, NOT applied
#   outputs/lab-09-lab10-readiness.txt        what Lab 10 needs to know
# Works whether or not the bucket exists. Applies nothing. Touches no credentials.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1090
source "$REPO_ROOT/configs/course.env" 2>/dev/null || true

INVENTORY="${1:-outputs/lab-09-identity-inventory.json}"
[ -f "$INVENTORY" ] || { echo "no inventory at $INVENTORY - run Lab 09 Step 4 part 2" >&2; exit 2; }

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

# The bucket name comes from Lab 01's policy document, never from typing it.
RW_ARN="arn:aws:iam::${ACCOUNT}:policy/USMSStudentDataReadWrite"
RW_VER=$(aws iam get-policy --policy-arn "$RW_ARN" --query 'Policy.DefaultVersionId' --output text)
BUCKET_ARN=$(aws iam get-policy-version --policy-arn "$RW_ARN" --version-id "$RW_VER" \
  --query "PolicyVersion.Document.Statement[?Effect=='Allow' && !contains(to_string(Resource), '/*')].Resource | [0]" \
  --output text)
# Parameter expansion, not sed: strip the fixed "arn:aws:s3:::" prefix to leave the
# bucket name, and fail loudly below if the ARN had some other shape.
BUCKET="${BUCKET_ARN#arn:aws:s3:::}"
[ "$BUCKET" != "$BUCKET_ARN" ] && [ -n "$BUCKET" ] || { echo "could not read the bucket from $RW_ARN" >&2; exit 2; }

# Every customer managed policy, with its default document, for python to filter.
aws iam list-policies --scope Local --query 'Policies[].[PolicyName,Arn,DefaultVersionId]' --output text \
  | while read -r name arn ver; do
      doc=$(aws iam get-policy-version --policy-arn "$arn" --version-id "$ver" \
              --query 'PolicyVersion.Document' --output json 2>/dev/null || echo null)
      printf '%s\t%s\n' "$name" "$(echo "$doc" | tr -d '\n')"
    done > "outputs/.lab-09-local-policies.tsv"

python3 - "$INVENTORY" "outputs/.lab-09-local-policies.tsv" "$BUCKET" "$ACCOUNT" << 'PY'
import json, sys
inv_path, pol_path, bucket, account = sys.argv[1:5]
b_arn, o_arn = f"arn:aws:s3:::{bucket}", f"arn:aws:s3:::{bucket}/*"

def as_list(x):
    return [] if x is None else (x if isinstance(x, list) else [x])

# the policies that name this bucket - "the transcripts policies"
policies = {}
for line in open(pol_path):
    name, _, doc = line.rstrip("\n").partition("\t")
    try:
        d = json.loads(doc)
    except Exception:
        continue
    if d and b_arn in json.dumps(d):
        policies[name] = d

def allowed_s3(doc):
    acts = set()
    for s in as_list(doc.get("Statement")):
        if s.get("Effect") == "Allow" and any(r.startswith(b_arn) for r in as_list(s.get("Resource"))):
            acts |= {a for a in as_list(s.get("Action")) if a.startswith("s3:")}
    return acts

def denied_s3(doc):
    acts = set()
    for s in as_list(doc.get("Statement")):
        if s.get("Effect") == "Deny":
            acts |= {a for a in as_list(s.get("Action")) if a.startswith("s3:")}
    return acts

grants = {}   # role ARN -> actions it already has (allow minus its own explicit denies)
holders = {}  # policy -> roles
for r in json.load(open(inv_path)):
    arn = r.get("arn") or f"arn:aws:iam::{account}:role/{r['role']}"
    for p in r.get("attachedPolicies", []):
        if p["name"] in policies:
            holders.setdefault(p["name"], []).append(arn)
            acts = allowed_s3(policies[p["name"]]) - denied_s3(policies[p["name"]])
            if acts:
                grants.setdefault(arn, set()).update(acts)

root = f"arn:aws:iam::{account}:root"
stmts = []
for i, (arn, acts) in enumerate(sorted(grants.items()), 1):
    stmts.append({"Sid": f"Existing{i}{arn.rsplit('/', 1)[-1].replace('-', '').title()[:40]}",
                  "Effect": "Allow", "Principal": {"AWS": arn},
                  "Action": sorted(acts), "Resource": [b_arn, o_arn]})
stmts.append({"Sid": "DenyInsecureTransport", "Effect": "Deny", "Principal": "*",
              "Action": "s3:*", "Resource": [b_arn, o_arn],
              "Condition": {"Bool": {"aws:SecureTransport": "false"}}})
stmts.append({"Sid": "DenyEveryoneElse", "Effect": "Deny",
              "NotPrincipal": {"AWS": sorted(grants) + [root]},
              "Action": "s3:*", "Resource": [b_arn, o_arn]})
policy = {"Version": "2012-10-17", "Id": f"{bucket}-draft", "Statement": stmts}
json.dump(policy, open("outputs/lab-09-bucket-policy-draft.json", "w"), indent=2)

# mechanical checks the exercise asks for
for s in stmts:
    p = s.get("Principal", s.get("NotPrincipal"))
    if s["Sid"] == "DenyInsecureTransport":
        assert p == "*", s["Sid"]
    else:
        assert all(a.startswith("arn:aws:iam::") for a in as_list(p["AWS"])), s["Sid"]
    assert b_arn in s["Resource"] and o_arn in s["Resource"], s["Sid"]

with open("outputs/lab-09-lab10-readiness.txt", "w") as f:
    f.write(f"bucket (from USMSStudentDataReadWrite) : {bucket}\n")
    f.write(f"policies naming it                     : {', '.join(sorted(policies))}\n")
    for name in sorted(policies):
        f.write(f"  {name:<36} : {', '.join(holders.get(name, [])) or '(attached to no role)'}\n")
    f.write(f"principals in the draft                : {len(grants)} roles + account root\n")
    f.write("when Lab 10 runs create-bucket         : every policy above stops naming a bucket that does "
            "not exist, so each listed role gains real access at that moment - and nobody else does "
            "once this draft is applied\n")
print(open("outputs/lab-09-lab10-readiness.txt").read(), end="")
PY
rc=$?
rm -f outputs/.lab-09-local-policies.tsv
exit $rc
