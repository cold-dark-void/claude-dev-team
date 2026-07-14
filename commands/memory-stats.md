---
name: memory-stats
description: Show memory usage statistics (counts, sizes, growth) — no content displayed
agent: build
---

# /memory-stats

Display anonymized memory usage metrics. Shows counts and sizes only — no memory content is ever displayed. Safe to share publicly.

## Arguments

- `/memory-stats` — show all stats
- `/memory-stats --agent <name>` — stats for a single agent

## Step 1: Resolve paths

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
```

## Step 2: Check DB exists

If no DB or no sqlite3:
```
Memory stats unavailable — no SQLite DB found.
Run /init-team to initialize.
```

## Step 3: Gather and display stats

Run these queries and format the output:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
# Per-agent stats (active rows only — archived excluded)
sqlite3 -header -column "$MEMDB" "
SELECT
  agent,
  COUNT(*) AS total_memories,
  SUM(CASE WHEN type='cortex' THEN 1 ELSE 0 END) AS cortex,
  SUM(CASE WHEN type='memory' THEN 1 ELSE 0 END) AS memory,
  SUM(CASE WHEN type='lessons' THEN 1 ELSE 0 END) AS lessons,
  CAST(AVG(LENGTH(content)) AS INTEGER) AS avg_chars,
  MAX(LENGTH(content)) AS max_chars,
  SUM(LENGTH(content)) AS total_chars
FROM memories
WHERE archived = FALSE
GROUP BY agent
ORDER BY total_chars DESC;
"

# Overall summary (active rows only — archived excluded)
sqlite3 "$MEMDB" "
SELECT
  COUNT(*) AS total_rows,
  COUNT(DISTINCT agent) AS agents,
  SUM(LENGTH(content)) AS total_chars,
  CAST(AVG(LENGTH(content)) AS INTEGER) AS avg_chars,
  MAX(LENGTH(content)) AS max_chars,
  MIN(created_at) AS oldest_memory,
  MAX(created_at) AS newest_memory
FROM memories
WHERE archived = FALSE;
"

# Embedding status
sqlite3 "$MEMDB" "
SELECT
  (SELECT value FROM config WHERE key='embedding_mode') AS mode,
  (SELECT value FROM config WHERE key='embedding_model') AS model,
  (SELECT COUNT(*) FROM embedding_meta) AS embedded_count,
  (SELECT COUNT(*) FROM memories) AS total_count;
"

# Boot load estimate (what agents actually load at session start).
# Mirrors the tiered read (SPEC-006 Step 2): tier-1 + tier-2 active content when an
# agent has any distilled rows, else tier-0 active content. Archived rows never load.
sqlite3 -header -column "$MEMDB" "
WITH active AS (
  SELECT agent, tier, LENGTH(content) AS len FROM memories WHERE archived = FALSE
),
distilled AS (
  SELECT DISTINCT agent FROM active WHERE tier >= 1
)
SELECT
  a.agent,
  SUM(CASE
        WHEN a.agent IN (SELECT agent FROM distilled) THEN CASE WHEN a.tier >= 1 THEN a.len ELSE 0 END
        ELSE CASE WHEN a.tier = 0 THEN a.len ELSE 0 END
      END) AS boot_load_chars,
  CASE
    WHEN SUM(CASE
        WHEN a.agent IN (SELECT agent FROM distilled) THEN CASE WHEN a.tier >= 1 THEN a.len ELSE 0 END
        ELSE CASE WHEN a.tier = 0 THEN a.len ELSE 0 END
      END) > 10000 THEN '⚠ HIGH'
    WHEN SUM(CASE
        WHEN a.agent IN (SELECT agent FROM distilled) THEN CASE WHEN a.tier >= 1 THEN a.len ELSE 0 END
        ELSE CASE WHEN a.tier = 0 THEN a.len ELSE 0 END
      END) > 5000 THEN 'moderate'
    ELSE 'ok'
  END AS status
FROM active a
GROUP BY a.agent
ORDER BY boot_load_chars DESC;
"
```

## Step 4: Format output

```
MEMORY STATS
════════════════════════════════════════════════════════════

Per-agent breakdown:
<per-agent table from query 1>

Summary:
  Total memories:  <N>
  Total agents:    <N>
  Total chars:     <N> (<N/1000>K)
  Avg memory size: <N> chars
  Max memory size: <N> chars
  Oldest memory:   <date>
  Newest memory:   <date>

Embeddings:
  Mode:     <mode> (<model>)
  Embedded: <N>/<total> memories

Boot load per agent (chars loaded at session start):
<boot load table>

════════════════════════════════════════════════════════════
Safe to share — no memory content included.
```
