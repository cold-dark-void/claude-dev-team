#!/usr/bin/env bash
# skills/autopilot/test-card-validation.sh — SPEC-033 wp-1-08-autopilot-state AC A, B.
#
# AC A: append-card.sh / budget-check.sh validate every numeric card argument
# and env cap BY PATTERN before any arithmetic (AC9): a malformed value exits
# 64, names the field/variable on stderr, and appends no ledger line. Also
# checks self-answer.md's AC9 wording (drops "never external input", states
# the env caps are external input).
#
# AC B: self-answer.md §3f holds ONE bash fence (interface contract C5) that
# reads the freeze via read-cards.sh, calls budget-check.sh, and calls
# append-card.sh. Extracted via tests/lib/fence.sh (C6) and run in a fresh
# shell against a fixture ledger.
#
# Runs no live council; writes only under a hermetic TMPDIR (never the real
# .claude/autopilot/). THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
hermetic_init

SCRIPT_DIR="$ROOT/skills/autopilot"
APPEND="$SCRIPT_DIR/append-card.sh"
BUDGET="$SCRIPT_DIR/budget-check.sh"
READ="$SCRIPT_DIR/read-cards.sh"
SELF_ANSWER="$SCRIPT_DIR/self-answer.md"
FENCE_LIB="$ROOT/tests/lib/fence.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

if ! command -v jq >/dev/null 2>&1; then
  fail "jq not found; cannot run this suite"
  echo "PASS=$PASS FAIL=$FAIL"
  exit 1
fi

# ---- Hermetic fixture git repo (fake MROOT via git-common-dir) -------------
FX="$HERMETIC_ROOT/mroot"
mkdir -p "$FX"
git init -q "$FX" || { echo "FAIL: git init" >&2; exit 1; }
cd "$FX" || { echo "FAIL: cd $FX" >&2; exit 1; }
AUTODIR="$FX/.claude/autopilot"
reset() { rm -rf "$AUTODIR"; }
ledger() { echo "$AUTODIR/$1.jsonl"; }

# run_capture <cmd...> -> sets G_OUT, G_ERR, G_RC. Never trips set -e (none set).
run_capture() {
  local errfile
  errfile=$(mktemp "${TMPDIR:-/tmp}/tcv-err.XXXXXX")
  G_OUT=$("$@" 2>"$errfile")
  G_RC=$?
  G_ERR=$(cat "$errfile")
  rm -f "$errfile"
}

# error_names <substring> -> the captured stderr has a line starting "error: "
# that contains <substring>. Anchoring on "^error: " avoids a vacuous match
# against the USAGE line (which lists every field name).
error_names() {
  printf '%s\n' "$G_ERR" | grep -q "^error: .*$1"
}

no_ledger() {
  # $1 = ticket_id used by the case. True iff no (or empty) ledger line exists.
  local l
  l=$(ledger "$1")
  [ ! -s "$l" ]
}

# =============================================================================
# AC A — append-card.sh: confidence pattern (reject 007 / 101 / abc / huge int)
# =============================================================================
reset
run_capture bash "$APPEND" orchestrate CDT-A1 plan-approve proceed auto null \
  99999999999999999999999 null run-1 1 10 orch "r"
if [ "$G_RC" -eq 64 ] && error_names "confidence" && no_ledger CDT-A1; then
  pass "a1 confidence 23-digit -> 64, names confidence, no ledger line"
else
  fail "a1 rc=$G_RC err=$G_ERR"
fi

reset
run_capture bash "$APPEND" orchestrate CDT-A2 plan-approve proceed auto null \
  abc null run-1 1 10 orch "r"
if [ "$G_RC" -eq 64 ] && error_names "confidence" && no_ledger CDT-A2; then
  pass "a2 confidence=abc -> 64, names confidence"
else
  fail "a2 rc=$G_RC err=$G_ERR"
fi

reset
run_capture bash "$APPEND" orchestrate CDT-A3 plan-approve proceed auto null \
  101 null run-1 1 10 orch "r"
if [ "$G_RC" -eq 64 ] && error_names "confidence" && no_ledger CDT-A3; then
  pass "a3 confidence=101 -> 64, names confidence"
else
  fail "a3 rc=$G_RC err=$G_ERR"
fi

reset
run_capture bash "$APPEND" orchestrate CDT-A4 plan-approve proceed auto null \
  007 null run-1 1 10 orch "r"
