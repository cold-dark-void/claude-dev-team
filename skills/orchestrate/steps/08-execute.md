<!-- /orchestrate phase body. Load via SKILL.md router — current step only. -->

## Step 8: Execute — spawn agents and monitor

When `[ "$ORCH_TIER" = "light" ]`: **You still do NOT write code.** Spawn exactly one `@ic4` at low effort for the single task. No DAG ready-set fan-out. No task-store graph. Do not append the `requires_council` council instruction (that task MUST NOT set `requires_council`). Then monitor that one agent. Escalation triggers, CI-watch 8.5, and stint-end still apply. Skip the multi-agent spawn loop and DAG-aware fan-out below.

Before spawning @ic4:
```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
RESOLVE=$(bash "$PDH/skills/plugin-dir.sh" file skills/model-map/resolve-model.sh)
MODEL=$(bash "$RESOLVE" ic4)
printf '%s\n' "$MODEL"
```
Bash stdout = model string; empty → omit model.
Surface resolver stderr to the user. Do not swallow.
If MODEL is non-empty: pass it as the Agent model param.
If MODEL is empty: omit model. MUST NOT pass "".
If spawn fails attributed to the model param (invalid/unknown/unsupported model): retry once with model omitted; warn `model-map: host rejected model '<string>' for ic4; retrying with Tier default`.
Other spawn failures MUST NOT be retried as a model fallback.

```
Spawn @ic4 for the single light-tier task (low effort):
"<task description>

Output mode: terse

Work in worktree: <path>
Spec: <spec path>
Plan: <plan path>

When done, mark your task completed via TaskUpdate. Return your final report as
this agent invocation's output — do NOT SendMessage to the orchestrator. There
is no addressable parent named 'main' or 'orchestrator'; symbolic addressing
will fail. The orchestrator reads your output directly from this spawn return."
```

Otherwise (omit / `standard` / `full`):

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

Before spawning @<agent> (same roster name as `Spawn @<agent>`):
```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && pwd; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
RESOLVE=$(bash "$PDH/skills/plugin-dir.sh" file skills/model-map/resolve-model.sh)
MODEL=$(bash "$RESOLVE" <agent>)
printf '%s\n' "$MODEL"
```
Bash stdout = model string; empty → omit model.
Surface resolver stderr to the user. Do not swallow.
If MODEL is non-empty: pass it as the Agent model param.
If MODEL is empty: omit model. MUST NOT pass "".
If spawn fails attributed to the model param (invalid/unknown/unsupported model): retry once with model omitted; warn `model-map: host rejected model '<string>' for <agent>; retrying with Tier default`.
Other spawn failures MUST NOT be retried as a model fallback.

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
  MUST carry the autopilot state forward — pass `--autopilot[=<bump>]` (or `AUTOPILOT=1`)
  so `/epic` Step 0.5 re-enables autopilot. When `<bump>` ∈ {patch,minor,major},
  also pass `--worktree --release <bump>` (seal-intent; MUST NOT land each child
  on master). `/epic` persists that bump as `release_bump` (SPEC-033 M11a / CDT-196).
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
