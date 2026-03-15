-- Core memory table
CREATE TABLE IF NOT EXISTS memories (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  agent TEXT NOT NULL,
  type TEXT NOT NULL CHECK(type IN ('cortex','memory','lessons')),
  content TEXT NOT NULL,
  metadata_json TEXT DEFAULT '{}',
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_memories_agent ON memories(agent);
CREATE INDEX IF NOT EXISTS idx_memories_agent_type ON memories(agent, type);

-- Config table for runtime state (embedding mode, model info, schema version)
CREATE TABLE IF NOT EXISTS config (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- Seed config
INSERT OR IGNORE INTO config(key, value) VALUES
  ('schema_version', '1'),
  ('embedding_mode', 'fallback'),
  ('embedding_model', 'none'),
  ('embedding_dimensions', '0');

-- Embedding provenance tracking (which model produced which embeddings)
CREATE TABLE IF NOT EXISTS embedding_meta (
  memory_id INTEGER NOT NULL,
  model TEXT NOT NULL,
  dimensions INTEGER NOT NULL,
  vec_table TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  PRIMARY KEY (memory_id, model)
);

-- NOTE: The following vec0 virtual tables are created ONLY when sqlite-vec
-- extension is loaded. They will fail silently if vec0 is not available.
-- Agents must check for extension availability before creating these.
--
-- For 384-dim (sqlite-lembed / all-MiniLM-L6-v2):
-- CREATE VIRTUAL TABLE IF NOT EXISTS vec_memories_384 USING vec0(
--   memory_id INTEGER,
--   embedding FLOAT[384]
-- );
--
-- For 768-dim (ollama / nomic-embed-text):
-- CREATE VIRTUAL TABLE IF NOT EXISTS vec_memories_768 USING vec0(
--   memory_id INTEGER,
--   embedding FLOAT[768]
-- );

-- Enable WAL mode for concurrent agent access
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;
