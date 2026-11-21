package chief

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/cold-dark-void/claude-dev-team/control-plane/agent"
	"github.com/cold-dark-void/claude-dev-team/control-plane/queue"
	"github.com/cold-dark-void/claude-dev-team/control-plane/run"
)

// AC6: the Chief is reachable only over the API the web UI uses — the
// handler is the whole surface, and every verb answers from the journal and
// the queue.
func TestAPIIsTheWholeSurface(t *testing.T) {
	eng := newEngine(t)
	c := newTestChief(t, eng, &fakeAgent{}, &fakeTickets{slug: "api-run"},
		&fakeModels{model: "sonnet", source: "map"}, &fakePhone{})
	srv := httptest.NewServer(c.Handler())
	t.Cleanup(srv.Close)

	// Route over the API: the same path the web UI will drive.
	res := post(t, srv, "/v1/route", `{"kind":"defect","title":"API defect",
		"text":"the premise","agent":"ic5","host":"omp"}`)
	var routed RouteResult
	if err := json.Unmarshal(res, &routed); err != nil {
		t.Fatal(err)
	}
	if routed.RunID != "api-run" || routed.Surface.Name != "debug" ||
		routed.Model != "sonnet" {
		t.Fatalf("route = %s, want the defect route with its model", res)
	}
	// The fake agent's start only claims; wait for the state to settle.
	deadline := time.Now().Add(5 * time.Second)
	for !isRunning(t, eng, routed.RunID) {
		if time.Now().After(deadline) {
			t.Fatal("the run never claimed")
		}
		time.Sleep(10 * time.Millisecond)
	}

	// Reports over the API, from the journal and the queue.
	if got := get(t, srv, "/v1/runs"); !strings.Contains(string(got), `"run_id":"api-run"`) {
		t.Errorf("runs = %s, want api-run", got)
	}
	if got := get(t, srv, "/v1/runs/api-run"); !strings.Contains(string(got), `"state":"running"`) {
		t.Errorf("run = %s, want the running state", got)
	}
	if got := get(t, srv, "/v1/queue"); !strings.Contains(string(got), `"slots":[]`) {
		t.Errorf("queue = %s, want the empty ledger", got)
	}
	if got := get(t, srv, "/v1/checks"); !strings.Contains(string(got), `"run_id":"api-run"`) {
		t.Errorf("checks = %s, want api-run", got)
	}
	if got := get(t, srv, "/v1/standup"); !strings.Contains(string(got), `"active":[{`) {
		t.Errorf("standup = %s, want the active run", got)
	}
	if got := get(t, srv, "/v1/halts"); !strings.Contains(string(got), `"halts":[]`) {
		t.Errorf("halts = %s, want the empty set", got)
	}

	// A correction over the API rides the same C6 path the tests prove
	// end-to-end elsewhere; an unknown run refuses with 404 and the typed
	// error, not a prose page.
	status, body := postStatus(t, srv, "/v1/runs/nope/corrections",
		`{"message":"x"}`)
	if status != http.StatusNotFound ||
		!strings.Contains(string(body), "chief: unknown run") {
		t.Errorf("correction = %d %s, want 404 with the typed error", status, body)
	}

	// Unknown run on the report surface: 404.
	status, body = getStatus(t, srv, "/v1/runs/nope")
	if status != http.StatusNotFound {
		t.Errorf("unknown run status = %d (%s), want 404", status, body)
	}

	// Unknown route kind: 400, the typed refusal.
	status, body = postStatus(t, srv, "/v1/route", `{"kind":"spike","title":"T","text":"x"}`)
	if status != http.StatusBadRequest ||
		!strings.Contains(string(body), "chief: unknown route kind") {
		t.Errorf("route = %d %s, want 400 with the typed refusal", status, body)
	}
}

