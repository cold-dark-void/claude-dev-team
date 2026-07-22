# SPEC-003: Agent Role System

**Status**: ACTIVE
**Category**: core
**Created**: 2026-03-22

**Covers**: `agents/pm.md`, `agents/tech-lead.md`, `agents/ic5.md`, `agents/ic4.md`, `agents/devops.md`, `agents/qa.md`, `agents/ds.md`, `commands/adjust-agent.md`

## Overview

The core concept of the plugin: a FAANG-style team of 7 specialized AI agents with distinct roles, responsibilities, model assignments, and tool access. Each agent has YAML frontmatter (name, description, tools, model), behavioral rules encoded in markdown, and a per-agent memory architecture. Behavioral directives provide persistent standing orders that agents cannot override.

## MUST

### Agent Identity
- MUST define exactly 7 behavioral agents: pm, tech-lead, ic5, ic4, devops, qa, ds
- MUST require YAML frontmatter with `name`, `description`, `tools`, and `model` fields on all agent definitions
- MUST assign model tiers: Opus for tech-lead, ic5, qa, ds; Sonnet for pm, ic4, devops

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
- Every agent-spawn prompt template in skills that dispatch agents MUST include the line `Output mode: terse` so spawned agents communicate in agent-to-agent terse mode (`/reflect-specs` flags any spawn template missing it).

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

- Verify all 7 agent .md files have valid YAML frontmatter with required fields
- Verify model assignments match spec (Opus: tech-lead, ic5, qa, ds; Sonnet: pm, ic4, devops)
- Verify directives load order: directives → memory → context
- Verify `/adjust-agent` surfaces conflicts and rewrites holistically with sequential numbering

## Validation

- [ ] Each agent .md has `name`, `description`, `tools`, `model` in frontmatter
- [ ] Role boundaries are enforced in agent behavioral rules
- [ ] TDD gate exemption for config/docs is explicit in IC5 and IC4 agent definitions
- [ ] Directives file uses sequential numbering after holistic rewrite

## Open Questions

- [x] ~~Is the TDD gate mandatory for config/docs changes?~~ **Resolved: No** — TDD is mandatory for runtime behavior changes only. Pure config, docs, and metadata changes are exempt.
- [ ] Should IC4 use Opus instead of Sonnet for better reasoning on edge cases?

## Version History

| Date | Change |
|------|--------|
| 2026-07-22 | CDT-52 / CDT-46-C6: human-reviewed promote INFERRED→ACTIVE; evidence: Linear CDT-52 ship comment + /spec check exit-0. |
| 2026-03-22 | Initial spec generated by /generate-specs |
| 2026-03-23 | Resolved TDD gate exemption. Removed duplicate line limits (now in SPEC-004 only). Clarified directive renumbering on rewrite. |
| 2026-06-13 | Added MC-4 MUST: every agent-spawn prompt template MUST include `Output mode: terse`. Added managed-inline include MUST: the 7 agents carry the memory protocol as a drift-checked include region (skills/agent-memory/protocol.md) and MUST NOT hand-maintain divergent copies (AUDIT-P1-1). |
| 2026-06-15 | Editorial de-duplication (AUDIT-P3.5b): trimmed the Directives subsection to a pointer at SPEC-001 (was restating SPEC-001's storage-path/numbered-list/surface-conflicts/holistic-rewrite/standing-orders contract verbatim); added SPEC-001 cross-reference. No behavioral change. |

## Cross-references

- SPEC-001: Per-Agent Directives — owns the directives contract (storage path, numbered list, conflict surfacing, holistic rewrite, standing orders)
- SPEC-004: Memory Storage — dual-mode storage implementation, file line limits
- SPEC-005: Team Bootstrap — project-init writes cortex.md for all 7 agents
- SPEC-006: Memory Retrieval — tiered loading at session start
- SPEC-007: Memory Distillation — tier compression changes what agents see at session start
