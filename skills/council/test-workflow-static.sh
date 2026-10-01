#!/usr/bin/env bash
# Static ACs for Council-on-Workflow (CDV-196). No live Workflow host required.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# shellcheck source=../../tests/lib/skip.sh
. "$ROOT/tests/lib/skip.sh"
# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
require_cmd jq node
hermetic_init
WORK=$(mktemp -d)
TOK_OUT="$WORK/tokens"
mkdir -p "$TOK_OUT"
trap 'rm -rf "$WORK"; hermetic_cleanup' EXIT

fail=0
check() { if "$@"; then echo "OK: $*"; else echo "FAIL: $*"; fail=1; fi; }

# T4.3 greps
if grep -nE 'PYREPAIR|repair_json' skills/council/workflow.js; then echo "FAIL: repair layers"; fail=1; else echo "OK: no repair layers"; fi
if grep -nF "typeof t === 'string'" skills/council/workflow.js >/dev/null; then echo "OK: args guard"; else echo "FAIL: args guard"; fail=1; fi
if grep -nF 'self-verified — refuters unavailable' skills/council/workflow.js; then echo "FAIL: marker inlined"; fail=1; else echo "OK: marker only via finalize"; fi
if grep -nF "agentType: 'dev-team:council-judge'" skills/council/workflow.js >/dev/null; then echo "OK: judge agentType"; else echo "FAIL: judge agentType"; fail=1; fi
if grep -nF 'tools: ""' agents/council-judge.md >/dev/null; then echo "OK: judge tools empty"; else echo "FAIL: judge tools"; fail=1; fi

# probe
env -u CLAUDE_CODE_VERSION bash skills/council/workflow-probe.sh
COUNCIL_WORKFLOW_FORCE_FALLBACK=1 env -u CLAUDE_CODE_VERSION bash skills/council/workflow-probe.sh && { echo "FAIL: force fallback"; fail=1; } || echo "OK: force fallback"

# CDV-208 plan-scope preflight
FIX_PLAN=skills/council/fixtures/plan-scope-sample.md
if [ -f "$FIX_PLAN" ]; then
  echo "OK: plan-scope fixture present"
else
  echo "FAIL: missing $FIX_PLAN"; fail=1
fi
if [ -f skills/council/prompts/plan-extractor.md ] \
  && grep -qE 'file:heading-path:line|heading-path' skills/council/prompts/plan-extractor.md; then
  echo "OK: plan-extractor.md documents locator format"
else
  echo "FAIL: plan-extractor.md missing or no locator guidance"; fail=1
fi
set +e
bash skills/council/engine.sh preflight --scope plan --scope-arg /nonexistent-cdv208-plan.md >/dev/null 2>"$WORK/cdv208-plan-miss.err"
ec_miss=$?
set -e
if [ "$ec_miss" -eq 2 ] && grep -qE 'not found|not readable|requires a path' "$WORK/cdv208-plan-miss.err"; then
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
bash skills/council/engine.sh preflight --scope from-retro --scope-arg missing-cdv212-anchor >/dev/null 2>"$WORK/cdv212-fr-miss.err"
ec_fr_miss=$?
set -e
if [ "$ec_fr_miss" -eq 2 ] && grep -qE 'not found|requires an anchor' "$WORK/cdv212-fr-miss.err"; then
  echo "OK: from-retro missing anchor → exit 2"
else
  echo "FAIL: from-retro missing exit=$ec_fr_miss (want 2)"; fail=1
fi
# Present fixture: stage under a disposable temp repo's .claude/retro/anchors/
# then preflight with cwd = that repo — nothing under the real MROOT (T5).
TR="$WORK/repo"
mkdir -p "$TR"
git init -q "$TR"
AID=$(jq -r '.anchor_id' "$FIX_ANCHOR")
ANCHOR_DIR="$TR/.claude/retro/anchors"
mkdir -p "$ANCHOR_DIR"
cp "$FIX_ANCHOR" "$ANCHOR_DIR/${AID}.json"
set +e
FR_JSON=$(cd "$TR" && bash "$ROOT/skills/council/engine.sh" preflight --scope from-retro --scope-arg "$AID" 2>"$WORK/cdv212-fr-ok.err")
ec_fr_ok=$?
set -e
if [ "$ec_fr_ok" -eq 0 ] && printf '%s' "$FR_JSON" | jq -e \
  --arg aid "$AID" \
  --arg claim "$(jq -r '.fabricated_claim_text' "$FIX_ANCHOR")" \
  '.scope=="from-retro" and .preset=="generic" and .phases["1_claim_extraction"].skip==true and .scope_arg==$aid and .resolved_claim==$claim and (.slug|test("^from-retro-"))' >/dev/null; then
  echo "OK: from-retro present → skip extract + resolved_claim"
else
  echo "FAIL: from-retro present preflight exit=$ec_fr_ok"; fail=1
  cat "$WORK/cdv212-fr-ok.err" >&2 || true
