---
name: memory-store
description: Write agent memories to the SQLite database (or fall back to .md files). Handles
  DB detection, SQL-safe INSERT/UPDATE, optional embedding generation (lembed or remote
  embedding provider), and retry on SQLITE_BUSY. Usage: read this file to learn the
  protocol, then execute the relevant bash blocks.
---

# memory-store

Write a memory record for an agent. Supports both the SQLite DB path (preferred) and
the legacy `.md` file fallback when the DB or sqlite3 are unavailable.

---

## Step 1: Resolve paths and detect storage mode

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
EXT_DIR="$MROOT/.claude/memory/extensions"

# Determine storage mode
USE_DB=false
if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
  USE_DB=true
fi
```

---

## Step 2: Store a memory (DB path)

Replace `<AGENT>`, `<TYPE>`, and `<CONTENT_ESCAPED>` with real values.
`<TYPE>` must be one of: `cortex`, `memory`, `lessons`.

**Write protocol: append-only — one focused fact per INSERT.**

```bash
# APPEND a focused memory entry (one fact, decision, or lesson per INSERT)
ESCAPED=$(printf '%s' "$CONTENT" | sed "s/'/''/g")
sqlite3 "$MEMDB" "INSERT INTO memories(agent, type, content) VALUES ('<AGENT>', '<TYPE>', '$ESCAPED');"
```

**Use heredoc for multi-line content** to avoid shell quoting issues:

```bash
sqlite3 "$MEMDB" <<'EOSQL'
INSERT INTO memories(agent, type, content) VALUES (
  'tech-lead',
  'cortex',
  'Cache: sharded LRU in internal/cache/, keys sha256(model+prompt), TTL 1h default'
);
EOSQL
```

**Capture the new row ID in the same session** (needed for embedding — see Step 4):
```bash
MEMORY_ID=$(sqlite3 "$MEMDB" "INSERT INTO memories(agent, type, content)
  VALUES ('<AGENT>', '<TYPE>', '$ESCAPED');
  SELECT last_insert_rowid();")
```

> Note: `last_insert_rowid()` MUST be called within the same sqlite3 session as the
> INSERT. A separate `sqlite3 "$MEMDB" "SELECT last_insert_rowid();"` call will return
> 0 because each invocation is an independent connection.

---

### What makes a good memory entry

Each INSERT should capture ONE focused piece of knowledge:
- A specific architectural fact: `"Cache uses sharded LRU with per-shard locks, max size via DESCRIBER_CACHE_SIZE"`
- A key decision: `"Chose SQLite over Postgres for simplicity — no server needed"`
- A lesson learned: `"NEVER mock the database — prod migration broke despite green mocked tests"`
- A pattern to follow: `"All backends implement the Describer interface in internal/backend/"`

Do NOT write:
- Entire codebase maps as one entry (break into per-subsystem entries)
- Multi-topic paragraphs (split into separate INSERTs)
- Duplicate entries (search first with memory-recall before writing)

---

## Step 3: Store a memory (fallback .md path)

Use this branch when `USE_DB=false` (DB file absent or sqlite3 not installed).

```bash
AGENT_MEM="$MROOT/.claude/memory/<AGENT>"
mkdir -p "$AGENT_MEM"
cat > "$AGENT_MEM/<TYPE>.md" << 'EOF'
<content>
EOF
echo "[memory-store] DB unavailable — writing to .md fallback."
```

`<TYPE>` maps to the filename: `cortex.md`, `memory.md`, or `lessons.md`.

---

## Step 4: Generate embedding after store (if extensions available)

This step is optional. Skip it when the embedding mode is `fallback` or when the
required extensions/models are absent.

```bash
# Read embedding mode from config
EMBED_MODE=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='embedding_mode';")

# Determine platform extension suffix
EXT_SUFFIX="so"
[ "$(uname -s)" = "Darwin" ] && EXT_SUFFIX="dylib"
```

### 4a. lembed mode (sqlite-lembed + local GGUF model)

The `lembed()` function takes the **model file path** as its first argument, not the
model name. Ensure the GGUF file exists before calling.

```bash
if [ "$EMBED_MODE" = "lembed" ] && \
   [ -f "$EXT_DIR/vec0.$EXT_SUFFIX" ] && \
   [ -f "$EXT_DIR/lembed0.$EXT_SUFFIX" ]; then
  MODEL_PATH="$MROOT/.claude/memory/models/all-MiniLM-L6-v2.gguf"
  sqlite3 "$MEMDB" <<EOSQL
.load $EXT_DIR/vec0
.load $EXT_DIR/lembed0
INSERT INTO vec_memories_384(memory_id, embedding)
  VALUES ($MEMORY_ID, lembed('$MODEL_PATH', '<CONTENT_ESCAPED>'));
INSERT OR IGNORE INTO embedding_meta(memory_id, model, dimensions, vec_table)
  VALUES ($MEMORY_ID, 'all-MiniLM-L6-v2', 384, 'vec_memories_384');
EOSQL
fi
```

### 4b. remote mode (any OpenAI-compatible embedding provider)

Reads `embedding_url` from the config table. Optionally reads `EMBEDDING_API_KEY` and
`EMBEDDING_MODEL` from the environment. Handles both OpenAI (`data[0].embedding`) and
ollama-style (`embeddings[0]` / `embedding`) response shapes. Dimensions are inferred
from the response so this works with any model.

```bash
elif [ "$EMBED_MODE" = "remote" ]; then
  EMBED_URL=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='embedding_url';")
  EMBED_KEY="${EMBEDDING_API_KEY:-}"
  EMBED_MODEL="${EMBEDDING_MODEL:-}"

  # Build curl args (array to avoid eval/quoting issues)
  CURL_ARGS=(-s "$EMBED_URL" -H "Content-Type: application/json")
  [ -n "$EMBED_KEY" ] && CURL_ARGS+=(-H "Authorization: Bearer $EMBED_KEY")

  # Truncate content for embedding (most models have ~512 token limit)
  EMBED_TEXT=$(echo "$CONTENT" | head -c 1500)

  # Build request body
  BODY="{\"input\":[$(echo "$EMBED_TEXT" | jq -Rs .)]}"
  [ -n "$EMBED_MODEL" ] && BODY=$(echo "$BODY" | jq --arg m "$EMBED_MODEL" '. + {model: $m}')
  CURL_ARGS+=(-d "$BODY")

  RESPONSE=$(curl "${CURL_ARGS[@]}")

  # Handle both OpenAI and ollama response formats
  EMBEDDING=$(echo "$RESPONSE" | jq -c '.data[0].embedding // .embeddings[0] // .embedding')
  DIMS=$(echo "$EMBEDDING" | jq 'length')
  VEC_TABLE="vec_memories_${DIMS}"

  # Ensure vec table exists for this dimension
  sqlite3 "$MEMDB" ".load $EXT_DIR/vec0" \
    "CREATE VIRTUAL TABLE IF NOT EXISTS ${VEC_TABLE} USING vec0(memory_id INTEGER, embedding FLOAT[$DIMS]);"

  # Insert embedding
  sqlite3 "$MEMDB" <<EOSQL
.load $EXT_DIR/vec0
INSERT INTO ${VEC_TABLE}(memory_id, embedding)
  VALUES ($MEMORY_ID, '$EMBEDDING');
INSERT OR IGNORE INTO embedding_meta(memory_id, model, dimensions, vec_table)
  VALUES ($MEMORY_ID, '${EMBED_MODEL:-remote}', $DIMS, '$VEC_TABLE');
EOSQL
fi
```

---

## Step 5: Retry on SQLITE_BUSY

WAL mode and `busy_timeout=5000` are set at DB init and handle most contention
automatically. For the rare case of a hard lock, retry once:

```bash
sqlite3 "$MEMDB" "INSERT ..." || { sleep 1; sqlite3 "$MEMDB" "INSERT ..."; }
```

---

## Step 6: Verify the write

```bash
sqlite3 "$MEMDB" \
  "SELECT id, agent, type, length(content), created_at
   FROM memories ORDER BY id DESC LIMIT 1;"
```

Expected output format: `<id>|<agent>|<type>|<bytes>|<timestamp>`

---

## Interface summary

| Parameter | Required | Values | Description |
|-----------|----------|--------|-------------|
| agent | yes | string | Agent name (e.g., `tech-lead`, `ic5`) |
| type | yes | `cortex`, `memory`, `lessons` | Memory type — must match CHECK constraint |
| content | yes | string | Text content to store |
| metadata | no | JSON object string | Arbitrary key-value metadata; defaults to `{}` |

---

## Design notes

- This skill handles BOTH the DB path and the `.md` fallback transparently. Always
  check `USE_DB` before choosing which path to take.
- SQL escaping is the agent's responsibility: every `'` in content must become `''`
  before string interpolation. Heredoc syntax sidesteps this for static content.
- `last_insert_rowid()` must be in the same sqlite3 session as the INSERT or it
  returns 0 (each `sqlite3` invocation is a separate connection).
- `lembed()` takes a **file path** to the GGUF model, not a model name string.
- For `remote` mode, set `embedding_url` in the config table and optionally export
  `EMBEDDING_API_KEY` and `EMBEDDING_MODEL`. The response parser handles both OpenAI
  (`data[0].embedding`) and ollama-style (`embeddings[0]` / `embedding`) shapes.
- The vec0 virtual tables (`vec_memories_384`, `vec_memories_768`) are created only
  when the sqlite-vec extension is loaded; they are absent from a plain `schema.sql`
  apply. Agents must guard all vec0 operations with an extension availability check.
