---
name: memory-compress
description: |
    Fact-dense rewrite of agent memory prose (tier-0 notes, digests) without
    losing technical substance. Companion to /memory-distill. Zero external deps.
---

# Memory Compress

Optional brevity pass for **memory content** — not a full distillation (no
tier promotion). Goal: same facts, fewer tokens, so session loads stay lean.

## When

| Caller | When |
|--------|------|
| `/memory-distill` | Optional pre-step on raw tier-0 rows before digest LLM (if user asks, or `MEMORY_COMPRESS=1`) |
| Manual | User asks to compress cortex/lessons/memory prose |

Skip when `MEMORY_COMPRESS=0` or content is already bullet-dense.

## Rules (MUST)

1. **Preserve every technical fact** — names, paths, IDs, versions, constraints,
   decisions, “do not” rules
2. **Prefer bullets** over paragraphs; one fact per line when possible
3. **Drop** greetings, hedges, restatements, “as discussed”, process narration
4. **Keep** code snippets, commands, and error strings **byte-exact**
5. **Do not** invent facts or change meaning
6. **Do not** delete archived markers or tier semantics — this is prose only

## Output shape

```markdown
- Fact one (path/to/file: detail)
- Fact two — constraint
- DO NOT: <rule>
```

Target: roughly **40–60% fewer tokens** on verbose narrative; already-tight
bullets may stay near 100%.

## Protocol snippet

```bash
# Example: dump one agent's tier-0 for compress, then UPDATE content after rewrite
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
# Caller selects rows, rewrites with this skill's rules, writes back via
# memory-store UPDATE protocol — never delete history without distill.
```

When rewriting `.md` fallback files (`cortex.md` / `memory.md` / `lessons.md`),
preserve headers; compress body sections only.
