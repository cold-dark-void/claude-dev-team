package lifecycle

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

// GraphName is the graph the loader accepts, and SchemaVersion is the version of
// the file shape. A file that names anything else is not this contract
// (ErrVersion).
const (
	GraphName     = "control-plane-lifecycle"
	SchemaVersion = "1"
)

// EnvGraph overrides the graph path outright — the DEVTEAM_* pattern of
// control-plane/journal/open.go.
const EnvGraph = "DEVTEAM_LIFECYCLE_GRAPH"

// graphRelPath is the committed home of the graph data inside the repository.
const graphRelPath = "docs/internal/control-plane/lifecycle-graph.json"

// Vertex kinds.
const (
	KindWorkflowPhase = "workflow-phase"
	KindRunState      = "run-state"
)

// Edge kinds. A gate edge is answered by a decision-card; a transition edge is
// not.
const (
	EdgeKindGate       = "gate"
	EdgeKindTransition = "transition"
)

// Guard outcomes (SPEC-033 M6). "halt" lands the run on a named halt state and
// "reroute" decomposes the ticket; SPEC-033 owns both semantics, so the graph
// cites them and never restates them (specs/core/SPEC-033-autopilot-policy.md:229).
const (
	OutcomeHalt    = "halt"
	OutcomeReroute = "reroute"
)

// GateNames is the closed set of gate names
// (specs/core/SPEC-033-autopilot-policy.md:117).
var GateNames = []string{"scope-confirm", "plan-approve", "ship-choice"}

// GuardBCs is the closed blocking-condition set, in evaluation order
// (SPEC-033 M6, specs/core/SPEC-033-autopilot-policy.md:229).
var GuardBCs = []string{"BC1", "BC2", "BC3", "BC4", "BC5", "BC6", "BC7", "BC8"}

// Spec033 is the file every guard must cite. SPEC-033 stays the gate policy
// (CDT-642 AC6): a guard is a pointer into it, never a second copy of it.
const Spec033 = "specs/core/SPEC-033-autopilot-policy.md"

// Element names carried by GraphError.
const (
	ElementGraph      = "graph"
	ElementVertex     = "vertex"
	ElementEdge       = "edge"
	ElementGuard      = "guard"
	ElementBoundary   = "boundary"
	ElementCheckpoint = "checkpoint"
)

// Guard is one blocking condition attached to an edge: the condition id, its
// name, what it does at this edge, and where it is defined. Citation is a
// path:line inside Spec033.
type Guard struct {
	BC       string `json:"bc"`
	Label    string `json:"label"`
	Outcome  string `json:"outcome"`
	Citation string `json:"citation"`
}

// Vertex is one node of the graph: a workflow phase (KindWorkflowPhase) or a run
// state (KindRunState).
type Vertex struct {
	ID        string `json:"id"`
	Kind      string `json:"kind"`
	Label     string `json:"label"`
	Order     int    `json:"order"`
	Terminal  bool   `json:"terminal"`
	DefinedAt string `json:"defined_at"`
	Source    string `json:"source"`
	Notes     string `json:"notes"`
}

// Edge is one guarded transition. Event is the journal event kind that fires it,
// or "" when the step writes no journal row of its own. Gate is set on a
// EdgeKindGate edge only.
type Edge struct {
	ID        string  `json:"id"`
	From      string  `json:"from"`
	To        string  `json:"to"`
	Event     string  `json:"event"`
	Kind      string  `json:"kind"`
	Gate      string  `json:"gate"`
	Label     string  `json:"label"`
	Guards    []Guard `json:"guards"`
	DefinedAt string  `json:"defined_at"`
	Source    string  `json:"source"`
	Notes     string  `json:"notes"`
}

// Boundary is one kill-test boundary: the point just after AfterEvent commits,
// in the run state Phase. AfterEvent is "" for the crash window that writes no
// journal row (control-plane/killtest, PhaseEffect).
type Boundary struct {
	ID         string `json:"id"`
	Phase      string `json:"phase"`
	AfterEvent string `json:"after_event"`
	Label      string `json:"label"`
	Order      int    `json:"order"`
	DefinedAt  string `json:"defined_at"`
	Source     string `json:"source"`
	Notes      string `json:"notes"`
}

