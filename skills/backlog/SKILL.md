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
`$MROOT` (the parent of `git rev-parse --git-common-dir`; SPEC-009 § Backlog
root rule), else `pwd` outside git — every linked worktree reads and writes
the one shared store.

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
ROW_EXISTS=$(grep -cE "\]\(backlog/${SLUG}\.md\)" "$BACKLOG_ROOT/.claude/backlog.md" 2>/dev/null || true); ROW_EXISTS=${ROW_EXISTS:-0}
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

**Self-contained content (REQUIRED)** — whatever problem/goal text is gathered
here becomes the Linear description verbatim (Step 4) and the local item's
Problem/Goal (Step 5). It MUST stand alone: inline the actual substance, never
a bare pointer to a local-only file path (a worktree-relative path,
`.claude/plans/**`, `.claude/backlog/**`, or any path only this checkout has).
Linear is read by teammates and agents with no access to this machine's disk.
A local path MAY be added as a supplementary cross-reference after the
inlined substance — never as a replacement for it. (Origin: CDT-111 — a
Linear issue was created pointing solely at a local `.claude/plans/**` file,
unreadable by anyone without that exact checkout.)

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

The local read-modify-write takes the shared backlog lock. Run `add.sh` once. Do not Write the item file or the index row yourself, before or after it returns.

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && BACKLOG_ROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || BACKLOG_ROOT=$(pwd)
bash skills/backlog/add.sh --root "$BACKLOG_ROOT" \
  --title "<TITLE>" --problem "<PROBLEM>" --goal "<GOAL>" \
  --linear-id "<LINEAR-ID>"
```

Omit `--linear-id` when Step 4 did not return an id. `add.sh` writes the item and the one Pending index row under the lock. With `--linear-id` it writes the frontmatter and `linear:<ID>` on that row. Do not write either file again. Pass an existing Linear id the same way: `--linear-id <ID>`. The block below is the shape that call already wrote. It has no Implementation Notes, Affects, Effort, or Notes sections.

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

---

*Added: <TODAY'S DATE YYYY-MM-DD>*
```

When there is no Linear id, that call omits the frontmatter block.

#### 6. Dual-write local index `.claude/backlog.md`

`add.sh` already inserted one row under `## Pending`. Do not add a second row. The summary on that row is the title. With `--linear-id`, the row already ends in `linear:<ID>`:

```markdown
- [<TITLE>](backlog/<slug>.md) - <TITLE> [PENDING]
- [<TITLE>](backlog/<slug>.md) - <TITLE> [PENDING] linear:<LINEAR-ID>
```

#### 7. Confirm

```
Added: .claude/backlog/<slug>.md
Linear: <LINEAR-ID | none (local-only)>
```

**MUST NOT** `git add` / commit the write-through files as product.

---

### Programmatic write-back (non-interactive callers)

For skills that need to write a backlog item without the interactive prompts
in `add` above — Step 3's ask, Step 2a's "(b) Abort" branch — e.g. an
escalation-gate auto-chain, or a command's `--auto` mode. This is not a
fourth subcommand; it is `add`'s Steps 1/2/2a/4/5/6/7 run with content
pre-supplied and two choices fixed, so non-interactive callers reuse the same
mechanics instead of forking their own (SPEC-002 D1: this section is the one
operational copy — callers cite it, never restate or reimplement it).

**Content pre-supply** — the caller passes title, problem, and goal text
directly; Step 3's ask is skipped. The **Self-contained content** requirement
from Step 3 applies without exception: the caller MUST pass the actual
substance, never a bare local-file pointer.

**Dedup resolution is fixed to (a) Suffix** — Step 2a's "(b) Abort" branch is
unavailable here: there is no user turn to report a collision to and wait on.
Walk `-2`, `-3`, … until both the item file and the index row are free, then
continue with that slug. Never abort.

**MCP mode is a caller-declared choice, not an availability fallback**:
- **Linear-first (default)** — same as `add` Step 4: create in Linear when MCP
  is reachable, dual-write local with `linear_id`; on MCP-down/error, the same
  one-line fail-open notice and local-only continuation.
- **`--local-only`** — skip Step 4 entirely regardless of MCP reachability;
  write local-only, no `linear_id`. Reserved for callers with a documented
  reason to avoid an MCP round-trip mid-chain (e.g. a tightly scoped
  escalation-gate write where Linear latency/failure would stall an unrelated
  gate). The calling skill's own contract MUST state that reason — never
  default to `--local-only` silently.

**Calling conventions** — a caller picks one; both reuse the rules above
rather than restating them:
1. **Print-and-confirm** — print `Run: /backlog add "<title>"` and stop; a
   human decides whether/when to run it.
2. **Direct write** — perform Steps 1/2/2a/(4)/5/6/7 in-session, no user turn.

