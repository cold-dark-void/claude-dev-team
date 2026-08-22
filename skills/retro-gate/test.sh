#!/usr/bin/env bash
# retro-gate/test.sh — CDV-184 S3 draft-polish bite-tests (AC1–AC5 + AC8) +
# CDT-212 S5 local S1–S4 co-occurrence.
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

# ---- AC3: pre-existing Edit×3 without struggle → no S3 (CDT-125) ----
# Multi-section doc authoring on an existing file is not an edit loop.
run_gate "ac3-preexisting-thrash.jsonl"
if assert_json_shape "AC3"; then
  s3c=$(signal_count S3)
  if [ "$s3c" = "0" ] 2>/dev/null; then
    ok "AC3 pre-existing clean multi-edit S3=0 (CDT-125)"
  else
    bad "AC3: expected no S3 on error-free multi-edit: $OUT"
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

# ---- CDV-186 hybrid S2 (ledger) ----
run_gate_env() {
  local f="$FIX/$1"
  shift
  OUT=$(env "$@" bash "$GATE" "$f" 2>/dev/null)
  RC=$?
}

# H1: transcript has no tool errors; ledger has ≥2 rows for session → S2 from ledger
run_gate_env "hybrid-ledger-s2.jsonl" \
  FRICTION_LEDGER="$FIX/hybrid-ledger-s2.ledger.jsonl"
if assert_json_shape "H1"; then
  s2c=$(signal_count S2)
  sc=$(score_val)
  if [ "$s2c" = "1" ] && python3 -c "import sys; sys.exit(0 if float(sys.argv[1])==2.0 else 1)" "$sc"; then
    ok "H1 ledger-covered S2 count=1 score=2.0"
  else
    bad "H1: want S2=1 score=2.0; got S2=$s2c score=$sc out=$OUT"
  fi
  if echo "$OUT" | grep -q 'ledger:PostToolUseFailure:'; then
    ok "H1 synthetic ledger S2 id"
  else
    bad "H1: missing ledger: anchor in ids: $OUT"
  fi
fi

# H2: same transcript, no ledger → no S2 (uncovered full transcript)
run_gate_env "hybrid-ledger-s2.jsonl" FRICTION_LEDGER="/nonexistent/friction.jsonl"
if assert_json_shape "H2"; then
  if has_signal S2; then
    bad "H2: unexpected S2 without ledger: $OUT"
  else
    ok "H2 uncovered clean transcript no S2"
  fi
fi

# H3: transcript has consecutive tool errors; no ledger → transcript S2
run_gate_env "hybrid-transcript-s2.jsonl" FRICTION_LEDGER="/nonexistent/friction.jsonl"
if assert_json_shape "H3"; then
  s2c=$(signal_count S2)
  if [ "$s2c" = "1" ]; then
    ok "H3 transcript S2 when uncovered count=$s2c"
  else
    bad "H3: want S2=1 got $s2c out=$OUT"
  fi
fi

# H4: covered with only 1 ledger row → S2 count 0 (run length < 2), ignores transcript errors
ONE_ROW="$FIX/hybrid-one-row-b.ledger.jsonl"
printf '%s\n' '{"ts":"2026-07-14T12:00:00Z","session_id":"hybrid-s2-b","event":"PostToolUseFailure","tool":"Bash","path":""}' > "$ONE_ROW"
run_gate_env "hybrid-transcript-s2.jsonl" FRICTION_LEDGER="$ONE_ROW"
if assert_json_shape "H4"; then
  if has_signal S2; then
    bad "H4: 1 ledger row should not yield S2 run: $OUT"
  else
    ok "H4 covered single-row suppresses transcript S2"
  fi
fi

# H5: RETRO_FORCE_TRANSCRIPT_S2=1 ignores ledger coverage (clean transcript → no S2)
run_gate_env "hybrid-ledger-s2.jsonl" \
  FRICTION_LEDGER="$FIX/hybrid-ledger-s2.ledger.jsonl" \
  RETRO_FORCE_TRANSCRIPT_S2=1
if assert_json_shape "H5"; then
  if has_signal S2; then
    bad "H5: force-transcript on clean session should not S2: $OUT"
  else
    ok "H5 RETRO_FORCE_TRANSCRIPT_S2 uses transcript (no S2)"
  fi
fi

# H6: force-transcript with real transcript errors still scores S2 despite 1-row ledger
run_gate_env "hybrid-transcript-s2.jsonl" \
  FRICTION_LEDGER="$ONE_ROW" \
  RETRO_FORCE_TRANSCRIPT_S2=1
