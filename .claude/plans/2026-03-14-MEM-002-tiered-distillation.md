# MEM-002: 3-Layer Tiered Memory Distillation

**Date:** 2026-03-14
**Status:** PLANNED — awaiting implementation
**Ticket:** MEM-002
**Version target:** v0.13.0 (minor — new feature, schema change, 2 new commands)

---

## Overview

Add a 3-layer tiered memory system to the SQLite memory backend. Layer 0 (raw memories,
current behavior), Layer 1 (LLM-compressed digests), Layer 2 (promoted core knowledge).
Distillation is a self-prompt pattern: the agent reads raw memories and writes a
synthesized digest as part of its own output. No external API call needed.

Auto-trigger modes: `manual` (only via /memory-distill), `suggest` (print notice after
store when threshold exceeded — DEFAULT), `auto` (wrap-ticket triggers distillation at
end of session).

---

## Design Decisions

- **Tier column:** `INTEGER DEFAULT 0 CHECK(tier IN (0, 1, 2))` on `memories` table
- **Archived column:** `BOOLEAN DEFAULT FALSE` — soft-archive, never delete raw memories
- **Type constraint expanded:** `CHECK(type IN ('cortex','memory','lessons','digest','core'))`
- **Distillation lock:** `distilling_lock` key in `config` table — prevents concurrent distills
- **Batch size:** configurable `distill_threshold` (default 50 tier-0 per agent)
- **Embeddings:** kept for archived rows, filtered at query time via `WHERE archived=FALSE`
- **Recall tiers:** tier 2 always loaded at boot, tier 1 by search, tier 0 by deep search
- **Fallback:** distillation unavailable in .md mode — prints error and exits
- **Schema version:** bumped from 1 to 2
- **Version:** 0.13.0 (not 0.12.1 — this is a new feature, not a patch)

---

## Task Graph

### Wave 1: Schema + Migration (no dependencies — foundation)

```
[T1] Schema v2 migration                    → ic5
[T2] /memory-config command (NEW)            → ic4
```

### Wave 2: Core Skills (depends on T1)

```
[T3] memory-store SKILL.md update            → ic5  [depends: T1]
[T4] memory-recall SKILL.md update           → ic5  [depends: T1]
[T5] /memory-distill command (NEW)           → ic5  [depends: T1]
```

### Wave 3: Integration (depends on T3, T4, T5)

```
[T6] Agent memory protocol rewrite (8 agents) → ic4  [depends: T3, T4]
[T7] wrap-ticket auto-distill hook             → ic4  [depends: T5]
[T8] memory-search tier filter                 → ic4  [depends: T4]
[T9] mem-search + recall tier awareness        → ic4  [depends: T4]
```

### Wave 4: Polish + Ship (depends on Wave 3)

```
[T10] 6 skills tier-aware reads              → ic4  [depends: T6]
[T11] README + AGENTS.md docs                → ic4  [depends: T6, T5]
[T12] Version bump v0.13.0                   → ic4  [depends: all]
[T13] QA validation                          → qa   [depends: all]
```

---

## Task Details

### T1: Schema v2 Migration
**Agent:** ic5 | **Time:** ~4 min
**Files:**
- MODIFY: `skills/memory-store/schema.sql`
- CREATE: `skills/memory-store/migrate-v2.sh`
- MODIFY: `commands/init-team.md` (add v2 migration call)

