#!/usr/bin/env bash
# Bite tests for skills/spec-tooling/check-format.sh (CDT-273, retired-checkbox
# gate). A claim bullet or a date table outside its own section must not
# satisfy that section; a legacy `- [ ]` under Validation/Test must fail.
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

# Section scope: an empty Validation section fails, and a claim bullet under
# Open Questions must not satisfy Validation.
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
  pass "empty Validation section fails; Open Questions claim does not count"
else
  fail "outside claim rc=$RC err=$(cat "$TMP/err")"
fi

# Control: a plain validation claim inside Validation passes.
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

- Spec reviewed against the shipped ACs; evidence: test log attached

## Version History

| Date | Change |
|------|--------|
| 2026-10-01 | start |
EOF
RC=0
bash "$FMT" "$TMP/inside.md" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 0 ] && pass "validation claim inside Validation passes" || fail "inside claim rc=$RC"

# Retirement gate: a legacy checkbox under Validation or Test fails.
cat > "$TMP/legacy-v.md" << 'EOF'
# SPEC-099: Legacy Validation

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
bash "$FMT" "$TMP/legacy-v.md" >/dev/null 2>"$TMP/err" || RC=$?
if [ "$RC" -eq 1 ] && grep -q 'retired checkbox' "$TMP/err"; then
  pass "legacy checkbox under Validation fails (retirement enforced)"
else
  fail "legacy Validation rc=$RC err=$(cat "$TMP/err")"
fi

cat > "$TMP/legacy-t.md" << 'EOF'
# SPEC-099: Legacy Test

**Status**: DRAFT
**Category**: core
**Created**: 2026-10-01

## Overview

x

## MUST

- MUST do the thing

## Test

- [ ] one check

## Validation

- Spec reviewed; evidence: attached run log

## Version History

| Date | Change |
|------|--------|
| 2026-10-01 | start |
EOF
RC=0
bash "$FMT" "$TMP/legacy-t.md" >/dev/null 2>"$TMP/err" || RC=$?
if [ "$RC" -eq 1 ] && grep -q 'retired checkbox' "$TMP/err"; then
  pass "legacy checkbox under Test fails (retirement enforced)"
else
  fail "legacy Test rc=$RC err=$(cat "$TMP/err")"
fi

# Retirement gate shapes: indented checkbox and `* [ ]` also fail.
legacy_shape() { # legacy_shape NAME LINE
  cat > "$TMP/shape.md" << EOF
# SPEC-099: Legacy $1

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

- Spec reviewed; evidence: attached run log

$2

## Version History

| Date | Change |
|------|--------|
| 2026-10-01 | start |
EOF
  RC=0
  bash "$FMT" "$TMP/shape.md" >/dev/null 2>"$TMP/err" || RC=$?
  if [ "$RC" -eq 1 ] && grep -q 'retired checkbox' "$TMP/err"; then
    pass "legacy $1 fails (retirement enforced)"
  else
    fail "legacy $1 rc=$RC err=$(cat "$TMP/err")"
  fi
}
legacy_shape "indented checkbox under Test" "  - [ ] nested check"
legacy_shape "asterisk checkbox under Validation" "* [ ] starred claim"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
