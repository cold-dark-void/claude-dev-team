# Bash output compression hook

**Status**: COMPLETED

## Problem

When IC agents run test suites, builds, or git commands during `/orchestrate`, full raw output floods the context window. dev-team has zero terminal output compression. Inspired by RTK (30.1K stars) but built in-house (no external binary — security/privacy concern).

## Blocker

PostToolUse hooks cannot replace `tool_result`. The hook can add a `systemMessage` and control `suppressOutput`, but there is no documented mechanism to swap out what the agent sees as the command output. Without output replacement, actual token savings are near zero — only advisory guidance is possible.

**Unblock condition**: Claude Code ships an API for PostToolUse hooks to rewrite/replace tool_result, OR a spike confirms `suppressOutput: true` suppresses the tool result (not just hook stdout).

## Design (ready to implement when unblocked)

- Pure shell/python3 PostToolUse hook (`bash-output-compress.sh`)
- Pattern-match on command prefix: go/cargo/npm/pytest test, go/cargo/npm build, make, git log/diff/status
- Retain: pass/fail summary, error messages, changed file paths. Drop: progress lines, passing tests, raw patches.
- Passthrough threshold: skip compression for output < 50 lines
- Header: `[output compressed: N lines -> M lines]`
- Installed by `/init-orchestration` alongside `memory-capture.sh`
- Run after `memory-capture.sh` (so memory gets raw output)
- Exit 0 always (never blocks agent)

## Acceptance Criteria (from PM review)

AC-1 through AC-14 documented in PM agent output, session 2026-04-19.

## Affects

- `skills/init-orchestration/`
- `.claude/settings.json` (target projects)

## Effort

Medium (when unblocked)

---

*Added: 2026-04-19*
*Deferred: 2026-04-19 — PostToolUse cannot replace tool_result*
