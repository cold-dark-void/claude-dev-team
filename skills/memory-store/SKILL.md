---
name: memory-store
description: |
    Write agent memories to the SQLite database (or fall back to .md files). Handles
    DB detection, SQL-safe INSERT/UPDATE, optional embedding generation (lembed or
    remote embedding provider), and retry on SQLITE_BUSY. Usage: read this file to
    learn the protocol, then execute the relevant bash blocks.
---

# memory-store

Write a memory record for an agent. Supports both the SQLite DB path (preferred) and
the legacy `.md` file fallback when the DB or sqlite3 are unavailable.

---

## Step 1: Resolve paths and detect storage mode

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
EXT_DIR="$MROOT/.claude/memory/extensions"

# Determine storage mode
USE_DB=false
if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
  USE_DB=true
fi
```

---

## Step 2: Store a memory (DB path)

Replace `<AGENT>`, `<TYPE>`, and `<CONTENT_ESCAPED>` with real values.
`<TYPE>` must be one of: `cortex`, `memory`, `lessons`, `digest`, `core`.

> **Tier note:** Regular agent writes are always tier 0 (the column defaults to 0 and
> agents do not specify it). Types `digest` and `core` with tier 1/2 are written only
> by the `@distiller` agent during `/memory-distill`.
>
> **Host-script elevated write (SPEC-024 M5):** `import-seed-pack.sh` (invoked only from
> `/init-team` Step 5.5) may INSERT `tier=1`, `type='digest'`, `distilled_from='[]'`, and
> a provenance `metadata_json` seed object. This is a narrow host-script carve-out —
> behavioral agents remain forbidden from setting `tier > 0`. See also SPEC-007.

**Write protocol: append-only — one focused fact per INSERT.**

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
# APPEND a focused memory entry (one fact, decision, or lesson per INSERT)
ESCAPED=$(printf '%s' "$CONTENT" | sed "s/'/''/g")
sqlite3 "$MEMDB" "PRAGMA busy_timeout=5000; INSERT INTO memories(agent, type, content) VALUES ('<AGENT>', '<TYPE>', '$ESCAPED');"
```

