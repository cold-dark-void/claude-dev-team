---
name: setup
description: >
  Onboarding dispatcher — project scaffold (TDD structure), orchestration
  bootstrap (sandbox/hooks/teams), team memory init (SQLite + project-init),
  Model map (local per-agent model strings), Telegram Intercom setup
  (SPEC-038), or a Slack stub. Usage /setup
  <project|orchestration|team|models|telegram|slack> [flags...].
  Bare/unknown prints usage only (no side effects).
argument-hint: "<project|orchestration|team|models|telegram|slack> [flags...]"
agent: build
---

# /setup — Onboarding Dispatcher

Single entry for project onboarding plus the Model map (SPEC-005) and the
Telegram Intercom subs (SPEC-038). The onboarding subs stay **behaviorally
distinct** — do not merge their protocols. `models`, `telegram` and `slack`
are known subs and are **not** doctor-gated.

## Dispatch

Parse the first positional argument as `<sub>`. If absent or unknown, print the
usage block below and **stop**. Do not guess a default sub. Do not create files,
touch settings, run migrations, or otherwise mutate project state on bare/unknown.

Remaining args (including flags) pass through unchanged to the routed sub.

### Usage (bare / unknown — prose only, zero side effects)

```
Usage: /setup <project|orchestration|team|models|telegram|slack> [flags...]

Subs:
  project         Scaffold TDD workflow structure (AGENTS.md, specs/TDD.md,
                  .claude/plans, settings allowlist). Greenfield / add-TDD.
                  Soft-advises dev-team:doctor (never blocks).
  orchestration   Bootstrap Agent Teams orchestration (sandbox, hooks,
                  `auto` (Cell D), AGENTS.md team section). Brownfield merge.
                  Hard-gates on dev-team:doctor (exit ≤1 OK; exit 2 blocks).
                  Flag: --skip-doctor
  team [flags…]   Initialize team memory (SQLite DB, embedding extensions,
                  project-init scan). Hard-gates on dev-team:doctor.
                  Flags: --refresh --migrate-only --no-extensions
                  --skip-doctor
  models          Local Model map (read/write
                  $MROOT/.claude/dev-team/models.local.json only).
                  Not doctor-gated. Bare = list (includes effort);
                  set/unset/set-effort/unset-effort pass through.
  telegram        Configure the Telegram Intercom (SPEC-038): token file,
                  pairing, state dirs, harness schedule. Interactive —
                  delegates to skills/intercom/setup-telegram.sh.
                  Not doctor-gated.
  slack           Zero-write stub: prints "Slack ships in v1.1/v2." and
                  exits 0. Not doctor-gated.

Examples:
  /setup project
  /setup orchestration
  /setup orchestration --skip-doctor
  /setup team
  /setup team --refresh
  /setup team --migrate-only
  /setup team --no-extensions
  /setup team --skip-doctor
  /setup models
  /setup models set ic4 grok-code-fast-1
  /setup models unset ic4
  /setup models set-effort ic4 high
  /setup models unset-effort ic4
  /setup telegram
  /setup slack
```

Unknown/missing sub → print this usage and stop. **MUST NOT** mutate project state.

**Doctor gate (SPEC-005 / SPEC-022 M6b/M6c):** `/setup team` and `/setup orchestration`
hard-gate on plugin **`dev-team:doctor`** (NOT the Claude Code harness built-in
`/doctor`) with `--gate=team` / `--gate=orchestration`. Exit ≤1 continues (including
self-remediating FAILs whose fix-it exactly matches the active sub); exit 2 blocks.
Override: `--skip-doctor` prints an explicit WARNING then continues. `/setup project`
is soft-advisory only. `/setup models` is **not** gated on doctor. Marketplace
install has no doctor gate.

## Routing table

| `<sub>` | Strategy | Source / target |
|---------|----------|-----------------|
| `project` | **skill-delegate** | `skills/scaffold-project/SKILL.md` (internal backend) |
| `orchestration` | **skill-delegate** | `skills/init-orchestration/SKILL.md` (internal backend) |
| `team` | **inline** | former `commands/init-team.md` body; flags pass through |
| `models` | **skill-delegate** | `skills/model-map/write-model.sh` via `plugin-dir.sh file` (SPEC-037) |
| `telegram` | **skill-delegate** | `skills/intercom/setup-telegram.sh` via `plugin-dir.sh file` (SPEC-038) |
| `slack` | **inline stub** | prints `Slack ships in v1.1/v2.`, exit 0, zero state writes (AC5) |

