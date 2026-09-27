#!/usr/bin/env bash
# skills/backlog/reconcile-test.sh — deterministic subprocess tests for reconcile.sh.
# Offline: no network, no LLM, no MCP. Each case drives reconcile.sh via --root into a
# fresh ${TMPDIR:-/tmp} fixture. See specs/core/SPEC-009-ticket-workflow.md §"Backlog reconcile".
# smoke parses it with `bash -n`; the all-suites runner runs it (SPEC-030).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RECONCILE="$HERE/reconcile.sh"
# shellcheck source=../../tests/lib/hermetic.sh
. "$HERE/../../tests/lib/hermetic.sh"
hermetic_init
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR 2>/dev/null || true
export GIT_CEILING_DIRECTORIES="$HERMETIC_ROOT"
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

TMP="$TMPDIR/reconcile-fixtures"
mkdir -p "$TMP"

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

# --- (n) CDT-175 Slug charset guard: path-escape row must not touch FS outside backlog dir ---
Rn="$TMP/n"
mkdir -p "$Rn/.claude/backlog"
mkdir -p "$TMP/canary"
item_file "$TMP/canary/pwned.md" "COMPLETED"
cp "$TMP/canary/pwned.md" "$TMP/canary/pwned.snap"
HOSTILE_ROW='- [Hostile](backlog/../../../canary/pwned.md) - x [PENDING]'
cat > "$Rn/.claude/backlog.md" <<EOF
# Backlog

## Pending

$HOSTILE_ROW
- [Live](backlog/live.md) - normal item [PENDING]

## Completed

EOF
item_file "$Rn/.claude/backlog/live.md" "PENDING"
rc_n1=0
out_n1=$(bash "$RECONCILE" --root "$Rn") || rc_n1=$?
if [ "$rc_n1" -eq 0 ]; then pass "(n) exit 0 with invalid slug present"
else fail "(n) exit 0 with invalid slug present" "rc=$rc_n1"
fi
if [ -f "$TMP/canary/pwned.md" ]; then
  pass "(n) canary file outside backlog dir survives (no path escape)"
else
  fail "(n) canary file outside backlog dir survives (no path escape)" "canary file was deleted"
fi
if cmp -s "$TMP/canary/pwned.md" "$TMP/canary/pwned.snap"; then
  pass "(n) canary file byte-unchanged"
else
  fail "(n) canary file byte-unchanged" "cmp differs"
fi
if grep -qxF -- "$HOSTILE_ROW" "$Rn/.claude/backlog.md"; then
  pass "(n) hostile row still present verbatim in rewritten index"
else
  fail "(n) hostile row still present verbatim in rewritten index" "row altered or missing"
fi
assert_out_match "(n) INVALID slug notice printed" "$out_n1" 'INVALID slug not reconciled'
assert_file_match "(n) valid sibling row still reconciles (stays PENDING)" "$Rn/.claude/backlog.md" 'live\.md\).*\[PENDING\]'
cp "$Rn/.claude/backlog.md" "$Rn/idx.snap1"
out_n2=$(bash "$RECONCILE" --root "$Rn")
if cmp -s "$Rn/.claude/backlog.md" "$Rn/idx.snap1"; then
  pass "(n) second run: index byte-identical (idempotent)"
else
  fail "(n) second run: index byte-identical (idempotent)" "cmp differs"
fi
assert_out_match "(n) second run repeats INVALID slug notice" "$out_n2" 'INVALID slug not reconciled'
out_n3=$(bash "$RECONCILE" --root "$Rn" --dry-run)
assert_out_match "(n) dry-run reports INVALID slug" "$out_n3" 'INVALID slug not reconciled'


# --- (o) AC A: MROOT root resolution from a worktree, no --root; no store in the worktree ---
Ro="$TMP/o"
mkdir -p "$Ro"
Mo="$Ro/M"
git init -q "$Mo"
echo seed > "$Mo/seed.txt"
git -C "$Mo" add seed.txt
git -C "$Mo" commit -q -m seed
mkdir -p "$Mo/.claude/backlog"
cat > "$Mo/.claude/backlog.md" <<'EOF'
# Backlog