**Schema changes to `schema.sql`:**
```sql
-- Add tier column (all existing rows become tier 0)
-- NOTE: applied via migrate-v2.sh for existing DBs, baked into schema.sql for new DBs
ALTER TABLE memories ADD COLUMN tier INTEGER NOT NULL DEFAULT 0
  CHECK(tier IN (0, 1, 2));

-- Add archived flag
ALTER TABLE memories ADD COLUMN archived BOOLEAN NOT NULL DEFAULT FALSE;

-- Expand type constraint (SQLite cannot ALTER CHECK — recreate via migration)
-- New CHECK: type IN ('cortex','memory','lessons','digest','core')

-- Add source tracking for distilled records
ALTER TABLE memories ADD COLUMN source_ids TEXT DEFAULT NULL;

-- Tier index for filtered queries
CREATE INDEX IF NOT EXISTS idx_memories_tier ON memories(agent, tier);
CREATE INDEX IF NOT EXISTS idx_memories_archived ON memories(agent, archived);

-- Distillation audit log
CREATE TABLE IF NOT EXISTS distillation_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  agent TEXT NOT NULL,
  from_tier INTEGER NOT NULL,
  to_tier INTEGER NOT NULL,
  source_count INTEGER NOT NULL,
  result_memory_id INTEGER NOT NULL,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- Config keys for distillation
INSERT OR IGNORE INTO config(key, value) VALUES
  ('distill_threshold', '50'),
  ('distill_mode', 'suggest'),
  ('distilling_lock', ''),
  ('schema_version', '2');
```

**`migrate-v2.sh` logic:**
1. Check `schema_version` in config table
2. If already '2', exit 0 (idempotent)
3. If '1': run ALTER TABLE statements, CREATE new table/indexes, UPDATE config
4. SQLite limitation: cannot modify CHECK constraints via ALTER TABLE. Workaround:
   the CHECK on `type` in the original CREATE TABLE must be dropped and recreated.
   Strategy: create new table with correct CHECK, copy data, drop old, rename.
   This is the standard SQLite "12-step" ALTER TABLE pattern.
5. Print summary: "Migrated schema v1 → v2. N existing memories set to tier=0."

**`init-team.md` change:** After Step 2 (DB init), add:
```bash
# Run schema migration if needed
if [ -f "$MEMDB" ]; then
  bash "$MROOT/skills/memory-store/migrate-v2.sh" "$MROOT"
fi
```

**Interface:** `schema_version = '2'` in config table. All subsequent tasks can
assert this.

**Verification:**
```bash
sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='schema_version';"
# Expected: 2
sqlite3 "$MEMDB" "PRAGMA table_info(memories);" | grep -E 'tier|archived|source_ids'
# Expected: 3 rows
sqlite3 "$MEMDB" ".tables" | grep distillation_log
# Expected: distillation_log
```

---

### T2: /memory-config Command (NEW)
**Agent:** ic4 | **Time:** ~3 min
**Files:**
- CREATE: `commands/memory-config.md`

**What it does:**
Simple key-value getter/setter for the `config` table.

```
/memory-config                          → show all config keys + values
/memory-config distill_mode             → get single key
/memory-config distill_mode auto        → set key=value
/memory-config distill_threshold 30     → set key=value
```

**Step 1: Parse arguments**
- No args → SELECT all from config, display as table
- 1 arg → SELECT value WHERE key=$1
- 2 args → UPDATE config SET value=$2 WHERE key=$1; if 0 rows affected, INSERT

**Step 2: Resolve DB path** (standard boilerplate)

**Step 3: Execute**
```bash
# Get all
sqlite3 -header -column "$MEMDB" "SELECT key, value, updated_at FROM config ORDER BY key;"

# Get one
sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='$KEY';"

# Set
sqlite3 "$MEMDB" "INSERT OR REPLACE INTO config(key, value, updated_at)
  VALUES ('$KEY', '$VALUE', strftime('%Y-%m-%dT%H:%M:%SZ','now'));"
```

**Guard:** Refuse to set `schema_version` — print error "schema_version is managed
by migrations, not /memory-config."

**Verification:** `/memory-config distill_mode` returns `suggest`. Set it to `auto`,
read it back, confirm `auto`.

---

### T3: memory-store SKILL.md Update
**Agent:** ic5 | **Time:** ~5 min
**Files:**
- MODIFY: `skills/memory-store/SKILL.md`

**What changes:**

1. **Step 2 (Store a memory):** Add `tier` parameter to INSERT (default 0):
```sql
INSERT INTO memories(agent, type, content, metadata_json, tier)
  VALUES ('<AGENT>', '<TYPE>', '<CONTENT_ESCAPED>', '<METADATA_JSON>', 0);
```

