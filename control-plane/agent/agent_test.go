package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
	"github.com/cold-dark-void/claude-dev-team/control-plane/run"
)

// The one-second stall limit is the C2 kill test's own number
// (killtest.StallLimitSeconds): the smallest legal value, the env layer of
// the run-budget chain, not a tuned number.
const stallLimit = "1"

// takeoverWait is how long a test waits for a dead owner's lease to age past
// its stall limit before the takeover is legal.
const takeoverWait = 1300 * time.Millisecond

// deadOwner is the lease identity of a supervisor that no longer exists — a
// pid no process carries (the "node-agent-<pid>" owner shape).
const deadOwner = "node-agent-999999"

// newEngine opens one journal file in a private directory and points the
// agent's node state at it.
func newEngine(t *testing.T) *journal.Engine {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("DEVTEAM_MROOT", dir)
	t.Setenv("DEVTEAM_RUN_DB", filepath.Join(dir, "run.db"))
	t.Setenv("DEVTEAM_STALL_LIMIT", stallLimit)
	t.Setenv(EnvRunner, string(RunnerNative))
	eng, err := journal.OpenPath(context.Background(), os.Getenv("DEVTEAM_RUN_DB"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = eng.Close() })
	return eng
}

// nativeAgent is an agent whose runner children write nowhere the test output
// reads.
func nativeAgent() *Agent {
	return &Agent{Runner: Native{Stdout: io.Discard, Stderr: io.Discard}}
}

// state is the replayed state of one run.
func state(t *testing.T, eng *journal.Engine, runID string) *journal.State {
	t.Helper()
	st, err := eng.RunState(context.Background(), runID)
	if err != nil {
		t.Fatalf("replay %s: %v", runID, err)
	}
	return st
}

// waitFor polls a condition on the replayed state.
func waitFor(t *testing.T, eng *journal.Engine, runID string,
	cond func(*journal.State) bool, what string) *journal.State {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		st := state(t, eng, runID)
		if cond(st) {
			return st
		}
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s; state is %s", what, st.Name())
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// waitRunner waits for the run to be running and the supervisor's handover
// record (the pidfile) to exist: the state turns running one journal write
// before the pidfile lands, and a verb that races that window would see a
// run with no recorded process.
func waitRunner(t *testing.T, eng *journal.Engine, runID string) *journal.State {
	t.Helper()
	return waitFor(t, eng, runID, func(st *journal.State) bool {
		if st.Status != journal.StatusRunning {
			return false
		}
		rec, err := readPIDFile(runID)
		return err == nil && rec.RunnerPID > 0
	}, "the runner to start")
}

// startReq is a start request whose host CLI is the given sh script.
func startReq(runID, script string) StartRequest {
	return StartRequest{
		RunID: runID, Ticket: "CDT-644", Workflow: "orchestrate", Model: "sonnet",
		Command: "sh", Args: []string{"-c", script},
	}
}

// supervise runs the supervisor and delivers its terminal error.
func supervise(t *testing.T, a *Agent, eng *journal.Engine, req StartRequest) <-chan error {
	t.Helper()
	done := make(chan error, 1)
	go func() { done <- a.Supervise(context.Background(), eng, req) }()
	return done
}

// rowsByKind counts the journal rows of one kind.
func rowsByKind(t *testing.T, eng *journal.Engine, runID string, kind journal.Kind) int {
	t.Helper()
	rows, err := eng.Events(context.Background(), runID)
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, r := range rows {
		if r.Kind == kind {
			n++
		}
	}
	return n
}

// AC: the four-verb contract on a fresh run — start journals the spawn before
// it spawns, a clean exit of the host CLI completes the run exactly once, and
// the lease and the pidfile leave with it.
func TestSuperviseFreshRunCompletesOnce(t *testing.T) {
	eng := newEngine(t)
	runID := "CDT-644"
	a := nativeAgent()

	if err := a.Supervise(context.Background(), eng, startReq(runID, "exit 0")); err != nil {
		t.Fatalf("supervise: %v", err)
	}

	st := state(t, eng, runID)
	if st.Name() != "completed" {
		t.Fatalf("state = %s, want completed", st.Name())
	}
	for kind, want := range map[journal.Kind]int{
		journal.KindRunClaimed:   1,
		journal.KindRunStarted:   1,
		journal.KindRunCompleted: 1,
	} {
		if got := rowsByKind(t, eng, runID, kind); got != want {
			t.Errorf("%s rows = %d, want %d", kind, got, want)
		}
	}
	st1 := state(t, eng, runID)
	if n := len(st1.Effects); n != 1 {
		t.Fatalf("effects = %d, want the one spawn intent with its outcome", n)
	}
	if st1.Effects[0].Effect != EffectStart || st1.Effects[0].Pending() {
		t.Errorf("spawn effect = %+v, want a closed agent.start", st1.Effects[0])
	}
	if st1.Effects[0].Intent == nil || !strings.Contains(string(st1.Effects[0].Intent), `"command":"sh"`) {
		t.Errorf("intent row does not carry the command: %s", st1.Effects[0].Intent)
	}
	if rec, err := readPIDFile(runID); err != nil || rec.RunnerPID != 0 {
		t.Errorf("pidfile survived a completed run: %+v (err %v)", rec, err)
	}
	if _, err := run.New(eng, runID).ReadLease(context.Background()); !errors.Is(err, journal.ErrNoLease) {
		t.Errorf("lease after completion: err = %v, want journal.ErrNoLease", err)
	}
}

// journalPIDErr is gone: readPIDFile answers an empty record and a nil error
// for a missing file, which is the assertion shape above.

// AC: fail-closed. A node with no selection starts no run, and nothing is
// written.
func TestStartWithoutSelectionRefusesAndWritesNothing(t *testing.T) {
	eng := newEngine(t)
	t.Setenv(EnvRunner, "")
	runID := "CDT-644"

	a, err := New()
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if a.Runner != nil {
		t.Fatal("a node with no selection built a runner anyway")
	}
	err = a.Supervise(context.Background(), eng, startReq(runID, "exit 0"))
	if !errors.Is(err, ErrNoRunnerSelected) {
		t.Fatalf("supervise err = %v, want ErrNoRunnerSelected", err)
	}
	if rows, err := eng.Events(context.Background(), runID); err != nil || len(rows) != 0 {
		t.Errorf("a refused start wrote %d rows (err %v), want none", len(rows), err)
	}
}

// AC: steer is a control message delivered to the runner process at a step
// boundary, journaled intent first; stop is SIGTERM, then SIGKILL after the
// grace, landing the run in the named halt halted:operator_halt.
func TestSuperviseSteerThenOperatorStop(t *testing.T) {
	eng := newEngine(t)
	runID := "CDT-644"
	out := filepath.Join(t.TempDir(), "steered.txt")
	t.Setenv("CDT644_TEST_STEER_OUT", out)
	script := `read l; printf '%s' "$l" > "$CDT644_TEST_STEER_OUT"; sleep 30`
	a := nativeAgent()

	// CDT-656: a wide stall limit makes the steer clock-independent. The
	// heartbeat is half the stall limit (clamped by heartbeatFloor), so no
	// beat can go stale between waitRunner and the Steer call — a loaded CI
	// runner can no longer race the 1 s default limit into ErrSteerLost.
	// The C2 kill semantics below are unchanged: the stop still SIGTERMs,
	// then SIGKILLs past the grace, and lands halted:operator_halt.
	t.Setenv("DEVTEAM_STALL_LIMIT", "270")

	done := supervise(t, a, eng, startReq(runID, script))
	waitRunner(t, eng, runID)

	if err := a.Steer(context.Background(), eng, runID, "steer-one"); err != nil {
		t.Fatalf("steer: %v", err)
	}
	waitFor(t, eng, runID, func(st *journal.State) bool {
		e, ok := st.EffectByKey("agent:steer:" + runID + "#1")
		return ok && !e.Pending()
	}, "the steer outcome")
	raw, err := os.ReadFile(out)
	if err != nil {
		t.Fatalf("steered output: %v", err)
	}
	if string(raw) != "steer-one" {
		t.Errorf("the runner received %q, want steer-one", raw)
	}

	if err := a.Stop(context.Background(), eng, runID, time.Second); err != nil {
		t.Fatalf("stop: %v", err)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("supervisor exit: %v", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("supervisor did not exit after the stop")
	}

	st := state(t, eng, runID)
	if st.Name() != "halted:operator_halt" {
		t.Errorf("state = %s, want halted:operator_halt", st.Name())
	}
	if rec, err := readPIDFile(runID); err != nil || rec.RunnerPID != 0 {
		t.Errorf("pidfile survived the stop: %+v (err %v)", rec, err)
	}
	if err := a.Stop(context.Background(), eng, runID, time.Second); !errors.Is(err, ErrNotRunning) {
		t.Errorf("second stop err = %v, want ErrNotRunning", err)
	}
}

// AC15 (SPEC-044 M8): a cancelled supervision context is a quiet shutdown. The
// child stops, the pidfile and the lease stay for the next supervisor, and the
// journal gains no row at all — halted:operator_halt belongs to the stop verb,
// so a restart journals no run event.
func TestSuperviseCancelledContextIsQuietShutdown(t *testing.T) {
	eng := newEngine(t)
	// A wide stall limit keeps the heartbeat out of the window the row count is
	// measured across: the beat is half the stall limit (clamped), so no beat
	// fires before the cancel lands.
	t.Setenv("DEVTEAM_STALL_LIMIT", "270")
	runID := "CDT-660"
	a := nativeAgent()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- a.Supervise(ctx, eng, startReq(runID, "sleep 30")) }()
	waitRunner(t, eng, runID)

	rec, err := readPIDFile(runID)
	if err != nil || rec.RunnerPID <= 0 {
		t.Fatalf("pidfile before the cancel: %+v (err %v)", rec, err)
	}
	before, err := eng.Events(context.Background(), runID)
	if err != nil {
		t.Fatal(err)
	}

	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatalf("supervisor exit = %v, want context.Canceled", err)
	}

	if got := probePID(rec.RunnerPID); got != processDead {
		t.Errorf("runner pid %d reads %s, want %s", rec.RunnerPID, got, processDead)
	}
	if after, err := readPIDFile(runID); err != nil || after.RunnerPID != rec.RunnerPID ||
		after.SupervisorPID != rec.SupervisorPID {
		t.Errorf("pidfile after the shutdown = %+v (err %v), want the handover record kept", after, err)
	}
	if st := state(t, eng, runID); st.Status != journal.StatusRunning {
		t.Errorf("state = %s, want running", st.Name())
	}
	if n := rowsByKind(t, eng, runID, journal.KindRunHalted); n != 0 {
		t.Errorf("run_halted rows = %d, want none", n)
	}
	after, err := eng.Events(context.Background(), runID)
	if err != nil {
		t.Fatal(err)
	}
	if len(after) != len(before) {
		t.Errorf("journal rows went %d → %d across the shutdown, want no write", len(before), len(after))
	}
	lease, err := run.New(eng, runID).ReadLease(context.Background())
	if err != nil {
		t.Fatalf("lease after the shutdown: %v", err)
	}
	if lease.Owner != a.owner() || lease.Token == 0 {
		t.Errorf("lease after the shutdown = %q token %d, want %q and the live token",
			lease.Owner, lease.Token, a.owner())
	}
}

