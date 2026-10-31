#!/usr/bin/env bash
# test.sh — advisor ask.sh probe/finalize seam bite-tests (SPEC-039 T6 / C4).
#
# Machine-check: bash skills/advisor/test.sh  (exit 0)
#
# Covers the CDT-556-C4 acceptance criteria:
#   - probe actions spawn|cache-hit|refuse|cap; probe never spawns
#   - unmapped -> refuse "advisor not configured", never a tier default
#   - caps: per-trigger reserves a=3/b=4/c=2/d=1, global 5,
#     ADVISOR_MAX_CALLS lowers only, hash dedupe, epic total 8
#   - re-entrant probe exits 64; finalize ruling taxonomy; timeout is
#     never a partial ruling; bad locator 64; spawn-fail/refuse status-only;
#     gitignored state root; sourcing attempt exits 64; single-object stdout;
#     non-integer confidence 64; b/c reserves; retry counter increments;
#     empty-evidence ruling 64
#   CDT-562 (C9): doc-bite greps — M31/M32 memory content rules and the
#     --memory write-path gate in skills/agent-memory/advisor-protocol.md

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT" || exit 1
ASK="$ROOT/skills/advisor/ask.sh"
RESOLVE="$ROOT/skills/model-map/resolve-model.sh"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/advisor-ask-test.XXXXXX")
# If mktemp failed (e.g. TMPDIR names a missing dir), abort BEFORE the map
# backup below — a bogus $TMP makes MAP_BAK unwritable and the restore trap
# would then rm the user's real map.
[ -d "$TMP" ] || { echo "test.sh: mktemp -d failed (check TMPDIR)" >&2; exit 1; }
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# resolve-model.sh reads layers from MROOT (git-common-dir parent) — the MAIN
# repo — even when this suite runs from a worktree. Plant/clear that layer,
# with backup + restore (never clobber the user's local map).
# Resolve MROOT the same way ask.sh does (git common dir), NOT via ../..
# — ../.. only resolves correctly from a worktree; from a plain checkout it
# would point at $HOME/.claude and plant the mapping into the global layer.
# The map file is SHARED, so concurrent suite runs must serialize: hold a
# global lock for the whole run (fd 9 closes at exit, after the restore trap
# has fired). Without it, two concurrent runs race the backup/restore and can
# leave the planted test mapping behind.
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
MAP="$MROOT/.claude/dev-team/models.local.json"
mkdir -p "$(dirname "$MAP")"
exec 9>>"$(dirname "$MAP")/.test-map.lock"
flock 9
MAP_BAK="$TMP/models.local.json.bak"
if [ -f "$MAP" ]; then cp "$MAP" "$MAP_BAK"; fi
restore_map() {
  if [ -f "$MAP_BAK" ]; then mv "$MAP_BAK" "$MAP"; else rm -f "$MAP"; fi
}
trap 'restore_map; rm -rf "$TMP"' EXIT

clear_layers() { rm -f "$MAP"; }
plant_advisor() { # plant an explicit advisor mapping (local layer)
  mkdir -p "$(dirname "$MAP")"
  echo '{"version":1,"agents":{"advisor":"test-model-x"},"effort":{"advisor":"low"}}' > "$MAP"
}

# probe with a scratch advisor state root so tests never touch real state
state_env() { # state_env <root>
  printf 'ADVISOR_STATE_ROOT=%s' "$1"
}

run_probe() { # run_probe <extra args...> — uses $TSTATE as ADVISOR_STATE_ROOT
  ADVISOR_STATE_ROOT="$TSTATE" bash "$ASK" probe "$@" 2>"$TMP/err.txt"
}

check_json() { # check_json <id> <json-out> <jq-expr> <want>
  local id="$1" out="$2" expr="$3" want="$4" got
  got=$(printf '%s' "$out" | jq -r "$expr" 2>/dev/null)
  if [ "$got" = "$want" ]; then pass "$id"; else fail "$id: got '$got' want '$want' (out: $out)"; fi
}

TSTATE="$TMP/state1"

# ---- 1. unmapped -> refuse "advisor not configured", never a tier default ----
clear_layers
OUT=$(run_probe --trigger b --question "what is omp")
check_json "t1-unmapped-refuse-action" "$OUT" ".action" "refuse"
check_json "t1-unmapped-refuse-reason" "$OUT" ".reason" "advisor not configured"
check_json "t1-unmapped-no-model" "$OUT" ".model" "null"
check_json "t1-unmapped-no-srp" "$OUT" ".spawn_request_path" "null"

# ---- 2. mapped -> spawn, model from the map, spawn-request written -----------
plant_advisor
OUT=$(run_probe --trigger b --question "what is omp" --run-id r1)
check_json "t2-spawn-action" "$OUT" ".action" "spawn"
check_json "t2-spawn-model" "$OUT" ".model" "test-model-x"
SRP=$(printf '%s' "$OUT" | jq -r .spawn_request_path)
if [ -f "$SRP" ] && [ "$(jq -r .status "$SRP")" = "awaiting-spawn" ]; then
  pass "t2-spawn-request-written"
else
  fail "t2-spawn-request-written: $SRP"
fi
HASH=$(jq -r .question_hash "$SRP")

# probe never spawns: the run dir holds only the spawn request + counters —
# no ruling, no cache entry, nothing that pretends an agent ran.
if [ ! -f "$TSTATE/runs/r1/ruling.json" ] && [ ! -f "$TSTATE/cache/$HASH.json" ]; then
  pass "t2-probe-never-spawns"
else
  fail "t2-probe-never-spawns: ruling or cache written by probe"
fi

# ---- 2b. model override (SPEC-039 M37) --------------------------------------
# --model wins over the Model map.
plant_advisor
OUT=$(run_probe --trigger b --question "model override question" --run-id r-model --model override-model)
check_json "t2b-model-flag-action" "$OUT" ".action" "spawn"
check_json "t2b-model-flag-model" "$OUT" ".model" "override-model"
SRP=$(printf '%s' "$OUT" | jq -r .spawn_request_path)
check_json "t2b-model-flag-spawn-request" "$(cat "$SRP" 2>/dev/null)" ".model" "override-model"

# An explicit override enables the advisor even when the map is empty.
clear_layers
OUT=$(run_probe --trigger b --question "unmapped override question" --run-id r-model2 --model override-model)
check_json "t2b-model-override-unmapped-action" "$OUT" ".action" "spawn"
check_json "t2b-model-override-unmapped-model" "$OUT" ".model" "override-model"