The three onboarding protocols stay distinct (greenfield scaffold vs brownfield
orchestration vs team memory bootstrap). Dispatcher only — no semantic merge.
`models` writes local Model map JSON only (never repo/global). `telegram` and
`slack` never write repo state (SPEC-038 AC1/AC5/AC23).

```
/setup project
/setup orchestration
/setup team [--refresh|--migrate-only|--no-extensions]
/setup models [set <agent> <string>|unset <agent>|set-effort <agent> <token>|unset-effort <agent>]
/setup telegram
/setup slack
```

---

## Sub: `project` — skill-delegate → `skills/scaffold-project`

**Do not implement scaffold behavior here.** Read and follow
`skills/scaffold-project/SKILL.md` with remaining args passed through unchanged.

| Invocation | Maps from | Expected behavior |
|------------|-----------|-------------------|
| `/setup project` | scaffold-project skill | Create TDD structure: `.claude/plans/`, `specs/TDD.md`, `AGENTS.md`, `CONTEXT.md`, settings allowlist, memory seed. Idempotent; ask before overwrite. |

Args: none required in the current surface (skill may accept a project name /
directory per its own instructions). Preserve every MUST from SPEC-005 scaffold
path (single-root `$PROJ_ROOT` via `--show-toplevel`, no silent overwrite).

**Doctor — soft advisory only (MUST NOT block):** before or after scaffold,
recommend running plugin doctor. Never hard-fail on doctor exit 2.

```
Recommended: run /doctor (plugin surface dev-team:doctor — not the Claude Code
harness built-in /doctor) after scaffold to verify install health.
```

---

## Sub: `orchestration` — skill-delegate → `skills/init-orchestration`

**Do not implement orchestration bootstrap here.** Read and follow
`skills/init-orchestration/SKILL.md` with remaining args passed through unchanged.

| Invocation | Maps from | Expected behavior |
|------------|-----------|-------------------|
| `/setup orchestration` | init-orchestration skill | Merge sandbox + hooks + `auto` posture (Cell D) into settings; emit hook scripts; AGENTS.md team section; CLAUDE.md reference; seed orchestrator memory. Safe re-run (merge, not clobber). |

Args: optional `--skip-doctor` (pass through). Doctor hard-gate lives at the
**start** of `skills/init-orchestration/SKILL.md` (before any mutation). Preserve
every MUST from SPEC-005 orchestration path (worktree-safe hook paths, network
allowlist confirm, idempotent merge). Step 2 detects commit signing
(`commit.gpgsign` / `tag.gpgsign`) and offers a sandbox allowlist merge.

**Force-overwrite disclosure (SPEC-005 / CDT-51 AC5):** when orchestration
re-run force-changes a managed settings value (especially
`permissions.defaultMode`) or replaces a managed hook, the skill protocol
**MUST** print old value, new value, and restore key/path before writing
(`skills/init-orchestration/disclose-force-overwrite.sh`). Forced + silent =
FAIL. See init-orchestration Step 3 brownfield merge.

**Not pure zero-intervention under `auto` (CDT-68):** settings.json merge,
writing `bash-compress.sh`, and writing `escalation-gate.sh` (SPEC-031's
blocking `PreToolUse` hook) are self-escalation-guarded and need explicit
user approval. Agents **MUST** batch all three approvals in **one** up-front
ask (settings merge + bash-compress + escalation-gate by name), including
escalation-gate.sh's honest-limits framing — it is **not tamper-proof**: Bash
bypasses it, the arming actor is the enforced actor, coverage is
tool-name-scoped, and path matching falls back to unnormalized `..`
traversal when `realpath` is unavailable — see
`skills/init-orchestration/SKILL.md` § Permission batching, and SPEC-031
§ Hook contract — honest limits. Do not strip `permissionDecision:"allow"`
from bash-compress without evidence. Doctor circular self-block is fixed via
`--gate=orchestration` (CDT-67).

---

## Sub: `team` — inline (former init-team command)

Perform SQLite memory setup, then use the project-init subagent to initialize the
team's memory for the current project.

Note: project-init needs Read, Write, Bash, and Glob permissions. Run this in the
foreground (not as a background task) so tool permission prompts can be approved.

