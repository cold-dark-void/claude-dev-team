#!/usr/bin/env bash
# test-enforce.sh — CDT-589-C5 advisor enforce (BC1 mis-fire clear) bite tests
# (SPEC-039 M42, SPEC-033 card compat, SPEC-009 Step 6c MUST).
#
# Machine-check: bash skills/advisor/test-enforce.sh [--ac AC<n>]  (exit 0)
#
# Per-AC run receipts (CDT-595 pattern): every check prints `ok AC<n>: <slug>`
# on stdout; a failure prints `FAIL: AC<n>: <slug>: <detail>` on stderr, from
# tests/lib/ac-receipt.sh. `--ac AC<n>` runs one AC block. The last stdout line
# is `PASS=<n> FAIL=<m>`; the `^ok ` line count equals n.
#
# Hermetic (SPEC-030 R20): the advisor state root is a scratch
# ADVISOR_STATE_ROOT; the decision-card ledger resolves through a fixture git
# repo (fake MROOT via git-common-dir); the PDH stub serves copies of the real
# gates.sh / append-card.sh / budget-check.sh. No live LLM, no spawn, no
# model-map layer is touched.

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
# shellcheck source=../../tests/lib/ac-receipt.sh
. "$ROOT/tests/lib/ac-receipt.sh"
hermetic_init
parse_ac_args "$@"

GATES="$ROOT/skills/advisor/gates.sh"
APPEND="$ROOT/skills/autopilot/append-card.sh"
READ_CARDS="$ROOT/skills/autopilot/read-cards.sh"
SA="$ROOT/skills/autopilot/self-answer.md"
D06="$ROOT/skills/orchestrate/steps/06-design.md"
SKILL="$ROOT/skills/advisor/SKILL.md"
SPEC039="$ROOT/specs/core/SPEC-039-advisor-agent.md"
SPEC033="$ROOT/specs/core/SPEC-033-autopilot-policy.md"
SPEC009="$ROOT/specs/core/SPEC-009-ticket-workflow.md"

ST="$HERMETIC_ROOT/advisor-state"
FX="$HERMETIC_ROOT/mroot"
STUB="$HERMETIC_ROOT/stub"
mkdir -p "$ST" "$FX" "$STUB"

# Fixture MROOT: the fence's append-card resolves the ledger from
# git-common-dir, so the fence runs with cwd inside the fixture repo.
git init -q "$FX"

# PDH stub: `file <rel>` maps to $STUB/<rel>. Real scripts are copied so the
# extracted fence exercises the shipped code, hermetically.
mkdir -p "$STUB/skills/autopilot" "$STUB/skills/advisor"
cp "$APPEND" "$STUB/skills/autopilot/append-card.sh"
cp "$ROOT/skills/autopilot/budget-check.sh" "$STUB/skills/autopilot/budget-check.sh"
cp "$GATES" "$STUB/skills/advisor/gates.sh"
cat > "$STUB/skills/plugin-dir.sh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "file" ]; then printf '%s\n' "${STUB:?}/$2"; exit 0; fi
printf '%s\n' "${STUB:?}"
EOF

# g — gates.sh against the scratch state root; stderr lands in g.err.
g() { ADVISOR_STATE_ROOT="$ST" timeout 20 bash "$GATES" "$@" 2>"$HERMETIC_ROOT/g.err"; }

# enforce_fence — the §3g CDT-589-C5 fence, extracted from self-answer.md.
enforce_fence() {
  awk '/CDT-589-C5 BC1 mis-fire enforce/{f=1} f{print} f&&/^fi$/{exit}' "$SA"
}

