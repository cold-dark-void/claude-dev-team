# MEM-001: SQLite + Vector Embeddings for Agent Memory

**Date:** 2026-03-14
**Status:** COMPLETED — all 14 tasks done, QA passed, v0.12.0
**Ticket:** MEM-001

---

## Overview

Replace flat markdown agent memory files with a single SQLite database per project,
backed by sqlite-vec for vector search and sqlite-lembed/ollama for embeddings.
Agents interact via `sqlite3` CLI with `.load` extensions. Graceful fallback to .md
files if extensions are unavailable.

The plugin remains pure markdown/JSON/bash — no compiled code. All "implementation"
is prompt engineering (agent .md files), skill/command markdown, and bash scripts.

---

## Design Decisions

- **DB location:** `.claude/memory/memory.db` (shared across worktrees via git-common-dir)
- **context.md stays as .md** — per-worktree, ephemeral, not migrated
- **Multi-model embeddings:** `memory_embeddings` stores ALL embedding variants; lazy re-embed on model change
- **Binary download:** Direct from GitHub releases (sqlite-vec, sqlite-lembed) + HuggingFace (GGUF) during `/init-team`
- **Platforms:** Linux x86_64, Linux aarch64, macOS x86_64, macOS aarch64
- **Concurrency:** WAL mode + busy_timeout(5000) for parallel agent writes
- **Ollama probe:** One-time at init, stored in config table. Re-probe via `--refresh`

---

## Task Graph

### Phase 0: Foundation (no dependencies — all parallel)

```
[T1] Schema + DB init script
[T2] Binary download script
[T3] Memory-store skill (NEW)
[T4] Memory-recall skill (NEW)
     T3 and T4 depend on T1 (schema)
```

### Phase 1: Core Integration (depends on Phase 0)

```
[T5] Agent memory protocol rewrite (all 8 agents)  — depends on T1, T3, T4
[T6] /init-team updates                            — depends on T1, T2
[T7] Migration script (.md → SQLite)                — depends on T1
```

### Phase 2: Commands + Skills (depends on Phase 1)

```
[T8]  /memory-search command (NEW)          — depends on T4
[T9]  /mem-search update (keyword fallback) — depends on T1
[T10] /recall update                        — depends on T1
[T11] Skills update (6 skills)              — depends on T5
```

### Phase 3: Polish + Ship

```
[T12] README + AGENTS.md docs       — depends on T5, T8
[T13] Version bump + release files  — depends on all
[T14] QA validation                 — depends on all
```

---

## Task Details

### T1: Schema + DB init bash script
**Agent:** ic5
**Time:** ~5 min
**Files:**
- CREATE: `skills/memory-store/schema.sql` (reference schema, used by init)
- Inline in `skills/memory-store/SKILL.md` (agents read this)

**Schema:**
```sql
-- Core memory table
CREATE TABLE IF NOT EXISTS memories (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  agent TEXT NOT NULL,
  type TEXT NOT NULL CHECK(type IN ('cortex','memory','lessons')),
  content TEXT NOT NULL,
  metadata_json TEXT DEFAULT '{}',
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_memories_agent ON memories(agent);
CREATE INDEX IF NOT EXISTS idx_memories_type ON memories(agent, type);

-- Multi-model embedding table (sqlite-vec virtual table)
-- Created only when sqlite-vec extension is available
CREATE VIRTUAL TABLE IF NOT EXISTS memory_embeddings USING vec0(
  memory_id INTEGER,
  model TEXT,
  dimensions INTEGER,
  embedding FLOAT[384]
);

-- Config table for runtime state
CREATE TABLE IF NOT EXISTS config (
  key TEXT PRIMARY KEY,
  value TEXT,
  updated_at TEXT DEFAULT (datetime('now'))
);

-- Seed config
INSERT OR IGNORE INTO config(key, value) VALUES
  ('schema_version', '1'),
  ('embedding_provider', 'none'),
  ('embedding_model', 'none'),
  ('embedding_dimensions', '0');
```

