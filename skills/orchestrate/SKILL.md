---
name: orchestrate
description: |
    Full lifecycle orchestrator — fetches issue context, creates worktree, spawns
    agents end-to-end, enforces tech-lead review loops, and optionally ships a PR.
    You stay as observer/navigator; agents do all the work.
    Usage: /orchestrate CDV-1 or /orchestrate
---

# Orchestrate

End-to-end issue orchestration. You (the main Claude) do NOT write code — you observe,
coordinate agents, track progress, and escalate decisions to the user. All implementation
happens in agent worktrees.

## Arguments

- `/orchestrate <ISSUE-ID>` — fetch from Linear or prompt for context
- `/orchestrate` — prompts for issue ID
- `[--autopilot[=<token>]]` — optional, any position: enable autopilot for this run
  (CDT-111-C4 / SPEC-033 / CDT-195). Bare `--autopilot` or `AUTOPILOT=1` env =
  enabled, bump `null` (PR-stop default at ship-choice);
  `--autopilot=<patch|minor|major>` = release ship intent (merge → end-state
  §5-release); `--autopilot=master` = **land-no-release** (merge → end-state §5b;
  token spelling only — land target is worktree baseline / origin default, not
  necessarily a branch named `master`; **MUST NOT** pass `master` to `/release`).
  Flag wins over env. See `skills/autopilot/parse-flags.sh` + Step 0 "Autopilot
  detection".
