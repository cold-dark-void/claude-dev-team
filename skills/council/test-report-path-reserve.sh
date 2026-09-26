#!/usr/bin/env bash
# skills/council/test-report-path-reserve.sh
#
# WP 1-14 T2 — Report-path no-overwrite (AC K-O; SPEC-013 Phase 6 "Report
# no-overwrite"; Test 23). Covers cmd_report_path (probe, used by preflight
# and the `report-path` subcommand) and finalize's write-time reservation
# (two sequential O_EXCL creates + rollback — "atomic as a pair" was struck
# by plan review as unimplementable in bash).
#
# Hermetic: every engine.sh call below runs with cwd inside a private,
# per-case temp git repo (its own MROOT/.claude/council), never the live
# worktree. A checksum guard at the end asserts the shared index is
# untouched.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="$ROOT/skills/council/engine.sh"
fail=0
pass=0

# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
hermetic_init

# ---- Guard: this suite must never rewrite the shared MROOT index ------------
_gc=$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null) \
  && _MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || _MROOT="$ROOT"
SHARED_IDX="$_MROOT/.claude/council/index.json"
if [ -f "$SHARED_IDX" ]; then
  SHARED_SUM_BEFORE=$(sha256sum "$SHARED_IDX" | awk '{print $1}')
else
  SHARED_SUM_BEFORE="absent"
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/report-path-reserve-test.XXXXXX")"
trap 'rm -rf "$TMP"; hermetic_cleanup' EXIT

ok() {  # ok <label> <condition-cmd...>
  if "${@:2}" >/dev/null 2>&1; then
    echo "OK: $1"; pass=$((pass + 1))
  else
    echo "FAIL: $1"; fail=$((fail + 1))
  fi
}
ok_eq() {  # ok_eq <label> <got> <want>
  if [ "$2" = "$3" ]; then
    echo "OK: $1"; pass=$((pass + 1))
  else
    echo "FAIL: $1 (got: $2 | want: $3)"; fail=$((fail + 1))
  fi
}

new_repo() {  # new_repo <name> -> prints absolute path, git-inits it
  local r="$TMP/$1"
  mkdir -p "$r"
  git init -q "$r"
  printf '%s' "$r"
}

# Returns engine.sh's OWN idea of "today" (UTC) by parsing the basename of a
# real `report-path claim` probe against a throwaway, empty temp repo — never
# an independent `date` read. A single global `date -u` captured once at
# suite start (the pre-review shape of this file) can go stale across a UTC
# midnight rollover that happens somewhere in the ~30 engine.sh invocations
# below, which desyncs the test's expected paths from what engine.sh itself
# computes and breaks SPEC-013 Test 23 #1 / AC O. Calling this immediately
# before each case's real engine.sh work (and, for the pre-seeding cases,
# before anything is touched on disk) keeps the two reads adjacent instead of
# minutes apart (tech-lead review r1, B3).
today_now() {
  local d="$TMP/date-probe-$$-$RANDOM" p base
  mkdir -p "$d"
  git init -q "$d"
  p="$(cd "$d" && bash "$ENGINE" report-path claim)" || return 1
  base="$(basename "$p")"
  printf '%s\n' "${base%-claim.md}"
}

# Minimal, self-contained evidence + judge fixtures (one verified claim).
EVIDENCE="$TMP/evidence.json"
cat >"$EVIDENCE" <<'EOF'
[{"tool_use_id":"t1","raw_blob":"b","file_line":"f:1","reproducible_command":"true"}]
EOF
JUDGE="$TMP/judge.json"
cat >"$JUDGE" <<'EOF'
{"verdicts":[{"claim_id":"c1","claim":"x","verdict":"VERIFIED","confidence":90,"evidence_blob":"b"}],"struck_lines":[]}
EOF

