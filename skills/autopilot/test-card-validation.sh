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

# =============================================================================
# CDT-565 (SPEC-039 M30) — append-card.sh --advisor-json: additive nullable
# 19th top-level key. File-path only; absent flag / empty file -> null;
# malformed or wrong-shape file -> 64 with no ledger line.
# =============================================================================
reset
run_capture bash "$APPEND" orchestrate CDT-D1 plan-approve proceed auto null \
  85 null run-1 1 10 orch "r"
if [ "$G_RC" -eq 0 ] && jq -e '.advisor == null and .schema_version == 1
  and (keys_unsorted | length) == 19
  and (keys_unsorted | last) == "advisor"' "$(ledger CDT-D1)" >/dev/null 2>&1; then
  pass "d1 argc13 without --advisor-json -> advisor:null, 19 keys, advisor last"
else
  fail "d1 rc=$G_RC err=$G_ERR"
fi

reset
ADVISOR_OK='{"ruling":"AGREE","corrected_claim":null,"evidence":[{"cmd":"pacman -Q openmpi","exit":1,"sha256":"abc","locator":"docs/runbooks/omp.md:12"}],"model":"test-model-x","evidence_over_memory":true,"question_hash":"h1","trigger":"b","cache_hit":false,"timeout":false,"marker":null}'
printf '%s' "$ADVISOR_OK" > "$FX/adv-ok.json"
run_capture bash "$APPEND" orchestrate CDT-D2 plan-approve proceed auto null \
  85 null run-1 1 10 orch "r" --advisor-json "$FX/adv-ok.json"
if [ "$G_RC" -eq 0 ] && jq -e --argjson adv "$ADVISOR_OK" '
  .advisor == $adv and .schema_version == 1
  and (keys_unsorted | length) == 19 and (keys_unsorted | last) == "advisor"
' "$(ledger CDT-D2)" >/dev/null 2>&1; then
  pass "d2 --advisor-json writes the M30 object verbatim as the 19th key"
else
  fail "d2 rc=$G_RC err=$G_ERR"
fi

reset
: > "$FX/adv-empty.json"
run_capture bash "$APPEND" orchestrate CDT-D3 plan-approve proceed auto null \
  85 null run-1 1 10 orch "r" --advisor-json "$FX/adv-empty.json"
if [ "$G_RC" -eq 0 ] && jq -e '.advisor == null' "$(ledger CDT-D3)" >/dev/null 2>&1; then
  pass "d3 empty --advisor-json file -> advisor: null"
else
  fail "d3 rc=$G_RC err=$G_ERR"
fi

reset
printf '%s' '{"ruling":"AGREE",' > "$FX/adv-trunc.json"
run_capture bash "$APPEND" orchestrate CDT-D4 plan-approve proceed auto null \
  85 null run-1 1 10 orch "r" --advisor-json "$FX/adv-trunc.json"
if [ "$G_RC" -eq 64 ] && no_ledger CDT-D4; then
  pass "d4 malformed JSON file -> 64, no ledger line"
else
  fail "d4 rc=$G_RC err=$G_ERR"
fi

reset
printf '%s' '{"ruling":"MAYBE","corrected_claim":null,"evidence":[],"model":"","evidence_over_memory":true,"question_hash":"","trigger":"a","cache_hit":false,"timeout":false,"marker":null}' > "$FX/adv-badruling.json"
run_capture bash "$APPEND" orchestrate CDT-D5 plan-approve proceed auto null \
  85 null run-1 1 10 orch "r" --advisor-json "$FX/adv-badruling.json"
if [ "$G_RC" -eq 64 ] && no_ledger CDT-D5; then
  pass "d5 ruling outside the M18 taxonomy -> 64, no ledger line"
else
  fail "d5 rc=$G_RC err=$G_ERR"
fi

reset
printf '%s' '[1,2]' > "$FX/adv-arr.json"
run_capture bash "$APPEND" orchestrate CDT-D6 plan-approve proceed auto null \
  85 null run-1 1 10 orch "r" --advisor-json "$FX/adv-arr.json"
D6A=$G_RC
printf '%s' '{"ruling":"AGREE"}{"ruling":"CONTRADICT"}' > "$FX/adv-multi.json"
run_capture bash "$APPEND" orchestrate CDT-D6 plan-approve proceed auto null \
  85 null run-1 1 10 orch "r" --advisor-json "$FX/adv-multi.json"