**Note on vec0 dimensions:** The `FLOAT[384]` is the default for sqlite-lembed with
all-MiniLM-L6-v2. When ollama is detected with nomic-embed-text (768-dim), a second
virtual table `memory_embeddings_768` is created. Multi-model means multiple tables,
not a single polymorphic table — sqlite-vec requires fixed dimensions per table.

**Revised embedding strategy:**
```sql
-- For 384-dim (sqlite-lembed / all-MiniLM-L6-v2):
CREATE VIRTUAL TABLE IF NOT EXISTS vec_memories_384 USING vec0(
  memory_id INTEGER,
  embedding FLOAT[384]
);

-- For 768-dim (ollama / nomic-embed-text):
CREATE VIRTUAL TABLE IF NOT EXISTS vec_memories_768 USING vec0(
  memory_id INTEGER,
  embedding FLOAT[768]
);

-- Track which model produced which embeddings
CREATE TABLE IF NOT EXISTS embedding_meta (
  memory_id INTEGER NOT NULL,
  model TEXT NOT NULL,
  dimensions INTEGER NOT NULL,
  vec_table TEXT NOT NULL,
  created_at TEXT DEFAULT (datetime('now')),
  PRIMARY KEY (memory_id, model)
);
```

**DB init bash snippet** (agents will inline this):
```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
MEMDB="$MROOT/.claude/memory/memory.db"

# Init DB if needed (schema.sql is bundled in the skill)
if [ \! -f "$MEMDB" ]; then
  mkdir -p "$(dirname "$MEMDB")"
  sqlite3 "$MEMDB" < "$MROOT/skills/memory-store/schema.sql"
fi

# Enable WAL mode for concurrent agent access
sqlite3 "$MEMDB" "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;"
```

**Exposes:** DB path convention (`$MROOT/.claude/memory/memory.db`), schema contract,
init snippet that all other tasks depend on.

**Verification:** `sqlite3 $MEMDB ".tables"` shows `memories`, `config`, `embedding_meta`.
Vec tables only appear after extension load.

---

### T2: Binary download script
**Agent:** ic5
**Time:** ~5 min
**Files:**
- CREATE: `skills/memory-store/download-extensions.sh`

**What it does:**
1. Detect platform: `uname -s` + `uname -m` → `{linux,darwin}-{x86_64,aarch64}`
2. Download sqlite-vec shared lib from GitHub releases
   (`https://github.com/asg017/sqlite-vec/releases/download/v0.1.6/...`)
3. Download sqlite-lembed shared lib from GitHub releases
   (`https://github.com/asg017/sqlite-lembed/releases/download/v0.0.1-alpha.2/...`)
4. Download GGUF model from HuggingFace
   (`https://huggingface.co/asg017/sqlite-lembed-models/resolve/main/all-MiniLM-L6-v2/ggml-model-f16.gguf`)
5. Store all binaries in `$MROOT/.claude/memory/extensions/`
6. Probe for ollama: `curl -s http://localhost:11434/api/tags | grep nomic-embed-text`
7. Store probe result in config table

**Platform mapping (sqlite-vec example):**
```bash
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)   PLATFORM="linux-x86_64" ;;
  Linux-aarch64)  PLATFORM="linux-aarch64" ;;
  Darwin-x86_64)  PLATFORM="macos-x86_64" ;;
  Darwin-arm64)   PLATFORM="macos-aarch64" ;;
  *) echo "Unsupported platform"; exit 1 ;;
esac
```

**Directory layout after download:**
```
.claude/memory/extensions/
├── vec0.so          (or vec0.dylib on macOS)
├── lembed0.so       (or lembed0.dylib)
└── models/
    └── all-MiniLM-L6-v2.gguf
```

**Exposes:** Extension paths, ollama availability in config table.

