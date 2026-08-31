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

Two files must have matching versions (SPEC-002):
1. `CHANGELOG.md` — add a `### vX.Y.Z` section at the top (newest first)
2. `.claude-plugin/plugin.json` — `"version"` field

`marketplace.json` does **not** carry a per-plugin version — install channels
pin via git refs (`stable` / `master` on `source.ref`). Description sync with
`plugin.json` is still required (docs-drift `manifest-desc`).

`README.md` carries only a pointer to `CHANGELOG.md` — do NOT add version
sections to it (the changelog was moved out of the README in v0.37.4).

Versioning: semver patch (x.y.Z) for fixes, minor (x.Y.0) for features.
New opt-in flags with unchanged defaults = patch; default-behavior changes or new command surfaces = minor.
Enforced on `master`: `githooks/pre-commit` → `skills/release/check-bump-class.sh` (also `/release` Step 4.11 and CI). A new `commands/*.md` on a patch bump MUST NOT commit.

**Ship / land (plugin-wide — not personal memory):**
- Never FF-merge epic children onto master so the next worktree can fast-forward. Work stays on `feat/<ticket>` or the epic integration branch. Master moves only at epic seal / one `/release` fold.
- `--autopilot=patch|minor|major` on `/orchestrate` that **BC5-reroutes to `/epic`** is **seal-intent**. `/epic` MUST persist that bump as `release_bump` (with `--worktree`) and MUST NOT land each child. Token is not unused.
- A new Surface shipped as a patch tag: fold into the minor, delete the patch tag, retag, force-push. Do not leave the false patch in history. Do not offer TL blockers as a "follow-up patch" when the bump was already wrong.
- If you FF'd and **did not push**: `git reset --hard origin/master`. Leave commits on feature branches.

The commit-message format, single-folded-commit rule, and tag/push sequence are owned by
`skills/release/SKILL.md` (the authoritative `/release` contract) — follow it rather than
hand-crafting a release commit. (The format is intentionally NOT restated here, to keep a
single source of truth; read the skill.)

## v1.0 Feature Freeze (CDT-46) — historical

Lifted: `v1.0.0` is tagged on master. This section is historical and does **not**
bind master (CDT-46-only + bugfixes is no longer a live landing rule).

While the freeze was active (pre-`v1.0.0`): only CDT-46 child-ticket work and bug
fixes landed on master. Scope then was `commands/`, `skills/`, `agents/*.md`,
hooks, and `specs/`.

## Agent Roster

| Agent | Model | Role |
|-------|-------|------|
| `pm` | Opus | Requirements, user stories, acceptance criteria |
| `tech-lead` | Opus | Architecture, design, unblocking ICs |
| `ic5` | Sonnet | Complex implementation, hard bugs, new systems |
| `ic4` | Sonnet | Well-defined tasks, extending patterns, tests |
| `devops` | Sonnet | CI/CD, infrastructure, deployments |
| `qa` | Sonnet | Testing, validation, release gating |
| `ds` | Opus | Data analysis, ML, metrics |
| `finder` | Sonnet | Read-only fan-out investigator (`/council` Phase 2 / 2.5, `/bug-hunt` S1 / S2) |
| `debugger` | Opus | Read-only causal root-cause investigator (`/debug ticket` premise only — `full`/`patch`/`arch` root-cause phases have no named-roster spawn) |
| `project-init` | Sonnet | One-time memory bootstrap (via `/setup team`) |
| `distiller` | Haiku | Memory compression specialist (invoked by `/memory distill` only) |
| `council-judge` | Opus | Tool-less final arbiter for `/council` tribunals (invoked by the council engine only) |

The first 7 rows are the behavioral/team agents. The remaining 5 — `finder`,
`debugger`, `project-init`, `distiller`, and `council-judge` — are internal
agents invoked by specific commands, never routed to directly. Internal agents
have no per-agent memory, no cortex, and no `/adjust-agent` directives surface.

Model and effort tiers for all 12 agents are set in `agents/*.md` frontmatter;
SPEC-003 § Tier table is the source of truth.

## Worktree Protocol

All plugin-managed worktrees MUST be created at `.worktrees/<slug>` inside the project root.

Use the shared CLI script — subprocess only, never sourced. Callers MUST resolve it through `plugin-dir.sh` (install-aware; the script ships in the plugin, not the user's repo) — NOT the cwd-relative `bash skills/worktree-lib.sh` (absent on a real install) and NOT `$MROOT/skills/worktree-lib.sh` (resolves to the user's repo, not the plugin):

