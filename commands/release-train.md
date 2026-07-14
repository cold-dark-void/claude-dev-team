---
name: release-train
description: |
    Multi-branch release queue (SPEC-023). Register ready branches, list/drop
    queue entries, dry-run the frozen plan, or start the landing loop that
    merge-squashes each branch onto master and drives /release with an explicit
    assigned version. Sequencer only — never reimplements /release.
argument-hint: "register <branch> | list | drop <branch> | start | dry-run | status"
---

# /release-train

Thin entrypoint for the release-train skill. Full protocol:
`skills/release-train/SKILL.md`. Mechanical CLI:
`bash skills/release-train/train-lib.sh <cmd> …`.

## Args

| Args | Action |
|------|--------|
| `register <branch> [--bump minor\|patch] [--assumed V]` | Queue a branch (manual only) |
| `list` / `status` | Show queue JSON / human summary |
| `drop <branch>` | Remove a **pending** entry |
| `dry-run` | Print order + slot versions; zero mutation |
| `start` | Freeze (if needed), lock, land each entry via skill loop |

## Routing

1. Resolve plugin/skill paths; prefer cwd repo root (`git rev-parse --show-toplevel`).
2. Ensure queue dir: `bash skills/release-train/train-lib.sh init`
3. Dispatch:

```bash
# register
bash skills/release-train/train-lib.sh register "$BRANCH" --bump "${BUMP:-minor}"

# list / status
bash skills/release-train/train-lib.sh list

# drop
bash skills/release-train/train-lib.sh drop "$BRANCH"

# dry-run (no freeze write; no status changes)
bash skills/release-train/train-lib.sh freeze --print-only

# start — follow skills/release-train/SKILL.md landing loop end-to-end
# including AGENT STEP: /release <assigned_version> per entry
```

4. For `start` and `dry-run`, load and execute the full skill protocol (preflight,
   lock, freeze, merge-squash, M5 resolvers, `/release`, resume rules). Do not
   improvise release internals here.
