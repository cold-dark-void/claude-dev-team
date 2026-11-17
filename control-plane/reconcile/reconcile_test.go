package reconcile

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
	"github.com/cold-dark-void/claude-dev-team/control-plane/run"
)

// clock is a controllable UTC clock, so lease expiry and stalls are moved, not
// slept.
type clock struct{ t time.Time }

func (c *clock) now() time.Time { return c.t }

func (c *clock) advance(d time.Duration) { c.t = c.t.Add(d).UTC() }

// fixture is one journal plus one real git repository: the reconciler compares
// the two, so the test needs both.
type fixture struct {
	t    *testing.T
	eng  *journal.Engine
	db   string
	repo string
	clk  *clock
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	tmp := t.TempDir()
	repo := filepath.Join(tmp, "repo")
	mkdirGit(t, repo)

	db := filepath.Join(repo, ".claude", "runs", "run.db")
	eng, err := journal.OpenPath(context.Background(), db)
	if err != nil {
		t.Fatalf("OpenPath: %v", err)
	}
	t.Cleanup(func() { _ = eng.Close() })

	return &fixture{
		t:    t,
		eng:  eng,
		db:   db,
		repo: repo,
		clk:  &clock{t: time.Date(2026, 11, 16, 12, 0, 0, 0, time.UTC)},
	}
}

// mkdirGit makes root a git repository with one commit, so `git worktree list`
// and `git branch` answer.
func mkdirGit(t *testing.T, root string) {
	t.Helper()
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	git(t, root, "init", "-q", "-b", "main")
	git(t, root, "-c", "user.name=t", "-c", "user.email=t@example.com",
		"commit", "-q", "--allow-empty", "-m", "seed")
}

// addWorktree creates .worktrees/<ticket> on branch feat/<ticket>.
func addWorktree(t *testing.T, root, ticket string) {
	t.Helper()
	git(t, root, "-c", "user.name=t", "-c", "user.email=t@example.com",
		"worktree", "add", "-q", "-b", "feat/"+ticket, ".worktrees/"+ticket)
}

func git(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
	}
}

// realPath is the path git reports: git resolves symlinks, t.TempDir may not be
// resolved.
func realPath(t *testing.T, p string) string {
	t.Helper()
	got, err := filepath.EvalSymlinks(p)
	if err != nil {
		t.Fatalf("EvalSymlinks(%s): %v", p, err)
	}
	return filepath.Clean(got)
}

// reconcile runs one pass with the given process probe.
func (f *fixture) reconcile(probe func(int) ProcessState) *Report {
	f.t.Helper()
	rep, err := Run(context.Background(), f.eng, Paths{
		MROOT: f.repo,
		Now:   f.clk.now,
		Probe: probe,
	})
	if err != nil {
		f.t.Fatalf("reconcile.Run: %v", err)
	}
	return rep
}

func (f *fixture) state(runID string) *journal.State {
	f.t.Helper()
	st, err := f.eng.RunState(context.Background(), runID)
	if err != nil {
		f.t.Fatalf("RunState(%s): %v", runID, err)
	}
	return st
}

// aliveProbe proves every owner the tests name, so an owner is never failed for
// a process the test did not kill.
func aliveProbe(int) ProcessState { return ProcessAlive }

func unknownProbe(int) ProcessState { return ProcessUnknown }

// deadPID returns a pid that is not a live process: a child started, waited on,
// and therefore reaped.
func deadPID(t *testing.T) int {
	t.Helper()
	cmd := exec.Command("true")
	if err := cmd.Start(); err != nil {
		t.Fatalf("start true: %v", err)
	}
	pid := cmd.Process.Pid
	if err := cmd.Wait(); err != nil {
		t.Fatalf("wait true: %v", err)
	}
	if got := ProbePID(pid); got != ProcessDead {
		t.Fatalf("ProbePID(%d) = %s, want dead", pid, got)
	}
	return pid
}

// machine returns a state machine on the fixture clock, so a test moves time
// instead of sleeping.
func (f *fixture) machine(runID string) *run.Machine {
	m := run.New(f.eng, runID)
	m.Now = f.clk.now
	return m
}

