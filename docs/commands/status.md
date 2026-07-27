# /status

Read-only project snapshot hub (SPEC-009, SPEC-016). **Display-only** — never
mutates worktrees, locks, branches, ledgers, DBs, task stores, or outcomes.

| Engine | Path |
|--------|------|
| Standup | `skills/standup/SKILL.md` |
| Metrics | `skills/metrics/rollup.sh` |
| Worktree list | `skills/worktree-lib.sh status` |

## Usage

```
/status
/status standup [TICKET-ID]
/status metrics [--json] [--section all|council|outcomes|worktree]
/status worktree
```

| Args | Action |
|------|--------|
| _(none)_ | Sequence: standup → metrics (all) → worktree status |
| `standup [TICKET-ID]` | Standup snapshot only (former `/standup`) |
| `metrics […]` | Metrics rollup only (former `/metrics`; full flag parity) |
| `worktree` | Plugin worktree list/status only |
| unknown | Print usage and stop |

## Sub: `standup`

TaskList + agent `context.md` snapshot — blockers, stale tasks, READY set.
Optional `TICKET-ID` filter. Read-only; surfaces suggested actions only.

```
/status standup
/status standup CDT-46
```

## Sub: `metrics`

All-time rollup of council, outcomes, worktree/task counts.

```
/status metrics
/status metrics --json
/status metrics --section outcomes
/status metrics --json --section council
```

## Sub: `worktree`

Lists plugin-managed worktrees under `.worktrees/<slug>` (FRESH/STALE locks).
Does **not** release — for removal use [`/worktree release`](./worktree.md).

```
/status worktree
```

## See also

- [`/worktree`](./worktree.md) — mutate residual (`release` only)
- Legacy: [`/standup`](./standup.md) (prefer this surface)
- Protocol: `skills/standup/SKILL.md`, `skills/metrics/rollup.sh`
