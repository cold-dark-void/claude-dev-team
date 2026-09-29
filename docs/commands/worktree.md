# /worktree

User-facing **mutate-only** surface for SPEC-016 worktrees. Thin dispatch over
`skills/worktree-lib.sh` for **release** only — never source the lib; never call
`git worktree` directly from this command.

Read-only listing moved to [`/status worktree`](./status.md). This command is
**not** a deprecation stub — it remains the live path for removing worktrees.

## Usage

```
/worktree release <slug>
```

| Args | Action |
|------|--------|
| `release <slug>` | Show a preview, ask for confirmation, then remove the worktree. Release never force-removes. It deletes `feat/<slug>` only when it is merged, and keeps an unmerged branch with a warning. |
| `status` / `list` / _(none)_ / unknown | Print usage (point to `/status worktree`) and stop |

Slug rules: `[A-Za-z0-9_-]+` only. Reject empty or invalid slugs before release.

## Before it asks

`release <slug>` runs `worktree-lib.sh release --preview <slug>` first. The
preview shows the counts: how many commits the branch has ahead of its base
and ahead of its upstream, and whether the branch is merged and pushed.

- If the branch is not merged, `/worktree` requires the typed slug as
  confirmation. A plain yes does not count.
- If the branch is merged, a plain yes or no answer is enough.

## Listing (read-only)

```
/status worktree
```

## See also

- Contract: `specs/core/SPEC-016-worktree-isolation.md`
- Lib (subprocess only): `skills/worktree-lib.sh`
- AGENTS.md Worktree Protocol
