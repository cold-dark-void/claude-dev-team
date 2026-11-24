package killtest

import (
	"fmt"
	"time"

	"github.com/cold-dark-void/claude-dev-team/control-plane/hostadapter"
)

// The environment contract between the restart harness and ./restart/helper —
// the CDT-660 restart kill test (SPEC-044 AC13). Values pass as argv-style
// environment entries, never as assembled shell text (AGENTS.md § Code
// Conventions), in the CDT643_KILLTEST_* shape of phases.go.
const (
	// EnvRestartMode selects the helper's mode: ModeSupervise or ModeRestart.
	EnvRestartMode = "CDT660_RESTART_MODE"
	// EnvRestartRunID is the run the helper drives.
	EnvRestartRunID = "CDT660_RESTART_RUN_ID"
	// EnvRestartReady is the file the supervisor writes once the run is
	// mid-flight: the point the harness kills at.
	EnvRestartReady = "CDT660_RESTART_READY"
	// EnvRestartReport is the file the restarted chiefd writes its answer to.
	EnvRestartReport = "CDT660_RESTART_REPORT"
	// EnvRestartHostCount is the launch counter the host-session stand-in
	// writes: the external record of how many runner processes spawned.
	EnvRestartHostCount = "CDT660_RESTART_HOST_COUNT"
	// EnvRestartHostArgs is the file the host-session stand-in appends its
	// own argv to on every launch: the external record of the re-spawn
	// invocation (the CDT-661 AC5 resume assertion reads it).
	EnvRestartHostArgs = "CDT660_RESTART_HOST_ARGS"
)

// The two modes of ./restart/helper: the supervisor that gets killed, and the
// chiefd that restarts.
const (
	ModeSupervise = "supervise"
	ModeRestart   = "restart"
)

// The one run the restart harness drives. Ticket, workflow, and model stay
// fixed across the takeover: replay refuses a re-claim that changes the ticket
// or the workflow (journal.applyClaim), and the takeover derives its host from
// the run's recorded start argv, so the launch command must be one
// chief.hostByCommand knows.
const (
	RestartRunID    = "CDT-660"
	RestartTicket   = "CDT-660"
	RestartWorkflow = "debug"
	RestartModel    = "sonnet"
	RestartHost     = hostadapter.HostClaudeCode
	// RestartHostCLI is the host command the adapter launches for RestartHost
	// (hostadapter/launch.go) — the name the harness's host-session stand-in
	// carries on disk.
	RestartHostCLI = "claude"
	// RestartHostSessionID is the session id the host-session stand-in names
	// on launch 1 — the id the takeover's resume argv must carry
	// (SPEC-044 CDT-661 AC5: the same host session continues across the
	// crash).
	RestartHostSessionID = "killtest-session-1"
)

// RestartStallLimitSeconds is DEVTEAM_STALL_LIMIT for the restart case: the
// number SPEC-044's Test section names for the kill test. It keeps a lease that
// must expire on its own inside the CI job's 10-minute timeout (M14). It is the
// env layer of the run-budget chain, not a tuned number — CDT-610 owns the
// wall-clock numbers and this suite tunes none of them.
const RestartStallLimitSeconds = "2"

// The wall-clock bounds of the restart case. Each is generous against the
// ~15 s the case takes and well inside the job timeout: a bound that expires is
// a failure the log names, never a hung job.
const (
	// RestartReadyWait bounds the wait for the supervisor to report the run
	// mid-run.
	RestartReadyWait = 60 * time.Second
	// RestartFinishWait bounds one journal wait after the restart: the lease
	// expiry, and the run's terminal state.
	RestartFinishWait = 90 * time.Second
	// RestartSupervisorLife is how long the supervisor outlives its readiness
	// signal before declaring that nobody killed it.
	RestartSupervisorLife = 3 * time.Minute
)

// RestartStartKey is the node agent's spawn-intent key of one attempt
// (agent.spawn writes "agent:start:<run>#<attempt>").
func RestartStartKey(attempt int) string {
	return fmt.Sprintf("agent:start:%s#%d", RestartRunID, attempt)
}

// RestartSessionKey is the node agent's session-id intent key of one attempt
// ("agent:session:<run>#<attempt>", SPEC-044 CDT-661 AC1).
func RestartSessionKey(attempt int) string {
	return fmt.Sprintf("agent:session:%s#%d", RestartRunID, attempt)
}
