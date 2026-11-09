# Lab 10 Exercise 4 - Transcript delivery design

## The Registrar's four requirements

1. A transcript is never served without a valid session token, and the check must not cost an origin request.
2. A corrected transcript stops being served within **five minutes**, but unchanged transcripts are not re-fetched every five minutes.
3. The Dean's office gets a count of refused requests **by faculty**.
4. Delivery survives one edge location being unable to reach the origin.

## 1. Where each piece of logic runs

| Logic | Placement | Why |
|---|---|---|
| Session-token check (signature + expiry) | **CloudFront Function, viewer-request** | Runs on every request *before the cache*, so a refusal never reaches the origin (req. 1). A signed token (HMAC/JWT with a key in the CloudFront KeyValueStore) can be checked with no network call. That fits CloudFront Functions' sub-millisecond budget at about 1/6 of the Lambda@Edge price, at every PoP. If the token scheme needs RSA keys fetched from a JWKS endpoint, move this to **Lambda@Edge viewer-request** (the current `usms-edge-viewer-request`). |
| URI normalisation (lower-case) | Same CloudFront Function | A pure string rewrite. It must run before the cache key is computed. |
| Security headers + `Cache-Control` | **Lambda@Edge origin-response** (current `usms-edge-origin-response`) | Runs once per cache miss, and the headers are cached with the object (Step 12 reasoning). A **response headers policy** is a no-code alternative for the static security headers. The cache-control logic stays in code. |
| Refusal counting by faculty | **Not on the request path.** CloudFront standard/real-time logs → regional processing | See section 4. |
| Notifying students of a corrected transcript | **Regional Lambda** (`usms-transcript-notifier`) on S3 ObjectCreated | It happens *after* the upload. Nobody is waiting for it. |

## 2. Cache key

**Include:** the normalised URI path. The object is the cache entry, so the faculty and the student ID are already in the path (`/transcripts/2026/stu-00417.json`).

**Do not include:**

- **The session token or the `Authorization` / `x-usms-student` header.** Every viewer would get a private cache entry, so the hit rate would fall to about zero and requirement 2's "don't re-fetch" would fail. Authorisation is already enforced *before* the cache by the viewer-request check, and that check must also confirm that the token's student owns the requested path.
- **Cookies.** The portal sets session and analytics cookies, and they would split the cache in the same way.
- **The query string.** Transcripts take no parameters, and cache-busting `?v=` strings from clients would bypass the cache.

This is a deliberate change from the lab's distribution config, which forwards `x-usms-student` as a header. That was right while the header *was* the identity, but it is wrong once a token check sits in front of the cache.

## 3. Five minutes vs "don't re-fetch every five minutes"

The two requirements apply to different caches:

- `Cache-Control: max-age=300` limits the **browser** to 5 minutes, so a corrected transcript reaches a returning viewer within 5 minutes.
- `s-maxage=3600` (or longer) keeps the object at the **edge** for an hour. When it expires, CloudFront revalidates with a conditional GET (`If-None-Match` with the ETag). An unchanged object returns **304 Not Modified**, with no body transferred, so unchanged transcripts are not re-fetched.
- The correction itself must not wait for the edge TTL. The regional notifier, triggered by the upload, issues a **CloudFront invalidation** for that one path (`/transcripts/2026/stu-00417.json`). That makes the edge copy stale within seconds to a couple of minutes, which is inside the 5-minute window.

So: a short viewer TTL, a long edge TTL, revalidation by ETag, and an event-driven invalidation of exactly the changed key.

**To verify first:** invalidation completion times in practice, and the cost (the first 1,000 paths a month are free). If corrections arrive in bulk at the end of term, path invalidations may cost more than shortening `s-maxage`, and that would change the design.

## 4. Where the refusal report comes from

Not from the edge function's logs. Lambda@Edge writes CloudWatch Logs in **the region nearest the viewer that ran it** (`/aws/lambda/us-east-1.usms-edge-viewer-request` in eu-west-2, ap-south-1, and so on). Counting would mean querying every region. CloudFront Functions have similarly region-scattered logs.

Instead, enable CloudFront **standard logs** (to an S3 bucket in us-east-1) or **real-time logs** (to Kinesis Data Streams). Each record has the status code (403), the URI, and therefore the faculty from the path. A scheduled Athena query over the standard logs, grouped by the faculty path segment where `sc-status = 403`, produces the Dean's daily count in one place. Have the viewer-request function return a distinctive `x-usms-edge: viewer-request-deny` header, and log that header, so that our refusals are not mixed up with origin 403s.

## 5. A requirement an edge function is the wrong tool for

**Requirement 4: survive an edge location being unable to reach the origin.** This is a property of the distribution, not of code on the request path:

- configure an **origin group with failover**: the primary `usms-student-data` in us-east-1, plus a secondary replica bucket via S3 Cross-Region Replication, failing over on 5xx/timeout;
- keep the long `s-maxage` so cached copies continue to be served;
- add **Origin Shield** so that edges share one regional cache.

An edge function cannot make an unreachable origin reachable. Writing retry logic in one adds latency and stays inside the same 30-second limit.

The refusal report (section 4) is the second thing that does not belong in the edge function. It is analytics after the fact, not request handling.

## What I'd measure first

- **Cache hit ratio by path** after removing the identity header from the cache key. I expect it above 90 %. If transcripts are each viewed only once or twice, the hit ratio stays low whatever the key is. Then the edge cache buys little, and a simpler design would do: signed URLs straight from the regional API, with no Lambda@Edge.
- **p95 latency of the viewer-request check** in each design. If the CloudFront Function version is within 1 ms, there is no case for paying Lambda@Edge prices on every request.
