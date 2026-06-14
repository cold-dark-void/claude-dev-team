#!/usr/bin/env bash
# migrate.sh — Drive memory.db schema to the LATEST version in a single run.
#
# Usage: migrate.sh <MROOT>
#   MROOT — project root containing .claude/memory/memory.db
#
# Loops: reads config 'schema_version', then applies each sibling
# migrate-v<next>.sh in sequence (v1->v2->v3->...) until LATEST is reached.
# Each migrate-v<N>.sh is individually idempotent, so re-running is safe.
#
# Edge cases:
#   - empty/absent schema_version -> print skip note, exit 0 (silent no-op intent)
#   - non-numeric schema_version  -> exit 1
#   - already at LATEST           -> 'up to date', exit 0
#   - a step that fails to advance the version -> fail loudly, exit 1 (no infinite loop)

set -euo pipefail

LATEST=3

if [ $# -lt 1 ]; then
  echo "Usage: migrate.sh <MROOT>" >&2
  exit 1
fi

MROOT="$1"
MEMDB="$MROOT/.claude/memory/memory.db"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$MEMDB" ]; then
  echo "Error: database not found at $MEMDB" >&2
  exit 1
fi

if ! command -v sqlite3 &>/dev/null; then
  echo "Error: sqlite3 not found in PATH" >&2
  exit 1
fi

read_version() {
  # Plain SELECT — no inline PRAGMA (an inline 'PRAGMA busy_timeout=N;'
  # emits a result row that would pollute this captured read).
  sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='schema_version';" 2>/dev/null || echo ""
}

V="$(read_version)"

if [ -z "$V" ]; then
  echo "No schema_version found in $MEMDB — skipping migration."
  exit 0
fi

case "$V" in
  ''|*[!0-9]*)
    echo "Error: non-numeric schema_version '$V'" >&2
    exit 1
    ;;
esac

if [ "$V" -ge "$LATEST" ]; then
  echo "Schema version: $V (up to date)"
  exit 0
fi

while [ "$V" -lt "$LATEST" ]; do
  NEXT=$((V + 1))
  STEP="$DIR/migrate-v${NEXT}.sh"
  if [ ! -f "$STEP" ]; then
    echo "Error: missing migration script $STEP (cannot advance from v$V)" >&2
    exit 1
  fi
  echo "Migrating schema v$V -> v$NEXT..."
  if ! bash "$STEP" "$MROOT"; then
    echo "Error: migration v$V->v$NEXT failed" >&2
    exit 1
  fi
  NEWV="$(read_version)"
  case "$NEWV" in
    ''|*[!0-9]*)
      echo "Error: schema_version unreadable/non-numeric ('$NEWV') after v$V->v$NEXT" >&2
      exit 1
      ;;
  esac
  if [ "$NEWV" -le "$V" ]; then
    echo "Error: migration v$V->v$NEXT did not advance schema_version (still '$NEWV')" >&2
    exit 1
  fi
  V="$NEWV"
done

echo "Schema migrated to v$V (latest)."
