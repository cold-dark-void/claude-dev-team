#!/usr/bin/env bash
# skills/lib/chunked-parallel-test.sh — unit tests for the shared
# chunkedParallel partition, plus the one-home / no-copy / coupling guards
# (SPEC-013 § Spawn concurrency cap, CDT-573 review).
#
# THIS SCRIPT IS A SUBPROCESS CLI — NEVER SOURCE IT.
# Run: bash skills/lib/chunked-parallel-test.sh
#
# Both consumers run this suite from their own gate so the shared partition is
# proven under each skill: skills/council/test-workflow-static.sh and
# skills/fix-ticket/test-workflow.sh. Per-skill integration tests (the three
# council chunk() sites; the fix-ticket refuter wave) stay in those suites.
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
MOD="$HERE/chunked-parallel.js"
COUNCIL_WF="$ROOT/skills/council/workflow.js"
FT_WF="$ROOT/skills/fix-ticket/workflow.js"

# shellcheck source=../../tests/lib/skip.sh
. "$ROOT/tests/lib/skip.sh"
require_cmd node

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'OK: %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; }

cd "$ROOT" || exit 1

# ---- one home: the partition is defined once, imported twice -----------------
if [ -f "$MOD" ]; then
  ok "skills/lib/chunked-parallel.js exists"
else
  bad "skills/lib/chunked-parallel.js is missing"
fi

# Scan shipped JS only: the suites quote the function name in their greps.
defs=$(grep -rlE --include='*.js' 'async function chunkedParallel' skills agents commands tools 2>/dev/null | LC_ALL=C sort)
if [ "$defs" = "skills/lib/chunked-parallel.js" ]; then
  ok "chunkedParallel is defined in exactly one file (no copy in the tree)"
else
  bad "chunkedParallel definitions: $(printf '%s' "$defs" | tr '\n' ' ') — want skills/lib/chunked-parallel.js only"
fi

