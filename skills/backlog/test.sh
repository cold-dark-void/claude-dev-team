#!/usr/bin/env bash
# skills/backlog/test.sh — unit tests for close.sh
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLOSE="$HERE/close.sh"
TS="$HERE/terminal-status.sh"
# shellcheck source=../../tests/lib/hermetic.sh
. "$HERE/../../tests/lib/hermetic.sh"
# path_canon: close.sh resolves --root through git, whose spelling of a
# trailing-slash TMPDIR / symlinked /var path differs from this suite's raw
# mktemp strings on macOS — canon both sides of every path compare.
# shellcheck source=../../tests/lib/path.sh
. "$HERE/../../tests/lib/path.sh"
hermetic_init

# Git fixtures (AC A) must not inherit the harness's own repo context.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
export GIT_CEILING_DIRECTORIES="$HERMETIC_ROOT"

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

file_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
}

TMP="$HERMETIC_ROOT/work"
mkdir -p "$TMP"

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
assert_eq "close: exactly one Completed header (AC E)" "1" \
  "$(grep -c '^## Completed[[:space:]]*$' "$R1/.claude/backlog.md")"
assert_eq "close: exactly one sort-dropdown row (AC E)" "1" \
  "$(grep -c '](backlog/sort-dropdown\.md)' "$R1/.claude/backlog.md")"
assert_file_match "close: old-item row kept (AC K adjacent)" "$R1/.claude/backlog.md" 'old-item\.md\).*\[COMPLETED\]'

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
assert_eq "idempotent close: exactly one Completed header (AC E)" "1" \
  "$(grep -c '^## Completed[[:space:]]*$' "$R1/.claude/backlog.md")"
assert_eq "idempotent close: exactly one sort-dropdown row (AC E)" "1" \
  "$(grep -c '](backlog/sort-dropdown\.md)' "$R1/.claude/backlog.md")"
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

# --- CDT-192: slug charset guard — path-escape index slug must not touch FS outside backlog ---
Rh="$TMP/hostile-slug"
mkdir -p "$Rh/.claude/backlog"
mkdir -p "$TMP/canary"
cat > "$TMP/canary/pwned.md" <<'EOF'
# pwned

**Status**: COMPLETED

## Problem

canary

## Goal

untouched

---

*Added: 2026-07-01*
EOF
cp "$TMP/canary/pwned.md" "$TMP/canary/pwned.snap"
HOSTILE_ROW='- [Hostile](backlog/../../../canary/pwned.md) - x [PENDING]'
cat > "$Rh/.claude/backlog.md" <<EOF
# Backlog

## Pending

$HOSTILE_ROW
- [Live](backlog/live.md) - normal item [PENDING]

## Completed

EOF
cat > "$Rh/.claude/backlog/live.md" <<'EOF'
# Live

**Status**: PENDING

## Problem

x

## Goal

y

---

*Added: 2026-07-01*
EOF

# Close by hostile title fragment: must not resolve to traversal path / touch canary
set +e
out_h1=$(bash "$CLOSE" Hostile --root "$Rh" 2>&1)
rc_h1=$?
set -e
if [ "$rc_h1" -ne 0 ]; then pass "hostile title close rejects (non-zero)"
else fail "hostile title close rejects (non-zero)" "rc=0 out=$out_h1"
fi
if [ -f "$TMP/canary/pwned.md" ]; then
  pass "hostile close: canary outside backlog survives"
else
  fail "hostile close: canary outside backlog survives" "canary deleted"
fi
if cmp -s "$TMP/canary/pwned.md" "$TMP/canary/pwned.snap"; then
  pass "hostile close: canary byte-unchanged"
else
  fail "hostile close: canary byte-unchanged" "cmp differs"
fi
if grep -qxF -- "$HOSTILE_ROW" "$Rh/.claude/backlog.md"; then
  pass "hostile close: hostile index row untouched"
else
  fail "hostile close: hostile index row untouched" "row altered or missing"
fi

# verify with traversal-shaped QUERY (basename → pwned; no pwned.md in backlog → miss)
set +e
out_h2=$(bash "$CLOSE" verify '../../../canary/pwned' --root "$Rh" 2>&1)
rc_h2=$?
set -e
if [ "$rc_h2" -ne 0 ]; then pass "verify traversal query non-zero"
else fail "verify traversal query non-zero" "rc=0 out=$out_h2"
fi
if cmp -s "$TMP/canary/pwned.md" "$TMP/canary/pwned.snap"; then
  pass "verify traversal: canary byte-unchanged"
else
  fail "verify traversal: canary byte-unchanged" "cmp differs"
fi

# Valid sibling still closes (happy path under hostile index)
set +e
out_h3=$(bash "$CLOSE" live --root "$Rh" 2>&1)
rc_h3=$?
set -e
if [ "$rc_h3" -eq 0 ] && printf '%s\n' "$out_h3" | grep -qE '^Closed:'; then
  pass "valid sibling close under hostile index"
else
  fail "valid sibling close under hostile index" "rc=$rc_h3 out=$out_h3"
fi
assert_file_match "valid sibling item COMPLETED" "$Rh/.claude/backlog/live.md" 'Status\*\*: COMPLETED'
assert_file_match "valid sibling index completed" "$Rh/.claude/backlog.md" 'live\.md\).*\[COMPLETED\]'
if [ -f "$TMP/canary/pwned.md" ] && cmp -s "$TMP/canary/pwned.md" "$TMP/canary/pwned.snap"; then
  pass "valid sibling close: canary still untouched"
else
  fail "valid sibling close: canary still untouched" "canary missing or changed"
fi
if bash "$CLOSE" verify live --root "$Rh" >/dev/null 2>&1; then
  pass "valid sibling verify closed"
