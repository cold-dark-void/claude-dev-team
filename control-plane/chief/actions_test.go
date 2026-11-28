package chief

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/cold-dark-void/claude-dev-team/control-plane/agent"
	"github.com/cold-dark-void/claude-dev-team/control-plane/hostadapter"
	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
	"github.com/cold-dark-void/claude-dev-team/control-plane/run"
)

// actionsBaseKeyType marks the chief's base context in the action tests, so a
// resume can be proved to ride the service lifetime and not the request.
type actionsBaseKeyType struct{}

var actionsBaseKey actionsBaseKeyType

// actionsCall is one spawn the action tests' node-agent seam recorded.
type actionsCall struct {
	RunID   string
	Request agent.StartRequest
	// BaseCtx is true when the spawn rode the chief's base context.
	BaseCtx bool
}

// actionsStopCall is one stop verb the seam recorded.
type actionsStopCall struct {
	RunID string
	Grace time.Duration
}

// actionsAgent is the node-agent seam of the action tests. It mirrors the real
// verbs against the journal — a spawn claims, resumes a halted run, and
// records its attempt; a stop journals the named halt, and from claimed the
// halt alone — and it records the argv it was handed, so the tests read the
// seam's contract rather than a mock's bookkeeping.
type actionsAgent struct {
	mu    sync.Mutex
	calls []actionsCall
	stops []actionsStopCall
	// errs names the run ids the verb refuses, writing nothing.
	errs map[string]error
}

func (f *actionsAgent) Supervise(ctx context.Context, eng *journal.Engine,
	req agent.StartRequest, _ io.Writer) error {
	f.mu.Lock()
	f.calls = append(f.calls, actionsCall{RunID: req.RunID, Request: req,
		BaseCtx: ctx.Value(actionsBaseKey) != nil})
	f.mu.Unlock()
	if refusal := f.errs[req.RunID]; refusal != nil {
		return refusal
	}

	m := run.New(eng, req.RunID)
	token, err := m.Claim(ctx, takeoverOwner, req.Ticket, req.Workflow, req.Model)
	if err != nil {
		return err
	}
	st, err := m.State(ctx)
	if err != nil {
		return err
	}
	switch st.Status {
	case journal.StatusClaimed:
		// The real node agent journals the run-scoped caps on the start row
		// (SPEC-046 M7); the seam mirrors it so the journal proof is real.
		if err := m.StartWithCaps(ctx, takeoverOwner, token, req.Model,
			req.WallclockCapS, req.IterationCapS); err != nil {
			return err
		}
	case journal.StatusHalted:
		if err := m.Resume(ctx, takeoverOwner, token); err != nil {
			return err
		}
	}

	prior, err := countStartIntents(eng, req.RunID)
	if err != nil {
		return err
	}
	attempt := prior + 1
	seq, _, err := m.Intent(ctx, takeoverOwner, token,
		fmt.Sprintf("agent:start:%s#%d", req.RunID, attempt), agent.EffectStart,
		map[string]any{"command": req.Command, "args": req.Args, "attempt": attempt})
	if err != nil {
		return err
	}
	if _, err := m.Outcome(ctx, takeoverOwner, token, seq, agent.EffectStart,
		map[string]any{"pid": 4321, "attempt": attempt}); err != nil {
		return err
	}
	return m.Stint(ctx, takeoverOwner, token, fmt.Sprintf("attempt %d", attempt))
}

