# /epic

Umbrella decomposition and sequenced orchestration over the single-ticket
pipeline (`/kickoff` / `/orchestrate`). PM and Tech Lead jointly split an epic
into child tickets with a cross-ticket dependency DAG; approved children land
in the backlog (Linear optional); execution walks ready children one at a time
with a confirm-before-handoff gate. **Composition only** — never reimplements
the ticket lifecycle.

Governing spec: `specs/core/SPEC-025-epic-umbrella-decomposition.md`.
Full protocol: `skills/epic/SKILL.md`. CLI: `bash skills/epic/epic-lib.sh`.

## Usage

```
/epic <EPIC-ID> "<epic text>"
/epic <EPIC-ID>
/epic status [<EPIC-ID>]
/epic --redecompose <EPIC-ID> "<text>"
/epic complete <EPIC-ID> <CHILD-ID>
/epic block <EPIC-ID> <CHILD-ID>
/epic unblock <EPIC-ID> <CHILD-ID>
```

## Flags / arguments

| Flag / Argument | Description |
|-----------------|-------------|
| `<EPIC-ID>` | Epic key (e.g. `CDV-30`). Child IDs become `CDV-30-C1`, `C2`, … |
| `"<epic text>"` | Umbrella description for decomposition |
| `status` | Print rollup from `state.json` |
| `--redecompose` | Re-plan non-completed children (requires confirmation) |
| `complete` / `block` / `unblock` | Manual child status transitions |

## Behavior summary

1. **Decompose** (no existing state): parallel PM + TL (`Output mode: terse`),
   merge five fields per child, `dag-lib.sh check-cycle`, user approval, then
   backlog + `state.json` (+ best-effort Linear).
2. **Execute / resume** (state exists): rollup → `ready-set` → confirm → hand
   off to recorded mode (`kickoff` \| `orchestrate`) with **mandatory PM**.
3. **Standup**: active epics appear under `## Epics` via `epic-lib.sh rollup`.
4. **wrap-ticket**: marks matching child `completed` via `mark-done` (soft).

## Examples

```
/epic CDV-30 "Ship feature X across API, CLI, and docs"
/epic CDV-30
/epic status CDV-30
/epic complete CDV-30 CDV-30-C1
```

## See also

- [`/kickoff`](kickoff.md) — plan-only child handoff target
- [`/orchestrate`](orchestrate.md) — full lifecycle child handoff target
- [`/standup`](standup.md) — epic rollup section
- [`/wrap-ticket`](wrap-ticket.md) — child completion write-back
