# Runbook: Project Onboarding

Day-one setup for a new project. Goes from "I just cloned this repo" to "agents are ready
to take tickets."

For detailed command reference, see [Setup Guide](../setup.md).

---

## Prerequisites

- **Claude Code** 2.x+ installed
- **`sqlite3`** available (`apt install sqlite3` / `brew install sqlite3`)
- **Git** repository (agents use worktree-aware paths)
- **Plugin installed:**
  ```bash
  /plugin marketplace add cold-dark-void/claude-dev-team
  /plugin install dev-team
  ```

---

## Step 1 — Bootstrap agent memory

```
/init-team
```

What happens:
- Scans your codebase, CI config, and infrastructure
- Downloads embedding extensions (~29MB) for semantic memory search
- Writes initial memory (cortex) for all 7 agents
- Creates `.claude/memory/memory.db`

Safe to re-run anytime.

**On restricted networks:**
```
/init-team --no-extensions    # keyword search only, no download
```

Or use remote embeddings (see [Setup Guide](../setup.md#remote-embeddings)).

### Verify

```
/memory-search --status
```

You should see all agents with initial memory entries.

---

## Step 2 — Enable Agent Teams

```
/init-orchestration
```

What happens:
- Enables `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` in project settings
- Wires the `TaskCompleted` quality-gate hook
- Creates/updates `AGENTS.md` with team coordination rules

Without this step, you can use agents individually (`@pm`, `@tech-lead`) but not
`/orchestrate` or task-based coordination.

---

## Step 3 — Establish spec baseline

**New project (no existing code):** Skip this step. Create specs as you build features
using `/create-spec` (see [Specs Runbook](specs.md)).

**Existing project (has code, no specs):**

```
/generate-specs
```

This reads your codebase and writes behavioral specs from what the code actually does.
See [Specs Runbook — Starting from Zero](specs.md#starting-from-zero-legacy-project) for
the review-and-commit steps after it runs.

---

## Step 4 — Configure memory distillation

Optional but recommended. See [Memory Runbook — Configuration](memory.md#configuration)
for recommended settings and what each option controls.

---

## Step 5 — Verify everything works

Run a quick smoke test:

```
/list-specs                    # should show your specs (if any)
/memory-search --status        # should show agents with memory
/memory-distill --status       # should show tier counts
```

Try a dry run with a small task:

```
/brainstorm <some small feature idea>
```

If agents respond with project-aware context (mentioning your actual code, architecture,
existing specs), onboarding worked.

---

## What's Next

| Goal | Runbook |
|------|---------|
| Start working on an idea | [Idea to Plan](idea-to-plan.md) |
| Implement a ticket (autopilot) | [Orchestrated](orchestrate.md) |
| Implement a ticket (full control) | [Manual](manual.md) |
| Learn the spec system | [Working with Specs](specs.md) |
| Understand agent memory | [Working with Memory](memory.md) |

---

## See Also

- [Setup Guide](../setup.md) — detailed command reference and troubleshooting
- [Working with Memory](memory.md) — memory tiers, search, distillation
- [Working with Specs](specs.md) — creating and maintaining specs
