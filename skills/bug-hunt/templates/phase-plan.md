---
hunt_stem: "{{HUNT_STEM}}"
plan_path: "{{PLAN_PATH}}"
route: "{{ROUTE}}"
phase_count: {{PHASE_COUNT}}
item_count: {{ITEM_COUNT}}
created_at: "{{CREATED_AT}}"
armed_phase: "{{ARMED_PHASE}}"
---

# Phase plan — {{HUNT_STEM}}

## Variable contract

Fill each brace slot in the frontmatter and body once. This section has no brace slots.

| Slot | Source |
|------|--------|
| HUNT_STEM | BH_STEM |
| PLAN_PATH | BH_PLAN (findings plan, not this phase-plan) |
| ROUTE | BH_ROUTE (`/orchestrate` or `/epic`) |
| PHASE_COUNT | BH_PHASE_COUNT |
| ITEM_COUNT | BH_ITEM_COUNT |
| CREATED_AT | ISO-8601 UTC |
| PHASE_INDEX | one table row per phase, or the zero-state note |
| ARMED_PHASE | none at emit; `n` after S4f |

Severity-banded phase index for stage-4 handoff (AC2 / AC8 / M44). Emit-only —
locks gate **arming**, not this write (OQ4). Route is the same for all phases
(S4c / M45).

## Phases

| n | phase_id | band | item_count | handoff_path | route | arm |
|---|----------|------|------------|--------------|-------|-----|
{{PHASE_INDEX}}

## Resume

- Findings plan: `{{PLAN_PATH}}`
- Phase plan: `$MROOT/.claude/bug-hunt/{{HUNT_STEM}}-phase-plan.md`
- Arm phase n: `/bug-hunt handoff {{PLAN_PATH}} --start-phase <n>`
  or typed `start-phase-<n>` (case-insensitive)

---

<!-- Orchestrator fill notes (S4d). Slot names are in the variable contract.
  Path: $BH_PHASE_PLAN = $MROOT/.claude/bug-hunt/<stem>-phase-plan.md
  ROUTE from S4c: /epic when phase_count≥2 and item_count≥2; else /orchestrate.
  ARMED_PHASE at emit is none. PHASE_INDEX is one row per phase; arm cell is AWAIT_USER.
  Zero path still writes this file and emits no handoff-phase files. Body note: (none — 0 phaseable).
  Write with the Write tool only. Do not git add. Do not invoke /orchestrate or /epic.
-->
