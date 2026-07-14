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

---

## Step 0: Resolve roots and load context

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
# Locate the dev-team plugin root (PDH). Dev checkout first, else installed cache (highest version). Slug-free, sort -V.
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
```

`$PDH` is the install-aware plugin root: helper scripts ship in the plugin
(not the user's repo), so every `skills/…` helper below is resolved through
`bash "$PDH/skills/plugin-dir.sh" file <relpath>` rather than `$MROOT/skills/…`.

Read in parallel:
- `$MROOT/AGENTS.md`
- Claude memory:
  ```bash
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

---

## Step 1: Fetch issue context

**Try Linear first** — check if Linear MCP tools are available (e.g. `linear_getIssue`).

If Linear MCP available:
- Fetch issue by ID
- Extract: title, description, acceptance criteria, priority, assignee, status, labels
- Print summary to user

If Linear MCP NOT available:
- Ask user:
  > "No Linear integration detected. Paste the issue details (title, description, acceptance criteria):"
- Parse what they provide

Store the issue context for all subsequent agent prompts.

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

Wait for user confirmation before proceeding. This is the first escalation gate.

---

## Step 3: Create branch and worktree

A git worktree is an additional working tree linked to the same repository — it lets
agents work on the issue branch in isolation without disturbing the main checkout.

```bash
SLUG="<ISSUE-ID>"   # MUST be the bare issue ID exactly as-is (e.g. "CDV-42")
                    # wrap-ticket detects the worktree at .worktrees/<ISSUE-ID> using
                    # this exact value — a longer slug will break detection
WT_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/worktree-lib.sh)
WT_PATH=$(bash "$WT_LIB" ensure "$SLUG") || {
  EXIT=$?
  if [ "$EXIT" -eq 2 ]; then
    echo "Worktree setup aborted by user." >&2
  elif [ "$EXIT" -eq 64 ]; then
    echo "worktree-lib.sh usage error, check slug" >&2
  fi
  exit "$EXIT"
}
```

`worktree-lib.sh` creates the branch `feat/<SLUG>` automatically and prints the
absolute worktree path to stdout — that value is captured in `WT_PATH`. Use
`$WT_PATH` everywhere downstream that references the worktree location.

- **Exit 1** (unexpected error): git or filesystem failure in the lib; stderr will have details; halt.
- **Exit 2** (user aborted): halt cleanly.
- **Exit 64** (usage error): unexpected — surface "worktree-lib.sh usage error, check slug" to stderr.

The worktree path comes from the lib's stdout (`$WT_PATH`) — all agent work happens there.

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
   PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
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

For each task in the approved plan, call TaskCreate:

```
TaskCreate:
  subject: "<ISSUE-ID> Task N — <title>"
  description: |
    <description>
    Recommended agent: <ic4|ic5|qa>
    Depends on: [Task IDs] or "none"
    requires_council: <true|false>   # omit = false
    Machine-check: <shell-expr> | none   # see below
```

**`Machine-check:` line (SPEC-019 PR2, ADR AMB-1).** When offload is in play, the
Tech Lead records a per-task **deterministic** machine-check as a `Machine-check:
<shell-expr>` prose line (mirroring `Recommended agent:`) — NOT a `task-store.sh`
schema field. The expression is a single shell string runnable via `bash -c` from
the worktree (tests, lint, `bash -n`, `jq`/JSON-validate, or a build) whose exit 0
means "the change is correct"; it is threaded **verbatim** into the offload path's
`run.sh --check`. Use the literal `none` for tasks with no deterministic check
(ambiguous/novel/design). A **missing line or `none` routes the task to Claude** —
one half of the Step 8 offload eligibility gate.

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
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
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

For each task that has no blockers, decide HOW to execute it. The default and
fallback path is the Claude IC spawn fence below; the optional local-agent offload
path (SPEC-019) is an **additive fork evaluated first**. The spawn fence is the
literal `else`/default of that fork, left **verbatim** — when offload is off,
ineligible, or exhausted, execution is byte-for-byte the pre-feature behavior.

### Local-agent routing fork (SPEC-019 PR2 — additive, evaluated before the spawn fence)

Before spawning the Claude IC for a ready task, evaluate this gate. **If ALL of the
following hold, take the offload sub-block below; OTHERWISE skip it entirely and
spawn the Claude IC via the unchanged fence that follows.**

1. **Flag on:** `LOCAL_AGENT=opencode` exactly (the env opt-in; any other value or
   unset ⇒ skip).
