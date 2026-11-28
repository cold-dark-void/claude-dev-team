package chief

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"time"

	"github.com/cold-dark-void/claude-dev-team/control-plane/agent"
	"github.com/cold-dark-void/claude-dev-team/control-plane/hostadapter"
	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
	"github.com/cold-dark-void/claude-dev-team/control-plane/reconcile"
	"github.com/cold-dark-void/claude-dev-team/control-plane/run"
)

// stalledState is the replayed name of the only halt state the takeover
// selects (SPEC-044 M1).
var stalledState = string(journal.StatusHalted) + ":" + run.ReasonStalled

// takeoverCandidate is one run the takeover scan selects (SPEC-044 M1). It
// carries what the takeover path needs to re-supervise the run through the
// host adapter: the run id, the replayed state it was found in, the
// journaled work (the run_claimed payload), the caps the run's own
// run_started row journaled (SPEC-046 M7), and the lease owner the records
// name — the node the Runner lives on (M12).
type takeoverCandidate struct {
	RunID    string
	State    string
	Owner    string
	Ticket   string
	Workflow string
	Model    string
	// WallclockCapS and IterationCapS are the run's journaled budget caps:
	// 0 for a run that carries none. The re-spawn re-injects them, because the
	// takeover reconstructs the run from the journal alone (SPEC-046 AC8).
	WallclockCapS int64
	IterationCapS int64
}

// takeoverSet folds every run's replayed state and returns the closed
// selection set (SPEC-044 M1, AC1): `running` or `claimed` (spawn-pending: a
// claim row, no run_started) whose lease has expired, or `halted:stalled`.
// Nothing else is ever selected — not the other named halts, not the terminal
// states, not `new`, not the reconcile.JournalRun pseudo-Run.
//
// The read is the journal replay and the lease row only: no queue read, no
// slot read (P4), and no state is projected for a run that is not selected
// (M7). It is a pure read — it writes no row.
//
// The fold is a snapshot, not a lock. A run that is live by the time the scan
// executor reaches it is refused by the lease itself
// (run.Machine.Claim → journal.ErrLeaseHeld), which is M4's mechanism; the
// scan never claims a run is takeable.
func (c *Chief) takeoverSet(ctx context.Context) ([]takeoverCandidate, error) {
	ids, err := c.runIDs(ctx)
	if err != nil {
		return nil, err
	}
	now := c.now()
	var out []takeoverCandidate
	for _, id := range ids {
		if id == reconcile.JournalRun {
			// AC1: the reconciler's own log is not a run.
			continue
		}
		st, err := c.eng.RunState(ctx, id)
		if err != nil {
			return nil, err
		}
		lease, hasLease, err := c.leaseFor(ctx, id)
		if err != nil {
			// M6: an unreadable lease row stops this run's takeover only.
			// A lease that cannot be read proves no expiry, so the run is
			// left alone and the next tick reads it again.
			continue
		}
		cand, ok := takeoverSelect(st, lease, hasLease, now)
		if !ok {
			continue
		}
		out = append(out, cand)
	}
	return out, nil
}

// leaseFor reads a run's lease row. hasLease is false when the run holds no
// lease row at all.
func (c *Chief) leaseFor(ctx context.Context, runID string) (run.Lease, bool, error) {
	l, err := run.New(c.eng, runID).ReadLease(ctx)
	if errors.Is(err, journal.ErrNoLease) {
		return run.Lease{}, false, nil
	}
	if err != nil {
		return run.Lease{}, false, err
	}
	return l, true, nil
}

// takeoverSelect is AC1's closed set as one decision over the replayed state,
// the lease row, and the scan clock.
//
// A `running`/`claimed` run is selected only when its own lease is expired
// (run.Lease.Expired). A run with no lease row is treated as expired: no
// owner can prove liveness, which is Lease.Expired's own rule for a lease
// whose liveness it cannot read.
func takeoverSelect(st *journal.State, lease run.Lease, hasLease bool,
	now time.Time) (takeoverCandidate, bool) {
	if st == nil {
		return takeoverCandidate{}, false
	}
	name := st.Name()
	switch name {
	case stalledState:
		// The stalled halt is the watchdog's finding: the takeover is the
		// response and the resume spends the stalled budget (M10).
		// Both selected states fall through to the one candidate return.
	case string(journal.StatusRunning), string(journal.StatusClaimed):
		if hasLease && !lease.Expired(now) {
			return takeoverCandidate{}, false
		}
	default:
		// halted:<lease_lost|reconcile_failed|budget_exhausted|operator_halt|
		// handshake_failed>, completed, failed, and new (M1's refuse list).
		// The handshake halt names the transport, not a dead owner: an
		// unattended re-spawn would idle on the same refusal (CDT-679 AC3).
		return takeoverCandidate{}, false
	}
	return takeoverCandidate{RunID: st.RunID, State: name, Owner: st.Owner,
		Ticket: st.Ticket, Workflow: st.Workflow, Model: st.Model,
		WallclockCapS: st.WallclockCapS, IterationCapS: st.IterationCapS}, true
}

