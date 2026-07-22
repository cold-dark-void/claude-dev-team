---
name: epic
description: |
    Umbrella decomposition and sequenced orchestration (SPEC-025). PM+TL
    jointly decompose an epic into child tickets + cross-ticket DAG; persist
    via backlog (Linear optional); walk ready children by handing each to
    /kickoff or /orchestrate. Composition layer only — never reimplements the
    ticket lifecycle. Usage: /epic <EPIC-ID> ["text"] | status | complete |
    block | unblock | --redecompose
---

# Epic — Umbrella Decomposition & Sequenced Orchestration

Governing spec: `specs/core/SPEC-025-epic-umbrella-decomposition.md`.

**Composition rule (M11):** `/epic` ends at the handoff string. It does **not**
inline kickoff/orchestrate steps, spawn IC agents, write application code,
create worktrees, or write epic children into `.claude/tasks/`.

Mechanical CLI (subprocess only, never source):

```bash
bash skills/epic/epic-lib.sh <cmd> …
```

State lives at `$MROOT/.claude/epics/<EPIC-ID>/state.json` (shared across
worktrees). Override root for tests: `EPIC_ROOT`.

---

## Arguments

| Invocation | Behavior |
|------------|----------|
| `/epic <ID> "<text>"` | Decompose if no state; else resume execute |
| `/epic <ID>` | Resume / status if state exists; else prompt for text |
| `/epic status [<ID>]` | Rollup one epic or all active |
| `/epic --redecompose <ID> "<text>"` | Confirm → re-decompose non-completed only |
| `/epic complete <ID> <CHILD>` | Manual complete (kickoff-mode children) |
| `/epic block <ID> <CHILD> [reason]` | Mark child blocked |
| `/epic unblock <ID> <CHILD>` | Mark child pending again |

Execution mode (`kickoff` | `orchestrate`) is chosen **once** at first execute
and stored in `state.json` (L7).

---

## Step 0: Resolve roots (every bash block)

Each fenced bash block is a fresh shell — re-resolve every time (skill-lint C1).

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
EPIC_LIB="$PDH/skills/epic/epic-lib.sh"
DAG_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/orchestrate/dag-lib.sh)
```

---

## Dispatch

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
EPIC_LIB="$PDH/skills/epic/epic-lib.sh"
EPIC_ID="<EPIC-ID>"
if bash "$EPIC_LIB" exists "$EPIC_ID"; then
  echo "RESUME"
else
  echo "DECOMPOSE"
fi
```

- `status` → **Status mode**
- `complete` / `block` / `unblock` → thin wrappers over `epic-lib.sh`
- `--redecompose` → **Redecompose mode** (requires confirm)
- else if `exists` → **Execute / Resume**
- else → **Decompose mode** (needs epic text)

---

## Mode A — Decompose

### A.1 Soft prechecks (SHOULD)

- If epic text is vague (< ~50 words): warn and offer `/brainstorm` — do **not** hard-block.
- Soft warn at approval if > ~8 children (probably two epics).

### A.2 Parallel PM + TL spawn (M1, MC-4)

Spawn **both** in parallel with `Output mode: terse`. Do **not** spawn ICs.

**PM prompt template:**

```
Decompose umbrella epic <EPIC-ID> into child tickets.

Epic text:
"""
<EPIC TEXT>
"""

For EACH child produce:
1. short title
2. problem statement (what/why — no technical design)
3. acceptance criteria (testable list)
4. suggested slug (lowercase-hyphen, ~50 chars)

Do NOT invent depends_on, estimates, or agent tags — Tech Lead owns those.
Output mode: terse.
```

**TL prompt template:**

```
Decompose umbrella epic <EPIC-ID> into child tickets + cross-ticket DAG.

Epic text:
"""
<EPIC TEXT>
"""

For EACH child produce:
1. short title (align with PM if available)
2. size estimate: S | M | L
3. recommended agent: ic4 (extend patterns) | ic5 (novel)
4. depends_on: list of OTHER child local IDs only (form <EPIC-ID>-C<n>)
5. flag file-overlap risks within the same wave (add serializing depends_on)

Do NOT write problem statements or ACs — PM owns those.
Child IDs will be assigned as <EPIC-ID>-C1, C2, … in stable title order.
Output mode: terse.
```

### A.3 Merge algorithm

1. Align children by title (PM list is primary order; TL fills estimate/agent/depends_on).
2. Assign local IDs: `<EPIC-ID>-C1` … `C<n>` (stable order).
3. Every child MUST have all five M1 fields before approval:
   - problem statement, acceptance criteria, estimate, agent, `depends_on`
