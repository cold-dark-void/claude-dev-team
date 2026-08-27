<!-- /orchestrate phase body. Load via SKILL.md router — current step only. -->

## Step 9: Tech Lead review loop

When `[ "$ORCH_TIER" = "light" ]`: single-pass TL diff review (same Check against / Evaluate as the spawn below). Run the standard resolve fences anyway (`tech-lead` review + IC `<agent>` rework). Max one rework (one REQUEST CHANGES → IC fix → re-review). Then APPROVE or escalate. Do not use the 3-round deadloop as the default. Skip Step 9.5 code-simplify. Council EFFECTIVE: if `COUNCIL_TIER_OVERRIDE` is not the string `"null"`, use that value (`skip|light|full`) — `--tier=light --council-tier=full` runs council; `--tier=light --council-tier=skip` skips. Else (override is `"null"`): no council spawn. After APPROVE: TaskUpdate completed. Skip `task-store.sh update-status` when no task-store file. Defensive CI-watch cleanup still applies if a ci-fixer task exists.

Otherwise (omit / `standard` / `full`):

As each IC task completes, trigger a Tech Lead review:

Before spawning @tech-lead:
```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
RESOLVE=$(bash "$PDH/skills/plugin-dir.sh" file skills/model-map/resolve-model.sh)
MODEL=$(bash "$RESOLVE" tech-lead)
printf '%s\n' "$MODEL"
EFFORT=$(bash "$RESOLVE" --effort tech-lead)
printf '%s\n' "$EFFORT"
```
Bash stdout = model string; empty → omit model.
Then `resolve-model.sh --effort` (same agent). Non-empty EFFORT → pass as Agent `effort` param; empty → omit (MUST NOT pass `""`).
Surface resolver stderr to the user. Do not swallow.
If MODEL is non-empty: pass it as the Agent model param.
If MODEL is empty: omit model. MUST NOT pass "".
If spawn fails attributed to the model param (invalid/unknown/unsupported model): retry once with model omitted; warn `model-map: host rejected model '<string>' for tech-lead; retrying with Tier default`.
If spawn fails attributed to the `effort` param (invalid/unknown/unsupported effort): retry once omitting effort; warn `model-map: host rejected effort '<token>' for tech-lead; retrying with inherited effort`.
Model host-reject stays independent. Ambiguous failure: do not guess; do not combinatorial-retry both params.
Other spawn failures MUST NOT be retried as a model or effort fallback.

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

Before spawning @<agent> (same roster name as `Spawn @<agent>`):
```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
RESOLVE=$(bash "$PDH/skills/plugin-dir.sh" file skills/model-map/resolve-model.sh)
MODEL=$(bash "$RESOLVE" <agent>)
printf '%s\n' "$MODEL"
EFFORT=$(bash "$RESOLVE" --effort <agent>)
printf '%s\n' "$EFFORT"
```
Bash stdout = model string; empty → omit model.
Then `resolve-model.sh --effort` (same agent). Non-empty EFFORT → pass as Agent `effort` param; empty → omit (MUST NOT pass `""`).
Surface resolver stderr to the user. Do not swallow.
If MODEL is non-empty: pass it as the Agent model param.
If MODEL is empty: omit model. MUST NOT pass "".
If spawn fails attributed to the model param (invalid/unknown/unsupported model): retry once with model omitted; warn `model-map: host rejected model '<string>' for <agent>; retrying with Tier default`.
If spawn fails attributed to the `effort` param (invalid/unknown/unsupported effort): retry once omitting effort; warn `model-map: host rejected effort '<token>' for <agent>; retrying with inherited effort`.
Model host-reject stays independent. Ambiguous failure: do not guess; do not combinatorial-retry both params.
Other spawn failures MUST NOT be retried as a model or effort fallback.

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
terse, file list from skill scope discovery, worktree `$WT_PATH`). Follow the
`skills/code-simplify/SKILL.md` spawn template (T6): resolve `ic4` via
`resolve-model.sh` / `resolve-model.sh --effort` before spawn; same host-reject
retry-once-omit (model and effort independent) as other sites. Hard rules: no
behavior/API/schema change; recently modified files
only; fail-open.

```
Code-simplify: <done | skipped | failed-open>
  files: <N>
  notes: <one line>
```

Do **not** re-open the Step 9 review loop for pure polish unless the simplify
agent reports it could not preserve behavior (then revert its edits and
`failed-open`). Do **not** block QA on simplify failure.

Then continue to Step 10.
