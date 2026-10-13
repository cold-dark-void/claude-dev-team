# SPEC-097: Ac style fixture

**Status**: DRAFT
**Category**: core
**Created**: 2026-10-12

## Overview

Fixture for check-ac-clauses.sh: exactly AC H and AC K are flagged.

## MUST

- MUST follow ASD-STE100 in the docs (outside the AC section — never flagged)

## Acceptance criteria

### T-fix

- **G.** The diff adds `docs/commands/wrap-ticket.md` and a grep check fails
  when the page says release removes the branch with no merge condition.
  Verify: bash skills/spec-tooling/check-ac-clauses-test.sh
- **H.** The docs match the lib. A grep check fails when either page says
  release removes the branch with no merge condition. The text follows ASD-STE100.
- **I.** [process] `bash tools/run-all-tests.sh` exits 0 and every `/release`
  gate passes; the docs follow Simplified Technical English.
- **K.** The docs match the lib and the prose is written in
  simplified technical english (lowercase, on a continuation).

## Test

- the flag fixture exists

## Validation

- reviewed; evidence: check-ac-clauses-test.sh run attached

## Version History

| Date | Change |
|------|--------|
| 2026-10-12 | fixture |
