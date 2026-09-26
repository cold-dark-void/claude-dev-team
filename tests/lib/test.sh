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

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
