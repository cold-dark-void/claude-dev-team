#!/usr/bin/env bash
# Bite for tools/spec-lint.sh (CDT-273).
# An empty Validation section must fail format; retired checkbox syntax is
# gated by check-format.sh. Backwards dates, a missing Covers path, and
# "SPEC-N line M" must fail too. A clean mini tree must exit 0.
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
    "$dest/skills/council" "$dest/skills" "$dest/commands" "$dest/agents" "$dest/tools"
  cp "$REPO/skills/spec-tooling/check-format.sh" "$dest/skills/spec-tooling/check-format.sh"
  cp "$REPO/skills/spec-tooling/check-ac-clauses.sh" "$dest/skills/spec-tooling/check-ac-clauses.sh"
  cp "$REPO/skills/council/m14-ac-split.sh" "$dest/skills/council/m14-ac-split.sh"
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

- reviewed; evidence: format gate run attached

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
  && pass "format names the empty Validation section" || fail "no [format]: $OUT"
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

# CDT-522 + spec-ac-uncheckable-clause-lint: the two advisory checks WARN
# and keep rc 0. Needs a git tree — the m14 check resolves the AC path
# against the worktree top level (and is skipped in the non-git seeds
# above, which must stay clean).
seed "$BASE/advisory"
git -C "$BASE/advisory" init -q
mkdir -p "$BASE/advisory/skills/x"
: > "$BASE/advisory/skills/x/test-y.sh"
cat > "$BASE/advisory/specs/core/SPEC-001-clean.md" << 'EOF'
# SPEC-001: Clean title

**Status**: ACTIVE
**Category**: core
**Created**: 2026-10-01

## Overview

Advisory-check fixture.

## MUST

- MUST stay clean under the gating checks

## Acceptance criteria

### T-good

- **A.** The diff adds a widget and `stat` shows mode 600 on the token file.
  Verify: bash skills/x/test-y.sh

### T-prose

- **A.** The diff adds a widget.

Captured history note at column zero, not a bullet or continuation.

### T-guard

- **A.** The diff adds a widget.
- **B.** [process] Approvals are recorded on the ticket.

### T-verify

- **C.** The diff adds a widget.
  Verify: bash skills/x/test-y.sh ; rm -rf /tmp/x

### T-absent

- **E.** The diff adds a widget.
  Verify: bash skills/absent/test-z.sh

### T-style

- **D.** The diff adds a widget. The text follows ASD-STE100.

## Test

- the advisory fixtures exist

## Validation

- reviewed; evidence: spec-lint-test.sh run attached

## Version History

| Date | Change |
|------|--------|
| 2026-10-12 | advisory fixture |
EOF
OUT=$(bash "$LINT" --root "$BASE/advisory" 2>&1); RC=$?
[ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -q 'spec-lint: clean' \
  && pass "advisory warnings keep rc 0" || fail "advisory rc=$RC out=$OUT"
printf '%s\n' "$OUT" | grep -q '\[m14-ac\] WARN: ### T-prose: m14-ac-split: case 5:' \
  && pass "m14 advisory warns on prose in an AC subsection" || fail "no case 5 warn: $OUT"
printf '%s\n' "$OUT" | grep -q '\[m14-ac\] WARN: ### T-guard: m14-ac-split: case 8:' \
  && pass "m14 advisory warns on [process] AC failing guard 1" || fail "no case 8 warn: $OUT"
printf '%s\n' "$OUT" | grep -q '\[m14-ac\] WARN: ### T-verify: m14-ac-split: case 10: AC C: a Verify line breaks' \
  && pass "m14 advisory warns on a Verify line breaking the grammar" || fail "no case 10 grammar warn: $OUT"
printf '%s\n' "$OUT" | grep -q '\[m14-ac\] WARN: ### T-absent: m14-ac-split: case 10: AC E: the Verify path fails' \
  && pass "m14 advisory warns on a Verify path absent from the worktree" || fail "no case 10 path warn: $OUT"
printf '%s\n' "$OUT" | grep -q '\[ac-style\] WARN: AC D' \
  && pass "ac-style advisory warns on the style-only clause" || fail "no ac-style warn: $OUT"
if printf '%s\n' "$OUT" | grep -q '### T-good'; then
  fail "valid subsection T-good warned: $OUT"
else
  pass "valid subsection T-good stays silent"
fi
if printf '%s\n' "$OUT" | grep -q '^\S*: \[format\]'; then
  fail "advisory fixture tripped a gating check: $OUT"
else
  pass "advisory fixture trips no gating check"
fi

echo "spec-lint tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
