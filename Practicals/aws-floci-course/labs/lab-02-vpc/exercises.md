# Lab 02 — Independent Lab Exercises

**Course:** DSO303 — AWS Infrastructure for USMS (Floci local emulator)
**VPC in use:** `usms-vpc` (`vpc-1efb1fbc`), `10.0.0.0/16`

---

## Exercise 1 — Basic: a third public subnet

**Requirement:** Create `usms-public-subnet-c` in `us-east-1c`, CIDR `10.0.5.0/24`, tagged consistently with the existing subnets, auto-assigning public IPv4 addresses, and associated with `usms-public-rt`.

### Commands

```bash
PUBLIC_SUBNET_C_ID=$(aws ec2 create-subnet \
  --vpc-id "$USMS_VPC_ID" \
  --cidr-block 10.0.5.0/24 \
  --availability-zone "${AWS_REGION_COURSE}c" \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=usms-public-subnet-c},{Key=Project,Value=USMS},{Key=Tier,Value=public},{Key=AZ,Value=c}]' \
  --query 'Subnet.SubnetId' \
  --output text)

aws ec2 modify-subnet-attribute \
  --subnet-id "$PUBLIC_SUBNET_C_ID" \
  --map-public-ip-on-launch

aws ec2 associate-route-table \
  --route-table-id "$USMS_PUBLIC_RT" \
  --subnet-id "$PUBLIC_SUBNET_C_ID" \
  --query 'AssociationId' \
  --output text
```

### Result

- `usms-public-subnet-c` created as `subnet-0b65e266`, `10.0.5.0/24`, `us-east-1c`.
- `MapPublicIpOnLaunch` confirmed `True`.
- Associated with `usms-public-rt` (`rtb-0c30599b`) — verified the route table now shows three associated subnet IDs (public A, B, and C).

**Verification output:**

| AZ | CIDR | Name | Public |
|---|---|---|---|
| us-east-1a | 10.0.1.0/24 | usms-public-subnet-a | True |
| us-east-1b | 10.0.2.0/24 | usms-public-subnet-b | True |
| us-east-1a | 10.0.3.0/24 | usms-private-subnet-a | False |
| us-east-1c | 10.0.5.0/24 | usms-public-subnet-c | True |

**Status: Complete.** Not added to `configs/lab-02.env`, per the lab's instructions — it's practice, not a Lab 3 dependency.

![Exercise 1 — public subnet C created and verified](screenshots/ex1_public_subnet_c.png)

---

## Exercise 2 — Intermediate: a bastion security group

**Requirement:** Create `usms-bastion-sg` allowing inbound SSH from a single trusted IP. Then modify `usms-app-sg` so its SSH rule is sourced from `usms-bastion-sg` (group-referenced) instead of the whole VPC CIDR, and remove the old CIDR-based rule.

### Commands

```bash
BASTION_SG_ID=$(aws ec2 create-security-group \
  --group-name usms-bastion-sg \
  --description "USMS bastion host: SSH from a single trusted admin IP only" \
  --vpc-id "$USMS_VPC_ID" \
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=usms-bastion-sg},{Key=Project,Value=USMS},{Key=Tier,Value=bastion}]' \
  --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress \
  --group-id "$BASTION_SG_ID" \
  --ip-permissions '[{"IpProtocol":"tcp","FromPort":22,"ToPort":22,"IpRanges":[{"CidrIp":"203.0.113.10/32","Description":"SSH from the designated admin workstation"}]}]'

# Add the new bastion-sourced rule to usms-app-sg BEFORE removing the old one
aws ec2 authorize-security-group-ingress \
  --group-id "$USMS_APP_SG" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":22,\"ToPort\":22,\"UserIdGroupPairs\":[{\"GroupId\":\"$BASTION_SG_ID\",\"Description\":\"SSH from the USMS bastion host only\"}]}]"

# Remove the old CIDR-based SSH rule by its exact rule ID
aws ec2 revoke-security-group-ingress \
  --group-id "$USMS_APP_SG" \
  --security-group-rule-ids sgr-d872bf32e6c395656
```

