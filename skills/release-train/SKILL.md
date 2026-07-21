---
name: release-train
description: |
    Multi-branch release queue sequencer (SPEC-023). Register ready feature
    branches, freeze deterministic landing order + slot versions, land each
    branch as uncommitted tree on master/main, mechanically pre-resolve known
    conflict classes (TDD index, Version-History, CHANGELOG, version JSON), then
    invoke /release with the explicit assigned version. Abort-safe, dry-run,
    never reimplements /release internals.
---

# Release Train

Sequencer for shipping several ready branches that race the same next version
and touch the same hot files. **Not a releaser** — all commit/tag/push go
through `/release <assigned_version>` (SPEC-010). Mechanical state lives in
`bash skills/release-train/train-lib.sh` (subprocess only).

**Usage**: `/release-train {register,list,drop,start,dry-run,status} …`

Governing spec: `specs/core/SPEC-023-release-train-queue.md`.

## Subcommands → train-lib + agent steps

| User cmd | Mechanical | Agent |
|----------|------------|-------|
| `register <branch> [--bump minor\|patch] [--assumed V]` | `train-lib.sh register …` | optional `detect-assumed` if `--assumed` omitted |
| `list` / `status` | `train-lib.sh list` | pretty-print |
| `drop <branch>` | `train-lib.sh drop` | confirm pending-only |
| `dry-run` | `freeze --print-only` (or `show-plan` if frozen) | print plan; **zero mutation** |
| `start` | lock → freeze → landing loop | merge-squash, M5, **invoke `/release`**, status |

## Preconditions (M13)

Before the landing loop:

1. Current branch is `master` or `main`
2. Working tree clean, or dirty from a prior train run → `restore <base_sha>`
3. Queue has ≥1 non-landed entry
4. Plan frozen (`assigned_version` set for all pending) — freeze on `start` if needed
5. Advisory lock acquired (`acquire-lock`)

Check with:

```bash
bash skills/release-train/train-lib.sh preflight
```

Exit 0 and stdout `ok` means clean on master/main. Non-zero prints `wrong-branch:…` and/or `dirty`.

## Register / list / drop

```bash
bash skills/release-train/train-lib.sh init
bash skills/release-train/train-lib.sh register feat/foo --bump minor
bash skills/release-train/train-lib.sh register feat/bar --bump patch --assumed 0.40.0
bash skills/release-train/train-lib.sh list
bash skills/release-train/train-lib.sh drop feat/bar
```

- `register` requires the branch ref to exist (`git rev-parse --verify`).
- Default bump is `minor`.
- If `--assumed` omitted, run `detect-assumed <branch>` and re-register or
  `set` via queue edit only through train-lib (register again after drop if needed).
  Prefer passing `--assumed` when known.
- `drop` only allows `pending` entries.

Detect assumed version:

```bash
bash skills/release-train/train-lib.sh detect-assumed feat/foo
```

## Dry-run (M9)

**Never** writes status transitions or freezes permanently for dry-run alone.

```bash
bash skills/release-train/train-lib.sh freeze --print-only
```

If already frozen:

```bash
bash skills/release-train/train-lib.sh show-plan
```

Print order, assigned versions, assumed→assigned renumber plan, and note that
predicted conflicts are the four enumerated classes (TDD index, VH, CHANGELOG,
version JSON). Confirm `git status --porcelain` unchanged and queue JSON
statuses unchanged after dry-run.

## Start — landing loop

### 0. Lock and freeze

```bash
bash skills/release-train/train-lib.sh acquire-lock
bash skills/release-train/train-lib.sh freeze
bash skills/release-train/train-lib.sh show-plan
```

Always `release-lock` on every exit path (success, block, user abort).

Optional order override:

```bash
bash skills/release-train/train-lib.sh freeze --order feat/a,feat/b
```

### 1. For each entry in `order` where `status != landed`

#### 1a. Verify prior landed tags (M8)

For each earlier entry with `status=landed` and a recorded `tag`:

```bash
bash skills/release-train/train-lib.sh verify-tag vX.Y.Z
```

If verify fails, stop and report — do not re-release.

#### 1b. Mark landing; record base

```bash
BASE=$(git rev-parse HEAD)
bash skills/release-train/train-lib.sh set-status <branch> landing --base-sha "$BASE"
```

#### 1c. Present branch as uncommitted tree (M4)

```bash template
git merge --squash <branch>
```

Do **not** create a merge commit. Leave the index/working tree uncommitted for
`/release`.

#### 1d. Conflict triage (M5 / M6)

List unmerged paths:

```bash
git diff --name-only --diff-filter=U
```

**Allowlist** (mechanical resolve only):

- `specs/TDD.md` (Spec Index + Version-History)
- any `specs/**` Version-History table
- `CHANGELOG.md`
- `.claude-plugin/plugin.json`
- `.claude-plugin/marketplace.json`

If **any** other path is conflicted → **M6 halt**:

