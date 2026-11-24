#!/usr/bin/env bash
# test-sync-includes-check.sh — golden suite for sync-includes-check.sh (CDT-615)
#
# Machine-check: bash skills/agent-memory/test-sync-includes-check.sh  (exit 0)
# Named test-*.sh per SPEC-030 R4/R9 — tools/run-all-tests.sh discovers it; it is
# also the CI include-drift job. Message-shape assertions are ported from the
# retired python suite (CDT-235 / CDT-241 era), not re-guessed.
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SCRIPT="$HERE/sync-includes-check.sh"

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

assert_bytes() { # assert_bytes <name> <expected-file> <actual-file>
  if cmp -s "$2" "$3"; then pass "$1"
  else fail "$1" "$(diff -u "$2" "$3" | head -20 | tr '\n' '|')"
  fi
}

run() {
  # run <args...> ; sets OUT, ERR, RC
  local out err rc errfile
  errfile=$(mktemp)
  out=$(cd "$ROOT" && bash "$SCRIPT" "$@" 2>"$errfile")
  rc=$?
  err=$(cat "$errfile"); rm -f "$errfile"
  OUT="$out"; ERR="$err"; RC="$rc"
}

# --- CDT-241: the suite must leave $ROOT byte-identical. Capture the working
# tree state before the first run; compare before the summary. Graceful skip
# (recorded pass) when $ROOT is not a git working tree.
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  TREE_CHECK=1
  TREE_BEFORE=$(git -C "$ROOT" status --porcelain)
else
  TREE_CHECK=0
  TREE_BEFORE=""
fi

# Fixture root so no test writes inside the repo tree (CDT-241: created before
# the first subtest; every write-side test, apply included, targets this root).
FIX=$(mktemp -d "${TMPDIR:-/tmp}/sync-includes-check-fix.XXXXXX")
trap 'rm -rf "$FIX"' EXIT
OUTSIDE=$(mktemp -d "${TMPDIR:-/tmp}/sync-includes-check-outside.XXXXXX")
trap 'rm -rf "$FIX" "$OUTSIDE"' EXIT

# --- unknown mode: table-driven over AC2's exit table, not two literals.
# Covers flag-like, near-misses (case/prefix), empty string, leading-dash,
# embedded-space, and path-like shapes.
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
  'skills/agent-memory/sync-includes-check.sh'
  'bogus'
  'applesauce'
)
for m in "${UNKNOWN_MODES[@]}"; do
  run "$m"
  assert_eq "unknown mode [$m]: exit 64" "64" "$RC"
  assert_contains "unknown mode [$m]: usage on stderr" "$ERR" "Usage:"
  assert_empty "unknown mode [$m]: stdout is empty" "$OUT"
done
run bogus
assert_contains "unknown mode: names the mode" "$ERR" "unrecognised mode: bogus"
assert_not_contains "unknown mode: no traceback" "$ERR" "Traceback"

# --- check on clean tree ---
run check
assert_eq "check: exit 0 on clean tree" "0" "$RC"
assert_contains "check: unchanged message" "$OUT" "All managed include regions match their partials."

# --- bare invocation defaults to check ---
run
assert_eq "bare: exit 0" "0" "$RC"
assert_contains "bare: unchanged message" "$OUT" "All managed include regions match their partials."

# --- apply still reports correctly (CDT-241: sandboxed to a fixture root) ----
# No subtest runs apply against $ROOT: with no --root the default root is '.'
# and a bare apply would heal drift in the real tree as a side effect.
mkdir -p "$FIX/applyroot/agents" "$FIX/applyroot/skills/lib"
printf '%s\n' '<!--' 'fixture partial' '-->' 'APPLIED BODY' > "$FIX/applyroot/skills/lib/part.md"
printf '%s\n' '<!-- include: skills/lib/part.md agent=qa -->' 'stale body' '<!-- /include -->' \
  > "$FIX/applyroot/agents/dummy.md"
run --root "$FIX/applyroot" apply
assert_eq "apply: exit 0" "0" "$RC"
assert_contains "apply: reports rewrite count" "$OUT" "apply: rewrote 1 region(s)."
assert_contains "apply: region body rewritten" "$(cat "$FIX/applyroot/agents/dummy.md")" "APPLIED BODY"
assert_not_contains "apply: stale body gone" "$(cat "$FIX/applyroot/agents/dummy.md")" "stale body"
run --root "$FIX/applyroot" check
assert_eq "apply: fixture clean after apply" "0" "$RC"

