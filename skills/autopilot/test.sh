#!/usr/bin/env bash
#
# autopilot/test.sh — SPEC-033 AC6/M13 bite-tests for append-card.sh + read-cards.sh
# + CDT-111-C3 T2 bite-tests for budget-check.sh.
# + CDT-111-C4 T1 bite-tests for parse-flags.sh.
#
# Machine-check: bash skills/autopilot/test.sh  (exit 0, all PASS)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
# Covers plan T3 cases (a)-(l): happy-path schema, append-only identity, argc,
# 5 bad-enum, both cross-field invariants, control-char rationale, env override,
# reader empty/N-cards/argc, and path-traversal rejection for BOTH scripts.
# jq is REQUIRED to run this harness (both scripts hard-fail 64 without it), so
# the jq-absent path is intentionally not exercised here.
#
# Covers CDT-111-C3 T2 cases (m)-(u) for budget-check.sh: within-budget,
# iteration breach, wall-clock breach (backdated run_start_epoch), both-breach,
# non-numeric arg, future run_start_epoch, wrong argc, env-override caps, and
# 7-key JSON shape.
#
# Covers CDT-111-C4 T1 cases (v)-(ad) for parse-flags.sh: flag-only, flag+bump,
# env-only, flag+env both set (flag wins), illegal bump, empty bump, off,
# unset, and 5-key JSON shape (CDT-126 adds council_tier; CDT-206 adds tier).
#
# Covers CDT-126 T5 cases (an)-(ap) for the council_tier/grading_reason card
# fields: 15-arg append + frozen key position, argc-14 / bad-enum / invariant-(c)
# / control-char rejections, and reader backfill + invariant-(c) hard-fail.
#
# Covers CDT-126 T6 cases (aq)-(au) for parse-flags.sh --council-tier: tier
# resolves independently of --autopilot, absent → null, illegal/bare → 64.
#
# Covers CDT-111-C8 T1 cases (ae)-(aj) for resume-state.sh: not-found, found
# with recorded on/bump state, found off-recorded, found pre-feature (no
# autopilot_on line), multi-match newest-mtime wins, bad ISSUE-ID, and
# accumulated-mode 0/1/N-card max.
#
# Covers CDT-185 T2 cases (av)-(bd) for M14(a) process-stamp predicate +
# static claim contract on ship-gate-council.md: stamp happy path, fail-closed
# matrix (missing/empty/BC7/halt/user/non-null-tier), and §3b technical-only
# claim / no RAW_ARTIFACTS.
#
# Covers CDT-195 T2 cases (be)-(bj) for bump=master sentinel: parse accept
# =master; illegal/empty list all four; env cannot set master; append-card
# accepts master on ship-choice / rejects on non-ship-choice; resume-state
# round-trip master.
#
# Covers CDT-206 T1 cases (bk)-(cc) for parse-flags.sh --tier: omit → null,
# light|standard|full accepted, independent of --council-tier/--autopilot,
# malformed/duplicate/bare/space/case → 64, mixed argv with --resume-ship.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
APPEND="$SCRIPT_DIR/append-card.sh"
READ="$SCRIPT_DIR/read-cards.sh"
BUDGET="$SCRIPT_DIR/budget-check.sh"
PARSE="$SCRIPT_DIR/parse-flags.sh"
RESUME="$SCRIPT_DIR/resume-state.sh"
SHIP_GATE="$SCRIPT_DIR/ship-gate-council.md"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

# rc N of a command without tripping anything; prints nothing.
rc_of() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; echo "$rc"; }

# M14(a) CDT-185 process-stamp predicate (SPEC-033 stamp shape).
# Reads ledger via read-cards.sh; exit 0 = stamp pass, 1 = fail.
# Shape on first ship-choice card for its run_id:
#   gate=ship-choice, decision∈{pr,merge}, blocking_condition=null,
#   decided_by=auto, council_tier=null, grading_reason=null.
process_stamps_ok() {
  local ticket=$1 out rc=0
  out=$(bash "$READ" "$ticket" 2>/dev/null) || rc=$?
  [ "$rc" -eq 0 ] || return 1
  printf '%s' "$out" | jq -e '
    length > 0
    and (
      (map(select(.gate == "ship-choice")) | .[0]) as $c
      | $c != null
      and ($c.decision == "pr" or $c.decision == "merge")
      and $c.blocking_condition == null
      and $c.decided_by == "auto"
      and $c.council_tier == null
      and $c.grading_reason == null
      and (
        ([.[] | select(.gate == "ship-choice" and .run_id == $c.run_id)] | .[0])
        == $c
      )
    )
  ' >/dev/null 2>&1
}

# expect_rc <want> <desc> <cmd...>
expect_rc() {
  local want=$1 desc=$2; shift 2
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq "$want" ]; then pass "$desc"; else fail "$desc rc=$rc (want $want)"; fi
}

