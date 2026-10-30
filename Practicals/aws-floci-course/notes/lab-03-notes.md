# Lab 03 notes: Amazon EC2 and the USMS application

Everything below is either **observed** in Floci (with a screenshot or command output) or **reasoned** about real AWS. The two are labelled.

## 1. Floci limitations I hit

| Step | What happened in Floci | What real AWS does |
|---|---|---|
| 3 | `ssm get-parameter` for the AL2023 AMI returned `ParameterNotFound`. `describe-images` did seed 5 images, so I used `ami-0abcdef1234567890` (Amazon Linux 2). The user-data uses `dnf` (AL2023); on AL2 it would need `yum`. | Public SSM parameter resolves the newest AMI per region |
| 8, 12 | `run-instances --user-data` was accepted (via `--cli-input-json` + `file://`, and via an explicit base64 string on a throwaway instance) but `describe-instance-attribute --attribute userData` always returned `None`. `modify-instance-attribute` exited 0 with `--value` (stored nothing) and 255 with `--user-data fileb://` (CLI error). The byte-identical `diff` proof could not be completed. | Blob is returned base64-encoded; `openssl base64 -d` + `diff` is empty |
| 8, 10 | Instance reports public `127.0.0.1` and private `172.20.0.x` instead of a `10.0.1.x` address | Private address inside the subnet CIDR |
| 8, 15 | Root volumes created by `run-instances` are untagged (the `volume` entry in `--tag-specifications` was not applied) | Root volume gets the tags |
| 13, 14 | `PublicIpAddress` stays `127.0.0.1` after `associate-address`; `curl` to the EIP times out | EIP replaces the auto-assigned address and is routable |
| 13, 22 | `describe-addresses --filters Name=tag:Name,...` returned every address, so tag-value filters are not applied. `configs/lab-03.env` was written from shell variables instead of tag lookups | Filters apply |
| 15 | `attach-volume` returned `UnsupportedOperation`. The data volume exists but has no attachment, so `DeleteOnTermination` is `None`. The AZ-mismatch "Your turn" could not be tested | Attaches as `/dev/sdf`, `DeleteOnTermination=False`; cross-AZ attach gives `InvalidVolume.ZoneMismatch` |
| 16 | `usms-db-01` reports `127.0.0.1` as public address although the private subnet has `MapPublicIpOnLaunch=False` (checked directly) | No public address |
| 17 | `usms-db-sg`'s tcp/5432 rule is returned with empty `UserIdGroupPairs` and `IpRanges`, even in the `authorize` response and via `describe-security-group-rules`. Re-submitting the same rule created a duplicate (no `InvalidPermission.Duplicate`), and revoke by rule ID returned true but removed nothing. | Returns the source group ID; rejects duplicates |
| 18 | Public address read `127.0.0.1` before, during and after stop/start | Public address is `None` while stopped; EIP survives |
| 20 | `create-image` returned `UnsupportedOperation`. Fallback: `register-image` created a metadata-only record named `usms-web-golden` | Real snapshot of the root volume |

Other incidents (my own, not Floci's): Step 13 was run twice and created a duplicate Elastic IP, which I released; the duplicate-rule test left two identical 5432 rules on `usms-db-sg`, which I removed and re-added once, leaving exactly one.

## 2. Verification result

`verify-lab-03.sh`: **PASS=32 FAIL=4**. The four failures are Floci limitations: user data not stored, data volume not attached, `DeleteOnTermination` not False (no attachment), and `usms-db-01` reporting a public address. I changed the "user data stored" check to compare against `None`, because the lab's non-empty test would have counted Floci's literal text `None` as a pass.

## 3. Evidence that the configuration is right (observed)

- Permission chain: instance -> `usms-ec2-app-profile` -> `usms-ec2-app-role` -> `USMSStudentDataReadWrite` (screenshots `lab3_cp3_...`, `step11_...`).
- `usms-db-01`: private subnet, `usms-db-sg`, no instance profile, subnet `MapPublicIpOnLaunch=False`.
- Private route table default route targets `nat-...`, not an `igw-` (outbound only).
- Six reachability checks all non-null (Step 14).
- Persistence: same two instances, subnets and security groups after a Floci restart; 3 volumes, 2 Elastic IPs (`lab3_cp6_...`).
- Private key: `chmod 600`, matched by `.gitignore:20:*.pem`, not tracked.

## 4. Review questions

### Q1. The five inputs to Step 8

| Input | If wrong or missing | Failure |
|---|---|---|
| Subnet (Lab 2) | `InvalidSubnetID.NotFound`; launch refused. A valid but wrong subnet launches into the wrong place | Immediate if missing, silent if wrong |
| Security group (Lab 2) | `InvalidGroup.NotFound`. A wrong but valid group gives the instance the wrong firewall | Immediate if missing, silent if wrong |
| Instance profile (Lab 1) | `InvalidParameterValue` on `iamInstanceProfile.name`. A wrong profile launches with the wrong permissions | Immediate if missing, silent if wrong |
| Key pair (Lab 3) | `InvalidKeyPair.NotFound`; launch refused | Immediate |
| User-data script (Lab 3) | A syntax error is accepted by the API and only fails at first boot inside the instance; nothing gets configured | Silent, the worst case |

Missing things fail loudly; wrong-but-valid things fail silently. That is why the lab reads user data back (Step 12) and runs `bash -n` before launching. (Reasoned, except the `bash -n` check, which I ran.)

### Q2. A policy on a bucket that does not exist

`USMSStudentDataReadWrite` grants access to `arn:aws:s3:::usms-student-data`, and the bucket does not exist yet. This is valid because an IAM policy is a statement about ARN strings, not a reference to a live object. IAM compares the requested resource's ARN with the policy when a request arrives; it never checks that anything exists at that ARN. Today `usms-web-01` holds the permission but has nothing to use it on: a call would fail with `NoSuchBucket`, not `AccessDenied`. At the moment Lab 4 runs `create-bucket`, a resource appears at that ARN and the already-attached policy starts to match. The instance can then read and write transcripts with no access key on the machine and no change to the instance, the profile, the role or the policy. The permission was in place before the resource, so the resource is governed from its first second. (I observed the chain and the policy document, screenshot `step11_...`; the `create-bucket` behaviour is reasoned.)

### Q3. User data and redeploying on restart

User data runs once, at first boot, via cloud-init, which records that it has run. Stop/start and reboot are not first boot, so the script does not run again, and a colleague's "restart redeploys it" does not hold. Two approaches that do work: (1) replace rather than restart: bake the application into an AMI or launch template and launch a fresh instance, which does have a first boot (this is what Lab 08's Auto Scaling group will do); (2) deploy on every start or on demand: a systemd unit or a cloud-init per-boot script that pulls and installs the release, or a deployment tool (CodeDeploy, SSM Run Command) that pushes a release to running instances. In Floci the script was never stored or executed at all, so this answer is reasoned, not observed.

