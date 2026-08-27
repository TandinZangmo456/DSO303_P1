# Practical Report

# Lab 1 — Identity and Access Management (IAM)

University Student Management System (USMS) Cloud Infrastructure Project

1. Aim / Objective

The main objective of this practical is to create and manage AWS IAM(identity and access management) resources containing users, groups, customer managed and inlined policies and roles by using AWS CLI in comparison to Floci which is a local AWS emulator and then verify the access rights, policy versions and check if secure credential management is correctly configured.

2. Introduction

AWS IAM is an AWS service that is mainly used for establishing access rules for AWS resources which shows us who can access it and what actions are allowed. IAM works with four components which are users, groups, roles and policies. Users are individual persons with permanent and long time credentials like passwords while groups are collections of users where we attach permission so that all users in it can have the same access. Roles are like temporary identities without permanent credentials with short term tasks. Policies are like a document of JSON which defines rules and tells what actions are allowed and rejected. The most important concept of IAM is the principle of least privilege which means that access should be given only when it is mostly needed. This is important because if there is too much access then it can create security issues.

3. Use Case

This lab is connected to other labs which design the cloud infrastructure of the Student Management System (USMS) software program that collects information about students, provides updates on enrollment, and enables the uploading documents. I hold the position of a junior cloud engineer at this lab and my job is to develop the identity model. Everything else will be developed on the basis of this model.

| Identity | Type | Represents | Permission level |
|---|---|---|---|
| `usms-admins` | Group | Lead cloud engineer | Broad, course-scoped permissions |
| `usms-developers` | Group | Developers building USMS infrastructure | Read access + scoped VPC/EC2 build permissions for later labs |
| `usms-auditors` | Group | University auditor | Read-only access, everywhere |
| `usms-ec2-app-role` | Role | USMS application server (EC2) | Read/write student data in S3 |
| `usms-lambda-exec-role` | Role | Notification functions (Lambda) | Logging and messaging |
| `usms-developer-role` | Role | Temporarily assumed by developers | Elevated, time-boxed build permissions |

This is actually how companies function: they give access not to the person but to their role and group. Therefore, it can be done by clicking rather than going through the entire process.

4. Implementation Procedure

There is 2 parks for this lab:

### Part A — Environment Bootstrap

Step 1: Before creating my environment, I confirmed that I installed the required components of Docker and Docker Compose v2. To do this, I created and ran a `hello-world` container, confirming the good condition of the components.

Step 2: When I installed the Floci CLI, I ran the command `floci doctor`, so that I could check the Docker operation, its emulator image existence, and the availability of port 4566.

Step 3: I constructed the project directory according to the layout as `labs/`, `policies/`, `configs/`, `scripts/`, `outputs/`, `templates/`, hence organizing the project files properly.

Step 4: With the aim to obstruct secrets from reaching Git after they have been expelled, I made sure that rules of the `.gitignore` file were written in the form of `outputs/*`, before making the first commit in the repository.

Step 5: I made sure that the rules worked successfully by creating a secret file and inspecting it with the commands `git status` and `git check-ignore`.

Step 6: I created the files `configs/course.env` and `docker-compose.yml`, setting the variable `FLOCI_STORAGE_MODE=hybrid` and establishing an absolute host bind mount at `/app/data`, then I launched Floci through a self-verifying script, the file `floci-up.sh`.


Step 7: I installed the AWS CLI version 2 and set up a named profile `"floci"` with the `endpoint_url` set to `http://localhost:4566`.


Step 8: I verified the isolation from the real Amazon AWS platform in three different ways — I got the account number as `000000000000`, the output of the `--debug` command showed that the request was sent to the address `localhost:4566`, and the AWS CLI showed that it does not work at all when Floci is switched off.


Step 9: I demonstrated the persistence feature by creating a normal IAM user which stayed there after full restart of Floci container — this is the only test that shows that the data is still there instead of the continuous root ARN that everybody assumes to exist.


### Part B — IAM Foundation for USMS

Step 1: The first stage was to set up three IAM groups, which are named `usms-admins`, `usms-developers`, and `usms-auditors`.


Step 2: The next step was to create three users under IAM (`usms-admin-01`, `usms-dev-01`, `usms-audit-01`), tag each of them with their Project and Role, and assign them correctly to their groups – then cross-verified the groups and users.


