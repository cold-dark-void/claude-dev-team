---
name: standup
description: Status snapshot for active agent team work — reads TaskList and each agent's
  context.md, produces a table of who is doing what, what's blocked, and what's ready to
  claim. Use during Phase 3 implementation to monitor parallel agent progress.
  Usage: /standup [TICKET-ID]
---

# Standup

Get an instant status snapshot of active agent team work. Reads the task system and each
agent's working memory to surface blockers, stale work, and next actions — without
interrupting agents mid-task.

## Arguments

- `/standup` — show all active tasks across all tickets
- `/standup <TICKET-ID>` — filter to tasks for a specific ticket (e.g. `POC-123`)

---

## Step 0: Resolve project root

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
```

---

## Step 1: Read TaskList

Call `TaskList` to get all tasks.

If a TICKET-ID was provided, filter to tasks whose subject contains that ID.
If no tasks are found: print `No active tasks found.` and stop.

Group tasks by status:
- `pending` — not yet claimed
- `in_progress` — claimed, actively being worked
- `completed` — done
- `blocked` — explicitly marked blocked

---

## Step 2: Read agent context files

For each task with status `in_progress`, read the owning agent's context file:

```bash
cat $WTROOT/.claude/memory/<owner>/context.md 2>/dev/null
```

If no context file exists for an agent, note: `(no context.md — agent hasn't written progress yet)`.

Also check for recent commits by the agent:
```bash
git log --oneline --since="2 hours ago" --author="<agent-name>" 2>/dev/null | head -5
```

(Agent name may appear in commit Co-Authored-By lines — grep for it if needed.)

---

## Step 3: Assess staleness

For each `in_progress` task, determine if it looks stale:

**Stale indicators** (any one → flag as STALE):
- context.md was not updated in the last 30 minutes (check file mtime if possible)
- No commits from this agent in the last hour
- context.md says "blocked" or "waiting" without a corresponding SendMessage to Tech Lead
- Task has been `in_progress` since before the last completed task finished

Flag stale tasks with `⚠️ STALE` in the output.

---

## Step 4: Identify ready-to-claim tasks

For each `pending` task, check its `depends_on` list (from task description):
- If all dependencies are `completed` → mark as **READY**
- If any dependency is still `in_progress` or `pending` → mark as **WAITING ON <task IDs>**

---

## Step 5: Print standup report

```
Standup — <TICKET-ID or "all tickets"> — <current time>

─── In Progress ──────────────────────────────────────────────────────
  id:<N>  [ic4]   Task 1 — cache layer (GetAllForFolder)
          Last: "Wrote 3 tests, implementing GetAllForFolder now"
          Commits: feat: POC-123 — add CachedAnalysis struct (14 min ago)
          Status: ✅ on track

  id:<N>  [ic5]   Task 2 — export package (Exporter+impls)
          Last: "Defined Exporter interface, sent to @ic4 and @qa. Writing CSV next."
          Commits: none yet
          Status: ⚠️ STALE — no commits in 45 min, check context

─── Pending (ready to claim) ─────────────────────────────────────────
  id:<N>  [unassigned]  Task 4 — QA acceptance tests
          Note: "Start after IC5 defines interface" — interface defined ✅ READY

─── Pending (blocked) ────────────────────────────────────────────────
  id:<N>  [unassigned]  Task 3 — UI wiring
          Waiting on: Task 1 (in_progress), Task 2 (in_progress)

─── Completed ────────────────────────────────────────────────────────
  id:<N>  [ic4]   Task 0 — spec review    ✓

─── Summary ──────────────────────────────────────────────────────────
  In progress: 2   |   Ready to claim: 1   |   Blocked: 1   |   Done: 1

─── Suggested actions ────────────────────────────────────────────────
  ⚠️  ic5 Task 2 looks stale — check .claude/memory/ic5/context.md or SendMessage to @ic5
  ✅  Task 4 is ready — @qa can claim via TaskUpdate now
  ⏳  Task 3 unblocks when Tasks 1+2 complete — Tech Lead should monitor
```

Omit any section that has no tasks.

---

## Step 6: Escalation check

After the report, check if any escalation is warranted:

**Auto-escalate to Tech Lead if:**
- Any task is STALE with no recent SendMessage to Tech Lead
- Two or more tasks are blocked waiting on the same dependency
- A completed task's output hasn't been consumed by the downstream task after 30+ min

If escalation is needed, add at the bottom:

```
─── Escalation needed ────────────────────────────────────────────────
  Recommend: SendMessage to @tech-lead — ic5 Task 2 stale, may need unblocking
```

Do NOT send the message automatically — surface it for the engineer to decide.

---

## Error Handling

- **No tasks at all**: `No tasks found. Run /kickoff <TICKET-ID> to create a task graph.`
- **TaskList unavailable** (orchestration not initialized): `Agent Teams not initialized. Run /init-orchestration first.`
- **context.md missing for in_progress agent**: note it but don't fail — the agent may not have written it yet
- **Git log unavailable** (not in a git repo): skip commit staleness check, rely on context.md mtime only
