---
name: init-team
description: Bootstrap all 7 agents' memory for the current project — initializes
  SQLite DB, downloads embedding extensions (~29MB), runs project-init scan, syncs
  permissions. Run once per project, safe to re-run. Flags --refresh, --migrate-only,
  --no-extensions.
agent: build
---

Perform SQLite memory setup, then use the project-init subagent to initialize the team's memory for the current project.

Note: project-init needs Read, Write, Bash, and Glob permissions. Run this in the foreground (not as a background task) so tool permission prompts can be approved.

## Flag handling

Parse flags from `$ARGUMENTS` (or the arguments passed to this command):
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
# Locate the dev-team plugin root (PDH). Optional CLAUDE_PLUGIN_ROOT (dead in Bash fences today — FR #48230; forward-compat), else dev checkout, else installed cache (pre-release-safe sort -V). Slug-free.
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
PLUGIN_DIR=$(bash "$PDH/skills/plugin-dir.sh" dir skills/memory-store/schema.sql)
if [ -z "$PLUGIN_DIR" ] || [ ! -f "$PLUGIN_DIR/schema.sql" ]; then
  echo "WARNING: Could not find dev-team plugin memory-store skills. SQLite setup will be skipped."
  PLUGIN_DIR=""
fi
echo "Plugin dir: $PLUGIN_DIR"
```

## Step 2: Initialize SQLite memory DB

Skip this step if `--migrate-only` is set.

```bash
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
PLUGIN_DIR="$PDH"
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
mkdir -p "$MROOT/.claude/memory"
if command -v sqlite3 &>/dev/null && [ -n "$PLUGIN_DIR" ]; then
  sqlite3 "$MEMDB" < "$PLUGIN_DIR/schema.sql"
  echo "SQLite memory DB initialized at $MEMDB"
else
  echo "WARNING: sqlite3 or plugin not found. Using .md memory fallback."
fi
```

This is idempotent — schema uses `CREATE TABLE IF NOT EXISTS` and `INSERT OR IGNORE`, so re-running is safe.

## Step 2.5: Run schema migration (if upgrading)

If the DB already existed before Step 2, check if it needs a schema upgrade:

```bash
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
PLUGIN_DIR="$PDH"
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
if [ -f "$MEMDB" ] && [ -n "$PLUGIN_DIR" ]; then
  bash "$PLUGIN_DIR/migrate.sh" "$MROOT"
fi
```

`migrate.sh` drives the DB to the latest schema in a single run: it reads
`schema_version` and applies each `migrate-v<next>.sh` in sequence (v1->v2->v3->…)
until the latest version is reached. It is idempotent — each step checks
`schema_version` internally, an already-latest DB prints "up to date", and an
empty/absent `schema_version` is a no-op (exit 0).

On `--refresh`: always run this migration check.
On `--migrate-only`: run this step, then the .md migration (Step 4), then exit.

## Step 3: Download extensions (unless --no-extensions or --migrate-only)

Skip this step if `--no-extensions` or `--migrate-only` is set.

```bash
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
PLUGIN_DIR="$PDH"
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
if command -v sqlite3 &>/dev/null && [ -n "$PLUGIN_DIR" ]; then
  # Only mark the memory .gitignore block as written if download-extensions.sh
  # actually SUCCEEDED — it writes that block at the very end, so a mid-run abort
  # (unsupported platform exit, curl/tar failure) must leave the flag UNSET so
  # Step 5's idempotent fallback still covers the extensions/ + models/ dirs the
  # script mkdir'd before failing. && ties the flag to the child's exit status.
  bash "$PLUGIN_DIR/download-extensions.sh" "$MROOT" && export EXT_GITIGNORE_DONE=1
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
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
PLUGIN_DIR="$PDH"
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
if command -v sqlite3 &>/dev/null && [ -f "$MEMDB" ] && [ -n "$PLUGIN_DIR" ]; then
  bash "$PLUGIN_DIR/migrate-md.sh" "$MROOT"
