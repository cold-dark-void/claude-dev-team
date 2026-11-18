package chief

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/cold-dark-void/claude-dev-team/control-plane/agent"
	"github.com/cold-dark-void/claude-dev-team/control-plane/hostadapter"
	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
)

// shAgent is the NodeAgent seam of the C6 steer proof: the supervised
// process is a real child of this node — it prints the session frame, then
// blocks on a line of stdin, which is exactly the step boundary a steer
// delivers at — and the agent supervises it for real.
type shAgent struct {
	A *agent.Agent
}

func (s *shAgent) Supervise(ctx context.Context, eng *journal.Engine,
	req agent.StartRequest, sessionOut io.Writer) error {
	req.Command, req.Args = "sh", []string{"-c",
		`printf '%s\n' '{"type":"session","version":3,"id":"01a1ddda-7a27"}'; read l; printf '%s' "$l" > "$CDT650_TEST_STEER_OUT"`}
	s.A.Runner = agent.Native{Stdout: sessionOut}
	return s.A.Supervise(ctx, eng, req)
}

func (s *shAgent) Stop(ctx context.Context, eng *journal.Engine,
	runID string, grace time.Duration) error {
	return s.A.Stop(ctx, eng, runID, grace)
}

func (s *shAgent) Steer(ctx context.Context, eng *journal.Engine, runID, message string) error {
	return s.A.Steer(ctx, eng, runID, message)
}

func (s *shAgent) Status(ctx context.Context, eng *journal.Engine,
	runID string) (agent.StatusReport, error) {
	return s.A.Status(ctx, eng, runID)
}

// AC4: a correction sent through the Chief reaches the running session at
// its next step boundary and does not interrupt a turn — the C6 steer path
// end-to-end on a live run: route → run → correction → the host frame the
// child consumed.
func TestCorrectionRidesTheSteerPathEndToEnd(t *testing.T) {
	eng := newEngine(t)
	out := filepath.Join(t.TempDir(), "steered.txt")
	t.Setenv("CDT650_TEST_STEER_OUT", out)

	ad := &hostadapter.Adapter{Agent: &shAgent{A: &agent.Agent{
		Runner: agent.Native{Stderr: io.Discard}}}}
	tickets := &fakeTickets{slug: "run-steer"}
	c := NewWithAdapter(eng, ad, WithTickets(tickets), WithModelMap(&fakeModels{}),
		WithPhone(&fakePhone{}))
	c.StartWait = 10 * time.Second

	res, err := c.Route(context.Background(), RouteRequest{
		Kind: "defect", Title: "Steer me", Text: "the defect premise",
		Host: hostadapter.HostOmp})
	if err != nil {
		t.Fatalf("route: %v", err)
	}
	// The run runs and its runner is recorded before the correction is
	// handed over: the delivery waits for the boundary, it never interrupts
	// a turn.
	deadline := time.Now().Add(10 * time.Second)
	for {
		if isRunning(t, eng, res.RunID) && runReady(res.RunID) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the run never started")
		}
		time.Sleep(25 * time.Millisecond)
	}
	const message = "Steer: include the exact token STEER-RECEIVED-47 in your final reply."
	if err := c.Correct(context.Background(), CorrectRequest{
		RunID: res.RunID, Message: message}); err != nil {
		t.Fatalf("correct: %v", err)
	}

	// The child consumed the frame and exited; the agent completed the run.
	deadline = time.Now().Add(10 * time.Second)
	for {
		st, err := eng.RunState(context.Background(), res.RunID)
		if err == nil && st.IsTerminal() && st.Status == journal.StatusCompleted {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the run never completed")
		}
		time.Sleep(25 * time.Millisecond)
	}
	raw, err := os.ReadFile(out)
	if err != nil {
		t.Fatalf("steered output: %v", err)
	}
	var frame struct {
		Type    string `json:"type"`
		Message string `json:"message"`
	}
	if err := json.Unmarshal(raw, &frame); err != nil {
		t.Fatalf("delivered frame is not JSON: %v (%q)", err, raw)
	}
	if frame.Type != "steer" || frame.Message != message {
		t.Errorf("delivered frame = %q, want the omp steer frame", raw)
	}

	// The route added no event kind and no run state: every row the run
	// carries is one of the machine's closed kinds (CDT-642).
	rows, err := eng.Events(context.Background(), res.RunID)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) == 0 {
		t.Fatal("the run carried no journal rows")
	}
	known := map[journal.Kind]bool{}
	for _, k := range journal.AllKinds {
		known[k] = true
	}
	for _, e := range rows {
		if !known[e.Kind] {
			t.Errorf("row kind %q is not a machine event kind", e.Kind)
		}
	}
}

// runReady reports whether the run has a recorded runner process: the
// handover the steer verb needs before it can record an intent.
func runReady(runID string) bool {
	raw, err := os.ReadFile(filepath.Join(os.Getenv("DEVTEAM_MROOT"),
		".claude", "runs", "agent", runID+".pid"))
	if err != nil {
		return false
	}
	var rec struct {
		RunnerPID int `json:"runner_pid"`
	}
	return json.Unmarshal(raw, &rec) == nil && rec.RunnerPID > 0
}

// isRunning reports whether a run's replayed state is running.
func isRunning(t *testing.T, eng *journal.Engine, runID string) bool {
	t.Helper()
	st, err := eng.RunState(context.Background(), runID)
	if err != nil {
		return false
	}
	return st.Status == journal.StatusRunning
}
