// Package reconcile is the on-start reconciler (CDT-643 AC5).
//
// The control plane starts by asking one question: where does the journal say
// each run is, and where is it in reality? Reality is the worktrees git lists
// under $MROOT, the local branches, and the processes the lease records name.
// Run Run after a crash, a SIGKILL, or a reboot: it compares the two, repairs
// the difference through the run state machine, and journals every repair
// (journal.KindRepair). No state is mutated anywhere else.
//
// The comparison reuses wave 1: run.RecoveryPlan compares the journal with the
// lease and the clock, and this package turns those actions into events through
// the state machine's own paths (Machine.Repair, Outcome, Halt, Watchdog, Fail,
// ReleaseStaleLease). Every write presents the (owner, fencing token) that the
// lease row carries, so the reconciler bypasses nothing: a token it did not read
// from the lease is refused with journal.ErrStaleToken.
//
// The repair verbs are closed (phase 1):
//
//	adopt              journal the discovered state; reality is ahead of the journal
//	resume-failed      the run cannot be resumed; the run is marked failed
//	release-stale-lease the lease row is stale and locks nothing; release it
//	deferred           recorded, not executed: phase 1 does not act on it
//
// Deletion is out of scope. A foreign worktree, a foreign branch, and a finished
// run's leftovers are journaled as deferred findings with the exact observation
// and never removed, so the reconciler cannot destroy a human's work.
//
// Findings with no run of their own — a foreign worktree, a failed reality
// scan, a terminal run that still holds a lease — are journaled to run_id
// "reconcile" (JournalRun): the reconciler's own append-only log. Events belong
// to a run, and this is the run that owns the ones no run owns.
//
// The pass is idempotent (the SPEC-009 reconcile precedent): a repair is
// journaled only when the journal does not already carry a repair row with the
// same target, observation, and action. Run it twice with no change in reality
// and the second pass appends nothing.
//
// It never repeats an external effect. An intent with no outcome row is never
// re-driven here: the reconciler either closes it from observed reality or
// journals it as deferred for the owner to re-drive under the same idempotency
// key (SPEC-040 AC11).
package reconcile
