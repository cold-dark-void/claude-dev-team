# /recall

Search all prior work by topic across sessions, memory, specs, plans, and git history. Returns `claude --resume` commands for matching sessions so you can instantly pick up where you left off.

## Usage

```
/recall [topic]
```

## Flags

| Flag / Argument | Description |
|-----------------|-------------|
| `topic` | Any keyword, ticket ID, feature name, or free-text phrase to search for |

## Examples

**Search by ticket ID:**
```
/recall MEM-002
```
Output (abbreviated):
```
═══ RECALL: MEM-002 ═══════════════════════════════════
SESSIONS (sorted by most recent):
  abc123... | 2026-03-14 | claude-dev-team | 4 prompts
    > "implement tiered memory distillation"
    Resume: claude --resume abc123...

SPECS:
  MEM-002 — Tiered Memory Distillation

COMMITS:
  9a1b2c feat: MEM-002 — add distillation pipeline (2026-03-14)
═══════════════════════════════════════════════════════
```

**Search by feature name:**
```
/recall embedding
```

**Search for plain-language concept:**
```
/recall "cache invalidation"
```
Output includes sessions matching expanded related terms like "cache layer", "invalidation strategy", and "stale cache" — even when those exact words were not in the original query.

## How It Works

`/recall` executes a two-phase search designed to surface work that predates formal ticket identifiers.

**Phase 1 — Structured sources (parallel):** Simultaneously searches agent memory (SQLite DB or `.md` fallback), plan files under `.claude/plans/`, spec files under `specs/`, backlog items, and the current repo's git log. Results are ranked by recency.

**Phase 2 — Keyword expansion then session search:** From the Phase 1 results, `/recall` extracts up to 8 related terms — distinctive noun phrases and technical terms used to describe the same concept in plain language. If Phase 1 returned nothing, the query itself is decomposed (split on hyphens/underscores, numeric affixes stripped). All terms are combined into a single pattern and `~/.claude/history.jsonl` is scanned in one pass for matching conversation sessions. Sessions that match only an expanded term are tagged `(related: "<term>")` so you know why they appeared.

The output groups findings by type (Sessions, Agent Memory, Specs, Plans, Commits, Backlog), orders each group newest-first, and caps results per section to avoid noise (10 sessions, 5 memory matches, 5 specs, 5 plans, 10 commits). After the summary, the most recent matching session's first five prompts are shown to give richer context.

## See Also

- [/memory-search](memory-search.md) — search only agent memory (SQLite semantic or keyword)
- [/standup](standup.md) — see what agents are working on right now
- [/wrap-ticket](wrap-ticket.md) — captures learnings so future recalls find them
