package lifecycle

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
	"github.com/cold-dark-void/claude-dev-team/control-plane/run"
)

// The named load causes (CDT-642 AC1). Every load failure carries exactly one of
// these, so a caller branches with errors.Is and the message says what to fix.
var (
	// ErrUnreadable is a graph file that cannot be found or read.
	ErrUnreadable = errors.New("lifecycle: graph file cannot be read")

	// ErrMalformedJSON is JSON this loader cannot decode: a syntax error, a
	// trailing value, a wrong JSON type, or a field the contract does not define.
	ErrMalformedJSON = errors.New("lifecycle: graph is not valid JSON")

	// ErrVersion is a graph identity this loader does not accept: the graph name
	// or the schema_version.
	ErrVersion = errors.New("lifecycle: unsupported graph identity")

	// ErrMissingSection is a required top-level section that is absent or empty.
	ErrMissingSection = errors.New("lifecycle: required section is missing")

	// ErrMissingField is a required field that is empty.
	ErrMissingField = errors.New("lifecycle: required field is empty")

	// ErrBadEnum is a value outside a closed set: an element id shape, a vertex
	// kind, an edge kind, a resume action.
	ErrBadEnum = errors.New("lifecycle: value is outside the closed set")

	// ErrDuplicateID is two elements of the same kind that share an id.
	ErrDuplicateID = errors.New("lifecycle: duplicate id")

	// ErrBadOrder is an order that is not a positive integer, or that two
	// elements of the same kind share.
	ErrBadOrder = errors.New("lifecycle: order is not a unique positive integer")

	// ErrDanglingEdge is an edge whose from or to names no vertex.
	ErrDanglingEdge = errors.New("lifecycle: edge names an unknown vertex")

	// ErrUnknownEvent is an edge or boundary event that is not a journal event
	// kind (control-plane/journal/event.go, AllKinds).
	ErrUnknownEvent = errors.New("lifecycle: event is not a journal event kind")

	// ErrUnknownState is a run-state vertex the machine cannot be in.
	ErrUnknownState = errors.New("lifecycle: run-state vertex is not a machine state")

	// ErrUnknownHaltReason is a halted:<reason> vertex whose reason is outside
	// journal.HaltReasons (CDT-643 AC6).
	ErrUnknownHaltReason = errors.New("lifecycle: halt reason is outside the journal halt set")

	// ErrMissingState is a machine state with no run-state vertex.
	ErrMissingState = errors.New("lifecycle: machine state has no vertex")

	// ErrBadTerminal is a terminal flag that disagrees with the machine's
	// terminal set.
	ErrBadTerminal = errors.New("lifecycle: terminal flag disagrees with the machine")

	// ErrBrokenLadder is a workflow-phase ladder with a gap: a missing step
	// between two consecutive phases, or no edge into a terminal state.
	ErrBrokenLadder = errors.New("lifecycle: workflow-phase ladder is broken")

	// ErrBadGate is a gate name that is not in GateNames, a gate edge with no
	// gate, or a transition edge that carries one. It is also a checkpoint
	// card_gate outside GateNames.
	ErrBadGate = errors.New("lifecycle: gate name disagrees with the element kind")

	// ErrBadGuard is a guard that is not a citation of a SPEC-033 blocking
	// condition: an id outside BC1-BC8, an outcome outside the closed set, or a
	// citation that is not a path:line inside SPEC-033 (CDT-642 AC6).
	ErrBadGuard = errors.New("lifecycle: guard is not a SPEC-033 blocking-condition citation")

	// ErrUnknownVertex is a boundary phase, checkpoint phase, or checkpoint
	// boundary that names no vertex.
	ErrUnknownVertex = errors.New("lifecycle: reference names an unknown vertex")

	// ErrUnknownBoundary is a checkpoint whose boundary is not a boundary id.
	ErrUnknownBoundary = errors.New("lifecycle: checkpoint names an unknown boundary")

	// ErrBadReference is a checkpoint that sets both boundary and card_gate, or
	// neither.
	ErrBadReference = errors.New("lifecycle: checkpoint needs exactly one of boundary and card_gate")
)

// GraphError is a load failure. It names the cause, the element kind, the
// element id, and the field, so one message is enough to fix the file
// (CDT-642 AC1).
type GraphError struct {
	Cause   error
	Element string
	ID      string
	Field   string
	Detail  string
}

