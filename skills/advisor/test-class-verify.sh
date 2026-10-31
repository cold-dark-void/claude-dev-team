#!/usr/bin/env bash
# test-class-verify.sh — CDT-589-C3 advisor class-verify (trigger d) bite tests
# (SPEC-039 trigger d / M38-M41, SPEC-009 Step 6c MUST).
#
# Machine-check: bash skills/advisor/test-class-verify.sh [--ac AC<n>]  (exit 0)
#
# Per-AC run receipts (CDT-595 pattern): every check prints `ok AC<n>: <slug>`
# on stdout; a failure prints `FAIL: AC<n>: <slug>: <detail>` on stderr, from
# tests/lib/ac-receipt.sh. `--ac AC<n>` runs one AC block. The last stdout line
# is `PASS=<n> FAIL=<m>`; the `^ok ` line count equals n.
#
# Hermetic (SPEC-030 R20): the advisor state root is a scratch
# ADVISOR_STATE_ROOT; the decision-card ledger resolves through a fixture git
# repo (fake MROOT via git-common-dir); the PDH stub serves copies of the real
# append-card.sh / budget-check.sh / gates.sh / ask.sh / SKILL.md plus a
# resolver that reports the advisor unmapped. No live LLM, no spawn, no
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

ASK="$ROOT/skills/advisor/ask.sh"
GATES="$ROOT/skills/advisor/gates.sh"
SKILL="$ROOT/skills/advisor/SKILL.md"
D06="$ROOT/skills/orchestrate/steps/06-design.md"
SPEC039="$ROOT/specs/core/SPEC-039-advisor-agent.md"
SPEC009="$ROOT/specs/core/SPEC-009-ticket-workflow.md"
SUITE="$HERE/test-class-verify.sh"

ST="$HERMETIC_ROOT/advisor-state"
FX="$HERMETIC_ROOT/mroot"
STUB="$HERMETIC_ROOT/stub"
mkdir -p "$ST" "$FX" "$STUB"

# Fixture MROOT: append-card.sh (invoked by finalize) resolves the ledger from
# git-common-dir, so finalize runs with cwd inside the fixture repo.
git init -q "$FX"

# PDH stub: `file <rel>` maps to $STUB/<rel>. Real scripts are copied below so
# the extracted 6c fences exercise the shipped code, hermetically.
mkdir -p "$STUB/skills/autopilot" "$STUB/skills/model-map" "$STUB/skills/advisor"
cp "$ROOT/skills/autopilot/append-card.sh" "$STUB/skills/autopilot/append-card.sh"
cp "$ROOT/skills/autopilot/budget-check.sh" "$STUB/skills/autopilot/budget-check.sh"
cp "$GATES" "$STUB/skills/advisor/gates.sh"
cp "$ASK" "$STUB/skills/advisor/ask.sh"
cp "$SKILL" "$STUB/skills/advisor/SKILL.md"
# The model map reports the advisor unmapped unless the caller passes a model.
printf '#!/usr/bin/env bash\ncase "${1:-}" in --mapped) echo unmapped ;; *) exit 0 ;; esac\n' \
  > "$STUB/skills/model-map/resolve-model.sh"
cat > "$STUB/skills/plugin-dir.sh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "file" ]; then printf '%s\n' "${STUB:?}/$2"; exit 0; fi
printf '%s\n' "${STUB:?}"
EOF

CV_MODEL="${CV_MODEL:-test-model}"

# cv_probe_raw <args...> — raw ask.sh probe, cwd in the fixture repo, scratch
# state root. Stderr lands in probe.err; stdout on the caller's stdout. An
# empty CV_MODEL probes without ADVISOR_MODEL (the unmapped-advisor refuse).
cv_probe_raw() {
  if [ -n "$CV_MODEL" ]; then
    (cd "$FX" && ADVISOR_STATE_ROOT="$ST" STUB="$STUB" PDH="$STUB" \
       ADVISOR_MODEL="$CV_MODEL" timeout 20 bash "$ASK" probe "$@") \
      2>"$HERMETIC_ROOT/probe.err"
  else
    (cd "$FX" && env -u ADVISOR_MODEL ADVISOR_STATE_ROOT="$ST" STUB="$STUB" PDH="$STUB" \
       timeout 20 bash "$ASK" probe "$@") \
      2>"$HERMETIC_ROOT/probe.err"
  fi
}

# cv_probe <run-id> <question> — the trigger-d probe used by most cases.
cv_probe() { cv_probe_raw --trigger d --question "$2" --run-id "$1"; }