// claimStart takes the lease and starts the run, and returns the fencing token.
func (f *fixture) claimStart(runID, owner, model string) int64 {
	f.t.Helper()
	m := f.machine(runID)
	token, err := m.Claim(context.Background(), owner, runID, "orchestrate", model)
	if err != nil {
		f.t.Fatalf("Claim: %v", err)
	}
	if err := m.Start(context.Background(), owner, token, model); err != nil {
		f.t.Fatalf("Start: %v", err)
	}
	return token
}

// AC5 idempotency: a pass that changes reality journals its repairs, and the
// next pass with no change in reality journals nothing.
func TestReconcileIsIdempotent(t *testing.T) {
	f := newFixture(t)
	addWorktree(t, f.repo, "CDT-9")

	f.claimStart("CDT-9", "runner-a", "sonnet")

	first := f.reconcile(aliveProbe)
	if first.EventsAppended == 0 {
		t.Fatalf("first pass journaled nothing; findings %+v", first.Findings)
	}
	if !hasAction(first, ActionAdopt) {
		t.Fatalf("first pass adopted nothing; findings %+v", first.Findings)
	}
	for _, want := range []string{".worktrees/CDT-9", "feat/CDT-9"} {
		if !hasTarget(first, want) {
			t.Errorf("no finding targets %s; findings %+v", want, first.Findings)
		}
	}

	second := f.reconcile(aliveProbe)
	if second.EventsAppended != 0 {
		t.Fatalf("second pass journaled %d events; findings %+v",
			second.EventsAppended, second.Findings)
	}
	if len(second.Findings) != 0 {
		t.Fatalf("second pass reported findings it did not journal: %+v", second.Findings)
	}

	// The repairs landed on the run, through the journal.
	st := f.state("CDT-9")
	if len(st.Repairs) == 0 {
		t.Fatal("the run carries no repair rows")
	}
	if st.Name() != "running" {
		t.Fatalf("state = %s, want running", st.Name())
	}
}

// AC5 with an empty journal: no run to repair. The resources reality shows are
// recorded once, as deferred findings, and nothing is removed.
func TestReconcileEmptyJournal(t *testing.T) {
	f := newFixture(t)
	addWorktree(t, f.repo, "CDT-9")

	rep := f.reconcile(aliveProbe)
	if len(rep.Runs) != 0 {
		t.Fatalf("runs = %v, want none", rep.Runs)
	}
	if len(rep.Findings) != int(rep.EventsAppended) || rep.EventsAppended == 0 {
		t.Fatalf("events = %d, findings = %d: every finding is journaled once",
			rep.EventsAppended, len(rep.Findings))
	}
	for _, d := range rep.Deferred {
		if d.Action != ActionDeferred {
			t.Fatalf("finding %+v is in Deferred but not deferred", d)
		}
	}
	if second := f.reconcile(aliveProbe); second.EventsAppended != 0 {
		t.Fatalf("second pass journaled %d events; findings %+v",
			second.EventsAppended, second.Findings)
	}
	if _, err := os.Stat(filepath.Join(f.repo, ".worktrees", "CDT-9")); err != nil {
		t.Fatalf("the reconciler removed the worktree: %v", err)
	}
}

// AC5 processes: a lease owner whose pid is not a live process is a crash. The
// run is failed through the state machine and its lease goes with it.
func TestStaleProcessFailsTheRun(t *testing.T) {
	f := newFixture(t)
	pid := deadPID(t)
	owner := fmt.Sprintf("node-agent-%d", pid)

	f.claimStart("CDT-40", owner, "sonnet")
	// The owner dies: the clock passes the stall limit the lease carries.
	f.clk.advance(4 * time.Minute)

	rep := f.reconcile(ProbePID)
	if !hasAction(rep, ActionResumeFailed) {
		t.Fatalf("no resume-failed repair; findings %+v", rep.Findings)
	}
	st := f.state("CDT-40")
	if st.Name() != "failed" {
		t.Fatalf("state = %s, want failed", st.Name())
	}
	if st.Failure == nil || !strings.Contains(st.Failure.Reason, owner) {
		t.Fatalf("failure = %+v, want the reason to name %s", st.Failure, owner)
	}
	m := f.machine("CDT-40")
	if _, err := m.ReadLease(context.Background()); !errors.Is(err, journal.ErrNoLease) {
		t.Fatalf("ReadLease after the repair = %v, want ErrNoLease", err)
	}

	// Nothing left to repair: the second pass journals nothing.
	if second := f.reconcile(ProbePID); second.EventsAppended != 0 {
		t.Fatalf("second pass journaled %d events; findings %+v",
			second.EventsAppended, second.Findings)
	}
}

