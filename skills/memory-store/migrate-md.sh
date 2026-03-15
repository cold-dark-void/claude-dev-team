#!/usr/bin/env bash
set -euo pipefail

# Usage: migrate-md.sh <MROOT>
# Where MROOT is the project root (resolved via git-common-dir)
#
# Migrates existing .md memory files (cortex, memory, lessons) from
# .claude/memory/<agent>/ into the SQLite memories table.
# Files are chunked by ## sections — each section becomes its own row
# for better embedding quality and semantic search granularity.
# context.md files are intentionally skipped — they remain as .md per-worktree.

MROOT="${1:?Usage: migrate-md.sh <project-root>}"
MEMDB="$MROOT/.claude/memory/memory.db"
MEMDIR="$MROOT/.claude/memory"

# Verify DB exists
if [ ! -f "$MEMDB" ]; then
  echo "ERROR: memory.db not found at $MEMDB"
  echo "Run /init-team first to create the database."
  exit 1
fi

# Counters
TOTAL_FILES=0
TOTAL_CHUNKS=0
MIGRATED=0
SKIPPED=0
FAILED=0
DELETED=0

# Track successfully migrated files for cleanup
MIGRATED_FILES=()

echo "Scanning $MEMDIR for .md memory files..."
echo ""

# Find all agent subdirectory .md files matching cortex/memory/lessons
while IFS= read -r FILE; do
  AGENT=$(basename "$(dirname "$FILE")")
  TYPE=$(basename "$FILE" .md)

  # Skip context.md
  [ "$TYPE" = "context" ] && continue

  # Only migrate known types
  [[ "$TYPE" != "cortex" && "$TYPE" != "memory" && "$TYPE" != "lessons" ]] && continue

  # Skip .md files that are directly in $MEMDIR (not inside an agent subdir)
  [ "$(dirname "$FILE")" = "$MEMDIR" ] && continue

  TOTAL_FILES=$((TOTAL_FILES + 1))

  # Idempotent: skip if this agent+type already has rows
  EXISTING=$(sqlite3 "$MEMDB" "SELECT COUNT(*) FROM memories WHERE agent='$AGENT' AND type='$TYPE';")
  if [ "$EXISTING" -gt 0 ]; then
    echo "  SKIP: $AGENT/$TYPE.md ($EXISTING chunks already in DB)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  echo "Processing: $AGENT/$TYPE.md"

  # Read file and chunk by ## headers (or double-newline for files without headers)
  # Each chunk becomes its own row for better embedding granularity
  CONTENT=$(cat "$FILE")
  FILE_FAILED=false

  # Split on ## headers. If no headers, split on double-newlines. If neither, use whole file.
  if echo "$CONTENT" | grep -q '^## '; then
    # Split by ## headers — each section is a chunk
    CHUNK=""
    CHUNK_NUM=0
    while IFS= read -r LINE; do
      if echo "$LINE" | grep -q '^## ' && [ -n "$CHUNK" ]; then
        # Save previous chunk
        CHUNK_TRIMMED=$(echo "$CHUNK" | sed '/^$/d' | sed '/^#/d' | head -c 5000)
        if [ ${#CHUNK_TRIMMED} -gt 20 ]; then
          ESCAPED=$(printf '%s' "$CHUNK_TRIMMED" | sed "s/'/''/g")
          if sqlite3 "$MEMDB" "INSERT INTO memories(agent, type, content) VALUES ('$AGENT', '$TYPE', '$ESCAPED');"; then
            CHUNK_NUM=$((CHUNK_NUM + 1))
          else
            FILE_FAILED=true
          fi
        fi
        CHUNK="$LINE"
      else
        CHUNK="${CHUNK}
${LINE}"
      fi
    done <<< "$CONTENT"
    # Save last chunk
    if [ -n "$CHUNK" ]; then
      CHUNK_TRIMMED=$(echo "$CHUNK" | sed '/^$/d' | sed '/^#/d' | head -c 5000)
      if [ ${#CHUNK_TRIMMED} -gt 20 ]; then
        ESCAPED=$(printf '%s' "$CHUNK_TRIMMED" | sed "s/'/''/g")
        if sqlite3 "$MEMDB" "INSERT INTO memories(agent, type, content) VALUES ('$AGENT', '$TYPE', '$ESCAPED');"; then
          CHUNK_NUM=$((CHUNK_NUM + 1))
        else
          FILE_FAILED=true
        fi
      fi
    fi
    echo "  OK: $CHUNK_NUM chunks from $AGENT/$TYPE"
    TOTAL_CHUNKS=$((TOTAL_CHUNKS + CHUNK_NUM))
  else
    # No ## headers — insert whole file as one chunk (capped at 5000 chars)
    CONTENT_TRIMMED=$(printf '%s' "$CONTENT" | head -c 5000)
    ESCAPED=$(printf '%s' "$CONTENT_TRIMMED" | sed "s/'/''/g")
    if sqlite3 "$MEMDB" "INSERT INTO memories(agent, type, content) VALUES ('$AGENT', '$TYPE', '$ESCAPED');"; then
      echo "  OK: 1 chunk (no sections) from $AGENT/$TYPE"
      TOTAL_CHUNKS=$((TOTAL_CHUNKS + 1))
    else
      FILE_FAILED=true
    fi
  fi

  if [ "$FILE_FAILED" = true ]; then
    echo "  ERROR: failed to insert some chunks for $AGENT/$TYPE"
    FAILED=$((FAILED + 1))
  else
    MIGRATED=$((MIGRATED + 1))
    MIGRATED_FILES+=("$FILE")
  fi
done < <(find "$MEMDIR" -mindepth 2 -maxdepth 2 -name "*.md" | sort)

# Generate embeddings for all unembedded memories
EMBED_MODE=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='embedding_mode';" 2>/dev/null || echo "fallback")
EXT_DIR="$MROOT/.claude/memory/extensions"
MODEL_DIR="$MROOT/.claude/memory/models"

EXT_SUFFIX="so"
[ "$(uname -s)" = "Darwin" ] && EXT_SUFFIX="dylib"

if [ "$EMBED_MODE" != "fallback" ] && [ "$EMBED_MODE" != "none" ]; then
  UNEMBEDDED=$(sqlite3 "$MEMDB" "SELECT COUNT(*) FROM memories m LEFT JOIN embedding_meta em ON em.memory_id = m.id WHERE em.memory_id IS NULL;")

  if [ "$UNEMBEDDED" -gt 0 ]; then
    echo ""
    echo "Embedding $UNEMBEDDED chunks (mode: $EMBED_MODE)..."
    EMBEDDED_COUNT=0

    # Read embedding URL/model once (not per-row)
    EMBED_URL=""
    EMBED_KEY="${EMBEDDING_API_KEY:-}"
    EMBED_MODEL="${EMBEDDING_MODEL:-}"
    if [ "$EMBED_MODE" = "remote" ]; then
      EMBED_URL=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='embedding_url';" 2>/dev/null)
    fi

    while read -r MEM_ID; do
      # Fetch content — truncate to 1000 chars for embedding (safe for most models)
      MEM_CONTENT=$(sqlite3 "$MEMDB" "SELECT substr(content, 1, 1000) FROM memories WHERE id=$MEM_ID;")
      [ -z "$MEM_CONTENT" ] && continue

      JSON_CONTENT=$(printf '%s' "$MEM_CONTENT" | jq -Rs .)

      if [ "$EMBED_MODE" = "remote" ] && [ -n "$EMBED_URL" ]; then
        CURL_ARGS=(-s "$EMBED_URL" -H "Content-Type: application/json")
        [ -n "$EMBED_KEY" ] && CURL_ARGS+=(-H "Authorization: Bearer $EMBED_KEY")

        BODY="{\"input\":[$JSON_CONTENT]}"
        [ -n "$EMBED_MODEL" ] && BODY=$(printf '%s' "$BODY" | jq --arg m "$EMBED_MODEL" '. + {model: $m}')
        CURL_ARGS+=(-d "$BODY")

        RESPONSE=$(curl "${CURL_ARGS[@]}" 2>/dev/null) || { echo "  WARN: curl failed for chunk $MEM_ID"; continue; }
        EMBEDDING=$(printf '%s' "$RESPONSE" | jq -c '.data[0].embedding // .embeddings[0] // .embedding' 2>/dev/null)

      elif [ "$EMBED_MODE" = "lembed" ] && [ -f "$EXT_DIR/lembed0.$EXT_SUFFIX" ]; then
        MODEL_PATH="$MODEL_DIR/all-MiniLM-L6-v2.gguf"
        ESCAPED_SQL=$(printf '%s' "$MEM_CONTENT" | sed "s/'/''/g")
        EMBEDDING=$(sqlite3 "$MEMDB" ".load $EXT_DIR/vec0" ".load $EXT_DIR/lembed0" \
          "SELECT json(lembed('$MODEL_PATH', '$ESCAPED_SQL'));" 2>/dev/null) || { echo "  WARN: lembed failed for chunk $MEM_ID"; continue; }
      else
        break
      fi

      # Validate
      [ -z "$EMBEDDING" ] || [ "$EMBEDDING" = "null" ] && { echo "  WARN: empty embedding for chunk $MEM_ID"; continue; }
      DIMS=$(printf '%s' "$EMBEDDING" | jq 'length' 2>/dev/null)
      [ -z "$DIMS" ] || [ "$DIMS" = "0" ] || [ "$DIMS" = "null" ] && continue

      VEC_TABLE="vec_memories_${DIMS}"

      # Ensure vec table exists with correct schema
      # Drop and recreate if columns don't match (handles legacy tables)
      HAS_MEMORY_ID=$(sqlite3 "$MEMDB" ".load $EXT_DIR/vec0" "PRAGMA table_info($VEC_TABLE);" 2>/dev/null | grep -c "memory_id" || true)
      if [ "$HAS_MEMORY_ID" = "0" ]; then
        sqlite3 "$MEMDB" ".load $EXT_DIR/vec0" \
          "DROP TABLE IF EXISTS $VEC_TABLE;" \
          "CREATE VIRTUAL TABLE $VEC_TABLE USING vec0(memory_id INTEGER, embedding FLOAT[$DIMS]);" 2>/dev/null
      else
        sqlite3 "$MEMDB" ".load $EXT_DIR/vec0" \
          "CREATE VIRTUAL TABLE IF NOT EXISTS $VEC_TABLE USING vec0(memory_id INTEGER, embedding FLOAT[$DIMS]);" 2>/dev/null
      fi

      # Insert embedding
      sqlite3 "$MEMDB" ".load $EXT_DIR/vec0" \
        "INSERT INTO ${VEC_TABLE}(memory_id, embedding) VALUES ($MEM_ID, '$EMBEDDING');" \
        "INSERT OR IGNORE INTO embedding_meta(memory_id, model, dimensions, vec_table) VALUES ($MEM_ID, '${EMBED_MODEL:-all-MiniLM-L6-v2}', $DIMS, '$VEC_TABLE');" \
        2>/dev/null || { echo "  WARN: vec insert failed for chunk $MEM_ID"; continue; }

      EMBEDDED_COUNT=$((EMBEDDED_COUNT + 1))
    done < <(sqlite3 "$MEMDB" "SELECT m.id FROM memories m LEFT JOIN embedding_meta em ON em.memory_id = m.id WHERE em.memory_id IS NULL;" 2>/dev/null)

    echo "  Embedded: $EMBEDDED_COUNT/$UNEMBEDDED chunks"

    # Update dimensions in config
    if [ -n "${DIMS:-}" ] && [ "${DIMS:-0}" != "0" ] && [ "${DIMS:-null}" != "null" ]; then
      sqlite3 "$MEMDB" "UPDATE config SET value='$DIMS', updated_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE key='embedding_dimensions';"
    fi
  fi
fi

# Validation
TOTAL_ROWS=$(sqlite3 "$MEMDB" "SELECT COUNT(*) FROM memories;")
echo ""
echo "Validation: $TOTAL_ROWS total rows in memories table"

# Delete originals only if all inserts succeeded
if [ "$FAILED" -eq 0 ] && [ "${#MIGRATED_FILES[@]}" -gt 0 ]; then
  echo ""
  echo "Deleting migrated source files..."
  for FILE in "${MIGRATED_FILES[@]}"; do
    if rm "$FILE"; then
      DELETED=$((DELETED + 1))
    else
      echo "  WARNING: Could not delete $FILE"
    fi
  done
  echo "  Deleted $DELETED files"
elif [ "$FAILED" -gt 0 ]; then
  echo ""
  echo "WARNING: $FAILED file(s) failed to migrate. Originals preserved."
fi

echo ""
echo "=== Migration Summary ==="
echo "Files found:    $TOTAL_FILES"
echo "Chunks created: $TOTAL_CHUNKS"
echo "Files migrated: $MIGRATED"
echo "Skipped (dupe): $SKIPPED"
echo "Failed:         $FAILED"
echo "Deleted:        $DELETED"
echo "========================="

[ "$FAILED" -gt 0 ] && exit 1
exit 0
