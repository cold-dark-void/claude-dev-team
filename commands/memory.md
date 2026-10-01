---
name: memory
description: Unified memory surface — config, distill, export, search, stats, validate
argument-hint: "<config|distill|export|search|stats|validate> [args...]"
agent: build
---

# /memory

Unified entry point for all memory operations. One dispatcher; six subs.
Read only the mode file for the sub you are running. Do not read the others.
`@distiller` runs only from the distill mode (`/memory distill`).

## Dispatch

Parse the first positional argument as `<sub>`. If absent or unknown, print the
sub list below and stop. Remaining args pass through unchanged to the routed file.

```
Usage: /memory <config|distill|export|search|stats|validate> [args...]

Subs:
  config    View/set distillation and validation config
  distill   Compress tier-0 raw memories into digests / promote to core
  export    Export sanitized tier-2 seed pack (SPEC-024)
  search    Search memories (semantic / keyword / grep)
  stats     Anonymized usage metrics (counts and sizes only)
  validate  Cross-reference memories vs codebase; --reconcile for contradictions
```

## Routing table

| `<sub>` | Read only this file |
|---------|---------------------|
| `config` | `skills/memory-store/modes/config.md` |
| `distill` | `skills/memory-store/modes/distill.md` |
| `export` | `skills/memory-store/modes/export.md` |
| `search` | `skills/memory-store/modes/search.md` |
| `stats` | `skills/memory-store/modes/stats.md` |
| `validate` | `skills/validate-memory/host-pipeline.md` |
| `validate --reconcile` | `skills/validate-memory/host-pipeline.md` Step 1, then `skills/validate-memory/reconcile-host.md` |

Tier counts for `distill --status` and `search --status` are one fence:
`skills/memory-store/modes/tier-status.md`. Do not copy that SELECT.

## Root resolution

Every mode fence resolves its own paths. This block is the shared shape:

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
WTROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MEMDB="$MROOT/.claude/memory/memory.db"
```
