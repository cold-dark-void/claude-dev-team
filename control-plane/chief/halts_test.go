package chief

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
	"github.com/cold-dark-void/claude-dev-team/control-plane/run"
)

// seedHalt claims, starts, and halts one run, the way a watchdog or an
// operator stop would journal it.
func seedHalt(t *testing.T, eng *journal.Engine, runID, reason, detail string) {
	t.Helper()
	m := run.New(eng, runID)
	token, err := m.Claim(context.Background(), "node-agent-1", "CDT-1", "debug", "")
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Start(context.Background(), "node-agent-1", token, ""); err != nil {
		t.Fatal(err)
	}
	if err := m.Halt(context.Background(), "node-agent-1", token, reason, detail); err != nil {
		t.Fatal(err)
	}
}

// AC5: a named halt is reported with its reason and its remaining retry
// budget, and the page carries both.
func TestHaltPageCarriesReasonAndBudget(t *testing.T) {
	eng := newEngine(t)
	seedHalt(t, eng, "r1", run.ReasonStalled, "no heartbeat for 2s")
	phone := &fakePhone{}
	c := newTestChief(t, eng, &fakeAgent{}, &fakeTickets{}, &fakeModels{}, phone)

	halts, err := c.ScanHalts(context.Background())
	if err != nil {
		t.Fatalf("scan: %v", err)
	}
	if len(halts) != 1 || halts[0].Reason != run.ReasonStalled ||
		halts[0].Budget != 2 || halts[0].Remaining != 2 || !halts[0].Notified {
		t.Fatalf("halts = %+v, want the stalled halt with its budget", halts)
	}
	pages := phone.recorded()
	if len(pages) != 1 {
		t.Fatalf("pages = %d, want one", len(pages))
	}
	for _, want := range []string{"run r1 halted: stalled", "no heartbeat for 2s",
		"retry budget 2, 2 remaining"} {
		if !strings.Contains(pages[0], want) {
			t.Errorf("page %q lacks %q", pages[0], want)
		}
	}
	// The report surface answers from the journal and the record, not the
	// page: Halts shows the same halt as notified.
	reported, err := c.Halts(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(reported) != 1 || !reported[0].Notified {
		t.Errorf("Halts = %+v, want the notified halt", reported)
	}
}

// SPEC-044 CDT-671 AC1/AC4: a run that journaled agent.start and heartbeats only
// lands halted:premise_undelivered (control-plane/agent's
// TestSuperviseSilentSessionHaltsPremiseUndelivered), and this is the page intent
// that follows it. The halt is outside the M1 selection set, so the takeover
// answers nothing and the halt scan's one existing page path (CDT-664) pages it:
// the intent row lands on the record.
func TestPremiseUndeliveredHaltPagesThroughTheHaltScan(t *testing.T) {
	eng := newEngine(t)
	ag := &fakeAgent{}
	seedHalt(t, eng, "r1", run.ReasonPremiseUndelivered,
		"no captured session id within 30s: the host's first-turn frame names the session")
	phone := &fakePhone{}
	c := newTestChief(t, eng, ag, &fakeTickets{}, &fakeModels{}, phone)

	ctx := context.Background()
	rep, err := c.TakeoverScan(ctx)
	if err != nil {
		t.Fatalf("takeover scan: %v", err)
	}
	if got := strings.Join(runIDsOf(rep.Taken), ","); got != "" {
		t.Errorf("takeover took %q, want nothing: the selection set stays closed", got)
	}

	halts, err := c.ScanHalts(ctx)
	if err != nil {
		t.Fatalf("scan: %v", err)
	}
	if len(halts) != 1 || halts[0].Reason != run.ReasonPremiseUndelivered ||
		halts[0].Budget != 1 || !halts[0].Notified {
		t.Fatalf("halts = %+v, want the premise halt paged", halts)
	}
	pages := phone.recorded()
	if len(pages) != 1 || !strings.Contains(pages[0], "run r1 halted: premise_undelivered") {
		t.Fatalf("pages = %q, want the one premise page", pages)
	}
	// No re-spawn of a silent host: the resume and retry verbs stay the way back.
	if n := len(ag.requests()); n != 0 {
		t.Errorf("agent starts = %d, want 0", n)
	}

	path, err := c.notifyPath()
	if err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read the page record: %v", err)
	}
	for _, want := range []string{`"kind":"intent"`, `"run_id":"r1"`,
		`"reason":"premise_undelivered"`} {
		if !strings.Contains(string(raw), want) {
			t.Errorf("page record %s lacks %s", raw, want)
		}
	}
}

