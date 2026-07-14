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