### Result

- `usms-bastion-sg` created as `sg-290601e859eb2a6d9`, with one inbound rule: TCP 22 from `203.0.113.10/32`.
- New group-referenced SSH rule added to `usms-app-sg` (`sgr-f1f901da77ca9a184`), correctly built with `UserIdGroupPairs` pointing at `usms-bastion-sg`.
- `revoke-security-group-ingress` against the old rule (`sgr-d872bf32e6c395656`, source `10.0.0.0/16`) returned `{"Return": true}`, but a follow-up `describe-security-group-rules` showed the rule **still present**.

### Floci limitations observed

1. **`UserIdGroupPairs` does not round-trip.** The new rule was created with a correctly formed `UserIdGroupPairs` payload (confirmed in the exact request sent), but `describe-security-group-rules` reads it back with an empty group reference. This was also observed earlier in the lab when building `usms-db-sg`'s rule sourced from `usms-app-sg`.
2. **`revoke-security-group-ingress` reports success without removing the rule.** Confirmed twice in this lab (once on `usms-db-sg`, once here on `usms-app-sg`) — the API returns `{"Return": true}` but the targeted rule remains in `describe-security-group-rules` output afterward.

**Status: Complete by design intent.** The correct AWS mechanisms were used throughout (`--security-group-rule-ids` for precise removal, `UserIdGroupPairs` for group-to-group rules) — the emulator cannot fully demonstrate the end state due to the two limitations above.

![Exercise 2 — usms-bastion-sg created](screenshots/ex2_bastion_sg_created.png)

![Exercise 2 — locating the old SSH rule and adding the bastion-sourced rule](screenshots/ex2_find_rule_add_bastion_rule.png)

![Exercise 2 — revoke call and the resulting Floci limitation](screenshots/ex2_revoke_and_limitation.png)

---

## Exercise 3 — Problem solving: a network classification script

**Requirement:** A script (`scripts/utilities/lab-02-network-report.sh`) that prints one line per subnet in `usms-vpc`, classifying each as `PUBLIC`, `PRIVATE`, or `ISOLATED` based purely on its route table — never on subnet names or tags. Must run correctly from any directory, never hardcode an ID, and must not fail on a subnet with no default route.

### Script

```bash
#!/usr/bin/env bash
# Classify every subnet in usms-vpc as PUBLIC, PRIVATE, or ISOLATED,
# based purely on its effective route table's default route target.
# Never hardcodes an ID; safe to run from any directory.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-02.env"

VPC_ID="$USMS_VPC_ID"

aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'sort_by(Subnets, &CidrBlock)[].SubnetId' \
  --output text | tr '\t' '\n' | while read -r subnet_id; do

  [ -z "$subnet_id" ] && continue

  name=$(aws ec2 describe-subnets --subnet-ids "$subnet_id" \
          --query 'Subnets[0].Tags[?Key==`Name`]|[0].Value' --output text)
  cidr=$(aws ec2 describe-subnets --subnet-ids "$subnet_id" \
          --query 'Subnets[0].CidrBlock' --output text)
  az=$(aws ec2 describe-subnets --subnet-ids "$subnet_id" \
          --query 'Subnets[0].AvailabilityZone' --output text)

  rt=$(aws ec2 describe-route-tables \
        --filters "Name=association.subnet-id,Values=$subnet_id" \
        --query 'RouteTables[0].RouteTableId' --output text)

  igw=$(aws ec2 describe-route-tables --route-table-ids "$rt" \
        --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId | [0]' \
        --output text 2>/dev/null)
  nat=$(aws ec2 describe-route-tables --route-table-ids "$rt" \
        --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].NatGatewayId | [0]' \
        --output text 2>/dev/null)

  if [ -n "$igw" ] && [ "$igw" != "None" ]; then
    printf '%-24s %-14s %-12s PUBLIC   via %s\n' "$name" "$cidr" "$az" "$igw"
  elif [ -n "$nat" ] && [ "$nat" != "None" ]; then
    printf '%-24s %-14s %-12s PRIVATE  via %s\n' "$name" "$cidr" "$az" "$nat"
  else
    printf '%-24s %-14s %-12s ISOLATED no default route\n' "$name" "$cidr" "$az"
  fi
done
```