fi
# Staging above went to a disposable temp repo ($TR), not the real MROOT;
# nothing here needs cleanup -- the trap on $WORK covers it.
if bash skills/council/engine.sh preflight --scope plan --scope-arg "$FIX_PLAN" \
  | jq -e '.scope=="plan" and .preset=="generic" and .phases["1_claim_extraction"].skip==false and (.phases["1_claim_extraction"].prompt|test("plan-extractor")) and (.claim_budget==10) and (.slug|test("^plan-"))' >/dev/null; then
  echo "OK: plan preflight JSON (generic, extract, plan-extractor, slug)"
else
  echo "FAIL: plan preflight JSON shape"; fail=1
fi
if grep -nE 'DEFERRED.*--plan|exits 3, deferred\)' commands/council.md >/dev/null; then
  echo "FAIL: council.md still defers --plan"; fail=1
else
  echo "OK: council.md does not defer --plan"
fi
if grep -nF 'from-retro' commands/council.md | grep -qE 'DEFERRED|deferred|exits 3'; then
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
if grep -nF 'why_detail' commands/council.md >/dev/null; then
  echo "OK: council.md documents why_detail"
else
  echo "FAIL: council.md missing why_detail"; fail=1
fi

# CDV-209 Phase 3 domain specialist
if [ -f skills/council/prompts/topic-classifier.md ] \
  && grep -qE 'confidence|devops|topic' skills/council/prompts/topic-classifier.md; then
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
if grep -nF 'topic-classifier' commands/council.md >/dev/null \
  && grep -nE 'max_specialists_per_run|confidence_threshold|0\.75' commands/council.md >/dev/null \
  && ! grep -nE 'Phase 3 — Domain Specialist \(DEFERRED' commands/council.md >/dev/null; then
  echo "OK: council.md Phase 3 dispatch live"
else
  echo "FAIL: council.md Phase 3 still deferred or missing classifier"; fail=1
fi

# CDV-207 external reviewer slot
EXT_SH=skills/council/external-reviewer.sh
if [ -x "$EXT_SH" ] || [ -f "$EXT_SH" ]; then
  echo "OK: external-reviewer.sh present"
else
  echo "FAIL: missing $EXT_SH"; fail=1
fi
if [ -f skills/council/flavors/external.md ]; then
  echo "OK: flavors/external.md present"
else
  echo "FAIL: missing flavors/external.md"; fail=1
fi
# PATH without codex/gemini → detect skip exit 0
# (codex may live in /usr/bin on host — build a PATH that only has jq)
_NOCLI_BIN=$(mktemp -d "$WORK/cdv207-nocli-bin.XXXXXX")
ln -s "$(command -v jq)" "$_NOCLI_BIN/jq"
set +e
NOCLI_OUT=$(PATH="$_NOCLI_BIN" /bin/bash "$EXT_SH" detect --prefer auto 2>"$WORK/cdv207-nocli.err")
ec_nocli=$?
set -e
rm -rf -- "$_NOCLI_BIN"
if [ "$ec_nocli" -eq 0 ] && printf '%s' "$NOCLI_OUT" | jq -e '.status=="skipped" and .tool==null' >/dev/null \
  && grep -qF 'skip' "$WORK/cdv207-nocli.err"; then
  echo "OK: external detect no-cli → skip exit 0"
else
  echo "FAIL: external detect no-cli exit=$ec_nocli out=$NOCLI_OUT"; fail=1
  cat "$WORK/cdv207-nocli.err" >&2 || true
fi
# normalize mock raw → evidence_bundle
MOCK_RAW=$(mktemp "$WORK/cdv207-raw.XXXXXX")
printf '%s\n' '- CRITICAL skills/council/engine.sh:42 — missing null check on scope' >"$MOCK_RAW"
set +e
NORM_OUT=$(bash "$EXT_SH" normalize --tool codex --raw-file "$MOCK_RAW" --output-shape 'finding[]' --command 'mock')
ec_norm=$?
set -e
rm -f -- "$MOCK_RAW"
if [ "$ec_norm" -eq 0 ] && printf '%s' "$NORM_OUT" | jq -e \
  '.status=="ok" and (.evidence_bundle.tool_use_id|test("^external:codex:")) and (.findings|type=="array")' >/dev/null; then
  echo "OK: external normalize → evidence_bundle + findings"
else
  echo "FAIL: external normalize exit=$ec_norm"; fail=1
  printf '%s\n' "$NORM_OUT" >&2 || true
fi
# preflight --external includes external field; never reduces flavors
set +e
EXT_PLAN=$(bash skills/council/engine.sh preflight --scope claim --scope-arg 'x' --external 2>"$WORK/cdv207-pf.err")
ec_ext_pf=$?
set -e
if [ "$ec_ext_pf" -eq 0 ] && printf '%s' "$EXT_PLAN" | jq -e \
  '.external.requested==true and (.external.status=="available" or .external.status=="skipped") and (.external.helper|test("external-reviewer")) and (.flavors|length)>=2' >/dev/null; then
  echo "OK: preflight --external emits external field; ≥2 internal flavors"
