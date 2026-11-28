package hostadapter

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/cold-dark-void/claude-dev-team/control-plane/agent"
	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
)

// NodeAgent is the node agent contract the adapter calls — the four verbs
// start, stop, status, and steer (CDT-644 AC1). The adapter realizes the
// host layer only through this contract: it never execs a host CLI, never
// opens a host session, and never touches Docker (AC1).
//
// Supervise carries one extra argument next to the agent's own start verb:
// sessionOut, the sink the runner's session output is drained into. The
// adapter reads the session id out of that stream at start (AC2); the agent
// itself does not parse host output.
type NodeAgent interface {
	Supervise(ctx context.Context, eng *journal.Engine, req agent.StartRequest, sessionOut io.Writer) error
	Stop(ctx context.Context, eng *journal.Engine, runID string, grace time.Duration) error
	Steer(ctx context.Context, eng *journal.Engine, runID, message string) error
	Status(ctx context.Context, eng *journal.Engine, runID string) (agent.StatusReport, error)
}

// Client binds the seam to the node agent's *agent.Agent. Every verb is the
// agent's own; Supervise additionally selects the agent's native runner and
// points its output drain at sessionOut. One Client drives one run at a
// time, the way cmd/node-agent runs the start verb in its foreground.
type Client struct{ A *agent.Agent }

// NewClient returns the seam over one node agent.
func NewClient(a *agent.Agent) *Client { return &Client{A: a} }

// Supervise is the agent's start verb with the native runner selected for
// this call: one host-CLI process on the node's own OS, spawned and
// supervised by the agent (CDT-644 AC2). The session output is the runner's
// stdout; the adapter scans it for the session id.
func (c *Client) Supervise(ctx context.Context, eng *journal.Engine,
	req agent.StartRequest, sessionOut io.Writer) error {
	c.A.Runner = agent.Native{Stdout: sessionOut}
	return c.A.Supervise(ctx, eng, req)
}

// Stop is the agent's stop verb, unchanged.
func (c *Client) Stop(ctx context.Context, eng *journal.Engine,
	runID string, grace time.Duration) error {
	return c.A.Stop(ctx, eng, runID, grace)
}

// Steer is the agent's steer verb, unchanged: the frame the adapter encoded
// is the message, and the delivery stays the agent's step-boundary mechanic.
func (c *Client) Steer(ctx context.Context, eng *journal.Engine,
	runID, message string) error {
	return c.A.Steer(ctx, eng, runID, message)
}

// Status is the agent's status verb, unchanged.
func (c *Client) Status(ctx context.Context, eng *journal.Engine,
	runID string) (agent.StatusReport, error) {
	return c.A.Status(ctx, eng, runID)
}

// Adapter is the host adapter of control plane Option C+ (CDT-626): the
// per-host driver that starts, resumes, steers, and observes a host session
// (CONTEXT.md § Host adapter), for the hosts and paths the capability matrix
// names.
type Adapter struct {
	// Agent is the node agent every host action goes through (AC1).
	Agent NodeAgent

	// Now is the clock, passed through to the agent when it is set.
	Now func() time.Time

	// runs is the per-run record of this adapter process: the host, the
	// session-id capture, and the steer request-id counter. The mutex
	// serializes the map and the counters.
	mu    sync.Mutex
	runs  map[string]*runRecord
	seqMu sync.Mutex
	seqs  map[string]int
}

// runRecord is one run the adapter started: its host and its session-id
// capture.
type runRecord struct {
	Host Host
	Cap  *Capture
}

// New returns an adapter over one node agent.
func New(a *agent.Agent) *Adapter {
	return &Adapter{Agent: NewClient(a), runs: map[string]*runRecord{}, seqs: map[string]int{}}
}

