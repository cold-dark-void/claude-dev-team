# /epic

Umbrella decomposition and sequenced orchestration over the single-ticket
pipeline (`/kickoff` / `/orchestrate`). PM and Tech Lead jointly split an epic
into child tickets with a cross-ticket dependency DAG; approved children land
in the backlog (Linear optional); execution walks ready children one at a time
with a confirm-before-handoff gate. **Composition only** (SPEC-025 M11) — never
reimplements the ticket lifecycle. **M14 carve-out:** may ensure one integration
worktree (`epic-<ID>`) and compose end-of-epic seal; does not re-implement
orchestrate WT lifecycle or `/release` version contract.

Governing spec: `specs/core/SPEC-025-epic-umbrella-decomposition.md` (M14 CLI
table, illegal combos, done-when 1–7, non-public API).
Full protocol: `skills/epic/SKILL.md`. CLI: `bash skills/epic/epic-lib.sh`.

## Usage

```
/epic <EPIC-ID> "<epic text>"
/epic <EPIC-ID>
/epic <EPIC-ID> --worktree
/epic <EPIC-ID> --worktree --release <patch|minor|major>
/epic status [<EPIC-ID>]
/epic --redecompose <EPIC-ID> "<text>"
/epic complete <EPIC-ID> <CHILD-ID>
/epic block <EPIC-ID> <CHILD-ID>
/epic unblock <EPIC-ID> <CHILD-ID>
/epic sync <EPIC-ID> [--dry-run]
```

## Flags / arguments

| Flag / Argument | Description |
|-----------------|-------------|
| `<EPIC-ID>` | Epic key (e.g. `CDV-30`). Child IDs become `CDV-30-C1`, `C2`, … |
| `"<epic text>"` | Umbrella description for decomposition |
| `status` | Print rollup from `state.json` |
| `--redecompose` | Re-plan non-completed children (requires confirmation) |
| `complete` / `block` / `unblock` | Manual child status transitions |
| `sync [--dry-run]` | Refresh existing `state.json` from Linear (M15) when stale — fill null `linear_id`/project, pull status forward, never re-open `completed`; orphans report-only. Illegal with `--worktree`/`--release`. |
| `--worktree` | (decompose/execute/resume/`--redecompose` only) Integration-worktree mode (SPEC-025 M14). Bare boolean only. Ensures one `$MROOT/.worktrees/epic-<ID>` tree; all children share it. Resume omit → honor store. Illegal on `status`/`complete`/`block`/`unblock`/`sync`. |
| `--release <bump>` | (with `--worktree` only) End-of-epic release intent; `<bump>` ∈ {patch,minor,major}. Space form canonical; `--release=<bump>` alias. After last child: seal once → one `/release <bump>` → `sealed=true`. Without this flag: no epic seal. |

### Hard-fail rules (exit 64, zero side effects)

- `--release` without `--worktree`; bare/empty/`each`/`end` bump; illegal bump
- `--worktree=*` / value forms; duplicate flags
- Flags on `status` \| `complete` \| `block` \| `unblock` \| `sync`
- Resume flags that conflict with durable state (no silent downgrade)

**Not public surface:** `--bump`, `--land`, `--seal` flags; `--worktree` mode
enums; `--release each|end`. (Internal `epic-lib seal` / `seal-ready` are
mechanical subcommands, not `/epic` flags.)

## Behavior summary

1. **Decompose** (no existing state): parallel PM + TL (`Output mode: terse`),
   merge five fields per child, `dag-lib.sh check-cycle`, user approval, then
   backlog + `state.json` (+ best-effort Linear). Optional M14 flags persist
   `worktree_enabled` / `release_bump`.
2. **Execute / resume** (state exists): rollup → `ready-set` → confirm → hand
   off to recorded mode (`kickoff` \| `orchestrate`) with **mandatory PM**.
   With `--worktree`: children use the shared `epic-<ID>` tree.
   `--autopilot`: Mode B keeps walking until B.3 halt/`n`, empty ready-set,
   all children completed (B.7 iff `release_bump`), only blocked/in_progress,
   M13 seed-fail, or user interrupt — not after the first shipped child.
3. **Mid-epic forbid (release=end):** when `release_bump` set and not sealed,
   `/release` and master-merge hard-fail (exit 64) until seal. When
   `release_bump` is null/absent, `/release` Step 0 prints a warn-only
   mid-epic ship gap callout if other children are still incomplete (M16;
   not a hard fail).
4. **Seal (CDT-141-C5):** when epic used `--worktree --release <bump>` and all
   children are completed, Mode B.7 runs once: `seal-ready` / `seal` squash-stage
   → one `/release <bump>` → `sealed=true`. Without `--release`, no seal path.
5. **Standup**: active epics appear under `## Epics` via `epic-lib.sh rollup`.
6. **wrap-ticket**: marks matching child `completed` via `mark-done` (soft);
   MUST NOT release the integration worktree slug.
7. **Sync (M15):** `/epic sync <ID>` pulls Linear status/`linear_id` into local
   state when it may be stale; never re-decomposes or creates issues.

## Examples

```
/epic CDV-30 "Ship feature X across API, CLI, and docs"
/epic CDV-30 --worktree --release minor
/epic CDV-30
/epic status CDV-30
/epic complete CDV-30 CDV-30-C1
```

## See also

- [`/kickoff`](kickoff.md) — plan-only child handoff target
- [`/orchestrate`](orchestrate.md) — full lifecycle child handoff target
- [`/release`](../../skills/release/SKILL.md) — sole ship-of-record at seal
- [`/status standup`](status.md) — epic rollup section
- [`/wrap-ticket`](wrap-ticket.md) — child completion write-back