func (e *GraphError) Error() string {
	var b strings.Builder
	if e.Cause != nil {
		b.WriteString(e.Cause.Error())
	}
	if e.Element != "" {
		fmt.Fprintf(&b, " [%s", e.Element)
		if e.ID != "" {
			fmt.Fprintf(&b, " %q", e.ID)
		}
		if e.Field != "" {
			fmt.Fprintf(&b, ", field %q", e.Field)
		}
		b.WriteString("]")
	}
	if e.Detail != "" {
		b.WriteString(": " + e.Detail)
	}
	return b.String()
}

// Unwrap makes errors.Is(err, ErrBadGuard) and every other named cause work.
func (e *GraphError) Unwrap() error { return e.Cause }

func graphErr(cause error, element, id, field, format string, args ...any) *GraphError {
	return &GraphError{Cause: cause, Element: element, ID: id, Field: field,
		Detail: fmt.Sprintf(format, args...)}
}

// Load reads and validates the graph at path.
func Load(path string) (*Graph, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, graphErr(ErrUnreadable, ElementGraph, "", "path", "%v", err)
	}
	return LoadBytes(raw)
}

// LoadBytes validates graph data that is already in memory.
func LoadBytes(raw []byte) (*Graph, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	var g Graph
	if err := dec.Decode(&g); err != nil {
		return nil, graphErr(ErrMalformedJSON, ElementGraph, "", "", "%v", err)
	}
	if dec.More() {
		return nil, graphErr(ErrMalformedJSON, ElementGraph, "", "",
			"trailing data after the graph object")
	}
	g.index()
	if err := g.validate(); err != nil {
		return nil, err
	}
	return &g, nil
}

// validate runs every check in section order and returns the first failure.
func (g *Graph) validate() error {
	for _, step := range []func() error{
		g.validateIdentity,
		g.validateSections,
		g.validateVertices,
		g.validateMachineStates,
		g.validateEdges,
		g.validateLadder,
		g.validateBoundaries,
		g.validateCheckpoints,
	} {
		if err := step(); err != nil {
			return err
		}
	}
	return nil
}

func (g *Graph) validateIdentity() error {
	if g.Graph != GraphName {
		return graphErr(ErrVersion, ElementGraph, g.Graph, "graph",
			"got %q, this loader accepts %q", g.Graph, GraphName)
	}
	if g.SchemaVersion != SchemaVersion {
		return graphErr(ErrVersion, ElementGraph, g.Graph, "schema_version",
			"got %q, this loader accepts %q", g.SchemaVersion, SchemaVersion)
	}
	if strings.TrimSpace(g.Title) == "" {
		return graphErr(ErrMissingField, ElementGraph, g.Graph, "title", "the graph needs a title")
	}
	return nil
}

func (g *Graph) validateSections() error {
	for _, s := range []struct {
		name  string
		count int
	}{
		{"vertices", len(g.Vertices)},
		{"edges", len(g.Edges)},
		{"kill_test_boundaries", len(g.KillTestBoundaries)},
		{"checkpoints", len(g.CheckpointPoints)},
	} {
		if s.count == 0 {
			return graphErr(ErrMissingSection, ElementGraph, g.Graph, s.name,
				"%s is empty", s.name)
		}
	}
	return nil
}

func (g *Graph) validateVertices() error {
	seen := make(map[string]bool, len(g.Vertices))
	orders := make(map[int]string, len(g.Vertices))
	for i, v := range g.Vertices {
		if v.ID == "" {
			return graphErr(ErrMissingField, ElementVertex, fmt.Sprintf("#%d", i), "id", "id is empty")
		}
		if !isElementID(v.ID) {
			return graphErr(ErrBadEnum, ElementVertex, v.ID, "id",
				"%q is not a lowercase id (letters, digits, '-', '_', ':', '.')", v.ID)
		}
		if seen[v.ID] {
			return graphErr(ErrDuplicateID, ElementVertex, v.ID, "id", "second vertex with this id")
		}
		seen[v.ID] = true
		if v.Kind != KindWorkflowPhase && v.Kind != KindRunState {
			return graphErr(ErrBadEnum, ElementVertex, v.ID, "kind",
				"got %q, want %q or %q", v.Kind, KindWorkflowPhase, KindRunState)
		}
		if strings.TrimSpace(v.Label) == "" {
			return graphErr(ErrMissingField, ElementVertex, v.ID, "label", "label is empty")
		}
		if v.Order <= 0 {
			return graphErr(ErrBadOrder, ElementVertex, v.ID, "order", "got %d, want a positive integer", v.Order)
		}
		if prev, dup := orders[v.Order]; dup {
			return graphErr(ErrBadOrder, ElementVertex, v.ID, "order",
				"same order as vertex %q", prev)
		}
		orders[v.Order] = v.ID
		if v.DefinedAt == "" {
			return graphErr(ErrMissingField, ElementVertex, v.ID, "defined_at",
				"every element names where it is defined")
		}
	}
	return nil
}

