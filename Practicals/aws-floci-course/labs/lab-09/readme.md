# Lab 09 Report - Securing USMS with IAM Roles and Security Groups

## Aim

To review USMS on both access-control axes, **who can call what** (IAM) and **what can reach what** (security groups and routing), using read-only audit scripts. I then fixed the findings, proved the data tier is unreachable, and showed that the changes survive a restart without breaking any earlier lab. Everything was done on Floci, on **support Path A**.

## Steps 0–3 - Environment, baseline and support probe

The prerequisites passed. `whoami.sh` reports account 000000000000, and all 17 env values loaded. The baseline was lab-02 30/0, 03 31/5, 04 36/2, 05 41/8, 06 21/21. These failures existed before this lab: stopped instances, Floci dropping the source group of group-referenced rules, Lab 06 done on Path C, and the `.gitkeep` false positive. The probe answered everything except `get-account-authorization-details`, Access Analyzer and the credential report.

![Prerequisites](screenshots/lab09-step00-prereqs.png)
![Environment](screenshots/lab09-step01-env-and-values.png)
![Baseline](screenshots/lab09-step02-baseline.png)
![Support probe](screenshots/lab09-step03-support-probe.png)

## Steps 4–5 - Identity inventory and IAM audit

The account has 9 roles, 4 users and 10 customer managed policies, and no role has a boundary. `usms-developer-role` trusts a user, while `usms-ec2-app-role` trusts a service, so for the EC2 role the real gate is `iam:PassRole`. The audit found **HIGH=7 MED=31** and exited 1. Every HIGH is a service trust policy with no Condition (the confused deputy).

![Inventory](screenshots/lab09-step04a-identity-inventory.png)
![Inventory JSON](screenshots/lab09-step04b-inventory-json.png)
![IAM audit](screenshots/lab09-step05-iam-audit.png)

## Step 6 - The transcripts policy

`USMSStudentDataReadWrite` grants `PutObject` and `DeleteObject`, which the enrolment API does not need. `list-entities-for-policy` is unsupported, so I read its holders from the inventory: ec2-app, ecs-task and eks-node roles. `head-bucket` returned 404, so the bucket does not exist yet.

![Transcripts policy](screenshots/lab09-step06-transcripts-policy.png)

## Steps 7–8 - Read-only role, confused-deputy fix, PassRole and boundary (Checkpoint 4)

- **Read-only access:** I created `USMSStudentDataReadOnly` (List + Get, explicit Deny on writes) and `usms-transcripts-reader-role`, whose trust is scoped by `aws:SourceAccount` and `aws:SourceArn`.
- **Confused-deputy fix:** I rewrote `usms-ecs-task-role`'s trust with the same conditions. The check printed **SAME PRINCIPAL, NEW CONDITION**.
- **Scoped PassRole:** `USMSDeployBase` can pass only 3 named roles, only to ECS, and denies any pass to EC2.
- **Deploy role:** `usms-deploy-role` trusts `usms-admin-01` and wears `USMSPermissionsBoundary`. The boundary's AttachmentCount is 0, so it is attached to nothing as an ordinary policy.
- **Floci limitation:** the boundary reads back as `null`, even after `put-role-permissions-boundary`.

![RO policy and role](screenshots/lab09-step07a-ro-policy-and-reader-role.png)
![Trust rewrite](screenshots/lab09-step07b-task-role-trust-rewrite.png)
![Boundary and deploy policy](screenshots/lab09-step08a-boundary-and-deploy-policy.png)
![Checkpoint 4](screenshots/lab09-step08b-deploy-role-checkpoint4.png)
![Boundary limitation](screenshots/lab09-step08c-boundary-floci-limitation.png)

## Step 9 - Session policy

`USMSDeveloperBase` v3 already allows `sts:GetCallerIdentity`, so I added `s3:GetObject` to the session policy to get a denied line. The intersection shows `s3:GetObject`: NOT allowed. `simulate-principal-policy` agrees: implicitDeny for `s3:GetObject` and explicitDeny for `iam:CreateUser`.

![Scoped session](screenshots/lab09-step09a-scoped-session.png)
![Effective permissions](screenshots/lab09-step09b-effective-permissions.png)

## Step 10 - Key rotation (Checkpoint 5)

I created a new key, repointed the profile, deactivated the old key (two keys, one Inactive), verified, then deleted it. `usms-dev-01` now has one Active key created today, and the profile still works.

![Create and repoint](screenshots/lab09-step10a-key-create-and-repoint.png)
![Deactivate and delete](screenshots/lab09-step10b-deactivate-and-delete.png)

## Step 11 - IMDSv2

`HttpTokens` was `optional`, and `modify-instance-metadata-options` is **unsupported** on Floci, so the result is NOT APPLIED. On real AWS, IMDSv2 required with hop limit 1 blocks SSRF credential theft. usms-db-01 has no role, so it should use the stronger `--http-endpoint disabled`. On usms-web-01 that setting would cut off its role credentials.

![IMDSv2](screenshots/lab09-step11-imdsv2.png)
![db-01](screenshots/lab09-step11b-db01-your-turn.png)

## Step 12 - Security group audit

The audit found **HIGH=3 MED=9 LOW=5**: every group had the default allow-all egress, and usms-app-sg allowed SSH from 10.0.0.0/16. Sources shown as `<none>` are group references that Floci returns empty.

![SG audit before](screenshots/lab09-step12-sg-audit-before.png)

## Steps 13–15 - Written egress (Checkpoint 8)

For each group I wrote the undo document first, authorized the new rules, then revoked the allow-all rule.

