# Agent notification sink (tiered)

**Status**: PENDING

## Problem

During long `/orchestrate` runs (30+ min, 10+ subagents), there is no passive visibility into agent progress. Users must actively poll `/standup` or watch the terminal. No way to get notified when tasks complete, QA passes, or errors occur.

## Goal

Tiered notification system that works with whatever the user already has configured:

1. **MCP** (if available): orchestrator detects Slack/Discord MCP tools (`mcp__slack__*`) at milestone points and sends rich summaries (QA verdict, PR ready, review done)
2. **Webhook** (fallback): `curl` in `memory-capture.sh` PostToolUse hook fires on high-signal events via `AGENT_WEBHOOK_URL` env var. Raw JSON, fire-and-forget, non-blocking.
3. **Silent**: neither set, skip — zero impact on existing behavior

## Scope

- **Hook layer** (`memory-capture.sh`): raw webhook via `curl` for all high-signal events
- **Agent layer** (`skills/orchestrate/SKILL.md`): checks for `mcp__slack__*` tools at milestone points, uses if available
- **Events**: task-complete, task-blocked, QA pass/fail, council verdict, errors (non-zero exit), review findings above confidence threshold

## Implementation Notes

- No external dependencies — `curl` for webhooks, MCP tools if already configured
- Webhook payload: `{"event":"task_complete","agent":"ic5","task":"...","time":"..."}`
- Fail silently on webhook errors (no retry, no queue — convenience, not critical path)
- Inspired by claude-mem's real-time observation feeds (AGPL — ideas only, no code)

## Affects

- `.claude/hooks/memory-capture.sh` (the live hook; emitted as a template by `/init-orchestration`)
- `skills/orchestrate/SKILL.md`

## Effort

Low

---

*Added: 2026-04-19*
