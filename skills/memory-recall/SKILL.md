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

Tiered loading: if distilled content (tier 1 or 2) exists, load only the compressed layers.
Otherwise fall back to raw tier-0 memories (backward compatible with pre-distillation DBs).

```bash
# Check if agent has any distilled content (tier 1 or 2)
HAS_DISTILLED=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT COUNT(*) FROM memories
  WHERE agent='<AGENT>' AND tier > 0 AND archived=FALSE;")

if [ "${HAS_DISTILLED:-0}" -gt 0 ]; then
  # Tier 2: core knowledge (always loaded, small set)
  sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT type, content FROM memories
    WHERE agent='<AGENT>' AND tier=2 AND archived=FALSE
    ORDER BY type, updated_at DESC;"
  # Tier 1: digests (compressed summaries)
  sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT type, content FROM memories
    WHERE agent='<AGENT>' AND tier=1 AND archived=FALSE
    ORDER BY type, updated_at DESC;"
else
  # No distilled content yet — load raw tier-0 (backward compat)
  sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT type, content FROM memories
    WHERE agent='<AGENT>' AND tier=0 AND archived=FALSE
    ORDER BY type, created_at DESC;"
fi
```

**Fallback** when `USE_DB=false`:

```bash
for TYPE in cortex memory lessons; do
  cat "$MROOT/.claude/memory/<AGENT>/$TYPE.md" 2>/dev/null
done
```

---

## Step 3: Keyword search (cross-agent)

Simple LIKE-based search — no extensions required. Keyword mode returns up to 20 rows
per SPEC-006 (`LIMIT 20`).

The query is interpolated into SQL, so it MUST be single-quote escaped first (`'`→`''`)
to prevent SQL injection. Define `ESCAPED_QUERY` once and use it everywhere the query
lands in SQL (here and in the LIKE/lembed paths below):

