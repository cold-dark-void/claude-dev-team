#!/usr/bin/env bash
# migrate-v2.sh — Migrate memory.db from schema v1 to v2 (tiered distillation)
#
# Usage: migrate-v2.sh <MROOT>
#   MROOT — project root containing .claude/memory/memory.db
#
# Idempotent: exits 0 if already at schema v2.
# Exit 1 on any failure (no partial schema_version update).

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: migrate-v2.sh <MROOT>" >&2
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

# Step 1: Check schema_version — exit early if already v2
CURRENT_VERSION=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='schema_version';" 2>/dev/null || echo "")
if [ "$CURRENT_VERSION" = "2" ]; then
  echo "Schema already at v2. Nothing to do."
  exit 0
fi

if [ "$CURRENT_VERSION" != "1" ]; then
  echo "Error: unexpected schema_version '$CURRENT_VERSION' (expected '1')" >&2
  exit 1
fi

# Count existing memories for summary
ROW_COUNT=$(sqlite3 "$MEMDB" "SELECT COUNT(*) FROM memories;" 2>/dev/null || echo "0")

# Table rebuild inside a transaction (SQLite cannot ALTER CHECK constraints).
# .bail on: abort on first error so a partial rebuild cannot leave the DB
# half-migrated while later statements (including schema_version) still run.
sqlite3 "$MEMDB" <<'SQL'
.bail on
-- Set busy timeout so concurrent writes don't immediately fail
PRAGMA busy_timeout=5000;

PRAGMA foreign_keys=OFF;

BEGIN TRANSACTION;

-- Create new table with v2 schema
CREATE TABLE memories_new (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  agent TEXT NOT NULL,
  type TEXT NOT NULL CHECK(type IN ('cortex','memory','lessons','digest','core')),
  content TEXT NOT NULL,
  metadata_json TEXT DEFAULT '{}',
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  tier INTEGER NOT NULL DEFAULT 0 CHECK(tier IN (0, 1, 2)),
  archived BOOLEAN NOT NULL DEFAULT FALSE,
  distilled_from TEXT NOT NULL DEFAULT '[]'
);

-- Copy existing data with v2 defaults
INSERT INTO memories_new
  SELECT id, agent, type, content, metadata_json, created_at, updated_at,
         0, FALSE, '[]'
  FROM memories;

DROP TABLE memories;

ALTER TABLE memories_new RENAME TO memories;

-- Recreate indexes
CREATE INDEX idx_memories_agent ON memories(agent);
CREATE INDEX idx_memories_agent_type ON memories(agent, type);
CREATE INDEX idx_memories_tier ON memories(agent, tier, archived);

COMMIT;

PRAGMA foreign_keys=ON;

-- Create distillation_log table
CREATE TABLE IF NOT EXISTS distillation_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  agent TEXT NOT NULL,
  from_tier INTEGER NOT NULL,
  to_tier INTEGER NOT NULL,
  source_count INTEGER NOT NULL,
  result_memory_id INTEGER REFERENCES memories(id),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- Insert config keys and update schema_version
INSERT OR IGNORE INTO config(key, value) VALUES
  ('distill_enabled', 'false'),
  ('distill_mode', 'suggest'),
  ('distill_threshold', '50'),
  ('distilling_lock', ''),
  ('distill_model', 'haiku');

UPDATE config SET value='2' WHERE key='schema_version';
SQL

echo "Migrated schema v1 -> v2. $ROW_COUNT existing memories set to tier=0."