2. **Eligible task type:** the task's `Recommended agent:` line marks ic4-class
   *implementation* (extending an existing pattern), *codebase discovery/search*,
   or *docs/boilerplate generation*. Any other type ⇒ skip.
3. **Forbidden-agent guard (hard):** the task is NOT any of — **tech-lead**
   (architecture/design), **ic5** (ambiguous/novel/security-sensitive), the
   **qa-gate** final release gate, the **council judge or any council/blind-review
   investigator**, **PM kickoff**, or **release/version-bump/commit** work. A match
   here skips the offload branch unconditionally — these NEVER offload, even with
   the flag set and a machine-check present.
4. **Machine-check present:** the task description carries a `Machine-check:
   <shell-expr>` line whose value is NOT the literal `none`. Missing or `none` ⇒
   skip (route to Claude, per Step 7).
5. **Preflight ok:** `run.sh` itself does the real preflight (flag match,
   `command -v opencode`, `opencode --version` liveness) and returns exit `2` on any
   failure — an absent/dead opencode is a transparent call-time fallback (exit 2 ⇒
   Claude), not a hard precondition here.

Skipping for any reason falls through to the Claude IC spawn fence below.

#### Offload sub-block (runs only when the fork above selected offload)

This is a **dedicated scoped sub-block**, NOT a rewrite of the Step-9 Tech-Lead
review loop and NOT a modification of the spawn fence (SPEC-019 ADR AMB-5,
protecting the central-file LOC budget per SPEC-009).

**Compose a self-contained brief** (briefest sufficient — SPEC-019 SHOULD). The
local agent has NO project memory: the brief is its sole context. Assemble: the
task description; only the **spec MUST/SHOULD excerpts** that bound this task; the
**file paths** it reads/edits (absolute, within the worktree); the **machine-check
string** (the bar it must clear); and an explicit instruction to follow the **TDD
gate** (RED → GREEN → REFACTOR for runtime-behavior changes) and stay within
SPEC-009 LOC caps. Do **NOT** include or reference agent memory, cortex, the SQLite
memory DB, or any credential (SPEC-019 MUST; the wrapper appends nothing).

**Resolve helpers and the labeled savings constant** (SPEC-019 ADR AMB-2 — per-task
ESTIMATE of Claude tokens saved, coarse planning constants, NOT measured):

```bash
RUN_SH=$(bash "$PDH/skills/plugin-dir.sh" file skills/local-agent/run.sh)
EMIT_METRIC=$(bash "$PDH/skills/plugin-dir.sh" file skills/local-agent/emit-orch-metric.sh)
# saved_est = ESTIMATE of Claude authoring tokens avoided (NOT measured):
#   ic4-class implementation -> 8000 ; discovery/search -> 3000 ; docs/boilerplate -> 2000
# On escalation (offload abandoned) saved_est is 0.
SAVED_EST=<8000|3000|2000 by task type>
MCHECK="<verbatim Machine-check: value>"
```

**Two independent attempt counters, each capped at 2** (both inherit SPEC-009's
"stuck after 2 → escalate"). Initialize `LOCAL_ATTEMPTS=0`, `REVIEW_ATTEMPTS=0`.
Loop:

```bash
bash "$RUN_SH" --worktree "$WT_PATH" --brief "$BRIEF" --check "$MCHECK"
RC=$?
```

Branch on `$RC`:

- **exit 2 (fallback)** — flag off / opencode absent / liveness failed. Log ONE
  notice (`Task <ID>: local-agent unavailable, running on Claude.`), then **fall
  through to the Claude IC spawn fence below**. NO loop, NO escalation metric — this
  is the invisible-when-off path. (Do NOT emit a `saved_est` metric here; nothing
  was offloaded.)
- **exit 1 (machine-check failed)** — local-iteration cap. `LOCAL_ATTEMPTS++`. If
  `LOCAL_ATTEMPTS < 2`: fold the machine-check failure (the stderr/diagnostic) into
  the brief and re-call `run.sh`. These iterations cost **no Claude tokens**. If
  `LOCAL_ATTEMPTS >= 2`: **escalate** (see below).
- **exit 0 (machine-check passed)** — trigger a **Claude diff review of the
  worktree diff**, the same bar as Claude-authored work. **Reuse the existing
  review mechanism — do NOT clone it:** invoke council `diff-mode` (SPEC-010), or
  equivalently route the diff through the **Step-9 Tech-Lead review loop** body
  (its APPROVE / REQUEST CHANGES contract). On **APPROVE** → accept; the task then
  passes the SAME `TaskCompleted` council gate as Claude-authored work (SPEC-013;
  set `requires_council` per the plan and export `CLAUDE_TASK_ID` exactly as for a
  Claude IC). On **REQUEST CHANGES** → `REVIEW_ATTEMPTS++`; if `REVIEW_ATTEMPTS < 2`
  fold the review feedback into the brief and re-call `run.sh`; if
  `REVIEW_ATTEMPTS >= 2` (second rejected review) → **escalate**.

