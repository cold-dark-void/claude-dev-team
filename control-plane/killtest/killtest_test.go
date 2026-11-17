package killtest

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
	"github.com/cold-dark-void/claude-dev-team/control-plane/run"
)

// helperBin is the sacrificial binary, built once per suite run.
var helperBin string

func TestMain(m *testing.M) {
	os.Exit(setup(m))
}

// setup builds ./helper before any test runs. A suite that cannot build its own
// victim is not a kill test, so a build failure fails the run: the suite never
// passes by silently skipping.
func setup(m *testing.M) int {
	dir, err := os.MkdirTemp("", "cdt643-killtest-")
	if err != nil {
		fmt.Fprintln(os.Stderr, "killtest: temp dir:", err)
		return 1
	}
	defer os.RemoveAll(dir)

	pkg, err := os.Getwd()
	if err != nil {
		fmt.Fprintln(os.Stderr, "killtest: work dir:", err)
		return 1
	}
	helperBin = filepath.Join(dir, "helper")
	cmd := exec.Command(goTool(), "build", "-o", helperBin, "./helper")
	cmd.Dir = pkg
	cmd.Env = os.Environ()
	if out, err := cmd.CombinedOutput(); err != nil {
		fmt.Fprintf(os.Stderr, "killtest: build ./helper: %v\n%s\n", err, out)
		return 1
	}
	return m.Run()
}

// goTool locates the Go binary that built this test.
func goTool() string {
	if root := os.Getenv("GOROOT"); root != "" {
		if p := filepath.Join(root, "bin", "go"); isExecutable(p) {
			return p
		}
	}
	if p, err := exec.LookPath("go"); err == nil {
		return p
	}
	fmt.Fprintln(os.Stderr, "killtest: no go tool to build the helper with")
	os.Exit(1)
	return ""
}

func isExecutable(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && !fi.IsDir() && fi.Mode().Perm()&0o111 != 0
}

// AC7, the gate that falsifies ADR 0001 cost 1: SIGKILL the service at every
// lifecycle phase boundary, restart it on the same journal, and the run
// completes exactly once.
//
// Each subtest owns one journal file and one effect log. The victim is a real
// process that SIGKILLs itself mid-flight with the journal open; the recovery is
// a second real process on the same file. The assertions are on the journal and
// on the external effect log — the two things an operator can audit — not on
// any in-memory state.
func TestKillAtEveryPhaseBoundaryCompletesOnce(t *testing.T) {
	for _, phase := range PhaseBoundaries {
		phase := phase
		t.Run(phase, func(t *testing.T) {
			c := newCase(t)

			c.kill(t, "runner-a", phase)
			time.Sleep(TakeoverWait) // the dead owner's lease ages past its stall limit
			rep := c.complete(t, "runner-b")

			if rep.State != "completed" {
				t.Fatalf("recovery state = %q, want completed", rep.State)
			}
			if phase == PhaseCompleted {
				// The run was already finished. Recovery must say so, not
				// complete it again.
				if rep.SecondCompleteRefused == "" {
					t.Fatal("recovery accepted a second completion of a completed run")
				}
				if !strings.Contains(rep.SecondCompleteRefused, "terminal") {
					t.Errorf("second Complete err = %q, want the terminal-state refusal",
						rep.SecondCompleteRefused)
				}
				t.Logf("exactly-once: killed at %s; recovery replayed %s and was refused: %s",
					phase, rep.State, rep.SecondCompleteRefused)
			} else if rep.SecondCompleteRefused != "" {
				t.Errorf("recovery attempted a second completion: %s", rep.SecondCompleteRefused)
			}

			c.assertExactlyOnce(t, phase)
		})
	}
}

// TestKillBetweenIntentAndOutcomePerformsTheEffectOnce pins the crash window the
// ADR paid for: the intent row is committed, the effect has not run, and the
// process dies. Recovery must see the pending intent, run the effect once, and
// close it.
func TestKillBetweenIntentAndOutcomePerformsTheEffectOnce(t *testing.T) {
	c := newCase(t)
	c.kill(t, "runner-a", PhaseIntent)
	time.Sleep(TakeoverWait)
	rep := c.complete(t, "runner-b")

	if !contains(rep.Performed, KeyA) {
		t.Errorf("recovery performed %v, want the pending %s to run", rep.Performed, KeyA)
	}
	if keys := c.effectKeys(t); len(keys) != 2 || keys[0] != KeyA {
		t.Errorf("effect log = %v, want [%s %s]", keys, KeyA, KeyB)
	}
	c.assertExactlyOnce(t, PhaseIntent)
}

