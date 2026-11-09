# Lab 13 - Exercises and Your-turn notes

All of this was run on Floci 1.5.34. Where a feature is missing, the original error is kept next to the substitute.

## Your-turn notes from the steps

**Step 7 - a non-matching event.** I wrote `health-check ok from usms-web-01 status=200` after the four `USMS_EVENT` lines. `rejectedLogEventsInfo` came back `null`. Neither the `USMS_NOTIFY` pattern nor the `ERROR` pattern matches it.

**Step 8 - the ERROR pattern.** Results from the local simulator (`test-metric-filter` is unsupported):

| Pattern | Matches among the four Step 7 lines | `"reason":"no ERROR here"` line |
|---|---|---|
| `ERROR` | [4] | **matched** (false positive) |
| `ERROR USMS_EVENT` | [4] | **matched** (both tokens are present) |
| `"ERROR USMS_EVENT"` | [4] | not matched |

A filter pattern matches tokens anywhere in the line, so any message that happens to contain the word `ERROR` is counted as an error. In production I would not accept a bare `ERROR`. I would use the quoted phrase `"ERROR USMS_EVENT"`, which only matches when `ERROR` is the level prefix, and make the logging code always put the level first. The better long-term fix is fully JSON log lines with a `level` field, so the `{ $.level = "ERROR" }` dialect can be used.

**Step 10 - defaultValue.** A 15-minute window before any upload today returned `[]`, an empty `Datapoints` list. A window that includes the upload returned `2.0`. An empty list means *no data point exists*. A list of zeroes means *a filter ran and found nothing*. This build can only produce the empty list, because zeroes come from a filter's `defaultValue=0` and Floci cannot install filters. The difference matters for `usms-notify-silence`, which treats missing data as breaching.

**Step 13 - rollback.** I pointed `live` at version 1, then back at the instrumented version. `list-versions-by-function` showed `$LATEST, 1, 2, 3` throughout, and I deleted nothing. Both invocations returned the *same* payload shape. Floci runs `$LATEST` for every qualifier: `ExecutedVersion=$LATEST`, and versions 1 and 3 have the same `CodeSha256`. So the rollback was **configuration only, not demonstrated**. On real AWS this rollback is one `update-alias` call and takes effect within seconds for every trigger, because S3 targets the alias. A Lambda@Edge rollback (Lab 10 Step 11) means republishing a version and pushing a CloudFront distribution update to every edge location, which takes minutes.

---

## Exercise 1 - Extract a value instead of counting events

**Original:** `put-metric-filter ... --filter-name usms-transcript-seconds ... metricValue=$.seconds` → `UnsupportedOperation`.

**Dialect choice.** The `USMS_EVENT` prefix means the message is not pure JSON, so the JSON dialect (`$.seconds`) cannot apply. The space-delimited dialect would split `USMS_EVENT {...}` into two fields, `[marker, payload]`. The payload has no spaces, so `seconds` cannot be pulled out as its own positional token. For a real filter there are two options:
- change the emitter to write the line as pure JSON, with the marker moved into a field (`{"marker":"USMS_EVENT",...}`), then use `metricValue=$.seconds`; or
- write a second, space-delimited line such as `USMS_METRIC transcript_seconds science 0.77` with `[m, name, faculty, seconds]` and `metricValue=$seconds`.