```bash
BASE=$(git rev-parse HEAD)   # or the base_sha recorded at landing start
# Prefer queue base_sha when present:
# BASE=$(bash skills/release-train/train-lib.sh list | jq -r --arg b '<branch>' '.entries[]|select(.branch==$b)|.base_sha')
bash skills/release-train/train-lib.sh restore "$BASE"
bash skills/release-train/train-lib.sh set-status <branch> blocked --paths path1,path2
bash skills/release-train/train-lib.sh release-lock
```

Stop the train. No skip-and-recompute in v1.

#### 1e. Mechanical pre-resolve (M5a–d)

Resolve allowlisted conflicts / dual trees. File-flag form (also used by tests):

```bash template
# M5a Spec Index
bash skills/release-train/train-lib.sh resolve-tdd-index \
  --ours /path/ours-TDD.md --theirs /path/theirs-TDD.md --out specs/TDD.md

# M5b Version-History (same or other spec files)
bash skills/release-train/train-lib.sh resolve-vh \
  --ours /path/ours.md --theirs /path/theirs.md --out specs/TDD.md

# M5c CHANGELOG — single heading for assigned version; body from branch
bash skills/release-train/train-lib.sh resolve-changelog <assigned> \
  --branch-file /path/branch-CHANGELOG.md \
  --master-file /path/master-CHANGELOG.md \
  --out CHANGELOG.md

# M5d version JSON
bash skills/release-train/train-lib.sh resolve-json <assigned>
```

Obtain ours/theirs via `git show <base>:path` and `git show <branch>:path` when
the squash left a clean or conflicted tree.

#### 1f. Renumber assumed → assigned (M3)

If `assumed_version` is non-null and differs from `assigned_version`:

```bash template
bash skills/release-train/train-lib.sh renumber <assumed> <assigned>
```

Touches only CHANGELOG headings + the two JSON version fields on the **working
tree** (never the source branch).

Ensure exactly one `### v<assigned>` CHANGELOG heading with a non-empty body
before continuing (M5c / skip-if-present contract).

#### 1g. AGENT STEP — invoke `/release` (M7)

**You (the agent) must run the `/release` skill** with the explicit assigned
version only:

```
/release <assigned_version>
```

Examples: `/release 0.40.0` or `/release v0.40.0`.

Because the train pre-wrote the CHANGELOG heading, `/release` uses
**skip-if-present** (explicit version + non-empty body) for Steps 2–3a — see
`skills/release/SKILL.md`. Do **not** pass bare `/release` (auto-detect would
mis-fire mid-train).

`/release` owns: remaining triplet sync, drift gates, single folded commit, tag,
push.

#### 1h. On `/release` failure → restore + blocked

```bash
BASE=$(bash skills/release-train/train-lib.sh list | jq -r --arg b '<branch>' \
  '.entries[] | select(.branch==$b) | .base_sha')
bash skills/release-train/train-lib.sh restore "$BASE"
bash skills/release-train/train-lib.sh set-status <branch> blocked
bash skills/release-train/train-lib.sh release-lock
```

Stop. Report the `/release` error to the user.

#### 1i. On success → landed

```bash template
bash skills/release-train/train-lib.sh set-status <branch> landed --tag v<assigned>
```

Print summary line: `<branch> → v<assigned> (tag pushed)`.

Continue to the next non-landed entry.

### 2. After the loop

```bash
bash skills/release-train/train-lib.sh release-lock
```

Print final train summary table from `list`. Suggest per-branch follow-up
`/wrap-ticket` (do not run it — SPEC-016/SPEC-009).

## Resume (M8)

On restart / `start` again:

1. `preflight` — if dirty, restore using the `landing` entry's `base_sha` (or last
   known clean tip)
2. `acquire-lock`
3. For each `landed` entry: `verify-tag` before skipping
4. Resume at first entry whose status is not `landed` (typically `pending` or
   re-attempt after user fixed a `blocked` entry offline — user must
   re-register/re-freeze as needed; no auto-skip)

Status transitions only (M15): `pending→landing`, `landing→landed`,
`landing→blocked`. No `skipped` in v1.

## MUST NOT (M10 / M11)

- MUST NOT perform tagging, pushing, or committing from the train skill or
  train-lib — only `/release` does that
- MUST NOT invent commit-message templates, changelog bullets, or drift-gate
  invocations in train-lib
- MUST NOT mutate queued source branches (no rebase, no renumber on the branch)
- MUST NOT land two entries concurrently
- MUST NOT auto-resolve conflicts outside the allowlist

## Queue location

`$MROOT/.claude/release-train/queue.json` where MROOT is the shared project root
from `git rev-parse --git-common-dir` (not worktree-local only). Gitignored.
Advisory lock: `.claude/release-train/train.lock`.

## Tests

```bash
bash skills/release-train/test.sh
bash skills/release-train/test-integration.sh
```
