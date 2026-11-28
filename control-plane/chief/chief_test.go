package chief

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/cold-dark-void/claude-dev-team/control-plane/agent"
	"github.com/cold-dark-void/claude-dev-team/control-plane/hostadapter"
	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
	"github.com/cold-dark-void/claude-dev-team/control-plane/queue"
	"github.com/cold-dark-void/claude-dev-team/control-plane/run"
)

// newEngine opens one journal file in a private directory and points the
// run state at it — the C6 test seam.
func newEngine(t *testing.T) *journal.Engine {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("DEVTEAM_MROOT", dir)
	t.Setenv("DEVTEAM_RUN_DB", filepath.Join(dir, "run.db"))
	t.Setenv("DEVTEAM_STALL_LIMIT", "1")
	t.Setenv("DEVTEAM_RUNNER", "native")
	eng, err := journal.OpenPath(context.Background(), os.Getenv("DEVTEAM_RUN_DB"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = eng.Close() })
	return eng
}

// newEngineWideStall is newEngine with a stall limit a loaded runner cannot
// race. The steer-seam tests (shAgent) supervise a real child, and the 1 s
// limit newEngine pins for the lease-staleness fixtures can go stale between
// the supervisor's heartbeat ticks (limit/2, heartbeatFloor-clamped) and the
// steer, which answers the stall instead of the correction. SPEC-044
// ### CDT-656 AC A is the precedent: pin the wide limit in the racing test,
// never in newEngine — the takeover fixtures need a 1 s stale lease.
func newEngineWideStall(t *testing.T) *journal.Engine {
	t.Helper()
	eng := newEngine(t)
	t.Setenv("DEVTEAM_STALL_LIMIT", "270")
	return eng
}

// fakeTickets records what the routes wrote and hands out deterministic
// slugs.
type fakeTickets struct {
	mu    sync.Mutex
	calls []TicketRequest
	slug  string
	n     int
}

func (f *fakeTickets) Create(_ context.Context, req TicketRequest) (TicketRecord, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, req)
	f.n++
	slug := f.slug
	if f.n > 1 {
		slug = fmt.Sprintf("%s-%d", f.slug, f.n)
	}
	return TicketRecord{Slug: slug, Path: "/store/" + slug + ".md",
		Kind: req.Kind, Title: req.Title}, nil
}

func (f *fakeTickets) recorded() []TicketRequest {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]TicketRequest(nil), f.calls...)
}

// fakeModels is the Model map seam: one canned answer.
type fakeModels struct {
	model  string
	source string
	agent  string
	calls  int
}

func (f *fakeModels) Resolve(_ context.Context, agentName string) (string, string, error) {
	f.agent = agentName
	f.calls++
	if f.model == "" {
		return tierDefaultModel(), "tier-default", nil
	}
	return f.model, f.source, nil
}

// fakePhone records every page attempt — a failure records too, so a test
// can hold the retry count — and can fail the first N page calls.
type fakePhone struct {
	mu       sync.Mutex
	pages    []string
	failLeft int
}

func (f *fakePhone) Page(_ context.Context, _, message string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.pages = append(f.pages, message)
	if f.failLeft > 0 {
		f.failLeft--
		return fmt.Errorf("intercom down")
	}
	return nil
}

func (f *fakePhone) recorded() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.pages...)
}

// fakeAgent is the NodeAgent seam: the start claims and starts the run in
// the journal, the steer records its frame, and nothing execs a host CLI.
type fakeAgent struct {
	mu     sync.Mutex
	frames []string
	// reqs records every start request the chief handed the seam, so a test
	// reads the spawn contract — the run-scoped caps included (SPEC-046 T6).
	reqs []agent.StartRequest
	// startDelay delays the supervised claim, so a test can outlast the
	// route's StartWait.
	startDelay time.Duration
}

func (f *fakeAgent) Supervise(ctx context.Context, eng *journal.Engine,
	req agent.StartRequest, _ io.Writer) error {
	if f.startDelay > 0 {
		time.Sleep(f.startDelay)
	}
	f.mu.Lock()
	f.reqs = append(f.reqs, req)
	f.mu.Unlock()
	m := run.New(eng, req.RunID)
	token, err := m.Claim(ctx, "fake-agent", req.Ticket, req.Workflow, req.Model)
	if err != nil {
		return err
	}
	// The real node agent journals the caps on the run_started row
	// (SPEC-046 M7); the seam mirrors it so the route's journal proof is real.
	return m.StartWithCaps(ctx, "fake-agent", token, req.Model,
		req.WallclockCapS, req.IterationCapS)
}

func (f *fakeAgent) requests() []agent.StartRequest {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]agent.StartRequest(nil), f.reqs...)
}

func (f *fakeAgent) Stop(_ context.Context, _ *journal.Engine, _ string, _ time.Duration) error {
	return nil
}

func (f *fakeAgent) Steer(_ context.Context, _ *journal.Engine, _, message string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.frames = append(f.frames, message)
	return nil
}

func (f *fakeAgent) Status(_ context.Context, _ *journal.Engine,
	runID string) (agent.StatusReport, error) {
	return agent.StatusReport{RunID: runID, State: "running"}, nil
}

func (f *fakeAgent) steered() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.frames...)
}

// newTestChief builds a chief over the fakes.
func newTestChief(t *testing.T, eng *journal.Engine, seam *fakeAgent,
	tickets *fakeTickets, models *fakeModels, phone *fakePhone) *Chief {
	t.Helper()
	c := NewWithAdapter(eng, &hostadapter.Adapter{Agent: seam},
		WithTickets(tickets), WithModelMap(models), WithPhone(phone))
	c.StartWait = 5 * time.Second
	return c
}

// runRecordOf reads the chief's own record of one run.
func runRecordOf(c *Chief, runID string) (*runRecord, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	rec, ok := c.runs[runID]
	return rec, ok
}

// AC1: a defect routes to /debug — the Surface is named, the ticket record
// is written through the ticket seam, the model resolves through the Model
// map, and the run's workflow carries the Surface — never a second copy.
func TestRouteDefectNamesTheSurfaceAndStartsTheRun(t *testing.T) {
	eng := newEngine(t)
	tickets := &fakeTickets{slug: "staging-deploy-hangs"}
	models := &fakeModels{model: "opus", source: "map"}
	c := newTestChief(t, eng, &fakeAgent{}, tickets, models, &fakePhone{})

	res, err := c.Route(context.Background(), RouteRequest{
		Kind: "defect", Title: "Staging deploy hangs", Text: "the deploy hangs",
		Agent: "ic5", Host: hostadapter.HostOmp,
	})
	if err != nil {
		t.Fatalf("route: %v", err)
	}
	if res.Surface.Name != "debug" || res.Surface.Path != "commands/debug.md" {
		t.Errorf("surface = %+v, want /debug (commands/debug.md)", res.Surface)
	}
	if res.RunID != "staging-deploy-hangs" {
		t.Errorf("run id = %q, want the ticket slug", res.RunID)
	}
	if res.Model != "opus" || res.ModelSource != "map" {
		t.Errorf("model = %q/%q, want the map resolution", res.Model, res.ModelSource)
	}
	calls := tickets.recorded()
	if len(calls) != 1 || calls[0].Kind != "ticket" ||
		calls[0].Title != "Staging deploy hangs" || calls[0].Problem != "the deploy hangs" {
		t.Errorf("ticket calls = %+v, want one ticket record with the premise", calls)
	}
	if models.agent != "ic5" {
		t.Errorf("the map seam saw agent %q, want ic5", models.agent)
	}
	// The run's own trail names the Surface and the model — the route's
	// journal row is the machine's run_claimed, never a new kind.
	st, err := eng.RunState(context.Background(), res.RunID)
	if err != nil {
		t.Fatal(err)
	}
	if st.Workflow != "debug" || st.Ticket != "staging-deploy-hangs" || st.Model != "opus" {
		t.Errorf("run state = %s/%s/%s, want debug/staging-deploy-hangs/opus",
			st.Workflow, st.Ticket, st.Model)
	}
}

// AC3: an unnamed agent and an empty resolution are the Tier default —
// never a flag, never a chief copy of the map.
func TestRouteModelResolvesEmptyToTheTierDefault(t *testing.T) {
	eng := newEngine(t)
	models := &fakeModels{}
	c := newTestChief(t, eng, &fakeAgent{}, &fakeTickets{slug: "r-model"}, models,
		&fakePhone{})

	res, err := c.Route(context.Background(), RouteRequest{
		Kind: "idea", Title: "Idea", Text: "an idea", Host: hostadapter.HostClaudeCode})
	if err != nil {
		t.Fatalf("route: %v", err)
	}
	if res.Model != tierDefaultModel() || res.ModelSource != "tier-default" {
		t.Errorf("model = %q/%q, want the Tier default", res.Model, res.ModelSource)
	}
}

// AC1: an idea routes to /brainstorm and then a ticket; an epic routes to
// child tickets through the same ticket verbs.
func TestRouteIdeaAndEpicUseTheTicketVerbs(t *testing.T) {
	eng := newEngine(t)
	tickets := &fakeTickets{slug: "dark-launch"}
	c := newTestChief(t, eng, &fakeAgent{}, tickets, &fakeModels{}, &fakePhone{})

	if _, err := c.Route(context.Background(), RouteRequest{
		Kind: "idea", Title: "Dark launch", Text: "launch dark", Host: hostadapter.HostGrok}); err != nil {
		t.Fatalf("idea route: %v", err)
	}
	res, err := c.Route(context.Background(), RouteRequest{
		Kind: "epic", Title: "Dark launch epic", Text: "launch dark",
		Children: []ChildRequest{{Title: "Child one"}, {Title: "Child two"}}})
	if err != nil {
		t.Fatalf("epic route: %v", err)
	}
	calls := tickets.recorded()
	want := []string{"ticket", "epic", "child", "child"}
	if len(calls) != len(want) {
		t.Fatalf("ticket calls = %d, want %d", len(calls), len(want))
	}
	for i, kind := range want {
		if calls[i].Kind != kind {
			t.Errorf("call %d kind = %q, want %q", i, calls[i].Kind, kind)
		}
	}
	if len(res.Children) != 2 || res.Children[0].Slug != "dark-launch-3" ||
		res.Children[1].Slug != "dark-launch-4" {
		t.Errorf("children = %+v, want two child records", res.Children)
	}
	if res.RunID != "" {
		t.Errorf("an epic route starts no run; got %q", res.RunID)
	}
	// The epic carries its children as frontmatter of the child records —
	// the plugin's own epic shape, not a chief copy.
	if calls[2].EpicParent != "dark-launch-2" || calls[2].ChildID != "C1" {
		t.Errorf("child call = %+v, want the epic parent and C1", calls[2])
	}
}