else
  echo "FAIL: preflight --external shape exit=$ec_ext_pf"; fail=1
  cat "$WORK/cdv207-pf.err" >&2 || true
fi
# without --external: requested false
if bash skills/council/engine.sh preflight --scope claim --scope-arg 'x' \
  | jq -e '.external.requested==false' >/dev/null; then
  echo "OK: preflight default external.requested=false"
else
  echo "FAIL: preflight missing external.requested=false"; fail=1
fi
# --external=gemini prefer pin (may skip if absent — still exit 0 + field)
set +e
PIN_PLAN=$(bash skills/council/engine.sh preflight --scope diff --external=gemini 2>/dev/null)
ec_pin=$?
set -e
if [ "$ec_pin" -eq 0 ] && printf '%s' "$PIN_PLAN" | jq -e \
  '.external.requested==true and .external.prefer=="gemini"' >/dev/null; then
  echo "OK: preflight --external=gemini prefer pin"
else
  echo "FAIL: preflight --external=gemini exit=$ec_pin"; fail=1
fi
if grep -nF -- '--external' commands/council.md >/dev/null \
  && grep -nF 'external-reviewer' commands/council.md >/dev/null; then
  echo "OK: council.md documents --external slot"
else
  echo "FAIL: council.md missing --external docs"; fail=1
fi
if grep -nF -- '--external' skills/review-and-commit/SKILL.md >/dev/null; then
  echo "OK: review-and-commit passthrough --external"
else
  echo "FAIL: review-and-commit missing --external"; fail=1
fi
if grep -nE 'CDV-207|external investigator' specs/core/SPEC-013-adversarial-council-tribunal.md >/dev/null; then
  echo "OK: SPEC-013 SHOULD external diversity"
else
  echo "FAIL: SPEC-013 missing external SHOULD"; fail=1
fi
if grep -nE 'Phase 3 — Domain Specialist \(DEFERRED' skills/council/SKILL.md >/dev/null \
  || grep -nE 'deferred \(CDV-209\)' skills/council/SKILL.md >/dev/null; then
  echo "FAIL: SKILL.md still defers Phase 3"; fail=1
else
  echo "OK: SKILL.md Phase 3 not deferred"
fi
if grep -nF 'Deferred to COUNCIL-002' specs/core/SPEC-013-adversarial-council-tribunal.md >/dev/null; then
  echo "FAIL: SPEC-013 Phase 3 still deferred blockquote"; fail=1
else
  echo "OK: SPEC-013 Phase 3 undefferred"
fi

# CDV-211: per-run investigator tool-call cache
if bash skills/council/engine.sh preflight --scope claim --scope-arg 'x' \
  | jq -e '.cache_dir and .run_id and (.cache_dir|test("council-cache-"))' >/dev/null; then
  echo "OK: preflight emits cache_dir + run_id"
else
  echo "FAIL: preflight missing cache_dir/run_id"; fail=1
fi
_CDV211_PLAN=$(bash skills/council/engine.sh preflight --scope claim --scope-arg 'x')
_CDV211_DIR=$(printf '%s' "$_CDV211_PLAN" | jq -r '.cache_dir')
if [ -d "$_CDV211_DIR" ] && [ -d "$_CDV211_DIR/reads" ] && [ -d "$_CDV211_DIR/greps" ] \
  && [ -f "$_CDV211_DIR/manifest.json" ]; then
  echo "OK: preflight creates council-cache layout"
else
  echo "FAIL: cache dir layout missing under $_CDV211_DIR"; fail=1
fi
rm -rf -- "$_CDV211_DIR" 2>/dev/null || true
_STALE_PARENT=$(dirname -- "$_CDV211_DIR")
_STALE="$_STALE_PARENT/council-cache-stale-wp406"
_FRESH="$_STALE_PARENT/council-cache-fresh-wp406"
rm -rf -- "$_STALE" "$_FRESH"
mkdir -p "$_STALE" "$_FRESH"
touch -d '2 days ago' "$_STALE"
bash skills/council/engine.sh preflight --scope claim --scope-arg 'prune' >/dev/null
if [ ! -d "$_STALE" ] && [ -d "$_FRESH" ]; then
  echo "OK: preflight prunes council-cache older than 24h"
else
  echo "FAIL: stale council-cache prune stale=$([ -d "$_STALE" ] && echo yes || echo no) fresh=$([ -d "$_FRESH" ] && echo yes || echo no)"; fail=1
fi
rm -rf -- "$_STALE" "$_FRESH" 2>/dev/null || true
if grep -nE 'cache_dir|cache-first|CACHE_DIR' skills/council/prompts/investigator.md >/dev/null \
  && grep -nE 'cache_dir|CACHE_DIR|council-cache' commands/council.md >/dev/null; then
  echo "OK: investigator + council.md document cache protocol"
else
  echo "FAIL: cache protocol docs missing"; fail=1
fi