# ADVISOR_MODEL env fills the model when the flag is bare.
plant_advisor
OUT=$(ADVISOR_STATE_ROOT="$TSTATE" ADVISOR_MODEL=env-model bash "$ASK" probe \
  --trigger b --question "env model question" --run-id r-model3 2>"$TMP/err.txt")
check_json "t2b-model-env-action" "$OUT" ".action" "spawn"
check_json "t2b-model-env-model" "$OUT" ".model" "env-model"

# --model wins over ADVISOR_MODEL.
OUT=$(ADVISOR_STATE_ROOT="$TSTATE" ADVISOR_MODEL=env-model bash "$ASK" probe \
  --trigger b --question "flag wins model question" --run-id r-model4 --model flag-model 2>"$TMP/err.txt")
check_json "t2b-model-flag-wins-env" "$OUT" ".model" "flag-model"

# Invalid ambient model refuses instead of falling back to the map.
OUT=$(ADVISOR_STATE_ROOT="$TSTATE" ADVISOR_MODEL='bad model' bash "$ASK" probe \
  --trigger b --question "invalid env model question" --run-id r-model5 2>"$TMP/err.txt")
check_json "t2b-model-env-invalid-action" "$OUT" ".action" "refuse"
check_json "t2b-model-env-invalid-reason" "$OUT" ".reason" "advisor model invalid"

# Duplicate or empty --model exits 64.
ADVISOR_STATE_ROOT="$TSTATE" bash "$ASK" probe --trigger b --question "dup model" \
  --model a --model b >/dev/null 2>"$TMP/err.txt"
RC=$?
if [ "$RC" -eq 64 ]; then pass "t2b-model-duplicate-64"; else fail "t2b-model-duplicate-64: rc=$RC"; fi
ADVISOR_STATE_ROOT="$TSTATE" bash "$ASK" probe --trigger b --question "empty model" \
  --model= >/dev/null 2>"$TMP/err.txt"
RC=$?
if [ "$RC" -eq 64 ]; then pass "t2b-model-empty-64"; else fail "t2b-model-empty-64: rc=$RC"; fi

# ---- 2c. a model override NEVER persists to the Model map (SPEC-039 M37) -----
plant_advisor
MAP_SHA_BEFORE=$(sha256sum "$MAP" | cut -d" " -f1)
ADVISOR_STATE_ROOT="$TSTATE" bash "$ASK" probe --trigger b --question "no-persist question" \
  --run-id r-nopersist --model no-persist-model >/dev/null 2>"$TMP/err.txt"
ADVISOR_MODEL=no-persist-model bash "$ROOT/skills/advisor/parse-flags.sh" --with-advisor >/dev/null 2>&1
MAP_SHA_AFTER=$(sha256sum "$MAP" | cut -d" " -f1)
if [ "$MAP_SHA_BEFORE" = "$MAP_SHA_AFTER" ] && [ "$(bash "$RESOLVE" advisor)" = "test-model-x" ]; then
  pass "t2c-override-leaves-model-map-byte-identical"
else
  fail "t2c-override-leaves-model-map-byte-identical: map $MAP_SHA_BEFORE -> $MAP_SHA_AFTER"
fi
if grep -q 'write-model' "$ASK" "$ROOT/skills/advisor/parse-flags.sh"; then
  fail "t2c-advisor-seam-calls-no-model-map-writer"
else
  pass "t2c-advisor-seam-calls-no-model-map-writer"
fi

# ---- 2d. council follow-ups (SPEC-039 M37 hardening) ------------------------
# The absent sentinel can never reach the override leg (council critical).
plant_advisor
OUT=$(ADVISOR_STATE_ROOT="$TSTATE" ADVISOR_MODEL=null bash "$ASK" probe \
  --trigger b --question "sentinel null question" --run-id r-sentinel 2>"$TMP/err.txt")
check_json "t2d-sentinel-null-refuses-action" "$OUT" ".action" "refuse"
check_json "t2d-sentinel-null-refuses-reason" "$OUT" ".reason" "advisor model invalid"

# Token grammar: shell metacharacters and traversal never parse as a model.
RC=0
ADVISOR_STATE_ROOT="$TSTATE" bash "$ASK" probe --trigger b --question "meta q" --model '$(id)' >/dev/null 2>"$TMP/err.txt" || RC=$?
if [ "$RC" -eq 64 ]; then pass "t2d-model-metachar-64"; else fail "t2d-model-metachar-64: rc=$RC"; fi
RC=0
ADVISOR_STATE_ROOT="$TSTATE" bash "$ASK" probe --trigger b --question "trav q" --model '../../etc/passwd' >/dev/null 2>"$TMP/err.txt" || RC=$?
if [ "$RC" -eq 64 ]; then pass "t2d-model-traversal-64"; else fail "t2d-model-traversal-64: rc=$RC"; fi
OUT=$(run_probe --trigger b --question "namespaced model question" --run-id r-ns --model spark-llama/ornith1.5-35b-a3b)
check_json "t2d-model-namespaced-spawn" "$OUT" ".action" "spawn"

# A malformed ambient value is caught even when --model wins precedence.
OUT=$(ADVISOR_STATE_ROOT="$TSTATE" ADVISOR_MODEL='bad model' bash "$ASK" probe \
  --trigger b --question "env invalid with flag question" --run-id r-envflag --model good-model 2>"$TMP/err.txt")
check_json "t2d-env-invalid-wins-over-flag-refuse" "$OUT" ".action" "refuse"
check_json "t2d-env-invalid-wins-over-flag-reason" "$OUT" ".reason" "advisor model invalid"

# model_source is recorded for the audit trail.
OUT=$(run_probe --trigger b --question "source flag question" --run-id r-src1 --model src-model-flag)
SRP=$(printf '%s' "$OUT" | jq -r .spawn_request_path)
check_json "t2d-source-flag" "$(cat "$SRP" 2>/dev/null)" ".model_source" "flag"
OUT=$(ADVISOR_STATE_ROOT="$TSTATE" ADVISOR_MODEL=src-model-env bash "$ASK" probe \
  --trigger b --question "source env question" --run-id r-src2 2>"$TMP/err.txt")