// Checkpoint is one point a run resumes from. Boundary names a Boundary id, and
// CardGate names a gate whose decision-card the recovery reads. Exactly one of
// the two is set.
type Checkpoint struct {
	ID           string `json:"id"`
	Phase        string `json:"phase"`
	Boundary     string `json:"boundary"`
	CardGate     string `json:"card_gate"`
	Label        string `json:"label"`
	ResumeAction string `json:"resume_action"`
	DefinedAt    string `json:"defined_at"`
	Source       string `json:"source"`
	Notes        string `json:"notes"`
}

// Graph is the decoded, validated lifecycle graph. CheckpointPoints is the
// decoded section; read it through Checkpoints() outside this package.
type Graph struct {
	Graph              string       `json:"graph"`
	SchemaVersion      string       `json:"schema_version"`
	Title              string       `json:"title"`
	Notes              string       `json:"notes"`
	Vertices           []Vertex     `json:"vertices"`
	Edges              []Edge       `json:"edges"`
	KillTestBoundaries []Boundary   `json:"kill_test_boundaries"`
	CheckpointPoints   []Checkpoint `json:"checkpoints"`

	byID        map[string]Vertex
	edgesByFrom map[[2]string][]Edge
}

// The lookup causes EdgeGuard reports. These are not load causes: the graph
// loads cleanly with a shared (from, event) pair, because the lifecycle graph
// legitimately fans one journal event out to several target states.
var (
	// ErrNoSuchEdge is a (phase, event) pair with no edge at all.
	ErrNoSuchEdge = errors.New("lifecycle: no edge leaves the vertex on this event")

	// ErrAmbiguousEdge is a (phase, event) pair that more than one edge shares.
	// The pair names no single step, so the accessor refuses rather than pick.
	ErrAmbiguousEdge = errors.New("lifecycle: this event leaves the vertex on more than one edge")
)

// EdgeLookupError is the typed failure of a (phase, event) lookup. Candidates
// lists the ids of every edge that shares the pair, in graph order, so the
// caller can name the step it meant. Candidates is empty for ErrNoSuchEdge.
type EdgeLookupError struct {
	Cause      error
	Phase      string
	Event      string
	Candidates []string
}

func (e *EdgeLookupError) Error() string {
	var b strings.Builder
	if e.Cause != nil {
		b.WriteString(e.Cause.Error())
	}
	fmt.Fprintf(&b, " (from %q, event %q)", e.Phase, e.Event)
	if len(e.Candidates) > 0 {
		fmt.Fprintf(&b, "; candidate edges: %s", strings.Join(e.Candidates, ", "))
	}
	return b.String()
}

// Unwrap makes errors.Is(err, ErrAmbiguousEdge) and ErrNoSuchEdge work.
func (e *EdgeLookupError) Unwrap() error { return e.Cause }

// VertexByID returns the vertex with this id.
func (g *Graph) VertexByID(id string) (Vertex, bool) {
	v, ok := g.byID[id]
	return v, ok
}

// Phases returns the workflow-phase vertices in ladder order.
func (g *Graph) Phases() []Vertex { return g.verticesOfKind(KindWorkflowPhase) }

// RunStates returns the run-state vertices in graph order.
func (g *Graph) RunStates() []Vertex { return g.verticesOfKind(KindRunState) }

func (g *Graph) verticesOfKind(kind string) []Vertex {
	var out []Vertex
	for _, v := range g.Vertices {
		if v.Kind == kind {
			out = append(out, v)
		}
	}
	slices.SortFunc(out, func(a, b Vertex) int { return a.Order - b.Order })
	return out
}

// BoundaryList is the kill-test boundary list, in lifecycle order. It is the
// single source the kill test iterates (CDT-642 AC2); the returned slice is a
// copy, so a caller cannot edit the graph.
func (g *Graph) BoundaryList() []Boundary {
	out := append([]Boundary(nil), g.KillTestBoundaries...)
	slices.SortFunc(out, func(a, b Boundary) int { return a.Order - b.Order })
	return out
}

// Checkpoints returns the checkpoint points in graph order (CDT-642 AC2). The
// returned slice is a copy.
func (g *Graph) Checkpoints() []Checkpoint {
	return append([]Checkpoint(nil), g.CheckpointPoints...)
}

