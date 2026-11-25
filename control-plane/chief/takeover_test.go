package chief

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/cold-dark-void/claude-dev-team/control-plane/agent"
	"github.com/cold-dark-void/claude-dev-team/control-plane/hostadapter"
	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
	"github.com/cold-dark-void/claude-dev-team/control-plane/reconcile"
	"github.com/cold-dark-void/claude-dev-team/control-plane/run"
)

const (
	takeoverOwner    = "node-agent-1"
	takeoverTicket   = "CDT-1"
	takeoverWorkflow = "debug"
	takeoverModel    = "sonnet"
)

// takeoverFixture is one AC1 row: a run seeded into one closed state and the
// selection the scan owes it. wantExpired is the answer at a clock past the
// journaled stall limit (the takeover clock); wantLive is the answer at the
// clock of the lease's own heartbeat (a live owner).
type takeoverFixture struct {
	name string
	// runID is the run the fixture writes; empty means the fixture writes
	// nothing at all.
	runID string
	seed  func(t *testing.T, eng *journal.Engine, runID string)
	// state is the replayed name the selected candidate must carry.
	state string
	// work is true when the fixture's claim row carries the ticket, the
	// workflow, and the model the candidate must carry.
	work bool

	wantExpired bool
	wantLive    bool
}

// takeoverFixtures is the closed AC1 set: one fixture per state in the select
// list and per state in the refuse list, plus the reconcile pseudo-Run.
func takeoverFixtures() []takeoverFixture {
	return []takeoverFixture{
		{"running with an expired lease", "r-running", seedRunning, "running", true, true, false},
		{"claimed with an expired lease", "r-claimed", seedClaimed, "claimed", true, true, false},
		{"halted:stalled", "r-stalled", seedStall(run.ReasonStalled), "halted:stalled", true, true, true},
		{"halted:operator_halt", "r-operator", seedStall(run.ReasonOperatorHalt), "", true, false, false},
		{"halted:lease_lost", "r-lease-lost", seedStall(run.ReasonLeaseLost), "", true, false, false},
		{"halted:reconcile_failed", "r-reconcile", seedStall(run.ReasonReconcileFailed), "", true, false, false},
		{"halted:budget_exhausted", "r-budget", seedStall(run.ReasonBudgetExhausted), "", true, false, false},
		{"completed", "r-completed", seedCompleted, "", true, false, false},
		{"failed", "r-failed", seedFailed, "", true, false, false},
		{"new", "", noRows, "", false, false, false},
		{"reconcile pseudo-Run", reconcile.JournalRun, seedRepair, "", false, false, false},
	}
}

func noRows(*testing.T, *journal.Engine, string) {}

// claim writes the run_claimed row and returns the machine and its token.
func claim(t *testing.T, eng *journal.Engine, runID string) (*run.Machine, int64) {
	t.Helper()
	m := run.New(eng, runID)
	token, err := m.Claim(context.Background(), takeoverOwner, takeoverTicket,
		takeoverWorkflow, takeoverModel)
	if err != nil {
		t.Fatalf("claim %s: %v", runID, err)
	}
	return m, token
}

func seedRunning(t *testing.T, eng *journal.Engine, runID string) {
	t.Helper()
	m, token := claim(t, eng, runID)
	if err := m.Start(context.Background(), takeoverOwner, token, takeoverModel); err != nil {
		t.Fatalf("start %s: %v", runID, err)
	}
}

// seedClaimed leaves the spawn-pending shape: a claim row and no run_started.
func seedClaimed(t *testing.T, eng *journal.Engine, runID string) {
	t.Helper()
	claim(t, eng, runID)
}

func seedStall(reason string) func(*testing.T, *journal.Engine, string) {
	return func(t *testing.T, eng *journal.Engine, runID string) {
		t.Helper()
		m, token := claim(t, eng, runID)
		if err := m.Start(context.Background(), takeoverOwner, token, takeoverModel); err != nil {
			t.Fatalf("start %s: %v", runID, err)
		}
		if err := m.Halt(context.Background(), takeoverOwner, token, reason, "fixture"); err != nil {
			t.Fatalf("halt %s: %v", runID, err)
		}
	}
}

func seedCompleted(t *testing.T, eng *journal.Engine, runID string) {
	t.Helper()
	m, token := claim(t, eng, runID)
	if err := m.Start(context.Background(), takeoverOwner, token, takeoverModel); err != nil {
		t.Fatalf("start %s: %v", runID, err)
	}
	if err := m.Complete(context.Background(), takeoverOwner, token, nil, nil); err != nil {
		t.Fatalf("complete %s: %v", runID, err)
	}
}

func seedFailed(t *testing.T, eng *journal.Engine, runID string) {
	t.Helper()
	m, token := claim(t, eng, runID)
	if err := m.Fail(context.Background(), takeoverOwner, token, "fixture"); err != nil {
		t.Fatalf("fail %s: %v", runID, err)
	}
}

