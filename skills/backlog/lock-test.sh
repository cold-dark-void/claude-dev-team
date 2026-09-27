#!/usr/bin/env bash
# skills/backlog/lock-test.sh — unit tests for the backlog lock (SPEC-009 C2, T2).
# Run: bash skills/backlog/lock-test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LOCK="$HERE/lock.sh"
# shellcheck source=../../tests/lib/hermetic.sh
. "$HERE/../../tests/lib/hermetic.sh"
hermetic_init
# shellcheck source=../../tests/lib/skip.sh
. "$HERE/../../tests/lib/skip.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s — %s\n' "$1" "$2"; }

assert_eq() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then pass "$name"; else fail "$name" "want='$want' got='$got'"; fi
}

assert_match() {
  local name="$1" text="$2" pat="$3"
  if printf '%s' "$text" | grep -qE "$pat"; then pass "$name"
  else fail "$name" "pattern /$pat/ not in: $text"
  fi
}

WORK="$HERMETIC_ROOT/work"
mkdir -p "$WORK"

# lockdir_of <root> — the lock directory path a given backlog root would use.
lockdir_of() { printf '%s/.claude/backlog.lock' "$1"; }

new_root() {
  local r="$WORK/$1"
  mkdir -p "$r/.claude"
  printf '%s\n' "$r"
}

# plant_stamp <lockdir> <epoch> <owner> — pre-create a held lock directly on
# disk (simulating another holder), without going through backlog_lock_acquire.
plant_stamp() {
  local dir="$1" epoch="$2" owner="$3"
  mkdir -p "$dir"
  printf '%s %s %s\n' "$epoch" "1970-01-01T00:00:00Z" "$owner" > "$dir/stamp"
}

# timed_acquire <root> <wait> <errfile> [path-prefix]
# Runs `backlog_lock_acquire <root>` in a private `bash -c` (so `set -u`,
# `BASH_SOURCE`, traps and PATH stay isolated from this suite), wrapped in
# `timeout 10` so a regression here cannot hang the suite. Sets `rc` (the
# acquire's exit status) and `elapsed` (wall seconds) for the caller to
# assert on — same two names every call site already used before this was
# extracted, so no assertion below had to change. Stderr goes to <errfile>.
# On a successful acquire (rc 0), the just-written stamp is also captured to
# "<errfile>.stamp" BEFORE this bash -c process exits: lock.sh's own EXIT
# trap releases (and removes) the lock the instant this process ends (same
# RAII the caller-facing tests rely on, e.g. "basic release removes dir"),
# so that is the only point at which a held lock's state can still be
# inspected. <path-prefix>, if given, is prepended to PATH inside the
# `bash -c` only (e.g. a shim directory) and never leaks out to the rest of
# the suite.
timed_acquire() {
  local _ta_root="$1" _ta_wait="$2" _ta_errfile="$3" _ta_prefix="${4:-}"
  local _ta_start _ta_end
  _ta_start=$(date +%s)
  timeout 10 bash -c '
    [ -n "$1" ] && PATH="$1:$PATH"
    . "$2"
    BACKLOG_LOCK_WAIT_SECONDS="$3" backlog_lock_acquire "$4"
    _ta_rc=$?
    [ "$_ta_rc" -eq 0 ] && cat "$BACKLOG_LOCK_DIR/stamp" > "$5" 2>/dev/null
    exit "$_ta_rc"
  ' _ "$_ta_prefix" "$LOCK" "$_ta_wait" "$_ta_root" "$_ta_errfile.stamp" 2> "$_ta_errfile"
  rc=$?
  _ta_end=$(date +%s)
  elapsed=$(( _ta_end - _ta_start ))
}

# ============================================================================
# 1. acquire -> dir + stamp; release removes.
# ============================================================================
root=$(new_root basic)
lockdir=$(lockdir_of "$root")
(
  . "$LOCK"
  backlog_lock_acquire "$root" || exit 1
  cat "$BACKLOG_LOCK_DIR/stamp" > "$WORK/basic_stamp.txt"
)
rc=$?
assert_eq "basic acquire rc" "0" "$rc"
if [ -d "$lockdir" ]; then fail "basic release removes dir" "still present"; else pass "basic release removes dir"; fi
assert_match "basic stamp format" "$(cat "$WORK/basic_stamp.txt" 2>/dev/null)" '^[0-9]+ [0-9T:Z-]+ [^ ]+$'

