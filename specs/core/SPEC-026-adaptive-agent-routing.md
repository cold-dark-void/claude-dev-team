# SPEC-026: Review-Outcome Ledger & Adaptive Agent Routing

**Status**: ACTIVE
**Category**: core
**Created**: 2026-07-03
**Promoted**: 2026-07-14 (CDV-185)

---

## Overview

Task assignment in `/orchestrate` follows static rules (ic4 vs ic5 by task class, SPEC-009) that never learn. The team already generates the signals needed to learn — Tech-Lead review cycles per task, QA bounces, council verdict overturns — but they evaporate with the session. This spec creates a **new data source**: an append-only outcome ledger at `.claude/metrics/outcomes.jsonl` recording, per orchestrated task, the assigned agent, task class/size, review cycles, QA bounce count, and council-gate overturns, emitted when a **(task, agent) stint ends** — at existing orchestrate review/QA terminals, with no new hook events.

On top of the ledger sits an **advisory** routing policy: at orchestrate task-assignment time (Step 7 tagging), consult per-(agent, task-class) outcome rates and print a recommendation WITH rationale (e.g. "ic4 escalated 3/4 refactor-class tasks, mean 2.8 TL cycles over 6 samples — consider ic5"). Cold start (no or thin data) falls back to the current static rules with zero advisory noise. Recommendations are advisory-with-override — the static rules remain the decision-maker unless the user **explicitly accepts**; unattended runs keep the static tag. There is **never** a silent reroute.

**Path-cherry-pick note:** this file is the sole SPEC-026 artifact landed from ideation-wave-2. No other ideation-branch content is merged.

