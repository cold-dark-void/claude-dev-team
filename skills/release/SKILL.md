---
name: release
description: Bump version across all required files (README.md changelog, plugin.json,
  marketplace.json), commit, tag, and push. Use when releasing any version of this
  plugin. Ensures all three version files stay in sync — never skips any of them.
---

# Release

Bumps the version in all required files, commits, tags, and pushes.

## Step 1: Determine new version

If the user provided a version (e.g. `v0.9.2` or `0.9.2`), use it.

Otherwise:
1. Read `.claude-plugin/plugin.json` — note current `"version"` field
2. Ask the user: "Current version is X.Y.Z — patch (X.Y.Z+1), minor (X.Y+1.0), or major (X+1.0.0)?"
3. Wait for answer, compute new version string (without `v` prefix for files, with `v` prefix for git tag)

## Step 2: Get changelog entry

If the user provided a description, use it.
Otherwise ask: "What changed in this release? (one line)"

## Step 3: Bump all three version files

**CRITICAL — all three must be updated. Never skip any.**

### 3a. `README.md`
Add a new `### vX.Y.Z` section at the top of the `## Changelog` section (above the previous version):
```markdown
### vX.Y.Z
- <changelog entry>
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
git push origin master --tags
```

Confirm with: `git log --oneline -3` and `git tag --list 'v*' | tail -3`