else
  fail "valid sibling verify closed" "verify failed"
fi


# --- WP 1-04 rework 2 N2: find_slugs' index-scan fallback must classify the
# FINAL index row even when the file has no trailing newline. Bug: the read
# loop dropped the last row silently, so a query matching only that row's
# free text (not its slug or title) found nothing. ---
Ry="$TMP/y-index-no-nl"
mkdir -p "$Ry/.claude/backlog"
cat > "$Ry/.claude/backlog/final-row.md" <<'EOF'
# Something Neutral

**Status**: PENDING

## Problem

x

## Goal

y

---

*Added: 2026-07-01*
EOF
printf '%s' "$(cat <<'IDXEOF'
# Backlog

## Pending

- [Something Neutral](backlog/final-row.md) - quirkytext-marker description [PENDING]
IDXEOF
)" > "$Ry/.claude/backlog.md"

set +e
out_y=$(bash "$CLOSE" quirkytext-marker --root "$Ry" 2>&1)
rc_y=$?
set -e
if [ "$rc_y" -eq 0 ] && printf '%s\n' "$out_y" | grep -qE '^Closed:'; then
  pass "final unterminated index row: close finds and closes it"
else
  fail "final unterminated index row: close finds and closes it" "rc=$rc_y out=$out_y"
fi
assert_file_match "final unterminated index row: item COMPLETED" "$Ry/.claude/backlog/final-row.md" 'Status\*\*: COMPLETED'
echo "== close.sh root resolution (AC A, B) =="

RR_BASE="$TMP/rootres"
RR_M="$RR_BASE/M"
mkdir -p "$RR_BASE"
git init -q "$RR_M"
(
  cd "$RR_M"
  : > seed.txt
  git add seed.txt
  git commit -q -m seed
)
setup_fixture "$RR_M"
RR_WT="$RR_M/.worktrees/x"
git -C "$RR_M" worktree add -q -b feat/wt-x "$RR_WT"

# 11-ship form: compute MROOT with the SPEC-009 formula from inside the worktree
# (parent of `git rev-parse --git-common-dir`), then pass it explicitly.
rr_mroot_explicit=$(cd "$RR_WT" && _gc=$(git rev-parse --git-common-dir) && cd "$(dirname "$_gc")" && pwd)
assert_eq "root resolution: MROOT formula matches M" "$(path_canon "$RR_M")" "$(path_canon "$rr_mroot_explicit")"

set +e
out_rr1=$(cd "$RR_WT" && bash "$CLOSE" sort-dropdown --root "$rr_mroot_explicit" --status FIXED/CLOSED --ticket RR-1 2>&1)
rc_rr1=$?
set -e
assert_eq "root resolution: explicit --root=MROOT from worktree exit 0" "0" "$rc_rr1"
assert_file_match "root resolution: item closed in M (explicit root)" "$RR_M/.claude/backlog/sort-dropdown.md" 'FIXED/CLOSED \(RR-1\)'
if [ -e "$RR_WT/.claude/backlog" ] || [ -e "$RR_WT/.claude/backlog.md" ]; then
  fail "root resolution: no backlog store created in worktree (explicit root)" "found"
else
  pass "root resolution: no backlog store created in worktree (explicit root)"
fi

set +e
out_rr2=$(cd "$RR_WT" && bash "$CLOSE" verify sort-dropdown --root "$rr_mroot_explicit" 2>&1)
rc_rr2=$?
set -e
assert_eq "root resolution: verify --root=MROOT from worktree exit 0" "0" "$rc_rr2"

# No --root at all from the worktree: close.sh must compute the same MROOT on
# its own (git-common-dir default), not the worktree toplevel.
set +e
out_rr3=$(cd "$RR_WT" && bash "$CLOSE" dark-mode --status FIXED/CLOSED --ticket RR-2 2>&1)
rc_rr3=$?
set -e
assert_eq "root resolution: no --root from worktree exit 0" "0" "$rc_rr3"
assert_file_match "root resolution: no-root item closed in M" "$RR_M/.claude/backlog/dark-mode.md" 'FIXED/CLOSED \(RR-2\)'
if [ -e "$RR_WT/.claude/backlog" ] || [ -e "$RR_WT/.claude/backlog.md" ]; then
  fail "root resolution: no backlog store created in worktree (default root)" "found"
else
  pass "root resolution: no backlog store created in worktree (default root)"
fi

set +e
out_rr4=$(cd "$RR_WT" && bash "$CLOSE" verify dark-mode 2>&1)
rc_rr4=$?
set -e
assert_eq "root resolution: verify no --root from worktree exit 0" "0" "$rc_rr4"

# outside git entirely: acts on pwd
RR_OUT="$RR_BASE/outside"
mkdir -p "$RR_OUT/.claude/backlog"
cat > "$RR_OUT/.claude/backlog/lonely.md" <<'EOF'
# Lonely

**Status**: PENDING

## Problem

x

## Goal

y

---

*Added: 2026-07-01*
EOF
set +e
out_rr5=$(cd "$RR_OUT" && bash "$CLOSE" lonely --status FIXED/CLOSED --ticket RR-3 2>&1)
rc_rr5=$?
set -e
assert_eq "root resolution: outside git acts on pwd exit 0" "0" "$rc_rr5"
assert_file_match "root resolution: outside-git item closed" "$RR_OUT/.claude/backlog/lonely.md" 'FIXED/CLOSED \(RR-3\)'

echo "== close.sh lock behavior (AC C, D) =="

RL="$TMP/lock-busy"
setup_fixture "$RL"
lockdir="$RL/.claude/backlog.lock"
mkdir -p "$lockdir"
printf '%s %s %s\n' "$(date +%s)" "1970-01-01T00:00:00Z" "other-holder" > "$lockdir/stamp"

