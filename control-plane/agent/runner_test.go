package agent

import (
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

// The native runner is a process on the node's own OS: it spawns the host
// CLI, tracks the PID, steers through the child's stdin, and stops with
// SIGTERM then SIGKILL after the grace. No Docker anywhere — these tests run
// plain host-CLI children.
func TestNativeRunnerStartsTracksAndSteers(t *testing.T) {
	out := filepath.Join(t.TempDir(), "steered.txt")
	t.Setenv("CDT644_TEST_STEER_OUT", out)
	p, err := Native{Stdout: io.Discard, Stderr: io.Discard}.Start(Spec{
		Command: "sh",
		Args:    []string{"-c", `read l; printf '%s' "$l" > "$CDT644_TEST_STEER_OUT"`},
	})
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	if p.PID() <= 0 {
		t.Fatalf("pid = %d, want a tracked process id", p.PID())
	}
	msg := "steer-me-at-the-boundary"
	if err := p.Steer(msg); err != nil {
		t.Fatalf("steer: %v", err)
	}
	// The child exits once it has read one line and written it out, so Done
	// is the delivery proof.
	select {
	case err := <-p.Done():
		if err != nil {
			t.Fatalf("child wait: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("child did not exit")
	}
	raw, err := os.ReadFile(out)
	if err != nil {
		t.Fatalf("steered output: %v", err)
	}
	if string(raw) != msg {
		t.Errorf("steered message = %q, want %q", raw, msg)
	}
}

// AC: stop is SIGTERM, then SIGKILL after a grace.
func TestNativeRunnerStopIsTermThenKill(t *testing.T) {
	cases := []struct {
		name  string
		grace time.Duration
		want  syscall.Signal
	}{
		{"grace gives SIGTERM room", 2 * time.Second, syscall.SIGTERM},
		{"zero grace escalates to SIGKILL", 0, syscall.SIGKILL},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			p, err := Native{Stdout: io.Discard, Stderr: io.Discard}.Start(Spec{
				Command: "sh",
				Args:    []string{"-c", "sleep 30"},
			})
			if err != nil {
				t.Fatalf("start: %v", err)
			}
			done := make(chan error, 1)
			go func() { done <- p.Stop(tc.grace) }()
			select {
			case err := <-done:
				var ee *exec.ExitError
				if err == nil || !errors.As(err, &ee) {
					t.Fatalf("Stop err = %v, want an exit-status error", err)
				}
				if got := exitSignal(err); got != tc.want {
					t.Errorf("died from signal %v, want %v", got, tc.want)
				}
			case <-time.After(tc.grace + 5*time.Second):
				t.Fatal("Stop did not return")
			}
		})
	}
}

// exitSignal reads the signal that ended a child, 0 when it exited by itself.
func exitSignal(err error) syscall.Signal {
	var ee *exec.ExitError
	if !errors.As(err, &ee) {
		return 0
	}
	status, ok := ee.Sys().(syscall.WaitStatus)
	if !ok || !status.Signaled() {
		return 0
	}
	return status.Signal()
}

// AC: a spawn of nothing is refused, fail-closed.
func TestNativeRunnerRefusesEmptyCommand(t *testing.T) {
	var n Native
	if _, err := n.Start(Spec{}); err == nil {
		t.Fatal("start of an empty spec was accepted")
	}
}