// StartRequest is one start verb for one host.
type StartRequest struct {
	RunID    string
	Ticket   string
	Workflow string
	Model    string
	Host     Host

	// Credentials are the env-var injections the run carries into the
	// runner's environment. Each resolves against the B7 proven-name table
	// before anything is written: an unproven name refuses the start
	// fail-closed (AC5/B7).
	Credentials []InjectCredential

	// RunCaps are the operator's per-run budget caps (SPEC-046 M5). They
	// ride the run-scoped non-credential channel beside the credential
	// entries — into that run's runner environment only, never the premise
	// command line, the chiefd unit environment, or another run's
	// environment. Zero means unset.
	RunCaps RunCaps

	// Premise is the run's work premise — the ticket record's text — which
	// the node agent delivers as the session's first turn (SPEC-044
	// CDT-665). The adapter renders it through the host's first-turn frame;
	// a host with no steerable route refuses the start (AC5). Empty means
	// this start has no premise to deliver.
	Premise string
}

// Start begins one host session for a run. The matrix gates the route
// first — a host × headless-streaming cell that is not supported returns the
// cell verdict as a refusal (AC6) and no journal row is written — then the
// adapter hands the host's launch argv to the node agent's start verb. The
// returned Capture records the session id as the host names it in the
// session output (AC2: captured at start). A start that carries a Premise
// gates the host's first-turn frame as well, and every start carries the
// renderer the host's spec names (SPEC-044 CDT-665 M16/AC5).
func (a *Adapter) Start(ctx context.Context, eng *journal.Engine,
	req StartRequest) (*Capture, error) {
	sp, err := a.launchOf(req.Host, req.Credentials, req.RunCaps)
	if err != nil {
		return nil, err
	}
	// CDT-665 AC1/AC5: the renderer travels with the spawn on the host's
	// spec, so a takeover re-spawn with no premise text of its own can still
	// perform the run's pending premise row. A start that carries a premise
	// is matrix-gated first, so a host with no steerable route refuses the
	// start and writes no row.
	premiseFrame, err := premiseFrameOf(req.Host, req.Premise)
	if err != nil {
		return nil, err
	}
	cap := NewCapture(req.Host)
	err = a.supervise(ctx, eng, req.RunID, req.Host, cap, agent.StartRequest{
		RunID: req.RunID, Ticket: req.Ticket, Workflow: req.Workflow,
		Model: req.Model, Command: sp.Command, Args: sp.Args, Env: sp.Env,
		Premise: req.Premise, PremiseFrame: premiseFrame,
		Handshake: handshakeFramesOf(req.Host),
		// SPEC-046 M7: the caps that ride this runner's environment are
		// journaled on the same start, so a retry and a takeover re-spawn
		// read the run's own values back from the journal.
		WallclockCapS: req.RunCaps.WallclockCapS,
		IterationCapS: req.RunCaps.IterationCapS,
	})
	return cap, err
}

// ResumeRequest is one resume of a dead host session along the matrix AC-4
// named path of its host (AC2).
type ResumeRequest struct {
	RunID    string
	Ticket   string
	Workflow string
	Model    string
	Host     Host
	// SessionID is the id captured at start. The by-id resume path needs
	// it; the Continue path (newest session in the working directory)
	// does not.
	SessionID string
	// Continue resumes the newest session in the cwd (Grok `-c/--continue`,
	// omp `-c/--continue`) instead of by id.
	Continue bool
	// Fork resumes into a new session id (Grok `--fork-session`, riding the
	// resume flag).
	Fork bool
	// OperatorResume passes the chief's operator-resume switch through to the
	// node agent (SPEC-045 M5): the supervision gate then resumes the run's
	// current halt reason. It adds no verb, no capability, and no event kind.
	OperatorResume bool

	// Credentials is C8 wiring scope (review N5): a resumed session whose
	// host CLI reads an env-var credential needs the proven-name injection
	// re-applied on the re-spawn. No encoded host needs it today — the omp
	// rows read the auth store, and the others read their own login files —
	// so Resume does not carry the field yet; wire it when one does.
}

