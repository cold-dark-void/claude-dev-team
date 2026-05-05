---
name: init-orchestration
description: Bootstrap Agent Teams orchestration for any project. Enables bubblewrap sandbox with auto-detected network allowlist, bypassPermissions for zero-prompt agents, CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS, and PostToolUse + Stop + TaskCompleted hooks. Creates/updates AGENTS.md with team coordination rules and CLAUDE.md as reference. Run once per project. Safe to re-run — existing files are merged, not overwritten.
---

# Init Orchestration

Bootstrap the files needed for Claude Code Agent Teams in the current project.

## What Gets Created / Updated

```
project/
├── .claude/
│   ├── settings.json          # + env var + hooks section (merged)
│   ├── hooks/
│   │   ├── task-completed.sh          # Quality-gate hook (created)
│   │   ├── stop-review.sh             # Self-review gate — checks diff before agent exits (created)
│   │   ├── memory-capture.sh          # Auto memory — logs Write/Edit/Bash to tier-0 (created)
│   │   ├── bash-compress.sh           # Output compression — rewrites noisy commands (created)
│   │   └── bash-compress-wrapper.sh   # Compression wrapper — head/tail with exit code (created)
│   └── memory/
│       └── claude/
│           └── memory.md      # Orchestrator rules seeded (created or appended)
├── AGENTS.md                  # Team coordination rules (created or appended)
└── CLAUDE.md                  # AGENTS.md reference (created, existing content migrated)
```

## Instructions

### Step 1: Inventory what exists

Check for existing files:
```bash
ls .claude/settings.json 2>/dev/null && echo "settings exists"
ls AGENTS.md 2>/dev/null && echo "agents exists"
ls CLAUDE.md 2>/dev/null && echo "claude.md exists"
```

Note which files exist — they get merged, not overwritten.

**Upgrade check — always run regardless of prior initialization:**

Even if the project was previously initialized, scan ALL hook commands in settings.json for:

1. **Pipe operators (`|`)** — pipes in hooks fail in the sandbox and poison the session, every subsequent bash command fails. Warn the user:
```
⚠️  Piped hook commands detected — these will poison the session and break all bash:
  [list the commands]
Fix: remove '| <cmd>' from each. Example: 'go vet ./... 2>&1 | head -20' → 'go vet ./... 2>&1'
Restart required after fixing.
```

2. **Worktree-unsafe relative paths** — commands of the form `bash .claude/hooks/<name>.sh` resolve from the agent's cwd, not the project root. Inside a git worktree (which doesn't share `.claude/`) every Bash tool call fails with "No such file or directory". Auto-rewrite these to use `${CLAUDE_PROJECT_DIR}`:
```
bash .claude/hooks/X.sh  →  bash "${CLAUDE_PROJECT_DIR}/.claude/hooks/X.sh"
```
Apply this rewrite for every hook command matching the relative pattern. Note this in the Step 9 summary as an upgrade applied.

If any upgrade keys are missing, proceed through the relevant steps to add them. Report what was upgraded in the Step 9 summary.

---

### Step 2: Detect sandbox network needs

The sandbox blocks all outbound network by default. Auto-detect what the project needs, then confirm with the user before writing settings.json.

**Auto-detect** — check for these files and map to domains:

| File | Domains to add |
|------|---------------|
| `package.json` or `pnpm-lock.yaml` or `yarn.lock` | `registry.npmjs.org`, `npmjs.com` |
| `go.mod` | `proxy.golang.org`, `sum.golang.org` |
| `requirements.txt` or `pyproject.toml` or `Pipfile` | `pypi.org`, `files.pythonhosted.org` |
| `Cargo.toml` | `crates.io`, `static.crates.io` |
| `Gemfile` | `rubygems.org` |
| `.git/config` containing `github.com` | `github.com` |
| `.git/config` containing `gitlab.com` | `gitlab.com` |
| `.git/config` containing `bitbucket.org` | `bitbucket.org` |