// A live owner is never failed, and a lease record that lags the journal's own
// liveness is adopted, not taken.
func TestLiveOwnerIsAdoptedNotFailed(t *testing.T) {
	f := newFixture(t)
	token := f.claimStart("CDT-41", "runner:pid=999999", "sonnet")
	m := f.machine("CDT-41")
	if err := m.Stint(context.Background(), "runner:pid=999999", token, "wave 2"); err != nil {
		t.Fatal(err)
	}
	f.clk.advance(4 * time.Minute) // the lease row is now past its limit

	rep := f.reconcile(aliveProbe)
	if hasAction(rep, ActionResumeFailed) {
		t.Fatalf("the reconciler failed a run whose owner is alive: %+v", rep.Findings)
	}
	if !hasAction(rep, ActionAdopt) {
		t.Fatalf("no adopt repair; findings %+v", rep.Findings)
	}
	if st := f.state("CDT-41"); st.Name() != "running" {
		t.Fatalf("state = %s, want running", st.Name())
	}
	if second := f.reconcile(aliveProbe); second.EventsAppended != 0 {
		t.Fatalf("second pass journaled %d events", second.EventsAppended)
	}
}

// release-stale-lease: a claimed run whose lease is past its limit and whose
// owner cannot be proven alive. The lock is released; the run keeps its state.
func TestReleaseStaleLease(t *testing.T) {
	f := newFixture(t)
	owner := "runner-b:pid=999999"
	m := f.machine("CDT-42")
	if _, err := m.Claim(context.Background(), owner, "CDT-42", "orchestrate", "sonnet"); err != nil {
		t.Fatal(err)
	}
	f.clk.advance(4 * time.Minute)

	rep := f.reconcile(unknownProbe)
	if !hasAction(rep, ActionReleaseStaleLease) {
		t.Fatalf("no release-stale-lease repair; findings %+v", rep.Findings)
	}
	if _, err := m.ReadLease(context.Background()); !errors.Is(err, journal.ErrNoLease) {
		t.Fatalf("ReadLease = %v, want ErrNoLease", err)
	}
	if st := f.state("CDT-42"); st.Name() != "claimed" {
		t.Fatalf("state = %s, want claimed", st.Name())
	}

	// The pass after the release reports the missing lease once, then stops.
	if second := f.reconcile(unknownProbe); second.EventsAppended == 0 {
		t.Fatalf("second pass journaled nothing; the no-lease finding is owed")
	}
	third := f.reconcile(unknownProbe)
	if third.EventsAppended != 0 {
		t.Fatalf("third pass journaled %d events; findings %+v",
			third.EventsAppended, third.Findings)
	}
}

// A lease inside its limit is never released, by anyone.
func TestReleaseStaleLeaseRefusesALiveLease(t *testing.T) {
	f := newFixture(t)
	m := f.machine("CDT-43")
	ctx := context.Background()
	token, err := m.Claim(ctx, "runner-c", "CDT-43", "orchestrate", "sonnet")
	if err != nil {
		t.Fatal(err)
	}
	if err := m.ReleaseStaleLease(ctx, "runner-c", token); !errors.Is(err, journal.ErrLeaseHeld) {
		t.Fatalf("ReleaseStaleLease on a live lease = %v, want ErrLeaseHeld", err)
	}
	if err := m.ReleaseStaleLease(ctx, "runner-c", token+1); !errors.Is(err, journal.ErrStaleToken) {
		t.Fatalf("ReleaseStaleLease with a stale token = %v, want ErrStaleToken", err)
	}
	if _, err := m.ReadLease(ctx); err != nil {
		t.Fatalf("the lease must survive a refused release: %v", err)
	}
}