// AC: the CDT-626 reboot contract — every in-flight run continues without a
// human. The first agent died after it closed its spawn (the closed intent and
// the dead pidfile are its whole trail); the restarting agent takes over the
// expired lease, re-spawns as the next attempt, and completes the run exactly
// once.
func TestSuperviseTakeoverAfterAgentDeathCompletesOnce(t *testing.T) {
	eng := newEngine(t)
	runID := "CDT-644"
	ctx := context.Background()

	// The dead agent's trail: claim, start, one closed spawn, a dead runner
	// pid recorded, no pidfile supervisor alive.
	m := run.New(eng, runID)
	m.Getenv = func(string) string { return stallLimit }
	token, err := m.Claim(ctx, deadOwner, "CDT-644", "orchestrate", "sonnet")
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Start(ctx, deadOwner, token, "sonnet"); err != nil {
		t.Fatal(err)
	}
	seq, _, err := m.Intent(ctx, deadOwner, token, fmt.Sprintf("agent:start:%s#1", runID),
		EffectStart, map[string]any{"command": "sh", "attempt": 1})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := m.Outcome(ctx, deadOwner, token, seq, EffectStart,
		map[string]any{"pid": 999999, "attempt": 1}); err != nil {
		t.Fatal(err)
	}
	if err := m.Stint(ctx, deadOwner, token, "attempt 1"); err != nil {
		t.Fatal(err)
	}
	if err := writePIDFile(runID, 999999, 999999); err != nil {
		t.Fatal(err)
	}
	time.Sleep(takeoverWait) // the dead lease ages past its stall limit

	a := nativeAgent()
	if err := a.Supervise(ctx, eng, startReq(runID, "exit 0")); err != nil {
		t.Fatalf("supervise: %v", err)
	}

	st := state(t, eng, runID)
	if st.Name() != "completed" {
		t.Fatalf("state = %s, want completed", st.Name())
	}
	if n := rowsByKind(t, eng, runID, journal.KindRunCompleted); n != 1 {
		t.Errorf("run_completed rows = %d, want exactly once", n)
	}
	if n := rowsByKind(t, eng, runID, journal.KindLeaseAcquire); n != 1 {
		t.Errorf("lease_acquired rows = %d, want the one takeover", n)
	}
	starts := 0
	for _, e := range st.Effects {
		if e.Effect == EffectStart {
			starts++
			if e.Pending() {
				t.Errorf("spawn intent %s left pending", e.Key)
			}
		}
	}
	if starts != 2 {
		t.Errorf("agent.start effects = %d, want the dead attempt and the recovery attempt", starts)
	}
}