# sub_all <text> <placeholder> <value> ... — substitute fence placeholders.
sub_all() {
  local t=$1; shift
  while [ $# -ge 2 ]; do
    t=$(printf '%s' "$t" | sed "s|$1|$2|g")
    shift 2
  done
  printf '%s' "$t"
}

ledger() { printf '%s' "$FX/.claude/autopilot/$1.jsonl"; }
exhibit() { printf 'exhibit %s\n' "$1"; }

# ruling_file <ruling> <confidence> — a raw M18-shaped advisor ruling file.
ruling_file() {
  printf '{"ruling":"%s","confidence":%s,"evidence":[{"cmd":"grep -c halt 06-design.md","exit":0,"sha256":"abc","locator":"skills/orchestrate/steps/06-design.md:350"}]}\n' \
    "$1" "$2" > "$HERMETIC_ROOT/ruling.json"
  printf '%s' "$HERMETIC_ROOT/ruling.json"
}

# run_fence [key=value ...] — the §3g enforce fence with every placeholder
# substituted, executed in the fixture repo. Keys (defaults in parens):
#   run_id(enf-run) conf(93) ruling(mis-fire) gate_id(bc1-mis-fire)
#   halt_gate(plan-approve) ticket(CDT-ENF) iter(2) epoch(now)
#   ruling_file(auto from ruling/conf) enforce(unset = absent config)
run_fence() {
  local RID=enf-run CONF=93 RULING=mis-fire GATE_ID=bc1-mis-fire
  local HALT_GATE=plan-approve TICKET=CDT-ENF ITER=2
  local EPOCH RFILE="" ENFORCE_SET=0 ENFORCE_VAL=1 kv
  EPOCH=$(date +%s)
  for kv in "$@"; do
    case "$kv" in
      run_id=*) RID=${kv#*=} ;;
      conf=*) CONF=${kv#*=} ;;
      ruling=*) RULING=${kv#*=} ;;
      gate_id=*) GATE_ID=${kv#*=} ;;
      halt_gate=*) HALT_GATE=${kv#*=} ;;
      ticket=*) TICKET=${kv#*=} ;;
      iter=*) ITER=${kv#*=} ;;
      epoch=*) EPOCH=${kv#*=} ;;
      ruling_file=*) RFILE=${kv#*=} ;;
      enforce=*) ENFORCE_SET=1; ENFORCE_VAL=${kv#*=} ;;
    esac
  done
  [ -n "$RFILE" ] || RFILE=$(ruling_file "$RULING" "$CONF")
  local F ENV_U=""
  [ "$ENFORCE_SET" -eq 1 ] || ENV_U="-u ADVISOR_ENFORCE"
  F=$(sub_all "$(enforce_fence)" \
    "<gate-id>" "$GATE_ID" "<halt-gate>" "$HALT_GATE" \
    "<RUN_ID>" "$RID" "<ruling-file>" "$RFILE" "<ruling>" "$RULING" \
    "<confidence>" "$CONF" "<model>" "test-model" "<question-hash>" "qhash-enf" \
    "<ticket_id>" "$TICKET" "<iteration>" "$ITER" "<run_start_epoch>" "$EPOCH")
  if [ "$ENFORCE_SET" -eq 1 ]; then
    (cd "$FX" && env ADVISOR_STATE_ROOT="$ST" STUB="$STUB" PDH="$STUB" \
       ADVISOR_ON=true "ADVISOR_ENFORCE=$ENFORCE_VAL" timeout 20 bash -c "$F" 2>&1)
  else
    (cd "$FX" && env ADVISOR_STATE_ROOT="$ST" STUB="$STUB" PDH="$STUB" \
       ADVISOR_ON=true timeout 20 env -u ADVISOR_ENFORCE bash -c "$F" 2>&1)
  fi
}

# =============================================================================
# AC1 — default off/absent: apply refuses, mode reports shadow, the shadow
# stdout keeps applied:false, the executed fence is a no-op (no card, no line).
# =============================================================================
set_ac AC1
if want_ac; then

  OUT=$(g apply --run-id enf-a1 --bc bc1-mis-fire --ruling mis-fire --confidence 93); RC=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '.applied == false' >/dev/null 2>&1; then
    ok "ADVISOR_ENFORCE absent: apply exits 0 with applied:false (halt stands)"
    exhibit "AC1: $(printf '%s' "$OUT" | jq -r '.reason')"
  else
    bad "apply default off" "rc=$RC out=$OUT"
  fi
  OUT=$(g mode --run-id enf-a1)
  if printf '%s' "$OUT" | jq -e '.mode == "shadow"' >/dev/null 2>&1; then
    ok "ADVISOR_ENFORCE absent: mode still reports shadow"
  else
    bad "mode default shadow" "out=$OUT"
  fi

  OUT=$(g shadow --run-id enf-a1 --bc bc1-mis-fire --ruling mis-fire)
  if printf '%s' "$OUT" | jq -e '.applied == false and .mode == "shadow"' >/dev/null 2>&1; then
    ok "shadow stdout keeps applied:false — the ruling is logged, never auto-applied"
  else
    bad "shadow applied:false unchanged" "out=$OUT"
  fi
  ROW=$(sed -n '1p' "$ST/runs/enf-a1/shadow.jsonl" 2>/dev/null)
  if printf '%s' "$ROW" | jq -e '.class == "gate-shadow" and .bc == "bc1-mis-fire" and .ruling == "mis-fire"' >/dev/null 2>&1; then
    ok "the M25 shadow row is unchanged under the default-off config"
  else
    bad "shadow row unchanged" "$ROW"
  fi

  OUT=$(run_fence); RC=$?
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok "executed fence with the config absent is silent (no clear line, no stderr)"
  else
    bad "fence silent when off" "rc=$RC out=$OUT"
  fi
  if [ ! -s "$(ledger CDT-ENF)" ]; then
    ok "default off: no card, the halt stands"
  else
    bad "no card when off" "$(cat "$(ledger CDT-ENF)" 2>/dev/null)"
  fi

  F=$(sub_all "$(enforce_fence)" '<gate-id>' bc1-mis-fire)
  OUT=$(env -u ADVISOR_ON -u ADVISOR_ENFORCE timeout 20 bash -c "$F" 2>&1); RC=$?
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok "advisor off: the fence is silent before any gates.sh call"
  else
    bad "fence silent when advisor off" "rc=$RC out=$OUT"
  fi

fi

# =============================================================================
# AC2 — on + mis-fire at confidence >= 80 clears: applied:true, exactly one
# decision card (decided_by auto, actor advisor, plan-approve/proceed) and the
# one clear line; no duplicate card.
# =============================================================================
set_ac AC2
if want_ac; then

  OUT=$(ADVISOR_ENFORCE=1 g apply --run-id enf-a2 --bc bc1-mis-fire --ruling mis-fire --confidence 93); RC=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '.applied == true and .confidence == 93' >/dev/null 2>&1; then
    ok "config on + mis-fire at 93: apply exits 0 with applied:true"
    exhibit "AC2: $(printf '%s' "$OUT" | jq -r '.reason')"
  else
    bad "apply on clears" "rc=$RC out=$OUT"
  fi

  OUT=$(run_fence enforce=1 run_id=enf-a2); RC=$?
  CLEAR_LINE="plan-approve proceed: bc1 mis-fire cleared by advisor enforce (CDT-589-C5) — Step 7 proceeds"
  if [ "$RC" -eq 0 ] && [ "$OUT" = "$CLEAR_LINE" ]; then
    ok "executed fence prints exactly the one clear line (Step 7 proceeds, no task_blocked)"
    exhibit "AC2: $OUT"
  else
    bad "fence clear line" "rc=$RC out=$OUT"
  fi
  L=$(ledger CDT-ENF)
  if [ "$(wc -l < "$L" 2>/dev/null)" = "1" ]; then
    ok "the clear writes exactly ONE decision card (no duplicate human/auto card)"
  else
    bad "card count" "$(cat "$L" 2>/dev/null)"
  fi
  if jq -e 'select(.gate == "plan-approve" and .decision == "proceed" and .blocking_condition == null and .decided_by == "auto" and .actor == "advisor" and .confidence == 93 and .rationale == "trigger=a bc=bc1-mis-fire ruling=mis-fire model=test-model" and .schema_version == 1)' "$L" >/dev/null 2>&1; then
    ok "card shape: plan-approve/proceed/null, decided_by auto, actor advisor, conf 93, C5 rationale, schema_version 1"
  else
    bad "card shape" "$(cat "$L" 2>/dev/null)"
  fi
  if jq -e 'select(.advisor.trigger == "a" and .advisor.ruling == "mis-fire" and .advisor.model == "test-model" and .advisor.timeout == false)' "$L" >/dev/null 2>&1; then
    ok "M30 advisor object rides the clear card with trigger \"a\" and the mis-fire ruling"
  else
    bad "advisor object" "$(jq -c '.advisor' "$L" 2>/dev/null)"
  fi

  OUT=$(run_fence enforce=1 run_id=enf-a2b conf=100 ticket=CDT-ENF2); RC=$?
  if [ "$RC" -eq 0 ] && [ -s "$(ledger CDT-ENF2)" ]; then
    ok "confidence 100 clears (boundary accepted)"
  else
    bad "confidence 100 clears" "rc=$RC out=$OUT"
  fi
  OUT=$(run_fence enforce=1 run_id=enf-a2c conf=80 ticket=CDT-ENF3); RC=$?
  if [ "$RC" -eq 0 ] && [ -s "$(ledger CDT-ENF3)" ]; then
    ok "confidence 80 clears (threshold is >= 80)"
  else
    bad "confidence 80 clears" "rc=$RC out=$OUT"
  fi

fi

# =============================================================================
# AC3 — fail-closed: halt-stands, confidence < 80, junk/out-of-range
# confidence, missing/unparseable ruling file, and a writer-side validation
# failure each leave the halt standing (no card, no clear line).
# =============================================================================
set_ac AC3
if want_ac; then

  OUT=$(run_fence enforce=1 run_id=enf-b1 ruling=halt-stands ticket=CDT-ENF31); RC=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF 'advisor enforce: halt stands' && [ ! -s "$(ledger CDT-ENF31)" ]; then
    ok "halt-stands ruling: the halt stands, no card"
    exhibit "AC3: $OUT"
  else
    bad "halt-stands stands" "rc=$RC out=$OUT"
  fi

  OUT=$(run_fence enforce=1 run_id=enf-b2 conf=79 ticket=CDT-ENF32); RC=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF 'confidence below 80' && [ ! -s "$(ledger CDT-ENF32)" ]; then
    ok "confidence 79: the halt stands (fail-closed)"
    exhibit "AC3: $OUT"
  else
    bad "conf 79 stands" "rc=$RC out=$OUT"
  fi

  OUT=$(run_fence enforce=1 run_id=enf-b3 conf=abc ticket=CDT-ENF33); RC=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF 'halt stands' && [ ! -s "$(ledger CDT-ENF33)" ]; then
    ok "junk confidence: apply exits 64 and the fence fails closed"
  else
    bad "junk confidence fails closed" "rc=$RC out=$OUT"
  fi
  OUT=$(run_fence enforce=1 run_id=enf-b4 conf=101 ticket=CDT-ENF34); RC=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF 'halt stands' && [ ! -s "$(ledger CDT-ENF34)" ]; then
    ok "confidence 101: apply exits 64, the halt stands"
  else
    bad "conf 101 fails closed" "rc=$RC out=$OUT"
  fi

  # Missing ruling file: jq cannot build the advisor object -> halt stands.
  OUT=$(run_fence enforce=1 run_id=enf-b5 ticket=CDT-ENF35 \
    ruling_file="$HERMETIC_ROOT/no-such-ruling.json"); RC=$?
  if printf '%s' "$OUT" | grep -qF 'cannot build the advisor object' && [ ! -s "$(ledger CDT-ENF35)" ]; then
    ok "missing ruling file: no advisor object, no card, the halt stands"
  else
    bad "missing ruling file fails closed" "rc=$RC out=$OUT"
  fi

  # Writer-side validation failure: a junk iteration is a budget-check 64.
  OUT=$(run_fence enforce=1 run_id=enf-b6 iter=notanint ticket=CDT-ENF36); RC=$?
  if printf '%s' "$OUT" | grep -qF 'halt stands' && [ ! -s "$(ledger CDT-ENF36)" ]; then
    ok "writer-side validation failure (budget-check 64): the halt stands, no card"
  else
    bad "writer reject fails closed" "rc=$RC out=$OUT"
  fi

  # timeout / spawn-fail / refuse / cap: no ruling exists, the fence is never
  # reached with a mis-fire ruling — assert the prose owns the fail-closed list.
  if grep -qF 'timeout, spawn-fail, refuse, cap' "$SA" && grep -qF 'timeout, spawn-fail' "$D06"; then
    ok "timeout/spawn-fail/refuse/cap are named fail-closed in the §3g fence prose and the 6c exception"
  else
    bad "fail-closed outcome list" "missing timeout/spawn-fail/refuse/cap wording"
  fi

fi

# =============================================================================
# AC4 — scope is the 6c BC1 halt only: other allowed gate ids and other
# halted gates never clear; a denylisted id exits 64.
# =============================================================================
set_ac AC4
if want_ac; then

  for ID in bc7 bc2-diagnosis bc6-diagnosis; do
    case "$ID" in
      bc7) R=AGREE ;;
      *) R=halt ;;
    esac
    OUT=$(ADVISOR_ENFORCE=1 g apply --run-id "enf-c-$ID" --bc "$ID" --ruling "$R" --confidence 93); RC=$?
    if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '.applied == false' >/dev/null 2>&1 \
      && printf '%s' "$OUT" | jq -r '.reason' | grep -qF 'bc1-mis-fire'; then
      ok "apply on $ID: applied:false naming the 6c scope (non-6c BC1 unaffected)"
    else
      bad "apply scope $ID" "rc=$RC out=$OUT"
    fi
  done

  OUT=$(g apply --run-id enf-cd --bc bc3 --ruling halt --confidence 93); RC=$?
  if [ "$RC" -eq 64 ] && grep -qF 'M23 denylist' "$HERMETIC_ROOT/g.err"; then
    ok "apply on a denylisted id (bc3) exits 64 — structurally unreachable"
  else
    bad "denylisted id" "rc=$RC err=$(cat "$HERMETIC_ROOT/g.err")"
  fi

  OUT=$(run_fence enforce=1 run_id=enf-cg gate_id=bc7 ticket=CDT-ENF41); RC=$?
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ ! -s "$(ledger CDT-ENF41)" ]; then
    ok "fence with <gate-id> bc7: silent no-op, the halt stands"
  else
    bad "fence scope gate-id" "rc=$RC out=$OUT"
  fi
  OUT=$(run_fence enforce=1 run_id=enf-ch halt_gate=ship-choice ticket=CDT-ENF42); RC=$?
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ ! -s "$(ledger CDT-ENF42)" ]; then
    ok "fence with <halt-gate> ship-choice: silent no-op, the halt stands"
  else
    bad "fence scope halt-gate" "rc=$RC out=$OUT"
  fi
  if grep -qF 'clearing path reaches Step 8 IC spawns outside 6c' "$D06"; then
    ok "06-design.md states no clearing path reaches Step 8 spawns outside 6c"
  else
    bad "6c scope prose" "exception paragraph lacks the outside-6c scope sentence"
  fi

