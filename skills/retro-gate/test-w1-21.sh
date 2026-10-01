#!/usr/bin/env bash
# test-w1-21.sh — W1-21 delta in commands/retro.md (freshness shell, trial
# short-circuit, per-file cap, Step 6d, printed-only SUGGESTED, gate cache).
# Drives the extracted fences. Headings: ### Step 2c: Apply filters,
# ### Step 3b: Gate each session, ### Step 6a: Short-circuit on empty input,
# ### Step 6c: Apply loop.
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
RETRO="$ROOT/commands/retro.md"
FRESHNESS="$ROOT/skills/transcript-parse/freshness.sh"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

unset GIT_DIR GIT_WORK_TREE
# shellcheck source=../../tests/lib/fence.sh
. "$ROOT/tests/lib/fence.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---- freshness: bash, so a dash-like sh cannot disable the 60s guard --------
DISC="$ROOT/skills/retro-gate/discover.sh"
[ -f "$DISC" ] && ok "discover.sh present" || bad "discover.sh present"
CALL=$(grep 'FRESHNESS" check' "$DISC" | head -1)
printf '%s\n' "$CALL" | grep -q 'bash "$FRESHNESS"' \
  && ok "Step 2c calls bash freshness" || bad "Step 2c freshness call: ${CALL:-missing}"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/sh" <<'EOF'
#!/bin/bash
exit 3
EOF
chmod +x "$TMP/bin/sh"
SRC="$TMP/in-progress.jsonl"
printf '%s\n' '{}' > "$SRC"
# touch is now; freshness.sh exits 9 for mtime < 60s
(
  PATH="$TMP/bin:$PATH"
  _src="$SRC"
  FRESHNESS="$FRESHNESS"
  eval "$CALL"
  echo $? > "$TMP/fresh.rc"
)
rc=$(cat "$TMP/fresh.rc")
[ "$rc" = "9" ] && ok "freshness guard fires while sh exits 3" || bad "freshness rc=$rc want 9"

# Bite: the same line under sh does not return 9.
SHCALL=$(printf '%s\n' "$CALL" | sed 's/bash "\$FRESHNESS"/sh "$FRESHNESS"/')
(
  PATH="$TMP/bin:$PATH"
  _src="$SRC"
  FRESHNESS="$FRESHNESS"
  eval "$SHCALL"
  echo $? > "$TMP/fresh-sh.rc"
)
rc=$(cat "$TMP/fresh-sh.rc")
[ "$rc" = "3" ] && ok "bite: sh freshness does not fire the guard" || bad "bite sh rc=$rc want 3"

# ---- Step 6a: TRIAL_DECISIONS blocks the short-circuit ----------------------
F6A=$(fence_nth "$RETRO" '### Step 6a: Short-circuit on empty input' 1) || F6A=""
[ -n "$F6A" ] && ok "Step 6a fence extracts" || bad "Step 6a fence extracts"
REPO="$TMP/repo"
mkdir -p "$REPO"
env -u GIT_DIR -u GIT_WORK_TREE git -C "$REPO" init -q .
fence_exec "$TMP/trial" "$REPO" "$F6A" CLAUDE_PLUGIN_ROOT="$ROOT" \
  MODE=single AUTO=0 \
  CLASSIFIED_PROPOSALS= OBSERVATIONS= \
  TRIAL_DECISIONS="$(printf 'KEEP\tagent\ttext')"
if grep -q 'No actionable findings' "$TMP/trial.out"; then
  bad "trial decisions took the empty short-circuit"
else
  ok "trial decisions skip the empty short-circuit"
fi
fence_exec "$TMP/empty6" "$REPO" "$F6A" CLAUDE_PLUGIN_ROOT="$ROOT" \
  MODE=single AUTO=0 \
  CLASSIFIED_PROPOSALS= OBSERVATIONS= TRIAL_DECISIONS=
grep -q 'No actionable findings' "$TMP/empty6.out" \
  && ok "all-empty input still short-circuits" || bad "all-empty input did not short-circuit"
# Bite: drop TRIAL_DECISIONS from the blob and the trial row short-circuits.
MUT=$(printf '%s\n' "$F6A" | sed 's/\${TRIAL_DECISIONS:-}//')
fence_exec "$TMP/mut6" "$REPO" "$MUT" CLAUDE_PLUGIN_ROOT="$ROOT" \
  MODE=single AUTO=0 \
  CLASSIFIED_PROPOSALS= OBSERVATIONS= \
  TRIAL_DECISIONS="$(printf 'KEEP\tagent\ttext')"
grep -q 'No actionable findings' "$TMP/mut6.out" \
  && ok "bite: without TRIAL_DECISIONS the short-circuit returns" \
  || bad "bite: mutated short-circuit did not fire"

# ---- Step 3b: timeout 2 stops a slow gate; the cache stores a fast gate -----
GS="$ROOT/skills/retro-gate/gate-sessions.sh"
[ -f "$GS" ] && ok "gate-sessions.sh present" || bad "gate-sessions.sh present"
PLUG="$TMP/plug"
mkdir -p "$PLUG/skills/retro-gate"
cp "$ROOT/skills/plugin-dir.sh" "$PLUG/skills/plugin-dir.sh"
chmod +x "$PLUG/skills/plugin-dir.sh"
cat > "$PLUG/skills/retro-gate/gate.sh" <<'EOF'
#!/bin/bash
sleep 3
printf '%s\n' '{}'
EOF
chmod +x "$PLUG/skills/retro-gate/gate.sh"
SESS="$TMP/slow.jsonl"
printf '%s\n' '{}' > "$SESS"
start=$(date +%s%N)
GATE_SH="$PLUG/skills/retro-gate/gate.sh" MODE=all WHY=0 SESSIONS="$SESS" \
  GATE_CACHE="$TMP/cache-slow" bash "$GS" >"$TMP/slow.out" 2>"$TMP/slow.err"
