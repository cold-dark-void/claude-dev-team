#!/usr/bin/env bash
# escalation-gate-test.sh — bite-tests for the escalation-gate.sh PreToolUse hook
# templated in skills/init-orchestration/SKILL.md (SPEC-031 / CDT-98 / CDT-102).
#
# Machine-check: bash skills/init-orchestration/escalation-gate-test.sh  (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
#
# The hook body is single-sourced in SKILL.md's fenced ```bash block; this
# harness extracts it verbatim (same block check-hook-templates.sh verifies) and
# drives it with JSON stdin under an isolated fake $MROOT + $TMPDIR. Covers:
#   T19 tamper-surface carve-out (CDT-102, C1)
#   T20 warn-latch session-scoping (CDT-102, B1)
#   T21 warn-latch symlink hardening (CDT-102, B2)
#   T8/T9 WARN vs BLOCK routing (regression)
#   T10 NotebookEdit notebook_path handling (regression)
#   T11 fail-open on hook errors (regression)
#   T12 allowlist / doc exemption (regression)

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
assert_contains() {
  local name="$1" hay="$2" needle="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then
    PASS=$((PASS + 1)); echo "  ok  $name"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $name: missing [$needle]"
  fi
}

command -v jq >/dev/null 2>&1 || die "jq required to drive the hook"
BASH_BIN=$(command -v bash) || die "bash not found"

# ---- Extract the hook template verbatim from SKILL.md -----------------------
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SKILL="$SCRIPT_DIR/SKILL.md"
[ -f "$SKILL" ] || die "SKILL.md not found at $SKILL"

# ---- Isolated fake repo ($MROOT) + isolated $TMPDIR for latches -------------
BASE=$(mktemp -d "${TMPDIR:-/tmp}/escgate-harness.XXXXXX") || die "mktemp failed"
BASE=$(realpath "$BASE")
REPO="$BASE/repo"
TESTTMP="$BASE/tmp"
mkdir -p "$REPO" "$TESTTMP"
cleanup() { rm -rf "$BASE"; }
trap cleanup EXIT

HOOK="$BASE/escalation-gate.sh"
awk -v out="$HOOK" '
  index($0, "escalation-gate.sh` with this content:") { found=1; next }
  found && $0 == "```bash" { inblock=1; next }
  inblock && $0 == "```" { exit }
  inblock { print > out }
' "$SKILL"
[ -s "$HOOK" ] || die "could not extract escalation-gate.sh template from SKILL.md"
chmod +x "$HOOK"

git init -q "$REPO" || die "git init failed"
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"
git -C "$REPO" commit --allow-empty -q -m init || die "empty commit failed"
mkdir -p "$REPO/.worktrees/foo/src" "$REPO/src" "$REPO/specs" \
         "$REPO/.claude/hooks" "$REPO/.claude/plans" \
         "$REPO/.claude/escalation-gate/armed"

export TMPDIR="$TESTTMP"

SID="sess-AAA"

# ---- Helpers ----------------------------------------------------------------
HOOK_ERR="$BASE/hook.err"
RC=0

# payload TOOL PATH SESSION AGENT [PATHKEY]
payload() {
  local key="${5:-file_path}"
  jq -nc --arg t "$1" --arg p "$2" --arg s "$3" --arg a "$4" --arg k "$key" \
    '{tool_name:$t, tool_input:{($k):$p}}
     + (if $s=="" then {} else {session_id:$s} end)
     + (if $a=="" then {} else {agent_id:$a} end)'
}

run_hook() {  # stdin JSON in $1 ; sets RC, stderr in $HOOK_ERR
  printf '%s' "$1" | ( cd "$REPO" && bash "$HOOK" ) 2>"$HOOK_ERR"
  RC=$?
}

arm() {  # slug session
  { echo "slug=$1"; echo "worktree=$REPO/.worktrees/$1";
    echo "session_id=$2"; echo "agent_id=main";
    echo "armed_at=2026-08-02T00:00:00Z"; } \
    > "$REPO/.claude/escalation-gate/armed/$1.marker"
}
disarm_all() { rm -f "$REPO/.claude/escalation-gate/armed/"*.marker; }
clear_latches() { rm -f "$TESTTMP"/claude-escgate-* 2>/dev/null; }

