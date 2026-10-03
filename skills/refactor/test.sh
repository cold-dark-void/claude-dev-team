#!/usr/bin/env bash
# skills/refactor/test.sh — W3-30 static contracts (rv-w3-30 / CDT-289 05 E4 delta).
# Static greps on the committed SKILL.md + SPEC-015 only — no network, no LLM.
# Run: bash skills/refactor/test.sh
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SKILL="$HERE/SKILL.md"
SPEC015="$ROOT/specs/core/SPEC-015-refactor-workflow.md"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

# --- W3-30 1: the ensure/worktree step sits after the routing decision -------
L_221=$(grep -n '^#### 2\.2a\.1 Ticket-weight routing test' "$SKILL" | cut -d: -f1)
L_224=$(grep -n '^#### 2\.2a\.4 Worktree' "$SKILL" | cut -d: -f1)
if [ -n "$L_221" ] && [ -n "$L_224" ] && [ "$L_221" -lt "$L_224" ]; then
  ok "2.2a.4 worktree section comes after the 2.2a.1 routing test (lines $L_221 < $L_224)"
else
  bad "2.2a.4 must appear after 2.2a.1 (got $L_221 vs $L_224)"
fi

# --- W3-30 1: worktree is created only on a bounded route --------------------
if grep -qF 'Create or reuse the worktree only when the routing test (2.2a.1) returned `bounded`' "$SKILL" \
  && grep -qF 'MUST NOT create one (no create-then-release churn' "$SKILL"; then
  ok "2.2a.4 creates the worktree only on a bounded route"
else
  bad "2.2a.4 does not gate ensure on the bounded route"
fi

# --- W3-30 1: the escalating path in 2.2a.5 never ensures/releases a worktree
A5=$(awk '/^#### 2\.2a\.5 Gate outcome/,/^### 2\.3 Coverage check/' "$SKILL")
if printf '%s\n' "$A5" | grep -qF 'created no worktree' \
  && ! printf '%s\n' "$A5" | grep -q 'bash "$WT_LIB" ensure' \
  && ! printf '%s\n' "$A5" | grep -q 'worktree-lib.sh release'; then
  ok "2.2a.5 escalating path creates no worktree and runs no release"
else
  bad "2.2a.5 escalating path still ensures or releases a worktree"
fi

# --- W3-30 1: escalating outcome block records a slug, not a path ------------
if printf '%s\n' "$A5" | grep -qF 'escalating: <slug> — none created'; then
  ok "outcome block records slug-only on the escalating route"
else
  bad "outcome block Worktree: line does not record slug-only for escalating routes"
fi

# --- W3-30 2: args parse (Step 0) before project context loads (Step 1) ------
L_s0=$(grep -n '^## Step 0: Parse mode' "$SKILL" | cut -d: -f1)
L_s1=$(grep -n '^## Step 1: Load project context' "$SKILL" | cut -d: -f1)
if [ -n "$L_s0" ] && [ -n "$L_s1" ] && [ "$L_s0" -lt "$L_s1" ]; then
  ok "Step 0 parses args before Step 1 loads project context (lines $L_s0 < $L_s1)"
else
  bad "parse-mode step must precede load-context step (got $L_s0 vs $L_s1)"
fi

# --- W3-30 3: 2.2a.5 is condensed, not the old ~90-line wall -----------------
L_a5=$(grep -n '^#### 2\.2a\.5 Gate outcome' "$SKILL" | cut -d: -f1)
L_23=$(grep -n '^### 2\.3 Coverage check' "$SKILL" | cut -d: -f1)
if [ -n "$L_a5" ] && [ -n "$L_23" ] && [ "$L_23" -gt "$L_a5" ] && [ $((L_23 - L_a5)) -le 60 ]; then
  ok "2.2a.5 is condensed ($((L_23 - L_a5)) lines, cap 60)"
else
  bad "2.2a.5 grew back ($L_a5..$L_23)"
fi

# --- W3-30 4: SPEC-015 and the skill cite the same decision id (SPEC-002 D1) -
if grep -qF 'SPEC-002 D1' "$SKILL" && grep -qF 'SPEC-002 D1' "$SPEC015"; then
  ok "skill and SPEC-015 cite the same contract-home decision id (SPEC-002 D1)"
else
  bad "decision-id cite mismatch between skill and SPEC-015"
fi

# --- fences lint clean (SPEC-021) --------------------------------------------
if bash "$ROOT/skills/skill-lint/check-skill-bash.sh" "$SKILL" >/dev/null 2>&1; then
  ok "skill-lint clean on $SKILL"
else
  bad "skill-lint findings on $SKILL"
fi

echo ""
echo "refactor-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
