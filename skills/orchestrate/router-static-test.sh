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

# ---- T8: SKILL.md lists --tier=light|standard|full (SPEC-009 CDT-206) ----
# Accept --tier=light|standard|full or --tier=<light|standard|full> on the Arguments line.
if grep -qE -- '--tier=<?light\|standard\|full>?' "$SKILL"; then ok
else bad "T8 SKILL.md missing --tier=light|standard|full (or equivalent Arguments line)"; fi

# ---- T9: per-tier table + light step map (SPEC-009 CDT-210) ----
# standard and full near a markdown table; light row names the real light path.
if grep -E '^\|' "$SKILL" | grep -q 'standard' \
  && grep -E '^\|' "$SKILL" | grep -q 'full' \
  && grep -E '^\|' "$SKILL" | grep -qiE 'light' \
  && grep -E '^\|' "$SKILL" | grep -iE 'light' | grep -qiE 'scoper-planner' \
  && grep -E '^\|' "$SKILL" | grep -iE 'light' | grep -qiE 'skip DAG|one IC4|single-pass'; then
  ok
else
  bad "T9 SKILL.md missing per-tier table (standard/full/light + light step map)"
fi

# ---- T10: ORCH_TIER binding + light-branch form (SPEC-009 CDT-207+) ----
# Binding lives in 00-resolve.md. Later children MAY branch on exactly
# `[ "$ORCH_TIER" = "light" ]` in allowed step files. NEVER `!=`.
# Allow: 02-scope.md, 04–10, 12-wrap.md.
# FORBID: 01-fetch.md, 03-worktree.md, 11-ship.md.
# 02-scope.md may also use `[ "$ORCH_TIER" = "null" ]` (C5 auto-size) or ORCH_TIER=.
t10_fail=""
if ! grep -q 'ORCH_TIER=' "$STEPS/00-resolve.md"; then
  t10_fail="$t10_fail 00-resolve.md missing ORCH_TIER="
fi
t10_allow='02-scope.md 04-kickoff.md 05-questions.md 06-design.md 07-tasks.md 08-execute.md 09-review.md 10-qa.md 12-wrap.md'
t10_forbid='01-fetch.md 03-worktree.md 11-ship.md'
for f in $t10_forbid; do
  if grep -q 'ORCH_TIER' "$STEPS/$f"; then
    t10_fail="$t10_fail FORBID:$f"
  fi
done
for f in "$STEPS"/*.md; do
  base=$(basename "$f")
  [ "$base" = "00-resolve.md" ] && continue
  case " $t10_allow " in
    *" $base "*) continue ;;
  esac
  if grep -q 'ORCH_TIER' "$f"; then
    t10_fail="$t10_fail leaked:$base"
  fi
done
for f in $t10_allow; do
  path="$STEPS/$f"
  grep -q 'ORCH_TIER' "$path" || continue
  if grep 'ORCH_TIER' "$path" | grep -q '!='; then
    t10_fail="$t10_fail $f has !="
  fi
  while IFS= read -r line; do
    echo "$line" | grep -q 'ORCH_TIER' || continue
    case "$line" in
      *'[ "$ORCH_TIER" = "light" ]'*) continue ;;
    esac
    if [ "$f" = "02-scope.md" ]; then
      case "$line" in
        *'[ "$ORCH_TIER" = "null" ]'*) continue ;;
        *ORCH_TIER=*) continue ;;
      esac
    fi
    t10_fail="$t10_fail $f bad-form"
  done < "$path"
done
if [ -z "$t10_fail" ]; then ok
else bad "T10$t10_fail"; fi

# ---- T11: spawn-site identity (omit/standard/full else-branch) ----
# Else/default sections MUST still contain today's spawn sites.
t11_fail=""
for n in 0 1 2 3 4 5 6 7 8 9 10 11 12; do
  if ! grep -qE "^\\| $n \\|" "$SKILL"; then
    t11_fail="$t11_fail | missing step $n row"
  fi
done
if ! grep -q 'PM agent' "$STEPS/04-kickoff.md" \
  && ! grep -q '@pm' "$STEPS/04-kickoff.md"; then
  t11_fail="$t11_fail | 04-kickoff.md missing PM spawn"
fi
if ! grep -q 'Tech Lead agent' "$STEPS/04-kickoff.md" \
  && ! grep -q '@tech-lead' "$STEPS/04-kickoff.md"; then
  t11_fail="$t11_fail | 04-kickoff.md missing Tech Lead spawn"
fi
if ! grep -q 'Spawn @' "$STEPS/08-execute.md" \
  && ! grep -qi 'spawn the Claude IC' "$STEPS/08-execute.md"; then
  t11_fail="$t11_fail | 08-execute.md missing spawn instruction"
fi
if ! grep -q '@qa' "$STEPS/10-qa.md" \
  && ! grep -qi 'spawn QA' "$STEPS/10-qa.md"; then
  t11_fail="$t11_fail | 10-qa.md missing QA spawn"
fi
if ! grep -qi 'Tech Lead review' "$STEPS/09-review.md"; then
  t11_fail="$t11_fail | 09-review.md missing Tech Lead review"
fi
if ! grep -q 'check-cycle' "$STEPS/07-tasks.md"; then
  t11_fail="$t11_fail | 07-tasks.md missing DAG check-cycle"
fi
if ! grep -q 'reviewed 3+ times' "$STEPS/09-review.md"; then
  t11_fail="$t11_fail | 09-review.md missing 3-round deadloop"
fi
if [ -z "$t11_fail" ]; then ok
else bad "T11 spawn-site identity:$t11_fail"; fi

# ---- T12: light-branch exact test (C2–C4 = steps 4–10 + 12) ----
t12_fail=""
for f in 04-kickoff.md 05-questions.md 06-design.md 07-tasks.md 08-execute.md 09-review.md 10-qa.md 12-wrap.md; do
  if ! grep -Fq '[ "$ORCH_TIER" = "light" ]' "$STEPS/$f"; then
    t12_fail="$t12_fail $f"
  fi
done
if ! grep -qi 'scoper-planner' "$STEPS/04-kickoff.md"; then
  t12_fail="$t12_fail 04 missing scoper-planner"
fi
if ! grep -qi 'skip DAG' "$STEPS/07-tasks.md" && ! grep -qi 'skip DAG and task-store' "$STEPS/07-tasks.md"; then
  t12_fail="$t12_fail 07 missing skip DAG"
fi
if ! grep -q 'Spawn @ic4' "$STEPS/08-execute.md"; then
  t12_fail="$t12_fail 08 missing Spawn @ic4"
fi
if ! grep -qi 'single-pass' "$STEPS/09-review.md"; then
  t12_fail="$t12_fail 09 missing single-pass"
fi
if ! grep -qi 'do not spawn `@qa`' "$STEPS/10-qa.md" && ! grep -qi 'do not spawn @qa' "$STEPS/10-qa.md"; then
  t12_fail="$t12_fail 10 missing no-qa-spawn"
fi
if ! grep -qi 'skip Step 12b' "$STEPS/12-wrap.md"; then
  t12_fail="$t12_fail 12 missing wrap-lite"
fi
if ! grep -Fq '[ "$ORCH_TIER" = "null" ]' "$STEPS/02-scope.md"; then
  t12_fail="$t12_fail 02 missing null-test"
fi
if ! grep -q 'S → light' "$STEPS/02-scope.md"; then
  t12_fail="$t12_fail 02 missing S→light"
fi
if [ -z "$t12_fail" ]; then ok
else bad "T12 light-branch:$t12_fail"; fi

echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
fi
exit 1
