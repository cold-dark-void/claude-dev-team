-- control-plane run journal — the one DDL home (CDT-643).
--
-- Engine: SQLite behind a narrow interface (docs/adr/0001-journal-engine.md).
-- One file, one short-lived writer per open, busy timeout set on every open
-- (the skills/memory-store/memdb.sh:35 pattern). The file is never
-- memory.db: run state is not agent memory (ADR 0001 § "The journal references
-- decision-cards"). journal.Open refuses a path that resolves to memory.db.
--
-- APPEND-ONLY RULE (SPEC-040 AC11/M20 discipline, carried to run state):
-- the events table is an append-only journal. INSERT is the only legal write.
-- No UPDATE, DELETE, REPLACE, TRUNCATE, DROP, ALTER, and no rowid reuse.
-- State is never stored: state is the replay of these rows (journal.Replay),
-- so replaying the same rows yields the same state. Three layers enforce it:
--   1. the journal package exposes no event-mutation call;
--   2. journal.execGuard refuses the statement before SQLite sees it: every
--      statement that writes the events table, and every DROP or ALTER on any
--      table. It resolves "quoted" and `quoted` identifiers to their plain
--      names first, so quoting does not hide a target;
--   3. the events_no_update / events_no_delete triggers below make the
--      database itself reject an UPDATE or DELETE of an event row, so no caller
--      can bypass 1 and 2 for the rows.
-- The guarantee, stated exactly: no caller of this engine can UPDATE or DELETE
-- an event row, or DROP or ALTER any table, through ExecContext. Layer 3
-- additionally rejects the row mutations at the database level. SQLite has no
-- DROP or ALTER trigger, so a structure change rests on layer 2 alone.
-- The lease table is NOT the journal: it is the mutable lock record of
-- record-ownership.md's `single-writer-lease` rule, and every acquisition of
-- it is journaled as an event, so the audit trail stays append-only.
--
-- CARD REFERENCE RULE (ADR 0001 § "The journal references decision-cards";
-- SPEC-033 AC6/M13 frozen schema): a row carries a card REFERENCE — path, ts,
-- run_id — and never a copy of a card field. The journal writes no card, adds
-- no card key, and needs no card schema_version bump. The three card_* columns
-- are all-null or all-set; journal.CardRef is the only type that can fill them.
--
-- Schema version: journal_meta('schema_version'). Journal rows carry no
-- per-row version: the closed kind set below is the contract.

PRAGMA foreign_keys = ON;

-- The journal. seq is monotonic and never reused (AUTOINCREMENT).
CREATE TABLE IF NOT EXISTS events (
  seq             INTEGER PRIMARY KEY AUTOINCREMENT,
  ts              TEXT    NOT NULL,
  run_id          TEXT    NOT NULL,
  kind            TEXT    NOT NULL CHECK (kind IN (
                    'run_claimed',
                    'lease_acquired',
                    'run_started',
                    'stint_started',
                    'heartbeat',
                    'run_progress',
                    'side_effect',
                    'run_halted',
                    'run_resumed',
                    'repair',
                    'run_completed',
                    'run_failed'
                  )),
  payload_json    TEXT    NOT NULL DEFAULT '{}',
  -- Idempotency key: an effect key survives a crash, so a replay of the same
  -- intent finds the row and does not repeat the effect (AC3). NULL = an event
  -- with no external effect. The partial unique index keys non-null values only.
  idempotency_key TEXT,
  -- Card reference (path + ts + run_id), all-null or all-set. Never a card copy.
  card_path       TEXT,
  card_ts         TEXT,
  card_run_id     TEXT,
  -- The one timestamp shape: UTC, second precision. A CHECK that can evaluate
  -- to NULL is no check, so the validity half is stated explicitly.
  CHECK (
    strftime('%Y-%m-%dT%H:%M:%SZ', ts) IS NOT NULL
    AND strftime('%Y-%m-%dT%H:%M:%SZ', ts) = ts
  ),
  CHECK (length(run_id) > 0),
  CHECK (
    (card_path IS NULL AND card_ts IS NULL AND card_run_id IS NULL)
    OR
    (card_path IS NOT NULL AND card_ts IS NOT NULL AND card_run_id IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_events_run_seq  ON events(run_id, seq);
CREATE INDEX IF NOT EXISTS idx_events_run_kind ON events(run_id, kind);
CREATE UNIQUE INDEX IF NOT EXISTS idx_events_idem
  ON events(idempotency_key) WHERE idempotency_key IS NOT NULL;

-- Enforcement layer 3 of the APPEND-ONLY RULE.
CREATE TRIGGER IF NOT EXISTS events_no_update
  BEFORE UPDATE ON events
BEGIN
  SELECT RAISE(ABORT, 'events is append-only: UPDATE is not a legal write');
END;

CREATE TRIGGER IF NOT EXISTS events_no_delete
  BEFORE DELETE ON events
BEGIN
  SELECT RAISE(ABORT, 'events is append-only: DELETE is not a legal write');
END;

-- One owner per run (AC4). token is the fencing token: strictly monotonic per
-- run. Acquisition and takeover are journaled; a released lease is removed, and
-- the terminal event that released it is the journal's record of that.
CREATE TABLE IF NOT EXISTS lease (
  run_id            TEXT PRIMARY KEY,
  owner             TEXT NOT NULL CHECK (length(owner) > 0),
  token             INTEGER NOT NULL CHECK (token >= 1),
  acquired_at       TEXT NOT NULL,
  last_heartbeat_ts TEXT NOT NULL,
  stall_limit_s     INTEGER NOT NULL CHECK (stall_limit_s > 0),
  CHECK (last_heartbeat_ts >= acquired_at)
);

-- Journal metadata. schema_version is the journal's own, not a card's:
-- SPEC-033 AC6/M13 keeps every card at schema_version 1 and the journal never
-- touches it.
CREATE TABLE IF NOT EXISTS journal_meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

INSERT OR IGNORE INTO journal_meta(key, value) VALUES
  ('schema_version', '1'),
  ('engine', 'sqlite-behind-narrow-interface'),
  ('adr', 'docs/adr/0001-journal-engine.md'),
  ('owner', 'control-plane-only');
