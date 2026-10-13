#!/usr/bin/env bash
# Bite tests for skills/spec-tooling/check-ac-clauses.sh
# (spec-ac-uncheckable-clause-lint). Technical ACs with a style-only clause
# (ASD-STE100 / Simplified Technical English) are flagged with both
# remedies; [process] ACs, non-AC sections and checkable clauses are not.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CHK="$HERE/check-ac-clauses.sh"
FIX="$HERE/fixtures"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/check-ac-clauses-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# Flag fixture: exactly AC H (ASD-STE100) and AC K (lowercase, on a
# continuation) are flagged; AC G is checkable, AC I is [process], and the
# ASD-STE100 mention under ## MUST is outside the AC section.
OUT=$(bash "$CHK" "$FIX/ac-style-flag.md" 2>&1 1>/dev/null); RC=$?
[ "$RC" -eq 1 ] && pass "flag fixture exits 1" || fail "flag fixture rc=$RC want 1"
[ "$(printf '%s\n' "$OUT" | wc -l)" -eq 2 ] \
  && pass "flag fixture reports exactly two findings" \
  || fail "flag fixture findings: $OUT"
printf '%s\n' "$OUT" | grep -q ': AC H (line' \
  && pass "AC H flagged" || fail "AC H not flagged: $OUT"
printf '%s\n' "$OUT" | grep -q ': AC K (line' \
  && pass "AC K flagged (lowercase pattern, continuation line)" \
  || fail "AC K not flagged: $OUT"
printf '%s\n' "$OUT" | grep -q 'a Verify line does not clear it: move the sentence to a \[process\] AC or delete it' \
  && pass "finding names both remedies" || fail "no remedies in: $OUT"
if printf '%s\n' "$OUT" | grep -q 'AC G\|AC I'; then
  fail "checkable AC G or [process] AC I flagged: $OUT"
else
  pass "AC G and [process] AC I stay clean"
fi

# Control fixture: zero findings, exit 0, nothing on stdout or stderr.
OUT=$(bash "$CHK" "$FIX/ac-style-clean.md" 2>&1 >/dev/null); RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  pass "control fixture exits 0, silent"
else
  fail "control rc=$RC out=$OUT"
fi

# A Verify line naming a style-standard-looking suite is a command, not AC
# prose: it must not join the match text and must stay clean.
cat > "$TMP/verifyline.md" << 'EOF'
# SPEC-099: Verify line naming

**Status**: DRAFT
**Category**: core
**Created**: 2026-10-12

## Acceptance criteria

### T-fix

- **A.** The diff adds the style checker and runs it in CI.
  Verify: bash skills/spec-tooling/test-asd-ste100.sh

## Test

- the verify-line fixture exists

## Validation

- reviewed; evidence: check-ac-clauses-test.sh run attached

## Version History

| Date | Change |
|------|--------|
| 2026-10-12 | x |
EOF
OUT=$(bash "$CHK" "$TMP/verifyline.md" 2>&1 >/dev/null); RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] \
  && pass "Verify line naming test-asd-ste100.sh stays clean" \
  || fail "verify-line rc=$RC out=$OUT"

# No ## Acceptance criteria section: clean.
cat > "$TMP/noac.md" << 'EOF'
# SPEC-099: No AC

**Status**: DRAFT
**Category**: core
**Created**: 2026-10-12

## Overview

The text follows ASD-STE100.

## Version History

| Date | Change |
|------|--------|
| 2026-10-12 | x |
EOF
OUT=$(bash "$CHK" "$TMP/noac.md" 2>&1 >/dev/null); RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] \
  && pass "no ## Acceptance criteria section is clean" \
  || fail "no-AC rc=$RC out=$OUT"

# Usage errors: 0 args, 2 args, missing file.
bash "$CHK" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 64 ] && pass "0 args exits 64" || fail "0 args rc=$RC"
bash "$CHK" a b >/dev/null 2>&1; RC=$?
[ "$RC" -eq 64 ] && pass "2 args exits 64" || fail "2 args rc=$RC"
bash "$CHK" "$TMP/absent.md" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 64 ] && pass "missing file exits 64" || fail "missing file rc=$RC"

# Findings go to stderr only (spec-lint captures stderr, discards stdout).
OUT=$(bash "$CHK" "$FIX/ac-style-flag.md" 2>/dev/null)
[ -z "$OUT" ] && pass "findings never go to stdout" || fail "stdout finding: $OUT"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
