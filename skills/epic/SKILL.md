---
name: epic
description: |
    Umbrella decomposition and sequenced orchestration (SPEC-025). PM+TL
    jointly decompose an epic into child tickets + cross-ticket DAG; persist
    via Linear preferred + local write-through; walk ready children by handing each to
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
| `/epic … --no-context-discipline` | Debug opt-out of M13 between-child boundary (default **on**) |

Execution mode (`kickoff` | `orchestrate`) is chosen **once** at first execute
and stored in `state.json` (L7).

**Context discipline (M13 / CDT-127):** default **on** for multi-child Mode B.
Debug opt-out: `--no-context-discipline` **or** `EPIC_NO_CONTEXT_DISCIPLINE=1`.
Single-child epics: no mandatory boundary. See **B.6**.

---

## Step 0: Resolve roots (every bash block)

Each fenced bash block is a fresh shell — re-resolve every time (skill-lint C1).

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
DAG_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/orchestrate/dag-lib.sh)
```

---

## Dispatch

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
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

## Step 0.5: Autopilot enablement (CDT-111-C4)

Resolve autopilot **once** at run start, before any gate. `--autopilot[=<bump>]`
on the invocation or `AUTOPILOT=1` in the environment enables it; the flag wins
over the env and is the **only** channel that carries a `<bump>` (SPEC-033 M2 /
C4 FINAL #3). A malformed `--autopilot=<bump>` (bump ∉ {patch,minor,major}, incl.
empty `--autopilot=`) is a hard error (exit 64) — never a silent fall-through to
off (R7). `bump` is unused by `/epic` (which never ships, M11) but is still
resolved+carried so the seed block is identical across `/orchestrate`,
`/kickoff`, `/epic`.

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
AP=$(bash "$PDH/skills/plugin-dir.sh" file skills/autopilot/parse-flags.sh)
AP_JSON=$(bash "$AP" "$@") || { echo "$AP_JSON" >&2; exit 64; }   # 64 = malformed --autopilot=<bump>
AUTOPILOT_ON=$(jq -r .enabled <<<"$AP_JSON")
AUTOPILOT_BUMP=$(jq -r '.bump // "null"' <<<"$AP_JSON")
RUN_START_EPOCH=$(date +%s)
RUN_ID="epic-<EPIC-ID>-$RUN_START_EPOCH"    # S3-derivable per C3 §2
ITER=0                                      # ++ once per stint
```

Every later reference to `AUTOPILOT_ON` / `AUTOPILOT_BUMP` / `RUN_ID` / `ITER` /
`RUN_START_EPOCH` below means these values, carried forward from this step (fresh
shells do not carry them; the orchestrator holds them as session-local run state). Each
mapped gate — **A.5** (atomic scope+plan) and **B.3** (per child) — consults
`AUTOPILOT_ON` to choose the autopilot branch or the existing human prompt.
**A.6** defaults `MODE=orchestrate` under autopilot. **B.5 completion is NEVER
autopilot-answered (SPEC-033 N8) — it stays a human/lifecycle attestation.**

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
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
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
4. **SHOULD (M12 / OQ8):** Linear project intent — will create or link a Linear Project named **exactly** the epic title (no `EPIC-ID` prefix). Informational only; not AC-gating.

**Autopilot (CDT-111-C4 — SPEC-033 M3 / M5c):** when `AUTOPILOT_ON=true`
(§Step 0.5), do **not** wait for the user. Make **one atomic** `scope-confirm`
engine call covering scope **and** plan together — `/epic` has no separate
plan-approve gate (M5c); the single A.5 verdict is both. Invoke
`skills/autopilot/self-answer.md` with the C3 §2 envelope: `{ workflow:"epic",
ticket_id:<EPIC-ID>, gate:"scope-confirm", run_id:RUN_ID, iteration:ITER,
run_start_epoch:RUN_START_EPOCH, autopilot_bump:AUTOPILOT_BUMP, <scope signals:
epic-text sufficiency evidence, destructive-op flags, complexity signals> }`.
Consume `{ decision, blocking_condition, confidence, rationale }` and act per the
C4 Decision→action map:

