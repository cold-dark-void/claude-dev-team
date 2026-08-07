[//]: # "Variable contract — orchestrator fills via Write tool (no bash heredoc with !)"
[//]: # "{{HUNT_STEM}}             — BH_STEM = <YYYY-MM-DD>-<slug>"
[//]: # "{{PLAN_PATH}}             — BH_PLAN absolute path (…-plan.md)"
[//]: # "{{ROUTE}}                 — BH_ROUTE: /orchestrate | /epic (S4c)"
[//]: # "{{PHASE_COUNT}}           — BH_PHASE_COUNT (non-empty bands after omit)"
[//]: # "{{ITEM_COUNT}}            — BH_ITEM_COUNT (|BH_PHASEABLE|)"
[//]: # "{{CREATED_AT}}            — ISO-8601 UTC timestamp at phase-plan write"
[//]: # "{{PHASE_INDEX}}           — markdown table rows for each phase 0..N; or zero-state note"
[//]: # "{{ARMED_PHASE}}           — none | <n> (S4e/S4f; pending at S4d emit)"

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

<!-- Orchestrator fill notes (S4d):
  Path: $BH_PHASE_PLAN = $MROOT/.claude/bug-hunt/<stem>-phase-plan.md

  {{ROUTE}} at S4d:
    from S4c: /epic iff phase_count≥2 AND item_count≥2; else /orchestrate.
    When phase_count==0 (zero path): use /orchestrate (default; no engines).

  {{ARMED_PHASE}} at S4d emit:
    always `none` (S4e/S4f rewrite to <n> after lock arm).

  {{PHASE_INDEX}} — one markdown table row per BH_PHASES[] entry (n = 0..N):
    | <n> | BH-PHASE-<n> | <band> | < |items| > | <stem>-handoff-phase-<n>.md | {{ROUTE}} | AWAIT_USER |
    handoff_path = basename only or absolute under $BH_REPORT_DIR (prefer basename).
    arm cell at emit: AWAIT_USER  (S4f → armed @ ISO).

  When BH_PHASE_COUNT == 0 (AC11 zero path):
    Still write this phase-plan (resume identity AC8).
    {{PHASE_COUNT}}=0 {{ITEM_COUNT}}=0 {{PHASE_INDEX}} body:
      (none — 0 phaseable)
    MUST NOT emit any *-handoff-phase-*.md files.

  Write with the Write tool only — MUST NOT bash heredoc with ! (skill-lint C2).
  MUST NOT git add / commit (process artifact; .gitignore .claude/bug-hunt/).
  MUST NOT invoke /orchestrate or /epic (emit-only AC9).
-->
