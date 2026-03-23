# AGENTS.md — claude-dev-team

Project-specific rules for all agents (Claude Code teammates, subagents, and CI).
Read this file at the start of every session before doing any work.

## What This Project Is

A Claude Code plugin (`dev-team`) that provides a FAANG-style AI dev team:
specialized agents (PM, Tech Lead, IC5, IC4, DevOps, QA, DS) with persistent
per-project memory, plus skills for spec management and project scaffolding.

**Key directories:**
```
agents/          # Agent definitions (.md with YAML frontmatter)
skills/          # Multi-file skill definitions (subdirs)
commands/        # Single-file slash command definitions (.md)
.claude-plugin/  # Plugin manifest (plugin.json, marketplace.json)
.claude/memory/  # Per-agent persistent memory (not committed)
```

## Release Rules — MUST follow on every commit

Three files must have matching versions:
1. `README.md` — add `### vX.Y.Z` section above previous version
2. `.claude-plugin/plugin.json` — `"version"` field
3. `.claude-plugin/marketplace.json` — `"version"` field inside `plugins[]`

Versioning: semver patch (x.y.Z) for fixes, minor (x.Y.0) for features.
After commit: `git tag vX.Y.Z && git push && git push --tags`

## Agent Roster

| Agent | Model | Role |
|-------|-------|------|
| `pm` | Sonnet | Requirements, user stories, acceptance criteria |
| `tech-lead` | Opus | Architecture, design, unblocking ICs |
| `ic5` | Opus | Complex implementation, hard bugs, new systems |
| `ic4` | Sonnet | Well-defined tasks, extending patterns, tests |
| `devops` | Sonnet | CI/CD, infrastructure, deployments |
| `qa` | Opus | Testing, validation, release gating |
| `ds` | Opus | Data analysis, ML, metrics |
| `project-init` | Sonnet | One-time memory bootstrap (via `/init-team`) |
| `distiller` | Haiku | Memory compression specialist (invoked by `/memory-distill` only) |

## Persistent Memory Protocol

Each agent has memory stored in SQLite (preferred) or .md files (fallback):

**SQLite mode** (after `/init-team`):
- Single DB at `.claude/memory/memory.db` (shared across worktrees)
- Agents read/write via `sqlite3` CLI
- Semantic search via sqlite-vec embeddings
- No line limits

**Memory tiers** (SQLite mode, after v0.14.0):
- Tier 0: Raw memories (written by agents during work)
- Tier 1: Digests (LLM-compressed summaries, created by `/memory-distill`)
- Tier 2: Core knowledge (promoted from digests, permanent)
- `archived = TRUE`: consumed by distillation, excluded from all queries

**Fallback mode** (no sqlite3 or extensions):
- Per-agent files at `.claude/memory/<agent>/`:
  - `cortex.md` — architecture/domain expertise
  - `memory.md` — working state and recent decisions
  - `lessons.md` — mistakes and project-specific patterns
- Line limits: cortex 100, memory 50, lessons 80

**Always .md** (both modes):
- `context.md` — current task progress (per-worktree, never migrated to DB)
- Line limit: 60 lines

**Path resolution:**
```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
MEMDB="$MROOT/.claude/memory/memory.db"

USE_DB=false
if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
  USE_DB=true
fi

# Worktree context (always .md)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
AGENT_CTX="$WTROOT/.claude/memory/<agent-name>"
```

**Session start — read memory (tiered):**
```bash
if [ "$USE_DB" = "true" ]; then
  # Check if distilled content exists
  HAS_DISTILLED=$(sqlite3 "$MEMDB" "SELECT COUNT(*) FROM memories
    WHERE agent='<NAME>' AND tier > 0 AND archived=FALSE;")
  if [ "$HAS_DISTILLED" -gt 0 ]; then
    # Tier 2: core knowledge (always loaded)
    sqlite3 "$MEMDB" "SELECT content FROM memories
      WHERE agent='<NAME>' AND tier=2 AND archived=FALSE
      ORDER BY type, updated_at DESC;"
    # Tier 1: digests (compressed summaries)
    sqlite3 "$MEMDB" "SELECT content FROM memories
      WHERE agent='<NAME>' AND tier=1 AND archived=FALSE
      ORDER BY type, updated_at DESC;"
  else
    # No distilled content yet — load all tier-0 (backward compat)
    sqlite3 "$MEMDB" "SELECT content FROM memories
      WHERE agent='<NAME>' AND tier=0 AND archived=FALSE
      ORDER BY type, created_at DESC;"
  fi
fi
```

Write back at end of task. Context stays per-worktree.

**Memory distillation:** Run `/memory-distill` to compress raw memories (tier 0) into
digests (tier 1) and promote high-signal knowledge to core (tier 2). Configure via
`/memory-config` (keys: `distill_enabled`, `distill_mode`, `distill_threshold`, `distill_model`).

## Per-Agent Directives

Agents can receive project-specific standing orders via directives files:

**File:** `.claude/memory/<agent>/directives.md`
**Format:** Numbered list, one directive per line
**Applies to:** 7 behavioral agents (pm, tech-lead, ic5, ic4, devops, qa, ds)
**Does NOT apply to:** project-init, distiller

Directives load BEFORE memory (load order: directives → memory → context).
They are framed as "standing orders" that the agent must not override — analogous to
Asimov's laws. If a user instruction during a session conflicts with a directive,
the agent flags the conflict rather than silently ignoring the directive.

Manage directives with `/adjust-agent`:
- `/adjust-agent` — dashboard (all agents + directive counts)
- `/adjust-agent <agent>` — view directives for one agent
- `/adjust-agent <agent> <prompt>` — conversational adjustment with conflict detection

Directives files are local (not committed to git).

## Team Coordination (Agent Teams)

When working as a native Agent Team teammate:
- Check `~/.claude/teams/<team-name>/config.json` to discover other teammates
- Use `TaskList` to find available work; prefer lowest-ID tasks first
- Claim tasks with `TaskUpdate` (set `owner` to your agent name) before starting
- Mark tasks `completed` via `TaskUpdate` when done, then check `TaskList` again
- Communicate with teammates via `SendMessage` (DM) or broadcast sparingly
- Do NOT edit files another teammate is actively working on
- When idle, send a status update to the team lead

## Code Conventions

- Agent `.md` files require YAML frontmatter: `name`, `description`, `tools`, `model`
- **All** command and skill `.md` files require YAML frontmatter: `name`, `description` — without it they won't appear in Claude Code's discovery/suggestion system
- `commands/<name>.md` — user-invoked slash commands (single file)
- `skills/<name>/SKILL.md` — multi-file skills needing supporting assets (scripts, schemas), or agent-internal protocols not directly user-invoked (e.g. `memory-store`, `memory-recall`)
- Both directories are functionally equivalent to Claude Code's plugin loader — the split is organizational only
- Plugin JSON files must always be valid JSON (enforced by TaskCompleted hook)
- No build step — this is a pure markdown/JSON plugin
- Agents may invoke `sqlite3` for memory operations (`Bash(sqlite3:*)` is added to the permission allowlist by `/init-team`)

## What NOT to Do

- Do not commit `.claude/settings.local.json` or `.claude/context/`
- Do not modify plugin.json version without also updating README.md and marketplace.json
- Do not add agents without updating the README agent roster table
- Do not create new files unless clearly necessary