// AC: a crash between the spawn intent and the spawn itself is the pending
// effect the recovery performs — once, not twice.
func TestRecoveryPerformsThePendingSpawn(t *testing.T) {
	eng := newEngine(t)
	runID := "CDT-644"
	ctx := context.Background()

	m := run.New(eng, runID)
	m.Getenv = func(string) string { return stallLimit }
	token, err := m.Claim(ctx, deadOwner, "CDT-644", "orchestrate", "sonnet")
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Start(ctx, deadOwner, token, "sonnet"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := m.Intent(ctx, deadOwner, token, fmt.Sprintf("agent:start:%s#1", runID),
		EffectStart, map[string]any{"command": "sh", "attempt": 1}); err != nil {
		t.Fatal(err)
	}
	time.Sleep(takeoverWait)

	a := nativeAgent()
	if err := a.Supervise(ctx, eng, startReq(runID, "exit 0")); err != nil {
		t.Fatalf("supervise: %v", err)
	}

	st := state(t, eng, runID)
	if st.Name() != "completed" {
		t.Fatalf("state = %s, want completed", st.Name())
	}
	if n := rowsByKind(t, eng, runID, journal.KindRunCompleted); n != 1 {
		t.Errorf("run_completed rows = %d, want exactly once", n)
	}
	if n := len(st.Effects); n != 1 {
		t.Errorf("agent.start effects = %d, want the one pending intent, performed and closed", n)
	} else if st.Effects[0].Pending() {
		t.Error("the performed spawn intent is still pending")
	}
}

// AC: start refuses a run parked in halted:operator_halt — only the operator
// moves it — but resumes a watchdog halt: the restarting agent is the
// liveness coming back.
func TestSuperviseHaltStates(t *testing.T) {
	t.Run("operator_halt is refused", func(t *testing.T) {
		eng := newEngine(t)
		runID := "CDT-644"
		ctx := context.Background()
		m := run.New(eng, runID)
		m.Getenv = func(string) string { return stallLimit }
		token, err := m.Claim(ctx, deadOwner, "CDT-644", "orchestrate", "sonnet")
		if err != nil {
			t.Fatal(err)
		}
		if err := m.Start(ctx, deadOwner, token, "sonnet"); err != nil {
			t.Fatal(err)
		}
		if err := m.Halt(ctx, deadOwner, token, run.ReasonOperatorHalt, "operator stop"); err != nil {
			t.Fatal(err)
		}
		a := nativeAgent()
		err = a.Supervise(ctx, eng, startReq(runID, "exit 0"))
		if !errors.Is(err, ErrHaltState) {
			t.Fatalf("supervise err = %v, want ErrHaltState", err)
		}
	})

	t.Run("halted:stalled resumes and completes", func(t *testing.T) {
		eng := newEngine(t)
		runID := "CDT-644"
		ctx := context.Background()
		m := run.New(eng, runID)
		m.Getenv = func(string) string { return stallLimit }
		token, err := m.Claim(ctx, deadOwner, "CDT-644", "orchestrate", "sonnet")
		if err != nil {
			t.Fatal(err)
		}
		if err := m.Start(ctx, deadOwner, token, "sonnet"); err != nil {
			t.Fatal(err)
		}
		if err := m.Halt(ctx, deadOwner, token, run.ReasonStalled, "the probe died"); err != nil {
			t.Fatal(err)
		}
		time.Sleep(takeoverWait) // the dead lease ages past its stall limit

		a := nativeAgent()
		if err := a.Supervise(ctx, eng, startReq(runID, "exit 0")); err != nil {
			t.Fatalf("supervise: %v", err)
		}
		st := state(t, eng, runID)
		if st.Name() != "completed" {
			t.Fatalf("state = %s, want completed through the resume", st.Name())
		}
		if n := rowsByKind(t, eng, runID, journal.KindRunResumed); n != 1 {
			t.Errorf("run_resumed rows = %d, want 1", n)
		}
	})
}

// AC: steer past the stall limit cannot be guaranteed a delivery. The intent
// is still recorded — the recovery agent resolves it — and the verb answers
// ErrSteerLost.
func TestSteerPastTheStallLimitIsRecordedAndRefused(t *testing.T) {
	eng := newEngine(t)
	runID := "CDT-644"
	ctx := context.Background()

	// A run whose heartbeat is ten seconds old, under a one-second limit,
	// and whose dead supervisor left a recorded runner pid behind.
	past := time.Now().UTC().Add(-10 * time.Second)
	m := run.New(eng, runID)
	m.Getenv = func(string) string { return stallLimit }
	m.Now = func() time.Time { return past }
	token, err := m.Claim(ctx, deadOwner, "CDT-644", "orchestrate", "sonnet")
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Start(ctx, deadOwner, token, "sonnet"); err != nil {
		t.Fatal(err)
	}
	if err := writePIDFile(runID, 999999, 999999); err != nil {
		t.Fatal(err)
	}

	a := nativeAgent()
	err = a.Steer(context.Background(), eng, runID, "into the quiet")
	if !errors.Is(err, ErrSteerLost) {
		t.Fatalf("steer err = %v, want ErrSteerLost", err)
	}
	st := state(t, eng, runID)
	e, ok := st.EffectByKey("agent:steer:" + runID + "#1")
	if !ok || !e.Pending() {
		t.Fatalf("steer intent = %+v, want one pending agent.steer", e)
	}
	lines, err := readSteerLines(runID)
	if err != nil || len(lines) != 1 || lines[0].Message != "into the quiet" {
		t.Fatalf("steer lines = %+v (err %v), want the one recorded message", lines, err)
	}
}

// AC: status reads; on a running run the reading is itself journaled, on any
// other state it is a pure read and says so.
func TestStatusReadsAndJournals(t *testing.T) {
	eng := newEngine(t)
	runID := "CDT-644"
	a := nativeAgent()

	// A completed run: the reading is pure.
	if err := a.Supervise(context.Background(), eng, startReq(runID, "exit 0")); err != nil {
		t.Fatalf("supervise: %v", err)
	}
	rep, err := a.Status(context.Background(), eng, runID)
	if err != nil {
		t.Fatalf("status: %v", err)
	}
	if rep.State != "completed" || rep.Journaled {
		t.Errorf("status of a completed run = %+v, want a pure read of completed", rep)
	}

	// A running run: the reading lands in the journal as intent + outcome.
	done := supervise(t, a, eng, startReq(runID+"-b", "sleep 30"))
	waitRunner(t, eng, runID+"-b")
	rep, err = a.Status(context.Background(), eng, runID+"-b")
	if err != nil {
		t.Fatalf("status: %v", err)
	}
	if !rep.Journaled || rep.PIDState != processAlive {
		t.Errorf("status of a running run = %+v, want a journaled read of a live pid", rep)
	}
	st := state(t, eng, runID+"-b")
	e, ok := st.EffectByKey("agent:status:" + runID + "-b#1")
	if !ok || e.Pending() {
		t.Errorf("status effect = %+v, want closed", e)
	}

	if err := a.Stop(context.Background(), eng, runID+"-b", time.Second); err != nil {
		t.Fatalf("stop: %v", err)
	}
	<-done
}

// AC: a node whose selection reverted to native cannot read a run whose
// pidfile records a container run — the container outlives its client
// process and only the container runner can probe it. Status fails closed
// like Stop and Supervise instead of reporting the client pid's state.
func TestStatusOfAContainerRunOnANativeNodeFailsClosed(t *testing.T) {
	eng := newEngine(t)
	runID := "CDT-647"
	ctx := context.Background()

	// A running run whose supervisor recorded a container run.
	m := run.New(eng, runID)
	m.Getenv = func(string) string { return stallLimit }
	token, err := m.Claim(ctx, deadOwner, "CDT-647", "orchestrate", "sonnet")
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Start(ctx, deadOwner, token, "sonnet"); err != nil {
		t.Fatal(err)
	}
	if err := writePIDRecord(runID, pidRecord{
		RunnerPID: os.Getpid(), SupervisorPID: os.Getpid(),
		StartedTS: time.Now().Unix(), RunnerType: RunnerContainer,
		Container: containerName(runID),
	}); err != nil {
		t.Fatal(err)
	}

	a := nativeAgent()
	_, err = a.Status(ctx, eng, runID)
	if !errors.Is(err, ErrNoRunnerSelected) {
		t.Fatalf("status err = %v, want ErrNoRunnerSelected", err)
	}
}

// AC: one supervisor per run. A live supervisor and a live lease refuse a
// second start; a record whose supervisor is dead is a stale handover, not a
// live run.
func TestOneSupervisorPerRun(t *testing.T) {
	t.Run("live supervisor refuses a second start", func(t *testing.T) {
		eng := newEngine(t)
		runID := "CDT-644"
		a := nativeAgent()
		done := supervise(t, a, eng, startReq(runID, "sleep 30"))
		waitRunner(t, eng, runID)

		err := a.Supervise(context.Background(), eng, startReq(runID, "exit 0"))
		if !errors.Is(err, ErrRunning) {
			t.Fatalf("second supervise err = %v, want ErrRunning", err)
		}
		if err := a.Stop(context.Background(), eng, runID, time.Second); err != nil {
			t.Fatalf("stop: %v", err)
		}
		<-done
	})

	t.Run("stale handover is not a live run", func(t *testing.T) {
		eng := newEngine(t) // the node state environment; no run is driven
		_ = eng
		runID := "CDT-644"
		if err := writePIDFile(runID, 999999, 999999); err != nil {
			t.Fatal(err)
		}
		rec, err := readPIDFile(runID)
		if err != nil {
			t.Fatal(err)
		}
		if rec.live() {
			t.Fatal("a record of dead pids reported a live supervisor")
		}
	})
}

// AC: the adoption policy's orphan kill. A dead supervisor's recorded runner
// is still alive: the takeover stops the orphan before it re-spawns, journals
// the kill as an intent-then-outcome row, and exactly one live runner remains.
func TestSuperviseTakeoverKillsTheLiveOrphan(t *testing.T) {
	eng := newEngine(t)
	runID := "CDT-644"
	ctx := context.Background()

	// The dead supervisor's lease, expired by the wait below.
	m := run.New(eng, runID)
	m.Getenv = func(string) string { return stallLimit }
	token, err := m.Claim(ctx, deadOwner, "CDT-644", "orchestrate", "sonnet")
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Start(ctx, deadOwner, token, "sonnet"); err != nil {
		t.Fatal(err)
	}

	// A live orphan: a sleep that outlives its (exiting) parent shell.
	orphanFile := filepath.Join(t.TempDir(), "orphan.pid")
	cmd := exec.Command("sh", "-c", `sleep 30 & printf '%s\n' "$!" > "$1"`, "sh", orphanFile)
	if err := cmd.Run(); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(orphanFile)
	if err != nil {
		t.Fatal(err)
	}
	orphanPID, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil {
		t.Fatal(err)
	}
	if probePID(orphanPID) != processAlive {
		t.Fatalf("orphan pid %d did not survive its parent", orphanPID)
	}
	if err := writePIDFile(runID, orphanPID, 999999); err != nil {
		t.Fatal(err)
	}
	time.Sleep(takeoverWait) // the dead lease ages past its stall limit

	a := nativeAgent()
	done := supervise(t, a, eng, startReq(runID, "sleep 30"))
	waitRunner(t, eng, runID)
	// The stale handover record still names the orphan; wait for the
	// takeover's own runner record to replace it.
	waitFor(t, eng, runID, func(st *journal.State) bool {
		rec, err := readPIDFile(runID)
		return err == nil && rec.RunnerPID > 0 && rec.RunnerPID != orphanPID
	}, "the takeover's own runner record")

	// Exactly one live runner remains: the takeover's own, not the orphan.
	rec, err := readPIDFile(runID)
	if err != nil {
		t.Fatal(err)
	}
	if rec.RunnerPID <= 0 || rec.RunnerPID == orphanPID {
		t.Fatalf("pidfile runner = %d, want a fresh pid, not the orphan %d",
			rec.RunnerPID, orphanPID)
	}
	if probePID(rec.RunnerPID) != processAlive {
		t.Errorf("the takeover runner pid %d is not alive", rec.RunnerPID)
	}
	if probePID(orphanPID) != processDead {
		t.Errorf("the orphan pid %d survived the takeover", orphanPID)
	}
	st := state(t, eng, runID)
	e, ok := st.EffectByKey("agent:kill:" + runID + "#1")
	if !ok || e.Pending() {
		t.Fatalf("kill effect = %+v (found %v), want one closed agent.kill", e, ok)
	}
	if e.Intent == nil || !strings.Contains(string(e.Intent), `"pid":`+strconv.Itoa(orphanPID)) {
		t.Errorf("kill intent %s does not carry the orphan pid %d", e.Intent, orphanPID)
	}
	if e.Outcome == nil || !strings.Contains(string(e.Outcome), `"stopped":true`) {
		t.Errorf("kill outcome %s does not record the stop", e.Outcome)
	}

	if err := a.Stop(ctx, eng, runID, time.Second); err != nil {
		t.Fatalf("stop: %v", err)
	}
	if err := <-done; err != nil {
		t.Fatalf("supervisor exit: %v", err)
	}
}

// AC: the window between the run's start and the pidfile write is
// fail-closed. Stop and steer refuse a running run with no recorded runner
// pid (typed error, nothing journaled that implies a signal was sent), and
// FindProcess refuses pid 0 outright — a signal(0) there would reach this
// agent's own process group.
func TestStopAndSteerRefuseBeforeThePidfile(t *testing.T) {
	eng := newEngine(t)
	runID := "CDT-644"
	ctx := context.Background()

	// A running run whose supervisor has not written the pidfile yet.
	m := run.New(eng, runID)
	m.Getenv = func(string) string { return stallLimit }
	token, err := m.Claim(ctx, deadOwner, "CDT-644", "orchestrate", "sonnet")
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Start(ctx, deadOwner, token, "sonnet"); err != nil {
		t.Fatal(err)
	}

	a := nativeAgent()
	if err := a.Stop(ctx, eng, runID, time.Second); !errors.Is(err, ErrNotRunning) {
		t.Fatalf("stop in the pre-pidfile window err = %v, want ErrNotRunning", err)
	}
	if err := a.Steer(ctx, eng, runID, "no pid yet"); !errors.Is(err, ErrNotRunning) {
		t.Fatalf("steer in the pre-pidfile window err = %v, want ErrNotRunning", err)
	}

	// No signal side effect: not one side_effect row exists, and no pidfile
	// was created by the refused verbs.
	rows, err := eng.Events(ctx, runID)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range rows {
		if r.Kind == journal.KindSideEffect {
			t.Errorf("a refused verb wrote the side_effect row %s (%s)", r.IdempotencyKey, r.Kind)
		}
	}
	if _, err := os.Stat(pidPath(runID)); !os.IsNotExist(err) {
		t.Errorf("pidfile stat err = %v, want not exist", err)
	}

	if _, err := FindProcess(0); !errors.Is(err, ErrNotRunning) {
		t.Errorf("FindProcess(0) err = %v, want ErrNotRunning", err)
	}
}

// AC: the run id names a file under .claude/runs/agent/, so a path separator
// or a .. segment never reaches one.
func TestRunIDShape(t *testing.T) {
	cases := []struct {
		runID string
		want  bool
	}{
		{"CDT-644", true}, {"run.1", true}, {"a_b-c", true},
		{"", false}, {"../escape", false}, {"a/b", false}, {".hidden", false},
		{"leadingspace x", false},
	}
	for _, tc := range cases {
		err := validRunID(tc.runID)
		if got := err == nil; got != tc.want {
			t.Errorf("validRunID(%q) err = %v, want valid=%v", tc.runID, err, tc.want)
		}
	}
}

// ---------------------------------------------------------------------------
// SPEC-044 CDT-661 AC1 — capture-time journaling of the host session id
// ---------------------------------------------------------------------------

// sessionCapture is the test shape of hostadapter.Capture: an io.Writer the
// runner's stdout drains into that records the first stream line as the
// session id. It satisfies SessionSource exactly the way the real capture
// does.
type sessionCapture struct {
	mu sync.Mutex
	id string
}

func (c *sessionCapture) Write(p []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.id == "" {
		for _, line := range strings.Split(string(p), "\n") {
			if line = strings.TrimSpace(line); line != "" {
				c.id = line
				break
			}
		}
	}
	return len(p), nil
}

func (c *sessionCapture) SessionID() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.id
}

// progressCapture is the test shape of hostadapter.Capture's output reading
// (SPEC-044 CDT-671 AC2): it stamps every stream write it sees and answers the
// last one through the seam, so the agent asks for the reading and never parses
// host output.
type progressCapture struct {
	mu   sync.Mutex
	last time.Time
}

func (c *progressCapture) Write(p []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(p) > 0 {
		c.last = time.Now().UTC()
	}
	return len(p), nil
}

func (c *progressCapture) LastOutputTS() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.last.IsZero() {
		return ""
	}
	return journal.FormatTS(c.last)
}

// progressRows returns one run's run_progress payloads, in seq order.
func progressRows(t *testing.T, eng *journal.Engine, runID string) []journal.ProgressPayload {
	t.Helper()
	rows, err := eng.Events(context.Background(), runID)
	if err != nil {
		t.Fatal(err)
	}
	var out []journal.ProgressPayload
	for _, r := range rows {
		if r.Kind != journal.KindRunProgress {
			continue
		}
		var p journal.ProgressPayload
		if err := json.Unmarshal(r.Payload, &p); err != nil {
			t.Fatalf("run_progress payload %s: %v", r.Payload, err)
		}
		out = append(out, p)
	}
	return out
}