if [ "$G_RC" -eq 64 ] && error_names "confidence" && no_ledger CDT-A4; then
  pass "a4 confidence=007 -> 64 (leading zero rejected), names confidence"
else
  fail "a4 rc=$G_RC err=$G_ERR"
fi

# Positive controls: 0 and 100 are legal confidence values.
reset
run_capture bash "$APPEND" orchestrate CDT-A5 plan-approve proceed auto null \
  0 null run-1 1 10 orch "r"
if [ "$G_RC" -eq 0 ] && jq -e '.confidence == 0' "$(ledger CDT-A5)" >/dev/null 2>&1; then
  pass "a5 confidence=0 -> rc 0, card written"
else
  fail "a5 rc=$G_RC err=$G_ERR"
fi

reset
run_capture bash "$APPEND" orchestrate CDT-A6 plan-approve proceed auto null \
  100 null run-1 1 10 orch "r"
if [ "$G_RC" -eq 0 ] && jq -e '.confidence == 100' "$(ledger CDT-A6)" >/dev/null 2>&1; then
  pass "a6 confidence=100 -> rc 0, card written"
else
  fail "a6 rc=$G_RC err=$G_ERR"
fi

# =============================================================================
# AC A — append-card.sh: blocking_condition pattern (reject 9 / huge int)
# =============================================================================
reset
run_capture bash "$APPEND" orchestrate CDT-A7 plan-approve halt auto null \
  70 99999999999999999999999 run-1 1 10 orch "r"
if [ "$G_RC" -eq 64 ] && error_names "blocking_condition" && no_ledger CDT-A7; then
  pass "a7 blocking_condition 23-digit -> 64, names blocking_condition"
else
  fail "a7 rc=$G_RC err=$G_ERR"
fi

reset
run_capture bash "$APPEND" orchestrate CDT-A8 plan-approve halt auto null \
  70 9 run-1 1 10 orch "r"
if [ "$G_RC" -eq 64 ] && error_names "blocking_condition" && no_ledger CDT-A8; then
  pass "a8 blocking_condition=9 -> 64, names blocking_condition"
else
  fail "a8 rc=$G_RC err=$G_ERR"
fi

# Positive controls: 1, 8, and null are legal.
reset
run_capture bash "$APPEND" orchestrate CDT-A9 plan-approve halt auto null \
  50 1 run-1 1 10 orch "r"
[ "$G_RC" -eq 0 ] && pass "a9 blocking_condition=1 -> rc 0" || fail "a9 rc=$G_RC err=$G_ERR"

reset
run_capture bash "$APPEND" orchestrate CDT-A10 plan-approve halt auto null \
  50 8 run-1 1 10 orch "r"
[ "$G_RC" -eq 0 ] && pass "a10 blocking_condition=8 -> rc 0" || fail "a10 rc=$G_RC err=$G_ERR"

# blocking_condition=7 + confidence=80 still exits 64 (cross-field invariant
# survives the new pattern check — both fields are now pre-validated ints).
reset
run_capture bash "$APPEND" orchestrate CDT-A11 plan-approve halt auto null \
  80 7 run-1 1 10 orch "r"
if [ "$G_RC" -eq 64 ] && no_ledger CDT-A11; then
  pass "a11 blocking_condition=7 + confidence=80 -> 64 (invariant b)"
else
  fail "a11 rc=$G_RC err=$G_ERR"
fi

# =============================================================================
# AC A — append-card.sh: iteration / wall_clock_s (16 digits or a letter -> 64)
# =============================================================================
reset
run_capture bash "$APPEND" orchestrate CDT-A12 plan-approve proceed auto null \
  70 null run-1 1234567890123456 10 orch "r"
if [ "$G_RC" -eq 64 ] && error_names "iteration" && no_ledger CDT-A12; then
  pass "a12 iteration 16-digit -> 64, names iteration"
else
  fail "a12 rc=$G_RC err=$G_ERR"
fi

reset
run_capture bash "$APPEND" orchestrate CDT-A13 plan-approve proceed auto null \
  70 null run-1 12a 10 orch "r"
if [ "$G_RC" -eq 64 ] && error_names "iteration" && no_ledger CDT-A13; then
  pass "a13 iteration with a letter -> 64, names iteration"
else
  fail "a13 rc=$G_RC err=$G_ERR"
