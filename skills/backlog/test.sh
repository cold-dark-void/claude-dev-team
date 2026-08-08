#!/usr/bin/env bash
# skills/backlog/test.sh — unit tests for close.sh
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLOSE="$HERE/close.sh"
TS="$HERE/terminal-status.sh"
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

# Assert terminal-status.sh is-closed exit code (0 closed / 1 open / 64 usage).
assert_ts_rc() {
  local name="$1" want_rc="$2"
  shift 2
  local rc
  set +e
  bash "$TS" "$@" >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "$name" "$want_rc" "$rc"
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

echo "== terminal-status.sh unit tests (CDT-160) =="

# Closed terminals (AC2 / AC5 token-match)
assert_ts_rc "ts COMPLETED closed" 0 is-closed COMPLETED
assert_ts_rc "ts completed closed" 0 is-closed completed
assert_ts_rc "ts COMPLETED (CDT-1) closed" 0 is-closed "COMPLETED (CDT-1)"
assert_ts_rc "ts DONE closed" 0 is-closed DONE
assert_ts_rc "ts done closed" 0 is-closed done
assert_ts_rc "ts DONE — note closed" 0 is-closed "DONE — note"
assert_ts_rc "ts DONE (CDT-1) closed" 0 is-closed "DONE (CDT-1)"
assert_ts_rc "ts FIXED/CLOSED closed" 0 is-closed "FIXED/CLOSED"
assert_ts_rc "ts FIXED-CLOSED closed" 0 is-closed "FIXED-CLOSED"
assert_ts_rc "ts FIXED CLOSED closed" 0 is-closed "FIXED CLOSED"
assert_ts_rc "ts FIXED/CLOSED (BHR-1) closed" 0 is-closed "FIXED/CLOSED (BHR-1)"
assert_ts_rc "ts FIXED/CLOSED (X) closed" 0 is-closed "FIXED/CLOSED (X)"
assert_ts_rc "ts CLOSED closed" 0 is-closed CLOSED
assert_ts_rc "ts CANCELLED closed" 0 is-closed CANCELLED
assert_ts_rc "ts CANCELED closed" 0 is-closed CANCELED
assert_ts_rc "ts Canceled closed" 0 is-closed Canceled

# Open / non-terminals (AC2 / AC5)
assert_ts_rc "ts PENDING open" 1 is-closed PENDING
assert_ts_rc "ts DEFERRED open" 1 is-closed DEFERRED
assert_ts_rc "ts empty open" 1 is-closed ""
assert_ts_rc "ts UNDONE open" 1 is-closed UNDONE
assert_ts_rc "ts NOT DONE open" 1 is-closed "NOT DONE"
assert_ts_rc "ts PRECOMPLETED open" 1 is-closed PRECOMPLETED
assert_ts_rc "ts FIXED/CLOSEDX open" 1 is-closed FIXED/CLOSEDX
assert_ts_rc "ts FIXED-CLOSEDX open" 1 is-closed FIXED-CLOSEDX
assert_ts_rc "ts FIXED CLOSEDX open" 1 is-closed "FIXED CLOSEDX"

# Usage errors
assert_ts_rc "ts missing status usage" 64 is-closed
assert_ts_rc "ts no args usage" 64
assert_ts_rc "ts unknown cmd usage" 64 not-a-cmd x

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
# Index row must carry exactly one status tag after re-close (tag-strip sed must work
# with FIXED/CLOSED — ticket payload; [^\]] inside sed character classes is wrong).
idx_line=$(grep -E '\]\(backlog/sort-dropdown\.md\)' "$R1/.claude/backlog.md" | head -n1 || true)
tag_n=$(printf '%s\n' "$idx_line" | grep -oE '\[(PENDING|COMPLETED[^]]*|FIXED/CLOSED[^]]*)\]' | wc -l | tr -d ' ')
if [ "$tag_n" = "1" ]; then pass "idempotent index single status tag"
else fail "idempotent index single status tag" "tags=$tag_n line=$idx_line"
fi
assert_file_match "idempotent index keeps FIXED/CLOSED tag" "$R1/.claude/backlog.md" \
  'sort-dropdown\.md\).*\[FIXED/CLOSED — BHR-1\]'
assert_file_nomatch "idempotent index no dual FIXED/CLOSED" "$R1/.claude/backlog.md" \
  'sort-dropdown\.md\).*\[FIXED/CLOSED[^]]*\][^\n]*\[FIXED/CLOSED'

# Re-close already-FIXED/CLOSED item with default COMPLETED: strip old tag, one new tag.
bash "$CLOSE" sort-dropdown --root "$R1" >/dev/null
idx_line=$(grep -E '\]\(backlog/sort-dropdown\.md\)' "$R1/.claude/backlog.md" | head -n1 || true)
tag_n=$(printf '%s\n' "$idx_line" | grep -oE '\[(PENDING|COMPLETED[^]]*|FIXED/CLOSED[^]]*)\]' | wc -l | tr -d ' ')
if [ "$tag_n" = "1" ]; then pass "retag index single status tag"
else fail "retag index single status tag" "tags=$tag_n line=$idx_line"
fi
assert_file_match "retag index COMPLETED only" "$R1/.claude/backlog.md" \
  'sort-dropdown\.md\).*\[COMPLETED\]'
assert_file_nomatch "retag index drops FIXED/CLOSED" "$R1/.claude/backlog.md" \
  'sort-dropdown\.md\).*FIXED/CLOSED'

# --- no-blank-line-after-Status: content immediately follows **Status**: (no canonical blank line) ---
# Regression for a bug where command substitution stripped build_status_line's trailing
# newline and the awk replacement printf'd it without one, silently merging the next line
# onto the Status line. The canonical template always has a blank line after Status, which
# masked this (an empty `print` still emits a bare newline) — this fixture has none.
Rnb="$TMP/rnb"
mkdir -p "$Rnb/.claude/backlog"
cat > "$Rnb/.claude/backlog.md" <<'EOF'
# Fixture

## Pending

- [No blank](backlog/no-blank.md) - status has no trailing blank line [PENDING]

## Completed

EOF
cat > "$Rnb/.claude/backlog/no-blank.md" <<'EOF'
# No blank

**Status**: PARTIAL (something)
**Priority**: P0
**Source**: test

## Problem

x
EOF
bash "$CLOSE" no-blank --root "$Rnb" >/dev/null
assert_file_match "no-blank-line: Status line clean" "$Rnb/.claude/backlog/no-blank.md" '^\*\*Status\*\*: COMPLETED$'
assert_file_match "no-blank-line: Priority line intact on its own line" "$Rnb/.claude/backlog/no-blank.md" '^\*\*Priority\*\*: P0$'
assert_file_nomatch "no-blank-line: no merged line" "$Rnb/.claude/backlog/no-blank.md" 'COMPLETED\*\*Priority\*\*'

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

# --- write-through: preserve linear_id frontmatter + emit bridge line ---
R5="$TMP/r5"
mkdir -p "$R5/.claude/backlog"
cat > "$R5/.claude/backlog.md" <<'EOF'
# Fixture - Backlog Index

## Pending

- [Linked](backlog/linked-item.md) - has Linear id [PENDING] linear:CDT-99

## Completed

EOF
cat > "$R5/.claude/backlog/linked-item.md" <<'EOF'
---
linear_id: CDT-99
epic_parent: CDT-46
---

# Linked

**Status**: PENDING

## Problem

Dual-write fixture.

## Goal

Close preserves linkage.

---

*Added: 2026-07-01*
EOF
out5=$(bash "$CLOSE" linked-item --root "$R5" --ticket CDT-99 --status FIXED/CLOSED)
# stdout: Closed line + linear_id bridge for session Linear Done
if printf '%s\n' "$out5" | grep -qE '^Closed: \.claude/backlog/linked-item\.md$'; then
  pass "write-through close stdout"
else
  fail "write-through close stdout" "got=$out5"
fi
if printf '%s\n' "$out5" | grep -qE '^linear_id: CDT-99$'; then
  pass "write-through linear_id bridge"
else
  fail "write-through linear_id bridge" "got=$out5"
fi
assert_file_match "write-through preserves linear_id" "$R5/.claude/backlog/linked-item.md" '^linear_id: CDT-99'
assert_file_match "write-through preserves epic_parent" "$R5/.claude/backlog/linked-item.md" '^epic_parent: CDT-46'
assert_file_match "write-through status FIXED/CLOSED" "$R5/.claude/backlog/linked-item.md" 'Status\*\*: FIXED/CLOSED \(CDT-99\)'
assert_file_match "write-through index completed" "$R5/.claude/backlog.md" 'linked-item\.md\).*FIXED/CLOSED'
# idempotent re-close still emits linear_id bridge
out5b=$(bash "$CLOSE" linked-item --root "$R5" --ticket CDT-99 --status FIXED/CLOSED)
if printf '%s\n' "$out5b" | grep -qE '^Already closed:'; then pass "write-through idempotent"
else fail "write-through idempotent" "got=$out5b"
fi
if printf '%s\n' "$out5b" | grep -qE '^linear_id: CDT-99$'; then
  pass "write-through idempotent linear_id bridge"
else
  fail "write-through idempotent linear_id bridge" "got=$out5b"
fi

# --- local-only close (no linear_id frontmatter) — no bridge line ---
R6="$TMP/r6"
setup_fixture "$R6"
out6=$(bash "$CLOSE" dark-mode --root "$R6")
assert_eq "local-only stdout single line" "Closed: .claude/backlog/dark-mode.md" "$out6"
if printf '%s\n' "$out6" | grep -qE '^linear_id:'; then
  fail "local-only no linear_id bridge" "unexpected bridge in: $out6"
else
  pass "local-only no linear_id bridge"
fi

# --- CDT-63: Linear-only / no local write-through (post-hygiene) — calm exit 0 ---
R7="$TMP/r7-empty"
mkdir -p "$R7"   # no .claude/backlog or backlog.md
set +e
out7=$(bash "$CLOSE" CDT-63 --root "$R7" --ticket CDT-63 --status FIXED/CLOSED 2>&1)
rc7=$?
set -e
if [ "$rc7" -eq 0 ]; then pass "linear-only no write-through exit 0"
else fail "linear-only no write-through exit 0" "rc=$rc7 out=$out7"
fi
if printf '%s\n' "$out7" | grep -qiE '^error:'; then
  fail "linear-only no error-shaped output" "got=$out7"
else
  pass "linear-only no error-shaped output"
fi
if printf '%s\n' "$out7" | grep -qiE 'no backlog (dir|index)'; then
  fail "linear-only no error-looking backlog msg" "got=$out7"
else
  pass "linear-only no error-looking backlog msg"
fi

# dir present, index absent, no matching item — still expected Linear-only skip
R8="$TMP/r8-no-index"
mkdir -p "$R8/.claude/backlog"
set +e
out8=$(bash "$CLOSE" CDT-99 --root "$R8" --ticket CDT-99 2>&1)
rc8=$?
set -e
if [ "$rc8" -eq 0 ]; then pass "no-index empty dir exit 0"
else fail "no-index empty dir exit 0" "rc=$rc8 out=$out8"
fi
if printf '%s\n' "$out8" | grep -qiE '^error:'; then
  fail "no-index empty dir no error:" "got=$out8"
else
  pass "no-index empty dir no error:"
fi

# index present + item missing remains a real error (not Linear-only skip)
R9="$TMP/r9-index-only"
mkdir -p "$R9/.claude/backlog"
cat > "$R9/.claude/backlog.md" <<'EOF'
# Fixture

## Pending

## Completed
EOF
set +e
out9=$(bash "$CLOSE" no-such-item --root "$R9" 2>&1)
rc9=$?
set -e
if [ "$rc9" -eq 1 ]; then pass "index exists missing item still exit 1"
else fail "index exists missing item still exit 1" "rc=$rc9 out=$out9"
fi
if printf '%s\n' "$out9" | grep -qE 'no backlog item matching'; then
  pass "index exists missing item message"
else
  fail "index exists missing item message" "got=$out9"
fi

# item file present without index — close item, skip index, exit 0
R10="$TMP/r10-orphan-item"
mkdir -p "$R10/.claude/backlog"
cat > "$R10/.claude/backlog/orphan.md" <<'EOF'
# Orphan

**Status**: PENDING

## Problem

x

## Goal

y

---

*Added: 2026-07-01*
EOF
set +e
out10=$(bash "$CLOSE" orphan --root "$R10" --ticket CDT-1 --status FIXED/CLOSED 2>&1)
rc10=$?
set -e
if [ "$rc10" -eq 0 ]; then pass "orphan item no-index exit 0"
else fail "orphan item no-index exit 0" "rc=$rc10 out=$out10"
fi
assert_file_match "orphan item closed without index" "$R10/.claude/backlog/orphan.md" 'Status\*\*: FIXED/CLOSED \(CDT-1\)'
if printf '%s\n' "$out10" | grep -qE '^Closed:'; then pass "orphan item closed stdout"
else fail "orphan item closed stdout" "got=$out10"
fi
if printf '%s\n' "$out10" | grep -qiE '^error:'; then
  fail "orphan item no error:" "got=$out10"
else
  pass "orphan item no error:"
fi

# --- CDT-160 T6: close integration — terminal-status parity (AC3–AC5, AC7) ---
# Helper: single-item fixture with given **Status** value (no index needed for verify/re-close).
mk_status_item() {
  local root="$1" slug="$2" status="$3"
  mkdir -p "$root/.claude/backlog"
  cat > "$root/.claude/backlog/${slug}.md" <<EOF
# ${slug}

**Status**: ${status}

## Problem

x

## Goal

y

---

*Added: 2026-07-01*
EOF
}

assert_verify_rc() {
  local name="$1" root="$2" slug="$3" want_rc="$4"
  local rc
  set +e
  bash "$CLOSE" verify "$slug" --root "$root" >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "$name" "$want_rc" "$rc"
}

# 1–2: DONE → verify 0; re-close → Already closed; status stays DONE (not rewritten)
RT="$TMP/rt-done"
mk_status_item "$RT" done-item "DONE"
assert_verify_rc "close DONE verify exit 0" "$RT" done-item 0
set +e
out_done=$(bash "$CLOSE" done-item --root "$RT" 2>&1)
rc_done=$?
set -e
if [ "$rc_done" -eq 0 ]; then pass "close DONE re-close exit 0"
else fail "close DONE re-close exit 0" "rc=$rc_done out=$out_done"
fi
if printf '%s\n' "$out_done" | grep -qE '^Already closed:'; then
  pass "close DONE re-close Already closed"
else
  fail "close DONE re-close Already closed" "got=$out_done"
fi
assert_file_match "close DONE re-close keeps DONE status" \
  "$RT/.claude/backlog/done-item.md" '^\*\*Status\*\*: DONE$'
assert_file_nomatch "close DONE re-close not rewritten to COMPLETED" \
  "$RT/.claude/backlog/done-item.md" 'COMPLETED'

# 3a: CANCELLED verify + re-close
RT="$TMP/rt-cancelled"
mk_status_item "$RT" cancelled-item "CANCELLED"
assert_verify_rc "close CANCELLED verify exit 0" "$RT" cancelled-item 0
set +e
out_can=$(bash "$CLOSE" cancelled-item --root "$RT" 2>&1)
rc_can=$?
set -e
if [ "$rc_can" -eq 0 ] && printf '%s\n' "$out_can" | grep -qE '^Already closed:'; then
  pass "close CANCELLED re-close Already closed"
else
  fail "close CANCELLED re-close Already closed" "rc=$rc_can out=$out_can"
fi
assert_file_match "close CANCELLED keeps CANCELLED" \
  "$RT/.claude/backlog/cancelled-item.md" '^\*\*Status\*\*: CANCELLED$'

# 3b: CANCELED (US) verify exit 0
RT="$TMP/rt-canceled"
mk_status_item "$RT" canceled-item "CANCELED"
assert_verify_rc "close CANCELED verify exit 0" "$RT" canceled-item 0

# 4: UNDONE stays open (substring guard AC5)
RT="$TMP/rt-undone"
mk_status_item "$RT" undone-item "UNDONE"
assert_verify_rc "close UNDONE verify exit 1" "$RT" undone-item 1

# 5: PENDING open
RT="$TMP/rt-pending"
mk_status_item "$RT" pending-item "PENDING"
assert_verify_rc "close PENDING verify exit 1" "$RT" pending-item 1

# 6: write --status still rejects DONE (AC7)
RT="$TMP/rt-write-done"
mk_status_item "$RT" write-item "PENDING"
set +e
out_wd=$(bash "$CLOSE" write-item --root "$RT" --status DONE 2>&1)
rc_wd=$?
set -e
if [ "$rc_wd" -eq 64 ]; then pass "close --status DONE rejected exit 64"
else fail "close --status DONE rejected exit 64" "rc=$rc_wd out=$out_wd"
fi
assert_file_match "close --status DONE leaves item PENDING" \
  "$RT/.claude/backlog/write-item.md" '^\*\*Status\*\*: PENDING$'

# 7: trailing noise FIXED/CLOSED (CDT-9) verify exit 0
RT="$TMP/rt-fixed-noise"
mk_status_item "$RT" fixed-noise "FIXED/CLOSED (CDT-9)"
assert_verify_rc "close FIXED/CLOSED (CDT-9) verify exit 0" "$RT" fixed-noise 0

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
