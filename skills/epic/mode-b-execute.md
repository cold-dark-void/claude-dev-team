<!-- /epic stage body — load via SKILL.md router; read only the current stage. -->

**Stage anchor (run once per stage; fresh-shell safe):**

```bash
# Locate the dev-team plugin root (PDH). Optional CLAUDE_PLUGIN_ROOT (force path / FR #48230), else cwd only when it is the dev-team plugin itself (CDT-265), else marketplace clone (slug-free agents/pm.md), else installed cache (rank by /dev-team/<VER>/ segment, not full path; CDT-166). CDT-82: marketplace before same-version cache.
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
printf 'PDH=%s\n' "$PDH" >&2
```

## Mode B — Execute / Resume (prompt-driven walker)

### B.1 Rollup

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
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
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
EPIC_ID="<EPIC-ID>"
READY=$(bash "$EPIC_LIB" ready-set "$EPIC_ID")
CHILD=$(printf '%s\n' "$READY" | head -1)
```

If empty: print `No ready children` (all done, or waiting on in_progress/blocked deps). If all completed: run **B.7** seal path when `release_bump` is set, then celebrate and stop. If only blocked/in_progress remain: report and stop. **B.7** MUST NOT run while ready-set is non-empty.

Same-run continue while `ready-set` is non-empty lives in **B.5** (`AUTOPILOT_ON`) — not this empty-set stop.

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
max_loc:MAX_LOC, <scope signals: child issue-text sufficiency, destructive-op flags, complexity> }`.
Consume `{ decision, blocking_condition, confidence, rationale }` and act:

- `proceed` → continue to **B.4** (status → in_progress + handoff) exactly as the
  human `y` path would.
- `halt` → emit `task_blocked` (detail = the one-line message) via **Passive
  notifications → Tier B** (fail-open; § Passive notifications), then print
  `scope-confirm halt: <rationale> — card: <card-path>` and **return**; that
  child's state is **unchanged** (no `set-status`), identical to the human `n`
  path (preserves AC10: confirm before `set-status`).
- `reroute-epic` (BC5: this child alone overflows one ticket) → treat as `halt`
  (emit `task_blocked`, print `scope-confirm reroute-epic: <rationale> — card:
  <card-path>`, **return**, child unchanged). A nested epic for a child is
  **not allowed:** one epic holds one flat child list (SPEC-025 M6), and a
  nested epic would need cross-epic dependencies, which SPEC-025 lists as out of
  scope. To split the child, the operator runs `/epic --redecompose <EPIC-ID>`
  on this same epic (non-completed children only); autopilot never starts that
  (SPEC-033 M5(g)).
- any other value (an engine contract break) → treat as `halt` (fail closed).

### B.4 Status → in_progress + handoff (M7, M8)

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
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
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
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

**Mid-epic ship hygiene (M16 / CDT-158):** when `release_bump` is null/absent,
`/release` Step 0 runs `epic-lib gap-callout` after assert succeeds (warn-only
incomplete-child + functional-gap notice; incomplete does **not** block). When
`release_bump` is set, C4 still 64 — do not mix the callout into that message.

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
mid-path successor) and `epic-lib ready-set` is non-empty: continue Mode B
in the **same run**. Order: **B.6** (if M13 applies) → **B.1** → **B.2** →
**B.3** (SPEC-033 M5e self-answer when `AUTOPILOT_ON=true`) → **B.4**.
**Continue (`AUTOPILOT_ON`):** MUST NOT require a new `/epic` invocation.
Do **not** end the epic after the first shipped child. Interactive Mode B
still uses B.3 `y/n` (`n` stops). Continue is the walker loop only after
the child `/kickoff` or `/orchestrate` lifecycle returns (M11 — no IC
inline, no inlined SPEC-009).

**Stops (unchanged — no new stop).** Walker stops only on: B.3 human `n` or
autopilot `halt`; empty ready-set; all children `completed` (then **B.7**
iff durable `release_bump` set); only `blocked`/`in_progress` remain; M13
`context-discipline: seed failed — <reason>`; user interrupt.

**B.7 MUST NOT run while ready-set is non-empty.** After each child, print
B.1 rollup (`show` / `waves` / `ready-set`) including remaining ready ids.
MUST NOT celebrate, run B.7, or claim epic Done / Orchestration complete
while any child is not `completed`.

**M13:** ≥2 children + discipline on → seed+validate still runs between
children (B.6); fail-closed. Continue the walker loop ≠ continue inline
with prior child transcripts (existing MUST NOT).

