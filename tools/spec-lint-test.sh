#!/usr/bin/env bash
# Bite for tools/spec-lint.sh (CDT-273).
# A checkbox that sits only under Open Questions must fail format.
# Backwards dates, a missing Covers path, and "SPEC-N line M" must fail too.
# A clean mini tree must exit 0.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
LINT="$REPO/tools/spec-lint.sh"
BASE=$(mktemp -d "${TMPDIR:-/tmp}/spec-lint-test.XXXXXX")
trap 'rm -rf "$BASE"' EXIT
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

seed() { # seed DEST
  local dest=$1
  mkdir -p "$dest/specs/core" "$dest/skills/spec-tooling" \
    "$dest/skills" "$dest/commands" "$dest/agents" "$dest/tools"
  cp "$REPO/skills/spec-tooling/check-format.sh" "$dest/skills/spec-tooling/check-format.sh"
  printf '%s\n' '# agents' > "$dest/AGENTS.md"
  cat > "$dest/specs/TDD.md" << 'EOF'
| ID | Title | Status | Coverage |
|----|-------|--------|----------|
| SPEC-001 | Clean title | ACTIVE | x |
EOF
  cat > "$dest/specs/core/SPEC-001-clean.md" << 'EOF'
# SPEC-001: Clean title

**Status**: ACTIVE
**Category**: core
**Created**: 2026-10-01

**Covers**: `skills/spec-tooling/check-format.sh`

## Overview

Clean.

## MUST

- MUST stay clean

## Test

- the format script exists

## Validation

- [x] reviewed

## Version History

| Date | Change |
|------|--------|
| 2026-10-01 | initial |
| 2026-09-01 | older
EOF
}

seed "$BASE/clean"
OUT=$(bash "$LINT" --root "$BASE/clean" 2>&1)
RC=$?
[ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -q 'spec-lint: clean' \
  && pass "clean tree exits 0" || fail "clean tree rc=$RC out=$OUT"

seed "$BASE/bad"
cat > "$BASE/bad/specs/core/SPEC-002-bad.md" << 'EOF'
# SPEC-002: Bad title

**Status**: DRAFT
**Category**: core
**Created**: 2026-10-01

**Covers**: `skills/missing-skill/SKILL.md`

## Overview

Bad.

## MUST

- MUST be caught

## Test

- planted

## Validation

No checkbox here.

## Open Questions

- [ ] this checkbox is not Validation

## Version History

| Date | Change |
|------|--------|
| 2026-02-01 | newest head |
| 2026-01-01 | older |
| 2026-03-01 | breaks newest-first
EOF
printf '%s\n' 'See SPEC-001' 'line 9 for the wrapped citation.' > "$BASE/bad/skills/note.md"

OUT=$(bash "$LINT" --root "$BASE/bad" 2>&1)
RC=$?
[ "$RC" -eq 1 ] && pass "bad tree exits 1" || fail "bad tree rc=$RC want 1"
printf '%s\n' "$OUT" | grep -q '\[format\]' \
  && pass "format names the section-scoped checkbox" || fail "no [format]: $OUT"
printf '%s\n' "$OUT" | grep -q '\[history\]' \
  && pass "history names the broken date order" || fail "no [history]: $OUT"
printf '%s\n' "$OUT" | grep -q '\[covers\]' \
  && pass "covers names the missing path" || fail "no [covers]: $OUT"
printf '%s\n' "$OUT" | grep -q '\[citation\]' \
  && pass "citation names the line anchor" || fail "no [citation]: $OUT"

# An index row with no file must fail the run (not only print a line).
seed "$BASE/orphan"
printf '%s\n' '| SPEC-099 | Nowhere | DRAFT | x |' >> "$BASE/orphan/specs/TDD.md"
OUT=$(bash "$LINT" --root "$BASE/orphan" 2>&1)
RC=$?
[ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q '\[index\].*SPEC-099' \
  && pass "orphan index row exits 1" || fail "orphan index rc=$RC out=$OUT"

# CDT-294 negative control: an archived spec is NOT linted. A file under
# specs/archive/ carrying every violation class must produce zero findings —
# and its TDD.md row must still resolve (the file exists, in the archive).
seed "$BASE/archived"
mkdir -p "$BASE/archived/specs/archive"
cat > "$BASE/archived/specs/archive/SPEC-090-retired.md" << 'EOF'
# SPEC-090: Wrong Title

**Status**: DRAFT
**Category**: core
**Created**: 2026-10-01

**Covers**: `skills/missing-thing/SKILL.md`

## Overview

Bad.

## MUST

- MUST be skipped

## Test

- planted

## Validation

No checkbox here.

## Open Questions

- [ ] checkbox outside Validation

## Version History

| Date | Change |
|------|--------|
| 2026-03-01 | newest head |
| 2026-01-01 | older |
| 2026-02-01 | breaks order
EOF
printf '%s\n' '| SPEC-090 | Wrong Title | DRAFT | x |' >> "$BASE/archived/specs/TDD.md"
OUT=$(bash "$LINT" --root "$BASE/archived" 2>&1)
RC=$?
[ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -q 'spec-lint: clean' \
  && pass "archived spec file is not linted" || fail "archived rc=$RC out=$OUT"
if printf '%s\n' "$OUT" | grep -q 'SPEC-090'; then
  fail "archived spec mentioned in findings"
else
  pass "findings never name the archived file"
fi

echo "spec-lint tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
