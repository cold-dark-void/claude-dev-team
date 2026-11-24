package reconcile

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/cold-dark-void/claude-dev-team/control-plane/agent"
	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
	"github.com/cold-dark-void/claude-dev-team/control-plane/run"
)

// The closed phase-1 repair verb set (AC5).
const (
	// ActionAdopt journals the discovered state: reality is ahead of the
	// journal and no state change is owed.
	ActionAdopt = "adopt"
	// ActionResumeFailed marks a run failed: it cannot be resumed.
	ActionResumeFailed = "resume-failed"
	// ActionReleaseStaleLease releases a lease row that locks nothing.
	ActionReleaseStaleLease = "release-stale-lease"
	// ActionDeferred records a finding phase 1 does not act on. Deletion of a
	// worktree or branch is always deferred, never executed.
	ActionDeferred = "deferred"
)

// Finding categories.
const (
	CategoryJournal  = "journal"
	CategoryLease    = "lease"
	CategoryProcess  = "process"
	CategoryEffect   = "effect"
	CategoryWorktree = "worktree"
	CategoryBranch   = "branch"
	CategoryState    = "state"
	CategoryReality  = "reality"
	CategoryTerminal = "terminal"
)

// JournalRun is the run_id of the reconciler's own log: the run that owns the
// findings no run of its own owns (a foreign worktree, a failed reality scan).
const JournalRun = "reconcile"

// ErrReality is a failed reality scan (no git, not a repository).
var ErrReality = errors.New("reconcile: reality scan failed")

// Finding is one journal↔reality difference and what the pass did about it.
type Finding struct {
	RunID       string `json:"run_id,omitempty"`
	Category    string `json:"category"`
	Target      string `json:"target"`
	Observation string `json:"observation"`
	Action      string `json:"action"`
	Detail      string `json:"detail,omitempty"`
}

// Report is what one reconciler pass found and did.
type Report struct {
	MROOT          string             `json:"mroot"`
	Runs           []string           `json:"runs,omitempty"`
	Plans          []run.RecoveryPlan `json:"plans,omitempty"`
	Findings       []Finding          `json:"findings,omitempty"`
	Deferred       []Finding          `json:"deferred,omitempty"`
	EventsAppended int64              `json:"events_appended"`
	RealityError   string             `json:"reality_error,omitempty"`
}

// Paths carries the reconciler's environment: the repo root reality is scanned
// under, the git binary, and the injected clock and process probe. An empty
// MROOT resolves through journal.MROOT ($DEVTEAM_MROOT, else the parent of
// `git rev-parse --git-common-dir`); a nil Now is time.Now; a nil Probe is
// ProbePID.
type Paths struct {
	MROOT  string
	GitBin string
	Now    func() time.Time
	Probe  func(int) ProcessState
}

