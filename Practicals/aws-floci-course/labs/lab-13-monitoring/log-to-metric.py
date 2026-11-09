#!/usr/bin/env python3
"""Exercise 1 substitute for a value-extracting metric filter.

PutMetricFilter is unsupported on Floci 1.5.34, so this does by hand what
  filter usms-transcript-seconds on /usms/central/application
  pattern  USMS_EVENT lines carrying a "seconds" field
  metricValue = the extracted seconds   (not the constant 1)
would do at ingestion: read the matching events, extract the value from each
line, and publish one TranscriptSecondsFromLogs data point per event with the
event's own timestamp.

It proves the extraction logic and that the values round-trip. It does NOT
prove that CloudWatch would run it at ingestion, and unlike a real filter it is
not automatic: it must be re-run, and it only sees events since --since-ms.

Usage: log-to-metric.py --since-ms EPOCH_MS [--dry-run]
"""

import argparse
import datetime
import json
import subprocess

GROUP = "/usms/central/application"
NAMESPACE = "USMS/Application"
METRIC = "TranscriptSecondsFromLogs"


def aws(*args):
    out = subprocess.run(["aws", *args, "--output", "json"],
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out) if out.strip() else {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--since-ms", type=int, required=True)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    events = aws("logs", "filter-log-events", "--log-group-name", GROUP,
                 "--filter-pattern", "USMS_EVENT",
                 "--start-time", str(args.since_ms)).get("events", [])

    published = []
    for ev in events:
        _, sep, payload = ev["message"].partition("USMS_EVENT ")
        if not sep:
            continue
        try:
            seconds = json.loads(payload).get("seconds")
        except json.JSONDecodeError:
            continue
        if not isinstance(seconds, (int, float)):
            continue        # a real filter publishes nothing for a non-matching line
        ts = datetime.datetime.fromtimestamp(ev["timestamp"] / 1000, datetime.timezone.utc)
        datum = {"MetricName": METRIC, "Timestamp": ts.isoformat().replace("+00:00", "Z"),
                 "Unit": "Seconds", "Value": seconds}
        if not args.dry_run:
            aws("cloudwatch", "put-metric-data", "--namespace", NAMESPACE,
                "--metric-data", json.dumps([datum]))
        published.append({"timestamp": datum["Timestamp"], "seconds": seconds})

    print(json.dumps({"metric": "%s %s" % (NAMESPACE, METRIC),
                      "mode": "local extraction - PutMetricFilter unsupported on this build",
                      "dry_run": args.dry_run, "published": published}, indent=2))


if __name__ == "__main__":
    main()