## Pending

- [Done in M](backlog/done-in-m.md) - closed [PENDING]
- [Open in M](backlog/open-in-m.md) - stays [PENDING]

## Completed

EOF
item_file "$Mo/.claude/backlog/done-in-m.md" "COMPLETED"
item_file "$Mo/.claude/backlog/open-in-m.md" "PENDING"
git -C "$Mo" worktree add -q "$Mo/.worktrees/x" -b feat/wp-1-04-o
WTo="$Mo/.worktrees/x"
out_o=$(cd "$WTo" && bash "$RECONCILE")
assert_file_nomatch "(o) MROOT resolve: terminal item pruned from shared index" "$Mo/.claude/backlog.md" 'done-in-m\.md'
if [ ! -f "$Mo/.claude/backlog/done-in-m.md" ]; then
  pass "(o) MROOT resolve: terminal item file pruned (deleted)"
else
  fail "(o) MROOT resolve: terminal item file pruned (deleted)" "file still exists"
fi
assert_file_match "(o) MROOT resolve: open sibling stays PENDING" "$Mo/.claude/backlog.md" 'open-in-m\.md\).*\[PENDING\]'
if [ ! -e "$WTo/.claude/backlog.md" ] && [ ! -d "$WTo/.claude/backlog" ]; then
  pass "(o) no backlog store created under the worktree"
else
  fail "(o) no backlog store created under the worktree" "found .claude/backlog under $WTo"
fi

# --- (p)/(q)/(r) AC C/D: shared lock ---
make_lock() {
  local dir="$1" epoch="$2" owner="${3:-manual-holder}"
  mkdir -p "$dir"
  printf '%s %s %s\n' "$epoch" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$owner" > "$dir/stamp"
}

# (p) held FRESH lock + WAIT=1 -> exit 1, stderr names the lock path, nothing changes.
Rp="$TMP/p"
mkdir -p "$Rp/.claude/backlog"
cat > "$Rp/.claude/backlog.md" <<'EOF'
# Backlog

## Pending

- [Prune me](backlog/prune-p.md) - will try to prune [PENDING]

## Completed

EOF
item_file "$Rp/.claude/backlog/prune-p.md" "COMPLETED"
cp "$Rp/.claude/backlog.md" "$Rp/idx.snap"
cp "$Rp/.claude/backlog/prune-p.md" "$Rp/item.snap"
make_lock "$Rp/.claude/backlog.lock" "$(date +%s)"
rc_p=0
out_p=$(BACKLOG_LOCK_WAIT_SECONDS=1 bash "$RECONCILE" --root "$Rp" 2>&1) || rc_p=$?
if [ "$rc_p" -eq 1 ]; then pass "(p) held fresh lock: exit 1"
else fail "(p) held fresh lock: exit 1" "rc=$rc_p"
fi
assert_out_match "(p) stderr names the lock path" "$out_p" 'backlog\.lock'
if cmp -s "$Rp/.claude/backlog.md" "$Rp/idx.snap"; then
  pass "(p) index unchanged while lock busy"
else
  fail "(p) index unchanged while lock busy" "cmp differs"
fi
if cmp -s "$Rp/.claude/backlog/prune-p.md" "$Rp/item.snap"; then
  pass "(p) item file unchanged while lock busy"
else
  fail "(p) item file unchanged while lock busy" "cmp differs"
fi

# (q) --dry-run under a held (foreign) lock: exits 0 fast, never waits, no change.
Rq="$TMP/q"
mkdir -p "$Rq/.claude/backlog"
cat > "$Rq/.claude/backlog.md" <<'EOF'
# Backlog

## Pending

- [Prune me](backlog/prune-q.md) - would prune [PENDING]

## Completed