// Run compares the journal with reality and repairs the difference (AC5). It is
// safe on a live journal: every write is fenced by the lease token the journal
// already carries, and every repair is journaled through the state machine.
//
// eng is the concrete journal engine, not journal.Doer, because the state
// machine writes inside one journal transaction (run.New takes *journal.Engine).
//
// It returns the report of what it found. An error is a journal it could not
// read or write, never a finding.
func Run(ctx context.Context, eng *journal.Engine, paths Paths) (*Report, error) {
	if eng == nil {
		return nil, fmt.Errorf("%w: journal engine is required", journal.ErrInvalid)
	}
	now := time.Now().UTC()
	if paths.Now != nil {
		now = paths.Now().UTC()
	}
	probe := paths.Probe
	if probe == nil {
		probe = ProbePID
	}
	mroot := paths.MROOT
	if mroot == "" {
		resolved, err := journal.MROOT()
		if err != nil {
			return nil, err
		}
		mroot = resolved
	}

	before, err := countEvents(ctx, eng)
	if err != nil {
		return nil, err
	}

	p := &pass{
		ctx:    ctx,
		eng:    eng,
		probe:  probe,
		now:    now,
		mroot:  mroot,
		rep:    &Report{MROOT: mroot},
		seen:   map[repairKey]bool{},
		global: map[repairKey]bool{},
	}

	reality, err := Scan(ctx, paths.GitBin, mroot)
	if err != nil {
		p.rep.RealityError = err.Error()
		p.rep.add(Finding{
			Category:    CategoryReality,
			Target:      mroot,
			Observation: "the reality scan failed: " + err.Error(),
			Action:      ActionDeferred,
			Detail:      "the journal-side repairs ran without worktree, branch, or process evidence",
		})
	} else {
		p.reality = reality
		p.realityOK = true
	}

	globalState, err := eng.RunState(ctx, JournalRun)
	if err != nil {
		return nil, fmt.Errorf("reconcile: read %s: %w", JournalRun, err)
	}
	for _, r := range globalState.Repairs {
		p.global[repairKeyOf(r.Target, r.Observation, r.Action)] = true
	}

	ids, err := listRuns(ctx, eng)
	if err != nil {
		return nil, err
	}
	p.rep.Runs = ids
	for _, id := range ids {
		if id == JournalRun {
			continue
		}
		if err := p.runOne(id); err != nil {
			return nil, err
		}
	}

	if p.realityOK {
		if err := p.foreignResources(); err != nil {
			return nil, err
		}
	}

	after, err := countEvents(ctx, eng)
	if err != nil {
		return nil, err
	}
	p.rep.EventsAppended = after - before
	return p.rep, nil
}

// repairKey is the identity of a repair: target, observation, and verb. A row
// that matches it is already journaled, so the pass writes no second one.
type repairKey struct{ target, observation, action string }

func repairKeyOf(target, observation, action string) repairKey {
	return repairKey{target: target, observation: observation, action: action}
}

// pass is one reconciler pass over every run in the journal.
type pass struct {
	ctx   context.Context
	eng   *journal.Engine
	probe func(int) ProcessState
	now   time.Time
	mroot string
	rep   *Report

	reality   Reality
	realityOK bool

	// seen holds the repairs of the run being examined; global holds the rows
	// of the JournalRun log. Both seed from the journal, so a second pass
	// journals nothing.
	seen   map[repairKey]bool
	global map[repairKey]bool

	// tickets names every run identity the journal carries, so a worktree or
	// branch that belongs to a run is not reported as foreign.
	tickets []string

	// machine, state, and lease are the run being examined.
	machine  *run.Machine
	state    *journal.State
	lease    run.Lease
	hasLease bool
}

// runOne reconciles one run in the journal.
func (p *pass) runOne(runID string) error {
	st, err := p.eng.RunState(p.ctx, runID)
	if err != nil {
		return p.journalFinding(Finding{
			RunID:       runID,
			Category:    CategoryJournal,
			Target:      runID,
			Observation: "the run's journal does not replay: " + err.Error(),
			Action:      ActionDeferred,
			Detail:      "phase 1 journals no repair for a journal that cannot be replayed",
		})
	}
	p.tickets = append(p.tickets, runID)
	if st.Ticket != "" {
		p.tickets = append(p.tickets, st.Ticket)
	}

	machine := run.New(p.eng, runID)
	machine.Now = func() time.Time { return p.now }
	p.machine = machine
	p.state = st
	p.seen = seenRepairs(st)

	plan, err := machine.RecoveryPlan(p.ctx)
	if err != nil {
		return err
	}
	p.rep.Plans = append(p.rep.Plans, plan)

	lease, err := machine.ReadLease(p.ctx)
	switch {
	case err == nil:
		p.hasLease, p.lease = true, lease
	case errors.Is(err, journal.ErrNoLease):
		p.hasLease, p.lease = false, run.Lease{}
	default:
		return err
	}

	if st.IsTerminal() {
		return p.terminalRun(runID)
	}
	if st.Status == journal.StatusHalted && st.Halt != nil &&
		st.Halt.Reason == run.ReasonOperatorHalt {
		if err := p.journalFinding(Finding{
			RunID:       runID,
			Category:    CategoryState,
			Target:      runID,
			Observation: "run is halted:" + st.Halt.Reason,
			Action:      ActionDeferred,
			Detail:      "an operator halted this run; only an operator resumes it",
		}); err != nil {
			return err
		}
		if err := p.effects(runID); err != nil {
			return err
		}
		return p.adoptResources(runID)
	}
	if !p.hasLease {
		return p.journalFinding(Finding{
			RunID:       runID,
			Category:    CategoryLease,
			Target:      runID,
			Observation: "run is " + st.Name() + " and the lease table carries no row for it",
			Action:      ActionDeferred,
			Detail: "the next owner takes the run through the lease acquisition path; " +
				"a repair row needs the lease to present",
		})
	}
	return p.leaseAndState(runID)
}

