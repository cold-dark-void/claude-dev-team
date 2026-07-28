#!/usr/bin/env bash
# light-defense-test.sh — CDT-91 T9b / SPEC-018 test 33 (M10c light cache defense).
# Mirrors commands/handoff.md Step 4 PYDELTA gate:
#   data.get("light") in (True, 1, "true", "1") → exit 0 (no PRIOR_LEAF)
#   empty events + leaf → no-prior (same soft path)
# Run: bash skills/handoff/light-defense-test.sh
set -u

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/light-defense-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# Exact gate from commands/handoff.md Step 4 (PYDELTA). Keep in sync.
prior_leaf_from_cache() {
  local cache=$1
  PRIOR_CACHE="$cache" python3 - <<'PYDELTA'
import json, os, sys
path = os.environ["PRIOR_CACHE"]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, ValueError):
    sys.exit(0)
if not isinstance(data, dict):
    sys.exit(0)
leaf = data.get("leaf_uuid") or ""
if not isinstance(leaf, str) or not leaf.strip():
    sys.exit(0)
ev = data.get("events")
if not isinstance(ev, dict) or not ev:
    sys.exit(0)
# M10c defense (CDT-91): light:true cache → no-prior (primary path never writes this)
if data.get("light") in (True, 1, "true", "1"):
    sys.exit(0)
has = False
for v in ev.values():
    if isinstance(v, list) and v:
        has = True
        break
if has:
    print(leaf.strip())
PYDELTA
}

# Helper: write JSON file from python dict literal
jwrite() {
  local path=$1
  local pyexpr=$2
  python3 -c "import json; json.dump($pyexpr, open(r'''$path''','w'))"
}

LEAF="leaf-defense-001"

# ---- T1: light:true (bool) + events + leaf → PRIOR_LEAF empty (no-prior) ----
C="$WORK/light-bool.json"
jwrite "$C" "{'leaf_uuid':'$LEAF','light':True,'events':{'through_line':[{'id':'e1','text':'x'}],'state':[]}}"
OUT=$(prior_leaf_from_cache "$C")
if [ -z "$OUT" ]; then ok; else bad "T1 light:true bool must no-prior got: $OUT"; fi

# ---- T2: light:1 (int) + events + leaf → no-prior ----
C="$WORK/light-int.json"
jwrite "$C" "{'leaf_uuid':'$LEAF','light':1,'events':{'through_line':[{'id':'e1','text':'x'}]}}"
OUT=$(prior_leaf_from_cache "$C")
if [ -z "$OUT" ]; then ok; else bad "T2 light:1 must no-prior got: $OUT"; fi

# ---- T3: light:"true" (str) + events + leaf → no-prior ----
C="$WORK/light-str-true.json"
jwrite "$C" "{'leaf_uuid':'$LEAF','light':'true','events':{'through_line':[{'id':'e1','text':'x'}]}}"
OUT=$(prior_leaf_from_cache "$C")
if [ -z "$OUT" ]; then ok; else bad "T3 light:\"true\" must no-prior got: $OUT"; fi

# ---- T4: light:"1" (str) + events + leaf → no-prior ----
C="$WORK/light-str-1.json"
jwrite "$C" "{'leaf_uuid':'$LEAF','light':'1','events':{'through_line':[{'id':'e1','text':'x'}]}}"
OUT=$(prior_leaf_from_cache "$C")
if [ -z "$OUT" ]; then ok; else bad "T4 light:\"1\" must no-prior got: $OUT"; fi

# ---- T5: empty events {} + leaf (no light) → no-prior (existing soft path) ----
C="$WORK/empty-events.json"
jwrite "$C" "{'leaf_uuid':'$LEAF','events':{}}"
OUT=$(prior_leaf_from_cache "$C")
if [ -z "$OUT" ]; then ok; else bad "T5 empty events must no-prior got: $OUT"; fi

# ---- T6: missing events + leaf → no-prior ----
C="$WORK/missing-events.json"
jwrite "$C" "{'leaf_uuid':'$LEAF'}"
OUT=$(prior_leaf_from_cache "$C")
if [ -z "$OUT" ]; then ok; else bad "T6 missing events must no-prior got: $OUT"; fi

# ---- T7: events with only empty lists + leaf → no-prior ----
C="$WORK/empty-lists.json"
jwrite "$C" "{'leaf_uuid':'$LEAF','events':{'through_line':[],'state':[]}}"
OUT=$(prior_leaf_from_cache "$C")
if [ -z "$OUT" ]; then ok; else bad "T7 empty-list events must no-prior got: $OUT"; fi

# ---- T8: positive control — no light, non-empty events, leaf → PRIOR_LEAF printed ----
C="$WORK/full-prior.json"
jwrite "$C" "{'leaf_uuid':'$LEAF','events':{'through_line':[{'id':'e1','text':'prior'}]}}"
OUT=$(prior_leaf_from_cache "$C")
if [ "$OUT" = "$LEAF" ]; then ok; else bad "T8 full prior want leaf=$LEAF got: $OUT"; fi

# ---- T9: light:false + non-empty events → still prior (not in True/1/"true"/"1") ----
C="$WORK/light-false.json"
jwrite "$C" "{'leaf_uuid':'$LEAF','light':False,'events':{'through_line':[{'id':'e1','text':'x'}]}}"
OUT=$(prior_leaf_from_cache "$C")
if [ "$OUT" = "$LEAF" ]; then ok; else bad "T9 light:false must still prior got: $OUT"; fi

# ---- T10: light:true + empty events + leaf → no-prior (either gate) ----
C="$WORK/light-and-empty.json"
jwrite "$C" "{'leaf_uuid':'$LEAF','light':True,'events':{}}"
OUT=$(prior_leaf_from_cache "$C")
if [ -z "$OUT" ]; then ok; else bad "T10 light+empty must no-prior got: $OUT"; fi

echo "light-defense-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