### Result

Output (identical whether run from `~`, `labs/lab-02-vpc/`, or the repo root):

```
usms-public-subnet-a    10.0.1.0/24   us-east-1a  PUBLIC   via igw-49bc6df6
usms-public-subnet-b    10.0.2.0/24   us-east-1b  PUBLIC   via igw-49bc6df6
usms-private-subnet-a   10.0.3.0/24   us-east-1a  PRIVATE  via nat-d19ba80f9652d2955
usms-public-subnet-c    10.0.5.0/24   us-east-1c  PUBLIC   via igw-49bc6df6
```

Directory independence confirmed by running the script from `~`, from `labs/lab-02-vpc/` (via a relative path), and from the repo root — all three produced byte-identical classification output.

**Status: Complete.** Committed as `scripts/utilities/lab-02-network-report.sh` (commit `5dbf7de`).

![Exercise 3 — script created and first run](screenshots/ex3_script_created_and_run.png)

![Exercise 3 — directory independence test](screenshots/ex3_directory_independence_test.png)

![Exercise 3 — committed to Git](screenshots/ex3_git_commit.png)

---

## Exercise 4 — Challenge: design and defend (exam-results service)

**Scenario:** USMS is adding an exam-results service. It must be reachable only by staff on campus (`10.10.0.0/16`, arriving over VPN), reads the transcripts database, must never be internet-reachable, and needs outbound access to download security patches.

### Design

**1. Subnet placement.**
The service goes in the existing private tier — `usms-private-subnet-a` (or `-b`, for HA) — not a new subnet. No new VPC is needed. The private tier already has exactly the properties the requirement describes: no route to an internet gateway, and outbound access via the NAT gateway for patches.

**2. Security groups.**
A new group, `usms-exam-sg`, attached to the exam-results instance(s):
- **Inbound:** TCP 443 (or an internal app port) from `10.10.0.0/16` only — the campus VPN range — never `0.0.0.0/0`.
- **Outbound:** rely on the default allow-all-outbound (covers the DB connection on 5432 and HTTPS for patches), or scope explicitly to `usms-db-sg` on 5432 plus 443 to `0.0.0.0/0` if a stricter posture is wanted.
- **No inbound SSH.** Management is via SSM Session Manager or the existing bastion (`usms-bastion-sg`) rather than a direct SSH rule, avoiding another exposed port.

**3. NACL change.**
The existing `usms-private-nacl` already allows TCP 5432 inbound from `10.0.0.0/16`, TCP 443 outbound to `0.0.0.0/0`, and the ephemeral-port (1024–65535) return-traffic rules. Whether a new NACL rule is required depends on whether campus VPN traffic arrives at the subnet already translated to a `10.0.0.0/16`-range address, or with the original `10.10.0.0/16` source preserved.

**Decision:** add an explicit NACL rule allowing inbound traffic from `10.10.0.0/16` on the exam-results app port, plus the matching ephemeral-port outbound reply, rather than assuming the VPN performs translation. A NACL is meant to be an explicit, auditable backstop — relying on an assumption about upstream network behavior defeats that purpose.

**4. Second NAT gateway in AZ b — cost/availability trade-off.**
A NAT gateway costs approximately **$0.045/hour (~$32/month)** plus **$0.045/GB processed** in `us-east-1` (AWS's published NAT Gateway pricing for the region — verify current figures on AWS's pricing page before citing in a final submission, as these can change).

