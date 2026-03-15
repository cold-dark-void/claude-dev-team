---
name: recall
description: Search all prior work by topic across sessions, memory, specs, plans,
  and git history. Outputs claude --resume commands for matching sessions. Usage
  /recall [topic]
argument-hint: [topic]
---

# Work Recall

Search all prior work for: **$ARGUMENTS**

## Your Task

Search across ALL available data sources for "$ARGUMENTS", synthesize findings,
and present an actionable summary with `claude --resume` commands so the user can
instantly resume any matching session.

---

## Step 1: Resolve paths

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && PROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || PROOT=$(pwd)
CLAUDE_DIR="$HOME/.claude"
```

---

## Step 2: Search (execute ALL available searches in parallel)

### A. Conversation History

Search `~/.claude/history.jsonl` for lines where the `display` field matches
"$ARGUMENTS" (case-insensitive, partial match). Each line is JSON with fields:
`display`, `timestamp`, `project`, `sessionId`.

Extract the most recent 15 matching entries. Group by `sessionId` — each session
may have multiple matching prompts.

### B. Current Project Git History

```bash
git log --oneline --all --grep="$ARGUMENTS" -i -20
```

### C. Agent Memory Files

```bash
MEMDB="$PROOT/.claude/memory/memory.db"
USE_DB=false
if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
  USE_DB=true
fi
```

If USE_DB=true, search the memories table:

```bash
sqlite3 -header -column "$MEMDB" \
  "SELECT agent, type, substr(content, 1, 300) AS content_preview, updated_at
   FROM memories
   WHERE content LIKE '%$ARGUMENTS%' COLLATE NOCASE
   ORDER BY updated_at DESC
   LIMIT 10;"
```

If USE_DB=false, fall back to grepping .md files:

```bash
# Project-local agent memory
grep -r -i -l "$ARGUMENTS" $PROOT/.claude/memory/ 2>/dev/null

# Global project memories
grep -r -i -l "$ARGUMENTS" ~/.claude/projects/*/memory/ 2>/dev/null
```

For each matching file (grep path only), extract the relevant lines with 2 lines of context.

### D. Plans

Search plan files for the topic:

```bash
grep -r -i -l "$ARGUMENTS" $PROOT/.claude/plans/ 2>/dev/null
```

Read matching plan titles and status.

### E. Specs

Search spec files:

```bash
grep -r -i -l "$ARGUMENTS" $PROOT/specs/ 2>/dev/null
```

Note spec IDs and titles.

### F. Backlog

Search backlog items:

```bash
grep -r -i -l "$ARGUMENTS" $PROOT/.claude/backlog/ 2>/dev/null
```

### G. Cross-Project Sessions

Search `~/.claude/projects/` directory names for projects that might match,
then check their session files:

```bash
ls ~/.claude/projects/ | grep -i "$ARGUMENTS" 2>/dev/null
```

---

## Step 3: Output

Present findings grouped and sorted by recency (newest first):

```
═══ RECALL: $ARGUMENTS ═══════════════════════════════

SESSIONS (sorted by most recent):

  <sessionId> | <date> | <project> | <N> prompts
    > "<first matching user prompt>"
    > "<second matching prompt>"
    Resume: claude --resume <full-sessionId>

  <sessionId> | <date> | <project> | <N> prompts
    > "<matching prompt>"
    Resume: claude --resume <full-sessionId>

AGENT MEMORY:
  <agent>/<file> — "<matching context snippet>"

SPECS:
  <spec-id> — <title>

PLANS:
  <plan-file> — <title> [STATUS]

COMMITS:
  <hash> <message> (<date>)

BACKLOG:
  <item-id> — <title> [open|closed]

═══════════════════════════════════════════════════════
```

Omit any section that has zero results.

---

## Step 4: Context Recovery

After showing the summary:

1. **If sessions found:** Read the most recent matching session's first 5 user
   prompts from `history.jsonl` to provide richer context. Then say:
   "Most recent session was on [date] in [project]. To resume: `claude --resume <id>`"

2. **If agent memory found but no sessions:** Summarize the relevant memory
   content. Say: "Found context in agent memory but no matching sessions."

3. **If nothing found:** Say: "No prior work found on '$ARGUMENTS'. Ready to
   start fresh."

---

## Rules

- Sort everything by recency (newest first)
- Show at most 10 sessions, 5 memory matches, 5 specs, 5 plans, 10 commits
- If there are more matches than the limit, show the count: "(+N more)"
- Always output the full sessionId in resume commands — never truncate
- The `history.jsonl` can be large — use efficient line-by-line search
- Do not attempt to actually resume a session — just print the command
