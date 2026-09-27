#!/usr/bin/env bash
#
# autopilot/test-m14-verify-chain.sh -- WP 1-15 T10 (AC F). Fixture chain:
# split -> preflight plan claims -> investigator prompt render -> synthetic
# judge output -> finalize -> finalize-meta sidecar ->
# skills/autopilot/ship-gate-verdict.sh.
#
# This suite proves the MAPPING through the pipeline only: a synthetic
# judge output feeds a deterministic outcome to the mapper. It does not
# prove that a live council investigator runs a Verify command and reaches
# that verdict on its own -- the first live proof of that is the WP 1-05
# ship gate (SPEC-033 M14, WP 1-15 kickoff reading (A), Q5).
#
# Step 3 (per-case, node+jq only; steps 1, 2, 4 and 5 stay bash-only):
# renders the investigator prompt for each of the 8 plan.claims[] via
# workflow.js's loadPrompt, with vars set the way runOneInv sets them
# (C4: TOOL_BUDGET = String(claim.tool_budget ?? 5), VERIFY_COMMAND =
# claim.verify ?? ''), then asserts budget/command/exit-marker text on the
# 7 verify claims and the substantive non-M14 shape on the 1 null-verify
# claim -- the same pattern as skills/council/test-verify-prompts.sh.
#
# Hermetic: private TMPDIR/HOME (tests/lib/hermetic.sh) and a private temp
# git repo (the fixture spec and its stub Verify targets are committed into
# it below; the live worktree is never touched).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="$ROOT/skills/council/engine.sh"
SPLIT="$ROOT/skills/council/m14-ac-split.sh"
MAPPER="$ROOT/skills/autopilot/ship-gate-verdict.sh"
WORKFLOW_JS="$ROOT/skills/council/workflow.js"
FIX="$ROOT/skills/autopilot/fixtures/m14-verify-chain"

# shellcheck source=../../tests/lib/skip.sh
. "$ROOT/tests/lib/skip.sh"
# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
hermetic_init

fail=0
pass=0
ok() { echo "OK: $1"; pass=$((pass + 1)); }
fail_msg() { echo "FAIL: $1"; fail=$((fail + 1)); }
ok_eq() {  # ok_eq <label> <got> <want>
  if [ "$2" = "$3" ]; then ok "$1"; else fail_msg "$1 (got: $2 | want: $3)"; fi
}

REPO="$HERMETIC_ROOT/repo"
mkdir -p "$REPO/skills/fx"
git init -q "$REPO"
cp "$FIX/wp-fx-spec.md" "$REPO/wp-fx-spec.md"
cp "$FIX"/test-*.sh "$REPO/skills/fx/"
chmod 755 "$REPO"/skills/fx/test-*.sh
git -C "$REPO" add -A
git -C "$REPO" commit -q -m fixtures

TICKET="wp-fx"
SPEC_REL="wp-fx-spec.md"
TRIGGER_ARG="Ship-gate audit for $TICKET. This ships under the ACs at ac-source=$SPEC_REL (section '## Acceptance criteria', subsection '### $TICKET'). Claim under audit: the change ships correctly."

# ==============================================================================
# 1. Split: 8 technical ACs (A-G with a Verify line, H without), 1 process AC
# ==============================================================================
SPLIT_OUT="$( cd "$REPO" && bash "$SPLIT" "$TICKET" "$SPEC_REL" )"
RC_SPLIT=$?
ok_eq "1 split: exit 0" "$RC_SPLIT" "0"
ok_eq "1 split: 8 technical ACs" \
  "$(printf '%s' "$SPLIT_OUT" | jq '[.acs[] | select(.process==false)] | length')" "8"
ok_eq "1 split: 1 process AC" \
  "$(printf '%s' "$SPLIT_OUT" | jq '[.acs[] | select(.process==true)] | length')" "1"
ok_eq "1 split: 7 ACs carry a non-null verify" \
  "$(printf '%s' "$SPLIT_OUT" | jq '[.acs[] | select(.verify != null)] | length')" "7"
ok_eq "1 split: AC A verify" \
  "$(printf '%s' "$SPLIT_OUT" | jq -r '.acs[] | select(.id=="A") | .verify')" \
  "bash skills/fx/test-a.sh"
ok_eq "1 split: AC H verify is null" \
  "$(printf '%s' "$SPLIT_OUT" | jq -c '.acs[] | select(.id=="H") | .verify')" "null"
ok_eq "1 split: AC I is [process] with no verify" \
  "$(printf '%s' "$SPLIT_OUT" | jq -c '.acs[] | select(.id=="I") | {process, verify}')" \
  '{"process":true,"verify":null}'