- **One NAT gateway (current state):** cheaper, but it is a single point of failure for the *entire* private tier. If AZ a fails, `usms-private-subnet-b`'s instances lose outbound access even though they are otherwise healthy — the availability boundary is not actually per-AZ, it's wherever the NAT gateway happens to sit.
- **Two NAT gateways (one per AZ):** roughly double the fixed monthly cost, but removes that single point of failure.

**Recommendation:** for a system with a real availability expectation during exam periods, the additional ~$32/month for a second NAT gateway is justified. This is a defensible trade-off either way provided it is stated explicitly, which is the actual point of the exercise.

**5. Cleanup plan.**
Remove `usms-public-subnet-c` (Exercise 1), since it was created for practice only, has no attached security group or instance, and is not part of the exam-results design.

```
Read before running any delete command

What will be deleted: usms-public-subnet-c (subnet-0b65e266) and its
association with usms-public-rt.

What depends on it: nothing — no instances, no security groups, no
other subnet references it.

Reversible? No, the subnet itself is not recoverable once deleted;
however it can be recreated identically at no cost using the same
commands from Exercise 1.

Effect on later labs: none. This subnet was never referenced in
configs/lab-02.env or consumed by any later lab step.
```

Deletion order: disassociate the route table association first, then delete the subnet.

```bash
aws ec2 disassociate-route-table --association-id <current association ID>
aws ec2 delete-subnet --subnet-id subnet-0b65e266
```

### Implementation status

The design above has been talked through and is ready to implement; **`usms-exam-sg` has not yet been created in the environment.** The concrete next step is to run the `create-security-group` / `authorize-security-group-ingress` commands for the 443-from-campus-VPN rule described above, following the same pattern used for `usms-app-sg` and `usms-db-sg` earlier in this lab.

**Status: Design complete. Security group implementation pending.**

---

## Exercise 5 — Integration: complete the second Availability Zone

**Requirement:** While holding `usms-developer-role` credentials (not the normal identity), create `usms-private-subnet-b` (`10.0.4.0/24`, `us-east-1b`), tagged consistently, associated with `usms-private-rt`, with `usms-private-nacl` applied. Restore identity afterward, regenerate `configs/lab-02.env`, confirm `USMS_PRIVATE_SUBNET_B` is populated.

### Commands

```bash
# Assume the developer role (note: USMS_ROLE_DEVELOPER is already a full ARN)
aws sts assume-role \
  --role-arn "$USMS_ROLE_DEVELOPER" \
  --role-session-name "lab02-ex5-private-subnet-b" \
  --profile usms-dev \
  > outputs/lab-02-ex5-assumed-role.json

export AWS_ACCESS_KEY_ID=$(jq -r '.Credentials.AccessKeyId'     outputs/lab-02-ex5-assumed-role.json)
export AWS_SECRET_ACCESS_KEY=$(jq -r '.Credentials.SecretAccessKey' outputs/lab-02-ex5-assumed-role.json)
export AWS_SESSION_TOKEN=$(jq -r '.Credentials.SessionToken'    outputs/lab-02-ex5-assumed-role.json)

# Confirmed identity: arn:aws:sts::000000000000:assumed-role/usms-developer-role/floci-session

PRIVATE_SUBNET_B_ID=$(aws ec2 create-subnet \
  --vpc-id "$USMS_VPC_ID" \
  --cidr-block 10.0.4.0/24 \
  --availability-zone "${AWS_REGION_COURSE}b" \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=usms-private-subnet-b},{Key=Project,Value=USMS},{Key=Tier,Value=private},{Key=AZ,Value=b}]' \
  --query 'Subnet.SubnetId' --output text)

aws ec2 associate-route-table \
  --route-table-id "$USMS_PRIVATE_RT" \
  --subnet-id "$PRIVATE_SUBNET_B_ID" \
  --query 'AssociationId' --output text

# Apply usms-private-nacl (found the subnet's current default-NACL association ID, then replaced it)
aws ec2 replace-network-acl-association \
  --association-id <current association ID> \
  --network-acl-id acl-9a37129722ed42c1c \
  --query 'NewAssociationId' --output text

# Restore identity
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
```

