# Lab 06 Notes - Implementing Auto Scaling for an ECS-Based Application

**Support path: C** (no Application Auto Scaling on this Floci build)

- Floci image: `floci/floci:latest`, storage mode hybrid, bind-mounted to `~/floci-data`
- `iam create-service-linked-role`: `UnsupportedOperation`
- `register-scalable-target` / `describe-scalable-targets`: `UnknownOperationException`
- The resource ID still derives correctly from the service ARN: `service/usms-ecs-cluster/usms-enrolment-svc`

Per Step 3, path C does Exercises 4 and 5 and Section 14. I also did every part of the main steps that does not need Application Auto Scaling: the CloudWatch metric and alarm, the templates, the restart test, the env file, and the verify and cleanup scripts.

## Pre-checks and fixes before starting

| Item | What I found | What I did |
|---|---|---|
| `cd ~/aws-floci-course` | The repo lives in `~/Desktop/SEM7/DSO303/Practicals/aws-floci-course` | Ran everything from there |
| verify-lab-02 | PASS=30 FAIL=0 | Nothing to do |
| verify-lab-03 | FAIL=4: usms-web-01 user data, data volume attached, DeleteOnTermination, usms-db-01 no public address | Left as known leftovers. Lab 06 does not use the EC2 instances |
| "no secret is tracked by git" (Labs 03, 04, 05) | The check is `! git ls-files \| grep -q '^outputs/'`, and files under outputs/ had been committed | `git rm -r --cached outputs/`, then committed |
| verify-lab-04 | After the git fix: PASS=37 FAIL=1, the one documented usms-app-sg failure | Allowed |
| usms-enrolment-sg | No inbound rules at all (`[]`) | Re-added tcp/80 from usms-alb-sg with `policies/usms-enrolment-sg-ingress-alb.json` |
| Service load balancer wiring | `loadBalancers` and `healthCheckGracePeriodSeconds` both null | Re-ran `update-service --load-balancers ... --health-check-grace-period-seconds 60`. Floci accepted it but still returns null: **Floci limitation** |
| `deployments` | Floci returns null, so Step 2's `length(deployments)` query errors | Used a query without `length()`. **Floci limitation** |
| configs/lab-05.env | `USMS_SVC_GRACE_PERIOD`, `USMS_SVC_LB_CONTAINER`, `USMS_SVC_LB_PORT` were `None` | Set to 60, enrolment-api and 80, then committed |
| Service baseline | Desired 2, Running 2 | Nothing to do |

## Step by step results

| Step | Result on path C |
|---|---|
| 1 Load env files | Done, all values present after the lab-05.env fix |
| 2 Earlier labs intact | Done, with the fixes above. Lab 05 still fails its service-wiring checks because of the Floci LB limitation |
| 3 Probe | Application Auto Scaling not available, so **path C** |
| 4 Service-linked role | `UnsupportedOperation`; get-role returns `NoSuchEntity`. On real AWS this role is what calls ecs:UpdateService for me |
| 5 Register scalable target | Resource ID derived and validated (3 segments, first `service`). The register call fails with `UnknownOperationException` |
| 6 Change the bounds | Not runnable. "Your turn" answered below |
| 7 CPU target tracking | Template `templates/lab-06-target-tracking-cpu.json` written and valid. Policy cannot be created |
| 8 Managed alarms | None exist (no policy). "Your turn" arithmetic below |
| 9 Request-count policy | ResourceLabel built from the ALB and target group ARNs: `app/usms-enrolment-alb/35b54c8749d043bd/targetgroup/usms-enrolment-tg/b7e6d71e05bd4136`, 6 segments, `app` first, `targetgroup` fourth, OK. Template written and valid with no unexpanded `$` |
| 10 Step scaling + alarm | Template valid. Metric `USMS/Enrolment EnrolmentQueueDepth` (Service=enrolment) published and listed. Alarm `usms-enrolment-queue-high` (>= 100, 1 x 60 s, notBreaching) created **without** an alarm action, because there is no policy ARN to give it |
| 11 Scheduled actions | Not runnable (same unsupported API) |
| 12 Fire the alarm | See below |
| 13 Suspend / resume | Not runnable. `templates/lab-06-suspended-state.json` written: suspends scale-in only, scale-out and scheduled stay false |
| 14 Restart | PERSISTENCE PROVEN for what exists on path C: the custom alarm, the custom metric, the service and the four templates (checked with sha256sum) were unchanged after floci-down / floci-up |
| 15 Close the loop | Blocks 2 and 3 fail (`UnknownOperationException`). Blocks 6 and 7 have no load balancer entry because of the Floci LB limitation. The custom alarm line in block 1, and blocks 4 and 5, work |
| 16 configs/lab-06.env | Written in the page's format, 22 exports, no empty values. The policy ARNs and bounds read `not-created`. 24 exports after Exercise 5 |
| 17 Commit | Committed with explicit paths. `git check-ignore -v` shows `.gitignore:7:outputs/*` protecting outputs/ |

