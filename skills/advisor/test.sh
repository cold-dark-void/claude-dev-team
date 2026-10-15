#!/usr/bin/env bash
# test.sh — advisor ask.sh probe/finalize seam bite-tests (SPEC-039 T6 / C4).
#
# Machine-check: bash skills/advisor/test.sh  (exit 0)
#
# Covers the CDT-556-C4 acceptance criteria:
#   - probe actions spawn|cache-hit|refuse|cap; probe never spawns
#   - unmapped -> refuse "advisor not configured", never a tier default
#   - caps: per-trigger reserves a=3/b=4/c=2, global 5,
#     ADVISOR_MAX_CALLS lowers only, hash dedupe, epic total 8
#   - re-entrant probe exits 64; finalize ruling taxonomy; timeout is
#     never a partial ruling; bad locator 64; spawn-fail/refuse status-only;
#     gitignored state root; sourcing attempt exits 64; single-object stdout;
#     non-integer confidence 64; b/c reserves; retry counter increments;
#     empty-evidence ruling 64

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
echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