// AC2: the supervision loop journals the capture's last output time as its own
// run_progress row — never a heartbeat row — so the replay carries the progress
// time on the state beside the heartbeat reading.
func TestSuperviseJournalsTheProgressTime(t *testing.T) {
	eng := newEngine(t)
	// The 1 s stall limit newEngine pins makes the beat fire every 500 ms; a
	// starved beat on a loaded runner would halt this run (CDT-656 precedent).
	t.Setenv("DEVTEAM_STALL_LIMIT", "270")
	runID := "CDT-671"
	pc := &progressCapture{}
	a := &Agent{Runner: Native{Stdout: pc, Stderr: io.Discard}}

	// The host writes its stream, then goes quiet.
	if err := a.Supervise(context.Background(), eng,
		startReq(runID, `printf 'hello\n'; sleep 0.5`)); err != nil {
		t.Fatalf("supervise: %v", err)
	}

	rows := progressRows(t, eng, runID)
	if len(rows) < 1 {
		t.Fatalf("run_progress rows = %d, want the row the capture fed", len(rows))
	}
	want := pc.LastOutputTS()
	for _, p := range rows {
		if p.LastOutputTS == "" {
			t.Fatalf("run_progress row %+v carries no output time", p)
		}
	}
	if got := rows[len(rows)-1].LastOutputTS; got != want {
		t.Errorf("last progress row = %q, want the capture's %q", got, want)
	}
	st := state(t, eng, runID)
	if st.ProgressTS != want {
		t.Errorf("state progress time = %q, want %q", st.ProgressTS, want)
	}
	// The row is its own kind: this run's child lives half a second, so the
	// 270 s stall limit keeps the beat out of the window and no heartbeat row
	// exists to confuse with it.
	if n := rowsByKind(t, eng, runID, journal.KindHeartbeat); n != 0 {
		t.Errorf("heartbeat rows = %d, want 0: the progress rows are not liveness rows", n)
	}
	if n := rowsByKind(t, eng, runID, journal.KindRunProgress); n != len(rows) {
		t.Errorf("run_progress rows = %d, want %d", n, len(rows))
	}
}

// AC2 boundary: a runner with no output capture — the container runner, and a
// native start whose sink is a plain writer — journals no progress row and
// carries no progress time. The reading names the absence, never a guess.
func TestSuperviseWithNoCaptureJournalsNoProgressRow(t *testing.T) {
	eng := newEngine(t)
	runID := "CDT-671"
	a := nativeAgent() // Stdout is io.Discard: no ProgressSource behind it

	if err := a.Supervise(context.Background(), eng,
		startReq(runID, `printf 'hello\n'; sleep 0.2`)); err != nil {
		t.Fatalf("supervise: %v", err)
	}
	if n := len(progressRows(t, eng, runID)); n != 0 {
		t.Errorf("run_progress rows = %d, want 0: a capture-less runner has no "+
			"progress time to report", n)
	}
	if st := state(t, eng, runID); st.ProgressTS != "" {
		t.Errorf("state progress time = %q, want the empty reading, never a guess",
			st.ProgressTS)
	}
	if got := (Native{Stdout: io.Discard}).CapturedOutputTS(); got != "" {
		t.Errorf("CapturedOutputTS on a plain writer = %q, want \"\"", got)
	}
}

// lateSessionRunner reports its capture id only after a delay: the poll
// loop must retry on the tick that names the id and treat the earlier
// unnamed ticks as nothing at all.
type lateSessionRunner struct {
	Native
	mu    sync.Mutex
	id    string
	since time.Time
	late  time.Duration
}

func (r *lateSessionRunner) CapturedSessionID() string {
	r.mu.Lock()
	defer r.mu.Unlock()
	if time.Since(r.since) < r.late {
		return ""
	}
	return r.id
}

// effectByKey is the record of one effect key on the replayed state.
func effectByKey(t *testing.T, eng *journal.Engine, runID, key string) journal.RecordedEffect {
	t.Helper()
	for _, e := range state(t, eng, runID).Effects {
		if e.Key == key {
			return e
		}
	}
	t.Fatalf("run %s carries no effect keyed %s", runID, key)
	return journal.RecordedEffect{}
}

// countKeyRows counts the journal rows carrying one idempotency key. Only
// the intent half of a side effect carries the key, so this is the count of
// times the intent landed: a replay answers with the recorded row, never a
// second one.
func countKeyRows(t *testing.T, eng *journal.Engine, runID, key string) int {
	t.Helper()
	rows, err := eng.Events(context.Background(), runID)
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, r := range rows {
		if r.IdempotencyKey == key {
			n++
		}
	}
	return n
}

// countEffectRows counts one run's side_effect rows of one effect name,
// both halves.
func countEffectRows(t *testing.T, eng *journal.Engine, runID, effect string) int {
	t.Helper()
	rows, err := eng.Events(context.Background(), runID)
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, r := range rows {
		if r.Kind != journal.KindSideEffect {
			continue
		}
		var ef journal.Effect
		if json.Unmarshal(r.Payload, &ef) == nil && ef.Effect == effect {
			n++
		}
	}
	return n
}

// AC1: a supervised run whose runner's capture names a session id lands
// exactly one closed agent.session row pair keyed to the live attempt, both
// rows carrying the id, and the run rides on unchanged.
func TestSuperviseJournalsTheCapturedSessionID(t *testing.T) {
	eng := newEngine(t)
	runID := "CDT-661"
	sc := &sessionCapture{}
	a := &Agent{Runner: Native{Stdout: sc, Stderr: io.Discard}}

	// The host CLI names its session, then lives across several poll ticks.
	req := startReq(runID, `printf 'sess-abc\n'; sleep 1`)
	if err := a.Supervise(context.Background(), eng, req); err != nil {
		t.Fatalf("supervise: %v", err)
	}
	if sc.SessionID() != "sess-abc" {
		t.Fatalf("capture = %q, want sess-abc: the sink must pass the stream through",
			sc.SessionID())
	}
	key := "agent:session:" + runID + "#1"
	e := effectByKey(t, eng, runID, key)
	if e.Effect != EffectSession || e.Pending() {
		t.Fatalf("session effect = %+v, want a closed agent.session row pair", e)
	}
	for _, raw := range [][]byte{e.Intent, e.Outcome} {
		if !strings.Contains(string(raw), `"session_id":"sess-abc"`) ||
			!strings.Contains(string(raw), `"attempt":1`) {
			t.Errorf("row %s does not carry the id and the attempt", raw)
		}
	}
	if n := countKeyRows(t, eng, runID, key); n != 1 {
		t.Errorf("rows keyed %s = %d, want the one intent", key, n)
	}
	if n := countEffectRows(t, eng, runID, EffectSession); n != 2 {
		t.Errorf("agent.session rows = %d, want the intent and its outcome", n)
	}
	if st := state(t, eng, runID); st.Name() != "completed" {
		t.Errorf("state = %s, want completed", st.Name())
	}
}

// AC1 boundary: a start whose runner carries no capture journals no session
// row — the adoption fallback covers that run.
func TestSuperviseWithNoCaptureJournalsNoSessionRow(t *testing.T) {
	eng := newEngine(t)
	runID := "CDT-661"
	a := nativeAgent() // Stdout is io.Discard: no SessionSource behind it

	if err := a.Supervise(context.Background(), eng,
		startReq(runID, `printf 'sess-abc\n'; sleep 0.3`)); err != nil {
		t.Fatalf("supervise: %v", err)
	}
	if n := countEffectRows(t, eng, runID, EffectSession); n != 0 {
		t.Errorf("agent.session rows = %d, want 0: a capture-less start journals none", n)
	}
}

// The retry rule: the id named late is journaled when it lands, the run is
// never harmed by the earlier unnamed ticks, and the pair lands exactly
// once.
func TestSuperviseSessionJournalRetriesUntilTheIDIsNamed(t *testing.T) {
	eng := newEngine(t)
	// CDT-656 precedent: a wide stall limit makes the run clock-independent.
	// The beat is half the stall limit (clamped), so the 1 s default fires a
	// watchdog check every 500 ms for the whole 5 s child, and a starved beat
	// halts the run on a loaded runner. 270 s keeps the watchdog out of the
	// window; the late-id retry rides the 100 ms poll tick, not the beat.
	t.Setenv("DEVTEAM_STALL_LIMIT", "270")
	runID := "CDT-661"
	r := &lateSessionRunner{
		Native: Native{Stdout: io.Discard, Stderr: io.Discard},
		id:     "sess-late", since: time.Now(), late: 350 * time.Millisecond,
	}
	a := &Agent{Runner: r}

	// sleep 5 (not 1): the tick that journals the late id needs headroom
	// after the 350 ms capture under package parallelism. The test runs ~5 s.
	if err := a.Supervise(context.Background(), eng, startReq(runID, `sleep 5`)); err != nil {
		t.Fatalf("supervise: %v", err)
	}
	key := "agent:session:" + runID + "#1"
	e := effectByKey(t, eng, runID, key)
	if e.Effect != EffectSession || e.Pending() {
		t.Fatalf("session effect = %+v, want the closed pair the retry landed", e)
	}
	if !strings.Contains(string(e.Outcome), `"session_id":"sess-late"`) {
		t.Errorf("outcome %s does not carry the late id", e.Outcome)
	}
	if n := countEffectRows(t, eng, runID, EffectSession); n != 2 {
		t.Errorf("agent.session rows = %d, want one closed pair", n)
	}
}

// The crash-window shape a failed half of the pair leaves — a session
// intent with no outcome: the next write replays the intent under the same
// idempotency key and closes it, never a second row.
func TestJournalSessionIDReplaysThePendingIntent(t *testing.T) {
	eng := newEngine(t)
	runID := "CDT-661"
	ctx := context.Background()
	a := &Agent{Runner: &lateSessionRunner{
		Native: Native{Stdout: io.Discard}, id: "sess-x", late: -time.Second,
	}}
	m := run.New(eng, runID)
	owner, model := a.owner(), "sonnet"
	token, err := m.Claim(ctx, owner, "CDT-661", "debug", model)
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Start(ctx, owner, token, model); err != nil {
		t.Fatal(err)
	}
	if _, _, err := m.Intent(ctx, owner, token, "agent:start:"+runID+"#1",
		EffectStart, map[string]any{"attempt": 1}); err != nil {
		t.Fatal(err)
	}
	key := "agent:session:" + runID + "#1"
	if _, _, err := m.Intent(ctx, owner, token, key, EffectSession,
		map[string]any{"session_id": "sess-x", "attempt": 1}); err != nil {
		t.Fatal(err)
	}

	if got := a.journalSessionID(ctx, m, token, runID); got != "sess-x" {
		t.Fatalf("journalSessionID = %q, want sess-x", got)
	}
	e := effectByKey(t, eng, runID, key)
	if e.Pending() {
		t.Errorf("the pending intent survived the write: %+v", e)
	}
	if n := countKeyRows(t, eng, runID, key); n != 1 {
		t.Errorf("rows keyed %s = %d, want the replayed intent, never a duplicate", key, n)
	}
}

// ---------------------------------------------------------------------------
// SPEC-044 CDT-665 — the work premise reaches the session's first turn
// ---------------------------------------------------------------------------

