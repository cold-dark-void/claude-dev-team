#!/usr/bin/env bash
# council-judge-file-delivery (2026-10-12): judge input channel for large
# bundle sets. A tool-less judge (SPEC-013, `tools: ""`) cannot Read bundle
# part files, so an oversized bundle set is split into claim-atomic parts
# judged in sequential spawns (size-cap variant). This suite pins:
#   - JUDGE_BUNDLE_CAP_BYTES (fixed constant, no env/flag — M14(j) style)
#   - partitionJudgeParts grouping on the fixture, cap-atomic per claim,
#     claim-atomic (a raw_blob is never cut mid-bundle), document order
#   - the single-part path reuse of the unfiltered brief text (prompt
#     byte-identical to the pre-split render)
#   - the commands/council.md Task-path recipe names the cap and the merge
#
# Hermetic: node + jq only, no live council, writes only under TMPDIR.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# shellcheck source=../../tests/lib/skip.sh
. "$ROOT/tests/lib/skip.sh"
# shellcheck source=../../tests/lib/hermetic.sh
. "$ROOT/tests/lib/hermetic.sh"
hermetic_init

fail=0
ok() { echo "OK: $1"; }
fail_msg() { echo "FAIL: $1"; fail=1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/judge-size-cap-test.XXXXXX")"
trap 'rm -rf "$TMP"; hermetic_cleanup' EXIT

if ! ( require_cmd node jq ); then
  echo "SKIP: test-judge-size-cap.sh (node/jq unavailable)"
  exit 0
fi

FIX_DIR="$ROOT/skills/council/fixtures/judge-size-cap"
WF="$ROOT/skills/council/workflow.js"

node --input-type=module <<'JS' > "$TMP/out.txt" 2>&1
import { readFileSync } from 'node:fs'
import { partitionJudgeParts, JUDGE_BUNDLE_CAP_BYTES } from './skills/council/workflow.js'

const fx = JSON.parse(readFileSync('skills/council/fixtures/judge-size-cap/bundles.json', 'utf8'))
const ex = JSON.parse(readFileSync('skills/council/fixtures/judge-size-cap/expected-partition.json', 'utf8'))

const lines = []
const check = (label, cond) => lines.push(`${cond ? 'OK' : 'FAIL'}: ${label}`)

check('cap constant is 64000', JUDGE_BUNDLE_CAP_BYTES === 64000)

const underCap = partitionJudgeParts(ex.claims, fx.bundles, 100000)
check('under-cap run is a single part', underCap.length === 1)
check('under-cap part holds every claim', underCap[0].claims.length === 4)
check('under-cap part holds every bundle', underCap[0].bundles.length === 5)

const parts = partitionJudgeParts(ex.claims, fx.bundles, ex.cap_bytes)
check(`over-cap run is ${ex.expected_parts.length} parts`, parts.length === ex.expected_parts.length)
for (let i = 0; i < Math.min(parts.length, ex.expected_parts.length); i++) {
  const want = ex.expected_parts[i]
  check(
    `part ${i} claim_ids = [${want.claim_ids.join(', ')}]`,
    JSON.stringify(parts[i].claim_ids) === JSON.stringify(want.claim_ids),
  )
  check(
    `part ${i} bundles = [${want.tool_use_ids.join(', ')}]`,
    JSON.stringify(parts[i].bundles.map((b) => b.tool_use_id)) === JSON.stringify(want.tool_use_ids),
  )
}

// Claim-atomicity: every bundle appears in exactly one part, whole.
const seen = parts.flatMap((p) => p.bundles.map((b) => b.tool_use_id)).sort()
check(
  'every bundle lands in exactly one part, whole',
  JSON.stringify(seen) === JSON.stringify(fx.bundles.map((b) => b.tool_use_id).sort()),
)

// Oversized single claim: its own part, blob never cut.
const one = [{ claim_id: 'c0', claim: 'one' }]
const big = [{ claim_id: 'c0', tool_use_id: 't0', raw_blob: 'x'.repeat(5000), file_line: 'a:1', reproducible_command: 'cat a' }]
const solo = partitionJudgeParts(one, big, 100)
check('oversized single claim is one unsplit part', solo.length === 1 && solo[0].bundles[0].raw_blob.length === 5000)

console.log(lines.join('\n'))
JS

if [ $? -eq 0 ] && ! grep -q '^FAIL:' "$TMP/out.txt" && grep -q '^OK: cap constant is 64000' "$TMP/out.txt"; then
  grep -q '^FAIL:' "$TMP/out.txt" || ok "partitionJudgeParts: $(grep -c '^OK:' "$TMP/out.txt") checks green"
else
  fail_msg "partitionJudgeParts checks failed:"
  cat "$TMP/out.txt" >&2
fi

# Static wiring: the Judge section routes through the partition, and the
# single-part path reuses the unfiltered brief text.
if grep -q 'partitionJudgeParts(claims, orderedBundles, JUDGE_BUNDLE_CAP_BYTES)' "$WF" \
  && grep -q 'judgeParts.length === 1' "$WF" \
  && grep -q 'Buffer.byteLength(allBundlesBlock' "$WF"; then
  ok "workflow.js: judge section routes through the cap and reuses briefs on single-part runs"
else
  fail_msg "workflow.js: judge section missing the cap routing or single-part brief reuse"
fi

# Task-path recipe: commands/council.md names the cap, the claim-atomic
# split and the concat merge.
COUNCIL_MD="$ROOT/commands/council.md"
if grep -qF 'JUDGE_BUNDLE_CAP_BYTES = 64000' "$COUNCIL_MD" \
  && grep -qF 'claim-atomic' "$COUNCIL_MD" \
  && grep -q 'concat' "$COUNCIL_MD"; then
  ok "commands/council.md: judge fan-out recipe names the cap, claim-atomic split and merge"
else
  fail_msg "commands/council.md: judge fan-out recipe missing"
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: test-judge-size-cap.sh"
  exit 0
else
  echo "FAIL: test-judge-size-cap.sh"
  exit 1
fi
