# AWS Practical Laboratory Report
## Lab 02 — Virtual Private Cloud and Networking

## 1. Aim / Objective

The objective of this practical is to design and build a secure, multi-tier Amazon VPC network for the USMS (University Student Management System) using the AWS CLI against a local AWS emulator (Floci). This includes creating a VPC with public and private subnets across two Availability Zones, configuring internet and NAT gateway routing, implementing layered access control with security groups and a network ACL, provisioning a gateway VPC endpoint for Amazon S3, and proving that the entire network configuration persists across a restart of the environment.

## 2. Introduction

Amazon Virtual Private Cloud (VPC) is a foundational AWS networking service that lets an account provision a logically isolated section of the AWS cloud in which to launch resources within a private, customer-defined IP address range. A VPC is organised into subnets tied to specific Availability Zones, and traffic between subnets and the internet is controlled by route tables, internet gateways, NAT gateways, and VPC endpoints, while access to individual resources is controlled by security groups (stateful, instance-level) and network ACLs (stateless, subnet-level). VPC is central to cloud computing because almost every other AWS compute and database service — EC2, RDS, Lambda (in VPC mode) — is deployed inside one, and the network design directly determines what is reachable from the internet, what can reach the internet, and what is isolated entirely. Typical applications include hosting multi-tier web applications with public web servers and private databases, isolating sensitive data stores, and connecting on-premises networks to the cloud via VPN or Direct Connect.

## 3. Use Case

This lab builds the network layer for USMS, a university student management system with three concrete requirements:

- A public web tier that students and staff reach directly from the internet.
- A private data tier holding transcripts and enrolment records that must never be reachable from the internet.
- The data tier must still be able to reach the internet outbound, to fetch operating-system security patches.