// TakeoverOutcome is what one takeover pass did with one selected run
// (SPEC-044 S1): taken, skipped (M5), refused (M6), or unconfirmed — a start
// whose journal proof never landed.
type TakeoverOutcome string

// The report outcomes of one takeover.
const (
	TakeoverTaken       TakeoverOutcome = "taken"
	TakeoverSkipped     TakeoverOutcome = "skipped"
	TakeoverRefused     TakeoverOutcome = "refused"
	TakeoverUnconfirmed TakeoverOutcome = "unconfirmed"
)

// TakeoverRun is one report line of the takeover scan: the run, the state it
// was found in, what the scan did, and why. It is the operator's first
// reading after a reboot (S1); the journal stays the record.
type TakeoverRun struct {
	RunID   string          `json:"run_id"`
	State   string          `json:"state"`
	Outcome TakeoverOutcome `json:"outcome"`
	// Host is the host the re-spawn rides — the command the run's own start
	// record named. Empty on a run the scan never spawned.
	Host   string `json:"host,omitempty"`
	Reason string `json:"reason,omitempty"`
}

// Line renders the report line chiefd writes to stdout, which journald
// captures (S1).
func (r TakeoverRun) Line() string {
	if r.Reason == "" {
		return fmt.Sprintf("takeover %s: run %s (%s)", r.Outcome, r.RunID, r.State)
	}
	return fmt.Sprintf("takeover %s: run %s (%s): %s",
		r.Outcome, r.RunID, r.State, r.Reason)
}

// TakeoverReport is the outcome of one scan pass, bucketed by outcome.
type TakeoverReport struct {
	Taken       []TakeoverRun `json:"taken,omitempty"`
	Skipped     []TakeoverRun `json:"skipped,omitempty"`
	Refused     []TakeoverRun `json:"refused,omitempty"`
	Unconfirmed []TakeoverRun `json:"unconfirmed,omitempty"`
}

func (r *TakeoverReport) add(line TakeoverRun) {
	switch line.Outcome {
	case TakeoverTaken:
		r.Taken = append(r.Taken, line)
	case TakeoverSkipped:
		r.Skipped = append(r.Skipped, line)
	case TakeoverRefused:
		r.Refused = append(r.Refused, line)
	case TakeoverUnconfirmed:
		r.Unconfirmed = append(r.Unconfirmed, line)
	}
}

// buckets is the report's non-taken buckets, in report-line order: what the
// operator has to read (S1). A taken run reports nothing.
func (r TakeoverReport) buckets() [][]TakeoverRun {
	return [][]TakeoverRun{r.Skipped, r.Refused, r.Unconfirmed}
}

// Lines is one report line per M5 skip, per M6 refusal, and per unconfirmed
// start — never a swallowed run (S1).
func (r TakeoverReport) Lines() []string {
	var out []string
	for _, bucket := range r.buckets() {
		for _, line := range bucket {
			out = append(out, line.Line())
		}
	}
	return out
}

// LinesFor is the report's lines for one run — the reading GET /v1/checks
// carries for it (AC5). A run the pass took over, or never selected, has
// none.
func (r TakeoverReport) LinesFor(runID string) []string {
	var out []string
	for _, bucket := range r.buckets() {
		for _, line := range bucket {
			if line.RunID == runID {
				out = append(out, line.Line())
			}
		}
	}
	return out
}

