package run

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"time"

	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
)

// Machine drives one run. It holds no state: the journal is the state
// (journal.Replay), so a restarted process picks the run up at the same
// position (AC1, AC7).
type Machine struct {
	eng   *journal.Engine
	runID string

	// Now is the clock, injectable so a test can move past a stall limit
	// instead of sleeping. UTC is applied at use.
	Now func() time.Time
	// Getenv resolves the run-budget env layer. Defaults to os.Getenv.
	Getenv func(string) string
}

// New returns a machine for runID.
func New(eng *journal.Engine, runID string) *Machine {
	return &Machine{eng: eng, runID: runID, Now: time.Now, Getenv: os.Getenv}
}

// RunID is the run this machine drives.
func (m *Machine) RunID() string { return m.runID }

func (m *Machine) now() time.Time {
	if m.Now == nil {
		return time.Now().UTC()
	}
	return m.Now().UTC()
}

func (m *Machine) getenv() func(string) string {
	if m.Getenv == nil {
		return os.Getenv
	}
	return m.Getenv
}

// stallLimit resolves the watchdog limit for a model: env > map > tier (AC6).
func (m *Machine) stallLimit(model string) (time.Duration, string, error) {
	return ResolveStallLimit(model, m.getenv())
}

// State replays the run's journal.
func (m *Machine) State(ctx context.Context) (*journal.State, error) {
	return m.eng.RunState(ctx, m.runID)
}

// event builds an event timestamped by the machine clock.
func (m *Machine) event(kind journal.Kind, payload any) (journal.Event, error) {
	ev, err := journal.NewEvent(m.runID, kind, payload)
	if err != nil {
		return journal.Event{}, err
	}
	ev.TS = journal.FormatTS(m.now())
	return ev, nil
}

// transition is one state change: the event that records it, and an optional
// write that lands with it inside the same transaction (lease release, lease
// heartbeat).
type transition struct {
	event journal.Event
	after func(ctx context.Context, tx *journal.Tx, seq int64) error
}

func then(ev journal.Event) transition { return transition{event: ev} }

// mutate is the transition primitive: one BEGIN IMMEDIATE transaction that
// checks the fencing token, replays the run, appends the transition event only
// if replay accepts it, and applies the after-write. Any error rolls the whole
// transaction back, so an invalid transition writes nothing (AC1) and a stale
// token writes nothing (AC4).
func (m *Machine) mutate(ctx context.Context, owner string, token int64,
	build func(ctx context.Context, tx *journal.Tx, st *journal.State) (transition, error)) (int64, bool, error) {
	var (
		seq     int64
		created bool
	)
	err := m.eng.Transact(ctx, func(tx *journal.Tx) error {
		st, err := m.replay(ctx, tx)
		if err != nil {
			return err
		}
		// A terminal run answers terminal, not "no lease": it released its
		// lease on the way out, and it accepts no further event (AC7).
		if st.IsTerminal() {
			return fmt.Errorf("%w: run %s is %s", journal.ErrTerminalState, m.runID, st.Name())
		}
		if _, err := verifyLease(ctx, tx, m.runID, owner, token); err != nil {
			return err
		}
		tr, err := build(ctx, tx, st)
		if err != nil {
			return err
		}
		seq, created, err = tx.AppendChecked(ctx, tr.event)
		if err != nil {
			return err
		}
		if tr.after == nil {
			return nil
		}
		return tr.after(ctx, tx, seq)
	})
	return seq, created, err
}

func (m *Machine) replay(ctx context.Context, tx *journal.Tx) (*journal.State, error) {
	events, err := tx.Events(ctx, m.runID)
	if err != nil {
		return nil, err
	}
	return journal.Replay(events)
}

