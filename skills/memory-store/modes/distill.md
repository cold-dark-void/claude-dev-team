# distill

Orchestrate memory distillation by spawning the @distiller agent.
Compresses tier-0 raw memories into tier-1 digests and promotes high-signal
knowledge to tier-2 core. Handles locking, batching, and status display.

## Arguments

- `/memory distill` -- distill all agents over threshold
- `/memory distill --agent <name>` -- distill a specific agent regardless of threshold
- `/memory distill --status` -- show tier stats per agent (no distillation)
- `/memory distill --force` -- clear stale lock before running
- `/memory distill --skip-validate` -- skip pre-distill validation step
- `/memory distill --compress` -- fact-dense rewrite of verbose tier-0 prose first
  (`skills/memory-compress`; also auto when `MEMORY_COMPRESS=1`)

Flags can be combined: `/memory distill --force --agent pm`

Validation runs automatically before distillation (archive stale memories first,
so they don't get distilled). Use `--skip-validate` to bypass.

**Prose compress (optional):** when `--compress` or `MEMORY_COMPRESS=1`, before
digest generation, rewrite selected raw rows into fact-dense bullets without
losing technical substance (not a tier promotion). Protocol:
`skills/memory-compress/SKILL.md`. Skip with `MEMORY_COMPRESS=0`.

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
  echo "Run /setup team to initialize the database."
  # Stop here
  exit 1
fi
```

Parse flags from arguments:

- `--status` -- set `STATUS=true`
- `--force` -- set `FORCE=true`
- `--agent <name>` -- set `TARGET_AGENT=<name>`
- `--skip-validate` -- set `SKIP_VALIDATE=true`
- `--compress` -- set `COMPRESS=true`. Also set it when `MEMORY_COMPRESS=1`. `MEMORY_COMPRESS=0` forces `COMPRESS` off.

```bash
ARGS=$(cat <<'__A__'
$ARGUMENTS
__A__
)
set -f; set -- $ARGS; set +f
[ "${1:-}" = "distill" ] && shift
COMPRESS=false
if [ "${MEMORY_COMPRESS:-}" = "1" ]; then
  COMPRESS=true
fi
while [ $# -gt 0 ]; do
  case "${1:-}" in
    --compress) COMPRESS=true; shift ;;
    *) shift ;;
  esac
done
if [ "${MEMORY_COMPRESS:-}" = "0" ]; then
  COMPRESS=false
fi
```

## Step 2: Handle --status

If `--status` flag is set, print tier breakdown and config, then stop.

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
echo "MEMORY TIER STATUS"
echo "================================"

# Tier columns live in skills/memory-store/modes/tier-status.md. Run that fence.
# Do not copy the SELECT into this file.

echo ""
echo "Distillation config:"
sqlite3 -cmd ".timeout 5000" -header -column "$MEMDB" \
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
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
bash skills/memory-store/distill-lock.sh force-clear "$MEMDB"
echo "[distill] Stale lock cleared. Proceeding."
```

Continue to distillation steps.

## Step 4: Acquire lock (CAS)

