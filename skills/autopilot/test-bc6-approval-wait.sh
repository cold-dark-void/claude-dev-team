#!/usr/bin/env bash
# skills/autopilot/test-bc6-approval-wait.sh — SPEC-033 wp-1-08-autopilot-state AC J.
#
# Extracts the 00-resolve.md "### Re-mint after a human approval wait" fence
# (SPEC-033 M9a / plan C4) via tests/lib/fence.sh (C6) and runs it, self-
# contained, against a fixture ledger through the real resume-state.sh
# --accumulated and budget-check.sh. The harness never pre-sets RS/PDH/
# RESUMING as shell variables — the fence must resolve its own PDH/RS (that
# was the T3 fix-pass defect: a harness that injects the missing state masks
# the bug it is supposed to catch). Hermetic: private TMPDIR/HOME, ledger
# under a throwaway git repo (fake MROOT via git-common-dir), no live
# council, no network.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
# shellcheck source=../../tests/lib/fence.sh
. "$ROOT/tests/lib/fence.sh"
hermetic_init

RESOLVE_MD="$ROOT/skills/orchestrate/steps/00-resolve.md"
CROSS_CUTTING="$ROOT/skills/orchestrate/steps/cross-cutting.md"
RESUME="$ROOT/skills/autopilot/resume-state.sh"
BUDGET="$ROOT/skills/autopilot/budget-check.sh"
APPEND="$ROOT/skills/autopilot/append-card.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

# ---- Static: cross-cutting.md cites the wait-card-before-block + re-mint-on-reply protocol ----
if grep -qF 'approval-wait:' "$CROSS_CUTTING" \
  && grep -qi 're-mint' "$CROSS_CUTTING" \
  && grep -qF '00-resolve.md' "$CROSS_CUTTING"; then
  pass "cross-cutting.md cites the approval-wait card + 00-resolve.md re-mint fence"
else
  fail "cross-cutting.md missing the approval-wait wait-card/re-mint protocol"
fi

# ---- Static: cross-cutting.md states the SPEC-033 M9a breach rule — a
# budget already breached at the wait writes a BC6 halt card instead, with
# no re-mint (else the orchestrator would silently drop a breach). ----------
if grep -qi 'already breached' "$CROSS_CUTTING" \
  && grep -qF 'blocking_condition=6' "$CROSS_CUTTING" \
  && grep -qi 'do \*\*not\*\* run the re-mint fence' "$CROSS_CUTTING"; then
  pass "cross-cutting.md states the already-breached BC6-halt / no-re-mint rule"
else
  fail "cross-cutting.md missing the already-breached BC6-halt / no-re-mint rule"
fi

# ---- Extract the re-mint fence (C6) -----------------------------------------
REMINT_FENCE=$(fence_nth "$RESOLVE_MD" "Re-mint after a human approval wait" 1) || REMINT_FENCE=""
if [ -z "$REMINT_FENCE" ]; then
  fail "could not extract the re-mint fence from 00-resolve.md"
else
  pass "extracted the re-mint fence from 00-resolve.md"
fi