```bash
# Example detection
ls package.json pnpm-lock.yaml yarn.lock 2>/dev/null
ls go.mod 2>/dev/null
ls requirements.txt pyproject.toml Pipfile 2>/dev/null
ls Cargo.toml 2>/dev/null
ls Gemfile 2>/dev/null
git remote get-url origin 2>/dev/null
```

**Present to user:**

```
Sandbox network configuration — the sandbox blocks all outbound network by default.

Auto-detected from your project:
  ✓ github.com          (git remote)
  ✓ registry.npmjs.org  (package.json)
  ✓ npmjs.com           (package.json)

Other common domains you might need:
  · pypi.org, files.pythonhosted.org    (Python)
  · proxy.golang.org, sum.golang.org    (Go)
  · crates.io, static.crates.io        (Rust)
  · rubygems.org                        (Ruby)
  · registry.hub.docker.com, ghcr.io   (Docker images)

Add any of the above, or custom domains? (comma-separated, or "none" to use only auto-detected)
```

Collect the user's answer. Build the final `allowedDomains` list (auto-detected + user-specified). Hold this list for Step 3.

If the user says "none" and auto-detection found domains, still use the auto-detected ones.
If the user says "skip" or "no sandbox", note that sandbox should be disabled — Step 3 will set `sandbox.enabled` to `false`.

#### Go project sandbox workarounds

If `go.mod` was detected, agents will need writable Go build and module caches.
The sandbox blocks `~/.cache/go-build/` by default. Inform the user:

```
Go project detected. Agents running `go build` or `go test` in sandbox mode need
a writable build cache. Two options:

1. (Recommended) Agents will use GOCACHE=$TMPDIR/go-cache GOWORK=off automatically
2. Add ~/.cache/go-build to sandbox filesystem write allowlist

Option 1 requires no config changes — I'll seed this into orchestrator memory.
```

If user picks option 1 (default), append this to the orchestrator memory content in Step 7:
```
- Go project: agents MUST prefix build/test commands with `GOWORK=off GOCACHE=$TMPDIR/go-cache`
  to avoid sandbox read-only cache errors. Inject this into IC agent prompts.
```

If user picks option 2, add to `.claude/settings.json` sandbox filesystem section:
```json
"filesystem": {
  "write": {
    "allowOnly": ["~/.cache/go-build"]
  }
}
```

---

### Step 3: Write .claude/settings.json

Using the `allowedDomains` list from Step 2, write the settings file.

**If `settings.json` does not exist** — create it:

```json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/bash-compress.sh\""
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/memory-capture.sh\""
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/stop-review.sh\""
          }
        ]
      }
    ],
    "TaskCompleted": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/task-completed.sh\""
          }
        ]
      }
    ]
  },
  "sandbox": {
    "enabled": true,
    "autoAllowBashIfSandboxed": true,
    "excludedCommands": ["docker", "docker-compose"],
    "network": {
      "allowedDomains": ["<domains from Step 2>"]
    }
  },
  "permissions": {
    "allow": [
      "Bash(*)"
    ],
    "defaultMode": "bypassPermissions"
  }
}
```

**If `settings.json` already exists** — read it, then merge in the missing keys:
- Add `"env": { "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1" }` if `env` key is absent
- If `env` key exists but lacks `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`, add it to the existing `env` object
- Add the `PreToolUse`, `PostToolUse`, `Stop`, and `TaskCompleted` hooks entries if `hooks` key is absent
- If `hooks` key exists but lacks `PreToolUse`, `PostToolUse`, `Stop`, or `TaskCompleted`, add the missing ones
- Add `sandbox` block if absent (`enabled: true`, `autoAllowBashIfSandboxed: true`, `excludedCommands: ["docker", "docker-compose"]`, `network.allowedDomains` from Step 2). If `sandbox` exists: ensure `enabled` is `true` and `autoAllowBashIfSandboxed` is `true`; merge new domains into existing `allowedDomains` (no duplicates); preserve any existing `filesystem` overrides
- Ensure `permissions.allow` contains `"Bash(*)"` and `permissions.defaultMode` is `"bypassPermissions"` — add or update as needed, but preserve any other existing allow entries
- Write the merged result back as valid JSON

