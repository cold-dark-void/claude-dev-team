package chief

import (
	"context"
	"encoding/json"
	"io"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/cold-dark-void/claude-dev-team/control-plane/agent"
	"github.com/cold-dark-void/claude-dev-team/control-plane/hostadapter"
	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
)

// AC4: a routine run is started, steered, and closed from the UI with no
// terminal tab. Every step below rides the HTTP endpoints the web UI drives
// — route, run status, correction — over the C6 steer E2E seam: a real
// child of this node that prints the session frame and blocks on stdin,
// exactly the step boundary a steer delivers at. Nothing touches a
// terminal.
func TestABoardRunIsStartedSteeredAndClosedFromTheUI(t *testing.T) {
	eng := newEngine(t)
	out := filepath.Join(t.TempDir(), "steered.txt")
	t.Setenv("CDT650_TEST_STEER_OUT", out)

	ad := &hostadapter.Adapter{Agent: &shAgent{A: &agent.Agent{
		Runner: agent.Native{Stderr: io.Discard}}}}
	c := NewWithAdapter(eng, ad, WithTickets(&fakeTickets{slug: "ui-run"}),
		WithModelMap(&fakeModels{}), WithPhone(&fakePhone{}))
	c.StartWait = 10 * time.Second
	srv := httptest.NewServer(c.Handler())
	t.Cleanup(srv.Close)

	// Start: the UI routes the work.
	var routed RouteResult
	if err := json.Unmarshal(post(t, srv, "/v1/route", `{"kind":"defect",
		"title":"Steer me","text":"the defect premise","host":"omp"}`),
		&routed); err != nil {
		t.Fatal(err)
	}
	if routed.RunID != "ui-run" {
		t.Fatalf("route = %s, want the ui-run run", routed.RunID)
	}

	// The run is in flight before the correction is handed over: the
	// delivery waits for the step boundary, it never interrupts a turn.
	deadline := time.Now().Add(10 * time.Second)
	for {
		if apiState(t, srv, routed.RunID) == "running" && runReady(routed.RunID) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the run never started")
		}
		time.Sleep(25 * time.Millisecond)
	}

	// Steer: the UI sends the correction.
	const message = "Steer: include the exact token UI-STEERED-10 in your final reply."
	post(t, srv, "/v1/runs/ui-run/corrections", `{"message":"`+message+`"}`)

	// Close: the steered child exits and the run reaches its terminal
	// state — the whole routine never left the UI's endpoints.
	deadline = time.Now().Add(10 * time.Second)
	for {
		if state := apiState(t, srv, routed.RunID); state == "completed" {
			break
		} else if time.Now().After(deadline) {
			t.Fatalf("the run never closed, last state %q", state)
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
		t.Errorf("delivered frame = %q, want the steer frame", raw)
	}
	// The run closed through the machine's own states — the board reports
	// it without prose.
	if st, err := eng.RunState(context.Background(), routed.RunID); err != nil ||
		st.Status != journal.StatusCompleted {
		t.Errorf("final state = %v (%v), want completed", st.Name(), err)
	}
}

// apiState reads one run's state the way the board does: over the HTTP API.
func apiState(t *testing.T, srv *httptest.Server, runID string) string {
	t.Helper()
	var rs RunStatus
	if err := json.Unmarshal(get(t, srv, "/v1/runs/"+runID), &rs); err != nil {
		t.Fatal(err)
	}
	return rs.State
}
