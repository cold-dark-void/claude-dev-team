---
name: epic
description: |
    Umbrella decomposition and sequenced orchestration (SPEC-025). PM+TL
    jointly decompose an epic into child tickets + cross-ticket DAG; persist
    via Linear preferred + local write-through; walk ready children by handing each to
    /kickoff or /orchestrate. Composition layer only — never reimplements the
    ticket lifecycle. Usage: /epic <EPIC-ID> ["text"] | status | complete |
    block | unblock | sync | --redecompose | [--worktree] [--release <bump>]
---

# Epic — Umbrella Decomposition & Sequenced Orchestration

Governing spec: `specs/core/SPEC-025-epic-umbrella-decomposition.md`.

**Composition rule (M11):** `/epic` ends at the handoff string. It does **not**
inline kickoff/orchestrate steps, spawn IC agents, write application code,
create **per-child** worktrees, or write epic children into `.claude/tasks/`.
**M14 carve-out:** MAY ensure/route one integration worktree (`epic-<ID>`) and
compose end-of-epic seal; MUST NOT re-implement full orchestrate lifecycle or
`/release` version/tag/push.

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
| `/epic sync <ID> [--dry-run]` | Refresh local `state.json` from Linear (M15) when state may be stale |
| `/epic … --worktree` | (decompose/execute/resume/`--redecompose` only) Enable epic integration-worktree mode (SPEC-025 M14 / CDT-141). Bare flag only — value forms hard-fail (exit 64). Persists `worktree_enabled=true` on init when set. After init (and on resume when state enabled): ensure **one** integration worktree `epic-<EPIC-ID>` (C2). On resume: omit to honor store; present must match state or exit 64 (C6). Illegal on `status` \| `complete` \| `block` \| `unblock`. |
| `/epic … --release <bump>` | (with `--worktree` only) End-of-epic release bump intent; `<bump>` ∈ {patch,minor,major}. Space form canonical; `--release=<bump>` accepted alias. Alone / bare / `each`\|`end` / without `--worktree` → exit 64, zero side effects. Persists `release_bump` on init. Resume: omit honors store (no silent clear); mismatch → 64 (C6). After last child: Mode B.7 seal once (squash → one `/release <bump>` → `sealed=true`; C5). Without this flag: no epic seal. Orthogonal to `--autopilot`. |
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
- `sync` → **Mode F — Sync** (Linear → local; requires state)
- `--redecompose` → **Redecompose mode** (requires confirm)
- else if `exists` → **Execute / Resume**
- else → **Decompose mode** (needs epic text)

---

## Step 0.4: Worktree / release flags (CDT-141 / SPEC-025 M14)

Locked contract: SPEC-025 M14 CLI table, semantics, illegal combos, done-when
1–7, non-public API. Parse **once** at run start, **before** any
state/Linear/backlog/worktree side effects. Own parser — **not**
`skills/autopilot/parse-flags.sh`.

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
EPIC_PARSE=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/parse-flags.sh)
EPIC_ID="<EPIC-ID>"
# Resume (state exists): honor store / hard-fail conflict (C6). New decompose: pure parse.
if bash "$EPIC_LIB" exists "$EPIC_ID"; then
  EPIC_FLAGS=$(bash "$EPIC_LIB" resolve-resume-flags "$EPIC_ID" -- "$@") \
    || { echo "$EPIC_FLAGS" >&2; exit 64; }
else
  EPIC_FLAGS=$(bash "$EPIC_PARSE" "$@") || { echo "$EPIC_FLAGS" >&2; exit 64; }
fi
WORKTREE_ENABLED=$(jq -r .worktree_enabled <<<"$EPIC_FLAGS")
RELEASE_BUMP=$(jq -r '.release_bump // "null"' <<<"$EPIC_FLAGS")   # literal null or patch|minor|major
```

Rules (hard-fail exit **64**, zero side effects):
- bare `--worktree` only; `--worktree=*` rejected
- `--release <bump>` (space canonical) or `--release=<bump>`; bump ∈ {patch,minor,major}
- `--release` without `--worktree` → 64; bare/empty/`each`/`end` → 64
- rejected surface: `--bump`, `--land`, `--seal`
- duplicate `--worktree` or `--release` → 64
- flags illegal with first positional `status` | `complete` | `block` | `unblock` | `sync`
- allowed on decompose / execute-resume / `--redecompose` only

### Resume flag-vs-state policy (CDT-141-C6) — hard-fail, no silent downgrade

When `state.json` **exists** (execute/resume / re-invoke same epic):

| CLI M14 flags | Policy |
|---------------|--------|
| **Omitted** (`--worktree` / `--release` absent) | **Honor store**: effective modes = `state.worktree_enabled // false` and `state.release_bump // null`. End-of-epic release intent (non-null `release_bump`) is **never** cleared by a bare resume. |
| **Present and match** state | OK — same modes; continue. |
| **Present and conflict** with state | **Exit 64**, zero side effects. No silent enable/disable of worktree, no silent change or clear of `release_bump` (no downgrade of end-release mode). |

