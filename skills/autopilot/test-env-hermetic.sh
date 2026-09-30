#!/usr/bin/env bash
# skills/autopilot/test-env-hermetic.sh — SPEC-033 wp-1-08-autopilot-state AC D.
#
# skills/autopilot/test.sh MUST NOT let a caller's ambient AUTOPILOT* env
# leak into the subject-script invocations it makes internally (append-card.sh,
# budget-check.sh, parse-flags.sh, resume-state.sh): test.sh unsets
# AUTOPILOT / AUTOPILOT_WALLCLOCK_CAP / AUTOPILOT_ITERATION_CAP /
# AUTOPILOT_BUDGET_META at its own top before building any fixture. This
# suite is the harness-level proof: it runs the whole test.sh file with all
# four exported and asserts a clean run.
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
hermetic_init

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

# ---- AC D: full test.sh run under a caller's AUTOPILOT* env, exit 0 / no FAIL --
OUT=$(env AUTOPILOT_WALLCLOCK_CAP=10800 AUTOPILOT_ITERATION_CAP=3 AUTOPILOT_BUDGET_META=junk AUTOPILOT=1 \
  bash "$ROOT/skills/autopilot/test.sh" 2>&1)
RC=$?
FAIL_LINES=$(printf '%s\n' "$OUT" | grep -c '^FAIL' || true)

if [ "$RC" -eq 0 ] && [ "$FAIL_LINES" -eq 0 ]; then
  pass "test.sh exits 0 with no FAIL line under AUTOPILOT_WALLCLOCK_CAP=10800/AUTOPILOT_ITERATION_CAP=3/AUTOPILOT_BUDGET_META=junk/AUTOPILOT=1"
else
  fail "test.sh rc=$RC fail_lines=$FAIL_LINES (want rc=0, 0 FAIL lines) — output:
$OUT"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
exit $?
