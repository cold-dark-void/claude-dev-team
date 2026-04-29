---
name: wrap-ticket
description: |
    Clean up after a ticket ships — verifies all tasks completed, removes the
    worktree, appends learnings to project memory, marks the plan complete, and
    prints a Linear close-out checklist. Usage: /wrap-ticket <TICKET-ID>
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
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
```

Detect the ticket's worktree path — prefer the new convention, fall back to legacy:
```bash
TICKET_ID="<TICKET-ID>"
if [ -d "$MROOT/.worktrees/$TICKET_ID" ]; then
  # New convention: $MROOT/.worktrees/<TICKET-ID>
  WORKTREE_PATH="$MROOT/.worktrees/$TICKET_ID"
else
  # Legacy: sibling directory
  WORKTREE_PATH=$(git worktree list --porcelain \
    | grep -A1 "^worktree " \
    | grep "^worktree " \
    | sed 's/^worktree //' \
    | grep -wF "$TICKET_ID" | head -1)
fi
```

`$WORKTREE_PATH` is used in all downstream steps. If empty, no worktree was found —
continue; it may already have been removed.

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
ls $WTROOT/.claude/plans/ | grep -wF "$TICKET_ID"
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
MEMDB="$MROOT/.claude/memory/memory.db"
```

Read current memory:
```bash
if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
  HAS_DISTILLED=$(sqlite3 "$MEMDB" "SELECT COUNT(*) FROM memories WHERE agent='claude' AND tier > 0 AND archived=FALSE;")
  if [ "$HAS_DISTILLED" -gt 0 ]; then
    sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='claude' AND tier=2 AND archived=FALSE ORDER BY type, updated_at DESC;"
    sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='claude' AND tier=1 AND archived=FALSE ORDER BY type, updated_at DESC;"
  else
    sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='claude' AND tier=0 AND archived=FALSE ORDER BY type, created_at DESC;"
  fi
else
  cat "$MROOT/.claude/memory/claude/memory.md" 2>/dev/null
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
  cat > "$MROOT/.claude/memory/claude/memory.md" << MEMEOF
$CONTENT
MEMEOF
fi
```

If the memory file is getting long (>150 lines), note:
`Memory file is >150 lines — consider consolidating older entries.`

---

## Step 3.5: Auto-distill check

After writing learnings to memory, check if distillation should run:

```bash
if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
  DISTILL_ENABLED=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='distill_enabled';")
  DISTILL_MODE=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='distill_mode';")

  if [ "$DISTILL_ENABLED" = "true" ] && [ "$DISTILL_MODE" = "auto" ]; then
    THRESHOLD=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='distill_threshold';")
    AGENTS_OVER=$(sqlite3 "$MEMDB" "SELECT agent FROM memories
      WHERE tier=0 AND archived=FALSE
      GROUP BY agent HAVING COUNT(*) >= $THRESHOLD;")
    if [ -n "$AGENTS_OVER" ]; then
      echo "[wrap-ticket] Auto-distilling agents over threshold..."
      for AGENT in $AGENTS_OVER; do
        echo "  Queuing distillation for @$AGENT"
      done
      echo "Run /memory-distill to execute distillation."
    fi
  elif [ "$DISTILL_ENABLED" = "true" ] && [ "$DISTILL_MODE" = "suggest" ]; then
    THRESHOLD=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='distill_threshold';")
    AGENTS_OVER=$(sqlite3 "$MEMDB" "SELECT agent || ' (' || COUNT(*) || ' raw)' FROM memories
      WHERE tier=0 AND archived=FALSE
      GROUP BY agent HAVING COUNT(*) >= $THRESHOLD;")
    if [ -n "$AGENTS_OVER" ]; then
      echo "[wrap-ticket] Agents over distill threshold:"
      echo "$AGENTS_OVER"
      echo "Run /memory-distill to compress."
    fi
  fi
fi
```

---

## Step 4: Update plans index

Find the plan entry in `$MROOT/.claude/plans.md` (if it exists):
```bash
grep -wF "$TICKET_ID" $MROOT/.claude/plans.md 2>/dev/null
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
cd $MROOT
if [ -d "$MROOT/.worktrees/$TICKET_ID" ]; then
  # New convention — delegate to worktree-lib.sh for lock cleanup + removal
  bash "$MROOT/skills/worktree-lib.sh" release "$TICKET_ID"
else
  # Legacy sibling path — remove directly and delete the tracking branch
  git worktree remove "$WORKTREE_PATH"
  git branch -D "feat/$TICKET_ID" 2>/dev/null || true
fi
```

If the worktree has uncommitted changes, `worktree-lib.sh release` (or `git worktree
remove`) will refuse. Report:
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
