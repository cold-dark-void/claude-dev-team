package lifecycle

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// The committed graph the loader is built for.
func graphBytes(t *testing.T) []byte {
	t.Helper()
	path, err := Resolve()
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return raw
}

func rootOf(t *testing.T) map[string]any {
	t.Helper()
	var root map[string]any
	if err := json.Unmarshal(graphBytes(t), &root); err != nil {
		t.Fatalf("the committed graph does not decode: %v", err)
	}
	return root
}

func elemOf(t *testing.T, root map[string]any, section, id string) map[string]any {
	t.Helper()
	items, ok := root[section].([]any)
	if !ok {
		t.Fatalf("section %q is not a list", section)
	}
	for _, it := range items {
		m, ok := it.(map[string]any)
		if ok && m["id"] == id {
			return m
		}
	}
	t.Fatalf("no element with id %q in section %q", id, section)
	return nil
}

func dropElem(t *testing.T, root map[string]any, section, id string) {
	t.Helper()
	items, ok := root[section].([]any)
	if !ok {
		t.Fatalf("section %q is not a list", section)
	}
	out := make([]any, 0, len(items))
	for _, it := range items {
		if m, ok := it.(map[string]any); ok && m["id"] == id {
			continue
		}
		out = append(out, it)
	}
	root[section] = out
}

func copyElem(t *testing.T, root map[string]any, section, id string) {
	t.Helper()
	src := elemOf(t, root, section, id)
	raw, err := json.Marshal(src)
	if err != nil {
		t.Fatalf("copy %s: %v", id, err)
	}
	var cp map[string]any
	if err := json.Unmarshal(raw, &cp); err != nil {
		t.Fatalf("copy %s: %v", id, err)
	}
	root[section] = append(root[section].([]any), cp)
}

func guardOf(t *testing.T, root map[string]any, edgeID string, i int) map[string]any {
	t.Helper()
	guards, ok := elemOf(t, root, "edges", edgeID)["guards"].([]any)
	if !ok || i >= len(guards) {
		t.Fatalf("edge %q has no guard %d", edgeID, i)
	}
	g, ok := guards[i].(map[string]any)
	if !ok {
		t.Fatalf("edge %q guard %d is not an object", edgeID, i)
	}
	return g
}

func TestLoadsTheCommittedGraph(t *testing.T) {
	g, err := LoadDefault()
	if err != nil {
		t.Fatalf("LoadDefault: %v", err)
	}
	if g.Graph != GraphName || g.SchemaVersion != SchemaVersion {
		t.Errorf("identity = %q/%q, want %q/%q", g.Graph, g.SchemaVersion, GraphName, SchemaVersion)
	}
	if n := len(g.Phases()); n != 7 {
		t.Errorf("workflow phases = %d, want 7 (claim, plan, implement, review, qa, ship, wrap)", n)
	}
	if n := len(g.RunStates()); n != len(machineStates()) {
		t.Errorf("run-state vertices = %d, want %d (one per machine state)", n, len(machineStates()))
	}
	if n := len(g.BoundaryList()); n != 10 {
		t.Errorf("kill boundaries = %d, want 10", n)
	}
	if n := len(g.Checkpoints()); n != 9 {
		t.Errorf("checkpoints = %d, want 9", n)
	}
	for _, v := range g.RunStates() {
		if !slices.Contains(machineStates(), v.ID) {
			t.Errorf("run-state vertex %q is not a machine state", v.ID)
		}
	}
	want := []string{"claim", "plan", "implement", "review", "qa", "ship", "wrap"}
	var got []string
	for _, p := range g.Phases() {
		got = append(got, p.ID)
	}
	if !slices.Equal(got, want) {
		t.Errorf("phase ladder = %v, want %v", got, want)
	}
}

