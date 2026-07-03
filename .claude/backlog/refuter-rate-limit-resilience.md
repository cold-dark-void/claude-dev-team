# Rate-limit resilience for adversarial refuter fleets

**Status**: PENDING

## Problem

Session rate-limits killed adversarial refuter subagents at least 3 times during the audit arcs (P0.5 attempt-3, P2.4, P3.6). The recovery protocol — orchestrator runs the adversarial checks itself, never ships on implementer self-validation — exists only as a memory note, not as documented engine/workflow behavior.

## Goal

Formalize the degradation path wherever refuters/investigators are spawned (council engine, review-and-commit, workflow templates): on spawn failure from rate limiting, auto-degrade to orchestrator self-verification with an explicit "self-verified — refuters unavailable" marker in the output, so degraded runs are visible and auditable.

## Implementation Notes

- Optional second tier: route refuters to the local agent (SPEC-019) when `LOCAL_AGENT` is enabled before falling back to self-verification.
- The marker must reach the final report/verdict output, not just stderr.

## Affects

`skills/council/` (engine + prompts docs), `skills/review-and-commit/`, workflow guidance in AGENTS.md template.

## Effort

S-M

## Notes

Source: 2026-07-03 ideation session (idea #4). Governing precedent: P0.5 — "when refuters are unavailable, orchestrator runs the checks; never ship on impl self-validation (it was green on 2 broken attempts)."

---

*Added: 2026-07-03*