// TestKillBetweenEffectAndOutcomeReplaysNoSideEffect is the no-duplicate half of
// AC7: the effect ran, the outcome row did not, and the process died. Recovery
// must reconcile from the effect log and NOT run the effect again.
func TestKillBetweenEffectAndOutcomeReplaysNoSideEffect(t *testing.T) {
	c := newCase(t)
	c.kill(t, "runner-a", PhaseEffect)
	time.Sleep(TakeoverWait)
	rep := c.complete(t, "runner-b")

	if contains(rep.Performed, KeyA) {
		t.Errorf("recovery re-ran %s after a crash between effect and outcome: performed %v",
			KeyA, rep.Performed)
	}
	if !contains(rep.Performed, KeyB) {
		t.Errorf("recovery performed %v, want the run finished (%s)", rep.Performed, KeyB)
	}
	if keys := c.effectKeys(t); len(keys) != 2 || keys[0] != KeyA {
		t.Errorf("effect log = %v, want [%s %s] with no repeat of %s", keys, KeyA, KeyB, KeyA)
	}
	c.assertExactlyOnce(t, PhaseEffect)
}

// AC4 under a real kill: the killed owner's fencing token is stale for good.
// Every write it would attempt is refused and writes nothing; the takeover
// drives the run to the one completion.
func TestStaleFencingTokenAfterTakeoverWritesNothing(t *testing.T) {
	c := newCase(t)
	c.kill(t, "runner-a", PhaseRunning)
	time.Sleep(TakeoverWait)

	ctx := context.Background()
	eng := c.openEngine(t)
	defer eng.Close()
	m := c.machine(eng)

	before, err := eng.Events(ctx, RunID)
	if err != nil {
		t.Fatal(err)
	}
	st, err := m.State(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if st.Owner != "runner-a" || st.Token != 1 {
		t.Fatalf("pre-takeover owner/token = %q/%d, want runner-a/1", st.Owner, st.Token)
	}

	token, err := m.Claim(ctx, "runner-b", Ticket, Workflow, Model)
	if err != nil {
		t.Fatalf("takeover claim: %v", err)
	}
	if token != 2 {
		t.Fatalf("takeover token = %d, want 2 (the token is monotonic per run)", token)
	}
	if rows := c.countTakeovers(t, eng); rows != 1 {
		t.Errorf("lease_acquired rows = %d, want 1", rows)
	}

	zombie := map[string]func() error{
		"Stint":     func() error { return m.Stint(ctx, "runner-a", 1, "zombie") },
		"Heartbeat": func() error { return m.Heartbeat(ctx, "runner-a", 1) },
		"Halt":      func() error { return m.Halt(ctx, "runner-a", 1, run.ReasonOperatorHalt, "zombie") },
		"Intent":    func() error { _, _, e := m.Intent(ctx, "runner-a", 1, KeyA, EffectA, nil); return e },
		"Complete":  func() error { return m.Complete(ctx, "runner-a", 1, nil, nil) },
	}
	for _, name := range []string{"Stint", "Heartbeat", "Halt", "Intent", "Complete"} {
		if err := zombie[name](); !errors.Is(err, journal.ErrStaleToken) {
			t.Errorf("zombie %s with token 1: err = %v, want journal.ErrStaleToken", name, err)
		}
	}

	after, err := eng.Events(ctx, RunID)
	if err != nil {
		t.Fatal(err)
	}
	if len(after) != len(before)+1 {
		t.Errorf("journal rows %d -> %d, want +1 (the takeover only)", len(before), len(after))
	}
	if keys := c.effectKeys(t); len(keys) != 0 {
		t.Errorf("zombie ran side effects: %v", keys)
	}

	// The new owner proceeds, and the run completes once.
	if err := m.Stint(ctx, "runner-b", token, "stint 1"); err != nil {
		t.Fatal(err)
	}
	performed, err := RunEffect(ctx, m, "runner-b", token, EffectA, KeyA, c.effects, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !performed {
		t.Errorf("%s performed = false; the killed attempt died before the effect", KeyA)
	}
	if err := m.Complete(ctx, "runner-b", token, map[string]string{"by": "harness"}, nil); err != nil {
		t.Fatal(err)
	}

	rows, err := eng.Events(ctx, RunID)
	if err != nil {
		t.Fatal(err)
	}
	if n := countKind(rows, journal.KindRunCompleted); n != 1 {
		t.Errorf("exactly-once: run_completed rows = %d, want 1", n)
	}
	if keys := c.effectKeys(t); len(keys) != 1 || keys[0] != KeyA {
		t.Errorf("effect log = %v, want exactly [%s]", keys, KeyA)
	}
	if _, err := m.ReadLease(ctx); !errors.Is(err, journal.ErrNoLease) {
		t.Errorf("lease after completion: err = %v, want journal.ErrNoLease", err)
	}
}

// ReasonForTest is a halt reason from journal.HaltReasons, used to drive a
// zombie write.
const ReasonForTest = "operator_halt"

// A run that is already completed cannot be claimed again: the recovery attempt
// is refused, and the journal keeps its single completion.
func TestCompletedRunRefusesReclaim(t *testing.T) {
	c := newCase(t)
	c.kill(t, "runner-a", PhaseCompleted)
	time.Sleep(TakeoverWait)

	ctx := context.Background()
	eng := c.openEngine(t)
	defer eng.Close()
	m := c.machine(eng)

	if _, err := m.Claim(ctx, "runner-c", Ticket, Workflow, Model); !errors.Is(err, journal.ErrTerminalState) {
		t.Errorf("reclaim of a completed run: err = %v, want journal.ErrTerminalState", err)
	}
	c.assertExactlyOnce(t, PhaseCompleted)
}

// caseSet is one kill-test case: a journal file and an effect log in a private
// directory.
type caseSet struct {
	dir     string
	dbPath  string
	effects *EffectLog
}

func newCase(t *testing.T) *caseSet {
	t.Helper()
	dir := t.TempDir()
	return &caseSet{
		dir:     dir,
		dbPath:  filepath.Join(dir, "run.db"),
		effects: NewEffectLog(filepath.Join(dir, "effects.log")),
	}
}

// kill runs the helper at the named boundary and proves it died by SIGKILL.
func (c *caseSet) kill(t *testing.T, owner, phase string) {
	t.Helper()
	cmd := c.command(owner, phase, filepath.Join(c.dir, "victim-report.json"))
	out, err := cmd.CombinedOutput()
	if err == nil {
		t.Fatalf("helper at %s exited cleanly, want death by SIGKILL\n%s", phase, out)
	}
	ee, ok := err.(*exec.ExitError)
	if !ok {
		t.Fatalf("helper at %s: err = %v, want an ExitError\n%s", phase, err, out)
	}
	ws, ok := ee.Sys().(syscall.WaitStatus)
	if !ok {
		t.Fatalf("helper at %s: no wait status", phase)
	}
	if !ws.Signaled() || ws.Signal() != syscall.SIGKILL {
		t.Fatalf("helper at %s: exited=%d signaled=%v signal=%v, want death by SIGKILL\n%s",
			phase, ee.ExitCode(), ws.Signaled(), ws.Signal(), out)
	}
	if _, err := os.Stat(filepath.Join(c.dir, "victim-report.json")); !os.IsNotExist(err) {
		t.Errorf("the killed process wrote a report; SIGKILL must leave it no chance")
	}
	t.Logf("killed: pid died by SIGKILL at %s (journal %s)", phase, c.dbPath)
}

// complete runs the helper as the recovery owner and returns its report.
func (c *caseSet) complete(t *testing.T, owner string) Report {
	t.Helper()
	reportPath := filepath.Join(c.dir, "recovery-report.json")
	cmd := c.command(owner, "", reportPath)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("recovery helper: %v\n%s", err, out)
	}
	raw, err := os.ReadFile(reportPath)
	if err != nil {
		t.Fatalf("recovery report: %v\n%s", err, out)
	}
	var rep Report
	if err := json.Unmarshal(raw, &rep); err != nil {
		t.Fatalf("recovery report %q: %v", raw, err)
	}
	t.Logf("recovery: owner=%s token=%d state=%s performed=%v halts=%v resumed=%v",
		rep.Owner, rep.Token, rep.State, rep.Performed, rep.Halts, rep.Resumed)
	return rep
}

// command builds a helper invocation. Every value goes through the environment
// as its own entry, never as shell text.
func (c *caseSet) command(owner, killAt, reportPath string) *exec.Cmd {
	cmd := exec.Command(helperBin)
	cmd.Env = append(os.Environ(),
		EnvRunID+"="+RunID,
		EnvOwner+"="+owner,
		EnvDB+"="+c.dbPath,
		EnvEffects+"="+c.effects.Path(),
		EnvKillAt+"="+killAt,
		EnvReport+"="+reportPath,
		"DEVTEAM_MROOT="+c.dir,
		"DEVTEAM_STALL_LIMIT="+StallLimitSeconds,
	)
	return cmd
}

func (c *caseSet) openEngine(t *testing.T) *journal.Engine {
	t.Helper()
	eng, err := journal.OpenPath(context.Background(), c.dbPath)
	if err != nil {
		t.Fatalf("reopen journal %s: %v", c.dbPath, err)
	}
	return eng
}

// machine mirrors the helper's environment: the same one-second stall limit.
func (c *caseSet) machine(eng *journal.Engine) *run.Machine {
	m := run.New(eng, RunID)
	m.Getenv = func(string) string { return StallLimitSeconds }
	return m
}

func (c *caseSet) effectKeys(t *testing.T) []string {
	t.Helper()
	keys, err := c.effects.Keys()
	if err != nil {
		t.Fatal(err)
	}
	return keys
}

// countTakeovers counts lease_acquired rows.
func (c *caseSet) countTakeovers(t *testing.T, eng *journal.Engine) int {
	t.Helper()
	rows, err := eng.Events(context.Background(), RunID)
	if err != nil {
		t.Fatal(err)
	}
	return countKind(rows, journal.KindLeaseAcquire)
}

// assertExactlyOnce is the AC7 assertion set, read off the journal file and the
// effect log after the kill and the recovery.
func (c *caseSet) assertExactlyOnce(t *testing.T, phase string) {
	t.Helper()
	ctx := context.Background()
	eng := c.openEngine(t)
	defer eng.Close()

	rows, err := eng.Events(ctx, RunID)
	if err != nil {
		t.Fatal(err)
	}
	st, err := eng.RunState(ctx, RunID)
	if err != nil {
		t.Fatalf("replay after the kill at %s: %v", phase, err)
	}

	// 1. Exactly one completion, and no failure.
	if n := countKind(rows, journal.KindRunCompleted); n != 1 {
		t.Errorf("exactly-once: run_completed rows = %d, want 1 (killed at %s)", n, phase)
	} else {
		t.Logf("exactly-once: 1 run_completed row across every attempt (killed at %s)", phase)
	}
	if n := countKind(rows, journal.KindRunFailed); n != 0 {
		t.Errorf("run_failed rows = %d, want 0 (killed at %s)", n, phase)
	}
	if !st.IsTerminal() || st.Name() != "completed" {
		t.Fatalf("state after recovery = %s, want completed (killed at %s)", st.Name(), phase)
	}

	// 2. No side-effect intent was replayed: one intent row per key, one run of
	// each effect in the external log, and no intent left pending.
	intentByKey := map[string]int{}
	for _, r := range rows {
		if r.Kind == journal.KindSideEffect && r.IntentRow() {
			intentByKey[r.IdempotencyKey]++
		}
	}
	for _, key := range []string{KeyA, KeyB} {
		if n := intentByKey[key]; n != 1 {
			t.Errorf("intent rows for %s = %d, want 1 (killed at %s)", key, n, phase)
		}
	}
	if len(st.Effects) != len(intentByKey) {
		t.Errorf("replayed effects = %d, intent keys = %d (killed at %s)",
			len(st.Effects), len(intentByKey), phase)
	}
	if pend := st.PendingEffects(); len(pend) != 0 {
		t.Errorf("effects left pending after recovery: %d (killed at %s)", len(pend), phase)
	}
	keys := c.effectKeys(t)
	if len(keys) != 2 {
		t.Errorf("effect log holds %d records %v, want 2 — a side effect ran twice or not once",
			len(keys), keys)
	}
	for i, want := range []string{KeyA, KeyB} {
		if i < len(keys) && keys[i] != want {
			t.Errorf("effect log[%d] = %s, want %s (killed at %s)", i, keys[i], want, phase)
		}
	}

	// 3. One owner per run, and the completed run left no live lease behind.
	wantTakeovers := 1
	if phase == PhaseCompleted {
		wantTakeovers = 0 // the completion released the lease before the kill
	}
	if st.LeaseTakeovers != wantTakeovers {
		t.Errorf("lease takeovers = %d, want %d (killed at %s)", st.LeaseTakeovers, wantTakeovers, phase)
	}
	if st.ClaimCount != 1 {
		t.Errorf("run_claimed rows = %d, want 1 (killed at %s)", st.ClaimCount, phase)
	}
	if _, err := c.machine(eng).ReadLease(ctx); !errors.Is(err, journal.ErrNoLease) {
		t.Errorf("lease after completion: err = %v, want journal.ErrNoLease (killed at %s)", err, phase)
	}
}

func countKind(rows []journal.Event, kind journal.Kind) int {
	n := 0
	for _, r := range rows {
		if r.Kind == kind {
			n++
		}
	}
	return n
}

func contains(haystack []string, needle string) bool {
	for _, s := range haystack {
		if s == needle {
			return true
		}
	}
	return false
}