before_item=$(cat "$RL/.claude/backlog/sort-dropdown.md")
before_index=$(cat "$RL/.claude/backlog.md")

set +e
out_lk1=$(BACKLOG_LOCK_WAIT_SECONDS=1 bash "$CLOSE" sort-dropdown --root "$RL" --status FIXED/CLOSED 2>&1)
rc_lk1=$?
set -e
assert_eq "lock busy: close exit 1" "1" "$rc_lk1"
# The stderr names the lock dir as close.sh resolved it (git/cd form); canon
# both that path and the fixture spelling before comparing.
lock_named=$(printf '%s\n' "$out_lk1" | grep -o '[^ ]*backlog\.lock' | head -1)
if [ -n "$lock_named" ] && [ "$(path_canon "$lock_named")" = "$(path_canon "$lockdir")" ]; then
  pass "lock busy: stderr names lock path"
else fail "lock busy: stderr names lock path" "got=$out_lk1"; fi
assert_eq "lock busy: item unchanged" "$before_item" "$(cat "$RL/.claude/backlog/sort-dropdown.md")"
assert_eq "lock busy: index unchanged" "$before_index" "$(cat "$RL/.claude/backlog.md")"

# stale stamp: close succeeds, no lock dir remains afterwards.
RL2="$TMP/lock-stale"
setup_fixture "$RL2"
lockdir2="$RL2/.claude/backlog.lock"
mkdir -p "$lockdir2"
printf '%s %s %s\n' "$(( $(date +%s) - 120 ))" "1970-01-01T00:00:00Z" "old-holder" > "$lockdir2/stamp"
set +e
out_lk2=$(bash "$CLOSE" sort-dropdown --root "$RL2" --status FIXED/CLOSED 2>&1)
rc_lk2=$?
set -e
assert_eq "lock stale: close succeeds" "0" "$rc_lk2"
if [ -d "$lockdir2" ]; then fail "lock stale: no lock dir remains" "present"; else pass "lock stale: no lock dir remains"; fi

# verify takes no lock: returns fast even while a fresh lock is held, with a
# long wait budget.
RL3="$TMP/lock-verify"
setup_fixture "$RL3"
lockdir3="$RL3/.claude/backlog.lock"
mkdir -p "$lockdir3"
printf '%s %s %s\n' "$(date +%s)" "1970-01-01T00:00:00Z" "other-holder" > "$lockdir3/stamp"
start_v=$(date +%s)
set +e
out_lk3=$(BACKLOG_LOCK_WAIT_SECONDS=30 bash "$CLOSE" verify sort-dropdown --root "$RL3" 2>&1)
rc_lk3=$?
set -e
end_v=$(date +%s)
elapsed_v=$(( end_v - start_v ))
assert_eq "lock verify: exit rc reflects open status, not the lock" "1" "$rc_lk3"
if [ "$elapsed_v" -lt 5 ]; then pass "lock verify: no lock wait ($elapsed_v s)"
else fail "lock verify: no lock wait" "elapsed=$elapsed_v"; fi
if [ -d "$lockdir3" ]; then pass "lock verify: held lock dir untouched"
else fail "lock verify: held lock dir untouched" "removed"; fi

# missing slug: lock acquired then released via the die path before find_slugs
# reports its miss — no lock dir left behind.
RL4="$TMP/lock-missing-slug"
setup_fixture "$RL4"
lockdir4="$RL4/.claude/backlog.lock"
set +e
out_lk4=$(bash "$CLOSE" no-such-slug-at-all --root "$RL4" 2>&1)
rc_lk4=$?
set -e
assert_eq "lock missing-slug: exit 1" "1" "$rc_lk4"
if [ -d "$lockdir4" ]; then fail "lock missing-slug: no lock dir left" "present"; else pass "lock missing-slug: no lock dir left"; fi

echo "== close.sh index Completed-header edge cases (AC E) =="

# E1: "## Completed" is the very last line, WITH a trailing newline, no rows under it yet.
RE1="$TMP/e1-last-line-nl"
mkdir -p "$RE1/.claude/backlog"
printf '%s\n' \
  '# Fixture' \
  '' \
  '## Pending' \
  '' \
  '- [E One](backlog/e-one.md) - x [PENDING]' \
  '' \
  '## Completed' \
  > "$RE1/.claude/backlog.md"
cat > "$RE1/.claude/backlog/e-one.md" <<'EOF'
# E One

**Status**: PENDING

## Problem

x

## Goal

y

---

*Added: 2026-07-01*
EOF
bash "$CLOSE" e-one --root "$RE1" >/dev/null
assert_eq "E1 (header last line, w/ nl): one Completed header" "1" \
  "$(grep -c '^## Completed[[:space:]]*$' "$RE1/.claude/backlog.md")"
assert_eq "E1 (header last line, w/ nl): one row for slug" "1" \
  "$(grep -c '](backlog/e-one\.md)' "$RE1/.claude/backlog.md")"
assert_file_match "E1 (header last line, w/ nl): row tagged COMPLETED" \
  "$RE1/.claude/backlog.md" 'e-one\.md\).*\[COMPLETED\]'

# E2: "## Completed" is the very last line, with NO trailing newline in the file.
RE2="$TMP/e2-last-line-no-nl"
mkdir -p "$RE2/.claude/backlog"
printf '%s\n%s\n%s\n%s\n%s\n%s\n%s' \
  '# Fixture' \
  '' \
  '## Pending' \
  '' \
  '- [E Two](backlog/e-two.md) - x [PENDING]' \
  '' \
  '## Completed' \
  > "$RE2/.claude/backlog.md"
