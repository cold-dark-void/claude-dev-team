#!/usr/bin/env bash
# SPEC-021 bite-test harness. Run: bash skills/skill-lint/test.sh
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LINT="$HERE/check-skill-bash.sh"
FIX="$HERE/fixtures"
PASS=0; FAIL=0
OUT=""; RC=0

run_lint() { # run_lint <expected_exit> <args...>
  local want="$1"; shift
  OUT=$(bash "$LINT" "$@" 2>&1); RC=$?
  if [ "$RC" -eq "$want" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: exit $RC != $want for: $*"; echo "$OUT" | head -5
  fi
}

expect_finding() { # expect_finding <check-id> <path-substring> — greps last OUT
  if echo "$OUT" | grep -q "\[$1\]" && echo "$OUT" | grep -q "$2"; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: no [$1] finding for $2 in:"; echo "$OUT" | head -5
  fi
}

expect_no_finding() { # expect_no_finding <check-id>
  if echo "$OUT" | grep -q "\[$1\]"; then
    FAIL=$((FAIL+1)); echo "FAIL: unexpected [$1] finding:"; echo "$OUT" | grep "\[$1\]" | head -3
  else PASS=$((PASS+1)); fi
}

VACUITY="canonical stanza not resolvable"

expect_vacuity() { # expect_vacuity <fail-msg> — C5 must refuse a missing canonical
  if echo "$OUT" | grep -q "$VACUITY"; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $1"; echo "$OUT" | tail -3
  fi
}

expect_no_vacuity() { # expect_no_vacuity <fail-msg> — canonical resolved cleanly
  if echo "$OUT" | grep -q "$VACUITY"; then
    FAIL=$((FAIL+1)); echo "FAIL: $1"; echo "$OUT" | tail -3
  else PASS=$((PASS+1)); fi
}

# T1: clean fixture exits 0; bad flag exits 64
run_lint 0 "$FIX/clean.md"
run_lint 64 --no-such-flag

# T2: C4 — captured inline-PRAGMA flagged; heredoc + -cmd forms not flagged
run_lint 1 "$FIX/c4-pragma.md"
expect_finding C4 "c4-pragma.md:5"
run_lint 1 "$FIX/c4-pragma.md"   # same file: exactly ONE C4 finding
[ "$(echo "$OUT" | grep -c '\[C4\]')" -eq 1 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: expected exactly 1 C4"; }

# T3: C2 — heredoc/quoted-string bang + HTML-comment opener flagged; legit forms not
run_lint 1 "$FIX/c2-bang.md"
expect_finding C2 "c2-bang.md"
[ "$(echo "$OUT" | grep -c '\[C2\]')" -eq 3 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: expected exactly 3 C2, got:"; echo "$OUT" | grep '\[C2\]'; }

# T4: C3 — unguarded globs flagged; find/case/[[ patterns not
run_lint 1 "$FIX/c3-glob.md"
expect_finding C3 "c3-glob.md"
[ "$(echo "$OUT" | grep -c '\[C3\]')" -eq 3 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: expected exactly 3 C3, got:"; echo "$OUT" | grep '\[C3\]'; }

# T5: C1 — cross-block use flagged; allowlist + nowhere-defined + loop vars not
# declare/local/readonly count as defs (Q4) — FIXED/Y/Z also cross-block
# indented same-block def not C1; indented sibling-only def IS C1
run_lint 1 "$FIX/c1-cross-block.md"
expect_finding C1 "c1-cross-block.md:13"
C1N=$(echo "$OUT" | grep -c '\[C1\]')
# PDH + FIXED + Y + Z + INDENTED_ONLY = 5 cross-block uses
[ "$C1N" -ge 1 ] && echo "$OUT" | grep -q '\[C1\].*\$PDH' && PASS=$((PASS+1)) || {
  FAIL=$((FAIL+1)); echo "FAIL: expected C1 on \$PDH, got:"; echo "$OUT" | grep '\[C1\]'
}
# declare/local/readonly defs visible as sibling defs
echo "$OUT" | grep -q '\$FIXED\|\$Y\|\$Z' && PASS=$((PASS+1)) || {
  FAIL=$((FAIL+1)); echo "FAIL: declare/local/readonly not treated as C1 defs"
}
# indented assignment in same block is a def — no C1 on $X
echo "$OUT" | grep '\[C1\].*\$X\b' && {
  FAIL=$((FAIL+1)); echo "FAIL: indented same-block \$X should not be C1"
} || PASS=$((PASS+1))
# indented assignment only in sibling → C1 on $INDENTED_ONLY
echo "$OUT" | grep -q '\[C1\].*\$INDENTED_ONLY' && PASS=$((PASS+1)) || {
  FAIL=$((FAIL+1)); echo "FAIL: expected C1 on indented sibling-only \$INDENTED_ONLY"
}

# T6: waivers — same-line + prev-line suppress; wrong-id does not; summary counts
run_lint 1 "$FIX/waived.md"
[ "$(echo "$OUT" | grep -c '\[C3\]')" -eq 1 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: expected exactly 1 unwaived C3"; }
echo "$OUT" | grep -q "3 findings, 2 waived" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: summary line wrong: $(echo "$OUT" | tail -1)"; }

# T7: discovery / coverage / CLI edges
# 1. No-arg --root temp tree: plant C4 in commands/, skills/nested/, agents/, AGENTS.md
T7ROOT=$(mktemp -d)
mkdir -p "$T7ROOT/commands" "$T7ROOT/skills/deep/nested" "$T7ROOT/agents"
PLANT='```bash'$'\n''V=$(sqlite3 db "PRAGMA busy_timeout=5000; SELECT 1;")'$'\n''```'
printf '%s\n' "$PLANT" > "$T7ROOT/commands/a.md"
printf '%s\n' "$PLANT" > "$T7ROOT/skills/deep/nested/b.md"
printf '%s\n' "$PLANT" > "$T7ROOT/agents/c.md"
printf '%s\n' "$PLANT" > "$T7ROOT/AGENTS.md"
# also plant a fixture-like path that MUST be excluded from no-arg
mkdir -p "$T7ROOT/skills/skill-lint/fixtures"
printf '%s\n' "$PLANT" > "$T7ROOT/skills/skill-lint/fixtures/planted.md"
run_lint 1 --root "$T7ROOT"
for loc in commands/a.md skills/deep/nested/b.md agents/c.md AGENTS.md; do
  echo "$OUT" | grep -q "$loc" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: no-arg scan missed $loc"; }
done
echo "$OUT" | grep -q "skill-lint/fixtures/planted.md" && {
  FAIL=$((FAIL+1)); echo "FAIL: fixtures dir not excluded from no-arg discovery"
} || PASS=$((PASS+1))

# 2. File-list form: scan only named file (other planted not reported)
run_lint 1 "$T7ROOT/commands/a.md"
echo "$OUT" | grep -q "commands/a.md" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: file-list missed named file"; }
echo "$OUT" | grep -q "agents/c.md" && { FAIL=$((FAIL+1)); echo "FAIL: file-list scanned non-named file"; } || PASS=$((PASS+1))
rm -rf "$T7ROOT"

# 3. Fixtures excluded: no-arg on real repo root must NOT report fixtures/c4-pragma.md
REPO_ROOT=$(cd "$HERE/../.." && pwd)
OUT=$(bash "$LINT" --root "$REPO_ROOT" 2>&1); RC=$?
echo "$OUT" | grep -q "fixtures/c4-pragma.md" && {
  FAIL=$((FAIL+1)); echo "FAIL: real-tree no-arg reported fixtures/c4-pragma.md"
} || PASS=$((PASS+1))

# 4. All-missing paths → 64
run_lint 64 /no/such/a.md /no/such/b.md

# 5. Unreadable skip+warn (mix with readable → not 64)
UNREAD=$(mktemp)
chmod 000 "$UNREAD" 2>/dev/null || true
if [ ! -r "$UNREAD" ]; then
  run_lint 0 "$FIX/clean.md" "$UNREAD"
  echo "$OUT" | grep -qi "warn:" && PASS=$((PASS+1)) || {
    # warn may be on stderr mixed into OUT via 2>&1
    echo "$OUT" | grep -qi "cannot read\|warn" && PASS=$((PASS+1)) || {
      FAIL=$((FAIL+1)); echo "FAIL: expected warn for unreadable path"
    }
  }
else
  PASS=$((PASS+1))  # skip if chmod ineffective (e.g. root)
fi
rm -f "$UNREAD"

# T8: C5 — PDH bootstrap-stanza drift against SPEC-002's canonical fenced block
SPEC002="$REPO_ROOT/specs/core/SPEC-002-plugin-infrastructure.md"
CANON=$(grep -m1 '^PDH=\$( {' "$SPEC002")
[ -n "$CANON" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: no canonical stanza in $SPEC002"; }
DECOY='PDH=$( { decoy-block-that-is-not-the-canonical-stanza; } )'
C3W='# lint-ok: C3 — marketplace */ for-loop + -f guarded'

# 1. Mutated-byte fixture bites; C3 waiver does not suppress C5; C5 waiver does
run_lint 1 "$FIX/c5-pdh-drift.md"
expect_finding C5 "c5-pdh-drift.md:9"
[ "$(echo "$OUT" | grep -c '\[C5\]')" -eq 1 ] && PASS=$((PASS+1)) || {
  FAIL=$((FAIL+1)); echo "FAIL: expected exactly 1 unwaived C5, got:"; echo "$OUT" | grep '\[C5\]'
}

# 2. Indentation tolerance: canonical at 0/2/4-space indent → no C5
T8A=$(mktemp -d)
{ printf '```bash\n%s\n%s\n```\n' "$C3W" "$CANON"
  printf '```bash\n  %s\n  %s\n```\n' "$C3W" "$CANON"
  printf '```bash\n    %s\n    %s\n```\n' "$C3W" "$CANON"; } > "$T8A/indent.md"
run_lint 0 "$T8A/indent.md"
expect_no_finding C5

# 3. Anchor bite-test: SPEC-002 holds MORE THAN ONE fenced bash block. Anchoring on
#    "first block in the file" would extract the decoy and compare every emission
#    against garbage while still exiting 0. Decoys sit both before and after the
#    canonical section here; a correct heading anchor ignores both.
T8B=$(mktemp -d)
mkdir -p "$T8B/specs/core" "$T8B/commands"
{ printf '# SPEC-002\n\n## Overview\n\n```bash\n%s\n```\n\n' "$DECOY"
  printf '### Locating `plugin-dir.sh` itself\n\n```bash\n# canonical\n%s\n```\n\n' "$CANON"
  printf '### Caller integration\n\n```bash\n%s\n```\n' "$DECOY"; } \
  > "$T8B/specs/core/SPEC-002-plugin-infrastructure.md"
printf '```bash\n%s\n%s\n```\n' "$C3W" "$CANON" > "$T8B/commands/site.md"
run_lint 0 --root "$T8B"
expect_no_finding C5
expect_no_vacuity "heading anchor did not resolve past the decoy blocks"

# 4. Vacuous-gate guard: canonical unresolvable + a live PDH stanza → loud non-zero,
#    never a silent pass. Three ways to break it, each must be distinct and fatal.
for BREAK in missing-spec broken-heading no-fence; do
  T8C=$(mktemp -d)
  mkdir -p "$T8C/specs/core" "$T8C/commands"
  printf '```bash\n%s\n%s\n```\n' "$C3W" "$CANON" > "$T8C/commands/site.md"
  case "$BREAK" in
    broken-heading)
      printf '### Finding plugin-dir.sh\n\n```bash\n%s\n```\n' "$CANON" \
        > "$T8C/specs/core/SPEC-002-plugin-infrastructure.md" ;;
    no-fence)
      printf '### Locating `plugin-dir.sh` itself\n\nProse only, no fenced block.\n' \
        > "$T8C/specs/core/SPEC-002-plugin-infrastructure.md" ;;
  esac
  run_lint 1 --root "$T8C"
  expect_vacuity "$BREAK did not report an unresolvable canonical"
  rm -rf "$T8C"
done

# 5. A `# lint-ok: C5` waiver must NOT rescue an unresolvable canonical (that would
#    re-hide the vacuity the guard exists to expose)
T8D=$(mktemp -d)
mkdir -p "$T8D/commands"
printf '```bash\n# lint-ok: C3,C5\n%s\n```\n' "$CANON" > "$T8D/commands/site.md"
run_lint 1 --root "$T8D"
expect_vacuity "C5 waiver silenced the vacuous-gate guard"
rm -rf "$T8D"

# 6. Exclusions: the locator and its test harness are exempt (they cannot bootstrap
#    themselves / hold a deliberately re-quoted copy). Control proves the test bites.
#    Fenced-md bodies in .sh paths: the file-list form scans any path handed to it.
T8E=$(mktemp -d)
mkdir -p "$T8E/skills"
printf '```bash\n%s\n%s\n```\n' "$C3W" "${CANON/k1,1V -k2,2n/k1,1n -k2,2n}" > "$T8E/skills/plugin-dir.sh"
cp "$T8E/skills/plugin-dir.sh" "$T8E/skills/plugin-dir-test.sh"
cp "$T8E/skills/plugin-dir.sh" "$T8E/skills/other.sh"
run_lint 0 --root "$REPO_ROOT" "$T8E/skills/plugin-dir.sh" "$T8E/skills/plugin-dir-test.sh"
expect_no_finding C5
run_lint 1 --root "$REPO_ROOT" "$T8E/skills/other.sh"
expect_finding C5 "other.sh"
rm -rf "$T8E" "$T8A" "$T8B"

# 7. Live-tree baseline: zero UNWAIVED C5 on the real tree (gate lands green)
OUT=$(bash "$LINT" --root "$REPO_ROOT" 2>&1); RC=$?
expect_no_finding C5
expect_no_vacuity "live tree cannot resolve the SPEC-002 canonical stanza"

echo "---"
echo "skill-lint tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
