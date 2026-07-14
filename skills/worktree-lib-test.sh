#!/usr/bin/env bash
# worktree-lib-test.sh — bite-tests for worktree-lib.sh (CDV-189 Part 2)
#
# Machine-check: bash skills/worktree-lib-test.sh  (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB="$SCRIPT_DIR/worktree-lib.sh"

PASS=0
FAIL=0

die() { echo "FAIL: $*" >&2; exit 1; }

assert_eq() {
  local name="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
    echo "  ok  $name"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL $name: got=[$got] want=[$want]"
  fi
}

assert_contains() {
  local name="$1" hay="$2" needle="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then
    PASS=$((PASS + 1))
    echo "  ok  $name"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL $name: missing [$needle] in:"
    printf '%s\n' "$hay" | head -10 | sed 's/^/    /'
  fi
}

assert_not_contains() {
  local name="$1" hay="$2" needle="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then
    FAIL=$((FAIL + 1))
    echo "  FAIL $name: unexpected [$needle]"
  else
    PASS=$((PASS + 1))
    echo "  ok  $name"
  fi
}

assert_file() {
  local name="$1" path="$2"
  if [ -f "$path" ]; then
    PASS=$((PASS + 1))
    echo "  ok  $name"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL $name: missing file $path"
  fi
}

assert_dir() {
  local name="$1" path="$2"
  if [ -d "$path" ]; then
    PASS=$((PASS + 1))
    echo "  ok  $name"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL $name: missing dir $path"
  fi
}

# ---- Isolated fake MROOT ----------------------------------------------------
TMP=$(mktemp -d "${TMPDIR:-/tmp}/worktree-lib-test.XXXXXX")
ERR_TMP="${TMPDIR:-/tmp}/wt-test-err.$$"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

git init -q "$TMP" || die "git init failed"
git -C "$TMP" config user.email "test@example.com"
git -C "$TMP" config user.name "Test"
git -C "$TMP" commit --allow-empty -q -m "init" || die "empty commit failed"
cd "$TMP" || die "cd $TMP"

run_lib() {
  # Preserve exit code; capture stdout/stderr separately when needed
  bash "$LIB" "$@"
}

echo "== T1 status empty =="
OUT=$(run_lib status 2>"$ERR_TMP"); RC=$?
assert_eq "status empty exit 0" "$RC" "0"
assert_eq "status empty stdout" "$OUT" ""

echo "== T2 status FRESH / STALE =="
mkdir -p .worktrees/fresh-slug .worktrees/stale-slug
# Minimal git checkout markers optional — status tolerates (unknown) HEAD
NOW=$(date +%s)
printf '%s %s\n' "$NOW" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > .worktrees/fresh-slug/.wt-lock
OLD=$(( NOW - 86400 ))
printf '%s %s\n' "$OLD" "2020-01-01T00:00:00Z" > .worktrees/stale-slug/.wt-lock
# No-lock dir
mkdir -p .worktrees/none-slug

export WT_LOCK_TTL_SECONDS=21600
OUT=$(run_lib status 2>"$ERR_TMP"); RC=$?
assert_eq "status FRESH/STALE exit 0" "$RC" "0"
assert_contains "status has fresh FRESH" "$OUT" "fresh-slug"
assert_contains "status FRESH state" "$OUT" "fresh-slug | feat/fresh-slug | FRESH |"
assert_contains "status STALE state" "$OUT" "stale-slug | feat/stale-slug | STALE |"
assert_contains "status NONE state" "$OUT" "none-slug | feat/none-slug | NONE | - |"
assert_not_contains "status no PID field" "$OUT" "PID"
assert_not_contains "status no session_id" "$OUT" "session"

echo "== T3 list alias =="
LIST_OUT=$(run_lib list 2>"$ERR_TMP"); LRC=$?
assert_eq "list exit 0" "$LRC" "0"
assert_eq "list == status" "$LIST_OUT" "$OUT"

