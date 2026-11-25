package chief

import (
	"context"
	"encoding/json"
	"io"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
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
	// The steer seam supervises a real child, so it runs on the wide stall
	// limit (newEngineWideStall): a loaded runner must not race newEngine's
	// 1 s limit into a stall answer on the correction.
	eng := newEngineWideStall(t)
	out := filepath.Join(t.TempDir(), "steered.txt")
	premise := filepath.Join(t.TempDir(), "first-frame.txt")
	t.Setenv("CDT650_TEST_STEER_OUT", out)
	t.Setenv("CDT650_TEST_PREMISE_OUT", premise)

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
	// CDT-665: the correction rode the second frame — the route's premise was
	// the session's first turn.
	praw, err := os.ReadFile(premise)
	if err != nil {
		t.Fatalf("premise output: %v", err)
	}
	if !strings.Contains(string(praw), "the defect premise") {
		t.Errorf("first frame = %q, want the route's premise", praw)
	}
	// The run closed through the machine's own states — the board reports
	// it without prose.
	if st, err := eng.RunState(context.Background(), routed.RunID); err != nil ||
		st.Status != journal.StatusCompleted {
		t.Errorf("final state = %v (%v), want completed", st.Name(), err)
	}
}

// CDT-665 AC1/AC2: the premise of a routed run reaches the spawned session's
// FIRST turn and carries the run to completed on its own. The seam's child
// reads one stdin frame and exits — no correction is ever sent — so the only
// frame it can read is the premise, and the only state it can reach is the
// one the premise drove.
func TestAPremiseTurnCompletesARoutedRunWithNoSteer(t *testing.T) {
	eng := newEngineWideStall(t)
	premise := filepath.Join(t.TempDir(), "first-frame.txt")
	steer := filepath.Join(t.TempDir(), "steered.txt")
	t.Setenv("CDT650_TEST_PREMISE_OUT", premise)
	t.Setenv("CDT650_TEST_STEER_OUT", steer)

	ad := &hostadapter.Adapter{Agent: &premiseShAgent{A: &agent.Agent{
		Runner: agent.Native{Stderr: io.Discard}}}}
	c := NewWithAdapter(eng, ad, WithTickets(&fakeTickets{slug: "premise-run"}),
		WithModelMap(&fakeModels{}), WithPhone(&fakePhone{}))
	c.StartWait = 10 * time.Second
	srv := httptest.NewServer(c.Handler())
	t.Cleanup(srv.Close)

	const premiseText = "The premise of CDT-665: the spawned session never sees its work."
	var routed RouteResult
	if err := json.Unmarshal(post(t, srv, "/v1/route", `{"kind":"defect",
		"title":"Deliver the premise","text":"`+premiseText+`","host":"omp"}`),
		&routed); err != nil {
		t.Fatal(err)
	}
	if routed.RunID != "premise-run" {
		t.Fatalf("route = %s, want the premise-run run", routed.RunID)
	}

	// Completed on the premise alone: the child exits when its first frame
	// lands, and nothing posts to /v1/runs/<run>/corrections.
	deadline := time.Now().Add(10 * time.Second)
	for {
		if state := apiState(t, srv, routed.RunID); state == "completed" {
			break
		} else if time.Now().After(deadline) {
			t.Fatalf("the run never closed on its premise, last state %q", state)
		}
		time.Sleep(25 * time.Millisecond)
	}

	raw, err := os.ReadFile(premise)
	if err != nil {
		t.Fatalf("premise output: %v", err)
	}
	var frame struct {
		Type    string `json:"type"`
		Message string `json:"message"`
	}
	if err := json.Unmarshal(raw, &frame); err != nil {
		t.Fatalf("premise frame is not JSON: %v (%q)", err, raw)
	}
	if frame.Message != premiseText {
		t.Errorf("first frame = %q, want the route's premise %q", raw, premiseText)
	}

	// No steer happened: the steer file is the child's second read, which
	// this seam never reaches.
	if _, err := os.Stat(steer); !os.IsNotExist(err) {
		t.Errorf("the steer file exists (%v): the run was steered, not premised", err)
	}
	// The journal trail is intent-then-outcome, one closed pair for attempt 1.
	if n, o := premiseFrameRows(t, eng, routed.RunID); n != 1 || o != 1 {
		t.Errorf("agent.premise rows = %d intents, %d outcomes, want one closed pair", n, o)
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
