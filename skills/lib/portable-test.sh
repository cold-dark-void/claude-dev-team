#!/usr/bin/env bash
# skills/lib/portable-test.sh — unit tests for atomic_write (SPEC-009 C1, T1).
# Run: bash skills/lib/portable-test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LIB="$HERE/portable.sh"
# shellcheck source=../../tests/lib/hermetic.sh
. "$HERE/../../tests/lib/hermetic.sh"
hermetic_init
umask 022
# shellcheck source=portable.sh
. "$LIB"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s — %s\n' "$1" "$2"; }

assert_eq() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then pass "$name"; else fail "$name" "want='$want' got='$got'"; fi
}

file_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
}

no_leftover_temp() {
  local dir="$1" hit
  hit=$(find "$dir" -maxdepth 1 -name '.*.tmp.*' 2>/dev/null)
  [ -z "$hit" ]
}

WORK="$HERMETIC_ROOT/work"
mkdir -p "$WORK"

# --- new dest: mode = 0666 & ~umask (umask 022 -> 644) ----------------------
d="$WORK/new1"; mkdir -p "$d"
dest="$d/out.txt"
atomic_write "$dest" printf '%s' "hello"
rc=$?
assert_eq "new dest rc" "0" "$rc"
assert_eq "new dest content" "hello" "$(cat "$dest" 2>/dev/null)"
assert_eq "new dest mode (umask 022)" "644" "$(file_mode "$dest")"
no_leftover_temp "$d" && pass "new dest: no leftover temp" || fail "new dest: no leftover temp" "found"

# --- existing dest: mode kept (0644 / 0664 / 0600) --------------------------
for m in 644 664 600; do
  d="$WORK/existing_$m"; mkdir -p "$d"
  dest="$d/out.txt"
  printf 'old' > "$dest"
  chmod "$m" "$dest"
  atomic_write "$dest" printf 'new-%s' "$m"
  rc=$?
  assert_eq "existing dest ($m) rc" "0" "$rc"
  assert_eq "existing dest ($m) mode kept" "$m" "$(file_mode "$dest")"
  assert_eq "existing dest ($m) content updated" "new-$m" "$(cat "$dest" 2>/dev/null)"
  no_leftover_temp "$d" && pass "existing dest ($m): no leftover temp" || fail "existing dest ($m): no leftover temp" "found"
done

# --- temp file visible in dest dir during producer run; name never .md -----
d="$WORK/tmpname"; mkdir -p "$d"
dest="$d/notes.md"
: > "$dest"
atomic_write "$dest" sh -c 'ls -a "$1"' _ "$d"
rc=$?
assert_eq "tmpname producer rc" "0" "$rc"
content=$(cat "$dest" 2>/dev/null)
tmpname=$(printf '%s\n' "$content" | grep -oE '\.notes\.md\.tmp\.[A-Za-z0-9]+' | head -n1)
if [ -n "$tmpname" ]; then pass "temp file visible in dest dir during producer run"
else fail "temp file visible in dest dir during producer run" "not found in: $content"
fi
case "$tmpname" in
  *.md) fail "temp name must not end .md" "$tmpname" ;;
  *) pass "temp name does not end .md" ;;
esac
no_leftover_temp "$d" && pass "tmpname: no leftover temp" || fail "tmpname: no leftover temp" "found"

# --- producer false: rc propagated, dest untouched, no temp ----------------
d="$WORK/fail_false"; mkdir -p "$d"
dest="$d/out.txt"
printf 'orig' > "$dest"
cp "$dest" "$d/orig.snapshot"
atomic_write "$dest" false
rc=$?
assert_eq "false producer rc" "1" "$rc"
cmp -s "$dest" "$d/orig.snapshot" && pass "false producer: dest unchanged" || fail "false producer: dest unchanged" "changed"
no_leftover_temp "$d" && pass "false producer: no leftover temp" || fail "false producer: no leftover temp" "found"

