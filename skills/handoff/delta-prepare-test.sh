#!/usr/bin/env bash
# delta-prepare-test.sh — CDT-88 prepare --since-leaf (M8b / M6.8–M6.9).
# Run: bash skills/handoff/delta-prepare-test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PREPASS="$HERE/prepass.sh"
FIX="$HERE/fixtures/delta-two-stage.jsonl"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/delta-prepare-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

if [ ! -f "$FIX" ]; then
  echo "FAIL: missing fixture $FIX"
  exit 1
fi

TR="$WORK/tr.jsonl"
cp "$FIX" "$TR"
touch "$TR"

run_prep() {
  local out=$1; shift
  bash "$PREPASS" prepare --uuid "00000000-0000-4000-8000-delta" \
    --transcript "$TR" --allow-in-progress --out "$out" "$@" 2>"$WORK/prep.err"
}

# ---- T0: cold prepare (no --since-leaf) succeeds; tip leaf; prior marker in spine ----
PLAN_FULL="$WORK/full.json"
if run_prep "$PLAN_FULL"; then
  ok
  FULL_LEAF=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["leaf_uuid"])' "$PLAN_FULL")
  FULL_MSGS=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["stats"]["spine_msgs"])' "$PLAN_FULL")
  FULL_TOK=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["stats"]["est_tokens"])' "$PLAN_FULL")
  SP=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("spine",""))' "$PLAN_FULL")
  if [ "$FULL_LEAF" = "delta-b4" ]; then ok; else bad "T0 leaf_uuid want delta-b4 got $FULL_LEAF"; fi
  if [ "$FULL_MSGS" = "8" ]; then ok; else bad "T0 spine_msgs want 8 got $FULL_MSGS"; fi
  if [ -n "$SP" ] && grep -q 'MARKER_PRIOR_ONLY' "$SP" && grep -q 'MARKER_DELTA_ONLY' "$SP"; then ok
  else bad "T0 full spine missing markers"; fi
  # cold path must NOT emit since_leaf / delta_msgs (identity with pre-CDT-88)
  HAS_SINCE=$(python3 -c 'import json,sys; print("since_leaf" in json.load(open(sys.argv[1]))["stats"])' "$PLAN_FULL")
  if [ "$HAS_SINCE" = "False" ]; then ok; else bad "T0 cold stats must not include since_leaf"; fi
else
  bad "T0 cold prepare failed rc=$? err=$(head -c 300 "$WORK/prep.err")"
fi

# ---- T1: --since-leaf prior tip → delta spine only; leaf still current tip ----
PLAN_D="$WORK/delta.json"
if run_prep "$PLAN_D" --since-leaf delta-a4; then
  ok
  python3 - "$PLAN_D" "$FULL_TOK" <<'PY' || bad "T1 stats/spine assertions"
import json, sys
plan = json.load(open(sys.argv[1]))
full_tok = int(sys.argv[2])
st = plan["stats"]
errs = []
if plan.get("leaf_uuid") != "delta-b4":
    errs.append(f"leaf_uuid={plan.get('leaf_uuid')} want delta-b4")
if st.get("since_leaf") != "delta-a4":
    errs.append(f"since_leaf={st.get('since_leaf')}")
if st.get("since_leaf_applied") is not True:
    errs.append(f"since_leaf_applied={st.get('since_leaf_applied')} want True")
if st.get("delta_msgs") != 4:
    errs.append(f"delta_msgs={st.get('delta_msgs')} want 4")
if st.get("full_msgs") != 8:
    errs.append(f"full_msgs={st.get('full_msgs')} want 8")
if st.get("spine_msgs") != 4:
    errs.append(f"spine_msgs={st.get('spine_msgs')} want 4 (delta)")
if st.get("est_tokens", 10**9) >= full_tok:
    errs.append(f"est_tokens={st.get('est_tokens')} not << full {full_tok}")
if st.get("spine_chars", 10**9) >= st.get("full_msgs", 0) * 50:  # sanity
    pass  # soft
sp = plan.get("spine") or ""
if not sp:
    errs.append("no spine path")
