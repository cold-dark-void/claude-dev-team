# Skills

This directory holds engines, protocols, and libraries.

Read the layout rule in [AGENTS.md — Commands and skills](../AGENTS.md#commands-and-skills).
Do not copy that rule here.

## Library exceptions (no SKILL.md)

These four entries are libraries. They have no `SKILL.md` by design:

| Path | Role |
|------|------|
| `skills/plugin-dir.sh` | Plugin-root resolver |
| `skills/worktree-lib.sh` | Worktree create and release CLI |
| `skills/agent-memory/` | Agent memory protocol partials |
| `skills/notify/` | Webhook helper |

Resolve them through `plugin-dir.sh`. Do not add a `SKILL.md` only to silence `/doctor`.

## `/mode` backends

`skills/focus/` and `skills/blunt/` are live `/mode` backends.
They carry `user-invocable: false`. They are not libraries.

Keep them until `/mode` inlines the protocol. Planned removal: v1.19.0.
