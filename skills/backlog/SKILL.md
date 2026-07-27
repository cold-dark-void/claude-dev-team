---
name: backlog
description: Manage project backlog with Linear-first dual-write when MCP is up; local .claude/backlog/ is a mandatory write-through cache. Supports add, close, list, reconcile, and init. Use when adding/closing/listing backlog items or reconciling index drift.
---

# Backlog Manager

Linear-first backlog Surface (SPEC-009 / CDT-54). When the Linear MCP is
reachable, Linear is the preferred source of truth for **open** work; local
`.claude/backlog.md` + `.claude/backlog/<slug>.md` are a **mandatory write-through
cache** on every path. When MCP is down: local-only + one-line notice (fail-open).

Process trackers under `.claude/` are **never** staged or committed as product
delivery (v1.0 invariant).

## Commands

| Invocation | What it does |
|------------|-------------|
| `/backlog add <title>` | Create Linear issue (if MCP up) + dual-write local |
| `/backlog close <slug-or-title>` | Mark Linear terminal (if MCP up) + flip local COMPLETED |
| `/backlog reconcile` | Repair index ↔ item files (+ Linear via `--linear-verdicts`) |
| `/backlog list` | Prefer Linear open issues when MCP up; else local index |
| `/backlog init` | Initialize local backlog structure (if not present) |
| `/backlog` (no args) | Same as `list` |

---

## Instructions

### Step 0: Detect project root

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && BACKLOG_ROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || BACKLOG_ROOT=$(pwd)
```

Local write-through paths below are relative to `$BACKLOG_ROOT` for **index
discovery**, but close/reconcile CLIs resolve root as `--root` if set, else
`git rev-parse --show-toplevel`, else `pwd` (worktree-correct for on-disk files).

### MCP posture (all subcommands)

| MCP state | Behavior |
|-----------|----------|
| **Up** | Linear-first: create/list/close on Linear, **always** dual-write local with `linear_id` linkage |
| **Down / error** | Local-only; emit **one** line: `Linear unreachable — local backlog only.`; never block, retry-loop, or hard-fail |

Session owns Linear MCP calls. Bash engines (`close.sh`, `reconcile.sh`) are
**bash-only** — they never call MCP. Session bridges Linear → scripts via
`--linear-verdicts` (reconcile) or by reading `linear_id` from the item file
(close).

---

### Subcommand: `init`

Create the **local write-through** structure if it doesn't already exist.

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

Add a new backlog item. **Linear-first when MCP up; always dual-write local.**

#### 1. Ensure structure exists

If `.claude/backlog/` or `.claude/backlog.md` are missing, run `init` first (silently).

#### 2. Generate slug

Convert the title to a slug:
- Lowercase, words joined with `-`
- Strip punctuation
- Max ~50 chars
- Example: "Sort dropdown when queue view is on" → `sort-dropdown-queue-view`

#### 2a. Dedup guard (REQUIRED — no silent duplicate rows)

Before writing anything, check **both stores** for the generated slug:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && BACKLOG_ROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || BACKLOG_ROOT=$(pwd)
# Row-exists = an index row keyed to this slug; file-exists = item file.
SLUG="<generated-slug>"
ROW_EXISTS=$(grep -cE "\]\(backlog/${SLUG}\.md\)" "$BACKLOG_ROOT/.claude/backlog.md" 2>/dev/null || echo 0)
FILE_EXISTS=$([ -f "$BACKLOG_ROOT/.claude/backlog/${SLUG}.md" ] && echo 1 || echo 0)
```

If either the item file OR an index row already exists for this slug, you MUST NOT append a
second row keyed to the same slug. Do exactly one of:

- **(a) Suffix** — append `-2`, `-3`, … to the slug until both the item file and the index row
  are free, then continue with the distinct new slug (this is the slug-collision rule, extended to
  cover the index, not just the file); **or**
