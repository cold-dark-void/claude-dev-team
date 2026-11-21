package killtest

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/cold-dark-void/claude-dev-team/control-plane/agent"
	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
	"github.com/cold-dark-void/claude-dev-team/control-plane/run"
)

// restartBin is the restart helper binary, built once per suite run beside the
// sacrificial helper: the kill test never runs `go build` inside a test
// (SPEC-044 M14).
var restartBin string

// AC13 with AC11/M11: the restart kill test. A real runner child runs under a
// real chiefd-class supervisor; the supervisor dies by SIGKILL mid-run; the
// restarted chiefd takes the run over and completes it exactly once.
//
// Nothing is simulated, and that is what makes this a falsification gate: the
// killed process owns a real lease over an open journal, the runner child
// outlives it and is a real orphan the takeover must stop, the re-spawn is a
// second real process, and exactly-once is read off the journal file and the
// runner-launch record — the two things an operator can audit.
//
// The trail is SPEC-044 M11's, asserted as ordered journal rows:
// lease_acquired (reason takeover, token+1) → agent.kill (the orphan stop) →
// agent.start (new pid, attempt N+1) → stint_started (attempt N+1) →
// run_completed. The crash journals nothing (P1, M8): no halt row of any reason
// exists between the kill and the takeover.
//
// SPEC-044's Test section leaves the kill test the crash-to-completion trail;
// the scan's repetition (AC2) and its refusal matrix (AC4–AC6, AC10) are the
// chief suite's, in chief/takeover_test.go.
func TestRestartTakeoverCompletesTheRunOnce(t *testing.T) {
	c := newRestartCase(t)

	// 1. A real supervisor runs the run: claim → start → spawn → stint, with a
	//    runner process alive under it and a lease beating every second.
	sup := c.startHelper(t, ModeSupervise)
	supPID := c.waitMidRun(t, sup)

	ctx := context.Background()
	eng := c.openEngine(t)
	m := run.New(eng, RestartRunID)
	before, err := m.State(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if before.Name() != "running" || before.Token != 1 || before.Stint != 1 {
		t.Fatalf("pre-kill state = %s token %d stint %d, want running token 1 stint 1",
			before.Name(), before.Token, before.Stint)
	}
	first := startLaunches(t, eng)
	if len(first) != 1 {
		t.Fatalf("spawn records before the kill = %d, want 1", len(first))
	}
	attempt1 := first[0]
	if attempt1.attempt != 1 || attempt1.pid <= 0 || attempt1.outcomeSeq == 0 {
		t.Fatalf("attempt 1 = %+v, want a closed spawn outcome with a live pid", attempt1)
	}
	rec := readPIDRecord(t, c.dir, RestartRunID)
	if rec.RunnerPID != attempt1.pid || rec.SupervisorPID != supPID {
		t.Fatalf("pidfile records runner %d supervisor %d, want %d/%d — this is the "+
			"handover the takeover's orphan probe reads", rec.RunnerPID,
			rec.SupervisorPID, attempt1.pid, supPID)
	}

	// 2. SIGKILL the supervisor. The runner is its child, so the runner
	//    survives — the orphan the takeover owes its agent.kill row to. The
	//    node's init reaps that runner when the takeover stops it (the
	//    container init in the CI lane), which is what lets the stop confirm
	//    the death through the signal-0 probe.
	killBySIGKILL(t, sup)
	if !processAlive(attempt1.pid) {
		t.Fatalf("runner pid %d died with its supervisor; this case has no orphan to "+
			"take over", attempt1.pid)
	}

	// 3. P1's shape: the run sits in `running` on a stale lease with no halt
	//    row — no watchdog is alive to name one, and a shutdown journals
	//    nothing (M8).
	st, err := m.State(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if st.Name() != "running" {
		t.Fatalf("state after the kill = %s, want running (SPEC-044 P1)", st.Name())
	}
	if n := countKind(rows(t, eng), journal.KindRunHalted); n != 0 {
		t.Fatalf("run_halted rows after the kill = %d, want 0 (SPEC-044 M8/AC15)", n)
	}
	lease := c.waitLeaseExpired(t, m)
	t.Logf("killed: supervisor pid %d is gone; the lease of %s expired (token %d, "+
		"limit %ds)", supPID, lease.Owner, lease.Token, lease.StallLimitS)

	// 4. The restart: one takeover pass, then the taken-over run runs to its
	//    end under the restarted chiefd.
	rep := c.runRestart(t)
	if len(rep.Taken) != 1 || rep.Taken[0].RunID != RestartRunID {
		t.Fatalf("taken = %+v, want exactly %s", rep.Taken, RestartRunID)
	}
	if got := rep.Taken[0]; got.State != "running" || got.Host != string(RestartHost) {
		t.Errorf("taken run = %+v, want found in `running` on host %s (the host the "+
			"run's own start record names)", got, RestartHost)
	}
	if len(rep.Skipped) != 0 || len(rep.Refused) != 0 || len(rep.Unconfirmed) != 0 {
		t.Errorf("skipped/refused/unconfirmed = %+v / %+v / %+v, want none",
			rep.Skipped, rep.Refused, rep.Unconfirmed)
	}
	if rep.State != "completed" {
		t.Fatalf("state the restarted chiefd finished in = %q, want completed", rep.State)
	}

	// 5. Exactly once, on the journal and on the external record.
	assertRestartTrail(t, eng, attempt1)

	after, err := m.State(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if after.Name() != "completed" {
		t.Errorf("final state = %s, want completed", after.Name())
	}
	if after.Token != 2 || after.LeaseTakeovers != 1 || after.ClaimCount != 1 {
		t.Errorf("token/takeovers/claims = %d/%d/%d, want 2/1/1 (one takeover at token+1)",
			after.Token, after.LeaseTakeovers, after.ClaimCount)
	}
	if after.Stint != 2 {
		t.Errorf("stints = %d, want 2 (attempt N+1 after the takeover)", after.Stint)
	}
	if pend := after.PendingEffects(); len(pend) != 0 {
		t.Errorf("effects left pending: %+v, want none", pend)
	}
	if _, err := m.ReadLease(ctx); !errors.Is(err, journal.ErrNoLease) {
		t.Errorf("lease after the completion: err = %v, want journal.ErrNoLease", err)
	}
	if launches := c.runnerLaunches(t); launches != 2 {
		t.Errorf("runner launches = %d, want 2: the killed attempt and the takeover's "+
			"re-spawn. Any other count is a double spawn or a run that never restarted",
			launches)
	}
	if processAlive(attempt1.pid) {
		t.Errorf("orphan runner pid %d is still alive after the takeover's orphan stop",
			attempt1.pid)
	}
	if pid := lastStartPID(t, eng); processAlive(pid) {
		t.Errorf("re-spawned runner pid %d is still alive after the completion", pid)
	}
	if _, err := os.Stat(pidPathIn(c.dir, RestartRunID)); !os.IsNotExist(err) {
		t.Errorf("the pidfile survived the completion (%v); a finished run's record goes", err)
	}
	t.Logf("exactly-once across a SIGKILL: 1 run_completed, 2 runner launches, " +
		"token 1→2, stints 1→2")
}

// restartCase is one restart-kill case: a private directory that holds the
// journal, the agent state root, the host-session stand-in, and the reports.
type restartCase struct {
	dir        string
	dbPath     string
	countPath  string
	readyPath  string
	reportPath string
}

func newRestartCase(t *testing.T) *restartCase {
	t.Helper()
	dir := t.TempDir()
	c := &restartCase{
		dir:        dir,
		dbPath:     filepath.Join(dir, "run.db"),
		countPath:  filepath.Join(dir, "runner-launches"),
		readyPath:  filepath.Join(dir, "supervisor-ready"),
		reportPath: filepath.Join(dir, "restart-report.json"),
	}
	bin := filepath.Join(dir, "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatalf("create %s: %v", bin, err)
	}
	host := filepath.Join(bin, RestartHostCLI)
	if err := os.WriteFile(host, []byte(hostSessionCLI), 0o755); err != nil {
		t.Fatalf("write the host-session stand-in: %v", err)
	}
	// A case that fails before the takeover leaves the runner child parented to
	// a dead supervisor, and nothing else stops it: the pidfile is the only
	// handle on it. On the happy path the completion removes the record, so
	// this finds nothing to do.
	t.Cleanup(func() {
		raw, err := os.ReadFile(pidPathIn(dir, RestartRunID))
		if err != nil {
			return
		}
		var rec pidRecord
		if json.Unmarshal(raw, &rec) == nil && rec.RunnerPID > 0 {
			_ = syscall.Kill(rec.RunnerPID, syscall.SIGKILL)
		}
	})
	return c
}

// hostSessionCLI is the host session stand-in: the runner process the node
// agent spawns, records, and supervises. It carries a real host CLI's name so
// the takeover can derive a host from the run's start record
// (chief.hostByCommand), and it is a shell script so the test needs no host CLI
// installed on the lane.
//
// Launch 1 stays alive: it must outlive its SIGKILLed supervisor so the
// takeover's orphan probe finds it live and stops it. SIGTERM ends it, which is
// what the orphan stop waits for. Launch 2 exits clean, and the node agent's
// terminal step completes the run.
const hostSessionCLI = `#!/bin/sh
# Host-session stand-in of the CDT-660 restart kill test. The count file is the
# external record of how many runner processes spawned.
n=0
if [ -f "$` + EnvRestartHostCount + `" ]; then
	n=$(cat "$` + EnvRestartHostCount + `")
fi
n=$((n + 1))
printf '%s\n' "$n" > "$` + EnvRestartHostCount + `"
if [ "$n" -le 1 ]; then
	trap 'exit 0' TERM
	while :; do sleep 1; done
fi
exit 0
`

// command builds one helper invocation. Every value goes through the
// environment as its own entry, never as shell text. The journal is located at
// $DEVTEAM_RUN_DB and the state root at $DEVTEAM_MROOT (AC13), both inside
// t.TempDir().
func (c *restartCase) command(mode string) *exec.Cmd {
	cmd := exec.Command(restartBin)
	cmd.Env = append(os.Environ(),
		EnvRestartMode+"="+mode,
		EnvRestartRunID+"="+RestartRunID,
		EnvRestartHostCount+"="+c.countPath,
		"DEVTEAM_RUN_DB="+c.dbPath,
		"DEVTEAM_MROOT="+c.dir,
		"DEVTEAM_STALL_LIMIT="+RestartStallLimitSeconds,
		"PATH="+filepath.Join(c.dir, "bin")+string(os.PathListSeparator)+os.Getenv("PATH"),
	)
	switch mode {
	case ModeSupervise:
		cmd.Env = append(cmd.Env, EnvRestartReady+"="+c.readyPath)
	case ModeRestart:
		cmd.Env = append(cmd.Env, EnvRestartReport+"="+c.reportPath)
	}
	return cmd
}

// startHelper starts the supervisor with its output on the test's own streams,
// so a case that will not start is diagnosable from the test log.
func (c *restartCase) startHelper(t *testing.T, mode string) *exec.Cmd {
	t.Helper()
	cmd := c.command(mode)
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	if err := cmd.Start(); err != nil {
		t.Fatalf("start the %s helper: %v", mode, err)
	}
	t.Cleanup(func() {
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		// The kill step reaps the supervisor on the happy path; this is the
		// path for a case that failed before it got there.
		_ = cmd.Wait()
	})
	return cmd
}

// waitMidRun returns the supervisor's pid once the helper has reported the run
// mid-run — the point the harness kills at.
func (c *restartCase) waitMidRun(t *testing.T, cmd *exec.Cmd) int {
	t.Helper()
	deadline := time.Now().Add(RestartReadyWait)
	for {
		raw, err := os.ReadFile(c.readyPath)
		if err == nil {
			pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
			if err != nil {
				t.Fatalf("ready file %q: %v", raw, err)
			}
			if pid != cmd.Process.Pid {
				t.Fatalf("the ready file names pid %d; the helper is pid %d",
					pid, cmd.Process.Pid)
			}
			return pid
		}
		if !os.IsNotExist(err) {
			t.Fatalf("read the ready file: %v", err)
		}
		if time.Now().After(deadline) {
			t.Fatalf("the supervisor reported no mid-run position within %s (last "+
				"read error %v)", RestartReadyWait, err)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// killBySIGKILL kills the supervisor and proves the death was a SIGKILL: no
// handler, no deferred close, no checkpoint.
func killBySIGKILL(t *testing.T, cmd *exec.Cmd) {
	t.Helper()
	if err := cmd.Process.Kill(); err != nil {
		t.Fatalf("kill supervisor pid %d: %v", cmd.Process.Pid, err)
	}
	err := cmd.Wait()
	ee, ok := err.(*exec.ExitError)
	if !ok {
		t.Fatalf("supervisor err = %v, want an ExitError from SIGKILL", err)
	}
	ws, ok := ee.Sys().(syscall.WaitStatus)
	if !ok {
		t.Fatal("supervisor: no wait status")
	}
	if !ws.Signaled() || ws.Signal() != syscall.SIGKILL {
		t.Fatalf("supervisor exited=%d signaled=%v signal=%v, want death by SIGKILL",
			ee.ExitCode(), ws.Signaled(), ws.Signal())
	}
}

// waitLeaseExpired waits for the killed owner's lease to pass its own stall
// limit, which is what makes the takeover legal (run.Lease.Expired). The bound
// is the journaled stall limit, not a knob (SPEC-044 M2, DRI OQ3).
func (c *restartCase) waitLeaseExpired(t *testing.T, m *run.Machine) run.Lease {
	t.Helper()
	ctx := context.Background()
	deadline := time.Now().Add(RestartFinishWait)
	for {
		l, err := m.ReadLease(ctx)
		if errors.Is(err, journal.ErrNoLease) {
			t.Fatalf("the killed owner's lease row is gone (%v); nothing is left for "+
				"the takeover to take over", err)
		}
		if err != nil {
			t.Fatalf("read the lease: %v", err)
		}
		if l.Expired(time.Now()) {
			return l
		}
		if time.Now().After(deadline) {
			t.Fatalf("the lease (heartbeat %s, limit %ds) never expired within %s",
				l.LastHeartbeatTS, l.StallLimitS, RestartFinishWait)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// runRestart runs the restarted chiefd and answers with its report. A non-zero
// exit is a failure: the restart either refused the takeover or left the run
// unfinished, and both are the defect this test exists to catch.
func (c *restartCase) runRestart(t *testing.T) restartReport {
	t.Helper()
	out, err := c.command(ModeRestart).CombinedOutput()
	if err != nil {
		t.Fatalf("the restarted chiefd failed: %v\n%s", err, out)
	}
	raw, err := os.ReadFile(c.reportPath)
	if err != nil {
		t.Fatalf("read the restart report: %v\n%s", err, out)
	}
	var rep restartReport
	if err := json.Unmarshal(raw, &rep); err != nil {
		t.Fatalf("restart report %q: %v", raw, err)
	}
	t.Logf("restart report: %s", raw)
	return rep
}

// runnerLaunches is the external record of how many runner processes spawned.
func (c *restartCase) runnerLaunches(t *testing.T) int {
	t.Helper()
	raw, err := os.ReadFile(c.countPath)
	if err != nil {
		t.Fatalf("read the runner-launch record: %v", err)
	}
	n, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil {
		t.Fatalf("runner-launch record %q: %v", raw, err)
	}
	return n
}

func (c *restartCase) openEngine(t *testing.T) *journal.Engine {
	t.Helper()
	eng, err := journal.OpenPath(context.Background(), c.dbPath)
	if err != nil {
		t.Fatalf("open journal %s: %v", c.dbPath, err)
	}
	t.Cleanup(func() { _ = eng.Close() })
	return eng
}

// restartReport mirrors the answer ./restart/helper writes.
type restartReport struct {
	RunID       string            `json:"run_id"`
	State       string            `json:"state"`
	Taken       []takeoverRunLine `json:"taken,omitempty"`
	Skipped     []takeoverRunLine `json:"skipped,omitempty"`
	Refused     []takeoverRunLine `json:"refused,omitempty"`
	Unconfirmed []takeoverRunLine `json:"unconfirmed,omitempty"`
}

// takeoverRunLine mirrors chief.TakeoverRun.
type takeoverRunLine struct {
	RunID   string `json:"run_id"`
	State   string `json:"state"`
	Outcome string `json:"outcome"`
	Host    string `json:"host,omitempty"`
	Reason  string `json:"reason,omitempty"`
}

// runnerLaunch is one agent.start intent/outcome pair read off the journal.
type runnerLaunch struct {
	seq        int64
	outcomeSeq int64
	key        string
	command    string
	attempt    int
	pid        int
}

// startLaunches reads every spawn of the run, in journal order.
func startLaunches(t *testing.T, eng *journal.Engine) []runnerLaunch {
	t.Helper()
	var out []runnerLaunch
	for _, ev := range rows(t, eng) {
		ef, ok := sideEffect(ev, agent.EffectStart)
		if !ok {
			continue
		}
		if ev.IntentRow() {
			var intent struct {
				Command string `json:"command"`
				Attempt int    `json:"attempt"`
			}
			if err := json.Unmarshal(ef.Intent, &intent); err != nil {
				t.Fatalf("spawn intent %d: %v", ev.Seq, err)
			}
			out = append(out, runnerLaunch{seq: ev.Seq, key: ev.IdempotencyKey,
				command: intent.Command, attempt: intent.Attempt})
			continue
		}
		var outcome struct {
			PID int `json:"pid"`
		}
		if err := json.Unmarshal(ef.Outcome, &outcome); err != nil {
			t.Fatalf("spawn outcome %d: %v", ev.Seq, err)
		}
		for i := range out {
			if out[i].seq == ef.IntentSeq {
				out[i].outcomeSeq, out[i].pid = ev.Seq, outcome.PID
			}
		}
	}
	return out
}

// lastStartPID is the pid of the newest recorded spawn outcome.
func lastStartPID(t *testing.T, eng *journal.Engine) int {
	t.Helper()
	ls := startLaunches(t, eng)
	if len(ls) == 0 {
		t.Fatal("the journal carries no spawn record")
	}
	return ls[len(ls)-1].pid
}

// trailStep is one named row of the M11 trail.
type trailStep struct {
	name string
	seq  int64
}

// assertRestartTrail is SPEC-044 M11 read off the journal file, in row order.
func assertRestartTrail(t *testing.T, eng *journal.Engine, first runnerLaunch) {
	t.Helper()
	all := rows(t, eng)

	takeoverSeq, takeover := leaseTakeoverRow(t, all)
	if takeover.Reason != "takeover" {
		t.Errorf("lease_acquired reason = %q, want takeover", takeover.Reason)
	}
	if takeover.Token != 2 {
		t.Errorf("takeover token = %d, want 2 (the fencing token rises by one)", takeover.Token)
	}
	if !strings.HasPrefix(takeover.Owner, agent.Owner+"-") {
		t.Errorf("takeover owner = %q, want this node's own agent shape %q-<pid>",
			takeover.Owner, agent.Owner)
	}

	kill := sideEffects(t, all, agent.EffectKill)
	if len(kill) != 2 {
		t.Fatalf("agent.kill rows = %d, want the intent and the outcome of one orphan stop",
			len(kill))
	}
	var killIntent struct {
		PID int `json:"pid"`
	}
	if err := json.Unmarshal(kill[0].ef.Intent, &killIntent); err != nil {
		t.Fatalf("agent.kill intent: %v", err)
	}
	if killIntent.PID != first.pid {
		t.Errorf("agent.kill names pid %d, want the killed supervisor's runner %d: the "+
			"takeover must stop the orphan it found alive", killIntent.PID, first.pid)
	}
	if kill[1].ef.IntentSeq != kill[0].seq {
		t.Errorf("the agent.kill outcome closes intent %d, want %d",
			kill[1].ef.IntentSeq, kill[0].seq)
	}

	launches := startLaunches(t, eng)
	if len(launches) != 2 {
		t.Fatalf("spawn records = %d, want 2 (attempt 1 and the takeover's re-spawn)",
			len(launches))
	}
	second := launches[1]
	if second.attempt != 2 {
		t.Errorf("re-spawn attempt = %d, want 2 (attempt N+1)", second.attempt)
	}
	if second.key != RestartStartKey(2) {
		t.Errorf("re-spawn key = %q, want %q", second.key, RestartStartKey(2))
	}
	if base := filepath.Base(second.command); base != RestartHostCLI {
		t.Errorf("re-spawn command = %q, want the journaled host command %q",
			second.command, RestartHostCLI)
	}
	if second.pid <= 0 || second.pid == first.pid {
		t.Errorf("re-spawn pid = %d, want a new live pid (attempt 1 was %d)",
			second.pid, first.pid)
	}
	if second.outcomeSeq == 0 {
		t.Fatal("the re-spawn carries no outcome row: the spawn is unresolved")
	}

	st := stints(t, eng)
	if len(st) != 2 {
		t.Fatalf("stint rows = %+v, want 2 (one per attempt)", st)
	}
	if st[1].stint != 2 || st[1].label != "attempt 2" {
		t.Errorf("second stint = %+v, want stint 2 labeled %q", st[1], "attempt 2")
	}

	if n := countKind(all, journal.KindRunCompleted); n != 1 {
		t.Errorf("run_completed rows = %d, want 1 (exactly once, across a SIGKILL)", n)
	}
	for _, bad := range []struct {
		kind journal.Kind
		want int
	}{
		{journal.KindRunFailed, 0},
		{journal.KindRunHalted, 0},
		{journal.KindRunResumed, 0},
		{journal.KindLeaseAcquire, 1},
		{journal.KindRunClaimed, 1},
	} {
		if n := countKind(all, bad.kind); n != bad.want {
			t.Errorf("%s rows = %d, want %d", bad.kind, n, bad.want)
		}
	}

	// M11's order, on the journal's own seq.
	steps := []trailStep{
		{"lease_acquired(takeover)", takeoverSeq},
		{"agent.kill intent", kill[0].seq},
		{"agent.kill outcome", kill[1].seq},
		{"agent.start intent(2)", second.seq},
		{"agent.start outcome(new pid)", second.outcomeSeq},
		{"stint_started(2)", st[1].seq},
		{"run_completed", lastSeqOf(t, eng, journal.KindRunCompleted)},
	}
	for i := 1; i < len(steps); i++ {
		if steps[i].seq <= steps[i-1].seq {
			t.Errorf("trail order broken: %s (seq %d) does not follow %s (seq %d)",
				steps[i].name, steps[i].seq, steps[i-1].name, steps[i-1].seq)
		}
	}
	labels := make([]string, 0, len(steps))
	for _, s := range steps {
		labels = append(labels, fmt.Sprintf("%s@%d", s.name, s.seq))
	}
	t.Logf("trail: %s", strings.Join(labels, " → "))

	if first.seq >= takeoverSeq {
		t.Errorf("attempt 1's spawn (seq %d) is not before the takeover (seq %d)",
			first.seq, takeoverSeq)
	}
}

// rows is the run's journal, in seq order.
func rows(t *testing.T, eng *journal.Engine) []journal.Event {
	t.Helper()
	evs, err := eng.Events(context.Background(), RestartRunID)
	if err != nil {
		t.Fatalf("read the journal: %v", err)
	}
	return evs
}

// sideEffect reads one side_effect row's payload, naming the effect it carries.
func sideEffect(ev journal.Event, effect string) (journal.Effect, bool) {
	if ev.Kind != journal.KindSideEffect {
		return journal.Effect{}, false
	}
	var ef journal.Effect
	if err := json.Unmarshal(ev.Payload, &ef); err != nil || ef.Effect != effect {
		return journal.Effect{}, false
	}
	return ef, true
}

// effectRow is one side_effect row with its journal position.
type effectRow struct {
	seq int64
	ef  journal.Effect
}

// sideEffects returns every row of one effect name, in journal order.
func sideEffects(t *testing.T, all []journal.Event, effect string) []effectRow {
	t.Helper()
	var out []effectRow
	for _, ev := range all {
		if ef, ok := sideEffect(ev, effect); ok {
			out = append(out, effectRow{seq: ev.Seq, ef: ef})
		}
	}
	return out
}

// lastSeqOf is the seq of the run's newest row of one kind.
func lastSeqOf(t *testing.T, eng *journal.Engine, kind journal.Kind) int64 {
	t.Helper()
	seq := int64(0)
	for _, ev := range rows(t, eng) {
		if ev.Kind == kind {
			seq = ev.Seq
		}
	}
	if seq == 0 {
		t.Fatalf("the journal carries no %s row", kind)
	}
	return seq
}

// stintRow is one stint_started row.
type stintRow struct {
	seq   int64
	stint int
	label string
}

// stints reads the run's stint rows, in journal order.
func stints(t *testing.T, eng *journal.Engine) []stintRow {
	t.Helper()
	var out []stintRow
	for _, ev := range rows(t, eng) {
		if ev.Kind != journal.KindStintStarted {
			continue
		}
		var p journal.StintPayload
		if err := json.Unmarshal(ev.Payload, &p); err != nil {
			t.Fatalf("stint row %d: %v", ev.Seq, err)
		}
		out = append(out, stintRow{seq: ev.Seq, stint: p.Stint, label: p.Label})
	}
	return out
}

// leaseTakeoverRow returns the run's lease-acquisition row.
func leaseTakeoverRow(t *testing.T, all []journal.Event) (int64, journal.LeasePayload) {
	t.Helper()
	for _, ev := range all {
		if ev.Kind != journal.KindLeaseAcquire {
			continue
		}
		var p journal.LeasePayload
		if err := json.Unmarshal(ev.Payload, &p); err != nil {
			t.Fatalf("lease_acquired row %d: %v", ev.Seq, err)
		}
		return ev.Seq, p
	}
	t.Fatal("the journal carries no lease_acquired row: nothing was taken over")
	return 0, journal.LeasePayload{}
}

// pidRecord mirrors the node agent's live-process record — the handover the
// takeover's orphan probe reads.
type pidRecord struct {
	RunnerPID     int    `json:"runner_pid"`
	SupervisorPID int    `json:"supervisor_pid"`
	RunnerType    string `json:"runner_type"`
}

// pidPathIn is the agent's live-process record of one run under one state root.
func pidPathIn(mroot, runID string) string {
	return filepath.Join(mroot, ".claude", "runs", "agent", runID+".pid")
}

func readPIDRecord(t *testing.T, mroot, runID string) pidRecord {
	t.Helper()
	path := pidPathIn(mroot, runID)
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read the pidfile the takeover's orphan probe reads: %v", err)
	}
	var rec pidRecord
	if err := json.Unmarshal(raw, &rec); err != nil {
		t.Fatalf("pidfile %q is not a record: %v", raw, err)
	}
	return rec
}

// processAlive is the agent's own liveness probe: signal 0.
func processAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	return syscall.Kill(pid, 0) == nil
}
