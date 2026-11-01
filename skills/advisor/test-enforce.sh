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
ASK="$ROOT/skills/advisor/ask.sh"
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
cp "$ASK" "$STUB/skills/advisor/ask.sh"
# The model map reports the advisor unmapped unless ADVISOR_MODEL overrides.
mkdir -p "$STUB/skills/model-map"
printf '#!/usr/bin/env bash\ncase "${1:-}" in --mapped) echo unmapped ;; *) exit 0 ;; esac\n' \
  > "$STUB/skills/model-map/resolve-model.sh"
cat > "$STUB/skills/plugin-dir.sh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "file" ]; then printf '%s\n' "${STUB:?}/$2"; exit 0; fi
printf '%s\n' "${STUB:?}"
EOF

# g — gates.sh against the scratch state root; stderr lands in g.err.
g() { ADVISOR_STATE_ROOT="$ST" timeout 20 bash "$GATES" "$@" 2>"$HERMETIC_ROOT/g.err"; }

# ask [model] <args...> — ask.sh in the fixture repo (scratch state root).
# A non-empty model arg takes the override path; empty takes env -u, the
# unmapped-advisor refuse path.
ask() {
  local m="$1"; shift
  if [ -n "$m" ]; then
    (cd "$FX" && env -u ADVISOR_ENFORCE ADVISOR_STATE_ROOT="$ST" STUB="$STUB" PDH="$STUB" \
       ADVISOR_MODEL="$m" timeout 20 bash "$ASK" "$@") 2>"$HERMETIC_ROOT/ask.err"
  else
    (cd "$FX" && env -u ADVISOR_MODEL -u ADVISOR_ENFORCE ADVISOR_STATE_ROOT="$ST" STUB="$STUB" \
       PDH="$STUB" timeout 20 bash "$ASK" "$@") 2>"$HERMETIC_ROOT/ask.err"
  fi
}

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

  # Span receipt: the AC1 invocation form, executed with the config absent.
  OUT=$(g apply --run-id ID --bc bc1-mis-fire --ruling mis-fire --confidence 93); RC=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '.applied == false' >/dev/null 2>&1; then
    ok "AC1: executed gates.sh apply --run-id ID --bc bc1-mis-fire --ruling mis-fire --confidence 93 with ADVISOR_ENFORCE unset — applied: false, exit 0"
    exhibit "AC1: $OUT"
  else
    bad "AC1 invocation form applied:false" "rc=$RC out=$OUT"
  fi

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
  # Span receipts: field bytes, on-values, and the rationale template, read
  # back from the executed clear card.
  FIELDS=$(jq -r '"gate: \(.gate) / decision: \(.decision) / blocking_condition: \(.blocking_condition) / decided_by: \(.decided_by) / actor: \(.actor) / schema_version \(.schema_version)"' "$L" 2>/dev/null)
  if printf '%s' "$FIELDS" | grep -qF 'gate: plan-approve / decision: proceed / blocking_condition: null / decided_by: auto / actor: advisor'; then
    ok "AC2: executed clear card field bytes read back from the ledger — gate: plan-approve, decision: proceed, blocking_condition: null, decided_by: auto, actor: advisor (schema_version 1); actual: $FIELDS"
    exhibit "AC2: $FIELDS"
  else
    bad "clear card field bytes" "got=$FIELDS"
  fi
  RAT2=$(jq -r '.rationale // empty' "$L" 2>/dev/null)
  if [ "$RAT2" = "trigger=a bc=bc1-mis-fire ruling=mis-fire model=test-model" ]; then
    ok "AC2: executed clear card rationale realizes the template trigger=a bc=bc1-mis-fire ruling=mis-fire model=<m> — actual ledger bytes: $RAT2"
  else
    bad "clear rationale template" "got=$RAT2"
  fi
  OUT=$(ADVISOR_ENFORCE=1 g apply --run-id enf-a2s --bc bc1-mis-fire --ruling mis-fire --confidence 93); RC=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '.applied == true' >/dev/null 2>&1; then
    ok "AC2: executed apply --bc bc1-mis-fire with a valid on config (1|true|on) exits 0 applied: true — the ruling is mis-fire at confidence >= 80"
  else
    bad "applied true span receipt" "rc=$RC out=$OUT"
  fi
  ADV=$(jq -c '.advisor' "$L" 2>/dev/null)
  if printf '%s' "$ADV" | jq -e '.trigger == "a"' >/dev/null 2>&1; then
    ok "AC2: executed clear card M30 advisor object carries trigger: \"a\" (jq read-back: $ADV)"
  else
    bad "trigger a span receipt" "$ADV"
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
  # Span receipt: the executed fail-closed outcome is applied: false.
  OUT=$(ADVISOR_ENFORCE=1 g apply --run-id enf-b2s --bc bc1-mis-fire --ruling mis-fire --confidence 79); RC=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '.applied == false' >/dev/null 2>&1; then
    ok "AC3: executed fail-closed apply outcomes report applied: false — the halt stands (confidence < 80 exhibited; no card)"
    exhibit "AC3: $OUT"
  else
    bad "applied false span receipt" "rc=$RC out=$OUT"
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

  # timeout / spawn-fail / refuse / cap: each upstream condition is produced
  # by the real seam, then the §3g fence/apply path is executed — the halt
  # stands (applied:false / halt-stands), no card.
  #
  # timeout: the real finalize --timeout records status only, never a ruling.
  ask test-model probe --trigger a --question "bc1 mis-fire second opinion (timeout case)?" --bc 1 --run-id enf-t1 >/dev/null 2>&1
  ask "" finalize --run-id enf-t1 --timeout >/dev/null 2>&1; RC=$?
  OUT=$(run_fence enforce=1 run_id=enf-t1 ruling_file="$HERMETIC_ROOT/no-such-ruling.json" ticket=CDT-ENF37); RC2=$?
  if [ "$RC" -eq 0 ] && [ -f "$ST/runs/enf-t1/status.json" ] && [ ! -f "$ST/runs/enf-t1/ruling.json" ] \
    && [ "$RC2" -eq 0 ] && printf '%s' "$OUT" | grep -qF 'halt stands' && [ ! -s "$(ledger CDT-ENF37)" ]; then
    ok "executed timeout path — finalize --timeout records status only (no ruling.json), the fence runs and the halt stands (no card)"
    exhibit "AC3: $OUT"
  else
    bad "executed timeout path" "rc=$RC rc2=$RC2 out=$OUT status=$(cat "$ST/runs/enf-t1/status.json" 2>/dev/null)"
  fi

  # spawn-fail: the real finalize --spawn-fail is the same never-cached arm.
  ask test-model probe --trigger a --question "bc1 mis-fire second opinion (spawn-fail case)?" --bc 1 --run-id enf-t2 >/dev/null 2>&1
  ask "" finalize --run-id enf-t2 --spawn-fail >/dev/null 2>&1; RC=$?
  OUT=$(run_fence enforce=1 run_id=enf-t2 ruling_file="$HERMETIC_ROOT/no-such-ruling.json" ticket=CDT-ENF38); RC2=$?
  if [ "$RC" -eq 0 ] && [ -f "$ST/runs/enf-t2/status.json" ] && [ ! -f "$ST/runs/enf-t2/ruling.json" ] \
    && [ "$RC2" -eq 0 ] && printf '%s' "$OUT" | grep -qF 'halt stands' && [ ! -s "$(ledger CDT-ENF38)" ]; then
    ok "executed spawn-fail path — finalize --spawn-fail caches no ruling, the fence runs and the halt stands (no card)"
  else
    bad "executed spawn-fail path" "rc=$RC rc2=$RC2 out=$OUT"
  fi

  # refuse: the real probe with the advisor unmapped emits action refuse.
  OUT=$(ask "" probe --trigger a --question "bc1 mis-fire second opinion (refuse case)?" --bc 1 --run-id enf-t3); RC=$?
  OUT2=$(run_fence enforce=1 run_id=enf-t3 ruling_file="$HERMETIC_ROOT/no-such-ruling.json" ticket=CDT-ENF39); RC2=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '.action == "refuse"' >/dev/null 2>&1 \
    && [ "$RC2" -eq 0 ] && printf '%s' "$OUT2" | grep -qF 'halt stands' && [ ! -s "$(ledger CDT-ENF39)" ]; then
    ok "executed refuse path — the unmapped probe emits action refuse, no spawn-request ruling, the fence leaves the halt stands (no card)"
    exhibit "AC3: refuse -> $(printf '%s' "$OUT" | jq -r '.reason') | $OUT2"
  else
    bad "executed refuse path" "rc=$RC out=$OUT rc2=$RC2 out2=$OUT2"
  fi

  # cap: the real probe exhausts the trigger-d reserve (M26) in the same run.
  ask test-model probe --trigger d --question "cap probe one" --run-id enf-t4 >/dev/null 2>&1
  OUT=$(ask test-model probe --trigger d --question "cap probe two" --run-id enf-t4); RC=$?
  OUT2=$(run_fence enforce=1 run_id=enf-t4 ruling_file="$HERMETIC_ROOT/no-such-ruling.json" ticket=CDT-ENF310); RC2=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '.action == "cap"' >/dev/null 2>&1 \
    && [ "$RC2" -eq 0 ] && printf '%s' "$OUT2" | grep -qF 'halt stands' && [ ! -s "$(ledger CDT-ENF310)" ]; then
    ok "executed cap path — the second probe returns action cap, no spawn, the fence leaves the halt stands (no card)"
    exhibit "AC3: cap -> $(printf '%s' "$OUT" | jq -r '.reason') | $OUT2"
  else
    bad "executed cap path" "rc=$RC out=$OUT rc2=$RC2 out2=$OUT2"
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
  # Span receipt: all three non-6c allowed ids in one executed line.
  OK7=0; OK2=0; OK6=0
  ADVISOR_ENFORCE=1 g apply --run-id enf-c-s1 --bc bc7 --ruling AGREE --confidence 93 | jq -e '.applied == false' >/dev/null 2>&1 && OK7=1
  ADVISOR_ENFORCE=1 g apply --run-id enf-c-s2 --bc bc2-diagnosis --ruling halt --confidence 93 | jq -e '.applied == false' >/dev/null 2>&1 && OK2=1
  ADVISOR_ENFORCE=1 g apply --run-id enf-c-s3 --bc bc6-diagnosis --ruling halt --confidence 93 | jq -e '.applied == false' >/dev/null 2>&1 && OK6=1
  if [ "$OK7" -eq 1 ] && [ "$OK2" -eq 1 ] && [ "$OK6" -eq 1 ]; then
    ok "AC4: executed apply on bc7, bc2-diagnosis, bc6-diagnosis — each exits 0 with applied: false naming the 6c-only scope (non-6c BC1 unaffected)"
  else
    bad "non-6c ids span receipt" "bc7=$OK7 bc2=$OK2 bc6=$OK6"
  fi

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
  # Span receipt: the fence's narrow scope, executed on both no-op runs.
  O1=$(run_fence enforce=1 run_id=enf-cg2 gate_id=bc7 ticket=CDT-ENF43); RC=$?
  O2=$(run_fence enforce=1 run_id=enf-ch2 halt_gate=ship-choice ticket=CDT-ENF44); RC2=$?
  if [ "$RC" -eq 0 ] && [ -z "$O1" ] && [ ! -s "$(ledger CDT-ENF43)" ] \
    && [ "$RC2" -eq 0 ] && [ -z "$O2" ] && [ ! -s "$(ledger CDT-ENF44)" ]; then
    ok "AC4: executed fence is a silent no-op unless the gate id is bc1-mis-fire and the halted gate is plan-approve (both no-op runs left no card)"
  else
    bad "no-op span receipt" "rc=$RC o1=$O1 rc2=$RC2 o2=$O2"
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
  # Executed both-ways receipt: the subprocess form itself, rc-checked.
  OUT=$(ADVISOR_ENFORCE=1 g mode --run-id enf-d1m); RC=$?
  OUT2=$(g mode --run-id enf-d1m); RC2=$?
  if [ "$RC" -eq 0 ] && [ "$RC2" -eq 0 ] \
    && printf '%s' "$OUT" | jq -e '.mode == "enforce"' >/dev/null 2>&1 \
    && printf '%s' "$OUT2" | jq -e '.mode == "shadow"' >/dev/null 2>&1; then
    ok "gates.sh mode reports enforce with a valid on config and shadow otherwise (executed subprocess form, both rc 0)"
    exhibit "AC5: gates.sh mode on -> $OUT | off -> $OUT2"
  else
    bad "gates.sh mode both ways" "rc=$RC rc2=$RC2 out=$OUT out2=$OUT2"
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

  # Executed provenance pair. (a) The real C3 demotion path: trigger-d probe
  # + finalize with card context writes the demotion card with trigger "d"
  # (and its class-verify.jsonl precision row) in the same scratch fixtures.
  ask test-model probe --trigger d --question "Is this ticket actually about authentication? Rule not-auth-relevant only when the staged evidence proves otherwise." --run-id enf-e1 >/dev/null 2>&1
  printf '{"ruling":"not-auth-relevant","confidence":85,"evidence":[{"cmd":"grep -c auth ticket.md","exit":0,"sha256":"abc","locator":"ticket.md:1"}]}\n' \
    > "$HERMETIC_ROOT/ruling-d.json"
  ask "" finalize --run-id enf-e1 --ruling-file "$HERMETIC_ROOT/ruling-d.json" \
    --card-workflow orchestrate --card-ticket CDT-ENF-D --card-gate plan-approve \
    --card-iteration 2 --card-run-start-epoch "$(date +%s)" >/dev/null 2>&1; RC=$?
  LD=$(ledger CDT-ENF-D)
  if [ "$RC" -eq 0 ] && [ "$(wc -l < "$LD" 2>/dev/null)" = "1" ] \
    && jq -e 'select(.advisor.trigger == "d" and .decision == "proceed" and .actor == "advisor")' "$LD" >/dev/null 2>&1 \
    && [ "$(wc -l < "$ST/runs/enf-e1/class-verify.jsonl" 2>/dev/null)" = "1" ]; then
    ok "executed C3 demotion finalize writes the distinct trigger-d card (decision proceed, actor advisor) plus its class-verify.jsonl row"
    exhibit "AC6: demotion card advisor -> $(jq -c '.advisor | {trigger, ruling}' "$LD")"
  else
    bad "executed demotion card" "rc=$RC ledger=$(cat "$LD" 2>/dev/null)"
  fi
  # The rationale field bytes, read back from the executed card: the real
  # finalize composes `trigger=<t> ruling=<r> model=<m>` with the actual
  # model name — printed here as written, never a fabricated placeholder.
  RAT=$(jq -r '.rationale // empty' "$LD" 2>/dev/null)
  if [ "$RAT" = "trigger=d ruling=not-auth-relevant model=test-model" ]; then
    ok "executed demotion card rationale field bytes read back from the ledger: $RAT"
    exhibit "AC6: demotion card rationale -> $RAT"
  else
    bad "executed demotion rationale bytes" "got=$RAT ledger=$(cat "$LD" 2>/dev/null)"
  fi
  # Span receipts: both trigger values and both rationale templates, read
  # back from the two executed cards.
  DADV=$(jq -c '.advisor' "$LD" 2>/dev/null)
  if printf '%s' "$DADV" | jq -e '.trigger == "d"' >/dev/null 2>&1; then
    ok "AC6: executed demotion card M30 advisor object carries trigger: \"d\" (jq read-back: $DADV)"
  else
    bad "trigger d span receipt" "$DADV"
  fi
  if [ "$RAT" = "trigger=d ruling=not-auth-relevant model=test-model" ]; then
    ok "AC6: executed demotion rationale realizes the template trigger=d ruling=not-auth-relevant model=<m> — actual ledger bytes: $RAT"
  else
    bad "demotion rationale template" "got=$RAT"
  fi
  LA=$(ledger CDT-ENF9)
  if [ ! -s "$LA" ]; then # the AC blocks are independent under --ac: run the clear
    run_fence enforce=1 run_id=enf-e2s ticket=CDT-ENF9 >/dev/null 2>&1
  fi
  RATA=$(jq -r '.rationale // empty' "$LA" 2>/dev/null)
  ADVA=$(jq -c '.advisor // empty' "$LA" 2>/dev/null)
  if [ "$RATA" = "trigger=a bc=bc1-mis-fire ruling=mis-fire model=test-model" ] \
    && printf '%s' "$ADVA" | jq -e '.trigger == "a"' >/dev/null 2>&1; then
    ok "AC6: executed clear card carries trigger: \"a\" and its rationale realizes the template trigger=a bc=bc1-mis-fire ruling=mis-fire model=<m> — actual ledger bytes: $RATA"
  else
    bad "clear card span receipts" "rat=$RATA adv=$ADVA"
  fi
  # (b) The executed enforce fence writes no class-verify.jsonl row: the clear
  # case runs, then the scratch run dir is checked for the artifact.
  OUT=$(run_fence enforce=1 run_id=enf-e2); RC=$?
  CLEAR_LINE="plan-approve proceed: bc1 mis-fire cleared by advisor enforce (CDT-589-C5) — Step 7 proceeds"
  if [ "$RC" -eq 0 ] && [ "$OUT" = "$CLEAR_LINE" ] && [ ! -e "$ST/runs/enf-e2/class-verify.jsonl" ] \
    && [ -s "$(ledger CDT-ENF)" ]; then
    ok "executed enforce fence writes no class-verify.jsonl row (test ! -e on the scratch run dir) while its own card carries trigger a"
  else
    bad "executed fence class-verify absence" "rc=$RC out=$OUT"
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
  # Span receipts: the writer named in the executed accept/reject matrix.
  ADVISOR_OBJ='{"ruling":"mis-fire","corrected_claim":null,"evidence":[],"model":"m","evidence_over_memory":true,"question_hash":"q","trigger":"a","cache_hit":false,"timeout":false,"marker":null}'
  OUT=$(card_write "$ADVISOR_OBJ" CDT-ENF7S); RC=$?
  ADVISOR_OBJ='{"ruling":"halt","corrected_claim":null,"evidence":[],"model":"m","evidence_over_memory":true,"question_hash":"q","trigger":"a","cache_hit":false,"timeout":false,"marker":null}'
  OUT2=$(card_write "$ADVISOR_OBJ" CDT-ENF7S2); RC2=$?
  ADVISOR_OBJ='{"ruling":"decompose","corrected_claim":null,"evidence":[],"model":"m","evidence_over_memory":true,"question_hash":"q","trigger":"a","cache_hit":false,"timeout":false,"marker":null}'
  OUT3=$(card_write "$ADVISOR_OBJ" CDT-ENF7S3); RC3=$?
  if [ "$RC" -eq 0 ] && [ "$RC2" -eq 64 ] && [ "$RC3" -eq 64 ] \
    && [ ! -s "$(ledger CDT-ENF7S2)" ] && [ ! -s "$(ledger CDT-ENF7S3)" ]; then
    ok "AC7: executed append-card.sh accept/reject matrix — trigger-a mis-fire accepted (exit 0), rulings halt and decompose rejected (exit 64, no card)"
  else
    bad "append-card span receipt" "rc=$RC rc2=$RC2 rc3=$RC3"
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
  # Span receipt: the executed denylist path names M23.
  OUT=$(ADVISOR_ENFORCE=true g apply --run-id enf-h3m --bc bc3 --ruling halt --confidence 93); RC=$?
  ERR=$(cat "$HERMETIC_ROOT/g.err")
  if [ "$RC" -eq 64 ] && printf '%s' "$ERR" | grep -qF 'M23 denylist'; then
    ok "AC8: M23 denylist unchanged — executed apply --bc bc3 exits 64 with the stable refusal reason ($ERR)"
    exhibit "AC8: M23 -> $ERR"
  else
    bad "M23 span receipt" "rc=$RC err=$ERR"
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
  # Executed M26 caps receipt: the real probe seam exhausts the trigger-d
  # reserve (1 per run) and ADVISOR_MAX_CALLS still lowers only the global 5.
  ask test-model probe --trigger d --question "M26 reserve probe" --run-id enf-h5 >/dev/null 2>&1
  OUT=$(ask test-model probe --trigger d --question "M26 reserve probe two" --run-id enf-h5); RC=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '.action == "cap"' >/dev/null 2>&1 \
    && printf '%s' "$OUT" | jq -r '.reason' | grep -qF 'reserve exhausted (1)'; then
    ok "executed M26 cap path — the trigger-d reserve exhausts to action cap with reason 'reserve exhausted (1)' (M26 unchanged by enforce)"
    exhibit "AC8: M26 -> $(printf '%s' "$OUT" | jq -r '.reason')"
  else
    bad "executed M26 caps" "rc=$RC out=$OUT"
  fi
  OUT=$(ADVISOR_MAX_CALLS=2 ask test-model probe --trigger a --question "M26 global one" --run-id enf-h6 >/dev/null 2>&1; ADVISOR_MAX_CALLS=2 ask test-model probe --trigger a --question "M26 global two" --run-id enf-h6 >/dev/null 2>&1; ADVISOR_MAX_CALLS=2 ask test-model probe --trigger a --question "M26 global three" --run-id enf-h6); RC=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -r '.reason' | grep -qF 'global per-run cap exhausted (2)'; then
    ok "executed M26 global cap — ADVISOR_MAX_CALLS=2 lowers only the global per-run total (cap reason exhibited)"
  else
    bad "executed M26 global cap" "rc=$RC out=$OUT err=$(cat "$HERMETIC_ROOT/ask.err" 2>/dev/null)"
  fi