### Flag handling

Parse flags from remaining args after `team` (or `$ARGUMENTS` for this sub):
- `--refresh` — re-check embedding configuration, re-check extensions, re-run migration for any new .md files
- `--migrate-only` — only run migration, skip everything else (DB init, extensions, project-init agent)
- `--no-extensions` — skip binary download (for air-gapped setups where the user installs extensions manually)
- `--skip-doctor` — skip the doctor hard-gate (prints WARNING, then continues; silent skip forbidden)

Flag pass-through: any combination of the four is accepted; unrecognized tokens
after `team` are ignored for dispatch purposes but should be reported if they
look like flags (`--*`).

### Step 0: Doctor hard-gate (before any mutation)

Hard-gate on plugin **`dev-team:doctor`** with `--gate=team` (SPEC-022 M6b/M6c; NOT
harness `/doctor`). Run before Steps 1+ mutate memory/settings. Exit ≤1 (PASS, WARN,
or self-remediating FAIL) continues; exit 2 (blocking FAIL) **blocks** bootstrap.

```bash
# Parse --skip-doctor from the user's text (do not strip other flags). A
# Bash-tool fence has no positional arguments: read the text through a quoted
# heredoc, then split it with globbing off (skill-lint C9).
# Locate the dev-team plugin root (PDH). Optional CLAUDE_PLUGIN_ROOT (force path / FR #48230), else cwd only when it is the dev-team plugin itself (CDT-265), else marketplace clone (slug-free agents/pm.md), else installed cache (rank by /dev-team/<VER>/ segment, not full path; CDT-166). CDT-82: marketplace before same-version cache.
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
printf 'PDH=%s\n' "$PDH" >&2
ARGS=$(cat <<'__A__'
$ARGUMENTS
__A__
)
set -f; set -- $ARGS; set +f
SKIP_DOCTOR=0
for _a in "$@"; do
  case "$_a" in --skip-doctor) SKIP_DOCTOR=1 ;; esac
done

if [ "$SKIP_DOCTOR" -eq 1 ]; then
  echo "WARNING: doctor gate skipped (--skip-doctor). Proceeding without dev-team:doctor health check." >&2
else
  DOCTOR_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/doctor/doctor.sh 2>/dev/null) || DOCTOR_SH=""
  if [ -z "$DOCTOR_SH" ] || [ ! -f "$DOCTOR_SH" ]; then
    echo "FAIL: dev-team:doctor (plugin /doctor) not found — cannot gate /setup team." >&2
    echo "Remediation: reinstall the dev-team plugin, then re-run /setup team (or pass --skip-doctor)." >&2
    exit 2
  fi
  set +e
  bash "$DOCTOR_SH" --gate=team
  DOCTOR_RC=$?
  set -e
  if [ "$DOCTOR_RC" -ge 2 ]; then
    echo "FAIL: dev-team:doctor exited $DOCTOR_RC (FAIL). /setup team blocked." >&2
    echo "Remediation: fix FAIL rows above, re-run /doctor (plugin surface dev-team:doctor — not the Claude Code harness /doctor), then retry /setup team. Override: /setup team --skip-doctor" >&2
    exit 2
  fi
  # exit 0 (PASS) or 1 (WARN / self-remediating under --gate=team) → continue
fi
```

### Step 1: Resolve project root and plugin path

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
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
PLUGIN_DIR=$(bash "$PDH/skills/plugin-dir.sh" dir skills/memory-store/schema.sql)
if [ -z "$PLUGIN_DIR" ] || [ ! -f "$PLUGIN_DIR/schema.sql" ]; then
  echo "WARNING: Could not find dev-team plugin memory-store skills. SQLite setup will be skipped."
  PLUGIN_DIR=""
fi
echo "Plugin dir: $PLUGIN_DIR"
```

### Step 2: Initialize SQLite memory DB

Skip this step if `--migrate-only` is set.

```bash
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
PLUGIN_DIR=$(bash "$PDH/skills/plugin-dir.sh" dir skills/memory-store/schema.sql 2>/dev/null) || PLUGIN_DIR=""
if [ -z "$PLUGIN_DIR" ] || [ ! -f "$PLUGIN_DIR/schema.sql" ]; then
  echo "WARNING: dev-team plugin memory-store skills not found (schema.sql)." >&2
  PLUGIN_DIR=""