// leaseAndState repairs the lease, process, and state side of a live run, then
// its pending effects and its resources.
func (p *pass) leaseAndState(runID string) error {
	st, lease := p.state, p.lease
	pid, hasPID := OwnerPID(lease.Owner)
	proc := ProcessUnknown
	if hasPID {
		proc = p.probe(pid)
	}

	// The owner process is gone: the run cannot continue unattended. Fail it
	// through the state machine, which releases the lease in the same
	// transaction.
	if proc == ProcessDead {
		obs := fmt.Sprintf("lease owner %q (pid %d) is not a live process; lease heartbeat %s, state liveness %s",
			lease.Owner, pid, lease.LastHeartbeatTS, st.HeartbeatTS)
		if err := p.repair(runID, CategoryProcess, runID+"/lease", obs, ActionResumeFailed); err != nil {
			return err
		}
		return p.machine.Fail(p.ctx, lease.Owner, lease.Token,
			"reconcile: lease owner "+lease.Owner+" is not a live process")
	}

	// A halt whose retries are spent has no way out but failed (AC6). The
	// budget is the run package's, not a number this package owns.
	if st.Status == journal.StatusHalted && st.Halt != nil && st.Halt.Remaining == 0 {
		obs := fmt.Sprintf("run is halted:%s and that halt's retry budget %d is spent",
			st.Halt.Reason, st.Halt.Budget)
		if err := p.repair(runID, CategoryState, runID, obs, ActionResumeFailed); err != nil {
			return err
		}
		return p.machine.Fail(p.ctx, lease.Owner, lease.Token,
			"reconcile: "+st.Halt.Reason+" retry budget is spent")
	}

	if lease.Expired(p.now) {
		if err := p.expiredLease(runID, pid, hasPID, proc); err != nil {
			return err
		}
	}

	if err := p.effects(runID); err != nil {
		return err
	}
	return p.adoptResources(runID)
}

// expiredLease handles a lease row past its own stall limit.
func (p *pass) expiredLease(runID string, pid int, hasPID bool, proc ProcessState) error {
	st, lease := p.state, p.lease
	stale := fmt.Sprintf("lease heartbeat %s is past its %ds stall limit", lease.LastHeartbeatTS, lease.StallLimitS)

	// The owner is alive: reality is ahead of the lease record (a stint is
	// liveness in the journal and does not stamp the lease row). Journal the
	// discovered state; the owner keeps its lease.
	if proc == ProcessAlive {
		obs := fmt.Sprintf("%s while owner %q (pid %d) is alive; state liveness %s",
			stale, lease.Owner, pid, st.HeartbeatTS)
		return p.repair(runID, CategoryLease, runID+"/lease", obs, ActionAdopt)
	}

	switch st.Status {
	case journal.StatusClaimed:
		obs := fmt.Sprintf("%s, owner %q is not proven alive, and the run never started",
			stale, lease.Owner)
		if err := p.repair(runID, CategoryLease, runID+"/lease", obs, ActionReleaseStaleLease); err != nil {
			return err
		}
		return p.machine.ReleaseStaleLease(p.ctx, lease.Owner, lease.Token)
	case journal.StatusRunning:
		obs := fmt.Sprintf("%s, owner %q is not proven alive, and the run is running at stint %d",
			stale, lease.Owner, st.Stint)
		if err := p.repair(runID, CategoryLease, runID+"/lease", obs, ActionAdopt); err != nil {
			return err
		}
		// The watchdog owns the stalled halt and its budget.
		_, err := p.machine.Watchdog(p.ctx, lease.Owner, lease.Token)
		return err
	default:
		// halted with budget left: the halt is the recorded state, and the
		// lease is what the next owner takes over. Nothing to repair.
		return nil
	}
}