After folding feedback into the brief on either an exit-1 retry or an exit-0
REQUEST CHANGES retry, return to the `Loop:` `run.sh` call above and re-evaluate
`$RC`.

**Escalate** (either cap exhausted): spawn the Claude IC via the unchanged fence
below, passing **the local agent's partial worktree diff as context** — Claude owns
and completes the output. At this terminal handoff emit `saved_est = 0` (offload
abandoned): `bash "$EMIT_METRIC" "<ISSUE-ID>" 0 null`.

**Instrument every terminal outcome** (SPEC-019 ADR AMB-3 companion record; `run.sh`
stays frozen and writes its own `saved_est_tokens: null` line — the non-null
ESTIMATE lives ONLY on this companion record):

- **accepted (review APPROVE)** → `bash "$EMIT_METRIC" "<ISSUE-ID>" "$SAVED_EST"
  null` (`spent_review_escalation` is `null` in this version: the orchestrator has
  no reliable per-task Claude-token meter and MUST NOT fabricate one (AMB-2 honesty
  rule); the field exists for a future metered implementation).
- **escalated (either cap)** → `saved_est = 0` (the escalation call shown above).
- **fallback (exit 2)** → no companion metric; `run.sh` already logged its line.

When offload accepts or escalates, the task proceeds to Step 9 / Step 10 exactly as
a Claude-authored task would — there is no separate completion path.

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

Whenever the orchestrator invokes `/council` as part of a task's orchestration steps (e.g., a task with `requires_council: true` that requires a council verdict before completion), the orchestrator MUST export `CLAUDE_TASK_ID=<task_id>` in the subprocess environment of that `/council` invocation. This is the ambient task-id transport SPEC-013 Phase 6 uses for verdict-to-task binding via the fallback chain `--task-id` flag → `CLAUDE_TASK_ID` env → unbound (SPEC-009, the `CLAUDE_TASK_ID` export MUST; SPEC-013 Task-ID Plumbing). The hook path (SPEC-002 TaskCompleted) resolves its task id from stdin JSON and does NOT share this fallback chain — the two paths are independent.

The orchestrator MAY also export `CLAUDE_TASK_ID=<task_id>` when spawning regular IC agents for a task; this is useful when the agent itself invokes `/council` mid-task as a self-review.

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

Without step 3, `/standup` will show stale `in_progress` counters and
the TaskCompleted hook (council gate) never fires for that task. The
file-based task store at `.claude/tasks/<task_id>.json` is the source
of truth that survives compaction; TaskList is the in-session view of
it.

### DAG-aware task fan-out

At orchestration start and after every task status transition to `completed`,
compute the unblocked set via:

  ```bash
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

- **Agent stuck after 2 genuine attempts** — present what was tried, ask for guidance
- **Scope creep detected** — agent discovers work not in the plan; ask user whether to expand scope or defer to backlog
- **Ambiguous requirement** — agent can't resolve from spec/ACs alone
- **Breaking change discovered** — schema migration, API contract change, dependency bump
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
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
WT_PATH="$MROOT/.worktrees/<TICKET-ID>"
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

5. **Schedule durable cron** (Claude CronCreate tool — not bash; runs after the
   arming block succeeds):
   Call CronCreate with:
   - cron: `"*/7 * * * *"` (off-minute per project convention)
   - durable: `true`
   - recurring: `true`
   - prompt: the self-contained cron body from skills/ci-watch/SKILL.md
     (copy the exact template, substituting TICKET-ID, BRANCH, and `<PLUGIN>`).
     `<PLUGIN>` is the resolved plugin root — the cron runs detached with the
     user's repo as cwd, so the helper scripts live in the plugin, not the repo:
     ```bash
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
   bash "$SIDECAR_CLI" set "<TICKET-ID>" cron_job_id "<returned-job-id>"
   ```

7. **Notify**:
   Print: `CI watch armed for <TICKET-ID> in <MODE> mode (cron job: <job-id>).`

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

Send feedback back to the IC agent:

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

Escalate to user. Do NOT let it loop further.

### After Tech Lead approves:

Update TaskUpdate → completed. Check if this unblocks other tasks.

On every TaskUpdate that changes a task's status, the orchestrator MUST also call:

```bash
# Re-resolve PDH (each bash fence is a fresh shell)
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
TASK_STORE=$(bash "$PDH/skills/plugin-dir.sh" file skills/orchestrate/task-store.sh)
bash "$TASK_STORE" update-status <ISSUE-ID>-<task_id> <new_status>
```

Use the same compound key as the `create` call (e.g. `CDV-QF-FILTER-1`). This mirrors the new status into `$MROOT/.claude/tasks/<ISSUE-ID>-<task_id>.json`, preserving all other fields. Applies to every transition — agent claiming (pending → in_progress), completion (→ completed), and blocking (→ blocked). The task store file is the persistent record consulted by the TaskCompleted council gate (SPEC-009, the task-store write/update/no-delete-after-completion MUSTs); it MUST never be deleted after task completion. If `task-store.sh` exits non-zero, surface the failure to the user.

### Defensive CI-watch cleanup

After any task transitions to `completed`, the orchestrator MUST run this block.
If TASK_ID does not end with `-ci-fixer`, skip this block.

Otherwise, verify `fixer_active` is false in the CI-watch sidecar:

```bash
  # Extract TICKET from task_id (compound key format: TICKET-ci-fixer)
  # ci-fixer tasks have task_id like "CDV-1-ci-fixer"
  # Re-resolve PDH (each bash fence is a fresh shell)
  PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
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