## Step 12 - Fire the alarm (path C)

Prediction before running: queue depth 260 against a threshold of 100 is a breach of 160. That falls in the open-ended second step, so +3 tasks, 2 to 5.

- I pushed the metric to 260 three times and forced the alarm to ALARM with set-alarm-state.
- desiredCount stayed at 2.
- The fallback proof is saved in `outputs/lab-06-scaling-proof.txt`:
  - Blocks 1, 4 and 6 work: the alarm watches the metric, the breach of 160 selects +3, and desired is 2.
  - Block 2 is empty, because the alarm has no action.
  - Blocks 3 and 5 fail with `UnknownOperationException`.

The missing link is the step scaling policy. Without it there is no ARN for AlarmActions, so the alarm changes state and nothing is invoked.

On real AWS the chain would be: alarm ALARM, then step policy, then the breach of 160 selects +3, then desiredCount goes from 2 to 5. A scaling activity would record a Cause naming both the alarm and the policy.

Back to baseline: alarm set to OK, metric pushed down to 4, 3 and 2 first, then desired set to 2.

## verify-lab-06.sh on path C: PASS=22 FAIL=20

| Group | Checks failing | Why on this build | Real AWS would show |
|---|---|---|---|
| Lab 05 dependency | service has ONE loadBalancers entry | Floci drops the service LB wiring | 1 entry, usms-enrolment-tg / enrolment-api / 80 |
| Scalable target (5) | exists, resource ID, dimension, min 2, max 10 | `register-scalable-target` is unsupported | one target, 2..10, ecs:service:DesiredCount |
| Scaling policies (7) | CPU policy, type, metric, target, cooldowns, step policy, open-ended step | no Application Auto Scaling | 3 policies with the template configs |
| Alarms (2) | queue alarm invokes the step policy; 2+ managed alarms | no policy ARN for AlarmActions; target tracking never ran | AlarmActions = step policy ARN; 2 TargetTracking alarms per policy |
| Scheduled actions (3) | morning, evening, floor order | same unsupported API | 07:45 min 4, 20:00 min 2, Asia/Thimphu |
| Service state (2) | desiredCount inside bounds; ONE deployment | no bounds to compare; Floci returns deployments as null | desired 2 in 2..10, 1 deployment |

Everything that does not depend on Application Auto Scaling passes: the environment, the custom metric, the env file, the templates and git hygiene.

Two earlier failures were my own mistakes and are fixed:

- The suspended-state template first suspended all three switches. The lab's version suspends scale-in only.
- `outputs/.gitkeep` had been committed. The "no secret is tracked by git" check fails on any tracked file under outputs/, even .gitkeep, so I keep it untracked. This conflicts with Step 17's expectation that .gitkeep is listed.

The cleanup script `scripts/cleanup/lab-06-cleanup.sh` passes `bash -n` and has **not** been run.

## Exercise 5 summary (details in exercises.md)

- History export: `outputs/lab-06-scaling-history.json`, 2087 bytes, valid JSON. Application Auto Scaling sections are marked `"supported": false`.
- Scale-out latency: 27 s, measured with `update-service --desired-count 4` (2 to 4), then put back to 2.
- Task role `usms-ecs-task-role`; bucket ARN `arn:aws:s3:::usms-student-data`, read from USMSStudentDataReadWrite v1.
- head-bucket: exit 254, 404 Not Found, as expected before Lab 10.

## Step 6 - Your turn (answered without running it, path C)

Re-registering with min 5 while two tasks run would push desiredCount to 5 within seconds, with no policy and no alarm involved.

(a) The scalable target made that change. Application Auto Scaling enforces MinCapacity as soon as it is registered; neither a policy nor ECS decided it.

(b) The cost is three extra tasks running all night (3 x $0.01457 = about $0.04 an hour, and the floor stays raised until someone notices). `describe-scalable-targets --query 'ScalableTargets[0].MinCapacity'` is the call that would have shown it, since a monitor can compare it with the baseline of 2.

## Step 8 - Your turn: 100 percent CPU to a third task serving traffic