fi

reset
run_capture bash "$APPEND" orchestrate CDT-A14 plan-approve proceed auto null \
  70 null run-1 1 1234567890123456 orch "r"
if [ "$G_RC" -eq 64 ] && error_names "wall_clock_s" && no_ledger CDT-A14; then
  pass "a14 wall_clock_s 16-digit -> 64, names wall_clock_s"
else
  fail "a14 rc=$G_RC err=$G_ERR"
fi

reset
run_capture bash "$APPEND" orchestrate CDT-A15 plan-approve proceed auto null \
  70 null run-1 1 10x orch "r"
if [ "$G_RC" -eq 64 ] && error_names "wall_clock_s" && no_ledger CDT-A15; then
  pass "a15 wall_clock_s with a letter -> 64, names wall_clock_s"
else
  fail "a15 rc=$G_RC err=$G_ERR"
fi

# Positive controls: 0 and a 15-digit value are legal (AC9 boundary).
reset
run_capture bash "$APPEND" orchestrate CDT-A16 plan-approve proceed auto null \
  70 null run-1 0 999999999999999 orch "r"
if [ "$G_RC" -eq 0 ] && jq -e '.budget.iteration == 0 and .budget.wall_clock_s == 999999999999999' \
  "$(ledger CDT-A16)" >/dev/null 2>&1; then
  pass "a16 iteration=0, wall_clock_s=15-nines -> rc 0"
else
  fail "a16 rc=$G_RC err=$G_ERR"
fi

# =============================================================================
# AC A — append-card.sh: AUTOPILOT_ITERATION_CAP / AUTOPILOT_WALLCLOCK_CAP,
# validated when read (META unset) -> 64, names the variable.
# =============================================================================
reset
run_capture env -u AUTOPILOT_BUDGET_META AUTOPILOT_ITERATION_CAP=abc \
  bash "$APPEND" orchestrate CDT-A17 plan-approve proceed auto null 70 null run-1 1 10 orch "r"
if [ "$G_RC" -eq 64 ] && error_names "AUTOPILOT_ITERATION_CAP" && no_ledger CDT-A17; then
  pass "a17 AUTOPILOT_ITERATION_CAP=abc (META unset) -> 64, names the variable"
else
  fail "a17 rc=$G_RC err=$G_ERR"
fi

reset
run_capture env -u AUTOPILOT_BUDGET_META AUTOPILOT_ITERATION_CAP=1234567890123456 \
  bash "$APPEND" orchestrate CDT-A18 plan-approve proceed auto null 70 null run-1 1 10 orch "r"
if [ "$G_RC" -eq 64 ] && error_names "AUTOPILOT_ITERATION_CAP" && no_ledger CDT-A18; then
  pass "a18 AUTOPILOT_ITERATION_CAP 16-digit (META unset) -> 64"
else
  fail "a18 rc=$G_RC err=$G_ERR"
fi

reset
run_capture env -u AUTOPILOT_BUDGET_META AUTOPILOT_WALLCLOCK_CAP=abc \
  bash "$APPEND" orchestrate CDT-A19 plan-approve proceed auto null 70 null run-1 1 10 orch "r"
if [ "$G_RC" -eq 64 ] && error_names "AUTOPILOT_WALLCLOCK_CAP" && no_ledger CDT-A19; then
  pass "a19 AUTOPILOT_WALLCLOCK_CAP=abc (META unset) -> 64, names the variable"
else
  fail "a19 rc=$G_RC err=$G_ERR"
fi

reset
run_capture env -u AUTOPILOT_BUDGET_META AUTOPILOT_WALLCLOCK_CAP=1234567890123456 \
  bash "$APPEND" orchestrate CDT-A20 plan-approve proceed auto null 70 null run-1 1 10 orch "r"
if [ "$G_RC" -eq 64 ] && error_names "AUTOPILOT_WALLCLOCK_CAP" && no_ledger CDT-A20; then
  pass "a20 AUTOPILOT_WALLCLOCK_CAP 16-digit (META unset) -> 64"
else
  fail "a20 rc=$G_RC err=$G_ERR"
fi

