#!/usr/bin/env bash
# light-gates-test.sh — CDT-91 T9c / SPEC-018 M10c test 31 + CDT-203 --miner-model parse
# Coverage:
#   (1) Cold + --light → usage fail (static gate in commands/handoff.md + fence extract)
#   (2) Bare warm finalize (no --light) still writes M8 cache (regression vs light skip)
#   (3) CDT-203 AC1–AC5: --miner-model parse/export (flag > env > light > inherit)
# Run: bash skills/handoff/light-gates-test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
CMD="$ROOT/commands/handoff.md"
PREPASS="$HERE/prepass.sh"
FIX="$HERE/fixtures"
THRASH="$FIX/events-thrash.json"
GITBLOB="$FIX/git-state.txt"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/light-gates-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# Extract first ```bash fence under "## Step 1: Parse arguments"
extract_step1_fence() {
  awk '
    /^## Step 1: Parse arguments/ { want=1; next }
    want && /^```bash[[:space:]]*$/ { on=1; next }
    on && /^```[[:space:]]*$/ { exit }
    on { print }
  ' "$CMD"
}

# Source Step 1 fence. $1=ARGUMENTS; $2=HANDOFF_MINER_MODEL env (omit = unset).
# RUN_PARSE_EXPECT_FAIL=1 → echo UNEXPECTED_PARSE_OK if fence does not exit.
# Sets RC; writes $WORK/p.out $WORK/p.err
run_parse() {
  local args="$1"
  local miner="${2-__UNSET__}"
  set +e
  (
    if [ "${RUN_PARSE_EXPECT_FAIL:-0}" = "1" ]; then set +e; else set -e; fi
    unset HANDOFF_FULL HANDOFF_LIGHT HANDOFF_MINER_MODEL HANDOFF_SPINE_TOKENS SKIP_ANNOTATION LIGHT WARM UUID 2>/dev/null || true
    if [ "$miner" != "__UNSET__" ]; then
      export HANDOFF_MINER_MODEL="$miner"
    fi
    ARGUMENTS="$args"
    # shellcheck disable=SC1090
    . "$FENCE_FILE"
    if [ "${RUN_PARSE_EXPECT_FAIL:-0}" = "1" ]; then
      echo "UNEXPECTED_PARSE_OK WARM=${WARM:-} LIGHT=${LIGHT:-} HANDOFF_MINER_MODEL=${HANDOFF_MINER_MODEL:-unset}"
    else
      echo "PARSE_OK WARM=${WARM:-} LIGHT=${LIGHT:-} HANDOFF_MINER_MODEL=${HANDOFF_MINER_MODEL:-unset}"
    fi
  ) >"$WORK/p.out" 2>"$WORK/p.err"
  RC=$?
  set -e
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

# ---- T2: extract Step 1 fence — cold uuid + --light → exit 1 ----
FENCE_FILE="$WORK/step1-parse.sh"
extract_step1_fence >"$FENCE_FILE"
if [ -s "$FENCE_FILE" ] && grep -q 'LIGHT=1' "$FENCE_FILE"; then ok
else bad "T2a failed to extract Step 1 parse fence"; fi

set +e
(
  set +e
  unset HANDOFF_FULL HANDOFF_LIGHT HANDOFF_MINER_MODEL HANDOFF_SPINE_TOKENS SKIP_ANNOTATION LIGHT WARM UUID 2>/dev/null || true
  ARGUMENTS="cold-uuid-abc --light"
  # shellcheck disable=SC1090
  . "$FENCE_FILE"
  echo "UNEXPECTED_PARSE_OK WARM=${WARM:-} LIGHT=${LIGHT:-}" 
) >"$WORK/t2.stdout" 2>"$WORK/t2.stderr"
RC=$?
set -e
if [ "$RC" -eq 1 ] \
   && grep -q 'error: --light is warm-only' "$WORK/t2.stderr" \
   && ! grep -q 'UNEXPECTED_PARSE_OK' "$WORK/t2.stdout"; then ok
else
  bad "T2 cold+--light must exit 1 with warm-only error rc=$RC out=$(head -c 120 "$WORK/t2.stdout") err=$(head -c 200 "$WORK/t2.stderr")"
fi

# order independence: --light before uuid also fails
set +e
(
  set +e
  unset HANDOFF_FULL HANDOFF_LIGHT 2>/dev/null || true
  ARGUMENTS="--light cold-uuid-xyz"
  # shellcheck disable=SC1090
  . "$FENCE_FILE"
  echo "UNEXPECTED_PARSE_OK"
) >"$WORK/t2b.stdout" 2>"$WORK/t2b.stderr"
RC=$?
set -e
if [ "$RC" -eq 1 ] && grep -q 'error: --light is warm-only' "$WORK/t2b.stderr"; then ok
else bad "T2b --light before uuid must also fail rc=$RC err=$(head -c 160 "$WORK/t2b.stderr")"; fi

# ---- T3: warm --light alone passes gate (does not usage-fail) ----
set +e
(
  set -e
  unset HANDOFF_FULL HANDOFF_LIGHT HANDOFF_MINER_MODEL HANDOFF_SPINE_TOKENS SKIP_ANNOTATION 2>/dev/null || true
  ARGUMENTS="--light"
  # shellcheck disable=SC1090
  . "$FENCE_FILE"
  echo "PARSE_OK WARM=$WARM LIGHT=$LIGHT HANDOFF_LIGHT=$HANDOFF_LIGHT SKIP_ANNOTATION=$SKIP_ANNOTATION"
) >"$WORK/t3.stdout" 2>"$WORK/t3.stderr"
RC=$?
set -e
if [ "$RC" -eq 0 ] \
   && grep -q 'PARSE_OK WARM=1 LIGHT=1 HANDOFF_LIGHT=1 SKIP_ANNOTATION=1' "$WORK/t3.stdout"; then ok
else
  bad "T3 bare --light must pass gate as warm rc=$RC out=$(cat "$WORK/t3.stdout") err=$(head -c 160 "$WORK/t3.stderr")"
fi

# ---- T4: bare warm (no --light) defaults — not light knobs ----
set +e
(
  set -e
  unset HANDOFF_FULL HANDOFF_LIGHT HANDOFF_MINER_MODEL HANDOFF_SPINE_TOKENS SKIP_ANNOTATION LIGHT 2>/dev/null || true
  ARGUMENTS=""
  # shellcheck disable=SC1090
  . "$FENCE_FILE"
  # After non-light branch: HANDOFF_LIGHT=0 LIGHT=0; spine/miner left unset (honor operator / prepass defaults)
  echo "BARE WARM=$WARM LIGHT=$LIGHT HANDOFF_LIGHT=$HANDOFF_LIGHT SKIP=${SKIP_ANNOTATION:-} MINER=${HANDOFF_MINER_MODEL:-unset} SPINE=${HANDOFF_SPINE_TOKENS:-unset}"
) >"$WORK/t4.stdout" 2>"$WORK/t4.stderr"
RC=$?
set -e
if [ "$RC" -eq 0 ] \
   && grep -q 'BARE WARM=1 LIGHT=0 HANDOFF_LIGHT=0 SKIP=0 MINER=unset SPINE=unset' "$WORK/t4.stdout"; then ok
else
  bad "T4 bare warm must leave light knobs off/unset rc=$RC out=$(cat "$WORK/t4.stdout") err=$(head -c 120 "$WORK/t4.stderr")"
fi

# ---- AC1: --miner-model <alias> and --miner-model=<alias> export alias as given ----
run_parse "--miner-model balanced"
if [ "$RC" -eq 0 ] \
   && grep -q 'PARSE_OK ' "$WORK/p.out" \
   && grep -q 'HANDOFF_MINER_MODEL=balanced' "$WORK/p.out"; then ok
else
  bad "AC1 space form --miner-model balanced rc=$RC out=$(cat "$WORK/p.out") err=$(head -c 160 "$WORK/p.err")"
fi

run_parse "--miner-model=fast"
if [ "$RC" -eq 0 ] \
   && grep -q 'HANDOFF_MINER_MODEL=fast' "$WORK/p.out"; then ok
else
  bad "AC1 equals form --miner-model=fast rc=$RC out=$(cat "$WORK/p.out") err=$(head -c 160 "$WORK/p.err")"
fi

# ---- AC2: missing value → rc 1, exact stderr, no UNEXPECTED_PARSE_OK ----
ERR_NEED='error: --miner-model requires a value'
for ac2_args in "--miner-model" "--miner-model=" "--miner-model --light"; do
  RUN_PARSE_EXPECT_FAIL=1 run_parse "$ac2_args"
  unset RUN_PARSE_EXPECT_FAIL
  ac2_err=$(cat "$WORK/p.err")
  if [ "$RC" -eq 1 ] \
     && [ "$ac2_err" = "$ERR_NEED" ] \
     && ! grep -q 'UNEXPECTED_PARSE_OK' "$WORK/p.out"; then ok
  else
    bad "AC2 missing value ARGUMENTS='$ac2_args' rc=$RC err=$(head -c 200 "$WORK/p.err") out=$(head -c 120 "$WORK/p.out")"
  fi
done

# ---- AC3: flag + --light (either order) → light knobs + miner=fast; --light alone still haiku ----
run_parse "--miner-model fast --light"
if [ "$RC" -eq 0 ] \
   && grep -q 'PARSE_OK WARM=1 LIGHT=1 HANDOFF_MINER_MODEL=fast' "$WORK/p.out"; then ok
else
  bad "AC3 --miner-model fast --light rc=$RC out=$(cat "$WORK/p.out") err=$(head -c 160 "$WORK/p.err")"
fi

run_parse "--light --miner-model fast"
if [ "$RC" -eq 0 ] \
   && grep -q 'PARSE_OK WARM=1 LIGHT=1 HANDOFF_MINER_MODEL=fast' "$WORK/p.out"; then ok
else
  bad "AC3 --light --miner-model fast rc=$RC out=$(cat "$WORK/p.out") err=$(head -c 160 "$WORK/p.err")"
fi

run_parse "--light"
if [ "$RC" -eq 0 ] \
   && grep -q 'HANDOFF_MINER_MODEL=haiku' "$WORK/p.out"; then ok
else
  bad "AC3 --light alone must default miner haiku rc=$RC out=$(cat "$WORK/p.out") err=$(head -c 160 "$WORK/p.err")"
fi

# ---- AC4: flag > env; env preserved when no flag; T4 bare still unset ----
run_parse "--miner-model fast" "sonnet"
if [ "$RC" -eq 0 ] \
   && grep -q 'HANDOFF_MINER_MODEL=fast' "$WORK/p.out"; then ok
else
  bad "AC4 env sonnet + --miner-model fast must export fast rc=$RC out=$(cat "$WORK/p.out") err=$(head -c 160 "$WORK/p.err")"
fi

run_parse "" "sonnet"
if [ "$RC" -eq 0 ] \
   && grep -q 'HANDOFF_MINER_MODEL=sonnet' "$WORK/p.out"; then ok
else
  bad "AC4 env sonnet + no flag + no --light must keep sonnet rc=$RC out=$(cat "$WORK/p.out") err=$(head -c 160 "$WORK/p.err")"
fi

if grep -q 'BARE WARM=1 LIGHT=0 HANDOFF_LIGHT=0 SKIP=0 MINER=unset SPINE=unset' "$WORK/t4.stdout"; then ok
else
  bad "AC4 T4 bare must still leave MINER=unset out=$(cat "$WORK/t4.stdout")"
fi

# ---- AC5: unknown alias is not a parse error (passthrough as given) ----
run_parse "--miner-model narnia"
if [ "$RC" -eq 0 ] \
   && grep -q 'HANDOFF_MINER_MODEL=narnia' "$WORK/p.out" \
   && ! grep -qi 'error: --miner-model' "$WORK/p.err"; then ok
else
  bad "AC5 --miner-model narnia must parse/export as-is rc=$RC out=$(cat "$WORK/p.out") err=$(head -c 160 "$WORK/p.err")"
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