// Claim takes the lease and journals it. It returns the fencing token the
// caller must present on every later call (AC4).
//
// A live lease owned by someone else is refused with journal.ErrLeaseHeld. An
// expired one is taken over at token+1, so every write the old owner attempts
// afterwards is refused as stale. Claiming a terminal run is refused.
func (m *Machine) Claim(ctx context.Context, owner, ticket, workflow, model string) (int64, error) {
	var token int64
	err := m.eng.Transact(ctx, func(tx *journal.Tx) error {
		st, err := m.replay(ctx, tx)
		if err != nil {
			return err
		}
		if st.IsTerminal() {
			return fmt.Errorf("%w: run %s is %s", journal.ErrTerminalState, m.runID, st.Name())
		}
		limit, _, err := m.stallLimit(model)
		if err != nil {
			return err
		}
		tok, how, err := acquireLease(ctx, tx, m.runID, owner, limit, m.now())
		if err != nil {
			return err
		}
		token = tok

		switch how {
		case leaseTakeover:
			ev, err := m.event(journal.KindLeaseAcquire,
				journal.LeasePayload{Owner: owner, Token: tok, Reason: how})
			if err != nil {
				return err
			}
			_, _, err = tx.AppendChecked(ctx, ev)
			return err
		case leaseNew, leaseSelf:
			if st.Status != journal.StatusNew {
				// Already claimed by this owner: a re-claim writes nothing.
				return nil
			}
			ev, err := m.event(journal.KindRunClaimed, journal.ClaimPayload{
				Owner: owner, Token: tok, Ticket: ticket, Workflow: workflow, Model: model,
			})
			if err != nil {
				return err
			}
			_, _, err = tx.AppendChecked(ctx, ev)
			return err
		}
		return fmt.Errorf("%w: unknown lease acquisition %q", journal.ErrInvalid, how)
	})
	if err != nil {
		return 0, err
	}
	return token, nil
}

// Start moves claimed → running and journals the stall limit the watchdog uses.
// The limit follows env > map > tier (AC6). CDT-610 gates any change to the
// numbers behind it: phase 1 tunes none of them (AC9).
func (m *Machine) Start(ctx context.Context, owner string, token int64, model string) error {
	secs, _, err := StallLimitSeconds(model, m.getenv())
	if err != nil {
		return err
	}
	_, _, err = m.mutate(ctx, owner, token,
		func(_ context.Context, _ *journal.Tx, _ *journal.State) (transition, error) {
			ev, err := m.event(journal.KindRunStarted,
				journal.StartPayload{StallLimitS: secs, Model: model})
			if err != nil {
				return transition{}, err
			}
			return then(ev), nil
		})
	return err
}

// Stint journals the start of the next stint. Progress counts as liveness: a
// stint refreshes the watchdog.
func (m *Machine) Stint(ctx context.Context, owner string, token int64, label string) error {
	_, _, err := m.mutate(ctx, owner, token,
		func(_ context.Context, _ *journal.Tx, st *journal.State) (transition, error) {
			ev, err := m.event(journal.KindStintStarted,
				journal.StintPayload{Stint: st.Stint + 1, Label: label})
			if err != nil {
				return transition{}, err
			}
			return then(ev), nil
		})
	return err
}

// Heartbeat records that the owner is alive inside the stall limit (AC6). The
// lease write is a compare-and-set on (owner, token), so a run that was taken
// over answers journal.ErrStaleToken and writes nothing.
func (m *Machine) Heartbeat(ctx context.Context, owner string, token int64) error {
	_, _, err := m.mutate(ctx, owner, token,
		func(ctx context.Context, tx *journal.Tx, _ *journal.State) (transition, error) {
			ev, err := m.event(journal.KindHeartbeat,
				journal.HeartbeatPayload{Owner: owner, Token: token})
			if err != nil {
				return transition{}, err
			}
			return transition{
				event: ev,
				after: func(ctx context.Context, tx *journal.Tx, _ int64) error {
					return beatLease(ctx, tx, m.runID, owner, token, m.now())
				},
			}, nil
		})
	return err
}