- `proceed` → continue to **A.6** exactly as the human **approve** path would.
- `halt` → emit `task_blocked` (detail = the one-line message) via **Passive
  notifications → Tier B** (fail-open; § Passive notifications), then print the
  one-line message `scope-confirm halt: <rationale> — card: <card-path>` and
  **return** with **zero** disk side effects **and zero** Linear project
  create/link attempts — identical no-side-effect semantics to the human
  **decline** path below (AC12 / M3).
- any other decision follows the shared C4 Decision→action map (e.g.
  `reroute-epic` → same one-line message, then hand to `/epic` decompose).

Otherwise (autopilot off) the existing human gate applies **unchanged**:

User may edit/merge/remove children. On **decline**: exit, **zero** disk side effects **and zero** Linear project create/link attempts (AC12 / M3).

On **approve** continue A.6.

### A.6 Persist (only after approve)

Ask once for execution mode if not yet known: `kickoff` | `orchestrate`.

**Autopilot (CDT-111-C4 — SPEC-033 M5d / FINAL #5):** when `AUTOPILOT_ON=true`
(§Step 0.5), **skip the ask** and default `MODE=orchestrate` without prompting.
The ask above applies only when autopilot is off. (A.6 makes no engine call — it
is purely a function of the A.5 verdict.)

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
EPIC_ID="<EPIC-ID>"
TITLE="<epic title>"
MODE="<kickoff|orchestrate>"
bash "$EPIC_LIB" init "$EPIC_ID" --title "$TITLE" --mode "$MODE"
# linear_project_id starts null; set after M12 project resolve (below)
# per child (after Linear project + issue when MCP up — prefer --linear-id at add time):
bash "$EPIC_LIB" add-child "$EPIC_ID" \
  --id "${EPIC_ID}-C<n>" --slug "<slug>" --title "<title>" \
  --estimate S|M|L --agent ic4|ic5 \
  --depends-on '<json-array>' \
  --problem "<problem>" --ac '<json-array-of-strings>'
  # optional: --linear-id "<LINEAR-ISSUE-ID>"
```

#### Dual-write persistence (M4 — Linear preferred + local write-through)

When Linear MCP is available, resolve Linear project (M12) and create/link each
Linear issue first, then **always** write local write-through. When MCP is down,
write local only. Process trackers under `.claude/` MUST NOT be committed
(SPEC-025 M4 / SPEC-009).

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

#### Linear Project per epic (M12) — before/with child dual-write

Session owns Linear MCP; `epic-lib.sh` never calls MCP (M12.9). After `init`,
before or with child issue dual-write:

1. **MCP down** → print M5 notice (below); skip project; local path only (AC7).
2. **MCP up** — resolve **exactly one** project named the epic `title` **exactly**
   (AC2; no `EPIC-ID` prefix, no fuzzy match):
   - Call `list_projects` with `query` = epic title (substring search is fine as
     a prefilter). **Then filter client-side** to projects whose **name equals
     the epic title exactly** (string equality — not substring/prefix). Ignore
     near-matches (e.g. title + `" v2"`). If the tool paginates (default limit
     often 50), page with the cursor until no more results or an exact match is
     found — do not stop at the first page if zero exact survivors remain.
     Listing and linking need **no team** — never gate this step on team
     resolution (only `save_project` requires a team).
   - **≥1 exact survivor** → **link** the first exact survivor; do **not** create
     (AC3). If **multiple** exact-name survivors → still link the first, and print
     exactly: `Multiple Linear projects named '<title>' — linking first hit`
     (OQ3; this is a multi-hit advisory, **not** a second M5 fail-open string).
   - **Zero exact survivors → create.** First **resolve the Linear team once**
     (OQ2 / M12.3) — the team used for **both** `save_project` and child
     `save_issue` (known team from workspace/session context, or `list_teams`
     when ambiguous). Cache that team id/name and pass it to every subsequent
     `save_project` / `save_issue` in this approve path; resolve it **once**, not
     per child. Then `save_project` with `name` = epic title and
     `team` / `addTeams` = that team. If the team cannot be resolved → fail-open
     (M5 notice); skip **create only**, leave `linear_project_id` null, continue
     local. Never invent a team. The child issue path still fail-opens
     independently if it needs a team later.
   - On **any** project list/create failure → M5 notice; continue local; leave
     `linear_project_id` null (AC6).
3. **On success** — record id (atomic):
   ```bash
   # lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
   PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
   EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
   EPIC_ID="<EPIC-ID>"
   PROJECT_ID="<LINEAR-PROJECT-ID>"
   bash "$EPIC_LIB" set-linear-project "$EPIC_ID" "$PROJECT_ID"
   ```
   `show` / `rollup` surface `linear_project_id` when non-null.

#### Linear preferred (M5) — child issues + project attach

If Linear MCP tools are available (preferred SoT for open work), **per child**:

1. Create issue via `save_issue`: title `[<EPIC-ID>] <child title>`; description
   embeds local `child_id` + problem + ACs.
2. **Attach to project (M12 / AC4):** when `linear_project_id` is non-null, pass
   `project` = that id on `save_issue`. Attach failure for one child is fail-open
   for **that child only** — keep `linear_project_id`, continue remaining children
   (OQ5); print M5 notice for the failed attach if useful, do not retry-loop.
3. **Label (AC11):** `epic:<EPIC-ID>` if labels API works; else description-only.
   Project does **not** replace labels.
4. Record returned issue id: prefer Linear first then
   `add-child … --linear-id`, **or** pass `--linear-id` at add-child when known.
   Re-`add-child` is wrong if already added; `set-status` alone does not store
   `linear_id`.

Then always local backlog item + index row + `add-child` (with `--linear-id`
when known).

On **any** Linear failure or MCP absence (issue create/link, project
create/link, or child-to-project attach): print **exactly** one line

`Linear unavailable — continuing with local write-through only`

and continue. **Never** block, retry-loop, or fail the epic. Reuse this single
M5 string for project failures too (OQ7 / M5) — do not invent a second fail-open
string.

**Notify-on-done (CDT-123):** after successful A.6 persist (decompose approved and
written), emit `task_complete` (detail = `epic decompose complete: <EPIC-ID>`) via
**Passive notifications → Tier B** (fail-open; § Passive notifications). Skip if the
run halted at A.5.

Then enter **Execute / Resume**.

---

## Mode B — Execute / Resume (prompt-driven walker)

### B.1 Rollup

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
EPIC_ID="<EPIC-ID>"
bash "$EPIC_LIB" show "$EPIC_ID"
bash "$EPIC_LIB" waves "$EPIC_ID"
```

Print counts by status + ready set + wave plan. **No re-decomposition.** No duplicate backlog/Linear.

**Resume seed (M13):** if `show` surfaces non-null `last_seed_path`, print
`@<last_seed_path>` and treat that seed as the live context source for the
next child (plus `show`/`waves`/`ready-set` rollup). Do **not** re-mine prior
child transcripts.

**Linear project on resume (M12 / AC8 / OQ4):**

- If `linear_project_id` is **non-null** (`show` / state): do **not**
  `list_projects` / `save_project`; do **not** re-attach existing children
  (no attach storm).
- If `linear_project_id` is **null**: do **not** create or link a project on
  bare resume — create/link only on new approved decompose, or approved
  `--redecompose` when id is still null.

### B.2 Ready set → first child (stable id sort)

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
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

**Autopilot (CDT-111-C4 — SPEC-033 M5):** when `AUTOPILOT_ON=true` (§Step 0.5),
do **not** print the `(y/n)` prompt. For **each** child popped off the ready set,
make **one** `scope-confirm` engine call via `skills/autopilot/self-answer.md`
with the C3 §2 envelope — `ticket_id` = **that child's** `<CHILD-ID>`:
`{ workflow:"epic", ticket_id:<CHILD-ID>, gate:"scope-confirm", run_id:RUN_ID,
iteration:ITER, run_start_epoch:RUN_START_EPOCH, autopilot_bump:AUTOPILOT_BUMP,
<scope signals: child issue-text sufficiency, destructive-op flags, complexity> }`.
Consume `{ decision, blocking_condition, confidence, rationale }` and act:

- `proceed` → continue to **B.4** (status → in_progress + handoff) exactly as the
  human `y` path would.
- `halt` → emit `task_blocked` (detail = the one-line message) via **Passive
  notifications → Tier B** (fail-open; § Passive notifications), then print
  `scope-confirm halt: <rationale> — card: <card-path>` and **return**; that
  child's state is **unchanged** (no `set-status`), identical to the human `n`
  path (preserves AC10: confirm before `set-status`).
- any other decision follows the shared C4 Decision→action map (e.g.
  `reroute-epic` → same one-line message, then hand that child to `/epic`
  decompose per M11 self-reroute).

### B.4 Status → in_progress + handoff (M7, M8)

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
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

Prefer optional `--outcome "<≤1 line>"` on `set-status … completed|blocked`
(Mode D) so seeds carry status+summary without re-reading child sessions.

After a child leaves the active handoff (`completed`, or `blocked` with no
ready successor to start mid-path), **before** the next B.3: run **B.6** when
discipline applies. Then loop B.1 / B.2 (next ready) or exit if user stops.

Never mark `completed` merely because kickoff produced a plan (M7).
**Kickoff mode:** M13 boundary still applies between children; completion
attestation is unchanged (user/`/epic complete` — never auto on plan alone).

### B.6 Between-child context discipline (M13 / CDT-127)

**When (default on):** epic has **≥2 children**, discipline not opted out
(`--no-context-discipline` / `EPIC_NO_CONTEXT_DISCIPLINE=1`), and walker is about
to start child **N+1** after child **N** left the active handoff. **Between
children only** — not mid-`/orchestrate`. Single-child: skip. **Blocked:**
seed is still OK; `ready-set` continues to respect deps (M7 — never skip
blocked deps).

**Primary = hard cut (A).** After status write via `epic-lib` only (status =
sole SoT; seed is advisory narrative — **no dual status SoT**):

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
EPIC_ID="<EPIC-ID>"
NEXT="<next ready CHILD-ID or omit --next for auto>"
# Prefer mechanical build-seed (records last_seed_path on success):
SEED_PATH=$(bash "$EPIC_LIB" build-seed "$EPIC_ID" --next "$NEXT") || {
  echo "context-discipline: seed failed — build-seed failed"
  # halt: do NOT set-status in_progress on next child; leave pending
  return
}
bash "$EPIC_LIB" validate-seed "$SEED_PATH" || {
  echo "context-discipline: seed failed — validate-seed failed"
  return
}
echo "@$SEED_PATH"
```

**Fail-closed:** any build/validate failure → print exact one-liner
`context-discipline: seed failed — <reason>`, **do not** start next child, leave
next `pending` (confirm-before-`in_progress` preserved). Reason = CLI stderr /
short cause (empty, missing sections, unreadable path).

**Hard-cut degrade ladder** (after valid seed; before next B.3/B.4):

1. **Prefer:** new session / harness branch-fork seeded with `@<seed-path>` +
   state rollup only.
2. **Fallback:** same-session `/compact` (or equivalent), then load only
   `@seed` + `show`/`waves`/`ready-set`.
3. **MUST NOT** continue Mode B **inline while prior child plan/review/QA/TL/council
   transcripts remain live context** when discipline is on.

Allowed live inputs after cut: compact epic seed + `state.json` rollup + optional
prior seed path. Resume next child only from seed + state (no re-decomposition).

**Secondary = guardrail (C).** Between children only: if estimated live context is
**≥ ~400k tokens** or **≥ 50% of the model window**, **warn and force** the same
M13 hard-cut (not warn-only). Estimation: session heuristic / human dogfood until
free telemetry. Mid-child guardrail = OOS. Guardrail alone is never the primary.

**Autopilot:** boundary is **silent mechanical** on success — **not** a new
SPEC-033 gate enum. Decision card **only** on seed-fail halt path.

**M11 under M13:** boundary / seed / guardrail spawn no ICs, create no worktrees,
write no `.claude/tasks/`, do not re-implement kickoff/orchestrate.

**CDT-126 non-goal:** council `--tier light` reduces **council** cost inside a
child; it does **not** replace M13 epic-walker context cuts.

**Measurement (AC2/AC3):** design target child-N peak ≤ child-1 peak × (1+**ε**)
with **ε = 0.5** (peak per-turn context or cache-read proxy; ≥3 sequential
children). **CI = seed shape + protocol presence only.** Peak/cache-read =
**dogfood/manual** until free token telemetry (log method + pass/fail per run).

---

## Mode C — Status

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
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
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
EPIC_ID="<EPIC-ID>"
CHILD_ID="<CHILD-ID>"
# complete (optional --outcome "≤1 line" for seed outcomes)
bash "$EPIC_LIB" set-status "$EPIC_ID" "$CHILD_ID" completed --outcome "<summary>"
# block
bash "$EPIC_LIB" set-status "$EPIC_ID" "$CHILD_ID" blocked --outcome "<reason>"
# unblock
bash "$EPIC_LIB" set-status "$EPIC_ID" "$CHILD_ID" pending
```

---

## Mode E — `--redecompose` (M9 + M12)

1. Require explicit `--redecompose` flag.
2. Require user **yes** confirmation. Without confirmation: **no-op**.
3. Preserve completed children records (never delete/alter completed).
4. Re-run PM∥TL for non-completed only; re-merge; full-graph `check-cycle`.
5. On approve: update/replace non-completed children in state + backlog; do not duplicate backlog for unchanged completed children.
6. **Linear project (M12 / AC9):**
   - If `linear_project_id` is **non-null**: **reuse** it — do not create/list a
     second project; id stays stable. Attach **only new/changed** children to
     that project on dual-write (no re-attach of unchanged/completed children).
   - If `linear_project_id` is **null** and MCP is up after approve: run the
     A.6 M12 create/link path **once**, then
     `set-linear-project`; attach new/changed dual-written children.
   - Project/attach failures → same M5 one-liner; local continues.
7. Linear issues: best-effort only for new/changed children (`save_issue` with
   `project` when id known + `epic:<EPIC-ID>` labels — AC11).

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
- Treat seed packets as status authority (status SoT = `epic-lib` / `state.json` only)
- Inline next-child handoff while prior child transcripts remain live context when M13 discipline is on

---

## Error handling

| Case | Action |
|------|--------|
| No EPIC-ID | Ask; do not guess |
| Decompose without text | Prompt for epic text |
| Cycle in DAG | Halt; zero writes; name back-edge |
| Decline approval | Exit; zero writes **including** zero Linear project create/link (AC12) |
| Linear fail / absent (issue, project, or attach) | Exactly: `Linear unavailable — continuing with local write-through only`; continue local (M5/M12) |
| Project multi-hit exact name | Link first exact survivor; print exactly `Multiple Linear projects named '<title>' — linking first hit`; do not create (OQ3) |
| Child attach fail | Keep `linear_project_id`; continue other children (OQ5) |
| Bare resume + null project id | Do not create/link project (OQ4) |
| No ready children | Report rollup; stop cleanly |
| Confirm handoff = n | Exit; child stays pending (or revert in_progress if already set — prefer confirm **before** set-status) |
| M13 seed build/validate fail | Exactly: `context-discipline: seed failed — <reason>`; next child stays `pending`; no `in_progress` without valid seed when boundary required |

Confirm **before** `set-status in_progress` so `n` leaves state unchanged (AC10).

---

## Passive notifications (CDT-123 / CDV-210 Tier B)

Same fail-open webhook sink as `/orchestrate` (`skills/notify/webhook.sh`). Never
block `/epic` on notify failure. Unset `AGENT_WEBHOOK_URL` → silent.

At each site that says **Passive notifications → Tier B**, run (fresh shell):

```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
NOTIFY=$(bash "$PDH/skills/plugin-dir.sh" file skills/notify/webhook.sh)
NOTIFY_SOURCE=epic NOTIFY_TICKET="<EPIC-ID or CHILD-ID>" \
  bash "$NOTIFY" <event> "<detail ≤500 chars>"
```

| Event | Epic call site |
|-------|----------------|
| `task_blocked` | Autopilot halt at A.5 (atomic scope+plan) or B.3 (per-child handoff) |
| `task_complete` | Successful A.6 persist after approve; optional: epic all-children completed |

---

## Tests

```bash
bash skills/epic/test.sh
```