// effects resolves the run's pending side-effect intents (AC3 + AC5). An intent
// whose effect is visible in reality is closed with the outcome the reconciler
// observed; one it cannot prove is journaled as deferred and the run is halted
// for the reconciler's reason, whose budget the run package owns. The
// reconciler never repeats an external effect.
func (p *pass) effects(runID string) error {
	if !p.hasLease {
		return nil
	}
	st, lease := p.state, p.lease
	for _, e := range st.PendingEffects() {
		obs := fmt.Sprintf("side effect %q (key %q, intent seq %d) has an intent row and no outcome row",
			e.Effect, e.Key, e.Seq)
		observed, seen := p.effectEvidence(e)

		if seen {
			obs = obs + "; " + observed
			if err := p.repair(runID, CategoryEffect, e.Key, obs, ActionAdopt); err != nil {
				return err
			}
			outcome := map[string]string{"source": "reconciler", "observed": observed}
			if _, err := p.machine.Outcome(p.ctx, lease.Owner, lease.Token, e.Seq, e.Effect, outcome); err != nil {
				if errors.Is(err, journal.ErrTransition) {
					return p.journalFinding(Finding{
						RunID:       runID,
						Category:    CategoryEffect,
						Target:      e.Key,
						Observation: obs,
						Action:      ActionDeferred,
						Detail:      "the outcome row is refused from state " + st.Name() + "; the owner closes it",
					})
				}
				return err
			}
			continue
		}

		if err := p.repair(runID, CategoryEffect, e.Key, obs, ActionDeferred); err != nil {
			return err
		}
		// Only a run that is doing work can be halted for the reconciler's
		// reason; a halted run already carries its state.
		if st.Status != journal.StatusRunning && st.Status != journal.StatusClaimed {
			continue
		}
		err := p.machine.Halt(p.ctx, lease.Owner, lease.Token, run.ReasonReconcileFailed,
			"an intent has no outcome row and the reconciler cannot prove the effect landed: "+e.Key)
		if err != nil && !errors.Is(err, journal.ErrBudgetExhausted) {
			return err
		}
	}
	return nil
}

// effectEvidence asks reality whether the effect behind an intent landed. The
// intent names its subject in a path or a branch field; anything else has no
// evidence a reconciler may read. One effect is self-evidencing and needs no
// reality at all: agent.session.
func (p *pass) effectEvidence(e journal.RecordedEffect) (string, bool) {
	if e.Effect == agent.EffectSession {
		// SPEC-044 CDT-661 AC1: the session-id row IS the record — the
		// intent payload carries the captured id, and no external reality
		// re-proves it. The pending intent is the crash window between two
		// back-to-back appends; halting for it would cost a microsecond
		// window the whole run (the takeover refuses halted:reconcile_failed).
		fields := intentFields(e.Intent)
		if fields == nil {
			return "", false
		}
		if id := firstString(fields, "session_id"); id != "" {
			return "the journal row names host session " + id, true
		}
		return "", false
	}
	if !p.realityOK {
		return "", false
	}
	fields := intentFields(e.Intent)
	if fields == nil {
		return "", false
	}
	path := firstString(fields, "path", "worktree", "worktree_path")
	branch := firstString(fields, "branch", "branch_name")
	if path == "" && branch == "" {
		return "", false
	}
	var parts []string
	if path != "" {
		full := resolveIn(p.mroot, path)
		if wt, ok := p.worktreeAt(full); ok {
			parts = append(parts, "worktree "+full+" exists on branch "+wt.Branch)
		} else if pathExists(full) {
			parts = append(parts, "the path "+full+" exists")
		}
	}
	if branch != "" && p.hasBranch(branch) {
		parts = append(parts, "branch "+branch+" exists")
	}
	if len(parts) == 0 {
		return "", false
	}
	return strings.Join(parts, " and "), true
}