2. **NEW Step 5.5: Post-store threshold check (suggest mode):**
After a successful INSERT, check if distillation should be suggested:
```bash
DISTILL_MODE=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='distill_mode';")
if [ "$DISTILL_MODE" = "suggest" ]; then
  THRESHOLD=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='distill_threshold';")
  COUNT=$(sqlite3 "$MEMDB" "SELECT COUNT(*) FROM memories
    WHERE agent='<AGENT>' AND tier=0 AND archived=FALSE;")
  if [ "$COUNT" -gt "$THRESHOLD" ]; then
    echo "[memory-store] Agent '<AGENT>' has $COUNT raw memories (threshold: $THRESHOLD)."
    echo "[memory-store] Consider running: /memory-distill --agent <AGENT>"
  fi
fi
```

3. **Interface summary table:** Add `tier` parameter (optional, default 0).

4. **Design notes:** Add note that tier 1/2 inserts come from `/memory-distill`,
not from regular agent writes. Regular writes are always tier 0.

**Verification:** Store a memory, confirm it has `tier=0`. Store 51 memories for
one agent, confirm the suggest notice prints on the 51st.

**Depends on:** T1

---

### T4: memory-recall SKILL.md Update
**Agent:** ic5 | **Time:** ~5 min
**Files:**
- MODIFY: `skills/memory-recall/SKILL.md`

**What changes:**

1. **Step 2 (Load all for agent — session start):** Replace flat SELECT with tiered loading:
```bash
# Always load tier 2 (core knowledge) — small, always relevant
sqlite3 "$MEMDB" "SELECT type, content FROM memories
  WHERE agent='<AGENT>' AND tier=2 AND archived=FALSE
  ORDER BY type, updated_at DESC;"

# Load tier 1 (digests) — compressed summaries
sqlite3 "$MEMDB" "SELECT type, content FROM memories
  WHERE agent='<AGENT>' AND tier=1 AND archived=FALSE
  ORDER BY type, updated_at DESC;"

# Skip tier 0 at boot — too noisy. Available via deep search.
```

2. **Step 3 (Keyword search):** Add tier filter and archived filter:
```sql
SELECT agent, type, tier, substr(content, 1, 200) AS snippet, updated_at
FROM memories
WHERE content LIKE '%<QUERY>%' COLLATE NOCASE
  AND archived = FALSE
ORDER BY tier DESC, updated_at DESC
LIMIT <LIMIT>;
```
Tier DESC so tier-2 results appear first.

3. **Step 4 (Semantic search):** Same filters added to the JOIN:
```sql
JOIN memories m ON m.id = e.memory_id AND m.archived = FALSE
```

4. **NEW Step 4.5: Deep search mode:**
When the agent passes `--deep` or `deep=true`, include tier 0 and archived rows:
```sql
-- Deep search: no tier/archived filter
WHERE content LIKE '%<QUERY>%' COLLATE NOCASE
ORDER BY tier DESC, updated_at DESC
```

5. **Interface summary:** Add `tier` filter (optional), `deep` flag (optional, default false).

6. **Return format:** Add `tier` to each result row.

**Verification:** Insert memories at tier 0, 1, 2. Standard search returns only
tier 1+2. Deep search returns all. Archived tier-0 excluded from standard, included
in deep.

**Depends on:** T1

---

### T5: /memory-distill Command (NEW)
**Agent:** ic5 | **Time:** ~5 min
**Files:**
- CREATE: `commands/memory-distill.md`

**This is the most architecturally interesting task.** The command is a self-prompt:
it instructs the executing agent to read raw memories and write a synthesis.

**Arguments:**
```
/memory-distill                    → distill current agent's tier-0 into tier-1
/memory-distill --agent <name>     → distill specific agent
/memory-distill --promote          → evaluate tier-1 digests for promotion to tier-2
/memory-distill --status           → show tier stats per agent
/memory-distill --force            → clear stale distilling_lock
```

**Step 1: Parse arguments, resolve DB**