if [ "$D6A" -eq 64 ] && [ "$G_RC" -eq 64 ] && no_ledger CDT-D6; then
  pass "d6 non-object and multi-object advisor files -> 64, no ledger line"
else
  fail "d6 rc1=$D6A rc2=$G_RC err=$G_ERR"
fi

reset
run_capture bash "$APPEND" orchestrate CDT-D7 plan-approve proceed auto null \
  85 null run-1 1 10 orch "r" --advisor-json "$FX/adv-ok.json" --advisor-json "$FX/adv-ok.json"
if [ "$G_RC" -eq 64 ] && no_ledger CDT-D7; then
  pass "d7 duplicate --advisor-json -> 64"
else
  fail "d7 rc=$G_RC err=$G_ERR"
fi

reset
run_capture bash "$APPEND" orchestrate CDT-D8 plan-approve proceed auto null \
  85 null run-1 1 10 orch "r" --advisor-json --advisor-json
if [ "$G_RC" -eq 64 ] && no_ledger CDT-D8; then
  pass "d8 --advisor-json with a flag-like value -> 64"
else
  fail "d8 rc=$G_RC err=$G_ERR"
fi

# argc 14/15/16 stay legal alongside --advisor-json (M30: argc 13-16 valid).
reset
run_capture bash "$APPEND" orchestrate CDT-D9 ship-choice pr auto patch \
  90 null run-1 1 10 orch "r" 5000 --advisor-json "$FX/adv-ok.json"
if [ "$G_RC" -eq 0 ] && jq -e --argjson adv "$ADVISOR_OK" \
  '.advisor == $adv and .max_loc == 5000 and .bump == "patch"' \
  "$(ledger CDT-D9)" >/dev/null 2>&1; then
  pass "d9 argc14 max_loc + --advisor-json -> both written"
else
  fail "d9 rc=$G_RC err=$G_ERR"
fi

# Untrusted-input rule: the object is DATA. Injection content in corrected_claim
# must land verbatim on the card and create no file.
reset
ADVISOR_INJ='{"ruling":"INSUFFICIENT","corrected_claim":"`touch D10_MARKER` and $(touch D10_MARKER2) not verified","evidence":[{"cmd":"true","exit":0,"sha256":"x","locator":"a:1"}],"model":"m","evidence_over_memory":true,"question_hash":"","trigger":"a","cache_hit":false,"timeout":false,"marker":null}'
printf '%s' "$ADVISOR_INJ" > "$FX/adv-inj.json"
run_capture bash "$APPEND" orchestrate CDT-D10 plan-approve halt auto null \
  40 7 run-1 1 10 orch "r" --advisor-json "$FX/adv-inj.json"
if [ "$G_RC" -eq 0 ] && [ ! -e "$FX/D10_MARKER" ] && [ ! -e "$FX/D10_MARKER2" ] \
  && jq -e --argjson adv "$ADVISOR_INJ" '.advisor == $adv' "$(ledger CDT-D10)" >/dev/null 2>&1; then
  pass "d10 injection content in the advisor object is data: no file, verbatim on the card"
else
  fail "d10 rc=$G_RC marker=$(ls "$FX"/D10_MARKER* 2>/dev/null) err=$G_ERR"
fi

# =============================================================================
# CDT-565 — read-cards.sh backfills a missing advisor as null (frozen
# position, after actor); new cards round-trip with the object intact.
# =============================================================================
reset
mkdir -p "$AUTODIR"
printf '%s\n' '{"schema_version":1,"type":"autopilot_decision","ts":"2026-01-01T00:00:00Z","run_id":"old","workflow":"orchestrate","ticket_id":"CDT-D11","gate":"plan-approve","decision":"proceed","decided_by":"auto","bump":null,"confidence":50,"blocking_condition":null,"rationale":"legacy","budget":{"iteration":1,"iteration_cap":25,"wall_clock_s":1,"wall_clock_cap_s":2700},"actor":"orchestrator"}' > "$(ledger CDT-D11)"
run_capture bash "$READ" CDT-D11
if [ "$G_RC" -eq 0 ] && printf '%s' "$G_OUT" | jq -e '
  .[0].advisor == null
  and .[0].schema_version == 1
  and ((.[0] | keys_unsorted | length) == 19)
  and ((.[0] | keys_unsorted | last) == "advisor")
  and ((.[0] | keys_unsorted | .[-2]) == "actor")