// adoptResources journals the worktrees and branches that belong to this run's
// ticket and that the journal says nothing about (the adopt verb: journal the
// discovered state).
func (p *pass) adoptResources(runID string) error {
	if !p.realityOK || p.state.Ticket == "" {
		return nil
	}
	for _, w := range p.reality.Worktrees {
		if !namesRun(w.Path, p.state.Ticket) && !namesRun(w.Branch, p.state.Ticket) {
			continue
		}
		if p.isMainWorktree(w.Path) {
			continue
		}
		obs := fmt.Sprintf("worktree %s exists on branch %s for ticket %s", w.Path, w.Branch, p.state.Ticket)
		if err := p.repair(runID, CategoryWorktree, w.Path, obs, ActionAdopt); err != nil {
			return err
		}
	}
	for _, b := range p.reality.Branches {
		if !namesRun(b, p.state.Ticket) {
			continue
		}
		obs := fmt.Sprintf("branch %s exists for ticket %s", b, p.state.Ticket)
		if err := p.repair(runID, CategoryBranch, b, obs, ActionAdopt); err != nil {
			return err
		}
	}
	return nil
}

// terminalRun handles a finished run: no event may follow a terminal one, so
// the reconciler journals nothing on it. What it finds is recorded in the
// reconciler's own log.
func (p *pass) terminalRun(runID string) error {
	st := p.state
	if p.hasLease {
		return p.journalFinding(Finding{
			RunID:       runID,
			Category:    CategoryLease,
			Target:      runID + "/lease",
			Observation: "run is " + st.Name() + " and the lease table carries a row for it",
			Action:      ActionDeferred,
			Detail:      "no repair row may follow a terminal event; the lease row stays for the owner to release",
		})
	}
	if !p.realityOK || st.Ticket == "" {
		return nil
	}
	for _, w := range p.reality.Worktrees {
		if p.isMainWorktree(w.Path) {
			continue
		}
		if !namesRun(w.Path, st.Ticket) && !namesRun(w.Branch, st.Ticket) {
			continue
		}
		if err := p.journalFinding(Finding{
			RunID:       runID,
			Category:    CategoryTerminal,
			Target:      w.Path,
			Observation: "run is " + st.Name() + " and its worktree " + w.Path + " is still present",
			Action:      ActionDeferred,
			Detail:      "deleting a worktree is out of scope for phase 1; the reconciler never deletes one",
		}); err != nil {
			return err
		}
	}
	return nil
}

// foreignResources journals the worktrees and branches that name no run in the
// journal. Phase 1 records them and removes nothing (AC5).
func (p *pass) foreignResources() error {
	attached := map[string]bool{}
	for _, w := range p.reality.Worktrees {
		if p.isMainWorktree(w.Path) {
			attached["branch:"+w.Branch] = true
			continue
		}
		if p.belongs(w.Path) || p.belongs(w.Branch) {
			attached["worktree:"+w.Path] = true
			attached["branch:"+w.Branch] = true
			continue
		}
		if err := p.journalFinding(Finding{
			Category:    CategoryWorktree,
			Target:      w.Path,
			Observation: fmt.Sprintf("worktree %s on branch %q names no run in the journal", w.Path, w.Branch),
			Action:      ActionDeferred,
			Detail:      "deleting a foreign worktree is out of scope for phase 1; the reconciler never deletes one",
		}); err != nil {
			return err
		}
		attached["worktree:"+w.Path] = true
	}
	for _, b := range p.reality.Branches {
		if attached["branch:"+b] || p.belongs(b) {
			continue
		}
		if err := p.journalFinding(Finding{
			Category:    CategoryBranch,
			Target:      b,
			Observation: fmt.Sprintf("branch %s names no run in the journal", b),
			Action:      ActionDeferred,
			Detail:      "deleting a foreign branch is out of scope for phase 1; the reconciler never deletes one",
		}); err != nil {
			return err
		}
	}
	return nil
}

