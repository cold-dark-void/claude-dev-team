# Claude Dev Team

A FAANG-style AI dev team plugin for [Claude Code](https://claude.ai/claude-code). Gives you six specialized agents with persistent per-project memory, plus a full spec management workflow and project scaffolding — all wired together.

## Install

```bash
/plugin marketplace add cold-dark-void/claude-dev-team
```

Or if you haven't added this marketplace yet:

```bash
/plugin marketplace add cold-dark-void/claude-dev-team
/plugin install dev-team
```

## What You Get

### Agents

| Agent | Model | Tools | Role |
|-------|-------|-------|------|
| `pm` | Sonnet | Read, Grep, Glob, Bash, Task*, SendMessage | Requirements, user stories, acceptance criteria, prioritization |
| `tech-lead` | Opus | Read, Grep, Glob, Bash, Task*, SendMessage | Architecture, system design, cross-cutting concerns, unblocking ICs |
| `ic5` | Sonnet | Read, Write, Edit, Bash, Grep, Glob, Task*, SendMessage | Complex implementation — ambiguous problems, hard bugs, new systems |
| `ic4` | Sonnet | Read, Write, Edit, Bash, Grep, Glob, Task*, SendMessage | Well-defined tasks — extending patterns, tests, simple fixes |
| `devops` | Sonnet | Read, Write, Edit, Bash, Grep, Glob, Task*, SendMessage | Deployments, CI/CD, infrastructure, monitoring, incident response |
| `qa` | Sonnet | Read, Grep, Glob, Bash, Task*, SendMessage | Test planning, validation, bug reports, **release gating** |
| `ds` | Sonnet | Read, Write, Edit, Bash, Grep, Glob, Task*, SendMessage | Data analysis, ML/AI pipelines, A/B testing, metrics, statistical modeling |
| `project-init` | Sonnet | Read, Write, Edit, Bash, Grep, Glob, SendMessage | One-time team memory bootstrap (invoked via `/init-team`) |

Each agent maintains **four persistent memory files per project**:

| File | Scope | Purpose |
|------|-------|---------|
| `cortex.md` | Shared (all worktrees) | Accumulated project expertise |
| `memory.md` | Shared (all worktrees) | Working state and recent decisions |
| `lessons.md` | Shared (all worktrees) | Mistakes, anti-patterns, what works here |
| `context.md` | Per worktree | Current task progress and next steps |

Memory files live at `{project-root}/.claude/memory/{agent}/` and are **unified across git worktrees** — all worktrees share the same `cortex`, `memory`, and `lessons`, while each worktree gets its own `context`.

### Commands / Skills

| Command | What it does |
|---------|-------------|
| `/init-team` | Bootstrap all 6 agents' memory for the current project (run once per project) |
| `/scaffold-project` | Create TDD workflow structure: `AGENTS.md`, `specs/TDD.md`, `.claude/plans/` |
| `/create-spec` | Guided interview → new behavioral spec in `specs/` |
| `/update-spec` | Modify an existing spec with version history |
| `/find-spec` | Search specs by keyword |
| `/list-specs` | Quick status overview of all specs |
| `/check-specs` | Audit spec format + code alignment (Phase 1: format/index, Phase 2: MATCH/MISSING/DIFFERS per requirement) |
| `/review-and-commit` | Review changes, update specs, append to review.md, commit |
| `/reflect-specs` | Full-system health check — ALL specs exhaustively, cross-spec conflicts, skill/command consistency, interactive confirmation |
| `/release` | Bump version in all required files (README, plugin.json, marketplace.json), commit, tag, and push |
| `/init-orchestration` | Enable Agent Teams for any project: adds env var, TaskCompleted hook, and AGENTS.md with team coordination rules |
| `/generate-specs` | Reverse-engineer behavioral specs from existing code — establishes a spec baseline for legacy projects with no existing specs |
| `/generate-tests` | Generate unit/integration tests from specs — one test per MUST requirement, tagged with source spec ID for traceability |
| `/kickoff` | Orchestrate full ticket intake + planning: parallel PM+TL kickoff, spec creation, implementation plan, TaskCreate task graph |
| `/standup` | Status snapshot of active agent work: reads TaskList + agent context files, surfaces blockers and stale tasks |
| `/wrap-ticket` | Close out a shipped ticket: verify tasks done, capture learnings to memory, update plans, remove worktree |
| `/orchestrate` | Full lifecycle orchestrator: fetch issue, create worktree, spawn agents end-to-end, tech-lead review loops, optional PR |

---

## Quick Start

### New project

```
/scaffold-project          # Sets up AGENTS.md, specs/TDD.md, .claude/plans/
/init-team                 # Bootstraps all agent memories from your codebase
/init-orchestration        # Enable Agent Teams: env var + quality-gate hook + AGENTS.md
```

### Existing project

```
/init-team                 # Run once — reads AGENTS.md, code, CI, infra, writes cortex.md for each agent
```

> **Note**: The bundled `.claude/settings.json` pre-approves common operations so agents run without permission prompts. See [Autonomy & Permissions](#autonomy--permissions) below.

### Starting a task

```
# 1. Requirements
Use the pm subagent to write a spec for: [feature]

# 2. Technical direction
Use the tech-lead subagent to review the spec and give implementation direction

# 3. Implement
Use the ic5 subagent to implement: [complex task]
Use the ic4 subagent to implement: [well-defined task]

# 4. QA gates the release
Use the qa subagent to validate against the spec before we deploy

# 5. Ship
Use the devops subagent to deploy to staging
```

Or just describe the task — Claude will route to the right agent automatically based on their descriptions.

---

## Typical Workflow

```
PM  ──► defines requirements + acceptance criteria
         │
Tech Lead ──► architecture direction, unblocks ICs
         │
IC5 / IC4 ──► implement (IC5: complex, IC4: simple)
         │
QA  ──► validates all acceptance criteria ─── BLOCK if issues ──► back to IC
         │ GO
DevOps ──► deploy + monitor
```

### Routing shortcuts

| Task type | Agent |
|-----------|-------|
| Ambiguous / hard / new system | IC5 |
| Clear pattern extension / tests / config | IC4 |
| Design question / architecture | Tech Lead |
| Bug investigation + fix | IC5 |
| Infrastructure, deploy, CI | DevOps |
| Spec validation, release gate | QA |
| Requirements, scoping | PM |

---

## Memory Layout

After `/init-team` runs:

```
{project}/.claude/memory/
  pm/           cortex.md ✓   memory.md   lessons.md
  tech-lead/    cortex.md ✓   memory.md   lessons.md ✓ (seeded from AGENTS.md)
  ic5/          cortex.md ✓   memory.md   lessons.md ✓ (seeded from AGENTS.md)
  ic4/          cortex.md ✓   memory.md   lessons.md
  devops/       cortex.md ✓   memory.md   lessons.md
  qa/           cortex.md ✓   memory.md   lessons.md

{worktree}/.claude/memory/{agent}/context.md   ← fills as work happens
```

`cortex.md` is populated on init. Everything else fills naturally as the team works. The team gets sharper the more you use it on a project — agents stop re-reading the codebase from scratch each session.

### Re-initialize after major changes

```
/init-team    # Safe to re-run — updates cortex.md for all agents
```

---

## Spec Workflow

Specs live in `specs/` and are tracked in `specs/TDD.md`. The QA agent reads them as acceptance criteria. The IC agents read them before implementation.

```
/create-spec          # Guided interview → new spec file + TDD.md entry
/list-specs           # Quick status: what's passing, new, broken
/find-spec thumbnail  # Search across all spec content
/check-specs          # Audit all specs: format compliance + code alignment (samples 3–5 recent specs)
/check-specs SPEC-012 # Validate spec: Grep source, classify each MUST as MATCH/MISSING/DIFFERS, flag drift
/update-spec          # Modify spec: cross-spec conflict check + code alignment warning on changed requirements
/reflect-specs       # Full health check: ALL specs + cross-spec conflicts + skill consistency + interactive confirmation
```

### Spec categories

| Prefix | Category |
|--------|----------|
| `SPEC-` | Core behavior |
| `PERF-` | Performance |
| `SAFE-` | Safety / concurrency |
| `COMPAT-` | Compatibility |
| `ARCH-` | Architecture |

---

## Autonomy & Permissions

The plugin ships `.claude/settings.json` which pre-approves common operations so agents run without prompting for every tool call:

```json
{
  "permissions": {
    "defaultMode": "acceptEdits",
    "allow": [
      "Bash(git:*)", "Bash(npm:*)", "Bash(go:*)", "Bash(gh:*)",
      "Bash(_gc=*)", "Bash(MROOT=*)", "Bash(AGENT_*)", "Bash({:*)",
      "Bash(grep:*)", "Bash(sed -n:*)", "Bash(if :*)", "Bash(for :*)",
      "..."
    ]
  }
}
```

- **`defaultMode: "acceptEdits"`** — file reads, writes, and edits are auto-approved
- **Bash allow list** — 41 entries covering dev tools, agent bootstrap patterns (variable assignments, compound commands, shell control flow), and common read-only utilities
- **Intentionally excluded**: destructive commands (`rm`, `curl`, `wget`) still prompt for confirmation

Both `/scaffold-project` (new projects) and `/init-team` (existing projects) emit/sync the full allowlist automatically.

To extend for your stack, add entries to `.claude/settings.json`:

```json
"Bash(terraform:*)",
"Bash(kubectl:*)",
"Bash(docker:*)"
```

### Memory budgets

All agents enforce file size limits to prevent context blowout:

| File | Limit |
|------|-------|
| `cortex.md` | ≤ 100 lines |
| `memory.md` | ≤ 50 lines |
| `lessons.md` | ≤ 80 lines |
| `context.md` | ≤ 60 lines |

Agents trim stale content before writing and skip files that don't exist yet.

---

## Adding to a Team

Check the plugin into your project's settings so teammates get it automatically. The plugin already ships `.claude/settings.json` — merge the marketplace entry into it:

**`.claude/settings.json`**:
```json
{
  "permissions": {
    "defaultMode": "acceptEdits",
    "allow": ["Bash(git:*)", "Bash(npm:*)", "..."]
  },
  "extraKnownMarketplaces": {
    "dev-team": {
      "source": {
        "source": "github",
        "repo": "cold-dark-void/claude-dev-team"
      }
    }
  }
}
```

---

## Requirements

- Claude Code 2.x+
- Git (for worktree-aware memory path resolution)

---

## Changelog

### v0.10.0
- **`/orchestrate`**: new skill — full lifecycle issue orchestrator; fetches issue context (Linear or prompted), creates branch/worktree, spawns PM+Tech Lead for scoping, IC4/IC5 for implementation, QA for validation, enforces tech-lead review loops with deadloop detection, optionally creates PR; main Claude stays as observer/navigator throughout

### v0.9.10
- **`/init-orchestration`**: enable bubblewrap sandbox (`sandbox.enabled: true`, `autoAllowBashIfSandboxed: true`) + simplify permissions to `Bash(*)` with `bypassPermissions` — replaces 70-line command allowlist with OS-level isolation for zero-prompt fully autonomous agents

### v0.9.9
- **`/init-orchestration`**: now creates `CLAUDE.md` as `AGENTS.md` reference (migrates existing content); AGENTS.md template gains battle-tested workflow rules (spec compliance, project-local paths, version bumping, no over-planning); hook template adds spec-change detection example

### v0.9.8
- **`/generate-tests`**: new skill — generates unit/integration tests from behavioral specs; reads MUST/SHOULD/MUST NOT requirements, detects project test framework and conventions, writes one test per requirement tagged with source spec ID (`// Generated from SPEC-NNN`), runs tests and reports pass/fail baseline; closes the spec-to-test gap when used after `/generate-specs` or `/create-spec`

### v0.9.7
- **`/generate-specs`**: new skill — reverse-engineers behavioral specs from existing source code; groups public surface into 8–15 domain-level specs with MUST/SHOULD/MUST NOT language; marks all output `INFERRED` for human review; designed for legacy project onboarding
- **runbook**: adds Phase 0 (legacy baseline) referencing `/generate-specs`; Phase 1.3 now directs to `/generate-specs` when no specs exist; Quick Reference updated

### v0.9.6
- **`/kickoff`**: new skill — orchestrates full ticket intake + planning phase; parallel PM+Tech Lead kickoff, spec creation, implementation plan, and TaskCreate task graph from a single command
- **`/standup`**: new skill — status snapshot of active agent team work; reads TaskList + each agent's context.md, surfaces blockers and stale tasks
- **`/wrap-ticket`**: new skill — close-out workflow; verifies all tasks completed, captures learnings to project memory, updates plans index, removes worktree, prints Linear checklist
- **docs**: Linear-to-prod runbook with full agent team orchestration walkthrough (POC-123 example)

### v0.9.5
- **Agent autonomy**: fix `Task` → `TaskCreate, TaskList, TaskUpdate, TaskGet` on all coordinating agents (pm, tech-lead, ic5, qa); add Task tools + `SendMessage` to all 8 agents so they can coordinate and communicate without human intervention
- **Bash allow list**: expand init-orchestration permissions from 38 to 73 entries, covering shell builtins, text processing, and common dev tools; remove dangerous commands (rm, chmod, curl, wget, patch, source) to require human approval

### v0.9.4
- **Cost efficiency**: downgrade `ds`, `project-init` to Sonnet; add dynamic Opus escalation for `pm`, `ic5`, `qa`, `ds` with role-specific trigger conditions

### v0.9.3
- **`/review-and-commit` overhaul**: brutal honest review — no sugar-coating, explicit PII/data exposure scan, over-engineering and simplicity checks, commit gated on critical issues, "What I Would Do Instead" section, structured action items checklist, file:line citations required on every finding; review printed as text with optional save path arg

### v0.9.2
- **`/release` skill**: bumps version in all three required files (README.md, plugin.json, marketplace.json), commits, tags, and pushes — ensures they never get out of sync

### v0.9.1
- **`/reflect-specs` rename**: `/reflect-skills` renamed to `/reflect-specs` — the skill audits specs (and code alignment), not just skills; the old name was misleading

### v0.9.0
- **`/init-orchestration` skill**: bootstrap Agent Teams for any project — enables `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`, adds a `TaskCompleted` quality-gate hook, and creates/updates `AGENTS.md` with team coordination rules; idempotent (safe to re-run)
- **`AGENTS.md`**: added to this plugin repo for contributors

### v0.8.1
- **`/review-and-commit` fix**: review output now written to `/tmp/review.md` instead of a project-local file, eliminating any risk of accidentally staging or committing it

### v0.8.0
- **`/reflect-specs` skill**: full-system health check — exhaustive code alignment across ALL specs (not sampled), cross-spec BLOCKER/WARNING/terminology-drift detection, skill/command self-consistency audit, interactive Phase 6 confirmation loop
- **Phase 5 independent code read**: reads every source file in full (not just keyword hits), summarizes each module's purpose, maps public surface (exported functions/types/routes/handlers) to specs, produces a module summary table with COVERED/UNCOVERED status — finds gaps that spec-driven grep would miss

### v0.7.0
- **Permissions sync**: `/init-team` now auto-syncs `.claude/settings.json` — merges missing permissions into existing projects without overwriting user additions
- **Expanded allowlist**: 41 entries covering agent bootstrap patterns (`_gc=*`, `MROOT=*`, `AGENT_*`), compound commands (`{:*`), shell control flow (`if`, `for`), and read-only `sed -n`
- **`/scaffold-project`** updated to emit the full allowlist for new projects

### v0.6.0
- **`/review-and-commit` skill**: review staged/modified files for bugs and spec drift, update out-of-date specs, append findings to `review.md`, then commit

### v0.5.0
- **`/check-specs` audit**: adds Phase 2 code alignment — samples 3–5 recently-updated specs, Greps source files, classifies each MUST requirement as MATCH / MISSING / DIFFERS, flags undocumented behavior (drift)
- **`/check-specs <ID>` validate**: fully rewritten — keyword extraction, language detection, source file discovery, per-requirement reasoning with `file:~line` evidence, drift detection, structured report with counts
- **`/create-spec`**: new Step 2.5 conflict scan — before creating, reads all existing specs and flags BLOCKER (direct contradictions) and WARNING (scope overlap); pauses for user decision
- **`/update-spec`**: new Step 3.5 cross-spec conflict check (same BLOCKER/WARNING logic, handles removed requirements); new Step 4.5 code alignment warning for added/modified requirements

### v0.4.0
- **Autonomy**: Added `.claude/settings.json` with `defaultMode: "acceptEdits"` and Bash allow list
- **Orchestration**: `pm`, `qa`, `tech-lead` can now spawn subagents via `Task` tool
- **project-init**: Added `Edit` tool for in-place file patching
- **Context efficiency**: All agents enforce memory file size budgets; ic5 applies `max_turns` limits
- **Scaffolding**: `/scaffold-project` now generates `.claude/settings.json` for new projects

### v0.3.0
- **Memory bootstrap**: `project-init` and `scaffold-project` now create `.claude/CLAUDE.md` and seed `.claude/memory/claude/memory.md` for project-local Claude Code memory

### v0.2.0
- **Backlog**: Added `/backlog` skill for `.claude/backlog/` management (add, close, list, init)

### v0.1.0
- Initial release: pm, tech-lead, ic5, ic4, devops, qa, ds, project-init agents
- Four-file per-agent memory system (cortex, memory, lessons, context) — worktree-aware
- Spec management: `/create-spec`, `/update-spec`, `/find-spec`, `/list-specs`, `/check-specs`
- `/scaffold-project` and `/init-team` commands

---

## License

MIT