' >/dev/null 2>&1; then
  pass "d11 pre-CDT-565 18-key card reads back with advisor:null as the 19th key (after actor), schema_version 1"
else
  fail "d11 rc=$G_RC out=$G_OUT"
fi

reset
run_capture bash "$APPEND" orchestrate CDT-D12 plan-approve proceed auto null \
  85 null run-1 1 10 orch "r" --advisor-json "$FX/adv-ok.json"
run_capture bash "$APPEND" orchestrate CDT-D12 plan-approve approve auto null \
  80 null run-1 2 20 orch "r2"
run_capture bash "$READ" CDT-D12
if [ "$G_RC" -eq 0 ] && printf '%s' "$G_OUT" | jq -e --argjson adv "$ADVISOR_OK" '
  (.[0].advisor == $adv) and (.[1].advisor == null)
  and ([.[] | (keys_unsorted | length)] == [19, 19])
' >/dev/null 2>&1; then
  pass "d12 mixed ledger: advisor object round-trips; advisor-less card backfills null"
else
  fail "d12 rc=$G_RC out=$G_OUT"
fi

# d13: argc15 (council_tier + grading_reason) alongside --advisor-json — the
# M30 flag composes with the M14 council pair (invariant (c) gate respected).
reset
run_capture bash "$APPEND" orchestrate CDT-D13 ship-choice pr auto patch \
  90 null run-1 1 10 orch "r" light "tier band" --advisor-json "$FX/adv-ok.json"
if [ "$G_RC" -eq 0 ] && jq -e --argjson adv "$ADVISOR_OK" '
  .advisor == $adv and .council_tier == "light" and .grading_reason == "tier band"
  and .bump == "patch" and .schema_version == 1
  and (keys_unsorted | length) == 19 and (keys_unsorted | last) == "advisor"
' "$(ledger CDT-D13)" >/dev/null 2>&1; then
  pass "d13 argc15 council pair + --advisor-json -> 19 keys, advisor intact, tier/grading present"
else
  fail "d13 rc=$G_RC err=$G_ERR"
fi

# d14: argc16 (council pair + max_loc) alongside --advisor-json.
reset
run_capture bash "$APPEND" orchestrate CDT-D14 ship-choice pr auto patch \
  90 null run-1 1 10 orch "r" light "tier band" 5000 --advisor-json "$FX/adv-ok.json"
if [ "$G_RC" -eq 0 ] && jq -e --argjson adv "$ADVISOR_OK" '
  .advisor == $adv and .council_tier == "light" and .grading_reason == "tier band"
  and .max_loc == 5000 and .schema_version == 1
  and (keys_unsorted | length) == 19 and (keys_unsorted | last) == "advisor"
' "$(ledger CDT-D14)" >/dev/null 2>&1; then
  pass "d14 argc16 council pair + max_loc + --advisor-json -> all fields written"
else
  fail "d14 rc=$G_RC err=$G_ERR"
fi

# d15: position independence — the flag before the positionals writes the
# identical card to d2 (same argv values, same ticket semantics).
reset
run_capture bash "$APPEND" --advisor-json "$FX/adv-ok.json" \
  orchestrate CDT-D15 plan-approve proceed auto null 85 null run-1 1 10 orch "r"
if [ "$G_RC" -eq 0 ] && jq -e --argjson adv "$ADVISOR_OK" \
  '.advisor == $adv and (keys_unsorted | length) == 19' \
  "$(ledger CDT-D15)" >/dev/null 2>&1; then
  pass "d15 --advisor-json before the positionals -> identical card (position-independent)"
else
  fail "d15 rc=$G_RC err=$G_ERR"
fi

# d16/d17/d18: per-field M30 rejections -> 64, no ledger line.
reset
printf '%s' '{"ruling":"AGREE","corrected_claim":null,"evidence":[{"cmd":"true","exit":0,"sha256":"x","locator":"a:1"}],"model":"m","evidence_over_memory":true,"question_hash":"","trigger":"d","cache_hit":false,"timeout":false,"marker":null}' > "$FX/adv-badtrigger.json"
run_capture bash "$APPEND" orchestrate CDT-D16 plan-approve proceed auto null \
  85 null run-1 1 10 orch "r" --advisor-json "$FX/adv-badtrigger.json"