# ==============================================================================
# 2. Preflight: plan.claims[].verify and .tool_budget (8 with a command,
#    5 without). 8 claims total (the [process] AC never becomes a claim).
# ==============================================================================
PLAN="$HERMETIC_ROOT/plan.json"
( cd "$REPO" && bash "$ENGINE" preflight --scope claim --scope-arg "$TRIGGER_ARG" ) > "$PLAN"
RC_PRE=$?
ok_eq "2 preflight: exit 0" "$RC_PRE" "0"
ok_eq "2 preflight: 8 claims" "$(jq '.claims | length' "$PLAN")" "8"
ok_eq "2 preflight: 7 claims carry a verify command" \
  "$(jq '[.claims[] | select(.verify != null)] | length' "$PLAN")" "7"
ok_eq "2 preflight: 1 claim has verify:null" \
  "$(jq '[.claims[] | select(.verify == null)] | length' "$PLAN")" "1"

BUDGET_MISMATCH=0
for i in $(seq 0 7); do
  V=$(jq -c ".claims[$i].verify" "$PLAN")
  B=$(jq ".claims[$i].tool_budget" "$PLAN")
  if [ "$V" = "null" ]; then
    [ "$B" = "5" ] || BUDGET_MISMATCH=1
  else
    [ "$B" = "8" ] || BUDGET_MISMATCH=1
  fi
done
ok_eq "2 preflight: every claim's tool_budget matches its verify (8 with, 5 without)" \
  "$BUDGET_MISMATCH" "0"

# ==============================================================================
# 3. Render: each plan.claims[] investigator prompt via workflow.js's
#    loadPrompt, with vars set the way runOneInv sets them (C4). node+jq
#    only; the rest of this suite stays bash-only, so this whole step is
#    guarded and skips (exit 77) when either tool is missing.
# ==============================================================================
if ( require_cmd node jq ); then
  RESULTS="$HERMETIC_ROOT/step3-results.json"
  NEGCTRL="$HERMETIC_ROOT/step3-negctrl.txt"
  if COUNCIL_WORKFLOW_JS="$WORKFLOW_JS" \
     COUNCIL_PLAN_FILE="$PLAN" \
     COUNCIL_RESULTS_OUT="$RESULTS" \
     COUNCIL_NEGCTRL_OUT="$NEGCTRL" \
node --input-type=module <<'JS'
import { readFileSync, writeFileSync } from 'node:fs'
import { pathToFileURL } from 'node:url'

const { loadPrompt } = await import(pathToFileURL(process.env.COUNCIL_WORKFLOW_JS).href)

const plan = JSON.parse(readFileSync(process.env.COUNCIL_PLAN_FILE, 'utf8'))

// Same vars runOneInv sets per claim (workflow.js C4).
const renderClaim = (c, budgetOverride) => loadPrompt('investigator', {
  CLAIM_TEXT: c.claim || '',
  SOURCE_LOCATOR: c.source_locator || 'unknown',
  RAW_ARTIFACTS: '',
  FLAVOR_DELTA: '',
  CACHE_DIR: '',
  TOOL_BUDGET: budgetOverride != null ? budgetOverride : String(c.tool_budget ?? 5),
  VERIFY_COMMAND: c.verify ?? '',
})

const results = plan.claims.map((c, i) => ({
  index: i,
  ac_id: c.ac_id ?? null,
  verify: c.verify ?? '',
  tool_budget: String(c.tool_budget ?? 5),
  text: renderClaim(c),
}))
writeFileSync(process.env.COUNCIL_RESULTS_OUT, JSON.stringify(results))