# --- partial-output producer exiting 3: rc 3, dest untouched, no temp ------
d="$WORK/fail_partial"; mkdir -p "$d"
dest="$d/out.txt"
printf 'orig' > "$dest"
cp "$dest" "$d/orig.snapshot"
atomic_write "$dest" sh -c 'printf partial; exit 3'
rc=$?
assert_eq "partial producer rc" "3" "$rc"
cmp -s "$dest" "$d/orig.snapshot" && pass "partial producer: dest unchanged" || fail "partial producer: dest unchanged" "changed"
no_leftover_temp "$d" && pass "partial producer: no leftover temp" || fail "partial producer: no leftover temp" "found"

# --- BSD stat shim (-c fails, -f %Lp answers): mode kept via fallback ------
SHIM_BSD="$WORK/shim-bsd"
mkdir -p "$SHIM_BSD"
cat > "$SHIM_BSD/stat" << 'EOS'
#!/usr/bin/env bash
if [ "$1" = "-c" ]; then exit 1; fi
if [ "$1" = "-f" ] && [ "$2" = "%Lp" ]; then echo "640"; exit 0; fi
exit 1
EOS
chmod +x "$SHIM_BSD/stat"

d="$WORK/bsdshim"; mkdir -p "$d"
dest="$d/out.txt"
printf 'orig' > "$dest"
chmod 600 "$dest"
OLDPATH="$PATH"
PATH="$SHIM_BSD:$PATH"
atomic_write "$dest" printf '%s' "new"
rc=$?
PATH="$OLDPATH"
assert_eq "bsd shim rc" "0" "$rc"
assert_eq "bsd shim mode applied via -f %Lp" "640" "$(file_mode "$dest")"
no_leftover_temp "$d" && pass "bsd shim: no leftover temp" || fail "bsd shim: no leftover temp" "found"

# --- stat shim printing junk: rc 1, no change, no temp ----------------------
SHIM_JUNK="$WORK/shim-junk"
mkdir -p "$SHIM_JUNK"
cat > "$SHIM_JUNK/stat" << 'EOS'
#!/usr/bin/env bash
echo "not-a-mode"
exit 0
EOS
chmod +x "$SHIM_JUNK/stat"

d="$WORK/junkshim"; mkdir -p "$d"
dest="$d/out.txt"
printf 'orig' > "$dest"
cp "$dest" "$d/orig.snapshot"
OLDPATH="$PATH"
PATH="$SHIM_JUNK:$PATH"
atomic_write "$dest" printf '%s' "new"
rc=$?
PATH="$OLDPATH"
assert_eq "junk stat rc" "1" "$rc"
cmp -s "$dest" "$d/orig.snapshot" && pass "junk stat: dest unchanged" || fail "junk stat: dest unchanged" "changed"
no_leftover_temp "$d" && pass "junk stat: no leftover temp" || fail "junk stat: no leftover temp" "found"

# --- stat shim failing BOTH forms under caller set -e: rc 1, no leftover ---
# temp (regression: an unguarded `_aw_mode=$(stat ... || stat ...)` trips
# errexit in the caller's shell when both forms fail, skipping the `rm -f
# "$_aw_tmp"` cleanup and leaving the temp file behind).
SHIM_BOTHFAIL="$WORK/shim-bothfail"
mkdir -p "$SHIM_BOTHFAIL"
cat > "$SHIM_BOTHFAIL/stat" << 'EOS'
#!/usr/bin/env bash
exit 1
EOS
chmod +x "$SHIM_BOTHFAIL/stat"

d="$WORK/bothfail_errexit"; mkdir -p "$d"
dest="$d/out.txt"
printf 'orig' > "$dest"
cp "$dest" "$d/orig.snapshot"
OLDPATH="$PATH"
PATH="$SHIM_BOTHFAIL:$PATH"
( set -e; atomic_write "$dest" printf '%s' "new" )
rc=$?
PATH="$OLDPATH"
assert_eq "both-stat-fail under set -e: rc" "1" "$rc"
cmp -s "$dest" "$d/orig.snapshot" && pass "both-stat-fail under set -e: dest unchanged" || fail "both-stat-fail under set -e: dest unchanged" "changed"
no_leftover_temp "$d" && pass "both-stat-fail under set -e: no leftover temp" || fail "both-stat-fail under set -e: no leftover temp" "found"