# cv_finalize <run-id> <ruling> <confidence> [card args...] — finalize inside
# the fixture repo (the ledger lands under $FX/.claude/autopilot/).
cv_finalize() {
  local rid=$1 ruling=$2 conf=$3; shift 3
  printf '{"ruling":"%s","confidence":%s,"evidence":[{"cmd":"grep -c auth ticket.md","exit":0,"sha256":"abc","locator":"ticket.md:1"}]}\n' \
    "$ruling" "$conf" > "$HERMETIC_ROOT/ruling.json"
  (cd "$FX" && ADVISOR_STATE_ROOT="$ST" STUB="$STUB" PDH="$STUB" \
     timeout 20 bash "$ASK" finalize --run-id "$rid" \
     --ruling-file "$HERMETIC_ROOT/ruling.json" "$@") 2>"$HERMETIC_ROOT/fin.err"
}

# The extracted 6c fences (kept in sync with 06-design.md exactly).
probe_fence() {
  awk 'index($0, "if [ \"${ADVISOR_ON:-}\" = \"true\" ] && [ \"${ADVISOR_SKIP_TRIGGER:-}\" != \"1\" ] && [ \"${TICKET_CLASS:-}\" = \"auth-secrets\" ]") == 1 {f=1} f{print} f&&/^fi$/{exit}' "$D06"
}
demote_fence() {
  # Anchored on the demotion-fence comment marker so the pre-existing
  # trigger-(b) fence (same guard shape) is never extracted instead.
  awk '/CDT-589-C3 demotion decision/{f=1} f{print} f&&/^fi$/{exit}' "$D06"
}

ledger() { printf '%s' "$FX/.claude/autopilot/$1.jsonl"; }
exhibit() { printf 'exhibit %s\n' "$1"; }

Q="Is this ticket actually about authentication? Rule not-auth-relevant only when the staged evidence proves otherwise."