// Stop mirrors agent.Stop: from claimed the stop is the journal's named halt
// alone (nothing is signalled, so no agent.stop row is written); from running
// it is the intent, the outcome, and the halt.
func (f *actionsAgent) Stop(ctx context.Context, eng *journal.Engine,
	runID string, grace time.Duration) error {
	f.mu.Lock()
	f.stops = append(f.stops, actionsStopCall{RunID: runID, Grace: grace})
	f.mu.Unlock()

	m := run.New(eng, runID)
	st, err := m.State(ctx)
	if err != nil {
		return err
	}
	if st.Status == journal.StatusClaimed {
		return m.Halt(ctx, st.Owner, st.Token, run.ReasonOperatorHalt,
			"stopped by the operator before the run recorded a runner")
	}
	seq, _, err := m.Intent(ctx, st.Owner, st.Token, fmt.Sprintf("agent:stop:%s#1", runID),
		agent.EffectStop, map[string]any{"grace_s": int64(grace / time.Second), "pid": 4321})
	if err != nil {
		return err
	}
	if _, err := m.Outcome(ctx, st.Owner, st.Token, seq, agent.EffectStop,
		map[string]any{"stopped": true}); err != nil {
		return err
	}
	return m.Halt(ctx, st.Owner, st.Token, run.ReasonOperatorHalt,
		"stopped by the operator (pid 4321)")
}

func (f *actionsAgent) Steer(_ context.Context, _ *journal.Engine, _, _ string) error {
	return nil
}

func (f *actionsAgent) Status(_ context.Context, _ *journal.Engine,
	runID string) (agent.StatusReport, error) {
	return agent.StatusReport{RunID: runID, State: "running"}, nil
}

func (f *actionsAgent) recorded() []actionsCall {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]actionsCall(nil), f.calls...)
}

func (f *actionsAgent) stopCalls() []actionsStopCall {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]actionsStopCall(nil), f.stops...)
}

// callFor is the recorded call for one run id, and the test fails when the
// verb spawned nothing.
func callFor(t *testing.T, ag *actionsAgent, runID string) actionsCall {
	t.Helper()
	for _, call := range ag.recorded() {
		if call.RunID == runID {
			return call
		}
	}
	t.Fatalf("no spawn recorded for %s, want one", runID)
	return actionsCall{}
}

// newActionsChief wires one action test: the fake node agent behind the real
// host adapter, over the chief's base context.
func newActionsChief(t *testing.T, eng *journal.Engine, ag *actionsAgent) *Chief {
	t.Helper()
	c := NewWithAdapter(eng, &hostadapter.Adapter{Agent: ag},
		WithTickets(&fakeTickets{}), WithModelMap(&fakeModels{}), WithPhone(&fakePhone{}))
	c.StartWait = 5 * time.Second
	c.baseCtx = context.WithValue(context.Background(), actionsBaseKey, true)
	return c
}

// stateName replays one run and answers its state name.
func stateName(t *testing.T, eng *journal.Engine, runID string) string {
	t.Helper()
	st, err := eng.RunState(context.Background(), runID)
	if err != nil {
		t.Fatal(err)
	}
	return st.Name()
}

// seedRoutedRun leaves a run shaped like a ticket route: the claim names the
// ticket id, the workflow, and the model; the start record names the host
// command; the premise row carries the text the run was sent. terminal moves
// the run out to completed or failed; empty leaves it running.
func seedRoutedRun(t *testing.T, eng *journal.Engine, runID, command, premise, terminal string) {
	t.Helper()
	seedRoutedRunCaps(t, eng, runID, command, premise, terminal, 0, 0)
}

// seedRoutedRunCaps is seedRoutedRun with the operator's budget caps journaled
// on the run_started row (SPEC-046 M7) — the shape a retry must read back.
func seedRoutedRunCaps(t *testing.T, eng *journal.Engine, runID, command, premise,
	terminal string, wallclockCapS, iterationCapS int64) {
	t.Helper()
	ctx := context.Background()
	m := run.New(eng, runID)
	token, err := m.Claim(ctx, takeoverOwner, runID, "orchestrate", takeoverModel)
	if err != nil {
		t.Fatalf("claim %s: %v", runID, err)
	}
	if err := m.StartWithCaps(ctx, takeoverOwner, token, takeoverModel,
		wallclockCapS, iterationCapS); err != nil {
		t.Fatalf("start %s: %v", runID, err)
	}
	seedStartIntent(t, eng, runID, command)
	if premise != "" {
		seedPendingPremiseRow(t, eng, runID, premise)
	}
	switch terminal {
	case "failed":
		if err := m.Fail(ctx, takeoverOwner, token, "the run failed"); err != nil {
			t.Fatalf("fail %s: %v", runID, err)
		}
	case "completed":
		if err := m.Complete(ctx, takeoverOwner, token, nil, nil); err != nil {
			t.Fatalf("complete %s: %v", runID, err)
		}
	case "halted":
		if err := m.Halt(ctx, takeoverOwner, token, run.ReasonStalled, "watchdog"); err != nil {
			t.Fatalf("halt %s: %v", runID, err)
		}
	}
}

