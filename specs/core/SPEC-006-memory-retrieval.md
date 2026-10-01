# SPEC-006: Memory Retrieval & Search

**Status**: ACTIVE
**Category**: core
**Created**: 2026-03-22

**Covers**: `skills/memory-recall/SKILL.md` (agent-internal protocol; live again after CDT-46-C3 over-stub), `/memory search` (`commands/memory.md` skill-delegates search to memory-recall), `commands/recall.md`

## Overview

The query layer for agent memories. Provides three search strategies (semantic vector search, keyword LIKE search, grep .md fallback) with automatic mode detection based on available infrastructure. Also includes cross-session recall that searches git history, plans, specs, backlog, and conversation history to find prior work on any topic.

## MUST

### Mode Auto-Detection
- MUST auto-detect search mode in priority order: semantic/lembed → semantic/remote → keyword → grep
- MUST fall back gracefully: semantic → keyword if embedding fails; keyword → grep if no DB
- MUST make every fenced bash block of `skills/memory-recall/SKILL.md` self-contained, because each block runs as a separate shell: the block resolves `MROOT` before it derives `MEMDB`, `EXT_DIR` or `MODEL_DIR`, and captures the query itself. A block MUST NOT read a variable that only an earlier block sets (SPEC-021 C6 checks the order)

### Tiered Loading (Session Start)
- MUST load memories by tier: tier-2 core first, then tier-1 digests, then tier-0 raw only for agents with no tier-1 or tier-2 memories (to ensure some context loads)
- MUST never return archived rows (`archived = TRUE` always filtered)
- MUST support optional agent and type filters on all queries

### Agent Session-Read Protocol (single source of truth)
- The agent session-READ (tiered) protocol is defined ONCE in `skills/agent-memory/protocol.md` (expanded into the 7 behavioral agents, drift-checked by `skills/agent-memory/sync-includes.py` at `/release`). `skills/memory-recall` Step 2 points at that partial and does not duplicate the bash.
- The read MUST select `type, content` (not `content` alone) with the tier-2 → tier-1 → tier-0 fallback (tier-0 only when no tier-1/tier-2 rows exist for the agent), `archived = TRUE` excluded.

### Semantic Search
- MUST use sqlite-vec KNN syntax (`MATCH` operator, `k = N`) for vector search
- MUST read `embedding_dimensions` from config for remote mode
- MUST call `lembed()` with the REGISTERED MODEL NAME (`mini`), never a file path. The Step 4 lembed block MUST register the GGUF on the same `sqlite3` connection, after the `.load` lines and before the query, with the statement `embed_lembed_register_sql` prints (`INSERT INTO temp.lembed_models(name, model) SELECT 'mini', lembed_model_from_file('<MROOT>/.claude/memory/models/all-MiniLM-L6-v2.gguf');`). The block MUST NOT hand-type that statement or the name: it resolves `skills/memory-store/embed-common.sh` through `plugin-dir.sh`, sources it, and uses `embed_lembed_register_sql` and `$EMBED_LEMBED_NAME`. When the file does not resolve, the block MUST fall back to keyword search. `temp.lembed_models` is per connection; SPEC-004 owns the name and the statement (WP 1-13, CDT-262)
- MUST derive `EXT_DIR` (`$MROOT/.claude/memory/extensions`) and `MODEL_DIR` (`$MROOT/.claude/memory/models`) in the semantic-search block itself, as `skills/memory-store/download-extensions.sh` does, and MUST quote every `.load` path
- MUST handle both OpenAI (`.data[0].embedding`) and Ollama (`.embeddings[0]`) response shapes
- MUST convert cosine distance to similarity: `(1 - distance) * 100`
- MUST surface unembedded memories after semantic results (so nothing is silently missed)

### Keyword Search
- MUST use SQL LIKE-based search across all agents and memory types
- MUST treat the query as literal text: single-quote escaped (`''`) and, in a LIKE pattern, `\`, `%` and `_` escaped with `ESCAPE '\'`, so a query such as `100%` does not match `1000`
- MUST return up to 20 results for keyword mode
- MUST exclude archived memories

### Grep Fallback
- MUST search `.claude/memory/<agent>/{cortex,memory,lessons,context}.md` when no DB available
- MUST match the query as a fixed string (`grep -F`), MUST capture it through a quoted heredoc so a query such as `$(touch X)` executes nothing, and MUST also search the current worktree's `.claude/memory/*/context.md` when it is not the main checkout
- MUST print nothing from the grep fallback when the DB is present (`USE_DB=true`)

### Memory Search Command
- MUST return top 10 results for semantic mode, up to 20 for keyword
- MUST sort results by tier DESC, then recency/distance
- MUST truncate snippets to first 200 chars
- MUST support `--status` flag to show DB stats (mode, row counts per agent/tier)
- MUST search all agents and all memory types (cortex, memory, lessons, digest, core)

### Recall (Cross-Session Search)
- MUST search structured sources FIRST (git, memories, plans, specs, backlog), then sessions
- MUST extract up to 8 related search terms from titles/descriptions of structured results
- MUST search conversation history (`~/.claude/history.jsonl`) with both original and expanded terms
- MUST include full `claude --resume <sessionId>` commands in output (never truncate session IDs)
- MUST sort all results by recency (newest first)
- MUST limit output: 10 sessions, 5 memory, 5 specs, 5 plans, 10 commits (show "+N more" if exceeded)
- MUST mark sessions matching only expanded terms with `(related: "<term>")`
- MUST omit sections with zero results

