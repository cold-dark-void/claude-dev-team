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
/backlog sweep [flags]
/backlog init
```

| Sub | Action |
|-----|--------|
| `add <title>` | Create the Linear issue (if MCP up) + dual-write local |
| `close <slug-or-title>` | Mark Linear terminal (if MCP up) + flip local `COMPLETED` |
| `reconcile` | Repair index ↔ item files (+ Linear via `--linear-verdicts`) |
| `list` | Prefer Linear open issues when MCP up; else the local index |
| `sweep [flags]` | Purge pre-pass over the open set, then a serial size-ascending walk (`skills/backlog/sweep.md`) |
| `init` | Initialize the local backlog structure (if not present) |
| _(none)_ | Same as `list` |

### `sweep` flags

| Flag | Effect |
|------|--------|
| `--ship=<pr\|master\|patch\|minor\|major>` | Compiled to `/orchestrate` autopilot argv; sweep `--autopilot` defaults it to `master`; omitted = attended, so the walk runs with no autopilot flag |
| `--limit <N>` | Bounds code-bearing `/orchestrate` runs only; the purge stays full; the items the bound truncates are `SKIP`-counted |
| `--project <X>` | Filters the Linear query only |
| `--refresh` | Re-judge every item; ignore the journal |
| `--skip-decided` | Skip every item with a terminal journal outcome |
| `--autopilot` | Ask nothing; every would-be ASK becomes `DEFER` |

A sweep closes stale items only on Mechanical evidence (cited paths absent at
HEAD, or a fix shipped after the item was added). Everything else is `ASK`
attended, or `DEFER` under `--autopilot`. Each decision appends one line to
`$MROOT/.claude/sweeps/<slug>.jsonl`; that journal is process state and is never
committed. A sweep never edits product code and never runs `/release`.
Spec: SPEC-040.

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
