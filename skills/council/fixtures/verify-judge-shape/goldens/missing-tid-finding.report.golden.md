---
scope: "diff"
preset: "diff-mode"
output_shape: "finding[]"
created_at: "<TIMESTAMP>"
verification_mode: "full"
council_tier: "full"
concurrency: "unbounded"
grading_reason: "fixture: CDT-178 missing tool_use_id strike"
task_id: "T-178"
---

# Council Code Review Report

## Summary


This report documents a diff-mode council run (preset `diff-mode`) against
the scope `diff` at council tier `full`. The specialist
investigators for this run (`logic, security, compliance, quality, simplification`)
gathered raw tool-call evidence; the
Council Judge deduplicated and cross-checked citations, striking findings
without `tool_use_id` backing. Commit gate status: **PASSED**.
See Findings for per-finding detail and Audit Trail for struck items.

---

## Severity Summary

| Severity | Count |
|---|---|
| critical | 0 |
| warning | 1 |
| nitpick | 0 |

---

## Commit Gate

**PASSED**

The commit gate is BLOCKED when any finding with severity `critical` or a
compliance violation exists. It is PASSED when only warnings and nitpicks
remain (or the diff is clean). The user must resolve all blocking findings
before committing.

---

## Diff Under Review

_Not available._

---

## Applicable Specs

Specs taken from the plan field applicable_specs. When the plan omits that
field, this section stays none-matched. Spec-grep is the orchestrator's job.
This report does not claim a grep ran.

_None matched._

---

## Cross-Review

Phase 2.5: Phase 2.5 not run

### Per-Reviewer Rankings

Each row is one cross-reviewer (the investigator who submitted that row's
bundle is excluded from their own evaluation). Labels A/B/C are the
anonymized bundle identifiers presented to that reviewer; order within
each row is best-first.

_Phase 2.5 not run — no cross-review rankings._

### Borda Scores

Borda count aggregated across all cross-reviewers. For N bundles, a
rank-1 vote = N−1 points, rank-2 = N−2, …, rank-N = 0. Bundles in the
bottom quartile are flagged WEAK_EVIDENCE and passed to Phase 4/5 with
that flag set.

_Phase 2.5 not run — no Borda scores._

---

## Evidence Bundles

Raw tool-call evidence collected by investigators. Each bundle contains a
`tool_use_id` and the raw output blob.

### `external:codex:deadbeef` — skills/council/engine.sh:945

```
valid external bundle body
```

Reproducible: `rg tool_use_id skills/council/engine.sh`

### `tu-valid` — skills/council/engine.sh:1026

```
valid native tool_use_id bundle
```

Reproducible: `sed -n '1020,1035p' skills/council/engine.sh`

### `unknown` — skills/council/engine.sh:1

```
literal unknown is a valid tid — must not strike
```

Reproducible: `true`


---

## Prosecutor Brief

_Phase 4 skipped, reason: finding[]-shape preset — no brief was produced and none was synthesized._

---

## Devil's Advocate Brief

_Phase 4 skipped, reason: finding[]-shape preset — no brief was produced and none was synthesized._

---

## Findings

Per-finding records from the Council Judge (Phase 5, diff-mode). Each entry
includes `file:line`, category (from the specialist flavor), description,
suggestion, confidence score (0–100), and the `tool_use_id` citing the
Read/Grep that observed the cited location. Findings below the plan
confidence filter were struck at emission (diff-mode threshold 80). The
engine emits one severity heading per unstruck finding, in judge order, so
each finding carries its own severity inline and no static severity
subheadings are needed here.

### [WARNING] skills/council/engine.sh:945 (correctness)

valid high-conf warning with tool_use_id — must remain unstruck

**Suggestion:** keep packaging strike for blank tids only

Confidence: 85/100 | tool_use_id: `external:codex:deadbeef`


---

## Action Items

- [ ] DESIGN `skills/council/engine.sh:945` — valid high-conf warning with tool_use_id — must remain unstruck — keep packaging strike for blank tids only [confidence: 85]

---

## Audit Trail — Struck Findings

Every finding struck for missing `tool_use_id`, unsupported citation, or
severity outside the fixed taxonomy is listed here. This section is always
present.

- judge pre-strike
- evidence bundle missing tool_use_id (file_line=skills/council/engine.sh:2)
- evidence bundle missing tool_use_id (file_line=skills/council/engine.sh:3)
- evidence bundle missing tool_use_id (file_line=skills/council/engine.sh:4)
- finding missing tool_use_id (file=skills/council/engine.sh line=2)
- finding missing tool_use_id (file=skills/council/engine.sh line=3)
- finding missing tool_use_id (file=skills/council/engine.sh line=4)

---

## Run Metadata

| Field | Value |
|---|---|
| Completion time | 0s |
| Council tier | `full` |
| Investigator flavors | `logic, security, compliance, quality, simplification` |
| Phase 3 (domain specialist) | ELIGIBLE (runtime classify) |
| Report shape | `finding[]` |
| Confidence filter | ≥80 (diff-mode) |
| Engine | `skills/council/engine.sh` |
| Spec | `specs/core/SPEC-013-adversarial-council-tribunal.md` |
