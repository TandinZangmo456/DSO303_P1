#!/usr/bin/env bash
# Generate templates/lab-13-dashboard.json (Lab 13 Exercise 2) from the course
# environment instead of literals: account id from configs/lab-01.env, region
# from configs/course.env. Re-runnable; the output file holds values, not commands.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/lab-01.env"

ACCOUNT="${USMS_ACCOUNT_ID:?USMS_ACCOUNT_ID unset - source configs/lab-01.env}"
REGION="${AWS_REGION_COURSE:?AWS_REGION_COURSE unset - source configs/course.env}"
ALARM_ARN="arn:aws:cloudwatch:${REGION}:${ACCOUNT}:alarm"

cat > templates/lab-13-dashboard.json << EOF
{
  "widgets": [
    {
      "type": "text",
      "x": 0, "y": 0, "width": 24, "height": 2,
      "properties": {
        "markdown": "# USMS - transcript delivery\nOwner: platform team · Runbook: notes/lab-13-runbook.md · Alarms page the composite alarm only."
      }
    },
    {
      "type": "metric",
      "x": 0, "y": 2, "width": 12, "height": 6,
      "properties": {
        "title": "Transcripts processed, by faculty",
        "region": "${REGION}",
        "stat": "Sum",
        "period": 300,
        "view": "timeSeries",
        "stacked": false,
        "metrics": [
          [ "USMS/Application", "TranscriptsProcessed", "Faculty", "science", "Stage", "notify" ],
          [ "USMS/Application", "TranscriptsProcessed", "Faculty", "engineering", "Stage", "notify" ]
        ]
      }
    },
    {
      "type": "metric",
      "x": 12, "y": 2, "width": 12, "height": 6,
      "properties": {
        "title": "Notification latency - max and average",
        "region": "${REGION}",
        "period": 60,
        "view": "timeSeries",
        "metrics": [
          [ "USMS/Application", "TranscriptLagSeconds", "Stage", "notify", { "stat": "Maximum", "label": "max" } ],
          [ "USMS/Application", "TranscriptLagSeconds", "Stage", "notify", { "stat": "Average", "label": "avg" } ]
        ],
        "annotations": {
          "horizontal": [
            { "label": "alarm threshold", "value": 2 }
          ]
        }
      }
    },
    {
      "type": "metric",
      "x": 0, "y": 8, "width": 8, "height": 4,
      "properties": {
        "title": "Notifications in the last 5 minutes",
        "region": "${REGION}",
        "stat": "Sum",
        "period": 300,
        "view": "singleValue",
        "metrics": [
          [ "USMS/Application", "NotifyCount" ],
          [ "USMS/Application", "CentralErrorCount" ]
        ]
      }
    },
    {
      "type": "alarm",
      "x": 8, "y": 8, "width": 16, "height": 4,
      "properties": {
        "title": "Pipeline alarms",
        "alarms": [
          "${ALARM_ARN}:usms-transcript-pipeline-down",
          "${ALARM_ARN}:usms-transcript-lag-high",
          "${ALARM_ARN}:usms-notify-silence"
        ]
      }
    },
    {
      "type": "metric",
      "x": 0, "y": 12, "width": 24, "height": 6,
      "properties": {
        "title": "Central log errors - last 3 hours",
        "region": "${REGION}",
        "stat": "Sum",
        "period": 300,
        "start": "-PT3H",
        "view": "timeSeries",
        "metrics": [
          [ "USMS/Application", "CentralErrorCount" ]
        ],
        "annotations": {
          "horizontal": [
            { "label": "page if sustained (proposed)", "value": 5 }
          ]
        }
      }
    }
  ]
}
EOF

python3 -m json.tool templates/lab-13-dashboard.json > /dev/null && echo "generated templates/lab-13-dashboard.json (account ${ACCOUNT}, region ${REGION})"
