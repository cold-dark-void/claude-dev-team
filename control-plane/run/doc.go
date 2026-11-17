// Package run is the control-plane run state machine (CDT-643).
//
// A Run is one durable execution of a workflow for a ticket. Every transition
// appends a journal event, and the state is the replay of those events
// (journal.Replay), so the machine has no state of its own: a process that is
// SIGKILLed anywhere rebuilds the identical position from the journal on the
// next open (AC1, AC7).
//
// Named states (AC6):
//
//	claimed → running → completed
//	              ↘ halted:<reason> → running   (spends one retry of that reason)
//	claimed | running | halted:<reason> → failed
//
// halted:<reason> is one of stalled, lease_lost, reconcile_failed,
// budget_exhausted, operator_halt. Each carries a reason and a retry budget in
// journal.State.Halt; RetryBudgets fixes the budgets.
//
// One owner per run (AC4): every mutating call presents (owner, fencing token).
// The token is monotonic per run and lives in journal's lease table; a token at
// or below the current one is refused with journal.ErrStaleToken and nothing is
// written.
//
// Every mutating call runs inside one BEGIN IMMEDIATE journal transaction: the
// fencing check, the transition check (a replay of the candidate event), the
// lease write, and the append commit together. That atomicity is what makes the
// engine kill-safe: a crash leaves either the transition and its journal row, or
// neither.
package run
