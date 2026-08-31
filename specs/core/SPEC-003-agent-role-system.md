# SPEC-003: Agent Role System

**Status**: ACTIVE
**Category**: core
**Created**: 2026-03-22

**Covers**: `agents/pm.md`, `agents/tech-lead.md`, `agents/ic5.md`, `agents/ic4.md`, `agents/devops.md`, `agents/qa.md`, `agents/ds.md`, `agents/finder.md`, `agents/debugger.md`, `commands/adjust-agent.md`

## Overview

The core concept of the plugin: a FAANG-style team of 7 specialized AI agents with distinct roles, responsibilities, model assignments, and tool access. Each agent has YAML frontmatter (name, description, tools, model), behavioral rules encoded in markdown, and a per-agent memory architecture. Behavioral directives provide persistent standing orders that agents cannot override.

Alongside the 7 behavioral agents the plugin ships **non-behavioral roster agents** — single-purpose agent files invoked by a specific engine, with no per-agent memory, no cortex, and no directives surface. `council-judge`, `distiller`, and `project-init` established that category; `finder` and `debugger` (CDT-230) join it. The full 12-file roster and its model/effort tier table are below.

## MUST

### Agent Identity
- MUST define exactly 7 behavioral agents: pm, tech-lead, ic5, ic4, devops, qa, ds
- MUST define exactly 5 non-behavioral roster agents: finder, debugger, council-judge, distiller, project-init. A non-behavioral agent MUST NOT have `.claude/memory/<agent>/`, a cortex, an `init-team` bootstrap entry, or a `/adjust-agent` directives surface. It MUST NOT carry the managed-inline memory-protocol include region (§ Memory Architecture). Precedent: `council-judge`.
- MUST require YAML frontmatter with `name`, `description`, `tools`, `model`, and `effort` fields on all 12 agent definitions
- MUST assign the model and effort tier for every roster agent per the Tier table below. This spec is SoT for both columns.
- MUST treat shipped frontmatter `model:` as the **Tier default** and shipped frontmatter `effort:` as the **Effort tier default**. Runtime model routing via the **Model map** is SPEC-037. Per-agent effort is NOT runtime-routable on this host — frontmatter is the only substrate that reaches a namespaced roster spawn (SPEC-037 § Host capability findings F3, F6). SPEC-037 MUST NOT rewrite `agents/*.md`.

### Tier table

| Agent | Model | Effort | Category |
|-------|-------|--------|----------|
| `tech-lead` | opus | high | behavioral |
| `council-judge` | opus | high | non-behavioral |
| `debugger` | opus | high | non-behavioral |
| `ds` | opus | medium | behavioral |
| `pm` | opus | medium | behavioral |
| `ic5` | sonnet | xhigh | behavioral |
| `qa` | sonnet | high | behavioral |
| `finder` | sonnet | high | non-behavioral |
| `devops` | sonnet | medium | behavioral |
| `ic4` | sonnet | medium | behavioral |
| `project-init` | sonnet | low | non-behavioral |
| `distiller` | haiku | low | non-behavioral |

- `effort` values MUST be drawn from the host loader's accepted set: `low`, `medium`, `high`, `xhigh`, `max` (SPEC-037 F5). An omitted `effort:` key inherits the session `effortLevel` (F7) and MUST NOT be relied on as a tier assignment.
- `model:` and `effort:` MUST both be present in the same frontmatter block; they resolve independently (SPEC-037 F8).

### Role split (CDT-230)
- `ic5` MUST be a pure senior implementer. It MUST NOT be the default agent for cheap parallel fan-out breadth or for causal root-cause depth.
- `finder` MUST be the fan-out investigation role: `/council` Phase 2 investigators, `/council` Phase 2.5 cross-reviewers, and `/bug-hunt` S1/S2 waves. Its body MUST stay generic across callers — it MUST NOT encode council-specific or bug-hunt-specific protocol. `/debug ticket` Step 5 refuters stay on `qa` (SPEC-014 § Root-cause agent).
- `debugger` MUST be the causal root-cause role for `/debug ticket` premise
  investigation. `full` / `patch` / `arch` root-cause phases have no
  named-roster Agent spawn (SPEC-037 M16 site 3) — `debugger` does not apply
  there.
