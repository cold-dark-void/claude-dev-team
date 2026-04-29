# WISO-001: Worktree Isolation — Implementation Plan

**Date:** 2026-04-28
**Spec:** `specs/core/SPEC-016-worktree-isolation.md`
**Ticket:** WISO-001

## Task graph

```
T1 (ic5) ──┬──> T2 (ic4)
           └──> T3 (ic4)
T4 (ic4)   [independent]
T5 (ic4)   [independent]
```

- T1 must complete before T2 and T3 (both call the lib).
- T2, T3, T4, T5 can all run in parallel after T1 lands.
- T4 and T5 can start immediately (do not depend on T1).

## Tasks

---

### T1 — Implement `skills/worktree-lib.sh`

**Agent:** ic5 (new system, bash safety + collision semantics critical)
**Touches:** `skills/worktree-lib.sh` (new, executable)
**Depends on:** —

**Spec sections:** "`worktree-lib.sh` CLI contract", "`ensure <slug>` semantics", "`release <slug>` semantics", "Lock file format", "Exit code contract"

**Required subcommands:**
- `bash skills/worktree-lib.sh ensure <slug>`
- `bash skills/worktree-lib.sh release <slug>`

**Key implementation points:**
- Resolve `$MROOT` via `_gc=$(git rev-parse --git-common-dir 2>/dev/null) && MROOT=$(cd "$(dirname "$_gc")" && pwd) || MROOT=$(pwd)`
- Use `set -euo pipefail`; quote all expansions; `kill -0 "$pid"` for liveness
- `ensure`: check lock first → live collision (exit 1 or prompt) / stale (overwrite) / absent (create). On creation: `git worktree add`, create `feat/<slug>` branch if absent, write `.wt-lock` with `SESSION_ID PID ISO-8601-TIMESTAMP`, print absolute path on stdout
- Stdout MUST be empty on any non-zero exit
- Collision summary on stderr: slug, branch, `git -C <wt> rev-parse --short HEAD` + `git -C <wt> log -1 --format=%s`, lock age (now − TIMESTAMP), PID + live status
- Prompt branch (TTY and no-TTY both): read from `/dev/tty` if available else stdin; choices `abort` (exit 2) / `steal` (overwrite lock, exit 0)
- `release`: `git -C "$MROOT/.worktrees/$slug" status --porcelain` — if non-empty, error to stderr and exit non-zero; else `rm .wt-lock` and `git worktree remove <path>`; exit 0
- `chmod +x skills/worktree-lib.sh`

**Verify:**
```bash
# Happy path
bash skills/worktree-lib.sh ensure test-slug   # → prints path, exit 0
test -f "$MROOT/.worktrees/test-slug/.wt-lock"
bash skills/worktree-lib.sh release test-slug  # → exit 0

# Stale lock
bash skills/worktree-lib.sh ensure test2
echo "sess 999999 2026-01-01T00:00:00Z" > "$MROOT/.worktrees/test2/.wt-lock"
bash skills/worktree-lib.sh ensure test2       # → silently overwrites, exit 0

# Live collision (background sleep keeps PID alive)
sleep 300 & PID=$!
echo "sess $PID 2026-04-28T00:00:00Z" > "$MROOT/.worktrees/test2/.wt-lock"
bash skills/worktree-lib.sh ensure test2 </dev/null  # → exit 1 (or prompt)
kill $PID
```

---

### T2 — Update `skills/orchestrate/SKILL.md` Step 3

**Agent:** ic4 (extending existing pattern)
**Touches:** `skills/orchestrate/SKILL.md`
**Depends on:** T1

**Changes:**
- Replace any sibling-path worktree creation (`$MROOT/../$(basename $MROOT)-$ISSUE_ID`) with subprocess call:
  ```
  WT_PATH=$(bash skills/worktree-lib.sh ensure "$SLUG") || EXIT=$?
  ```
- Capture stdout into `WT_PATH`; check exit code:
  - `0`: proceed with `WT_PATH`
  - `1`: surface stderr to user, halt orchestration
  - `2`: halt cleanly (user aborted)
