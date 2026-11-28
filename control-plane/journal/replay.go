package journal

import (
	"encoding/json"
	"fmt"
)

// Event payloads. They are the payload contract for the closed kind set in
// schema.sql; the run package appends with these types.

// ClaimPayload is run_claimed: an owner takes the run under a fencing token.
type ClaimPayload struct {
	Owner    string `json:"owner"`
	Token    int64  `json:"token"`
	Ticket   string `json:"ticket,omitempty"`
	Workflow string `json:"workflow,omitempty"`
	Model    string `json:"model,omitempty"`
}

// LeasePayload is lease_acquired: a lease changes hands. Reason is "claim",
// "takeover", or "renew".
type LeasePayload struct {
	Owner  string `json:"owner"`
	Token  int64  `json:"token"`
	Reason string `json:"reason"`
}

// StartPayload is run_started. StallLimitS is the journaled watchdog limit.
// WallclockCapS and IterationCapS are the operator's per-run budget caps
// (SPEC-046 M7): wall-clock seconds and an iteration count. They are optional —
// an absent key, like an explicit 0, means unset, so every run_started row
// written before SPEC-046 replays unchanged.
type StartPayload struct {
	StallLimitS   int64  `json:"stall_limit_s"`
	Model         string `json:"model,omitempty"`
	WallclockCapS int64  `json:"wallclock_cap_s,omitempty"`
	IterationCapS int64  `json:"iteration_cap_s,omitempty"`
	// ProgressLimitS is the no-progress bound in seconds (SPEC-044 CDT-671 AC3):
	// how long a running session may go with no output before the checks reading
	// flags it. It flags, it does not halt — StallLimitS stays the watchdog's
	// only trigger. Optional, like the caps: an absent key means the run carries
	// no bound, so every pre-CDT-671 run_started row replays unchanged.
	ProgressLimitS int64 `json:"progress_limit_s,omitempty"`
}

// StintPayload is stint_started. Stint is 1-based and strictly sequential.
type StintPayload struct {
	Stint int    `json:"stint"`
	Label string `json:"label,omitempty"`
}

// HeartbeatPayload is heartbeat: the owner proves it holds the token it claims.
type HeartbeatPayload struct {
	Owner string `json:"owner"`
	Token int64  `json:"token"`
}

// ProgressPayload is run_progress: the time the runner's output capture last
// saw the host's stream (SPEC-044 CDT-671 AC2). It is a reading, not liveness —
// a run can progress with no heartbeat and beat with no progress — so the row
// never refreshes State.HeartbeatTS. LastOutputTS is required: a runner with no
// output capture journals no row, so no row ever carries a guessed time.
type ProgressPayload struct {
	LastOutputTS string `json:"last_output_ts"`
}

// HaltPayload is run_halted: a named halt state with a reason and a retry
// budget (AC6). RetryRemaining is the writer's count of authorised resumes
// left; Replay re-derives it from the halt history and refuses a mismatch.
type HaltPayload struct {
	Reason         string `json:"reason"`
	Detail         string `json:"detail,omitempty"`
	RetryBudget    int    `json:"retry_budget"`
	RetryRemaining int    `json:"retry_remaining"`
}

// ResumePayload is run_resumed: leaving a named halt state spends one retry.
type ResumePayload struct {
	Reason string `json:"reason"`
}

// RepairPayload is repair: one reconciler repair, journaled (AC5).
type RepairPayload struct {
	Target      string `json:"target,omitempty"`
	Observation string `json:"observation"`
	Action      string `json:"action"`
}

// CompletePayload is run_completed.
type CompletePayload struct {
	Result json.RawMessage `json:"result,omitempty"`
}

// FailPayload is run_failed.
type FailPayload struct {
	Reason string `json:"reason"`
}

// Replay projects an event log into run state (AC1). It is a pure function: the
// events are the only input, the log order is the only clock, and no field is
// read from the environment, so the same journal yields the same state.
//
// The events must belong to one run and arrive in ascending seq order.
func Replay(events []Event) (*State, error) {
	return ReplayFrom(nil, events)
}

