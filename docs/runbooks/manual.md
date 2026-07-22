# Runbook: Idea to PR (Manual)

Full-control workflow — you dispatch each agent and drive every phase yourself.

> **Prefer the simpler path?** Most tickets should use [`/orchestrate`](orchestrate.md),
> which automates this entire workflow. This manual runbook is for when you want full control
> over agent dispatch and task management.

Prerequisites: see [Setup Guide](../setup.md)

---

## Phase 1 — Ticket Intake

### 1.1 Read the ticket

Collect: ticket ID, title/description, acceptance criteria, linked designs and dependencies.

### 1.2 Orient yourself

```bash
git checkout main && git pull
cat .claude/memory/claude/memory.md
cat .claude/memory/tech-lead/cortex.md   # architecture decisions
cat .claude/memory/pm/cortex.md          # product context
```

### 1.3 Check existing specs

```bash
ls specs/
```

Read any specs covering the area this ticket touches — they constrain your design.
If no `specs/` directory exists, run `/spec generate` first (see [Setup Guide](../setup.md)).

### 1.4 Create a worktree

Create the worktree **before** planning — `/kickoff` writes the plan into the current working tree.

```bash
WT=$(bash skills/worktree-lib.sh ensure ENG-123-short-description)
cd "$WT"
```

This creates branch `feat/ENG-123-short-description` and the worktree at
`$MROOT/.worktrees/ENG-123-short-description`, printing its path on stdout
(see [Worktree Protocol](../../AGENTS.md#worktree-protocol) / `specs/core/SPEC-016-worktree-isolation.md`).

---

## Phase 2 — Planning

Fastest path — collapses steps 2.1–2.5 into one command:

```
/kickoff ENG-123 "<paste ticket text>"
```

Skip to Phase 3 when done.

### Manual path

**2.1 Parallel kickoff:**
```
@pm Review ENG-123: <ticket>. Confirm ACs, flag ambiguities. SendMessage @tech-lead when done.
@tech-lead Orient on ENG-123 in parallel. Read cortex.md + relevant specs. Wait for @pm's ACs.
```

**2.2 Plan and task graph:**
```
@tech-lead Plan ENG-123. Save to .claude/plans/YYYY-MM-DD-ENG-123.md.
Output task graph with parallel/sequential relationships and recommended agent per step.
```

**2.3 Write or update specs (spec-first):**

Before writing code, specs for the affected area must exist and be current.
```
@tech-lead Review specs/<relevant>.md against ENG-123. Update if needed.
# OR: write a new spec if none exists
/spec tests SPEC-NNN   # optional: make requirements executable
git add specs/ && git commit -m "spec: ENG-123 — add/update <area> spec"
```

**2.4 Sanity-check the plan** — scope bounded? migrations? new dependencies? spec conflicts?

**2.5 Tech Lead creates the task graph:**
```
@tech-lead Create tasks for ENG-123. TaskCreate for each step with dependencies.
```

---

## Phase 3 — Implementation

### 3.1 IC agents claim and work in parallel

```
@ic4 Check TaskList for ENG-123. Claim first ready task via TaskUpdate. TDD — tests first.
     When done: TaskUpdate status=completed, SendMessage @tech-lead.

@ic5 Check TaskList for ENG-123. Claim your task via TaskUpdate. Design interface first.
     SendMessage interface definition to downstream agents early (don't make them wait).
     When done: TaskUpdate status=completed, SendMessage @tech-lead.

@qa  Check TaskList. Claim acceptance-test task. Write tests for all ACs now — don't wait
     for wiring to finish. When done: TaskUpdate status=completed.
```

### 3.2 Monitor and unblock

```
/status standup ENG-123
```

When resuming: `cat .claude/memory/ic4/context.md` (etc.) to reload agent context.

---

## Phase 4 — Quality Gate

### 4.1 QA final validation

```
@qa All ENG-123 implementation done. Run full validation:
- Execute the acceptance test suite
- Run go test ./... for regressions
- Check each AC against the spec
- Flag anything that doesn't pass
```

Fix all issues before proceeding.

### 4.2 Spec alignment check

```
/spec reflect --phase 4
```

Fix anything marked MISSING or DIFFERS. If implementation intentionally diverges, update the spec.

### 4.3 Review and commit

```
/review-and-commit
```

Address all critical/high findings.

### 4.4 Commit

```bash
git add <files>
git commit -m "feat: ENG-123 — <short description>

<1-2 sentence summary>

Co-Authored-By: Claude <model> <noreply@anthropic.com>"
```

---

## Phase 5 — Pull Request

```bash
git push -u origin feat/ENG-123-short-description

gh pr create \
  --title "feat: ENG-123 — <short description>" \
  --body "$(cat <<'EOF'
## Linear ticket
ENG-123: <title>

## What changed
- <bullet>

## Acceptance criteria
- [ ] <criterion 1>

## Test plan
- [ ] Unit tests pass
- [ ] Integration tests pass
- [ ] Manual smoke test on staging
EOF
)"
```

In Linear: attach the PR URL, move ticket to **In Review**.

---

## Phase 6 — Review & Merge

For each review comment: fix it or explain why not. Re-run `/review-and-commit` after significant changes.

Once approved and CI green:
```bash
gh pr merge --squash --delete-branch
```

Move Linear ticket to **Done**.

---

## Phase 7 — Production Delivery

### 7.1 Post-merge verification

```bash
git checkout main && git pull
git log --oneline | head -5
```

### 7.2 Deploy

```bash
# Auto-deploy: monitor CI/CD pipeline
# Manual deploy: adapt to your tooling
./scripts/deploy.sh production
# Release tag:
/release patch   # or minor/major
```

### 7.3 Smoke test

Verify ACs in prod. Check monitoring/dashboards and logs for error spikes.

### 7.4 Consult DevOps if anything looks wrong

```
@devops Deployment for ENG-123 is live. Here are the logs: <paste>. Anything to worry about?
```

---

## Post-ship: Memory Hygiene

See [memory configuration](../setup.md#memory-configuration-memory-config) for distillation settings.

```bash
/memory distill --status   # check raw memory count
/memory distill            # compress raw memories into tier-1 digests
/memory config list        # verify settings
```

---

## Phase 8 — Wrap-up

Fastest path:
```
/wrap-ticket ENG-123
```

Handles: task verification, learnings capture, plans.md update, source tracker re-close (`close.sh`), deferred backlog adds, worktree removal, Linear checklist.

### Manual path

```bash
# 8.1 Clean up worktree
bash skills/worktree-lib.sh release ENG-123-short-description

# 8.2 Spec reflection (periodic — before minor/major bumps)
/spec reflect

# 8.3 Update project memory
echo "\n## ENG-123 learnings\n<insight>" >> .claude/memory/claude/memory.md
```

**8.4 Close out:** Linear ticket → Done/Released, notify stakeholders, update affected docs.

---

## Quick Reference

| Phase | Skill shortcut | Manual equivalent |
|-------|----------------|-------------------|
| Baseline specs (legacy, once) | `/spec generate` | Read code → write specs manually |
| Tests from specs | `/spec tests` | Write tests manually from MUST requirements |
| Bootstrap (once) | `/setup orchestration` | — |
| Intake + planning | **`/kickoff ENG-123 "..."`** | `@pm` + `@tech-lead` parallel → spec → plan → `TaskCreate` |
| Monitor progress | **`/status standup ENG-123`** | `TaskList` + read agent `context.md` files |
| Implement (parallel) | — | IC4 + IC5 `TaskUpdate` to claim; IC5 `SendMessage` interface early |
| QA final validate | — | `@qa Run full validation, TaskUpdate completed` |
| Spec alignment | `/spec reflect --phase 4` | — |
| Review | `/review-and-commit` | — |
| PR | — | `gh pr create` |
| Release | `/release patch` | — |
| Wrap-up | **`/wrap-ticket ENG-123`** | Verify tasks → memory → plans.md → worktree remove |
| Full health check | `/spec reflect` (periodic) | — |

---

## Worked Example

For a full worked example (POC-123 — Batch Export Descriptions) showing the same ticket
implemented via both orchestrated and manual paths, see the
[orchestrated runbook](orchestrate.md#worked-example-poc-123--batch-export-descriptions).

The manual path requires ~16 user interactions vs 5 with `/orchestrate` — same PR either way.

---

## Escalation

| Situation | Action |
|-----------|--------|
| Scope unclear | Ping PM; do not guess |
| Architecture uncertain | `@tech-lead` before writing code |
| CI failing unexpectedly | `@devops` with logs |
| Tests failing you can't explain | `@ic5` to debug |
| Prod incident post-deploy | Roll back first, investigate second |

---

## See Also

- [Project Onboarding](onboarding.md) — day-one setup for a new project
- [Working with Specs](specs.md) — creating, updating, and validating specs
- [Working with Memory](memory.md) — memory tiers, search, distillation
- [Idea to Plan](idea-to-plan.md) — brainstorm → spec → Linear tickets (upstream of this)
- [Orchestrated Runbook](orchestrate.md) — recommended path, fewer interactions
- [`/kickoff` command reference](../commands/kickoff.md) — planning phase only
- [`/orchestrate` command reference](../commands/orchestrate.md) — full lifecycle