fi
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
mkdir -p "$MROOT/.claude/memory"
if command -v sqlite3 &>/dev/null && [ -n "$PLUGIN_DIR" ]; then
  sqlite3 -cmd ".timeout 5000" "$MEMDB" < "$PLUGIN_DIR/schema.sql"
  echo "SQLite memory DB initialized at $MEMDB"
else
  echo "WARNING: sqlite3 or plugin not found. Using .md memory fallback."
fi
```

This is idempotent — schema uses `CREATE TABLE IF NOT EXISTS` and `INSERT OR IGNORE`, so re-running is safe.

### Step 2.5: Run schema migration (if upgrading)

If the DB already existed before Step 2, check if it needs a schema upgrade:

```bash
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
PLUGIN_DIR=$(bash "$PDH/skills/plugin-dir.sh" dir skills/memory-store/migrate.sh 2>/dev/null) || PLUGIN_DIR=""
if [ -z "$PLUGIN_DIR" ] || [ ! -f "$PLUGIN_DIR/migrate.sh" ]; then
  echo "WARNING: dev-team plugin memory-store skills not found (migrate.sh)." >&2
  PLUGIN_DIR=""
fi
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
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

### Step 3: Download extensions (unless --no-extensions or --migrate-only)

Skip this step if `--no-extensions` or `--migrate-only` is set.

```bash
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
PLUGIN_DIR=$(bash "$PDH/skills/plugin-dir.sh" dir skills/memory-store/download-extensions.sh 2>/dev/null) || PLUGIN_DIR=""
if [ -z "$PLUGIN_DIR" ] || [ ! -f "$PLUGIN_DIR/download-extensions.sh" ]; then
  echo "WARNING: dev-team plugin memory-store skills not found (download-extensions.sh)." >&2
  PLUGIN_DIR=""
fi
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
if command -v sqlite3 &>/dev/null && [ -n "$PLUGIN_DIR" ]; then
  # A failed or partial run does not matter here: Step 5 re-checks the memory
  # .gitignore block every time (idempotent), so nothing is passed to Step 5.
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

### Step 4: Run migration (if .md files exist)

Skip this step if `--migrate-only` is NOT set AND this is the first run (no prior .md files). Always run on `--migrate-only` or `--refresh`.

```bash
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
PLUGIN_DIR=$(bash "$PDH/skills/plugin-dir.sh" dir skills/memory-store/migrate-md.sh 2>/dev/null) || PLUGIN_DIR=""
if [ -z "$PLUGIN_DIR" ] || [ ! -f "$PLUGIN_DIR/migrate-md.sh" ]; then
  echo "WARNING: dev-team plugin memory-store skills not found (migrate-md.sh)." >&2
  PLUGIN_DIR=""
fi
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
if command -v sqlite3 &>/dev/null && [ -f "$MEMDB" ] && [ -n "$PLUGIN_DIR" ]; then
  bash "$PLUGIN_DIR/migrate-md.sh" "$MROOT"
fi
```

### Step 5: Update .gitignore (fallback)

Skip this step if `--migrate-only` is set.

`download-extensions.sh` (Step 3) is the single source of the 5-line memory
`.gitignore` block. This step is the **fallback** for the paths where Step 3
did not run or did not finish — `--no-extensions`, `sqlite3`/`PLUGIN_DIR`
unavailable, or a failed download — so no init path loses gitignore coverage.
Each step runs in its own shell, so Step 3 cannot pass a flag to this step.
This step always runs. The `grep -qF || echo` guard skips an entry that is
already present.

**Never** write a bare `.claude/memory/` exclude here — use child globs only so a
committed seed pack under `.claude/memory/seed/` stays committable (SPEC-024 M9).

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
GITIGNORE="$MROOT/.gitignore"
for ENTRY in \
  ".claude/memory/extensions/" \
  ".claude/memory/models/" \
  ".claude/memory/memory.db" \
  ".claude/memory/memory.db-wal" \
  ".claude/memory/memory.db-shm" \
  ".claude/handoff/" \
  ".claude/retro/" \
  ".claude/dev-team/models.local.json*"; do
  grep -qF "$ENTRY" "$GITIGNORE" 2>/dev/null || echo "$ENTRY" >> "$GITIGNORE"
done
# Seed carve-out (child-glob + negations) when a pack may be committed
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
COMMON=$(bash "$PDH/skills/plugin-dir.sh" file skills/memory-store/seed-common.sh 2>/dev/null || true)
if [ -n "$COMMON" ] && [ -f "$COMMON" ]; then
  # shellcheck disable=SC1090
  . "$COMMON"
  ensure_seed_gitignore "$MROOT" || true
fi
echo "Checked .gitignore entries (fallback)."
```