# ==============================================================================
# 1. No collision: the path stays byte-identical to the pre-WP-1-14 formula
#    (AC L; Test 23 #5)
# ==============================================================================
R1=$(new_repo repo1)
(
  cd "$R1" || exit 1
  bash "$ENGINE" preflight --scope claim --scope-arg "x" > plan.json
  bash "$ENGINE" finalize --plan-file plan.json --evidence-file "$EVIDENCE" \
    --judge-output "$JUDGE" > finalize.out 2> finalize.err
)
RP1=$(jq -r '.report_path' "$R1/plan.json")
# Date read from THIS run's own report_path (WP 1-14 review r2, N-a) --
# repo1 is fresh, so preflight's probe was guaranteed collision-free and
# plan.json's report_path IS the base formula; no separate probe, no race.
T1="$(basename "$RP1")"; T1="${T1%-claim.md}"
EXPECT1="$R1/.claude/council/${T1}-claim.md"
ok_eq "1 no-collision plan.report_path is the base formula" "$RP1" "$EXPECT1"
ok "1 no-collision report exists at the base path" test -f "$EXPECT1"
ok "1 no-collision sidecar exists" test -f "${EXPECT1}.finalize-meta.json"
ok "1 Council report: line names the base path" \
  grep -qF "Council report: .claude/council/${T1}-claim.md" "$R1/finalize.out"
ok "1 no stray plan-rewrite notice on the no-collision path" \
  bash -c "! grep -q 'rewrote plan.report_path' '$R1/finalize.err'"

# ==============================================================================
# 2. Two same-day unbound finalizes, same slug -> base + -2. First report's
#    and sidecar's bytes stay unchanged (Test 23 #2; AC O)
# ==============================================================================
R2=$(new_repo repo2)
(
  cd "$R2" || exit 1
  bash "$ENGINE" preflight --scope claim --scope-arg "y" > plan-a.json
  bash "$ENGINE" finalize --plan-file plan-a.json --evidence-file "$EVIDENCE" \
    --judge-output "$JUDGE" > /dev/null 2>&1
)
RPA2=$(jq -r '.report_path' "$R2/plan-a.json")
# Date read from run a's own report_path (WP 1-14 review r2, N-a) -- repo2
# is fresh at this point, so run a's report_path IS the base formula; no
# separate probe, no race.
T2="$(basename "$RPA2")"; T2="${T2%-claim.md}"
BASE2="$R2/.claude/council/${T2}-claim.md"
SUM_REPORT_BEFORE=$(sha256sum "$BASE2" | awk '{print $1}')
SUM_META_BEFORE=$(sha256sum "${BASE2}.finalize-meta.json" | awk '{print $1}')
(
  cd "$R2" || exit 1
  bash "$ENGINE" preflight --scope claim --scope-arg "y" > plan-b.json
  bash "$ENGINE" finalize --plan-file plan-b.json --evidence-file "$EVIDENCE" \
    --judge-output "$JUDGE" > finalize-b.out 2> finalize-b.err
)
NEXT2="$R2/.claude/council/${T2}-claim-2.md"
ok "2 first report still present" test -f "$BASE2"
ok "2 second run reserved -2 for the report" test -f "$NEXT2"
ok "2 second run reserved -2 for the sidecar" test -f "${NEXT2}.finalize-meta.json"
SUM_REPORT_AFTER=$(sha256sum "$BASE2" | awk '{print $1}')
SUM_META_AFTER=$(sha256sum "${BASE2}.finalize-meta.json" | awk '{print $1}')
ok_eq "2 first report bytes unchanged" "$SUM_REPORT_AFTER" "$SUM_REPORT_BEFORE"
ok_eq "2 first sidecar bytes unchanged" "$SUM_META_AFTER" "$SUM_META_BEFORE"
RP2B=$(jq -r '.report_path' "$R2/plan-b.json")
ok_eq "2 plan-b.report_path already the reserved -2 path (preflight probed after run 1)" "$RP2B" "$NEXT2"
# No race in this sequence (preflight for plan-b ran after run 1 finished, so
# its own probe already returned -2) -> finalize reserves what the plan
# already says and must NOT print a rewrite notice.
ok "2 no stray rewrite notice when preflight's probe already matches" \
  bash -c "! grep -q 'rewrote plan.report_path' '$R2/finalize-b.err'"