// ReplayFrom continues a replay from a snapshot. base is not modified, so
// ReplayFrom(Replay(events[:k]), events[k:]) equals Replay(events) for every k —
// the mid-replay snapshot property the kill test depends on.
func ReplayFrom(base *State, events []Event) (*State, error) {
	st := base.clone()
	if st == nil {
		st = &State{}
	}
	for _, ev := range events {
		if err := st.apply(ev); err != nil {
			return nil, fmt.Errorf("journal: replay seq %d (%s): %w", ev.Seq, ev.Kind, err)
		}
	}
	return st, nil
}

// apply folds one event into the state. Every kind in the closed set is handled;
// anything else is an error, never a silent no-op.
func (s *State) apply(ev Event) error {
	if err := ev.Validate(); err != nil {
		return err
	}
	if ev.Seq != 0 && ev.Seq <= s.LastSeq {
		return fmt.Errorf("%w: seq %d follows %d", ErrReplayInconsistent, ev.Seq, s.LastSeq)
	}
	if s.RunID == "" {
		s.RunID = ev.RunID
	} else if s.RunID != ev.RunID {
		return fmt.Errorf("%w: event for run %q inside run %q",
			ErrReplayInconsistent, ev.RunID, s.RunID)
	}
	if s.Terminal {
		return fmt.Errorf("%w: %s after %s", ErrTerminalState, ev.Kind, s.Name())
	}

	switch ev.Kind {
	case KindRunClaimed:
		return s.applyClaim(ev)
	case KindLeaseAcquire:
		return s.applyLeaseAcquired(ev)
	case KindRunStarted:
		return s.applyStarted(ev)
	case KindStintStarted:
		return s.applyStint(ev)
	case KindHeartbeat:
		return s.applyHeartbeat(ev)
	case KindRunProgress:
		return s.applyProgress(ev)
	case KindSideEffect:
		return s.applySideEffect(ev)
	case KindRunHalted:
		return s.applyHalted(ev)
	case KindRunResumed:
		return s.applyResumed(ev)
	case KindRepair:
		return s.applyRepair(ev)
	case KindRunCompleted:
		return s.applyCompleted(ev)
	case KindRunFailed:
		return s.applyFailed(ev)
	default:
		return fmt.Errorf("%w: kind %q has no replay rule", ErrReplayInconsistent, ev.Kind)
	}
}

// touch records the log position shared by every kind.
func (s *State) touch(ev Event) {
	s.EventCount++
	s.LastSeq = ev.Seq
	s.LastTS = ev.TS
}

func (s *State) applyClaim(ev Event) error {
	var p ClaimPayload
	if err := json.Unmarshal(ev.Payload, &p); err != nil {
		return fmt.Errorf("%w: run_claimed: %v", ErrReplayInconsistent, err)
	}
	if p.Owner == "" || p.Token < 1 {
		return fmt.Errorf("%w: run_claimed needs owner and token >= 1", ErrReplayInconsistent)
	}
	if s.Status == StatusNew {
		s.Owner, s.Token = p.Owner, p.Token
		s.Ticket, s.Workflow, s.Model = p.Ticket, p.Workflow, p.Model
		s.Status = StatusClaimed
		s.ClaimCount = 1
		s.touch(ev)
		return nil
	}
	// A second claim is a re-claim of the same run after a crash: the token must
	// move forward, and the run's identity stays fixed (AC4).
	if p.Token <= s.Token {
		return fmt.Errorf("%w: re-claim token %d, current %d", ErrStaleToken, p.Token, s.Token)
	}
	if p.Ticket != s.Ticket || p.Workflow != s.Workflow {
		return fmt.Errorf("%w: re-claim changes ticket/workflow %q/%q -> %q/%q",
			ErrReplayInconsistent, s.Ticket, s.Workflow, p.Ticket, p.Workflow)
	}
	s.Owner, s.Token, s.Model = p.Owner, p.Token, p.Model
	s.ClaimCount++
	// A takeover moves ownership only. It does not leave a halt state: only
	// run_resumed does that, and it spends the reason's retry budget (AC6).
	s.touch(ev)
	return nil
}

