#!/usr/bin/env bash
# Static checks for full-mode commit and exit (W2-41).
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SKILL="$HERE/SKILL.md"
SPEC="$HERE/../../specs/core/SPEC-014-debug-workflow.md"
REFACTOR="$HERE/../refactor/SKILL.md"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }
grep -qF '### 2.7a Commit the fix' "$SKILL" && ok "2.7a heading" || bad "2.7a heading"
grep -qF '### 2.10a Bounded exit' "$SKILL" && ok "2.10a heading" || bad "2.10a heading"
grep -qF 'The P.2a escalation gate still runs' "$SKILL" && ok "patch keeps P.2a" || bad "patch keeps P.2a"
grep -qF '§ 2.4a branch' "$SPEC" && ok "SPEC-014 names 2.7a branch" || bad "SPEC-014 2.7a"
grep -qF '§ 2.10a' "$SPEC" && ok "SPEC-014 names 2.10a" || bad "SPEC-014 2.10a"
grep -qF 'owns the exit' "$REFACTOR" && ok "refactor 2.4 caller owns exit" || bad "refactor owns exit"
if grep -qF 'Do NOT apply the same fix in multiple places' "$SKILL"; then
  bad "old same-fix ban still present"
else
  ok "same-fix ban is gone"
fi
grep -qF 'at scope time (§ 2.4)' "$SPEC" && ok "SPEC same-fix ban is scope time" || bad "SPEC scope-time ban"
if grep -qF 'always a refactor trigger' "$SPEC"; then
  bad "SPEC still says every same-fix is a refactor"
else
  ok "SPEC dropped the always-a-refactor line"
fi
grep -qF 'full` mode only' "$SPEC" && ok "SPEC commit MUST is full mode" || bad "SPEC commit MUST scope"
grep -qF 'The P.2a escalation gate still runs' "$SPEC" && ok "SPEC T7 keeps P.2a" || bad "SPEC T7 P.2a"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
