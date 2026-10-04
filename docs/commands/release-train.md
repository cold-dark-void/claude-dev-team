# /release-train

Multi-branch release queue (SPEC-023). Register ready branches, list/drop
queue entries, dry-run the frozen plan, or start the landing loop that
merge-squashes each branch onto `master` and drives `/release` with an
explicit assigned version. Sequencer only — never reimplements `/release`.

## Usage

```
/release-train register <branch> [--bump minor|patch] [--assumed V]
/release-train list
/release-train status
/release-train drop <branch>
/release-train requeue <branch>
/release-train dry-run
/release-train start
```

| Sub | Action |
|-----|--------|
| `register <branch> [--bump minor\|patch] [--assumed V]` | Queue a branch (manual only). Pass `--bump` and `--assumed` explicitly — there is no silent default. |
| `list` | Show queue JSON |
| `status` | Human summary of the same queue (`show-plan`) |
| `drop <branch>` | Remove a **pending** or **blocked** entry |
| `requeue <branch>` | Move a **blocked** entry back to pending and clear the freeze |
| `dry-run` | Print order + slot versions; no queue or status mutation (the idempotent `init` in the routing step may create the queue dir if absent) |
| `start` | Freeze (if needed), lock, land each entry via the skill loop |

## Notes

- `--assumed V` records the assumed base version a branch was cut from;
  `detect-assumed` re-derives it when omitted at register time.
- The landing loop calls the `/release` skill per entry with an explicit
  assigned version — it never bumps by inference.
- Mechanical CLI: `train-lib.sh` resolved via `plugin-dir.sh`, subprocess only.

## See also

- [`/release`](release.md) — the per-entry release contract
- `skills/release-train/SKILL.md` — full protocol