// Named halt states (AC6).
const (
	ReasonStalled         = "stalled"
	ReasonLeaseLost       = "lease_lost"
	ReasonReconcileFailed = "reconcile_failed"
	ReasonBudgetExhausted = "budget_exhausted"
	ReasonOperatorHalt    = "operator_halt"
)

// errNotStalled cancels a watchdog halt inside the transaction. It is not a
// failure: the run proved alive between the liveness read and the halt, so the
// watchdog writes nothing and spends no retry budget.
var errNotStalled = errors.New("run: stall limit not passed")

// Watchdog compares the run's liveness with its stall limit and journals the
// named halt state when the limit is passed (AC6). It returns true when it
// halted the run.
//
// The read outside the transaction is a filter, not the decision. stallGate
// re-checks liveness inside the same BEGIN IMMEDIATE as the halt event, so a
// heartbeat that lands in between cancels the stall and costs no retry budget.
func (m *Machine) Watchdog(ctx context.Context, owner string, token int64) (bool, error) {
	st, err := m.State(ctx)
	if err != nil {
		return false, err
	}
	limit, quiet, stalled := stallReading(st, m.now())
	if !stalled {
		return false, nil
	}
	detail := fmt.Sprintf("no heartbeat for %s, stall limit %s (last liveness %s)",
		quiet, limit, st.HeartbeatTS)
	_, _, err = m.halt(ctx, owner, token, ReasonStalled, detail, m.stallGate())
	switch {
	case errors.Is(err, errNotStalled):
		return false, nil
	case err != nil:
		return false, err
	}
	return true, nil
}

// stallReading is the watchdog's reading of a replayed state: the limit, how
// long the run has been quiet, and whether that quiet period passes the limit.
func stallReading(st *journal.State, now time.Time) (limit, quiet time.Duration, stalled bool) {
	if st.Status != journal.StatusRunning || st.StallLimitS <= 0 {
		return 0, 0, false
	}
	limit = time.Duration(st.StallLimitS) * time.Second
	quiet = st.SinceHeartbeat(now)
	return limit, quiet, quiet > limit
}

// stallGate is the halt gate the watchdog passes: the liveness re-check that
// runs inside the halt transaction, over the replayed state and over the lease
// row. Both must say the owner is gone.
func (m *Machine) stallGate() haltGate {
	return func(ctx context.Context, tx *journal.Tx, st *journal.State) error {
		if _, _, stalled := stallReading(st, m.now()); !stalled {
			return errNotStalled
		}
		l, err := readLease(ctx, tx, m.runID)
		if errors.Is(err, journal.ErrNoLease) {
			return errNotStalled
		}
		if err != nil {
			return err
		}
		if !l.Expired(m.now()) {
			return errNotStalled
		}
		return nil
	}
}

// haltGate is an optional gate a caller adds to the halt transaction. It runs
// after the fencing check and before the halt event is appended: a gate error
// rolls the transaction back, so the run keeps its retry budget.
type haltGate func(ctx context.Context, tx *journal.Tx, st *journal.State) error

// Halt moves the run to halted:<reason> and journals the reason with its retry
// budget (AC6). When that reason's budget is already spent it refuses and
// writes nothing: the caller fails the run instead.
func (m *Machine) Halt(ctx context.Context, owner string, token int64, reason, detail string) error {
	_, _, err := m.halt(ctx, owner, token, reason, detail, nil)
	return err
}

