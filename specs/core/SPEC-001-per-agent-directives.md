# SPEC-001: Per-Agent Directives

**Status**: ACTIVE — implemented in v0.15.0
**Category**: core
**Created**: 2026-03-16
**Ticket**: DIR-001

**Covers**: `commands/adjust-agent.md`, `agents/*.md` (directives loading block)

## Overview

Persistent behavioral instructions for individual agents — project-specific standing orders that survive across sessions, load before any memory, and cannot be overridden by the agent's own reasoning. Managed via `/adjust-agent` command. Follows the Asimov model: directives are non-negotiable, zero-impact when absent, minimal footprint (~3 lines per agent), and user-owned as plain numbered lists.

## MUST

### Directives File
- MUST store per-agent directives at `.claude/memory/<agent>/directives.md` where `<agent>` is one of: `pm`, `tech-lead`, `ic5`, `ic4`, `devops`, `qa`, `ds`
- MUST NOT load directives for `project-init` or `distiller` agents (internal-only, no user behavioral overrides)
- MUST have zero impact when `directives.md` does not exist — no errors, no warnings, no placeholder output
- MUST use numbered list format, one directive per line (e.g., `1. Always write specs in Gherkin format`)
- MUST NOT commit `directives.md` files to git (covered by `.gitignore` patterns under `.claude/memory/`)

### Agent Loading Protocol
- MUST load directives BEFORE memory during session start — load order: (1) directives, (2) memory, (3) context
- MUST frame directives as "standing orders for this project" that take priority over agent reasoning and memory
- MUST NOT error when the file is absent or empty — use `cat ... 2>/dev/null` or equivalent silent fallback
- MUST use ~3 lines of bash for loading, consistent across all 7 agents — placed after path resolution, before memory loading
- MUST NOT allow agent to override directives via its own reasoning — framing and load-first positioning are the enforcement mechanisms

### /adjust-agent Command
- MUST display dashboard (all 7 agents + directive counts) when invoked with no arguments
- MUST display read-only directive list when invoked with agent name only — MUST NOT prompt for input
- MUST trigger conversational adjustment flow when invoked with agent name + prompt: read existing → interpret → detect conflicts → holistic rewrite → show final state
- MUST accept any agent name string but MUST warn if no matching agent `.md` file exists in `agents/` (forward-compatible, typo-safe)
- MUST detect conflicts between new intent and existing directives interactively — MUST NOT silently resolve conflicts
- MUST rewrite entire `directives.md` holistically on each adjustment (never append) — all directives re-evaluated as coherent set
- MUST display final directive list after writing so user can verify
- MUST create `directives.md` file and parent directory if they do not exist
- MUST be idempotent: same prompt on same state produces same result (no duplicates, no drift)
- MUST support a non-interactive `--apply` flag: `/adjust-agent <agent> --apply <prompt>` skips user prompting and applies the adjustment directly — but on conflict detection MUST refuse the write and exit with a clear error (fail-fast, never silently resolve). Enables automation callers (e.g. `/retro --auto`) to request directive updates without bypassing conflict safety.

### /init-team Integration
- MUST output hint about `/adjust-agent` after init-team completes bootstrap

### .gitignore Coverage
- MUST ensure `.gitignore` covers `directives.md` files (verify existing `.claude/memory/` patterns are sufficient; add explicit entry if not)
- MUST check coverage in `/init-team` and in `/adjust-agent` when creating a new directives file

## SHOULD

- SHOULD compute directive count via `grep -c '^[0-9]'` for dashboard display

## Test

- Verify directives load before memory in all 7 agent session-start sequences
- Verify absent directives file causes no errors or output
- Verify `/adjust-agent` dashboard shows correct counts for all 7 agents
- Verify `/adjust-agent <agent>` read-only mode does not prompt for input
- Verify `/adjust-agent <agent> <prompt>` detects conflicts and surfaces them
- Verify holistic rewrite produces no duplicates on repeated invocation
- Verify `project-init` and `distiller` agents do not load directives

## Validation

- [ ] All 7 agent `.md` files contain directives loading block after path resolution
- [ ] `project-init.md` and `distiller.md` do NOT contain directives loading block
- [ ] `/adjust-agent` with no args shows 7-row dashboard
- [ ] `/adjust-agent pm "use Gherkin"` creates/updates `.claude/memory/pm/directives.md`
- [ ] Running same adjustment twice produces identical file content (idempotent)
- [ ] Deleting `directives.md` causes zero errors on next agent session start

## Open Questions

None — all ACs confirmed by user.

## Out of Scope

- Directive inheritance (global directives for all agents)
- Directive versioning or history
- Directive validation against agent capabilities
- Remote/shared directive storage
- Programmatic directive API beyond `/adjust-agent`

## Version History

| Date | Change |
|------|--------|
| 2026-03-16 | Initial spec drafted by tech-lead for DIR-001 |
| 2026-03-16 | Implemented and shipped in v0.15.0 |
| 2026-03-23 | Reformatted for /reflect-specs compliance: added Category, Created, Covers, Overview, Test, Validation, Version History sections. Consolidated section-based requirements into bulleted MUST format. Status updated from Draft to ACTIVE. |
| 2026-04-08 | Added `--apply` non-interactive mode MUST to enable automation callers (RETRO-001 / SPEC-012). Fail-fast on conflict preserves existing conflict-detection guarantee. |

## Cross-references

- SPEC-003: Agent Role System — 7 behavioral agents, directives in memory architecture
- SPEC-005: Team Bootstrap — init-team outputs /adjust-agent hint
