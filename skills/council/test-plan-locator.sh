#!/usr/bin/env bash
# L-19: plan-extractor input line numbers are file lines. A prepended header
# that shifts the recorded line fails this test.
#
# CDT-589-C4 per-AC run receipts (SPEC-013 § CDT-589-C4, CDT-595 pattern):
# every check prints `ok AC<n>: <slug>` on stdout and a failure prints
# `FAIL: AC<n>: <slug>: <detail>` on stderr, from tests/lib/ac-receipt.sh.
# `--ac AC<n>` runs one AC's checks and prints the subset aggregate; the last
# stdout line of any run is `PASS=<n> FAIL=<m>` and the count of `^ok ` lines
# equals n. The `OK:` prose lines and the `ALL PASS` line are kept verbatim
# for back-compat. Checks carry AC1 (tagging + prefix keying), AC2 (untagged
# cases stay refutable), AC4 (prefix survives the phases) and AC10 (spec and
# doc state; no bash classifier).
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# shellcheck source=../../tests/lib/ac-receipt.sh
. "$ROOT/tests/lib/ac-receipt.sh"
parse_ac_args "$@"

PASS=0
FAIL=0

SPEC="specs/core/SPEC-013-adversarial-council-tribunal.md"

# line_ok <slug> <expected-line> <captured-output> — receipt for one OK: line
# printed by a node block. The block is the check; the receipt names it.
line_ok() {
  local slug=$1 want=$2 out=$3
  if printf '%s\n' "$out" | grep -qF -- "$want"; then
    ok "$slug"
  else
    bad "$slug" "node block did not print: $want"
  fi
}

# prose_ok <slug> <fixed-string> <file> — the file states the string.
prose_ok() {
  local slug=$1 want=$2 file=$3
  if grep -qF -- "$want" "$file"; then
    echo "OK: $file states: $want"
    ok "$slug"
  else
    echo "FAIL: $file missing: $want"
    bad "$slug" "$file missing: $want"
  fi
}

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

# =============================================================================
# AC4 — the prefix survives the phases; planClaimLine accepts prefixed text
# =============================================================================
set_ac AC4
if want_ac; then
  line_ok ac4-locator-file-line-53 'OK: locator line 53 contains the claim' "$out"
  line_ok ac4-locator-rendered-prompt 'OK: rendered prompt does not shift the line' "$out"
  line_ok ac4-locator-header-shift-bites 'OK: a prepended header would miss the claim' "$out"
  line_ok ac4-planclaimline-accepts-prefixed-text \
    'OK: a [forward] claim still resolves locator line 53' "$out2"
  printf 'exhibit: planClaimLine strips the [forward] prefix before the line search — prefixed text resolves, and finalize text-equality is prefix-optional on either side\n'
  # The tag rides verbatim: the committed fixture claim record carries it, and
  # the placeholder sites that carry the claim text name it verbatim.
  FIXCLAIM="$(jq -r '.claims[0].claim' skills/council/fixtures/forward-claim/plan-tagged.json)"
  printf 'exhibit: fixture claim record: %s\n' "$FIXCLAIM"
  case "$FIXCLAIM" in
    '[forward] '*) ok ac4-fixture-claim-prefix-verbatim ;;
    *) bad ac4-fixture-claim-prefix-verbatim "fixture claim lost the prefix: $FIXCLAIM" ;;
  esac
  for want in '{{CLAIM_TEXT}}' '{{ORIGINAL_CLAIMS}}' '{{EVIDENCE_BUNDLES}}'; do
    if grep -qF "$want" skills/council/prompts/cross-reviewer.md 2>/dev/null \
       || grep -qF "$want" skills/council/prompts/judge.md; then
      echo "OK: $want is substituted from the claim list verbatim"
      case "$want" in
        '{{CLAIM_TEXT}}')      ok ac4-prefix-survives-claim-text ;;
        '{{ORIGINAL_CLAIMS}}') ok ac4-prefix-survives-original-claims ;;
        '{{EVIDENCE_BUNDLES}}') ok ac4-evidence-bundles-claim-site ;;
      esac
    else
      echo "FAIL: $want has no prompt site"
      bad "ac4-$want-no-site" "$want has no prompt site"
    fi
  done
  # Phase 4 grouping stays keyed on claim_id (workflow.js brief filter).
  if grep -qF 'claimIds.includes(b.claim_id)' skills/council/workflow.js; then
    ok ac4-phase4-grouping-by-claim-id
  else
    bad ac4-phase4-grouping-by-claim-id "workflow.js phase-4 brief filter is not keyed on claim_id"
  fi
  printf 'exhibit: phase 4 grouping: briefs filtered by claim_id (workflow.js); claim text rides into {{CLAIM_TEXT}} and {{ORIGINAL_CLAIMS}}\n'
  case "$(cat skills/council/prompts/phase4-brief.md)" in
    *'[forward]'*) bad ac4-phase4-brief-stays-claim-blind "phase4-brief.md gained Forward claim prose" ;;
    *) echo "OK: phase4-brief.md stays claim-blind (AC4)"; ok ac4-phase4-brief-stays-claim-blind ;;
  esac