# ============================================================================
# 2. fresh held + BACKLOG_LOCK_WAIT_SECONDS=1 -> rc 1, stderr names the dir,
#    elapsed 1-5s. Also covers "release with a foreign owner in stamp -> dir kept".
# ============================================================================
root=$(new_root fresh_wait)
lockdir=$(lockdir_of "$root")
plant_stamp "$lockdir" "$(date +%s)" "other-owner"
timed_acquire "$root" 1 "$WORK/fresh_wait_err.txt"
assert_eq "fresh-held busy rc" "1" "$rc"
if grep -qF "$lockdir" "$WORK/fresh_wait_err.txt"; then pass "fresh-held busy stderr names lock dir"
else fail "fresh-held busy stderr names lock dir" "$(cat "$WORK/fresh_wait_err.txt")"; fi
if [ "$elapsed" -ge 1 ] && [ "$elapsed" -le 5 ]; then pass "fresh-held busy elapsed 1-5s ($elapsed)"
else fail "fresh-held busy elapsed 1-5s" "elapsed=$elapsed"; fi
if [ -d "$lockdir" ]; then pass "foreign-owner release keeps dir"; else fail "foreign-owner release keeps dir" "removed"; fi
assert_eq "foreign-owner stamp untouched" "other-owner" "$(awk '{print $3}' "$lockdir/stamp" 2>/dev/null)"

# ============================================================================
# 3. stale stamp (now-120, default TTL=60) -> reclaimed, new owner.
# ============================================================================
root=$(new_root stale_120)
lockdir=$(lockdir_of "$root")
plant_stamp "$lockdir" "$(( $(date +%s) - 120 ))" "old-owner"
(
  . "$LOCK"
  backlog_lock_acquire "$root" || exit 1
  cat "$BACKLOG_LOCK_DIR/stamp" > "$WORK/stale_120_stamp.txt"
)
rc=$?
assert_eq "stale-120 reclaim rc" "0" "$rc"
newowner=$(awk '{print $3}' "$WORK/stale_120_stamp.txt" 2>/dev/null)
if [ -n "$newowner" ] && [ "$newowner" != "old-owner" ]; then pass "stale-120 reclaim: new owner"
else fail "stale-120 reclaim: new owner" "got='$newowner'"; fi

# ============================================================================
# 4. BACKLOG_LOCK_TTL_SECONDS=3 + stamp now-5 -> reclaimed.
# ============================================================================
root=$(new_root ttl3)
lockdir=$(lockdir_of "$root")
plant_stamp "$lockdir" "$(( $(date +%s) - 5 ))" "old-owner"
(
  . "$LOCK"
  BACKLOG_LOCK_TTL_SECONDS=3 backlog_lock_acquire "$root" || exit 1
  cat "$BACKLOG_LOCK_DIR/stamp" > "$WORK/ttl3_stamp.txt"
)
rc=$?
assert_eq "custom TTL reclaim rc" "0" "$rc"
newowner=$(awk '{print $3}' "$WORK/ttl3_stamp.txt" 2>/dev/null)
if [ -n "$newowner" ] && [ "$newowner" != "old-owner" ]; then pass "custom TTL reclaim: new owner"
else fail "custom TTL reclaim: new owner" "got='$newowner'"; fi

# ============================================================================
# 5. empty dir (no stamp) and garbage stamp -> reclaimed after the 1s grace.
# ============================================================================
root=$(new_root empty_dir)
lockdir=$(lockdir_of "$root")
mkdir -p "$lockdir"
timed_acquire "$root" 30 "$WORK/empty_dir_err.txt"
assert_eq "empty-dir reclaim rc" "0" "$rc"
if [ "$elapsed" -ge 1 ] && [ "$elapsed" -le 10 ]; then pass "empty-dir reclaim waited for the grace ($elapsed s)"
else fail "empty-dir reclaim waited for the grace" "elapsed=$elapsed"; fi