// AC2 (SPEC-045 M4): stop is the operator halt — from running on the node
// agent's signal path, and from claimed on the journal trail alone. Both land
// halted:operator_halt on the closed run_halted kind.
func TestStopHaltsRunningAndClaimedRuns(t *testing.T) {
	eng := newEngine(t)
	ag := &actionsAgent{}
	c := newActionsChief(t, eng, ag)
	seedTakeoverRunning(t, eng, "r-running", takeoverOwner, "grok")
	seedClaimed(t, eng, "r-claimed")

	for _, runID := range []string{"r-running", "r-claimed"} {
		res, err := c.Stop(context.Background(), runID)
		if err != nil {
			t.Fatalf("stop %s: %v", runID, err)
		}
		if res.RunID != runID || res.Halted != run.ReasonOperatorHalt {
			t.Errorf("stop %s = %+v, want the operator halt on the same run id", runID, res)
		}
		if got := stateName(t, eng, runID); got != "halted:operator_halt" {
			t.Errorf("stop %s left %s, want halted:operator_halt", runID, got)
		}
		if n := countRows(t, eng, runID, journal.KindRunHalted, ""); n != 1 {
			t.Errorf("stop %s wrote %d run_halted rows, want exactly one", runID, n)
		}
	}

	stops := ag.stopCalls()
	if len(stops) != 2 {
		t.Fatalf("stop verbs = %d, want one per run", len(stops))
	}
	if stops[0].RunID != "r-running" || stops[0].Grace != agent.DefaultGrace {
		t.Errorf("first stop = %+v, want r-running on the default grace", stops[0])
	}
	// The signal path is the node agent's own trail; the claimed stop signals
	// nothing, so it journals nothing that implies a signal.
	if n := countRows(t, eng, "r-running", journal.KindSideEffect, agent.EffectStop); n != 2 {
		t.Errorf("the running stop journaled %d agent.stop rows, want the intent and its outcome", n)
	}
	if n := countRows(t, eng, "r-claimed", journal.KindSideEffect, agent.EffectStop); n != 0 {
		t.Errorf("the claimed stop journaled %d agent.stop rows, want none", n)
	}
}

// seedResumableStall leaves a watchdog halt on a run that recorded both its
// spawn and its host session — the shape the operator resume reads. The session
// row lands before the halt, because the journal refuses a side effect from a
// halt state.
func seedResumableStall(t *testing.T, eng *journal.Engine, runID, command, sessionID string) {
	t.Helper()
	seedResumableStallCaps(t, eng, runID, command, sessionID, 0, 0)
}

// seedResumableStallCaps is seedResumableStall with the run's budget caps
// journaled on its run_started row (SPEC-046 M7).
func seedResumableStallCaps(t *testing.T, eng *journal.Engine, runID, command, sessionID string,
	wallclockCapS, iterationCapS int64) {
	t.Helper()
	seedTakeoverRunningCaps(t, eng, runID, takeoverOwner, command, wallclockCapS, iterationCapS)
	seedSessionRow(t, eng, runID, sessionID, true)
	m := run.New(eng, runID)
	if err := m.Halt(context.Background(), takeoverOwner, 1, run.ReasonStalled, "watchdog"); err != nil {
		t.Fatalf("halt %s: %v", runID, err)
	}
}