**N8:** `AUTOPILOT_ON` does not mark kickoff-mode children `completed`.
Continue waits for wrap-ticket / orchestrate lifecycle (A.6 default remains
`orchestrate`). B.5 completion is NEVER autopilot-answered (SPEC-033 N8).

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
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
EPIC_ID="<EPIC-ID>"
NEXT="<next ready CHILD-ID or omit --next for auto>"
# Prefer mechanical build-seed (records last_seed_path on success):
SEED_PATH=$(bash "$EPIC_LIB" build-seed "$EPIC_ID" --next "$NEXT") || {
  echo "context-discipline: seed failed — build-seed failed"
  # halt: do NOT set-status in_progress on next child; leave pending
  exit 1
}
bash "$EPIC_LIB" validate-seed "$SEED_PATH" || {
  echo "context-discipline: seed failed — validate-seed failed"
  exit 1
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

Runs **once** after the **last** child reaches `completed` (all children
`completed` — MUST NOT run while ready-set is non-empty), and **only** when
durable `release_bump` is non-null (epic was started with `--worktree --release
<bump>`). Without `--release`, there is **no** epic seal path — children ship
as today (per-child `/release` / merge unchanged).

Mechanical CLI (subprocess only):

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
EPIC_ID="<EPIC-ID>"

# Pure check (ready=false when no release_bump / incomplete / already sealed)
bash "$EPIC_LIB" seal-ready "$EPIC_ID"
# Optional plan only:
# bash "$EPIC_LIB" seal "$EPIC_ID" --dry-run
```

**When `seal-ready` reports `ready=true`:**

1. **Squash-stage** integration onto the default branch (the local branch behind `origin/HEAD`, else master/main; no commit). Run it from the main checkout with the default branch checked out. Seal never switches branches: it exits 1 when that checkout is dirty, or when HEAD is another branch or detached. Check out the default branch there first:
```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
EPIC_ID="<EPIC-ID>"
bash "$EPIC_LIB" seal "$EPIC_ID"
# stdout: staged=true, handoff="/release <bump>", env.EPIC_ALLOW_SEAL_RELEASE=1
```
2. **Exactly one** `/release <release_bump>` (bump from durable state — not a
   separate `--bump` flag). `/release` remains the ship-of-record (version
   pair + single fold-commit + tag/push). `assert-release-allowed` honors
   `EPIC_ALLOW_SEAL_RELEASE=1` only while the epic is seal-staged (`seal_stage`
   non-null: after `seal`, before `--complete`/`--abort`); a stray env var
   alone bypasses nothing. Export for the single invocation:
```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
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
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
EPIC_ID="<EPIC-ID>"
bash "$EPIC_LIB" seal "$EPIC_ID" --complete
```
4. **On `/release` or squash failure** — leave `sealed=false` (no partial
   tag/push from seal; master not half-shipped). Recover with **bare**
   `seal --abort` first — it resets the seal-owned squash stage (or is a
   no-op when main is already clean) and exits 0:
```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
EPIC_ID="<EPIC-ID>"
bash "$EPIC_LIB" seal "$EPIC_ID" --abort
```
   If bare `--abort` **refuses** (exit **1** — main holds edits outside the
   seal-owned stage, for example unstaged version-pair edits a failed
   `/release` Step 3 left behind), run `--abort` with `--force` — stash then reset —
   a named stash holds the edits, nothing is lost:
```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
PDH="${PDH:-<PDH>}"   # session root carried from the stanza fence above — re-run that fence first when not held
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
EPIC_ID="<EPIC-ID>"
# Post-stage / intentional wipe (stash then reset) — only after bare --abort refused.
bash "$EPIC_LIB" seal "$EPIC_ID" --abort --force
```

**Invariants:**
- Seal path runs **once** (`sealed=true` → further `seal` is `already_sealed` no-op).
- Master receives epic delivery **only** at seal (C4 forbids mid-epic land).
- Exactly one versioned release commit for the epic (`/release` contract).
- Bare `seal --abort` resets only the seal-owned stage (or no-ops on a clean
  tree) and MUST NOT wipe unrelated main WIP; `--abort` with `--force` is
  stash then reset (named stash; operator/orchestrator recovery only; never
  removes untracked files — CDT-170).
- `EPIC_SEAL_RELEASE_HOOK` (tests only; runs only with `EPIC_TEST_MODE=1`, else
  ignored with a stderr notice) may stand in for `/release`; production
  orchestrator always uses `/release` as SoT.

**When `release_bump` is null/absent:** `seal` / `seal-ready` skip (`reason=
no_release_bump`) — zero squash, zero `/release` from epic.