Known citing callers: `skills/brainstorm/SKILL.md` Step 4c (convention 1 or
2, Linear-first), `skills/refactor/SKILL.md` § 2.2a.5 (convention 2,
`--local-only`), `commands/retro.md` `--auto` mode (convention 2,
Linear-first), `skills/bug-hunt/SKILL.md` S3e (convention 2 Direct write,
Linear-first; M8 proceed-gated).

---

### Subcommand: `close <slug-or-title>`

Mark a backlog item completed. **Linear terminal when MCP up + always local flip.**

Prefer the deterministic CLI (shared with `/orchestrate` ship and `/wrap-ticket`)
for the **local** write-through:

```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
printf 'PDH=%s\n' "$PDH" >&2
CLOSE=$(bash "$PDH/skills/plugin-dir.sh" file skills/backlog/close.sh)
# ROOT = MROOT by default (shared store; SPEC-009 § Backlog root rule); --root overrides
bash "$CLOSE" <slug-or-title> \
  [--ticket <ISSUE-ID>] [--sha <sha>] [--note <text>] \
  [--root <path>] [--status COMPLETED|FIXED/CLOSED]
# Gate (exit 0 closed, 1 open/missing):
bash "$CLOSE" verify <slug-or-title> [--root <path>]
```

`close.sh` is subprocess-only, bash-only (no MCP). It is **idempotent**
(re-close → `Already closed:`). Does **not** git-commit or stage.

**Lock (SPEC-009 § Backlog write integrity).** `close.sh` in close mode holds one
shared `mkdir` lock, `<root>/.claude/backlog.lock/`, over the whole read-decide-write
(`close.sh verify` takes no lock). A fresh lock makes the caller wait at most
`BACKLOG_LOCK_WAIT_SECONDS` (default 30); on timeout it exits 1 with the lock path
on stderr and no file changes. A stale lock — stamp `BACKLOG_LOCK_TTL_SECONDS`
(default 60) or more seconds old, or missing/unparseable — is reclaimed.
It fails fast only when `<root>/.claude` is not writable, and exits 1 when its stamp write fails (SPEC-009 documents the double-reclaim residual).

**Terminal classification** (verify + idempotent re-close) uses the shared
classifier `skills/backlog/terminal-status.sh` — single definition of truth
(SPEC-009 / CDT-160). Closed when status is (case-insensitive, token-match
not bare substring; trailing noise OK): `COMPLETED`, `DONE`,
`FIXED/CLOSED` | `FIXED-CLOSED` | `FIXED CLOSED`, `CLOSED`,
`CANCELLED` | `CANCELED`. Open: `PENDING`, `DEFERRED`, empty. Write path
`--status` is unchanged: only `COMPLETED|FIXED/CLOSED` (do not invent new
write values for close).

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
terminal issue states. It is a hygiene operation: it removes/prunes index rows and item files, but
**never invents new items**. See `specs/core/SPEC-009-ticket-workflow.md` §"Backlog reconcile".

The local write-through is a **disposable cache**, not an archive — once an item is terminal
(locally or in Linear), reconcile **deletes** its item file and drops its index row entirely.
Linear (when linked) or git/commit history is the durable record for done work; nothing is ever
retained on disk under a `## Completed` section (the header stays, for schema stability, but stays
empty after a clean reconcile).

Run the deterministic CLI (subprocess-only; does **not** git-commit — and MUST NOT stage):

```bash
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
RECON=$(bash "$PDH/skills/plugin-dir.sh" file skills/backlog/reconcile.sh)
# ROOT = MROOT by default (shared store; SPEC-009 § Backlog root rule); --root overrides
bash "$RECON" [--root <path>] [--dry-run] [--linear-verdicts <file>]
```

**Lock (SPEC-009 § Backlog write integrity).** In apply mode, `reconcile.sh`
holds the same shared `mkdir` lock as `close.sh`, `<root>/.claude/backlog.lock/`,
over the whole read-decide-write (`--dry-run` takes no lock). A fresh lock makes
the caller wait at most `BACKLOG_LOCK_WAIT_SECONDS` (default 30); on timeout it
exits 1 with the lock path on stderr and no file changes. A stale lock — stamp
`BACKLOG_LOCK_TTL_SECONDS` (default 60) or more seconds old, or missing/unparseable
— is reclaimed.
It fails fast only when `<root>/.claude` is not writable, and exits 1 when its stamp write fails (SPEC-009 documents the double-reclaim residual).

#### What it does (LOCAL pass — always)

- Rows whose **item file** `Status` is terminal per shared classifier
  `skills/backlog/terminal-status.sh` (token-match, not bare substring;
  case-insensitive; trailing noise OK) — AC2 set: `COMPLETED`, `DONE`,
  `FIXED/CLOSED` | `FIXED-CLOSED` | `FIXED CLOSED`, `CLOSED`,
  `CANCELLED` | `CANCELED` — → **pruned**: item file deleted, index row
  dropped entirely (not moved/archived). (`UNDONE` stays open.)