# CDV-204: finalize --tokens-file (graceful Tokens block + optional FM)
FIX_BASE=skills/council/fixtures/finalize-task-id
TOK_BASE=skills/council/fixtures/finalize-tokens
if OUT=$(bash skills/council/engine.sh finalize \
  --plan-file "$FIX_BASE/plan-unbound.json" \
  --evidence-file "$FIX_BASE/evidence.json" \
  --judge-output "$FIX_BASE/judge.json" \
  --report-out "$TOK_OUT/with.md" \
  --tokens-file "$TOK_BASE/tokens-full.json" 2>/dev/null) \
  && printf '%s\n' "$OUT" | grep -qE '^Tokens:' \
  && printf '%s\n' "$OUT" | grep -qF 'Total: 78232' \
  && grep -qF 'tokens_total: 78232' "$TOK_OUT/with.md" \
  && grep -qF '1_claim_extraction: 2341' "$TOK_OUT/with.md"; then
  echo "OK: finalize with tokens → Tokens block + frontmatter"
else
  echo "FAIL: finalize with tokens"; fail=1
fi
if OUT=$(bash skills/council/engine.sh finalize \
  --plan-file "$FIX_BASE/plan-unbound.json" \
  --evidence-file "$FIX_BASE/evidence.json" \
  --judge-output "$FIX_BASE/judge.json" \
  --report-out "$TOK_OUT/without.md" 2>/dev/null) \
  && ! printf '%s\n' "$OUT" | grep -qE '^Tokens' \
  && ! grep -qF 'tokens_total' "$TOK_OUT/without.md"; then
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
  && ! printf '%s\n' "$OUT" | grep -qE '^Tokens' \
  && ! grep -qF 'tokens_total' "$TOK_OUT/unavail.md"; then
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
  && printf '%s\n' "$OUT" | grep -qE 'Tokens \(partial\):' \
  && printf '%s\n' "$OUT" | grep -qF 'Total: 59738'; then
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
  && ! printf '%s\n' "$OUT" | grep -qE '^Tokens' \
  && ! grep -qF 'tokens_total' "$TOK_OUT/zeros.md"; then
  echo "OK: finalize zeros/null phases → omit (no invented 0)"
else
  echo "FAIL: zeros treated as real tokens"; fail=1
fi
if grep -nF 'tokens-file' commands/council.md >/dev/null; then
  echo "OK: council.md documents tokens-file"
else
  echo "FAIL: council.md missing tokens-file"; fail=1
fi


# T6 — SPEC-013 Test 24 item 3: plan.claims[] verbatim on both consumer
# paths, no truncate/re-extract; exit 8/9 propagated + documented.
if grep -nF 'consume it **verbatim**' commands/council.md >/dev/null \
  && grep -nF 'Do NOT truncate, reorder, merge, reword, or re-extract' commands/council.md >/dev/null \
  && ! grep -nE 'plan\.claims.*slice|claims\.slice\(0, *claimBudget\)' commands/council.md >/dev/null; then
  echo "OK: council.md Task path consumes plan.claims verbatim, no slice/truncate"
else
  echo "FAIL: council.md Task path plan.claims verbatim contract"; fail=1
fi
if grep -nF 'plan.claims.map((c) => ({' skills/council/workflow.js >/dev/null \
  && ! grep -nE 'plan\.claims\.slice' skills/council/workflow.js >/dev/null; then
  echo "OK: workflow.js Workflow path maps plan.claims verbatim, no slice"
else
  echo "FAIL: workflow.js plan.claims verbatim contract"; fail=1
fi
if grep -nF 'claim_id: c.claim_id' skills/council/workflow.js >/dev/null \
  && grep -nF 'ac_id: c.ac_id' skills/council/workflow.js >/dev/null; then
  echo "OK: workflow.js keeps claim_id/ac_id on M14 claims"
else
  echo "FAIL: workflow.js drops claim_id/ac_id"; fail=1
fi
if grep -nE '\*\*Exit 8' commands/council.md >/dev/null \
  && grep -nE 'exits 9' commands/council.md >/dev/null; then
  echo "OK: council.md documents exit 8 and exit 9"
else
  echo "FAIL: council.md missing exit 8/9 documentation"; fail=1
fi
if grep -nF 'pre.status !== 0' skills/council/workflow.js >/dev/null \
  && grep -nF 'fin.status !== 0' skills/council/workflow.js >/dev/null; then
  echo "OK: workflow.js propagates preflight/finalize exit codes generically (8/9 not special-cased/retried)"
else
  echo "FAIL: workflow.js exit-code propagation missing"; fail=1
fi
# helpers + mock finalize
COUNCIL_TEST_REPO="$TR" node --input-type=module <<'JS'
import { parseArgs, loadPrompt, runCouncil } from './skills/council/workflow.js'
// Isolate MROOT off the real worktree before any preflight/finalize call —
// see the full rationale next to this same chdir in test-tier-engine.sh (T5).
process.chdir(process.env.COUNCIL_TEST_REPO)
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


# WP 1-15 T7 (AC I) — per-claim cross-review (SPEC-013 Phase 2.5)
if grep -nF 'claims[0]?.claim' skills/council/workflow.js >/dev/null; then
  echo "FAIL: workflow.js still reads claims[0] for cross-review CLAIM_TEXT"; fail=1
