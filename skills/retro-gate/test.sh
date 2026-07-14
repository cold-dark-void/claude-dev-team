#!/usr/bin/env bash
# retro-gate/test.sh — CDV-184 S3 draft-polish bite-tests (AC1–AC5 + AC9).
# Run: bash skills/retro-gate/test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
GATE="$HERE/gate.sh"
FIX="$HERE/fixtures"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

# run_gate <fixture-basename> → sets OUT, RC
run_gate() {
  local f="$FIX/$1"
  OUT=$(bash "$GATE" "$f" 2>/dev/null)
  RC=$?
}

# assert_json_shape — AC9: exit 0 + required keys
assert_json_shape() {
  local label="$1"
  if [ "$RC" -ne 0 ]; then
    bad "$label: exit $RC (want 0)"
    return 1
  fi
  if ! python3 -c '
import json,sys
d=json.loads(sys.argv[1])
need={"score","passed","threshold","signals"}
missing=need-set(d)
sys.exit(0 if not missing else 1)
' "$OUT" 2>/dev/null; then
    bad "$label: missing JSON keys in: $OUT"
    return 1
  fi
  return 0
}

has_signal() {
  local name="$1"
  python3 -c '
import json,sys
d=json.loads(sys.argv[1])
sys.exit(0 if any(s.get("name")==sys.argv[2] for s in d.get("signals",[])) else 1)
' "$OUT" "$name" 2>/dev/null
}

signal_count() {
  local name="$1"
  python3 -c '
import json,sys
d=json.loads(sys.argv[1])
for s in d.get("signals",[]):
    if s.get("name")==sys.argv[2]:
        print(int(s.get("count",0))); break
else:
    print(0)
' "$OUT" "$name" 2>/dev/null
}

score_val() {
  python3 -c 'import json,sys; print(float(json.loads(sys.argv[1]).get("score",-1)))' "$OUT" 2>/dev/null
}

passed_val() {
  # print JSON bool (true/false) not Python True/False
  python3 -c 'import json,sys; print("true" if json.loads(sys.argv[1]).get("passed") else "false")' "$OUT" 2>/dev/null
}

# ---- AC1: clean draft-polish → no S3 ----
run_gate "ac1-clean-draft-polish.jsonl"
if assert_json_shape "AC1"; then
  if has_signal S3; then
    bad "AC1: unexpected S3 on clean draft-polish: $OUT"
  else
    ok "AC1 clean draft-polish no S3"
  fi
fi

# ---- AC2: two clean paths → S3 contrib 0; passed false ----
run_gate "ac2-two-clean-paths.jsonl"
if assert_json_shape "AC2"; then
  s3c=$(signal_count S3)
  sc=$(score_val)
  pv=$(passed_val)
  # score must have zero S3 contribution; solo clean session stays below threshold
  if [ "$s3c" = "0" ] && python3 -c "import sys; sys.exit(0 if float(sys.argv[1])==0.0 else 1)" "$sc" \
     && [ "$pv" = "false" ]; then
    ok "AC2 two clean paths S3=0 score=0 passed=false"
  else
    bad "AC2: want S3=0 score=0 passed=false; got S3=$s3c score=$sc passed=$pv out=$OUT"
  fi
fi

# ---- AC3: pre-existing Edit×3 → S3 ----
run_gate "ac3-preexisting-thrash.jsonl"
if assert_json_shape "AC3"; then
  s3c=$(signal_count S3)
  if [ "$s3c" -ge 1 ] 2>/dev/null; then
    ok "AC3 pre-existing thrash S3 count=$s3c"
  else
    bad "AC3: expected S3 present: $OUT"
  fi
fi

# ---- AC4: Write + intervening tool error → S3 ----
run_gate "ac4-write-then-tool-error.jsonl"
if assert_json_shape "AC4"; then
  if has_signal S3; then
    ok "AC4 write+tool-error fires S3"
  else
    bad "AC4: expected S3: $OUT"
  fi
fi

# ---- AC5: Write + intervening S1 → S3 ----
run_gate "ac5-write-then-s1.jsonl"
if assert_json_shape "AC5"; then
  if has_signal S3; then
    ok "AC5 write+S1 rejection fires S3"
  else
    bad "AC5: expected S3: $OUT"
  fi
fi

# ---- constants still present (AC8 smoke) ----
if grep -q 'S3_WEIGHT, S3_MIN_EDITS, S3_WINDOW = 2.5, 3, 10' "$GATE"; then
  ok "AC8 S3 tunables unchanged"
else
  bad "AC8: S3_WEIGHT/MIN_EDITS/WINDOW constants missing or changed"
fi

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