# =============================================================================
# AC1 — trigger d is accepted by ask.sh probe (a|b|c|d) and gates.sh allow
# (class-verify); the trigger-d vocabulary is exactly auth-relevant /
# not-auth-relevant with confidence 0-100 (anything else exits 64 in finalize
# and gates.sh ruling); the M23 denylist is unchanged; the trigger-d reserve
# is 1 per run; the global cap stays 5; the question text has one named home.
# =============================================================================
set_ac AC1
if want_ac; then

  OUT=$(cv_probe cv-a1 "$Q a1"); RC=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '.action == "spawn"' >/dev/null 2>&1; then
    ok "ask.sh probe --trigger d accepted (a|b|c|d) -> spawn"
    exhibit "AC1: ask.sh probe --trigger d -> $(printf '%s' "$OUT" | jq -c '{action, model}')"
  else
    bad "ask.sh probe --trigger d accepted" "rc=$RC out=$OUT"
  fi

  cv_probe_raw --trigger e --question "$Q" >/dev/null; RC=$?
  if [ "$RC" -eq 64 ] && grep -qF 'a|b|c|d' "$HERMETIC_ROOT/probe.err"; then
    ok "probe rejects a trigger outside a|b|c|d with exit 64"
  else
    bad "probe rejects trigger outside a|b|c|d" "rc=$RC err=$(cat "$HERMETIC_ROOT/probe.err")"
  fi

  OUT=$(ADVISOR_STATE_ROOT="$ST" timeout 20 bash "$GATES" allow --bc class-verify); RC=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '.gate == "class-verify" and .allowed == true' >/dev/null 2>&1; then
    ok "gates.sh allow --bc class-verify -> allowed: true"
  else
    bad "gates.sh allow --bc class-verify" "rc=$RC out=$OUT"
  fi

  for R in not-auth-relevant auth-relevant; do
    OUT=$(ADVISOR_STATE_ROOT="$ST" timeout 20 bash "$GATES" ruling --bc class-verify --ruling "$R"); RC=$?
    if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '.accepted == true' >/dev/null 2>&1; then
      ok "gates.sh ruling accepts $R"
    else
      bad "gates.sh ruling accepts $R" "rc=$RC out=$OUT"
    fi
  done
  for R in AGREE halt auth-relevants "" "not-auth-relevant "; do
    OUT=$(ADVISOR_STATE_ROOT="$ST" timeout 20 bash "$GATES" ruling --bc class-verify --ruling "$R" 2>/dev/null); RC=$?
    if [ "$RC" -eq 64 ]; then ok "gates.sh ruling rejects '$R' with 64"; else bad "gates.sh ruling rejects '$R'" "rc=$RC out=$OUT"; fi
  done

  # finalize validates the trigger-d vocabulary (exit 64 otherwise).
  cv_probe cv-vocab "$Q vocab" >/dev/null
  cv_finalize cv-vocab AGREE 85 --card-workflow orchestrate --card-ticket CDT-CVV \
    --card-gate plan-approve --card-iteration 1 --card-run-start-epoch "$(date +%s)" >/dev/null 2>&1
  RC=$?
  if [ "$RC" -eq 64 ] && grep -qF 'auth-relevant|not-auth-relevant' "$HERMETIC_ROOT/fin.err"; then
    ok "ask.sh finalize rejects a non-trigger-d ruling (AGREE) with 64"
    exhibit "AC1: ask.sh finalize trigger-d vocab -> $(cat "$HERMETIC_ROOT/fin.err")"
  else
    bad "finalize rejects AGREE on trigger d" "rc=$RC err=$(cat "$HERMETIC_ROOT/fin.err")"
  fi
  cv_finalize cv-vocab maybe 85 >/dev/null 2>&1
  [ $? -eq 64 ] && ok "finalize rejects ruling 'maybe' with 64" || bad "finalize rejects 'maybe'" "see fin.err"
  cv_finalize cv-vocab not-auth-relevant 101 >/dev/null 2>&1
  [ $? -eq 64 ] && ok "finalize rejects confidence 101 with 64" || bad "finalize rejects conf 101" "see fin.err"
  cv_finalize cv-vocab not-auth-relevant abc >/dev/null 2>&1
  [ $? -eq 64 ] && ok "finalize rejects non-integer confidence with 64" || bad "finalize rejects conf abc" "see fin.err"

  # Boundary acceptance: the AC1 vocabulary is confidence 0-100 inclusive, so
  # the edges are ACCEPTED (by finalize, the layer that owns the check).
  cv_probe cv-bnd0 "$Q bnd0" >/dev/null 2>&1
  cv_finalize cv-bnd0 not-auth-relevant 0 >/dev/null 2>&1
  [ $? -eq 0 ] && ok "finalize accepts boundary confidence 0" || bad "finalize accepts conf 0" "see fin.err"
  cv_probe cv-bnd100 "$Q bnd100" >/dev/null 2>&1
  cv_finalize cv-bnd100 not-auth-relevant 100 >/dev/null 2>&1
  [ $? -eq 0 ] && ok "finalize accepts boundary confidence 100" || bad "finalize accepts conf 100" "see fin.err"

  # M23 denylist unchanged.
  for ID in bc3 bc8 bc6-extension bc1-as-human-preference; do
    OUT=$(ADVISOR_STATE_ROOT="$ST" timeout 20 bash "$GATES" allow --bc "$ID" 2>"$HERMETIC_ROOT/g.err"); RC=$?
    if [ "$RC" -eq 64 ] && grep -qF 'SPEC-039 M23 denylist' "$HERMETIC_ROOT/g.err"; then
      ok "SPEC-039 M23 denylist unchanged: $ID still refused with 64"
    else
      bad "M23 denylist unchanged: $ID" "rc=$RC out=$OUT"
    fi
  done

  # Reserve d=1: a second trigger-d spawn-probe in the same run caps.
  cv_probe cv-d1 "$Q d1" >/dev/null
  OUT=$(cv_probe cv-d1 "$Q 2"); RC=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '.action == "cap"' >/dev/null 2>&1; then
    ok "trigger d reserve is 1 probe per run (second probe -> cap)"
    exhibit "AC1: reserve d=1 -> $(printf '%s' "$OUT" | jq -r '.reason')"
  else
    bad "trigger d reserve" "rc=$RC out=$OUT"
  fi

  # Global cap mechanism unchanged: ADVISOR_MAX_CALLS still lowers only the
  # global (never the reserves), and the shipped GLOBAL_LIMIT stays 5. Trigger
  # b (reserve 4) stays under its reserve so the global is the binder.
  for i in 1 2; do ADVISOR_MAX_CALLS=2 cv_probe_raw --trigger b --question "mc q$i" --run-id cv-mc >/dev/null 2>&1; done
  OUT=$(ADVISOR_MAX_CALLS=2 cv_probe_raw --trigger b --question "mc q3" --run-id cv-mc)
  if printf '%s' "$OUT" | jq -r '.reason' | grep -qF 'global per-run cap exhausted (2)'; then
    ok "ADVISOR_MAX_CALLS still lowers only the global cap (d included)"
  else
    bad "global cap lowering" "out=$OUT"
  fi
  if grep -qF 'GLOBAL_LIMIT=5' "$ASK"; then
    ok "global per-run cap stays 5 (GLOBAL_LIMIT=5 in ask.sh)"
    exhibit "AC1: global cap 5 unchanged -> GLOBAL_LIMIT=5; ADVISOR_MAX_CALLS=2 run: $(printf '%s' "$OUT" | jq -r '.reason')"
  else
    bad "global cap 5 unchanged" "GLOBAL_LIMIT=5 not found in ask.sh"
  fi

  # One named home for the question text: the SKILL trigger table line, and
  # the question body appears nowhere else in the plugin docs.
  QHOME=$(sed -n 's/^CLASS_VERIFY_QUESTION=//p' "$SKILL" | head -n 1)
  if [ -n "$QHOME" ]; then
    ok "question text home: CLASS_VERIFY_QUESTION= in the advisor SKILL trigger table"
    exhibit "AC1: CLASS_VERIFY_QUESTION= -> $QHOME"
  else
    bad "question text home" "no CLASS_VERIFY_QUESTION= line in the SKILL trigger table"
  fi
  if [ -n "$QHOME" ] && grep -qF "$QHOME" "$D06"; then
    bad "question text home" "06-design.md copies the question body (must reference the SKILL)"
  else
    ok "question body is not duplicated into 06-design.md"
  fi

