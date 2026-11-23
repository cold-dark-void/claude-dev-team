#!/usr/bin/env bash
#
# council/test-waves.sh — SPEC-013 CDT-594 (waves[] — the mechanical wave plan)
#
# Sections 1-4 are the seed (commit 5d40e20): the invariants that held BEFORE
# the emitter landed — the unbounded path, the single cap carrier, the
# Workflow-path carve-out, and the CDT-594 AC-block grammar. Sections 5-12 are
# the T1 engine surface: the waves-lib partition arithmetic, the slot audit,
# the `engine.sh waves` emitter (merge, determinism, idempotence, the seven
# fail-closed inputs), preflight emission coverage, the blind form, and
# `--why`. Section 13 is the T2 finalize Phase-2-only count check (AC18).
#
# Sections 14-19 are the T6 extension (SPEC-013 Test 28, plan CDT-594 T6): the
# AC10 M14 PREFLIGHT fixture (14 technical ACs × 2 flavors at cap 4 — 7 batches
# of 4), the emitter on a waves_pending plan with the phase2.5 slot audit, the
# slice invariants (contiguity, disjointness, cap 1, unbounded caps), the
# one-carrier cases (env and Model map are never a cap source for the emitter)
# and the AC1/AC13 byte-identity pins, the AC16 prose pins, and the finalize
# count-check cases § 13 does not cover.
#
# The AC10 fixture: m14-ac-split.sh case 1 reads the AC source at HEAD from a
# path inside the worktree, so the 14-technical-AC spec is generated into the
# disposable repo and committed there. No committed fixture fork: the file
# lives under $TMPDIR only (SPEC-030 R9), and the committed
# skills/council/fixtures/m14-split/ specs (2 technical ACs) stay the C1/C2
# shape fixtures.
#
# Neighbours, deliberately not repeated here: skills/council/test-concurrency.sh
# owns cap resolution, the fail-closed flag matrix, the contract line, and the
# report frontmatter; skills/lib/chunked-parallel-test.sh owns the chunk helper;
# skills/council/test-parity-fixtures.sh owns Task-vs-Workflow parity;
# skills/orchestrate/router-static-test.sh owns the gated-site prose (§ AC12).
#
# Machine-check: bash skills/council/test-waves.sh   (exit 0)
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="$ROOT/skills/council/engine.sh"
SPEC="$ROOT/specs/core/SPEC-013-adversarial-council-tribunal.md"
WFJS="$ROOT/skills/council/workflow.js"

# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
hermetic_init

TMP="$(mktemp -d "${TMPDIR:-/tmp}/waves-test.XXXXXX")"
trap 'rm -rf "$TMP"; hermetic_cleanup' EXIT

REPO="$TMP/repo"
mkdir -p "$REPO"
git init -q "$REPO"
MAP="$REPO/.claude/dev-team/models.local.json"
rm -f "$MAP"

fail=0
ok()  { echo "OK: $1"; }
bad() { echo "FAIL: $1" >&2; fail=1; }
want() {  # want <label> <want> <got>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$2' got '$3')"; fi
}

# ---- plan <preflight args...> -----------------------------------------------
# Runs in the disposable repo so the engine state dir and the Model map stay
# ours. COUNCIL_CONCURRENCY is scrubbed unless CAP is set.
PLANF="$TMP/plan.json"
RC=0
plan() {
  : > "$PLANF"
  if [ -n "${CAP+x}" ]; then
    ( cd "$REPO" && env "COUNCIL_CONCURRENCY=$CAP" bash "$ENGINE" preflight "$@" ) > "$PLANF"
  else
    ( cd "$REPO" && env -u COUNCIL_CONCURRENCY bash "$ENGINE" preflight "$@" ) > "$PLANF"
  fi
  RC=$?
  return 0
}

expect_rc() { [ "$RC" -eq "$2" ] && ok "$1" || bad "$1 (exit $RC, want $2)"; }
expect_plan() {  # expect_plan <label> <jq-boolean-filter>
  if jq -e "$2" "$PLANF" >/dev/null 2>&1; then ok "$1"; else bad "$1 — plan: $(head -c 240 "$PLANF")"; fi
}
check_json() {  # check_json <label> <file> <jq-boolean-filter>
  if jq -e "$3" "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1 — $(head -c 240 "$2")"; fi
}

# ---- emitter harness --------------------------------------------------------
# The emitter is a subprocess CLI on the engine. COUNCIL_CONCURRENCY is scrubbed
# in the plan-file form (it reads plan.concurrency only) and set by CAP in the
# blind form's map-layer case.
EMF="$TMP/emitter-err.txt"
ERC=0
EOUT=""
waves_emit() {
  if [ -n "${CAP+x}" ]; then
    EOUT=$( cd "$REPO" && env "COUNCIL_CONCURRENCY=$CAP" bash "$ENGINE" waves "$@" 2>"$EMF" )
  else
    EOUT=$( cd "$REPO" && env -u COUNCIL_CONCURRENCY bash "$ENGINE" waves "$@" 2>"$EMF" )
  fi
  ERC=$?
  return 0
}
expect_erc() { [ "$ERC" -eq "$2" ] && ok "$1" || bad "$1 (exit $ERC, want $2; stderr: $(head -2 "$EMF" | tr '\n' ' '))"; }
sizes_of() { printf '%s' "$1" | jq -c '[.[].spawns | length]'; }

# ---- 1. Unset at every layer: no cap, no wave plan (AC1, unset half) --------
unset CAP
plan --scope claim --scope-arg "the engine emits nothing new when the cap is unset"
expect_rc "unset cap: preflight exit 0" 0
expect_plan "unset cap: plan has no concurrency key"        'has("concurrency") | not'
expect_plan "unset cap: plan has no waves key"              'has("waves") | not'
expect_plan "unset cap: plan has no waves_pending key"      'has("waves_pending") | not'
expect_plan "unset cap: no wave name appears in the plan bytes" \
  '[.. | strings | select(. == "phase2" or . == "phase2.5" or . == "phase2.5-wave")] | length == 0'

# ---- 2. Capped run: the cap stays on the one carrier, every scope accepted --
CAP=2
plan --scope claim --scope-arg "the cap rides one plan field"
expect_rc "capped claim scope: preflight exit 0" 0
expect_plan "capped claim scope: plan.concurrency == 2" '.concurrency == 2'
plan --scope diff
expect_rc "capped diff scope: preflight exit 0" 0
expect_plan "capped diff scope: plan.concurrency == 2" '.concurrency == 2'

# ---- 3. Workflow path stays out of the wave plan (AC15) ---------------------
if grep -qE 'waves|waves_pending' "$WFJS"; then
  bad "workflow.js reads the wave plan — it keeps chunkedParallel, not waves[] (AC15)"
else
  ok "workflow.js carries no waves[] consumer (AC15)"
fi

# ---- 4. CDT-594 AC-block grammar (SPEC-033 M14(g); the claim budget) --------
sec=$(awk '/^### CDT-594$/{f=1;next} f&&/^### /{exit} f&&/^---$/{exit} f&&/^## /{exit} f' "$SPEC")
bullets=$(printf '%s\n' "$sec" | grep -cE '^- \*\*AC[0-9]+\.\*\* ')
procn=$(printf '%s\n' "$sec" | grep -cE '^- \*\*AC[0-9]+\.\*\* \[process\] ')
verify=$(printf '%s\n' "$sec" | grep -cE '^  Verify: bash [A-Za-z0-9._/=:@%+,-]+( [A-Za-z0-9._/=:@%+,-]+)*$')
nonconf=$(printf '%s\n' "$sec" | grep -vE '^$|^(- \*\*AC|  Verify: bash )' | wc -l | tr -d ' ')
want "CDT-594 AC block holds 18 bullets" "18" "$bullets"
want "CDT-594 AC block holds 3 [process] ACs" "3" "$procn"
want "CDT-594 AC block: one Verify line per technical AC" "$((bullets - procn))" "$verify"
want "CDT-594 AC block: no line breaks the M14(g) grammar" "0" "$nonconf"
technical=$((bullets - procn))
if [ "$technical" -le 16 ]; then
  ok "CDT-594 technical AC count ($technical) is within M14_AC_BUDGET (16)"
