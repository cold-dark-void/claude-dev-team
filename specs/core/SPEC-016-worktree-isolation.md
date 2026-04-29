# SPEC-016: Worktree Isolation

**Status**: ACTIVE
**Category**: core
**Created**: 2026-04-28

**Covers**: `skills/worktree-lib.sh`, `skills/orchestrate/SKILL.md`, `skills/wrap-ticket/SKILL.md`, `skills/demo/SKILL.md`, `AGENTS.md`, `.gitignore`

## Overview

Defines a canonical, collision-safe worktree convention for the plugin. Any skill or agent that needs an isolated worktree for implementation work MUST go through `skills/worktree-lib.sh` — a pure subprocess CLI that creates worktrees at `$MROOT/.worktrees/<slug>`, manages a PID-based lock, and handles stale-lock recovery. Eliminates the previous pattern of skills improvising sibling-directory paths (`$MROOT/../<project>-<TICKET-ID>`) which collided across parallel runs.

## MUST

### Path convention
- MUST place all plugin-managed worktrees at `$MROOT/.worktrees/<slug>` where `$MROOT` is resolved via `_gc=$(git rev-parse --git-common-dir 2>/dev/null) && MROOT=$(cd "$(dirname "$_gc")" && pwd) || MROOT=$(pwd)` (per SPEC-009, SPEC-002)
- MUST use branch name `feat/<slug>` when creating a new worktree branch
- MUST add `.worktrees/` to `$MROOT/.gitignore`
- MUST NOT create new worktrees at sibling paths (`$MROOT/../<project>-<TICKET-ID>`); legacy paths are read-only for detection/cleanup

### `worktree-lib.sh` CLI contract
- MUST be a pure subprocess CLI — `bash skills/worktree-lib.sh <cmd> <args>` only; MUST NOT require sourcing; MUST NOT mutate the caller's shell
- MUST support exactly two subcommands: `ensure <slug>` and `release <slug>`
- MUST resolve `$MROOT` internally using the worktree-aware formula above
- MUST exit with: `0` = success, `1` = release error, `2` = user aborted on collision prompt, `64` = usage error

### `ensure <slug>` semantics
- MUST create the worktree at `$MROOT/.worktrees/<slug>` if absent
- MUST create branch `feat/<slug>` if absent; MUST reuse the branch if it already exists
- MUST print the absolute worktree path to stdout on success (and only on success)
- MUST write `$MROOT/.worktrees/<slug>/.wt-lock` on success containing one line: `SESSION_ID PID ISO-8601-TIMESTAMP` (space-separated). SESSION_ID and TIMESTAMP are informational only; PID is authoritative
- MUST detect existing `.wt-lock`:
  - If lock PID is a live process: print collision summary to stderr (slug, branch, HEAD short SHA + commit subject, lock age, PID + live status), then:
    - If stdin is a TTY: prompt user (abort | steal lock). On abort exit 2 with nothing on stdout. On steal overwrite lock and exit 0 with worktree path on stdout
    - If no TTY: still print summary, prompt, and apply same exit codes (AC-5)
  - If lock PID is dead (stale): silently overwrite lock and exit 0 with worktree path on stdout
- MUST NOT print the worktree path on stdout for any non-zero exit

### `release <slug>` semantics
- MUST remove `$MROOT/.worktrees/<slug>/.wt-lock`
- MUST run `git worktree remove "$MROOT/.worktrees/<slug>"`
- MUST exit non-zero with a clear stderr message if the worktree has uncommitted changes; MUST NOT force-remove
- MUST exit 0 on clean removal

### Caller integration
- `skills/orchestrate/SKILL.md` Step 3 MUST call `bash skills/worktree-lib.sh ensure <slug>` as a subprocess and capture stdout as the worktree path. MUST remove the legacy sibling-path creation. On exit 1: surface the stderr error to the user and halt. On exit 2: halt cleanly without error
- `skills/wrap-ticket/SKILL.md` Step 6 MUST call `bash skills/worktree-lib.sh release <slug>` as a subprocess. MUST remove any direct `git worktree remove` call targeting `.worktrees/` paths
- `skills/wrap-ticket/SKILL.md` MUST detect both `.worktrees/<slug>` (new) and `$MROOT/../<project>-<TICKET-ID>` (legacy) worktree paths; MUST prefer the new path when both exist
- `skills/wrap-ticket/SKILL.md` MUST anchor every `grep` for a TICKET-ID so `WISO-1` does not match `WISO-10` (use `grep -E "(^|[^A-Z0-9-])WISO-1([^0-9]|$)"` or `grep -wF`); fix everywhere wrap-ticket greps for ticket ID
- `skills/demo/SKILL.md` MUST keep its dedicated `$TMPDIR/demo-project` path and MUST NOT depend on `worktree-lib.sh`. MUST add a 2-3 line inline check at worktree creation: if path exists, prompt user before proceeding
- `AGENTS.md` MUST contain a "Worktree Protocol" section that: declares `.worktrees/<slug>` as the canonical path, points to `skills/worktree-lib.sh` and SPEC-016, and states in one sentence that sibling-directory worktrees are forbidden when the lib is in use

