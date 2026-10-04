# /backlog

Linear-first backlog surface (SPEC-009). When the Linear MCP is reachable,
Linear is the preferred source of truth for **open** work; the local
`.claude/backlog.md` index plus `.claude/backlog/<slug>.md` items are a
**mandatory write-through cache** on every path. When MCP is down: local-only
with a one-line notice — never blocks.

Process trackers under `.claude/` are never staged or committed as product
delivery.

## Usage

```
/backlog add <title>
/backlog close <slug-or-title>
/backlog reconcile
/backlog list
/backlog init
```

| Sub | Action |
|-----|--------|
| `add <title>` | Create the Linear issue (if MCP up) + dual-write local |
| `close <slug-or-title>` | Mark Linear terminal (if MCP up) + flip local `COMPLETED` |
| `reconcile` | Repair index ↔ item files (+ Linear via `--linear-verdicts`) |
| `list` | Prefer Linear open issues when MCP up; else the local index |
| `init` | Initialize the local backlog structure (if not present) |
| _(none)_ | Same as `list` |

## Notes

- `add` writes the item file first and derives the slug from the title;
  a `(b) Abort` dedup branch never silently merges two items.
- Close writes the `close-note` trailer with a real newline (never a literal
  `\n`).
- Every linked worktree reads and writes the one shared store
  (`$MROOT/.claude/backlog/`).

## See also

- [Specs runbook](../runbooks/specs.md) — where backlog items land as specs
- `skills/backlog/SKILL.md` — write-back protocol used by `/refactor` auto-chain