# --- -h / --help: usage, exit 0 ---
run --help
assert_eq "--help: exit 0" "0" "$RC"
assert_contains "--help: usage on stdout" "$OUT" "Usage:"
run -h
assert_eq "-h: exit 0" "0" "$RC"
assert_contains "-h: usage on stdout" "$OUT" "Usage:"
run --root "$FIX/applyroot" --help
assert_eq "--root then --help: exit 0" "0" "$RC"

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

# --- INTENTIONAL DIVERGENCE (CDT-615 audit gap 7): a nonexistent --root exits
# 64. The retired python globbed an empty set and exited 0 on a clean scan.
run check --root "$FIX/no-such-root"
assert_eq "divergence: nonexistent --root exits 64" "64" "$RC"
assert_contains "divergence: nonexistent --root names --root" "$ERR" "--root"
assert_not_contains "divergence: nonexistent --root: no traceback" "$ERR" "Traceback"

# --- rv-w3-25 hardening: containment, missing partial, pairing ---------------
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

# 2. Absolute path: rejected with the python wording (audit gap 6).
fixture_file 'escape-abs.md' '<!-- include: /etc/passwd agent=x -->'
run --root "$FIX" check "$FIX/escape-abs.md"
assert_eq "absolute path: exit 1" "1" "$RC"
assert_contains "absolute path: friendly error" "$ERR" "absolute"
assert_contains "absolute path: names the partial" "$ERR" "/etc/passwd"
assert_not_contains "absolute path: no traceback" "$ERR" "Traceback"

# 3. Missing partial: friendly error naming it, not a traceback.
fixture_file 'missing.md' '<!-- include: skills/p/nope.md agent=x -->'
run --root "$FIX" check "$FIX/missing.md"
assert_eq "missing partial: exit 1" "1" "$RC"
assert_contains "missing partial: names the partial" "$ERR" "skills/p/nope.md"
assert_not_contains "missing partial: no traceback" "$ERR" "Traceback"

# 3b. ~-prefixed partial path: rejected with the friendly error (rv-w3-25).
fixture_file 'tilde.md' '<!-- include: ~/escape/outside.md agent=x -->'
run --root "$FIX" check "$FIX/tilde.md"
assert_eq "tilde path: check exit 1" "1" "$RC"
assert_contains "tilde path: friendly error" "$ERR" "~/escape/outside.md"
assert_not_contains "tilde path: no traceback" "$ERR" "Traceback"
run --root "$FIX" apply "$FIX/tilde.md"
assert_eq "tilde path: apply exit 1" "1" "$RC"
assert_not_contains "tilde path: apply no traceback" "$ERR" "Traceback"

# 3c. Symlink inside the tree pointing outside: rejected (rv-w3-25).
printf '%s\n' 'HOSTILE BODY' > "$OUTSIDE/target.md"
if ln -s "$OUTSIDE/target.md" "$FIX/skills/p/outside.md" 2>/dev/null; then
  fixture_file 'symlink.md' '<!-- include: skills/p/outside.md agent=x -->'
  run --root "$FIX" check "$FIX/symlink.md"
  assert_eq "symlink escape: check exit 1" "1" "$RC"
  assert_contains "symlink escape: friendly error" "$ERR" "outside"
  assert_not_contains "symlink escape: no traceback" "$ERR" "Traceback"
  pass "symlink escape fixture created"
else
  pass "symlink escape: ln -s unsupported on this host — skipped"
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

# 6b. A late region error aborts the whole apply: an earlier clean region in the
# same file is NOT written (audit gap 3 — collect-then-write, rv-w3-25).
printf '%s\n' '<!-- include: skills/p/part.md agent=x -->' 'stale a' '<!-- /include -->' \
  '<!-- include: skills/p/nope.md agent=x -->' 'stale b' '<!-- /include -->' > "$FIX/late.md"
cp "$FIX/late.md" "$FIX/late.orig"
run --root "$FIX" apply "$FIX/late.md"
assert_eq "late error: apply exit 1" "1" "$RC"
assert_eq "late error: earlier region untouched" "$(cat "$FIX/late.orig")" "$(cat "$FIX/late.md")"

# 7. Orphan close: rejected (the file carries no open marker at all).
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

# --- apply byte-contract: the rewrite equals the python apply output ---------
# Expected bytes are written out literally (python's '\n'.join(lines) with the
# expansion spliced in), so the port is pinned byte-for-byte, not just loosely.
mkdir -p "$FIX/bytes/skills/p"
printf '%s\n' '<!--' 'Editing notes: this block is stripped,' 'through the first --> line.' '-->' \
  '' '## Heading' '' 'Text for <AGENT> today and <AGENT> again.' '' > "$FIX/bytes/skills/p/part.md"
