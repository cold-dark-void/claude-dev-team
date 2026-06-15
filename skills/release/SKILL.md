---
name: release
description: |
    Bump version across all required files (README.md changelog, plugin.json,
    marketplace.json), commit, tag, and push. Use when releasing any version of
    this plugin. Ensures all three version files stay in sync — never skips any
    of them.
---

# Release

Bumps the version in all required files, then folds the release into a SINGLE
commit (the actual change + the version bump together), tags, and pushes.

This repo uses **one commit per release**: the work being released is usually
still uncommitted in the working tree when `/release` runs (HEAD sits on the last
tag). So this skill stages the changed source files *and* the version files into
one `fix:/feat: vX.Y.Z — <summary>` commit. It does NOT assume the work was
committed separately, and it does NOT create a standalone `chore: release` commit.

**Usage**: `/release [patch|minor|major|vX.Y.Z]`

## Step 1: Determine new version

Read `.claude-plugin/plugin.json` to get the current `"version"` field.

Resolve the new version using these rules (first match wins):

1. **Explicit version in args** (e.g. `v0.14.0` or `0.14.0`) → use it directly
2. **Bump keyword in args** (`patch`, `minor`, or `major`) → compute from current version
3. **No args provided** → auto-detect from everything being released — BOTH
   commits since the last tag AND the current uncommitted changes:
   - `git log $(git describe --tags --abbrev=0)..HEAD --oneline` — committed since tag
   - `git status --short` and `git diff --stat HEAD` — uncommitted work (usually the bulk)
   - If the release adds a new user-facing capability (or any commit subject contains
     `feat:`/`feat(`) → **minor**; otherwise → **patch**
   - Tell the user what you chose and why (e.g. "Auto-detected **patch** — hardening, no new feature")

Version format: no `v` prefix in files, `v` prefix for git tag and changelog heading.

## Step 2: Generate changelog entry

**Do NOT ask the user for a description.** Auto-generate it from the actual
changes being released — which include uncommitted working-tree changes, not just
committed history:

1. Gather the full change set:
   - `git diff --stat HEAD` and `git status --short` — uncommitted work (usually the bulk)
   - `git log $(git describe --tags --abbrev=0)..HEAD --oneline --no-merges` — anything already committed since the last tag (exclude `chore: release` commits)
2. Read the actual diffs of changed files as needed to describe them accurately — do not infer from filenames alone.
3. Write the changelog as a bulleted Markdown list — one `- **bold summary** — detail` line per meaningful change, grouping granular edits.
4. Match the style of existing changelog entries in README.md (bold lead, concise but specific).

If there are NO uncommitted changes AND no commits since the last tag, tell the
user "Nothing to release — working tree clean and no commits since last tag" and stop.

## Step 3: Bump all three version files

**CRITICAL — all three must be updated. Never skip any.**

### 3a. `README.md`
Add a new `### vX.Y.Z` section at the top of the `## Changelog` section (above the previous version):
```markdown
### vX.Y.Z
- <changelog entries>
```

### 3b. `.claude-plugin/plugin.json`
Update `"version"` field to new version string.

### 3c. `.claude-plugin/marketplace.json`
Update `"version"` field inside the `plugins[]` array to new version string.

## Step 4: Verify all three match

Read all three files and confirm the version string is identical in:
- `README.md` changelog heading (`### vX.Y.Z`)
- `.claude-plugin/plugin.json` `"version"` field
- `.claude-plugin/marketplace.json` `"version"` field inside `plugins[]`

If any mismatch: fix before proceeding.

## Step 4.5: Include drift-check (pre-commit gate)

Run:
```bash
python3 skills/agent-memory/sync-includes.py check
```

If it exits non-zero, one or more managed include regions have drifted from their canonical partials (`skills/agent-memory/protocol.md` — the 7-agent `## Persistent Memory` block; `skills/agent-memory/cortex-load.md` — the debug/refactor tiered-cortex block). **Do NOT commit or tag.** Fix the drift first (re-expand the drifted region to match its partial via `python3 skills/agent-memory/sync-includes.py apply`), then re-run until it exits 0.

## Step 4.6: Council template-variable drift-check (pre-commit gate)

Run:
```bash
bash skills/council/check-template-vars.sh
```

If it exits non-zero, the council template-variable contract has drifted: `commands/council.md` substitutes a variable set that no longer matches a prompt's authoritative `## Variables` table (a dead substitution or a literal `{{VAR}}` leak into the spawned subagent, per SPEC-013). **Do NOT commit or tag.** Fix `commands/council.md` (and/or the prompt's `## Variables` table) so each covered prompt's substituted set exactly equals its declared set, then re-run until it exits 0. (Covered: claim-extractor, investigator, cross-reviewer, judge. Prosecutor/advocate are explicitly deferred to AUDIT-P1-4C and the gate logs them as unchecked.)

## Step 4.7: Hook-template drift-check (pre-commit gate)

Run:
```bash
bash skills/init-orchestration/check-hook-templates.sh
```

If it exits non-zero, a hook template emitted by `/init-orchestration` has drifted from this repo's canonical live `.claude/hooks/<name>.sh` (the gate names the drifted hook). Consumers would receive a broken/stale hook. **Do NOT commit or tag.** Re-sync the drifted template: replace the fenced ```bash block under its "create `.claude/hooks/<name>.sh` with this content:" marker in `skills/init-orchestration/SKILL.md` with the exact current content of the live hook, then re-run until it exits 0. (Covered: task-completed, stop-review, memory-capture, bash-compress.)

## Step 5: Commit (one folded commit)

Stage the version files **and the actual changed source files** — everything being
released goes into a single commit:
```bash
git add README.md .claude-plugin/plugin.json .claude-plugin/marketplace.json
git add <the source files this release changes>   # e.g. agents/*.md, skills/**, commands/*.md
```
Then check `git status --short`: confirm nothing intended is left unstaged and that
no unrelated/untracked files were swept in.

Commit message — **type-prefixed subject with the version inline, plus a
Co-Authored-By trailer. No `chore: release`. No prose body:**
```
<feat|fix>: vX.Y.Z — <one-line summary derived from the changelog lead bullet>

Co-Authored-By: Claude <Model> (1M context) <noreply@anthropic.com>
```
- `feat:` for feature releases, `fix:` for fixes/hardening — match the bump from Step 1.
- Em-dash (`—`) between version and summary, not a hyphen.
- `<Model>` = the model doing the work, e.g. `Claude Opus 4.8 (1M context)`. Keep the `(1M context)` suffix to match this repo's history.
- The README changelog carries the detail; the commit subject stays one line.

## Step 6: Tag and push

```bash
git tag vX.Y.Z
BRANCH=$(git rev-parse --abbrev-ref HEAD)
git push origin "$BRANCH" --tags
```

**If push fails due to sandbox restrictions**: tell the user to run the push manually and print the exact commands:
```
git push origin <branch> --tags
```

Confirm with: `git log --oneline -3` and `git tag --list 'v*' | tail -3`