// Resume re-spawns the host session of a dead run along its AC-4 named path.
// The invocation is the host's resume command — a distinct headless route
// per host, not the steerable launch (review B1: `grok agent stdio` accepts
// no resume flags). The machine side is the existing run_resumed path: the
// node agent's recovery resumes a halted:stalled run and re-spawns the
// runner as the next attempt (the CDT-626 adoption policy), so the adapter
// adds no run state and no event kind — no lifecycle-graph change. C8
// wiring scope: on a halted run this verb must ride the machine's
// run_resumed recovery (the takeover re-spawn), not a fresh claim; the
// dead-run path lands with the C8 run orchestration. The matrix gates the
// route first: an unsupported resume cell returns the verdict as a refusal
// (AC6), a resume by id without the captured session id refuses with
// ErrNoSessionID, and a request setting both Continue and Fork refuses with
// ErrResumeAmbiguous.
func (a *Adapter) Resume(ctx context.Context, eng *journal.Engine,
	req ResumeRequest) (*Capture, error) {
	if req.Continue && req.Fork {
		return nil, fmt.Errorf("%w: continue and fork are mutually exclusive",
			ErrResumeAmbiguous)
	}
	if err := route(req.Host, CapResume); err != nil {
		return nil, err
	}
	sp, err := specOf(req.Host)
	if err != nil {
		return nil, err
	}
	rs := sp.Resume
	var args []string
	switch {
	case req.Continue && rs.Continue != nil:
		args = append([]string(nil), rs.Continue...)
	case req.Continue:
		return nil, refusalOf(req.Host, CapResume,
			fmt.Sprintf("%s names no steerable continue-resume invocation; the AC-4 row names the flag only parenthetically on its interactive route", req.Host))
	case req.Fork && rs.Fork != nil:
		if req.SessionID == "" {
			return nil, ErrNoSessionID
		}
		args = rs.Fork(req.SessionID)
	case req.Fork:
		return nil, refusalOf(req.Host, CapResume,
			fmt.Sprintf("%s names no fork-resume path in the matrix", req.Host))
	default:
		if req.SessionID == "" {
			return nil, ErrNoSessionID
		}
		args = rs.ByID(req.SessionID)
	}
	cap := NewCapture(req.Host)
	// CDT-665 M16: the resume carries no premise text — the resumed session
	// continues a session that already opened — yet it carries the host's
	// first-turn renderer, because this verb is also a takeover re-adoption
	// (SPEC-044 AC3/CDT-661): a premise row the dead stint left PENDING is
	// performed by the re-spawn, from the text that row carries.
	premiseFrame, err := premiseFrameOf(req.Host, "")
	if err != nil {
		return nil, err
	}
	err = a.supervise(ctx, eng, req.RunID, req.Host, cap, agent.StartRequest{
		RunID: req.RunID, Ticket: req.Ticket, Workflow: req.Workflow,
		Model: req.Model, Command: rs.Command, Args: args,
		PremiseFrame: premiseFrame, OperatorResume: req.OperatorResume,
		// The re-spawn's child is a new agent on the host's transport, so the
		// handshake rides it too (SPEC-044 CDT-679 AC1).
		Handshake: handshakeFramesOf(req.Host),
	})
	return cap, err
}

// ResumeRoute reports whether the matrix names a supported resume cell for a
// host (CDT-661 AC4). It is the pre-check a caller runs before it asks for a
// resume — the takeover's adoption path uses it to choose between
// Adapter.Resume and a fresh Start. A false answer is the cell's verdict, never
// an error: an unknown host has no route either.
func ResumeRoute(h Host) bool { return route(h, CapResume) == nil }

// PremiseRoute returns the first-turn frame renderer of one host — the frame
// that carries a run's work premise into the session as its first turn
// (SPEC-044 CDT-665 AC1). It is the pre-check a caller runs before it asks
// for a premise delivery. The matrix gates the route first: a host with no
// steerable route answers with its cell verdict as a refusal (AC5), and an
// unknown host is a named error. The renderer answers ok=false for as long as
// the frame has no session id to name — the ACP transport names the session
// in the frame (probe P-GK-ACP-1) — so a premise is never rendered blind.
func PremiseRoute(h Host) (func(sessionID, premise string, seq int) (string, bool), error) {
	if err := route(h, CapSteer); err != nil {
		return nil, err
	}
	sp, err := specOf(h)
	if err != nil {
		return nil, err
	}
	if sp.PremiseFrame == nil {
		return nil, refusalOf(h, CapSteer,
			fmt.Sprintf("%s names no first-turn frame: the premise needs the steerable "+
				"route the matrix (c) cell records", h))
	}
	return sp.PremiseFrame, nil
}

