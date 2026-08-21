#!/usr/bin/env bash
# spawn-model-ac-test.sh — CDT-90 / CDT-203 / CDT-204 static contract for SPEC-018 M3e.
# CDT-204: T0/T1/AC7e → CMD in-session fallback + SKILL; T3/AC7a–c → orchestrator-spawn.
# Greps committed prompt/docs only (no network, no LLM, no cost metrics).
# Run: bash skills/handoff/spawn-model-ac-test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
CMD="$ROOT/commands/handoff.md"
SKILL="$HERE/SKILL.md"
LIGHT="$HERE/LIGHT.md"
PREPASS="$HERE/prepass.sh"
SPEC="$ROOT/specs/core/SPEC-018-cold-session-handoff.md"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

# Extract markdown section starting at first heading matching pat; stop at next
# heading of equal or higher level. Only ##+ count as headings (single-# is
# bash comment noise inside fences).
# Args: file, awk-regex for the start heading line
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

has_active_haiku() {
  grep -E '^[[:space:]]*model:[[:space:]]*haiku[[:space:]]*$' "$1" >/dev/null 2>&1
}

# ---- fixtures present ----
if [ -f "$CMD" ] && [ -f "$SKILL" ] && [ -f "$PREPASS" ]; then ok
else bad "T-pre missing CMD/SKILL/PREPASS"; fi

# T2 heading contract (CDT-204): CMD in-session fallback pointer + orchestrator-spawn.
#   ## In-session fallback  — chunk/annotation model: haiku (T0/T1/T8/AC7e)
#   ## Orchestrator spawn   — background agent model: (T3/AC7a–c)
FALLBACK=$(section "$CMD" 'In-session fallback')
SPAWN_SEC=$(section "$CMD" 'Orchestrator spawn')

# ---- T0: CMD in-session fallback / chunk-summarizer pins model: haiku ----
if printf '%s\n' "$FALLBACK" | grep -qE 'chunk-summarizer|chunked' \
  && printf '%s\n' "$FALLBACK" | grep -qE '^[[:space:]]*model:[[:space:]]*haiku[[:space:]]*$'; then
  ok
else
  bad "T0 in-session fallback missing active model: haiku (chunk) in $CMD"
fi

# ---- T1: CMD in-session fallback / annotation pins model: haiku ----
if printf '%s\n' "$FALLBACK" | grep -qiE 'annotation' \
  && printf '%s\n' "$FALLBACK" | grep -qE '^[[:space:]]*model:[[:space:]]*haiku[[:space:]]*$'; then
  ok
else
  bad "T1 in-session fallback missing active model: haiku (annotation) in $CMD"
fi

# ---- T2: SKILL.md ≥2 active model: haiku (chunk + annotation spawn contracts) ----
HAIKU_N=$(grep -cE '^[[:space:]]*model:[[:space:]]*haiku[[:space:]]*$' "$SKILL" || true)
CHUNK_SEC=$(section "$SKILL" '^## Chunk-Summarizer')
ANN_SEC=$(section "$SKILL" '^## Annotation pass')
if [ "${HAIKU_N:-0}" -ge 2 ] \
  && printf '%s\n' "$CHUNK_SEC" | grep -qE '^[[:space:]]*model:[[:space:]]*haiku' \
  && printf '%s\n' "$ANN_SEC" | grep -qE '^[[:space:]]*model:[[:space:]]*haiku'; then
  ok
else
  bad "T2 SKILL.md need ≥2 active model: haiku near chunk+annotation (count=${HAIKU_N:-0})"
fi

# ---- T3: miner inherits; HANDOFF_MINER_MODEL opt-in; no unconditional haiku ----
# CMD home is orchestrator-spawn (background agent model:), not Step 6 miner Task.
if printf '%s\n' "$SPAWN_SEC" | grep -q 'HANDOFF_MINER_MODEL' \
  && printf '%s\n' "$SPAWN_SEC" | grep -qiE 'inherit' \
  && ! printf '%s\n' "$SPAWN_SEC" | grep -qE '^[[:space:]]*model:[[:space:]]*haiku[[:space:]]*$'; then
  ok
else
  bad "T3 orchestrator-spawn must document HANDOFF_MINER_MODEL + inherit; no active model: haiku default"
fi

if grep -q 'HANDOFF_MINER_MODEL' "$SKILL" \
  && grep -qiE 'inherit session|omit `model`|omit model' "$SKILL"; then
  ok