fi

# =============================================================================
# AC5 — M25 invariant: the mode value transitions only from the human config,
# never from code; mode reports enforce/shadow accordingly; junk config is
# off with exactly one stderr line.
# =============================================================================
set_ac AC5
if want_ac; then

  OUT=$(ADVISOR_ENFORCE=1 g mode --run-id enf-d1)
  if printf '%s' "$OUT" | jq -e '.mode == "enforce"' >/dev/null 2>&1; then
    ok "config on: mode reports enforce"
    exhibit "AC5: $OUT"
  else
    bad "mode enforce" "out=$OUT"
  fi
  i=1
  while [ "$i" -le 7 ]; do # shadow_used 7 must not change the reported mode
    ADVISOR_ENFORCE=1 g shadow --run-id enf-d1 --bc bc1-mis-fire --ruling mis-fire >/dev/null
    i=$((i + 1))
  done
  OUT=$(ADVISOR_ENFORCE=1 g mode --run-id enf-d1)
  if printf '%s' "$OUT" | jq -e '.mode == "enforce" and .shadow_used == 7' >/dev/null 2>&1; then
    ok "shadow_used 7 does not change the mode — the counter never flips it"
  else
    bad "counter never flips mode" "out=$OUT"
  fi
  OUT=$(g mode --run-id enf-d1)
  if printf '%s' "$OUT" | jq -e '.mode == "shadow"' >/dev/null 2>&1; then
    ok "unsetting the config returns the mode to shadow (config-only transition)"
  else
    bad "config-only transition" "out=$OUT"
  fi
  if [ "$(grep -ci 'widen' "$GATES")" -eq 0 ]; then
    ok "no widen transition exists in gates.sh (M25 source invariant intact)"
  else
    bad "no widen transition" "$(grep -in 'widen' "$GATES")"
  fi

  OUT=$(ADVISOR_ENFORCE=junk g mode --run-id enf-d2); RC=$?
  ERR=$(cat "$HERMETIC_ROOT/g.err")
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '.mode == "shadow"' >/dev/null 2>&1 \
    && [ "$(printf '%s\n' "$ERR" | grep -c 'ADVISOR_ENFORCE')" -eq 1 ]; then
    ok "junk config: off + exactly one stderr line, never parsed as code"
    exhibit "AC5: $ERR"
  else
    bad "junk config handling" "rc=$RC out=$OUT err=$ERR"
  fi
  OUT=$(ADVISOR_ENFORCE=junk g apply --run-id enf-d3 --bc bc1-mis-fire --ruling mis-fire --confidence 93)
  if printf '%s' "$OUT" | jq -e '.applied == false' >/dev/null 2>&1; then
    ok "junk config: apply refuses (fail-closed to the halt)"
  else
    bad "junk apply refuses" "out=$OUT"
  fi
  for V in 0 false off; do
    OUT=$(ADVISOR_ENFORCE=$V g apply --run-id enf-d4 --bc bc1-mis-fire --ruling mis-fire --confidence 93)
    if printf '%s' "$OUT" | jq -e '.applied == false' >/dev/null 2>&1; then
      ok "explicit off value '$V': apply refuses"
    else
      bad "explicit off $V" "out=$OUT"
    fi
  done

