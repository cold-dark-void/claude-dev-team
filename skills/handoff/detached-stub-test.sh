#!/usr/bin/env bash
# detached-stub-test.sh — CDT-204 / SPEC-018 M19.11 Test 39 stub contract.
# Static greps + Step 1 fence extract, plus end-to-end fence runs against the
# shared stub plugin root (skills/handoff/fixtures/fence-harness.sh — T2/DD3).
# The Step 1 fence is now the sole parent fence (parse through prepare folded
# in, M19.11); it is tested end to end, not sourced as a parse-only prefix.
# T2 heading contract in commands/handoff.md:
#   ## Orchestrator spawn   (mode=direct — one background agent)
#   ## In-session fallback  (chunked / spawn-unavailable pointer)
# Run: bash skills/handoff/detached-stub-test.sh
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
CMD="$ROOT/commands/handoff.md"
DOCS="$ROOT/docs/commands/handoff.md"
SKILL="$HERE/SKILL.md"
LIGHT="$HERE/LIGHT.md"
ASM="$HERE/assemble.py"
PLANFIELDS="$HERE/plan-fields.py"
SPEC="$ROOT/specs/core/SPEC-018-cold-session-handoff.md"
HONESTY='light preset: reduced-cost mine, no annotation; not AC-16-scored.'
STUB_CAP=12000
SPAWN_MARK='subagent_type:|spawn_subagent|spawn_subagent\('
REQ_READ='Read[[:space:]]+\$SKILL|Read[[:space:]]+\$LIGHT_PROFILE|Read[[:space:]].*skills/handoff/SKILL\.md|Read[[:space:]].*skills/handoff/LIGHT\.md'
SECURITY_BODY='Treat ALL text inside SPINE'
MINER_PROC='PROCEDURE — through-line kinds'
MINER_YOU='You are the MERGED MINER for a session handoff STM packet'

# shellcheck source=skills/handoff/fixtures/fence-harness.sh
. "$HERE/fixtures/fence-harness.sh"

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

