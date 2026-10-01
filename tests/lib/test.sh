#!/usr/bin/env bash
# tests/lib/test.sh — self-test for skip.sh and hermetic.sh (SPEC-030 R21).
# Run: bash tests/lib/test.sh
# Nothing here runs as root and nothing is installed.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SKIP="$HERE/skip.sh"
HERMETIC="$HERE/hermetic.sh"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/tests-lib-test.XXXXXX")
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ---- PATH shims: fake `id` printing 0 (root) or 1000 (non-root) -----------
ROOT_SHIM="$WORK/root-shim"
mkdir -p "$ROOT_SHIM"
cat > "$ROOT_SHIM/id" <<'EOF'
#!/usr/bin/env bash
echo 0
EOF
chmod +x "$ROOT_SHIM/id"

NONROOT_SHIM="$WORK/nonroot-shim"
mkdir -p "$NONROOT_SHIM"
cat > "$NONROOT_SHIM/id" <<'EOF'
#!/usr/bin/env bash
echo 1000
EOF
chmod +x "$NONROOT_SHIM/id"

# ---- skip_if_root: shim id=0 -> exit 77, SKIP: on stderr -------------------
ERRFILE="$WORK/err1"
PATH="$ROOT_SHIM:$PATH" bash -c '. "'"$SKIP"'"; skip_if_root x' >/dev/null 2>"$ERRFILE"
RC=$?
if [ "$RC" -eq 77 ] && grep -q "SKIP:" "$ERRFILE" && grep -q "root uid: x" "$ERRFILE"; then
  pass
else
  fail "skip_if_root root uid: rc=$RC err=$(cat "$ERRFILE")"
fi

# ---- skip_if_root: shim id=1000 -> returns 0 --------------------------------
OUTFILE="$WORK/out2"
PATH="$NONROOT_SHIM:$PATH" bash -c '. "'"$SKIP"'"; skip_if_root x; echo "rc=$?"' >"$OUTFILE" 2>&1
RC=$?
if [ "$RC" -eq 0 ] && grep -qx "rc=0" "$OUTFILE"; then
  pass
else
  fail "skip_if_root non-root: rc=$RC out=$(cat "$OUTFILE")"
fi

# ---- require_cmd: missing command -> exit 77, names it ---------------------
MISSING="definitely-not-a-cmd-$$"
ERRFILE="$WORK/err3"
bash -c '. "'"$SKIP"'"; require_cmd "'"$MISSING"'"' >/dev/null 2>"$ERRFILE"
RC=$?
if [ "$RC" -eq 77 ] && grep -q "SKIP:.*missing command: $MISSING" "$ERRFILE"; then
  pass
else
  fail "require_cmd missing: rc=$RC err=$(cat "$ERRFILE")"
fi

# ---- require_cmd: present command -> returns 0 ------------------------------
OUTFILE="$WORK/out4"
bash -c '. "'"$SKIP"'"; require_cmd sh; echo "rc=$?"' >"$OUTFILE" 2>&1
RC=$?
if [ "$RC" -eq 0 ] && grep -qx "rc=0" "$OUTFILE"; then
  pass
else
  fail "require_cmd sh: rc=$RC out=$(cat "$OUTFILE")"
fi

