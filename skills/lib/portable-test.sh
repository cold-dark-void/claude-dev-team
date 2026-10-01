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

# --- static: exactly one function definition in portable.sh -----------------
FUNC_RE='^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{'
func_count=$(grep -cE "$FUNC_RE" "$LIB")
assert_eq "static: exactly one function definition" "1" "$func_count"

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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
