package killtest

import "time"

// The phase boundaries the kill test kills at. Each one is the point just
// after that journal row commits (and, for PhaseEffect, in the middle of a
// real side effect), with the process still holding the lease and the WAL open.
//
// The set is the run state machine's own ladder (run/machine.go,
// run/doc.go § Named states): claim, start, stint, heartbeat, the
// intent/effect/outcome triple, the watchdog halt, the resume, and the
// completion. PhaseCompleted is the "never twice" half of AC7: the kill lands
// after the run_completed row, so recovery must detect completion from replay
// and refuse the second completion.
//
// The lifecycle graph carries this list in machine-readable form and the sweep
// iterates the graph (CDT-642 AC2, control-plane/lifecycle). The constants below
// are the same list in Go, for the process boundary contract.
const (
	PhaseClaimed   = "claimed"
	PhaseRunning   = "running"
	PhaseStint     = "stint"
	PhaseHeartbeat = "heartbeat"
	PhaseIntent    = "intent"
	PhaseEffect    = "effect"
	PhaseOutcome   = "outcome"
	PhaseHalted    = "halted"
	PhaseResumed   = "resumed"
	PhaseCompleted = "completed"
)

// PhaseBoundaries is the full kill set, in lifecycle order. The machine-readable
// copy of this list is the lifecycle graph
// (docs/internal/control-plane/lifecycle-graph.json, § kill_test_boundaries), and
// the sweep iterates that list (CDT-642 AC2); TestGraphBoundaryListIsTheMachineLadder
// fails when the two disagree. This declaration stays the phase vocabulary: the
// ids the helper validates CDT643_KILLTEST_KILL_AT against.
var PhaseBoundaries = []string{
	PhaseClaimed, PhaseRunning, PhaseStint, PhaseHeartbeat,
	PhaseIntent, PhaseEffect, PhaseOutcome,
	PhaseHalted, PhaseResumed, PhaseCompleted,
}

// IsPhase reports whether s names a kill boundary.
func IsPhase(s string) bool {
	for _, p := range PhaseBoundaries {
		if p == s {
			return true
		}
	}
	return false
}

// The environment contract between the harness and the helper process. Values
// pass as argv-style environment entries, never as assembled shell text
// (AGENTS.md § Code Conventions).
const (
	EnvRunID   = "CDT643_KILLTEST_RUN_ID"
	EnvOwner   = "CDT643_KILLTEST_OWNER"
	EnvDB      = "CDT643_KILLTEST_DB"
	EnvEffects = "CDT643_KILLTEST_EFFECTS"
	EnvKillAt  = "CDT643_KILLTEST_KILL_AT"
	EnvReport  = "CDT643_KILLTEST_REPORT"
)

// The one run the harness drives. Ticket and workflow stay fixed across
// attempts: replay refuses a re-claim that changes them (journal.applyClaim).
const (
	RunID    = "CDT-643"
	Ticket   = "CDT-643"
	Workflow = "orchestrate"
	Model    = "sonnet"
)

// The two side effects of the script. KeyB is the effect only a recovery
// attempt performs, so the sweep proves a recovery does more than close the
// book: it finishes the run.
const (
	EffectA = "push-a"
	KeyA    = "CDT-643:push-a:1"
	EffectB = "push-b"
	KeyB    = "CDT-643:push-b:1"
)

// StallLimitSeconds is DEVTEAM_STALL_LIMIT for every attempt. One second is the
// smallest legal value (run.EnvStallLimit wants a positive integer) and it is
// the env layer of the run-budget chain, not a tuned number (AC9: CDT-610 owns
// tuning). The kill test needs a stall it can wait out in wall-clock time.
const StallLimitSeconds = "1"

// StallSleep is how long the script goes quiet to trip the watchdog for real,
// past the one-second journal timestamp truncation.
const StallSleep = 1300 * time.Millisecond

// TakeoverWait is how long the harness waits after a kill before it starts the
// recovery, so the dead owner's lease is past its own stall limit and the
// takeover is legal (run.acquireLease, Lease.Expired).
const TakeoverWait = 1500 * time.Millisecond