# =============================================================================
echo "== T8/T9 WARN vs BLOCK routing =="
disarm_all; clear_latches
run_hook "$(payload Write "$REPO/src/a.go" "$SID" main)"
assert_eq "unarmed out-of-worktree exits 0 (WARN)" "$RC" "0"
assert_contains "WARN stderr names the gate" "$(cat "$HOOK_ERR")" "Escalation gate:"

run_hook "$(payload Write "$REPO/.worktrees/foo/src/a.go" "$SID" main)"
assert_eq "in-worktree write exits 0" "$RC" "0"

arm foo "$SID"
run_hook "$(payload Write "$REPO/src/a.go" "$SID" main)"
assert_eq "armed out-of-worktree exits 2 (BLOCK)" "$RC" "2"
assert_contains "BLOCK stderr says BLOCK" "$(cat "$HOOK_ERR")" "BLOCK"

run_hook "$(payload Write "$REPO/.worktrees/foo/src/a.go" "$SID" main)"
assert_eq "armed in-worktree write exits 0" "$RC" "0"

# armed but session mismatch => no marker match => WARN not BLOCK
run_hook "$(payload Write "$REPO/src/a.go" "sess-OTHER" main)"
assert_eq "armed marker, different session exits 0 (WARN)" "$RC" "0"
disarm_all

# =============================================================================
echo "== T19 tamper-surface carve-out (CDT-102 C1) =="
arm foo "$SID"
for tgt in \
  "$REPO/.claude/hooks/escalation-gate.sh" \
  "$REPO/.claude/settings.json" \
  "$REPO/.claude/settings.local.json" \
  "$REPO/.claude/escalation-gate/armed/foo.marker"; do
  run_hook "$(payload Write "$tgt" "$SID" main)"
  assert_eq "armed BLOCKs tamper write ${tgt##*/.claude/}" "$RC" "2"
done
# doc exemption retained while armed
run_hook "$(payload Write "$REPO/README.md" "$SID" main)"
assert_eq "armed README.md still exits 0 (doc exemption)" "$RC" "0"
run_hook "$(payload Write "$REPO/specs/SPEC-999-x.md" "$SID" main)"
assert_eq "armed specs/*.md still exits 0" "$RC" "0"
# narrowness: a non-tamper .claude/ path is still allowlisted while armed
run_hook "$(payload Write "$REPO/.claude/plans/p.json" "$SID" main)"
assert_eq "armed non-tamper .claude/*.json exits 0 (carve-out is narrow)" "$RC" "0"

# unarmed: same tamper writes are unaffected (exit 0 via .claude allowlist)
disarm_all
for tgt in \
  "$REPO/.claude/hooks/escalation-gate.sh" \
  "$REPO/.claude/settings.json" \
  "$REPO/.claude/settings.local.json" \
  "$REPO/.claude/escalation-gate/armed/foo.marker"; do
  run_hook "$(payload Write "$tgt" "$SID" main)"
  assert_eq "unarmed tamper write ${tgt##*/.claude/} exits 0" "$RC" "0"
done

