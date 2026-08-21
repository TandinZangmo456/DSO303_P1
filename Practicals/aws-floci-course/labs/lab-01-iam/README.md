# Practical Report

# Lab 1 — Identity and Access Management (IAM)

University Student Management System (USMS) Cloud Infrastructure Project

1. Aim / Objective

The main objective of this practical is to create and manage AWS IAM(identity and access management) resources containing users, groups, customer managed and inlined policies and roles by using AWS CLI in comparison to Floci which is a local AWS emulator and then verify the access rights, policy versions and check if secure credential management is correctly configured.

2. Introduction

AWS IAM is an AWS service that is mainly used for establishing access rules for AWS resources which shows us who can access it and what actions are allowed. IAM works with four components which are users, groups, roles and policies. Users are individual persons with permanent and long time credentials like passwords while groups are collections of users where we attach permission so that all users in it can have the same access. Roles are like temporary identities without permanent credentials with short term tasks. Policies are like a document of JSON which defines rules and tells what actions are allowed and rejected. The most important concept of IAM is the principle of least privilege which means that access should be given only when it is mostly needed. This is important because if there is too much access then it can create security issues.

3. Use Case

This lab is the first in a series building out the cloud infrastructure for the University Student Management System (USMS) — a web app that stores student records, handles transcript uploads, sends enrolment notifications, and generates reports for the College of Science and Technology. The scenario puts me in the role of a junior cloud engineer, and this particular lab was about laying down the identity model everything else in the project will sit on top of:

usms-admins group — the lead cloud engineer, broad course-scoped permissions.

usms-developers group — developers building USMS infrastructure (read access plus scoped VPC/EC2 build permissions for later labs).

usms-auditors group — the university auditor, read-only access everywhere.

usms-ec2-app-role — assumed by the USMS application server (EC2) to read/write student data in S3.

usms-lambda-exec-role — assumed by notification functions (Lambda) for logging and messaging.

usms-developer-role — assumed temporarily by developers for elevated, time-boxed build permissions.

This is basically how real companies handle it too — permissions go on groups and roles, not on individual people, so that adding a new hire or taking away someone's access is a one-line change instead of a scramble. Doing it this way from the start keeps the whole USMS project honest about least privilege as it grows.

4. System Architecture / Design

Everything for this lab ran locally on my own machine rather than a real AWS account. I set up the AWS CLI with a named profile called "floci", and pointed its endpoint_url at a Floci container — an open-source local AWS emulator — running through Docker Compose with hybrid (durable) storage bound to a folder on my host disk. The nice thing about this setup is that every IAM command behaves exactly like it would against real AWS, but all the users, groups, policies, and roles I create actually stick around on disk between container restarts, and none of it costs anything or touches a real account.

AWS CLI (profile "floci", endpoint_url -> localhost:4566)

|

v

Docker container "floci"  (FLOCI_STORAGE_MODE = hybrid)

|  bind mount

v

~/floci-data  (host disk -- IAM users, groups, policies, roles stored as JSON)

