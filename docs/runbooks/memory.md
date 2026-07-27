# Runbook: Working with Memory

Agent memory is what makes the dev-team get smarter over time. Each agent accumulates
knowledge about your project — architecture decisions, past mistakes, domain expertise —
and recalls it in future sessions.

This runbook covers: how memory works, searching it, and keeping it healthy.

For initial setup, see [Setup Guide](../setup.md).
For project onboarding (including memory bootstrap), see [Onboarding Runbook](onboarding.md).

---

## How Memory Works

### Storage

Memory lives in a SQLite database at `.claude/memory/memory.db` (shared across git worktrees).
If `sqlite3` is unavailable, agents fall back to `.md` files at `.claude/memory/<agent>/`.

Each memory entry has an **agent** (who wrote it), a **type** (cortex, memory, lessons), and a **tier**.

### Related: domain glossary (not memory)

`CONTEXT.md` (or `docs/domain/CONTEXT.md`) is a **committed domain glossary** —
project ubiquitous language updated by `/brainstorm` / `/kickoff` when terms
crystallize. Agents load it for naming; it is not stored in `memory.db` and has
no tiers. See plugin skill `domain-glossary` and the [Onboarding runbook](onboarding.md).

### Related: prose compress (still memory)

Optional fact-dense rewrite of verbose tier-0 notes before distillation:
`/memory distill --compress` or `MEMORY_COMPRESS=1` (`skills/memory-compress`).
Does not promote tiers — only shortens prose while keeping technical facts.


### Tiers

| Tier | Name | What it contains | Created by |
|------|------|-----------------|------------|
| 0 | Raw | Individual observations from agent work sessions | Agents, automatically |
| 1 | Digest | LLM-compressed summaries of raw memories | `/memory distill` |
| 2 | Core | High-signal knowledge promoted from digests — permanent | `/memory distill` |
| — | Archived | Consumed tier-0 rows, excluded from queries, always recoverable | `/memory distill` |

When agents start a session, they load memory top-down: core (tier 2) first, then digests (tier 1).
If no distilled content exists yet, they load all raw (tier 0) memories — backward compatible.

### Why distillation matters

Without distillation, raw memories accumulate indefinitely. Agents load all of them on session start,
consuming context window. After 50+ raw memories per agent, you'll notice slower agent startup and
noisier recall. Distillation compresses 50 raw observations into 2-3 digests, and promotes the most
important patterns to permanent core knowledge.

---

## Quick Reference

| Task | Command |
|------|---------|
| Search all agent memories | `/memory search <query>` |
| Search memories + sessions + specs + git | `/recall <topic>` |
| Check memory DB status and counts | `/memory search --status` |
| Check tier counts per agent | `/memory distill --status` |
| Compress raw memories into digests | `/memory distill` |
| Distill a specific agent | `/memory distill --agent pm` |
| View distillation config | `/memory config list` |
| Change distillation settings | `/memory config set <key> <value>` |
| Clear a stale distillation lock | `/memory distill --force` |

---

## Searching Memory

### By topic across memories only

```
/memory search authentication token
```

Uses the best available method automatically:
- **Semantic search** (if vector extensions loaded) — embeds query, finds closest matches by cosine similarity
- **Keyword search** (if DB exists but no embeddings) — SQL LIKE matching
- **Grep fallback** (no DB) — searches `.md` files

Results are sorted by tier (core first) then relevance. Archived memories are excluded.

### By topic across everything

```
/recall authentication
```

Searches agent memory + plan files + specs + backlog + git log + conversation history.
Returns `claude --resume` commands for matching sessions. Use this when you want the full
picture of prior work on a topic, not just what agents remember.

### Check what's in the DB

```
/memory search --status
```

Shows: DB path, embedding mode, total memories, per-agent breakdown by tier.

---

## Distillation

### When to distill

- After wrapping a ticket (`/wrap-ticket` is a natural trigger)
- When `/memory distill --status` shows high raw counts (50+ per agent)
- Before a release (clean memory = better agent performance next cycle)
- If `distill_mode` is set to `suggest`, agents will remind you

### Running distillation

```
/memory distill --status          # check counts first
/memory distill                   # distill all agents over threshold
/memory distill --agent tech-lead # distill one agent regardless of threshold
```

What happens:
1. Reads tier-0 (raw) memories, batches oldest-first
2. Spawns `@distiller` agent (using configured model, default Haiku) to compress each batch
3. Writes tier-1 digest entries
4. Evaluates each digest for promotion to tier-2 core
5. Archives consumed tier-0 rows (not deleted — always recoverable)

### Configuration

```
/memory config list               # view current settings
```

| Key | Values | Default | What it controls |
|-----|--------|---------|-----------------|
| `distill_enabled` | true/false | false | Master switch for automatic triggers |
| `distill_mode` | manual/suggest/auto | suggest | When distillation runs |
| `distill_threshold` | 1–9999 | 50 | Raw count per agent before trigger |
| `distill_model` | model name | haiku | LLM for compression |

**Recommended setup:**

```
/memory config set distill_enabled true
/memory config set distill_mode suggest
/memory config set distill_threshold 30
```

This gives you a nudge when memory is getting noisy, without running automatically.

For high-velocity projects (multiple tickets/day), consider:

```
/memory config set distill_mode auto
/memory config set distill_threshold 25
```

---

## Search Modes

The quality of memory search depends on your embedding configuration:

| Mode | How it works | Quality | Setup |
|------|-------------|---------|-------|
| `remote` | Calls external embedding API | Best | Set `EMBEDDING_URL` env var |
| `lembed` | Local GGUF model (all-MiniLM-L6-v2) | Good | Default after `/setup team` |
| `fallback` | SQL keyword matching or grep | Basic | Automatic if no extensions |

To switch to remote embeddings:

```bash
export EMBEDDING_URL=https://api.openai.com/v1/embeddings
export EMBEDDING_API_KEY=sk-...
export EMBEDDING_MODEL=text-embedding-3-small
/setup team --refresh
```

Any OpenAI-compatible endpoint works (OpenAI, Azure, ollama, etc.).

---

## Memory Hygiene Checklist

Run periodically (e.g., after every 2-3 tickets or before a release):

1. **Check status** — `/memory distill --status`
2. **Distill if needed** — `/memory distill` for agents over threshold
3. **Spot-check quality** — `/memory search <recent feature>` to verify agents retained the right knowledge
4. **Review core** — tier-2 core memories are permanent; make sure they're still accurate

### Troubleshooting

**Stale lock error:**
```
/memory distill --force
```
Clears a lock left by a crashed distillation run.

**Agent loading too much/wrong context:**
Check what they're loading: `/memory distill --status`. If raw count is high, distill.
If core memories are outdated, they can't be edited through commands — update the DB directly
or delete and re-bootstrap with `/setup team`.

**No DB found:**
Run `/setup team` to create it. Agents work with `.md` fallback but lose semantic search.

---

## See Also

- [Onboarding Runbook](onboarding.md) — initial memory bootstrap for a new project
- [Setup Guide](../setup.md) — installation, embedding config, troubleshooting
- [Idea to Plan](idea-to-plan.md) — agents use memory during planning
- [Orchestrated Runbook](orchestrate.md) — agents use memory during implementation
