Support path: B (ECS supported; Application Auto Scaling not available in this Floci build)

Lab 04 Step 7 note: Lab 03's EC2 instance (instance profile -> usms-ec2-app-role) and Lab 04's Fargate task (taskRoleArn -> usms-ecs-task-role) both end at the same policy, USMSStudentDataReadWrite. Both deliver temporary credentials with no key on disk, and both start working at the same moment Lab 10 creates the bucket.

Lab 04 Step 8 limitation: Floci accepted the group-referenced ingress rule (both via --ip-permissions file:// and via --source-group) but did not store or return UserIdGroupPairs. describe-security-groups shows port 80 with no source. On real AWS the rule would show usms-app-sg as its source. The input document (policies/usms-enrolment-sg-ingress.json) contains the correct group ID, which is the reviewable evidence.

Lab 04 Step 9 limitation: the submitted task definition (templates/lab-04-taskdef.json) contains an awslogs logConfiguration naming /usms/ecs/enrolment, but Floci's describe-task-definition returns null for it. On real AWS the log group name would be returned.

Lab 04 Step 8 limitation: Floci accepted the group-referenced ingress rule (via --ip-permissions file:// and via --source-group) but does not store or return UserIdGroupPairs. describe-security-groups shows port 80 with no source. policies/usms-enrolment-sg-ingress.json holds the correct group ID as evidence.

Lab 04 Step 11 limitation: describe-services returns no events (events[0:3] is null / None) on this Floci build, so the service's own narration of the count change could not be observed. Evidence of the manual scale is the desiredCount/runningCount readings instead: Desired 3 / Running 2 immediately after update, then Desired 2 / Running 3 as the third task started, settling at Desired 2 / Running 2.



Lab 04 verify-lab-04.sh result: PASS=36 FAIL=2. (1) 'usms-enrolment-sg is sourced from usms-app-sg' fails because Floci does not store or return UserIdGroupPairs (see Step 8 limitation). (2) 'no secret is tracked by git' fails only because outputs/.gitkeep is tracked and matches the script's '^outputs/' pattern; no secret is tracked.
