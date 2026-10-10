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


## Exercise 2 - self-describing bootstrap (intermediate)

Draft: `drafts/user-data-db.sh` (marker file check at the top makes it idempotent; outer heredoc must be quoted so `$(date)` and `${INSTANCE_ID}` expand on the instance at boot, not in the local shell).

Floci does not return stored user data, so the byte-identical `diff` from Step 12 cannot pass; record that as the known limitation and show `bash -n` and the byte count (`wc -c`, under 16,384) instead.

A re-run can only happen if cloud-init is told to run per-boot, or someone executes the script by hand; the marker check makes either harmless.


## Exercise 3 - reachability report (problem solving)

Draft: `drafts/lab-03-reachability.sh`. Verdicts: REACHABLE, UNREACHABLE (no IGW route), NO-ADDRESS (IGW route but no public address), BLOCKED (security group does not admit 80). Why `-e` is off is in the script's header comment.

Floci caveat: every instance shows public `127.0.0.1`, so expect `usms-db-01` to be misclassified on this build; the private route table has no IGW route, so the script should still say UNREACHABLE for it. Test it from `~` and from `labs/lab-03-ec2/` (it uses no relative paths).


## Exercise 4 - right-size and clean up (challenge)

Written analysis: TODO. Points to cover, from the brief:
- Scale up vs out: at 400 concurrent mostly-read users, scaling out (several instances behind a load balancer, with the golden AMI) handles peak and lets you remove instances overnight; a bigger single instance does neither.
- t3 burstable credits: sustained 85% CPU exceeds the t3.micro baseline (about 10% per vCPU), so credits run out and the instance is either throttled (standard mode) or billed extra (unlimited mode). Check with `aws ec2 describe-instance-credit-specifications`.
- Monthly cost comparison of at least two options with prices **cited from a named source (AWS EC2 pricing page)**: TODO, look up current prices; do not use the lab's rounded figures as your citation.
- Deletions (only the Exercise 1 host, orphaned volumes, unassociated EIPs), each preceded by the four-line danger note. Do not touch anything in the lab's KEEP column. Floci caveat: the data volume `usms-web-data-vol` has no attachment, so it looks "orphaned" but is on the KEEP list; leave it.

## Exercise 5 - S3 hand-off for Lab 4 (integration)

Draft: `drafts/transcript-upload.sh` (two-argument validation, exits non-zero with a message, no access keys anywhere).

- `outputs/lab-03-s3-readiness.txt`: instance ID, profile ARN, role name, policy name, bucket ARN from the policy (`arn:aws:s3:::usms-student-data`), and the captured `aws s3api head-bucket --bucket usms-student-data` result (use `|| true` and record `$?`; the failure is the evidence).
- One sentence on outbound: security groups allow all outbound by default, and that rule you never wrote is what lets the instance reach S3.
- Add `USMS_BUCKET_NAME=usms-student-data` to `configs/lab-03.env` if `lab-01.env` does not carry it. (The exercise text mentions "a second inbound rule ... 443 outbound"; it is self-contradictory, so confirm the default egress rule instead of adding anything.)

### Exercise 1 result
- Launched usms-admin-01-host as i-75c5ab654ebf06d13 in usms-public-subnet-b (us-east-1b) with usms-app-sg and no instance profile, using the long-form command and `aws ec2 wait instance-running` (no sleep). Not recorded in configs/lab-03.env.
- The Tier=admin tag filter on describe-instances returned exactly the one admin instance (i-75c5ab654ebf06d13), so the expected outcome is met. (Tag-value filters were only found to be ignored on describe-addresses.)