// AC2: the boundary list and the checkpoint points come out of the graph.
func TestBoundaryListIsOrderedAndDefensive(t *testing.T) {
	g, err := LoadDefault()
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"claimed", "running", "stint", "heartbeat", "intent",
		"effect", "outcome", "halted", "resumed", "completed"}
	got := make([]string, 0, 10)
	for _, b := range g.BoundaryList() {
		got = append(got, b.ID)
	}
	if !slices.Equal(got, want) {
		t.Errorf("BoundaryList = %v, want %v", got, want)
	}

	list := g.BoundaryList()
	list[0].ID = "clobbered"
	if g.BoundaryList()[0].ID != "claimed" {
		t.Error("BoundaryList leaked the graph's own slice")
	}
	cks := g.Checkpoints()
	cks[0].ID = "clobbered"
	if g.Checkpoints()[0].ID != "claim" {
		t.Error("Checkpoints leaked the graph's own slice")
	}
}

// AC2: every checkpoint points at one vertex and exactly one of a boundary or a
// gate card; the three gate checkpoints cover the three SPEC-033 gate names.
func TestCheckpointsReferenceOneVertexAndOneReference(t *testing.T) {
	g, err := LoadDefault()
	if err != nil {
		t.Fatal(err)
	}
	gates := map[string]bool{}
	for _, c := range g.Checkpoints() {
		if _, ok := g.VertexByID(c.Phase); !ok {
			t.Errorf("checkpoint %q names vertex %q, which does not exist", c.ID, c.Phase)
		}
		if (c.Boundary == "") == (c.CardGate == "") {
			t.Errorf("checkpoint %q: boundary=%q card_gate=%q, want exactly one set",
				c.ID, c.Boundary, c.CardGate)
		}
		if c.CardGate != "" {
			gates[c.CardGate] = true
		}
	}
	for _, name := range GateNames {
		if !gates[name] {
			t.Errorf("no checkpoint reads the %q decision-card", name)
		}
	}
}

func TestEdgeGuardReturnsTheEdgeAndItsGuards(t *testing.T) {
	g, err := LoadDefault()
	if err != nil {
		t.Fatal(err)
	}
	e, err := g.EdgeGuard("claim", "run_claimed")
	if err != nil {
		t.Fatalf("EdgeGuard(claim, run_claimed): %v", err)
	}
	if e.ID != "claim-plan" || e.Kind != EdgeKindGate || e.Gate != "scope-confirm" {
		t.Errorf("edge = %s kind=%s gate=%s, want claim-plan gate scope-confirm",
			e.ID, e.Kind, e.Gate)
	}
	if len(e.Guards) != 6 {
		t.Errorf("claim-plan guards = %d, want 6", len(e.Guards))
	}
	var bc7 *Guard
	for i := range e.Guards {
		if e.Guards[i].BC == "BC7" {
			bc7 = &e.Guards[i]
		}
	}
	if bc7 == nil {
		t.Fatal("claim-plan carries no BC7 guard")
	}
	if bc7.Outcome != OutcomeHalt || bc7.Citation != Spec033+":255" {
		t.Errorf("BC7 = %s %s, want %s %s:255", bc7.Outcome, bc7.Citation, OutcomeHalt, Spec033)
	}

	// The edge that writes no journal row is reached with an empty event.
	if e, err := g.EdgeGuard("qa", ""); err != nil || e.ID != "qa-ship" {
		t.Errorf("EdgeGuard(qa, \"\") = %v %v, want the qa-ship edge", e.ID, err)
	}
	if _, err := g.EdgeGuard("claim", "heartbeat"); !errors.Is(err, ErrNoSuchEdge) {
		t.Errorf("EdgeGuard(claim, heartbeat) err = %v, want %v", err, ErrNoSuchEdge)
	}
	guards, ok := g.Guards("plan", "run_started")
	if !ok || len(guards) == 0 {
		t.Fatalf("Guards(plan, run_started) = %d guards, ok=%v", len(guards), ok)
	}
	if _, ok := g.Guards("claim", "heartbeat"); ok {
		t.Error("Guards matched a missing edge")
	}
}

