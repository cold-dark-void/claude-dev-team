#!/usr/bin/env bash
# Static ACs for Council-on-Workflow (CDV-196). No live Workflow host required.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
fail=0
check() { if "$@"; then echo "OK: $*"; else echo "FAIL: $*"; fail=1; fi; }

# T4.3 greps
if rg -n 'PYREPAIR|repair_json' skills/council/workflow.js; then echo "FAIL: repair layers"; fail=1; else echo "OK: no repair layers"; fi
if rg -n "typeof t === 'string'" skills/council/workflow.js >/dev/null; then echo "OK: args guard"; else echo "FAIL: args guard"; fail=1; fi
if rg -n 'self-verified — refuters unavailable' skills/council/workflow.js; then echo "FAIL: marker inlined"; fail=1; else echo "OK: marker only via finalize"; fi
if rg -n "agentType: 'dev-team:council-judge'" skills/council/workflow.js >/dev/null; then echo "OK: judge agentType"; else echo "FAIL: judge agentType"; fail=1; fi
if rg -n 'tools: ""' agents/council-judge.md >/dev/null; then echo "OK: judge tools empty"; else echo "FAIL: judge tools"; fail=1; fi

# probe
bash skills/council/workflow-probe.sh
COUNCIL_WORKFLOW_FORCE_FALLBACK=1 bash skills/council/workflow-probe.sh && { echo "FAIL: force fallback"; fail=1; } || echo "OK: force fallback"

# CDV-208 plan-scope preflight
FIX_PLAN=skills/council/fixtures/plan-scope-sample.md
if [ -f "$FIX_PLAN" ]; then
  echo "OK: plan-scope fixture present"
else
  echo "FAIL: missing $FIX_PLAN"; fail=1
fi
if [ -f skills/council/prompts/plan-extractor.md ] \
  && rg -q 'file:heading-path:line|heading-path' skills/council/prompts/plan-extractor.md; then
  echo "OK: plan-extractor.md documents locator format"
else
  echo "FAIL: plan-extractor.md missing or no locator guidance"; fail=1
fi
set +e
bash skills/council/engine.sh preflight --scope plan --scope-arg /nonexistent-cdv208-plan.md >/dev/null 2>"${TMPDIR:-/tmp}/cdv208-plan-miss.err"
ec_miss=$?
set -e
if [ "$ec_miss" -eq 2 ] && rg -q 'not found|not readable|requires a path' "${TMPDIR:-/tmp}/cdv208-plan-miss.err"; then
  echo "OK: plan missing path → exit 2"
else
  echo "FAIL: plan missing path exit=$ec_miss (want 2)"; fail=1
fi
# CDV-212 from-retro scope preflight
FIX_ANCHOR=skills/council/fixtures/from-retro-anchor.json
if [ -f "$FIX_ANCHOR" ] \
  && jq -e '.anchor_id and .fabricated_claim_text and .session_id and .turn_id' "$FIX_ANCHOR" >/dev/null; then
  echo "OK: from-retro fixture present"
else
  echo "FAIL: missing/invalid $FIX_ANCHOR"; fail=1
fi
set +e
bash skills/council/engine.sh preflight --scope from-retro --scope-arg missing-cdv212-anchor >/dev/null 2>"${TMPDIR:-/tmp}/cdv212-fr-miss.err"
ec_fr_miss=$?
set -e
if [ "$ec_fr_miss" -eq 2 ] && rg -q 'not found|requires an anchor' "${TMPDIR:-/tmp}/cdv212-fr-miss.err"; then
  echo "OK: from-retro missing anchor → exit 2"
else
  echo "FAIL: from-retro missing exit=$ec_fr_miss (want 2)"; fail=1
