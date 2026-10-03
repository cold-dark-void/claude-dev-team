#!/usr/bin/env bash
# task-store-test.sh — CDT-167 + CDT-163 + CDT-186 regression for task-store invent +
# TaskCompleted shadow-safe meta, index isolate scores, multi-true lex-min preferred
# (CDT-167 AC1/AC2/AC4/AC5/AC6; CDT-163 AC3/AC4/AC5/AC7/AC8; CDT-186 multi-true P; SPEC-002).
#
# Machine-check: bash skills/orchestrate/task-store-test.sh  (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
# (A) task-store invent — temp git repo as MROOT via git-common-dir
# (B) hook shadow-safe — extract task-completed body from
#     skills/init-orchestration/SKILL.md (same marker as check-hook-templates)
#     CDT-163 B6/B7/B9/B10: isolate preferred + unique-suffix; no multi-key max-merge
#     CDT-186 B11/B12: multi-true compounds → lex-min preferred basename
# (C) task identity fields -- --plan-ordinal / --taskcreate-id on `create`,
#     null defaults, upsert-preserves-when-omitted, bad-flag exit 2 no write (SPEC-017 AC A)
# (D) dag-lib.sh ready-set integration -- a Step-7-shaped store (compound keys,
#     translated depends_on) keeps a dependent out of the unscoped ready set
#     until every dep is completed (SPEC-017 AC B)
# (E) `create` stderr -- exactly one line, created|upserted (SPEC-017 AC C)
set -u

PASS=0
FAIL=0
die() { echo "FATAL: $*" >&2; exit 1; }

assert_file_absent() {
  assert_not_file "$@"
}
assert_file_present() {
  assert_file "$@"
}

command -v jq >/dev/null 2>&1 || die "jq required"
command -v python3 >/dev/null 2>&1 || die "python3 required"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

# shellcheck source=../../tests/lib/assert.sh
. "$ROOT/tests/lib/assert.sh"

# C7 hygiene: shared hermetic-suite helper (SPEC-030 R20) isolates HOME/TMPDIR
# and git author identity; add git-config isolation on top so fixture repos
# never read host/global git config.
source "$ROOT/tests/lib/hermetic.sh"
hermetic_init
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1

unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE 2>/dev/null || true
STORE="$SCRIPT_DIR/task-store.sh"
SKILL="$ROOT/skills/init-orchestration/SKILL.md"
[ -f "$STORE" ] || die "task-store.sh not found at $STORE"
[ -f "$SKILL" ] || die "SKILL.md not found at $SKILL"
[ -x "$STORE" ] || chmod +x "$STORE"
DAG_LIB="$SCRIPT_DIR/dag-lib.sh"
[ -f "$DAG_LIB" ] || die "dag-lib.sh not found at $DAG_LIB"

BASE=$(mktemp -d "${TMPDIR:-/tmp}/task-store-test.XXXXXX") || die "mktemp failed"
BASE=$(realpath "$BASE")
cleanup() { rm -rf "$BASE"; hermetic_cleanup; }
trap cleanup EXIT

# ---- Shared: fresh temp git repo as MROOT -----------------------------------
# task-store and the hook both resolve MROOT via git-common-dir.
new_repo() {
  local name="$1"
  local repo="$BASE/$name"
  mkdir -p "$repo"
  git init -q "$repo" || die "git init $name"
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test"
  git -C "$repo" commit --allow-empty -q -m init || die "empty commit $name"
  mkdir -p "$repo/.claude/tasks" "$repo/.claude/council"
  printf '%s\n' "$repo"
}

write_meta() {
  # write_meta REPO FILENAME TASK_ID RC [STATUS]
  local repo="$1" fname="$2" tid="$3" rc="$4" status="${5:-pending}"
  jq -n \
    --arg tid "$tid" \
    --argjson rc "$rc" \
    --arg s "$status" \
    '{task_id:$tid, subject:"test", requires_council:$rc, depends_on:[], created_at:"2026-08-07T00:00:00Z", status:$s}' \
    > "$repo/.claude/tasks/$fname"
}

# =============================================================================
echo "== (A) task-store invent =="