**Step 2: Handle --status**
```bash
sqlite3 -header -column "$MEMDB" \
  "SELECT agent,
    SUM(CASE WHEN tier=0 AND archived=FALSE THEN 1 ELSE 0 END) AS raw,
    SUM(CASE WHEN tier=0 AND archived=TRUE THEN 1 ELSE 0 END) AS archived,
    SUM(CASE WHEN tier=1 THEN 1 ELSE 0 END) AS digests,
    SUM(CASE WHEN tier=2 THEN 1 ELSE 0 END) AS core
  FROM memories GROUP BY agent ORDER BY agent;"
```

**Step 3: Handle --force (clear lock)**
```bash
sqlite3 "$MEMDB" "UPDATE config SET value='' WHERE key='distilling_lock';"
echo "Distillation lock cleared."
```

**Step 4: Acquire lock**
```bash
LOCK=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='distilling_lock';")
if [ -n "$LOCK" ]; then
  echo "ERROR: Distillation already in progress (lock: $LOCK)."
  echo "If stale, run: /memory-distill --force"
  exit 1
fi
sqlite3 "$MEMDB" "UPDATE config SET value='<AGENT>-$(date +%s)' WHERE key='distilling_lock';"
```

**Step 5: Read tier-0 memories for the agent**
```bash
sqlite3 "$MEMDB" "SELECT id, type, content FROM memories
  WHERE agent='<AGENT>' AND tier=0 AND archived=FALSE
  ORDER BY created_at ASC;"
```

**Step 6: Self-prompt distillation (THIS IS THE KEY PART)**

The command markdown instructs the agent:

```
You now have N raw memories for agent <AGENT>. Your job:

1. Group related memories by topic/theme
2. For each group, write a concise digest (3-8 sentences) that preserves:
   - Key facts and decisions
   - Important patterns and anti-patterns
   - Specific technical details (file paths, function names, gotchas)
   - Drop: timestamps, transient status, duplicate info
3. Each digest becomes one tier-1 'digest' record
4. INSERT each digest:
   sqlite3 "$MEMDB" "INSERT INTO memories(agent, type, content, tier, source_ids)
     VALUES ('<AGENT>', 'digest', '<DIGEST_CONTENT>', 1, '<JSON_ARRAY_OF_SOURCE_IDS>');"
5. Generate embedding for each new digest (if extensions available)
6. Archive source memories:
   sqlite3 "$MEMDB" "UPDATE memories SET archived=TRUE
     WHERE id IN (<SOURCE_IDS>) AND agent='<AGENT>';"
7. Log to distillation_log:
   sqlite3 "$MEMDB" "INSERT INTO distillation_log(agent, from_tier, to_tier, source_count, result_memory_id)
     VALUES ('<AGENT>', 0, 1, <N>, <NEW_ID>);"
```

**Step 7: Handle --promote (tier 1 → tier 2)**

Similar self-prompt but for promoting digests to core knowledge:

```
You have N tier-1 digests for agent <AGENT>. Evaluate each:
- Is this knowledge permanent and broadly applicable? → promote to tier 2 (type='core')
- Is this knowledge still situational? → keep at tier 1
- Is this knowledge stale/obsolete? → archive it

For promotions:
  INSERT INTO memories(agent, type, content, tier, source_ids)
    VALUES ('<AGENT>', 'core', '<CORE_CONTENT>', 2, '<SOURCE_DIGEST_IDS>');
  UPDATE memories SET archived=TRUE WHERE id IN (<SOURCE_DIGEST_IDS>);
```

**Step 8: Release lock**
```bash
sqlite3 "$MEMDB" "UPDATE config SET value='' WHERE key='distilling_lock';"
```

**Step 9: Print summary**
```
DISTILLATION COMPLETE: <AGENT>
════════════════════════════════════════
  Raw memories processed: N
  Digests created:        M
  Promotions to core:     P (if --promote)
  Archived:               A
════════════════════════════════════════
```

**Fallback guard:** If `USE_DB=false`:
```
Distillation requires SQLite memory backend.
Run /init-team to initialize the database.
```

**Verification:** Insert 5 test memories for agent 'test'. Run `/memory-distill --agent test`.
Confirm: digest records created at tier 1, source records archived, distillation_log has entry,
lock is released.

**Depends on:** T1

---