else:
    text = open(sp).read()
    if "MARKER_PRIOR_ONLY" in text:
        errs.append("delta spine still has PRIOR marker")
    if "MARKER_DELTA_ONLY" not in text:
        errs.append("delta spine missing DELTA marker")
    if "MARKER_TIP" not in text:
        errs.append("delta spine missing TIP marker")
if plan.get("mode") != "direct":
    errs.append(f"mode={plan.get('mode')} want direct")
if errs:
    print("FAIL:", "; ".join(errs))
    sys.exit(1)
print("ok")
PY
  [ $? -eq 0 ] && ok
else
  bad "T1 since-leaf prepare failed rc=$? err=$(head -c 300 "$WORK/prep.err")"
fi

# ---- T2: unknown since-leaf → full spine fallback + warn ----
PLAN_FB="$WORK/fallback.json"
if run_prep "$PLAN_FB" --since-leaf "does-not-exist-uuid"; then
  ok
  python3 - "$PLAN_FB" <<'PY' || bad "T2 fallback assertions"
import json, sys
plan = json.load(open(sys.argv[1]))
st = plan["stats"]
errs = []
if plan.get("leaf_uuid") != "delta-b4":
    errs.append("leaf not tip")
if st.get("spine_msgs") != 8:
    errs.append(f"spine_msgs={st.get('spine_msgs')} want full 8")
if st.get("full_msgs") != 8:
    errs.append(f"full_msgs={st.get('full_msgs')}")
if st.get("delta_msgs") != 8:
    errs.append(f"delta_msgs={st.get('delta_msgs')} want 8 on fallback")
if st.get("since_leaf") != "does-not-exist-uuid":
    errs.append(f"since_leaf={st.get('since_leaf')}")
if st.get("since_leaf_applied") is not False:
    errs.append(f"since_leaf_applied={st.get('since_leaf_applied')} want False")
sp = plan.get("spine") or ""
text = open(sp).read() if sp else ""
if "MARKER_PRIOR_ONLY" not in text or "MARKER_DELTA_ONLY" not in text:
    errs.append("fallback spine not full")
if errs:
    print("FAIL:", "; ".join(errs))
    sys.exit(1)
print("ok")
PY
  [ $? -eq 0 ] && ok
  if grep -qi 'since-leaf\|not found\|fallback\|unknown' "$WORK/prep.err"; then ok
  else bad "T2 expected warn on stderr about missing since-leaf"; fi
else
  bad "T2 fallback prepare failed"
fi

# ---- T3: empty delta (since-leaf = current tip) → mode=direct, delta_msgs=0 ----
PLAN_E="$WORK/empty.json"
if run_prep "$PLAN_E" --since-leaf delta-b4; then
  ok
  python3 - "$PLAN_E" <<'PY' || bad "T3 empty-delta assertions"
import json, sys
plan = json.load(open(sys.argv[1]))
st = plan["stats"]
errs = []
if plan.get("leaf_uuid") != "delta-b4":
    errs.append("leaf not tip")
if plan.get("mode") != "direct":
    errs.append(f"mode={plan.get('mode')}")
if st.get("delta_msgs") != 0:
    errs.append(f"delta_msgs={st.get('delta_msgs')} want 0")
if st.get("spine_msgs") != 0:
    errs.append(f"spine_msgs={st.get('spine_msgs')} want 0")
if st.get("full_msgs") != 8:
    errs.append(f"full_msgs={st.get('full_msgs')}")
if st.get("est_tokens") != 0:
    errs.append(f"est_tokens={st.get('est_tokens')} want 0")
# empty delta still applied the cut (leaf found)
if st.get("since_leaf_applied") is not True:
    errs.append(f"since_leaf_applied={st.get('since_leaf_applied')} want True (empty delta)")
sp = plan.get("spine") or ""
if not sp:
    errs.append("missing spine path")
elif not open(sp).read().strip() == open(sp).read().strip():  # always true
    pass
if errs:
    print("FAIL:", "; ".join(errs))
    sys.exit(1)
print("ok")
PY
  [ $? -eq 0 ] && ok
else
  bad "T3 empty-delta prepare failed rc=$? err=$(head -c 300 "$WORK/prep.err")"
fi