---

### Step 4: Create .claude/hooks/task-completed.sh

Create `.claude/hooks/` directory:

```bash
mkdir -p .claude/hooks
```

**IMPORTANT — use the `Write` tool (NOT a bash heredoc) to create each hook file below.**

Use the `Write` tool to create `.claude/hooks/task-completed.sh` with this content:

```bash
#!/usr/bin/env bash
# TaskCompleted hook — quality gate that runs before any task is marked done.
# Exit code 2 = block completion (stderr is fed back to the agent as feedback).
# Exit code 0 = allow completion.
#
# Customize this script for your project. Examples:
#   - Run tests: npm test / go test ./... / pytest
#   - Validate JSON/YAML config files
#   - Check for lint errors
#   - Verify build artifacts exist
#
# Input (via stdin): JSON with task_id, task_subject, task_description, teammate_name, team_name

# Uncomment and adapt the check(s) relevant to your project:

# --- Example: require tests to pass ---
# if ! npm test 2>&1; then
#   echo "Tests must pass before completing task." >&2
#   exit 2
# fi

# --- Example: validate JSON config files ---
# for f in package.json tsconfig.json; do
#   if [ -f "$f" ] && ! python3 -c "import json,sys; json.load(open('$f'))" 2>/dev/null; then
#     echo "$f is not valid JSON" >&2
#     exit 2
#   fi
# done

# --- Example: check for spec updates when source files change ---
# CHANGED=$(git diff --cached --name-only 2>/dev/null || true)
# if echo "$CHANGED" | grep -qE '\.(go|ts|py|rs|java)$'; then
#   if ! echo "$CHANGED" | grep -q 'specs/'; then
#     echo "WARNING: Source files changed but no spec files updated." >&2
#     echo "Verify that related specs in specs/ are still accurate." >&2
#     # Uncomment the next line to hard-block commits without spec updates:
#     # exit 2
#   fi
# fi

exit 0
```

Then make it executable:
```bash
chmod +x .claude/hooks/task-completed.sh
```

---

### Step 4b: Create .claude/hooks/stop-review.sh

Use the `Write` tool to create `.claude/hooks/stop-review.sh` with this content:

```bash
#!/usr/bin/env bash
# Stop hook — non-blocking self-review reminder.
# Prints once per (cwd + HEAD-sha) when uncommitted changes exist; never blocks exit.
# The stamp re-fires when HEAD moves (a commit lands), not on every `claude --resume`.

if ! git rev-parse --git-dir &>/dev/null; then
  exit 0
fi

_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && _MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || _MROOT=$(pwd)

# Drain stdin so the harness doesn't block on the pipe; we don't need its content.
TMPF="${TMPDIR:-/tmp}/stop-review-$$"
timeout 1 cat > "$TMPF" 2>/dev/null || true
rm -f "$TMPF"

HEAD_SHA=$(git -C "$_MROOT" rev-parse --short HEAD 2>/dev/null || echo "nohead")
CWD_HASH=$(printf '%s' "$PWD" | cksum | cut -d' ' -f1)
STAMP_KEY="${CWD_HASH}-${HEAD_SHA}"
STAMP="$_MROOT/.claude/.stop-review-${STAMP_KEY}"

[ -f "$STAMP" ] && exit 0

DIRTY=$(git status --porcelain 2>/dev/null)
[ -z "$DIRTY" ] && exit 0

MODIFIED=0
while IFS= read -r line; do
  case "$line" in
    [MADRC]\ *|\ [MADRC]\ *) MODIFIED=$(( MODIFIED + 1 )) ;;
  esac
done <<< "$DIRTY"

if [ "$MODIFIED" -gt 0 ]; then
  # Sweep stale stamps from prior HEAD shas to keep .claude/ tidy.
  find "$_MROOT/.claude" -maxdepth 1 -name '.stop-review-*' \
    ! -name ".stop-review-${STAMP_KEY}" -delete 2>/dev/null || true
  touch "$STAMP"
  printf "Stop hook: %d file(s) modified but not committed.\n" "$MODIFIED"
fi

exit 0
```