fi
# Present fixture: stage under $MROOT/.claude/retro/anchors/ then preflight
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && _MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || _MROOT=$(pwd)
AID=$(jq -r '.anchor_id' "$FIX_ANCHOR")
ANCHOR_DIR="$_MROOT/.claude/retro/anchors"
mkdir -p "$ANCHOR_DIR"
cp "$FIX_ANCHOR" "$ANCHOR_DIR/${AID}.json"
set +e
FR_JSON=$(bash skills/council/engine.sh preflight --scope from-retro --scope-arg "$AID" 2>"${TMPDIR:-/tmp}/cdv212-fr-ok.err")
ec_fr_ok=$?
set -e
if [ "$ec_fr_ok" -eq 0 ] && printf '%s' "$FR_JSON" | jq -e \
  --arg aid "$AID" \
  --arg claim "$(jq -r '.fabricated_claim_text' "$FIX_ANCHOR")" \
  '.scope=="from-retro" and .preset=="generic" and .phases["1_claim_extraction"].skip==true and .scope_arg==$aid and .resolved_claim==$claim and (.slug|test("^from-retro-"))' >/dev/null; then
  echo "OK: from-retro present → skip extract + resolved_claim"
else
  echo "FAIL: from-retro present preflight exit=$ec_fr_ok"; fail=1
  cat "${TMPDIR:-/tmp}/cdv212-fr-ok.err" >&2 || true
fi
# Leave staged fixture for local re-runs; tests are idempotent overwrite.
if bash skills/council/engine.sh preflight --scope plan --scope-arg "$FIX_PLAN" \
  | jq -e '.scope=="plan" and .preset=="generic" and .phases["1_claim_extraction"].skip==false and (.phases["1_claim_extraction"].prompt|test("plan-extractor")) and (.claim_budget==10) and (.slug|test("^plan-"))' >/dev/null; then
  echo "OK: plan preflight JSON (generic, extract, plan-extractor, slug)"
else
  echo "FAIL: plan preflight JSON shape"; fail=1
fi
if rg -n 'DEFERRED.*--plan|exits 3, deferred\)' commands/council.md >/dev/null; then
  echo "FAIL: council.md still defers --plan"; fail=1
else
  echo "OK: council.md does not defer --plan"
fi
if rg -n 'from-retro' commands/council.md | rg -q 'DEFERRED|deferred|exits 3'; then
  echo "FAIL: council.md still defers from-retro"; fail=1
else
  echo "OK: council.md does not defer from-retro"
fi

# CDV-206 --why preflight
if bash skills/council/engine.sh preflight --scope claim --scope-arg 'x' --why \
  | jq -e '.why==true and .why_detail.preset and .why_detail.flavors and .why_detail.phase3_specialist and .why_detail.claim_budget and (.why_detail.preset_source=="inferred" or .why_detail.preset_source=="explicit")' >/dev/null; then
  echo "OK: preflight --why emits why_detail"
else
  echo "FAIL: preflight --why why_detail"; fail=1
fi
if bash skills/council/engine.sh preflight --scope claim --scope-arg 'x' \
  | jq -e '.why!=true and (.why_detail|not)' >/dev/null; then
  echo "OK: preflight without --why has no why_detail"
else
  echo "FAIL: preflight without --why leaked why_detail"; fail=1
fi
if bash skills/council/engine.sh preflight --scope claim --scope-arg 'x' --preset generic --why \
  | jq -e '.why_detail.preset_source=="explicit"' >/dev/null; then
  echo "OK: --preset sets preset_source=explicit"
else
  echo "FAIL: preset_source explicit"; fail=1
fi
if rg -n 'why_detail' commands/council.md >/dev/null; then
  echo "OK: council.md documents why_detail"
else
  echo "FAIL: council.md missing why_detail"; fail=1
fi

# CDV-209 Phase 3 domain specialist
if [ -f skills/council/prompts/topic-classifier.md ] \
  && rg -q 'confidence|devops|topic' skills/council/prompts/topic-classifier.md; then
  echo "OK: topic-classifier.md present"
else
  echo "FAIL: topic-classifier.md missing/incomplete"; fail=1
fi
if bash skills/council/engine.sh preflight --scope claim --scope-arg 'x' \
  | jq -e '.phases["3_domain_specialist"].deferred==false and .phases["3_domain_specialist"].skipped==false and .phases["3_domain_specialist"].confidence_threshold==0.75 and .phases["3_domain_specialist"].max_specialists_per_run==1 and (.phases["3_domain_specialist"].classifier_prompt|test("topic-classifier"))' >/dev/null; then
  echo "OK: phase 3 claim preflight (live, not deferred)"
