---
name: wrap-ticket
description: Clean up after a ticket ships — verifies all tasks completed, removes the
  worktree, appends learnings to project memory, marks the plan complete, and prints a
  Linear close-out checklist. Usage: /wrap-ticket <TICKET-ID>
---

# Wrap Ticket

Close out a shipped ticket cleanly. Checks the task system, captures learnings before
context is lost, removes the worktree, and leaves the project in a clean state.

Run this after the PR is merged and released.

## Arguments

- `/wrap-ticket <TICKET-ID>` — required; the Linear ticket ID (e.g. `POC-123`)
- `/wrap-ticket` — prompts for ticket ID

---

## Step 0: Resolve roots

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && PROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || PROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
```

Detect the ticket's worktree path:
```bash
git worktree list | grep -i "<TICKET-ID>"
```

Note the worktree path if found (e.g. `../project-POC-123`). If no worktree found,
continue — it may already have been removed.

---

## Step 1: Verify all tasks are completed

Call `TaskList`. Filter to tasks containing `<TICKET-ID>`.

If any task is NOT `completed`:

```
Cannot wrap — N tasks are not yet completed:
  id:<N>  [<owner>]  <title>  status:<status>

Complete or close these tasks before wrapping.
To force-close a task: TaskUpdate id:<N> status:completed
```

Ask the user: "Force-close these tasks and proceed, or stop?"

If user says stop: exit.
If user says force-close: issue `TaskUpdate status:completed` for each, then continue.

If all tasks are completed: proceed silently.

---

## Step 2: Collect learnings from agent context files

Read each agent's context.md for this ticket's worktree:

```bash
for agent in ic4 ic5 qa tech-lead pm devops; do
  cat $WTROOT/.claude/memory/$agent/context.md 2>/dev/null
done
```

Also read the plan file:
```bash
ls $WTROOT/.claude/plans/ | grep -i "<TICKET-ID>"
```

From these, extract:
- Unexpected technical discoveries (things that weren't in the plan)
- Patterns that worked well and should be repeated
- Gotchas, footguns, or surprises that would trip up a future engineer
- Any spec/doc that should be updated (if not already)
- Low-priority items that were deferred (add to backlog)

Summarize into 3–8 bullet points maximum. Be specific — not "cache is important" but
"responseCache.GetAllForFolder must use LIKE '%' not '=' — the latter breaks on Windows paths".

---

## Step 3: Append learnings to project memory

```bash
MEMDB="$PROOT/.claude/memory/memory.db"
```

Read current memory:
```bash
if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
  sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='claude' AND type='memory' ORDER BY updated_at DESC LIMIT 1;"
else
  cat "$PROOT/.claude/memory/claude/memory.md" 2>/dev/null
fi
```

Append a new section:

```markdown

## <TICKET-ID> learnings (<TODAY YYYY-MM-DD>)

- <learning 1>
- <learning 2>
...
```

Write back:
```bash
CONTENT="<full updated memory content>"
if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
  ESCAPED=$(echo "$CONTENT" | sed "s/'/''/g")
  sqlite3 "$MEMDB" "INSERT OR REPLACE INTO memories(agent, type, content, updated_at) VALUES ('claude', 'memory', '$ESCAPED', strftime('%Y-%m-%dT%H:%M:%SZ','now'));"
else
  cat > "$PROOT/.claude/memory/claude/memory.md" << 'MEMEOF'
$CONTENT
MEMEOF
fi
```

If the memory file is getting long (>150 lines), note:
`Memory file is >150 lines — consider consolidating older entries.`

---

## Step 4: Update plans index

Find the plan entry in `$PROOT/.claude/plans.md` (if it exists):
```bash
grep -i "<TICKET-ID>" $PROOT/.claude/plans.md 2>/dev/null
```

If found, update its status from `[IN PROGRESS]` or `[ACTIVE]` to `[COMPLETED]`.

If `plans.md` doesn't exist, skip silently.

---

## Step 5: Add any deferred items to backlog

If learnings from Step 2 include deferred work (things descoped, follow-up tickets,
known limitations), add them to the backlog:

For each deferred item, call `/backlog add <title>` or prompt the user:

```
Found N deferred items from <TICKET-ID>:
  1. "No loading indicator during export — large folders feel frozen"
  2. "Gio backend not covered — export only works in Fyne"

Add these to the backlog? (y/n)
```

If yes: create backlog entries for each.

---

## Step 6: Remove the worktree

If a worktree was found in Step 0:

```
About to remove worktree at <path>.
This cannot be undone. The branch feat/<TICKET-ID>-* has already been merged.
Proceed? (y/n)
```

If yes:
```bash
cd $PROOT
git worktree remove <worktree-path>
```

If the worktree has uncommitted changes, git will refuse. Report:
```
Worktree has uncommitted changes — cannot remove automatically.
Check <path> and either commit or discard before retrying.
```

If no worktree was found: skip silently.

---

## Step 7: Print close-out checklist

Print a checklist for the engineer to complete manually:

```
Wrap-up complete for <TICKET-ID>

Automated:
  ✅ All N tasks confirmed completed
  ✅ Learnings appended to .claude/memory/claude/memory.md
  ✅ Plan marked [COMPLETED] in .claude/plans.md
  ✅ N backlog items added for deferred work
  ✅ Worktree removed

Manual checklist (copy to Linear comment):
  [ ] Linear ticket moved to Done / Released
  [ ] PR link attached to Linear ticket
  [ ] Release version noted: v<X.Y.Z>
  [ ] Stakeholders notified (if required)
  [ ] Runbook / internal docs updated (if this ticket changed any process)
  [ ] On-call team aware (if this ticket touched prod infrastructure)

Learnings saved:
  <bullet 1>
  <bullet 2>
  ...

<If any deferred backlog items were added>
Backlog items added:
  • <title 1>
  • <title 2>
```

---

## Error Handling

- **No TICKET-ID provided**: ask for it — do not guess
- **Not in a git repo**: warn; skip worktree removal and git-based steps; still collect learnings
- **TaskList unavailable**: warn and skip Step 1; still do learnings, plans update, and worktree removal
- **Worktree has uncommitted changes**: report clearly, do not force-remove
- **Memory file does not exist**: create it with the learnings section as the first content
- **Plan file not found**: skip plans update silently (not all projects use plans.md)