Then make it executable:
```bash
chmod +x .claude/hooks/stop-review.sh
```

**Re-running on an existing install**: if `.claude/hooks/stop-review.sh` already exists and contains `exit 2` (the legacy blocking version) or references `SESSION_ID` for its stamp key, overwrite it with the content above. Sweep stale stamps with `find .claude -maxdepth 1 -name '.stop-review-*' -delete`.

---

### Step 4c: Create .claude/hooks/memory-capture.sh

Use the `Write` tool to create `.claude/hooks/memory-capture.sh` with this content:

```bash
#!/usr/bin/env bash
# PostToolUse hook — automatic memory capture for agent observations.
# Logs Write/Edit/Bash to tier-0 memory in SQLite. Exit 0 always.

_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
MEMDB="$MROOT/.claude/memory/memory.db"

[ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null || exit 0

TMPF="${TMPDIR:-/tmp}/memcap-$$"
cat > "$TMPF"

TOOL_NAME=$(jq -r '.tool_name // empty' "$TMPF" 2>/dev/null)

case "$TOOL_NAME" in
  Write|Edit|Bash) ;;
  *) rm -f "$TMPF"; exit 0 ;;
esac

AGENT=$(jq -r '.teammate_name // "auto"' "$TMPF" 2>/dev/null || echo "auto")

case "$TOOL_NAME" in
  Write)
    FILE_PATH=$(jq -r '.tool_input.file_path // empty' "$TMPF" 2>/dev/null)
    OBSERVATION="wrote $FILE_PATH"
    ;;
  Edit)
    FILE_PATH=$(jq -r '.tool_input.file_path // empty' "$TMPF" 2>/dev/null)
    OBSERVATION="edited $FILE_PATH"
    ;;
  Bash)
    RAW=$(jq -r '.tool_input.command // empty' "$TMPF" 2>/dev/null)
    RAW="${RAW:0:120}"
    OBSERVATION="ran: $RAW"
    ;;
esac

rm -f "$TMPF"
[ -z "$OBSERVATION" ] && exit 0

DEDUP_FILE="${TMPDIR:-/tmp}/.claude-memcap-last"
LAST=$(cat "$DEDUP_FILE" 2>/dev/null || true)
[ "$OBSERVATION" = "$LAST" ] && exit 0
printf '%s' "$OBSERVATION" > "$DEDUP_FILE"

sqlite3 "$MEMDB" \
  "INSERT INTO memories(agent, type, content) VALUES (?, 'memory', ?);" \
  "$AGENT" "$OBSERVATION" 2>/dev/null || true

exit 0
```

Then make it executable:
```bash
chmod +x .claude/hooks/memory-capture.sh
```

---

### Step 4d: Create .claude/hooks/bash-compress.sh and bash-compress-wrapper.sh

Use the `Write` tool to create `.claude/hooks/bash-compress.sh` with this content:

