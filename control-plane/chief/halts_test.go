package chief

import (
	"context"
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