EOF
item_file "$Rq/.claude/backlog/prune-q.md" "COMPLETED"
cp "$Rq/.claude/backlog.md" "$Rq/idx.snap"
make_lock "$Rq/.claude/backlog.lock" "$(date +%s)"
start_q=$(date +%s)
rc_q=0
out_q=$(bash "$RECONCILE" --root "$Rq" --dry-run 2>&1) || rc_q=$?
end_q=$(date +%s)
if [ "$rc_q" -eq 0 ]; then pass "(q) --dry-run exit 0 under a held lock"
else fail "(q) --dry-run exit 0 under a held lock" "rc=$rc_q"
fi
elapsed_q=$(( end_q - start_q ))
if [ "$elapsed_q" -lt 5 ]; then pass "(q) --dry-run does not wait on the lock (elapsed ${elapsed_q}s)"
else fail "(q) --dry-run does not wait on the lock" "elapsed ${elapsed_q}s"
fi
if cmp -s "$Rq/.claude/backlog.md" "$Rq/idx.snap"; then
  pass "(q) index unchanged under --dry-run with a held lock"
else
  fail "(q) index unchanged under --dry-run with a held lock" "cmp differs"
fi
if [ -d "$Rq/.claude/backlog.lock" ]; then
  pass "(q) --dry-run leaves the foreign lock untouched"
else
  fail "(q) --dry-run leaves the foreign lock untouched" "lock dir gone"
fi

# (r) STALE lock (age >= TTL) is reclaimed; run proceeds and releases on exit.
Rr="$TMP/r"
mkdir -p "$Rr/.claude/backlog"
cat > "$Rr/.claude/backlog.md" <<'EOF'
# Backlog

## Pending

- [Prune me](backlog/prune-r.md) - will prune [PENDING]

## Completed

EOF
item_file "$Rr/.claude/backlog/prune-r.md" "COMPLETED"
make_lock "$Rr/.claude/backlog.lock" "$(( $(date +%s) - 120 ))" "stale-holder"
out_r=$(bash "$RECONCILE" --root "$Rr")
assert_out_match "(r) stale lock reclaimed: prune still applies" "$out_r" "prune 'prune-r'"
if [ ! -f "$Rr/.claude/backlog/prune-r.md" ]; then
  pass "(r) stale lock reclaimed: item pruned"
else
  fail "(r) stale lock reclaimed: item pruned" "file still exists"
fi
if [ ! -d "$Rr/.claude/backlog.lock" ]; then
  pass "(r) lock released after a successful reclaim+run"
else
  fail "(r) lock released after a successful reclaim+run" "lock dir still present"
fi

# --- (s) AC H: blank verdict is non-terminal (TSV empty state, bare slug, JSON "", JSON null) ---
Rs="$TMP/s"
mkdir -p "$Rs/.claude/backlog"
cat > "$Rs/.claude/backlog.md" <<'EOF'
# Backlog

## Pending

- [Blank TSV state](backlog/blank-tsv-s.md) - tab, empty state [PENDING]
- [Bare TSV slug](backlog/bare-tsv-s.md) - no state field at all [PENDING]
- [Blank JSON obj](backlog/blank-obj-s.md) - JSON object empty string [PENDING]
- [Blank JSON arr](backlog/blank-arr-s.md) - JSON array null state [PENDING]

## Completed

EOF
item_file "$Rs/.claude/backlog/blank-tsv-s.md" "PENDING"
item_file "$Rs/.claude/backlog/bare-tsv-s.md" "PENDING"
item_file "$Rs/.claude/backlog/blank-obj-s.md" "PENDING"
item_file "$Rs/.claude/backlog/blank-arr-s.md" "PENDING"
cp "$Rs/.claude/backlog.md" "$Rs/idx.snap"

printf 'blank-tsv-s\t\nbare-tsv-s\n' > "$Rs/verdicts-tsv.txt"
out_s1=$(bash "$RECONCILE" --root "$Rs" --linear-verdicts "$Rs/verdicts-tsv.txt")
assert_out_match "(s) TSV blank/bare verdicts: no changes" "$out_s1" 'no changes'

printf '{"blank-obj-s":""}' > "$Rs/verdicts-obj.json"
out_s2=$(bash "$RECONCILE" --root "$Rs" --linear-verdicts "$Rs/verdicts-obj.json")
assert_out_match "(s) JSON flat-object blank state: no changes" "$out_s2" 'no changes'