fi

# =============================================================================
# AC1 — tagging rule, literal prefix, no schema field, no bash classifier
# =============================================================================
set_ac AC1
if want_ac; then
  # The engine keys on the prefix: the seam fires for a tagged plan-scope
  # claim, and both engine layers hold the literal-prefix constant.
  line_ok ac1-engine-keys-on-prefix \
    'OK: composeRawArtifacts appends the addendum for a tagged claim' "$out2"
  if grep -qF 'FORWARD_CLAIM_PREFIX' skills/council/workflow.js \
     && grep -qF 'FORWARD_CLAIM_PREFIX' skills/council/engine-finalize.sh; then
    ok ac1-engine-keys-on-literal-prefix
  else
    bad ac1-engine-keys-on-literal-prefix "engine layers lost the FORWARD_CLAIM_PREFIX constant"
  fi
  printf 'exhibit: the keying constant is the 10-char tag: [forward] (left bracket, forward, right bracket, space)\n'
  # The record gains no schema field: tagged and untagged claim records carry
  # the same key set, and the extractor prompt says so.
  KEYS_T="$(jq -r '.claims[0] | keys_unsorted | sort | join(",")' skills/council/fixtures/forward-claim/plan-tagged.json)"
  KEYS_U="$(jq -r '.claims[0] | keys_unsorted | sort | join(",")' skills/council/fixtures/forward-claim/plan-untagged.json)"
  if [ -n "$KEYS_T" ] && [ "$KEYS_T" = "$KEYS_U" ]; then
    ok ac1-record-shape-unchanged
  else
    bad ac1-record-shape-unchanged "tagged [$KEYS_T] vs untagged [$KEYS_U] claim record keys differ"
  fi
  printf 'exhibit: record shape: {claim, source_locator, claim_type} (+ claim_id, verify, tool_budget as today): %s\n' "$KEYS_T"
  prose_ok ac1-extractor-states-tagging-rule 'FORWARD CLAIM TAGGING' skills/council/prompts/plan-extractor.md
  prose_ok ac1-forward-claim-definition \
    'A claim that asserts work that graph schedules is a Forward claim' skills/council/prompts/plan-extractor.md
  prose_ok ac1-literal-prefix-spelling '`forward`, right bracket, space' skills/council/prompts/plan-extractor.md
  prose_ok ac1-no-task-graph-no-tags 'No parsable task graph -> no tagged claims' skills/council/prompts/plan-extractor.md
  prose_ok ac1-no-schema-field 'it is not a schema field' skills/council/prompts/plan-extractor.md
  prose_ok ac1-hard-rule-exempts-prefix 'except the optional' skills/council/prompts/plan-extractor.md
  if grep -rqF '[forward] ' skills/council/engine.sh skills/council/engine-preflight.sh; then
    bad ac1-no-bash-classifier-in-engine "the engine must not classify tags (no bash classifier, AC1)"
  else
    echo "OK: engine preflight carries no tag classifier"
    ok ac1-no-bash-classifier-in-engine
  fi
