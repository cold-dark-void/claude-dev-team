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
	"github.com/cold-dark-void/claude-dev-team/control-plane/queue"
	"github.com/cold-dark-void/claude-dev-team/control-plane/run"
	"github.com/cold-dark-void/claude-dev-team/control-plane/spool"
)

// AC2: the board shows, per run, state, current phase, halt reason, retry
// budget, queue position, node, and runner type — every field from journal,
// queue, spool, and node state, never prose. A waiting runner ranks in the
// queue; a held one does not. The node column is the replayed owner — the
// node agent that holds the run.
func TestBoardCarriesStatePhaseHaltBudgetQueueNodeAndRunner(t *testing.T) {
	eng := newEngine(t)
	c := newTestChief(t, eng, &fakeAgent{}, &fakeTickets{slug: "board-run"},
		&fakeModels{}, &fakePhone{})

	// The C3 phase-event read: the fixture spool the fold rides — the
	// default spool of the fixture root, the C3 contract's own path.
	sp, err := spool.OpenDefault()
	if err != nil {
		t.Fatal(err)
	}
	for _, rec := range []spool.Record{
		{RunID: "board-run", Phase: "claim", Kind: spool.KindStart},
		{RunID: "board-run", Phase: "claim", Kind: spool.KindEnd},
		{RunID: "board-run", Phase: "plan", Kind: spool.KindStart},
	} {
		if _, _, err := sp.Emit(spool.Record{
			TS: "2026-11-18T12:00:00Z", RunID: rec.RunID,
			Phase: rec.Phase, Kind: rec.Kind,
		}); err != nil {
			t.Fatalf("spool %s/%s: %v", rec.Phase, rec.Kind, err)
		}
	}

	// A run on a capped model: one held slot, then a waiter. The cap comes
	// from the Model map's local layer (SPEC-037 M11), the C5 chain.
	mroot, err := journal.MROOT()
	if err != nil {
		t.Fatal(err)
	}
	writeModelMap(t, mroot, `{"version":1,"concurrency":2,"model_slots":{"sonnet":1}}`)
	m1 := run.New(eng, "board-run")
	token1, err := m1.Claim(context.Background(), "node-agent-1", "board-run", "debug", "sonnet")
	if err != nil {
		t.Fatal(err)
	}
	if err := m1.Start(context.Background(), "node-agent-1", token1, "sonnet"); err != nil {
		t.Fatal(err)
	}
	granted, err := c.Queue.Grant(context.Background(), "node-agent-1", token1,
		queue.Request{RunID: "board-run", Runner: "node-agent-1", Model: "sonnet"})
	if err != nil || !granted {
		t.Fatalf("grant: granted=%v err=%v", granted, err)
	}
	m2 := run.New(eng, "board-run-2")
	token2, err := m2.Claim(context.Background(), "node-agent-2", "T", "debug", "sonnet")
	if err != nil {
		t.Fatal(err)
	}
	if err := m2.Start(context.Background(), "node-agent-2", token2, "sonnet"); err != nil {
		t.Fatal(err)
	}
	granted, err = c.Queue.Grant(context.Background(), "node-agent-2", token2,
		queue.Request{RunID: "board-run-2", Runner: "node-agent-2", Model: "sonnet"})
	if err != nil || granted {
		t.Fatalf("overflow grant: granted=%v err=%v, want a wait", granted, err)
	}

	// A halt row: the reason and the remaining retry budget land on the
	// board from the C2 halt row.
	if err := m2.Halt(context.Background(), "node-agent-2", token2,
		run.ReasonStalled, "no heartbeat for 1s"); err != nil {
		t.Fatal(err)
	}

	srv := httptest.NewServer(c.Handler())
	t.Cleanup(srv.Close)

	var doc struct {
		Runs []RunStatus `json:"runs"`
	}
	if err := json.Unmarshal(get(t, srv, "/v1/runs"), &doc); err != nil {
		t.Fatal(err)
	}
	byID := map[string]RunStatus{}
	for _, rs := range doc.Runs {
		byID[rs.RunID] = rs
	}

	helping := byID["board-run"]
	if helping.State != "running" || helping.Phase != "plan" || helping.Owner != "node-agent-1" ||
		helping.RunnerType != "native" || helping.Slot != queue.SlotHeld ||
		helping.QueuePosition != 0 {
		t.Errorf("board-run = %+v, want running in plan on node-agent-1, held, native, no queue", helping)
	}
	waiting := byID["board-run-2"]
	if waiting.State != "halted:stalled" || waiting.Halt == nil ||
		waiting.Halt.Reason != "stalled" ||
		waiting.Halt.Budget != run.RetryBudgets["stalled"] ||
		waiting.Halt.Remaining != waiting.Halt.Budget ||
		waiting.QueuePosition != 1 || waiting.Owner != "node-agent-2" {
		t.Errorf("board-run-2 = %+v (halt %+v), want halted:stalled at queue position 1 with the budget",
			waiting, waiting.Halt)
	}
	// No phase event for the second run: the fold fails closed to an empty
	// phase, and the state still says where the machine is.
	if waiting.Phase != "" {
		t.Errorf("phase = %q, want empty without a phase event", waiting.Phase)
	}
}

