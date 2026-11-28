package chief

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/cold-dark-void/claude-dev-team/control-plane/agent"
	"github.com/cold-dark-void/claude-dev-team/control-plane/hostadapter"
	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
	"github.com/cold-dark-void/claude-dev-team/control-plane/lifecycle"
	"github.com/cold-dark-void/claude-dev-team/control-plane/queue"
	"github.com/cold-dark-void/claude-dev-team/control-plane/spool"
)

// Surface is one existing plugin Surface the Chief routes to. The Chief
// invokes the Surface — it never reimplements one: the ticket record is
// written by the plugin's own ticket verbs, and the run executes the Surface
// through the C6 host adapter and the node agent.
type Surface struct {
	// Kind is the route kind the API accepts.
	Kind string `json:"kind"`
	// Name is the Surface's name as a caller says it.
	Name string `json:"name"`
	// Path is the plugin file the Surface lives at.
	Path string `json:"path"`
}

// surfaces is the closed route set: the three routes of CDT-650 AC1 plus the
// existing-ticket route SPEC-045 M1 adds by amendment. Every path is a real
// plugin file.
var surfaces = map[string]Surface{
	"defect": {"defect", "debug", "commands/debug.md"},
	"idea":   {"idea", "brainstorm", "skills/brainstorm/SKILL.md"},
	"epic":   {"epic", "epic", "commands/epic.md"},
	"ticket": {"ticket", "orchestrate", "skills/orchestrate/SKILL.md"},
}

// RouteKinds is the closed route-kind set, in AC order.
var RouteKinds = []string{"defect", "idea", "epic", "ticket"}