else
  bad "T3 SKILL.md missing HANDOFF_MINER_MODEL / inherit language"
fi

MINER_BLOCK=$(section "$SKILL" '^## Merged miner')
if ! printf '%s\n' "$MINER_BLOCK" | grep -qE '^[[:space:]]*model:[[:space:]]*haiku[[:space:]]*$'; then
  ok
else
  bad "T3 SKILL merged-miner block has unconditional model: haiku (must inherit / env-only)"
fi

# ---- T4: tier aliases only — no dated model ID pins in handoff spawn docs ----
PIN_HITS=$(grep -nE 'claude-[a-z0-9-]*-20[0-9]{2}|claude-3-5|claude-3\.5' \
  "$CMD" "$SKILL" 2>/dev/null || true)
if [ -z "$PIN_HITS" ]; then
  ok
else
  bad "T4 dated model pin in handoff docs:"$'\n'"$PIN_HITS"
fi

# ---- T5: parent/orchestrator stays session tier (not forced haiku) ----
if grep -qiE 'parent|orchestrator' "$CMD" \
  && grep -qiE 'session tier|session model|parent.*session|orchestrator.*session' "$CMD"; then
  ok
else
  bad "T5 commands/handoff.md missing parent/orchestrator session-tier language"
fi

if [ -f "$SPEC" ] && grep -q 'M3e' "$SPEC" \
  && grep -qiE 'parent|orchestrator' "$SPEC" \
  && grep -qiE 'session tier|MUST NOT force haiku' "$SPEC"; then
  ok
else
  if [ -f "$SPEC" ]; then
    bad "T5 SPEC-018 M3e missing parent session-tier / no-force-haiku language"
  else
    bad "T5 SPEC-018 missing at $SPEC"
  fi
fi

# ---- T6: HANDOFF_SPINE_TOKENS default remains 120000 in prepass.sh ----
if grep -qE 'HANDOFF_SPINE_TOKENS="\$\{HANDOFF_SPINE_TOKENS:-120000\}"' "$PREPASS" \
  && grep -qE 'get\("HANDOFF_SPINE_TOKENS", "120000"\)' "$PREPASS"; then
  ok
else
  bad "T6 prepass.sh HANDOFF_SPINE_TOKENS default not 120000 (shell + python)"
fi

# ---- T7 (optional contract): SPEC-018 M3e + HANDOFF_MINER_MODEL ----
if [ -f "$SPEC" ] \
  && grep -q 'M3e' "$SPEC" \
  && grep -q 'HANDOFF_MINER_MODEL' "$SPEC" \
  && grep -q 'model: haiku' "$SPEC"; then
  ok
else
  bad "T7 SPEC-018 M3e contract incomplete (need M3e + HANDOFF_MINER_MODEL + model: haiku)"
fi

# ---- T8: cheap stages must not lose haiku (command+skill both pin) ----
if has_active_haiku "$CMD" && has_active_haiku "$SKILL"; then
  ok
else
  bad "T8 cheap stages lost model: haiku pin in CMD and/or SKILL"
fi

# ---- AC7: host-neutral fast|balanced|max at spawn (orchestrator-spawn + SKILL + LIGHT) ----
# Reuse SPAWN_SEC from T3; cheap-stage haiku pins must stay (T0/T1/T2/T8).
if [ -z "${SPAWN_SEC:-}" ]; then
  SPAWN_SEC=$(section "$CMD" 'Orchestrator spawn')
fi
if [ -f "$LIGHT" ] \
   && printf '%s\n' "$SPAWN_SEC" | grep -qF 'fast|balanced|max' \
   && grep -qF 'fast|balanced|max' "$SKILL" \
   && grep -qF 'fast|balanced|max' "$LIGHT"; then
  ok
else
  bad "AC7a orchestrator-spawn + SKILL + LIGHT must mention fast|balanced|max"
fi