D16=$G_RC
printf '%s' '{"ruling":"AGREE","corrected_claim":null,"evidence":[{"cmd":"true","exit":0,"sha256":"x","locator":"a:1"}],"model":"m","evidence_over_memory":true,"question_hash":"","trigger":"a","cache_hit":"yes","timeout":false,"marker":null}' > "$FX/adv-badcache.json"
run_capture bash "$APPEND" orchestrate CDT-D17 plan-approve proceed auto null \
  85 null run-1 1 10 orch "r" --advisor-json "$FX/adv-badcache.json"
D17=$G_RC
printf '%s' '{"ruling":"AGREE","corrected_claim":null,"evidence":[{"cmd":"true","exit":0,"locator":"a:1"}],"model":"m","evidence_over_memory":true,"question_hash":"","trigger":"a","cache_hit":false,"timeout":false,"marker":null}' > "$FX/adv-nosha.json"
run_capture bash "$APPEND" orchestrate CDT-D18 plan-approve proceed auto null \
  85 null run-1 1 10 orch "r" --advisor-json "$FX/adv-nosha.json"
if [ "$D16" -eq 64 ] && [ "$D17" -eq 64 ] && [ "$G_RC" -eq 64 ] && no_ledger CDT-D16 && no_ledger CDT-D17 && no_ledger CDT-D18; then
  pass "d16-d18 per-field rejections: trigger d / string cache_hit / evidence element missing sha256 (M30 shape {cmd, exit, sha256, locator}) -> 64, no ledger line"
else
  fail "d16-d18 rc=$D16/$D17/$G_RC"
fi

# d20-d29: the remaining per-field M30 shape rejections -> 64, no ledger line
# (AC2: the writer enforces the full M30 shape, one run-output line per field).
reset
while IFS='|' read -r tag desc json; do
  [ -n "$tag" ] || continue
  printf '%s' "$json" > "$FX/adv-f.json"
  run_capture bash "$APPEND" orchestrate "CDT-$tag" plan-approve proceed auto null \
    85 null run-1 1 10 orch "r" --advisor-json "$FX/adv-f.json"
  if [ "$G_RC" -eq 64 ] && no_ledger "CDT-$tag"; then
    pass "d${tag#D} $desc -> 64, no ledger line"
  else
    fail "d${tag#D} rc=$G_RC err=$G_ERR"
  fi
done <<'EOF'
D20|corrected_claim non-string (number)|{"ruling":"AGREE","corrected_claim":7,"evidence":[{"cmd":"true","exit":0,"sha256":"x","locator":"a:1"}],"model":"m","evidence_over_memory":true,"question_hash":"","trigger":"a","cache_hit":false,"timeout":false,"marker":null}
D21|model non-string (number)|{"ruling":"AGREE","corrected_claim":null,"evidence":[{"cmd":"true","exit":0,"sha256":"x","locator":"a:1"}],"model":7,"evidence_over_memory":true,"question_hash":"","trigger":"a","cache_hit":false,"timeout":false,"marker":null}
D22|evidence_over_memory non-boolean (string)|{"ruling":"AGREE","corrected_claim":null,"evidence":[{"cmd":"true","exit":0,"sha256":"x","locator":"a:1"}],"model":"m","evidence_over_memory":"yes","question_hash":"","trigger":"a","cache_hit":false,"timeout":false,"marker":null}
D23|question_hash non-string (number)|{"ruling":"AGREE","corrected_claim":null,"evidence":[{"cmd":"true","exit":0,"sha256":"x","locator":"a:1"}],"model":"m","evidence_over_memory":true,"question_hash":7,"trigger":"a","cache_hit":false,"timeout":false,"marker":null}
D24|timeout non-boolean (string)|{"ruling":"AGREE","corrected_claim":null,"evidence":[{"cmd":"true","exit":0,"sha256":"x","locator":"a:1"}],"model":"m","evidence_over_memory":true,"question_hash":"","trigger":"a","cache_hit":false,"timeout":"yes","marker":null}
D25|marker non-string (number)|{"ruling":"AGREE","corrected_claim":null,"evidence":[{"cmd":"true","exit":0,"sha256":"x","locator":"a:1"}],"model":"m","evidence_over_memory":true,"question_hash":"","trigger":"a","cache_hit":false,"timeout":false,"marker":7}
D26|evidence element missing cmd|{"ruling":"AGREE","corrected_claim":null,"evidence":[{"exit":0,"sha256":"x","locator":"a:1"}],"model":"m","evidence_over_memory":true,"question_hash":"","trigger":"a","cache_hit":false,"timeout":false,"marker":null}
D27|evidence element missing exit|{"ruling":"AGREE","corrected_claim":null,"evidence":[{"cmd":"true","sha256":"x","locator":"a:1"}],"model":"m","evidence_over_memory":true,"question_hash":"","trigger":"a","cache_hit":false,"timeout":false,"marker":null}
D28|evidence element missing locator|{"ruling":"AGREE","corrected_claim":null,"evidence":[{"cmd":"true","exit":0,"sha256":"x"}],"model":"m","evidence_over_memory":true,"question_hash":"","trigger":"a","cache_hit":false,"timeout":false,"marker":null}
D29|evidence element non-object|{"ruling":"AGREE","corrected_claim":null,"evidence":["nope"],"model":"m","evidence_over_memory":true,"question_hash":"","trigger":"a","cache_hit":false,"timeout":false,"marker":null}
EOF

