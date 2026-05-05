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
```

Read in parallel:
- `$MROOT/AGENTS.md`
- Claude memory:
  ```bash
  if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
    HAS_DISTILLED=$(sqlite3 "$MEMDB" "SELECT COUNT(*) FROM memories WHERE agent='claude' AND tier > 0 AND archived=FALSE;")
    if [ "$HAS_DISTILLED" -gt 0 ]; then
      sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='claude' AND tier=2 AND archived=FALSE ORDER BY type, updated_at DESC;"
      sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='claude' AND tier=1 AND archived=FALSE ORDER BY type, updated_at DESC;"
    else
      sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='claude' AND tier=0 AND archived=FALSE ORDER BY type, created_at DESC;"
    fi
  else
    cat "$MROOT/.claude/memory/claude/memory.md" 2>/dev/null
  fi
  ```
- _(Tech Lead and PM memory loading removed from Step 0 — both agents load their own
  memory via their agent definitions when spawned in Step 4. Loading it here was
  redundant and added ~2-5K tokens to the orchestrator's startup context.)_

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
WT_PATH=$(bash "$MROOT/skills/worktree-lib.sh" ensure "$SLUG") || {
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

For each task in the approved plan, call TaskCreate:

```
TaskCreate:
  subject: "<ISSUE-ID> Task N — <title>"
  description: |
    <description>
    Recommended agent: <ic4|ic5|qa>
    Depends on: [Task IDs] or "none"
    requires_council: <true|false>   # omit = false
```

After each TaskCreate succeeds and the task id is known, the orchestrator MUST call:

```bash
bash skills/orchestrate/task-store.sh create <ISSUE-ID>-<task_id> "<subject>" <requires_council>
```

where `<ISSUE-ID>` is the current issue ID (e.g. `CDV-QF-FILTER`) and `<task_id>` is the integer returned by TaskCreate (e.g. `1`). The compound key (e.g. `CDV-QF-FILTER-1`) prevents task-store collisions when a new Claude process reuses the same integer IDs across runs. This writes `$MROOT/.claude/tasks/<ISSUE-ID>-<task_id>.json` — the source of truth the SPEC-002 TaskCompleted hook reads to determine whether the council quality gate applies (SPEC-009 line 48). If `task-store.sh` exits non-zero, surface the error to the user immediately — do NOT silently continue.

Update the plan file with task IDs.

If Linear is available, add a comment with the task breakdown.

---

## Step 8: Execute — spawn agents and monitor

**CRITICAL: You do NOT write code. You orchestrate.**

For each task that has no blockers, spawn the recommended agent in the worktree:

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

Whenever the orchestrator invokes `/council` as part of a task's orchestration steps (e.g., a task with `requires_council: true` that requires a council verdict before completion), the orchestrator MUST export `CLAUDE_TASK_ID=<task_id>` in the subprocess environment of that `/council` invocation. This is the ambient task-id transport SPEC-013 Phase 6 uses for verdict-to-task binding via the fallback chain `--task-id` flag → `CLAUDE_TASK_ID` env → unbound (SPEC-009 line 46; SPEC-013 Task-ID Plumbing). The hook path (SPEC-002 TaskCompleted) resolves its task id from stdin JSON and does NOT share this fallback chain — the two paths are independent.

The orchestrator MAY also export `CLAUDE_TASK_ID=<task_id>` when spawning regular IC agents for a task; this is useful when the agent itself invokes `/council` mid-task as a self-review.

### PM kickoff is mandatory for every ticket

When orchestrating an umbrella ticket with child issues, each child ticket MUST get
its own PM kickoff (Step 4 AC review). Do NOT skip PM for "obvious" tickets or
tickets that came from a TL plan — PM's job is to validate ACs independently.
In session 00000000, PM caught a false premise in CDV-151's spec that would have
broken the implementation. Skipping PM for 5/7 child tickets was a missed opportunity.

### Monitoring loop

After spawning, enter a monitoring cycle:

1. Check TaskList periodically for progress
2. When an agent completes a task, check if blocked tasks are now unblocked → spawn next agents
3. Surface blockers or errors to user immediately

### DAG-aware task fan-out

At orchestration start and after every task status transition to `completed`,
compute the unblocked set via:

  ```bash
  READY=$(bash "$MROOT/skills/orchestrate/dag-lib.sh" ready-set)
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

When a CI-watch cron spawns a `dev-team:ic5` fixer agent, the fixer prompt
MUST end with this instruction:

  "When done with the fix, run:
   bash <MROOT>/skills/ci-watch/sidecar.sh set <TICKET_ID> fixer_active false
   This clears the fixer guard so the CI-watch cron can evaluate the next poll."

---

## Step 8.5: Arm CI-watch after first push

After the first IC agent reports a push to the remote branch (detected when the
monitoring loop sees a new commit on the remote), arm the CI-watch loop:

1. **Check if already armed** (idempotent guard):
   ```bash
   SIDECAR="$MROOT/.claude/ci-watch/<TICKET-ID>.json"
   [ -f "$SIDECAR" ] && exit 0   # already armed, skip
   ```

2. **Detect quality-check mode**:
   ```bash
   MODE_LINE=$(bash "$MROOT/skills/ci-watch/detect-mode.sh" "$WT_PATH")
   MODE=$(echo "$MODE_LINE" | head -n1)
   TEST_CMD=$(echo "$MODE_LINE" | sed -n 2p)
   ```
   If MODE is `none`: print "CI watch: no quality checks detected — skipping." and skip to Step 9.