# Claude: fast→haiku, balanced→sonnet, max inherit/omit (table in SKILL/LIGHT; spawn prose or cite)
if grep -qE '`fast`[[:space:]]*\|[[:space:]]*`haiku`' "$SKILL" \
   && grep -qE '`balanced`[[:space:]]*\|[[:space:]]*`sonnet`' "$SKILL" \
   && grep -qE '`max`[[:space:]]*\|[[:space:]]*inherit' "$SKILL" \
   && grep -qE '`fast`[[:space:]]*\|[[:space:]]*`haiku`' "$LIGHT" \
   && grep -qE '`balanced`[[:space:]]*\|[[:space:]]*`sonnet`' "$LIGHT" \
   && grep -qE '`max`[[:space:]]*\|[[:space:]]*inherit' "$LIGHT" \
   && printf '%s\n' "$SPAWN_SEC" | grep -qE 'fast[[:space:]]*(→|->)[[:space:]]*`?haiku`?|`fast`[[:space:]]*\|[[:space:]]*`haiku`' \
   && printf '%s\n' "$SPAWN_SEC" | grep -qE 'balanced[[:space:]]*(→|->)[[:space:]]*`?sonnet`?|`balanced`[[:space:]]*\|[[:space:]]*`sonnet`' \
   && printf '%s\n' "$SPAWN_SEC" | grep -qiE 'max.*(inherit|omit)|omit.*max'; then
  ok
else
  bad "AC7b Claude map missing (fast→haiku, balanced→sonnet, max inherit/omit) in orchestrator-spawn/SKILL/LIGHT"
fi

# Grok identity (fast→fast); passthrough; fail-soft inherit
if grep -qE '`fast` \(identity\)' "$SKILL" \
   && grep -qE '`fast` \(identity\)' "$LIGHT" \
   && printf '%s\n' "$SPAWN_SEC" | grep -qiE 'identity|fast[[:space:]]*(→|->)[[:space:]]*`?fast`?' \
   && grep -qiE 'passthrough|pass-through|pass as-is|pass through' "$SKILL" \
   && grep -qiE 'passthrough|pass-through|pass as-is|pass through' "$LIGHT" \
   && printf '%s\n' "$SPAWN_SEC" | grep -qiE 'passthrough|pass-through|pass as-is|pass through' \
   && grep -qi 'fail-soft' "$SKILL" \
   && grep -qi 'fail-soft' "$LIGHT" \
   && printf '%s\n' "$SPAWN_SEC" | grep -qi 'fail-soft'; then
  ok
else
  bad "AC7c Grok identity / passthrough / fail-soft inherit missing in orchestrator-spawn/SKILL/LIGHT"
fi

# No dated Grok/spark pins as Task model: values (prose "never pin" mentions OK)
PIN_GROK=$(grep -nE '^[[:space:]]*model:[[:space:]]*(spark-llama|grok-4)' \
  "$CMD" "$SKILL" "$LIGHT" 2>/dev/null || true)
if [ -z "$PIN_GROK" ]; then
  ok
else
  bad "AC7d spark-llama / grok-4 dated pin as model:"$'\n'"$PIN_GROK"
fi

if has_active_haiku "$CMD" && has_active_haiku "$SKILL" \
   && printf '%s\n' "$FALLBACK" | grep -qE '^[[:space:]]*model:[[:space:]]*haiku'; then
  ok
else
  bad "AC7e chunk/annotation must keep active model: haiku on in-session fallback + SKILL (T0/T1/T2/T8 lock)"
fi

# ---- AC8: advisory after successful prepare (print-only; exact lines + skip) ----
# Live printer: non-comment echo/print( of both exact strings (comments do not count).
if grep -vE '^[[:space:]]*#' "$CMD" | grep -F 'fast tier is likely sufficient for this mine' | grep -qE 'echo|print\(' \
   && grep -vE '^[[:space:]]*#' "$CMD" | grep -F 'keep session tier' | grep -qE 'echo|print\('; then
  ok
else
  bad "AC8a commands/handoff.md missing live echo/print of exact advisory strings"
fi

if grep -q '30000' "$CMD" \
   && grep -q 'est_tokens' "$CMD" \
   && grep -q 'mode==direct' "$CMD" \
   && grep -q 'chunked' "$CMD"; then
  ok
else
  bad "AC8b commands/handoff.md must mention 30000 / est_tokens / mode==direct / chunked"
fi

if grep -qiE 'prepare fail|prepare failed' "$CMD" \
   && grep -qiE 'missing.*token|tokens missing|non-numeric' "$CMD" \
   && grep -qE 'cache-HIT' "$CMD"; then
  ok
else
  bad "AC8c commands/handoff.md missing no-advisory conditions (prepare fail / missing tokens / cache-HIT)"
fi

echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
fi
exit 1
