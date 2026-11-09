# Lab 12 Notes - ECS Pipeline Deploy

## Support path

`deploy-support-probe.sh` gave **Path A** (`USMS_CODEDEPLOY_SUPPORTED=yes`, because the CodeDeploy API answers). In practice there are three gaps:

- CodeBuild FAULTs, so the Deploy stage never runs;
- `describe-images` is blind to pushed images;
- ECS moves the service pointer but never replaces tasks.

The registry works for real: push, pull and pull-by-digest. It runs as the sidecar container `floci-floci-course-ecr-registry` on host port 5100, which is why Step 4's port publish collided and was reverted.

## privilegedMode (Step 13)

`privilegedMode: true` gives the CodeBuild container a Docker daemon and the elevated Linux capabilities that `docker build` needs. Effectively, anything in the buildspec runs with root-level control of the build host's container runtime. That is why it matters who can start the build or edit the buildspec. The pipeline role's `codebuild:StartBuild` is scoped to the one project for this reason.

## Your turn - Step 12: my USMSCodePipelineBase v2 vs Step 15

My draft is `notes/lab-12-my-pipeline-policy.json` (5 statements); Step 15 has 6. Three statements match exactly (artifact store, StartBuild, PassRole to CodeBuild). The two that differ are both ECS statements:

1. **My single `DeployTheEnrolmentService` statement put all four ECS actions on `"*"`.** Step 15 splits it in two:
   - `DescribeServices`/`UpdateService` scoped to the one service ARN `service/usms-ecs-cluster/usms-enrolment-svc`;
   - the task-definition actions on `"*"`.

   Mine let the role update *any* service in the account. I only needed the wildcard for the actions that have no ARN to scope to yet (`RegisterTaskDefinition`), and I let that leak onto `UpdateService`.
2. **My ECS PassRole statement** matches in substance (same two roles, `ecs-tasks.amazonaws.com`). But Step 15 also adds `ecs:ListTaskDefinitions`, which I left out. That count difference is why the statement totals are 5 vs 6.

Lesson: split statements by *what can be scoped*, not by *what the feature is*.

## Your turn - Step 16: inputArtifacts = SourceOutput instead of BuildOutput

`SourceOutput` is the zip of `labs/lab-11-cicd/app/` as uploaded: `buildspec.yml`, `src/`, `config/`, `tests/`, `VERSION`, `Dockerfile`. It has **no `imagedefinitions.json`**, because that file is only created by the build, in `dist/`. `artifacts.base-directory: dist` is what puts it at the root of `BuildOutput`.

So the DeployToECS action would open the source archive, look for `imagedefinitions.json` at its root, not find it, and **fail in the Deploy stage**, even though the mistake is in the pipeline wiring and the Build stage was green. Worse, the pipeline would be deploying from something the build never produced or tested.

## Your turn - Step 18: what to do about usms-enrolment:5

**Decision: leave `usms-enrolment:5` registered (ACTIVE) for now, and record it.**

**Reason:** it is the evidence of the failed release. It shows exactly what was deployed (image `…:r8`, never pushed) and when. Deregistering it now would remove the record from the family's default listing while the incident is still being written up. It cannot be deployed by accident through the pipeline, because the pipeline always derives a *new* revision from the service's current one (`:4`). It is also listed for deregistration in `scripts/cleanup/lab-12-cleanup.sh` (`for REV in 3 4 5`) at the end of the course.

**How someone would notice in six months without being told:**

- `describe-task-definition --task-definition usms-enrolment` returns the **latest** ACTIVE revision, which is `:5`. Any script that "deploys the latest revision" would pick the broken one.
- An audit that resolves every ACTIVE revision's image against the registry flags it immediately: `docker manifest inspect` or the registry `HEAD …/manifests/r8` returns not found. That check belongs in `verify-lab-12.sh`. Today, its "task definition names the ECR repo" check passes on `:5`, because it only matches the repository *string*.
- Tagging the revision would make it visible in any console listing. For example: `aws ecs tag-resource --resource-arn …:task-definition/usms-enrolment:5 --tags Key=Status,Value=failed-release-r8-image-missing`.