// Negative control (required correction 5): render a verify claim with
// TOOL_BUDGET forced to '5' -- the budget-8 checks below must fail on it.
const negSrc = plan.claims.find((c) => c.verify)
if (negSrc) {
  writeFileSync(process.env.COUNCIL_NEGCTRL_OUT, renderClaim(negSrc, '5'))
}
console.log('OK: step3 render done')
JS
  then
    ok "3 render: workflow.js loadPrompt renders all 8 claims"
  else
    fail_msg "3 render: workflow.js loadPrompt render failed"
  fi

  TMP3="$HERMETIC_ROOT/step3-renders"
  mkdir -p "$TMP3"

  # ---- 7 verify claims: budget=8 in all three spots, the C5 has_command
  # wrapper with the claim's own Verify command, VERIFY exit= present, no
  # leftover {{ markers. ------------------------------------------------
  VERIFY_ACS="$TMP3/verify-acs.txt"
  jq -r '.[] | select(.verify != "" and .verify != null) | .ac_id' "$RESULTS" > "$VERIFY_ACS"
  ok_eq "3 render: 7 claims carry a verify command" "$(wc -l < "$VERIFY_ACS" | tr -d ' ')" "7"

  while IFS= read -r ACID; do
    [ -z "$ACID" ] && continue
    TXT="$TMP3/render-$ACID.txt"
    jq -r --arg id "$ACID" '.[] | select(.ac_id==$id) | .text' "$RESULTS" > "$TXT"
    VCMD=$(jq -r --arg id "$ACID" '.[] | select(.ac_id==$id) | .verify' "$RESULTS")

    if grep -qF 'BUDGET of 8 tool calls total' "$TXT" \
      && grep -qF 'after 8 calls' "$TXT" \
      && grep -qF 'NEVER exceed 8 tool calls' "$TXT"; then
      ok "3 render AC $ACID: 8 in all three budget spots"
    else
      fail_msg "3 render AC $ACID: budget=8 not in all three spots"
    fi

    if grep -qF "TMPDIR=\"\$d\" $VCMD; echo \"VERIFY exit=\$?\"" "$TXT"; then
      ok "3 render AC $ACID: has_command wrapper carries $VCMD"
    else
      fail_msg "3 render AC $ACID: has_command wrapper missing/mismatched for $VCMD"
    fi

    if grep -qF 'VERIFY exit=' "$TXT" && ! grep -qF '{{' "$TXT"; then
      ok "3 render AC $ACID: VERIFY exit= present, no leftover {{ markers"
    else
      fail_msg "3 render AC $ACID: missing VERIFY exit= or a leftover {{ marker"
    fi
  done < "$VERIFY_ACS"

  # ---- 1 null-verify claim: the substantive non-M14 shape (no verify-run
  # artifacts, 5-call budget text intact). --------------------------------
  TXT_NULL="$TMP3/render-null.txt"
  jq -r '.[] | select(.verify == "" or .verify == null) | .text' "$RESULTS" > "$TXT_NULL"
  if [ -s "$TXT_NULL" ]; then
    if grep -qF 'VERIFY exit=' "$TXT_NULL" \
      || grep -qF 'VERIFY RUN (M14 per-AC)' "$TXT_NULL" \
      || grep -qF '{{' "$TXT_NULL"; then
      fail_msg "3 render (null verify): leftover verify-run marker/body or unsubstituted {{ }}"
    else
      ok "3 render (null verify): no verify-run marker/body, no leftover {{ markers"
    fi
    if grep -qF 'BUDGET of 5 tool calls total' "$TXT_NULL" \
      && grep -qF 'after 5 calls' "$TXT_NULL" \
      && grep -qF 'NEVER exceed 5 tool calls' "$TXT_NULL"; then
      ok "3 render (null verify): 5-call budget text intact"
    else
      fail_msg "3 render (null verify): 5-call budget text missing/changed"
    fi
  else
    fail_msg "3 render (null verify): empty output"
  fi

  # ---- Negative control: the same budget-8 checks must fail on a verify
  # claim rendered with TOOL_BUDGET forced to '5'. -----------------------
  if [ -s "$NEGCTRL" ]; then
    if grep -qF 'BUDGET of 8 tool calls total' "$NEGCTRL" \
      || grep -qF 'after 8 calls' "$NEGCTRL" \
      || grep -qF 'NEVER exceed 8 tool calls' "$NEGCTRL"; then
      fail_msg "3 negative control: budget-8 phrases leaked into a TOOL_BUDGET=5 render"
    else
      ok "3 negative control: budget-8 checks correctly fail when TOOL_BUDGET=5"
    fi
  else
    fail_msg "3 negative control: empty output"
  fi
fi

# ==============================================================================
# 4. Synthetic judge output: all 8 ACs tagged VERIFIED at 85 -> finalize ->
#    sidecar -> ship-gate-verdict.sh with card #1 -> agree, bump copied.
# ==============================================================================
CARD1="$HERMETIC_ROOT/card1.json"
cat > "$CARD1" <<'CARD1_EOF'
{"gate":"ship-choice","decision":"merge","bump":"patch","decided_by":"auto",
 "blocking_condition":null,"council_tier":null,"grading_reason":null}
CARD1_EOF

JUDGE_ALL="$HERMETIC_ROOT/judge-all-verified.json"
jq '{
  verdicts: [.claims[] | {claim_id: .claim_id, claim: .claim,
    verdict: "VERIFIED", confidence: 85, evidence_blob: "VERIFY exit=0"}],
  struck_lines: []
}' "$PLAN" > "$JUDGE_ALL"

EVIDENCE_ALL="$HERMETIC_ROOT/evidence-all.json"
cat > "$EVIDENCE_ALL" <<'EV_EOF'
[{"tool_use_id": "t1", "raw_blob": "VERIFY exit=0",
  "file_line": "skills/fx/test-a.sh:1", "reproducible_command": "bash skills/fx/test-a.sh"}]
EV_EOF

