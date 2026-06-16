[//]: # "Variable contract — engine.sh (finalize) substitutes these via {{VAR}} placeholders"
[//]: # "{{TASK_ID}}               — task id, present in frontmatter only when run is task-bound"
[//]: # "{{SCOPE}}                 — e.g. 'diff', 'diff-staged'"
[//]: # "{{PRESET}}                — e.g. 'diff-mode'"
[//]: # "{{TIMESTAMP}}             — ISO-8601 UTC timestamp of report creation"
[//]: # "{{DIFF_SUMMARY}}          — paths and line counts of the diff under review"
[//]: # "{{APPLICABLE_SPECS}}      — list of spec files matched by spec-grep intake"
[//]: # "{{INVESTIGATOR_FLAVORS}}  — comma-separated list of flavor ids used"
[//]: # "{{CROSS_REVIEW_STATUS}}   — 'RAN' or 'BYPASSED (reason: <text>)'"
[//]: # "{{CROSS_REVIEW_RANKINGS}} — per-reviewer ranking table (anonymized labels A/B/C)"
[//]: # "{{CROSS_REVIEW_SCORES}}   — Borda score table: bundle identity, score, WEAK_EVIDENCE flag"
[//]: # "{{FINDINGS}}              — per-finding records grouped by severity"
[//]: # "{{STRUCK_FINDINGS}}       — findings struck for missing tool_use_id or unsupported citation"
[//]: # "{{SEVERITY_SUMMARY_TABLE}} — counts by severity: critical / warning / nitpick"
[//]: # "{{COMMIT_GATE_STATUS}}    — BLOCKED if any critical/compliance finding, else PASSED"
[//]: # "{{ACTION_ITEMS}}          — checklist by severity (BLOCKERs first, then DESIGN, then NITPICK)"
[//]: # "{{COMPLETION_TIME}}       — wall-clock duration of the full council run"

# Council Code Review Report

## Summary

This report documents a diff-mode council run (preset `{{PRESET}}`) against
the scope `{{SCOPE}}`. Five specialist investigators (logic, security,
compliance, quality, simplification) gathered raw tool-call evidence; the
Council Judge deduplicated and cross-checked citations, striking findings
without `tool_use_id` backing. Commit gate status: **{{COMMIT_GATE_STATUS}}**.
See Findings for per-finding detail and Audit Trail for struck items.

---

## Severity Summary

{{SEVERITY_SUMMARY_TABLE}}

---

## Commit Gate

**{{COMMIT_GATE_STATUS}}**

The commit gate is BLOCKED when any finding with severity `critical` or a
compliance violation exists. It is PASSED when only warnings and nitpicks
remain (or the diff is clean). The user must resolve all blocking findings
before committing.

---

## Diff Under Review

{{DIFF_SUMMARY}}

---

## Applicable Specs

Spec files matched by spec-grep over the changed file paths. Each matched
MUST requirement was provided to investigators as context during Phase 1
enrichment and Phase 2 investigation.

{{APPLICABLE_SPECS}}

---

## Cross-Review

Phase 2.5: {{CROSS_REVIEW_STATUS}}

### Per-Reviewer Rankings

Each row is one cross-reviewer (the investigator who submitted that row's
bundle is excluded from their own evaluation). Labels A/B/C are the
anonymized bundle identifiers presented to that reviewer; order within
each row is best-first.

{{CROSS_REVIEW_RANKINGS}}

### Borda Scores

Borda count aggregated across all cross-reviewers. For N bundles, a
rank-1 vote = N−1 points, rank-2 = N−2, …, rank-N = 0. Bundles in the
bottom quartile are flagged WEAK_EVIDENCE and passed to Phase 4/5 with
that flag set.

{{CROSS_REVIEW_SCORES}}

---

## Findings

Per-finding records from the Council Judge (Phase 5, diff-mode). Each entry
includes `file:line`, category (from the specialist flavor), description,
suggestion, confidence score (0–100), and the `tool_use_id` citing the
Read/Grep that observed the cited location. Findings below confidence 80 were
filtered at emission (per SPEC-013's "diff-mode findings filter <80 at emission"). `engine.sh`
emits one `### [SEVERITY] file:line (category)` heading per finding into
`{{FINDINGS}}` (in the order the judge returned them), so each finding carries
its own severity inline and no static severity subheadings are needed here.

{{FINDINGS}}

---

## Action Items

{{ACTION_ITEMS}}

---

## Audit Trail — Struck Findings

Every finding struck for missing `tool_use_id`, unsupported citation, or
severity outside the fixed taxonomy is listed here. This section is always
present.

{{STRUCK_FINDINGS}}

---

## Run Metadata

| Field | Value |
|---|---|
| Completion time | {{COMPLETION_TIME}} |
| Report shape | `finding[]` |
| Confidence filter | ≥80 (diff-mode) |
| Engine | `skills/council/engine.sh` |
| Spec | `specs/core/SPEC-013-adversarial-council-tribunal.md` |