### Step 5.5: Import memory seed pack (if present)

Skip this step if `--migrate-only` is set.

Runs on **first init and `--refresh`**. If `.claude/memory/seed/manifest.json` is
absent, do nothing (no new output — SPEC-024 M11 graceful absence). A bad pack
never blocks bootstrap: import always exits 0 and prints counts/warnings only.

Import runs **after** DB init + extensions + md-migrate + gitignore, and
**before** project-init (Step 6). Print the pack file list. Ask the user to
confirm it. Import only after that confirm. Rows land at tier 0 with the
provenance marker `imported — untrusted` (SPEC-024 M5). A pack without
confirm is refused and does not block bootstrap.

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
SEED_IMPORT_SUMMARY=""
if [ -f "$MROOT/.claude/memory/seed/manifest.json" ]; then
  PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
  IMPORT_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/memory-store/import-seed-pack.sh)
  if [ -n "$IMPORT_SH" ] && [ -f "$IMPORT_SH" ]; then
    find "$MROOT/.claude/memory/seed" -type f -print
    if [ "${SEED_IMPORT_CONFIRM:-}" = "1" ]; then
      SEED_IMPORT_SUMMARY=$(bash "$IMPORT_SH" --confirm "$MROOT" 2>&1) || true
      echo "$SEED_IMPORT_SUMMARY"
    else
      echo "seed import refused: review the pack list, then re-run with SEED_IMPORT_CONFIRM=1"
    fi
  else
    echo "WARNING: seed pack present but import-seed-pack.sh not found — skipping import"
  fi
fi
```

### Step 5b: Add required hosts to sandbox network allowlist

Collect all hosts that need sandbox network access. Always include `github.com:22`
(for git push over SSH). If `$EMBEDDING_URL` is set, also include the embedding host.
For each host, check if it's already in the allowlist. If not, add it.

**IMPORTANT — not pure zero-intervention under `auto` (CDT-68):** two layers
can block settings writes, not just the sandbox:

1. **Sandbox** — `.claude/settings.json` is sandbox-protected. On sandbox deny,
   retry with `dangerouslyDisableSandbox: true` (user approves once per command).
2. **Permission classifier under `auto`** — writes to `settings.json` (Edit or
   jq-via-Bash) are self-escalation-guarded. Generic "approve edits" is often
   rejected; the user must **explicitly** approve the write by name.

**Approval up front (MUST):** before this `team`-path settings merge, ask the user
**once** for the merge, e.g.:

```
This bootstrap needs one explicit approval (`auto` self-escalation guard —
not removable without losing the guard):
  1. Merge into .claude/settings.json (sandbox network allowlist + team permissions)