printf '[{"slug":"blank-arr-s","state":null}]' > "$Rs/verdicts-arr.json"
out_s3=$(bash "$RECONCILE" --root "$Rs" --linear-verdicts "$Rs/verdicts-arr.json")
assert_out_match "(s) JSON array null state: no changes" "$out_s3" 'no changes'

if cmp -s "$Rs/.claude/backlog.md" "$Rs/idx.snap"; then
  pass "(s) index byte-unchanged across all blank-verdict runs"
else
  fail "(s) index byte-unchanged across all blank-verdict runs" "cmp differs"
fi
for slug in blank-tsv-s bare-tsv-s blank-obj-s blank-arr-s; do
  if [ -f "$Rs/.claude/backlog/${slug}.md" ]; then
    pass "(s) $slug item file NOT pruned (blank verdict is non-terminal)"
  else
    fail "(s) $slug item file NOT pruned (blank verdict is non-terminal)" "file was deleted"
  fi
done

# --- (t) AC I: verdict precedence (slug>id, state>status), malformed JSON fail-closed, jq-less PATH ---
Rt="$TMP/t"
mkdir -p "$Rt/.claude/backlog"
cat > "$Rt/.claude/backlog.md" <<'EOF'
# Backlog

## Pending

- [Slug a](backlog/a.md) - array slug/state [PENDING]
- [Slug b](backlog/b.md) - id vs slug precedence [PENDING]
- [Slug x](backlog/x.md) - state vs status precedence [PENDING]

## Completed

EOF
item_file "$Rt/.claude/backlog/a.md" "PENDING"
item_file "$Rt/.claude/backlog/b.md" "PENDING"
item_file "$Rt/.claude/backlog/x.md" "PENDING"
cat > "$Rt/verdicts-precedence.json" <<'EOF'
[
  {"state":"Done","slug":"a"},
  {"slug":"b","id":"CDT-9","status":"Done"},
  {"slug":"x","status":"Open","state":"Done"}
]
EOF
bash "$RECONCILE" --root "$Rt" --linear-verdicts "$Rt/verdicts-precedence.json" >/dev/null
for slug in a b x; do
  if [ ! -f "$Rt/.claude/backlog/${slug}.md" ]; then
    pass "(t) verdict precedence: '$slug' pruned"
  else
    fail "(t) verdict precedence: '$slug' pruned" "file still exists"
  fi
done
assert_file_nomatch "(t) verdict precedence: no row keyed by id 'CDT-9'" "$Rt/.claude/backlog.md" 'CDT-9'

# malformed JSON verdicts -> exit 1, nothing touched (each case against the same snapshot).
Rt2="$TMP/t2"
mkdir -p "$Rt2/.claude/backlog"
cat > "$Rt2/.claude/backlog.md" <<'EOF'
# Backlog

## Pending

- [Untouched](backlog/untouched-t2.md) - stays [PENDING]

## Completed

EOF
item_file "$Rt2/.claude/backlog/untouched-t2.md" "PENDING"
cp "$Rt2/.claude/backlog.md" "$Rt2/idx.snap"
cp "$Rt2/.claude/backlog/untouched-t2.md" "$Rt2/item.snap"
printf '{bad' > "$Rt2/bad1.json"
printf '[1]' > "$Rt2/bad2.json"
printf '{"a":1}' > "$Rt2/bad3.json"
printf '[{"state":"Done"}]' > "$Rt2/bad4.json"
for f in bad1.json bad2.json bad3.json bad4.json; do
  rc=0
  bash "$RECONCILE" --root "$Rt2" --linear-verdicts "$Rt2/$f" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 1 ]; then pass "(t) malformed verdicts $f: exit 1"
  else fail "(t) malformed verdicts $f: exit 1" "rc=$rc"
  fi
done
if cmp -s "$Rt2/.claude/backlog.md" "$Rt2/idx.snap"; then
  pass "(t) malformed verdicts: index unchanged across all cases"
else
  fail "(t) malformed verdicts: index unchanged across all cases" "cmp differs"
fi
if cmp -s "$Rt2/.claude/backlog/untouched-t2.md" "$Rt2/item.snap"; then
  pass "(t) malformed verdicts: item file unchanged"
