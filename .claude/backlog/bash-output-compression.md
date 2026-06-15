# Bash output compression hook

**Status**: COMPLETED

## Problem

When IC agents run test suites, builds, or git commands during `/orchestrate`, full raw output floods the context window. dev-team has zero terminal output compression. Inspired by RTK (30.1K stars) but built in-house (no external binary — security/privacy concern).

## Resolution (shipped)

The original PostToolUse approach was blocked — PostToolUse hooks cannot replace `tool_result`, so a post-hoc compressor could only add advisory `systemMessage` text with near-zero token savings. **Shipped instead as a PreToolUse hook** that sidesteps the blocker: `.claude/hooks/bash-compress.sh` rewrites the command *before* execution via `hookSpecificOutput.updatedInput.command`, wrapping noisy commands so their output is captured and compressed inline.

- PreToolUse `Bash` matcher; the wiring is emitted into consumer projects' `settings.json` by `/init-orchestration` (`skills/init-orchestration/SKILL.md`).
- Pattern-matches noisy command prefixes (test/build, git log/diff/status); short output passes through untouched.
- Truncates to head-20 + tail-20 with a compression header; skipped for output under 50 lines; the wrapped command's exit code is preserved and the hook never blocks the agent.

## Acceptance Criteria (from PM review)

AC-1 through AC-14 documented in PM agent output, session 2026-04-19.

## Affects

- `.claude/hooks/bash-compress.sh` (the shipped PreToolUse hook)
- `skills/init-orchestration/SKILL.md` (emits the hook + the PreToolUse `settings.json` wiring into target projects)

## Effort

Medium

---

*Added: 2026-04-19*
*Shipped: implemented as a PreToolUse hook that rewrites the command via `updatedInput` — the original PostToolUse "cannot replace tool_result" blocker was bypassed by moving to PreToolUse.*
