/**
 * chunked-parallel.js — the ONE home of the Spawn concurrency cap partition
 * (SPEC-013 § Spawn concurrency cap, CDT-573).
 *
 * THIS IS AN IMPORTED ES MODULE — NEVER PASTE IT. Consumers import it by
 * relative path:
 *   skills/council/workflow.js     — the three fleet waves (chunk())
 *   skills/fix-ticket/workflow.js  — the refuter wave
 * Machine-check: bash skills/lib/chunked-parallel-test.sh
 *
 * Self-contained by design: no imports, no fs, no host globals. The host
 * fan-out arrives as the `parallel` argument, so this module couples to
 * nothing and every consumer stays import-independent of the other skill.
 *
 * Batch-synchronous fleet wave under a spawn cap (AC2/AC7/AC9).
 * `n` unset/null/undefined (or any non-positive-integer value the plan cannot
 * carry) and a wave of <= n jobs both take today's single `parallel(jobs)`
 * call, so the unbounded path is byte-identical. A longer wave runs
 * ceil(W/n) batches of <= n: spawn a batch, await every return, then the next
 * batch. The final batch is partial. Nothing is dropped to fit the cap —
 * queueing is not a spawn failure, so this never touches markDegraded and the
 * run keeps `verification_mode: full`.
 *
 * Blindness: `jobs` are thunks built before the first batch spawns, so a batch
 * cannot observe sibling-batch output; results concatenate in job order and
 * stay index-aligned with `jobs`, as `Promise.all` leaves them.
 *
 * @param {Array<() => Promise<any>>} jobs — the wave
 * @param {number|null|undefined} n — resolved cap (council plan.concurrency,
 *   fix-ticket args.concurrency). The caller resolves it; this module never
 *   resolves a cap layer of its own.
 * @param {(jobs: Array<Function>) => Promise<any[]>} parallel — host fan-out
 * @returns {Promise<any[]>} results, index-aligned with `jobs`
 */
export async function chunkedParallel(jobs, n, parallel) {
  const list = Array.isArray(jobs) ? jobs : []
  const cap = Number.isInteger(n) && n >= 1 ? n : 0
  if (cap === 0 || list.length <= cap) return parallel(list)
  const out = []
  for (let i = 0; i < list.length; i += cap) {
    const batch = await parallel(list.slice(i, i + cap))
    for (const r of batch) out.push(r)
  }
  return out
}