# =============================================================================
echo "== T20 warn-latch session-scoping (CDT-102 B1) =="
disarm_all; clear_latches
# session A warns twice; session B (same MROOT, same agent) warns once
run_hook "$(payload Write "$REPO/src/a.go" "sess-A" main)"; assert_eq "A warn1 exit0" "$RC" "0"
run_hook "$(payload Write "$REPO/src/a.go" "sess-A" main)"; assert_eq "A warn2 exit0" "$RC" "0"
run_hook "$(payload Write "$REPO/src/a.go" "sess-B" main)"; assert_eq "B warn1 exit0" "$RC" "0"
NFILES=$(ls "$TESTTMP"/claude-escgate-* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "two distinct session latches exist" "$NFILES" "2"
# find each latch by content: A should be 2, B should be 1 (no cross-session bleed)
FOUND_A=""; FOUND_B=""
for f in "$TESTTMP"/claude-escgate-*; do
  c=$(cat "$f")
  [ "$c" = "2" ] && FOUND_A=1
  [ "$c" = "1" ] && FOUND_B=1
done
assert_eq "session A latch counted to 2" "${FOUND_A:-0}" "1"
assert_eq "session B latch independent at 1 (no bleed)" "${FOUND_B:-0}" "1"
# fallback: no session_id uses agent-only key (a 3rd, distinct latch)
run_hook "$(payload Write "$REPO/src/a.go" "" main)"; assert_eq "no-session warn exit0" "$RC" "0"
NFILES=$(ls "$TESTTMP"/claude-escgate-* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "no-session fallback latch is distinct (3 total)" "$NFILES" "3"

# =============================================================================
echo "== T21 warn-latch symlink hardening (CDT-102 B2) =="
disarm_all; clear_latches
# discover the latch path by triggering one warn
run_hook "$(payload Write "$REPO/src/a.go" "sess-SL" main)"; assert_eq "symlink pretest exit0" "$RC" "0"
LATCHFILE=$(ls "$TESTTMP"/claude-escgate-* 2>/dev/null | head -1)
[ -n "$LATCHFILE" ] || die "could not locate latch file for symlink test"
SCRATCH="$BASE/scratch-target"
printf 'SENTINEL' > "$SCRATCH"
rm -f "$LATCHFILE"
ln -s "$SCRATCH" "$LATCHFILE"
run_hook "$(payload Write "$REPO/src/a.go" "sess-SL" main)"
assert_eq "warn over planted symlink exits 0" "$RC" "0"
assert_eq "scratch target NOT clobbered (SENTINEL intact)" "$(cat "$SCRATCH")" "SENTINEL"
if [ -L "$LATCHFILE" ]; then
  FAIL=$((FAIL + 1)); echo "  FAIL symlink at latch path was followed, not removed"
else
  PASS=$((PASS + 1)); echo "  ok  symlink removed; latch is a regular file"
fi

# =============================================================================
echo "== T10 NotebookEdit notebook_path handling =="
disarm_all; clear_latches
run_hook "$(payload NotebookEdit "$REPO/nb.ipynb" "$SID" main notebook_path)"
assert_eq "unarmed notebook_path out-of-worktree exits 0 (WARN)" "$RC" "0"
assert_contains "notebook WARN names target" "$(cat "$HOOK_ERR")" "nb.ipynb"
arm foo "$SID"
run_hook "$(payload NotebookEdit "$REPO/nb.ipynb" "$SID" main notebook_path)"
assert_eq "armed notebook_path out-of-worktree exits 2 (gated via notebook_path)" "$RC" "2"
disarm_all

# =============================================================================
echo "== T11 fail-open on hook errors =="
disarm_all; clear_latches
# malformed stdin
printf 'not json at all' | ( cd "$REPO" && bash "$HOOK" ) 2>/dev/null; RC=$?
assert_eq "malformed stdin exits 0" "$RC" "0"
# armed but marker directory absent => degrades to WARN (exit 0)
rm -rf "$REPO/.claude/escalation-gate"
run_hook "$(payload Write "$REPO/src/a.go" "$SID" main)"
assert_eq "armed request, marker dir absent exits 0" "$RC" "0"
mkdir -p "$REPO/.claude/escalation-gate/armed"
# jq unavailable on PATH => fail open at first check
printf '%s' "$(payload Write "$REPO/src/a.go" "$SID" main)" \
  | ( cd "$REPO" && PATH="/nonexistent-dir" "$BASH_BIN" "$HOOK" ) 2>/dev/null; RC=$?
assert_eq "jq absent exits 0 (fail-open)" "$RC" "0"
# non-editing tool name is ignored
run_hook "$(payload Read "$REPO/src/a.go" "$SID" main)"
assert_eq "non-editing tool exits 0" "$RC" "0"

# =============================================================================
echo "== T12 allowlist / doc exemption (unarmed) =="
disarm_all; clear_latches
for tgt in "$REPO/.claude/foo.json" "$REPO/specs/SPEC-1-x.md" "$REPO/README.md"; do
  run_hook "$(payload Write "$tgt" "$SID" main)"
  assert_eq "allowlisted ${tgt##*/} exits 0" "$RC" "0"
done

# =============================================================================
echo ""
echo "escalation-gate-test: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
