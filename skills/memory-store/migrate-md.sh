#!/usr/bin/env bash
set -euo pipefail

# Usage: migrate-md.sh [--dry-run] [--delete-sources] <MROOT>
# Where MROOT is the project root (resolved via git-common-dir)
#
# Migrates existing .md memory files (cortex, memory, lessons) from
# .claude/memory/<agent>/ into the SQLite memories table.
# Files are chunked by ## sections — each section becomes its own row
# for better embedding quality and semantic search granularity.
# Body lines that start with # are kept. Oversized chunks are split, not
# truncated. Sources are renamed to *.md.migrated unless --delete-sources.
# --dry-run writes nothing and leaves every source in place.
# context.md files are intentionally skipped — they remain as .md per-worktree.

DRY_RUN=false
DELETE_SOURCES=false
MROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --delete-sources) DELETE_SOURCES=true; shift ;;
    --) shift; break ;;
    -*) echo "ERROR: unknown flag $1" >&2; exit 64 ;;
    *) MROOT="$1"; shift ;;
  esac
done
if [ -z "$MROOT" ]; then
  echo "Usage: migrate-md.sh [--dry-run] [--delete-sources] <project-root>" >&2
  exit 64
fi
MEMDB="$MROOT/.claude/memory/memory.db"
MEMDIR="$MROOT/.claude/memory"

# Shared lembed helpers (model registration, .errors.log) live next to this file.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# A missing embed-common.sh must not stop the .md import: embedding is skipped.
EMBED_LIB_OK=true
if [ -f "$SCRIPT_DIR/embed-common.sh" ]; then
  # shellcheck source=embed-common.sh
  . "$SCRIPT_DIR/embed-common.sh"
else
  EMBED_LIB_OK=false
  echo "WARNING: embed-common.sh not found next to migrate-md.sh; embedding is skipped (the .md import still runs)." >&2
fi

# Verify DB exists
if [ ! -f "$MEMDB" ]; then
  echo "ERROR: memory.db not found at $MEMDB"
  echo "Run /setup team first to create the database."
  exit 1
fi
command -v sqlite3 >/dev/null 2>&1 || { echo "ERROR: sqlite3 is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required" >&2; exit 1; }

# Counters
TOTAL_FILES=0
TOTAL_CHUNKS=0
MIGRATED=0
SKIPPED=0
FAILED=0
DELETED=0

# Track successfully migrated files for cleanup
MIGRATED_FILES=()