// The closed route set refuses what it does not name.
func TestRouteRefusalsAreTyped(t *testing.T) {
	eng := newEngine(t)
	tickets := &fakeTickets{slug: "r"}
	c := newTestChief(t, eng, &fakeAgent{}, tickets, &fakeModels{}, &fakePhone{})
	ctx := context.Background()

	if _, err := c.Route(ctx, RouteRequest{Kind: "spike", Title: "T", Text: "x"}); !errors.Is(err, ErrUnknownRoute) {
		t.Errorf("unknown kind err = %v, want ErrUnknownRoute", err)
	}
	if _, err := c.Route(ctx, RouteRequest{Kind: "defect", Title: "", Text: "x"}); !errors.Is(err, ErrInvalid) {
		t.Errorf("titleless route err = %v, want ErrInvalid", err)
	}
	if _, err := c.Route(ctx, RouteRequest{Kind: "epic", Title: "T", Text: "x"}); !errors.Is(err, ErrInvalid) {
		t.Errorf("childless epic err = %v, want ErrInvalid", err)
	}
	if _, err := c.Route(ctx, RouteRequest{Kind: "defect", Title: "T", Text: "x",
		Host: "codex"}); !errors.Is(err, hostadapter.ErrUnknownHost) {
		t.Errorf("unknown host err = %v, want ErrUnknownHost", err)
	}
	if n := len(tickets.recorded()); n != 0 {
		t.Errorf("%d ticket calls on refused routes; want none", n)
	}
}

// M1: a route whose StartWait expires answers honestly — the typed error
// names whether the run started, and the run the goroutine claimed anyway
// under the base context makes a retried route refuse with ErrRunExists.
func TestRouteTimeoutNamesTheRunState(t *testing.T) {
	eng := newEngine(t)
	seam := &fakeAgent{startDelay: 50 * time.Millisecond}
	c := newTestChief(t, eng, seam, &fakeTickets{slug: "late-run"}, &fakeModels{},
		&fakePhone{})
	c.StartWait = 5 * time.Millisecond
	ctx := context.Background()

	_, err := c.Route(ctx, RouteRequest{
		Kind: "defect", Title: "T", Text: "x", Host: hostadapter.HostOmp})
	if !errors.Is(err, ErrStartUnconfirmed) {
		t.Fatalf("err = %v, want ErrStartUnconfirmed", err)
	}
	if !strings.Contains(err.Error(), "may still start") {
		t.Errorf("err = %v, want the answer to say the run may still start", err)
	}
	// The start goroutine rides the base context: the run claims anyway.
	deadline := time.Now().Add(5 * time.Second)
	for !isRunning(t, eng, "late-run") {
		if time.Now().After(deadline) {
			t.Fatal("the run never claimed after the unconfirmed answer")
		}
		time.Sleep(5 * time.Millisecond)
	}
	// The honest answer makes the retried route refuse, not double-start.
	retried := newTestChief(t, eng, &fakeAgent{}, &fakeTickets{slug: "late-run"},
		&fakeModels{}, &fakePhone{})
	if _, err := retried.Route(ctx, RouteRequest{
		Kind: "defect", Title: "T", Text: "x", Host: hostadapter.HostOmp}); !errors.Is(err, ErrRunExists) {
		t.Fatalf("retry err = %v, want ErrRunExists", err)
	}
}