# --- A1: unique compound *-7.json rc:true → update compound; no bare 7.json ---
REPO=$(new_repo a1)
write_meta "$REPO" "CDT-111-C1-7.json" "CDT-111-C1-7" true pending
set +e
( cd "$REPO" && bash "$STORE" update-status 7 completed ) >/dev/null 2>"$BASE/a1.err"
RC=$?
set -e
assert_eq "A1 update-status unique compound rc" "$RC" "0"
assert_file_absent "A1 no bare 7.json invented" "$REPO/.claude/tasks/7.json"
assert_file_present "A1 compound still present" "$REPO/.claude/tasks/CDT-111-C1-7.json"
got_status=$(jq -r '.status' "$REPO/.claude/tasks/CDT-111-C1-7.json")
got_rc=$(jq -r '.requires_council' "$REPO/.claude/tasks/CDT-111-C1-7.json")
assert_eq "A1 compound status completed" "$got_status" "completed"
assert_eq "A1 compound rc still true" "$got_rc" "true"

# --- A2: two *-7.json → exit !=0; no 7.json ---
REPO=$(new_repo a2)
write_meta "$REPO" "CDT-111-C1-7.json" "CDT-111-C1-7" true
write_meta "$REPO" "CDT-999-C2-7.json" "CDT-999-C2-7" false
set +e
( cd "$REPO" && bash "$STORE" update-status 7 completed ) >/dev/null 2>"$BASE/a2.err"
RC=$?
set -e
assert_ne "A2 multi-match exit non-zero" "$RC" "0"
assert_file_absent "A2 no bare 7.json on multi" "$REPO/.claude/tasks/7.json"
# compounds untouched
got_status=$(jq -r '.status' "$REPO/.claude/tasks/CDT-111-C1-7.json")
assert_eq "A2 first compound still pending" "$got_status" "pending"

# --- A3: zero match → bare stub invent rc:false ---
REPO=$(new_repo a3)
set +e
( cd "$REPO" && bash "$STORE" update-status orphan99 in_progress ) >/dev/null 2>"$BASE/a3.err"
RC=$?
set -e
assert_eq "A3 zero-match invent rc" "$RC" "0"
assert_file_present "A3 bare stub created" "$REPO/.claude/tasks/orphan99.json"
got_rc=$(jq -r '.requires_council' "$REPO/.claude/tasks/orphan99.json")
got_status=$(jq -r '.status' "$REPO/.claude/tasks/orphan99.json")
got_subj=$(jq -r '.subject' "$REPO/.claude/tasks/orphan99.json")
assert_eq "A3 stub rc false" "$got_rc" "false"
assert_eq "A3 stub status in_progress" "$got_status" "in_progress"
assert_eq "A3 stub subject auto" "$got_subj" "(auto-created stub)"

# --- A4: dest exists → status only (preserve rc) ---
REPO=$(new_repo a4)
write_meta "$REPO" "7.json" "7" true pending
set +e
( cd "$REPO" && bash "$STORE" update-status 7 blocked ) >/dev/null 2>"$BASE/a4.err"
RC=$?
set -e
assert_eq "A4 dest-exists update rc" "$RC" "0"
got_status=$(jq -r '.status' "$REPO/.claude/tasks/7.json")
got_rc=$(jq -r '.requires_council' "$REPO/.claude/tasks/7.json")
got_subj=$(jq -r '.subject' "$REPO/.claude/tasks/7.json")
assert_eq "A4 status only → blocked" "$got_status" "blocked"
assert_eq "A4 rc preserved true" "$got_rc" "true"
assert_eq "A4 subject preserved" "$got_subj" "test"

# =============================================================================
echo "== (B) hook shadow-safe (extracted template) =="

HOOK="$BASE/task-completed.sh"
# Same extraction contract as check-hook-templates.sh / escalation-gate-test.sh
SKILL="$SKILL" python3 -c '
import os, re, sys
skill = open(os.environ["SKILL"], encoding="utf-8").read()
marker = "create `.claude/hooks/task-completed.sh` with this content:"
idx = skill.find(marker)
if idx == -1:
    sys.stderr.write("no marker for task-completed\n")
    sys.exit(3)
rest = skill[idx:]
m = re.search(r"\n```bash\n(.*?)\n```", rest, re.DOTALL)
if not m:
    sys.stderr.write("no fenced bash block after marker\n")
    sys.exit(3)