// AC2 (SPEC-045 M5): resume continues the same run through the takeover/resume
// seam. The Chief derives the host from the recorded start argv and the session
// id from the journaled agent.session row, spends one retry of the reason, and
// journals run_resumed — no new event kind and no new run id.
func TestResumeContinuesTheSameRunThroughTheResumeSeam(t *testing.T) {
	eng := newEngine(t)
	ag := &actionsAgent{}
	c := newActionsChief(t, eng, ag)
	seedResumableStall(t, eng, "CDT-700", "claude", "sess-9")

	res, err := c.Resume(context.Background(), "CDT-700")
	if err != nil {
		t.Fatalf("resume: %v", err)
	}
	if res.RunID != "CDT-700" || !res.Resumed {
		t.Fatalf("resume = %+v, want the same run id resumed", res)
	}

	calls := ag.recorded()
	if len(calls) != 1 {
		t.Fatalf("spawns = %d, want the one resume", len(calls))
	}
	call := calls[0]
	if call.Request.Command != "claude" {
		t.Errorf("resume command = %q, want the host the start record names", call.Request.Command)
	}
	if got := strings.Join(call.Request.Args, " "); got != "-p --resume sess-9" {
		t.Errorf("resume argv = %q, want the by-id invocation of the journaled session", got)
	}
	if !call.Request.OperatorResume {
		t.Errorf("the operator resume carried no operator switch")
	}
	if !call.BaseCtx {
		t.Errorf("the resume did not ride the chief's base context")
	}
	if call.Request.Ticket != takeoverTicket || call.Request.Workflow != takeoverWorkflow ||
		call.Request.Model != takeoverModel {
		t.Errorf("resume work = %+v, want the run's journaled ticket, workflow, and model",
			call.Request)
	}

	if n := countRows(t, eng, "CDT-700", journal.KindRunResumed, ""); n != 1 {
		t.Errorf("run_resumed rows = %d, want exactly one", n)
	}
	st, err := eng.RunState(context.Background(), "CDT-700")
	if err != nil {
		t.Fatal(err)
	}
	if st.Name() != string(journal.StatusRunning) {
		t.Errorf("state after the resume = %s, want running", st.Name())
	}
	if st.Ticket != takeoverTicket {
		t.Errorf("the resumed run carries ticket %q, want %q", st.Ticket, takeoverTicket)
	}
}