4. Missing any field → block approval; re-prompt the owning agent for that field only.

### A.4 Cycle gate (M2) — before any write

Build adapter JSON and call **dag-lib** (or epic-lib thin wrapper) literally:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
EPIC_LIB="$PDH/skills/epic/epic-lib.sh"
DAG_JSON="${TMPDIR:-/tmp}/epic-dag-$$.json"
# Write [{"task_id":"<EPIC-ID>-C1","depends_on":[]}, …] into $DAG_JSON
if ! bash "$EPIC_LIB" check-cycle "$DAG_JSON"; then
  echo "HALT: cycle in proposed DAG — zero writes"
  rm -f "$DAG_JSON"
  # stop; name the back-edge from stderr
fi
rm -f "$DAG_JSON"
```

On cycle: **halt**. Zero backlog / Linear / `state.json` writes.

### A.5 Approval gate (M3)

Present:

1. Per-child summary (five fields + slug)
2. Wave plan: `bash …/epic-lib.sh waves` after a dry-run structure, or format from DAG levels
3. Soft >8-children warning if applicable

User may edit/merge/remove children. On **decline**: exit, zero disk side effects.

On **approve** continue A.6.

### A.6 Persist (only after approve)

Ask once for execution mode if not yet known: `kickoff` | `orchestrate`.

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
EPIC_LIB="$PDH/skills/epic/epic-lib.sh"
EPIC_ID="<EPIC-ID>"
TITLE="<epic title>"
MODE="<kickoff|orchestrate>"
bash "$EPIC_LIB" init "$EPIC_ID" --title "$TITLE" --mode "$MODE"
# per child:
bash "$EPIC_LIB" add-child "$EPIC_ID" \
  --id "${EPIC_ID}-C<n>" --slug "<slug>" --title "<title>" \
  --estimate S|M|L --agent ic4|ic5 \
  --depends-on '<json-array>' \
  --problem "<problem>" --ac '<json-array-of-strings>'
```

#### Backlog writes (M4 — source of truth)

Per child, write `.claude/backlog/<slug>.md` with YAML frontmatter + body:

```markdown
---
epic_parent: <EPIC-ID>
child_id: <EPIC-ID>-C<n>
depends_on: [<ids>]
estimate: M
agent: ic5
---

# <TITLE>

**Status**: PENDING

## Problem

<problem statement>

## Acceptance Criteria

- <ac1>
- <ac2>

## Goal

Ship child of epic <EPIC-ID>.

## Effort

<S|M|L>

---

*Added: <YYYY-MM-DD>*
```

Index row under `## Pending` in `.claude/backlog.md`:

```markdown
- [<TITLE>](backlog/<slug>.md) - <one-line> [PENDING] epic:<EPIC-ID> <CHILD-ID>
```

Slug formula (SPEC-009 / `/backlog`): lowercase, hyphen-join, strip punctuation, max ~50 chars; on collision append `-2`, `-3`.

Ensure backlog structure exists (`/backlog init` if missing).

#### Linear best-effort (M5)

If Linear MCP tools are available:

1. Create issue: title `[<EPIC-ID>] <child title>`; description embeds local `child_id` + problem + ACs.
2. Label `epic:<EPIC-ID>` if labels API works; else description-only.
3. Record returned id: re-`add-child` is wrong if already added — instead note `linear_id` via a follow-up state edit only if you stored it at add-child time (`--linear-id`). Prefer creating Linear first then `add-child … --linear-id`, **or** create Linear after add-child and call `set-status` is not enough — pass `--linear-id` at add-child when known.

On **any** Linear failure or MCP absence: print one line
`Linear unavailable — continuing with backlog as source of truth`
and continue. **Never** block, retry-loop, or fail the epic.

Then enter **Execute / Resume**.

---

## Mode B — Execute / Resume (prompt-driven walker)

### B.1 Rollup

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
EPIC_LIB="$PDH/skills/epic/epic-lib.sh"
EPIC_ID="<EPIC-ID>"
bash "$EPIC_LIB" show "$EPIC_ID"
bash "$EPIC_LIB" waves "$EPIC_ID"
```

Print counts by status + ready set + wave plan. **No re-decomposition.** No duplicate backlog/Linear.

### B.2 Ready set → first child (stable id sort)

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
EPIC_LIB="$PDH/skills/epic/epic-lib.sh"
EPIC_ID="<EPIC-ID>"
READY=$(bash "$EPIC_LIB" ready-set "$EPIC_ID")
CHILD=$(printf '%s\n' "$READY" | head -1)
```

