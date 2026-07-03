# Promote the p0-fix-workflow into the plugin as /fix-ticket

**Status**: PENDING

## Problem

The premise→implement→adversarial-refuters Workflow script (`.claude/p0-fix-workflow.js`) proved itself across ~40 consolidation-audit tickets — refuters and orchestrator review repeatedly caught fixes the audit itself got wrong — but it lives as an untracked project-local file, invisible to plugin consumers and to other projects.

## Goal

Ship the workflow as a first-class plugin capability (e.g. `/fix-ticket <id> "<premise>"`): premise verification (ic5) → implementation (ic4/ic5, worktree-isolated) → N adversarial refuters (qa) → orchestrator review, with the caller doing release mechanics.

## Implementation Notes

- Fix the known gotcha: Workflow `args` may arrive as a JSON **string** — guard with `typeof args==='string' ? JSON.parse(args) : args`.
- Bake into refuter prompts: revert bite-test injections via cp-from-backup or sed-reverse, NEVER `git checkout` (wipes uncommitted sibling work).
- Include the rate-limit fallback: when refuter spawns fail, orchestrator runs the adversarial checks itself and marks the result "self-verified".
- Decide surface: `skills/` workflow asset invoked by a thin command, mirroring council's engine/command split.

## Affects

New `skills/fix-ticket/` (or similar), README roster/command index, docs/.

## Effort

M

## Notes

Source: 2026-07-03 ideation session (idea #2). Empirical basis: AUDIT-P0/P1/P2P3P4 arcs — 6+ tickets where the audit-named fix was insufficient and verification caught it.

---

*Added: 2026-07-03*