end=$(date +%s%N)
ms=$(( (end - start) / 1000000 ))
if [ "$ms" -lt 2800 ]; then
  ok "per-file cap stops a 3s gate in ${ms}ms"
else
  bad "per-file cap took ${ms}ms (want < 2800)"
fi
grep -q 'gate timed out' "$TMP/slow.err" \
  && ok "timeout message is printed" || bad "timeout message missing"

cat > "$PLUG/skills/retro-gate/gate.sh" <<'EOF'
#!/bin/bash
printf '%s\n' 'MARKER-GATE-OUT'
EOF
chmod +x "$PLUG/skills/retro-gate/gate.sh"
mkdir -p "$TMP/cache-fast"
GATE_SH="$PLUG/skills/retro-gate/gate.sh" MODE=all WHY=0 SESSIONS="$SESS" \
  GATE_CACHE="$TMP/cache-fast" bash "$GS" >"$TMP/fast.out" 2>"$TMP/fast.err"
sid=$(basename "$SESS" .jsonl)
if [ -f "$TMP/cache-fast/$sid.out" ] && grep -q 'MARKER-GATE-OUT' "$TMP/cache-fast/$sid.out"; then
  ok "Step 3b stores gate stdout in GATE_CACHE"
else
  bad "Step 3b did not store gate stdout"
fi

# Step 4c reads the cache. It does not run gate.sh again.
F4C=$(fence_nth "$RETRO" '### Step 4c: Spawn subagents' 1) || F4C=""
[ -n "$F4C" ] && ok "Step 4c fence extracts" || bad "Step 4c fence extracts"
if printf '%s\n' "$F4C" | grep -q 'bash "$GATE_SH"'; then
  bad "Step 4c still runs gate.sh"
else
  ok "Step 4c does not run gate.sh"
fi
mkdir -p "$TMP/cache-4c"
printf '%s\n' 'MARKER-4C' > "$TMP/cache-4c/slow.out"
printf '%s\nprintf "%%s\\n" "$FRICTION_SIGNALS_JSON"\n' "$F4C" > "$TMP/4c.sh"
got=$(cd "$REPO" && env -u GIT_DIR -u GIT_WORK_TREE \
  GATE_CACHE="$TMP/cache-4c" JSONL="$TMP/slow.jsonl" ANCHOR_IDS= \
  bash "$TMP/4c.sh" | tail -1)
[ "$got" = "MARKER-4C" ] && ok "Step 4c reads the Step 3b cache" || bad "Step 4c cache read got ${got:-empty}"

# Step 4b reads the cache. It does not run gate.sh again.
# shellcheck source=../../tests/lib/fence.sh
SEC4=$(md_section "$RETRO" '### Step 4b: Build per-session Task inputs')
printf '%s\n' "$SEC4" | grep -q 'GATE_CACHE' \
  && ok "Step 4b names GATE_CACHE" || bad "Step 4b does not name GATE_CACHE"
if printf '%s\n' "$SEC4" | grep -q 'bash "$GATE_SH"'; then
  bad "Step 4b still re-runs gate.sh"
else
  ok "Step 4b does not re-run gate.sh"
fi

# ---- Step 6d reference ------------------------------------------------------
SEC6B=$(md_section "$RETRO" '### Step 6b: Separate DUPLICATE')
printf '%s\n' "$SEC6B" | grep -q 'see Step 6d' \
  && ok "duplicates point at Step 6d" || bad "duplicates do not point at Step 6d"
if printf '%s\n' "$SEC6B" | grep -q 'see Step 6f'; then
  bad "duplicates still point at Step 6f"
else
  ok "duplicates do not point at Step 6f"
fi
grep -q '### Step 6d:' "$RETRO" && ok "Step 6d heading exists" || bad "Step 6d heading missing"

# ---- printed-only suggestions increment SUGGESTED, not APPLIED --------------
n=1
SUG_FENCE=""
while true; do
  if ! one=$(fence_nth "$RETRO" '### Step 6c: Apply loop' "$n"); then
    break
  fi
  if printf '%s\n' "$one" | grep -q 'SUGGESTED=\$(( \${SUGGESTED:-0} + 1 ))'; then
    SUG_FENCE=$one
    break
  fi
  n=$((n + 1))
done
[ -n "$SUG_FENCE" ] && ok "Step 6c fence increments SUGGESTED" || bad "Step 6c fence increments SUGGESTED"
if [ -n "$SUG_FENCE" ]; then
  printf '%s\nprintf "%%s\\n" "${SUGGESTED:-0}"\n' "$SUG_FENCE" > "$TMP/sug.sh"
  got=$(MROOT="$TMP" bash "$TMP/sug.sh" | tail -1)
  [ "$got" = "1" ] && ok "printed suggestion counts as 1 suggested" || bad "suggested count=$got"
fi

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
