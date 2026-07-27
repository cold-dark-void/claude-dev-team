# Documentation

Everything for the **claude-dev-team** plugin. New here? Start with the
[Onboarding runbook](runbooks/onboarding.md), then come back for command details.

The command index below mirrors the tiered layout in the
[project README Commands](../README.md#commands) section (Core / Advanced /
Internal / Migration). Full per-command pages live under `commands/` when one
exists; skills-backed Surfaces without a page still appear here.

## Guides

| Guide | What's in it |
|-------|--------------|
| [Setup & Configuration](setup.md) | Prerequisites, **upgrading**, optional tools, `/setup`, memory config |
| [Onboarding](runbooks/onboarding.md) | "Just cloned the repo" → agents ready (glossary + optional Graphify) |
| [Migrate to v1.0.0](runbooks/migrate-to-v1.md) | 0.x → 1.0.0 consumer checklist (doctor, schema, hooks, stubs) |
| [Idea → Plan](runbooks/idea-to-plan.md) | Rough idea → brainstorm (`--grill`) → spec → plan |
| [Orchestrate](runbooks/orchestrate.md) | Full lifecycle end-to-end with `/orchestrate` |
| [Specs](runbooks/specs.md) | Spec workflow — create, audit, reflect |
| [Memory](runbooks/memory.md) | Memory tiers, distillation, **prose compress**, domain glossary vs DB |
| [Manual operation](runbooks/manual.md) | Driving agents by hand without orchestrators |
| [Scheduled retro](runbooks/scheduled-retro.md) | Opt-in cron for `/retro --all --auto` |
| [Permission posture matrix](runbooks/permission-posture-matrix.md) | C8 evidence — `dontAsk` ship default (pin Claude Code 2.1.190) |

**What's new / upgrade path:** [CHANGELOG](../CHANGELOG.md) (newest first) · [Migrate to v1.0.0](runbooks/migrate-to-v1.md) · [Setup → Upgrading](setup.md#upgrading-the-plugin-existing-projects).

## Command reference

> **opencode**: Commands are namespaced under `/dev-team/` (e.g., `/dev-team/handoff`).
> Claude Code uses the bare name (e.g., `/handoff`).

### Core

First-ticket lifecycle: install → health → plan → execute → review → ship.

| Command | Docs | When to use |
|---------|------|-------------|
| `/setup` | [setup](commands/setup.md) · [Setup guide](setup.md) | Onboard a project — `project` · `orchestration` · `team` |
| `/doctor` | skill | Diagnose install/config health (PASS/WARN/FAIL); read-only default, `--fix` allowlist |
| `/kickoff` | [kickoff](commands/kickoff.md) | Parallel PM+TL planning → spec → plan → task graph |
| `/orchestrate` | [orchestrate](commands/orchestrate.md) · [runbook](runbooks/orchestrate.md) | Full lifecycle: issue → worktree → agents → review → ship/PR |
| `/debug` | [debug](commands/debug.md) | Phase-gated bug fix (`patch`/`arch`) or ticket pipeline (`ticket`) |
| `/council` | [council](commands/council.md) | Adversarial tribunal — reality-check a claim, session slice, or diff |
| `/release` | skill | Bump version (CHANGELOG + plugin JSON), commit, tag, push |
| `/status` | [status](commands/status.md) | Read-only hub — bare = standup→metrics→worktrees; subs `standup` · `metrics` · `worktree` |
| `/memory` | [memory](commands/memory.md) · [runbook](runbooks/memory.md) | Unified memory — `config` · `distill` · `export` · `search` · `stats` · `validate` |
| `/spec` | [spec](commands/spec.md) · [runbook](runbooks/specs.md) | Unified specs — `check` · `create` · `find` · `list` · `update` · `generate` · `tests` · `reflect` |

### Advanced

Program / multi-ticket work, session tuning, and quality gates.

