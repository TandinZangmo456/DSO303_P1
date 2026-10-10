# Lab 03 exercises

**Status: DRAFT. None of the five exercises has been run against Floci yet.** The scripts in `drafts/` pass `bash -n` only. Fill in the "Output" sections after running each one, and do not submit this file with the TODOs still in it.

## Exercise 1 - maintenance instance (basic)

Plan (long-form launch, waiter, not recorded in `lab-03.env`):

```bash
ADMIN_ID=$(aws ec2 run-instances --image-id "$AMI_ID" --instance-type t3.micro \
  --key-name usms-app-key --subnet-id "$USMS_PUBLIC_SUBNET_B" --security-group-ids "$USMS_APP_SG" \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=usms-admin-01-host},{Key=Project,Value=USMS},{Key=Tier,Value=admin},{Key=Lab,Value=03},{Key=Ephemeral,Value=true}]' \
  --query 'Instances[0].InstanceId' --output text)
aws ec2 wait instance-running --instance-ids "$ADMIN_ID"
```

Note: Floci ignores tag filters, so verify with `describe-instances --instance-ids "$ADMIN_ID"` (Subnet, AZ `us-east-1b`) rather than a `Tier=admin` filter. Check `$USMS_PUBLIC_SUBNET_B` is set in `configs/lab-02.env` first.

Output: TODO

## Exercise 2 - self-describing bootstrap (intermediate)

Draft: `drafts/user-data-db.sh` (marker file check at the top makes it idempotent; outer heredoc must be quoted so `$(date)` and `${INSTANCE_ID}` expand on the instance at boot, not in the local shell).

Floci does not return stored user data, so the byte-identical `diff` from Step 12 cannot pass; record that as the known limitation and show `bash -n` and the byte count (`wc -c`, under 16,384) instead.

A re-run can only happen if cloud-init is told to run per-boot, or someone executes the script by hand; the marker check makes either harmless.

Output: TODO

## Exercise 3 - reachability report (problem solving)

Draft: `drafts/lab-03-reachability.sh`. Verdicts: REACHABLE, UNREACHABLE (no IGW route), NO-ADDRESS (IGW route but no public address), BLOCKED (security group does not admit 80). Why `-e` is off is in the script's header comment.

Floci caveat: every instance shows public `127.0.0.1`, so expect `usms-db-01` to be misclassified on this build; the private route table has no IGW route, so the script should still say UNREACHABLE for it. Test it from `~` and from `labs/lab-03-ec2/` (it uses no relative paths).

Output: TODO

## Exercise 4 - right-size and clean up (challenge)

Written analysis: TODO. Points to cover, from the brief:
- Scale up vs out: at 400 concurrent mostly-read users, scaling out (several instances behind a load balancer, with the golden AMI) handles peak and lets you remove instances overnight; a bigger single instance does neither.
- t3 burstable credits: sustained 85% CPU exceeds the t3.micro baseline (about 10% per vCPU), so credits run out and the instance is either throttled (standard mode) or billed extra (unlimited mode). Check with `aws ec2 describe-instance-credit-specifications`.
- Monthly cost comparison of at least two options with prices **cited from a named source (AWS EC2 pricing page)**: TODO, look up current prices; do not use the lab's rounded figures as your citation.
- Deletions (only the Exercise 1 host, orphaned volumes, unassociated EIPs), each preceded by the four-line danger note. Do not touch anything in the lab's KEEP column. Floci caveat: the data volume `usms-web-data-vol` has no attachment, so it looks "orphaned" but is on the KEEP list; leave it.

## Exercise 5 - S3 hand-off for Lab 4 (integration)

Draft: `drafts/transcript-upload.sh` (two-argument validation, exits non-zero with a message, no access keys anywhere).

Still to do: TODO
- `outputs/lab-03-s3-readiness.txt`: instance ID, profile ARN, role name, policy name, bucket ARN from the policy (`arn:aws:s3:::usms-student-data`), and the captured `aws s3api head-bucket --bucket usms-student-data` result (use `|| true` and record `$?`; the failure is the evidence).
- One sentence on outbound: security groups allow all outbound by default, and that rule you never wrote is what lets the instance reach S3.
- Add `USMS_BUCKET_NAME=usms-student-data` to `configs/lab-03.env` if `lab-01.env` does not carry it. (The exercise text mentions "a second inbound rule ... 443 outbound"; it is self-contradictory, so confirm the default egress rule instead of adding anything.)
