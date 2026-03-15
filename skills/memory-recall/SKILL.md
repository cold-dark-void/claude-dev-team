---
name: memory-recall
description: Search and retrieve agent memories from SQLite DB with semantic or keyword search
---

# memory-recall

Search and retrieve memories stored by agents. Supports semantic (vector) search when
embeddings are available, keyword search as a fallback, and `.md` file grep when the DB
is absent entirely.

---

## Step 1: Resolve paths and detect storage mode

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
EXT_DIR="$MROOT/.claude/memory/extensions"
MODEL_DIR="$MROOT/.claude/memory/models"

USE_DB=false
if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
  USE_DB=true
fi
```

---

## Step 2: Load all memories for an agent (session start)

Used by agents at boot to load their full context. Replace `<AGENT>` with the agent name
(e.g., `ic5`, `tech-lead`).

```bash
# Load all memories (returns multiple rows per type — each row is one focused entry)
sqlite3 "$MEMDB" "SELECT type, content FROM memories WHERE agent='<AGENT>' ORDER BY type, created_at DESC;"
```

**Fallback** when `USE_DB=false`:

```bash
for TYPE in cortex memory lessons; do
  cat "$MROOT/.claude/memory/<AGENT>/$TYPE.md" 2>/dev/null
done
```

---

## Step 3: Keyword search (cross-agent)

Simple LIKE-based search — no extensions required. Replace `<QUERY>` and `<LIMIT>`.

```bash
sqlite3 -header -column "$MEMDB" \
  "SELECT agent, type, substr(content, 1, 200) AS snippet, updated_at
   FROM memories
   WHERE content LIKE '%<QUERY>%' COLLATE NOCASE
   ORDER BY updated_at DESC
   LIMIT <LIMIT>;"
```

**Optional agent filter** — append to the WHERE clause:

```bash
# Add: AND agent='<AGENT_FILTER>'
```

**Optional type filter** — append to the WHERE clause:

```bash
# Add: AND type='<TYPE_FILTER>'
```

---

## Step 4: Semantic search (requires extensions)

Cosine similarity search using stored embeddings. Gracefully degrades to keyword search
when extensions or models are absent.

```bash
EMBED_MODE=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='embedding_mode';")

EXT_SUFFIX="so"
[ "$(uname -s)" = "Darwin" ] && EXT_SUFFIX="dylib"

if [ "$EMBED_MODE" = "lembed" ] && [ -f "$EXT_DIR/vec0.$EXT_SUFFIX" ] && [ -f "$EXT_DIR/lembed0.$EXT_SUFFIX" ]; then
  MODEL_PATH="$MODEL_DIR/all-MiniLM-L6-v2.gguf"
  sqlite3 "$MEMDB" <<EOSQL
.load $EXT_DIR/vec0
.load $EXT_DIR/lembed0
SELECT m.agent, m.type,
       substr(m.content, 1, 200) AS snippet,
       e.distance AS score,
       m.created_at
FROM vec_memories_384 e
JOIN memories m ON m.id = e.memory_id
WHERE e.embedding MATCH lembed('$MODEL_PATH', '<QUERY>')
  AND k = <LIMIT>
ORDER BY e.distance ASC;
EOSQL

elif [ "$EMBED_MODE" = "remote" ]; then
  EMBED_URL=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='embedding_url';")
  EMBED_KEY="${EMBEDDING_API_KEY:-}"
  EMBED_MODEL="${EMBEDDING_MODEL:-}"
  DIMS=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='embedding_dimensions';")
  VEC_TABLE="vec_memories_${DIMS}"

  # Build curl args
  CURL_ARGS=(-s "$EMBED_URL" -H "Content-Type: application/json")
  [ -n "$EMBED_KEY" ] && CURL_ARGS+=(-H "Authorization: Bearer $EMBED_KEY")

  BODY="{\"input\":[$(echo "$QUERY" | jq -Rs .)]}"
  [ -n "$EMBED_MODEL" ] && BODY=$(echo "$BODY" | jq --arg m "$EMBED_MODEL" '. + {model: $m}')
  CURL_ARGS+=(-d "$BODY")

  RESPONSE=$(curl "${CURL_ARGS[@]}")
  QUERY_EMBEDDING=$(echo "$RESPONSE" | jq -c '.data[0].embedding // .embeddings[0] // .embedding')

  sqlite3 "$MEMDB" <<EOSQL
