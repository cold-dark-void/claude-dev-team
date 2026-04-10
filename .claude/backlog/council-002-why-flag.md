# COUNCIL-002 — `/council --why` flag

**Status**: PENDING

## Problem

SPEC-013 lists `--why` in the SHOULD section as a flag that prints flavor presets used + reasoning behind specialist selection. COUNCIL-001 doesn't implement it. Users running `/council` get a verdict but no visibility into which flavors fired, which prompts were used, or why a particular specialist was (or wasn't) pulled.

## Goal

Add a `--why` flag to `commands/council.md` and `engine.sh preflight` that, when set, prints a debug section in the stdout summary covering:

- Flavors used per phase (claim-extractor, investigators with their flavor names, prosecutor, advocate, judge)
- Domain specialist selection reasoning (once Phase 3 lands — until then, just "skipped (Phase 3 deferred)")
- Token budget per phase
- Claim ranking when budget was exceeded
- Any preset overrides applied

## Implementation Notes

- Add `--why` to `engine.sh` arg parsing — preflight emits a `why` section in the investigation plan JSON
- `commands/council.md` reads the `why` section and prints it after the main summary
- Format: short labeled bullets, not a wall of JSON
- Don't dump raw prompts — those live in the report file already
- Test: `/council --why "<claim>"` prints the debug section; `/council "<claim>"` (without flag) does not

## Notes

Source: deferred from COUNCIL-001 per locked decision 1 (SHOULD item). Cheap, low-risk, useful for calibration. Could ship in COUNCIL-002 alongside the heavier scope additions.

---

*Added: 2026-04-09*