# --- symlink dest: rc 1, no change ------------------------------------------
d="$WORK/symlink"; mkdir -p "$d"
target="$d/target.txt"
printf 'x' > "$target"
link="$d/link.txt"
ln -s "$target" "$link"
atomic_write "$link" printf '%s' "new"
rc=$?
assert_eq "symlink dest rc" "1" "$rc"
assert_eq "symlink dest: target unchanged" "x" "$(cat "$target" 2>/dev/null)"
no_leftover_temp "$d" && pass "symlink dest: no leftover temp" || fail "symlink dest: no leftover temp" "found"

# --- missing parent dir: rc 1 ------------------------------------------------
dest="$WORK/no-such-dir/sub/out.txt"
atomic_write "$dest" printf '%s' "new"
rc=$?
assert_eq "missing parent rc" "1" "$rc"
if [ -e "$dest" ]; then fail "missing parent: dest absent" "exists"; else pass "missing parent: dest absent"; fi

# --- errexit-safe: (set -e; atomic_write "$d" false) leaves no temp --------
d="$WORK/errexit"; mkdir -p "$d"
dest="$d/out.txt"
( set -e; atomic_write "$dest" false )
no_leftover_temp "$d" && pass "errexit safe: no leftover temp" || fail "errexit safe: no leftover temp" "found"

# --- subprocess form works ---------------------------------------------------
d="$WORK/subproc"; mkdir -p "$d"
dest="$d/out.txt"
bash "$LIB" atomic_write "$dest" printf '%s' "viaSubprocess"
rc=$?
assert_eq "subprocess form rc" "0" "$rc"
assert_eq "subprocess form content" "viaSubprocess" "$(cat "$dest" 2>/dev/null)"

# --- subprocess bad argv -> usage on stderr, exit 64 ------------------------
bash "$LIB" badcmd >"$WORK/subproc_bad_out.txt" 2>"$WORK/subproc_bad_err.txt"
rc=$?
assert_eq "subprocess bad argv rc" "64" "$rc"
[ -s "$WORK/subproc_bad_err.txt" ] && pass "subprocess bad argv: usage on stderr" || fail "subprocess bad argv: usage on stderr" "empty"

bash "$LIB" atomic_write "$dest" >"$WORK/subproc_short_out.txt" 2>"$WORK/subproc_short_err.txt"
rc=$?
assert_eq "subprocess missing producer rc" "64" "$rc"
[ -s "$WORK/subproc_short_err.txt" ] && pass "subprocess missing producer: usage on stderr" || fail "subprocess missing producer: usage on stderr" "empty"

# --- static: the portable.sh function inventory is exactly known -------------
# CDT-284 added sha256/lock/with_timeout; any new function must be added here
# so the sourced surface cannot drift silently.
FUNC_RE='^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{'
EXPECTED_FUNCS="atomic_write portable_sha256 _portable_lock_stamp_field _portable_lock_pid_alive portable_lock_acquire portable_lock_release portable_with_timeout"
for f in $EXPECTED_FUNCS; do
  if grep -qE "^${f}\(\)[[:space:]]*\{" "$LIB"; then
    pass "static: $f defined"
  else
    fail "static: $f defined" "missing from $LIB"
  fi
done
func_count=$(grep -cE "$FUNC_RE" "$LIB")
assert_eq "static: no extra functions beyond the inventory" "$(printf '%s\n' $EXPECTED_FUNCS | wc -l | tr -d ' ')" "$func_count"