### T6: Agent Memory Protocol Rewrite (8 agents)
**Agent:** ic4 | **Time:** ~5 min (pattern replication)
**Files:**
- MODIFY: `agents/pm.md`
- MODIFY: `agents/tech-lead.md`
- MODIFY: `agents/ic5.md`
- MODIFY: `agents/ic4.md`
- MODIFY: `agents/devops.md`
- MODIFY: `agents/qa.md`
- MODIFY: `agents/ds.md`
- MODIFY: `agents/project-init.md`

**What changes in each agent's "Session start — read memory" section:**

Replace the current flat SELECT:
```bash
sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='<NAME>' AND type='cortex' ORDER BY updated_at DESC LIMIT 1;"
sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='<NAME>' AND type='memory' ORDER BY updated_at DESC LIMIT 1;"
sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='<NAME>' AND type='lessons' ORDER BY updated_at DESC LIMIT 1;"
```

With tiered loading:
```bash
# Tier 2: core knowledge (always loaded)
sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='<NAME>' AND tier=2 AND archived=FALSE ORDER BY type, updated_at DESC;"
# Tier 1: digests (loaded for context)
sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='<NAME>' AND tier=1 AND archived=FALSE ORDER BY type, updated_at DESC;"
# Tier 0: raw (not loaded at boot — available via /memory-search --deep)
# Legacy untiered (tier=0, type in cortex/memory/lessons): still loaded for backward compat
sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='<NAME>' AND tier=0 AND archived=FALSE AND type IN ('cortex','memory','lessons') ORDER BY type, updated_at DESC;"
```

**IMPORTANT backward compatibility note:** Until distillation has actually run,
ALL memories are tier 0. The agent must still load tier-0 cortex/memory/lessons
at boot or it will have no context. The tiered loading supplements — it does not
replace — the original type-based loading until the user runs `/memory-distill`.

The pattern per agent is: load tier 2 first, then tier 1, then tier 0 (type-filtered).
This ensures the newest, most distilled knowledge is presented first in the agent's
context window.

**Verification:** Diff each agent file. Confirm 3-tier SELECT pattern. Confirm
backward compat (tier-0 type-filtered SELECT still present). All 8 agents identical
except agent name string.

**Depends on:** T3, T4

---

### T7: wrap-ticket Auto-Distill Hook
**Agent:** ic4 | **Time:** ~3 min
**Files:**
- MODIFY: `skills/wrap-ticket/SKILL.md`

**What changes:**

Add a new Step 2.5 (between "Collect learnings" and "Append learnings to memory"):

```markdown
## Step 2.5: Auto-distill check

If using SQLite memory:
\```bash
DISTILL_MODE=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='distill_mode';")
\```

If `distill_mode` is `auto`:
1. Check tier-0 count for each agent that participated in this ticket
2. If any agent exceeds threshold, run distillation:
   \```
   For each agent with tier-0 count > threshold:
     Run the /memory-distill --agent <AGENT> protocol (from commands/memory-distill.md)
   \```
3. Print: "Auto-distilled N agents at session end."

If `distill_mode` is `suggest`:
1. Same threshold check
2. Print notice only: "Agent <X> has N raw memories (threshold: T). Run /memory-distill --agent <X>"

If `distill_mode` is `manual`:
1. Skip silently
```

**Verification:** Set `distill_mode=suggest` via /memory-config. Run wrap-ticket
with an agent over threshold. Confirm notice prints. Set to `auto`, confirm
distillation runs.

**Depends on:** T5

---

### T8: memory-search Tier Filter
**Agent:** ic4 | **Time:** ~3 min
**Files:**
- MODIFY: `commands/memory-search.md`

**What changes:**

1. Add `--tier <N>` flag to argument parsing
2. Add `--deep` flag (alias for searching all tiers including archived)
3. Default behavior: search tier 1+2 only (non-archived)
4. Add `AND archived=FALSE` to all WHERE clauses
5. If `--tier` specified: `AND tier=<N>`
6. If `--deep`: remove tier and archived filters
7. Add `tier` to the --status output

**Verification:** `/memory-search "test"` excludes archived. `--deep` includes them.
`--tier 2` returns only core.

