#!/usr/bin/env bash
# skills/backlog/reconcile-test.sh — deterministic subprocess tests for reconcile.sh.
# Offline: no network, no LLM, no MCP. Each case drives reconcile.sh via --root into a
# fresh ${TMPDIR:-/tmp} fixture. See specs/core/SPEC-009-ticket-workflow.md §"Backlog reconcile".
# The *-test.sh basename keeps this out of the smoke harness's engine-script discovery (SPEC-030).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RECONCILE="$HERE/reconcile.sh"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s — %s\n' "$1" "$2"; }

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

# assert_stdout_match: run reconcile, assert its combined stdout matches a pattern.
assert_out_match() {
  local name="$1" out="$2" pat="$3"
  if printf '%s' "$out" | grep -qE "$pat"; then pass "$name"
  else fail "$name" "pattern /$pat/ not in output: $out"
  fi
}

# assert_count: exact grep -c match count in a file.
assert_count() {
  local name="$1" file="$2" pat="$3" want="$4" got
  got=$(grep -cE "$pat" "$file" || true)
  if [ "$got" = "$want" ]; then pass "$name"
  else fail "$name" "want count=$want got=$got for /$pat/ in $file"
  fi
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/backlog-reconcile-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# item_file <path> <status> — write a minimal item file with a given Status.
item_file() {
  local path="$1" status="$2"
  cat > "$path" <<EOF
# $(basename "$path" .md)

**Status**: $status

## Problem

detail for $(basename "$path" .md)

---

*Added: 2026-01-01*
EOF
}

echo "== reconcile.sh tests =="

# --- (a) Stale row: index PENDING but item file COMPLETED -> pruned (deleted, row dropped) ---
Ra="$TMP/a"
mkdir -p "$Ra/.claude/backlog"
cat > "$Ra/.claude/backlog.md" <<'EOF'
# Backlog

## Pending

- [Stale](backlog/stale.md) - Do stale [PENDING]
- [Live](backlog/live.md) - Do live [PENDING]

## Completed

EOF
item_file "$Ra/.claude/backlog/stale.md" "COMPLETED"
item_file "$Ra/.claude/backlog/live.md" "PENDING"
bash "$RECONCILE" --root "$Ra" >/dev/null
# Completed item is pruned outright: row removed entirely (no ## Completed archive), file deleted.
assert_file_nomatch "(a) stale row removed from index" "$Ra/.claude/backlog.md" 'stale\.md'
if [ ! -f "$Ra/.claude/backlog/stale.md" ]; then
  pass "(a) stale item file pruned (deleted)"
else
  fail "(a) stale item file pruned (deleted)" "file still exists"
fi
assert_file_match "(a) live sibling stays PENDING" "$Ra/.claude/backlog.md" 'live\.md\).*\[PENDING\]'

# --- (b) Dead reference: index row with no item file -> removed ---
Rb="$TMP/b"
mkdir -p "$Rb/.claude/backlog"
cat > "$Rb/.claude/backlog.md" <<'EOF'
# Backlog

## Pending

- [Ghost](backlog/ghost.md) - no item file [PENDING]
- [Real](backlog/real.md) - has item file [PENDING]

## Completed

EOF
item_file "$Rb/.claude/backlog/real.md" "PENDING"
bash "$RECONCILE" --root "$Rb" >/dev/null
assert_file_nomatch "(b) dead-ref row removed" "$Rb/.claude/backlog.md" 'ghost\.md'
assert_file_match "(b) live sibling survives" "$Rb/.claude/backlog.md" 'real\.md\).*\[PENDING\]'

# --- (c) Duplicate rows for one slug -> collapsed to exactly one ---
Rc="$TMP/c"
mkdir -p "$Rc/.claude/backlog"
cat > "$Rc/.claude/backlog.md" <<'EOF'
# Backlog

## Pending

- [Dupe one](backlog/dupe.md) - first row [PENDING]
- [Dupe two](backlog/dupe.md) - second row [PENDING]
- [Dupe three](backlog/dupe.md) - third row [PENDING]

## Completed

EOF
item_file "$Rc/.claude/backlog/dupe.md" "PENDING"
bash "$RECONCILE" --root "$Rc" >/dev/null
assert_count "(c) exactly one dupe row" "$Rc/.claude/backlog.md" 'dupe\.md' 1
# First-seen row is the one kept.
assert_file_match "(c) keeps first-seen row text" "$Rc/.claude/backlog.md" 'Dupe one.*first row'

# --- (d) Idempotency: second run reports no changes AND index byte-identical ---
Rd="$TMP/d"
mkdir -p "$Rd/.claude/backlog"
cat > "$Rd/.claude/backlog.md" <<'EOF'
# Backlog

## Pending

- [Keep](backlog/keep.md) - stays pending [PENDING]
- [Drop](backlog/drop.md) - will close [PENDING]

## Completed

EOF
item_file "$Rd/.claude/backlog/keep.md" "PENDING"
item_file "$Rd/.claude/backlog/drop.md" "COMPLETED"
bash "$RECONCILE" --root "$Rd" >/dev/null       # first run: reconciles drift
if [ ! -f "$Rd/.claude/backlog/drop.md" ]; then
  pass "(d) drop item file pruned on first run"
else
  fail "(d) drop item file pruned on first run" "file still exists"
fi
cp "$Rd/.claude/backlog.md" "$Rd/idx.snap"      # snapshot the reconciled index
out_d=$(bash "$RECONCILE" --root "$Rd")          # second run
assert_out_match "(d) second run says no changes" "$out_d" 'no changes'
if cmp -s "$Rd/.claude/backlog.md" "$Rd/idx.snap"; then
  pass "(d) index byte-identical after second run"
else
  fail "(d) index byte-identical after second run" "cmp differs"
fi

# --- (e) Linear verdicts precedence: locally-PENDING slug marked Done -> moved + item COMPLETED ---
Re="$TMP/e"
mkdir -p "$Re/.claude/backlog"
cat > "$Re/.claude/backlog.md" <<'EOF'
# Backlog

## Pending

- [Shipped](backlog/shipped.md) - closed in Linear [PENDING]
- [Working](backlog/working.md) - still open [PENDING]

## Completed

EOF
item_file "$Re/.claude/backlog/shipped.md" "PENDING"
item_file "$Re/.claude/backlog/working.md" "PENDING"
printf 'shipped\tDone\n' > "$Re/verdicts.tsv"
out_e=$(bash "$RECONCILE" --root "$Re" --linear-verdicts "$Re/verdicts.tsv")
assert_file_nomatch "(e) linear-closed row pruned from index" "$Re/.claude/backlog.md" 'shipped\.md'
if [ ! -f "$Re/.claude/backlog/shipped.md" ]; then
  pass "(e) linear-closed item file pruned (deleted)"
else
  fail "(e) linear-closed item file pruned (deleted)" "file still exists"
fi
assert_out_match "(e) prune reason cites Linear verdict" "$out_e" "prune 'shipped'.*Linear verdict"
# Non-verdict local-pending sibling untouched.
assert_file_match "(e) unrelated slug stays PENDING" "$Re/.claude/backlog.md" 'working\.md\).*\[PENDING\]'
assert_file_match "(e) unrelated item Status unchanged" "$Re/.claude/backlog/working.md" '^\*\*Status\*\*: PENDING'

# --- (f) --dry-run: prints planned actions, index file byte-unchanged ---
Rf="$TMP/f"
mkdir -p "$Rf/.claude/backlog"
cat > "$Rf/.claude/backlog.md" <<'EOF'
# Backlog

## Pending

- [Pend](backlog/pend.md) - actually done [PENDING]
- [Gone](backlog/gone.md) - dead ref [PENDING]

## Completed

EOF
item_file "$Rf/.claude/backlog/pend.md" "COMPLETED"
cp "$Rf/.claude/backlog.md" "$Rf/idx.snap"
cp "$Rf/.claude/backlog/pend.md" "$Rf/pend.snap"
out_f=$(bash "$RECONCILE" --root "$Rf" --dry-run)
assert_out_match "(f) dry-run announces planned actions" "$out_f" 'dry-run.*planned actions'
assert_out_match "(f) dry-run lists dead-ref removal" "$out_f" "remove dead-ref row for 'gone'"
if cmp -s "$Rf/.claude/backlog.md" "$Rf/idx.snap"; then
  pass "(f) index byte-unchanged under --dry-run"
else
  fail "(f) index byte-unchanged under --dry-run" "cmp differs"
fi
if cmp -s "$Rf/.claude/backlog/pend.md" "$Rf/pend.snap"; then
  pass "(f) item file byte-unchanged under --dry-run"
else
  fail "(f) item file byte-unchanged under --dry-run" "cmp differs"
fi

# --- (g) Untouched survivor: open PENDING row with live item stays, text preserved verbatim ---
Rg="$TMP/g"
mkdir -p "$Rg/.claude/backlog"
SURV_ROW='- [Survivor](backlog/survivor.md) - Keep this text EXACTLY, tricky (chars) & all [PENDING]'
cat > "$Rg/.claude/backlog.md" <<EOF
# Backlog

## Pending

$SURV_ROW
- [Closer](backlog/closer.md) - will move [PENDING]

## Completed

EOF
item_file "$Rg/.claude/backlog/survivor.md" "PENDING"
item_file "$Rg/.claude/backlog/closer.md" "DONE"
cp "$Rg/.claude/backlog/survivor.md" "$Rg/survivor.snap"
bash "$RECONCILE" --root "$Rg" >/dev/null
# Row text preserved verbatim, byte-for-byte.
if grep -qxF -- "$SURV_ROW" "$Rg/.claude/backlog.md"; then
  pass "(g) survivor row text preserved verbatim"
else
  fail "(g) survivor row text preserved verbatim" "row altered: $(grep 'survivor\.md' "$Rg/.claude/backlog.md")"
fi
# Still sits under ## Pending (above ## Completed).
if awk '/^## Pending/{p=1} /^## Completed/{p=0} p && /survivor\.md/{found=1} END{exit !found}' "$Rg/.claude/backlog.md"; then
  pass "(g) survivor stays under ## Pending"
else
  fail "(g) survivor stays under ## Pending" "not in Pending section"
fi
# Item file untouched.
if cmp -s "$Rg/.claude/backlog/survivor.md" "$Rg/survivor.snap"; then
  pass "(g) survivor item file unchanged"
else
  fail "(g) survivor item file unchanged" "cmp differs"
fi
# Closer (DONE) is pruned — file deleted, row gone entirely (not archived under Completed).
if [ ! -f "$Rg/.claude/backlog/closer.md" ]; then
  pass "(g) closer item file pruned (deleted)"
else
  fail "(g) closer item file pruned (deleted)" "file still exists"
fi
assert_file_nomatch "(g) closer row removed from index" "$Rg/.claude/backlog.md" 'closer\.md'

# --- (h) Degrade path: no --linear-verdicts → local-only; PENDING+linear_id stays PENDING ---
Rh="$TMP/h"
mkdir -p "$Rh/.claude/backlog"
cat > "$Rh/.claude/backlog.md" <<'EOF'
# Backlog

## Pending

- [Linked open](backlog/linked-open.md) - still open in Linear [PENDING] linear:CDT-77
- [Local done](backlog/local-done.md) - closed only locally [PENDING]

## Completed

EOF
cat > "$Rh/.claude/backlog/linked-open.md" <<'EOF'
---
linear_id: CDT-77
---

# Linked open

**Status**: PENDING

## Problem

open

---

*Added: 2026-01-01*
EOF
item_file "$Rh/.claude/backlog/local-done.md" "COMPLETED"
# MCP-down / degrade: no --linear-verdicts (session would emit one-line notice; script is silent)
out_h=$(bash "$RECONCILE" --root "$Rh")
assert_file_match "(h) linked open stays PENDING without verdicts" "$Rh/.claude/backlog.md" 'linked-open\.md\).*\[PENDING\]'
assert_file_match "(h) linked item Status still PENDING" "$Rh/.claude/backlog/linked-open.md" '^\*\*Status\*\*: PENDING'
assert_file_match "(h) linked linear_id preserved" "$Rh/.claude/backlog/linked-open.md" '^linear_id: CDT-77'
assert_file_nomatch "(h) local COMPLETED pruned from index" "$Rh/.claude/backlog.md" 'local-done\.md'
if [ ! -f "$Rh/.claude/backlog/local-done.md" ]; then
  pass "(h) local COMPLETED item file pruned (deleted)"
else
  fail "(h) local COMPLETED item file pruned (deleted)" "file still exists"
fi
# exit 0 on degrade (local-only still succeeds)
rc_h=0
bash "$RECONCILE" --root "$Rh" >/dev/null || rc_h=$?
if [ "$rc_h" -eq 0 ]; then pass "(h) degrade path exit 0"
else fail "(h) degrade path exit 0" "rc=$rc_h"
fi

# --- (i) Write-through after Linear verdict: preserve frontmatter linear_id ---
Ri="$TMP/i"
mkdir -p "$Ri/.claude/backlog"
cat > "$Ri/.claude/backlog.md" <<'EOF'
# Backlog

## Pending

- [Dual](backlog/dual.md) - closed in Linear [PENDING] linear:CDT-88

## Completed

EOF
cat > "$Ri/.claude/backlog/dual.md" <<'EOF'
---
linear_id: CDT-88
epic_parent: CDT-46
---

# Dual

**Status**: PENDING

## Problem

shipped remotely

---

*Added: 2026-01-01*
EOF
printf 'dual\tDone\n' > "$Ri/verdicts.tsv"
out_i=$(bash "$RECONCILE" --root "$Ri" --linear-verdicts "$Ri/verdicts.tsv")
if [ ! -f "$Ri/.claude/backlog/dual.md" ]; then
  pass "(i) Linear-verdict item pruned (deleted, frontmatter and all)"
else
  fail "(i) Linear-verdict item pruned (deleted, frontmatter and all)" "file still exists"
fi
assert_file_nomatch "(i) index row removed" "$Ri/.claude/backlog.md" 'dual\.md'
# Even though the file is gone, the prune log names the slug's linear_id for traceability.
assert_out_match "(i) prune log cites linear_id for traceability" "$out_i" 'CDT-88'

# --- (j) Orphan item files: no index row at all ---
Rj="$TMP/j"
mkdir -p "$Rj/.claude/backlog"
cat > "$Rj/.claude/backlog.md" <<'EOF'
# Backlog

## Pending

## Completed

EOF
# Closed-status orphan: never dual-written / predates the index — safe to prune.
item_file "$Rj/.claude/backlog/orphan-done.md" "COMPLETED"
# Open-status orphan: real un-tracked work — must NOT be silently deleted.
item_file "$Rj/.claude/backlog/orphan-open.md" "PARTIAL"
cp "$Rj/.claude/backlog/orphan-open.md" "$Rj/orphan-open.snap"
out_j=$(bash "$RECONCILE" --root "$Rj")
if [ ! -f "$Rj/.claude/backlog/orphan-done.md" ]; then
  pass "(j) closed-status orphan pruned (deleted)"
else
  fail "(j) closed-status orphan pruned (deleted)" "file still exists"
fi
if [ -f "$Rj/.claude/backlog/orphan-open.md" ]; then
  pass "(j) open-status orphan NOT deleted (no silent loss)"
else
  fail "(j) open-status orphan NOT deleted (no silent loss)" "file was deleted"
fi
if cmp -s "$Rj/.claude/backlog/orphan-open.md" "$Rj/orphan-open.snap"; then
  pass "(j) open-status orphan file byte-unchanged"
else
  fail "(j) open-status orphan file byte-unchanged" "cmp differs"
fi
assert_out_match "(j) open-status orphan reported for manual triage" "$out_j" 'ORPHAN not pruned.*orphan-open'
# Orphans never get an invented index row (reconcile MUST NOT invent new backlog items).
assert_file_nomatch "(j) orphan-done never gets an index row" "$Rj/.claude/backlog.md" 'orphan-done\.md'
assert_file_nomatch "(j) orphan-open never gets an index row" "$Rj/.claude/backlog.md" 'orphan-open\.md'
# Idempotent: second run over the surviving open orphan reports it again (still needs triage),
# not silently swallowed, but changes nothing on disk.
cp "$Rj/.claude/backlog/orphan-open.md" "$Rj/orphan-open.snap2"
bash "$RECONCILE" --root "$Rj" >/dev/null
if cmp -s "$Rj/.claude/backlog/orphan-open.md" "$Rj/orphan-open.snap2"; then
  pass "(j) open-status orphan stable across repeated reconcile"
else
  fail "(j) open-status orphan stable across repeated reconcile" "cmp differs"
fi

# --- (k) Local CANCELLED / CANCELED terminal prune (CDT-160 AC4) ---
# Mirror (g) DONE closer: Status CANCELLED|CANCELED → file deleted, row gone; PENDING sibling stays.
Rk="$TMP/k"
mkdir -p "$Rk/.claude/backlog"
cat > "$Rk/.claude/backlog.md" <<'EOF'
# Backlog

## Pending

- [Cancelled UK](backlog/cancelled-uk.md) - dropped [PENDING]
- [Canceled US](backlog/canceled-us.md) - dropped [PENDING]
- [Still open](backlog/still-open.md) - stays [PENDING]

## Completed

EOF
item_file "$Rk/.claude/backlog/cancelled-uk.md" "CANCELLED"
item_file "$Rk/.claude/backlog/canceled-us.md" "CANCELED"
item_file "$Rk/.claude/backlog/still-open.md" "PENDING"
bash "$RECONCILE" --root "$Rk" >/dev/null
if [ ! -f "$Rk/.claude/backlog/cancelled-uk.md" ]; then
  pass "(k) local CANCELLED item file pruned (deleted)"
else
  fail "(k) local CANCELLED item file pruned (deleted)" "file still exists"
fi
if [ ! -f "$Rk/.claude/backlog/canceled-us.md" ]; then
  pass "(k) local CANCELED item file pruned (deleted)"
else
  fail "(k) local CANCELED item file pruned (deleted)" "file still exists"
fi
assert_file_nomatch "(k) CANCELLED row removed from index" "$Rk/.claude/backlog.md" 'cancelled-uk\.md'
assert_file_nomatch "(k) CANCELED row removed from index" "$Rk/.claude/backlog.md" 'canceled-us\.md'
assert_file_match "(k) PENDING sibling stays open" "$Rk/.claude/backlog.md" 'still-open\.md\).*\[PENDING\]'
assert_file_match "(k) PENDING item Status unchanged" "$Rk/.claude/backlog/still-open.md" '^\*\*Status\*\*: PENDING'

# --- (l) Linear Cancelled / Canceled verdicts prune PENDING local (CDT-160 AC4) ---
Rl="$TMP/l"
mkdir -p "$Rl/.claude/backlog"
cat > "$Rl/.claude/backlog.md" <<'EOF'
# Backlog

## Pending

- [Lin cancel UK](backlog/lin-cancel-uk.md) - cancelled in Linear [PENDING]
- [Lin cancel US](backlog/lin-cancel-us.md) - canceled in Linear [PENDING]
- [Lin open](backlog/lin-open.md) - no verdict [PENDING]

## Completed

EOF
item_file "$Rl/.claude/backlog/lin-cancel-uk.md" "PENDING"
item_file "$Rl/.claude/backlog/lin-cancel-us.md" "PENDING"
item_file "$Rl/.claude/backlog/lin-open.md" "PENDING"
# Mixed case as Linear MCP may emit (is_closed_status is case-insensitive).
printf 'lin-cancel-uk\tCancelled\nlin-cancel-us\tCanceled\n' > "$Rl/verdicts.tsv"
out_l=$(bash "$RECONCILE" --root "$Rl" --linear-verdicts "$Rl/verdicts.tsv")
if [ ! -f "$Rl/.claude/backlog/lin-cancel-uk.md" ]; then
  pass "(l) Linear Cancelled verdict item pruned (deleted)"
else
  fail "(l) Linear Cancelled verdict item pruned (deleted)" "file still exists"
fi
if [ ! -f "$Rl/.claude/backlog/lin-cancel-us.md" ]; then
  pass "(l) Linear Canceled verdict item pruned (deleted)"
else
  fail "(l) Linear Canceled verdict item pruned (deleted)" "file still exists"
fi
assert_file_nomatch "(l) Cancelled row removed from index" "$Rl/.claude/backlog.md" 'lin-cancel-uk\.md'
assert_file_nomatch "(l) Canceled row removed from index" "$Rl/.claude/backlog.md" 'lin-cancel-us\.md'
assert_out_match "(l) prune reason cites Linear for Cancelled" "$out_l" "prune 'lin-cancel-uk'.*Linear verdict"
assert_out_match "(l) prune reason cites Linear for Canceled" "$out_l" "prune 'lin-cancel-us'.*Linear verdict"
assert_file_match "(l) non-verdict sibling stays PENDING" "$Rl/.claude/backlog.md" 'lin-open\.md\).*\[PENDING\]'
assert_file_match "(l) non-verdict item Status still PENDING" "$Rl/.claude/backlog/lin-open.md" '^\*\*Status\*\*: PENDING'

# --- (m) Non-terminal Linear verdict (UNDONE) does not prune; PENDING stays open ---
Rm="$TMP/m"
mkdir -p "$Rm/.claude/backlog"
cat > "$Rm/.claude/backlog.md" <<'EOF'
# Backlog

## Pending

- [Not terminal](backlog/not-terminal.md) - UNDONE is open [PENDING]
- [Done via Linear](backlog/done-via-linear.md) - Done still prunes [PENDING]

## Completed

EOF
item_file "$Rm/.claude/backlog/not-terminal.md" "PENDING"
item_file "$Rm/.claude/backlog/done-via-linear.md" "PENDING"
printf 'not-terminal\tUNDONE\ndone-via-linear\tDone\n' > "$Rm/verdicts.tsv"
bash "$RECONCILE" --root "$Rm" --linear-verdicts "$Rm/verdicts.tsv" >/dev/null
if [ -f "$Rm/.claude/backlog/not-terminal.md" ]; then
  pass "(m) UNDONE Linear verdict does NOT prune item"
else
  fail "(m) UNDONE Linear verdict does NOT prune item" "file was deleted"
fi
assert_file_match "(m) UNDONE verdict slug stays PENDING in index" "$Rm/.claude/backlog.md" 'not-terminal\.md\).*\[PENDING\]'
assert_file_match "(m) UNDONE item Status still PENDING" "$Rm/.claude/backlog/not-terminal.md" '^\*\*Status\*\*: PENDING'
# Control: Done verdict still prunes (existing DONE path remains green under same run).
if [ ! -f "$Rm/.claude/backlog/done-via-linear.md" ]; then
  pass "(m) Done Linear verdict still prunes (DONE path green)"
else
  fail "(m) Done Linear verdict still prunes (DONE path green)" "file still exists"
fi
assert_file_nomatch "(m) Done-verdict row removed" "$Rm/.claude/backlog.md" 'done-via-linear\.md'

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