// premiseFrameOf resolves the first-turn renderer one spawn carries (SPEC-044
// CDT-665 M16). It is gated on the host's SPEC, never on the caller's text.
//
// A start that carries a premise is gated by PremiseRoute: a host with no
// steerable route refuses with its matrix cell (AC5) before any row lands.
//
// A spawn that carries no premise text attaches the renderer whenever the
// host's spec names one. That is the takeover re-adoption: the run's PENDING
// premise row carries the text (the chief stores no ticket text, M16), so the
// renderer must travel with a re-spawn that has no premise of its own — with
// nil here the re-adoption closes the row undelivered and the crash window is
// never performed.
//
// A host whose spec names no first-turn frame answers nil, never a refusal: a
// premise-less mini-swe re-spawn behaves exactly as it did before CDT-665
// (its start refusal is the matrix (b) cell, which launchOf owns), and the
// agent journals no premise row when it has neither a row nor text.
func premiseFrameOf(h Host, premise string) (agent.PremiseFrame, error) {
	if premise != "" {
		render, err := PremiseRoute(h)
		if err != nil {
			return nil, err
		}
		return render, nil
	}
	sp, err := specOf(h)
	if err != nil {
		return nil, err
	}
	if sp.PremiseFrame == nil {
		return nil, nil
	}
	return agent.PremiseFrame(sp.PremiseFrame), nil
}

// handshakeFramesOf resolves the client handshake one spawn carries (SPEC-044
// CDT-679 AC1). It is gated on the host's SPEC, never on the caller's request:
// a host that opens its session on its own transport — Claude Code, omp,
// mini-swe — answers nil and its start is byte-unchanged. Every spawn of a
// host that names frames carries them, so a takeover re-spawn writes the
// handshake its new child needs. An unknown host is refused by launchOf or the
// route check before this runs; its nil answer travels nothing.
func handshakeFramesOf(h Host) agent.HandshakeFrames {
	sp, err := specOf(h)
	if err != nil || sp.HandshakeFrames == nil {
		return nil
	}
	return agent.HandshakeFrames(sp.HandshakeFrames)
}

// SteerRequest is one correction for one running host session.
type SteerRequest struct {
	RunID string
	Host  Host
	// SessionID is the session the correction rides (the ACP transport
	// names it in the frame; the other hosts ignore it).
	SessionID string
	// Message is the correction. Untrusted text: it travels as data inside
	// the host's control-message frame, never as a command line.
	Message string
}

// Steer delivers one correction at the next step boundary (AC3). The
// glossary Steer term is written unchanged and the six probes hold it —
// mid-stream injection consumed at the next step boundary, never a separate
// turn — so the adapter encodes the correction into the host's
// control-message frame and hands it to the node agent's steer verb, whose
// delivery is the step-boundary mechanic. The matrix gates the route first:
// an unsupported steer cell returns the verdict as a refusal (AC6).
func (a *Adapter) Steer(ctx context.Context, eng *journal.Engine,
	req SteerRequest) error {
	if err := route(req.Host, CapSteer); err != nil {
		return err
	}
	sp, err := specOf(req.Host)
	if err != nil {
		return err
	}
	frame := sp.SteerFrame(req.SessionID, req.Message, a.nextSeq(req.RunID))
	return a.Agent.Steer(ctx, eng, req.RunID, frame)
}

// Observation is one observe reading: the node agent's status report and the
// session id the run's capture holds (empty before the host named one).
type Observation struct {
	Report    agent.StatusReport `json:"report"`
	SessionID string             `json:"session_id,omitempty"`
}

