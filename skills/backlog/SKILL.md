---
name: backlog
description: Use when adding, claiming, closing, or listing backlog items, reconciling index drift, or sweeping the open backlog — the local .claude/backlog/ store is the source of truth; Linear is an opt-in per-project mirror behind the linear_sync key. Supports add, claim, close, list, reconcile, sweep, and init.
---

# Backlog Manager

Backlog Surface (SPEC-009). The local store (`.claude/backlog.md` +
`.claude/backlog/<slug>.md` at `$MROOT`) is the **source of truth** for ticket
records (CDT-646). Linear is an **opt-in per-project mirror** behind
`linear_sync`: `off` (default) = local paths, zero Linear MCP calls; `on` = local
write first, mirror second, and a mirror failure never rolls back the local
write. Store, index, and the `linear_sync` config are process state: never staged
or committed as product delivery (v1.0 invariant).

## Tracker plane (CDT-646)

`skills/backlog/linear-gate.sh` is the only reader of `linear_sync`; bind it once
per run and print one `linear_sync=<off|on>` line. Gate CLI, verb CLI, and
ordering rules: Read `skills/backlog/linear-sync.md` (SPEC-002 D1 copy).

## Commands

| Invocation | What it does |
|------------|-------------|
| `/backlog add <title>` | Write the local item (the record); Linear mirror when `on` |
| `/backlog claim <slug-or-title>` | Stamp the item `IN_PROGRESS` + owner (local only) |
| `/backlog close <slug-or-title>` | Flip local COMPLETED; Linear terminal when `on` |
| `/backlog reconcile` | Repair index ↔ item files (`--linear-verdicts`, `on` only) |
| `/backlog list` | The local index; Linear open issues as the mirror when `on` |
| `/backlog sweep [flags]` | Purge pre-pass + serial walk of the open set; protocol in `sweep.md` |
| `/backlog init` | Initialize local backlog structure (if not present) |
| `/backlog` (no args) | Same as `list` |

### Offline ticket verbs (CDT-646)

`skills/backlog/ticket.sh create|claim|close` — the ticket CLI over the local
store: zero network, zero Linear MCP calls, `store: <path>` per verb, exit
0 / 1 / 64. Flags: `skills/backlog/linear-sync.md`.

## Instructions