## SHOULD

- SHOULD include the slug, branch, HEAD short SHA, commit subject, lock age, and PID liveness in the collision summary so the user can decide informed
- SHOULD use `kill -0 <pid>` (POSIX) for liveness check
- SHOULD treat absent `$MROOT` resolution as a fatal error and exit non-zero with a clear message
- SHOULD exclude `.wt-lock` from the dirty-tree check in `release` (it is bookkeeping, not user content)

## MUST NOT

- MUST NOT source `worktree-lib.sh`; subprocess invocation only (matches `task-store.sh`, `gate.sh` precedent)
- MUST NOT silently reuse a worktree owned by a live PID
- MUST NOT delete or `--force` a worktree with uncommitted changes
- MUST NOT run parallel `git worktree` operations — already documented in AGENTS.md; this spec inherits that constraint

## Lock file format

`.wt-lock` contains exactly one line:

```
<SESSION_ID> <PID> <ISO-8601-TIMESTAMP>
```

Example:

```
sess-abc123 48217 2026-04-28T14:32:11Z
```

PID is the only authoritative field. SESSION_ID and TIMESTAMP are informational (debug aid only).

## Exit code contract

| Code | Meaning |
|------|---------|
| 0 | Success — worktree ready, path on stdout |
| 1 | `release` error — missing worktree or uncommitted changes block removal |
| 2 | User aborted on prompt (live lock collision declined or no answer given) |
| 64 | Usage error — missing slug or unknown subcommand |
| non-zero (other) | Fatal error |

## Test

- Verify `ensure <slug>` creates `.worktrees/<slug>`, branch `feat/<slug>`, and `.wt-lock`; prints absolute path; exits 0
- Verify `ensure` against an existing live-PID lock: stderr shows summary, exit 2 on abort, stdout empty
- Verify `ensure` against a stale lock (dead PID): silently overwrites, exits 0, prints path
- Verify `ensure` no-TTY collision still prompts and honors abort (exit 2) / steal (exit 0)
- Verify `release` cleans `.wt-lock` + removes worktree on clean tree; exits non-zero on dirty tree without force
- Verify orchestrate Step 3 captures stdout path correctly and halts on exit 1/2
- Verify wrap-ticket grep does not match `WISO-10` when looking for `WISO-1`
- Verify wrap-ticket detects both `.worktrees/<slug>` and legacy sibling path; prefers new

## Validation

- [ ] `skills/worktree-lib.sh` exists and is executable as a subprocess CLI
- [ ] `.worktrees/` is in `$MROOT/.gitignore`
- [ ] `AGENTS.md` has a "Worktree Protocol" section pointing to SPEC-016
- [ ] `orchestrate` Step 3 calls `worktree-lib.sh ensure`
- [ ] `wrap-ticket` Step 6 calls `worktree-lib.sh release`
- [ ] `wrap-ticket` ticket-ID greps are anchored
- [ ] `demo` retains its inline worktree check; does not call `worktree-lib.sh`

## Open Questions

- [ ] Should `ensure` accept a `--no-prompt` flag for fully non-interactive callers (CI)? Currently no-TTY path still prompts per AC-5; if CI proves painful, add later.
- [ ] Should `release` support an explicit `--force` for callers that have already confirmed loss is acceptable? Out of scope for v1.

## Version History

| Date | Change |
|------|--------|
| 2026-04-28 | Initial spec for WISO-001. |
| 2026-04-29 | Exit code table corrected to match implementation (exit 1 = release error, exit 2 = abort/decline, exit 64 = usage). Added SHOULD for .wt-lock dirty-check exclusion. |

## Cross-references

- SPEC-002: Plugin Infrastructure — `$MROOT` resolution formula; subprocess CLI precedent (`task-store.sh`, `gate.sh`)
- SPEC-009: Ticket Workflow — wrap-ticket worktree cleanup MUSTs; orchestrate Step 3 ownership; `$MROOT` worktree-aware resolution