func (s *State) applyLeaseAcquired(ev Event) error {
	var p LeasePayload
	if err := json.Unmarshal(ev.Payload, &p); err != nil {
		return fmt.Errorf("%w: lease_acquired: %v", ErrReplayInconsistent, err)
	}
	if p.Owner == "" || p.Token < 1 {
		return fmt.Errorf("%w: lease_acquired needs owner and token >= 1", ErrReplayInconsistent)
	}
	if s.Status == StatusNew {
		return fmt.Errorf("%w: lease_acquired before run_claimed", ErrReplayInconsistent)
	}
	if p.Token <= s.Token {
		return fmt.Errorf("%w: token %d, current %d", ErrStaleToken, p.Token, s.Token)
	}
	s.Owner, s.Token = p.Owner, p.Token
	s.LeaseTakeovers++
	// Ownership moves; the state does not. A run halted for a reason stays
	// halted until run_resumed spends that reason's retry budget (AC6).
	s.touch(ev)
	return nil
}

func (s *State) applyStarted(ev Event) error {
	var p StartPayload
	if err := json.Unmarshal(ev.Payload, &p); err != nil {
		return fmt.Errorf("%w: run_started: %v", ErrReplayInconsistent, err)
	}
	if p.StallLimitS < 1 {
		return fmt.Errorf("%w: run_started needs stall_limit_s >= 1", ErrReplayInconsistent)
	}
	// The caps are optional and 0 is the unset encoding, so only a negative
	// one is inconsistent (SPEC-046 M7).
	if p.WallclockCapS < 0 || p.IterationCapS < 0 {
		return fmt.Errorf("%w: run_started needs a non-negative wallclock_cap_s (%d) and iteration_cap_s (%d)",
			ErrReplayInconsistent, p.WallclockCapS, p.IterationCapS)
	}
	// The no-progress bound is optional and 0 is the unset encoding, so only a
	// negative one is inconsistent (SPEC-044 CDT-671 AC3).
	if p.ProgressLimitS < 0 {
		return fmt.Errorf("%w: run_started needs a non-negative progress_limit_s (%d)",
			ErrReplayInconsistent, p.ProgressLimitS)
	}
	if s.Status != StatusClaimed {
		return fmt.Errorf("%w: run_started from %s", ErrTransition, s.Name())
	}
	s.StallLimitS = p.StallLimitS
	s.WallclockCapS = p.WallclockCapS
	s.IterationCapS = p.IterationCapS
	s.ProgressLimitS = p.ProgressLimitS
	if p.Model != "" {
		s.Model = p.Model
	}
	s.Status = StatusRunning
	s.HeartbeatTS = ev.TS
	s.touch(ev)
	return nil
}

func (s *State) applyStint(ev Event) error {
	var p StintPayload
	if err := json.Unmarshal(ev.Payload, &p); err != nil {
		return fmt.Errorf("%w: stint_started: %v", ErrReplayInconsistent, err)
	}
	if s.Status != StatusRunning {
		return fmt.Errorf("%w: stint_started from %s", ErrTransition, s.Name())
	}
	if p.Stint != s.Stint+1 {
		return fmt.Errorf("%w: stint %d after %d", ErrReplayInconsistent, p.Stint, s.Stint)
	}
	s.Stint = p.Stint
	// Progress is liveness: a stint is a heartbeat.
	s.HeartbeatTS = ev.TS
	s.touch(ev)
	return nil
}

