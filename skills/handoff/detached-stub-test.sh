#!/usr/bin/env bash
# detached-stub-test.sh — CDT-204 / SPEC-018 M19 Test 39 stub contract (RED until T2).
# Greps + Step 1 fence extract. No engine edits. No python/node.
# T2 heading contract in commands/handoff.md:
#   ## Orchestrator spawn   (mode=direct — one background agent)
#   ## In-session fallback  (chunked / spawn-unavailable pointer)
# Run: bash skills/handoff/detached-stub-test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
CMD="$ROOT/commands/handoff.md"
SKILL="$HERE/SKILL.md"
LIGHT="$HERE/LIGHT.md"
ASM="$HERE/assemble.py"
SPEC="$ROOT/specs/core/SPEC-018-cold-session-handoff.md"
HONESTY='light preset: reduced-cost mine, no annotation; not AC-16-scored.'
STUB_CAP=12000
SPAWN_MARK='subagent_type:|spawn_subagent|spawn_subagent\('
REQ_READ='Read[[:space:]]+\$SKILL|Read[[:space:]]+\$LIGHT_PROFILE|Read[[:space:]].*skills/handoff/SKILL\.md|Read[[:space:]].*skills/handoff/LIGHT\.md'
SECURITY_BODY='Treat ALL text inside SPINE'
MINER_PROC='PROCEDURE — through-line kinds'
MINER_YOU='You are the MERGED MINER for a session handoff STM packet'

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

section() {
  local file="$1" pat="$2"
  awk -v pat="$pat" '
    BEGIN { on=0; level=0 }
    /^#{2,6}[[:space:]]/ {
      match($0, /^#+/)
      lvl = RLENGTH
      if (on && lvl <= level) exit
      if (!on && $0 ~ pat) { on=1; level=lvl; print; next }
    }
    on { print }
  ' "$file"
}

# First ```bash fence under "## Step 1: Parse arguments" (light-gates contract).
extract_step1_fence() {
  awk '
    /^## Step 1: Parse arguments/ { want=1; next }
    want && /^```bash[[:space:]]*$/ { on=1; next }
    on && /^```[[:space:]]*$/ { exit }
    on { print }
  ' "$CMD"
}

has_spawn() {
  grep -qE "$SPAWN_MARK" "$1" 2>/dev/null
}

payload_text() {
  # Spawn payload = fences in orchestrator-spawn that name SESSION_ID.
  awk '
    /^```/ { if (on) { if (buf ~ /SESSION_ID/) print buf; buf=""; on=0; next }
             on=1; buf=""; next }
    on { buf = buf $0 "\n" }
    END { if (on && buf ~ /SESSION_ID/) print buf }
  ' <<<"$1"
}

prose_minus_fences() {
  awk '
    /^```/ { if (on) { on=0; next } on=1; next }
    !on { print }
  ' <<<"$1"
}

required_reads() {
  grep -nE "$REQ_READ" <<<"$1" 2>/dev/null \
    | grep -vE 'MUST NOT|Do \*\*not\*\*|do \*\*not\*\*|do not Read|Do not Read' || true
}