```bash
#!/usr/bin/env bash
# PreToolUse hook — rewrites noisy Bash commands to compress output.
# Exit 0 with no stdout = pass through unchanged.

TMPF="${TMPDIR:-/tmp}/bcompress-$$"
cat > "$TMPF"

TOOL_NAME=$(jq -r '.tool_name // empty' "$TMPF" 2>/dev/null)
[ "$TOOL_NAME" = "Bash" ] || { rm -f "$TMPF"; exit 0; }

COMMAND=$(jq -r '.tool_input.command // empty' "$TMPF" 2>/dev/null)
rm -f "$TMPF"
[ -z "$COMMAND" ] && exit 0

NOISY=false
case "$COMMAND" in
  npm\ test*|npx\ jest*|npx\ vitest*|yarn\ test*|pnpm\ test*) NOISY=true ;;
  pytest*|python\ -m\ pytest*) NOISY=true ;;
  go\ test*) NOISY=true ;;
  cargo\ test*) NOISY=true ;;
  mvn\ test*|gradle\ test*) NOISY=true ;;
  npm\ run\ build*|yarn\ build*|pnpm\ build*) NOISY=true ;;
  cargo\ build*) NOISY=true ;;
  make\ *|make) NOISY=true ;;
  tsc\ *|tsc) NOISY=true ;;
esac

[ "$NOISY" = "false" ] && exit 0

WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
WRAPPER="$WTROOT/.claude/hooks/bash-compress-wrapper.sh"
[ -f "$WRAPPER" ] || exit 0

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"Bash output compression","updatedInput":{"command":"bash %s %s"}}}\n' "$WRAPPER" "$COMMAND"
```

Make it executable:
```bash
chmod +x .claude/hooks/bash-compress.sh
```

Write `.claude/hooks/bash-compress-wrapper.sh`:

```bash
#!/usr/bin/env bash
# Runs a command and compresses output if it exceeds a threshold.
# Preserves exit code. Shows first/last N lines with omitted count.

THRESHOLD=50
HEAD_LINES=20
TAIL_LINES=20

OUTPUT=$("$@" 2>&1)
EXIT_CODE=$?

TMPF="${TMPDIR:-/tmp}/bcompress-out-$$"
printf '%s\n' "$OUTPUT" > "$TMPF"
LINE_COUNT=$(awk 'END{print NR}' "$TMPF")

if [ "$LINE_COUNT" -le "$THRESHOLD" ]; then
  cat "$TMPF"
else
  OMITTED=$(( LINE_COUNT - HEAD_LINES - TAIL_LINES ))
  printf '[compressed: %d lines -> %d lines]\n' "$LINE_COUNT" $(( HEAD_LINES + TAIL_LINES ))
  head -"$HEAD_LINES" "$TMPF"
  printf '\n... %d lines omitted ...\n\n' "$OMITTED"
  tail -"$TAIL_LINES" "$TMPF"
fi

rm -f "$TMPF"
exit $EXIT_CODE
```

Use the `Write` tool to create `.claude/hooks/bash-compress-wrapper.sh` with the content above, then:

```bash
chmod +x .claude/hooks/bash-compress.sh .claude/hooks/bash-compress-wrapper.sh
```

---

### Step 5: Create or update AGENTS.md

**If `AGENTS.md` does not exist** — create it with a full template (see below).

**If `AGENTS.md` already exists** — read it, then check if it already has an `## Agent Teams` or `## Team Coordination` section. If not, append the team coordination section (from the template below) to the end of the existing file.

#### AGENTS.md template (new file)