fi

# =============================================================================
# AC6 — distinct paths, distinct provenance: the C5 clear card (trigger a)
# vs the C3 demotion card (trigger d); the enforce path writes no
# class-verify.jsonl row.
# =============================================================================
set_ac AC6
if want_ac; then

  if grep -qF 'trigger=a bc=bc1-mis-fire ruling=mis-fire' "$SA" && grep -qF 'trigger=d ruling=not-auth-relevant' "$SPEC039"; then
    ok "the two rationales are distinct (a in the engine doc, d in SPEC-039 M40/AC6)"
  else
    bad "distinct rationales" "missing a/d rationale lines"
  fi
  if grep -qF 'trigger: "a"' "$SA" && grep -qF 'trigger: "d"' "$SPEC039"; then
    ok "the two advisor objects carry distinct triggers (a in the engine doc, d in SPEC-039)"
  else
    bad "distinct triggers" "missing trigger \"a\" / trigger \"d\""
  fi
  ENF_BLOCK=$(enforce_fence)
  if printf '%s' "$ENF_BLOCK" | grep -qF 'class-verify'; then
    bad "no class-verify row" "the enforce fence writes a class-verify artifact"
  else
    ok "the enforce fence writes no class-verify.jsonl row (distinct from the C3 log)"
  fi
  if grep -qF 'distinct paths' "$D06" && grep -qF 'distinct paths' "$SPEC039"; then
    ok "SPEC-039 and 06-design.md state the clear and the demotion are distinct paths"
  else
    bad "distinct-paths prose" "missing distinct-path wording"
  fi