- **(b) Abort** — stop and tell the user the pre-existing slug, e.g.
  `Backlog item 'sort-dropdown-queue-view' already exists (.claude/backlog/sort-dropdown-queue-view.md). Not adding a duplicate.`

Choose (a) when the new item is genuinely distinct work that happens to slugify the same; choose
(b) when it looks like a re-file of the same item. Never write a row for a slug that already has
one — duplicate rows per slug are an invariant the index must never carry (`/backlog reconcile`
collapses any that predate this guard, but add must not create new ones).

#### 3. Ask for details (brief)

Ask the user one question:

> "Briefly describe the problem and goal (or press Enter to fill it in later):"

If they provide content, use it. If they press Enter/skip, use placeholder text.

#### 4. Linear-first create (when MCP reachable)

If Linear MCP tools are available:

1. Create a Linear issue (title = item title; description = problem + goal).
2. Capture the returned identifier (e.g. `CDT-99` or UUID — prefer team issue key).
3. Proceed to dual-write local with that id as `linear_id`.

If Linear MCP is absent or any create call fails: print exactly one line

```
Linear unreachable — local backlog only.
```

and continue with local-only write-through (no `linear_id`). Never block or retry-loop.

#### 5. Dual-write local item `.claude/backlog/<slug>.md`

Always write the local item (mandatory write-through), including optional YAML
frontmatter when a Linear id is known:

```markdown
---
linear_id: <LINEAR-ID>
---

# <TITLE>

**Status**: PENDING

## Problem

<PROBLEM DESCRIPTION or "TODO: describe the problem">

## Goal

<GOAL DESCRIPTION or "TODO: describe the goal">

## Implementation Notes

<optional: hints for how to implement, or leave blank>

## Affects

<optional: file/dir paths this work will touch, or leave blank>

## Effort

<optional: rough size — S / M / L, or leave blank>

## Notes

<NOTES or leave blank>

---

*Added: <TODAY'S DATE YYYY-MM-DD>*
```

Omit the frontmatter block entirely when there is no Linear id (MCP-down path).
When linking an **existing** Linear issue instead of creating one, still write
`linear_id: <ID>` the same way.

#### 6. Dual-write local index `.claude/backlog.md`

Add a line under `## Pending`:

```markdown
- [<TITLE>](backlog/<slug>.md) - <one-line summary> [PENDING]
```

When `linear_id` is known, append it for discoverability:

```markdown
- [<TITLE>](backlog/<slug>.md) - <one-line summary> [PENDING] linear:<LINEAR-ID>
```

The one-line summary is the first sentence of the problem description (or the title if no description).

#### 7. Confirm

```
Added: .claude/backlog/<slug>.md
Linear: <LINEAR-ID | none (local-only)>
```

**MUST NOT** `git add` / commit the write-through files as product.

---

### Subcommand: `close <slug-or-title>`

Mark a backlog item completed. **Linear terminal when MCP up + always local flip.**

Prefer the deterministic CLI (shared with `/orchestrate` ship and `/wrap-ticket`)
for the **local** write-through:

```bash
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
CLOSE=$(bash "$PDH/skills/plugin-dir.sh" file skills/backlog/close.sh)
# ROOT = worktree/show-toplevel (on-disk write-through), NOT git-common-dir
bash "$CLOSE" <slug-or-title> \
  [--ticket <ISSUE-ID>] [--sha <sha>] [--note <text>] \
  [--root <path>] [--status COMPLETED|FIXED/CLOSED]
# Gate (exit 0 closed, 1 open/missing):
bash "$CLOSE" verify <slug-or-title> [--root <path>]
```

`close.sh` is subprocess-only, bash-only (no MCP). It is **idempotent**
(re-close → `Already closed:`). Does **not** git-commit or stage.

#### Session Linear close (before or after local CLI)

1. Resolve the item (slug/title match). Read `linear_id` from YAML frontmatter
   (or a `linear:<ID>` token on the index row / plan `closes:` entry).