```bash
# Locate the dev-team plugin root (PDH). Optional CLAUDE_PLUGIN_ROOT (force path / FR #48230), else cwd dev/worktree, else marketplace clone (slug-free agents/pm.md), else installed cache (rank by /dev-team/<VER>/ segment, not full path; CDT-166). CDT-82: marketplace before same-version cache.
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
WT_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/worktree-lib.sh)
```
- Create: `bash "$WT_LIB" ensure <slug>` (prints path on stdout)
- Remove: `bash "$WT_LIB" release <slug>`

Full contract: `specs/core/SPEC-016-worktree-isolation.md`

User-facing management:
- Release: `/worktree release <slug>` (see `commands/worktree.md`)
- List/status: `/status worktree` (see `commands/status.md`)

Sibling-directory worktrees (`$MROOT/../<project>-<id>`) are forbidden when this lib is in use.

## Persistent Memory Protocol

Each agent has memory stored in SQLite (preferred) or .md files (fallback):

**SQLite mode** (after `/setup team`):
- Single DB at `.claude/memory/memory.db` (shared across worktrees)
- Agents read/write via `sqlite3` CLI
- Semantic search via sqlite-vec embeddings
- No line limits

**Memory tiers** (SQLite mode, after v0.14.0):
- Tier 0: Raw memories (written by agents during work)
- Tier 1: Digests (LLM-compressed summaries, created by `/memory distill`)
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

**Memory distillation:** Run `/memory distill` to compress raw memories (tier 0) into
digests (tier 1) and promote high-signal knowledge to core (tier 2). Configure via
`/memory config` (keys: `distill_enabled`, `distill_mode`, `distill_threshold`, `distill_model`).

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

When spawning agents via `/orchestrate`, `/kickoff`, or manually, include an
output-mode line in the task prompt:

| Prompt line | Effect |
|-------------|--------|
| (omit) | **normal** — full sentences OK for human-facing work |
| `Output mode: terse` | **terse** — decisions, code, blockers only (default for agent-to-agent) |
| `Output mode: ultra` | **ultra** — fragments; max compression; still keep code/commands/errors exact |

Agents produce the same quality work; only communication verbosity changes.
Override per-agent via `/adjust-agent <agent> "Disable terse mode"` or
`"Default to Output mode: ultra"`.

**Memory prose compress (optional):** when distilling or writing tier-0 notes,
prefer fact-dense bullets over narrative — same substance, fewer tokens
(`skills/memory-compress` protocol; used by `/memory distill` when invited).

## Domain Glossary (CONTEXT.md)

When `$MROOT/CONTEXT.md` or `$MROOT/docs/domain/CONTEXT.md` exists, it is the
project's **ubiquitous language** (committed glossary — not agent memory).

- Load it before naming types, tickets, specs, or plan subjects
- Prefer **Term** names; do not reintroduce listed **Avoid** aliases
- Write-back only with user-confirmed terms via `/brainstorm` or `/kickoff`
  (`skills/domain-glossary/SKILL.md`)

Absent file is fine until the first real term crystallizes.

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
- Agents may invoke `sqlite3` for memory operations (`Bash(sqlite3:*)` is in the curated allowlist `/setup project` emits for interactive use; `/setup team`, via `project-init`, sets the `Bash(*)` wildcard — the sandbox is the boundary — and syncs the sandbox network allowlist)
- Temp paths in skill/command executable bash blocks MUST use `"${TMPDIR:-/tmp}/…"`
  or plain `mktemp` / `mktemp -d` (honors `$TMPDIR`). MUST NOT hard-code bare
  `/tmp/…` for writable files. Intentional OS mounts (e.g. bwrap `--tmpfs /tmp`
  in SPEC-019) are exempt.

## Adversarial fleet degradation

On rate-limit or any unusable spawn of council/refuter/review investigators
(or prosecutor/advocate/judge): the **orchestrator** self-verifies with real
tools. Report marker (exact): `self-verified — refuters unavailable`.
**Never ship on implementer self-validation.** Council and `/review-and-commit`
implement the report path (`--verification-mode self-verified`); other
workflows (incl. `/debug ticket`) reuse the same marker + actor
rule — do not invent a second string.

## What NOT to Do

- Do not commit `.claude/settings.local.json` or `.claude/context/`
- Do not commit process trackers (`.claude/backlog*`, `.claude/plans*`, or other
  process state under `.claude/`) as product delivery — Linear preferred SoT when
  MCP is up; local write-through always; never stage trackers into delivery commits
- Do not modify plugin.json version without also updating CHANGELOG.md (use `/release`)
- Do not add agents without updating the README agent roster table
- Do not create new files unless clearly necessary
- Do not land a lesson only in `.claude/memory/claude/lessons.md` when the
  failure is a plugin skill/command/gate defect — patch the plugin (CDT-111)
- Do not FF-merge epic children onto master (see Release Rules — Ship / land)