# Negative control: the same check must fire on a planted two-function file.
FIXTURE_TWO_FUNCS="$WORK/two-funcs.sh"
cat > "$FIXTURE_TWO_FUNCS" << 'EOS'
foo() { :; }
bar() { :; }
EOS
neg_count=$(grep -cE "$FUNC_RE" "$FIXTURE_TWO_FUNCS")
assert_eq "static negative control: two funcs detected" "2" "$neg_count"

# Writers that used a predictable .tmp.$$ name now call atomic_write.
# A planted line must still match, so the pattern is not vacuous.
ROOT=$(cd "$HERE/../.." && pwd)
for rel in \
  skills/model-map/write-model.sh \
  skills/retro-gate/scheduled-lock.sh \
  skills/retro-gate/write-scheduled-report.sh \
  skills/epic/epic-lib.sh \
  skills/orchestrate/task-store.sh \
  skills/ci-watch/sidecar.sh \
  skills/ci-watch/poll.sh \
  skills/security-scan/scan.sh \
  tools/permission-matrix-probe.sh
do
  if grep -n '\.tmp\.\$\$' "$ROOT/$rel" >/dev/null; then
    fail "no predictable .tmp.\$\$ in $rel" "still present"
  else
    pass "no predictable .tmp.\$\$ in $rel"
  fi
  if grep -q 'atomic_write\|mktemp' "$ROOT/$rel"; then
    pass "$rel publishes through atomic_write or mktemp"
  else
    fail "$rel publishes through atomic_write or mktemp" "neither helper"
  fi
done
PLANT="$WORK/plant-tmp.sh"
printf '%s\n' 'tmp="${LOCK}.tmp.$$"' > "$PLANT"
if grep -n '\.tmp\.\$\$' "$PLANT" >/dev/null; then
  pass "control: the .tmp.\$\$ pattern matches a planted line"
else
  fail "control: the .tmp.\$\$ pattern matches a planted line" "no match"
fi

# ===========================================================================
# CDT-284: sha256, lock (no flock), with_timeout.
# ===========================================================================

# --- sha256: known vectors, stdin and file ---------------------------------
GOT=$(printf 'abc' | portable_sha256)
assert_eq "sha256 stdin 'abc'" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" "$GOT"
GOT=$(printf '' | portable_sha256)
assert_eq "sha256 stdin empty" "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" "$GOT"
printf 'abc' > "$WORK/abc.txt"
GOT=$(portable_sha256 "$WORK/abc.txt")
assert_eq "sha256 file 'abc'" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" "$GOT"
GOT=$(portable_sha256 "$WORK/abc.txt" "$WORK/abc.txt" | wc -l | tr -d ' ')
assert_eq "sha256 one digest per file arg" "2" "$GOT"
GOT=$(bash "$LIB" sha256 "$WORK/abc.txt")
assert_eq "sha256 subprocess form" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" "$GOT"

# --- sha256: tool-fallback paths under a constrained PATH -------------------
# The BSD lane has shasum but no sha256sum; the GNU lane the reverse; a host
# with neither must fail loudly (rc 127), never print a wrong digest.
mk_fakebin() { # mk_fakebin <dir> <tool>...
  local d="$1"; shift
  mkdir -p "$d"
  local t
  for t in "$@"; do
    p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$d/$t"
  done
}
if command -v shasum >/dev/null 2>&1; then
  mk_fakebin "$WORK/bin-shasum" bash awk shasum
  GOT=$(PATH="$WORK/bin-shasum" bash -c '. "$1"; printf "abc" | portable_sha256' _ "$LIB" 2>/dev/null)
  assert_eq "sha256 shasum-only PATH (BSD lane)" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" "$GOT"
else
  pass "sha256 shasum-only PATH (BSD lane) — skipped: no shasum on host"
