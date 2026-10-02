# SPEC-004: Memory Storage & Migration

**Status**: ACTIVE
**Category**: core
**Created**: 2026-03-22

**Covers**: `skills/memory-store/SKILL.md`, `skills/memory-store/schema.sql`, `skills/memory-store/embed-one.sh`, `skills/memory-store/embed-common.sh`, `skills/memory-store/test-embed-lembed.sh`, `skills/memory-store/memdb.sh`, `skills/memory-store/vec-cosine.sh`, `skills/memory-store/test-memdb.sh`, `skills/memory-store/test-migrate.sh`, `skills/memory-store/test-seed-pack.sh`, `skills/memory-store/migrate.sh`, `skills/memory-store/migrate-md.sh`, `skills/memory-store/migrate-v2.sh`, `skills/memory-store/migrate-v3.sh`, `skills/memory-store/migrate-v4.sh`

## Overview

The write-path persistence layer for agent memories. Handles dual-mode storage (SQLite preferred, .md fallback), append-only writes with SQL safety, optional embedding generation (lembed local or remote API), schema migrations through schema v4 (`schema.sql` stores `schema_version` 4; v1→v2 tiered distillation, then v3 and v4), and .md-to-SQLite bulk migration. All writes go through this layer.

## MUST

### Storage Mode Detection
- MUST detect storage mode by checking for `.claude/memory/memory.db` existence and `sqlite3` availability
- MUST fall back transparently to .md files when SQLite is unavailable

### SQLite Write Path
- MUST use append-only writes (one focused fact per INSERT, not giant blobs)
- MUST escape single quotes in all SQL content (double them: `'` → `''`)
- MUST call `last_insert_rowid()` in the same sqlite3 session as the INSERT
- MUST set `PRAGMA busy_timeout=5000` on every write operation
- MUST retry once on SQLITE_BUSY before failing
- MUST verify writes by reading back the inserted row

### Agent Session-Write Protocol (single source of truth)
- The agent session-WRITE protocol (append-only INSERT, `PRAGMA busy_timeout=5000`, SQLITE_BUSY retry, `MEMORY_ID` capture via same-session `last_insert_rowid()`, best-effort embedding via `skills/memory-store/embed-one.sh`) is defined ONCE in `skills/memory-store` plus the canonical `skills/agent-memory/protocol.md` partial.
- The 7 behavioral agents (pm, tech-lead, ic5, ic4, devops, qa, ds) MUST carry a MANAGED-INLINE copy of that block — expanded from the partial with `<AGENT>` substituted, between `<!-- include: skills/agent-memory/protocol.md agent=X -->` / `<!-- /include -->` markers, verified byte-identical against the partial by `skills/agent-memory/sync-includes.py` (check mode) at `/release`. Agents MUST NOT hand-edit the managed-inline region; corrections go to the partial and re-expand.

### .md Fallback Path
- MUST write to `.claude/memory/<agent>/{cortex,memory,lessons}.md`
- MUST respect line limits: cortex 100, memory 50, lessons 80, context 60
- MUST NOT migrate context.md to SQLite (remains per-worktree .md always)

### Embedding Generation
- MUST support two embedding modes: lembed (local GGUF model) and remote (API endpoint)
- MUST call `lembed()` with the REGISTERED MODEL NAME (`mini`), never a file path. sqlite-lembed v0.0.1-alpha.8 fails `lembed('<path>', …)` with "Unknown model name … Was it registered with lembed_models?" (WP 1-13, CDT-262)
- MUST register the GGUF model on the same `sqlite3` connection, in the same call, after the `.load` lines and before any `lembed()` call: `INSERT INTO temp.lembed_models(name, model) SELECT 'mini', lembed_model_from_file('<gguf>');`. `temp.lembed_models` is per connection, and every `sqlite3` invocation is its own connection. `embed-one.sh` and `migrate-md.sh` build the statement with `embed_lembed_register_sql` from `skills/memory-store/embed-common.sh`; `skills/memory-recall/SKILL.md` Step 4 sources the same file, resolved through `plugin-dir.sh`, and uses the same function; it has no copy (SPEC-006)
- MUST read a `lembed()` result as JSON in `migrate-md.sh` with `vec_to_json(lembed('mini', …))`: `lembed()` returns a BLOB and `json()` cannot hold a BLOB. In `migrate-md.sh`, sqlite3 stderr goes to a temp file, never into the captured vector: a call that succeeds but prints a warning still yields a clean vector
- MUST use `sqlite3 -bail` for the `embed-one.sh` lembed batch, so a failed registration never lets the vector INSERT run
- MUST handle both OpenAI (`.data[0].embedding`) and Ollama (`.embeddings[0]`) response shapes for remote mode
- MUST skip embedding gracefully if extensions or config unavailable (write memory without vector). `fallback` mode skips silently. In `lembed` or `remote` mode a failed embed — missing extension or model, sqlite error, provider error — MUST NOT be silent (next block)