else
  fail "(t) malformed verdicts: item file unchanged" "cmp differs"
fi

# jq-less PATH: JSON verdicts hard-fail; TSV verdicts still work. Shim = symlinks to exactly the
# external tools reconcile.sh/lock.sh/portable.sh/terminal-status.sh call, minus jq.
SHIM="$TMP/shim-nojq"
mkdir -p "$SHIM"
for tool in bash awk basename dirname grep sed tr rm mv mkdir stat chmod mktemp date sleep; do
  real=$(command -v "$tool" 2>/dev/null) || continue
  ln -sf "$real" "$SHIM/$tool"
done
Rt3="$TMP/t3"
mkdir -p "$Rt3/.claude/backlog"
cat > "$Rt3/.claude/backlog.md" <<'EOF'
# Backlog

## Pending

- [JQ needed](backlog/needs-jq-t3.md) - closed via Linear [PENDING]

## Completed

EOF
item_file "$Rt3/.claude/backlog/needs-jq-t3.md" "PENDING"
cp "$Rt3/.claude/backlog.md" "$Rt3/idx.snap"
printf '{"needs-jq-t3":"Done"}' > "$Rt3/verdicts.json"
rc_t3=0
out_t3=$(PATH="$SHIM" bash "$RECONCILE" --root "$Rt3" --linear-verdicts "$Rt3/verdicts.json" 2>&1) || rc_t3=$?
if [ "$rc_t3" -eq 1 ]; then pass "(t) JSON verdicts with no jq on PATH: exit 1"
else fail "(t) JSON verdicts with no jq on PATH: exit 1" "rc=$rc_t3"
fi
assert_out_match "(t) jq-required error names the file" "$out_t3" 'jq required'
if cmp -s "$Rt3/.claude/backlog.md" "$Rt3/idx.snap"; then
  pass "(t) JSON verdicts with no jq on PATH: index unchanged"
else
  fail "(t) JSON verdicts with no jq on PATH: index unchanged" "cmp differs"
fi
printf 'needs-jq-t3\tDone\n' > "$Rt3/verdicts.tsv"
out_t3b=$(PATH="$SHIM" bash "$RECONCILE" --root "$Rt3" --linear-verdicts "$Rt3/verdicts.tsv")
if [ ! -f "$Rt3/.claude/backlog/needs-jq-t3.md" ]; then
  pass "(t) TSV verdicts still work with no jq on PATH"
else
  fail "(t) TSV verdicts still work with no jq on PATH" "file still exists"
fi

# --- (u) AC K: line-preserving stream ---
Ru="$TMP/u"
mkdir -p "$Ru/.claude/backlog"
cat > "$Ru/.claude/backlog.md" <<'EOF'
# Backlog

Some intro prose that must survive untouched.

### A sub-heading

## Pending

- [Keep](backlog/keep-u.md) - stays open [PENDING]
  - a nested detail line
  - another nested detail line

- [Terminal](backlog/terminal-u.md) - will be pruned [PENDING]
- [Ghost](backlog/ghost-u.md) - dead reference [PENDING]
- [Dup](backlog/dup-u.md) - first occurrence [PENDING]
- [Dup](backlog/dup-u.md) - second occurrence (duplicate) [PENDING]

## Completed

EOF
item_file "$Ru/.claude/backlog/keep-u.md" "PENDING"
item_file "$Ru/.claude/backlog/terminal-u.md" "COMPLETED"
item_file "$Ru/.claude/backlog/dup-u.md" "PENDING"
# ghost-u.md deliberately absent (dead reference).

cat > "$Ru/expected.md" <<'EOF'
# Backlog

Some intro prose that must survive untouched.

### A sub-heading

## Pending

- [Keep](backlog/keep-u.md) - stays open [PENDING]
  - a nested detail line
  - another nested detail line

- [Dup](backlog/dup-u.md) - first occurrence [PENDING]

## Completed

EOF

bash "$RECONCILE" --root "$Ru" >/dev/null
if cmp -s "$Ru/.claude/backlog.md" "$Ru/expected.md"; then
  pass "(u) line-preserving: result matches fixture minus exactly the dropped rows"
