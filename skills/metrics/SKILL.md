---
name: metrics
description: >
  SPEC-026 outcomes ledger writers/readers plus CDV-187 read-only rollup.
  Helpers: emit-outcome.sh (write), outcome-rates.sh (advisory rates),
  rollup.sh (display). User-facing entry: /metrics.
---

# metrics

Observability helpers for review-outcome routing (SPEC-026) and the all-time
rollup command (CDV-187). Display and write paths are intentionally split.

## Components

```
skills/metrics/
├── SKILL.md           (this file)
├── emit-outcome.sh    SPEC-026 writer — append outcomes.jsonl
├── outcome-rates.sh   SPEC-026 M5 advisory rates (read)
├── rollup.sh          CDV-187 read-only multi-source rollup
└── test.sh            bite-tests for emit / rates / rollup
```

## Ownership split

| Path | Owner | Mode |
|------|-------|------|
| `.claude/metrics/outcomes.jsonl` | SPEC-026 / `emit-outcome.sh` | append-only write |
| `.claude/local-agent/metrics.jsonl` | SPEC-019 (`run.sh` + `emit-orch-metric.sh`) | append-only write |
| `.claude/council/index.json` | SPEC-013 | atomic index write |
| `/metrics` + `rollup.sh` | CDV-187 | **read-only** display |

`rollup.sh` MUST NOT write under `.claude/`, call emit helpers, open council
report bodies, or re-run retro-gate.

## Dual-shape (local-agent)

`metrics.jsonl` mixes two record types:

- **run** — from `run.sh`: has `outcome` ∈ {success,fail,fallback}; no `ticket`
- **companion** — from `emit-orch-metric.sh`: has `ticket` + `saved_est_tokens`

Classification pin: `has("ticket")` → companion; else if `has("outcome")` → run;
else skip. Never double-count. Sum `saved_est_tokens` only when numeric on
companion rows.

## Interface — rollup.sh

```
rollup.sh [--json] [--section all|local|council|outcomes|worktree]
```

Exit `0` success/partial; `64` usage. jq absent → degrade notice, exit 0.

## Related specs

- SPEC-026 — adaptive agent routing / outcomes ledger
- SPEC-019 — local-agent metrics dual-shape
- SPEC-013 — council verdict index