// premiseTestFrame is the test host's first-turn frame — the shape a host
// adapter's per-host spec owns. It names the session, so a frame rendered
// before the capture names the id is visible in the bytes the child read.
func premiseTestFrame(sessionID, premise string, seq int) (string, bool) {
	if sessionID == "" {
		return "", false
	}
	return fmt.Sprintf(`{"type":"prompt","session_id":%q,"premise":%q,"id":%d}`,
		sessionID, premise, seq), true
}

// firstFrameFile points the seam child's stdin capture at a file of its own.
// The child scripts below read one line of stdin — the session's first frame —
// and write it out, the step the shipped contract never proved.
func firstFrameFile(t *testing.T) string {
	t.Helper()
	out := filepath.Join(t.TempDir(), "first-frame.txt")
	t.Setenv("CDT665_TEST_FIRST_FRAME_OUT", out)
	return out
}

// premiseAttemptPair reads the attempt number out of both halves of one
// premise pair. A re-delivery closes the pair the dead attempt opened, so the
// two numbers must agree.
func premiseAttemptPair(t *testing.T, eng *journal.Engine, runID, key string) (int, int) {
	t.Helper()
	at := func(raw []byte) int {
		var p struct {
			Attempt int `json:"attempt"`
		}
		if json.Unmarshal(raw, &p) != nil {
			return 0
		}
		return p.Attempt
	}
	e := effectByKey(t, eng, runID, key)
	return at(e.Intent), at(e.Outcome)
}

// readFirstFrame decodes the frame the seam child read from its stdin.
func readFirstFrame(t *testing.T, out string) (sessionID, premise string) {
	t.Helper()
	raw, err := os.ReadFile(out)
	if err != nil {
		t.Fatalf("first-frame output: %v", err)
	}
	var f struct {
		SessionID string `json:"session_id"`
		Premise   string `json:"premise"`
	}
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatalf("first frame is not JSON: %v (%q)", err, raw)
	}
	return f.SessionID, f.Premise
}

// seedDeadAttempt is a dead supervisor's trail for a takeover: claim, start,
// the closed attempt-1 spawn, the premise rows the dead agent left, and the
// handover pidfile that names a dead runner. closed picks the shape: the
// premise pair that landed, or the crash window's pending intent. The dead
// lease is aged past its stall limit, so the takeover is legal.
func seedDeadAttempt(t *testing.T, eng *journal.Engine, runID string, closed bool) {
	t.Helper()
	ctx := context.Background()
	m := run.New(eng, runID)
	m.Getenv = func(string) string { return stallLimit }
	token, err := m.Claim(ctx, deadOwner, runID, "orchestrate", "sonnet")
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Start(ctx, deadOwner, token, "sonnet"); err != nil {
		t.Fatal(err)
	}
	seq, _, err := m.Intent(ctx, deadOwner, token, fmt.Sprintf("agent:start:%s#1", runID),
		EffectStart, map[string]any{"command": "sh", "attempt": 1})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := m.Outcome(ctx, deadOwner, token, seq, EffectStart,
		map[string]any{"pid": 999999, "attempt": 1}); err != nil {
		t.Fatal(err)
	}
	key := fmt.Sprintf("agent:premise:%s#1", runID)
	intent := map[string]any{"premise": "the seeded premise", "attempt": 1}
	ps, _, err := m.Intent(ctx, deadOwner, token, key, EffectPremise, intent)
	if err != nil {
		t.Fatal(err)
	}
	if closed {
		if _, err := m.Outcome(ctx, deadOwner, token, ps, EffectPremise,
			map[string]any{"delivered": true, "attempt": 1}); err != nil {
			t.Fatal(err)
		}
	}
	if err := writePIDFile(runID, 999999, 999999); err != nil {
		t.Fatal(err)
	}
	time.Sleep(takeoverWait)
}

// AC1/AC2: the premise of a start is the session's first turn. The frame the
// child read carries the text and the captured session id, and the journal
// carries one closed pair for the attempt — the intent row and its outcome.
func TestSuperviseDeliversThePremiseAsTheFirstTurn(t *testing.T) {
	eng := newEngine(t)
	runID := "CDT-665"
	out := firstFrameFile(t)
	sc := &sessionCapture{}
	a := &Agent{Runner: Native{Stdout: sc, Stderr: io.Discard}}

	const premise = "Fix the redirect: the premise reaches the first turn."
	req := startReq(runID,
		`printf 'sess-1\n'; read l; printf '%s\n' "$l" > "$CDT665_TEST_FIRST_FRAME_OUT"`)
	req.Premise = premise
	req.PremiseFrame = premiseTestFrame
	if err := a.Supervise(context.Background(), eng, req); err != nil {
		t.Fatalf("supervise: %v", err)
	}

	sessionID, delivered := readFirstFrame(t, out)
	if sessionID != "sess-1" || delivered != premise {
		t.Errorf("first frame = (%q, %q), want the captured id and the premise",
			sessionID, delivered)
	}

	key := "agent:premise:" + runID + "#1"
	e := effectByKey(t, eng, runID, key)
	if e.Effect != EffectPremise || e.Pending() {
		t.Fatalf("premise effect = %+v, want a closed agent.premise row pair", e)
	}
	if !strings.Contains(string(e.Intent), `"premise":"`+premise+`"`) ||
		!strings.Contains(string(e.Intent), `"attempt":1`) {
		t.Errorf("intent %s does not carry the premise and the attempt", e.Intent)
	}
	if !strings.Contains(string(e.Outcome), `"delivered":true`) {
		t.Errorf("outcome %s does not close the delivery", e.Outcome)
	}
	if n := countKeyRows(t, eng, runID, key); n != 1 {
		t.Errorf("rows keyed %s = %d, want the one intent", key, n)
	}
	if n := countEffectRows(t, eng, runID, EffectPremise); n != 2 {
		t.Errorf("agent.premise rows = %d, want the intent and its outcome", n)
	}
	if st := state(t, eng, runID); st.Name() != "completed" {
		t.Errorf("state = %s, want completed", st.Name())
	}
}

// The ACP dependency: the premise frame names the session, and the id arrives
// in the host's session/new response. The delivery rides the tick that names
// the id — it never renders a frame with an empty session, and the earlier
// unnamed ticks harm nothing.
func TestSupervisePremiseWaitsForTheCapturedSessionID(t *testing.T) {
	eng := newEngine(t)
	runID := "CDT-665"
	out := firstFrameFile(t)
	r := &lateSessionRunner{
		Native: Native{Stdout: io.Discard, Stderr: io.Discard},
		id:     "sess-late", since: time.Now(), late: 350 * time.Millisecond,
	}
	a := &Agent{Runner: r}

	const premise = "The premise waits for the session it names."
	req := startReq(runID,
		`sleep 0.4; read l; printf '%s\n' "$l" > "$CDT665_TEST_FIRST_FRAME_OUT"`)
	req.Premise = premise
	req.PremiseFrame = premiseTestFrame
	if err := a.Supervise(context.Background(), eng, req); err != nil {
		t.Fatalf("supervise: %v", err)
	}

	sessionID, delivered := readFirstFrame(t, out)
	if sessionID != "sess-late" || delivered != premise {
		t.Errorf("first frame = (%q, %q), want the late id and the premise",
			sessionID, delivered)
	}
	if n := countEffectRows(t, eng, runID, EffectPremise); n != 2 {
		t.Errorf("agent.premise rows = %d, want one closed pair", n)
	}
}

// SPEC-044 CDT-671 AC1 narrows CDT-665 AC6's ride-on rule: the bounded poll
// still closes the pair undelivered with its reason (M17's record rule holds),
// and the run now lands in the named halt instead of riding on — a session
// that never took its premise never starts work.
func TestSupervisePremiseClosesUndeliveredPastTheSessionWait(t *testing.T) {
	eng := newEngine(t)
	runID := "CDT-665"
	a := &Agent{Runner: Native{Stdout: io.Discard, Stderr: io.Discard},
		PremiseSessionWait: 250 * time.Millisecond}

	req := startReq(runID, "sleep 1")
	req.Premise = "A premise no frame can carry."
	req.PremiseFrame = premiseTestFrame
	err := a.Supervise(context.Background(), eng, req)
	if !errors.Is(err, ErrPremiseUndelivered) {
		t.Fatalf("supervise err = %v, want %v", err, ErrPremiseUndelivered)
	}

	key := "agent:premise:" + runID + "#1"
	e := effectByKey(t, eng, runID, key)
	if e.Pending() {
		t.Fatalf("the premise intent is pending: %+v", e)
	}
	if !strings.Contains(string(e.Outcome), `"delivered":false`) {
		t.Errorf("outcome %s, want delivered false", e.Outcome)
	}
	if !strings.Contains(string(e.Outcome), "session") {
		t.Errorf("outcome %s names no cause for the undelivered premise", e.Outcome)
	}
	if n := countEffectRows(t, eng, runID, EffectPremise); n != 2 {
		t.Errorf("agent.premise rows = %d, want one closed pair", n)
	}
	h := haltedRow(t, eng, runID)
	if h.Reason != run.ReasonPremiseUndelivered {
		t.Errorf("halt reason = %q, want %q", h.Reason, run.ReasonPremiseUndelivered)
	}
	if !strings.Contains(h.Detail, "session") {
		t.Errorf("halt detail %q names no cause", h.Detail)
	}
}