for wf in "$COUNCIL_WF" "$FT_WF"; do
  rel=${wf#"$ROOT/"}
  if grep -qE "^import \{ chunkedParallel \} from '\.\./lib/chunked-parallel\.js'$" "$wf"; then
    ok "$rel imports chunkedParallel from skills/lib/chunked-parallel.js"
  else
    bad "$rel does not import the shared module"
  fi
  if grep -qE 'function chunkedParallel' "$wf"; then
    bad "$rel still defines a local chunkedParallel copy"
  else
    ok "$rel defines no local chunkedParallel copy"
  fi
  # The host parallel() may only be reached through the shared module.
  if [ "$(grep -cE 'await parallel\(' "$wf")" -eq 0 ]; then
    ok "$rel calls the host parallel() nowhere directly"
  else
    bad "$rel has a direct await parallel() call outside chunkedParallel"
  fi
done

# ---- self-containment: the module couples to nothing -------------------------
if grep -qE "^(import |export .* from |.*require\()" "$MOD"; then
  bad "chunked-parallel.js is not self-contained (it has an import/require)"
else
  ok "chunked-parallel.js has no imports — it pulls in no engine, schema, or tmpdir"
fi
if [ "$(grep -cE 'await parallel\(' "$MOD")" -eq 1 ]; then
  ok "the host parallel() is called only from chunkedParallel (one site)"
else
  bad "chunked-parallel.js direct parallel() sites != 1"
fi
# Cross-skill coupling guard: fix-ticket must never import from skills/council.
if grep -qE "from '[^']*council/" "$FT_WF"; then
  bad "fix-ticket/workflow.js imports a skills/council path (forbidden coupling)"
else
  ok "fix-ticket/workflow.js imports nothing from skills/council"
fi
# The batch rule must stay documented where it is implemented.
if grep -qF 'ceil(W/n)' "$MOD"; then
  ok "chunked-parallel.js documents the ceil(W/n) batch rule it implements"
else
  bad "chunked-parallel.js batch rule undocumented"
fi
# The host fan-out global may be invoked in exactly one file: this module.
fan=$(grep -rcE --include='*.js' 'await parallel\(' skills agents commands tools 2>/dev/null \
  | awk -F: '$2 > 0 { print $1 "=" $2 }' | LC_ALL=C sort)
if [ "$fan" = "skills/lib/chunked-parallel.js=1" ]; then
  ok "the host parallel() is awaited in one file only (skills/lib/chunked-parallel.js)"
else
  bad "parallel() call sites: $fan"
fi
if node --check "$MOD"; then
  ok "chunked-parallel.js node --check"
else
  bad "chunked-parallel.js node --check"
fi

# ---- unit: the partition itself (three-way contract) ------------------------
if node --input-type=module <<'JS'
import { chunkedParallel } from './skills/lib/chunked-parallel.js'

let active = 0
let peak = 0
function jobs(w) {
  return Array.from({ length: w }, (_u, i) => async () => {
    active += 1
    if (active > peak) peak = active
    await new Promise((r) => setTimeout(r, 1))
    active -= 1
    return i
  })
}
function stub() {
  const sizes = []
  const arities = []
  const par = async (fns) => {
    sizes.push(fns.length)
    for (const f of fns) arities.push(f.length)
    return Promise.all(fns.map((f) => f()))
  }
  return { par, sizes, arities }
}
const ceilDiv = (w, n) => Math.ceil(w / n)
// The contract: a wave of <= n jobs is one batch; longer waves are ceil(W/n)
// batches of <= n with a partial tail.
function expectedBatches(w, n) {
  if (w <= n) return [w]
  const out = []
  for (let left = w; left > 0; left -= n) out.push(Math.min(n, left))
  return out
}

for (const unset of [undefined, null, 0, -1, '2', 1.5, NaN]) {
  const s = stub()
  peak = 0
  const out = await chunkedParallel(jobs(7), unset, s.par)
  if (s.sizes.length !== 1 || s.sizes[0] !== 7) {
    throw new Error(`n=${String(unset)}: unbounded path must be one parallel() of all jobs, got ${JSON.stringify(s.sizes)}`)
  }
  if (JSON.stringify(out) !== JSON.stringify([0, 1, 2, 3, 4, 5, 6])) {
    throw new Error(`n=${String(unset)}: results must stay index-aligned`)
  }
  if (peak !== 7) throw new Error(`n=${String(unset)}: unbounded in-flight must be the whole wave`)
}
console.log('OK: chunkedParallel unbounded/null/negative/non-integer = one parallel() call, byte-identical path')

for (const [w, n] of [[7, 3], [6, 2], [5, 2], [4, 4], [3, 8], [1, 1], [4, 1], [0, 2]]) {
  const s = stub()
  peak = 0
  const out = await chunkedParallel(jobs(w), n, s.par)
  const want = expectedBatches(w, n)
  if (JSON.stringify(s.sizes) !== JSON.stringify(want)) {
    throw new Error(`w=${w} n=${n}: batches ${JSON.stringify(s.sizes)} want ${JSON.stringify(want)}`)
  }
  if (w > 0 && s.sizes.length !== ceilDiv(w, n)) {
    throw new Error(`w=${w} n=${n}: batch count ${s.sizes.length} != ceil(W/n)`)
  }
  if (w > n && w % n !== 0 && s.sizes[s.sizes.length - 1] !== w % n) {
    throw new Error(`w=${w} n=${n}: the final batch is not the partial tail (${w % n})`)
  }
  if (s.sizes.some((b) => b > n)) throw new Error(`w=${w} n=${n}: a batch exceeded the cap`)
  if (JSON.stringify(out) !== JSON.stringify(Array.from({ length: w }, (_u, i) => i))) {
    throw new Error(`w=${w} n=${n}: chunking reordered results`)
  }
  if (peak > n) throw new Error(`w=${w} n=${n}: ${peak} jobs in flight exceeded cap ${n}`)
  if (s.arities.some((a) => a !== 0)) throw new Error(`w=${w} n=${n}: a job received sibling-batch output`)
}
console.log('OK: chunkedParallel batches are <= n, count == ceil(W/n), final batch partial, order preserved, in-flight <= n')

{
  const seq = []
  for (const j of jobs(4)) seq.push(await j())
  const s = stub()
  const par = []
  const n1 = await chunkedParallel(
    Array.from({ length: 4 }, (_u, i) => async () => { par.push(i); return i }),
    1,
    s.par,
  )
  if (JSON.stringify(s.sizes) !== '[1,1,1,1]') throw new Error('n=1 is not one job per batch: ' + JSON.stringify(s.sizes))
  if (JSON.stringify(n1) !== JSON.stringify(seq)) throw new Error('n=1 != sequential')
  console.log('OK: chunkedParallel(x, 1) == sequential spawn-per-spawn (the judge-parts shape)')
}
JS
then
  ok "node partition contract"
else
  bad "node partition contract"
fi

printf '\nOK=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
