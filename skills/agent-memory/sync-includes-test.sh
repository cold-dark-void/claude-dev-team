#!/usr/bin/env bash
# sync-includes-test.sh — bite-tests for sync-includes.py mode validation (CDT-235)
#
# Machine-check: bash skills/agent-memory/sync-includes-test.sh  (exit 0)
# Named *-test.sh per SPEC-030 — excluded from smoke discovery, wired as its own
# CI job (parity with skills/plugin-dir-test.sh).
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SCRIPT="$HERE/sync-includes.py"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s — %s\n' "$1" "$2"; }

assert_eq() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then pass "$name"
  else fail "$name" "want='$want' got='$got'"
  fi
}

assert_contains() {
  local name="$1" hay="$2" needle="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then pass "$name"
  else fail "$name" "missing [$needle] in [$hay]"
  fi
}

assert_empty() {
  local name="$1" hay="$2"
  if [ -z "$hay" ]; then pass "$name"
  else fail "$name" "expected empty, got [$hay]"
  fi
}

assert_not_contains() {
  local name="$1" hay="$2" needle="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then fail "$name" "unexpected [$needle] in [$hay]"
  else pass "$name"
  fi
}

run() {
  # run <mode-args...> ; sets OUT, ERR, RC
  local out err rc errfile
  errfile=$(mktemp)
  out=$(cd "$ROOT" && python3 "$SCRIPT" "$@" 2>"$errfile")
  rc=$?
  err=$(cat "$errfile"); rm -f "$errfile"
  OUT="$out"; ERR="$err"; RC="$rc"
}

# --- unknown mode: table-driven over AC1's "any other unrecognised mode",
# not two literals. Covers flag-like, near-misses (case/whitespace/prefix),
# empty string, leading-dash, embedded-space, and path-like shapes.
UNKNOWN_MODES=(
  '--check'
  '-c'
  '--apply'
  'checked'
  'Check'
  'CHECK'
  'apply '
  'chec'
  ''
  '-x'
  'with space'
  'skills/agent-memory/sync-includes.py'
  'bogus'
  'applesauce'
)
for m in "${UNKNOWN_MODES[@]}"; do
  run "$m"
  assert_eq "unknown mode [$m]: exit 64" "64" "$RC"
  assert_contains "unknown mode [$m]: usage on stderr" "$ERR" "Usage:"
  assert_empty "unknown mode [$m]: stdout is empty" "$OUT"
done

# --- check on clean tree ---
run check
assert_eq "check: exit 0 on clean tree" "0" "$RC"
assert_contains "check: unchanged message" "$OUT" "All managed include regions match their partials."

# --- bare invocation defaults to check ---
run
assert_eq "bare: exit 0" "0" "$RC"
assert_contains "bare: unchanged message" "$OUT" "All managed include regions match their partials."

# --- apply still reports correctly ---
run apply
assert_eq "apply: exit 0" "0" "$RC"
assert_contains "apply: reports rewrite count" "$OUT" "apply: rewrote"

# --- -h / --help: usage, exit 0 ---
run --help
assert_eq "--help: exit 0" "0" "$RC"
assert_contains "--help: usage on stdout" "$OUT" "Usage:"

# --- --root: before mode, with a valid path ---
run --root "$ROOT" check
assert_eq "--root before mode: exit 0" "0" "$RC"
assert_contains "--root before mode: unchanged message" "$OUT" "All managed include regions match their partials."

# --- --root: after mode, with a valid path ---
run check --root "$ROOT"
assert_eq "--root after mode: exit 0" "0" "$RC"
assert_contains "--root after mode: unchanged message" "$OUT" "All managed include regions match their partials."

# --- --root: as the final argument, no value — must fail closed, not crash ---
run --root
assert_eq "--root missing value: exit 64" "64" "$RC"
assert_contains "--root missing value: usage on stderr" "$ERR" "Usage:"
assert_empty "--root missing value: stdout is empty" "$OUT"
assert_not_contains "--root missing value: no traceback" "$ERR" "Traceback"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
