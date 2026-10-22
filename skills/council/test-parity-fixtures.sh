#!/usr/bin/env bash
# F-29: parity fixtures are wired. false-claim stays false; true-claim stays true.
# diff-mode.md stays (test-workflow-static.sh references it) and does not claim
# to be the preset file.
# CDT-573 T5: Task-path contract line vs Workflow chunking — batch-partition
# parity at unbounded and cap=2 for all three parallel() sites (SPEC-013 AC9).
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PAR="$ROOT/skills/council/fixtures/parity"
fail=0
cd "$ROOT"

# shellcheck source=../../tests/lib/skip.sh
. "$ROOT/tests/lib/skip.sh"
# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
require_cmd jq node
hermetic_init

ok() { echo "OK: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

claim="$(jq -r .claim "$PAR/false-claim.json")"
if printf '%s' "$claim" | grep -q 'exponential backoff' \
  && ! grep -q 'exponential backoff' commands/retro.md; then
  ok "false-claim premise: retro.md has no exponential backoff"
else
  bad "false-claim fixture no longer matches commands/retro.md"
fi

true_claim="$(jq -r .claim "$PAR/true-claim.json")"
if printf '%s' "$true_claim" | grep -q 'tools:' \
  && grep -q 'tools: ""' agents/council-judge.md; then
  ok "true-claim premise: council-judge tools are empty"
else
  bad "true-claim fixture no longer matches agents/council-judge.md"
fi

if grep -q '^diff --git' "$PAR/mini-diff.patch"; then
  ok "mini-diff.patch is a unified diff"
else
  bad "mini-diff.patch is not a diff"
fi

note="skills/council/flavors/diff-mode.md"
if [ -f "$note" ] \
  && grep -qF 'Presets are not files' "$note" \
  && grep -qF 'Phase 7 is DEFERRED' "$note" \
  && grep -qF 'does not write lessons.md' "$note" \
  && grep -qF 'skills/council/flavors/diff-mode.md' skills/council/test-workflow-static.sh; then
  ok "diff-mode.md is a note, not a preset file, and the static test still references it"
else
  bad "diff-mode.md missing, still a preset, or no longer referenced"
fi

if grep -q 'flavors/diff-mode.md' skills/council/engine.sh skills/council/workflow.js; then
  bad "engine or workflow loads flavors/diff-mode.md"
else
  ok "engine and workflow do not load flavors/diff-mode.md"
fi

# ---- CDT-573 T5: Task-path contract vs Workflow chunking (SPEC-013 AC9) -----
# One partition rule, two paths. The Task path is a prose contract line the
# orchestrator obeys; the Workflow path is chunkedParallel. This gate asserts
# they split the same wave the same way at unbounded and at cap=2, for all
# three parallel() sites.
PREPO="$TMPDIR/parity-repo"
mkdir -p "$PREPO"
git init -q "$PREPO"
OBS="$TMPDIR/observed.tsv"

SPEC='specs/core/SPEC-013-adversarial-council-tribunal.md'
FENCE='skills/council/spawn-contract.md'
# Take the canonical sentence from SPEC-013 at run time. This suite never
# retypes it: the T6 gate (`no site retypes the sentence`, test-concurrency.sh)
# requires one copy of that string in the tree, in the fence file.
SPEC_SENT=$(sed -n 's/.*`\([^`]*spawns in flight[^`]*\)`.*/\1/p' "$SPEC" | head -1)
if [ -n "$SPEC_SENT" ] \
  && printf '%s' "$SPEC_SENT" | grep -qF 'at most <N> spawns in flight' \
  && printf '%s' "$SPEC_SENT" | grep -qF 'await all returns, then the next batch' \
  && printf '%s' "$SPEC_SENT" | grep -qF 'Never exceed.'; then
  ok "the Task-path contract line is the single canonical sentence"
else
  bad "SPEC-013 lost the contract line the partition model derives from"
fi
# T6 owns the fence file; when it lands, the fence MUST carry that same
# sentence verbatim, which is what makes this model apply to the Task path.
if [ -f "$FENCE" ]; then
  if grep -qF -- "$SPEC_SENT" "$FENCE"; then
    ok "the T6 fence carries the SPEC-013 sentence verbatim"
  else
    bad "$FENCE does not carry the canonical sentence"
  fi
else
  ok "no fence file yet (T6 in flight) — the model applies to SPEC-013 directly"
fi

# partition <W> <N|unbounded> — the Task-path reading of that sentence: at most
# N in flight, spawn a batch, await all returns, then the next batch. A wave of
# <= N is one batch; the tail is partial; no cap is one wave.
partition() {
  awk -v w="$1" -v n="$2" 'BEGIN{
    if (n == "unbounded" || n + 0 < 1) { printf "%d", w; exit }
    b = int(w / n); if (w % n) b++
    s = ""; left = w
    for (i = 0; i < b; i++) { k = (left >= n) ? n : left; s = s (i ? "," : "") k; left -= k }
    printf "%s", s
  }'
}

for w in 1 2; do
  if [ "$(partition "$w" 2)" = "$w" ]; then
    ok "model: a wave of $w at cap 2 stays one batch"
  else
    bad "model: wave of $w at cap 2 must stay one batch (got $(partition "$w" 2))"
  fi
