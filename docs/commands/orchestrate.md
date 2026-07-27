# /orchestrate

End-to-end issue orchestrator. Fetches issue context, creates a worktree, spawns PM and Tech Lead for planning, drives IC agents through implementation with review loops, runs QA validation, and ships a PR. You stay as observer and navigator — agents do all the work.

## Usage

```
/orchestrate <ISSUE-ID>
/orchestrate
```

## Flags

| Flag / Argument | Description |
|-----------------|-------------|
| `<ISSUE-ID>` | Linear ticket ID (e.g. `CDV-42`) **or** local backlog slug. Omit to be prompted. |

## Examples

**Start from a Linear ticket:**
```
/orchestrate CDV-42
```
Fetches the issue from Linear, summarizes it, and asks for scope confirmation before creating a worktree.

**Start without Linear integration:**
```
/orchestrate
```
Prompts for issue ID, then asks you to paste the title, description, and acceptance criteria directly.

**Expected output after scope confirmation:**
```
Issue: CDV-42 — Add export to CSV
Priority: Medium
Current status: Todo

My assessment:
- Complexity: moderate
- Estimated agents needed: ic4, qa
- Likely affected areas: export package, CSV serializer

Proceed with this scope? Any adjustments?
```

## How It Works

`/orchestrate` runs the full Linear-to-prod lifecycle as a managed flow:

1. **Load context** — reads AGENTS.md and agent memory (Tech Lead + PM cortex) before touching the issue.
2. **Fetch issue** — resolves source in order: Linear MCP → local `.claude/backlog/` slug/title → freeform paste. Seeds plan `closes:` (backlog paths and/or `linear:<ID>`).
3. **Scope gate** — presents issue summary, source/closes, and complexity assessment; waits for user confirmation (first escalation gate).
4. **Create worktree** — creates a `feat/<ISSUE-ID>-<slug>` branch and git worktree. All agent work happens inside the worktree.
5. **Parallel PM + Tech Lead kickoff** — PM refines and finalizes acceptance criteria; Tech Lead identifies affected files, specs, and risks. Both run simultaneously.
6. **Open-questions gate** — if PM surfaces ambiguities, they are presented to you before any design work begins.
7. **Tech Lead designs approach** — produces a spec (in `specs/core/`), an implementation plan (in `.claude/plans/`) including a **Tracking** section (`source` + `closes:`), and a task graph with per-task agent recommendations. Waits for user approval (second escalation gate).
8. **Task graph creation** — each plan step becomes a `TaskCreate` entry with dependencies noted.
9. **Execute and monitor** — unblocked tasks are dispatched to the recommended IC agents in the worktree. As tasks complete, blocked tasks are unblocked and dispatched. Escalation triggers are watched throughout (see below).
10. **Tech Lead review loop** — every completed IC task gets a Tech Lead review. `REQUEST CHANGES` routes feedback back to the IC. If the same task cycles 3+ times without consensus, you are asked to break the deadlock.
11. **Code-simplify (optional)** — after all tasks APPROVE, one behavior-preserving polish pass on recently modified files only (`skills/code-simplify`). Skip with `CODE_SIMPLIFY=0` or empty/docs-only diff. Fail-open — never blocks QA.
12. **QA validation** — after review (and simplify if run), QA runs against the spec and acceptance criteria. Failures route back to the responsible IC for a fix-and-re-review cycle.
12. **Ship** — presents a diff summary; **tracking close-out** runs on the feature worktree (`skills/backlog/close.sh` for each plan `closes:` backlog item; Linear Done when MCP available) and those files ship **in the same delivery commit** as product code. Then PR/squash options. Suggests `/wrap-ticket` for worktree/learnings.
13. **Friction check (non-blocking)** — at completion the orchestrator runs the phase-1 retro gate against the just-finished session. If the session accumulated friction signals, it prints a one-line `Consider: /retro <session-id>` hint. Never auto-runs `/retro`, never blocks completion.

### Escalation triggers

The orchestrator interrupts you when:
- An agent is stuck after 2 genuine attempts
- Scope creep is discovered (work not in the plan)
- An ambiguous requirement can't be resolved from the spec
- A breaking change is found (schema migration, API contract, dependency bump)
- IC and Tech Lead cycle 3+ review rounds without consensus

Routine issues (test failures, lint, formatting, implementation choices within spec) are handled by agents without interrupting you.

### Change discipline

- One ticket = one branch = one PR. Never bundle multiple tickets.
- Soft cap: ~1,000 LOC of real code per PR. Hard cap: 2,000 LOC total. PRs over limit must be split.
- Refactoring is always a separate PR — never mixed with feature work.
- Discovered out-of-scope work goes to a new ticket, not the current PR.
- Material changes to the approach trigger a replan gate: all IC work pauses, Tech Lead replans, you approve before resuming.

## See Also

- [`/kickoff`](./kickoff.md) — planning phase only (no worktree, no agents)
- [`/wrap-ticket`](./wrap-ticket.md) — close out after the PR is merged
- [`/brainstorm`](./brainstorm.md) — Socratic refinement before formal planning
- [`/status standup`](./status.md) — monitor in-progress task state
- [`/retro`](./retro.md) — review the just-finished session for friction patterns (suggested at completion when the gate fires)
