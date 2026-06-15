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
    | grep "^worktree " \
    | sed 's/^worktree //' \
    | grep -wF "$TICKET_ID" | head -1)
fi
```

`$WORKTREE_PATH` is used in all downstream steps. If empty, no worktree was found —
continue; it may already have been removed.

---

## Step 1: Verify all tasks are completed

Verification dual-reads the **file store as authoritative** — the in-session
`TaskList` is empty after `/clear`, so a TaskList-only check would vacuously
pass and let Step 6 destroy a worktree whose work is still incomplete. The file
store (`$MROOT/.claude/tasks/<ISSUE-ID>-<task_id>.json`, written by
`skills/orchestrate/task-store.sh`) survives `/clear`; it is the source of truth.

This block is self-contained (each SKILL bash block runs as a fresh shell):
re-resolve `MROOT` and set `TICKET_ID` at the top so it does not depend on Step 0.
Select the ticket's tasks by **compound-key FILENAME** (`<TICKET-ID>-*.json`), NOT
by subject — subjects are free-text (`t1`, `(auto-created stub)`), so a subject
filter misses real files. The `-` separator anchors the match so `FOO-1` does NOT
match `FOO-10-1.json`. Enumerate with `find` (never a bare glob: under zsh an
empty glob is a fatal `no matches found` that aborts the whole block; do NOT use
`shopt -s nullglob` — bash-only).

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
TICKET_ID="<TICKET-ID>"

INCOMPLETE=""
FOUND=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  FOUND=$((FOUND + 1))
  IFS=$'\t' read -r TID STATUS SUBJECT < <(jq -r '[.task_id, .status, .subject // ""] | @tsv' "$f")
  # Anything != completed (pending|in_progress|blocked) is incomplete.
  if [ "$STATUS" != "completed" ]; then
    INCOMPLETE="${INCOMPLETE}  ${TID}  status:${STATUS}  ${SUBJECT}"$'\n'
  fi
done < <(find "$MROOT/.claude/tasks" -maxdepth 1 -name "${TICKET_ID}-*.json" 2>/dev/null)
N=$(printf '%s' "$INCOMPLETE" | grep -c .)
```

Also call `TaskList` for the in-session view and reconcile — but the file store
wins: an empty/stale `TaskList` does **not** override an incomplete file-store
record (this is the fix). Then branch:

**If any file-store task is incomplete (`$N` > 0):** refuse.

```
Cannot wrap — N tasks are not yet completed:
  <task_id>  status:<status>  <subject>

Complete or close these tasks before wrapping.
To force-close a task: TaskUpdate <task_id> status:completed
```

(The displayed columns — `<task_id>  status:<status>  <subject>` — match the
captured `@tsv` order exactly. The task store has no owner field, so there is no
`[owner]` column.)

Ask the user: "Force-close these tasks and proceed, or stop?"

If user says stop: exit.
If user says force-close: issue `TaskUpdate status:completed` for each (and run
`skills/orchestrate/task-store.sh update-status <task_id> completed` so the file
store agrees), then continue.

**If `find` found NO matching files AND TaskList has none (`$FOUND` == 0):** do
not silently pass — print and continue to the Step 6 uncommitted-changes backstop:

```
Completion could not be verified — no task records found for <TICKET-ID>.
```

**If all file-store tasks are completed:** proceed silently.

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

Write back — **append-only** (matches `skills/agent-memory/protocol.md` / `skills/memory-store`
Step 2). wrap-ticket appends ONE consolidated learnings doc per wrap; the table has no unique
key, so `INSERT OR REPLACE` would just append a duplicate every time. Append-only is correct —
distillation (`/memory-distill`) compresses older rows later.
```bash
CONTENT="<the new learnings section only (## <TICKET-ID> learnings …) — NOT the full re-read>"
if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
  ESCAPED=$(printf '%s' "$CONTENT" | sed "s/'/''/g")
  MEMORY_ID=$(sqlite3 "$MEMDB" "PRAGMA busy_timeout=5000;
    INSERT INTO memories(agent, type, content) VALUES ('claude', 'memory', '$ESCAPED');
    SELECT last_insert_rowid();")
  # Best-effort embedding — silently skips when extensions absent (SPEC-004:36). embed-one.sh
  # is a sibling of skills/memory-store/; resolve it (dev checkout first, else installed cache).
  EMB=$( [ -f skills/memory-store/embed-one.sh ] && echo skills/memory-store/embed-one.sh \
    || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/memory-store/embed-one.sh' 2>/dev/null | sort -V | tail -1 )
  [ -n "$EMB" ] && [ -n "$MEMORY_ID" ] && bash "$EMB" "$MEMDB" "$MEMORY_ID" "$CONTENT" 2>/dev/null || true
else
  # Fallback: append to .md (NEVER truncate — append-only contract, SPEC-004)
  cat >> "$MROOT/.claude/memory/claude/memory.md" << MEMEOF
$CONTENT
MEMEOF
fi
```

If the memory file exceeds its SPEC-004 line limit (memory: 50 lines), note:
`Memory file exceeds its SPEC-004 limit — run /memory-distill to compress older entries.`

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

## Step 6.5: CI-watch cleanup

Check for an active CI-watch sidecar for this ticket:

```bash
SIDECAR_PATH=$(bash "$MROOT/skills/ci-watch/sidecar.sh" path "$TICKET_ID" 2>/dev/null)
```

If `$SIDECAR_PATH` is non-empty and the file exists:

1. Read the cron job ID:
   ```bash
   CRON_ID=$(jq -r '.cron_job_id // empty' "$SIDECAR_PATH")
   ```

2. If `CRON_ID` is non-empty:
   - Call **CronDelete** with `id: <CRON_ID>` — this is a Claude tool call, NOT a bash command.
   - On success, print: `CI watch cron <CRON_ID> deleted.`
   - If CronDelete fails: warn `CI watch cron deletion failed — may need manual cleanup` but do NOT halt wrap-ticket.

3. Clean up the sidecar file:
   ```bash
   bash "$MROOT/skills/ci-watch/sidecar.sh" delete "$TICKET_ID"
   ```
   Print: `CI watch sidecar cleaned up.`

If the sidecar file does not exist: skip silently.

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
- **TaskList unavailable**: do NOT skip the completion check — verify from the file store instead. The Step 1 `find "$MROOT/.claude/tasks" -name "<TICKET-ID>-*.json"` read does not depend on TaskList and survives `/clear`. Worktree removal must never proceed without a completion verdict from at least one surviving source (file store or TaskList); if the file store shows incomplete tasks, refuse exactly as Step 1 does. If neither source has any record, print the "Completion could not be verified" note and rely on the Step 6 uncommitted-changes backstop — never remove silently.
- **Worktree has uncommitted changes**: report clearly, do not force-remove
- **Memory file does not exist**: create it with the learnings section as the first content
- **Plan file not found**: skip plans update silently (not all projects use plans.md)