root=$(new_root garbage_stamp)
lockdir=$(lockdir_of "$root")
mkdir -p "$lockdir"
printf 'garbage\n' > "$lockdir/stamp"
timed_acquire "$root" 30 "$WORK/garbage_stamp_err.txt"
assert_eq "garbage-stamp reclaim rc" "0" "$rc"
if [ "$elapsed" -ge 1 ] && [ "$elapsed" -le 10 ]; then pass "garbage-stamp reclaim waited for the grace ($elapsed s)"
else fail "garbage-stamp reclaim waited for the grace" "elapsed=$elapsed"; fi

# ============================================================================
# 6. exit code passthrough: explicit `exit 3` after acquire survives the
#    EXIT-trap release; no dir left.
# ============================================================================
root=$(new_root exit3)
lockdir=$(lockdir_of "$root")
marker="$WORK/exit3_marker.txt"
rm -f "$marker"
bash -c '
  . "$1"
  backlog_lock_acquire "$2" || { printf "ACQUIRE_FAILED\n" > "$3"; exit 1; }
  printf "ACQUIRED\n" > "$3"
  exit 3
' _ "$LOCK" "$root" "$marker"
rc=$?
assert_eq "exit-passthrough rc" "3" "$rc"
assert_eq "exit-passthrough: acquire actually succeeded" "ACQUIRED" "$(cat "$marker" 2>/dev/null)"
if [ -d "$lockdir" ]; then fail "exit-passthrough: no dir left" "present"; else pass "exit-passthrough: no dir left"; fi

# ============================================================================
# 7. SIGINT -> 130, SIGTERM -> 143, both release and leave no dir.
# ============================================================================
root=$(new_root sigint)
lockdir=$(lockdir_of "$root")
marker="$WORK/sigint_marker.txt"
rm -f "$marker"
bash -c '
  . "$1"
  backlog_lock_acquire "$2" || { printf "ACQUIRE_FAILED\n" > "$3"; exit 1; }
  printf "OK\n" > "$3"
  kill -INT $$
  printf "UNREACHABLE\n" >> "$3"
' _ "$LOCK" "$root" "$marker"
rc=$?
assert_eq "SIGINT rc" "130" "$rc"
assert_eq "SIGINT: marker shows trap ran, no unreachable code" "OK" "$(cat "$marker" 2>/dev/null)"
if [ -d "$lockdir" ]; then fail "SIGINT: no dir left" "present"; else pass "SIGINT: no dir left"; fi

root=$(new_root sigterm)
lockdir=$(lockdir_of "$root")
marker="$WORK/sigterm_marker.txt"
rm -f "$marker"
bash -c '
  . "$1"
  backlog_lock_acquire "$2" || { printf "ACQUIRE_FAILED\n" > "$3"; exit 1; }
  printf "OK\n" > "$3"
  kill -TERM $$
  printf "UNREACHABLE\n" >> "$3"
' _ "$LOCK" "$root" "$marker"
rc=$?
assert_eq "SIGTERM rc" "143" "$rc"
assert_eq "SIGTERM: marker shows trap ran, no unreachable code" "OK" "$(cat "$marker" 2>/dev/null)"
if [ -d "$lockdir" ]; then fail "SIGTERM: no dir left" "present"; else pass "SIGTERM: no dir left"; fi

# ============================================================================
# 8. bad env -> 64, no dir created.
# ============================================================================
root=$(new_root badenv_wait)
lockdir=$(lockdir_of "$root")
(
  . "$LOCK"
  BACKLOG_LOCK_WAIT_SECONDS=abc backlog_lock_acquire "$root"
)
rc=$?
assert_eq "bad WAIT rc" "64" "$rc"
if [ -d "$lockdir" ]; then fail "bad WAIT: no dir created" "present"; else pass "bad WAIT: no dir created"; fi

root=$(new_root badenv_ttl)
lockdir=$(lockdir_of "$root")
(
  . "$LOCK"
  BACKLOG_LOCK_TTL_SECONDS=0 backlog_lock_acquire "$root"
)
rc=$?
assert_eq "bad TTL=0 rc" "64" "$rc"
if [ -d "$lockdir" ]; then fail "bad TTL=0: no dir created" "present"; else pass "bad TTL=0: no dir created"; fi

# ============================================================================
# 9. waiter: hold fresh, background acquire WAIT=10 writes a marker only once
#    the held lock goes away.
# ============================================================================
root=$(new_root waiter)
lockdir=$(lockdir_of "$root")
plant_stamp "$lockdir" "$(date +%s)" "holder"