else
  fail "(u) line-preserving: result matches fixture minus exactly the dropped rows" "cmp differs"
fi
cp "$Ru/.claude/backlog.md" "$Ru/after1.snap"
out_u2=$(bash "$RECONCILE" --root "$Ru")
assert_out_match "(u) second run: no changes" "$out_u2" 'no changes'
if cmp -s "$Ru/.claude/backlog.md" "$Ru/after1.snap"; then
  pass "(u) second run: index byte-unchanged"
else
  fail "(u) second run: index byte-unchanged" "cmp differs"
fi

# No-drop fixture: never rewritten -> keeps its inode and its missing trailing newline.
Ru2="$TMP/u2"
mkdir -p "$Ru2/.claude/backlog"
printf '%s' "$(cat <<'EOF'
# Backlog

## Pending

- [Solo](backlog/solo-u2.md) - stays open, no drops here [PENDING]

## Completed
EOF
)" > "$Ru2/.claude/backlog.md"
item_file "$Ru2/.claude/backlog/solo-u2.md" "PENDING"
cp "$Ru2/.claude/backlog.md" "$Ru2/idx.snap"
ino_before=$(ls -i "$Ru2/.claude/backlog.md" | awk '{print $1}')
out_u3=$(bash "$RECONCILE" --root "$Ru2")
ino_after=$(ls -i "$Ru2/.claude/backlog.md" | awk '{print $1}')
assert_out_match "(u) no-drop fixture: reconcile reports no changes" "$out_u3" 'no changes'
if [ "$ino_before" = "$ino_after" ]; then
  pass "(u) no-drop fixture: index inode unchanged (never rewritten)"
else
  fail "(u) no-drop fixture: index inode unchanged (never rewritten)" "inode changed: $ino_before -> $ino_after"
fi
if cmp -s "$Ru2/.claude/backlog.md" "$Ru2/idx.snap"; then
  pass "(u) no-drop fixture: byte-identical, including the missing trailing newline"
else
  fail "(u) no-drop fixture: byte-identical, including the missing trailing newline" "cmp differs"
fi

# --- (v) AC L/M: index mode kept after a drop; no temp files left under .claude/ ---
Rv="$TMP/v"
mkdir -p "$Rv/.claude/backlog"
cat > "$Rv/.claude/backlog.md" <<'EOF'
# Backlog

## Pending

- [Prune me](backlog/prune-v.md) - will drop [PENDING]
- [Stay](backlog/stay-v.md) - keeps [PENDING]

## Completed

EOF
item_file "$Rv/.claude/backlog/prune-v.md" "COMPLETED"
item_file "$Rv/.claude/backlog/stay-v.md" "PENDING"
chmod 0664 "$Rv/.claude/backlog.md"
bash "$RECONCILE" --root "$Rv" >/dev/null
mode_v=$(stat -c %a "$Rv/.claude/backlog.md" 2>/dev/null || stat -f %Lp "$Rv/.claude/backlog.md")
if [ "$mode_v" = "664" ]; then
  pass "(v) index mode 0664 kept after a drop"
else
  fail "(v) index mode 0664 kept after a drop" "mode=$mode_v"
fi
leftover_v=$(find "$Rv/.claude" -name '.*.tmp.*' 2>/dev/null | wc -l | tr -d ' ')
if [ "$leftover_v" = "0" ]; then
  pass "(v) no temp files left under .claude/"
else
  fail "(v) no temp files left under .claude/" "found: $(find "$Rv/.claude" -name '.*.tmp.*')"
fi

# --- (w) WP 1-04 rework T4-1: pass 1 must classify the FINAL index row even
# when the file has no trailing newline. Bug: pass 1's read loop dropped the
# last row silently; its slug never entered DISPOSITION, so emit_index's
# default case dropped the row a second time and the orphan scan then
# reported the still-PENDING item as a false ORPHAN. ---
Rw="$TMP/w"
mkdir -p "$Rw/.claude/backlog"
printf '%s' "$(cat <<'EOF'
# Backlog

