#!/usr/bin/env bash
# scheduled-lock-test.sh — unit tests for scheduled-lock.sh (CDV-190, CDT-344)
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LOCK_SH="$HERE/scheduled-lock.sh"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
MROOT="$TMP/proj"
mkdir -p "$MROOT"

lock_file() { printf '%s\n' "$1/.claude/retro/scheduled.lock"; }

# 1. acquire succeeds and prints an owner token
TOKEN=$(bash "$LOCK_SH" acquire "$MROOT")
rc=$?
if [ "$rc" -eq 0 ] && [ -n "$TOKEN" ]; then
  ok "acquire first token"
else
  bad "acquire first rc=$rc token=${TOKEN:-empty}"
fi
[ -f "$(lock_file "$MROOT")" ] && ok "lock file exists" || bad "lock file missing"
# token is the third line of the lock (pid, ts, token)
got=$(sed -n '3p' "$(lock_file "$MROOT")")
[ -n "$TOKEN" ] && [ "$got" = "$TOKEN" ] && ok "lock stores the owner token" || bad "lock token want ${TOKEN:-empty} got ${got:-empty}"

# 2. second acquire while fresh → rc 2, first token unchanged
before=$(cat "$(lock_file "$MROOT")")
bash "$LOCK_SH" acquire "$MROOT" >/dev/null 2>/dev/null
rc=$?
if [ "$rc" -eq 2 ]; then
  ok "second acquire rc=2"
else
  bad "second acquire want rc=2 got $rc"
fi
after=$(cat "$(lock_file "$MROOT")")
[ "$before" = "$after" ] && ok "held lock body unchanged" || bad "held lock body changed"

# 3. release with the owner token, then re-acquire
bash "$LOCK_SH" release "$MROOT" "$TOKEN"
if [ ! -f "$(lock_file "$MROOT")" ]; then
  ok "owner release removes the lock"
else
  bad "owner release left the lock"
fi
TOKEN=$(bash "$LOCK_SH" acquire "$MROOT")
rc=$?
if [ "$rc" -eq 0 ] && [ -n "$TOKEN" ]; then
  ok "re-acquire after release"
else
  bad "re-acquire after release rc=$rc"
fi

# 4. stale lock (age > 7200) is stolen
printf '99999\n1\n' >"$(lock_file "$MROOT")"
TOKEN=$(bash "$LOCK_SH" acquire "$MROOT")
rc=$?
if [ "$rc" -eq 0 ] && [ -n "$TOKEN" ]; then
  ok "stale lock stolen"
else
  bad "stale lock not stolen rc=$rc"
fi
ts=$(sed -n '2p' "$(lock_file "$MROOT")")
now=$(date +%s)
age=$((now - ts))
if [ "$age" -lt 60 ]; then
  ok "stolen lock has fresh ts"
else
  bad "stolen lock ts stale age=$age"
fi

# 5. release is fail-open when the lock is already gone
bash "$LOCK_SH" release "$MROOT" "$TOKEN"
bash "$LOCK_SH" release "$MROOT" "$TOKEN"
rc=$?
if [ "$rc" -eq 0 ]; then
  ok "release fail-open"
else
  bad "release fail-open rc=$rc"
fi

# 6. usage error
bash "$LOCK_SH" 2>/dev/null
rc=$?
if [ "$rc" -eq 1 ]; then
  ok "usage error rc=1"
else
  bad "usage want 1 got $rc"
fi

# 7. a non-owner release does not delete a live lock (CDT-344)
TOKEN=$(bash "$LOCK_SH" acquire "$MROOT")
bash "$LOCK_SH" release "$MROOT" "not-the-owner" 
if [ -f "$(lock_file "$MROOT")" ]; then
  ok "wrong token leaves the lock"
else
  bad "wrong token deleted the lock"
fi
bash "$LOCK_SH" release "$MROOT"
if [ -f "$(lock_file "$MROOT")" ]; then
  ok "release without a token leaves the lock"
else
  bad "release without a token deleted the lock"
fi
# the owner can still release
bash "$LOCK_SH" release "$MROOT" "$TOKEN"
if [ ! -f "$(lock_file "$MROOT")" ]; then
  ok "owner token still releases after a refused release"
else
  bad "owner token did not release"
fi

# 8. parallel acquire: exactly one winner (CDT-344)
PDIR="$TMP/parallel"
mkdir -p "$PDIR"
N=8
i=1
while [ "$i" -le "$N" ]; do
  bash "$LOCK_SH" acquire "$PDIR" >"$TMP/pout.$i" 2>"$TMP/perr.$i" &
  i=$((i + 1))
done
okc=0
wait || true
i=1
while [ "$i" -le "$N" ]; do
  # rc is not available after wait-all; the winner is the one that printed a token
  if [ -s "$TMP/pout.$i" ]; then
    okc=$((okc + 1))
  fi
  i=$((i + 1))
done
# Also count "lock held" lines. A winner prints a token and no skip line.
held=0
i=1
while [ "$i" -le "$N" ]; do
  if grep -q 'lock held' "$TMP/perr.$i"; then
    held=$((held + 1))
  fi
  i=$((i + 1))
done
if [ "$okc" -eq 1 ] && [ "$held" -eq $((N - 1)) ]; then
  ok "parallel acquire exactly one winner"
else
  bad "parallel acquire winners=$okc held=$held want 1 and $((N - 1))"
fi
# the lock token matches the one stdout
WIN=$(cat "$TMP"/pout.* 2>/dev/null | head -1 | tr -d '\n')
got=$(sed -n '3p' "$(lock_file "$PDIR")")
[ -n "$WIN" ] && [ "$got" = "$WIN" ] && ok "winner token matches the lock" || bad "winner token mismatch"

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