// halt is the Halt primitive. gate, when non-nil, runs inside the same
// transaction as the halt event.
func (m *Machine) halt(ctx context.Context, owner string, token int64, reason, detail string,
	gate haltGate) (int64, bool, error) {
	budget, err := RetryBudget(reason)
	if err != nil {
		return 0, false, err
	}
	_, _, err = m.mutate(ctx, owner, token,
		func(ctx context.Context, tx *journal.Tx, st *journal.State) (transition, error) {
			if gate != nil {
				if err := gate(ctx, tx, st); err != nil {
					return transition{}, err
				}
			}
			prior := 0
			for _, h := range st.Halts {
				if h.Reason == reason {
					prior++
				}
			}
			remaining := budget - prior
			if remaining < 0 {
				return transition{}, fmt.Errorf("%w: %s budget %d is spent (halt %d)",
					journal.ErrBudgetExhausted, reason, budget, prior+1)
			}
			ev, err := m.event(journal.KindRunHalted, journal.HaltPayload{
				Reason: reason, Detail: detail, RetryBudget: budget, RetryRemaining: remaining,
			})
			if err != nil {
				return transition{}, err
			}
			return then(ev), nil
		})
	return 0, false, err
}

// Resume leaves a named halt state and spends one retry of that reason (AC6).
func (m *Machine) Resume(ctx context.Context, owner string, token int64) error {
	_, _, err := m.mutate(ctx, owner, token,
		func(_ context.Context, _ *journal.Tx, st *journal.State) (transition, error) {
			if st.Halt == nil {
				return transition{}, fmt.Errorf("%w: resume from %s", journal.ErrTransition, st.Name())
			}
			ev, err := m.event(journal.KindRunResumed, journal.ResumePayload{Reason: st.Halt.Reason})
			if err != nil {
				return transition{}, err
			}
			return then(ev), nil
		})
	return err
}

// Intent records a side effect before performing it (AC3; the SPEC-040 AC11
// intent-then-outcome pattern). key is the idempotency key: a second call with
// the same key finds the recorded row and returns created=false, so a replay of
// a crashed run does not repeat a push, a PR, a ticket creation, or a release.
func (m *Machine) Intent(ctx context.Context, owner string, token int64,
	key, effect string, intent any) (int64, bool, error) {
	if key == "" {
		return 0, false, fmt.Errorf("%w: a side effect needs an idempotency key", journal.ErrInvalid)
	}
	raw, err := marshal(intent)
	if err != nil {
		return 0, false, err
	}
	return m.mutate(ctx, owner, token,
		func(_ context.Context, _ *journal.Tx, _ *journal.State) (transition, error) {
			ev, err := m.event(journal.KindSideEffect,
				journal.Effect{Effect: effect, Intent: raw})
			if err != nil {
				return transition{}, err
			}
			ev.IdempotencyKey = key
			return then(ev), nil
		})
}

// Outcome closes a pending effect with what actually happened. An effect with no
// outcome row stays pending after replay, and the reconciler resolves it (AC5).
func (m *Machine) Outcome(ctx context.Context, owner string, token int64,
	intentSeq int64, effect string, outcome any) (int64, error) {
	raw, err := marshal(outcome)
	if err != nil {
		return 0, err
	}
	seq, _, err := m.mutate(ctx, owner, token,
		func(_ context.Context, _ *journal.Tx, _ *journal.State) (transition, error) {
			ev, err := m.event(journal.KindSideEffect,
				journal.Effect{Effect: effect, Outcome: raw, IntentSeq: intentSeq})
			if err != nil {
				return transition{}, err
			}
			return then(ev), nil
		})
	return seq, err
}

// Repair journals one reconciler repair (AC5): the observation that started it
// and the action that closed it.
func (m *Machine) Repair(ctx context.Context, owner string, token int64,
	target, observation, action string) error {
	_, _, err := m.mutate(ctx, owner, token,
		func(_ context.Context, _ *journal.Tx, _ *journal.State) (transition, error) {
			ev, err := m.event(journal.KindRepair,
				journal.RepairPayload{Target: target, Observation: observation, Action: action})
			if err != nil {
				return transition{}, err
			}
			return then(ev), nil
		})
	return err
}