// TakeoverScan is the takeover's one entry point (SPEC-044 M2/M3): it takes
// every run of the M1 selection set over through the host adapter's Start —
// the same spawn path a routed run rides — serially, one run at a time
// (S2, DRI OQ4), and reports what each one did. A tick that finds more
// selected runs than it finishes leaves the rest to the next tick.
//
// The pass writes no journal row of its own: no run_halted, no repair, no
// projected state. Every row a takeover carries is the machine's own,
// journaled by the start verb behind Adapter.Start.
//
// One run's failure never ends the pass (M6): a skip, a refusal, or an
// unconfirmed start is a report line, and the scan moves to the next run.
// The only error returned is the pass's own — the selection read, or the
// caller ending the scan.
func (c *Chief) TakeoverScan(ctx context.Context) (TakeoverReport, error) {
	cands, err := c.takeoverSet(ctx)
	if err != nil {
		return TakeoverReport{}, fmt.Errorf("chief: takeover scan: %w", err)
	}
	var rep TakeoverReport
	for _, cand := range cands {
		if err := ctx.Err(); err != nil {
			c.recordTakeover(rep)
			c.logTakeover(rep)
			return rep, err
		}
		rep.add(c.takeoverOne(ctx, cand))
	}
	c.recordTakeover(rep)
	c.logTakeover(rep)
	return rep, nil
}

// recordTakeover keeps the pass's report as the chief's takeover reading:
// GET /v1/checks projects it, so a run the scan skipped (M5) or refused (M6)
// is named to the UI and not on journald alone (AC5). The last pass wins —
// the scan repeats (M2) and a run the next pass takes over reads clean
// again.
func (c *Chief) recordTakeover(rep TakeoverReport) {
	c.mu.Lock()
	c.takeoverRep = rep
	c.mu.Unlock()
}

// takeoverReading is the last scan's report lines for one run (AC5).
func (c *Chief) takeoverReading(runID string) []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.takeoverRep.LinesFor(runID)
}

// takeoverLog is where the scan's report lines go: chiefd's stdout, which
// journald captures (S1). Tests swap it.
var takeoverLog io.Writer = os.Stdout

// logTakeover writes the pass's report lines to chiefd's stdout, each one
// only the first time the process sees it: the scan repeats every tick (M2),
// and a run that stays skipped would otherwise write the same line forever.
// The report itself is the journal's truth on every pass — the dedup covers
// the log line, never the reading.
func (c *Chief) logTakeover(rep TakeoverReport) {
	w := takeoverLog
	if w == nil {
		return
	}
	c.mu.Lock()
	if c.takeoverSeen == nil {
		c.takeoverSeen = map[string]bool{}
	}
	var fresh []string
	for _, line := range rep.Lines() {
		if !c.takeoverSeen[line] {
			c.takeoverSeen[line] = true
			fresh = append(fresh, line)
		}
	}
	c.mu.Unlock()
	for _, line := range fresh {
		fmt.Fprintln(w, line)
	}
}

// takeoverOne takes one selected run over. Every refusal it can name comes
// back as a report line, never as an error the pass would swallow.
func (c *Chief) takeoverOne(ctx context.Context, cand takeoverCandidate) TakeoverRun {
	line := TakeoverRun{RunID: cand.RunID, State: cand.State}
	if !takeoverNodeLocal(cand.Owner) {
		line.Outcome = TakeoverRefused
		line.Reason = fmt.Sprintf("the takeover is node-local: the lease owner %q names a "+
			"runner on another node, and chiefd spawns only on its own node (SPEC-044 M12)",
			cand.Owner)
		return line
	}
	command, recorded, err := c.takeoverStartCommand(ctx, cand.RunID)
	if err != nil {
		line.Outcome = TakeoverRefused
		line.Reason = err.Error()
		return line
	}
	if !recorded {
		// M5: the run died between its claim and its spawn intent. There is
		// no host to derive, so the takeover spawns nothing and says so.
		line.Outcome = TakeoverSkipped
		line.Reason = fmt.Sprintf("the run records no %s intent, so no host is derivable; "+
			"the takeover spawns nothing", agent.EffectStart)
		return line
	}
	host, ok := hostByCommand(filepath.Base(command))
	if !ok {
		line.Outcome = TakeoverRefused
		line.Reason = fmt.Sprintf("the run's start record launches %q, which names no host "+
			"the adapter can launch (%s)", command, hostList())
		return line
	}
	line.Host = string(host)
	sessionID, err := c.takeoverSessionID(ctx, cand.RunID)
	if err != nil {
		line.Outcome = TakeoverRefused
		line.Reason = err.Error()
		return line
	}
	if sessionID != "" && hostadapter.ResumeRoute(host) {
		// SPEC-044 CDT-661 AC3: the journal names the host session and the
		// host names a supported resume cell, so the same host session
		// continues across the crash. The reason line tells the operator
		// resume from re-spawn on first reading (S1).
		line.Reason = fmt.Sprintf("resumed host session %s", sessionID)
		return c.takeoverResume(ctx, cand, host, sessionID, line)
	}
	// CDT-661 AC4: no captured id (before-capture hosts, capture-less
	// starts) or no resume cell (mini-swe) — CDT-660's fresh re-spawn,
	// byte-identical.
	return c.takeoverSpawn(ctx, cand, host, line)
}

