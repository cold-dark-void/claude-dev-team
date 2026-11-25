package chief

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/cold-dark-void/claude-dev-team/control-plane/agent"
	"github.com/cold-dark-void/claude-dev-team/control-plane/hostadapter"
	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
	"github.com/cold-dark-void/claude-dev-team/control-plane/run"
)

// shAgent is the NodeAgent seam of the C6 steer proof: the supervised
// process is a real child of this node — it prints the session frame, then
// blocks on a line of stdin, which is exactly the step boundary a steer
// delivers at — and the agent supervises it for real.
//
// CDT-665 widened the seam to the session's whole frame order: the child
// reads its FIRST stdin frame (the work premise's first-turn frame) into
// $CDT650_TEST_PREMISE_OUT and only then reads the steer frame into
// $CDT650_TEST_STEER_OUT. The premise file appends, so a re-adoption that
// re-sent the premise shows up as a second line.
type shAgent struct {
	A *agent.Agent
}

func (s *shAgent) Supervise(ctx context.Context, eng *journal.Engine,
	req agent.StartRequest, sessionOut io.Writer) error {
	req.Command, req.Args = "sh", []string{"-c", steerSeamScript}
	s.A.Runner = agent.Native{Stdout: sessionOut}
	return s.A.Supervise(ctx, eng, req)
}

// steerSeamScript is the two-frame child of the steer seam: session frame,
// premise frame into $CDT650_TEST_PREMISE_OUT, steer frame into
// $CDT650_TEST_STEER_OUT.
const steerSeamScript = `printf '%s\n' '{"type":"session","version":3,"id":"01a1ddda-7a27"}'; ` +
	`read l; printf '%s\n' "$l" >> "$CDT650_TEST_PREMISE_OUT"; ` +
	`read l; printf '%s' "$l" > "$CDT650_TEST_STEER_OUT"`

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

// premiseShAgent is the CDT-665 e2e seam: the child prints the session frame,
// reads its FIRST stdin frame into $CDT650_TEST_PREMISE_OUT, and exits.
// Nothing steers it — the work premise alone must carry the run to
// completed, which is the shipped contract the steer seam never proved.
// It records the request it was handed, so a test can name what the caller
// supplied and what the host adapter attached.
type premiseShAgent struct {
	A *agent.Agent

	mu   sync.Mutex
	reqs []agent.StartRequest
}

// lastStart is the request of the most recent Supervise, as the adapter
// handed it over.
func (s *premiseShAgent) lastStart() agent.StartRequest {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.reqs) == 0 {
		return agent.StartRequest{}
	}
	return s.reqs[len(s.reqs)-1]
}

func (s *premiseShAgent) Supervise(ctx context.Context, eng *journal.Engine,
	req agent.StartRequest, sessionOut io.Writer) error {
	s.mu.Lock()
	s.reqs = append(s.reqs, req)
	s.mu.Unlock()
	req.Command, req.Args = "sh", []string{"-c",
		`printf '%s\n' '{"type":"session","version":3,"id":"01a1ddda-7a27"}'; ` +
			`read l; printf '%s' "$l" > "$CDT650_TEST_PREMISE_OUT"`}
	s.A.Runner = agent.Native{Stdout: sessionOut}
	return s.A.Supervise(ctx, eng, req)
}

func (s *premiseShAgent) Stop(ctx context.Context, eng *journal.Engine,
	runID string, grace time.Duration) error {
	return s.A.Stop(ctx, eng, runID, grace)
}

func (s *premiseShAgent) Steer(ctx context.Context, eng *journal.Engine,
	runID, message string) error {
	return s.A.Steer(ctx, eng, runID, message)
}

func (s *premiseShAgent) Status(ctx context.Context, eng *journal.Engine,
	runID string) (agent.StatusReport, error) {
	return s.A.Status(ctx, eng, runID)
}

// premiseFrameRows counts the run's side_effect rows of the premise effect,
// split by half. The effect name is spelled out: the chief package names no
// agent effect of its own, and the wire name is what the AC pins.
func premiseFrameRows(t *testing.T, eng *journal.Engine, runID string) (intents, outcomes int) {
	t.Helper()
	rows, err := eng.Events(context.Background(), runID)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range rows {
		if r.Kind != journal.KindSideEffect {
			continue
		}
		var ef struct {
			Effect    string          `json:"effect"`
			Intent    json.RawMessage `json:"intent"`
			Outcome   json.RawMessage `json:"outcome"`
			IntentSeq int64           `json:"intent_seq"`
		}
		if json.Unmarshal(r.Payload, &ef) != nil || ef.Effect != "agent.premise" {
			continue
		}
		if ef.IntentSeq != 0 {
			outcomes++
			continue
		}
		intents++
	}
	return intents, outcomes
}

