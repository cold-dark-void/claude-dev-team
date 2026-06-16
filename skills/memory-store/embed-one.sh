#!/usr/bin/env bash
# embed-one.sh — generate and store the embedding for one memory row (best-effort).
#
# Usage: bash embed-one.sh <db> <memory_id> <text>
#   <db>         absolute path to memory.db
#   <memory_id>  rowid of the memories row to embed (from last_insert_rowid())
#   <text>       the memory content to embed
#
# Self-derives every path from <db> (the memory dir is dirname <db>, so
# extensions live in <memdir>/extensions and the GGUF model in <memdir>/models),
# and reads embedding_mode / embedding_url from the DB's config table. Modes:
#   lembed  — sqlite-lembed + a local GGUF model (vec_memories_384)
#   remote  — any OpenAI-compatible provider (vec_memories_<dims>, dims inferred)
#
# Per-write embedding helper: called by skills/memory-store Step 4 and the agent
# memory-write protocol. migrate-md.sh is NOT a caller — its bulk-migration path
# inlines its own embedding logic (a separate implementation, not this one).
#
# Best-effort: ALWAYS exits 0. Embedding is optional — it MUST NEVER break the
# caller's write. Skips silently when mode=fallback, args/DB are missing, the
# extensions/models are absent, or the provider call fails (SPEC-004).

set -u

MEMDB="${1:-}"
MEMORY_ID="${2:-}"
CONTENT="${3:-}"

# Missing inputs, no DB, or no sqlite3 → nothing to do (best-effort, exit 0).
{ [ -z "$MEMDB" ] || [ -z "$MEMORY_ID" ] || [ -z "$CONTENT" ]; } && exit 0
# MEMORY_ID is interpolated raw into INSERT VALUES — it must be a bare rowid.
if ! [[ "$MEMORY_ID" =~ ^[0-9]+$ ]]; then
  echo "embed-one: invalid memory_id '$MEMORY_ID' (must be numeric); skipping embed." >&2
  exit 0
fi
[ -f "$MEMDB" ] || exit 0
command -v sqlite3 >/dev/null 2>&1 || exit 0

# Derive paths from the DB location: <memdir> = <MROOT>/.claude/memory.
MEM_DIR=$(cd "$(dirname "$MEMDB")" 2>/dev/null && pwd) || exit 0
EXT_DIR="$MEM_DIR/extensions"

EMBED_MODE=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='embedding_mode';" 2>/dev/null) || exit 0

# Determine platform extension suffix.
EXT_SUFFIX="so"
[ "$(uname -s)" = "Darwin" ] && EXT_SUFFIX="dylib"

# --- 4a. lembed mode (sqlite-lembed + local GGUF model) ---
if [ "$EMBED_MODE" = "lembed" ] && \
   [ -f "$EXT_DIR/vec0.$EXT_SUFFIX" ] && \
   [ -f "$EXT_DIR/lembed0.$EXT_SUFFIX" ]; then
  MODEL_PATH="$MEM_DIR/models/all-MiniLM-L6-v2.gguf"
  CONTENT_ESC=$(printf '%s' "$CONTENT" | sed "s/'/''/g")
  sqlite3 "$MEMDB" <<EOSQL 2>/dev/null || true
.load $EXT_DIR/vec0
.load $EXT_DIR/lembed0
INSERT INTO vec_memories_384(memory_id, embedding)
  VALUES ($MEMORY_ID, lembed('$MODEL_PATH', '$CONTENT_ESC'));
INSERT OR IGNORE INTO embedding_meta(memory_id, model, dimensions, vec_table)
  VALUES ($MEMORY_ID, 'all-MiniLM-L6-v2', 384, 'vec_memories_384');
UPDATE config SET value='384', updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE key='embedding_dimensions';
EOSQL