- Pass `WT_PATH` to downstream agent dispatch

**Verify:**
- `grep -nE 'sibling|/\.\./|MROOT/\.\.' skills/orchestrate/SKILL.md` returns no worktree-creation hits
- Step 3 references `worktree-lib.sh ensure`
- Halt behavior documented for exit 1 and exit 2

---

### T3 — Update `skills/wrap-ticket/SKILL.md` (Step 6 + grep fix + Step 0 detection)

**Agent:** ic4 (extending existing pattern; localized fixes)
**Touches:** `skills/wrap-ticket/SKILL.md`
**Depends on:** T1

**Changes:**
1. Step 6 (cleanup): replace direct `git worktree remove` for `.worktrees/` paths with `bash skills/worktree-lib.sh release "$SLUG"`. Keep legacy sibling-path removal logic for backward compat with already-open tickets.
2. Step 0 (detection): detect both `.worktrees/<slug>` (new) and `$MROOT/../<project>-<TICKET-ID>` (legacy); prefer new when both exist.
3. Anchor every TICKET-ID grep so `WISO-1` does not match `WISO-10`. Replace bare `grep "$TICKET_ID"` with `grep -wF "$TICKET_ID"` or `grep -E "(^|[^A-Z0-9-])${TICKET_ID}([^0-9]|$)"`. Apply EVERYWHERE wrap-ticket greps for ticket ID (search the file for all occurrences).

**Verify:**
- `grep -n 'TICKET_ID' skills/wrap-ticket/SKILL.md` shows every match is anchored (`-wF` or anchored regex)
- Step 6 calls `worktree-lib.sh release`
- Step 0 documents both new and legacy paths with new preferred

---

### T4 — Update `skills/demo/SKILL.md` inline worktree check

**Agent:** ic4 (small change)
**Touches:** `skills/demo/SKILL.md`
**Depends on:** —

**Changes:**
- Keep `$TMPDIR/demo-project` as the demo path. Do NOT call `worktree-lib.sh`.
- Add a 2-3 line inline check at the worktree creation step:
  ```
  if [ -e "$TMPDIR/demo-project" ]; then
    echo "demo-project already exists at $TMPDIR/demo-project — remove or rename, then re-run." >&2
    exit 1
  fi
  ```
- Document one-line rationale: demo is ephemeral and lives outside `$MROOT`, so it does not need lock/PID semantics.

**Verify:**
- demo SKILL.md does NOT reference `worktree-lib.sh`
- Inline existence check is present at worktree creation step

---

### T5 — Update `AGENTS.md` + `.gitignore`

**Agent:** ic4 (docs/config)
**Touches:** `AGENTS.md`, `.gitignore`
**Depends on:** —

**Changes:**
1. `AGENTS.md`: add "Worktree Protocol" section containing:
   - `.worktrees/<slug>` is the canonical path for plugin-managed worktrees
   - Use `bash skills/worktree-lib.sh ensure|release <slug>` — subprocess only, no sourcing
   - See `specs/core/SPEC-016-worktree-isolation.md` for the full contract
   - One sentence: sibling-directory worktrees (`$MROOT/../<project>-<id>`) are forbidden when the lib is in use
2. `.gitignore`: append `.worktrees/`

**Verify:**
- `grep -n "Worktree Protocol" AGENTS.md` matches
- `grep -n "SPEC-016" AGENTS.md` matches
- `grep -n "^.worktrees/" .gitignore` matches

---

## Sequencing summary

| Wave | Tasks | Notes |
|------|-------|-------|
| 1 | T1, T4, T5 (parallel) | T4 and T5 do not depend on T1; start all three together |
| 2 | T2, T3 (parallel) | After T1 lands |

## Out of scope

- `/worktree` user-facing skill (deferred to backlog per brainstorm)
- Migration of currently-open tickets using legacy sibling paths (wrap-ticket retains legacy detection; no forced migration)
- CI `--no-prompt` flag for `ensure` (open question in spec)