// seedRepair writes the reconciler's own log: a repair row on the
// reconcile.JournalRun pseudo-Run.
func seedRepair(t *testing.T, eng *journal.Engine, runID string) {
	t.Helper()
	ev, err := journal.NewEvent(runID, journal.KindRepair, journal.RepairPayload{
		Target: "r-running", Observation: "state and reality differ", Action: "noop",
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := eng.Append(context.Background(), ev); err != nil {
		t.Fatalf("append repair: %v", err)
	}
}

// takeoverScan runs one pass and indexes the candidates by run id.
func takeoverScan(t *testing.T, c *Chief) map[string]takeoverCandidate {
	t.Helper()
	set, err := c.takeoverSet(context.Background())
	if err != nil {
		t.Fatalf("takeoverSet: %v", err)
	}
	out := map[string]takeoverCandidate{}
	for _, cand := range set {
		out[cand.RunID] = cand
	}
	return out
}

// AC1: the selection set is closed. Every state of the closed set is seeded in
// one journal and the scan selects exactly the M1 rows — and only the rows
// whose lease has expired at the scan clock.
func TestTakeoverSetSelection(t *testing.T) {
	eng := newEngine(t)
	fixtures := takeoverFixtures()
	for _, f := range fixtures {
		if f.runID != "" {
			f.seed(t, eng, f.runID)
		}
	}

	baseClock := time.Now().UTC()
	at := func(offset time.Duration) func() time.Time {
		return func() time.Time { return baseClock.Add(offset) }
	}
	// newEngine sets DEVTEAM_STALL_LIMIT=1, so every fixture lease's own stall
	// limit is 1 s: +30 s is past it, +0 s is inside it.
	expired := newTestChief(t, eng, &fakeAgent{}, &fakeTickets{}, &fakeModels{}, &fakePhone{})
	expired.Now = at(30 * time.Second)
	live := newTestChief(t, eng, &fakeAgent{}, &fakeTickets{}, &fakeModels{}, &fakePhone{})
	live.Now = at(0)

	gotExpired := takeoverScan(t, expired)
	gotLive := takeoverScan(t, live)

	for _, f := range fixtures {
		if _, leaked := gotExpired[reconcile.JournalRun]; leaked {
			t.Errorf("the %s pseudo-Run is in the selection set", reconcile.JournalRun)
		}
		cand, selected := gotExpired[f.runID]
		if selected != f.wantExpired {
			t.Errorf("%s: selected at the expired clock = %t, want %t",
				f.name, selected, f.wantExpired)
		}
		if _, selected = gotLive[f.runID]; selected != f.wantLive {
			t.Errorf("%s: selected at the live clock = %t, want %t",
				f.name, selected, f.wantLive)
		}
		if !f.wantExpired {
			continue
		}
		if cand.State != f.state {
			t.Errorf("%s: candidate state = %q, want %q", f.name, cand.State, f.state)
		}
		if !f.work {
			continue
		}
		if cand.Ticket != takeoverTicket || cand.Workflow != takeoverWorkflow ||
			cand.Model != takeoverModel {
			t.Errorf("%s: candidate work = %q/%q/%q, want %q/%q/%q", f.name,
				cand.Ticket, cand.Workflow, cand.Model,
				takeoverTicket, takeoverWorkflow, takeoverModel)
		}
	}
	if len(gotExpired) != 3 {
		t.Errorf("expired clock set = %v, want the three M1 rows", candidateIDs(gotExpired))
	}
	if len(gotLive) != 1 {
		t.Errorf("live clock set = %v, want only halted:stalled", candidateIDs(gotLive))
	}
}

func candidateIDs(set map[string]takeoverCandidate) []string {
	out := make([]string, 0, len(set))
	for id := range set {
		out = append(out, id)
	}
	return out
}

// AC1 as one closed-set decision: every state name, the lease gate, and the
// states a journal fixture cannot carry (no events at all, a nil replay).
func TestTakeoverSetSelectionPredicate(t *testing.T) {
	now := time.Now().UTC()
	liveLease := run.Lease{RunID: "r", Owner: takeoverOwner, Token: 1,
		LastHeartbeatTS: journal.FormatTS(now), StallLimitS: 600}
	staleLease := run.Lease{RunID: "r", Owner: takeoverOwner, Token: 1,
		LastHeartbeatTS: journal.FormatTS(now.Add(-time.Hour)), StallLimitS: 600}
	running := func() *journal.State {
		return &journal.State{RunID: "r", Status: journal.StatusRunning,
			Ticket: takeoverTicket, Workflow: takeoverWorkflow, Model: takeoverModel}
	}
	claimed := func() *journal.State {
		st := running()
		st.Status = journal.StatusClaimed
		return st
	}
	halted := func(reason string) *journal.State {
		st := running()
		st.Status = journal.StatusHalted
		st.Halt = &journal.Halt{Reason: reason, Budget: 1, Remaining: 1}
		return st
	}
	completed := func() *journal.State {
		st := running()
		st.Status, st.Terminal = journal.StatusCompleted, true
		return st
	}
	failed := func() *journal.State {
		st := running()
		st.Status, st.Terminal = journal.StatusFailed, true
		return st
	}

	rows := []struct {
		name       string
		state      *journal.State
		lease      run.Lease
		hasLease   bool
		wantSelect bool
	}{
		{"running with an expired lease", running(), staleLease, true, true},
		{"running with no lease row", running(), run.Lease{}, false, true},
		{"claimed with an expired lease", claimed(), staleLease, true, true},
		{"claimed with no lease row", claimed(), run.Lease{}, false, true},
		{"halted:stalled", halted(run.ReasonStalled), run.Lease{}, false, true},
		{"running with a live lease", running(), liveLease, true, false},
		{"claimed with a live lease", claimed(), liveLease, true, false},
		{"halted:operator_halt", halted(run.ReasonOperatorHalt), staleLease, true, false},
		{"halted:lease_lost", halted(run.ReasonLeaseLost), staleLease, true, false},
		{"halted:reconcile_failed", halted(run.ReasonReconcileFailed), staleLease, true, false},
		{"halted:budget_exhausted", halted(run.ReasonBudgetExhausted), staleLease, true, false},
		{"completed", completed(), staleLease, true, false},
		{"failed", failed(), staleLease, true, false},
		{"new", &journal.State{}, run.Lease{}, false, false},
		{"no replay at all", nil, run.Lease{}, false, false},
	}

	for _, r := range rows {
		cand, selected := takeoverSelect(r.state, r.lease, r.hasLease, now)
		if selected != r.wantSelect {
			t.Errorf("%s: selected = %t, want %t", r.name, selected, r.wantSelect)
		}
		if !selected {
			continue
		}
		if cand.RunID != "r" || cand.Ticket != takeoverTicket ||
			cand.Workflow != takeoverWorkflow || cand.Model != takeoverModel {
			t.Errorf("%s: candidate = %+v, want the run id and the journaled work",
				r.name, cand)
		}
	}
}

// ---------------------------------------------------------------------------
// T4 — the scan executor: one path, serial, per-run isolation
// (SPEC-044 M3/M5/M6/M12; AC3-AC6)
// ---------------------------------------------------------------------------

// takeoverCtxKey marks the two contexts the executor must not confuse: the
// spawn rides the chief's base context, never the scan's.
type takeoverCtxKey struct{ name string }

var (
	takeoverBaseKey = takeoverCtxKey{"base"}
	takeoverScanKey = takeoverCtxKey{"scan"}
)

// takeoverOwnerOf is the lease-owner shape this node's own agent writes
// (agent.Owner plus the supervisor pid).
func takeoverOwnerOf() string { return fmt.Sprintf("%s-%d", agent.Owner, os.Getpid()) }

// takeoverClock is a clock offset from the moment the fixtures are seeded.
// newEngine sets DEVTEAM_STALL_LIMIT=1, so +30s is past every fixture lease
// and +0s is inside it.
func takeoverClock(offset time.Duration) func() time.Time {
	base := time.Now().UTC()
	return func() time.Time { return base.Add(offset) }
}

// claimAs claims one run as one owner and returns its machine and token.
func claimAs(t *testing.T, eng *journal.Engine, runID, owner string) (*run.Machine, int64) {
	t.Helper()
	m := run.New(eng, runID)
	token, err := m.Claim(context.Background(), owner, takeoverTicket,
		takeoverWorkflow, takeoverModel)
	if err != nil {
		t.Fatalf("claim %s: %v", runID, err)
	}
	return m, token
}

// seedStartIntent records one agent.start spawn intent and its outcome: the
// row the takeover derives the host from.
func seedStartIntent(t *testing.T, eng *journal.Engine, runID, command string) {
	t.Helper()
	ctx := context.Background()
	raw, err := json.Marshal(map[string]any{"command": command, "args": []string{},
		"attempt": 1})
	if err != nil {
		t.Fatal(err)
	}
	ev, err := journal.NewEvent(runID, journal.KindSideEffect, journal.Effect{
		Effect: agent.EffectStart, Intent: raw})
	if err != nil {
		t.Fatal(err)
	}
	ev.IdempotencyKey = fmt.Sprintf("agent:start:%s#1", runID)
	seq, _, err := eng.AppendChecked(ctx, ev)
	if err != nil {
		t.Fatalf("append %s start intent: %v", runID, err)
	}
	out, err := journal.NewEvent(runID, journal.KindSideEffect, journal.Effect{
		Effect: agent.EffectStart, Intent: raw, Outcome: json.RawMessage(`{"pid":4321}`),
		IntentSeq: seq})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := eng.AppendChecked(ctx, out); err != nil {
		t.Fatalf("append %s start outcome: %v", runID, err)
	}
}

// seedTakeoverRunning leaves a run whose supervisor died mid-flight: claimed,
// started, and one recorded spawn intent on command.
func seedTakeoverRunning(t *testing.T, eng *journal.Engine, runID, owner, command string) {
	t.Helper()
	m, token := claimAs(t, eng, runID, owner)
	if err := m.Start(context.Background(), owner, token, takeoverModel); err != nil {
		t.Fatalf("start %s: %v", runID, err)
	}
	seedStartIntent(t, eng, runID, command)
}

// seedTakeoverStalled leaves a watchdog halt on a run that recorded its spawn.
func seedTakeoverStalled(t *testing.T, eng *journal.Engine, runID, owner, command string) {
	t.Helper()
	seedTakeoverRunning(t, eng, runID, owner, command)
	m := run.New(eng, runID)
	if err := m.Halt(context.Background(), owner, 1, run.ReasonStalled, "watchdog"); err != nil {
		t.Fatalf("halt %s: %v", runID, err)
	}
}

// takeoverCall is one Start the fake node agent recorded.
type takeoverCall struct {
	RunID   string
	Request agent.StartRequest
	// BaseCtx and ScanCtx name which context the spawn rode.
	BaseCtx bool
	ScanCtx bool
	// Proven names the runs whose takeover row had landed in the journal
	// when this Start began.
	Proven []string
}

// takeoverAgent is the node-agent seam of the executor tests. It drives the
// run's machine the way the real takeover does — the lease takeover at
// token+1, the stalled resume, the spawn intent and its outcome, the stint —
// and refuses the run ids its errs table names, writing nothing.
type takeoverAgent struct {
	mu    sync.Mutex
	calls []takeoverCall
	// steers records the control frames the chief sent to a taken-over run.
	steers []string
	errs   map[string]error
	delay  time.Duration
	now    func() time.Time
	// serial names each run's journal position before the pass, so every
	// call can record which earlier runs the journal had already proved at
	// its entry — the reading that the pass takes one run at a time (S2).
	serial map[string]int64
}

func (f *takeoverAgent) Supervise(ctx context.Context, eng *journal.Engine,
	req agent.StartRequest, _ io.Writer) error {
	f.mu.Lock()
	var proven []string
	if f.serial != nil {
		proven = f.provenRuns(ctx, eng)
	}
	f.calls = append(f.calls, takeoverCall{RunID: req.RunID, Request: req,
		BaseCtx: ctx.Value(takeoverBaseKey) != nil,
		ScanCtx: ctx.Value(takeoverScanKey) != nil,
		Proven:  proven})
	f.mu.Unlock()

	if f.delay > 0 {
		time.Sleep(f.delay)
	}
	if refusal := f.errs[req.RunID]; refusal != nil {
		return refusal
	}
	return f.journalTakeover(ctx, eng, req, f.clock())
}

// provenRuns is the subset of the serial set the journal proves as taken.
func (f *takeoverAgent) provenRuns(ctx context.Context, eng *journal.Engine) []string {
	var out []string
	for id, since := range f.serial {
		st, err := eng.RunState(ctx, id)
		if err != nil {
			continue
		}
		if st.LastSeq > since && st.Name() == string(journal.StatusRunning) {
			out = append(out, id)
		}
	}
	sort.Strings(out)
	return out
}

func (f *takeoverAgent) clock() func() time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.now
}

// journalTakeover is the takeover trail the node agent's start verb writes:
// the fencing token rises by one, a watchdog halt resumes, and the new
// attempt records its spawn.
func (f *takeoverAgent) journalTakeover(ctx context.Context, eng *journal.Engine,
	req agent.StartRequest, clock func() time.Time) error {
	m := run.New(eng, req.RunID)
	if clock != nil {
		m.Now = clock
	}
	owner := takeoverOwnerOf()
	token, err := m.Claim(ctx, owner, req.Ticket, req.Workflow, req.Model)
	if err != nil {
		return err
	}
	st, err := m.State(ctx)
	if err != nil {
		return err
	}
	switch st.Status {
	case journal.StatusClaimed:
		if err := m.Start(ctx, owner, token, req.Model); err != nil {
			return err
		}
	case journal.StatusHalted:
		if err := m.Resume(ctx, owner, token); err != nil {
			return err
		}
	}
	prior, err := countStartIntents(eng, req.RunID)
	if err != nil {
		return err
	}
	attempt := prior + 1
	key := fmt.Sprintf("agent:start:%s#%d", req.RunID, attempt)
	seq, _, err := m.Intent(ctx, owner, token, key, agent.EffectStart,
		map[string]any{"command": req.Command, "args": req.Args, "attempt": attempt})
	if err != nil {
		return err
	}
	if _, err := m.Outcome(ctx, owner, token, seq, agent.EffectStart,
		map[string]any{"pid": 4321, "attempt": attempt}); err != nil {
		return err
	}
	return m.Stint(ctx, owner, token, fmt.Sprintf("attempt %d", attempt))
}

func (f *takeoverAgent) Stop(_ context.Context, _ *journal.Engine, _ string,
	_ time.Duration) error {
	return nil
}

func (f *takeoverAgent) Steer(_ context.Context, _ *journal.Engine, _, frame string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.steers = append(f.steers, frame)
	return nil
}

func (f *takeoverAgent) steered() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.steers...)
}

