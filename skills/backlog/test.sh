#!/usr/bin/env bash
# skills/backlog/test.sh — unit tests for close.sh
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLOSE="$HERE/close.sh"
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

assert_file_match() {
  local name="$1" file="$2" pat="$3"
  if grep -qE "$pat" "$file"; then pass "$name"
  else fail "$name" "pattern /$pat/ not in $file"
  fi
}

assert_file_nomatch() {
  local name="$1" file="$2" pat="$3"
  if grep -qE "$pat" "$file"; then fail "$name" "pattern /$pat/ unexpectedly in $file"
  else pass "$name"
  fi
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/backlog-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

setup_fixture() {
  local root="$1"
  mkdir -p "$root/.claude/backlog"
  cat > "$root/.claude/backlog.md" <<'EOF'
# Fixture - Backlog Index

## Pending

### Group A
- [Sort dropdown](backlog/sort-dropdown.md) - Sort when queue view is on [PENDING]
- [Dark mode](backlog/dark-mode.md) - Add dark mode [PENDING]

## Completed

- [Old item](backlog/old-item.md) - Already done [COMPLETED]
EOF

  cat > "$root/.claude/backlog/sort-dropdown.md" <<'EOF'
# Sort dropdown

**Status**: PENDING

## Problem

Sort is wrong.

## Goal

Sorted list.

---

*Added: 2026-07-01*
EOF

  cat > "$root/.claude/backlog/dark-mode.md" <<'EOF'
# Dark mode

**Status**: PENDING

## Problem

No dark theme.

## Goal

Dark theme.

---

*Added: 2026-07-01*
EOF

  cat > "$root/.claude/backlog/old-item.md" <<'EOF'
# Old item

**Status**: COMPLETED

## Problem

x

## Goal

y

---

*Added: 2026-01-01*
*Closed: 2026-02-01*
EOF
}

echo "== close.sh tests =="

# --- close pending ---
R1="$TMP/r1"
setup_fixture "$R1"
out=$(bash "$CLOSE" sort-dropdown --root "$R1" --ticket BHR-1 --status FIXED/CLOSED)
assert_eq "close stdout" "Closed: .claude/backlog/sort-dropdown.md" "$out"
assert_file_match "item FIXED/CLOSED" "$R1/.claude/backlog/sort-dropdown.md" 'Status\*\*: FIXED/CLOSED \(BHR-1\)'
assert_file_match "item Closed footer" "$R1/.claude/backlog/sort-dropdown.md" '^\*Closed:'
# line with sort-dropdown should carry closed tag (moved to Completed)
assert_file_match "index closed tag" "$R1/.claude/backlog.md" 'sort-dropdown\.md\).*FIXED/CLOSED — BHR-1'
assert_file_match "group header preserved" "$R1/.claude/backlog.md" '### Group A'
assert_file_match "sibling still pending" "$R1/.claude/backlog.md" 'dark-mode\.md\).*\[PENDING\]'

# --- verify closed ---
if bash "$CLOSE" verify sort-dropdown --root "$R1" >/dev/null; then
  pass "verify closed exit 0"
else
  fail "verify closed exit 0" "exit $?"
fi

# --- verify open ---
if bash "$CLOSE" verify dark-mode --root "$R1" >/dev/null 2>&1; then
  fail "verify open exit 1" "expected non-zero"
else
  pass "verify open exit 1"
fi

# --- idempotent close ---
out2=$(bash "$CLOSE" sort-dropdown --root "$R1" --ticket BHR-1 --status FIXED/CLOSED)
assert_eq "idempotent stdout" "Already closed: .claude/backlog/sort-dropdown.md" "$out2"
# status still one line closed
c=$(grep -c 'FIXED/CLOSED' "$R1/.claude/backlog/sort-dropdown.md" || true)
if [ "$c" -ge 1 ]; then pass "idempotent keeps closed status"
else fail "idempotent keeps closed status" "count=$c"
fi

# --- close by title fragment ---
R2="$TMP/r2"
setup_fixture "$R2"
out3=$(bash "$CLOSE" "dark mode" --root "$R2")
assert_eq "title match stdout" "Closed: .claude/backlog/dark-mode.md" "$out3"
assert_file_match "title match COMPLETED" "$R2/.claude/backlog/dark-mode.md" 'Status\*\*: COMPLETED'

# --- --root isolation ---
R3="$TMP/r3a"
R4="$TMP/r3b"
setup_fixture "$R3"
setup_fixture "$R4"
bash "$CLOSE" sort-dropdown --root "$R3" >/dev/null
if bash "$CLOSE" verify sort-dropdown --root "$R3" >/dev/null \
  && ! bash "$CLOSE" verify sort-dropdown --root "$R4" >/dev/null 2>&1; then
  pass "root isolation"
else
  fail "root isolation" "R3 should be closed, R4 open"
fi

# --- missing ---
if bash "$CLOSE" no-such-item --root "$R1" >/dev/null 2>&1; then
  fail "missing item exit 1" "expected non-zero"
else
  pass "missing item exit 1"
fi

# --- usage ---
if bash "$CLOSE" >/dev/null 2>&1; then
  fail "usage no args" "expected 64"
else
  rc=$?
  if [ "$rc" -eq 64 ]; then pass "usage exit 64"
  else fail "usage exit 64" "got $rc"
  fi
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