else
  bad "CDT-594 technical AC count ($technical) exceeds M14_AC_BUDGET (16)"
fi

# ---- 5. Partition arithmetic (AC3) ------------------------------------------
# waves-lib.sh is the ONE partition home for the Task path and is a sourced
# function library by design (the CLI is engine.sh waves), so the suite sources
# it to test the arithmetic directly.
# shellcheck source=waves-lib.sh
. "$ROOT/skills/council/waves-lib.sh"

slotn() {  # slotn <W> — a W-slot phase2 slot array
  jq -nc "[range(0; $1) | {slot: ., claim_index: 0, claim_id: \"c0\", flavor: \"f\",
                           agent: \"finder\", model_pin_source: \"map\"}]"
}

W5=$(waves_partition phase2 2 "$(slotn 5)")
want "W=5 X=2: sizes 2,2,1" "[2,2,1]" "$(sizes_of "$W5")"
want "W=5 X=2: three objects" "3" "$(printf '%s' "$W5" | jq -c 'length')"
want "W=5 X=2: slot total == W" "5" "$(printf '%s' "$W5" | jq -c '[.[].spawns[]] | length')"
want "W=5 X=2: batches are 1-based contiguous" "[1,2,3]" "$(printf '%s' "$W5" | jq -c '[.[].batch]')"
want "W=5 X=2: every object carries the wave name" "true" \
  "$(printf '%s' "$W5" | jq -c 'all(.[]; .wave == "phase2")')"
W8=$(waves_partition phase2 4 "$(slotn 8)")
want "W=8 X=4: sizes 4,4" "[4,4]" "$(sizes_of "$W8")"
W3=$(waves_partition phase2 3 "$(slotn 3)")
want "W<=X (3 at 3): one object" "[3]" "$(sizes_of "$W3")"
W1=$(waves_partition phase2 4 "$(slotn 1)")
want "W<=X (1 at 4): one object" "[1]" "$(sizes_of "$W1")"
W7=$(waves_partition phase2 3 "$(slotn 7)")
want "W=7 X=3: partial last batch (3,3,1)" "[3,3,1]" "$(sizes_of "$W7")"
want "W=0: no wave object (spawns is never empty)" "[]" "$(waves_partition phase2 2 "$(slotn 0)")"
want "cap null (unbounded): one batch (chunkedParallel parity)" "[5]" "$(sizes_of "$(waves_partition phase2 null "$(slotn 5)")")"
want "W=28 X=4: the C1 incident shape (7 batches of 4)" \
  "[4,4,4,4,4,4,4]" "$(sizes_of "$(waves_partition phase2 4 "$(slotn 28)")")"

# ---- 6. Slot audit + the emitter (AC2, AC6) --------------------------------
CAP=4
plan --scope claim --scope-arg "a claim holding MARKER-CLAIM-TEXT that must never reach a slot"
expect_rc "capped claim preflight: exit 0" 0
PLAN_E="$TMP/planE.json"
PLAN_E2="$TMP/planE2.json"
cp "$PLANF" "$PLAN_E"
cp "$PLANF" "$PLAN_E2"
CLAIMS="$TMP/claims.json"
cat > "$CLAIMS" <<'EOF'
[{"claim":"MARKER-CLAIM-TEXT one","source_locator":"f.md:1","claim_type":"factual","claim_id":"c0"},
 {"claim":"MARKER-CLAIM-TEXT two","source_locator":"f.md:2","claim_type":"factual","claim_id":"c1"},
 {"claim":"MARKER-CLAIM-TEXT three","source_locator":"f.md:3","claim_type":"factual","claim_id":"c2"}]
EOF
waves_emit --plan-file "$PLAN_E" --claims-file "$CLAIMS"
expect_erc "emitter: exit 0" 0
check_json "emitter: plan gains waves" "$PLAN_E" '(.waves | type) == "array" and (.waves | length > 0)'
want "emitter: stdout == plan.waves" \
  "$(jq -c '.waves' "$PLAN_E")" "$EOUT"
check_json "slot key set is exactly the six tuple keys" "$PLAN_E" \
  '([.waves[].spawns[] | keys_unsorted | sort] | unique) == [["agent","claim_id","claim_index","flavor","model_pin_source","slot"]]'
check_json "model_pin_source is a rule name, never a model string" "$PLAN_E" \
  '([.waves[].spawns[].model_pin_source] | all(.[]; . == "map" or . == "tier-default" or . == "p2-literal"))'
check_json "no slot value carries claim text" "$PLAN_E" \
  '([.waves[] | tostring] | join("") | contains("MARKER-CLAIM-TEXT") | not)'
check_json "phase2 slots are claim-keyed in claim order" "$PLAN_E" \
  '([.waves[] | select(.wave == "phase2") | .spawns[] | .claim_id]) == ["c0","c0","c1","c1","c2","c2"]'
check_json "phase2 slot index runs 0..W-1 in wave order" "$PLAN_E" \
  '([.waves[] | select(.wave == "phase2") | .spawns[] | .slot]) == [range(0; 6)]'
check_json "phase4 slots carry claim_index/claim_id null" "$PLAN_E" \
  'all(.waves[] | select(.wave == "phase4") | .spawns[]; .claim_index == null and .claim_id == null)'
check_json "phase2.5 is skipped for a 2-bundle group (AC8)" "$PLAN_E" \
  '([.waves[] | select(.wave == "phase2.5")] | length) == 0'
check_json "emitter: no waves_pending on a claims-known plan" "$PLAN_E" 'has("waves_pending") | not'

# ---- 6b. The C1 incident at the emitter (AC10) ------------------------------
# 14 claims x 2 plan flavors at cap 4 = the 28 Phase 2 spawns the M14 C1 run
# pre-fired against cap 4. The emitter form carries the fixture here: the M14
# preflight path needs a committed spec fixture (plan CDT-594 T6).
CLAIMS14="$TMP/claims14.json"
jq -nc '[range(0; 14) as $i | {claim: ("MARKER14 claim " + ($i|tostring)),
                              source_locator: ("SPEC.md:" + ($i|tostring)),
                              claim_type: "factual",
                              claim_id: ("c" + ($i|tostring))}]' > "$CLAIMS14"
PLAN_C1="$TMP/planC1.json"
jq '.concurrency = 4 | del(.waves)' "$PLAN_E" > "$PLAN_C1"
waves_emit --plan-file "$PLAN_C1" --claims-file "$CLAIMS14"
expect_erc "emitter C1 fixture: exit 0" 0
want "emitter C1 fixture: 7 phase2 batches of exactly 4" \
  "[4,4,4,4,4,4,4]" "$(jq -c '[.waves[] | select(.wave == "phase2") | .spawns | length]' "$PLAN_C1")"
want "emitter C1 fixture: slots are in plan.claims order with claim_id set" \
  '["c0","c0","c1","c1","c2","c2","c3","c3","c4","c4","c5","c5","c6","c6","c7","c7","c8","c8","c9","c9","c10","c10","c11","c11","c12","c12","c13","c13"]' \
  "$(jq -c '[.waves[] | select(.wave == "phase2") | .spawns[] | .claim_id]' "$PLAN_C1")"
want "emitter C1 fixture: no claim text in any slot" "true" \
  "$(jq -c '([.waves[] | tostring] | join("") | contains("MARKER14") | not)' "$PLAN_C1")"

