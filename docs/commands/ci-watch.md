# /ci-watch

Autonomous CI/test polling and recovery for a single ticket. **Not
user-invoked — armed by `/orchestrate`** after the first push. A cron drives a
self-contained poll loop until the ticket's PR is green, merged, closed, or
the retry cap is hit.

## Behavior

- Polls every 7 minutes; spawns a fixer agent on failure (max 3), self-cleans
  when green.
- Prefers durable `CronCreate`; falls back to session-only when the harness
  denies durable.

## Modes

`detect-mode.sh <worktree>` selects exactly one of:

| Mode | Trigger | Poll mechanism |
|------|---------|----------------|
| `ci` | `.github/workflows/` + `gh auth status` + `gh pr checks` | `gh pr checks <PR> --json name,state,bucket` |
| `local-test` | `package.json scripts.test` / `Makefile test:` / `go.mod` / `pytest` | `timeout 120 bash -c "<cmd>"` in the worktree |
| `none` | Neither | Watch is **not armed** (skipped silently) |

## State

`$MROOT/.claude/ci-watch/<TICKET>.json` plus optional `<TICKET>.last_failure.txt`
(4 KiB cap) and `<TICKET>.log`. The sidecar schema is owned by `sidecar.sh`.

## See also

- [`/orchestrate`](orchestrate.md) — arms the watch after the first push
- `skills/ci-watch/SKILL.md` — the full protocol