# Positive control (M9b): META set + a junk env cap alongside it -> rc 0, and
# the card carries META's caps (env is NOT re-applied when META is set).
reset
META_OK='{"iteration_cap":9,"wall_clock_cap_s":99,"tier":"S","source":"env","signals":{"tasks":1,"projected_loc":1,"waves":1}}'
run_capture env AUTOPILOT_BUDGET_META="$META_OK" AUTOPILOT_ITERATION_CAP=abc \
  bash "$APPEND" orchestrate CDT-A21 plan-approve proceed auto null 70 null run-1 1 10 orch "r"
if [ "$G_RC" -eq 0 ] && jq -e '.budget.iteration_cap == 9 and .budget.wall_clock_cap_s == 99' \
  "$(ledger CDT-A21)" >/dev/null 2>&1; then
  pass "a21 META set + junk AUTOPILOT_ITERATION_CAP -> rc 0, META caps win (env not re-applied)"
else
  fail "a21 rc=$G_RC err=$G_ERR"
fi

# =============================================================================
# AC A — budget-check.sh: iteration / run_start_epoch (16 digits -> 64)
# =============================================================================
NOW=$(date +%s)

run_capture bash "$BUDGET" 1234567890123456 "$NOW"
if [ "$G_RC" -eq 64 ] && error_names "iteration"; then
  pass "a22 budget-check iteration 16-digit -> 64, names iteration"
else
  fail "a22 rc=$G_RC err=$G_ERR"
fi

run_capture bash "$BUDGET" 1 1234567890123456
if [ "$G_RC" -eq 64 ] && error_names "run_start_epoch"; then
  pass "a23 budget-check run_start_epoch 16-digit -> 64, names run_start_epoch"
else
  fail "a23 rc=$G_RC err=$G_ERR"
fi

# argc=4 caps: same 15-digit rule applies to iteration_cap / wall_clock_cap_s.
run_capture bash "$BUDGET" 1 "$NOW" 1234567890123456 100
if [ "$G_RC" -eq 64 ] && error_names "iteration_cap"; then
  pass "a24 budget-check argc4 iteration_cap 16-digit -> 64"
else
  fail "a24 rc=$G_RC err=$G_ERR"
fi

# Positive control: a 15-digit cap is legal; iteration=1 and wall_clock_s=0
# stay well under a 15-nines cap, so this must not breach or be rejected.
run_capture bash "$BUDGET" 1 "$NOW" 999999999999999 999999999999999
if [ "$G_RC" -eq 0 ]; then
  pass "a25 budget-check 15-digit caps, within budget -> rc 0"
else
  fail "a25 rc=$G_RC out=$G_OUT err=$G_ERR"
fi

# =============================================================================
# AC A — budget-check.sh: AUTOPILOT_ITERATION_CAP / AUTOPILOT_WALLCLOCK_CAP
# (argc=2 path), validated when read -> 64, names the variable.
# =============================================================================
run_capture env AUTOPILOT_ITERATION_CAP=abc bash "$BUDGET" 1 "$NOW"
if [ "$G_RC" -eq 64 ] && error_names "AUTOPILOT_ITERATION_CAP"; then
  pass "a26 budget-check AUTOPILOT_ITERATION_CAP=abc -> 64, names the variable"
else
  fail "a26 rc=$G_RC err=$G_ERR"
fi

run_capture env AUTOPILOT_WALLCLOCK_CAP=1234567890123456 bash "$BUDGET" 1 "$NOW"
if [ "$G_RC" -eq 64 ] && error_names "AUTOPILOT_WALLCLOCK_CAP"; then
  pass "a27 budget-check AUTOPILOT_WALLCLOCK_CAP 16-digit -> 64"
else
  fail "a27 rc=$G_RC err=$G_ERR"
fi

# G2: the other two combinations (speccheck flagged only abc/16-digit were
# tested, one per variable, not both variables x both bad shapes).
run_capture env AUTOPILOT_ITERATION_CAP=1234567890123456 bash "$BUDGET" 1 "$NOW"
if [ "$G_RC" -eq 64 ] && error_names "AUTOPILOT_ITERATION_CAP"; then
  pass "a26b budget-check AUTOPILOT_ITERATION_CAP 16-digit -> 64, names the variable"
else
  fail "a26b rc=$G_RC err=$G_ERR"
fi

run_capture env AUTOPILOT_WALLCLOCK_CAP=abc bash "$BUDGET" 1 "$NOW"
if [ "$G_RC" -eq 64 ] && error_names "AUTOPILOT_WALLCLOCK_CAP"; then
  pass "a27b budget-check AUTOPILOT_WALLCLOCK_CAP=abc -> 64, names the variable"