cat > "$RE2/.claude/backlog/e-two.md" <<'EOF'
# E Two

**Status**: PENDING

## Problem

x

## Goal

y

---

*Added: 2026-07-01*
EOF
bash "$CLOSE" e-two --root "$RE2" >/dev/null
assert_eq "E2 (header last line, no nl): one Completed header" "1" \
  "$(grep -c '^## Completed[[:space:]]*$' "$RE2/.claude/backlog.md")"
assert_eq "E2 (header last line, no nl): one row for slug" "1" \
  "$(grep -c '](backlog/e-two\.md)' "$RE2/.claude/backlog.md")"
assert_file_match "E2 (header last line, no nl): row tagged COMPLETED" \
  "$RE2/.claude/backlog.md" 'e-two\.md\).*\[COMPLETED\]'

# E3: re-close where the OLD row for this slug sits directly after "## Completed"
# (no blank line between header and row) — the getline-breaking shape.
RE3="$TMP/e3-adjacent-row"
mkdir -p "$RE3/.claude/backlog"
printf '%s\n' \
  '# Fixture' \
  '' \
  '## Pending' \
  '' \
  '## Completed' \
  '- [E Three](backlog/e-three.md) - x [FIXED/CLOSED — OLD-1]' \
  '' \
  > "$RE3/.claude/backlog.md"
cat > "$RE3/.claude/backlog/e-three.md" <<'EOF'
# E Three

**Status**: FIXED/CLOSED (OLD-1)

## Problem

x

## Goal

y

---

*Added: 2026-07-01*
*Closed: 2026-08-01 OLD-1*
EOF
bash "$CLOSE" e-three --root "$RE3" --ticket NEW-1 --status FIXED/CLOSED >/dev/null
assert_eq "E3 (adjacent row re-close): one Completed header" "1" \
  "$(grep -c '^## Completed[[:space:]]*$' "$RE3/.claude/backlog.md")"
assert_eq "E3 (adjacent row re-close): one row for slug" "1" \
  "$(grep -c '](backlog/e-three\.md)' "$RE3/.claude/backlog.md")"
assert_file_match "E3 (adjacent row re-close): row retagged NEW-1" \
  "$RE3/.claude/backlog.md" 'e-three\.md\).*FIXED/CLOSED — NEW-1'
assert_file_nomatch "E3 (adjacent row re-close): old tag gone" \
  "$RE3/.claude/backlog.md" 'e-three\.md\).*OLD-1'

# E4 (10b gap 5): an index with two "## Completed" headers must end with
# exactly one after a close, and no row is lost — rows that were under the
# SECOND header stay in the file, now merged below the first (only the
# duplicate header line itself is dropped; every row line is untouched).
RE4="$TMP/e4-dup-header"
mkdir -p "$RE4/.claude/backlog"
printf '%s\n' \
  '# Fixture' \
  '' \
  '## Pending' \
  '' \
  '- [Gap Five](backlog/gap-five.md) - to be closed [PENDING]' \
  '- [Other Pending](backlog/other-pending.md) - stays open [PENDING]' \
  '' \
  '## Completed' \
  '' \
  '- [First Completed](backlog/first-completed.md) - done earlier [COMPLETED]' \
  '' \
  '## Completed' \
  '' \
  '- [Second Completed](backlog/second-completed.md) - done earlier too [COMPLETED]' \
  > "$RE4/.claude/backlog.md"
cat > "$RE4/.claude/backlog/gap-five.md" <<'EOF'
# Gap Five

**Status**: PENDING
EOF
cat > "$RE4/.claude/backlog/other-pending.md" <<'EOF'
# Other Pending

**Status**: PENDING
EOF
cat > "$RE4/.claude/backlog/first-completed.md" <<'EOF'
# First Completed

**Status**: COMPLETED
EOF
cat > "$RE4/.claude/backlog/second-completed.md" <<'EOF'
# Second Completed

**Status**: COMPLETED
EOF
bash "$CLOSE" gap-five --root "$RE4" >/dev/null
assert_eq "E4 (dup header close): exactly one Completed header" "1" \
  "$(grep -c '^## Completed[[:space:]]*$' "$RE4/.claude/backlog.md")"
for slug4 in gap-five other-pending first-completed second-completed; do
  assert_eq "E4 (dup header close): exactly one row for $slug4" "1" \
    "$(grep -c "](backlog/${slug4}\.md)" "$RE4/.claude/backlog.md")"
done
assert_file_match "E4 (dup header close): closed slug retagged COMPLETED" \
  "$RE4/.claude/backlog.md" 'gap-five\.md\).*\[COMPLETED\]'
assert_file_match "E4 (dup header close): row under the dropped second header survives" \
  "$RE4/.claude/backlog.md" 'second-completed\.md\).*\[COMPLETED\]'

echo "== close.sh frontmatter-aware title (AC F) =="

RF="$TMP/f-title"
mkdir -p "$RF/.claude/backlog"
cat > "$RF/.claude/backlog.md" <<'EOF'
# Fixture

## Pending

## Completed

EOF
cat > "$RF/.claude/backlog/fm-item.md" <<'EOF'
---
epic_parent: CDT-1
---

# Real Title

**Status**: PENDING

## Problem

x

## Goal

y

---

*Added: 2026-07-01*
EOF
set +e
out_f1=$(bash "$CLOSE" "Real Title" --root "$RF" 2>&1)
rc_f1=$?
set -e
assert_eq "F title search exit 0" "0" "$rc_f1"
assert_eq "F title search matches frontmatter title" "Closed: .claude/backlog/fm-item.md" "$out_f1"
assert_file_match "F new index row uses real title" "$RF/.claude/backlog.md" '\[Real Title\]\(backlog/fm-item\.md\)'
assert_file_nomatch "F new index row never uses --- as title" "$RF/.claude/backlog.md" '\[---\]'