// AC3 + AC5: an intent whose effect reality can see is closed with the outcome
// the reconciler observed. It is never re-driven.
func TestPendingIntentWithObservedEffectCloses(t *testing.T) {
	f := newFixture(t)
	addWorktree(t, f.repo, "CDT-44")
	owner := "runner-a"
	token := f.claimStart("CDT-44", owner, "sonnet")

	m := f.machine("CDT-44")
	key := "CDT-44:worktree:1"
	if _, _, err := m.Intent(context.Background(), owner, token, key, "worktree",
		map[string]string{"path": ".worktrees/CDT-44", "branch": "feat/CDT-44"}); err != nil {
		t.Fatal(err)
	}
	if st := f.state("CDT-44"); len(st.PendingEffects()) != 1 {
		t.Fatalf("the intent is not pending: %+v", st.Effects)
	}

	rep := f.reconcile(aliveProbe)
	if !hasAction(rep, ActionAdopt) {
		t.Fatalf("no adopt repair for the observed effect; findings %+v", rep.Findings)
	}
	st := f.state("CDT-44")
	if len(st.PendingEffects()) != 0 {
		t.Fatalf("the intent is still pending: %+v", st.Effects)
	}
	if len(st.Effects) != 1 || st.Effects[0].OutcomeSeq == 0 {
		t.Fatalf("no outcome row closed the intent: %+v", st.Effects)
	}
	if !strings.Contains(string(st.Effects[0].Outcome), "reconciler") {
		t.Fatalf("outcome = %s, want the reconciler as its source", st.Effects[0].Outcome)
	}
	if second := f.reconcile(aliveProbe); second.EventsAppended != 0 {
		t.Fatalf("second pass journaled %d events", second.EventsAppended)
	}
}

// AC5: an intent with no observable outcome is resolved into a journaled
// repair, and the run is halted for the reconciler's reason. Nothing external
// is repeated.
func TestPendingIntentWithNoOutcomeIsJournaled(t *testing.T) {
	f := newFixture(t)
	owner := "runner-a"
	token := f.claimStart("CDT-45", owner, "sonnet")

	m := f.machine("CDT-45")
	key := "CDT-45:push:1"
	if _, _, err := m.Intent(context.Background(), owner, token, key, "push",
		map[string]string{"remote": "origin", "ref": "feat/CDT-45"}); err != nil {
		t.Fatal(err)
	}

	rep := f.reconcile(aliveProbe)
	if !hasActionTarget(rep, ActionDeferred, key) {
		t.Fatalf("no deferred repair for %s; findings %+v", key, rep.Findings)
	}
	st := f.state("CDT-45")
	if st.Name() != "halted:reconcile_failed" {
		t.Fatalf("state = %s, want halted:reconcile_failed", st.Name())
	}
	if len(st.PendingEffects()) != 1 {
		t.Fatalf("the reconciler closed an effect it did not observe: %+v", st.Effects)
	}
	if second := f.reconcile(aliveProbe); second.EventsAppended != 0 {
		t.Fatalf("second pass journaled %d events; findings %+v",
			second.EventsAppended, second.Findings)
	}
}

// AC5: a foreign worktree and a foreign branch are journaled as deferred
// findings with the exact observation. Nothing is deleted.
func TestForeignResourcesAreDeferredNotDeleted(t *testing.T) {
	f := newFixture(t)
	addWorktree(t, f.repo, "CDT-50") // no run in the journal names CDT-50
	f.claimStart("CDT-51", "runner-a", "sonnet")

	foreign := realPath(t, filepath.Join(f.repo, ".worktrees", "CDT-50"))
	branchPath := filepath.Join(f.repo, ".git", "refs", "heads", "feat", "CDT-50")

	rep := f.reconcile(aliveProbe)
	var found bool
	for _, d := range rep.Deferred {
		if d.Category == CategoryWorktree && d.Target == foreign {
			found = true
			if !strings.Contains(d.Observation, "names no run") {
				t.Errorf("observation %q does not state the finding", d.Observation)
			}
			if !strings.Contains(d.Detail, "out of scope") {
				t.Errorf("detail %q does not state the phase-1 limit", d.Detail)
			}
		}
	}
	if !found {
		t.Fatalf("no deferred finding for the foreign worktree; deferred %+v", rep.Deferred)
	}
	if _, err := os.Stat(foreign); err != nil {
		t.Fatalf("the reconciler removed the worktree: %v", err)
	}
	if _, err := os.Stat(branchPath); err != nil {
		t.Fatalf("the reconciler removed the branch: %v", err)
	}

	// The finding is journaled in the reconciler's own log, once.
	gl := f.state(JournalRun)
	if len(gl.Repairs) == 0 {
		t.Fatal("the reconciler's journal carries no repair row")
	}
	if !strings.Contains(gl.Repairs[0].Target, "CDT-50") {
		t.Fatalf("journal target = %q, want the foreign path", gl.Repairs[0].Target)
	}
	if second := f.reconcile(aliveProbe); second.EventsAppended != 0 {
		t.Fatalf("second pass journaled %d events; findings %+v",
			second.EventsAppended, second.Findings)
	}
}