- `[--council-tier=<skip|light|full>]` — optional, any position: DRI-supplied
  override for every `requires_council: true` task-gate council run in this
  orchestration (CDT-126, SPEC-013 § Council tiering). Scoped like `--autopilot`
  itself — resolved once at Step 0, applies for the whole run. No env-var
  equivalent and never auto-selected; omitting it runs every task-gate council
  call at `full` (`commands/council.md` does not auto-grade any scope it
  resolves on its own — Task 3's F-A fix). See Step 0 "Council tier
  detection" and Step 9 "Council gate for `requires_council: true` tasks".
- `[--resume-ship[=<patch|minor|major|master>]]` — optional (CDT-135 / SPEC-033 /
  CDT-195): after a human overrides a BC7 ship-choice halt, run the **single
  confirmed ship sequence** (end-state land path + wrap) without re-running the
  full orchestration. Bare re-reads plan/card mode; explicit `=master|patch|minor|major`
  overrides. `=master` resumes land-no-release (token spelling; land target is
  worktree baseline). See Step 11 § Resume ship after BC7 override.

---

## Step 0: Resolve roots and load context

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
# Locate the dev-team plugin root (PDH). Optional CLAUDE_PLUGIN_ROOT (force path / FR #48230), else cwd dev/worktree, else marketplace clone (slug-free agents/pm.md), else installed cache (rank by /dev-team/<VER>/ segment, not full path; CDT-166). CDT-82: marketplace before same-version cache.
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
```

`$PDH` is the install-aware plugin root: helper scripts ship in the plugin
(not the user's repo), so every `skills/…` helper below is resolved through
`bash "$PDH/skills/plugin-dir.sh" file <relpath>` rather than `$MROOT/skills/…`.

Read in parallel:
- `$MROOT/AGENTS.md`
- Claude memory:
  ```bash
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
  if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
    HAS_DISTILLED=$(sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT COUNT(*) FROM memories WHERE agent='claude' AND tier > 0 AND archived=FALSE;")
    if [ "${HAS_DISTILLED:-0}" -gt 0 ]; then
      sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT content FROM memories WHERE agent='claude' AND tier=2 AND archived=FALSE ORDER BY type, updated_at DESC;"
      sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT content FROM memories WHERE agent='claude' AND tier=1 AND archived=FALSE ORDER BY type, updated_at DESC;"
    else
      sqlite3 -cmd ".timeout 5000" "$MEMDB" "SELECT content FROM memories WHERE agent='claude' AND tier=0 AND archived=FALSE ORDER BY type, created_at DESC;"
    fi
  else
    cat "$MROOT/.claude/memory/claude/memory.md" 2>/dev/null
  fi
  ```
- Tech Lead and PM load their own memory via their agent definitions when spawned
  in Step 4 — the orchestrator does not load it here.

If ISSUE-ID missing, ask:
> "Issue ID (e.g. CDV-1):"

### Autopilot detection (CDT-111-C4)

Resolve autopilot enablement once, at run start — every gated checkpoint below
(Step 2 scope-confirm, Step 6 plan-approve, Step 11 ship-choice) reuses these values
by reference. `ITER` starts at `0` and increments once per orchestration stint.

```bash
# Locate the dev-team plugin root (PDH). Optional CLAUDE_PLUGIN_ROOT (force path / FR #48230), else cwd dev/worktree, else marketplace clone (slug-free agents/pm.md), else installed cache (rank by /dev-team/<VER>/ segment, not full path; CDT-166). CDT-82: marketplace before same-version cache.
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
AP=$(bash "$PDH/skills/plugin-dir.sh" file skills/autopilot/parse-flags.sh)
AP_JSON=$(bash "$AP" "$@") || { echo "$AP_JSON" >&2; exit 64; }   # 64 = malformed --autopilot=<bump>
AUTOPILOT_ON=$(jq -r .enabled <<<"$AP_JSON")
AUTOPILOT_BUMP=$(jq -r '.bump // "null"' <<<"$AP_JSON")
AP_SOURCE=$(jq -r .source <<<"$AP_JSON")            # flag | env | none
# CDT-126: DRI --council-tier=<skip|light|full> override, resolved once for
# the whole run from the same parse-flags.sh call — no precedence interaction
# with --autopilot, no resume-state seeding (unlike AUTOPILOT_ON/BUMP, this
# is not persisted; a resumed run without the flag re-resolves to null).
COUNCIL_TIER_OVERRIDE=$(jq -r '.council_tier // "null"' <<<"$AP_JSON")

# Resume detection (CDT-111-C8): only when THIS invocation gave neither
# --autopilot nor AUTOPILOT= (flag/env always win over recorded state).
RESUMING=false
if [ "$AP_SOURCE" = none ]; then
  RS=$(bash "$PDH/skills/plugin-dir.sh" file skills/autopilot/resume-state.sh)
  RS_JSON=$(bash "$RS" "<ISSUE-ID>")
  if [ "$(jq -r .found <<<"$RS_JSON")" = true ]; then
    REC_ON=$(jq -r '.autopilot_on // "null"' <<<"$RS_JSON")
    if [ "$REC_ON" != null ]; then
      AUTOPILOT_ON=$REC_ON
      AUTOPILOT_BUMP=$(jq -r '.autopilot_bump // "null"' <<<"$RS_JSON")
      RESUMING=true
      PLAN_PATH=$(jq -r .plan <<<"$RS_JSON")
      if [ "$AUTOPILOT_ON" = true ]; then
        echo "resuming <ISSUE-ID> in recorded autopilot mode (bump=$AUTOPILOT_BUMP) — plan: $PLAN_PATH"
      else
        echo "resuming <ISSUE-ID> — recorded state: autopilot off — plan: $PLAN_PATH"
      fi
    fi
  fi
fi

# RUN_START_EPOCH: synthetic on resume so BC6's wall-clock cap measures active
# execution time only — pause duration must never count (SPEC-033 M9a).
NOW=$(date +%s)
if [ "$RESUMING" = true ]; then
  ACCUM=$(bash "$RS" --accumulated "<ISSUE-ID>")   # $RS resolved above, same script
  if [ "$ACCUM" -gt 0 ]; then
    RUN_START_EPOCH=$(( NOW - ACCUM ))
  else
    RUN_START_EPOCH=$NOW
  fi
else
  RUN_START_EPOCH=$NOW
fi
RUN_ID="orchestrate-<ISSUE-ID>-$RUN_START_EPOCH"    # S3-derivable per C3 §2
ITER=0                                              # ++ once per stint
```

On a fresh `/orchestrate <ISSUE-ID>`, an existing `.claude/plans/*-<ISSUE-ID>-*.md`
seeds autopilot state only when no `--autopilot`/`AUTOPILOT=1` was given on this
invocation (flag/env win over recorded state — `parse-flags.sh`'s own precedence,
`source=="none"` is the signal). Pause time is excluded from BC6 via the synthetic
epoch (SPEC-033 M9a, CDT-111-C8).

Every later reference to `AUTOPILOT_ON` / `AUTOPILOT_BUMP` / `RUN_ID` /
`RUN_START_EPOCH` / `ITER` / `COUNCIL_TIER_OVERRIDE` below means these values,
carried forward from this step.

---

## Step 1: Fetch issue context

Resolve **ticket source** and a `closes:` list (persisted on the plan in Step 6).
Order:

1. **Linear** — if Linear MCP is available (e.g. `linear_getIssue`) and the ID
   resolves: extract title, description, ACs, priority, assignee, status, labels.
   Set `source=linear`. Seed `closes:` with `linear:<ISSUE-ID>`.
2. **Backlog** — else if `.claude/backlog/<ISSUE-ID>.md` exists, or
   `.claude/backlog.md` / item titles match the ID or slug: load Problem/Goal/Notes
   as issue context. Set `source=backlog`. Seed `closes:` with
   `backlog/<slug>.md` (and any additional slugs the user names).
3. **Freeform** — else ask the user to paste title, description, ACs. Set
   `source=freeform`, `closes: []`, and warn: no tracker will be closed at ship.

If Linear **and** a matching backlog item both exist, dual-write both into
`closes:` (close local index at ship; Linear ticket status per **Linear lifecycle**
below — Done only when work is on master / wrap).

Print source + closes in the Step 2 summary. Store issue context for all
subsequent agent prompts.

---

## Step 2: Evaluate issue and confirm scope with user

Present the issue summary:

```
Issue: <ISSUE-ID> — <title>
Priority: <priority>
Current status: <status>

Description:
<description summary>

Acceptance Criteria:
1. <AC>
2. <AC>
...

My assessment:
- Complexity: <simple | moderate | complex>
- Estimated agents needed: <list>
- Likely affected areas: <educated guess from issue text + project memory>

Proceed with this scope? Any adjustments?
```

**Autopilot:** if `AUTOPILOT_ON` (Step 0), do NOT wait for the user here. Build the
C3 §2 envelope `{ workflow:"orchestrate", ticket_id:<ISSUE-ID>, gate:"scope-confirm",
run_id:RUN_ID, iteration:ITER, run_start_epoch:RUN_START_EPOCH,
autopilot_bump:AUTOPILOT_BUMP, <issue-text sufficiency evidence, destructive-op flags,
and the complexity signals from the assessment above> }` and call
`skills/autopilot/self-answer.md`'s procedure for `{decision, blocking_condition,
confidence, rationale}` (exactly one `decided_by:"auto"` card is appended). Act on
`decision`:
- `proceed` → continue to Step 3 exactly as the user's "yes" would.
- `reroute-epic` → print the one-line message below, hand off to `/epic` decompose, and
  return control.
  The `/epic` decompose invocation MUST carry the autopilot state forward — pass
  `--autopilot[=<bump>]` (or `AUTOPILOT=1`); `/epic` Step 0.5 resolves its OWN autopilot state
  independently and does NOT inherit the caller's (SPEC-033 M11a).
- `halt` → emit `task_blocked` (detail = the one-line message below) via **Passive
  notifications → Tier B** (fail-open; § below), then print the one-line message below and
  return control:
```
scope-confirm <decision>: <rationale> — card: <card-file-path>
```
Otherwise (autopilot off), the user-confirmation gate below applies unchanged.

Wait for user confirmation before proceeding. This is the first escalation gate.

---

## Step 3: Create branch and worktree

A git worktree is an additional working tree linked to the same repository — it lets
agents work on the issue branch in isolation without disturbing the main checkout.

**CDT-141-C3 / epic shared integration:** when this ticket is an epic child of a
`--worktree` epic (or `EPIC_INTEGRATION_PATH` is set to an existing integration
tree), do **not** open a per-child worktree off master. Route through
`epic-lib ensure-ticket-worktree` — it prints the shared path and skips
`worktree-lib ensure <child-slug>`. Default (no epic shared tree): same as today.

```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
SLUG="<ISSUE-ID>"   # bare issue ID (e.g. "CDV-42" or "CDT-141-C3")
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
# Prefer ensure-ticket-worktree: shared integration when epic child + worktree_enabled,
# else worktree-lib ensure <SLUG>. Honors EPIC_INTEGRATION_PATH from epic B.4 handoff.
WT_PATH=$(bash "$EPIC_LIB" ensure-ticket-worktree "$SLUG") || {
  EXIT=$?
  if [ "$EXIT" -eq 2 ]; then
    echo "Worktree setup aborted by user." >&2
  elif [ "$EXIT" -eq 64 ]; then
    echo "ensure-ticket-worktree / worktree-lib usage error, check slug" >&2
  fi
  exit "$EXIT"
}
# Record whether this run is on a shared epic tree (for cleanup + re-derive).
CHILD_WT=$(bash "$EPIC_LIB" resolve-child-worktree "$SLUG")
USE_SHARED=$(jq -r '.use_shared // false' <<<"$CHILD_WT")
INT_SLUG=$(jq -r '.integration_slug // empty' <<<"$CHILD_WT")
```

When `USE_SHARED=true`: `$WT_PATH` is the epic integration path
(`.worktrees/epic-<EPIC-ID>`), branch `feat/epic-<EPIC-ID>`. **Zero** new
per-child trees. Child commits land on the integration branch.

When `USE_SHARED=false`: same as pre-C3 — `worktree-lib` creates `feat/<SLUG>`
and prints `.worktrees/<SLUG>`.

- **Exit 1** (unexpected error): git or filesystem failure; stderr will have details; halt.
- **Exit 2** (user aborted): halt cleanly.
- **Exit 64** (usage error): surface usage error to stderr.

Use `$WT_PATH` everywhere downstream. On later fences, re-derive:

```bash
# Shared epic child: resolve again (do NOT hardcode .worktrees/<ISSUE-ID>)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
WT_PATH=$(bash "$EPIC_LIB" ensure-ticket-worktree "<ISSUE-ID>")
# or, if USE_SHARED was true: WT_PATH=$(jq -r .integration_path <<<"$(bash "$EPIC_LIB" resolve-child-worktree "<ISSUE-ID>")")
```

If Linear is available, update issue status to "In Progress".

---

## Step 4: Parallel PM + Tech Lead kickoff

Use `/kickoff` logic but adapted — spawn both agents in the worktree:

### PM agent (spawn now):
```
You are @pm. Review issue <ISSUE-ID>:

Output mode: terse

<ISSUE CONTEXT>

Your job:
1. Confirm or rewrite each acceptance criterion — make them unambiguous and testable
2. Flag any scope questions that must be resolved before implementation
3. Add any missing ACs the issue implies but doesn't state
4. Output: revised AC list + open questions (if any)

Do NOT plan implementation. Scope only.
Return your output as this agent's final message — do NOT SendMessage to the
orchestrator; there is no addressable parent.
```

### Tech Lead agent (spawn now, in parallel):
```
You are @tech-lead. Orient on issue <ISSUE-ID> while @pm reviews scope.

Output mode: terse

Issue summary: <title + first 2 sentences>

Your job:
1. Read your cortex.md for architecture context
2. Identify which files/packages this will likely touch
3. Identify existing specs that constrain the design
4. Note technical risks or unknowns

Do NOT produce a plan yet — wait for confirmed ACs.
Output: affected files, relevant specs, risks.
Return your output as this agent's final message — do NOT SendMessage to the
orchestrator; there is no addressable parent.
```

Collect both outputs.

---

## Step 5: Resolve open questions (escalate to user)

If PM found open questions:

```
@pm found N open questions:

1. <question>
2. <question>

Please answer so we can lock scope.
```

Wait for user answers. Feed them back to PM for final AC list.

If no open questions, proceed.

---

## Step 6: Tech Lead designs approach

Feed confirmed ACs + Tech Lead's orientation to Tech Lead:

```
@tech-lead — ACs are confirmed:

Output mode: terse

<final AC list>

Your earlier assessment: <affected files, specs, risks>

Produce:
1. Spec (create/update in specs/core/ with MUST/SHOULD/MUST NOT)
2. Implementation plan with task graph (dependencies, parallelism)
3. For each task: recommended agent (ic4/ic5/qa) and why.
   Escalation heuristic: assign ic5 (not ic4) when a task touches >10 files,
   modifies >15 callsites, or involves wide-scope structural deletion/renaming.
   ic4 excels at focused tasks; wide-scope structural work should go to ic5 or be split further.
4. Save plan to .claude/plans/<YYYY-MM-DD>-<ISSUE-ID>-<slug>.md
5. Include a Tracking section on the plan (from Step 1; edit if multi-item):

## Tracking
- source: linear | backlog | freeform
- ticket_id: <ISSUE-ID>
- closes:
  - backlog/<slug>.md
  - linear:<ID>
- autopilot_on: <true|false>
- autopilot_bump: <patch|minor|major|master|null>

Many-to-one is allowed (one ticket closes multiple backlog items). Empty closes
only for freeform. `autopilot_on`/`autopilot_bump` MUST always be written, on
autopilot and non-autopilot runs alike — substitute the Step-0 resolved
`AUTOPILOT_ON`/`AUTOPILOT_BUMP` values (recording `autopilot_on: false`
explicitly on a non-autopilot run is a symmetric "remember it was NOT
autopilot" record, not just a true-case field). `autopilot_bump` is `null`
when autopilot is off, or when on in bare/pr-mode; may be `master` (land-no-release
sentinel, CDT-195) or a release token. pr-vs-merge is always derived from bump
(null→pr, else→merge — includes `master`) — do NOT record a separate field
(SPEC-033 M9a / CDT-111-C8 AC1). This is `resume-state.sh`'s Step-0 resume
detection read surface (CDT-111-C8).
```

Present the plan summary to user:

```
Tech Lead's plan for <ISSUE-ID>:

Tasks:
1. <task> → ic4 (extends existing pattern)
2. <task> → ic5 (new module, needs design)
3. <task> → qa (acceptance tests from spec)

Dependencies: Task 3 blocked by Task 1+2

Approve this plan? Want changes?
```

**Autopilot:** if `AUTOPILOT_ON` (Step 0), do NOT wait for the user here — this is the
autopilot-only `plan-approve` branch; when autopilot is off nothing changes and the
existing approval gate below fires as the sole gate. Build the C3 §2 envelope
`{ workflow:"orchestrate", ticket_id:<ISSUE-ID>, gate:"plan-approve", run_id:RUN_ID,
iteration:ITER, run_start_epoch:RUN_START_EPOCH, autopilot_bump:AUTOPILOT_BUMP,
<per-task {file paths present?, verification step present?}, projected LOC / per-file
size, task-graph shape, destructive-op flags> }` and call
`skills/autopilot/self-answer.md`'s procedure. Act on `decision`:
- `approve` → continue to Step 7 exactly as the user's approval would.
- `reroute-epic` → print the one-line message below, hand off to `/epic` decompose, and
  return control.
  The `/epic` decompose invocation MUST carry the autopilot state forward — pass
  `--autopilot[=<bump>]` (or `AUTOPILOT=1`); `/epic` Step 0.5 resolves its OWN autopilot state
  independently and does NOT inherit the caller's (SPEC-033 M11a).
- `halt` → emit `task_blocked` (detail = the one-line message below) via **Passive
  notifications → Tier B** (fail-open; § below), then print the one-line message below and
  return control:
```
plan-approve <decision>: <rationale> — card: <card-file-path>
```
Otherwise (autopilot off), the user-approval gate below applies unchanged.

Wait for user approval. This is the second escalation gate.

---

## Step 7: Create task graph

Before creating any tasks, extract the dependency graph from the approved Tech Lead plan and reject cycles up front:
1. For each task in the plan, note its ID (Task 1, Task 2, …) and its "Depends on:" list.
2. Map each plan "Task N" reference to its compound key `<ISSUE-ID>-N` (the same key Step 7 uses for `task-store.sh create`), then build a JSON array: `[{"task_id": "<ISSUE-ID>-N", "depends_on": ["<ISSUE-ID>-M", ...]}, ...]`. A task with no deps gets `"depends_on": []`.
3. Write the dependency JSON to `$DAG_FILE` and run the cycle pre-gate BEFORE any TaskCreate:
   ```bash
   DAG_FILE="${TMPDIR:-/tmp}/orchestrate-dag-$$.json"
   CYCLE_ERR="${TMPDIR:-/tmp}/orchestrate-cycle-err-$$.txt"
   # (caller already wrote the dependency JSON into $DAG_FILE)
   # Re-resolve PDH (each bash fence is a fresh shell)
   # lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
   PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
   DAG_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/orchestrate/dag-lib.sh)
   bash "$DAG_LIB" check-cycle "$DAG_FILE" 2>"$CYCLE_ERR"
   rc=$?
   if [ "$rc" -eq 1 ]; then
     CYCLE_MSG=$(cat "$CYCLE_ERR" 2>/dev/null || true)
     rm -f "$DAG_FILE" "$CYCLE_ERR"
     echo "Orchestrate error: circular dependency detected: $CYCLE_MSG. Revise the task graph."
     # halt — do NOT call TaskCreate for any task
   elif [ "$rc" -ne 0 ]; then
     DIAG=$(cat "$CYCLE_ERR" 2>/dev/null || true)
     rm -f "$DAG_FILE" "$CYCLE_ERR"
     echo "Orchestrate error: cycle gate could not run (rc=$rc): $DIAG"
     # halt — do NOT call TaskCreate for any task
   fi
   rm -f "$DAG_FILE" "$CYCLE_ERR"
   ```
   Do NOT call TaskCreate (or `task-store.sh create`) for any task if a cycle is detected or the cycle gate could not run.

For each task in the approved plan, finalize tagging then call TaskCreate.

**`Task-class:` line (SPEC-026 M3).** Record class as a prose line (mirroring
`Recommended agent:`) — NOT a `task-store.sh` schema field.
Fixed taxonomy: `impl-extend | impl-novel | refactor | test | docs | infra | discovery`.
Missing line ⇒ `task_class: null` at emit; null-class records are still written but
excluded from advisory aggregation (M7).

#### Step 7 advisory (SPEC-026 M5/M6/M7) — before Recommended agent is finalized

After choosing the **static** Recommended agent (SPEC-009 rules) and Task-class,
consult the outcome ledger. Fail-open: any failure ⇒ silence, keep static (M9).
MUST NOT auto-flip routing (M6).

```bash
# Re-resolve PDH (each bash fence is a fresh shell)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
RATES=$(bash "$PDH/skills/plugin-dir.sh" file skills/metrics/outcome-rates.sh)
STATIC_AGENT="<ic4|ic5|… from static rule>"
TASK_CLASS="<from Task-class line; empty if missing>"
ADVISORY=""
if [ -n "$TASK_CLASS" ]; then
  ADVISORY=$(bash "$RATES" "$STATIC_AGENT" "$TASK_CLASS" 2>/dev/null || true)
fi
[ -n "$ADVISORY" ] && printf '%s\n' "$ADVISORY"
```

- Empty `$ADVISORY` (cold start / thin data / boundary / no jq) → no advisory text;
  set `Recommended agent: $STATIC_AGENT`.
- Non-empty → print to user. **Interactive only:** wait for explicit accept/decline.
  On **explicit accept**, set `Recommended agent:` to the suggested alt (the
  `consider <alt>` agent — already M8-legal). Decline / timeout / unattended /
  no response → keep `$STATIC_AGENT`. Unattended runs never wait.

Then call TaskCreate with the finalized lines:

```
TaskCreate:
  subject: "<ISSUE-ID> Task N — <title>"
  description: |
    <description>
    Task-class: <impl-extend|impl-novel|refactor|test|docs|infra|discovery>
    Recommended agent: <ic4|ic5|qa>
    Depends on: [Task IDs] or "none"
    requires_council: <true|false>   # omit = false
```

After each TaskCreate succeeds and the task id is known, the orchestrator MUST call:

```bash
# Build colon-separated depends_on from this task's plan "Depends on:" list.
# Map each "Task N" reference to the SAME compound key used below: "<ISSUE-ID>-N".
# e.g. if Task 3 depends on Task 1 and Task 2 and <ISSUE-ID> is CDV-QF-FILTER:
#   DEPS="CDV-QF-FILTER-1:CDV-QF-FILTER-2"
# If no deps:
#   DEPS=""
DEPS=$(echo "<compound dep keys for this task, space/comma-separated>" | tr ', ' ':' | tr -s ':' | sed 's/^://;s/:$//')
# Re-resolve PDH (each bash fence is a fresh shell)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
TASK_STORE=$(bash "$PDH/skills/plugin-dir.sh" file skills/orchestrate/task-store.sh)
bash "$TASK_STORE" create <ISSUE-ID>-<task_id> "<subject>" <requires_council> "$DEPS"
```

where `<ISSUE-ID>` is the current issue ID (e.g. `CDV-QF-FILTER`) and `<task_id>` is the integer returned by TaskCreate (e.g. `1`). The compound key (e.g. `CDV-QF-FILTER-1`) prevents task-store collisions when a new Claude process reuses the same integer IDs across runs. The 4th `[depends_on]` argument MUST use the SAME compound `<ISSUE-ID>-N` form so `dag-lib.sh ready-set`'s set-subtraction matches completed task IDs — a bare `Task N` or `N` would never appear in the done-set and would silently re-mark every dependent as ready, defeating the DAG. A task with no deps passes `""` (empty depends_on). This writes `$MROOT/.claude/tasks/<ISSUE-ID>-<task_id>.json` — the source of truth the SPEC-002 TaskCompleted hook reads to determine whether the council quality gate applies (SPEC-009, "council gate applies when `requires_council: true`" MUST + the task-store source-of-truth MUSTs). If `task-store.sh` exits non-zero, surface the error to the user immediately — do NOT silently continue.

Update the plan file with task IDs.

If Linear is available, add a comment with the task breakdown.

---

## Step 8: Execute — spawn agents and monitor

**CRITICAL: You do NOT write code. You orchestrate.** This rule survives
session compaction and `claude --resume`. If you find yourself reaching
for `Edit` or `Write` on a project file after a long session — stop.
That work belongs to a spawned IC agent. Re-enter the orchestrator
posture, identify the right task and agent, and spawn.

**Post-compaction discipline.** When the harness summarises and resumes
the session (after `/clear`, after auto-compaction, or after a fresh
`claude --resume`), Claude Code resets its per-tool read-tracker — but
the conversation summary may still convince you that you have already
read a given file. You have not. Before any `Edit` on a file you do not
remember reading *in this concrete turn*, run `Read` first. The
"File has not been read yet" tool error is the signal that compaction
just happened; treat it as a directive to re-Read every file you intend
to touch this turn, not a one-off retry.

For each task that has no blockers, spawn the Claude IC via the fence below.

```
Spawn @<agent> for Task <ID>:
"<task description>

Output mode: terse

Work in worktree: <path>
Spec: <spec path>
Plan: <plan path>

Architecture context (from Tech Lead's orientation):
- Affected components: <list all backends/services/packages that need changes for this task>
- If the spec or plan mentions multiple backends, services, or platforms (e.g. Fyne, Gio,
  Web; or API, Worker, CLI), enumerate EVERY one that this task must touch. Do not assume
  the agent will discover them on its own.

When done, mark your task completed via TaskUpdate. Return your final report as
this agent invocation's output — do NOT SendMessage to the orchestrator. There
is no addressable parent named 'main' or 'orchestrator'; symbolic addressing
will fail. The orchestrator reads your output directly from this spawn return."
```

**When this task's `requires_council: true`** (Step 7) **and `COUNCIL_TIER_OVERRIDE` (Step 0) is not `skip`**, append to the spawn prompt above, before the "When done" line. The council run MUST use **claim scope, not `--diff`** — **by product policy** (claim / fabrication audit), not because `finding[]` is unusable at the gate. `--diff` resolves `preset: diff-mode` (`finding[]`-shape: writes `max_finding_confidence` with `max_verdict_confidence: null` — SPEC-013 Output Shapes; `index.json` row shape). The SPEC-002 TaskCompleted hook is **dual-shape**: it clears `requires_council: true` against a non-null `max_verdict_confidence` **or** null-verdict + non-null `max_finding_confidence` at or above `council.taskgate.min_confidence`. Manual `/council --diff --task-id X` **can** pass if finding conf ≥ threshold; orchestrated task-gate still **MUST NOT** use `--diff` (claim-audit policy). Claim scope (`generic` preset) is `verdict[]`-shape and carries confidence from the Judge's verdict — the task-gate command — and tiering still applies there exactly as elsewhere (`--tier light` → `paranoid-ic` + `jaded-senior` only, Phase 3/4 skipped, Judge gets claims + evidence bundles only — 3 spawns vs. `full`'s 5-9, the same ~2-3× saving as the rest of this ticket).

Compose `<CLAIM>` as a single testable sentence asserting the task is correctly, completely implemented — drawn from the task's own subject/description (Step 7), e.g. `"<ISSUE-ID> Task <N> ('<subject>') is fully implemented per its task description: <one-line summary>."` Investigators have full tool access and verify the claim against the actual repo state; the claim only needs to be a concrete, falsifiable assertion, not a proof.

With `<COMMAND>` resolved by the orchestrator at spawn time (not left as a placeholder for the agent):

- `COUNCIL_TIER_OVERRIDE` is `light` or `full` → `<COMMAND>` =
  `/council "<CLAIM>" --task-id <task_id> --council-tier=<light|full>`
- `COUNCIL_TIER_OVERRIDE` is the literal string `"null"` (no `--council-tier` on this run —
  Step 0's `jq -r '.council_tier // "null"'` renders parse-flags.sh's JSON `null` as the
  4-character string `"null"`, not empty/unset; same idiom as `AUTOPILOT_BUMP` two lines
  above it in Step 0) → `<COMMAND>` = `/council "<CLAIM>" --task-id <task_id>`
  — this runs at `full`: `commands/council.md` Step 1.5.1 does not auto-grade any scope it
  resolves on its own (the diff-scope auto-grading trigger was removed entirely — Task 3's
  F-A fix; §§ 1.5.2–1.5.4's grading procedure now runs only for a caller that grades its own
  diff and supplies the result externally, e.g. `ship-gate-council.md`'s M14(e) pass). Building
  a second, task-gate-side grading path here would duplicate that same shared procedure — not
  done in this fix; the task-gate site simply has no external-tier supplier of its own beyond
  the DRI's `--council-tier` flag.

```
Before reporting done, run:
  <COMMAND>
Your task will not be marked complete without a qualifying council verdict.
```

When `COUNCIL_TIER_OVERRIDE == skip`, do NOT append this instruction and do NOT
export `CLAUDE_TASK_ID` for a council purpose — Step 9's council-gate block
handles `skip` entirely on the orchestrator side, without ever invoking
`/council` for this task.

Whenever the orchestrator invokes `/council` as part of a task's orchestration steps (e.g., a task with `requires_council: true` that requires a council verdict before completion), the orchestrator MUST export `CLAUDE_TASK_ID=<task_id>` in the subprocess environment of that `/council` invocation. This is the ambient task-id transport SPEC-013 Phase 6 uses for verdict-to-task binding via the fallback chain `--task-id` flag → `CLAUDE_TASK_ID` env → unbound (SPEC-009, the `CLAUDE_TASK_ID` export MUST; SPEC-013 Task-ID Plumbing). The hook path (SPEC-002 TaskCompleted) resolves its task id from stdin JSON and does NOT share this fallback chain — the two paths are independent.

The orchestrator MUST export `CLAUDE_TASK_ID=<task_id>` when spawning an IC agent for a task with `requires_council: true` and `COUNCIL_TIER_OVERRIDE != skip` (per the spawn-prompt addendum above) — this is the case where the agent itself invokes `/council` mid-task as a self-review, and the export is how that run binds to the right index row.

### PM kickoff is mandatory for every ticket

When orchestrating an umbrella ticket with child issues, each child ticket MUST get
its own PM kickoff (Step 4 AC review). Do NOT skip PM for "obvious" tickets or
tickets that came from a TL plan — PM's job is to validate ACs independently.
PM regularly catches false premises in a child ticket's spec that would otherwise
break the implementation, so skipping PM for "obvious" child tickets is a defect.

### Monitoring loop

After spawning, enter a monitoring cycle:

1. Check TaskList periodically for progress
2. When an agent completes a task, check if blocked tasks are now unblocked → spawn next agents
3. Surface blockers or errors to user immediately

**TaskList ↔ Agent-spawn reconciliation.** The Agent tool reports
`status: "async_launched"` when a spawn is fired-and-forgotten — that
status lives on the *Agent tool result*, not on the TaskList. A spawned
agent's `TaskUpdate(completed)` runs in its own sandbox session and
does NOT propagate back to the orchestrator's TaskList. So TaskList
will stay at `in_progress` forever unless the orchestrator itself
closes the loop.

**The orchestrator MUST**, on every Agent-completion notification:
1. Identify the `task_id` the spawned agent was working (you set this
   when you called `TaskCreate`; record `task_id ↔ agentId` at spawn
   time so you can map back).
2. Read the spawn result for outcome (success/failure/blocker).
3. Call `TaskUpdate(task_id, completed)` (or `blocked` with reason).
4. Then re-run `dag-lib.sh ready-set` to fan out unblocked work.

Without step 3, `/status standup` will show stale `in_progress` counters and
the TaskCompleted hook (council gate) never fires for that task. The
file-based task store at `.claude/tasks/<task_id>.json` is the source
of truth that survives compaction; TaskList is the in-session view of
it.

### DAG-aware task fan-out

At orchestration start and after every task status transition to `completed`,
compute the unblocked set via:

  ```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
  DAG_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/orchestrate/dag-lib.sh)
  READY=$(bash "$DAG_LIB" ready-set)
  ```

Spawn an agent for every task_id in `$READY` simultaneously — do not process
them one at a time. This is the parallel fan-out guaranteed by SPEC-017.

A task is only eligible for spawning when:
1. dag-lib.sh ready-set includes its task_id
2. No agent is currently running for that task_id (check in-progress task store status)

After each agent completes (status → completed), immediately re-run ready-set
and spawn any newly-unblocked tasks.

### Escalation triggers (interrupt user):

- **Agent stuck after 2 genuine attempts** — present what was tried, ask for guidance.
  Before re-routing: run **Stint-end outcome emit** with `STINT_OUTCOME=escalated`
  for the agent whose stint is ending (counters as of hand-off).

**Autopilot — agent stuck after 2 attempts:** if `AUTOPILOT_ON` (Step 0), do NOT wait for the
user here. (Off-triad checkpoint; canonical gate = `plan-approve` — SPEC-033 M8 mapping; no new
gate enum value.) The Stint-end outcome emit above still fires unchanged first. Build the C3 §2
envelope `{ workflow:"orchestrate", ticket_id:<ISSUE-ID>, gate:"plan-approve", run_id:RUN_ID,
iteration:ITER, run_start_epoch:RUN_START_EPOCH, autopilot_bump:AUTOPILOT_BUMP, <trigger signal:
"agent stuck after 2 genuine attempts; what was tried: <summary>" — an unresolved
product/architecture decision autopilot cannot self-answer (BC1)> }` and call
`skills/autopilot/self-answer.md`'s procedure for `{decision, blocking_condition, confidence,
rationale}` (exactly one `decided_by:"auto"` card is appended; expected `blocking_condition = 1`).
Act on `decision`:
- `halt` → emit `task_blocked` (detail = the one-line message below) via **Passive
  notifications → Tier B** (fail-open; § below), then print the one-line message below and
  return control:
```
plan-approve <decision>: <rationale> — card: <card-file-path>
```
Otherwise (autopilot off), the escalation above applies unchanged.

- **Scope creep detected** — agent discovers work not in the plan; ask user whether to expand scope or defer to backlog

**Autopilot — scope creep detected:** if `AUTOPILOT_ON` (Step 0), do NOT wait for the user here.
(Off-triad checkpoint; canonical gate = `plan-approve` — SPEC-033 M8 mapping; no new gate enum
value.) Build the C3 §2 envelope `{ workflow:"orchestrate", ticket_id:<ISSUE-ID>,
gate:"plan-approve", run_id:RUN_ID, iteration:ITER, run_start_epoch:RUN_START_EPOCH,
autopilot_bump:AUTOPILOT_BUMP, <scope-creep signal: the out-of-plan work the agent discovered,
evaluated against the SPEC-033 M10 complexity-overflow criteria> }` and call
`skills/autopilot/self-answer.md`'s procedure (exactly one `decided_by:"auto"` card is appended).
Act on `decision`:
- `reroute-epic` (BC5 — meets M10 overflow) → print the one-line message below; hand this ticket's
  **remaining + newly-discovered scope** to `/epic` decompose per SPEC-033 M11 / M11a(b), and
  return control. **Already-completed/shipped task state is NOT rolled back** (M11a(b)); completed
  commits stay committed and become inputs to the decomposed epic. The `/epic` decompose invocation
  MUST carry the autopilot state forward — pass `--autopilot[=<bump>]` (or `AUTOPILOT=1`) so `/epic`
  Step 0.5 re-enables autopilot; `/epic` resolves its OWN autopilot state independently and does NOT
  inherit the caller's (SPEC-033 M11a(a)).
- `halt` (BC1 — scope-creep that is NOT an overflow) → emit `task_blocked` (detail = the
  one-line message below) via **Passive notifications → Tier B** (fail-open; § below), then
  print the one-line message below and return control:
```
plan-approve <decision>: <rationale> — card: <card-file-path>
```
Otherwise (autopilot off), the escalation above applies unchanged.

- **Ambiguous requirement** — agent can't resolve from spec/ACs alone

**Autopilot — ambiguous requirement:** if `AUTOPILOT_ON` (Step 0), do NOT wait for the user here.
(Off-triad checkpoint; canonical gate = `plan-approve` — SPEC-033 M8 mapping; no new gate enum
value.) Build the C3 §2 envelope `{ workflow:"orchestrate", ticket_id:<ISSUE-ID>,
gate:"plan-approve", run_id:RUN_ID, iteration:ITER, run_start_epoch:RUN_START_EPOCH,
autopilot_bump:AUTOPILOT_BUMP, <trigger signal: "requirement unresolvable from spec/ACs alone" —
an unresolved product/architecture decision autopilot cannot self-answer (BC1)> }` and call
`skills/autopilot/self-answer.md`'s procedure for `{decision, blocking_condition, confidence,
rationale}` (exactly one `decided_by:"auto"` card is appended; expected `blocking_condition = 1`).
Act on `decision`:
- `halt` → emit `task_blocked` (detail = the one-line message below) via **Passive
  notifications → Tier B** (fail-open; § below), then print the one-line message below and
  return control:
```
plan-approve <decision>: <rationale> — card: <card-file-path>
```
Otherwise (autopilot off), the escalation above applies unchanged.

- **Breaking change discovered** — schema migration, API contract change, dependency bump

**Autopilot — breaking change discovered:** if `AUTOPILOT_ON` (Step 0), do NOT wait for the user
here. (Off-triad checkpoint; canonical gate = `plan-approve` — SPEC-033 M8 mapping; no new gate
enum value.) Build the C3 §2 envelope `{ workflow:"orchestrate", ticket_id:<ISSUE-ID>,
gate:"plan-approve", run_id:RUN_ID, iteration:ITER, run_start_epoch:RUN_START_EPOCH,
autopilot_bump:AUTOPILOT_BUMP, <trigger signal: "breaking change discovered (schema migration /
API contract / dep bump) — **discovery**, a required human decision, not a destructive action
being taken now (BC1, not BC3)"> }` and call `skills/autopilot/self-answer.md`'s procedure for
`{decision, blocking_condition, confidence, rationale}` (exactly one `decided_by:"auto"` card is
appended; expected `blocking_condition = 1`). Act on `decision`:
- `halt` → emit `task_blocked` (detail = the one-line message below) via **Passive
  notifications → Tier B** (fail-open; § below), then print the one-line message below and
  return control:
```
plan-approve <decision>: <rationale> — card: <card-file-path>
```
Otherwise (autopilot off), the escalation above applies unchanged.

- **Agent disagreement** — IC and Tech Lead can't align after review rounds (see Step 9)

### DO NOT escalate:
- Test failures (agent should fix)
- Lint/format issues (agent should fix)
- Routine implementation decisions within the spec
- File organization within established patterns

### CI-watch fixer agent convention

The canonical CI-watch fixer-spawn block is `skills/ci-watch/SKILL.md` (the
`outcome == "fail"` branch). Follow it verbatim — it owns the full bookkeeping:
`task-store.sh create <TICKET>-ci-fixer` before the spawn, `sidecar.sh inc
<TICKET> retry_count`, and `task-store.sh update-status <TICKET>-ci-fixer
completed` after. Do NOT restate a partial copy here; defer to that block so
the bookkeeping stays single-sourced.

The one runtime instruction the spawned fixer needs IN its own prompt (it runs
in a separate session that cannot read this file) is the trailing guard clear.
Substitute `<PLUGIN>` with the resolved plugin root (`plugin-dir.sh`), not
`<MROOT>` — the fixer runs detached with the user's repo as cwd:

  "When done with the fix, run:
   bash <PLUGIN>/skills/ci-watch/sidecar.sh set <TICKET_ID> fixer_active false
   This clears the fixer guard so the CI-watch cron can evaluate the next poll."

---

## Step 8.5: Arm CI-watch after first push

After the first IC agent reports a push to the remote branch (detected when the
monitoring loop sees a new commit on the remote), arm the CI-watch loop.

**Arming block** (single self-contained shell — do NOT split; each ```bash fence
is a fresh shell so vars do not carry across fences):

```bash
# Re-derive roots (session may have compacted; do not rely on Step 0/3 vars)
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
# CDT-141-C3: shared epic children live under epic-<ID>, not .worktrees/<TICKET-ID>
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
WT_PATH=$(bash "$EPIC_LIB" ensure-ticket-worktree "<TICKET-ID>" 2>/dev/null) \
  || WT_PATH="$MROOT/.worktrees/<TICKET-ID>"
BRANCH=$(git -C "$WT_PATH" rev-parse --abbrev-ref HEAD) || BRANCH=""

SIDECAR_CLI=$(bash "$PDH/skills/plugin-dir.sh" file skills/ci-watch/sidecar.sh)
DETECT_CLI=$(bash "$PDH/skills/plugin-dir.sh" file skills/ci-watch/detect-mode.sh)

# 1. Idempotent guard — already armed, skip
SIDECAR=$(bash "$SIDECAR_CLI" path "<TICKET-ID>")
[ -f "$SIDECAR" ] && exit 0

# 2. Detect quality-check mode
MODE_LINE=$(bash "$DETECT_CLI" "$WT_PATH")
MODE=$(echo "$MODE_LINE" | head -n1)
TEST_CMD=$(echo "$MODE_LINE" | sed -n 2p)
if [ "$MODE" = "none" ]; then
  echo "CI watch: no quality checks detected — skipping."
  exit 0   # skip to Step 9
fi

# 3. Draft PR (ci mode only)
PR=""
if [ "$MODE" = "ci" ]; then
  PR=$(cd "$WT_PATH" && gh pr view --json number -q .number 2>/dev/null || echo "")
  if [ -z "$PR" ]; then
    cd "$WT_PATH" && gh pr create --draft \
      --title "<TICKET-ID>: WIP — <issue title>" \
      --body "Auto-draft created by CI watch for <TICKET-ID>"
    PR=$(cd "$WT_PATH" && gh pr view --json number -q .number)
  fi
fi

# Guard before init
if [ -z "$MODE" ] || [ -z "$BRANCH" ]; then
  echo "CI watch: abort — MODE or BRANCH empty (MODE='$MODE' BRANCH='$BRANCH')" >&2
  exit 1
fi

# 4. Init sidecar
bash "$SIDECAR_CLI" init "<TICKET-ID>" "$MODE" "${PR:-}" "$BRANCH"
```

5. **Schedule cron** (Claude CronCreate tool — not bash; runs after the arming
   block succeeds). **Harness-aware durable** — full rule in
   `skills/ci-watch/SKILL.md` "Durable flag (harness-aware)"; summary:
   - Prefer `durable: true` when the harness supports it (native Claude Code
     persists across session restart).
   - If the CronCreate schema/description says durable is unavailable /
     session-only only → first call with `durable: false` (avoid a denied call).
   - Else try `durable: true`; on deny (e.g. cmux rejects durable outright,
     does **not** silently downgrade) → retry **once** with `durable: false`.
     Not fatal.
   Call CronCreate with:
   - cron: `"*/7 * * * *"` (off-minute per project convention)
   - durable: per harness rule above (`true` preferred, `false` fallback)
   - recurring: `true`
   - prompt: the self-contained cron body from skills/ci-watch/SKILL.md
     (copy the exact template, substituting TICKET-ID, BRANCH, and `<PLUGIN>`).
     `<PLUGIN>` is the resolved plugin root — the cron runs detached with the
     user's repo as cwd, so the helper scripts live in the plugin, not the repo:
     ```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
     PLUGIN=$(bash "$PDH/skills/plugin-dir.sh" dir skills/ci-watch/poll.sh | xargs dirname | xargs dirname)
     ```
     (`dir` gives `<root>/skills/ci-watch`; two `dirname`s strip back to the
     plugin root. The only `<MROOT>` left in the template is the data-file read
     `<MROOT>/.claude/ci-watch/<TICKET>.last_failure.txt`, which stays MROOT.)

   The cron prompt MUST be self-contained — it reads the sidecar and runs
   poll.sh without relying on any session context. See SKILL.md for the template.

6. **Persist cron job ID** (same shell session as step 5's PLUGIN resolve if
   needed; re-resolve SIDECAR_CLI if a new shell):
   ```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
SIDECAR_CLI=$(bash "$PDH/skills/plugin-dir.sh" file skills/ci-watch/sidecar.sh)
   bash "$SIDECAR_CLI" set "<TICKET-ID>" cron_job_id "<returned-job-id>"
   ```

7. **Notify** (include durability mode so the user knows session-close risk):
   - durable: `CI watch armed for <TICKET-ID> in <MODE> mode (cron job: <job-id>, durable).`
   - session-only: `CI watch armed for <TICKET-ID> in <MODE> mode (cron job: <job-id>, session-only — ends when this session ends).`

---

### Stint-end outcome emit (SPEC-026 M4) — named reusable block

Call when a **(task, agent) stint ends**. Never on Step-9 APPROVE alone (OQ4).
Fail-open — never block orchestration (M9). MVP outcomes: `accepted` | `escalated`
only (`rejected` reserved, never written this version).

**Session-local counters** (orchestrator tracks per compound `task_id`; same
bookkeeping SPEC-009 already requires for deadloop):
- `review_cycles` — increment on each Step-9 REQUEST CHANGES for that task
- `qa_bounces` — increment on each Step-10 QA FAIL routed back to the IC for that task
Initialize both to `0` when a stint starts (agent spawn / hand-off receive).

```bash
# Stint-end emit — set STINT_* then run. Re-resolve PDH (fresh shell).
# STINT_TICKET STINT_TASK_ID STINT_AGENT STINT_CLASS STINT_SIZE
# STINT_OUTCOME STINT_REVIEW_CYCLES STINT_QA_BOUNCES
# Optional fields: literal "null" when unknown. STINT_AGENT + STINT_OUTCOME required.
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
EMIT=$(bash "$PDH/skills/plugin-dir.sh" file skills/metrics/emit-outcome.sh)
MIN_CONF=$(python3 -c '
import json,sys
try:
  data=json.load(open(sys.argv[1]))
  print(data.get("council",{}).get("taskgate",{}).get("min_confidence",80))
except Exception:
  print(80)
' "$MROOT/.claude/settings.json" 2>/dev/null || echo 80)
# council_overturns: index rows for task_id where max_verdict_confidence is null
# OR < min (OQ2). Missing index / jq / null task_id → null arg.
COUNCIL_OVERTURNS=null
if command -v jq >/dev/null 2>&1 && [ -f "$MROOT/.claude/council/index.json" ] \
   && [ -n "${STINT_TASK_ID:-}" ] && [ "$STINT_TASK_ID" != "null" ]; then
  COUNCIL_OVERTURNS=$(jq -r --arg tid "$STINT_TASK_ID" --argjson min "$MIN_CONF" '
    (.[$tid] // [])
    | map(select(
        (.max_verdict_confidence == null)
        or ((.max_verdict_confidence | type == "number")
            and .max_verdict_confidence < $min)
      ))
    | length
  ' "$MROOT/.claude/council/index.json" 2>/dev/null || echo null)
fi
bash "$EMIT" \
  "${STINT_TICKET:-null}" "${STINT_TASK_ID:-null}" "${STINT_AGENT}" \
  "${STINT_CLASS:-null}" "${STINT_SIZE:-null}" "${STINT_OUTCOME}" \
  "${STINT_REVIEW_CYCLES:-null}" "${STINT_QA_BOUNCES:-null}" \
  "${COUNCIL_OVERTURNS:-null}" 2>/dev/null || true
```

**Call sites** (prose only — do not rewrite review/QA loop bodies):
1. **Escalated** (`STINT_OUTCOME=escalated`): Step-8 stuck-after-2 hand-off; Step-9
   3+-round deadloop escalate. Emit for the agent whose stint ends; counters as of
   hand-off.
2. **Accepted** (`STINT_OUTCOME=accepted`): **after** Step-10 finalizes `qa_bounces`
   for that task (QA PASS, or QA N/A with counter frozen). MUST NOT emit on Step-9
   APPROVE alone.

---

## Step 9: Tech Lead review loop

As each IC task completes, trigger a Tech Lead review:

```
@tech-lead — Review the changes for Task <ID> (<title>).

Output mode: terse

Check against:
- Spec: <spec path>
- Plan: <plan path>
- Task description: <description>

Evaluate:
1. Does it meet the spec requirements?
2. Code quality — would you approve this PR?
3. Any concerns about integration with other tasks?

Output: APPROVE, or REQUEST CHANGES with specific feedback.
```

### If REQUEST CHANGES:

Increment session-local `review_cycles` for this `task_id` (SPEC-026 counter only —
no ledger write). Send feedback back to the IC agent:

```
@<agent> — Tech Lead requested changes on Task <ID>:

<feedback>

Address these and mark task completed again when done.
```

### Deadloop detection:

Track review round count per task. If the same task has been reviewed 3+ times:

```
Task <ID> has been through <N> review rounds without consensus.

Tech Lead's latest feedback:
<feedback>

IC's latest response:
<response>

This looks like a disagreement — please weigh in:
1. Side with Tech Lead's approach
2. Side with IC's approach
3. Different direction entirely
```

Escalate to user. Do NOT let it loop further. Before re-assigning or pausing the
current agent, run **Stint-end outcome emit** with `STINT_OUTCOME=escalated` for
the agent whose stint is ending (counters as of hand-off).

**Autopilot — deadloop (3+ review rounds):** if `AUTOPILOT_ON` (Step 0), do NOT wait for the user
here. (Off-triad checkpoint; canonical gate = `plan-approve` — SPEC-033 M8 mapping; no new gate
enum value.) The Stint-end outcome emit above still fires unchanged first. Build the C3 §2 envelope
`{ workflow:"orchestrate", ticket_id:<ISSUE-ID>, gate:"plan-approve", run_id:RUN_ID,
iteration:ITER, run_start_epoch:RUN_START_EPOCH, autopilot_bump:AUTOPILOT_BUMP, <trigger signal:
"IC↔TL 3+ review rounds without consensus" — an unresolved product/architecture decision autopilot
cannot self-answer (BC1)> }` and call `skills/autopilot/self-answer.md`'s procedure for
`{decision, blocking_condition, confidence, rationale}` (exactly one `decided_by:"auto"` card is
appended; expected `blocking_condition = 1`). Act on `decision`:
- `halt` → emit `task_blocked` (detail = the one-line message below) via **Passive
  notifications → Tier B** (fail-open; § below), then print the one-line message below and
  return control:
```
plan-approve <decision>: <rationale> — card: <card-file-path>
```
Otherwise (autopilot off), the escalation above applies unchanged.

### After Tech Lead approves:

**Council gate for `requires_council: true` tasks (CDT-126).** Before calling
`TaskUpdate(task_id, completed)` for a task whose Step 7 `TaskCreate` description
carried `requires_council: true`, a qualifying `.claude/council/index.json` entry
MUST already exist for that task's compound `task_id` — otherwise the SPEC-002
TaskCompleted hook blocks completion (SPEC-009; SPEC-013 Task-ID Plumbing).
"Qualifying" means a **dual-shape** entry: non-null `max_verdict_confidence` **or**
null-verdict + non-null `max_finding_confidence`, at or above
`council.taskgate.min_confidence` (SPEC-002). Step 8 still requires **claim scope**
(never `--diff`) at this call site by product policy (claim audit) — claim-shape
rows are what orchestrated spawns write. Tiering changes **which** council
pipeline runs, never **whether** the gate fires (SPEC-013 § Council tiering) —
this block does not change that. Skip this block entirely for tasks without
`requires_council: true`.

Branch on `COUNCIL_TIER_OVERRIDE` (Step 0 — resolved once per run from
`--council-tier=<skip|light|full>` on this `/orchestrate` invocation; never
auto-selected):

- **`skip`** — the DRI forced this run to skip council entirely. Do NOT invoke
  `/council` at all for this task — no grading, no tribunal spawn, nothing (the
  short-circuit happens here, before any council invocation, per SPEC-013 §
  Council tiering's `skip` vocabulary). The orchestrator itself records an
  audit-trail row directly via `index-writer.sh` — the single owning surface
  for `.claude/council/index.json` (SPEC-013 "Recording the tier"; SPEC-026
  M10 forbids other writers):
  ```bash
  # Re-resolve PDH (each bash fence is a fresh shell)
  # lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
  PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
  INDEX_WRITER=$(bash "$PDH/skills/plugin-dir.sh" file skills/council/index-writer.sh)
  bash "$INDEX_WRITER" "<ISSUE-ID>-<task_id>" "" null null skip \
    "skip: DRI --council-tier=skip on /orchestrate <ISSUE-ID> (run_id=<RUN_ID>)"
  ```
  `<RUN_ID>` here is Step 0's resolved value (this is a fresh shell — a
  cross-block bash variable would be empty; substitute the literal text
  the same way `<ISSUE-ID>` / `<task_id>` are substituted elsewhere).

  **This row does NOT and structurally cannot satisfy `requires_council: true`**
  — `skip` never produces a verdict or findings, so **both** `max_verdict_confidence`
  and `max_finding_confidence` stay `null`, and the dual-shape hook rejects both-null
  conf (same as any empty-conf row). This is not routed around: AC6 (SPEC-013 §
  Council tiering) requires tiering to change *which* pipeline runs, never *whether*
  the gate fires, so the orchestrator MUST NOT clear `requires_council` on the task
  record to force completion through — that would be exactly the AC6 violation the
  ticket forbids. `skip` and `requires_council: true` are a **structural
  incompatibility** on the same task, and HALT before `TaskUpdate(completed)` — the
  DRI has to resolve it, not the orchestrator.

  **This is a genuine off-triad checkpoint (SPEC-033 M8 mapping; no new gate
  enum value, no ninth blocking condition) and maps to BC1** — an unresolved
  configuration conflict only a human can settle (drop `--council-tier=skip`
  for this task, or confirm `requires_council: true` isn't actually needed and
  remove it from the task record). It follows the same shape as every other
  off-triad halt in this file (e.g. Step 8's "Ambiguous requirement"):

  **Autopilot — skip/requires_council incompatibility:** if `AUTOPILOT_ON`
  (Step 0), do NOT wait for the user here. (Off-triad checkpoint; canonical
  gate = `plan-approve` — SPEC-033 M8 mapping; no new gate enum value.) Build
  the C3 §2 envelope `{ workflow:"orchestrate", ticket_id:<ISSUE-ID>,
  gate:"plan-approve", run_id:RUN_ID, iteration:ITER,
  run_start_epoch:RUN_START_EPOCH, autopilot_bump:AUTOPILOT_BUMP, <trigger
  signal: "task <task_id> has requires_council: true but this run carries
  --council-tier=skip; skip never produces a verdict, so the gate can never be
  satisfied for this task as configured — an unresolved configuration conflict
  autopilot cannot self-answer (BC1)"> }` and call
  `skills/autopilot/self-answer.md`'s procedure for `{decision,
  blocking_condition, confidence, rationale}` (exactly one `decided_by:"auto"`
  card is appended; expected `blocking_condition = 1`, and it MUST be recorded
  as `1` on the card — this conflict has no `proceed`/`reroute-epic` resolution,
  only `halt`). Act on `decision`:
  - `halt` → emit `task_blocked` (detail = the one-line message below) via
    **Passive notifications → Tier B** (fail-open; § below), then print the
    one-line message below and return control:
  ```
  plan-approve <decision>: <rationale> — card: <card-file-path>
  ```
  Otherwise (autopilot off), print this and wait for the user:
  ```
  Task <task_id> has requires_council: true, but this run carries
  --council-tier=skip. These are incompatible: skip never produces a council
  verdict, so the gate can never be satisfied for this task as configured.

  Resolve by either:
    1. Re-running this task's completion without --council-tier=skip (drop the
       DRI override for the rest of this run), or
    2. Confirming with the Tech Lead that requires_council: true is not actually
       needed for this task and removing it from the task record.
  ```
  Do not proceed to `TaskUpdate(completed)` until the conflict is resolved
  (either path above).
- **`light` or `full`** — an externally-supplied tier. The IC agent's Step 8
  spawn prompt already carries the instruction to invoke
  `/council "<CLAIM>" --task-id <task_id> --council-tier=<light|full>`
  (claim scope — see Step 8; never `--diff`) as part of finishing the task.
  The `<light|full>` there is the literal resolved value, substituted by the
  orchestrator at spawn time — same discipline as Step 8's own `<COMMAND>`
  and as `<RUN_ID>` above. A spawn prompt is prose handed to an agent, not a
  bash fence, so writing the shell variable name `$COUNCIL_TIER_OVERRIDE`
  literally into it would never expand; the agent would pass `/council` the
  four-character flag value `$COUNCIL_TIER_OVERRIDE`, which
  `commands/council.md` hard-fail #6 rejects outright. `commands/council.md`
  Step 1.5 honors the supplied tier at any scope and passes it straight
  through to `--tier` with no grading run (Task 3's "any scope" path — do not
  duplicate that grading logic here). Confirm a `verdict[]`-shape index entry
  exists before proceeding to `TaskUpdate(completed)`.
- **the literal string `"null"`** (no `--council-tier` on this run — Step 0's
  `jq -r '.council_tier // "null"'` renders parse-flags.sh's JSON `null` as
  the 4-character string `"null"`, not empty/unset; same idiom as
  `AUTOPILOT_BUMP`, and a test here MUST be `[ "$COUNCIL_TIER_OVERRIDE" = "null" ]`,
  never an emptiness check) — the IC agent's spawn prompt instructs a plain
  `/council "<CLAIM>" --task-id <task_id>` invocation (claim scope), which
  runs at `full` (`commands/council.md` Step 1.5.1 does not
  auto-grade any scope it resolves on its own — the diff-scope auto-grading
  trigger was removed entirely, Task 3's F-A fix; see Step 8). Confirm the
  index entry exists before proceeding to `TaskUpdate(completed)`.

In the `light`/`full`/`"null"` branches the orchestrator MUST have exported
`CLAUDE_TASK_ID=<task_id>` in the IC agent's subprocess environment at spawn
time (Step 8) so the council run binds to the correct index row (SPEC-013
Task-ID Plumbing). A missing or below-threshold verdict is not a new blocking
mechanism — it surfaces through this same Step 9 Tech Lead review loop, same
as any other incomplete task (SPEC-013 § Council tiering; no new gate).

Update TaskUpdate → completed. Check if this unblocks other tasks.
**Do NOT** emit an outcomes-ledger record here — wait for Step-10 QA terminal (OQ4).

On every TaskUpdate that changes a task's status, the orchestrator MUST also call:

```bash template
# Re-resolve PDH (each bash fence is a fresh shell)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
TASK_STORE=$(bash "$PDH/skills/plugin-dir.sh" file skills/orchestrate/task-store.sh)
bash "$TASK_STORE" update-status <ISSUE-ID>-<task_id> <new_status>
```

Use the same compound key as the `create` call (e.g. `CDV-QF-FILTER-1`). **MUST** pass the compound key — bare TaskCreate integers are non-native (CDT-167: unique compound is redirected, multi-match fails closed; historical bare stubs are handled by shadow-safe TaskCompleted, not invent). This mirrors the new status into `$MROOT/.claude/tasks/<ISSUE-ID>-<task_id>.json`, preserving all other fields. Applies to every transition — agent claiming (pending → in_progress), completion (→ completed), and blocking (→ blocked). The task store file is the persistent record consulted by the TaskCompleted council gate (SPEC-009, the task-store write/update/no-delete-after-completion MUSTs); it MUST never be deleted after task completion. If `task-store.sh` exits non-zero, surface the failure to the user.

### Defensive CI-watch cleanup

After any task transitions to `completed`, the orchestrator MUST run this block.
If TASK_ID does not end with `-ci-fixer`, skip this block.

Otherwise, verify `fixer_active` is false in the CI-watch sidecar:

```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
  # Extract TICKET from task_id (compound key format: TICKET-ci-fixer)
  # ci-fixer tasks have task_id like "CDV-1-ci-fixer"
  # Re-resolve PDH (each bash fence is a fresh shell)
  # lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
  PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
  SIDECAR_CLI=$(bash "$PDH/skills/plugin-dir.sh" file skills/ci-watch/sidecar.sh)
  TICKET=$(echo "$TASK_ID" | sed 's/-ci-fixer$//')
  # Do not mask helper-missing with `|| echo false` — let a missing plugin surface.
  FIXER_ACTIVE=$(bash "$SIDECAR_CLI" get "$TICKET" fixer_active 2>/dev/null)
  if [ "$FIXER_ACTIVE" = "true" ]; then
    bash "$SIDECAR_CLI" set "$TICKET" fixer_active false
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) corrected stale fixer_active=true" >> "$MROOT/.claude/ci-watch/$TICKET.log"
  fi