# d19: an M30 object with "ruling": null (the BC8 unavailable shape) is
# ACCEPTED — the writer only rejects illegal field values, never the
# law-abiding null ruling.
reset
ADVISOR_NULL='{"ruling":null,"corrected_claim":null,"evidence":[],"model":"","evidence_over_memory":true,"question_hash":"","trigger":"b","cache_hit":false,"timeout":true,"marker":"advisor unavailable — fell back"}'
printf '%s' "$ADVISOR_NULL" > "$FX/adv-null.json"
run_capture bash "$APPEND" orchestrate CDT-D19 plan-approve halt auto null \
  0 8 run-1 1 10 advisor "advisor unavailable — fell back (timeout)" --advisor-json "$FX/adv-null.json"
if [ "$G_RC" -eq 0 ] && jq -e --argjson adv "$ADVISOR_NULL" \
  '.advisor == $adv and .advisor.ruling == null and .blocking_condition == 8
   and (keys_unsorted | length) == 19' \
  "$(ledger CDT-D19)" >/dev/null 2>&1; then
  pass "d19 ruling: null object accepted -> card written with advisor.ruling null and the rest of the M30 object intact"
else
  fail "d19 rc=$G_RC err=$G_ERR"
fi

# =============================================================================
# CDT-565 (SPEC-039 M27/AC11) — self-answer.md §3g BC8 unavailable fence:
# probe/finalize report; the caller writes ONE halt card, blocking_condition 8,
# exact marker "advisor unavailable — fell back" in the advisor object. The BC
# list stays eight (append-card still rejects 9 — case a8 above).
# =============================================================================
if [ ! -f "$FENCE_LIB" ]; then
  echo "SKIP: tests/lib/fence.sh missing — CDT-565 §3g fence scenarios deferred"
