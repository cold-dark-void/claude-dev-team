# Handoff — smarter chunk-boundary heuristics

**Status**: COMPLETED — shipped v0.30.3 (user-turn-boundary chunk cutting in prepass.sh; HANDOFF_CHUNK_SOFT_RATIO, default 0.8)

## Problem
prepass.sh chunks the size-adaptive spine at plain message boundaries by token budget. A debug arc can split mid-thread, weakening the convergence through-line in chunked (monster) mode.

## Goal
Prefer natural breaks (compact boundaries, topic shifts, post-resolution, commit points) over a raw token cutoff, so each chunk-summary preserves a coherent slice.

## Implementation Notes
- Avoid splitting inside a hypothesis -> test -> correction run.
- Keep the deterministic/streaming constraint (no whole-file load).

## Affects
- skills/handoff/prepass.sh
- skills/handoff/SKILL.md (chunk-summarizer)

## Effort
Medium

---

*Added: 2026-06-05*
