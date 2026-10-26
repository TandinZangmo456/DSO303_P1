Support path: B (control plane only). ELBv2 objects are created, described and persisted, but the ECS service does not retain its loadBalancers entry, no target is ever registered, and the load balancer's DNS name does not resolve, so no request was served.

Floci build: server 1.5.34 (floci-always-free), CLI 0.2.0, storage mode hybrid.

# Floci limitations recorded in this lab

- Step 8: `create-listener` first failed with `InternalFailure ... Unexpected error: null`. The Floci log showed `java.lang.UnsupportedOperationException` at `ElbV2Service.createListener(ElbV2Service.java:487)`. It failed for every variant (tags or none, forward or fixed-response, ALB or NLB, with or without a security group). A clean Floci container from the same image created listeners fine, so this was stale in-memory state in my container. A `floci-down.sh` / `floci-up.sh` restart (state kept) cleared it, and the same command then succeeded. Real AWS would have returned the listener ARN first time.
- Step 9 and 13: Floci accepts group-referenced ingress rules but never returns `UserIdGroupPairs` or `ReferencedGroupInfo` (same as Lab 04 Step 8). `describe-security-groups` shows port 80 with `Sources: []`. The input document `policies/usms-enrolment-sg-ingress-alb.json` holds the correct source group (`sg-67f11047b7ab80db0`, usms-alb-sg) as the evidence.
- Step 13: because `ReferencedGroupInfo` is missing, the lab's `OLD_RULE_ID` query returns `None`. I identified Lab 04's two port-80 rules as every tcp/80 ingress rule except the one Step 9 created (`sgr-e5000c83f073fd7e2`). `revoke-security-group-ingress` returned `True` for `sgr-e862db1a6adb2ec56` and `sgr-3ad2f8f30757a84f7`, and also for the Lab 04 document, but `describe-security-group-rules` still lists all three rules. Floci acknowledges the revoke and does not apply it. On real AWS only the usms-alb-sg rule would remain. Per my instructor, this limitation is left as is.
- Step 10: `update-service --load-balancers ... --health-check-grace-period-seconds 60` is accepted and starts new tasks, but `describe-services` returns `loadBalancers: null`, `healthCheckGracePeriodSeconds: null` and `deployments: null`. This is the documented Floci known issue for Lab 05. The `length(deployments)` in the lab's `--query` fails for the same reason.
- Step 11: the target group stays empty (`[]`) through all 12 polls and through the desired-count 3 to 2 change. Tasks are RUNNING with `healthStatus` and private IP both `None`, and there are no service events.
- Step 12: the DNS name `usms-enrolment-alb-35b54c8749d043bd.elb.floci` does not resolve and curl returns `http_code=000`. The proof I have is the control-plane chain in `outputs/lab-05-path-proof.txt`. Blocks 1 and 2 are populated, while blocks 3 to 5 are empty for the reasons above. I did not observe a 200.
- Step 14: `--force-new-deployment` is accepted but no tasks were replaced. The pre- and post-deploy task IDs are identical, and no initial, healthy or draining state was seen.
- Step 15: the rule is created at priority 10 with a fixed-response 200 and sorts above the default. `Conditions[0].Values` comes back `[]` even though the path patterns were sent in `PathPatternConfig`.
- Step 16: six of the seven facts were compared and were identical across the restart (PERSISTENCE PROVEN). The seventh, the enrolment SG source count, errors with `length(null)` both before and after, because of the UserIdGroupPairs gap.
- Step 17: `CUTOVER CONFIRMED` was not printed. The script printed `MISMATCH ... found None` because the source group is not returned. `LOOP CLOSED` was printed.
- Step 18: there are 15 exports. Three values are `None` (USMS_SVC_LB_CONTAINER, USMS_SVC_LB_PORT, USMS_SVC_GRACE_PERIOD) because of the Step 10 issue. The lab's `\`` escaping in the listener line left the backslashes inside `$()` in the heredoc (bash 5), so I used plain backticks inside the single-quoted query.
- verify-lab-05.sh: PASS=40 FAIL=9. Eight failures are the Floci gaps above: SG source (1), service wiring (6) and env None values (1). The ninth, "no secret is tracked by git", fails only because `outputs/.gitkeep` is tracked, as in Lab 04. The "cutover done" check passes only because no sources are returned at all.
- verify-lab-04.sh stayed at PASS=36 FAIL=2 before and after Step 13 (empty diff), because the revoke did not take effect and the source check was already failing on Floci.

Observed versus reasoned about: I observed every object being created and read back, the 0 to 1 attachment count, the rule ordering, the restart proof and the tags. I reasoned about, and did not observe, target registration, health states, draining, the served request, rule evaluation, HTTPS and the security-group cutover.

# Your turn answers

Step 4 (HTTPS): The 443 rule only opens the port. Two more things are needed: an HTTPS listener on port 443 and a TLS certificate attached to it. AWS gives you the listener and a public ACM certificate for free. What you have to obtain from somewhere else is a domain name you control, so ACM can validate the certificate through a DNS record.