SRP=$(printf '%s' "$OUT" | jq -r .spawn_request_path)
check_json "t2d-source-env" "$(cat "$SRP" 2>/dev/null)" ".model_source" "env"
plant_advisor
OUT=$(run_probe --trigger b --question "source map question" --run-id r-src3)
SRP=$(printf '%s' "$OUT" | jq -r .spawn_request_path)
check_json "t2d-source-map" "$(cat "$SRP" 2>/dev/null)" ".model_source" "model-map"

# An override that replaces a mapped choice warns on stderr.
plant_advisor
OUT=$(run_probe --trigger b --question "warn question" --run-id r-warn --model replace-me)
grep -qF "replaces the Model map choice" "$TMP/err.txt" \
  && pass "t2d-override-warns-when-replacing-map" \
  || fail "t2d-override-warns-when-replacing-map: err=$(cat "$TMP/err.txt")"
# An unmapped advisor enabled by an override must not warn about a map it lacks.
clear_layers
OUT=$(run_probe --trigger b --question "no-warn question" --run-id r-nowarn --model only-model)
grep -qF "replaces the Model map choice" "$TMP/err.txt" \
  && fail "t2d-no-warn-when-unmapped" \
  || pass "t2d-no-warn-when-unmapped"

# Cache stays model-blind, and a cache hit reports the model that ruled.
plant_advisor
cat > "$TMP/ruling-prov.json" <<'EOF'
{"ruling":"AGREE","confidence":88,"evidence":[{"cmd":"true","exit":0,"sha256":"abc","locator":"docs/runbooks/omp.md:63"}]}
EOF
OUT=$(run_probe --trigger b --question "cache provenance question" --run-id r-prov1 --model model-alpha)
check_json "t2d-probe-alpha-spawn" "$OUT" ".action" "spawn"
ADVISOR_STATE_ROOT="$TSTATE" bash "$ASK" finalize --run-id r-prov1 --ruling-file "$TMP/ruling-prov.json" >/dev/null 2>"$TMP/err.txt"
RC=$?
if [ "$RC" -eq 0 ]; then pass "t2d-probe-finalize-alpha"; else fail "t2d-probe-finalize-alpha: rc=$RC err=$(cat "$TMP/err.txt")"; fi
CNT_ALPHA=$(jq -r .total "$TSTATE/runs/r-prov1/counters.json")
OUT=$(run_probe --trigger b --question "cache provenance question" --run-id r-prov2 --model model-beta)
check_json "t2d-probe-beta-cache-hit" "$OUT" ".action" "cache-hit"
check_json "t2d-probe-beta-reports-alpha" "$OUT" ".model" "model-alpha"
CNT_BETA=$(jq -r ".total // 0" "$TSTATE/runs/r-prov2/counters.json" 2>/dev/null)
if [ "${CNT_BETA:-0}" = "0" ]; then pass "t2d-cache-hit-free-across-overrides"; else fail "t2d-cache-hit-free-across-overrides: counters=$CNT_BETA"; fi

# ---- 3. re-entrant probe -> 64 ----------------------------------------------
flock -w 5 "$TSTATE/lock" -c "sleep 3" &
HOLD_PID=$!
sleep 1
ADVISOR_STATE_ROOT="$TSTATE" bash "$ASK" probe --trigger b --question "x" >/dev/null 2>"$TMP/err.txt"
RC=$?
if [ "$RC" -eq 64 ]; then pass "t3-reentrant-probe-64"; else fail "t3-reentrant-probe-64: rc=$RC"; fi
kill "$HOLD_PID" 2>/dev/null; wait "$HOLD_PID" 2>/dev/null

# ---- 4. finalize ruling -> cache; same question -> cache-hit (free) ----------
cat > "$TMP/ruling.json" <<'EOF'
{"ruling":"CONTRADICT","confidence":92,"corrected_claim":"omp is not installed here",
 "evidence":[{"cmd":"pacman -Q openmpi","exit":1,"sha256":"abc","locator":"docs/runbooks/omp.md:12"}]}
EOF
ADVISOR_STATE_ROOT="$TSTATE" bash "$ASK" finalize --run-id r1 --ruling-file "$TMP/ruling.json" >/dev/null 2>"$TMP/err.txt"
RC=$?
if [ "$RC" -eq 0 ] && [ -f "$TSTATE/cache/$HASH.json" ]; then
  pass "t4-finalize-caches-ruling"
else
  fail "t4-finalize-caches-ruling: rc=$RC"
fi
CNT_BEFORE=$(jq -r .total "$TSTATE/runs/r1/counters.json")
OUT=$(run_probe --trigger b --question "what is omp")
check_json "t4-cache-hit-action" "$OUT" ".action" "cache-hit"
check_json "t4-cache-hit-path" "$OUT" ".cached_ruling_path" "$TSTATE/cache/$HASH.json"
CNT_AFTER=$(jq -r .total "$TSTATE/runs/r1/counters.json")
if [ "$CNT_BEFORE" = "$CNT_AFTER" ]; then pass "t4-cache-hit-free"; else fail "t4-cache-hit-free: $CNT_BEFORE -> $CNT_AFTER"; fi

# ---- 5. finalize rejects bad ruling taxonomy (exit 64) ------------------------
echo '{"ruling":"MAYBE","confidence":50}' > "$TMP/bad-ruling.json"
ADVISOR_STATE_ROOT="$TSTATE" bash "$ASK" finalize --run-id r1 --ruling-file "$TMP/bad-ruling.json" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 64 ]; then pass "t5-bad-ruling-64"; else fail "t5-bad-ruling-64: rc=$RC"; fi
echo '{"ruling":"AGREE","confidence":101}' > "$TMP/bad-conf.json"
ADVISOR_STATE_ROOT="$TSTATE" bash "$ASK" finalize --run-id r1 --ruling-file "$TMP/bad-conf.json" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 64 ]; then pass "t5-bad-confidence-64"; else fail "t5-bad-confidence-64: rc=$RC"; fi

# ---- 6. timeout is never a partial ruling ------------------------------------
plant_advisor
OUT=$(run_probe --trigger a --question "is docker running" --run-id r2)
check_json "t6-spawn-r2" "$OUT" ".action" "spawn"
ADVISOR_STATE_ROOT="$TSTATE" bash "$ASK" finalize --run-id r2 --timeout >/dev/null 2>&1
HASH2=$(jq -r .question_hash "$TSTATE/runs/r2/spawn-request.json")
if [ ! -f "$TSTATE/cache/$HASH2.json" ]; then
  pass "t6-timeout-no-cache"
