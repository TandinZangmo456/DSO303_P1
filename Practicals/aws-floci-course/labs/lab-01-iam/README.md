# Lab 01 — IAM — completed

## What exists after this lab
- Environment: Floci via docker-compose.yml, FLOCI_STORAGE_MODE=hybrid,
  bind-mounted to ~/floci-data, persistence proven (created a user, restarted, found it again)
- Groups: usms-admins, usms-developers, usms-auditors
- Users: usms-admin-01, usms-dev-01, usms-audit-01
- Customer managed policies: USMSDeveloperBase (v2), USMSStudentDataReadWrite,
  USMSAssumeAppRoles, USMSLambdaBasic
- Inline policy: USMSSelfManageCredentials on usms-dev-01
- Roles: usms-ec2-app-role, usms-lambda-exec-role, usms-developer-role
- Instance profile: usms-ec2-app-profile

## Reproduce
    source configs/course.env
    ./scripts/setup/floci-up.sh
    source configs/lab-01.env

## Evidence
- [x] whoami.sh output showing account 000000000000
- [x] floci-storage-check.sh output, all [ok]
- [x] Step 14 persistence proof (user survived a restart)
- [x] verify-lab-01.sh with FAIL=0 (pending)

## Problems I hit and how I fixed them
- Project kept under ~/Desktop/SEM7/DSO303/Practicals/aws-floci-course instead of
  ~/aws-floci-course — adjusted COURSE_ROOT and all path references accordingly.
- simulate-principal-policy returned implicitDeny for ec2:CreateVpc on usms-dev-01
  even though USMSDeveloperBase (attached via the usms-developers group) allows it.
  This appears to be a Floci limitation: the simulator does not seem to evaluate
  policies inherited through group membership, only ones attached directly to the
  principal. iam:CreateUser correctly showed explicitDeny and s3:GetObject correctly
  showed implicitDeny.
