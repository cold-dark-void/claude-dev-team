#!/usr/bin/env bash
# Category token, --gate pairing, and stale consumer names (WP 5-05).
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s — %s\n' "$1" "$2"; }

expect_cat() {
  local want="$1" arg="$2" name="$3" got
  got=$(bash "$HERE/category.sh" "$arg") || { fail "$name" "rc"; return; }
  [ "$got" = "$want" ] && pass "$name" || fail "$name" "got=$got want=$want"
}

expect_cat perf "specs/performance/PERF-001-latency.md" "performance path is perf"
expect_cat safe "SAFE-004" "SAFE id is safe"
expect_cat compat "specs/compatibility/COMPAT-002-hosts.md" "compatibility path is compat"
expect_cat arch "ARCH-001" "ARCH id is arch"
expect_cat core "SPEC-010" "SPEC id is core"
expect_cat core "specs/core/SPEC-010-x.md" "core path is core"

skel=$(sed -n '/^```markdown$/,/^```$/p' "$HERE/spec-skeleton.md")
printf '%s\n' "$skel" | grep -qxF '**Category**: <CATEGORY>' \
  && pass "skeleton keeps the category token" \
  || fail "skeleton token" "missing"

for f in "$HERE/modes/generate.md" "$HERE/modes/create.md"; do
  if grep -q 'skills/spec-tooling/category.sh' "$f" \
     && grep -q 'Do not write `core` for a PERF' "$f"; then
    pass "render instruction in $(basename "$f")"
  else
    fail "render instruction" "$f"
  fi
done

# Write a non-core spec the way /spec create is told to, then read the field.
TMP=$(mktemp -d "${TMPDIR:-/tmp}/category-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
dest="$TMP/specs/performance/PERF-001-latency.md"
mkdir -p "$(dirname "$dest")"
catg=$(bash "$HERE/category.sh" "$dest")
cat > "$dest" <<EOF
# PERF-001: Latency

**Status**: DRAFT
**Category**: ${catg}
**Created**: 2026-10-01

## Overview

Latency bound.

## MUST

- MUST answer within 50 ms

## Test

- one check

## Validation

- [ ] reviewed

## Version History

| Date | Change |
|------|--------|
| 2026-10-01 | start |
EOF
grep -qxF '**Category**: perf' "$dest" \
  && pass "created non-core spec category is perf" \
  || fail "created spec" "$(grep Category "$dest")"
bash "$HERE/check-format.sh" "$dest" >/dev/null \
  && pass "created spec passes format check" \
  || fail "format" "rc=$?"

rc=0
out=$(bash "$HERE/check-gate.sh" --gate 2>&1) || rc=$?
[ "$rc" -eq 64 ] && printf '%s' "$out" | grep -qxF 'error: --gate requires --tests' \
  && pass "gate without tests is a hard failure" \
  || fail "gate alone" "rc=$rc out=$out"

rc=0
bash "$HERE/check-gate.sh" --tests --gate >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && pass "gate with tests is allowed" || fail "gate with tests" "rc=$rc"

rc=0
bash "$HERE/check-gate.sh" --gate=5 >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 64 ] && pass "gate=N without tests fails" || fail "gate=N" "rc=$rc"

# Removed command names must not remain in this skill tree.
# This test's own pattern is excluded so the assertion can name them.
hits=$(grep -R -n -E 'create-spec|generate-specs|check-specs|update-spec|reflect-specs' \
  "$HERE" --exclude 'category-test.sh' || true)
[ -z "$hits" ] && pass "no removed command names in spec-tooling" \
  || fail "stale names" "$hits"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