**Verification:** `ls -la $MROOT/.claude/memory/extensions/` shows 3 files. File sizes
are non-zero. `sqlite3 :memory: ".load $EXT_DIR/vec0" "SELECT vec_version();"` returns
a version string.

**Depends on:** T1 (config table for ollama probe result)

---

### T3: Memory-store skill (NEW)
**Agent:** ic5
**Time:** ~5 min
**Files:**
- CREATE: `skills/memory-store/SKILL.md`
- CREATE: `skills/memory-store/schema.sql` (if not already from T1)

**What it does:**
Teaches agents how to write memory to the DB. The skill provides:

1. **Path resolution + DB detection** (try DB, fall back to .md)
```bash
MEMDB="$MROOT/.claude/memory/memory.db"
if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
  USE_DB=true
else
  USE_DB=false  # fallback to .md
fi
```

2. **Store a memory (DB path):**
```bash
sqlite3 "$MEMDB" "INSERT INTO memories(agent, type, content, metadata_json)
  VALUES ('$AGENT', '$TYPE', '$CONTENT', '$META');"
```

3. **Store a memory (fallback .md path):**
Write to `$MROOT/.claude/memory/$AGENT/$TYPE.md` as before.

4. **Generate embedding after store** (if extensions available):
```bash
EXT_DIR="$MROOT/.claude/memory/extensions"
if [ -f "$EXT_DIR/vec0.so" ] || [ -f "$EXT_DIR/vec0.dylib" ]; then
  # Load extension and insert embedding
  PROVIDER=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='embedding_provider';")
  if [ "$PROVIDER" = "lembed" ]; then
    sqlite3 "$MEMDB" <<SQL
.load $EXT_DIR/vec0
.load $EXT_DIR/lembed0
INSERT INTO vec_memories_384(memory_id, embedding)
  SELECT last_insert_rowid(), lembed('$CONTENT');
INSERT INTO embedding_meta(memory_id, model, dimensions, vec_table)
  VALUES (last_insert_rowid(), 'all-MiniLM-L6-v2', 384, 'vec_memories_384');
SQL
  elif [ "$PROVIDER" = "ollama" ]; then
    # Use ollama API for embedding
    EMBEDDING=$(curl -s http://localhost:11434/api/embeddings \
      -d "{\"model\":\"nomic-embed-text\",\"prompt\":$(echo "$CONTENT" | jq -Rs .)}" \
      | jq -c '.embedding')
    # Insert into 768-dim table via sqlite3
    # (exact syntax depends on sqlite-vec's insert format)
  fi
fi
```

5. **Concurrency guard:**
```bash
# WAL mode + busy_timeout already set at init
# But if we get SQLITE_BUSY, retry once after 1s
sqlite3 "$MEMDB" "..." || { sleep 1; sqlite3 "$MEMDB" "..."; }
```

**Exposes:** `memory-store` skill interface — agents call this to persist knowledge.
Contract: agent name, type (cortex|memory|lessons), content string, optional metadata JSON.

**Verification:** After storing, `sqlite3 "$MEMDB" "SELECT count(*) FROM memories WHERE agent='test';"` returns 1.

**Depends on:** T1

---

### T4: Memory-recall skill (NEW)
**Agent:** ic5
**Time:** ~5 min
**Files:**
- CREATE: `skills/memory-recall/SKILL.md`

**What it does:**
Teaches agents how to read/search memory from the DB. Three modes:

1. **Load all memory for this agent** (session start):
```bash
sqlite3 "$MEMDB" "SELECT type, content FROM memories
  WHERE agent='$AGENT' ORDER BY type, updated_at DESC;"
```

2. **Keyword search** (cross-agent, grep equivalent):
```bash
sqlite3 "$MEMDB" "SELECT agent, type, content FROM memories
  WHERE content LIKE '%$QUERY%' ORDER BY updated_at DESC LIMIT 20;"
```