// Observe reads a run through the node agent's status verb. The reading is
// the agent's own: on a running run the agent journals it (intent, then
// outcome), on any other state it is a pure read and the report says so.
func (a *Adapter) Observe(ctx context.Context, eng *journal.Engine,
	runID string) (Observation, error) {
	rep, err := a.Agent.Status(ctx, eng, runID)
	if err != nil {
		return Observation{}, err
	}
	return Observation{Report: rep, SessionID: a.sessionID(runID)}, nil
}

// Stop stops a run through the node agent's stop verb: the intent row, then
// SIGTERM, then SIGKILL after the grace, then the outcome row and the named
// halt halted:operator_halt.
func (a *Adapter) Stop(ctx context.Context, eng *journal.Engine,
	runID string, grace time.Duration) error {
	return a.Agent.Stop(ctx, eng, runID, grace)
}

// supervise hands one start to the node agent and records the run. The
// agent's own verb refuses an invalid run id or a refused state before any
// row is written; the adapter only routes.
func (a *Adapter) supervise(ctx context.Context, eng *journal.Engine,
	runID string, host Host, cap *Capture, req agent.StartRequest) error {
	a.mu.Lock()
	if a.runs == nil {
		a.runs = map[string]*runRecord{}
	}
	a.runs[runID] = &runRecord{Host: host, Cap: cap}
	a.mu.Unlock()
	return a.Agent.Supervise(ctx, eng, req, cap)
}

// launchOf resolves one host's launch argv and environment. The matrix
// gates the route first (AC6); the credentials resolve against the B7
// proven-name table (AC5) — an unproven name refuses the launch; the run
// caps resolve against the closed non-credential allowlist (SPEC-046 M5) —
// any other name refuses the launch the same way. Every refusal lands here,
// before the node agent sees the start and before any journal row is
// written.
func (a *Adapter) launchOf(h Host, creds []InjectCredential, caps RunCaps) (agentLaunch, error) {
	if err := route(h, CapHeadlessStream); err != nil {
		return agentLaunch{}, err
	}
	sp, err := specOf(h)
	if err != nil {
		return agentLaunch{}, err
	}
	capEnv, err := caps.EnvEntries()
	if err != nil {
		return agentLaunch{}, err
	}
	env := make([]string, 0, len(creds)+len(capEnv))
	for _, c := range creds {
		entry, err := c.EnvEntry()
		if err != nil {
			return agentLaunch{}, err
		}
		env = append(env, entry)
	}
	env = append(env, capEnv...)
	return agentLaunch{Command: sp.LaunchCommand,
		Args: append([]string(nil), sp.LaunchArgs...), Env: env}, nil
}

// agentLaunch is one resolved start: the host CLI command, its argv, and the
// launch environment — the proven credential env entries with the run's
// cap entries appended.
type agentLaunch struct {
	Command string
	Args    []string
	Env     []string
}

// ---------------------------------------------------------------------------
// SPEC-046 CDT-677 M5 — the run-scoped non-credential environment channel
// ---------------------------------------------------------------------------

// The budget-cap environment names, written exactly as the plugin names them:
// the autopilot engine reads both from the session environment
// (skills/autopilot/budget-check.sh). The channel adds no plugin flag and
// changes no name (SPEC-033 N12/N14, SPEC-046 M6).
const (
	EnvCapWallclock = "AUTOPILOT_WALLCLOCK_CAP"
	EnvCapIteration = "AUTOPILOT_ITERATION_CAP"
)

// runEnvAllowlist is the channel's closed name set: exactly the two cap names.
// A start that asks the channel for any other name refuses fail-closed — the
// same shape as the B7 credential gate, and the reason the caps never reach a
// runner environment through a guessed name.
var runEnvAllowlist = []string{EnvCapWallclock, EnvCapIteration}