func (s *State) applyHeartbeat(ev Event) error {
	var p HeartbeatPayload
	if err := json.Unmarshal(ev.Payload, &p); err != nil {
		return fmt.Errorf("%w: heartbeat: %v", ErrReplayInconsistent, err)
	}
	if s.Status != StatusRunning {
		return fmt.Errorf("%w: heartbeat from %s", ErrTransition, s.Name())
	}
	if p.Token != s.Token || p.Owner != s.Owner {
		return fmt.Errorf("%w: heartbeat token %d owner %q, current token %d owner %q",
			ErrStaleToken, p.Token, p.Owner, s.Token, s.Owner)
	}
	s.HeartbeatTS = ev.TS
	s.touch(ev)
	return nil
}

// applyProgress folds one run_progress row in (SPEC-044 CDT-671 AC2). The row
// is legal from running only — a claimed run has no session to read output
// from — and it moves the progress reading alone: HeartbeatTS is untouched, so
// the watchdog keeps its own input.
func (s *State) applyProgress(ev Event) error {
	var p ProgressPayload
	if err := json.Unmarshal(ev.Payload, &p); err != nil {
		return fmt.Errorf("%w: run_progress: %v", ErrReplayInconsistent, err)
	}
	if s.Status != StatusRunning {
		return fmt.Errorf("%w: run_progress from %s", ErrTransition, s.Name())
	}
	if _, err := ParseTS(p.LastOutputTS); err != nil {
		return fmt.Errorf("%w: run_progress needs a canonical last_output_ts (%q)",
			ErrReplayInconsistent, p.LastOutputTS)
	}
	s.ProgressTS = p.LastOutputTS
	s.touch(ev)
	return nil
}

func (s *State) applySideEffect(ev Event) error {
	var p Effect
	if err := json.Unmarshal(ev.Payload, &p); err != nil {
		return fmt.Errorf("%w: side_effect: %v", ErrReplayInconsistent, err)
	}
	if s.Status != StatusRunning {
		return fmt.Errorf("%w: side_effect from %s", ErrTransition, s.Name())
	}

	if p.IntentSeq == 0 {
		// Intent row. The key is what makes a replay safe (AC3).
		if ev.IdempotencyKey == "" {
			return fmt.Errorf("%w: side_effect intent needs an idempotency key", ErrReplayInconsistent)
		}
		if _, found := s.EffectByKey(ev.IdempotencyKey); found {
			return fmt.Errorf("%w: %s", ErrDuplicateKey, ev.IdempotencyKey)
		}
		s.Effects = append(s.Effects, RecordedEffect{
			Seq:    ev.Seq,
			TS:     ev.TS,
			Effect: p.Effect,
			Key:    ev.IdempotencyKey,
			Intent: append(json.RawMessage(nil), p.Intent...),
			Card:   copyCard(ev.Card),
		})
		s.touch(ev)
		return nil
	}

	// Outcome row: it closes the intent at IntentSeq.
	for i := range s.Effects {
		if s.Effects[i].Seq != p.IntentSeq {
			continue
		}
		if !s.Effects[i].Pending() {
			return fmt.Errorf("%w: effect seq %d already has an outcome",
				ErrReplayInconsistent, p.IntentSeq)
		}
		if p.Effect != s.Effects[i].Effect {
			return fmt.Errorf("%w: outcome effect %q closes intent effect %q",
				ErrReplayInconsistent, p.Effect, s.Effects[i].Effect)
		}
		s.Effects[i].Outcome = append(json.RawMessage(nil), p.Outcome...)
		s.Effects[i].OutcomeSeq = ev.Seq
		s.Effects[i].OutcomeTS = ev.TS
		s.touch(ev)
		return nil
	}
	return fmt.Errorf("%w: outcome for unknown intent seq %d", ErrReplayInconsistent, p.IntentSeq)
}