fi

# =============================================================================
# AC2 — Step 6c runs at most ONE class-verify probe per run on
# ticket_class: auth-secrets, before any /council invoke.
# =============================================================================
set_ac AC2
if want_ac; then

  FENCE=$(probe_fence)
  if [ -n "$FENCE" ]; then
    ok "6c class-verify probe fence extractable"
  else
    bad "6c class-verify probe fence extractable" "guard line not found in 06-design.md"
  fi
  case "$FENCE" in
    *"--trigger d"*) ok "probe fence invokes ask.sh probe --trigger d" ;;
    *) bad "probe fence invokes --trigger d" "fence text lacks --trigger d" ;;
  esac

  ST2="$HERMETIC_ROOT/state-ac2"
  EV="$HERMETIC_ROOT/ac2-evidence"; mkdir -p "$EV"
  printf 'title: add a token refresh endpoint\nbody: rotates secrets\n' > "$EV/ticket.md"
  OUT=$(cd "$FX" && env ADVISOR_STATE_ROOT="$ST2" STUB="$STUB" PDH="$STUB" \
    ADVISOR_ON=true TICKET_CLASS=auth-secrets CV_EVIDENCE_DIR="$EV" ADVISOR_MODEL=test-model \
    bash -c "$FENCE" 2>&1); RC=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '.action == "spawn"' >/dev/null 2>&1; then
    ok "executed probe fence probes once on auth-secrets with the advisor on"
    exhibit "AC2: fence probe -> $(printf '%s' "$OUT" | jq -c '{action, trigger}')"
  else
    bad "executed probe fence probes once" "rc=$RC out=$OUT"
  fi
  # At most one per run: the same run-id cannot spawn a second probe.
  OUT2=$(cd "$FX" && env ADVISOR_STATE_ROOT="$ST2" STUB="$STUB" PDH="$STUB" \
    ADVISOR_ON=true TICKET_CLASS=auth-secrets CV_EVIDENCE_DIR="$EV" ADVISOR_MODEL=test-model \
    bash -c "$FENCE" 2>&1); RC2=$?
  if [ "$RC2" -eq 0 ] && printf '%s' "$OUT2" | jq -r '.action' | grep -qF 'cap'; then
    ok "second probe in the same run returns action: cap (at most one probe per run)"
  else
    bad "second probe capped" "rc=$RC2 out=$OUT2"
  fi

  # The fence sits BEFORE the /council invoke in 06-design.md.
  FI=$(grep -n 'class-verify probe' "$D06" | head -n 1 | cut -d: -f1)
  CI=$(grep -n 'invoke `/council --plan' "$D06" | head -n 1 | cut -d: -f1)
  if [ -n "$FI" ] && [ -n "$CI" ] && [ "$FI" -lt "$CI" ]; then
    ok "probe fence precedes the /council invoke (line $FI < $CI)"
  else
    bad "probe fence precedes the /council invoke" "fence=$FI council=$CI"
  fi

  # The question travels from the one home into the spawn request.
  SQ=$(ADVISOR_STATE_ROOT="$ST2" jq -r '.question' "$ST2/runs/<RUN_ID>/spawn-request.json" 2>/dev/null)
  SQ2=$(sed -n 's/^CLASS_VERIFY_QUESTION=//p' "$SKILL" | head -n 1)
  if [ -n "$SQ2" ] && [ "$SQ" = "$SQ2" ]; then
    ok "spawn-request question equals the SKILL trigger-table question"
  else
    bad "spawn-request question" "got [$SQ] want [$SQ2]"
  fi

fi