# Insert a text body in pieces of at most LIMIT characters, on line boundaries
# when a line fits. A single longer line is inserted whole (never head -c).
split_and_insert() {
  local text="$1" limit="$2"
  local piece="" line
  local -a parts=()
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -z "$piece" ]; then
      piece="$line"
    elif [ $(( ${#piece} + ${#line} + 1 )) -le "$limit" ]; then
      piece="${piece}
${line}"
    else
      parts+=("$piece")
      piece="$line"
    fi
  done <<< "$text"
  if [ -n "$piece" ]; then
    parts+=("$piece")
  fi
  # A piece of 20 characters or fewer is below the insert floor. Fold it into
  # a neighbor so a short tail is not stored alone and then lost on the rerun.
  if [ "${#parts[@]}" -gt 1 ]; then
    local -a folded=()
    local cur=""
    for cur in "${parts[@]}"; do
      if [ "${#folded[@]}" -gt 0 ] && [ "${#cur}" -le 20 ]; then
        folded[$((${#folded[@]} - 1))]="${folded[$((${#folded[@]} - 1))]}
${cur}"
      else
        folded+=("$cur")
      fi
    done
    if [ "${#folded[@]}" -gt 1 ] && [ "${#folded[0]}" -le 20 ]; then
      folded[1]="${folded[0]}
${folded[1]}"
      folded=("${folded[@]:1}")
    fi
    parts=("${folded[@]}")
  fi
  local p
  for p in "${parts[@]}"; do
    [ -n "$p" ] || continue
    _migrate_chunk "$p"
  done
}

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

  if [ "$DRY_RUN" = true ]; then
    echo "  dry-run: would migrate $AGENT/$TYPE.md"
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
        split_and_insert "$CHUNK" 8000
        CHUNK="$LINE"
      else
        CHUNK="${CHUNK}
${LINE}"
      fi
    done <<< "$CONTENT"
    # Save last chunk
    if [ -n "$CHUNK" ]; then
      split_and_insert "$CHUNK" 8000
    fi
    echo "  OK: $FILE_INSERTED inserted / $FILE_CONSIDERED considered ($FILE_SKIPPED short-skipped) from $AGENT/$TYPE"
    TOTAL_CHUNKS=$((TOTAL_CHUNKS + FILE_INSERTED))
  else
    # No ## headers — split the file instead of truncating at 5000 chars.
    if [ -z "$CONTENT" ]; then
      FILE_SKIPPED=$((FILE_SKIPPED + 1))
      echo "  WARN: empty content for $AGENT/$TYPE — source will be preserved"
    else
      split_and_insert "$CONTENT" 5000
      if [ "$FILE_INSERTED" -gt 0 ]; then
        echo "  OK: $FILE_INSERTED chunk(s) (no sections) from $AGENT/$TYPE"
      fi
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

if [ "$DRY_RUN" != true ] && [ "$EMBED_MODE" != "fallback" ] && [ "$EMBED_MODE" != "none" ] && [ "$EMBED_LIB_OK" = true ]; then
  UNEMBEDDED=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT COUNT(*) FROM memories m LEFT JOIN embedding_meta em ON em.memory_id = m.id WHERE em.memory_id IS NULL AND m.archived = 0;")

  if [ "$UNEMBEDDED" -gt 0 ]; then
    echo ""
    echo "Embedding $UNEMBEDDED chunks (mode: $EMBED_MODE)..."
    EMBEDDED_COUNT=0

    # sqlite3 stderr goes to this temp file, never into a captured value: a call
    # that succeeds but prints a warning must still yield a clean vector. The file
    # is removed on every exit path; without it stderr is discarded.
    EMBED_ERR=$(mktemp "${TMPDIR:-/tmp}/migrate-md-embed.XXXXXX") || EMBED_ERR=""
    trap '[ -z "${EMBED_ERR:-}" ] || rm -f "$EMBED_ERR"' EXIT

    # Read embedding URL/model once (not per-row)
    EMBED_URL=""
    EMBED_KEY="${EMBEDDING_API_KEY:-}"
    EMBED_MODEL="${EMBEDDING_MODEL:-}"
    if [ "$EMBED_MODE" = "remote" ]; then
      EMBED_URL=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT value FROM config WHERE key='embedding_url';" 2>/dev/null)
      # Env overrides DB; DB is durable source when env unset.
      [ -n "$EMBED_MODEL" ] || EMBED_MODEL=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT value FROM config WHERE key='embedding_model';" 2>/dev/null)
    fi
    # Apply :-default before escaping (SPEC-004 / CDT-164). SQL-only — jq --arg keeps raw EMBED_MODEL.
    EMBED_MODEL_ESC=$(printf '%s' "${EMBED_MODEL:-all-MiniLM-L6-v2}" | sed "s/'/''/g")

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

        RESPONSE=$(curl "${CURL_ARGS[@]}" 2>/dev/null) || { [ -n "$CURL_CONFIG" ] && rm -f "$CURL_CONFIG"; echo "  WARN: curl failed for chunk $MEM_ID"; embed_log_error "$MEMDIR" migrate-md "chunk $MEM_ID: curl failed for the remote embedding endpoint"; continue; }
        [ -n "$CURL_CONFIG" ] && rm -f "$CURL_CONFIG"
        EMBEDDING=$(printf '%s' "$RESPONSE" | jq -c '.data[0].embedding // .embeddings[0] // .embedding' 2>/dev/null)
        # $EMBEDDING is interpolated raw into INSERT VALUES — it must be a well-formed
        # numeric array. Reject anything outside digits . , e E + - space [ ] (network
        # trust boundary). ']' is first and '-' last so the bracket class is literal.
        # Per-row best-effort: skip this chunk's embedding, don't abort the migration.
        if printf '%s' "$EMBEDDING" | grep -q '[^][0-9.,eE+ -]'; then
          echo "  WARN: embedding from endpoint is not a numeric vector for chunk $MEM_ID; skipping" >&2
          embed_log_error "$MEMDIR" migrate-md "chunk $MEM_ID: embedding from the remote endpoint is not a numeric vector"
          continue
        fi

      elif [ "$EMBED_MODE" = "lembed" ] && [ -f "$EXT_DIR/lembed0.$EXT_SUFFIX" ]; then
        MODEL_PATH="$MODEL_DIR/all-MiniLM-L6-v2.gguf"
        ESCAPED_SQL=$(printf '%s' "$MEM_CONTENT" | sed "s/'/''/g")
        # lembed() takes a registered model NAME (embed-common.sh). The model is
        # registered on this connection, in the same call, before lembed() runs
        # (temp.lembed_models is per connection; a bulk run loads the model per
        # row — simple, not fast). lembed() returns a BLOB, so read it as JSON
        # with vec_to_json(): json() cannot hold a BLOB.
        REGISTER_SQL=$(embed_lembed_register_sql "$MODEL_PATH") || REGISTER_SQL=""
        LEMBED_RC=0
        EMBEDDING=$(sqlite3 -bail "$MEMDB" ".load $EXT_DIR/vec0" ".load $EXT_DIR/lembed0" \
          "$REGISTER_SQL" \
          "SELECT vec_to_json(lembed('$EMBED_LEMBED_NAME', '$ESCAPED_SQL'));" 2>"${EMBED_ERR:-/dev/null}") || LEMBED_RC=$?
        if [ "$LEMBED_RC" -ne 0 ]; then
          LEMBED_ERR=""
          [ -z "$EMBED_ERR" ] || LEMBED_ERR=$(cat "$EMBED_ERR" 2>/dev/null || true)
          echo "  WARN: lembed failed for chunk $MEM_ID"
          embed_log_error "$MEMDIR" migrate-md "chunk $MEM_ID: lembed failed (sqlite3 exit $LEMBED_RC): ${LEMBED_ERR:-${EMBEDDING:-no error text}}"
          continue
        fi
      else
        break
      fi

      # Validate
      [ -z "$EMBEDDING" ] || [ "$EMBEDDING" = "null" ] && { echo "  WARN: empty embedding for chunk $MEM_ID"; embed_log_error "$MEMDIR" migrate-md "chunk $MEM_ID: empty embedding"; continue; }
      # DIMS becomes a table identifier (vec_memories_<DIMS>): a positive integer only.
      # A failing jq (not JSON) must not abort the run under set -e, and an invalid
      # count is a failed embed: warn and log it, never a silent continue.
      DIMS=$(printf '%s' "$EMBEDDING" | jq 'length' 2>/dev/null) || DIMS=""
      if ! [[ "$DIMS" =~ ^[0-9]+$ ]] || [ "$DIMS" -eq 0 ]; then
        echo "  WARN: invalid embedding dimensions '$DIMS' for chunk $MEM_ID"
        embed_log_error "$MEMDIR" migrate-md "chunk $MEM_ID: invalid embedding dimensions '$DIMS'"
        continue
      fi

      VEC_TABLE="vec_memories_${DIMS}"

      # Ensure vec table exists with correct schema
      # Drop and recreate if columns don't match (handles legacy tables)
      PROBE_RC=0
      PROBE_OUT=$(sqlite3 "$MEMDB" ".load $EXT_DIR/vec0" "PRAGMA table_info($VEC_TABLE);" 2>/dev/null) || PROBE_RC=$?
      if [ "$PROBE_RC" -ne 0 ]; then
        echo "  WARN: table_info probe failed for $VEC_TABLE; not dropping it"
        embed_log_error "$MEMDIR" migrate-md "chunk $MEM_ID: table_info probe failed; left $VEC_TABLE in place"
        continue
      fi
      HAS_MEMORY_ID=$(printf '%s\n' "$PROBE_OUT" | grep -c "memory_id" || true)
      if [ "$HAS_MEMORY_ID" = "0" ]; then
        sqlite3 "$MEMDB" ".load $EXT_DIR/vec0" \
          "DROP TABLE IF EXISTS $VEC_TABLE;" \
          "CREATE VIRTUAL TABLE $VEC_TABLE USING vec0(memory_id INTEGER, embedding FLOAT[$DIMS]);" 2>/dev/null
      else
        sqlite3 "$MEMDB" ".load $EXT_DIR/vec0" \
          "CREATE VIRTUAL TABLE IF NOT EXISTS $VEC_TABLE USING vec0(memory_id INTEGER, embedding FLOAT[$DIMS]);" 2>/dev/null
      fi

      # Insert embedding
      INSERT_RC=0
      INSERT_ERR=$(sqlite3 "$MEMDB" ".load $EXT_DIR/vec0" \
        "INSERT INTO ${VEC_TABLE}(memory_id, embedding) VALUES ($MEM_ID, '$EMBEDDING');" \
        "INSERT OR IGNORE INTO embedding_meta(memory_id, model, dimensions, vec_table) VALUES ($MEM_ID, '$EMBED_MODEL_ESC', $DIMS, '$VEC_TABLE');" \
        2>&1) || INSERT_RC=$?
      if [ "$INSERT_RC" -ne 0 ]; then
        echo "  WARN: vec insert failed for chunk $MEM_ID"
        embed_log_error "$MEMDIR" migrate-md "chunk $MEM_ID: vec insert failed (sqlite3 exit $INSERT_RC): ${INSERT_ERR:-no error text}"
        continue
      fi

      EMBEDDED_COUNT=$((EMBEDDED_COUNT + 1))
    done < <(sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT m.id FROM memories m LEFT JOIN embedding_meta em ON em.memory_id = m.id WHERE em.memory_id IS NULL AND m.archived = 0;" 2>/dev/null)

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
if [ "$DRY_RUN" = true ]; then
  echo ""
  echo "dry-run: no source files renamed"
elif [ "${#MIGRATED_FILES[@]}" -gt 0 ]; then
  echo ""
  if [ "$DELETE_SOURCES" = true ]; then
    echo "Deleting fully-migrated source files..."
  else
    echo "Renaming fully-migrated source files to *.md.migrated..."
  fi
  for FILE in "${MIGRATED_FILES[@]}"; do
    if [ "$DELETE_SOURCES" = true ]; then
      if rm "$FILE"; then
        DELETED=$((DELETED + 1))
      else
        echo "  WARNING: Could not delete $FILE"
      fi
    elif mv "$FILE" "$FILE.migrated"; then
      DELETED=$((DELETED + 1))
    else
      echo "  WARNING: Could not rename $FILE"
    fi
  done
  echo "  Retired $DELETED files"
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
