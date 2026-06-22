# Claude Dev Team

A FAANG-style AI dev team plugin for [Claude Code](https://claude.ai/claude-code) and [opencode](https://opencode.ai). Gives you seven specialized agents with persistent per-project memory, plus a full spec management workflow and project scaffolding — all wired together.

## Install

### Claude Code

```bash
/plugin marketplace add cold-dark-void/claude-dev-team
/plugin install dev-team
```

### opencode

```bash
git clone https://github.com/cold-dark-void/claude-dev-team.git
cd claude-dev-team
bash install.sh
```

The opencode install script creates symlinks to `agents/` and `commands/` in your opencode config directory (`~/.config/opencode/`). Skills are added via `opencode.json` `skills.paths`.

## Documentation

| Guide | What's in it |
|-------|--------------|
| **[Documentation hub](docs/README.md)** | Index of every command, runbook, and guide — start here |
| [Setup & Configuration](docs/setup.md) | Prerequisites, `/init-team`, memory config, remote embeddings, troubleshooting |
| [Onboarding runbook](docs/runbooks/onboarding.md) | "Just cloned the repo" → agents ready to take tickets |
| [Memory runbook](docs/runbooks/memory.md) | How memory works, distillation, search, hygiene |
| [Command reference](docs/commands/) | Per-command pages (usage, flags, examples) |
| [CHANGELOG](CHANGELOG.md) | Release history |

## What You Get

### Agents

| Agent | Model | Role |
|-------|-------|------|
| `pm` | Sonnet | Requirements, user stories, acceptance criteria, prioritization |
| `tech-lead` | Opus | Architecture, system design, cross-cutting concerns, unblocking ICs |
| `ic5` | Opus | Complex implementation — ambiguous problems, hard bugs, new systems |
| `ic4` | Sonnet | Well-defined tasks — extending patterns, tests, simple fixes |
| `devops` | Sonnet | Deployments, CI/CD, infrastructure, monitoring, incident response |
| `qa` | Opus | Test planning, validation, bug reports, **release gating** |
| `ds` | Opus | Data analysis, ML/AI pipelines, A/B testing, metrics, statistical modeling |

The seven rows above are the behavioral/team agents you route work to. Three internal
agents — `project-init`, `distiller`, and `council-judge` — are invoked by specific
commands (`/init-team`, `/memory-distill`, `/council`), not directly. Every agent has
persistent per-project memory.

### Memory

Each agent remembers what it learns about your project, so the team stops re-reading the
codebase from scratch every session. Storage is **SQLite with semantic search** when
available (after `/init-team` downloads the embedding extensions, ~29MB), and falls back
**transparently to per-agent markdown files** when it isn't. Per-worktree task progress
always lives in `context.md`.

See the **[Memory runbook](docs/runbooks/memory.md)** for storage layout, tiers, and
distillation, and the **[Setup Guide](docs/setup.md#memory-configuration--memory-config)**
for configuration and remote-embedding options.

## Commands

Full per-command docs live in **[`docs/commands/`](docs/commands/)**. At a glance:

> **opencode**: Commands are namespaced under `/dev-team/` (e.g., `/dev-team/handoff`, `/dev-team/recall`). Claude Code uses the bare command name (e.g., `/handoff`, `/recall`).

### Setup (run once per project)

| Command | What it does |
|---------|-------------|
| `/init-team` | Bootstrap all 7 agents' memory for the current project |
| `/adjust-agent` | View and manage per-agent behavioral directives (`--apply` for non-interactive) |
| `/scaffold-project` | Create TDD workflow structure: `AGENTS.md`, `specs/TDD.md`, `.claude/plans/` |
| `/init-orchestration` | Enable Agent Teams: sandbox, env var, auto-memory + Stop + TaskCompleted hooks |
| `/demo` | Interactive walkthrough — scaffolds a temp project, injects a ticket, runs the pipeline |

### Feature work

| Command | What it does |
|---------|-------------|
| [`/brainstorm`](docs/commands/brainstorm.md) | Socratic design refinement — structured questioning before planning |
| [`/debug`](docs/commands/debug.md) | Phase-gated bug workflow — root cause → failing test → fix → verify (`patch`, `arch` subcommands) |
| [`/refactor`](docs/commands/refactor.md) | Design-first restructuring with behavior-unchanged verification (`inline` subcommand) |
| [`/kickoff`](docs/commands/kickoff.md) | Parallel PM+TL kickoff → spec → implementation plan → task graph |
| [`/orchestrate`](docs/commands/orchestrate.md) | Full lifecycle: fetch issue → worktree → agents → review loops → PR |
| [`/standup`](docs/commands/standup.md) | Status snapshot: TaskList + agent context, surfaces blockers and stale tasks |
| [`/wrap-ticket`](docs/commands/wrap-ticket.md) | Close out: verify tasks, capture learnings, update plans, remove worktree |

### Spec management

| Command | What it does |
|---------|-------------|
| `/create-spec` | Guided interview → new behavioral spec in `specs/` |
| `/update-spec` | Modify an existing spec with version history |
| `/find-spec` | Search specs by keyword |
| `/list-specs` | Quick status overview of all specs |
| `/check-specs` | Audit spec format + code alignment (MATCH/MISSING/DIFFERS per requirement) |
| `/reflect-specs` | Full health check — ALL specs exhaustively, cross-spec conflicts, interactive |
| `/generate-specs` | Reverse-engineer specs from existing code (legacy project baseline) |
| `/generate-tests` | Generate tests from specs — one test per MUST requirement, tagged with spec ID |

### Code quality

| Command | What it does |
|---------|-------------|
| [`/review-and-commit`](docs/commands/review-and-commit.md) | 5-agent parallel review with confidence scoring, blocks commit on critical issues |
| [`/blind-review`](docs/commands/blind-review.md) | Multi-team blind peer review with quorum analysis |
| [`/council`](docs/commands/council.md) | Adversarial tribunal — reality-checks a claim, session slice, or diff |
| `/tdd-gate` | Toggle hook-based TDD enforcement — blocks Write/Edit without tests (on/off/status) |

### Memory & recall

| Command | What it does |
|---------|-------------|
| [`/memory-search`](docs/commands/memory-search.md) | Search agent memories — semantic, keyword, or grep fallback |
| [`/recall`](docs/commands/recall.md) | Cross-source search: sessions, memory, specs, plans, git history |
| [`/memory-distill`](docs/commands/memory-distill.md) | Compress raw memories into digests, promote high-signal to core |
| [`/memory-config`](docs/commands/memory-config.md) | View and set memory configuration (distill mode, threshold) |
| `/memory-stats` | Show memory usage statistics (counts, sizes, growth) |
| `/validate-memory` | Cross-reference agent memories against the live codebase to detect stale refs |
| [`/handoff`](docs/commands/handoff.md) | Reconstruct a past session, or capture the current one, into a dense brief |

### Maintenance

| Command | What it does |
|---------|-------------|
| `/backlog` | Manage project backlog items (add, close, list, init) |
| `/release` | Bump version across all files, commit, tag, push |
| `/scout-plugins` | Research new plugins, evaluate against current setup, propose enhancements |
| [`/retro`](docs/commands/retro.md) | Review past sessions for friction patterns, propose directive adjustments |

## Quick Start

> **Heads up**: `/init-team` downloads sqlite-vec, sqlite-lembed, and an embedding model
> (~29MB) for semantic memory search — 1–2 minutes, needs internet. On a restricted or
> air-gapped network, use `/init-team --no-extensions` for keyword-only search.

**New project:**
```
/scaffold-project          # Sets up AGENTS.md, specs/TDD.md, .claude/plans/
/init-team                 # Bootstraps all agent memories from your codebase
/init-orchestration        # Enable Agent Teams: env var + quality-gate hook + AGENTS.md
```

**Existing project:**
```
/init-team                 # Run once — reads AGENTS.md, code, CI, infra, writes per-agent memory
```

**Starting a task:**
```
/kickoff POC-123 "Add user avatar upload with S3 storage"
```
Runs PM + Tech Lead in parallel, creates a spec, produces an implementation plan, and
generates a task graph — all in one command. For full lifecycle automation (branch,
implement, review, PR), use `/orchestrate POC-123`.

You can also invoke agents directly (`Use the ic5 subagent to implement: …`) or just
describe the task — Claude routes to the right agent based on their descriptions.

> `/scaffold-project` and `/init-orchestration` generate a local `.claude/settings.json`
> that pre-approves common operations so agents run without permission prompts.
> See [Autonomy & Permissions](#autonomy--permissions) below.

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

| Task type | Agent |
|-----------|-------|
| Ambiguous / hard / new system | IC5 |
| Clear pattern extension / tests / config | IC4 |
| Design question / architecture | Tech Lead |
| Bug investigation + fix | IC5 |
| Infrastructure, deploy, CI | DevOps |
| Spec validation, release gate | QA |
| Requirements, scoping | PM |

## Specs

Specs live in `specs/` and are tracked in `specs/TDD.md`. QA reads them as acceptance
criteria; the IC agents read them before implementation. Create with `/create-spec`, audit
with `/check-specs`, and run a full health check with `/reflect-specs`. Categories:

| Prefix | Category |
|--------|----------|
| `SPEC-` | Core behavior |
| `PERF-` | Performance |
| `SAFE-` | Safety / concurrency |
| `COMPAT-` | Compatibility |
| `ARCH-` | Architecture |

See the **[Specs runbook](docs/runbooks/specs.md)** for the full workflow.

## Autonomy & Permissions

`.claude/settings.json` is generated locally — by `/scaffold-project` for interactive/solo
work, or by `/init-orchestration` for Agent Teams — and is **gitignored, not shipped with
the plugin**. It pre-approves common operations so agents run without prompting for every
tool call:

- **Interactive (`/scaffold-project`)** — `defaultMode: "acceptEdits"` plus a curated Bash
  allowlist (dev tools, agent-bootstrap patterns, read-only utilities, `sqlite3`, `curl`).
  Destructive commands like `rm` and `wget` still prompt. The canonical list lives in
  `skills/scaffold-project/SKILL.md` — the single source of truth.
- **Orchestration (`/init-orchestration`)** — grants `Bash(*)` under `bypassPermissions`,
  where the OS sandbox, not the allowlist, is the boundary.

Extend for your stack by adding entries (`Bash(terraform:*)`, `Bash(kubectl:*)`, …) to
`.claude/settings.json`. Full details in the **[Setup Guide](docs/setup.md)**.

## Adding to a Team

### Claude Code

The generated `.claude/settings.json` is gitignored, so to share the plugin with teammates,
add the marketplace entry to a settings file you **do** commit:

```json
{
  "extraKnownMarketplaces": {
    "dev-team": {
      "source": { "source": "github", "repo": "cold-dark-void/claude-dev-team" }
    }
  }
}
```

### opencode

For opencode, clone the repo and run `bash install.sh` to create symlinks in your opencode config directory. Commands are accessible as `/dev-team/<command-name>` (e.g., `/dev-team/handoff`, `/dev-team/recall`).

For skills, add your clone's `skills/` directory to `opencode.json` (skills are
**not** symlinked by `install.sh` — they are loaded in place from the clone):

```json
{
  "skills": {
    "paths": ["~/claude-dev-team/skills"]
  }
}
```

For teammates, add the plugin paths to `opencode.json`. Agents and commands resolve
from the `install.sh` symlinks under `~/.config/opencode/`; skills still load from
the clone's `skills/` directory:

```json
{
  "skills": {
    "paths": ["~/claude-dev-team/skills"]
  },
  "agents": {
    "paths": ["~/.config/opencode/agents"]
  },
  "commands": {
    "paths": ["~/.config/opencode/commands"]
  }
}
```

Note: opencode command names are namespaced as `/dev-team/<command>` (e.g., `/dev-team/handoff` instead of `/handoff`) to avoid conflicts with other plugins and opencode's built-in commands.

## /council

Adversarial tribunal that reality-checks claims with material evidence. Spawns blind
read-only investigators, a prosecutor, a devil's advocate, and a tool-less `council-judge`,
then issues per-claim verdicts (`VERIFIED`, `PARTIALLY_VERIFIED`, `UNVERIFIED`,
`CONTRADICTED`, `FABRICATED`) with confidence scores — every verdict backed by investigator
evidence or struck. Shares an engine with `/review-and-commit` (`diff-mode` preset).

Full docs: **[`docs/commands/council.md`](docs/commands/council.md)** ·
Contract: `specs/core/SPEC-013-adversarial-council-tribunal.md`.

## Requirements

- Claude Code 2.x+ (Claude Code install)
- opencode 1.x+ (opencode install)
- Git (for worktree-aware memory path resolution)
- `sqlite3` recommended for the SQLite memory backend — agents fall back to `.md` files without it

## Changelog

See **[CHANGELOG.md](CHANGELOG.md)**. Maintained by the `/release` skill.

## License

MIT
