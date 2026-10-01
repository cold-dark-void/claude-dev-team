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
# has its own embedding loop (a separate implementation, not this one). Both source
# embed-common.sh (lembed model registration, .errors.log writer).
#
# Best-effort: ALWAYS exits 0. Embedding is optional — it MUST NEVER break the
# caller's write. Skips silently when mode=fallback or the args/DB are missing
# (SPEC-004). A failed embed in lembed or remote mode (missing extension or
# model, sqlite error, provider error) is NOT silent: one line is appended to
# <memdir>/.errors.log and counted by /memory stats and /doctor (CDT-262).
# Callers usually send this script's stderr to /dev/null, so the log is the
# durable channel.
#
# lembed takes a REGISTERED MODEL NAME, not a file path: the GGUF is registered
# on the same sqlite3 connection, before the lembed() call (see embed-common.sh).

set -u

_VEC_COSINE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vec-cosine.sh
# shellcheck disable=SC1090
. "$_VEC_COSINE"

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

# Shared lembed helpers (registration statement, error log) live next to this file.
EMBED_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || EMBED_DIR=""
if [ -z "$EMBED_DIR" ] || [ ! -f "$EMBED_DIR/embed-common.sh" ]; then
  echo "embed-one: embed-common.sh not found next to embed-one.sh; skipping embed." >&2
  exit 0
fi
# shellcheck source=embed-common.sh
. "$EMBED_DIR/embed-common.sh"

# Derive paths from the DB location: <memdir> = <MROOT>/.claude/memory.
MEM_DIR=$(cd "$(dirname "$MEMDB")" 2>/dev/null && pwd) || exit 0
EXT_DIR="$MEM_DIR/extensions"

# A failed embed: say so on stderr AND append it to <memdir>/.errors.log.
embed_fail() {
  echo "embed-one: $1" >&2
  embed_log_error "$MEM_DIR" embed-one "memory $MEMORY_ID: $1"
}

EMBED_MODE=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT value FROM config WHERE key='embedding_mode';" 2>/dev/null) || exit 0

# Determine platform extension suffix.
EXT_SUFFIX="so"
[ "$(uname -s)" = "Darwin" ] && EXT_SUFFIX="dylib"

# --- 4a. lembed mode (sqlite-lembed + local GGUF model) ---
if [ "$EMBED_MODE" = "lembed" ]; then
  MODEL_PATH="$MEM_DIR/models/all-MiniLM-L6-v2.gguf"
  MISSING=""
  [ -f "$EXT_DIR/vec0.$EXT_SUFFIX" ] || MISSING="vec0.$EXT_SUFFIX"
  [ -f "$EXT_DIR/lembed0.$EXT_SUFFIX" ] || MISSING="${MISSING:+$MISSING, }lembed0.$EXT_SUFFIX"
  [ -f "$MODEL_PATH" ] || MISSING="${MISSING:+$MISSING, }models/all-MiniLM-L6-v2.gguf"
  if [ -n "$MISSING" ]; then
    embed_fail "embedding_mode=lembed but missing: $MISSING; run /setup team --refresh."
    exit 0
  fi
  CONTENT_ESC=$(printf '%s' "$CONTENT" | sed "s/'/''/g")
  vec_repair_db "$MEMDB" "$EXT_DIR/vec0.$EXT_SUFFIX" || true
  VEC_SQL=$(vec_create_sql vec_memories_384 384 1) || { embed_fail "cannot build the vec0 cosine create."; exit 0; }
  REGISTER_SQL=$(embed_lembed_register_sql "$MODEL_PATH") || { embed_fail "cannot build the lembed model registration."; exit 0; }
  # -bail: stop at the first failing statement, so a failed registration never
  # lets the vector INSERT run. temp.lembed_models is per connection, so the
  # registration shares this batch with the lembed() call (embed-common.sh).
  emit_lembed_sql() {
    cat <<EOSQL
.load $EXT_DIR/vec0
.load $EXT_DIR/lembed0
$VEC_SQL
$REGISTER_SQL
INSERT INTO vec_memories_384(memory_id, embedding)
  VALUES ($MEMORY_ID, lembed('$EMBED_LEMBED_NAME', '$CONTENT_ESC'));
INSERT OR IGNORE INTO embedding_meta(memory_id, model, dimensions, vec_table)
  VALUES ($MEMORY_ID, 'all-MiniLM-L6-v2', 384, 'vec_memories_384');
UPDATE config SET value='384', updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE key='embedding_dimensions';
EOSQL
  }
  LEMBED_RC=0
  LEMBED_ERR=$(emit_lembed_sql | sqlite3 -cmd ".timeout 5000" -bail "$MEMDB" 2>&1) || LEMBED_RC=$?
  if [ "$LEMBED_RC" -ne 0 ]; then
    embed_fail "lembed embed failed (sqlite3 exit $LEMBED_RC): ${LEMBED_ERR:-no error text}"
  fi

