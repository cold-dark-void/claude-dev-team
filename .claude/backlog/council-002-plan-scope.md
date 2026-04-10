# COUNCIL-002 — `/council --plan <path>` scope

**Status**: PENDING

## Problem

`/council --plan <path>` is documented in SPEC-013 (Command Shape & Scope MUSTs) and accepted by `commands/council.md` argument parsing, but currently fails loudly with `engine.sh: --plan is not implemented in COUNCIL-001 (v0.18.0). Planned for COUNCIL-002. See SPEC-013.` Users who try to audit a plan file for unverified assumptions get a wall, not a verdict.

## Goal

Implement Phase 1 claim extraction over markdown plan files. The extractor should walk the plan's headings and bullets, identify load-bearing assertions (decisions, technical claims, "we will use X because Y" statements), and emit them as the same `{claim, source_locator, claim_type}` records the session-scope extractor produces. Source locator format: `<plan-file>:<heading-path>:<line>`. Once claim extraction is in place, the rest of the engine pipeline (Phase 2 investigators → Phase 5 judge) just works because it's claim-shape agnostic.

## Implementation Notes

- Add `--scope plan --scope-arg <path>` handling in `skills/council/engine.sh` preflight
- Extend `skills/council/prompts/claim-extractor.md` with a plan-mode branch (or create a sibling `plan-extractor.md`)
- Source locator should be precise enough that an investigator can read just the relevant section, not the whole plan
- Update `commands/council.md` to drop the deferred-fail message for `--plan` once the engine handles it
- Snapshot test: feed a known plan with one true claim and one fabricated claim, verify VERIFIED + FABRICATED verdicts

## Notes

Source: deferred from COUNCIL-001 per locked decision 1 (scope split). No spec change needed — SPEC-013 already mandates this scope.

---

*Added: 2026-04-09*