### Q4. Auto-assigned public address vs Elastic IP

| | Auto-assigned (Step 10) | Elastic IP (Step 13) |
|---|---|---|
| Who owns it | AWS lends it to the instance from a pool | The account owns it as its own resource (allocation ID) |
| When it changes | Released on stop, a new one on start | Never, until released |
| Cost | Historically free; since early 2024 AWS charges for every public IPv4 address, so check current pricing | Charged hourly, and idle ones are the surprise on a bill (the lab quotes about USD 3.60/month) |
| On instance stop | Released; the instance has no public address | Stays allocated and associated |

Failover that only the EIP allows: if the web server fails, start a standby instance and run `associate-address --allocation-id <eip> --instance-id <standby> --allow-reassociation`. The public address moves to the standby and DNS needs no change. With an auto-assigned address there is nothing to move. In Floci I observed the EIP staying associated through stop/start, but the auto-assigned release was not observable (the address stayed `127.0.0.1`).

### Q5. EBS volumes and snapshots across Availability Zones

A volume can only attach inside its own AZ, which tells me it lives in that AZ's storage fabric. A snapshot can be restored into any AZ of the region, so it must be stored regionally (in AWS-managed S3). To survive the loss of one AZ, data must exist outside that AZ: take regular snapshots (or use replication such as RDS Multi-AZ) so a new volume can be created in a surviving AZ, and keep AMIs and launch templates so compute can be rebuilt there. A volume alone is not AZ-fault-tolerant. (Reasoned; Floci could not attach volumes, so the AZ constraint was not tested.)

### Q6. Is the six-check fallback adequate?

It is adequate for proving the configuration: state running, subnet route to an IGW, IGW attached, security group admits 80, public address present, NACL exists. Those are the AWS-side links of the chain, and all six returned real values. It is not adequate as proof that the application is reachable. The class of fault it cannot detect is anything inside the guest: no process listening on port 80 (nginx not installed, crashed, or bound to localhost), a failed user-data script, or an OS firewall. It also only confirms that a NACL is attached, not that its rule contents allow the traffic. On real AWS, the seventh link is the one that is not an AWS problem, and it is often the real answer.

### Q7. `usms-web-01` vs `usms-db-01`

| Difference | Belongs to |
|---|---|
| Name and `Tier` tags (web vs data) | Instance |
| Security group (`usms-app-sg` vs `usms-db-sg`) | Instance (attached to its network interface; the rules themselves live in the VPC) |
| Instance profile (present vs none) | Instance |
| User data (web has it, db has none) | Instance |
| Elastic IP association | Instance |
| Subnet, AZ-local CIDR and so private IP range (10.0.1.0/24 vs 10.0.3.0/24) | Subnet |
| `MapPublicIpOnLaunch` (true vs false), hence whether it gets a public address | Subnet |
| Route table (default route to IGW vs to NAT) and NACL (`usms-private-nacl`) | Subnet association |
| IGW, NAT gateway, S3 endpoint, DNS settings that make those routes exist | VPC |

Both are `t3.micro` from the same AMI, and the key pair is the same.
- Floci limitation (Exercise 4): describe-nat-gateways returned EIP None for nat-d19ba80f9652d2955, and describe-instance-credit-specifications returned UnsupportedOperation.
