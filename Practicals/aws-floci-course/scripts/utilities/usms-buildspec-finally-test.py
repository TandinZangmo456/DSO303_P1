#!/usr/bin/env python3
"""Lab 11 Exercise 2: run a buildspec locally WITH `finally` blocks.

usms-buildspec-run.sh ignores `finally`. This harness models CodeBuild's rule:
inside a phase, commands run in order until one fails; the phase's `finally`
commands then run regardless; a failed phase still fails the build.
Usage: usms-buildspec-finally-test.py <app-dir>
"""
import os, shlex, subprocess, sys, yaml

ORDER = ("install", "pre_build", "build", "post_build")
app = os.path.abspath(sys.argv[1])
doc = yaml.safe_load(open(os.path.join(app, "buildspec.yml")))

lines = ["#!/usr/bin/env bash", "set -uo pipefail", "BUILD_RC=0"]
for k, v in ((doc.get("env") or {}).get("variables") or {}).items():
    lines.append('export %s="${%s:-%s}"' % (k, k, v))
for name in ORDER:
    body = (doc.get("phases") or {}).get(name)
    if not body:
        continue
    lines += ['echo "=== phase: %s ==="' % name, "PHASE_RC=0"]
    if name != ORDER[0]:
        # CodeBuild skips later phases once the build has failed (post_build excepted)
        lines.append('if [ "$BUILD_RC" -eq 0 ] || [ "%s" = post_build ]; then' % name)
    else:
        lines.append("if true; then")
    for cmd in body.get("commands") or []:
        lines.append('  [ "$PHASE_RC" -eq 0 ] && { eval %s || PHASE_RC=$?; }' % shlex.quote(cmd))
    for cmd in body.get("finally") or []:
        lines.append('  echo "--- finally (%s) ---"; eval %s' % (name, shlex.quote(cmd)))
    lines += ["fi", '[ "$PHASE_RC" -ne 0 ] && { echo "phase %s FAILED (exit $PHASE_RC)"; BUILD_RC=$PHASE_RC; }' % name]
lines += ['echo "--- build exit status: $BUILD_RC ---"', 'exit "$BUILD_RC"']

sys.exit(subprocess.call(["bash", "-c", "\n".join(lines)], cwd=app))
