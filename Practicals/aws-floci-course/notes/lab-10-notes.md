# Lab 10 notes

**Support path: A, with a Path B check.** All six probes answered. `create-distribution` returned `E2Q9BI3T548JQK`, but Floci stored the Lambda associations as `Quantity: 0`, so the association was also validated structurally (11 ok, 0 errors).

## Environment

- Floci under Compose, `FLOCI_STORAGE_MODE=hybrid`, account 000000000000. Source lives in `labs/lab-10-lambda/`.
- `USMS_ROLE_LAMBDA` in `configs/lab-01.env` is an ARN, so I used `${USMS_ROLE_LAMBDA##*/}` wherever a role *name* is needed (also in `verify-lab-10.sh`).
- The Step 6 trust replacement removed the `aws:SourceAccount`/`aws:SourceArn` conditions that Lab 09 had added to `usms-lambda-exec-role`. The previous document is saved in `outputs/lab-10-lambda-trust-before.json`.
- Floci behaviour seen in this lab:
  - `LogResult` is None, and Node.js log streams are empty (Python logs do arrive).
  - CloudFront associations are dropped.
  - `list-distributions` is empty.
  - The resource policy loses `SourceAccount` and the `:live` qualifier.
  - S3 → Lambda delivery is absent.
  - `--qualifier` is ignored on invoke and get-function-configuration.
- `verify-lab-10.sh`: PASS=50 FAIL=1. The only failure is the `outputs/.gitkeep` check, which is also flaky under `pipefail` (SIGPIPE).

## Review questions

### 1. Moving the enrolment API to Lambda@Edge

**Against, first:** enrolment is a *write* path to one source of truth. Every enrolment has to reach the same PostgreSQL database in us-east-1, so code running in a distant edge location still makes a long round trip to the database. That trip often happens more than once per request, and over a connection that can't be pooled between requests. Moving the code nearer the user moves it *further* from the data, which can make the request slower, not faster.

**Against, second:** the restrictions do not fit an API.

- There are no environment variables and no VPC access, so the function cannot reach the private database subnets or the Lab 09 security groups at all.
- There are tight timeouts and body limits.
- Deployments replicate slowly, and you can only publish numbered versions.
- Logs are scattered across regions.
- Every viewer request is billed, including the ones that end in an error.

**When they would be right:** a request that can be answered *without the origin*, from data that rarely changes and can travel with the code. Examples are redirecting by country, refusing an unauthenticated request, or returning a static, cacheable list such as "is enrolment open today". Then the edge avoids the trip to the origin entirely. That is exactly what `usms-edge-viewer-request` does with the 403.

### 2. CloudFront Functions vs Lambda@Edge

| | CloudFront Functions | Lambda@Edge |
|---|---|---|
| Runtime | JavaScript (cloudfront-js), sub-millisecond, ~10 KB code | Node.js or Python, up to 5 s (viewer) / 30 s (origin) |
| Trigger points | viewer-request and viewer-response only | all four (viewer and origin, request and response) |
| Capabilities | Headers, URI, cookies, a key-value store; no network, no body, no file system | Network calls, request body, AWS SDK, more memory |
| Relative cost | About 1/6 of Lambda@Edge per invocation; runs at all PoPs | Higher per request plus duration; runs in regional edge caches |

- **Adding `/index.html` to a URI:** a CloudFront Function. It is a pure string rewrite on every request, which is the cheapest and fastest option.
- **Checking a JWT signature:** a CloudFront Function if the key is a symmetric secret kept in its key-value store and the check fits in its compute budget. If verification needs RSA/ECDSA with key rotation (fetching JWKS), use Lambda@Edge at viewer-request, because it has crypto libraries and network access.
- **Fetching a per-user redirect from DynamoDB:** Lambda@Edge, at **origin-request** if possible so that the result can be cached. It needs a network call and the SDK, which CloudFront Functions cannot make.

### 3. origin-response vs viewer-response for security headers

