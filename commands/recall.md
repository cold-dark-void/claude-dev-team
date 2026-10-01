---
name: recall
description: Search all prior work by topic across sessions, memory, specs, plans,
  and git history. Outputs claude --resume commands for matching sessions. Usage
  /recall [topic]
argument-hint: "[topic]"
agent: build
---

# Work Recall

Search all prior work for: **$ARGUMENTS**

## Your Task

Search across ALL available data sources for "$ARGUMENTS", synthesize findings,
and present an actionable summary with `claude --resume` commands so the user can
instantly resume any matching session.

---

## Step 0: Read the topic literally

A bare `/recall` has no topic. Stop with usage. Never eval the topic.

```bash
TOPIC=$(bash skills/lib/recall-topic.sh "$ARGUMENTS") || exit $?
# First line is the literal topic. Second line is the LIKE pattern (\ % _ escaped).
TOPIC_LITERAL=$(printf '%s\n' "$TOPIC" | head -1)
TOPIC_LIKE=$(printf '%s\n' "$TOPIC" | tail -1)
```

An empty topic makes `recall-topic.sh` exit 64 and print `Usage: /recall <topic>`.

## Step 1: Resolve paths

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
CLAUDE_DIR="$HOME/.claude"
```

---

## Step 2: Search structured sources FIRST (execute in parallel)

Search memory, specs, plans, commits, and backlog for the literal term FIRST.
These results will be used to expand the search for sessions.

### A. Current Project Git History

```bash
TOPIC=$(bash skills/lib/recall-topic.sh "$ARGUMENTS") || exit $?
TOPIC_LITERAL=$(printf '%s\n' "$TOPIC" | head -1)
git log --oneline --all --fixed-strings --grep="$TOPIC_LITERAL" -i -20
```

### B. Agent Memory Files

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
USE_DB=false
if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
  USE_DB=true
fi
```

If USE_DB=true, search the memories table. This is the keyword form from
`skills/memory-recall` Step 3, specialized for /recall: it is intentionally
keyword-only (no semantic mode) and capped at 10 because /recall is a cross-source
session/plan/spec/git finder, not a pure memory query — memory is one of several
sources here, so it shows a wider 300-char preview and a tighter 10-row cap rather
than the SKILL's 20-row keyword default.

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
TOPIC=$(bash skills/lib/recall-topic.sh "$ARGUMENTS") || exit $?
TOPIC_LIKE=$(printf '%s\n' "$TOPIC" | tail -1)
sqlite3 -header -column "$MEMDB" \
  "SELECT agent, type, tier, substr(content, 1, 300) AS content_preview, updated_at
   FROM memories
   WHERE content LIKE '%${TOPIC_LIKE}%' ESCAPE '\' COLLATE NOCASE
     AND archived = FALSE
   ORDER BY tier DESC, updated_at DESC
   LIMIT 10;"
```

If USE_DB=false, fall back to grepping .md files:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
TOPIC=$(bash skills/lib/recall-topic.sh "$ARGUMENTS") || exit $?
TOPIC_LITERAL=$(printf '%s\n' "$TOPIC" | head -1)
# Project-local agent memory
grep -F --directories=recurse -i -l -- "$TOPIC_LITERAL" "$MROOT/.claude/memory/"

# Global project memories
find ~/.claude/projects -mindepth 2 -maxdepth 2 -type d -name memory 2>/dev/null | while read -r d; do grep -F --directories=recurse -i -l -- "$TOPIC_LITERAL" "$d" 2>/dev/null; done
```

For each matching file (grep path only), extract the relevant lines with 2 lines of context.

### C. Plans

Search plan files for the topic:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
TOPIC=$(bash skills/lib/recall-topic.sh "$ARGUMENTS") || exit $?
TOPIC_LITERAL=$(printf '%s\n' "$TOPIC" | head -1)
grep -F --directories=recurse -i -l -- "$TOPIC_LITERAL" "$MROOT/.claude/plans/"
```

Read matching plan files — extract titles, status, AND key terms/phrases.

### D. Specs

Search spec files:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
TOPIC=$(bash skills/lib/recall-topic.sh "$ARGUMENTS") || exit $?
TOPIC_LITERAL=$(printf '%s\n' "$TOPIC" | head -1)
grep -F --directories=recurse -i -l -- "$TOPIC_LITERAL" "$MROOT/specs/"
```

Note spec IDs, titles, AND key terms/phrases from matching specs.

### E. Backlog

Search backlog items:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
TOPIC=$(bash skills/lib/recall-topic.sh "$ARGUMENTS") || exit $?
TOPIC_LITERAL=$(printf '%s\n' "$TOPIC" | head -1)
grep -F --directories=recurse -i -l -- "$TOPIC_LITERAL" "$MROOT/.claude/backlog/"
```

### F. Cross-Project Sessions

Search `~/.claude/projects/` directory names for projects that might match,
then check their session files:

```bash
TOPIC=$(bash skills/lib/recall-topic.sh "$ARGUMENTS") || exit $?
TOPIC_LITERAL=$(printf '%s\n' "$TOPIC" | head -1)
ls ~/.claude/projects/ 2>/dev/null | grep -F --ignore-case -- "$TOPIC_LITERAL"
```

---

## Step 2b: Extract related search terms

From the results of Step 2, extract **related keywords** that someone might have
used BEFORE the formal identifier "$ARGUMENTS" existed. These are terms that
describe the same concept in plain language.

For example, if "$ARGUMENTS" is "MEM-002" and the spec/plan mentions
"tiered memory distillation with LLM compression", the related terms would be:
"tiered distillation", "memory distillation", "LLM compression".

Build a list of up to 8 related search terms (may be fewer if sources are sparse) by:
1. Reading titles and descriptions from matching specs, plans, and memory entries
2. Extracting distinctive noun phrases and technical terms (not generic words)
3. Including any alternative names, aliases, branch names, or words from
   hyphenated identifiers (e.g., "MEM-002-tiered-distillation" yields
   "tiered distillation")

Skip generic terms that would produce too many false positives (e.g., "memory",
"fix").

**If Step 2 returned zero results**, decompose "$ARGUMENTS" itself to seed terms:
split on hyphens/underscores, strip numeric prefixes/suffixes, and use the
remaining words as search terms. For example, "MEM-002-tiered-distillation"
yields "tiered distillation", "tiered", "distillation".

---

## Step 2c: Search conversation history (with expanded terms)

Search `~/.claude/history.jsonl` for lines where the `display` field matches
the original "$ARGUMENTS" OR any related term from Step 2b (case-insensitive,
partial match). Build a single combined pattern (pipe-delimited alternation)
and scan the file in one pass — do NOT grep once per term.

Each line is JSON with fields: `display`, `timestamp`, `project`, `sessionId`.

Extract the most recent 20 matching entries across all terms combined. Group
by `sessionId` — each session may have multiple matching prompts.

When reporting sessions, indicate which search term matched:
- Sessions matching the original "$ARGUMENTS" → show normally
- Sessions matching only expanded terms → mark with `(related: "<term>")`

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

  <sessionId> | <date> | <project> | <N> prompts (related: "<matched term>")
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
- Show at most 10 sessions, 10 memory matches, 5 specs, 5 plans, 10 commits
- A bare `/recall` prints `Usage: /recall <topic>` and searches nothing
- If there are more matches than the limit, show the count: "(+N more)"
- Always output the full sessionId in resume commands — never truncate
- The `history.jsonl` can be large — use efficient line-by-line search
- Do not attempt to actually resume a session — just print the command