```bash
ESCAPED_QUERY=$(printf '%s' "$QUERY" | sed "s/'/''/g")
sqlite3 -header -column "$MEMDB" \
  "SELECT agent, type, tier, substr(content, 1, 200) AS snippet, updated_at
   FROM memories
   WHERE content LIKE '%${ESCAPED_QUERY}%' COLLATE NOCASE
     AND archived = FALSE
   ORDER BY tier DESC, updated_at DESC
   LIMIT 20;"
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

DIMS=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='embedding_dimensions';")
if [ "$EMBED_MODE" = "lembed" ] && [ -f "$EXT_DIR/vec0.$EXT_SUFFIX" ] && [ -f "$EXT_DIR/lembed0.$EXT_SUFFIX" ] && \
   [[ "$DIMS" =~ ^[0-9]+$ ]] && [ "$DIMS" -gt 0 ]; then
  MODEL_PATH="$MODEL_DIR/all-MiniLM-L6-v2.gguf"
  VEC_TABLE="vec_memories_${DIMS}"
  # Escape the query for SQL interpolation (see Step 3): '→''
  ESCAPED_QUERY=$(printf '%s' "$QUERY" | sed "s/'/''/g")
  sqlite3 "$MEMDB" <<EOSQL
.load $EXT_DIR/vec0
.load $EXT_DIR/lembed0
SELECT m.agent, m.type, m.tier,
       substr(m.content, 1, 200) AS snippet,
       CAST(ROUND((1 - e.distance) * 100) AS INTEGER) || '%' AS score,
       m.created_at
FROM ${VEC_TABLE} e
JOIN memories m ON m.id = e.memory_id AND m.archived = FALSE
WHERE e.embedding MATCH lembed('$MODEL_PATH', '$ESCAPED_QUERY')
  AND k = 10
ORDER BY m.tier DESC, e.distance ASC;
EOSQL

elif [ "$EMBED_MODE" = "remote" ] && \
     DIMS=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='embedding_dimensions';") && \
     [[ "$DIMS" =~ ^[0-9]+$ ]] && [ "$DIMS" -gt 0 ]; then
  EMBED_URL=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='embedding_url';")
  EMBED_KEY="${EMBEDDING_API_KEY:-}"
  EMBED_MODEL="${EMBEDDING_MODEL:-}"
  VEC_TABLE="vec_memories_${DIMS}"

  # Build curl args — auth header via config file to avoid leaking in ps aux
  CURL_ARGS=(-s "$EMBED_URL" -H "Content-Type: application/json")
  CURL_CONFIG=""
  if [ -n "$EMBED_KEY" ]; then
    CURL_CONFIG=$(mktemp "${TMPDIR:-/tmp}/curl-cfg.XXXXXX")
    printf 'header = "Authorization: Bearer %s"\n' "$EMBED_KEY" > "$CURL_CONFIG"
    chmod 600 "$CURL_CONFIG"
    CURL_ARGS+=(-K "$CURL_CONFIG")
  fi

  BODY="{\"input\":[$(echo "$QUERY" | jq -Rs .)]}"
  [ -n "$EMBED_MODEL" ] && BODY=$(echo "$BODY" | jq --arg m "$EMBED_MODEL" '. + {model: $m}')
  CURL_ARGS+=(-d "$BODY")

  RESPONSE=$(curl "${CURL_ARGS[@]}")
  [ -n "$CURL_CONFIG" ] && rm -f "$CURL_CONFIG"
  QUERY_EMBEDDING=$(echo "$RESPONSE" | jq -c '.data[0].embedding // .embeddings[0] // .embedding')

  # $QUERY_EMBEDDING crosses a network trust boundary (remote endpoint) and is
  # interpolated raw into the MATCH clause. Require a bracketed numeric vector —
  # reject anything outside digits . , e E + - space [ ] and fall back to keyword
  # search (']' first and '-' last keep the bracket class literal).
  if [ -z "$QUERY_EMBEDDING" ] || [ "$QUERY_EMBEDDING" = "null" ] || \
     printf '%s' "$QUERY_EMBEDDING" | grep -q '[^][0-9.,eE+ -]'; then
    echo "[memory-recall] Invalid/empty embedding from endpoint. Using keyword search."
    ESCAPED_QUERY=$(printf '%s' "$QUERY" | sed "s/'/''/g")
    sqlite3 -header -column "$MEMDB" \
      "SELECT agent, type, tier, substr(content, 1, 200) AS snippet, updated_at
       FROM memories WHERE content LIKE '%${ESCAPED_QUERY}%' COLLATE NOCASE
         AND archived = FALSE
       ORDER BY tier DESC, updated_at DESC LIMIT 20;"
    exit 0
  fi

  sqlite3 "$MEMDB" <<EOSQL
.load $EXT_DIR/vec0
SELECT m.agent, m.type, m.tier,
       substr(m.content, 1, 200) AS snippet,
       CAST(ROUND((1 - e.distance) * 100) AS INTEGER) || '%' AS score,
       m.created_at
FROM ${VEC_TABLE} e
JOIN memories m ON m.id = e.memory_id AND m.archived = FALSE
WHERE e.embedding MATCH '$QUERY_EMBEDDING'
  AND k = 10
ORDER BY m.tier DESC, e.distance ASC;
EOSQL

else
  # Fallback: keyword search
  echo "[memory-recall] No embeddings available. Using keyword search."
  ESCAPED_QUERY=$(printf '%s' "$QUERY" | sed "s/'/''/g")
  sqlite3 -header -column "$MEMDB" \
    "SELECT agent, type, tier, substr(content, 1, 200) AS snippet, updated_at
     FROM memories WHERE content LIKE '%${ESCAPED_QUERY}%' COLLATE NOCASE
       AND archived = FALSE
     ORDER BY tier DESC, updated_at DESC LIMIT 20;"
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
| type | no | all types | Filter to cortex/memory/lessons/digest/core |
| limit | no | semantic 10 / keyword 20 | Max results (SPEC-006: top-10 semantic, up-to-20 keyword) |

**Filtering:** Archived rows (`archived = TRUE`) are **never** returned in any mode
(session load, keyword search, semantic search, or unembedded fallback). This is enforced
at the query level in every step above.

---

## Step 7: Return format

Each result includes:

- `agent` — which agent stored this memory
- `type` — cortex, memory, lessons, digest, or core
- `tier` — 0 (raw), 1 (digest), or 2 (core)
- `snippet` — first 200 chars of content
- `score` — similarity percentage `(1 - distance) * 100` (semantic) or empty (keyword)
- `created_at` — when the memory was stored

---

## Step 8: Handling not-yet-embedded memories

After semantic results, also surface memories that lack embeddings for the current model
(e.g., memories stored before embedding was configured, or stored while extensions were
absent). Replace `<CURRENT_MODEL>`. The query is single-quote escaped (`ESCAPED_QUERY`,
see Step 3) before interpolation.

```bash
# Append unembedded memories (keyword match) after semantic results
ESCAPED_QUERY=$(printf '%s' "$QUERY" | sed "s/'/''/g")
sqlite3 "$MEMDB" <<EOSQL
SELECT m.agent, m.type, m.tier, substr(m.content, 1, 200) AS snippet,
       '[not yet embedded]' AS score, m.created_at
FROM memories m
LEFT JOIN embedding_meta em ON em.memory_id = m.id AND em.model = '<CURRENT_MODEL>'
WHERE em.memory_id IS NULL
  AND m.archived = FALSE
  AND m.content LIKE '%${ESCAPED_QUERY}%' COLLATE NOCASE
LIMIT 10;
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
