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
  `external-reviewer.sh` are out of the cap.

*Traceability:* SPEC-013 § Spawn concurrency cap (AC2, AC8);
`commands/council.md` § Step 2 plan field.
