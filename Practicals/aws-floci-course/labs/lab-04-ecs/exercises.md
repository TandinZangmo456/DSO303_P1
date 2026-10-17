# Lab 04 Exercises

## Exercise 1 - a second service, deployed

Created `usms-results-svc` in `usms-ecs-cluster` from the `usms-enrolment` task definition family, desired count 1, both private subnets, carrying `usms-enrolment-sg`. All IDs came from `configs/*.env` and `$(...)`, nothing copied by hand. It is not recorded in `configs/lab-04.env`, because Exercise 4 removes it.

Result: two ACTIVE services with different names and desired counts (usms-enrolment-svc = 2, usms-results-svc = 1). Screenshot: `screenshots/exercise1.png`.

Observation: the new service showed Running 0 straight after creation and reached its desired count after roughly 40 seconds, the same task start delay seen in Step 10.

Follow-up check: after about 40 seconds usms-results-svc reached Desired 1 / Running 1, spans 2 subnets, carries usms-enrolment-sg, and list-tags-for-resource returned all four tags (Project, Tier, Service, Lab), so tag storage works on this build. Screenshots: `screenshots/exercise1.png`, `screenshots/exercise1-followup.png`.

## Exercise 2 - a new revision, and a deployment that does not drop traffic

Kept the revision 1 document as `templates/lab-04-taskdef-rev1.json` (a copy; `templates/lab-04-taskdef.json` is untouched). Built `templates/lab-04-taskdef-rev2.json` from it with memory raised from 512 to 1024 (a valid pair for cpu 256) and `USMS_LOG_LEVEL=info` added. Registered it as `usms-enrolment:2`, then ran `update-service --task-definition usms-enrolment:2` and polled with the Step 10 loop.

Result: the service reports `usms-enrolment:2`, Desired 2 / Running 2. `describe-task-definition usms-enrolment:1` still succeeds, is ACTIVE and still shows memory 512; revision 2 is ACTIVE with memory 1024. Nothing was deregistered. Screenshots: `screenshots/exercise2-register-update.png`, `screenshots/exercise2-stabilised.png`.

One sentence: the service's `taskDefinition` field (its pointer) changes to revision 2, while revision 1 itself, the service name and ARN, its network configuration and its desiredCount do not change.

Observation: the polling loop exited on attempt 1 with desired=2 running=2, so I did not observe old tasks being replaced by new ones; this Floci build reports the service as stable immediately. On real AWS the default rolling deployment starts new tasks before stopping old ones, and the waiter would take noticeably longer.

Drift note: `configs/lab-04.env` still records `USMS_ENROLMENT_TASK_REVISION=1`, while the family's latest revision is now 2. That file was written at the end of Step 12 and is a point-in-time record, which is why the lab looks values up from the API instead of trusting stale ones.

## Exercise 3 - an ECS configuration drift report

Wrote `scripts/utilities/lab-04-ecs-inventory.sh`. It resolves `configs/` from `${BASH_SOURCE[0]}`, lists services from the cluster with `list-services` (no hard-coded name), describes each one, and computes both verdicts from the data: `roles` compares `executionRoleArn` to `taskRoleArn`, and `publicip` reads `assignPublicIp`. It also writes `outputs/lab-04-ecs-inventory.json`.

Decision on `set -e`: not used. An inventory must keep going when one service cannot be described, otherwise the first error would silently hide the services I most want to see. `-u` and `pipefail` are on.

Result: identical output from the repo root, from `~`, and from `labs/lab-04-ecs/`:

    usms-enrolment-svc   desired=2  running=2  taskdef=usms-enrolment:2  roles=SEPARATE  publicip=OK
    usms-results-svc     desired=1  running=1  taskdef=usms-enrolment    roles=SEPARATE  publicip=OK

Observation: `usms-results-svc` shows the family name with no revision because it was created from the family name, and Floci stores it that way. Limitation: the `publicip=N/A` branch (a service with no networkConfiguration) is in the script but I could not test it, because this lab has no EC2 launch type service. Screenshot: `screenshots/exercise3-inventory.png`.

## Exercise 4 - the enrolment week capacity plan

### 1. Why a fixed desiredCount of 2 cannot answer the 08:03 problem
usms-enrolment-svc has no mechanism that reads a metric or a clock. Its desiredCount changes only when a human runs update-service (as I did in Step 11). At 08:03 two 256/512 tasks carry the whole first-twenty-minutes load, and nothing adds capacity until someone notices the outage. Fixed capacity also cannot shrink, so the same 2 tasks run at 3am on a Sunday in July.

### 2. Proposed plan
Assumptions (not given by the project lead): 4,000 students x ~10 API calls = 40,000 calls in 1,200 s = ~33 rps average; 3x burst = ~100 rps peak; 25 rps per task. Tasks needed = 100 / 25 = 4; doubled so one AZ can fail = 8.

