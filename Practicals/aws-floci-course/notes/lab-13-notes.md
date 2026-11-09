# Lab 13 Notes - Review Questions

## 1. "We have logs, so we do not need metrics"

The first argument is cost at question time. A log line is cheap to write and expensive to ask about. Every question means scanning and parsing text: an Insights query is billed per gigabyte scanned, and on this build I had to pull every event across the network and parse it in Python (Step 23, path B). A metric is pre-aggregated as it is written. Asking "what was the maximum latency each minute today" reads a few hundred numbers, however many requests there were.

The second argument is alerting. An alarm can only evaluate a metric, never a log, so a system with only logs has nothing that wakes anyone up. Metrics can also represent an absence: a period with no data can count as breaching (`usms-notify-silence`). A log search has no row to return for "nothing happened".

The colleague is right in one situation: investigating a single event after the fact. Questions like "what happened to student stu-01044's transcript" need the detail of a log line (who, which key, which error). A metric deliberately throws that away; it is a count, not a story.

## 2. Metric filter (Step 9) vs a directly published metric (Step 11)

- **Retroactivity:** neither is retroactive. A filter starts counting only from when it is installed, and a published metric starts only once the code is deployed. Only a log query (Insights) can look back at last week.
- **Cost:** a filter costs nothing in code, but every distinct metric it produces is billed, and a dimension taken from a log field multiplies that. A direct publish also costs an API call per data point.
- **Adding a measurement:** with a filter you change configuration (a new pattern, no deployment), but it depends on the log line's wording staying stable. With a direct publish you change and redeploy the code.
- **Code that is not yours:** you can only filter its logs; you cannot add a `put_metric_data` call to someone else's binary.

For "how many transcript downloads happened" I would use a **metric filter**. The download is already a log line, a count is `metricValue=1`, and it works even for components we do not own. For "how long the render took" I would use a **direct publish**. A duration needs a precise numeric value measured where the work happens; extracting it from text depends on the log format staying the same (Exercise 1 showed how awkward that is with a `USMS_EVENT` prefix). The answers differ because counting an event is a property of the log stream, while measuring a duration is a property of the code.

## 3. notBreaching vs breaching

`usms-transcript-lag-high` with `breaching` would fire every night. Nobody uploads transcripts at 3am, so there is no latency data, and with `breaching` that empty period counts as "latency too high". That is a false page for a quiet system.

`usms-notify-silence` with `notBreaching` would **never** fire in the one situation it exists for. When the pipeline stops, `NotifyCount` stops being published, the periods are empty, `notBreaching` treats empty as fine, and the alarm stays OK forever.

The incident only the second catches: the S3 notification is removed (for example by a later lab's `put-bucket-notification-configuration`, which replaces the whole document), or the function starts failing before it logs anything. No transcript is notified, so there is no latency data either, and the lag alarm sees nothing and stays OK. The dashboard would show empty graphs, which look like a quiet day rather than an outage: no red line and no spike, just flat or missing series. This is exactly the registrar's "six hours of green dashboard" complaint.

## 4. Metric dimension vs X-Ray annotation

A **dimension** is part of a metric's identity, so each distinct combination of values is a separate, billed metric with its own time series. It is indexed for aggregation over time (sum, max, percentile per period, alarmable). Cost grows linearly with the number of distinct values, so dimensions must come from small, known sets. You can ask "what is the trend of X for value V".

An **annotation** is an indexed key/value on an individual trace. It is used to *find* specific requests (`annotation.faculty = "science"`). There are no per-value time series, so high-cardinality values are fine. You can ask "show me the traces where X = V". You cannot alarm on an annotation or graph it over time.

- **Faculty** → dimension (and also an annotation). About eight values, and we want to graph and compare throughput per faculty.
- **Student ID** → annotation (and a log field), never a dimension. Thirty thousand values would mean thirty thousand billed metrics; as an annotation it lets us find one student's traces.
- **Origin HTTP status** → neither a dimension nor an annotation. It belongs in the segment's `http.response.status` field, which X-Ray understands natively for error, fault and throttle classification. If it should be graphed, it would be a small-cardinality dimension (`StatusClass=2xx/4xx/5xx`), not the raw code.
- **Renderer name** → annotation. It is useful for finding which renderer produced a slow or broken PDF, but it is not something to alarm on per value. If there are only two or three renderers and we want to compare their latency, it could also be a dimension, so it is a judgement call.

## 5. Why tracing needed its own version

A Lambda version freezes **code and configuration together** (Lab 10 Step 11). `TracingConfig` is configuration. Changing it with `update-function-configuration` only changes `$LATEST`; the version `live` pointed at keeps the configuration it was published with. So the trace setting only reaches what S3 actually invokes after publishing a new version and moving `live` to it.

Had I changed `TracingConfig` and left `live` on the instrumented version, `get-function-configuration` without a qualifier would show `Active` and look correct. Every real invocation through the alias would still run with `PassThrough`, producing no traces and no error. In this repository the numbers are v3 (instrumented) and v4 (traced), because Lab 10's Your-turn had already used v2.

Floci itself does not honour this: it ran `$LATEST` for every qualifier. I could only check the versions' recorded configuration, not watch the frozen behaviour.

## 6. What forcing an alarm proves

Forcing `usms-transcript-lag-high` into ALARM with `set-alarm-state` proves:
- the alarm exists under the name the next lab will use;
- it can change state;
- the reason and the `synthetic` flag are stored.

On this build it also proves that I can read the transitions back from snapshots, since `DescribeAlarmHistory` is unsupported. It does **not** prove that the threshold, statistic, dimensions or unit match the published metric, or that the alarm would ever leave OK on its own. Floci never evaluates alarms.

On real AWS the same test proves what happens *after* the alarm fires: the SNS action runs, the message arrives, the on-call person receives it and the runbook link works. CloudWatch then re-evaluates and moves the state back based on the real data, which is an indirect check of the configuration.

It is worth testing the after-path even when confident in the threshold, because an alarm is only useful if someone acts on it. A perfect threshold attached to a deleted topic, a muted channel or an empty `--alarm-actions` looks identical to a working one. This is the course's rule that a command appearing to succeed is not evidence it did what you meant:
- `put-metric-alarm` succeeds silently with a unit that will never match;
- `put-metric-data` returns nothing at all;
- in this lab, `--log-type Tail` "succeeded" and returned no logs;
- invoking alias `live` at version 1 "succeeded" while actually running `$LATEST`.

Each of these looked fine, and only reading back the right thing showed otherwise.

## Floci and environment findings worth remembering

- Floci 1.5.34 does not support metric filters, Logs Insights `stats`/`parse`, X-Ray, composite alarms, alarm history or dashboards. Logs, custom metrics, metric alarms and `set-alarm-state` work.
- Lambda versions and aliases are stored, but every invocation runs `$LATEST`.
- AWS CLI 2.32 shorthand rejects `"` inside a value, so `--log-events timestamp=..,message='{"a":1}'` must be sent as JSON instead.
- `configs/lab-06.env` and `configs/lab-13.env` both export `USMS_METRIC_NAMESPACE` with different values. Source order decides which one scripts see.
