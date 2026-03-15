#!/usr/bin/env bash
set -euo pipefail

# Usage: migrate-md.sh <MROOT>
# Where MROOT is the project root (resolved via git-common-dir)
#
# Migrates existing .md memory files (cortex, memory, lessons) from
# .claude/memory/<agent>/ into the SQLite memories table.
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
TOTAL=0
MIGRATED=0
SKIPPED=0
FAILED=0
DELETED=0

# Track successfully migrated files for cleanup
MIGRATED_FILES=()

echo "Scanning $MEMDIR for .md memory files..."
echo ""

# Find all agent subdirectory .md files matching cortex/memory/lessons
# Pattern: $MEMDIR/<agent>/{cortex,memory,lessons}.md
# We deliberately skip context.md and files not in agent subdirs.
while IFS= read -r FILE; do
  AGENT=$(basename "$(dirname "$FILE")")
  TYPE=$(basename "$FILE" .md)

  # Skip context.md
  if [ "$TYPE" = "context" ]; then
    continue
  fi

  # Only migrate known types
  if [[ "$TYPE" != "cortex" && "$TYPE" != "memory" && "$TYPE" != "lessons" ]]; then
    continue
  fi

  # Skip .md files that are directly in $MEMDIR (not inside an agent subdir)
  PARENT_DIR=$(dirname "$FILE")
  if [ "$PARENT_DIR" = "$MEMDIR" ]; then
    continue
  fi

  TOTAL=$((TOTAL + 1))
  echo "Processing: $AGENT/$TYPE.md"

  # Idempotent: skip if agent+type already has a row
  EXISTING=$(sqlite3 "$MEMDB" "SELECT COUNT(*) FROM memories WHERE agent='$AGENT' AND type='$TYPE';")
  if [ "$EXISTING" -gt 0 ]; then
    echo "  SKIP: $AGENT/$TYPE.md (already in DB)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Read file content
  CONTENT=$(cat "$FILE")

  # Escape single quotes for SQLite (double them up)
  ESCAPED_CONTENT=$(printf '%s' "$CONTENT" | sed "s/'/''/g")

  # Insert into DB
  if sqlite3 "$MEMDB" "INSERT INTO memories(agent, type, content) VALUES ('$AGENT', '$TYPE', '$ESCAPED_CONTENT');"; then
    echo "  OK: inserted $AGENT/$TYPE"
    MIGRATED=$((MIGRATED + 1))
    MIGRATED_FILES+=("$FILE")
  else
    echo "  ERROR: failed to insert $AGENT/$TYPE"
    FAILED=$((FAILED + 1))
  fi
done < <(find "$MEMDIR" -mindepth 2 -maxdepth 2 -name "*.md" | sort)

# Generate embeddings if the embedding mode is not 'fallback'
EMBED_MODE=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='embedding_mode';" 2>/dev/null || echo "fallback")

if [ "$EMBED_MODE" != "fallback" ] && [ "$EMBED_MODE" != "none" ] && [ "$MIGRATED" -gt 0 ]; then
  echo ""
  echo "Embedding mode: $EMBED_MODE — attempting to generate embeddings for migrated rows..."
  EMBED_SCRIPT="$(dirname "$0")/embed.sh"
  if [ -x "$EMBED_SCRIPT" ]; then
    "$EMBED_SCRIPT" "$MEMDB" || echo "WARNING: embedding generation failed (rows still saved)"
  else
    echo "  NOTE: embed.sh not found or not executable — skipping embeddings"
  fi
fi

# Validation: total rows in memories table
INSERTED=$(sqlite3 "$MEMDB" "SELECT COUNT(*) FROM memories;")
echo ""
echo "Validation: $INSERTED total rows in memories table"

# Delete originals only if all inserts succeeded
if [ "$FAILED" -eq 0 ] && [ "${#MIGRATED_FILES[@]}" -gt 0 ]; then
  echo ""
  echo "Deleting migrated source files..."
  for FILE in "${MIGRATED_FILES[@]}"; do
    if rm "$FILE"; then
      echo "  DELETED: $FILE"
      DELETED=$((DELETED + 1))
    else
      echo "  WARNING: Could not delete $FILE"
    fi
  done
elif [ "$FAILED" -gt 0 ]; then
  echo ""
  echo "WARNING: $FAILED file(s) failed to migrate. Originals preserved."
fi

echo ""
echo "=== Migration Summary ==="
echo "Files found:    $TOTAL"
echo "Migrated:       $MIGRATED"
echo "Skipped (dupe): $SKIPPED"
echo "Failed:         $FAILED"
echo "Deleted:        $DELETED"
echo "========================="

# Exit 1 if any migrations failed
if [ "$FAILED" -gt 0 ]; then
  exit 1
fi

exit 0