printf '%s\n' '# Consumer' '' '<!-- include: skills/p/part.md agent=qa -->' 'stale body' \
  '<!-- /include -->' '' 'trailing prose' > "$FIX/bytes/consumer.md"
cat > "$FIX/bytes/expected.md" <<'EOF'
# Consumer

<!-- include: skills/p/part.md agent=qa -->
## Heading

Text for qa today and qa again.
<!-- /include -->

trailing prose
EOF
cp "$FIX/bytes/consumer.md" "$FIX/bytes/consumer.before"
run --root "$FIX/bytes" apply "$FIX/bytes/consumer.md"
assert_eq "apply bytes: exit 0" "0" "$RC"
assert_bytes "apply bytes: file byte-equals the python-apply expectation" \
  "$FIX/bytes/expected.md" "$FIX/bytes/consumer.md"
run --root "$FIX/bytes" check "$FIX/bytes/consumer.md"
assert_eq "apply bytes: check clean after apply" "0" "$RC"

# --- apply on a GREEN file: zero rewrites, file bytes untouched --------------
BEFORE=$(cksum "$FIX/bytes/consumer.md")
run --root "$FIX/bytes" apply "$FIX/bytes/consumer.md"
assert_eq "apply green: exit 0" "0" "$RC"
assert_contains "apply green: reports 0 rewrites" "$OUT" "apply: rewrote 0 region(s)."
assert_eq "apply green: file bytes untouched" "$BEFORE" "$(cksum "$FIX/bytes/consumer.md")"

# --- apply keeps a file that ends WITHOUT a final newline byte-exact (python
# '\n'.join(lines) does not add one) ------------------------------------------
printf '%s\n' '<!-- include: skills/p/part.md agent=x -->' 'stale tail' '<!-- /include -->' \
  > "$FIX/bytes/notrail.md"
printf '%s' 'trailing prose with no newline' >> "$FIX/bytes/notrail.md"
printf '%s\n' '<!-- include: skills/p/part.md agent=x -->' '## Heading' '' \
  'Text for x today and x again.' '<!-- /include -->' > "$FIX/bytes/notrail-expected.md"
printf '%s' 'trailing prose with no newline' >> "$FIX/bytes/notrail-expected.md"
run --root "$FIX/bytes" apply "$FIX/bytes/notrail.md"
assert_eq "apply no-final-newline: exit 0" "0" "$RC"
assert_bytes "apply no-final-newline: byte-exact (no newline added)" \
  "$FIX/bytes/notrail-expected.md" "$FIX/bytes/notrail.md"

# --- an expansion that trims to nothing empties the region (python: [] slice) -
printf '%s\n' '<!--' 'only a comment block' '-->' > "$FIX/bytes/skills/p/empty.md"
printf '%s\n' '<!-- include: skills/p/empty.md agent=x -->' 'stale body' '<!-- /include -->' \
  > "$FIX/bytes/empty-consumer.md"
printf '%s\n' '<!-- include: skills/p/empty.md agent=x -->' '<!-- /include -->' > "$FIX/bytes/empty-expected.md"
run --root "$FIX/bytes" apply "$FIX/bytes/empty-consumer.md"
assert_eq "empty expansion: apply exit 0" "0" "$RC"
assert_bytes "empty expansion: body lines removed" \
  "$FIX/bytes/empty-expected.md" "$FIX/bytes/empty-consumer.md"

# --- drift output shape (audit gaps 4 + 5) ----------------------------------
mkdir -p "$FIX/drift/skills/p"
printf '%s\n' '<!--' 'fixture partial' '-->' 'THE EXPECTED BODY' > "$FIX/drift/skills/p/part.md"
printf '%s\n' '<!-- include: skills/p/part.md agent=x -->' 'stale body' '<!-- /include -->' \
  > "$FIX/drift/d.md"
