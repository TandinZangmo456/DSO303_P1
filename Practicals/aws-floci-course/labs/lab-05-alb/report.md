# Lab 05 Report - Putting the ECS Service Behind an Application Load Balancer

**Course:** DSO303 · **Environment:** AWS CLI 2.32.7 against Floci (server 1.5.34, storage mode hybrid), account 000000000000, us-east-1
**Support path (Step 3):** **B - control plane only**

## 1. Objective

Put Lab 04's `usms-enrolment-svc` behind an internet-facing Application Load Balancer (`usms-enrolment-alb`) in Lab 02's two public subnets, with its own security group, a target group with a deliberate health check, a listener and one listener rule. Then attach the service, cut over the task security group so only the load balancer can reach the tasks, prove persistence across a restart, and save the ARNs for Lab 06.

## 2. What was built

| Resource | Value |
|---|---|
| Security group `usms-alb-sg` | `sg-67f11047b7ab80db0`, in tcp/80 and tcp/443 from 0.0.0.0/0 |
| Load balancer `usms-enrolment-alb` | `arn:...:loadbalancer/app/usms-enrolment-alb/35b54c8749d043bd`, internet-facing, application, us-east-1a + us-east-1b, state active |
| DNS name | `usms-enrolment-alb-35b54c8749d043bd.elb.floci` |
| Target group `usms-enrolment-tg` | `arn:...:targetgroup/usms-enrolment-tg/b7e6d71e05bd4136`, type ip, HTTP:80, GET / every 30 s, timeout 5, healthy 2, unhealthy 2, matcher 200 |
| Target group attributes | deregistration delay 30 s, least_outstanding_requests |
| Listener | HTTP:80, default action forward to `usms-enrolment-tg` |
| Rule | priority 10, path `/alb-health`, `/alb-health/*`, fixed-response 200 |
| Service attachment | `update-service --load-balancers ... --health-check-grace-period-seconds 60` (accepted; not retained by Floci) |
| Files | `policies/usms-alb-sg-ingress.json`, `policies/usms-alb-sg-ingress-https.json`, `policies/usms-enrolment-sg-ingress-alb.json`, `templates/lab-05-*.json` (4), `configs/lab-05.env`, `scripts/utilities/verify-lab-05.sh`, `scripts/cleanup/lab-05-cleanup.sh` |

## 3. Step-by-step evidence

### Prerequisites
Four tools are found, and the AWS CLI is v2.

![Prerequisites](screenshots/step00-prereqs.png)

### Step 1 - Resume the environment and load the env files
Floci is running under Compose with the bind mount verified, the account is 000000000000, and all twelve values are populated. Both public subnets are present.

![Step 1 - environment](screenshots/step01-environment.png)

### Step 2 - Confirm Labs 02, 03 and 04
Lab 02 reports FAIL=0. Lab 03 (FAIL=4) and Lab 04 (FAIL=2) show the same Floci-related failures already documented in their own notes, so nothing has regressed. Lab 04's output was saved to `outputs/lab-05-pre-verify-04.txt` as the "before" picture.

![Step 2 - earlier labs](screenshots/step02-verify-earlier.png)

### Step 3 - Probe ELBv2 support
Every probe answered. The public subnets are in two different AZs (10.0.1.0/24 in us-east-1a, 10.0.2.0/24 in us-east-1b).

![Step 3 - probe](screenshots/step03-probe.png)

### Step 4 - The load balancer's security group
There is one inbound rule, tcp/80 from 0.0.0.0/0, with FromGroup null and one outbound rule.

![Step 4 - usms-alb-sg](screenshots/step04-alb-sg.png)

**Your turn:** tcp/443 was added from a JSON document. The group now has 80 and 443 from 0.0.0.0/0.

![Step 4 - your turn 443](screenshots/step04-yourturn-443.png)

### Step 5 - The Application Load Balancer

![Step 5 - create](screenshots/step05-alb.png)

The waiter completed, and the state is `active`. There are two AZs in two zones, and the scheme is internet-facing with type application and SG usms-alb-sg.

![Step 5 - wait and verify](screenshots/step05-alb-wait-verify.png)

![Step 5 - attributes](screenshots/step05-alb-attributes.png)

### Step 6 - The target group
The target group is type ip with the full health check as specified. LBs is 0 and there are no targets yet.