# ---- 7. Emitter determinism + idempotence (AC3, AC6) ------------------------
waves_emit --plan-file "$PLAN_E2" --claims-file "$CLAIMS"
expect_erc "emitter second run: exit 0" 0
want "emitter: byte-identical stdout over the same inputs" "$EOUT" "$(jq -c '.waves' "$PLAN_E2")"
want "emitter: byte-identical plan over the same inputs" \
  "$(cksum < "$PLAN_E")" "$(cksum < "$PLAN_E2")"
MD5_PLAN=$(cksum < "$PLAN_E")
waves_emit --plan-file "$PLAN_E" --claims-file "$CLAIMS"   # re-run over a merged plan
expect_erc "emitter re-run: exit 0" 0
want "emitter re-run: plan unchanged (wave replace is idempotent)" \
  "$MD5_PLAN" "$(cksum < "$PLAN_E")"

# ---- 8. Preflight emission coverage (AC1, AC4, AC5) -------------------------
CAP=1
plan --scope claim --scope-arg "x"
expect_plan "X=1: a 2-flavor phase2 wave is two batches of 1" \
  '([.waves[] | select(.wave == "phase2") | .spawns | length]) == [1,1]'
expect_plan "X=1: the Phase 4 pair is two batches of 1" \
  '([.waves[] | select(.wave == "phase4") | .spawns | length]) == [1,1]'
CAP=2
plan --scope claim --scope-arg "x"
expect_plan "capped claim scope: phase2 emitted at preflight" \
  'any(.waves[]; .wave == "phase2")'
expect_plan "capped claim scope: waves_pending absent once emitted" \
  'has("waves_pending") | not'
expect_plan "Phase 4 runs: one wave object with 2 slots" \
  '([.waves[] | select(.wave == "phase4") | .spawns | length]) == [2]'
expect_plan "Phase 3 runs: one specialist slot at agent null" \
  '([.waves[] | select(.wave == "phase3") | .spawns] | length == 1)
   and all(.waves[] | select(.wave == "phase3") | .spawns[]; .agent == null)'
expect_plan "generic preset: no phase2.5 wave (2 bundles < 3)" \
  'any(.waves[]; .wave == "phase2.5") | not'
plan --scope claim --scope-arg "x" --preset diff-mode
expect_plan "5-flavor wave: phase2.5 emits one slot per bundle (AC8)" \
  '([.waves[] | select(.wave == "phase2.5") | .spawns | length] | add) == 5'
expect_plan "a skipped Phase 3 emits no wave object" \
  'any(.waves[]; .wave == "phase3") | not'
expect_plan "a skipped Phase 4 emits no wave object" \
  'any(.waves[]; .wave == "phase4") | not'
for s in session plan diff; do
  case "$s" in
    plan)   plan --scope plan --scope-arg "$SPEC" ;;
    diff)   plan --scope diff ;;
    *)      plan --scope session ;;
  esac
  expect_rc "capped $s scope: preflight exit 0" 0
  expect_plan "$s scope: waves_pending names phase2 and phase2.5" \
    '.waves_pending == ["phase2","phase2.5"]'
  expect_plan "$s scope: no slots emitted for the pending waves" \
    'any(.waves[]?; .wave == "phase2") | not'
done
# --from-retro: the claim is already isolated, so phase2 is knowable.
mkdir -p "$REPO/.claude/retro/anchors"
cp "$ROOT/skills/council/fixtures/from-retro-anchor.json" \
   "$REPO/.claude/retro/anchors/a1b2c3d4e5f60718.json"
plan --scope from-retro --scope-arg a1b2c3d4e5f60718
expect_rc "capped from-retro: preflight exit 0" 0
expect_plan "from-retro: phase2 emitted (claim set known)" \
  'any(.waves[]; .wave == "phase2")'
expect_plan "from-retro: waves_pending absent" 'has("waves_pending") | not'
# The wave bytes are deterministic across runs of the same inputs.
CAP=3
plan --scope claim --scope-arg "x"; WAVES_A=$(jq -c '.waves' "$PLANF")
plan --scope claim --scope-arg "x"; WAVES_B=$(jq -c '.waves' "$PLANF")
want "preflight waves[]: byte-identical over the same inputs" "$WAVES_A" "$WAVES_B"
unset CAP
plan --scope claim --scope-arg "x" --preset diff-mode
expect_plan "unset cap on a 5-flavor run: no waves key" 'has("waves") | not'
expect_plan "unset cap on a 5-flavor run: no waves_pending key" 'has("waves_pending") | not'

# ---- 9. Emitter fail-closed matrix (AC7) ------------------------------------
# Every case: exit 64, stderr, plan file byte-unchanged, no stdout.
plan_hash() { { cksum < "$1"; } 2>/dev/null; }
emit_fail() {  # emit_fail <label> <plan-file> <claims-file>
  local before=""
  [ -f "$2" ] && before=$(plan_hash "$2")
  waves_emit --plan-file "$2" --claims-file "$3"
  expect_erc "$1: exit 64" 64
  [ -z "$EOUT" ] && ok "$1: empty stdout" || bad "$1: stdout not empty"
  [ -s "$EMF" ] && ok "$1: stderr names the cause" || bad "$1: empty stderr"
  if [ -n "$before" ]; then
    want "$1: plan file byte-unchanged" "$before" "$(plan_hash "$2")"
  fi
}
NOCONC="$TMP/plan-noconc.json"
jq 'del(.concurrency)' "$PLAN_E" > "$NOCONC"
emit_fail "missing plan file"        "$TMP/nope.json" "$CLAIMS"
emit_fail "plan with no concurrency" "$NOCONC"        "$CLAIMS"
emit_fail "missing claims file"      "$PLAN_E"        "$TMP/no-claims.json"
NOTARRAY="$TMP/claims-object.json"; printf '%s\n' '{"claim":"not an array"}' > "$NOTARRAY"
emit_fail "claims file is not a JSON array" "$PLAN_E" "$NOTARRAY"
EMPTYARR="$TMP/claims-empty.json"; printf '%s\n' '[]' > "$EMPTYARR"
emit_fail "empty claims array"       "$PLAN_E"        "$EMPTYARR"
BADJSON="$TMP/claims-bad.json"; printf '%s\n' 'not json at all' > "$BADJSON"
emit_fail "claims file is not valid JSON" "$PLAN_E"   "$BADJSON"
if [ "$(id -u)" != "0" ]; then
  NOREAD="$TMP/plan-noread.json"; cp "$PLAN_E" "$NOREAD"; chmod 000 "$NOREAD"
  emit_fail "unreadable plan file" "$NOREAD" "$CLAIMS"
  chmod 600 "$NOREAD"
  CNOREAD="$TMP/claims-noread.json"; cp "$CLAIMS" "$CNOREAD"; chmod 000 "$CNOREAD"
  emit_fail "unreadable claims file" "$PLAN_E" "$CNOREAD"
  chmod 600 "$CNOREAD"
else
  ok "unreadable-file cases skipped (running as root: [ -r ] is always true)"
fi

# ---- 10. Emitter usage guards (no cap layer, no mixed forms) ----------------
waves_emit
expect_erc "waves with no flags: exit 64" 64
waves_emit --bogus-flag
expect_erc "waves unknown flag: exit 64" 64
waves_emit --plan-file "$PLAN_E"
expect_erc "waves --plan-file with no --claims-file: exit 64" 64
waves_emit --plan-file "$PLAN_E" --claims-file "$CLAIMS" --concurrency 3
expect_erc "waves --concurrency in the plan-file form: exit 64" 64
waves_emit --blind --plan-file "$PLAN_E" --claims-file "$CLAIMS"
expect_erc "waves --blind with a plan file: exit 64" 64
waves_emit --blind --concurrency 0
expect_erc "waves --blind --concurrency 0: exit 64" 64
waves_emit --blind --teams 0
expect_erc "waves --blind --teams 0: exit 64" 64
waves_emit --blind --lenses 'security,,'
expect_erc "waves --blind empty lens token: exit 64" 64