```

This guards against a fixer agent that exited without clearing the flag.

---

## Step 9.5: Code-simplify (optional polish, before QA)

After **all** IC tasks have Tech Lead **APPROVE** and **before** Step 10 QA,
run a single behavior-preserving polish pass. Protocol:
`skills/code-simplify/SKILL.md` (zero external deps; not a marketplace plugin).

**Skip when** any of:
- `CODE_SIMPLIFY=0` in the environment
- Diff is docs/config-only (no runtime source)
- Empty feature-branch diff vs merge-base

**Otherwise** spawn once using the skill's spawn template (ic4-class agent,
terse, file list from skill scope discovery, worktree `$WT_PATH`). Hard rules:
no behavior/API/schema change; recently modified files only; fail-open.

```
Code-simplify: <done | skipped | failed-open>
  files: <N>
  notes: <one line>
```

Do **not** re-open the Step 9 review loop for pure polish unless the simplify
agent reports it could not preserve behavior (then revert its edits and
`failed-open`). Do **not** block QA on simplify failure.

Then continue to Step 10.

---

## Step 10: QA validation

After all IC tasks pass Tech Lead review (and Step 9.5 simplify if run), spawn QA:

```
@qa — All implementation tasks for <ISSUE-ID> are complete and reviewed.

Output mode: terse