if assert_json_shape "H6"; then
  s2c=$(signal_count S2)
  if [ "$s2c" = "1" ]; then
    ok "H6 force-transcript keeps transcript S2 count=$s2c"
  else
    bad "H6: want S2=1 got $s2c out=$OUT"
  fi
fi
rm -f "$ONE_ROW"

echo "----"

# ---- CDT-124 + CDT-129: S5 approval-token allowlist ----
# One long assistant turn (>500 chars) followed by short user turns.
# Suppressed: "y", "approve", "accept, anyting else?"
# Fire S5: "y tho", "y not" (not bare y)
# Fire S5: "dont accept", "no, accept" (negation + approval — CDT-129)
run_gate "s5-approval-tokens.jsonl"
if assert_json_shape "S5-tok"; then
  s5c=$(signal_count S5)
  if [ "$s5c" = "1" ]; then
    ok "S5-tok friction=1 (dont-accept via same-turn S1)"
  else
    bad "S5-tok: want S5=1; got S5=$s5c out=$OUT"
  fi
  if has_signal S5 && echo "$OUT" | grep -q '000607'; then
    ok "S5-tok ids include dont-accept"
  else
    bad "S5-tok: expected id …607: $OUT"
  fi
  if echo "$OUT" | grep -q '000605\|000606\|000608'; then
    bad "S5-tok: isolated y-tho/y-not/no-accept leaked into S5 ids: $OUT"
  else
    ok "S5-tok isolated y-tho/y-not/no-accept absent from S5 ids"
  fi
  if echo "$OUT" | grep -q '000602\|000603\|000604'; then
    bad "S5-tok: pure approval turns (y/approve/accept) leaked into S5 ids: $OUT"
  else
    ok "S5-tok pure approval turns absent from S5 ids"
  fi
fi

echo "----"

# ---- CDT-196: Grok <user_query> wrap + S1 rage lexicon ----
# Wrapped "PATCH!? WTF" is 4 tokens; unwrap → 2 words (S5) + wtf (S1).
# Second turn "fucking" is a second S1. Score ≥ 6.
run_gate "grok-user-query-s1.jsonl"
if assert_json_shape "Grok-UQ"; then
  sc=$(score_val)
  pv=$(passed_val)
  s1c=$(signal_count S1)
  if [ "$pv" = "true" ] && [ "$s1c" -ge 2 ] \
     && python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) >= 6.0 else 1)" "$sc"; then
    ok "Grok-UQ unwrap+S1 rage passed=true S1=$s1c score=$sc"
  else
    bad "Grok-UQ: want passed=true S1≥2 score≥6; got passed=$pv S1=$s1c score=$sc out=$OUT"
  fi
fi

echo "----"

# ---- CDT-156 T6 / AC12: Grok raw fixture → normalize → gate passed:true ----
# Raw Grok chat_history with S1 rejection + ≥2 consecutive exit:N≠0 (S2).
# Weights unchanged: S1=3.0 + S2=2.0 → score 5.0 ≥ threshold.
GROK_RAW="$FIX/grok-friction-s1-s2.jsonl"
TP_DIR=$(CDPATH= cd -- "$HERE/../transcript-parse" && pwd)
if [ ! -f "$GROK_RAW" ]; then
  bad "Grok-AC12: missing fixture $GROK_RAW"
elif [ ! -f "$TP_DIR/grok_normalize.py" ]; then
  bad "Grok-AC12: missing grok_normalize.py under $TP_DIR"
else
  GROK_NORM=$(mktemp "${TMPDIR:-/tmp}/grok-friction-norm.XXXXXX.jsonl")
  set +e
  python3 "$TP_DIR/grok_normalize.py" \
    --in "$GROK_RAW" \
    --out "$GROK_NORM" \
    --cwd /home/proj \
    --session-id cdt156-friction \
    --mode scoring >/dev/null 2>"${TMPDIR:-/tmp}/grok-norm.err"
  NRC=$?
  set -e
  if [ "$NRC" -ne 0 ]; then
    bad "Grok-AC12: normalize exit $NRC err=$(cat "${TMPDIR:-/tmp}/grok-norm.err" 2>/dev/null)"
  else
    OUT=$(bash "$GATE" "$GROK_NORM" 2>/dev/null)
    RC=$?
    if assert_json_shape "Grok-AC12"; then
      sc=$(score_val)
      pv=$(passed_val)
      s1c=$(signal_count S1)
      s2c=$(signal_count S2)
      # Expect S1 + S2 both present; score ≥ threshold (default 5.0)
      if [ "$pv" = "true" ] && [ "$s1c" -ge 1 ] && [ "$s2c" -ge 1 ] \
         && python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) >= 5.0 else 1)" "$sc"; then
        ok "Grok-AC12 normalize→gate passed=true S1=$s1c S2=$s2c score=$sc"
      else
        bad "Grok-AC12: want passed=true S1≥1 S2≥1 score≥5; got passed=$pv S1=$s1c S2=$s2c score=$sc out=$OUT"
      fi
    fi
  fi
  rm -f "$GROK_NORM"