echo "== close.sh ENVIRON byte-exact special values (AC G) =="

RG="$TMP/g-bytes"
mkdir -p "$RG/.claude/backlog"
cat > "$RG/.claude/backlog.md" <<'EOF'
# Fixture

## Pending

- [G Item](backlog/g-item.md) - x [PENDING]

## Completed

EOF
cat > "$RG/.claude/backlog/g-item.md" <<'EOF'
# G Item

**Status**: PENDING

## Problem

x

## Goal

y

---

*Added: 2026-07-01*
EOF
set +e
bash "$CLOSE" g-item --root "$RG" --status FIXED/CLOSED --ticket 'T&1/2\t' --sha 'ab\\c' --note 'a\tb\nc\\d&e/f' >/dev/null
rc_g=$?
set -e
assert_eq "G close exit 0" "0" "$rc_g"

if grep -qF 'T&1/2\t' "$RG/.claude/backlog/g-item.md"; then pass "G item Status line has exact ticket bytes"
else fail "G item Status line has exact ticket bytes" "not found"; fi
if grep -qF -- 'ab\\c' "$RG/.claude/backlog/g-item.md"; then pass "G item Status line has exact sha bytes"
else fail "G item Status line has exact sha bytes" "not found"; fi
if grep -qF -- 'a\tb\nc\\d&e/f' "$RG/.claude/backlog/g-item.md"; then pass "G item Status line has exact note bytes"
else fail "G item Status line has exact note bytes" "not found"; fi
if grep -qF 'T&1/2\t' "$RG/.claude/backlog.md"; then pass "G index row has exact ticket bytes"
else fail "G index row has exact ticket bytes" "not found"; fi

echo "== close.sh atomic_write modes + no leftover temp (AC L, M) =="

RM="$TMP/modes"
setup_fixture "$RM"
chmod 0664 "$RM/.claude/backlog/sort-dropdown.md"
chmod 0644 "$RM/.claude/backlog.md"
set +e
bash "$CLOSE" sort-dropdown --root "$RM" --status FIXED/CLOSED --ticket M-1 >/dev/null
rc_lm=$?
set -e
assert_eq "L/M close exit 0" "0" "$rc_lm"
assert_eq "item mode kept 0664" "664" "$(file_mode "$RM/.claude/backlog/sort-dropdown.md")"
assert_eq "index mode kept 0644" "644" "$(file_mode "$RM/.claude/backlog.md")"

leftover=$(find "$RM/.claude" -name '.*.tmp.*' 2>/dev/null)
if [ -z "$leftover" ]; then pass "no leftover temp files under .claude"
else fail "no leftover temp files under .claude" "found: $leftover"
fi

echo "== close.sh producer-failure rc mapping (WP 1-04 rework T3) =="

# update_item_file's atomic_write must map ANY producer failure to rc 1, never
# rc 2 — cmd_close reads rc==2 as "already closed" (the pre-existing sentinel
# for a status already terminal). Before this fix, an awk exiting 2 for a real
# reason (fatal parse/I/O error) collided with that sentinel: cmd_close ran
# update_index and printed "Already closed", leaving the store inconsistent
# with no error ever surfaced. Repro: a PATH awk shim that exits 2 only for
# the update_item_file call (detected via the BL_NS env var that only that
# call sets — never BL_SLUG/BL_ROW, so update_index's awk call is unaffected).
RZ="$TMP/z-producer-fail"
setup_fixture "$RZ"
cp "$RZ/.claude/backlog/sort-dropdown.md" "$RZ/sort-dropdown.snap"
cp "$RZ/.claude/backlog.md" "$RZ/idx.snap"

AWK_REAL=$(command -v awk)
SHIM="$HERMETIC_ROOT/awk-fail-shim"
mkdir -p "$SHIM"
cat > "$SHIM/awk" << SHIMEOF
#!/usr/bin/env bash
if [ -n "\${BL_NS:-}" ]; then
  exit 2
fi
exec "$AWK_REAL" "\$@"
SHIMEOF
chmod +x "$SHIM/awk"

set +e
out_z=$(PATH="$SHIM:$PATH" bash "$CLOSE" sort-dropdown --root "$RZ" --status FIXED/CLOSED --ticket Z-1 2>&1)
rc_z=$?
set -e
if [ "$rc_z" -ne 0 ]; then pass "producer-failure: close exits non-zero"
else fail "producer-failure: close exits non-zero" "rc=0 out=$out_z"
fi
if printf '%s\n' "$out_z" | grep -qiE 'already closed'; then
  fail "producer-failure: no false Already closed message" "got=$out_z"
else
  pass "producer-failure: no false Already closed message"
fi
if cmp -s "$RZ/.claude/backlog/sort-dropdown.md" "$RZ/sort-dropdown.snap"; then
  pass "producer-failure: item file cmp-unchanged"
else
  fail "producer-failure: item file cmp-unchanged" "cmp differs"
fi
if cmp -s "$RZ/.claude/backlog.md" "$RZ/idx.snap"; then
  pass "producer-failure: index cmp-unchanged"
else
  fail "producer-failure: index cmp-unchanged" "cmp differs"
fi
leftover_z=$(find "$RZ/.claude" -name '.*.tmp.*' 2>/dev/null)
if [ -z "$leftover_z" ]; then pass "producer-failure: no leftover temp files"
else fail "producer-failure: no leftover temp files" "found: $leftover_z"
fi
rm -rf "$SHIM"

echo "== close.sh re-close index-write failure must not swallow (10b gap 6) =="