// machineStates is the closed set of run-state names the machine can hold, read
// off the code it describes: the journal status names plus the named halt states
// of run.RetryBudgets (CDT-643 AC6). The empty status ("new") is excluded: a run
// with no events has no position to name in the graph.
func machineStates() []string {
	set := map[string]bool{
		string(journal.StatusClaimed):   true,
		string(journal.StatusRunning):   true,
		string(journal.StatusCompleted): true,
		string(journal.StatusFailed):    true,
	}
	for reason := range run.RetryBudgets {
		set[string(journal.StatusHalted)+":"+reason] = true
	}
	out := make([]string, 0, len(set))
	for name := range set {
		out = append(out, name)
	}
	sort.Strings(out)
	return out
}

func machineTerminal(name string) bool {
	return name == string(journal.StatusCompleted) || name == string(journal.StatusFailed)
}

// validateMachineStates is the cross-check against control-plane/run and
// control-plane/journal: a run-state vertex the machine cannot be in, a
// halted:<reason> outside journal.HaltReasons, a machine state with no vertex,
// and a terminal flag that disagrees all fail the load.
func (g *Graph) validateMachineStates() error {
	states := machineStates()
	allowed := make(map[string]bool, len(states))
	for _, name := range states {
		allowed[name] = true
	}
	for _, v := range g.Vertices {
		if v.Kind != KindRunState {
			continue
		}
		if state, reason, isHalt := strings.Cut(v.ID, ":"); isHalt {
			if state != string(journal.StatusHalted) {
				return graphErr(ErrUnknownState, ElementVertex, v.ID, "id",
					"%q is not a machine state; only %q carries a reason",
					v.ID, string(journal.StatusHalted))
			}
			if !journal.ValidHaltReason(reason) {
				return graphErr(ErrUnknownHaltReason, ElementVertex, v.ID, "id",
					"halt reason %q is not one of %s", reason, strings.Join(journal.HaltReasons, ", "))
			}
		}
		if !allowed[v.ID] {
			return graphErr(ErrUnknownState, ElementVertex, v.ID, "id",
				"the run machine cannot be in %q; its states are %s", v.ID, strings.Join(states, ", "))
		}
		if v.Terminal != machineTerminal(v.ID) {
			return graphErr(ErrBadTerminal, ElementVertex, v.ID, "terminal",
				"got %v, the machine says %v", v.Terminal, machineTerminal(v.ID))
		}
	}
	for _, name := range states {
		if _, ok := g.byID[name]; !ok {
			return graphErr(ErrMissingState, ElementVertex, name, "vertices",
				"the machine can be in %q and the graph has no vertex for it", name)
		}
	}
	return nil
}

func (g *Graph) validateEdges() error {
	seen := make(map[string]bool, len(g.Edges))
	for i, e := range g.Edges {
		id := e.ID
		if id == "" {
			return graphErr(ErrMissingField, ElementEdge, fmt.Sprintf("#%d", i), "id", "id is empty")
		}
		if !isElementID(id) {
			return graphErr(ErrBadEnum, ElementEdge, id, "id",
				"%q is not a lowercase id (letters, digits, '-', '_', ':', '.')", id)
		}
		if seen[id] {
			return graphErr(ErrDuplicateID, ElementEdge, id, "id", "second edge with this id")
		}
		seen[id] = true
		if _, ok := g.byID[e.From]; !ok {
			return graphErr(ErrDanglingEdge, ElementEdge, id, "from", "no vertex %q", e.From)
		}
		if _, ok := g.byID[e.To]; !ok {
			return graphErr(ErrDanglingEdge, ElementEdge, id, "to", "no vertex %q", e.To)
		}
		if strings.TrimSpace(e.Label) == "" {
			return graphErr(ErrMissingField, ElementEdge, id, "label", "label is empty")
		}
		if e.DefinedAt == "" {
			return graphErr(ErrMissingField, ElementEdge, id, "defined_at",
				"every element names where it is defined")
		}
		if e.Event != "" && !isJournalKind(e.Event) {
			return graphErr(ErrUnknownEvent, ElementEdge, id, "event",
				"%q is not a journal event kind", e.Event)
		}
		switch e.Kind {
		case EdgeKindGate:
			if !inSet(GateNames, e.Gate) {
				return graphErr(ErrBadGate, ElementEdge, id, "gate",
					"a gate edge needs one of %s, got %q", strings.Join(GateNames, ", "), e.Gate)
			}
		case EdgeKindTransition:
			if e.Gate != "" {
				return graphErr(ErrBadGate, ElementEdge, id, "gate",
					"a transition edge carries no gate, got %q", e.Gate)
			}
		default:
			return graphErr(ErrBadEnum, ElementEdge, id, "kind",
				"got %q, want %q or %q", e.Kind, EdgeKindGate, EdgeKindTransition)
		}
		if err := validateGuards(id, e.Guards); err != nil {
			return err
		}
	}
	return nil
}