Approve it so the rest of /setup can run without mid-run denials?
```

Do **not** discover this mid-run as a separate denial. The `team` path writes no
hook script. `/setup orchestration` owns `bash-compress.sh` and its approval
(`skills/init-orchestration/SKILL.md` § Permission batching).

Temp paths in any bypass-retry snippet: use `"${TMPDIR:-/tmp}/…"` (or
`mktemp`) — bare `$TMPDIR` is unset outside the sandbox.

This step is one fence. Each fence runs in its own shell, so `SETTINGS` and
`HOSTS_TO_ADD` must be set in the fence that uses them.

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

if command -v jq &>/dev/null; then
  # Ensure settings.json exists with minimal structure
  mkdir -p "$MROOT/.claude"
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

### Step 6: Invoke project-init agent

Skip this step if `--migrate-only` or `--refresh` is set. Project-init only runs on first initialization — `--refresh` re-checks extensions and embeddings but does NOT rescan the project or rewrite cortex data.

Use the project-init subagent to scan the project and write cortex.md files for all 7 team agents.

### Step 7: Post-bootstrap hints

After all steps complete, print:

```
Tip: Use /adjust-agent to set per-agent behavioral directives for this project.
```

If Step 5.5 produced a `seed-import:` summary line, also print a one-line warm-start
note for the user (SPEC-024 SHOULD), e.g.:

```
warm start: N memories imported for M agents from pack dated <date>; K rejected
```

Parse counts from the `seed-import:` line that Step 5.5 printed. No variable carries
over from that step, because each step runs in its own shell. Omit this line entirely
when no pack was present (M11).

---

## Sub: `models` — skill-delegate → `skills/model-map/write-model.sh`

Local Model map only (SPEC-037). **Do not** write repo
`$MROOT/.claude/dev-team/models.json` or global `~/.claude/dev-team/models.json`.
**Do not** inline JSON writes in this command — call `write-model.sh` as a
subprocess. **Not** doctor-gated (unlike `team` / `orchestration`). Unknown
remainder after a known `models` verb still must not mutate the model map:
pass through to the CLI (bad argv → exit 64, no JSON write).
The same fence appends three `.gitignore` lines when they are absent.
That ignore update is idempotent. It is not a model-map write.

| Invocation | Maps to |
|------------|---------|
| `/setup models` | `write-model.sh list` (read-only; model + effort) |
| `/setup models set <agent> <string>` | `write-model.sh set <agent> <string>` |
| `/setup models unset <agent>` | `write-model.sh unset <agent>` |
| `/setup models set-effort <agent> <token>` | `write-model.sh set-effort <agent> <token>` |
| `/setup models unset-effort <agent>` | `write-model.sh unset-effort <agent>` |

Protocol (also in `skills/model-map/SKILL.md`):

```bash
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
WRITE_MODEL=$(bash "$PDH/skills/plugin-dir.sh" file skills/model-map/write-model.sh)
if [ -z "$WRITE_MODEL" ] || [ ! -f "$WRITE_MODEL" ]; then
  echo "error: skills/model-map/write-model.sh not found in the installed plugin" >&2
  exit 1
fi
# Ignore handoff spines, the friction ledger, and local model pins.
# Idempotent. This is not a model-map write. list stays read-only for JSON.
# show-toplevel: .gitignore is this worktree's file, not the common-dir parent.
RT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
RT_GI="$RT_ROOT/.gitignore"
for RT_ENTRY in \
  ".claude/handoff/" \
  ".claude/retro/" \
  ".claude/dev-team/models.local.json*"; do
  grep -qF -- "$RT_ENTRY" "$RT_GI" 2>/dev/null || printf '%s\n' "$RT_ENTRY" >> "$RT_GI"
done
# Remaining args after `models` pass through unchanged (empty → list). A
# Bash-tool fence has no positional arguments: read the user's text through a
# quoted heredoc, then split it with globbing off (skill-lint C9).
ARGS=$(cat <<'__A__'
$ARGUMENTS
__A__
)
set -f; set -- $ARGS; set +f
[ "${1:-}" = "models" ] && shift
bash "$WRITE_MODEL" "${1:-list}" "${@:2}"
```

Surface CLI stderr (M9 adversarial warn, unparseable refuse). Do not reimplement
layer merge — `list` calls `resolve-model.sh`.

---

## Sub: `telegram` — skill-delegate → `skills/intercom/setup-telegram.sh`

Configure the Telegram Intercom (SPEC-038). The script is interactive: it
prompts for the bot token, validates via `getMe`, pairs the operator chat,
writes state under the state root (outside the repo; `INTERCOM_STATE_ROOT`
honored), and prints the harness schedule prompt. Run it in the foreground so
the token prompt can be answered. The command documents and delegates only —
**do not** inline any setup behavior here. Not doctor-gated. The script takes
no flags; extra arguments are not forwarded.

```bash
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
TG_SETUP=$(bash "$PDH/skills/plugin-dir.sh" file skills/intercom/setup-telegram.sh)
if [ -z "$TG_SETUP" ] || [ ! -f "$TG_SETUP" ]; then
  echo "error: skills/intercom/setup-telegram.sh not found in the installed plugin" >&2
  exit 1
fi
bash "$TG_SETUP"
```

---

## Sub: `slack` — inline zero-write stub (AC5)

Slack is out of scope in phase 1 (SPEC-038). Print the notice and stop. Zero
state writes: no token file, no config, no spool artifact.

```bash
# AC5: zero state writes — print the notice and exit 0.
echo 'Slack ships in v1.1/v2.'
exit 0
```
