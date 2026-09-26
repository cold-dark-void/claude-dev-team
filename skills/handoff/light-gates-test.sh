#!/usr/bin/env bash
# light-gates-test.sh — CDT-91 T9c / SPEC-018 M10c test 31 + CDT-203 --miner-model parse
# Coverage:
#   (1) Cold + --light → usage fail (static gate in commands/handoff.md + fence run)
#   (2) Bare warm finalize (no --light) still writes M8 cache (regression vs light skip)
#   (3) CDT-203 AC1–AC5: --miner-model parse/export (flag > env > light > inherit)
#
# The Step 1 fence is the sole parent fence (M19.11 — parse through prepare
# folded in). It is run end to end against the shared stub plugin root
# (skills/handoff/fixtures/fence-harness.sh), not sourced as a parse-only
# prefix — the fence's own PDH/prepass/discover calls need somewhere real (or
# stubbed) to resolve to.
# Run: bash skills/handoff/light-gates-test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
CMD="$ROOT/commands/handoff.md"
PREPASS="$HERE/prepass.sh"
FIX="$HERE/fixtures"
THRASH="$FIX/events-thrash.json"
GITBLOB="$FIX/git-state.txt"

# shellcheck source=skills/handoff/fixtures/fence-harness.sh
. "$FIX/fence-harness.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/light-gates-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
harness_init

FENCE_FILE="$WORK/step1-parse.sh"
harness_extract_fence "$CMD" "$FENCE_FILE"

# run_parse <args> [miner-env] — runs the folded fence against the stub root.
# miner-env, when given, is passed through to harness_run's hermetic
# miner-model arg, which re-exports HANDOFF_MINER_MODEL after the child's env
# is stripped (operator env precedence case — SPEC-030 R16). Sets RC; writes
# $WORK/run.out $WORK/run.err.
run_parse() {
  local args="$1" miner="${2-}"
  harness_run "$FENCE_FILE" "$args" "$miner"
  RC=$HARNESS_RC
}

# ---- T0: fixtures ----
if [ -f "$CMD" ] && [ -x "$PREPASS" ] && [ -f "$THRASH" ] && [ -f "$GITBLOB" ]; then ok
else bad "T0 missing CMD/PREPASS/fixtures"; fi

# ---- T1: static — commands/handoff.md warm-only gate (AC-2) ----
# Gate: LIGHT=1 && WARM!=1 → usage error + exit 1
if grep -q 'M10c: --light is warm-only' "$CMD" \
   && grep -qE '\[ "\$LIGHT" = "1" \] && \[ "\$WARM" != "1" \]' "$CMD" \
   && grep -q 'error: --light is warm-only' "$CMD" \
   && grep -q 'Warm-only — not valid with a session uuid' "$CMD"; then ok
else bad "T1 static warm-only gate missing/broken in commands/handoff.md"; fi

# --light case arm sets both flags
if grep -qE -- '--light\)' "$CMD" \
   && awk '/--light\)/,/;;/' "$CMD" | grep -q 'HANDOFF_LIGHT=1' \
   && awk '/--light\)/,/;;/' "$CMD" | grep -q 'LIGHT=1'; then ok
else bad "T1b --light case arm must set HANDOFF_LIGHT=1 and LIGHT=1"; fi

# ---- T2: folded fence — cold uuid + --light → exit 1 ----
if [ -s "$FENCE_FILE" ] && grep -q 'LIGHT=1' "$FENCE_FILE"; then ok
else bad "T2a failed to extract Step 1 fence"; fi

run_parse "cold-uuid-abc --light"
if [ "$RC" -eq 1 ] && grep -q 'error: --light is warm-only' "$WORK/run.err"; then ok
else bad "T2 cold+--light must exit 1 with warm-only error rc=$RC err=$(head -c 200 "$WORK/run.err")"; fi

# order independence: --light before uuid also fails
run_parse "--light cold-uuid-xyz"
if [ "$RC" -eq 1 ] && grep -q 'error: --light is warm-only' "$WORK/run.err"; then ok
else bad "T2b --light before uuid must also fail rc=$RC err=$(head -c 160 "$WORK/run.err")"; fi