3. **Create draft PR** (ci mode only):
   In ci mode, create a draft PR immediately if one doesn't exist yet:
   ```bash
   PR=$(cd "$WT_PATH" && gh pr view --json number -q .number 2>/dev/null || echo "")
   if [ -z "$PR" ]; then
     cd "$WT_PATH" && gh pr create --draft \
       --title "<TICKET-ID>: WIP — <issue title>" \
       --body "Auto-draft created by CI watch for <TICKET-ID>"
     PR=$(cd "$WT_PATH" && gh pr view --json number -q .number)
   fi
   ```

4. **Init sidecar**:
   ```bash
   bash "$MROOT/skills/ci-watch/sidecar.sh" init "<TICKET-ID>" "$MODE" "${PR:-}" "$BRANCH"
   ```

5. **Schedule durable cron**:
   Call CronCreate (Claude tool) with:
   - cron: `"*/7 * * * *"` (off-minute per project convention)
   - durable: `true`
   - recurring: `true`
   - prompt: the self-contained cron body from skills/ci-watch/SKILL.md
     (copy the exact template, substituting TICKET-ID, MROOT, and BRANCH)

   The cron prompt MUST be self-contained — it reads the sidecar and runs
   poll.sh without relying on any session context. See SKILL.md for the template.

6. **Persist cron job ID**:
   ```bash
   bash "$MROOT/skills/ci-watch/sidecar.sh" set "<TICKET-ID>" cron_job_id "<returned-job-id>"
   ```

7. **Notify**:
   Print: `CI watch armed for <TICKET-ID> in <MODE> mode (cron job: <job-id>).`

---

## Step 9: Tech Lead review loop

As each IC task completes, trigger a Tech Lead review:

```
@tech-lead — Review the changes for Task <ID> (<title>).

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
bash skills/orchestrate/task-store.sh update-status <ISSUE-ID>-<task_id> <new_status>
```

Use the same compound key as the `create` call (e.g. `CDV-QF-FILTER-1`). This mirrors the new status into `$MROOT/.claude/tasks/<ISSUE-ID>-<task_id>.json`, preserving all other fields. Applies to every transition — agent claiming (pending → in_progress), completion (→ completed), and blocking (→ blocked). The task store file is the persistent record consulted by the TaskCompleted council gate (SPEC-009 lines 49–51); it MUST never be deleted after task completion. If `task-store.sh` exits non-zero, surface the failure to the user.

### Defensive CI-watch cleanup

After any task transitions to `completed`, the orchestrator MUST run this block.
If TASK_ID does not end with `-ci-fixer`, skip this block.

Otherwise, verify `fixer_active` is false in the CI-watch sidecar:

  # Extract TICKET from task_id (compound key format: TICKET-ci-fixer)
  # ci-fixer tasks have task_id like "CDV-1-ci-fixer"
  TICKET=$(echo "$TASK_ID" | sed 's/-ci-fixer$//')
  FIXER_ACTIVE=$(bash skills/ci-watch/sidecar.sh get "$TICKET" fixer_active 2>/dev/null || echo "false")
  if [ "$FIXER_ACTIVE" = "true" ]; then
    bash skills/ci-watch/sidecar.sh set "$TICKET" fixer_active false
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) corrected stale fixer_active=true" >> "$MROOT/.claude/ci-watch/$TICKET.log"
  fi

This guards against a fixer agent that exited without clearing the flag.

---

## Step 10: QA validation

After all IC tasks pass Tech Lead review, spawn QA:

```
@qa — All implementation tasks for <ISSUE-ID> are complete and reviewed.

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

Co-Authored-By: Claude <noreply@anthropic.com>"
```

Only use `gh pr merge --squash` if the user explicitly created a PR and `gh` is
available. Plain `git merge --squash` is the default merge path.

---

## Worktree cleanup

When removing worktree branches after a squash merge, `git branch -d` will fail
with "not fully merged" (expected — squash merge doesn't create a merge commit).
Use `git branch -D` instead.

**Serialize worktree removal** — do NOT remove multiple worktrees in parallel.
Parallel git operations on shared `.git/config` cause `error: could not write
config file .git/config: Device or resource busy`. Remove worktrees one at a time:

```bash
git worktree remove <path-1> && git branch -D <branch-1>
git worktree remove <path-2> && git branch -D <branch-2>
```

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
# Locate gate.sh via plugin version lookup (mirrors commands/init-team.md pattern)
PLUGIN_VER=$(cat ~/.claude/plugins/cache/cold-dark-void/dev-team/*/.claude-plugin/plugin.json 2>/dev/null \
  | grep -o '"version": *"[^"]*"' | tail -1 | grep -o '[0-9][0-9.]*')
GATE_SH="$HOME/.claude/plugins/cache/cold-dark-void/dev-team/${PLUGIN_VER}/skills/retro-gate/gate.sh"
if [ ! -x "$GATE_SH" ]; then
  GATE_SH=$(find ~/.claude/plugins/cache -path "*/dev-team/*/skills/retro-gate/gate.sh" 2>/dev/null | sort -V | tail -1)
fi

HINT_SH="$(dirname "$GATE_SH")/hint.sh"
bash "$HINT_SH" "$GATE_SH" 2>/dev/null || true
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