else
  fail "t6-timeout-no-cache: timeout produced a cached ruling"
fi
if [ "$(jq -r .status "$TSTATE/runs/r2/status.json")" = "timeout" ]; then
  pass "t6-timeout-status-recorded"
else
  fail "t6-timeout-status-recorded"
fi
# retry after timeout: counts again (fresh spawn, not a cache hit)
OUT=$(run_probe --trigger a --question "is docker running" --run-id r2)
check_json "t6-retry-is-spawn" "$OUT" ".action" "spawn"

# ---- 7. per-trigger reserve (a)=3 then cap -----------------------------------
plant_advisor
for i in 1 2 3 4; do
  OUT=$(run_probe --trigger a --question "reserve q$i" --run-id r3)
done
check_json "t7-reserve-exhausted" "$OUT" ".action" "cap"
check_json "t7-reserve-reason" "$OUT" ".reason" "trigger a reserve exhausted (3)"
CNT3=$(jq -r '.a' "$TSTATE/runs/r3/counters.json")
if [ "$CNT3" = "3" ]; then pass "t7-count-a-3"; else fail "t7-count-a-3: $CNT3"; fi

# ---- 8. global cap 5 across triggers; ADVISOR_MAX_CALLS lowers only ----------
plant_advisor
for i in 1 2 3; do
  run_probe --trigger a --question "g a$i" --run-id r4 >/dev/null
done
OUT=$(run_probe --trigger b --question "g b1" --run-id r4)
check_json "t8-global-fifth-spawns" "$OUT" ".action" "spawn"
OUT=$(run_probe --trigger b --question "g b2" --run-id r4)
check_json "t8-global-sixth-caps" "$OUT" ".action" "cap"
# ADVISOR_MAX_CALLS lowers only: trigger a (reserve 3) with MAX_CALLS=2 —
# the global 2 binds before the reserve, proving the knob lowers the global.
OUT=$(ADVISOR_MAX_CALLS=2 ADVISOR_STATE_ROOT="$TSTATE" bash "$ASK" probe --trigger a --question "m1" --run-id r5 2>/dev/null)
check_json "t8-maxcalls-first-spawn" "$OUT" ".action" "spawn"
OUT=$(ADVISOR_MAX_CALLS=2 ADVISOR_STATE_ROOT="$TSTATE" bash "$ASK" probe --trigger a --question "m2" --run-id r5 2>/dev/null)
check_json "t8-maxcalls-second-spawn" "$OUT" ".action" "spawn"
OUT=$(ADVISOR_MAX_CALLS=2 ADVISOR_STATE_ROOT="$TSTATE" bash "$ASK" probe --trigger a --question "m3" --run-id r5 2>/dev/null)
check_json "t8-maxcalls-third-caps" "$OUT" ".action" "cap"
check_json "t8-maxcalls-reason" "$OUT" ".reason" "global per-run cap exhausted (2)"
# ADVISOR_MAX_CALLS above 5 does NOT raise the global cap: 5 b-probes spawn
# (reserve b=4 is not the binder — global 5 is), the 6th caps on global.
for i in 1 2 3 4 5 6; do
  OUT=$(ADVISOR_MAX_CALLS=9 ADVISOR_STATE_ROOT="$TSTATE" bash "$ASK" probe --trigger b --question "hi$i" --run-id r6 2>/dev/null)
done
check_json "t8-maxcalls-no-raise" "$OUT" ".action" "cap"

# ---- 9. dedupe: same trigger+question+evidence -> same hash ------------------
plant_advisor
mkdir -p "$TMP/ev1"; echo "x" > "$TMP/ev1/f.txt"
H1=$(run_probe --trigger c --question "dedupe me" --evidence-dir "$TMP/ev1" --run-id r7 | jq -r .spawn_request_path | xargs jq -r .question_hash)
H2=$(run_probe --trigger c --question "dedupe    me" --evidence-dir "$TMP/ev1" --run-id r8 2>/dev/null | jq -r '.spawn_request_path // empty' | xargs -r jq -r .question_hash)
if [ -n "$H2" ] && [ "$H1" = "$H2" ]; then
  pass "t9-dedupe-same-hash"
else
  fail "t9-dedupe-same-hash: $H1 vs $H2"
fi
mkdir -p "$TMP/ev2"; echo "y" > "$TMP/ev2/g.txt"
H3=$(run_probe --trigger c --question "dedupe me" --evidence-dir "$TMP/ev2" --run-id r9 2>/dev/null | jq -r '.spawn_request_path // empty' | xargs -r jq -r .question_hash)
if [ -n "$H3" ] && [ "$H1" != "$H3" ]; then
  pass "t9-different-evidence-different-hash"
else
  fail "t9-different-evidence-different-hash: $H1 vs $H3"
fi

# ---- 10. epic total cap 8 (default) ------------------------------------------
plant_advisor
mkdir -p "$TSTATE/epic/CDT-999"
echo '{"total":8}' > "$TSTATE/epic/CDT-999/counters.json"
OUT=$(run_probe --trigger a --question "epic q1" --epic-id CDT-999 --run-id r10)
check_json "t10-epic-cap" "$OUT" ".action" "cap"
check_json "t10-epic-cap-reason" "$OUT" ".reason" "epic total cap exhausted (8)"
echo '{"total":7}' > "$TSTATE/epic/CDT-999/counters.json"
OUT=$(run_probe --trigger a --question "epic q2" --epic-id CDT-999 --run-id r11)
check_json "t10-epic-under-cap-spawns" "$OUT" ".action" "spawn"
EPIC_TOTAL=$(jq -r .total "$TSTATE/epic/CDT-999/counters.json")
if [ "$EPIC_TOTAL" = "8" ]; then pass "t10-epic-counter-incremented"; else fail "t10-epic-counter-incremented: $EPIC_TOTAL"; fi

# ---- 11. trigger validation ---------------------------------------------------
ADVISOR_STATE_ROOT="$TSTATE" bash "$ASK" probe --trigger z --question "x" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 64 ]; then pass "t11-bad-trigger-64"; else fail "t11-bad-trigger-64: rc=$RC"; fi

