[//]: # "Variable contract — orchestrator fills via Write tool (no bash heredoc with !)"
[//]: # "{{PATH}}                  — BH_PATH absolute scope"
[//]: # "{{FLOOR}}                 — BH_FLOOR (critical|warning|nitpick)"
[//]: # "{{SLUG}}                  — BH_SLUG report basename slug"
[//]: # "{{DATE}}                  — BH_DATE YYYY-MM-DD UTC"
[//]: # "{{CREATED_AT}}            — ISO-8601 UTC timestamp"
[//]: # "{{MANIFEST}}              — team/lens manifest (BH_MANIFEST)"
[//]: # "{{S2_FLAVORS}}            — refute flavor pair(s) e.g. logic+security"
[//]: # "{{VERIFICATION_MODE}}     — full | self-verified"
[//]: # "{{DEGRADED_BANNER}}       — empty when full; blockquote with exact CDV-199 marker when degraded"
[//]: # "{{COUNTS}}                — multiline counts block (candidates/confirmed/refuted/dropped/confirmed_actionable)"
[//]: # "{{CONFIRMED_ACTIONABLE}}  — full AC8 list for confirmed ∧ severity≥floor; or '(none)' when empty"
[//]: # "{{REFUTED_SUMMARY}}       — locator + one-line reason per refuted item; or '(none)'"
[//]: # "{{DROPPED_SUMMARY}}       — informational dropped[] (reason); or '(none)'"
[//]: # "{{PHASE_DONE_M20}}        — exact phase-done discover lines from S1"
[//]: # "{{PHASE_DONE_M21}}        — exact phase-done refute lines from S2"
[//]: # "{{ZERO_ACTIONABLE_LINE}}  — '0 confirmed-actionable' when A==0; else empty or count line"
[//]: # "{{REPORT_PATH}}           — BH_REPORT absolute path"
[//]: # "{{FINDINGS_JSON_PATH}}    — SHOULD path for machine JSON (or 'not written')"

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

## Hard walls (stages 1–2)

- **MUST NOT** materialize / backlog / findings-plan (AC12)
- **MUST NOT** fix / implement / stage-4 handoff (AC13)
- Stages 3–4 require a later epic child + explicit user proceed

---

<!-- Orchestrator fill notes:
  {{DEGRADED_BANNER}} when BH_REFUTE_DEGRADED or BH_VERIFICATION_MODE=self-verified:
    > **self-verified — refuters unavailable**
  else empty string.

  {{COUNTS}} example:
    - candidates: N
    - confirmed: C
    - refuted: R
    - dropped: D
    - confirmed_actionable: A

  {{CONFIRMED_ACTIONABLE}} — for each item, all AC8 fields:
    ### <id or n>
    - **locator:** …
    - **severity:** critical|warning|nitpick
    - **description:** …
    - **evidence:** …
    - **status:** confirmed
    When empty: `(none)` plus ensure terminal shows `0 confirmed-actionable`.

  {{REFUTED_SUMMARY}} — bullet per item: `- <locator> — <one-line reason>`
  {{DROPPED_SUMMARY}} — bullet: `- <locator> (<reason>) — <detail>`
-->
