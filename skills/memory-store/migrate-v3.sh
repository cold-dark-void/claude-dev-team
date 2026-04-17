#!/usr/bin/env bash
# migrate-v3.sh — Migrate memory.db from schema v2 to v3 (memory validation)
#
# Usage: migrate-v3.sh <MROOT>
#   MROOT — project root containing .claude/memory/memory.db
#
# Idempotent: exits 0 if already at schema v3.
# Exit 1 on any failure (no partial schema_version update).

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: migrate-v3.sh <MROOT>" >&2
  exit 1
fi

MROOT="$1"
MEMDB="$MROOT/.claude/memory/memory.db"

if [ ! -f "$MEMDB" ]; then
  echo "Error: database not found at $MEMDB" >&2
  exit 1
fi

if ! command -v sqlite3 &>/dev/null; then
  echo "Error: sqlite3 not found in PATH" >&2
  exit 1
fi

# Check schema_version — exit early if already v3
CURRENT_VERSION=$(sqlite3 "$MEMDB" "PRAGMA busy_timeout=5000; SELECT value FROM config WHERE key='schema_version';" 2>/dev/null || echo "")
if [ "$CURRENT_VERSION" = "3" ]; then
  echo "Schema already at v3. Nothing to do."
  exit 0
fi

if [ "$CURRENT_VERSION" != "2" ]; then
  echo "Error: unexpected schema_version '$CURRENT_VERSION' (expected '2')" >&2
  exit 1
fi

# Count existing memories for summary
ROW_COUNT=$(sqlite3 "$MEMDB" "PRAGMA busy_timeout=5000; SELECT COUNT(*) FROM memories;" 2>/dev/null || echo "0")

# Run migration inside a transaction
sqlite3 "$MEMDB" <<'SQL'
PRAGMA busy_timeout=5000;

BEGIN TRANSACTION;

ALTER TABLE memories ADD COLUMN validated_at TEXT DEFAULT NULL;
ALTER TABLE memories ADD COLUMN archive_reason TEXT DEFAULT NULL;

CREATE TABLE IF NOT EXISTS validation_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  memory_id INTEGER NOT NULL,
  agent TEXT NOT NULL,
  action TEXT NOT NULL CHECK(action IN ('pass','archive','rewrite','flag_review','flag_user')),
  confidence INTEGER NOT NULL,
  reason TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

INSERT OR IGNORE INTO config(key, value) VALUES ('validate_window_days', '7');

UPDATE config SET value='3' WHERE key='schema_version';

COMMIT;
SQL

echo "Migrated schema v2 -> v3. $ROW_COUNT existing memories preserved. validated_at and archive_reason columns added."
