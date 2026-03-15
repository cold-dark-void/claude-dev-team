---
name: memory-store
description: Write agent memories to the SQLite database (or fall back to .md files). Handles
  DB detection, SQL-safe INSERT/UPDATE, optional embedding generation (lembed or ollama),
  and retry on SQLITE_BUSY. Usage: read this file to learn the protocol, then execute
  the relevant bash blocks.
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

Replace `<AGENT>`, `<TYPE>`, `<CONTENT_ESCAPED>`, and `<METADATA_JSON>` with real values.
`<TYPE>` must be one of: `cortex`, `memory`, `lessons`.

**Single-line insert:**
```bash
sqlite3 "$MEMDB" "INSERT INTO memories(agent, type, content, metadata_json)
  VALUES ('<AGENT>', '<TYPE>', '<CONTENT_ESCAPED>', '<METADATA_JSON>');"
```

**Update existing record for agent + type:**
```bash
sqlite3 "$MEMDB" "UPDATE memories SET content='<CONTENT_ESCAPED>',
  updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
  WHERE agent='<AGENT>' AND type='<TYPE>';"
```

**IMPORTANT — SQL escaping:** Content that contains single quotes MUST have each `'`
doubled to `''` before interpolation into the SQL string. Failure to do so will corrupt
the statement. Use a heredoc for multi-line content to avoid shell quoting issues:

```bash
sqlite3 "$MEMDB" <<'EOSQL'
INSERT INTO memories(agent, type, content) VALUES (
  'tech-lead',
  'cortex',
  'Architecture overview:
  - This is a Claude Code plugin
  - Uses markdown/JSON, no build step
  - Skills live in skills/<name>/SKILL.md
  ...'
);
EOSQL
```

**Capture the new row ID in the same session** (needed for embedding — see Step 4):
```bash
MEMORY_ID=$(sqlite3 "$MEMDB" "INSERT INTO memories(agent, type, content, metadata_json)
  VALUES ('<AGENT>', '<TYPE>', '<CONTENT_ESCAPED>', '<METADATA_JSON>');
  SELECT last_insert_rowid();")
```

> Note: `last_insert_rowid()` MUST be called within the same sqlite3 session as the
> INSERT. A separate `sqlite3 "$MEMDB" "SELECT last_insert_rowid();"` call will return
> 0 because each invocation is an independent connection.

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

### 4b. ollama mode (local Ollama server)

Use the `/api/embed` endpoint (not `/api/embeddings` — that is the deprecated path).
Dimensions are inferred from the response so this works with any model.

```bash
if [ "$EMBED_MODE" = "ollama" ]; then
  OLLAMA_MODEL=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='embedding_model';")

  EMBEDDING=$(curl -s http://localhost:11434/api/embed \
    -d "{\"model\":\"$OLLAMA_MODEL\",\"input\":[$(echo '<CONTENT>' | jq -Rs .)]}" \
    | jq -c '.embeddings[0]')

  DIMS=$(echo "$EMBEDDING" | jq 'length')
  VEC_TABLE="vec_memories_${DIMS}"

  sqlite3 "$MEMDB" <<EOSQL
.load $EXT_DIR/vec0
INSERT INTO ${VEC_TABLE}(memory_id, embedding)
  VALUES ($MEMORY_ID, '$EMBEDDING');
INSERT OR IGNORE INTO embedding_meta(memory_id, model, dimensions, vec_table)
  VALUES ($MEMORY_ID, '$OLLAMA_MODEL', $DIMS, '$VEC_TABLE');
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
- For ollama, call `/api/embed` — `/api/embeddings` is deprecated.
- The vec0 virtual tables (`vec_memories_384`, `vec_memories_768`) are created only
  when the sqlite-vec extension is loaded; they are absent from a plain `schema.sql`
  apply. Agents must guard all vec0 operations with an extension availability check.
