package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
	"github.com/cold-dark-void/claude-dev-team/control-plane/run"
)

// Owner is the owner-name prefix of the agent's lease identity. The full
// name carries the supervising agent's PID — "node-agent-4321" — the shape
// control-plane/reconcile reads the pid out of
// (control-plane/reconcile/reality.go § The lease record). The PID in the
// name is what makes a restarted agent a different owner: the takeover
// raises the fencing token, and a zombie of the dead agent writes nothing.
const Owner = "node-agent"

// owner is the lease identity of this agent process.
func (a *Agent) owner() string {
	return fmt.Sprintf("%s-%d", Owner, os.Getpid())
}

// Effect names of the agent's journal-first verbs. Each intent row lands
// before the verb acts; each outcome row closes it after.
const (
	EffectStart  = "agent.start"
	EffectStop   = "agent.stop"
	EffectSteer  = "agent.steer"
	EffectStatus = "agent.status"
	// EffectKill is the takeover's orphan kill: a live runner recorded by a
	// dead supervisor, stopped before the re-spawn (the adoption policy).
	EffectKill = "agent.kill"
	// EffectSession is the capture-time record of the host session id
	// (SPEC-044 CDT-661 AC1): the id the runner's session capture holds,
	// journaled once per attempt as an intent row and its outcome row, both
	// carrying the id. The row IS the record — no external reality re-proves
	// it — so control-plane/reconcile closes a pending one from its own
	// payload, and the chief's takeover reads the id from either row.
	EffectSession = "agent.session"
)

// agentRunsRelPath is where the agent records its live processes, under the
// run-state tree .gitignore already ignores (.claude/runs/).
const agentRunsRelPath = ".claude/runs/agent"

// DefaultGrace is the stop grace: SIGTERM first, SIGKILL after this long.
const DefaultGrace = 10 * time.Second

// killConfirmWait is how long an orphan stop polls after SIGKILL before it
// declares the process un-killable (only a D-state process survives it).
const killConfirmWait = 5 * time.Second

// pollInterval is how often the supervisor reads the steer control file and
// the journal.
const pollInterval = 100 * time.Millisecond

// heartbeatFloor is the smallest heartbeat interval: half the stall limit,
// but never faster than this (a one-second test stall limit is the C2 kill
// test's own number).
const heartbeatFloor = 250 * time.Millisecond