fi
mk_fakebin "$WORK/bin-sha256sum" bash awk sha256sum
GOT=$(PATH="$WORK/bin-sha256sum" bash -c '. "$1"; printf "abc" | portable_sha256' _ "$LIB" 2>/dev/null)
assert_eq "sha256 sha256sum-only PATH (GNU lane)" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" "$GOT"
mk_fakebin "$WORK/bin-none" bash awk
GOT=$(PATH="$WORK/bin-none" bash -c '. "$1"; portable_sha256 "$2"' _ "$LIB" "$WORK/abc.txt" 2>"$WORK/none.err"); RC=$?
assert_eq "sha256 neither tool rc" "127" "$RC"
grep -q 'no sha256 tool' "$WORK/none.err" && pass "sha256 neither tool names the problem on stderr" || fail "sha256 neither tool names the problem on stderr" "$(cat "$WORK/none.err")"

# --- lock: acquire, stamp, release -------------------------------------------
# The holder is a background subshell: its EXIT trap releases the lock, which
# is itself part of the assertion. A subshell keeps $$, so the stamp pid is
# this test's pid.
L="$WORK/lock-basic"
( portable_lock_acquire "$L" 30 600; sleep 4 ) &
HOLDER=$!
sleep 1
[ -d "$L" ] && pass "lock dir created" || fail "lock dir created" "missing"
[ "$(cat "$L/stamp" 2>/dev/null | awk '{print $1}')" = "$$" ] && pass "lock stamp records the holder pid" || fail "lock stamp records the holder pid" "$(cat "$L/stamp" 2>/dev/null)"
stamp_epoch=$(cat "$L/stamp" 2>/dev/null | awk '{print $2}')
case "$stamp_epoch" in
  ''|*[!0-9]*) fail "lock stamp records an epoch" "$stamp_epoch" ;;
  *) pass "lock stamp records an epoch" ;;
esac
wait "$HOLDER"
[ ! -e "$L" ] && pass "holder exit released the lock" || fail "holder exit released the lock" "still there"

# --- lock: second acquirer is busy while the holder is alive ----------------
L="$WORK/lock-busy"
( portable_lock_acquire "$L" 30 600; sleep 4 ) &
HOLDER=$!
sleep 1
GOT=$(timeout 30 bash -c '. "$1"; portable_lock_acquire "$2" 2 600' _ "$LIB" "$L" >/dev/null 2>&1; echo $?)
assert_eq "lock busy rc (holder alive, fresh stamp)" "1" "$GOT"
# stamp pid is $$ of the holder subshell == this test's pid (subshells keep $$):
# prove the liveness check did NOT steal a fresh, alive lock.
[ -d "$L" ] && pass "fresh alive lock not stolen" || fail "fresh alive lock not stolen" "stolen"
wait "$HOLDER"
[ ! -e "$L" ] && pass "holder exit released the lock" || fail "holder exit released the lock" "still there"
# after release the same lock is acquirable again
GOT=$(timeout 30 bash -c '. "$1"; portable_lock_acquire "$2" 2 600 && portable_lock_release' _ "$LIB" "$L" >/dev/null 2>&1; echo $?); RC=$GOT
assert_eq "lock re-acquirable after release" "0" "$GOT"

# --- lock: dead-pid stamp is stolen ------------------------------------------
L="$WORK/lock-deadpid"
sh -c 'exec sleep 30' & DEADPID=$!
kill -9 "$DEADPID" 2>/dev/null
wait "$DEADPID" 2>/dev/null
mkdir -p "$L"
printf '%s %s %s\n' "$DEADPID" "$(date +%s)" "other-owner" > "$L/stamp"
GOT=$(timeout 30 bash -c '. "$1"; portable_lock_acquire "$2" 5 600' _ "$LIB" "$L" >/dev/null 2>&1; echo $?); RC=$GOT
assert_eq "dead-pid lock is stolen" "0" "$GOT"
timeout 30 bash -c '. "$1"; portable_lock_release' _ "$LIB" >/dev/null 2>&1

