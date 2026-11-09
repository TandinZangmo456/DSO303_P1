# Lab 11 notes

**Support path: A as recorded by the probe, but Path C for builds.** `cicd-support-probe.sh` answered every call, including CodeDeploy, and wrote `USMS_CICD_SUPPORT_PATH=A`. Floci stores the CodeBuild project and the pipeline and runs the Source action. **No build ever ran**, though: every build ends in `FAULT` because Floci cannot pull `aws/codebuild/standard:7.0` (Known Issues - Lab 11). Every artifact that came out of the buildspec was made by the Step 14 local runner, and I report it as a local build (`buildId: local`).

## Environment

- Floci 1.5.34 under Compose (`floci-course`), `FLOCI_STORAGE_MODE=hybrid`, bind-mounted to `~/floci-data`, account 000000000000.
- All ten earlier env files were sourced (Lab 09 included). The container name is `enrolment-api` and the placeholder image is `public.ecr.aws/nginx/nginx:stable-alpine` (task definition `usms-enrolment:2`).
- What Floci did in this lab:
  - `start-build` → SUBMITTED, QUEUED, PROVISIONING and DOWNLOAD_SOURCE succeed, then COMPLETED FAILED with the context `pull access denied for aws/codebuild/standard`. Build status `FAULT`, the log stream is empty, and no artifact is uploaded.
  - `create-pipeline` stores the document but does **not** start an automatic execution (0 executions after create).
  - `start-pipeline-execution` → the Source action succeeds and records the S3 version ID as `externalExecutionId`. The Build action fails with `CodeBuild build usms-enrolment-build:N finished with FAULT`.
  - `get-pipeline-state`: the stage-level `latestExecution.status` is `None`. Only the action-level state is filled in, so I queried `actionStates[0].latestExecution`.
  - No `SourceOutput/` or `BuildOutput/` objects are written to the artifact bucket.
  - After Step 18 (`source.type=CODEPIPELINE`), a plain `start-build --project-name` is **accepted** (build `:2`). Real AWS rejects it. This is *recorded, not observed*.
  - `errorDetails.message` is `null` in the state output, but `list-action-executions` holds the error.
  - EventBridge `put-targets` returns 0 failures, but the target's `RoleArn` reads back as `None`.
- `verify-lab-11.sh`: **PASS=45 FAIL=1**. The only failure is `no secret is tracked`, caused by the deliberately tracked `outputs/.gitkeep`. It is the same false positive as in Labs 09 and 10. The CodeBuild/CodePipeline checks pass because they check stored configuration, not whether a build ran.
- I did not apply the Known Issues alternative (`python:3.12-slim` build image). I recorded the limitation instead.

## In-lab questions

### Nested heredoc rule
A quoted heredoc (`<< 'BUILDSPEC'`, `<< 'EOF'`) writes the **text**: `$VAR` and `$(...)` reach the file unexpanded. An unquoted heredoc (`<< META`, `<< EOF` in Step 21) writes the **result**: the shell expands them first. The buildspec is quoted so CodeBuild expands `$USMS_RELEASE` at build time. `META` inside it is unquoted so the metadata gets real values at build time. `configs/lab-11.env` is unquoted so the file holds values, not commands.

### The explicit Deny in USMSCodeBuildBase
The Deny on `usms-student-data` records that no build may ever touch student records, and it holds even if a later policy version or another attached policy adds a broad `s3:*` Allow. On Floci it is documentation only, because Floci evaluates no IAM.

### Step 15 - USMSDeployBase with `Resource: "*"` but the condition kept
`iam:PassedToService` would still limit *which service* receives the role (EC2 or ECS tasks), but not *which role*. The deploy role could then pass any role that trusts `ec2.amazonaws.com` or `ecs-tasks.amazonaws.com`. In this account an attacker would name **`usms-eks-node-role`**. It trusts EC2, and it carries `USMSEKSNodePolicy`, whose CNI statement can create, attach and delete network interfaces anywhere in the VPC, as well as `USMSStudentDataReadWrite`. They would launch an instance with it and read its credentials from IMDS, which gives them write access to student records and control over the network. `usms-transcripts-reader-role` (ECS tasks, `USMSStudentDataReadOnly`) is the second choice. The scoped Resource list is the part that stops this. The condition only decides where the stolen role ends up.

