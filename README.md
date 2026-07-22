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

The opencode install script symlinks `commands/` and generates opencode-valid agent files (Claude Code's string `tools:` field is stripped — opencode rejects it) into your opencode config directory (`~/.config/opencode/`). Re-run `bash install.sh` after editing an agent. Skills are added via `opencode.json` `skills.paths`.

## Documentation

| Guide | What's in it |
|-------|--------------|
| **[Documentation hub](docs/README.md)** | Index of every command, runbook, and guide — start here |
| [Setup & Configuration](docs/setup.md) | Prerequisites, `/setup`, memory config, remote embeddings, troubleshooting |
| [Onboarding runbook](docs/runbooks/onboarding.md) | "Just cloned the repo" → agents ready to take tickets |
| [Memory runbook](docs/runbooks/memory.md) | How memory works, distillation, search, hygiene |
| [Command reference](docs/commands/) | Per-command pages (usage, flags, examples) |
| [CHANGELOG](CHANGELOG.md) | Release history — **start here to discover new features** |
| [Upgrading](docs/setup.md#upgrading-the-plugin-existing-projects) | Existing projects: what to re-run (usually nothing beyond plugin update) |
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
commands (`/setup team`, `/memory distill`, `/council`), not directly. Every agent has
persistent per-project memory.

### Memory

Each agent remembers what it learns about your project, so the team stops re-reading the
codebase from scratch every session. Storage is **SQLite with semantic search** when
available (after `/setup team` downloads the embedding extensions, ~29MB), and falls back
**transparently to per-agent markdown files** when it isn't. Per-worktree task progress
always lives in `context.md`.

**Domain glossary (separate):** optional committed `CONTEXT.md` (or
`docs/domain/CONTEXT.md`) holds the project's ubiquitous language — preferred term
names and aliases to avoid. `/brainstorm` and `/kickoff` load and update it; this is
not agent memory and needs no extra tooling.

See the **[Memory runbook](docs/runbooks/memory.md)** for storage layout, tiers, and
distillation, and the **[Setup Guide](docs/setup.md#memory-configuration--memory-config)**
for configuration and remote-embedding options.

## Commands

The command index below is exhaustive (docs-drift `cmd-index` checked). Full
per-command docs live in **[`docs/commands/`](docs/commands/)** when a page exists;
skills-backed Surfaces without a page still appear here.

> **opencode**: Commands are namespaced under `/dev-team/` (e.g., `/dev-team/handoff`).
> Claude Code uses the bare name (e.g., `/handoff`).

### Core

First-ticket lifecycle: install → health → plan → execute → review → ship.

| Command | When to use |
|---------|-------------|
| [`/setup`](docs/commands/setup.md) | Onboard a project — `project` · `orchestration` · `team` |
| `/doctor` | Diagnose install/config health (PASS/WARN/FAIL); read-only default, `--fix` allowlist |
| [`/kickoff`](docs/commands/kickoff.md) | Parallel PM+TL planning → spec → implementation plan → task graph |
| [`/orchestrate`](docs/commands/orchestrate.md) | Full lifecycle: issue → worktree → agents → review → ship/PR |
| [`/debug`](docs/commands/debug.md) | Phase-gated bug fix (`patch`/`arch`) or ticket pipeline (`ticket`) |
| [`/council`](docs/commands/council.md) | Adversarial tribunal — reality-check a claim, session slice, or diff |
| `/release` | Bump version (CHANGELOG + plugin JSON), commit, tag, push |
| [`/status`](docs/commands/status.md) | Read-only hub — bare = standup→metrics→worktrees; subs `standup` · `metrics` · `worktree` |
| [`/memory`](docs/commands/memory.md) | Unified memory — `config` · `distill` · `export` · `search` · `stats` · `validate` |
| [`/spec`](docs/commands/spec.md) | Unified specs — `check` · `create` · `find` · `list` · `update` · `generate` · `tests` · `reflect` |

### Advanced

Program / multi-ticket work, session tuning, and quality gates.

| Command | When to use |
|---------|-------------|
| [`/epic`](docs/commands/epic.md) | Decompose an umbrella into sequenced children for `/kickoff` or `/orchestrate` |
| `/backlog` | Manage backlog items (Linear-first dual-write when MCP is up) |
| [`/brainstorm`](docs/commands/brainstorm.md) | Socratic design refinement before planning (`--grill` for one-Q-at-a-time) |
| [`/craft-loop`](docs/commands/craft-loop.md) | Design reviewed loop programs for the host `/loop`/`/goal` |
| `/release-train` | Multi-branch release queue — register, freeze, land via `/release` |
| [`/retro`](docs/commands/retro.md) | Scan past sessions for friction; propose directive adjustments ([runbook](docs/runbooks/scheduled-retro.md)) |
| [`/handoff`](docs/commands/handoff.md) | Reconstruct a past session (or capture current) into a dense brief |
| [`/recall`](docs/commands/recall.md) | Cross-source search: sessions, memory, specs, plans, git history |
| [`/mode`](docs/commands/mode.md) | Session modes — `focus` (action+evidence) · `blunt` (tone+confidence); `status` / `off` |
| `/adjust-agent` | View/manage per-agent standing directives (`--apply` for non-interactive) |
| [`/worktree`](docs/commands/worktree.md) | Release a plugin worktree (`release <slug>`); list via `/status worktree` |
| `/ci-watch` | Poll PR checks / local tests and spawn a fixer (armed by `/orchestrate`) |
| [`/review-and-commit`](docs/commands/review-and-commit.md) | Multi-specialist review with confidence scoring; blocks commit on criticals |
| [`/refactor`](docs/commands/refactor.md) | Design-first restructuring with behavior-unchanged verification |
| `/tdd-gate` | Toggle hook TDD enforcement — blocks Write/Edit without tests (`on`/`off`/`status`) |
| [`/wrap-ticket`](docs/commands/wrap-ticket.md) | Close out: verify tasks, capture learnings, re-close tracker, drop worktree |

Optional host SAST: if `semgrep` (and/or CodeQL with an existing DB) is on PATH,
`/review-and-commit` and the council security flavor run a fail-open scan first
(`skills/security-scan`; `SECURITY_SCAN=0` to skip). Not required to install.

### Internal

Agent protocols (`agent-memory`, `memory-store`, `memory-recall`), council/orchestrate
engines, gates (`docs-drift`, `skill-lint`, …), and `tools/` helpers are **not**
user-invoked Surfaces — they run under Core/Advanced commands or CI. Internal agents
`project-init`, `distiller`, and `council-judge` are reached only via `/setup team`,
`/memory distill`, and `/council`.

### Migration / deprecated

Stubs remain discoverable until **removed at v1.1**. Prefer the replacement now.

| Command | Replacement |
|---------|-------------|
| `/init-team` | `/setup team` — removed at v1.1 |
| `/init-orchestration` | `/setup orchestration` — removed at v1.1 |
| `/scaffold-project` | `/setup project` — removed at v1.1 |
| [`/focus`](docs/commands/focus.md) | `/mode focus` — removed at v1.1 |
| [`/blunt`](docs/commands/blunt.md) | `/mode blunt` — removed at v1.1 |
| `/metrics` | `/status metrics` — removed at v1.1 |
| [`/standup`](docs/commands/standup.md) | `/status standup` — removed at v1.1 |
| [`/fix-ticket`](docs/commands/fix-ticket.md) | `/debug ticket` — removed at v1.1 |
| `/blind-review` | `/council --blind` — removed at v1.1 |
| `/create-spec` | `/spec create` — removed at v1.1 |
| `/update-spec` | `/spec update` — removed at v1.1 |
| `/find-spec` | `/spec find` — removed at v1.1 |
| `/list-specs` | `/spec list` — removed at v1.1 |
| `/check-specs` | `/spec check` — removed at v1.1 |
| `/generate-specs` | `/spec generate` — removed at v1.1 |
| `/generate-tests` | `/spec tests` — removed at v1.1 |
| `/reflect-specs` | `/spec reflect` — removed at v1.1 |
| `/memory-config` | `/memory config` — removed at v1.1 |
| `/memory-distill` | `/memory distill` — removed at v1.1 |
| `/memory-export` | `/memory export` — removed at v1.1 |
| `/memory-search` | `/memory search` — removed at v1.1 |
| `/memory-stats` | `/memory stats` — removed at v1.1 |
| `/validate-memory` | `/memory validate` — removed at v1.1 |
| `/incident` | removed (no war-room Surface; use devops role + `/debug`) — removed at v1.1 |
| `/demo` | removed (use `/setup` + `/kickoff` on scratch) — removed at v1.1 |
| `/local-do` | removed (local-agent offload excised) — removed at v1.1 |

`/worktree list` and `/worktree status` moved to `/status worktree`; live mutate path is `/worktree release <slug>` only.

## Quick Start

> **Heads up**: `/setup team` downloads sqlite-vec, sqlite-lembed, and an embedding model
> (~29MB) for semantic memory search — 1–2 minutes, needs internet. On a restricted or
> air-gapped network, use `/setup team --no-extensions` for keyword-only search.

**New project:**
```
/setup project             # Sets up AGENTS.md, specs/TDD.md, .claude/plans/
/setup team                # Bootstraps all agent memories from your codebase
/setup orchestration       # Enable Agent Teams: env var + quality-gate hook + AGENTS.md
```

**Existing project:**
```
/setup team                # Run once — reads AGENTS.md, code, CI, infra, writes per-agent memory
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

> `/setup project` and `/setup orchestration` generate a local `.claude/settings.json`
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
criteria; the IC agents read them before implementation. Create with `/spec create`, audit
with `/spec check`, and run a full health check with `/spec reflect`. Categories:

| Prefix | Category |
|--------|----------|
| `SPEC-` | Core behavior |
| `PERF-` | Performance |
| `SAFE-` | Safety / concurrency |
| `COMPAT-` | Compatibility |
| `ARCH-` | Architecture |

See the **[Specs runbook](docs/runbooks/specs.md)** for the full workflow.

## Autonomy & Permissions

Process state under `.claude/` (settings, hooks, plans, memory, backlog, …) is **local
runtime only** — gitignored and **never committed as product delivery** (never upstream).
Each machine regenerates it via `/setup`.

`.claude/settings.json` is written by `/setup project` (interactive/solo) or
`/setup orchestration` (Agent Teams). It pre-approves common operations so agents run
without prompting for every tool call:

- **Interactive (`/setup project`)** — `defaultMode: "acceptEdits"` plus a curated Bash
  allowlist (dev tools, agent-bootstrap patterns, read-only utilities, `sqlite3`, `curl`).
  Destructive commands like `rm` and `wget` still prompt. The canonical list lives in
  `skills/scaffold-project/SKILL.md` — the single source of truth.
- **Orchestration (`/setup orchestration`)** — grants the **matrix allow set**
  (`Bash(*)` + Read/Write/Edit/Glob/Grep/Agent/Task) under `dontAsk` with
  sandbox enabled + `autoAllowBashIfSandboxed` (matrix winner Cell C; evidence in
  `docs/runbooks/permission-posture-matrix.md`). The OS sandbox is the boundary;
  `dontAsk` never prompts (allow/auto-allow run; everything else is denied).

Extend for your stack by adding entries (`Bash(terraform:*)`, `Bash(kubectl:*)`, …) to
`.claude/settings.json`. Full details in the **[Setup Guide](docs/setup.md)**.

**Plugin contributors:** live `.claude/hooks/*.sh` are generated, not package-tracked.
Edit the fenced templates in `skills/init-orchestration/SKILL.md` (sole source of truth),
then re-run `/setup orchestration` to regenerate hooks locally.

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

For opencode, clone the repo and run `bash install.sh` to install into your opencode config directory (commands are symlinked; agents are copied with the Claude Code `tools:` field stripped, since opencode rejects it — re-run after editing an agent). Commands are accessible as `/dev-team/<command-name>` (e.g., `/dev-team/handoff`, `/dev-team/recall`).

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

## Versioning

Plugin version is kept in lockstep across `plugin.json`, `marketplace.json`,
and `CHANGELOG.md`. Use **`/release`** to bump, commit, tag, and push — do not
edit those three files by hand. Contract: [SPEC-002](specs/core/SPEC-002-plugin-infrastructure.md).

## License

MIT — see [LICENSE](LICENSE).

## Security

Supported versions and vulnerability reporting: [SECURITY.md](SECURITY.md).