Origin-response runs **once per cache miss**, before the object is stored. The headers become part of the cached object and are served from the cache to every later viewer without running any code. Viewer-response runs on **every** response, hits included. The output is the same, but the cost and latency differ by the cache hit ratio: at a 95 % hit rate, viewer-response does 20× the work.

A requirement that forces viewer-response is a header that must differ **per viewer** and must not be cached, because whatever origin-response adds is shared by everyone who hits that cache entry. Examples:

- a per-request CSP `nonce`;
- a header echoing the authenticated student ID or a per-request trace ID;
- headers that must also appear on responses served from the cache after the origin-response logic changes.

### 4. Execution role vs resource policy on the notifier

These two policies control two different calls made by different callers.

- **Resource policy** (on `usms-transcript-notifier:live`): **S3 is the caller** of `lambda:InvokeFunction`. It answers "who may invoke this function?". If you delete it, S3 is denied when it tries to invoke. On real AWS, S3 refuses to even save the notification configuration ("Unable to validate the following destination configurations"), and existing notifications fail silently. The function itself is fine and can still be invoked manually.
- **Execution role** (`usms-lambda-exec-role`, `USMSLambdaBasic`): **the function is the caller** of `s3:GetObject`/`HeadObject` and `logs:PutLogEvents`. It answers "what may this code do once it runs?". If you delete it (or the `s3:GetObject` grant), invocations still arrive. However, `head_object` raises AccessDenied (`readable: false`), and without the log permissions there is no `USMS_NOTIFY` line to prove the function ran.

So the two are not redundant. One faces inward (who can call the function) and the other faces outward (what the function can call).

### 5. `--source-arn` and `--source-account` (confused deputy)

**The attack:** without them, the statement says "the S3 service may invoke this function". S3 acts on behalf of *any* customer. An attacker in another account creates their own bucket and configures its event notification to target our function ARN, since ARNs are not secret. When they upload objects, S3 (the deputy) invokes our function with events the attacker controls. That runs our code, spends our concurrency and money, and feeds forged `transcripts/...` keys into a pipeline that will later publish notifications.

`--source-arn arn:aws:s3:::usms-student-data` and `--source-account 000000000000` add `AWS:SourceArn`/`AWS:SourceAccount` conditions. S3 includes those values about the *original* resource, so the invoke is allowed only when it was caused by our bucket in our account. (Bucket names are global, so `SourceAccount` also covers the case where the bucket is deleted and someone else registers the same name.)

**The Lab 09 equivalent** is the trust-policy rewrite of `usms-ecs-task-role` (and the other service roles). There we added `aws:SourceAccount` and `aws:SourceArn` conditions so that `ecs-tasks.amazonaws.com` can assume the role only on behalf of our account's resources.

**Why they are the same idea:** in both cases a **service principal** is granted access. Since a service serves everyone, the grant must be narrowed with conditions that identify *on whose behalf* the service is acting. The only difference is the direction: a trust policy controls who can *become* our role, and a Lambda resource policy controls who can *invoke* our function.

### 6. Env vars accepted on an edge function

**Where validation happens:** in CloudFront, at **association time**. That is when `create-distribution`/`update-distribution` names the function version, CloudFront checks the edge restrictions (no env vars, runtime, memory, timeout, VPC, qualified ARN, trust includes edgelambda), and then replicates.

**Why the mistake isn't rejected immediately:** at `update-function-configuration` time, Lambda has no idea the function will be used at the edge. "Edge function" is not a property of the function, only of how it is later associated. A function with env vars is a perfectly valid *regional* function, so the Lambda API correctly accepts it.

**What that implies:** edge eligibility has to be checked **by us, before association**. We need a static check (Step 14's `edge_eligibility`, Exercise 3's report, the verify script's `NO environment variables` check) that runs in CI on the exact version to be associated, not on `$LATEST`. We also have to read back what the distribution actually stored. On Floci, `create-distribution` succeeded and the associations were silently stored as `Quantity: 0`. This is the same rule as Lab 09: an exit status of 0 means the API accepted the request, not that the system now does what we meant. Only reading back the stored state, and ideally exercising the path, proves that.