- `finder` and `debugger` MUST be read-only. Tools MUST be exactly `Read, Grep, Glob, Bash, SendMessage` — no `Write`, no `Edit`.
- On host-reject of a `finder` or `debugger` spawn, the caller MUST fall back to `ic5` (the pre-CDT-230 agent for all three job shapes), not to `ic4`.

### Role Boundaries
- MUST NOT allow PM to write code or make technical implementation decisions
- MUST NOT allow Tech Lead to implement features (architecture and design only)
- MUST NOT allow IC4 to tackle ambiguous or architecturally significant work alone — MUST escalate to IC5 or Tech Lead
- MUST NOT allow DevOps to modify application business logic
- MUST NOT allow QA to approve releases when blocking bugs exist
- MUST NOT allow DS to ship models without evaluation metrics and baseline comparison

### Role Responsibilities
- MUST require Tech Lead to produce micro-task decomposition with exact file paths, specific changes, and verification steps
- MUST require IC5 and IC4 to follow TDD gate (RED → GREEN → REFACTOR) for changes that affect runtime behavior — exempt for pure config, docs, and metadata changes
- MUST require QA to have veto power over production releases
- MUST require DevOps to verify blast radius and have rollback plan before production actions
- MUST require IC4 to escalate to IC5/Tech Lead when task scope expands beyond original definition

### Memory Architecture
- MUST provide per-agent memory at `.claude/memory/<agent>/` with dual-mode storage (SQLite or .md fallback) — see SPEC-004 for storage details and line limits
- MUST keep context.md per-worktree (never migrated to SQLite)
- MUST load directives BEFORE memory at session start (directives → memory → context)
- The 7 behavioral agents MUST carry the memory protocol (path resolution / directives-load / tiered read / append-only write / search / line-limits) as a MANAGED-INLINE include region sourced from the canonical `skills/agent-memory/protocol.md` partial (between `<!-- include: skills/agent-memory/protocol.md agent=X -->` / `<!-- /include -->` markers), drift-checked byte-identical against the partial by `skills/agent-memory/sync-includes.py` at `/release`. Agents MUST NOT hand-maintain divergent copies — the block stays inline for portability (D2), single-sourced via the release-time check. See SPEC-004 (write) and SPEC-006 (read) for the protocol contracts.

### Agent-Spawn Templates (MC-4)
- Every agent-spawn prompt template in skills that dispatch agents MUST include the line `Output mode: terse` so spawned agents communicate in agent-to-agent terse mode (`/spec reflect` flags any spawn template missing it).

### Directives (adjust-agent)
- MUST support per-agent directives for exactly the 7 behavioral agents (pm, tech-lead, ic5, ic4, devops, qa, ds) per SPEC-001 — see SPEC-001 for the storage-path, numbered-list, surface-conflicts, holistic-rewrite, and standing-orders contract

### Collaboration
- MUST require IC5/IC4 to hand off to QA with testing notes after implementation
- MUST require DevOps to coordinate with QA for post-deployment smoke tests
- MUST require DS to work with PM to define measurable success criteria before features ship

## SHOULD

- SHOULD use RICE/MoSCoW/impact-effort for PM prioritization
- SHOULD have Tech Lead define interfaces before ICs implement in parallel
- SHOULD have IC5 spawn exploration subagents with max_turns: 15 and implementation subagents with max_turns: 30
- SHOULD have IC4 flag blockers quickly instead of spinning
- SHOULD have QA test failure modes and edge cases actively, not just happy paths
- SHOULD have DS include confidence intervals with point estimates

## Test