// takeoverSessionID reads the run's journaled host session id (SPEC-044
// CDT-661 AC3): the newest agent.session row that names one, its outcome
// payload first and its intent payload after — a pending intent is the crash
// window between two back-to-back appends, and the id must survive it. The
// newest row wins: a resumed attempt supersedes its predecessor. Empty means
// the run carries no captured id — the CDT-660 fresh re-spawn fallback.
func (c *Chief) takeoverSessionID(ctx context.Context, runID string) (string, error) {
	events, err := c.eng.Events(ctx, runID)
	if err != nil {
		return "", err
	}
	id := ""
	for _, ev := range events {
		if ev.Kind != journal.KindSideEffect {
			continue
		}
		var ef journal.Effect
		if err := jsonUnmarshal(ev.Payload, &ef); err != nil || ef.Effect != agent.EffectSession {
			continue
		}
		raw := ef.Outcome
		if len(raw) == 0 {
			raw = ef.Intent
		}
		var payload struct {
			SessionID string `json:"session_id"`
		}
		if err := jsonUnmarshal(raw, &payload); err == nil && payload.SessionID != "" {
			id = payload.SessionID
		}
	}
	return id, nil
}

// takeoverStartCommand reads the command of the run's newest recorded
// spawn intent. recorded is false when the run carries no agent.start intent
// at all — M5's no-host shape.
//
// The newest intent is the one to re-spawn from: a run that was taken over
// once already carries one row per attempt. hostFromJournal answers a
// correction, so it names the host that is steerable today.
func (c *Chief) takeoverStartCommand(ctx context.Context, runID string) (string, bool, error) {
	events, err := c.eng.Events(ctx, runID)
	if err != nil {
		return "", false, err
	}
	command, recorded := "", false
	for _, ev := range events {
		if ev.Kind != journal.KindSideEffect || !ev.IntentRow() {
			continue
		}
		var ef journal.Effect
		if err := jsonUnmarshal(ev.Payload, &ef); err != nil || ef.Effect != agent.EffectStart {
			continue
		}
		var intent struct {
			Command string `json:"command"`
		}
		if err := jsonUnmarshal(ef.Intent, &intent); err != nil || intent.Command == "" {
			continue
		}
		command, recorded = intent.Command, true
	}
	return command, recorded, nil
}

// takeoverSpawn re-supervises one run through chief.startSupervised — the
// same spawn path a routed run rides — and answers what the journal proves.
//
// The proof is a row the takeover wrote: a journal position past the pass's
// snapshot on a run the machine moved to running. Refusals (the matrix, no
// runner selection, a held lease, a terminal state, a spent budget) return
// on errc with nothing written, which is what keeps the run untouched.
func (c *Chief) takeoverSpawn(ctx context.Context, cand takeoverCandidate,
	host hostadapter.Host, line TakeoverRun) TakeoverRun {
	since, err := c.takeoverSeq(ctx, cand.RunID)
	if err != nil {
		line.Outcome = TakeoverRefused
		line.Reason = err.Error()
		return line
	}
	errc := c.startSupervised(cand.RunID, hostadapter.StartRequest{
		RunID: cand.RunID, Ticket: cand.Ticket, Workflow: cand.Workflow,
		Model: cand.Model, Host: host,
		// The caps the run's own run_started row journaled ride the re-spawn
		// (SPEC-046 M7/AC8): the takeover rebuilds the run from the journal,
		// so a run the operator capped keeps its cap across the crash. A run
		// that carried none re-spawns with none — the takeover invents no
		// budget. The resume branch carries neither: it re-uses the session by
		// id and re-execs nothing.
		RunCaps: hostadapter.RunCaps{WallclockCapS: cand.WallclockCapS,
			IterationCapS: cand.IterationCapS},
		// No Premise: the re-adoption reads the run's work premise out of
		// the journal's own premise row (SPEC-044 CDT-665) — a closed pair
		// means the session already got its turn, a pending intent carries
		// the text to deliver. The chief stores no ticket text to re-send.
	})
	return c.takeoverWatch(ctx, cand, since, errc, line)
}