func (f *takeoverAgent) Status(_ context.Context, _ *journal.Engine,
	runID string) (agent.StatusReport, error) {
	return agent.StatusReport{RunID: runID, State: "running"}, nil
}

func (f *takeoverAgent) recorded() []takeoverCall {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]takeoverCall(nil), f.calls...)
}

// newTakeoverChief wires one executor test: the fake node agent behind the
// real host adapter, and a base context the spawn must ride.
func newTakeoverChief(t *testing.T, eng *journal.Engine, ag *takeoverAgent,
	phone *fakePhone) *Chief {
	t.Helper()
	c := NewWithAdapter(eng, &hostadapter.Adapter{Agent: ag},
		WithTickets(&fakeTickets{}), WithModelMap(&fakeModels{}), WithPhone(phone))
	c.StartWait = 5 * time.Second
	c.baseCtx = context.WithValue(context.Background(), takeoverBaseKey, true)
	return c
}

// countStartIntents counts the agent.start intent rows a run carries.
func countStartIntents(eng *journal.Engine, runID string) (int, error) {
	events, err := eng.Events(context.Background(), runID)
	if err != nil {
		return 0, err
	}
	n := 0
	for _, ev := range events {
		if !ev.IntentRow() || ev.Kind != journal.KindSideEffect {
			continue
		}
		var ef journal.Effect
		if err := jsonUnmarshal(ev.Payload, &ef); err == nil && ef.Effect == agent.EffectStart {
			n++
		}
	}
	return n, nil
}