fi

# =============================================================================
# AC2 — existing-state and unscheduled-file claims stay untagged, refutable
# =============================================================================
set_ac AC2
if want_ac; then
  # A missed tag is old behavior: the untagged plan-scope artifacts value is
  # the identity, so absence of the described code stays admissible evidence.
  line_ok ac2-untagged-compose-identity \
    'OK: composeRawArtifacts is the identity for an untagged claim' "$out2"
  printf 'exhibit: refutability: an untagged plan-scope claim renders byte-identical artifacts — absence of the described code stays admissible evidence, fully refutable\n'
  prose_ok ac2-existing-state-untagged \
    'A claim about existing state stays untagged' skills/council/prompts/plan-extractor.md
  prose_ok ac2-present-tense-negative-untagged 'present-tense' skills/council/prompts/plan-extractor.md
  prose_ok ac2-unscheduled-file-untagged 'does not schedule' skills/council/prompts/plan-extractor.md
fi

# =============================================================================
# AC10 — spec/doc state: sections, fail-closed, no classifier, 6c timing
# =============================================================================
set_ac AC10
if want_ac; then
  # Sections of $SPEC that carry a Forward claim (CDT-589-C4) statement.
  SECMAP="$(awk '/^### / { sec=$0; sub(/^### /, "", sec) } /CDT-589-C4/ && /[Ff]orward/ { print sec }' "$SPEC")"
  for pair in \
    'ac10-spec-states-forward-phase-1:Phase 1 — Claim Extraction' \
    'ac10-spec-states-forward-phase-2:Phase 2 — Parallel Investigation' \
    'ac10-spec-states-forward-phase-2-5:Phase 2.5 — Blind Cross-Review' \
    'ac10-spec-states-forward-phase-5:Phase 5 — Judgment' \
    'ac10-spec-states-forward-phase-6:Phase 6 — Report & Persistence' \
    'ac10-spec-states-forward-scope-exclusions:Scope Exclusions'
  do
    slug=${pair%%:*}
    want=${pair#*:}
    if printf '%s\n' "$SECMAP" | grep -qF -- "$want"; then
      echo "OK: $SPEC states the Forward claim rule under $want"
      ok "$slug"
    else
      echo "FAIL: $SPEC has no Forward claim statement under $want"
      bad "$slug" "no Forward claim statement under $want"
    fi
  done
  prose_ok ac10-missed-tag-fail-closed 'A missed tag is old behavior (fail-closed)' "$SPEC"
  prose_ok ac10-context-md-writeback-epic-level \
    'epic-level obligation, not this ticket' "$SPEC"
  printf 'exhibit: CONTEXT.md write-back of the term Forward claim is an epic-level obligation, not this ticket diff\n'
  if grep -qF 'evaluated on unstruck **post-finalize** verdicts' specs/core/SPEC-033-autopilot-policy.md; then
    echo "OK: SPEC-033 M8.6c evaluates the Step 6c halt list on post-finalize verdicts"
    ok ac10-spec033-post-finalize-timing
  else
    bad ac10-spec033-post-finalize-timing "SPEC-033 lost the post-finalize Step 6c timing"
  fi
  printf 'exhibit: SPEC-033 M8.6c: the Step 6c halt list is evaluated on unstruck post-finalize verdicts\n'
  CLS="$(grep -rlE 'forward-classifier' "$ROOT/skills/council/" --include='*.sh' 2>/dev/null | grep -v test- | wc -l | tr -d ' ')"
  if [ "$CLS" = "0" ]; then
    echo "OK: no bash classifier script keys the tag (AC10)"
    ok ac10-no-bash-classifier-anywhere
  else
    bad ac10-no-bash-classifier-anywhere "$CLS classifier script(s) present"
  fi
fi

if [ "${FAIL:-0}" -eq 0 ]; then echo "ALL PASS"; else echo "FAILURES PRESENT"; fi
ac_finish