## Pending

- [A item](backlog/a-nl.md) - stays open [PENDING]
- [B item](backlog/b-nl.md) - will prune [PENDING]
- [C item](backlog/c-nl.md) - last row, file has no trailing newline [PENDING]
EOF
)" > "$Rw/.claude/backlog.md"
item_file "$Rw/.claude/backlog/a-nl.md" "PENDING"
item_file "$Rw/.claude/backlog/b-nl.md" "COMPLETED"
item_file "$Rw/.claude/backlog/c-nl.md" "PENDING"
cp "$Rw/.claude/backlog/c-nl.md" "$Rw/c-nl.snap"
out_w=$(bash "$RECONCILE" --root "$Rw")
assert_file_match "(w) row a stays PENDING" "$Rw/.claude/backlog.md" 'a-nl\.md\).*\[PENDING\]'
assert_file_nomatch "(w) row b (COMPLETED) pruned from index" "$Rw/.claude/backlog.md" 'b-nl\.md'
assert_file_match "(w) final row c (no trailing newline) preserved, not dropped" \
  "$Rw/.claude/backlog.md" 'c-nl\.md\).*\[PENDING\]'
if [ -f "$Rw/.claude/backlog/c-nl.md" ]; then
  pass "(w) item c.md NOT deleted (previously silently pruned as a false orphan)"
else
  fail "(w) item c.md NOT deleted (previously silently pruned as a false orphan)" "file was deleted"
fi
if cmp -s "$Rw/.claude/backlog/c-nl.md" "$Rw/c-nl.snap"; then
  pass "(w) item c.md byte-unchanged"
else
  fail "(w) item c.md byte-unchanged" "cmp differs"
fi
if [ ! -f "$Rw/.claude/backlog/b-nl.md" ]; then
  pass "(w) item b.md pruned (deleted)"
else
  fail "(w) item b.md pruned (deleted)" "file still exists"
fi
if printf '%s' "$out_w" | grep -qE 'ORPHAN.*c-nl'; then
  fail "(w) c-nl must NOT be reported as an ORPHAN" "got: $out_w"
else
  pass "(w) c-nl must NOT be reported as an ORPHAN"
fi

# --- (x) WP 1-04 rework T4-2: emit_index must not swallow a mid-stream
# producer write failure. atomic_write runs emit_index inside an `if`
# (errexit off in there); an unguarded printf failure was masked by a later
# successful printf, so the function returned 0 and a truncated temp file got
# renamed over the index. Deterministic repro: override the `printf` builtin
# with an exported bash function that fails only for a marker line, so exactly
# one write inside emit_index fails while later writes would otherwise
# succeed. ---
Rx="$TMP/x-write-fail"
mkdir -p "$Rx/.claude/backlog"
cat > "$Rx/.claude/backlog.md" <<'EOF'
# Backlog

PRINTF_FAIL_MARKER prose line that must trigger a producer write failure

## Pending

- [Prune me](backlog/prune-x.md) - will drop [PENDING]
- [Stay](backlog/stay-x.md) - keeps [PENDING]

## Completed

EOF
item_file "$Rx/.claude/backlog/prune-x.md" "COMPLETED"
item_file "$Rx/.claude/backlog/stay-x.md" "PENDING"
cp "$Rx/.claude/backlog.md" "$Rx/idx.snap"
cp "$Rx/.claude/backlog/prune-x.md" "$Rx/prune-x.snap"

# Match only emit_index's exact call shape (format arg exactly %s\n, one
# further arg) so this does not also intercept unrelated printf calls
# elsewhere (row_slug uses format %s, no trailing newline — a plain substring
# match would abort pass 1 for the wrong reason instead of emit_index).
printf() {
  if [ "$1" = '%s\n' ] && [ "$#" -eq 2 ]; then
    case "$2" in
      *PRINTF_FAIL_MARKER*) return 7 ;;
    esac
  fi
  builtin printf "$@"
}
export -f printf
rc_x=0
out_x=$(bash "$RECONCILE" --root "$Rx" 2>&1) || rc_x=$?
unset -f printf