![Step 6 - target group](screenshots/step06-target-group.png)

**Your turn:** the matcher was widened to 200-399, read back, and restored to 200 in place, with no recreation.

![Step 6 - your turn matcher](screenshots/step06-yourturn-matcher.png)

### Step 7 - Deregistration delay and algorithm
The deregistration delay is 30 s and the algorithm is least_outstanding_requests.

![Step 7 - attributes](screenshots/step07-tg-attributes.png)

### Step 8 - The listener
The first attempt failed inside Floci with an `InternalFailure`. The container log showed a Java `UnsupportedOperationException` in `ElbV2Service.createListener`:

![Step 8 - listener error](screenshots/step08-listener-error.png)

A clean Floci container from the same image created listeners normally, so the cause was stale in-memory state. A course-standard restart (`floci-down.sh` / `floci-up.sh`, state kept) cleared it. After the restart, the listener shows HTTP:80 forwarding to the target group, and AttachedToLoadBalancers is 1:

![Step 8 - listener](screenshots/step08-listener.png)

### Step 9 - Let the load balancer reach the tasks
The rule was created (`sgr-e5000c83f073fd7e2`). Floci does not return `UserIdGroupPairs`, so `Sources` reads `[]`. This is the same limitation recorded in Lab 04. The document in `policies/` holds the correct source group.

![Step 9 - SG rule](screenshots/step09-sg-alb-to-tasks.png)

### Step 10 - Attach the service to the target group
The template expanded correctly (0 `$`, containerName enrolment-api). `update-service` was accepted, but the `--query` failed on `length(deployments)` because Floci returns null:

![Step 10 - attach](screenshots/step10-attach-service.png)

The read-back confirms the known Floci issue: `loadBalancers`, the grace period and deployments are all `null`. The task definition is unchanged at `usms-enrolment:2`, and new tasks were started.

![Step 10 - readback](screenshots/step10-readback.png)

### Step 11 - Target registration and health
The target group stayed empty for all 12 polls:

![Step 11 - watch targets](screenshots/step11-watch-targets.png)

The service is at Desired 2 and Running 2, with no events. The tasks are RUNNING, but their ECS health and IP read `None`, and the target list is empty:

![Step 11 - service view](screenshots/step11-service-view.png)

**Your turn:** desired count went 3 then 2. The running count followed (3, then 2), and the target count stayed 0. I ran no register or deregister command.

![Step 11 - your turn](screenshots/step11-yourturn-desired3.png)

### Step 12 - Proving the path
Data path: the DNS name does not resolve and curl cannot connect. **No 200 was observed.**

![Step 12 - data path](screenshots/step12-data-path.png)

Control-plane proof (`outputs/lab-05-path-proof.txt`): blocks 1 and 2 show the listener forwarding to `usms-enrolment-tg`, type ip, HTTP:80 in usms-vpc. Blocks 3 to 5 are empty because of the Step 9 and 10 limitations.

![Step 12 - control plane proof](screenshots/step12-control-plane-proof.png)

### Step 13 - The cutover
`ReferencedGroupInfo` is not returned, so the lab's query finds `None`:

![Step 13 - find rule](screenshots/step13-find-rule.png)

