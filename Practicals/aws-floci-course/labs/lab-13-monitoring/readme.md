# Lab 13 Report - Centralized Logging and Monitoring with CloudWatch and X-Ray

## Aim

To add three layers of telemetry to USMS:
- **Logs:** a central log group and retention on every USMS log group.
- **Metrics:** metric filters and custom metrics with dimensions.
- **Traces:** X-Ray segments for the instrumented `usms-transcript-notifier`.

On top of these: a threshold alarm, an absence alarm, a composite alarm, the `usms-overview` dashboard, a restart test, `configs/lab-13.env`, and the verify and cleanup scripts.

The lab ran on **Floci 1.5.34** (hybrid storage) with **AWS CLI 2.32.7**. Several observability APIs do not exist on this build. I did not try to fix that. For each gap I recorded the exact error and used the substitute from *Known Issues - Lab 13*:

| Feature | Error on this build | Substitute |
|---|---|---|
| Metric filters | `UnsupportedOperation` | Local filter-pattern simulator; metrics published directly and marked synthetic |
| Logs Insights | `start-query` answers but ignores `parse`/`stats` | `filter-log-events`, aggregated locally in Python |
| X-Ray | `UnknownOperationException` | Structural validation of segment documents; logs and traces joined by `trace_id` |
| Composite alarms / alarm history | `UnsupportedOperation` | Rule evaluated locally against the real child states; `describe-alarms` snapshots as history |
| Dashboards | `UnsupportedOperation` | Dashboard JSON as the deliverable, plus a terminal summary drawn from live data |

> **Observed** means the command ran and I read the result back. **Recorded** means Floci stores the setting but does not act on it, or does not store it at all. **Substitute** means the Known Issues alternative.

**Repository notes**
- The lab folder is `labs/lab-13-monitoring/`; the handout calls it `labs/lab-13-cloudwatch-xray/`.
- `lab-01.env` stores the role variables as ARNs, so I used `${USMS_ROLE_LAMBDA##*/}` to get the role names.
- I tagged resources `Lab=13`, not the handout's copied `Lab=08`.

## Steps 1-4 - Environment and support probe

- **Floci and storage:** Floci came up in hybrid mode and every storage check was `[ok]`.
- **Lab 10 verify:** `verify-lab-10.sh` gave **50/1**. The one failure was already there before this lab: `outputs/.gitkeep` is tracked in git.
- **Env files:** all twelve earlier env files were sourced.
- **Probe:** logs, metrics, alarms and Lambda are supported. Metric filters, Insights, dashboards and X-Ray are not.

- **[Screenshot: Step 1 - Floci up, storage check, Lab 10 verify]** ![Step 1](screenshots/lab13-step01-floci-up.png)
- **[Screenshot: Step 2 - env files, identity, key values]** ![Step 2](screenshots/lab13-step02-source-env.png)
- **[Screenshot: Step 3 - lab directories]** ![Step 3](screenshots/lab13-step03-dirs.png)
- **[Screenshot: Step 4 - support probe]** ![Step 4](screenshots/lab13-step04-support-probe.png)
- **[Screenshot: Step 4b - exact errors for unsupported APIs]** ![Step 4b](screenshots/lab13-step04b-unsupported-errors.png)

## Steps 5-7 - Inventory, retention and log events

- **Inventory:** five of the six log groups had no retention (`None`). Lab 06's alarm was in `ALARM`.
- **Retention:** I created `/usms/central/application` and set 30 days on it and the ECS groups, 14 days on the Lambda groups, and tagged the central group.
- **Log events:** the handout's shorthand `--log-events` fails on CLI 2.32 (`Expected: ',', received: '"'`), so I sent the same four events as JSON. `rejectedLogEventsInfo` was `null`.
- **Your turn:** I added a health-check line that no filter should match.

- **[Screenshot: Step 5 - telemetry inventory]** ![Step 5](screenshots/lab13-step05-inventory.png)
- **[Screenshot: Step 6 - central group and retention]** ![Step 6](screenshots/lab13-step06-central-group-retention.png)
- **[Screenshot: Step 6b - tagging]** ![Step 6b](screenshots/lab13-step06b-tag.png)
- **[Screenshot: Step 7 - put-log-events and read back]** ![Step 7](screenshots/lab13-step07-put-log-events.png)
- **[Screenshot: Step 7 Your turn - non-matching event]** ![Step 7b](screenshots/lab13-step07b-yourturn-negative-event.png)

## Steps 8-10 - Filter patterns and metric filters (substitute)

- **Step 8:** `test-metric-filter` is unsupported, so I tested patterns with `filter-pattern-sim.py`. `USMS_NOTIFY` matched only line 1 of the four. `ERROR` also matched the false positive `"no ERROR here"`; `"ERROR USMS_EVENT"` did not.
- **Step 9:** `put-metric-filter` is unsupported, so **Checkpoint 4 is not demonstrated**.
- **Step 10:** the S3 upload invoked the notifier and the `USMS_NOTIFY` line was **observed**. `NotifyCount` had no data, so I published it by hand and recorded it as **synthetic**.
- **Step 10 Your turn:** a window before the upload returns `[]` (no data), not zeroes. Zeroes would need a filter's `defaultValue`.

