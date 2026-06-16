---
name: standup
description: |
    Status snapshot for active agent team work — reads TaskList and each agent's
    context.md, produces a table of who is doing what, what's blocked, and what's
    ready to claim. Use during Phase 3 implementation to monitor parallel agent
    progress. Usage: /standup [TICKET-ID]
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
# Locate the dev-team plugin root (PDH). Dev checkout first, else installed cache (highest version). Slug-free, sort -V.
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
```

`dag-lib.sh` ships in the plugin, not the user's repo, so it is resolved through
`bash "$PDH/skills/plugin-dir.sh" file skills/orchestrate/dag-lib.sh`. Each SKILL
bash block runs as a fresh shell, so Step 4 re-emits this stanza.

---

## Step 1: Read task state

Read both views of task state and reconcile them:

1. Call `TaskList` for the in-session view.
2. Read `.claude/tasks/*.json` for the file-store view (the source of
   truth that survives compaction):
   ```bash
   for f in "$MROOT"/.claude/tasks/*.json; do
     [ -f "$f" ] || continue
     jq -r '[.task_id, .status, .subject // ""] | @tsv' "$f"
   done
   ```

If a TICKET-ID was provided, filter to tasks whose subject contains that ID.
If no tasks are found in either view: print `No active tasks found.` and stop.

Group tasks by status:
- `pending` — not yet claimed
- `in_progress` — claimed, actively being worked
- `completed` — done
- `blocked` — explicitly marked blocked

When TaskList and the file store disagree on a task's status, prefer
the file store (TaskList can stale out across `/clear` and across
async-spawned agents whose completion never closed the parent's
TaskList row).

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

**Probably-completed-but-unmarked detection.** Async-spawned agents
finish in their own sandbox session, so their `TaskUpdate(completed)`
never reaches the orchestrator. Their TaskList row stays
`in_progress` indefinitely while the work is actually done. Flag a
task as `🟡 LIKELY-DONE` (separate from STALE) when ALL of:

- Status is `in_progress` AND
- Owner has no live agent process (no recent context.md write, no
  recent commits) AND
- The agent's expected output marker exists — either
  `.claude/tasks/<id>.json` shows `status: completed` in the file
  store but TaskList disagrees, OR the agent has commits referencing
  the ticket within the last 2 hours but no activity since.

Surface these in a dedicated section — they need an orchestrator
`TaskUpdate(<id>, completed)` to close the loop and unblock dependent
tasks.

---

## Step 4: Identify ready-to-claim tasks

For each `pending` task, compute readiness from the task store:

```bash
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
DAG_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/orchestrate/dag-lib.sh)
READY_TASKS=$(bash "$DAG_LIB" ready-set)
```

- A task is **READY** when its `task_id` appears in the output of `dag-lib.sh ready-set`.
- A task is **WAITING** when it is `pending` but NOT in the ready-set.

For each WAITING task, show the dependency chain by reading its task file:

```bash
TASK_FILE="$MROOT/.claude/tasks/<task_id>.json"
DEP_IDS=$(jq -r '.depends_on // [] | .[]' "$TASK_FILE" 2>/dev/null)
```

For each `dep_id` in `depends_on` (reuse `$DAG_LIB`, or re-resolve if running
this block fresh):
```bash
STATUS=$(bash "$DAG_LIB" status-of "$dep_id")
```
- Show: `WAITING on: <dep_id> (<STATUS>)`
- If the dep's task file is missing: show `WAITING on: <dep_id> (file missing)`

Use `jq '.depends_on // []'` as the default to ensure backward compatibility with task files that predate the `depends_on` field.

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
  🟡 Task 5 likely-done — orchestrator should TaskUpdate id:5 → completed
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