marker="$WORK/waiter_marker.txt"
rcfile="$WORK/waiter_rc.txt"
rm -f "$marker" "$rcfile"

bash -c '
  . "$1"
  BACKLOG_LOCK_WAIT_SECONDS=10 backlog_lock_acquire "$2"
  rc=$?
  printf "%s\n" "$rc" > "$3"
  [ "$rc" -eq 0 ] && printf "done\n" > "$4"
' _ "$LOCK" "$root" "$rcfile" "$marker" &
bgpid=$!

sleep 1
if [ -f "$marker" ]; then fail "waiter: marker absent while held" "present"; else pass "waiter: marker absent while held"; fi

rm -rf "$lockdir"
wait "$bgpid"

if [ -f "$marker" ]; then pass "waiter: marker present after release"; else fail "waiter: marker present after release" "absent"; fi
assert_eq "waiter: acquire rc after release" "0" "$(cat "$rcfile" 2>/dev/null)"

# ============================================================================
# 10. static: no `kill -0` in lock.sh (+ negative control).
# ============================================================================
if grep -q 'kill -0' "$LOCK"; then fail "static: no kill -0 in lock.sh" "found"; else pass "static: no kill -0 in lock.sh"; fi

NEG="$WORK/neg-kill0.sh"
printf 'kill -0 "$$"\n' > "$NEG"
if grep -q 'kill -0' "$NEG"; then pass "static negative control: kill -0 detected"
else fail "static negative control: kill -0 detected" "not found"; fi


# ============================================================================
# 11. AC D regression (T2 rework, tech-lead REQUEST CHANGES): the acquire
#    loop must hit the BACKLOG_LOCK_WAIT_SECONDS deadline even when the lock
#    can never be reclaimed (a read-only ancestor). Pre-fix this hung
#    (mkdir fails, stamp missing -> sleep 1 -> stale -> mv fails silently ->
#    `continue` skips the deadline check forever; or, with an existing stale
#    stamp, mv fails with NO sleep at all -> tight-loop forever). Every case
#    is wrapped in `timeout 10` so a regression here cannot hang the suite,
#    and chmod is always restored so hermetic cleanup can remove $WORK.
# ============================================================================

# 11a. No lock dir yet; its parent (.claude) is unwritable, so mkdir can
#      never succeed. Must fail at once with a clear error, not wait at all.
if ( skip_if_root "AC D: unwritable .claude blocks mkdir (11a)" ); then
  root=$(new_root acd_nomkdir)
  lockdir=$(lockdir_of "$root")
  chmod 555 "$root/.claude"
  errfile="$WORK/acd_nomkdir_err.txt"
  timed_acquire "$root" 1 "$errfile"
  chmod 755 "$root/.claude"
  assert_eq "11a unwritable-.claude rc" "1" "$rc"
  if [ "$elapsed" -le 5 ]; then pass "11a unwritable-.claude elapsed <=5s ($elapsed)"
  else fail "11a unwritable-.claude elapsed <=5s" "elapsed=$elapsed"; fi
  assert_match "11a unwritable-.claude stderr names the lock dir" "$(cat "$errfile" 2>/dev/null)" "cannot create backlog lock: $lockdir"
  if [ -d "$lockdir" ]; then fail "11a unwritable-.claude: no dir created" "present"; else pass "11a unwritable-.claude: no dir created"; fi
fi

# 11b. A stale (age-expired) stamp already sits in the lock dir, but its
#      parent (.claude) is unwritable, so the reclaim `mv` can never succeed
#      either. Must still return 1 once BACKLOG_LOCK_WAIT_SECONDS elapses,
#      not spin forever with no sleep.
if ( skip_if_root "AC D: unwritable parent blocks stale-lock reclaim (11b)" ); then
  root=$(new_root acd_nomv)
  lockdir=$(lockdir_of "$root")
  plant_stamp "$lockdir" "$(( $(date +%s) - 120 ))" "old-owner"
  chmod 555 "$root/.claude"
  errfile="$WORK/acd_nomv_err.txt"
  timed_acquire "$root" 1 "$errfile"
  chmod 755 "$root/.claude"
  assert_eq "11b unwritable-parent-reclaim rc" "1" "$rc"
  if [ "$elapsed" -le 5 ]; then pass "11b unwritable-parent-reclaim elapsed <=5s ($elapsed)"
  else fail "11b unwritable-parent-reclaim elapsed <=5s" "elapsed=$elapsed"; fi
  assert_match "11b unwritable-parent-reclaim stderr: busy message" "$(cat "$errfile" 2>/dev/null)" "backlog lock busy: $lockdir"
  assert_eq "11b unwritable-parent-reclaim: stamp untouched (never reclaimed)" "old-owner" "$(awk '{print $3}' "$lockdir/stamp" 2>/dev/null)"