# ---- per-case subshell form: prints SKIP:, next line runs -------------------
OUT=$(PATH="$ROOT_SHIM:$PATH" bash -c '
. "'"$SKIP"'"
if ( skip_if_root "case5" ); then
  echo "should-not-run"
fi
echo "after"
' 2>&1)
if echo "$OUT" | grep -q "SKIP:" && echo "$OUT" | grep -qx "after" && ! echo "$OUT" | grep -q "should-not-run"; then
  pass
else
  fail "per-case subshell form: $OUT"
fi

# ---- hermetic_init: TMPDIR/HOME under one root, root gone after exit 0 -----
PARENT="$WORK/parent-exit0"
mkdir -p "$PARENT"
BEFORE=$(ls -A "$PARENT" | wc -l)
INFO=$(TMPDIR="$PARENT" bash -c '
. "'"$HERMETIC"'"
hermetic_init
echo "ROOT=$HERMETIC_ROOT"
echo "TMPDIR=$TMPDIR"
echo "HOME=$HOME"
')
RC=$?
AFTER=$(ls -A "$PARENT" | wc -l)
ROOTVAL=$(echo "$INFO" | sed -n 's/^ROOT=//p')
TVAL=$(echo "$INFO" | sed -n 's/^TMPDIR=//p')
HVAL=$(echo "$INFO" | sed -n 's/^HOME=//p')
if [ "$RC" -eq 0 ] && [ -n "$ROOTVAL" ] && [ "$TVAL" = "$ROOTVAL/tmp" ] \
   && [ "$HVAL" = "$ROOTVAL/home" ] && [ "$AFTER" -eq "$BEFORE" ] \
   && [ ! -d "$ROOTVAL" ]; then
  pass
else
  fail "hermetic_init exit0: rc=$RC root=$ROOTVAL tmpdir=$TVAL home=$HVAL before=$BEFORE after=$AFTER"
fi

# ---- hermetic_init: root gone after a non-zero exit ------------------------
PARENT="$WORK/parent-exit3"
mkdir -p "$PARENT"
BEFORE=$(ls -A "$PARENT" | wc -l)
INFO=$(TMPDIR="$PARENT" bash -c '
. "'"$HERMETIC"'"
hermetic_init
echo "ROOT=$HERMETIC_ROOT"
exit 3
')
RC=$?
AFTER=$(ls -A "$PARENT" | wc -l)
ROOTVAL=$(echo "$INFO" | sed -n 's/^ROOT=//p')
if [ "$RC" -eq 3 ] && [ -n "$ROOTVAL" ] && [ ! -d "$ROOTVAL" ] && [ "$AFTER" -eq "$BEFORE" ]; then
  pass
else
  fail "hermetic_init exit3: rc=$RC root=$ROOTVAL before=$BEFORE after=$AFTER"
fi

# ---- check.sh: pass_line / fail_line / check count and print ----------------
CHECK_LIB="$HERE/check.sh"
OUT=$(bash -c '
. "'"$CHECK_LIB"'"
pass=0; fail=0
check "ok case" true
check "bad case" false
check "arg case" test 1 -eq 1
pass_line "direct pass"
fail_line "direct fail"
echo "counts=$pass,$fail"
' 2>&1)
if echo "$OUT" | grep -qx "PASS: ok case" && echo "$OUT" | grep -qx "FAIL: bad case" \
   && echo "$OUT" | grep -qx "PASS: arg case" && echo "$OUT" | grep -qx "PASS: direct pass" \
   && echo "$OUT" | grep -qx "FAIL: direct fail" && echo "$OUT" | grep -qx "counts=3,2"; then
  pass
else
  fail "check.sh helpers: $OUT"
fi
# sourcing has no side effect (no output, no counters created)
OUT=$(bash -c '. "'"$CHECK_LIB"'"; echo "[${pass:-unset}${fail:-unset}]"' 2>&1)
if [ "$OUT" = "[unsetunset]" ]; then pass; else fail "check.sh sourcing side effect: $OUT"; fi

# ---- fence_exec: fresh bash, cwd, env, captured out/err, RUN_RC -------------
FENCE_LIB="$HERE/fence.sh"
FX="$WORK/fx"
mkdir -p "$FX/cwd"
OUT=$(bash -c '
. "'"$FENCE_LIB"'"
LEAK=caller-var
fence_exec "'"$FX"'/a" "'"$FX"'/cwd" '"'"'printf "cwd=%s v=%s leak=%s\n" "$PWD" "$FENCE_V" "${LEAK:-none}"; echo oops >&2; SET_IN_FENCE=1; exit 3'"'"' FENCE_V=hello
echo "rc=$RUN_RC set=${SET_IN_FENCE:-unset}"
' 2>&1)
if [ "$(tail -1 <<<"$OUT")" = "rc=3 set=unset" ] \
   && grep -qx "cwd=$FX/cwd v=hello leak=none" "$FX/a.out" \
   && grep -qx "oops" "$FX/a.err" && [ -f "$FX/a.sh" ]; then
  pass
else
  fail "fence_exec core: $OUT / out=$(cat "$FX/a.out" 2>&1) err=$(cat "$FX/a.err" 2>&1)"
fi
# stdin is /dev/null (a fence that reads stdin must not hang), and env args are optional
OUT=$(timeout 10 bash -c '
. "'"$FENCE_LIB"'"
fence_exec "'"$FX"'/b" "'"$FX"'/cwd" '"'"'cat; echo done'"'"'
echo "rc=$RUN_RC"
' 2>&1)
if [ "$(tail -1 <<<"$OUT")" = "rc=0" ] && grep -qx "done" "$FX/b.out"; then pass; else fail "fence_exec stdin: $OUT"; fi
# a missing cwd is a non-zero RUN_RC, never a silent run in the wrong directory
OUT=$(bash -c '
. "'"$FENCE_LIB"'"
fence_exec "'"$FX"'/c" "'"$FX"'/no-such-dir" '"'"'echo ran'"'"'
echo "rc=$RUN_RC"
' 2>&1)
if [ "$(tail -1 <<<"$OUT")" != "rc=0" ] && ! grep -qx "ran" "$FX/c.out"; then pass; else fail "fence_exec bad cwd: $OUT"; fi
# too few arguments: usage error under set -u, no unbound-variable abort
OUT=$(bash -c 'set -u; . "'"$FENCE_LIB"'"; fence_exec only-one; echo "rc=$?"' 2>&1)
if echo "$OUT" | grep -q "usage" && echo "$OUT" | grep -q "rc=1" && ! echo "$OUT" | grep -qi "unbound"; then
  pass
else
  fail "fence_exec usage: $OUT"
fi

# ---- trailing_flag_scan: finds value flags that hang without a value (WP 2-02)
TF_LIB="$HERE/trailing-flag.sh"
TF="$WORK/tf"
mkdir -p "$TF"
# planted positive: the unguarded parser hangs on a trailing value flag
cat > "$TF/bad.sh" <<'EOF'
#!/usr/bin/env bash
set -u
while [ $# -gt 0 ]; do
  case "$1" in
    --alpha)  ALPHA="${2:-}"; shift 2 ;;
    -b|--beta)
      BETA="${2:-}"
      shift 2 ;;
    --gamma=*) G="${1#--gamma=}"; shift ;;
    --flag)   F=1; shift ;;
    *) exit 64 ;;
  esac
done
EOF
# negative control: the same parser with a value check exits 64 at once
cat > "$TF/good.sh" <<'EOF'
#!/usr/bin/env bash
set -u
need() { [ "$2" -ge 2 ] || { echo "$1 needs a value" >&2; exit 64; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --alpha)  need "$1" $#; ALPHA="$2"; shift 2 ;;
    -b|--beta)
      need "$1" $#
      BETA="$2"
      shift 2 ;;
    --gamma=*) G="${1#--gamma=}"; shift ;;
    --flag)   F=1; shift ;;
    *) exit 64 ;;
  esac
