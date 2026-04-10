[//]: # "Variable contract — engine.sh (finalize) substitutes these via {{VAR}} placeholders"
[//]: # "{{TASK_ID}}               — task id, present in frontmatter only when run is task-bound"
[//]: # "{{SCOPE}}                 — e.g. 'diff', 'diff-staged'"
[//]: # "{{PRESET}}                — e.g. 'diff-mode'"
[//]: # "{{TIMESTAMP}}             — ISO-8601 UTC timestamp of report creation"
[//]: # "{{DIFF_SUMMARY}}          — paths and line counts of the diff under review"
[//]: # "{{APPLICABLE_SPECS}}      — list of spec files matched by spec-grep intake"
[//]: # "{{INVESTIGATOR_FLAVORS}}  — comma-separated list of flavor ids used"
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

| Severity | Count |
|---|---|
| critical | — |
| warning | — |
| nitpick | — |

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

## Findings

Per-finding records from the Council Judge (Phase 5, diff-mode). Grouped by
severity: Critical first, then Warning, then Nitpick. Each entry includes
`file:line`, category (from the specialist flavor), description, suggestion,
confidence score (0–100), and the `tool_use_id` citing the Read/Grep that
observed the cited location. Findings below confidence 80 were filtered at
emission (diff-mode threshold per SPEC-013 line 44).

### Critical Issues (Must Fix) [confidence 95–100]

{{FINDINGS}}

### Warnings [confidence 80–94]

_See findings above._

### Nitpicks [confidence 80–94]

_See findings above._

---

## Action Items

{{ACTION_ITEMS}}

```
Action Items: N BLOCKERs, M DESIGN, K NITPICK — [commit blocked | commit proceeded]
```

- [ ] BLOCKER `file:line` — what is wrong — exactly what to do [confidence: N]
- [ ] DESIGN  `file:line` — what is wrong — exactly what to do [confidence: N]
- [ ] NITPICK `file:line` — what is wrong — exactly what to do [confidence: N]

---

## Audit Trail — Struck Findings

Every finding struck for missing `tool_use_id`, unsupported citation, or
severity outside the fixed taxonomy is listed here. This section is always
present.

{{STRUCK_FINDINGS}}

No findings struck.

---

## Run Metadata

| Field | Value |
|---|---|
| Completion time | {{COMPLETION_TIME}} |
| Report shape | `finding[]` |
| Confidence filter | ≥80 (diff-mode) |
| Engine | `skills/council/engine.sh` |
| Spec | `specs/core/SPEC-013-adversarial-council-tribunal.md` |
