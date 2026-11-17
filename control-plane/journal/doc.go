// Package journal is the control-plane run journal: an append-only SQLite
// event log behind a narrow interface (docs/adr/0001-journal-engine.md).
//
// One Run is one durable execution of a workflow for a ticket. Every lifecycle
// transition is one appended row. Run state is never stored: state is the pure
// replay of the rows (Replay), so the same journal yields the same state.
//
// The rules this package owns, and where each comes from:
//
//   - Append is the only write path for events. No UPDATE, no DELETE, at any
//     layer (schema.sql § APPEND-ONLY RULE; execGuard; DB triggers).
//   - Side effects carry an idempotency key, recorded before the effect runs
//     (intent-then-outcome, SPEC-040 AC11). A replay of the same intent finds
//     the existing row and does not repeat the effect.
//   - The journal REFERENCES decision-cards: a row carries card path, ts, and
//     run_id, never a copy of a card field (ADR 0001; SPEC-033 AC6/M13 keeps
//     every card at schema_version 1, and the journal never touches one).
//   - The journal file is git-ignored, lives under $MROOT/.claude/runs/, and is
//     never memory.db (Open refuses that path).
//   - Writes are short: one writer per open, busy timeout 5000 ms on every open
//     (the skills/memory-store/memdb.sh:35 pattern), and no transaction is held
//     across a model call, a spawn, or a network round trip (ADR 0001 § Cost 3).
//
// SQL text in this package is always a package constant. Values reach SQLite
// only as bound ? parameters in argv — the skills/lib/sqlq.sh convention
// (AGENTS.md § Code Conventions: untrusted input never becomes code).
package journal