I identified Lab 04's two rules as every tcp/80 ingress rule except Step 9's rule. The revoke returned `True`, but Floci still lists all three rules (limitation; left as is on instructor's advice):

![Step 13 - revoke](screenshots/step13-revoke.png)

verify-lab-04.sh is unchanged at PASS=36 FAIL=2 and the diff is empty, because nothing was actually removed:

![Step 13 - lab 04 diff](screenshots/step13-verify-lab04-diff.png)

### Step 14 - Forced deployment
The before state:

![Step 14 - pre](screenshots/step14-pre.png)

The polls show Desired 2, Running 2, deployments `None` and no targets:

![Step 14 - watch](screenshots/step14-watch.png)

The before and after records show the same task definition and counts. The task IDs are also identical, so Floci did not replace the tasks, and no draining could be observed.

![Step 14 - post](screenshots/step14-post.png)

### Step 15 - The listener rule
Priority 10 is a fixed-response 200 listed above the default forward. Floci returns `Values: []` for the path condition. Neither curl connected, so the `describe-rules` output is the evidence.

![Step 15 - rule](screenshots/step15-rule.png)

### Step 16 - Survive a restart

![Step 16 - before](screenshots/step16-pre.png)

Every ARN was re-derived from the API after `floci-down.sh` / `floci-up.sh`, and the result is **PERSISTENCE PROVEN**. The enrolment-SG source count errors identically before and after (no UserIdGroupPairs), so in practice six of the seven facts were compared.

![Step 16 - restart and diff](screenshots/step16-restart.png)

### Step 17 - Close the loop and audit
Block 1 shows the ALB admits 80 and 443 from the internet. Block 2 prints `MISMATCH ... None`, because Floci does not return the source group (a limitation, not a wrong rule). Block 3 prints **LOOP CLOSED**: usms-web-01 still carries usms-app-sg. Block 4 shows the Lab=05 tags on the SG, the ALB and the TG.

![Step 17 - audit](screenshots/step17-audit.png)

### Step 18 - configs/lab-05.env
There are 15 exports. Three are `None` (the service's LB container, port and grace period) because of the Step 10 issue. The lab's `\`` escaping in the listener line produced an invalid JMESPath under bash 5, so I used plain backticks.

![Step 18 - env file](screenshots/step18-env.png)

### Step 19 - Commit
`outputs/` is ignored by `.gitignore:7:outputs/*`, only `outputs/.gitkeep` is tracked, and Lab 05 files were staged by explicit path.

![Step 19 - commit](screenshots/step19-commit.png)

### Section 8 - Verification and cleanup scripts
`verify-lab-05.sh` reports **PASS=40 FAIL=9**:

![Section 8.1 - verify-lab-05.sh](screenshots/sec8-verify.png)

| Failing check | Cause |
|---|---|
| usms-enrolment-sg admits tcp/80 from usms-alb-sg | Floci does not return UserIdGroupPairs (Step 9) |
| service has exactly ONE loadBalancers entry, names the TG, containerName, containerPort, grace period (5 checks) | Floci known issue: loadBalancers and grace period not retained (Step 10) |
| exactly ONE deployment | Floci returns `deployments: null` |
| configs/lab-05.env has no empty values | The three `None` values come from the same Step 10 issue |
| no secret is tracked by git | Matches the tracked `outputs/.gitkeep` only; no secret is tracked (same as Lab 04) |

The cleanup script was written and syntax-checked and **was not run**:

![Section 8.2 - cleanup syntax](screenshots/sec8-cleanup-syntax.png)

## 4. Observed vs reasoned about

| Observed on this build | Reasoned about only (real AWS behaviour) |
|---|---|
| ALB, SG, TG, listener and rule created, read back and tagged | ALB nodes and a resolving DNS name |
| ALB in two AZs, state active | Health checks actually executed; healthy/unhealthy states |
| TG attached to 1 load balancer | The service registering and deregistering targets |
| Rule priority 10 above the default | Rule evaluation on a real request; fixed-response body |
| Matcher changed and restored in place | Draining during a deployment (deregistration delay 30 s) |
| Persistence across a Floci restart | The security-group cutover actually blocking usms-app-sg |
| Desired count 3 to 2 followed by the service | A served HTTP 200 through the listener |

## 5. Floci limitations met

1. `create-listener` crashed (`UnsupportedOperationException`) until Floci was restarted.
2. Group-referenced SG rules are stored without their source group (`UserIdGroupPairs`, `ReferencedGroupInfo`).
3. `revoke-security-group-ingress` returns `True` but leaves the rules in place.
4. `update-service --load-balancers` / `--health-check-grace-period-seconds` is accepted but not retained (documented known issue).
5. No target registration, no health states, no service events, and `--force-new-deployment` replaces nothing.
6. No data path: the `*.elb.floci` name does not resolve, and curl returns 000.
7. The path-pattern `Values` are returned empty by `describe-rules`.

Details and the effect on each step are in `notes/lab-05-notes.md`.

## 6. Answers

The "Your turn" answers and all seven review questions are in `notes/lab-05-notes.md`.

## 7. Conclusion

The full load-balancer control plane (security group, ALB in two AZs, target group with a deliberate health check and 30 s deregistration delay, listener, priority-10 rule) was built, verified and shown to persist across a restart. The ECS integration, target health, data path and security-group cutover could not be observed on this Floci build. Each is recorded above with what real AWS would have done, and the lab was completed on support path B.
