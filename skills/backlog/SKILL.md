---
name: backlog
description: Manage project backlog items stored in .claude/backlog/ (index at .claude/backlog.md). Supports add, close, list, and init subcommands. Use when adding backlog items, closing/completing backlog items, listing the backlog, or initializing the backlog structure in a project.
---

# Backlog Manager

Manages a project backlog using `.claude/backlog.md` as an index and `.claude/backlog/<slug>.md` for individual items — mirroring the `.claude/plans.md` / `.claude/plans/` convention.

## Commands

| Invocation | What it does |
|------------|-------------|
| `/backlog add <title>` | Add a new backlog item |
| `/backlog close <slug-or-title>` | Mark an item completed |
| `/backlog list` | Show all pending + completed items |
| `/backlog init` | Initialize backlog structure (if not present) |
| `/backlog` (no args) | Same as `list` |

---

## Instructions

### Step 0: Detect project root

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && BACKLOG_ROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || BACKLOG_ROOT=$(pwd)
```

All paths below are relative to `$BACKLOG_ROOT`.

---

### Subcommand: `init`

Create the backlog structure if it doesn't already exist.

1. Create `.claude/backlog/` directory.
2. If `.claude/backlog.md` does not exist, create it:

```markdown
# <PROJECT NAME> - Backlog Index

## Pending

## Completed
```

Replace `<PROJECT NAME>` with the basename of `$BACKLOG_ROOT`.

3. Report what was created (or that it already existed).

---

### Subcommand: `add <title>`

Add a new backlog item.

#### 1. Ensure structure exists

If `.claude/backlog/` or `.claude/backlog.md` are missing, run `init` first (silently).

#### 2. Generate slug

Convert the title to a slug:
- Lowercase, words joined with `-`
- Strip punctuation
- Max ~50 chars
- Example: "Sort dropdown when queue view is on" → `sort-dropdown-queue-view`

If a file with that slug already exists, append `-2`, `-3`, etc.

#### 3. Ask for details (brief)

Ask the user one question:

> "Briefly describe the problem and goal (or press Enter to fill it in later):"

If they provide content, use it. If they press Enter/skip, use placeholder text.

#### 4. Create `.claude/backlog/<slug>.md`

```markdown
# <TITLE>

**Status**: PENDING

## Problem

<PROBLEM DESCRIPTION or "TODO: describe the problem">

## Goal

<GOAL DESCRIPTION or "TODO: describe the goal">

## Notes

<NOTES or leave blank>

---

*Added: <TODAY'S DATE YYYY-MM-DD>*
```

#### 5. Update `.claude/backlog.md` index

Add a line under `## Pending`:

```markdown
- [<TITLE>](backlog/<slug>.md) - <one-line summary> [PENDING]
```

The one-line summary is the first sentence of the problem description (or the title if no description).

#### 6. Confirm

Output: `Added: .claude/backlog/<slug>.md`

---

### Subcommand: `close <slug-or-title>`

Mark a backlog item as completed.

#### 1. Find the item

Search `.claude/backlog.md` for a line matching the slug or title (case-insensitive substring match). If multiple match, list them and ask user to pick one.

#### 2. Update the item file

In `.claude/backlog/<slug>.md`, change:
```
**Status**: PENDING
```
to:
```
**Status**: COMPLETED
```

And append at the bottom (before the final `---` line if present, or at end):
```
*Closed: <TODAY'S DATE YYYY-MM-DD>*
```

#### 3. Update `.claude/backlog.md`

Move the entry from `## Pending` to `## Completed`, changing `[PENDING]` → `[COMPLETED]`.

#### 4. Confirm

Output: `Closed: .claude/backlog/<slug>.md`

---

### Subcommand: `list` (default)

Display the backlog.

1. Read `.claude/backlog.md`.
2. If it doesn't exist, output: `No backlog found. Run /backlog init to create one.`
3. Otherwise, print:
   - All **Pending** items (with file links if terminal supports it)
   - Count of **Completed** items (don't list them unless there are 0 pending)

Example output:

```
Backlog — myproject

Pending (2):
  • sort-dropdown-queue-view  Sort dropdown when queue view is on
  • dark-mode                 Add dark mode support

Completed: 3 items (see .claude/backlog.md for details)
```

---

## File Format Reference

### `.claude/backlog.md` (index)

```markdown
# <PROJECT NAME> - Backlog Index

## Pending

- [Title](backlog/slug.md) - One-line summary [PENDING]

## Completed

- [Title](backlog/slug.md) - One-line summary [COMPLETED]
```

### `.claude/backlog/<slug>.md` (item)

```markdown
# <TITLE>

**Status**: PENDING | COMPLETED

## Problem

Description of what's wrong or missing.

## Goal

What the desired outcome looks like.

## Implementation Notes

Optional: hints for how to implement (backend, UI specifics, etc.).

## Notes

Optional: any other relevant context.

---

*Added: YYYY-MM-DD*
*Closed: YYYY-MM-DD*   ← only when completed
```

---

## Commit Guidance

After any backlog change, suggest a commit:

```bash
git add -f .claude/backlog.md .claude/backlog/
git commit -m "backlog: <add/close> <title>"
```

---

## Error Handling

- **Not in a git repo**: Proceed using `pwd` as project root; warn user.
- **No title provided for add**: Ask: "What is the title for this backlog item?"
- **No match for close**: List all pending items and ask user which to close.
- **Backlog.md malformed**: Warn and offer to re-initialize (preserving existing item files).