2. **If MCP up and a Linear id is known:** mark the Linear issue terminal
   (`Done` / team equivalent). Fail-open with one line if MCP errors:
   `Linear unreachable — local close only.`
3. **Always** run `close.sh` for local item + index write-through.
4. `close.sh verify` must pass for ship gates.

#### Manual fallback (if CLI unavailable)

##### 1. Find the item

Search `.claude/backlog.md` for a line matching the slug or title (case-insensitive substring match). If multiple match, list them and ask user to pick one.

##### 2. Update the item file

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

Preserve any YAML frontmatter (`linear_id`, epic fields) — do not strip it.

##### 3. Update `.claude/backlog.md`

Move the entry from `## Pending` to `## Completed`, changing `[PENDING]` → `[COMPLETED]`.

##### 4. Confirm

```
Closed: .claude/backlog/<slug>.md
Linear: <Done <ID> | skipped (no id) | unreachable (local only)>
```

**MUST NOT** stage/commit write-through as product.

---

### Subcommand: `reconcile`

Idempotent repair pass that brings `.claude/backlog.md` (the index) into agreement with the
`.claude/backlog/<slug>.md` item files — and, when the Linear MCP is reachable, with Linear's
terminal issue states. It is a hygiene operation: it moves/removes index rows and flips item-file
`Status`, but **never invents new items**. See `specs/core/SPEC-009-ticket-workflow.md`
§"Backlog reconcile".

Run the deterministic CLI (subprocess-only; does **not** git-commit — and MUST NOT stage):

```bash
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
RECON=$(bash "$PDH/skills/plugin-dir.sh" file skills/backlog/reconcile.sh)
# ROOT = worktree/show-toplevel (on-disk write-through), NOT git-common-dir.
bash "$RECON" [--root <path>] [--dry-run] [--linear-verdicts <file>]
```

#### What it does (LOCAL pass — always)

- Rows whose **item file** `Status` reads `COMPLETED` / `DONE` / `FIXED-CLOSED` (case-insensitive)
  → moved to `## Completed`, re-tagged `[COMPLETED]`.
- Index rows with **no corresponding item file** (dead references) → **removed**.
- **Duplicate** rows for one slug → collapsed to a single row (first-seen kept).
- The index is rebuilt deterministically: header/preamble preserved verbatim, surviving rows
  emitted in first-seen order under `## Pending` then `## Completed`.

#### Precedence — Linear is source of truth when reachable

`reconcile.sh` is bash-only and **cannot call MCP tools**. The split (mirrors close.sh's subprocess
contract):

1. **You (the interpreting Claude session) query Linear first**, if the Linear MCP is reachable.
   For each index entry with a Linear counterpart (`linear_id` frontmatter or `linear:<ID>` on the
   index row), resolve its issue state. Write a verdicts file mapping slug → terminal-state for the
   entries Linear reports as `Done` / `Cancelled` / `Completed` (or the team's equivalent terminal
   state), and pass it via `--linear-verdicts`. These verdicts **take precedence over local
   item-file status** (Linear = SoT): the script sets the item `Status` to `COMPLETED` and moves
   the row to `## Completed`.
2. **Without the flag** (or for slugs absent from the verdicts file), reconcile falls back to pure
   **local item-file status** per the LOCAL pass above.
3. **MCP failure is best-effort** (SPEC-025 M5 posture): if the Linear MCP is absent,
   unauthenticated, times out, or errors per-issue, **skip the `--linear-verdicts` flag entirely**,
   emit a single one-line notice (e.g. `Linear unreachable — reconciling from local item files
   only.`), and run the local fallback. Never block, retry-loop, or fail the pass on Linear
   unavailability. A reconcile run always terminates with a consistent local index.

