# Brainstorm: SQLite + Vector Embeddings for Agent Memory

**Date:** 2026-03-14
**Status:** COMPLETE — Option A selected, ready for planning

## Problem Statement
Agent memory in dev-team is flat markdown files with no semantic search, no
consolidation, and no cross-agent visibility. Agents can't find relevant context
unless they know exactly where to look.

## Success Criteria
- Agents can semantically search memory ("what did we decide about auth?")
- Single SQLite DB per project replaces scattered .md files
- Works fully air-gapped (sqlite-lembed), upgrades quality when ollama available
- Migration from existing .md memory is automatic and validated
- No 35GB RAM problem (no Chroma)

## Scope
**IN:** Per-project SQLite memory DB, sqlite-vec + embeddings (lembed or ollama),
migration from .md, agent read/write/search, fallback to .md if extensions
unavailable, `/memory-search` user command

**OUT (for now):** Global cross-project memory DB, short/long-term tiered
distillation, session recording (claude-mem style), UI/dashboard

## Constraints
- Must work air-gapped (no mandatory API calls)
- Plugin is markdown/JSON today — this adds binary deps (sqlite extensions, GGUF model)
- Must handle multi-agent concurrent writes (WAL mode)
- Bundled model size ~24MB acceptable

## Embedding Strategy (Tiered)
```
if ollama running && has embedding model -> use ollama (best quality)
else if sqlite-lembed available          -> use bundled GGUF (good, zero deps)
else                                     -> fallback to .md files (no embeddings)
```

**Default model:** all-MiniLM-L6-v2 GGUF (24MB, 384-dim) via sqlite-lembed
**Upgrade model:** nomic-embed-text (768-dim, 8k context) via ollama

## Selected Design: Option A — "Embedded-First"

Single `memory.db` per project at `.claude/memory/memory.db`.

**Schema:**
```sql
memories(id, agent, type, content, metadata_json, created_at, updated_at)
memory_embeddings(id, memory_id, embedding)  -- sqlite-vec virtual table
```

**Interfaces:**
- `/memory-search <query>` — user-facing slash command (semantic search)
- Internal skill for agents: memory-store, memory-recall
- `/init-team` downloads sqlite-vec + sqlite-lembed + GGUF model

**Fallback:** If sqlite extensions unavailable, degrade to .md files (current behavior)

## Key Risks
- sqlite-lembed pre-v1.0, less battle-tested -> fallback to .md
- Binary distribution cross-platform -> download during /init-team
- Embedding quality for short text -> ollama upgrade path
- Migration edge cases -> validate before deleting .md originals

## Future Phases
- **v2:** Working/long-term memory tiers + `/memory-distill`
- **v3:** Global cross-project memory DB (`~/.claude/memory.db`)

## Research Notes

### Current Memory State (across ~/vibes/)
- 38 memory files, ~1,670 lines across 4 repos
- Cortex files (codebase maps) are detailed and well-maintained
- Lessons files are concise and actionable
- Problems: no search, no consolidation, context file rot, quality variance

### claude-mem Plugin (thedotmack)
- ~35k GitHub stars, uses SQLite + Chroma (not sqlite-vec)
- Chroma eats 35GB+ RAM on large stores (Issue #707)
- AGPL license, general-purpose session recorder
- Validates the concept but wrong architecture for our use case

### sqlite-vec Ecosystem
- sqlite-vec: stable v0.1.0, zero-dep C extension, <75ms search for 10k vectors
- sqlite-lembed: generates embeddings in-process using GGUF models
- sqlite-rembed: API-based embeddings (OpenAI, Ollama, etc.)