On real AWS I would deregister it once the incident note is written. "Latest revision is broken" is a trap for the next person.

---

## Section 14 - Review questions

**1. The deploy action changes one field. Name three changes that cannot travel through this pipeline, and how to deploy each.**

The action copies the *service's current* task definition and replaces only `containerDefinitions[name].image`. So anything else in the task definition cannot ride along:

- **Resource sizing:** `cpu`/`memory` (for example, raising memory from 1024 to 2048 because enrolment week causes OOM kills). Deploy it by registering a new revision with describe → strip → change → register (Step 10) and `update-service`, or better, by putting the task definition under IaC (the CloudFormation lab) so the pipeline deploys the whole definition.
- **Environment and secrets:** adding an environment variable or a `secrets` entry (a new DB endpoint, a feature flag). Same route: a new revision registered outside the image path. Alternatively, move configuration out of the task definition into something the app reads at runtime (SSM Parameter Store or AppConfig), so a config change needs no deploy at all.
- **Logging, health check or roles:** `logConfiguration`, `healthCheck`, `taskRoleArn`/`executionRoleArn` (for example, swapping to a narrower task role, as Exercise 4 recommends). These are infrastructure changes. They should go through a CloudFormation/CodeDeploy pipeline whose artifact *is* a task definition file (the blue/green action consumes `taskdef.json` + `appspec.yaml`, which do travel with the source).

Service-level settings (`desiredCount`, load-balancer wiring, `deploymentConfiguration`) are not in the task definition at all. They need `update-service` or IaC.

**2. `ecr:GetAuthorizationToken` on `"*"` and `ecs:RegisterTaskDefinition` on `"*"`: the same kind of exception?**

*For "the same":* both are wildcards forced by the API's shape, not by laziness. Neither action operates on a resource that has an ARN at authorization time: the token belongs to the registry, and the task definition revision does not exist yet. Both are bounded by *other* statements. The token is useless without the repository-scoped push/pull actions, and a registered revision is inert until `UpdateService` (scoped to one service) runs it, with the roles it can name bounded by PassRole.

*For "different":* `GetAuthorizationToken` grants **nothing by itself**. It authenticates you, and every action you take with that token is authorized again against the repository. `RegisterTaskDefinition` **creates** something whose contents (image, command, role, environment) are completely unconstrained. Exercise 4 shows that content can turn into a data breach once any service runs it.

*My answer:* **not the same.** The token wildcard is *authentication* and is fully re-checked downstream. The RegisterTaskDefinition wildcard is *authoring* code that a privileged role will execute, and nothing downstream inspects that content. The first is safe to accept; the second needs compensating controls (least-privilege task roles, image provenance checks, approval before deploy).

**3. Digest vs tag: why the inconvenience is worth it, and the strongest case against pinning digests.**

A tag is a pointer that anyone with push access can move. A digest is the hash of the content and cannot move. A task definition that names `:r7` means "whatever `r7` points to when a task starts". So a scale-out at 3 a.m., or a task replaced after a host failure, can run different bytes from the ones you tested. Exercise 5 showed this: revision 4 kept saying `:r7` while `r7` resolved to a different image. With a digest, the task definition *is* the evidence of what ran, and a rollback to a revision restores the exact bytes.

**The case against pinning:** a digest also pins the base image's vulnerabilities. If `nginx:1.27-alpine` gets a critical CVE fix, a tag-based deployment picks up a rebuilt and re-pushed tag on the next task start or `--force-new-deployment`. A digest-pinned service keeps running the vulnerable bytes until someone rebuilds, re-pins and redeploys through the full pipeline. Digests make security patching an explicit release every time, and with many services that operational burden is real. (Answer: pin digests *and* automate the rebuild-and-redeploy when base images change. Don't use tags as a patching mechanism.)

**4. A failure the circuit breaker would not catch, and what would.**

The circuit breaker only watches whether new tasks **reach a steady RUNNING state and pass health checks** during the deployment. It would not catch an image that starts, answers `/healthz.html` with `ok` (a static file), and is *functionally wrong*. For example, `r9` ships an `index.html` whose enrolment form posts to the wrong endpoint, or a config change makes 30% of requests return 500 while the health path stays 200. Every task is "healthy", the deployment completes, and the breaker never fires. It also cannot undo a deployment that already completed.

