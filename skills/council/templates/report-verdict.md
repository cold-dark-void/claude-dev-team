[//]: # "Variable contract — engine.sh (finalize) substitutes these via {{VAR}} placeholders"
[//]: # "{{TASK_ID}}               — task id, present in frontmatter only when run is task-bound"
[//]: # "{{SCOPE}}                 — e.g. 'session --last 20', 'claim', 'from-retro abc123'"
[//]: # "{{PRESET}}                — e.g. 'generic'"
[//]: # "{{TIMESTAMP}}             — ISO-8601 UTC timestamp of report creation"
[//]: # "{{INVESTIGATOR_FLAVORS}}  — comma-separated list of flavor ids used"
[//]: # "{{CLAIM_BUDGET}}          — maximum claims allowed per run (default: 10)"
[//]: # "{{CLAIMS_AUDITED}}        — actual number of claims investigated"
[//]: # "{{EXTRACTED_CLAIMS}}      — structured claim list from Phase 1"
[//]: # "{{EVIDENCE_BUNDLES}}      — raw evidence bundles from Phase 2 investigators"
[//]: # "{{CROSS_REVIEW_STATUS}}   — 'RAN' or 'BYPASSED (reason: <text>)'"
[//]: # "{{CROSS_REVIEW_RANKINGS}} — per-reviewer ranking table (anonymized labels A/B/C)"
[//]: # "{{CROSS_REVIEW_SCORES}}   — Borda score table: bundle identity, score, WEAK_EVIDENCE flag"
[//]: # "{{PROSECUTOR_BRIEF}}      — Phase 4 prosecutor output (post-strike)"
[//]: # "{{ADVOCATE_BRIEF}}        — Phase 4 devil's advocate output (post-strike)"
[//]: # "{{VERDICTS}}              — per-claim verdict records from Phase 5 judge"
[//]: # "{{STRUCK_LINES}}          — lines struck for missing/unsupported evidence"
[//]: # "{{VERDICT_SUMMARY_TABLE}} — counts by taxonomy: VERIFIED/PARTIALLY_VERIFIED/UNVERIFIED/CONTRADICTED/FABRICATED"
[//]: # "{{COMPLETION_TIME}}       — wall-clock duration of the full council run"

# Council Verdict Report

## Summary

This report documents an adversarial council tribunal run against the scope
`{{SCOPE}}` using preset `{{PRESET}}`. Investigators gathered raw tool-call
evidence for each extracted claim; a Prosecutor and Devil's Advocate wrote
adversarial briefs over that evidence; the Council Judge — structurally
forbidden from running tools — issued verdicts from the fixed taxonomy.
See the Verdicts section for per-claim outcomes and the Audit Trail for any
lines struck for missing or unsupported evidence.

---

## Verdict Summary

{{VERDICT_SUMMARY_TABLE}}

| Taxonomy | Count |
|---|---|
| VERIFIED | — |
| PARTIALLY_VERIFIED | — |
| UNVERIFIED | — |
| CONTRADICTED | — |
| FABRICATED | — |

---

## Scope & Configuration

| Field | Value |
|---|---|
| Scope | `{{SCOPE}}` |
| Preset | `{{PRESET}}` |
| Investigator flavors | `{{INVESTIGATOR_FLAVORS}}` |
| Claim budget | {{CLAIM_BUDGET}} |
| Claims audited | {{CLAIMS_AUDITED}} |
| Timestamp | `{{TIMESTAMP}}` |

---

## Extracted Claims

Claims extracted from the subject during Phase 1. Each carries a source
locator (turn ID or file:line) and claim type (factual / causal /
recommendation). When the budget was exceeded, claims were ranked by
load-bearing weight; un-audited claims are listed below the budget cap note.

{{EXTRACTED_CLAIMS}}

---

## Evidence Bundles

Raw tool-call evidence collected by blind investigators (Phase 2). Each
bundle contains a `tool_use_id`, the raw output blob (not paraphrased), a
`file:line` citation, and a reproducible command. Bundles missing a
`tool_use_id` were rejected; those claims are noted in the Audit Trail.

{{EVIDENCE_BUNDLES}}

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

## Prosecutor Brief

Phase 4 Prosecutor output (jaded-senior flavor). Lists each claim, the
evidence against it, and a requested verdict. Lines asserting facts not
backed by an investigator `tool_use_id` were struck before delivery to the
Judge; struck lines appear in the Audit Trail.

{{PROSECUTOR_BRIEF}}

---

## Devil's Advocate Brief

Phase 4 Devil's Advocate output (yolo-ic flavor). Lists each claim, the
evidence supporting it, and a requested verdict. Same strike rule applies.

{{ADVOCATE_BRIEF}}

---

## Verdicts

Per-claim verdicts from the Council Judge (Phase 5). The Judge is
structurally forbidden from running tools and operates solely on the
evidence bundles above. Each verdict includes the taxonomy term, confidence
score (0–100), and the raw inline evidence blob in a fenced code block.
Verdict lines lacking a raw blob or whose quoted citation does not appear
verbatim in the blob were struck and appear in the Audit Trail.

{{VERDICTS}}

---

## Audit Trail — Struck Lines

Every line struck for missing `tool_use_id`, unsupported citation, or
paraphrased evidence is listed here. This section is always present.

{{STRUCK_LINES}}

No lines struck.

---

## Run Metadata

| Field | Value |
|---|---|
| Completion time | {{COMPLETION_TIME}} |
| Report shape | `verdict[]` |
| Engine | `skills/council/engine.sh` |
| Spec | `specs/core/SPEC-013-adversarial-council-tribunal.md` |