## SHOULD

- SHOULD decompose query terms (split hyphens, strip numbers) if zero structured results found
- SHOULD group session results by sessionId with matching prompts
- SHOULD include 2 lines of context around grep fallback matches

## Test

- Verify auto-detection selects correct mode based on available infrastructure
- Verify tiered loading returns tier-2 before tier-1, and tier-0 only when no distilled content exists for agent
- Verify archived rows never appear in any query result
- Verify semantic search returns ranked results with similarity scores
- Verify grep fallback includes context.md (which is always .md, never in SQLite)
- Verify each `skills/memory-recall/SKILL.md` fence runs in a fresh shell (`skills/memory-recall/test-fences.sh`): keyword and unembedded queries with `%`, `_` and `'` match literally; semantic search in none, remote (curl stub) and lembed mode loads `"<MROOT>/.claude/memory/extensions/vec0"` (the `.load` step is stubbed where the extensions are not installed); the grep fallback uses the DB when present, matches fixed strings and executes nothing for `$(touch X)`
- SPEC-006/T1 — keyword search treats `%`, `_` and `'` as literal text (`100%` does not match `1000`). Verify: bash skills/memory-recall/test-fences.sh
- Verify the lembed block of Step 4 registers the model before it calls `lembed('mini', …)` and never passes a path (`skills/memory-recall/test-fences.sh`; the shim records the SQL, and `skills/memory-store/test-embed-lembed.sh` refuses an unregistered name the way the extension does)
- Verify recall produces valid `claude --resume` commands

## Validation

- [ ] Search with DB + extensions returns semantic results
- [ ] Search with DB but no extensions returns keyword results
- [ ] Search with no DB returns grep results
- [ ] Archived memories excluded from all three modes
- [ ] Recall output includes session IDs that can be used with `claude --resume`

## Open Questions

- [ ] Is top-10 semantic / top-20 keyword the right default, or should limits be configurable?
- [ ] Should recall search cross-project sessions in `~/.claude/projects/` by default, or only when no local results found?

## Version History

| Date | Change |
|------|--------|
| 2026-10-01 | WP 2-03: SPEC-006/T1 names the keyword-literal assertion in `skills/memory-recall/test-fences.sh`. |
| 2026-09-30 | WP 1-13 (`wp-1-13-setup-team-lembed`; CDT-262 `[07 F-1]`): the MUST "pass file path to GGUF model for lembed (not model name)" is reversed. sqlite-lembed takes a registered model name, so the Step 4 lembed block registers the GGUF (`INSERT INTO temp.lembed_models(name, model) SELECT 'mini', lembed_model_from_file(…)`) on its own connection, after the `.load` lines, and calls `lembed('mini', <query>)`. `skills/memory-recall/test-fences.sh` asserts the order and the name. SPEC-004 owns the name and the statement. Step 4 sources `embed-common.sh` through `plugin-dir.sh` and has no typed copy; when the file does not resolve, it uses keyword search. Status stays ACTIVE. |
| 2026-09-30 | WP 1-12 (`wp-1-12-fence-state`; CDT-357, CDT-263 `[07 F-18]`, CDT-264, W2-22): every `skills/memory-recall/SKILL.md` fence is self-contained (separate shells). Step 4 derives `EXT_DIR`/`MODEL_DIR` from `MROOT` and quotes `.load` paths; Step 5 resolves `MROOT` before `MEMDB` so a present DB is used, matches with `grep -F`, captures the query through a quoted heredoc and searches a worktree's `context.md`; Steps 3, 4 and 8 escape `\`, `%`, `_` in LIKE patterns. The waiver after a `\` continuation in Step 4 is gone. Behavioural suite: `skills/memory-recall/test-fences.sh`. |
| 2026-07-22 | CDT-52: restore `skills/memory-recall/SKILL.md` body over-stubbed in pre.3/C3; session-read SoT clarified as `skills/agent-memory/protocol.md` (memory-recall Step 2 points, does not duplicate); `/memory search` skill-delegates to memory-recall. Status → ACTIVE. |
| 2026-07-22 | CDT-46-C3: retarget Covers `commands/memory-search.md` → `/memory search` (`commands/memory.md`). (Status was still INFERRED; false "Status stays ACTIVE" claim removed on promote.) |
| 2026-06-13 | Added "Agent Session-Read Protocol (single source of truth)" MUST — tiered read defined once in skills/memory-recall Step 2, carried as a managed-inline copy in skills/agent-memory/protocol.md (drift-checked at /release); read MUST select `type, content` with tier-2 → tier-1 → tier-0 fallback, archived excluded (AUDIT-P1-1). |
| 2026-03-23 | Clarified tiered loading scope: tier-0 only for agents with no tier-1 or tier-2 memories. Moved grep context lines to SHOULD. |
| 2026-03-22 | Initial spec generated by /generate-specs |
## Cross-references

- SPEC-004: Memory Storage — writes what this spec reads
- SPEC-005: Team Bootstrap — download-extensions.sh enables semantic search mode
- SPEC-007: Memory Distillation — changes tier assignments that affect tiered loading
- SPEC-003: Agent Role System — session start loading uses this spec's tiered protocol