**Depends on:** T4

---

### T9: mem-search + recall Tier Awareness
**Agent:** ic4 | **Time:** ~3 min
**Files:**
- MODIFY: `commands/mem-search.md`
- MODIFY: `commands/recall.md`

**mem-search changes:**
1. Add `AND archived=FALSE` to the DB keyword search query
2. Add `tier` to SELECT output
3. Order by `tier DESC` (core first)

**recall changes:**
1. Same `AND archived=FALSE` filter on the memories query
2. Add `tier` to output

**Verification:** Archived memories do not appear in `/mem-search` or `/recall` results.

**Depends on:** T4

---

### T10: 6 Skills Tier-Aware Reads
**Agent:** ic4 | **Time:** ~4 min (pattern replication)
**Files:**
- MODIFY: `skills/orchestrate/SKILL.md`
- MODIFY: `skills/kickoff/SKILL.md`
- MODIFY: `skills/brainstorm/SKILL.md`
- MODIFY: `skills/wrap-ticket/SKILL.md` (the memory READ part, not the auto-distill hook from T7)
- MODIFY: `skills/scaffold-project/SKILL.md`
- MODIFY: `skills/init-orchestration/SKILL.md`

**Pattern:** Wherever a skill currently reads memory with:
```sql
SELECT content FROM memories WHERE agent='...' AND type='cortex';
```
Replace with:
```sql
SELECT content FROM memories WHERE agent='...' AND archived=FALSE
  ORDER BY tier DESC, type, updated_at DESC;
```

This loads core (tier 2) first, then digests (tier 1), then raw (tier 0) — giving
the skill the best context ordering. The `archived=FALSE` filter prevents stale
memories from polluting skill context.

**For scaffold-project and init-orchestration:** New memories they seed should
explicitly set `tier=0` in the INSERT statement.

**Verification:** Grep all 6 skill files for `archived=FALSE`. Confirm no skill
queries lack the filter.

**Depends on:** T6

---

### T11: README + AGENTS.md Docs
**Agent:** ic4 | **Time:** ~4 min
**Files:**
- MODIFY: `README.md`
- MODIFY: `AGENTS.md`

**README changes:**
1. Add "Memory Distillation" section explaining the 3-tier system
2. Add `/memory-distill` and `/memory-config` to the commands table
3. Note: "Run `/memory-distill` periodically to compress raw memories into digests"

**AGENTS.md changes:**
1. Update "Persistent Memory Protocol" to document tiers:
   ```
   Tier 0: Raw memories (written by agents during work)
   Tier 1: Digests (LLM-compressed summaries, created by /memory-distill)
   Tier 2: Core knowledge (promoted from digests, permanent)
   ```
2. Update session start protocol to show tiered loading
3. Add `distill_mode` config key documentation
4. Add `/memory-config` and `/memory-distill` to the "Code Conventions" or a new section

**Depends on:** T6, T5

---

### T12: Version Bump v0.13.0
**Agent:** ic4 | **Time:** ~2 min
**Files:**
- MODIFY: `README.md` (add `### v0.13.0` section)
- MODIFY: `.claude-plugin/plugin.json` (version field)
- MODIFY: `.claude-plugin/marketplace.json` (version field)

**Depends on:** All other tasks

---

### T13: QA Validation
**Agent:** qa | **Time:** ~5 min
**Checks:**

1. **Schema migration:** Fresh DB from schema.sql has tier/archived/source_ids columns.
   Existing v1 DB migrates cleanly via migrate-v2.sh.
2. **Type constraint:** INSERT with type='digest' succeeds. INSERT with type='invalid' fails.
3. **Tier filter:** Tier-0 archived records excluded from standard recall. Included with --deep.
4. **Distillation round-trip:** Insert 5 raw memories, run /memory-distill, verify:
   - Digest records at tier 1, type='digest'
   - Source records have archived=TRUE
   - source_ids JSON array is valid and references correct IDs
   - distillation_log has entry
   - Lock is released