| Command | Docs | When to use |
|---------|------|-------------|
| `/epic` | [epic](commands/epic.md) | Decompose an umbrella into sequenced children for `/kickoff` or `/orchestrate` |
| `/backlog` | skill | Manage backlog items (Linear-first dual-write when MCP is up) |
| `/brainstorm` | [brainstorm](commands/brainstorm.md) · [Idea→Plan](runbooks/idea-to-plan.md) | Socratic design refinement (`--grill` one-Q + recommended answers) |
| `/craft-loop` | [craft-loop](commands/craft-loop.md) | Design reviewed loop programs for the host `/loop`/`/goal` |
| `/release-train` | skill | Multi-branch release queue — register, freeze, land via `/release` |
| `/retro` | [retro](commands/retro.md) · [scheduled runbook](runbooks/scheduled-retro.md) | Scan past sessions for friction; propose directive adjustments |
| `/handoff` | [handoff](commands/handoff.md) | Reconstruct a past session (or capture current) into a dense brief |
| `/recall` | [recall](commands/recall.md) | Cross-source search: sessions, memory, specs, plans, git history |
| `/mode` | [mode](commands/mode.md) | Session modes — `focus` (action+evidence) · `blunt` (tone+confidence); `status` / `off` |
| `/adjust-agent` | skill | View/manage per-agent standing directives (`--apply` for non-interactive) |
| `/worktree` | [worktree](commands/worktree.md) | Release a plugin worktree (`release <slug>`); list via `/status worktree` |
| `/ci-watch` | skill | Poll PR checks / local tests and spawn a fixer (armed by `/orchestrate`) |
| `/review-and-commit` | [review-and-commit](commands/review-and-commit.md) | Multi-specialist review with confidence scoring; blocks commit on criticals |
| `/refactor` | [refactor](commands/refactor.md) | Design-first restructuring with behavior-unchanged verification |
| `/tdd-gate` | skill | Toggle hook TDD enforcement — blocks Write/Edit without tests (`on`/`off`/`status`) |
| `/wrap-ticket` | [wrap-ticket](commands/wrap-ticket.md) | Close out: verify tasks, capture learnings, re-close tracker, drop worktree |

### Internal

Agent protocols (`agent-memory`, `memory-store`, `memory-recall`), council/orchestrate
engines, gates (`docs-drift`, `skill-lint`, …), and `tools/` helpers are **not**
user-invoked Surfaces — they run under Core/Advanced commands or CI. Internal agents
`project-init`, `distiller`, and `council-judge` are reached only via `/setup team`,
`/memory distill`, and `/council`.

### Migration / deprecated

Stubs remain discoverable until **removed at v1.1**. Prefer the replacement now.
Full checklist: [Migrate to v1.0.0](runbooks/migrate-to-v1.md).
Authoritative old→new table: [CHANGELOG v1.0.0 Migration](../CHANGELOG.md#v100).

| Command | Docs | Replacement |
|---------|------|-------------|
| `/init-team` | — | `/setup team` |
| `/init-orchestration` | — | `/setup orchestration` |
| `/scaffold-project` | — | `/setup project` |
| `/focus` | [focus](commands/focus.md) | `/mode focus` |
| `/blunt` | [blunt](commands/blunt.md) | `/mode blunt` |
| `/metrics` | — | `/status metrics` |
| `/standup` | [standup](commands/standup.md) | `/status standup` |
| `/fix-ticket` | [fix-ticket](commands/fix-ticket.md) | `/debug ticket` |
| `/blind-review` | — | `/council --blind` |
| `/create-spec` | — | `/spec create` |
| `/update-spec` | — | `/spec update` |
| `/find-spec` | — | `/spec find` |
| `/list-specs` | — | `/spec list` |
| `/check-specs` | — | `/spec check` |
| `/generate-specs` | — | `/spec generate` ([legacy baseline](setup.md#spec-generate-legacy-project-baseline)) |
| `/generate-tests` | — | `/spec tests` |
| `/reflect-specs` | — | `/spec reflect` |
| `/memory-config` | — | `/memory config` ([setup](setup.md#memory-configuration-memory-config)) |
| `/memory-distill` | — | `/memory distill` |
| `/memory-export` | — | `/memory export` |
| `/memory-search` | — | `/memory search` |
| `/memory-stats` | — | `/memory stats` |
| `/validate-memory` | — | `/memory validate` |
| `/incident` | — | removed (no war-room Surface; use devops role + `/debug`) |
| `/demo` | — | removed (use `/setup` + `/kickoff` on scratch) |
| `/local-do` | — | removed (local-agent offload excised) |

`/worktree list` and `/worktree status` moved to `/status worktree`; live mutate path is `/worktree release <slug>` only.

## See also

- [Project README](../README.md) — overview, install, agent roster, tiered Commands
- [CHANGELOG](../CHANGELOG.md) — release history + migration table
- `specs/` — the behavioral specs the agents implement against