# ---- 11. The blind wave (AC9) -----------------------------------------------
SCRATCH="$TMP/scratch"; mkdir -p "$SCRATCH"
BEFORE=$(cd "$SCRATCH" && ls -A | wc -l | tr -d ' ')
# The default parity flags are `--teams 3 --lenses security,contributor,spec`
# — the 6-slot wave SPEC-013 Test 28 item 5 names.
waves_emit --blind --concurrency 9
BLIND6="$EOUT"
expect_erc "blind at X=9: exit 0" 0
want "blind 6 slots at X>=6: one batch" "[6]" "$(sizes_of "$BLIND6")"
want "blind slot ids are U1..UN then L-<lens>" \
  '["U1","U2","U3","L-security","L-contributor","L-spec"]' \
  "$(printf '%s' "$BLIND6" | jq -c '[.[].spawns[].flavor]')"
want "blind slots carry claim_index/claim_id null" "true" \
  "$(printf '%s' "$BLIND6" | jq -c 'all(.[].spawns[]; .claim_index == null and .claim_id == null)')"
want "blind slots are one wave" "true" \
  "$(printf '%s' "$BLIND6" | jq -c 'all(.[]; .wave == "blind")')"
want "blind slot key set is the six tuple keys" '[["agent","claim_id","claim_index","flavor","model_pin_source","slot"]]' \
  "$(printf '%s' "$BLIND6" | jq -c '[.[].spawns[] | keys_unsorted | sort] | unique')"
waves_emit --blind --concurrency 4
expect_erc "blind at X=4: exit 0" 0
want "blind 6 slots at X=4: sizes 4,2" "[4,2]" "$(sizes_of "$EOUT")"
waves_emit --blind --concurrency 2
want "blind 6 slots at X=2: sizes 2,2,2" "[2,2,2]" "$(sizes_of "$EOUT")"
waves_emit --blind --teams 2 --lenses security --concurrency 1
want "blind 3 slots at X=1: three batches of 1" "[1,1,1]" "$(sizes_of "$EOUT")"
AFTER=$(cd "$SCRATCH" && ls -A | wc -l | tr -d ' ')
want "blind form writes nothing" "$BEFORE" "$AFTER"
# Cap from the ONE merge helper: the Model map layer is honoured, a flag wins.
mkdir -p "$(dirname "$MAP")"
printf '%s\n' '{"concurrency": 2}' > "$MAP"
waves_emit --blind
want "blind cap from the Model map layer" "[2,2,2]" "$(sizes_of "$EOUT")"
waves_emit --blind --concurrency 5
want "blind: the flag beats the map layer" "[5,1]" "$(sizes_of "$EOUT")"
rm -f "$MAP"
waves_emit --blind
want "blind with no cap set: one batch (unbounded)" "[6]" "$(sizes_of "$EOUT")"

# ---- 12. --why gains why_detail.waves (AC1) ---------------------------------
CAP=3
plan --scope claim --scope-arg "x" --why
expect_plan "--why: why_detail.waves is a non-empty array" \
  '(.why_detail.waves | type) == "array" and (.why_detail.waves | length > 0)'
expect_plan "--why: every entry carries wave, batches, spawns" \
  'all(.why_detail.waves[]; has("wave") and has("batches") and has("spawns"))'
expect_plan "--why: spawn totals match the wave plan" \
  '([.why_detail.waves[].spawns] | add) == ([.waves[].spawns[]] | length)'
unset CAP
plan --scope claim --scope-arg "x" --why
expect_plan "unset cap --why: why_detail gains no waves key" \
  'has("why_detail") and (.why_detail | has("waves") | not)'

# ---- 13. Finalize Phase-2-only count check (AC18) ---------------------------
# Shortfall = bundles that carry a claim below the plan's phase2 slot count for
# that claim. At verification_mode full it is exit 7 (the shared finalize
# contract-violation code, so the suite asserts the stderr text naming the
# claim ids) with no report and no reservation. Declared self-verified it
# proceeds and writes one Audit Trail line. An equal count, an excess, a plan
# with no phase2 wave, and an empty bundle set are all not failures.
FPLAN="$TMP/plan-finalize.json"
FJUDGE="$TMP/finalize-judge.json"
FREP="$TMP/finalize-report.md"
FOUT="$TMP/finalize.out"
FERR="$TMP/finalize.err"
FRC=0
has() {  # has <label> <fixed-string> <file>
  if grep -qF -- "$2" "$3"; then ok "$1"; else bad "$1 (missing: $2)"; fi
}
hasnt() {  # hasnt <label> <fixed-string> <file>
  if grep -qF -- "$2" "$3"; then bad "$1 (present: $2)"; else ok "$1"; fi
}
strip_ts() { sed -E 's/20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:]+Z/TS/g' "$1"; }
fmkeys() { sed -n '/^---$/,/^---$/p' "$1" | grep -E '^[A-Za-z0-9_]+:' | cut -d: -f1 | sort; }
mk_bundles() {  # mk_bundles <file> <claim ids, space separated — one bundle each>
  jq -nc --arg ids "$2" '
    [$ids | split(" ") | to_entries[]
     | { tool_use_id: ("ft" + (.key | tostring)),
         raw_blob: ("WAVEBLOB-" + (.key | tostring) + " observed on " + .value),
         file_line: ("f.md:" + ((.key + 1) | tostring)),
         reproducible_command: "true",
         claim_id: .value }]' > "$1"
}
finalize_run() {  # finalize_run <plan> <evidence> [extra finalize flags…]
  local _plan="$1" _ev="$2"; shift 2
  ( cd "$REPO" && env -u COUNCIL_CONCURRENCY bash "$ENGINE" finalize \
      --plan-file "$_plan" --evidence-file "$_ev" --judge-output "$FJUDGE" \
      --report-out "$FREP" "$@" ) > "$FOUT" 2> "$FERR"
  FRC=$?
  return 0
}

CAP=4
plan --scope claim --scope-arg "the finalize count check fixture"
expect_rc "finalize fixture: preflight exit 0" 0
cp "$PLANF" "$FPLAN"
waves_emit --plan-file "$FPLAN" --claims-file "$CLAIMS"
expect_erc "finalize fixture: emitter exit 0" 0
want "finalize fixture: 6 phase2 slots keyed c0,c1,c2" "6" \
  "$(jq -c '[.waves[] | select(.wave == "phase2") | .spawns[]] | length' "$FPLAN")"
jq -nc '{verdicts: [{claim_id: "c0", claim: "MARKER-CLAIM-TEXT one", verdict: "VERIFIED",
                     confidence: 90, evidence_blob: "WAVEBLOB-0", tool_use_id: "ft0"}],
         struck_lines: []}' > "$FJUDGE"

EV_EQ="$TMP/ev-equal.json";      mk_bundles "$EV_EQ" "c0 c0 c1 c1 c2 c2"
EV_SHORT="$TMP/ev-short.json";   mk_bundles "$EV_SHORT" "c0 c0 c1 c1 c2"
EV_EXCESS="$TMP/ev-excess.json"; mk_bundles "$EV_EXCESS" "c0 c0 c1 c1 c2 c2 c2"

# 13a. Equal: silent exit 0, nothing new in the report.
finalize_run "$FPLAN" "$EV_EQ"
want "equal counts: finalize exit 0" "0" "$FRC"
hasnt "equal counts: no Audit Trail line" 'phase2-wave-shortfall' "$FREP"
hasnt "equal counts: nothing on stderr" 'phase2-wave-shortfall' "$FERR"
want "equal counts: struck line count unchanged" "Struck lines: 0" "$(grep '^Struck lines:' "$FOUT")"
cp "$FREP" "$TMP/report-equal.md"