// A finished run accepts no event, so what the reconciler finds around it is
// recorded in its own log, and nothing is deleted.
func TestTerminalRunFindsAreJournaledGlobally(t *testing.T) {
	f := newFixture(t)
	addWorktree(t, f.repo, "CDT-52")
	owner := "runner-a"
	token := f.claimStart("CDT-52", owner, "sonnet")
	m := f.machine("CDT-52")
	if err := m.Complete(context.Background(), owner, token, map[string]string{"sha": "abc"}, nil); err != nil {
		t.Fatal(err)
	}

	rep := f.reconcile(aliveProbe)
	if len(rep.Deferred) == 0 {
		t.Fatalf("nothing recorded about the finished run's worktree; findings %+v", rep.Findings)
	}
	if _, err := os.Stat(filepath.Join(f.repo, ".worktrees", "CDT-52")); err != nil {
		t.Fatalf("the reconciler removed the worktree: %v", err)
	}
	if len(f.state(JournalRun).Repairs) == 0 {
		t.Fatal("the reconciler's own log is empty")
	}
	if second := f.reconcile(aliveProbe); second.EventsAppended != 0 {
		t.Fatalf("second pass journaled %d events", second.EventsAppended)
	}
}

// An operator halt is a human's decision: the reconciler never resumes and
// never fails that run.
func TestOperatorHaltIsLeftAlone(t *testing.T) {
	f := newFixture(t)
	owner := "runner-a"
	token := f.claimStart("CDT-53", owner, "sonnet")
	m := f.machine("CDT-53")
	ctx := context.Background()
	if err := m.Halt(ctx, owner, token, run.ReasonOperatorHalt, "the maintainer said stop"); err != nil {
		t.Fatal(err)
	}
	f.clk.advance(10 * time.Minute)

	rep := f.reconcile(unknownProbe)
	if hasAction(rep, ActionResumeFailed) {
		t.Fatalf("the reconciler failed an operator-halted run: %+v", rep.Findings)
	}
	if st := f.state("CDT-53"); st.Name() != "halted:operator_halt" {
		t.Fatalf("state = %s, want halted:operator_halt", st.Name())
	}
	if len(rep.Deferred) == 0 {
		t.Fatalf("the operator halt is not reported: %+v", rep.Findings)
	}
}

// A halt whose retries are spent has one way out: failed. The budget is the run
// package's, so a third pass cannot spin on it.
func TestSpentHaltBudgetFailsTheRun(t *testing.T) {
	f := newFixture(t)
	owner := "runner-a"
	token := f.claimStart("CDT-54", owner, "sonnet")
	m := f.machine("CDT-54")
	ctx := context.Background()
	// Spend operator_halt's zero-resume budget: the halt itself is the state,
	// so use reconcile_failed, whose budget the reconciler owns.
	// Spend reconcile_failed's budget of 3: the fourth halt of the reason
	// leaves 0 resumes.
	for i := 0; i < 4; i++ {
		if err := m.Halt(ctx, owner, token, run.ReasonReconcileFailed, "pass"); err != nil {
			t.Fatalf("halt %d: %v", i+1, err)
		}
		if i < 3 {
			if err := m.Resume(ctx, owner, token); err != nil {
				t.Fatalf("resume %d: %v", i+1, err)
			}
		}
	}
	if st := f.state("CDT-54"); st.Halt == nil || st.Halt.Remaining != 0 {
		t.Fatalf("the budget is not spent: %+v", st.Halt)
	}

	rep := f.reconcile(aliveProbe)
	if !hasAction(rep, ActionResumeFailed) {
		t.Fatalf("no resume-failed repair; findings %+v", rep.Findings)
	}
	if st := f.state("CDT-54"); st.Name() != "failed" {
		t.Fatalf("state = %s, want failed", st.Name())
	}
}

