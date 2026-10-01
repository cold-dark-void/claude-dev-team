---
phase_id: "{{PHASE_ID}}"
phase_n: {{PHASE_N}}
hunt_stem: "{{HUNT_STEM}}"
plan_path: "{{PLAN_PATH}}"
route: "{{ROUTE}}"
band: "{{BAND}}"
goal: "{{GOAL}}"
lock: "{{LOCK}}"
created_at: "{{CREATED_AT}}"
exit_metrics:
  closed_count_target: "{{CLOSED_COUNT_TARGET}}"
  residual_criticals: "{{RESIDUAL_CRITICALS}}"
  signoff: pending
---

# Phase handoff — {{PHASE_ID}} ({{BAND}})

## Variable contract

Fill each brace slot in the frontmatter and body once. This section has no brace slots.

| Slot | Source |
|------|--------|
| PHASE_ID | BH-PHASE-n |
| PHASE_N | integer n |
| HUNT_STEM | BH_STEM |
| PLAN_PATH | BH_PLAN |
| ROUTE | BH_ROUTE |
| BAND | critical, warning, or nitpick |
| ITEMS | table rows for this phase |
| ITEM_COUNT | item count |
| GOAL | close all phase items for this band |
| CLOSED_COUNT_TARGET | exit_metrics.closed_count_target |
| RESIDUAL_CRITICALS | exit_metrics.residual_criticals (0) |
| SIGNOFF | body mirror of exit_metrics.signoff |
| LOCK | AWAIT_USER until S4f |
| INVOCATION_HINT | print-only /orchestrate or /epic string |
| CREATED_AT | ISO-8601 UTC |

Emit-only handoff for severity band `{{BAND}}` (AC3 / M44). **MUST NOT** invoke
engines from this file — print `invocation_hint` only after M9 arm (AC9 / OQ10).

## Identity

| Field | Value |
|-------|-------|
| phase_id | `{{PHASE_ID}}` |
| hunt_stem | `{{HUNT_STEM}}` |
| plan_path | `{{PLAN_PATH}}` |
| route | `{{ROUTE}}` |
| band | `{{BAND}}` |
| item_count | {{ITEM_COUNT}} |

## Goal

{{GOAL}}

## Items

Phaseable backlog rows in this band (slug required; linear_id optional).

| backlog_slug | linear_id | finding_id | severity | locator |
|--------------|-----------|------------|----------|---------|
{{ITEMS}}

## Exit metrics

Downstream run contract (S4 does **not** wait for close — OQ9):

| Metric | Target |
|--------|--------|
| closed_count | {{CLOSED_COUNT_TARGET}} (== \|items\|) |
| residual_criticals | {{RESIDUAL_CRITICALS}} |
| signoff | {{SIGNOFF}} |

## Lock

{{LOCK}}

Arm forms (OQ5): `--start-phase {{PHASE_N}}` **or** typed `start-phase-{{PHASE_N}}`
(case-insensitive). Without lock: templates stay on disk; no auto-advance (M9).

## Invocation hint

**String only** — operator runs this after arm. Skill/orchestrator **MUST NOT**
spawn `/orchestrate` or `/epic`.

```
{{INVOCATION_HINT}}
```

---

<!-- Orchestrator fill notes (S4d):
  Path: $BH_HANDOFF_N[n] = $MROOT/.claude/bug-hunt/<stem>-handoff-phase-<n>.md

  Emit one file per entry in BH_PHASES[] (all phases at once — OQ4).
  Zero path (phase_count==0): emit **zero** handoff-phase files.

  Field sources (AC3 / AC6 / AC8):
    phase_id     = BH-PHASE-<n>
    hunt_stem    = BH_STEM
    plan_path    = BH_PLAN absolute
    route        = BH_ROUTE from S4c
    items[]      = phase.items — backlog_slug + linear_id (optional) + finding_id
    goal         = Close all phase items (severity=<band>) for hunt <stem>  (OQ8)
    exit_metrics.closed_count_target = |items|
    exit_metrics.residual_criticals  = 0
    exit_metrics.signoff             = pending  (S4f → recorded (flag|token @ ISO))
    lock         = AWAIT_USER start-phase-<n>   (S4f → armed @ ISO)
    invocation_hint:
      if route=/epic:    /epic <ISSUE-ID>          # first linear_id or slug guidance
      else:              /orchestrate <ISSUE-ID>  # string only

  ITEMS — one table row per phase item (plan-table order within band):
    | <backlog_slug> | <linear_id or (none)> | <finding_id> | <severity> | <locator> |
    Escape bare | in cells as \| .

  Write with the Write tool only — MUST NOT bash heredoc with ! (skill-lint C2).
  MUST NOT git add / commit (process artifact; .gitignore .claude/bug-hunt/).
  MUST NOT invoke /orchestrate or /epic (emit-only AC9).
-->