func (s *State) applyHalted(ev Event) error {
	var p HaltPayload
	if err := json.Unmarshal(ev.Payload, &p); err != nil {
		return fmt.Errorf("%w: run_halted: %v", ErrReplayInconsistent, err)
	}
	if !ValidHaltReason(p.Reason) {
		return fmt.Errorf("%w: halt reason %q is not in the closed set", ErrReplayInconsistent, p.Reason)
	}
	if s.Status != StatusClaimed && s.Status != StatusRunning {
		return fmt.Errorf("%w: run_halted from %s", ErrTransition, s.Name())
	}
	if p.RetryBudget < 0 {
		return fmt.Errorf("%w: retry_budget %d", ErrReplayInconsistent, p.RetryBudget)
	}
	prior := 0
	for _, h := range s.Halts {
		if h.Reason == p.Reason {
			prior++
		}
	}
	// The k-th halt of a reason leaves budget-(k-1) resumes.
	want := p.RetryBudget - prior
	if p.RetryRemaining != want {
		return fmt.Errorf("%w: %s halt %d reports retry_remaining %d, replay derives %d",
			ErrReplayInconsistent, p.Reason, prior+1, p.RetryRemaining, want)
	}
	h := Halt{
		Reason:    p.Reason,
		Detail:    p.Detail,
		Budget:    p.RetryBudget,
		Remaining: p.RetryRemaining,
		TS:        ev.TS,
		Seq:       ev.Seq,
	}
	s.Halts = append(s.Halts, h)
	s.Halt = &h
	s.Status = StatusHalted
	s.touch(ev)
	return nil
}

func (s *State) applyResumed(ev Event) error {
	var p ResumePayload
	if err := json.Unmarshal(ev.Payload, &p); err != nil {
		return fmt.Errorf("%w: run_resumed: %v", ErrReplayInconsistent, err)
	}
	if s.Status != StatusHalted || s.Halt == nil {
		return fmt.Errorf("%w: run_resumed from %s", ErrTransition, s.Name())
	}
	if p.Reason != s.Halt.Reason {
		return fmt.Errorf("%w: resume %q, halted %q", ErrReplayInconsistent, p.Reason, s.Halt.Reason)
	}
	if s.Halt.Remaining < 1 {
		return fmt.Errorf("%w: %s budget %d is spent", ErrBudgetExhausted, s.Halt.Reason, s.Halt.Budget)
	}
	s.Status = StatusRunning
	s.Halt = nil
	s.HeartbeatTS = ev.TS
	s.touch(ev)
	return nil
}

func (s *State) applyRepair(ev Event) error {
	var p RepairPayload
	if err := json.Unmarshal(ev.Payload, &p); err != nil {
		return fmt.Errorf("%w: repair: %v", ErrReplayInconsistent, err)
	}
	if p.Observation == "" || p.Action == "" {
		return fmt.Errorf("%w: repair needs observation and action", ErrReplayInconsistent)
	}
	s.Repairs = append(s.Repairs, Repair{
		Seq:         ev.Seq,
		TS:          ev.TS,
		Target:      p.Target,
		Observation: p.Observation,
		Action:      p.Action,
	})
	s.touch(ev)
	return nil
}

func (s *State) applyCompleted(ev Event) error {
	var p CompletePayload
	if err := json.Unmarshal(ev.Payload, &p); err != nil {
		return fmt.Errorf("%w: run_completed: %v", ErrReplayInconsistent, err)
	}
	if s.Status != StatusRunning {
		return fmt.Errorf("%w: run_completed from %s", ErrTransition, s.Name())
	}
	s.Status = StatusCompleted
	s.Terminal = true
	s.Result = append(json.RawMessage(nil), p.Result...)
	s.touch(ev)
	return nil
}

func (s *State) applyFailed(ev Event) error {
	var p FailPayload
	if err := json.Unmarshal(ev.Payload, &p); err != nil {
		return fmt.Errorf("%w: run_failed: %v", ErrReplayInconsistent, err)
	}
	if p.Reason == "" {
		return fmt.Errorf("%w: run_failed needs a reason", ErrReplayInconsistent)
	}
	s.Status = StatusFailed
	s.Terminal = true
	s.Failure = &Failure{Reason: p.Reason, TS: ev.TS, Seq: ev.Seq}
	s.touch(ev)
	return nil
}

func copyCard(c *CardRef) *CardRef {
	if c == nil {
		return nil
	}
	out := *c
	return &out
}
