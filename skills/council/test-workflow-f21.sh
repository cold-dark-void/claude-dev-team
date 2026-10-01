#!/usr/bin/env bash
# CDT-275 workflow parity delta + CDT-330 generic Phase 2 flavors.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=../../tests/lib/skip.sh
. "$ROOT/tests/lib/skip.sh"
# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
require_cmd jq node
hermetic_init
TR="$TMPDIR/repo"
mkdir -p "$TR"
git init -q -b main "$TR"
fail=0

# Generic preset Phase 2 flavors must not be a file that says "cannot Read".
flavors=$(bash skills/council/engine.sh preflight --scope claim --scope-arg x | jq -r '.flavors[]')
if [ "$flavors" = "$(printf '%s\n' paranoid-ic skeptic-ic)" ]; then
  echo "OK: generic flavors are paranoid-ic and skeptic-ic"
else
  echo "FAIL: generic flavors: $flavors"; fail=1
fi
for name in $flavors; do
  f="skills/council/flavors/${name}.md"
  if [ ! -f "$f" ]; then
    echo "FAIL: missing $f"; fail=1
    continue
  fi
  if grep -qF 'cannot Read' "$f"; then
    echo "FAIL: Phase 2 flavor $name contains cannot Read"; fail=1
  else
    echo "OK: $name does not say cannot Read"
  fi
done
if ! grep -qF 'cannot Read' skills/council/flavors/jaded-senior.md; then
  echo "FAIL: jaded-senior should still be tool-less (prosecutor)"; fail=1
else
  echo "OK: jaded-senior remains the tool-less prosecutor flavor"
fi

# Investigator prompt must not tell the investigator to write the cache.
if grep -qF 'sha256sum |' skills/council/prompts/investigator.md \
  || grep -qF 'mkdir -p' skills/council/prompts/investigator.md; then
  echo "FAIL: investigator prompt still writes or hashes the cache"; fail=1
else
  echo "OK: investigator prompt does not sha256sum or mkdir the cache"
fi
if grep -qF 'Do not invent a' skills/council/prompts/investigator.md \
  && grep -qF 'tool_use_id' skills/council/prompts/investigator.md; then
  echo "OK: investigator prompt forbids a invented cache tool_use_id"
else
  echo "FAIL: investigator prompt missing cache tool_use_id rule"; fail=1
fi

