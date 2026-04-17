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
│   │   ├── task-completed.sh  # Quality-gate hook (created)
│   │   ├── stop-review.sh     # Self-review gate — checks diff before agent exits (created)
│   │   └── memory-capture.sh  # Auto memory — logs Write/Edit/Bash to tier-0 (created)
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
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash .claude/hooks/memory-capture.sh"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash .claude/hooks/stop-review.sh"
          }
        ]
      }
    ],
    "TaskCompleted": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash .claude/hooks/task-completed.sh"
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
- Add the `PostToolUse`, `Stop`, and `TaskCompleted` hooks entries if `hooks` key is absent
- If `hooks` key exists but lacks `PostToolUse`, `Stop`, or `TaskCompleted`, add the missing ones
- Add `sandbox` block if absent (`enabled: true`, `autoAllowBashIfSandboxed: true`, `excludedCommands: ["docker", "docker-compose"]`, `network.allowedDomains` from Step 2). If `sandbox` exists, ensure `enabled` is `true` and `autoAllowBashIfSandboxed` is `true`, merge new domains into existing `allowedDomains` (no duplicates), and preserve any existing `filesystem` overrides
- Ensure `permissions.allow` contains `"Bash(*)"` and `permissions.defaultMode` is `"bypassPermissions"` — add or update as needed, but preserve any other existing allow entries
- Write the merged result back as valid JSON

---

### Step 4: Create .claude/hooks/task-completed.sh

Create `.claude/hooks/` directory and write the hook script:

```bash
mkdir -p .claude/hooks
```

Write `.claude/hooks/task-completed.sh`:

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

Make it executable:
```bash
chmod +x .claude/hooks/task-completed.sh
```

---

### Step 4b: Create .claude/hooks/stop-review.sh

Write `.claude/hooks/stop-review.sh`:

```bash
#!/usr/bin/env bash
# Stop hook — lightweight self-review gate before an agent exits.
# Exit code 2 = block exit (stderr is fed back to the agent as feedback).
# Exit code 0 = allow exit.
#
# Checks for uncommitted changes that might indicate unfinished work.
# The agent sees the stderr feedback and can address issues before exiting.
#
# IMPORTANT: Only fires ONCE per session to avoid infinite loops.
# Uses a stamp file keyed on session_id (from stdin JSON) so the agent
# sees the warning once, gets a chance to address it, then exits cleanly.

# Only run if inside a git repo
if ! git rev-parse --git-dir &>/dev/null; then
  exit 0
fi

# Resolve MROOT for project-local stamp file
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && _MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || _MROOT=$(pwd)

# Read stdin JSON (Claude Code delivers session context)
INPUT=$(timeout 1 cat 2>/dev/null || true)

# Extract session_id for one-shot stamp; fall back to PPID if unavailable
SESSION_ID=$(printf '%s' "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null || true)
STAMP_KEY="${SESSION_ID:-ppid-${PPID:-0}}"
STAMP="$_MROOT/.claude/.stop-review-${STAMP_KEY}"

# One-shot guard: if we already warned this session, let the agent exit.
if [ -f "$STAMP" ]; then
  exit 0
fi

# Check for unstaged or staged-but-uncommitted changes
DIRTY=$(git status --porcelain 2>/dev/null | head -20)
if [ -n "$DIRTY" ]; then
  # Count modified files (excludes untracked)
  MODIFIED=$(echo "$DIRTY" | grep -cE '^\s?[MADRC]' || true)

  if [ "$MODIFIED" -gt 0 ]; then
    # Drop the stamp so next invocation passes through
    touch "$STAMP"
    echo "SELF-REVIEW: $MODIFIED file(s) modified but not committed." >&2
    echo "Before exiting, verify:" >&2
    echo "  - All changes are intentional and complete" >&2
    echo "  - Tests pass with these changes" >&2
    echo "  - No debug code or TODO markers left behind" >&2
    echo "" >&2
    echo "Files:" >&2
    echo "$DIRTY" | grep -E '^\s?[MADRC]' | head -10 >&2
    exit 2
  fi
fi

exit 0
```

Make it executable:
```bash
chmod +x .claude/hooks/stop-review.sh
```

---

### Step 4c: Create .claude/hooks/memory-capture.sh

