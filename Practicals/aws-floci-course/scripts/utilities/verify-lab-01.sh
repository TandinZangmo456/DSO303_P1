#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"

PASS=0; FAIL=0
check() {
  if eval "$2" >/dev/null 2>&1; then
    printf "  ✔ %s\n" "$1"; PASS=$((PASS+1))
  else
    printf "  ✗ %s\n" "$1"; FAIL=$((FAIL+1))
  fi
}

echo "== Environment =="
check "Docker daemon reachable"   "docker info"
check "Compose v2 present"        "docker compose version"
check "Floci container running"   "test \"\$(docker container inspect $FLOCI_CONTAINER_NAME --format '{{.State.Running}}')\" = true"
check "Health endpoint responds"  "curl -sf http://localhost:4566/_floci/health"
check "AWS CLI reaches Floci"     "aws sts get-caller-identity"
check "Account is 000000000000"   "test \"\$(aws sts get-caller-identity --query Account --output text)\" = $ACCOUNT_ID"

echo "== Groups =="
for g in usms-admins usms-developers usms-auditors; do
  check "group $g" "aws iam get-group --group-name $g"
done

echo "== Users =="
for u in usms-admin-01 usms-dev-01 usms-audit-01; do
  check "user $u" "aws iam get-user --user-name $u"
done

echo "== Policies =="
for p in USMSDeveloperBase USMSStudentDataReadWrite USMSAssumeAppRoles USMSLambdaBasic; do
  check "policy $p" \
    "aws iam list-policies --scope Local --query \"Policies[?PolicyName=='$p'].Arn|[0]\" --output text | grep -q arn:"
done
check "inline policy on usms-dev-01" \
  "aws iam get-user-policy --user-name usms-dev-01 --policy-name USMSSelfManageCredentials"

echo "== Roles =="
for r in usms-ec2-app-role usms-lambda-exec-role usms-developer-role; do
  check "role $r" "aws iam get-role --role-name $r"
done
check "instance profile has the role" \
  "aws iam get-instance-profile --instance-profile-name usms-ec2-app-profile --query 'InstanceProfile.Roles[0].RoleName' --output text | grep -q usms-ec2-app-role"

echo "== Files and Git hygiene =="
check "configs/course.env"    "test -f configs/course.env"
check "configs/lab-01.env"    "test -f configs/lab-01.env"
check "docker-compose.yml"    "test -f docker-compose.yml"
check "outputs/.gitkeep IS tracked" "git ls-files --error-unmatch outputs/.gitkeep"
check "access key file is IGNORED"  "git check-ignore -q outputs/usms-dev-01-access-key.json"
check "no secret is staged or tracked" \
  "! git ls-files | grep -q '^outputs/usms-dev-01-access-key.json$'"

echo
echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