if [ "$rc_x" -ne 0 ]; then
  pass "(x) producer write failure: reconcile exits non-zero"
else
  fail "(x) producer write failure: reconcile exits non-zero" "rc=0 out=$out_x"
fi
if cmp -s "$Rx/.claude/backlog.md" "$Rx/idx.snap"; then
  pass "(x) producer write failure: index cmp-unchanged"
else
  fail "(x) producer write failure: index cmp-unchanged" "cmp differs"
fi
if cmp -s "$Rx/.claude/backlog/prune-x.md" "$Rx/prune-x.snap"; then
  pass "(x) producer write failure: pruned item file NOT deleted (index write failed first)"
else
  fail "(x) producer write failure: pruned item file NOT deleted (index write failed first)" "cmp differs or missing"
fi
leftover_x=$(find "$Rx/.claude" -name '.*.tmp.*' 2>/dev/null | wc -l | tr -d ' ')
if [ "$leftover_x" = "0" ]; then
  pass "(x) producer write failure: no leftover temp file"
else
  fail "(x) producer write failure: no leftover temp file" "found: $(find "$Rx/.claude" -name '.*.tmp.*')"
fi


# --- (y) WP 1-04 rework 2 N2: load_verdicts' TSV loop must classify the FINAL
# verdicts line even when the file has no trailing newline. Bug: the read loop
# dropped the last line silently, so a verdict on the last line never entered
# VERDICT_SLUGS and its slug fell through to local (PENDING) status instead
# of pruning. ---
Ry="$TMP/y-verdicts-no-nl"
mkdir -p "$Ry/.claude/backlog"
cat > "$Ry/.claude/backlog.md" <<'EOF'
# Backlog

## Pending

- [First](backlog/first-y.md) - no verdict [PENDING]
- [Last](backlog/last-y.md) - verdict on final unterminated line [PENDING]

## Completed

EOF
item_file "$Ry/.claude/backlog/first-y.md" "PENDING"
item_file "$Ry/.claude/backlog/last-y.md" "PENDING"
printf 'first-y\tOpen\nlast-y\tDone' > "$Ry/verdicts.tsv"
bash "$RECONCILE" --root "$Ry" --linear-verdicts "$Ry/verdicts.tsv" >/dev/null
if [ ! -f "$Ry/.claude/backlog/last-y.md" ]; then
  pass "(y) final unterminated verdicts line prunes its slug"
else
  fail "(y) final unterminated verdicts line prunes its slug" "file still exists"
fi
assert_file_nomatch "(y) pruned row removed from index" "$Ry/.claude/backlog.md" 'last-y\.md'
assert_file_match "(y) non-verdict sibling stays PENDING" "$Ry/.claude/backlog.md" 'first-y\.md\).*\[PENDING\]'

# --- (z) 10b gap 3 / SPEC-009 detection rule: JSON is decided by the file's
# FIRST NON-BLANK CHARACTER, not its first line. A verdicts file that opens
# with blank lines, then a JSON array, must still be read as JSON (and
# prune), never misread as TSV. ---
Rz="$TMP/z-blank-lines-json"
mkdir -p "$Rz/.claude/backlog"
cat > "$Rz/.claude/backlog.md" <<'EOF'
# Backlog

## Pending

- [Blank lines json](backlog/blank-lines-json-z.md) - terminal via JSON after blank lines [PENDING]

## Completed

EOF
item_file "$Rz/.claude/backlog/blank-lines-json-z.md" "PENDING"
printf '\n\n[{"slug":"blank-lines-json-z","state":"Done"}]\n' > "$Rz/verdicts.json"
bash "$RECONCILE" --root "$Rz" --linear-verdicts "$Rz/verdicts.json" >/dev/null
if [ ! -f "$Rz/.claude/backlog/blank-lines-json-z.md" ]; then
  pass "(z) leading-blank-lines JSON verdict prunes its slug"
else
  fail "(z) leading-blank-lines JSON verdict prunes its slug" "file still exists"
fi
assert_file_nomatch "(z) pruned row removed from index" "$Rz/.claude/backlog.md" 'blank-lines-json-z\.md'
echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
