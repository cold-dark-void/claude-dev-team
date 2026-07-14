#!/usr/bin/env bash
# sidechain-test.sh — SPEC-018 M2 signal-bearing sidechain reconstruction (CDV-205).
# Run: bash skills/handoff/sidechain-test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
PREPASS="$HERE/prepass.sh"
FIX="$HERE/fixtures"
SIGNAL="$FIX/sidechain-signal.jsonl"
NOISE="$FIX/sidechain-noise.jsonl"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/sidechain-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# ---- T0: fixtures exist + ≥3 isSidechain true each ----
for F in "$SIGNAL" "$NOISE"; do
  if [ ! -f "$F" ]; then bad "missing fixture: $F"; continue; fi
  N=$(python3 -c '
import json,sys
n=0
for line in open(sys.argv[1]):
    line=line.strip()
    if not line: continue
    o=json.loads(line)
    if o.get("isSidechain"): n+=1
print(n)
' "$F")
  if [ "$N" -ge 3 ]; then ok; else bad "fixture $F: isSidechain count $N < 3"; fi
done

# ---- helper: prepare + print spine path ----
run_prepare() {
  local src=$1 out=$2
  # Copy so we can touch without mutating the repo fixture; allow-in-progress
  # because the copy is freshly written.
  local tr="$WORK/$(basename "$src")"
  cp "$src" "$tr"
  touch "$tr"
  bash "$PREPASS" prepare --uuid "00000000-0000-4000-8000-sidechain" \
    --transcript "$tr" --allow-in-progress --out "$out" 2>"$WORK/prep.err"
}

# ---- T1: signal fixture → spine has killed: + cue; no raw tool payload ----
PLAN_S="$WORK/signal-plan.json"
if run_prepare "$SIGNAL" "$PLAN_S"; then
  SP_S=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("spine",""))' "$PLAN_S")
  if [ -n "$SP_S" ] && [ -f "$SP_S" ]; then
    if grep -q 'sidechain signal' "$SP_S" && grep -q 'killed:' "$SP_S"; then ok
    else bad "T1 signal spine missing 'sidechain signal' / 'killed:'"; fi
    # cue substring from closed list (any of these proves cue path)
    if grep -qiE 'that didn.t work|wrong approach|abandoned|scratch that|hypothesis|dead end' "$SP_S"; then ok
    else bad "T1 signal spine missing cue substring"; fi
    if grep -q 'FIXTURE_SIDECHAIN_PAYLOAD' "$SP_S"; then
      bad "T1 toolUseResult payload leaked into signal spine"
    else ok; fi
    SIG_N=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["stats"].get("sidechain_runs_signal",-1))' "$PLAN_S")
    if [ "$SIG_N" = "1" ]; then ok; else bad "T1 stats.sidechain_runs_signal expected 1 got $SIG_N"; fi
    # hard-ish cap: each sidechain block should stay compact
    BLOCK_LEN=$(python3 -c '
import re,sys
t=open(sys.argv[1]).read()
m=re.search(r"\[L\d+-L\d+\] \(sidechain signal[\s\S]*?(?=\n\[L|\Z)", t)
print(len(m.group(0)) if m else 9999)
' "$SP_S")
    if [ "$BLOCK_LEN" -le 400 ]; then ok; else bad "T1 signal block len $BLOCK_LEN > 400"; fi
  else
    bad "T1 prepare produced no spine (err: $(head -c 200 "$WORK/prep.err" 2>/dev/null))"
  fi
else
  bad "T1 prepare failed rc=$? err=$(head -c 200 "$WORK/prep.err" 2>/dev/null)"
fi

# ---- T2: noise fixture → one-line collapse only; no killed: ----
PLAN_N="$WORK/noise-plan.json"
if run_prepare "$NOISE" "$PLAN_N"; then
  SP_N=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("spine",""))' "$PLAN_N")
  if [ -n "$SP_N" ] && [ -f "$SP_N" ]; then
    if grep -q 'sidechain run collapsed' "$SP_N"; then ok
    else bad "T2 noise spine missing one-line collapse"; fi
    if grep -q 'killed:' "$SP_N"; then
      bad "T2 noise spine must not contain 'killed:'"
    else ok; fi
    if grep -q 'sidechain signal' "$SP_N"; then
      bad "T2 noise spine must not contain 'sidechain signal'"
    else ok; fi
    if grep -q 'FIXTURE_NOISE_PAYLOAD' "$SP_N"; then
      bad "T2 toolUseResult payload leaked into noise spine"
    else ok; fi
    COL_N=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["stats"].get("sidechain_runs_collapsed",-1))' "$PLAN_N")
    SIG_N2=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["stats"].get("sidechain_runs_signal",-1))' "$PLAN_N")
    if [ "$COL_N" = "1" ] && [ "$SIG_N2" = "0" ]; then ok
    else bad "T2 stats collapsed=$COL_N signal=$SIG_N2 (want 1/0)"; fi
  else
    bad "T2 prepare produced no spine"
  fi
else
  bad "T2 prepare failed rc=$?"
fi

# ---- T3: parselib cue list is the single named constant ----
if python3 -c '
import sys
sys.path.insert(0, "'"$ROOT"'/skills/transcript-parse")
from parselib import SIDECHAIN_SIGNAL_CUES, sidechain_cue_hit, sidechain_is_signal
assert isinstance(SIDECHAIN_SIGNAL_CUES, tuple) and len(SIDECHAIN_SIGNAL_CUES) >= 10
assert sidechain_cue_hit("Actually, that didn'\''t work") is not None
assert sidechain_is_signal(["clean status summary"]) is False
assert sidechain_is_signal(["this is a dead end"]) is True
print("ok")
' >/dev/null 2>&1; then ok
else bad "T3 parselib SIDECHAIN_SIGNAL_CUES / helpers"; fi

echo "sidechain-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
