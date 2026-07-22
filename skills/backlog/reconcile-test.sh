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

# --- (a) Stale row: index PENDING but item file COMPLETED -> moved to Completed, item unchanged ---
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
cp "$Ra/.claude/backlog/stale.md" "$Ra/stale.snap"
bash "$RECONCILE" --root "$Ra" >/dev/null
# Row is now under ## Completed carrying [COMPLETED].
assert_file_match "(a) stale row tagged COMPLETED" "$Ra/.claude/backlog.md" 'stale\.md\).*\[COMPLETED\]'
assert_file_nomatch "(a) stale row no longer PENDING" "$Ra/.claude/backlog.md" 'stale\.md\).*\[PENDING\]'
# Confirm it physically sits below the ## Completed header (not just tagged).
if awk '/^## Completed/{c=1} c && /stale\.md/{found=1} END{exit !found}' "$Ra/.claude/backlog.md"; then
  pass "(a) stale row under ## Completed section"
else
  fail "(a) stale row under ## Completed section" "not found below header"
fi
# Item file already COMPLETED -> byte-identical (reconcile must not rewrite a closed item).
if cmp -s "$Ra/.claude/backlog/stale.md" "$Ra/stale.snap"; then
  pass "(a) item file otherwise unchanged"
else
  fail "(a) item file otherwise unchanged" "$(diff "$Ra/stale.snap" "$Ra/.claude/backlog/stale.md" | head -5)"
fi

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
bash "$RECONCILE" --root "$Re" --linear-verdicts "$Re/verdicts.tsv" >/dev/null
assert_file_match "(e) linear-closed row moved to COMPLETED" "$Re/.claude/backlog.md" 'shipped\.md\).*\[COMPLETED\]'
assert_file_match "(e) item Status flipped COMPLETED" "$Re/.claude/backlog/shipped.md" '^\*\*Status\*\*: COMPLETED'
assert_file_match "(e) linear reason footer" "$Re/.claude/backlog/shipped.md" '\(reconcile: linear\)'
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

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