3. **Semantic search** (requires extensions):
```bash
EXT_DIR="$MROOT/.claude/memory/extensions"
sqlite3 "$MEMDB" <<SQL
.load $EXT_DIR/vec0
.load $EXT_DIR/lembed0
SELECT m.agent, m.type, m.content,
       vec_distance_cosine(e.embedding, lembed('$QUERY')) AS distance
FROM vec_memories_384 e
JOIN memories m ON m.id = e.memory_id
ORDER BY distance ASC
LIMIT 10;
SQL
```

4. **Fallback (.md path):**
If DB unavailable, grep `.claude/memory/*/` as current behavior.

5. **Agent filter:**
Default: search ALL agents. Optional: `WHERE agent='$FILTER_AGENT'`

**Exposes:** `memory-recall` skill interface — agents call this to load context or search.
Contract: query string, optional agent filter, returns content + distance score.

**Verification:** Store a test memory via T3, then recall it by keyword and by semantic
search. Semantic should rank it high.

**Depends on:** T1, T3 (needs data to search)

---

### T5: Agent memory protocol rewrite (all 8 agents)
**Agent:** ic4
**Time:** ~5 min (repetitive, pattern-based across 8 files)
**Files:**
- MODIFY: `agents/pm.md`
- MODIFY: `agents/tech-lead.md`
- MODIFY: `agents/ic5.md`
- MODIFY: `agents/ic4.md`
- MODIFY: `agents/devops.md`
- MODIFY: `agents/qa.md`
- MODIFY: `agents/ds.md`
- MODIFY: `agents/project-init.md`

**What changes:**
Replace the "Persistent Memory" section in each agent. The new section:

1. **Path resolution** — same `MROOT`/`WTROOT` as today, plus DB detection:
```bash
MEMDB="$MROOT/.claude/memory/memory.db"
USE_DB=false
if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
  USE_DB=true
fi
```

2. **Session start protocol** — try DB first, fall back to .md:
```
If USE_DB=true:
  1. Load cortex:   sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='<name>' AND type='cortex' ORDER BY updated_at DESC;"
  2. Load memory:   sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='<name>' AND type='memory' ORDER BY updated_at DESC;"
  3. Load lessons:  sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='<name>' AND type='lessons' ORDER BY updated_at DESC;"
  4. Read context:  cat "$AGENT_CTX/context.md" (still .md, per-worktree)

If USE_DB=false:
  Same as today — read the 4 .md files.
```

3. **Memory writes** — same dual-path:
```
If USE_DB=true:
  Use memory-store skill to INSERT/UPDATE.
  UPDATE: sqlite3 "$MEMDB" "UPDATE memories SET content='...', updated_at=datetime('now') WHERE agent='<name>' AND type='<type>';"

If USE_DB=false:
  Write to .md files as before.
```

4. **context.md** — unchanged. Still .md, still per-worktree.

5. **Memory file size budget** — replaced with a note:
```
When using SQLite: no line limits. The DB handles storage.
When using .md fallback: same limits as before (cortex 100, memory 50, lessons 80, context 60).
```

6. **Permissions** — add `sqlite3` to the project-init settings.json allowlist:
```
"Bash(sqlite3:*)"
```

**Pattern:** The change is structurally identical across all 8 agents. Only the agent name
string changes. IC4 can do this as a pattern-replication task.

**Exposes:** Updated agent protocol. All skills that read agent context must understand
the new dual-path.

**Verification:** Diff each agent file. Confirm the Persistent Memory section has DB
detection, dual-path read, dual-path write, and context.md unchanged.

**Depends on:** T1 (schema), T3 (memory-store skill reference), T4 (memory-recall reference)

---

### T6: /init-team updates
**Agent:** ic5
**Time:** ~5 min
**Files:**
- MODIFY: `commands/init-team.md`
- MODIFY: `agents/project-init.md`

**What changes:**