- Minimum 2: one per AZ. Too high: idle cost all month. Too low: an AZ failure leaves 1 task.
- Scheduled floor 8, Mon 07:45-08:45: Too high: a few extra task-hours per week. Too low: 08:03 fails again.
- Maximum 12: 150 rps surprise / 25 = 6, doubled for AZ loss. Too high: runaway cost on abnormal traffic. Too low: a larger surprise hits the ceiling.

Advice to the Lab 06 team: aim for capacity to already exist before 08:00 (scheduled floor), because Fargate tasks take 20-60 s to start and a metric-triggered policy alone reacts too late for a spike that carries 90% of the week's traffic in 20 minutes. Use target tracking for the unexpected remainder.

### 3. Monthly cost (Fargate Linux/x86, us-east-1, 730 h/month)
Rates: $0.000011244 per vCPU-second and $0.000001235 per GB-second (https://aws.amazon.com/fargate/pricing/, accessed 17 Oct 2026) = $0.04048 per vCPU-hour, $0.004446 per GB-hour.
Per task-hour (0.25 vCPU, 0.5 GB) = 0.25 x 0.04048 + 0.5 x 0.004446 = $0.012343; per task-month = $9.01.

- Fixed at 2: 2 x 9.01 = $18.02
- Fixed at peak 8: 8 x 9.01 = $72.08
- Min 2 + floor 8 for 1 h/week: 18.02 + 6 x 4.345 x 0.012343 = ~$18.34

Excludes data transfer, NAT gateway charges, CloudWatch Logs and any Savings Plan discount.

### 4. What to switch off: the Exercise 1 results service

    What will be deleted: usms-results-svc (Exercise 1 practice service) only.
    What depends on it: nothing; it is not in configs/lab-04.env and no other lab references it.
    Reversible? Yes: re-run Exercise 1.
    Effect on later labs: none. usms-enrolment-svc, the cluster and the task definitions are kept.

Order: scale to zero, wait until running=0, then delete the service.

    aws ecs update-service --cluster usms-ecs-cluster --service usms-results-svc --desired-count 0
    (poll describe-services until runningCount is 0)
    aws ecs delete-service --cluster usms-ecs-cluster --service usms-results-svc --force

### Deletion result
Scaled usms-results-svc to 0, polled until runningCount was 0 (attempt 2), then ran delete-service --force. It now shows INACTIVE; usms-enrolment-svc is still ACTIVE with desired 2. verify-lab-04.sh reports PASS=36 FAIL=2, the same two documented failures as before the exercise (Floci does not return UserIdGroupPairs; outputs/.gitkeep matches the '^outputs/' pattern). Nothing new fails, which is the real test. Screenshot: `screenshots/exercise4-deletion.png`.

## Exercise 5 - close the loop back to Lab 3

Source group: Floci does not return UserIdGroupPairs (Step 8 limitation), so the inbound source group was read from policies/usms-enrolment-sg-ingress.json, which holds sg-016aeadf128a2fb06 (usms-app-sg).

Reverse lookup, first attempt: `aws ec2 describe-instances --filters "Name=instance.group-id,Values=<group>" "Name=instance-state-name,Values=running"` returned three instances: usms-web-01 (i-7d102245bea4dde6d), usms-db-01 (i-c84c3079944bba97a) and usms-db-02 (i-4e4ee481c1cea6bb9). This was a MISMATCH against $USMS_WEB_INSTANCE, and I did not treat it as a pass.

Diagnosis: describe-instances on those three IDs showed usms-db-01 and usms-db-02 carry only usms-db-sg. Floci ignores the instance.group-id filter and returns every running instance. A client-side check (JMESPath over each instance's SecurityGroups, comparing GroupId to the source group) returned only i-7d102245bea4dde6d.

Verdict: LOOP CLOSED. The only running instance carrying usms-app-sg is usms-web-01, which equals $USMS_WEB_INSTANCE from configs/lab-03.env, so the rule grants access to something real. Limitation recorded: server-side group filter not honoured on this build; on real AWS the filter alone would have returned one instance. usms-db-02 appears to be left over from a Lab 3 exercise; it is unrelated to this lab and I left it alone.

Tag audit: list-tags-for-resource on the cluster ARN and service ARN returned Project=USMS (plus Tier, Name, and Lab on the service) for both, so this build stores ECS tags and no tag-resource fix was needed.

Output: `lab-04-lab03-linkage.txt` (copied from the git-ignored outputs/ so it can be committed) states the source group, the instance, the verdict and that the rule is temporary until Lab 05. Screenshots: `screenshots/exercise5-diagnosis.png`, `screenshots/exercise5-linkage-file.png`.
