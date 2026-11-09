# USMS Observability Plan (Lab 13 Exercise 4)

A design for the registrar's office. It contains no commands. Every number says where it came from, and the ones that are guesses are labelled as guesses.

## 1. The four complaints, and the layer each needs

| Complaint | Right layer | Why not the other two |
|---|---|---|
| Transcripts stopped for six hours and the dashboard was green | **Metrics**, specifically an alarm on the *absence* of a metric | Logs record what happened, not what did not happen; nobody reads them unprompted. Traces exist only for requests that ran, and here none did. |
| We could not tell whether it was the upload, the function or the bucket | **Traces** | A metric says "slow" or "missing" across the board, not *where* inside one request. Logs from three services are separate streams with no shared key unless they carry a trace ID. A trace follows one request across S3 → notifier → renderer with a timing for each part. |
| Who downloaded a particular transcript in March? | **Logs** (a separately retained audit log) | A metric is a count and has no "who". Traces are sampled and kept for 30 days, so March would be gone, and most requests were never traced. |
| Monitoring costs more than the system | **All three**, but mostly logs and metric cardinality | See section 5. |

The second complaint has only one right answer. Lab 13 built it: the segment with `s3-head-object`, `render-pdf` and `cloudwatch-put-metric-data` subsegments shows that 74 of 120 ms were in the renderer.

## 2. Log group taxonomy and retention

| Log group | Contents | Retention | Who may read |
|---|---|---|---|
| `/usms/central/application` | Structured `USMS_EVENT` lines from every tier | 30 days | Platform team |
| `/usms/ecs/enrolment` | Enrolment container output | 30 days | Platform team |
| `/aws/lambda/usms-*` | Function runtime output (START/END/REPORT, prints) | **14 days** (shortest) | Platform team |
| `/usms/audit/transcript-access` | One line per transcript read/download: who, which student, when, from where | **2557 days, i.e. 7 years** (longest) | Registrar's audit office and security only. **Not** the platform team. |

- **Why 14 days is the shortest:** function output is debugging data. If nobody looked at it within two weeks of an incident, nobody will. It is also the noisiest group by volume. This number is a judgement.
- **Why 7 years is the longest:** the audit question ("who downloaded it in March") is a records-retention question, not an engineering one. Seven years is a common figure for academic records, but I would **verify it with the university's records policy and the applicable data-protection rules** before committing to it. It may be shorter, and keeping personal data longer than required is itself a risk.
- The audit group is separate because a log group is the unit of retention and access control (Lab 13 Step 6). Putting audit lines in the central group would force either 7-year retention on all application noise or 30-day retention on audit evidence. It should be encrypted with its own KMS key, so that read access is granted by key policy, and the key should not be readable by the platform role.

## 3. Service level indicators for transcript delivery

An SLI is something a student would notice.

| SLI | Target (SLO) | Alarm or graph? |
|---|---|---|
| **Delivery success:** notifications sent ÷ transcripts uploaded, per hour | 99.5% over 28 days | **Alarm** (via the composite) when the ratio drops sharply. A failed transcript is the thing students complain about. |
| **Delivery latency:** time from upload to notification, p95 | p95 under 2 s | **Alarm** on sustained breach (2 of 3 minutes over 2 s = `usms-transcript-lag-high`). The 2 s comes from the Lab 13 alarm. My only real data is the Exercise 5 baseline (max 3.1 s from synthetic runs), so it must be re-derived from production data. |
| **Freshness:** minutes since the last successful notification during working hours | Never more than 15 minutes between 08:00 and 18:00 | **Alarm** (`usms-notify-silence`). This is the one that catches the six-hour outage. |
| Render time per page (supporting indicator) | none | **Graph only** |

The un-alarmed render-time graph is not wasted. It is what you look at *after* the latency alarm fires to see whether the renderer caused it, and it shows slow drift weeks before it becomes an outage. Alarming on it would page people for things students do not notice.

## 4. Alarms and missing-data policy

