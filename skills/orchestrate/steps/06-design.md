<!-- /orchestrate phase body. Load via SKILL.md router — current step only. -->

## Step 6: Tech Lead designs approach

When `[ "$ORCH_TIER" = "light" ]`: do not spawn Tech Lead for a second design pass. The scoper-planner already wrote `.claude/plans/<YYYY-MM-DD>-<ISSUE-ID>-<slug>.md` with Tracking (Step 4). Skip the `@tech-lead — ACs are confirmed` spawn below. Present that plan summary. SPEC-033 `plan-approve` still fires — the Autopilot self-answer block below stays. Then Step 6b.

Otherwise (omit / `standard` / `full`):

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
  `--autopilot[=<bump>]` (or `AUTOPILOT=1`). When `<bump>` ∈ {patch,minor,major},
  also pass `--worktree --release <bump>` (seal-intent; MUST NOT land each child
  on master). `/epic` persists that bump as `release_bump` (SPEC-033 M11a / CDT-196).
- `halt` → emit `task_blocked` (detail = the one-line message below) via **Passive
  notifications → Tier B** (fail-open; § below), then print the one-line message below and
  return control:
```
plan-approve <decision>: <rationale> — card: <card-file-path>
```
Otherwise (autopilot off), the user-approval gate below applies unchanged.

Wait for user approval. This is the second escalation gate.

### Step 6b: Domain glossary write-back on the worktree (conditional)

Mirror `/kickoff` Step 7b. After the plan is approved (or auto-approved), if this
run crystallized **user-confirmed** domain terms (AC resolution, design choices,
or Step 3b-missed plan delta):

1. Write into **`$WT_PATH/CONTEXT.md`** (never `$MROOT/CONTEXT.md`) per
   `skills/domain-glossary/SKILL.md`
2. Commit on `feat/<ISSUE-ID>` (or shared epic branch) — couple with the Step 6
   spec commit when both change in the same turn:
   ```bash
   # Fresh shell — re-derive WT (SPEC-021 C1)
   # lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
   PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
   EPIC_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/epic/epic-lib.sh)
   WT_PATH=$(bash "$EPIC_LIB" ensure-ticket-worktree "<ISSUE-ID>")
   git -C "$WT_PATH" add CONTEXT.md specs/
   git -C "$WT_PATH" commit -m "spec+context: <ISSUE-ID> — <feature area> + glossary"
   ```
   or a dedicated `context: <ISSUE-ID> — crystallized glossary terms` if specs
   already committed.
3. If no new terms, skip silently.

**MUST NOT** leave glossary as uncommitted dirt on the main tree while the
feature branch carries only specs/code.

