---
name: mem-search
description: Search across all agent memory files (cortex, memory, lessons, context)
  for a keyword or topic. Shows which agents know what about a given subject.
  Usage /mem-search [topic]
argument-hint: [topic]
---

# Memory Search

Search all agent memory for: **$ARGUMENTS**

## Step 1: Resolve memory root

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
```

## Step 2: Check for SQLite DB

```bash
MEMDB="$MROOT/.claude/memory/memory.db"
USE_DB=false
if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
  USE_DB=true
fi
```

If `USE_DB=true`, search the memories table and display results:

```bash
sqlite3 -header -column "$MEMDB" \
  "SELECT agent, type, substr(content, 1, 200) AS content_preview, updated_at
   FROM memories
   WHERE content LIKE '%$ARGUMENTS%' COLLATE NOCASE
   ORDER BY updated_at DESC
   LIMIT 20;"
```

Output the DB results under a header:

```
═══ DB SEARCH: $ARGUMENTS ═══════════════════════════
<sqlite3 output>
═══════════════════════════════════════════════════════

TIP: For semantic search, use /memory-search <query>
```

If `USE_DB=false` (DB missing or sqlite3 unavailable), skip this step and fall through to the grep-based search below.

## Step 3: Discover agents

List all agent memory directories:

```bash
ls "$MROOT/.claude/memory/" 2>/dev/null
```

## Step 4: Search (parallel across all agents)

For each agent directory found, search all four memory files for "$ARGUMENTS"
(case-insensitive, partial match) with 2 lines of surrounding context:

Files to search per agent:
- `$MROOT/.claude/memory/<agent>/cortex.md` (architecture/domain)
- `$MROOT/.claude/memory/<agent>/memory.md` (working state)
- `$MROOT/.claude/memory/<agent>/lessons.md` (patterns/mistakes)
- `$WTROOT/.claude/memory/<agent>/context.md` (current task)

Use Grep with context lines to find matches.

Also search the project-level Claude memory:
- `$MROOT/.claude/memory/claude/memory.md`

## Step 5: Output

```
═══ MEMORY SEARCH: $ARGUMENTS ════════════════════════

@tech-lead / cortex.md:
  <matching lines with context>

@ic5 / lessons.md:
  <matching lines with context>

@pm / memory.md:
  <matching lines with context>

═══════════════════════════════════════════════════════
```

Rules:
- Omit agents/files with no matches
- Show the agent name and file type for each match
- Include 2 lines of context above and below each match
- If no matches found across any agent, say: "No agent memory matches for '$ARGUMENTS'."
- Sort by relevance: cortex matches first (deepest knowledge), then lessons, then memory, then context