#### Embed errors are logged (WP 1-13, CDT-262)
- MUST append one line per failed embed in `lembed` or `remote` mode to `<MROOT>/.claude/memory/.errors.log`: `<UTC ISO-8601> embed <site> <detail>`, where `<site>` is `embed-one` or `migrate-md` and `<detail>` is one line of at most 300 characters (`embed_log_error` in `embed-common.sh`). `embed-one.sh` callers send its stderr to `/dev/null`, so the log is the durable channel
- MUST keep `embed-one.sh` best-effort: it ALWAYS exits 0, and logging is fail-open (an unwritable log never fails the caller's write)
- MUST log every failed embed in `migrate-md.sh`, including an embedding whose dimension count is empty, `0` or not a number (`chunk N: invalid embedding dimensions`): a bare skip is not allowed. A failing `jq` MUST NOT abort the run. When `embed-common.sh` is missing next to `migrate-md.sh`, the script MUST print a warning on stderr, skip embedding and still import the `.md` files
- MUST keep `.errors.log` out of git: its `<detail>` is sqlite error text and can quote memory content. The `.claude/memory/*` child glob that `/setup team` Steps 3 and 5 ensure (SPEC-024 M9) covers it, so the log needs no entry of its own in the memory `.gitignore` block
- MUST surface the count — the lines whose second field is `embed` — in `/memory stats` (Embeddings block, `Embed errors:` line) and in `/doctor` (`memory.embed_errors`, SPEC-022 M2j)

#### SQL safety in the embedding write path (CDT-164)
- MUST apply the SQLite Write Path escaping rule ("MUST escape single quotes in all SQL content") to EVERY shell-expanded value interpolated into a SQL string literal in the embedding write path — including the embedding model name (`EMBED_MODEL`), not only memory content
- MUST apply any `:-default` fallback BEFORE escaping, so an empty model name still resolves to the documented default and that default is itself SQL-safe
- MUST NOT reuse the SQL-escaped form as the value sent to the embedding provider — the JSON request body carries the RAW model name via `jq --arg`; doubling quotes there would corrupt the provider request. The escaped form is SQL-only
- MUST NOT reject, validate-by-charset, or skip embedding solely because the model name contains a quote — `embed-one.sh` is best-effort and always exits 0, so quote handling is escaping, not validation. This deliberately differs from `EMBEDDING` and `DIMS`, which are network-derived (a vector literal and a table identifier respectively) and MAY be rejected

### Schema Migration (v1 → v2)
- MUST check `schema_version` before any changes (exit 0 if already v2, exit 1 if not v1)
- MUST execute all schema changes in a single transaction (atomic, no partial states)
- MUST disable foreign key checks during table rebuild
- MUST set existing data to tier=0, archived=false, distilled_from='[]' during migration
- MUST create indexes: idx_memories_agent, idx_memories_agent_type, idx_memories_tier
- MUST create distillation_log table
- MUST INSERT OR IGNORE default distill config keys: distill_enabled=false, distill_mode=suggest, distill_threshold=50, distill_model=haiku (idempotent)
- MUST update schema_version to "2" only after all steps complete, inside the same `BEGIN IMMEDIATE` transaction as the rebuild, `distillation_log`, and the distill config inserts (WP 3-07)
- MUST preserve `sqlite_sequence` for `memories` across the v2 rebuild so later inserts do not reuse ids
- MUST take `VACUUM INTO memory.db.bak-v<version>` before the first destructive migrate step
- MUST treat a failed `schema_version` read (locked database included) as a non-zero exit. An empty version is still the skip path

### .md → SQLite Migration
- MUST be idempotent (check existing row count before re-inserting)
- MUST chunk .md files by `##` headers (fallback: double-newline, then whole file)
- MUST truncate individual chunks (sections split by `##` headers) at 8000 chars and skip chunks under 20 chars
- MUST truncate the whole-file chunk (no-header fallback path) at 5000 chars
- MUST delete source .md files ONLY if all inserts succeeded (no partial deletions)
- MUST NOT migrate context.md (skip always)
- MUST generate embeddings for migrated content if extensions and config are present

## SHOULD

- SHOULD use heredoc for SQL content to avoid shell escaping issues
- SHOULD embed migrated content automatically when extensions are available
- SHOULD word failure warnings for multi-statement SQL batches to account for sqlite3 aborting every REMAINING statement after a parse error while earlier statements in the same batch stay committed — such a warning SHOULD NOT name one specific statement as the failure when the true outcome is partial

## Test

- Verify SQLite writes are append-only and readable back
- Verify .md fallback respects line limits for all 4 file types
- Verify context.md is never migrated or touched by SQLite operations
- Verify schema migration is atomic (all-or-nothing) and idempotent
- Verify .md→SQLite migration chunks by `##` headers correctly
- Verify chunk truncation at 8000 chars and skip under 20 chars
- Verify embedding generation handles both response shapes
- **Model-name SQL safety (CDT-164):** verify an embedding model name containing a single quote round-trips into `embedding_meta.model` verbatim and does not abort the sqlite batch. Manual verification is acceptable for this quote case. CDT-164 adds no harness. `skills/memory-store/test-migrate.sh` and `skills/memory-store/test-seed-pack.sh` already cover other memory-store checks.
- **Lembed registration (WP 1-13, CDT-262):** `bash skills/memory-store/test-embed-lembed.sh` runs `embed-one.sh` and `migrate-md.sh` in `lembed` mode against a fixture project and a `sqlite3` shim that refuses an unregistered model name, like the extension. It asserts that the registration comes after the `.load` lines and before every `lembed()` call, that the first argument of every `lembed()` call is `'mini'`, that a failed embed adds one line to `.errors.log` and still exits 0, and that a missing model or extension is logged. The suite downloads no extension and no model; a CI round-trip with a real model is deferred until a CI model download is approved
- **Migrate driver (CDT-51):** automated tests MUST cover (1) **fresh** install via `schema.sql` → `schema_version=4`; (2) **≥1 real upgrade floor** v3→v4 via `migrate-v4.sh` / `migrate.sh`. Full stepwise v1→v4 is OK because `migrate-v2/v3/v4` + `schema.sql` are in-repo (no git-history archaeology). Version reads MUST be PRAGMA-poison capture-safe (plain SELECT for `schema_version`; never capture an inline `PRAGMA` result row as the version)

## Validation

- [ ] `sqlite3 .claude/memory/memory.db "SELECT value FROM config WHERE key='schema_version'"` returns `"4"` after fresh `schema.sql` apply
- [ ] v3 fixture + migrate → `"4"` with no data loss on pre-seeded rows
- [ ] Migrated memories have tier=0, archived=false (v1→v2 path)
- [ ] context.md files remain untouched after migration
- [ ] No .md source files deleted if any INSERT failed
- [ ] With `embedding_mode=remote`, a model name containing an apostrophe (e.g. `o'brien-embed`) yields `embedding_meta.model = o'brien-embed` verbatim, a matching `vec_memories_<dims>` row, and an updated `config.embedding_dimensions` — no orphaned vector row (CDT-164)

- [ ] `bash skills/memory-store/test-embed-lembed.sh` exits 0: the model is registered before every `lembed('mini', …)` call, no call passes a path, and a failed embed leaves one line in `.claude/memory/.errors.log` (WP 1-13, CDT-262)

## Open Questions

- [x] ~~Is the 5000-char truncation on migration too aggressive?~~ **Resolved: Yes** — bumped to 8000 chars per chunk. A 100-line cortex file with dense content can easily exceed 5000 chars in a single `##` section.
- [ ] Should the busy_timeout be configurable, or is 5000ms always correct?
- [ ] The v2 migration adds `distilled_from` as TEXT (JSON array) — should this be a separate join table for referential integrity?

## Version History

| Date | Change |
|------|--------|
| 2026-10-02 | CDT-371 / CDT-391: schema is v4. Test harnesses `test-migrate.sh` and `test-seed-pack.sh` exist. Covers names them. |
| 2026-10-01 | WP 3-07: v2 rebuild, distillation_log, and the version bump share one `BEGIN IMMEDIATE`. `sqlite_sequence` is preserved. `migrate.sh` backs up with `VACUUM INTO` and fails when the version read fails. |
| 2026-09-30 | WP 1-13 (`wp-1-13-setup-team-lembed`; CDT-262 `[07 F-1]`): `lembed()` takes a registered model NAME, not a file path. The Embedding MUST "pass file path to GGUF model for lembed (not model name)" was wrong for sqlite-lembed v0.0.1-alpha.8: `lembed('<path>', …)` fails with "Unknown model name … Was it registered with lembed_models?", so no vector was stored or queried in the default local mode. The GGUF is now registered on the same connection, before `lembed()` (`INSERT INTO temp.lembed_models(name, model) SELECT 'mini', lembed_model_from_file('<gguf>')`); `migrate-md.sh` reads the result with `vec_to_json()` (a BLOB, not `json()`) and keeps sqlite3 stderr out of the vector (temp file); `embed-one.sh` and `migrate-md.sh` share `embed-common.sh`. A failed embed is no longer hidden: one line per failure in `<MROOT>/.claude/memory/.errors.log`, counted by `/memory stats` and `/doctor`. The CI round-trip smoke test with a real model is deferred until a CI model download is approved. Status stays ACTIVE. |
| 2026-08-09 | CDT-190: fixed the same `EMBED_MODEL` SQL-interpolation defect in `migrate-md.sh` that CDT-164 fixed for `embed-one.sh`. After model resolution (outside the per-row loop), apply `:-all-MiniLM-L6-v2` then single-quote-double into `EMBED_MODEL_ESC`; use that form only in the `embedding_meta` INSERT. Provider body still gets the raw name via `jq --arg`. |
| 2026-08-07 | CDT-164: added "SQL safety in the embedding write path" MUST block — `EMBED_MODEL` MUST be single-quote-escaped before interpolation into the `embedding_meta` INSERT in `embed-one.sh` (it was raw, violating the existing SQLite Write Path MUST at the top of this spec). An apostrophe in the model name aborted the remaining statements in the sqlite batch, leaving an orphaned `vec_memories_<dims>` row with no `embedding_meta` and skipping the `embedding_dimensions` UPDATE. Escaping is SQL-only — the provider JSON body keeps the raw name via `jq --arg`. Added SHOULD on partial-batch warning wording. `migrate-md.sh` carried the same defect (fixed in CDT-190). |
| 2026-07-22 | CDT-52 / CDT-46-C6: human-reviewed promote INFERRED→ACTIVE; evidence: Linear CDT-52 ship comment + /spec check exit-0. |
| 2026-07-22 | CDT-51 / CDT-46-C5: Covers + migrate-v3/v4; Test/Validation note for fresh + v3→v4 (full v1→v4 OK in-repo) and PRAGMA-poison-safe version capture. Status stays INFERRED (W5). migrate-v3/v4 ownership notes with SPEC-011 unchanged. |
| 2026-06-15 | Added `skills/memory-store/schema.sql` (the fresh-DB DDL — normative home for the schema) to Covers; it was orphaned. Added the `REFERENCES memories(id)` FK clause to `distillation_log.result_memory_id` (migrate-v2.sh) and `validation_log.memory_id` (migrate-v3.sh) so a migrated DB's log-table DDL matches schema.sql's fresh-create DDL exactly (`migrate-v3.sh` itself stays owned by SPEC-011) (AUDIT-P3.5a). |
| 2026-06-13 | Added "Agent Session-Write Protocol (single source of truth)" MUST — the write block is defined once in skills/memory-store + the canonical skills/agent-memory/protocol.md partial; the 7 behavioral agents carry a managed-inline copy (markers, sync-includes.py byte-check at /release) and MUST NOT hand-edit it. Confirmed the cortex 100/memory 50/lessons 80/context 60 line-limits MUST is the canonical copy (AUDIT-P1-1). |
| 2026-04-26 | Added MUST for whole-file (no-header) chunk truncation at 5000 chars — distinct from the 8000-char ## section limit. Added PRAGMA busy_timeout=5000 to migrate-v2.sh to satisfy the "every write" requirement. |
| 2026-03-23 | Bumped chunk truncation from 5000 to 8000 chars. Added context.md 60-line limit. Added default distill config values. Moved tier access control to SPEC-007. Moved distillation threshold check to SPEC-007. |
| 2026-03-22 | Initial spec generated by /generate-specs |
## Cross-references

- SPEC-005: Team Bootstrap — init-team triggers download-extensions.sh and migrate scripts
- SPEC-006: Memory Retrieval — reads what this spec writes
- SPEC-007: Memory Distillation — distiller writes tier 1/2; owns tier access control and threshold checks
- SPEC-003: Agent Role System — defines which agents write what memory types
