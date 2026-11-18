package agent

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
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
