# COUNCIL-002 — Investigator tool-call caching within a run

**Status**: PENDING

## Problem

When a council run audits 10 claims with 2 investigators each, multiple investigators may end up reading the same file (e.g., `commands/retro.md`) independently. Each Read tool call burns context. SPEC-013 SHOULD section flags intra-run caching as a perf optimization that COUNCIL-001 doesn't implement.

## Goal

Build a per-run shared cache that investigators check before issuing a Read/Grep against a path. Cache layout:

```
$TMPDIR/council-cache-<run-id>/
  reads/<sha256-of-path>.txt
  greps/<sha256-of-pattern-and-glob>.txt
```

Investigators query the cache first; on miss, they run the actual tool call and write the result back. Cache is run-scoped (same `run-id` across all investigators in a single council invocation) and discarded at the end of the run.

## Implementation Notes

- The cache is owned by `engine.sh` — preflight creates the cache dir and passes its path to all investigator Task spawns via the prompt env
- Investigators check the cache via a small shell helper or by being instructed in the prompt template (`investigator.md`) to look there first
- Tricky: Task subagents run in their own context and can't share state cleanly. The cache may be best implemented as a "pre-fetched artifact bundle" — preflight reads all the files referenced in the claims into the cache, and investigators are passed the cache contents as raw artifacts directly (no need for them to issue Reads at all)
- Alternative simpler approach: just instruct the orchestrating Claude (in `commands/council.md`) to dedupe overlapping investigator file requests before spawning them
- Test: run a council with 5 claims that all reference the same file, verify only 1 Read tool call appears in the aggregated tool_use_id list

## Notes

Source: deferred from COUNCIL-001 per locked decision 1 (SHOULD item). Optimization, not correctness — defer until token cost on real `/council` runs is measured and shown to be a problem.

---

*Added: 2026-04-09*