# ---- T3: warm --light alone passes gate (does not usage-fail); reaches the end ----
run_parse "--light"
if [ "$RC" -eq 0 ] \
   && grep -qF 'HANDOFF_MODE=warm' "$WORK/run.out" \
   && grep -qF 'HANDOFF_LIGHT=1' "$WORK/run.out" \
   && grep -qF 'SKIP_ANNOTATION=1' "$WORK/run.out"; then ok
else
  bad "T3 bare --light must pass gate as warm rc=$RC out=$(cat "$WORK/run.out") err=$(head -c 160 "$WORK/run.err")"
fi

# ---- T4: bare warm (no --light) defaults — not light knobs ----
run_parse ""
if [ "$RC" -eq 0 ] \
   && grep -qF 'HANDOFF_MODE=warm' "$WORK/run.out" \
   && grep -qF 'HANDOFF_LIGHT=0' "$WORK/run.out" \
   && grep -qF 'SKIP_ANNOTATION=0' "$WORK/run.out" \
   && grep -qF 'HANDOFF_MINER_MODEL= ' "$WORK/run.out" \
   && grep -qF 'HANDOFF_SPINE_TOKENS= ' "$WORK/run.out"; then ok
else
  bad "T4 bare warm must leave light knobs off/unset rc=$RC out=$(cat "$WORK/run.out") err=$(head -c 120 "$WORK/run.err")"
fi
T4_OUT=$(cat "$WORK/run.out")

# ---- AC1: --miner-model <alias> and --miner-model=<alias> export alias as given ----
run_parse "--miner-model balanced"
if [ "$RC" -eq 0 ] \
   && grep -qF 'HANDOFF_MODE=warm' "$WORK/run.out" \
   && grep -qF 'HANDOFF_MINER_MODEL=balanced' "$WORK/run.out"; then ok
else
  bad "AC1 space form --miner-model balanced rc=$RC out=$(cat "$WORK/run.out") err=$(head -c 160 "$WORK/run.err")"
fi

run_parse "--miner-model=fast"
if [ "$RC" -eq 0 ] \
   && grep -qF 'HANDOFF_MINER_MODEL=fast' "$WORK/run.out"; then ok
else
  bad "AC1 equals form --miner-model=fast rc=$RC out=$(cat "$WORK/run.out") err=$(head -c 160 "$WORK/run.err")"
fi

# ---- AC2: missing value → rc 1, exact stderr, no partial success ----
ERR_NEED='error: --miner-model requires a value'
for ac2_args in "--miner-model" "--miner-model=" "--miner-model --light"; do
  run_parse "$ac2_args"
  ac2_err=$(cat "$WORK/run.err")
  if [ "$RC" -eq 1 ] && [ "$ac2_err" = "$ERR_NEED" ]; then ok
  else
    bad "AC2 missing value ARGUMENTS='$ac2_args' rc=$RC err=$(head -c 200 "$WORK/run.err") out=$(head -c 120 "$WORK/run.out")"
  fi
done

# ---- AC3: flag + --light (either order) → light knobs + miner=fast; --light alone still haiku ----
run_parse "--miner-model fast --light"
if [ "$RC" -eq 0 ] \
   && grep -qF 'HANDOFF_MODE=warm' "$WORK/run.out" \
   && grep -qF 'HANDOFF_LIGHT=1' "$WORK/run.out" \
   && grep -qF 'HANDOFF_MINER_MODEL=fast' "$WORK/run.out"; then ok
else
  bad "AC3 --miner-model fast --light rc=$RC out=$(cat "$WORK/run.out") err=$(head -c 160 "$WORK/run.err")"
fi

run_parse "--light --miner-model fast"
if [ "$RC" -eq 0 ] \
   && grep -qF 'HANDOFF_LIGHT=1' "$WORK/run.out" \
   && grep -qF 'HANDOFF_MINER_MODEL=fast' "$WORK/run.out"; then ok
