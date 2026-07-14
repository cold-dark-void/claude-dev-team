# Worktree Skill — User-Invocable `/worktree` Command

**Status**: COMPLETED — shipped v0.45.0 (CDV-189)

## Problem

`worktree-lib.sh` (Option B) provides internal functions for skills to call, but users
have no way to inspect or manage worktrees directly. To check what's running, clean up a
stale lock, or list active worktrees, users must drop to raw `git worktree list` and
manually hunt for lock files.

## Goal

A user-invocable `/worktree` skill with subcommands:
- `/worktree status` — show all active `.worktrees/<slug>` with lock info (PID, age, session)
- `/worktree list` — alias for status
- `/worktree release <slug>` — remove lock + worktree (with confirmation), equivalent to `/wrap-ticket` for non-ticket worktrees

Other skills could also call it via bash for richer UX, but the primary value is the user-facing interface.

## Implementation Notes

- Prerequisite satisfied: Option B (`skills/worktree-lib.sh`, providing `ensure`/`release`) has shipped — this skill wraps it
- Should reuse `worktree_release` from the lib, not duplicate logic
- `status` output should show: slug, branch, lock PID (live/stale), lock age, HEAD commit summary

## Notes

Deferred from worktree isolation brainstorm (2026-04-28). Chosen solution was Option B
(shared lib script). This is Option C — more formal, more files, but better UX once the
lib exists.

---

*Added: 2026-04-28*

*Closed: 2026-07-14*