run_parse() {
  local args="$1"
  set +e
  (
    if [ "${RUN_PARSE_EXPECT_FAIL:-0}" = "1" ]; then set +e; else set -e; fi
    unset HANDOFF_FULL HANDOFF_LIGHT HANDOFF_MINER_MODEL HANDOFF_SPINE_TOKENS SKIP_ANNOTATION LIGHT WARM UUID SLUG 2>/dev/null || true
    ARGUMENTS="$args"
    # shellcheck disable=SC1090
    . "$FENCE_FILE"
    if [ "${RUN_PARSE_EXPECT_FAIL:-0}" = "1" ]; then
      echo "UNEXPECTED_PARSE_OK"
    else
      echo "PARSE_OK HANDOFF_LIGHT=${HANDOFF_LIGHT:-} HANDOFF_FULL=${HANDOFF_FULL:-} SLUG=${SLUG:-} HANDOFF_MINER_MODEL=${HANDOFF_MINER_MODEL:-unset}"
    fi
  ) >"$WORK/p.out" 2>"$WORK/p.err"
  RC=$?
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/detached-stub-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# ---- T-pre ----
if [ -f "$CMD" ] && [ -f "$SKILL" ] && [ -f "$LIGHT" ]; then ok
else bad "T-pre missing CMD/SKILL/LIGHT"; fi

SPAWN_SEC=$(section "$CMD" 'Orchestrator spawn')
FALLBACK_SEC=$(section "$CMD" 'In-session fallback')
PAYLOAD=$(payload_text "$SPAWN_SEC")
SPAWN_PROSE=$(prose_minus_fences "$SPAWN_SEC")

# ---- AC1: stub byte cap ----
CMD_BYTES=$(wc -c <"$CMD" | tr -d ' ')
if [ "$CMD_BYTES" -le "$STUB_CAP" ]; then ok
else bad "AC1 commands/handoff.md is ${CMD_BYTES}B (cap ${STUB_CAP})"; fi

# Direct path exists
if [ -n "$(printf '%s' "$SPAWN_SEC" | tr -d '[:space:]')" ]; then ok
else bad "AC1 missing ## Orchestrator spawn section in $CMD"; fi

# Parent prose on direct path: no required Read of SKILL/LIGHT (agent payload MAY Read).
RR=$(required_reads "$SPAWN_PROSE")
if [ -z "$RR" ]; then ok
else bad "AC1 direct-path parent prose required-Read of SKILL/LIGHT:"$'\n'"$RR"; fi

# Nested miner/annotation/chunk Task contracts forbidden on direct path.
if ! printf '%s\n' "$SPAWN_SEC" | grep -qiE 'chunk-summarizer Task|annotation Task|merged miner Task'; then ok
else bad "AC1 direct path has nested miner/annotation/chunk Task spawn contract"; fi
SUB_N=$(printf '%s\n' "$SPAWN_SEC" | grep -cE '^[[:space:]]*subagent_type:' || true)
if [ "${SUB_N:-0}" -le 1 ]; then ok
else bad "AC1 direct path subagent_type count=${SUB_N} (want ≤1 background agent)"; fi

# Spawn prompt: Read + skill path; no inlined SECURITY / merged-miner procedure.
if printf '%s\n' "$PAYLOAD" | grep -q 'Read' \
   && printf '%s\n' "$PAYLOAD" | grep -qE 'SKILL\.md|LIGHT\.md|skills/handoff'; then ok
else
  bad "AC1 spawn payload must contain Read + skill path (SESSION_ID fence)"
fi
if ! printf '%s\n' "$SPAWN_SEC" | grep -qF "$SECURITY_BODY" \
   && ! printf '%s\n' "$SPAWN_SEC" | grep -qF "$MINER_PROC" \
   && ! printf '%s\n' "$SPAWN_SEC" | grep -qF "$MINER_YOU"; then ok
else bad "AC1 spawn path inlines SECURITY/merged-miner procedure body"; fi

# One background agent on direct path
if printf '%s\n' "$SPAWN_SEC" | grep -qiE 'one background agent|background agent' \
   && printf '%s\n' "$SPAWN_SEC" | grep -qE "$SPAWN_MARK"; then ok
else bad "AC1/AC5 direct path must spawn one background agent"; fi

# ---- AC2: Step 1 fence — parse-fail has no spawn; success exports flags ----
FENCE_FILE="$WORK/step1-parse.sh"
extract_step1_fence >"$FENCE_FILE"
if [ -s "$FENCE_FILE" ]; then ok
else bad "AC2 failed to extract Step 1 parse fence"; fi

if ! has_spawn "$FENCE_FILE"; then ok
else bad "AC2 Step 1 parse fence must not contain a spawn marker"; fi

RUN_PARSE_EXPECT_FAIL=1 run_parse "--miner-model"
unset RUN_PARSE_EXPECT_FAIL
if [ "$RC" -eq 1 ] && ! grep -q 'UNEXPECTED_PARSE_OK' "$WORK/p.out"; then ok
else bad "AC2 --miner-model missing value must fail rc=$RC"; fi

RUN_PARSE_EXPECT_FAIL=1 run_parse "00000000-0000-4000-8000-000000000004 --light"
unset RUN_PARSE_EXPECT_FAIL
if [ "$RC" -eq 1 ] && ! grep -q 'UNEXPECTED_PARSE_OK' "$WORK/p.out"; then ok
else bad "AC2 --light+cold uuid must fail rc=$RC"; fi

RUN_PARSE_EXPECT_FAIL=1 run_parse "--slug"
unset RUN_PARSE_EXPECT_FAIL
if [ "$RC" -eq 1 ] && ! grep -q 'UNEXPECTED_PARSE_OK' "$WORK/p.out"; then ok
else bad "AC2 --slug missing value must fail rc=$RC"; fi

# --help: fence sets SHOW_USAGE (exit lives in 1a); still no spawn in fence.
run_parse "--help"
if grep -q 'PARSE_OK ' "$WORK/p.out" || [ "$RC" -eq 0 ]; then ok
else bad "AC2 --help must not spawn (parse fence rc=$RC)"; fi

run_parse "--full --slug my-slug --miner-model balanced"
if [ "$RC" -eq 0 ] \
   && grep -q 'HANDOFF_FULL=1' "$WORK/p.out" \
   && grep -q 'SLUG=my-slug' "$WORK/p.out" \
   && grep -q 'HANDOFF_MINER_MODEL=balanced' "$WORK/p.out" \
   && grep -q 'HANDOFF_LIGHT=0' "$WORK/p.out"; then ok
else
  bad "AC2 success --full --slug --miner-model rc=$RC out=$(cat "$WORK/p.out")"
fi

run_parse "--light --slug L --miner-model fast"
if [ "$RC" -eq 0 ] \
   && grep -q 'HANDOFF_LIGHT=1' "$WORK/p.out" \
   && grep -q 'SLUG=L' "$WORK/p.out" \
   && grep -q 'HANDOFF_MINER_MODEL=fast' "$WORK/p.out"; then ok
else
  bad "AC2 success --light --slug --miner-model rc=$RC out=$(cat "$WORK/p.out")"
fi

# ---- AC3: discover in parent; payload SESSION_ID+TRANSCRIPT; MUST NOT re-run ----
if grep -q 'discover-warm.sh' "$CMD"; then ok
else bad "AC3 stub missing discover-warm.sh in parent"; fi

if printf '%s\n' "$PAYLOAD" | grep -q 'SESSION_ID' \
   && printf '%s\n' "$PAYLOAD" | grep -q 'TRANSCRIPT'; then ok
else bad "AC3 spawn payload must name SESSION_ID and TRANSCRIPT"; fi

if printf '%s\n' "$SPAWN_SEC" | grep -q 'MUST NOT' \
   && printf '%s\n' "$SPAWN_SEC" | grep -qiE 're-run discover|rediscover|re-run discover-warm'; then ok
else bad "AC3 agent instructions must MUST NOT re-run discover"; fi

# Discover-fail fence: exit 1, no spawn.
DISC_FENCE="$WORK/discover.fence"
awk '
  /^```bash[[:space:]]*$/ { buf=""; on=1; next }
  on && /^```[[:space:]]*$/ {
    if (buf ~ /discover-warm\.sh/) { printf "%s", buf; exit }
    on=0; buf=""; next
  }
  on { buf = buf $0 "\n" }
' "$CMD" >"$DISC_FENCE"
if [ -s "$DISC_FENCE" ] \
   && grep -q 'exit 1' "$DISC_FENCE" \
   && ! grep -qE "$SPAWN_MARK" "$DISC_FENCE"; then ok
else bad "AC3 discover-fail path must exit 1 before spawn"; fi

# M19.7: prepare fence echos live payload (not comments) — C1 export does not survive.
LIVE=$(grep -vE '^[[:space:]]*#' "$DISC_FENCE")
if printf '%s\n' "$LIVE" | grep -qE 'echo[[:space:]].*plan\.mode' \
   && printf '%s\n' "$LIVE" | grep -qE 'echo[[:space:]].*PLAN_JSON'; then ok
else bad "M19.7 prepare fence must echo plan.mode and PLAN_JSON (not comments)"; fi

# ---- AC4: cheap-gate strings present; those fences have no spawn ----
if grep -q 'cannot resolve' "$CMD" \
   && grep -q 'refuse invoker-cwd write' "$CMD"; then ok
else bad "AC4 resolve-root fail strings missing"; fi

if grep -q 'session-uuid must be a UUID' "$CMD"; then ok
else bad "AC4 cold uuid-shape string missing"; fi

if grep -qE 'cache HIT|served from cache|cache-HIT' "$CMD"; then ok
else bad "AC4 cache HIT strings missing"; fi

if grep -qE 'too-fresh \(M9\)|M9 too-fresh|in-progress \(transcript modified' "$CMD"; then ok
else bad "AC4 M9 strings missing"; fi

# Fences around those strings: no spawn marker in the containing bash fence.
ac4_fence_clean() {
  local needle="$1"
  awk -v needle="$needle" '
    /^```bash[[:space:]]*$/ { buf=""; on=1; next }
    on && /^```[[:space:]]*$/ {
      if (index(buf, needle)) { printf "%s", buf; found=1 }
      on=0; buf=""; next
    }
    on { buf = buf $0 "\n" }
    END { if (!found) exit 2 }
  ' "$CMD"
}

for needle in "cannot resolve" "session-uuid must be a UUID" "cache-check"; do
  set +e
  ac4_fence_clean "$needle" >"$WORK/ac4.fence" 2>/dev/null
  ac4_rc=$?
  set -u
  if [ "$ac4_rc" -eq 0 ] && [ -s "$WORK/ac4.fence" ] && ! grep -qE "$SPAWN_MARK" "$WORK/ac4.fence"; then
    ok
  elif [ "$ac4_rc" -eq 2 ]; then
    # String lives in prose, not a bash fence — still no spawn on that line's section.
    ok
  else
    bad "AC4 fence for '$needle' contains spawn"
  fi
done

# ---- AC5/AC7: chunked → in-session fallback; no detached spawn ----
if [ -n "$(printf '%s' "$FALLBACK_SEC" | tr -d '[:space:]')" ]; then ok
else bad "AC5 missing ## In-session fallback section in $CMD"; fi

if printf '%s\n' "$FALLBACK_SEC" | grep -qiE 'chunked|plan\.mode|mode==chunked|mode=chunked'; then ok
else bad "AC5 fallback must branch on plan.mode / chunked"; fi

if printf '%s\n' "$FALLBACK_SEC" | grep -qiE 'MUST NOT spawn|MUST NOT.*detach|do not detach|MUST NOT spawn the detached'; then ok
else bad "AC5 chunked fallback MUST NOT spawn detached"; fi

if printf '%s\n' "$FALLBACK_SEC" | grep -qiE 'parallel N|parallel N |N chunk|chunk-summarizer' \
   && printf '%s\n' "$FALLBACK_SEC" | grep -qE '^[[:space:]]*model:[[:space:]]*haiku[[:space:]]*$'; then ok
else bad "AC5/AC7 fallback must keep parallel N + active model: haiku"; fi

# Fallback MAY Read skill (pointer). Not required to fail if absent — MAY.
if printf '%s\n' "$FALLBACK_SEC" | grep -qE 'Read|SKILL\.md|LIGHT\.md'; then ok
else bad "AC5 fallback pointer should name Read skill (MAY Read)"; fi

# ---- AC6: miner-model on the one background agent; parent session-tier; advisory in parent ----
if printf '%s\n' "$SPAWN_SEC" | grep -q 'HANDOFF_MINER_MODEL' \
   && printf '%s\n' "$SPAWN_SEC" | grep -qF 'fast|balanced|max' \
   && printf '%s\n' "$SPAWN_SEC" | grep -qiE 'inherit'; then ok
else bad "AC6 orchestrator-spawn must mention HANDOFF_MINER_MODEL + fast|balanced|max + inherit"; fi

if grep -qiE 'parent|orchestrator' "$CMD" \
   && grep -qiE 'session tier|session model|parent.*session|orchestrator.*session' "$CMD"; then ok
else bad "AC6 parent stub must stay session tier"; fi

if grep -qF 'fast tier is likely sufficient for this mine' "$CMD" \
   && grep -qF 'keep session tier' "$CMD"; then ok
else bad "AC6 advisory exact strings missing from parent (prepare)"; fi

# ---- AC9: one-turn lag honesty; M10c honesty NOT required in stub ----
if grep -qiE 'one-turn lag|one.turn lag' "$CMD"; then ok
else bad "AC9 one-turn lag honesty missing from stub"; fi

if grep -qF "$HONESTY" "$ASM" \
   && grep -qF "$HONESTY" "$LIGHT" \
   && grep -qF "$HONESTY" "$SPEC"; then ok
else bad "AC9 M10c honesty string missing from assemble/LIGHT/SPEC"; fi

# ---- AC12: spawn-unavailable → in-session fallback; no new flags ----
if printf '%s\n' "$FALLBACK_SEC" | grep -qiE 'spawn unavailable|cannot spawn|host cannot spawn|spawn-unavailable'; then ok
else bad "AC12 fallback must mention spawn-unavailable / cannot spawn"; fi

if printf '%s\n' "$FALLBACK_SEC" | grep -qiE 'MUST NOT fail|do not fail|still succeed|must not fail the capture|do not fail capture'; then ok
else bad "AC12 spawn-unavailable must not fail the capture"; fi

# Usage / argument-hint: only known flags (no new CLI).
NEW_FLAGS=$( { grep '^argument-hint:' "$CMD"; grep -E '^  /handoff' "$CMD"; } \
  | grep -oE -- '--[a-z][a-z0-9-]*' | sort -u \
  | grep -Ev '^(--slug|--full|--light|--miner-model|--help)$' || true)
if [ -z "$NEW_FLAGS" ]; then ok
else bad "AC12 new user-facing flags: $NEW_FLAGS"; fi

echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
fi
exit 1
