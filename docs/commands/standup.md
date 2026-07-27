# /standup

> **Prefer [`/status standup`](./status.md)** — status hub absorbs standup as of
> v1.0-W3 (CDT-46-C4). This page remains for link stability.

Instant status snapshot of active agent team work. Reads the task system and each
agent's `context.md` to surface what is in progress, what is blocked, and what is
ready to claim — without interrupting agents mid-task.

## Replacement

```
/status standup
/status standup POC-123
/status                 # bare: standup → metrics → worktrees
```

Full reference: [`/status`](./status.md). Protocol retained in
`skills/standup/SKILL.md` (skill-delegate backend).

## See also

- [`/status`](./status.md) — primary read-only hub
- [`/worktree`](./worktree.md) — release only (list via `/status worktree`)