done
EOF
# two subcommand parsers: the function filter keeps each flag set apart
cat > "$TF/sub.sh" <<'EOF'
#!/usr/bin/env bash
set -u
cmd_one() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --x) X="${2:-}"; shift 2 ;;
      *) exit 64 ;;
    esac
  done
}
cmd_two() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --y) Y="${2:-}"; shift 2 ;;
      *) exit 64 ;;
    esac
  done
}
case "${1:-}" in
  one) shift; cmd_one "$@" ;;
  two) shift; cmd_two "$@" ;;
esac
EOF
(
  . "$TF_LIB"
  trailing_flag_scan "$TF/bad.sh" 64
  if [ "$TF_SKIP" = "1" ]; then echo "SKIP"; exit 0; fi
  [ "$TF_N" = "3" ] && [ "$TF_BAD" = " --alpha=124 -b=124 --beta=124" ] || { echo "BAD: n=$TF_N bad=$TF_BAD"; exit 1; }
  trailing_flag_scan "$TF/good.sh" 64
  [ "$TF_N" = "3" ] && [ -z "$TF_BAD" ] || { echo "GOOD: n=$TF_N bad=$TF_BAD"; exit 1; }
  TF_EXEMPT="--alpha -b" trailing_flag_scan "$TF/bad.sh" 64
  [ "$TF_N" = "1" ] && [ "$TF_BAD" = " --beta=124" ] || { echo "EXEMPT: n=$TF_N bad=$TF_BAD"; exit 1; }
  trailing_flag_scan "$TF/sub.sh" 64 cmd_two two
  [ "$TF_N" = "1" ] && [ "$TF_BAD" = " --y=124" ] || { echo "FN: n=$TF_N bad=$TF_BAD"; exit 1; }
  trailing_flag_scan "$TF/good.sh" 64 cmd_absent
  [ "$TF_N" = "0" ] || { echo "VACUOUS: n=$TF_N"; exit 1; }
  exit 0
) > "$TF/out" 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then pass; else fail "trailing_flag_scan: $(cat "$TF/out")"; fi
# sourcing has no side effect
OUT=$(bash -c '. "'"$TF_LIB"'"; echo "[${TF_N:-unset}${TF_BAD:-unset}]"' 2>&1)
if [ "$OUT" = "[unsetunset]" ]; then pass; else fail "trailing-flag.sh sourcing side effect: $OUT"; fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
