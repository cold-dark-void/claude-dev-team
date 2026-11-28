package journal

import (
	"encoding/json"
	"time"
)

// Status is the run position that replay derives. Named states, per CDT-643
// AC6: claimed, running, halted:<reason>, completed, failed.
type Status string

const (
	StatusNew       Status = ""          // no events yet
	StatusClaimed   Status = "claimed"   // an owner holds the lease
	StatusRunning   Status = "running"   // work is in flight
	StatusHalted    Status = "halted"    // a named halt state; see HaltReasons
	StatusCompleted Status = "completed" // terminal success
	StatusFailed    Status = "failed"    // terminal failure
)

// HaltReasons is the closed set of named halt states (AC6). Each one carries a
// reason and a retry budget in State.Halt; the budgets live in the run package.
var HaltReasons = []string{
	"stalled",             // the watchdog saw no heartbeat inside the stall limit
	"lease_lost",          // the owner's fencing token stopped matching
	"reconcile_failed",    // the reconciler could not repair the difference
	"budget_exhausted",    // the run budget ran out
	"operator_halt",       // a human stopped it
	"handshake_failed",    // the host never opened the session the client asked for (CDT-679)
	"premise_undelivered", // the session never took the work premise it started with (CDT-671)
}

func ValidHaltReason(s string) bool {
	for _, r := range HaltReasons {
		if r == s {
			return true
		}
	}
	return false
}

// Halt is one named halt state with its reason and retry budget (AC6).
type Halt struct {
	Reason string `json:"reason"`
	Detail string `json:"detail,omitempty"`
	Budget int    `json:"retry_budget"`
	// Remaining is how many resumes this halt authorises. 0 means the budget is
	// spent: the only way out is run_failed.
	Remaining int    `json:"retry_remaining"`
	TS        string `json:"ts"`
	Seq       int64  `json:"seq"`
}

// Failure is the terminal failure record.
type Failure struct {
	Reason string `json:"reason"`
	TS     string `json:"ts"`
	Seq    int64  `json:"seq"`
}

// Repair is one reconciler repair, journaled (AC5: every repair is a row).
type Repair struct {
	Seq         int64  `json:"seq"`
	TS          string `json:"ts"`
	Target      string `json:"target,omitempty"`
	Observation string `json:"observation"`
	Action      string `json:"action"`
}

// RecordedEffect is one side effect and, when it is resolved, its outcome.
// OutcomeSeq 0 means the effect is pending: an intent row exists and no outcome
// row closes it, so a crash may have landed between the intent and the effect.
// The run package's reconciler resolves it (AC5); replay only marks it.
type RecordedEffect struct {
	Seq        int64           `json:"seq"`
	TS         string          `json:"ts"`
	Effect     string          `json:"effect"`
	Key        string          `json:"key"`
	Intent     json.RawMessage `json:"intent,omitempty"`
	Outcome    json.RawMessage `json:"outcome,omitempty"`
	OutcomeSeq int64           `json:"outcome_seq,omitempty"`
	OutcomeTS  string          `json:"outcome_ts,omitempty"`
	Card       *CardRef        `json:"card,omitempty"`
}

// Pending reports whether the effect has no outcome row.
func (e RecordedEffect) Pending() bool { return e.OutcomeSeq == 0 }

// State is the projection of a run's event log. It is built only by Replay, so
// the same journal yields the same state (AC1). It carries no maps and no time
// values: every field is deterministic, comparable, and JSON-stable.
type State struct {
	RunID    string `json:"run_id"`
	Status   Status `json:"status"`
	Owner    string `json:"owner,omitempty"`
	Token    int64  `json:"token,omitempty"`
	Ticket   string `json:"ticket,omitempty"`
	Workflow string `json:"workflow,omitempty"`
	Model    string `json:"model,omitempty"`

	// StallLimitS is the watchdog's stall limit in seconds, journaled at
	// run_started. It is a journaled number, never a tuned one (AC9: CDT-610 is
	// the precondition of any wall-clock tuning).
	StallLimitS int64 `json:"stall_limit_s,omitempty"`

	// WallclockCapS and IterationCapS are the operator's per-run budget caps
	// journaled at run_started (SPEC-046 M7): wall-clock seconds and an iteration
	// count. 0 means unset, so a caps-free run keeps the plugin's own budget.
	// chiefd relays them to that run's runner environment; the plugin never
	// writes them (SPEC-033 N12) and they carry no ceiling (N14).
	WallclockCapS int64  `json:"wallclock_cap_s,omitempty"`
	IterationCapS int64  `json:"iteration_cap_s,omitempty"`
	HeartbeatTS   string `json:"last_heartbeat_ts,omitempty"`
	Stint         int    `json:"stint"`

	// ProgressTS is the last session output time, journaled by the run's own
	// run_progress rows (SPEC-044 CDT-671 AC2): the time the runner's output
	// capture last saw the host's stream. Empty is a reading, not a gap — the
	// container runner and a capture-less start carry no output capture, so
	// they carry no progress time, and nothing here stands in for one.
	ProgressTS string `json:"last_progress_ts,omitempty"`

	// ProgressLimitS is the no-progress bound in seconds, journaled at
	// run_started (SPEC-044 CDT-671 AC3): the quiet window past which the
	// checks reading flags the session. 0 means the run carries no bound, so
	// nothing is flagged. It is a journaled number, never a tuned constant in
	// the reader, and it halts nothing — StallLimitS stays the watchdog's only
	// trigger.
	ProgressLimitS int64 `json:"progress_limit_s,omitempty"`

	ClaimCount     int    `json:"claims"`
	LeaseTakeovers int    `json:"lease_takeovers"`
	EventCount     int64  `json:"events"`
	LastSeq        int64  `json:"last_seq"`
	LastTS         string `json:"last_ts,omitempty"`

	Terminal bool            `json:"terminal"`
	Halt     *Halt           `json:"halt,omitempty"`
	Failure  *Failure        `json:"failure,omitempty"`
	Result   json.RawMessage `json:"result,omitempty"`

	Effects []RecordedEffect `json:"effects,omitempty"`
	Repairs []Repair         `json:"repairs,omitempty"`
	Halts   []Halt           `json:"halts,omitempty"`
}