// ticketIDRE is the run-id grammar SPEC-045 M2 pins for a ticket id: the id
// becomes both a run id and the backlog item's file name, so a path
// separator or a `..` segment never reaches either.
var ticketIDRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*$`)

// defaultAutopilot is the token a ticket route composes when the request
// names none (SPEC-045 M3).
const defaultAutopilot = "auto"

// advisorOn is the with_advisor value that composes the valueless
// --with-advisor flag; any other non-empty value is the model token
// (SPEC-046 M1).
const advisorOn = "true"

// SurfaceFor returns the Surface one route kind names.
func SurfaceFor(kind string) (Surface, bool) {
	s, ok := surfaces[kind]
	return s, ok
}

// DefaultStartWait is how long a route waits for the run it starts to reach
// the journal (the claim row) or the start verb to refuse, so the common
// refusals — an unsupported matrix cell, a node with no runner selected —
// come back on the route response instead of only in the run's journal.
const DefaultStartWait = 10 * time.Second

// DefaultVersion is the version an unstamped binary serves on
// GET /v1/version (SPEC-043 CDT-678 AC1): the build stamp is the only source
// of a release name, so a binary built without it says "dev" and names no
// commit.
const DefaultVersion = "dev"

// Chief is the single point of contact of control plane Option C+ (CDT-626):
// it routes work to the existing Surfaces and reports from run state. It
// holds no state of its own beyond the runs it started in this process: the
// run state is the journal's replay (AC1), the queue state is the C5 slot
// ledger, and the phone-channel record is .claude/runs/chief/notified.jsonl.
type Chief struct {
	// eng is the journal every report folds and every run rides.
	eng *journal.Engine
	// Adapter is the C6 host adapter every run starts and every correction
	// rides. The Chief adds no second path to the host session.
	Adapter *hostadapter.Adapter
	// Queue is the C5 run queue over the same journal; the reports read its
	// slot ledger.
	Queue *queue.Queue

	// Now is the clock of the checks reading. Defaults to time.Now.
	Now func() time.Time

	// StartWait bounds the route's wait for the run's first journal row.
	StartWait time.Duration

	// SID is the Intercom session id of the operator the halt pages name.
	// Empty lets the intercom CLI resolve its own sid (INTERCOM_SID, then
	// CLAUDE_SESSION_ID, then the newest transcript).
	SID string

	// version and commit are the build identity this Chief serves: the
	// control-plane/VERSION and short commit the binary was built from,
	// stamped in at build time (SPEC-043 CDT-678 AC1). An unstamped binary
	// keeps DefaultVersion and the empty commit — it never claims a release
	// it is not.
	version string
	commit  string

	// baseCtx is the context the supervision of a routed run lives under —
	// the chiefd lifetime, never one HTTP request. Defaults to
	// context.Background.
	baseCtx context.Context

	// mroot resolves the record root. Defaults to journal.MROOT.
	mroot func() (string, error)

	// pluginRoot resolves the plugin root the seams exec the plugin's own
	// CLIs from. Defaults to $MROOT — the repository checkout the service
	// runs against.
	pluginRoot func() (string, error)

	// Seams over the plugin's own CLIs — files and CLI calls only, the ADR
	// 0001 boundary. Tests inject fakes.
	tickets TicketCreator
	models  ModelResolver
	phone   Phone

	// autopilot is the autopilot-token seam of the ticket route
	// (SPEC-045 M3): the vocabulary is the plugin's flag parser, never a
	// chief copy.
	autopilot AutopilotValidator

	// options is the run-options seam of the ticket route (SPEC-046 M3): the
	// tier, council-tier, and max-loc vocabularies are the plugin's own flag
	// parser, never a chief copy.
	options OptionsValidator

	// advisor is the advisor-token seam of the ticket route (SPEC-046 M3):
	// the model-token grammar is the plugin's own advisor parser
	// (SPEC-039 M37), never a chief copy of the charset.
	advisor AdvisorValidator

	// phaseEvents is the C3 phase-event read the board's current-phase
	// fold rides (control-plane/spool). Nil is the default spool read.
	phaseEvents func(ctx context.Context, runID string) ([]spool.Record, error)

	// runnerOnce and runner resolve the node's runner selection once, so
	// every board row names the same runner.
	runnerOnce sync.Once
	runner     string

	// graphOnce, graphVal, and graphErr load the committed C3 lifecycle
	// graph once — the graph the board draws, never a second copy of it.
	graphOnce sync.Once
	graphVal  *lifecycle.Graph
	graphErr  error

	mu   sync.Mutex
	runs map[string]*runRecord

	// takeoverSeen holds the takeover report lines this process already put
	// on stdout, so the repeating scan (SPEC-044 M2) does not write the same
	// skip or refusal to journald on every tick.
	takeoverSeen map[string]bool

	// takeoverRep is the last takeover scan's report: the skips (M5) and
	// refusals (M6) it named. Checks projects it per run so a run the scan
	// did not take over is named on GET /v1/checks (AC5). Guarded by mu.
	takeoverRep TakeoverReport

	// notifyMu serializes the halt scan and its pages: two scans must not
	// page the same halt twice.
	notifyMu sync.Mutex

	// answeredRead is the takeover-answered reading of the halt scan —
	// takeoverAnswered itself. It is a seam like the others: a test drives it
	// to land a re-spawn between the scan's first read and its pre-page
	// re-read, the one-shot page window CDT-664 closes.
	answeredRead func(context.Context, HaltReport) (bool, error)
}

// runRecord is one run the chief started: the host its session rides and the
// session-id capture from the start.
type runRecord struct {
	Host hostadapter.Host
	Cap  *hostadapter.Capture
}

// Option configures a chief.
type Option func(*Chief)

// WithNow sets the checks clock.
func WithNow(now func() time.Time) Option { return func(c *Chief) { c.Now = now } }

// WithBaseContext sets the context the supervision of a routed run lives
// under — the service lifetime, never one HTTP request.
func WithBaseContext(ctx context.Context) Option {
	return func(c *Chief) { c.baseCtx = ctx }
}

// WithVersion stamps the build identity GET /v1/version serves (SPEC-043
// CDT-678 AC1) — the values chiefd carries in from -ldflags -X. An empty
// version is the unstamped build: it answers DefaultVersion and the commit it
// carries, never a release name.
func WithVersion(version, commit string) Option {
	return func(c *Chief) {
		if version == "" {
			version = DefaultVersion
		}
		c.version = version
		c.commit = commit
	}
}

// WithPluginRoot points the plugin-CLI seams at one plugin root. The
// default is defaultPluginRoot: the $MROOT checkout itself, refused unless
// it carries the dev-team manifest.
func WithPluginRoot(dir string) Option {
	return func(c *Chief) {
		c.pluginRoot = func() (string, error) { return dir, nil }
	}
}

// defaultPluginRoot resolves the plugin root from $MROOT and refuses a
// non-dev-team checkout: chiefd is deployed on a dev-team checkout and the
// seams exec the plugin's own CLIs from it. The refusal is typed and
// visible — on a foreign checkout the pages fail and retry (the AC5 phone
// channel), they never fail silently.
func defaultPluginRoot() (string, error) {
	root, err := journal.MROOT()
	if err != nil {
		return "", err
	}
	raw, err := os.ReadFile(filepath.Join(root, ".claude-plugin", "plugin.json"))
	if err != nil {
		return "", fmt.Errorf("%w: %s carries no dev-team plugin manifest: %v",
			ErrNoPluginRoot, root, err)
	}
	var manifest struct {
		Name string `json:"name"`
	}
	if err := jsonUnmarshal(raw, &manifest); err != nil || manifest.Name != "dev-team" {
		return "", fmt.Errorf("%w: %s is not a dev-team checkout", ErrNoPluginRoot, root)
	}
	return root, nil
}

// WithTickets replaces the ticket seam.
func WithTickets(t TicketCreator) Option { return func(c *Chief) { c.tickets = t } }

// WithModelMap replaces the Model map seam.
func WithModelMap(m ModelResolver) Option { return func(c *Chief) { c.models = m } }

// WithPhone replaces the phone seam.
func WithPhone(p Phone) Option { return func(c *Chief) { c.phone = p } }

// WithAutopilot replaces the autopilot-token seam.
func WithAutopilot(v AutopilotValidator) Option {
	return func(c *Chief) { c.autopilot = v }
}

// WithOptionValidator replaces the run-options seam (SPEC-046 M3).
func WithOptionValidator(v OptionsValidator) Option {
	return func(c *Chief) { c.options = v }
}

// WithAdvisorValidator replaces the advisor-token seam (SPEC-046 M3).
func WithAdvisorValidator(v AdvisorValidator) Option {
	return func(c *Chief) { c.advisor = v }
}

// WithSID pins the Intercom session id of the operator channel.
func WithSID(sid string) Option { return func(c *Chief) { c.SID = sid } }

// WithPhaseEvents replaces the C3 phase-event read the board's
// current-phase fold rides. The default reads the default spool
// (control-plane/spool). Tests inject a fixture.
func WithPhaseEvents(read func(ctx context.Context, runID string) ([]spool.Record, error)) Option {
	return func(c *Chief) { c.phaseEvents = read }
}

// New returns a chief over one journal, its C5 queue, and the C6 host
// adapter built on one node agent.
func New(eng *journal.Engine, a *agent.Agent, opts ...Option) *Chief {
	return NewWithAdapter(eng, hostadapter.New(a), opts...)
}

// NewWithAdapter is New over a caller-built adapter — the seam tests drive
// the node agent through.
func NewWithAdapter(eng *journal.Engine, ad *hostadapter.Adapter, opts ...Option) *Chief {
	c := &Chief{
		eng:          eng,
		Adapter:      ad,
		Queue:        queue.New(eng),
		Now:          time.Now,
		StartWait:    DefaultStartWait,
		version:      DefaultVersion,
		baseCtx:      context.Background(),
		mroot:        journal.MROOT,
		runs:         map[string]*runRecord{},
		takeoverSeen: map[string]bool{},
	}
	for _, opt := range opts {
		opt(c)
	}
	if c.pluginRoot == nil {
		c.pluginRoot = defaultPluginRoot
	}
	if c.answeredRead == nil {
		c.answeredRead = c.takeoverAnswered
	}
	if c.tickets == nil {
		c.tickets = &ticketCLI{root: c.pluginRoot, store: c.mroot}
	}
	if c.models == nil {
		c.models = &bashModelMap{root: c.pluginRoot}
	}
	if c.phone == nil {
		c.phone = &intercomPhone{root: c.pluginRoot, sid: c.SID}
	}
	if c.autopilot == nil {
		c.autopilot = &bashAutopilotFlags{root: c.pluginRoot}
	}
	if c.options == nil {
		c.options = &bashOptionFlags{root: c.pluginRoot}
	}
	if c.advisor == nil {
		c.advisor = &bashAdvisorFlags{root: c.pluginRoot}
	}
	return c
}

// RouteRequest is one request the Chief turns into work.
type RouteRequest struct {
	// Kind is the route: one of RouteKinds.
	Kind string `json:"kind"`
	// Title is the ticket title the route writes; its slug becomes the
	// run id of a defect or idea route.
	Title string `json:"title"`
	// Text is the premise: it rides the ticket record the Surface reads.
	Text string `json:"text"`
	// Agent optionally names a mappable agent (SPEC-037) whose Model map
	// row resolves the run's model. Empty is the Tier default (AC3); there
	// is no flag for this.
	Agent string `json:"agent,omitempty"`
	// Host is the matrix host the run rides — required for a defect or
	// idea route, the frame encoder of a correction.
	Host hostadapter.Host `json:"host,omitempty"`
	// Children are the child tickets of an epic route (AC1: an epic routes
	// to child tickets).
	Children []ChildRequest `json:"children,omitempty"`
	// TicketID is the existing backlog slug a ticket route runs (SPEC-045
	// M1). The route writes no record: the id names an item the store
	// already holds.
	TicketID string `json:"ticket_id,omitempty"`
	// Autopilot is the ship-intent token of a ticket route — bare, auto,
	// patch, minor, major, or master — validated by the plugin's own flag
	// parser. Empty is auto.
	Autopilot string `json:"autopilot,omitempty"`
	// The run options of a ticket route (SPEC-046 M1). Every field is a
	// string so "empty composes nothing" is one rule and the numeric fields
	// keep the text form the validation seams pass to the plugin's parsers.
	// An empty field composes nothing; a non-ticket kind refuses every one
	// of them.
	// WithAdvisor is off when empty, the bare --with-advisor when "true",
	// and the --with-advisor=<model> token for any other non-empty value.
	WithAdvisor string `json:"with_advisor,omitempty"`
	// Tier is the pipeline cost tier: light, standard, or full.
	Tier string `json:"tier,omitempty"`
	// CouncilTier is the council tier: skip, light, or full.
	CouncilTier string `json:"council_tier,omitempty"`
	// MaxLoc is the per-run LOC cap: a positive integer or "unbound".
	MaxLoc string `json:"max_loc,omitempty"`
	// Concurrency is the spawn concurrency cap: a positive integer.
	Concurrency string `json:"concurrency,omitempty"`
	// WallclockCap and IterationCap are the run-budget caps, in seconds and
	// stints. They never reach the command line (SPEC-046 M5): they ride the
	// run's runner environment as AUTOPILOT_WALLCLOCK_CAP /
	// AUTOPILOT_ITERATION_CAP.
	WallclockCap string `json:"wallclock_cap,omitempty"`
	IterationCap string `json:"iteration_cap,omitempty"`
}

// routeOptions are a ticket route's run options in the SPEC-046 M2
// composition order — the order the fields are declared in. Every field
// carries the request's own text; empty composes nothing. The route resolves
// the autopilot token (its default is auto) before it fills Autopilot.
type routeOptions struct {
	Tier         string
	CouncilTier  string
	MaxLoc       string
	Concurrency  string
	WithAdvisor  string
	Autopilot    string
	WallclockCap string
	IterationCap string
}

// runOptions reads the request's option fields, trimmed, into the
// composition order. The autopilot token is the caller's — the route applies
// its default before it composes.
func (r RouteRequest) runOptions() routeOptions {
	return routeOptions{
		Tier:         strings.TrimSpace(r.Tier),
		CouncilTier:  strings.TrimSpace(r.CouncilTier),
		MaxLoc:       strings.TrimSpace(r.MaxLoc),
		Concurrency:  strings.TrimSpace(r.Concurrency),
		WithAdvisor:  strings.TrimSpace(r.WithAdvisor),
		WallclockCap: strings.TrimSpace(r.WallclockCap),
		IterationCap: strings.TrimSpace(r.IterationCap),
	}
}

// optionField is one request option a refusal names: epicApplicable is false
// for the options /orchestrate owns alone (SPEC-046 M4). The caps are
// applicable to an epic route — they ride the run's environment, never the
// command line (SPEC-046 M5).
type optionField struct {
	name           string
	value          string
	epicApplicable bool
}

// optionFields names the option fields the request carries, in M1 order, for
// the refusal text of a kind that accepts none of them.
func (r RouteRequest) optionFields() []string {
	return r.presentOptionFields(false)
}

// orchestrateOnlyFields names the present fields that apply to /orchestrate
// alone: the options an epic id refuses by name (SPEC-046 M4).
func (r RouteRequest) orchestrateOnlyFields() []string {
	return r.presentOptionFields(true)
}

// presentOptionFields lists the present option fields in M1 order. With
// epicOnly set it keeps only the options an epic id does not apply
// (SPEC-046 M4).
func (r RouteRequest) presentOptionFields(epicOnly bool) []string {
	fields := []optionField{
		{"with_advisor", r.WithAdvisor, false}, {"tier", r.Tier, false},
		{"council_tier", r.CouncilTier, false}, {"max_loc", r.MaxLoc, false},
		{"concurrency", r.Concurrency, false},
		{"wallclock_cap", r.WallclockCap, true}, {"iteration_cap", r.IterationCap, true},
	}
	var present []string
	for _, f := range fields {
		if strings.TrimSpace(f.value) == "" {
			continue
		}
		if epicOnly && f.epicApplicable {
			continue
		}
		present = append(present, f.name)
	}
	return present
}

// ChildRequest is one child ticket of an epic route.
type ChildRequest struct {
	Title string `json:"title"`
	Text  string `json:"text,omitempty"`
}

// TicketRecord is one ticket record the route wrote through the plugin's
// ticket verbs.
type TicketRecord struct {
	Slug  string `json:"slug"`
	Path  string `json:"path"`
	Kind  string `json:"kind"`
	Title string `json:"title"`
}

// RouteResult is what one route did.
type RouteResult struct {
	Kind        string         `json:"kind"`
	Surface     Surface        `json:"surface"`
	Ticket      *TicketRecord  `json:"ticket,omitempty"`
	Children    []TicketRecord `json:"children,omitempty"`
	RunID       string         `json:"run_id,omitempty"`
	Model       string         `json:"model"`
	ModelSource string         `json:"model_source"`
	// Command is the premise a ticket route composes — the command line the
	// run executes (SPEC-045 M3). Empty for the new-work kinds, whose
	// premise is the request's text.
	Command string `json:"command,omitempty"`
}

// Route turns one request into work (AC1): it writes the ticket record
// through the plugin's own ticket verbs, resolves the model through the
// Model map (AC3), and — for a defect or an idea — starts the run whose
// workflow names the Surface. An epic route ends at the child-ticket
// records; a child run starts when the operator routes it.
//
// A ticket route (SPEC-045 M1) writes no record: the request names an
// existing backlog id, the composed command is the run's premise, and the
// run is the next attempt of that ticket.
//
// The run is started through the C6 host adapter — the Chief adds no second
// path to the host session. The route waits, bounded by StartWait, for the
// run's first journal row or the start verb's refusal, so an unsupported
// matrix cell or a node with no runner selection refuses the route instead
// of leaving a silent ticket.
func (c *Chief) Route(ctx context.Context, req RouteRequest) (*RouteResult, error) {
	surface, ok := surfaces[req.Kind]
	if !ok {
		return nil, fmt.Errorf("%w: %q is not one of %s", ErrUnknownRoute, req.Kind,
			strings.Join(RouteKinds, ", "))
	}
	// A ticket route names an id, not new work: its premise is the composed
	// command, so the title and premise checks are the new-work kinds'.
	// The run options are the ticket route's alone (SPEC-046 M1): every
	// other kind refuses them before it writes a record.
	if req.Kind != "ticket" {
		if fields := req.optionFields(); len(fields) > 0 {
			return nil, fmt.Errorf("%w: the %s route carries no run options (%s)",
				ErrInvalid, req.Kind, strings.Join(fields, ", "))
		}
		if strings.TrimSpace(req.Title) == "" {
			return nil, fmt.Errorf("%w: a route needs a title", ErrInvalid)
		}
		if strings.TrimSpace(req.Text) == "" {
			return nil, fmt.Errorf("%w: a route needs a premise", ErrInvalid)
		}
	}
	model, source, err := c.models.Resolve(ctx, req.Agent)
	if err != nil {
		return nil, err
	}

	res := &RouteResult{Kind: req.Kind, Surface: surface, Model: model, ModelSource: source}

	switch req.Kind {
	case "epic":
		if len(req.Children) == 0 {
			return nil, fmt.Errorf("%w: an epic route carries at least one child", ErrInvalid)
		}
		epic, err := c.tickets.Create(ctx, TicketRequest{
			Kind: "epic", Title: req.Title, Problem: req.Text})
		if err != nil {
			return nil, err
		}
		res.Ticket = &epic
		for i, ch := range req.Children {
			rec, err := c.tickets.Create(ctx, TicketRequest{
				Kind: "child", Title: ch.Title, Problem: ch.Text,
				EpicParent: epic.Slug, ChildID: fmt.Sprintf("C%d", i+1)})
			if err != nil {
				return nil, err
			}
			res.Children = append(res.Children, rec)
		}
		return res, nil

	case "ticket":
		id, err := ticketRouteID(req.TicketID)
		if err != nil {
			return nil, err
		}
		opts := req.runOptions()
		// The SPEC-046 M3 refusal order: syntax, then the parser seams, then
		// the item read, then the M4 epic refusal — every refusal lands
		// before any journal row. The numeric options are the syntax layer:
		// the plugin owns no parser for them, and the check answers the caps
		// the spawn carries (M5).
		caps, err := validateRunOptionNumbers(opts)
		if err != nil {
			return nil, err
		}
		token := strings.TrimSpace(req.Autopilot)
		if token == "" {
			token = defaultAutopilot
		}
		if err := c.autopilot.Validate(ctx, token); err != nil {
			return nil, err
		}
		if err := c.options.Validate(ctx, opts); err != nil {
			return nil, err
		}
		if opts.WithAdvisor != "" {
			if err := c.advisor.Validate(ctx, opts.WithAdvisor); err != nil {
				return nil, err
			}
		}
		opts.Autopilot = token
		if !hostadapter.ValidHost(req.Host) {
			return nil, fmt.Errorf("%w: %q is not one of %s", hostadapter.ErrUnknownHost,
				req.Host, hostList())
		}
		// The item read is the SPEC-046 M8 lookup order: a local slug, then a
		// frontmatter linear_id match, then the tracker-id passthrough. It
		// refuses nothing — a grammar-valid id always routes.
		item, err := c.ticketItem(id)
		if err != nil {
			return nil, err
		}
		if item.Kind == "epic" {
			if fields := req.orchestrateOnlyFields(); len(fields) > 0 {
				return nil, fmt.Errorf("%w: the epic route carries no orchestrate options (%s)",
					ErrOrchestrateOnlyOption, strings.Join(fields, ", "))
			}
			// The run rides the epic surface: /epic, not /orchestrate.
			surface = surfaces["epic"]
			res.Surface = surface
		}
		res.Command = composeRunCommand(surface.Name, id, opts)
		if res.RunID, err = c.nextAttempt(ctx, id); err != nil {
			return nil, err
		}
		if err := c.startRun(ctx, req, res, id, res.Command, caps); err != nil {
			return nil, err
		}
		return res, nil

	default:
		if !hostadapter.ValidHost(req.Host) {
			return nil, fmt.Errorf("%w: %q is not one of %s", hostadapter.ErrUnknownHost,
				req.Host, hostList())
		}
		ticket, err := c.tickets.Create(ctx, TicketRequest{
			Kind: "ticket", Title: req.Title, Problem: req.Text})
		if err != nil {
			return nil, err
		}
		res.Ticket = &ticket
		res.RunID = ticket.Slug
		if exists, err := c.runExists(ctx, ticket.Slug); err != nil {
			return nil, err
		} else if exists {
			return nil, fmt.Errorf("%w: %s", ErrRunExists, ticket.Slug)
		}
		// A new-work kind carries no run options (SPEC-046 M1), so its start
		// names no caps.
		if err := c.startRun(ctx, req, res, ticket.Slug, req.Text,
			hostadapter.RunCaps{}); err != nil {
			return nil, err
		}
		return res, nil
	}
}

// ticketRouteID validates the id a ticket route names: it is a run-safe id
// before it reaches the store path or a run id (SPEC-045 M2).
func ticketRouteID(raw string) (string, error) {
	id := strings.TrimSpace(raw)
	if !ticketIDRE.MatchString(id) {
		return "", fmt.Errorf("%w: ticket id %q must match %s", ErrInvalid, raw, ticketIDRE)
	}
	return id, nil
}

// positiveIntRE is the integer grammar SPEC-046 M3 cites from CDT-573: an
// integer of at least 1 — no sign, no leading zero, no fractional part.
var positiveIntRE = regexp.MustCompile(`^[1-9][0-9]*$`)

// validateRunOptionNumbers is the syntax layer of the ticket route's M3 order:
// concurrency is the CDT-573 grammar, cited not copied, and the two caps are
// positive integers with no upper ceiling (SPEC-033 N14). The plugin owns no
// parser for these, so the check is mechanical here and it refuses before any
// seam execs. It is also the route's only reader of the cap text: it answers
// the values the spawn carries (SPEC-046 M5/M7), so no caller re-parses them.
func validateRunOptionNumbers(opts routeOptions) (hostadapter.RunCaps, error) {
	var caps hostadapter.RunCaps
	// Concurrency composes onto the command line, so its value is checked and
	// not carried; the two caps are the payload this returns.
	if opts.Concurrency != "" {
		if _, err := positiveIntField("concurrency", opts.Concurrency); err != nil {
			return hostadapter.RunCaps{}, err
		}
	}
	if opts.WallclockCap != "" {
		n, err := positiveIntField("wallclock_cap", opts.WallclockCap)
		if err != nil {
			return hostadapter.RunCaps{}, err
		}
		caps.WallclockCapS = n
	}
	if opts.IterationCap != "" {
		n, err := positiveIntField("iteration_cap", opts.IterationCap)
		if err != nil {
			return hostadapter.RunCaps{}, err
		}
		caps.IterationCapS = n
	}
	return caps, nil
}

// positiveIntField checks one numeric option against positiveIntRE and answers
// its value. The only ceiling is int64: a cap the journal cannot carry refuses
// here, never at the spawn (SPEC-046 M3).
func positiveIntField(name, raw string) (int64, error) {
	if !positiveIntRE.MatchString(raw) {
		return 0, fmt.Errorf("%w: %s must be an integer of at least 1, got %q",
			ErrIllegalOptionNumber, name, raw)
	}
	n, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("%w: %s %s is out of range: %v",
			ErrIllegalOptionNumber, name, raw, err)
	}
	return n, nil
}

// ticketItem is one backlog item the local store holds. The read is the
// store file the plugin's own ticket verbs own —
// $MROOT/.claude/backlog/<id>.md (SPEC-045 M1) — and the ticket route only
// reads it: the store gains no row from routing an existing id (AC8).
type ticketItem struct {
	// Kind is the item's frontmatter kind: epic, child, or empty for a
	// plain ticket. The tracker-id passthrough has no item, so it answers
	// the empty Kind: the route composes /orchestrate <ID> and neither the
	// kind-epic switch nor the M4 epic refusal applies to it (SPEC-046 M8).
	Kind string
}

// ticketItem resolves one ticket-route id against the local store in the
// SPEC-046 M8 lookup order: (1) the id is a slug and names
// $MROOT/.claude/backlog/<id>.md; (2) the id is a tracker id one item's
// frontmatter carries as linear_id; (3) neither — the passthrough. The scan
// is read-only and stays inside the store directory: chiefd gains no Linear
// dependency and makes no network read (M8).
func (c *Chief) ticketItem(id string) (ticketItem, error) {
	root, err := c.mroot()
	if err != nil {
		return ticketItem{}, err
	}
	dir := filepath.Join(root, ".claude", "backlog")
	raw, err := os.ReadFile(filepath.Join(dir, id+".md"))
	if err == nil {
		return ticketItem{Kind: frontmatterKind(raw)}, nil
	}
	if !errors.Is(err, fs.ErrNotExist) {
		// Only a missing item is a passthrough; a store the process cannot
		// read is a visible failure, never a silent loss of the item's kind.
		return ticketItem{}, fmt.Errorf("chief: cannot read the store item for %s: %w", id, err)
	}
	kind, err := linearIDKind(dir, id)
	if err != nil {
		return ticketItem{}, err
	}
	return ticketItem{Kind: kind}, nil
}

// linearIDKind answers the kind of the store item whose frontmatter carries
// the tracker id as linear_id — the bridge skills/backlog/add.sh --linear-id
// writes and skills/backlog/close.sh reads — and "" when no item carries it.
// It reads the frontmatter header only. os.ReadDir hands the names in sorted
// order, so a store that carries the id twice resolves the same item every time.
func linearIDKind(dir, id string) (string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return "", nil
		}
		return "", fmt.Errorf("chief: cannot read the backlog store %s: %w", dir, err)
	}
	for _, ent := range entries {
		if ent.IsDir() || !strings.HasSuffix(ent.Name(), ".md") {
			continue
		}
		lines, err := frontmatterLines(filepath.Join(dir, ent.Name()))
		if err != nil {
			// An item this process cannot read matches nothing; the entry the
			// listing named can already be gone (the plugin owns the store).
			continue
		}
		value := frontmatterValue(lines, "linear_id")
		if value != "" && value == id {
			return frontmatterValue(lines, "kind"), nil
		}
	}
	return "", nil
}

// frontmatterHeaderLines bounds the header read: an item's frontmatter is the
// short key block skills/backlog/add.sh writes, so a block longer than this is
// not frontmatter and the scan stops rather than reading the item's body.
const frontmatterHeaderLines = 64

// frontmatterLines returns the lines of a file's YAML frontmatter block, and
// reads no further: the read stops at the closing fence. A file in the
// plain-ticket shape (no frontmatter) answers nil.
func frontmatterLines(path string) ([]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	var lines []string
	opened := false
	for sc.Scan() {
		line := strings.TrimRight(sc.Text(), "\r")
		if !opened {
			if !frontmatterFence(line) {
				// Plain-ticket shape: no header, so nothing to read of it.
				return nil, nil
			}
			opened = true
			continue
		}
		if frontmatterFence(line) {
			return lines, nil
		}
		lines = append(lines, line)
		if len(lines) >= frontmatterHeaderLines {
			break
		}
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	return lines, nil
}

func frontmatterFence(line string) bool {
	return strings.TrimRight(line, " \t") == "---"
}

// frontmatterValue returns the first value of a top-level frontmatter key, in
// the shape skills/backlog/sweep.sh's fm_value reads: the key at column 1, the
// value stripped of surrounding spaces.
func frontmatterValue(lines []string, key string) string {
	for _, line := range lines {
		if value, found := strings.CutPrefix(line, key+":"); found {
			return strings.Trim(value, " \t")
		}
	}
	return ""
}

// frontmatterKind reads the kind key of an item's YAML frontmatter — the key
// order skills/backlog/add.sh writes. Empty is the plain-ticket shape: those
// records carry no frontmatter.
func frontmatterKind(raw []byte) string {
	lines := strings.Split(string(raw), "\n")
	if len(lines) == 0 || strings.TrimRight(lines[0], "\r") != "---" {
		return ""
	}
	var header []string
	for _, line := range lines[1:] {
		line = strings.TrimRight(line, "\r")
		if line == "---" {
			break
		}
		header = append(header, line)
	}
	return frontmatterValue(header, "kind")
}

// parserTokens are the option flags of skills/autopilot/parse-flags.sh's own
// vocabulary — the tokens of the SPEC-046 M2 composition the plugin's flag
// parser reads. One spelling serves the composition and the validation seam,
// so no vocabulary is copied into the control plane. Only present fields
// compose.
func parserTokens(opts routeOptions) []string {
	var tokens []string
	if opts.Tier != "" {
		tokens = append(tokens, "--tier="+opts.Tier)
	}
	if opts.CouncilTier != "" {
		tokens = append(tokens, "--council-tier="+opts.CouncilTier)
	}
	if opts.MaxLoc != "" {
		tokens = append(tokens, "--max-loc="+opts.MaxLoc)
	}
	return tokens
}

// composeRunCommand is the premise a ticket route sends: the Surface's
// command line, then the run options in the SPEC-046 M2 pinned order — id
// first, then --tier, --council-tier, --max-loc, --concurrency N,
// --with-advisor[=<model>], and --autopilot[=<token>] last. Only a present
// option composes, so an empty option set composes the SPEC-045 command byte
// for byte. The caps are never part of the command (M5). A bare token names
// the valueless flag (SPEC-045 M3).
func composeRunCommand(workflow, id string, opts routeOptions) string {
	args := append([]string{"/" + workflow, id}, parserTokens(opts)...)
	if opts.Concurrency != "" {
		// The plugin's own grammar is the two-token space form.
		args = append(args, "--concurrency", opts.Concurrency)
	}
	if opts.WithAdvisor != "" {
		flag := "--with-advisor"
		if opts.WithAdvisor != advisorOn {
			flag += "=" + opts.WithAdvisor
		}
		args = append(args, flag)
	}
	if opts.Autopilot == autopilotBare {
		args = append(args, "--autopilot")
	} else {
		args = append(args, "--autopilot="+opts.Autopilot)
	}
	return strings.Join(args, " ")
}

// nextAttempt answers the run id of one ticket's next attempt (SPEC-045 M2):
// the plain slug for its first run, then `<slug>-r<N>` where N is one past
// the highest attempt the journal already carries for the ticket. The
// journal's ticket field is the grouping key, so a restarted chief re-reads
// the same answer and an allocation is never doubled.
func (c *Chief) nextAttempt(ctx context.Context, ticket string) (string, error) {
	ids, err := c.runIDs(ctx)
	if err != nil {
		return "", err
	}
	highest := 0
	for _, id := range ids {
		st, err := c.eng.RunState(ctx, id)
		if err != nil {
			return "", err
		}
		if st.Ticket != ticket {
			continue
		}
		if n, ok := attemptOf(ticket, id); ok && n > highest {
			highest = n
		}
	}
	if highest == 0 {
		return ticket, nil
	}
	return fmt.Sprintf("%s-r%d", ticket, highest+1), nil
}

// attemptOf derives a ticket run's attempt from its id: the plain slug is
// attempt 1 and `<slug>-r<N>` is attempt N.
func attemptOf(ticket, runID string) (int, bool) {
	if runID == ticket {
		return 1, true
	}
	rest, found := strings.CutPrefix(runID, ticket+attemptSuffix)
	if !found {
		return 0, false
	}
	n := attemptFromTail(rest)
	if n == 0 {
		return 0, false
	}
	return n, true
}

// startSupervised is the one spawn path of the chief's own starts — a routed
// run (startRun) and a takeover re-spawn (takeoverSpawn). It records the run,
// starts it through the host adapter on the chief's base context (the service
// lifetime, never the caller's), and answers with the start's channel: nil
// when the supervision is running, a refusal when the start wrote no row.
// Proving the start is the caller's read of the journal.
func (c *Chief) startSupervised(runID string, req hostadapter.StartRequest) <-chan error {
	return c.superviseRun(runID, req.Host, func(ctx context.Context) (*hostadapter.Capture, error) {
		return c.Adapter.Start(ctx, c.eng, req)
	})
}

// startSupervisedResume is startSupervised's resume twin (SPEC-044 CDT-661
// AC3): the run's capture is recorded exactly like a start's, so Correct
// keeps steering the resumed session, and the spawn rides Adapter.Resume —
// the host's by-id resume invocation — on the chief's base context.
func (c *Chief) startSupervisedResume(runID string, req hostadapter.ResumeRequest) <-chan error {
	return c.superviseRun(runID, req.Host, func(ctx context.Context) (*hostadapter.Capture, error) {
		return c.Adapter.Resume(ctx, c.eng, req)
	})
}

// superviseRun is the body of both: record the run, run the adapter verb on
// the base context, store the returned capture so Correct can steer it, and
// answer on the start's channel. A refused start wrote no row: the chief's
// record of the run goes with it — when that record is still unconfirmed.
// Two starts for one run id share one record (CDT-664), so the record carries
// one start's confirmation while the other answers: registration keeps the
// record a confirmed start is carrying, an errored start owns no confirmation
// and never deletes a record that holds a capture, and a confirmed start
// re-creates the record a refused sibling removed.
func (c *Chief) superviseRun(runID string, host hostadapter.Host,
	spawn func(ctx context.Context) (*hostadapter.Capture, error)) <-chan error {
	c.mu.Lock()
	if c.runs == nil {
		c.runs = map[string]*runRecord{}
	}
	if rec, ok := c.runs[runID]; ok {
		rec.Host = host
	} else {
		c.runs[runID] = &runRecord{Host: host}
	}
	c.mu.Unlock()

	base := c.baseCtx
	if base == nil {
		base = context.Background()
	}
	errc := make(chan error, 1)
	go func() {
		cap, err := spawn(base)
		if err != nil {
			c.mu.Lock()
			if rec, ok := c.runs[runID]; ok && rec.Cap == nil {
				delete(c.runs, runID)
			}
			c.mu.Unlock()
			errc <- err
			return
		}
		if cap != nil {
			c.mu.Lock()
			if rec, ok := c.runs[runID]; ok {
				rec.Cap = cap
			} else {
				c.runs[runID] = &runRecord{Host: host, Cap: cap}
			}
			c.mu.Unlock()
		}
		errc <- nil
	}()
	return errc
}

// startWait is the start-wait budget: how long a caller watches the journal
// for the proof of a start before it answers unconfirmed.
func (c *Chief) startWait() time.Duration {
	if c.StartWait <= 0 {
		return DefaultStartWait
	}
	return c.StartWait
}

// startRun journals the route onto a run: the run's claim payload carries
// the ticket, the Surface as the workflow, and the resolved model — the
// route's own trail in the closed event set, never a new kind. The
// supervision lives under the chief's base context, not the caller's.
//
// The route's premise rides the start as the run's work premise
// (SPEC-044 CDT-665): the host adapter renders it into the session's
// first-turn frame, so a routed run reaches work without an operator
// correction. For a ticket route the premise is the composed command and the
// ticket is the existing id, which the attempt ladder keeps distinct from
// the run id (SPEC-045 M1/M2).
//
// caps are the run's own budget caps (SPEC-046 M5/M7): they ride the
// run-scoped environment channel and the run_started row, never the premise
// command line. The host adapter is the one writer of the environment; the
// chief hands it validated values — from the route's syntax check, or read
// back from the journaled state by a retry. The zero value means no cap.
func (c *Chief) startRun(ctx context.Context, req RouteRequest, res *RouteResult,
	ticket, premise string, caps hostadapter.RunCaps) error {
	errc := c.startSupervised(res.RunID, hostadapter.StartRequest{
		RunID: res.RunID, Ticket: ticket, Workflow: res.Surface.Name,
		Model: res.Model, Host: req.Host, Premise: premise, RunCaps: caps,
	})

	wait := c.startWait()
	timer := time.NewTimer(wait)
	defer timer.Stop()
	for {
		select {
		case err := <-errc:
			return err
		case <-ctx.Done():
			return c.unconfirmedStart(ctx, res, fmt.Errorf("route %s abandoned while run %s starts: %v",
				res.Surface.Name, res.RunID, ctx.Err()))
		case <-timer.C:
			return c.unconfirmedStart(ctx, res, fmt.Errorf("run %s reached no journal row within %s",
				res.RunID, wait))
		default:
			if exists, err := c.runExists(ctx, res.RunID); err == nil && exists {
				return nil
			}
			time.Sleep(5 * time.Millisecond)
		}
	}
}

// unconfirmedStart answers a route whose start wait expired or whose
// caller left, honestly about the run: the start goroutine rides the base
// context, so its rows may land after the answer — the error names whether
// the journal already carries the run.
func (c *Chief) unconfirmedStart(ctx context.Context, res *RouteResult, cause error) error {
	state := "may still start under the chief's base context"
	if exists, err := c.runExists(ctx, res.RunID); err == nil && exists {
		state = "started despite the wait"
	}
	return fmt.Errorf("%w: run %s %s (%v)", ErrStartUnconfirmed, res.RunID, state, cause)
}

// CorrectRequest is one correction the Chief sends to a running session.
type CorrectRequest struct {
	RunID string `json:"run_id"`
	// Message is the correction. It travels as data inside the host's
	// control-message frame, never as a command line (AC3 of CDT-648).
	Message string `json:"message"`
	// Host, when the chief holds no record of the run's start — a chief
	// restarted between the start and the correction — names the frame
	// encoder. Empty derives the host from the run's recorded start argv.
	Host hostadapter.Host `json:"host,omitempty"`
	// SessionID overrides the captured session id (the ACP transport names
	// the session in the frame; the other hosts ignore it).
	SessionID string `json:"session_id,omitempty"`
}

// Correct sends one correction to a running session at its next step
// boundary, without interrupting a turn (AC4): the C6 steer path — the host
// adapter encodes the host's control-message frame and hands it to the node
// agent's steer verb — unchanged.
func (c *Chief) Correct(ctx context.Context, req CorrectRequest) error {
	if req.RunID == "" || req.Message == "" {
		return fmt.Errorf("%w: a correction needs a run and a message", ErrInvalid)
	}
	host, session := req.Host, req.SessionID
	c.mu.Lock()
	rec, ok := c.runs[req.RunID]
	c.mu.Unlock()
	if ok {
		if host == "" {
			host = rec.Host
		}
		if session == "" && rec.Cap != nil {
			session = rec.Cap.SessionID()
		}
	}
	if host == "" {
		h, err := c.hostFromJournal(ctx, req.RunID)
		if err != nil {
			return err
		}
		host = h
	}
	return c.Adapter.Steer(ctx, c.eng, hostadapter.SteerRequest{
		RunID: req.RunID, Host: host, SessionID: session, Message: req.Message,
	})
}

// hostFromJournal derives the host of a run from its recorded start argv —
// the spawn intent carries the command the adapter launched. The fold is the
// detail view's (detailFold): one host fold for both readers, and its
// newest-start-row-wins rule is the one a correction needs, so a taken-over
// run is steered on the host of its current attempt.
func (c *Chief) hostFromJournal(ctx context.Context, runID string) (hostadapter.Host, error) {
	events, err := c.eng.Events(ctx, runID)
	if err != nil {
		return "", err
	}
	if len(events) == 0 {
		return "", fmt.Errorf("%w: %s", ErrUnknownRun, runID)
	}
	host, _ := detailFold(events)
	if host == "" {
		return "", fmt.Errorf("%w: %s names no known host command in its start record; pass host on the correction",
			ErrNotSteerable, runID)
	}
	return host, nil
}

// hostByCommand maps the adapter's launch commands back to their hosts —
// the same commands the adapter's per-host specs launch.
func hostByCommand(command string) (hostadapter.Host, bool) {
	switch command {
	case "claude":
		return hostadapter.HostClaudeCode, true
	case "grok":
		return hostadapter.HostGrok, true
	case "omp":
		return hostadapter.HostOmp, true
	default:
		return "", false
	}
}

// RunStatus is one run the Chief reports: the replayed journal state plus
// the queue state of its runner.
type RunStatus struct {
	RunID           string      `json:"run_id"`
	State           string      `json:"state"`
	Ticket          string      `json:"ticket,omitempty"`
	Workflow        string      `json:"workflow,omitempty"`
	Model           string      `json:"model,omitempty"`
	Owner           string      `json:"owner,omitempty"`
	Stint           int         `json:"stint,omitempty"`
	LastHeartbeatTS string      `json:"last_heartbeat_ts,omitempty"`
	Halt            *HaltReport `json:"halt,omitempty"`
	// Slot is the runner's queue state — held, waiting, or released (the
	// C5 vocabulary); empty when the run holds no slot.
	Slot string `json:"slot,omitempty"`
	// Phase is the run's current phase (the board's AC): the lifecycle
	// vertex the run's latest C3 phase event names. Empty when the spool
	// carries no phase event for the run — the fold fails closed, and the
	// state field still says where the machine is.
	Phase string `json:"phase,omitempty"`
	// QueuePosition is the run's waiting runner's position in the queue:
	// 1-based among the waiting slots, in ledger order. 0 means the run
	// holds no waiting runner (a held or released slot queues no one).
	QueuePosition int `json:"queue_position,omitempty"`
	// RunnerType is the node's runner selection (the C4 closed set) — the
	// runner every run on this node rides. Empty when the node has no
	// selection.
	RunnerType string `json:"runner_type,omitempty"`
}

// HaltReport is one named halt: its reason and its remaining retry budget
// (AC5), plus whether the operator channel has been paged for it.
type HaltReport struct {
	RunID string `json:"run_id"`
	// Seq is the seq of the run_halted row — the key the phone channel
	// records answer.
	Seq       int64  `json:"seq"`
	Reason    string `json:"reason"`
	Detail    string `json:"detail,omitempty"`
	Budget    int    `json:"retry_budget"`
	Remaining int    `json:"retry_remaining"`
	TS        string `json:"ts"`
	Notified  bool   `json:"notified"`
}

// Runs reports every run in the journal (AC2): the replayed state of each,
// with its queue slot. The answer is the fold of the rows, never prose.
func (c *Chief) Runs(ctx context.Context) ([]RunStatus, error) {
	ids, err := c.runIDs(ctx)
	if err != nil {
		return nil, err
	}
	slots, err := c.Queue.Slots(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]RunStatus, 0, len(ids))
	for _, id := range ids {
		rs, err := c.status(ctx, id, slots)
		if err != nil {
			return nil, err
		}
		out = append(out, rs)
	}
	return out, nil
}

// Run reports one run (AC2).
func (c *Chief) Run(ctx context.Context, runID string) (RunStatus, error) {
	slots, err := c.Queue.Slots(ctx)
	if err != nil {
		return RunStatus{}, err
	}
	return c.status(ctx, runID, slots)
}

// status builds one run's status from its replay and the slot ledger.
func (c *Chief) status(ctx context.Context, runID string, slots []queue.Slot) (RunStatus, error) {
	events, err := c.eng.Events(ctx, runID)
	if err != nil {
		return RunStatus{}, err
	}
	if len(events) == 0 {
		return RunStatus{}, fmt.Errorf("%w: %s", ErrUnknownRun, runID)
	}
	st, err := c.eng.RunState(ctx, runID)
	if err != nil {
		return RunStatus{}, err
	}
	rs := RunStatus{
		RunID: runID, State: st.Name(), Ticket: st.Ticket, Workflow: st.Workflow,
		Model: st.Model, Owner: st.Owner, Stint: st.Stint, LastHeartbeatTS: st.HeartbeatTS,
		Slot:          slotState(slots, runID),
		Phase:         c.currentPhase(ctx, runID),
		QueuePosition: queuePosition(slots, runID),
		RunnerType:    c.runnerType(),
	}
	if st.Halt != nil {
		rs.Halt = &HaltReport{
			RunID: runID, Seq: st.Halt.Seq, Reason: st.Halt.Reason, Detail: st.Halt.Detail,
			Budget: st.Halt.Budget, Remaining: st.Halt.Remaining, TS: st.Halt.TS,
		}
	}
	return rs, nil
}

// slotState picks the strongest queue state a run's runners carry: a runner
// waiting on a cap outranks one holding its slot.
func slotState(slots []queue.Slot, runID string) string {
	state := ""
	for _, s := range slots {
		if s.RunID != runID {
			continue
		}
		switch s.State {
		case queue.SlotWaiting:
			return queue.SlotWaiting
		case queue.SlotHeld:
			state = queue.SlotHeld
		case queue.SlotReleased:
			if state == "" {
				state = queue.SlotReleased
			}
		}
	}
	return state
}

// Check is one run of the checks reading (AC2): the run's integrity as the
// journal carries it — the effects with no outcome yet, the reconciler
// repairs, and the watchdog reading.
type Check struct {
	RunID string `json:"run_id"`
	State string `json:"state"`
	// Stalled is the watchdog reading: the heartbeat is past the stall
	// limit the run_started row journaled.
	Stalled bool `json:"stalled"`
	// PendingEffects are the recorded effects with no outcome row — an
	// effect whose outcome never landed is the reconciler's work list.
	PendingEffects []string `json:"pending_effects,omitempty"`
	Repairs        int      `json:"repairs"`
	// Takeover is the last takeover scan's report line for this run — the
	// run it skipped (SPEC-044 M5) or refused (M6), named on the reading so
	// an operator sees why a selected run never came back (AC5). Empty for a
	// run the scan took over, and for one it never selected.
	Takeover []string `json:"takeover,omitempty"`
}

// Checks reports every run's integrity reading (AC2): the journal state,
// plus the last takeover scan's reading for the run (SPEC-044 AC5).
func (c *Chief) Checks(ctx context.Context) ([]Check, error) {
	ids, err := c.runIDs(ctx)
	if err != nil {
		return nil, err
	}
	now := c.now()
	out := make([]Check, 0, len(ids))
	for _, id := range ids {
		st, err := c.eng.RunState(ctx, id)
		if err != nil {
			return nil, err
		}
		chk := Check{RunID: id, State: st.Name(), Repairs: len(st.Repairs)}
		if st.Status == journal.StatusRunning && st.StallLimitS > 0 &&
			st.SinceHeartbeat(now) > time.Duration(st.StallLimitS)*time.Second {
			chk.Stalled = true
		}
		for _, e := range st.PendingEffects() {
			chk.PendingEffects = append(chk.PendingEffects, e.Effect+" "+e.Key)
		}
		chk.Takeover = c.takeoverReading(id)
		out = append(out, chk)
	}
	return out, nil
}

// Standup is the stand-up report (AC2): the active and the finished runs,
// their halts, and the queue — one composition of journal and queue state,
// never prose.
type Standup struct {
	GeneratedAt string       `json:"generated_at"`
	Active      []RunStatus  `json:"active"`
	Finished    []RunStatus  `json:"finished"`
	Halts       []HaltReport `json:"halts"`
	Slots       []queue.Slot `json:"slots"`
}

// Standup builds the stand-up report (AC2).
func (c *Chief) Standup(ctx context.Context) (*Standup, error) {
	runs, err := c.Runs(ctx)
	if err != nil {
		return nil, err
	}
	halts, err := c.Halts(ctx)
	if err != nil {
		return nil, err
	}
	slots, err := c.Queue.Slots(ctx)
	if err != nil {
		return nil, err
	}
	up := &Standup{
		GeneratedAt: journal.FormatTS(c.now()),
		Active:      []RunStatus{},
		Finished:    []RunStatus{},
		Halts:       halts,
		Slots:       slots,
	}
	for _, rs := range runs {
		if isTerminalState(rs.State) {
			up.Finished = append(up.Finished, rs)
		} else {
			up.Active = append(up.Active, rs)
		}
	}
	return up, nil
}

// isTerminalState reports whether a state name is one of the two terminal
// states.
func isTerminalState(state string) bool {
	return state == string(journal.StatusCompleted) || state == string(journal.StatusFailed)
}

// Graph serves the C3 lifecycle graph (the board's AC): the committed
// graph file, loaded once through control-plane/lifecycle — the only
// reader that validates it. The answer is the graph data itself, never a
// second copy of it and never a rendering of it.
func (c *Chief) Graph() (*lifecycle.Graph, error) {
	c.graphOnce.Do(func() {
		c.graphVal, c.graphErr = lifecycle.LoadDefault()
	})
	return c.graphVal, c.graphErr
}

// Halts reports every named halt in the journal (AC5): the reason and the
// remaining retry budget the halt row carries, and whether the page
// actually reached the operator — only a delivered outcome answers it.
func (c *Chief) Halts(ctx context.Context) ([]HaltReport, error) {
	halts, err := c.haltRows(ctx)
	if err != nil {
		return nil, err
	}
	delivered, err := c.deliveredKeys()
	if err != nil {
		return nil, err
	}
	out := make([]HaltReport, 0, len(halts))
	for _, h := range halts {
		h.Notified = delivered[h.key()]
		out = append(out, h)
	}
	return out, nil
}

// haltRows folds every halt row of the journal, in (run id, seq) order.
func (c *Chief) haltRows(ctx context.Context) ([]HaltReport, error) {
	ids, err := c.runIDs(ctx)
	if err != nil {
		return nil, err
	}
	var out []HaltReport
	for _, id := range ids {
		st, err := c.eng.RunState(ctx, id)
		if err != nil {
			return nil, err
		}
		for _, h := range st.Halts {
			out = append(out, HaltReport{
				RunID: id, Seq: h.Seq, Reason: h.Reason, Detail: h.Detail,
				Budget: h.Budget, Remaining: h.Remaining, TS: h.TS,
			})
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].RunID != out[j].RunID {
			return out[i].RunID < out[j].RunID
		}
		return out[i].Seq < out[j].Seq
	})
	return out, nil
}

// runIDs lists the run ids the journal carries, in first-appearance order.
func (c *Chief) runIDs(ctx context.Context) ([]string, error) {
	events, err := c.eng.AllEvents(ctx)
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	var ids []string
	for _, ev := range events {
		if !seen[ev.RunID] {
			seen[ev.RunID] = true
			ids = append(ids, ev.RunID)
		}
	}
	return ids, nil
}

// runExists reports whether the journal holds any row for a run id.
func (c *Chief) runExists(ctx context.Context, runID string) (bool, error) {
	events, err := c.eng.Events(ctx, runID)
	if err != nil {
		return false, err
	}
	return len(events) > 0, nil
}

// now is the clock of the checks and the stand-up reading.
func (c *Chief) now() time.Time {
	if c.Now == nil {
		return time.Now().UTC()
	}
	return c.Now().UTC()
}

// hostList is the closed host set, for error text.
func hostList() string {
	parts := make([]string, 0, len(hostadapter.Hosts))
	for _, h := range hostadapter.Hosts {
		parts = append(parts, string(h))
	}
	return strings.Join(parts, ", ")
}
