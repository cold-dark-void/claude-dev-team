package chief

import (
	"context"
	"fmt"
	"time"

	"github.com/cold-dark-void/claude-dev-team/control-plane/agent"
	"github.com/cold-dark-void/claude-dev-team/control-plane/hostadapter"
	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
	"github.com/cold-dark-void/claude-dev-team/control-plane/run"
)

// The three operator actions of SPEC-045 M4/M5/M6. Each rides a primitive that
// already exists — the node agent's stop verb, the takeover/resume seam, and
// the route's own start path — and journals only the closed event set:
// run_halted, run_resumed, and the new run's claim rows. No verb here adds an
// event kind, a halt reason, a retry budget, or a lifecycle-graph vertex.

// StopResult is what one stop did.
type StopResult struct {
	RunID  string `json:"run_id"`
	Halted string `json:"halted"`
}

// ResumeResult is what one resume did.
type ResumeResult struct {
	RunID   string `json:"run_id"`
	Resumed bool   `json:"resumed"`
}

// RetryResult names the run one retry started.
type RetryResult struct {
	RunID string `json:"run_id"`
}

// RetryRequest is one retry verb's body. Every field is optional.
type RetryRequest struct {
	// Host names the host the retried run rides. Empty derives it from the
	// old run's start record (SPEC-045 M6).
	Host hostadapter.Host `json:"host,omitempty"`
}

// Stop halts a run to halted:operator_halt (SPEC-045 M4). It is valid from
// running — the node agent's signal path: intent row, stop, outcome row, named
// halt — and from claimed, where the run holds no recorded runner and the
// agent's stop verb journals the named halt alone. Every other state refuses
// with ErrNotStoppable.
func (c *Chief) Stop(ctx context.Context, runID string) (StopResult, error) {
	st, err := c.actionState(ctx, runID)
	if err != nil {
		return StopResult{}, err
	}
	if st.Status != journal.StatusRunning && st.Status != journal.StatusClaimed {
		return StopResult{}, fmt.Errorf(
			"%w: run %s is %s; stop is valid from running and claimed",
			ErrNotStoppable, runID, st.Name())
	}
	if err := c.Adapter.Stop(ctx, c.eng, runID, agent.DefaultGrace); err != nil {
		return StopResult{}, err
	}
	return StopResult{RunID: runID, Halted: run.ReasonOperatorHalt}, nil
}

// Resume continues a halted run in place (SPEC-045 M5) through the chief's one
// resume seam — startSupervisedResume over Adapter.Resume, the takeover's own
// path. The Chief is the resume owner and derives both inputs from the journal:
// the host from the run's recorded start argv and the session id from its
// agent.session rows, never from the in-memory capture a restart loses.
//
// The refusals, in the order the checks fall: ErrNotResumable when the run is
// not in a named halt state, when its start record names no host the adapter
// can launch, and when the matrix denies that host's resume cell;
// ErrResumeSpent (the replay's journal.ErrBudgetExhausted) when the reason's
// budget is spent — always true for halted:operator_halt, whose recovery path
// is Retry; and ErrNoJournaledSession when the journal names no session id to
// resume by.
func (c *Chief) Resume(ctx context.Context, runID string) (ResumeResult, error) {
	st, err := c.actionState(ctx, runID)
	if err != nil {
		return ResumeResult{}, err
	}
	if st.Status != journal.StatusHalted || st.Halt == nil {
		return ResumeResult{}, fmt.Errorf(
			"%w: run %s is %s; resume is valid from a named halt state",
			ErrNotResumable, runID, st.Name())
	}
	if st.Halt.Remaining < 1 {
		return ResumeResult{}, fmt.Errorf(
			"%w: run %s is halted:%s with budget %d spent; retry it",
			ErrResumeSpent, runID, st.Halt.Reason, st.Halt.Budget)
	}
	host, _, err := c.resumeWork(ctx, runID)
	if err != nil {
		return ResumeResult{}, err
	}
	if host == "" {
		return ResumeResult{}, fmt.Errorf(
			"%w: run %s names no host the adapter can launch in its start record",
			ErrNotResumable, runID)
	}
	if !hostadapter.ResumeRoute(host) {
		return ResumeResult{}, fmt.Errorf(
			"%w: %s has no resume route in the capability matrix, so the host session "+
				"cannot be continued; retry it", ErrNotResumable, host)
	}
	sessionID, err := c.takeoverSessionID(ctx, runID)
	if err != nil {
		return ResumeResult{}, err
	}
	if sessionID == "" {
		return ResumeResult{}, fmt.Errorf(
			"%w: %s journals no agent.session row, so the host session to continue is unknown",
			ErrNoJournaledSession, runID)
	}

	since := st.LastSeq
	errc := c.startSupervisedResume(runID, hostadapter.ResumeRequest{
		RunID: runID, Ticket: st.Ticket, Workflow: st.Workflow, Model: st.Model,
		Host: host, SessionID: sessionID, OperatorResume: true,
	})
	if err := c.resumeWatch(ctx, runID, since, errc); err != nil {
		return ResumeResult{}, err
	}
	return ResumeResult{RunID: runID, Resumed: true}, nil
}