| Group | Egress now |
|---|---|
| usms-enrolment-sg | tcp/443 to S3 prefix list `pl-63a5400a` + tcp/443 out |
| usms-alb-sg | tcp/80 to usms-enrolment-sg only |
| usms-db-sg | tcp/443 out only |

All three groups have **0 allow-all rules**, and their ingress is unchanged.

**Floci quirk:** after the revoke, `describe-security-groups` shows the allow-all rule gone, but `describe-security-group-rules` still lists it, and prefix-list and group targets read back empty. **JMESPath fix:** `IpProtocol` is the string `"-1"`, so the filter must be `IpProtocol=='-1'`, not `` `-1` ``.

![Prefix list](screenshots/lab09-step13a-prefix-list-and-egress-doc.png)
![Enrolment egress](screenshots/lab09-step13b-enrolment-egress.png)
![Revoke by rule id](screenshots/lab09-step13c-revoke-by-rule-id.png)
![Two views](screenshots/lab09-step13d-egress-two-views.png)
![ALB egress](screenshots/lab09-step14-alb-egress-to-group.png)
![Checkpoint 8](screenshots/lab09-step15-db-egress-checkpoint8.png)

## Step 16 - SSH from the bastion (Checkpoint 9)

I reused `usms-bastion-sg` and added tcp/22 from it to usms-app-sg. Revoking the old rule by rule ID did not remove it from the group. The `--cidr` revoke did, but it also removed the bastion rule, because Floci had dropped that rule's source group. I re-applied the bastion rule. The final state is tcp/22 from the group and **0 CIDR sources**.

![SSH from bastion](screenshots/lab09-step16-ssh-from-bastion.png)
![Revoke CIDR](screenshots/lab09-step16b-revoke-ssh-cidr.png)
![Checkpoint 9](screenshots/lab09-step16c-bastion-rule-reapplied-checkpoint9.png)

## Step 17 - Reachability and negative proof (Checkpoint 10)

The matrix, computed from rules only, shows that the internet can reach usms-alb-sg (80, 443) and usms-app-sg (80). The five controls on usms-db-01 are:

| # | Control | Result |
|---|---|---|
| 1 | No public IP | `127.0.0.1` (Floci loopback mapping, not routable) |
| 2 | No auto-assign | False |
| 3 | No igw route | default route goes to `nat-…`, no `igw-` |
| 4 | SG has one source, no CIDR | tcp/5432, CIDR None |
| 5 | Non-default NACL | IsDefault False |

![Reachability matrix](screenshots/lab09-step17a-reachability-matrix.png)
![Checkpoint 10](screenshots/lab09-step17b-negative-proof-checkpoint10.png)

## Step 18 - Restart and regression

I recorded nine facts, stopped and started Floci, re-derived the IDs and diffed: **PERSISTENCE PROVEN**. All five earlier verify scripts gave the same results: **NOTHING BROKE**. A side effect: the restart removed the Lab 07/08 k3s container, so the EKS cluster needs recreating.

![Restart](screenshots/lab09-step18a-pre-restart-and-restart.png)
![Persistence proven](screenshots/lab09-step18b-persistence-proven.png)
![Nothing broke](screenshots/lab09-step18c-nothing-broke.png)

## Steps 19–20 and Section 8 - Env file, verification, hygiene

- **`configs/lab-09.env`:** 16 exports (17 after Exercise 5), no empty values, no access key ID.
- **`verify-lab-09.sh`:** **PASS=42 FAIL=8**. I fixed four bugs in the lab's version first: a missing `SecurityGroups[0]`, the number-vs-string `-1` filter, over-escaped quotes, and false positives on `${aws:username}` and `.gitkeep`. The 8 remaining failures are all Floci limitations: boundary readback, IMDS, `list-entities-for-policy`, group references dropped on readback, and the 127.0.0.1 address.
- **Cleanup script:** passes `bash -n`; not run.
- **Audits after the changes:** SG MED 9 → 5; IAM HIGH 7 → 6 (0 after Exercise 2).
- **Git:** nothing under `outputs/` is tracked, and `check-ignore` names `.gitignore:7` for the key file.

![lab-09.env](screenshots/lab09-step19-lab09-env.png)
![verify-lab-09](screenshots/lab09-sec8a-verify-lab09.png)
![Cleanup script](screenshots/lab09-sec8b-cleanup-script.png)
![Audits after](screenshots/lab09-sec8c-audits-after.png)
![Git hygiene](screenshots/lab09-step20-git-hygiene.png)

## Floci limitations

| What | Floci 2.0.1 | Real AWS |
|---|---|---|
| Permissions boundary | Accepted, reads back `null` | Stored and enforced |
| `list-entities-for-policy`, IMDS options | Unsupported | Supported |
| Group or prefix-list rule targets | Return empty | Returned |
| Revoke | The two describe APIs disagree; a CIDR revoke also removed group rules | Exact match |
| Instance IPs | 172.20.x private, `127.0.0.1` public | VPC IPs |
| Policy evaluation | None | Every call |

## Conclusion

The system's permissions changed a lot; what it does did not change. Transcripts now have a read-only path. Four service roles have confused-deputy conditions, and three that can't be fixed are recorded as accepted findings. The deploy role can pass only three roles to ECS, under a boundary. Four groups have written egress, and SSH comes only from the bastion. Exercise 5 found that six policies, not three, name the transcripts bucket. The main lesson: on Floci several commands returned `True` while storing something different, so a control counts as proven only once its stored state is read back.

Exercises are in [exercises.md](exercises.md); review answers are in [notes/lab-09-notes.md](../../notes/lab-09-notes.md).