# ---- 12. finalize rejects a malformed evidence[].locator (exit 64, M18) -------
plant_advisor
OUT=$(run_probe --trigger a --question "m18 q1" --run-id r12)
check_json "t12-spawn-r12" "$OUT" ".action" "spawn"
cat > "$TMP/bad-locator.json" <<'EOF'
{"ruling":"AGREE","confidence":50,
 "evidence":[{"cmd":"pacman -Q openmpi","exit":1,"sha256":"abc","locator":"no-line-number"}]}
EOF
ADVISOR_STATE_ROOT="$TSTATE" bash "$ASK" finalize --run-id r12 --ruling-file "$TMP/bad-locator.json" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 64 ]; then pass "t12-bad-locator-64"; else fail "t12-bad-locator-64: rc=$RC"; fi
if [ ! -f "$TSTATE/cache/$(jq -r .question_hash "$TSTATE/runs/r12/spawn-request.json").json" ]; then
  pass "t12-bad-locator-no-cache"
else
  fail "t12-bad-locator-no-cache: rejected ruling was cached"
fi

# ---- 13. --spawn-fail records status and never writes the cache ---------------
plant_advisor
OUT=$(run_probe --trigger a --question "sf q1" --run-id r13)
check_json "t13-spawn-r13" "$OUT" ".action" "spawn"
ADVISOR_STATE_ROOT="$TSTATE" bash "$ASK" finalize --run-id r13 --spawn-fail >/dev/null 2>&1
RC=$?
HASH13=$(jq -r .question_hash "$TSTATE/runs/r13/spawn-request.json")
if [ "$RC" -eq 0 ] && [ "$(jq -r .status "$TSTATE/runs/r13/status.json")" = "spawn-fail" ]; then
  pass "t13-spawn-fail-status"
else
  fail "t13-spawn-fail-status: rc=$RC"
fi
if [ ! -f "$TSTATE/cache/$HASH13.json" ]; then
  pass "t13-spawn-fail-no-cache"
else
  fail "t13-spawn-fail-no-cache: cache written by --spawn-fail"
fi

# ---- 14. --refuse records status and never writes the cache -------------------
plant_advisor
OUT=$(run_probe --trigger a --question "rf q1" --run-id r14)
check_json "t14-spawn-r14" "$OUT" ".action" "spawn"
ADVISOR_STATE_ROOT="$TSTATE" bash "$ASK" finalize --run-id r14 --refuse >/dev/null 2>&1
RC=$?
HASH14=$(jq -r .question_hash "$TSTATE/runs/r14/spawn-request.json")
if [ "$RC" -eq 0 ] && [ "$(jq -r .status "$TSTATE/runs/r14/status.json")" = "refuse" ]; then
  pass "t14-refuse-status"
else
  fail "t14-refuse-status: rc=$RC"
fi
if [ ! -f "$TSTATE/cache/$HASH14.json" ]; then
  pass "t14-refuse-no-cache"
else
  fail "t14-refuse-no-cache: cache written by --refuse"
fi

# ---- 15. advisor state root is gitignored (exhibited, not just commented) -----
( cd "$ROOT" && git check-ignore -q .claude/advisor/ ) && RC=0 || RC=$?
if [ "$RC" -eq 0 ] && grep -q '^\.claude/advisor/$' "$ROOT/.gitignore"; then
  pass "t15-advisor-state-gitignored"
else
  fail "t15-advisor-state-gitignored: check-ignore rc=$RC"
fi

# ---- 16. sourcing attempt exits 64 (subprocess CLI, never sourced) ------------
bash -c ". '$ASK'" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 64 ]; then pass "t16-source-guard-64"; else fail "t16-source-guard-64: rc=$RC"; fi

# ---- 17. probe stdout is exactly one JSON object -------------------------------
plant_advisor
OUT=$(run_probe --trigger a --question "one object" --run-id r17)
N=$(printf '%s' "$OUT" | jq -s 'length' 2>/dev/null)
if [ "$N" = "1" ]; then pass "t17-probe-single-object"; else fail "t17-probe-single-object: $N objects"; fi

# ---- 18. finalize rejects a non-integer confidence (exit 64) --------------------
plant_advisor
run_probe --trigger a --question "ni q1" --run-id r18 >/dev/null
echo '{"ruling":"AGREE","confidence":"high"}' > "$TMP/bad-conf-type.json"
ADVISOR_STATE_ROOT="$TSTATE" bash "$ASK" finalize --run-id r18 --ruling-file "$TMP/bad-conf-type.json" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 64 ]; then pass "t18-bad-confidence-type-64"; else fail "t18-bad-confidence-type-64: rc=$RC"; fi

# ---- 19. per-trigger reserve (b)=4 then cap -------------------------------------
plant_advisor
for i in 1 2 3 4 5; do
  OUT=$(run_probe --trigger b --question "bres q$i" --run-id r19)
done
check_json "t19-b-reserve-cap" "$OUT" ".action" "cap"
check_json "t19-b-reserve-reason" "$OUT" ".reason" "trigger b reserve exhausted (4)"

# ---- 20. per-trigger reserve (c)=2 then cap -------------------------------------
plant_advisor
for i in 1 2 3; do
  OUT=$(run_probe --trigger c --question "cres q$i" --run-id r20)
done
check_json "t20-c-reserve-cap" "$OUT" ".action" "cap"
check_json "t20-c-reserve-reason" "$OUT" ".reason" "trigger c reserve exhausted (2)"

# ---- 21. a retry after timeout increments the counter (retries count) -----------
CNT21=$(jq -r .total "$TSTATE/runs/r2/counters.json")
if [ "$CNT21" = "2" ]; then pass "t21-retry-counter-incremented"; else fail "t21-retry-counter-incremented: $CNT21"; fi

# ---- 22. finalize rejects a ruling with no evidence[] (exit 64, M18) ------------
plant_advisor
run_probe --trigger a --question "ev q1" --run-id r22 >/dev/null
echo '{"ruling":"AGREE","confidence":50}' > "$TMP/no-evidence.json"
ADVISOR_STATE_ROOT="$TSTATE" bash "$ASK" finalize --run-id r22 --ruling-file "$TMP/no-evidence.json" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 64 ]; then pass "t22-bad-evidence-empty-64"; else fail "t22-bad-evidence-empty-64: rc=$RC"; fi