fi

# =============================================================================
# AC7 — card-schema compatibility: append-card accepts trigger-a
# halt-stands|mis-fire objects, still rejects halt/decompose on trigger a,
# keeps trigger-b/c on the M18 vocabulary, and read-cards.sh reads the card.
# =============================================================================
set_ac AC7
if want_ac; then

  card_write() { # card_write <advisor-object-json> <ticket>
    local OBJ="$HERMETIC_ROOT/adv-obj.json"; printf '%s' "$1" > "$OBJ"
    (cd "$FX" && STUB="$STUB" PDH="$STUB" timeout 20 bash "$APPEND" \
      orchestrate "$2" plan-approve proceed auto null 93 null enf-g 2 "$(( $(date +%s) - 5 ))" advisor \
      "trigger=a bc=bc1-mis-fire ruling=mis-fire model=test-model" \
      --advisor-json "$OBJ") 2>"$HERMETIC_ROOT/ac7.err"
  }
  ADVISOR_OBJ='{"ruling":"mis-fire","corrected_claim":null,"evidence":[{"cmd":"grep","exit":0,"sha256":"a","locator":"x:1"}],"model":"m","evidence_over_memory":true,"question_hash":"q","trigger":"a","cache_hit":false,"timeout":false,"marker":null}'
  OUT=$(card_write "$ADVISOR_OBJ" CDT-ENF7); RC=$?
  if [ "$RC" -eq 0 ] && [ -s "$(ledger CDT-ENF7)" ]; then
    ok "append-card accepts a trigger-a advisor object with ruling mis-fire"
  else
    bad "accept trigger-a mis-fire" "rc=$RC out=$OUT err=$(cat "$HERMETIC_ROOT/ac7.err")"
  fi
  ADVISOR_OBJ='{"ruling":"halt-stands","corrected_claim":null,"evidence":[],"model":"m","evidence_over_memory":true,"question_hash":"q","trigger":"a","cache_hit":false,"timeout":false,"marker":null}'
  OUT=$(card_write "$ADVISOR_OBJ" CDT-ENF7B); RC=$?
  if [ "$RC" -eq 0 ] && [ -s "$(ledger CDT-ENF7B)" ]; then
    ok "append-card accepts a trigger-a advisor object with ruling halt-stands"
  else
    bad "accept trigger-a halt-stands" "rc=$RC out=$OUT err=$(cat "$HERMETIC_ROOT/ac7.err")"
  fi
  for R in halt decompose; do
    ADVISOR_OBJ="{\"ruling\":\"$R\",\"corrected_claim\":null,\"evidence\":[],\"model\":\"m\",\"evidence_over_memory\":true,\"question_hash\":\"q\",\"trigger\":\"a\",\"cache_hit\":false,\"timeout\":false,\"marker\":null}"
    OUT=$(card_write "$ADVISOR_OBJ" CDT-ENF7R); RC=$?
    if [ "$RC" -eq 64 ] && [ ! -s "$(ledger CDT-ENF7R)" ]; then
      ok "append-card rejects a trigger-a object with ruling '$R' (BC2/BC6 vocabulary)"
    else
      bad "reject trigger-a $R" "rc=$RC out=$OUT err=$(cat "$HERMETIC_ROOT/ac7.err")"
    fi
  done
  ADVISOR_OBJ='{"ruling":"auth-relevant","corrected_claim":null,"evidence":[],"model":"m","evidence_over_memory":true,"question_hash":"q","trigger":"b","cache_hit":false,"timeout":false,"marker":null}'
  OUT=$(card_write "$ADVISOR_OBJ" CDT-ENF7B2); RC=$?
  if [ "$RC" -eq 64 ]; then
    ok "append-card still rejects the trigger-d vocabulary on trigger b (M18 kept)"
  else
    bad "trigger-b vocabulary unchanged" "rc=$RC out=$OUT"
  fi
  L=$(ledger CDT-ENF7)
  if jq -e 'select(.schema_version == 1 and .advisor.ruling == "mis-fire")' "$L" >/dev/null 2>&1; then
    ok "the written clear card keeps schema_version 1"
  else
    bad "schema_version 1" "$(cat "$L" 2>/dev/null)"
  fi
  OUT=$(cd "$FX" && CLAUDE_PLUGIN_ROOT="$ROOT" timeout 20 bash "$READ_CARDS" CDT-ENF7 2>&1); RC=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '.[] | select(.decision == "proceed" and .advisor.ruling == "mis-fire")' >/dev/null 2>&1; then
    ok "read-cards.sh reads the clear card unchanged"
  else
    bad "read-cards" "rc=$RC out=$OUT"
  fi
  if grep -qF 'halt-stands|mis-fire' "$SPEC033" && grep -qF 'CDT-589-C5' "$SPEC033"; then
    ok "SPEC-033 documents the accept/reject cases with schema_version unchanged"
  else
    bad "SPEC-033 card-compat note" "missing the trigger-a accept wording"
  fi

