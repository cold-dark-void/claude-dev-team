-- Minimal v3 memory.db seed (post validation columns, pre reconcile_log).
-- Shape matches schema after migrate-v2 + migrate-v3 (schema_version=3).

CREATE TABLE IF NOT EXISTS memories (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  agent TEXT NOT NULL,
  type TEXT NOT NULL CHECK(type IN ('cortex','memory','lessons','digest','core')),
  content TEXT NOT NULL,
  metadata_json TEXT DEFAULT '{}',
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  tier INTEGER NOT NULL DEFAULT 0 CHECK(tier IN (0, 1, 2)),
  archived BOOLEAN NOT NULL DEFAULT FALSE,
  distilled_from TEXT NOT NULL DEFAULT '[]',
  validated_at TEXT DEFAULT NULL,
  archive_reason TEXT DEFAULT NULL
);

CREATE INDEX IF NOT EXISTS idx_memories_agent ON memories(agent);
CREATE INDEX IF NOT EXISTS idx_memories_agent_type ON memories(agent, type);
CREATE INDEX IF NOT EXISTS idx_memories_tier ON memories(agent, tier, archived);

CREATE TABLE IF NOT EXISTS config (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

INSERT OR IGNORE INTO config(key, value) VALUES
  ('schema_version', '3'),
  ('embedding_mode', 'fallback'),
  ('embedding_model', 'none'),
  ('embedding_dimensions', '0'),
  ('distill_enabled', 'false'),
  ('distill_mode', 'suggest'),
  ('distill_threshold', '50'),
  ('distilling_lock', ''),
  ('distill_model', 'haiku'),
  ('validate_window_days', '7');

CREATE TABLE IF NOT EXISTS distillation_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  agent TEXT NOT NULL,
  from_tier INTEGER NOT NULL,
  to_tier INTEGER NOT NULL,
  source_count INTEGER NOT NULL,
  result_memory_id INTEGER REFERENCES memories(id),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE TABLE IF NOT EXISTS validation_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  memory_id INTEGER NOT NULL REFERENCES memories(id),
  agent TEXT NOT NULL,
  action TEXT NOT NULL CHECK(action IN ('pass','archive','rewrite','flag_review','flag_user')),
  confidence INTEGER NOT NULL,
  reason TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE TABLE IF NOT EXISTS embedding_meta (
  memory_id INTEGER NOT NULL,
  model TEXT NOT NULL,
  dimensions INTEGER NOT NULL,
  vec_table TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  PRIMARY KEY (memory_id, model)
);

-- Seed row for floor-upgrade data-preservation check
INSERT INTO memories(agent, type, content, tier)
VALUES ('ic4', 'memory', 'v3-seed-row: floor upgrade must preserve this content', 0);