// M1: an abandoned route answers the same typed honesty — the cancelled
// route context does not stop the start goroutine.
func TestAbandonedRouteNamesTheRunState(t *testing.T) {
	eng := newEngine(t)
	seam := &fakeAgent{startDelay: 50 * time.Millisecond}
	c := newTestChief(t, eng, seam, &fakeTickets{slug: "late-cancel"}, &fakeModels{},
		&fakePhone{})
	c.StartWait = 5 * time.Second
	ctx, cancel := context.WithCancel(context.Background())
	time.AfterFunc(20*time.Millisecond, cancel)

	_, err := c.Route(ctx, RouteRequest{
		Kind: "defect", Title: "T", Text: "x", Host: hostadapter.HostOmp})
	if !errors.Is(err, ErrStartUnconfirmed) {
		t.Fatalf("err = %v, want ErrStartUnconfirmed", err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for !isRunning(t, eng, "late-cancel") {
		if time.Now().After(deadline) {
			t.Fatal("the run never claimed after the abandoned route")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// A second route onto a run id the journal already carries refuses.
func TestRouteRefusesWhenTheRunAlreadyExists(t *testing.T) {
	eng := newEngine(t)
	m := run.New(eng, "staging-deploy-hangs")
	token, err := m.Claim(context.Background(), "someone", "T", "debug", "")
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Start(context.Background(), "someone", token, ""); err != nil {
		t.Fatal(err)
	}
	c := newTestChief(t, eng, &fakeAgent{}, &fakeTickets{slug: "staging-deploy-hangs"},
		&fakeModels{}, &fakePhone{})
	_, err = c.Route(context.Background(), RouteRequest{
		Kind: "defect", Title: "T", Text: "x", Host: hostadapter.HostOmp})
	if !errors.Is(err, ErrRunExists) {
		t.Fatalf("err = %v, want ErrRunExists", err)
	}
}

// M3: the default plugin root refuses a non-dev-team checkout — the
// deployment assumption is pinned, typed, and visible.
func TestDefaultPluginRootRefusesANonDevTeamCheckout(t *testing.T) {
	foreign := t.TempDir()
	t.Setenv("DEVTEAM_MROOT", foreign)
	if _, err := defaultPluginRoot(); !errors.Is(err, ErrNoPluginRoot) {
		t.Fatalf("err = %v, want ErrNoPluginRoot", err)
	}

	// A foreign manifest is equally refused.
	if err := os.MkdirAll(filepath.Join(foreign, ".claude-plugin"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(foreign, ".claude-plugin", "plugin.json"),
		[]byte(`{"name":"other-plugin"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := defaultPluginRoot(); !errors.Is(err, ErrNoPluginRoot) {
		t.Fatalf("err = %v, want ErrNoPluginRoot for a foreign manifest", err)
	}

	// The dev-team manifest itself passes.
	if err := os.WriteFile(filepath.Join(foreign, ".claude-plugin", "plugin.json"),
		[]byte(`{"name":"dev-team"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	root, err := defaultPluginRoot()
	if err != nil {
		t.Fatalf("defaultPluginRoot: %v", err)
	}
	if root != foreign {
		t.Errorf("root = %q, want %q", root, foreign)
	}
}

// M3 at the phone channel: on a non-dev-team record root the pages fail
// and retry — the typed refusal records a failed outcome and the halts
// report reads notified:false, never a silent loss.
func TestNonDevTeamCheckoutPagesFailAndRetry(t *testing.T) {
	// newEngine points DEVTEAM_MROOT at a bare temp dir: no dev-team
	// manifest, so the default plugin root refuses.
	eng := newEngine(t)
	seedHalt(t, eng, "r1", run.ReasonStalled, "no heartbeat for 2s")
	c := NewWithAdapter(eng, &hostadapter.Adapter{Agent: &fakeAgent{}})
	ctx := context.Background()

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
		t.Errorf("Halts = %+v, want notified:false on a non-dev-team root", reported)
	}

	// The next scan re-pages: the failure retries, it never settles.
	if _, err := c.ScanHalts(ctx); err != nil {
		t.Fatal(err)
	}
	path, err := c.notifyPath()
	if err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if n := strings.Count(string(raw), `"kind":"intent"`); n != 2 {
		t.Errorf("record holds %d page intents after two scans, want one per scan", n)
	}
}

// A correction derives the host from the run's recorded start argv when the
// chief holds no record of the start — a chief restarted between the two.
func TestCorrectDerivesHostFromTheStartRecord(t *testing.T) {
	eng := newEngine(t)
	m := run.New(eng, "run-x")
	token, err := m.Claim(context.Background(), "node-agent-1", "T", "debug", "")
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Start(context.Background(), "node-agent-1", token, ""); err != nil {
		t.Fatal(err)
	}
	if _, _, err := m.Intent(context.Background(), "node-agent-1", token,
		"agent:start:run-x#1", agent.EffectStart,
		map[string]any{"command": "omp", "args": []string{}}); err != nil {
		t.Fatal(err)
	}
	seam := &fakeAgent{}
	c := newTestChief(t, eng, seam, &fakeTickets{slug: "run-x"}, &fakeModels{}, &fakePhone{})
	if err := c.Correct(context.Background(), CorrectRequest{
		RunID: "run-x", Message: "steer text"}); err != nil {
		t.Fatalf("correct: %v", err)
	}
	if len(seam.steered()) != 1 {
		t.Fatalf("steered = %d frames, want one", len(seam.steered()))
	}
	var frame map[string]any
	if err := json.Unmarshal([]byte(seam.steered()[0]), &frame); err != nil {
		t.Fatalf("frame is not JSON: %v", err)
	}
	if frame["type"] != "steer" {
		t.Errorf("frame type = %v, want the omp steer frame", frame["type"])
	}
}

// A correction whose run the journal holds nothing for refuses.
func TestCorrectRefusesAnUnknownRun(t *testing.T) {
	eng := newEngine(t)
	c := newTestChief(t, eng, &fakeAgent{}, &fakeTickets{}, &fakeModels{}, &fakePhone{})
	err := c.Correct(context.Background(), CorrectRequest{
		RunID: "nope", Message: "x"})
	if !errors.Is(err, ErrUnknownRun) {
		t.Fatalf("err = %v, want ErrUnknownRun", err)
	}
}

// AC2: every answer folds journal and queue state — the reports never
// generate prose of their own.
func TestReportsFoldJournalAndQueueState(t *testing.T) {
	eng := newEngine(t)
	c := newTestChief(t, eng, &fakeAgent{}, &fakeTickets{}, &fakeModels{}, &fakePhone{})
	ctx := context.Background()

	// r1 runs and holds a slot; r2 halted:stalled with its budget.
	m1 := run.New(eng, "r1")
	tok1, err := m1.Claim(context.Background(), "node-agent-1", "CDT-1", "debug", "sonnet")
	if err != nil {
		t.Fatal(err)
	}
	if err := m1.Start(context.Background(), "node-agent-1", tok1, "sonnet"); err != nil {
		t.Fatal(err)
	}
	granted, err := c.Queue.Grant(ctx, "node-agent-1", tok1,
		queue.Request{RunID: "r1", Runner: "node-agent-1", Model: "sonnet"})
	if err != nil || !granted {
		t.Fatalf("grant: granted=%v err=%v", granted, err)
	}

	m2 := run.New(eng, "r2")
	tok2, err := m2.Claim(context.Background(), "node-agent-2", "CDT-2", "brainstorm", "opus")
	if err != nil {
		t.Fatal(err)
	}
	if err := m2.Start(context.Background(), "node-agent-2", tok2, "opus"); err != nil {
		t.Fatal(err)
	}
	if err := m2.Halt(ctx, "node-agent-2", tok2, run.ReasonStalled,
		"no heartbeat for 2s"); err != nil {
		t.Fatal(err)
	}

	runs, err := c.Runs(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(runs) != 2 {
		t.Fatalf("runs = %d, want 2", len(runs))
	}
	byID := map[string]RunStatus{}
	for _, rs := range runs {
		byID[rs.RunID] = rs
	}
	if got := byID["r1"]; got.State != "running" || got.Model != "sonnet" ||
		got.Ticket != "CDT-1" || got.Workflow != "debug" || got.Slot != queue.SlotHeld {
		t.Errorf("r1 = %+v, want the running held run", got)
	}
	got := byID["r2"]
	if got.State != "halted:stalled" || got.Halt == nil ||
		got.Halt.Reason != run.ReasonStalled || got.Halt.Detail != "no heartbeat for 2s" ||
		got.Halt.Budget != 2 || got.Halt.Remaining != 2 {
		t.Errorf("r2 = %+v, want the halted run with its reason and budget", got)
	}

	checks, err := c.Checks(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(checks) != 2 {
		t.Fatalf("checks = %d, want 2", len(checks))
	}

	up, err := c.Standup(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(up.Active) != 2 || len(up.Finished) != 0 {
		t.Errorf("standup active/finished = %d/%d, want 2/0",
			len(up.Active), len(up.Finished))
	}
	if len(up.Halts) != 1 || up.Halts[0].RunID != "r2" {
		t.Errorf("standup halts = %+v, want r2's halt", up.Halts)
	}
	if len(up.Slots) != 1 || up.Slots[0].State != queue.SlotHeld {
		t.Errorf("standup slots = %+v, want r1's held slot", up.Slots)
	}

	// A finished run moves to the standup's finished half.
	if err := m1.Complete(ctx, "node-agent-1", tok1, map[string]any{"exit_code": 0}, nil); err != nil {
		t.Fatal(err)
	}
	up, err = c.Standup(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(up.Active) != 1 || len(up.Finished) != 1 ||
		up.Finished[0].State != "completed" {
		t.Errorf("standup after completion = %+v, want r1 finished", up)
	}
}

// M3 (SPEC-044): the takeover registers the runRecord bookkeeping — the host
// the re-spawn rides — so the run reports, the checks reading, and the steer
// path resolve a taken-over run with no special case. A taken-over run is an
// ordinary run to every reading the chief serves.
func TestTakeoverRegistersTheTakenOverRunForRunsChecksAndSteer(t *testing.T) {
	_ = captureTakeoverLog(t)
	eng := newEngine(t)
	seedTakeoverRunning(t, eng, "r-taken", takeoverOwner, "omp")

	clock := takeoverClock(30 * time.Second)
	ag := &takeoverAgent{now: clock}
	c := newTakeoverChief(t, eng, ag, &fakePhone{})
	c.Now = clock
	rep, err := c.TakeoverScan(context.Background())
	if err != nil {
		t.Fatalf("TakeoverScan: %v", err)
	}
	if got := runIDsOf(rep.Taken); strings.Join(got, ",") != "r-taken" {
		t.Fatalf("taken = %v, want the taken-over run (%s)", got, joinReport(rep))
	}

	c.mu.Lock()
	rec, ok := c.runs["r-taken"]
	c.mu.Unlock()
	if !ok || rec.Host != hostadapter.HostOmp {
		t.Fatalf("the chief's record of r-taken = %+v (present %t), want the host its "+
			"start record names", rec, ok)
	}

	ctx := context.Background()
	rs, err := c.Run(ctx, "r-taken")
	if err != nil {
		t.Fatalf("run reading: %v", err)
	}
	if rs.State != "running" || rs.Halt != nil || rs.Ticket != takeoverTicket ||
		rs.Workflow != takeoverWorkflow {
		t.Errorf("run reading = %+v, want the taken-over run running on its journaled work", rs)
	}

	checks, err := c.Checks(ctx)
	if err != nil {
		t.Fatalf("checks reading: %v", err)
	}
	if len(checks) != 1 || checks[0].RunID != "r-taken" ||
		checks[0].State != "running" || len(checks[0].Takeover) != 0 {
		t.Errorf("checks = %+v, want the taken-over run and no takeover line for a taken run",
			checks)
	}

	// The steer path: the correction resolves the host from the chief's own
	// record of the taken-over run and reaches the host session.
	if err := c.Correct(ctx, CorrectRequest{RunID: "r-taken",
		Message: "steer text"}); err != nil {
		t.Fatalf("correct: %v", err)
	}
	frames := ag.steered()
	if len(frames) != 1 {
		t.Fatalf("steered = %d frames, want one", len(frames))
	}
	var frame map[string]any
	if err := json.Unmarshal([]byte(frames[0]), &frame); err != nil {
		t.Fatalf("frame is not JSON: %v", err)
	}
	if frame["type"] != "steer" {
		t.Errorf("frame = %v, want the omp steer frame", frame)
	}
}

// gateAgent is the node-agent seam of the start-race tests: every Supervise
// call records the capture the adapter handed it, says it is inside the
// start, and answers only when the test releases it, with its tabled error.
// The test owns the order of the two racing starts.
type gateAgent struct {
	mu       sync.Mutex
	captures []io.Writer
	inside   []chan struct{}
	release  []chan struct{}
	errs     []error
	n        int
}

func newGateAgent(errs ...error) *gateAgent {
	ag := &gateAgent{errs: errs}
	for range errs {
		ag.inside = append(ag.inside, make(chan struct{}))
		ag.release = append(ag.release, make(chan struct{}))
	}
	return ag
}

func (f *gateAgent) Supervise(_ context.Context, _ *journal.Engine,
	_ agent.StartRequest, cap io.Writer) error {
	f.mu.Lock()
	idx := f.n
	f.n++
	f.captures = append(f.captures, cap)
	f.mu.Unlock()
	close(f.inside[idx])
	<-f.release[idx]
	return f.errs[idx]
}

// capture is the session capture the i-th start rode.
func (f *gateAgent) capture(i int) *hostadapter.Capture {
	f.mu.Lock()
	defer f.mu.Unlock()
	cap, ok := f.captures[i].(*hostadapter.Capture)
	if !ok {
		return nil
	}
	return cap
}

func (f *gateAgent) Stop(_ context.Context, _ *journal.Engine, _ string,
	_ time.Duration) error {
	return nil
}

func (f *gateAgent) Steer(_ context.Context, _ *journal.Engine, _, _ string) error {
	return nil
}

func (f *gateAgent) Status(_ context.Context, _ *journal.Engine,
	runID string) (agent.StatusReport, error) {
	return agent.StatusReport{RunID: runID, State: "running"}, nil
}

// gateStartRequest is the start both racing calls carry.
func gateStartRequest(runID string) hostadapter.StartRequest {
	return hostadapter.StartRequest{RunID: runID, Ticket: "CDT-1",
		Workflow: "debug", Model: "sonnet", Host: hostadapter.HostOmp}
}

func gateChief(t *testing.T, eng *journal.Engine, ag *gateAgent) *Chief {
	t.Helper()
	return NewWithAdapter(eng, &hostadapter.Adapter{Agent: ag},
		WithTickets(&fakeTickets{}), WithModelMap(&fakeModels{}), WithPhone(&fakePhone{}))
}

// CDT-664: two starts for one run id share the record's key, so a refusal
// answers over a record its confirmed sibling is carrying. An errored start
// owns no confirmation: it deletes only an unconfirmed record, and the
// confirmed run keeps the capture the board, steer, and checks readings read.
func TestRefusedStartKeepsTheConfirmedRunsCapture(t *testing.T) {
	eng := newEngine(t)
	ag := newGateAgent(nil, fmt.Errorf("agent.ErrRunning: the runner is live"))
	c := gateChief(t, eng, ag)

	errc1 := c.startSupervised("r-race", gateStartRequest("r-race"))
	<-ag.inside[0]
	close(ag.release[0])
	if err := <-errc1; err != nil {
		t.Fatalf("first start: %v", err)
	}
	cap1 := ag.capture(0)
	rec, ok := runRecordOf(c, "r-race")
	if !ok || rec.Cap != cap1 {
		t.Fatalf("record after the confirmed start = %+v (present %t), want its capture", rec, ok)
	}

	errc2 := c.startSupervised("r-race", gateStartRequest("r-race"))
	<-ag.inside[1]
	close(ag.release[1])
	if err := <-errc2; err == nil {
		t.Fatal("second start: want the refusal")
	}

	rec, ok = runRecordOf(c, "r-race")
	if !ok {
		t.Fatal("the refused start deleted the confirmed run's record: the readings " +
			"lose the host and the capture until restart")
	}
	if rec.Cap != cap1 {
		t.Errorf("record Cap = %p, want the confirmed start's capture %p", rec.Cap, cap1)
	}
	if rec.Host != hostadapter.HostOmp {
		t.Errorf("record Host = %q, want the start's host", rec.Host)
	}
}

// CDT-664, the reverse order: the refusal deletes the shared record, so the
// start that lands after it must re-create one — otherwise its capture is
// silently dropped and Correct can no longer steer the run.
func TestConfirmedStartAfterARefusalKeepsTheCapture(t *testing.T) {
	eng := newEngine(t)
	ag := newGateAgent(fmt.Errorf("agent.ErrNoRunnerSelected: no runner"), nil)
	c := gateChief(t, eng, ag)

	errc1 := c.startSupervised("r-race", gateStartRequest("r-race"))
	<-ag.inside[0]
	errc2 := c.startSupervised("r-race", gateStartRequest("r-race"))
	<-ag.inside[1]

	close(ag.release[0])
	if err := <-errc1; err == nil {
		t.Fatal("first start: want the refusal")
	}
	close(ag.release[1])
	if err := <-errc2; err != nil {
		t.Fatalf("second start: %v", err)
	}

	rec, ok := runRecordOf(c, "r-race")
	if !ok {
		t.Fatal("the confirmed run has no record: the refused start deleted the " +
			"shared key and the confirmed capture was dropped")
	}
	if rec.Cap != ag.capture(1) {
		t.Errorf("record Cap = %p, want the confirmed start's capture %p",
			rec.Cap, ag.capture(1))
	}
	if rec.Host != hostadapter.HostOmp {
		t.Errorf("record Host = %q, want the start's host", rec.Host)
	}
}

// --- SPEC-045 AC1/AC8: the existing-ticket route (kind `ticket`) ----------

// plantTicket writes one backlog item in the store newEngine points
// DEVTEAM_MROOT at, in the shape the plugin's own add.sh writes. frontmatter
// is the frontmatter body ("kind: epic") or empty for a plain ticket.
func plantTicket(t *testing.T, slug, frontmatter string) string {
	t.Helper()
	dir := filepath.Join(os.Getenv("DEVTEAM_MROOT"), ".claude", "backlog")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	body := fmt.Sprintf("# %s\n\n**Status**: PENDING\n\n## Problem\n\ndo the work\n", slug)
	if frontmatter != "" {
		body = "---\n" + frontmatter + "\n---\n\n" + body
	}
	if err := os.WriteFile(filepath.Join(dir, slug+".md"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return slug
}

// plantAutopilotParser plants the parser files the ticket route's seams exec —
// skills/autopilot/parse-flags.sh (the autopilot token and the tier,
// council-tier, and max-loc tokens) and skills/advisor/parse-flags.sh (the
// --with-advisor token) — at one fixture plugin root, and records each call's
// argv. code is both parsers' exit: 0 admits the tokens, 64 is their
// malformed-flag refusal — the seams read the parsers' exit codes, never a Go
// copy of the vocabulary.
func plantAutopilotParser(t *testing.T, code int) (root, log string) {
	t.Helper()
	root = t.TempDir()
	log = filepath.Join(t.TempDir(), "argv.log")
	t.Setenv("CHIEF_SEAM_LOG", log)
	for _, rel := range []string{"skills/autopilot/parse-flags.sh",
		"skills/advisor/parse-flags.sh"} {
		path := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		script := fmt.Sprintf("#!/usr/bin/env bash\nprintf '%%s\\n' \"$*\" >> \"$CHIEF_SEAM_LOG\"\nexit %d\n", code)
		if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return root, log
}

// newTicketChief is the chief of the ticket-route tests: the fakes of
// newTestChief plus a plugin root the autopilot seam execs.
func newTicketChief(t *testing.T, eng *journal.Engine, tickets *fakeTickets,
	models *fakeModels, seam *fakeAgent, pluginRoot string) *Chief {
	t.Helper()
	c := NewWithAdapter(eng, &hostadapter.Adapter{Agent: seam},
		WithTickets(tickets), WithModelMap(models), WithPhone(&fakePhone{}),
		WithPluginRoot(pluginRoot))
	c.StartWait = 5 * time.Second
	return c
}

// AC1: an existing ticket id routes /orchestrate — the run carries the
// existing id as its ticket, the workflow is orchestrate, the command is the
// composed premise, and the store gains no row (zero ticket-seam calls).
func TestRouteExistingTicketStartsOneRun(t *testing.T) {
	eng := newEngine(t)
	plantTicket(t, "CDT-600", "")
	root, log := plantAutopilotParser(t, 0)
	tickets := &fakeTickets{slug: "CDT-600"}
	c := newTicketChief(t, eng, tickets, &fakeModels{model: "opus", source: "map"},
		&fakeAgent{}, root)

	res, err := c.Route(context.Background(), RouteRequest{
		Kind: "ticket", TicketID: "CDT-600", Host: hostadapter.HostGrok,
		Autopilot: "patch"})
	if err != nil {
		t.Fatalf("route: %v", err)
	}
	if res.Kind != "ticket" {
		t.Errorf("kind = %q, want ticket", res.Kind)
	}
	if res.Surface.Name != "orchestrate" || res.Surface.Path != "skills/orchestrate/SKILL.md" {
		t.Errorf("surface = %+v, want orchestrate (skills/orchestrate/SKILL.md)", res.Surface)
	}
	if res.RunID != "CDT-600" {
		t.Errorf("run id = %q, want the plain slug for a ticket's first run", res.RunID)
	}
	if want := "/orchestrate CDT-600 --autopilot=patch"; res.Command != want {
		t.Errorf("command = %q, want %q", res.Command, want)
	}
	if res.Model != "opus" || res.ModelSource != "map" {
		t.Errorf("model = %q/%q, want the map resolution", res.Model, res.ModelSource)
	}
	// AC8: routing an existing id writes no ticket record.
	if calls := tickets.recorded(); len(calls) != 0 {
		t.Errorf("ticket seam calls = %+v, want none", calls)
	}
	st, err := eng.RunState(context.Background(), res.RunID)
	if err != nil {
		t.Fatal(err)
	}
	if st.Workflow != "orchestrate" || st.Ticket != "CDT-600" || st.Model != "opus" {
		t.Errorf("run state = %s/%s/%s, want orchestrate/CDT-600/opus",
			st.Workflow, st.Ticket, st.Model)
	}
	// The token reached the plugin's own parser as one argv value.
	raw, err := os.ReadFile(log)
	if err != nil {
		t.Fatalf("the parser seam never ran: %v", err)
	}
	if !strings.Contains(string(raw), "--autopilot=patch") {
		t.Errorf("parser argv %q lacks --autopilot=patch", raw)
	}
}

// AC1: a ticket id whose item is an epic rides the epic surface — /epic
// <ID> --autopilot[=<token>], with the default token when the request names
// none.
func TestRouteExistingEpicRoutesTheEpicPath(t *testing.T) {
	eng := newEngine(t)
	plantTicket(t, "CDT-628", "kind: epic")
	root, log := plantAutopilotParser(t, 0)
	tickets := &fakeTickets{slug: "CDT-628"}
	c := newTicketChief(t, eng, tickets, &fakeModels{}, &fakeAgent{}, root)

	res, err := c.Route(context.Background(), RouteRequest{
		Kind: "ticket", TicketID: "CDT-628", Host: hostadapter.HostClaudeCode})
	if err != nil {
		t.Fatalf("route: %v", err)
	}
	if res.Surface.Name != "epic" || res.Surface.Path != "commands/epic.md" {
		t.Errorf("surface = %+v, want epic (commands/epic.md)", res.Surface)
	}
	if want := "/epic CDT-628 --autopilot=auto"; res.Command != want {
		t.Errorf("command = %q, want %q", res.Command, want)
	}
	st, err := eng.RunState(context.Background(), res.RunID)
	if err != nil {
		t.Fatal(err)
	}
	if st.Workflow != "epic" || st.Ticket != "CDT-628" {
		t.Errorf("run state = %s/%s, want epic/CDT-628", st.Workflow, st.Ticket)
	}
	if calls := tickets.recorded(); len(calls) != 0 {
		t.Errorf("ticket seam calls = %+v, want none", calls)
	}
	// The default token is the parser's own ship-intent default.
	raw, err := os.ReadFile(log)
	if err != nil {
		t.Fatalf("the parser seam never ran: %v", err)
	}
	if !strings.Contains(string(raw), "--autopilot=auto") {
		t.Errorf("parser argv %q lacks the default --autopilot=auto", raw)
	}
}

// AC1: a token the plugin's own parser refuses (its exit-64 usage code)
// refuses the route with a typed error before any run row is written.
func TestRouteRefusesAnIllegalAutopilotToken(t *testing.T) {
	eng := newEngine(t)
	plantTicket(t, "CDT-600", "")
	root, _ := plantAutopilotParser(t, 64)
	tickets := &fakeTickets{slug: "CDT-600"}
	c := newTicketChief(t, eng, tickets, &fakeModels{}, &fakeAgent{}, root)

	_, err := c.Route(context.Background(), RouteRequest{
		Kind: "ticket", TicketID: "CDT-600", Host: hostadapter.HostGrok,
		Autopilot: "hotdog"})
	if !errors.Is(err, ErrIllegalAutopilot) {
		t.Fatalf("err = %v, want ErrIllegalAutopilot", err)
	}
	if calls := tickets.recorded(); len(calls) != 0 {
		t.Errorf("ticket seam calls = %+v, want none", calls)
	}
	if exists, err := c.runExists(context.Background(), "CDT-600"); err != nil || exists {
		t.Errorf("the refused route left a run row (exists=%v, err=%v)", exists, err)
	}
}

// AC1/AC7: the "unknown ticket" refusal is the grammar's alone — a
// grammar-valid id the store holds no item for passes through (SPEC-046 M8,
// TestRouteTrackerIDWithoutLocalItemPassesThrough), and an id that is not a
// run-safe id refuses as malformed input before any run row and never reaches
// the store path.
func TestRouteRefusesAnUnknownTicketID(t *testing.T) {
	eng := newEngine(t)
	root, _ := plantAutopilotParser(t, 0)
	tickets := &fakeTickets{slug: "CDT-999"}
	c := newTicketChief(t, eng, tickets, &fakeModels{}, &fakeAgent{}, root)
	ctx := context.Background()

	for _, bad := range []string{"", "  ", "../secrets", "a/b", "CDT 600"} {
		if _, err := c.Route(ctx, RouteRequest{
			Kind: "ticket", TicketID: bad, Host: hostadapter.HostGrok}); !errors.Is(err, ErrInvalid) {
			t.Errorf("ticket id %q err = %v, want ErrInvalid", bad, err)
		}
	}
	if calls := tickets.recorded(); len(calls) != 0 {
		t.Errorf("ticket seam calls = %+v, want none", calls)
	}
	if ids, err := c.runIDs(ctx); err != nil || len(ids) != 0 {
		t.Errorf("the refused routes wrote runs %v (err %v), want none", ids, err)
	}
}

// storeItems answers the item file names the local store holds, in Glob order.
func storeItems(t *testing.T) []string {
	t.Helper()
	names, err := filepath.Glob(filepath.Join(os.Getenv("DEVTEAM_MROOT"),
		".claude", "backlog", "*.md"))
	if err != nil {
		t.Fatal(err)
	}
	out := make([]string, 0, len(names))
	for _, p := range names {
		out = append(out, filepath.Base(p))
	}
	return out
}

// AC7: a tracker id the local store holds no item for passes through — the
// route composes /orchestrate <ID> exactly as a local id, starts the run, and
// writes no store row. The scan of the store's items is frontmatter-only, so
// an item that names the id in its body resolves to nothing: the route stays
// on the orchestrate surface.
func TestRouteTrackerIDWithoutLocalItemPassesThrough(t *testing.T) {
	eng := newEngine(t)
	plantTicket(t, "chief-single-point-of-contact-router", "linear_id: CDT-626")
	plantTicket(t, "node-agent-native-runner", "linear_id: CDT-640")
	// A body-only mention of the id, with the epic keys a frontmatter match
	// would carry: the header-only scan must not read them.
	plantTicket(t, "body-only-mention", "")
	path := filepath.Join(os.Getenv("DEVTEAM_MROOT"), ".claude", "backlog",
		"body-only-mention.md")
	if err := os.WriteFile(path, []byte("# body-only-mention\n\n"+
		"linear_id: CDT-999\nkind: epic\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	before := storeItems(t)

	root, log := plantAutopilotParser(t, 0)
	tickets := &fakeTickets{slug: "CDT-999"}
	c := newTicketChief(t, eng, tickets, &fakeModels{}, &fakeAgent{}, root)
	ctx := context.Background()

	res, err := c.Route(ctx, RouteRequest{
		Kind: "ticket", TicketID: "CDT-999", Host: hostadapter.HostGrok})
	if err != nil {
		t.Fatalf("route: %v", err)
	}
	if res.Surface.Name != "orchestrate" {
		t.Errorf("surface = %q, want orchestrate — a passthrough id has no item kind",
			res.Surface.Name)
	}
	if want := "/orchestrate CDT-999 --autopilot=auto"; res.Command != want {
		t.Errorf("command = %q, want %q", res.Command, want)
	}
	if res.RunID != "CDT-999" {
		t.Errorf("run id = %q, want the tracker id", res.RunID)
	}
	st, err := eng.RunState(ctx, res.RunID)
	if err != nil {
		t.Fatal(err)
	}
	if st.Workflow != "orchestrate" || st.Ticket != "CDT-999" {
		t.Errorf("run state = %s/%s, want orchestrate/CDT-999", st.Workflow, st.Ticket)
	}
	// No store row: the ticket verbs never ran and the store is exactly what
	// the operator had before the route.
	if calls := tickets.recorded(); len(calls) != 0 {
		t.Errorf("ticket seam calls = %+v, want none", calls)
	}
	if after := storeItems(t); strings.Join(after, " ") != strings.Join(before, " ") {
		t.Errorf("store items = %v, want the scan to stay read-only (%v)", after, before)
	}
	raw, err := os.ReadFile(log)
	if err != nil {
		t.Fatalf("the parser seam never ran: %v", err)
	}
	if !strings.Contains(string(raw), "--autopilot=auto") {
		t.Errorf("parser argv %q lacks the default --autopilot=auto", raw)
	}
}

// AC7: an id that matches an item's frontmatter linear_id resolves to that
// item — the epic item rides the epic surface, the plain item rides
// /orchestrate, and the M4 orchestrate-option refusal applies to the resolved
// epic exactly as it does to a local slug.
func TestRouteResolvesALinearIDFrontmatterMatch(t *testing.T) {
	eng := newEngine(t)
	plantTicket(t, "control-plane-one-ui-and-a-chief-that-drives-durab",
		"linear_id: CDT-626\nkind: epic")
	plantTicket(t, "node-agent-native-runner", "linear_id: CDT-640")
	root, _ := plantAutopilotParser(t, 0)
	tickets := &fakeTickets{slug: "unused-slug"}
	c := newTicketChief(t, eng, tickets, &fakeModels{}, &fakeAgent{}, root)
	ctx := context.Background()

	res, err := c.Route(ctx, RouteRequest{
		Kind: "ticket", TicketID: "CDT-626", Host: hostadapter.HostClaudeCode})
	if err != nil {
		t.Fatalf("route: %v", err)
	}
	if res.Surface.Name != "epic" || res.Surface.Path != "commands/epic.md" {
		t.Errorf("surface = %+v, want epic (commands/epic.md) from the matched item",
			res.Surface)
	}
	if want := "/epic CDT-626 --autopilot=auto"; res.Command != want {
		t.Errorf("command = %q, want %q", res.Command, want)
	}
	st, err := eng.RunState(ctx, res.RunID)
	if err != nil {
		t.Fatal(err)
	}
	if st.Workflow != "epic" || st.Ticket != "CDT-626" {
		t.Errorf("run state = %s/%s, want epic/CDT-626", st.Workflow, st.Ticket)
	}

	// M4: the resolved epic refuses the orchestrate-only options by name.
	_, err = c.Route(ctx, RouteRequest{
		Kind: "ticket", TicketID: "CDT-626", Host: hostadapter.HostClaudeCode,
		Tier: "light", Concurrency: "4"})
	if !errors.Is(err, ErrOrchestrateOnlyOption) {
		t.Fatalf("err = %v, want ErrOrchestrateOnlyOption on the resolved epic", err)
	}

	// A plain matched item keeps the orchestrate surface.
	res, err = c.Route(ctx, RouteRequest{
		Kind: "ticket", TicketID: "CDT-640", Host: hostadapter.HostGrok,
		Autopilot: "patch"})
	if err != nil {
		t.Fatalf("route: %v", err)
	}
	if want := "/orchestrate CDT-640 --autopilot=patch"; res.Command != want {
		t.Errorf("command = %q, want %q", res.Command, want)
	}
	if calls := tickets.recorded(); len(calls) != 0 {
		t.Errorf("ticket seam calls = %+v, want none", calls)
	}
}

// AC8: every route of one existing id starts a further attempt and writes no
// store row — the run ids follow the attempt ladder, and a restarted chief
// reads the same answer from the journal.
func TestRepeatRoutesNeverWriteTheStore(t *testing.T) {
	eng := newEngine(t)
	plantTicket(t, "CDT-600", "")
	root, _ := plantAutopilotParser(t, 0)
	tickets := &fakeTickets{slug: "CDT-600"}
	ctx := context.Background()

	var got []string
	for i := 0; i < 3; i++ {
		c := newTicketChief(t, eng, tickets, &fakeModels{}, &fakeAgent{}, root)
		res, err := c.Route(ctx, RouteRequest{
			Kind: "ticket", TicketID: "CDT-600", Host: hostadapter.HostGrok,
			Autopilot: "auto"})
		if err != nil {
			t.Fatalf("route %d: %v", i+1, err)
		}
		got = append(got, res.RunID)
	}
	// A chief that holds no record of the runs allocates the next attempt
	// from the journal alone.
	restarted := newTicketChief(t, eng, tickets, &fakeModels{}, &fakeAgent{}, root)
	res, err := restarted.Route(ctx, RouteRequest{
		Kind: "ticket", TicketID: "CDT-600", Host: hostadapter.HostGrok})
	if err != nil {
		t.Fatalf("route after restart: %v", err)
	}
	got = append(got, res.RunID)

	want := []string{"CDT-600", "CDT-600-r2", "CDT-600-r3", "CDT-600-r4"}
	if strings.Join(got, " ") != strings.Join(want, " ") {
		t.Errorf("run ids = %v, want %v", got, want)
	}
	if calls := tickets.recorded(); len(calls) != 0 {
		t.Errorf("ticket seam calls = %+v, want none on any repeat", calls)
	}
	for _, id := range want {
		st, err := eng.RunState(context.Background(), id)
		if err != nil {
			t.Fatalf("run %s: %v", id, err)
		}
		if st.Ticket != "CDT-600" {
			t.Errorf("run %s ticket = %q, want CDT-600", id, st.Ticket)
		}
	}
}

// M3: the seam execs the plugin's own parser — the legal forms exit 0 and the
// vocabulary stays the script's. `bare` composes the valueless flag.
func TestAutopilotSeamRunsThePluginParser(t *testing.T) {
	t.Run("the flag form rides the token", func(t *testing.T) {
		root, log := plantAutopilotParser(t, 0)
		seat := &bashAutopilotFlags{root: func() (string, error) { return root, nil }}
		ctx := context.Background()
		if err := seat.Validate(ctx, "patch"); err != nil {
			t.Fatalf("patch: %v", err)
		}
		if err := seat.Validate(ctx, "bare"); err != nil {
			t.Fatalf("bare: %v", err)
		}
		raw, err := os.ReadFile(log)
		if err != nil {
			t.Fatal(err)
		}
		argv := string(raw)
		if !strings.Contains(argv, "--autopilot=patch") {
			t.Errorf("argv %q lacks --autopilot=patch", argv)
		}
		if !strings.Contains(argv, "--autopilot\n") {
			t.Errorf("argv %q lacks the valueless --autopilot for the bare token", argv)
		}
	})
	t.Run("the real parser admits its own vocabulary", func(t *testing.T) {
		seat := &bashAutopilotFlags{root: func() (string, error) { return "../..", nil }}
		ctx := context.Background()
		for _, token := range []string{"bare", "auto", "patch", "minor", "major", "master"} {
			if err := seat.Validate(ctx, token); err != nil {
				t.Errorf("token %q: %v", token, err)
			}
		}
	})
	t.Run("the real parser refuses an illegal token", func(t *testing.T) {
		// One argv value: the token never reaches a shell, so a token that
		// carries shell text is a vocabulary refusal, not a command.
		seat := &bashAutopilotFlags{root: func() (string, error) { return "../..", nil }}
		ctx := context.Background()
		for _, token := range []string{"hotdog", "Patch", "auto; rm -rf /", "--autopilot=patch"} {
			if err := seat.Validate(ctx, token); !errors.Is(err, ErrIllegalAutopilot) {
				t.Errorf("token %q err = %v, want ErrIllegalAutopilot", token, err)
			}
		}
	})
}

// The interface contract over the one interface: a ticket route answers the
// composed command and the run id, and each refusal is a typed 400 that
// writes no run row.
func TestTheAPIServesTheTicketRouteAndItsRefusals(t *testing.T) {
	eng := newEngine(t)
	plantTicket(t, "CDT-600", "")
	// The plugin's own parser is the seam here: the 400 below is the real
	// vocabulary's verdict, not a stub's.
	c := newTicketChief(t, eng, &fakeTickets{slug: "CDT-600"},
		&fakeModels{model: "opus", source: "map"}, &fakeAgent{}, "../..")

	post := func(body string) (int, map[string]any) {
		t.Helper()
		req := httptest.NewRequest(http.MethodPost, "/v1/route", strings.NewReader(body))
		rec := httptest.NewRecorder()
		c.Handler().ServeHTTP(rec, req)
		var out map[string]any
		if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
			t.Fatalf("body %q is not JSON: %v", rec.Body, err)
		}
		return rec.Code, out
	}

	code, out := post(`{"kind":"ticket","ticket_id":"CDT-600","host":"grok","autopilot":"patch"}`)
	if code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (%v)", code, out)
	}
	for key, want := range map[string]string{
		"kind": "ticket", "run_id": "CDT-600", "model": "opus",
		"command": "/orchestrate CDT-600 --autopilot=patch",
	} {
		if out[key] != want {
			t.Errorf("%s = %v, want %q", key, out[key], want)
		}
	}

	for _, body := range []string{
		`{"kind":"ticket","ticket_id":"CDT-600","host":"grok","autopilot":"hotdog"}`,
		// SPEC-046 AC7: the unknown-ticket 400 is the grammar's alone — an id
		// the grammar refuses, never a grammar-valid id the store lacks.
		`{"kind":"ticket","ticket_id":"a/b","host":"grok"}`,
	} {
		code, out := post(body)
		if code != http.StatusBadRequest {
			t.Errorf("status = %d for %s, want 400 (%v)", code, body, out)
		}
	}
	// The refusals wrote nothing: three routes, one run.
	runs, err := c.Runs(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(runs) != 1 || runs[0].RunID != "CDT-600" {
		t.Errorf("runs = %+v, want only the accepted route's run", runs)
	}
}

// --- SPEC-046 AC1: the ticket route's run options (M1/M2) ------------------

// AC1 regression lock (M2): an option request with nothing set composes
// today's exact command bytes — the SPEC-045 composition, byte for byte, for
// both workflows and for the bare token.
func TestComposeRunCommandGoldenBytes(t *testing.T) {
	for _, tc := range []struct{ workflow, id, token, want string }{
		{"orchestrate", "CDT-600", "auto", "/orchestrate CDT-600 --autopilot=auto"},
		{"orchestrate", "CDT-600", "patch", "/orchestrate CDT-600 --autopilot=patch"},
		{"orchestrate", "CDT-600", "master", "/orchestrate CDT-600 --autopilot=master"},
		{"orchestrate", "CDT-600", autopilotBare, "/orchestrate CDT-600 --autopilot"},
		{"epic", "CDT-628", "auto", "/epic CDT-628 --autopilot=auto"},
		{"epic", "CDT-628", autopilotBare, "/epic CDT-628 --autopilot"},
	} {
		if got := composeRunCommand(tc.workflow, tc.id, routeOptions{Autopilot: tc.token}); got != tc.want {
			t.Errorf("composeRunCommand(%q, %q, %q) = %q, want %q",
				tc.workflow, tc.id, tc.token, got, tc.want)
		}
	}
}

// AC1: a ticket route that carries no options composes today's exact command
// and echoes it as today — the empty form is byte-identical to SPEC-045.
func TestRouteTicketEmptyOptionsComposeTodaysCommand(t *testing.T) {
	eng := newEngine(t)
	plantTicket(t, "CDT-600", "")
	root, _ := plantAutopilotParser(t, 0)
	c := newTicketChief(t, eng, &fakeTickets{}, &fakeModels{}, &fakeAgent{}, root)

	res, err := c.Route(context.Background(), RouteRequest{
		Kind: "ticket", TicketID: "CDT-600", Host: hostadapter.HostGrok})
	if err != nil {
		t.Fatalf("route: %v", err)
	}
	if want := "/orchestrate CDT-600 --autopilot=auto"; res.Command != want {
		t.Errorf("command = %q, want %q", res.Command, want)
	}
}

// AC1 (M2): the present options compose in the pinned order — id first, then
// --tier, --council-tier, --max-loc, --concurrency N, --with-advisor[=<model>],
// then --autopilot[=<token>] last. Only present fields compose, `true`
// composes the bare advisor flag, and the caps never reach the command line
// (M5).
func TestRouteTicketComposesOptionsInPinnedOrder(t *testing.T) {
	for _, tc := range []struct {
		name, workflow, id string
		opts               routeOptions
		want               string
	}{
		{"every option", "orchestrate", "CDT-600", routeOptions{
			Tier: "light", CouncilTier: "skip", MaxLoc: "800", Concurrency: "4",
			WithAdvisor: "swift-x/model.1", Autopilot: "patch",
		}, "/orchestrate CDT-600 --tier=light --council-tier=skip --max-loc=800" +
			" --concurrency 4 --with-advisor=swift-x/model.1 --autopilot=patch"},
		{"bare advisor", "orchestrate", "CDT-600",
			routeOptions{WithAdvisor: advisorOn, Autopilot: autopilotBare},
			"/orchestrate CDT-600 --with-advisor --autopilot"},
		{"tier and autopilot only", "orchestrate", "CDT-600",
			routeOptions{Tier: "full", Autopilot: "auto"},
			"/orchestrate CDT-600 --tier=full --autopilot=auto"},
		{"max-loc unbound and concurrency", "orchestrate", "CDT-600", routeOptions{
			MaxLoc: "unbound", Concurrency: "1", Autopilot: "auto",
		}, "/orchestrate CDT-600 --max-loc=unbound --concurrency 1 --autopilot=auto"},
		{"council-tier alone before autopilot", "orchestrate", "CDT-600",
			routeOptions{CouncilTier: "light", Autopilot: "minor"},
			"/orchestrate CDT-600 --council-tier=light --autopilot=minor"},
		{"the caps never compose", "orchestrate", "CDT-600", routeOptions{
			WallclockCap: "2700", IterationCap: "25", Autopilot: "auto",
		}, "/orchestrate CDT-600 --autopilot=auto"},
		{"the epic workflow keeps the same order", "epic", "CDT-628",
			routeOptions{Tier: "light", Autopilot: "auto"},
			"/epic CDT-628 --tier=light --autopilot=auto"},
	} {
		if got := composeRunCommand(tc.workflow, tc.id, tc.opts); got != tc.want {
			t.Errorf("%s: composeRunCommand = %q, want %q", tc.name, got, tc.want)
		}
	}
}

// AC1 (M2): the route composes the pinned order from the request's fields and
// echoes it on the response.
func TestRouteTicketRouteComposesTheAdvancedOptions(t *testing.T) {
	eng := newEngine(t)
	plantTicket(t, "CDT-600", "")
	root, log := plantAutopilotParser(t, 0)
	c := newTicketChief(t, eng, &fakeTickets{}, &fakeModels{}, &fakeAgent{}, root)

	res, err := c.Route(context.Background(), RouteRequest{
		Kind: "ticket", TicketID: "CDT-600", Host: hostadapter.HostGrok,
		WithAdvisor: "true", Tier: "standard", CouncilTier: "full", MaxLoc: "1200",
		Concurrency: "3", WallclockCap: "2700", IterationCap: "25", Autopilot: "minor"})
	if err != nil {
		t.Fatalf("route: %v", err)
	}
	want := "/orchestrate CDT-600 --tier=standard --council-tier=full --max-loc=1200" +
		" --concurrency 3 --with-advisor --autopilot=minor"
	if res.Command != want {
		t.Errorf("command = %q, want %q", res.Command, want)
	}
	// The autopilot token still reaches the plugin's own parser.
	raw, err := os.ReadFile(log)
	if err != nil {
		t.Fatalf("the parser seam never ran: %v", err)
	}
	if !strings.Contains(string(raw), "--autopilot=minor") {
		t.Errorf("parser argv %q lacks --autopilot=minor", raw)
	}
}

// AC1 (M1): the option fields belong to the ticket route alone. The defect,
// idea, and epic kinds refuse every one of them with a typed 400 that writes
// no record and no run row.
func TestRouteNonTicketKindsRefuseTheOptionFields(t *testing.T) {
	eng := newEngine(t)
	tickets := &fakeTickets{slug: "opt-refusal"}
	c := newTestChief(t, eng, &fakeAgent{}, tickets, &fakeModels{}, &fakePhone{})
	ctx := context.Background()

	fields := []struct {
		name string
		set  func(*RouteRequest, string)
	}{
		{"with_advisor", func(r *RouteRequest, v string) { r.WithAdvisor = v }},
		{"tier", func(r *RouteRequest, v string) { r.Tier = v }},
		{"council_tier", func(r *RouteRequest, v string) { r.CouncilTier = v }},
		{"max_loc", func(r *RouteRequest, v string) { r.MaxLoc = v }},
		{"concurrency", func(r *RouteRequest, v string) { r.Concurrency = v }},
		{"wallclock_cap", func(r *RouteRequest, v string) { r.WallclockCap = v }},
		{"iteration_cap", func(r *RouteRequest, v string) { r.IterationCap = v }},
	}
	for _, kind := range []string{"defect", "idea", "epic"} {
		for _, f := range fields {
			req := RouteRequest{Kind: kind, Title: "Opt refusal", Text: "a premise",
				Host: hostadapter.HostGrok}
			if kind == "epic" {
				req.Children = []ChildRequest{{Title: "child one", Text: "a premise"}}
			}
			f.set(&req, "2")
			_, err := c.Route(ctx, req)
			if !errors.Is(err, ErrInvalid) {
				t.Errorf("kind %s field %s: err = %v, want ErrInvalid", kind, f.name, err)
				continue
			}
			if !strings.Contains(err.Error(), f.name) {
				t.Errorf("kind %s field %s: refusal %q names no field", kind, f.name, err)
			}
		}
	}
	if calls := tickets.recorded(); len(calls) != 0 {
		t.Errorf("ticket seam calls = %+v, want none", calls)
	}
	if ids, err := c.runIDs(ctx); err != nil || len(ids) != 0 {
		t.Errorf("the refused routes wrote runs %v (err %v), want none", ids, err)
	}
}

// AC1 (M1): over HTTP the same refusals answer 400 and the ticket route's
// option set answers 200 with the composed command.
func TestTheAPIRefusesTheOptionFieldsOnTheOtherKinds(t *testing.T) {
	eng := newEngine(t)
	plantTicket(t, "CDT-600", "")
	c := newTicketChief(t, eng, &fakeTickets{slug: "CDT-600"},
		&fakeModels{model: "opus", source: "map"}, &fakeAgent{}, "../..")

	post := func(body string) (int, map[string]any) {
		t.Helper()
		req := httptest.NewRequest(http.MethodPost, "/v1/route", strings.NewReader(body))
		rec := httptest.NewRecorder()
		c.Handler().ServeHTTP(rec, req)
		var out map[string]any
		if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
			t.Fatalf("body %q is not JSON: %v", rec.Body, err)
		}
		return rec.Code, out
	}

	code, out := post(`{"kind":"ticket","ticket_id":"CDT-600","host":"grok",` +
		`"tier":"light","concurrency":"4","with_advisor":"true","wallclock_cap":"2700"}`)
	if code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (%v)", code, out)
	}
	want := "/orchestrate CDT-600 --tier=light --concurrency 4 --with-advisor --autopilot=auto"
	if out["command"] != want {
		t.Errorf("command = %v, want %q", out["command"], want)
	}

	for _, body := range []string{
		`{"kind":"defect","title":"T","text":"P","host":"grok","tier":"light"}`,
		`{"kind":"idea","title":"T","text":"P","host":"grok","with_advisor":"true"}`,
		`{"kind":"epic","title":"T","text":"P","children":[{"title":"c1"}],"concurrency":"4"}`,
	} {
		code, out := post(body)
		if code != http.StatusBadRequest {
			t.Errorf("status = %d for %s, want 400 (%v)", code, body, out)
		}
	}
}

// --- SPEC-046 AC2: the option-validation seams and the M4 epic refusal ----

// AC2 (M3): the tier, council-tier, and max-loc tokens are validated by the
// plugin's own parser, exec'd as argv; its exit-64 refusal is a typed 400 that
// writes no run row. An empty option set execs nothing but the autopilot
// token's own seam call.
func TestRouteOptionValidationRidesThePluginParsers(t *testing.T) {
	t.Run("the present tokens reach the plugin parser as argv", func(t *testing.T) {
		eng := newEngine(t)
		plantTicket(t, "CDT-600", "")
		root, log := plantAutopilotParser(t, 0)
		c := newTicketChief(t, eng, &fakeTickets{}, &fakeModels{}, &fakeAgent{}, root)

		res, err := c.Route(context.Background(), RouteRequest{
			Kind: "ticket", TicketID: "CDT-600", Host: hostadapter.HostGrok,
			Tier: "standard", CouncilTier: "full", MaxLoc: "1200", Autopilot: "minor"})
		if err != nil {
			t.Fatalf("route: %v", err)
		}
		want := "/orchestrate CDT-600 --tier=standard --council-tier=full" +
			" --max-loc=1200 --autopilot=minor"
		if res.Command != want {
			t.Errorf("command = %q, want %q", res.Command, want)
		}
		raw, err := os.ReadFile(log)
		if err != nil {
			t.Fatalf("no parser seam ran: %v", err)
		}
		argv := string(raw)
		if !strings.Contains(argv, "--tier=standard --council-tier=full --max-loc=1200\n") {
			t.Errorf("parser argv %q lacks the option tokens on one call", argv)
		}
		if !strings.Contains(argv, "--autopilot=minor") {
			t.Errorf("parser argv %q lacks the autopilot token", argv)
		}
	})
	t.Run("an empty option set composes no parser tokens", func(t *testing.T) {
		eng := newEngine(t)
		plantTicket(t, "CDT-600", "")
		root, log := plantAutopilotParser(t, 0)
		c := newTicketChief(t, eng, &fakeTickets{}, &fakeModels{}, &fakeAgent{}, root)

		if _, err := c.Route(context.Background(), RouteRequest{
			Kind: "ticket", TicketID: "CDT-600", Host: hostadapter.HostGrok}); err != nil {
			t.Fatalf("route: %v", err)
		}
		raw, err := os.ReadFile(log)
		if err != nil {
			t.Fatalf("the autopilot seam never ran: %v", err)
		}
		if got := strings.TrimSpace(string(raw)); got != "--autopilot=auto" {
			t.Errorf("parser argv = %q, want only the default autopilot token", got)
		}
	})
	t.Run("the real parser admits its own vocabulary", func(t *testing.T) {
		eng := newEngine(t)
		plantTicket(t, "CDT-600", "")
		c := newTicketChief(t, eng, &fakeTickets{}, &fakeModels{}, &fakeAgent{}, "../..")

		res, err := c.Route(context.Background(), RouteRequest{
			Kind: "ticket", TicketID: "CDT-600", Host: hostadapter.HostGrok,
			Tier: "light", CouncilTier: "skip", MaxLoc: "unbound"})
		if err != nil {
			t.Fatalf("route: %v", err)
		}
		want := "/orchestrate CDT-600 --tier=light --council-tier=skip" +
			" --max-loc=unbound --autopilot=auto"
		if res.Command != want {
			t.Errorf("command = %q, want %q", res.Command, want)
		}
	})
	t.Run("the real parser refuses a value outside its vocabulary", func(t *testing.T) {
		eng := newEngine(t)
		plantTicket(t, "CDT-600", "")
		c := newTicketChief(t, eng, &fakeTickets{}, &fakeModels{}, &fakeAgent{}, "../..")
		ctx := context.Background()

		for _, tc := range []struct {
			set   func(*RouteRequest)
			token string
		}{
			{func(r *RouteRequest) { r.Tier = "Standard" }, "--tier=Standard"},
			{func(r *RouteRequest) { r.Tier = "standard-fast" }, "--tier=standard-fast"},
			{func(r *RouteRequest) { r.Tier = "light; rm -rf /" }, "--tier=light; rm -rf /"},
			{func(r *RouteRequest) { r.CouncilTier = "ultra" }, "--council-tier=ultra"},
			{func(r *RouteRequest) { r.MaxLoc = "0" }, "--max-loc=0"},
			{func(r *RouteRequest) { r.MaxLoc = "unlimited" }, "--max-loc=unlimited"},
			{func(r *RouteRequest) { r.MaxLoc = "1.5" }, "--max-loc=1.5"},
		} {
			req := RouteRequest{Kind: "ticket", TicketID: "CDT-600", Host: hostadapter.HostGrok}
			tc.set(&req)
			_, err := c.Route(ctx, req)
			if !errors.Is(err, ErrIllegalRunOption) {
				t.Errorf("token %q err = %v, want ErrIllegalRunOption", tc.token, err)
				continue
			}
			if !strings.Contains(err.Error(), tc.token) {
				t.Errorf("refusal %q does not name the token %q", err, tc.token)
			}
		}
		// Every refusal landed before any run row (M3).
		if ids, err := c.runIDs(ctx); err != nil || len(ids) != 0 {
			t.Errorf("the refused routes wrote runs %v (err %v), want none", ids, err)
		}
	})
}

// AC2 (M3): the advisor model token is validated by the plugin's own advisor
// parser (SPEC-039 M37) — the reserved tokens and a value outside the charset
// refuse with a typed 400; the bare flag and a legal model token route.
func TestRouteRefusesIllegalAdvisorModelToken(t *testing.T) {
	eng := newEngine(t)
	plantTicket(t, "CDT-600", "")
	c := newTicketChief(t, eng, &fakeTickets{}, &fakeModels{}, &fakeAgent{}, "../..")
	ctx := context.Background()

	for _, token := range []string{"null", "--clear", "a..b", "bad model",
		"mo|del", "tu*r", "mod;el"} {
		_, err := c.Route(ctx, RouteRequest{
			Kind: "ticket", TicketID: "CDT-600", Host: hostadapter.HostGrok,
			WithAdvisor: token})
		if !errors.Is(err, ErrIllegalAdvisorModel) {
			t.Errorf("token %q err = %v, want ErrIllegalAdvisorModel", token, err)
			continue
		}
		if !strings.Contains(err.Error(), token) {
			t.Errorf("refusal %q does not name the token %q", err, token)
		}
	}
	if ids, err := c.runIDs(ctx); err != nil || len(ids) != 0 {
		t.Errorf("the refused routes wrote runs %v (err %v), want none", ids, err)
	}

	for _, token := range []string{"true", "opus", "swift-x/model.1+@_~-"} {
		res, err := c.Route(ctx, RouteRequest{
			Kind: "ticket", TicketID: "CDT-600", Host: hostadapter.HostGrok,
			WithAdvisor: token})
		if err != nil {
			t.Errorf("token %q: route: %v", token, err)
			continue
		}
		want := "--with-advisor"
		if token != advisorOn {
			want += "=" + token
		}
		if !strings.Contains(res.Command, want) {
			t.Errorf("command = %q, want the %q flag", res.Command, want)
		}
	}
}

// AC2 (M3): concurrency and the two caps are the mechanical positive-integer
// checks — the CDT-573 grammar for concurrency, cited not copied, and no upper
// ceiling for the caps (SPEC-033 N14). They refuse before any seam execs.
func TestRouteRefusesIllegalConcurrencyAndCaps(t *testing.T) {
	eng := newEngine(t)
	plantTicket(t, "CDT-600", "")
	root, log := plantAutopilotParser(t, 0)
	c := newTicketChief(t, eng, &fakeTickets{}, &fakeModels{}, &fakeAgent{}, root)
	ctx := context.Background()

	setOf := func(field string) func(*RouteRequest, string) {
		return func(r *RouteRequest, v string) {
			switch field {
			case "concurrency":
				r.Concurrency = v
			case "wallclock_cap":
				r.WallclockCap = v
			case "iteration_cap":
				r.IterationCap = v
			}
		}
	}
	for _, tc := range []struct{ field, value string }{
		{"concurrency", "0"}, {"concurrency", "-1"}, {"concurrency", "1.5"},
		{"concurrency", "4x"}, {"concurrency", "unbound"},
		{"concurrency", "9223372036854775808"},
		{"wallclock_cap", "0"}, {"wallclock_cap", "-5"}, {"wallclock_cap", "2.5"},
		{"wallclock_cap", "abc"},
		{"iteration_cap", "0"}, {"iteration_cap", "zero"},
		{"iteration_cap", "9223372036854775808"},
	} {
		req := RouteRequest{Kind: "ticket", TicketID: "CDT-600", Host: hostadapter.HostGrok}
		setOf(tc.field)(&req, tc.value)
		_, err := c.Route(ctx, req)
		if !errors.Is(err, ErrIllegalOptionNumber) {
			t.Errorf("%s = %q err = %v, want ErrIllegalOptionNumber", tc.field, tc.value, err)
			continue
		}
		if !strings.Contains(err.Error(), tc.field) {
			t.Errorf("refusal %q does not name the field %q", err, tc.field)
		}
	}
	// The mechanical check is the syntax layer of M3: it refuses before the
	// parser seams exec.
	if _, err := os.Stat(log); !os.IsNotExist(err) {
		t.Errorf("a numeric refusal reached a parser seam (stat: %v)", err)
	}

	// The legal forms route. Concurrency composes as the plugin's two-token
	// form; the caps never reach the command line (M5).
	for _, tc := range []struct{ field, value, want string }{
		{"concurrency", "1", " --concurrency 1 "}, {"concurrency", "64", " --concurrency 64 "},
		{"wallclock_cap", "2700", " --autopilot=auto"},
		{"iteration_cap", "25", " --autopilot=auto"},
	} {
		req := RouteRequest{Kind: "ticket", TicketID: "CDT-600", Host: hostadapter.HostGrok}
		setOf(tc.field)(&req, tc.value)
		res, err := c.Route(ctx, req)
		if err != nil {
			t.Errorf("%s = %q: route: %v", tc.field, tc.value, err)
			continue
		}
		if !strings.Contains(res.Command, tc.want) {
			t.Errorf("%s = %q: command = %q, want it to carry %q",
				tc.field, tc.value, res.Command, tc.want)
		}
		if strings.Contains(res.Command, tc.value) && tc.field != "concurrency" {
			t.Errorf("%s = %q: command = %q carries the cap", tc.field, tc.value, res.Command)
		}
	}
	ids, err := c.runIDs(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(ids) != 4 {
		t.Errorf("runs = %v, want the four accepted routes only", ids)
	}
}

// M4: an epic-kind local item refuses every orchestrate-only option, naming
// the options, before any run row. The caps are not orchestrate-only — they
// ride the run's environment (M5) — so the epic route keeps accepting them and
// composes /epic with the autopilot token alone.
func TestRouteEpicItemRefusesOrchestrateOnlyOptions(t *testing.T) {
	fields := []struct {
		name string
		set  func(*RouteRequest, string)
	}{
		{"with_advisor", func(r *RouteRequest, v string) { r.WithAdvisor = v }},
		{"tier", func(r *RouteRequest, v string) { r.Tier = v }},
		{"council_tier", func(r *RouteRequest, v string) { r.CouncilTier = v }},
		{"max_loc", func(r *RouteRequest, v string) { r.MaxLoc = v }},
		{"concurrency", func(r *RouteRequest, v string) { r.Concurrency = v }},
	}
	t.Run("each orchestrate-only option refuses the epic item", func(t *testing.T) {
		eng := newEngine(t)
		plantTicket(t, "CDT-628", "kind: epic")
		root, _ := plantAutopilotParser(t, 0)
		c := newTicketChief(t, eng, &fakeTickets{}, &fakeModels{}, &fakeAgent{}, root)
		ctx := context.Background()

		for _, f := range fields {
			req := RouteRequest{Kind: "ticket", TicketID: "CDT-628",
				Host: hostadapter.HostClaudeCode}
			f.set(&req, "2")
			_, err := c.Route(ctx, req)
			if !errors.Is(err, ErrOrchestrateOnlyOption) {
				t.Errorf("field %s: err = %v, want ErrOrchestrateOnlyOption", f.name, err)
				continue
			}
			if !strings.Contains(err.Error(), f.name) {
				t.Errorf("field %s: refusal %q names no field", f.name, err)
			}
		}
		if ids, err := c.runIDs(ctx); err != nil || len(ids) != 0 {
			t.Errorf("the refused routes wrote runs %v (err %v), want none", ids, err)
		}
	})
	t.Run("the caps are not orchestrate-only", func(t *testing.T) {
		eng := newEngine(t)
		plantTicket(t, "CDT-628", "kind: epic")
		root, _ := plantAutopilotParser(t, 0)
		c := newTicketChief(t, eng, &fakeTickets{}, &fakeModels{}, &fakeAgent{}, root)

		res, err := c.Route(context.Background(), RouteRequest{
			Kind: "ticket", TicketID: "CDT-628", Host: hostadapter.HostClaudeCode,
			WallclockCap: "2700", IterationCap: "25"})
		if err != nil {
			t.Fatalf("route: %v", err)
		}
		if want := "/epic CDT-628 --autopilot=auto"; res.Command != want {
			t.Errorf("command = %q, want %q", res.Command, want)
		}
	})
	t.Run("the API answers 400 naming the options", func(t *testing.T) {
		eng := newEngine(t)
		plantTicket(t, "CDT-628", "kind: epic")
		root, _ := plantAutopilotParser(t, 0)
		c := newTicketChief(t, eng, &fakeTickets{}, &fakeModels{}, &fakeAgent{}, root)

		body := `{"kind":"ticket","ticket_id":"CDT-628","host":"claude-code",` +
			`"tier":"light","concurrency":"4","with_advisor":"true"}`
		req := httptest.NewRequest(http.MethodPost, "/v1/route", strings.NewReader(body))
		rec := httptest.NewRecorder()
		c.Handler().ServeHTTP(rec, req)
		var out map[string]any
		if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
			t.Fatalf("body %q is not JSON: %v", rec.Body, err)
		}
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("status = %d, want 400 (%v)", rec.Code, out)
		}
		msg, _ := out["error"].(string)
		for _, name := range []string{"with_advisor", "tier", "concurrency"} {
			if !strings.Contains(msg, name) {
				t.Errorf("refusal %q does not name %q", msg, name)
			}
		}
		if ids, err := c.runIDs(context.Background()); err != nil || len(ids) != 0 {
			t.Errorf("the refused route wrote runs %v (err %v), want none", ids, err)
		}
	})
}

// AC3/AC8 (SPEC-046 T6): the validated caps ride the one spawn path into the
// start request and the run's own run_started row — the record a retry and a
// takeover read back. A route that names no caps spawns none: the chief
// invents no budget (SPEC-033 N14).
func TestRouteCapsReachTheSpawnedStartAndTheJournal(t *testing.T) {
	eng := newEngine(t)
	plantTicket(t, "CDT-680", "")
	plantTicket(t, "CDT-681", "")
	root, _ := plantAutopilotParser(t, 0)
	seam := &fakeAgent{}
	c := newTicketChief(t, eng, &fakeTickets{slug: "CDT-680"},
		&fakeModels{model: "opus", source: "map"}, seam, root)

	res, err := c.Route(context.Background(), RouteRequest{
		Kind: "ticket", TicketID: "CDT-680", Host: hostadapter.HostGrok,
		Tier: "full", WallclockCap: "7200", IterationCap: "40", Autopilot: "auto"})
	if err != nil {
		t.Fatalf("route: %v", err)
	}
	reqs := seam.requests()
	if len(reqs) != 1 {
		t.Fatalf("starts = %d, want one", len(reqs))
	}
	if reqs[0].WallclockCapS != 7200 || reqs[0].IterationCapS != 40 {
		t.Errorf("spawn caps = %d/%d, want 7200/40",
			reqs[0].WallclockCapS, reqs[0].IterationCapS)
	}
	// The caps ride the environment channel, never the premise command line.
	for _, frag := range []string{"7200", "40", "CAP"} {
		if strings.Contains(res.Command, frag) {
			t.Errorf("the composed command carries %q: %q", frag, res.Command)
		}
	}
	st, err := eng.RunState(context.Background(), res.RunID)
	if err != nil {
		t.Fatal(err)
	}
	if st.WallclockCapS != 7200 || st.IterationCapS != 40 {
		t.Errorf("journaled caps = %d/%d, want 7200/40", st.WallclockCapS, st.IterationCapS)
	}

	bare, err := c.Route(context.Background(), RouteRequest{
		Kind: "ticket", TicketID: "CDT-681", Host: hostadapter.HostGrok})
	if err != nil {
		t.Fatalf("route the option-free ticket: %v", err)
	}
	reqs = seam.requests()
	if len(reqs) != 2 {
		t.Fatalf("starts = %d, want two", len(reqs))
	}
	if reqs[1].WallclockCapS != 0 || reqs[1].IterationCapS != 0 {
		t.Errorf("spawn caps = %d/%d, want 0/0 for a route with no caps",
			reqs[1].WallclockCapS, reqs[1].IterationCapS)
	}
	bareState, err := eng.RunState(context.Background(), bare.RunID)
	if err != nil {
		t.Fatal(err)
	}
	if bareState.WallclockCapS != 0 || bareState.IterationCapS != 0 {
		t.Errorf("journaled caps = %d/%d, want 0/0",
			bareState.WallclockCapS, bareState.IterationCapS)
	}
}