# ==============================================================================
# 2b. A genuine race: plan.report_path was computed BEFORE another run took
#     the base path. Finalize's write-time reservation must recover to -2,
#     rewrite plan.report_path (tmp+rename) and print exactly one notice
#     (SPEC-013 Phase 6 "One path everywhere")
# ==============================================================================
R2B=$(new_repo repo2b)
(
  cd "$R2B" || exit 1
  bash "$ENGINE" preflight --scope claim --scope-arg "race" > plan.json
)
RP2B_ORIG=$(jq -r '.report_path' "$R2B/plan.json")
# Date read from this preflight's own report_path (WP 1-14 review r2, N-a)
# -- repo2b is fresh at this point (nothing pre-seeded yet), so it IS the
# base formula; no separate probe, no race.
T2B="$(basename "$RP2B_ORIG")"; T2B="${T2B%-claim.md}"
BASE2B="$R2B/.claude/council/${T2B}-claim.md"
ok_eq "2b preflight's plan.report_path is the base path" "$RP2B_ORIG" "$BASE2B"
# Simulate a concurrent run winning the base path between preflight and
# finalize for THIS run.
mkdir -p "$(dirname "$BASE2B")"
: > "$BASE2B"
: > "${BASE2B}.finalize-meta.json"
(
  cd "$R2B" || exit 1
  bash "$ENGINE" finalize --plan-file plan.json --evidence-file "$EVIDENCE" \
    --judge-output "$JUDGE" > finalize.out 2> finalize.err
)
NEXT2B="$R2B/.claude/council/${T2B}-claim-2.md"
ok "2b finalize recovered to -2 despite the race" test -f "$NEXT2B"
RP2B_AFTER=$(jq -r '.report_path' "$R2B/plan.json")
ok_eq "2b plan.report_path rewritten to the reserved -2 path" "$RP2B_AFTER" "$NEXT2B"
NOTICE2B_COUNT=$(grep -c 'rewrote plan.report_path' "$R2B/finalize.err" || true)
ok_eq "2b exactly one stderr rewrite notice" "$NOTICE2B_COUNT" "1"

# ==============================================================================
# 3. Sidecar-only collision at the base path -> probe AND reserve both skip
#    to -2 (Test 23 #3; task list item 1: "report free but sidecar exists")
# ==============================================================================
R3=$(new_repo repo3)
T3=$(today_now)
mkdir -p "$R3/.claude/council"
BASE3="$R3/.claude/council/${T3}-claim.md"
: > "${BASE3}.finalize-meta.json"   # sidecar only; report absent
(
  cd "$R3" || exit 1
  bash "$ENGINE" report-path claim > probe.out
  bash "$ENGINE" preflight --scope claim --scope-arg "z" > plan.json
  bash "$ENGINE" finalize --plan-file plan.json --evidence-file "$EVIDENCE" \
    --judge-output "$JUDGE" > /dev/null 2>&1
)
NEXT3="$R3/.claude/council/${T3}-claim-2.md"
ok_eq "3 probe skips the sidecar-only base path" "$(cat "$R3/probe.out")" "$NEXT3"
ok "3 base report was never created" bash -c "[ ! -e '$BASE3' ]"
ok "3 pre-existing sidecar-only placeholder untouched" test -f "${BASE3}.finalize-meta.json"
ok "3 finalize reserved -2 for the report" test -f "$NEXT3"
ok "3 finalize reserved -2 for the sidecar" test -f "${NEXT3}.finalize-meta.json"