### Result

- `usms-private-subnet-b` created as `subnet-932e73a5`, `10.0.4.0/24`, `us-east-1b`, while `get-caller-identity` confirmed `assumed-role/usms-developer-role/...`.
- Associated with `usms-private-rt` (`rtb-f4ae68f7`).
- `usms-private-nacl` (`acl-9a37129722ed42c1c`) confirmed applied — `describe-network-acls` shows both `subnet-c6c5db9b` (private A) and `subnet-932e73a5` (private B) associated with it.
- Identity restored to `root` afterward.
- `configs/lab-02.env` regenerated; `USMS_PRIVATE_SUBNET_B=subnet-932e73a5` now populated (previously `None`).
- `verify-lab-02.sh` re-run after the change: **PASS=30 FAIL=0**.

### Note on an error encountered

The first attempt at `assume-role` failed with `Invalid length for parameter RoleArn` because `$USMS_ROLE_DEVELOPER` (sourced from `configs/lab-01.env`) is stored as a full ARN, not a bare role name — building `arn:aws:iam::${ACCOUNT}:role/${USMS_ROLE_DEVELOPER}` on top of it produced a doubled, malformed ARN. Because the assume-role call failed, the exported credential variables were empty, and the AWS CLI silently fell back to the `floci` profile — so the subnet was briefly (and incorrectly) created under the normal `root` identity. This was caught, the incorrectly-created subnet was deleted, and the exercise was redone correctly using `$USMS_ROLE_DEVELOPER` directly as the role ARN.

![Exercise 5 — whoami before, then the failed assume-role attempt](screenshots/ex5_whoami_and_failed_assume_role.png)

![Exercise 5 — the subnet mistakenly created under root identity](screenshots/ex5_subnet_created_as_root_mistake.png)

![Exercise 5 — cleanup of the mistaken subnet, re-sourcing all env files](screenshots/ex5_cleanup_and_resource_envs.png)

![Exercise 5 — RoleArn fix and successful assume-role as usms-developer-role](screenshots/ex5_rolearn_fix_and_successful_assume_role.png)

![Exercise 5 — private-subnet-b created while assuming the role, NACL association list](screenshots/ex5_subnet_b_created_nacl_list.png)

![Exercise 5 — full NACL associations output confirming subnet-932e73a5](screenshots/ex5_full_nacl_associations_output.png)

![Exercise 5 — NACL association replaced, identity restored to root](screenshots/ex5_nacl_replace_and_identity_restored.png)

![Exercise 5 — regenerating configs/lab-02.env](screenshots/ex5_lab02_env_heredoc.png)

![Exercise 5 — configs/lab-02.env fully populated, no None values](screenshots/ex5_lab02_env_populated.png)

![Exercise 5 — verify-lab-02.sh re-run, PASS=30 FAIL=0](screenshots/ex5_verify_script_pass30.png)

**Status: Complete.** Committed (`configs/lab-02.env` update).

---

## Floci limitations observed across all exercises

1. `describe-security-group-rules` / `describe-security-groups` do not persist or read back `UserIdGroupPairs` (group-to-group security group references) — confirmed on `usms-db-sg` (main lab) and again on `usms-app-sg` (Exercise 2).
2. `revoke-security-group-ingress` returns `{"Return": true}` without actually removing the targeted rule — confirmed twice (on `usms-db-sg` in the main lab, and on `usms-app-sg` in Exercise 2).
3. `describe-network-acls --filters "Name=tag:Name,..."` returns the default NACL mislabeled with a placeholder ID (`acl-default`) instead of the correctly tagged NACL or an empty result.
4. `describe-tags` retains entries for resources that have already been deleted, rather than purging them — observed when an old, fully torn-down VPC's tags still appeared in a `Project=USMS` tag audit.
5. NACL associations for deleted subnets can remain visible in a NACL's `Associations` list rather than being cleaned up immediately.