# The re-close path (update_item_file returns 2 because the item's Status is
# already terminal, before ever calling atomic_write) must not paper over a
# failed update_index write with `|| true` — a broken index write there must
# still surface as a non-zero exit, same as the fresh-close path already gets
# via set -euo pipefail. Repro: an awk shim on PATH that fails only the
# update_index call (detected via BL_SLUG, which only update_index sets —
# update_item_file's own awk never runs on this path, so it can't collide).
RRC="$TMP/reclose-index-fail"
setup_fixture "$RRC"
cp "$RRC/.claude/backlog.md" "$RRC/idx.snap"

SHIM_RC="$HERMETIC_ROOT/awk-reclose-fail-shim"
mkdir -p "$SHIM_RC"
cat > "$SHIM_RC/awk" << SHIMEOF
#!/usr/bin/env bash
if [ -n "\${BL_SLUG:-}" ]; then
  exit 2
fi
exec "$AWK_REAL" "\$@"
SHIMEOF
chmod +x "$SHIM_RC/awk"

set +e
out_rc=$(PATH="$SHIM_RC:$PATH" bash "$CLOSE" old-item --root "$RRC" 2>&1)
rc_rc=$?
set -e
if [ "$rc_rc" -ne 0 ]; then pass "re-close index-write failure: close exits non-zero"
else fail "re-close index-write failure: close exits non-zero" "rc=0 out=$out_rc"
fi
if printf '%s\n' "$out_rc" | grep -qiE 'already closed'; then
  fail "re-close index-write failure: no false Already-closed message" "got=$out_rc"
else
  pass "re-close index-write failure: no false Already-closed message"
fi
if cmp -s "$RRC/.claude/backlog.md" "$RRC/idx.snap"; then
  pass "re-close index-write failure: index cmp-unchanged"
else
  fail "re-close index-write failure: index cmp-unchanged" "cmp differs"
fi
rm -rf "$SHIM_RC"

echo "== static (WP 1-04) =="
# Static guards for AC B, J, N (backlog side) and the static side of F, G, D.
# Every check below carries a planted-string negative control in $STATIC_TMP
# proving the check fires on a bad pattern — none passes vacuously.

assert_count() {
  # assert_count <name> <eq|ge> <want> <got>
  local name="$1" op="$2" want="$3" got="$4"
  case "$op" in
    eq) if [ "$got" -eq "$want" ]; then pass "$name"; else fail "$name" "want==$want got=$got"; fi ;;
    ge) if [ "$got" -ge "$want" ]; then pass "$name"; else fail "$name" "want>=$want got=$got"; fi ;;
  esac
}

REPO_ROOT="$HERE/../.."
RECON="$HERE/reconcile.sh"
LOCKSH="$HERE/lock.sh"
PORTABLE="$HERE/../lib/portable.sh"
SKILL_MD="$HERE/SKILL.md"
SHIP_MD="$HERE/../orchestrate/steps/11-ship.md"
STATIC_TMP="$HERMETIC_ROOT/static-nc"
mkdir -p "$STATIC_TMP"

# --- AC B: no caller/doc passes a worktree toplevel ($WT_PATH/$WTROOT/--show-toplevel) as --root ---

# Covers a literal $WT_PATH/$WTROOT and a literal show-toplevel command
# substitution passed directly as --root's value.
B1_PATTERN='(CLOSE|RECON)"[^|;&]*--root "(\$(WT_PATH|WTROOT)|\$\(git rev-parse --show-toplevel\))"'
# --exclude=test.sh: this suite's own negative-control literal strings below
# (e.g. b1-bad.sh's planted line) would otherwise self-match this scan.
b1_real=$({ grep -rnE --exclude='test.sh' "$B1_PATTERN" "$REPO_ROOT/skills" "$REPO_ROOT/commands" "$REPO_ROOT/docs" 2>/dev/null || true; } | wc -l | tr -d ' ')
assert_count "B: no CLOSE/RECON call site passes WT_PATH/WTROOT/show-toplevel as --root" eq 0 "$b1_real"

printf '%s\n' 'bash "$CLOSE" foo --root "$WT_PATH"' > "$STATIC_TMP/b1-bad.sh"
b1_nc=$(grep -cE "$B1_PATTERN" "$STATIC_TMP/b1-bad.sh" || true)
assert_count "B nc: planted CLOSE --root \$WT_PATH fires" ge 1 "${b1_nc:-0}"
rm -f "$STATIC_TMP/b1-bad.sh"

printf '%s\n' 'bash "$CLOSE" foo --root "$(git rev-parse --show-toplevel)"' > "$STATIC_TMP/b1t-bad.sh"
b1t_nc=$(grep -cE "$B1_PATTERN" "$STATIC_TMP/b1t-bad.sh" || true)
assert_count "B nc: planted CLOSE --root literal show-toplevel fires" ge 1 "${b1t_nc:-0}"
rm -f "$STATIC_TMP/b1t-bad.sh"

# --- AC B (variable form): a variable assigned earlier in the same file from
# `git rev-parse --show-toplevel`, then passed as --root "$VAR" at a
# CLOSE/RECON call site, under any variable name. ---

count_toplevel_var_root_hits() {
  # count_toplevel_var_root_hits <file> — prints a count, never fails the caller.
  local f="$1" vnames vn hits=0
  vnames=$(grep -oE '[A-Za-z_][A-Za-z0-9_]*=\$\(git rev-parse --show-toplevel\)' "$f" 2>/dev/null | sed -E 's/=.*//' || true)
  if [ -z "$vnames" ]; then printf '0\n'; return 0; fi
  while IFS= read -r vn || [ -n "$vn" ]; do
    [ -n "$vn" ] || continue
    if grep -qE "(CLOSE|RECON)\"[^|;&]*--root \"\\\$${vn}\"" "$f" 2>/dev/null; then
      hits=$((hits + 1))
    fi
  done <<VNAMES
$vnames
VNAMES
  printf '%s\n' "$hits"
}