Step 3: Then I assigned the policy `ReadOnlyAccess` from AWS to the group of `usms-auditors`.


Step 4: After that I composed a custom policy named `USMSDeveloperBase, that contained three statements, which gave permission to view infrastructure information, added a condition in a statement to restrict use of VPC/EC2 build permissions to a region and put a restriction statement to protect IAM from the use of `iam:CreateUser` call.


Step 5: Finally, I composed the `USMSStudentDataReadWrite` permission policy, which provided the right level of detail in specifying ARNs to allow the policy to perform `s3:ListBucket` and `s3:GetObject` /`PutObject` / `DeleteObject` actions.

Step 6: I inserted a policy that has been specified, `USMSSelfManageCredentials`, on `usms-dev-01` by incorporating the IAM variable of policy `${aws:username}` so as to make the document applicable for whomever is using it as per their user name.

Step 7: I have formed three IAM roles so that each of them possesses its own separate policies - `usms-ec2-app-role`(which is trusted by the `ec2.amazonaws.com` domain and is surrounded by an instance profile), `usms-lambda-exec-role`(which is trusted by `lambda.amazonaws.com`) and `usms-developer-role`(which is being trusted by an IAM user and assumed through STS for just one hour).

Step 8: I established a new access key of `usms-dev-01` which has been redirected directly to a file that has been ignored by git and has granted permissions of value `600`, just for the purpose of creating a second CLI profile called `usms-dev`.

Step 9: Using the IAM policy simulator (`simulate-principal-policy`), tested for explicit denies, implicit denies, and allowed outcomes on `usms-dev-01`.

Step 10: Created `configs/lab-01.env`, which has ARNs needed for the upcoming labs, compiled lab notes, and executed 27 checks to ensure the entire environment, its IAM base, and Git are in good shape.

6. Results and Evidence

### 6.1 CLI / SDK Output

The screenshots given below are the AWS CLI commands executed and their outputs at key stages of the practical.


![alt text](<../../screenshots/Screenshot from 2026-08-21 01-19-09.png>)
**Figure 1: Docker and Docker Compose v2 verified, with a successful hello-world container run confirming the daemon was reachable.**


![alt text](<../../screenshots/Screenshot from 2026-08-21 01-24-29.png>)
**Figure 2: Project directory structure created before Floci was started, following the prescribed labs/policies/configs/scripts layout.**


![alt text](<../../screenshots/Screenshot from 2026-08-21 01-44-35.png>)
**Figure 3: Floci brought up via Docker Compose with hybrid storage; the script verified /app/data was a genuine host bind mount before reporting success.**


![alt text](<../../screenshots/Screenshot from 2026-08-21 01-55-38.png>)
**Figure 4: aws sts get-caller-identity returning Account 000000000000 without the --profile flag, confirming the named CLI profile and AWS_PROFILE environment variable were active by default.**


![alt text](<../../screenshots/Screenshot from 2026-08-21 02-05-22.png>)
**Figure 5: Persistence proof — an IAM user (persistence-check) created, the Floci container fully restarted, and the same user retrieved afterwards, confirming durable storage rather than a coincidental constant.**


![alt text](<../../screenshots/Screenshot from 2026-08-21 02-41-15.png>)
**Figure 6: The three IAM groups (usms-admins, usms-developers, usms-auditors) created and listed with their ARNs.**


![alt text](<../../screenshots/Screenshot from 2026-08-21 02-46-44.png>)
**Figure 7: The three IAM users created and confirmed via aws iam list-users and aws iam get-user, each with the correct ARN under account 000000000000.**


![alt text](<../../screenshots/Screenshot from 2026-08-21 02-48-41.png>)
**Figure 8: Group membership verified from both directions — usms-dev-01 shown as a member of usms-developers, and usms-developers shown as containing usms-dev-01.**


![alt text](<../../screenshots/Screenshot from 2026-08-21 02-57-38.png>)
**Figure 9: The customer-managed policy USMSDeveloperBase created and attached to the usms-developers group, confirmed via list-attached-group-policies.**


![alt text](<../../screenshots/Screenshot from 2026-08-21 23-35-39.png>)
**Figure 10: Mid-lab state verification confirming all users, groups, local policies, and roles (including the instance profile) were present after a persistence gap, demonstrating durable storage across sessions.**


![alt text](<../../screenshots/Screenshot from 2026-08-21 09-14-05.png>)
**Figure 11: The final end-to-end verification script (verify-lab-01.sh) reporting PASS=27, FAIL=0 across environment, groups, users, policies, roles, and Git-hygiene checks.**


![alt text](<../../screenshots/Screenshot from 2026-08-21 09-34-59.png>)
**Figure 12: Final Git commit history — six clean commits from the initial .gitignore commit through to the review-question notes, with no secret files ever staged.**

### 6.2 AWS Management Console Verification

The entire practical was done through the AWS CLI against Floci, which is a local emulator without a graphic web console. Floci is not equipped with the equivalent of AWS Management Console, being a CLI/API-only emulator by design, as explained in the lab’s “Floci vs Real AWS” section. Therefore, the console equivalent verification is conducted through the AWS CLI inspection commands yielding the same output in terms of the format (JSON) as the real AWS Management Console would have, including commands such as: aws iam get-group, aws iam get-user, aws iam list-attached-group-policies, aws iam get-role, or aws iam get-instance-profile (see Figures 6-10). In a real AWS account, the same resources such as IAM Users, Groups, Roles, and attached Policies would have appeared in the same way in the AWS Management Console in the IAM service section.

7. Analysis and Discussion

    1. What was achieved
    
    In the end, I was able to complete the entire IAM setup of USMS successfully, which included three groups, three users categorized into relevant groups, five customer-managed policies along with both AWS-managed and inline policies, three roles with their trust and permission documents isolated, an instance profile and two CLI profiles helping to switch between root and developer identities. Following that, I wrote a short script for checking everything and all 27 checks were carried out successfully. The git history shows six commits at the end; the .gitignore commit being the very first one which makes sense as no secrets have been created at that point in time.

    2. Did the results match what I expected?

    Yes it matches for some but one thing that caused my confusion. In step 32, I executed aws iam simulate-principal-policy for usms-dev-01 and ec2:CreateVpc and expected it to return allowed as that permission comes from USMSBowlerBase policy attached to usms-developers group. Instead, I received an implicitDeny error. Everything else was correct.


    3. Did you encounter any mistakes?

    Two. The above simulator error and another smaller one in Exercise 3 when I tried to set --max-session-duration of 1800 seconds to analytics partner role and it resulted in parameter validation error.

    4. How did I fix them?


    What did I notice while doing all this?

    The main point is that Floci does not enforce IAM quite like it is supposed to in real AWS. It accepts pretty much any credentials and does not prevent you from doing something that should be forbidden by a properly constrained policy. The above simulator example demonstrates my point well. Thus, having a command that works does not mean that the underlying policy is correct. I have checked the JSON myself, especially the bucket-vs-object ARN thing from step 23, and thought through the explicit-deny-wins principle on my own rather than trusting the running code.
    


Pretty much everything matched what I expected, except for one thing that tripped me up during the policy simulator test in Step 32. I ran aws iam simulate-principal-policy against usms-dev-01 for ec2:CreateVpc, expecting it to say allowed  since that permission comes from the USMSDeveloperBase policy attached to the usms-developers group. Instead it came back implicitDeny. At first I assumed I'd messed up the policy somewhere, but after double-checking with list-attached-group-policies and confirming the group really did have the right policy attached, I realised the issue was on Floci's side — its simulator seems to only check policies attached directly to whichever principal you name, and doesn't trace permissions that come in through group membership the way real AWS does. So I noted it as a Floci limitation rather than going down a rabbit hole trying to "fix" a policy that was already correct.

A smaller hiccup came up in Exercise 3, where I tried setting --max-session-duration to 1800 seconds (30 minutes) for the analytics partner role and got a parameter validation error straight away. Turns out IAM enforces a minimum of 3600 seconds for that setting, on real AWS and apparently on Floci too — I hadn't expected the emulator to enforce that particular limit given how loose it is about everything else. I fixed it by leaving the role's ceiling at 3600 and instead passing --duration-seconds 1800 directly to the assume-role call, which worked fine since it's well under the ceiling. It was actually a useful mistake to make, because it made the distinction between a role's maximum allowed session and the session actually requested a lot clearer to me than just reading about it would have.

The biggest thing I took away from the whole lab, though, is that Floci doesn't really enforce IAM the way real AWS does — it'll accept basically any credentials and won't stop you from doing something a properly scoped policy should have blocked. The simulator issue above is a good example of that. So the fact that all my commands "worked" isn't really proof the policies are correct — I had to actually read through the JSON carefully, especially around the bucket-vs-object ARN distinction from Step 23, and reason about the explicit-deny-always-wins rule myself, rather than trusting that a command succeeding meant the permissions were right.

8. Reflection

Going into this lab I understood IAM at a surface level — users, permissions, that sort of thing — but actually building it out from scratch made the group-vs-user distinction click in a way reading about it never did. The clearest example was Exercise 1: I created a brand new user, usms-qa-01, added it to a group, and it instantly had the same developer permissions as everyone else in that group — without me attaching a single policy to the user itself. That's the whole point, and seeing it work firsthand made it obvious why real teams almost never attach policies straight to a person.

A few things gave me trouble along the way. The S3 bucket-vs-object ARN thing (bucket ARN for listing, bucket ARN + /* for actually reading objects) is such an easy mistake to make and I can see why it trips people up — the two look almost the same on paper but one gives you a policy that silently fails on every download. I also hadn't really appreciated, before this lab, that a role needs both a trust policy and a permissions policy, and that forgetting either one just quietly breaks assume-role with no obvious error pointing you to the cause. And then there was the whole simulator situation with Floci not evaluating group-inherited permissions properly, which was frustrating in the moment but taught me to be more sceptical of "it ran without an error" as proof that something is actually configured right.

In an actual job, I'd expect this kind of IAM setup to be used for onboarding new engineers safely — just drop them in the right group instead of hand-crafting permissions every time — and for giving applications and scheduled jobs their own scoped, auto-rotating credentials through roles instead of hardcoding an access key somewhere in a config file. The analytics-partner-role exercise also gave me a decent mental model for how you'd grant a third party temporary, audited access without ever handing over something permanent.

Things I'd like to dig into further after this: MFA enforcement, IAM Identity Center / SSO and federation for handling multiple accounts, permission boundaries and Service Control Policies for org-wide guardrails, and Attribute-Based Access Control as an alternative to the group model I used here — I have a feeling ABAC scales a lot better once you're managing hundreds of users instead of three.

9. Conclusion

Overall I'd say this lab did exactly what it set out to do. I ended up with a full, least-privilege IAM setup for USMS — three groups, three users, five customer-managed policies plus one inline and one AWS-managed one, three roles with their trust and permissions documents kept properly separate, an instance profile, and two working CLI profiles — all checked over both by hand and by a 27-point script, and all sitting in Git without a single secret ever making it into version control.

More than just the resources themselves, what I'm taking away from this is a much better feel for how identity and access actually work in the cloud — trust versus permissions, why groups and roles beat individual users almost every time, how an explicit deny always wins no matter what else is allowed, and the simple habit of writing your .gitignore before you've created anything worth hiding. All of this — plus just being more comfortable typing out IAM policies from scratch — is what the rest of the USMS build (VPC, EC2, S3, Lambda) is going to be resting on.

## 10. Appendix

Additional Files

policies/usms-developer-base-policy.json (and -v3.json) — customer-managed policy for developers/admins

policies/usms-student-data-rw-policy.json — S3 read/write policy with bucket-vs-object ARN distinction

policies/usms-self-manage-credentials.json — inline policy using the ${aws:username} variable

policies/trust-ec2.json, trust-lambda.json, trust-account-developers.json — role trust policies

policies/usms-reporting-readonly-policy.json, usms-analytics-partner-permissions.json, usms-backup-operator-policy.json — exercise policies

configs/course.env, configs/lab-01.env — shared and lab-specific environment configuration (no secrets)

scripts/setup/floci-up.sh, floci-down.sh — environment lifecycle scripts

scripts/utilities/whoami.sh, floci-storage-check.sh, verify-lab-01.sh — diagnostic and verification scripts

notes/lab-01-notes.md — review question answers and observed Floci limitations

outputs/lab-01-iam-snapshot.json — full account authorization details snapshot (git-ignored)

Submission Checklist

Student information completed

Objectives stated

Introduction provided

Real-world use case described

System design included

Implementation documented

CLI outputs included

Console-equivalent verification included (Floci has no web console; CLI inspection commands used instead)

Analysis completed

Reflection completed

Conclusion written