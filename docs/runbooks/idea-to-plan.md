# Runbook: Idea to Plan

Turn a vague idea or feature request into a structured spec, implementation plan, and Linear tickets — ready to hand off to [`/orchestrate`](orchestrate.md) or [manual implementation](manual.md).

For prerequisites, see [Onboarding](onboarding.md). Linear MCP is optional (for automatic ticket creation).

---

## Quick Start

If the idea is clear enough to plan immediately:

```
/kickoff
```

If the idea is vague or complex — brainstorm first:

```
/brainstorm
# high-stakes design: one question at a time + recommended answers
/brainstorm --grill multi-tenant auth session model
```

Then when requirements are solid:

```
/kickoff
```

Confirmed domain terms may land in repo-root **`CONTEXT.md`** (ubiquitous language —
not agent memory). Prefer those names in later specs and tickets.

---

## The Flow

### Step 1 — Clarify the idea (`/brainstorm`)

```
/brainstorm real-time collaboration on shared documents
```

**Default mode** — four rounds of batched Socratic questions (3–5 at a time):
- **Core intent** — what problem, who has it, why now
- **Scope and constraints** — what's in, what's out, hard limits
- **Edge cases** — failure modes, concurrency, integration points
- **Alternatives** — simpler options, minimum viable version

**Grill mode** (`--grill`) — one question at a time, each with a recommended answer;
walks the same design tree; reads the codebase when it can answer without asking you.

Output: a structured synthesis saved to `.claude/plans/<date>-brainstorm-<slug>.md`,
plus optional `CONTEXT.md` glossary updates for user-confirmed terms.

```
  ## Problem Statement
  Teams editing the same document lose each other's changes when saves collide.

  ## Success Criteria
  - Two users editing simultaneously see each other's cursors within 500ms
  - No data loss on concurrent edits

  ## Scope
  IN:  text edits, cursor positions, presence indicators
  OUT: file attachments, comments, version history

  ## Key Risks
  - Conflict resolution — mitigation: CRDT
  - WebSocket state on mobile — mitigation: graceful reconnect
```

### Step 2 — Plan and spec (`/kickoff`)

Takes the brainstorm output (or raw ticket text) and produces a spec + task graph.

```
/kickoff ENG-456 "Real-time collaboration on shared documents.
  AC1: Two users see each other's cursors within 500ms.
  AC2: No data loss on concurrent edits.
  AC3: Presence indicators visible in document header."
```

Three agents run in parallel:
- **PM** — confirms ACs, flags ambiguities, gates on open questions
- **Tech Lead** — orients on codebase, identifies affected areas
- **Codebase explorer** — finds entry points, patterns, dependencies

Output:

```
  Kickoff complete for ENG-456

  Spec:   specs/core/SPEC-031-realtime-collab.md [created]
  Plan:   .claude/plans/2026-03-15-ENG-456-realtime-collab.md

  Task Graph:
    id:1  Task 1 — CRDT engine              → ic5   [ready]
    id:2  Task 2 — WebSocket transport       → ic5   [ready]
    id:3  Task 3 — Presence UI               → ic4   [blocked by 2]
    id:4  Task 4 — Cursor sync               → ic4   [blocked by 1, 2]
    id:5  Task 5 — Acceptance tests          → qa    [blocked by 3, 4]
```

The spec is committed before any implementation planning begins.

### Step 3 — Create Linear tickets

Ask Claude to create Linear issues from the task graph:

```
> Create Linear issues from the kickoff output. Use project "COLLAB", label "realtime".
  One issue per task, include the spec requirements as acceptance criteria.
```

```
  Created 5 Linear issues:
  COLLAB-31  Task 1 — CRDT engine             [Todo]
  COLLAB-32  Task 2 — WebSocket transport      [Todo]
  COLLAB-33  Task 3 — Presence UI              [Todo, blocked by COLLAB-32]
  COLLAB-34  Task 4 — Cursor sync              [Todo, blocked by COLLAB-31, COLLAB-32]
  COLLAB-35  Task 5 — Acceptance tests         [Todo, blocked by COLLAB-33, COLLAB-34]

  All linked to parent: COLLAB-30 (ENG-456)
```

### What's Next

From here, pick your implementation path:

| Path | Command | When to use |
|------|---------|-------------|
| **Orchestrated** | `/orchestrate COLLAB-31` | Let agents handle it end-to-end |
| **Manual** | Follow [manual runbook](manual.md) | You want full control |
| **Defer** | Leave tickets in backlog | Not ready to implement yet |

For large features with multiple tasks, you can `/orchestrate` each task independently —
they already have specs and acceptance criteria baked in.

---

## Worked Example

For a full worked example (POC-123 — Batch Export Descriptions) showing the kickoff
and implementation flow, see the
[orchestrated runbook](orchestrate.md#worked-example-poc-123--batch-export-descriptions).

---

## See Also

- [Project Onboarding](onboarding.md) — day-one setup for a new project
- [Working with Specs](specs.md) — creating, updating, and validating specs
- [Working with Memory](memory.md) — memory tiers, search, distillation
- [Orchestrated Runbook](orchestrate.md) — idea → PR in one command
- [Manual Runbook](manual.md) — idea → PR with full control
- [`/brainstorm` command reference](../commands/brainstorm.md)
- [`/kickoff` command reference](../commands/kickoff.md)