# ==============================================================================
# 4. Second create fails -> the first (report) placeholder is removed
#    (rollback). Same setup as case 3, checked from the reservation's own
#    point of view: the base report must never survive a failed reservation.
# ==============================================================================
R4=$(new_repo repo4)
T4=$(today_now)
mkdir -p "$R4/.claude/council"
BASE4="$R4/.claude/council/${T4}-claim.md"
: > "${BASE4}.finalize-meta.json"   # forces: report create wins, sidecar create loses
(
  cd "$R4" || exit 1
  bash "$ENGINE" preflight --scope claim --scope-arg "w" > plan.json
  bash "$ENGINE" finalize --plan-file plan.json --evidence-file "$EVIDENCE" \
    --judge-output "$JUDGE" > /dev/null 2>&1
)
ok "4 rollback: no orphaned report placeholder at the base path" \
  bash -c "[ ! -e '$BASE4' ]"
ok "4 rollback: base sidecar is still the original empty placeholder" \
  bash -c "[ ! -s '${BASE4}.finalize-meta.json' ]"
NEXT4="$R4/.claude/council/${T4}-claim-2.md"
ok "4 the run that rolled back still finished at -2" test -f "$NEXT4"

# ==============================================================================
# 5. Collision exhausts every candidate up to -99 -> exit 9, no report
#    written, nothing rewritten (task list item 3; SPEC-013 Phase 6
#    "Exhausted")
# ==============================================================================
R5=$(new_repo repo5)
T5=$(today_now)
mkdir -p "$R5/.claude/council"
BASE5="$R5/.claude/council/${T5}-claim"
touch "${BASE5}.md" "${BASE5}.md.finalize-meta.json"
for n in $(seq 2 99); do
  touch "${BASE5}-${n}.md" "${BASE5}-${n}.md.finalize-meta.json"
done

RC5A=0
( cd "$R5" && bash "$ENGINE" report-path claim > probe.out 2> probe.err )
RC5A=$?
ok_eq "5a probe (report-path subcommand) exhausted -> exit 9" "$RC5A" 9
ok "5a probe stderr names the cause" grep -qi "report no-overwrite" "$R5/probe.err"

RC5B=0
( cd "$R5" && bash "$ENGINE" preflight --scope claim --scope-arg "exhausted" \
    > plan-exh.json 2> preflight.err )
RC5B=$?
ok_eq "5b preflight exhausted -> exit 9 (fails closed, never emits a taken path)" "$RC5B" 9
ok "5b preflight prints no path or plan on exhaustion (SPEC-013:420)" \
  bash -c "[ ! -s '$R5/plan-exh.json' ]"

PLAN5="$R5/plan-finalize.json"
jq -n --arg rp "${BASE5}.md" '{
  output_shape: "verdict[]", scope: "claim", preset: "generic",
  slug: "claim", task_id: "", report_path: $rp,
  flavors: ["paranoid-ic"], claim_budget: 10, completion_time: "0s"
}' > "$PLAN5"
RC5C=0
( cd "$R5" && bash "$ENGINE" finalize --plan-file plan-finalize.json \
    --evidence-file "$EVIDENCE" --judge-output "$JUDGE" \
    > finalize.out 2> finalize.err )
RC5C=$?
ok_eq "5c finalize exhausted -> exit 9" "$RC5C" 9
ok "5c finalize stderr names the cause" grep -qi "report no-overwrite" "$R5/finalize.err"
ok "5c finalize exhausted -> no 100th report written" \
  bash -c "[ ! -e '${BASE5}-100.md' ]"
RP5=$(jq -r '.report_path' "$PLAN5")
ok_eq "5c plan.report_path unchanged on exhaustion (never rewritten)" "$RP5" "${BASE5}.md"