- Index rows with **no corresponding item file** (dead references) → **removed**.
- **Duplicate** rows for one slug → collapsed to a single row (first-seen kept).
- **Orphan item files** — files under `.claude/backlog/` with **no index row at all** (never
  dual-written via `add`, or predating this convention) → if the item's own `Status` is already
  terminal, **pruned** the same as a completed indexed row (nothing points to it; Linear or
  git/commit history already has the record). If the status is open/unrecognized, the file is
  **left untouched** and reported as `ORPHAN not pruned` — deleting un-tracked, un-shipped work
  with no other record of it would be a silent loss. It is never auto-added to the index either
  (that would be inventing a new item); a human decides — `/backlog add` to track it properly, or
  delete it if it's stale.
- The index is **line-preserving** (SPEC-009 § Backlog write integrity): reconcile drops only
  the rows it decides to remove — terminal (pruned), dead-reference and duplicate rows. Every
  other line — headings, prose, blank lines, nested content and kept rows — stays byte-identical
  and in its original position, except that a missing final newline is added
  when the index is rewritten. Reconcile never adds, moves, re-orders or re-tags
  a line. When it drops nothing, it does not rewrite the index; a second run
  reports no changes.

#### Precedence — Linear is source of truth when reachable

`reconcile.sh` is bash-only and **cannot call MCP tools**. The split (mirrors close.sh's subprocess
contract):

1. **You (the interpreting Claude session) query Linear first**, if the Linear MCP is reachable.
   For each index entry with a Linear counterpart (`linear_id` frontmatter or `linear:<ID>` on the
   index row), resolve its issue state. Write a verdicts file mapping slug → terminal-state for the
   entries Linear reports as `Done` / `Cancelled` / `Completed` (or the team's equivalent terminal
   state), and pass it via `--linear-verdicts`. These verdicts **take precedence over local
   item-file status** (Linear = SoT): the script prunes the item — deletes the file, drops the
   index row — the same as a locally-terminal item.
2. **Without the flag** (or for slugs absent from the verdicts file), reconcile falls back to pure
   **local item-file status** per the LOCAL pass above.
3. **MCP failure is best-effort** (SPEC-025 M5 posture): if the Linear MCP is absent,
   unauthenticated, times out, or errors per-issue, **skip the `--linear-verdicts` flag entirely**,
   emit a single one-line notice (e.g. `Linear unreachable — reconciling from local item files
   only.`), and run the local fallback. Never block, retry-loop, or fail the pass on Linear
   unavailability. A reconcile run always terminates with a consistent local index.

**Verdicts file format** (`--linear-verdicts`): either TSV lines `<slug>\t<state>`, or JSON — a
flat object `{"<slug>":"<state>",...}` or an array of objects each with a `slug`/`id` and a
`state`/`status` key. JSON is parsed with `jq` only, never a regular expression, and the result does
not depend on key order; when `jq` is not on `PATH`, a JSON verdicts file is refused (exit 1, no
writes) — a TSV file needs no `jq`. In an array object, `slug` wins over `id` and `state` wins over
`status`; a key with a `null` value counts as absent. For JSON input, malformed JSON, another top-level type, a
non-object array element, or a missing/non-string slug gives exit 1 with no file changes.
A file whose first non-blank character is `{` or `[` is JSON; any other file is TSV.
**A blank state is non-terminal** (CDT-267): a TSV line with an empty state, a bare slug line, or a
JSON `""`/`null` state prunes nothing — the slug falls through to its local item-file status, so a
locally open item stays open with no file written.

#### Idempotency & dry-run

- **Idempotent**: a second consecutive `reconcile` over an already-reconciled store makes **zero
  changes** (no row removals, no item-file deletions, no diff). Safe to run repeatedly. Open-status
  orphans keep being reported each run (they're not a change, just a standing notice) until a
  human resolves them.
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
   - Count of **Completed** rows closed since the last `/backlog reconcile` (reconcile prunes
     terminal rows rather than archiving them, so this count is 0 after a clean reconcile;
     don't list them unless there are 0 pending)

Example output:

```
Backlog — myproject

Pending (2):
  • sort-dropdown-queue-view  Sort dropdown when queue view is on
  • dark-mode                 Add dark mode support

Completed: 2 items closed since the last reconcile (see .claude/backlog.md for details)
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

**Status**: PENDING | COMPLETED | DONE | FIXED/CLOSED | FIXED-CLOSED | FIXED CLOSED | CLOSED | CANCELLED | CANCELED | DEFERRED

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

Readable terminal statuses (close/reconcile classify via
`skills/backlog/terminal-status.sh`): `COMPLETED`, `DONE`,
`FIXED/CLOSED` | `FIXED-CLOSED` | `FIXED CLOSED`, `CLOSED`,
`CANCELLED` | `CANCELED`. Write path still emits only
`COMPLETED` | `FIXED/CLOSED`.

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