# 13b. Shortfall at verification_mode full: exit 7, stderr names the claim ids,
# no report and no reservation.
NOOUT_PLAN_REPORT=$(jq -r '.report_path' "$FPLAN")
BEFORE_COUNCIL=$( { ls -A "$REPO/.claude/council"; } 2>/dev/null | wc -l | tr -d ' ')
( cd "$REPO" && env -u COUNCIL_CONCURRENCY bash "$ENGINE" finalize \
    --plan-file "$FPLAN" --evidence-file "$EV_SHORT" --judge-output "$FJUDGE" ) > "$FOUT" 2> "$FERR"
FRC=$?
want "shortfall at full: exit 7 (contract-violation code)" "7" "$FRC"
has "shortfall at full: stderr names the claim id and counts" "c2 intended 2 observed 1" "$FERR"
AFTER_COUNCIL=$( { ls -A "$REPO/.claude/council"; } 2>/dev/null | wc -l | tr -d ' ')
want "shortfall at full: no report, no reservation" "$BEFORE_COUNCIL" "$AFTER_COUNCIL"
[ -e "$NOOUT_PLAN_REPORT" ] && bad "shortfall at full: plan.report_path written" || ok "shortfall at full: plan.report_path untouched"

# 13c. The same shortfall declared self-verified: proceed, one Audit Trail line.
finalize_run "$FPLAN" "$EV_SHORT" --verification-mode self-verified
want "shortfall self-verified: finalize exit 0" "0" "$FRC"
has "shortfall self-verified: Audit Trail line" \
  '- phase2-wave-shortfall: c2 intended 2 observed 1' "$FREP"
has "shortfall self-verified: the line names the self-verified declaration" \
  'observed 1 — declared self-verified' "$FREP"
want "shortfall self-verified: the line is the struck-count entry" \
  "Struck lines: 1" "$(grep '^Struck lines:' "$FOUT")"
want "shortfall self-verified: no new frontmatter key" \
  "$(fmkeys "$TMP/report-equal.md")" "$(fmkeys "$FREP")"

# 13d. No phase2 wave to count: no check, byte-identical report.
FPLAN_NW="$TMP/plan-finalize-nowaves.json"
jq 'del(.waves)' "$FPLAN" > "$FPLAN_NW"
finalize_run "$FPLAN_NW" "$EV_SHORT"
want "no waves key: finalize exit 0 (no check)" "0" "$FRC"
hasnt "no waves key: no Audit Trail line" 'phase2-wave-shortfall' "$FREP"
finalize_run "$FPLAN" "$EV_EQ"
strip_ts "$FREP" | cksum > "$TMP/ck-waves"
finalize_run "$FPLAN_NW" "$EV_EQ"
strip_ts "$FREP" | cksum > "$TMP/ck-nowaves"
want "no waves key: report bytes identical to the capped run" \
  "$(cat "$TMP/ck-waves")" "$(cat "$TMP/ck-nowaves")"

FPLAN_NOP2="$TMP/plan-finalize-nop2.json"
jq '.waves = [.waves[] | select(.wave != "phase2")]' "$FPLAN" > "$FPLAN_NOP2"
finalize_run "$FPLAN_NOP2" "$EV_SHORT"
want "waves with no phase2 wave: finalize exit 0" "0" "$FRC"
hasnt "waves with no phase2 wave: no Audit Trail line" 'phase2-wave-shortfall' "$FREP"

# 13e. No wave other than Phase 2 is counted (AC18 last clause): the same six
# slots renamed phase2.5 against two bundles is not a shortfall.
FPLAN_P25="$TMP/plan-finalize-p25.json"
jq -c --argjson w "$(jq -c '[.waves[] | select(.wave == "phase2") | .wave = "phase2.5"]' "$FPLAN")" \
  '.waves = $w' "$FPLAN" > "$FPLAN_P25"
if jq -e '[.waves[] | .wave] | index("phase2") | not' "$FPLAN_P25" >/dev/null; then
  ok "phase2.5-only plan: no phase2 wave"
else
  bad "phase2.5-only plan build failed"
fi
jq -c '.[0:2]' "$EV_EQ" > "$TMP/ev-p25.json"
finalize_run "$FPLAN_P25" "$TMP/ev-p25.json"
want "phase2.5 slots are not counted: finalize exit 0" "0" "$FRC"
hasnt "phase2.5 slots are not counted: no Audit Trail line" 'phase2-wave-shortfall' "$FREP"

# 13f. An excess is legitimate (Phase 3 specialist merge, appended flavors,
# the additive external slot) — never a failure.
finalize_run "$FPLAN" "$EV_EXCESS"
want "excess bundles: finalize exit 0" "0" "$FRC"
hasnt "excess bundles: no Audit Trail line" 'phase2-wave-shortfall' "$FREP"

# 13g. Single-claim / --from-retro plans: the phase2 slots carry claim_id null
# and key the same no-claim-id group the bundles with no claim_id form.
CAP=2
plan --scope claim --scope-arg "single claim, claim_id null slots"
FPLAN_NULL="$TMP/plan-finalize-null.json"
cp "$PLANF" "$FPLAN_NULL"
want "null-group fixture: phase2 slots carry claim_id null" "true" \
  "$(jq -c 'all(.waves[] | select(.wave == "phase2") | .spawns[]; .claim_id == null)' "$FPLAN_NULL")"
jq -c 'map(del(.claim_id))' "$EV_EQ" > "$TMP/ev-null-equal.json"
jq -c 'map(del(.claim_id)) | .[0:1]' "$EV_EQ" > "$TMP/ev-null-short.json"
finalize_run "$FPLAN_NULL" "$TMP/ev-null-equal.json"
want "null group, equal counts: finalize exit 0" "0" "$FRC"
finalize_run "$FPLAN_NULL" "$TMP/ev-null-short.json"
want "null group, one bundle short: exit 7" "7" "$FRC"
has "null group shortfall: stderr names the no-claim-id group" "no-claim-id intended 2 observed 1" "$FERR"

# 13h. An empty bundle set stays exit 5, not 7.
printf '%s\n' '[]' > "$TMP/ev-empty.json"
finalize_run "$FPLAN" "$TMP/ev-empty.json"
want "empty bundle set with a shortfall plan: exit 5 wins" "5" "$FRC"
hasnt "empty bundle set: no shortfall line on stderr" 'phase2-wave-shortfall' "$FERR"

# ---- 14. The M14 preflight fixture — AC10 on the preflight path -------------
# SPEC-013 AC10 names the C1 incident: an M14 split of 14 technical ACs, the
# generic preset's 2 flavors, at cap 4 = 28 Phase 2 slots in 7 batches of 4, in
# plan.claims[] order with claim_id on every slot. § 6b pins the same arithmetic
# through the emitter; this is the preflight path, driven by a real split.
M14FIX="$REPO/m14-14-ac.md"
{
  printf '# Wave fixture spec (waves T6)\n\n## Acceptance criteria\n\n### wave-m14-fixture\n\n'
  for L in A B C D E F G H I J K L M N; do
    printf -- '- **%s.** MARKER14AC criterion %s: the wave fixture holds.\n' "$L" "$L"
  done
} > "$M14FIX"
want "AC10 fixture: 14 AC bullets written" "14" "$(grep -cE '^- \*\*[A-N]\.\*\* ' "$M14FIX")"
git -C "$REPO" add -- m14-14-ac.md && git -C "$REPO" commit -q -m 'waves m14 fixture' \
  && ok "AC10 fixture: committed into the disposable repo (m14-ac-split reads HEAD)" \
  || bad "AC10 fixture: git add/commit failed — the split cannot read HEAD"
