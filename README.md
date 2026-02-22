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

| Agent | Model | Role |
|-------|-------|------|
| `pm` | Sonnet | Requirements, user stories, acceptance criteria, prioritization |
| `tech-lead` | Opus | Architecture, system design, cross-cutting concerns, unblocking ICs |
| `ic5` | Opus | Complex implementation — ambiguous problems, hard bugs, new systems |
| `ic4` | Sonnet | Well-defined tasks — extending patterns, tests, simple fixes |
| `devops` | Sonnet | Deployments, CI/CD, infrastructure, monitoring, incident response |
| `qa` | Sonnet | Test planning, validation, bug reports, **release gating** |
| `ds` | Opus | Data analysis, ML/AI pipelines, A/B testing, metrics, statistical modeling |
| `project-init` | Opus | One-time team memory bootstrap (invoked via `/init-team`) |

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
| `/check-specs` | Audit spec format + validate implementation against a specific spec |

---

## Quick Start

### New project

```
/scaffold-project          # Sets up AGENTS.md, specs/TDD.md, .claude/plans/
/init-team                 # Bootstraps all agent memories from your codebase
```

### Existing project

```
/init-team                 # Run once — reads AGENTS.md, code, CI, infra, writes cortex.md for each agent
```

> **Note**: Run `/init-team` in the foreground — the `project-init` agent needs tool permissions approved interactively.

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
/check-specs          # Audit format compliance + link integrity
/check-specs SPEC-012 # Validate specific spec against codebase
/update-spec          # Modify spec with version history
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

## Adding to a Team

Check the plugin into your project's settings so teammates get it automatically:

**`.claude/settings.json`**:
```json
{
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

## License

MIT