sys.stdout.write(m.group(1) + "\n")
' > "$HOOK" || die "could not extract task-completed template from SKILL.md"
[ -s "$HOOK" ] || die "extracted hook empty"
chmod +x "$HOOK"
bash -n "$HOOK" || die "extracted hook fails bash -n"

HOOK_ERR="$BASE/hook.err"
run_hook() {
  # run_hook REPO TASK_ID — sets RC; stderr in HOOK_ERR
  local repo="$1" tid="$2"
  local payload
  payload=$(jq -nc --arg t "$tid" '{task_id:$t, hook_event_name:"TaskCompleted"}')
  # File redirect (not pipe) — matches Step 8 hygiene; timeout 1 cat still ok
  printf '%s' "$payload" > "$BASE/hook.stdin"
  set +e
  ( cd "$repo" && bash "$HOOK" < "$BASE/hook.stdin" ) >/dev/null 2>"$HOOK_ERR"
  RC=$?
  set -e
}

# --- B1 AC1: compound true + bare stub false + bare id 7 + empty/missing index → exit 2 ---
REPO=$(new_repo b1)
write_meta "$REPO" "CDT-111-C1-7.json" "CDT-111-C1-7" true
write_meta "$REPO" "7.json" "7" false
# no index.json → gate fires when effective_rc true
run_hook "$REPO" "7"
assert_eq "B1 AC1 compound true + bare false → exit 2" "$RC" "2"

# --- B2 AC5: pure-missing → exit 0 ---
REPO=$(new_repo b2)
# empty tasks dir
run_hook "$REPO" "7"
assert_eq "B2 AC5 pure-missing → exit 0" "$RC" "0"

# --- B3 AC6: multi compound any true + bare false → exit 2 ---
REPO=$(new_repo b3)
write_meta "$REPO" "CDT-111-C1-7.json" "CDT-111-C1-7" true
write_meta "$REPO" "CDT-999-C2-7.json" "CDT-999-C2-7" false
write_meta "$REPO" "7.json" "7" false
run_hook "$REPO" "7"
assert_eq "B3 AC6 multi any-true + bare false → exit 2" "$RC" "2"

# --- B4: all false → exit 0 ---
REPO=$(new_repo b4)
write_meta "$REPO" "CDT-111-C1-7.json" "CDT-111-C1-7" false
write_meta "$REPO" "7.json" "7" false
run_hook "$REPO" "7"
assert_eq "B4 all-false → exit 0" "$RC" "0"

# --- B5 AC5: preferred compound ≥ thr → exit 0 (CDT-163 regression) ---
REPO=$(new_repo b5)
write_meta "$REPO" "CDT-111-C1-7.json" "CDT-111-C1-7" true
write_meta "$REPO" "7.json" "7" false
jq -n '{
  "CDT-111-C1-7": [
    {"max_verdict_confidence": 95, "max_finding_confidence": null}
  ]
}' > "$REPO/.claude/council/index.json"
run_hook "$REPO" "7"
assert_eq "B5 AC5 preferred compound ≥ thr → exit 0" "$RC" "0"

# --- B6 AC3: preferred CDT-B-7 missing; only sibling CDT-A-7@95 → exit 2 ---
# Isolate: preferred miss MUST NOT borrow sibling score (multi-key merge bug).
REPO=$(new_repo b6)
write_meta "$REPO" "CDT-B-7.json" "CDT-B-7" true
write_meta "$REPO" "7.json" "7" false
jq -n '{
  "CDT-A-7": [
    {"max_verdict_confidence": 95, "max_finding_confidence": null}
  ]
}' > "$REPO/.claude/council/index.json"
run_hook "$REPO" "7"
assert_eq "B6 AC3 preferred miss + sibling@95 → exit 2 (no borrow)" "$RC" "2"

# --- B7 AC4: preferred CDT-B-7@50 + sibling CDT-A-7@95 thr80 → exit 2 ---
# Preferred key only; sibling high conf MUST NOT clear low preferred.
REPO=$(new_repo b7)
write_meta "$REPO" "CDT-B-7.json" "CDT-B-7" true
write_meta "$REPO" "7.json" "7" false
jq -n '{
  "CDT-B-7": [
    {"max_verdict_confidence": 50, "max_finding_confidence": null}
  ],
  "CDT-A-7": [
    {"max_verdict_confidence": 95, "max_finding_confidence": null}
  ]
}' > "$REPO/.claude/council/index.json"
run_hook "$REPO" "7"
assert_eq "B7 AC4 preferred@50 + sibling@95 thr80 → exit 2" "$RC" "2"

