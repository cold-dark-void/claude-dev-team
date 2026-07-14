#!/usr/bin/env bash
# scheduled-lock-test.sh — unit tests for scheduled-lock.sh (CDV-190)
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

# 1. acquire succeeds
if bash "$LOCK_SH" acquire "$MROOT"; then
  ok "acquire first"
else
  bad "acquire first (rc=$?)"
fi
[ -f "$MROOT/.claude/retro/scheduled.lock" ] && ok "lock file exists" || bad "lock file missing"

# 2. second acquire while fresh → rc 2
bash "$LOCK_SH" acquire "$MROOT" 2>/dev/null
rc=$?
if [ "$rc" -eq 2 ]; then
  ok "second acquire rc=2"
else
  bad "second acquire want rc=2 got $rc"
fi

# 3. release then re-acquire
bash "$LOCK_SH" release "$MROOT"
if bash "$LOCK_SH" acquire "$MROOT"; then
  ok "re-acquire after release"
else
  bad "re-acquire after release"
fi

# 4. stale lock (age > 7200) is stolen
# Write lock with ts far in the past
printf '99999\n1\n' >"$MROOT/.claude/retro/scheduled.lock"
if bash "$LOCK_SH" acquire "$MROOT"; then
  ok "stale lock stolen"
else
  bad "stale lock not stolen (rc=$?)"
fi
# Fresh content should have recent ts
ts=$(sed -n '2p' "$MROOT/.claude/retro/scheduled.lock")
now=$(date +%s)
age=$((now - ts))
if [ "$age" -lt 60 ]; then
  ok "stolen lock has fresh ts"
else
  bad "stolen lock ts stale age=$age"
fi

# 5. release is fail-open (missing lock)
bash "$LOCK_SH" release "$MROOT"
bash "$LOCK_SH" release "$MROOT"
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

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
