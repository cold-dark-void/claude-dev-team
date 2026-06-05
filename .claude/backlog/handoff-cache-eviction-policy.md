# Handoff — cache-eviction policy

**Status**: COMPLETED — shipped v0.30.1 (count-cap retention in prepass.sh; HANDOFF_CACHE_MAX_ENTRIES, default 50)

## Problem
The cold-handoff cache (.claude/handoff/cache/<uuid>.json) is invalidated only on session growth (leaf-uuid change). Stale briefs for old sessions accumulate with no eviction.

## Goal
A simple retention policy (LRU by mtime, max-N, or max-age) so the cache dir does not grow unbounded.

## Implementation Notes
- Prune on /handoff invocation or via /wrap-ticket.
- Cheap + deterministic.

## Affects
- skills/handoff/prepass.sh (cache)

## Effort
Low

---

*Added: 2026-06-05*
