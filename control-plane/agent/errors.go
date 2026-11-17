package agent

import "errors"

// Typed errors. Callers branch on these with errors.Is.
var (
	// ErrNoRunnerSelected is the fail-closed answer of a node with no runner
	// selection: start refuses and no run begins.
	ErrNoRunnerSelected = errors.New("agent: no runner selected on this node")

	// ErrNoCommand refuses a start whose host CLI command is nowhere: not in
	// the node config and not on the command line.
	ErrNoCommand = errors.New("agent: no runner command configured")

	// ErrRunning refuses a start of a run that already has a live supervisor
	// and a live lease: one supervisor per run.
	ErrRunning = errors.New("agent: run already has a live supervisor")

	// ErrNotRunning refuses stop and steer against a run with no live runner
	// process. Nothing is written.
	ErrNotRunning = errors.New("agent: run has no live runner process")

	// ErrHaltState refuses a start of a run parked in a halt state the agent
	// does not resume. Only halted:stalled resumes (the watchdog halt names an
	// owner that stopped proving liveness — the restarting agent is the
	// liveness coming back); every other halt belongs to the operator or the
	// reconciler.
	ErrHaltState = errors.New("agent: run is in a halt state the agent does not resume")

	// ErrRunID refuses a run id outside the safe shape. It names a file under
	// .claude/runs/agent/, so a path separator or a .. segment never reaches
	// it.
	ErrRunID = errors.New("agent: invalid run id")

	// ErrGraceInvalid refuses a negative stop grace.
	ErrGraceInvalid = errors.New("agent: stop grace is negative")

	// ErrSteerLost reports a steer whose delivery cannot be guaranteed: the
	// run's heartbeat is past its stall limit, so the supervising agent is
	// gone or gone quiet. The intent row is recorded; the recovery agent
	// resolves it.
	ErrSteerLost = errors.New("agent: run heartbeat is past its stall limit")
)