// EdgeGuard returns the single edge that leaves phase on the journal event kind
// event. An event of "" matches the edge that writes no journal row.
//
// A (phase, event) pair names a step only when one edge carries it. The
// committed graph fans run_halted out to one halt state per reason, so
// EdgeGuard("running", "run_halted") and EdgeGuard("claimed", "run_halted") are
// ambiguous: they return an *EdgeLookupError wrapping ErrAmbiguousEdge that names
// every candidate edge id. A pair with no edge wraps ErrNoSuchEdge. Read the
// guards of a whole pair with Guards; to name one step, match its target state
// against Edge.To.
func (g *Graph) EdgeGuard(phase, event string) (Edge, error) {
	group := g.edgesByFrom[[2]string{phase, event}]
	switch len(group) {
	case 0:
		return Edge{}, &EdgeLookupError{Cause: ErrNoSuchEdge, Phase: phase, Event: event}
	case 1:
		return group[0], nil
	default:
		return Edge{}, &EdgeLookupError{Cause: ErrAmbiguousEdge, Phase: phase, Event: event,
			Candidates: edgeIDs(group)}
	}
}

// Guards returns the blocking conditions of every edge that leaves phase on
// event, in graph order, and reports whether the pair has any edge. The guards of
// a fan-out pair are concatenated, so the guard of one target state is reachable
// through the pair (running + run_halted carries the BC6 guard of
// running-halted-budget_exhausted). The returned slice is a copy.
func (g *Graph) Guards(phase, event string) ([]Guard, bool) {
	group := g.edgesByFrom[[2]string{phase, event}]
	if len(group) == 0 {
		return nil, false
	}
	var out []Guard
	for _, e := range group {
		out = append(out, e.Guards...)
	}
	return out, true
}

// IsTerminal reports whether the named run state is terminal for the machine.
func (g *Graph) IsTerminal(name string) bool {
	v, ok := g.byID[name]
	return ok && v.Terminal
}

// index builds the lookup maps. Load calls it once, after validation.
func (g *Graph) index() {
	g.byID = make(map[string]Vertex, len(g.Vertices))
	for _, v := range g.Vertices {
		g.byID[v.ID] = v
	}
	// The index carries the full (from, event, to) triple: the key is the pair
	// and the group keeps one entry per target, in graph order. Two edges that
	// share (from, event) — run_halted fans out to a state per halt reason —
	// therefore never overwrite each other.
	g.edgesByFrom = make(map[[2]string][]Edge, len(g.Edges))
	for _, e := range g.Edges {
		k := [2]string{e.From, e.Event}
		g.edgesByFrom[k] = append(g.edgesByFrom[k], e)
	}
}

// edgeIDs returns the ids of edges in graph order.
func edgeIDs(edges []Edge) []string {
	out := make([]string, 0, len(edges))
	for _, e := range edges {
		out = append(out, e.ID)
	}
	return out
}

// Resolve returns the graph path: $DEVTEAM_LIFECYCLE_GRAPH when set, else the
// first docs/internal/control-plane/lifecycle-graph.json found at or above the
// working directory.
//
// The walk-up search is deliberate. journal.MROOT anchors state at the parent of
// the git common dir, and a linked worktree inside a container points outside
// that container; the graph is committed product data, so the search follows the
// checkout instead.
func Resolve() (string, error) {
	if p := strings.TrimSpace(os.Getenv(EnvGraph)); p != "" {
		abs, err := filepath.Abs(p)
		if err != nil {
			return "", &GraphError{Cause: ErrUnreadable, Element: ElementGraph,
				Field: "path", Detail: err.Error()}
		}
		return filepath.Clean(abs), nil
	}
	start, err := os.Getwd()
	if err != nil {
		return "", &GraphError{Cause: ErrUnreadable, Element: ElementGraph,
			Field: "path", Detail: err.Error()}
	}
	dir := start
	for {
		cand := filepath.Join(dir, graphRelPath)
		if fi, err := os.Stat(cand); err == nil && !fi.IsDir() {
			return cand, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return "", &GraphError{Cause: ErrUnreadable, Element: ElementGraph, Field: "path",
		Detail: "no " + graphRelPath + " at or above " + start}
}

// LoadDefault resolves the graph path and loads it.
func LoadDefault() (*Graph, error) {
	path, err := Resolve()
	if err != nil {
		return nil, err
	}
	return Load(path)
}