// AC2 (SPEC-045 M6): retry starts a NEW run at the next attempt of the same
// ticket — the same ticket field, workflow, and journaled model, the premise
// from the old run's agent.premise row, and the host from its start record.
// The old run keeps its terminal state: failed stays terminal.
func TestRetryStartsANewRunWithTheSameTicket(t *testing.T) {
	eng := newEngine(t)
	ag := &actionsAgent{}
	c := newActionsChief(t, eng, ag)
	seedRoutedRun(t, eng, "CDT-710", "grok", "/orchestrate CDT-710 --autopilot=auto", "failed")
	seedRoutedRun(t, eng, "CDT-730", "claude", "/orchestrate CDT-730 --autopilot=patch", "halted")
	failedBefore := lastSeq(t, eng, "CDT-710")

	res, err := c.Retry(context.Background(), "CDT-710", "")
	if err != nil {
		t.Fatalf("retry CDT-710: %v", err)
	}
	if res.RunID != "CDT-710-r2" {
		t.Fatalf("retry run id = %q, want the ticket's next attempt", res.RunID)
	}
	call := callFor(t, ag, "CDT-710-r2")
	if call.Request.Ticket != "CDT-710" || call.Request.Workflow != "orchestrate" ||
		call.Request.Model != takeoverModel {
		t.Errorf("retried work = %+v, want the same ticket, workflow, and journaled model",
			call.Request)
	}
	if call.Request.Premise != "/orchestrate CDT-710 --autopilot=auto" {
		t.Errorf("retried premise = %q, want the journaled premise", call.Request.Premise)
	}
	if call.Request.Command != "grok" {
		t.Errorf("retried host = %q, want the host the old start record names",
			call.Request.Command)
	}
	if call.Request.OperatorResume {
		t.Errorf("a retry start carried the operator-resume switch")
	}
	if got := stateName(t, eng, "CDT-710-r2"); got != string(journal.StatusRunning) {
		t.Errorf("the retried run is %s, want running", got)
	}
	st, err := eng.RunState(context.Background(), "CDT-710-r2")
	if err != nil {
		t.Fatal(err)
	}
	if st.Ticket != "CDT-710" {
		t.Errorf("the retried run carries ticket %q, want CDT-710", st.Ticket)
	}
	// The old run is untouched: failed stays terminal and gains no row.
	if got := stateName(t, eng, "CDT-710"); got != string(journal.StatusFailed) {
		t.Errorf("the retried run is %s, want failed (terminal, unchanged)", got)
	}
	if seq := lastSeq(t, eng, "CDT-710"); seq != failedBefore {
		t.Errorf("the retried run gained journal rows (last seq %d, was %d)", seq, failedBefore)
	}

	// A halted run retries the same way, and the attempt ladder keeps counting.
	res, err = c.Retry(context.Background(), "CDT-730", hostadapter.HostOmp)
	if err != nil {
		t.Fatalf("retry CDT-730: %v", err)
	}
	if res.RunID != "CDT-730-r2" {
		t.Errorf("retry of a halted run = %q, want CDT-730-r2", res.RunID)
	}
	if call := callFor(t, ag, "CDT-730-r2"); call.Request.Command != "omp" {
		t.Errorf("the named host was not carried: command = %q, want omp",
			call.Request.Command)
	}
	res, err = c.Retry(context.Background(), "CDT-710", "")
	if err != nil {
		t.Fatalf("repeat retry CDT-710: %v", err)
	}
	if res.RunID != "CDT-710-r3" {
		t.Errorf("repeat retry run id = %q, want the next attempt CDT-710-r3", res.RunID)
	}
}

