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

Three files must have matching versions (SPEC-002):
1. `CHANGELOG.md` — add a `### vX.Y.Z` section at the top (newest first)
2. `.claude-plugin/plugin.json` — `"version"` field
3. `.claude-plugin/marketplace.json` — `"version"` field inside `plugins[]`

`README.md` carries only a pointer to `CHANGELOG.md` — do NOT add version
sections to it (the changelog was moved out of the README in v0.37.4).

Versioning: semver patch (x.y.Z) for fixes, minor (x.Y.0) for features.

The commit-message format, single-folded-commit rule, and tag/push sequence are owned by
`skills/release/SKILL.md` (the authoritative `/release` contract) — follow it rather than
hand-crafting a release commit. (The format is intentionally NOT restated here, to keep a
single source of truth; read the skill.)

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
| `council-judge` | Opus | Tool-less final arbiter for `/council` tribunals (invoked by the council engine only) |

The first 7 rows are the behavioral/team agents; `project-init`, `distiller`, and
`council-judge` are internal agents invoked by specific commands, never routed to directly.

## Worktree Protocol

All plugin-managed worktrees MUST be created at `.worktrees/<slug>` inside the project root.

Use the shared CLI script — subprocess only, never sourced:
- Create: `bash skills/worktree-lib.sh ensure <slug>` (prints path on stdout)
- Remove: `bash skills/worktree-lib.sh release <slug>`

Full contract: `specs/core/SPEC-016-worktree-isolation.md`

User-facing management: `/worktree status|list|release` (see `commands/worktree.md`).

Sibling-directory worktrees (`$MROOT/../<project>-<id>`) are forbidden when this lib is in use.

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
USE_DB=false
if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
  USE_DB=true
fi
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
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
- `SendMessage` is for **peer-to-peer** DMs only. Spawned sub-agents have NO addressable parent — there is no agent named `main` or `orchestrator`. Return work to the orchestrator as your final message; the orchestrator reads it from your spawn-return value, not from an inbound SendMessage.
- Do NOT edit files another teammate is actively working on
- When idle, send a status update to the team lead

### Terse Communication

When spawning agents via `/orchestrate`, `/kickoff`, or manually, include
`Output mode: terse` in the task prompt. This triggers compressed output —
decisions, code, and blockers only, no narrative. Agents produce the same
quality work; they just stop explaining it to an audience that doesn't need
explanations. Override per-agent via `/adjust-agent <agent> "Disable terse mode"`.

## Code Conventions

- Agent `.md` files require YAML frontmatter: `name`, `description`, `tools`, `model`
  - **Keep `tools:` in these source files** — Claude Code needs it for per-agent tool
    scoping (e.g. `council-judge` uses `tools: ""` to stay tool-less per SPEC-013).
    opencode requires `tools:` to be an object and hard-errors on the string form, so
    `install.sh` strips the `tools:` line when generating the opencode copies. Do NOT
    remove `tools:` here to satisfy opencode — fix it in the install transform instead.
- **All** command and skill `.md` files require YAML frontmatter: `name`, `description` — without it they won't appear in Claude Code's discovery/suggestion system
- `commands/<name>.md` — user-invoked slash commands (single file)
- `skills/<name>/SKILL.md` — multi-file skills needing supporting assets (scripts, schemas), or agent-internal protocols not directly user-invoked (e.g. `memory-store`, `memory-recall`)
- Both directories are functionally equivalent to Claude Code's plugin loader — the split is organizational only
- Plugin JSON files must always be valid JSON (enforced by TaskCompleted hook)
- No build step — this is a pure markdown/JSON plugin
- Agents may invoke `sqlite3` for memory operations (`Bash(sqlite3:*)` is in the curated allowlist `/scaffold-project` emits for interactive use; `/init-team`, via `project-init`, sets the `Bash(*)` wildcard — the sandbox is the boundary — and syncs the sandbox network allowlist)
- Temp paths in skill/command executable bash blocks MUST use `"${TMPDIR:-/tmp}/…"`
  or plain `mktemp` / `mktemp -d` (honors `$TMPDIR`). MUST NOT hard-code bare
  `/tmp/…` for writable files. Intentional OS mounts (e.g. bwrap `--tmpfs /tmp`
  in SPEC-019) are exempt.

## Local-Agent Offload (OPT-IN)

Setting `LOCAL_AGENT=opencode` enables offloading mechanical/machine-verifiable work
to a local model via `skills/local-agent/run.sh`. **Off by default** — unset, all
work is done by Claude as usual. Drivers: `/orchestrate` (eligible tasks), `/local-do`,
`/debug patch` P.4, `/refactor inline` 3.3. Optional `LOCAL_AGENT_NET=none` adds bwrap
`--unshare-net` (breaks remote/LAN/**localhost** model HTTP — leave unset for ollama).
Governing spec: `specs/core/SPEC-019-local-agent-offload-via-opencode.md`.

## Adversarial fleet degradation

On rate-limit or any unusable spawn of council/refuter/review investigators
(or prosecutor/advocate/judge): the **orchestrator** self-verifies with real
tools. Report marker (exact): `self-verified — refuters unavailable`.
**Never ship on implementer self-validation.** Council and `/review-and-commit`
implement the report path (`--verification-mode self-verified`); other
workflows (incl. `/fix-ticket`) reuse the same marker + actor
rule — do not invent a second string.

## What NOT to Do

- Do not commit `.claude/settings.local.json` or `.claude/context/`
- Do not modify plugin.json version without also updating README.md and marketplace.json
- Do not add agents without updating the README agent roster table
- Do not create new files unless clearly necessary