Validate against the spec:
- Spec: <spec path>
- Acceptance criteria: <list>

Run tests. Check edge cases. Report:
- PASS: all ACs met, tests green
- FAIL: list what's broken with specifics
```

If QA reports FAIL → increment session-local `qa_bounces` for the responsible
task_id (SPEC-026 counter only — no ledger write yet), then route failures back
to the responsible IC agent. Tech Lead reviews the fix. Repeat until QA passes.

When QA reports **PASS** (or QA is explicitly N/A and `qa_bounces` is frozen for
each finished task), run **Stint-end outcome emit** once per task with
`STINT_OUTCOME=accepted` and finalized counters. This is the accepted-stint
terminal (OQ4) — not Step-9 APPROVE.

---

## Step 10b: Spec alignment check (mandatory, survives pause/resume)

After QA passes, run a spec alignment check. This step is **mandatory** — it MUST
NOT be skipped even after session pauses, context compression, or `/reload-plugins`.
If you are resuming an orchestration and unsure which steps have run, check whether
a spec alignment check has been reported in the conversation. If not, run it now.

```
Run /spec check <spec-file> to verify code matches the spec written in Step 6.
If /spec check finds MISSING or DIFFERS items, route them back to the responsible
IC agent for correction before shipping.
```

This is the last quality gate before presenting to the user.

---

## Step 11: Ship (present to user)

When all tasks are complete, reviewed, and QA-validated:

```
<ISSUE-ID> is ready to ship.