# =============================================================================
# AC3 — ticket_class: none -> zero advisor calls, zero cards, zero added lines.
# =============================================================================
set_ac AC3
if want_ac; then

  FENCE=$(probe_fence)
  ST3="$HERMETIC_ROOT/state-ac3"
  OUT=$(cd "$FX" && env ADVISOR_STATE_ROOT="$ST3" STUB="$STUB" PDH="$STUB" \
    ADVISOR_ON=true TICKET_CLASS=none bash -c "$FENCE" 2>&1); RC=$?
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok "ticket_class: none: zero added lines (fence silent)"
  else
    bad "ticket_class none: zero added lines" "rc=$RC out=$OUT"
  fi
  if [ ! -e "$ST3/runs" ]; then
    ok "ticket_class: none: zero advisor calls (no runs state created)"
  else
    bad "ticket_class none: zero advisor calls" "$(ls "$ST3/runs" 2>/dev/null)"
  fi
  if [ ! -e "$FX/.claude/autopilot" ] || [ -z "$(ls "$FX/.claude/autopilot" 2>/dev/null)" ]; then
    ok "ticket_class: none: zero cards (no ledger written)"
  else
    bad "ticket_class none: zero cards" "$(ls "$FX/.claude/autopilot" 2>/dev/null)"
  fi
  if grep -qF 'Step 6c (security council): skipped — ticket_class: none' "$D06"; then
    ok "the existing ticket_class none skip line is unchanged"
  else
    bad "existing none skip line" "not found in 06-design.md"
  fi

fi

# =============================================================================
# AC4 — not-auth-relevant at confidence >= 80 demotes: the 6c skip line names
# class-verify, the run continues to Step 7, the council is NOT run.
# =============================================================================
set_ac AC4
if want_ac; then

  DFENCE=$(demote_fence)
  if printf '%s' "$DFENCE" | grep -qF 'class-verify: not-auth-relevant'; then
    ok "demotion fence extractable and prints the class-verify skip line"
  else
    bad "demotion fence extractable" "no class-verify skip line in the demotion fence"
  fi

  RFILE="$HERMETIC_ROOT/ac4-ruling.json"
  sub_fence() { # sub_fence <confidence> <ruling> — demotion fence with the ruling file substituted
    printf '{"ruling":"%s","confidence":%s}\n' "$2" "$1" > "$RFILE"
    local SUB=${DFENCE//"<class-verify-ruling-file>"/$RFILE}
    (cd "$FX" && env ADVISOR_ON=true STUB="$STUB" bash -c "$SUB" 2>&1)
  }
  OUT=$(sub_fence 85 not-auth-relevant); RC=$?
  if [ "$RC" -eq 0 ] && [ "$OUT" = "Step 6c (security council): skipped — class-verify: not-auth-relevant" ]; then
    ok "not-auth-relevant at confidence >= 80 prints the class-verify skip line"
    exhibit "AC4: $OUT"
  else
    bad "not-auth-relevant at 80 demotes" "rc=$RC out=$OUT"
  fi
  OUT=$(sub_fence 79 not-auth-relevant)
  if [ -z "$OUT" ]; then ok "confidence 79 prints nothing (council)"; else bad "confidence 79" "out=$OUT"; fi
  OUT=$(sub_fence 95 auth-relevant)
  if [ -z "$OUT" ]; then ok "auth-relevant at any confidence prints nothing (council)"; else bad "auth-relevant 95" "out=$OUT"; fi
  OUT=$(sub_fence abc not-auth-relevant)
  if [ -z "$OUT" ]; then ok "junk confidence prints nothing (fail-closed)"; else bad "junk confidence" "out=$OUT"; fi

  if grep -q 'council NOT run' "$D06" && grep -q 'continue to Step 7' "$D06"; then
    ok "6c prose: demotion continues to Step 7, council NOT run"
  else
    bad "6c prose demotion outcome" "missing 'council NOT run' / 'continue to Step 7'"
  fi

fi

# =============================================================================
# AC5 — a demotion writes exactly one decision card (gate: plan-approve,
# decision: proceed, blocking_condition: null, actor: advisor, confidence =
# the ruling's, rationale naming trigger + ruling + model) and logs the
# ruling for precision measurement.
# =============================================================================
set_ac AC5
if want_ac; then

  cv_probe cv-demote "$Q demote" >/dev/null
  cv_finalize cv-demote not-auth-relevant 85 \
    --card-workflow orchestrate --card-ticket CDT-CV5 \
    --card-gate plan-approve --card-iteration 3 --card-run-start-epoch "$(date +%s)" >/dev/null 2>&1
  RC=$?
  L=$(ledger CDT-CV5)
  if [ "$RC" -eq 0 ] && [ "$(wc -l < "$L" 2>/dev/null)" = "1" ]; then
    ok "demotion finalize writes exactly one decision card"
    exhibit "AC5: card -> $(cat "$L")"
  else
    bad "demotion card count" "rc=$RC ledger=$(cat "$L" 2>/dev/null) err=$(cat "$HERMETIC_ROOT/fin.err")"
  fi
  if [ -f "$L" ] && jq -e 'select(.gate == "plan-approve" and .decision == "proceed" and .blocking_condition == null and .actor == "advisor" and .confidence == 85 and .rationale == "trigger=d ruling=not-auth-relevant model=test-model")' "$L" >/dev/null 2>&1; then
    ok "card shape: gate: plan-approve, decision: proceed, blocking_condition: null, actor: advisor, confidence 85, rationale trigger=d ruling=not-auth-relevant model=test-model"
  else
    bad "card shape" "$(cat "$L" 2>/dev/null)"
  fi
  if [ -f "$L" ] && jq -e 'select(.advisor.trigger == "d" and .advisor.ruling == "not-auth-relevant" and .advisor.cache_hit == false)' "$L" >/dev/null 2>&1; then
    ok "M30 advisor object rides the card with trigger: \"d\" and the trigger-d ruling"
  else
    bad "M30 advisor object" "$(jq -c '.advisor' "$L" 2>/dev/null)"
  fi

  LOG="$ST/runs/cv-demote/class-verify.jsonl"
  if [ "$(wc -l < "$LOG" 2>/dev/null)" = "1" ] && jq -e 'select(.class == "class-verify" and .decision == "demote" and .ruling == "not-auth-relevant" and .confidence == 85)' "$LOG" >/dev/null 2>&1; then
    ok "ruling logged for precision measurement in runs/<run_id>/class-verify.jsonl: one class-verify row with decision: demote"
    exhibit "AC5: log -> $(cat "$LOG")"
  else
    bad "class-verify log row" "$(cat "$LOG" 2>/dev/null)"
  fi

fi

# =============================================================================
# AC6 — demotion-only: the verifier never raises; none is never auth-secrets
# and the ruling never rewrites ticket_class.
# =============================================================================
set_ac AC6
if want_ac; then

  SECTION=$(awk '/^#### Step 6c class-verify probe/{f=1; print; next} f&&/^### /{exit} f{print}' "$D06")
  if printf '%s' "$SECTION" | grep -qi 'demotion-only' && printf '%s' "$SECTION" | grep -qi 'never raised'; then
    ok "6c section states demotion-only and that none is never raised"
  else
    bad "demotion-only prose" "section lacks the demotion-only / never-raised statement"
  fi
  if printf '%s' "$SECTION" | grep -qE 'TICKET_CLASS=auth-secrets|ticket_class=auth-secrets'; then
    bad "no ticket_class rewrite" "the section assigns ticket_class"
  else
    ok "no ticket_class rewrite: the section only compares, never assigns"
  fi

  # Engine side: a demotion finalize touches only run state — no plan/class
  # artifact is written anywhere (the run dir holds ruling/status/log/cache).
  cv_probe cv-noerase "$Q noerase" >/dev/null
  cv_finalize cv-noerase not-auth-relevant 90 >/dev/null 2>&1
  FILES=$(ls "$ST/runs/cv-noerase" 2>/dev/null | sort | tr '\n' ' ')
  case "$FILES" in
    *plan*|*ticket-class*) bad "no class rewrite artifacts" "$FILES" ;;
    *) ok "demotion finalize writes no ticket_class artifact (run dir: $FILES)" ;;
  esac
  exhibit "AC6: demotion-only — none is never raised to auth-secrets; run dir: $FILES"

