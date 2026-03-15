---
name: memory-search
description: Semantic search across all agent memories using embeddings
arguments: query text or --status flag
---

# /memory-search

Semantic search across all agent memories. Uses vector embeddings when available,
falls back to keyword search.

## Arguments

- `/memory-search <query>` — search for memories related to the query
- `/memory-search --status` — show memory DB status (mode, row counts)
- `/memory-search` (no args) — print usage

## Step 1: Parse arguments

If no arguments provided, print:
```
Usage: /memory-search <query>
       /memory-search --status

Semantic search across all agent memories.
For keyword search, use /mem-search instead.
```
And stop.

## Step 2: Resolve paths

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
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

MODE=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='embedding_mode';")
MODEL=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='embedding_model';")
DIMS=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='embedding_dimensions';")
TOTAL=$(sqlite3 "$MEMDB" "SELECT COUNT(*) FROM memories;")
AGENTS=$(sqlite3 "$MEMDB" "SELECT agent || ' (' || COUNT(*) || ')' FROM memories GROUP BY agent ORDER BY agent;" | tr '\n' ', ' | sed 's/,$//')

EMBED_URL=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='embedding_url';" 2>/dev/null)

echo "Memory DB:      $MEMDB"
echo "Embedding mode: $MODE ($MODEL, ${DIMS}-dim)"
[ -n "$EMBED_URL" ] && echo "Embedding URL:  $EMBED_URL"
echo "Total memories: $TOTAL"
echo "Agents:         $AGENTS"
```
And stop.

## Step 4: Search

Determine the search mode and execute:

```bash
if [ ! -f "$MEMDB" ] || ! command -v sqlite3 &>/dev/null; then
  # No DB — full fallback to grep
  MODE_LABEL="keyword / fallback"
  grep -ril "$QUERY" "$MROOT/.claude/memory/"*/*.md 2>/dev/null | while read -r FILE; do
    AGENT=$(basename "$(dirname "$FILE")")
    TYPE=$(basename "$FILE" .md)
    echo "@$AGENT / $TYPE:"
    grep -i -C 2 "$QUERY" "$FILE" | head -10
    echo ""
  done
else
  EMBED_MODE=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='embedding_mode';")
  EXT_SUFFIX="so"
  [ "$(uname -s)" = "Darwin" ] && EXT_SUFFIX="dylib"

  if [ "$EMBED_MODE" = "lembed" ] && [ -f "$EXT_DIR/vec0.$EXT_SUFFIX" ] && [ -f "$EXT_DIR/lembed0.$EXT_SUFFIX" ]; then
    MODE_LABEL="semantic / lembed"
    MODEL_PATH="$MODEL_DIR/all-MiniLM-L6-v2.gguf"

    RESULTS=$(sqlite3 "$MEMDB" <<EOSQL
.load $EXT_DIR/vec0
.load $EXT_DIR/lembed0
SELECT m.agent, m.type,
       CAST(ROUND((1 - e.distance) * 100) AS INTEGER) || '%' AS score,
       m.created_at,
       substr(m.content, 1, 200) AS snippet
FROM vec_memories_384 e
JOIN memories m ON m.id = e.memory_id
WHERE e.embedding MATCH lembed('$MODEL_PATH', '$QUERY')
  AND k = 10
ORDER BY e.distance ASC;
EOSQL
    )

  elif [ "$EMBED_MODE" = "remote" ]; then
    MODE_LABEL="semantic / remote"
    EMBED_URL=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='embedding_url';")
    EMBED_KEY="${EMBEDDING_API_KEY:-}"
    EMBED_MODEL="${EMBEDDING_MODEL:-}"
    DIMS=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='embedding_dimensions';")
    VEC_TABLE="vec_memories_${DIMS}"

    CURL_ARGS=(-s "$EMBED_URL" -H "Content-Type: application/json")
    [ -n "$EMBED_KEY" ] && CURL_ARGS+=(-H "Authorization: Bearer $EMBED_KEY")

    BODY="{\"input\":[$(echo "$QUERY" | jq -Rs .)]}"
    [ -n "$EMBED_MODEL" ] && BODY=$(echo "$BODY" | jq --arg m "$EMBED_MODEL" '. + {model: $m}')
    CURL_ARGS+=(-d "$BODY")

    QUERY_EMBEDDING=$(curl "${CURL_ARGS[@]}" | jq -c '.data[0].embedding // .embeddings[0] // .embedding')

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

  else
    MODE_LABEL="keyword / fallback"
    RESULTS=$(sqlite3 "$MEMDB" \
      "SELECT agent, type, '' AS score, updated_at, substr(content, 1, 200) AS snippet
       FROM memories WHERE content LIKE '%$QUERY%' COLLATE NOCASE
       ORDER BY updated_at DESC LIMIT 10;")
  fi
fi
```

## Step 5: Format output

Print results with a header showing the search mode:

```
MEMORY SEARCH: "<query>"  [<MODE_LABEL>]
════════════════════════════════════════════

@<agent> / <type>  (<score>)  <created_at>
  <snippet>...

@<agent> / <type>  (<score>)  <created_at>
  <snippet>...

════════════════════════════════════════════
Results: N matches
```

If no results, print:
```
MEMORY SEARCH: "<query>"  [<MODE_LABEL>]
════════════════════════════════════════════
No matching memories found.
```