### Step 0: Detect project root

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && BACKLOG_ROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || BACKLOG_ROOT=$(pwd)
```

Local store paths below are relative to `$BACKLOG_ROOT` for **index
discovery**, but close/reconcile CLIs resolve root as `--root` if set, else
`$MROOT` (the parent of `git rev-parse --git-common-dir`; SPEC-009 § Backlog
root rule), else `pwd` outside git — every linked worktree reads and writes
the one shared store.

### Tracker-plane posture (all subcommands)

| Gate | Behavior |
|---|---|
| **`off` (default)** | Local path only: the store answers every subcommand. **Zero Linear MCP calls**, no Linear notice. |
| **`on`, MCP up** | Local write first, Linear second (`linear_id` linkage). |
| **`on`, MCP down** | Local write stands; **one** line `Linear unreachable — local backlog only.`; never block or hard-fail |

The session owns Linear MCP calls; the bash engines never call MCP — they take
`--linear-verdicts` and read `linear_id`.

---

### Subcommand: `init`

Create the **local ticket store** if it doesn't already exist — the whole setup
on the default (`linear_sync=off`) path.

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

Add a new backlog item. **The local write is the record** (SPEC-009, CDT-646);
the Linear mirror runs only when `linear_sync=on`.

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
here becomes the local item's Problem/Goal (Step 5), and the Linear description
verbatim (Step 4) when the gate is `on`. It MUST stand alone: inline the actual substance, never
a bare pointer to a local-only file path (a worktree-relative path,
`.claude/plans/**`, `.claude/backlog/**`, or any path only this checkout has).
Linear is read by teammates and agents with no access to this machine's disk.
A local path MAY be added as a supplementary cross-reference after the
inlined substance — never as a replacement for it. (Origin: CDT-111 — a
Linear issue was created pointing solely at a local `.claude/plans/**` file,
unreadable by anyone without that exact checkout.)

#### 4. Linear mirror create (`linear_sync=on` only)

Key `off` (default): **skip this step** — no Linear call, no notice, no
`linear_id`; Step 5 is the whole create. Key `on`: create the Linear issue (title
+ the Step 3 text), capture the identifier, and pass it to Step 5 as
`--linear-id` so the one local write carries the linkage. On MCP-down or create
failure print exactly one line `Linear unreachable — local backlog only.` and
write with no `linear_id`. Never block or retry-loop. Mechanics:
`skills/backlog/linear-sync.md` § Mirror paths.

#### 5. Write the local item `.claude/backlog/<slug>.md` (the ticket record)

The local read-modify-write takes the shared backlog lock. Run `add.sh` once. Do not Write the item file or the index row yourself, before or after it returns.

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && BACKLOG_ROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || BACKLOG_ROOT=$(pwd)
bash skills/backlog/add.sh --root "$BACKLOG_ROOT" \
  --title "<TITLE>" --problem "<PROBLEM>" --goal "<GOAL>" \
  --linear-id "<LINEAR-ID>"
```

Omit `--linear-id` when the gate is `off` or Step 4 did not return an id. `add.sh` writes the item and the one Pending index row under the lock. With `--linear-id` it writes the frontmatter and `linear:<ID>` on that row. Do not write either file again. Pass an existing Linear id the same way: `--linear-id <ID>`. The block below is the shape that call already wrote. It has no Implementation Notes, Affects, Effort, or Notes sections.

For a ticket, epic, or epic child, add `--kind ticket|epic|child` (plus
`--epic-parent`, `--child-id`, `--depends-on`, `--estimate`, `--agent`); a plain
ticket writes no frontmatter. Prefer `skills/backlog/ticket.sh create`.

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

#### 6. Local index row in `.claude/backlog.md`

`add.sh` already inserted one row under `## Pending`. Do not add a second row. The summary on that row is the title. With `--linear-id`, the row already ends in `linear:<ID>`:

```markdown
- [<TITLE>](backlog/<slug>.md) - <TITLE> [PENDING]
- [<TITLE>](backlog/<slug>.md) - <TITLE> [PENDING] linear:<LINEAR-ID>
```

#### 7. Confirm

```
Added: .claude/backlog/<slug>.md
Linear: <LINEAR-ID (mirrored) | skipped (linear_sync=off) | none (unreachable)>
```

**MUST NOT** `git add` / commit the tracker files as product.

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

**The gate comes first** — with `linear_sync=off` every caller takes the local
path and Step 4 is skipped (see § Tracker plane). With the key `on`:

**MCP mode is a caller-declared choice, not an availability fallback**:
- **Linear mirror (default)** — same as `add` Step 4: create in Linear when MCP
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
2, mirror mode (`on` path)), `skills/refactor/SKILL.md` § 2.2a.5 (convention 2,
`--local-only`), `commands/retro.md` `--auto` mode (convention 2,
mirror mode (`on` path)), `skills/bug-hunt/SKILL.md` S3e (convention 2 Direct write,
mirror mode (`on` path); M8 proceed-gated).

---

### Subcommand: `close <slug-or-title>`

Mark a backlog item completed. **The local flip is the record.** Linear goes
terminal only when `linear_sync=on`.

**Trigger-(b) classifier before the disposition write (SPEC-039 M13.2;
CDT-564).** When the advisor is enabled for the run (`ADVISOR_ON=true`, Step
0) and `ADVISOR_SKIP_TRIGGER` is not `1` (interactive bypass), classify the
close rationale — `--kind disposition --action close` — BEFORE `close.sh` or
the Linear terminal call. A zero-hit scan is a silent skip (M17 miss sampling
runs inside `classify.sh` under `--run-id`). `descope` / `reassign` state
changes on Linear use the same fence with that `--action` value. A halt
outcome (BC7/BC8) MUST NOT apply the state change. The block below sits in
the same fresh-shell fence as the CLI call (it needs the same PDH).

Prefer the deterministic CLI (shared with `/orchestrate` ship and `/wrap-ticket`)
for the **local** write (the ticket record):

```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && grep -qF '"name": "dev-team"' "${_mp}.claude-plugin/plugin.json" 2>/dev/null && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
printf 'PDH=%s\n' "$PDH" >&2
CLOSE=$(bash "$PDH/skills/plugin-dir.sh" file skills/backlog/close.sh)
# CDT-564: trigger-(b) classifier before the close write (M13.2); silent skip
# when the advisor is off or ADVISOR_SKIP_TRIGGER=1 (interactive bypass).
if [ "${ADVISOR_ON:-}" = "true" ] && [ "${ADVISOR_SKIP_TRIGGER:-}" != "1" ]; then
  CLASSIFY=$(bash "$PDH/skills/plugin-dir.sh" file skills/advisor/classify.sh)
  HITS=$(bash "$CLASSIFY" --kind disposition --action close --text "<close rationale>" --run-id "<RUN_ID>") || exit $?
  if [ "$HITS" != "[]" ]; then
    # static-check.sh first (M19), then ask.sh probe --trigger b per
    # skills/advisor/SKILL.md [--model "<ADVISOR_MODEL>" when the run set one —
    # SPEC-039 M37]; a halt outcome (BC7/BC8) MUST NOT close.
    echo "advisor trigger-(b) hits at the disposition write: $HITS" >&2
  fi
fi
# ROOT = MROOT by default (shared store; SPEC-009 § Backlog root rule); --root overrides
bash "$CLOSE" <slug-or-title> \
  [--ticket <ISSUE-ID>] [--sha <sha>] [--note <text>] \
  [--root <path>] [--status COMPLETED|FIXED/CLOSED]
# Gate (exit 0 closed, 1 open/missing):
bash "$CLOSE" verify <slug-or-title> [--root <path>]
```

`close.sh` is subprocess-only, bash-only (no MCP). It is **idempotent**
(re-close → `Already closed:`). Does **not** git-commit or stage.

**Post-ship fold sweeps** (`/release` Step 6.5, `/wrap-ticket` Step 5.5) reuse
this same verb through `skills/backlog/fold-sweep.sh`: it collects the ticket
IDs/slugs named by a shipped fold commit (the subject's trailing `(slug, …)`
list plus the matching `### vX.Y.Z` CHANGELOG entry), closes each local item
(`--ticket vX.Y.Z --sha <commit>` — version+commit footer), and prints one
`linear-close: <ID>` line per flipped item for the session's best-effort
Linear Done. Never fatal; already-closed files are skipped without writes
(and without a second Linear close); slugs with no local item file are a
calm skip. Test seam: `--linear-close-cmd CMD` invokes `CMD <linear-id>` per
flipped item (tests stub it; production callers never set it).

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
`CANCELLED` | `CANCELED`. Open: `PENDING`, `IN_PROGRESS`, `DEFERRED`, empty —
a claimed item is open work with an owner (CDT-646), so `sweep`, `list`, and
`reconcile` keep seeing it. Write path
`--status` is unchanged: only `COMPLETED|FIXED/CLOSED` (do not invent new
write values for close).

#### Session Linear close (`linear_sync=on` only — always second)

Key `off`: the local close is the whole operation — no Linear step, no Linear
line. Key `on`: `close.sh` first (the record), then read `linear_id`
(frontmatter, index row, or plan `closes:`) and mark the Linear issue terminal,
failing open with `Linear unreachable — local close only.` `close.sh verify` is
the ship gate. Mechanics: `skills/backlog/linear-sync.md` § Mirror paths.

#### Subcommand: `claim <slug-or-title>` (CDT-646, local only)

`close.sh claim <slug-or-title> [--owner <name>] [--root <path>]` → status
`IN_PROGRESS (<owner>)`, a `*Claimed:*` footer, index row re-tagged
`[IN_PROGRESS]` in place under `## Pending` (open for `list`, `sweep`,
`reconcile`). Shared lease; idempotent per owner; refuses a closed item (1); no
Linear call. Mechanics: `skills/backlog/linear-sync.md`.

#### Manual fallback (if CLI unavailable)

1. Find the row in `.claude/backlog.md` (case-insensitive slug/title substring);
   on multiple matches, list them and ask the user to pick one.
2. In `.claude/backlog/<slug>.md`, change `**Status**: PENDING` to
   `**Status**: COMPLETED` and append `*Closed: <YYYY-MM-DD>*` (before the final
   `---` if present). Preserve YAML frontmatter (`linear_id`, epic fields).
3. In the index, move the row from `## Pending` to `## Completed` and re-tag
   `[PENDING]` → `[COMPLETED]`.
4. Confirm: `Closed: .claude/backlog/<slug>.md` plus
   `Linear: <Done <ID> | skipped (no id) | unreachable (local only)>`.

**MUST NOT** stage/commit tracker files as product.

---

### Subcommand: `reconcile`

Idempotent repair pass that brings `.claude/backlog.md` (the index) into agreement with the
`.claude/backlog/<slug>.md` item files — and, on the `linear_sync=on` path when the Linear MCP is
reachable, with Linear's terminal issue states. It is a hygiene operation: it removes/prunes index rows and item files, but
**never invents new items**. See `specs/core/SPEC-009-ticket-workflow.md` §"Backlog reconcile".

The store is the source of truth for **open** ticket records; it is not an
archive. Once an item is terminal (locally, or in the mirror when
`linear_sync=on`) reconcile **deletes** its item file and drops its index row.
The closed record lives in git history, the release notes, and Linear when the
mirror is on. Nothing is retained on disk under a `## Completed` section (the
header stays for schema stability, empty after a clean reconcile).

Run the deterministic CLI (subprocess-only; does **not** git-commit — and MUST NOT stage):

```bash
PDH="${PDH:-$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && grep -qF '"name": "dev-team"' "${_mp}.claude-plugin/plugin.json" 2>/dev/null && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache \( -path '*/dev-team/*/skills/plugin-dir.sh' -o -path '*/dev-team-edge/*/skills/plugin-dir.sh' \) 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if(($i=="dev-team"||$i=="dev-team-edge")&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?2:(($0 ~ /\/cache\/cold-dark-void\/dev-team-edge\//)?1:0); print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )}"
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

#### Precedence — the gate decides, then Linear ranks

`reconcile.sh` is bash-only and **cannot call MCP tools** (mirrors close.sh's
subprocess contract):

0. **`linear_sync=off`: stop here.** Never query Linear, never pass
   `--linear-verdicts` — the LOCAL pass above is the whole reconcile, with zero
   Linear MCP calls.
1. **`on`:** the session resolves each linked entry's Linear state
   (`linear_id` frontmatter or `linear:<ID>` row token) and passes a verdicts file
   via `--linear-verdicts`. A terminal verdict **takes precedence over local
   item-file status** for this one prune decision.
2. **`on`, no flag** (or a slug absent from it): pure **local item-file status**.
3. **`on`, MCP failure** (SPEC-025 M5 posture): skip the flag, print one line
   (`Linear unreachable — reconciling from local item files only.`), run the local
   pass. Never block, retry-loop, or fail the pass.

**Verdicts file format** (`--linear-verdicts`): TSV `<slug>\t<state>`, JSON, `jq`
rules, and the malformed-input exits are SPEC-009 § Backlog reconcile (the one
copy). **A blank state is non-terminal** (CDT-267): an empty state, a bare slug
line, or a JSON `""`/`null` prunes nothing — the slug falls through to its local
item-file status.

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

Display open work from the local index (the record). Read Linear only when
`linear_sync=on`.

#### `linear_sync=off` (default) — the local path

Read `.claude/backlog.md` and present its open rows (`PENDING`, `IN_PROGRESS`,
`DEFERRED`): zero Linear MCP calls, no Linear notice. If the index is absent,
output `No backlog found. Run /backlog init to create one.` Print the Pending
items, then the Completed count (0 after a clean reconcile; list them only when
nothing is pending). Shape — the MCP-down fallback below uses it too:

```
Backlog — myproject

Pending (2):
  • sort-dropdown-queue-view  Sort dropdown when queue view is on
  • dark-mode                 Add dark mode support  [IN_PROGRESS: ic5]

Completed: 2 items closed since the last reconcile (see .claude/backlog.md)
```

#### `linear_sync=on` — the mirror path

MCP reachable: query Linear for open issues (exclude terminal states), present
them cross-referenced with the local store, and note local rows with no
`linear_id` as work the mirror does not carry. MCP down: one line
`Linear unreachable — local backlog only.`, then the local path above. Mechanics:
`skills/backlog/linear-sync.md` § Mirror paths.

### Subcommand: `sweep [flags]`

`/backlog sweep` is a composition layer over `/backlog` and `/orchestrate`
(SPEC-040): it walks the open set once, runs a Purge pre-pass, then a
size-ascending serial walk. Protocol: Read `skills/backlog/sweep.md` — the one
operational copy (SPEC-002 D1). Do not inline it here. Helpers:
`skills/backlog/sweep.sh` (subprocess CLI, never sourced) and
`skills/backlog/defer.sh`. Flags:
`--ship=<pr|master|patch|minor|major>`, `--limit N`, `--project X`,
`--refresh`, `--skip-decided`, `--autopilot`. Journal:
`$MROOT/.claude/sweeps/<slug>.jsonl` — process state, never staged.

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
kind: child              # optional; ticket | epic | child (CDT-646)
linear_id: <LINEAR-ID>   # optional; set only on the linear_sync=on path
---

# <TITLE>

**Status**: PENDING | IN_PROGRESS [(<owner>)] | DEFERRED | COMPLETED | DONE | FIXED/CLOSED | FIXED-CLOSED | FIXED CLOSED | CLOSED | CANCELLED | CANCELED

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
*Claimed: YYYY-MM-DD by <owner>*   ← only when claimed (`IN_PROGRESS`)
*Closed: YYYY-MM-DD*   ← only when completed
```

Readable terminal statuses (close/reconcile classify via
`skills/backlog/terminal-status.sh`): `COMPLETED`, `DONE`,
`FIXED/CLOSED` | `FIXED-CLOSED` | `FIXED CLOSED`, `CLOSED`,
`CANCELLED` | `CANCELED`. Write path still emits only
`COMPLETED` | `FIXED/CLOSED`.

Epic children may carry extra frontmatter (`kind: child`, `epic_parent`,
`child_id`, `depends_on`, `estimate`, `agent`) per SPEC-025 + CDT-646; preserve
it on close. `add.sh` / `ticket.sh create` write it; a plain ticket writes none.

## Commit / stage policy (v1.0 invariant)

**MUST NOT** stage or commit process trackers as product delivery:
`.claude/backlog.md`, `.claude/backlog/**` (the ticket records — row 4 of
`docs/internal/control-plane/record-ownership.md`), `.claude/plans*`,
`.claude/dev-team/config.json` (the `linear_sync` key — row 13), and other
process state under `.claude/` (except committed seed carve-outs per SPEC-024).
Source of truth changes nothing: the store stays on disk only, and ship/wrap
never fold tracker files into the product commit.

## Error Handling

- **Not in a git repo**: proceed with `pwd` as root; warn the user.
- **No title for add**: ask for one.
- **No match for close**: list pending items and ask which one.
- **Backlog.md malformed**: warn and offer to re-initialize (item files preserved).
- **`linear_sync=off`**: nothing to degrade — the store is the record, and no
  Linear call is made.
- **Linear MCP down (key `on`)**: one-line notice; the local write stands.