// runIDRE is the safe run-id shape. It names files under
// .claude/runs/agent/, so a path separator or a .. segment never reaches one.
var runIDRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*$`)

// Agent is one node agent over one journal. It reuses control-plane/run and
// control-plane/journal; it forks neither.
type Agent struct {
	// Runner is the selected runner. Start refuses a run when no runner is
	// selected (fail-closed).
	Runner Runner

	// Now is the clock, injected so a test can move time instead of sleeping.
	Now func() time.Time

	// steerMu serializes the steer verb: two concurrent steers must not
	// derive the same sequence number n.
	steerMu sync.Mutex
}

// New returns an agent. It resolves the runner selection first: a node with
// no selection returns a nil runner, and Start refuses every run until the
// node names one.
func New() (*Agent, error) {
	cfg, err := Load(nil)
	if err != nil {
		return nil, err
	}
	if !cfg.Selected() {
		return &Agent{}, nil
	}
	var r Runner
	switch cfg.Runner {
	case RunnerNative:
		r = Native{}
	case RunnerContainer:
		r = Container{}
	default:
		return nil, fmt.Errorf("%w: %q is not one of %s", ErrNoRunnerSelected,
			cfg.Runner, strings.Join(RunnerTypeList(), ", "))
	}
	return &Agent{Runner: r}, nil
}

// StartRequest is one start verb: the run to drive and the host CLI to spawn
// in its slot.
type StartRequest struct {
	RunID    string
	Ticket   string
	Workflow string
	Model    string
	// Command and Args name the host CLI. Command overrides the node config;
	// with neither, start refuses.
	Command string
	Args    []string
	// Env carries extra environment entries for the runner process, on top
	// of the agent's own environment the child inherits. The host adapter
	// is the only writer of these entries (the CDT-648 B7 proven-name rule:
	// only a proven credential name reaches a run); the agent itself injects
	// nothing.
	Env []string
}

// Supervise drives one run to its end and journals every step of it
// (journal-first). It claims or takes over the lease, moves the run to
// running, journals the spawn intent, spawns the host CLI, records the PID,
// and then supervises: heartbeats inside the stall limit, steers delivered at
// step boundaries, a clean exit completed, a failing exit failed.
//
// The returned error carries the terminal reason when the run ends failed, so
// a caller (and the systemd unit's Restart=on-failure) can react.
//
// A cancelled ctx is a quiet shutdown (SPEC-044 M8): this verb registers no
// process signal of its own, so the caller owns the reason. The child is
// stopped, the pidfile and the lease stay, and no halt row is written — the
// operator halt belongs to the stop verb alone.
func (a *Agent) Supervise(ctx context.Context, eng *journal.Engine, req StartRequest) error {
	if err := validRunID(req.RunID); err != nil {
		return err
	}
	if a.Runner == nil {
		return fmt.Errorf("%w: set $%s or the runner key of the node config",
			ErrNoRunnerSelected, EnvRunner)
	}
	command, args, err := a.resolveCommand(req)
	if err != nil {
		return err
	}
	m := run.New(eng, req.RunID)
	if a.Now != nil {
		m.Now = a.Now
	}
	// The pidfile check comes before any write: one supervisor per run.
	pidRec, pidErr := readPIDFile(req.RunID)
	if pidErr == nil && pidRec.live() {
		return fmt.Errorf("%w: pid %d supervises %s", ErrRunning, pidRec.SupervisorPID, req.RunID)
	}
	if pidErr != nil {
		return pidErr
	}
	// A dead supervisor's recorded runner that is still alive is an orphan
	// (the adoption policy's kill): the takeover stops it before the
	// re-spawn, so the run never carries two live runners. A container run
	// is probed by container name: the container outlives the client process
	// the pidfile recorded, so the PID probe alone would miss it.
	orphanPID := 0
	orphanContainer := ""
	if pidRec.Container != "" {
		cs, ok := a.Runner.(containerStopper)
		if !ok {
			return fmt.Errorf("%w: run %s recorded container %q but this node does not select the container runner",
				ErrNoRunnerSelected, req.RunID, pidRec.Container)
		}
		live, err := cs.ContainerRunning(pidRec.Container)
		if err != nil {
			return err
		}
		if live {
			orphanContainer = pidRec.Container
		}
	} else if pidRec.RunnerPID > 0 && probePID(pidRec.RunnerPID) == processAlive {
		orphanPID = pidRec.RunnerPID
	}

	// A run parked in a halt the agent does not resume is refused before any
	// lease write: only halted:stalled resumes, and only after the takeover
	// below.
	if st0, err := m.State(ctx); err != nil {
		return err
	} else if st0.Status == journal.StatusHalted &&
		(st0.Halt == nil || st0.Halt.Reason != run.ReasonStalled) {
		return fmt.Errorf("%w: %s", ErrHaltState, st0.Name())
	}

	token, err := a.claim(ctx, m, req)
	if err != nil {
		return err
	}

	// A watchdog halt names an owner that stopped proving liveness. The
	// restarting agent is the liveness coming back, so it resumes and spends
	// the reason's retry budget; every other halt belongs elsewhere.
	if st, err := m.State(ctx); err == nil && st.Status == journal.StatusHalted &&
		st.Halt != nil && st.Halt.Reason == run.ReasonStalled {
		if err := m.Resume(ctx, a.owner(), token); err != nil {
			return err
		}
	}

	if orphanPID > 0 || orphanContainer != "" {
		if err := a.killOrphan(ctx, m, token, req.RunID, orphanPID, orphanContainer); err != nil {
			return err
		}
	}

	proc, err := a.spawn(ctx, m, token, req.RunID, command, args, req.Env)
	if err != nil {
		return err
	}
	return a.supervise(ctx, m, token, req.RunID, proc)
}

// killOrphan stops the live runner a dead supervisor recorded, journaled
// intent-then-outcome under the fresh token, before the takeover re-spawns
// (the adoption policy). It runs after the claim, so the trail carries the
// new owner's token. A native orphan is named by pid; a container orphan by
// its container name.
func (a *Agent) killOrphan(ctx context.Context, m *run.Machine, token int64,
	runID string, pid int, container string) error {
	var (
		p       Process
		target  any
		stopErr error
	)
	if container != "" {
		cs, ok := a.Runner.(containerStopper)
		if !ok {
			return fmt.Errorf("%w: run %s recorded container %q but this node does not select the container runner",
				ErrNoRunnerSelected, runID, container)
		}
		target = map[string]any{"container": container}
		live, err := cs.ContainerRunning(container)
		if err != nil {
			return err
		}
		if !live {
			// The orphan died between the probe and the kill: nothing to stop.
			return nil
		}
	} else {
		var err error
		p, err = FindProcess(pid)
		switch {
		case err == nil:
		case errors.Is(err, ErrNotRunning):
			// The orphan died between the probe and the kill: nothing to stop.
			return nil
		default:
			return err
		}
		target = map[string]any{"pid": pid}
	}
	st, err := m.State(ctx)
	if err != nil {
		return err
	}
	key := fmt.Sprintf("agent:kill:%s#%d", runID, countEffects(st, EffectKill)+1)
	seq, _, err := m.Intent(ctx, a.owner(), token, key, EffectKill, target)
	if err != nil {
		return err
	}
	if container != "" {
		cs := a.Runner.(containerStopper)
		stopErr = cs.StopContainer(container, DefaultGrace)
	} else {
		stopErr = p.Stop(DefaultGrace)
	}
	outcome := map[string]any{"stopped": stopErr == nil}
	if container != "" {
		outcome["container"] = container
	} else {
		outcome["pid"] = pid
	}
	if _, oerr := m.Outcome(ctx, a.owner(), token, seq, EffectKill, outcome); oerr != nil {
		return oerr
	}
	return stopErr
}

// claim takes the lease for the run: a fresh claim, a self-claim after a
// crash between claim and start, or a takeover of an expired owner.
func (a *Agent) claim(ctx context.Context, m *run.Machine, req StartRequest) (int64, error) {
	token, err := m.Claim(ctx, a.owner(), req.Ticket, req.Workflow, req.Model)
	if err != nil {
		return 0, err
	}
	// claimed -> running. A takeover of a running run skips this: the run is
	// already running, and the takeover is journaled by Claim itself.
	if st, err := m.State(ctx); err == nil && st.Status == journal.StatusClaimed {
		if err := m.Start(ctx, a.owner(), token, req.Model); err != nil {
			return 0, err
		}
	}
	return token, nil
}

// spawn journals the spawn intent, spawns the host CLI, records the PID in
// the pidfile, and closes the intent with the outcome row.
//
// The attempt number is the count of prior spawn intents plus one. A pending
// spawn intent is the crash window of this very verb — an agent that died
// between its intent row and the spawn — and the recovery performs that
// pending effect instead of repeating it (the C2 kill-test rule: the
// recovery completes the work, it does not duplicate it).
func (a *Agent) spawn(ctx context.Context, m *run.Machine, token int64,
	runID, command string, args, extraEnv []string) (Process, error) {
	st, err := m.State(ctx)
	if err != nil {
		return nil, err
	}
	var (
		seq     int64
		attempt int
	)
	if e, found := pendingIntent(st, EffectStart); found {
		seq, attempt = e.Seq, countEffects(st, EffectStart)
	} else {
		attempt = countEffects(st, EffectStart) + 1
		key := fmt.Sprintf("agent:start:%s#%d", runID, attempt)
		intent := map[string]any{"command": command, "args": args, "attempt": attempt}
		var err error
		seq, _, err = m.Intent(ctx, a.owner(), token, key, EffectStart, intent)
		if err != nil {
			return nil, err
		}
	}

	proc, err := a.Runner.Start(Spec{Command: command, Args: args, Env: extraEnv,
		Name: containerName(runID)})
	if err != nil {
		return nil, err
	}
	rec := pidRecord{RunnerPID: proc.PID(), SupervisorPID: os.Getpid(),
		StartedTS: time.Now().Unix()}
	if a.Runner != nil {
		rec.RunnerType = a.Runner.Name()
	}
	if rec.RunnerType == RunnerContainer {
		rec.Container = containerName(runID)
	}
	if err := writePIDRecord(runID, rec); err != nil {
		_ = proc.Stop(0)
		return nil, err
	}
	outcome := map[string]any{"pid": proc.PID(), "attempt": attempt}
	if _, err := m.Outcome(ctx, a.owner(), token, seq, EffectStart, outcome); err != nil {
		_ = proc.Stop(0)
		return nil, err
	}
	// Progress is liveness: a stint journals the attempt that just began.
	if err := m.Stint(ctx, a.owner(), token, fmt.Sprintf("attempt %d", attempt)); err != nil {
		_ = proc.Stop(0)
		return nil, err
	}
	return proc, nil
}

// supervise is the supervision loop: heartbeats, steers, and the terminal
// exit. It returns when the run ends, the lease is lost, or the caller
// cancels the supervision context for a quiet shutdown.
func (a *Agent) supervise(ctx context.Context, m *run.Machine, token int64,
	runID string, proc Process) error {
	st, err := m.State(ctx)
	if err != nil {
		_ = proc.Stop(0)
		return err
	}
	limit, _, err := run.ResolveStallLimit(st.Model, m.Getenv)
	if err != nil {
		_ = proc.Stop(0)
		return err
	}
	beat := time.NewTicker(clamp(limit/2, heartbeatFloor, 30*time.Second))
	defer beat.Stop()
	poll := time.NewTicker(pollInterval)
	defer poll.Stop()
	// sessionID names the capture id this attempt has already journaled
	// (SPEC-044 CDT-661 AC1); the empty string means nothing has landed.
	sessionID := ""

	for {
		select {
		case <-ctx.Done():
			// Quiet shutdown (SPEC-044 M8): the caller cancelled the
			// supervision context — chiefd's restart, not an operator stop.
			// Stop the child inside the stop grace and write nothing: the
			// ctx is gone, so no journal write on it is trustworthy, and the
			// closed event set has no live-lease release verb. The pidfile
			// and the lease stay for the next supervisor — its orphan probe
			// reads the recorded pid and its takeover rides the fencing
			// token once the lease expires.
			a.stopQuiet(proc, DefaultGrace)
			return ctx.Err()
		case <-beat.C:
			if err := m.Heartbeat(ctx, a.owner(), token); err != nil {
				// The lease moved or the state moved: this supervisor is no
				// longer the fenced owner. When an operator stop closed the
				// run, the stop verb owns the close and this exit is quiet.
				// A replay failure is not falsified into a read: the
				// supervisor exits with the named cause.
				st, stateErr := m.State(ctx)
				if stateErr != nil {
					a.stopQuiet(proc, 0)
					return fmt.Errorf("agent: state after heartbeat failure: %w", stateErr)
				}
				if pendingEffect(st, EffectStop) || st.IsTerminal() {
					removeRunFiles(runID)
					return nil
				}
				a.stopQuiet(proc, 0)
				return fmt.Errorf("agent: heartbeat: %w", err)
			}
			if halted, err := m.Watchdog(ctx, a.owner(), token); err != nil {
				a.stopQuiet(proc, 0)
				return fmt.Errorf("agent: watchdog: %w", err)
			} else if halted {
				a.stopQuiet(proc, DefaultGrace)
				return fmt.Errorf("agent: watchdog halted the run")
			}
		case <-poll.C:
			if done, err := a.deliverSteers(ctx, m, token, runID, proc); done {
				// A stop intent without an outcome means the stop verb owns
				// the close: it kills the child and journals the halt.
				return nil
			} else if err != nil {
				a.stopQuiet(proc, 0)
				return err
			}
			if sessionID == "" {
				sessionID = a.journalSessionID(ctx, m, token, runID)
			}
		case exitErr := <-proc.Done():
			return a.runnerExit(ctx, m, token, runID, proc, exitErr)
		}
	}
}

// SessionSource is the capture contract the agent asks its runner's stdout
// sink through (SPEC-044 CDT-661 AC1): the capture records the session id
// from the host's output, the agent only asks for the id and journals it —
// it never parses host output (adapter seam, AC1). hostadapter.Capture
// satisfies it import-free: the agent package never imports hostadapter
// (hostadapter imports the agent).
type SessionSource interface {
	SessionID() string
}

// capturedRunner is the runner shape that carries a session-id capture: the
// native runner over a SessionSource stdout sink. The container runner and a
// capture-less start carry none and journal nothing.
type capturedRunner interface {
	CapturedSessionID() string
}

// journalSessionID journals the session id the runner's capture holds —
// once per attempt (SPEC-044 CDT-661 AC1): the intent row and its outcome
// row, both carrying the id and the attempt number, keyed
// "agent:session:<run>#<attempt>" under the live token. A crash between the
// two back-to-back appends leaves the one pending intent the reconciler
// closes from the row's own payload (control-plane/reconcile § effects), and
// the takeover reads the id from either row.
//
// It answers the id it journaled, and "" for the poll loop to retry on the
// next tick: no capture, no id yet, and a failed write (the idempotency key
// replays the intent safely) are never a new failure mode for the run — the
// adoption fallback covers a run whose host never named an id.
func (a *Agent) journalSessionID(ctx context.Context, m *run.Machine, token int64,
	runID string) string {
	src, ok := a.Runner.(capturedRunner)
	if !ok {
		return ""
	}
	id := src.CapturedSessionID()
	if id == "" {
		return ""
	}
	st, err := m.State(ctx)
	if err != nil {
		return ""
	}
	attempt := countEffects(st, EffectStart)
	if attempt < 1 {
		return ""
	}
	payload := map[string]any{"session_id": id, "attempt": attempt}
	key := fmt.Sprintf("agent:session:%s#%d", runID, attempt)
	seq, _, err := m.Intent(ctx, a.owner(), token, key, EffectSession, payload)
	if err != nil {
		return ""
	}
	if _, err := m.Outcome(ctx, a.owner(), token, seq, EffectSession, payload); err != nil {
		return ""
	}
	return id
}

// runnerExit is the terminal step: the host CLI exited on its own. A clean
// exit completes the run; a failing exit fails it with the reason the exit
// code names.
func (a *Agent) runnerExit(ctx context.Context, m *run.Machine, token int64,
	runID string, proc Process, exitErr error) error {
	// A stop in flight owns the close (the stop verb journals the outcome and
	// the halt); a completion in flight means the run is already closed. A
	// replay failure is not falsified into a read: the error carries up.
	st, err := m.State(ctx)
	if err != nil {
		return err
	}
	if pendingEffect(st, EffectStop) || st.IsTerminal() {
		removeRunFiles(runID)
		return nil
	}
	code := exitCode(exitErr)
	if code == 0 {
		err := m.Complete(ctx, a.owner(), token, map[string]any{"exit_code": 0}, nil)
		removeRunFiles(runID)
		return err
	}
	err = m.Fail(ctx, a.owner(), token, fmt.Sprintf("runner-exited:%d", code))
	removeRunFiles(runID)
	return err
}

// stopQuiet stops a child and reports nothing: the exit that follows carries
// the reason.
func (a *Agent) stopQuiet(proc Process, grace time.Duration) {
	_ = proc.Stop(grace)
}

// deliverSteers delivers every steer intent whose outcome has not landed. It
// returns done=true when it finds an unanswered stop intent: the stop verb is
// killing the child and owns the close.
func (a *Agent) deliverSteers(ctx context.Context, m *run.Machine, token int64,
	runID string, proc Process) (bool, error) {
	st, err := m.State(ctx)
	if err != nil {
		return false, err
	}
	if pendingEffect(st, EffectStop) {
		return true, nil
	}
	lines, err := readSteerLines(runID)
	if err != nil {
		return false, err
	}
	byN := make(map[int]string, len(lines))
	for _, l := range lines {
		byN[l.N] = l.Message
	}
	for _, e := range st.Effects {
		if e.Effect != EffectSteer || !e.Pending() {
			continue
		}
		n, ok := steerSeq(e.Key)
		if !ok {
			continue
		}
		msg, ok := byN[n]
		if !ok {
			continue
		}
		// The supervising process holds the stdin pipe: it is the only
		// writer of a control message to the runner process.
		if err := proc.Steer(msg); err != nil {
			return false, err
		}
		if _, err := m.Outcome(ctx, a.owner(), token, e.Seq, EffectSteer,
			map[string]any{"delivered": true}); err != nil {
			return false, err
		}
	}
	return false, nil
}

// Stop stops a run: the intent row first, then SIGTERM, then SIGKILL after
// the grace, then the outcome row and the named halt operator_halt. It is the
// only producer of halted:operator_halt (SPEC-044 M8). It usually runs in a
// process other than the supervisor — the pidfile is the handover between the
// two — and the supervising process, on seeing the unanswered stop intent,
// steps aside. The `node-agent start` signal path calls it in-process for the
// same result.
func (a *Agent) Stop(ctx context.Context, eng *journal.Engine, runID string, grace time.Duration) error {
	if grace < 0 {
		return fmt.Errorf("%w: %s", ErrGraceInvalid, grace)
	}
	if err := validRunID(runID); err != nil {
		return err
	}
	m := run.New(eng, runID)
	if a.Now != nil {
		m.Now = a.Now
	}
	st, err := m.State(ctx)
	if err != nil {
		return err
	}
	if st.Status != journal.StatusRunning {
		return fmt.Errorf("%w: %s is %s", ErrNotRunning, runID, st.Name())
	}
	rec, recErr := readPIDFile(runID)
	if recErr != nil {
		return recErr
	}
	if rec.RunnerPID <= 0 {
		// The run is running but the supervisor has not recorded the runner
		// yet (the window between m.Start and the pidfile write): nothing is
		// signalled, and nothing that implies a signal is journaled.
		return fmt.Errorf("%w: %s has no recorded runner pid yet", ErrNotRunning, runID)
	}
	stopIntent := map[string]any{"grace_s": int64(grace / time.Second), "pid": rec.RunnerPID}
	var stop func() error
	if rec.Container != "" {
		// A container run is stopped by name: the container outlives its
		// client process, so the recorded pid reaches only the client.
		cs, ok := a.Runner.(containerStopper)
		if !ok {
			return fmt.Errorf("%w: run %s recorded container %q but this node does not select the container runner",
				ErrNoRunnerSelected, runID, rec.Container)
		}
		stopIntent["container"] = rec.Container
		stop = func() error { return cs.StopContainer(rec.Container, grace) }
	} else {
		p, err := FindProcess(rec.RunnerPID)
		if err != nil {
			return err
		}
		stop = func() error { _ = p.Stop(grace); return nil }
	}

	// Journal first: the stop is recorded before the process is signalled, so
	// a crash between the row and the signal leaves the trail (and the
	// supervising process steps aside on the unanswered intent). The verbs
	// present the recorded owner and token: the identity the live lease
	// carries, which the run machine fences on.
	seq, _, err := m.Intent(ctx, st.Owner, st.Token, fmt.Sprintf("agent:stop:%s#1", runID),
		EffectStop, stopIntent)
	if err != nil {
		return err
	}
	_ = stop()
	outcome := map[string]any{"stopped": true}
	if rec.Container != "" {
		outcome["container"] = rec.Container
	}
	if _, err := m.Outcome(ctx, st.Owner, st.Token, seq, EffectStop, outcome); err != nil {
		return err
	}
	if err := m.Halt(ctx, st.Owner, st.Token, run.ReasonOperatorHalt,
		fmt.Sprintf("stopped by the operator (pid %d)", rec.RunnerPID)); err != nil {
		return err
	}
	removeRunFiles(runID)
	return nil
}

// Steer records a control message for a run and hands it to the supervising
// process, which delivers it to the runner process at its next step boundary
// and closes the intent with the outcome row. When the run's heartbeat is
// past its stall limit the delivery cannot be guaranteed: the intent stays
// recorded for the recovery agent, and ErrSteerLost is returned.
func (a *Agent) Steer(ctx context.Context, eng *journal.Engine, runID, message string) error {
	if message == "" {
		return fmt.Errorf("%w: steer needs a message", journal.ErrInvalid)
	}
	if err := validRunID(runID); err != nil {
		return err
	}
	// The whole record-then-append sequence is serialized: two concurrent
	// steers must not derive the same sequence number n.
	a.steerMu.Lock()
	defer a.steerMu.Unlock()
	m := run.New(eng, runID)
	if a.Now != nil {
		m.Now = a.Now
	}
	st, err := m.State(ctx)
	if err != nil {
		return err
	}
	if st.Status != journal.StatusRunning {
		return fmt.Errorf("%w: %s is %s", ErrNotRunning, runID, st.Name())
	}
	rec, err := readPIDFile(runID)
	if err != nil {
		return err
	}
	if rec.RunnerPID <= 0 {
		// The pre-pidfile window: no recorded process, nothing to deliver to.
		return fmt.Errorf("%w: %s has no recorded runner pid yet", ErrNotRunning, runID)
	}
	limit := time.Duration(st.StallLimitS) * time.Second
	lost := limit > 0 && st.SinceHeartbeat(nowOr(a.Now)) > limit

	n := countEffects(st, EffectSteer) + 1
	key := fmt.Sprintf("agent:steer:%s#%d", runID, n)
	seq, _, err := m.Intent(ctx, st.Owner, st.Token, key, EffectSteer,
		map[string]any{"message": message})
	if err != nil {
		return err
	}
	if err := appendSteerLine(runID, n, message); err != nil {
		// Close the intent: a steer whose line never reached the control
		// file must not stay pending — the delivery loop would wait on it
		// forever.
		_, _ = m.Outcome(ctx, st.Owner, st.Token, seq, EffectSteer,
			map[string]any{"delivered": false, "error": err.Error()})
		return err
	}
	if lost {
		return ErrSteerLost
	}
	return nil
}

// StatusReport is one status reading.
type StatusReport struct {
	RunID    string `json:"run_id"`
	State    string `json:"state"`
	Owner    string `json:"owner,omitempty"`
	Token    int64  `json:"token,omitempty"`
	Model    string `json:"model,omitempty"`
	Stint    int    `json:"stint,omitempty"`
	BeatTS   string `json:"last_heartbeat_ts,omitempty"`
	BeatAgeS int64  `json:"heartbeat_age_s,omitempty"`

	// Runner and its selection source; empty when the node has none.
	Runner string `json:"runner,omitempty"`
	Source string `json:"runner_source,omitempty"`

	// PID is the live runner process recorded for the run, and PIDState its
	// liveness (alive, dead, or unknown), from the record-ownership reality
	// probe (control-plane/reconcile/reality.go § ProcessState). On a
	// container run the pid is the Docker client's; Container carries the
	// session container's name and PIDState its liveness.
	PID       int    `json:"pid,omitempty"`
	PIDState  string `json:"pid_state,omitempty"`
	Container string `json:"container,omitempty"`

	// Journaled reports whether this reading was itself recorded in the
	// journal: true only on a running run, the one state where a side_effect
	// row is replayable.
	Journaled bool `json:"journaled"`
}

// Status reads a run. On a running run it journals its reading first —
// intent, then the read, then the outcome row — so even a status surface
// leaves its trail in order; on any other state it is a pure read and
// Journaled says so.
func (a *Agent) Status(ctx context.Context, eng *journal.Engine, runID string) (StatusReport, error) {
	if err := validRunID(runID); err != nil {
		return StatusReport{}, err
	}
	m := run.New(eng, runID)
	if a.Now != nil {
		m.Now = a.Now
	}
	st, err := m.State(ctx)
	if err != nil {
		return StatusReport{}, err
	}
	cfg, err := Load(nil)
	if err != nil {
		return StatusReport{}, err
	}
	rep := StatusReport{
		RunID:  runID,
		State:  st.Name(),
		Owner:  st.Owner,
		Token:  st.Token,
		Model:  st.Model,
		Stint:  st.Stint,
		BeatTS: st.HeartbeatTS,
		Source: cfg.Source,
	}
	if cfg.Raw != "" && !cfg.Selected() {
		// A selection that does not name a known runner is reported as read,
		// so a typo is visible on the status surface.
		rep.Runner = cfg.Raw
	} else if cfg.Selected() {
		rep.Runner = string(cfg.Runner)
	}
	if rec, err := readPIDFile(runID); err == nil && rec.RunnerPID > 0 {
		rep.PID = rec.RunnerPID
		rep.PIDState = probePID(rec.RunnerPID)
		if rec.Container != "" {
			// A container outlives its client process; Docker's own liveness
			// reading is the state that matters. A node whose selection
			// reverted to native cannot read it — fail closed like Stop and
			// Supervise instead of reporting the client process's state.
			cs, ok := a.Runner.(containerStopper)
			if !ok {
				return StatusReport{}, fmt.Errorf("%w: run %s recorded container %q but this node does not select the container runner",
					ErrNoRunnerSelected, runID, rec.Container)
			}
			rep.Container = rec.Container
			if live, err := cs.ContainerRunning(rec.Container); err == nil {
				if live {
					rep.PIDState = processAlive
				} else {
					rep.PIDState = processDead
				}
			}
		}
	}
	if st.Status == journal.StatusRunning {
		n := countEffects(st, EffectStatus) + 1
		key := fmt.Sprintf("agent:status:%s#%d", runID, n)
		seq, _, err := m.Intent(ctx, st.Owner, st.Token, key, EffectStatus,
			map[string]any{"state": st.Name()})
		if err != nil {
			return rep, err
		}
		if _, err := m.Outcome(ctx, st.Owner, st.Token, seq, EffectStatus,
			map[string]any{"state": st.Name(), "pid": rep.PID}); err != nil {
			return rep, err
		}
		rep.Journaled = true
	}
	if st.HeartbeatTS != "" {
		if t, err := journal.ParseTS(st.HeartbeatTS); err == nil {
			rep.BeatAgeS = int64(nowOr(a.Now).Sub(t) / time.Second)
		}
	}
	return rep, nil
}

// resolveCommand takes the host CLI from the verb when given, else from the
// node config. Nowhere means refuse.
func (a *Agent) resolveCommand(req StartRequest) (string, []string, error) {
	if req.Command != "" {
		return req.Command, req.Args, nil
	}
	cfg, err := Load(nil)
	if err != nil {
		return "", nil, err
	}
	if cfg.Command == "" {
		return "", nil, fmt.Errorf("%w: set --command or the command key of the node config", ErrNoCommand)
	}
	return cfg.Command, req.Args, nil
}

// pidRecord is the live-process record of one run: the runner process and the
// agent supervising it. RunnerType and Container record which runner owns
// the run — a container outlives its client process, so the adoption policy
// and the stop verb need the container name to reach it. Records written
// before CDT-647 carry neither field and read as native runs.
type pidRecord struct {
	RunnerPID     int        `json:"runner_pid"`
	SupervisorPID int        `json:"supervisor_pid"`
	StartedTS     int64      `json:"started_unix"`
	RunnerType    RunnerType `json:"runner_type,omitempty"`
	Container     string     `json:"container,omitempty"`
}

// live reports whether the recorded supervisor is alive. A dead supervisor's
// record is a stale handover, not a live run.
func (r pidRecord) live() bool { return probePID(r.SupervisorPID) == processAlive }

func probePID(pid int) string {
	if pid <= 0 {
		return processUnknown
	}
	p, err := os.FindProcess(pid)
	if err != nil {
		return processDead
	}
	switch err := p.Signal(syscall.Signal(0)); {
	case err == nil:
		return processAlive
	case errors.Is(err, os.ErrProcessDone), errors.Is(err, syscall.ESRCH):
		return processDead
	default:
		return processAlive
	}
}

// The liveness vocabulary of control-plane/reconcile/reality.go § ProcessState.
const (
	processAlive   = "alive"
	processDead    = "dead"
	processUnknown = "unknown"
)

// pidPath is the pidfile of one run.
func pidPath(runID string) string {
	mroot, err := journal.MROOT()
	if err != nil {
		return ""
	}
	return filepath.Join(mroot, agentRunsRelPath, runID+".pid")
}

// steerPath is the steer control file of one run: one JSON line per message,
// consumed by the supervising agent.
func steerPath(runID string) string {
	mroot, err := journal.MROOT()
	if err != nil {
		return ""
	}
	return filepath.Join(mroot, agentRunsRelPath, runID+".steer")
}

// removeRunFiles removes the live-process records of a finished run: the
// pidfile and the steer control file.
func removeRunFiles(runID string) {
	_ = os.Remove(pidPath(runID))
	_ = os.Remove(steerPath(runID))
}

// validRunID checks the safe run-id shape.
func validRunID(runID string) error {
	if !runIDRE.MatchString(runID) {
		return fmt.Errorf("%w: %q must match %s", ErrRunID, runID, runIDRE)
	}
	return nil
}

// steerLine is one control message in the steer file.
type steerLine struct {
	N       int    `json:"n"`
	Message string `json:"message"`
}

// writePIDRecord records the runner and the supervisor of a run. The write
// is tmp + rename, so a reader never sees a partial record.
func writePIDRecord(runID string, rec pidRecord) error {
	path := pidPath(runID)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("agent: create %s: %w", filepath.Dir(path), err)
	}
	raw, err := json.Marshal(rec)
	if err != nil {
		return fmt.Errorf("agent: pid record: %w", err)
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".pid-*")
	if err != nil {
		return fmt.Errorf("agent: pidfile tmp: %w", err)
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(raw); err != nil {
		tmp.Close()
		return fmt.Errorf("agent: pidfile write: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("agent: pidfile close: %w", err)
	}
	return os.Rename(tmp.Name(), path)
}

// writePIDFile records a plain pid pair — the shape the tests and the
// pre-CDT-647 records carry.
func writePIDFile(runID string, runnerPID, supervisorPID int) error {
	return writePIDRecord(runID, pidRecord{RunnerPID: runnerPID,
		SupervisorPID: supervisorPID, StartedTS: time.Now().Unix()})
}

// readPIDFile reads the live-process record of a run. A missing record is a
// run with no recorded process.
func readPIDFile(runID string) (pidRecord, error) {
	data, err := os.ReadFile(pidPath(runID))
	if err != nil {
		if os.IsNotExist(err) {
			return pidRecord{}, nil
		}
		return pidRecord{}, fmt.Errorf("agent: read pidfile: %w", err)
	}
	var rec pidRecord
	if err := json.Unmarshal(data, &rec); err != nil {
		return pidRecord{}, fmt.Errorf("agent: pidfile is not a record: %w", err)
	}
	return rec, nil
}

// appendSteerLine appends one control message. O_APPEND and one write keep
// concurrent verbs line-atomic.
func appendSteerLine(runID string, n int, message string) error {
	path := steerPath(runID)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("agent: create %s: %w", filepath.Dir(path), err)
	}
	raw, err := json.Marshal(steerLine{N: n, Message: message})
	if err != nil {
		return fmt.Errorf("agent: steer line: %w", err)
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return fmt.Errorf("agent: open %s: %w", path, err)
	}
	defer f.Close()
	if _, err := f.Write(append(raw, '\n')); err != nil {
		return fmt.Errorf("agent: steer append: %w", err)
	}
	return f.Sync()
}

// readSteerLines returns every control message recorded for a run. A missing
// file is no messages, not an error.
func readSteerLines(runID string) ([]steerLine, error) {
	data, err := os.ReadFile(steerPath(runID))
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("agent: read steer file: %w", err)
	}
	var out []steerLine
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		var l steerLine
		if err := json.Unmarshal([]byte(line), &l); err != nil {
			return nil, fmt.Errorf("agent: steer line is not a record: %w", err)
		}
		out = append(out, l)
	}
	return out, nil
}

// steerSeq reads the attempt number out of a steer intent key.
func steerSeq(key string) (int, bool) {
	_, suffix, found := strings.Cut(key, "#")
	if !found {
		return 0, false
	}
	n, err := strconv.Atoi(suffix)
	if err != nil || n < 1 {
		return 0, false
	}
	return n, true
}

// countEffects counts the intent rows of one effect name, pending or closed.
func countEffects(st *journal.State, effect string) int {
	n := 0
	for _, e := range st.Effects {
		if e.Effect == effect {
			n++
		}
	}
	return n
}

// pendingEffect reports whether an effect name has an unanswered intent.
func pendingEffect(st *journal.State, effect string) bool {
	_, found := pendingIntent(st, effect)
	return found
}

// pendingIntent returns one unanswered intent of an effect name, the oldest
// first. At most one of each can be pending: the verbs record, act, and close
// in order, and a second stop refuses on the state.
func pendingIntent(st *journal.State, effect string) (journal.RecordedEffect, bool) {
	for _, e := range st.Effects {
		if e.Effect == effect && e.Pending() {
			return e, true
		}
	}
	return journal.RecordedEffect{}, false
}

// FindProcess returns a live process interface for pid. A dead pid answers
// ErrNotRunning: there is nothing to stop, steer, or record. pid <= 0 is
// refused outright: signal(0) would reach this agent's own process group.
func FindProcess(pid int) (Process, error) {
	if pid <= 0 {
		return nil, fmt.Errorf("%w: pid %d", ErrNotRunning, pid)
	}
	switch probePID(pid) {
	case processDead:
		return nil, fmt.Errorf("%w: pid %d", ErrNotRunning, pid)
	default:
		return &orphanProcess{pid: pid}, nil
	}
}

// orphanProcess is a runner process this agent did not spawn — the handover
// case where the stop verb signals a process the supervising agent owns. It
// can be signalled, not steered: the stdin pipe belongs to the supervising
// agent.
type orphanProcess struct{ pid int }

func (p *orphanProcess) PID() int           { return p.pid }
func (p *orphanProcess) Done() <-chan error { return nil }
func (p *orphanProcess) Wait() error        { return nil }
func (p *orphanProcess) Steer(string) error {
	return fmt.Errorf("%w: pid %d was not spawned here", ErrNotRunning, p.pid)
}
func (p *orphanProcess) Signal(sig syscall.Signal) error {
	proc, err := os.FindProcess(p.pid)
	if err != nil {
		return err
	}
	return proc.Signal(sig)
}

// Stop on an orphan signals SIGTERM, waits a bounded grace for the exit, and
// escalates to SIGKILL. A grace of zero skips the SIGTERM, matching the
// native runner's stop. It cannot Wait the child (another process reaps it),
// so the death is confirmed by bounded polling on the liveness probe — both
// after the grace and after the SIGKILL.
func (p *orphanProcess) Stop(grace time.Duration) error {
	if grace != 0 {
		if err := p.Signal(syscall.SIGTERM); err != nil && !errors.Is(err, os.ErrProcessDone) {
			return fmt.Errorf("agent: stop pid %d: %w", p.pid, err)
		}
		deadline := time.Now().Add(grace)
		for time.Now().Before(deadline) {
			if probePID(p.pid) == processDead {
				return nil
			}
			time.Sleep(20 * time.Millisecond)
		}
	}
	if err := p.Signal(syscall.SIGKILL); err != nil && !errors.Is(err, os.ErrProcessDone) {
		return fmt.Errorf("agent: kill pid %d: %w", p.pid, err)
	}
	deadline := time.Now().Add(killConfirmWait)
	for time.Now().Before(deadline) {
		if probePID(p.pid) == processDead {
			return nil
		}
		time.Sleep(20 * time.Millisecond)
	}
	return fmt.Errorf("agent: pid %d survived SIGKILL", p.pid)
}

// nowOr is the injectable clock or the real one.
func nowOr(now func() time.Time) time.Time {
	if now != nil {
		return now().UTC()
	}
	return time.Now().UTC()
}

// clamp keeps d inside [lo, hi].
func clamp(d, lo, hi time.Duration) time.Duration {
	if d < lo {
		return lo
	}
	if d > hi {
		return hi
	}
	return d
}

// exitCode reads the exit code out of a wait result.
func exitCode(err error) int {
	if err == nil {
		return 0
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return ee.ExitCode()
	}
	return -1
}