### Exercise 2 result
- Script: labs/lab-03-ec2/user-data-db.sh. `bash -n` passed, 679 bytes (limit 16,384). Launched usms-db-02 as i-4e4ee481c1cea6bb9 in usms-private-subnet-b (us-east-1b) with usms-db-sg.
- Step 12 round trip: Floci returned None for the stored user data, so the decoded file did not match (MISMATCH). Floci limitation: it accepts --user-data but does not return it. On real AWS the diff would be empty.
- Why the outer heredoc is quoted: so my local shell writes `$(date ...)`, `${INSTANCE_ID}` and `$MARKER` into the file literally; they must be evaluated on the instance at boot, not on my laptop now.
- Idempotence: the first lines check for /var/log/usms-db-bootstrap.done and `exit 0` if it exists, so a second run changes nothing. The marker is written last, so a run that fails halfway will retry on the next run.
- When a re-run could actually happen: user data normally runs only once, at first boot. It could run again if cloud-init is configured to run scripts every boot (scripts-user per-boot), if the instance is rebuilt from an AMI that was captured before cloud-init recorded the first run, or if someone runs the script by hand. The marker makes all of those safe.

### Exercise 2 result
- Script: labs/lab-03-ec2/user-data-db.sh. `bash -n` passed, 679 bytes (limit 16,384). Launched usms-db-02 as i-4e4ee481c1cea6bb9 in usms-private-subnet-b (us-east-1b) with usms-db-sg.
- Step 12 round trip: Floci returned None for the stored user data, so the decoded file did not match (MISMATCH). Floci limitation: it accepts --user-data but does not return it. On real AWS the diff would be empty.
- Why the outer heredoc is quoted: so my local shell writes `$(date ...)`, `${INSTANCE_ID}` and `$MARKER` into the file literally; they must be evaluated on the instance at boot, not on my laptop now.
- Idempotence: the first lines check for /var/log/usms-db-bootstrap.done and `exit 0` if it exists, so a second run changes nothing. The marker is written last, so a run that fails halfway will retry on the next run.
- When a re-run could actually happen: user data normally runs only once, at first boot. It could run again if cloud-init is configured to run scripts every boot (scripts-user per-boot), if the instance is rebuilt from an AMI that was captured before cloud-init recorded the first run, or if someone runs the script by hand. The marker makes all of those safe.

### Exercise 3 result
- Script: scripts/utilities/lab-03-reachability.sh. It resolves each instance's route table (explicit association, else the VPC main table), checks for an igw- route, then for a public address, then for a security-group rule admitting 80/tcp from 0.0.0.0/0. Verdicts never use names or tags. No hard-coded IDs; the repo root is found from the script's own path.
- `-e` is not set, on purpose: a None field is a state to classify, so one failed describe call must not abort the report.
- Output was identical when run from the repo root, from ~, and from labs/lab-03-ec2/ (diff empty).
- Result: usms-web-01 and usms-admin-01-host REACHABLE; usms-db-01 and usms-db-02 UNREACHABLE (no igw route on subnet).
- Floci limitations: every instance reports public 127.0.0.1, so the NO-ADDRESS case (igw route present, no public address) could not be produced here. usms-web-01 and usms-admin-01-host both report private IP 172.20.0.3, which real AWS would not allow.
- NO-ADDRESS is its own verdict because that state is neither reachable nor unreachable: the network path exists, but the instance has no address to receive traffic on.

### Exercise 5 result
- Script: labs/lab-03-ec2/transcript-upload.sh. Takes <student-id> <file-path>, validates both (exit 2 with a usage or error message if either is missing or the file does not exist), and runs `aws s3 cp` to s3://usms-student-data/transcripts/<student-id>/<filename>. It contains no access key, no secret, no --profile; credentials come from the instance profile. Not executed: the bucket does not exist yet and I am not on the instance.
- Outbound: usms-app-sg has one egress rule, protocol -1 to 0.0.0.0/0. That default allow-all outbound rule, which I never wrote, is what lets the instance reach the S3 endpoint; no inbound rule is needed for it, because security groups are stateful and the instance initiates the connection.
- Evidence file outputs/lab-03-s3-readiness.txt: instance i-7d102245bea4dde6d, profile arn:aws:iam::000000000000:instance-profile/usms-ec2-app-profile, role usms-ec2-app-role, policy USMSStudentDataReadWrite, bucket ARN arn:aws:s3:::usms-student-data, and `head-bucket` exit 254 ("An error occurred (404) when calling the HeadBucket operation: Not Found").
- What changes when Lab 4 creates the bucket: the same head-bucket call succeeds (exit 0), and the instance's upload would be allowed by the already-attached policy with no change to the instance, role or policy.
- USMS_BUCKET_NAME is already exported by configs/lab-01.env, so it was not added to lab-03.env (as the exercise instructs).

