# Session cost tracking

**Status**: PENDING — DEFERRED (hook payloads lack token data)

## Problem

dev-team has zero visibility into token/cost burn during orchestration runs. `/orchestrate` can spawn 10+ subagents with no way to see cumulative cost until the API bill arrives.

## Blocker

PostToolUse hook stdin JSON does not include token usage data (input_tokens, output_tokens, cache_read, cache_write). The transcript JSONL also does not surface per-turn token counts. Without token data in hook payloads, per-turn cost tracking is not feasible.

**Unblock condition**: Claude Code exposes token usage in hook stdin payloads (any hook event), OR adds token data to the transcript JSONL schema.

**Partial workaround** (not implemented): `--output-format json` emits costUSD + token counts at session end in headless mode. A Stop hook could capture this for subagents spawned by `/orchestrate`, but not for interactive sessions. Could be revisited as a downscoped v1.

## Design (ready when unblocked)

- PostToolUse hook accumulates input/output/cache tokens per turn
- Flags runaway loops (retry spirals) via token velocity detection
- Surfaces cost summary in `/standup` and `/wrap-ticket` output
- Quality score as a field in `/memory-stats`
- Inspired by token-optimizer (alexgreensh, 453 stars, PolyForm NC — ideas only)

## Affects

- `skills/init-orchestration/`
- `commands/standup.md`
- `commands/wrap-ticket.md`

## Effort

Medium (when unblocked)

---

*Added: 2026-04-19*
*Deferred: 2026-04-19 — hook payloads lack token usage data*