```markdown
# AGENTS.md — <PROJECT NAME>

Project-specific rules for all agents (Claude Code teammates, subagents, CI).
Read this file at the start of every session before doing any work.

## Project Overview

**Description**: [What this project does]
**Tech stack**: [Primary language/framework]
**Build**: [How to build, e.g., `go build ./...` or `npm run build`]
**Test**: [How to run tests, e.g., `go test ./...` or `npm test`]

## Critical Rules

**DO:**
- Update spec files whenever behavioral changes are made
- Use project-local paths for all plans, specs, and memory — never global `~/.claude/` paths
- When releasing, bump ALL version references (code, config, changelog, tags)
- When comparing or cross-checking documents, analyze differences first — never blindly merge

**DO NOT:**
- Over-plan: if asked for a fix or implementation, proceed quickly unless a plan is explicitly requested
- Write to global paths (`~/.claude/`) when project-local paths exist
- Commit implementation changes without checking if related specs need updating

## Change Discipline

All agents MUST follow these rules. The orchestrator enforces them, but agents should self-police.

**Atomic PRs:**
- One logical change per PR. One ticket = one branch = one PR. Never bundle.
- If a task description needs "and" to explain it, split it first.

**Size limits:**
- ~1,000 LOC of real code per PR (soft cap). Tests, generated code, migrations don't count.
- Hard cap: 2,000 LOC total including tests. Exceeding this = stop and split.
- No single file > 1,000 lines. If approaching this, pause and discuss decomposition with Tech Lead.

**Refactoring is always separate:**
- Never mix refactoring with feature work in the same PR.
- If you need to refactor before implementing: stop, flag to orchestrator/Tech Lead, ship refactor PR first, then resume feature work on the clean base.
- Large refactors get their own ticket.

**Discovered work → new tickets:**
- Never absorb unplanned work into the current change.
- Flag it to the orchestrator. It becomes a new ticket (Linear or backlog).
- If it blocks current work, escalate — don't silently expand scope.

**Replan on deviation:**
- If your approach changes materially from the plan (new deps, scope grew, architecture assumption broken): stop all work and request a replan from Tech Lead.
- Small deviations compound. When in doubt, stop and ask.

## Project Structure

```
[paste your directory tree here]
```

## Key Files

- `[path]` — [what it does]

## Team Coordination

When working as a native Agent Team teammate:
- Check `~/.claude/teams/<team-name>/config.json` to discover other teammates
- Use `TaskList` to find available work; prefer lowest-ID tasks first
- Claim tasks with `TaskUpdate` (set `owner` to your agent name) before starting
- Mark tasks `completed` via `TaskUpdate` when done, then check `TaskList` again
- Communicate with teammates via `SendMessage` (DM); avoid broadcast unless critical
- Do NOT edit files another teammate is actively working on
- After finishing, send a status update to the team lead

## Commit Rules

- [Project-specific commit convention, e.g., conventional commits]
- Always include: `Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>`
```

Replace all `[bracketed]` and `<ANGLE BRACKET>` placeholders with actual values.

#### Team Coordination section only (appending to existing AGENTS.md)

```markdown

## Team Coordination

When working as a native Agent Team teammate:
- Check `~/.claude/teams/<team-name>/config.json` to discover other teammates
- Use `TaskList` to find available work; prefer lowest-ID tasks first
- Claim tasks with `TaskUpdate` (set `owner` to your agent name) before starting
- Mark tasks `completed` via `TaskUpdate` when done, then check `TaskList` again
- Communicate with teammates via `SendMessage` (DM); avoid broadcast unless critical
- Do NOT edit files another teammate is actively working on
- After finishing, send a status update to the team lead
```

---

### Step 6: Create or update CLAUDE.md

**If `CLAUDE.md` does not exist** — create it with just the reference line (see template below).

**If `CLAUDE.md` already exists and has content beyond an AGENTS.md reference:**
1. Read the existing `CLAUDE.md` content
2. Migrate any rules, instructions, or project details into the appropriate sections of `AGENTS.md` (created/updated in Step 5):
   - Workflow rules → `## Critical Rules`
   - Build/test/tech stack info → `## Project Overview`
   - File conventions → `## Code Conventions` or `## Critical Rules`
   - Any other project-specific instructions → appropriate AGENTS.md section
3. Do NOT duplicate — if equivalent rules already exist in AGENTS.md, skip them
4. Replace `CLAUDE.md` contents with just the reference line

**If `CLAUDE.md` already exists and is only the reference line** — no changes needed, skip.

#### CLAUDE.md template

```markdown
Read and follow [AGENTS.md](./AGENTS.md) before starting any work.
```

All project rules live in AGENTS.md. CLAUDE.md just ensures Claude Code loads them.

---

### Step 7: Seed orchestrator memory