### Step 19 "Your turn" - r5
Evidence (screenshot `lab11-step19d-yourturn-r5.png`): `list-object-versions` shows **3** versions of `source/usms-enrolment-src.zip` (r3, r4, r5). `list-objects-v2 --prefix usms-enrolment-pipeline/BuildOutput/` shows **0** objects. There were 2 pipeline executions, both `Failed`.

The numbers differ because they count different events. A source version appears on every `put-object`, whether or not a pipeline runs. A BuildOutput object appears only when an execution's Build action succeeds and uploads its artifact. On real AWS the counts would also differ: the automatic execution at create time adds an output with no new upload, superseded executions add none, and the Step 12 standalone build writes to `build/`, not `BuildOutput/`. On Floci every build faults, so the count stays at 0 however many versions I upload.

### Exercise 3 - what `aws:SourceArn` adds to `aws:SourceAccount`
`aws:SourceAccount` only says "CodeBuild acting for *some* resource in account 000000000000". Anyone in the account who can create a CodeBuild project, and pass this role to it, could get a build running with `usms-codebuild-role`. CodeBuild acts as the confused deputy for their project. `aws:SourceArn` pins the trust to the named projects (`usms-enrolment-build`, `usms-results-build`), so a project somebody else creates cannot assume the role even inside the same account. Because Exercise 1 reuses the role, the results project had to be listed too. Otherwise the tightening would break it on real AWS.

## Review questions

### 1. Source and Build succeed, but the deployed application is unchanged
- **`artifacts.base-directory`:** if it pointed somewhere other than where the build wrote (for example the repository root instead of `dist`), the build would succeed but collect the unbuilt `src/` files (still showing `__RELEASE__`). Or the artifact would nest everything under `dist/`, so the deploy stage would not find `imagedefinitions.json` at the root and would keep the old image. One command to check: `unzip -l outputs/lab-11-buildoutput.zip`. Look for a `dist/` prefix or a missing `imagedefinitions.json`.
- **The source zip's internal layout:** if the zip was packed from the parent (`app/…`) and a stale `buildspec.yml` or `VERSION` also sat at the root, CodeBuild would build the stale root copy. Likewise, a failed repack could leave the previous `outputs/usms-enrolment-src.zip` to be uploaded again. The build succeeds, but on old bytes. One command to check: `unzip -p outputs/usms-enrolment-src.zip VERSION` (and `unzip -l` for an `app/` prefix). If it does not print the release I meant to ship, the source was wrong, not the build.

### 2. Why CodePipeline requires versioning on an S3 source
An execution must be able to say exactly **which input it ran on**, and keep saying it while the stages run. With versioning, the Source action records an immutable version ID. I saw it as the FetchSource `externalExecutionId` `3bdc0c4b-…` for r4. Every later stage, retry or re-run of that execution refers to those exact bytes, even if a new upload lands a second later. Without versioning, the key is a mutable name. An execution could only record "whatever was at `source/usms-enrolment-src.zip`", and two stages, or a retry, could read different contents under one execution ID.

### 3. iam:PassRole for someone who thinks it is redundant
"Permission to create a project" is permission over the *project object*. The role decides what the project's code can do once it runs, and that can be far more than you can do yourself. If creating the project were enough, anyone allowed to create a build project could name the account's most powerful role, put `aws iam attach-user-policy …` in the buildspec, and give themselves administrator rights. They would never hold those permissions directly. `iam:PassRole` is the separate check that you may *delegate this specific role's power*. `iam:PassedToService` limits that delegation to the service that should receive it. The objection is reasonable because in day-to-day work the two always go together, but they protect different things.