# --- lock: stale-TTL stamp is stolen even with a live pid ---------------------
L="$WORK/lock-stale"
mkdir -p "$L"
printf '%s %s %s\n' "$$" "$(( $(date +%s) - 10 ))" "other-owner" > "$L/stamp"
GOT=$(timeout 30 bash -c '. "$1"; portable_lock_acquire "$2" 5 5' _ "$LIB" "$L" >/dev/null 2>&1; echo $?); RC=$GOT
assert_eq "stale-TTL lock is stolen (live pid, old stamp)" "0" "$GOT"
timeout 30 bash -c '. "$1"; portable_lock_release' _ "$LIB" >/dev/null 2>&1

# --- lock: release never removes a foreign-owned lock -------------------------
L="$WORK/lock-foreign"
mkdir -p "$L"
printf '%s %s %s\n' "$$" "$(date +%s)" "someone-else" > "$L/stamp"
timeout 30 bash -c '. "$1"; PORTABLE_LOCK_DIR="$2"; portable_lock_release' _ "$LIB" "$L" >/dev/null 2>&1
[ -d "$L" ] && pass "foreign-owned lock not removed on release" || fail "foreign-owned lock not removed on release" "removed"
rm -rf "$L"

# --- lock: no subprocess form --------------------------------------------------
bash "$LIB" lock >"$WORK/lock-sub.out" 2>"$WORK/lock-sub.err"; RC=$?
assert_eq "lock subprocess form rc" "64" "$RC"
grep -q 'source-only' "$WORK/lock-sub.err" && pass "lock subprocess form explains source-only" || fail "lock subprocess form explains source-only" "no message"

# --- lock: a flock-era .lock FILE at the lock path is unlinked (review 1) -----
# Existing installs can carry a regular file where the mkdir lock wants to
# live; before the fix acquire spun forever on it.
L="$WORK/lock-file-leftover"
printf 'flock-leftover' > "$L"
( portable_lock_acquire "$L" 30 600; sleep 3 ) &
HOLDER=$!
sleep 1
[ -d "$L" ] && pass "leftover .lock file unlinked; lock dir created" || fail "leftover .lock file unlinked; lock dir created" "$(ls -ld "$L" 2>/dev/null)"
[ -f "$L/stamp" ] && pass "leftover-file lock holds a stamp" || fail "leftover-file lock holds a stamp" "no stamp"
wait "$HOLDER"
[ ! -e "$L" ] && pass "leftover-file lock released" || fail "leftover-file lock released" "still there"

# --- lock: an unlink that cannot succeed fails fast (review 1) -----------------
# A read-only parent makes rm -f fail; acquire must return 1 with a clear
# status, never spin. Skipped under root (root bypasses the mode bits).
if [ "$(id -u)" = "0" ]; then
  pass "unlink-failure fail-fast — skipped: running as root"
else
  ROP="$WORK/lock-ro"
  mkdir -p "$ROP"
  printf 'flock-leftover' > "$ROP/keep.lock"
  chmod 555 "$ROP"
  GOT=$(timeout 30 bash -c '. "$1"; portable_lock_acquire "$2" 2 600' \
    _ "$LIB" "$ROP/keep.lock" >/dev/null 2>"$WORK/ro.err"; echo $?)
  assert_eq "unlink-failure rc (fail fast, no spin)" "1" "$GOT"
  grep -q 'not a directory' "$WORK/ro.err" \
    && pass "unlink-failure names the blocked path" \
    || fail "unlink-failure names the blocked path" "$(cat "$WORK/ro.err")"
  [ -f "$ROP/keep.lock" ] && pass "blocked leftover file left in place" || fail "blocked leftover file left in place" "removed"
  chmod 755 "$ROP"
  rm -f "$ROP/keep.lock"
fi

