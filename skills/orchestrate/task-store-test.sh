#!/usr/bin/env bash
# task-store-test.sh — CDT-167 + CDT-163 regression for task-store invent +
# TaskCompleted shadow-safe meta and index isolate scores
# (CDT-167 AC1/AC2/AC4/AC5/AC6; CDT-163 AC3/AC4/AC5/AC7/AC8; SPEC-002).
#
# Machine-check: bash skills/orchestrate/task-store-test.sh  (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
# (A) task-store invent — temp git repo as MROOT via git-common-dir
# (B) hook shadow-safe — extract task-completed body from
#     skills/init-orchestration/SKILL.md (same marker as check-hook-templates)
#     CDT-163 B6/B7/B9/B10: isolate preferred + unique-suffix; no multi-key max-merge

set -u

PASS=0
FAIL=0
die() { echo "FATAL: $*" >&2; exit 1; }

assert_eq() {
  local name="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1)); echo "  ok  $name"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $name: got=[$got] want=[$want]"
  fi
}

assert_ne() {
  local name="$1" got="$2" want_not="$3"
  if [ "$got" != "$want_not" ]; then
    PASS=$((PASS + 1)); echo "  ok  $name"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $name: got=[$got] want !=[$want_not]"
  fi
}

assert_file_absent() {
  local name="$1" path="$2"
  if [ ! -f "$path" ]; then
    PASS=$((PASS + 1)); echo "  ok  $name"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $name: unexpected file $path"
  fi
}

assert_file_present() {
  local name="$1" path="$2"
  if [ -f "$path" ]; then
    PASS=$((PASS + 1)); echo "  ok  $name"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $name: missing $path"
  fi
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    PASS=$((PASS + 1)); echo "  ok  $name"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $name: missing [$needle] in [$haystack]"
  fi
}

command -v jq >/dev/null 2>&1 || die "jq required"
command -v python3 >/dev/null 2>&1 || die "python3 required"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
STORE="$SCRIPT_DIR/task-store.sh"
SKILL="$ROOT/skills/init-orchestration/SKILL.md"
[ -f "$STORE" ] || die "task-store.sh not found at $STORE"
[ -f "$SKILL" ] || die "SKILL.md not found at $SKILL"
[ -x "$STORE" ] || chmod +x "$STORE"

BASE=$(mktemp -d "${TMPDIR:-/tmp}/task-store-test.XXXXXX") || die "mktemp failed"
BASE=$(realpath "$BASE")
cleanup() { rm -rf "$BASE"; }
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

# =============================================================================
echo ""
echo "task-store-test: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
