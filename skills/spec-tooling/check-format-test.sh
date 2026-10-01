#!/usr/bin/env bash
# Bite tests for skills/spec-tooling/check-format.sh (CDT-273).
# The two fixtures were previously unwired. A checkbox or a date table
# outside its own section must not satisfy that section.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
FMT="$HERE/check-format.sh"
FIX="$HERE/fixtures"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

RC=0
bash "$FMT" "$FIX/pre-fix-baseline.spec.md" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 1 ] && pass "pre-fix fixture exits 1" || fail "pre-fix fixture rc=$RC want 1"

RC=0
bash "$FMT" "$FIX/post-fix.spec.md" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 0 ] && pass "post-fix fixture exits 0" || fail "post-fix fixture rc=$RC want 0"

# Section scope: the only checkbox sits under Open Questions, after Validation.
TMP=$(mktemp -d "${TMPDIR:-/tmp}/check-format-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/outside.md" << 'EOF'
# SPEC-099: Outside

**Status**: DRAFT
**Category**: core
**Created**: 2026-10-01

## Overview

x

## MUST

- MUST do the thing

## Test

- one check

## Validation

## Open Questions

- [ ] this checkbox is not in Validation

## Version History

| Date | Change |
|------|--------|
| 2026-10-01 | start |
EOF
RC=0
bash "$FMT" "$TMP/outside.md" >/dev/null 2>"$TMP/err" || RC=$?
if [ "$RC" -eq 1 ] && grep -q 'Validation' "$TMP/err"; then
  pass "checkbox outside Validation does not count"
else
  fail "outside checkbox rc=$RC err=$(cat "$TMP/err")"
fi

# Control: the same checkbox moved into Validation passes.
cat > "$TMP/inside.md" << 'EOF'
# SPEC-099: Inside

**Status**: DRAFT
**Category**: core
**Created**: 2026-10-01

## Overview

x

## MUST

- MUST do the thing

## Test

- one check

## Validation

- [ ] reviewed

## Version History

| Date | Change |
|------|--------|
| 2026-10-01 | start |
EOF
RC=0
bash "$FMT" "$TMP/inside.md" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 0 ] && pass "checkbox inside Validation passes" || fail "inside checkbox rc=$RC"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
