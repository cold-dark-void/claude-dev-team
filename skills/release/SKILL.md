---
name: release
description: Bump version across all required files (README.md changelog, plugin.json,
  marketplace.json), commit, tag, and push. Use when releasing any version of this
  plugin. Ensures all three version files stay in sync — never skips any of them.
---

# Release

Bumps the version in all required files, commits, tags, and pushes.

**Usage**: `/release [patch|minor|major|vX.Y.Z]`

## Step 1: Determine new version

Read `.claude-plugin/plugin.json` to get the current `"version"` field.

Resolve the new version using these rules (first match wins):

1. **Explicit version in args** (e.g. `v0.14.0` or `0.14.0`) → use it directly
2. **Bump keyword in args** (`patch`, `minor`, or `major`) → compute from current version
3. **No args provided** → auto-detect:
   - Run `git log $(git describe --tags --abbrev=0)..HEAD --oneline` to see commits since last tag
   - If ANY commit message contains `feat:` or `feat(` → **minor**
   - Otherwise → **patch**
   - Tell the user what you chose and why (e.g. "Auto-detected **patch** — no feat: commits since v0.13.2")

Version format: no `v` prefix in files, `v` prefix for git tag and changelog heading.

## Step 2: Generate changelog entry

**Do NOT ask the user for a description.** Auto-generate it from git history:

1. Run `git log $(git describe --tags --abbrev=0)..HEAD --oneline --no-merges` to get commits since last tag
2. Exclude any `chore: release` commits
3. Write the changelog as a bulleted Markdown list — one `- **summary**` line per meaningful commit
4. If commits are very granular, group related ones into a single bullet
5. Match the style of existing changelog entries in README.md (bold lead, concise description)

If there are zero non-release commits since the last tag, tell the user "Nothing to release — no commits since last tag" and stop.

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

## Step 5: Commit

Stage all three files:
```
git add README.md .claude-plugin/plugin.json .claude-plugin/marketplace.json
```

Commit with message:
```
chore: release vX.Y.Z
```

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