else
  fail "a27b rc=$G_RC err=$G_ERR"
fi

# =============================================================================
# AC A — self-answer.md wording (AC9: env caps are external input)
# =============================================================================
if grep -qF -- 'never external input' "$SELF_ANSWER"; then
  fail "a28 self-answer.md still contains the literal phrase 'never external input'"
else
  pass "a28 self-answer.md does not contain 'never external input'"
fi

if grep -qF -- 'the env caps are external input' "$SELF_ANSWER"; then
  pass "a29 self-answer.md states the env caps are external input"
else
  fail "a29 self-answer.md is missing the 'the env caps are external input' wording"
fi

# =============================================================================
# AC B — self-answer.md §3f: exactly one bash fence, extracted via fence.sh,
# reads the freeze / calls budget-check.sh / calls append-card.sh.
# =============================================================================
if [ ! -f "$FENCE_LIB" ]; then
  echo "SKIP: tests/lib/fence.sh not committed yet (Task 4 step 1) — AC B deferred"
else
  # shellcheck source=../../tests/lib/fence.sh
  . "$FENCE_LIB"

  F1=$(fence_nth "$SELF_ANSWER" "### f." 1) || F1=""
  if [ -n "$F1" ]; then
    pass "b1 §3f has a bash fence (fence_nth 1 succeeds)"
  else
    fail "b1 §3f has no bash fence"
  fi

  if fence_nth "$SELF_ANSWER" "### f." 2 >/dev/null 2>&1; then
    fail "b2 §3f has a SECOND bash fence (AC B requires exactly one)"
  else
    pass "b2 §3f has exactly one bash fence (no second fence)"
  fi

  if printf '%s\n' "$F1" | grep -q 'read-cards.sh' \
    && printf '%s\n' "$F1" | grep -q 'budget-check.sh' \
    && printf '%s\n' "$F1" | grep -q 'append-card.sh'; then
    pass "b3 the fence reads the freeze with read-cards.sh and calls budget-check.sh / append-card.sh"
  else
    fail "b3 the fence body is missing one of read-cards.sh / budget-check.sh / append-card.sh"
  fi

  # substitute_fence <body> -> stdout: every C5 placeholder replaced with the
  # SUB_* values below (plain alnum/dash — no '&' or '#' to keep sed simple).
  substitute_fence() {
    printf '%s\n' "$1" \
      | sed -e "s#<workflow>#$SUB_WORKFLOW#g" \
            -e "s#<ticket_id>#$SUB_TICKET#g" \
            -e "s#<gate>#$SUB_GATE#g" \
            -e "s#<decision>#$SUB_DECISION#g" \
            -e "s#<bump>#$SUB_BUMP#g" \
            -e "s#<confidence>#$SUB_CONFIDENCE#g" \
            -e "s#<blocking_condition>#$SUB_BC#g" \
            -e "s#<run_id>#$SUB_RUN_ID#g" \
            -e "s#<iteration>#$SUB_ITERATION#g" \
            -e "s#<run_start_epoch>#$SUB_EPOCH#g" \
            -e "s#<actor>#$SUB_ACTOR#g" \
            -e "s#<rationale>#$SUB_RATIONALE#g" \
            -e "s#<max_loc>#$SUB_MAX_LOC#g" \
            -e "s#<RESUMING>#$SUB_RESUMING#g" \
            -e "s#<tasks>#$SUB_TASKS#g" \
            -e "s#<projected_loc>#$SUB_PROJECTED_LOC#g" \
            -e "s#<waves>#$SUB_WAVES#g"
  }

  # run_fence -> writes the substituted F1 to a temp script and runs it from
  # $FX (fixture MROOT) with CLAUDE_PLUGIN_ROOT="$ROOT" (Tier-0 PDH force) and
  # AUTOPILOT_BUDGET_META / AUTOPILOT_ITERATION_CAP / AUTOPILOT_WALLCLOCK_CAP
  # unset, per AC B. Sets G_OUT / G_ERR / G_RC.
  run_fence() {
    local script errfile
    script=$(mktemp "${TMPDIR:-/tmp}/tcv-fence.XXXXXX.sh")
    substitute_fence "$F1" > "$script"
    errfile=$(mktemp "${TMPDIR:-/tmp}/tcv-fence-err.XXXXXX")
    G_OUT=$(cd "$FX" && CLAUDE_PLUGIN_ROOT="$ROOT" \
      env -u AUTOPILOT_BUDGET_META -u AUTOPILOT_ITERATION_CAP -u AUTOPILOT_WALLCLOCK_CAP \
      timeout 60 bash "$script" 2>"$errfile")
    G_RC=$?
    G_ERR=$(cat "$errfile")
    rm -f "$script" "$errfile"
  }

  # ---- Fixture: a plan-approve freeze 40/10800 tier L at run_id=run-A -------
  reset
  META_L='{"iteration_cap":40,"wall_clock_cap_s":10800,"tier":"L","source":"auto","signals":{"tasks":6,"projected_loc":1200,"waves":3}}'
  AUTOPILOT_BUDGET_META="$META_L" bash "$APPEND" orchestrate CDT-B1 plan-approve approve auto null \
    88 null run-A 0 0 orchestrator "derive budget_tier=L auto" >/dev/null 2>&1

  SUB_WORKFLOW=orchestrate; SUB_TICKET=CDT-B1; SUB_GATE=ship-choice
  SUB_DECISION=pr; SUB_BUMP=null; SUB_CONFIDENCE=90; SUB_BC=null
  SUB_ITERATION=1; SUB_EPOCH="$NOW"; SUB_ACTOR=orchestrator
  SUB_RATIONALE="fence-test"; SUB_MAX_LOC=null
  SUB_TASKS=0; SUB_PROJECTED_LOC=0; SUB_WAVES=1

  # Scenario 1: same run_id as the freeze -> the card carries 40/10800/L
  # regardless of RESUMING.
  SUB_RUN_ID=run-A; SUB_RESUMING=false
  run_fence
  CARD=$(bash "$READ" CDT-B1 2>/dev/null | jq -c '[.[] | select(.gate=="ship-choice")] | last')
  if [ "$G_RC" -eq 0 ] && printf '%s' "$CARD" | jq -e '
    .budget.iteration_cap == 40 and .budget.wall_clock_cap_s == 10800 and .budget.tier == "L"
  ' >/dev/null 2>&1; then
    pass "b4 same run_id -> ship-choice card carries the 40/10800/L freeze"
  else
    fail "b4 rc=$G_RC card=$CARD out=$G_OUT err=$G_ERR"
  fi

  # Scenario 2: different run_id, RESUMING=false -> no freeze (default 25/2700, tier null)
  SUB_RUN_ID=run-B; SUB_RESUMING=false
  run_fence
  CARD=$(bash "$READ" CDT-B1 2>/dev/null | jq -c '[.[] | select(.gate=="ship-choice" and .run_id=="run-B")] | last')
  if [ "$G_RC" -eq 0 ] && printf '%s' "$CARD" | jq -e '
    .budget.tier == null and .budget.iteration_cap == 25 and .budget.wall_clock_cap_s == 2700
  ' >/dev/null 2>&1; then
    pass "b5 different run_id + RESUMING=false -> no freeze (25/2700, tier null)"
  else
    fail "b5 rc=$G_RC card=$CARD out=$G_OUT err=$G_ERR"
  fi

  # Scenario 3: different run_id, RESUMING=true -> freeze still applies
  SUB_RUN_ID=run-C; SUB_RESUMING=true
  run_fence
  CARD=$(bash "$READ" CDT-B1 2>/dev/null | jq -c '[.[] | select(.gate=="ship-choice" and .run_id=="run-C")] | last')
  if [ "$G_RC" -eq 0 ] && printf '%s' "$CARD" | jq -e '
    .budget.iteration_cap == 40 and .budget.wall_clock_cap_s == 10800 and .budget.tier == "L"
  ' >/dev/null 2>&1; then
    pass "b6 different run_id + RESUMING=true -> freeze still applies (40/10800/L)"
  else
    fail "b6 rc=$G_RC card=$CARD out=$G_OUT err=$G_ERR"
  fi

  # Scenario 4 (path 2): no freeze yet, gate=plan-approve on orchestrate ->
  # derive from tasks/projected_loc/waves, env unset -> source=auto, tier=L.
  reset
  SUB_TICKET=CDT-B2; SUB_GATE=plan-approve; SUB_DECISION=approve
  SUB_CONFIDENCE=85; SUB_RUN_ID=run-D; SUB_RATIONALE="derive-path-test budget_tier=L auto"
  SUB_RESUMING=false; SUB_TASKS=6; SUB_PROJECTED_LOC=1200; SUB_WAVES=3
  run_fence
  CARD=$(bash "$READ" CDT-B2 2>/dev/null | jq -c '[.[] | select(.gate=="plan-approve")] | last')
  if [ "$G_RC" -eq 0 ] && printf '%s' "$CARD" | jq -e '
    .budget.iteration_cap == 40 and .budget.wall_clock_cap_s == 4500
    and .budget.tier == "L" and .budget.source == "auto" and .budget.signals != null
  ' >/dev/null 2>&1; then
    pass "b7 path 2 (first freeze at plan-approve): derive -> L 40/4500, source=auto"
  else
    fail "b7 rc=$G_RC card=$CARD out=$G_OUT err=$G_ERR"
  fi

  # Scenario 5 (path 2, env mix): AUTOPILOT_ITERATION_CAP set, WALLCLOCK unset ->
  # source=mixed, iteration_cap from env, wall_clock_cap_s from derive.
  reset
  SUB_TICKET=CDT-B3; SUB_RUN_ID=run-E
  script2=$(mktemp "${TMPDIR:-/tmp}/tcv-fence2.XXXXXX.sh")
  substitute_fence "$F1" > "$script2"
  errfile2=$(mktemp "${TMPDIR:-/tmp}/tcv-fence2-err.XXXXXX")
  G_OUT=$(cd "$FX" && CLAUDE_PLUGIN_ROOT="$ROOT" \
    env -u AUTOPILOT_BUDGET_META -u AUTOPILOT_WALLCLOCK_CAP AUTOPILOT_ITERATION_CAP=7 \
    timeout 60 bash "$script2" 2>"$errfile2")
  G_RC=$?
  G_ERR=$(cat "$errfile2")
  rm -f "$script2" "$errfile2"
  CARD=$(bash "$READ" CDT-B3 2>/dev/null | jq -c '[.[] | select(.gate=="plan-approve")] | last')
  if [ "$G_RC" -eq 0 ] && printf '%s' "$CARD" | jq -e '
    .budget.iteration_cap == 7 and .budget.wall_clock_cap_s == 4500 and .budget.source == "mixed"
  ' >/dev/null 2>&1; then
    pass "b8 path 2 env mix: AUTOPILOT_ITERATION_CAP=7 wins iteration_cap, wall_clock_cap_s stays derived -> source=mixed"
  else
    fail "b8 rc=$G_RC card=$CARD out=$G_OUT err=$G_ERR"
  fi

  # Scenario 6 (TL review item 3): rationale injection. Backticks and $(...)
  # inside the model-written <rationale> slot must be data, never executed,
  # once loaded through the RATIONALE heredoc.
  reset
  SUB_TICKET=CDT-B4; SUB_GATE=ship-choice; SUB_DECISION=pr; SUB_BUMP=null
  SUB_CONFIDENCE=90; SUB_BC=null; SUB_RUN_ID=run-G; SUB_RESUMING=false
  SUB_MAX_LOC=null
  MARKER1="$FX/INJECTION_MARKER"
  MARKER2="$FX/INJECTION_MARKER2"
  rm -f "$MARKER1" "$MARKER2"
  SUB_RATIONALE='approval-wait: `touch INJECTION_MARKER` and $(touch INJECTION_MARKER2) needs a human'
  run_fence
  CARD=$(bash "$READ" CDT-B4 2>/dev/null | jq -c '[.[] | select(.gate=="ship-choice")] | last')
  RAT=$(printf '%s' "$CARD" | jq -r '.rationale')
  if [ "$G_RC" -eq 0 ] && [ ! -e "$MARKER1" ] && [ ! -e "$MARKER2" ] \
    && [ "$RAT" = "$SUB_RATIONALE" ]; then
    pass "b9 rationale injection: backtick/\$(...) create no file, land verbatim in the card"
  else
    M1S=absent; [ -e "$MARKER1" ] && M1S=present
    M2S=absent; [ -e "$MARKER2" ] && M2S=present
    fail "b9 rc=$G_RC marker1=$M1S marker2=$M2S rationale=[$RAT] out=$G_OUT err=$G_ERR"
  fi
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