Create the Claude Code memory directory and seed it with learned patterns from past sessions. These prevent known mistakes from being repeated in every new project.

```bash
mkdir -p .claude/memory/claude
MEMDB=".claude/memory/memory.db"
```

If sqlite3 is available and the DB does not yet exist, initialize it:
```bash
if command -v sqlite3 &>/dev/null && [ ! -f "$MEMDB" ]; then
  # Locate schema from plugin install cache
  SCHEMA=""
  for d in ~/.claude/plugins/cache/*/dev-team/*/skills/memory-store/schema.sql; do
    [ -f "$d" ] && SCHEMA="$d" && break
  done
  # Fallback: try relative to project root (dev on the plugin itself)
  [ -z "$SCHEMA" ] && SCHEMA="$(git rev-parse --show-toplevel 2>/dev/null)/skills/memory-store/schema.sql"
  if [ -f "$SCHEMA" ]; then
    sqlite3 "$MEMDB" < "$SCHEMA"

    # Probe journal mode. Some sandboxed filesystems (bubblewrap
    # tmpdirs, NFS, certain CI containers) reject WAL and SQLite
    # silently degrades to journal_mode=delete. The DB still works
    # but writes serialize across agents — surface this so the user
    # knows what they're getting.
    JMODE=$(sqlite3 "$MEMDB" "PRAGMA journal_mode;" 2>/dev/null | tr 'A-Z' 'a-z')
    if [ "$JMODE" != "wal" ]; then
      echo "⚠️  memory.db journal_mode=$JMODE (WAL rejected by this filesystem)." >&2
      echo "    DB works correctly; concurrent agent writes will serialize" >&2
      echo "    instead of running in parallel. Common cause: sandboxed tmpdir" >&2
      echo "    or NFS-backed project root. Re-running outside the sandbox or" >&2
      echo "    on a local filesystem will enable WAL." >&2
    fi
  fi
fi
```

**If `.claude/memory/claude/memory.md` does not exist AND no DB row exists** — create/seed both paths below.

**If it already exists** — read it, check if the orchestrator rules section is present. If not, append it. Do not duplicate.

#### Baseline memory content

```markdown
# Project Memory

## Orchestrator rules (seeded by /init-orchestration)

- When acting as orchestrator/coordinator, NEVER implement code directly — not even "quick fixes" for broken agent output. Always create a task and assign to an IC agent.
- After each agent phase completes, create an explicit "validate and debug" task before starting the next phase. Quality gaps between defined tasks are where bugs hide.
- Agents stuck after 2 genuine attempts → escalate to user. Don't let them loop.
- Scope creep discovered mid-implementation → pause and ask user whether to expand scope or defer to backlog. Never silently absorb extra work.
- Breaking changes (schema, API contracts, dependency bumps) → always escalate to user before proceeding.
- Batch questions for the user — don't interrupt for routine progress. Protect their time.
- When spawning agents, give them the worktree path, spec path, and plan path explicitly. Don't assume they'll find context on their own.
- Atomic PRs only — one ticket, one branch, one PR. Never bundle multiple tickets.
- ~1k LOC real code per PR (tests don't count). Hard cap 2k total. No single file > 1k lines. Exceeding = stop and split.
- Refactoring is always a separate PR — never mixed with feature work. Ship refactor first, then feature on top.
- Discovered work becomes a new ticket — never silently absorb unplanned work into the current change.
- Material approach changes → pause all IC work, Tech Lead replans, user approves before resuming.
- `dangerouslyDisableSandbox` is per-command, not a session state. Only use it when the specific command needs it (heredocs, process substitution). Never carry it forward after one command requires it — `pwd`, `ls`, `python3 -c`, `chmod` and similar never need it.
```

Write this content using the DB-first dual path.