fi

# =============================================================================
# AC9 — the suite itself: hermetic, receipt-based, --ac filtered. Each of the
# six named case families is re-executed here and named in its ok line, the
# fixture-ledger MROOT resolution is exhibited, and the no-live-LLM absence
# is checked on the executed artifacts.
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
  # Span receipts: the suite's own path, the shared receipt lib, and the
  # filtered-run form. The nested --ac AC9 run is guarded against recursion.
  if [ -n "${ENF_NESTED:-}" ]; then
    RC1=0 # nested filtered run: the outer run owns the receipt
  else
    ENF_NESTED=1 timeout 60 bash "$0" --ac AC9 >/dev/null 2>&1 || RC1=$?
    RC1=${RC1:-0}
    if [ "$RC1" -eq 0 ] && [ -f "$0" ] && [ -f "$ROOT/tests/lib/ac-receipt.sh" ]; then
      ok "AC9: executed skills/advisor/test-enforce.sh (rc 0) sourcing tests/lib/ac-receipt.sh with --ac AC<n> filtered runs — the nested --ac AC9 run is that filtered run"
      exhibit "AC9: skills/advisor/test-enforce.sh --ac AC9 -> rc $RC1"
    else
      bad "suite-path span receipts" "rc1=${RC1:-?}"
    fi
  fi

  # (a) Families re-executed, one ok line per family with its run output.
  # family default-off
  OUT=$(g apply --run-id enf-i1 --bc bc1-mis-fire --ruling mis-fire --confidence 93); RC=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '.applied == false' >/dev/null 2>&1; then
    ok "family default-off executed — apply with ADVISOR_ENFORCE absent exits 0 applied:false ($OUT)"
  else
    bad "family default-off" "rc=$RC out=$OUT"
  fi
  # family on-clears
  OUT=$(ADVISOR_ENFORCE=1 g apply --run-id enf-i2 --bc bc1-mis-fire --ruling mis-fire --confidence 93); RC=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '.applied == true' >/dev/null 2>&1; then
    ok "family on-clears executed — apply with ADVISOR_ENFORCE=1 exits 0 applied:true ($OUT)"
  else
    bad "family on-clears" "rc=$RC out=$OUT"
  fi
  # family on-below-80-stands
  OUT=$(ADVISOR_ENFORCE=1 g apply --run-id enf-i3 --bc bc1-mis-fire --ruling mis-fire --confidence 79); RC=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '.applied == false' >/dev/null 2>&1; then
    ok "family on-below-80-stands executed — apply at confidence 79 exits 0 applied:false ($OUT)"
  else
    bad "family on-below-80-stands" "rc=$RC out=$OUT"
  fi
  # family non-6c BC1 unaffected
  OUT=$(ADVISOR_ENFORCE=1 g apply --run-id enf-i4 --bc bc2-diagnosis --ruling halt --confidence 93); RC=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '.applied == false' >/dev/null 2>&1; then
    ok "family non-6c BC1 unaffected executed — apply on bc2-diagnosis exits 0 applied:false naming the 6c-only scope"
  else
    bad "family non-6c BC1 unaffected" "rc=$RC out=$OUT"
  fi
  # family card provenance — the family's own clear fence runs first (the
  # AC blocks are independent under --ac), then the card is read back.
  OUT=$(run_fence enforce=1 run_id=enf-i6 ticket=CDT-ENF9); RC=$?
  if [ "$RC" -eq 0 ] && jq -e 'select(.advisor.trigger == "a" and .advisor.ruling == "mis-fire" and .decided_by == "auto" and .actor == "advisor")' "$(ledger CDT-ENF9)" >/dev/null 2>&1; then
    ok "family card provenance executed — the clear fence ran and its ledger card reads back with advisor.trigger a, decided_by auto, actor advisor"
  else
    bad "family card provenance" "rc=$RC out=$OUT ledger=$(cat "$(ledger CDT-ENF9)" 2>/dev/null)"
  fi
  # family mode-report
  OUT=$(ADVISOR_ENFORCE=1 g mode --run-id enf-i5); RC=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '.mode == "enforce"' >/dev/null 2>&1; then
    ok "family mode-report executed — gates.sh mode exits 0 with mode enforce under the on config ($OUT)"
  else
    bad "family mode-report" "rc=$RC out=$OUT"
  fi

  # (b) Fixture-ledger MROOT resolution, exhibited: append-card resolves the
  # ledger from git-common-dir of the cwd — the fixture repo, not this tree.
  RESOLVED=$(cd "$FX" && git rev-parse --git-common-dir 2>/dev/null) \
    && RESOLVED=$(cd "$FX" && cd "$(dirname "$RESOLVED")" && pwd) || RESOLVED=""
  if [ "$RESOLVED" = "$FX" ] && [ -s "$(ledger CDT-ENF9)" ] && [ "$(dirname "$(ledger CDT-ENF9)")" = "$FX/.claude/autopilot" ]; then
    ok "fixture-ledger MROOT resolved — git-common-dir of the fixture cwd is $FX and the executed cards live under $FX/.claude/autopilot (never this checkout)"
  else
    bad "fixture-ledger MROOT" "resolved=$RESOLVED ledger=$(ledger CDT-ENF9)"
  fi

  # (c) No-live-LLM absence check on the executed artifacts: the fence text
  # and gates.sh carry no Agent-tool / spawn mechanism, and the ask.sh spawn
  # arm was never executed — every run dir here holds at most counters,
  # spawn-requests written by the probe, and logs, never a live agent.
  FENCE_TXT=$(enforce_fence)
  if ! printf '%s' "$FENCE_TXT" | grep -qE 'subagent_type|Agent tool|claude -p|grok ' \
    && ! grep -qE 'subagent_type|Agent tool' "$GATES" \
    && ! grep -qE 'curl |https?://' "$GATES"; then
    ok "no live LLM — the executed fence text and gates.sh carry no Agent tool, no subagent_type, no network call (absence verified by grep over the executed artifacts)"
  else
    bad "no live LLM" "spawn mechanism found in the executed artifacts"
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
  # Span receipt: the commands/*.md count is asserted on the real tree.
  CMDCOUNT=$(ls "$ROOT/commands"/*.md 2>/dev/null | wc -l)
  if [ -d "$ROOT/commands" ] && [ "$CMDCOUNT" -gt 0 ] \
    && [ -z "$(ls "$ROOT/commands" 2>/dev/null | grep -iE 'enforce|advisor')" ]; then
    ok "AC10: executed commands/*.md existence assertion — no commands/*.md added (count $CMDCOUNT, Surface unchanged; no new agent role either)"
  else
    bad "commands span receipt" "count=$CMDCOUNT"
  fi
  if grep -qF 'ADVISOR_ENFORCE' "$SKILL" && grep -qF 'apply --run-id ID --bc bc1-mis-fire' "$SKILL"; then
    ok "executed skills/advisor/SKILL.md check: the advisor SKILL documents ADVISOR_ENFORCE (default off, valid values, junk handling) and apply"
  else
    bad "SKILL documents enforce" "$SKILL"
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
