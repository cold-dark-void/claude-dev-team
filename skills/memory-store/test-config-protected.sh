#!/usr/bin/env bash
# covers: SPEC-007/T1
# Runs the shipped Step 5a fence in commands/memory.md. A protected key must
# exit 1. A settable key must fall through.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=../../tests/lib/fence.sh
. "$ROOT/tests/lib/fence.sh"
# shellcheck source=../../tests/lib/check.sh
. "$ROOT/tests/lib/check.sh"
pass=0
fail=0

FENCE=$(fence_nth "$ROOT/skills/memory-store/modes/config.md" "Step 5a: Reject read-only" 1) || FENCE=""
if [ -n "$FENCE" ]; then
  pass_line "Step 5a fence extracted"
else
  fail_line "Step 5a fence extracted"
  echo "memory config protected: $pass passed, $fail failed"
  exit 1
fi

run() { # run KEY
  KEY=$1 bash -c "$FENCE" >"$WORK" 2>&1
  echo $?
}
WORK=$(mktemp "${TMPDIR:-/tmp}/mem-cfg.XXXXXX")
trap 'rm -f "$WORK"' EXIT

RC=$(run distilling_lock)
[ "$RC" -eq 1 ] && grep -q "cannot be set manually" "$WORK" \
  && pass_line "distilling_lock rejected" || fail_line "distilling_lock rejected rc=$RC"

RC=$(run schema_version)
[ "$RC" -eq 1 ] && grep -q "managed by migrations" "$WORK" \
  && pass_line "schema_version rejected" || fail_line "schema_version rejected rc=$RC"

RC=$(run distill_enabled)
[ "$RC" -eq 0 ] && pass_line "distill_enabled is settable" || fail_line "distill_enabled rc=$RC"

echo "memory config protected: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