# --- B8 AC6 (optional): exact bare index key "7" only → exit 0 ---
REPO=$(new_repo b8)
write_meta "$REPO" "7.json" "7" true
jq -n '{
  "7": [
    {"max_verdict_confidence": 90, "max_finding_confidence": null}
  ]
}' > "$REPO/.claude/council/index.json"
run_hook "$REPO" "7"
assert_eq "B8 AC6 exact bare index key → exit 0" "$RC" "0"

# --- B9 AC7: no distinct preferred; unique suffix endswith(-7) ≥ thr → exit 0 ---
# Bare meta only → COMPOUND_KEY empty; single suffix key is the unique fallback.
REPO=$(new_repo b9)
write_meta "$REPO" "7.json" "7" true
jq -n '{
  "CDT-ONLY-7": [
    {"max_verdict_confidence": 90, "max_finding_confidence": null}
  ]
}' > "$REPO/.claude/council/index.json"
run_hook "$REPO" "7"
assert_eq "B9 AC7 unique suffix key ≥ thr → exit 0" "$RC" "0"

# --- B10 AC8: no preferred; two suffix keys CDT-A-7 + CDT-B-7 → exit 2 ---
# MUST NOT max-merge; stderr names bare id + both colliding keys.
REPO=$(new_repo b10)
write_meta "$REPO" "7.json" "7" true
jq -n '{
  "CDT-A-7": [
    {"max_verdict_confidence": 95, "max_finding_confidence": null}
  ],
  "CDT-B-7": [
    {"max_verdict_confidence": 95, "max_finding_confidence": null}
  ]
}' > "$REPO/.claude/council/index.json"
run_hook "$REPO" "7"
assert_eq "B10 AC8 multi-suffix no max-merge → exit 2" "$RC" "2"
assert_contains "B10 AC8 stderr names bare id 7" "$(cat "$HOOK_ERR")" "7"
assert_contains "B10 AC8 stderr names CDT-A-7" "$(cat "$HOOK_ERR")" "CDT-A-7"
assert_contains "B10 AC8 stderr names CDT-B-7" "$(cat "$HOOK_ERR")" "CDT-B-7"

# --- B11 CDT-186: two true compounds → preferred = lex-min stem AAA-ticket-7 ---
# Create ZZZ first then AAA (filesystem order must not affect preferred P).
REPO=$(new_repo b11)
write_meta "$REPO" "ZZZ-ticket-7.json" "ZZZ-ticket-7" true
write_meta "$REPO" "AAA-ticket-7.json" "AAA-ticket-7" true
jq -n '{
  "AAA-ticket-7": [
    {"max_verdict_confidence": 95, "max_finding_confidence": null}
  ]
}' > "$REPO/.claude/council/index.json"
run_hook "$REPO" "7"
assert_eq "B11 CDT-186 multi-true lex-min AAA preferred ≥ thr → exit 0" "$RC" "0"

# Reverse create order (AAA then ZZZ) — still prefer AAA-ticket-7.
REPO=$(new_repo b11b)
write_meta "$REPO" "AAA-ticket-7.json" "AAA-ticket-7" true
write_meta "$REPO" "ZZZ-ticket-7.json" "ZZZ-ticket-7" true
jq -n '{
  "AAA-ticket-7": [
    {"max_verdict_confidence": 95, "max_finding_confidence": null}
  ]
}' > "$REPO/.claude/council/index.json"
run_hook "$REPO" "7"
assert_eq "B11b CDT-186 reverse create order still AAA preferred → exit 0" "$RC" "0"

# --- B12 CDT-186: only non-preferred key has conf → exit 2 (isolate uses AAA) ---
REPO=$(new_repo b12)
write_meta "$REPO" "ZZZ-ticket-7.json" "ZZZ-ticket-7" true
write_meta "$REPO" "AAA-ticket-7.json" "AAA-ticket-7" true
jq -n '{
  "ZZZ-ticket-7": [
    {"max_verdict_confidence": 95, "max_finding_confidence": null}
  ]
}' > "$REPO/.claude/council/index.json"
run_hook "$REPO" "7"
assert_eq "B12 CDT-186 only non-preferred ZZZ@95 → exit 2 (isolate AAA)" "$RC" "2"