M14ARG="Ship-gate audit for wave-m14-fixture. Ship-gate audit under the ACs at"
M14ARG="$M14ARG ac-source=m14-14-ac.md (section '## Acceptance criteria',"
M14ARG="$M14ARG subsection '### wave-m14-fixture'). Claim under audit: the change ships correctly."
CAP=4
plan --scope claim --scope-arg "$M14ARG"
expect_rc "M14 preflight: preflight exit 0" 0
expect_plan "M14 preflight: the split produced 14 claims" '(.claims | length) == 14'
want "M14 preflight: claim ids c0..c13 in document order" \
  "$(jq -nc '[range(0;14) | ("c" + tostring)]')" "$(jq -c '[.claims[].claim_id]' "$PLANF")"
want "AC10: 7 phase2 batches of exactly 4 slots at cap 4" "[4,4,4,4,4,4,4]" \
  "$(jq -c '[.waves[] | select(.wave == "phase2") | .spawns | length]' "$PLANF")"
want "AC10: 28 phase2 slots (the count C1 pre-fired against cap 4)" "28" \
  "$(jq -c '[.waves[] | select(.wave == "phase2") | .spawns[]] | length' "$PLANF")"
want "AC10: slots are claim-major in plan.claims[] order" \
  "$(jq -nc '[range(0;14) | ("c" + tostring), ("c" + tostring)]')" \
  "$(jq -c '[.waves[] | select(.wave == "phase2") | .spawns[] | .claim_id]' "$PLANF")"
expect_plan "AC10: every phase2 slot carries claim_index + claim_id" \
  'all(.waves[] | select(.wave == "phase2") | .spawns[]; .claim_id != null and .claim_index != null)'
expect_plan "AC10: no slot carries claim text, locator, or AC text" \
  '([.waves[] | tostring] | join("")
   | (contains("MARKER14AC") or contains("m14-14-ac.md") or contains("satisfies acceptance criterion"))
   | not)'
expect_plan "AC10: waves_pending absent (the claim set is known)" 'has("waves_pending") | not'
expect_plan "AC8: no phase2.5 wave (a 2-bundle group is below the bar)" \
  'any(.waves[]; .wave == "phase2.5") | not'
expect_plan "AC4: phase3 (1 slot) and phase4 (2 slots) ride the same plan" \
  '([.waves[] | select(.wave == "phase3") | .spawns | length]) == [1]
   and ([.waves[] | select(.wave == "phase4") | .spawns | length]) == [2]'
want "AC1/AC15: batch numbering is per wave (7, then 1, then 1)" "[1,2,3,4,5,6,7]" \
  "$(jq -c '[.waves[] | select(.wave == "phase2") | .batch]' "$PLANF")"
want "AC1: the phase3 batch is batch 1 of its own wave" "[1]" \
  "$(jq -c '[.waves[] | select(.wave == "phase3") | .batch]' "$PLANF")"
want "AC1: the phase4 batch is batch 1 of its own wave" "[1]" \
  "$(jq -c '[.waves[] | select(.wave == "phase4") | .batch]' "$PLANF")"
plan --scope claim --scope-arg "$M14ARG" --why
expect_plan "AC9/AC1 --why: why_detail.waves summarises the emitted plan" \
  '.why_detail.waves == [{wave: "phase2", batches: 7, spawns: 28},
                         {wave: "phase3", batches: 1, spawns: 1},
                         {wave: "phase4", batches: 1, spawns: 2}]'
CAP=1
plan --scope claim --scope-arg "$M14ARG"
expect_plan "AC15 at cap 1: 28 phase2 batches of one slot" \
  '([.waves[] | select(.wave == "phase2") | .spawns | length]) == [range(0; 28) | 1]'
unset CAP
plan --scope claim --scope-arg "$M14ARG"
expect_plan "AC1 on the M14 path: 14 claims, no waves key" \
  '(.claims | length) == 14 and (has("waves") | not)'
expect_plan "AC1 on the M14 path: no waves_pending key" 'has("waves_pending") | not'
CAP=4
plan --scope claim --scope-arg "$M14ARG"; M14W_A=$(jq -c '.waves' "$PLANF")
plan --scope claim --scope-arg "$M14ARG"
want "AC3: M14 waves[] byte-identical over the same inputs" "$M14W_A" "$(jq -c '.waves' "$PLANF")"
# One partition home: preflight and the emitter agree on the same plan + claims.
M14CLAIMS="$TMP/m14-claims.json"
jq -c '[.claims[] | {claim, source_locator, claim_type, claim_id}]' "$PLANF" > "$M14CLAIMS"
M14EMIT="$TMP/plan-m14-emit.json"
jq 'del(.waves)' "$PLANF" > "$M14EMIT"
waves_emit --plan-file "$M14EMIT" --claims-file "$M14CLAIMS"
expect_erc "M14 emitter re-emit: exit 0" 0
want "AC3/AC6: the emitter and preflight emit the same phase2 partition" \
  "$(jq -c '[.waves[] | select(.wave == "phase2")]' "$PLANF")" \
  "$(jq -c '[.waves[] | select(.wave == "phase2")]' "$M14EMIT")"

# ---- 15. The emitter on a waves_pending plan + the phase2.5 slot audit -------
# The diff scope is the AC5 shape: waves_pending names phase2 + phase2.5 and
# preflight emits no objects for them. The diff-mode preset carries 5 flavors,
# so this is also the only fixture here with a real phase2.5 wave (3 claims ×
# 5 bundles ≥ the 3-bundle bar).
CAP=2
plan --scope diff
expect_rc "diff plan for the emitter: preflight exit 0" 0
expect_plan "AC5: waves_pending names both Phase-1 waves" '.waves_pending == ["phase2","phase2.5"]'
expect_plan "AC5: no wave objects for the pending waves at preflight" 'has("waves") | not'
DIFFP="$TMP/plan-diff-emit.json"
cp "$PLANF" "$DIFFP"
waves_emit --plan-file "$DIFFP" --claims-file "$CLAIMS"
expect_erc "AC6: emitter on a waves_pending plan exits 0" 0
want "AC6: stdout == plan.waves, byte for byte" "$(jq -c '.waves' "$DIFFP")" "$EOUT"
check_json "AC6: both emitted names dropped (key deleted when empty)" "$DIFFP" \
  'has("waves_pending") | not'
want "AC3: phase2 = 3 claims × 5 flavors at cap 2 → 7 full + 1 partial" \
  "[2,2,2,2,2,2,2,1]" "$(jq -c '[.waves[] | select(.wave == "phase2") | .spawns | length]' "$DIFFP")"
want "AC8: phase2.5 = one slot per bundle of a ≥3 group (3 × 5)" \
  "[2,2,2,2,2,2,2,1]" "$(jq -c '[.waves[] | select(.wave == "phase2.5") | .spawns | length]' "$DIFFP")"
check_json "AC1: plan.waves holds exactly the two emitted waves" "$DIFFP" \
  '([.waves[].wave] | unique) == ["phase2","phase2.5"]'
check_json "AC6: waves are ordered by the canonical wave order" "$DIFFP" \
  '(.waves[0].wave == "phase2") and (.waves[7].wave == "phase2")
   and (.waves[8].wave == "phase2.5")'
want "AC15: batch indices restart per wave (batches never merge across waves)" \
  "[1,2,3,4,5,6,7,8]" "$(jq -c '[.waves[] | select(.wave == "phase2.5") | .batch]' "$DIFFP")"
check_json "AC2: phase2.5 slots are the cross-review tuple" "$DIFFP" \
  '([.waves[] | select(.wave == "phase2.5") | .spawns[] | .flavor] | unique) == ["cross-review"]
   and ([.waves[] | select(.wave == "phase2.5") | .spawns[] | .agent] | unique) == ["council-scribe"]
   and ([.waves[] | select(.wave == "phase2.5") | .spawns[] | .model_pin_source] | unique) == ["p2-literal"]'
check_json "AC8: phase2.5 slots are claim-keyed, claim-major" "$DIFFP" \
  '([.waves[] | select(.wave == "phase2.5") | .spawns[] | .claim_id])
   == ["c0","c0","c0","c0","c0","c1","c1","c1","c1","c1","c2","c2","c2","c2","c2"]'
