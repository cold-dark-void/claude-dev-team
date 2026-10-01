---
hunt_stem: "{{HUNT_STEM}}"
report_path: "{{REPORT_PATH}}"
findings_json_path: "{{FINDINGS_JSON_PATH}}"
severity_floor: "{{FLOOR}}"
created_at: "{{CREATED_AT}}"
proceed: "{{PROCEED}}"
---

# Findings plan — {{HUNT_STEM}}

## Variable contract

Fill each brace slot in the frontmatter and body once. This section has no brace slots.

| Slot | Source |
|------|--------|
| HUNT_STEM | BH_STEM (`YYYY-MM-DD-slug`) |
| REPORT_PATH | BH_REPORT |
| FINDINGS_JSON_PATH | BH_FINDINGS, or not written |
| FLOOR | BH_FLOOR |
| CREATED_AT | ISO-8601 UTC at plan write |
| PROCEED | pending, or recorded (flag or token at ISO) |
| ACTIONABLE_TABLE | rows for BH_ACTIONABLE, or the empty note |
| COUNT_A | count of BH_ACTIONABLE |
| COUNT_M | materialized count (0 before S3e) |
| COUNT_S | skipped_linked count (0 before S3e) |
| COUNT_F | failed count (0 before S3e) |
| PHASE_DONE | S3g M22 block, or pending S3g |
| EVIDENCE_SECTIONS | full evidence bodies, or empty |

Reviewable stage-3 plan (AC3 / M39). Plan write is allowed **before** M8 proceed;
backlog create (S3e) only after `--proceed` or typed `proceed` (AC4).

## Actionable

Findings with `status=confirmed` **and** severity ≥ floor (AC2 / AC8). Columns
`backlog_slug` / `linear_id` stay `(pending)` until S3e–S3f; pre-proceed
`status` is `planned`.

| finding_id | severity | locator | description | evidence | backlog_slug | linear_id | status |
|------------|----------|---------|-------------|----------|--------------|-----------|--------|
{{ACTIONABLE_TABLE}}

## Counts

- actionable: {{COUNT_A}}
- materialized: {{COUNT_M}}
- skipped_linked: {{COUNT_S}}
- failed: {{COUNT_F}}

## Phase-done

{{PHASE_DONE}}

{{EVIDENCE_SECTIONS}}

---

<!-- Orchestrator fill notes (S3c). Slot names are in the variable contract, not repeated here.
  Path: $BH_PLAN = $MROOT/.claude/bug-hunt/<YYYY-MM-DD>-<slug>-plan.md  (exact -plan.md)
  PROCEED at first write is pending. S3d rewrites it after the lock.
  ACTIONABLE_TABLE is one row per BH_ACTIONABLE item. Empty hunt: `(none — 0 confirmed-actionable)`.
  PHASE_DONE at S3c is `(pending S3g)`.
  Write with the Write tool only. Do not git add. Status after materialize:
  planned, materialized, skipped_linked, or failed.
-->