# =============================================================================
echo "== (C) task identity fields (SPEC-017 AC A) =="

# --- C1: new file, 3-arg create -> both keys present, type null ---
REPO=$(new_repo c1)
set +e
( cd "$REPO" && bash "$STORE" create T-1 "subj" true ) >/dev/null 2>"$BASE/c1.err"
RC=$?
set -e
assert_eq "C1 create rc" "$RC" "0"
f="$REPO/.claude/tasks/T-1.json"
assert_file_present "C1 file created" "$f"
got_has_po=$(jq -r 'has("plan_ordinal")' "$f")
got_has_tc=$(jq -r 'has("taskcreate_id")' "$f")
got_po_type=$(jq -r '.plan_ordinal | type' "$f")
got_tc_type=$(jq -r '.taskcreate_id | type' "$f")
assert_eq "C1 has plan_ordinal key" "$got_has_po" "true"
assert_eq "C1 has taskcreate_id key" "$got_has_tc" "true"
assert_eq "C1 plan_ordinal type null" "$got_po_type" "null"
assert_eq "C1 taskcreate_id type null" "$got_tc_type" "null"

# --- C2: 4-arg create (deps set) + both flags -> plan_ordinal number 3, taskcreate_id "43" ---
REPO=$(new_repo c2)
set +e
( cd "$REPO" && bash "$STORE" create T-43 "subj" true "" --plan-ordinal 3 --taskcreate-id 43 ) \
  >/dev/null 2>"$BASE/c2.err"
RC=$?
set -e
assert_eq "C2 create rc" "$RC" "0"
f="$REPO/.claude/tasks/T-43.json"
assert_file_present "C2 file created" "$f"
if [ -f "$f" ]; then
  got_po_type=$(jq -r '.plan_ordinal | type' "$f")
  got_tc_type=$(jq -r '.taskcreate_id | type' "$f")
  got_po=$(jq -r '.plan_ordinal' "$f")
  got_tc=$(jq -r '.taskcreate_id' "$f")
else
  got_po_type="(no file)"; got_tc_type="(no file)"; got_po="(no file)"; got_tc="(no file)"
fi
assert_eq "C2 plan_ordinal type number" "$got_po_type" "number"
assert_eq "C2 taskcreate_id type string" "$got_tc_type" "string"
assert_eq "C2 plan_ordinal value 3" "$got_po" "3"
assert_eq "C2 taskcreate_id value 43" "$got_tc" "43"

# --- C3: plain old 4-arg call (deps set, no flags) still works; keys present+null ---
REPO=$(new_repo c3)
set +e
( cd "$REPO" && bash "$STORE" create T-1 "subj" true "T-0" ) >/dev/null 2>"$BASE/c3.err"
RC=$?
set -e
assert_eq "C3 old 4-arg create rc" "$RC" "0"
f="$REPO/.claude/tasks/T-1.json"
got_deps=$(jq -c '.depends_on' "$f")
got_po_type=$(jq -r '.plan_ordinal | type' "$f")
got_tc_type=$(jq -r '.taskcreate_id | type' "$f")
assert_eq "C3 deps preserved" "$got_deps" '["T-0"]'
assert_eq "C3 plan_ordinal type null" "$got_po_type" "null"
assert_eq "C3 taskcreate_id type null" "$got_tc_type" "null"

# --- C4: upsert without flags keeps previously-set plan_ordinal/taskcreate_id ---
REPO=$(new_repo c4)
set +e
( cd "$REPO" && bash "$STORE" create T-43 "subj" true "" --plan-ordinal 3 --taskcreate-id 43 ) \
  >/dev/null 2>"$BASE/c4a.err"
( cd "$REPO" && bash "$STORE" create T-43 "subj2" false "" ) >/dev/null 2>"$BASE/c4b.err"
RC=$?
set -e
assert_eq "C4 upsert-no-flags rc" "$RC" "0"
f="$REPO/.claude/tasks/T-43.json"
got_po=$(jq -r '.plan_ordinal' "$f")
got_tc=$(jq -r '.taskcreate_id' "$f")
got_subj=$(jq -r '.subject' "$f")
assert_eq "C4 plan_ordinal kept" "$got_po" "3"
assert_eq "C4 taskcreate_id kept" "$got_tc" "43"
assert_eq "C4 subject updated by upsert" "$got_subj" "subj2"