Step 6 (matcher): (a) Any application whose `/` redirects, for example a portal that answers `/` with a 302 to `/login`, would be unhealthy forever under a strict 200 matcher. (b) It would be a failure of my work, not the script. A verification script records the configuration we decided on (200), so a different value is drift from the agreed design until the design and the script are changed together.

Step 11 (desired count): Without the service registering its own targets, I would have to run `register-targets` for every new task IP and `deregister-targets` for every stopped one after each scaling event.

Step 11 part 3 - the two health opinions:

| ECS healthStatus | Target health | Diagnosis |
|---|---|---|
| HEALTHY | healthy | Working |
| HEALTHY | unhealthy | The network path is broken: security group, subnet, or health check path returning the wrong code |
| UNHEALTHY | unhealthy | The application is broken; read the container logs |
| UNKNOWN | healthy | Not a fault; the task definition has no container health check |
| anything | unused | Nothing forwards to this target group |

On this build the tasks show `None` and the target list is empty, so no row could be observed.

# Review Questions

## 1. Group references and load balancers
Both replace an address with a stable name, because the thing behind it is short-lived. A security group reference says "whatever carries usms-app-sg", and a load balancer says "whatever is registered in usms-enrolment-tg". Clients and rules point at the name, and the membership behind it changes freely. The general problem is indirection over a changing set of endpoints, or service discovery. A third solution elsewhere in computing is DNS itself, or a service registry such as Consul or Kubernetes Services, where callers use a name and a controller keeps the list of endpoints current.

## 2. "Unhealthy means the application is broken"
That is unsound, because the target group health check runs from the load balancer over the network. An unhealthy result can mean the application is broken or that the probe never reached it (security group, NACL, wrong port or path). The target state alone cannot tell "application down" from "network path blocked". `TargetHealth.Reason` and `Description` (for example `Target.Timeout` against `Target.ResponseCodeMismatch`) can, together with the task's ECS `healthStatus` from the container health check. The sequence I would follow: compare the ECS health with the target health, read the Reason, check the task SG admits usms-alb-sg on the target port, then check the health check path and matcher against what the app returns, and only then read the container logs.

## 3. No update-target-group-target-type
Some fields are the target group's identity, not tunable configuration. Changing them would make a different object, so you create a new target group and switch to it, as Lab 04 registers a new task definition revision instead of editing one. Two other fields that behave the same way here are the load balancer's `--scheme` and `--type`, and the target group's `--vpc-id` is a third. One that looks like it should be fixed but is not is the health check (path, interval, matcher), which `modify-target-group` changes in place, as Step 6's "Your turn" showed.

## 4. A request at the moment ECS stops the task
The timers are `deregistration_delay.timeout_seconds` (30s, target group, Step 7), the container's `stopTimeout` (task definition, Lab 04), and the health check interval and thresholds plus `healthCheckGracePeriodSeconds` for the replacement task. ECS deregisters the target first, so the load balancer stops sending new requests and lets in-flight ones finish within 30 seconds. Only after that does ECS send SIGTERM, wait for stopTimeout, then SIGKILL. A request already in flight succeeds. A request arriving just after deregistration goes to another healthy target. At 300 seconds every deployment and scale-in would wait up to five minutes per task before stopping it, making rollouts very slow without making a millisecond API any safer.

## 5. Update the Lab 04 script, or leave it failing?
For updating it now: the check encodes a property ("tasks accept traffic only from a named group"), the architecture changed on purpose, and the fix belongs in the same change so the suite stays a trustworthy green. For leaving it failing and documented: the Lab 04 script records what Lab 04 built, and rewriting it hides the history and risks making a script green by weakening it. With four other engineers I would update it in the same commit as the cutover, with a message explaining why, because a known red check trains people to ignore red. A single engineer working alone might reasonably leave it documented for now, since the knowledge sits in one head.

## 6. Internet-facing load balancer, private tasks
The ALB's nodes live in usms-public-subnet-a and -b, whose route table usms-public-rt sends 0.0.0.0/0 to usms-igw, so they have public addresses. The tasks live in usms-private-subnet-a and -b, whose usms-private-rt only has a default route to usms-nat (outbound only) and the S3 endpoint, and they have assignPublicIp DISABLED. The ALB terminates the connection and opens a new one to the task inside usms-vpc. Someone who controlled the load balancer's configuration could reach anything the ALB can route to: any target group, any IP target in the VPC that usms-alb-sg is admitted by, and fixed responses or redirects. If the tasks had public addresses, they could be reached directly from the internet, bypassing the listener, the rules and any future TLS or WAF, and only their SG would stand in the way.

## 7. Requests per target versus CPU
Requests per target measures the load the API is designed for. It is directly tied to user demand, reacts before CPU saturates, and is linear in the number of tasks, so target tracking can calculate the right count. CPU is better when the work per request varies a lot or is CPU-bound in the background, for example report generation or batch jobs that are not driven by request count. ALBRequestCountPerTarget would scale the enrolment app badly if its requests had very uneven cost, such as a few heavy enrolment transactions mixed with many cheap health calls, or if the bottleneck were downstream (the database) so adding tasks would not help.
