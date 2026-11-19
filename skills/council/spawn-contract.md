<!-- /council stage body — load via SKILL.md router; read only the current stage. -->

## Spawn Contract Line (CDT-573)

Canonical home of the Task-path spawn contract line — **one fence, one copy**.
Every fleet spawn fence cites this file by path and MUST NOT retype the
sentence. A site that retypes it breaks the grep-identical rule (SPEC-013
§ Spawn concurrency cap, AC8).

### The line

```text
Spawn contract: at most <N> spawns in flight — spawn a batch, await all returns, then the next batch. Never exceed.
```

### Rules

- **Substitution.** `<N>` is the integer in `plan.concurrency`. The plan is the
  single carrier of the resolved cap — never re-read `--concurrency`,
  `COUNCIL_CONCURRENCY`, or the Model map mid-run.
- **Placement.** Append the line once per fleet spawn fence, after the fleet
  instruction (the wave's fan-out sentence) and before the per-spawn prompt
  blocks. Grep-identical at every site.
- **Unset.** When `plan.concurrency` is absent the cap is unbounded: emit **no
  line**. The canonical spawn fence stays byte-unchanged (AC1).
- **Blindness.** A batch MUST NOT observe sibling-batch output. Queueing is not
  a spawn failure: batching never sets `verification_mode: self-verified`
  (SKILL.md § Invariants).
- **Scope.** Caps every enumerated fleet wave of ≥ 2 spawns. Named fences that
  cite this file: Phase 2 investigators, Phase 2.5 cross-reviewers, Phase 3
  specialist, Phase 4 prosecutor/advocate, Phase 5 judge parts, the `--blind`
  teams + lenses wave, `/review-and-commit` investigators, `/bug-hunt` S1/S2
  (T8), and `/debug ticket` refuters (T9). `/kickoff` Step 2 finder fan-out and
  `external-reviewer.sh` are out of the cap. Each site's enforcement tier is
  in § Scope — enforcement tier below.

## Scope — enforcement tier of every site *(CDT-594)*

Every capped site carries one of two tiers (SPEC-013 § Spawn concurrency cap →
waves[]). The contract line above is the whole cap at a prose-enforced site; a
wave-plan-enforced site adds the batch iteration below.

- **Wave-plan-enforced** — the site iterates its `plan.waves[]` batches
  (§ Wave-plan iteration): the Phase 2 investigator fence
  (`skills/council/phases-0-2.md` § Phase 2, `commands/council.md` § Phase 2),
  the Phase 2.5 cross-reviewer fence (`skills/council/phases-blind.md`
  § Phase 2.5, `commands/council.md` § Phase 2.5), and the two gated council
  sites (`skills/autopilot/ship-gate-council.md`,
  `skills/orchestrate/steps/08-execute.md`).
- **Prose-enforced** — contract line only; the site reads no `waves[]`: the
  Phase 3 classifier + specialist wave, the Phase 4 pair, the Phase 5
  judge-parts wave, the `--blind` teams + lenses wave, `/bug-hunt` S1/S2, and
  the `/debug ticket` refuter wave.
- **Out of the cap** — `/kickoff` Step 2 finder fan-out and
  `external-reviewer.sh` (a bash subprocess, not a subagent spawn).

Emission is wider than enforcement: preflight emits the `phase3`, `phase4`, and
`blind` waves (their slot sets are LLM-free) and the plan is the single source
of their batch structure, yet those six sites keep the contract line in this
ticket. An emitted wave is authoritative for a site only once that site reads
it. Follow-up record:
`.claude/backlog/wave-plan-enforcement-for-the-six-prose-enforced-s.md`.

## Wave plan `waves[]` *(CDT-594)*

The batch structure of a capped run is plan data, not a prompt sentence: the
M14 C1 run pre-fired all 28 Phase 2 spawns against a cap of 4.
`plan.waves[]` is an array of `{wave, batch, spawns[]}` objects. A slot is an
index tuple `{slot, claim_index, claim_id, flavor, agent, model_pin_source}` —
never prompt text, claim text, or artifact bytes.

- **Carrier.** Batch boundaries come from `plan.waves[]`; the cap from
  `plan.concurrency`. A wave-plan-enforced site MUST NOT count, slice, rank,
  reorder, or enumerate the fleet, and MUST NOT re-resolve the cap.
- **Unset.** No `waves` key, no `waves_pending`, no contract line: every fence
  stays byte-unchanged (AC1).

### Wave-plan iteration (one copy — every wave-plan-enforced fence cites it)

Take the objects whose `wave` equals your wave name and run them in ascending
`batch` order: spawn exactly the slots of batch *k* in one message, await every
return, then run batch *k*+1. Map each slot to a spawn from its `agent` +
`flavor`, pinned by the existing model-pin fence keyed on `model_pin_source`
(`map` → the P1 resolver fence with its Tier-alias floor, `tier-default` → the
SPEC-003 alias, `p2-literal` → the literal `sonnet`). Batches never merge
across waves and never split inside a wave. `cap = 1` is legal: every batch
then holds one slot. A batch MUST NOT observe sibling-batch output. Queueing
is not a spawn failure: batching never sets `verification_mode:
self-verified` and never emits the CDV-199 marker.

### Pending waves and the emitter

`plan.waves_pending` names the waves whose slot set needs Phase 1 output
(`phase2`, `phase2.5` for the transcript-slice, plan, and diff scopes). A fence
for a pending wave calls the emitter before it spawns and invents no batching
of its own:

```bash
"$ENGINE_SH" waves --plan-file "$PLAN_FILE" --claims-file "$CLAIMS_FILE"
```

The cap comes from `plan.concurrency` only; the claim records come from the
JSON-array file at `$CLAIMS_FILE` (a path argument, never inline text). The
emitter merges `phase2` and `phase2.5` into the plan file through tmp + rename,
drops each emitted name from `waves_pending`, prints the merged `plan.waves` on
stdout, and is idempotent: a re-run replaces the wave objects it owns. The
fence is `commands/council.md` § Phase 1.5 (wave-plan emission).

- **Zero slots.** The emitter drops only the names it emitted objects for. A
  wave that expands to no slots keeps its name in `waves_pending` with no wave
  objects behind it — a `plan.flavors` of fewer than 3 entries expands no
  `phase2.5` wave at all. A fence that finds its wave named and its wave objects
  absent has no spawns in that wave: it runs that wave's documented skip/bypass
  path. It does NOT call the emitter again and does NOT invent slots.

- **Fail closed.** Exit `64` on a missing or unreadable plan, a plan with no
  `concurrency`, a missing or unreadable claims file, a claims file that is not
  a JSON array, and an empty claims array. The plan stays byte-unchanged. Stop
  loudly at that point: print the emitter's stderr and exit. NEVER continue the
  run with an unbounded fan-out — that is the failure mode this plan closes.

### Degrade path: no batch-synchronous fan-out primitive

On a host with no batch-synchronous fan-out primitive, the CDT-573 contract
line is the degrade path (SPEC-013 § Phase 2): emit the line with the
`plan.concurrency` value, spawn the batches in the same `batch` order, one
message per batch, and warn on stderr that the host has no batch-synchronous
primitive. Batch boundaries stay the plan's; blindness holds; queueing still is
not a spawn failure, so the degrade sets no `verification_mode` and emits no
marker.

*Traceability:* SPEC-013 § Spawn concurrency cap (AC2, AC8), § waves[] (AC11,
AC13, AC14); `commands/council.md` § Step 2 plan field, § Phase 1.5 (wave-plan
emission).