// belongs reports whether a worktree path or branch name is tied to a run the
// journal knows.
func (p *pass) belongs(name string) bool {
	for _, id := range p.tickets {
		if namesRun(name, id) {
			return true
		}
	}
	return false
}

// worktreeAt finds a scanned worktree by its path.
func (p *pass) worktreeAt(path string) (Worktree, bool) {
	want := normPath(path)
	for _, w := range p.reality.Worktrees {
		if normPath(w.Path) == want {
			return w, true
		}
	}
	return Worktree{}, false
}

// hasBranch reports a local branch git listed.
func (p *pass) hasBranch(branch string) bool {
	for _, b := range p.reality.Branches {
		if b == branch {
			return true
		}
	}
	return false
}

// isMainWorktree reports the repository's own checkout: it is never a run's
// resource, so it is never adopted and never reported as foreign.
func (p *pass) isMainWorktree(path string) bool {
	return normPath(path) == normPath(p.mroot)
}

// repair journals one repair through the state machine (AC5). A repair the
// journal already carries is not written again: that is the idempotency rule.
func (p *pass) repair(runID, category, target, observation, action string) error {
	key := repairKeyOf(target, observation, action)
	if p.seen[key] {
		return nil
	}
	if !p.hasLease {
		return fmt.Errorf("%w: run %s has no lease to present for repair %s/%s",
			journal.ErrNoLease, runID, target, action)
	}
	if err := p.machine.Repair(p.ctx, p.lease.Owner, p.lease.Token, target, observation, action); err != nil {
		return err
	}
	p.seen[key] = true
	p.rep.add(Finding{
		RunID:       runID,
		Category:    category,
		Target:      target,
		Observation: observation,
		Action:      action,
	})
	return nil
}

// journalFinding appends one finding to the reconciler's own journal run: the
// findings that have no run of their own, and the ones a run cannot carry.
func (p *pass) journalFinding(f Finding) error {
	key := repairKeyOf(f.Target, f.Observation, f.Action)
	if p.global[key] {
		return nil
	}
	ev, err := journal.NewEvent(JournalRun, journal.KindRepair, journal.RepairPayload{
		Target:      f.Target,
		Observation: f.Observation,
		Action:      f.Action,
	})
	if err != nil {
		return err
	}
	ev.TS = journal.FormatTS(p.now)
	if _, _, err := p.eng.AppendChecked(p.ctx, ev); err != nil {
		return err
	}
	p.global[key] = true
	p.rep.add(f)
	return nil
}

// add records a finding, and counts the deferred ones separately.
func (r *Report) add(f Finding) {
	r.Findings = append(r.Findings, f)
	if f.Action == ActionDeferred {
		r.Deferred = append(r.Deferred, f)
	}
}

// seenRepairs seeds the dedupe set from the journal's own repair rows.
func seenRepairs(st *journal.State) map[repairKey]bool {
	seen := make(map[repairKey]bool, len(st.Repairs))
	for _, r := range st.Repairs {
		seen[repairKeyOf(r.Target, r.Observation, r.Action)] = true
	}
	return seen
}

// listRuns returns every run the journal carries, in sorted order, so a pass is
// deterministic. Values bind nowhere: the statement carries no parameter.
func listRuns(ctx context.Context, eng *journal.Engine) ([]string, error) {
	rows, err := eng.QueryContext(ctx, `SELECT DISTINCT run_id FROM events ORDER BY run_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

func countEvents(ctx context.Context, eng *journal.Engine) (int64, error) {
	var n int64
	row, err := eng.QueryRow(ctx, `SELECT count(*) FROM events`)
	if err != nil {
		return 0, err
	}
	if err := row.Scan(&n); err != nil {
		return 0, err
	}
	return n, nil
}