The first costs every consumer of the `USMS_EVENT` prefix (Step 9's interface). The second costs an extra log line per event.

**Substitute (run):** `labs/lab-13-monitoring/log-to-metric.py` reads the `USMS_EVENT` lines since a given time, extracts `seconds`, and publishes one `TranscriptSecondsFromLogs` data point per event with that event's timestamp. Three fresh emitter runs (0.77, 1.25, 2.60) produced data points with **SampleCount 3, Minimum 0.77, Maximum 2.6, Sum 4.62**, exactly the values passed on the command line.

**TranscriptSecondsFromLogs vs TranscriptLagSeconds.** Both measure how long a transcript took, by two routes:
- `TranscriptLagSeconds` is published directly by the code, so it costs a code change and a `PutMetricData` call.
- The log-derived metric needs no code change, but depends on the log line format and only exists while the filter is installed.

I would keep `TranscriptLagSeconds` for code we own, because it does not break when someone rewords a log line. I would use the log-derived route for components whose code we cannot change.

Screenshot: `screenshots/lab13-ex1-extract-value.png`

## Exercise 2 - Portable dashboard and a sixth widget

`scripts/utilities/usms-dashboard-generate.sh` regenerates `templates/lab-13-dashboard.json` with an unquoted heredoc. Region comes from `$AWS_REGION_COURSE` and the alarm ARNs from `$USMS_ACCOUNT_ID`. The generator contains no literal account ID (`grep -c 000000000000` → 0). The sixth widget is *Central log errors - last 3 hours*: `CentralErrorCount`, `start: -PT3H`, a horizontal annotation at 5, full width at `y=12`. Layout check: **6 widgets, no overlap**.

`put-dashboard` is still `UnsupportedOperation`, so `DashboardValidationMessages` could not be observed. The terminal summary draws the new widget.

`verify-lab-13.sh` now checks for 6 widgets. A hard-coded count is useful because it catches a widget that silently disappeared, which CloudWatch never reports. It is annoying because every legitimate dashboard change means editing the verifier too, and someone will forget. A better check would compare the deployed widget count to the widget count in the committed template.

Screenshot: `screenshots/lab13-ex2-portable-dashboard.png`

## Exercise 3 - Are these thresholds defensible?

`scripts/utilities/usms-threshold-report.sh` writes one JSON array to stdout, with diagnostics on stderr. It finds the root from `${BASH_SOURCE[0]}`, so it runs from `/tmp`. It reads the alarm list and metric names from `describe-alarms`, nothing is hard-coded, and it passes each alarm's dimensions to `get-metric-statistics` unchanged. The composite alarm is not stored on Floci, so the script reads it from its template with nulls for the metric fields and marks it `"source": "template"`.

Findings over the last 24 hours:
- `usms-transcript-lag-high`: observed max **3.1 s**, 16 samples, `threshold_ever_breached: true`. The threshold of 2 s is within the range of real values, which is good. But every breach came from my own emitter runs (2.40, 2.85, 3.10), so this does not yet say anything about production traffic.
- `usms-enrolment-queue-high` (Lab 06): **no data at all** in 24 hours, and it has never breached. It sits in `ALARM` only because an earlier lab forced it there. It cannot be defended or attacked without data. This is the alarm whose threshold has never been approached, which is the finding the exercise is designed to produce.
- `usms-notify-silence`: one data point (the synthetic `NotifyCount=2`), never below 1. With so little data, the 15-minute window is a guess.
- `usms-transcript-pipeline-down`: no metric, as expected for a composite.

Output: `outputs/lab-13-threshold-report.json`. Screenshot: `screenshots/lab13-ex3-threshold-report.png`

## Exercise 4 - USMS observability plan

Written as `notes/lab-13-observability-plan.md`.

## Exercise 5 - Leave an alarm the next alerting lab can attach to

- `outputs/lab-13-alarm-actions-draft.json`: three actions. The composite **pages**; the two children open **tickets** and are planned to run with `actions_enabled: false`. The SNS ARNs are built from `$USMS_ACCOUNT_ID` and `$AWS_REGION_COURSE`, not typed.
- Validation, with mismatches reported rather than fixed: every ARN is well formed. `usms-transcript-pipeline-down` is reported as **not existing**, because `PutCompositeAlarm` is unsupported. I kept that mismatch in the output instead of removing the composite from the draft.
- The draft is **not applied**: `AlarmActions` is `null` on both stored alarms. Floci returns `null` rather than `[]`.
- I ran the emitter six more times across four faculties (0.38, 1.72, 0.95, 2.85, 1.10, 0.64 s). `outputs/lab-13-latency-baseline.json` holds the `get-metric-statistics` result over the session, so these are real observations.
- `outputs/lab-13-alerting-readiness.txt` is generated by a single re-runnable `{ ...; } > file` block and is git-ignored (`.gitignore:7:outputs/*`). It contains the alarm names and missing-data policies, the composite rule, the namespace and five metrics, alias version 4 with tracing Active, `xray_supported=no`, `insights_supported=no`, the draft validation and an **observed max latency of 3.1 s**.
- `verify-lab-13.sh` is unchanged at 39/10. The same ten failures are all explained in the report.

Screenshots: `screenshots/lab13-ex5a-actions-draft.png`, `screenshots/lab13-ex5b-baseline-readiness.png`