else
  echo "OK: claims[0]?.claim shortcut removed"
fi
if grep -nE 'per claim group|per-claim|group.*claim_id' commands/council.md >/dev/null \
  && grep -nE 'bypassed: fewer than 3 bundles' commands/council.md >/dev/null; then
  echo "OK: council.md Phase 2.5 states per-claim grouping and per-claim bypass reason"
else
  echo "FAIL: council.md Phase 2.5 missing per-claim grouping/bypass text"; fail=1
fi

COUNCIL_TEST_REPO="$TR" node --input-type=module <<'JS'
import { runCouncil } from './skills/council/workflow.js'
process.chdir(process.env.COUNCIL_TEST_REPO)

const crossPrompts = []
const agent = async (prompt, opts) => {
  if (opts.phase === 'Extract') {
    return {
      claims: [
        { claim: 'CLAIM_C0_TEXT', source_locator: 'f:1', claim_type: 'factual' },
        { claim: 'CLAIM_C1_TEXT', source_locator: 'f:2', claim_type: 'factual' },
      ],
    }
  }
  if (opts.phase === 'Investigate') {
    if (opts.label === 'inv:c0:paranoid-ic') {
      return {
        bundles: [
          { tool_use_id: 'c0-a', raw_blob: 'C0_BUNDLE_A', file_line: 'f:1', reproducible_command: 'e' },
          { tool_use_id: 'c0-b', raw_blob: 'C0_BUNDLE_B', file_line: 'f:1', reproducible_command: 'e' },
          { tool_use_id: 'c0-c', raw_blob: 'C0_BUNDLE_C', file_line: 'f:1', reproducible_command: 'e' },
        ],
      }
    }
    if (opts.label === 'inv:c0:skeptic-ic') return { bundles: [] }
    if (opts.label === 'inv:c1:paranoid-ic') {
      return { bundles: [{ tool_use_id: 'c1-a', raw_blob: 'C1_BUNDLE_A', file_line: 'f:2', reproducible_command: 'e' }] }
    }
    if (opts.label === 'inv:c1:skeptic-ic') {
      return { bundles: [{ tool_use_id: 'c1-b', raw_blob: 'C1_BUNDLE_B', file_line: 'f:2', reproducible_command: 'e' }] }
    }
    return { bundles: [] }
  }
  if (opts.phase === 'Cross-review') {
    crossPrompts.push({ label: opts.label, prompt })
    return { ranking: ['A', 'B'] }
  }
  if (opts.phase === 'Phase4') {
    return { briefs: [], struck_lines: [] }
  }
  if (opts.label === 'council-judge') {
    return {
      verdicts: [
        { claim: 'CLAIM_C0_TEXT', claim_id: 'c0', verdict: 'VERIFIED', confidence: 85, evidence_blob: 'x' },
        { claim: 'CLAIM_C1_TEXT', claim_id: 'c1', verdict: 'VERIFIED', confidence: 85, evidence_blob: 'x' },
      ],
      struck_lines: [],
    }
  }
  return null
}

const r = await runCouncil({
  args: { scope: 'session', claim: 'two-claim cross-review probe' },
  agent,
  phase: () => {},
  parallel: async (fns) => Promise.all(fns.map((f) => f())),
})
if (!r.ok) throw new Error('runCouncil failed: ' + JSON.stringify(r))

const c0Prompts = crossPrompts.filter((p) => p.label.startsWith('cross:c0:'))
const c1Prompts = crossPrompts.filter((p) => p.label.startsWith('cross:c1:'))
if (c0Prompts.length !== 3) throw new Error('expected 3 c0 cross-reviewer spawns, got ' + c0Prompts.length)
if (c1Prompts.length !== 0) throw new Error('expected 0 c1 cross-reviewer spawns, got ' + c1Prompts.length)
for (const p of c0Prompts) {
  if (!p.prompt.includes('CLAIM_C0_TEXT')) throw new Error('c0 prompt missing c0 claim text')
  if (p.prompt.includes('CLAIM_C1_TEXT')) throw new Error('c0 prompt leaked c1 claim text')
  if (p.prompt.includes('C1_BUNDLE')) throw new Error('c0 prompt leaked a c1 bundle')
}
console.log('OK: per-claim cross-review isolates c0 bundles/text from c1, bypasses c1')
JS

# WP 2-08 — Borda label map, empty-fleet exit 5, degraded judge fails closed.
if grep -nF 'self-verify-${claimId}' skills/council/workflow.js; then
  echo "FAIL: workflow.js still fabricates a self-verify bundle id"; fail=1
else
  echo "OK: no fabricated self-verify bundle id"
fi

COUNCIL_TEST_REPO="$TR" node --input-type=module <<'JS'
import { readFileSync, existsSync } from 'node:fs'
import { runCouncil } from './skills/council/workflow.js'
import { CLAIM_TYPES, ClaimsSchema } from './skills/council/workflow-schemas.js'
process.chdir(process.env.COUNCIL_TEST_REPO)