// A (phase, event) pair that fans out to more than one target state names no
// single step, so the accessor refuses and names the candidates rather than
// returning the last edge in the file (B1).
func TestEdgeGuardRefusesAnAmbiguousEventPair(t *testing.T) {
	g, err := LoadDefault()
	if err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		phase, event string
		want         []string
	}{
		{"running", "run_halted", []string{
			"running-halted-stalled", "running-halted-lease_lost",
			"running-halted-reconcile_failed", "running-halted-budget_exhausted",
			"running-halted-operator_halt",
		}},
		{"claimed", "run_halted", []string{"claimed-halted-stalled", "claimed-halted-operator_halt"}},
	}
	for _, tc := range cases {
		_, err := g.EdgeGuard(tc.phase, tc.event)
		if !errors.Is(err, ErrAmbiguousEdge) {
			t.Errorf("EdgeGuard(%q, %q) err = %v, want %v", tc.phase, tc.event, err, ErrAmbiguousEdge)
			continue
		}
		var le *EdgeLookupError
		if !errors.As(err, &le) {
			t.Fatalf("err %v is not a *EdgeLookupError", err)
		}
		if le.Phase != tc.phase || le.Event != tc.event {
			t.Errorf("EdgeLookupError = %+v, want phase %q event %q", le, tc.phase, tc.event)
		}
		if !slices.Equal(le.Candidates, tc.want) {
			t.Errorf("candidates = %v, want %v", le.Candidates, tc.want)
		}
		for _, id := range tc.want {
			if !strings.Contains(err.Error(), id) {
				t.Errorf("message does not name the candidate %q: %s", id, err)
			}
		}
	}

	// No pair in the committed graph is ambiguous except run_halted.
	for _, e := range g.Edges {
		if e.Event == "run_halted" {
			continue
		}
		if _, err := g.EdgeGuard(e.From, e.Event); err != nil {
			t.Errorf("EdgeGuard(%q, %q) = %v, want the unambiguous edge %q", e.From, e.Event, err, e.ID)
		}
	}
}

// Every edge of a fan-out pair stays reachable through the index, so the BC6
// guard on running-halted-budget_exhausted is not hidden by the other halt edges
// (B1, specs/core/SPEC-033-autopilot-policy.md:254).
func TestGuardsReturnsEveryGuardOfTheEventPair(t *testing.T) {
	g, err := LoadDefault()
	if err != nil {
		t.Fatal(err)
	}
	guards, ok := g.Guards("running", "run_halted")
	if !ok {
		t.Fatal("Guards(running, run_halted) found no edge")
	}
	var bc6 []Guard
	for _, gd := range guards {
		if gd.BC == "BC6" {
			bc6 = append(bc6, gd)
		}
	}
	if len(bc6) != 1 {
		t.Fatalf("running + run_halted guards = %d, want the single BC6 guard of the graph: %+v",
			len(guards), guards)
	}
	want := Guard{BC: "BC6", Label: "Run-budget breach", Outcome: OutcomeHalt,
		Citation: Spec033 + ":254"}
	if bc6[0] != want {
		t.Errorf("BC6 guard = %+v, want %+v", bc6[0], want)
	}

	// The pair's guard set is the union over the edges, in graph order.
	var wantGuard []Guard
	for _, e := range g.Edges {
		if e.From == "running" && e.Event == "run_halted" {
			wantGuard = append(wantGuard, e.Guards...)
		}
	}
	if len(guards) != len(wantGuard) {
		t.Fatalf("guard count = %d, want %d", len(guards), len(wantGuard))
	}
	for i := range guards {
		if guards[i] != wantGuard[i] {
			t.Errorf("guard %d = %+v, want %+v", i, guards[i], wantGuard[i])
		}
	}
	guards[0].Label = "clobbered"
	again, _ := g.Guards("running", "run_halted")
	if again[0].Label == "clobbered" {
		t.Error("Guards leaked the graph's own guards")
	}
}

