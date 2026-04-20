# External reviewer option

**Status**: PENDING

## Problem

dev-team's `/review-commit` and `/council` use 5 Claude-only reviewers. Same-model review has blind-spot correlation — Claude is unlikely to catch issues that Claude systematically misses. Cross-tool review (claude-review-loop pattern) adds genuine diversity of perspective.

## Goal

Optional `--external` flag on `/council` or `/review-commit` that delegates one investigator slot to an external AI tool (Codex, Gemini CLI, etc.) when available. The external reviewer sees the same diff but reasons independently, breaking same-model correlation.

## Implementation Notes

- New investigator flavor in council engine that shells out to external CLI (e.g., `codex review`, `gemini code-review`)
- Auto-detect available tools at runtime — skip gracefully if none installed
- External reviewer output parsed into the same finding/verdict format as internal investigators
- Could also work via MCP if an external review MCP server is configured
- Inspired by claude-review-loop (hamelsmu, 648 stars) — two-phase stop-hook review loop

## Affects

- `skills/council/`
- `commands/review-commit.md`

## Effort

Medium (needs external CLI detection + output parsing)

---

*Added: 2026-04-19*
