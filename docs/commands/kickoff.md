# /kickoff

Collapses ticket intake and planning into a single command. Fires PM, Tech Lead, and a codebase exploration agent in parallel, resolves scope questions, writes or updates the relevant spec, produces an implementation plan, and creates a ready-to-claim task graph.

## Usage

```
/kickoff <TICKET-ID> "<ticket text>"
/kickoff <TICKET-ID>
/kickoff
```

## Flags

| Flag / Argument | Description |
|-----------------|-------------|
| `<TICKET-ID>` | Linear ticket ID (e.g. `POC-123`). Omit to be prompted. |
| `"<ticket text>"` | Full ticket text inline (title, description, ACs). Omit to be prompted. |

## Examples

**Kickoff with ticket ID and text inline:**
```
/kickoff POC-123 "Add CSV export. ACs: 1. Export button visible in toolbar. 2. Output matches schema v2."
```

**Kickoff with ID only (prompts for text):**
```
/kickoff POC-123
```
Prompts: `Paste the full ticket text (title, description, acceptance criteria):`

**Expected kickoff summary output:**
```
Kickoff complete for POC-123

Spec:   specs/core/SPEC-007-csv-export.md [created]
Plan:   .claude/plans/2026-03-15-POC-123-csv-export.md
Tasks:  3 created

Task Graph:
  id:41  Task 1 — CSV serializer       → ic4   [ready to claim]
  id:42  Task 2 — Export toolbar UI    → ic4   [ready to claim]
  id:43  Task 3 — Acceptance tests     → qa    [blocked by Task 1, Task 2]

Parallel work ready:
  @ic4: claim Task 1 via TaskUpdate, start immediately
  @ic4: claim Task 2 via TaskUpdate, start immediately
  @qa:  claim Task 3 after Task 1 + Task 2 complete

Next: /standup to monitor progress
```

## How It Works

`/kickoff` replaces the manual back-and-forth of ticket intake with a structured, parallel flow:

1. **Load context** — reads AGENTS.md and memory for Claude, Tech Lead, and PM. Scans `specs/` for specs that may constrain the design.
2. **Three parallel agents** — PM (scope and ACs), Tech Lead (architecture orientation), and a codebase exploration agent (entry points, execution flows, patterns, dependencies) all run simultaneously without waiting for each other.
3. **Open questions gate** — PM's scope questions are surfaced immediately. If there are more than 4 open questions the command pauses and asks you to clarify the ticket before proceeding — a vague ticket produces a bad plan.
4. **Spec gap check** — using Tech Lead's affected-area list and PM's confirmed ACs, the command determines whether a spec exists. If not, Tech Lead writes one (saved to `specs/core/SPEC-NNN-<slug>.md`). If one exists, Tech Lead patches it for this ticket's changes only.
5. **Spec commit** — the new or updated spec is committed before any implementation planning begins (spec-first discipline).
6. **Implementation plan** — Tech Lead produces a step-by-step plan (saved to `.claude/plans/<date>-<TICKET-ID>-<slug>.md`) that identifies which steps are independent, which are blocked, and which agent (ic4 for extending patterns, ic5 for novel/complex work) is recommended for each.
7. **Task graph** — each plan step becomes a `TaskCreate` call with dependencies noted. Task IDs are written back into the plan file.
8. **Summary** — a structured output shows the full task graph and tells each agent exactly what to claim and when.
9. **Friction check (non-blocking)** — after the summary prints, kickoff runs the phase-1 retro gate against the just-finished session. If the session accumulated friction signals, a one-line `Consider: /retro <session-id>` hint is printed. Never auto-runs `/retro`, never blocks completion.

`/kickoff` covers Phase 1 (intake) and Phase 2 (planning) of the Linear-to-prod workflow. It does not create a worktree or spawn IC agents — use `/orchestrate` for the full end-to-end flow, or claim tasks manually after `/kickoff`.

## See Also

- [`/orchestrate`](./orchestrate.md) — full lifecycle including worktree, IC agents, review, and PR
- [`/brainstorm`](./brainstorm.md) — Socratic refinement to use before kickoff on complex features
- [`/standup`](./standup.md) — monitor task progress after kickoff
- [`/wrap-ticket`](./wrap-ticket.md) — close out after the PR is merged
- [`/retro`](./retro.md) — review the just-finished session for friction patterns (suggested at completion when the gate fires)