// startIntents is countStartIntents for a test assertion.
func startIntents(t *testing.T, eng *journal.Engine, runID string) int {
	t.Helper()
	n, err := countStartIntents(eng, runID)
	if err != nil {
		t.Fatal(err)
	}
	return n
}

// countRows counts one run's rows of one kind. effect names the side effect
// and is empty for the kinds that carry none.
func countRows(t *testing.T, eng *journal.Engine, runID string, kind journal.Kind,
	effect string) int {
	t.Helper()
	events, err := eng.Events(context.Background(), runID)
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, ev := range events {
		if ev.Kind != kind {
			continue
		}
		if effect == "" {
			n++
			continue
		}
		var ef journal.Effect
		if err := jsonUnmarshal(ev.Payload, &ef); err == nil && ef.Effect == effect {
			n++
		}
	}
	return n
}

// lastSeq is the run's journal position — the proof of "wrote nothing".
func lastSeq(t *testing.T, eng *journal.Engine, runID string) int64 {
	t.Helper()
	st, err := eng.RunState(context.Background(), runID)
	if err != nil {
		t.Fatal(err)
	}
	return st.LastSeq
}

// runIDsOf projects one report bucket to its run ids, in report order.
func runIDsOf(lines []TakeoverRun) []string {
	out := make([]string, 0, len(lines))
	for _, l := range lines {
		out = append(out, l.RunID)
	}
	return out
}

// joinReport is the report as one string, for the reason-text assertions.
func joinReport(rep TakeoverReport) string {
	var b strings.Builder
	for _, l := range append(append(append([]TakeoverRun(nil),
		rep.Taken...), rep.Skipped...), rep.Refused...) {
		fmt.Fprintf(&b, "%s %s %s: %s\n", l.Outcome, l.RunID, l.State, l.Reason)
	}
	for _, l := range rep.Unconfirmed {
		fmt.Fprintf(&b, "%s %s %s: %s\n", l.Outcome, l.RunID, l.State, l.Reason)
	}
	return b.String()
}

// captureTakeoverLog points the scan's report lines at a buffer for one test.
func captureTakeoverLog(t *testing.T) *bytes.Buffer {
	t.Helper()
	var buf bytes.Buffer
	old := takeoverLog
	takeoverLog = &buf
	t.Cleanup(func() { takeoverLog = old })
	return &buf
}

// proven reports whether a call's proof list names one run.
func proven(list []string, runID string) bool {
	for _, id := range list {
		if id == runID {
			return true
		}
	}
	return false
}

