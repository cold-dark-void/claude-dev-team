# Brainstorm: Worktree Isolation Convention

**Date:** 2026-04-28

## Problem Statement
No canonical worktree convention exists in the plugin — skills and spawned agents each
improvise the path, causing parallel runs to collide in the same directory and contaminate
each other's code and PRs.

## Success Criteria
- Any implementation work via this plugin runs in an isolated `.worktrees/<slug>` dir
- All skills use one shared function — no path improvisation possible
- Existing worktree triggers an interactive prompt (resume/wrap/force-recreate), not silent reuse or failure
- Lock file prevents two sessions claiming the same worktree simultaneously

## Scope
IN: `skills/worktree-lib.sh` (new shared script), `SPEC-015-worktree-isolation.md`, updates
to `/orchestrate`, `/demo`, `/wrap-ticket`, AGENTS.md

OUT: `/init-orchestration` (separate concern), memory architecture, agent definitions,
`/kickoff` (planning only, no code written, no worktree needed)

## Constraints
- `.worktrees/` gitignored — inherits `.claude/settings.json`, `AGENTS.md`, hooks automatically
- One new file max philosophy respected — lib script, not a full skill
- `wrap-ticket` detection unchanged — `git worktree list | grep` finds both old and new paths

## Key Risks
- Stale lock on crash → detect via PID check (if PID dead, lock is stale)
- Skills updated in text but agents still improvise → spec + AGENTS.md must be explicit
  that improvising the path is a protocol violation

## Chosen Option: B — `skills/worktree-lib.sh` + AGENTS.md + spec + skill updates

### Design
Path convention: `.worktrees/<slug>` inside project root (gitignored)
Lock file: `.worktrees/<slug>/.lock` — contains `PID TIMESTAMP SESSION_ID`

Script provides three functions:
- `worktree_ensure <slug>` — if exists: prompt (resume / wrap / force-recreate); if not: create
- `worktree_claim <slug>` — create + write lock; error if already locked by live PID
- `worktree_release <slug>` — remove lock (called by `/wrap-ticket`)

### Skills to update
- `skills/orchestrate/SKILL.md` — call `worktree_ensure` in Step 3
- `skills/demo/SKILL.md` — call `worktree_ensure` for demo worktree
- `skills/wrap-ticket/SKILL.md` — call `worktree_release` in cleanup step
- `AGENTS.md` — add "Worktree Protocol" section

### Deferred (backlog)
Option C: `/worktree` as a user-invocable skill (status, list, release subcommands)

## Next Step
/kickoff to produce spec + implementation plan