## Step 10: QA validation

After all IC tasks pass Tech Lead review, spawn QA:

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

If QA reports FAIL → route failures back to the responsible IC agent.
Tech Lead reviews the fix. Repeat until QA passes.

---

## Step 10b: Spec alignment check (mandatory, survives pause/resume)

After QA passes, run a spec alignment check. This step is **mandatory** — it MUST
NOT be skipped even after session pauses, context compression, or `/reload-plugins`.
If you are resuming an orchestration and unsure which steps have run, check whether
a spec alignment check has been reported in the conversation. If not, run it now.

```
Run /check-specs <spec-file> to verify code matches the spec written in Step 6.
If /check-specs finds MISSING or DIFFERS items, route them back to the responsible
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

Options:
1. Create PR (I'll draft title + description)
2. Just show me the diff
3. I need to review manually first
```

Wait for user choice.

### If PR requested:

```bash
cd <worktree-path>
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

If Linear is available, update issue status and link the PR.

### If squash merge requested (no PR):

Prefer plain git — do NOT require `gh`:

```bash
cd <main-repo-path>
git merge --squash <branch>
git commit -m "<ISSUE-ID>: <title>

<bullet summary>

Co-Authored-By: Claude <model> <noreply@anthropic.com>"
```

Only use `gh pr merge --squash` if the user explicitly created a PR and `gh` is
available. Plain `git merge --squash` is the default merge path.

---

## Worktree cleanup

**Prefer `worktree-lib.sh release <slug>`** — it handles EBUSY retry, branch
deletion, and orphaned config-section cleanup in the right order. Use it
instead of running `git worktree remove` + `git branch -D` by hand:

```bash
WT_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/worktree-lib.sh)
bash "$WT_LIB" release "$SLUG"
```

If you must do it by hand (squash-merge case where the lib refuses on
"uncommitted changes"), run each step as a SEPARATE Bash call — never
chain `worktree remove && branch -D` in a single command. On WSL2 the
second op fires while the first is still releasing `.git/config`, which
produces `error: could not write config file .git/config: Device or
resource busy`. The branch ref still gets deleted but the
`[branch "feat/X"]` config stanza orphans:

```bash
git worktree remove <path-1>      # call 1
git branch -D <branch-1>          # call 2 (separate Bash invocation)
git worktree prune                # call 3 (reaps leftover admin entries)
```

**Serialize across worktrees** — do NOT remove multiple worktrees in
parallel for the same reason. Drain them one at a time.

---

## Step 12: Wrap up

Suggest running `/wrap-ticket <ISSUE-ID>` for cleanup and learnings capture.

If Linear is available, update issue status to "In Review" or "Done" based on user preference.

Print:

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

Next: /wrap-ticket <ISSUE-ID> after merge
```

---

## Step 12b: Friction check (non-blocking)

Before exiting, check the just-completed orchestration session for friction
signals. Never auto-run `/retro`. Never block.

```bash
# Locate the dev-team plugin root (PDH). Dev checkout first, else installed cache (highest version). Slug-free, sort -V.
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
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
