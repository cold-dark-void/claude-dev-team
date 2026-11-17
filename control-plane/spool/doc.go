// Package spool is the phase-event spool (CDT-642 AC3, AC4).
//
// A workflow writes one NDJSON line per phase event, so a run that dies leaves a
// readable trail of the phases it passed. The event kinds are the four the
// control plane needs: start, end, gate, halt. The phase vocabulary is the
// lifecycle graph (control-plane/lifecycle); this package does not import it, so
// a shell workflow can emit events without the Go loader.
//
// Path: $MROOT/.claude/runs/spool/spool.ndjson. $DEVTEAM_SPOOL overrides it
// outright, and $DEVTEAM_MROOT moves the $MROOT anchor — the same contract as
// control-plane/journal/open.go. .gitignore carries the pattern: the spool is
// process state, never committed, and never in memory.db.
//
// Record shape — one JSON object per line, these keys and no others:
//
//	{"ts":"2026-11-17T09:00:00Z","run_id":"CDT-642","phase":"plan","kind":"gate","detail":"plan-approve: approved"}
//
// ts is the canonical journal timestamp (UTC, second precision,
// journal.FormatTS). run_id and phase are required. kind is one of start, end,
// gate, halt. detail is optional free text.
//
// Idempotency (AC4): (run_id, phase, kind) is the key. Append checks the key
// first and writes nothing when the spool already holds it, refusing with the
// typed ErrDuplicate. That is the chosen rule: a typed error, not a silent
// dedupe, so a writer that meant to record a second event sees that it did not.
// Emit is the replay path a workflow uses: it stamps the clock, folds
// ErrDuplicate into created=false with a nil error, and so a replay of a crashed
// run neither fails nor causes a second transition. Has answers the question
// directly.
//
// Trust rule (AGENTS.md § Code Conventions): detail carries untrusted text —
// agent prose, human input. It is marshalled by encoding/json and written through
// a file handle as data. It is never assembled into a command, a shell string, or
// SQL. The path arrives as an argument, as $DEVTEAM_SPOOL, or from $MROOT.
// If the spool ever moves into SQLite, the SQL follows skills/lib/sqlq.sh: fixed
// statement text, every value bound through "?".
package spool