# --- C5: bad --plan-ordinal '0' on existing T-43 -> exit 2, no write ---
REPO=$(new_repo c5)
set +e
( cd "$REPO" && bash "$STORE" create T-43 "subj" true "" --plan-ordinal 3 --taskcreate-id 43 ) \
  >/dev/null 2>"$BASE/c5setup.err"
set -e
f="$REPO/.claude/tasks/T-43.json"
before=$(cat "$f" 2>/dev/null || true)
set +e
( cd "$REPO" && bash "$STORE" create T-43 "subj3" true "" --plan-ordinal 0 ) >/dev/null 2>"$BASE/c5.err"
RC=$?
set -e
assert_eq "C5 bad plan-ordinal 0 exit 2" "$RC" "2"
after=$(cat "$f" 2>/dev/null || true)
assert_eq "C5 file unchanged" "$before" "$after"
assert_file_absent "C5 no tmp left" "$f.tmp"

# --- C6: bad --plan-ordinal 'x' on existing T-43 -> exit 2, no write ---
REPO=$(new_repo c6)
set +e
( cd "$REPO" && bash "$STORE" create T-43 "subj" true "" --plan-ordinal 3 --taskcreate-id 43 ) \
  >/dev/null 2>"$BASE/c6setup.err"
set -e
f="$REPO/.claude/tasks/T-43.json"
before=$(cat "$f" 2>/dev/null || true)
set +e
( cd "$REPO" && bash "$STORE" create T-43 "subj3" true "" --plan-ordinal x ) >/dev/null 2>"$BASE/c6.err"
RC=$?
set -e
assert_eq "C6 bad plan-ordinal x exit 2" "$RC" "2"
after=$(cat "$f" 2>/dev/null || true)
assert_eq "C6 file unchanged" "$before" "$after"
assert_file_absent "C6 no tmp left" "$f.tmp"

# --- C7: bad --taskcreate-id 'a.b' (dotted) on existing T-43 -> exit 2, no write ---
REPO=$(new_repo c7)
set +e
( cd "$REPO" && bash "$STORE" create T-43 "subj" true "" --plan-ordinal 3 --taskcreate-id 43 ) \
  >/dev/null 2>"$BASE/c7setup.err"
set -e
f="$REPO/.claude/tasks/T-43.json"
before=$(cat "$f" 2>/dev/null || true)
set +e
( cd "$REPO" && bash "$STORE" create T-43 "subj3" true "" --taskcreate-id "a.b" ) >/dev/null 2>"$BASE/c7.err"
RC=$?
set -e
assert_eq "C7 bad taskcreate-id dotted exit 2" "$RC" "2"
after=$(cat "$f" 2>/dev/null || true)
assert_eq "C7 file unchanged" "$before" "$after"
assert_file_absent "C7 no tmp left" "$f.tmp"

# --- C8: --taskcreate-id '44' is not the suffix of T-43 -> exit 2, no write ---
REPO=$(new_repo c8)
set +e
( cd "$REPO" && bash "$STORE" create T-43 "subj" true "" --plan-ordinal 3 --taskcreate-id 43 ) \
  >/dev/null 2>"$BASE/c8setup.err"
set -e
f="$REPO/.claude/tasks/T-43.json"
before=$(cat "$f" 2>/dev/null || true)
set +e
( cd "$REPO" && bash "$STORE" create T-43 "subj3" true "" --taskcreate-id 44 ) >/dev/null 2>"$BASE/c8.err"
RC=$?
set -e
assert_eq "C8 bad taskcreate-id non-suffix exit 2" "$RC" "2"
after=$(cat "$f" 2>/dev/null || true)
assert_eq "C8 file unchanged" "$before" "$after"
assert_file_absent "C8 no tmp left" "$f.tmp"

# --- C9: bad flag on a FRESH id -> exit 2, no file at all ---
REPO=$(new_repo c9)
set +e
( cd "$REPO" && bash "$STORE" create T-99 "subj" true "" --plan-ordinal 0 ) >/dev/null 2>"$BASE/c9.err"
RC=$?
set -e
assert_eq "C9 bad flag fresh id exit 2" "$RC" "2"
assert_file_absent "C9 fresh id file absent" "$REPO/.claude/tasks/T-99.json"
assert_file_absent "C9 fresh id tmp absent" "$REPO/.claude/tasks/T-99.json.tmp"