Inside IAM, the flow looks roughly like this: users get placed into groups, groups have policies attached to them (either ones I wrote or AWS's built-in ones), roles have two separate documents — a trust policy deciding who's even allowed to become that role, and a permissions policy deciding what they can do once they are — and any role meant for an EC2 instance gets wrapped in something called an instance profile before it can actually be attached.

5. Implementation Procedure

I split the work into two parts — getting the environment running first, then actually building out the IAM resources on top of it.

### Part A — Environment Bootstrap

Verified Docker and Docker Compose v2 were installed and the daemon was reachable; ran a hello-world container as a smoke test.

Installed the Floci CLI and ran floci doctor to confirm Docker, image availability, and port 4566 were ready.

Created the project directory structure (labs/, policies/, configs/, scripts/, outputs/, templates/) before starting any service.

Wrote .gitignore (using the outputs/* form, not outputs/, so secrets could never be committed) and initialised Git, committing the ignore rules as the very first commit before any credential existed.

Proved the ignore rules worked by creating a fake secret file and confirming git status and git check-ignore correctly blocked it.

Wrote configs/course.env and docker-compose.yml, pinning FLOCI_STORAGE_MODE=hybrid and an absolute host bind mount for /app/data, then brought Floci up via a self-verifying floci-up.sh script.

Installed AWS CLI v2 and created a named profile ("floci") with endpoint_url pointed at http://localhost:4566.

Proved isolation from real AWS three ways: account number 000000000000, --debug output showing the request URL was localhost:4566, and confirming the CLI failed once Floci was stopped.

Proved persistence: created a real IAM user, fully restarted the Floci container, and confirmed the user still existed afterwards — the single test that distinguishes real durability from a coincidence of a constant root ARN.

### Part B — IAM Foundation for USMS

Created three IAM groups: usms-admins, usms-developers, usms-auditors.

Created three IAM users (usms-admin-01, usms-dev-01, usms-audit-01), each tagged with Project and Role, and added each to its matching group — verified membership from both directions (group→users and user→groups).

Attached the AWS-managed ReadOnlyAccess policy to usms-auditors.

Authored a customer-managed policy, USMSDeveloperBase, with three statements: broad read access to infrastructure, scoped VPC/EC2 build permissions for the next lab (region-restricted via a Condition), and an explicit Deny guardrail blocking dangerous identity-escalation actions (e.g. iam:CreateUser) — attached to both usms-developers and usms-admins.

Authored USMSStudentDataReadWrite, correctly distinguishing the bucket-level ARN (for s3:ListBucket) from the object-level ARN with a trailing /* (for s3:GetObject/PutObject/DeleteObject), with an explicit Deny on ever deleting the bucket.

Added an inline policy, USMSSelfManageCredentials, directly on usms-dev-01, using the IAM policy variable ${aws:username} so the same document scopes correctly to whichever user it is attached to.

Created three IAM roles with separate trust and permissions policies: usms-ec2-app-role (trusted by ec2.amazonaws.com, wrapped in an instance profile), usms-lambda-exec-role (trusted by lambda.amazonaws.com), and usms-developer-role (trusted by a specific IAM user, assumed via STS for temporary, one-hour credentials).

Created an access key for usms-dev-01, redirected straight to a git-ignored file with 600 permissions, and built a second CLI profile ("usms-dev") from it.

Ran the IAM policy simulator (simulate-principal-policy) to test explicit-deny, implicit-deny, and allow outcomes against usms-dev-01.

Generated configs/lab-01.env containing every ARN required by later labs, wrote lab notes, and ran a 27-point end-to-end verification script confirming the entire environment, IAM foundation, and Git hygiene.

6. Results and Evidence

### 6.1 CLI / SDK Output

The following screenshots capture the AWS CLI commands executed and their outputs at key stages of the practical.


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

This practical was carried out entirely through the AWS CLI against Floci, a local emulator with no graphical web console. Floci does not provide an AWS Management Console equivalent — it is a CLI/API-only emulator by design, as documented in the lab's "Floci vs Real AWS" comparison. Console-equivalent verification was therefore performed using the AWS CLI's own inspection commands, which return the same JSON representations the real AWS Console would display: aws iam get-group, aws iam get-user, aws iam list-attached-group-policies, aws iam get-role, and aws iam get-instance-profile (see Figures 6–10 above). In a real AWS account, the same resources — IAM Users, Groups, Roles, and attached Policies — would appear identically under the IAM service dashboard in the AWS Management Console.

7. Analysis and Discussion

By the end of the lab I had the full IAM foundation in place for USMS: three groups, three users tagged and dropped into the right groups, five customer-managed policies plus one AWS-managed and one inline policy, three roles each with its trust and permissions documents kept properly separate, an instance profile, and two working CLI profiles for switching between the root and developer identities. I wrote a small verification script at the end that ran 27 checks across all of this, and it came back all green. Git history shows six commits, with the .gitignore commit sitting right at the very start — before I'd created a single secret — which was the whole point of doing it in that order.

Pretty much everything matched what I expected, except for one thing that tripped me up during the policy simulator test in Step 32. I ran aws iam simulate-principal-policy against usms-dev-01 for ec2:CreateVpc, expecting it to say allowed since that permission comes from the USMSDeveloperBase policy attached to the usms-developers group. Instead it came back implicitDeny. At first I assumed I'd messed up the policy somewhere, but after double-checking with list-attached-group-policies and confirming the group really did have the right policy attached, I realised the issue was on Floci's side — its simulator seems to only check policies attached directly to whichever principal you name, and doesn't trace permissions that come in through group membership the way real AWS does. So I noted it as a Floci limitation rather than going down a rabbit hole trying to "fix" a policy that was already correct.

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