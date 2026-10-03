#!/usr/bin/env bash
# sync-includes-test.sh — bite-tests for sync-includes.py mode validation (CDT-235)
#
# Machine-check: bash skills/agent-memory/sync-includes-test.sh  (exit 0)
# Named *-test.sh per SPEC-030 — smoke parses it with `bash -n`; the all-suites
# runner runs it. Also wired as its own CI job (parity with skills/plugin-dir-test.sh).
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

# --- rv-w3-25 hardening: containment, missing partial, pairing ---------------
# Fixture root so no test writes inside the repo tree.
FIX=$(mktemp -d "${TMPDIR:-/tmp}/sync-includes-fix.XXXXXX")
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/skills/p"
printf '%s\n' '<!--' 'fixture partial' '-->' 'BODY' > "$FIX/skills/p/part.md"

fixture_file() { # fixture_file <name> <marker-line>
  printf '%s\n' "$2" 'stale body' '<!-- /include -->' > "$FIX/$1"
}

# 1. ../ escape: rejected in check and apply, friendly error, no traceback.
fixture_file 'escape-rel.md' '<!-- include: skills/../outside.md agent=x -->'
run --root "$FIX" check "$FIX/escape-rel.md"
assert_eq "escape ../: check exit 1" "1" "$RC"
assert_contains "escape ../: names the partial" "$ERR" "../outside.md"
assert_not_contains "escape ../: no traceback" "$ERR" "Traceback"
cp "$FIX/escape-rel.md" "$FIX/escape-rel.orig"
run --root "$FIX" apply "$FIX/escape-rel.md"
assert_eq "escape ../: apply exit 1" "1" "$RC"
assert_eq "escape ../: apply wrote nothing" "$(cat "$FIX/escape-rel.orig")" "$(cat "$FIX/escape-rel.md")"

# 2. Absolute path: rejected.
fixture_file 'escape-abs.md' '<!-- include: /etc/passwd agent=x -->'
run --root "$FIX" check "$FIX/escape-abs.md"
assert_eq "absolute path: exit 1" "1" "$RC"
assert_contains "absolute path: friendly error" "$ERR" "absolute"
assert_not_contains "absolute path: no traceback" "$ERR" "Traceback"

# 3. Missing partial: friendly error naming it, not a traceback.
fixture_file 'missing.md' '<!-- include: skills/p/nope.md agent=x -->'
run --root "$FIX" check "$FIX/missing.md"
assert_eq "missing partial: exit 1" "1" "$RC"
assert_contains "missing partial: names the partial" "$ERR" "skills/p/nope.md"
assert_not_contains "missing partial: no traceback" "$ERR" "Traceback"

# 3b. ~-prefixed partial path: rejected with the friendly error (rv-w3-25).
# Old code joined it onto root and trace-backed on the missing file.
fixture_file 'tilde.md' '<!-- include: ~/escape/outside.md agent=x -->'
run --root "$FIX" check "$FIX/tilde.md"
assert_eq "tilde path: check exit 1" "1" "$RC"
assert_contains "tilde path: friendly error" "$ERR" "~/escape/outside.md"
assert_not_contains "tilde path: no traceback" "$ERR" "Traceback"
run --root "$FIX" apply "$FIX/tilde.md"
assert_eq "tilde path: apply exit 1" "1" "$RC"
assert_not_contains "tilde path: apply no traceback" "$ERR" "Traceback"

# 3c. Symlink inside the tree pointing outside: rejected (rv-w3-25).
# Old code followed the link and happily read the outside file.
OUTSIDE=$(mktemp -d "${TMPDIR:-/tmp}/sync-includes-outside.XXXXXX")
printf '%s\n' 'HOSTILE BODY' > "$OUTSIDE/target.md"
if ln -s "$OUTSIDE/target.md" "$FIX/skills/p/outside.md" 2>/dev/null; then
  fixture_file 'symlink.md' '<!-- include: skills/p/outside.md agent=x -->'
  run --root "$FIX" check "$FIX/symlink.md"
  assert_eq "symlink escape: check exit 1" "1" "$RC"
  assert_contains "symlink escape: friendly error" "$ERR" "outside"
  assert_not_contains "symlink escape: no traceback" "$ERR" "Traceback"
  ok "symlink escape fixture created"
else
  ok "symlink escape: ln -s unsupported on this host — skipped"
fi

# 4. Valid region still resolves from the fixture root (correct body → clean).
printf '%s\n' '<!-- include: skills/p/part.md agent=x -->' 'BODY' '<!-- /include -->' > "$FIX/ok.md"
run --root "$FIX" check "$FIX/ok.md"
assert_eq "valid fixture region: exit 0" "0" "$RC"

# 5. Unclosed region: apply aborts without writing.
printf '%s\n' '<!-- include: skills/p/part.md agent=x -->' 'stale body' > "$FIX/unclosed.md"
cp "$FIX/unclosed.md" "$FIX/unclosed.orig"
run --root "$FIX" apply "$FIX/unclosed.md"
assert_eq "unclosed region: apply exit 1" "1" "$RC"
assert_contains "unclosed region: says unclosed" "$ERR" "unclosed"
assert_not_contains "unclosed region: no traceback" "$ERR" "Traceback"
assert_eq "unclosed region: file untouched" "$(cat "$FIX/unclosed.orig")" "$(cat "$FIX/unclosed.md")"
run --root "$FIX" check "$FIX/unclosed.md"
assert_eq "unclosed region: check exit 1" "1" "$RC"

# 6. Second open before the first close (the swallow corruption class):
# apply must abort before writing either region.
printf '%s\n' '<!-- include: skills/p/part.md agent=x -->' 'body one' \
  '<!-- include: skills/p/part.md agent=y -->' 'body two' '<!-- /include -->' > "$FIX/nested.md"
cp "$FIX/nested.md" "$FIX/nested.orig"
run --root "$FIX" apply "$FIX/nested.md"
assert_eq "nested open: apply exit 1" "1" "$RC"
assert_contains "nested open: reports the first open" "$ERR" "opened at line 1"
assert_eq "nested open: file untouched" "$(cat "$FIX/nested.orig")" "$(cat "$FIX/nested.md")"

# 7. Orphan close: rejected.
printf '%s\n' 'prose' '<!-- /include -->' > "$FIX/orphan.md"
run --root "$FIX" check "$FIX/orphan.md"
assert_eq "orphan close: exit 1" "1" "$RC"
assert_contains "orphan close: friendly error" "$ERR" "without a matching open"

# 8. Two well-formed regions in one file apply cleanly (multi-region rewrite).
printf '%s\n' '<!-- include: skills/p/part.md agent=x -->' 'stale a' '<!-- /include -->' \
  'middle prose' \
  '<!-- include: skills/p/part.md agent=y -->' 'stale b' '<!-- /include -->' > "$FIX/two.md"
run --root "$FIX" apply "$FIX/two.md"
assert_eq "two regions: apply exit 0" "0" "$RC"
assert_contains "two regions: reports 2 rewrites" "$OUT" "apply: rewrote 2 region(s)."
assert_contains "two regions: second region rewritten" "$(cat "$FIX/two.md")" "BODY"
run --root "$FIX" check "$FIX/two.md"
assert_eq "two regions: check clean after apply" "0" "$RC"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