Summary of changes:
<high-level diff summary — files changed, what each does>

Spec:    <spec path>
Plan:    <plan path>
Branch:  <branch name>
Tasks:   N/N completed
Closes:  <from plan Tracking, or "none (freeform)">

Options:
1. Create PR (I'll draft title + description)
2. Just show me the diff
3. I need to review manually first
```

### Epic release=end ship guard (CDT-141-C4)

When this ticket is under an epic with durable `release_bump` set (release=end)
and seal is not done, **forbid** mid-child land onto the baseline — including
`/release` **and** land-no-release (`--autopilot=master` / end-state §5b).
`assert-release-allowed` still runs first. Baseline must stay clean until
end-of-epic seal (C5).

```bash
# Re-resolve PDH (fresh shell)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
RELEASE_END_BLOCKED=false
_ASSERT_ERR=$(mktemp "${TMPDIR:-/tmp}/epic-assert-rel.XXXXXX")
if ! bash "$EPIC_LIB" assert-release-allowed "<ISSUE-ID>" 2>"$_ASSERT_ERR"; then
  RELEASE_END_BLOCKED=true
  cat "$_ASSERT_ERR" >&2 || true
fi
rm -f "$_ASSERT_ERR"
```

When `RELEASE_END_BLOCKED=true`:

- **Allowed:** Option 1 Create PR (PR-stop); Option 2/3 review; work stays on
  the integration branch (`feat/epic-<EPIC-ID>`). Child wrap via `/wrap-ticket`
  (does not release the integration tree — C3).
- **Forbidden:** autopilot `merge` → end-state (release **or** land-no-release);
  interactive "If squash merge requested"; `--resume-ship` any land path; any
  land onto master/main. Print the assert message and **halt** those paths —
  baseline unchanged, no version bump/tag/push, no land-no-release commit.
- Without `--release` on the parent epic (`release_bump` null/absent): assert
  exits 0 — per-child release/merge/land-no-release unchanged.

**Autopilot:** if `AUTOPILOT_ON` (Step 0), do NOT wait for the user here. Build the C3 §2
envelope `{ workflow:"orchestrate", ticket_id:<ISSUE-ID>, gate:"ship-choice",
run_id:RUN_ID, iteration:ITER, run_start_epoch:RUN_START_EPOCH,
autopilot_bump:AUTOPILOT_BUMP, <the Step-10b spec-alignment result, QA PASS/FAIL, the
session-local `qa_bounces` count (BC2), and ship-action irreversibility (protected-branch
merge / force-push)> }` and call `skills/autopilot/self-answer.md`'s procedure — it records
the clean answer as **card #1** (`blocking_condition = null` on a clean `pr`/`merge`).

**Council interposition (AC1 — SPEC-033 M14).** On a clean `pr` **or** `merge` card #1, run
`skills/autopilot/ship-gate-council.md`'s procedure **before any ship action** — on **both**
branches, not merge-only. That pass appends **card #2** (same `run_id`) and yields the
**post-council effective decision**: council **agree** (conf ≥ 80, non-degraded) keeps card #1's
`pr`/`merge`; **disagree / degraded / total-fail** forces `halt` (BC7). On a card #1 already
`halt`/`reroute-epic`, the council pass is **skipped** (ship-gate-council.md §2) and the
effective decision is card #1's.

Act on the **post-council effective decision**:
- `pr` → take Option 1 (Create PR) above exactly as the user's choice would; emit `task_complete`
  (detail = `shipped (PR): <PR URL>`) via **Passive notifications → Tier B** (fail-open; § below),
  then STOP — no `/release` (Tracking close-out below runs in its existing pre-delivery order).
  [PR-stop]
- `merge` → **CDT-141-C4:** if `RELEASE_END_BLOCKED=true`, do **not** run end-state;
  print `epic <ID> is in release=end mode until seal (CDT-141)` (from assert stderr),
  emit `task_blocked` via Tier B (fail-open), and return — baseline unchanged
  (release **and** land-no-release forbidden mid-epic). Else run
  `skills/autopilot/end-state.md` (shared preflight then branch on
  `AUTOPILOT_BUMP` — SPEC-033 N3a / CDT-195):
  deterministic BC3 push-target check (N3a) → record `SHIP_START_SHA` →
  `git merge --squash <branch>` (stage only) → then:
  - **`AUTOPILOT_BUMP` ∈ {patch, minor, major}** → **§5-release:** still **no**
    `git commit` here → `/release <AUTOPILOT_BUMP>` (sole commit + tag + push).
    **NEVER** pass `master` to `/release`.
  - **`AUTOPILOT_BUMP` = master** → **§5-land-no-release:** interactive-shape
    `git commit` + non-force `git push origin <baseline>` — **MUST NOT** invoke
    `/release`, version files, tag, or CHANGELOG.
  Then §5.5 ship-history clean check (SPEC-010 H; cite, do not restate D1–D4)
  and §6 closeout. Does **not** route through the interactive "If squash merge
  requested" block below (`autopilot_bump != null` is engine-guaranteed).
  On land success **and** end-state §5.5 clean (§6 closeout done), emit
  `task_complete` via **Passive notifications → Tier B** (fail-open; § below):
  - release path: detail = `released <bump>/<tag>`
  - land-no-release: detail = `landed master (no release)`
  On dirty ship-history (H8): halt with exact `history dirty — rewrite needed`;
  **MUST NOT** Linear/backlog Done, **MUST NOT** print Orchestration complete /
  ship success.
- `halt` / `reroute-epic` → print the one-line message below and return control; on `halt`
  **only**, first emit `task_blocked` (detail = the one-line message below) via **Passive
  notifications → Tier B** (fail-open; § below) — `reroute-epic` does NOT notify-blocked;
  `reroute-epic` additionally hands off to `/epic` decompose:
  The `/epic` decompose invocation MUST carry the autopilot state forward — pass
  `--autopilot[=<bump>]` (or `AUTOPILOT=1`); `/epic` Step 0.5 resolves its OWN autopilot state
  independently and does NOT inherit the caller's (SPEC-033 M11a).
```
ship-choice <decision>: <rationale> — card: <card-file-path>
```
On a **BC7 / ship-choice `halt`**, also print the resume hint (CDT-135; CDT-195):
```
Ship halted (BC7). To finish shipping after human review without re-running the
full ticket, use:
  /orchestrate <ISSUE-ID> --resume-ship=<patch|minor|major|master>
or reply "resume ship <patch|minor|major|master>" in this session (same sequence).
Bare --resume-ship re-reads plan/card mode. Does NOT auto-bypass BC7 — you must
explicitly confirm (path-aware: release vs land-no-release).
```
Otherwise (autopilot off), the user-choice gate below applies unchanged.

Wait for user choice.

### Resume ship after BC7 override (CDT-135; CDT-195)

**When:** A prior ship-choice halt (typically BC7 after M14 council disagree /
degraded / spawn-fail) left the work ready to ship, the human has reviewed and
**explicitly** wants to finish shipping, and re-running full PM/TL/IC is waste.

**Entry (either):**
1. `/orchestrate <ISSUE-ID> --resume-ship[=<patch|minor|major|master>]`
2. In-session after a BC7 halt: user says `resume ship` / `resume ship patch` /
   `resume ship master` (etc.)

**Bump resolution (context-aware):** explicit `=<token>` wins and overrides
recorded mode; else plan Tracking `autopilot_bump` / last ship-choice card bump
if non-null (bare re-read); else ask once (`patch` recommended for fix trains;
`master` only when land-no-release is intentional). Invalid token → error, no
ship actions. Tokens ∈ {patch, minor, major, master}.

**MUST NOT:** re-run scope-confirm / plan-approve / IC implementation / M14
council as if starting fresh; invent a bump; skip the human confirmation line
below; force-push; pass `master` to `/release`; force release path when token
is `master` (or force land-no-release when token is a release bump).

**Confirmed sequence (one orchestrated path — replace ad-hoc land then
`/wrap-ticket`):**

0. **CDT-141-C4:** run `assert-release-allowed <ISSUE-ID>` first. On exit 64
   (release=end mid-flight): print the message, **stop** — no squash, no
   `/release`, no land-no-release, baseline unchanged. (Seal is C5; resume-ship
   is not a seal. Mid-epic land-no-release forbidden too.)
1. Print plan summary: branch, worktree, proposed token, land path name
   (`release <bump>` vs `land-no-release`), last ship-choice card path
   (`$MROOT/.claude/autopilot/<ISSUE-ID>.jsonl` if present).
2. Ask once with **path-aware** confirm (**required**; autopilot MUST NOT
   self-answer this confirmation — human override of a safety halt):
   - release token: `Proceed with release <bump> + wrap-ticket <ISSUE-ID>? (y/n)`
   - `master`: `Proceed with land-no-release (commit+push baseline, no /release)
     + wrap-ticket <ISSUE-ID>? (y/n)`
3. On `n` / empty: stop; no side effects.
4. On `y`:
   - If worktree still present: run `skills/autopilot/end-state.md` for the
     chosen token (shared preflight → §5-release **or** §5-land-no-release →
     §5.5 → tracking close-out per that file's §6).
   - Else if already on baseline with clean tree after a prior partial land:
     - release token: run `/release <bump>` only if version files still need
       the bump; otherwise skip to wrap.
     - `master`: **MUST NOT** run `/release`; if commit already pushed, skip
       to wrap; if staged-only leftover, halt for human.
   - Then `/wrap-ticket <ISSUE-ID>` (idempotent close-out + worktree release).
5. Emit `task_complete` via Passive notifications Tier B (fail-open):
   - release: detail = `resume-ship released <bump>`
   - land-no-release: detail = `resume-ship landed master (no release)`
6. Append one decision card to the ticket ledger if append-card is available:
   `gate=ship-choice`, `decision=merge`, `decided_by=user`,
   `blocking_condition=null`, `bump=<resolved token>`, rationale notes path
   (`human override of BC7 via --resume-ship` + `release` or `land-no-release`)
   (never rewrite prior halt cards).

**Failure:** any land abort (`/release` pre-commit gate, land-no-release
commit/push fail, ship-history dirty) → stop; leave wrap for later; print the
failing gate / evidence.

### Linear lifecycle (status truth — master is Done)

Linear issue status must match **where the code lives**, not “implementation
finished in a worktree”:

| Phase | Linear status | When |
|-------|---------------|------|
| Work started | **In Progress** | Step 3 (already) |
| PR open / not on master | **In Review** | PR-stop, draft/ready PR, release=end child left on integration branch |
| Landed on master + close-out | **Done** (or team Released) | Squash/merge to baseline succeeds (interactive, release `/release`, **or** land-no-release commit+push), **and** ship-history clean (SPEC-010 H), **or** `/wrap-ticket` after land |

**MUST NOT** set Linear to **Done** when the only ship action was open a PR,
push a feature branch, or finish IC/QA while changes are still off master.
That was a footgun: tickets looked Done while master lacked the code.

**MUST NOT** set Linear to **Done** when ship-history is dirty (SPEC-010 H5/H8/H9):
run `check-ship-history.sh --since $SHIP_START` (or ambient `SHIP_START_SHA`) and
require exit 0 before any master-land Done. Dirty → exact halt
`history dirty — rewrite needed`; trackers stay open. Cite SPEC-010 H — do not
restate D1–D4.

Local backlog write-through (`close.sh`) may still flip **local** COMPLETED at
ship (process cache) only when ship-history is clean on master-land paths.
Linear terminal state is **master-land / wrap**, not PR-open.

### Tracking close-out (ship DoD — orchestrator-owned)

**Before** finalizing the delivery commit (PR tip commit or squash), close every
**local** tracker listed under plan `closes:` (`backlog/<slug>.md`). Do this on
the **feature worktree** (`--root "$WT_PATH"`) so edits land on the branch tree
— not mid-flight by parallel ICs (avoids `backlog.md` races).

**Linear** (`linear:<ID>` / source=linear) is **path-dependent** (see table above):
- **PR-stop / autopilot `pr` / release=end PR-only:** MCP → **In Review** + PR URL
  comment. **MUST NOT** Done.
- **Master land** (interactive squash onto baseline, autopilot `merge` after
  release **or** land-no-release success **and** ship-history clean, resume-ship
  after either land path): MCP → **Done** + PR/SHA comment. **Requires** clean
  `check-ship-history.sh` (SPEC-010 H5/H9) first — see ship-history gate below.
- Fail-open if MCP unavailable: print a warning; do not invent Done or In Review.

**Autopilot land-path exception (AC5, CDT-111-C9; CDT-195):** on the autopilot
`merge` → end-state path (release **or** land-no-release) **only**, this close-out
runs **after** the land succeeds **and** end-state §5.5 ship-history is clean
(per `skills/autopilot/end-state.md` §6) — not before — so trackers stay open if
`/release` aborts at a pre-commit gate, land-no-release commit/push fails, or
history is dirty (nothing claimed Done). Every other path (interactive PR,
interactive squash, autopilot `pr`) keeps the before-commit ordering below for
**local** backlog; Linear follows the lifecycle table. Master-land paths still
require the ship-history gate before Linear **Done**.

```bash
# Re-resolve PDH / MROOT / WT (fresh shell). Parse backlog slugs from plan Tracking.
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
CLOSE=$(bash "$PDH/skills/plugin-dir.sh" file skills/backlog/close.sh)
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
WT_PATH=$(bash "$EPIC_LIB" ensure-ticket-worktree "<ISSUE-ID>" 2>/dev/null) \
  || WT_PATH="$MROOT/.worktrees/<ISSUE-ID>"
# Prefer worktree root for --root when present (local write-through on branch tree).
[ -d "$WT_PATH" ] || WT_PATH=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# For each plan closes: entry of form backlog/<slug>.md (or bare slug):
bash "$CLOSE" "<slug>" --root "$WT_PATH" --ticket "<ISSUE-ID>" --status "FIXED/CLOSED"
bash "$CLOSE" verify "<slug>" --root "$WT_PATH" || {
  echo "Ship blocked: backlog/<slug> still open after close" >&2
  exit 1
}
```

- Close local write-through (item Status + index) on disk; **MUST NOT** stage or
  commit `.claude/backlog*` / `.claude/plans*` into the product delivery commit
  (process trackers never upstream — SPEC-009 / CDT-54).
- For each `linear:<ID>` (or source=linear): apply **Linear lifecycle** for this
  ship path (**In Review** on PR-stop; **Done** only after master land). Comment
  with PR URL and/or SHA when known. Fail-open if MCP unavailable.
- Empty `closes:` (freeform): print `Tracking: none (freeform)` — do not block.
- Non-empty closes that fail verify on local write-through: **block ship**.

### If PR requested:

```bash template
cd <worktree-path>
# Tracking close-out already applied on this worktree (above) — status only; do NOT git add .claude/backlog*
git status --short
git push -u origin <branch>
gh pr create --title "<ISSUE-ID>: <title>" --body "$(cat <<'EOF'
## Summary
<bullet points from plan>

## Acceptance Criteria
- [x] <AC 1>
- [x] <AC 2>

## Test Plan
<QA validation results>

## Spec
<link to spec file>

Closes <ISSUE-ID>

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

If `gh` is not available, fall back to `git push -u origin <branch>` and print the
URL for manual PR creation.

If Linear is available: set status to **In Review** (not Done), attach/link the
PR, comment with PR URL. Covered by Tracking close-out PR-stop branch.

### If squash merge requested (no PR):

**CDT-141-C4:** if `RELEASE_END_BLOCKED=true` (or `assert-release-allowed
<ISSUE-ID>` exits 64), **halt** — do not squash onto master; print the
release=end message; master unchanged. Prefer PR-stop or leave work on the
integration branch until epic seal (C5).

Prefer plain git — do NOT require `gh`. Apply Tracking close-out on the feature
worktree first (local write-through; Linear **Done** only after squash commit on
master succeeds — if squash fails, leave Linear at In Progress/In Review):

```bash template
# CDT-141-C4 precheck (re-resolve if fresh shell)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
bash "$EPIC_LIB" assert-release-allowed "<ISSUE-ID>" || exit 64
# Tracking close-out on WT_PATH already done (above) — status flips only; do NOT
# include .claude/backlog* or .claude/plans* in the squash tree.
cd <main-repo-path>
git merge --squash <branch>
git commit -m "<ISSUE-ID>: <title>

<bullet summary>

Co-Authored-By: Claude <model> <noreply@anthropic.com>"
```

**Honest identity** — replace `<model>` with the agent/model actually performing this commit. Do **not** hardcode Claude/Anthropic when the agent is something else (e.g. Grok, Codex, a human). Examples:
- `Co-Authored-By: Grok <noreply@x.ai>`
- `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

Only use `gh pr merge --squash` if the user explicitly created a PR and `gh` is
available. Plain `git merge --squash` is the default merge path.

### Ship-history gate before master-land Done (SPEC-010 H5/H7–H9; CDT-188)

On **any master-land path** (interactive squash onto baseline, autopilot `merge`
end-state after release **or** land-no-release, resume-ship after either land)
**before** Linear **Done**, local backlog terminal close that implies ship
success, or Step 12 `Orchestration complete`:

1. Ensure `SHIP_START` / `SHIP_START_SHA` is known (end-state §3.5 /
   `/release` Step 0.5; for interactive squash-only or land-no-release without
   `/release`, record `SHIP_START=$(git rev-parse HEAD)` on the main-repo path
   **before** the squash commit).
2. Run the install-aware checker (cite SPEC-010 H — **do not** restate D1–D4):

```bash
# Fresh shell — re-resolve PDH (SPEC-021 C1)
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
CHECK_SHIP=$(bash "$PDH/skills/plugin-dir.sh" file skills/release/check-ship-history.sh)
SHIP_START="${SHIP_START:-${SHIP_START_SHA:-}}"
[ -n "$SHIP_START" ] || { echo "orchestrate: SHIP_START unset for master-land gate" >&2; exit 64; }
bash "$CHECK_SHIP" --since "$SHIP_START"
```

3. **Exit 0** — proceed with Linear Done / closeout / Step 12 complete banner.
4. **Exit 1 dirty:**
   - **Autopilot on (H8):** halt with exact `history dirty — rewrite needed`
     plus checker evidence. **MUST NOT** Done, **MUST NOT** `Orchestration
     complete`, **MUST NOT** silent force-push.
   - **Interactive (H7):** print evidence + rewrite plan; require explicit user
     confirm before rewrite/force-push; on decline → halt (refs unchanged).
5. **PR-stop paths** skip this gate (no master land / no Done claim).

---

## Worktree cleanup

**CDT-141-C3:** when this ticket used a **shared epic integration** worktree
(`USE_SHARED=true` / `resolve-child-worktree.skip_release`), **MUST NOT** call
`worktree-lib release` on the child slug **or** the `epic-<EPIC-ID>` integration
slug — other children still need the tree. Prefer `/wrap-ticket <ISSUE-ID>` which
also skips release when shared. Integration tree lifecycle is epic-owned (C5 seal
/ end-of-epic), not per-child wrap.

**Prefer `worktree-lib.sh release <slug>`** only for **non-shared** per-ticket
trees — it handles EBUSY retry, branch deletion, and orphaned config-section
cleanup. Use it instead of running `git worktree remove` + `git branch -D` by hand:

```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
SLUG="<ISSUE-ID>"
CHILD_WT=$(bash "$EPIC_LIB" resolve-child-worktree "$SLUG")
if [ "$(jq -r '.skip_release // false' <<<"$CHILD_WT")" = "true" ]; then
  echo "Shared epic integration worktree — skipping release of $SLUG / integration slug"
else
  WT_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/worktree-lib.sh)
  bash "$WT_LIB" release "$SLUG"