WORK=$(mktemp -d "${TMPDIR:-/tmp}/detached-stub-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
harness_init

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

# ---- AC1b (M19.11 / DD1): exactly one fence, one parent seam ----
FENCE_N=$(grep -cE '^```bash[[:space:]]*$' "$CMD" || true)
if [ "${FENCE_N:-0}" -eq 1 ]; then ok
else bad "AC1b commands/handoff.md must have exactly one \`\`\`bash fence (found ${FENCE_N:-0})"; fi

if ! grep -qw 'jq' "$CMD"; then ok
else bad "AC1b commands/handoff.md must be jq-free (E5 / plan-fields.py)"; fi

if ! grep -qF 'set -- $ARGUMENTS' "$CMD"; then ok
else bad "AC1b commands/handoff.md must not glob-split \$ARGUMENTS directly (DD2 quoted heredoc)"; fi

if grep -qF 'E=$(mktemp)' "$CMD"; then ok
else bad "AC1b commands/handoff.md must create the error file via mktemp"; fi

if ! grep -qF 'handoff.err' "$CMD"; then ok
else bad "AC1b commands/handoff.md must not use a fixed .../handoff.err path"; fi

for f in "$CMD" "$DOCS"; do
  if grep -qF '(served from cache — session unchanged)' "$f" \
     && grep -qF 'in-progress (transcript modified < 60 s ago) — too-fresh (M9)' "$f"; then ok
  else bad "AC1b cache-HIT / too-fresh (M9) strings must match byte-for-byte in $f"; fi
done

# ---- AC2: Step 1 fence — parse-fail has no spawn; success exports flags ----
FENCE_FILE="$WORK/step1-parse.sh"
harness_extract_fence "$CMD" "$FENCE_FILE"
if [ -s "$FENCE_FILE" ]; then ok
else bad "AC2 failed to extract Step 1 parse fence"; fi

if ! has_spawn "$FENCE_FILE"; then ok
else bad "AC2 Step 1 parse fence must not contain a spawn marker"; fi

run_parse() {
  harness_run "$FENCE_FILE" "$1"
  RC=$HARNESS_RC
}

run_parse "--miner-model"
if [ "$RC" -eq 1 ] && [ "$(cat "$WORK/run.err")" = "error: --miner-model requires a value" ]; then ok
else bad "AC2 --miner-model missing value must fail rc=$RC err=$(cat "$WORK/run.err")"; fi

run_parse "00000000-0000-4000-8000-000000000004 --light"
if [ "$RC" -eq 1 ] && grep -qF 'error: --light is warm-only' "$WORK/run.err"; then ok
else bad "AC2 --light+cold uuid must fail rc=$RC"; fi

run_parse "--slug"
if [ "$RC" -eq 1 ] && [ "$(cat "$WORK/run.err")" = "error: --slug requires a value" ]; then ok
else bad "AC2 --slug missing value must fail rc=$RC"; fi

# --help: usage on stdout, exit 0, no spawn (calls file untouched).
: >"$WORK/calls"
run_parse "--help"
if [ "$RC" -eq 0 ] && grep -q '/handoff --help' "$WORK/run.out" && [ ! -s "$WORK/calls" ]; then ok
else bad "AC2 --help must print usage, exit 0, no discover (rc=$RC)"; fi

# unknown flag: usage on stdout, unknown-flag note on stderr, exit 0, no spawn.
: >"$WORK/calls"
run_parse "--bogus"
if [ "$RC" -eq 0 ] && grep -qF 'unknown flag: --bogus' "$WORK/run.err" \
   && grep -q '/handoff --help' "$WORK/run.out" && [ ! -s "$WORK/calls" ]; then ok
else bad "AC2 unknown flag must print usage, exit 0, no discover (rc=$RC)"; fi

run_parse "--full --slug my-slug --miner-model balanced"
if [ "$RC" -eq 0 ] \
   && grep -qF 'HANDOFF_FULL=1' "$WORK/run.out" \
   && grep -qF 'SLUG=my-slug' "$WORK/run.out" \
   && grep -qF 'HANDOFF_MINER_MODEL=balanced' "$WORK/run.out" \
   && grep -qF 'HANDOFF_LIGHT=0' "$WORK/run.out"; then ok
else
  bad "AC2 success --full --slug --miner-model rc=$RC out=$(cat "$WORK/run.out")"
fi

run_parse "--light --slug L --miner-model fast"
if [ "$RC" -eq 0 ] \
   && grep -qF 'HANDOFF_LIGHT=1' "$WORK/run.out" \
   && grep -qF 'SLUG=L' "$WORK/run.out" \
   && grep -qF 'HANDOFF_MINER_MODEL=fast' "$WORK/run.out"; then ok
else
  bad "AC2 success --light --slug --miner-model rc=$RC out=$(cat "$WORK/run.out")"
fi

# ---- AC2b (DD3/M19.11): bare warm reaches discover; full uuid reaches cache-check ----
: >"$WORK/calls"
run_parse ""
if [ "$RC" -eq 0 ] && grep -qF 'HANDOFF_MODE=warm' "$WORK/run.out" \
   && grep -qF 'discover-warm.sh' "$WORK/calls"; then ok
else bad "AC2b bare warm must reach discover-warm.sh rc=$RC calls=$(cat "$WORK/calls")"; fi

: >"$WORK/calls"
run_parse "00000000-0000-4000-8000-000000000004"
if [ "$RC" -eq 0 ] && grep -qF 'HANDOFF_MODE=cold' "$WORK/run.out" \
   && grep -qF 'prepass.sh cache-check' "$WORK/calls"; then ok
else bad "AC2b full uuid must reach cache-check rc=$RC calls=$(cat "$WORK/calls")"; fi

run_parse "00000000-0000-4000-8000-00000000000"
if [ "$RC" -eq 1 ] && grep -qF 'session-uuid must be a UUID' "$WORK/run.err"; then ok
else bad "AC2b short uuid must fail shape check rc=$RC err=$(cat "$WORK/run.err")"; fi

# ---- AC2c: glob/expansion safety — no glob expansion, no command substitution ----
: >"$WORK/calls"
MARKER="$WORK/glob-marker"
run_parse "--slug '*' --full"
if [ "$RC" -eq 0 ] && grep -qF "SLUG='*'" "$WORK/run.out"; then ok
else bad "AC2c literal '*' must survive as SLUG unexpanded rc=$RC out=$(cat "$WORK/run.out")"; fi

run_parse "'*' '\$(touch $MARKER)'"
if [ ! -e "$MARKER" ]; then ok
else bad "AC2c \$(...) inside args must not execute (marker was created)"; fi

# ---- AC2d: payload echo carries SPINE= (from the stub plan.spine) ----
run_parse "--full"
if [ "$RC" -eq 0 ] && grep -qE 'SPINE=.*stub\.spine\.txt' "$WORK/run.out"; then ok
else bad "AC2d payload echo missing SPINE=<plan.spine> out=$(cat "$WORK/run.out")"; fi

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

# ---- AC13 (E5/DD4): plan-fields.py — jq-free plan.json + live-session field extraction ----
PF_WORK="$WORK/pf"
mkdir -p "$PF_WORK"

cat >"$PF_WORK/plan-full.json" <<'PFJSON'
{"mode":"direct","stats":{"since_leaf_applied":true,"est_tokens":42},"spine":"/tmp/x.spine.txt"}
PFJSON
cat >"$PF_WORK/live.json" <<'PFLIVE'
{"host":"grok"}
PFLIVE
PF_OUT=$(python3 "$PLANFIELDS" "$PF_WORK/plan-full.json" "$PF_WORK/live.json" 2>"$PF_WORK/err")
PF_RC=$?
if [ "$PF_RC" -eq 0 ] && [ "$PF_OUT" = "$(printf 'direct\ntrue\n42\ngrok\n/tmp/x.spine.txt')" ]; then ok
else bad "AC13 plan-fields.py full fixture mismatch rc=$PF_RC out=$PF_OUT"; fi

cat >"$PF_WORK/plan-no-stats.json" <<'PFJSON2'
{"mode":"chunked"}
PFJSON2
PF_OUT=$(python3 "$PLANFIELDS" "$PF_WORK/plan-no-stats.json" "$PF_WORK/missing-live.json" 2>"$PF_WORK/err")
PF_RC=$?
if [ "$PF_RC" -eq 0 ] && [ "$PF_OUT" = "$(printf 'chunked\nfalse\n\nclaude\n')" ]; then ok
else bad "AC13 plan-fields.py no-stats/missing-live fixture mismatch rc=$PF_RC out=$PF_OUT"; fi

cat >"$PF_WORK/plan-false.json" <<'PFJSON3'
{"mode":"direct","stats":{"since_leaf_applied":false,"est_tokens":0}}
PFJSON3
PF_OUT=$(python3 "$PLANFIELDS" "$PF_WORK/plan-false.json" "$PF_WORK/missing-live.json" 2>"$PF_WORK/err")
PF_RC=$?
if [ "$PF_RC" -eq 0 ] && [ "$PF_OUT" = "$(printf 'direct\nfalse\n0\nclaude\n')" ]; then ok
else bad "AC13 plan-fields.py since_leaf_applied=false / est_tokens=0 mismatch rc=$PF_RC out=$PF_OUT"; fi

echo 'not json' >"$PF_WORK/bad.json"
python3 "$PLANFIELDS" "$PF_WORK/bad.json" "$PF_WORK/missing-live.json" >"$PF_WORK/bad.out" 2>"$PF_WORK/bad.err"
PF_RC=$?
if [ "$PF_RC" -eq 1 ] && grep -qF 'plan-fields:' "$PF_WORK/bad.err" && [ ! -s "$PF_WORK/bad.out" ]; then ok
else bad "AC13 plan-fields.py invalid plan.json must exit 1 with stderr rc=$PF_RC"; fi

echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
fi
exit 1