# =============================================================================
# CDT-565 — M29 decision map + M30 advisor card (SPEC-039 AC10 / C8).
# Cards are written into a HERMETIC fixture repo ($FXM) so append-card's
# git-common-dir MROOT never touches the real .claude/autopilot/.
# =============================================================================
FXM="$TMP/fxmroot"
git init -q "$FXM"
fin_card() { # fin_card <finalize args...> — finalize with card context, cwd $FXM
  (cd "$FXM" && CLAUDE_PLUGIN_ROOT="$ROOT" ADVISOR_STATE_ROOT="$TSTATE" \
    bash "$ASK" finalize "$@") 2>"$TMP/fin.err"
}
card_read() { # card_read <ticket_id> — read-cards from the fixture MROOT
  (cd "$FXM" && CLAUDE_PLUGIN_ROOT="$ROOT" bash "$ROOT/skills/autopilot/read-cards.sh" "$1") 2>/dev/null
}
rule() { # rule <file> <json>
  printf '%s' "$2" > "$TMP/$1"
}
check_card() { # check_card <id> <ticket> <jq-expr>
  local id="$1" ticket="$2" expr="$3" got
  got=$(card_read "$ticket" | jq -c "$expr" 2>/dev/null)
  if [ "$got" = "true" ]; then pass "$id"; else fail "$id: got $got"; fi
}

# ---- t23: AGREE @ 85 -> proceed / null, confidence 85, M30 advisor object ----
plant_advisor
run_probe --trigger b --question "map agree" --run-id r23 >/dev/null
HASH_R23=$(jq -r .question_hash "$TSTATE/runs/r23/spawn-request.json")
rule r23.json '{"ruling":"AGREE","confidence":85,"evidence":[{"cmd":"pacman -Q openmpi","exit":1,"sha256":"abc","locator":"docs/runbooks/omp.md:12"}]}'
fin_card --run-id r23 --ruling-file "$TMP/r23.json" \
  --card-workflow orchestrate --card-ticket CDT-565 --card-gate plan-approve \
  --card-iteration 1 --card-run-start-epoch "$(date +%s)"
# AC4 sub-clauses each get their own run-output PASS line (M14 source-assert
# cap: an aggregate name is not per-clause run output).
check_card "t23-agree-proceed-null" CDT-565 \
  '.[0] | .decision == "proceed" and .blocking_condition == null'
check_card "t23b-agree-confidence-actor-decided-by" CDT-565 \
  '.[0] | .confidence == 85 and .actor == "advisor" and .decided_by == "auto"'
check_card "t23c-agree-bump-null-19-keys" CDT-565 \
  '.[0] | .bump == null and .schema_version == 1 and (keys_unsorted | length) == 19'
check_card "t23d-agree-rationale-line" CDT-565 \
  '.[0] | .rationale == "trigger=b ruling=AGREE model=test-model-x"'
check_card "t23e-agree-advisor-object-m30-shape" CDT-565 '
  .[0] | .advisor.ruling == "AGREE" and .advisor.model == "test-model-x"
  and .advisor.trigger == "b" and .advisor.timeout == false
  and .advisor.marker == null and .advisor.cache_hit == false
  and .advisor.evidence_over_memory == true
  and .advisor.question_hash == "'"$HASH_R23"'"
  and (.advisor.evidence | length) == 1'
# AC4 "passed as a path": the object on the card equals the on-disk file the
# seam wrote — exhibited at run time, not by source asserts.
card_read CDT-565 | jq -S '.[0].advisor' > "$TMP/card23.json"
jq -S . "$TSTATE/runs/r23/advisor-object.json" > "$TMP/obj23.json"
if cmp -s "$TMP/obj23.json" "$TMP/card23.json"; then
  pass "t23f-agree-advisor-object-travels-from-file-to-card"
else
  fail "t23f-agree-advisor-object-travels-from-file-to-card"
fi
if [ ! -f "$TSTATE/runs/r23/advisor-object.json" ]; then
  fail "t23-advisor-object-file: missing runs/r23/advisor-object.json"
else
  pass "t23-advisor-object-file"
fi

# ---- t24: CONTRADICT @ 92 -> halt/BC7, fail-closed confidence 0 ---------------
# (M29's "confidence is the ruling's" collides with append-card invariant (b):
# a BC7 card at confidence >= 80 is unwritable, so a high-confidence refutation
# fails closed to 0 — the M14(b) CONTRADICTED->0 precedent.)
run_probe --trigger a --question "map contradict" --run-id r24 >/dev/null
rule r24.json '{"ruling":"CONTRADICT","confidence":92,"evidence":[{"cmd":"true","exit":0,"sha256":"x","locator":"a:1"}]}'
fin_card --run-id r24 --ruling-file "$TMP/r24.json" \
  --card-workflow orchestrate --card-ticket CDT-565 --card-gate plan-approve \
  --card-iteration 1 --card-run-start-epoch "$(date +%s)"
check_card "t24-contradict-halt-bc7-conf0" CDT-565 '
  (.[1] | .decision == "halt" and .blocking_condition == 7 and .confidence == 0
  and .advisor.ruling == "CONTRADICT")'

# ---- t25: INSUFFICIENT @ 60 -> halt/BC7 with the ruling's confidence ----------
run_probe --trigger a --question "map insuff" --run-id r25 >/dev/null
rule r25.json '{"ruling":"INSUFFICIENT","confidence":60,"evidence":[{"cmd":"true","exit":0,"sha256":"x","locator":"a:1"}]}'
fin_card --run-id r25 --ruling-file "$TMP/r25.json" \
  --card-workflow orchestrate --card-ticket CDT-565 --card-gate plan-approve \
  --card-iteration 1 --card-run-start-epoch "$(date +%s)"
check_card "t25-insufficient-halt-bc7-conf60" CDT-565 '
  (.[2] | .decision == "halt" and .blocking_condition == 7 and .confidence == 60)'

# ---- t26: AGREE @ 79 -> halt/BC7 with the ruling's confidence -----------------
run_probe --trigger a --question "map lowagree" --run-id r26 >/dev/null
rule r26.json '{"ruling":"AGREE","confidence":79,"evidence":[{"cmd":"true","exit":0,"sha256":"x","locator":"a:1"}]}'
fin_card --run-id r26 --ruling-file "$TMP/r26.json" \
  --card-workflow orchestrate --card-ticket CDT-565 --card-gate plan-approve \
  --card-iteration 1 --card-run-start-epoch "$(date +%s)"