// validateGuards proves each guard is a pointer into SPEC-033 and not a second
// copy of the policy (CDT-642 AC6, SPEC-033 M6).
func validateGuards(edgeID string, guards []Guard) error {
	for i, gd := range guards {
		gid := edgeID + "/" + gd.BC
		if gd.BC == "" {
			gid = fmt.Sprintf("%s#%d", edgeID, i)
		}
		if !inSet(GuardBCs, gd.BC) {
			return graphErr(ErrBadGuard, ElementGuard, gid, "bc",
				"got %q, want one of %s", gd.BC, strings.Join(GuardBCs, ", "))
		}
		if strings.TrimSpace(gd.Label) == "" {
			return graphErr(ErrMissingField, ElementGuard, gid, "label",
				"the condition name is empty")
		}
		if gd.Outcome != OutcomeHalt && gd.Outcome != OutcomeReroute {
			return graphErr(ErrBadGuard, ElementGuard, gid, "outcome",
				"got %q, want %q or %q", gd.Outcome, OutcomeHalt, OutcomeReroute)
		}
		if !isSpec033Citation(gd.Citation) {
			return graphErr(ErrBadGuard, ElementGuard, gid, "citation",
				"got %q, want %s:<line> — cite SPEC-033, do not restate it",
				gd.Citation, Spec033)
		}
	}
	return nil
}

// validateLadder proves the workflow phases form one unbroken ladder: orders
// 1..n, an edge from each phase to the next, and an edge from the last phase to
// a terminal run state.
func (g *Graph) validateLadder() error {
	phases := g.Phases()
	for i, p := range phases {
		if p.Order != i+1 {
			return graphErr(ErrBrokenLadder, ElementVertex, p.ID, "order",
				"workflow-phase orders must be 1..n, got %d at position %d", p.Order, i+1)
		}
	}
	last := phases[len(phases)-1]
	for i := 0; i < len(phases)-1; i++ {
		if !g.hasEdge(phases[i].ID, phases[i+1].ID) {
			return graphErr(ErrBrokenLadder, ElementEdge, phases[i].ID+"-"+phases[i+1].ID, "from",
				"no edge from phase %q to phase %q", phases[i].ID, phases[i+1].ID)
		}
	}
	if !g.hasEdgeToTerminal(last.ID) {
		return graphErr(ErrBrokenLadder, ElementEdge, last.ID, "to",
			"the last phase %q has no edge to a terminal run state", last.ID)
	}
	return nil
}

func (g *Graph) hasEdge(from, to string) bool {
	for _, e := range g.Edges {
		if e.From == from && e.To == to {
			return true
		}
	}
	return false
}

func (g *Graph) hasEdgeToTerminal(from string) bool {
	for _, e := range g.Edges {
		if e.From != from {
			continue
		}
		if v, ok := g.byID[e.To]; ok && v.Kind == KindRunState && v.Terminal {
			return true
		}
	}
	return false
}

func (g *Graph) validateBoundaries() error {
	seen := make(map[string]bool, len(g.KillTestBoundaries))
	orders := make(map[int]string, len(g.KillTestBoundaries))
	for i, b := range g.KillTestBoundaries {
		id := b.ID
		if id == "" {
			return graphErr(ErrMissingField, ElementBoundary, fmt.Sprintf("#%d", i), "id", "id is empty")
		}
		if !isElementID(id) {
			return graphErr(ErrBadEnum, ElementBoundary, id, "id",
				"%q is not a lowercase id (letters, digits, '-', '_', ':', '.')", id)
		}
		if seen[id] {
			return graphErr(ErrDuplicateID, ElementBoundary, id, "id", "second boundary with this id")
		}
		seen[id] = true
		v, ok := g.byID[b.Phase]
		if !ok {
			return graphErr(ErrUnknownVertex, ElementBoundary, id, "phase", "no vertex %q", b.Phase)
		}
		if v.Kind != KindRunState {
			return graphErr(ErrUnknownVertex, ElementBoundary, id, "phase",
				"%q is %s; a kill boundary lands in a run state", b.Phase, v.Kind)
		}
		if b.AfterEvent != "" && !isJournalKind(b.AfterEvent) {
			return graphErr(ErrUnknownEvent, ElementBoundary, id, "after_event",
				"%q is not a journal event kind", b.AfterEvent)
		}
		if strings.TrimSpace(b.Label) == "" {
			return graphErr(ErrMissingField, ElementBoundary, id, "label", "label is empty")
		}
		if b.DefinedAt == "" {
			return graphErr(ErrMissingField, ElementBoundary, id, "defined_at",
				"every element names where it is defined")
		}
		if b.Order <= 0 {
			return graphErr(ErrBadOrder, ElementBoundary, id, "order",
				"got %d, want a positive integer", b.Order)
		}
		if prev, dup := orders[b.Order]; dup {
			return graphErr(ErrBadOrder, ElementBoundary, id, "order",
				"same order as boundary %q", prev)
		}
		orders[b.Order] = id
	}
	return nil
}

