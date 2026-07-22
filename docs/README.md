# Documentation

Everything for the **claude-dev-team** plugin. New here? Start with the
[Onboarding runbook](runbooks/onboarding.md), then come back for command details.

## Guides

| Guide | What's in it |
|-------|--------------|
| [Setup & Configuration](setup.md) | Prerequisites, **upgrading**, optional tools, `/setup`, memory config |
| [Onboarding](runbooks/onboarding.md) | "Just cloned the repo" → agents ready (glossary + optional Graphify) |
| [Idea → Plan](runbooks/idea-to-plan.md) | Rough idea → brainstorm (`--grill`) → spec → plan |
| [Orchestrate](runbooks/orchestrate.md) | Full lifecycle end-to-end with `/orchestrate` |
| [Specs](runbooks/specs.md) | Spec workflow — create, audit, reflect |
| [Memory](runbooks/memory.md) | Memory tiers, distillation, **prose compress**, domain glossary vs DB |
| [Manual operation](runbooks/manual.md) | Driving agents by hand without orchestrators |
| [Scheduled retro](runbooks/scheduled-retro.md) | Opt-in cron for `/retro --all --auto` |

**What's new / upgrade path:** [CHANGELOG](../CHANGELOG.md) (newest first) · [Setup → Upgrading](setup.md#upgrading-the-plugin-existing-projects) (v0.71–v0.77: no migration; marketplace/opencode install only).

## Command reference

Commands with a dedicated page link to it; lighter commands are described here and
documented further in their skill (`skills/<name>/SKILL.md`) or the linked guide.

### Setup (run once per project)

| Command | Docs | Summary |
|---------|------|---------|
| `/setup` | [setup](commands/setup.md) · [Setup guide](setup.md) | Onboarding: `project` · `orchestration` · `team` |
| `/init-team` | [Setup](setup.md#setup-team--bootstrap-agent-memory) | Bootstrap agent memory **(deprecated — use /setup team)** |
| `/init-orchestration` | [Setup](setup.md#setup-orchestration--enable-agent-teams) | Enable Agent Teams (prefer `/setup orchestration`) |
| `/scaffold-project` | skill | TDD workflow structure (prefer `/setup project`) |
| `/adjust-agent` | skill | View/manage per-agent behavioral directives (`--apply`) |

### Feature work

| Command | Docs | Summary |
|---------|------|---------|
| `/brainstorm` | [brainstorm](commands/brainstorm.md) | Socratic design refinement (`--grill` one-Q + recommended answers) |
| `/mode` | [mode](commands/mode.md) | Session modes — `focus` · `blunt` · `status` · `off` |
| `/focus` | [focus](commands/focus.md) | Session mode — action-first + evidence **(deprecated — use /mode focus)** |
| `/blunt` | [blunt](commands/blunt.md) | Session tone — verdict-first **(deprecated — use /mode blunt)** |
| `/debug` | [debug](commands/debug.md) | Phase-gated bug workflow (`patch`, `arch`, `ticket`) |
| `/fix-ticket` | [fix-ticket](commands/fix-ticket.md) | Premise→implement→refuters **(deprecated — use /debug ticket)** |
| `/refactor` | [refactor](commands/refactor.md) | Design-first restructuring, behavior-preserving (`inline`) |
| `/kickoff` | [kickoff](commands/kickoff.md) | Parallel PM+TL kickoff → spec → plan → task graph (+ domain glossary) |
| `/orchestrate` | [orchestrate](commands/orchestrate.md) | Full lifecycle → review → optional **code-simplify** → QA → PR |
| `/epic` | [epic](commands/epic.md) | Umbrella decompose + sequenced child handoff |
| `/status` | [status](commands/status.md) | Read-only hub — bare = standup → metrics → worktrees |
| `/standup` | [standup](commands/standup.md) | Status snapshot **(prefer /status standup)** |
| `/wrap-ticket` | [wrap-ticket](commands/wrap-ticket.md) | Close out: verify, capture learnings, remove worktree |
| `/craft-loop` | [craft-loop](commands/craft-loop.md) | Design reviewed loop programs for the built-in `/loop`/`/goal` (library, journal, refine) |

### Spec management

| Command | Docs | Summary |
|---------|------|---------|
| `/spec` | [spec](commands/spec.md) | Unified: `check` · `create` · `find` · `list` · `update` · `generate` · `tests` · `reflect` |
| `/spec create` | [Specs runbook](runbooks/specs.md) | Guided interview → new behavioral spec |
| `/spec update` | [Specs runbook](runbooks/specs.md) | Modify an existing spec with version history |
| `/spec find` | skill | Search specs by keyword |
| `/spec list` | skill | Quick status overview of all specs |
| `/spec check` | [Specs runbook](runbooks/specs.md) | Audit format + code alignment |
| `/reflect-specs` | [Specs runbook](runbooks/specs.md) | Full health check across ALL specs (prefer `/spec reflect`) |
| `/generate-specs` | [Setup](setup.md#generate-specs--legacy-project-baseline) | Reverse-engineer specs from existing code (prefer `/spec generate`) |
| `/generate-tests` | skill | Generate tests from specs (prefer `/spec tests`) |

### Code quality

| Command | Docs | Summary |
|---------|------|---------|
| `/review-and-commit` | [review-and-commit](commands/review-and-commit.md) | 5-agent review; optional `--impact` / host SAST if Semgrep present |
| `/council` | [council](commands/council.md) | Adversarial tribunal + `--blind` multi-team peer review |
| `/tdd-gate` | skill | Toggle hook-based TDD enforcement (on/off/status) |

### Memory & recall

| Command | Docs | Summary |
|---------|------|---------|
| `/memory` | [memory](commands/memory.md) | Unified: `config` · `distill` · `export` · `search` · `stats` · `validate` |
| `/recall` | [recall](commands/recall.md) | Cross-source search: sessions, memory, specs, plans, git |
| `/handoff` | [handoff](commands/handoff.md) | Reconstruct a past session, or capture the current one |

### Maintenance

| Command | Docs | Summary |
|---------|------|---------|
| `/doctor` | skill | Install/config diagnostics (PASS/WARN/FAIL); `--json` / `--fix`; namespaced `dev-team:doctor` — distinct from harness `/doctor` |
| `/worktree` | [worktree](commands/worktree.md) | Release plugin worktree (`release <slug>`); list via `/status worktree` |
| `/backlog` | skill | Manage project backlog items (add, close, list, init) |
| `/release` | skill | Bump version across all files, commit, tag, push |
| `/retro` | [retro](commands/retro.md) · [scheduled runbook](runbooks/scheduled-retro.md) | Review sessions for friction, propose directive adjustments; opt-in `--all --auto` schedule |

## See also

- [Project README](../README.md) — overview, install, agent roster
- [CHANGELOG](../CHANGELOG.md) — release history
- `specs/` — the behavioral specs the agents implement against