// AC7 (SPEC-045 M4/M5/M6): every action refusal is distinct, typed, and served
// with its status code so the UI renders it verbatim.
func TestActionRefusalsAreDistinctAndTyped(t *testing.T) {
	eng := newEngine(t)
	ag := &actionsAgent{}
	c := newActionsChief(t, eng, ag)
	seedRunning(t, eng, "r-run")
	seedCompleted(t, eng, "r-done")
	seedFailed(t, eng, "r-failed")
	seedStall(run.ReasonOperatorHalt)(t, eng, "r-op")
	seedTakeoverStalled(t, eng, "r-nosess", takeoverOwner, "claude")
	seedStall(run.ReasonStalled)(t, eng, "r-nohost")

	cases := []struct {
		name  string
		verb  string
		runID string
		body  string
		want  error
	}{
		{"stop a completed run", "stop", "r-done", "", ErrNotStoppable},
		{"stop a failed run", "stop", "r-failed", "", ErrNotStoppable},
		{"resume a running run", "resume", "r-run", "", ErrNotResumable},
		{"resume a completed run", "resume", "r-done", "", ErrNotResumable},
		{"resume a spent budget", "resume", "r-op", "", ErrResumeSpent},
		{"resume with no journaled session", "resume", "r-nosess", "", ErrNoJournaledSession},
		{"resume with no recorded host", "resume", "r-nohost", "", ErrNotResumable},
		{"retry a running run", "retry", "r-run", "", ErrNotRetryable},
		{"retry a completed run", "retry", "r-done", "", ErrNotRetryable},
		{"retry on a host with no resume cell", "retry", "r-failed",
			`{"host":"mini-swe"}`, hostadapter.ErrUnsupportedCapability},
	}

	seen := map[string]string{}
	got := make([]error, len(cases))
	for i, tc := range cases {
		var err error
		switch tc.verb {
		case "stop":
			_, err = c.Stop(context.Background(), tc.runID)
		case "resume":
			_, err = c.Resume(context.Background(), tc.runID)
		case "retry":
			var req RetryRequest
			if tc.body != "" {
				if err := jsonUnmarshal([]byte(tc.body), &req); err != nil {
					t.Fatal(err)
				}
			}
			_, err = c.Retry(context.Background(), tc.runID, req.Host)
		}
		if !errors.Is(err, tc.want) {
			t.Errorf("%s: err = %v, want %v", tc.name, err, tc.want)
			got[i] = tc.want
			continue
		}
		got[i] = err
		if err == nil {
			t.Errorf("%s: no refusal", tc.name)
			continue
		}
		if other, dup := seen[err.Error()]; dup {
			t.Errorf("%s reuses the refusal of %s: %q", tc.name, other, err.Error())
		}
		seen[err.Error()] = tc.name
	}
	// The spent budget answers the replay's budget exhaustion, so the budget
	// rule stays the one the journal enforces.
	_, err := c.Resume(context.Background(), "r-op")
	if !errors.Is(err, journal.ErrBudgetExhausted) {
		t.Errorf("the spent budget = %v, want journal.ErrBudgetExhausted", err)
	}

	srv := httptest.NewServer(c.Handler())
	t.Cleanup(srv.Close)
	for i, tc := range cases {
		body := tc.body
		if body == "" {
			body = "{}"
		}
		status, out := postStatus(t, srv, "/v1/runs/"+tc.runID+"/"+tc.verb, body)
		// A matrix cell is the start's refusal (400); a state refusal is a
		// conflict on the run.
		want := http.StatusConflict
		if errors.Is(got[i], hostadapter.ErrUnsupportedCapability) {
			want = http.StatusBadRequest
		}
		if status != want {
			t.Errorf("%s over the API = %d %s, want %d", tc.name, status, out, want)
		}
		if !strings.Contains(string(out), got[i].Error()) {
			t.Errorf("%s over the API carries %s, want the refusal the UI renders (%q)",
				tc.name, out, got[i].Error())
		}
	}
	// An unknown run is a 404 on every verb, not a state refusal.
	for _, verb := range []string{"stop", "resume", "retry"} {
		status, out := postStatus(t, srv, "/v1/runs/r-nope/"+verb, "{}")
		if status != http.StatusNotFound || !strings.Contains(string(out), "chief: unknown run") {
			t.Errorf("%s of an unknown run = %d %s, want 404 with the typed error",
				verb, status, out)
		}
	}
}