// A journal that cannot be replayed is a finding, not a panic and not a repair.
func TestUnreplayableJournalIsDeferred(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	// A heartbeat with no claim: legal to append, impossible to replay.
	ev, err := journal.NewEvent("CDT-55", journal.KindHeartbeat,
		journal.HeartbeatPayload{Owner: "x", Token: 3})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.eng.Append(ctx, ev); err != nil {
		t.Fatal(err)
	}

	rep := f.reconcile(aliveProbe)
	var found bool
	for _, d := range rep.Deferred {
		if d.Category == CategoryJournal && d.RunID == "CDT-55" {
			found = true
		}
	}
	if !found {
		t.Fatalf("no deferred finding for the broken journal; deferred %+v", rep.Deferred)
	}
	if second := f.reconcile(aliveProbe); second.EventsAppended != 0 {
		t.Fatalf("second pass journaled %d events", second.EventsAppended)
	}
}

// A directory git will not answer is a recorded finding: the pass still runs the
// journal-side repairs.
func TestRealityScanFailureIsRecorded(t *testing.T) {
	tmp := t.TempDir()
	db := filepath.Join(tmp, "run.db")
	eng, err := journal.OpenPath(context.Background(), db)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = eng.Close() })

	owner := "runner-a"
	m := run.New(eng, "CDT-56")
	clk := &clock{t: time.Date(2026, 11, 16, 12, 0, 0, 0, time.UTC)}
	m.Now = clk.now
	token, err := m.Claim(context.Background(), owner, "CDT-56", "orchestrate", "sonnet")
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Start(context.Background(), owner, token, "sonnet"); err != nil {
		t.Fatal(err)
	}

	rep, err := Run(context.Background(), eng, Paths{
		MROOT: tmp,
		Now:   clk.now,
		Probe: aliveProbe,
	})
	if err != nil {
		t.Fatalf("Run with no repository: %v", err)
	}
	if rep.RealityError == "" {
		t.Fatal("RealityError is empty; the scan failure is unreported")
	}
	if !hasAction(rep, ActionDeferred) {
		t.Fatalf("the scan failure is not a deferred finding; findings %+v", rep.Findings)
	}
}

// The report carries wave 1's comparison for every run, so the plan stays the
// single source of the journal↔lease↔clock reading.
func TestReportCarriesTheRecoveryPlan(t *testing.T) {
	f := newFixture(t)
	f.claimStart("CDT-57", "runner-a", "sonnet")

	rep := f.reconcile(aliveProbe)
	if len(rep.Plans) != 1 {
		t.Fatalf("plans = %+v, want one", rep.Plans)
	}
	if rep.Plans[0].RunID != "CDT-57" || rep.Plans[0].State != "running" || !rep.Plans[0].LeaseLive {
		t.Fatalf("plan = %+v", rep.Plans[0])
	}
}

// Scan reads git's own records.
func TestScanReadsWorktreesAndBranches(t *testing.T) {
	tmp := t.TempDir()
	mkdirGit(t, tmp)
	addWorktree(t, tmp, "CDT-60")

	real, err := Scan(context.Background(), "", tmp)
	if err != nil {
		t.Fatal(err)
	}
	if len(real.Worktrees) != 2 {
		t.Fatalf("worktrees = %+v, want the main checkout plus one", real.Worktrees)
	}
	if real.Worktrees[0].Path != realPath(t, tmp) {
		t.Fatalf("main worktree = %+v, want %s", real.Worktrees[0], tmp)
	}
	if real.Worktrees[1].Branch != "feat/CDT-60" {
		t.Fatalf("worktree branch = %+v", real.Worktrees[1])
	}
	want := realPath(t, filepath.Join(tmp, ".worktrees", "CDT-60"))
	if real.Worktrees[1].Path != want {
		t.Fatalf("worktree path = %q, want %q", real.Worktrees[1].Path, want)
	}
	if len(real.Branches) != 2 || real.Branches[0] != "feat/CDT-60" || real.Branches[1] != "main" {
		t.Fatalf("branches = %v, want [feat/CDT-60 main]", real.Branches)
	}
	if _, err := Scan(context.Background(), "", filepath.Join(tmp, "nope")); err == nil {
		t.Fatal("Scan on a directory that is not a repository returned no error")
	}
}

