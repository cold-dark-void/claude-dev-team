# Runbook: Idea to PR (Orchestrated)

The recommended path. Run `/orchestrate`, approve at gates, get a PR.

For full-control manual agent dispatch, see [Manual Runbook](manual.md).
For prerequisites and setup, see [Setup Guide](../setup.md).

---

## Quick Start

```
/orchestrate CDV-42
```

That's it. The orchestrator fetches the issue, plans, implements, reviews, and opens a PR.

If you don't have a Linear ticket yet:

```
/orchestrate
```

You'll be prompted to paste the title, description, and acceptance criteria directly.

For complex or ambiguous ideas, run [`/brainstorm`](idea-to-plan.md) first.

---

## Gates Overview

`/orchestrate` runs autonomously but pauses at gates for your input. Between gates, agents work without interrupting you.

| # | Gate | What agents did | What you do |
|---|------|----------------|-------------|
| 1 | **Scope** | PM + Tech Lead assess the issue, present summary + complexity estimate | Confirm scope or adjust |
| 2 | **Open questions** | PM surfaces ambiguities from the ticket | Answer questions (skipped if ACs are clear) |
| 3 | **Plan approval** | Tech Lead writes/updates spec, produces implementation plan + task graph | Approve plan or redirect |
| 4 | *(agents work)* | ICs implement tasks in parallel in a worktree; Tech Lead reviews each | Nothing — you're notified only on escalation |
| 5 | **QA results** | QA validates against spec and acceptance criteria | Review findings if any remain |
| 6 | **Ship** | Diff summary + PR draft presented | Approve PR creation |

Typical flow: you interact at gates 1, 3, and 6. Gates 2, 4, and 5 often pass without needing you.

---

## Worked Example: POC-123 — Batch Export Descriptions

**Context**: `project` is a Go desktop app that uses a local Ollama LLM to generate descriptions
for images. This ticket adds CSV/JSON/Markdown export of cached descriptions.

### Gate 1 — Scope confirmation

```
> /orchestrate POC-123 "Batch Export Descriptions. As a user, I want to export all analyzed
  image descriptions to a file (CSV, JSON, or Markdown).
  AC1: Export all completed analyses from current folder
  AC2: Each entry includes: file path, model, prompt, description, timestamp
  AC3: User chooses format and output path via a dialog
  AC4: Export is available from the File menu"
```

```
  Issue: POC-123 — Batch Export Descriptions
  Priority: Medium

  My assessment:
  - Complexity: moderate
  - Estimated agents needed: ic4 (cache layer, UI), ic5 (export package), qa
  - Likely affected areas: internal/cache, internal/ui/fyne, new internal/export package

  Proceed with this scope? Any adjustments?
```

```
> Looks good. Proceed.
```

### Gate 2 — Open questions

```
  PM flagged 2 questions before planning can proceed:

  1. "Current folder" — the folder currently open in the file browser, or a user-specified path?
  2. "Each entry includes timestamp" — the export timestamp, or the original analysis timestamp?

  Please clarify:
```

```
> 1. Current folder open in file browser only.
> 2. Export timestamp (when the export was created).
```

### Gate 3 — Plan approval

This is the most important gate — you're approving the spec and task breakdown.

```
  Worktree created: ../project-POC-123 (branch feat/POC-123-batch-export)

  Spec: specs/core/SPEC-026-batch-export.md [created]
  Plan: .claude/plans/2026-03-07-POC-123-batch-export.md

  Task graph:
    id:1  Task 1 — Cache layer (GetAllForFolder)       → ic4   [ready]
    id:2  Task 2 — Export package (CSV/JSON/Markdown)  → ic5   [ready]
    id:3  Task 3 — UI wiring (File menu + dialog)      → ic4   [blocked by 1, 2]
    id:4  Task 4 — Acceptance tests                    → qa    [starts after interface defined]

  Tasks 1+2 run in parallel. Task 3 starts when both complete.
  QA starts writing tests as soon as IC5 defines the Exporter interface.

  Approve this plan?
```

```
> Approved.
```

