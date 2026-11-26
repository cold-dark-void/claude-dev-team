package chief

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/cold-dark-void/claude-dev-team/control-plane/agent"
	"github.com/cold-dark-void/claude-dev-team/control-plane/hostadapter"
	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
	"github.com/cold-dark-void/claude-dev-team/control-plane/run"
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

// cdt672SeamCLI is the planted host CLI of the operator-action e2e. It prints
// the session frame, then appends every stdin frame it reads and blocks on the
// next read — the step boundary — so the run stays running until the operator
// stops it. The final `|| [ -n "$frame" ]` closes the loop on a last frame
// with no newline, and on EOF (the supervisor's pipe closing at shutdown) it
// ends the loop instead of spinning.
const cdt672SeamCLI = `#!/bin/sh
printf '%s\n' '{"type":"session","version":3,"id":"01a1ddda-7a27"}'
while read frame || [ -n "$frame" ]; do
	printf '%s\n' "$frame" >> "$CDT672_TEST_FRAMES"
done
`

// plantHostCLI puts an executable of the host's own CLI name on $PATH, so the
// node agent's native runner spawns the seam child under that name. The start
// record then carries the host the way a real start does — the run detail's
// host fold (SPEC-045 M7) and the retry's host derivation both read it out of
// that row, and a seam that renamed the command to sh would leave the fold
// empty.
func plantHostCLI(t *testing.T, name, body string) {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

// SPEC-045 AC1/AC2/AC3/AC7/AC8 as one operator journey, over the HTTP
// endpoints the web UI drives and nothing else: route an EXISTING ticket id,
// read the run detail, stop the run, take resume's spent-budget refusal
// (halted:operator_halt carries budget 0, so its recovery path is retry), then
// retry into the ticket's next attempt.
//
// The runner is a real child of this node on the adapter's own Client seam —
// the product's node-agent binding, not a test double — so the stop signals a
// live pid and the retried run spawns for real. Every journal row the journey
// writes stays in the closed event set.
func TestAOperatorRunsAnExistingTicketAndDrivesStopResumeRetryFromTheUI(t *testing.T) {
	// The steer seam supervises a real child, so it runs on the wide stall
	// limit (newEngineWideStall) — no beat races the action verbs.
	eng := newEngineWideStall(t)
	plantTicket(t, "CDT-672", "")
	root, argv := plantAutopilotParser(t, 0)
	frames := filepath.Join(t.TempDir(), "frames.txt")
	t.Setenv("CDT672_TEST_FRAMES", frames)
	plantHostCLI(t, "omp", cdt672SeamCLI)

	const command = "/orchestrate CDT-672 --autopilot=patch"
	tickets := &fakeTickets{slug: "CDT-672"}
	c := NewWithAdapter(eng, &hostadapter.Adapter{Agent: hostadapter.NewClient(
		&agent.Agent{Runner: agent.Native{Stderr: io.Discard}})},
		WithTickets(tickets), WithModelMap(&fakeModels{model: "opus", source: "map"}),
		WithPhone(&fakePhone{}), WithPluginRoot(root))
	c.StartWait = 10 * time.Second
	srv := httptest.NewServer(c.Handler())
	t.Cleanup(srv.Close)

	// Route (AC1/AC8): the existing id names the run, the composed command is
	// the premise, and the ticket seam is never called — the store gains no
	// record, on this route or the retry below.
	var routed RouteResult
	if err := json.Unmarshal(post(t, srv, "/v1/route",
		`{"kind":"ticket","ticket_id":"CDT-672","host":"omp","autopilot":"patch"}`),
		&routed); err != nil {
		t.Fatal(err)
	}
	if routed.RunID != "CDT-672" || routed.Command != command {
		t.Fatalf("route = %+v, want run CDT-672 with command %q", routed, command)
	}
	if routed.Surface.Name != "orchestrate" {
		t.Errorf("route surface = %q, want orchestrate", routed.Surface.Name)
	}
	if routed.Model != "opus" || routed.ModelSource != "map" {
		t.Errorf("route model = %q/%q, want the Model map resolution",
			routed.Model, routed.ModelSource)
	}
	if calls := tickets.recorded(); len(calls) != 0 {
		t.Errorf("ticket seam calls = %+v, want none (AC8)", calls)
	}
	raw, err := os.ReadFile(argv)
	if err != nil {
		t.Fatalf("the autopilot seam never ran: %v", err)
	}
	if !strings.Contains(string(raw), "--autopilot=patch") {
		t.Errorf("parser argv = %q, want the token as one argv value", raw)
	}

	// The run is in flight on a real runner — the state the stop verb needs.
	deadline := time.Now().Add(10 * time.Second)
	for {
		if apiState(t, srv, "CDT-672") == string(journal.StatusRunning) &&
			runReady("CDT-672") {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the routed run never started on the planted host CLI")
		}
		time.Sleep(25 * time.Millisecond)
	}

	// Detail (AC3): the pane's read of premise, host, model, state, attempt,
	// and the resume capability cell — all folded from the journal rows.
	deadline = time.Now().Add(10 * time.Second)
	var detail RunDetail
	for {
		detail = apiDetail(t, srv, "CDT-672")
		if detail.Premise == command {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("run detail = %+v, want the journaled premise %q", detail, command)
		}
		time.Sleep(25 * time.Millisecond)
	}
	if detail.State != string(journal.StatusRunning) {
		t.Errorf("detail state = %q, want running", detail.State)
	}
	if detail.Host != "omp" || !detail.ResumeSupported {
		t.Errorf("detail host = %q (resume_supported %v), want omp with the matrix's resume cell",
			detail.Host, detail.ResumeSupported)
	}
	if detail.Model != "opus" {
		t.Errorf("detail model = %q, want the routed model", detail.Model)
	}
	if detail.Ticket != "CDT-672" || detail.Workflow != "orchestrate" {
		t.Errorf("detail ticket/workflow = %q/%q, want CDT-672/orchestrate",
			detail.Ticket, detail.Workflow)
	}
	if detail.Attempt != 1 {
		t.Errorf("detail attempt = %d, want 1 (the plain slug is the first attempt)", detail.Attempt)
	}

	// The board row carries the same fold the ticket grouping reads (AC5).
	var grouped bool
	for _, row := range apiBoard(t, srv) {
		if row.RunID == "CDT-672" && row.Ticket == "CDT-672" && row.Attempt == 1 {
			grouped = true
		}
	}
	if !grouped {
		t.Error("the board carries no CDT-672 row grouped by its ticket at attempt 1")
	}

	// The journal row list and the output tail the pane polls (AC3). The
	// transcript is absent on this node, so the tail is the explicit empty
	// answer — a 200 with its reason, named by the journaled session id.
	rows := apiClosedKinds(t, srv, "CDT-672")
	if n := apiKindCount(rows, journal.KindRunClaimed); n != 1 {
		t.Errorf("run_claimed rows = %d, want one", n)
	}
	if n := apiKindCount(rows, journal.KindRunStarted); n != 1 {
		t.Errorf("run_started rows = %d, want one", n)
	}
	if i, o := apiCountEffect(rows, "agent.premise"); i != 1 || o != 1 {
		t.Errorf("agent.premise rows = %d intents, %d outcomes, want one closed pair", i, o)
	}
	var tail OutputTail
	if err := json.Unmarshal(get(t, srv, "/v1/runs/CDT-672/output?lines=5"), &tail); err != nil {
		t.Fatal(err)
	}
	if tail.Host != "omp" || tail.SessionID != "01a1ddda-7a27" {
		t.Errorf("output tail = %q/%q, want the omp host read by the journaled session id",
			tail.Host, tail.SessionID)
	}
	if len(tail.Lines) != 0 || tail.Reason == "" {
		t.Errorf("output tail = %d lines (reason %q), want the explicit empty answer with its reason",
			len(tail.Lines), tail.Reason)
	}

	// Stop (AC2): the operator halt on the node agent's signal path — 202, the
	// named halt, one run_halted row, and the closed agent.stop pair.
	status, out := postStatus(t, srv, "/v1/runs/CDT-672/stop", "{}")
	if status != http.StatusAccepted {
		t.Fatalf("stop = %d %s, want 202", status, out)
	}
	var stopped StopResult
	if err := json.Unmarshal(out, &stopped); err != nil {
		t.Fatal(err)
	}
	if stopped.RunID != "CDT-672" || stopped.Halted != run.ReasonOperatorHalt {
		t.Errorf("stop = %+v, want the operator halt on CDT-672", stopped)
	}
	stoppedState := apiState(t, srv, "CDT-672")
	if stoppedState != "halted:"+run.ReasonOperatorHalt {
		t.Fatalf("state after the stop = %q, want halted:%s", stoppedState, run.ReasonOperatorHalt)
	}
	rows = apiClosedKinds(t, srv, "CDT-672")
	if n := apiKindCount(rows, journal.KindRunHalted); n != 1 {
		t.Fatalf("run_halted rows = %d, want exactly one", n)
	}
	var halt journal.HaltPayload
	if err := json.Unmarshal(haltedRowPayload(t, rows), &halt); err != nil {
		t.Fatal(err)
	}
	if halt.Reason != run.ReasonOperatorHalt || halt.RetryBudget != 0 || halt.RetryRemaining != 0 {
		t.Errorf("halt row = %+v, want operator_halt with budget 0 spent", halt)
	}
	if i, o := apiCountEffect(rows, "agent.stop"); i != 1 || o != 1 {
		t.Errorf("agent.stop rows = %d intents, %d outcomes, want the closed signal pair", i, o)
	}

	// Resume (AC2/AC7): a stopped run is not resumable — operator_halt carries
	// budget 0 — and the refusal is the typed conflict the UI renders verbatim.
	// The answer is the same on a second attempt, and nothing is journaled.
	for attempt := 1; attempt <= 2; attempt++ {
		status, out = postStatus(t, srv, "/v1/runs/CDT-672/resume", "{}")
		if status != http.StatusConflict {
			t.Fatalf("resume %d = %d %s, want 409", attempt, status, out)
		}
		if !strings.Contains(string(out), "budget") ||
			!strings.Contains(string(out), run.ReasonOperatorHalt) {
			t.Errorf("resume %d refusal = %s, want the spent-budget refusal the UI renders",
				attempt, out)
		}
	}
	rows = apiClosedKinds(t, srv, "CDT-672")
	if n := apiKindCount(rows, journal.KindRunResumed); n != 0 {
		t.Errorf("run_resumed rows = %d, want none: the refusal wrote no row", n)
	}
	if got := apiState(t, srv, "CDT-672"); got != stoppedState {
		t.Errorf("state after the refused resumes = %q, want %q", got, stoppedState)
	}

	// Retry (AC2/AC6/M6): a NEW run at the ticket's next attempt, derived from
	// the old run's journal — the host from its start record, the premise from
	// its premise row — and the old run keeps its state and gains no row.
	before := lastSeqOf(t, srv, "CDT-672")
	status, out = postStatus(t, srv, "/v1/runs/CDT-672/retry", "{}")
	if status != http.StatusOK {
		t.Fatalf("retry = %d %s, want 200", status, out)
	}
	var retried RetryResult
	if err := json.Unmarshal(out, &retried); err != nil {
		t.Fatal(err)
	}
	if retried.RunID != "CDT-672-r2" {
		t.Fatalf("retry run id = %q, want the ticket's next attempt CDT-672-r2", retried.RunID)
	}
	deadline = time.Now().Add(10 * time.Second)
	var retryDetail RunDetail
	for {
		retryDetail = apiDetail(t, srv, "CDT-672-r2")
		if retryDetail.State == string(journal.StatusRunning) &&
			retryDetail.Premise == command {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("retried run detail = %+v, want running on the journaled premise %q",
				retryDetail, command)
		}
		time.Sleep(25 * time.Millisecond)
	}
	if retryDetail.Ticket != "CDT-672" || retryDetail.Workflow != "orchestrate" {
		t.Errorf("retried ticket/workflow = %q/%q, want CDT-672/orchestrate",
			retryDetail.Ticket, retryDetail.Workflow)
	}
	if retryDetail.Attempt != 2 {
		t.Errorf("retried attempt = %d, want 2", retryDetail.Attempt)
	}
	if retryDetail.Host != "omp" {
		t.Errorf("retried host = %q, want the host the old start record names", retryDetail.Host)
	}
	if retryDetail.Model != "opus" {
		t.Errorf("retried model = %q, want the journaled model", retryDetail.Model)
	}
	if seq := lastSeqOf(t, srv, "CDT-672"); seq != before {
		t.Errorf("the stopped run gained journal rows (last seq %d, was %d)", seq, before)
	}
	if got := apiState(t, srv, "CDT-672"); got != stoppedState {
		t.Errorf("the stopped run is %q after the retry, want it unchanged at %q", got, stoppedState)
	}

	// Both children ran: the retried session was sent the journaled premise as
	// its first turn, which is the frame its stdin received.
	for _, line := range waitForFrames(t, frames, 2) {
		if !strings.Contains(line, command) {
			t.Errorf("session frame = %q, want the journaled premise %q", line, command)
		}
	}

	// The whole journey stayed on the closed event set, and the store still
	// holds exactly the one item the operator routed (AC8).
	apiClosedKinds(t, srv, "CDT-672-r2")
	if calls := tickets.recorded(); len(calls) != 0 {
		t.Errorf("ticket seam calls after the retry = %+v, want none (AC8)", calls)
	}
	items, err := filepath.Glob(filepath.Join(os.Getenv("DEVTEAM_MROOT"),
		".claude", "backlog", "*.md"))
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 || filepath.Base(items[0]) != "CDT-672.md" {
		t.Errorf("store items = %v, want exactly CDT-672.md", items)
	}
}

// apiDetail reads one run's detail the way the detail pane does:
// GET /v1/runs/{run}.
func apiDetail(t *testing.T, srv *httptest.Server, runID string) RunDetail {
	t.Helper()
	var d RunDetail
	if err := json.Unmarshal(get(t, srv, "/v1/runs/"+runID), &d); err != nil {
		t.Fatal(err)
	}
	return d
}

// apiBoard reads the board: GET /v1/runs.
func apiBoard(t *testing.T, srv *httptest.Server) []RunDetail {
	t.Helper()
	var out struct {
		Runs []RunDetail `json:"runs"`
	}
	if err := json.Unmarshal(get(t, srv, "/v1/runs"), &out); err != nil {
		t.Fatal(err)
	}
	return out.Runs
}

// apiEvents reads a run's journal rows: GET /v1/runs/{run}/events.
func apiEvents(t *testing.T, srv *httptest.Server, runID string) []journal.Event {
	t.Helper()
	var out struct {
		Events []journal.Event `json:"events"`
	}
	if err := json.Unmarshal(get(t, srv, "/v1/runs/"+runID+"/events"), &out); err != nil {
		t.Fatal(err)
	}
	return out.Events
}

// apiClosedKinds reads a run's rows from the API and fails when the list is
// empty or names a kind outside the machine's closed set (CDT-642).
func apiClosedKinds(t *testing.T, srv *httptest.Server, runID string) []journal.Event {
	t.Helper()
	rows := apiEvents(t, srv, runID)
	if len(rows) == 0 {
		t.Fatalf("%s carries no journal rows", runID)
	}
	known := map[journal.Kind]bool{}
	for _, k := range journal.AllKinds {
		known[k] = true
	}
	for _, e := range rows {
		if !known[e.Kind] {
			t.Errorf("%s row kind %q is not a machine event kind", runID, e.Kind)
		}
	}
	return rows
}

// apiKindCount counts the rows of one kind.
func apiKindCount(rows []journal.Event, kind journal.Kind) int {
	n := 0
	for _, e := range rows {
		if e.Kind == kind {
			n++
		}
	}
	return n
}

// apiCountEffect counts one effect's intent and outcome rows.
func apiCountEffect(rows []journal.Event, effect string) (intents, outcomes int) {
	for _, e := range rows {
		if e.Kind != journal.KindSideEffect {
			continue
		}
		var ef journal.Effect
		if json.Unmarshal(e.Payload, &ef) != nil || ef.Effect != effect {
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

// haltedRowPayload is the payload of the run's single run_halted row.
func haltedRowPayload(t *testing.T, rows []journal.Event) json.RawMessage {
	t.Helper()
	for _, e := range rows {
		if e.Kind == journal.KindRunHalted {
			return e.Payload
		}
	}
	t.Fatal("no run_halted row")
	return nil
}

// lastSeqOf is the newest seq the API reports for a run — the marker a verb
// must not move on a run it does not touch.
func lastSeqOf(t *testing.T, srv *httptest.Server, runID string) int64 {
	t.Helper()
	var last int64
	for _, e := range apiEvents(t, srv, runID) {
		if e.Seq > last {
			last = e.Seq
		}
	}
	return last
}

// waitForFrames reads the seam child's appended frames once n of them land.
func waitForFrames(t *testing.T, path string, n int) []string {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		if raw, err := os.ReadFile(path); err == nil {
			text := strings.TrimRight(string(raw), "\n")
			if text != "" {
				lines := strings.Split(text, "\n")
				if len(lines) >= n {
					return lines
				}
			}
		}
		if time.Now().After(deadline) {
			t.Fatalf("frames file %s never carried %d frames", path, n)
		}
		time.Sleep(25 * time.Millisecond)
	}
}