// AC1/AC4: the CDT-600 dogfood shape. A runner that starts and stays silent —
// agent.start, then heartbeats only, stalled: false — halts by name past the
// premise bound instead of looking healthy forever. The closed undelivered
// pair stays the record, and the halt carries its retry budget.
func TestSuperviseSilentSessionHaltsPremiseUndelivered(t *testing.T) {
	eng := newEngine(t)
	runID := "CDT-671"
	// The bound is wider than the beat (half the 1 s stall limit), so the
	// journal carries the dogfood's shape before the halt: agent.start, then
	// heartbeats only.
	a := &Agent{Runner: Native{Stdout: io.Discard, Stderr: io.Discard},
		PremiseSessionWait: 1200 * time.Millisecond}

	// The child idles: the host opened no session and writes nothing. The
	// supervisor's own heartbeats keep the stall limit met, so nothing else
	// can name this run.
	req := startReq(runID, "sleep 30")
	req.Premise = "A premise the silent session never takes."
	req.PremiseFrame = premiseTestFrame
	done := supervise(t, a, eng, req)

	waitFor(t, eng, runID, func(st *journal.State) bool {
		return st.Status == journal.StatusHalted
	}, "the premise halt")
	if err := <-done; !errors.Is(err, ErrPremiseUndelivered) {
		t.Fatalf("supervise err = %v, want %v", err, ErrPremiseUndelivered)
	}

	st := state(t, eng, runID)
	if st.Name() != "halted:"+run.ReasonPremiseUndelivered {
		t.Fatalf("state = %s, want halted:%s", st.Name(), run.ReasonPremiseUndelivered)
	}
	if st.Halt.Budget != 1 || st.Halt.Remaining != 1 {
		t.Errorf("halt budget = %d/%d, want 1/1", st.Halt.Remaining, st.Halt.Budget)
	}
	// The ride-on journal shape stands: agent.start and heartbeats landed, and
	// the premise pair closed undelivered — the record, not a pending intent.
	if s := effectByKey(t, eng, runID, "agent:start:"+runID+"#1"); s.Pending() {
		t.Errorf("spawn pair = %+v, want the closed agent.start record", s)
	}
	if n := rowsByKind(t, eng, runID, journal.KindHeartbeat); n < 1 {
		t.Errorf("heartbeat rows = %d, want the heartbeats of a live supervisor", n)
	}
	e := effectByKey(t, eng, runID, "agent:premise:"+runID+"#1")
	if e.Pending() || !strings.Contains(string(e.Outcome), `"delivered":false`) {
		t.Errorf("premise pair = %+v, want the closed undelivered record", e)
	}
	if n := countEffectRows(t, eng, runID, EffectPremise); n != 2 {
		t.Errorf("agent.premise rows = %d, want one closed pair", n)
	}
}

// AC1 boundary: a start that carries no premise journals no premise row and
// never halts under this AC — the silent session of a premise-less start rides
// on exactly as before.
func TestSuperviseSilentSessionWithNoPremiseNeverHaltsPremiseUndelivered(t *testing.T) {
	eng := newEngine(t)
	runID := "CDT-671"
	a := &Agent{Runner: Native{Stdout: io.Discard, Stderr: io.Discard},
		PremiseSessionWait: 250 * time.Millisecond}

	if err := a.Supervise(context.Background(), eng, startReq(runID, "sleep 1")); err != nil {
		t.Fatalf("supervise: %v", err)
	}
	if n := countEffectRows(t, eng, runID, EffectPremise); n != 0 {
		t.Errorf("agent.premise rows = %d, want 0: a premise-less start journals none", n)
	}
	if st := state(t, eng, runID); st.Name() != "completed" {
		t.Errorf("state = %s, want completed: a premise-less start halts under no premise AC",
			st.Name())
	}
}

// AC3: a takeover re-adoption of a run whose premise pair landed sends no
// second turn. The child sits reading stdin — the 0-CPU shape of the defect —
// and the re-adoption writes it nothing at all, and journals no new row.
func TestSuperviseTakeoverSkipsAClosedPremiseRow(t *testing.T) {
	eng := newEngine(t)
	runID := "CDT-665"
	seedDeadAttempt(t, eng, runID, true)
	out := firstFrameFile(t)
	sc := &sessionCapture{}
	a := &Agent{Runner: Native{Stdout: sc, Stderr: io.Discard}}
	ctx := context.Background()

	req := startReq(runID, `printf 'sess-1\n'; cat > "$CDT665_TEST_FIRST_FRAME_OUT"`)
	req.Premise = "the seeded premise"
	req.PremiseFrame = premiseTestFrame
	done := supervise(t, a, eng, req)
	// waitRunner's record check passes on the dead attempt's handover record
	// (it names pid 999999), so wait for the re-adoption's own runner record
	// before stopping it — the way the orphan-kill test does.
	waitFor(t, eng, runID, func(st *journal.State) bool {
		if st.Status != journal.StatusRunning {
			return false
		}
		rec, err := readPIDFile(runID)
		return err == nil && rec.RunnerPID > 0 && rec.RunnerPID != 999999
	}, "the re-adoption's own runner record")

	if n := countEffectRows(t, eng, runID, EffectPremise); n != 2 {
		t.Errorf("agent.premise rows = %d, want the dead attempt's pair and no new row", n)
	}
	// End the run: the child blocks on stdin, which is what the delivery
	// would have written to.
	if err := a.Stop(ctx, eng, runID, 0); err != nil {
		t.Fatalf("stop: %v", err)
	}
	if err := <-done; err != nil {
		t.Fatalf("supervise: %v", err)
	}
	raw, err := os.ReadFile(out)
	if err != nil {
		t.Fatalf("first-frame output: %v", err)
	}
	if strings.TrimSpace(string(raw)) != "" {
		t.Errorf("the re-adoption re-sent the premise: %q", raw)
	}
}

// AC4: the crash window is the pending premise row the takeover performs. The
// frame the child read carries the journaled text — the re-spawn carries no
// premise of its own — and it lands exactly once, closing the row.
func TestSuperviseTakeoverRedeliversThePendingPremiseRow(t *testing.T) {
	eng := newEngine(t)
	runID := "CDT-665"
	seedDeadAttempt(t, eng, runID, false)
	out := firstFrameFile(t)
	sc := &sessionCapture{}
	a := &Agent{Runner: Native{Stdout: sc, Stderr: io.Discard}}

	req := startReq(runID,
		`printf 'sess-1\n'; read l; printf '%s\n' "$l" > "$CDT665_TEST_FIRST_FRAME_OUT"`)
	req.PremiseFrame = premiseTestFrame
	if err := a.Supervise(context.Background(), eng, req); err != nil {
		t.Fatalf("supervise: %v", err)
	}

	_, delivered := readFirstFrame(t, out)
	if delivered != "the seeded premise" {
		t.Errorf("first frame carries %q, want the premise of the pending row", delivered)
	}
	key := "agent:premise:" + runID + "#1"
	e := effectByKey(t, eng, runID, key)
	if e.Pending() {
		t.Fatalf("the pending premise row survived the re-delivery: %+v", e)
	}
	if !strings.Contains(string(e.Outcome), `"delivered":true`) {
		t.Errorf("outcome %s does not close the delivery", e.Outcome)
	}
	if n := countKeyRows(t, eng, runID, key); n != 1 {
		t.Errorf("rows keyed %s = %d, want the replayed intent, never a duplicate", key, n)
	}
	if n := countEffectRows(t, eng, runID, EffectPremise); n != 2 {
		t.Errorf("agent.premise rows = %d, want the seeded intent and its outcome", n)
	}
	// The trail names one attempt in both halves: the outcome closes the pair
	// the dead attempt opened, not the re-spawn's own count.
	if ia, oa := premiseAttemptPair(t, eng, runID, key); ia != 1 || oa != 1 {
		t.Errorf("premise pair carries attempt %d (intent) / %d (outcome), want 1/1 under %s",
			ia, oa, key)
	}
	if st := state(t, eng, runID); st.Name() != "completed" {
		t.Errorf("state = %s, want completed", st.Name())
	}
}

// A start that carries no premise journals nothing and writes nothing: the
// premise row belongs to the start that has a premise.
func TestSuperviseWithNoPremiseJournalsNoPremiseRow(t *testing.T) {
	eng := newEngine(t)
	runID := "CDT-665"
	a := nativeAgent()

	if err := a.Supervise(context.Background(), eng, startReq(runID, "sleep 0.2")); err != nil {
		t.Fatalf("supervise: %v", err)
	}
	if n := countEffectRows(t, eng, runID, EffectPremise); n != 0 {
		t.Errorf("agent.premise rows = %d, want 0: a start with no premise journals none", n)
	}
}

// haltForResume leaves a run parked in one named halt, its dead owner's lease
// aged past the stall limit — the shape a re-supervision meets.
func haltForResume(t *testing.T, eng *journal.Engine, runID, reason string) {
	t.Helper()
	ctx := context.Background()
	m := run.New(eng, runID)
	m.Getenv = func(string) string { return stallLimit }
	token, err := m.Claim(ctx, deadOwner, "CDT-644", "orchestrate", "sonnet")
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Start(ctx, deadOwner, token, "sonnet"); err != nil {
		t.Fatal(err)
	}
	if err := m.Halt(ctx, deadOwner, token, reason, "fixture"); err != nil {
		t.Fatal(err)
	}
	time.Sleep(takeoverWait)
}

// SPEC-045 M5: the supervision gate widens in place for the operator resume.
// Under the switch the run's current halt reason resumes through the one
// machine call; a start without it keeps refusing every halt but the watchdog's;
// and a spent budget (operator_halt, budget 0) stays fenced by the machine —
// the gate names no budget of its own.
func TestSuperviseOperatorResumeWidensTheGate(t *testing.T) {
	t.Run("the switch resumes the run's current halt", func(t *testing.T) {
		eng := newEngine(t)
		runID := "CDT-644"
		haltForResume(t, eng, runID, run.ReasonLeaseLost)
		req := startReq(runID, "exit 0")
		req.OperatorResume = true
		if err := nativeAgent().Supervise(context.Background(), eng, req); err != nil {
			t.Fatalf("supervise: %v", err)
		}
		if got := state(t, eng, runID).Name(); got != "completed" {
			t.Fatalf("state = %s, want completed through the operator resume", got)
		}
		if n := rowsByKind(t, eng, runID, journal.KindRunResumed); n != 1 {
			t.Errorf("run_resumed rows = %d, want 1", n)
		}
	})

	t.Run("without the switch the halt is refused", func(t *testing.T) {
		eng := newEngine(t)
		runID := "CDT-644"
		haltForResume(t, eng, runID, run.ReasonLeaseLost)
		err := nativeAgent().Supervise(context.Background(), eng, startReq(runID, "exit 0"))
		if !errors.Is(err, ErrHaltState) {
			t.Fatalf("supervise err = %v, want ErrHaltState", err)
		}
		if n := rowsByKind(t, eng, runID, journal.KindRunResumed); n != 0 {
			t.Errorf("run_resumed rows = %d, want none", n)
		}
	})

	t.Run("a spent budget stays fenced by the machine", func(t *testing.T) {
		eng := newEngine(t)
		runID := "CDT-644"
		haltForResume(t, eng, runID, run.ReasonOperatorHalt)
		req := startReq(runID, "exit 0")
		req.OperatorResume = true
		err := nativeAgent().Supervise(context.Background(), eng, req)
		if !errors.Is(err, journal.ErrBudgetExhausted) {
			t.Fatalf("supervise err = %v, want journal.ErrBudgetExhausted", err)
		}
		if got := state(t, eng, runID).Name(); got != "halted:operator_halt" {
			t.Errorf("state = %s, want the halt a spent budget leaves", got)
		}
	})
}