| Term | Value | Where it comes from |
|---|---|---|
| High alarm Period x EvaluationPeriods | 60 s x 3 = 180 s | AWS (managed alarm) |
| Policy invocation | about 0 s | AWS |
| Task start-up | 20 to 60 s (Floci measured 27 s in Exercise 5) | AWS / Lab 04 Exercise 5 |
| Health-check grace period | 60 s | Lab 05 Step 10 |
| **Total** | **about 260 to 300 s** | |

Two of the four (the alarm timing and the start-up) are not set anywhere in this lab.

The first one I would change is the grace period. Lowering it from 60 s is the only term I control directly. The cost is that a task that is still warming up could fail health checks and be killed and replaced, which makes things slower, not faster.

## Section 11 - Where each item ended up for me (path C)

**Observable here:**

- the custom metric (put-metric-data, list-metrics, get-metric-statistics)
- the custom alarm and set-alarm-state
- the ResourceLabel built and validated from the ALB and target group ARNs
- the step table in the template
- persistence of the alarm, metric, service and templates across a Floci stop and start
- ECS starting extra tasks after update-service (27 s)

**Conceptual only:**

- the service-linked role (UnsupportedOperation)
- the scalable target and its bounds
- all three policies
- the managed alarms
- the alarm-to-policy link
- scheduled actions
- suspension
- scaling activities and their Cause string
- the capacity calculation
- cooldowns
- every cost

## Review Questions

### 1. The nine lines

1. A student clicks Register, and requests per target rise past 1000 or the work queue passes 100.
2. An alarm fires and invokes a scaling policy.
3. The policy writes desiredCount, clamped to 2..10.
4. ECS starts a task from usms-enrolment:2.
5. The task gets an ENI in usms-private-subnet-a or -b with no public address.
6. usms-enrolment-sg lets in tcp/80 only from usms-alb-sg.
7. The service registers the task's IP in usms-enrolment-tg.
8. The load balancer health-checks it, and after 60 s of grace it takes traffic.
9. Nothing about the task definition, the service or the load balancer changed.

This lab owns lines 1, 2 and 3: the thresholds, the alarms and policies, and the scalable target that clamps the number.

The other six needed no change because ECS does the same thing whether a person or Application Auto Scaling sets desiredCount. The service already knew which task definition to run, which subnets and security group to use, and which target group to register in. All of that was decided in Labs 02, 04 and 05.

**What does auto scaling change about my application?** Only who sets the number of tasks and when; nothing about how a task is built, where it runs or how it gets traffic.

On my build only lines 4 to 9 could be seen. Lines 2 and 3 failed because Application Auto Scaling is not implemented.

### 2. The resource ID

The resource ID is a constructed string, `service/<cluster>/<service>`. It is not the ARN, so passing the full ARN fails validation.

Application Auto Scaling uses one API for nine namespaces, so it addresses everything as a triple: namespace, resource ID and scalable dimension. A resource ID alone is not enough, because one resource can have more than one thing that scales.

The format differs per namespace:

- **ECS:** `service/usms-ecs-cluster/usms-enrolment-svc`, dimension `ecs:service:DesiredCount`.
- **DynamoDB:** `table/<table>` or `table/<table>/index/<index>`, dimension `dynamodb:table:ReadCapacityUnits` (or WriteCapacityUnits).
- **Lambda:** `function:<name>:<alias>`, dimension `lambda:function:ProvisionedConcurrency`.

Other constructed identifiers in this architecture:

- **The ALBRequestCountPerTarget ResourceLabel** (`app/<alb>/<id>/targetgroup/<tg>/<id>`): built from the end of the load balancer ARN and the end of the target group ARN.
- **The managed alarm names** (`TargetTracking-<resource id>-AlarmHigh-<uuid>`): built from the resource ID.
- **The scaling policy ARN** (`arn:aws:autoscaling:...:resource/ecs/service/<cluster>/<service>:policyName/<name>`): embeds the resource ID.

### 3. Registering with minimum 2 against one task

The scalable target made the change. Application Auto Scaling enforces MinCapacity as soon as the target is registered or re-registered.

A policy change is different:

- A policy only acts when one of its alarms fires.
- It respects its cooldown.
- Its scaling activity's Cause names the alarm and the policy.

The bounds change involves no alarm and no cooldown, and it happens straight away.

**Example incident.** At 3 a.m. the enrolment service is struggling and the on-call engineer does not want to wait for alarms. They re-register the target with min 6 so six tasks start at once, and go back to bed.

The person taking over at 8 can find:

- `describe-scalable-targets` showing MinCapacity 6 instead of 2
- a scaling activity setting the desired count to 6 because of a minimum capacity change, not an alarm
- the ECS service events showing tasks starting at 3 a.m.
- on real AWS, a CloudTrail RegisterScalableTarget event with the caller's identity and time