// Name is the state name a status surface shows: "claimed", "running",
// "halted:<reason>", "completed", "failed", "new".
func (s *State) Name() string {
	if s == nil {
		return string(StatusNew)
	}
	if s.Status == StatusHalted && s.Halt != nil {
		return string(StatusHalted) + ":" + s.Halt.Reason
	}
	if s.Status == StatusNew {
		return "new"
	}
	return string(s.Status)
}

// IsTerminal reports whether the run is finished.
func (s *State) IsTerminal() bool { return s != nil && s.Terminal }

// PendingEffects returns the side effects with no outcome row, in seq order
// (AC3 + AC5): the reconciler's work list.
func (s *State) PendingEffects() []RecordedEffect {
	if s == nil {
		return nil
	}
	var out []RecordedEffect
	for _, e := range s.Effects {
		if e.Pending() {
			out = append(out, e)
		}
	}
	return out
}

// EffectByKey returns the recorded effect for an idempotency key.
func (s *State) EffectByKey(key string) (RecordedEffect, bool) {
	if s == nil {
		return RecordedEffect{}, false
	}
	for _, e := range s.Effects {
		if e.Key == key {
			return e, true
		}
	}
	return RecordedEffect{}, false
}

// SinceHeartbeat is how long the run has gone without a heartbeat or a stint.
// A stall is judged against State.StallLimitS.
func (s *State) SinceHeartbeat(now time.Time) time.Duration {
	if s == nil {
		return 0
	}
	ts := s.HeartbeatTS
	if ts == "" {
		ts = s.LastTS
	}
	t, err := time.Parse(tsLayout, ts)
	if err != nil {
		return 0
	}
	d := now.UTC().Sub(t)
	if d < 0 {
		return 0
	}
	return d
}

// SinceProgress is how long the run's session has gone with no output. A run
// that carries no progress time has no reading to judge, so the answer is 0
// (SPEC-044 CDT-671 AC2: never a guess). A stall is judged against
// State.StallLimitS; this is a separate signal and halts nothing.
func (s *State) SinceProgress(now time.Time) time.Duration {
	if s == nil || s.ProgressTS == "" {
		return 0
	}
	t, err := time.Parse(tsLayout, s.ProgressTS)
	if err != nil {
		return 0
	}
	d := now.UTC().Sub(t)
	if d < 0 {
		return 0
	}
	return d
}

// clone deep-copies the state so ReplayFrom never mutates a caller's snapshot.
func (s *State) clone() *State {
	if s == nil {
		return nil
	}
	out := *s
	if s.Halt != nil {
		h := *s.Halt
		out.Halt = &h
	}
	if s.Failure != nil {
		f := *s.Failure
		out.Failure = &f
	}
	out.Effects = cloneSlice(s.Effects)
	out.Repairs = cloneSlice(s.Repairs)
	out.Halts = cloneSlice(s.Halts)
	if s.Result != nil {
		out.Result = append(json.RawMessage(nil), s.Result...)
	}
	for i := range out.Effects {
		out.Effects[i].Intent = append(json.RawMessage(nil), s.Effects[i].Intent...)
		out.Effects[i].Outcome = append(json.RawMessage(nil), s.Effects[i].Outcome...)
		if s.Effects[i].Card != nil {
			c := *s.Effects[i].Card
			out.Effects[i].Card = &c
		}
	}
	return &out
}

func cloneSlice[T any](in []T) []T {
	if in == nil {
		return nil
	}
	return append(make([]T, 0, len(in)), in...)
}
