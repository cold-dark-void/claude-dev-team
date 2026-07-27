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
/setup team
```

What happens:
- Scans your codebase, CI config, and infrastructure
- Downloads embedding extensions (~29MB) for semantic memory search
- Writes initial memory (cortex) for all 7 agents
- Creates `.claude/memory/memory.db`

Safe to re-run anytime.

**On restricted networks:**
```
/setup team --no-extensions    # keyword search only, no download
```

Or use remote embeddings (see [Setup Guide](../setup.md#remote-embeddings)).

### Verify

```
/memory search --status
```

You should see all agents with initial memory entries.

---

## Step 2 — Enable Agent Teams

```
/setup orchestration
```

What happens:
- Enables `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` in project settings
- Wires the `TaskCompleted` quality-gate hook
- Creates/updates `AGENTS.md` with team coordination rules

Without this step, you can use agents individually (`@pm`, `@tech-lead`) but not
`/orchestrate` or task-based coordination.

---

## Step 2b — Domain glossary (optional, zero deps)

Projects may keep a committed **ubiquitous language** file at repo-root `CONTEXT.md`
(or `docs/domain/CONTEXT.md`). `/setup project` seeds an empty template;
`/brainstorm` and `/kickoff` load it and merge user-confirmed terms.

This is **not** agent memory (not SQLite). It is shared vocabulary so agents stop
reintroducing avoided aliases. Protocol: plugin skill `domain-glossary`. Absent
file is fine until the first real term crystallizes.

---

## Step 2c — Optional structural map (Graphify companion)

If you want a **code knowledge graph** (call/import structure, god-nodes), install
[Graphify](https://github.com/Graphify-Labs/graphify) separately — not part of
dev-team:

```bash
uv tool install graphifyy
graphify install
# then in Claude Code / your agent:
/graphify .
```

Agent memory (SQLite) is episodic/semantic; Graphify is structural. Use both
when monorepos make “who calls what” expensive to rediscover. Optional for
`/review-and-commit --impact` when `graphify` is on PATH. Full companion list:
[Setup → optional tools](../setup.md#optional-companion-tools-not-dependencies).

**Upgrading an existing project?** See
[Setup → Upgrading](../setup.md#upgrading-the-plugin-existing-projects) — v0.71–v0.77
need no migration; update the plugin (and re-run `install.sh` for opencode).

---

## Step 3 — Establish spec baseline

**New project (no existing code):** Skip this step. Create specs as you build features
using `/spec create` (see [Specs Runbook](specs.md)).

**Existing project (has code, no specs):**

```
/spec generate
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
/spec list                    # should show your specs (if any)
/memory search --status        # should show agents with memory
/memory distill --status       # should show tier counts
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