fi
```

## Step 5: Update .gitignore (fallback)

Skip this step if `--migrate-only` is set.

`download-extensions.sh` (Step 3) is the single source of the 5-line memory
`.gitignore` block. This step is only a **fallback** for the paths where Step 3
did not run — `--no-extensions`, or `sqlite3`/`PLUGIN_DIR` unavailable — so no
init path loses gitignore coverage. When Step 3 ran (`EXT_GITIGNORE_DONE=1`),
skip this step entirely. The `grep -qF || echo` guard is idempotent regardless.

**Never** write a bare `.claude/memory/` exclude here — use child globs only so a
committed seed pack under `.claude/memory/seed/` stays committable (SPEC-024 M9).

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
if [ -z "${EXT_GITIGNORE_DONE:-}" ]; then  # lint-ok: C1
  GITIGNORE="$MROOT/.gitignore"
  for ENTRY in \
    ".claude/memory/extensions/" \
    ".claude/memory/models/" \
    ".claude/memory/memory.db" \
    ".claude/memory/memory.db-wal" \
    ".claude/memory/memory.db-shm"; do
    grep -qF "$ENTRY" "$GITIGNORE" 2>/dev/null || echo "$ENTRY" >> "$GITIGNORE"
  done
  # Seed carve-out (child-glob + negations) when a pack may be committed
  PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
  COMMON=$(bash "$PDH/skills/plugin-dir.sh" file skills/memory-store/seed-common.sh 2>/dev/null || true)
  if [ -n "$COMMON" ] && [ -f "$COMMON" ]; then
    # shellcheck disable=SC1090
    . "$COMMON"
    ensure_seed_gitignore "$MROOT" || true
  fi
  echo "Checked .gitignore entries (fallback)."
fi
```

## Step 5.5: Import memory seed pack (if present)

Skip this step if `--migrate-only` is set.

Runs on **first init and `--refresh`**. If `.claude/memory/seed/manifest.json` is
absent, do nothing (no new output — SPEC-024 M11 graceful absence). A bad pack
never blocks bootstrap: import always exits 0 and prints counts/warnings only.

Import runs **after** DB init + extensions + md-migrate + gitignore, and
**before** project-init (Step 6), so seeded tier-1 digests already exist when the
scan runs (SPEC-024 M4).

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
SEED_IMPORT_SUMMARY=""
if [ -f "$MROOT/.claude/memory/seed/manifest.json" ]; then
  PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
  IMPORT_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/memory-store/import-seed-pack.sh)
  if [ -n "$IMPORT_SH" ] && [ -f "$IMPORT_SH" ]; then
    SEED_IMPORT_SUMMARY=$(bash "$IMPORT_SH" "$MROOT" 2>&1) || true
    echo "$SEED_IMPORT_SUMMARY"
  else
    echo "WARNING: seed pack present but import-seed-pack.sh not found — skipping import"
  fi
fi
# Export for Step 7 warm-start line (same shell / agent context)
export SEED_IMPORT_SUMMARY
```

## Step 5b: Add required hosts to sandbox network allowlist

Collect all hosts that need sandbox network access. Always include `github.com:22`
(for git push over SSH). If `$EMBEDDING_URL` is set, also include the embedding host.

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
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
  if [ ! -f "$SETTINGS" ]; then  # lint-ok: C1
    echo '{}' > "$SETTINGS"
  fi

  for HOST in "${HOSTS_TO_ADD[@]}"; do  # lint-ok: C1
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

## Step 7: Post-bootstrap hints

After all steps complete, print:

```
Tip: Use /adjust-agent to set per-agent behavioral directives for this project.
```

If Step 5.5 produced a `seed-import:` summary line, also print a one-line warm-start
note for the user (SPEC-024 SHOULD), e.g.:

```
warm start: N memories imported for M agents from pack dated <date>; K rejected
```

Parse counts from `$SEED_IMPORT_SUMMARY` when non-empty; omit this line entirely when
no pack was present (M11).