fi

# ============================================================================
# 11c. B1 regression (T2 rework round 2, tech-lead REQUEST CHANGES): a bare
#    mkdir failure must NOT be treated as unrecoverable just because the lock
#    dir doesn't exist at that instant. Real sequence: the waiter's mkdir
#    fails with EEXIST because the lock dir exists; before the waiter's
#    `[ ! -d ]` check runs, the holder's EXIT trap `rm -rf`s it (or a
#    stale-lock reclaim/hand-back `mv`s it away) — so the dir is gone by the
#    time the waiter looks, and the pre-fix code wrongly bailed out with
#    "cannot create". A `mkdir` shim simulates this deterministically: its
#    first call fails without creating anything (the raced EEXIST-then-gone
#    window); every later call runs the real mkdir. Must return 0 with a
#    freshly-owned lock instead.
# ============================================================================
REAL_MKDIR=$(command -v mkdir)
SHIM_MKDIR="$WORK/shim-mkdir-11c"
mkdir -p "$SHIM_MKDIR"
STATE_11C="$WORK/mkdir_11c_state"
rm -f "$STATE_11C"
cat > "$SHIM_MKDIR/mkdir" << EOF
#!/usr/bin/env bash
if [ ! -e "$STATE_11C" ]; then
  : > "$STATE_11C"
  exit 1
fi
exec "$REAL_MKDIR" "\$@"
EOF
chmod +x "$SHIM_MKDIR/mkdir"

root=$(new_root acd_mkdir_race)
lockdir=$(lockdir_of "$root")
errfile="$WORK/acd_mkdir_race_err.txt"
timed_acquire "$root" 2 "$errfile" "$SHIM_MKDIR"
assert_eq "11c mkdir-EEXIST-then-gone rc" "0" "$rc"
# The acquiring process's own EXIT trap releases (rm -rf) the lock the
# instant it exits, same RAII as every other successful-acquire test in this
# suite (see "basic release removes dir") — so the only point at which the
# held lock's state is inspectable is the stamp `timed_acquire` captured
# from inside that process, before its own exit. A non-empty, non-old-owner
# stamp there is proof the second (real) mkdir created the dir and wrote a
# fresh stamp — i.e. the lock genuinely existed and was ours.
owner=$(awk '{print $3}' "$errfile.stamp" 2>/dev/null)
if [ -n "$owner" ] && [ "$owner" != "old-owner" ]; then pass "11c mkdir-EEXIST-then-gone: lock existed with a fresh stamp (owner neither old-owner nor empty)"
else fail "11c mkdir-EEXIST-then-gone: lock existed with a fresh stamp (owner neither old-owner nor empty)" "got='$owner'"; fi
if [ -d "$lockdir" ]; then fail "11c mkdir-EEXIST-then-gone: lock released on process exit" "still present"
else pass "11c mkdir-EEXIST-then-gone: lock released on process exit"; fi

# ============================================================================
# 12. Reclaim race (T2 rework, non-blocking): a stale lock's move-aside can
#    land on a copy that went fresh between our stale read and the `mv`
#    (another acquirer's own reclaim-and-remkdir got there first). A `mv`
#    shim on PATH simulates this deterministically: it performs the real
#    rename lock.sh asked for, then rewrites the moved-aside copy's stamp to
#    a fresh epoch — exactly what lock.sh would see if a racer's fresh
#    stamp had been renamed instead of the stale one it read. lock.sh must
#    hand that copy back rather than destroying a live lock.
# ============================================================================
root=$(new_root race)
lockdir=$(lockdir_of "$root")
plant_stamp "$lockdir" "$(( $(date +%s) - 120 ))" "old-owner"