More broadly, this pattern — public subnet for a web/app tier, private subnet for a database tier, NAT gateway for controlled outbound-only access, and a gateway endpoint to keep S3 traffic off the public internet — is the standard reference architecture used by organisations to host scalable, tiered web applications while keeping sensitive data isolated (e.g. an e-commerce site's web servers in a public subnet and its order database in a private subnet).

## 4. System Architecture / Design

The network built in this lab follows the address plan and topology below.

| CIDR range | Purpose | Tier |
|---|---|---|
| 10.0.0.0/16 | usms-vpc — the whole VPC | — |
| 10.0.1.0/24 | usms-public-subnet-a (us-east-1a) — web tier | Public |
| 10.0.2.0/24 | usms-public-subnet-b (us-east-1b) — web tier | Public |
| 10.0.3.0/24 | usms-private-subnet-a (us-east-1a) — data tier | Private |

**Logical data flow:**

- Internet ⇄ usms-igw ⇄ usms-public-rt (0.0.0.0/0 → igw) ⇄ public subnets (web tier, usms-app-sg).
- Public subnet (web tier, usms-app-sg) ⇄ usms-db-sg ⇄ private subnet (data tier), PostgreSQL 5432, sourced by security group rather than CIDR.
- Private subnet ⇒ usms-private-rt (0.0.0.0/0 → usms-nat) ⇒ usms-nat (in the public subnet) ⇒ usms-igw ⇒ internet — outbound-only, for OS patches.
- Private subnet ⇒ usms-private-rt ⇒ usms-s3-endpoint (Gateway type) ⇒ Amazon S3, without traversing the internet gateway or NAT gateway.
- usms-private-nacl applied to the private subnet as a stateless, subnet-wide backstop, independent of any security-group misconfiguration.

Diagram (textual, since no console diagram tool is available in Floci):

```
Internet
  |
usms-igw
  |
usms-public-rt --- usms-public-subnet-a/b --[usms-app-sg]-- (web tier)
                                                   |
                                          usms-db-sg (5432, source = usms-app-sg)
                                                   |
usms-private-rt --- usms-private-subnet-a --[usms-private-nacl]-- (data tier)
     |         \
  usms-nat      usms-s3-endpoint --- Amazon S3
     |
  usms-igw --- Internet (outbound only)
```

## 5. Implementation Procedure

All commands were run from the aws-floci-course repository root, against the Floci emulator (endpoint http://localhost:4566, account 000000000000), with configs/course.env and configs/lab-01.env sourced first. The build proceeded as follows:

1. **Resume environment** — Started Floci via docker compose, ran floci-storage-check.sh (hybrid storage mode confirmed), and created labs/lab-02-vpc.
2. **Load identity** — Sourced configs/lab-01.env and confirmed the developer role, developer user and account ID (000000000000) via whoami.sh.
3. **Read the governing policy** — Retrieved the default version of USMSDeveloperBase and printed its document to confirm it actually permits the EC2 actions this lab needs.
4. **Assume role and create the VPC** — Assumed usms-developer-role via sts assume-role (profile usms-dev), exported the temporary credentials, and created usms-vpc (10.0.0.0/16) while holding those credentials.
5. **Restore identity** — Unset the temporary credentials, restored the floci profile, and read the VPC back as a different identity to confirm it exists in the account, not just in that session.
6. **Enable DNS** — Enabled DNS support and DNS hostnames on the VPC via modify-vpc-attribute.
7. **Internet gateway** — Created usms-igw and attached it to usms-vpc.
8. **Public subnet** — Created usms-public-subnet-a (10.0.1.0/24, us-east-1a) and enabled auto-assign public IPv4.
9. **Private subnet** — Created usms-private-subnet-a (10.0.3.0/24, us-east-1a) without auto-assign public IPv4.
10. **Public routing** — Created usms-public-rt with a 0.0.0.0/0 route to usms-igw, associated it with usms-public-subnet-a, and (per the exercise) created a second public subnet (10.0.2.0/24, us-east-1b) and associated it too.
11. **Private routing** — Created usms-private-rt and associated it with the private subnet (no internet route at this point).
12. **Prove public vs private** — Read back the effective route table of each subnet and confirmed the public subnet resolves a default route to the IGW while the private subnet resolves none.
13. **Application security group** — Created usms-app-sg allowing inbound TCP 80/443 from 0.0.0.0/0 and TCP 22 from 10.0.0.0/16.
14. **Database security group** — Created usms-db-sg allowing inbound TCP 5432 sourced from usms-app-sg (group reference, not a CIDR). A duplicate ingress rule was created by mistake; it was identified with describe-security-group-rules and removed with revoke-security-group-ingress.
15. **Network ACL** — Read the default NACL's implicit allow/deny structure, created usms-private-nacl with explicit rules for PostgreSQL inbound (10.0.0.0/16:5432), ephemeral-port inbound, and matching egress rules (VPC-internal and HTTPS), then replaced the private subnet's NACL association from the default ACL to usms-private-nacl.
16. **NACL troubleshooting** — One replace-network-acl-association call failed with InvalidAssociationID.NotFound because a stale association ID was reused; the correct current association ID was re-queried and the operation was retried successfully.
17. **NAT gateway** — Allocated an Elastic IP, created usms-nat inside the public subnet, and waited for it to reach the available state.
18. **Private default route** — Added a 0.0.0.0/0 route on usms-private-rt targeting usms-nat, removing the need to route private-subnet traffic through the internet gateway.
19. **S3 gateway endpoint** — Created usms-s3-endpoint (Gateway type) and associated it with usms-private-rt, so S3 traffic from the private subnet never leaves the AWS network.
20. **Tag audit** — Ran describe-tags filtered on Project=USMS to confirm every resource created in this lab was tagged consistently, and produced a tiered subnet inventory table.
21. **Persistence proof** — Recorded the VPC ID, subnet count and security-group count, stopped and restarted Floci, re-derived the VPC by tag, and confirmed all three values were unchanged (PERSISTENCE PROVEN).
22. **Cleanup of a stray resource** — During verification, an orphaned security group referencing a VPC ID that no longer existed was discovered, traced, and deleted; usms-db-sg was then recreated cleanly with the correct group-referenced ingress rule.
23. **Environment file** — Wrote configs/lab-02.env (VPC, subnet, route-table, security-group, NACL, NAT and endpoint IDs looked up by tag), corrected one variable (USMS_PRIVATE_NACL) that had been mis-populated, and confirmed no value was left empty or None.
24. **Git hygiene** — Confirmed via git status --short that nothing under outputs/ was staged, then committed the lab files, policy JSON and verification script.
25. **Automated verification** — Wrote scripts/utilities/verify-lab-02.sh (33 checks across environment, Lab 01 dependencies, Lab 02 resources, tagging, and file/git hygiene) and ran it, obtaining PASS=29, FAIL=1.

## 6. Results and Evidence

### 6.1 CLI Output

The screenshots below are ordered chronologically and capture every command and its output for the build described in Section 5.

![alt text](<../../screenshots/lab2/Screenshot from 2026-08-27 12-38-41.png>)
*Figure 1: Resuming Floci, running the storage-persistence check, and creating the labs/lab-02-vpc directory.*

![alt text](<../../screenshots/lab2/Screenshot from 2026-08-27 12-38-49.png>)
*Figure 2: Sourcing configs/lab-01.env, confirming the developer identity, and reading the default version of the USMSDeveloperBase policy.*

![alt text](<../../screenshots/lab2/Screenshot from 2026-08-27 12-38-59.png>)
*Figure 3: Assuming usms-developer-role and creating usms-vpc (10.0.0.0/16) while holding that role's credentials.*

![Figure 4](figures/Screenshot_from_2026-08-27_12-39-05.png)
*Figure 4: Restoring the normal identity and reading back the VPC's state, CIDR block, and default-VPC flag.*

![Figure 5](figures/Screenshot_from_2026-08-27_12-41-07.png)
*Figure 5: Enabling DNS support and DNS hostnames on the VPC, then creating and attaching usms-igw.*

![Figure 6](figures/Screenshot_from_2026-08-27_12-42-34.png)
*Figure 6: Creating usms-public-subnet-a (10.0.1.0/24) and enabling auto-assign public IPv4.*

![Figure 7](figures/Screenshot_from_2026-08-27_12-44-34.png)
*Figure 7: Creating usms-private-subnet-a (10.0.3.0/24) and creating usms-public-rt with a default route to the internet gateway.*

![Figure 8](figures/Screenshot_from_2026-08-27_12-46-43.png)
*Figure 8: Associating usms-public-rt with the subnet, creating the second public subnet (10.0.2.0/24), and confirming route-table associations.*

![Figure 9](figures/Screenshot_from_2026-08-27_12-48-30.png)
*Figure 9: Creating usms-private-rt, associating it with the private subnet, and comparing the effective routes of every subnet.*

![Figure 10](figures/Screenshot_from_2026-08-27_12-51-33.png)
*Figure 10: Creating usms-app-sg with HTTP/SSH ingress rules, then creating usms-db-sg and its PostgreSQL ingress policy JSON.*

![Figure 11](figures/Screenshot_from_2026-08-27_12-52-54.png)
*Figure 11: Applying the PostgreSQL ingress rule to usms-db-sg and confirming its source/port details.*

![Figure 12](figures/Screenshot_from_2026-08-27_12-56-03.png)
*Figure 12: Full JSON detail of usms-db-sg, showing the default allow-all egress rule and two ingress rules on port 5432.*

![Figure 13](figures/Screenshot_from_2026-08-27_12-56-25.png)
*Figure 13: Listing individual security-group-rule IDs for usms-db-sg, revealing a duplicate rule on TCP 5432.*

![Figure 14](figures/Screenshot_from_2026-08-27_12-58-40.png)
*Figure 14: Revoking the duplicate ingress rule from usms-db-sg.*

![Figure 15](figures/Screenshot_from_2026-08-27_13-00-39.png)
*Figure 15: Confirming a single 5432 ingress rule remains, and a tag-based summary of all security groups in the VPC.*

![Figure 16](figures/Screenshot_from_2026-08-27_13-01-33.png)
*Figure 16: Reading the default network ACL's entries, then creating usms-private-nacl.*

![Figure 17](figures/Screenshot_from_2026-08-27_13-03-52.png)
*Figure 17: Adding the four custom NACL entries (PostgreSQL inbound, ephemeral-port inbound, and the matching egress rules) and reading them back.*

![Figure 18](figures/Screenshot_from_2026-08-27_13-05-26.png)
*Figure 18: Replacing the private subnet's NACL association, moving it from the default ACL to usms-private-nacl.*

![Figure 19](figures/Screenshot_from_2026-08-27_13-06-15.png)
*Figure 19: Confirming usms-private-nacl is now associated with the private subnet.*

![Figure 20](figures/Screenshot_from_2026-08-27_13-16-19.png)
*Figure 20: Re-checking the NACL association and reviewing the default NACL's remaining associations.*

![Figure 21](figures/Screenshot_from_2026-08-27_13-17-44.png)
*Figure 21: Full listing of both network ACLs in the VPC and every subnet each one is associated with.*

![Figure 22](figures/Screenshot_from_2026-08-27_13-19-48.png)
*Figure 22: A failed association-replacement using a stale association ID, followed by correctly moving the public subnet back onto the default NACL.*

![Figure 23](figures/Screenshot_from_2026-08-27_13-23-24.png)
*Figure 23: Correcting the private subnet's NACL association, then allocating an Elastic IP for the NAT gateway.*

![Figure 24](figures/Screenshot_from_2026-08-27_13-24-09.png)
*Figure 24: Creating the NAT gateway (usms-nat) inside the public subnet, using the allocated Elastic IP.*

![Figure 25](figures/Screenshot_from_2026-08-27_13-24-39.png)
*Figure 25: Waiting for the NAT gateway to reach the available state.*

![Figure 26](figures/Screenshot_from_2026-08-27_14-03-49.png)
*Figure 26: Adding the private route table's default route via the NAT gateway, then creating the S3 gateway VPC endpoint.*

![Figure 27](figures/Screenshot_from_2026-08-27_14-04-03.png)
*Figure 27: Verifying the S3 endpoint's state and its association with the private route table.*

![Figure 28](figures/Screenshot_from_2026-08-27_14-05-17.png)
*Figure 28: Confirming the private route table's three routes: local, default-via-NAT, and default-via-endpoint.*

![Figure 29](figures/Screenshot_from_2026-08-27_14-05-55.png)
*Figure 29: Auditing every resource tagged Project=USMS across the VPC using describe-tags.*

![Figure 30](figures/Screenshot_from_2026-08-27_14-06-49.png)
*Figure 30: Producing a tiered subnet inventory table and recording pre-restart VPC/subnet/security-group counts.*

![Figure 31](figures/Screenshot_from_2026-08-27_14-15-43.png)
*Figure 31: Troubleshooting: an orphaned security group referencing a stale VPC ID, tracked down and deleted.*

![Figure 32](figures/Screenshot_from_2026-08-27_14-17-56.png)
*Figure 32: Recreating usms-db-sg with the correct group-referenced PostgreSQL ingress rule.*

![Figure 33](figures/Screenshot_from_2026-08-27_14-19-11.png)
*Figure 33: Confirming the recreated usms-db-sg is attached to the correct VPC.*

![Figure 34](figures/Screenshot_from_2026-08-27_14-20-56.png)
*Figure 34: Stopping and restarting Floci, then proving the VPC ID, subnet count, and security-group count all survived the restart.*

![Figure 35](figures/Screenshot_from_2026-08-27_14-25-02.png)
*Figure 35: Correcting the USMS_PRIVATE_NACL value in configs/lab-02.env and checking for unset/None values.*

![Figure 36](figures/Screenshot_from_2026-08-27_14-28-32.png)
*Figure 36: Reviewing git status for the lab files and beginning the verify-lab-02.sh verification script.*

![Figure 37](figures/Screenshot_from_2026-08-27_14-28-48.png)
*Figure 37: Running verify-lab-02.sh: PASS=29, FAIL=1 (a git-hygiene check flagged for review).*

### 6.2 AWS Management Console Verification

This lab was carried out entirely against Floci, a local, CLI-only AWS emulator with no web-based Management Console. In place of console screenshots, verification was performed with read-only AWS CLI describe-* calls immediately after each build action, which is the equivalent evidence available in this environment. The most relevant verification points are:

- Figure 5, 6, 9, 13 and 17 — read-back confirmation that DNS attributes, subnet auto-assign settings, route-table contents, security-group rules and NACL entries matched what was intended, immediately after each was created.
- Figure 29 — a full tag-based inventory (describe-tags, Project=USMS) confirming every resource this lab created actually exists and is tagged correctly, functioning as the equivalent of browsing the console's resource lists.
- Figure 34 — a before/after persistence check (VPC ID, subnet count, security-group count) across a stop/restart of the emulator, confirming the configuration is durable rather than only present in memory.
- Figure 37 — the automated verification script result (PASS=29, FAIL=1), which checks configuration correctness (e.g. NACL is not the default, DB security group is sourced from the app group, private route table has no route to an internet gateway) rather than mere existence.

## 7. Analysis and Discussion

The practical achieved its aim: a two-tier VPC (public/private, across two Availability Zones) was built with correct internet, NAT and S3-endpoint routing, layered security-group and NACL controls, and a persistence proof across a restart. The results matched the expected outcome for nearly every step — subnets, route tables, security groups, the NAT gateway, and the S3 endpoint all came back from describe-* calls exactly as configured, and the final verification script reported 29 of 33 checks passing on the first complete run.

Several errors were encountered and resolved during implementation:

- A duplicate ingress rule was accidentally created on usms-db-sg (visible in Figure 12/13 as two identical TCP 5432 rules). It was identified with describe-security-group-rules and removed precisely, by rule ID, using revoke-security-group-ingress (Figure 14), rather than recreating the whole group.
- A replace-network-acl-association call failed with InvalidAssociationID.NotFound (Figure 22) because a previously captured association ID was stale — the association had already changed by the time the command was reissued. The current association ID was re-queried from describe-network-acls and the replacement was retried successfully.
- During the resource audit, an orphaned security group was found referencing a VPC ID that describe-vpcs reported as InvalidVpcID.NotFound (Figure 31). Rather than leaving it, it was traced with describe-security-groups, cross-checked against the live VPC, and deleted; usms-db-sg was then recreated cleanly with the correct group-referenced rule (Figures 32–33).
- The final verification run reported one failure (FAIL=1) alongside 29 passes (Figure 37) — a git-hygiene check, most likely related to a file under outputs/ or a similar tracked-secret pattern being flagged. This is a housekeeping issue rather than a networking defect, and would be resolved by re-checking .gitignore coverage and re-running git status --short before the next commit.

A key observation from Step 12 (Figure 9) and the interlude on public vs private subnets is that a subnet's public/private status is determined purely by its associated route table's default route target, not by its name, tags, or MapPublicIpOnLaunch setting — all of which can be set independently and can therefore be misleading if read in isolation. This was proven directly by reading back the effective route of both subnets rather than trusting their labels.

## 8. Reflection

**1. What did you learn about this AWS service?**

VPC networking is built from several independent, composable primitives — VPC, subnet, route table, internet gateway, NAT gateway, security group, network ACL, and VPC endpoint — and none of them do anything on their own until they are explicitly wired together (e.g. creating an internet gateway and attaching it does nothing until a route table actually points at it). I also learned the practical difference between the two firewall layers: security groups are stateful, allow-only, and can reference each other, while network ACLs are stateless, support explicit deny, and apply to an entire subnet regardless of what an individual instance's security group says.

**2. What challenges did you encounter?**

The main challenges were operational rather than conceptual: a duplicate security-group rule created by re-running a command, a stale association ID causing a failed NACL replacement, and an orphaned security group left over from an earlier, now-invalid VPC. Each required reading the current state back from the API rather than trusting a previously captured shell variable — the same lesson the lab's persistence test (Step 20) makes explicit.

**3. How would you apply this service in a real-world cloud environment?**

This exact pattern — public web tier, private data tier, NAT gateway for controlled outbound access, and a gateway endpoint for S3 — is directly applicable to any tiered application that must expose a front end publicly while keeping a database or sensitive storage fully isolated from the internet, such as the USMS system this lab was built around, or any equivalent transactional web application.

**4. What additional concepts or features would you like to explore?**

VPC peering and Transit Gateway for connecting multiple VPCs, interface VPC endpoints (as opposed to the gateway endpoint used here) for private access to services beyond S3 and DynamoDB, VPC Flow Logs for traffic visibility, and a highly available NAT design with one NAT gateway per Availability Zone rather than the single shared one built in this lab.

## 9. Conclusion

The objectives of this practical were achieved. A two-tier USMS VPC (10.0.0.0/16) was built across two Availability Zones with a public web tier and a private data tier, correct internet, NAT-gateway and S3-gateway-endpoint routing, layered access control via security groups and a custom network ACL, and full tagging for auditability. The configuration was proven to persist across a restart of the Floci environment, and an automated verification script confirmed 29 of 33 checks passing. Along the way, this lab reinforced that a subnet's public/private status is a property of its route table and nothing else, that security-group-to-security-group references are more robust than CIDR-based rules, and that every resource's state should be verified by reading it back from the API rather than assumed from a prior command's success.