**If DB exists:** use the `Bash` tool to run the python3 sqlite3 insert:
```bash
python3 -c "
import sqlite3, sys, datetime
db = sqlite3.connect(sys.argv[1])
db.execute('PRAGMA busy_timeout=5000')
db.execute('DELETE FROM memories WHERE agent=? AND type=? AND content LIKE ?',
           ('claude', 'memory', '%seeded by /init-orchestration%'))
db.execute('INSERT INTO memories(agent, type, content, updated_at) VALUES (?, ?, ?, ?)',
           ('claude', 'memory', sys.argv[2], datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')))
db.commit()
" "$MEMDB" "$CONTENT"
```

**If no DB:** use the `Write` tool to create `.claude/memory/claude/memory.md` with the baseline content above.

---

### Step 8: Validate

Run the hook manually to confirm it passes. Use file redirection — NOT a pipe (`echo '{}' | bash ...` poisons the session):
```bash
printf '{}' > "$TMPDIR/hook-test-$$"
bash .claude/hooks/task-completed.sh < "$TMPDIR/hook-test-$$"
echo "Hook exit code: $?"
rm -f "$TMPDIR/hook-test-$$"
```

Validate settings.json is still valid JSON:
```bash
python3 -c "import json; json.load(open('.claude/settings.json')); print('settings.json OK')"
```

**Warn about piped user hooks:** Check whether any existing hooks in settings.json use pipe operators (`|`). If found, warn the user:
```
⚠️  WARNING: The following hook commands use pipes ('|') which fail in the sandbox
and will poison the session, causing all subsequent bash commands to fail:

  [list the piped hook commands]

Fix: remove the pipe and any command after it, or replace with a non-piped equivalent.
Example: 'go vet ./... 2>&1 | head -20' → 'go vet ./... 2>&1'
A restart is required after fixing hooks.
```

---

### Step 9: Summary

Print a summary of what was done:

```
✅ Agent Teams orchestration initialized!

Updated:
  📄 .claude/settings.json   — sandbox + bypassPermissions + PreToolUse + PostToolUse + Stop + TaskCompleted hooks
      Sandbox: enabled, autoAllowBash, network: [list of configured domains]
  📄 .claude/hooks/task-completed.sh — quality-gate hook (customize for your project)
  📄 .claude/hooks/stop-review.sh   — self-review gate (one-shot warning on uncommitted changes)
  📄 .claude/hooks/memory-capture.sh — auto memory (logs Write/Edit/Bash to tier-0)
  📄 .claude/hooks/bash-compress.sh — output compression (rewrites noisy test/build commands)
  📄 .claude/hooks/bash-compress-wrapper.sh — compression wrapper (head/tail with preserved exit code)
  📄 AGENTS.md               — team coordination rules [created/appended]
  📄 CLAUDE.md                — AGENTS.md reference [created/migrated]
  📄 .claude/memory/claude/memory.md — orchestrator rules seeded [created/updated]

Next steps:
  1. Customize .claude/hooks/task-completed.sh with project-specific checks
     (uncomment test runner, JSON validation, spec-change check, or add your own)
  2. Fill in AGENTS.md placeholders with actual project details
  3. Restart Claude Code for the env var to take effect

To use Agent Teams:
  "Create a team with tech-lead as lead, spawn ic5 and qa as teammates,
   assign implementation to ic5 and test validation to qa."
```

---

## Error Handling

- If `settings.json` contains invalid JSON before we touch it: warn the user and stop — do not overwrite
- If `AGENTS.md` is very large (>200 lines): append the team coordination section at the end and note it was appended
- If `CLAUDE.md` already exists and references AGENTS.md: no changes needed, skip this step
- If `.claude/hooks/` cannot be created (permissions): report the error with the manual command to run

## Important Notes

- This skill is idempotent — safe to run multiple times without clobbering existing content
- The hook script exits 0 by default (pass-through) until customized
- Agent Teams require Claude Code restart after `settings.json` changes for the env var to take effect
- Teammates do not inherit conversation history — AGENTS.md is their primary orientation document