// AC11: a taken-over run reads running on the board with the halt cell
// clear, with no operator action. The run needs no board special case — the
// cell is the replayed state and the takeover's resume clears the halt. The
// halt record stays readable: the cell is the now, the halt rows are the
// history, and the takeover lease at token+1 is the trail that proves it.
func TestBoardShowsATakenOverRunRunningWithTheHaltCellClear(t *testing.T) {
	_ = captureTakeoverLog(t)
	eng := newEngine(t)
	// The two shapes the scan takes over: the watchdog halt (the resume
	// path, whose halt cell must clear) and the stale lease (no halt row).
	seedTakeoverStalled(t, eng, "r-stalled", takeoverOwner, "claude")
	seedTakeoverRunning(t, eng, "r-stale", takeoverOwner, "grok")

	clock := takeoverClock(30 * time.Second)
	c := newTakeoverChief(t, eng, &takeoverAgent{now: clock}, &fakePhone{})
	c.Now = clock
	rep, err := c.TakeoverScan(context.Background())
	if err != nil {
		t.Fatalf("TakeoverScan: %v", err)
	}
	if got := runIDsOf(rep.Taken); strings.Join(got, ",") != "r-stalled,r-stale" {
		t.Fatalf("taken = %v, want both selected runs (%s)", got, joinReport(rep))
	}

	srv := httptest.NewServer(c.Handler())
	t.Cleanup(srv.Close)
	var doc struct {
		Runs []RunStatus `json:"runs"`
	}
	if err := json.Unmarshal(get(t, srv, "/v1/runs"), &doc); err != nil {
		t.Fatal(err)
	}
	byID := map[string]RunStatus{}
	for _, rs := range doc.Runs {
		byID[rs.RunID] = rs
	}
	owner := takeoverOwnerOf()
	for _, id := range []string{"r-stalled", "r-stale"} {
		rs := byID[id]
		if rs.State != "running" || rs.Halt != nil || rs.Owner != owner || rs.Stint != 1 {
			t.Errorf("%s board row = %+v, want running with a clear halt cell on %q at stint 1",
				id, rs, owner)
		}
	}

	// The stalled run's halt row stays in the record the halts surface
	// reads — the board cell clears, the history does not vanish.
	halts, err := c.Halts(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(halts) != 1 || halts[0].RunID != "r-stalled" ||
		halts[0].Reason != run.ReasonStalled {
		t.Errorf("halts = %+v, want r-stalled's stalled halt row", halts)
	}

	// M11's proof: the takeover lease at token+1, reason takeover.
	for _, id := range []string{"r-stalled", "r-stale"} {
		row := leaseAcquired(t, eng, id)
		if row.Reason != "takeover" || row.Token != 2 || row.Owner != owner {
			t.Errorf("%s lease_acquired = %+v, want reason takeover at token 2 on %q",
				id, row, owner)
		}
	}
}

// AC3: the lifecycle graph serves from the committed graph JSON through
// control-plane/lifecycle — the same file the loader validates, never a
// second copy of it.
func TestGraphEndpointServesTheLifecycleJSON(t *testing.T) {
	eng := newEngine(t)
	c := newTestChief(t, eng, &fakeAgent{}, &fakeTickets{}, &fakeModels{}, &fakePhone{})
	srv := httptest.NewServer(c.Handler())
	t.Cleanup(srv.Close)

	raw := get(t, srv, "/v1/graph")
	var g struct {
		Graph         string `json:"graph"`
		SchemaVersion string `json:"schema_version"`
		Vertices      []struct {
			ID   string `json:"id"`
			Kind string `json:"kind"`
		} `json:"vertices"`
	}
	if err := json.Unmarshal(raw, &g); err != nil {
		t.Fatalf("graph = %s: %v", raw, err)
	}
	if g.Graph != "control-plane-lifecycle" || g.SchemaVersion != "1" {
		t.Errorf("graph identity = %s/%s, want control-plane-lifecycle/1", g.Graph, g.SchemaVersion)
	}
	var phases, states int
	for _, v := range g.Vertices {
		switch v.Kind {
		case "workflow-phase":
			phases++
		case "run-state":
			states++
		}
	}
	if phases != 7 || states != 9 {
		t.Errorf("vertices = %d phases, %d states, want 7 and 9", phases, states)
	}
}

// writeModelMap plants the Model map's local layer in the fixture root —
// the C5 caps chain, local layer first.
func writeModelMap(t *testing.T, dir, doc string) {
	t.Helper()
	dirPath := filepath.Join(dir, ".claude", "dev-team")
	if err := os.MkdirAll(dirPath, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dirPath, "models.local.json"),
		[]byte(doc), 0o644); err != nil {
		t.Fatal(err)
	}
}

// AC5: every existing Surface still works standalone in a terminal — one
// check per Surface. The check is hermetic: the Surface's own plugin file
// exists at the checkout, still names its frontmatter (it is a terminal
// command/skill on its own), and the Chief's route names that same file —
// the UI added no copy of any Surface and no endpoint of its own.
func TestSurfacesStillWorkStandaloneInTheTerminal(t *testing.T) {
	// The checkout root: two levels above the package directory.
	root := "../.."

	for _, tc := range []struct {
		kind    string
		surface string
		path    string
	}{
		{"defect", "debug", "commands/debug.md"},
		{"idea", "brainstorm", "skills/brainstorm/SKILL.md"},
		{"epic", "epic", "commands/epic.md"},
	} {
		t.Run(tc.surface, func(t *testing.T) {
			// The Surface is a real plugin file that works in a terminal.
			raw, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(tc.path)))
			if err != nil {
				t.Fatalf("the %s Surface is not at %s: %v", tc.surface, tc.path, err)
			}
			text := string(raw)
			if !strings.HasPrefix(text, "---\n") ||
				!strings.Contains(text, "name:") || !strings.Contains(text, "description:") {
				t.Errorf("%s carries no Surface frontmatter", tc.path)
			}

			// The Chief routes to that file by name — no copy of the
			// Surface behind the UI.
			surface, ok := SurfaceFor(tc.kind)
			if !ok || surface.Name != tc.surface || surface.Path != tc.path {
				t.Errorf("SurfaceFor(%q) = %+v, want the standalone Surface at %s",
					tc.kind, surface, tc.path)
			}
		})
	}
}