### 4. Two roles versus one
**For two roles:** each principal gets only what its job needs.
- The pipeline role can start one build, read and write artifacts and pass one role, but it cannot run arbitrary code.
- The build role runs arbitrary code from the repository, so anyone who can change `buildspec.yml` controls it. It therefore gets only its log group and the artifact bucket, and no `codebuild:*`, `iam:PassRole` or (later) `ecs:UpdateService`.
- A malicious commit compromises the build role, not the pipeline role, so it cannot redeploy production or change the pipeline.
- CloudTrail also shows clearly which identity did what.

**Strongest argument against:** the boundary is weaker than it looks. The build writes the artifact that the pipeline deploys, so a compromised build can already ship whatever it likes through `imagedefinitions.json` without needing the pipeline's permissions. Two roles also mean two trust policies and a PassRole that must be kept in step (Lab 12 must version both). That is more to get wrong, and a misconfigured PassRole fails only at run time. When there is one small service and one team, much of that extra complexity buys little real isolation.

### 5. The three heredoc forms
- **`<< 'BUILDSPEC'` (quoted) made unquoted:** my shell would expand `$USMS_RELEASE`, `$ARTIFACT_DIR`, `$(date …)` and `${CODEBUILD_BUILD_ID:-local}` *while writing the file*. Those were empty or wrong at that moment, so the buildspec would contain `release=` and `"buildId": "local"` fixed forever. It would still be valid YAML, so no error, and the build would quietly ship empty versions.
- **`<< META` (unquoted, nested) made quoted:** `build-metadata.json` would contain the literal text `"$USMS_RELEASE"` and `"${CODEBUILD_BUILD_ID:-local}"`. That is still valid JSON, so `json.tool` and the smoke test pass. Only a person reading the file would notice.
- **`<< EOF` in Step 21 made quoted:** `configs/lab-11.env` would hold `$(aws s3api …)` text instead of values. It still "works" when sourced, but it runs AWS calls on every `source`, records nothing for Lab 12, and gives different answers on different days. Nothing fails, so nothing reports it.

In all three cases the result is valid in its own format (YAML, JSON, shell). The mistake shows up only in the *values*, and no parser checks values.

### 6. Removing pre_build's configuration validation
**They are right** when deploy is cheap, fast and safe to fail. Examples: a dev environment with a quick rollback, or a deploy stage that checks the same thing (ECS refusing an `imagedefinitions.json` whose name matches no container) before it changes anything. Then the check is duplicated and only saves a little time.

**They are expensively wrong** when the deploy stage checks it *late* or *partly*. For example:
- a rolling deployment has already drained healthy tasks before it notices;
- the wrong container name only fails after ECR push and a 10-minute deployment, with a circuit-breaker rollback;
- the check covers something the deploy never looks at (the port, the health path), so a bad config deploys "successfully" and breaks behind the ALB.

pre_build fails in seconds, before anything is built or pushed. Its message also names the file and the value to fix, not just the failing service.

### 7. Proving to an auditor that r4 was built from the source on a given date
The evidence chain, from what this lab created:
1. **Git history:** the commit that set `labs/lab-11-cicd/app/VERSION` to `r4`, with its date and author.
2. **The versioned source object:** `list-object-versions` shows version `3bdc0c4b-aefd-490b-ad18-c8676a56105e` with its `LastModified` time. `get-object --version-id` returns those exact bytes, and the `VERSION` file inside them can be compared with the commit.
3. **The pipeline execution:** execution `4f82be51-…`'s Source action recorded `externalExecutionId = 3bdc0c4b-…`, so this execution fetched exactly that version.
4. **The build:** the Build action names `usms-enrolment-build:4`, and `batch-get-builds` shows its resolved source version and phases.
5. **The artifact:** `build-metadata.json` inside BuildOutput contains `release: r4`, `buildId` and `sourceVersion`, which tie the output back to steps 3 and 4.

**Weakest link:** the step from Git to S3. Nothing proves that the zip uploaded as `3bdc0c4b` was packed from that commit. `usms-pack-source.sh` runs on my laptop from a working tree that could be dirty, and no hash or commit ID is recorded in the object. (A real setup would put the commit SHA in the object's metadata or use a Git-based source.) On Floci the chain also breaks at steps 4–5, because the build faulted and no BuildOutput exists. Here the honest evidence stops at step 3, plus a local build.