# --- 4b. remote mode (any OpenAI-compatible embedding provider) ---
elif [ "$EMBED_MODE" = "remote" ]; then
  EMBED_URL=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='embedding_url';" 2>/dev/null)
  [ -n "$EMBED_URL" ] || exit 0
  command -v curl >/dev/null 2>&1 || exit 0
  command -v jq   >/dev/null 2>&1 || exit 0
  EMBED_KEY="${EMBEDDING_API_KEY:-}"
  EMBED_MODEL="${EMBEDDING_MODEL:-}"

  # Build curl args — auth header via config file to avoid leaking in ps aux.
  CURL_ARGS=(-s "$EMBED_URL" -H "Content-Type: application/json")
  CURL_CONFIG=""
  if [ -n "$EMBED_KEY" ]; then
    CURL_CONFIG=$(mktemp "${TMPDIR:-/tmp}/curl-cfg.XXXXXX")
    printf 'header = "Authorization: Bearer %s"\n' "$EMBED_KEY" > "$CURL_CONFIG"
    chmod 600 "$CURL_CONFIG"
    CURL_ARGS+=(-K "$CURL_CONFIG")
  fi

  # Truncate content for embedding (most models have ~512 token limit).
  EMBED_TEXT=$(echo "$CONTENT" | head -c 1500)

  # Build request body.
  BODY="{\"input\":[$(echo "$EMBED_TEXT" | jq -Rs .)]}"
  [ -n "$EMBED_MODEL" ] && BODY=$(echo "$BODY" | jq --arg m "$EMBED_MODEL" '. + {model: $m}')
  CURL_ARGS+=(-d "$BODY")

  RESPONSE=$(curl "${CURL_ARGS[@]}")
  [ -n "$CURL_CONFIG" ] && rm -f "$CURL_CONFIG"

  # Handle both OpenAI (.data[0].embedding) and ollama (.embeddings[0]/.embedding) shapes.
  EMBEDDING=$(echo "$RESPONSE" | jq -c '.data[0].embedding // .embeddings[0] // .embedding' 2>/dev/null)
  { [ -z "$EMBEDDING" ] || [ "$EMBEDDING" = "null" ]; } && exit 0
  # $EMBEDDING is interpolated raw into INSERT VALUES — it must be a well-formed
  # numeric array. Reject anything outside digits . , e E + - space [ ] (network
  # trust boundary). ']' is first and '-' last so the bracket class is literal.
  if printf '%s' "$EMBEDDING" | grep -q '[^][0-9.,eE+ -]'; then
    echo "embed-one: embedding from endpoint is not a numeric vector; skipping embed." >&2
    exit 0
  fi
  DIMS=$(echo "$EMBEDDING" | jq 'length' 2>/dev/null)
  # $DIMS becomes a table identifier (vec_memories_<DIMS>) and a FLOAT[<DIMS>] size —
  # require a strict positive integer (mirrors migrate-md.sh's ^[0-9]+$ guard).
  if ! { [[ "$DIMS" =~ ^[0-9]+$ ]] && [ "$DIMS" -gt 0 ]; }; then
    echo "embed-one: invalid embedding dimensions '$DIMS'; skipping embed." >&2
    exit 0
  fi
  VEC_TABLE="vec_memories_${DIMS}"

  # Remote mode computes embeddings without lembed0, but vec0 is still REQUIRED to
  # store them. If vec0 is absent (e.g. --no-extensions), warn loudly-but-nonfatally
  # and skip the store — the memory write itself already succeeded; only the vector
  # is lost. (Do NOT silently swallow: a swallowed failure strands semantic search.)
  if [ ! -f "$EXT_DIR/vec0.$EXT_SUFFIX" ]; then
    echo "embed-one: vec0 extension unavailable — remote embedding computed but NOT stored; install extensions to enable semantic search." >&2
    exit 0
  fi

  # Ensure vec table exists for this dimension.
  sqlite3 "$MEMDB" ".load $EXT_DIR/vec0" \
    "CREATE VIRTUAL TABLE IF NOT EXISTS ${VEC_TABLE} USING vec0(memory_id INTEGER, embedding FLOAT[$DIMS]);" 2>/dev/null || true

  # Insert embedding. Warn (don't swallow) if the vec store fails despite vec0.
  sqlite3 "$MEMDB" <<EOSQL 2>/dev/null || echo "embed-one: vec store failed — remote embedding computed but NOT stored for memory $MEMORY_ID." >&2
.load $EXT_DIR/vec0
INSERT INTO ${VEC_TABLE}(memory_id, embedding)
  VALUES ($MEMORY_ID, '$EMBEDDING');
INSERT OR IGNORE INTO embedding_meta(memory_id, model, dimensions, vec_table)
  VALUES ($MEMORY_ID, '${EMBED_MODEL:-remote}', $DIMS, '$VEC_TABLE');
UPDATE config SET value='$DIMS', updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE key='embedding_dimensions';
EOSQL
fi

exit 0
