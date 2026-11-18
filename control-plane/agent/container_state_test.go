package agent

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// AC4 sub-clause receipt: state written by container 1 crosses the rw
// session-state mounts — not only the worktree mount — and is container 2's
// starting state after the first container dies (container-runner.md AC-9
// restart rows; the Fact-2 writable-mount rule). The worktree half of the
// death→resume hand-off is TestContainerResumeSurvivesDeathOverTheMountedPathsLive;
// this test holds the state-mount half.
func TestContainerStateCrossesTheRWStateMountsLive(t *testing.T) {
	c := liveContainer(t)
	rows := c.stateMounts("sh")
	if len(rows) == 0 {
		t.Fatal("no state mounts wired")
	}
	stateDir := rows[0].target
	stateFile := filepath.Join(stateDir, "state-mount-state.txt")

	first, err := c.Start(Spec{
		Command: "sh",
		Args:    []string{"-c", `printf 'state-mount-state' > ` + stateFile + `; echo done`},
		Name:    containerName("live-state"),
	})
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	select {
	case err := <-first.Done():
		if err != nil {
			t.Fatalf("first session exit: %v", err)
		}
	case <-time.After(60 * time.Second):
		t.Fatal("first session did not exit")
	}

	// The first container is dead; a fresh container reads the state the
	// dead one wrote — over the rw state mount, with no host action.
	second, err := c.Start(Spec{
		Command: "sh",
		Args: []string{"-c",
			`cp ` + stateFile + ` ` + stateFile + `.crossed; echo crossed`},
		Name: containerName("live-state"),
	})
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	defer second.Stop(0)
	select {
	case err := <-second.Done():
		if err != nil {
			t.Fatalf("second session exit: %v", err)
		}
	case <-time.After(60 * time.Second):
		t.Fatal("second session did not exit")
	}
	raw, err := os.ReadFile(stateFile + ".crossed")
	if err != nil {
		t.Fatalf("crossed state: %v", err)
	}
	if string(raw) != "state-mount-state" {
		t.Errorf("crossed state = %q, want state-mount-state", raw)
	}
}