echo "== T4 register ok / missing =="
mkdir -p .worktrees/reg-slug
ROUT=$(run_lib register reg-slug 2>"$ERR_TMP"); RRC=$?
assert_eq "register ok exit 0" "$RRC" "0"
assert_eq "register prints path" "$ROUT" "$TMP/.worktrees/reg-slug"
assert_file "register wrote lock" ".worktrees/reg-slug/.wt-lock"
# mode 600 (umask 077)
MODE=$(stat -c '%a' .worktrees/reg-slug/.wt-lock 2>/dev/null || stat -f '%Lp' .worktrees/reg-slug/.wt-lock)
assert_eq "register lock mode 600" "$MODE" "600"
# lock format epoch ISO
LOCK_LINE=$(head -1 .worktrees/reg-slug/.wt-lock)
if [[ "$LOCK_LINE" =~ ^[0-9]+[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
  PASS=$((PASS + 1)); echo "  ok  register lock format"
else
  FAIL=$((FAIL + 1)); echo "  FAIL register lock format: $LOCK_LINE"
fi
# no branch created by register
if git rev-parse --verify --quiet refs/heads/feat/reg-slug >/dev/null 2>&1; then
  FAIL=$((FAIL + 1)); echo "  FAIL register must not create branch"
else
  PASS=$((PASS + 1)); echo "  ok  register no branch"
fi

ROUT=$(run_lib register missing-slug 2>"$ERR_TMP"); RRC=$?
assert_eq "register missing exit 1" "$RRC" "1"

echo "== T5 release dirty refuses =="
# Real worktree via ensure
EOUT=$(run_lib ensure dirty-slug 2>"$ERR_TMP"); ERC=$?
assert_eq "ensure dirty-slug exit 0" "$ERC" "0"
assert_dir "ensure created wt" ".worktrees/dirty-slug"
# Dirtify
echo "dirty" > .worktrees/dirty-slug/dirty.txt
REL_OUT=$(run_lib release dirty-slug 2>"$ERR_TMP"); RERC=$?
assert_eq "release dirty exit 1" "$RERC" "1"
assert_dir "release dirty kept dir" ".worktrees/dirty-slug"
assert_file "release dirty kept dirty file" ".worktrees/dirty-slug/dirty.txt"
# cleanup for later: remove dirty so we can release if needed
rm -f .worktrees/dirty-slug/dirty.txt

echo "== T6 sweep no-delete =="
# stale-slug already STALE, no tasks → PROPOSAL
# fresh-slug FRESH → not proposed
# Add live-task worktree STALE but protected by task
mkdir -p .worktrees/live-slug .claude/tasks
printf '%s %s\n' "$OLD" "2020-01-01T00:00:00Z" > .worktrees/live-slug/.wt-lock
cat > .claude/tasks/live-slug.json << 'JSON'
{"task_id":"live-slug","subject":"held","status":"in_progress","requires_council":false,"depends_on":[],"created_at":"2020-01-01T00:00:00Z"}
JSON

SWEEP=$(run_lib sweep 2>"$ERR_TMP"); SRC=$?
assert_eq "sweep exit 0" "$SRC" "0"
assert_contains "sweep proposes stale-slug" "$SWEEP" "PROPOSAL stale-slug"
assert_not_contains "sweep skips FRESH" "$SWEEP" "PROPOSAL fresh-slug"
assert_not_contains "sweep skips live task" "$SWEEP" "PROPOSAL live-slug"
assert_dir "sweep did not delete stale" ".worktrees/stale-slug"
assert_file "sweep did not delete stale lock" ".worktrees/stale-slug/.wt-lock"
assert_dir "sweep did not delete live" ".worktrees/live-slug"

# completed task should NOT protect
cat > .claude/tasks/stale-slug.json << 'JSON'
{"task_id":"stale-slug","subject":"done","status":"completed","requires_council":false,"depends_on":[],"created_at":"2020-01-01T00:00:00Z"}
JSON
SWEEP2=$(run_lib sweep 2>"$ERR_TMP"); SRC2=$?
assert_eq "sweep completed still proposes" "$SRC2" "0"
assert_contains "sweep still proposes completed-task slug" "$SWEEP2" "PROPOSAL stale-slug"

# cleanup temp err
rm -f "$ERR_TMP" 2>/dev/null || true

echo
echo "Results: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
