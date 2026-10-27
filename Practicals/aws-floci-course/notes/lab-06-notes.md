Support path: A or B (confirm at Step 12)
Pre-check: verify-lab-03 FAIL=4 (EC2 user data/volume/db public IP checks). Not used by Lab 06, left as known leftovers.
Support path: C (no Application Auto Scaling on this Floci build)
- create-service-linked-role: UnsupportedOperation
- register-scalable-target / describe-scalable-targets: UnknownOperationException
Resource ID derived correctly: service/usms-ecs-cluster/usms-enrolment-svc
- ecs update-service --load-balancers: accepted but LBs/Grace stay null (Floci does not persist service LB wiring)
- Floci image: floci/floci:latest
- Step 11 (scheduled actions) and Step 13 (suspend/resume): not runnable, need Application Auto Scaling
- Step 12 (path C): alarm usms-enrolment-queue-high set to ALARM with set-alarm-state; no action attached,
  so desiredCount did not and could not move. On real AWS AlarmActions = step policy ARN -> +1 task (queue 100-200).
Step 12: fallback proof (path C). Chain proven only for blocks 1, 4, 6. Missing link: no step policy
exists (Application Auto Scaling unsupported), so AlarmActions is empty and desiredCount stayed 2.
On real AWS: alarm ALARM -> step policy -> breach 160 selects +3 -> desiredCount 2 -> 5.
- verify check 'no secret is tracked by git' fails on outputs/.gitkeep too, so .gitkeep is kept untracked (conflicts with Step 17's expectation)

## verify-lab-06.sh on path C: PASS=22 FAIL=20
| Group | Checks failing | Why on this build | Real AWS would show |
|---|---|---|---|
| Lab 05 dependency | service has ONE loadBalancers entry | Floci drops the service LB wiring; update-service with --load-balancers is accepted but not stored | 1 entry, usms-enrolment-tg / enrolment-api / 80 |
| Scalable target (5) | exists, resource ID, dimension, min 2, max 10 | register-scalable-target returns UnknownOperationException | one target, 2..10, ecs:service:DesiredCount |
| Scaling policies (7) | CPU policy, type, metric, target, cooldowns, step policy, open-ended step | no Application Auto Scaling, so no policies | 3 policies with the template configs |
| Alarms (2) | queue alarm invokes the step policy; 2+ managed alarms | no policy ARN to put in AlarmActions; target tracking never ran | AlarmActions = step policy ARN; 2 TargetTracking alarms per policy |
| Scheduled actions (3) | morning, evening, floor order | put-scheduled-action is part of the same unsupported API | 07:45 min 4, 20:00 min 2, Asia/Thimphu |
| Service state (2) | desiredCount inside bounds; ONE deployment | no bounds exist to compare; Floci returns deployments as null | desired 2 in 2..10, 1 deployment |
Everything that does not depend on Application Auto Scaling passes: environment, custom metric, env file, templates, git hygiene.
