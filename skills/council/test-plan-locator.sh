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

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "FAILURES PRESENT"; fi
exit "$fail"