// Shared (from, event) pairs are legal graph data: the load is silent, and the
// whole fan-out survives indexing (B1).
func TestLoadIsSilentOnSharedEventPairs(t *testing.T) {
	root := rootOf(t)
	groups := map[string]int{}
	items, ok := root["edges"].([]any)
	if !ok {
		t.Fatal("edges section is not a list")
	}
	for _, it := range items {
		m, ok := it.(map[string]any)
		if !ok {
			t.Fatal("an edge is not an object")
		}
		groups[fmt.Sprintf("%s\x00%s", m["from"], m["event"])]++
	}

	g, err := LoadBytes(graphBytes(t))
	if err != nil {
		t.Fatalf("the committed graph shares (from, event) pairs and must still load: %v", err)
	}
	if len(g.Edges) != len(items) {
		t.Fatalf("loaded %d edges, the file carries %d", len(g.Edges), len(items))
	}
	for _, e := range g.Edges {
		_, ok := g.VertexByID(e.To)
		if !ok {
			t.Fatalf("edge %q targets the missing vertex %q", e.ID, e.To)
		}
		if n := groups[fmt.Sprintf("%s\x00%s", e.From, e.Event)]; n == 0 {
			t.Errorf("edge %q is not in any (from, event) group", e.ID)
		}
	}
	if n := groups["running\x00run_halted"]; n != 5 {
		t.Errorf("running + run_halted edges = %d, want 5", n)
	}
	if n := groups["claimed\x00run_halted"]; n != 2 {
		t.Errorf("claimed + run_halted edges = %d, want 2", n)
	}
}

// AC6: SPEC-033 stays the gate policy. Every guard is a citation into it, and no
// guard restates a condition.
func TestEveryGuardIsASPEC033Citation(t *testing.T) {
	g, err := LoadDefault()
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, e := range g.Edges {
		for _, gd := range e.Guards {
			n++
			if !strings.HasPrefix(gd.Citation, Spec033+":") {
				t.Errorf("guard %s on %s cites %q, want a %s line",
					gd.BC, e.ID, gd.Citation, Spec033)
			}
			if !inSet(GuardBCs, gd.BC) {
				t.Errorf("guard %q on %s is outside BC1-BC8", gd.BC, e.ID)
			}
			if strings.Contains(gd.Label, ".") {
				t.Errorf("guard %s on %s looks like a restatement, not a name: %q",
					gd.BC, e.ID, gd.Label)
			}
		}
	}
	if n < 20 {
		t.Errorf("guard count = %d, want the eight conditions cited across the gated edges", n)
	}
}

// SPEC-033 M6.4: BC4 is scoped to the plan gate.
func TestBC4AppearsOnThePlanGateOnly(t *testing.T) {
	g, err := LoadDefault()
	if err != nil {
		t.Fatal(err)
	}
	var hits []string
	for _, e := range g.Edges {
		for _, gd := range e.Guards {
			if gd.BC == "BC4" {
				hits = append(hits, e.ID)
			}
		}
	}
	if !slices.Equal(hits, []string{"plan-implement"}) {
		t.Errorf("BC4 guards sit on %v, want [plan-implement]", hits)
	}
}

func TestResolveHonoursTheEnvOverride(t *testing.T) {
	t.Setenv(EnvGraph, filepath.Join(t.TempDir(), "graph.json"))
	got, err := Resolve()
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Clean(os.Getenv(EnvGraph)); got != want {
		t.Errorf("Resolve = %q, want %q", got, want)
	}
}