Write `.claude/hooks/memory-capture.sh`:

```bash
#!/usr/bin/env bash
# PostToolUse hook — automatic memory capture for agent observations.
# Logs significant tool uses (Write, Edit, Bash) to tier-0 memory in SQLite.
# Skips read-only tools (Read, Grep, Glob) to avoid noise.
# Designed to feed /memory-distill — raw observations are compressed later.
#
# Input (via stdin): JSON with tool_name, tool_input, session_id, etc.
# Exit 0 always — this hook should never block the agent.

# Only run if SQLite DB exists
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
MEMDB="$MROOT/.claude/memory/memory.db"

[ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null || exit 0

# Read stdin JSON
INPUT=$(cat)

# Extract tool name
TOOL_NAME=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null || true)

# Only capture mutating tools
case "$TOOL_NAME" in
  Write|Edit|Bash) ;;
  *) exit 0 ;;
esac

# Extract key info based on tool type
case "$TOOL_NAME" in
  Write)
    FILE_PATH=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))" 2>/dev/null || true)
    OBSERVATION="wrote $FILE_PATH"
    ;;
  Edit)
    FILE_PATH=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))" 2>/dev/null || true)
    OBSERVATION="edited $FILE_PATH"
    ;;
  Bash)
    COMMAND=$(echo "$INPUT" | python3 -c "
import sys,json,re
c=json.load(sys.stdin).get('tool_input',{}).get('command','')[:120]
# Redact known secret patterns before logging
c=re.sub(r'(Bearer|Token|Authorization:?)\s+\S+', r'\1 [REDACTED]', c, flags=re.I)
c=re.sub(r'(PASSWORD|SECRET|API_KEY|TOKEN)=\S+', r'\1=[REDACTED]', c, flags=re.I)
print(c)
" 2>/dev/null || true)
    OBSERVATION="ran: $COMMAND"
    ;;
esac

[ -z "$OBSERVATION" ] && exit 0

# Deduplicate: skip if same observation was just logged (avoids tier-0 flood)
DEDUP_FILE="${TMPDIR:-/tmp}/.claude-memcap-last"
LAST=$(cat "$DEDUP_FILE" 2>/dev/null || true)
if [ "$OBSERVATION" = "$LAST" ]; then
  exit 0
fi
printf '%s' "$OBSERVATION" > "$DEDUP_FILE"

# Determine agent name (from teammate_name or default to 'unknown')
AGENT=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('teammate_name','auto'))" 2>/dev/null || echo "auto")

# Append to tier-0 memory (fire-and-forget, parameterized query)
python3 -c "
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute('PRAGMA busy_timeout=5000')
db.execute('INSERT INTO memories(agent, type, content) VALUES (?, ?, ?)',
           (sys.argv[2], 'memory', sys.argv[3]))
db.commit()
" "$MEMDB" "$AGENT" "$OBSERVATION" 2>/dev/null || true

exit 0
```

Make it executable:
```bash
chmod +x .claude/hooks/memory-capture.sh
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
```

Write this content using the DB-first dual path:
```bash
CONTENT="<baseline memory content above>"
if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
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
else
  cat > ".claude/memory/claude/memory.md" << MEMEOF
$CONTENT
MEMEOF
fi
```

---

### Step 8: Validate

Run the hook manually to confirm it passes:
```bash
echo '{}' | bash .claude/hooks/task-completed.sh
echo "Hook exit code: $?"
```

Validate settings.json is still valid JSON:
```bash
python3 -c "import json; json.load(open('.claude/settings.json')); print('settings.json OK')"
```

---

### Step 9: Summary

Print a summary of what was done:

```
✅ Agent Teams orchestration initialized!

Updated:
  📄 .claude/settings.json   — sandbox + bypassPermissions + PostToolUse + Stop + TaskCompleted hooks
      Sandbox: enabled, autoAllowBash, network: [list of configured domains]
  📄 .claude/hooks/task-completed.sh — quality-gate hook (customize for your project)
  📄 .claude/hooks/stop-review.sh   — self-review gate (one-shot warning on uncommitted changes)
  📄 .claude/hooks/memory-capture.sh — auto memory (logs Write/Edit/Bash to tier-0)
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