// Complete moves running → completed, releases the lease, and carries a
// decision-card reference when the caller supplies one. A second Complete is
// refused: the run completes exactly once (AC7).
func (m *Machine) Complete(ctx context.Context, owner string, token int64,
	result any, card *journal.CardRef) error {
	raw, err := marshal(result)
	if err != nil {
		return err
	}
	_, _, err = m.mutate(ctx, owner, token,
		func(ctx context.Context, tx *journal.Tx, _ *journal.State) (transition, error) {
			ev, err := m.event(journal.KindRunCompleted, journal.CompletePayload{Result: raw})
			if err != nil {
				return transition{}, err
			}
			ev.Card = card
			return transition{
				event: ev,
				// The lease is released in the same transaction, so a completed
				// run never leaves a live owner behind.
				after: func(ctx context.Context, tx *journal.Tx, _ int64) error {
					return releaseLease(ctx, tx, m.runID)
				},
			}, nil
		})
	return err
}

// Fail moves the run to failed and releases the lease. It is legal from
// claimed, running, and any halt state.
func (m *Machine) Fail(ctx context.Context, owner string, token int64, reason string) error {
	if reason == "" {
		return fmt.Errorf("%w: run_failed needs a reason", journal.ErrInvalid)
	}
	_, _, err := m.mutate(ctx, owner, token,
		func(ctx context.Context, tx *journal.Tx, _ *journal.State) (transition, error) {
			ev, err := m.event(journal.KindRunFailed, journal.FailPayload{Reason: reason})
			if err != nil {
				return transition{}, err
			}
			return transition{
				event: ev,
				after: func(ctx context.Context, tx *journal.Tx, _ int64) error {
					return releaseLease(ctx, tx, m.runID)
				},
			}, nil
		})
	return err
}

// RecoveryPlan is the read-only comparison the reconciler starts from (AC5;
// wave 2 owns the repair loop): where the journal says the run is, who owns it,
// and which side effects were recorded and never closed.
type RecoveryPlan struct {
	RunID          string                   `json:"run_id"`
	State          string                   `json:"state"`
	Owner          string                   `json:"owner,omitempty"`
	Token          int64                    `json:"token,omitempty"`
	LeaseLive      bool                     `json:"lease_live"`
	LeaseExpired   bool                     `json:"lease_expired"`
	Stalled        bool                     `json:"stalled"`
	PendingEffects []journal.RecordedEffect `json:"pending_effects,omitempty"`
	Actions        []string                 `json:"actions,omitempty"`
}

// RecoveryPlan compares the journal with the lease and the clock. It writes
// nothing, so it is safe to take on a live run.
func (m *Machine) RecoveryPlan(ctx context.Context) (RecoveryPlan, error) {
	st, err := m.State(ctx)
	if err != nil {
		return RecoveryPlan{}, err
	}
	plan := RecoveryPlan{
		RunID: m.runID,
		State: st.Name(),
		Owner: st.Owner,
		Token: st.Token,
	}
	lease, err := readLease(ctx, m.eng, m.runID)
	switch {
	case err == nil:
		plan.LeaseLive = true
		plan.LeaseExpired = lease.Expired(m.now())
		plan.Owner, plan.Token = lease.Owner, lease.Token
	case !errors.Is(err, journal.ErrNoLease):
		return RecoveryPlan{}, err
	}
	if st.Status == journal.StatusRunning && st.StallLimitS > 0 {
		plan.Stalled = st.SinceHeartbeat(m.now()) > time.Duration(st.StallLimitS)*time.Second
	}
	plan.PendingEffects = st.PendingEffects()

	if !st.IsTerminal() {
		if plan.LeaseExpired {
			plan.Actions = append(plan.Actions, "take-over-lease")
		}
		for _, e := range plan.PendingEffects {
			plan.Actions = append(plan.Actions, "resolve-effect:"+e.Key)
		}
		if plan.Stalled {
			plan.Actions = append(plan.Actions, "halt:stalled")
		}
	}
	return plan, nil
}

// marshal renders a payload, with nil meaning an empty object.
func marshal(v any) (json.RawMessage, error) {
	if v == nil {
		return json.RawMessage(`{}`), nil
	}
	raw, err := json.Marshal(v)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", journal.ErrInvalid, err)
	}
	return raw, nil
}