func TestOwnerPID(t *testing.T) {
	for _, tc := range []struct {
		owner string
		pid   int
		ok    bool
	}{
		{"runner:pid=4321", 4321, true},
		{"node-agent-4321", 4321, true},
		{"runner-a:4321", 4321, true},
		{"4321", 4321, true},
		{"runner-a", 0, false},
		{"", 0, false},
		{"pid=0", 0, false},
	} {
		pid, ok := OwnerPID(tc.owner)
		if pid != tc.pid || ok != tc.ok {
			t.Errorf("OwnerPID(%q) = %d, %v; want %d, %v", tc.owner, pid, ok, tc.pid, tc.ok)
		}
	}
}

func TestProbePID(t *testing.T) {
	if got := ProbePID(os.Getpid()); got != ProcessAlive {
		t.Errorf("ProbePID(self) = %s, want alive", got)
	}
	if got := ProbePID(0); got != ProcessUnknown {
		t.Errorf("ProbePID(0) = %s, want unknown", got)
	}
	if got := ProbePID(-1); got != ProcessUnknown {
		t.Errorf("ProbePID(-1) = %s, want unknown", got)
	}
	if got := ProbePID(deadPID(t)); got != ProcessDead {
		t.Errorf("ProbePID(dead) = %s, want dead", got)
	}
}

func TestNamesRun(t *testing.T) {
	for _, tc := range []struct {
		name, ticket string
		want         bool
	}{
		{"feat/CDT-643", "CDT-643", true},
		{"/w/repo/.worktrees/CDT-643", "CDT-643", true},
		{"feat/cdt-643-rebase", "CDT-643", true},
		{"feature/643", "CDT-643", false},
		{"main", "CDT-643", false},
		{"feat/CDT-6430", "CDT-643", false},
		{"feat/CDT-643", "", false},
	} {
		if got := namesRun(tc.name, tc.ticket); got != tc.want {
			t.Errorf("namesRun(%q, %q) = %v, want %v", tc.name, tc.ticket, got, tc.want)
		}
	}
}

func TestIntentFieldsAndResolve(t *testing.T) {
	fields := intentFields(json.RawMessage(`{"path":".worktrees/X","n":3}`))
	if got := firstString(fields, "path", "worktree"); got != ".worktrees/X" {
		t.Errorf("firstString = %q", got)
	}
	if fields := intentFields(json.RawMessage(`{"n":3}`)); firstString(fields, "path") != "" {
		t.Error("a number field must not read as a path")
	}
	if intentFields(json.RawMessage(`not json`)) != nil {
		t.Error("a payload that is not JSON must read as no fields")
	}
	if got := resolveIn("/m", ".worktrees/X"); got != "/m/.worktrees/X" {
		t.Errorf("resolveIn = %q", got)
	}
	if got := resolveIn("/m", "/abs/X"); got != "/abs/X" {
		t.Errorf("resolveIn absolute = %q", got)
	}
}

// Run refuses a nil engine: no pass, no write.
func TestRunRefusesNilEngine(t *testing.T) {
	if _, err := Run(context.Background(), nil, Paths{}); !errors.Is(err, journal.ErrInvalid) {
		t.Fatalf("Run(nil) = %v, want ErrInvalid", err)
	}
}

func hasAction(rep *Report, action string) bool {
	for _, f := range rep.Findings {
		if f.Action == action {
			return true
		}
	}
	return false
}

func hasTarget(rep *Report, needle string) bool {
	for _, f := range rep.Findings {
		if strings.HasSuffix(f.Target, needle) {
			return true
		}
	}
	return false
}

func hasActionTarget(rep *Report, action, target string) bool {
	for _, f := range rep.Findings {
		if f.Action == action && f.Target == target {
			return true
		}
	}
	return false
}
