---
path: "{{PATH}}"
severity_floor: "{{FLOOR}}"
slug: "{{SLUG}}"
date: "{{DATE}}"
created_at: "{{CREATED_AT}}"
verification_mode: "{{VERIFICATION_MODE}}"
stage: "1-2"
---

# Bug-hunt report — {{DATE}}-{{SLUG}}

## Variable contract

Fill each brace slot in the frontmatter and body once. This section has no brace slots.

| Slot | Source |
|------|--------|
| PATH | BH_PATH |
| FLOOR | BH_FLOOR |
| SLUG | BH_SLUG |
| DATE | BH_DATE |
| CREATED_AT | ISO-8601 UTC |
| VERIFICATION_MODE | full, or self-verified |
| DEGRADED_BANNER | empty when full; the CDV-199 marker when degraded |
| MANIFEST | BH_MANIFEST |
| S2_FLAVORS | refute flavor pair |
| COUNTS | candidates, confirmed, refuted, dropped, confirmed_actionable |
| CONFIRMED_ACTIONABLE | AC8 list, or `(none)` |
| REFUTED_SUMMARY | locator plus one-line reason, or `(none)` |
| DROPPED_SUMMARY | dropped rows, or `(none)` |
| PHASE_DONE_M20 | discover phase-done lines |
| PHASE_DONE_M21 | refute phase-done lines |
| ZERO_ACTIONABLE_LINE | `0 confirmed-actionable` when the actionable count is 0 |
| REPORT_PATH | BH_REPORT |
| FINDINGS_JSON_PATH | findings JSON path, or not written |

{{DEGRADED_BANNER}}

## Scope

| Field | Value |
|-------|-------|
| Path | `{{PATH}}` |
| Severity floor | `{{FLOOR}}` |
| Manifest | {{MANIFEST}} |
| Refute flavors | `{{S2_FLAVORS}}` |
| Verification mode | `{{VERIFICATION_MODE}}` |

## Counts

{{COUNTS}}

## Confirmed actionable

Findings with `status=confirmed` **and** severity ≥ floor (AC8 / M32). Below-floor
findings MUST NOT appear here.

{{CONFIRMED_ACTIONABLE}}

## Refuted

Locator + one-line disposition reason (not actionable).

{{REFUTED_SUMMARY}}

## Dropped (informational)

Below-floor / out-of-scope / malformed — never entered candidate set (M15).

{{DROPPED_SUMMARY}}

## Phase-done

### Discover (M20)

{{PHASE_DONE_M20}}

### Refute (M21)

{{PHASE_DONE_M21}}

## Terminal

{{ZERO_ACTIONABLE_LINE}}

## Artifacts

| Artifact | Path |
|----------|------|
| User-visible report | `{{REPORT_PATH}}` |
| Machine findings JSON (SHOULD) | `{{FINDINGS_JSON_PATH}}` |

## Hard walls

- The report does not materialize. Materialize runs only after `--proceed` or a typed `proceed`.
- Stage 4 is emit-only. The skill prints an invocation hint and does not start `/orchestrate` or `/epic`.
- Stages 3 and 4 continue in this hunt after the report.

---

<!-- Orchestrator fill notes. Slot names are in the variable contract.
  DEGRADED_BANNER is the self-verified marker when degraded, else empty.
  COUNTS lists candidates, confirmed, refuted, dropped, and confirmed_actionable.
  CONFIRMED_ACTIONABLE is one AC8 block per item, or (none).
  REFUTED_SUMMARY and DROPPED_SUMMARY are one bullet per item.
-->
