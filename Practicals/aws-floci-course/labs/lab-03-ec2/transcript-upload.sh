#!/usr/bin/env bash
# Runs on usms-web-01. Uses NO credentials: the instance profile supplies them.
set -uo pipefail
if [ $# -ne 2 ]; then
  echo "usage: $0 <student-id> <file-path>" >&2; exit 2
fi
STUDENT_ID=$1; FILE=$2
[ -n "$STUDENT_ID" ] || { echo "error: student id is empty" >&2; exit 2; }
[ -f "$FILE" ]       || { echo "error: file not found: $FILE" >&2; exit 2; }
BUCKET=usms-student-data
aws s3 cp "$FILE" "s3://${BUCKET}/transcripts/${STUDENT_ID}/$(basename "$FILE")"