fi

# =============================================================================
# AC7 — fail-closed to the council (never a halt): auth-relevant at any
# confidence, confidence < 80, advisor off/unmapped, probe refuse/cap,
# finalize timeout/spawn-fail; cap exhaustion on this trigger emits no BC8.
# =============================================================================
set_ac AC7
if want_ac; then

  cv_probe cv-fc "$Q fc" >/dev/null
  cv_finalize cv-fc auth-relevant 95 \
    --card-workflow orchestrate --card-ticket CDT-CV7 \
    --card-gate plan-approve --card-iteration 1 --card-run-start-epoch "$(date +%s)" >/dev/null 2>&1
  RC=$?
  if [ "$RC" -eq 0 ] && [ ! -s "$(ledger CDT-CV7)" ]; then
    ok "auth-relevant finalize: council path, no card written"
  else
    bad "auth-relevant no card" "rc=$RC ledger=$(cat "$(ledger CDT-CV7)" 2>/dev/null)"
  fi
  LOG7="$ST/runs/cv-fc/class-verify.jsonl"
  jq -e 'select(.decision == "council")' "$LOG7" >/dev/null 2>&1 \
    && ok "non-demotion logged with decision: council" || bad "council log row" "$(cat "$LOG7" 2>/dev/null)"

  cv_probe cv-fc2 "$Q fc2" >/dev/null
  cv_finalize cv-fc2 not-auth-relevant 79 \
    --card-workflow orchestrate --card-ticket CDT-CV7 \
    --card-gate plan-approve --card-iteration 1 --card-run-start-epoch "$(date +%s)" >/dev/null 2>&1
  if [ ! -s "$(ledger CDT-CV7)" ]; then
    ok "confidence < 80 finalize: council path, no card written"
  else
    bad "conf<80 no card" "$(cat "$(ledger CDT-CV7)" 2>/dev/null)"
  fi

  # Unmapped advisor -> refuse (never a tier default, never a spawn).
  OUT=$(CV_MODEL= cv_probe_raw --trigger d --question "$Q" --run-id cv-refuse)
  if printf '%s' "$OUT" | jq -e '.action == "refuse" and .reason == "advisor not configured"' >/dev/null 2>&1; then
    ok "advisor off/unmapped -> action refuse (fail-closed to the council)"
    exhibit "AC7: refuse -> $(printf '%s' "$OUT" | jq -c '{action, reason}')"
  else
    bad "unmapped refuse" "out=$OUT err=$(cat "$HERMETIC_ROOT/probe.err")"
  fi

  # Timeout records status only, never caches a partial ruling.
  cv_probe cv-timeout "$Q timeout" >/dev/null
  (cd "$FX" && ADVISOR_STATE_ROOT="$ST" STUB="$STUB" PDH="$STUB" \
    timeout 20 bash "$ASK" finalize --run-id cv-timeout --timeout) >/dev/null 2>&1
  HASH=$(jq -r '.question_hash' "$ST/runs/cv-timeout/spawn-request.json")
  if jq -r '.status' "$ST/runs/cv-timeout/status.json" 2>/dev/null | grep -qF 'timeout' \
    && [ ! -f "$ST/cache/$HASH.json" ]; then
    ok "finalize --timeout records status only and never caches (retry is a fresh spawn)"
  else
    bad "timeout no cache" "status=$(cat "$ST/runs/cv-timeout/status.json" 2>/dev/null) cache=$ST/cache/$HASH.json"
  fi
  (cd "$FX" && ADVISOR_STATE_ROOT="$ST" STUB="$STUB" PDH="$STUB" \
    timeout 20 bash "$ASK" finalize --run-id cv-timeout --spawn-fail) >/dev/null 2>&1
  if jq -r '.status' "$ST/runs/cv-timeout/status.json" 2>/dev/null | grep -qF 'spawn-fail'; then
    ok "finalize --spawn-fail records status (council path)"
  else
    bad "spawn-fail status" "$(cat "$ST/runs/cv-timeout/status.json" 2>/dev/null)"
  fi

  # Cap exhaustion on this trigger emits no BC8: the §3g BC8 fence stays a|b|c.
  if grep -qF 'case "<trigger>" in a|b|c)' "$ROOT/skills/autopilot/self-answer.md"; then
    ok "the BC8 unavailable fence stays a|b|c — trigger d can never emit BC8"
  else
    bad "BC8 fence a|b|c" "self-answer.md §3g guard changed"
  fi
  if grep -q 'never BC8' "$D06" && grep -q 'never a halt' "$D06"; then
    ok "6c prose states the fail-closed outcome: council, never a halt, never BC8"
  else
    bad "fail-closed prose" "06-design.md lacks the never-a-halt / never-BC8 statement"
  fi