# ---- Temp git repo (fake MROOT via git-common-dir) ---------------------------
TMP=$(mktemp -d "${TMPDIR:-/tmp}/autopilot-test.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

git init -q "$TMP" || { echo "FAIL: git init" >&2; exit 1; }
cd "$TMP" || { echo "FAIL: cd $TMP" >&2; exit 1; }

AUTODIR="$TMP/.claude/autopilot"
reset() { rm -rf "$AUTODIR"; }
ledger() { echo "$AUTODIR/$1.jsonl"; }

# A known-valid 13-arg card (bump=null, plan-approve) — flip one field per case.
# order: workflow ticket gate decision decided_by bump confidence blocking run_id iter wall actor rationale

# =============================================================================
# (a) happy-path append → rc 0, 1 line, jq . parses, 18 keys, type/schema/ts
# =============================================================================
reset
RC=$(rc_of bash "$APPEND" orchestrate CDT-111 ship-choice merge auto patch 90 null run-1 3 120 orchestrator "ship it")
L=$(ledger CDT-111)
LINES=$(wc -l < "$L" 2>/dev/null | tr -d ' ')
if [ "$RC" -eq 0 ] && [ "${LINES:-0}" -eq 1 ] && jq -e . "$L" >/dev/null 2>&1; then
  pass "a1 happy-path append rc=0, 1 line, jq parses"
else
  fail "a1 rc=$RC lines=${LINES:-?} (want 0/1, jq-parseable)"
fi
KEYS_OK=$(jq -e '
  (keys_unsorted | length) == 18
  and has("schema_version") and has("type") and has("ts") and has("run_id")
  and has("workflow") and has("ticket_id") and has("gate") and has("decision")
  and has("decided_by") and has("bump") and has("confidence")
  and has("blocking_condition") and has("council_tier") and has("grading_reason")
  and has("max_loc") and has("rationale") and has("budget") and has("actor")
  and .council_tier == null and .grading_reason == null and .max_loc == null
  and .schema_version == 1 and .type == "autopilot_decision"
  and (.ts | test("^[0-9T:-]+Z$"))
  and (.budget | (has("iteration") and has("iteration_cap")
       and has("wall_clock_s") and has("wall_clock_cap_s")))
  and .budget.iteration_cap == 25 and .budget.wall_clock_cap_s == 2700
' "$L" >/dev/null 2>&1 && echo y || echo n)
if [ "$KEYS_OK" = "y" ]; then
  pass "a2 all 18 keys + type/schema_version/ts-shape + default budget caps"
else
  fail "a2 schema mismatch: $(cat "$L" 2>/dev/null)"
fi

# =============================================================================
# (b) append-only — prior line byte-identical after 2nd write
# =============================================================================
reset
bash "$APPEND" orchestrate CDT-111 plan-approve proceed auto null 70 null run-1 1 10 orch "first" >/dev/null 2>&1
L=$(ledger CDT-111)
LINE1=$(cat "$L")
bash "$APPEND" orchestrate CDT-111 plan-approve approve user null 65 null run-1 2 20 orch "second" >/dev/null 2>&1
LINES=$(wc -l < "$L" | tr -d ' ')
LINE1_AFTER=$(head -n 1 "$L")
if [ "$LINES" -eq 2 ] && [ "$LINE1" = "$LINE1_AFTER" ]; then
  pass "b append-only: 2 lines, prior line byte-identical"
else
  fail "b lines=$LINES prior_match=$([ "$LINE1" = "$LINE1_AFTER" ] && echo y || echo n)"
fi

# =============================================================================
# (c) wrong argc → 64
# =============================================================================
reset
expect_rc 64 "c1 argc=12 (one short) → 64" \
  bash "$APPEND" orchestrate CDT-111 plan-approve proceed auto null 70 null run-1 1 10 orch
expect_rc 64 "c2 argc=0 → 64" bash "$APPEND"
expect_rc 64 "c3 argc=14 (one over) → 64" \
  bash "$APPEND" orchestrate CDT-111 plan-approve proceed auto null 70 null run-1 1 10 orch "r" extra

# =============================================================================
# (d) each of the 5 bad-enum cases → 64 (workflow, gate, decision, decided_by, bump)
# =============================================================================
reset
expect_rc 64 "d1 bad workflow → 64" \
  bash "$APPEND" BOGUS CDT-111 plan-approve proceed auto null 70 null run-1 1 10 orch "r"
expect_rc 64 "d2 bad gate → 64" \
  bash "$APPEND" orchestrate CDT-111 BOGUS proceed auto null 70 null run-1 1 10 orch "r"
expect_rc 64 "d3 bad decision → 64" \
  bash "$APPEND" orchestrate CDT-111 plan-approve BOGUS auto null 70 null run-1 1 10 orch "r"
expect_rc 64 "d4 bad decided_by → 64" \
  bash "$APPEND" orchestrate CDT-111 plan-approve proceed BOGUS null 70 null run-1 1 10 orch "r"
expect_rc 64 "d5 bad bump → 64" \
  bash "$APPEND" orchestrate CDT-111 ship-choice merge auto BOGUS 70 null run-1 1 10 orch "r"

# =============================================================================
# (e) bump non-null + non-ship-choice gate → 64
# =============================================================================
reset
expect_rc 64 "e bump=patch on gate=scope-confirm → 64" \
  bash "$APPEND" orchestrate CDT-111 scope-confirm proceed auto patch 70 null run-1 1 10 orch "r"

# =============================================================================
# (f) blocking_condition=7 + confidence>=80 → 64 ; confidence<80 → rc 0
# =============================================================================
reset
expect_rc 64 "f1 blocking_condition=7 + confidence=80 → 64" \
  bash "$APPEND" orchestrate CDT-111 plan-approve halt auto null 80 7 run-1 1 10 orch "r"
reset
RC=$(rc_of bash "$APPEND" orchestrate CDT-111 plan-approve halt auto null 79 7 run-1 1 10 orch "bc7 low conf")
L=$(ledger CDT-111)
if [ "$RC" -eq 0 ] && jq -e '.blocking_condition == 7 and .confidence == 79' "$L" >/dev/null 2>&1; then
  pass "f2 blocking_condition=7 + confidence=79 → rc 0 (card written)"
else
  fail "f2 rc=$RC card=$(cat "$L" 2>/dev/null)"
fi

# =============================================================================
# (g) newline / tab in rationale → 64
# =============================================================================
reset
expect_rc 64 "g1 newline in rationale → 64" \
  bash "$APPEND" orchestrate CDT-111 plan-approve proceed auto null 70 null run-1 1 10 orch $'line1\nline2'
expect_rc 64 "g2 tab in rationale → 64" \
  bash "$APPEND" orchestrate CDT-111 plan-approve proceed auto null 70 null run-1 1 10 orch $'a\tb'

# =============================================================================
# (h) env override respected (AUTOPILOT_ITERATION_CAP=5 → budget.iteration_cap==5)
# =============================================================================
reset
AUTOPILOT_ITERATION_CAP=5 bash "$APPEND" orchestrate CDT-111 plan-approve proceed auto null 70 null run-1 1 10 orch "cap5" >/dev/null 2>&1
L=$(ledger CDT-111)
if jq -e '.budget.iteration_cap == 5' "$L" >/dev/null 2>&1; then
  pass "h env AUTOPILOT_ITERATION_CAP=5 → budget.iteration_cap==5"
else
  fail "h iteration_cap override not honored: $(cat "$L" 2>/dev/null)"
fi

# =============================================================================
# (i) reader empty → [] rc 0
# =============================================================================
reset
RC=0
OUT=$(bash "$READ" NOPE 2>/dev/null) || RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "[]" ]; then
  pass "i reader on empty/missing ledger → [] rc 0"
else
  fail "i reader empty rc=$RC out=$OUT (want [] / 0)"
fi

# =============================================================================
# (j) reader over N cards → array length N
# =============================================================================
reset
N=3
i=1
while [ "$i" -le "$N" ]; do
  bash "$APPEND" orchestrate CDT-J plan-approve proceed auto null 70 null run-1 "$i" 10 orch "card$i" >/dev/null 2>&1
  i=$((i + 1))
done
RC=0
LEN=$(bash "$READ" CDT-J 2>/dev/null | jq 'length') || RC=$?
if [ "$RC" -eq 0 ] && [ "$LEN" = "$N" ]; then
  pass "j reader over $N cards → array length $N"
else
  fail "j reader length rc=$RC len=$LEN (want $N)"
fi

# =============================================================================
# (k) reader bad argc → 64
# =============================================================================
expect_rc 64 "k1 reader argc=0 → 64" bash "$READ"
expect_rc 64 "k2 reader argc=2 → 64" bash "$READ" CDT-J extra

# =============================================================================
# (l) traversal-rejection for BOTH scripts (../evil → 64, nothing escapes)
# =============================================================================
reset
# would-be traversal target if the guard were absent: $MROOT/.claude/autopilot/../evil.jsonl
# → $MROOT/.claude/evil.jsonl
ESCAPE_TARGET="$TMP/.claude/evil.jsonl"
rm -f "$ESCAPE_TARGET"
expect_rc 64 "l1 writer ticket_id='../evil' → 64" \
  bash "$APPEND" orchestrate "../evil" plan-approve proceed auto null 70 null run-1 1 10 orch "r"
expect_rc 64 "l2 reader ticket_id='../evil' → 64" bash "$READ" "../evil"
# also reject a bare slash and a dot-only id (both outside the charset)
expect_rc 64 "l3 writer ticket_id='a/b' → 64" \
  bash "$APPEND" orchestrate "a/b" plan-approve proceed auto null 70 null run-1 1 10 orch "r"
expect_rc 64 "l4 reader ticket_id='..' → 64" bash "$READ" ".."
if [ ! -e "$ESCAPE_TARGET" ]; then
  pass "l5 no file written/read outside .claude/autopilot ($ESCAPE_TARGET absent)"
else
  fail "l5 traversal escaped: $ESCAPE_TARGET exists"
fi

# =============================================================================
# (m) budget-check.sh: within-budget → rc 0, breached:false, reason:"none"
# =============================================================================
OUT=$(bash "$BUDGET" 3 "$(date +%s)" 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.breached == false and .reason == "none"' >/dev/null 2>&1; then
  pass "m budget-check within-budget rc=0, breached:false, reason:none"
else
  fail "m rc=$RC out=$OUT (want 0 / breached:false / reason:none)"
fi

# =============================================================================
# (n) budget-check.sh: iteration breach via AUTOPILOT_ITERATION_CAP override → rc 6, reason:iteration
# =============================================================================
OUT=$(AUTOPILOT_ITERATION_CAP=2 bash "$BUDGET" 5 "$(date +%s)" 2>/dev/null); RC=$?
if [ "$RC" -eq 6 ] && echo "$OUT" | jq -e '.breached == true and .reason == "iteration" and .blocking_condition == 6' >/dev/null 2>&1; then
  pass "n budget-check iteration breach rc=6, reason:iteration"
else
  fail "n rc=$RC out=$OUT (want 6 / breached:true / reason:iteration)"
fi

# =============================================================================
# (o) budget-check.sh: wall-clock breach via backdated run_start_epoch → rc 6, reason:wall_clock
# =============================================================================
BACKDATED=$(( $(date +%s) - 3000 ))
OUT=$(bash "$BUDGET" 1 "$BACKDATED" 2>/dev/null); RC=$?
if [ "$RC" -eq 6 ] && echo "$OUT" | jq -e '.breached == true and .reason == "wall_clock" and .blocking_condition == 6' >/dev/null 2>&1; then
  pass "o budget-check wall-clock breach rc=6, reason:wall_clock"
else
  fail "o rc=$RC out=$OUT (want 6 / breached:true / reason:wall_clock)"
fi

# =============================================================================
# (p) budget-check.sh: both breach (iteration + wall-clock) → rc 6, reason:both
# =============================================================================
OUT=$(AUTOPILOT_ITERATION_CAP=2 bash "$BUDGET" 5 "$BACKDATED" 2>/dev/null); RC=$?
if [ "$RC" -eq 6 ] && echo "$OUT" | jq -e '.breached == true and .reason == "both" and .blocking_condition == 6' >/dev/null 2>&1; then
  pass "p budget-check both breach rc=6, reason:both"
else
  fail "p rc=$RC out=$OUT (want 6 / breached:true / reason:both)"
fi

# =============================================================================
# (q) budget-check.sh: non-numeric arg → 64
# =============================================================================
expect_rc 64 "q1 non-numeric iteration → 64" bash "$BUDGET" abc "$(date +%s)"
expect_rc 64 "q2 non-numeric run_start_epoch → 64" bash "$BUDGET" 3 abc

# =============================================================================
# (r) budget-check.sh: future run_start_epoch → 64
# =============================================================================
FUTURE=$(( $(date +%s) + 1000 ))
expect_rc 64 "r budget-check future run_start_epoch → 64" bash "$BUDGET" 1 "$FUTURE"

# =============================================================================
# (s) budget-check.sh: wrong argc → 64
# =============================================================================
expect_rc 64 "s1 budget-check argc=0 → 64" bash "$BUDGET"
expect_rc 64 "s2 budget-check argc=1 → 64" bash "$BUDGET" 3
expect_rc 64 "s3 budget-check argc=3 → 64" bash "$BUDGET" 3 100 200

# =============================================================================
# (t) budget-check.sh: env-override caps respected in JSON output
# =============================================================================
OUT=$(AUTOPILOT_ITERATION_CAP=10 AUTOPILOT_WALLCLOCK_CAP=500 bash "$BUDGET" 3 "$(date +%s)" 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.iteration_cap == 10 and .wall_clock_cap_s == 500' >/dev/null 2>&1; then
  pass "t budget-check env-override caps reflected in JSON (iteration_cap=10, wall_clock_cap_s=500)"
else
  fail "t rc=$RC out=$OUT (want iteration_cap=10 / wall_clock_cap_s=500)"
fi

# =============================================================================
# (u) budget-check.sh: JSON shape has all 7 keys
# =============================================================================
OUT=$(bash "$BUDGET" 3 "$(date +%s)" 2>/dev/null)
if echo "$OUT" | jq -e '
  (keys_unsorted | length) == 7
  and has("wall_clock_s") and has("iteration") and has("iteration_cap")
  and has("wall_clock_cap_s") and has("breached") and has("blocking_condition")
  and has("reason")
' >/dev/null 2>&1; then
  pass "u budget-check JSON shape has all 7 keys"
else
  fail "u JSON shape mismatch: $OUT"
fi

# =============================================================================
# (v) parse-flags.sh: flag-only (--autopilot) → enabled,null,flag
# =============================================================================
OUT=$(bash "$PARSE" --autopilot 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.enabled == true and .bump == null and .source == "flag"' >/dev/null 2>&1; then
  pass "v parse-flags flag-only → enabled:true, bump:null, source:flag"
else
  fail "v rc=$RC out=$OUT (want enabled:true/bump:null/source:flag)"
fi

# =============================================================================
# (w) parse-flags.sh: flag+bump (--autopilot=minor) → enabled,minor,flag
# =============================================================================
OUT=$(bash "$PARSE" --autopilot=minor 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.enabled == true and .bump == "minor" and .source == "flag"' >/dev/null 2>&1; then
  pass "w parse-flags flag+bump=minor → enabled:true, bump:minor, source:flag"
else
  fail "w rc=$RC out=$OUT (want enabled:true/bump:minor/source:flag)"
fi

# =============================================================================
# (x) parse-flags.sh: env-only (AUTOPILOT=1) → enabled,null,env
# =============================================================================
OUT=$(AUTOPILOT=1 bash "$PARSE" 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.enabled == true and .bump == null and .source == "env"' >/dev/null 2>&1; then
  pass "x parse-flags env-only AUTOPILOT=1 → enabled:true, bump:null, source:env"
else
  fail "x rc=$RC out=$OUT (want enabled:true/bump:null/source:env)"
fi

# =============================================================================
# (y) parse-flags.sh: flag+env both set → flag wins (--autopilot=major, AUTOPILOT=1)
# =============================================================================
OUT=$(AUTOPILOT=1 bash "$PARSE" --autopilot=major 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.enabled == true and .bump == "major" and .source == "flag"' >/dev/null 2>&1; then
  pass "y parse-flags flag+env both set → flag wins (bump:major, source:flag)"
else
  fail "y rc=$RC out=$OUT (want enabled:true/bump:major/source:flag)"
fi

# =============================================================================
# (z) parse-flags.sh: illegal bump (--autopilot=huge) → exit 64
# =============================================================================
expect_rc 64 "z parse-flags illegal bump --autopilot=huge → 64" bash "$PARSE" --autopilot=huge

# =============================================================================
# (aa) parse-flags.sh: empty bump (--autopilot=) → exit 64
# =============================================================================
expect_rc 64 "aa parse-flags empty bump --autopilot= → 64" bash "$PARSE" --autopilot=

# =============================================================================
# (ab) parse-flags.sh: off (AUTOPILOT=0, no flag) → false,null,none
# =============================================================================
OUT=$(AUTOPILOT=0 bash "$PARSE" 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.enabled == false and .bump == null and .source == "none"' >/dev/null 2>&1; then
  pass "ab parse-flags off AUTOPILOT=0 → enabled:false, bump:null, source:none"
else
  fail "ab rc=$RC out=$OUT (want enabled:false/bump:null/source:none)"
fi

# =============================================================================
# (ac) parse-flags.sh: unset (no flag, no env) → false,null,none
# =============================================================================
OUT=$(env -u AUTOPILOT bash "$PARSE" 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.enabled == false and .bump == null and .source == "none"' >/dev/null 2>&1; then
  pass "ac parse-flags unset (no flag/env) → enabled:false, bump:null, source:none"
else
  fail "ac rc=$RC out=$OUT (want enabled:false/bump:null/source:none)"
fi

# =============================================================================
# (ad) parse-flags.sh: JSON shape has all 6 keys (CDT-223 adds max_loc)
# =============================================================================
OUT=$(bash "$PARSE" --autopilot=patch 2>/dev/null)
if echo "$OUT" | jq -e '
  (keys_unsorted | length) == 6
  and has("enabled") and has("bump") and has("source") and has("council_tier")
  and has("tier") and has("max_loc")
' >/dev/null 2>&1; then
  pass "ad parse-flags JSON shape has all 6 keys"
else
  fail "ad JSON shape mismatch: $OUT"
fi


# =============================================================================
# (ae) resume-state.sh: no matching plan → {"found":false}
# =============================================================================
reset
PLANDIR="$TMP/.claude/plans"
rm -rf "$PLANDIR"
mkdir -p "$PLANDIR"
OUT=$(bash "$RESUME" CDT-RS 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = '{"found":false}' ]; then
  pass "ae resume-state no matching plan → {\"found\":false}"
else
  fail "ae rc=$RC out=$OUT (want 0 / {\"found\":false})"
fi

# =============================================================================
# (af) resume-state.sh: found, recorded state on:true bump:minor
# =============================================================================
rm -rf "$PLANDIR"
mkdir -p "$PLANDIR"
cat > "$PLANDIR/2026-08-04-CDT-RS-plan.md" << 'EOF'
## Tracking
- source: backlog
- ticket_id: CDT-RS
- autopilot_on: true
- autopilot_bump: minor
EOF
OUT=$(bash "$RESUME" CDT-RS 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.found == true and .autopilot_on == true and .autopilot_bump == "minor" and (.plan | test("2026-08-04-CDT-RS-plan.md$"))' >/dev/null 2>&1; then
  pass "af resume-state found, on:true bump:minor"
else
  fail "af rc=$RC out=$OUT (want found:true/on:true/bump:minor)"
fi

# =============================================================================
# (ag) resume-state.sh: found, recorded state on:false (bump always null)
# =============================================================================
rm -rf "$PLANDIR"
mkdir -p "$PLANDIR"
cat > "$PLANDIR/2026-08-04-CDT-RS-plan.md" << 'EOF'
## Tracking
- autopilot_on: false
- autopilot_bump: null
EOF
OUT=$(bash "$RESUME" CDT-RS 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.found == true and .autopilot_on == false and .autopilot_bump == null' >/dev/null 2>&1; then
  pass "ag resume-state found, on:false → bump:null"
else
  fail "ag rc=$RC out=$OUT (want found:true/on:false/bump:null)"
fi

# =============================================================================
# (ah) resume-state.sh: found, pre-C8 plan (no autopilot_on line) → on:null
# =============================================================================
rm -rf "$PLANDIR"
mkdir -p "$PLANDIR"
cat > "$PLANDIR/2026-08-04-CDT-RS-plan.md" << 'EOF'
## Tracking
- source: backlog
- ticket_id: CDT-RS
EOF
OUT=$(bash "$RESUME" CDT-RS 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.found == true and .autopilot_on == null and .autopilot_bump == null' >/dev/null 2>&1; then
  pass "ah resume-state found, pre-C8 plan (no autopilot_on) → on:null"
else
  fail "ah rc=$RC out=$OUT (want found:true/on:null/bump:null)"
fi

# =============================================================================
# (ai) resume-state.sh: two matching plans (different date prefixes) → most
# recently modified wins, regardless of filename sort order.
# =============================================================================
rm -rf "$PLANDIR"
mkdir -p "$PLANDIR"
cat > "$PLANDIR/2026-01-01-CDT-RS-old.md" << 'EOF'
## Tracking
- autopilot_on: false
EOF
cat > "$PLANDIR/2026-08-04-CDT-RS-new.md" << 'EOF'
## Tracking
- autopilot_on: true
- autopilot_bump: major
EOF
# Make the alphabetically-later filename the mtime-older one, so a
# filename-sort implementation and an mtime implementation disagree —
# proves the mtime rule is actually in effect.
touch -t 202001010000 "$PLANDIR/2026-08-04-CDT-RS-new.md"
OUT=$(bash "$RESUME" CDT-RS 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.found == true and (.plan | test("old.md$")) and .autopilot_on == false' >/dev/null 2>&1; then
  pass "ai resume-state multi-match → most recently modified wins"
else
  fail "ai rc=$RC out=$OUT (want plan=...old.md / on:false)"
fi
rm -rf "$PLANDIR"

# =============================================================================
# (aj) resume-state.sh: bad ISSUE-ID (path traversal) → 64
# =============================================================================
expect_rc 64 "aj1 resume-state ISSUE-ID='../evil' → 64" bash "$RESUME" "../evil"
expect_rc 64 "aj2 resume-state --accumulated ISSUE-ID='a/b' → 64" bash "$RESUME" --accumulated "a/b"
expect_rc 64 "aj3 resume-state wrong argc (0) → 64" bash "$RESUME"
expect_rc 64 "aj4 resume-state wrong argc (3) → 64" bash "$RESUME" a b c
expect_rc 64 "aj5 resume-state unknown flag → 64" bash "$RESUME" --bogus CDT-RS

# =============================================================================
# (ak) resume-state.sh --accumulated: 0 cards → 0
# =============================================================================
reset
OUT=$(bash "$RESUME" --accumulated CDT-RSACC 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "0" ]; then
  pass "ak resume-state --accumulated 0 cards → 0"
else
  fail "ak rc=$RC out=$OUT (want 0)"
fi

# =============================================================================
# (al) resume-state.sh --accumulated: 1 card → its wall_clock_s
# =============================================================================
reset
bash "$APPEND" orchestrate CDT-RSACC plan-approve proceed auto null 70 null run-1 1 42 orch "only" >/dev/null 2>&1
OUT=$(bash "$RESUME" --accumulated CDT-RSACC 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "42" ]; then
  pass "al resume-state --accumulated 1 card → 42"
else
  fail "al rc=$RC out=$OUT (want 42)"
fi

# =============================================================================
# (am) resume-state.sh --accumulated: N cards with varying wall_clock_s → max
# =============================================================================
reset
bash "$APPEND" orchestrate CDT-RSACC plan-approve proceed auto null 70 null run-1 1 100 orch "c1" >/dev/null 2>&1
bash "$APPEND" orchestrate CDT-RSACC plan-approve proceed auto null 70 null run-1 2 55 orch "c2" >/dev/null 2>&1
bash "$APPEND" orchestrate CDT-RSACC ship-choice merge auto patch 90 null run-1 3 300 orch "c3" >/dev/null 2>&1
OUT=$(bash "$RESUME" --accumulated CDT-RSACC 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "300" ]; then
  pass "am resume-state --accumulated N cards (100,55,300) → max 300"
else
  fail "am rc=$RC out=$OUT (want 300)"
fi

# =============================================================================
# (an) CDT-126: 15-arg ship-choice card carries council_tier/grading_reason
#      in the frozen M13 position (after blocking_condition, before rationale)
# =============================================================================
reset
RC=$(rc_of bash "$APPEND" orchestrate CDT-T ship-choice halt auto null 0 7 run-1 2 20 orch \
  "council disagreed (council_tier=light)" light "clear-low (files=3, loc=40)")
L=$(ledger CDT-T)
TIER_OK=$(jq -e '
  .council_tier == "light" and .grading_reason == "clear-low (files=3, loc=40)"
  and .max_loc == null
  and (keys_unsorted | index("council_tier")) == (keys_unsorted | index("blocking_condition")) + 1
  and (keys_unsorted | index("max_loc")) == (keys_unsorted | index("grading_reason")) + 1
  and (keys_unsorted | index("rationale")) == (keys_unsorted | index("max_loc")) + 1
' "$L" >/dev/null 2>&1 && echo y || echo n)
if [ "$RC" -eq 0 ] && [ "$TIER_OK" = "y" ]; then
  pass "an 15-arg append: tier fields present in frozen M13 key order"
else
  fail "an rc=$RC keys=$(cat "$L" 2>/dev/null)"
fi

# =============================================================================
# (ao) CDT-126: writer rejections — argc 14, bad tier enum, invariant (c),
#      control-char grading_reason
# =============================================================================
reset
expect_rc 64 "ao1 argc=14 (tier without reason) → 64" \
  bash "$APPEND" orchestrate CDT-T ship-choice pr auto patch 90 null run-1 1 10 orch "r" light
expect_rc 64 "ao2 council_tier='bogus' → 64" \
  bash "$APPEND" orchestrate CDT-T ship-choice pr auto patch 90 null run-1 1 10 orch "r" bogus "why"
expect_rc 64 "ao3 invariant (c): tier on plan-approve → 64" \
  bash "$APPEND" orchestrate CDT-T plan-approve proceed auto null 70 null run-1 1 10 orch "r" light "why"
expect_rc 64 "ao4 control-char grading_reason → 64" \
  bash "$APPEND" orchestrate CDT-T ship-choice pr auto patch 90 null run-1 1 10 orch "r" light "$(printf 'a\nb')"

# =============================================================================
# (ap) CDT-126: reader backfills absent tier keys as explicit nulls (M13
#      absent ≡ null) and hard-fails invariant (c) on a corrupt ledger
# =============================================================================
reset
mkdir -p "$AUTODIR"
LEGACY=$(ledger CDT-LEG)
echo '{"schema_version":1,"type":"autopilot_decision","gate":"ship-choice","blocking_condition":null,"rationale":"old","actor":"orch"}' > "$LEGACY"
RC=0
OUT=$(bash "$READ" CDT-LEG 2>/dev/null) || RC=$?
BACKFILL_OK=$(printf '%s' "$OUT" | jq -e '
  (.[0] | has("council_tier")) and (.[0].council_tier == null)
  and (.[0] | has("grading_reason")) and (.[0].grading_reason == null)
  and (.[0] | keys_unsorted | index("council_tier"))
      == (.[0] | keys_unsorted | index("blocking_condition")) + 1
' >/dev/null 2>&1 && echo y || echo n)
if [ "$RC" -eq 0 ] && [ "$BACKFILL_OK" = "y" ]; then
  pass "ap1 reader backfills absent tier keys as nulls in frozen position"
else
  fail "ap1 rc=$RC out=$OUT"
fi

CORRUPT=$(ledger CDT-COR)
echo '{"schema_version":1,"type":"autopilot_decision","gate":"plan-approve","blocking_condition":null,"council_tier":"light","grading_reason":"x","rationale":"r","actor":"orch"}' > "$CORRUPT"
expect_rc 64 "ap2 reader rejects tier on a non-ship-choice card → 64" bash "$READ" CDT-COR

# =============================================================================
# (aq) parse-flags.sh: --council-tier=light → council_tier:light, autopilot unaffected
# =============================================================================
OUT=$(bash "$PARSE" --council-tier=light 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.council_tier == "light" and .enabled == false and .bump == null and .source == "none"' >/dev/null 2>&1; then
  pass "aq parse-flags --council-tier=light → council_tier:light, autopilot untouched"
else
  fail "aq rc=$RC out=$OUT (want council_tier:light, enabled:false/bump:null/source:none)"
fi

# =============================================================================
# (ar) parse-flags.sh: --autopilot=minor --council-tier=skip → both resolve independently
# =============================================================================
OUT=$(bash "$PARSE" --autopilot=minor --council-tier=skip 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.enabled == true and .bump == "minor" and .source == "flag" and .council_tier == "skip"' >/dev/null 2>&1; then
  pass "ar parse-flags --autopilot=minor --council-tier=skip → both flags resolve independently"
else
  fail "ar rc=$RC out=$OUT (want enabled:true/bump:minor/source:flag/council_tier:skip)"
fi

# =============================================================================
# (as) parse-flags.sh: no --council-tier → council_tier:null
# =============================================================================
OUT=$(bash "$PARSE" --autopilot 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.council_tier == null' >/dev/null 2>&1; then
  pass "as parse-flags no --council-tier → council_tier:null"
else
  fail "as rc=$RC out=$OUT (want council_tier:null)"
fi

# =============================================================================
# (at) parse-flags.sh: illegal tier (--council-tier=bogus) → exit 64
# =============================================================================
expect_rc 64 "at parse-flags illegal tier --council-tier=bogus → 64" bash "$PARSE" --council-tier=bogus

# =============================================================================
# (au) parse-flags.sh: bare --council-tier (no value) → exit 64
# =============================================================================
expect_rc 64 "au parse-flags bare --council-tier (no value) → 64" bash "$PARSE" --council-tier

# =============================================================================
# (av) CDT-185: stamp predicate happy — clean ship-choice card #1 → PASS
# =============================================================================
reset
bash "$APPEND" orchestrate CDT-185 ship-choice merge auto patch 90 null run-1 1 10 orch \
  "clean ship" >/dev/null 2>&1
if process_stamps_ok CDT-185; then
  pass "av stamp predicate happy: clean merge card #1 → PASS"
else
  fail "av stamp predicate happy expected PASS; cards=$(bash "$READ" CDT-185 2>/dev/null)"
fi

# also pr decision stamps
reset
bash "$APPEND" orchestrate CDT-185 ship-choice pr auto patch 90 null run-1 1 10 orch \
  "clean pr" >/dev/null 2>&1
if process_stamps_ok CDT-185; then
  pass "av2 stamp predicate happy: clean pr card #1 → PASS"
else
  fail "av2 stamp predicate happy pr expected PASS"
fi

# =============================================================================
# (aw) CDT-185: stamp fail — missing ledger → fail
# =============================================================================
reset
if process_stamps_ok CDT-185-MISSING; then
  fail "aw missing ledger expected stamp FAIL"
else
  pass "aw stamp fail-closed: missing ledger → FAIL"
fi

# =============================================================================
# (ax) CDT-185: stamp fail — empty ledger [] → fail
# =============================================================================
reset
mkdir -p "$AUTODIR"
: > "$(ledger CDT-185-EMPTY)"
if process_stamps_ok CDT-185-EMPTY; then
  fail "ax empty ledger expected stamp FAIL"
else
  pass "ax stamp fail-closed: empty [] → FAIL"
fi

# =============================================================================
# (ay) CDT-185: stamp fail — halt card #1 with blocking_condition=7 → fail
# =============================================================================
reset
bash "$APPEND" orchestrate CDT-185 ship-choice halt auto null 0 7 run-1 1 10 orch \
  "bc7 halt" >/dev/null 2>&1
if process_stamps_ok CDT-185; then
  fail "ay BC7 halt card #1 expected stamp FAIL"
else
  pass "ay stamp fail-closed: blocking_condition=7 → FAIL"
fi

# =============================================================================
# (az) CDT-185: stamp fail — decision=halt (non-clean) → fail
# =============================================================================
reset
# halt with null BC still fails decision∈{pr,merge}
bash "$APPEND" orchestrate CDT-185 ship-choice halt auto null 50 null run-1 1 10 orch \
  "halt no bc" >/dev/null 2>&1
if process_stamps_ok CDT-185; then
  fail "az decision=halt expected stamp FAIL"
else
  pass "az stamp fail-closed: decision=halt → FAIL"
fi

# =============================================================================
# (ba) CDT-185: stamp fail — decided_by=user → fail
# =============================================================================
reset
bash "$APPEND" orchestrate CDT-185 ship-choice merge user patch 90 null run-1 1 10 orch \
  "human merge" >/dev/null 2>&1
if process_stamps_ok CDT-185; then
  fail "ba decided_by=user expected stamp FAIL"
else
  pass "ba stamp fail-closed: decided_by=user → FAIL"
fi

# =============================================================================
# (bb) CDT-185: stamp fail — non-null council_tier on first ship-choice → fail
# =============================================================================
reset
bash "$APPEND" orchestrate CDT-185 ship-choice merge auto patch 90 null run-1 1 10 orch \
  "tier on card1" light "clear-low (files=1, loc=10)" >/dev/null 2>&1
if process_stamps_ok CDT-185; then
  fail "bb non-null council_tier on card #1 expected stamp FAIL"
else
  pass "bb stamp fail-closed: non-null council_tier on first ship-choice → FAIL"
fi

# =============================================================================
# (bc) CDT-185: static claim contract — §3b technical-only / no process phrases
# =============================================================================
if [ ! -f "$SHIP_GATE" ]; then
  fail "bc ship-gate-council.md missing at $SHIP_GATE"
else
  # Extract §3b block (### 3b … next ## heading) for claim-template scoping.
  SEC3B=$(awk '
    /^### 3b\./ { grab=1 }
    grab && /^## / && !/^### / { exit }
    grab { print }
  ' "$SHIP_GATE")
  if [ -z "$SEC3B" ]; then
    fail "bc could not extract §3b from ship-gate-council.md"
  else
    HAS_TECH=$(printf '%s' "$SEC3B" | grep -E -q 'technical-only|narrow claim|process.stamp|process stamp' && echo y || echo n)
    HAS_QA=$(printf '%s' "$SEC3B" | grep -F -q 'QA PASS' && echo y || echo n)
    HAS_10B=$(printf '%s' "$SEC3B" | grep -F -q 'Step-10b' && echo y || echo n)
    HAS_RAW=$(printf '%s' "$SEC3B" | grep -E -q 'MUST NOT inject RAW_ARTIFACTS|MUST NOT.*RAW_ARTIFACTS' && echo y || echo n)
    if [ "$HAS_TECH" = "y" ]; then
      pass "bc1 §3b has technical-only / narrow-claim / process-stamp language"
    else
      fail "bc1 §3b missing technical-only/narrow-claim/process-stamp language"
    fi
    if [ "$HAS_QA" = "n" ] && [ "$HAS_10B" = "n" ]; then
      pass "bc2 §3b claim template has no QA PASS / Step-10b process assertions"
    else
      fail "bc2 §3b still contains process phrases (QA PASS=$HAS_QA Step-10b=$HAS_10B)"
    fi
    if [ "$HAS_RAW" = "y" ]; then
      pass "bc3 §3b forbids RAW_ARTIFACTS injection"
    else
      fail "bc3 §3b missing RAW_ARTIFACTS forbid"
    fi
  fi
fi

# =============================================================================
# (bd) CDT-185: procedure cites stamp pre-flight + M14(a) CDT-185
# =============================================================================
if [ -f "$SHIP_GATE" ] \
  && grep -q 'Process-stamp pre-flight' "$SHIP_GATE" \
  && grep -q 'CDT-185' "$SHIP_GATE" \
  && grep -q 'Agree without process stamps' "$SHIP_GATE"; then
  pass "bd ship-gate-council.md cites stamp pre-flight + CDT-185 + §7 stamp boundary"
else
  fail "bd procedure missing stamp pre-flight / CDT-185 / §7 stamp boundary"
fi

# =============================================================================
# (be) CDT-195: parse-flags --autopilot=master → enabled,master,flag
# =============================================================================
OUT=$(bash "$PARSE" --autopilot=master 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.enabled == true and .bump == "master" and .source == "flag"' >/dev/null 2>&1; then
  pass "be parse-flags --autopilot=master → enabled:true, bump:master, source:flag"
else
  fail "be rc=$RC out=$OUT (want enabled:true/bump:master/source:flag)"
fi

# =============================================================================
# (bf) CDT-195: illegal/empty bump still 64; error lists patch,minor,major,master
# =============================================================================
ERR=$(bash "$PARSE" --autopilot=huge 2>&1 >/dev/null) || true
RC=$(rc_of bash "$PARSE" --autopilot=huge)
if [ "$RC" -eq 64 ] \
  && echo "$ERR" | grep -q 'patch' \
  && echo "$ERR" | grep -q 'minor' \
  && echo "$ERR" | grep -q 'major' \
  && echo "$ERR" | grep -q 'master'; then
  pass "bf1 parse-flags illegal bump → 64 and error lists patch,minor,major,master"
else
  fail "bf1 rc=$RC err=$ERR (want 64 + four legal tokens)"
fi
ERR=$(bash "$PARSE" --autopilot= 2>&1 >/dev/null) || true
RC=$(rc_of bash "$PARSE" --autopilot=)
if [ "$RC" -eq 64 ] \
  && echo "$ERR" | grep -q 'patch' \
  && echo "$ERR" | grep -q 'minor' \
  && echo "$ERR" | grep -q 'major' \
  && echo "$ERR" | grep -q 'master'; then
  pass "bf2 parse-flags empty bump → 64 and error lists patch,minor,major,master"
else
  fail "bf2 rc=$RC err=$ERR (want 64 + four legal tokens)"
fi

# =============================================================================
# (bg) CDT-195: env AUTOPILOT never carries master (only 1|true enable)
# =============================================================================
OUT=$(AUTOPILOT=master bash "$PARSE" 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.enabled == false and .bump == null and .source == "none"' >/dev/null 2>&1; then
  pass "bg1 parse-flags AUTOPILOT=master → disabled (env cannot set master)"
else
  fail "bg1 rc=$RC out=$OUT (want enabled:false/bump:null/source:none)"
fi
OUT=$(AUTOPILOT=1 bash "$PARSE" 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.enabled == true and .bump == null and .source == "env"' >/dev/null 2>&1; then
  pass "bg2 parse-flags AUTOPILOT=1 still → enabled,null,env (regression)"
else
  fail "bg2 rc=$RC out=$OUT (want enabled:true/bump:null/source:env)"
fi

# =============================================================================
# (bh) CDT-195: release tokens still accepted (=patch|minor|major) + bare flag
# =============================================================================
for tok in patch minor major; do
  OUT=$(bash "$PARSE" --autopilot="$tok" 2>/dev/null); RC=$?
  if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e --arg t "$tok" '.enabled == true and .bump == $t and .source == "flag"' >/dev/null 2>&1; then
    pass "bh1 parse-flags --autopilot=$tok → bump:$tok (regression)"
  else
    fail "bh1 --autopilot=$tok rc=$RC out=$OUT"
  fi
done
OUT=$(bash "$PARSE" --autopilot 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.enabled == true and .bump == null and .source == "flag"' >/dev/null 2>&1; then
  pass "bh2 parse-flags bare --autopilot → enabled,null,flag (regression)"
else
  fail "bh2 rc=$RC out=$OUT (want enabled:true/bump:null/source:flag)"
fi

# =============================================================================
# (bi) CDT-195: append-card accepts master on ship-choice; rejects on non-ship
# =============================================================================
reset
RC=$(rc_of bash "$APPEND" orchestrate CDT-195 ship-choice merge auto master 90 null run-1 1 10 orch "land-no-release")
L=$(ledger CDT-195)
if [ "$RC" -eq 0 ] && [ -f "$L" ] \
  && jq -e '.[0].bump == "master" and .[0].gate == "ship-choice"' < <(jq -s . "$L") >/dev/null 2>&1; then
  pass "bi1 append-card bump=master on ship-choice → 0, card bump:master"
else
  fail "bi1 rc=$RC ledger=$(cat "$L" 2>/dev/null)"
fi
expect_rc 64 "bi2 append-card bump=master on gate=scope-confirm → 64" \
  bash "$APPEND" orchestrate CDT-195 scope-confirm proceed auto master 90 null run-1 1 10 orch "bad"

# =============================================================================
# (bj) CDT-195: resume-state autopilot_bump: master → JSON "master"
# =============================================================================
reset
PLANDIR="$TMP/.claude/plans"
rm -rf "$PLANDIR"
mkdir -p "$PLANDIR"
cat > "$PLANDIR/2026-08-10-CDT-195RS-plan.md" <<'EOF'
# plan
## Tracking
- source: linear
- ticket_id: CDT-195RS
- autopilot_on: true
- autopilot_bump: master
EOF
OUT=$(bash "$RESUME" CDT-195RS 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.found == true and .autopilot_on == true and .autopilot_bump == "master"' >/dev/null 2>&1; then
  pass "bj resume-state autopilot_bump: master → bump:master"
else
  fail "bj rc=$RC out=$OUT (want found:true/on:true/bump:master)"
fi

# =============================================================================
# (bk) CDT-206: no --tier → tier:null, exit 0
# =============================================================================
OUT=$(bash "$PARSE" 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e 'has("tier") and .tier == null' >/dev/null 2>&1; then
  pass "bk parse-flags no --tier → tier:null"
else
  fail "bk rc=$RC out=$OUT (want has(tier) and tier:null, rc=0)"
fi

# =============================================================================
# (bl) CDT-206: --tier=light → tier:light
# =============================================================================
OUT=$(bash "$PARSE" --tier=light 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.tier == "light"' >/dev/null 2>&1; then
  pass "bl parse-flags --tier=light → tier:light"
else
  fail "bl rc=$RC out=$OUT (want tier:light)"
fi

# =============================================================================
# (bm) CDT-206: --tier=standard → tier:standard
# =============================================================================
OUT=$(bash "$PARSE" --tier=standard 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.tier == "standard"' >/dev/null 2>&1; then
  pass "bm parse-flags --tier=standard → tier:standard"
else
  fail "bm rc=$RC out=$OUT (want tier:standard)"
fi

# =============================================================================
# (bn) CDT-206: --tier=full → tier:full
# =============================================================================
OUT=$(bash "$PARSE" --tier=full 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.tier == "full"' >/dev/null 2>&1; then
  pass "bn parse-flags --tier=full → tier:full"
else
  fail "bn rc=$RC out=$OUT (want tier:full)"
fi

# =============================================================================
# (bo) CDT-206: --tier=light --council-tier=full → independent
# =============================================================================
OUT=$(bash "$PARSE" --tier=light --council-tier=full 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.tier == "light" and .council_tier == "full"' >/dev/null 2>&1; then
  pass "bo parse-flags --tier=light --council-tier=full → independent"
else
  fail "bo rc=$RC out=$OUT (want tier:light, council_tier:full)"
fi

# =============================================================================
# (bp) CDT-206: --council-tier=light --tier=full → reverse independence
# =============================================================================
OUT=$(bash "$PARSE" --council-tier=light --tier=full 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.tier == "full" and .council_tier == "light"' >/dev/null 2>&1; then
  pass "bp parse-flags --council-tier=light --tier=full → reverse independence"
else
  fail "bp rc=$RC out=$OUT (want tier:full, council_tier:light)"
fi

# =============================================================================
# (bq) CDT-206: --autopilot=minor --tier=standard --council-tier=skip → all three independent
# =============================================================================
OUT=$(bash "$PARSE" --autopilot=minor --tier=standard --council-tier=skip 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.enabled == true and .bump == "minor" and .source == "flag" and .tier == "standard" and .council_tier == "skip"' >/dev/null 2>&1; then
  pass "bq parse-flags --autopilot=minor --tier=standard --council-tier=skip → all three independent"
else
  fail "bq rc=$RC out=$OUT (want enabled:true/bump:minor/source:flag/tier:standard/council_tier:skip)"
fi

# =============================================================================
# (br)–(bu) CDT-206: illegal --tier values → exit 64
# =============================================================================
expect_rc 64 "br parse-flags illegal --tier=skip → 64" bash "$PARSE" --tier=skip
expect_rc 64 "bs parse-flags illegal --tier=bogus → 64" bash "$PARSE" --tier=bogus
expect_rc 64 "bt parse-flags illegal --tier=std → 64" bash "$PARSE" --tier=std
expect_rc 64 "bu parse-flags illegal --tier=max → 64" bash "$PARSE" --tier=max

# =============================================================================
# (bv) CDT-206: empty --tier= → exit 64
# =============================================================================
expect_rc 64 "bv parse-flags empty --tier= → 64" bash "$PARSE" --tier=

# =============================================================================
# (bw) CDT-206: bare --tier → exit 64
# =============================================================================
expect_rc 64 "bw parse-flags bare --tier (no value) → 64" bash "$PARSE" --tier

# =============================================================================
# (bx) CDT-206: space form --tier light (two argv) → exit 64
# =============================================================================
expect_rc 64 "bx parse-flags space form --tier light → 64" bash "$PARSE" --tier light

# =============================================================================
# (by) CDT-206: --tier=LIGHT (case) → exit 64
# =============================================================================
expect_rc 64 "by parse-flags --tier=LIGHT → 64" bash "$PARSE" --tier=LIGHT

# =============================================================================
# (bz) CDT-206: --tier=Full (case) → exit 64
# =============================================================================
expect_rc 64 "bz parse-flags --tier=Full → 64" bash "$PARSE" --tier=Full

# =============================================================================
# (ca) CDT-206: duplicate --tier=full --tier=full → exit 64
# =============================================================================
expect_rc 64 "ca parse-flags duplicate --tier=full --tier=full → 64" bash "$PARSE" --tier=full --tier=full

# =============================================================================
# (cb) CDT-206: duplicate --tier=light --tier=standard → exit 64
# =============================================================================
expect_rc 64 "cb parse-flags duplicate --tier=light --tier=standard → 64" bash "$PARSE" --tier=light --tier=standard

# =============================================================================
# (cc) CDT-206: mixed argv --autopilot --tier=full --council-tier=light --resume-ship
# =============================================================================
OUT=$(bash "$PARSE" CDT-206 --autopilot --tier=full --council-tier=light --resume-ship 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.tier == "full" and .council_tier == "light" and .enabled == true and .bump == null and .source == "flag"' >/dev/null 2>&1; then
  pass "cc parse-flags mixed argv --tier=full; other flags unchanged; --resume-ship ignored"
else
  fail "cc rc=$RC out=$OUT (want tier:full, council_tier:light, enabled:true/bump:null/source:flag)"
fi

# --- CDT-223 T1 parse-flags max_loc ---
# =============================================================================
# omit → null; numeric → JSON number; unbound → JSON string; junk → 64;
# last-wins same-value and different-value; independence; 6-key JSON; env-ignore.
# =============================================================================

# omit → max_loc:null
OUT=$(bash "$PARSE" 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e 'has("max_loc") and .max_loc == null' >/dev/null 2>&1; then
  pass "cdt223-t1 omit --max-loc → max_loc:null"
else
  fail "cdt223-t1 omit rc=$RC out=$OUT (want max_loc:null, rc=0)"
fi

# numeric → JSON number (not string)
OUT=$(bash "$PARSE" --max-loc=4000 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.max_loc == 4000 and (.max_loc | type) == "number"' >/dev/null 2>&1; then
  pass "cdt223-t1 --max-loc=4000 → JSON number 4000"
else
  fail "cdt223-t1 numeric rc=$RC out=$OUT (want number 4000)"
fi

OUT=$(bash "$PARSE" --max-loc=1 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.max_loc == 1 and (.max_loc | type) == "number"' >/dev/null 2>&1; then
  pass "cdt223-t1 --max-loc=1 → JSON number 1"
else
  fail "cdt223-t1 min-numeric rc=$RC out=$OUT (want number 1)"
fi

# unbound → JSON string (case-sensitive)
OUT=$(bash "$PARSE" --max-loc=unbound 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.max_loc == "unbound" and (.max_loc | type) == "string"' >/dev/null 2>&1; then
  pass "cdt223-t1 --max-loc=unbound → JSON string unbound"
else
  fail "cdt223-t1 unbound rc=$RC out=$OUT (want string unbound)"
fi

# junk / 0 / negative / UNBOUND/off/none/unlimited/inf → 64, stderr, no success JSON
for junk in bogus 0 -1 UNBOUND off none unlimited inf; do
  OUT=$(bash "$PARSE" --max-loc="$junk" 2>/dev/null); RC=$?
  ERR=$(bash "$PARSE" --max-loc="$junk" 2>&1 >/dev/null) || true
  if [ "$RC" -eq 64 ] && [ -z "$OUT" ] && [ -n "$ERR" ]; then
    pass "cdt223-t1 junk --max-loc=$junk → 64, no success JSON, stderr"
  else
    fail "cdt223-t1 junk --max-loc=$junk rc=$RC out=$OUT err=$ERR"
  fi
done

# empty --max-loc=
OUT=$(bash "$PARSE" --max-loc= 2>/dev/null); RC=$?
ERR=$(bash "$PARSE" --max-loc= 2>&1 >/dev/null) || true
if [ "$RC" -eq 64 ] && [ -z "$OUT" ] && [ -n "$ERR" ]; then
  pass "cdt223-t1 empty --max-loc= → 64, no success JSON, stderr"
else
  fail "cdt223-t1 empty rc=$RC out=$OUT err=$ERR"
fi

# bare --max-loc
OUT=$(bash "$PARSE" --max-loc 2>/dev/null); RC=$?
ERR=$(bash "$PARSE" --max-loc 2>&1 >/dev/null) || true
if [ "$RC" -eq 64 ] && [ -z "$OUT" ] && [ -n "$ERR" ]; then
  pass "cdt223-t1 bare --max-loc → 64, no success JSON, stderr"
else
  fail "cdt223-t1 bare rc=$RC out=$OUT err=$ERR"
fi

# space form --max-loc n
OUT=$(bash "$PARSE" --max-loc 4000 2>/dev/null); RC=$?
ERR=$(bash "$PARSE" --max-loc 4000 2>&1 >/dev/null) || true
if [ "$RC" -eq 64 ] && [ -z "$OUT" ] && [ -n "$ERR" ]; then
  pass "cdt223-t1 space form --max-loc 4000 → 64, no success JSON, stderr"
else
  fail "cdt223-t1 space rc=$RC out=$OUT err=$ERR"
fi

# last-wins same-value
OUT=$(bash "$PARSE" --max-loc=4000 --max-loc=4000 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.max_loc == 4000 and (.max_loc | type) == "number"' >/dev/null 2>&1; then
  pass "cdt223-t1 last-wins same-value --max-loc=4000 --max-loc=4000 → 4000"
else
  fail "cdt223-t1 last-wins same rc=$RC out=$OUT (want number 4000)"
fi

OUT=$(bash "$PARSE" --max-loc=unbound --max-loc=unbound 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.max_loc == "unbound" and (.max_loc | type) == "string"' >/dev/null 2>&1; then
  pass "cdt223-t1 last-wins same-value --max-loc=unbound --max-loc=unbound → unbound"
else
  fail "cdt223-t1 last-wins same unbound rc=$RC out=$OUT (want string unbound)"
fi

# last-wins different-value
OUT=$(bash "$PARSE" --max-loc=4000 --max-loc=unbound 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.max_loc == "unbound" and (.max_loc | type) == "string"' >/dev/null 2>&1; then
  pass "cdt223-t1 last-wins different --max-loc=4000 --max-loc=unbound → unbound"
else
  fail "cdt223-t1 last-wins 4000→unbound rc=$RC out=$OUT (want string unbound)"
fi

OUT=$(bash "$PARSE" --max-loc=unbound --max-loc=2000 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.max_loc == 2000 and (.max_loc | type) == "number"' >/dev/null 2>&1; then
  pass "cdt223-t1 last-wins different --max-loc=unbound --max-loc=2000 → 2000"
else
  fail "cdt223-t1 last-wins unbound→2000 rc=$RC out=$OUT (want number 2000)"
fi

# independence of --autopilot / --council-tier / --tier
OUT=$(bash "$PARSE" --autopilot=minor --council-tier=skip --tier=light --max-loc=4000 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '
  .enabled == true and .bump == "minor" and .source == "flag"
  and .council_tier == "skip" and .tier == "light"
  and .max_loc == 4000 and (.max_loc | type) == "number"
' >/dev/null 2>&1; then
  pass "cdt223-t1 independence: all four flags resolve without writing each other"
else
  fail "cdt223-t1 independence rc=$RC out=$OUT"
fi

OUT=$(bash "$PARSE" --max-loc=unbound 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '
  .enabled == false and .bump == null and .source == "none"
  and .council_tier == null and .tier == null
  and .max_loc == "unbound" and (.max_loc | type) == "string"
' >/dev/null 2>&1; then
  pass "cdt223-t1 --max-loc=unbound alone does not enable other flags"
else
  fail "cdt223-t1 max_loc-alone rc=$RC out=$OUT"
fi

OUT=$(bash "$PARSE" --tier=light --council-tier=full --autopilot 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '
  .tier == "light" and .council_tier == "full" and .enabled == true
  and has("max_loc") and .max_loc == null
' >/dev/null 2>&1; then
  pass "cdt223-t1 other flags omit --max-loc → max_loc:null"
else
  fail "cdt223-t1 other-flags-omit rc=$RC out=$OUT"
fi

# 6-key JSON with max_loc set
OUT=$(bash "$PARSE" --max-loc=4000 2>/dev/null)
if echo "$OUT" | jq -e '
  (keys_unsorted | length) == 6
  and has("enabled") and has("bump") and has("source") and has("council_tier")
  and has("tier") and has("max_loc")
' >/dev/null 2>&1; then
  pass "cdt223-t1 --max-loc=4000 JSON has all 6 keys"
else
  fail "cdt223-t1 6-key JSON mismatch: $OUT"
fi

# MUST NOT read MAX_LOC / AUTOPILOT_MAX_LOC
OUT=$(MAX_LOC=4000 AUTOPILOT_MAX_LOC=unbound env -u AUTOPILOT bash "$PARSE" 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e 'has("max_loc") and .max_loc == null and .enabled == false' >/dev/null 2>&1; then
  pass "cdt223-t1 env MAX_LOC/AUTOPILOT_MAX_LOC ignored → max_loc:null"
else
  fail "cdt223-t1 env-ignore omit rc=$RC out=$OUT (want max_loc:null)"
fi

OUT=$(MAX_LOC=999 AUTOPILOT_MAX_LOC=unbound bash "$PARSE" --max-loc=4000 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.max_loc == 4000 and (.max_loc | type) == "number"' >/dev/null 2>&1; then
  pass "cdt223-t1 env does not override --max-loc=4000"
else
  fail "cdt223-t1 env-ignore flag rc=$RC out=$OUT (want number 4000)"
fi

# --- CDT-223 T2 loc-exclude ---
# SPEC-033 M15 arms 1–2: lockfile/snap/prefix excluded; linguist-generated=true
# excluded; =false counted; missing attrs → built-in only; src/vendor/x counted;
# usage 64. Helper does NOT classify test files (arm 3 is the caller).
LOC_EXCLUDE="$SCRIPT_DIR/loc-exclude.sh"
rm -f .gitattributes

# lockfile basenames (exact), nested and ./ stripped
for lf in package-lock.json yarn.lock pnpm-lock.yaml bun.lock bun.lockb \
          Cargo.lock composer.lock Gemfile.lock poetry.lock Pipfile.lock \
          uv.lock flake.lock go.sum; do
  expect_rc 0 "cdt223-t2 lockfile $lf excluded" bash "$LOC_EXCLUDE" is-excluded "$lf"
  expect_rc 0 "cdt223-t2 lockfile dir/$lf excluded" bash "$LOC_EXCLUDE" is-excluded "dir/$lf"
  expect_rc 0 "cdt223-t2 lockfile ./$lf excluded" bash "$LOC_EXCLUDE" is-excluded "./$lf"
done

# snap glob (basename)
expect_rc 0 "cdt223-t2 snap foo.snap excluded" bash "$LOC_EXCLUDE" is-excluded foo.snap
expect_rc 0 "cdt223-t2 snap dir/bar.snap excluded" bash "$LOC_EXCLUDE" is-excluded dir/bar.snap
expect_rc 0 "cdt223-t2 snap ./baz.snap excluded" bash "$LOC_EXCLUDE" is-excluded ./baz.snap
expect_rc 1 "cdt223-t2 snap foo.snap.bak counted" bash "$LOC_EXCLUDE" is-excluded foo.snap.bak
expect_rc 1 "cdt223-t2 snap foo.SNAP counted" bash "$LOC_EXCLUDE" is-excluded foo.SNAP

# vendored prefixes (after stripping ./); mid-path does NOT match
for pfx in vendor third_party node_modules; do
  expect_rc 0 "cdt223-t2 prefix $pfx/x excluded" bash "$LOC_EXCLUDE" is-excluded "$pfx/x"
  expect_rc 0 "cdt223-t2 prefix $pfx exact excluded" bash "$LOC_EXCLUDE" is-excluded "$pfx"
  expect_rc 0 "cdt223-t2 prefix ./$pfx/x excluded" bash "$LOC_EXCLUDE" is-excluded "./$pfx/x"
  expect_rc 1 "cdt223-t2 mid-path src/$pfx/x counted" bash "$LOC_EXCLUDE" is-excluded "src/$pfx/x"
done
# nested under vendor/ (arm 2 starts-with vendor/; * in case matches /)
expect_rc 0 "cdt223-t2 prefix vendor/pkg/foo.go nested excluded" bash "$LOC_EXCLUDE" is-excluded vendor/pkg/foo.go

# missing attrs → built-in only
rm -f .gitattributes
expect_rc 1 "cdt223-t2 missing-attrs src/foo.go counted" bash "$LOC_EXCLUDE" is-excluded src/foo.go
expect_rc 0 "cdt223-t2 missing-attrs go.sum still excluded" bash "$LOC_EXCLUDE" is-excluded go.sum

# linguist-generated=true / set excluded; =false counted (non-builtin)
printf '%s\n' 'gen.go linguist-generated=true' > .gitattributes
expect_rc 0 "cdt223-t2 linguist-generated=true excluded" bash "$LOC_EXCLUDE" is-excluded gen.go
printf '%s\n' 'set.go linguist-generated' > .gitattributes
expect_rc 0 "cdt223-t2 linguist-generated set excluded" bash "$LOC_EXCLUDE" is-excluded set.go
printf '%s\n' 'plain.go linguist-generated=false' > .gitattributes
expect_rc 1 "cdt223-t2 linguist-generated=false counted" bash "$LOC_EXCLUDE" is-excluded plain.go

# union: lockfile stays excluded even when linguist-generated=false
printf '%s\n' 'go.sum linguist-generated=false' > .gitattributes
expect_rc 0 "cdt223-t2 lockfile union beats linguist-generated=false" bash "$LOC_EXCLUDE" is-excluded go.sum

# *.pb.go / *_gen.* NOT built-in (attrs can still exclude)
rm -f .gitattributes
expect_rc 1 "cdt223-t2 foo.pb.go counted (not built-in)" bash "$LOC_EXCLUDE" is-excluded foo.pb.go
expect_rc 1 "cdt223-t2 foo_gen.go counted (not built-in)" bash "$LOC_EXCLUDE" is-excluded foo_gen.go
expect_rc 1 "cdt223-t2 foo_gen.bar counted (not built-in)" bash "$LOC_EXCLUDE" is-excluded foo_gen.bar
printf '%s\n' '*.pb.go linguist-generated' > .gitattributes
expect_rc 0 "cdt223-t2 foo.pb.go excluded via attrs" bash "$LOC_EXCLUDE" is-excluded foo.pb.go
rm -f .gitattributes

# arm 3 stays with caller — helper does NOT classify test/spec paths
expect_rc 1 "cdt223-t2 foo_test.go counted (not classified)" bash "$LOC_EXCLUDE" is-excluded foo_test.go
expect_rc 1 "cdt223-t2 tests/foo.go counted (not classified)" bash "$LOC_EXCLUDE" is-excluded tests/foo.go
expect_rc 1 "cdt223-t2 specs/bar.md counted (not classified)" bash "$LOC_EXCLUDE" is-excluded specs/bar.md

# malformed .gitattributes → arm 1 empty; built-in still runs; never halt
printf '%s\n' '[[[' > .gitattributes
expect_rc 1 "cdt223-t2 malformed attrs src/foo.go counted" bash "$LOC_EXCLUDE" is-excluded src/foo.go
expect_rc 0 "cdt223-t2 malformed attrs yarn.lock excluded" bash "$LOC_EXCLUDE" is-excluded yarn.lock
rm -f .gitattributes

# fail-open on git check-attr errors (never exit 2)
expect_rc 1 "cdt223-t2 git-fail-open non-builtin counted" env GIT_DIR=/dev/null bash "$LOC_EXCLUDE" is-excluded src/foo.go
expect_rc 0 "cdt223-t2 git-fail-open lockfile still excluded" env GIT_DIR=/dev/null bash "$LOC_EXCLUDE" is-excluded go.sum
failopen_rc=$(rc_of env GIT_DIR=/dev/null bash "$LOC_EXCLUDE" is-excluded src/foo.go)
if [ "$failopen_rc" -ne 2 ]; then
  pass "cdt223-t2 git-fail-open MUST NOT exit 2 (rc=$failopen_rc)"
else
  fail "cdt223-t2 git-fail-open exited 2"
fi

# usage 64
expect_rc 64 "cdt223-t2 usage no-args" bash "$LOC_EXCLUDE"
expect_rc 64 "cdt223-t2 usage missing path" bash "$LOC_EXCLUDE" is-excluded
expect_rc 64 "cdt223-t2 usage extra args" bash "$LOC_EXCLUDE" is-excluded foo bar
expect_rc 64 "cdt223-t2 usage bad command" bash "$LOC_EXCLUDE" exclude foo
expect_rc 64 "cdt223-t2 usage empty path" bash "$LOC_EXCLUDE" is-excluded ""

# --- CDT-223 T3 card max_loc ---
# =============================================================================
# CDT-223 T3: M13 max_loc additive-nullable (argc 13|14|15|16, frozen key order)
# =============================================================================
reset
RC=$(rc_of bash "$APPEND" orchestrate CDT-T3 plan-approve proceed auto null 70 null run-1 1 10 orch "r")
L=$(ledger CDT-T3)
if [ "$RC" -eq 0 ] && jq -e '.max_loc == null and .schema_version == 1 and (keys_unsorted | length) == 18' "$L" >/dev/null 2>&1; then
  pass "t3-13 13-arg append writes max_loc:null, schema_version=1, 18 keys"
else
  fail "t3-13 rc=$RC card=$(cat "$L" 2>/dev/null)"
fi

reset
RC=$(rc_of bash "$APPEND" orchestrate CDT-T3 plan-approve proceed auto null 70 null run-1 1 10 orch "r" 4000)
L=$(ledger CDT-T3)
if [ "$RC" -eq 0 ] && jq -e '.max_loc == 4000 and (.max_loc | type) == "number" and .council_tier == null and .grading_reason == null' "$L" >/dev/null 2>&1; then
  pass "t3-14n 14-arg append writes max_loc number, council pair null"
else
  fail "t3-14n rc=$RC card=$(cat "$L" 2>/dev/null)"
fi

reset
RC=$(rc_of bash "$APPEND" orchestrate CDT-T3 plan-approve proceed auto null 70 null run-1 1 10 orch "r" unbound)
L=$(ledger CDT-T3)
if [ "$RC" -eq 0 ] && jq -e '.max_loc == "unbound" and (.max_loc | type) == "string"' "$L" >/dev/null 2>&1; then
  pass "t3-14u 14-arg append writes max_loc:\"unbound\""
else
  fail "t3-14u rc=$RC card=$(cat "$L" 2>/dev/null)"
fi

reset
bash "$APPEND" orchestrate CDT-T3 plan-approve proceed auto null 70 null run-1 1 10 orch "r" 2000 >/dev/null 2>&1
L=$(ledger CDT-T3)
POS_OK=$(jq -e '
  (keys_unsorted | index("max_loc")) == (keys_unsorted | index("grading_reason")) + 1
  and (keys_unsorted | index("rationale")) == (keys_unsorted | index("max_loc")) + 1
' "$L" >/dev/null 2>&1 && echo y || echo n)
if [ "$POS_OK" = "y" ]; then
  pass "t3-pos max_loc immediately after grading_reason, before rationale"
else
  fail "t3-pos keys=$(jq -c 'keys_unsorted' "$L" 2>/dev/null)"
fi

reset
RC=$(rc_of bash "$APPEND" orchestrate CDT-T3 ship-choice pr auto patch 90 null run-1 1 10 orch "r" light "why")
L=$(ledger CDT-T3)
if [ "$RC" -eq 0 ] && jq -e 'has("max_loc") and .council_tier == "light" and .grading_reason == "why" and .max_loc == null' "$L" >/dev/null 2>&1; then
  pass "t3-15 15-arg append writes council pair, max_loc:null"
else
  fail "t3-15 rc=$RC card=$(cat "$L" 2>/dev/null)"
fi

reset
RC=$(rc_of bash "$APPEND" orchestrate CDT-T3 ship-choice pr auto patch 90 null run-1 1 10 orch "r" full "band" unbound)
L=$(ledger CDT-T3)
if [ "$RC" -eq 0 ] && jq -e '.council_tier == "full" and .grading_reason == "band" and .max_loc == "unbound"' "$L" >/dev/null 2>&1; then
  pass "t3-16 16-arg append writes council pair + max_loc"
else
  fail "t3-16 rc=$RC card=$(cat "$L" 2>/dev/null)"
fi

reset
RC=$(rc_of bash "$APPEND" orchestrate CDT-T3 scope-confirm proceed auto null 70 null run-1 1 10 orch "r" null null 3000)
L=$(ledger CDT-T3)
if [ "$RC" -eq 0 ] && jq -e '.gate == "scope-confirm" and .max_loc == 3000 and .council_tier == null' "$L" >/dev/null 2>&1; then
  pass "t3-gate max_loc legal on scope-confirm (not ship-choice-only)"
else
  fail "t3-gate rc=$RC card=$(cat "$L" 2>/dev/null)"
fi

expect_rc 64 "t3-argc17 argc=17 → 64" \
  bash "$APPEND" orchestrate CDT-T3 plan-approve proceed auto null 70 null run-1 1 10 orch "r" light "why" 4000 extra
expect_rc 64 "t3-bad0 max_loc=0 → 64" \
  bash "$APPEND" orchestrate CDT-T3 plan-approve proceed auto null 70 null run-1 1 10 orch "r" 0
expect_rc 64 "t3-badU max_loc=UNBOUND → 64" \
  bash "$APPEND" orchestrate CDT-T3 plan-approve proceed auto null 70 null run-1 1 10 orch "r" UNBOUND
expect_rc 64 "t3-badn max_loc=-1 → 64" \
  bash "$APPEND" orchestrate CDT-T3 plan-approve proceed auto null 70 null run-1 1 10 orch "r" -1

reset
mkdir -p "$AUTODIR"
PRE=$(ledger CDT-PREML)
echo '{"schema_version":1,"type":"autopilot_decision","gate":"plan-approve","blocking_condition":null,"council_tier":null,"grading_reason":null,"rationale":"old","actor":"orch"}' > "$PRE"
RC=0
OUT=$(bash "$READ" CDT-PREML 2>/dev/null) || RC=$?
BF_OK=$(printf '%s' "$OUT" | jq -e '
  (.[0] | has("max_loc")) and (.[0].max_loc == null)
  and (.[0] | keys_unsorted | index("max_loc"))
      == (.[0] | keys_unsorted | index("grading_reason")) + 1
  and (.[0] | keys_unsorted | index("rationale"))
      == (.[0] | keys_unsorted | index("max_loc")) + 1
' >/dev/null 2>&1 && echo y || echo n)
if [ "$RC" -eq 0 ] && [ "$BF_OK" = "y" ]; then
  pass "t3-bf1 reader backfills absent max_loc as null after grading_reason"
else
  fail "t3-bf1 rc=$RC out=$OUT"
fi

reset
mkdir -p "$AUTODIR"
PRE126=$(ledger CDT-PRE126)
echo '{"schema_version":1,"type":"autopilot_decision","gate":"ship-choice","blocking_condition":null,"rationale":"old","actor":"orch"}' > "$PRE126"
RC=0
OUT=$(bash "$READ" CDT-PRE126 2>/dev/null) || RC=$?
BF126_OK=$(printf '%s' "$OUT" | jq -e '
  (.[0] | has("council_tier")) and (.[0].council_tier == null)
  and (.[0] | has("grading_reason")) and (.[0].grading_reason == null)
  and (.[0] | has("max_loc")) and (.[0].max_loc == null)
  and (.[0] | keys_unsorted | index("council_tier"))
      == (.[0] | keys_unsorted | index("blocking_condition")) + 1
  and (.[0] | keys_unsorted | index("max_loc"))
      == (.[0] | keys_unsorted | index("grading_reason")) + 1
' >/dev/null 2>&1 && echo y || echo n)
if [ "$RC" -eq 0 ] && [ "$BF126_OK" = "y" ]; then
  pass "t3-bf2 reader backfills pre-CDT-126 card with council pair AND max_loc"
else
  fail "t3-bf2 rc=$RC out=$OUT"
fi

# --- CDT-223 T7 QA holes (AC8 M15/M16) ---
# Resume MUST NOT seed max_loc (N11). Kickoff MUST NOT document/bind --max-loc
# (junk still 64 via shared parser). F4/F4-* writer shapes + decided_by=auto.
# M13 JSON keys/order match SPEC-033. Does not weaken ACs.
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
AP_SKILL="$SCRIPT_DIR/SKILL.md"
SPEC033="$ROOT/specs/core/SPEC-033-autopilot-policy.md"
SCEN="$SCRIPT_DIR/self-answer-scenarios.md"
KICKOFF_SKILL="$ROOT/skills/kickoff/SKILL.md"
EPIC_SKILL="$ROOT/skills/epic/SKILL.md"
ORCH_SKILL="$ROOT/skills/orchestrate/SKILL.md"
SCAFFOLD_SKILL="$ROOT/skills/scaffold-project/SKILL.md"
: "${LOC_EXCLUDE:=$SCRIPT_DIR/loc-exclude.sh}"

# F4 rewritten: counted hand-written path vs F4-gen excluded lockfile/snap
expect_rc 1 "cdt223-t7 F4 counted src/impl.go" bash "$LOC_EXCLUDE" is-excluded src/impl.go
expect_rc 0 "cdt223-t7 F4-gen package-lock.json excluded" bash "$LOC_EXCLUDE" is-excluded package-lock.json
expect_rc 0 "cdt223-t7 F4-gen foo.snap excluded" bash "$LOC_EXCLUDE" is-excluded foo.snap

# F4 rewritten card (argc 13, max_loc null, decided_by auto, BC4 halt)
reset
RC=$(rc_of bash "$APPEND" orchestrate CDT-200 plan-approve halt auto null 85 4 ap-rs 4 60 orchestrator \
  "one counted hand-written file 1400 lines exceeds per-file cap")
L=$(ledger CDT-200)
if [ "$RC" -eq 0 ] && jq -e '
  .decision == "halt" and .blocking_condition == 4 and .decided_by == "auto"
  and .max_loc == null and .gate == "plan-approve"
' "$L" >/dev/null 2>&1; then
  pass "cdt223-t7 F4 rewritten card argc13 halt bc=4 decided_by=auto max_loc=null"
else
  fail "cdt223-t7 F4 rewritten rc=$RC card=$(cat "$L" 2>/dev/null)"
fi

# F4-gen card: excluded 1400 → approve, no BC4
reset
RC=$(rc_of bash "$APPEND" orchestrate CDT-200 plan-approve approve auto null 88 null ap-rs 4 60 orchestrator \
  "lockfile 1400 excluded; counted LOC within caps")
L=$(ledger CDT-200)
if [ "$RC" -eq 0 ] && jq -e '
  .decision == "approve" and .blocking_condition == null and .decided_by == "auto"
  and .max_loc == null
' "$L" >/dev/null 2>&1; then
  pass "cdt223-t7 F4-gen card argc13 approve no BC4 decided_by=auto"
else
  fail "cdt223-t7 F4-gen rc=$RC card=$(cat "$L" 2>/dev/null)"
fi

# F4-n-tight plan-approve → BC4 halt argc 14; rationale mentions override
reset
RC=$(rc_of bash "$APPEND" orchestrate CDT-200 plan-approve halt auto null 85 4 ap-rs 4 60 orchestrator \
  "max-loc=1500 tightens per-PR; counted 1800 exceeds n" 1500)
L=$(ledger CDT-200)
if [ "$RC" -eq 0 ] && jq -e '
  .decision == "halt" and .blocking_condition == 4 and .decided_by == "auto"
  and .max_loc == 1500 and (.max_loc | type) == "number"
  and (.rationale | test("max-loc=1500"))
' "$L" >/dev/null 2>&1; then
  pass "cdt223-t7 F4-n-tight plan-approve argc14 halt bc=4 decided_by=auto"
else
  fail "cdt223-t7 F4-n-tight plan rc=$RC card=$(cat "$L" 2>/dev/null)"
fi

# F4-n-tight scope-confirm → M10.1 reroute-epic
reset
RC=$(rc_of bash "$APPEND" orchestrate CDT-200 scope-confirm reroute-epic auto null 85 5 ap-rs 2 60 orchestrator \
  "max-loc=1500; counted 1800 trips M10.1" 1500)
L=$(ledger CDT-200)
if [ "$RC" -eq 0 ] && jq -e '
  .decision == "reroute-epic" and .blocking_condition == 5 and .decided_by == "auto"
  and .max_loc == 1500 and .gate == "scope-confirm"
' "$L" >/dev/null 2>&1; then
  pass "cdt223-t7 F4-n-tight scope-confirm argc14 reroute-epic M10.1 decided_by=auto"
else
  fail "cdt223-t7 F4-n-tight scope rc=$RC card=$(cat "$L" 2>/dev/null)"
fi

# F4-unbound-m10: unbound does not disable M10.2 → BC5 reroute-epic
reset
RC=$(rc_of bash "$APPEND" orchestrate CDT-200 scope-confirm reroute-epic auto null 85 5 ap-rs 1 60 orchestrator \
  "max-loc=unbound; 4 workstreams still M10.2 overflow" unbound)
L=$(ledger CDT-200)
if [ "$RC" -eq 0 ] && jq -e '
  .decision == "reroute-epic" and .blocking_condition == 5 and .decided_by == "auto"
  and .max_loc == "unbound" and (.max_loc | type) == "string"
  and (.rationale | test("max-loc=unbound"))
' "$L" >/dev/null 2>&1; then
  pass "cdt223-t7 F4-unbound-m10 argc14 reroute-epic M10.2 decided_by=auto"
else
  fail "cdt223-t7 F4-unbound-m10 rc=$RC card=$(cat "$L" 2>/dev/null)"
fi

# Fixtures: F4 is hand-written; F4-gen is lockfile/snap; table matches M16
if grep -q 'hand-written implementation' "$SCEN" \
  && grep -q 'package-lock.json' "$SCEN" \
  && grep -q 'F4-gen' "$SCEN" \
  && grep -q 'plan-approve BC4 halt; scope-confirm M10.1 reroute' "$SCEN" \
  && grep -q 'F4-unbound-m10' "$SCEN" \
  && grep -q 'reroute-epic' "$SCEN"; then
  pass "cdt223-t7 scenarios F4 rewritten hand-written; F4-gen/F4-n-tight/F4-unbound-m10 present"
else
  fail "cdt223-t7 scenarios F4 fixture text missing required M16 signals"
fi

# Kickoff: --max-loc=bogus → 64 (shared parser, kickoff Step 0)
OUT=$(bash "$PARSE" --autopilot --max-loc=bogus 2>/dev/null); RC=$?
ERR=$(bash "$PARSE" --autopilot --max-loc=bogus 2>&1 >/dev/null) || true
if [ "$RC" -eq 64 ] && [ -z "$OUT" ] && [ -n "$ERR" ]; then
  pass "cdt223-t7 kickoff argv --max-loc=bogus → 64"
else
  fail "cdt223-t7 kickoff bogus rc=$RC out=$OUT err=$ERR"
fi
# --max-loc=4000 parses; kickoff MUST NOT document the flag (gates unchanged).
# M13 still requires cards to record the parse: envelopes that pass
# max_loc:MAX_LOC MUST have Step 0 bind MAX_LOC=$(jq …) from AP_JSON.
OUT=$(bash "$PARSE" --autopilot --max-loc=4000 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.max_loc == 4000' >/dev/null 2>&1 \
  && ! grep -q '\[--max-loc' "$KICKOFF_SKILL"; then
  pass "cdt223-t7 kickoff --max-loc=4000 unused as a documented flag (no Arguments row)"
else
  fail "cdt223-t7 kickoff unused-docs rc=$RC out=$OUT"
fi
for pair in "kickoff:$KICKOFF_SKILL" "epic:$EPIC_SKILL"; do
  name="${pair%%:*}"
  skill="${pair#*:}"
  if grep -q 'max_loc:MAX_LOC' "$skill"; then
    if grep -q 'MAX_LOC=$(jq' "$skill"; then
      pass "cdt223-t7 $name envelopes pass MAX_LOC and Step 0 binds it"
    else
      fail "cdt223-t7 $name envelopes pass max_loc:MAX_LOC but Step 0 does not bind MAX_LOC=\$(jq"
    fi
  else
    pass "cdt223-t7 $name envelopes omit max_loc (caller-null → argc 13)"
  fi
done

# Resume without --max-loc → parse max_loc:null; resume-state has no max_loc key
# even if the plan tracking line names one (N11: MUST NOT resume-seed)
OUT=$(env -u AUTOPILOT bash "$PARSE" 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.max_loc == null' >/dev/null 2>&1; then
  pass "cdt223-t7 resume-omit parse-flags → max_loc:null"
else
  fail "cdt223-t7 resume-omit parse rc=$RC out=$OUT"
fi
PLANDIR="$TMP/.claude/plans"
rm -rf "$PLANDIR"
mkdir -p "$PLANDIR"
cat > "$PLANDIR/2026-08-27-CDT-RS-plan.md" << 'EOF'
## Tracking
- autopilot_on: true
- autopilot_bump: minor
- max_loc: 4000
EOF
OUT=$(bash "$RESUME" CDT-RS 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '
  .found == true and .autopilot_on == true and .autopilot_bump == "minor"
  and (has("max_loc") | not)
' >/dev/null 2>&1; then
  pass "cdt223-t7 resume-state ignores plan max_loc (no JSON key)"
else
  fail "cdt223-t7 resume-state max_loc leak rc=$RC out=$OUT"
fi
rm -rf "$PLANDIR"

# orch SKILL ≤80; M13 JSON keys/order match SPEC-033 (indent-stripped bodies)
N=$(wc -l < "$ORCH_SKILL" | tr -d ' ')
if [ "$N" -le 80 ]; then
  pass "cdt223-t7 orchestrate SKILL.md ≤80 lines (got $N)"
else
  fail "cdt223-t7 orchestrate SKILL.md is $N lines (must be ≤80)"
fi
m13_body() {
  awk '
    /^[[:space:]]*```json[[:space:]]*$/ {p=1; next}
    p && /^[[:space:]]*```[[:space:]]*$/ {exit}
    p { sub(/^[[:space:]]+/, ""); print }
  ' "$1"
}
if cmp -s <(m13_body "$SPEC033") <(m13_body "$AP_SKILL"); then
  pass "cdt223-t7 M13 JSON fence keys/order match SPEC-033"
else
  fail "cdt223-t7 M13 JSON fence mismatch vs SPEC-033"
fi

# scaffold seed: append-missing heredoc has M15 paths, no *.pb.go
if grep -q 'append missing markers only' "$SCAFFOLD_SKILL" \
  && grep -q 'package-lock.json' "$SCAFFOLD_SKILL" \
  && grep -q 'vendor/\*\*' "$SCAFFOLD_SKILL" \
  && ! grep -E '^[[:space:]]*\*\.pb\.go' "$SCAFFOLD_SKILL"; then
  pass "cdt223-t7 scaffold seeds .gitattributes append-missing; no *.pb.go in seed"
else
  fail "cdt223-t7 scaffold seed missing or contains *.pb.go"
fi

# --- CDT-224 T2 ---
# =============================================================================
# CDT-224 T2: M13 nested budget.{tier,source,signals} via AUTOPILOT_BUDGET_META
# =============================================================================
BUDGET_KEYS='["iteration","iteration_cap","wall_clock_s","wall_clock_cap_s","tier","source","signals"]'
META_S_AUTO='{"iteration_cap":10,"wall_clock_cap_s":1200,"tier":"S","source":"auto","signals":{"tasks":2,"projected_loc":150,"waves":1}}'
META_MIXED='{"iteration_cap":25,"wall_clock_cap_s":1200,"tier":"S","source":"mixed","signals":{"tasks":2,"projected_loc":150,"waves":1}}'

# META unset → nested null + 25/2700; frozen 7-key budget; top-level still 18
reset
RC=$(rc_of env -u AUTOPILOT_BUDGET_META -u AUTOPILOT_ITERATION_CAP -u AUTOPILOT_WALLCLOCK_CAP \
  bash "$APPEND" orchestrate CDT-T2 plan-approve proceed auto null 70 null run-1 1 10 orch "r")
L=$(ledger CDT-T2)
if [ "$RC" -eq 0 ] && jq -e --argjson bk "$BUDGET_KEYS" '
  (keys_unsorted | length) == 18
  and .budget.iteration_cap == 25 and .budget.wall_clock_cap_s == 2700
  and .budget.tier == null and .budget.source == null and .budget.signals == null
  and (.budget | keys_unsorted) == $bk
' "$L" >/dev/null 2>&1; then
  pass "t2-unset META unset → nested null + 25/2700, keys_unsorted length==18"
else
  fail "t2-unset rc=$RC card=$(cat "$L" 2>/dev/null)"
fi

# META S auto
reset
RC=$(rc_of env AUTOPILOT_BUDGET_META="$META_S_AUTO" \
  bash "$APPEND" orchestrate CDT-T2 plan-approve approve auto null 85 null run-1 1 10 orch "budget_tier=S")
L=$(ledger CDT-T2)
if [ "$RC" -eq 0 ] && jq -e --argjson bk "$BUDGET_KEYS" '
  (keys_unsorted | length) == 18
  and .budget.iteration_cap == 10 and .budget.wall_clock_cap_s == 1200
  and .budget.tier == "S" and .budget.source == "auto"
  and .budget.signals.tasks == 2 and .budget.signals.projected_loc == 150
  and .budget.signals.waves == 1
  and (.budget | keys_unsorted) == $bk
' "$L" >/dev/null 2>&1; then
  pass "t2-s-auto META S auto writes 10/1200 + nested S/auto/signals"
else
  fail "t2-s-auto rc=$RC card=$(cat "$L" 2>/dev/null)"
fi

# META mixed (one env + one auto)
reset
RC=$(rc_of env AUTOPILOT_BUDGET_META="$META_MIXED" \
  bash "$APPEND" orchestrate CDT-T2 plan-approve approve auto null 85 null run-1 1 10 orch "budget_tier=S env")
L=$(ledger CDT-T2)
if [ "$RC" -eq 0 ] && jq -e '
  .budget.iteration_cap == 25 and .budget.wall_clock_cap_s == 1200
  and .budget.tier == "S" and .budget.source == "mixed"
  and .budget.signals.tasks == 2
' "$L" >/dev/null 2>&1; then
  pass "t2-mixed META mixed writes 25/1200 + nested S/mixed"
else
  fail "t2-mixed rc=$RC card=$(cat "$L" 2>/dev/null)"
fi

# META ignores AUTOPILOT_ITERATION_CAP
reset
RC=$(rc_of env AUTOPILOT_ITERATION_CAP=99 AUTOPILOT_WALLCLOCK_CAP=99 \
  AUTOPILOT_BUDGET_META="$META_S_AUTO" \
  bash "$APPEND" orchestrate CDT-T2 plan-approve proceed auto null 70 null run-1 1 10 orch "r")
L=$(ledger CDT-T2)
if [ "$RC" -eq 0 ] && jq -e '
  .budget.iteration_cap == 10 and .budget.wall_clock_cap_s == 1200
  and .budget.tier == "S"
' "$L" >/dev/null 2>&1; then
  pass "t2-meta-ignores-cap META ignores AUTOPILOT_ITERATION_CAP/WALLCLOCK_CAP"
else
  fail "t2-meta-ignores-cap rc=$RC card=$(cat "$L" 2>/dev/null)"
fi

# reader backfill: pre-CDT-224 4-key budget → nested nulls in frozen order
reset
mkdir -p "$AUTODIR"
PRE224=$(ledger CDT-PRE224)
echo '{"schema_version":1,"type":"autopilot_decision","gate":"plan-approve","blocking_condition":null,"council_tier":null,"grading_reason":null,"max_loc":null,"rationale":"old","budget":{"iteration":1,"iteration_cap":25,"wall_clock_s":10,"wall_clock_cap_s":2700},"actor":"orch"}' > "$PRE224"
RC=0
OUT=$(bash "$READ" CDT-PRE224 2>/dev/null) || RC=$?
BF_OK=$(printf '%s' "$OUT" | jq -e --argjson bk "$BUDGET_KEYS" '
  .[0].budget.tier == null and .[0].budget.source == null and .[0].budget.signals == null
  and (.[0].budget | keys_unsorted) == $bk
  and .[0].budget.iteration_cap == 25 and .[0].budget.wall_clock_cap_s == 2700
' >/dev/null 2>&1 && echo y || echo n)
if [ "$RC" -eq 0 ] && [ "$BF_OK" = "y" ]; then
  pass "t2-bf reader backfills absent nested budget.tier/source/signals as null"
else
  fail "t2-bf rc=$RC out=$OUT"
fi

# t3-13 still 18 keys (13-arg append after nested budget)
reset
RC=$(rc_of env -u AUTOPILOT_BUDGET_META \
  bash "$APPEND" orchestrate CDT-T3 plan-approve proceed auto null 70 null run-1 1 10 orch "r")
L=$(ledger CDT-T3)
if [ "$RC" -eq 0 ] && jq -e '.max_loc == null and .schema_version == 1 and (keys_unsorted | length) == 18' "$L" >/dev/null 2>&1; then
  pass "t2-t3-13 13-arg append still max_loc:null, schema_version=1, 18 keys"
else
  fail "t2-t3-13 rc=$RC card=$(cat "$L" 2>/dev/null)"
fi

# malformed META → 64
reset
expect_rc 64 "t2-malformed-json META not-json → 64" \
  env AUTOPILOT_BUDGET_META='not-json' \
  bash "$APPEND" orchestrate CDT-T2 plan-approve proceed auto null 70 null run-1 1 10 orch "r"
expect_rc 64 "t2-malformed-obj META array → 64" \
  env AUTOPILOT_BUDGET_META='[]' \
  bash "$APPEND" orchestrate CDT-T2 plan-approve proceed auto null 70 null run-1 1 10 orch "r"
expect_rc 64 "t2-malformed-keys META missing nested keys → 64" \
  env AUTOPILOT_BUDGET_META='{"iteration_cap":10,"wall_clock_cap_s":1200}' \
  bash "$APPEND" orchestrate CDT-T2 plan-approve proceed auto null 70 null run-1 1 10 orch "r"

# --- CDT-224 T1 ---
# budget-check.sh argv 2|4|derive (SPEC-033 AC9 / M9b)
# =============================================================================
NOW=$(date +%s)

# T1.2 argc=2: empty env = unset → static M 25/2700
OUT=$(AUTOPILOT_ITERATION_CAP= AUTOPILOT_WALLCLOCK_CAP= bash "$BUDGET" 3 "$NOW" 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.iteration_cap == 25 and .wall_clock_cap_s == 2700' >/dev/null 2>&1; then
  pass "cdt224-t1 argc=2 empty env → static M 25/2700"
else
  fail "cdt224-t1 empty-env rc=$RC out=$OUT (want 25/2700)"
fi

# T1.2 argc=2: junk non-integer env → 64
expect_rc 64 "cdt224-t1 argc=2 junk AUTOPILOT_ITERATION_CAP=abc → 64" \
  env AUTOPILOT_ITERATION_CAP=abc bash "$BUDGET" 3 "$NOW"
expect_rc 64 "cdt224-t1 argc=2 junk AUTOPILOT_WALLCLOCK_CAP=12.5 → 64" \
  env AUTOPILOT_WALLCLOCK_CAP=12.5 bash "$BUDGET" 3 "$NOW"
expect_rc 64 "cdt224-t1 argc=2 junk AUTOPILOT_ITERATION_CAP=-1 → 64" \
  env AUTOPILOT_ITERATION_CAP=-1 bash "$BUDGET" 3 "$NOW"

# T1.5 argc=3 still 64
expect_rc 64 "cdt224-t1 argc=3 → 64" bash "$BUDGET" 3 "$NOW" 10

# T1.3 argc=4: verbatim freeze, 7 keys, env ignored even if set/junk
OUT=$(AUTOPILOT_ITERATION_CAP=2 AUTOPILOT_WALLCLOCK_CAP=100 bash "$BUDGET" 5 "$NOW" 40 4500 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '
  .iteration == 5 and .iteration_cap == 40 and .wall_clock_cap_s == 4500
  and .breached == false and .reason == "none"
  and (keys_unsorted | length) == 7
  and has("wall_clock_s") and has("iteration") and has("iteration_cap")
  and has("wall_clock_cap_s") and has("breached") and has("blocking_condition")
  and has("reason")
' >/dev/null 2>&1; then
  pass "cdt224-t1 argc=4 freeze 40/4500 ignores env ITER=2 WALL=100; 7 keys"
else
  fail "cdt224-t1 argc=4 env-ignore rc=$RC out=$OUT"
fi

OUT=$(AUTOPILOT_ITERATION_CAP=abc AUTOPILOT_WALLCLOCK_CAP=nope bash "$BUDGET" 3 "$NOW" 10 1200 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.iteration_cap == 10 and .wall_clock_cap_s == 1200' >/dev/null 2>&1; then
  pass "cdt224-t1 argc=4 ignores junk env"
else
  fail "cdt224-t1 argc=4 junk-env rc=$RC out=$OUT (want 10/1200, not 64)"
fi

OUT=$(bash "$BUDGET" 10 "$NOW" 10 1200 2>/dev/null); RC=$?
if [ "$RC" -eq 6 ] && echo "$OUT" | jq -e '
  .breached == true and .reason == "iteration" and .blocking_condition == 6
  and .iteration_cap == 10
' >/dev/null 2>&1; then
  pass "cdt224-t1 argc=4 S freeze iteration=10 → BC6"
else
  fail "cdt224-t1 argc=4 S-breach rc=$RC out=$OUT"
fi

OUT=$(bash "$BUDGET" 9 "$NOW" 10 1200 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.breached == false and .iteration_cap == 10' >/dev/null 2>&1; then
  pass "cdt224-t1 argc=4 S freeze iteration=9 → no BC6"
else
  fail "cdt224-t1 argc=4 S-ok rc=$RC out=$OUT"
fi

expect_rc 64 "cdt224-t1 argc=4 non-numeric iter_cap → 64" bash "$BUDGET" 3 "$NOW" abc 1200
expect_rc 64 "cdt224-t1 argc=4 non-numeric wall_s → 64" bash "$BUDGET" 3 "$NOW" 10 abc
expect_rc 64 "cdt224-t1 argc=5 → 64" bash "$BUDGET" 3 "$NOW" 10 1200 extra

# T1.4 derive: L-first then S else M; MUST NOT read env
derive_ok() {
  local t=$1 loc=$2 w=$3 want_tier=$4 want_ic=$5 want_wc=$6
  local out rc=0
  out=$(AUTOPILOT_ITERATION_CAP=99 AUTOPILOT_WALLCLOCK_CAP=99 bash "$BUDGET" derive "$t" "$loc" "$w" 2>/dev/null) || rc=$?
  if [ "$rc" -eq 0 ] && echo "$out" | jq -e \
    --argjson t "$t" --argjson loc "$loc" --argjson w "$w" \
    --arg tier "$want_tier" --argjson ic "$want_ic" --argjson wc "$want_wc" '
      .tier == $tier
      and .iteration_cap == $ic
      and .wall_clock_cap_s == $wc
      and .signals.tasks == $t
      and .signals.projected_loc == $loc
      and .signals.waves == $w
      and (keys_unsorted) == ["tier","iteration_cap","wall_clock_cap_s","signals"]
      and (.signals | keys_unsorted) == ["tasks","projected_loc","waves"]
    ' >/dev/null 2>&1; then
    pass "cdt224-t1 derive $t/$loc/$w → $want_tier $want_ic/$want_wc (env ignored)"
  else
    fail "cdt224-t1 derive $t/$loc/$w rc=$rc out=$out (want $want_tier $want_ic/$want_wc)"
  fi
}
derive_ok 3 300 1 S 10 1200
derive_ok 4 300 1 M 25 2700
derive_ok 3 301 1 M 25 2700
derive_ok 3 300 2 M 25 2700
derive_ok 5 1000 2 M 25 2700
derive_ok 6 100 1 L 40 4500
derive_ok 2 1001 1 L 40 4500
derive_ok 2 200 3 L 40 4500
derive_ok 100 5000 5 L 40 4500

expect_rc 64 "cdt224-t1 derive non-numeric tasks → 64" bash "$BUDGET" derive abc 300 1
expect_rc 64 "cdt224-t1 derive non-numeric loc → 64" bash "$BUDGET" derive 3 abc 1
expect_rc 64 "cdt224-t1 derive non-numeric waves → 64" bash "$BUDGET" derive 3 300 abc
expect_rc 64 "cdt224-t1 derive argc=3 → 64" bash "$BUDGET" derive 3 300
expect_rc 64 "cdt224-t1 derive argc=5 → 64" bash "$BUDGET" derive 3 300 1 extra

# N12: helper MUST NOT write/export AUTOPILOT_*_CAP
if grep -Eq '^[[:space:]]*(export[[:space:]]+)?AUTOPILOT_(ITERATION_CAP|WALLCLOCK_CAP)=' "$BUDGET"; then
  fail "cdt224-t1 budget-check.sh writes/exports AUTOPILOT_*_CAP"
else
  pass "cdt224-t1 budget-check.sh MUST NOT write/export AUTOPILOT_*_CAP"
fi

# --- CDT-224 T5 ---
# Isolation + remaining tests (SPEC-033 AC9 / N13): kickoff/epic argc=2 at
# iteration=10 (would-be S ignored), resume argc=4 from freeze card (env
# mutation ignored), parse-flags still six keys, SKILL/SPEC M13 fence cmp,
# F6 rewritten pins M (tasks=4, loc in (300,1000], waves=1).
: "${ROOT:=$(cd "$SCRIPT_DIR/../.." && pwd)}"
: "${AP_SKILL:=$SCRIPT_DIR/SKILL.md}"
: "${SPEC033:=$ROOT/specs/core/SPEC-033-autopilot-policy.md}"
: "${SCEN:=$SCRIPT_DIR/self-answer-scenarios.md}"
: "${KICKOFF_SKILL:=$ROOT/skills/kickoff/SKILL.md}"
: "${EPIC_SKILL:=$ROOT/skills/epic/SKILL.md}"
ORCH00="$ROOT/skills/orchestrate/steps/00-resolve.md"
NOW=$(date +%s)

# Would-be S signals (kickoff/epic MUST ignore): derive 2/150/1 → S 10/1200
OUT=$(bash "$BUDGET" derive 2 150 1 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '
  .tier == "S" and .iteration_cap == 10 and .wall_clock_cap_s == 1200
  and .signals.tasks == 2 and .signals.projected_loc == 150 and .signals.waves == 1
' >/dev/null 2>&1; then
  pass "cdt224-t5 would-be S derive 2/150/1 → S 10/1200 (counterfactual)"
else
  fail "cdt224-t5 would-be-S rc=$RC out=$OUT"
fi

# Kickoff argc=2 at iteration=10: static M 25, not BC6 (S would halt at 10)
OUT=$(env -u AUTOPILOT_ITERATION_CAP -u AUTOPILOT_WALLCLOCK_CAP \
  bash "$BUDGET" 10 "$NOW" 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '
  .breached == false and .reason == "none" and .iteration == 10
  and .iteration_cap == 25 and .wall_clock_cap_s == 2700
  and (keys_unsorted | length) == 7
' >/dev/null 2>&1; then
  pass "cdt224-t5 kickoff argc=2 iteration=10 → not BC6 (static 25)"
else
  fail "cdt224-t5 kickoff argc=2 rc=$RC out=$OUT"
fi

if grep -q 'N13 isolation' "$KICKOFF_SKILL" \
  && grep -F -q 'envelopes omit `tasks` / `projected_loc` / `waves`' "$KICKOFF_SKILL" \
  && grep -q 'engine argc=2' "$KICKOFF_SKILL" \
  && ! grep -q 'budget-check.sh derive' "$KICKOFF_SKILL" \
  && ! grep -q 'AUTOPILOT_BUDGET_META' "$KICKOFF_SKILL" \
  && ! grep -qE -- '--(iteration-cap|wall-clock-cap|budget-cap)' "$KICKOFF_SKILL"; then
  pass "cdt224-t5 kickoff SKILL N13 argc=2, no derive/META/cap-flag"
else
  fail "cdt224-t5 kickoff SKILL isolation grep miss"
fi

reset
RC=$(rc_of env -u AUTOPILOT_BUDGET_META -u AUTOPILOT_ITERATION_CAP -u AUTOPILOT_WALLCLOCK_CAP \
  bash "$APPEND" kickoff CDT-T5K scope-confirm proceed auto null 90 null run-1 10 60 orch \
  "kickoff argc=2 static 25; iteration 10 in budget")
L=$(ledger CDT-T5K)
if [ "$RC" -eq 0 ] && jq -e '
  .workflow == "kickoff" and .decision == "proceed" and .blocking_condition == null
  and .budget.iteration == 10 and .budget.iteration_cap == 25
  and .budget.tier == null and .budget.source == null and .budget.signals == null
' "$L" >/dev/null 2>&1; then
  pass "cdt224-t5 F6-kickoff card argc13 proceed nested-null iter=10"
else
  fail "cdt224-t5 F6-kickoff rc=$RC card=$(cat "$L" 2>/dev/null)"
fi

# Epic Mode A: same argc=2 isolation
OUT=$(env -u AUTOPILOT_ITERATION_CAP -u AUTOPILOT_WALLCLOCK_CAP \
  bash "$BUDGET" 10 "$NOW" 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '
  .breached == false and .iteration_cap == 25 and .iteration == 10
' >/dev/null 2>&1; then
  pass "cdt224-t5 epic Mode A argc=2 iteration=10 → not BC6 (static 25)"
else
  fail "cdt224-t5 epic argc=2 rc=$RC out=$OUT"
fi

if grep -q 'N13 isolation' "$EPIC_SKILL" \
  && grep -F -q 'Mode A envelopes omit `tasks` / `projected_loc` / `waves`' "$EPIC_SKILL" \
  && grep -q 'engine argc=2' "$EPIC_SKILL" \
  && grep -q 'child `/orchestrate` freezes independently' "$EPIC_SKILL" \
  && ! grep -q 'budget-check.sh derive' "$EPIC_SKILL" \
  && ! grep -q 'AUTOPILOT_BUDGET_META' "$EPIC_SKILL"; then
  pass "cdt224-t5 epic SKILL N13 Mode A argc=2, no derive/META"
else
  fail "cdt224-t5 epic SKILL isolation grep miss"
fi

reset
RC=$(rc_of env -u AUTOPILOT_BUDGET_META -u AUTOPILOT_ITERATION_CAP -u AUTOPILOT_WALLCLOCK_CAP \
  bash "$APPEND" epic CDT-T5E scope-confirm proceed auto null 90 null run-1 10 60 orch \
  "epic Mode A argc=2 static 25; iteration 10 in budget")
L=$(ledger CDT-T5E)
if [ "$RC" -eq 0 ] && jq -e '
  .workflow == "epic" and .decision == "proceed" and .blocking_condition == null
  and .budget.iteration == 10 and .budget.iteration_cap == 25
  and .budget.tier == null and .budget.source == null and .budget.signals == null
' "$L" >/dev/null 2>&1; then
  pass "cdt224-t5 epic Mode A card argc13 proceed nested-null iter=10"
else
  fail "cdt224-t5 epic card rc=$RC card=$(cat "$L" 2>/dev/null)"
fi

# Resume: argc=4 from freeze card; env mutation ignored
reset
META_S='{"iteration_cap":10,"wall_clock_cap_s":1200,"tier":"S","source":"auto","signals":{"tasks":2,"projected_loc":150,"waves":1}}'
RC=$(rc_of env AUTOPILOT_BUDGET_META="$META_S" \
  bash "$APPEND" orchestrate CDT-T5R plan-approve approve auto null 88 null run-1 1 10 orch \
  "budget_tier=S freeze")
L=$(ledger CDT-T5R)
if [ "$RC" -ne 0 ]; then
  fail "cdt224-t5 resume freeze-card write rc=$RC"
else
  IC=$(jq -r '.budget.iteration_cap' "$L")
  WC=$(jq -r '.budget.wall_clock_cap_s' "$L")
  TIER=$(jq -r '.budget.tier' "$L")
  # env 99/99 would NOT breach at iter=10; freeze 10/1200 DOES
  OUT=$(AUTOPILOT_ITERATION_CAP=99 AUTOPILOT_WALLCLOCK_CAP=99 \
    bash "$BUDGET" 10 "$NOW" "$IC" "$WC" 2>/dev/null); RC=$?
  if [ "$RC" -eq 6 ] && [ "$IC" = "10" ] && [ "$WC" = "1200" ] && [ "$TIER" = "S" ] \
    && echo "$OUT" | jq -e '
      .breached == true and .reason == "iteration" and .iteration_cap == 10
      and .wall_clock_cap_s == 1200 and .blocking_condition == 6
    ' >/dev/null 2>&1; then
    pass "cdt224-t5 resume argc=4 from card 10/1200; env 99 ignored → BC6"
  else
    fail "cdt224-t5 resume argc=4 rc=$RC ic=$IC wc=$WC out=$OUT"
  fi
  OUT=$(AUTOPILOT_ITERATION_CAP=99 AUTOPILOT_WALLCLOCK_CAP=99 \
    bash "$BUDGET" 9 "$NOW" "$IC" "$WC" 2>/dev/null); RC=$?
  if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '
    .breached == false and .iteration_cap == 10 and .wall_clock_cap_s == 1200
  ' >/dev/null 2>&1; then
    pass "cdt224-t5 resume argc=4 iter=9 freeze 10 → no BC6 (env 99 unused)"
  else
    fail "cdt224-t5 resume iter=9 rc=$RC out=$OUT"
  fi
fi

# resume-state.sh MUST NOT seed caps from plan frontmatter
PLANDIR="$TMP/.claude/plans"
rm -rf "$PLANDIR"
mkdir -p "$PLANDIR"
cat > "$PLANDIR/2026-08-27-CDT-T5R-plan.md" << 'EOF'
## Tracking
- autopilot_on: true
- autopilot_bump: minor
- iteration_cap: 10
- wall_clock_cap_s: 1200
- budget_tier: S
EOF
OUT=$(bash "$RESUME" CDT-T5R 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '
  .found == true and .autopilot_on == true and .autopilot_bump == "minor"
  and (has("iteration_cap") | not) and (has("wall_clock_cap_s") | not)
  and (has("budget") | not) and (has("tier") | not)
' >/dev/null 2>&1; then
  pass "cdt224-t5 resume-state ignores plan cap keys (no JSON seed)"
else
  fail "cdt224-t5 resume-state cap leak rc=$RC out=$OUT"
fi
rm -rf "$PLANDIR"

if grep -q 'Freeze-on-resume' "$ORCH00" \
  && grep -q 'read-cards.sh' "$ORCH00" \
  && grep -q 'MUST NOT seed caps from plan frontmatter' "$ORCH00" \
  && grep -q 'engine argc=4' "$ORCH00"; then
  pass "cdt224-t5 00-resolve freeze-on-resume cites card not resume-state"
else
  fail "cdt224-t5 00-resolve freeze-on-resume grep miss"
fi

# parse-flags.sh still six keys; unknown cap flags ignored (no 7th key)
OUT=$(bash "$PARSE" --autopilot=patch 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '
  (keys_unsorted | length) == 6
  and has("enabled") and has("bump") and has("source") and has("council_tier")
  and has("tier") and has("max_loc")
  and (has("iteration_cap") | not) and (has("wall_clock_cap_s") | not)
  and (has("budget") | not)
' >/dev/null 2>&1; then
  pass "cdt224-t5 parse-flags JSON still exactly six keys"
else
  fail "cdt224-t5 parse-flags six-key mismatch: $OUT"
fi

OUT=$(bash "$PARSE" --iteration-cap=10 --wall-clock-cap=1200 --budget-cap=S 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '
  (keys_unsorted | length) == 6
  and (has("iteration_cap") | not) and (has("wall_clock_cap_s") | not)
  and .enabled == false and .max_loc == null
' >/dev/null 2>&1; then
  pass "cdt224-t5 parse-flags unknown cap flags ignored; still six keys"
else
  fail "cdt224-t5 parse-flags cap-flag leak rc=$RC out=$OUT"
fi

if ! grep -qE -- '--(iteration-cap|wall-clock-cap|budget-cap)' "$PARSE"; then
  pass "cdt224-t5 parse-flags.sh has no cap-flag surface"
else
  fail "cdt224-t5 parse-flags.sh grew a cap-flag surface"
fi

# SKILL/SPEC M13 fence still cmp (indent-stripped JSON fences byte-identical)
if ! type m13_body >/dev/null 2>&1; then
  m13_body() {
    awk '
      /^[[:space:]]*```json[[:space:]]*$/ {p=1; next}
      p && /^[[:space:]]*```[[:space:]]*$/ {exit}
      p { sub(/^[[:space:]]+/, ""); print }
    ' "$1"
  }
fi
if cmp -s <(m13_body "$SPEC033") <(m13_body "$AP_SKILL"); then
  pass "cdt224-t5 M13 JSON fence indent-stripped still byte-identical"
else
  fail "cdt224-t5 M13 JSON fence mismatch vs SPEC-033"
fi

# F6 rewritten pins M: tasks=4, loc in (300,1000], waves=1
if grep -q 'F6 (rewritten)' "$SCEN" \
  && grep -F -q '`tasks=4`, `projected_loc=500` ∈ (300,1000], `waves=1`' "$SCEN" \
  && grep -F -q 'derive M; argc=4 `25 2700`' "$SCEN" \
  && grep -q 'tasks=4, projected_loc=500, waves=1' "$SCEN" \
  && grep -q 'F6-kickoff' "$SCEN" \
  && grep -F -q 'argc=2 (static 25); no derive' "$SCEN"; then
  pass "cdt224-t5 F6 rewritten pins M tasks=4 loc=500∈(300,1000] waves=1"
else
  fail "cdt224-t5 F6 rewritten pin / F6-kickoff fixture missing"
fi

F6_LOC=$(sed -n '/^### F6 /,/^### F7 /{
  s/.*projected_loc=\([0-9][0-9]*\).*/\1/p
}' "$SCEN" | head -1)
F6_TASKS=$(sed -n '/^### F6 /,/^### F7 /{
  s/.*tasks=\([0-9][0-9]*\).*/\1/p
}' "$SCEN" | head -1)
F6_WAVES=$(sed -n '/^### F6 /,/^### F7 /{
  s/.*waves=\([0-9][0-9]*\).*/\1/p
}' "$SCEN" | head -1)
if [ "${F6_TASKS:-}" = "4" ] \
  && [ -n "${F6_LOC:-}" ] && [ "$F6_LOC" -gt 300 ] && [ "$F6_LOC" -le 1000 ] \
  && [ "${F6_WAVES:-}" = "1" ]; then
  pass "cdt224-t5 F6 extracted pins M (tasks=$F6_TASKS loc=$F6_LOC∈(300,1000] waves=$F6_WAVES)"
else
  fail "cdt224-t5 F6 extract tasks=$F6_TASKS loc=$F6_LOC waves=$F6_WAVES (want 4 / (300,1000] / 1)"
fi

OUT=$(bash "$BUDGET" derive 4 500 1 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '
  .tier == "M" and .iteration_cap == 25 and .wall_clock_cap_s == 2700
  and .signals.tasks == 4 and .signals.projected_loc == 500 and .signals.waves == 1
' >/dev/null 2>&1; then
  pass "cdt224-t5 derive 4/500/1 → M 25/2700 (F6 rewritten live)"
else
  fail "cdt224-t5 F6 derive rc=$RC out=$OUT (want M 25/2700)"
fi

META_M='{"iteration_cap":25,"wall_clock_cap_s":2700,"tier":"M","source":"auto","signals":{"tasks":4,"projected_loc":500,"waves":1}}'
reset
RC=$(rc_of env AUTOPILOT_BUDGET_META="$META_M" \
  bash "$APPEND" orchestrate CDT-200 plan-approve halt auto null 90 6 ap-rs 25 60 orchestrator \
  "budget_tier=M; iteration cap 25 reached")
L=$(ledger CDT-200)
if [ "$RC" -eq 0 ] && jq -e '
  .decision == "halt" and .blocking_condition == 6 and .decided_by == "auto"
  and .budget.tier == "M" and .budget.source == "auto"
  and .budget.iteration_cap == 25 and .budget.wall_clock_cap_s == 2700
  and .budget.signals.tasks == 4 and .budget.signals.projected_loc == 500
  and .budget.signals.waves == 1
' "$L" >/dev/null 2>&1; then
  pass "cdt224-t5 F6 rewritten card argc13 halt bc=6 M freeze 4/500/1"
else
  fail "cdt224-t5 F6 rewritten card rc=$RC card=$(cat "$L" 2>/dev/null)"
fi

# --- CDT-224 T3b ---
# P1#1: freeze card run_id=A, envelope run_id=B (synthetic epoch) still argc=4
# (engine lookup by ticket_id + latest plan-approve nested-non-null, not solely
# envelope run_id). P1#2: unfrozen M10.6 vs 4500; BC6 argc=2 stays 25/2700.
ENGINE="$SCRIPT_DIR/self-answer.md"
: "${SCEN:=$SCRIPT_DIR/self-answer-scenarios.md}"
NOW=$(date +%s)

# Procedure: freeze is latest plan-approve nested-non-null; same ticket AND
# (same run_id OR resume); MUST NOT key solely on envelope run_id.
FREEZE_BLK=$(awk '/A \*\*freeze\*\*/,/^Pick \*\*one\*\* path/' "$ENGINE")
if printf '%s\n' "$FREEZE_BLK" | grep -q 'latest `gate=plan-approve`' \
  && printf '%s\n' "$FREEZE_BLK" | grep -q 'RESUMING=true' \
  && printf '%s\n' "$FREEZE_BLK" | grep -q 'MUST derive, not steal' \
  && printf '%s\n' "$FREEZE_BLK" | grep -q 'MUST NOT key freeze solely' \
  && ! printf '%s\n' "$FREEZE_BLK" | grep -q 'card with this'; then
  pass "cdt224-t3b engine freeze lookup ticket_id+latest plan-approve, not solely run_id"
else
  fail "cdt224-t3b freeze-lookup procedure grep miss"
fi

# Live: freeze card run_id=A; envelope run_id=B would miss if keyed on run_id;
# ticket_id + latest nested-non-null still yields argc=4; env ignored.
reset
META_S='{"iteration_cap":10,"wall_clock_cap_s":1200,"tier":"S","source":"auto","signals":{"tasks":2,"projected_loc":150,"waves":1}}'
RC=$(rc_of env AUTOPILOT_BUDGET_META="$META_S" \
  bash "$APPEND" orchestrate CDT-T3b plan-approve approve auto null 88 null run-A 1 10 orch \
  "budget_tier=S freeze")
if [ "$RC" -ne 0 ]; then
  fail "cdt224-t3b freeze-card write rc=$RC"
else
  CARDS=$(bash "$READ" CDT-T3b 2>/dev/null)
  MATCH_B=$(printf '%s' "$CARDS" | jq '[.[] | select(.run_id == "run-B" and .gate == "plan-approve" and .budget.tier != null)] | length')
  FREEZE=$(printf '%s' "$CARDS" | jq -c '
    [.[] | select(.gate == "plan-approve"
      and .budget.tier != null and .budget.source != null and .budget.signals != null)] | last
  ')
  FRID=$(printf '%s' "$FREEZE" | jq -r '.run_id')
  IC=$(printf '%s' "$FREEZE" | jq -r '.budget.iteration_cap')
  WC=$(printf '%s' "$FREEZE" | jq -r '.budget.wall_clock_cap_s')
  TIER=$(printf '%s' "$FREEZE" | jq -r '.budget.tier')
  if [ "$MATCH_B" = "0" ] && [ "$FRID" = "run-A" ] && [ "$IC" = "10" ] && [ "$WC" = "1200" ] && [ "$TIER" = "S" ]; then
    OUT=$(AUTOPILOT_ITERATION_CAP=99 AUTOPILOT_WALLCLOCK_CAP=99 \
      bash "$BUDGET" 10 "$NOW" "$IC" "$WC" 2>/dev/null); RC=$?
    if [ "$RC" -eq 6 ] && echo "$OUT" | jq -e '
      .breached == true and .reason == "iteration" and .iteration_cap == 10
      and .wall_clock_cap_s == 1200 and .blocking_condition == 6
    ' >/dev/null 2>&1; then
      pass "cdt224-t3b freeze run_id=A envelope run_id=B still argc=4 10/1200; env 99 ignored → BC6"
    else
      fail "cdt224-t3b resume-mismatch argc=4 rc=$RC ic=$IC wc=$WC out=$OUT"
    fi
  else
    fail "cdt224-t3b lookup match_b=$MATCH_B frid=$FRID ic=$IC wc=$WC tier=$TIER"
  fi
fi

# P1#2: §3d splits M10.6 4500 from unfrozen BC6 argc=2 2700
if grep -q 'M10.6 vs \*\*4500 s\*\*' "$ENGINE" \
  && grep -q 'Unfrozen BC6 stays argc=2' "$ENGINE" \
  && grep -q 'separate compare' "$ENGINE" \
  && ! grep -q 'effective wall-clock cap from step (b)' "$ENGINE"; then
  pass "cdt224-t3b §3d unfrozen M10.6 vs 4500; BC6 argc=2 unchanged"
else
  fail "cdt224-t3b M10.6 split grep miss"
fi

# F6-m10.6-scope fixture still unfrozen 4500; BC6 argc=2 25/2700
if grep -q 'F6-m10.6-scope' "$SCEN" \
  && grep -F -q 'unfrozen compare is 4500 s' "$SCEN" \
  && grep -F -q 'M10.6** uses 4500, not the argc=2 2700' "$SCEN"; then
  pass "cdt224-t3b F6-m10.6-scope unfrozen M10.6 vs 4500 (not 2700)"
else
  fail "cdt224-t3b F6-m10.6-scope wording miss"
fi

# Live: unfrozen BC6 argc=2 still 25/2700 (do not retune pre-freeze BC6)
OUT=$(env -u AUTOPILOT_ITERATION_CAP -u AUTOPILOT_WALLCLOCK_CAP \
  bash "$BUDGET" 2 "$NOW" 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '
  .breached == false and .iteration == 2
  and .iteration_cap == 25 and .wall_clock_cap_s == 2700
' >/dev/null 2>&1; then
  pass "cdt224-t3b unfrozen argc=2 still BC6 25/2700 (M10.6 4500 is separate)"
else
  fail "cdt224-t3b unfrozen argc=2 rc=$RC out=$OUT (want 25/2700)"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -ne 0 ] && exit 1
exit 0
