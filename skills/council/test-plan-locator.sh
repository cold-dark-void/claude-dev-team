#!/usr/bin/env bash
# L-19: plan-extractor input line numbers are file lines. A prepended header
# that shifts the recorded line fails this test.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
cd "$ROOT"

out="$(node --input-type=module <<'JS'
import { readFileSync } from 'node:fs'
import { buildPlanExtractorInput, planClaimLine, loadPrompt } from './skills/council/workflow.js'

const lines = []
for (let i = 1; i <= 60; i++) lines.push('filler line ' + i)
const claim = 'Use SQLite at .claude/memory/memory.db for agent memory'
lines[52] = '- ' + claim
const plan = lines.join('\n') + '\n'
const input = buildPlanExtractorInput(plan)
const line = planClaimLine(input, claim)
const fileLine = plan.split('\n')[line - 1] || ''
if (line !== 53) {
  console.error('FAIL: recorded line ' + line + ' want 53')
  process.exit(1)
}
if (!fileLine.includes(claim)) {
  console.error('FAIL: file line does not contain the claim: ' + fileLine)
  process.exit(1)
}

const rendered = loadPrompt('plan-extractor', {
  PLAN_PATH: 'plans/sample.md',
  INPUT_TEXT: input,
  CLAIM_BUDGET: '10',
})
const rline = planClaimLine(rendered, claim)
if (rline !== 53) {
  console.error('FAIL: rendered prompt line ' + rline + ' (header shifted the claim)')
  process.exit(1)
}
const shifted = 'HEADER\n'.repeat(26) + input
const sline = planClaimLine(shifted, claim)
const shiftedText = plan.split('\n')[sline - 1] || ''
if (shiftedText.includes(claim)) {
  console.error('FAIL: a prepended header still pointed at the claim')
  process.exit(1)
}

const prompt = readFileSync('skills/council/prompts/plan-extractor.md', 'utf8')
const fence = prompt.split('```\n')[1] || ''
if (!fence.startsWith('{{INPUT_TEXT}}\n')) {
  console.error('FAIL: prompt body does not start with {{INPUT_TEXT}}')
  process.exit(1)
}
console.log('OK: locator line 53 contains the claim')
console.log('OK: rendered prompt does not shift the line')
console.log('OK: a prepended header would miss the claim')
JS
)" || { echo "FAIL: plan locator"; echo "$out"; exit 1; }
printf '%s\n' "$out"
printf '%s\n' "$out" | grep -q 'OK: locator line 53' || fail=1

# ---- CDT-589-C4 (AC1/AC2/AC4): a [forward] claim keeps its locator ---------
# The plan file never carries the tag — the Phase 1 extractor adds it — so
# planClaimLine strips `[forward] ` before the line search. The plan-scope
# artifacts seam (composeRawArtifacts) MUST be the identity for every untagged
# claim, so a plan-scope render stays byte-exact (AC3, SPEC-013 Phase 2).
out2="$(node --input-type=module <<'JS'
import { readFileSync } from 'node:fs'
import { buildPlanExtractorInput, planClaimLine, composeRawArtifacts } from './skills/council/workflow.js'

const lines = []
for (let i = 1; i <= 60; i++) lines.push('filler line ' + i)
const claim = 'Step 3 adds flag --fwd-demo to skills/council/engine.sh'
lines[52] = '- ' + claim
const plan = lines.join('\n') + '\n'
const input = buildPlanExtractorInput(plan)
const tagged = '[forward] ' + claim

