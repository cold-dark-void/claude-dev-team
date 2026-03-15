# /standup

Instant status snapshot of active agent team work. Reads the task system and each agent's `context.md` to surface what is in progress, what is blocked, and what is ready to claim — without interrupting agents mid-task.

## Usage

```
/standup [TICKET-ID]
```

## Flags

| Flag / Argument | Description |
|-----------------|-------------|
| _(none)_ | Show all active tasks across all tickets |
| `TICKET-ID` | Filter output to tasks for a specific ticket (e.g. `POC-123`) |

## Examples

**Global snapshot:**
```
/standup
```

**Filtered to one ticket:**
```
/standup POC-123
```
Output (abbreviated):
```
Standup — POC-123 — 14:32 UTC

─── In Progress ──────────────────────────────────────────────────────
  id:3  [ic4]   cache layer (GetAllForFolder)
        Last: "Wrote 3 tests, implementing GetAllForFolder now"
        Commits: feat: POC-123 — add CachedAnalysis struct (14 min ago)
        Status: on track

  id:4  [ic5]   export package (Exporter+impls)
        Last: "Defined Exporter interface, sent to @ic4 and @qa."
        Commits: none yet
        Status: STALE — no commits in 45 min, check context

─── Pending (ready to claim) ─────────────────────────────────────────
  id:6  [unassigned]  QA acceptance tests
        Note: "Start after IC5 defines interface" — interface defined. READY

─── Pending (blocked) ────────────────────────────────────────────────
  id:5  [unassigned]  UI wiring
        Waiting on: Task 3 (in_progress), Task 4 (in_progress)

─── Completed ────────────────────────────────────────────────────────
  id:1  [ic4]   spec review  done

─── Summary ──────────────────────────────────────────────────────────
  In progress: 2  |  Ready to claim: 1  |  Blocked: 1  |  Done: 1

─── Suggested actions ────────────────────────────────────────────────
  ic5 Task 4 looks stale — check .claude/memory/ic5/context.md
  Task 6 is ready — @qa can claim via TaskUpdate now
```

## How It Works

`/standup` reads the live task system and agent working memory in four steps.

**TaskList reading:** All tasks are loaded and grouped by status (`pending`, `in_progress`, `completed`, `blocked`). When a `TICKET-ID` argument is given, only tasks whose subject contains that ID are shown.

**Agent context files:** For every `in_progress` task, `/standup` reads the owning agent's `context.md` at `.claude/memory/<agent>/context.md`. This file is the agent's running scratchpad — it captures current step, decisions made, and blockers. If no context file exists, the output notes that the agent has not written progress yet.

**Staleness detection:** Each in-progress task is evaluated for signs of stall: no context.md update in the last 30 minutes, no commits from that agent in the last hour, or context.md text that says "blocked" or "waiting" without a corresponding escalation message. Stale tasks are flagged prominently.

**Dependency analysis:** Pending tasks are checked against their `depends_on` lists. Tasks whose dependencies are all completed are marked READY so another agent can claim them immediately.

The final report includes a suggested-actions section. If any task is stale with no escalation, or if a critical dependency is bottlenecked, `/standup` recommends a `SendMessage` to `@tech-lead` — but does not send it automatically.

## See Also

- [/orchestrate](orchestrate.md) — launch the full agent team for a ticket
- [/kickoff](kickoff.md) — create the task graph that standup reads
- [/recall](recall.md) — search history for prior work on a topic