check_card "t26-agree79-halt-bc7-conf79" CDT-565 '
  (.[3] | .decision == "halt" and .blocking_condition == 7 and .confidence == 79)'

# ---- t27: AGREE @ 80 (boundary) -> proceed / null ------------------------------
run_probe --trigger a --question "map boundary" --run-id r27 >/dev/null
rule r27.json '{"ruling":"AGREE","confidence":80,"evidence":[{"cmd":"true","exit":0,"sha256":"x","locator":"a:1"}]}'
fin_card --run-id r27 --ruling-file "$TMP/r27.json" \
  --card-workflow orchestrate --card-ticket CDT-565 --card-gate plan-approve \
  --card-iteration 1 --card-run-start-epoch "$(date +%s)"
check_card "t27-agree80-boundary-proceed" CDT-565 '
  (.[4] | .decision == "proceed" and .blocking_condition == null and .confidence == 80)'

# ---- t34: append-card cross-field invariant (b) exhibited as run output -------
# (AC5's fail-closed-0 rationale: the WRITER rejects a BC7 card at confidence
# >= 80 — this suite's own run output, matching a11 in test-card-validation.)
(cd "$FXM" && CLAUDE_PLUGIN_ROOT="$ROOT" bash "$ROOT/skills/autopilot/append-card.sh" \
  orchestrate CDT-565-IB plan-approve halt auto null 85 7 \
  "t34-invariant-b" 1 10 orchestrator "invariant b probe") >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 64 ] && [ ! -s "$FXM/.claude/autopilot/CDT-565-IB.jsonl" ]; then
  pass "t34-bc7-card-at-confidence-ge80-rejected-64"
else
  fail "t34-bc7-card-at-confidence-ge80-rejected-64: rc=$RC"
fi

# ---- t28: finalize WITHOUT card context writes no card (C4 unchanged) ---------
run_probe --trigger a --question "map noctx" --run-id r28 >/dev/null
HASH_R28=$(jq -r .question_hash "$TSTATE/runs/r28/spawn-request.json")
rule r28.json '{"ruling":"AGREE","confidence":85,"evidence":[{"cmd":"true","exit":0,"sha256":"x","locator":"a:1"}]}'
ADVISOR_STATE_ROOT="$TSTATE" bash "$ASK" finalize --run-id r28 --ruling-file "$TMP/r28.json" >/dev/null 2>&1
RC=$?
N28=$(card_read CDT-565 | jq 'length' 2>/dev/null)
if [ "$RC" -eq 0 ] && [ "$N28" = "5" ] && [ -f "$TSTATE/cache/$HASH_R28.json" ]; then
  pass "t28-no-card-context-no-ledger-cache-still-written"
else
  fail "t28-no-card-context-no-ledger-cache-still-written: rc=$RC cards=$N28"
fi

# ---- t29: partial card context -> 64; card context on a status finalize -> 64 -
fin_card --run-id r27 --ruling-file "$TMP/r27.json" --card-gate plan-approve >/dev/null 2>&1
RC=$?
[ "$RC" -eq 64 ] && pass "t29-partial-card-context-64" || fail "t29-partial-card-context-64: rc=$RC"
run_probe --trigger a --question "map toctx" --run-id r29 >/dev/null
fin_card --run-id r29 --timeout \
  --card-workflow orchestrate --card-ticket CDT-565 --card-gate plan-approve \
  --card-iteration 1 --card-run-start-epoch "$(date +%s)" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 64 ] && pass "t29-card-context-with-status-finalize-64" || fail "t29-card-context-with-status-finalize-64: rc=$RC"

# ---- t30: a writer reject exits 64 and leaves NOTHING cached ------------------
# The reject targets the REAL ticket (CDT-565) via an invalid card arg the
# seam passes through (--card-gate); the ledger line count must not move.
run_probe --trigger a --question "map reject" --run-id r30 >/dev/null
rule r30.json '{"ruling":"AGREE","confidence":85,"evidence":[{"cmd":"true","exit":0,"sha256":"x","locator":"a:1"}]}'
N30_BEFORE=$(card_read CDT-565 | jq 'length' 2>/dev/null)
fin_card --run-id r30 --ruling-file "$TMP/r30.json" \
  --card-workflow orchestrate --card-ticket CDT-565 --card-gate not-a-gate \
  --card-iteration 1 --card-run-start-epoch "$(date +%s)" >/dev/null 2>&1
RC=$?
N30_AFTER=$(card_read CDT-565 | jq 'length' 2>/dev/null)
HASH_R30=$(jq -r .question_hash "$TSTATE/runs/r30/spawn-request.json")
if [ "$RC" -eq 64 ] && [ "$N30_AFTER" = "$N30_BEFORE" ] \
  && [ ! -f "$TSTATE/cache/$HASH_R30.json" ]; then
  pass "t30-writer-reject-64-no-new-ledger-line-no-cache (CDT-565 count $N30_BEFORE -> $N30_AFTER)"
else
  fail "t30-writer-reject-64-no-new-ledger-line-no-cache: rc=$RC cards=$N30_BEFORE->$N30_AFTER cache=$([ -f "$TSTATE/cache/$HASH_R30.json" ] && echo y || echo n)"
fi

# ---- t30b: after the reject the ruling is NOT cached — the retry re-spawns ----
OUT=$(run_probe --trigger a --question "map reject" --run-id r30)
check_json "t30b-retry-respawns-not-cache-hit" "$OUT" ".action" "spawn"

# ---- t32/t33: card context on a status finalize -> 64, no card, no cache ------
N32_BEFORE=$(card_read CDT-565 | jq 'length' 2>/dev/null)
run_probe --trigger a --question "map sfctx" --run-id r32 >/dev/null
fin_card --run-id r32 --spawn-fail \
  --card-workflow orchestrate --card-ticket CDT-565 --card-gate plan-approve \
  --card-iteration 1 --card-run-start-epoch "$(date +%s)" >/dev/null 2>&1
RC=$?
HASH_R32=$(jq -r .question_hash "$TSTATE/runs/r32/spawn-request.json")
N32_AFTER=$(card_read CDT-565 | jq 'length' 2>/dev/null)
if [ "$RC" -eq 64 ] && [ "$N32_AFTER" = "$N32_BEFORE" ] \
  && [ ! -f "$TSTATE/cache/$HASH_R32.json" ]; then
  pass "t32-card-context-with-spawn-fail-64-no-card-no-cache"