func TestResolveFindsTheGraphFromASubdirectory(t *testing.T) {
	dir := t.TempDir()
	repo := filepath.Join(dir, "repo")
	target := filepath.Join(repo, filepath.FromSlash(graphRelPath))
	for _, d := range []string{filepath.Dir(target), filepath.Join(repo, "control-plane", "lifecycle")} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(target, graphBytes(t), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv(EnvGraph, "")
	t.Chdir(filepath.Join(repo, "control-plane", "lifecycle"))
	got, err := Resolve()
	if err != nil {
		t.Fatal(err)
	}
	if got != target {
		t.Errorf("Resolve = %q, want %q", got, target)
	}
}

func TestLoadNamesTheCauseOfAnUnreadableFile(t *testing.T) {
	_, err := Load(filepath.Join(t.TempDir(), "absent.json"))
	if !errors.Is(err, ErrUnreadable) {
		t.Fatalf("err = %v, want ErrUnreadable", err)
	}
	var ge *GraphError
	if !errors.As(err, &ge) {
		t.Fatalf("err %v is not a *GraphError", err)
	}
	if ge.Element != ElementGraph || ge.Field != "path" {
		t.Errorf("GraphError = %+v, want element %q field %q", ge, ElementGraph, "path")
	}
	if !strings.Contains(ge.Error(), "absent.json") {
		t.Errorf("message does not name the file: %s", ge)
	}
}

type badCase struct {
	name    string
	cause   error
	element string
	id      string
	field   string
	mutate  func(t *testing.T, root map[string]any)
}

// AC1: every malformed graph fails load with a named cause, and the error names
// the element, its id, and the field.
func TestLoadFailsWithANamedCause(t *testing.T) {
	cases := []badCase{
		{"graph name is not the contract", ErrVersion, ElementGraph, "other-graph", "graph",
			func(_ *testing.T, r map[string]any) { r["graph"] = "other-graph" }},
		{"schema_version is not 1", ErrVersion, ElementGraph, GraphName, "schema_version",
			func(_ *testing.T, r map[string]any) { r["schema_version"] = "2" }},
		{"title is empty", ErrMissingField, ElementGraph, GraphName, "title",
			func(_ *testing.T, r map[string]any) { r["title"] = "" }},
		{"vertices section is empty", ErrMissingSection, ElementGraph, GraphName, "vertices",
			func(_ *testing.T, r map[string]any) { r["vertices"] = []any{} }},
		{"boundaries section is empty", ErrMissingSection, ElementGraph, GraphName, "kill_test_boundaries",
			func(_ *testing.T, r map[string]any) { r["kill_test_boundaries"] = []any{} }},
		{"checkpoints section is absent", ErrMissingSection, ElementGraph, GraphName, "checkpoints",
			func(_ *testing.T, r map[string]any) { delete(r, "checkpoints") }},

		{"vertex id is empty", ErrMissingField, ElementVertex, "#0", "id",
			func(t *testing.T, r map[string]any) { elemOf(t, r, "vertices", "claim")["id"] = "" }},
		{"vertex id is not lowercase", ErrBadEnum, ElementVertex, "Claim", "id",
			func(t *testing.T, r map[string]any) { elemOf(t, r, "vertices", "claim")["id"] = "Claim" }},
		{"vertex id is duplicated", ErrDuplicateID, ElementVertex, "claim", "id",
			func(t *testing.T, r map[string]any) { copyElem(t, r, "vertices", "claim") }},
		{"vertex kind is unknown", ErrBadEnum, ElementVertex, "claim", "kind",
			func(t *testing.T, r map[string]any) { elemOf(t, r, "vertices", "claim")["kind"] = "state" }},
		{"vertex label is empty", ErrMissingField, ElementVertex, "claim", "label",
			func(t *testing.T, r map[string]any) { elemOf(t, r, "vertices", "claim")["label"] = "" }},
		{"vertex order is zero", ErrBadOrder, ElementVertex, "claim", "order",
			func(t *testing.T, r map[string]any) { elemOf(t, r, "vertices", "claim")["order"] = 0 }},
		{"vertex order is shared", ErrBadOrder, ElementVertex, "plan", "order",
			func(t *testing.T, r map[string]any) { elemOf(t, r, "vertices", "plan")["order"] = 1 }},
		{"vertex defined_at is empty", ErrMissingField, ElementVertex, "claim", "defined_at",
			func(t *testing.T, r map[string]any) { elemOf(t, r, "vertices", "claim")["defined_at"] = "" }},
		{"run state is not a machine state", ErrUnknownState, ElementVertex, "sleeping", "id",
			func(t *testing.T, r map[string]any) { elemOf(t, r, "vertices", "running")["id"] = "sleeping" }},
		{"halt reason is outside the journal set", ErrUnknownHaltReason, ElementVertex, "halted:not_a_reason", "id",
			func(t *testing.T, r map[string]any) {
				elemOf(t, r, "vertices", "halted:stalled")["id"] = "halted:not_a_reason"
			}},
		{"halted prefix is misspelled", ErrUnknownState, ElementVertex, "stopped:stalled", "id",
			func(t *testing.T, r map[string]any) {
				elemOf(t, r, "vertices", "halted:stalled")["id"] = "stopped:stalled"
			}},
		{"a machine state has no vertex", ErrMissingState, ElementVertex, "failed", "vertices",
			func(t *testing.T, r map[string]any) { dropElem(t, r, "vertices", "failed") }},
		{"a terminal state is not flagged", ErrBadTerminal, ElementVertex, "completed", "terminal",
			func(t *testing.T, r map[string]any) { elemOf(t, r, "vertices", "completed")["terminal"] = false }},
		{"a live state is flagged terminal", ErrBadTerminal, ElementVertex, "claimed", "terminal",
			func(t *testing.T, r map[string]any) { elemOf(t, r, "vertices", "claimed")["terminal"] = true }},

		{"edge id is empty", ErrMissingField, ElementEdge, "#0", "id",
			func(t *testing.T, r map[string]any) { elemOf(t, r, "edges", "claim-plan")["id"] = "" }},
		{"edge id is duplicated", ErrDuplicateID, ElementEdge, "claim-plan", "id",
			func(t *testing.T, r map[string]any) { copyElem(t, r, "edges", "claim-plan") }},
		{"edge from is a dangling vertex", ErrDanglingEdge, ElementEdge, "claim-plan", "from",
			func(t *testing.T, r map[string]any) { elemOf(t, r, "edges", "claim-plan")["from"] = "nope" }},
		{"edge to is a dangling vertex", ErrDanglingEdge, ElementEdge, "claim-plan", "to",
			func(t *testing.T, r map[string]any) { elemOf(t, r, "edges", "claim-plan")["to"] = "nope" }},
		{"edge label is empty", ErrMissingField, ElementEdge, "claim-plan", "label",
			func(t *testing.T, r map[string]any) { elemOf(t, r, "edges", "claim-plan")["label"] = "" }},
		{"edge defined_at is empty", ErrMissingField, ElementEdge, "claim-plan", "defined_at",
			func(t *testing.T, r map[string]any) { elemOf(t, r, "edges", "claim-plan")["defined_at"] = "" }},
		{"edge event is not a journal kind", ErrUnknownEvent, ElementEdge, "claim-plan", "event",
			func(t *testing.T, r map[string]any) { elemOf(t, r, "edges", "claim-plan")["event"] = "run_finished" }},
		{"edge kind is unknown", ErrBadEnum, ElementEdge, "claim-plan", "kind",
			func(t *testing.T, r map[string]any) { elemOf(t, r, "edges", "claim-plan")["kind"] = "flow" }},
		{"a gate edge has no gate", ErrBadGate, ElementEdge, "claim-plan", "gate",
			func(t *testing.T, r map[string]any) { elemOf(t, r, "edges", "claim-plan")["gate"] = "" }},
		{"a gate edge names an unknown gate", ErrBadGate, ElementEdge, "claim-plan", "gate",
			func(t *testing.T, r map[string]any) { elemOf(t, r, "edges", "claim-plan")["gate"] = "hall" }},
		{"a transition edge carries a gate", ErrBadGate, ElementEdge, "claim-plan", "gate",
			func(t *testing.T, r map[string]any) {
				e := elemOf(t, r, "edges", "claim-plan")
				e["kind"] = EdgeKindTransition
			}},

		{"guard id is outside BC1-BC8", ErrBadGuard, ElementGuard, "claim-plan/BC9", "bc",
			func(t *testing.T, r map[string]any) { guardOf(t, r, "claim-plan", 0)["bc"] = "BC9" }},
		{"guard id is empty", ErrBadGuard, ElementGuard, "claim-plan#0", "bc",
			func(t *testing.T, r map[string]any) { guardOf(t, r, "claim-plan", 0)["bc"] = "" }},
		{"guard label is empty", ErrMissingField, ElementGuard, "claim-plan/BC1", "label",
			func(t *testing.T, r map[string]any) { guardOf(t, r, "claim-plan", 0)["label"] = "" }},
		{"guard outcome is unknown", ErrBadGuard, ElementGuard, "claim-plan/BC1", "outcome",
			func(t *testing.T, r map[string]any) { guardOf(t, r, "claim-plan", 0)["outcome"] = "halt_and_notify" }},
		{"guard citation is prose, not a pointer", ErrBadGuard, ElementGuard, "claim-plan/BC1", "citation",
			func(t *testing.T, r map[string]any) {
				guardOf(t, r, "claim-plan", 0)["citation"] = "SPEC-033 M6 condition 1"
			}},
		{"guard citation names another spec", ErrBadGuard, ElementGuard, "claim-plan/BC1", "citation",
			func(t *testing.T, r map[string]any) {
				guardOf(t, r, "claim-plan", 0)["citation"] = "specs/core/SPEC-040-backlog-sweep.md:269"
			}},

		{"phase ladder has a gap", ErrBrokenLadder, ElementEdge, "plan-implement", "from",
			func(t *testing.T, r map[string]any) { dropElem(t, r, "edges", "plan-implement") }},
		{"the last phase has no terminal edge", ErrBrokenLadder, ElementEdge, "wrap", "to",
			func(t *testing.T, r map[string]any) { dropElem(t, r, "edges", "wrap-completed") }},
		{"phase orders are not 1..n", ErrBrokenLadder, ElementVertex, "plan", "order",
			func(t *testing.T, r map[string]any) { elemOf(t, r, "vertices", "claim")["order"] = 9 }},

		{"boundary id is duplicated", ErrDuplicateID, ElementBoundary, "claimed", "id",
			func(t *testing.T, r map[string]any) { copyElem(t, r, "kill_test_boundaries", "claimed") }},
		{"boundary phase is no vertex", ErrUnknownVertex, ElementBoundary, "claimed", "phase",
			func(t *testing.T, r map[string]any) {
				elemOf(t, r, "kill_test_boundaries", "claimed")["phase"] = "nope"
			}},
		{"boundary phase is a workflow phase", ErrUnknownVertex, ElementBoundary, "claimed", "phase",
			func(t *testing.T, r map[string]any) {
				elemOf(t, r, "kill_test_boundaries", "claimed")["phase"] = "claim"
			}},
		{"boundary event is not a journal kind", ErrUnknownEvent, ElementBoundary, "claimed", "after_event",
			func(t *testing.T, r map[string]any) {
				elemOf(t, r, "kill_test_boundaries", "claimed")["after_event"] = "run_finished"
			}},
		{"boundary label is empty", ErrMissingField, ElementBoundary, "claimed", "label",
			func(t *testing.T, r map[string]any) {
				elemOf(t, r, "kill_test_boundaries", "claimed")["label"] = ""
			}},
		{"boundary order is shared", ErrBadOrder, ElementBoundary, "running", "order",
			func(t *testing.T, r map[string]any) {
				elemOf(t, r, "kill_test_boundaries", "running")["order"] = 1
			}},

		{"checkpoint id is duplicated", ErrDuplicateID, ElementCheckpoint, "claim", "id",
			func(t *testing.T, r map[string]any) { copyElem(t, r, "checkpoints", "claim") }},
		{"checkpoint phase is no vertex", ErrUnknownVertex, ElementCheckpoint, "claim", "phase",
			func(t *testing.T, r map[string]any) { elemOf(t, r, "checkpoints", "claim")["phase"] = "nope" }},
		{"checkpoint boundary is no boundary", ErrUnknownBoundary, ElementCheckpoint, "claim", "boundary",
			func(t *testing.T, r map[string]any) { elemOf(t, r, "checkpoints", "claim")["boundary"] = "nope" }},
		{"checkpoint card_gate is no gate", ErrBadGate, ElementCheckpoint, "scope-confirm", "card_gate",
			func(t *testing.T, r map[string]any) {
				elemOf(t, r, "checkpoints", "scope-confirm")["card_gate"] = "hall-of-fame"
			}},
		{"checkpoint sets both references", ErrBadReference, ElementCheckpoint, "claim", "boundary",
			func(t *testing.T, r map[string]any) {
				elemOf(t, r, "checkpoints", "claim")["card_gate"] = "plan-approve"
			}},
		{"checkpoint sets neither reference", ErrBadReference, ElementCheckpoint, "claim", "boundary",
			func(t *testing.T, r map[string]any) {
				c := elemOf(t, r, "checkpoints", "claim")
				c["boundary"] = ""
			}},
		{"checkpoint resume_action is not an action", ErrBadEnum, ElementCheckpoint, "claim", "resume_action",
			func(t *testing.T, r map[string]any) {
				elemOf(t, r, "checkpoints", "claim")["resume_action"] = "Read The Card"
			}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			root := rootOf(t)
			tc.mutate(t, root)
			raw, err := json.Marshal(root)
			if err != nil {
				t.Fatalf("marshal the mutated graph: %v", err)
			}
			_, err = LoadBytes(raw)
			if !errors.Is(err, tc.cause) {
				t.Fatalf("err = %v, want %v", err, tc.cause)
			}
			var ge *GraphError
			if !errors.As(err, &ge) {
				t.Fatalf("err %v is not a *GraphError", err)
			}
			if ge.Element != tc.element || ge.ID != tc.id || ge.Field != tc.field {
				t.Errorf("GraphError names element=%q id=%q field=%q, want %q %q %q",
					ge.Element, ge.ID, ge.Field, tc.element, tc.id, tc.field)
			}
			if !strings.Contains(ge.Error(), tc.cause.Error()) {
				t.Errorf("message drops the cause: %s", ge)
			}
		})
	}
}