What catches it: **application-level signals tied to the deployment.** CloudWatch alarms on the ALB's `HTTPCode_Target_5XX_Count` or on latency, used as **deployment alarms** (ECS rolls back on alarm) or in CodeDeploy blue/green's `autoRollbackConfiguration` with `DEPLOYMENT_STOP_ON_ALARM`. Add a synthetic smoke test in the `AfterAllowTestTraffic` hook that exercises a real enrolment flow through the test listener *before* production traffic shifts.

**5. Replace-only APIs: what they share, and what a merge-based `update-pipeline` would have to decide.**

`update-pipeline`, `put-bucket-notification-configuration`, `update-assume-role-policy` and `put-bucket-policy` all store **one document whose meaning comes from the whole**. The statements of a policy are evaluated together (an explicit Deny anywhere wins). A notification configuration must not have overlapping prefix/suffix rules. A pipeline's stages form an ordered graph wired by artifact names. Validating a fragment in isolation is impossible, so the API takes the whole document, validates it as a unit, and swaps it atomically. Replacing is also idempotent and easy to reason about: what you sent is what exists.

A merge-based `update-pipeline` would have to decide:

- **identity:** are stages and actions matched by name or by position, and what does a rename mean (delete plus add, or rename)?
- **ordering:** where does a new stage go, and how do you express "between Build and Deploy"?
- **deletion:** how do you say "remove this action", given that an absent key would mean "keep"?
- **nested merging:** does `configuration` merge key by key, so stale keys survive, or replace?
- **artifacts:** if a merge renames `BuildOutput`, are the downstream `inputArtifacts` updated?
- **concurrency:** what happens if two merges land at once? Replacement plus a `version` field gives optimistic locking for free.

Replace-only pushes all of those decisions to the client, which is why the lab's get-modify-put script asserts the stages it expects before writing.

**6. Why `create-policy-version` does not set the new version as default automatically.**

Because a policy can be attached to many principals, and the default version is what *all* of them are evaluated against, immediately. Separating "create" from "activate" supports a **stage → review → promote → roll back** workflow:

1. create v2 next to v1;
2. inspect it, or simulate it (`iam simulate-principal-policy` against the non-default document);
3. have someone else approve;
4. flip the default;
5. if something breaks, flip back to v1 with `set-default-policy-version`, which is a pointer change and not a re-upload.

It also separates the permissions: `iam:CreatePolicyVersion` and `iam:SetDefaultPolicyVersion` can be granted to different people. An automatic default would turn every draft into a production change and remove the one-call rollback.

**7. The colleague's claim: the enrolment service is running code that was never reviewed.**

- **`outputs/lab-12-image-digest.txt` helps most.** It is the only artefact that ties a *tag* to a *digest* at a point in time. It also shows that `r7` was moved (the RETAGGED line), which is the exact mechanism by which unreviewed bytes could be running under a reviewed name.
- **`outputs/lab-12-deploy-evidence.txt` helps partly.** It shows the service moved from `:3` to `:4` and that `:4` names `…:r7`, but it names a tag, so it cannot say which bytes.
- **The pipeline execution history does not help on its own** (and here the Build stage FAULTed). It links a source version to an execution, but nothing in it records the image digest that was built. On Floci the image was not even built by that execution.

What I needed at build time: the **image digest written into the build's output and into the task definition**. The build should emit `imageUri` as `repo@sha256:…` (from `docker push`'s output or `docker inspect --format '{{index .RepoDigests 0}}'`) and record the source version beside it in `build-metadata.json` inside the image. Then one command settles it:

```bash
aws ecs describe-task-definition \
  --task-definition "$(aws ecs describe-services --cluster usms-ecs-cluster --services usms-enrolment-svc --query 'services[0].taskDefinition' --output text)" \
  --query 'taskDefinition.containerDefinitions[0].image'
```

That returns a digest, which maps one-to-one to a build record and a reviewed source version.