# ==============================================================================
# 6. --report-out keeps its exact-path, overwriting, non-reserving behavior
#    (AC N; task list item 4; Test 23 #5)
# ==============================================================================
R6=$(new_repo repo6)
(
  cd "$R6" || exit 1
  bash "$ENGINE" preflight --scope claim --scope-arg "ro" > plan.json
)
RP6_ORIG=$(jq -r '.report_path' "$R6/plan.json")
OUT6="$R6/explicit-report.md"
RC6A=0
(
  cd "$R6" || exit 1
  bash "$ENGINE" finalize --plan-file plan.json --evidence-file "$EVIDENCE" \
    --judge-output "$JUDGE" --report-out "$OUT6" > /dev/null 2>&1
)
RC6A=$?
RC6B=0
(
  cd "$R6" || exit 1
  bash "$ENGINE" finalize --plan-file plan.json --evidence-file "$EVIDENCE" \
    --judge-output "$JUDGE" --report-out "$OUT6" > /dev/null 2>&1
)
RC6B=$?
ok_eq "6 --report-out first call exit 0" "$RC6A" 0
ok_eq "6 --report-out second call exit 0 (overwrites, does not collide)" "$RC6B" 0
ok "6 --report-out wrote exactly PATH" test -f "$OUT6"
ok "6 --report-out never adds -N" bash -c "[ ! -e '${OUT6%.md}-2.md' ]"
RP6_AFTER=$(jq -r '.report_path' "$R6/plan.json")
ok_eq "6 plan.report_path is untouched for --report-out" "$RP6_AFTER" "$RP6_ORIG"

# ==============================================================================
# 7. Task-bound collision: plan.report_path, the `Council report:` line, the
#    file on disk and the index row's report_path all agree on the reserved
#    -2 path (Test 23 #4; AC L)
# ==============================================================================
R7=$(new_repo repo7)
(
  cd "$R7" || exit 1
  bash "$ENGINE" preflight --scope claim --scope-arg "tb" --task-id T-RESERVE > plan-a.json
  bash "$ENGINE" finalize --plan-file plan-a.json --evidence-file "$EVIDENCE" \
    --judge-output "$JUDGE" --task-id T-RESERVE > /dev/null 2>&1
  bash "$ENGINE" preflight --scope claim --scope-arg "tb" --task-id T-RESERVE > plan-b.json
  bash "$ENGINE" finalize --plan-file plan-b.json --evidence-file "$EVIDENCE" \
    --judge-output "$JUDGE" --task-id T-RESERVE > finalize-b.out 2> finalize-b.err
)
RPA7=$(jq -r '.report_path' "$R7/plan-a.json")
# Date read from run a's own report_path (WP 1-14 review r2, N-a) -- repo7
# is fresh at this point, so run a's report_path IS the base (task-bound,
# no -N) formula; no separate probe, no race.
T7="$(basename "$RPA7")"; T7="${T7%-claim--T-RESERVE.md}"
EXPECT7="$R7/.claude/council/${T7}-claim--T-RESERVE-2.md"
RP7=$(jq -r '.report_path' "$R7/plan-b.json")
ok_eq "7 plan-b.report_path is the reserved -2 path" "$RP7" "$EXPECT7"
ok "7 report exists at the reserved path" test -f "$EXPECT7"
CR7=$(sed -n 's/^Council report: //p' "$R7/finalize-b.out")
ok_eq "7 Council report: line names the reserved path" "$CR7" ".claude/council/${T7}-claim--T-RESERVE-2.md"
IDX7=$(jq -r '.["T-RESERVE"][0].report_path' "$R7/.claude/council/index.json")
ok_eq "7 index row report_path agrees with the reserved path" "$IDX7" "$EXPECT7"

# ==============================================================================
# Guard: the shared MROOT index must be byte-identical to how this suite
# found it — every case above ran inside its own per-case temp repo.
# ==============================================================================
if [ -f "$SHARED_IDX" ]; then
  SHARED_SUM_AFTER=$(sha256sum "$SHARED_IDX" | awk '{print $1}')
else
  SHARED_SUM_AFTER="absent"
fi
ok_eq "guard: shared MROOT index untouched" "$SHARED_SUM_AFTER" "$SHARED_SUM_BEFORE"

echo
echo "PASS=$pass FAIL=$fail"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