// premisePairPayload is the run's premise pair: the intent payload and its
// outcome payload, as the journal carries them.
func premisePairPayload(t *testing.T, eng *journal.Engine, runID string) (json.RawMessage, json.RawMessage) {
	t.Helper()
	rows, err := eng.Events(context.Background(), runID)
	if err != nil {
		t.Fatal(err)
	}
	var intent, outcome json.RawMessage
	for _, r := range rows {
		if r.Kind != journal.KindSideEffect {
			continue
		}
		var ef struct {
			Effect    string          `json:"effect"`
			Intent    json.RawMessage `json:"intent"`
			Outcome   json.RawMessage `json:"outcome"`
			IntentSeq int64           `json:"intent_seq"`
		}
		if json.Unmarshal(r.Payload, &ef) != nil || ef.Effect != "agent.premise" {
			continue
		}
		if ef.IntentSeq != 0 {
			outcome = ef.Outcome
			continue
		}
		intent = ef.Intent
	}
	return intent, outcome
}

// CDT-665 AC4, unmasked: a takeover re-adoption performs the run's PENDING
// premise row with the renderer the host adapter attaches from the host's
// spec. The caller supplies no premise text and no frame — the chief stores
// no ticket text, and the takeover request carries none — so the frame the
// re-spawned child reads can only be the row's own text through the product's
// own wiring.
func TestTakeoverRedeliversThePendingPremiseRowFromTheJournal(t *testing.T) {
	_ = captureTakeoverLog(t)
	// The wide env limit covers the RE-ADOPTION's own lease, so the real
	// child's beats never race a 1 s watchdog (the CDT-669 lesson). The dead
	// stint's lease is seeded at 1 s on purpose: the agent's takeover claim
	// compares the lease at the real clock, so a wide seeded limit leaves the
	// live owner in place and refuses the claim.
	eng := newEngineWideStall(t)
	premise := filepath.Join(t.TempDir(), "first-frame.txt")
	t.Setenv("CDT650_TEST_PREMISE_OUT", premise)
	t.Setenv("CDT650_TEST_STEER_OUT", filepath.Join(t.TempDir(), "steered.txt"))

	const rowText = "the premise of the dead attempt, carried by its own row"
	ctx := context.Background()
	m := run.New(eng, "premise-run")
	m.Getenv = func(string) string { return "1" }
	token, err := m.Claim(ctx, takeoverOwner, takeoverTicket, takeoverWorkflow, takeoverModel)
	if err != nil {
		t.Fatalf("seed claim: %v", err)
	}
	if err := m.Start(ctx, takeoverOwner, token, takeoverModel); err != nil {
		t.Fatalf("seed start: %v", err)
	}
	seedStartIntent(t, eng, "premise-run", "claude")
	seedPendingPremiseRow(t, eng, "premise-run", rowText)
	time.Sleep(1200 * time.Millisecond) // the 1 s lease ages past its limit

	seam := &premiseShAgent{A: &agent.Agent{Runner: agent.Native{Stderr: io.Discard}}}
	c := NewWithAdapter(eng, &hostadapter.Adapter{Agent: seam},
		WithTickets(&fakeTickets{slug: "premise-run"}),
		WithModelMap(&fakeModels{}), WithPhone(&fakePhone{}))
	c.StartWait = 10 * time.Second
	c.Now = takeoverClock(30 * time.Second)

	rep, err := c.TakeoverScan(context.Background())
	if err != nil {
		t.Fatalf("TakeoverScan: %v", err)
	}
	if got := strings.Join(runIDsOf(rep.Taken), ","); got != "premise-run" {
		t.Fatalf("taken = %v, want premise-run (%s)", got, joinReport(rep))
	}

	// The mask is gone: the re-spawn carried no premise and no frame of the
	// caller's — the renderer is the adapter's, from the host's spec.
	req := seam.lastStart()
	if req.Premise != "" {
		t.Errorf("the takeover spawn carried premise %q, want none (the row carries the text)",
			req.Premise)
	}
	if req.PremiseFrame == nil {
		t.Fatal("the takeover spawn carries no premise frame renderer: the pending row " +
			"cannot be performed and would close undelivered")
	}

	// The row's text reached the re-spawned child as its first turn, and the
	// run closed on it.
	deadline := time.Now().Add(15 * time.Second)
	for {
		st, err := eng.RunState(context.Background(), "premise-run")
		if err != nil {
			t.Fatal(err)
		}
		if st.Name() == "completed" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the re-adoption never closed the run, last state %q", st.Name())
		}
		time.Sleep(25 * time.Millisecond)
	}
	raw, err := os.ReadFile(premise)
	if err != nil {
		t.Fatalf("premise output: %v", err)
	}
	var frame struct {
		Type    string `json:"type"`
		Message struct {
			Role    string `json:"role"`
			Content []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"content"`
		} `json:"message"`
	}
	if err := json.Unmarshal(raw, &frame); err != nil {
		t.Fatalf("premise frame is not JSON: %v (%q)", err, raw)
	}
	if len(frame.Message.Content) != 1 || frame.Message.Content[0].Text != rowText {
		t.Errorf("first frame = %q, want the journaled premise %q", raw, rowText)
	}

	// One pair, closed delivered:true, naming one attempt in both halves.
	if n, o := premiseFrameRows(t, eng, "premise-run"); n != 1 || o != 1 {
		t.Errorf("agent.premise rows = %d intents, %d outcomes, want the seeded pair closed",
			n, o)
	}
	intent, outcome := premisePairPayload(t, eng, "premise-run")
	var ih, oh struct {
		Premise   string `json:"premise"`
		Attempt   int    `json:"attempt"`
		Delivered *bool  `json:"delivered"`
	}
	if json.Unmarshal(intent, &ih) != nil || json.Unmarshal(outcome, &oh) != nil {
		t.Fatalf("premise pair is not the payload shape: intent %s, outcome %s", intent, outcome)
	}
	if ih.Premise != rowText {
		t.Errorf("the intent row carries %q, want the seeded text", ih.Premise)
	}
	if oh.Delivered == nil || !*oh.Delivered {
		t.Errorf("outcome %s does not close the delivery", outcome)
	}
	if ih.Attempt != oh.Attempt {
		t.Errorf("the pair names attempt %d (intent) / %d (outcome), want one attempt",
			ih.Attempt, oh.Attempt)
	}
}

// AC4: a correction sent through the Chief reaches the running session at
// its next step boundary and does not interrupt a turn — the C6 steer path
// end-to-end on a live run: route → run → correction → the host frame the
// child consumed.
func TestCorrectionRidesTheSteerPathEndToEnd(t *testing.T) {
	// Real-child supervision: the wide stall limit keeps a loaded runner from
	// racing newEngine's 1 s limit into a stall answer on the correction
	// (newEngineWideStall, the SPEC-044 ### CDT-656 AC A class).
	eng := newEngineWideStall(t)
	out := filepath.Join(t.TempDir(), "steered.txt")
	premise := filepath.Join(t.TempDir(), "first-frame.txt")
	t.Setenv("CDT650_TEST_STEER_OUT", out)
	t.Setenv("CDT650_TEST_PREMISE_OUT", premise)

	ad := &hostadapter.Adapter{Agent: &shAgent{A: &agent.Agent{
		Runner: agent.Native{Stderr: io.Discard}}}}
	tickets := &fakeTickets{slug: "run-steer"}
	c := NewWithAdapter(eng, ad, WithTickets(tickets), WithModelMap(&fakeModels{}),
		WithPhone(&fakePhone{}))
	c.StartWait = 10 * time.Second

	const premiseText = "the defect premise"
	res, err := c.Route(context.Background(), RouteRequest{
		Kind: "defect", Title: "Steer me", Text: premiseText,
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

	// CDT-665: the correction was the SECOND frame. The route's premise
	// reached the session as its first turn, and the pair lands once.
	praw, err := os.ReadFile(premise)
	if err != nil {
		t.Fatalf("premise output: %v", err)
	}
	var pframe struct {
		Type    string `json:"type"`
		Message string `json:"message"`
	}
	if err := json.Unmarshal(praw, &pframe); err != nil {
		t.Fatalf("premise frame is not JSON: %v (%q)", err, praw)
	}
	if pframe.Message != premiseText {
		t.Errorf("first frame = %q, want the route's premise %q", praw, premiseText)
	}
	if n, o := premiseFrameRows(t, eng, res.RunID); n != 1 || o != 1 {
		t.Errorf("agent.premise rows = %d intents, %d outcomes, want one closed pair", n, o)
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