- Verify all 12 agent .md files have valid YAML frontmatter with `name`, `description`, `tools`, `model`, `effort`
- Verify every `model:` and `effort:` value matches the Tier table row for that agent
- Verify `finder` and `debugger` carry no memory directory, no cortex, and no memory-protocol include region
- Verify `finder` and `debugger` tools are exactly `Read, Grep, Glob, Bash, SendMessage`
- Verify directives load order: directives → memory → context
- Verify `/adjust-agent` surfaces conflicts and rewrites holistically with sequential numbering

## Validation

- [ ] Each agent .md has `name`, `description`, `tools`, `model`, `effort` in frontmatter
- [ ] All 12 Tier table rows match the shipped frontmatter exactly
- [ ] `finder` / `debugger` are read-only and memory-less
- [ ] Role boundaries are enforced in agent behavioral rules
- [ ] TDD gate exemption for config/docs is explicit in IC5 and IC4 agent definitions
- [ ] Directives file uses sequential numbering after holistic rewrite

## Open Questions

- [x] ~~Is the TDD gate mandatory for config/docs changes?~~ **Resolved: No** — TDD is mandatory for runtime behavior changes only. Pure config, docs, and metadata changes are exempt.
- [ ] Should IC4 use Opus instead of Sonnet for better reasoning on edge cases?

## Version History

| Date | Change |
|------|--------|
| 2026-08-30 | CDT-230: role split + full tier table. Added `finder` (fan-out investigation) and `debugger` (causal root-cause) as **non-behavioral roster agents** — memory-less, directive-less, read-only, precedent `council-judge`; the behavioral count stays exactly 7. `ic5` narrowed to pure senior implementation. Replaced the flat "Opus for tech-lead, ic5, qa, ds; Sonnet for pm, ic4, devops" tier MUST with a 12-row model+effort Tier table (`ic5` opus→sonnet/xhigh, `qa` opus→sonnet/high, `pm` sonnet→opus/medium, `ds` opus/medium). Added `effort` as a required frontmatter field — frontmatter is the only substrate that reaches a namespaced roster spawn (SPEC-037 F3/F6/F8). Host-reject fallback for `finder`/`debugger` is `ic5`. Status stays ACTIVE. |
| 2026-08-26 | CDT-222: shipped `model:` is the **Tier default**; runtime **Model map** is SPEC-037. Roster unchanged. |
| 2026-07-22 | CDT-52 / CDT-46-C6: human-reviewed promote INFERRED→ACTIVE; evidence: Linear CDT-52 ship comment + /spec check exit-0. |
| 2026-03-22 | Initial spec generated by /generate-specs |
| 2026-03-23 | Resolved TDD gate exemption. Removed duplicate line limits (now in SPEC-004 only). Clarified directive renumbering on rewrite. |
| 2026-06-13 | Added MC-4 MUST: every agent-spawn prompt template MUST include `Output mode: terse`. Added managed-inline include MUST: the 7 agents carry the memory protocol as a drift-checked include region (skills/agent-memory/protocol.md) and MUST NOT hand-maintain divergent copies (AUDIT-P1-1). |
| 2026-06-15 | Editorial de-duplication (AUDIT-P3.5b): trimmed the Directives subsection to a pointer at SPEC-001 (was restating SPEC-001's storage-path/numbered-list/surface-conflicts/holistic-rewrite/standing-orders contract verbatim); added SPEC-001 cross-reference. No behavioral change. |
| 2026-07-22 | CDT-53 reflect: spawn-template audit names `/spec reflect` (was `/reflect-specs`). Status stays ACTIVE. |

## Cross-references

- SPEC-001: Per-Agent Directives — owns the directives contract (storage path, numbered list, conflict surfacing, holistic rewrite, standing orders)
- SPEC-004: Memory Storage — dual-mode storage implementation, file line limits
- SPEC-005: Team Bootstrap — project-init writes cortex.md for all 7 agents
- SPEC-006: Memory Retrieval — tiered loading at session start
- SPEC-007: Memory Distillation — tier compression changes what agents see at session start
- SPEC-037: Per-agent Model map — local file + resolver may override the Agent `model` param at `/orchestrate` spawn; does not rewrite frontmatter
