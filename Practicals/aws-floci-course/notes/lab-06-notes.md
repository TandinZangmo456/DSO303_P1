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