- **[Screenshot: Step 8 - USMS_NOTIFY pattern test]** ![Step 8](screenshots/lab13-step08-filter-test.png)
- **[Screenshot: Step 8 Your turn - ERROR pattern]** ![Step 8b](screenshots/lab13-step08b-yourturn-error-pattern.png)
- **[Screenshot: Step 9 - put-metric-filter unsupported]** ![Step 9](screenshots/lab13-step09-metric-filters.png)
- **[Screenshot: Step 10 - upload, invoke, USMS_NOTIFY line]** ![Step 10a](screenshots/lab13-step10a-perturb.png)
- **[Screenshot: Step 10 - read-back and synthetic substitute]** ![Step 10b](screenshots/lab13-step10b-readback.png)
- **[Screenshot: Step 10 Your turn - empty list vs data]** ![Step 10c](screenshots/lab13-step10c-yourturn-defaultvalue.png)

## Steps 11-12 - Custom metrics and IAM

- **Custom metrics (observed):** `TranscriptsProcessed` was published both with dimensions and without (the total). The two `TranscriptLagSeconds` points aggregated to **SampleCount 2, Average 1.165, Maximum 1.91**.
- **IAM:** `USMSObservabilityWrite` has three statements and is attached to both roles. It is **recorded** only, because Floci does not enforce IAM.

- **[Screenshot: Step 11 - put-metric-data]** ![Step 11a](screenshots/lab13-step11a-put-metric-data.png)
- **[Screenshot: Step 11 - dimensions and statistics]** ![Step 11b](screenshots/lab13-step11b-verify-dimensions.png)
- **[Screenshot: Step 12 - policy document]** ![Step 12a](screenshots/lab13-step12a-policy-doc.png)
- **[Screenshot: Step 12 - create, attach, verify]** ![Step 12b](screenshots/lab13-step12b-create-attach.png)

## Steps 13-14 - Instrumented notifier, alias and tracing

- **Version numbers:** Lab 10 already used v2, so the instrumented code is **v3**, the traced version is **v4**, and `live` now points at 4.
- **v3 runs (observed):** it logs `USMS_SUMMARY` and published a metric from inside Lambda.
- **Floci finding:** every qualifier (`1`, `3`, `live`) runs `$LATEST`, and v1 and v3 have the same `CodeSha256`. The **rollback could not be demonstrated**.
- **Tracing:** `TracingConfig=Active` is **recorded** only. No X-Ray daemon runs.

- **[Screenshot: Step 13 - package, publish, repoint alias]** ![Step 13a](screenshots/lab13-step13a-deploy-v2.png)
- **[Screenshot: Step 13 - verify through the alias]** ![Step 13b](screenshots/lab13-step13b-verify-v2.png)
- **[Screenshot: Step 13 Your turn - rollback and forward]** ![Step 13c](screenshots/lab13-step13c-yourturn-rollback.png)
- **[Screenshot: Step 13 - Floci always runs $LATEST]** ![Step 13d](screenshots/lab13-step13d-floci-alias-finding.png)
- **[Screenshot: Step 14 - active tracing]** ![Step 14](screenshots/lab13-step14-active-tracing.png)

## Steps 15-18 - X-Ray segments, emitter and sampling (substitute)

- **Segments:** I built a parent segment, three subsegments and a downstream segment. Every X-Ray API returned `UnknownOperationException`, so I ran structural validation instead: **10 ok, 0 errors**.
- **Namespace bug:** `lab-06.env` already exports `USMS_METRIC_NAMESPACE=USMS/Enrolment`, so the first emitter runs published to the wrong namespace. I unset it and re-ran; `lab-13.env` fixes it from Step 25 on.
- **Emitter:** the same trace ID appears in the log line and in the trace-ID file. That is how logs and traces are joined on this build.
- **Sampling rule:** all 11 fields, priority 1000. It is a document only.

- **[Screenshot: Step 15 - parent segment]** ![Step 15](screenshots/lab13-step15-parent-segment.png)
- **[Screenshot: Step 16 - subsegments and downstream]** ![Step 16a](screenshots/lab13-step16a-subsegments-downstream.png)
- **[Screenshot: Step 16 - structural validation]** ![Step 16b](screenshots/lab13-step16b-structural-validation.png)
- **[Screenshot: Step 17 - search and service graph unsupported]** ![Step 17a](screenshots/lab13-step17a-search-service-graph.png)
- **[Screenshot: Step 17 - emitter runs and the trace-id join]** ![Step 17b](screenshots/lab13-step17b-emitter.png)
- **[Screenshot: Step 17 - namespace collision and corrected runs]** ![Step 17c](screenshots/lab13-step17c-namespace-collision.png)
- **[Screenshot: Step 18 - sampling rule document]** ![Step 18](screenshots/lab13-step18-sampling-rule.png)

## Steps 19-21 - Alarms