else
  echo "FAIL: phase 3 claim preflight shape"; fail=1
fi
if bash skills/council/engine.sh preflight --scope diff \
  | jq -e '.phases["3_domain_specialist"].deferred==false and .phases["3_domain_specialist"].skipped==true' >/dev/null; then
  echo "OK: phase 3 diff-mode skipped"
else
  echo "FAIL: phase 3 should skip in diff-mode"; fail=1
fi
if bash skills/council/engine.sh preflight --scope claim --scope-arg 'x' --why \
  | jq -e '.why_detail.phase3_specialist|test("pending|runtime")' >/dev/null; then
  echo "OK: why_detail phase3 pending stub (claim)"
else
  echo "FAIL: why_detail phase3 claim stub"; fail=1
fi
if bash skills/council/engine.sh preflight --scope diff --why \
  | jq -e '.why_detail.phase3_specialist|test("diff-mode")' >/dev/null; then
  echo "OK: why_detail phase3 skipped (diff-mode)"
else
  echo "FAIL: why_detail phase3 diff stub"; fail=1
fi
if rg -n 'topic-classifier' commands/council.md >/dev/null \
  && rg -n 'max_specialists_per_run|confidence_threshold|0\.75' commands/council.md >/dev/null \
  && ! rg -n 'Phase 3 — Domain Specialist \(DEFERRED' commands/council.md >/dev/null; then
  echo "OK: council.md Phase 3 dispatch live"
else
  echo "FAIL: council.md Phase 3 still deferred or missing classifier"; fail=1
fi
if rg -n 'Phase 3 — Domain Specialist \(DEFERRED' skills/council/SKILL.md >/dev/null \
  || rg -n 'deferred \(CDV-209\)' skills/council/SKILL.md >/dev/null; then
  echo "FAIL: SKILL.md still defers Phase 3"; fail=1
else
  echo "OK: SKILL.md Phase 3 not deferred"
fi
if rg -n 'Deferred to COUNCIL-002' specs/core/SPEC-013-adversarial-council-tribunal.md >/dev/null; then
  echo "FAIL: SPEC-013 Phase 3 still deferred blockquote"; fail=1
else
  echo "OK: SPEC-013 Phase 3 undefferred"
fi

# CDV-204: finalize --tokens-file (graceful Tokens block + optional FM)
FIX_BASE=skills/council/fixtures/finalize-task-id
TOK_BASE=skills/council/fixtures/finalize-tokens
TOK_OUT=$(mktemp -d)
trap 'rm -rf "$TOK_OUT"' EXIT
if OUT=$(bash skills/council/engine.sh finalize \
  --plan-file "$FIX_BASE/plan-unbound.json" \
  --evidence-file "$FIX_BASE/evidence.json" \
  --judge-output "$FIX_BASE/judge.json" \
  --report-out "$TOK_OUT/with.md" \
  --tokens-file "$TOK_BASE/tokens-full.json" 2>/dev/null) \
  && printf '%s\n' "$OUT" | rg -q '^Tokens:' \
  && printf '%s\n' "$OUT" | rg -q 'Total: 78232' \
  && rg -q 'tokens_total: 78232' "$TOK_OUT/with.md" \
  && rg -q '1_claim_extraction: 2341' "$TOK_OUT/with.md"; then
  echo "OK: finalize with tokens → Tokens block + frontmatter"
else
  echo "FAIL: finalize with tokens"; fail=1
fi
if OUT=$(bash skills/council/engine.sh finalize \
  --plan-file "$FIX_BASE/plan-unbound.json" \
  --evidence-file "$FIX_BASE/evidence.json" \
  --judge-output "$FIX_BASE/judge.json" \
  --report-out "$TOK_OUT/without.md" 2>/dev/null) \
  && ! printf '%s\n' "$OUT" | rg -q '^Tokens' \
  && ! rg -q 'tokens_total' "$TOK_OUT/without.md"; then
  echo "OK: finalize without tokens-file → omit Tokens"