check_json "AC2: phase2.5 slot index runs 0..W-1 in wave order" "$DIFFP" \
  '([.waves[] | select(.wave == "phase2.5") | .spawns[] | .slot]) == [range(0; 15)]'
check_json "AC2: every slot of every wave is the six-key tuple" "$DIFFP" \
  '([.waves[].spawns[] | keys_unsorted | sort] | unique)
   == [["agent","claim_id","claim_index","flavor","model_pin_source","slot"]]'
check_json "AC2: a slot value is a scalar — no nested object, no artifact bytes" "$DIFFP" \
  'all(.waves[].spawns[] | to_entries[]; (.value | type) != "object" and (.value | type) != "array")'
check_json "AC2: no slot carries claim text from the fixture" "$DIFFP" \
  '([.waves[] | tostring] | join("") | contains("MARKER-CLAIM-TEXT") | not)'

# ---- 16. Slice invariants (AC3, AC15) ---------------------------------------
# The fences iterate these objects, so the partition must be a plain contiguous
# slicing of the ordered slot list: nothing merged, nothing reordered, nothing
# duplicated, every batch full except a partial last.
P11=$(waves_partition phase2 3 "$(slotn 11)")
want "AC3: W=11 X=3 → 3,3,3,2" "[3,3,3,2]" "$(sizes_of "$P11")"
want "AC3: ceil(11/3) batches, 1-based and contiguous" "[1,2,3,4]" "$(printf '%s' "$P11" | jq -c '[.[].batch]')"
want "AC3: every batch except the last holds exactly X" "[3,3,3]" \
  "$(printf '%s' "$P11" | jq -c '[.[:-1][].spawns | length]')"
want "AC3: no batch exceeds X" "true" "$(printf '%s' "$P11" | jq -c 'all(.[]; (.spawns | length) <= 3)')"
want "AC3: slot total == W" "11" "$(printf '%s' "$P11" | jq -c '[.[].spawns[]] | length')"
want "AC15: the batches concatenate back to the slot list, in order" \
  "$(slotn 11)" "$(printf '%s' "$P11" | jq -c '[.[].spawns[]]')"
want "AC15: no slot appears in two batches" "11" \
  "$(printf '%s' "$P11" | jq -c '[.[].spawns[].slot] | unique | length')"
want "AC15: cap 1 → six batches of one slot" "[1,1,1,1,1,1]" \
  "$(sizes_of "$(waves_partition phase2 1 "$(slotn 6)")")"
want "AC3: cap 0 is unbounded (chunkedParallel parity)" "[11]" \
  "$(sizes_of "$(waves_partition phase2 0 "$(slotn 11)")")"
want "AC3: X > W → one batch" "[11]" "$(sizes_of "$(waves_partition phase2 1000 "$(slotn 11)")")"
want "AC3: a non-numeric cap is not a cap (the CLI rejects it upstream)" "[11]" \
  "$(sizes_of "$(waves_partition phase2 '"3"' "$(slotn 11)")")"

# ---- 17. One carrier: plan.concurrency, and nothing else (AC13, AC1) --------
# The emitter is the site most exposed to a second cap layer. COUNCIL_CONCURRENCY
# is passed by the harness (CAP) and a Model map file is planted in the repo:
# neither may move the partition.
PLAN_E3="$TMP/planE3.json"
jq 'del(.waves)' "$PLAN_E" > "$PLAN_E3"          # plan.concurrency == 4
CAP=8
waves_emit --plan-file "$PLAN_E3" --claims-file "$CLAIMS"
expect_erc "AC13: emitter with COUNCIL_CONCURRENCY=8 exits 0" 0
want "AC13: the env layer is not a cap source (plan 4 wins)" "[4,2]" \
  "$(jq -c '[.waves[] | select(.wave == "phase2") | .spawns | length]' "$PLAN_E3")"
mkdir -p "$(dirname "$MAP")"
printf '%s\n' '{"concurrency": 3}' > "$MAP"
PLAN_E4="$TMP/planE4.json"
jq 'del(.waves)' "$PLAN_E" > "$PLAN_E4"
waves_emit --plan-file "$PLAN_E4" --claims-file "$CLAIMS"
expect_erc "AC13: emitter with a Model map concurrency exits 0" 0
want "AC13: the Model map layer is not a cap source (plan 4 wins)" "[4,2]" \
  "$(jq -c '[.waves[] | select(.wave == "phase2") | .spawns | length]' "$PLAN_E4")"
rm -f "$MAP"
emit_fail "AC13: plan with no concurrency, env cap 8 set" "$NOCONC" "$CLAIMS"
unset CAP
# Unset is untouched: the plan is the CDT-573 plan, and the wave keys are the
# whole delta a capped run adds. cache_dir / run_id are the per-run temporaries.
strip_plan() { jq -S 'del(.cache_dir, .run_id, .concurrency, .waves, .waves_pending)' "$1"; }
unset CAP
plan --scope claim --scope-arg "byte identity on the unset path"
strip_plan "$PLANF" > "$TMP/plan-unset-a.json"
plan --scope claim --scope-arg "byte identity on the unset path"
strip_plan "$PLANF" > "$TMP/plan-unset-b.json"
want "AC1: the unset plan is byte-identical across runs" \
  "$(cksum < "$TMP/plan-unset-a.json")" "$(cksum < "$TMP/plan-unset-b.json")"
plan --scope claim --scope-arg "byte identity on the unset path"
expect_plan "AC13: no wave carrier at any depth in the unset plan" \
  '[.. | objects | select(has("waves") or has("waves_pending") or has("concurrency"))] | length == 0'
strip_plan "$PLANF" > "$TMP/plan-capped-stripped.json"
# Guard the byte-identity comparisons: a cksum of a missing file is the empty
# string on both sides, so an empty artifact would pass vacuously.
for _f in plan-unset-a plan-unset-b plan-capped-stripped; do
  if jq -e 'has("phases") and (.scope == "claim")' "$TMP/$_f.json" >/dev/null 2>&1; then
    ok "AC1 fixture: $_f is a whole plan"
  else
    bad "AC1 fixture: $_f is not a whole plan — the byte-identity pins below are vacuous"
  fi
done
want "AC1/AC13: the capped plan minus the wave keys == the unset plan bytes" \
  "$(cksum < "$TMP/plan-unset-a.json")" "$(cksum < "$TMP/plan-capped-stripped.json")"

# ---- 18. AC16 — the documented behaviour is prose: the pins exist -----------
# AC16 is a [process] AC: the gate evidence is the emitted waves[] (§ 5-15), the
# batch-synchronous fence text, and the static suites. This section asserts the
# prose those gates read exists and says what the gate relies on. The
# host-portability degrade row in docs/host-tool-map.md is the T5 surface and is
# pinned by skills/council/test-concurrency.sh (plan CDT-594 T7 § AC16).
SC="$ROOT/skills/council/spawn-contract.md"
P2F="$ROOT/skills/council/phases-0-2.md"
P25F="$ROOT/skills/council/phases-blind.md"
CMDF="$ROOT/commands/council.md"
flat() { tr -s '[:space:]' ' ' < "$1"; }
flat_has() {  # flat_has <label> <needle> <file> — prose pins are line-wrapped
  if flat "$3" | grep -qF -- "$2"; then ok "$1"; else bad "$1 (missing: $2)"; fi
}
want "AC13/AC16: spawn-contract.md holds exactly one copy of the contract line" "1" \
  "$(grep -c 'Spawn contract: at most <N> spawns in flight' "$SC")"
want "AC11: spawn-contract.md holds the batch iteration exactly once" "1" \
  "$(grep -c 'spawn exactly the slots of batch' "$SC")"