fi

echo "----"

# ---- CDT-212: S5 scores only with local transcript S1–S4 co-occurrence ----
# Isolated S5 (no S1–S4 in the preceding exchange) contributes 0.
run_gate "s5-only.jsonl"
if assert_json_shape "S5-only"; then
  s5c=$(signal_count S5)
  sc=$(score_val)
  pv=$(passed_val)
  if [ "$s5c" = "0" ] && ! has_signal S5 \
     && python3 -c "import sys; sys.exit(0 if float(sys.argv[1])==0.0 else 1)" "$sc" \
     && [ "$pv" = "false" ]; then
    ok "S5-only isolated candidates score=0 passed=false omit S5"
  else
    bad "S5-only: want S5 omitted score=0 passed=false; got S5=$s5c score=$sc passed=$pv out=$OUT"
  fi
fi

# ee104182: scoring S3 then three later isolated terse turns in new exchanges.
# Session-level co-occur (keep S5 because S3 exists anywhere) is a FAIL.
run_gate "s5-ee104182-profile.jsonl"
if assert_json_shape "S5-ee104182"; then
  s3c=$(signal_count S3)
  s5c=$(signal_count S5)
  sc=$(score_val)
  pv=$(passed_val)
  if [ "$s3c" = "1" ] && [ "$s5c" = "0" ] && ! has_signal S5 \
     && python3 -c "import sys; sys.exit(0 if float(sys.argv[1])==2.5 else 1)" "$sc" \
     && [ "$pv" = "false" ]; then
    ok "S5-ee104182 S3=1 S5=0 score=2.5 passed=false"
  else
    bad "S5-ee104182: want S3=1 S5=0 score=2.5 passed=false; got S3=$s3c S5=$s5c score=$sc passed=$pv out=$OUT"
  fi
fi

# Local co-occur keeps S5: same-turn S1, exchange S4, transcript S2, scoring S3.
run_gate "s5-local-cooccur.jsonl"
if assert_json_shape "S5-local"; then
  s1c=$(signal_count S1)
  s2c=$(signal_count S2)
  s3c=$(signal_count S3)
  s4c=$(signal_count S4)
  s5c=$(signal_count S5)
  if [ "$s1c" -ge 1 ] && [ "$s2c" = "1" ] && [ "$s3c" = "1" ] && [ "$s4c" -ge 1 ] \
     && [ "$s5c" = "4" ]; then
    ok "S5-local S1/S2/S3/S4 present S5=4"
  else
    bad "S5-local: want S1>=1 S2=1 S3=1 S4>=1 S5=4; got S1=$s1c S2=$s2c S3=$s3c S4=$s4c S5=$s5c out=$OUT"
  fi
  if echo "$OUT" | grep -q '000851' && echo "$OUT" | grep -q '000854' \
     && echo "$OUT" | grep -q '000862' && echo "$OUT" | grep -q '000872'; then
    ok "S5-local ids include same-turn S1, S4, S2, S3 S5s"
  else
    bad "S5-local: expected S5 ids …851 …854 …862 …872: $OUT"
  fi
fi

# Ledger-covered S2 still scores; isolated S5s MUST NOT unlock from ledger S2.
run_gate_env "s5-ledger-isolated.jsonl" \
  FRICTION_LEDGER="$FIX/s5-ledger-isolated.ledger.jsonl"
if assert_json_shape "S5-ledger"; then
  s2c=$(signal_count S2)
  s5c=$(signal_count S5)
  sc=$(score_val)
  pv=$(passed_val)
  if [ "$s2c" = "1" ] && [ "$s5c" = "0" ] && ! has_signal S5 \
     && python3 -c "import sys; sys.exit(0 if float(sys.argv[1])==2.0 else 1)" "$sc" \
     && [ "$pv" = "false" ]; then
    ok "S5-ledger S2=1 S5=0 score=2.0 passed=false"
  else
    bad "S5-ledger: want S2=1 S5=0 score=2.0 passed=false; got S2=$s2c S5=$s5c score=$sc passed=$pv out=$OUT"
  fi
fi

if grep -q 'S5_WEIGHT, S5_CAP = 1.0, 4' "$GATE"; then
  ok "S5 tunables unchanged"
else
  bad "S5: S5_WEIGHT/S5_CAP constants missing or changed"
fi

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