# --- 4b. remote mode (any OpenAI-compatible embedding provider) ---
elif [ "$EMBED_MODE" = "remote" ]; then
  EMBED_URL=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT value FROM config WHERE key='embedding_url';" 2>/dev/null)
  [ -n "$EMBED_URL" ] || exit 0
  command -v curl >/dev/null 2>&1 || exit 0
  command -v jq   >/dev/null 2>&1 || exit 0
  EMBED_KEY="${EMBEDDING_API_KEY:-}"
  # Env overrides DB; DB is the durable source when env is unset (local ollama, etc.).
  EMBED_MODEL="${EMBEDDING_MODEL:-$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT value FROM config WHERE key='embedding_model';" 2>/dev/null)}"


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
  if [ -z "$EMBEDDING" ] || [ "$EMBEDDING" = "null" ]; then
    embed_fail "remote endpoint returned no embedding vector; skipping embed."
    exit 0
  fi
  # $EMBEDDING is interpolated raw into INSERT VALUES — it must be a well-formed
  # numeric array. Reject anything outside digits . , e E + - space [ ] (network
  # trust boundary). ']' is first and '-' last so the bracket class is literal.
  if printf '%s' "$EMBEDDING" | grep -q '[^][0-9.,eE+ -]'; then
    embed_fail "embedding from endpoint is not a numeric vector; skipping embed."
    exit 0
  fi
  DIMS=$(echo "$EMBEDDING" | jq 'length' 2>/dev/null)
  # $DIMS becomes a table identifier (vec_memories_<DIMS>) and a FLOAT[<DIMS>] size —
  # require a strict positive integer (mirrors migrate-md.sh's ^[0-9]+$ guard).
  if ! { [[ "$DIMS" =~ ^[0-9]+$ ]] && [ "$DIMS" -gt 0 ]; }; then
    embed_fail "invalid embedding dimensions '$DIMS'; skipping embed."
    exit 0
  fi
  VEC_TABLE="vec_memories_${DIMS}"

  # Remote mode computes embeddings without lembed0, but vec0 is still REQUIRED to
  # store them. If vec0 is absent (e.g. --no-extensions), warn loudly-but-nonfatally
  # and skip the store — the memory write itself already succeeded; only the vector
  # is lost. (Do NOT silently swallow: a swallowed failure strands semantic search.)
  if [ ! -f "$EXT_DIR/vec0.$EXT_SUFFIX" ]; then
    embed_fail "vec0 extension unavailable — remote embedding computed but NOT stored; install extensions to enable semantic search."
    exit 0
  fi

  # Ensure vec table exists for this dimension, using cosine distance.
  vec_repair_db "$MEMDB" "$EXT_DIR/vec0.$EXT_SUFFIX" || true
  VEC_SQL=$(vec_create_sql "$VEC_TABLE" "$DIMS" 1) || true
  if [ -n "${VEC_SQL:-}" ]; then
    sqlite3 -cmd ".timeout 5000" "$MEMDB" ".load $EXT_DIR/vec0" "$VEC_SQL" 2>/dev/null || true
  fi

  # Insert embedding. sqlite3 aborts the remainder of a multi-statement batch on a
  # parse error, so a failure here may be partial (e.g. the vec row already committed).
  EMBED_MODEL_ESC=$(printf '%s' "${EMBED_MODEL:-remote}" | sed "s/'/''/g")
  emit_remote_sql() {
    cat <<EOSQL
.load $EXT_DIR/vec0
INSERT INTO ${VEC_TABLE}(memory_id, embedding)
  VALUES ($MEMORY_ID, '$EMBEDDING');
INSERT OR IGNORE INTO embedding_meta(memory_id, model, dimensions, vec_table)
  VALUES ($MEMORY_ID, '$EMBED_MODEL_ESC', $DIMS, '$VEC_TABLE');
UPDATE config SET value='$DIMS', updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE key='embedding_dimensions';
EOSQL
  }
  REMOTE_RC=0
  REMOTE_ERR=$(emit_remote_sql | sqlite3 -cmd ".timeout 5000" "$MEMDB" 2>&1) || REMOTE_RC=$?
  if [ "$REMOTE_RC" -ne 0 ]; then
    embed_fail "sqlite write batch failed — vector and/or its embedding_meta row may be missing; semantic search may be incomplete. sqlite3 said: ${REMOTE_ERR:-no error text}"
  fi
fi

exit 0
