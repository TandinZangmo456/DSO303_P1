# Lab 09 notes

**Support path: A.** Every Step 3 probe answered, including `simulate-principal-policy`. `get-account-authorization-details`, `accessanalyzer list-analyzers` and `get-credential-report` are not available.

**usms-student-data at Step 6:** it did not exist (`head-bucket` returned 404, exit 254).

## Environment

- Floci under Compose, `FLOCI_STORAGE_MODE=hybrid`, account 000000000000.
- Baseline before the lab: lab-02 30/0, lab-03 31/5, lab-04 36/2, lab-05 41/8, lab-06 21/21. These failures predate the lab (stopped instances, Floci dropping group-referenced sources, Lab 06 done on Path C, the `.gitkeep` false positive). After the lab the results were identical: NOTHING BROKE.
- The Step 18 restart removed the k3s (EKS) container. The Lab 07/08 cluster needs recreating before any EKS work.

## Step 4 - Two kinds of trust principal

`usms-developer-role` trusts an AWS identity (`user/usms-dev-01`): only whoever holds that user's credentials can become it, by calling `sts:AssumeRole`. `usms-ec2-app-role` trusts a service (`ec2.amazonaws.com`): anyone who can launch an instance and pass the role gets its credentials from that instance's metadata service, so the real gate is `iam:PassRole`, not the trust policy.

## Step 6 - Actions needed

- To *display* a transcript: `s3:GetObject` (and `s3:ListBucket`, so that a missing key returns 404 NoSuchKey instead of 403 AccessDenied).
- To *store* one: the same plus exactly one action, `s3:PutObject`.

The Lab 01 policy also grants `s3:DeleteObject` and `s3:GetBucketLocation`, so it is wider than either list.

## Step 8 - Why the audit does not flag Resource "*" on the boundary

The audit reads the inventory, which holds only *attached* policies, and the boundary is attached to nothing. Even if it were read, a boundary grants nothing, so a wide Resource there is a wide ceiling, not a wide permission.

## Floci limitations hit

The full table is in `labs/lab-09-security/readme.md`. In short: boundaries are not returned on readback; `list-entities-for-policy` and `modify-instance-metadata-options` are unsupported; group-referenced SG rules and prefix-list destinations lose their target on readback; revoke results differ between `describe-security-groups` and `describe-security-group-rules`; instances report public `127.0.0.1`; nothing is enforced.

---

## Review questions

### 1. Why "NOTHING BROKE" is a strong result

The five earlier scripts check the things that make USMS work: the VPC, the routes, the instances, the ECS service and the load balancer. This lab changed trust policies, egress and SSH rules on the very groups and roles those scripts read, so an identical result shows that every change was additive to security without removing anything the system relied on. A plausible break would be revoking usms-alb-sg's default egress *before* authorizing the tcp/80 rule to the enrolment group. On real AWS, the ALB health checks to the tasks would fail, the targets would go unhealthy, and verify-lab-05's target-health checks would fail. That is why every egress change in Steps 13 to 15 authorizes first and revokes second. If it had happened, I would have re-authorized from `policies/usms-egress-allow-all.json` (the undo written before the change), confirmed the targets were healthy again, and then retried in the right order.

### 2. Attaching the boundary as an ordinary policy

Attaching `USMSPermissionsBoundary` with `attach-role-policy` turns a ceiling into a grant. **Upwards**, usms-deploy-role gains everything the boundary allows that USMSDeployBase did not, including `ecs:*`, `elasticloadbalancing:*`, `logs:*`, `cloudwatch:*`, `s3:Get*/List*/PutObject` and `iam:PassRole` on `Resource "*"`. That last one undoes the scoped PassRole, because an Allow on `"*"` now sits beside the scoped one and only the explicit Deny to EC2 still holds. **Downwards**, the boundary's Deny statements still apply as identity denies, so nothing is lost there. And if it was moved from the boundary slot rather than added, the role has no ceiling at all any more. It becomes dangerous the moment the role is assumed by a pipeline that is compromised: the attacker can pass any role to ECS and write to S3. Section 8 catches it with "the boundary is attached to NOTHING as an ordinary policy" (AttachmentCount = 0).

### 3. A breach with every ingress rule correct