if (!CLAIM_TYPES.includes('behavioral')) throw new Error('CLAIM_TYPES missing behavioral')
if (ClaimsSchema.properties.unaudited) throw new Error('ClaimsSchema still has unaudited')
if (!ClaimsSchema.properties.un_audited) throw new Error('ClaimsSchema missing un_audited')
const req = ClaimsSchema.properties.claims.items.required
for (const k of ['claim', 'source_locator', 'claim_type', 'load_weight']) {
  if (!req.includes(k)) throw new Error('claim record missing required ' + k)
}
console.log('OK: ClaimsSchema matches extractor claim_type and un_audited')

function reportText(r) {
  const m = String(r.stdout || '').match(/Council report: (\S+)/)
  if (!m) throw new Error('no Council report line\n' + r.stdout + '\n' + r.stderr)
  return readFileSync(m[1], 'utf8')
}

const cross = []
const agent = async (_prompt, opts) => {
  if (opts.phase === 'Investigate') {
    if (opts.label === 'inv:c0:paranoid-ic') {
      return {
        bundles: [
          { tool_use_id: 'b0', raw_blob: 'BLOB_0', file_line: 'f:1', reproducible_command: 'true' },
          { tool_use_id: 'b1', raw_blob: 'BLOB_1', file_line: 'f:2', reproducible_command: 'true' },
          { tool_use_id: 'b2', raw_blob: 'BLOB_2', file_line: 'f:3', reproducible_command: 'true' },
        ],
      }
    }
    return { bundles: [] }
  }
  if (opts.phase === 'Cross-review') {
    cross.push({ label: opts.label, prompt: _prompt })
    return { ranking: ['B', 'A'] }
  }
  if (opts.phase === 'Phase4') return { briefs: [], struck_lines: [] }
  if (opts.label === 'council-judge') {
    return {
      verdicts: [{ claim: 'borda probe', claim_id: 'c0', verdict: 'UNVERIFIED', confidence: 50, evidence_blob: 'b' }],
      struck_lines: [],
    }
  }
  return null
}
const ranked = await runCouncil({
  args: { scope: 'claim', claim: 'borda probe' },
  agent,
  phase: () => {},
  parallel: async (fns) => Promise.all(fns.map((f) => f())),
  shuffle: (items) => items.slice(),
})
if (!ranked.ok) throw new Error('borda run failed: ' + JSON.stringify(ranked))
for (const p of cross) {
  const ri = Number(p.label.split(':').pop())
  const own = `tool_use_id=b${ri}`
  if (p.prompt.includes(own)) throw new Error('reviewer ' + ri + ' saw its own bundle')
}
const rankedReport = reportText(ranked)
if (!rankedReport.includes('bundle_2=2') || !rankedReport.includes('bundle_1=1') || !rankedReport.includes('bundle_0=0')) {
  throw new Error('Borda scores did not follow the per-reviewer label map:\n' + rankedReport)
}
console.log('OK: Borda attributes B>A to the bundles each reviewer saw, not the global index')

const failed = await runCouncil({
  args: { scope: 'claim', claim: 'fleet down' },
  agent: async () => null,
  phase: () => {},
  parallel: async (fns) => Promise.all(fns.map((f) => f())),
})
if (failed.ok || failed.exit_code !== 5) {
  throw new Error('expected exit 5, got ' + JSON.stringify(failed))
}
if (failed.handoff && existsSync(failed.handoff.judge)) {
  throw new Error('exit 5 wrote a judge file')
}
if (JSON.stringify(failed).includes('self-verify-c0')) {
  throw new Error('exit 5 response contains a fabricated bundle id')
}
console.log('OK: investigator fleet failure exits 5 with no fabricated bundles')

async function diffRun(judge) {
  return runCouncil({
    args: { scope: 'diff', claim: 'diff probe' },
    agent: async (_prompt, opts) => {
      if (opts.phase === 'Extract') {
        return {
          claims: [{ claim: 'diff claim', source_locator: 'src/a.js:4', claim_type: 'factual', load_weight: 5 }],
        }
      }
      if (opts.phase === 'Investigate') {
        if (String(opts.label).endsWith(':logic')) {
          return {
            bundles: [{ tool_use_id: 't-real', raw_blob: 'REAL_BLOB', file_line: 'src/a.js:4', reproducible_command: 'true' }],
          }
        }
        return { bundles: [] }
      }
      if (opts.label === 'council-judge') return judge
      return null
    },
    phase: () => {},
    parallel: async (fns) => Promise.all(fns.map((f) => f())),
  })
}
const blocked = await diffRun(null)
if (!blocked.ok) throw new Error('degraded judge run failed: ' + JSON.stringify(blocked))
const blockedReport = reportText(blocked)
if (!blockedReport.includes('**BLOCKED**')) throw new Error('degraded judge did not block the commit gate')
if (!blockedReport.includes('degraded-judge: council-judge spawn failed')) {
  throw new Error('report missing degraded-judge reason')
}
if (!blockedReport.includes('[CRITICAL]')) throw new Error('fallback finding is not critical')
console.log('OK: degraded finding[] judge fails closed and names the reason')