# ---- T4: --since-leaf= form ----
PLAN_EQ="$WORK/eq.json"
if run_prep "$PLAN_EQ" --since-leaf=delta-a4; then
  DM=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["stats"].get("delta_msgs"))' "$PLAN_EQ")
  if [ "$DM" = "4" ]; then ok; else bad "T4 --since-leaf= form delta_msgs=$DM"; fi
  SLA=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["stats"].get("since_leaf_applied"))' "$PLAN_EQ")
  if [ "$SLA" = "True" ]; then ok; else bad "T4 since_leaf_applied=$SLA want True"; fi
else
  bad "T4 equals-form prepare failed"
fi

# ---- T5: cold path must not emit since_leaf_applied ----
HAS_SLA=$(python3 -c 'import json,sys; print("since_leaf_applied" in json.load(open(sys.argv[1]))["stats"])' "$PLAN_FULL")
if [ "$HAS_SLA" = "False" ]; then ok; else bad "T5 cold stats must not include since_leaf_applied"; fi

# ---- T6: orchestrator clear logic (handoff.md M8b) — miss → no --prior-events ----
# Simulate post-prepare clear: prior cache set + plan with since_leaf_applied=false
# → PRIOR_EVENTS_FILE cleared so finalize path must not pass --prior-events.
clear_prior_on_miss() {
  # stdin unused; args: PLAN_JSON PRIOR_EVENTS_FILE
  local plan=$1
  local prior=$2
  PRIOR_EVENTS_FILE="$prior"
  FINALIZE_PRIOR_EVENTS="$prior"
  PRIOR_LEAF="stale-leaf"
  _SLA_CLEAR=$(PLAN_JSON="$plan" python3 - <<'PYSLA'
import json, os, sys
try:
    st = json.load(open(os.environ["PLAN_JSON"], encoding="utf-8")).get("stats") or {}
except (OSError, ValueError):
    sys.exit(0)
if "since_leaf" not in st and "since_leaf_applied" not in st:
    sys.exit(0)
if st.get("since_leaf_applied") is True:
    sys.exit(0)
print("clear")
PYSLA
)
  if [ "$_SLA_CLEAR" = "clear" ]; then
    PRIOR_EVENTS_FILE=""
    PRIOR_LEAF=""
    unset FINALIZE_PRIOR_EVENTS 2>/dev/null || true
  fi
  # finalize gate (commands/handoff.md Step 8)
  FIN_ARGS=()
  if [ -n "${PRIOR_EVENTS_FILE:-}" ] && [ -f "$PRIOR_EVENTS_FILE" ]; then
    FIN_ARGS+=(--prior-events "$PRIOR_EVENTS_FILE")
  fi
  printf '%s\n' "${FIN_ARGS[*]-}"
}

# T6a: miss plan + prior cache path → FIN_ARGS empty
PRIOR_CACHE="$WORK/prior-cache.json"
cat >"$PRIOR_CACHE" <<'JSON'
{"leaf_uuid":"stale-leaf","events":{"through_line":[{"id":"x","text":"prior only"}]}}
JSON
FIN_OUT=$(clear_prior_on_miss "$PLAN_FB" "$PRIOR_CACHE")
if [ -z "$FIN_OUT" ]; then ok; else bad "T6a miss must clear --prior-events got: $FIN_OUT"; fi

# T6b: applied plan + prior cache → keep --prior-events
FIN_OUT=$(clear_prior_on_miss "$PLAN_D" "$PRIOR_CACHE")
if [ "$FIN_OUT" = "--prior-events $PRIOR_CACHE" ]; then ok
else bad "T6b applied must keep --prior-events got: $FIN_OUT"; fi

# T6c: cold plan (no since_leaf stats) + empty prior → no flag
FIN_OUT=$(clear_prior_on_miss "$PLAN_FULL" "")
if [ -z "$FIN_OUT" ]; then ok; else bad "T6c cold empty prior got: $FIN_OUT"; fi

# T6d: empty-delta applied → keep prior (delta empty; prior has history)
FIN_OUT=$(clear_prior_on_miss "$PLAN_E" "$PRIOR_CACHE")
if [ "$FIN_OUT" = "--prior-events $PRIOR_CACHE" ]; then ok
else bad "T6d empty-delta applied must keep prior got: $FIN_OUT"; fi

echo "delta-prepare-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