// SPEC-045 M4: a claimed run takes the stop verb. It holds no recorded runner,
// so the stop is the journal trail alone — the named halt, no signal, and no
// agent.stop row that would imply one.
func TestStopAClaimedRunJournalsTheHaltAlone(t *testing.T) {
	eng := newEngine(t)
	runID := "CDT-644"
	ctx := context.Background()
	m := run.New(eng, runID)
	m.Getenv = func(string) string { return stallLimit }
	if _, err := m.Claim(ctx, deadOwner, "CDT-644", "orchestrate", "sonnet"); err != nil {
		t.Fatal(err)
	}

	if err := nativeAgent().Stop(ctx, eng, runID, time.Second); err != nil {
		t.Fatalf("stop a claimed run: %v", err)
	}
	if got := state(t, eng, runID).Name(); got != "halted:operator_halt" {
		t.Errorf("state = %s, want halted:operator_halt", got)
	}
	if n := countEffectRows(t, eng, runID, EffectStop); n != 0 {
		t.Errorf("agent.stop rows = %d, want none — nothing is signalled", n)
	}
	if n := rowsByKind(t, eng, runID, journal.KindRunHalted); n != 1 {
		t.Errorf("run_halted rows = %d, want exactly one", n)
	}
	if _, err := os.Stat(pidPath(runID)); !os.IsNotExist(err) {
		t.Errorf("pidfile stat err = %v, want not exist", err)
	}
}

// ---------------------------------------------------------------------------
// SPEC-044 CDT-679 — the client handshake opens a Grok ACP session
// ---------------------------------------------------------------------------

// acpCapture is the test shape of hostadapter.Capture for the ACP transport:
// it reads result.sessionId off a response frame and the JSON-RPC error off
// the session/new answer, satisfying SessionSource and HandshakeSource the way
// the real capture does. The real parser and its recorded transcript live in
// control-plane/hostadapter — the agent asks for the readings and never parses
// host output itself.
// COPY-ACCEPTED: divergence-expected — a capture-less agent test needs the
// source shape locally; hostadapter imports this package, so the real parser
// cannot be imported here. It reads the same frame fields as
// hostadapter.Capture; the frames it parses come from the shared fixture.
type acpCapture struct {
	mu      sync.Mutex
	line    []byte
	id      string
	handErr string
}

// Write consumes the stream byte by byte and parses each complete line: a
// frame arrives split across writes (the runner drains in 32 KB chunks and the
// probe's response frames are larger than that), so a partial frame is
// buffered, never parsed.
func (c *acpCapture) Write(p []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, b := range p {
		if b == '\n' {
			c.consumeLine()
			c.line = c.line[:0]
			continue
		}
		c.line = append(c.line, b)
	}
	return len(p), nil
}

func (c *acpCapture) consumeLine() {
	line := strings.TrimSpace(string(c.line))
	if line == "" || line[0] != '{' {
		return
	}
	var frame struct {
		ID     *int `json:"id"`
		Result struct {
			SessionID string `json:"sessionId"`
		} `json:"result"`
		Error *struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if json.Unmarshal([]byte(line), &frame) != nil {
		return
	}
	switch {
	case frame.Result.SessionID != "" && c.id == "":
		c.id = frame.Result.SessionID
	case c.id == "" && frame.ID != nil && *frame.ID == 1 && frame.Error != nil:
		c.handErr = fmt.Sprintf("code %d: %s", frame.Error.Code, frame.Error.Message)
	}
}

func (c *acpCapture) SessionID() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.id
}

func (c *acpCapture) HandshakeError() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.handErr
}

// The probe transcript's layout: the frames the agent answered with, then the
// three frames the probe's client sent, with acpCWDToken where the probe named
// its scratch directory.
const (
	acpServerFrameCount = 4
	acpClientFrameCount = 3
	acpCWDToken         = "__CWD__"
)

// acpFixturePath is the recorded probe transcript, read across the package
// boundary: the fake child answers from it and the client frames come from it
// (SPEC-044 CDT-679 AC4). control-plane/hostadapter owns the file and imports
// this package, so no test helper crosses that way — the fixture is the one
// home of the probe's bytes for both lanes.
func acpFixturePath() string {
	p, err := filepath.Abs(filepath.Join("..", "hostadapter", "testdata",
		"grok-acp-session-frames.jsonl"))
	if err != nil {
		panic(err)
	}
	return p
}

// acpFixture is acpFixturePath with the suite's own failure verb.
func acpFixture(t *testing.T) string {
	t.Helper()
	p := acpFixturePath()
	if _, err := os.Stat(p); err != nil {
		t.Fatalf("the recorded probe transcript: %v", err)
	}
	return p
}

// acpFixtureClientFrames is the transcript's client half, read once. A missing
// or reshaped fixture is a broken suite, so it fails loudly from a renderer the
// product calls with no *testing.T in hand.
var acpFixtureClientFrames = sync.OnceValue(func() []string {
	raw, err := os.ReadFile(acpFixturePath())
	if err != nil {
		panic("read the recorded probe transcript: " + err.Error())
	}
	var lines []string
	for _, l := range strings.Split(string(raw), "\n") {
		if strings.TrimSpace(l) != "" {
			lines = append(lines, l)
		}
	}
	if len(lines) != acpServerFrameCount+acpClientFrameCount {
		panic(fmt.Sprintf("the probe transcript carries %d frames, want the %d recorded "+
			"answers and the %d client frames",
			len(lines), acpServerFrameCount, acpClientFrameCount))
	}
	return lines[acpServerFrameCount:]
})

// acpHandshakeFrames is the P-GK-ACP-1 client handshake — the shapes the suite
// feeds a fake child (SPEC-044 CDT-679 AC4) — read from the transcript
// hostadapter owns, naming the directory this test's child inherits.
// control-plane/hostadapter owns the encoder and pins these bytes in
// TestGrokHandshakeFramesAreTheProbeShapes; reading them from the fixture is
// what keeps the two lanes from drifting.
func acpHandshakeFrames(cwd string) []string {
	out := make([]string, acpClientFrameCount)
	for i, l := range acpFixtureClientFrames() {
		out[i] = strings.ReplaceAll(l, acpCWDToken, cwd)
	}
	return out
}

// acpFiles points the seam child's stdin capture and frame outputs at a
// directory of its own.
func acpFiles(t *testing.T) (framesOut, promptOut string) {
	t.Helper()
	dir := t.TempDir()
	framesOut = filepath.Join(dir, "handshake.txt")
	promptOut = filepath.Join(dir, "prompt.txt")
	t.Setenv("CDT679_TEST_HANDSHAKE_OUT", framesOut)
	t.Setenv("CDT679_TEST_PROMPT_OUT", promptOut)
	t.Setenv("CDT679_TEST_TRANSCRIPT", acpFixture(t))
	return framesOut, promptOut
}

// readFramesLines returns the frames one child read, in order.
func readFramesLines(t *testing.T, path string) []string {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("frames output: %v", err)
	}
	return strings.Split(strings.TrimRight(string(raw), "\n"), "\n")
}

// haltedRow reads the run's halt record.
func haltedRow(t *testing.T, eng *journal.Engine, runID string) journal.Halt {
	t.Helper()
	st := state(t, eng, runID)
	if st.Halt == nil {
		t.Fatalf("run %s carries no halt (state %s)", runID, st.Name())
	}
	return *st.Halt
}

// AC1/AC2: the handshake rides the spawn in order, the session id is captured
// off the transcript's session/new response on the CDT-661 path, and the
// premise renders as the frame that names it — the delivery rides the tick
// that captured the id, and the pair lands once under the live attempt.
func TestSuperviseWritesTheHandshakeThenDeliversThePremise(t *testing.T) {
	eng := newEngine(t)
	runID := "CDT-679"
	framesOut, promptOut := acpFiles(t)
	const wantSession = "01a20e68-d7e1-7bc0-9eb8-915deef0e64b"

	cap := &acpCapture{}
	a := &Agent{Runner: Native{Stdout: cap, Stderr: io.Discard}}
	req := startReq(runID,
		`read a; read b; read c; `+
			`printf '%s\n%s\n%s\n' "$a" "$b" "$c" > "$CDT679_TEST_HANDSHAKE_OUT"; `+
			`sed -n '1p;4p' "$CDT679_TEST_TRANSCRIPT"; `+
			`read p; printf '%s\n' "$p" > "$CDT679_TEST_PROMPT_OUT"`)
	req.Premise = "Fix the redirect: the handshake opens the session."
	req.PremiseFrame = premiseTestFrame
	req.Handshake = acpHandshakeFrames

	if err := a.Supervise(context.Background(), eng, req); err != nil {
		raw, _ := os.ReadFile(framesOut)
		t.Fatalf("supervise: %v (capture id %q, handshake error %q, frames read: %q)",
			err, cap.SessionID(), cap.HandshakeError(), raw)
	}

	wd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	got := readFramesLines(t, framesOut)
	want := acpHandshakeFrames(wd)
	if len(got) != len(want) {
		t.Fatalf("the child read %d frames, want the three the probe sent: %v", len(got), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("frame %d = %s\n            want %s", i, got[i], want[i])
		}
	}

	key := "agent:handshake:" + runID + "#1"
	e := effectByKey(t, eng, runID, key)
	if e.Effect != EffectHandshake || e.Pending() {
		t.Fatalf("handshake effect = %+v, want a closed agent.handshake row pair", e)
	}
	if !strings.Contains(string(e.Intent), `"cwd":"`+wd+`"`) {
		t.Errorf("intent %s does not carry the directory the child inherited", e.Intent)
	}
	for _, raw := range [][]byte{e.Intent, e.Outcome} {
		if !strings.Contains(string(raw), `"attempt":1`) {
			t.Errorf("row %s does not carry the attempt", raw)
		}
	}
	if !strings.Contains(string(e.Outcome), `"frames":3`) {
		t.Errorf("outcome %s does not record the frames written", e.Outcome)
	}
	if !strings.Contains(string(e.Outcome), `"delivered":true`) {
		t.Errorf("outcome %s does not close the delivery", e.Outcome)
	}
	if n := countKeyRows(t, eng, runID, key); n != 1 {
		t.Errorf("rows keyed %s = %d, want the one intent", key, n)
	}
	if n := countEffectRows(t, eng, runID, EffectHandshake); n != 2 {
		t.Errorf("agent.handshake rows = %d, want the intent and its outcome", n)
	}

	// AC2: the capture path is CDT-661's, unchanged — the id off the
	// session/new response, journaled once for the attempt.
	sess := effectByKey(t, eng, runID, "agent:session:"+runID+"#1")
	if !strings.Contains(string(sess.Outcome), `"session_id":"`+wantSession+`"`) {
		t.Errorf("session outcome %s, want the transcript's session id", sess.Outcome)
	}

	praw, err := os.ReadFile(promptOut)
	if err != nil {
		t.Fatalf("premise output: %v", err)
	}
	sessionID, delivered := readFirstFrame(t, promptOut)
	if sessionID != wantSession || delivered != req.Premise {
		t.Errorf("premise frame = (%q, %q), want the captured id and the premise (%q) — got %s",
			sessionID, delivered, req.Premise, praw)
	}
	premise := effectByKey(t, eng, runID, "agent:premise:"+runID+"#1")
	if !strings.Contains(string(premise.Outcome), `"delivered":true`) {
		t.Errorf("premise outcome %s, want delivered true on the capture tick", premise.Outcome)
	}
	if st := state(t, eng, runID); st.Name() != "completed" {
		t.Errorf("state = %s, want completed", st.Name())
	}
}