### Agents work (no interaction needed)

```
  Dispatching ic4 → Task 1 (cache layer)
  Dispatching ic5 → Task 2 (export package)

  ...

  ic5: Exporter interface defined → SendMessage to qa
  Dispatching qa → Task 4 (acceptance tests)

  ic4: Task 1 completed (GetAllForFolder + 3 tests green)
  ic5: Task 2 completed (3 exporters + 6 tests green)

  Tasks 1+2 done → unblocking Task 3
  Dispatching ic4 → Task 3 (UI wiring)

  Tech Lead reviewing Task 1... approved
  Tech Lead reviewing Task 2... approved

  ic4: Task 3 completed (File menu + export dialog)
  Tech Lead reviewing Task 3... approved

  qa: Task 4 completed (7 acceptance tests)

  All tasks completed. Running QA final validation...
```

### QA findings (auto-resolved)

QA found 2 spec violations. The orchestrator routed fixes automatically — no input needed.

```
  QA final validation:
  AC1 ✅  AC2 ✅  AC3 ✅  AC4 ✅

  2 issues found:
  ⚠️  Markdown footer missing 'model' field (SPEC-026 violation)
  ⚠️  MUST NOT overwrite without confirmation — not implemented

  Routing fixes to ic4...

  ic4: Both issues fixed (2 commits)
  Tech Lead: Re-review approved
  QA: Re-validation passed — all clear
```

### Gate 6 — Ship

```
  All tasks complete. QA approved. Spec alignment: 8/8 MATCH.

  Branch: feat/POC-123-batch-export
  Commits: 5 (spec + 4 implementation)
  Files changed: 8
  Lines: +342 / -0

  Ready to create PR?
```

```
> Yes.
```

```
  PR created: https://github.com/org/project/pull/87

  Suggested next steps:
  - Move POC-123 to In Review in Linear
  - After merge: /wrap-ticket POC-123
```

**Total user interactions: 5.** Same PR that the [manual runbook](manual.md) produces in 16 steps.

---

## Escalation Triggers

The orchestrator interrupts you mid-flow when:

- An agent is stuck after 2 genuine attempts
- Scope creep is discovered (work not in the plan)
- An ambiguous requirement can't be resolved from the spec
- A breaking change is found (schema migration, API contract, dependency bump)
- IC and Tech Lead cycle 3+ review rounds without consensus

Routine issues (test failures, lint, formatting, implementation choices within spec) are handled by agents without interrupting you.

---

## Change Discipline

- One ticket = one branch = one PR. Never bundle multiple tickets.
- Soft cap: ~1,000 LOC of real code per PR. Hard cap: 2,000 LOC total. PRs over limit must be split.
- Refactoring is always a separate PR — never mixed with feature work.
- Discovered out-of-scope work goes to a new ticket, not the current PR.
- Material changes to the approach trigger a replan gate: all IC work pauses, Tech Lead replans, you approve before resuming.

---

## After the PR

```
/wrap-ticket CDV-42
```

Handles: task verification, learnings capture, plans.md update, backlog items, worktree removal, Linear checklist.

For memory hygiene, see [Memory Configuration](../setup.md#memory-configuration----memory-config).

---

## When to Use Manual Mode Instead

Use the [manual runbook](manual.md) when you want to:

- Drive each agent directly (learning the system, debugging agent behavior)
- Cherry-pick which agents work on which tasks
- Skip certain phases or run them out of order
- Work on something that doesn't fit the ticket → spec → implement → PR pattern

---

## See Also

- [Project Onboarding](onboarding.md) — day-one setup for a new project
- [Working with Specs](specs.md) — creating, updating, and validating specs
- [Working with Memory](memory.md) — memory tiers, search, distillation
- [Idea to Plan](idea-to-plan.md) — brainstorm → spec → Linear tickets (upstream of this)
- [Manual Runbook](manual.md) — full-control agent dispatch
- [`/orchestrate` command reference](../commands/orchestrate.md)
- [`/kickoff` command reference](../commands/kickoff.md) — planning only, no implementation