SHIM_RACE="$WORK/shim-race"
mkdir -p "$SHIM_RACE"
cat > "$SHIM_RACE/mv" << 'EOS'
#!/usr/bin/env bash
REAL_MV=$(command -v /bin/mv || command -v /usr/bin/mv)
"$REAL_MV" "$@"
rc=$?
if [ "$rc" -eq 0 ] && [ "$#" -eq 2 ]; then
  case "$2" in
    *.stale.*)
      if [ -f "$2/stamp" ]; then
        owner=$(awk '{print $3}' "$2/stamp")
        printf '%s %s %s\n' "$(date +%s)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$owner" > "$2/stamp"
      fi
      ;;
  esac
fi
exit "$rc"
EOS
chmod +x "$SHIM_RACE/mv"

errfile="$WORK/race_err.txt"
timed_acquire "$root" 2 "$errfile" "$SHIM_RACE"
assert_eq "12 reclaim-race rc" "1" "$rc"
if [ "$elapsed" -ge 2 ] && [ "$elapsed" -le 8 ]; then pass "12 reclaim-race elapsed 2-8s ($elapsed)"
else fail "12 reclaim-race elapsed 2-8s" "elapsed=$elapsed"; fi
assert_match "12 reclaim-race stderr: busy message" "$(cat "$errfile" 2>/dev/null)" "backlog lock busy: $lockdir"
if [ -d "$lockdir" ]; then pass "12 reclaim-race: lock handed back, not destroyed"
else fail "12 reclaim-race: lock handed back, not destroyed" "removed"; fi
assert_eq "12 reclaim-race: stamp owner preserved" "old-owner" "$(awk '{print $3}' "$lockdir/stamp" 2>/dev/null)"
if ls -d "$lockdir".stale.* >/dev/null 2>&1; then fail "12 reclaim-race: no leftover .stale. dir" "found"; else pass "12 reclaim-race: no leftover .stale. dir"; fi

# ============================================================================
# 13. Stamp-write check (10b gap 7 / SPEC-009 "MUST check that the stamp
#    write succeeds. When it fails, the holder MUST remove the lock directory
#    and exit 1."): a `mkdir` shim performs the real mkdir (so it lands
#    normally under a writable .claude) then chmods the freshly-created lock
#    dir itself to 0555 (read+exec, no write) so the subsequent stamp write
#    (a plain `>` redirection into that dir) fails with EACCES. Pre-fix, the
#    unchecked `printf ... > stamp` failure was silently ignored and
#    backlog_lock_acquire still returned 0 as if it held a real lock, leaving
#    a stamp-less, unwritable lock dir behind. Must now return 1, name the
#    lock dir, and leave no lock dir at all (removal only needs write on the
#    parent .claude, which this shim never touches, so the rm always
#    succeeds).
# ============================================================================
SHIM_STAMP="$WORK/shim-stampfail"
mkdir -p "$SHIM_STAMP"
cat > "$SHIM_STAMP/mkdir" << 'EOS'
#!/usr/bin/env bash
REAL_MKDIR=$(command -v /bin/mkdir || command -v /usr/bin/mkdir)
"$REAL_MKDIR" "$@"
rc=$?
if [ "$rc" -eq 0 ] && [ "$#" -ge 1 ]; then
  last="${@: -1}"
  chmod 0555 "$last" 2>/dev/null || true
fi
exit "$rc"
EOS
chmod +x "$SHIM_STAMP/mkdir"

root=$(new_root stampfail)
lockdir=$(lockdir_of "$root")
errfile="$WORK/stampfail_err.txt"
timed_acquire "$root" 5 "$errfile" "$SHIM_STAMP"
assert_eq "13 stamp-write-failure rc" "1" "$rc"
assert_match "13 stamp-write-failure stderr names the lock dir" "$(cat "$errfile" 2>/dev/null)" "cannot write lock stamp: $lockdir"
if [ "$elapsed" -le 5 ]; then pass "13 stamp-write-failure elapsed <=5s ($elapsed)"
else fail "13 stamp-write-failure elapsed <=5s" "elapsed=$elapsed"; fi
if [ -d "$lockdir" ]; then fail "13 stamp-write-failure: no lock dir left" "present"
else pass "13 stamp-write-failure: no lock dir left"; fi
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
