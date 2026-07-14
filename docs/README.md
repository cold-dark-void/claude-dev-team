# Documentation

Everything for the **claude-dev-team** plugin. New here? Start with the
[Onboarding runbook](runbooks/onboarding.md), then come back for command details.

## Guides

| Guide | What's in it |
|-------|--------------|
| [Setup & Configuration](setup.md) | Prerequisites, `/init-team`, memory config, remote embeddings, troubleshooting |
| [Onboarding](runbooks/onboarding.md) | "Just cloned the repo" → agents ready to take tickets |
| [Idea → Plan](runbooks/idea-to-plan.md) | Turning a rough idea into a spec and an implementation plan |
| [Orchestrate](runbooks/orchestrate.md) | Running the full lifecycle end-to-end with `/orchestrate` |
| [Specs](runbooks/specs.md) | The spec workflow — create, audit, reflect |
| [Memory](runbooks/memory.md) | How memory works, distillation, search, hygiene |
| [Manual operation](runbooks/manual.md) | Driving the agents by hand, without the orchestrators |
| [Scheduled retro](runbooks/scheduled-retro.md) | Opt-in cron for `/retro --all --auto` (reports under `.claude/retro/`) |

## Command reference

Commands with a dedicated page link to it; lighter commands are described here and
documented further in their skill (`skills/<name>/SKILL.md`) or the linked guide.

### Setup (run once per project)

| Command | Docs | Summary |
|---------|------|---------|
| `/init-team` | [Setup](setup.md#init-team--bootstrap-agent-memory) | Bootstrap all 7 agents' memory for the project |
| `/init-orchestration` | [Setup](setup.md#init-orchestration--enable-agent-teams) | Enable Agent Teams: sandbox, env var, hooks, AGENTS.md |
| `/scaffold-project` | skill | TDD workflow structure: `AGENTS.md`, `specs/TDD.md`, `.claude/plans/` |
| `/adjust-agent` | skill | View/manage per-agent behavioral directives (`--apply`) |
| `/demo` | [demo](commands/demo.md) | Interactive walkthrough of the full pipeline in a temp project |

### Feature work

| Command | Docs | Summary |
|---------|------|---------|
| `/brainstorm` | [brainstorm](commands/brainstorm.md) | Socratic design refinement before planning |
| `/debug` | [debug](commands/debug.md) | Phase-gated bug workflow (`patch`, `arch` subcommands) |
| `/refactor` | [refactor](commands/refactor.md) | Design-first restructuring, behavior-preserving (`inline`) |
| `/kickoff` | [kickoff](commands/kickoff.md) | Parallel PM+TL kickoff → spec → plan → task graph |
| `/orchestrate` | [orchestrate](commands/orchestrate.md) | Full lifecycle: issue → worktree → agents → review → PR |
| `/standup` | [standup](commands/standup.md) | Status snapshot of active agent work |
| `/wrap-ticket` | [wrap-ticket](commands/wrap-ticket.md) | Close out: verify, capture learnings, remove worktree |
| `/craft-loop` | [craft-loop](commands/craft-loop.md) | Design reviewed loop programs for the built-in `/loop`/`/goal` (library, journal, refine) |

### Spec management

| Command | Docs | Summary |
|---------|------|---------|
| `/create-spec` | [Specs runbook](runbooks/specs.md) | Guided interview → new behavioral spec |
| `/update-spec` | [Specs runbook](runbooks/specs.md) | Modify an existing spec with version history |
| `/find-spec` | skill | Search specs by keyword |
| `/list-specs` | skill | Quick status overview of all specs |
| `/check-specs` | [Specs runbook](runbooks/specs.md) | Audit format + code alignment (MATCH/MISSING/DIFFERS) |
| `/reflect-specs` | [Specs runbook](runbooks/specs.md) | Full health check across ALL specs, interactive |
| `/generate-specs` | [Setup](setup.md#generate-specs--legacy-project-baseline) | Reverse-engineer specs from existing code |
| `/generate-tests` | skill | Generate tests from specs — one per MUST requirement |

### Code quality

| Command | Docs | Summary |
|---------|------|---------|
| `/review-and-commit` | [review-and-commit](commands/review-and-commit.md) | 5-agent parallel review, blocks on critical issues |
| `/blind-review` | [blind-review](commands/blind-review.md) | Multi-team blind peer review with quorum analysis |
| `/council` | [council](commands/council.md) | Adversarial tribunal — reality-checks claims with evidence |
| `/tdd-gate` | skill | Toggle hook-based TDD enforcement (on/off/status) |

### Memory & recall

| Command | Docs | Summary |
|---------|------|---------|
| `/memory-search` | [memory-search](commands/memory-search.md) | Search agent memories — semantic/keyword/grep |
| `/recall` | [recall](commands/recall.md) | Cross-source search: sessions, memory, specs, plans, git |
| `/memory-distill` | [memory-distill](commands/memory-distill.md) | Compress raw memories, promote high-signal to core |
| `/memory-config` | [memory-config](commands/memory-config.md) | View/set memory configuration |
| `/memory-stats` | skill | Memory usage statistics (counts, sizes, growth) |
| `/memory-export` | skill | Export sanitized tier-2 memories to a committable seed pack (SPEC-024) |
| `/validate-memory` | skill | Detect stale memory references against live code |
| `/handoff` | [handoff](commands/handoff.md) | Reconstruct a past session, or capture the current one |

### Maintenance

| Command | Docs | Summary |
|---------|------|---------|
| `/doctor` | skill | Install/config diagnostics (PASS/WARN/FAIL); `--json` / `--fix`; namespaced `dev-team:doctor` |
| `/backlog` | skill | Manage project backlog items (add, close, list, init) |
| `/release` | skill | Bump version across all files, commit, tag, push |
| `/scout-plugins` | skill | Research new plugins, propose enhancements |
| `/retro` | [retro](commands/retro.md) · [scheduled runbook](runbooks/scheduled-retro.md) | Review sessions for friction, propose directive adjustments; opt-in `--all --auto` schedule |
| `/local-do` | skill | Offload one mechanical, machine-verifiable task to the local model |

## See also

- [Project README](../README.md) — overview, install, agent roster
- [CHANGELOG](../CHANGELOG.md) — release history
- `specs/` — the behavioral specs the agents implement against
