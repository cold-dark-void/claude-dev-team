# COUNCIL-002 — Phase 3 dynamic domain specialist

**Status**: PENDING

## Problem

SPEC-013 Phase 3 (Dynamic Domain Specialist) is documented but explicitly DEFERRED in COUNCIL-001 — `skills/council/SKILL.md` and `commands/council.md` skip the phase entirely. The engine treats it as a no-op. Without it, claims about deploys / metrics / tests / requirements get audited by generic investigators instead of by the specialist team agents (devops/ds/qa/pm) who actually have project cortex on those domains.

## Goal

Implement claim topic classification and conditional specialist pull. When a claim's topic confidently matches a known domain, spawn the matching team agent as an additional investigator (read-only, blind, returns evidence bundle). When no confident match exists, skip — never pull a specialist on weak signal.

Topic → agent mapping (per SPEC-013 Phase 3):
- Deploy / infra / CI / Docker / K8s / rollout → `devops`
- Metrics / statistics / ML / data-pipeline / a-b-test → `ds`
- Test / coverage / regression / fixture → `qa`
- Product / requirements / scope / user-story → `pm`

## Implementation Notes

- Add a topic-classifier prompt at `skills/council/prompts/topic-classifier.md` (cheap Sonnet pass: claim text in, `{topic, confidence}` out)
- Add Phase 3 dispatch in `commands/council.md` between Phase 2 and Phase 4 — read classifier output, decide specialist or skip, spawn via Task tool with the team agent name (NOT subagent_type general-purpose)
- Cross-check: team agents have non-empty tool allowlists by default; the specialist call still inherits team-agent cortex but operates as an investigator (blind, evidence-bundle output)
- Document the confidence threshold (suggest ≥0.75) — anything below is "no match, skip"
- Update SPEC-013 Validation checklist to add a Phase 3 specialist-pull verification line
- Test: `/council "the k8s rollout is healthy"` should pull devops; `/council "users love the new flow"` should NOT pull anyone

## Notes

Source: deferred from COUNCIL-001 per locked decision 1. Highest-complexity deferred item — adds a new subagent class (topic classifier) and a new dispatch path. Defer until COUNCIL-001 has been used in anger and the specialist value is clear.

---

*Added: 2026-04-09*