fi

# =============================================================================
# AC8 — advisor off: the 6c path is byte-identical to today (no probe line,
# no card).
# =============================================================================
set_ac AC8
if want_ac; then

  FENCE=$(probe_fence)
  DFENCE=$(demote_fence)
  ST8="$HERMETIC_ROOT/state-ac8"
  OUT=$(cd "$FX" && env -u ADVISOR_ON -u ADVISOR_SKIP_TRIGGER -u TICKET_CLASS \
    ADVISOR_STATE_ROOT="$ST8" STUB="$STUB" PDH="$STUB" bash -c "$FENCE" 2>&1); RC=$?
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok "ADVISOR_ON unset: probe fence is silent (no probe line)"
  else
    bad "advisor off probe fence" "rc=$RC out=$OUT"
  fi
  OUT=$(cd "$FX" && env -u TICKET_CLASS ADVISOR_ON=true ADVISOR_SKIP_TRIGGER=1 \
    ADVISOR_STATE_ROOT="$ST8" STUB="$STUB" PDH="$STUB" bash -c "$FENCE" 2>&1); RC=$?
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok "ADVISOR_SKIP_TRIGGER=1 bypass: probe fence silent"
  else
    bad "bypass probe fence" "rc=$RC out=$OUT"
  fi
  OUT=$(cd "$FX" && env -u ADVISOR_ON -u ADVISOR_SKIP_TRIGGER \
    ADVISOR_STATE_ROOT="$ST8" STUB="$STUB" bash -c "$DFENCE" 2>&1); RC=$?
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok "advisor off: demotion fence is silent (no card, no line)"
  else
    bad "advisor off demotion fence" "rc=$RC out=$OUT"
  fi
  if [ ! -e "$ST8/runs" ]; then
    ok "advisor off: zero advisor calls (no state written)"
    exhibit "AC8: advisor off -> 6c path byte-identical (no probe line, no card)"
  else
    bad "advisor off zero calls" "$(ls "$ST8/runs" 2>/dev/null)"
  fi