func (g *Graph) validateCheckpoints() error {
	seen := make(map[string]bool, len(g.CheckpointPoints))
	boundaries := make(map[string]bool, len(g.KillTestBoundaries))
	for _, b := range g.KillTestBoundaries {
		boundaries[b.ID] = true
	}
	for i, c := range g.CheckpointPoints {
		id := c.ID
		if id == "" {
			return graphErr(ErrMissingField, ElementCheckpoint, fmt.Sprintf("#%d", i), "id", "id is empty")
		}
		if !isElementID(id) {
			return graphErr(ErrBadEnum, ElementCheckpoint, id, "id",
				"%q is not a lowercase id (letters, digits, '-', '_', ':', '.')", id)
		}
		if seen[id] {
			return graphErr(ErrDuplicateID, ElementCheckpoint, id, "id", "second checkpoint with this id")
		}
		seen[id] = true
		if _, ok := g.byID[c.Phase]; !ok {
			return graphErr(ErrUnknownVertex, ElementCheckpoint, id, "phase", "no vertex %q", c.Phase)
		}
		if (c.Boundary == "") == (c.CardGate == "") {
			return graphErr(ErrBadReference, ElementCheckpoint, id, "boundary",
				"set exactly one of boundary and card_gate, got boundary=%q card_gate=%q",
				c.Boundary, c.CardGate)
		}
		if c.Boundary != "" && !boundaries[c.Boundary] {
			return graphErr(ErrUnknownBoundary, ElementCheckpoint, id, "boundary",
				"no boundary %q", c.Boundary)
		}
		if c.CardGate != "" && !inSet(GateNames, c.CardGate) {
			return graphErr(ErrBadGate, ElementCheckpoint, id, "card_gate",
				"got %q, want one of %s", c.CardGate, strings.Join(GateNames, ", "))
		}
		if strings.TrimSpace(c.Label) == "" {
			return graphErr(ErrMissingField, ElementCheckpoint, id, "label", "label is empty")
		}
		if !isKebab(c.ResumeAction) {
			return graphErr(ErrBadEnum, ElementCheckpoint, id, "resume_action",
				"got %q, want a kebab-case action such as read-card", c.ResumeAction)
		}
		if c.DefinedAt == "" {
			return graphErr(ErrMissingField, ElementCheckpoint, id, "defined_at",
				"every element names where it is defined")
		}
	}
	return nil
}

func isJournalKind(s string) bool {
	for _, k := range journal.AllKinds {
		if string(k) == s {
			return true
		}
	}
	return false
}

func inSet(set []string, v string) bool {
	for _, s := range set {
		if s == v {
			return true
		}
	}
	return false
}

// isElementID accepts a lowercase id: letters, digits, and '-', '_', ':', '.'
// after the first character.
func isElementID(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9':
		case i > 0 && (c == '-' || c == '_' || c == ':' || c == '.'):
		default:
			return false
		}
	}
	return true
}

func isKebab(s string) bool {
	if s == "" {
		return false
	}
	prevDash := true
	for i := 0; i < len(s); i++ {
		c := s[i]
		lower := c >= 'a' && c <= 'z'
		digit := c >= '0' && c <= '9'
		switch {
		case lower || digit:
			prevDash = false
		case c == '-':
			if prevDash {
				return false
			}
			prevDash = true
		default:
			return false
		}
	}
	return !prevDash
}

// isSpec033Citation reports whether s is SPEC-033 plus a line number.
func isSpec033Citation(s string) bool {
	rest, ok := strings.CutPrefix(s, Spec033+":")
	if !ok || rest == "" {
		return false
	}
	for i := 0; i < len(rest); i++ {
		if rest[i] < '0' || rest[i] > '9' {
			return false
		}
	}
	return true
}