// Every cause this loader can report is reachable, and the JSON-level causes are
// reachable too.
func TestMalformedJSONIsNamed(t *testing.T) {
	cases := []struct {
		name string
		raw  string
	}{
		{"syntax error", `{"graph": "control-plane-lifecycle"`},
		{"trailing data", "{\"graph\":\"control-plane-lifecycle\",\"schema_version\":\"1\"} {}"},
		{"unknown field", string(mustAddField(t, "not_in_the_contract", true))},
		{"vertex has an unknown field", string(mustMutateVertex(t, "bogus_field", 1))},
		{"a section is the wrong JSON type", string(mustSetSection(t, "vertices", "not-a-list"))},
		{"the file is not an object", `[1,2,3]`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := LoadBytes([]byte(tc.raw))
			if !errors.Is(err, ErrMalformedJSON) {
				t.Fatalf("err = %v, want ErrMalformedJSON", err)
			}
			var ge *GraphError
			if !errors.As(err, &ge) || ge.Element != ElementGraph {
				t.Errorf("GraphError = %+v, want element %q", ge, ElementGraph)
			}
		})
	}
}

func mustAddField(t *testing.T, field string, value any) []byte {
	t.Helper()
	root := rootOf(t)
	root[field] = value
	raw, err := json.Marshal(root)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func mustMutateVertex(t *testing.T, field string, value any) []byte {
	t.Helper()
	root := rootOf(t)
	elemOf(t, root, "vertices", "claim")[field] = value
	raw, err := json.Marshal(root)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func mustSetSection(t *testing.T, section string, value any) []byte {
	t.Helper()
	root := rootOf(t)
	root[section] = value
	raw, err := json.Marshal(root)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}