# --- lock: a restamped (fresh) lock carried off by a steal is handed back -----
# (review 2). The steal's mv->re-read window is microseconds in production, so
# the branch is driven directly: a stub stamp reader reports a dead-pid stamp
# for the lock path (making acquire steal) and a live-pid fresh stamp for the
# moved-aside copy — the on-disk state another holder's restamp would produce.
# The pre-fix code rm'd that copy, destroying the live holder's lock dir.
L="$WORK/lock-restamp"
mkdir -p "$L"
sh -c 'exec sleep 30' & STALEPID=$!
kill -9 "$STALEPID" 2>/dev/null
wait "$STALEPID" 2>/dev/null
printf '%s %s %s\n' "$STALEPID" "$(( $(date +%s) - 30 ))" "dead-owner" > "$L/stamp"
sh -c 'exec sleep 20' & FRESHPID=$!
RESTAMP_DRIVER="$WORK/restamp-driver.sh"
cat > "$RESTAMP_DRIVER" <<'EOS'
. "$1"
_portable_lock_stamp_field() {
  case "$1" in
    *.stale.*)
      case "$2" in
        1) printf '%s\n' "$RESTAMP_PID" ;;
        2) printf '%s\n' "$(date +%s)" ;;
        3) printf '%s\n' "fresh-owner" ;;
      esac
      ;;
    *)
      case "$2" in
        1) printf '%s\n' "$STALE_PID" ;;
        2) printf '%s\n' "$(( $(date +%s) - 30 ))" ;;
        3) printf '%s\n' "dead-owner" ;;
      esac
      ;;
  esac
}
portable_lock_acquire "$2" 2 600
EOS
GOT=$(timeout 30 env RESTAMP_PID="$FRESHPID" STALE_PID="$STALEPID" \
  bash "$RESTAMP_DRIVER" "$LIB" "$L" >/dev/null 2>&1; echo $?)
assert_eq "restamped fresh copy: acquire stays busy" "1" "$GOT"
[ -d "$L" ] && pass "restamped lock dir survived (handed back, not rm'd)" || fail "restamped lock dir survived (handed back, not rm'd)" "destroyed"
ls "$WORK"/lock-restamp.stale.* >/dev/null 2>&1 \
  && fail "restamped hand-back left no .stale copy" "copy remains" \
  || pass "restamped hand-back left no .stale copy"
kill "$FRESHPID" 2>/dev/null
wait "$FRESHPID" 2>/dev/null
rm -rf "$L"

# --- with_timeout: passthrough, deadline, perl fallback, usage ----------------
portable_with_timeout 5 true; RC=$?
assert_eq "with_timeout true rc" "0" "$RC"
portable_with_timeout 5 sh -c 'exit 3'; RC=$?
assert_eq "with_timeout passthrough rc" "3" "$RC"
timeout 30 bash -c '. "$1"; portable_with_timeout 1 sleep 30' _ "$LIB" >/dev/null 2>&1; RC=$?
assert_eq "with_timeout kills past the deadline (124)" "124" "$RC"
mk_fakebin "$WORK/bin-perl" bash sh perl sleep cat
timeout 30 env PATH="$WORK/bin-perl" bash -c '. "$1"; portable_with_timeout 1 sleep 30' _ "$LIB" >/dev/null 2>&1; RC=$?
assert_eq "with_timeout perl fallback kills past the deadline (124)" "124" "$RC"
timeout 30 env PATH="$WORK/bin-perl" bash -c '. "$1"; portable_with_timeout 5 sh -c "exit 3"' _ "$LIB" >/dev/null 2>&1; RC=$?
assert_eq "with_timeout perl fallback passthrough rc" "3" "$RC"
portable_with_timeout 0 true >/dev/null 2>&1; RC=$?
assert_eq "with_timeout 0 seconds is a usage error" "64" "$RC"
portable_with_timeout abc true >/dev/null 2>&1; RC=$?
assert_eq "with_timeout non-numeric seconds is a usage error" "64" "$RC"
portable_with_timeout 5 >/dev/null 2>&1; RC=$?
assert_eq "with_timeout without a command is a usage error" "64" "$RC"
bash "$LIB" with_timeout 5 >/dev/null 2>&1; RC=$?
assert_eq "with_timeout subprocess without a command is a usage error" "64" "$RC"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
