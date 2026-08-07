[//]: # "Variable contract — orchestrator fills via Write tool (no bash heredoc with !)"
[//]: # "{{HUNT_STEM}}             — BH_STEM = <YYYY-MM-DD>-<slug>"
[//]: # "{{REPORT_PATH}}           — BH_REPORT absolute path (or sibling .md)"
[//]: # "{{FINDINGS_JSON_PATH}}    — BH_FINDINGS absolute path, or 'not written'"
[//]: # "{{FLOOR}}                 — BH_FLOOR (critical|warning|nitpick)"
[//]: # "{{CREATED_AT}}            — ISO-8601 UTC timestamp at plan write"
[//]: # "{{PROCEED}}               — pending | recorded (flag @ ISO) | recorded (token @ ISO)"
[//]: # "{{ACTIONABLE_TABLE}}      — markdown table rows for BH_ACTIONABLE[]; or empty-table note"
[//]: # "{{COUNT_A}}               — |BH_ACTIONABLE| (BH_MAT_A)"
[//]: # "{{COUNT_M}}               — materialized count (BH_MAT_M; 0 pre-S3e)"
[//]: # "{{COUNT_S}}               — skipped_linked count (BH_MAT_S; 0 pre-S3e)"
[//]: # "{{COUNT_F}}               — failed count (BH_MAT_F; 0 pre-S3e)"
[//]: # "{{PHASE_DONE}}            — S3g M22 block after materialize; else '(pending S3g)'"
[//]: # "{{EVIDENCE_SECTIONS}}     — optional full evidence bodies when table truncates; else empty"

---
hunt_stem: "{{HUNT_STEM}}"
report_path: "{{REPORT_PATH}}"
findings_json_path: "{{FINDINGS_JSON_PATH}}"
severity_floor: "{{FLOOR}}"
created_at: "{{CREATED_AT}}"
proceed: "{{PROCEED}}"
---

# Findings plan — {{HUNT_STEM}}

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

<!-- Orchestrator fill notes (S3c):
  Path: $BH_PLAN = $MROOT/.claude/bug-hunt/<YYYY-MM-DD>-<slug>-plan.md  (exact -plan.md)

  {{PROCEED}} at S3c write:
    always `pending` on first write (S3d rewrites to recorded (…) after lock).

  {{ACTIONABLE_TABLE}} — one markdown table row per BH_ACTIONABLE item:
    | <id> | <severity> | <locator> | <description> | <evidence> | (pending) | (pending) | planned |
    Escape bare `|` inside cells as `\|` or replace with `/`.
    Evidence: full substance preferred; if truncated for table width, put full
    text under ## Evidence detail ({{EVIDENCE_SECTIONS}}) — never empty when
    materializing later (AC6).

  When BH_MAT_A == 0 (AC10):
    {{ACTIONABLE_TABLE}} = single note row or leave body as:
      | — | — | — | (none) | — | (pending) | (pending) | planned |
    Prefer a paragraph under the table header instead when empty:
      (none — 0 confirmed-actionable)
    Still write the plan (resume identity). Counts all 0.

  {{PHASE_DONE}} at S3c:
    `(pending S3g)` — S3g / T4 overwrites with exact M22 block.

  {{EVIDENCE_SECTIONS}} when needed:
    ## Evidence detail
    ### <finding_id>
    <full evidence text>
    else empty string (omit heading).

  Write with the Write tool only — MUST NOT bash heredoc with `!` (skill-lint C2).
  MUST NOT git add / commit (process artifact; .gitignore .claude/bug-hunt/).

  Status enum after materialize (S3f / T4):
    planned | materialized | skipped_linked | failed
-->