const passed = await diffRun({
  findings: [{
    file: 'src/a.js', line: 4, severity: 'warning', category: 'quality',
    description: 'ordinary warning', suggestion: 'none', confidence: 90, tool_use_id: 't-real',
  }],
  struck_lines: [],
})
if (!passed.ok) throw new Error('normal judge run failed: ' + JSON.stringify(passed))
const passedReport = reportText(passed)
if (!passedReport.includes('**PASSED**')) throw new Error('normal warning judge did not pass the gate')
if (passedReport.includes('degraded-judge:')) throw new Error('normal judge report mentions degraded-judge')
console.log('OK: normal finding[] judge path stays PASSED')
JS
# CDT-411: Step 4 finalize passes Phase 2.5 placeholders.
step4=$(awk '/^## Step 4:/,/^## Step 5:/' commands/council.md)
for flag in --cross-review-status --cross-review-rankings --cross-review-scores; do
  if printf '%s\n' "$step4" | grep -qF -- "$flag"; then
    echo "OK: Step 4 finalize has $flag"
  else
    echo "FAIL: Step 4 finalize missing $flag"; fail=1
  fi
done
if printf '%s\n' "$step4" | grep -qF '[--task-id'; then
  echo "FAIL: Step 4 finalize still contains [--task-id"; fail=1
else
  echo "OK: Step 4 finalize has no [--task-id pseudo-syntax"
fi
if grep -qF 'Do not flag a bundle at confidence' commands/council.md; then
  echo "OK: WEAK_EVIDENCE confidence floor is stated"
else
  echo "FAIL: WEAK_EVIDENCE confidence floor sentence missing"; fail=1
fi

# CDT-380: no ic4/ic5 spawn for council roles. Phase 3 keeps dev-team:<agent>.
if grep -nE 'subagent_type: "dev-team:ic[45]"' commands/council.md; then
  echo "FAIL: commands/council.md still spawns ic4 or ic5"; fail=1
else
  echo "OK: commands/council.md has no dev-team:ic4/ic5 spawn"
fi
if grep -nE "agentType: 'dev-team:ic[45]'" skills/council/workflow.js; then
  echo "FAIL: workflow.js still spawns ic4 or ic5"; fail=1
else
  echo "OK: workflow.js has no dev-team:ic4/ic5 agentType"
fi
if grep -qF "agentType: 'dev-team:finder'" skills/council/workflow.js \
  && grep -qF "agentType: 'dev-team:council-scribe'" skills/council/workflow.js \
  && grep -qF "agentType: 'dev-team:council-judge'" skills/council/workflow.js; then
  echo "OK: workflow.js agentTypes are finder, council-scribe, council-judge"
else
  echo "FAIL: workflow.js missing finder/council-scribe/council-judge"; fail=1
fi

# CDT-325: Test 1 must require that a normal run does not write lessons.md.
# The old step ("feedback memory written to") would fail this check.
test1=$(awk '/^### Test 1/,/^### Test 2/' specs/core/SPEC-013-adversarial-council-tribunal.md)
if printf '%s\n' "$test1" | grep -qF 'feedback memory written to'; then
  echo "FAIL: SPEC-013 Test 1 still requires a lessons.md write"; fail=1
elif printf '%s\n' "$test1" | grep -qF 'Phase 7 is DEFERRED' \
  && printf '%s\n' "$test1" | grep -qF 'must NOT write lessons.md'; then
  echo "OK: SPEC-013 Test 1 says Phase 7 is DEFERRED and must NOT write lessons.md"
else
  echo "FAIL: SPEC-013 Test 1 missing deferred lessons.md wording"; fail=1
fi
if grep -qF 'Phase 7 is a no-op' skills/council/flavors/diff-mode.md; then
  echo "FAIL: diff-mode.md still says Phase 7 is a no-op"; fail=1
elif grep -qF 'Phase 7 is DEFERRED' skills/council/flavors/diff-mode.md \
  && grep -qF 'does not write lessons.md' skills/council/flavors/diff-mode.md; then
  echo "OK: diff-mode.md says Phase 7 is DEFERRED and does not write lessons.md"
else
  echo "FAIL: diff-mode.md missing deferred lessons.md wording"; fail=1
fi

# Council --blind reviewers use the tool-less prompt, not the bug-hunt prompts.
b2=$(awk '/^### B2 /,/^### B3 /' commands/council.md)
if printf '%s\n' "$b2" | grep -qF 'skills/council/prompts/blind-scribe.md' \
  && printf '%s\n' "$b2" | grep -qF 'dev-team:council-scribe' \
  && printf '%s\n' "$b2" | grep -qF '{{FILE_TEXT}}' \
  && ! printf '%s\n' "$b2" | grep -qF 'unconstrained-reviewer.md' \
  && ! printf '%s\n' "$b2" | grep -qF 'lens-reviewer.md'; then
  echo "OK: council blind spawns use blind-scribe.md and council-scribe"