If empty: print `No ready children` (all done, or waiting on in_progress/blocked deps). If all completed: celebrate and stop. If only blocked/in_progress remain: report and stop.

### B.3 Confirm each handoff (L5)

Print child summary (title, problem, ACs, estimate, agent, deps satisfied). Ask:

```
Hand off <CHILD-ID> via /<execution_mode>? (y/n)
```

- `n` → exit cleanly; state unchanged for that child.
- `y` → continue.

### B.4 Status → in_progress + handoff (M7, M8)

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
EPIC_LIB="$PDH/skills/epic/epic-lib.sh"
EPIC_ID="<EPIC-ID>"
CHILD_ID="<CHILD-ID>"
bash "$EPIC_LIB" set-status "$EPIC_ID" "$CHILD_ID" in_progress
```

**Handoff template — PM kickoff is mandatory. There is no skip-PM path.**

```
/<execution_mode> <CHILD-ID> "<problem statement>

Acceptance criteria:
- …

Epic parent: <EPIC-ID>
depends_on: … (already satisfied)
Recommended agent: <ic4|ic5>
Estimate: <S|M|L>

Output mode: terse for agent spawns.
PM kickoff is mandatory — do not skip."
```

Invoke the existing `/kickoff` or `/orchestrate` command with that payload.
Do **not** reimplement their internals here.

### B.5 Completion

| Mode | When to mark `completed` |
|------|--------------------------|
| `orchestrate` | Child lifecycle finishes (typically `/wrap-ticket` calls `mark-done`) |
| `kickoff` | User confirms at next resume, **or** `/epic complete <ID> <CHILD>` — never auto on plan file alone |

After a child is completed, loop B.1 (next ready) or exit if user stops.

Never mark `completed` merely because kickoff produced a plan (M7).

---

## Mode C — Status

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
EPIC_LIB="$PDH/skills/epic/epic-lib.sh"
# one epic:
bash "$EPIC_LIB" show "<EPIC-ID>"
# all active:
bash "$EPIC_LIB" rollup
```

---

## Mode D — complete / block / unblock

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
EPIC_LIB="$PDH/skills/epic/epic-lib.sh"
EPIC_ID="<EPIC-ID>"
CHILD_ID="<CHILD-ID>"
# complete
bash "$EPIC_LIB" set-status "$EPIC_ID" "$CHILD_ID" completed
# block
bash "$EPIC_LIB" set-status "$EPIC_ID" "$CHILD_ID" blocked
# unblock
bash "$EPIC_LIB" set-status "$EPIC_ID" "$CHILD_ID" pending
```

---

## Mode E — `--redecompose` (M9)

1. Require explicit `--redecompose` flag.
2. Require user **yes** confirmation. Without confirmation: **no-op**.
3. Preserve completed children records (never delete/alter completed).
4. Re-run PM∥TL for non-completed only; re-merge; full-graph `check-cycle`.
5. On approve: update/replace non-completed children in state + backlog; do not duplicate backlog for unchanged completed children.
6. Linear: best-effort only for new/changed children.

---

## Integration notes

### Standup (M10)

`/status standup` runs `epic-lib.sh rollup` and prints `## Epics` when non-empty.
Sourced from `state.json`, not prose.

### wrap-ticket (SHOULD)

`/wrap-ticket` calls `epic-lib.sh mark-done "$TICKET_ID"` best-effort (matches
child `id` or `linear_id`). Unknown ticket → exit 0, no fail.

### What /epic MUST NOT do (M11)

- Write application code or spawn IC agents directly
- Run review loops
- Create/remove worktrees
- Store children in `.claude/tasks/`
- Expose any option that skips PM on child handoff

---

## Error handling

| Case | Action |
|------|--------|
| No EPIC-ID | Ask; do not guess |
| Decompose without text | Prompt for epic text |
| Cycle in DAG | Halt; zero writes; name back-edge |
| Decline approval | Exit; zero writes |
| Linear fail / absent | One-line notice; continue |
| No ready children | Report rollup; stop cleanly |
| Confirm handoff = n | Exit; child stays pending (or revert in_progress if already set — prefer confirm **before** set-status) |

Confirm **before** `set-status in_progress` so `n` leaves state unchanged (AC10).

---

## Tests

```bash
bash skills/epic/test.sh
```