// AC5 (SPEC-046 M10): a retry starts the next attempt with the same premise
// flags and the same caps, the caps recovered from the journaled run_started
// row of M7. The retry request body carries no option field to override them
// (RetryRequest names a host alone), and a run that carried no caps retries
// with none — the seam invents no budget.
func TestRetryCarriesTheOriginalOptionsAndCaps(t *testing.T) {
	eng := newEngine(t)
	ag := &actionsAgent{}
	c := newActionsChief(t, eng, ag)
	ctx := context.Background()
	premise := "/orchestrate CDT-677 --tier=full --autopilot=major"
	seedRoutedRunCaps(t, eng, "CDT-677", "grok", premise, "failed", 7200, 40)
	seedRoutedRun(t, eng, "CDT-678", "grok", "/orchestrate CDT-678 --autopilot=auto", "failed")

	res, err := c.Retry(ctx, "CDT-677", "")
	if err != nil {
		t.Fatalf("retry CDT-677: %v", err)
	}
	if res.RunID != "CDT-677-r2" {
		t.Fatalf("retry run id = %q, want the ticket's next attempt", res.RunID)
	}
	call := callFor(t, ag, "CDT-677-r2")
	if call.Request.WallclockCapS != 7200 || call.Request.IterationCapS != 40 {
		t.Errorf("retried caps = %d/%d, want the journaled 7200/40",
			call.Request.WallclockCapS, call.Request.IterationCapS)
	}
	if call.Request.Premise != premise {
		t.Errorf("retried premise = %q, want the journaled command %q",
			call.Request.Premise, premise)
	}
	if call.Request.Workflow != "orchestrate" || call.Request.Model != takeoverModel {
		t.Errorf("retried work = %+v, want the journaled workflow and model", call.Request)
	}
	// The new attempt's own start row carries the caps again: the journal of a
	// retried run is faithful, so a takeover of it reads the same values back.
	st, err := eng.RunState(ctx, "CDT-677-r2")
	if err != nil {
		t.Fatal(err)
	}
	if st.WallclockCapS != 7200 || st.IterationCapS != 40 {
		t.Errorf("journaled caps of the retry = %d/%d, want 7200/40",
			st.WallclockCapS, st.IterationCapS)
	}

	res, err = c.Retry(ctx, "CDT-678", "")
	if err != nil {
		t.Fatalf("retry CDT-678: %v", err)
	}
	bare := callFor(t, ag, "CDT-678-r2")
	if bare.Request.WallclockCapS != 0 || bare.Request.IterationCapS != 0 {
		t.Errorf("retried caps = %d/%d, want 0/0 for a run that carried none",
			bare.Request.WallclockCapS, bare.Request.IterationCapS)
	}
	bareState, err := eng.RunState(ctx, res.RunID)
	if err != nil {
		t.Fatal(err)
	}
	if bareState.WallclockCapS != 0 || bareState.IterationCapS != 0 {
		t.Errorf("journaled caps = %d/%d, want 0/0",
			bareState.WallclockCapS, bareState.IterationCapS)
	}
}

// AC8 (SPEC-046 M7 ruling): an operator resume reuses the host session by id
// and re-execs nothing, so the resume seam carries no caps — it is the
// unchanged Adapter.Resume invocation — and the caps the original start
// journaled stay the run's record. No second resume path, no new start row.
func TestResumeRidesTheUnchangedResumeSeam(t *testing.T) {
	eng := newEngine(t)
	ag := &actionsAgent{}
	c := newActionsChief(t, eng, ag)
	ctx := context.Background()
	seedResumableStallCaps(t, eng, "CDT-701", "claude", "sess-9", 3600, 25)

	res, err := c.Resume(ctx, "CDT-701")
	if err != nil {
		t.Fatalf("resume: %v", err)
	}
	if !res.Resumed {
		t.Fatalf("resume = %+v, want the run resumed", res)
	}
	calls := ag.recorded()
	if len(calls) != 1 {
		t.Fatalf("spawns = %d, want the one resume", len(calls))
	}
	call := calls[0]
	if !call.Request.OperatorResume {
		t.Errorf("the resume did not ride the operator-resume seam")
	}
	if got := strings.Join(call.Request.Args, " "); got != "-p --resume sess-9" {
		t.Errorf("resume argv = %q, want the unchanged by-id invocation", got)
	}
	if call.Request.WallclockCapS != 0 || call.Request.IterationCapS != 0 {
		t.Errorf("the resume carried caps %d/%d; the resume seam carries none (SPEC-046 M7)",
			call.Request.WallclockCapS, call.Request.IterationCapS)
	}
	if n := countRows(t, eng, "CDT-701", journal.KindRunStarted, ""); n != 1 {
		t.Errorf("run_started rows = %d, want the original one — the resume writes no start", n)
	}
	st, err := eng.RunState(ctx, "CDT-701")
	if err != nil {
		t.Fatal(err)
	}
	if st.WallclockCapS != 3600 || st.IterationCapS != 25 {
		t.Errorf("caps after the resume = %d/%d, want the journaled 3600/25 intact",
			st.WallclockCapS, st.IterationCapS)
	}
}
