---
scope: "claim"
preset: "generic"
output_shape: "verdict[]"
created_at: "<TIMESTAMP>"
verification_mode: "full"
council_tier: "full"
concurrency: "unbounded"
grading_reason: "fixture: CDT-589-C4 AC7(c) M14 ship-gate control (scope=claim, ac_source, no [forward] tag)"
---

# Council Verdict Report

## Summary


This report documents an adversarial council tribunal run against the scope
`claim` using preset `generic` at council tier `full`.
Investigators gathered raw tool-call evidence for each extracted claim; when
Phase 4 ran, a Prosecutor and Devil's Advocate wrote adversarial briefs over
that evidence (the Prosecutor Brief and Devil's Advocate Brief sections below
record this run's status); the Council Judge — structurally
forbidden from running tools — issued verdicts from the fixed taxonomy.
See the Verdicts section for per-claim outcomes and the Audit Trail for any
lines struck for missing or unsupported evidence.

---

## Verdict Summary

| Taxonomy | Count |
|---|---|
| VERIFIED | 0 |
| PARTIALLY_VERIFIED | 0 |
| UNVERIFIED | 0 |
| CONTRADICTED | 1 |
| FABRICATED | 0 |

---

## Scope & Configuration

| Field | Value |
|---|---|
| Scope | `claim` |
| Preset | `generic` |
| Council tier | `full` |
| Investigator flavors | `paranoid-ic` |
| Phase 3 (domain specialist) | ELIGIBLE (runtime classify) |
| Claim budget | 16 |
| Claims audited | 1 |
| Timestamp | `<TIMESTAMP>` |

---

## Extracted Claims

Claims extracted from the subject during Phase 1. Each carries a source
locator (turn ID or file:line) and claim type (factual / causal /
recommendation). When the budget was exceeded, claims were ranked by
load-bearing weight; un-audited claims are listed below the budget cap note.

1. **factual** — c0: [AC-A] Step 3 adds flag --fwd-demo to skills/council/engine.sh (source: specs/core/SPEC-FIX.md:12)

---

## Evidence Bundles

Raw tool-call evidence collected by blind investigators (Phase 2). Each
bundle contains a `tool_use_id`, the raw output blob (not paraphrased), a
`file:line` citation, and a reproducible command. Bundles missing a
`tool_use_id` were rejected; those claims are noted in the Audit Trail.

### `t1` — skills/council/engine.sh:0

```
$ grep -n -- '--fwd-demo' skills/council/engine.sh
(no output; exit 1)

```

Reproducible: `grep -n -- '--fwd-demo' skills/council/engine.sh`


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

## Prosecutor Brief

Phase 4 Prosecutor output (jaded-senior flavor). Lists each claim, the
evidence against it, and a requested verdict. Lines asserting facts not
backed by an investigator `tool_use_id` were struck before delivery to the
Judge; struck lines appear in the Audit Trail.

_Brief not provided._

---

## Devil's Advocate Brief

Phase 4 Devil's Advocate output (yolo-ic flavor). Lists each claim, the
evidence supporting it, and a requested verdict. Same strike rule applies.

_Brief not provided._

---

## Verdicts

Per-claim verdicts from the Council Judge (Phase 5). The Judge is
structurally forbidden from running tools and operates solely on the
evidence bundles above. Each verdict includes the taxonomy term, confidence
score (0–100), and the raw inline evidence blob in a fenced code block.
Verdict lines lacking a raw blob or whose quoted citation does not appear
verbatim in the blob were struck and appear in the Audit Trail.

### Claim c0: [AC-A] Step 3 adds flag --fwd-demo to skills/council/engine.sh

**CONTRADICTED** — confidence: 92/100

```
(no output; exit 1)
```


---

## Audit Trail — Struck Lines

Every line struck for missing `tool_use_id`, unsupported citation, or
paraphrased evidence is listed here. This section is always present.

No lines struck.

---

## Run Metadata

| Field | Value |
|---|---|
| Completion time | 0s |
| Report shape | `verdict[]` |
| Engine | `skills/council/engine.sh` |
| Spec | `specs/core/SPEC-013-adversarial-council-tribunal.md` |