fi
```

If you must do it by hand (squash-merge case where the lib refuses on
"uncommitted changes"), run each step as a SEPARATE Bash call — never
chain `worktree remove && branch -D` in a single command. On WSL2 the
second op fires while the first is still releasing `.git/config`, which
produces `error: could not write config file .git/config: Device or
resource busy`. The branch ref still gets deleted but the
`[branch "feat/X"]` config stanza orphans:

```bash template
git worktree remove <path-1>      # call 1
git branch -D <branch-1>          # call 2 (separate Bash invocation)
git worktree prune                # call 3 (reaps leftover admin entries)
```

**Serialize across worktrees** — do NOT remove multiple worktrees in
parallel for the same reason. Drain them one at a time.

---

## Step 12: Wrap up

Suggest running `/wrap-ticket <ISSUE-ID>` for worktree removal + learnings.
- **After PR-stop:** Linear should be **In Review**; wrap after **merge** sets **Done**.
- **After master land:** Linear should already be **Done**; wrap re-applies Done
  idempotently (safety net) + local re-close.

Do **not** set Done from preference while code is still off master.

### Ship-history before `Orchestration complete` (SPEC-010 H5/H9; CDT-188)

On **master-land** paths (interactive squash, autopilot `merge` release **or**
land-no-release, resume-ship), **before** printing the `Orchestration complete`
banner:

- Require a clean `check-ship-history.sh --since $SHIP_START` result (same
  install-aware resolve as Step 11 ship-history gate; cite SPEC-010 H — do
  **not** restate D1–D4).
- **Dirty (H8 autopilot / H7 interactive):** print exact
  `history dirty — rewrite needed` (+ evidence). **MUST NOT** print
  `Orchestration complete`. **MUST NOT** claim Linear Done if not already
  blocked at Step 11. Halt; leave rewrite to human confirm (H7) or clean re-check.
- **PR-stop:** may print the banner with Tracking `Linear In Review (PR)` —
  ship-history gate does not apply (no master land).

Print (master-land only when ship-history clean; PR-stop always OK):

```
Orchestration complete for <ISSUE-ID>