.load $EXT_DIR/vec0
SELECT m.agent, m.type,
       substr(m.content, 1, 200) AS snippet,
       e.distance AS score,
       m.created_at
FROM ${VEC_TABLE} e
JOIN memories m ON m.id = e.memory_id
WHERE e.embedding MATCH '$QUERY_EMBEDDING'
  AND k = <LIMIT>
ORDER BY e.distance ASC;
EOSQL

else
  # Fallback: keyword search
  echo "[memory-recall] No embeddings available. Using keyword search."
  sqlite3 -header -column "$MEMDB" \
    "SELECT agent, type, substr(content, 1, 200) AS snippet, updated_at
     FROM memories WHERE content LIKE '%<QUERY>%' COLLATE NOCASE
     ORDER BY updated_at DESC LIMIT <LIMIT>;"
fi
```

---

## Step 5: Fallback (.md grep)

Used when `USE_DB=false`. Searches all agent `.md` files with grep.

```bash
if [ "$USE_DB" = "false" ]; then
  grep -ril "<QUERY>" "$MROOT/.claude/memory/"*/*.md 2>/dev/null | while read -r FILE; do
    AGENT=$(basename "$(dirname "$FILE")")
    TYPE=$(basename "$FILE" .md)
    echo "=== @$AGENT / $TYPE ==="
    grep -i -C 2 "<QUERY>" "$FILE"
    echo ""
  done
fi
```

---

## Step 6: Interface summary

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| query | yes | — | Search query string |
| agent | no | all agents | Filter to single agent |
| type | no | all types | Filter to cortex/memory/lessons |
| limit | no | 5 | Max results to return |

---

## Step 7: Return format

Each result includes:

- `agent` — which agent stored this memory
- `type` — cortex, memory, or lessons
- `snippet` — first 200 chars of content
- `score` — cosine distance (semantic) or null (keyword)
- `created_at` — when the memory was stored

---

## Step 8: Handling not-yet-embedded memories

After semantic results, also surface memories that lack embeddings for the current model
(e.g., memories stored before embedding was configured, or stored while extensions were
absent). Replace `<CURRENT_MODEL>` and `<QUERY>`.

```bash
# Append unembedded memories (keyword match) after semantic results
sqlite3 "$MEMDB" <<EOSQL
SELECT m.agent, m.type, substr(m.content, 1, 200) AS snippet,
       '[not yet embedded]' AS score, m.created_at
FROM memories m
LEFT JOIN embedding_meta em ON em.memory_id = m.id AND em.model = '<CURRENT_MODEL>'
WHERE em.memory_id IS NULL
  AND m.content LIKE '%<QUERY>%' COLLATE NOCASE
LIMIT 5;
EOSQL
```

---

## Design notes

- The `MATCH` operator + `k = N` is sqlite-vec's KNN syntax — it is not standard SQL.
- Distance is cosine distance: lower = more similar, 0 = identical.
- To convert to similarity percentage: `(1 - distance) * 100`.
- `lembed()` takes the **model file path** (GGUF) as its first argument, not a model name.
- For remote embedding providers, the URL and optional API key are read from the DB config
  and the `EMBEDDING_API_KEY` / `EMBEDDING_MODEL` environment variables respectively.
- `jq` is required for remote embedding extraction and request building.
- Vec0 virtual tables (`vec_memories_384`, `vec_memories_768`) are only accessible when
  the sqlite-vec extension is loaded. Always guard vec0 operations with an extension
  availability check.
- The `USE_DB` guard (Step 1) must wrap all DB operations — fall through to `.md` grep
  (Step 5) whenever `USE_DB=false`.
