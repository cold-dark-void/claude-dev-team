Perform SQLite memory setup, then use the project-init subagent to initialize the team's memory for the current project.

Note: project-init needs Read, Write, Bash, and Glob permissions. Run this in the foreground (not as a background task) so tool permission prompts can be approved.

## Flag handling

Parse flags from `$ARGS` (or the arguments passed to this command):
- `--refresh` — re-probe ollama, re-check extensions, re-run migration for any new .md files
- `--migrate-only` — only run migration, skip everything else (DB init, extensions, project-init agent)
- `--no-extensions` — skip binary download (for air-gapped setups where the user installs extensions manually)

## Step 1: Resolve project root

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
echo "Project root: $MROOT"
echo "Memory DB:    $MEMDB"
```

## Step 2: Initialize SQLite memory DB

Skip this step if `--migrate-only` is set.

```bash
mkdir -p "$MROOT/.claude/memory"
if command -v sqlite3 &>/dev/null; then
  sqlite3 "$MEMDB" < "$MROOT/skills/memory-store/schema.sql"
  echo "SQLite memory DB initialized at $MEMDB"
else
  echo "WARNING: sqlite3 not found. Using .md memory fallback."
fi
```

This is idempotent — schema uses `CREATE TABLE IF NOT EXISTS` and `INSERT OR IGNORE`, so re-running is safe.

## Step 3: Download extensions (unless --no-extensions or --migrate-only)

Skip this step if `--no-extensions` or `--migrate-only` is set.

```bash
if command -v sqlite3 &>/dev/null; then
  bash "$MROOT/skills/memory-store/download-extensions.sh" "$MROOT"
fi
```

On `--refresh`: this step always re-runs (the script itself is idempotent — it skips already-present files but re-probes ollama).

## Step 4: Run migration (if .md files exist)

Skip this step if `--migrate-only` is NOT set AND this is the first run (no prior .md files). Always run on `--migrate-only` or `--refresh`.

```bash
if command -v sqlite3 &>/dev/null && [ -f "$MEMDB" ]; then
  bash "$MROOT/skills/memory-store/migrate-md.sh" "$MROOT"
fi
```

## Step 5: Update .gitignore

Skip this step if `--migrate-only` is set.

Ensure the following entries are present in `$MROOT/.gitignore`. Add any that are missing; do not remove or reorder existing entries.

```bash
GITIGNORE="$MROOT/.gitignore"
for ENTRY in \
  ".claude/memory/memory.db" \
  ".claude/memory/memory.db-wal" \
  ".claude/memory/memory.db-shm" \
  ".claude/memory/extensions/" \
  ".claude/memory/models/"; do
  grep -qF "$ENTRY" "$GITIGNORE" 2>/dev/null || echo "$ENTRY" >> "$GITIGNORE"
done
echo "Checked .gitignore entries."
```

## Step 6: Invoke project-init agent

Skip this step if `--migrate-only` is set.

Use the project-init subagent to scan the project and write cortex.md files for all 7 team agents.