# =============================================================================
echo "== (D) dag-lib.sh ready-set integration (SPEC-017 AC B) =="

# --- D1: Step-7-shaped store; T-43 out of ready-set until both deps completed ---
REPO=$(new_repo d1)
set +e
( cd "$REPO" && bash "$STORE" create T-41 "task one" false ) >/dev/null 2>"$BASE/d1-41.err"
( cd "$REPO" && bash "$STORE" create T-42 "task two" false ) >/dev/null 2>"$BASE/d1-42.err"
( cd "$REPO" && bash "$STORE" create T-43 "task three" true "T-41:T-42" \
    --plan-ordinal 3 --taskcreate-id 43 ) >/dev/null 2>"$BASE/d1-43.err"
set -e
assert_file_present "D1 T-43 file exists (guards against old-code usage reject)" \
  "$REPO/.claude/tasks/T-43.json"

set +e
READY=$( cd "$REPO" && bash "$DAG_LIB" ready-set 2>"$BASE/d1-ready1.err" | sort )
RC=$?
set -e
assert_eq "D1 ready-set (no deps done) rc" "$RC" "0"
assert_contains "D1 T-41 ready" "$READY" "T-41"
assert_contains "D1 T-42 ready" "$READY" "T-42"
if printf '%s\n' "$READY" | grep -qx "T-43"; then
  FAIL=$((FAIL + 1)); echo "  FAIL D1 T-43 must not be ready yet: [$READY]"
else
  PASS=$((PASS + 1)); echo "  ok  D1 T-43 not ready yet"
fi

set +e
( cd "$REPO" && bash "$STORE" update-status T-41 completed ) >/dev/null 2>"$BASE/d1-u41.err"
set -e
set +e
READY=$( cd "$REPO" && bash "$DAG_LIB" ready-set 2>"$BASE/d1-ready2.err" | sort )
RC=$?
set -e
if printf '%s\n' "$READY" | grep -qx "T-43"; then
  FAIL=$((FAIL + 1)); echo "  FAIL D1 T-43 must still not be ready (T-42 incomplete): [$READY]"
else
  PASS=$((PASS + 1)); echo "  ok  D1 T-43 still not ready (T-42 incomplete)"
fi

set +e
( cd "$REPO" && bash "$STORE" update-status T-42 completed ) >/dev/null 2>"$BASE/d1-u42.err"
set -e
set +e
READY=$( cd "$REPO" && bash "$DAG_LIB" ready-set 2>"$BASE/d1-ready3.err" | sort )
RC=$?
set -e
assert_contains "D1 T-43 ready once both deps completed" "$READY" "T-43"

# =============================================================================
echo "== (E) create stderr — exactly one line (SPEC-017 AC C) =="

# --- E1: new file -> exactly one stderr line, "created: <path>" ---
REPO=$(new_repo e1)
set +e
( cd "$REPO" && bash "$STORE" create T-1 "subj" true ) >/dev/null 2>"$BASE/e1.err"
RC=$?
set -e
assert_eq "E1 create rc" "$RC" "0"
e1_lines=$(wc -l < "$BASE/e1.err" | tr -d ' ')
assert_eq "E1 stderr exactly one line" "$e1_lines" "1"
assert_contains "E1 line says created" "$(cat "$BASE/e1.err")" "created: $REPO/.claude/tasks/T-1.json"

# --- E2: upsert (create again on same id) -> exactly one stderr line, "upserted: ..." ---
REPO=$(new_repo e2)
set +e
( cd "$REPO" && bash "$STORE" create T-1 "subj" true ) >/dev/null 2>"$BASE/e2a.err"
( cd "$REPO" && bash "$STORE" create T-1 "subj2" false ) >/dev/null 2>"$BASE/e2b.err"
RC=$?
set -e
assert_eq "E2 upsert rc" "$RC" "0"
e2_lines=$(wc -l < "$BASE/e2b.err" | tr -d ' ')
assert_eq "E2 upsert stderr exactly one line" "$e2_lines" "1"
assert_contains "E2 line says upserted" "$(cat "$BASE/e2b.err")" "upserted: $REPO/.claude/tasks/T-1.json"

# =============================================================================
echo ""
echo "task-store-test: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