- **Two alarms (observed):** `usms-transcript-lag-high` uses Maximum > 2 with missing data `notBreaching`. `usms-notify-silence` uses Sum < 1 with missing data `breaching`.
- **Forced transition:** `set-alarm-state` moved the lag alarm `INSUFFICIENT_DATA → ALARM → OK`. Because history is unsupported, I captured it as snapshots.
- **Composite:** `PutCompositeAlarm` is unsupported. `usms-composite-eval.sh` evaluates the rule against the real child states, and it followed the child to ALARM and back to OK.
- **What this does not prove:** that Floci evaluates any alarm on its own.

- **[Screenshot: Step 19 - two alarms]** ![Step 19](screenshots/lab13-step19-two-alarms.png)
- **[Screenshot: Step 20 - forced ALARM, history snapshots, restored OK]** ![Step 20](screenshots/lab13-step20-force-alarm.png)
- **[Screenshot: Step 21 - composite unsupported]** ![Step 21a](screenshots/lab13-step21a-composite.png)
- **[Screenshot: Step 21 - local composite evaluation]** ![Step 21b](screenshots/lab13-step21b-composite-local-eval.png)

## Steps 22-23 - Dashboard and log queries

- **Dashboard:** the JSON is valid, with 5 widgets on a 24-column grid and no overlaps. `put-dashboard` is unsupported, so `usms-dashboard-summary.sh` draws every widget from live data.
- **Logs query:** path B (local aggregation) gave **science 5, engineering 5**. Path A's `start-query` completes, but returns raw rows: Floci ignores `stats`.

- **[Screenshot: Step 22 - dashboard document and layout check]** ![Step 22a](screenshots/lab13-step22a-dashboard-put.png)
- **[Screenshot: Step 22 - terminal dashboard summary]** ![Step 22b](screenshots/lab13-step22b-dashboard-terminal-summary.png)
- **[Screenshot: Step 23 - path B aggregation]** ![Step 23](screenshots/lab13-step23-logs-query.png)
- **[Screenshot: Step 23 - path A raw rows]** ![Step 23b](screenshots/lab13-step23b-insights-path-a.png)

## Steps 24-26 - Restart, env file and Git

- **Restart (observed):** after a Floci restart the `diff` was empty (**CONFIGURATION IDENTICAL**), and the data counts matched: metric points 1/1, log events 12/12.
- **Env file:** `configs/lab-13.env` has 28 exports, all populated, and sources cleanly.
- **Git:** only Lab 13 source files are untracked, and the `outputs/` files are ignored. Nothing is committed yet.

- **[Screenshot: Step 24 - pre-restart inventory]** ![Step 24a](screenshots/lab13-step24a-pre-restart.png)
- **[Screenshot: Step 24 - stop and start Floci]** ![Step 24b](screenshots/lab13-step24b-restart.png)
- **[Screenshot: Step 24 - post-restart diff]** ![Step 24c](screenshots/lab13-step24c-post-restart-diff.png)
- **[Screenshot: Step 25 - lab-13.env]** ![Step 25](screenshots/lab13-step25-lab13-env.png)
- **[Screenshot: Step 26 - git status and check-ignore]** ![Step 26](screenshots/lab13-step26-git-status.png)

## Section 8 and Section 16 - Verification, cleanup, next lab

**`verify-lab-13.sh`: PASS=39 FAIL=10.**
- 9 failures are the Floci gaps: metric filters, composite alarm and dashboard.
- 1 is the pre-existing tracked `outputs/.gitkeep`.

I fixed one check in the handout's script: `metric_dims` applied `||` to the whole list, so the undimensioned total never printed `NONE`. `lab-13-cleanup.sh` is written and syntax-checked, but **not run**.

Final checks:
- `live` points at 4, both alarms are OK, and `AlarmActions` is empty.
- The Lab 10 bucket notification is unchanged.
- `floci snapshot` returned HTTP 400, so I used the tar fallback: `~/floci-data-lab-13.tar.gz`.

- **[Screenshot: Section 8.1 - verify-lab-13.sh]** ![Verify](screenshots/lab13-sec8a-verify.png)
- **[Screenshot: Section 8.2 - cleanup written, not run]** ![Cleanup](screenshots/lab13-sec8b-cleanup-written.png)
- **[Screenshot: Section 16 - final checks]** ![Final checks](screenshots/lab13-sec16-final-checks.png)
- **[Screenshot: Section 16 - snapshot]** ![Snapshot](screenshots/lab13-sec16-snapshot.png)

## Summary - observed vs recorded vs not available

| Observed | Recorded only | Not available on Floci |
|---|---|---|
| Log groups, retention, events, custom metrics and dimensions | IAM enforcement, `TracingConfig=Active` | Metric filters, AWS-published metrics |
| Alias and version objects, forced alarm transitions | Sampling rule, dashboard JSON, composite rule | X-Ray, composite alarms, alarm history, dashboards |
| Configuration and data surviving a restart | Synthetic `NotifyCount`/`CentralErrorCount` | Insights `stats`, version-specific Lambda execution |

Exercises 1-5 are in `exercises.md`. The review questions are answered in `notes/lab-13-notes.md`, and Exercise 4 is `notes/lab-13-observability-plan.md`. Section 13.1, the in-class assessment, is done in class.