fi

# =============================================================================
# AC9 — no new agent role, no new user-invoked Surface; the advisor roster
# lines in agents/advisor.md, README.md and AGENTS.md are unchanged.
# =============================================================================
set_ac AC9
if want_ac; then

  if [ ! -e "$ROOT/agents/class-verify.md" ] && [ ! -e "$ROOT/commands/class-verify.md" ]; then
    ok "no new agent role and no new Surface (no agents/class-verify.md, no commands/class-verify.md)"
  else
    bad "no new role or Surface" "agents/class-verify.md or commands/class-verify.md exists"
  fi
  if grep -q '^name: advisor' "$ROOT/agents/advisor.md"; then
    ok "agents/advisor.md still names exactly the advisor role"
  else
    bad "agents/advisor.md" "name: advisor missing"
  fi
  NR=$(grep -c '^| `advisor`' "$ROOT/README.md")
  NA=$(grep -c '^| `advisor`' "$ROOT/AGENTS.md")
  if [ "$NR" = "1" ] && [ "$NA" = "1" ]; then
    ok "README and AGENTS.md rosters unchanged (one advisor row each)"
    exhibit "AC9: rosters unchanged — README advisor rows: $NR, AGENTS.md advisor rows: $NA"
  else
    bad "roster rows" "README=$NR AGENTS.md=$NA"
  fi

fi

# =============================================================================
# AC10 — the checks live in this hermetic engine-side suite with per-AC
# receipts and --ac filtering.
# =============================================================================
set_ac AC10
if want_ac; then

  if [ -f "$SUITE" ] && grep -qF 'tests/lib/ac-receipt.sh' "$SUITE" && grep -qF 'tests/lib/hermetic.sh' "$SUITE"; then
    ok "receipts suite skills/advisor/test-class-verify.sh sources tests/lib/ac-receipt.sh + tests/lib/hermetic.sh (scratch ADVISOR_STATE_ROOT, fixture-ledger MROOT)"
  else
    bad "receipts suite" "$SUITE missing or not sourcing the helpers"
  fi
  if bash "$SUITE" --ac AC1 >/dev/null 2>&1; then
    ok "--ac AC<n> filtered run exits 0 (per-AC Verify support: --ac AC1)"
  else
    bad "--ac filtered run" "--ac AC1 exited non-zero"
  fi

fi

# =============================================================================
# AC11 — SPEC-039 gains the Class verify section and SPEC-009's Step 6c MUST
# names the probe, the skip line, the demotion card, and the fail-closed rule.
# =============================================================================
set_ac AC11
if want_ac; then

  if grep -qF '### CDT-589-C3' "$SPEC039" && grep -q 'Trigger (d) — class verify' "$SPEC039"; then
    ok "SPEC-039 has the CDT-589-C3 ACs and the Trigger (d) MUST section"
    exhibit "AC11: SPEC-039 — $(grep -cF '### CDT-589-C3' "$SPEC039") CDT-589-C3 heading(s), $(grep -c 'Trigger (d)' "$SPEC039") Trigger (d) mention(s)"
  else
    bad "SPEC-039 sections" "missing ### CDT-589-C3 or Trigger (d)"
  fi
  M06C=$(grep -n 'MUST run the Step 6c class-verify probe' "$SPEC009" | head -n 1)
  if [ -n "$M06C" ]; then
    ok "SPEC-009 6c MUST names the class-verify probe"
    exhibit "AC11: SPEC-009 6c MUST -> $M06C"
  else
    bad "SPEC-009 6c MUST" "no class-verify MUST line"
  fi
  L6C=$(printf '%s' "$M06C" | cut -d: -f2-)
  for TOK in 'not-auth-relevant' 'BC8' 'plan-approve' 'never a halt'; do
    case "$L6C" in
      *"$TOK"*) ok "SPEC-009 6c MUST carries $TOK" ;;
      *) bad "SPEC-009 6c MUST token" "missing $TOK" ;;
    esac
  done

fi

ac_finish