# ---- Fixture git repo (fake MROOT via git-common-dir) ----------------------
TMP=$(mktemp -d "${TMPDIR:-/tmp}/bc6-approval-wait.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

git init -q "$TMP" || { echo "FAIL: git init" >&2; exit 1; }
cd "$TMP" || { echo "FAIL: cd $TMP" >&2; exit 1; }

TICKET="TJ1"
NOW=$(date +%s)
ORIG_START=$((NOW - 30000))
CAP_ITER=40
CAP_WALL=10800

# 1) plan-approve freeze card (tier L, 40/10800) via AUTOPILOT_BUDGET_META,
#    so the wait card below inherits the same frozen caps the run carries.
META='{"iteration_cap":40,"wall_clock_cap_s":10800,"tier":"L","source":"auto","signals":{"tasks":6,"projected_loc":1200,"waves":3}}'
env AUTOPILOT_BUDGET_META="$META" bash "$APPEND" \
  orchestrate "$TICKET" plan-approve approve auto null 90 null "run-tj1" 2 500 orchestrator "plan approved" \
  >/dev/null 2>&1

# 2) approval-wait BC1 halt card: wall_clock_s 2000, iteration_cap/wall_clock_cap_s
#    carried from the freeze (40/10800), gate = last answered gate (plan-approve).
env AUTOPILOT_BUDGET_META="$META" bash "$APPEND" \
  orchestrate "$TICKET" plan-approve halt auto null 95 1 "run-tj1" 3 2000 orchestrator "approval-wait: destructive git reset needs a human" \
  >/dev/null 2>&1

ACCUM=$(bash "$RESUME" --accumulated "$TICKET" 2>/dev/null) || ACCUM=""
if [ "$ACCUM" = "2000" ]; then
  pass "resume-state.sh --accumulated reads the wait card's wall_clock_s (2000)"
else
  fail "resume-state.sh --accumulated = '$ACCUM' (want 2000)"
fi

# ---- Run the extracted re-mint fence self-contained: substitute <ISSUE-ID>
# and let it resolve its own PDH/RS via CLAUDE_PLUGIN_ROOT="$ROOT" (the real
# plugin-dir.sh + the real resume-state.sh) — never pre-set RS/PDH here. ----
run_remint() {
  # $1 = ISSUE-ID literal to substitute for <ISSUE-ID> in the fence body
  local body
  body=$(printf '%s\n' "$REMINT_FENCE" | sed "s#<ISSUE-ID>#$1#g")
  # PDH="$ROOT" is the WP 7-02 session carry: the re-mint fence takes the root
  # from env instead of resolving it; the comment below the old stanza contract
  # no longer applies to PDH (only RS is still resolved by the fence itself).
  CLAUDE_PLUGIN_ROOT="$ROOT" PDH="$ROOT" bash -c "$body"
}

if [ -n "$REMINT_FENCE" ]; then
  REMINT_OUT=$(run_remint "$TICKET" 2>"$TMP/remint.stderr")
  REMINT_RC=$?
  REMINT_STDERR=$(cat "$TMP/remint.stderr" 2>/dev/null)
  NEW_START=$(printf '%s\n' "$REMINT_OUT" | sed -n 's/^RUN_START_EPOCH=//p' | tail -n1)

  if [ "$REMINT_RC" -ne 0 ]; then
    fail "re-mint fence exited $REMINT_RC on a resolvable RS: $REMINT_STDERR"
  fi

  # RUN_START_EPOCH = a fresh "now" minus the 2000s accumulated active time —
  # NOT the current epoch (only a fresh run with zero accumulated time would
  # re-mint to "now"). Allow a couple of seconds of test-execution drift.
  WANT_LOW=$((NOW - 2000 - 2))
  WANT_HIGH=$((NOW - 2000 + 2))
  if [ -n "$NEW_START" ] && [ "$NEW_START" -ge "$WANT_LOW" ] 2>/dev/null \
    && [ "$NEW_START" -le "$WANT_HIGH" ] 2>/dev/null; then
    pass "re-mint fence sets RUN_START_EPOCH = now - 2000 (active-time-only basis)"
  else
    fail "re-mint fence RUN_START_EPOCH='$NEW_START' not in [$WANT_LOW,$WANT_HIGH]"
  fi

  # No breach from the re-minted start (2000 accumulated << 10800 cap).
  RC=0
  bash "$BUDGET" 3 "$NEW_START" "$CAP_ITER" "$CAP_WALL" >/dev/null 2>&1 || RC=$?
  if [ "$RC" -eq 0 ]; then
    pass "budget-check.sh reports no breach from the re-minted RUN_START_EPOCH"
  else
    fail "budget-check.sh rc=$RC from the re-minted RUN_START_EPOCH (want 0)"
  fi

  # Same check from the ORIGINAL (pre-wait) run start reports a wall_clock breach.
  RC=0
  BREACH_JSON=$(bash "$BUDGET" 3 "$ORIG_START" "$CAP_ITER" "$CAP_WALL" 2>/dev/null) || RC=$?
  if [ "$RC" -eq 6 ] && printf '%s' "$BREACH_JSON" | grep -q '"reason":"wall_clock"'; then
    pass "budget-check.sh reports a wall_clock breach from the original (pre-wait) run start"
  else
    fail "budget-check.sh rc=$RC (want 6, wall_clock) from the original run start"
  fi

  # RUN_ID stays whatever the caller already carries — the fence never touches it.
  RUN_ID_BEFORE="orchestrate-$TICKET-$ORIG_START"
  RUN_ID_AFTER_BODY=$(printf '%s\n' "$REMINT_FENCE" | sed "s#<ISSUE-ID>#$TICKET#g")
  if ! printf '%s' "$RUN_ID_AFTER_BODY" | grep -q 'RUN_ID='; then
    pass "re-mint fence never assigns RUN_ID (unchanged)"
  else
    fail "re-mint fence assigns RUN_ID — it must stay the Step-0 literal"
  fi
else
  fail "skipped re-mint execution checks (fence not extracted)"
fi

# ---- Ledger whose last card has wall_clock_s 11000 and no wait card still breaches ----
TICKET2="TJ2"
env AUTOPILOT_BUDGET_META="$META" bash "$APPEND" \
  orchestrate "$TICKET2" plan-approve approve auto null 90 null "run-tj2" 4 11000 orchestrator "still running" \
  >/dev/null 2>&1

if [ -n "$REMINT_FENCE" ]; then
  REMINT2_OUT=$(run_remint "$TICKET2" 2>/dev/null)
  NEW_START2=$(printf '%s\n' "$REMINT2_OUT" | sed -n 's/^RUN_START_EPOCH=//p' | tail -n1)
  RC=0
  bash "$BUDGET" 4 "$NEW_START2" "$CAP_ITER" "$CAP_WALL" >/dev/null 2>&1 || RC=$?
  if [ "$RC" -eq 6 ]; then
    pass "a ledger with wall_clock_s 11000 (no wait card) still breaches after the re-mint"
  else
    fail "rc=$RC (want 6) for the 11000-wall_clock_s ledger after re-mint"
  fi

  # ---- Negative case (G1): with RS unresolvable, the fence MUST exit
  # non-zero (fail closed) instead of silently re-minting to "now" and
  # losing the 11000s already accumulated. A plugin-dir.sh stub that
  # resolves ITSELF (so the fence's own PDH detection succeeds) but always
  # fails to resolve any OTHER relpath forces RS empty deterministically,
  # regardless of the real repo's own resume-state.sh being reachable via
  # plugin-dir.sh's worktree/marketplace/cache fallback tiers.
  NEGROOT=$(mktemp -d "${TMPDIR:-/tmp}/bc6-negroot.XXXXXX")
  mkdir -p "$NEGROOT/skills"
  cat > "$NEGROOT/skills/plugin-dir.sh" << 'NEG_EOF'
#!/usr/bin/env bash
echo "plugin-dir: stub: not found: $2" >&2
exit 3
NEG_EOF
  chmod +x "$NEGROOT/skills/plugin-dir.sh"
  NEG_BODY=$(printf '%s\n' "$REMINT_FENCE" | sed "s#<ISSUE-ID>#$TICKET2#g")
  NEG_OUT=$(CLAUDE_PLUGIN_ROOT="$NEGROOT" PDH="$NEGROOT" bash -c "$NEG_BODY" 2>"$TMP/neg.stderr")
  NEG_RC=$?
  NEG_STDERR=$(cat "$TMP/neg.stderr" 2>/dev/null)
  rm -rf "$NEGROOT"
  if [ "$NEG_RC" -eq 0 ]; then
    fail "re-mint fence exited 0 with an unresolvable RS (want non-zero)"
  elif printf '%s' "$NEG_OUT" | grep -q '^RUN_START_EPOCH='; then
    fail "re-mint fence printed RUN_START_EPOCH with an unresolvable RS"
  elif [ -z "$NEG_STDERR" ]; then
    fail "re-mint fence wrote nothing to stderr on an unresolvable RS"
  else
    pass "re-mint fence with RS unresolvable exits non-zero and prints no RUN_START_EPOCH"
  fi
fi

echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
fi
exit 1
