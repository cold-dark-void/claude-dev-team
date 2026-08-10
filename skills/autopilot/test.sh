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
# unset, and 4-key JSON shape (CDT-126 adds council_tier).
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
# (a) happy-path append → rc 0, 1 line, jq . parses, 17 keys, type/schema/ts
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
  (keys_unsorted | length) == 17
  and has("schema_version") and has("type") and has("ts") and has("run_id")
  and has("workflow") and has("ticket_id") and has("gate") and has("decision")
  and has("decided_by") and has("bump") and has("confidence")
  and has("blocking_condition") and has("council_tier") and has("grading_reason")
  and has("rationale") and has("budget") and has("actor")
  and .council_tier == null and .grading_reason == null
  and .schema_version == 1 and .type == "autopilot_decision"
  and (.ts | test("^[0-9T:-]+Z$"))
  and (.budget | (has("iteration") and has("iteration_cap")
       and has("wall_clock_s") and has("wall_clock_cap_s")))
  and .budget.iteration_cap == 25 and .budget.wall_clock_cap_s == 2700
' "$L" >/dev/null 2>&1 && echo y || echo n)
if [ "$KEYS_OK" = "y" ]; then
  pass "a2 all 17 keys + type/schema_version/ts-shape + default budget caps"
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
# (ad) parse-flags.sh: JSON shape has all 4 keys (CDT-126 adds council_tier)
# =============================================================================
OUT=$(bash "$PARSE" --autopilot=patch 2>/dev/null)
if echo "$OUT" | jq -e '
  (keys_unsorted | length) == 4
  and has("enabled") and has("bump") and has("source") and has("council_tier")
' >/dev/null 2>&1; then
  pass "ad parse-flags JSON shape has all 4 keys"
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
  and (keys_unsorted | index("council_tier")) == (keys_unsorted | index("blocking_condition")) + 1
  and (keys_unsorted | index("rationale")) == (keys_unsorted | index("grading_reason")) + 1
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
# Summary
# =============================================================================
echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -ne 0 ] && exit 1
exit 0
