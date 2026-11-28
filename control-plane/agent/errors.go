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

	// ErrNoContainerName refuses a container-runner start whose spec carries
	// no per-run container name. One container per run is named after its
	// run, so a session that cannot be named cannot be stopped or adopted.
	ErrNoContainerName = errors.New("agent: container start needs a container name")

	// ErrNoDocker refuses a container-runner start on a node whose Docker CLI
	// cannot be found. The node agent holds the socket; without its CLI it
	// holds nothing and starts nothing.
	ErrNoDocker = errors.New("agent: docker CLI not found")

	// ErrSocketLeak refuses an invocation that would hand the Docker socket
	// to the session container, or widen it with privileged or host-
	// namespace access. The node agent is the only holder of the socket.
	ErrSocketLeak = errors.New("agent: session container must not reach the Docker socket")

	// ErrUnknownSessionHost refuses a container-runner start whose host CLI
	// carries no container probe facts — no per-host state-mount row exists
	// for it (hostStateDirs; the matrix § AC-1 container cells).
	ErrUnknownSessionHost = errors.New("agent: host CLI has no container state-mount row")

	// ErrHostStateMissing refuses a container-runner start whose host CLI's
	// session state is absent on the node: the one-time operator login has
	// not happened, and a container started without it is unauthenticated.
	ErrHostStateMissing = errors.New("agent: host CLI session state is missing on this node")

	// ErrHandshakeFailed ends a supervision whose host never opened the
	// session the client asked for (SPEC-044 CDT-679 AC3). The run lands in
	// the named halt halted:handshake_failed; the error names the cause.
	ErrHandshakeFailed = errors.New("agent: the host session handshake failed")

	// ErrPremiseUndelivered ends a supervision whose session never took the
	// work premise it started with (SPEC-044 CDT-671 AC1): the bounded session
	// wait expired after the spawn with no delivered agent.premise row. The
	// run lands in the named halt halted:premise_undelivered; the error names
	// the cause. A start that carries no premise never raises it.
	ErrPremiseUndelivered = errors.New("agent: the run premise was never delivered to the session")
)
