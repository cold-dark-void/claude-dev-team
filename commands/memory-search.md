---
name: memory-search
description: Search across all agent memories — semantic (embeddings), keyword (DB),
  or grep (.md fallback). Shows which agents know what about a given subject.
arguments: query text or --status flag
argument-hint: <query> or --status
---

# /memory-search

Search all agent memories. Auto-detects the best available mode:
semantic (vector embeddings) → keyword (SQLite LIKE) → grep (.md files).

## Arguments

- `/memory-search <query>` — search for memories related to the query
- `/memory-search --status` — show memory DB status (mode, row counts)
- `/memory-search` (no args) — print usage

## Step 1: Parse arguments

If no arguments provided, print:
```
Usage: /memory-search <query>
       /memory-search --status

Searches all agent memories using the best available method:
  - Semantic search (vector embeddings) when DB + embeddings configured
  - Keyword search (SQLite LIKE) when DB exists but no embeddings
  - Grep search (.md files) when no DB available
```
And stop.

## Step 2: Resolve paths

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
EXT_DIR="$MROOT/.claude/memory/extensions"
MODEL_DIR="$MROOT/.claude/memory/models"
```

## Step 3: Handle --status flag

If arguments contain `--status`:

```bash
if [ ! -f "$MEMDB" ]; then
  echo "Memory DB: not initialized (run /init-team first)"
  exit 0
fi

EMBED_MODE=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='embedding_mode';")
MODEL=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='embedding_model';")
DIMS=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='embedding_dimensions';")
TOTAL=$(sqlite3 "$MEMDB" "SELECT COUNT(*) FROM memories;")
AGENTS=$(sqlite3 "$MEMDB" "SELECT agent || ' (' || COUNT(*) || ')' FROM memories GROUP BY agent ORDER BY agent;" | tr '\n' ', ' | sed 's/,$//')

EMBED_URL=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='embedding_url';" 2>/dev/null)

echo "Memory DB:      $MEMDB"
echo "Embedding mode: $EMBED_MODE ($MODEL, ${DIMS}-dim)"
[ -n "$EMBED_URL" ] && echo "Embedding URL:  $EMBED_URL"
echo "Total memories: $TOTAL"
echo "Agents:         $AGENTS"
```
And stop.

## Step 4: Search

Determine the best search mode and execute:

```bash
if [ ! -f "$MEMDB" ] || ! command -v sqlite3 &>/dev/null; then
  SEARCH_MODE="grep"
else
  EMBED_MODE=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='embedding_mode';")
  EXT_SUFFIX="so"
  [ "$(uname -s)" = "Darwin" ] && EXT_SUFFIX="dylib"

  DIMS=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='embedding_dimensions';" 2>/dev/null)

  if [ "$EMBED_MODE" = "lembed" ] && [ -f "$EXT_DIR/vec0.$EXT_SUFFIX" ] && [ -f "$EXT_DIR/lembed0.$EXT_SUFFIX" ] && [[ "$DIMS" =~ ^[0-9]+$ ]]; then
    SEARCH_MODE="semantic/lembed"
  elif [ "$EMBED_MODE" = "remote" ] && [[ "$DIMS" =~ ^[0-9]+$ ]]; then
    EMBED_URL=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='embedding_url';" 2>/dev/null)
    [ -n "$EMBED_URL" ] && SEARCH_MODE="semantic/remote" || SEARCH_MODE="keyword"
  else
    SEARCH_MODE="keyword"
  fi
fi
```

### Mode: semantic/lembed

```bash
MODEL_PATH="$MODEL_DIR/all-MiniLM-L6-v2.gguf"
VEC_TABLE="vec_memories_${DIMS}"

RESULTS=$(sqlite3 "$MEMDB" <<EOSQL
.load $EXT_DIR/vec0
.load $EXT_DIR/lembed0
SELECT m.agent, m.type,
       CAST(ROUND((1 - e.distance) * 100) AS INTEGER) || '%' AS score,
       m.created_at,
       substr(m.content, 1, 200) AS snippet
FROM ${VEC_TABLE} e
JOIN memories m ON m.id = e.memory_id
WHERE e.embedding MATCH lembed('$MODEL_PATH', '$QUERY')
  AND k = 10
ORDER BY e.distance ASC;
EOSQL
)
```

### Mode: semantic/remote

```bash
# EMBED_URL already resolved during mode detection
EMBED_KEY="${EMBEDDING_API_KEY:-}"
EMBED_MODEL="${EMBEDDING_MODEL:-}"
VEC_TABLE="vec_memories_${DIMS}"