1. **init-team.md** — add step before invoking project-init:
   - Run `download-extensions.sh` to fetch sqlite-vec, sqlite-lembed, GGUF model
   - Run DB init (create memory.db, apply schema)
   - Probe for ollama and store result in config
   - Report: "SQLite memory initialized" or "Extensions unavailable, using .md fallback"

2. **project-init.md** — after scanning the project:
   - If DB is available: INSERT cortex records into `memories` table instead of writing .md
   - If DB is unavailable: write .md files as before (current behavior)
   - Add `"Bash(sqlite3:*)"` and `"Bash(curl:*)"` to the permissions allowlist

3. **Add `--refresh` flag handling:**
   - Re-probe ollama
   - Re-download extensions if missing
   - Re-run migration if .md files exist but DB rows don't

**Exposes:** Fully initialized memory.db with extensions and cortex data after running
`/init-team`.

**Verification:** Run `/init-team` on a test project. Check that `memory.db` exists,
has cortex rows for all 7 agents, and extensions load successfully.

**Depends on:** T1, T2

---

### T7: Migration script (.md to SQLite)
**Agent:** ic5
**Time:** ~5 min
**Files:**
- CREATE: `skills/memory-store/migrate-md.sh`

**What it does:**
1. Scan `$MROOT/.claude/memory/*/` for .md files (excluding context.md)
2. For each `{agent}/{type}.md`:
   - Read file content
   - INSERT into memories table: `agent`, `type` (from filename minus .md), `content` (full file)
   - Generate embedding if extensions available
3. Validate: for each migrated file, confirm row exists in DB with matching content
4. After validation passes: rename originals to `{type}.md.bak` (do NOT delete yet)
5. Print summary: "Migrated N files for M agents. Originals backed up as .md.bak"

**Migration record granularity decision:**
Each .md file becomes ONE row in `memories`. This preserves the current "one file = one
knowledge unit" model. Future phases can add finer-grained chunking. For now, a cortex.md
file (up to 100 lines) is a single searchable unit — this is fine for ~38 files.

**Rollback:** If anything fails mid-migration, the .md files are untouched (we only
rename after full validation). User can re-run migration to retry.

**Re-migration on /init-team:** If .md files exist AND DB rows exist for the same agent+type,
skip that file (idempotent). If .md files exist but no DB rows, migrate. This makes
`/init-team --refresh` safe to re-run.

**Exposes:** Migration script callable from /init-team and standalone.

**Verification:** Create test .md files, run migration, verify DB rows match, verify .md.bak
files exist.

**Depends on:** T1

---

### T8: /memory-search command (NEW)
**Agent:** ic4
**Time:** ~3 min
**Files:**
- CREATE: `commands/memory-search.md`

**What it does:**
User-facing semantic search command. Uses memory-recall skill internally.

```
/memory-search <query>
```

1. Resolve DB path
2. If DB + extensions available: run semantic search (cosine distance) across all agents
3. If DB available but no extensions: run keyword search (`LIKE '%query%'`)
4. If no DB: fall back to grep across .md files (same as current /mem-search)
5. Output format:
```
=== MEMORY SEARCH: <query> ===================================

@tech-lead / cortex (distance: 0.12):
  <matching content snippet>

@ic5 / lessons (distance: 0.18):
  <matching content snippet>

@pm / memory (distance: 0.24):
  <matching content snippet>

============================================================
Results: 3 semantic matches (threshold: 0.5)
Provider: sqlite-lembed (all-MiniLM-L6-v2, 384-dim)
```

**Exposes:** `/memory-search` slash command.

**Verification:** Store test memories, search for a semantically related but not
keyword-identical query. Verify results are ranked by relevance.

**Depends on:** T4 (memory-recall skill)

---

### T9: /mem-search update (keyword fallback)
**Agent:** ic4
**Time:** ~3 min
**Files:**
- MODIFY: `commands/mem-search.md`

**What changes:**
Add DB keyword search path before the grep fallback:

