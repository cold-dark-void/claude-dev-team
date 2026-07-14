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
set +e
bash skills/council/engine.sh preflight --scope from-retro --scope-arg anchor-x >/dev/null 2>"${TMPDIR:-/tmp}/cdv208-fr.err"
ec_fr=$?
set -e
if [ "$ec_fr" -eq 3 ] && rg -q 'not implemented' "${TMPDIR:-/tmp}/cdv208-fr.err"; then
  echo "OK: from-retro still deferred exit 3"
else
  echo "FAIL: from-retro exit=$ec_fr (want 3)"; fail=1
fi
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
  echo "OK: council.md keeps from-retro deferred"
else
  echo "FAIL: from-retro deferred note missing in council.md"; fail=1
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
