#!/usr/bin/env bash
# Concurrent add vs a held backlog lock, and close.sh newline rejection.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s — %s\n' "$1" "$2"; }
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/add-lock.XXXXXX")
mkdir -p "$ROOT/.claude"
lockdir="$ROOT/.claude/backlog.lock"
mkdir -p "$lockdir"
printf '%s %s %s\n' "$(date +%s)" "2026-01-01T00:00:00Z" "holder" > "$lockdir/stamp"
rc=0
out=$(BACKLOG_LOCK_WAIT_SECONDS=1 bash "$HERE/add.sh" --root "$ROOT" --title "Held lock item" 2>&1) || rc=$?
if [ "$rc" -eq 1 ] && [ ! -f "$ROOT/.claude/backlog/held-lock-item.md" ]; then
  pass "add waits on a fresh lock and writes nothing"
else
  fail "add under a held lock" "rc=$rc out=$out"
fi
rm -rf "$lockdir"
rc=0
out=$(bash "$HERE/add.sh" --root "$ROOT" --title "Held lock item" 2>&1) || rc=$?
if [ "$rc" -eq 0 ] && [ -f "$ROOT/.claude/backlog/held-lock-item.md" ] \
   && grep -q 'held-lock-item.md' "$ROOT/.claude/backlog.md"; then
  pass "add writes the item and the index after the lock is free"
else
  fail "add after release" "rc=$rc out=$out"
fi
rc=0
out=$(bash "$HERE/close.sh" "held-lock-item" --root "$ROOT" --note "$(printf 'a\nb')" 2>&1) || rc=$?
if [ "$rc" -eq 64 ] && printf '%s' "$out" | grep -q 'newline'; then
  pass "close rejects a newline in --note"
else
  fail "close newline" "rc=$rc out=$out"
fi
rc=0
out=$(bash "$HERE/add.sh" --root "$ROOT" --title "Linked item" --linear-id "CDT-389" 2>&1) || rc=$?
if [ "$rc" -eq 0 ] \
   && grep -q 'linear_id: CDT-389' "$ROOT/.claude/backlog/linked-item.md" \
   && grep -q 'linear:CDT-389' "$ROOT/.claude/backlog.md" \
   && [ "$(grep -c 'linked-item.md' "$ROOT/.claude/backlog.md")" -eq 1 ]; then
  pass "add writes linear id inside the locked write, one index row"
else
  fail "linear id" "rc=$rc out=$out"
fi
rc=0
out=$(bash "$HERE/close.sh" "held-lock-item" --root "$ROOT" --ticket "$(printf 'A\rB')" 2>&1) || rc=$?
if [ "$rc" -eq 64 ] && printf '%s' "$out" | grep -q 'newline'; then
  pass "close rejects a CR in --ticket"
else
  fail "close CR" "rc=$rc out=$out"
fi
rm -rf "$ROOT"
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
