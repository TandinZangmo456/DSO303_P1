# Lab 01 — Review Questions & Notes

## 1. Trust vs permissions
If a role has a perfect permissions policy but nobody can use it, the missing piece
is almost certainly the trust policy (AssumeRolePolicyDocument). A permissions
policy answers "what may this identity do?" while a trust policy answers "who may
become this identity?" IAM separates these because they protect against two
different risks: the permissions policy limits blast radius once someone is the
role, while the trust policy limits who can even get in. If they were combined,
you couldn't reuse the same permission set across different trusted principals
(e.g. usms-developer-role trusts a specific user, while usms-ec2-app-role trusts
the EC2 service) without duplicating the
whole document. Both halves are required — I saw this directly in Step 30, where
the role needed both a trust statement AND a group-attached sts:AssumeRole
permission before the handshake worked.

## 2. Explicit vs implicit deny
Both failures return AccessDenied to the user, but internally they come from
different places. An explicit deny means a policy statement with "Effect": "Deny"
specifically matches the action — like our DenyDangerousIdentityChanges statement
blocking iam:CreateUser. An implicit deny means no statement anywhere grants the
action at all — the default-deny behavior of IAM when nothing says Allow (this is
what happened with s3:GetObject in my simulate-principal-policy test in Step 32).
I'd tell them apart using simulate-principal-policy, which reports explicitDeny
vs implicitDeny separately. The fix differs: for implicit deny, ADD a permission
somewhere (attach a broader policy, add an Allow statement). For explicit deny,
adding more Allow statements will NEVER fix it — you have to find and remove or
narrow the specific Deny statement, since explicit deny always overrides any
number of Allows.

## 3. Roles over keys
Attaching usms-ec2-app-role to the server (via the instance profile) is more
secure than embedding usms-dev-01's access key in the app's config for two
reasons: (1) No permanent secret sits on disk. A role provides temporary
credentials via the instance metadata service that automatically rotate — if the
server is compromised, imaged, or backed up, there's no long-lived key to steal.
An access key baked into a config file, by contrast, could leak through a backup,
a misconfigured repo, or a compromised machine and remain valid indefinitely.
(2) Scoped, single-purpose permissions. The EC2 role only has
USMSStudentDataReadWrite — exactly what the app needs. A developer's personal
access key (usms-dev-01) usually carries broader permissions meant for a human
doing infrastructure work, so using it for an application would massively
over-grant the app's blast radius if compromised.

## 4. The S3 ARN trap
Downloads fail because s3:GetObject and s3:ListBucket act on two different kinds
of ARN. arn:aws:s3:::usms-student-data refers to the BUCKET itself — that's the
correct resource for s3:ListBucket (you list the contents of a bucket). But
s3:GetObject acts on OBJECTS inside the bucket, which need the ARN
arn:aws:s3:::usms-student-data/* (note the trailing /*). A policy that only lists
the bucket ARN for both actions means s3:GetObject has no matching Resource, so
IAM implicitly denies every GetObject call even though ListBucket succeeds. The
corrected policy needs two Resource entries (or two statements): the bare bucket
ARN for ListBucket/GetBucketLocation, and the bucket ARN + /* for
GetObject/PutObject/DeleteObject. I applied exactly this distinction when writing
USMSStudentDataReadWrite in Step 23 and USMSReportingReadOnly in Exercise 2.

## 5. The Floci illusion
Every command in this lab succeeded, but that's not evidence my policies are
correct because Floci does not enforce IAM authorization against the policies I
wrote by default — it accepts any non-empty credentials and doesn't actually
check whether the caller's policy permits the request. I saw this directly: my
simulate-principal-policy test in Step 32 returned implicitDeny for
ec2:CreateVpc even though usms-dev-01 should have that permission through the
usms-developers group and USMSDeveloperBase — Floci's simplified simulator
doesn't seem to evaluate group-inherited policies correctly. Two techniques to
gain real confidence before deploying to real AWS: (1) Read the policy JSON
carefully and reason through Resource/Action/Condition matches by hand rather
than trusting that "it ran without an error" means it's scoped correctly. (2) Use
IAM Access Analyzer or the policy simulator against real AWS (not Floci), and
actually test with a real, restricted IAM user attempting the exact operations
the policy should and shouldn't allow.

## 6. The persistence trap
Three independent reasons floci start --persist ~/floci-data --detach could still
lose data: (1) --persist only supplies a host directory; it does NOT set
FLOCI_STORAGE_MODE to anything other than the default "memory" mode, so Floci
still treats its own state as disposable and writes almost nothing durable into
that directory. (2) Sidecar services (RDS, Lambda, ECR, etc.) use a completely
different variable, FLOCI_STORAGE_HOST_PERSISTENT_PATH, which --persist doesn't
set at all — so even if IAM data persisted, sidecar data wouldn't. (3) CLI flags
like --persist are not remembered between runs — any later floci restart, floci
stop --remove, or plain floci start recreates the container on defaults, silently
wiping everything with no warning. The single test that would catch this in under
a minute is exactly what I did in Step 14.4: create a real resource (an IAM user),
force a full container restart, and check if the resource is still there — not
just checking that the root account ARN looks the same, since that's a constant
that "survives" even in pure memory mode with zero real persistence.

## 7. Configuration as evidence
docker-compose.yml being a committed file is a security and reproducibility
property, not just a convenience, because it makes the environment's behavior an
auditable, versioned artifact rather than a fact that only lives in one person's
head or terminal history. An instructor or colleague can open the file and verify,
without running anything, that FLOCI_STORAGE_MODE is set to hybrid (not the
insecure/lossy default), that the host bind mount path is correct, that no
secrets are hardcoded into the file, and that the exact same container
configuration will be recreated identically on any machine. A typed command, by
contrast, leaves no permanent record — if I had just run `docker run -e
FLOCI_STORAGE_MODE=hybrid ...` by hand, nobody (including future-me) could verify
weeks later what flags were actually used, whether they matched what was intended,
or whether the setup is reproducible at all. Committing the compose file turns
"trust me, I configured it right" into "here, read exactly what was configured."

## Floci limitations observed (for the report's "Floci vs Real AWS" section)
- MaxSessionDuration has a hard floor of 3600 seconds even in Floci — matching
  real AWS behavior, not a Floci-specific bug (learned this in Exercise 3 while
  trying to set 1800 for the analytics partner role).
- simulate-principal-policy appears to only evaluate policies attached directly
  to the specified principal, not policies inherited through group membership
  (observed in Step 32 and reproduced with usms-dev-01 / USMSDeveloperBase).
