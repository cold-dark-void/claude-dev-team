#!/usr/bin/env bash
# router-static-test.sh — CDT-199 PR1: /orchestrate SKILL.md is a ≤80-line router.
# Greps committed protocol only (no network, no LLM).
# Run: bash skills/orchestrate/router-static-test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
SKILL="$HERE/SKILL.md"
STEPS="$HERE/steps"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

# ---- T0: SKILL.md exists + YAML name ----
if [ -f "$SKILL" ] && grep -q '^name: orchestrate$' "$SKILL"; then ok
else bad "T0 SKILL.md missing or name: orchestrate absent"; fi

# ---- T1: router ≤80 lines (always-on inject cap) ----
N=$(wc -l < "$SKILL" | tr -d ' ')
if [ "$N" -le 80 ]; then ok
else bad "T1 SKILL.md is $N lines (must be ≤80 router)"; fi

# ---- T2: load-only-current-phase contract ----
if grep -qiE 'read steps/|current (step|phase)' "$SKILL" \
  && grep -qiE 'do not Read every|only the current|not.*every steps' "$SKILL"; then
  ok
else
  bad "T2 SKILL.md missing load-only-current-phase protocol"
fi

# ---- T3: step index files exist ----
EXPECTED='
00-resolve.md
01-fetch.md
02-scope.md
03-worktree.md
04-kickoff.md
05-questions.md
06-design.md
07-tasks.md
08-execute.md
09-review.md
10-qa.md
11-ship.md
12-wrap.md
cross-cutting.md
'
missing=""
for f in $EXPECTED; do
  [ -f "$STEPS/$f" ] || missing="$missing $f"
done
if [ -z "$missing" ]; then ok
else bad "T3 missing step files:$missing"; fi

# ---- T4: no new file >1000 lines ----
over=""
while IFS= read -r path; do
  ln=$(wc -l < "$path" | tr -d ' ')
  if [ "$ln" -gt 1000 ]; then
    over="$over $(basename "$path"):$ln"
  fi
done <<EOF
$(find "$HERE" -type f -name '*.md' ! -path '*/fixtures/*')
EOF
if [ -z "$over" ]; then ok
else bad "T4 files over 1000 lines:$over"; fi

# ---- T5: monolith gone from always-on path ----
# Router must not embed the Step 8 spawn body or Step 11 ship template.
if ! grep -q 'Spawn @<agent> for Task' "$SKILL" \
  && ! grep -q 'gh pr create --title' "$SKILL"; then
  ok
else
  bad "T5 SKILL.md still embeds spawn/ship monolith bodies"
fi

# ---- T6: user-visible MUST protocol still in steps/ ----
NEEDLES='
You do NOT write code
assert-release-allowed
history dirty — rewrite needed
Orchestration complete
requires_council
self-answer.md
ensure-ticket-worktree
PM kickoff is mandatory
check-ship-history.sh
--autopilot=master
--council-tier
--resume-ship
Passive notifications
'
miss=""
# newline-safe: read line by line
while IFS= read -r needle; do
  [ -n "$needle" ] || continue
  if ! grep -rqF -- "$needle" "$STEPS"; then
    miss="$miss | $needle"
  fi
done <<EOF
$NEEDLES
EOF
if [ -z "$miss" ]; then ok
else bad "T6 protocol needles missing from steps/:$miss"; fi

# ---- T7: no commands/orchestrate.md embed of the skill ----
if [ -f "$ROOT/commands/orchestrate.md" ]; then
  bad "T7 commands/orchestrate.md exists — must not embed the skill monolith"
else
  ok
fi

echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
fi
exit 1
