#!/usr/bin/env bash
# WP 2-09 — simplify checkpoints before it edits, reverts with reset --hard,
# includes the changed set, and a manual run routes to /refactor.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$ROOT/skills/code-simplify/SKILL.md"
STEP="$ROOT/skills/orchestrate/steps/09-review.md"
fail=0
check() {
  if grep -qF -- "$2" "$1"; then echo "OK: $3"; else echo "FAIL: $3"; fail=1; fi
}
check "$SKILL" 'chore: pre-simplify checkpoint' "skill commits a pre-simplify checkpoint"
check "$SKILL" 'git reset --hard "$PRE_SIMPLIFY_SHA"' "skill reverts with reset --hard"
check "$SKILL" 'skills/lib/changed-set.sh' "skill scope uses the changed set"
check "$SKILL" '/refactor' "manual invocation points at /refactor"
check "$STEP" 'git diff "$PRE_SIMPLIFY_SHA"' "orchestrate step 9.5 delta-reviews the simplify edit"
exit $fail
