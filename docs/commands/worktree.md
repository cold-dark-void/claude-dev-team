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
| `release <slug>` | Confirm in chat, then remove lock + worktree if clean |
| `status` / `list` / _(none)_ / unknown | Print usage (point to `/status worktree`) and stop |

Slug rules: `[A-Za-z0-9_-]+` only. Reject empty or invalid slugs before release.

## Listing (read-only)

```
/status worktree
```

## See also

- Contract: `specs/core/SPEC-016-worktree-isolation.md`
- Lib (subprocess only): `skills/worktree-lib.sh`
- AGENTS.md Worktree Protocol