Defaults path (never used `--worktree`/`--release` at init — keys absent) + flags omitted → `false`/`null`; resume unchanged. Do **not** re-decompose; do **not** require pasting a prior handoff string for tree/branch continuity — B.1 `ensure-integration-worktree` reuses the recorded `epic-<ID>` path/branch from state.

On **new** `init` when `WORKTREE_ENABLED=true`, pass modes into epic-lib so state
records them (omit keys when both default — AC6/AC7):

```bash
# Re-resolve roots + flags (fresh shell — SPEC-021 C1). Modes from Step 0.4 parse result.
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
EPIC_ID="<EPIC-ID>"
TITLE="<epic title>"
MODE="<kickoff|orchestrate>"
WORKTREE_ENABLED="<true|false>"   # from Step 0.4
RELEASE_BUMP="<null|patch|minor|major>"  # from Step 0.4
INIT_EXTRA=()
if [ "$WORKTREE_ENABLED" = true ]; then
  INIT_EXTRA+=(--worktree-enabled true)
  if [ "$RELEASE_BUMP" != "null" ] && [ -n "$RELEASE_BUMP" ]; then
    INIT_EXTRA+=(--release-bump "$RELEASE_BUMP")
  fi
fi
bash "$EPIC_LIB" init "$EPIC_ID" --title "$TITLE" --mode "$MODE" "${INIT_EXTRA[@]}"
```