1. If DB available: `SELECT agent, type, content FROM memories WHERE content LIKE '%$ARGS%'`
2. If no DB: grep .md files (current behavior)
3. Add note at top: "For semantic search, use `/memory-search`"

**Depends on:** T1

---

### T10: /recall update
**Agent:** ic4
**Time:** ~3 min
**Files:**
- MODIFY: `commands/recall.md`

**What changes:**
In "Step 2C: Agent Memory Files" section, add DB search path:

1. If DB available: search `memories` table
2. If no DB: grep .md files (current behavior)

Rest of recall (history.jsonl, git log, specs, plans, backlog) unchanged.

**Depends on:** T1

---

### T11: Skills update (6 skills that read memory)
**Agent:** ic4
**Time:** ~5 min (repetitive, 6 files)
**Files:**
- MODIFY: `skills/orchestrate/SKILL.md` (lines 31-33: reads cortex/memory)
- MODIFY: `skills/kickoff/SKILL.md` (lines 42-44: reads cortex/memory)
- MODIFY: `skills/brainstorm/SKILL.md` (lines 33-34: reads cortex)
- MODIFY: `skills/standup/SKILL.md` (line 53: reads context.md — NO CHANGE needed, context stays .md)
- MODIFY: `skills/wrap-ticket/SKILL.md` (lines 66-70: reads context, 95+109: reads/writes claude/memory.md)
- MODIFY: `skills/scaffold-project/SKILL.md` (lines 49, 119-131: creates memory dir and seeds memory)
- MODIFY: `skills/init-orchestration/SKILL.md` (line 345-348: creates/seeds claude memory)

**Pattern for each:**
Where the skill currently does `cat $PROOT/.claude/memory/tech-lead/cortex.md`:
```bash
MEMDB="$PROOT/.claude/memory/memory.db"
if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
  sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='tech-lead' AND type='cortex';"
else
  cat "$PROOT/.claude/memory/tech-lead/cortex.md" 2>/dev/null
fi
```

**standup note:** Standup reads context.md which stays as .md. No change needed for
context reads. But if standup also surfaces memory, add the DB path.

**wrap-ticket note:** wrap-ticket writes to `claude/memory.md`. Update to write to DB
when available, fall back to .md.

**scaffold-project + init-orchestration note:** These create the memory directory and seed
initial memory. Update to also create memory.db and insert seed rows when sqlite3 is
available.

**Depends on:** T5 (agent protocol must be updated first so the pattern is established)

---

### T12: README + AGENTS.md docs update
**Agent:** ic4
**Time:** ~3 min
**Files:**
- MODIFY: `README.md`
- MODIFY: `AGENTS.md`

**README changes:**
1. Update the "four persistent memory files" table to document dual storage:
   ```
   | Storage | When | Description |
   |---------|------|-------------|
   | SQLite DB | After `/init-team` with extensions | Single DB at .claude/memory/memory.db |
   | .md files | Fallback (no sqlite3 or extensions) | Same as before at .claude/memory/{agent}/ |
   | context.md | Always | Per-worktree task progress (never migrated) |
   ```
2. Add `/memory-search` to the commands table
3. Update Quick Start to mention extension download
4. Note the ~50MB download for extensions + model

**AGENTS.md changes:**
1. Update "Persistent Memory Protocol" section with dual-path
2. Add `sqlite3` to the common bash permission patterns
3. Note that context.md remains per-worktree .md

**Depends on:** T5, T8

---

### T13: Version bump + release files
**Agent:** ic4
**Time:** ~2 min
**Files:**
- MODIFY: `README.md` (version section)
- MODIFY: `.claude-plugin/plugin.json` (version field)
- MODIFY: `.claude-plugin/marketplace.json` (version field)

Bump to v0.12.0 (minor — new feature).

**Depends on:** All other tasks complete

---

### T14: QA validation
**Agent:** qa
**Time:** ~5 min
**What:**