Timeline:
  Scope confirmed:    <timestamp>
  Plan approved:      <timestamp>
  Implementation:     <N tasks, N agents>
  Review rounds:      <total across all tasks>
  QA:                 PASS

Artifacts:
  Branch:  <branch>
  PR:      <PR URL or "not created">
  Spec:    <spec path>
  Plan:    <plan path>
  Tracking: <closed N backlog | Linear In Review (PR) | Linear Done (on master) | none (freeform)>

Next: /wrap-ticket <ISSUE-ID> after merge (sets Linear Done if still In Review)
```

---

## Step 12b: Friction check (non-blocking)

Before exiting, check the just-completed orchestration session for friction
signals. Never auto-run `/retro`. Never block.

```bash
# Locate the dev-team plugin root (PDH). Optional CLAUDE_PLUGIN_ROOT (force path / FR #48230), else cwd dev/worktree, else marketplace clone (slug-free agents/pm.md), else installed cache (rank by /dev-team/<VER>/ segment, not full path; CDT-166). CDT-82: marketplace before same-version cache.
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
bash "$PDH/skills/retro-gate/hint.sh" 2>/dev/null || true
```

Non-blocking. Silently skipped when gate binary is absent or JSONL is not
found. No user action required.

---

## Orchestrator Rules

These rules apply to YOU (the main Claude) throughout the entire flow:

1. **You do NOT write code.** Not even "small fixes". Route everything through agents.
2. **You do NOT make architectural decisions.** That's Tech Lead's job. You facilitate.
3. **You DO escalate** when triggers are hit (Step 8). Err on the side of asking.
4. **You DO track state** — keep a mental model of which tasks are in which state.
5. **You DO keep Linear updated** (if available) at each phase transition.
6. **You DO keep the user informed** with concise status updates at natural milestones.
7. **You DO protect the user's time** — batch questions, don't interrupt for routine progress.
8. **You DO close trackers at ship** — plan `closes:` local write-through always;
   Linear **In Review** on PR-stop, Linear **Done** only when on master (Step 11
   lifecycle). Wrap re-Dones as safety net. Never leave close-out as optional hygiene.
   **Never** stage process trackers (`.claude/backlog*`, `.claude/plans*`) into the
   product commit.

---

## Passive notifications (CDV-210)

Tiered, fail-open progress visibility for long `/orchestrate` runs. **Never block**
orchestration on notify failures. Unset MCP + unset `AGENT_WEBHOOK_URL` → silent
(today's behavior). Dual delivery is OK when both MCP and webhook are available.

### Tier A — MCP (human milestones)

At each milestone below, if any Slack/Discord MCP tool is available
(`mcp__slack__*` / `mcp__discord__*` or project-equivalent), post a **short**
summary (one line + ticket/task id). Missing tools = skip. Never block.

| Milestone | When |
|-----------|------|
| task completed | Agent spawn returns success; after `TaskUpdate(completed)` |
| task blocked (+ reason) | Agent/task enters blocked; after `TaskUpdate(blocked)` |
| QA pass / QA fail | Step 10 QA terminal report |
| council finished | `/council` returns — verdict one-liner **or** findings one-liner |
| unrecoverable error / hard stop | Orchestration cannot continue |

Do **not** notify on routine progress (lint, intermediate test flakes the IC is
fixing, CI-watch polls).

### Tier B — Webhook (`AGENT_WEBHOOK_URL`)

When `AGENT_WEBHOOK_URL` is set, fire the shared fail-open helper at the same
milestones. Resolve via plugin-dir (fresh shell each fence):

```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
NOTIFY=$(bash "$PDH/skills/plugin-dir.sh" file skills/notify/webhook.sh)
# Optional context (omit empty):
#   NOTIFY_SOURCE=orchestrate  NOTIFY_AGENT=<agent>  NOTIFY_TASK=<task_id>  NOTIFY_TICKET=<ISSUE-ID>
NOTIFY_SOURCE=orchestrate NOTIFY_TICKET="<ISSUE-ID>" NOTIFY_TASK="<task_id>" NOTIFY_AGENT="<agent>" \
  bash "$NOTIFY" <event> "<detail ≤500 chars>"
