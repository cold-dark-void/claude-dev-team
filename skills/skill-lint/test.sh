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

echo "---"
echo "skill-lint tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