// The queue surface answers from the C5 ledger: a granted runner shows held.
func TestAPIQueueAnswersFromTheLedger(t *testing.T) {
	eng := newEngine(t)
	c := newTestChief(t, eng, &fakeAgent{}, &fakeTickets{}, &fakeModels{}, &fakePhone{})
	srv := httptest.NewServer(c.Handler())
	t.Cleanup(srv.Close)

	m := run.New(eng, "r-q")
	token, err := m.Claim(context.Background(), "node-agent-1", "T", "debug", "sonnet")
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Start(context.Background(), "node-agent-1", token, "sonnet"); err != nil {
		t.Fatal(err)
	}
	granted, err := c.Queue.Grant(context.Background(), "node-agent-1", token,
		queue.Request{RunID: "r-q", Runner: "node-agent-1", Model: "sonnet"})
	if err != nil || !granted {
		t.Fatalf("grant: granted=%v err=%v", granted, err)
	}
	if got := get(t, srv, "/v1/queue"); !strings.Contains(string(got),
		`"state":"held"`) {
		t.Errorf("queue = %s, want the held slot", got)
	}
}

// AC5 (SPEC-044): the takeover scan's report reaches the UI. A selected run
// that records no agent.start intent is skipped, and GET /v1/checks carries
// that skip as the run's takeover reading — chiefd's stdout is never the
// only record. A run the scan took over carries no line: the reading reports
// what the scan did, never a projected state (M7).
func TestAPIChecksCarriesTheTakeoverSkip(t *testing.T) {
	_ = captureTakeoverLog(t)
	eng := newEngine(t)
	seedRunning(t, eng, "r-nohost")
	seedTakeoverRunning(t, eng, "r-taken", takeoverOwner, "omp")

	clock := takeoverClock(30 * time.Second)
	c := newTakeoverChief(t, eng, &takeoverAgent{now: clock}, &fakePhone{})
	c.Now = clock
	rep, err := c.TakeoverScan(context.Background())
	if err != nil {
		t.Fatalf("TakeoverScan: %v", err)
	}
	if got := runIDsOf(rep.Skipped); strings.Join(got, ",") != "r-nohost" {
		t.Fatalf("skipped = %v, want the run with no start intent (%s)", got, joinReport(rep))
	}

	srv := httptest.NewServer(c.Handler())
	t.Cleanup(srv.Close)
	var doc struct {
		Checks []Check `json:"checks"`
	}
	if err := json.Unmarshal(get(t, srv, "/v1/checks"), &doc); err != nil {
		t.Fatal(err)
	}
	byID := map[string]Check{}
	for _, chk := range doc.Checks {
		byID[chk.RunID] = chk
	}
	skip := byID["r-nohost"]
	if len(skip.Takeover) != 1 {
		t.Fatalf("checks = %+v, want r-nohost with one takeover report line", doc.Checks)
	}
	if !strings.Contains(skip.Takeover[0], string(TakeoverSkipped)) ||
		!strings.Contains(skip.Takeover[0], agent.EffectStart) ||
		!strings.Contains(skip.Takeover[0], "r-nohost") {
		t.Errorf("takeover line = %q, want the skip line naming the run and the missing %s intent",
			skip.Takeover[0], agent.EffectStart)
	}
	if got := byID["r-taken"]; len(got.Takeover) != 0 {
		t.Errorf("r-taken takeover reading = %v, want no line for a taken run", got.Takeover)
	}
}

// post posts a JSON body and returns the response body, failing on a
// non-2xx status.
func post(t *testing.T, srv *httptest.Server, path, body string) []byte {
	t.Helper()
	status, got := postStatus(t, srv, path, body)
	if status < 200 || status >= 300 {
		t.Fatalf("%s = %d %s, want 2xx", path, status, got)
	}
	return got
}

func postStatus(t *testing.T, srv *httptest.Server, path, body string) (int, []byte) {
	t.Helper()
	resp, err := http.Post(srv.URL+path, "application/json", bytes.NewBufferString(body))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out bytes.Buffer
	if _, err := out.ReadFrom(resp.Body); err != nil {
		t.Fatal(err)
	}
	return resp.StatusCode, out.Bytes()
}

// get gets a path and returns the response body, failing on a non-2xx
// status.
func get(t *testing.T, srv *httptest.Server, path string) []byte {
	t.Helper()
	status, got := getStatus(t, srv, path)
	if status != http.StatusOK {
		t.Fatalf("%s = %d %s, want 200", path, status, got)
	}
	return got
}

func getStatus(t *testing.T, srv *httptest.Server, path string) (int, []byte) {
	t.Helper()
	resp, err := http.Get(srv.URL + path)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out bytes.Buffer
	if _, err := out.ReadFrom(resp.Body); err != nil {
		t.Fatal(err)
	}
	return resp.StatusCode, out.Bytes()
}