REPORT_ALL="$HERMETIC_ROOT/report-all.md"
( cd "$REPO" && bash "$ENGINE" finalize --plan-file "$PLAN" --evidence-file "$EVIDENCE_ALL" \
    --judge-output "$JUDGE_ALL" --report-out "$REPORT_ALL" \
    > "$HERMETIC_ROOT/finalize-all.out" 2>"$HERMETIC_ROOT/finalize-all.err" )
RC_FIN_ALL=$?
ok_eq "4 finalize (all VERIFIED): exit 0" "$RC_FIN_ALL" "0"

META_ALL="${REPORT_ALL}.finalize-meta.json"
if [ -f "$META_ALL" ]; then
  ok "4 sidecar exists"
else
  fail_msg "4 sidecar exists (not found: $META_ALL)"
fi
ok_eq "4 sidecar.ac_claims length" "$(jq '.ac_claims | length' "$META_ALL")" "8"

VERDICT_ALL="$(bash "$MAPPER" --meta "$META_ALL" --card1 "$CARD1" --tier full)"
RCV_ALL=$?
ok_eq "4 mapper: exit 0" "$RCV_ALL" "0"
ok_eq "4 mapper: decision agree -> merge (card #1's decision)" \
  "$(printf '%s' "$VERDICT_ALL" | jq -r '.decision')" "merge"
ok_eq "4 mapper: blocking_condition null" \
  "$(printf '%s' "$VERDICT_ALL" | jq -c '.blocking_condition')" "null"
ok_eq "4 mapper: confidence == 85" "$(printf '%s' "$VERDICT_ALL" | jq '.confidence')" "85"
ok_eq "4 mapper: bump copied from card #1" \
  "$(printf '%s' "$VERDICT_ALL" | jq -r '.bump')" "patch"

# ==============================================================================
# 5. Same, with AC A's verdict CONTRADICTED (its bundle holds "VERIFY exit=1")
#    -> blocking_condition=7, confidence=0. A distinct --report-out avoids
#    reusing (and overwriting) step 4's sidecar.
# ==============================================================================
JUDGE_ONE_BAD="$HERMETIC_ROOT/judge-one-bad.json"
jq '{
  verdicts: [.claims[] | {claim_id: .claim_id, claim: .claim,
    verdict: (if .ac_id == "A" then "CONTRADICTED" else "VERIFIED" end),
    confidence: (if .ac_id == "A" then 20 else 85 end),
    evidence_blob: (if .ac_id == "A" then "VERIFY exit=1" else "VERIFY exit=0" end)}],
  struck_lines: []
}' "$PLAN" > "$JUDGE_ONE_BAD"

EVIDENCE_ONE_BAD="$HERMETIC_ROOT/evidence-one-bad.json"
cat > "$EVIDENCE_ONE_BAD" <<'EV_EOF'
[{"tool_use_id": "t1", "raw_blob": "VERIFY exit=1",
  "file_line": "skills/fx/test-a.sh:1", "reproducible_command": "bash skills/fx/test-a.sh"}]
EV_EOF

REPORT_BAD="$HERMETIC_ROOT/report-bad.md"
( cd "$REPO" && bash "$ENGINE" finalize --plan-file "$PLAN" --evidence-file "$EVIDENCE_ONE_BAD" \
    --judge-output "$JUDGE_ONE_BAD" --report-out "$REPORT_BAD" \
    > "$HERMETIC_ROOT/finalize-bad.out" 2>"$HERMETIC_ROOT/finalize-bad.err" )
RC_FIN_BAD=$?
ok_eq "5 finalize (AC A CONTRADICTED): exit 0" "$RC_FIN_BAD" "0"

META_BAD="${REPORT_BAD}.finalize-meta.json"

VERDICT_BAD="$(bash "$MAPPER" --meta "$META_BAD" --card1 "$CARD1" --tier full)"
RCV_BAD=$?
ok_eq "5 mapper: exit 0" "$RCV_BAD" "0"
ok_eq "5 mapper: decision halt" "$(printf '%s' "$VERDICT_BAD" | jq -r '.decision')" "halt"
ok_eq "5 mapper: blocking_condition == 7" \
  "$(printf '%s' "$VERDICT_BAD" | jq -c '.blocking_condition')" "7"
ok_eq "5 mapper: confidence == 0" "$(printf '%s' "$VERDICT_BAD" | jq '.confidence')" "0"
case "$(printf '%s' "$VERDICT_BAD" | jq -r '.rationale')" in
  *"A=CONTRADICTED"*) ok "5 mapper: rationale names AC A's CONTRADICTED verdict" ;;
  *) fail_msg "5 mapper: rationale missing A=CONTRADICTED: $VERDICT_BAD" ;;
esac

# ==============================================================================
echo
echo "PASS=$pass FAIL=$fail"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