| Alarm | Metric | Missing data | Pages? |
|---|---|---|---|
| `usms-transcript-lag-high` | `TranscriptLagSeconds` Max > 2 s, 2 of 3 × 60 s | `notBreaching` (no uploads at night is normal) | No (ticket) |
| `usms-notify-silence` | `NotifyCount` Sum < 1, 3 of 3 × 300 s | **`breaching`** (silence is the failure) | No (ticket) |
| `usms-delivery-ratio-low` (new) | metric math: sent ÷ uploaded < 0.95, 2 of 3 × 300 s | `notBreaching` | No (ticket) |
| `usms-transcript-pipeline-down` | **Composite:** any of the above in ALARM | n/a | **Yes**, the only page |

**`usms-notify-silence` is the alarm that would have caught the six-hour outage.** A threshold alarm on a *value* cannot catch it: when the pipeline stops, no values are published at all. Every threshold comparison needs a data point to compare, and with the default missing-data setting the alarm just keeps its last state, OK. Only an alarm that treats *missing* as *breaching* turns silence into a signal.

Fifteen minutes is a guess. During exam-result week uploads are continuous, but at weekends there are none. Before committing I would measure the longest normal gap between notifications during working hours over a month. The window should be longer than that gap, and limited to working hours so it does not fire every Saturday.

## 5. Where the monitoring bill goes

These are orders of magnitude only. I would verify every price on the current CloudWatch and X-Ray pricing pages, since they change and differ by region.

1. **Log ingestion (largest).** Billed per GB ingested. Lambda START/END/REPORT lines and verbose container output are most of the volume. Logs kept forever (every group was `None` in Step 5) add storage cost every month.
2. **Custom metrics.** Billed per metric per month, and each distinct dimension combination is one metric. A `StudentId` dimension would be about 30,000 metrics, which on its own could exceed the cost of the application.
3. **Logs Insights scans.** Billed per GB scanned. A month-long query over `@message` on a large group is expensive every time someone runs it.
4. **X-Ray traces.** Billed per trace recorded and retrieved. Without a sampling rule this grows with traffic.
5. **Alarms and dashboards.** Small, and a fixed number.

**The two changes with the largest effect:**
1. Retention on every group and less verbose Lambda logging.
2. Keeping metric dimensions to small, known sets.

**Cardinality of every proposed dimension:**
- `Faculty`: about 8 values. That is a guess from a typical university; I would check against the student records system.
- `Stage`: 3 values (`notify`, `render`, `viewer-request`).
- `StatusClass`, if added: 3 values (`2xx`, `4xx`, `5xx`).
- Worst case for `TranscriptsProcessed`: 8 × 3 = 24 metrics, plus the undimensioned total.

Student ID, transcript key and renderer host are **never** dimensions; they go in log fields and X-Ray annotations. Lab 13 Step 13 caught the notifier deriving `Faculty=evidence` from the test path `transcripts/evidence/`. Path-derived dimension values need an allow-list, not just the `isalpha()` guard.

Sampling: the reservoir of 2 per second plus 10% (`usms-transcripts-sampling`) caps trace cost during exam-result spikes while still tracing every request on a quiet day.

## 6. What I would not build yet

**I would not build anomaly-detection alarms or per-faculty latency alarms yet.** There is no production baseline: every latency number I have came from the emitter script with values I typed. Anomaly detection trained on that would learn my test data. Per-faculty alarms would multiply the alarm count by eight with no evidence that faculties behave differently.

**What would change my mind:** four to six weeks of production `TranscriptLagSeconds` data showing a stable daily and weekly pattern, which would make anomaly detection meaningful. For per-faculty alarms, it would take a real incident where one faculty's transcripts failed while the overall ratio stayed healthy.

**What I would measure before committing to any of this:**
- the real distribution of upload-to-notification latency (p50, p95, max) over a month;
- the longest normal gap between notifications during working hours;
- the actual log volume per group per day.

Those three numbers set the latency threshold, the silence window and most of the bill.
