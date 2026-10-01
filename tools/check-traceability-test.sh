#!/usr/bin/env bash
# Bite: the report lists an id with no tag, stays quiet once tagged, and
# exits 0 in both cases (report-only; a non-zero exit is a failure).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CHECK="$HERE/check-traceability.sh"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/trace-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

mkdir -p "$ROOT/specs/core" "$ROOT/skills/ac"
cat > "$ROOT/specs/core/SPEC-001-x.md" << 'EOF'
# SPEC-001: X
## Test
- SPEC-001/T9 — the thing.
- SPEC-001/M2 — the other.
EOF

OUT=$(bash "$CHECK" --root "$ROOT")
RC=$?
[ "$RC" -eq 0 ] && pass "untagged tree exits 0" || fail "untagged tree rc=$RC want 0"
printf '%s\n' "$OUT" | grep -qx 'uncovered: SPEC-001/T9' \
  && pass "prints uncovered T9" || fail "missing uncovered T9: $OUT"
printf '%s\n' "$OUT" | grep -qx 'uncovered: SPEC-001/M2' \
  && pass "prints uncovered M2" || fail "missing uncovered M2: $OUT"

printf '%s\n' '# covers: SPEC-001/T9' > "$ROOT/skills/ac/test-ac.sh"
OUT=$(bash "$CHECK" --root "$ROOT")
RC=$?
[ "$RC" -eq 0 ] && pass "partial cover still exits 0" || fail "partial rc=$RC want 0"
printf '%s\n' "$OUT" | grep -q 'SPEC-001/T9' \
  && fail "tagged T9 still listed: $OUT" || pass "tagged T9 is not listed"
printf '%s\n' "$OUT" | grep -qx 'uncovered: SPEC-001/M2' \
  && pass "untagged M2 still listed" || fail "M2 dropped: $OUT"

printf '%s\n' '# covers: SPEC-001/M2' >> "$ROOT/skills/ac/test-ac.sh"
OUT=$(bash "$CHECK" --root "$ROOT")
RC=$?
[ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -q 'traceability: clean (report only)' \
  && pass "full cover is clean and exits 0" || fail "full cover: rc=$RC out=$OUT"

# A comment in the spec is not a cover.
printf '%s\n' '# covers: SPEC-001/T9' >> "$ROOT/specs/core/SPEC-001-x.md"
# Remove the test tag so only the spec mentions the cover line.
printf '%s\n' '# covers: SPEC-001/M2' > "$ROOT/skills/ac/test-ac.sh"
OUT=$(bash "$CHECK" --root "$ROOT")
printf '%s\n' "$OUT" | grep -qx 'uncovered: SPEC-001/T9' \
  && pass "a spec line is not a cover" || fail "spec comment counted as a cover: $OUT"

bash "$CHECK" --root /no/such/trace-root >/dev/null 2>&1
RC=$?
[ "$RC" -eq 64 ] && pass "bad --root exits 64" || fail "bad --root rc=$RC want 64"

echo "check-traceability tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
