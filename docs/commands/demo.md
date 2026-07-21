# /demo

Live, interactive demo of the dev-team workflow. Scaffolds a tiny Go project in a temp worktree, injects a ticket, and runs real agents against it. Cleans up after.

The demo is a **teaching pass for the core pipeline** (scope → plan → implement →
QA), not an exhaustive tour of every plugin feature. After the demo, point users
at [CHANGELOG](../../CHANGELOG.md) and [Setup → Upgrading](../setup.md#upgrading-the-plugin-existing-projects)
for glossary, grill mode, code-simplify, SAST companions, etc.

## Usage

```
/demo
/demo orchestrate
/demo kickoff
/demo specs
```

## Modes

| Mode | What it does | Duration |
|------|-------------|----------|
| `orchestrate` (default) | Full pipeline: scope → plan → implement → (optional polish) → QA → PR-ready diff | 3-5 min |
| `kickoff` | Planning only: PM + Tech Lead → spec + task graph | 1-2 min |
| `specs` | Spec generation: reads code → writes spec → validates against code | 1-2 min |

## Prerequisites

- `/init-team` completed
- `/init-orchestration` completed (for `orchestrate` mode)

## What Gets Created

A throwaway micro-project (`demo-todo` — a CLI todo app in Go) on a temp branch. The demo ticket asks agents to add CSV export — a clear, bounded feature.

The demo worktree lives in `$TMPDIR/demo-project` and is cleaned up at the end (with your confirmation).

## Examples

**Full orchestrate demo:**
```
/demo
```

You'll see each gate in action — scope confirmation, open questions, plan approval, agent dispatch, QA validation, and final diff. Approve at each gate or type "skip" to auto-approve.

**Planning-only demo:**
```
/demo kickoff
```

PM reviews the ticket, Tech Lead writes a spec and produces a task graph. No code is written.

**Specs demo:**
```
/demo specs
```

Tech Lead reads the existing code and writes behavioral specs from what the code does, then validates them.

## See Also

- [Orchestrated Runbook](../runbooks/orchestrate.md) — the workflow the demo showcases
- [Manual Runbook](../runbooks/manual.md) — same flow, manual agent dispatch
- [Onboarding Runbook](../runbooks/onboarding.md) — first-time project setup
