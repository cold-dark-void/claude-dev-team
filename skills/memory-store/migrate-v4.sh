#!/usr/bin/env bash
# migrate-v4.sh — Migrate memory.db from schema v3 to v4 (cross-agent reconcile)
#
# Usage: migrate-v4.sh <MROOT>
#   MROOT — project root containing .claude/memory/memory.db
#
# Idempotent: exits 0 if already at schema v4.
# Exit 1 on any failure (no partial schema_version update).

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: migrate-v4.sh <MROOT>" >&2
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

# Check schema_version — exit early if already v4
CURRENT_VERSION=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='schema_version';" 2>/dev/null || echo "")
if [ "$CURRENT_VERSION" = "4" ]; then
  echo "Schema already at v4. Nothing to do."
  exit 0
fi

if [ "$CURRENT_VERSION" != "3" ]; then
  echo "Error: unexpected schema_version '$CURRENT_VERSION' (expected '3')" >&2
  exit 1
fi

# .bail on: mid-transaction errors must abort before schema_version bumps.
sqlite3 "$MEMDB" <<'SQL'
.bail on
PRAGMA busy_timeout=5000;

BEGIN TRANSACTION;

CREATE TABLE IF NOT EXISTS reconcile_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  memory_id_a INTEGER NOT NULL REFERENCES memories(id),
  memory_id_b INTEGER NOT NULL REFERENCES memories(id),
  agent_a TEXT NOT NULL,
  agent_b TEXT NOT NULL,
  verdict TEXT NOT NULL CHECK(verdict IN ('contradictory','consistent','unrelated')),
  claim_a TEXT,
  claim_b TEXT,
  confidence INTEGER NOT NULL,
  action TEXT NOT NULL CHECK(action IN (
    'none','report','pick-survivor','merge','both-stale','skip','deep-audit'
  )),
  winner_id INTEGER,
  loser_id INTEGER,
  reason TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_reconcile_pair
  ON reconcile_log(memory_id_a, memory_id_b);

INSERT OR IGNORE INTO config(key, value) VALUES ('reconcile_pair_cap', '50');

UPDATE config SET value='4' WHERE key='schema_version';

COMMIT;
SQL

echo "Migrated schema v3 -> v4. reconcile_log table added; reconcile_pair_cap defaulted to 50."