// AC3: a session/new response that carries a JSON-RPC error stops the child and
// lands the run in the named halt, on the tick that read the refusal — never
// idle as running.
func TestSuperviseHandshakeHaltsOnTheSessionNewError(t *testing.T) {
	eng := newEngine(t)
	runID := "CDT-679"
	acpFiles(t)
	cap := &acpCapture{}
	a := &Agent{Runner: Native{Stdout: cap, Stderr: io.Discard}}

	// The child answers the handshake with the refusal, then idles: an ACP
	// child that never opened its session waits forever, which is the defect.
	req := startReq(runID,
		`read a; read b; read c; `+
			`printf '%s\n' '{"jsonrpc":"2.0","id":1,"error":{"code":-32603,`+
			`"message":"session load was superseded"}}'; `+
			`sleep 30`)
	req.Handshake = acpHandshakeFrames

	err := a.Supervise(context.Background(), eng, req)
	if !errors.Is(err, ErrHandshakeFailed) {
		t.Fatalf("supervise err = %v, want ErrHandshakeFailed", err)
	}
	st := state(t, eng, runID)
	if st.Name() != "halted:handshake_failed" {
		t.Fatalf("state = %s, want the named halt", st.Name())
	}
	h := haltedRow(t, eng, runID)
	if h.Reason != run.ReasonHandshakeFailed ||
		!strings.Contains(h.Detail, "session/new") ||
		!strings.Contains(h.Detail, "session load was superseded") {
		t.Errorf("halt = %+v, want a reason that names the handshake failure", h)
	}
	if n := rowsByKind(t, eng, runID, journal.KindRunHalted); n != 1 {
		t.Errorf("run_halted rows = %d, want exactly one", n)
	}
	if rec, err := readPIDFile(runID); err != nil || rec.RunnerPID != 0 {
		t.Errorf("pidfile survived the halt: %+v (err %v)", rec, err)
	}
}

// AC3: a child that dies before the session id lands is the same named halt —
// not the exit code, and never a run left running on a dead host.
func TestSuperviseHandshakeHaltsWhenTheChildDiesBeforeTheSessionID(t *testing.T) {
	eng := newEngine(t)
	runID := "CDT-679"
	acpFiles(t)
	cap := &acpCapture{}
	a := &Agent{Runner: Native{Stdout: cap, Stderr: io.Discard}}

	req := startReq(runID, `read a; read b; read c; exit 3`)
	req.Handshake = acpHandshakeFrames

	err := a.Supervise(context.Background(), eng, req)
	if !errors.Is(err, ErrHandshakeFailed) {
		t.Fatalf("supervise err = %v, want ErrHandshakeFailed", err)
	}
	st := state(t, eng, runID)
	if st.Name() != "halted:handshake_failed" {
		t.Fatalf("state = %s, want the named halt, not the exit code's failure", st.Name())
	}
	h := haltedRow(t, eng, runID)
	if !strings.Contains(h.Detail, "exited") || !strings.Contains(h.Detail, "session/new") {
		t.Errorf("halt = %+v, want a detail that names the early child death", h)
	}
	if n := countEffectRows(t, eng, runID, EffectHandshake); n != 2 {
		t.Errorf("agent.handshake rows = %d, want the closed pair the write landed", n)
	}
}

// AC3: a capture that is still empty at the bounded wait is the named halt. The
// child answered initialize and nothing else — the shape of a host that waits
// for a client that already spoke.
func TestSuperviseHandshakeHaltsPastTheBoundedWait(t *testing.T) {
	eng := newEngine(t)
	runID := "CDT-679"
	acpFiles(t)
	cap := &acpCapture{}
	a := &Agent{Runner: Native{Stdout: cap, Stderr: io.Discard},
		PremiseSessionWait: 250 * time.Millisecond}

	req := startReq(runID,
		`read a; read b; read c; sed -n '1p' "$CDT679_TEST_TRANSCRIPT"; sleep 30`)
	req.Handshake = acpHandshakeFrames

	err := a.Supervise(context.Background(), eng, req)
	if !errors.Is(err, ErrHandshakeFailed) {
		t.Fatalf("supervise err = %v, want ErrHandshakeFailed", err)
	}
	st := state(t, eng, runID)
	if st.Name() != "halted:handshake_failed" {
		t.Fatalf("state = %s, want the named halt, never an idle running run", st.Name())
	}
	h := haltedRow(t, eng, runID)
	if !strings.Contains(h.Detail, "no captured session id within 250ms") {
		t.Errorf("halt = %+v, want a detail that names the bounded wait", h)
	}
	if cap.SessionID() != "" {
		t.Errorf("capture = %q, want empty: the initialize response names no session",
			cap.SessionID())
	}
	if cap.HandshakeError() != "" {
		t.Errorf("HandshakeError = %q, want empty: no response refused", cap.HandshakeError())
	}
}

// AC1 boundary: a start that names no handshake writes no frames to the child
// and journals no handshake row — Claude Code and omp open their sessions on
// their own transports, and their starts are unchanged.
func TestSuperviseWithNoHandshakeJournalsNoHandshakeRow(t *testing.T) {
	eng := newEngine(t)
	runID := "CDT-679"
	a := nativeAgent()

	if err := a.Supervise(context.Background(), eng,
		startReq(runID, `printf 'sess-1\n'; sleep 0.2`)); err != nil {
		t.Fatalf("supervise: %v", err)
	}
	if n := countEffectRows(t, eng, runID, EffectHandshake); n != 0 {
		t.Errorf("agent.handshake rows = %d, want 0: this start names no handshake", n)
	}
	if st := state(t, eng, runID); st.Name() != "completed" {
		t.Errorf("state = %s, want completed", st.Name())
	}
}

// AC3 boundary: an exit is judged from the capture, never from the loop's tick
// snapshot. The capture names the session id from the first moment and the
// child exits before the 100 ms poll tick ever turns, so the loop's snapshot is
// still empty when the exit lands — the run completes, it is not labelled a
// handshake failure (SPEC-044 CDT-679).
func TestSuperviseHandshakeExitWithACapturedIDCompletesTheRun(t *testing.T) {
	eng := newEngine(t)
	runID := "CDT-679"
	acpFiles(t)
	a := &Agent{Runner: &lateSessionRunner{
		Native: Native{Stdout: io.Discard, Stderr: io.Discard},
		id:     "sess-race", since: time.Now(), late: -time.Second,
	}}

	req := startReq(runID, `exit 0`)
	req.Handshake = acpHandshakeFrames

	if err := a.Supervise(context.Background(), eng, req); err != nil {
		t.Fatalf("supervise: %v", err)
	}
	if st := state(t, eng, runID); st.Name() != "completed" {
		t.Fatalf("state = %s, want completed: the capture already held the session id, "+
			"so the exit is the run's own, not the handshake's", st.Name())
	}
	if n := rowsByKind(t, eng, runID, journal.KindRunHalted); n != 0 {
		t.Errorf("run_halted rows = %d, want none", n)
	}
}

// ---------------------------------------------------------------------------
// SPEC-045 CDT-675 — a late child exit cannot overwrite an operator halt
// ---------------------------------------------------------------------------

// CDT-675 (TL review P3 d): the stop verb closes its own pair — intent,
// signal, outcome — and then journals the named halt, so the state the exit
// races is halted:operator_halt. That state is not terminal and its budget is
// spent, and run_failed is legal from a spent halt, so an unfenced late exit
// from the SIGTERM'd child flips the run the operator just stopped to failed.
func TestRunnerExitAfterOperatorHaltLeavesTheHalt(t *testing.T) {
	eng := newEngine(t)
	runID := "CDT-675"
	ctx := context.Background()
	a := nativeAgent()
	owner := a.owner()
	m := run.New(eng, runID)
	m.Getenv = func(string) string { return stallLimit }
	token, err := m.Claim(ctx, owner, "CDT-675", "orchestrate", "sonnet")
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Start(ctx, owner, token, "sonnet"); err != nil {
		t.Fatal(err)
	}
	// The stop verb's trail in its own order (Agent.Stop): journal the intent,
	// signal the child, close the outcome, journal the halt. The pair is closed
	// by the time the halt lands, so pendingEffect(EffectStop) is false on the
	// exit's read — the fence the halt reason has to supply. The verbs carry the
	// lease owner, which is this supervisor's own identity: the exit that follows
	// is its own, so it rides the same token.
	seq, _, err := m.Intent(ctx, owner, token, "agent:stop:"+runID+"#1", EffectStop,
		map[string]any{"grace_s": 1, "pid": 1234})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := m.Outcome(ctx, owner, token, seq, EffectStop,
		map[string]any{"stopped": true}); err != nil {
		t.Fatal(err)
	}
	if err := m.Halt(ctx, owner, token, run.ReasonOperatorHalt,
		"stopped by the operator (pid 1234)"); err != nil {
		t.Fatal(err)
	}
	if got := state(t, eng, runID).Name(); got != "halted:operator_halt" {
		t.Fatalf("state after the stop verb = %s, want halted:operator_halt", got)
	}
	if err := writePIDFile(runID, 1234, os.Getpid()); err != nil {
		t.Fatal(err)
	}

	// The late exit: a real child that exits nonzero, the shape of the wait
	// result the SIGTERM'd runner carries.
	proc, err := nativeAgent().Runner.Start(Spec{Command: "sh", Args: []string{"-c", "exit 3"}})
	if err != nil {
		t.Fatal(err)
	}
	exitErr := proc.Wait()

	if err := a.runnerExit(ctx, m, token, runID, proc, exitErr, &handshake{}); err != nil {
		t.Fatalf("runnerExit: %v", err)
	}
	if got := state(t, eng, runID).Name(); got != "halted:operator_halt" {
		t.Errorf("state = %s, want halted:operator_halt — the halt the operator named stands", got)
	}
	if n := rowsByKind(t, eng, runID, journal.KindRunFailed); n != 0 {
		t.Errorf("run_failed rows = %d, want none — the exit does not fail a halted run", n)
	}
	if _, err := os.Stat(pidPath(runID)); !os.IsNotExist(err) {
		t.Errorf("pidfile stat err = %v, want not exist", err)
	}
}
