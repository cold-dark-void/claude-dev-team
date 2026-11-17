# /backlog

Backlog surface (SPEC-009). The local store — the `.claude/backlog.md` index
plus `.claude/backlog/<slug>.md` items — is the **source of truth** for ticket
records (CDT-646). Linear is an **opt-in per-project mirror** behind the
`linear_sync` key: `off` (default) = every path is local with zero Linear MCP
calls; `on` = the local write lands first and the mirror second, and a mirror
failure never blocks the Surface.

Set the key once per project with `skills/backlog/linear-gate.sh set --root
<root> on` (it writes `.claude/dev-team/config.json`). The key is read by that
one helper and nothing else.

Process trackers under `.claude/` — the store, its index, and that config — are
never staged or committed as product delivery.

## Usage

```
/backlog add <title>
/backlog claim <slug-or-title>
/backlog close <slug-or-title>
/backlog reconcile
/backlog list
/backlog sweep [flags]
/backlog init
```

| Sub | Action |
|-----|--------|
| `add <title>` | Write the local item (the record); Linear mirror when `linear_sync=on` |
| `claim <slug-or-title>` | Stamp the local item `IN_PROGRESS` + owner (local only) |
| `close <slug-or-title>` | Flip local `COMPLETED`; Linear terminal when `linear_sync=on` |
| `reconcile` | Repair index ↔ item files (+ Linear via `--linear-verdicts`, `on` path only) |
| `list` | The local index (the record); Linear open issues as the mirror when `on` |
| `sweep [flags]` | Purge pre-pass over the open set, then a serial size-ascending walk (`skills/backlog/sweep.md`) |
| `init` | Initialize the local backlog structure (if not present) |
| _(none)_ | Same as `list` |

### `sweep` flags

| Flag | Effect |
|------|--------|
| `--ship=<pr\|master\|patch\|minor\|major\|auto>` | Compiled to `/orchestrate` autopilot argv; sweep `--autopilot` defaults it to `master`; omitted = attended, so the walk runs with no autopilot flag. `auto` = the ship gate decides the bump per item (SPEC-041) |
| `--limit <N>` | Bounds code-bearing `/orchestrate` runs only; the purge stays full; the items the bound truncates are `SKIP`-counted |
| `--project <X>` | Filters the Linear query only (`linear_sync=on`; ignored when off) |
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

- **Offline ticket verbs.** `skills/backlog/ticket.sh create|claim|close` is the
  ticket CLI over the local store: a ticket, an epic, and an epic child are
  created, claimed, and closed with zero network and zero Linear MCP calls. Each
  verb prints `store: <root>/.claude/backlog` and exits 0 (ok), 1 (verb failure:
  no match, closed item, lock timeout), or 64 (usage, or a query that matches
  more than one item).
  `--kind ticket|epic|child` writes the item frontmatter (with `epic_parent`,
  `child_id`, `depends_on`, `estimate`, `agent`).
- `add` writes the item file first and derives the slug from the title;
  a `(b) Abort` dedup branch never silently merges two items.
- `claim` sets `**Status**: IN_PROGRESS (<owner>)`, adds a `*Claimed:*` footer,
  and re-tags the index row in place under `## Pending` — a claimed item stays
  visible to `list`, `sweep`, and `reconcile`. It refuses a closed item.
- Close writes the `close-note` trailer with a real newline (never a literal
  `\n`).
- Every linked worktree reads and writes the one shared store
  (`$MROOT/.claude/backlog/`), under one shared `mkdir` lease.

## See also

- [Specs runbook](../runbooks/specs.md) — where backlog items land as specs
- `skills/backlog/SKILL.md` — write-back protocol used by `/refactor` auto-chain