// The channel's typed refusals. They live with the channel; the package's
// other refusals are in errors.go.
var (
	// ErrRunEnvNameNotAllowed is the SPEC-046 M5 fail-closed rule: a name
	// outside the two-name allowlist never enters the run environment. The
	// caps are not credentials, so this gate is separate from
	// ErrCredentialNameUnproven and the B7 table.
	ErrRunEnvNameNotAllowed = errors.New("hostadapter: environment name is not on the run-scoped allowlist")

	// ErrRunCapsInvalid refuses a cap that is set to a non-positive value
	// (SPEC-046 M3/M7: positive integers, zero means unset).
	ErrRunCapsInvalid = errors.New("hostadapter: run budget cap is not a positive integer")
)

// RunEnvAllowlist is the channel's closed name set, for tests and surfaces.
// The copy keeps the package's set closed to a caller.
func RunEnvAllowlist() []string {
	out := make([]string, len(runEnvAllowlist))
	copy(out, runEnvAllowlist)
	return out
}

// RunCaps are one run's operator-set budget caps (SPEC-046 M5). They ride
// that run's runner environment and nothing else: not the premise command
// line, not the chiefd unit environment, not another run's environment. Zero
// means unset — the run keeps the budget the plugin derives for itself.
type RunCaps struct {
	WallclockCapS int64
	IterationCapS int64
}

// EnvEntries composes the channel entries in allowlist order. A cap that is
// set must be positive; a negative value is a caller defect and refuses
// fail-closed. The rendering goes through runEnvEntry, so the allowlist gates
// every entry the adapter writes.
func (c RunCaps) EnvEntries() ([]string, error) {
	set := []struct {
		name  string
		value int64
	}{
		{EnvCapWallclock, c.WallclockCapS},
		{EnvCapIteration, c.IterationCapS},
	}
	var out []string
	for _, e := range set {
		if e.value == 0 {
			continue
		}
		if e.value < 0 {
			return nil, fmt.Errorf("%w: %s = %d", ErrRunCapsInvalid, e.name, e.value)
		}
		entry, err := runEnvEntry(e.name, strconv.FormatInt(e.value, 10))
		if err != nil {
			return nil, err
		}
		out = append(out, entry)
	}
	return out, nil
}

// runEnvEntry is the channel gate: it validates one name against the closed
// allowlist and renders the NAME=value entry. The name is matched exactly —
// a near-miss, a lowercase spelling, or a credential name is a refusal, never
// a coercion onto an allowed name. An empty value is a refusal too: a cap
// entry with no value is not the plugin's "unset" signal.
func runEnvEntry(name, value string) (string, error) {
	if !allowedRunEnvName(name) {
		return "", fmt.Errorf("%w: %q is not one of %s",
			ErrRunEnvNameNotAllowed, name, strings.Join(runEnvAllowlist, ", "))
	}
	if strings.TrimSpace(value) == "" {
		return "", fmt.Errorf("%w: %s carries an empty value",
			ErrRunEnvNameNotAllowed, name)
	}
	return name + "=" + value, nil
}

// allowedRunEnvName reports whether a name is on the closed allowlist.
func allowedRunEnvName(name string) bool {
	for _, n := range runEnvAllowlist {
		if n == name {
			return true
		}
	}
	return false
}

// sessionID returns the session id a run's capture holds.
func (a *Adapter) sessionID(runID string) string {
	a.mu.Lock()
	defer a.mu.Unlock()
	if rec, ok := a.runs[runID]; ok {
		return rec.Cap.SessionID()
	}
	return ""
}

// nextSeq is the per-run steer request-id counter. Only the ACP transport
// carries one; the counter keeps request ids unique within one session.
func (a *Adapter) nextSeq(runID string) int {
	a.seqMu.Lock()
	defer a.seqMu.Unlock()
	if a.seqs == nil {
		a.seqs = map[string]int{}
	}
	a.seqs[runID]++
	return a.seqs[runID]
}

// refusalOf builds the AC6 refusal of an unsupported shape inside an
// otherwise supported cell.
func refusalOf(h Host, c Capability, why string) error {
	cell, err := cell(h, c)
	if err != nil {
		return err
	}
	return Refusal{Cell: Cell{
		Host: h, Capability: c, Verdict: cell.Verdict, Citation: why,
	}}
}