**C2 integration worktree (when `worktree_enabled`):** after successful `init`
(and on Mode B resume when state has `worktree_enabled=true`), call:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
EPIC_ID="<EPIC-ID>"
bash "$EPIC_LIB" ensure-integration-worktree "$EPIC_ID"
```

Creates or reuses exactly one worktree at `$MROOT/.worktrees/epic-<EPIC-ID>`
(branch `feat/epic-<EPIC-ID>` via worktree-lib). Records
`integration_slug` / `integration_path` / `integration_branch` on state.
When `worktree_enabled` is false/absent: no-op exit 0. Re-invoke reuses the
same tree (no second integration worktree). Carry `WORKTREE_ENABLED` /
`RELEASE_BUMP` as session-local run state (from resolve-resume-flags on resume).

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
WORKTREE_ENABLED="<true|false>"   # from Step 0.4 session state
RELEASE_BUMP="<null|patch|minor|major>"  # from Step 0.4 session state
INIT_EXTRA=()
if [ "$WORKTREE_ENABLED" = true ]; then
  INIT_EXTRA+=(--worktree-enabled true)
  if [ "$RELEASE_BUMP" != "null" ] && [ -n "$RELEASE_BUMP" ]; then
    INIT_EXTRA+=(--release-bump "$RELEASE_BUMP")
  fi
fi
bash "$EPIC_LIB" init "$EPIC_ID" --title "$TITLE" --mode "$MODE" "${INIT_EXTRA[@]}"
# CDT-141-C2: one integration worktree when worktree_enabled (no-op otherwise)
bash "$EPIC_LIB" ensure-integration-worktree "$EPIC_ID"
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

If Linear MCP tools are available (preferred SoT for open work):

##### M4.1 Link-before-create (inventory → adopt | create | halt)

**Before any child `save_issue` create**, inventory existing parented children
(SPEC-025 M4.1). Session-owned MCP only (`epic-lib` never calls Linear).

1. **Inventory:** `list_issues` with `parentId=<EPIC-ID>`, page until exhausted
   (`limit` 50–250 + `cursor`). Request fields at least: `id`, `title`,
   `description`, `status`, `statusType`, `projectId` (identifier/url as available).
   Prefer `includeArchived=false`. **Survivors** = rows whose `statusType` is
   **not** `canceled` (include completed/done; drop canceled).
2. **Inventory failure** (tool error / unusable response) → print the single M5
   notice below; **skip all Linear child creates** for this approve path; continue
   local write-through only. Prefer missing Linear links over silent duplicates.
3. **Zero survivors → create path** (per-child steps below).
4. **≥1 survivor → adopt path — MUST NOT create a second child set:**
   - **Match** each proposed local child to ≤1 survivor, in order:
     1. Description embeds `child_id: <EPIC-ID>-C<n>` or the bare local id
     2. Unique exact match on **normalized title**: lowercase; strip leading
        `[<EPIC-ID>]`, `E<n>:`, `C<n>:`, `<EPIC-ID>-C<n>` (optional trailing
        punctuation/space)
     3. If `|survivors| == |proposed|` and a collision-free case-insensitive
        unique title map exists (normalized short titles), use it
   - **Full unique map:** for each pair, record Linear id as `linear_id`;
     best-effort attach to `linear_project_id` when set and missing; best-effort
     `epic:<EPIC-ID>` label; optional description patch to embed `child_id` if
     absent (fail-open). **Zero** `save_issue` creates. Local backlog + index +
     `add-child … --linear-id` as usual. Print one advisory line:
     `Adopted N existing Linear child(ren) under <EPIC-ID> — no new issues created`
   - **Ambiguous / partial map:** print **exactly**:
     `HALT: Linear already has N child issue(s) under <EPIC-ID> — adopt or confirm force-create; refusing duplicate create`
     Then list survivors (`id` + title) and proposed children. **Zero** Linear
     child creates. Human may: supply adopt map, **explicit** force-create
     override, or abort. **Autopilot:** full unique map → adopt (silent except
     the advisory); ambiguous → emit `task_blocked` (Tier B) and **return** —
     MUST NOT force-create under autopilot.

##### Create path (only when zero inventory survivors, or explicit force-create)

**Per child:**

1. Create issue via `save_issue`: title `[<EPIC-ID>] <child title>`; description
   embeds local `child_id` + problem + ACs. (Parent-edge on **create** remains
   deferred — M12 project + label group children; M4.1 only *reads* parentId.)
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
create/link, or child-to-project attach) — **except** M4.1 ambiguous halt,
which is intentional stop: print **exactly** one line

`Linear unavailable — continuing with local write-through only`

and continue. **Never** block, retry-loop, or fail the epic on transport/MCP
errors. Reuse this single M5 string for project failures too (OQ7 / M5) — do not
invent a second fail-open string. M4.1 ambiguous halt uses its own HALT line
above (not the M5 transport string).

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
# CDT-141-C2/C6: reuse/ensure same integration WT when state.worktree_enabled (no-op if false)
# Modes already resolved in Step 0.4 (honor store / conflict 64). No handoff paste needed.
bash "$EPIC_LIB" ensure-integration-worktree "$EPIC_ID"
bash "$EPIC_LIB" show "$EPIC_ID"
bash "$EPIC_LIB" waves "$EPIC_ID"
```

Print counts by status + ready set + wave plan. **No re-decomposition.** No duplicate backlog/Linear.
When `show` surfaces non-null `integration_path`, note the epic integration
worktree (operator continuity — same path/branch as prior session; CDT-141-C6).
Children share it (CDT-141-C3): B.4 handoff + `ensure-ticket-worktree`.

**Stale-state tip (M15):** when Linear MCP is up and state has any child
`linear_id` **or** any null `linear_id`, print one soft line (not a gate):
`Tip: /epic sync <EPIC-ID> refreshes status/linear_id from Linear when state may be stale`
Do **not** auto-run sync on every resume (M9 no surprise mutations).

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

If empty: print `No ready children` (all done, or waiting on in_progress/blocked deps). If all completed: run **B.7** seal path when `release_bump` is set, then celebrate and stop. If only blocked/in_progress remain: report and stop.

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
# CDT-141-C3: surface shared integration path for handoff (no-op fields when disabled)
CHILD_WT=$(bash "$EPIC_LIB" resolve-child-worktree "$CHILD_ID")
USE_SHARED=$(jq -r '.use_shared // false' <<<"$CHILD_WT")
INT_PATH=$(jq -r '.integration_path // empty' <<<"$CHILD_WT")
INT_BRANCH=$(jq -r '.integration_branch // empty' <<<"$CHILD_WT")
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

**When `use_shared=true` (epic `--worktree` / `worktree_enabled` + integration path set) — append to the handoff payload and export for the child run:**

