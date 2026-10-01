# Legacy review

User-facing review for `/council --diff` and `/review-and-commit`.
This file is the only copy of these headings.
`skills/review-and-commit/bucket.sh` prints a heading only for a section that
has findings. Omit empty sections.

If the run is degraded, print this banner before the first section:

> **self-verified — refuters unavailable**

## Critical Issues (Must Fix) [confidence 95-100]

Bugs, security risks, confirmed PII leaks, correctness failures.
Each item: `file:line` — what is wrong — what to do instead. [confidence: N]

## Compliance Violations

AGENTS.md / CLAUDE.md rule violations.
Each item: `file:line` — rule violated — what to fix. [confidence: N]

## Design Problems [confidence 80-94]

Wrong abstractions, unnecessary complexity, over-engineering.

## Security & PII [confidence 80-94]

Trust boundaries, auth gaps, data exposure, logging risks.

## Maintainability Risks

Hidden coupling, future migration pain, naming that lies.

## Simplification Opportunities

Concrete ways to make the code simpler.

## Nitpicks (Yes, They Matter) [confidence 80-94]

Small things that compound. Still cite file:line.

## Other

A finding whose category has no bucket above.

## What I Would Do Instead

The simpler or safer direction. Prefer subtraction.

## Overall Assessment

2–3 blunt sentences. End with one of: APPROVE / REQUEST CHANGES / NEEDS DISCUSSION

Review stats: N findings from A agents, M passed confidence filter (≥80), K discarded.

`A` is not a fixed 5. `skills/review-and-commit/stats-line.sh` counts one
agent per flavor, plus one when `external.status` is `available`.

Tone: no softening, no congratulation, no hedging ("maybe", "consider",
"you might want to"). Every issue cites `file:line`. Fixes are concrete.
