# /wrap-ticket

Close out a shipped ticket cleanly. Verifies all tasks are completed, extracts learnings from agent context files before they are lost, appends them to project memory, marks the plan complete, removes the worktree, and prints a Linear close-out checklist.

Run this after the PR is merged and released.

## Usage

```
/wrap-ticket <TICKET-ID>
/wrap-ticket
```

## Flags

| Flag / Argument | Description |
|-----------------|-------------|
| `<TICKET-ID>` | Linear ticket ID (e.g. `POC-123`). Required; prompts if omitted. |

## Examples

**Wrap a completed ticket:**
```
/wrap-ticket POC-123
```

**Expected close-out output:**
```
Wrap-up complete for POC-123

Automated:
  ✅ All 4 tasks confirmed completed
  ✅ Learnings appended to .claude/memory/claude/memory.md
  ✅ Plan marked [COMPLETED] in .claude/plans.md
  ✅ 1 backlog item added for deferred work
  ✅ Worktree removed

Manual checklist (copy to Linear comment):
  [ ] Linear ticket moved to Done / Released
  [ ] PR link attached to Linear ticket
  [ ] Release version noted: v1.4.2
  [ ] Stakeholders notified (if required)
  [ ] Runbook / internal docs updated (if this ticket changed any process)
  [ ] On-call team aware (if this ticket touched prod infrastructure)

Learnings saved:
  - responseCache.GetAllForFolder must use LIKE '%' not '=' — the latter breaks on Windows paths
  - QA found a nil pointer in the export handler when the folder has zero items — add a guard
```

**If tasks are still open:**
```
Cannot wrap — 2 tasks are not yet completed:
  id:41  [ic4]  Task 1 — CSV serializer  status:in-progress
  id:43  [qa]   Task 3 — Acceptance tests  status:pending

Complete or close these tasks before wrapping.
To force-close a task: TaskUpdate id:<N> status:completed
```

## How It Works

`/wrap-ticket` runs seven steps sequentially:

1. **Resolve worktree** — detects the ticket's worktree path via `git worktree list`. Notes it for removal in Step 6; continues even if no worktree is found.

2. **Verify tasks** — calls `TaskList` and filters to tasks containing `<TICKET-ID>`. If any task is not `completed`, presents the list and asks whether to force-close or stop. Does not proceed past this gate until all tasks are accounted for.

3. **Collect learnings** — reads each agent's `context.md` from the ticket's worktree and the plan file. Extracts 3-8 specific bullet points: unexpected technical discoveries, patterns worth repeating, gotchas that would trip up a future engineer, specs or docs that need updating, and work that was deferred.

4. **Append to project memory** — writes the learnings as a dated section to `.claude/memory/claude/memory.md` (or the SQLite `memories` table if the DB is active). Warns if the memory file exceeds 150 lines.

5. **Auto-distill check** — if `distill_enabled=true` and `distill_mode=auto`, checks whether any agent is over the `distill_threshold` raw-memory count and queues distillation. In `suggest` mode, prints a notice listing agents over threshold. In both cases, suggests running `/memory-distill` to compress.

6. **Update plans index** — finds the ticket's entry in `.claude/plans.md` and updates its status to `[COMPLETED]`. Skips silently if `plans.md` does not exist.

7. **Add deferred items to backlog** — any work explicitly deferred during the ticket (noted in agent context files) is surfaced and offered as backlog entries. Asks before creating them.

8. **Remove worktree** — asks for confirmation before running `git worktree remove`. If the worktree has uncommitted changes, git will refuse and the command reports clearly without force-removing.

9. **Print checklist** — outputs the automated summary and a manual checklist formatted for pasting into a Linear comment.

## See Also

- [`/orchestrate`](./orchestrate.md) — full lifecycle that ends with a suggestion to run this command
- [`/memory-distill`](./memory-distill.md) — compress raw agent memories after wrap
- [`/memory-config`](./memory-config.md) — configure auto-distill threshold and mode