run --root "$FIX/drift" check "$FIX/drift/d.md"
assert_eq "drift: exit 1" "1" "$RC"
assert_contains "drift: names the file and partial" "$OUT" "DRIFT: $FIX/drift/d.md (agent=x, partial=skills/p/part.md)"
assert_contains "drift: from-file label" "$OUT" "--- in-file"
assert_contains "drift: to-file label" "$OUT" "+++ partial-expanded"
assert_contains "drift: shows the stale line" "$OUT" "-stale body"
assert_contains "drift: shows the wanted line" "$OUT" "+THE EXPECTED BODY"
assert_not_contains "drift: no tmp path leak" "$OUT" "syncinc."
DRIFT_LABELS=$(printf '%s\n' "$OUT" | grep -E '^ *(-{3}|\+\+\+) ')
assert_not_contains "drift: diff labels are not paths" "$DRIFT_LABELS" "/"
assert_contains "drift: summary on stderr" "$ERR" "1 managed include region(s) drifted from their partial."
assert_not_contains "drift: summary not on stdout" "$OUT" "region(s) drifted"

# --- discovery: the default file set, AGENTS.md optional (audit gap 2) -------
mkdir -p "$FIX/scan/agents" "$FIX/scan/skills/p" "$FIX/scan/skills/s" "$FIX/scan/commands"
printf '%s\n' '<!--' 'p' '-->' 'BODY' > "$FIX/scan/skills/p/part.md"
printf '%s\n' '<!-- include: skills/p/part.md agent=x -->' 'stale' '<!-- /include -->' > "$FIX/scan/agents/a.md"
printf '%s\n' '<!-- include: skills/p/part.md agent=x -->' 'stale' '<!-- /include -->' > "$FIX/scan/skills/s/b.md"
printf '%s\n' '<!-- include: skills/p/part.md agent=x -->' 'stale' '<!-- /include -->' > "$FIX/scan/commands/c.md"
run --root "$FIX/scan" check
assert_eq "scan: exit 1 on drift" "1" "$RC"
assert_contains "scan: agents/ file scanned" "$OUT" "agents/a.md"
assert_contains "scan: skills/ file scanned" "$OUT" "skills/s/b.md"
assert_contains "scan: commands/ file scanned" "$OUT" "commands/c.md"
assert_contains "scan: three regions drifted" "$ERR" "3 managed include region(s) drifted from their partial."
printf '%s\n' '<!-- include: skills/p/part.md agent=x -->' 'stale' '<!-- /include -->' > "$FIX/scan/AGENTS.md"
run --root "$FIX/scan" check
assert_contains "scan: AGENTS.md scanned when present" "$OUT" "AGENTS.md"
assert_contains "scan: four regions drifted" "$ERR" "4 managed include region(s) drifted from their partial."

# --- discovery: a root with no AGENTS.md is scanned silently (audit gap 2 —
# python's glob omits the missing file; the seed port emitted it unconditionally
# and hard-failed with "no such file"). GREEN fixture: a clean region, exit 0.
mkdir -p "$FIX/noagents/agents" "$FIX/noagents/skills/p"
printf '%s\n' '<!--' 'p' '-->' 'BODY' > "$FIX/noagents/skills/p/part.md"
printf '%s\n' '<!-- include: skills/p/part.md agent=x -->' 'BODY' '<!-- /include -->' \
  > "$FIX/noagents/agents/a.md"
run --root "$FIX/noagents" check
assert_eq "scan: root without AGENTS.md exits 0" "0" "$RC"
assert_contains "scan: root without AGENTS.md clean message" "$OUT" "All managed include regions match their partials."
assert_not_contains "scan: no missing-file error for absent AGENTS.md" "$ERR" "no such file"

# --- INTENTIONAL DIVERGENCE (audit gap: friendly error class): a missing file
# argument exits 1 with a friendly message; python raised a FileNotFoundError.
run --root "$FIX" check "$FIX/no-such-file.md"
assert_eq "missing file arg: exit 1" "1" "$RC"
assert_contains "missing file arg: names the file" "$ERR" "no-such-file.md"
assert_not_contains "missing file arg: no traceback" "$ERR" "Traceback"

# --- INTENTIONAL DIVERGENCE (audit gap 8): a flag after the mode is a file
# argument (python: same position rule), so it is not help.
run check --help
assert_eq "check --help: not help, treated as a file" "1" "$RC"
assert_not_contains "check --help: no traceback" "$ERR" "Traceback"

# --- CDT-241: no subtest may mutate $ROOT. A real-tree `apply` healed drift as
# a side effect; the identity assertion catches any regression.
if [ "$TREE_CHECK" = "1" ]; then
  TREE_AFTER=$(git -C "$ROOT" status --porcelain)
  assert_eq "suite: working tree unchanged" "$TREE_BEFORE" "$TREE_AFTER"
else
  pass "suite: working tree unchanged — skipped (not a git working tree)"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