1. **Schema validation:** Create a fresh memory.db from schema.sql. Verify tables, indexes, constraints.
2. **Store + recall round-trip:** Use memory-store skill to insert, memory-recall to read back.
3. **Migration test:** Create test .md files, run migrate-md.sh, verify DB contents, verify .md.bak.
4. **Fallback test:** Remove memory.db, verify agents fall back to .md reads/writes.
5. **Concurrent write test:** Two parallel `sqlite3` writes to same DB in WAL mode — both succeed.
6. **Cross-agent search:** Store memories for 3 agents, search without filter, verify all returned.
7. **Agent filter:** Search with agent filter, verify only that agent's memories returned.
8. **Extension load test:** Load vec0, verify `vec_version()` returns. Load lembed0, verify embedding generation.
9. **Platform detection:** Run download script on current platform, verify correct binary downloaded.
10. **Semantic search test:** Store 3 memories with distinct topics, query for one topic, verify ranking.
11. **Command validation:** Run `/memory-search`, `/mem-search`, `/recall` — all work with DB and without.
12. **Agent .md diff:** Every agent file has DB detection, dual-path read, dual-path write.

**Depends on:** All other tasks

---

## Dependency Graph (visual)

```
T1 (schema) ──────┬──── T3 (memory-store) ──┬──── T5 (agent rewrite) ──── T11 (skills update)
                   │                         │                              │
                   ├──── T4 (memory-recall) ─┤                              ├──── T12 (docs)
                   │                         │                              │
                   ├──── T7 (migration) ─────┘                              └──── T13 (version bump)
                   │                                                               │
T2 (download) ────┴──── T6 (/init-team) ───────────────────────────────────────────┤
                                                                                   │
                        T8 (/memory-search) ── depends on T4                       │
                        T9 (/mem-search) ───── depends on T1                       │
                        T10 (/recall) ──────── depends on T1                       │
                                                                                   │
                                                                            T14 (QA) ── depends on ALL
```

**Maximum parallelism:**
- Wave 1: T1, T2 (parallel)
- Wave 2: T3, T4, T7, T9, T10 (parallel, all depend only on T1)
- Wave 3: T5, T6, T8 (parallel; T5 depends on T3+T4, T6 on T1+T2, T8 on T4)
- Wave 4: T11 (depends on T5)
- Wave 5: T12, T13 (parallel, depend on T5+T8 / all)
- Wave 6: T14 (QA, depends on all)

**Critical path:** T1 → T3 → T5 → T11 → T12 → T13 → T14

---

## Binary Distribution Strategy (T2, detailed)

### What gets downloaded

| Artifact | Source | Size | Format |
|----------|--------|------|--------|
| sqlite-vec v0.1.6 | `github.com/asg017/sqlite-vec/releases` | ~2MB | Platform-specific .so/.dylib in .tar.gz |
| sqlite-lembed v0.0.1-alpha.2 | `github.com/asg017/sqlite-lembed/releases` | ~3MB | Platform-specific .so/.dylib in .tar.gz |
| all-MiniLM-L6-v2 GGUF | `huggingface.co/asg017/sqlite-lembed-models` | ~24MB | Single .gguf file |

Total: ~29MB (not 50MB — corrected after checking actual release sizes).

### Download mechanics

```bash
# Detect platform
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
[ "$ARCH" = "arm64" ] && ARCH="aarch64"

# Target directory
EXT_DIR="$MROOT/.claude/memory/extensions"
mkdir -p "$EXT_DIR/models"

# Download with curl, verify with sha256
curl -fSL "$VEC_URL" -o "$EXT_DIR/vec0.$EXT"
curl -fSL "$LEMBED_URL" -o "$EXT_DIR/lembed0.$EXT"
curl -fSL "$GGUF_URL" -o "$EXT_DIR/models/all-MiniLM-L6-v2.gguf"

# Verify extensions load
sqlite3 :memory: ".load $EXT_DIR/vec0" "SELECT vec_version();" || {
  echo "WARNING: sqlite-vec failed to load. Falling back to .md memory."
  rm -rf "$EXT_DIR"
}
```