done
if [ "$(partition 5 2)" = "2,2,1" ] && [ "$(partition 6 2)" = "2,2,2" ] && [ "$(partition 7 unbounded)" = "7" ]; then
  ok "model: ceil(W/N) batches of <= N with a partial tail"
else
  bad "model partition is wrong: 5/2=$(partition 5 2) 6/2=$(partition 6 2) 7/unb=$(partition 7 unbounded)"
fi

COUNCIL_TEST_REPO="$PREPO" node --input-type=module <<'JS' > "$OBS" 2>"$TMPDIR/parity.err"
import { runCouncil } from './skills/council/workflow.js'
process.chdir(process.env.COUNCIL_TEST_REPO)

const agent = async (_prompt, opts) => {
  if (opts.phase === 'Extract') {
    return {
      claims: [
        { claim: 'PARITY_A', source_locator: 'f:1', claim_type: 'factual' },
        { claim: 'PARITY_B', source_locator: 'f:2', claim_type: 'factual' },
        { claim: 'PARITY_C', source_locator: 'f:3', claim_type: 'factual' },
      ],
    }
  }
  if (opts.phase === 'Investigate') {
    if (opts.label === 'inv:c0:paranoid-ic') {
      return {
        bundles: [
          { tool_use_id: 'p0', raw_blob: 'PB_0', file_line: 'f:1', reproducible_command: 'true' },
          { tool_use_id: 'p1', raw_blob: 'PB_1', file_line: 'f:1', reproducible_command: 'true' },
        ],
      }
    }
    if (opts.label === 'inv:c0:skeptic-ic') {
      return { bundles: [{ tool_use_id: 'p2', raw_blob: 'PB_2', file_line: 'f:1', reproducible_command: 'true' }] }
    }
    return { bundles: [{ tool_use_id: 'p9', raw_blob: 'PB_9', file_line: 'f:9', reproducible_command: 'true' }] }
  }
  if (opts.phase === 'Cross-review') return { ranking: ['A', 'B'] }
  if (opts.phase === 'Phase4') return { briefs: [], struck_lines: [] }
  if (opts.label === 'council-judge') {
    return {
      verdicts: [
        { claim: 'PARITY_A', claim_id: 'c0', verdict: 'VERIFIED', confidence: 90, evidence_blob: 'x' },
        { claim: 'PARITY_B', claim_id: 'c1', verdict: 'VERIFIED', confidence: 90, evidence_blob: 'x' },
        { claim: 'PARITY_C', claim_id: 'c2', verdict: 'VERIFIED', confidence: 90, evidence_blob: 'x' },
      ],
      struck_lines: [],
    }
  }
  return null
}

for (const mode of ['unbounded', 'cap2']) {
  const batches = []
  let currentPhase = 'none'
  const r = await runCouncil({
    args: { scope: 'session', claim: 'parity wave probe', ...(mode === 'cap2' ? { concurrency: 2 } : {}) },
    agent,
    phase: (name) => { currentPhase = name },
    parallel: async (fns) => {
      batches.push({ phase: currentPhase, n: fns.length })
      return Promise.all(fns.map((f) => f()))
    },
  })
  if (!r.ok) throw new Error(mode + ' run failed: ' + JSON.stringify(r))
  for (const site of ['Investigate', 'Cross-review', 'Phase4']) {
    const sizes = batches.filter((b) => b.phase === site).map((b) => b.n)
    const w = sizes.reduce((a, b) => a + b, 0)
    // Prefixed row: finalize stdout also lands on this stream (engine report
    // line), so the reader takes only PARITY rows.
    console.log(`PARITY\t${mode}\t${site}\t${w}\t${sizes.join(',')}`)
  }
}
JS
rc=$?
if [ "$rc" -ne 0 ]; then
  bad "parity harness exited $rc"
  cat "$TMPDIR/parity.err" >&2 || true
fi

ROWS="$TMPDIR/parity-rows.tsv"
awk -F'\t' '$1=="PARITY"{print $2"\t"$3"\t"$4"\t"$5}' "$OBS" > "$ROWS"

sites_seen=0
while IFS=$'\t' read -r mode site w got || [ -n "$mode" ]; do
  [ -n "$mode" ] || continue
  cap="unbounded"
  [ "$mode" = "cap2" ] && cap=2
  want="$(partition "$w" "$cap")"
  if [ "$got" = "$want" ]; then
    ok "parity: $mode $site wave of $w chunks as $want on both paths"
  else
    bad "parity: $mode $site wave of $w — Workflow '$got' != Task contract '$want'"
  fi
  sites_seen=$((sites_seen + 1))
done < "$ROWS"
[ "$sites_seen" -eq 6 ] \
  && ok "parity: all three parallel() sites covered at unbounded and cap=2" \
  || bad "parity: observed $sites_seen site/mode rows, want 6"

if grep -qF 'function chunkedParallel' skills/lib/chunked-parallel.js \
  && grep -qF 'ceil' skills/lib/chunked-parallel.js \
  && grep -qF "from '../lib/chunked-parallel.js'" skills/council/workflow.js; then
  ok "the shared chunkedParallel module documents the ceil(W/n) rule and workflow.js imports it"
else
  bad "chunked-parallel.js missing its batch rule, or workflow.js does not import it"
fi

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "FAILURES PRESENT"; fi
exit "$fail"
