# /metrics — observability rollup command

**Status**: PENDING

## Problem

The plugin now emits several machine-readable data streams — `.claude/local-agent/metrics.jsonl` (offload outcomes, saved/spent token estimates), the council verdict index (`.claude/council/index.json`), and retro-gate signal output — but there is no single place to see them. The earlier session-cost-tracking attempt (v0.23.0) was abandoned because hook payloads lack token data; these newer sources actually exist.

## Goal

A `/metrics` command that reads only data sources that already exist and prints a rollup: local-agent offload counts/outcomes and estimated savings, council runs and verdict distribution, retro friction trends (gate scores over recent sessions), and worktree/ticket throughput if cheaply derivable.

## Implementation Notes

- Read-only; degrade gracefully per missing source ("no local-agent metrics yet").
- Absorbs the pending `council-002-token-usage-reporting` backlog item as one section of the rollup — reconcile/close that item when this ships.
- Do NOT revive hook-based token capture; that premise already failed (see session-cost-tracking DEFERRED item).

## Affects

New `commands/metrics.md`, README command index, docs/.

## Effort

M

## Notes

Source: 2026-07-03 ideation session (idea #5).

---

*Added: 2026-07-03*