// Retry starts a NEW run for a finished ticket (SPEC-045 M6): the next attempt
// of the same ticket (the M2 allocation a ticket route shares), carrying the
// same workflow and the journaled model, the premise from the old run's
// agent.premise row, and the host from its start record unless the request
// names one. It is valid from failed and from halted:<reason>; every other
// state refuses with ErrNotRetryable.
//
// The old run is never touched: failed stays terminal in the lifecycle graph,
// and the record of the retry is the new run's own claim row. The matrix gates
// the new start as it gates any start.
func (c *Chief) Retry(ctx context.Context, runID string, host hostadapter.Host) (RetryResult, error) {
	st, err := c.actionState(ctx, runID)
	if err != nil {
		return RetryResult{}, err
	}
	if st.Status != journal.StatusFailed && st.Status != journal.StatusHalted {
		return RetryResult{}, fmt.Errorf(
			"%w: run %s is %s; retry is valid from failed and from a named halt state",
			ErrNotRetryable, runID, st.Name())
	}
	if st.Ticket == "" {
		return RetryResult{}, fmt.Errorf(
			"%w: run %s claims no ticket, so there is no attempt to allocate",
			ErrNotRetryable, runID)
	}
	oldHost, premise, err := c.resumeWork(ctx, runID)
	if err != nil {
		return RetryResult{}, err
	}
	if host == "" {
		host = oldHost
	}
	if !hostadapter.ValidHost(host) {
		return RetryResult{}, fmt.Errorf("%w: %q is not one of %s", hostadapter.ErrUnknownHost,
			host, hostList())
	}
	newRunID, err := c.nextAttempt(ctx, st.Ticket)
	if err != nil {
		return RetryResult{}, err
	}

	// The start rides the route's own path — the claim payload, the premise
	// frame, and the bounded wait for the run's first row — so a retry is a
	// start, never a second spawn path.
	res := &RouteResult{Kind: "ticket", Surface: Surface{Name: st.Workflow},
		RunID: newRunID, Model: st.Model}
	if err := c.startRun(ctx, RouteRequest{Host: host}, res, st.Ticket, premise); err != nil {
		return RetryResult{}, err
	}
	return RetryResult{RunID: newRunID}, nil
}

// actionState replays one run for the action verbs and refuses a run the journal
// holds no row for — an id the actions never saw.
func (c *Chief) actionState(ctx context.Context, runID string) (*journal.State, error) {
	st, err := c.eng.RunState(ctx, runID)
	if err != nil {
		return nil, err
	}
	if st.EventCount == 0 {
		return nil, fmt.Errorf("%w: %s", ErrUnknownRun, runID)
	}
	return st, nil
}

// resumeWork folds a run's journal into the two inputs the actions share: the
// host its recorded start argv names and the premise its newest agent.premise
// row carries. Both are empty for a run that records neither — Resume refuses
// that as ErrNotResumable and Retry answers on the host it was given.
func (c *Chief) resumeWork(ctx context.Context, runID string) (hostadapter.Host, string, error) {
	events, err := c.eng.Events(ctx, runID)
	if err != nil {
		return "", "", err
	}
	host, premise := detailFold(events)
	return host, premise, nil
}

// resumeWatch is the resume's bounded proof loop, the shape takeoverWatch uses:
// the journal proves the resume, the verb's refusal answers on errc, and an
// answer the wait cannot prove says so — the resume rides the chief's base
// context and may still land. Every path is bounded by startWait.
func (c *Chief) resumeWatch(ctx context.Context, runID string, since int64,
	errc <-chan error) error {
	wait := c.startWait()
	timer := time.NewTimer(wait)
	defer timer.Stop()
	for {
		select {
		case err := <-errc:
			return err
		case <-ctx.Done():
			return fmt.Errorf("%w: run %s lost its caller while the resume started: %v",
				ErrStartUnconfirmed, runID, ctx.Err())
		case <-timer.C:
			return fmt.Errorf("%w: run %s recorded no resume row within %s",
				ErrStartUnconfirmed, runID, wait)
		default:
			done, err := c.resumeConfirmed(ctx, runID, since)
			if err != nil {
				return err
			}
			if done {
				return nil
			}
			time.Sleep(5 * time.Millisecond)
		}
	}
}

// resumeConfirmed reports the journal's proof of a resume: a row past the
// snapshot on a run the machine moved back to running.
func (c *Chief) resumeConfirmed(ctx context.Context, runID string, since int64) (bool, error) {
	st, err := c.eng.RunState(ctx, runID)
	if err != nil {
		return false, err
	}
	return st.LastSeq > since && st.Name() == string(journal.StatusRunning), nil
}