else
  echo "FAIL: finalize without tokens-file leaked Tokens"; fail=1
fi
if OUT=$(bash skills/council/engine.sh finalize \
  --plan-file "$FIX_BASE/plan-unbound.json" \
  --evidence-file "$FIX_BASE/evidence.json" \
  --judge-output "$FIX_BASE/judge.json" \
  --report-out "$TOK_OUT/unavail.md" \
  --tokens-file "$TOK_BASE/tokens-unavailable.json" 2>/dev/null) \
  && ! printf '%s\n' "$OUT" | rg -q '^Tokens' \
  && ! rg -q 'tokens_total' "$TOK_OUT/unavail.md"; then
  echo "OK: finalize source=unavailable → omit Tokens"
else
  echo "FAIL: unavailable tokens not omitted"; fail=1
fi
if OUT=$(bash skills/council/engine.sh finalize \
  --plan-file "$FIX_BASE/plan-unbound.json" \
  --evidence-file "$FIX_BASE/evidence.json" \
  --judge-output "$FIX_BASE/judge.json" \
  --report-out "$TOK_OUT/partial.md" \
  --tokens-file "$TOK_BASE/tokens-partial.json" 2>/dev/null) \
  && printf '%s\n' "$OUT" | rg -q 'Tokens \(partial\):' \
  && printf '%s\n' "$OUT" | rg -q 'Total: 59738'; then
  echo "OK: finalize partial tokens"
else
  echo "FAIL: finalize partial tokens"; fail=1
fi
if OUT=$(bash skills/council/engine.sh finalize \
  --plan-file "$FIX_BASE/plan-unbound.json" \
  --evidence-file "$FIX_BASE/evidence.json" \
  --judge-output "$FIX_BASE/judge.json" \
  --report-out "$TOK_OUT/zeros.md" \
  --tokens-file "$TOK_BASE/tokens-zeros.json" 2>/dev/null) \
  && ! printf '%s\n' "$OUT" | rg -q '^Tokens' \
  && ! rg -q 'tokens_total' "$TOK_OUT/zeros.md"; then
  echo "OK: finalize zeros/null phases → omit (no invented 0)"
else
  echo "FAIL: zeros treated as real tokens"; fail=1
fi
if rg -n 'tokens-file' commands/council.md >/dev/null; then
  echo "OK: council.md documents tokens-file"
else
  echo "FAIL: council.md missing tokens-file"; fail=1
fi

# helpers + mock finalize
node --input-type=module <<'JS'
import { parseArgs, loadPrompt, runCouncil } from './skills/council/workflow.js'
const a = parseArgs(JSON.stringify({ scope: 'claim', claim: 'x' }))
if (!a.ok) throw new Error('parse')
const p = loadPrompt('judge', {
  ORIGINAL_CLAIMS: '[]', EVIDENCE_BUNDLES: '', PROSECUTOR_BRIEF: '',
  ADVOCATE_BRIEF: '', OUTPUT_SHAPE: 'verdict[]'
})
if (p.includes('{{OUTPUT_SHAPE}}')) throw new Error('unsub')
const agent = async (_pr, opts) => {
  if (opts.phase === 'Investigate') return { bundles: [{ tool_use_id: 't', raw_blob: 'b', file_line: 'f:1', reproducible_command: 'e' }] }
  if (opts.phase === 'Phase4') return { briefs: [{ claim_id: 'c0', evidence_against: 'e', requested_verdict: 'UNVERIFIED', supporting_tool_use_ids: ['t'] }], struck_lines: [] }
  if (opts.label === 'council-judge') return { verdicts: [{ claim: 'x', verdict: 'UNVERIFIED', confidence: 50, evidence_blob: 'b' }], struck_lines: [] }
  return null
}
const r = await runCouncil({ args: { scope: 'claim', claim: 'x' }, agent, phase: () => {}, parallel: async fns => Promise.all(fns.map(f => f())) })
if (!r.ok) throw new Error(JSON.stringify(r))
console.log('OK: mock runCouncil')
JS

exit $fail