b1v_total=0
b1v_files=$({ grep -rl -- 'rev-parse --show-toplevel' "$REPO_ROOT/skills" "$REPO_ROOT/commands" "$REPO_ROOT/docs" 2>/dev/null || true; } | { grep -v -- '/test\.sh$' || true; })
if [ -n "$b1v_files" ]; then
  while IFS= read -r vf || [ -n "$vf" ]; do
    [ -n "$vf" ] || continue
    b1v_hits=$(count_toplevel_var_root_hits "$vf")
    b1v_total=$((b1v_total + b1v_hits))
  done <<VFILES
$b1v_files
VFILES
fi
assert_count "B: no CLOSE/RECON call site passes a show-toplevel-derived variable as --root" eq 0 "$b1v_total"

printf '%s\n' 'toproot=$(git rev-parse --show-toplevel)
bash "$CLOSE" foo --root "$toproot"' > "$STATIC_TMP/b1v-bad.sh"
b1v_nc=$(count_toplevel_var_root_hits "$STATIC_TMP/b1v-bad.sh")
assert_count "B nc: planted show-toplevel-derived variable --root fires" ge 1 "$b1v_nc"
rm -f "$STATIC_TMP/b1v-bad.sh"

b2_close=$(grep -c -- '--show-toplevel' "$CLOSE" || true)
assert_count "B: close.sh never invokes --show-toplevel" eq 0 "${b2_close:-0}"
b2_recon=$(grep -c -- '--show-toplevel' "$RECON" || true)
assert_count "B: reconcile.sh never invokes --show-toplevel" eq 0 "${b2_recon:-0}"

printf '%s\n' 'root=$(git rev-parse --show-toplevel)' > "$STATIC_TMP/b2-bad.sh"
b2_nc=$(grep -c -- '--show-toplevel' "$STATIC_TMP/b2-bad.sh" || true)
assert_count "B nc: planted --show-toplevel invocation fires" ge 1 "${b2_nc:-0}"
rm -f "$STATIC_TMP/b2-bad.sh"

b3=$(grep -cE -- '--show-toplevel|--root "\$(WT_PATH|WTROOT)"' "$SKILL_MD" || true)
assert_count "B: SKILL.md never documents a worktree-toplevel root" eq 0 "${b3:-0}"

printf '%s\n' 'bash "$CLOSE" x --root "$WTROOT"' > "$STATIC_TMP/b3-bad.md"
b3_nc=$(grep -cE -- '--show-toplevel|--root "\$(WT_PATH|WTROOT)"' "$STATIC_TMP/b3-bad.md" || true)
assert_count "B nc: planted WTROOT root doc line fires" ge 1 "${b3_nc:-0}"
rm -f "$STATIC_TMP/b3-bad.md"

assert_file_match "B: 11-ship close line passes --root \$MROOT" "$SHIP_MD" \
  '"\$CLOSE" "<slug>"[^|]*--root "\$MROOT"'
assert_file_match "B: 11-ship verify line passes --root \$MROOT" "$SHIP_MD" \
  '"\$CLOSE" verify "<slug>" --root "\$MROOT"'

printf '%s\n' 'bash "$CLOSE" "<slug>" --root "$WT_PATH" --ticket "<ISSUE-ID>"' > "$STATIC_TMP/b4-bad.md"
if grep -qE '"\$CLOSE" "<slug>"[^|]*--root "\$MROOT"' "$STATIC_TMP/b4-bad.md"; then
  fail "B nc: planted non-MROOT ship line must not satisfy the MROOT pattern" "matched"
else
  pass "B nc: planted non-MROOT ship line must not satisfy the MROOT pattern"
fi
rm -f "$STATIC_TMP/b4-bad.md"

# --- AC J: every [@]/[*] array expansion is either a count (${#name[@]}) or the
# empty-array guard (${name[@]+"${name[@]}"}); strip both known-safe forms and
# anything left over is unguarded. ---

strip_guarded() {
  sed -E 's/\$\{#[A-Za-z_][A-Za-z0-9_]*\[@\]\}//g
          s/\$\{[A-Za-z_][A-Za-z0-9_]*\[@\]\+"\$\{[A-Za-z_][A-Za-z0-9_]*\[@\]\}"\}//g' "$1"
}

for jf in "$CLOSE" "$RECON" "$LOCKSH" "$PORTABLE"; do
  jname=$(basename "$jf")
  jcnt=$(strip_guarded "$jf" | { grep -oE '\[@\]\}|\[\*\]\}' || true; } | wc -l | tr -d ' ')
  assert_count "J: $jname has no unguarded [@]/[*] expansion" eq 0 "$jcnt"
done

printf '%s\n' 'for x in "${BADARR[@]}"; do echo "$x"; done' > "$STATIC_TMP/j-bad.sh"
j_nc=$(strip_guarded "$STATIC_TMP/j-bad.sh" | { grep -oE '\[@\]\}|\[\*\]\}' || true; } | wc -l | tr -d ' ')
assert_count "J nc: planted unguarded expansion fires" ge 1 "$j_nc"
rm -f "$STATIC_TMP/j-bad.sh"

