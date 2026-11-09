#!/usr/bin/env python3
"""Local stand-in for `aws logs test-metric-filter` (unsupported on Floci 1.5.34).

Implements only the TEXT dialect of CloudWatch filter patterns, as Lab 13 Step 8
describes it:
  TERM        the event must contain TERM as a whole token (case-sensitive)
  ?A ?B       at least one of the ?-terms must be present
  -TERM       the event must NOT contain TERM
  "a b"       a quoted term is matched as a literal substring
Tokens are split on anything that is not a letter, digit or underscore, so
USMS_NOTIFY is one token and "no ERROR here" contains the token ERROR.

This proves what the pattern logic does to sample lines. It does NOT prove
that Floci (or CloudWatch) would evaluate an installed filter at ingestion.

Usage: filter-pattern-sim.py PATTERN MESSAGE [MESSAGE ...]
Prints the same shape as test-metric-filter: {"matches": [{eventNumber, eventMessage}]}
"""

import json
import re
import shlex
import sys


def tokens(message):
    return set(re.findall(r"[A-Za-z0-9_]+", message))


def matches(pattern, message):
    terms = shlex.split(pattern)
    toks = tokens(message)

    def has(term):
        if re.fullmatch(r"[A-Za-z0-9_]+", term):
            return term in toks
        return term in message

    required = [t for t in terms if not t.startswith(("?", "-"))]
    optional = [t[1:] for t in terms if t.startswith("?")]
    excluded = [t[1:] for t in terms if t.startswith("-")]

    if not all(has(t) for t in required):
        return False
    if optional and not any(has(t) for t in optional):
        return False
    return not any(has(t) for t in excluded)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    pattern, messages = sys.argv[1], sys.argv[2:]
    result = [{"eventNumber": i, "eventMessage": m}
              for i, m in enumerate(messages, start=1) if matches(pattern, m)]
    print(json.dumps({"pattern": pattern,
                      "mode": "local simulation - test-metric-filter unsupported on this build",
                      "matches": result}, indent=2))


if __name__ == "__main__":
    main()