COUNCIL_TEST_REPO="$TR" node --input-type=module <<'JS'
import { readFileSync, writeFileSync, readdirSync, existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { loadPrompt, parsePreflightStdout, runCouncil } from './skills/council/workflow.js'

process.chdir(process.env.COUNCIL_TEST_REPO)

const bad = parsePreflightStdout('{')
if (bad.ok || bad.exit_code !== 1) throw new Error('parse should exit 1: ' + JSON.stringify(bad))
if (!String(bad.error).includes('parse failed')) throw new Error('parse error has no message')
console.log('OK: invalid preflight JSON is exit 1, not a throw')

const rendered = loadPrompt('investigator', {
  CLAIM_TEXT: 'literal {{RAW_ARTIFACTS}} stays',
  SOURCE_LOCATOR: 'f:1',
  RAW_ARTIFACTS: 'SECRET_BYTES',
  FLAVOR_DELTA: '',
  CACHE_DIR: '',
  TOOL_BUDGET: '5',
  VERIFY_COMMAND: '',
})
if (!rendered.includes('literal {{RAW_ARTIFACTS}} stays')) {
  throw new Error('claim value lost the literal placeholder:\n' + rendered)
}
if (rendered.includes('literal SECRET_BYTES stays')) {
  throw new Error('loadPrompt expanded {{RAW_ARTIFACTS}} inside the claim value')
}
const art = rendered.split('<<<BEGIN_ARTIFACTS>>>')[1] || ''
if (!art.includes('SECRET_BYTES')) throw new Error('template RAW_ARTIFACTS was not substituted')
console.log('OK: loadPrompt one pass does not expand a claim value')

function wfDirs() {
  return readdirSync(tmpdir()).filter((n) => n.startsWith('council-wf-'))
}
const before = new Set(wfDirs())

const errs = []
const origErr = console.error
console.error = (...a) => { errs.push(a.join(' ')) }

let spawned = 0
const agent = async () => { spawned += 1; return null }
const light = await runCouncil({
  args: { scope: 'claim', claim: 'x', council_tier: 'light' },
  agent,
  phase: () => {},
  parallel: async (fns) => Promise.all(fns.map((f) => f())),
})
if (light.ok || light.exit_code !== 2) throw new Error('light should exit 2: ' + JSON.stringify(light))
if (spawned !== 0) throw new Error('light spawned an investigator')
if (!errs.some((l) => l.includes('council_tier=light unsupported'))) {
  throw new Error('light notice missing: ' + errs.join('\n'))
}
console.log('OK: council_tier light exits 2 before spawn')

errs.length = 0
spawned = 0
const ext = await runCouncil({
  args: { scope: 'claim', claim: 'x', external: true },
  agent,
  phase: () => {},
  parallel: async (fns) => Promise.all(fns.map((f) => f())),
})
if (ext.ok || ext.exit_code !== 2) throw new Error('external should exit 2: ' + JSON.stringify(ext))
if (!errs.some((l) => l === 'council: Phase 3 and --external are the Task path (commands/council.md)')) {
  throw new Error('task-path notice missing: ' + errs.join('\n'))
}
const phase3 = await runCouncil({
  args: { scope: 'claim', claim: 'x', phase3: true },
  agent,
  phase: () => {},
  parallel: async (fns) => Promise.all(fns.map((f) => f())),
})
if (phase3.exit_code !== 2) throw new Error('phase3 should exit 2')
if (spawned !== 0) throw new Error('phase3/external spawned')
const leaked = wfDirs().filter((n) => !before.has(n))
if (leaked.length) throw new Error('handoff leaked: ' + leaked.join(','))
console.log('OK: phase3 and external exit 2 with no handoff dir')

console.error = origErr

const struckAgent = async (_p, opts) => {
  if (opts.phase === 'Investigate') {
    if (String(opts.label).endsWith(':paranoid-ic')) {
      return { bundles: [{ tool_use_id: 't', raw_blob: 'BLOB', file_line: 'f:1', reproducible_command: 'true' }] }
    }
    return { bundles: [] }
  }
  if (opts.phase === 'Phase4' && opts.label === 'Prosecutor') {
    return {
      briefs: [{ claim_id: 'c0', evidence_against: 'e', requested_verdict: 'UNVERIFIED', supporting_tool_use_ids: ['t'] }],
      struck_lines: ['only-once'],
    }
  }
  if (opts.phase === 'Phase4') return { briefs: [], struck_lines: [] }
  if (opts.label === 'council-judge') {
    return { verdicts: [{ claim: 'x', claim_id: 'c0', verdict: 'UNVERIFIED', confidence: 40, evidence_blob: 'BLOB' }] }
  }
  return null
}
const struckRun = await runCouncil({
  args: { scope: 'claim', claim: 'struck once' },
  agent: struckAgent,
  phase: () => {},
  parallel: async (fns) => Promise.all(fns.map((f) => f())),
})
if (!struckRun.ok) throw new Error('struck run failed: ' + JSON.stringify(struckRun))
const reportPath = String(struckRun.stdout || '').match(/Council report: (\S+)/)
if (!reportPath) throw new Error('no report\n' + struckRun.stdout)
const report = readFileSync(reportPath[1], 'utf8')
const hits = report.split('only-once').length - 1
if (hits !== 1) throw new Error('struck line count ' + hits + ' (want 1)\n' + report)
console.log('OK: phase4 struck line is not copied onto the judge')

const tok = process.env.TMPDIR + '/tokens.json'
writeFileSync(tok, JSON.stringify({ phases: { '5_judge': 3 }, total: 3, source: 'workflow' }))
const withTok = await runCouncil({
  args: { scope: 'claim', claim: 'tokens', tokens_file: tok },
  agent: struckAgent,
  phase: () => {},
  parallel: async (fns) => Promise.all(fns.map((f) => f())),
})
if (!withTok.ok) throw new Error('tokens run failed: ' + JSON.stringify(withTok))
if (!String(withTok.stdout).includes('Tokens:')) throw new Error('tokens file was not passed:\n' + withTok.stdout)
const noTok = await runCouncil({
  args: { scope: 'claim', claim: 'no tokens' },
  agent: struckAgent,
  phase: () => {},
  parallel: async (fns) => Promise.all(fns.map((f) => f())),
})
if (String(noTok.stdout).includes('Tokens:')) throw new Error('invented a tokens block')
console.log('OK: tokens-file is passed only when the caller has one')

const after = wfDirs().filter((n) => !before.has(n))
if (after.length) throw new Error('success path leaked handoff: ' + after.join(','))
console.log('OK: council-wf handoff removed on success')
JS

if [ "$fail" -eq 0 ]; then
  echo "PASS: test-workflow-f21.sh"
  exit 0
fi
echo "FAIL: test-workflow-f21.sh"
exit 1