CURL_ARGS=(-s "$EMBED_URL" -H "Content-Type: application/json")
[ -n "$EMBED_KEY" ] && CURL_ARGS+=(-H "Authorization: Bearer $EMBED_KEY")

BODY="{\"input\":[$(echo "$QUERY" | jq -Rs .)]}"
[ -n "$EMBED_MODEL" ] && BODY=$(echo "$BODY" | jq --arg m "$EMBED_MODEL" '. + {model: $m}')
CURL_ARGS+=(-d "$BODY")

QUERY_EMBEDDING=$(curl "${CURL_ARGS[@]}" | jq -c '.data[0].embedding // .embeddings[0] // .embedding')

# Fall back to keyword if embedding failed
if [ -z "$QUERY_EMBEDDING" ] || [ "$QUERY_EMBEDDING" = "null" ]; then
  SEARCH_MODE="keyword"
fi

RESULTS=$(sqlite3 "$MEMDB" <<EOSQL
.load $EXT_DIR/vec0
SELECT m.agent, m.type,
       CAST(ROUND((1 - e.distance) * 100) AS INTEGER) || '%' AS score,
       m.created_at,
       substr(m.content, 1, 200) AS snippet
FROM ${VEC_TABLE} e
JOIN memories m ON m.id = e.memory_id
WHERE e.embedding MATCH '$QUERY_EMBEDDING'
  AND k = 10
ORDER BY e.distance ASC;
EOSQL
)
```

### Mode: keyword

```bash
RESULTS=$(sqlite3 "$MEMDB" \
  "SELECT agent, type, '' AS score, updated_at, substr(content, 1, 200) AS snippet
   FROM memories WHERE content LIKE '%$QUERY%' COLLATE NOCASE
   ORDER BY updated_at DESC LIMIT 20;")
```

### Mode: grep

Search .md files across all agent directories:

```bash
GREP_RESULTS=""
for DIR in "$MROOT/.claude/memory"/*/; do
  AGENT=$(basename "$DIR")
  # Skip non-agent dirs (extensions, models)
  [ "$AGENT" = "extensions" ] || [ "$AGENT" = "models" ] && continue
  for TYPE in cortex memory lessons; do
    FILE="$MROOT/.claude/memory/$AGENT/$TYPE.md"
    [ -f "$FILE" ] || continue
    MATCHES=$(grep -i -C 2 "$QUERY" "$FILE" 2>/dev/null) || continue
    GREP_RESULTS="${GREP_RESULTS}@${AGENT} / ${TYPE}.md:\n  ${MATCHES}\n\n"
  done
  # Also check worktree-local context.md
  CTX="$WTROOT/.claude/memory/$AGENT/context.md"
  if [ -f "$CTX" ]; then
    MATCHES=$(grep -i -C 2 "$QUERY" "$CTX" 2>/dev/null) || true
    [ -n "$MATCHES" ] && GREP_RESULTS="${GREP_RESULTS}@${AGENT} / context.md:\n  ${MATCHES}\n\n"
  fi
done
```

## Step 5: Format output

For DB-backed modes (semantic or keyword), print results with a header showing the search mode:

```
MEMORY SEARCH: "<query>"  [<SEARCH_MODE>]
════════════════════════════════════════════

@<agent> / <type>  (<score>)  <created_at>
  <snippet>...

@<agent> / <type>  (<score>)  <created_at>
  <snippet>...

════════════════════════════════════════════
Results: N matches
```

For grep mode:

```
MEMORY SEARCH: "<query>"  [grep / .md files]
════════════════════════════════════════════

@<agent> / <type>.md:
  <matching lines with context>

@<agent> / <type>.md:
  <matching lines with context>

════════════════════════════════════════════
```

If no results in any mode, print:
```
MEMORY SEARCH: "<query>"  [<SEARCH_MODE>]
════════════════════════════════════════════
No matching memories found.
```