fi

# =============================================================================
# AC8 — config validation before use; the M23 denylist, M24 vocabularies,
# M26 caps and ADVISOR_SHADOW_N semantics are unchanged.
# =============================================================================
set_ac AC8
if want_ac; then

  OUT=$(ADVISOR_ENFORCE='$(rm -rf x)' g mode --run-id enf-h1); RC=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '.mode == "shadow"' >/dev/null 2>&1; then
    ok "an injection-shaped config value is off, never parsed as code"
  else
    bad "injection-shaped config" "rc=$RC out=$OUT"
  fi
  OUT=$(ADVISOR_ENFORCE=true g apply --run-id enf-h2 --bc bc1-mis-fire --ruling halt-stands --confidence 93)
  if printf '%s' "$OUT" | jq -e '.applied == false' >/dev/null 2>&1; then
    ok "M24 vocabulary still enforced: halt-stands never clears"
  else
    bad "M24 vocabulary" "out=$OUT"
  fi
  OUT=$(ADVISOR_ENFORCE=true g apply --run-id enf-h3 --bc bc1-mis-fire --ruling proceed --confidence 93); RC=$?
  if [ "$RC" -eq 64 ]; then
    ok "an out-of-vocabulary ruling still exits 64 (M24 unchanged)"
  else
    bad "out-of-vocab 64" "rc=$RC out=$OUT"
  fi
  OUT=$(ADVISOR_ENFORCE=true ADVISOR_SHADOW_N=2 g mode --run-id enf-h4)
  if printf '%s' "$OUT" | jq -e '.shadow_n == 2 and .mode == "enforce"' >/dev/null 2>&1; then
    ok "ADVISOR_SHADOW_N still only lowers the window (both knobs compose)"
  else
    bad "ADVISOR_SHADOW_N unchanged" "out=$OUT"
  fi
  OUT=$(ADVISOR_ENFORCE=true g ruling --bc bc1-mis-fire --ruling mis-fire)
  if printf '%s' "$OUT" | jq -e '.accepted == true' >/dev/null 2>&1; then
    ok "gates.sh ruling (M24 checker) is unchanged by enforce"
  else
    bad "ruling subcommand unchanged" "out=$OUT"
  fi