else
  # shellcheck source=../../tests/lib/fence.sh
  . "$FENCE_LIB"
  G_FENCE=$(fence_nth "$SELF_ANSWER" "### g." 1) || G_FENCE=""

  if [ -n "$G_FENCE" ] && printf '%s\n' "$G_FENCE" | grep -q 'advisor unavailable — fell back'; then
    pass "g1 §3g holds one bash fence carrying the exact BC8 marker"
  else
    fail "g1 §3g fence missing or without the marker"
  fi

  substitute_g() { # substitute_g <body> — CDT-565 §3g placeholders
    printf '%s\n' "$1" \
      | sed -e "s#<workflow>#$G_WORKFLOW#g" \
            -e "s#<ticket_id>#$G_TICKET#g" \
            -e "s#<gate>#$G_GATE#g" \
            -e "s#<run_id>#$G_RUN_ID#g" \
            -e "s#<iteration>#$G_ITERATION#g" \
            -e "s#<run_start_epoch>#$G_EPOCH#g" \
            -e "s#<trigger>#$G_TRIGGER#g" \
            -e "s#<mode>#$G_MODE#g" \
            -e "s#<reason>#$G_REASON#g"
  }

  run_g_fence() { # run_g_fence — sets G_OUT/G_ERR/G_RC from the §3g fence
    local script errfile
    script=$(mktemp "${TMPDIR:-/tmp}/tcv-g.XXXXXX.sh")
    substitute_g "$G_FENCE" > "$script"
    # Optional trailing lines appended to the substituted fence script (g7/g8
    # runtime exhibits). Empty by default.
    printf '%s' "${G_TRAILER:-}" >> "$script"
    errfile=$(mktemp "${TMPDIR:-/tmp}/tcv-g-err.XXXXXX")
    G_OUT=$(cd "$FX" && CLAUDE_PLUGIN_ROOT="$ROOT" \
      env -u AUTOPILOT_BUDGET_META -u AUTOPILOT_ITERATION_CAP -u AUTOPILOT_WALLCLOCK_CAP \
      timeout 60 bash "$script" 2>"$errfile")
    G_RC=$?
    G_ERR=$(cat "$errfile")
    rm -f "$script" "$errfile"
  }

  assert_bc8_card() { # assert_bc8_card <ticket> <expect-timeout>
    local ticket="$1" want_to="$2" card
    card=$(bash "$READ" "$ticket" 2>/dev/null | jq -c '[.[] | select(.blocking_condition == 8)] | last')
    [ -n "$card" ] || { echo "NO-CARD"; return 1; }
    printf '%s' "$card" | jq -e --argjson wt "$want_to" '
      .decision == "halt" and .blocking_condition == 8 and .decided_by == "auto"
      and .actor == "advisor" and .bump == null and .confidence == 0
      and .advisor.ruling == null
      and .advisor.marker == "advisor unavailable — fell back"
      and .advisor.trigger == "b" and .advisor.timeout == $wt
      and .advisor.cache_hit == false and .advisor.evidence_over_memory == true
      and (.advisor.evidence | type) == "array"
    ' >/dev/null 2>&1
  }

  G_WORKFLOW=orchestrate; G_GATE=plan-approve; G_TRIGGER=b
  G_ITERATION=1; G_EPOCH=$((NOW - 5))

  for G_MODE in refuse cap timeout spawn-fail; do
    reset
    G_TICKET="CDT-G-$G_MODE"; G_RUN_ID="run-g-$G_MODE"
    case "$G_MODE" in
      refuse) G_REASON="advisor not configured" ;;
      cap) G_REASON="global per-run cap exhausted (5)" ;;
      timeout) G_REASON="timeout" ;;
      spawn-fail) G_REASON="spawn-fail" ;;
    esac
    run_g_fence
    if [ "$G_RC" -eq 0 ] && assert_bc8_card "$G_TICKET" \
        "$([ "$G_MODE" = timeout ] && echo true || echo false)"; then
      pass "g2-$G_MODE §3g fence writes the BC8 halt card with the exact marker ($G_MODE)"
    else
      fail "g2-$G_MODE rc=$G_RC card=$(bash "$READ" "$G_TICKET" 2>/dev/null | tail -1) err=$G_ERR"
    fi
  done

  # g5: EXACTLY ONE BC8 card per unavailable outcome — count, not last.
  reset
  G_TICKET="CDT-G-COUNT"; G_RUN_ID="run-g-count"; G_MODE=refuse; G_REASON="advisor not configured"
  run_g_fence
  G_N8=$(bash "$READ" CDT-G-COUNT 2>/dev/null | jq '[.[] | select(.blocking_condition == 8)] | length' 2>/dev/null)
  if [ "$G_RC" -eq 0 ] && [ "$G_N8" = "1" ]; then
    pass "g5 ledger holds exactly ONE blocking_condition==8 card after one unavailable outcome (count=$G_N8)"
  else
    fail "g5 rc=$G_RC count=$G_N8"
  fi

  # g6: interactive-no-halt — the seam alone (probe refuse + a timeout
  # finalize) reports and writes NO card; only the §3g fence writes BC8.
  reset
  ADV_STATE="$FX/adv-state"
  mkdir -p "$ADV_STATE/runs/r-g6"
  jq -cn --arg run_id r-g6 --arg trigger a --arg question "g6" --arg hash g6hash \
    --arg model "" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{run_id:$run_id, trigger:$trigger, question:$question, question_hash:$hash,
      model:$model, evidence_dir:null, bc:null, ts:$ts, status:"awaiting-spawn"}' \
    > "$ADV_STATE/runs/r-g6/spawn-request.json"
  G_PROBE=$(cd "$FX" && CLAUDE_PLUGIN_ROOT="$ROOT" ADVISOR_STATE_ROOT="$ADV_STATE" \
    bash "$ROOT/skills/advisor/ask.sh" probe --trigger a --question "g6" --run-id r-g6 2>/dev/null)
  G_PACT=$(printf '%s' "$G_PROBE" | jq -r '.action' 2>/dev/null)
  G_FINRC=$(cd "$FX" && CLAUDE_PLUGIN_ROOT="$ROOT" ADVISOR_STATE_ROOT="$ADV_STATE" \
    bash "$ROOT/skills/advisor/ask.sh" finalize --run-id r-g6 --timeout >/dev/null 2>&1; echo $?)
  if [ "$G_PACT" = "refuse" ] && [ "$G_FINRC" = "0" ] && [ ! -s "$(ledger CDT-G6)" ]; then
    pass "g6 interactive-no-halt: probe refuse + timeout finalize write ZERO BC8 cards (seam only reports; the §3g fence is the sole writer)"
  else
    fail "g6 probe=$G_PACT finrc=$G_FINRC ledger=$(cat "$(ledger CDT-G6)" 2>/dev/null)"
  fi

  reset
  G_TICKET=CDT-G-BUDGET; G_RUN_ID=run-g-b; G_MODE=refuse; G_REASON="advisor not configured"
  run_g_fence
  if [ "$G_RC" -eq 0 ] && jq -s -e '
    [.[]
     | select(.blocking_condition == 8)][0]
    | .budget.iteration == 1 and .budget.iteration_cap == 25
      and .budget.wall_clock_cap_s == 2700 and .budget.tier == null
      and (.budget.wall_clock_s | type) == "number"
  ' "$(ledger CDT-G-BUDGET)" >/dev/null 2>&1; then
    pass "g3 §3g card carries a fresh budget-check wall_clock_s and default caps"
  else
    fail "g3 err=$G_ERR"
  fi

  reset
  G_TICKET=CDT-G-BADMODE; G_RUN_ID=run-g-x; G_MODE=ninth-bc; G_REASON="x"
  run_g_fence
  if [ "$G_RC" -eq 64 ] && no_ledger CDT-G-BADMODE; then
    pass "g4 §3g fence rejects a mode outside refuse|cap|timeout|spawn-fail (no ninth-BC path)"
  else
    fail "g4 rc=$G_RC"
  fi

  # g7: the §3g fence mktemp's the advisor object under TMPDIR — exhibited at
  # run time by the path the fence actually used (AC7 parenthetical).
  reset
  G_GT=$(mktemp -d "${TMPDIR:-/tmp}/cdt565-g7.XXXXXX")
  G_TICKET=CDT-G-TMPOBJ; G_RUN_ID=run-g-tmpobj; G_MODE=refuse; G_REASON="advisor not configured"
  G_TRAILER='