### Exercise 4 result

**Scale up or out.** I would scale out. 400 mostly-read concurrent users is a load that spreads well across identical web servers, and the web tier is already stateless (static pages, data on a separate tier). Scaling up to a bigger single instance (for example t3.medium) removes the CPU pressure but keeps a single point of failure, and it costs the same overnight when the server is idle. Scaling out means two or more instances behind a load balancer across both Availability Zones, built from the golden AMI, and an Auto Scaling group (Lab 08) can remove instances overnight, which is what addresses the idle time.

**Burstable credits.** A t3 instance earns CPU credits at a fixed rate (for t3.micro the baseline is about 10% of each vCPU) and spends them whenever it runs above that. One credit is one vCPU at 100% for one minute. Sustained 85% CPU is far above the baseline, so credits drain: in standard mode the instance is throttled back to its baseline, and in unlimited mode it keeps its speed but bills surplus credits as extra money. The setting decides which one happens. T3 instances launch in unlimited mode by default, so the likely outcome is a silent extra charge, not a slowdown. I could not read this setting: Floci returned UnsupportedOperation for describe-instance-credit-specifications. On real AWS I would run that command and confirm the rate on the EC2 pricing page before relying on it.

**Cost comparison (on-demand Linux, us-east-1, 730 h/month).** Source: Holori EC2 price calculator, mirrored by DoiT price tables; to be re-checked against aws.amazon.com/ec2/pricing/on-demand.
| Option | Calculation | Per month |
|---|---|---|
| Current: 1 x t3.micro, always on | 0.0104 x 730 | about $7.59 |
| A. Scale up: 1 x t3.medium, always on | 0.0416 x 730 | about $30.37 |
| B. Scale out: 2 x t3.micro, always on | 2 x 0.0104 x 730 | about $15.18 |
| C. Scale out with overnight scale-in: 1 always on + 1 for about half the day | 7.59 + 3.80 | about $11.39 |
Not included (not priced here): the load balancer needed for B and C, EBS storage, data transfer, and any surplus-credit charges. B and C therefore cost more than shown, by the load balancer's price. Option C is still the cheapest way to cover the peak, and A is the most expensive while giving no overnight saving.

**What I deleted today.** Only usms-admin-01-host (i-75c5ab654ebf06d13, tagged Ephemeral=true), whose root volume is deleted with it. Before running it I confirmed nothing depended on it (no Elastic IP, no data volume, not in lab-03.env). I did not delete anything in the KEEP column: usms-web-data-vol looks orphaned (state available, no attachment) only because Floci does not support attach-volume; usms-nat-eip shows no instance because it belongs to the NAT gateway from Lab 2. I left usms-db-02 (Exercise 2) in place because it is not marked ephemeral and is not in the exercise's delete list; I am flagging it so it can be removed if the lecturer wants it gone.

**Dependency order.** Elastic IPs must be disassociated before release, volumes detached before deletion, and instances terminated before the VPC around them can be removed. Today's deletion was a single instance, so only the last of these applied.

**Verification afterwards.** verify-lab-03.sh reports PASS=32 FAIL=4, identical to before the deletion. The four failures are the Floci limitations recorded in notes/lab-03-notes.md, so the deletion changed nothing that the script checks.
