# SPEC-098: Ac style control

**Status**: DRAFT
**Category**: core
**Created**: 2026-10-12

## Overview

Zero-finding control for check-ac-clauses.sh.

## Acceptance criteria

### T-fix

- **A.** The diff adds a grep check that fails when the page names the
  removed branch; `stat` shows mode 600 on the token file.
  Verify: bash skills/spec-tooling/check-ac-clauses-test.sh
- **B.** [process] `bash tools/run-all-tests.sh` exits 0; the release notes
  follow ASD-STE100 (style clauses belong on a [process] AC — never flagged).

## Test

- the control fixture exists

## Validation

- reviewed; evidence: check-ac-clauses-test.sh run attached

## Version History

| Date | Change |
|------|--------|
| 2026-10-12 | fixture |