An enrolment task has a dependency with a remote-code-execution bug, reachable through the load balancer exactly as designed. The attacker's code runs inside the task with `usms-ecs-task-role`, reads transcripts through the S3 gateway endpoint (allowed), and sends them out over HTTPS to a host they control. Steps 13 to 15 narrowed this: the task can no longer open a shell back over arbitrary ports, and the ALB and database cannot be used as relays. But tcp/443 to 0.0.0.0/0 is still open, so the exfiltration itself still works; it is narrowed in *channel*, not in *volume*. Prevention needs hostname-based egress filtering (AWS Network Firewall or a proxy allowing only ECR, Logs and STS) or interface endpoints with the 0.0.0.0/0 rule removed. It also needs the task role reduced to read-only. This course cannot build that because Floci has no Network Firewall, no interface endpoints that carry traffic, and no packet filtering at all.

### 4. An attacker who can call sts:AssumeRole from their own machine

- **usms-ecs-task-role / usms-transcripts-reader-role:** both trust only `ecs-tasks.amazonaws.com`, now with `aws:SourceAccount` and `aws:SourceArn`. An attacker's own IAM principal is not that service, so the call is denied outright. Even the confused-deputy route (getting ECS in another account to assume it) is closed by the two conditions. Their permissions differ, but the answer is the same because the trust policy decides first.
- **usms-deploy-role:** trusts `user/usms-admin-01`. An attacker with stolen admin-01 keys **can** assume it. What they get is capped by the boundary: no identity changes, no network deletion, and PassRole only for three roles into ECS. The answers differ because a service trust can only be satisfied by the service, while a user trust is satisfied by anyone holding that user's keys. That is why the deploy role carries a boundary and why Exercise 2's break-glass role adds MFA and an external ID.

### 5. "Five controls" vs "one control"

The five controls on usms-db-01 are not independent in the same way. Controls 1 and 2 (no public IP, no auto-assign) fail together if someone attaches an Elastic IP. Control 3 (no igw route) is the load-bearing one, because it stops return traffic regardless of the others. Controls 4 and 5 are filters that only matter once a packet arrives. If control 3 failed, controls 1 and 4 would still stop an internet attacker (no address to send to, and the group admits only usms-app-sg). If control 4 failed, controls 1 to 3 would still keep the internet out entirely; only VPC-internal sources would gain access. So it is "several different failure modes", not "five times better". The enrolment tasks look like they have one control, but Step 17's matrix models **security groups only**. The tasks also sit in the private subnets, with no public address, no igw route and the private NACL, so they share most of db-01's network controls. The single point of control is real only for *which VPC sources* may reach them.

### 6. The extra rotation steps

- **Step 2 (update every consumer while both keys work)** protects against an outage. It prevents the incident where a forgotten cron job or CI secret still uses the old key and breaks the moment the key changes.
- **Step 3 (deactivate before delete)** protects against an irreversible mistake. If something breaks after deactivation, `update-access-key --status Active` brings the old key back in seconds, whereas a deleted key can never be restored. It prevents the incident where a production integration is down until someone issues and distributes a new key.

A long-lived key is a compromise because it is a bearer secret that works from anywhere until someone remembers to rotate it, and it ends up in laptops, logs and repos. A real system would use **IAM Identity Center (SSO) with MFA** for humans, giving short-lived session credentials, and **IAM roles** for workloads (ECS task roles, instance profiles, IRSA/Pod Identity on EKS), which hand out credentials that rotate automatically.

### 7. Review vs testing

Reading is not an adequate *substitute* for testing, but neither replaces the other. **Reading catches** what testing cannot observe because it never happens in a test: for example, `iam:PassRole` on `Resource "*"` that no test exercises, a trust policy with no Condition, or an egress rule that is still allow-all while everything works. A test only shows that the paths you tried behave as expected. **Testing catches** what reading gets wrong about how the system actually behaves: this lab had several commands that returned `True` while the stored rules said something else (Floci's revoke behaviour), and on real AWS a policy can read correctly yet be broken by an SCP, a resource policy or a typo in a condition key. For student transcripts I would want **reading first**: the claim that matters is "nobody else can read them", which is a negative claim that no number of successful tests can prove. Testing would follow to confirm the legitimate paths still work.
