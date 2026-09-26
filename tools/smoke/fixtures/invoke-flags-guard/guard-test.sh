#!/usr/bin/env bash
# Fixture: a *-test.sh script that declares --help in its own text but MUST
# NOT be invoked by --invoke-flags (SPEC-030: test scripts are never
# invoked, their bodies mutate state). If ever invoked with --help, this
# exits 1 -- proving the harness skipped invocation when this stays a PASS.
set -euo pipefail
case "${1:-}" in
  --help)
    echo "guard-test.sh: --invoke-flags MUST NOT invoke a test script" >&2
    exit 1
    ;;
esac
echo "ok"