Use compare-and-swap to prevent concurrent distillation:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
# Print the token. Copy it into DISTILL_TOKEN and LOCK_OWNER for later fences.
# A fresh foreign lock exits 75. A lock older than 30 minutes is taken.
bash skills/memory-store/distill-lock.sh acquire "$MEMDB" || exit $?
```

## Step 4.5: Pre-distill validation

Unless `SKIP_VALIDATE=true`, run memory validation before distillation begins.
Validation runs inside the lock window (after lock acquired, before distiller
spawned) to prevent concurrent modifications during validation.

If validation fails (non-zero exit), abort distillation, release the lock, and stop.

The validation step is equivalent to running `/memory validate` with the same
`--agent` filter if provided, but without `--deep`. Deep mode is excluded
because it invokes the @distiller agent, which would create a circular
dependency.

If `SKIP_VALIDATE` is not `"true"`, follow these steps in order:

1. Build the validate args:
   ```bash
   VALIDATE_ARGS=""
   if [ -n "$TARGET_AGENT" ]; then VALIDATE_ARGS="--agent $TARGET_AGENT"; fi
   ```

2. **Run `/memory validate $VALIDATE_ARGS` now.** Read
   `skills/validate-memory/host-pipeline.md` and follow Steps 1–8 there.
   Do NOT pass `--deep` (circular dependency: distiller → validate → distiller).

3. If validation reported failures, release the lock and stop:
   ```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
   bash skills/memory-store/distill-lock.sh release "$MEMDB" "$DISTILL_TOKEN"
   echo "[distill] Validation failed. Aborting distillation."
   exit 1
   ```

4. On pass:
   ```bash
   echo "[distill] Validation complete. Proceeding to distillation."
   ```

## Step 5: Check distill_enabled and determine target agents

If `distill_enabled=false`, print a notice but continue (manual trigger bypasses the setting):

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
DISTILL_ENABLED=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT value FROM config WHERE key='distill_enabled';")
if [ "$DISTILL_ENABLED" = "false" ]; then
  echo "[distill] Note: auto-distillation is disabled. Running manual distillation."
fi

THRESHOLD=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT value FROM config WHERE key='distill_threshold';")
```

Determine which agents to process:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
# This block is a new shell: read the threshold here, never from the block above.
THRESHOLD=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT value FROM config WHERE key='distill_threshold';")
if [ -n "$TARGET_AGENT" ]; then
  # Single agent mode -- process regardless of threshold.
  # Roster check before the name is stored or reaches a later SQL fence.
  case "$TARGET_AGENT" in
    pm|tech-lead|ic5|ic4|devops|qa|ds) ;;
    *) echo "Error: --agent must match the roster" >&2; exit 64 ;;
  esac
  bash skills/lib/require-agent.sh "$TARGET_AGENT"
  AGENTS="$TARGET_AGENT"
else
  # All agents over threshold
  AGENTS=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" \
    "SELECT agent FROM memories
     WHERE tier=0 AND archived=FALSE
     GROUP BY agent
     HAVING COUNT(*) >= $THRESHOLD
     ORDER BY agent;")
fi

if [ -z "$AGENTS" ]; then
  echo "[distill] No agents have enough raw memories to distill (threshold: $THRESHOLD)."
  # Release only the token this run acquired.
  bash skills/memory-store/distill-lock.sh release "$MEMDB" "$DISTILL_TOKEN"
  # Stop here
  exit 0
fi
```

## Step 6: Read tier-0 memories for each agent

When `COMPRESS=true`, rewrite the selected rows with `skills/memory-compress/SKILL.md` before the distiller spawn. That rewrite is not a tier change.

For each target agent, query raw memories in oldest-first order, batched by threshold size:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
# Roster check before the name reaches SQL. skills/lib/require-agent.sh is the same rule.
case "$AGENT" in
  pm|tech-lead|ic5|ic4|devops|qa|ds) ;;
  *) echo "Error: --agent must match the roster" >&2; exit 64 ;;
esac
bash skills/lib/require-agent.sh "$AGENT"
MEMORIES=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" \
  "SELECT id, content FROM memories
   WHERE agent='$AGENT' AND tier=0 AND archived=FALSE
   ORDER BY created_at ASC;")

COUNT=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" \
  "SELECT COUNT(*) FROM memories
   WHERE agent='$AGENT' AND tier=0 AND archived=FALSE;")
```

If count is 0: print `"[distill] @<agent>: no raw memories to distill."` and skip to next agent.

## Step 7: Spawn @distiller agent

Read the configured distill model:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
DISTILL_MODEL=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT value FROM config WHERE key='distill_model';")
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
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
bash skills/memory-store/distill-lock.sh release "$MEMDB" "$DISTILL_TOKEN"
```

Release only the token Step 4 printed. A run that does not hold the lock
cannot clear another process's token.

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

---