**Boundaries & related specs:**
- **SPEC-009 (ticket workflow)** hosts the assignment step and owns the tagging rules (`Recommended agent:` line), the stuck-after-2 escalation rule, the 3+-round deadloop counter, and the Step-9/Step-10 review/QA loops. This spec MUST NOT rewrite any of those loops or rules — it *instruments stint terminals* (reusing Step 9's review-round counter) and adds a read-only advisory immediately before the `Recommended agent:` line is printed.
- **SPEC-019 (local-agent offload, DEPRECATED)** was the **format exemplar** for this ledger — its `.claude/local-agent/metrics.jsonl` established the JSONL, append-only, `jq`-guarded, `null`-not-`"unknown"` conventions this spec still follows. Local-agent offload was excised at v1.0.0, so its escalation events are no longer a live ledger source; the `local` agent enum value is retained but has no producer. `outcomes.jsonl` carries routing-outcome data only.
- **SPEC-013 (council)** owns the tribunal pipeline, the `TaskCompleted` quality gate, and the verdict index at `.claude/council/index.json`. Council overturn counts are derived **from the index only**; this spec MUST NOT write to the index, scan report `.md` files, or reimplement any verification pipeline.
- **SPEC-003 (agent roles)** owns capability boundaries. Those stay **authoritative**: the ledger tunes routing WITHIN them and never proposes a routing that crosses one.
- **CDV-187 metrics rollup** is display-only over existing sources (user entry: `/status metrics` after CDT-46-C4; former `/metrics` is a Deprecation stub). THIS spec owns write path + schema only — MUST NOT implement dashboards or rollup tables.

**Out of scope:** automatic/silent rerouting, changing SPEC-003 model tiers or role boundaries, `/metrics` display (CDV-187), statistical modeling beyond simple per-cell rates, per-token cost accounting (SPEC-019), cross-project ledgers, automatic kill-switches, windowing/decay, whole ideation-wave merge.

---

## Locked decisions (CDV-185 OQs)

| ID | Decision |
|----|----------|
| OQ1 | MVP emits `outcome ∈ {accepted, escalated}` only. Schema retains `rejected` for forward-compat; **unused** this version (no producer). Advisory failure rate = `escalated / n` (rejected contributes 0 until used). |
| OQ2 | `council_overturns` = count of `.claude/council/index.json` rows for `task_id` where `max_verdict_confidence` is JSON `null` **or** `< council.taskgate.min_confidence` (default **80**, same source as TaskCompleted gate / SPEC-002). Index is read-only. |
| OQ3 | Print advisory when thresholds met. `Recommended agent:` changes **only** on explicit user accept of a printed advisory. Unattended / no response → keep static rule. |
| OQ4 | Emit when a **(task, agent) stint ends**, with QA counters final — **not** mid-path at Step-9 APPROVE before Step-10. Accepted stint: after Step-10 completes for that task (QA PASS, or QA skipped/N/A with `qa_bounces` finalized). Escalated stint: at hand-off (original agent). |
| OQ5 | Thresholds hardcoded: escalated rate ≥ **50%**, OR mean `review_cycles` ≥ **2.0**. `MIN_SAMPLES` default **5**, override env `OUTCOME_MIN_SAMPLES`. |
| OQ6 | Aggregation is **all-time** per (agent, task_class) cell. No windowing/decay this version. |

---

## MUST

- **M1 — Append-only outcome ledger.** One JSONL record per (task, executor) stint terminal path appended to `$MROOT/.claude/metrics/outcomes.jsonl` — `$MROOT`-anchored so all worktrees of a project share one ledger (same anchoring as `task-store` and `memory.db`). Records are never mutated, rewritten, or deleted. Format exemplar: SPEC-019's (DEPRECATED) `.claude/local-agent/metrics.jsonl` conventions — one record per line; emit guarded by `command -v jq`, skipped best-effort when absent; stdout discipline — diagnostics to stderr only.

- **M2 — Record schema.** Fixed keys `{ ts, ticket, task_id, agent, task_class, size, outcome, review_cycles, qa_bounces, council_overturns }`:
  - `ts` — epoch seconds
  - `ticket` — issue id (JSON `null` when no issue id is available)
  - `task_id` — compound `<ISSUE-ID>-N` key (`null` when no ticket)
  - `agent` ∈ `ic4 | ic5 | qa | devops | ds | local` — `local` reserved (no live producer since local-agent offload was excised at v1.0.0)
  - `task_class` — per M3 (or `null`)
  - `size` ∈ `S | M | L` (from the plan when present, else `null`)
  - `outcome` ∈ `accepted | rejected | escalated` — **MVP producers emit only `accepted` | `escalated`** (OQ1); `rejected` reserved, never written this version
  - `review_cycles` — Step-9 Tech-Lead review rounds for this stint until terminal
  - `qa_bounces` — Step-10 QA FAIL routings attributed to the task during this stint (finalized before emit — OQ4)
  - `council_overturns` — per OQ2 (read-only index derivation)
  - Unknown values are JSON `null`, never the string `"unknown"` (SPEC-019 precedent)
  - An escalation produces TWO records over a task's life: `{agent: <original>, outcome: "escalated"}` at hand-off, then a terminal record for the executor that finishes (`accepted` or further `escalated`)

- **M3 — Task-class prose line.** The Tech Lead records the class at Step 7 as a `Task-class: <enum>` prose line in the TaskCreate description — mirroring the existing `Recommended agent:` and `Machine-check:` lines (SPEC-019 ADR AMB-1 precedent), NOT a `task-store.sh` schema field. Taxonomy is fixed for this version: `impl-extend | impl-novel | refactor | test | docs | infra | discovery`. A missing line ⇒ `task_class: null`; null-class records are still emitted but excluded from advisory aggregation.

- **M4 — Emission at existing stint terminals only (OQ4).** Ledger writes are instrumented at checkpoints that already exist — no new hook events:
  - **(a) Accepted stint** — after Step-10 has finalized `qa_bounces` for the task (QA PASS, or explicit QA N/A with counter frozen). Step-9 APPROVE alone MUST NOT emit.
  - **(b) Escalated stint** — at hand-off when SPEC-009 stuck-after-2 or 3+-round deadloop ends the current agent's stint; emit `{outcome: "escalated"}` with counters as of hand-off.
  - **(c)** each Step-10 QA FAIL routed back to the responsible IC increments that task's in-session `qa_bounces` (counter only — no ledger write until stint end).
  - **(d)** `council_overturns` are READ from `.claude/council/index.json` at emit time (OQ2; never written here).
  - All writes go through one helper (`skills/metrics/emit-outcome.sh`, `jq`-guarded, following the JSONL append-only pattern).

- **M5 — Advisory at assignment time, with rationale.** At Step-7 tagging, before printing the `Recommended agent:` line, consult per-(agent, task_class) aggregates via a read helper (`skills/metrics/outcome-rates.sh`). When the recommended agent's cell has ≥ `MIN_SAMPLES` records (default **5**, override `OUTCOME_MIN_SAMPLES`) AND crosses an advisory threshold (**escalated rate ≥ 50%**, OR mean `review_cycles` ≥ **2.0** — OQ5, hardcoded), print a recommendation carrying the actual observed numbers and sample count, e.g.: `Advisory: ic4 escalated 3/4 refactor-class tasks (mean 2.8 TL cycles, 6 samples) — consider ic5. Static rule keeps ic4 unless you accept.` Aggregation is all-time (OQ6).

- **M6 — Advisory-with-override, never a silent reroute (OQ3).** The SPEC-009 static tagging rules remain the decision-maker. An advisory changes nothing by itself: the `Recommended agent:` line changes ONLY on **explicit user acceptance** of a printed advisory. Unattended / no user response → static rule. No code path may alter routing based on ledger data without the printed advisory plus acceptance.

- **M7 — Cold start = silence.** Below `MIN_SAMPLES` for the relevant (agent, task_class) cell — including a missing, empty, or unparseable ledger, and any `task_class: null` task — no advisory text of any kind is printed and assignment proceeds per the current static rules. No "insufficient data" noise.

- **M8 — Capability boundaries stay authoritative.** Advisories may only propose alternatives legal under SPEC-003 role boundaries — in practice **ic4 ⇄ ic5**. MUST NOT advise a boundary-crossing routing (e.g. implementation to tech-lead/pm, ambiguous/novel work to ic4). The ledger tunes routing WITHIN boundaries; it never widens them.

- **M9 — Failure isolation (never block orchestration).** Emit and read paths are best-effort: `jq` absent ⇒ skip the append with a one-line stderr notice (SPEC-019 precedent); unwritable ledger ⇒ same; malformed JSONL lines ⇒ skipped by the reader; any advisory-computation failure ⇒ silent fallback to static rules. A ledger problem MUST never fail, block, or degrade a task assignment or review loop.

- **M10 — MUST NOT (hard boundaries).** MUST NOT silently reroute (hard restatement of M6); MUST NOT write to `memory.db` or `.claude/council/index.json` (owned by SPEC-004 and SPEC-013 respectively); MUST NOT store review feedback prose, diff content, or any free text in records — enums, counts, ids, and timestamps only; MUST NOT carry token/cost fields; MUST NOT implement rollup/dashboard display — rendering `outcomes.jsonl` is CDV-187 / banked `/metrics` duty; this spec owns only the write path and schema.

---

## SHOULD

- SHOULD record advisory events themselves (printed / accepted / declined) as a distinct `{ "type": "advisory", ... }` ledger record so the advisor's own hit-rate can be tuned later without new instrumentation.
- SHOULD surface a one-line per-agent outcome aggregate in `/standup` output. Deferred if it risks LOC/scope creep on CDV-185.
- SHOULD keep the task-class taxonomy stable: adding a class is a spec revision via `/spec update`, never an ad-hoc string in a TaskCreate description.
- SHOULD keep the Step-7 advisory block and the stint-end emit blocks as small, dedicated sub-blocks in `skills/orchestrate/SKILL.md` (SPEC-019's scoped sub-block precedent), protecting the central-file LOC budget.

---

## Test

1. **Ledger append (M1, M2):** drive emit helper with a full accepted record → exactly one line in `$MROOT/.claude/metrics/outcomes.jsonl` with all M2 keys and valid enums; a second emit appends a new line while prior lines remain byte-identical (append-only).
2. **Counter fidelity (M2, M4, OQ2):** emit with `review_cycles: 2`, `qa_bounces: 1`, and a seeded index yielding `council_overturns: 1`; index content is unchanged by the emit helper (read-only source).
3. **Escalation pair (M2, M4):** force an ic4 stuck-after-2 escalation to ic5 → two records: `{agent:"ic4", outcome:"escalated"}` then `{agent:"ic5", outcome:"accepted"}`, same `task_id`.
4. **Stint-end timing (OQ4):** Step-9 APPROVE alone produces **no** ledger line; emit occurs only after QA counters are finalized (accepted path) or at escalation hand-off.
5. **Advisory fires with rationale (M5, OQ5):** seed a ledger where ic4 shows ≥5 samples and escalated rate ≥50% on `refactor` → Step-7 assignment of a refactor-class task prints an advisory containing the rate, the sample count, and the suggested alternative (ic5).
6. **Cold-start silence (M7):** with 3 seeded records (< MIN_SAMPLES), or the ledger deleted, the same assignment prints no advisory text and the `Recommended agent:` line matches the static rule exactly.
7. **Override only (M6, OQ3):** decline or ignore a printed advisory → task routes per static rule; accept it → only then does the `Recommended agent:` line change; no path changes routing without advisory + acceptance.
8. **Boundary guard (M8):** seed data "showing" tech-lead outperforming on impl tasks and ic4 "outperforming" on `impl-novel` → no advisory proposing either routing is ever printed.
9. **Null class (M3):** a TaskCreate description missing the `Task-class:` line yields a record with `task_class: null` that never contributes to any advisory cell.
10. **Fail-open (M9):** remove `jq` / make the ledger unwritable / inject a corrupt JSONL line → orchestration and assignment complete normally with a one-line stderr notice; the reader skips the corrupt line; the advisory falls back silently to static rules.
11. **Hard boundaries (M10):** after a full instrumented run, the ledger contains no free-text feedback and no token/cost keys; the metrics helpers wrote nothing to `memory.db` or the council index.
12. **MVP outcomes (OQ1):** no producer path writes `outcome: "rejected"`.
13. **All-time cells (OQ6):** seeded records of any age all contribute to the cell (no window filter).

---

## Validation

- [x] Spec reviewed and promoted to ACTIVE (CDV-185)
- [ ] Helpers + orchestrate instrumentation land with bite-tests green
- [ ] One real orchestration run emits well-formed records from stint terminals (accepted after QA, escalated; council_overturns derived from index)
- [ ] Advisory observed with numeric rationale on a seeded ledger; cold-start silence verified on a thin ledger
- [ ] No silent-reroute path exists — printed advisory + explicit acceptance is the only route changer
- [ ] Display duties remain with CDV-187 (no rendering added here)

---

## Open Questions (resolved / deferred)

| Item | Status |
|------|--------|
| Advisory threshold defaults | **Locked OQ5** — revisit only via `/spec update` after real ledger data |
| Windowing/decay | **Deferred OQ6** — backlog until ~1k records |
| qa/devops/ds advisories | **Deferred** — this version: ic4 ⇄ ic5 only |
| `/metrics` rollup of `outcomes.jsonl` | **Out of scope** — CDV-187 |
| `rejected` outcome producers | **Deferred OQ1** — schema reserved |

---

## Version History

| Date | Change |
|------|--------|
| 2026-07-03 | Initial DRAFT — ideation wave 2 |
| 2026-07-14 | CDV-185: path-cherry-pick; OQ1–OQ6 locks; stint-end emit timing; council_overturns = index conf null or &lt; taskgate; status DRAFT→ACTIVE |
| 2026-07-21 | CDT-46-C2: ledger-source list narrowed — `/local-do` + local-agent escalation producers removed (SPEC-019 deprecated + local-agent surfaces excised at v1.0.0). Dropped `commands/local-do.md` from Covers and the local source test; `local` agent enum retained without a producer; SPEC-019 references retagged as historical format-exemplar. M8 advisory scope now ic4 ⇄ ic5 only. Status stays ACTIVE. |
| 2026-07-22 | CDT-46-C4: display entry for rollup noted as `/status metrics` (former `/metrics` Deprecation stub). Write-path ownership unchanged. |

**Covers**: `skills/metrics/emit-outcome.sh`, `skills/metrics/outcome-rates.sh`, `skills/metrics/test.sh` (or equivalent bite harness), `skills/orchestrate/SKILL.md` (Step-7 advisory sub-block + stint-end emission sub-blocks), `specs/TDD.md` (index row) — planned/landing with CDV-185. Standup surface is SHOULD (optional).

## Cross-references

- **SPEC-003** — Agent Role System: capability boundaries authoritative; ledger tunes routing within them (M8).
- **SPEC-009** — Ticket Workflow: hosts Step-7 assignment/tagging, Step-9 review loop, stuck-after-2 and deadloop rules; this spec instruments stint terminals only (M4) and adds the pre-tag advisory (M5).
- **SPEC-013** — Adversarial Council Tribunal: `.claude/council/index.json` is the read-only source for `council_overturns` (OQ2); index ownership and atomic-write contract stay there.
- **SPEC-019** — Local-Agent Offload via OpenCode (DEPRECATED): its `.claude/local-agent/metrics.jsonl` was the format exemplar for this ledger. Offload excised at v1.0.0 — no longer a live ledger source; the `local` agent enum value is retained without a producer.
- **SPEC-016** — Worktree Isolation: the ledger is `$MROOT`-anchored and shared across worktrees (M1).
- **SPEC-002** — Plugin Infrastructure: TaskCompleted gate + `council.taskgate.min_confidence` define the overturn threshold used in OQ2.
- **CDV-187** — `/metrics` rollup (display-only over `outcomes.jsonl` and other sources).