flat_has "AC11: one copy of the batch iteration" \
  "spawn exactly the slots of batch *k* in one message, await every return, then run batch *k*+1" "$SC"
want "AC11/AC13: the fences cite that copy, they do not retype it" "0" \
  "$(cat "$CMDF" "$P2F" "$P25F" | grep -c 'spawn exactly the slots of batch')"
flat_has "AC11: a wave-plan-enforced site counts, slices, and re-resolves nothing" \
  "A wave-plan-enforced site MUST NOT count, slice, rank, reorder, or enumerate the fleet, and MUST NOT re-resolve the cap." "$SC"
flat_has "AC15: batches never merge across waves and never split inside a wave" \
  "Batches never merge across waves and never split inside a wave" "$SC"
flat_has "AC15: cap = 1 is legal (every batch holds one slot)" \
  '`cap = 1` is legal: every batch then holds one slot' "$SC"
flat_has "AC15: a batch MUST NOT observe sibling-batch output" \
  "A batch MUST NOT observe sibling-batch output" "$SC"
flat_has "AC16: queueing is not a spawn failure — no self-verified, no marker" \
  "Queueing is not a spawn failure: batching never sets \`verification_mode: self-verified\` and never emits the CDV-199 marker" "$SC"
has "AC16: the degrade-path section exists" \
  "### Degrade path: no batch-synchronous fan-out primitive" "$SC"
flat_has "AC16: the degrade path keeps the plan boundaries and sets no verification_mode" \
  "Batch boundaries stay the plan's; blindness holds; queueing still is not a spawn failure, so the degrade sets no \`verification_mode\` and emits no marker" "$SC"
flat_has "AC7/AC16: a failed emitter stops the run, never an unbounded fan-out" \
  "NEVER continue the run with an unbounded fan-out" "$SC"
flat_has "AC7: the fail-closed rule keeps the plan byte-unchanged" "The plan stays byte-unchanged." "$SC"
has "AC14: § Scope names the wave-plan-enforced tier" "- **Wave-plan-enforced**" "$SC"
has "AC14: § Scope names the prose-enforced tier" "- **Prose-enforced**" "$SC"
has "AC14: § Scope names the follow-up record" \
  ".claude/backlog/wave-plan-enforcement-for-the-six-prose-enforced-s.md" "$SC"
has "AC11: the Phase 2 fence iterates its wave" "run the wave off \`plan.waves[]\`" "$P2F"
flat_has "AC11: the Phase 2 fence re-resolves no cap layer" \
  "re-resolves no cap layer" "$P2F"
flat_has "AC15: the Phase 2 fence keeps blindness" "A batch observes no sibling-batch output" "$P2F"
flat_has "AC15: the Phase 2 fence never pre-fires the wave whole" \
  "the wave is never pre-fired whole and never serialized one spawn at a time" "$P2F"
has "AC11: the Phase 2.5 fence iterates its own wave" \
  'run the wave off `plan.waves[]` (`wave == "phase2.5"`)' "$P25F"
flat_has "AC15: the Phase 2.5 fence keeps blindness" \
  "a batch MUST NOT observe sibling-batch output" "$P25F"
has "AC5/AC6: the emitter fence is Phase 1.5" \
  "### Phase 1.5 — Wave-plan emission (CDT-594)" "$CMDF"
has "AC7/AC16: a non-zero emitter exit is a hard stop" \
  "**Non-zero exit is a hard stop.**" "$CMDF"
flat_has "AC6: the Phase 1.5 fence passes the claims as a path argument" \
  "waves --plan-file \"\$PLAN_FILE\" --claims-file \"\$CLAIMS_FILE\"" "$CMDF"
has "AC16: the spec states the QA gate evidence" \
  "The gate evidence is the emitted \`waves[]\`, the batch-synchronous fence text, and the static suites named in this subsection." "$SPEC"

# ---- 19. Finalize count-check cases § 13 does not cover (AC18) --------------
# § 13 covers one short id, equality, excess, no phase2 wave, the no-claim-id
# group, and the exit-5 precedence. Added here: every short group is named, an
# excess in one group never cancels a shortfall in another, the intended count
# is the slot count of every phase2 batch object (not the batch count), and no
# wave other than phase2 is counted.
EV_MULTI="$TMP/ev-multi-short.json";  mk_bundles "$EV_MULTI" "c0 c1 c1 c2"
EV_MIX="$TMP/ev-mix.json";           mk_bundles "$EV_MIX" "c0 c0 c0 c1 c1 c1 c2"
EV_FOREIGN="$TMP/ev-foreign.json";   mk_bundles "$EV_FOREIGN" "c0 c0 c1 c1 c2 c2 c9"
finalize_run "$FPLAN" "$EV_MULTI"
want "AC18: two short groups → exit 7" "7" "$FRC"
has "AC18: stderr names every short group with its counts" \
  "c0 intended 2 observed 1; c2 intended 2 observed 1" "$FERR"
finalize_run "$FPLAN" "$EV_MULTI" --verification-mode self-verified
want "AC18: two short groups self-verified → exit 0" "0" "$FRC"
has "AC18: one Audit Trail line names both groups" \
  '- phase2-wave-shortfall: c0 intended 2 observed 1; c2 intended 2 observed 1 — declared self-verified' "$FREP"
finalize_run "$FPLAN" "$EV_MIX"
want "AC18: an excess group does not cancel a shortfall → exit 7" "7" "$FRC"
has "AC18: the short group is named" "c2 intended 2 observed 1" "$FERR"
hasnt "AC18: the excess groups are not named" "c0 intended" "$FERR"
finalize_run "$FPLAN" "$EV_FOREIGN"
want "AC18: bundles for a claim the plan has no slots for are not a shortfall" "0" "$FRC"
hasnt "AC18: no Audit Trail line for the foreign group" 'phase2-wave-shortfall' "$FREP"
# Intended = the phase2 slot count of the whole wave, spread over one batch.
FPLAN_ONE="$TMP/plan-finalize-onebatch.json"
jq -c '.waves = ([{wave: "phase2", batch: 1,
                   spawns: ([.waves[] | select(.wave == "phase2") | .spawns[]])}]
                  + [.waves[] | select(.wave != "phase2")])' "$FPLAN" > "$FPLAN_ONE"
want "one-batch fixture: one phase2 object of 6 slots" "[6]" \
  "$(jq -c '[.waves[] | select(.wave == "phase2") | .spawns | length]' "$FPLAN_ONE")"
finalize_run "$FPLAN_ONE" "$EV_SHORT"
want "AC18: batch count does not set the intended count → exit 7" "7" "$FRC"
has "AC18: the one-batch plan names the same shortfall" "c2 intended 2 observed 1" "$FERR"
# No wave other than phase2 is counted: the six slots renamed phase3 hold two
# bundles and are not a shortfall.
FPLAN_P3="$TMP/plan-finalize-p3.json"
jq -c --argjson w "$(jq -c '[.waves[] | select(.wave == "phase2") | .wave = "phase3"]' "$FPLAN")" \
  '.waves = $w + [.waves[] | select(.wave != "phase2")]' "$FPLAN" > "$FPLAN_P3"
if jq -e '[.waves[] | .wave] | index("phase2") | not' "$FPLAN_P3" >/dev/null; then
  ok "phase3-only wave plan: no phase2 wave"
else
  bad "phase3-only wave plan build failed"
fi
jq -c '.[0:2]' "$EV_EQ" > "$TMP/ev-p3.json"
finalize_run "$FPLAN_P3" "$TMP/ev-p3.json"
want "AC18: phase3 slots are not counted: finalize exit 0" "0" "$FRC"
hasnt "AC18: phase3 slots produce no Audit Trail line" 'phase2-wave-shortfall' "$FREP"

if [ "$fail" -eq 0 ]; then
  echo "PASS"
  exit 0
fi
echo "FAIL"
exit 1