**Verdicts file format** (`--linear-verdicts`): either TSV lines `<slug>\t<state>`, or JSON — a
flat object `{"<slug>":"<state>",...}` or an array of objects each with a `slug`/`id` and a
`state`/`status` key. Non-terminal states are ignored (they never override local; the local pass
may still close an item whose own file already reads terminal). A blank state is treated as
terminal.

#### Idempotency & dry-run

- **Idempotent**: a second consecutive `reconcile` over an already-reconciled store makes **zero
  changes** (no row moves, no removals, no item-file writes, no diff). Safe to run repeatedly.
- **`--dry-run`**: prints the planned actions and writes nothing. Use it to preview before
  applying.

Reconcile complements the ship-time / `/wrap-ticket` close-out (which close specific items named by
a plan `closes:` list): reconcile sweeps the **whole** index for drift — dead rows, stale `PENDING`
rows for items since closed, and duplicates. It does not replace them.

---

### Subcommand: `list` (default)

Display open work. **Prefer Linear open issues when MCP up.**

#### When Linear MCP is reachable

1. Query Linear for open issues (team default filter — exclude terminal states).
2. Present Linear open issues as the preferred SoT for open work.
3. Cross-reference local write-through: for each local PENDING item, show linked
   `linear_id` if present; note local-only rows (no `linear_id`) as write-through
   orphans that may need migrate (out of scope for day-to-day list).
4. Optionally summarize local COMPLETED count (do not dump the full completed list
   unless zero pending).

Example:

```
Backlog — myproject (Linear preferred)

Open in Linear (2):
  • CDT-12  Sort dropdown when queue view is on  [local: sort-dropdown-queue-view]
  • CDT-15  Add dark mode support                [local: dark-mode]

Local-only PENDING (no linear_id): 0
Local COMPLETED (write-through): 3
```

#### When Linear MCP is down

Emit one line:

```
Linear unreachable — local backlog only.
```

Then fall back to local index:

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

- [Title](backlog/slug.md) - One-line summary [PENDING] linear:<ID>

## Completed

- [Title](backlog/slug.md) - One-line summary [COMPLETED]
```

The `linear:<ID>` token on the index row is optional metadata for discoverability;
authoritative linkage lives on the item file frontmatter.

### `.claude/backlog/<slug>.md` (item)

```markdown
---
linear_id: <LINEAR-ID>   # optional; set when dual-written with Linear
---

# <TITLE>

**Status**: PENDING | COMPLETED | DEFERRED

## Problem

Description of what's wrong or missing.

## Goal

What the desired outcome looks like.

## Implementation Notes

Optional: hints for how to implement (backend, UI specifics, etc.).

## Affects

Optional: the file/dir paths this work will touch.

## Effort

Optional: rough size — S / M / L.

## Notes

Optional: any other relevant context. Items may also add ad-hoc sections as needed (e.g. `## Scope`, `## Blocker`, `## Design`, `## Acceptance Criteria`).

---

*Added: YYYY-MM-DD*
*Closed: YYYY-MM-DD*   ← only when completed
```

Epic children may carry additional frontmatter (`epic_parent`, `child_id`,
`depends_on`, `estimate`, `agent`) per SPEC-025 — preserve those fields on close.

---

## Commit / stage policy (v1.0 invariant)

**MUST NOT** stage or commit process trackers as product delivery:

- `.claude/backlog.md`, `.claude/backlog/**`
- `.claude/plans.md`, `.claude/plans/**`
- other process state under `.claude/` (except committed seed carve-outs per SPEC-024)

Local write-through remains on disk only. Ship/wrap close local status + Linear
Done best-effort; they **do not** fold tracker files into the product commit.

---

## Error Handling

- **Not in a git repo**: Proceed using `pwd` as project root; warn user.
- **No title provided for add**: Ask: "What is the title for this backlog item?"
- **No match for close**: List all pending items and ask user which to close.
- **Backlog.md malformed**: Warn and offer to re-initialize (preserving existing item files).
- **Linear MCP down**: one-line notice; continue local-only (fail-open).