// AC3 + S2 + AC9: the scan takes the selection set over through the one
// spawn path — the host adapter's Start with the journaled ticket, workflow,
// model, and the host derived from the recorded start argv — serially, one
// run at a time, under the chief's base context, and pages nothing. The
// trail is the machine's own: the takeover token rises by one, the stalled
// run resumes, the new attempt records its spawn, and the scan journals no
// halt of its own.
func TestTakeoverScanSpawnsTheSelectedSet(t *testing.T) {
	_ = captureTakeoverLog(t)
	eng := newEngine(t)
	seedTakeoverRunning(t, eng, "r-running", takeoverOwner, "grok")
	seedClaimed(t, eng, "r-claimed")
	seedTakeoverStalled(t, eng, "r-stalled", takeoverOwner, "claude")
	seedTakeoverRunning(t, eng, "r-running2", takeoverOwner, "omp")
	seedCompleted(t, eng, "r-done")

	clock := takeoverClock(30 * time.Second)
	phone := &fakePhone{}
	taken := []string{"r-running", "r-stalled", "r-running2"}
	// The halt rows the journal already carries: the watchdog's own finding
	// on r-stalled. The scan adds none of its own. Each run's journal
	// position is the serial pass's proof point.
	halted := map[string]int{}
	before := map[string]int64{}
	for _, id := range taken {
		halted[id] = countRows(t, eng, id, journal.KindRunHalted, "")
		before[id] = lastSeq(t, eng, id)
	}
	ag := &takeoverAgent{delay: 20 * time.Millisecond, now: clock, serial: before}
	c := newTakeoverChief(t, eng, ag, phone)
	c.Now = clock

	rep, err := c.TakeoverScan(context.WithValue(context.Background(), takeoverScanKey, true))
	if err != nil {
		t.Fatalf("TakeoverScan: %v", err)
	}
	if got := runIDsOf(rep.Taken); strings.Join(got, ",") != "r-running,r-stalled,r-running2" {
		t.Errorf("taken = %v, want the selected runs in journal order (%s)",
			got, joinReport(rep))
	}
	if got := runIDsOf(rep.Skipped); strings.Join(got, ",") != "r-claimed" {
		t.Errorf("skipped = %v, want the spawn-pending run", got)
	}
	if len(rep.Refused) != 0 || len(rep.Unconfirmed) != 0 {
		t.Errorf("refused/unconfirmed = %v / %v, want none (%s)",
			runIDsOf(rep.Refused), runIDsOf(rep.Unconfirmed), joinReport(rep))
	}

	calls := ag.recorded()
	if len(calls) != 3 {
		t.Fatalf("starts = %d, want one per taken run (%s)", len(calls), joinReport(rep))
	}
	wantHosts := []string{"grok", "claude", "omp"}
	for i, call := range calls {
		if call.Request.Ticket != takeoverTicket || call.Request.Workflow != takeoverWorkflow ||
			call.Request.Model != takeoverModel {
			t.Errorf("call %d carries %q/%q/%q, want the journaled work", i,
				call.Request.Ticket, call.Request.Workflow, call.Request.Model)
		}
		if call.Request.Command != wantHosts[i] {
			t.Errorf("call %d launched %q, want the host the run's start record names (%q)",
				i, call.Request.Command, wantHosts[i])
		}
		if !call.BaseCtx {
			t.Errorf("call %d (%s) does not ride the chief's base context", i, call.RunID)
		}
		if call.ScanCtx {
			t.Errorf("call %d (%s) rides the scan's context, not the base context", i, call.RunID)
		}
	}
	// S2, DRI OQ4: the pass takes one run at a time — the journal proves
	// run N taken before the pass spawns run N+1.
	for i, call := range calls {
		for _, earlier := range calls[:i] {
			if !proven(call.Proven, earlier.RunID) {
				t.Errorf("start %d (%s) began before %s was proven taken; proven %v",
					i, call.RunID, earlier.RunID, call.Proven)
			}
		}
	}

	owner := takeoverOwnerOf()
	for _, runID := range taken {
		st, err := eng.RunState(context.Background(), runID)
		if err != nil {
			t.Fatal(err)
		}
		if st.Name() != "running" {
			t.Errorf("%s after takeover = %s, want running", runID, st.Name())
		}
		if st.Owner != owner || st.Token != 2 {
			t.Errorf("%s after takeover: owner %q token %d, want %q at token 2",
				runID, st.Owner, st.Token, owner)
		}
		if n := countRows(t, eng, runID, journal.KindRunHalted, ""); n != halted[runID] {
			t.Errorf("%s carries %d run_halted rows after the takeover, want the %d it came with",
				runID, n, halted[runID])
		}
		// The re-spawn's intent rides the async path: await it before the
		// count assert reads the journal.
		awaitStartIntents(t, eng, runID, 2)
		if n := startIntents(t, eng, runID); n != 2 {
			t.Errorf("%s carries %d spawn intents, want the journaled one plus the re-spawn",
				runID, n)
		}
	}
	takeoverRows := leaseAcquired(t, eng, "r-running")
	if takeoverRows.Owner != owner || takeoverRows.Token != 2 ||
		takeoverRows.Reason != "takeover" {
		t.Errorf("lease_acquired = %+v, want the local owner at token 2 with reason takeover",
			takeoverRows)
	}
	if n := countRows(t, eng, "r-stalled", journal.KindRunResumed, ""); n != 1 {
		t.Errorf("r-stalled resumed %d times, want 1 (the stalled budget pays for the takeover)", n)
	}
	if n := countRows(t, eng, "r-running2", journal.KindStintStarted, ""); n != 1 {
		t.Errorf("r-running2 stints = %d, want the new attempt journaled", n)
	}
	if pages := phone.recorded(); len(pages) != 0 {
		t.Errorf("the takeover paged %v, want no page (AC9)", pages)
	}
}

// leaseAcquired returns the run's takeover lease row.
func leaseAcquired(t *testing.T, eng *journal.Engine, runID string) journal.LeasePayload {
	t.Helper()
	events, err := eng.Events(context.Background(), runID)
	if err != nil {
		t.Fatal(err)
	}
	var out journal.LeasePayload
	found := false
	for _, ev := range events {
		if ev.Kind != journal.KindLeaseAcquire {
			continue
		}
		var p journal.LeasePayload
		if err := jsonUnmarshal(ev.Payload, &p); err != nil {
			t.Fatal(err)
		}
		out, found = p, true
	}
	if !found {
		t.Fatalf("%s carries no lease_acquired row", runID)
	}
	return out
}