### Failure modes

1. **No internet:** Skip download, fall back to .md. Print: "No network — using .md memory files."
2. **Download fails:** Same fallback. Print specific error.
3. **Extension won't load:** Delete downloaded files, fall back. Common cause: glibc version mismatch on old Linux. Print: "Extension incompatible with this system."
4. **sqlite3 not installed:** Fall back to .md. Print: "sqlite3 not found. Install it for SQLite memory, or continue with .md files."

### .gitignore

Add to project `.gitignore` (or document in README):
```
.claude/memory/extensions/
.claude/memory/memory.db
.claude/memory/memory.db-wal
.claude/memory/memory.db-shm
```

---

## Future Phases

### v2: HTTP Daemon + Cross-Project DB + Tiered Distillation
- **HTTP daemon:** Long-running local process that holds the DB open, serves a REST API.
  Agents hit `localhost:PORT` instead of shelling out to sqlite3. Eliminates extension
  loading overhead per query. Enables streaming responses.
- **Cross-project DB:** `~/.claude/memory/global.db` aggregates learnings across projects.
  Federated search: query project DB first, then global DB for broader context.
- **Tiered distillation:** `/memory-distill` command that:
  1. Reads all raw memories for an agent
  2. Uses LLM to synthesize into a compressed "long-term memory"
  3. Stores distilled version, archives originals
  4. Reduces noise in agent context loading

### v3: Docker Distribution
- Package sqlite3 + extensions + model in a lightweight container
- `docker run --rm -v $MROOT/.claude/memory:/data memory-server`
- Eliminates all platform-specific binary concerns
- Enables GPU-accelerated embeddings via ollama sidecar

---

## Risk Mitigation

| Risk | Mitigation |
|------|-----------|
| sqlite-lembed instability | .md fallback is always available; extensions are optional |
| Agent emits bad SQL | Skills provide exact SQL templates; agents fill in parameters |
| WAL busy under load | busy_timeout(5000) + one retry; worst case a write is delayed 5s |
| Embedding dim mismatch | Separate vec tables per dimension; lazy re-embed on model change |
| Large download on init | Warn user of ~29MB download; make it skippable with --no-extensions |
| Migration data loss | Validate before renaming; keep .md.bak; re-migration is idempotent |

---

## Task Map

- Task 1 (id:1): T1 — Schema + DB init script → ic5 [ready]
- Task 2 (id:2): T2 — Binary download script → ic5 [blocked by: T1]
- Task 3 (id:3): T3 — memory-store skill → ic5 [blocked by: T1]
- Task 4 (id:4): T4 — memory-recall skill → ic5 [blocked by: T1, T3]
- Task 5 (id:5): T5 — Agent memory protocol rewrite (8 agents) → ic4 [blocked by: T1, T3, T4]
- Task 6 (id:6): T6 — /init-team updates → ic5 [blocked by: T1, T2]
- Task 7 (id:7): T7 — Migration script → ic5 [blocked by: T1]
- Task 8 (id:8): T8 — /memory-search command → ic4 [blocked by: T4]
- Task 9 (id:9): T9 — /mem-search update → ic4 [blocked by: T1]
- Task 10 (id:10): T10 — /recall update → ic4 [blocked by: T1]
- Task 11 (id:11): T11 — Update 6 skills → ic4 [blocked by: T5]
- Task 12 (id:12): T12 — README + AGENTS.md docs → ic4 [blocked by: T5, T8]
- Task 13 (id:13): T13 — Version bump v0.12.0 → ic4 [blocked by: all]
- Task 14 (id:14): T14 — QA validation → qa [blocked by: all]

## Spec

Full acceptance criteria: `.claude/plans/2026-03-14-spec-mem-001.md`
