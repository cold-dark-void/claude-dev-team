package journal

import "errors"

// Typed errors. Callers branch on these with errors.Is.
var (
	// ErrInvalid is a malformed event, path, or argument.
	ErrInvalid = errors.New("journal: invalid input")

	// ErrAppendOnly refuses a write that mutates the events journal
	// (schema.sql § APPEND-ONLY RULE). It is the Go half of the enforcement;
	// the events_no_update / events_no_delete triggers are the SQLite half.
	ErrAppendOnly = errors.New("journal: events is append-only")

	// ErrDuplicateKey refuses a second row with the same idempotency key (AC3).
	// The effect already happened: a replay must not repeat it.
	ErrDuplicateKey = errors.New("journal: idempotency key already recorded")

	// ErrTerminalState refuses a transition out of a terminal state.
	ErrTerminalState = errors.New("journal: run is terminal")

	// ErrTransition refuses an event that is legal for the journal but not for
	// the current state of the run. Nothing is written for it.
	ErrTransition = errors.New("journal: invalid transition")

	// ErrBudgetExhausted refuses a resume when the halt's retry budget is spent
	// (AC6). The run moves to a terminal state instead.
	ErrBudgetExhausted = errors.New("journal: retry budget exhausted")

	// ErrReplayInconsistent reports a journal that cannot be replayed: a
	// payload that contradicts the state its predecessors built.
	ErrReplayInconsistent = errors.New("journal: replay is inconsistent")

	// ErrLeaseHeld reports a live lease owned by someone else (AC4).
	ErrLeaseHeld = errors.New("journal: lease held by another owner")

	// ErrStaleToken reports a fencing token at or below the current token
	// (AC4). The writer is the zombie of an earlier owner.
	ErrStaleToken = errors.New("journal: stale fencing token")

	// ErrNotOwner reports a lease owner that does not match the caller.
	ErrNotOwner = errors.New("journal: caller is not the lease owner")

	// ErrNoLease reports a run with no live lease row.
	ErrNoLease = errors.New("journal: no lease row for run")

	// ErrMemoryDB refuses to open the agent memory database as the journal.
	// Run state is never in memory.db (docs/adr/0001-journal-engine.md).
	ErrMemoryDB = errors.New("journal: refusing to open memory.db")

	// ErrSchemaVersion reports a journal written by a newer schema.
	ErrSchemaVersion = errors.New("journal: unsupported schema_version")

	// ErrBusy reports SQLite lock contention after the busy timeout
	// (BusyTimeoutMS). The whole call is safe to retry: nothing was written.
	ErrBusy = errors.New("journal: database busy")
)