// AC6 + AC4: every per-run refusal is isolated. A matrix refusal, no runner
// selection, a terminal state, a held lease, a spent budget, and an
// unlaunchable command each stop their own run: the report names the reason,
// the run's journal and lease are untouched, the scan continues with the
// next run, and the API keeps serving.
func TestTakeoverScanIsolatesPerRunRefusals(t *testing.T) {
	_ = captureTakeoverLog(t)
	eng := newEngine(t)
	rows := []struct {
		runID string
		err   error
		want  string
	}{
		{"r-refusal", hostadapter.Refusal{Cell: hostadapter.Cell{
			Host: hostadapter.HostMiniSwe, Capability: hostadapter.CapHeadlessStream,
			Verdict: hostadapter.VerdictUnsupported, Citation: "matrix mini-swe (b)"}},
			"mini-swe"},
		{"r-norunner", agent.ErrNoRunnerSelected, "no runner selected"},
		{"r-terminal", journal.ErrTerminalState, "terminal"},
		{"r-lease", journal.ErrLeaseHeld, "lease held"},
		{"r-budget", journal.ErrBudgetExhausted, "budget"},
		{"r-command", fmt.Errorf("agent: no runner command configured"), "no runner command"},
	}
	errs := map[string]error{}
	before := map[string]int64{}
	for _, r := range rows {
		seedTakeoverRunning(t, eng, r.runID, takeoverOwner, "grok")
		errs[r.runID] = r.err
		before[r.runID] = lastSeq(t, eng, r.runID)
	}
	seedTakeoverRunning(t, eng, "r-clean", takeoverOwner, "grok")

	clock := takeoverClock(30 * time.Second)
	phone := &fakePhone{}
	ag := &takeoverAgent{errs: errs, now: clock}
	c := newTakeoverChief(t, eng, ag, phone)
	c.Now = clock

	rep, err := c.TakeoverScan(context.Background())
	if err != nil {
		t.Fatalf("TakeoverScan: %v", err)
	}
	if got := runIDsOf(rep.Refused); strings.Join(got, ",") !=
		"r-refusal,r-norunner,r-terminal,r-lease,r-budget,r-command" {
		t.Errorf("refused = %v, want every refused run in order (%s)", got, joinReport(rep))
	}
	for i, r := range rows {
		if !strings.Contains(rep.Refused[i].Reason, r.want) {
			t.Errorf("%s: refusal reason %q lacks %q", r.runID, rep.Refused[i].Reason, r.want)
		}
	}
	if got := runIDsOf(rep.Taken); strings.Join(got, ",") != "r-clean" {
		t.Errorf("taken = %v, want the clean run after the refusals", got)
	}
	if len(rep.Skipped) != 0 {
		t.Errorf("skipped = %v, want none", runIDsOf(rep.Skipped))
	}
	for _, r := range rows {
		if seq := lastSeq(t, eng, r.runID); seq != before[r.runID] {
			t.Errorf("%s: a refused takeover wrote rows (last seq %d, was %d)",
				r.runID, seq, before[r.runID])
		}
	}
	// AC4: the held lease stays exactly as it was — owner, token, and row.
	lease, err := run.New(eng, "r-lease").ReadLease(context.Background())
	if err != nil {
		t.Fatalf("read r-lease lease: %v", err)
	}
	if lease.Owner != takeoverOwner || lease.Token != 1 {
		t.Errorf("r-lease lease = %+v, want the held owner at token 1", lease)
	}
	if pages := phone.recorded(); len(pages) != 0 {
		t.Errorf("the takeover pass paged %v, want no page (AC9)", pages)
	}
	// AC6/AC7: chiefd keeps serving after the refusals.
	srv := httptest.NewServer(c.Handler())
	t.Cleanup(srv.Close)
	resp, err := http.Get(srv.URL + "/v1/runs")
	if err != nil {
		t.Fatalf("GET /v1/runs: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("GET /v1/runs = %d after the refusals, want 200", resp.StatusCode)
	}
}

// AC5: a selected run with no agent.start intent row has no host to derive.
// The scan skips it, names it on chiefd's stdout, spawns nothing for it,
// writes nothing for it, and continues with the next run.
func TestTakeoverScanSkipsASelectedRunThatRecordsNoHost(t *testing.T) {
	eng := newEngine(t)
	seedRunning(t, eng, "r-nohost")
	seedTakeoverRunning(t, eng, "r-grok", takeoverOwner, "grok")
	before := lastSeq(t, eng, "r-nohost")

	out := captureTakeoverLog(t)
	clock := takeoverClock(30 * time.Second)
	ag := &takeoverAgent{now: clock}
	c := newTakeoverChief(t, eng, ag, &fakePhone{})
	c.Now = clock

	rep, err := c.TakeoverScan(context.Background())
	if err != nil {
		t.Fatalf("TakeoverScan: %v", err)
	}
	if got := runIDsOf(rep.Skipped); strings.Join(got, ",") != "r-nohost" {
		t.Errorf("skipped = %v, want r-nohost (%s)", got, joinReport(rep))
	}
	if !strings.Contains(rep.Skipped[0].Reason, agent.EffectStart) {
		t.Errorf("skip reason %q does not name the missing %s intent",
			rep.Skipped[0].Reason, agent.EffectStart)
	}
	if got := runIDsOf(rep.Taken); strings.Join(got, ",") != "r-grok" {
		t.Errorf("taken = %v, want the scan to continue with the next run", got)
	}
	if seq := lastSeq(t, eng, "r-nohost"); seq != before {
		t.Errorf("the skipped run gained rows (last seq %d, was %d)", seq, before)
	}
	for _, call := range ag.recorded() {
		if call.RunID == "r-nohost" {
			t.Errorf("the skipped run was spawned: %+v", call)
		}
	}
	line := out.String()
	if !strings.Contains(line, "r-nohost") || !strings.Contains(line, string(TakeoverSkipped)) {
		t.Errorf("stdout = %q, want one report line naming the skipped run", line)
	}
	if strings.Contains(line, "r-grok") {
		t.Errorf("stdout = %q, want a line for the skip only — a taken run reports nothing", line)
	}

	// M2 + S1: the scan repeats. The next pass reports the same skip (the
	// journal's truth, unchanged) and writes the line once — a run that
	// stays skipped must not fill journald every tick.
	out.Reset()
	rep2, err := c.TakeoverScan(context.Background())
	if err != nil {
		t.Fatalf("second TakeoverScan: %v", err)
	}
	if got := runIDsOf(rep2.Skipped); strings.Join(got, ",") != "r-nohost" {
		t.Errorf("second pass skipped = %v, want the run still skipped", got)
	}
	if second := out.String(); second != "" {
		t.Errorf("second pass wrote %q, want no repeat of the same report line", second)
	}
}

// M6: a start record whose command the adapter cannot launch is a refusal,
// never a silent skip.
func TestTakeoverScanRefusesAnUnknownStartCommand(t *testing.T) {
	_ = captureTakeoverLog(t)
	eng := newEngine(t)
	seedRunning(t, eng, "r-weird")
	seedStartIntent(t, eng, "r-weird", "hermes")
	seedTakeoverRunning(t, eng, "r-grok", takeoverOwner, "grok")

	clock := takeoverClock(30 * time.Second)
	ag := &takeoverAgent{now: clock}
	c := newTakeoverChief(t, eng, ag, &fakePhone{})
	c.Now = clock

	rep, err := c.TakeoverScan(context.Background())
	if err != nil {
		t.Fatalf("TakeoverScan: %v", err)
	}
	if got := runIDsOf(rep.Refused); strings.Join(got, ",") != "r-weird" {
		t.Errorf("refused = %v, want r-weird (%s)", got, joinReport(rep))
	}
	if !strings.Contains(rep.Refused[0].Reason, "hermes") {
		t.Errorf("refusal reason %q does not name the command it refused", rep.Refused[0].Reason)
	}
	if len(rep.Skipped) != 0 {
		t.Errorf("skipped = %v, want the unknown command refused, not skipped",
			runIDsOf(rep.Skipped))
	}
	if got := runIDsOf(rep.Taken); strings.Join(got, ",") != "r-grok" {
		t.Errorf("taken = %v, want the scan to continue", got)
	}
}

// AC12: the scan is node-local. A run whose records name a runner on another
// node is refused, the refusal text names the boundary, and nothing is
// spawned for it.
func TestTakeoverScanRefusesARunnerOnAnotherNode(t *testing.T) {
	_ = captureTakeoverLog(t)
	eng := newEngine(t)
	const remote = "node-9:node-agent-4321"
	seedTakeoverRunning(t, eng, "r-remote", remote, "grok")
	seedTakeoverRunning(t, eng, "r-local", takeoverOwner, "grok")
	before := lastSeq(t, eng, "r-remote")

	clock := takeoverClock(30 * time.Second)
	ag := &takeoverAgent{now: clock}
	c := newTakeoverChief(t, eng, ag, &fakePhone{})
	c.Now = clock

	rep, err := c.TakeoverScan(context.Background())
	if err != nil {
		t.Fatalf("TakeoverScan: %v", err)
	}
	if got := runIDsOf(rep.Refused); strings.Join(got, ",") != "r-remote" {
		t.Errorf("refused = %v, want the foreign-node run (%s)", got, joinReport(rep))
	}
	if !strings.Contains(rep.Refused[0].Reason, "node-local") ||
		!strings.Contains(rep.Refused[0].Reason, remote) {
		t.Errorf("refusal reason %q does not name the node-local boundary and the owner",
			rep.Refused[0].Reason)
	}
	if got := runIDsOf(rep.Taken); strings.Join(got, ",") != "r-local" {
		t.Errorf("taken = %v, want the local run", got)
	}
	for _, call := range ag.recorded() {
		if call.RunID == "r-remote" {
			t.Errorf("the scan spawned a runner on another node: %+v", call)
		}
	}
	if seq := lastSeq(t, eng, "r-remote"); seq != before {
		t.Errorf("the foreign-node run gained rows (last seq %d, was %d)", seq, before)
	}
}

// AC4: a live lease is not selected — nothing is spawned for it and its
// journal is untouched.
func TestTakeoverScanLeavesALiveLeaseAlone(t *testing.T) {
	_ = captureTakeoverLog(t)
	eng := newEngine(t)
	// The 1 s limit newEngine pins leaves a 1 s live window: under package
	// parallelism the seed→scan gap can cross it and the scan takes the lease.
	// 600 s is a window the fixture gap can never cross.
	t.Setenv("DEVTEAM_STALL_LIMIT", "600")
	seedTakeoverRunning(t, eng, "r-live", takeoverOwner, "grok")
	before := lastSeq(t, eng, "r-live")

	ag := &takeoverAgent{now: takeoverClock(0)}
	c := newTakeoverChief(t, eng, ag, &fakePhone{})
	c.Now = takeoverClock(0)

	rep, err := c.TakeoverScan(context.Background())
	if err != nil {
		t.Fatalf("TakeoverScan: %v", err)
	}
	if len(rep.Taken)+len(rep.Skipped)+len(rep.Refused)+len(rep.Unconfirmed) != 0 {
		t.Errorf("report = %s, want an empty pass", joinReport(rep))
	}
	if calls := ag.recorded(); len(calls) != 0 {
		t.Errorf("starts = %v, want none for a live lease", calls)
	}
	if seq := lastSeq(t, eng, "r-live"); seq != before {
		t.Errorf("the live run gained rows (last seq %d, was %d)", seq, before)
	}
}

// ---------------------------------------------------------------------------
// SPEC-044 CDT-661 AC3/AC4 — adoption resumes the journaled host session
// ---------------------------------------------------------------------------

// seedSessionRow records the run's agent.session row: the intent and, when
// closed, its outcome — the shape the node agent's capture-time journaling
// writes (CDT-661 AC1). closed=false is the crash window between the two
// back-to-back appends.
func seedSessionRow(t *testing.T, eng *journal.Engine, runID, id string, closed bool) {
	t.Helper()
	ctx := context.Background()
	raw, err := json.Marshal(map[string]any{"session_id": id, "attempt": 1})
	if err != nil {
		t.Fatal(err)
	}
	ev, err := journal.NewEvent(runID, journal.KindSideEffect, journal.Effect{
		Effect: agent.EffectSession, Intent: raw})
	if err != nil {
		t.Fatal(err)
	}
	ev.IdempotencyKey = fmt.Sprintf("agent:session:%s#1", runID)
	seq, _, err := eng.AppendChecked(ctx, ev)
	if err != nil {
		t.Fatalf("append %s session intent: %v", runID, err)
	}
	if !closed {
		return
	}
	out, err := journal.NewEvent(runID, journal.KindSideEffect, journal.Effect{
		Effect: agent.EffectSession, Intent: raw, Outcome: raw, IntentSeq: seq})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := eng.AppendChecked(ctx, out); err != nil {
		t.Fatalf("append %s session outcome: %v", runID, err)
	}
}

// seedPendingPremiseRow records the crash window CDT-665 M16 names: the run's
// agent.premise intent row with no outcome — the intent landed and the frame
// never reached the child. The effect name is spelled out (the chief package
// names no agent effect of its own), as the CDT-661 seeding helper does.
func seedPendingPremiseRow(t *testing.T, eng *journal.Engine, runID, text string) {
	t.Helper()
	raw, err := json.Marshal(map[string]any{"premise": text, "attempt": 1})
	if err != nil {
		t.Fatal(err)
	}
	ev, err := journal.NewEvent(runID, journal.KindSideEffect, journal.Effect{
		Effect: "agent.premise", Intent: raw})
	if err != nil {
		t.Fatal(err)
	}
	ev.IdempotencyKey = fmt.Sprintf("agent:premise:%s#1", runID)
	if _, _, err := eng.AppendChecked(context.Background(), ev); err != nil {
		t.Fatalf("append %s premise intent: %v", runID, err)
	}
}

// lastStartIntentArgs is the argv of the run's newest agent.start intent.
func lastStartIntentArgs(t *testing.T, eng *journal.Engine, runID string) []string {
	t.Helper()
	events, err := eng.Events(context.Background(), runID)
	if err != nil {
		t.Fatal(err)
	}
	var args []string
	for _, ev := range events {
		if ev.Kind != journal.KindSideEffect || !ev.IntentRow() {
			continue
		}
		var ef journal.Effect
		if err := jsonUnmarshal(ev.Payload, &ef); err != nil || ef.Effect != agent.EffectStart {
			continue
		}
		var intent struct {
			Args []string `json:"args"`
		}
		if err := jsonUnmarshal(ef.Intent, &intent); err == nil {
			args = intent.Args
		}
	}
	return args
}

// awaitStartIntents blocks until the run's journal carries n agent.start
// intents, polling every 10 ms up to a 5 s deadline. The resume path appends
// its spawn intent AFTER the lease claim, and takeoverWatch proves the
// takeover off lease_acquired — which can land first — so the asserts that
// read the intents must await the append, not bare-read it.
func awaitStartIntents(t *testing.T, eng *journal.Engine, runID string, n int) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		got := startIntents(t, eng, runID)
		if got >= n {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("start intents = %d, want %d within 5s", got, n)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// AC3: a selected run whose journal carries a closed captured session id is
// re-supervised through Adapter.Resume — the host's by-id invocation rides
// the one takeover path, the newest spawn intent carries the resume argv at
// attempt N+1, and the report names the resumed session (S1).
func TestTakeoverScanResumesTheJournaledSession(t *testing.T) {
	_ = captureTakeoverLog(t)
	eng := newEngine(t)
	seedTakeoverRunning(t, eng, "r-run", takeoverOwner, "claude")
	seedSessionRow(t, eng, "r-run", "sess-1", true)

	ag := &takeoverAgent{now: takeoverClock(30 * time.Second)}
	c := newTakeoverChief(t, eng, ag, &fakePhone{})
	c.Now = takeoverClock(30 * time.Second)

	rep, err := c.TakeoverScan(context.Background())
	if err != nil {
		t.Fatalf("TakeoverScan: %v", err)
	}
	if got := runIDsOf(rep.Taken); strings.Join(got, ",") != "r-run" {
		t.Fatalf("taken = %v, want r-run (%s)", got, joinReport(rep))
	}
	if !strings.Contains(joinReport(rep), "resumed host session sess-1") {
		t.Errorf("the report does not name the resumed session: %s", joinReport(rep))
	}
	calls := ag.recorded()
	if len(calls) != 1 {
		t.Fatalf("starts = %d, want one", len(calls))
	}
	call := calls[0]
	if call.Request.Command != "claude" {
		t.Errorf("resume command = %q, want the host CLI", call.Request.Command)
	}
	if got := strings.Join(call.Request.Args, " "); got != "-p --resume sess-1" {
		t.Errorf("resume argv = %q, want the host's by-id invocation", got)
	}
	if !call.BaseCtx {
		t.Errorf("the resume does not ride the chief's base context")
	}
	// The resume's spawn intent rides the async path: await it before the
	// argv/count asserts read the journal.
	awaitStartIntents(t, eng, "r-run", 2)
	if got := strings.Join(lastStartIntentArgs(t, eng, "r-run"), " "); got != "-p --resume sess-1" {
		t.Errorf("the newest spawn intent carries %q, want the resume argv", got)
	}
	if n := startIntents(t, eng, "r-run"); n != 2 {
		t.Errorf("start intents = %d, want the recorded start plus the resume at attempt N+1", n)
	}
	st, err := eng.RunState(context.Background(), "r-run")
	if err != nil {
		t.Fatal(err)
	}
	if st.Name() != "running" {
		t.Errorf("state after the resumed takeover = %s, want running", st.Name())
	}
}

// AC3 + the reconciler landmine's twin: a pending agent.session intent — the
// crash window between the two back-to-back appends — carries the id too,
// so the resume rides it.
func TestTakeoverScanResumesFromAPendingSessionIntent(t *testing.T) {
	_ = captureTakeoverLog(t)
	eng := newEngine(t)
	seedTakeoverRunning(t, eng, "r-run", takeoverOwner, "grok")
	seedSessionRow(t, eng, "r-run", "sess-pending", false)

	ag := &takeoverAgent{now: takeoverClock(30 * time.Second)}
	c := newTakeoverChief(t, eng, ag, &fakePhone{})
	c.Now = takeoverClock(30 * time.Second)

	rep, err := c.TakeoverScan(context.Background())
	if err != nil {
		t.Fatalf("TakeoverScan: %v", err)
	}
	if got := runIDsOf(rep.Taken); strings.Join(got, ",") != "r-run" {
		t.Fatalf("taken = %v, want r-run (%s)", got, joinReport(rep))
	}
	calls := ag.recorded()
	if len(calls) != 1 {
		t.Fatalf("starts = %d, want one", len(calls))
	}
	want := "-p --output-format json --resume sess-pending"
	if got := strings.Join(calls[0].Request.Args, " "); got != want {
		t.Errorf("resume argv = %q, want %q", got, want)
	}
}

// AC4: with no journaled session id the scan re-spawns fresh — CDT-660's
// path, the host's headless launch argv, no resume flag, unchanged.
func TestTakeoverScanSpawnsFreshWhenNoSessionIsJournaled(t *testing.T) {
	_ = captureTakeoverLog(t)
	eng := newEngine(t)
	seedTakeoverRunning(t, eng, "r-run", takeoverOwner, "claude")

	ag := &takeoverAgent{now: takeoverClock(30 * time.Second)}
	c := newTakeoverChief(t, eng, ag, &fakePhone{})
	c.Now = takeoverClock(30 * time.Second)

	rep, err := c.TakeoverScan(context.Background())
	if err != nil {
		t.Fatalf("TakeoverScan: %v", err)
	}
	if got := runIDsOf(rep.Taken); strings.Join(got, ",") != "r-run" {
		t.Fatalf("taken = %v, want r-run (%s)", got, joinReport(rep))
	}
	if strings.Contains(joinReport(rep), "resumed") {
		t.Errorf("a fresh re-spawn names a resume in the report: %s", joinReport(rep))
	}
	calls := ag.recorded()
	if len(calls) != 1 {
		t.Fatalf("starts = %d, want one", len(calls))
	}
	for _, a := range calls[0].Request.Args {
		if a == "--resume" || a == "-r" {
			t.Fatalf("a run with no journaled id re-spawned with the resume flag %q", a)
		}
	}
	if !strings.Contains(strings.Join(calls[0].Request.Args, " "), "--verbose") {
		t.Errorf("the fresh re-spawn argv = %v, want claude's headless launch",
			calls[0].Request.Args)
	}
}