// takeoverResume re-supervises one run through chief.startSupervisedResume
// — the by-id resume of the journaled host session (SPEC-044 CDT-661 AC3).
// The resume rides the node agent's Supervise unchanged (the stalled resume
// for halted:stalled, the lease takeover for an expired-lease running run)
// and journals the spawn intent with the host's resume argv at attempt
// N+1: intent-then-outcome exactly like a start, no new verb, no new effect
// name for the resume itself. The proof loop is takeoverSpawn's.
func (c *Chief) takeoverResume(ctx context.Context, cand takeoverCandidate,
	host hostadapter.Host, sessionID string, line TakeoverRun) TakeoverRun {
	since, err := c.takeoverSeq(ctx, cand.RunID)
	if err != nil {
		line.Outcome = TakeoverRefused
		line.Reason = err.Error()
		return line
	}
	errc := c.startSupervisedResume(cand.RunID, hostadapter.ResumeRequest{
		RunID: cand.RunID, Ticket: cand.Ticket, Workflow: cand.Workflow,
		Model: cand.Model, Host: host, SessionID: sessionID,
	})
	return c.takeoverWatch(ctx, cand, since, errc, line)
}

// takeoverWatch is the takeover's proof loop, shared by the fresh re-spawn
// and the resume: it answers taken when the journal proves the takeover,
// refused when the start refuses, and unconfirmed when the pass ends or the
// wait expires before the proof lands.
func (c *Chief) takeoverWatch(ctx context.Context, cand takeoverCandidate,
	since int64, errc <-chan error, line TakeoverRun) TakeoverRun {
	wait := c.startWait()
	timer := time.NewTimer(wait)
	defer timer.Stop()
	for {
		select {
		case err := <-errc:
			if err != nil {
				line.Outcome = TakeoverRefused
				line.Reason = err.Error()
				return line
			}
			line.Outcome = TakeoverTaken
			return line
		case <-ctx.Done():
			// The pass ended; the start rides the base context and may still
			// land. The report says exactly that — it never claims a takeover
			// the journal does not prove (M7).
			line.Outcome = TakeoverUnconfirmed
			line.Reason = fmt.Sprintf("the takeover pass ended while %s started: %v",
				cand.RunID, ctx.Err())
			return line
		case <-timer.C:
			line.Outcome = TakeoverUnconfirmed
			line.Reason = fmt.Sprintf("run %s recorded no takeover row within %s; the start "+
				"rides the chief's base context and may still land", cand.RunID, wait)
			return line
		default:
			done, err := c.takeoverConfirmed(ctx, cand.RunID, since)
			if err != nil {
				line.Outcome = TakeoverRefused
				line.Reason = err.Error()
				return line
			}
			if done {
				line.Outcome = TakeoverTaken
				return line
			}
			time.Sleep(5 * time.Millisecond)
		}
	}
}

// takeoverSeq is the run's journal position at the moment the scan reaches
// it — the snapshot the takeover's proof is measured against.
func (c *Chief) takeoverSeq(ctx context.Context, runID string) (int64, error) {
	st, err := c.eng.RunState(ctx, runID)
	if err != nil {
		return 0, err
	}
	return st.LastSeq, nil
}

// takeoverConfirmed reports whether the journal carries the takeover: a row
// past the snapshot, on a run the machine moved to running.
func (c *Chief) takeoverConfirmed(ctx context.Context, runID string, since int64) (bool, error) {
	st, err := c.eng.RunState(ctx, runID)
	if err != nil {
		return false, err
	}
	return st.LastSeq > since && st.Name() == string(journal.StatusRunning), nil
}

// localOwnerRE is the lease-owner shape this node's own agent writes
// (agent.Owner plus the supervisor pid, "node-agent-4321").
var localOwnerRE = regexp.MustCompile(`^` + regexp.QuoteMeta(agent.Owner) + `-[1-9][0-9]*$`)

// takeoverNodeLocal is the M12 boundary as one decision over the records.
// Phase 1 has one node, so the boundary is structural: the takeover's
// re-spawn is executed by chiefd's own in-process agent on its local node,
// and it can only own a lease whose owner is that agent's own shape. An
// owner that names a node (the phase-4 shape, CDT-631) is not this node's
// runner. An owner the records leave empty names no other node.
func takeoverNodeLocal(owner string) bool {
	return owner == "" || localOwnerRE.MatchString(owner)
}