// The record's intent line is the dedupe: a re-scan and a restarted chief
// never page a halt twice.
func TestRestartNeverPagesTwice(t *testing.T) {
	eng := newEngine(t)
	seedHalt(t, eng, "r1", run.ReasonStalled, "no heartbeat for 2s")
	phone := &fakePhone{}
	c := newTestChief(t, eng, &fakeAgent{}, &fakeTickets{}, &fakeModels{}, phone)
	ctx := context.Background()

	if _, err := c.ScanHalts(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := c.ScanHalts(ctx); err != nil {
		t.Fatal(err)
	}
	if n := len(phone.recorded()); n != 1 {
		t.Fatalf("pages after two scans = %d, want one", n)
	}
	// A restarted chief over the same record sees the answered intents.
	restarted := newTestChief(t, eng, &fakeAgent{}, &fakeTickets{}, &fakeModels{}, phone)
	if _, err := restarted.ScanHalts(ctx); err != nil {
		t.Fatal(err)
	}
	if n := len(phone.recorded()); n != 1 {
		t.Errorf("pages after restart = %d, want one", n)
	}
}

// A crash between the intent line and the page re-pages once — the
// at-least-once posture of the operator phone channel.
func TestCrashBeforeThePageRepPagesOnce(t *testing.T) {
	eng := newEngine(t)
	seedHalt(t, eng, "r1", run.ReasonLeaseLost, "token moved")
	phone := &fakePhone{}
	c := newTestChief(t, eng, &fakeAgent{}, &fakeTickets{}, &fakeModels{}, phone)

	// The intent line landed; the page never went out.
	path, err := c.notifyPath()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	intent := `{"kind":"intent","ts":"2026-11-18T00:00:00Z","run_id":"r1","halt_seq":1,"reason":"lease_lost"}` + "\n"
	if err := os.WriteFile(path, []byte(intent), 0o644); err != nil {
		t.Fatal(err)
	}

	if _, err := c.ScanHalts(context.Background()); err != nil {
		t.Fatal(err)
	}
	if n := len(phone.recorded()); n != 1 {
		t.Fatalf("pages = %d, want the one re-page", n)
	}
	// The closed pair holds: a further scan pages nothing.
	if _, err := c.ScanHalts(context.Background()); err != nil {
		t.Fatal(err)
	}
	if n := len(phone.recorded()); n != 1 {
		t.Errorf("pages after the closed pair = %d, want one", n)
	}
}

// B1: a page that fails re-pages on the next scan — within one chief and
// across a restart — and `Notified` stays false until a page is actually
// delivered. Once a delivered outcome lands, no scan pages again.
func TestFailedPageRepPagesUntilDelivered(t *testing.T) {
	eng := newEngine(t)
	seedHalt(t, eng, "r1", run.ReasonStalled, "no heartbeat for 2s")
	phone := &fakePhone{failLeft: 1}
	c := newTestChief(t, eng, &fakeAgent{}, &fakeTickets{}, &fakeModels{}, phone)
	ctx := context.Background()

	// First scan: the page fails; the record and the report say so.
	halts, err := c.ScanHalts(ctx)
	if err != nil {
		t.Fatalf("scan: %v", err)
	}
	if len(halts) != 1 || halts[0].Notified {
		t.Fatalf("halts = %+v, want the halt marked not notified", halts)
	}
	reported, err := c.Halts(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(reported) != 1 || reported[0].Notified {
		t.Errorf("Halts = %+v, want notified:false after the failed page", reported)
	}

	// Second scan: the intent re-pages, and the page lands.
	halts, err = c.ScanHalts(ctx)
	if err != nil {
		t.Fatalf("rescan: %v", err)
	}
	if len(halts) != 1 || !halts[0].Notified {
		t.Fatalf("halts after the retry = %+v, want notified:true", halts)
	}
	if n := len(phone.recorded()); n != 2 {
		t.Fatalf("pages = %d, want the failed page plus its retry", n)
	}

	// The delivered outcome answers every later scan.
	if _, err := c.ScanHalts(ctx); err != nil {
		t.Fatal(err)
	}
	if n := len(phone.recorded()); n != 2 {
		t.Errorf("pages after delivery = %d, want no duplicate page", n)
	}
	reported, err = c.Halts(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(reported) != 1 || !reported[0].Notified {
		t.Errorf("Halts after delivery = %+v, want notified:true", reported)
	}
}

// B1: a page that failed before a restart re-pages once under the
// restarted chief — the record's outcome row, not the intent row, is the
// dedupe.
func TestFailedPageRepPagesAcrossARestart(t *testing.T) {
	eng := newEngine(t)
	seedHalt(t, eng, "r1", run.ReasonLeaseLost, "token moved")
	phone := &fakePhone{failLeft: 1}
	c := newTestChief(t, eng, &fakeAgent{}, &fakeTickets{}, &fakeModels{}, phone)
	ctx := context.Background()
	if _, err := c.ScanHalts(ctx); err != nil {
		t.Fatal(err)
	}
	if n := len(phone.recorded()); n != 1 {
		t.Fatalf("pages before the restart = %d, want one failed page", n)
	}

	// The restarted chief re-pages; the retry lands and closes the halt.
	restarted := newTestChief(t, eng, &fakeAgent{}, &fakeTickets{}, &fakeModels{},
		&fakePhone{})
	halts, err := restarted.ScanHalts(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(halts) != 1 || !halts[0].Notified {
		t.Fatalf("halts after the restart = %+v, want notified:true", halts)
	}
	if _, err := restarted.ScanHalts(ctx); err != nil {
		t.Fatal(err)
	}
	if n := len(phone.recorded()); n != 1 {
		t.Errorf("pages after the restarted chief delivered = %d, want one", n)
	}
}

// B1 at the API: GET /v1/halts reads notified:false until a page is
// actually delivered — the read never inherits an intent line's optimism.
func TestAPIHaltsReportHonestNotified(t *testing.T) {
	eng := newEngine(t)
	seedHalt(t, eng, "r1", run.ReasonStalled, "no heartbeat for 2s")
	phone := &fakePhone{failLeft: 1}
	c := newTestChief(t, eng, &fakeAgent{}, &fakeTickets{}, &fakeModels{}, phone)
	srv := httptest.NewServer(c.Handler())
	t.Cleanup(srv.Close)
	ctx := context.Background()

	if _, err := c.ScanHalts(ctx); err != nil {
		t.Fatal(err)
	}
	if got := get(t, srv, "/v1/halts"); !strings.Contains(string(got),
		`"notified":false`) {
		t.Errorf("halts = %s, want notified:false after the failed page", got)
	}
	if _, err := c.ScanHalts(ctx); err != nil {
		t.Fatal(err)
	}
	if got := get(t, srv, "/v1/halts"); !strings.Contains(string(got),
		`"notified":true`) {
		t.Errorf("halts = %s, want notified:true once delivered", got)
	}
}

// waitForState reports whether a run reaches one replayed state inside the
// deadline.
func waitForState(t *testing.T, eng *journal.Engine, runID, want string,
	deadline time.Duration) bool {
	t.Helper()
	end := time.Now().Add(deadline)
	for {
		st, err := eng.RunState(context.Background(), runID)
		if err != nil {
			t.Fatal(err)
		}
		if st.Name() == want {
			return true
		}
		if time.Now().After(end) {
			return false
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// AC2 + AC9: the watch's first takeover pass lands at startup — a stalled
// run the scan can take over is running well inside one interval, with no
// human input. The takeover is the response, so the answered stall pages
// nothing, and it stays un-paged after the watch stops.
func TestWatchTakeoverPassRunsAtStartup(t *testing.T) {
	_ = captureTakeoverLog(t)
	eng := newEngine(t)
	seedTakeoverStalled(t, eng, "r-stalled", takeoverOwner, "claude")
	phone := &fakePhone{}
	clock := takeoverClock(30 * time.Second)
	c := newTakeoverChief(t, eng, &takeoverAgent{now: clock}, phone)
	c.Now = clock

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { c.Watch(ctx, time.Second); close(done) }()

	// The interval is 1 s: a takeover inside 400 ms is the startup pass,
	// not a tick.
	if !waitForState(t, eng, "r-stalled", "running", 400*time.Millisecond) {
		cancel()
		<-done
		t.Fatal("the watch's first takeover pass did not take the stalled run over")
	}
	cancel()
	<-done

	if _, err := c.ScanHalts(context.Background()); err != nil {
		t.Fatal(err)
	}
	if pages := phone.recorded(); len(pages) != 0 {
		t.Errorf("pages = %v, want none — the takeover is the response (AC9)", pages)
	}
}

// AC2: the scan repeats on the watch cadence. A run that stays inside the
// selection set is offered the takeover on every tick, and the passes stop
// with the context.
func TestWatchRepeatsTheTakeoverScan(t *testing.T) {
	_ = captureTakeoverLog(t)
	eng := newEngine(t)
	seedTakeoverRunning(t, eng, "r-stale", takeoverOwner, "grok")
	phone := &fakePhone{}
	clock := takeoverClock(30 * time.Second)
	ag := &takeoverAgent{now: clock,
		errs: map[string]error{"r-stale": journal.ErrLeaseHeld}}
	c := newTakeoverChief(t, eng, ag, phone)
	c.Now = clock

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { c.Watch(ctx, 20*time.Millisecond); close(done) }()

	end := time.Now().Add(5 * time.Second)
	for len(ag.recorded()) < 3 {
		if time.Now().After(end) {
			cancel()
			<-done
			t.Fatalf("takeover passes = %d in 5s, want one per tick", len(ag.recorded()))
		}
		time.Sleep(10 * time.Millisecond)
	}
	cancel()
	<-done

	stopped := len(ag.recorded())
	time.Sleep(150 * time.Millisecond)
	if got := len(ag.recorded()); got != stopped {
		t.Errorf("starts after the watch stopped = %d, want no pass past the context (was %d)",
			got, stopped)
	}
	if pages := phone.recorded(); len(pages) != 0 {
		t.Errorf("pages = %v, want none — a refused takeover of a running run pages nothing",
			pages)
	}
}

// AC9: the takeover is the response to a stalled halt. The pass takes the
// run over and the halt scan pages nothing; the halt row stays readable,
// answered by the journal rather than by the phone.
func TestTakeoverAnsweredStallIsNotPaged(t *testing.T) {
	_ = captureTakeoverLog(t)
	eng := newEngine(t)
	seedTakeoverStalled(t, eng, "r-stalled", takeoverOwner, "claude")
	phone := &fakePhone{}
	clock := takeoverClock(30 * time.Second)
	c := newTakeoverChief(t, eng, &takeoverAgent{now: clock}, phone)
	c.Now = clock
	ctx := context.Background()

	rep, err := c.TakeoverScan(ctx)
	if err != nil {
		t.Fatalf("takeover scan: %v", err)
	}
	if got := runIDsOf(rep.Taken); strings.Join(got, ",") != "r-stalled" {
		t.Fatalf("taken = %v, want the stalled run (%s)", got, joinReport(rep))
	}

	halts, err := c.ScanHalts(ctx)
	if err != nil {
		t.Fatalf("scan halts: %v", err)
	}
	if len(halts) != 1 || halts[0].Reason != run.ReasonStalled || halts[0].Notified {
		t.Errorf("halts = %+v, want the stalled row reported as not paged", halts)
	}
	if pages := phone.recorded(); len(pages) != 0 {
		t.Fatalf("pages = %v, want none — the takeover answered the stall", pages)
	}

	// The suppression is stable: every later scan reads the journal and
	// pages nothing.
	for i := 0; i < 2; i++ {
		if _, err := c.ScanHalts(ctx); err != nil {
			t.Fatalf("rescan %d: %v", i, err)
		}
	}
	if pages := phone.recorded(); len(pages) != 0 {
		t.Errorf("pages after the rescans = %v, want none", pages)
	}
	reported, err := c.Halts(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(reported) != 1 || reported[0].Reason != run.ReasonStalled || reported[0].Notified {
		t.Errorf("Halts = %+v, want the stalled row, paged by nothing", reported)
	}
}

// AC9 + M9: the suppression never silences a halt the scan does not answer.
// A stalled run whose takeover is refused (the spent budget) and one the
// scan skips (no host, M5) keep their page, and the page record keeps it at
// one.
func TestTakeoverFailurePagesTheStalledHalt(t *testing.T) {
	_ = captureTakeoverLog(t)
	eng := newEngine(t)
	seedTakeoverStalled(t, eng, "r-budget", takeoverOwner, "claude")
	seedStall(run.ReasonStalled)(t, eng, "r-nohost")
	phone := &fakePhone{}
	clock := takeoverClock(30 * time.Second)
	ag := &takeoverAgent{now: clock,
		errs: map[string]error{"r-budget": journal.ErrBudgetExhausted}}
	c := newTakeoverChief(t, eng, ag, phone)
	c.Now = clock
	ctx := context.Background()

	rep, err := c.TakeoverScan(ctx)
	if err != nil {
		t.Fatalf("takeover scan: %v", err)
	}
	if got := runIDsOf(rep.Refused); strings.Join(got, ",") != "r-budget" {
		t.Errorf("refused = %v, want the spent-budget run (%s)", got, joinReport(rep))
	}
	if got := runIDsOf(rep.Skipped); strings.Join(got, ",") != "r-nohost" {
		t.Errorf("skipped = %v, want the hostless run (%s)", got, joinReport(rep))
	}
	if len(rep.Taken) != 0 {
		t.Errorf("taken = %v, want nothing taken (%s)", runIDsOf(rep.Taken), joinReport(rep))
	}

	halts, err := c.ScanHalts(ctx)
	if err != nil {
		t.Fatalf("scan halts: %v", err)
	}
	if len(halts) != 2 {
		t.Fatalf("halts = %+v, want both stalled rows", halts)
	}
	pages := phone.recorded()
	if len(pages) != 2 {
		t.Fatalf("pages = %v, want one per unanswered stall", pages)
	}
	for i, want := range []string{"r-budget", "r-nohost"} {
		if !strings.Contains(pages[i], want) ||
			!strings.Contains(pages[i], "halted: "+run.ReasonStalled) {
			t.Errorf("page %d = %q, want %q named with the stalled reason", i, pages[i], want)
		}
	}

	// The closed pair keeps the record's semantics: a re-scan pages
	// neither run again.
	if _, err := c.ScanHalts(ctx); err != nil {
		t.Fatal(err)
	}
	if got := phone.recorded(); len(got) != 2 {
		t.Errorf("pages after the re-scan = %v, want no duplicate page", got)
	}
}

// AC8: a halt the scan never handles keeps paging. The operator halt stays
// halted — no takeover, no spawn — and it pages beside a stall the takeover
// answered, which pages nothing.
func TestOperatorHaltPagesAfterTheTakeoverPass(t *testing.T) {
	_ = captureTakeoverLog(t)
	eng := newEngine(t)
	seedHalt(t, eng, "r-operator", run.ReasonOperatorHalt, "stopped by the operator")
	seedTakeoverStalled(t, eng, "r-stalled", takeoverOwner, "claude")
	phone := &fakePhone{}
	clock := takeoverClock(30 * time.Second)
	ag := &takeoverAgent{now: clock}
	c := newTakeoverChief(t, eng, ag, phone)
	c.Now = clock
	ctx := context.Background()

	if _, err := c.TakeoverScan(ctx); err != nil {
		t.Fatalf("takeover scan: %v", err)
	}
	halts, err := c.ScanHalts(ctx)
	if err != nil {
		t.Fatalf("scan halts: %v", err)
	}
	if len(halts) != 2 {
		t.Fatalf("halts = %+v, want the operator halt and the stall", halts)
	}
	pages := phone.recorded()
	if len(pages) != 1 {
		t.Fatalf("pages = %v, want the operator halt only", pages)
	}
	if !strings.Contains(pages[0], "r-operator") ||
		!strings.Contains(pages[0], run.ReasonOperatorHalt) {
		t.Errorf("page = %q, want the operator halt named", pages[0])
	}
	if strings.Contains(pages[0], "r-stalled") {
		t.Errorf("page = %q, want no page for the answered stall", pages[0])
	}
	for _, call := range ag.recorded() {
		if call.RunID == "r-operator" {
			t.Errorf("the takeover spawned an operator halt: %+v", call)
		}
	}
	if _, err := c.ScanHalts(ctx); err != nil {
		t.Fatal(err)
	}
	if got := phone.recorded(); len(got) != 1 {
		t.Errorf("pages after the re-scan = %v, want one", got)
	}
}

// Watch pages the halts as the journal names them and stops when the
// context ends.
func TestWatchPagesThenStops(t *testing.T) {
	eng := newEngine(t)
	seedHalt(t, eng, "r1", run.ReasonOperatorHalt, "stopped by the operator")
	phone := &fakePhone{}
	c := newTestChief(t, eng, &fakeAgent{}, &fakeTickets{}, &fakeModels{}, phone)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { c.Watch(ctx, 20*time.Millisecond); close(done) }()
	defer func() { cancel(); <-done }()
	deadline := time.Now().Add(5 * time.Second)
	for len(phone.recorded()) == 0 {
		if time.Now().After(deadline) {
			t.Fatal("the watch never paged the halt")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// CDT-664: the one-shot page window. An unconfirmed takeover start rides the
// chief's base context and can land after the scan's answered read. The scan
// re-reads the answer before it pages: the answered stall pages nothing, and
// the intent row closes with a suppressed outcome so the record shows the
// page never went out.
func TestStalledHaltAnsweredAfterTheIntentIsSuppressed(t *testing.T) {
	eng := newEngine(t)
	seedHalt(t, eng, "r1", run.ReasonStalled, "no heartbeat for 2s")
	phone := &fakePhone{}
	c := newTestChief(t, eng, &fakeAgent{}, &fakeTickets{}, &fakeModels{}, phone)
	ctx := context.Background()

	// The window: the scan's first read says the stall stands, and the
	// takeover's re-spawn lands between that read and the page.
	answered := c.takeoverAnswered
	reads := 0
	c.answeredRead = func(_ context.Context, h HaltReport) (bool, error) {
		reads++
		if reads == 1 {
			resumeStalledRun(t, eng, h.RunID)
			return false, nil
		}
		return answered(ctx, h)
	}

	halts, err := c.ScanHalts(ctx)
	if err != nil {
		t.Fatalf("scan: %v", err)
	}
	if len(halts) != 1 || halts[0].Notified {
		t.Fatalf("halts = %+v, want the halt reported un-notified", halts)
	}
	if n := len(phone.recorded()); n != 0 {
		t.Fatalf("pages = %d, want the answered stall suppressed", n)
	}
	rows := notifyRows(t, c)
	if len(rows) != 2 {
		t.Fatalf("record rows = %d (%+v), want one intent and its outcome", len(rows), rows)
	}
	if rows[0].Kind != "intent" || rows[0].RunID != "r1" || rows[0].HaltSeq != halts[0].Seq {
		t.Errorf("intent row = %+v, want the r1 halt intent at seq %d", rows[0], halts[0].Seq)
	}
	if rows[1].Kind != "outcome" || rows[1].Delivered ||
		rows[1].Error != suppressedByTakeover {
		t.Errorf("outcome row = %+v, want delivered:false with %q",
			rows[1], suppressedByTakeover)
	}

	// The next scan reads the journal's answer and pages nothing.
	halts, err = c.ScanHalts(ctx)
	if err != nil {
		t.Fatalf("rescan: %v", err)
	}
	if len(halts) != 1 || halts[0].Notified {
		t.Errorf("halts after the rescan = %+v, want the halt reported un-notified", halts)
	}
	if n := len(phone.recorded()); n != 0 {
		t.Errorf("pages after the rescan = %d, want none", n)
	}
	if got := len(notifyRows(t, c)); got != 2 {
		t.Errorf("record rows after the rescan = %d, want the suppressed pair", got)
	}
}

// resumeStalledRun is the takeover's re-spawn on the journal: the
// halted:stalled run runs again.
func resumeStalledRun(t *testing.T, eng *journal.Engine, runID string) {
	t.Helper()
	m := run.New(eng, runID)
	if err := m.Resume(context.Background(), "node-agent-1", 1); err != nil {
		t.Fatalf("resume %s: %v", runID, err)
	}
}

// notifyRows reads the phone-channel record.
func notifyRows(t *testing.T, c *Chief) []notifyRecord {
	t.Helper()
	path, err := c.notifyPath()
	if err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	var out []notifyRecord
	for _, line := range strings.Split(string(raw), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		var rec notifyRecord
		if err := json.Unmarshal([]byte(line), &rec); err != nil {
			t.Fatalf("record line %q: %v", line, err)
		}
		out = append(out, rec)
	}
	return out
}