5. **Promotion:** Run /memory-distill --promote, verify tier-2 records created.
6. **Lock safety:** Start distill, check lock is set, force-clear with --force.
7. **Config command:** Get/set/list all via /memory-config. Verify schema_version guard.
8. **Auto-trigger suggest:** Store memories past threshold, verify notice prints.
9. **wrap-ticket hook:** Set distill_mode=auto, verify wrap-ticket triggers distillation.
10. **Backward compat:** DB with no distilled memories (all tier 0) — agents still load
    all their cortex/memory/lessons at boot.
11. **Fallback guard:** Without DB, /memory-distill prints error and exits.
12. **Agent diffs:** All 8 agents have tiered loading. All 6 skills have archived filter.
13. **Version check:** plugin.json, marketplace.json, README.md all say 0.13.0.

**Depends on:** All other tasks

---

## Dependency Graph (visual)

```
[T1] Schema v2 migration ──────┬──── [T3] memory-store update ──────┐
                                │                                     │
                                ├──── [T4] memory-recall update ─────┤
                                │            │                        │
                                ├──── [T5] /memory-distill (NEW) ────┤──── [T7] wrap-ticket hook
                                │                                     │
[T2] /memory-config (NEW) ──────────── (no deps, parallel with T1)   │
                                                                      │
                                ┌─────────────────────────────────────┘
                                │
                          [T6] Agent rewrite (8 agents) ──── [T10] 6 skills update
                                │                                     │
                          [T8] memory-search tier filter              │
                          [T9] mem-search + recall                    │
                                │                                     │
                          [T11] README + AGENTS.md docs ──────────────┤
                                                                      │
                          [T12] Version bump v0.13.0 ─────────────────┘
                                │
                          [T13] QA validation
```

**Maximum parallelism:**
- Wave 1: T1, T2 (parallel — independent)
- Wave 2: T3, T4, T5 (parallel — all depend only on T1)
- Wave 3: T6, T7, T8, T9 (parallel — T6 depends on T3+T4, T7 on T5, T8+T9 on T4)
- Wave 4: T10, T11 (parallel — T10 depends on T6, T11 on T6+T5)
- Wave 5: T12 (depends on all)
- Wave 6: T13 (QA, depends on all)

**Critical path:** T1 → T3 → T6 → T10 → T11 → T12 → T13

---

## Risk Mitigation

| Risk | Mitigation |
|------|-----------|
| SQLite CHECK constraint cannot be ALTERed | Use 12-step table rebuild in migrate-v2.sh |
| Distillation quality varies by model | Keep archived originals; distillation is always reversible |
| Stale lock blocks all distillation | --force flag clears lock; lock value includes timestamp for staleness detection |
| Backward compat — no distilled memories yet | Agent boot loads tier-0 type-filtered as fallback until first distill runs |
| Auto-distill during wrap-ticket too slow | Default mode is 'suggest' (notice only); 'auto' is opt-in |
| Concurrent distillation for same agent | Config-table mutex lock prevents this |

---

## Task Map (for TaskCreate)

- Task 1 (T1): Schema v2 migration → ic5 [ready]
- Task 2 (T2): /memory-config command → ic4 [ready]
- Task 3 (T3): memory-store SKILL.md update → ic5 [blocked by: T1]
- Task 4 (T4): memory-recall SKILL.md update → ic5 [blocked by: T1]
- Task 5 (T5): /memory-distill command → ic5 [blocked by: T1]
- Task 6 (T6): Agent memory protocol rewrite (8 agents) → ic4 [blocked by: T3, T4]
- Task 7 (T7): wrap-ticket auto-distill hook → ic4 [blocked by: T5]
- Task 8 (T8): memory-search tier filter → ic4 [blocked by: T4]
- Task 9 (T9): mem-search + recall tier awareness → ic4 [blocked by: T4]
- Task 10 (T10): 6 skills tier-aware reads → ic4 [blocked by: T6]
- Task 11 (T11): README + AGENTS.md docs → ic4 [blocked by: T6, T5]
- Task 12 (T12): Version bump v0.13.0 → ic4 [blocked by: all]
- Task 13 (T13): QA validation → qa [blocked by: all]