else
  bad "AC3 --light --miner-model fast rc=$RC out=$(cat "$WORK/run.out") err=$(head -c 160 "$WORK/run.err")"
fi

run_parse "--light"
if [ "$RC" -eq 0 ] \
   && grep -qF 'HANDOFF_MINER_MODEL=haiku' "$WORK/run.out"; then ok
else
  bad "AC3 --light alone must default miner haiku rc=$RC out=$(cat "$WORK/run.out") err=$(head -c 160 "$WORK/run.err")"
fi

# ---- AC4: flag > env; env preserved when no flag; T4 bare still unset ----
run_parse "--miner-model fast" "sonnet"
if [ "$RC" -eq 0 ] \
   && grep -qF 'HANDOFF_MINER_MODEL=fast' "$WORK/run.out"; then ok
else
  bad "AC4 env sonnet + --miner-model fast must export fast rc=$RC out=$(cat "$WORK/run.out") err=$(head -c 160 "$WORK/run.err")"
fi

run_parse "" "sonnet"
if [ "$RC" -eq 0 ] \
   && grep -qF 'HANDOFF_MINER_MODEL=sonnet' "$WORK/run.out"; then ok
else
  bad "AC4 env sonnet + no flag + no --light must keep sonnet rc=$RC out=$(cat "$WORK/run.out") err=$(head -c 160 "$WORK/run.err")"
fi

if printf '%s' "$T4_OUT" | grep -qF 'HANDOFF_MINER_MODEL= '; then ok
else
  bad "AC4 T4 bare must still leave MINER unset out=$T4_OUT"
fi

# ---- AC5: unknown alias is not a parse error (passthrough as given) ----
run_parse "--miner-model narnia"
if [ "$RC" -eq 0 ] \
   && grep -qF 'HANDOFF_MINER_MODEL=narnia' "$WORK/run.out" \
   && ! grep -qi 'error: --miner-model' "$WORK/run.err"; then ok
else
  bad "AC5 --miner-model narnia must parse/export as-is rc=$RC out=$(cat "$WORK/run.out") err=$(head -c 160 "$WORK/run.err")"
fi

# ---- T5: bare warm finalize still writes M8 cache (regression; finalize-test T25) ----
export HANDOFF_DIR="$WORK/handoff"
mkdir -p "$HANDOFF_DIR"
WARM_SID="light-gates-warm-reg"
set +e
# Explicitly clear light env so finalize cannot inherit from outer shell
env -u HANDOFF_LIGHT -u LIGHT bash "$PREPASS" finalize \
  --uuid "$WARM_SID" \
  --events "$THRASH" \
  --git-state "$GITBLOB" \
  --leaf "leaf-warm-reg-gates" \
  --slug warm-reg-gates \
  --mode warm \
  --packet-out "$WORK/warm-reg.md" \
  >"$WORK/t5.stdout" 2>"$WORK/t5.stderr"
RC=$?
set -e
WARM_CACHE="$HANDOFF_DIR/cache/${WARM_SID}.json"
if [ "$RC" -eq 0 ] && [ -f "$WORK/warm-reg.md" ] && [ -f "$WARM_CACHE" ] \
   && ! grep -qE 'light: true|light=1' "$WORK/warm-reg.md" 2>/dev/null \
   && ! grep -qiE 'light preset' "$WORK/warm-reg.md" 2>/dev/null; then ok
else
  bad "T5 bare warm cache regression rc=$RC packet=$([ -f "$WORK/warm-reg.md" ] && echo y || echo n) cache=$([ -f "$WARM_CACHE" ] && echo y || echo n) err=$(head -c 240 "$WORK/t5.stderr")"
fi

# Cache object must not be light-tagged (full write path)
if python3 - "$WARM_CACHE" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, encoding="utf-8") as fh:
    data = json.load(fh)
assert data.get("light") not in (True, 1, "true", "1"), data
assert "packet" in data or "events" in data or "leaf_uuid" in data, sorted(data)
print("ok")
PY
then ok
else bad "T5b cache JSON must be full (non-light) write"; fi

echo
echo "light-gates-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