fi

# =============================================================================
# AC9 — the suite itself: hermetic, receipt-based, --ac filtered; the six
# named case families are exhibited by the blocks above.
# =============================================================================
set_ac AC9
if want_ac; then

  if grep -qF 'tests/lib/ac-receipt.sh' "$0" && grep -qF 'tests/lib/hermetic.sh' "$0"; then
    ok "the suite sources ac-receipt.sh and hermetic.sh (--ac filtered, scratch state root)"
  else
    bad "suite harness" "$0"
  fi
  if [ -d "$ST" ] && [ -d "$FX/.git" ]; then
    ok "hermetic fixtures: scratch ADVISOR_STATE_ROOT + fixture-ledger MROOT, no live LLM"
  else
    bad "hermetic fixtures" "$ST $FX"
  fi
  if grep -qF 'default-off' "$SPEC039" && grep -qF 'on-clears' "$SPEC039"; then
    ok "SPEC-039 AC9 names the six case families (default-off, on-clears, below-80, non-6c, provenance, mode-report)"
  else
    bad "six named families" "SPEC-039 AC9 wording"
  fi

fi

# =============================================================================
# AC10 — SKILL documents ADVISOR_ENFORCE + apply; no new Surface, no new
# flag, no new agent role.
# =============================================================================
set_ac AC10
if want_ac; then

  if grep -qF 'ADVISOR_ENFORCE' "$SKILL" && grep -qF 'apply --run-id ID --bc bc1-mis-fire' "$SKILL"; then
    ok "the advisor SKILL documents ADVISOR_ENFORCE (default off, valid values, junk handling) and apply"
  else
    bad "SKILL documents enforce" "$SKILL"
  fi
  if grep -qF 'never parsed as code' "$SKILL"; then
    ok "the SKILL states junk is never parsed as code"
  else
    bad "SKILL junk wording" "missing 'never parsed as code'"
  fi
  if [ -z "$(ls "$ROOT/commands" 2>/dev/null | grep -iE 'enforce|advisor')" ]; then
    ok "no new command Surface (commands/ has no enforce/advisor entry)"
  else
    bad "no new Surface" "$(ls "$ROOT/commands" | grep -iE 'enforce|advisor')"
  fi
  PF_HITS=0
  for PF in "$ROOT/skills/orchestrate/parse-flags.sh" "$ROOT/skills/autopilot/parse-flags.sh" "$ROOT/skills/epic/parse-flags.sh"; do
    [ -f "$PF" ] || continue
    grep -qF 'ADVISOR_ENFORCE' "$PF" && PF_HITS=1
  done
  if [ "$PF_HITS" -eq 0 ]; then
    ok "no new flag on any command (no parse-flags.sh carries an ADVISOR_ENFORCE key)"
  else
    bad "no new flag" "a parse-flags.sh gained a key"
  fi
  if [ -f "$ROOT/agents/advisor.md" ] && [ ! -f "$ROOT/agents/enforce.md" ]; then
    ok "no new agent role (the single advisor agent is unchanged)"
  else
    bad "no new agent role" "agents/ changed"
  fi
  if grep -qF '### CDT-589-C5' "$SPEC039" && grep -qF 'M42' "$SPEC039"; then
    ok "SPEC-039 carries the CDT-589-C5 section and the M42 rule"
  else
    bad "SPEC-039 section" "missing ### CDT-589-C5 / M42"
  fi
  if grep -qF 'CDT-589-C5' "$SPEC009" && grep -qF 'CDT-589-C5' "$D06"; then
    ok "SPEC-009 6c MUST and the 06-design.md exception name CDT-589-C5"
  else
    bad "SPEC-009 / 06-design wiring" "missing CDT-589-C5"
  fi

fi

ac_finish
