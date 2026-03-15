Perform SQLite memory setup, then use the project-init subagent to initialize the team's memory for the current project.

Note: project-init needs Read, Write, Bash, and Glob permissions. Run this in the foreground (not as a background task) so tool permission prompts can be approved.

## Flag handling

Parse flags from `$ARGS` (or the arguments passed to this command):
- `--refresh` — re-check embedding configuration, re-check extensions, re-run migration for any new .md files
- `--migrate-only` — only run migration, skip everything else (DB init, extensions, project-init agent)
- `--no-extensions` — skip binary download (for air-gapped setups where the user installs extensions manually)

## Step 1: Resolve project root and plugin path

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
echo "Project root: $MROOT"
echo "Memory DB:    $MEMDB"
```

Resolve the plugin's install directory (where schema.sql and scripts live):
```bash
# Find the current plugin version from plugin.json, then use that exact path
PLUGIN_VER=$(cat ~/.claude/plugins/cache/cold-dark-void/dev-team/*/\\.claude-plugin/plugin.json 2>/dev/null | grep -o '"version": *"[^"]*"' | tail -1 | grep -o '[0-9][0-9.]*')
PLUGIN_DIR="$HOME/.claude/plugins/cache/cold-dark-void/dev-team/${PLUGIN_VER}/skills/memory-store"
if [ -z "$PLUGIN_VER" ] || [ ! -f "$PLUGIN_DIR/schema.sql" ]; then
  # Fallback: find any version with schema.sql
  PLUGIN_DIR=$(find ~/.claude/plugins/cache -path "*/dev-team/*/skills/memory-store/schema.sql" 2>/dev/null | sort -V | tail -1 | xargs dirname 2>/dev/null)
fi
if [ -z "$PLUGIN_DIR" ] || [ ! -f "$PLUGIN_DIR/schema.sql" ]; then
  echo "WARNING: Could not find dev-team plugin memory-store skills. SQLite setup will be skipped."
  PLUGIN_DIR=""
fi
echo "Plugin dir: $PLUGIN_DIR"
```

## Step 2: Initialize SQLite memory DB

Skip this step if `--migrate-only` is set.

```bash
mkdir -p "$MROOT/.claude/memory"
if command -v sqlite3 &>/dev/null && [ -n "$PLUGIN_DIR" ]; then
  sqlite3 "$MEMDB" < "$PLUGIN_DIR/schema.sql"
  echo "SQLite memory DB initialized at $MEMDB"
else
  echo "WARNING: sqlite3 or plugin not found. Using .md memory fallback."
fi
```

This is idempotent — schema uses `CREATE TABLE IF NOT EXISTS` and `INSERT OR IGNORE`, so re-running is safe.

## Step 3: Download extensions (unless --no-extensions or --migrate-only)

Skip this step if `--no-extensions` or `--migrate-only` is set.

```bash
if command -v sqlite3 &>/dev/null && [ -n "$PLUGIN_DIR" ]; then
  bash "$PLUGIN_DIR/download-extensions.sh" "$MROOT"
fi
```

On `--refresh`: this step always re-runs (the script itself is idempotent — it skips already-present files but re-detects the embedding provider).

To configure a remote embedding provider, set environment variables before running:
```
export EMBEDDING_URL=https://api.openai.com/v1/embeddings
export EMBEDDING_API_KEY=sk-...
export EMBEDDING_MODEL=text-embedding-3-small
```

## Step 4: Run migration (if .md files exist)

Skip this step if `--migrate-only` is NOT set AND this is the first run (no prior .md files). Always run on `--migrate-only` or `--refresh`.

```bash
if command -v sqlite3 &>/dev/null && [ -f "$MEMDB" ] && [ -n "$PLUGIN_DIR" ]; then
  bash "$PLUGIN_DIR/migrate-md.sh" "$MROOT"
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

## Step 5b: Add required hosts to sandbox network allowlist

Collect all hosts that need sandbox network access. Always include `github.com:22`
(for git push over SSH). If `$EMBEDDING_URL` is set, also include the embedding host.

```bash
SETTINGS="$MROOT/.claude/settings.json"
HOSTS_TO_ADD=()

# Always need github SSH for push
HOSTS_TO_ADD+=("github.com:22")

# Embedding host if configured
if [ -n "${EMBEDDING_URL:-}" ]; then
  EMBED_HOST=$(echo "$EMBEDDING_URL" | sed -E 's|https?://([^/]+).*|\1|')
  HOSTS_TO_ADD+=("$EMBED_HOST")
fi
```

For each host, check if it's already in the allowlist. If not, add it.

**IMPORTANT:** `.claude/settings.json` is protected by the sandbox. The bash command
below will be blocked on first attempt. When it fails with a sandbox/permission error,
**retry with `dangerouslyDisableSandbox: true`** — the user will be prompted once to
approve. This is the expected flow for zero-intervention setup.

```bash
if command -v jq &>/dev/null; then
  # Ensure settings.json exists with minimal structure
  if [ ! -f "$SETTINGS" ]; then
    echo '{}' > "$SETTINGS"
  fi

  for HOST in "${HOSTS_TO_ADD[@]}"; do
    if ! grep -qF "$HOST" "$SETTINGS" 2>/dev/null; then
      jq --arg host "$HOST" '
        .sandbox.network.allowedDomains = ((.sandbox.network.allowedDomains // []) + [$host] | unique)
      ' "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
      echo "Added $HOST to sandbox.network.allowedDomains"
    else
      echo "$HOST already in allowlist"
    fi
  done
else
  echo "WARNING: jq not found. Manually add these to .claude/settings.json sandbox.network.allowedDomains:"
  printf '  - %s\n' "${HOSTS_TO_ADD[@]}"
fi
```

## Step 6: Invoke project-init agent

Skip this step if `--migrate-only` or `--refresh` is set. Project-init only runs on first initialization — `--refresh` re-checks extensions and embeddings but does NOT rescan the project or rewrite cortex data.

Use the project-init subagent to scan the project and write cortex.md files for all 7 team agents.