**Use heredoc for multi-line content** to avoid shell quoting issues:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
sqlite3 "$MEMDB" <<'EOSQL'
INSERT INTO memories(agent, type, content) VALUES (
  'tech-lead',
  'cortex',
  'Cache: sharded LRU in internal/cache/, keys sha256(model+prompt), TTL 1h default'
);
EOSQL
```

**Capture the new row ID in the same session** (needed for embedding — see Step 4):
```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
MEMORY_ID=$(sqlite3 "$MEMDB" "INSERT INTO memories(agent, type, content)
  VALUES ('<AGENT>', '<TYPE>', '$ESCAPED');
  SELECT last_insert_rowid();")
```

> Note: `last_insert_rowid()` MUST be called within the same sqlite3 session as the
> INSERT. A separate `sqlite3 "$MEMDB" "SELECT last_insert_rowid();"` call will return
> 0 because each invocation is an independent connection.

---

### What makes a good memory entry

Each INSERT should capture ONE focused piece of knowledge:
- A specific architectural fact: `"Cache uses sharded LRU with per-shard locks, max size via PROJECT_CACHE_SIZE"`
- A key decision: `"Chose SQLite over Postgres for simplicity — no server needed"`
- A lesson learned: `"NEVER mock the database — prod migration broke despite green mocked tests"`
- A pattern to follow: `"All backends implement the Project interface in internal/backend/"`

Do NOT write:
- Entire codebase maps as one entry (break into per-subsystem entries)
- Multi-topic paragraphs (split into separate INSERTs)
- Duplicate entries (search first with memory-recall before writing)

---

## Step 3: Store a memory (fallback .md path)

Use this branch when `USE_DB=false` (DB file absent or sqlite3 not installed).

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
AGENT_MEM="$MROOT/.claude/memory/<AGENT>"
mkdir -p "$AGENT_MEM"
cat >> "$AGENT_MEM/<TYPE>.md" << 'EOF'
<content>
EOF
echo "[memory-store] DB unavailable — writing to .md fallback."
```

`<TYPE>` maps to the filename: `cortex.md`, `memory.md`, or `lessons.md`.

---

## Step 4: Generate embedding after store (delegated to `embed-one.sh`)

After the Step 2 INSERT has captured `$MEMORY_ID`, generate the embedding with the
shared **`embed-one.sh`** helper (a sibling of this skill). It self-derives the
extensions/model paths from the DB, reads `embedding_mode` / `embedding_url` from
the `config` table, and is **best-effort**: it ALWAYS exits 0 and silently skips
when the mode is `fallback` or the required extensions/models are absent — so it
never breaks the write.

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
bash skills/memory-store/embed-one.sh "$MEMDB" "$MEMORY_ID" "$CONTENT"  # lint-ok: C1
```

The lembed (local GGUF) and remote (OpenAI-compatible) provider logic — formerly
inline here — now lives in `embed-one.sh`, shared with the agent memory-write
path. (`skills/memory-store/migrate-md.sh` is a separate, bulk-migration path
that inlines its own embedding logic — it is not a caller of `embed-one.sh`.)
Consumers resolve the skill's own directory via the plugin-dir bootstrap
(SPEC-002, "Locating `plugin-dir.sh` itself"); `embed-one.sh` sits alongside this file.


## Step 5: Retry on SQLITE_BUSY

WAL mode is set at DB init, but `busy_timeout` is a per-connection setting.
Always prepend `PRAGMA busy_timeout=5000;` to write operations. For the rare
case of a hard lock, retry once:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
sqlite3 "$MEMDB" "PRAGMA busy_timeout=5000; INSERT ..." || { sleep 1; sqlite3 "$MEMDB" "PRAGMA busy_timeout=5000; INSERT ..."; }
```

---

## Step 5.5: Post-store threshold check

After a successful INSERT, check whether the agent's raw memory count has exceeded
the distillation threshold. This only fires when `distill_enabled=true` — otherwise
zero extra queries are issued.

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
# Threshold check (skip if distill_enabled=false)
DISTILL_ENABLED=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='distill_enabled';")
if [ "$DISTILL_ENABLED" = "true" ]; then
  DISTILL_MODE=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='distill_mode';")
  if [ "$DISTILL_MODE" != "manual" ]; then
    THRESHOLD=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='distill_threshold';")
    COUNT=$(sqlite3 "$MEMDB" "SELECT COUNT(*) FROM memories WHERE agent='<AGENT>' AND tier=0 AND archived=FALSE;")
    if [ "$COUNT" -ge "$THRESHOLD" ]; then
      echo "[memory] @<AGENT> has $COUNT raw memories (threshold: $THRESHOLD). Run /memory-distill to compress."
    fi
  fi
fi
```

---

## Step 6: Verify the write

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
sqlite3 "$MEMDB" \
  "SELECT id, agent, type, length(content), created_at
   FROM memories ORDER BY id DESC LIMIT 1;"
```

Expected output format: `<id>|<agent>|<type>|<bytes>|<timestamp>`

---

## Interface summary

| Parameter | Required | Values | Description |
|-----------|----------|--------|-------------|
| agent | yes | string | Agent name (e.g., `tech-lead`, `ic5`) |
| type | yes | `cortex`, `memory`, `lessons`, `digest`, `core` | Memory type — must match CHECK constraint |
| content | yes | string | Text content to store |
| metadata | no | JSON object string | Arbitrary key-value metadata; defaults to `{}` |
| tier | no (DB default) | `0`, `1`, `2` | Memory tier — defaults to 0. Agents never set this; tier 1/2 is written by `@distiller` only |

---

## Design notes

- This skill handles BOTH the DB path and the `.md` fallback transparently. Always
  check `USE_DB` before choosing which path to take.
- SQL escaping is the agent's responsibility: every `'` in content must become `''`
  before string interpolation. Heredoc syntax sidesteps this for static content.
- `last_insert_rowid()` must be in the same sqlite3 session as the INSERT or it
  returns 0 (each `sqlite3` invocation is a separate connection).
- `lembed()` takes a **file path** to the GGUF model, not a model name string.
- For `remote` mode, set `embedding_url` in the config table and optionally export
  `EMBEDDING_API_KEY` and `EMBEDDING_MODEL`. The response parser handles both OpenAI
  (`data[0].embedding`) and ollama-style (`embeddings[0]` / `embedding`) shapes.
  `remote` mode skips the lembed0 extension + GGUF model needed to **compute**
  embeddings, but the `vec0` extension is still required to **store** and query
  them; if `vec0` is absent (e.g. `--no-extensions`), `embed-one.sh` computes the
  embedding, logs a one-line stderr warning, and skips the store (the write still
  succeeds — only the vector is lost).
- The vec0 virtual tables (`vec_memories_384`, `vec_memories_768`) are created only
  when the sqlite-vec extension is loaded; they are absent from a plain `schema.sql`
  apply. Agents must guard all vec0 operations with an extension availability check.
- **Distill threshold short-circuit:** When `distill_enabled=false` (the default), the
  post-store threshold check (Step 5.5) issues exactly one SELECT and exits immediately.
  Zero additional queries are run, so there is no performance impact on normal writes.
