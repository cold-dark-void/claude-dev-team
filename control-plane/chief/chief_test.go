package chief

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
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
	// startDelay delays the supervised claim, so a test can outlast the
	// route's StartWait.
	startDelay time.Duration
}

func (f *fakeAgent) Supervise(ctx context.Context, eng *journal.Engine,
	req agent.StartRequest, _ io.Writer) error {
	if f.startDelay > 0 {
		time.Sleep(f.startDelay)
	}
	m := run.New(eng, req.RunID)
	token, err := m.Claim(ctx, "fake-agent", req.Ticket, req.Workflow, req.Model)
	if err != nil {
		return err
	}
	return m.Start(ctx, "fake-agent", token, req.Model)
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
