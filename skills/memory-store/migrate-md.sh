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
  EXISTING=$(python3 -c "
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
print(db.execute('SELECT COUNT(*) FROM memories WHERE agent=? AND type=?', (sys.argv[2], sys.argv[3])).fetchone()[0])
" "$MEMDB" "$AGENT" "$TYPE")
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
  FILE_INSERTED=0
  FILE_SKIPPED=0   # non-empty content below the insert floor (fail-closed)
  FILE_CONSIDERED=0

  # Insert one chunk; updates FILE_INSERTED / FILE_FAILED. Args: content string.
  # Length floor: skip (count) non-empty chunks ≤20 chars so short noise does not
  # become rows — but those skips MUST block source deletion (data-loss guard).
  _migrate_chunk() {
    local chunk_trimmed="$1"
    FILE_CONSIDERED=$((FILE_CONSIDERED + 1))
    if [ -z "$chunk_trimmed" ]; then
      return 0
    fi
    if [ ${#chunk_trimmed} -le 20 ]; then
      FILE_SKIPPED=$((FILE_SKIPPED + 1))
      echo "  WARN: skipped short chunk (${#chunk_trimmed} chars ≤20) for $AGENT/$TYPE — source will be preserved"
      return 0
    fi
    if python3 -c "
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute('PRAGMA busy_timeout=5000')
db.execute('INSERT INTO memories(agent, type, content) VALUES (?, ?, ?)', (sys.argv[2], sys.argv[3], sys.argv[4]))
db.commit()
" "$MEMDB" "$AGENT" "$TYPE" "$chunk_trimmed"; then
      FILE_INSERTED=$((FILE_INSERTED + 1))
    else
      FILE_FAILED=true
    fi
  }

  # Split on ## headers. If no headers, use whole file as one chunk.
  if echo "$CONTENT" | grep -q '^## '; then
    # Split by ## headers — each section is a chunk
    CHUNK=""
    while IFS= read -r LINE; do
      if echo "$LINE" | grep -q '^## ' && [ -n "$CHUNK" ]; then
        CHUNK_TRIMMED=$(echo "$CHUNK" | sed '/^$/d' | sed '/^#/d' | head -c 8000)
        _migrate_chunk "$CHUNK_TRIMMED"
        CHUNK="$LINE"
      else
        CHUNK="${CHUNK}
${LINE}"
      fi
    done <<< "$CONTENT"
    # Save last chunk
    if [ -n "$CHUNK" ]; then
      CHUNK_TRIMMED=$(echo "$CHUNK" | sed '/^$/d' | sed '/^#/d' | head -c 8000)
      _migrate_chunk "$CHUNK_TRIMMED"
    fi
    echo "  OK: $FILE_INSERTED inserted / $FILE_CONSIDERED considered ($FILE_SKIPPED short-skipped) from $AGENT/$TYPE"
    TOTAL_CHUNKS=$((TOTAL_CHUNKS + FILE_INSERTED))
  else
    # No ## headers — insert whole file as one chunk (capped at 5000 chars)
    CONTENT_TRIMMED=$(printf '%s' "$CONTENT" | head -c 5000)
    FILE_CONSIDERED=1
    if [ -z "$CONTENT_TRIMMED" ]; then
      FILE_SKIPPED=$((FILE_SKIPPED + 1))
      echo "  WARN: empty content for $AGENT/$TYPE — source will be preserved"
    elif python3 -c "
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute('PRAGMA busy_timeout=5000')
db.execute('INSERT INTO memories(agent, type, content) VALUES (?, ?, ?)', (sys.argv[2], sys.argv[3], sys.argv[4]))
db.commit()
" "$MEMDB" "$AGENT" "$TYPE" "$CONTENT_TRIMMED"; then
      FILE_INSERTED=1
      echo "  OK: 1 chunk (no sections) from $AGENT/$TYPE"
      TOTAL_CHUNKS=$((TOTAL_CHUNKS + 1))
    else
      FILE_FAILED=true
    fi
  fi

  # Fail-closed deletion gate (per file):
  # - insert errors → FAILED, keep source
  # - zero rows inserted → FAILED, keep source (never delete on empty migration)
  # - any short-skipped non-empty content → FAILED, keep source (partial loss risk)
  # - only full success (inserted > 0 && skipped == 0 && !failed) may delete
  if [ "$FILE_FAILED" = true ]; then
    echo "  ERROR: failed to insert some chunks for $AGENT/$TYPE"
    FAILED=$((FAILED + 1))
  elif [ "$FILE_INSERTED" -eq 0 ]; then
    echo "  ERROR: zero rows inserted for $AGENT/$TYPE (considered=$FILE_CONSIDERED, short-skipped=$FILE_SKIPPED) — source preserved"
    FAILED=$((FAILED + 1))
  elif [ "$FILE_SKIPPED" -gt 0 ]; then
    echo "  ERROR: $FILE_SKIPPED chunk(s) with non-empty content were skipped for $AGENT/$TYPE — source preserved (fail-closed)"
    FAILED=$((FAILED + 1))
  else
    MIGRATED=$((MIGRATED + 1))
    MIGRATED_FILES+=("$FILE")
  fi
done < <(find "$MEMDIR" -mindepth 2 -maxdepth 2 -name "*.md" | sort)

# Generate embeddings for all unembedded memories
EMBED_MODE=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT value FROM config WHERE key='embedding_mode';" 2>/dev/null || echo "fallback")
EXT_DIR="$MROOT/.claude/memory/extensions"
MODEL_DIR="$MROOT/.claude/memory/models"

EXT_SUFFIX="so"
[ "$(uname -s)" = "Darwin" ] && EXT_SUFFIX="dylib"

if [ "$EMBED_MODE" != "fallback" ] && [ "$EMBED_MODE" != "none" ]; then
  UNEMBEDDED=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT COUNT(*) FROM memories m LEFT JOIN embedding_meta em ON em.memory_id = m.id WHERE em.memory_id IS NULL;")

  if [ "$UNEMBEDDED" -gt 0 ]; then
    echo ""
    echo "Embedding $UNEMBEDDED chunks (mode: $EMBED_MODE)..."
    EMBEDDED_COUNT=0

    # Read embedding URL/model once (not per-row)
    EMBED_URL=""
    EMBED_KEY="${EMBEDDING_API_KEY:-}"
    EMBED_MODEL="${EMBEDDING_MODEL:-}"
    if [ "$EMBED_MODE" = "remote" ]; then
      EMBED_URL=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT value FROM config WHERE key='embedding_url';" 2>/dev/null)
    fi

    while read -r MEM_ID; do
      # Validate MEM_ID is numeric (defense in depth)
      [[ "$MEM_ID" =~ ^[0-9]+$ ]] || continue
      # Fetch content — truncate to 1500 chars for embedding (matches embed-one.sh)
      MEM_CONTENT=$(sqlite3 "$MEMDB" "SELECT substr(content, 1, 1500) FROM memories WHERE id=$MEM_ID;")
      [ -z "$MEM_CONTENT" ] && continue

      JSON_CONTENT=$(printf '%s' "$MEM_CONTENT" | jq -Rs .)

      if [ "$EMBED_MODE" = "remote" ] && [ -n "$EMBED_URL" ]; then
        CURL_ARGS=(-s "$EMBED_URL" -H "Content-Type: application/json")

        # Pass auth header via config file to avoid leaking token in ps aux
        CURL_CONFIG=""
        if [ -n "$EMBED_KEY" ]; then
          CURL_CONFIG=$(mktemp "${TMPDIR:-/tmp}/curl-cfg.XXXXXX")
          printf 'header = "Authorization: Bearer %s"\n' "$EMBED_KEY" > "$CURL_CONFIG"
          chmod 600 "$CURL_CONFIG"
          CURL_ARGS+=(-K "$CURL_CONFIG")
        fi

        BODY="{\"input\":[$JSON_CONTENT]}"
        [ -n "$EMBED_MODEL" ] && BODY=$(printf '%s' "$BODY" | jq --arg m "$EMBED_MODEL" '. + {model: $m}')
        CURL_ARGS+=(-d "$BODY")

        RESPONSE=$(curl "${CURL_ARGS[@]}" 2>/dev/null) || { [ -n "$CURL_CONFIG" ] && rm -f "$CURL_CONFIG"; echo "  WARN: curl failed for chunk $MEM_ID"; continue; }
        [ -n "$CURL_CONFIG" ] && rm -f "$CURL_CONFIG"
        EMBEDDING=$(printf '%s' "$RESPONSE" | jq -c '.data[0].embedding // .embeddings[0] // .embedding' 2>/dev/null)
        # $EMBEDDING is interpolated raw into INSERT VALUES — it must be a well-formed
        # numeric array. Reject anything outside digits . , e E + - space [ ] (network
        # trust boundary). ']' is first and '-' last so the bracket class is literal.
        # Per-row best-effort: skip this chunk's embedding, don't abort the migration.
        if printf '%s' "$EMBEDDING" | grep -q '[^][0-9.,eE+ -]'; then
          echo "  WARN: embedding from endpoint is not a numeric vector for chunk $MEM_ID; skipping" >&2
          continue
        fi

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
      [[ "$DIMS" =~ ^[0-9]+$ ]] || continue

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
    done < <(sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT m.id FROM memories m LEFT JOIN embedding_meta em ON em.memory_id = m.id WHERE em.memory_id IS NULL;" 2>/dev/null)

    echo "  Embedded: $EMBEDDED_COUNT/$UNEMBEDDED chunks"

    # Update dimensions in config
    if [ -n "${DIMS:-}" ] && [ "${DIMS:-0}" != "0" ] && [ "${DIMS:-null}" != "null" ]; then
      python3 -c "
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute('PRAGMA busy_timeout=5000')
db.execute('UPDATE config SET value=?, updated_at=strftime(\'%Y-%m-%dT%H:%M:%SZ\',\'now\') WHERE key=?', (sys.argv[2], 'embedding_dimensions'))
db.commit()
" "$MEMDB" "$DIMS"
    fi
  fi
fi

# Validation
TOTAL_ROWS=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT COUNT(*) FROM memories;")
echo ""
echo "Validation: $TOTAL_ROWS total rows in memories table"

# Delete only fully-successful files (per-file fail-closed: MIGRATED_FILES never
# includes zero-row or short-skipped sources). Partial batch failures keep those
# originals but still clean up files that fully migrated.
if [ "${#MIGRATED_FILES[@]}" -gt 0 ]; then
  echo ""
  echo "Deleting fully-migrated source files..."
  for FILE in "${MIGRATED_FILES[@]}"; do
    if rm "$FILE"; then
      DELETED=$((DELETED + 1))
    else
      echo "  WARNING: Could not delete $FILE"
    fi
  done
  echo "  Deleted $DELETED files"
fi
if [ "$FAILED" -gt 0 ]; then
  echo ""
  echo "WARNING: $FAILED file(s) failed to migrate fully. Those originals preserved."
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