```
Epic integration worktree: <INT_PATH>
Epic integration branch: <INT_BRANCH>
EPIC_INTEGRATION_PATH=<INT_PATH>

Do NOT create a per-child worktree (no feat/<CHILD-ID>, no .worktrees/<CHILD-ID>).
Work only in the epic integration tree above. Child commits land on <INT_BRANCH>.
/wrap-ticket for this child MUST NOT release the integration worktree.
```

Export `EPIC_INTEGRATION_PATH=<INT_PATH>` in the environment of the `/kickoff` or
`/orchestrate` invocation when shared. Child Step 3 / 1b calls
`epic-lib ensure-ticket-worktree` which skips per-child `worktree-lib ensure`.

**CDT-141-C4 — when durable `release_bump` is non-null (release=end):** also
export and append:

```
EPIC_RELEASE_END=<EPIC-ID>
release=end: mid-child /release and master-merge are FORBIDDEN until epic seal (CDT-141).
Ship child via PR-stop or leave commits on the integration branch only.
```

```bash
# From show / state (durable — resume-safe); re-resolve (fresh shell — C1)
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
EPIC_ID="<EPIC-ID>"
RB=$(bash "$EPIC_LIB" show "$EPIC_ID" | jq -r '.release_bump // empty')
if [ -n "$RB" ] && [ "$RB" != "null" ]; then
  export EPIC_RELEASE_END="$EPIC_ID"
fi
```

`/release` Step 0 and orchestrate Step 11 call
`epic-lib assert-release-allowed <ticket-or-epic>` (exit 64 + message while
mid-flight). Without `--release` on the epic, omit this block.

When `use_shared=false` (default / no `--worktree`): omit the shared-WT block;
per-child worktree behavior is unchanged. Still export `EPIC_RELEASE_END` when
`release_bump` is set (release=end always couples to `--worktree` at parse time).

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
When the loop finds **all children completed**, run **B.7** (end-of-epic seal).

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

### B.7 End-of-epic seal (CDT-141-C5 / M14)

Runs **once** after the **last** child reaches `completed`, and **only** when
durable `release_bump` is non-null (epic was started with `--worktree --release
<bump>`). Without `--release`, there is **no** epic seal path — children ship
as today (per-child `/release` / merge unchanged).

Mechanical CLI (subprocess only):

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
EPIC_ID="<EPIC-ID>"

# Pure check (ready=false when no release_bump / incomplete / already sealed)
bash "$EPIC_LIB" seal-ready "$EPIC_ID"
# Optional plan only:
# bash "$EPIC_LIB" seal "$EPIC_ID" --dry-run
```

**When `seal-ready` reports `ready=true`:**

1. **Squash-stage** integration onto master/main (no commit):
   ```bash
   _gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
EPIC_ID="<EPIC-ID>"
bash "$EPIC_LIB" seal "$EPIC_ID"
   # stdout: staged=true, handoff="/release <bump>", env.EPIC_ALLOW_SEAL_RELEASE=1
   ```
2. **Exactly one** `/release <release_bump>` (bump from durable state — not a
   separate `--bump` flag). `/release` remains the ship-of-record (version
   pair + single fold-commit + tag/push). Export for the single invocation:
   ```bash
   _gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
EPIC_ID="<EPIC-ID>"
RB=$(bash "$EPIC_LIB" show "$EPIC_ID" | jq -r .release_bump)
   export EPIC_ALLOW_SEAL_RELEASE=1
   export EPIC_ID EPIC_RELEASE_END="$EPIC_ID"
   # Then invoke skills/release/SKILL.md with /release $RB  (once)
   ```
3. **On `/release` success** — mark sealed atomically:
   ```bash
   _gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
EPIC_ID="<EPIC-ID>"
bash "$EPIC_LIB" seal "$EPIC_ID" --complete
   ```
4. **On `/release` or squash failure** — leave `sealed=false` (no partial
   tag/push from seal; master not half-shipped). **Bare** `seal --abort` is
   safe cleanup **only when main is clean** (porcelain empty): it hard-resets
   seal staging then exits 0. If main is **dirty** (unrelated WIP or leftover
   seal dirt), bare `--abort` **refuses** (exit **1**, WIP preserved — CDT-170).
   When the orchestrator just staged seal and needs a wipe after failure (or
   any intentional dirty wipe), use `seal --abort --force`:
   ```bash
   _gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