// IntentWhenKeyed records a side effect only after a decision callback
// accepts it inside the write transaction (AC3; the SPEC-040 AC11
// intent-then-outcome pattern). It exists for a gate that must consult
// ledger state — its own run's replay and, through the transaction's Doer,
// the whole journal — before an intent commits: the control-plane queue
// reads the slot accounting with the ledger fold and appends the intent
// only when decide answers true.
//
// The contract:
//
//   - seq == 0 && created == false: no intent was recorded. The gate
//     refused (decide answered false before building a key), or the
//     caller's own state already accounts for the decision.
//   - seq != 0 && created == false: the intent was already recorded
//     (replay). The caller re-derives the same decision from the recorded
//     intent and the live state; an effect is never recorded twice.
//   - seq != 0 && created == true: the intent was recorded now.
//
// build runs after the fencing check, inside the same BEGIN IMMEDIATE
// transaction as the append. It reads the replayed state st and the
// transaction's Doer d (a cross-run ledger read lands inside the same
// write lock as the append), and returns the effect name, the idempotency
// key, and the payload of the intent it wants recorded — or ok=false to
// record nothing. Deriving the key inside the transaction is the point of
// the keyed form: an attempt number that comes from the ledger cannot race
// another writer the way a pre-read outside the transaction could, and
// naming the effect there lets one gate decide between two intents — the
// queue's grant either grants or waits, and the choice commits atomically
// with the decision. An error from build rolls
// the transaction back and writes nothing.
//
// after, when non-nil, runs after the append inside the same transaction —
// the pattern the machine's own transitions use for the lease release. It
// carries created: on a replay (created=false) the recorded rows already
// carry the follow-up writes, so the hook skips them. The queue's grant
// passes an after that closes the runner's open wait pair with its granted
// outcome, so the wait never dangles pending: the close and the grant
// commit together or not at all (AC6).
func (m *Machine) IntentWhenKeyed(ctx context.Context, owner string, token int64,
	build func(st *journal.State, d journal.Doer) (effect, key string, intent any, ok bool, err error),
	after func(ctx context.Context, tx *journal.Tx, seq int64, created bool) error) (int64, bool, error) {
	var (
		seq     int64
		created bool
	)
	err := m.eng.Transact(ctx, func(tx *journal.Tx) error {
		st, err := m.replay(ctx, tx)
		if err != nil {
			return err
		}
		if st.IsTerminal() {
			return fmt.Errorf("%w: run %s is %s", journal.ErrTerminalState, m.runID, st.Name())
		}
		if _, err := verifyLease(ctx, tx, m.runID, owner, token); err != nil {
			return err
		}
		effect, key, intent, ok, err := build(st, tx)
		if err != nil {
			return err
		}
		if !ok {
			seq, created = 0, false
			return nil
		}
		if key == "" {
			return fmt.Errorf("%w: a side effect needs an idempotency key", journal.ErrInvalid)
		}
		raw, err := marshal(intent)
		if err != nil {
			return err
		}
		ev, err := m.event(journal.KindSideEffect,
			journal.Effect{Effect: effect, Intent: raw})
		if err != nil {
			return err
		}
		ev.IdempotencyKey = key
		seq, created, err = tx.AppendChecked(ctx, ev)
		if err != nil {
			return err
		}
		if after == nil {
			return nil
		}
		return after(ctx, tx, seq, created)
	})
	return seq, created, err
}

// EffectRole names the caller that owns a control-plane side-effect record.
// The run machine itself journals no effect; the agents, the reconciler, and
// the queue set the prefix on their own keys.
const (
	// RoleAgent is the node agent (control-plane/agent). Its keys live in
	// control-plane/agent/agent.go.
	RoleAgent = "agent"
	// RoleQueue is the run queue (control-plane/queue, CDT-649). Its keys live
	// in control-plane/queue/queue.go.
	RoleQueue = "queue"
)
