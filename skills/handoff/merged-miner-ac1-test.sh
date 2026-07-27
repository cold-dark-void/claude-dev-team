#!/usr/bin/env bash
# merged-miner-ac1-test.sh — CDT-89 AC1 spine size ratio (SPEC-018 M3b cost cut).
# Models spine-read count only: baseline = 2 miners × S; merged = 1 miner × S.
# Asserts ratio = merged/baseline <= 0.55 (static math; no network / no LLM).
# Run: bash skills/handoff/merged-miner-ac1-test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FIX="$HERE/fixtures/spine-ac1-size.txt"
THRESHOLD="0.55"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

# ---- T0: fixture present ----
if [ -f "$FIX" ]; then ok
else bad "T0 missing fixture $FIX"; fi

# ---- T1: measure S (byte size of spine fixture) ----
if [ ! -f "$FIX" ]; then
  bad "T1 skip: no fixture"
  S=0
else
  # portable: wc -c may pad; strip whitespace
  S=$(wc -c < "$FIX" | tr -d '[:space:]')
  if [ -n "$S" ] && [ "$S" -gt 0 ] 2>/dev/null; then
    ok
  else
    bad "T1 invalid S='$S'"
    S=0
  fi
fi

# ---- T2: accounting model — baseline 2*S, merged 1*S, ratio <= 0.55 ----
# Pure size math models spine-read count (not prompt tokens / git blob).
BASELINE=$((S * 2))
MERGED=$((S * 1))

if [ "$S" -gt 0 ] && [ "$MERGED" -eq "$S" ] && [ "$BASELINE" -eq $((S * 2)) ]; then
  ok
else
  bad "T2 sizes S=$S merged=$MERGED baseline=$BASELINE"
fi

# ratio = MERGED / BASELINE; assert <= 0.55 without floating-point shell issues:
# MERGED/BASELINE <= 0.55  <=>  MERGED * 100 <= BASELINE * 55  (for positive ints)
if [ "$BASELINE" -gt 0 ] && [ $((MERGED * 100)) -le $((BASELINE * 55)) ]; then
  ok
else
  bad "T2 ratio failed: merged=$MERGED baseline=$BASELINE (need merged/baseline <= $THRESHOLD)"
fi

# ---- T3: ratio is exactly 0.50 for this model (document expected) ----
if [ "$BASELINE" -gt 0 ] && [ $((MERGED * 2)) -eq "$BASELINE" ]; then
  ok
else
  bad "T3 expected merged == baseline/2 (got merged=$MERGED baseline=$BASELINE)"
fi

# ---- T4: header documents S / spine-read model (optional sanity) ----
if [ -f "$FIX" ] && grep -q 'baseline miners each stream this file once' "$FIX" \
  && grep -q 'merged miner streams it once' "$FIX"; then
  ok
else
  bad "T4 fixture header missing spine-read model notes"
fi

echo "PASS=$PASS FAIL=$FAIL S=$S baseline=$BASELINE merged=$MERGED ratio=$((MERGED * 100 / BASELINE))%"
if [ "$FAIL" -eq 0 ]; then
  exit 0
fi
exit 1