EPIC_ID="<EPIC-ID>"
# Post-stage / intentional wipe (main usually dirty after squash-stage).
# Bare --abort only when main is clean (dirty → exit 1, WIP preserved).
bash "$EPIC_LIB" seal "$EPIC_ID" --abort --force
   ```

**Invariants:**
- Seal path runs **once** (`sealed=true` → further `seal` is `already_sealed` no-op).
- Master receives epic delivery **only** at seal (C4 forbids mid-epic land).
- Exactly one versioned release commit for the epic (`/release` contract).
- Bare `seal --abort` MUST NOT wipe dirty main WIP; `--abort --force` MAY
  hard-reset+clean (operator/orchestrator recovery only; CDT-170).
- `EPIC_SEAL_RELEASE_HOOK` (tests only) may stand in for `/release`; production
  orchestrator always uses `/release` as SoT.

**When `release_bump` is null/absent:** `seal` / `seal-ready` skip (`reason=
no_release_bump`) — zero squash, zero `/release` from epic.


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

## Mode F — `/epic sync <EPIC-ID> [--dry-run]` (M15)

**When:** local `$MROOT/.claude/epics/<EPIC-ID>/state.json` exists but may be
**stale** vs Linear (status closed in Linear, null `linear_id`, wrong project id,
orphans under parent). **Not** re-decomposition (use `--redecompose`).

**Requires:** `exists` → else print `No state for epic <ID> — nothing to sync`
and stop (exit non-zero / return). Illegal with `--worktree` / `--release`
(parse-flags exit 64).

### F.1 Inventory (session-owned MCP)

When Linear MCP is **down**: print M5 one-liner
`Linear unavailable — continuing with local write-through only`, then stop with
**zero** `state.json` mutation (sync has nothing to pull).

When MCP is **up**:

1. `list_issues parentId=<EPIC-ID>` — page until exhausted; same survivor filter
   as M4.1 (not `canceled`). Fields: `id`, `title`, `description`, `status`,
   `statusType`, `projectId` / identifier as available.
2. Optional: if `linear_project_id` is null, resolve project by exact epic
   `title` (M12.2 link-only rules) — do **not** create a project on sync.
3. **Map** each local child to ≤1 Linear survivor:
   - Prefer exact `linear_id` match (identifier or UUID as stored)
   - Else M4.1 title / `child_id`-in-description match
4. **statusType → local status** (session maps before apply):
   - `completed` / done → `completed` (Linear Done only — not In Review)
   - `canceled` → `blocked`
   - `started` → `in_progress` (covers **In Progress** and **In Review** —
     review is still open work for epic walkers; do not treat as completed)
   - else (`unstarted`, backlog, triage, …) → `pending`
5. Build verdicts JSON (TMPDIR):

```json
{
  "linear_project_id": "<optional when local null and known>",
  "children": [
    { "id": "<EPIC-ID>-C1", "linear_id": "CDT-…", "status": "completed",
      "outcome_summary": "optional ≤1 line from Linear title/state" }
  ],
  "orphans": [{ "linear_id": "…", "title": "…" }],
  "unmatched_local": ["<EPIC-ID>-C3"]
}
```

- **orphans:** Linear survivors with no local child map (report only — never
  auto-add children; that needs approve/`--redecompose`)
- **unmatched_local:** local children with null `linear_id` and no unique match

### F.2 Apply (mechanical)

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sed 's/-pre\./~pre./' | sort -V | tail -1 | sed 's/~pre\./-pre./' | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
EPIC_ID="<EPIC-ID>"
VERDICTS="${TMPDIR:-/tmp}/epic-sync-verdicts-$$.json"
# write F.1 verdicts into $VERDICTS
# DRY_RUN=1 when user passed --dry-run
if [ "${DRY_RUN:-0}" = "1" ]; then
  bash "$EPIC_LIB" sync-apply "$EPIC_ID" --verdicts "$VERDICTS" --dry-run
else
  bash "$EPIC_LIB" sync-apply "$EPIC_ID" --verdicts "$VERDICTS"
fi
rm -f "$VERDICTS"
```

**`sync-apply` invariants (epic-lib, no MCP):**

| Rule | Behavior |
|------|----------|
| Fill `linear_id` | Only when local null/empty |
| `linear_id` mismatch | Conflict; leave local |
| Status same | Skip |
| Status forward | Apply (e.g. pending→completed) |
| `completed` → non-completed | **Skip** (`no_downgrade_completed`) — never re-open wrapped work |
| `linear_project_id` | Fill only when local null; never clear; mismatch → conflict |
| Unknown child / invalid status | Conflict skip |
| Orphans | Report only |
| `--dry-run` | Report planned actions; **zero** disk write |