const tline = planClaimLine(input, tagged)
if (tline !== 53) {
  console.error('FAIL: tagged claim resolved line ' + tline + ' want 53')
  process.exit(1)
}
if (!(plan.split('\n')[tline - 1] || '').includes(claim)) {
  console.error('FAIL: the tagged claim pointed at a line without its text')
  process.exit(1)
}
if (planClaimLine(input, claim) !== 53) {
  console.error('FAIL: the untagged claim no longer resolves line 53')
  process.exit(1)
}
if (planClaimLine(input, '[forward] nothing in this plan') !== 0) {
  console.error('FAIL: an absent tagged claim resolved a line')
  process.exit(1)
}
const rendered = loadRenderCheck()
function loadRenderCheck() {
  const addendum = readFileSync('skills/council/forward-claim-addendum.txt', 'utf8').trimEnd()
  const raw = 'artifacts line 1\nartifacts line 2\n'
  // AC3: untagged -> byte-identical value, no addendum.
  if (composeRawArtifacts(raw, claim, 'plan') !== raw) {
    console.error('FAIL: composeRawArtifacts changed an untagged plan-scope value')
    process.exit(1)
  }
  // AC3: tagged -> that exact value, the addendum appended on its own line.
  if (composeRawArtifacts(raw, tagged, 'plan') !== raw + '\n' + addendum) {
    console.error('FAIL: composeRawArtifacts did not append the addendum for a tagged claim')
    process.exit(1)
  }
  // AC6: the same tagged text outside plan scope is the identity.
  if (composeRawArtifacts(raw, tagged, 'claim') !== raw) {
    console.error('FAIL: composeRawArtifacts fired outside plan scope')
    process.exit(1)
  }
  return 'ok'
}
if (rendered !== 'ok') process.exit(1)
console.log('OK: a [forward] claim still resolves locator line 53')
console.log('OK: composeRawArtifacts is the identity for an untagged claim')
console.log('OK: composeRawArtifacts appends the addendum for a tagged claim')
console.log('OK: composeRawArtifacts is a no-op outside plan scope')
JS
)" || { echo "FAIL: forward-claim locator + compose"; echo "$out2"; exit 1; }
printf '%s\n' "$out2"
for want in \
  'OK: a [forward] claim still resolves locator line 53' \
  'OK: composeRawArtifacts is the identity for an untagged claim' \
  'OK: composeRawArtifacts appends the addendum for a tagged claim' \
  'OK: composeRawArtifacts is a no-op outside plan scope'
do
  printf '%s\n' "$out2" | grep -qF "$want" || fail=1
done

# ---- CDT-589-C4 AC1/AC2: the extractor rule is prompt prose, not a classifier
# Tagging is LLM judgment (SPEC-013 § CDT-589-C4 AC1/AC10): the prefix rule,
# the substring-HARD-RULE exemption, the untagged cases, and the no-task-graph
# fail-closed all live in plan-extractor.md. No bash classifier may infer it.
pe="$(cat skills/council/prompts/plan-extractor.md)"
for want in \
  'FORWARD CLAIM TAGGING' \
  'A claim that asserts work that graph schedules is a Forward claim' \
  '`forward`, right bracket, space' \
  'A claim about existing state stays untagged' \
  'No parsable task graph -> no tagged claims' \
  'except the optional' \
  'it is not a schema field'
do
  case "$pe" in
    *"$want"*) echo "OK: plan-extractor.md states: $want" ;;
    *) echo "FAIL: plan-extractor.md missing: $want"; fail=1 ;;
  esac
done
if grep -rqF '[forward] ' skills/council/engine.sh skills/council/engine-preflight.sh; then
  echo "FAIL: the engine must not classify tags (no bash classifier, AC1)"
  fail=1
else
  echo "OK: engine preflight carries no tag classifier"
fi
# AC4: the tag survives into Phase 2.5 CLAIM_TEXT and Phase 5 ORIGINAL_CLAIMS
# verbatim, and Phase 4 stays claim-blind.
case "$(cat skills/council/prompts/phase4-brief.md)" in
  *'[forward]'*) echo "FAIL: phase4-brief.md gained Forward claim prose (AC4)"; fail=1 ;;
  *) echo "OK: phase4-brief.md stays claim-blind (AC4)" ;;
esac
for want in '{{CLAIM_TEXT}}' '{{ORIGINAL_CLAIMS}}' '{{EVIDENCE_BUNDLES}}'; do
  if grep -qF "$want" skills/council/prompts/cross-reviewer.md 2>/dev/null \
     || grep -qF "$want" skills/council/prompts/judge.md; then
    echo "OK: $want is substituted from the claim list verbatim"
  else
    echo "FAIL: $want has no prompt site"
    fail=1
  fi
done

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "FAILURES PRESENT"; fi
exit "$fail"
