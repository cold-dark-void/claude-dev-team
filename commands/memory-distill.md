---
name: memory-distill
description: Compress raw memories into digests and promote high-signal knowledge to core tier
argument-hint: "[--agent <name>] [--status] [--force]"
---

# /memory-distill

Orchestrate memory distillation by spawning the @distiller agent.
Compresses tier-0 raw memories into tier-1 digests and promotes high-signal
knowledge to tier-2 core. Handles locking, batching, and status display.

## Arguments

- `/memory-distill` -- distill all agents over threshold
- `/memory-distill --agent <name>` -- distill a specific agent regardless of threshold
- `/memory-distill --status` -- show tier stats per agent (no distillation)
- `/memory-distill --force` -- clear stale lock before running

Flags can be combined: `/memory-distill --force --agent pm`

## Step 1: Parse arguments, resolve DB

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
MEMDB="$MROOT/.claude/memory/memory.db"

USE_DB=false
if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
  USE_DB=true
fi

if [ "$USE_DB" = "false" ]; then
  echo "Distillation requires SQLite memory backend."
  echo "Run /init-team to initialize the database."
  # Stop here
fi
```

Parse flags from arguments:

- `--status` -- set `STATUS=true`
- `--force` -- set `FORCE=true`
- `--agent <name>` -- set `TARGET_AGENT=<name>`

## Step 2: Handle --status

If `--status` flag is set, print tier breakdown and config, then stop.

```bash
echo "MEMORY TIER STATUS"
echo "================================"

sqlite3 -header -column "$MEMDB" \
  "SELECT agent,
    SUM(CASE WHEN tier=0 AND archived=FALSE THEN 1 ELSE 0 END) AS raw,
    SUM(CASE WHEN tier=0 AND archived=TRUE THEN 1 ELSE 0 END) AS archived,
    SUM(CASE WHEN tier=1 AND archived=FALSE THEN 1 ELSE 0 END) AS digests,
    SUM(CASE WHEN tier=2 AND archived=FALSE THEN 1 ELSE 0 END) AS core
  FROM memories GROUP BY agent ORDER BY agent;"

echo ""
echo "Distillation config:"
sqlite3 -header -column "$MEMDB" \
  "SELECT key,
    CASE WHEN key='distilling_lock' AND value='' THEN '(none)' ELSE value END AS value
  FROM config
  WHERE key LIKE 'distill%'
  ORDER BY key;"

echo "================================"
```

Stop after printing.

## Step 3: Handle --force

If `--force` flag is set, clear any stale lock:

```bash
sqlite3 "$MEMDB" "UPDATE config SET value='' WHERE key='distilling_lock';"
echo "[distill] Stale lock cleared. Proceeding."
```

Continue to distillation steps.

## Step 4: Acquire lock (CAS)

Use compare-and-swap to prevent concurrent distillation:

```bash
# UPDATE + changes() MUST run in a single sqlite3 session for CAS to work
CHANGED=$(sqlite3 "$MEMDB" "
  UPDATE config SET value='distill-$(date +%s)' WHERE key='distilling_lock' AND value='';
  SELECT changes();
")
if [ "$CHANGED" = "0" ]; then
  HOLDER=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='distilling_lock';")
  echo "[distill] Skipped: distillation already in progress (locked by $HOLDER). Use --force to clear."
  # Stop here
fi
```

## Step 5: Check distill_enabled and determine target agents

If `distill_enabled=false`, print a notice but continue (manual trigger bypasses the setting):

```bash
DISTILL_ENABLED=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='distill_enabled';")
if [ "$DISTILL_ENABLED" = "false" ]; then
  echo "[distill] Note: auto-distillation is disabled. Running manual distillation."
fi

THRESHOLD=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='distill_threshold';")
```

Determine which agents to process:

```bash
if [ -n "$TARGET_AGENT" ]; then
  # Single agent mode -- process regardless of threshold
  AGENTS="$TARGET_AGENT"
else
  # All agents over threshold
  AGENTS=$(sqlite3 "$MEMDB" \
    "SELECT agent FROM memories
     WHERE tier=0 AND archived=FALSE
     GROUP BY agent
     HAVING COUNT(*) >= $THRESHOLD
     ORDER BY agent;")
fi

if [ -z "$AGENTS" ]; then
  echo "[distill] No agents have enough raw memories to distill (threshold: $THRESHOLD)."
  # Release lock and stop
  sqlite3 "$MEMDB" "UPDATE config SET value='' WHERE key='distilling_lock';"
  # Stop here
fi
```

## Step 6: Read tier-0 memories for each agent

For each target agent, query raw memories in oldest-first order, batched by threshold size:

```bash
MEMORIES=$(sqlite3 "$MEMDB" \
  "SELECT id, content FROM memories
   WHERE agent='$AGENT' AND tier=0 AND archived=FALSE
   ORDER BY created_at ASC;")

COUNT=$(sqlite3 "$MEMDB" \
  "SELECT COUNT(*) FROM memories
   WHERE agent='$AGENT' AND tier=0 AND archived=FALSE;")
```

If count is 0: print `"[distill] @<agent>: no raw memories to distill."` and skip to next agent.

## Step 7: Spawn @distiller agent

Read the configured distill model:

```bash
DISTILL_MODEL=$(sqlite3 "$MEMDB" "SELECT value FROM config WHERE key='distill_model';")
```

For each target agent, spawn the @distiller agent with:

- **Agent name** being processed
- **DB path** (`$MEMDB`)
- **Batch of memories** (id/content pairs, threshold-sized chunks, oldest-first)
- **Instruction** to process L0->L1 distillation, then evaluate L1->L2 promotion

If the user has configured a `distill_model` other than the default, pass it as
the model override when spawning the agent.

The @distiller processes all batches for one agent, prints its summary line
(`@<agent>: N raw -> M digests, P promoted to core`), then the command moves
to the next agent.

## Step 8: Release lock

After all agents are processed (or on error), release the lock:

```bash
sqlite3 "$MEMDB" "UPDATE config SET value='' WHERE key='distilling_lock';"
```

Always release the lock, even if distillation encountered errors for some agents.

## Step 9: Print summary

```
DISTILLATION COMPLETE
================================
  @pm        52 raw -> 3 digests | 1 promoted to core
  @tech-lead 50 raw -> 2 digests | 0 promoted to core
================================
Lock released.
```

If some agents failed, note them:

```
  @devops    FAILED (DB locked during write)
```
