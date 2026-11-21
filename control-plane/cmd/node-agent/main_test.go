package main

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
)

// helperArgsEnv is the sentinel that turns this test binary into a node-agent:
// its value is the verb list, one argv entry per line. The signal test re-execs
// os.Args[0] with it, so the process that takes SIGTERM is a real
// `node-agent start` — no build step, no simulated signal.
const helperArgsEnv = "CDT660_NODEAGENT_ARGS"

// agentRunsRelPath mirrors the agent's handover-record location
// (control-plane/agent: .claude/runs/agent). The test reads the file, so it
// needs the path, and the constant is unexported in the agent package.
const agentRunsRelPath = ".claude/runs/agent"

// TestMain doubles as the helper entry point: with helperArgsEnv set, this
// binary is the CLI, running the verb list that variable carries, and it exits
// with the CLI's exit code.
func TestMain(m *testing.M) {
	if raw := os.Getenv(helperArgsEnv); raw != "" {
		args := strings.Split(strings.TrimSuffix(raw, "\n"), "\n")
		os.Exit(run(args, os.Stdout, os.Stderr))
	}
	os.Exit(m.Run())
}

// AC15 (SPEC-044 M8): the standalone CLI's signal path is an operator stop.
// SIGTERM to `node-agent start` drives the journal-first stop verb, so the run
// lands in halted:operator_halt — the supervisor registers no signal of its
// own, and the quiet-shutdown path is not what a CLI signal produces.
func TestStartSignalPathLandsOperatorHalt(t *testing.T) {
	dir := t.TempDir()
	db := filepath.Join(dir, "run.db")
	runID := "CDT-660"
	pidFile := filepath.Join(dir, agentRunsRelPath, runID+".pid")

	eng, err := journal.OpenPath(context.Background(), db)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = eng.Close() })

	args := []string{"start", "--run-id", runID, "--ticket", "CDT-660",
		"--workflow", "orchestrate", "--model", "sonnet",
		"--command", "sh", "--arg", "-c", "--arg", "sleep 30", "--grace", "1s"}
	cmd := exec.Command(os.Args[0])
	cmd.Env = append(os.Environ(),
		helperArgsEnv+"="+strings.Join(args, "\n")+"\n",
		"DEVTEAM_MROOT="+dir,
		"DEVTEAM_RUN_DB="+db,
		"DEVTEAM_RUNNER=native",
		"DEVTEAM_STALL_LIMIT=1",
	)
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	// One goroutine owns cmd.Wait; the deadline path kills the child so the
	// wait always lands and a hang is reported as a failure, never a leak.
	waited := make(chan error, 1)
	go func() { waited <- cmd.Wait() }()

	runnerPID := waitForRunnerPID(t, eng, runID, pidFile)

	if err := cmd.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatalf("SIGTERM: %v", err)
	}
	select {
	case err := <-waited:
		if err != nil {
			t.Fatalf("node-agent start after SIGTERM: %v\nstdout: %sstderr: %s",
				err, stdout.String(), stderr.String())
		}
	case <-time.After(20 * time.Second):
		_ = cmd.Process.Kill()
		<-waited
		t.Fatalf("node-agent start did not exit after SIGTERM\nstdout: %sstderr: %s",
			stdout.String(), stderr.String())
	}
	if got := stdout.String(); got != "ok\n" {
		t.Errorf("stdout = %q, want %q (stderr %q)", got, "ok\n", stderr.String())
	}

	st, err := eng.RunState(context.Background(), runID)
	if err != nil {
		t.Fatal(err)
	}
	if st.Name() != "halted:operator_halt" {
		t.Errorf("state = %s, want halted:operator_halt", st.Name())
	}
	if n := countKind(t, eng, runID, journal.KindRunHalted); n != 1 {
		t.Errorf("run_halted rows = %d, want the one operator halt", n)
	}
	if _, err := os.Stat(pidFile); !os.IsNotExist(err) {
		t.Errorf("pidfile survived the signal stop (stat err %v)", err)
	}
	if deadline := time.Now().Add(5 * time.Second); waitForAlive(runnerPID, deadline) {
		t.Errorf("runner pid %d survived the signal stop", runnerPID)
	}
}

// waitForRunnerPID waits for the run to read running and for the agent's
// handover record to name the live runner: the state turns running one journal
// write before the pidfile lands.
func waitForRunnerPID(t *testing.T, eng *journal.Engine, runID, pidFile string) int {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for {
		st, err := eng.RunState(context.Background(), runID)
		if err != nil {
			t.Fatalf("replay %s: %v", runID, err)
		}
		if st.Status == journal.StatusRunning {
			if pid := readRunnerPID(pidFile); pid > 0 {
				return pid
			}
		}
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s to run; state is %s", runID, st.Name())
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// readRunnerPID reads the runner pid out of the agent's handover record. A
// missing or unreadable record reads 0: no recorded process yet.
func readRunnerPID(path string) int {
	raw, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	var rec struct {
		RunnerPID int `json:"runner_pid"`
	}
	if err := json.Unmarshal(raw, &rec); err != nil {
		return 0
	}
	return rec.RunnerPID
}

// waitForAlive reports whether pid is still signalling before the deadline.
func waitForAlive(pid int, deadline time.Time) bool {
	for {
		if err := syscall.Kill(pid, 0); err != nil {
			return false
		}
		if time.Now().After(deadline) {
			return true
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// countKind counts the journal rows of one kind for a run.
func countKind(t *testing.T, eng *journal.Engine, runID string, kind journal.Kind) int {
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