printf "ADV_OBJ_PATH=%s\n" "$ADVISOR_OBJ"'
  TMPDIR="$G_GT" run_g_fence
  G_TMP_USED=$(printf '%s' "$G_OUT" | sed -n 's/^ADV_OBJ_PATH=//p')
  case "$G_TMP_USED" in
    "$G_GT"/advisor-unavailable.*.json) G_TMP_OK=1 ;;
    *) G_TMP_OK=0 ;;
  esac
  if [ "$G_RC" -eq 0 ] && [ "$G_TMP_OK" -eq 1 ]; then
    pass "g7 §3g fence mktemps the advisor object under TMPDIR ($G_TMP_USED)"
  else
    fail "g7 rc=$G_RC path=$G_TMP_USED tmp=$G_GT err=$G_ERR"
  fi
  rm -rf "$G_GT"; G_TRAILER=""

  # g8: a writer reject exits 64 through the fence, writes no card, and the
  # advisor-object temp file is cleaned up — escalate, never retry silently.
  reset
  G_GT=$(mktemp -d "${TMPDIR:-/tmp}/cdt565-g8.XXXXXX")
  G_TICKET=CDT-G-REJECT; G_RUN_ID=run-g-reject; G_MODE=refuse; G_REASON="advisor not configured"
  G_GATE=not-a-gate   # append-card gate enum -> die 64 inside the fence
  TMPDIR="$G_GT" run_g_fence
  G_LEFT=$(ls "$G_GT"/advisor-unavailable.* 2>/dev/null | wc -l)
  if [ "$G_RC" -eq 64 ] && no_ledger CDT-G-REJECT && [ "$G_LEFT" -eq 0 ]; then
    pass "g8 §3g writer reject -> exit 64, no card, advisor-object temp cleaned (no silent retry)"
  else
    fail "g8 rc=$G_RC left=$G_LEFT ledger=$(cat "$(ledger CDT-G-REJECT)" 2>/dev/null) err=$G_ERR"
  fi
  rm -rf "$G_GT"; G_TRAILER=""; G_GATE=plan-approve
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