# The outer-quoted form "${name[@]+"${name[@]}"}" (10b gap 4) is a DIFFERENT,
# buggy guard: wrapping the whole guard in one more pair of quotes forces the
# unset/empty-array branch to expand to one empty-string ELEMENT instead of
# zero elements (e.g. `for x in "${a[@]+"${a[@]}"}"` iterates once with
# x="" when $a is empty). strip_guarded above strips straight through to this
# form too (its pattern only cares about the guard's own text, not what wraps
# it), so it must never pass vacuously — check for the outer-quoted shape
# directly, unstripped.
outer_quoted_guard() {
  grep -cE '"\$\{[A-Za-z_][A-Za-z0-9_]*\[[@*]\]\+"\$\{[A-Za-z_][A-Za-z0-9_]*\[[@*]\]\}"\}"' "$1" || true
}

for jf in "$CLOSE" "$RECON" "$LOCKSH" "$PORTABLE"; do
  jname=$(basename "$jf")
  jouter=$(outer_quoted_guard "$jf")
  assert_count "J: $jname has no outer-quoted array guard" eq 0 "${jouter:-0}"
done

printf '%s\n' 'for x in "${BADARR[@]+"${BADARR[@]}"}"; do echo "$x"; done' > "$STATIC_TMP/j-outer-bad.sh"
j_outer_nc=$(outer_quoted_guard "$STATIC_TMP/j-outer-bad.sh")
assert_count "J nc: planted outer-quoted array guard fires" ge 1 "${j_outer_nc:-0}"
rm -f "$STATIC_TMP/j-outer-bad.sh"

# --- AC N: atomic_write only, no mktemp/mv left in close.sh/reconcile.sh ---

for nf in "$CLOSE" "$RECON"; do
  nname=$(basename "$nf")
  n_mt=$(grep -c 'mktemp' "$nf" || true)
  assert_count "N: $nname has zero mktemp" eq 0 "${n_mt:-0}"
  n_mv=$(grep -c 'mv "' "$nf" || true)
  assert_count "N: $nname has zero mv \" writes" eq 0 "${n_mv:-0}"
  assert_file_match "N: $nname sources lib/portable.sh" "$nf" 'lib/portable\.sh'
done

close_aw=$(grep -c 'atomic_write' "$CLOSE" || true)
assert_count "N: close.sh calls atomic_write >= 2" ge 2 "${close_aw:-0}"
recon_aw=$(grep -c 'atomic_write' "$RECON" || true)
assert_count "N: reconcile.sh calls atomic_write >= 1" ge 1 "${recon_aw:-0}"

printf '%s\n' 'tmp=$(mktemp)' 'mv "$tmp" "$dest"' > "$STATIC_TMP/n-bad.sh"
n_mt_nc=$(grep -c 'mktemp' "$STATIC_TMP/n-bad.sh" || true)
assert_count "N nc: planted mktemp fires" ge 1 "${n_mt_nc:-0}"
n_mv_nc=$(grep -c 'mv "' "$STATIC_TMP/n-bad.sh" || true)
assert_count "N nc: planted mv \" fires" ge 1 "${n_mv_nc:-0}"
rm -f "$STATIC_TMP/n-bad.sh"

# --- AC F (static side; orchestrator amendment): scope to title reads only.
# close.sh keeps 3 legitimate non-title `head -n1` uses (ambiguous-match pick at
# ~:235/:436, first index row at ~:342) — SPEC-009/AC F cover title reading only.
# So: item_title is defined; the old head-n1-on-a-quoted-file-arg title form is
# gone; item_title is called at least 3 times. ---

assert_file_match "F: close.sh defines item_title" "$CLOSE" '^item_title\(\) \{'

f_old=$(grep -cE 'head -n *1[[:space:]]*"' "$CLOSE" || true)
assert_count "F: close.sh has no old head-n1-on-quoted-file title form" eq 0 "${f_old:-0}"

f_calls=$(grep -cE 'item_title "' "$CLOSE" || true)
assert_count "F: close.sh calls item_title at least 3 times" ge 3 "${f_calls:-0}"

printf '%s\n' 'title=$(head -n 1 "$file" 2>/dev/null | sed '"'"'s/^# *//'"'"')' > "$STATIC_TMP/f-bad.sh"
f_nc=$(grep -cE 'head -n *1[[:space:]]*"' "$STATIC_TMP/f-bad.sh" || true)
assert_count "F nc: planted head -n1 \"\$file\" title form fires" ge 1 "${f_nc:-0}"
rm -f "$STATIC_TMP/f-bad.sh"

# --- AC G (static side): values reach awk only via ENVIRON, never -v ---

g_close=$(grep -c -- 'awk -v' "$CLOSE" || true)
assert_count "G: close.sh has no awk -v" eq 0 "${g_close:-0}"
g_recon=$(grep -c -- 'awk -v' "$RECON" || true)
assert_count "G: reconcile.sh has no awk -v" eq 0 "${g_recon:-0}"

printf '%s\n' "awk -v x=1 '{print}'" > "$STATIC_TMP/g-bad.sh"
g_nc=$(grep -c -- 'awk -v' "$STATIC_TMP/g-bad.sh" || true)
assert_count "G nc: planted awk -v fires" ge 1 "${g_nc:-0}"
rm -f "$STATIC_TMP/g-bad.sh"

# --- AC D (static side): no PID-liveness check in lock.sh ---

d_real=$(grep -c -- 'kill -0' "$LOCKSH" || true)
assert_count "D: lock.sh has no kill -0 liveness check" eq 0 "${d_real:-0}"

printf '%s\n' 'kill -0 "$pid" 2>/dev/null' > "$STATIC_TMP/d-bad.sh"
d_nc=$(grep -c -- 'kill -0' "$STATIC_TMP/d-bad.sh" || true)
assert_count "D nc: planted kill -0 fires" ge 1 "${d_nc:-0}"
rm -f "$STATIC_TMP/d-bad.sh"

rmdir "$STATIC_TMP" 2>/dev/null || true

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
