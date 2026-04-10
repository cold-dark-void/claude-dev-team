# COUNCIL-002 — Per-phase token usage reporting

**Status**: PENDING

## Problem

A council run can spawn 25+ subagents (claim extractor + 2 investigators × 10 claims + prosecutor + advocate + judge + optional specialist) at Opus pricing. Users have no visibility into the cost of a single `/council` invocation. SPEC-013 lists this in the SHOULD section but COUNCIL-001 doesn't implement it.

## Goal

Track per-phase token usage during a council run and surface it in the stdout summary. Format like:

```
Council run summary
  Verdicts: 8 (5 VERIFIED, 2 PARTIALLY_VERIFIED, 1 FABRICATED)
  Report:   .claude/council/2026-04-15-foo--task42.md
  Tokens:   Phase 1 (extraction)     2,341
            Phase 2 (investigation) 47,182
            Phase 4 (prosecution)    8,210
            Phase 4 (advocate)       7,943
            Phase 5 (judge)         12,556
            Total                   78,232
```

## Implementation Notes

- Each Task tool spawn returns token usage in its result envelope. The orchestrating Claude (in `commands/council.md`) collects these per phase and passes them to `engine.sh finalize` as part of the investigation outputs
- `engine.sh finalize` aggregates and prints the token block in the stdout summary
- Persist token totals in the report frontmatter as well so historical analysis is possible
- Don't break the existing summary format — append the token block as a new section

## Notes

Source: deferred from COUNCIL-001 per locked decision 1 (SHOULD item). Useful for cost-conscious users; pairs naturally with the `--why` flag.

---

*Added: 2026-04-09*
