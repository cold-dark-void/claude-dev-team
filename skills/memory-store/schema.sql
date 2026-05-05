-- Core memory table (v3: validation support)
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

-- Config table for runtime state (embedding mode, model info, schema version)
CREATE TABLE IF NOT EXISTS config (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- Seed config
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

-- Distillation audit log
CREATE TABLE IF NOT EXISTS distillation_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  agent TEXT NOT NULL,
  from_tier INTEGER NOT NULL,
  to_tier INTEGER NOT NULL,
  source_count INTEGER NOT NULL,
  result_memory_id INTEGER REFERENCES memories(id),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- Validation audit log
CREATE TABLE IF NOT EXISTS validation_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  memory_id INTEGER NOT NULL REFERENCES memories(id),
  agent TEXT NOT NULL,
  action TEXT NOT NULL CHECK(action IN ('pass','archive','rewrite','flag_review','flag_user')),
  confidence INTEGER NOT NULL,
  reason TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

-- Embedding provenance tracking (which model produced which embeddings)
CREATE TABLE IF NOT EXISTS embedding_meta (
  memory_id INTEGER NOT NULL,
  model TEXT NOT NULL,
  dimensions INTEGER NOT NULL,
  vec_table TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  PRIMARY KEY (memory_id, model)
);

-- NOTE: vec0 virtual tables are created ONLY when sqlite-vec extension is
-- loaded. They will fail silently if vec0 is not available.
-- Agents must check for extension availability before creating these.
--
-- Common dimensions:
--   384  — sqlite-lembed / all-MiniLM-L6-v2
--   768  — nomic-embed-text
--   1024 — mxbai-embed-large
--   1536 — OpenAI text-embedding-3-small
--
-- Tables are auto-created at runtime for any dimension via:
--   CREATE VIRTUAL TABLE IF NOT EXISTS vec_memories_N USING vec0(...)

-- Enable WAL mode for concurrent agent access. Some sandboxed
-- filesystems (bubblewrap tmpdirs, NFS, certain CI runners) cannot
-- host the WAL/SHM shared-memory files; in those environments SQLite
-- silently falls back to journal_mode=delete and writes serialize
-- across agents. Init-orchestration probes the actual mode after
-- apply and warns if WAL was rejected, so the degradation is visible.
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;
PRAGMA foreign_keys=ON;
