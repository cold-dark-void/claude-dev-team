---
name: orchestrate
description: Full lifecycle orchestrator — fetches issue context, creates worktree, spawns
  agents end-to-end, enforces tech-lead review loops, and optionally ships a PR. You stay
  as observer/navigator; agents do all the work. Usage: /orchestrate CDV-1 or /orchestrate
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
  && PROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || PROOT=$(pwd)
MEMDB="$PROOT/.claude/memory/memory.db"
```

Read in parallel:
- `$PROOT/AGENTS.md`
- Claude memory:
  ```bash
  if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
    sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='claude' AND type='memory' ORDER BY updated_at DESC LIMIT 1;"
  else
    cat "$PROOT/.claude/memory/claude/memory.md" 2>/dev/null
  fi
  ```
- Tech Lead cortex:
  ```bash
  if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
    sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='tech-lead' AND type='cortex' ORDER BY updated_at DESC LIMIT 1;"
  else
    cat "$PROOT/.claude/memory/tech-lead/cortex.md" 2>/dev/null
  fi
  ```
- PM cortex:
  ```bash
  if [ -f "$MEMDB" ] && command -v sqlite3 &>/dev/null; then
    sqlite3 "$MEMDB" "SELECT content FROM memories WHERE agent='pm' AND type='cortex' ORDER BY updated_at DESC LIMIT 1;"
  else
    cat "$PROOT/.claude/memory/pm/cortex.md" 2>/dev/null
  fi
  ```

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

```bash
BRANCH="feat/<ISSUE-ID>-$(echo '<slug from title>' | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | head -c 40)"
git branch "$BRANCH" 2>/dev/null || true
git worktree add "$PROOT/../$(basename $PROOT)-$ISSUE_ID" "$BRANCH"
```

Note the worktree path — all agent work happens there.

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
3. For each task: recommended agent (ic4/ic5/qa) and why
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
```

Update the plan file with task IDs.

If Linear is available, add a comment with the task breakdown.

---

## Step 8: Execute — spawn agents and monitor

**CRITICAL: You do NOT write code. You orchestrate.**

For each task that has no blockers, spawn the recommended agent in the worktree:

```
Spawn @<agent> for Task <ID>:
"<task description>

Work in worktree: <path>
Spec: <spec path>
Plan: <plan path>

When done, mark your task completed via TaskUpdate."
```

### Monitoring loop

After spawning, enter a monitoring cycle:

1. Check TaskList periodically for progress
2. When an agent completes a task, check if blocked tasks are now unblocked → spawn next agents
3. Surface blockers or errors to user immediately

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

If Linear is available, update issue status and link the PR.

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

- **No git repo**: warn; skip worktree, work in current directory
- **Linear MCP unavailable**: fall back to prompted context; use plans for tracking instead
- **Agent fails to start**: retry once, then report to user with error details
- **Worktree already exists for this issue**: ask user — reuse or remove and recreate?
- **Branch already exists**: check if it has unmerged work; ask user before resetting
- **All agents stuck**: don't panic — present the full state to user and ask for direction
- **User goes AFK mid-flow**: pause gracefully; state is in tasks + plan file; resumable