```

**Event enum:**

| Event | Orchestrate call site |
|-------|----------------------|
| `task_complete` | Task completed (optional: TaskCompleted hook also emits with `source=task_completed`) |
| `task_blocked` | Task blocked — detail = reason |
| `qa_pass` | Step 10 QA PASS |
| `qa_fail` | Step 10 QA FAIL — detail = short failure list |
| `council_verdict` | Council finished with verdict[] — detail = verdict one-liner |
| `council_findings` | Council finished with findings only — detail = findings one-liner |
| `error` | Unrecoverable error / hard stop — detail = short cause |

`scheduled_retro` remains **CDV-190-owned** (`write-scheduled-report.sh`); same
URL is fine. Helper always exits 0 (`curl -m 5 || true`). Payload fields:
`event`, `time` (ISO-UTC), `source`; optional `agent` / `task` / `ticket` /
`detail` (≤500). **No secrets, transcripts, or file bodies.**

### Tier C — Silent

Neither MCP tools nor `AGENT_WEBHOOK_URL` → zero I/O beyond existing user-facing
status lines.

---

## Change Discipline

These rules constrain how work is structured. Violating them is an escalation trigger.

### Atomic PRs — one logical change per PR

- Each ticket = its own branch + its own PR. Never bundle multiple tickets into one change.
- A PR should do ONE thing. If the description needs "and" to explain it, it's too big.

### Size limits

- **~1,000 LOC of real code** per PR (soft cap). Tests, generated code, and migrations don't count toward this limit.
- **Hard cap: 2,000 LOC total** (including tests). If a PR exceeds this, it must be split.
- **No single file > 1,000 lines.** If a file approaches this, pause and discuss decomposition with Tech Lead before continuing.

When a task would exceed these limits, the orchestrator must:
1. Stop the IC agent
2. Have Tech Lead split the task into smaller, shippable increments
3. Each increment gets its own task, branch, and PR
4. Increments ship sequentially — each must be green and mergeable on its own

### Refactoring is always a separate PR

If implementation requires refactoring existing code:
1. **Stop implementation.** Do not mix refactoring with feature work.
2. Have Tech Lead design the refactor — what changes, what stays, what's the migration path.
3. Ship the refactor PR first. Get it merged.
4. Resume feature implementation on top of the clean base.

If the refactor is large enough to warrant its own ticket, create one (in Linear if available, otherwise `/backlog add`).

### Discovered work → new tickets

When agents discover work that wasn't in the original plan:
- **Do NOT absorb it** into the current PR.
- Create a new ticket (Linear if available, otherwise `/backlog add`).
- If it blocks the current work, escalate to user with: "This blocks <ISSUE-ID>. Create a blocking ticket and do it first, or defer?"

### Replan gate

Whenever the approach changes materially — new dependencies discovered, scope expanded, architecture assumption invalidated:
1. **Pause all IC work.**
2. Spawn Tech Lead to replan.
3. Present updated plan to user for approval.
4. Only resume after user confirms.
5. When regenerating the plan file, re-write the `## Tracking` `autopilot_on`/
   `autopilot_bump` lines with the current run's Step-0 values (same rule as
   Step 6 — CDT-111-C8 AC1; never drop them on replan).

This applies even if the change seems small. Small deviations compound.

---

## Error Handling

Task metadata writes via `skills/orchestrate/task-store.sh` are **distinct from** the Claude Code TaskList / TaskCreate / TaskUpdate tools. Both tracks must stay in sync: TaskCreate → `task-store.sh create`, each TaskUpdate → `task-store.sh update-status`. If either track fails, the orchestrator MUST surface the failure to the user rather than silently diverging. The task store is the persistent source of truth for the TaskCompleted council gate (SPEC-002); TaskList is the in-session state.

- **No git repo**: warn; skip worktree, work in current directory
- **Linear MCP unavailable**: fall back to prompted context; use plans for tracking instead
- **Agent fails to start**: retry once, then report to user with error details
- **Worktree already exists for this issue**: `worktree-lib.sh ensure` reuses it silently (writes a fresh lock). A prompt only appears if another live PID holds the lock — in that case surface the lib's stderr output to the user.
- **Branch already exists**: check if it has unmerged work; ask user before resetting
- **All agents stuck**: don't panic — present the full state to user and ask for direction
- **User goes AFK mid-flow**: pause gracefully; state is in tasks + plan file; resumable