Verify-lab-06's "MinCapacity is the Lab 04 baseline of 2" check would also fail.

### 4. Managed alarms versus my own

**The two target tracking alarms** are owned by the policy:

- Application Auto Scaling creates them, rewrites them whenever the policy changes, and deletes them with the policy.
- If I edit one, the edit is overwritten at the next put-scaling-policy.
- If I delete one, the policy can no longer scale in that direction, but describe-scaling-policies still lists the alarm.

**usms-enrolment-queue-high** is mine:

- Nothing recreates or deletes it for me.
- It survives policy changes.
- I choose its metric, threshold, evaluation periods and missing-data treatment.
- It can have several actions, for example the step policy and an SNS topic. A managed alarm cannot notify SNS.

**The case for `breaching`.** If the queue depth metric stops arriving, the most likely cause is that the thing publishing it (the worker) has died. If the worker is dead, the queue is probably growing. Treating missing data as breaching makes the service scale out instead of sitting still, which fails safe.

**What goes wrong if I am right.** The alarm cannot tell "the publisher is broken" from "there is nothing to report". Some publishers only send a value when the queue is non-empty. In a quiet period, or during a publisher bug, the alarm would keep firing and push the service up towards the ceiling of 10. That costs money, and extra tasks do not fix a broken publisher. It also hides the real fault behind a scaling event.

### 5. Why reactive scaling is always late

| Delay | Time | Set by |
|---|---|---|
| The metric is published and aggregated over its period | 60 s | Container Insights / CloudWatch |
| The managed high alarm needs 3 periods in breach | 180 s | AWS, inside the managed alarm |
| The policy is invoked and writes desiredCount | about 0 s | Application Auto Scaling |
| Fargate pulls and starts the task | 20 to 60 s | AWS (Floci measured 27 s) |
| The task is not useful capacity until the grace period has passed | 60 s | Lab 05 Step 10 |
| **Total** | **about 4 to 5 minutes**, all served by the capacity already running | |

The three consequences, and the configuration each one justifies:

1. **The minimum capacity is a latency decision.** The floor has to carry the first minutes of any spike, which justifies MinCapacity 2 (one task per AZ) rather than 1.
2. **Scale out eagerly, scale in reluctantly.** Being slow to add capacity hurts users, while being slow to remove it only costs money. That justifies ScaleOutCooldown 60 against ScaleInCooldown 300.
3. **Known spikes need scheduled scaling.** It is the only kind that can act before the load arrives, which justifies the 07:45 weekday action raising the floor to 4, and the evening action at 20:00 bringing it back to 2.

### 6. Two policies that disagree

- **Scale out:** the CPU policy at 50 and the request policy at 1000 each compute a capacity, and the largest one wins.
- **Scale in:** happens only when every policy agrees it is safe.

The rule is asymmetric for the same reason as the cooldowns: too little capacity hurts users straight away, while too much only costs money. A second policy on a different metric can therefore only make the service bigger, never smaller.

**Two target tracking policies on the same metric** with different targets, for example CPU 50 and CPU 60, fight. Whenever CPU is between the two targets, one policy is satisfied and the other is not. So the service keeps getting pushed towards the lower target, while the higher one keeps reporting that scale-in is safe. The capacity moves up and down, and the scaling history is hard to read. One of the two targets is always pointless.

**A step policy and a target tracking policy on the same metric** is the same mistake. Target tracking computes the capacity that should bring CPU back to 50, but the step policy adds a fixed +1 or +3 at its own threshold. The step overshoots, CPU drops below target, and target tracking starts trying to scale in, until load rises and the step fires again. I would keep the target tracking policy, because it corrects itself in proportion to the metric. Step scaling should be kept for a metric that does not fall as capacity rises, like queue depth.

### 7. ALBRequestCountPerTarget versus CPU

Three reasons the request count is the better signal for the enrolment API:

1. It measures the cause (requests) instead of a symptom (CPU).
2. It does not depend on the task's CPU reservation of 256 units, so changing the task size does not change what the target means.
3. It moves as soon as load moves, and as a per-target value it falls as tasks are added, which is what target tracking needs.

**Where CPU is better:** CPU-bound work where each request costs a very different amount, such as generating PDF transcripts or reports. In that case 1000 requests a minute could be easy or impossible depending on the mix, and CPU shows the real load.

**When the request count would scale this service badly:** when the bottleneck is not the tasks. If the database behind the API is saturated, adding tasks adds more connections and makes things worse. The request count per target still looks fine, or even drops, because slow requests take longer to complete. The ALB's TargetResponseTime (together with HTTPCode_Target_5XX_Count and the database's own CPU and connection count) would have warned me first.