Print the JSON report (applied / skipped / conflicts / orphans). On conflicts or
orphans, tell the user: orphans need manual map or `--redecompose`; mismatches
need human fix.

**Autopilot:** `/epic sync` is not a SPEC-033 gate; if invoked under autopilot,
apply the same safe rules (no force reopen, no create, no auto-add orphans).

**Does NOT:** create Linear issues, re-decompose, delete children, attach-storm
all children to a project, or run Mode B handoff.

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
7. Linear issues: best-effort only for new/changed children. **M4.1 first:**
   inventory `list_issues(parentId=<EPIC-ID>)`; adopt unique map for children
   that already exist; **create only** for proposed children with no survivor
   match when the overall map is non-ambiguous (or after explicit force-create).
   Never blind-create a full second set when parent already has survivors.
   `save_issue` with `project` when id known + `epic:<EPIC-ID>` labels — AC11.

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
- Create/remove **per-child** worktrees (or any worktree outside the M14 integration carve-out)
- Store children in `.claude/tasks/`
- Expose any option that skips PM on child handoff
- Treat seed packets as status authority (status SoT = `epic-lib` / `state.json` only)
- Inline next-child handoff while prior child transcripts remain live context when M13 discipline is on

**M11 carve-out (CDT-141-C2/C3/C5 / M14):** when `worktree_enabled`, `/epic` **MAY**
ensure **exactly one** integration worktree (`epic-<EPIC-ID>` via
`ensure-integration-worktree` → worktree-lib) and **route** child handoffs into
it (`resolve-child-worktree` / `ensure-ticket-worktree` + B.4 template). At
end-of-epic with `release_bump` set, **MAY** run **B.7** seal composition
(`seal-ready` / `seal` → squash-stage + one `/release` + `sealed=true`). Still
MUST NOT create per-child worktrees, remove worktrees (including the integration
tree on child wrap), re-implement kickoff/orchestrate WT lifecycle, or fork
`/release`'s version/tag/push contract.

---

## Error handling

| Case | Action |
|------|--------|
| No EPIC-ID | Ask; do not guess |
| Decompose without text | Prompt for epic text |
| Cycle in DAG | Halt; zero writes; name back-edge |
| Decline approval | Exit; zero writes **including** zero Linear project create/link (AC12) |
| Linear fail / absent (issue, project, or attach) | Exactly: `Linear unavailable — continuing with local write-through only`; continue local (M5/M12) |
| Linear inventory fail (M4.1) | M5 notice; **skip Linear child creates**; local write-through only (no silent duplicates) |
| Linear parent has ≥1 non-canceled child (M4.1) | Adopt unique map (zero creates) **or** HALT with exact line `HALT: Linear already has N child issue(s) under <EPIC-ID> — adopt or confirm force-create; refusing duplicate create`; autopilot never force-creates |
| `/epic sync` no state | Report nothing to sync; stop |
| `/epic sync` MCP down | M5 notice; zero state mutation |
| `/epic sync` stale local | `sync-apply` fills null `linear_id` / project id; pulls status forward; never downgrades `completed`; orphans report-only |
| Project multi-hit exact name | Link first exact survivor; print exactly `Multiple Linear projects named '<title>' — linking first hit`; do not create (OQ3) |
| Child attach fail | Keep `linear_project_id`; continue other children (OQ5) |
| Bare resume + null project id | Do not create/link project (OQ4) |
| Resume M14 flags omitted | Honor stored `worktree_enabled` / `release_bump` (C6); ensure same integration tree |
| Resume M14 flags conflict with state | Exit **64**, zero side effects; no silent mode change/downgrade (C6) |
| All children completed + `release_bump` set | **B.7** seal once: squash-stage → one `/release <bump>` → `sealed=true` (C5) |
| Seal failure (B.7 post-stage) | `seal --abort --force`; `sealed` stays false; wipes seal dirt; no partial tag/push (C5/CDT-170) |
| Seal abort (main clean only) | Bare `seal --abort`; resets seal staging; exit 0. Dirty main → exit **1**, WIP preserved — use `--force` for intentional wipe (CDT-170) |
| No `release_bump` at end | No epic seal path (C5) |
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