else
  echo "FAIL: council blind spawn sites still use a tool-using reviewer prompt"; fail=1
fi
if grep -qF 'Read, Bash' skills/council/prompts/unconstrained-reviewer.md \
  && grep -qF 'Read, Bash' skills/council/prompts/lens-reviewer.md; then
  echo "OK: bug-hunt reviewer prompts still allow Read and Bash"
else
  echo "FAIL: shared reviewer prompts lost their tool instructions"; fail=1
fi
if grep -qF 'head -c 8192' commands/council.md \
  && grep -qF 'must not call Read, Bash, Glob, or Grep' skills/council/prompts/blind-scribe.md; then
  echo "OK: blind file text is preloaded and the scribe is tool-less"
else
  echo "FAIL: blind file preload or tool-less scribe rule missing"; fail=1
fi

# CDT-275 static: guarded preflight JSON, tokens passthrough, handoff trap.
if grep -qF 'JSON.parse(pre.stdout)' skills/council/workflow.js; then
  echo "FAIL: workflow.js still has unguarded JSON.parse(pre.stdout)"; fail=1
else
  echo "OK: preflight JSON.parse is not bare"
fi
if grep -qF 'parsePreflightStdout(pre.stdout)' skills/council/workflow.js \
  && grep -qF 'exit_code: 1' skills/council/workflow.js \
  && grep -qF -- '--tokens-file' skills/council/workflow.js \
  && grep -qF 'rmSync(handoff.dir' skills/council/workflow.js \
  && grep -qF 'TASK_PATH_NOTICE' skills/council/workflow.js \
  && grep -qF 'LIGHT_NOTICE' skills/council/workflow.js; then
  echo "OK: workflow.js parse guard, tokens-file, handoff trap, exit-2 notices"
else
  echo "FAIL: workflow.js missing CDT-275 guards"; fail=1
fi

# CDT-275 F-18: SKILL.md must not cite a missing command or a stale tier-triage scope.
if grep -qF 'commands/blind-review.md' skills/council/SKILL.md; then
  echo "FAIL: SKILL.md still cites commands/blind-review.md"; fail=1
else
  echo "OK: SKILL.md does not cite commands/blind-review.md"
fi
if grep -qF 'tier-triage --diff only' skills/council/SKILL.md \
  || grep -qF -- '--diff` scope only' skills/council/SKILL.md \
  || grep -qF -- '--diff scope only' skills/council/SKILL.md; then
  echo "FAIL: SKILL.md still says tier-triage is --diff only"; fail=1
else
  echo "OK: SKILL.md does not limit tier-triage to --diff only"
fi
if grep -qF 'under 60 lines' skills/council/SKILL.md; then
  echo "FAIL: SKILL.md still states a 60-line flavor cap"; fail=1
else
  echo "OK: SKILL.md has no 60-line flavor cap"
fi

# BH-C013 / SPEC-003 MC-4: the 8 tribunal templates carry Output mode: terse.
for f in investigator cross-reviewer claim-extractor plan-extractor phase4-brief judge tier-triage topic-classifier; do
  if grep -qF 'Output mode: terse' "skills/council/prompts/${f}.md"; then
    echo "OK: ${f}.md has Output mode: terse"
  else
    echo "FAIL: ${f}.md missing Output mode: terse"; fail=1
  fi
done

# CDT-275 F-24: diff flavors do not return a finding array or demand a fix.
for f in logic quality security simplification compliance; do
  if grep -qF 'Return a JSON array' "skills/council/flavors/${f}.md" \
    || grep -qF 'MUST suggest a concrete fix' "skills/council/flavors/${f}.md"; then
    echo "FAIL: ${f}.md still has a finding-array or fix-suggestion contract"; fail=1
  else
    echo "OK: ${f}.md has no finding-array or fix-suggestion contract"
  fi
done
if grep -qF 'bash "$SCAN"' skills/council/flavors/security.md; then
  echo "FAIL: security.md still runs the scanner"; fail=1
else
  echo "OK: security.md does not run the scanner"
fi
if grep -qF '1k lines' skills/council/flavors/compliance.md \
  || grep -qF '2k hard' skills/council/flavors/compliance.md; then
  echo "FAIL: compliance.md still hard-codes invented size caps"; fail=1
else
  echo "OK: compliance.md has no invented size caps"
fi
if grep -qF 'Nitpick is a real severity' skills/council/flavors/simplification.md; then
  echo "OK: simplification.md states nitpick is a real severity"
else
  echo "FAIL: simplification.md missing nitpick severity sentence"; fail=1
fi
if grep -qF 'reason_if_empty' skills/council/flavors/paranoid-ic.md; then
  echo "FAIL: paranoid-ic.md still references reason_if_empty"; fail=1
else
  echo "OK: paranoid-ic.md does not reference reason_if_empty"
fi
if grep -qF 'role: preset' skills/council/flavors/diff-mode.md; then
  echo "FAIL: diff-mode.md still claims role: preset"; fail=1
else
  echo "OK: diff-mode.md does not claim role: preset"
fi

exit $fail