else
  fail "t32-card-context-with-spawn-fail-64-no-card-no-cache: rc=$RC cards=$N32_BEFORE->$N32_AFTER"
fi

N33_BEFORE=$(card_read CDT-565 | jq 'length' 2>/dev/null)
run_probe --trigger a --question "map rfctx" --run-id r33 >/dev/null
fin_card --run-id r33 --refuse \
  --card-workflow orchestrate --card-ticket CDT-565 --card-gate plan-approve \
  --card-iteration 1 --card-run-start-epoch "$(date +%s)" >/dev/null 2>&1
RC=$?
HASH_R33=$(jq -r .question_hash "$TSTATE/runs/r33/spawn-request.json")
N33_AFTER=$(card_read CDT-565 | jq 'length' 2>/dev/null)
if [ "$RC" -eq 64 ] && [ "$N33_AFTER" = "$N33_BEFORE" ] \
  && [ ! -f "$TSTATE/cache/$HASH_R33.json" ]; then
  pass "t33-card-context-with-refuse-64-no-card-no-cache"
else
  fail "t33-card-context-with-refuse-64-no-card-no-cache: rc=$RC cards=$N33_BEFORE->$N33_AFTER"
fi

# ---- t31: BC8 unavailable fallback (M27/AC11) — the caller's halt card ---------
# Unconfigured advisor (clear layers -> probe refuse), then the documented
# self-answer §3g argv: ONE halt card, blocking_condition 8, exact marker in
# the advisor object. BC list stays eight (no ninth condition anywhere).
clear_layers
G_OUT=$(run_probe --trigger a --question "bc8 unconfigured" --run-id r31)
check_json "t31-probe-refuses" "$G_OUT" ".action" "refuse"
BJ="$FXM/bc8-obj.json"
jq -cn --arg trigger a \
  '{ruling: null, corrected_claim: null, evidence: [], model: "",
    evidence_over_memory: true, question_hash: "", trigger: $trigger,
    cache_hit: false, timeout: false,
    marker: "advisor unavailable — fell back"}' > "$BJ"
(cd "$FXM" && CLAUDE_PLUGIN_ROOT="$ROOT" bash "$ROOT/skills/autopilot/append-card.sh" \
  orchestrate CDT-565-BC8 plan-approve halt auto null 0 8 \
  "orchestrate-CDT-565-1" 1 5 advisor "advisor unavailable — fell back (refuse): advisor not configured" \
  --advisor-json "$BJ") >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ] && card_read CDT-565-BC8 | jq -e '
  .[0] | .decision == "halt" and .blocking_condition == 8
  and .decided_by == "auto" and .actor == "advisor" and .bump == null
  and .confidence == 0
  and .advisor.marker == "advisor unavailable — fell back"
  and .advisor.ruling == null and .advisor.trigger == "a"
  and .advisor.timeout == false
' >/dev/null 2>&1; then
  pass "t31-bc8-unavailable-card-exact-marker"
else
  fail "t31-bc8-unavailable-card-exact-marker: rc=$RC"
fi
# The writer still rejects a ninth blocking condition (BC list stays 8).
(cd "$FXM" && CLAUDE_PLUGIN_ROOT="$ROOT" bash "$ROOT/skills/autopilot/append-card.sh" \
  orchestrate CDT-565-BC8 plan-approve halt auto null 0 9 \
  "orchestrate-CDT-565-1" 1 5 advisor "ninth" --advisor-json "$BJ") >/dev/null 2>&1
RC=$?
[ "$RC" -eq 64 ] && pass "t31-no-ninth-bc-writer-64" || fail "t31-no-ninth-bc-writer-64: rc=$RC"

# =============================================================================
# CDT-562 (SPEC-039 C9) — doc-bite tests: the M31/M32 memory-content rules and
# the --memory write-path gate, each as its own run-output PASS line. Greps the
# actual bytes of skills/agent-memory/advisor-protocol.md; an absent clause
# fails loudly (FAIL counter -> exit 1).
# =============================================================================
PROTO="$ROOT/skills/agent-memory/advisor-protocol.md"

# ---- t35: M31 — persisted facts carry a re-verify predicate -------------------
if grep -q 're-verify predicate' "$PROTO" \
  && grep -qF '`{cmd, sha256, version, ts}`' "$PROTO"; then
  pass "t35-m31-reverify-predicate-tuple-documented"
else
  fail "t35-m31-reverify-predicate-tuple-documented: advisor-protocol.md lacks 're-verify predicate' or '{cmd, sha256, version, ts}'"
fi

# ---- t36: M31 — a row goes stale when version changes -------------------------
if grep -qF 'goes stale when `version` changes' "$PROTO"; then
  pass "t36-m31-stale-when-version-changes-documented"
else
  fail "t36-m31-stale-when-version-changes-documented: missing 'goes stale when `version` changes'"
fi

# ---- t37: M31 — evidence_over_memory enforcement -------------------------------
if grep -q 'evidence_over_memory' "$PROTO"; then
  pass "t37-evidence-over-memory-enforcement-documented"
else
  fail "t37-evidence-over-memory-enforcement-documented: missing 'evidence_over_memory'"
fi

# ---- t38: M32 — the never-persist list -----------------------------------------
if grep -qF 'NEVER persist: rulings-as-facts' "$PROTO"; then
  pass "t38-m32-never-persist-list-documented"
else
  fail "t38-m32-never-persist-list-documented: missing 'NEVER persist: rulings-as-facts'"
fi

# ---- t39: M32 — user-overridden rulings persist as a pattern only --------------
if grep -qF 'persist as a pattern only' "$PROTO"; then
  pass "t39-m32-pattern-only-documented"
else
  fail "t39-m32-pattern-only-documented: missing 'persist as a pattern only'"
fi

# ---- t40: M33 — the --memory write-path gate in the write fence ----------------
if grep -qF 'require-agent.sh" --memory' "$PROTO"; then
  pass "t40-memory-write-path-gate-documented"
else
  fail "t40-memory-write-path-gate-documented: missing 'require-agent.sh\" --memory' gate in advisor-protocol.md"
fi

# =============================================================================
echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
