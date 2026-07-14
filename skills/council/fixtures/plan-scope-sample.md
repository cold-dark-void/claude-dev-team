# Sample plan for council --plan scope (CDV-208 fixture)

This fixture is a static input for plan-scope preflight and extractor dry-reads.
It intentionally mixes one true claim (verifiable in-repo) and one fabricated
claim (false on purpose) so a live tribunal can yield VERIFIED + FABRICATED.

## Approach

### Decision: storage

- Use SQLite at `.claude/memory/memory.db` for agent memory (true — see SPEC-004).
- The council engine is implemented entirely in Rust under `src/council/` (fabricated — there is no Rust council crate; the engine is `skills/council/engine.sh`).

## Success criteria

- `/council --plan <path>` preflight exits 0 when the path is readable.
- Missing plan path exits 2 (usage), not exit 3 (deferred).
