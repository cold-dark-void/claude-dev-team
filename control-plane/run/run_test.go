package run

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"testing"
	"time"

	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
)

// clock is a controllable UTC clock: the watchdog and lease expiry are judged
// against it, so no test sleeps.
type clock struct{ t time.Time }

func (c *clock) now() time.Time { return c.t }
func (c *clock) advance(d time.Duration) {
	c.t = c.t.Add(d).UTC()
}

func newTestMachine(t *testing.T, runID, model string) (*Machine, *journal.Engine, *clock) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "run.db")
	eng, err := journal.OpenPath(context.Background(), path)
	if err != nil {
		t.Fatalf("OpenPath: %v", err)
	}
	t.Cleanup(func() { _ = eng.Close() })

	c := &clock{t: time.Date(2026, 11, 16, 12, 0, 0, 0, time.UTC)}
	m := New(eng, runID)
	m.Now = c.now
	m.Getenv = func(string) string { return "" } // no env layer: map and tier only
	return m, eng, c
}

// reopen stands in for a SIGKILL and a restart: the state must come back from
// the journal file alone.
func reopen(t *testing.T, path, runID, model string) (*Machine, *journal.Engine) {
	t.Helper()
	eng, err := journal.OpenPath(context.Background(), path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	t.Cleanup(func() { _ = eng.Close() })
	c := &clock{t: time.Date(2026, 11, 16, 12, 0, 0, 0, time.UTC)}
	m := New(eng, runID)
	m.Now = c.now
	m.Getenv = func(string) string { return "" }
	return m, eng
}

// AC4: one owner per run, enforced by a monotonic fencing token.
func TestLeaseFencing(t *testing.T) {
	m, eng, clk := newTestMachine(t, "CDT-643", "sonnet")
	ctx := context.Background()

	token, err := m.Claim(ctx, "runner-a", "CDT-643", "orchestrate", "sonnet")
	if err != nil {
		t.Fatalf("Claim: %v", err)
	}
	if token != 1 {
		t.Fatalf("first token = %d, want 1", token)
	}

	// A live lease blocks a second owner.
	if _, err := m.Claim(ctx, "runner-b", "CDT-643", "orchestrate", "sonnet"); !errors.Is(err, journal.ErrLeaseHeld) {
		t.Fatalf("second owner err = %v, want ErrLeaseHeld", err)
	}
	// The same owner re-claiming keeps its token.
	again, err := m.Claim(ctx, "runner-a", "CDT-643", "orchestrate", "sonnet")
	if err != nil {
		t.Fatalf("re-claim: %v", err)
	}
	if again != token {
		t.Fatalf("re-claim token = %d, want %d", again, token)
	}

	if err := m.Start(ctx, "runner-a", token, "sonnet"); err != nil {
		t.Fatalf("Start: %v", err)
	}

	// The owner goes quiet past its own stall limit; runner-b takes over at the
	// next token.
	limit, source, err := ResolveStallLimit("sonnet", m.Getenv)
	if err != nil {
		t.Fatal(err)
	}
	if source != "map" {
		t.Fatalf("stall source = %s, want map", source)
	}
	clk.advance(limit + time.Second)

	tokenB, err := m.Claim(ctx, "runner-b", "CDT-643", "orchestrate", "sonnet")
	if err != nil {
		t.Fatalf("takeover Claim: %v", err)
	}
	if tokenB != token+1 {
		t.Fatalf("takeover token = %d, want %d", tokenB, token+1)
	}

	// Every write the old owner attempts now is refused, and writes nothing.
	before, err := m.State(ctx)
	if err != nil {
		t.Fatal(err)
	}
	// journal.Engine.AppendChecked has no fencing by design: the journal checks
	// transition legality, and the run package owns fencing (AC4). So a stale
	// token at this layer is reported, not asserted; the fenced calls below are
	// the AC4 contract.
	if _, _, err := eng.AppendChecked(ctx, mustHeartbeat(t, "CDT-643", "runner-a", token)); !errors.Is(err, journal.ErrStaleToken) {
		t.Logf("AppendChecked with a stale token: %v", err)
	}
	for name, call := range map[string]func() error{
		"heartbeat": func() error { return m.Heartbeat(ctx, "runner-a", token) },
		"stint":     func() error { return m.Stint(ctx, "runner-a", token, "zombie") },
		"halt":      func() error { return m.Halt(ctx, "runner-a", token, ReasonOperatorHalt, "x") },
		"complete":  func() error { return m.Complete(ctx, "runner-a", token, nil, nil) },
		"fail":      func() error { return m.Fail(ctx, "runner-a", token, "zombie") },
		"repair":    func() error { return m.Repair(ctx, "runner-a", token, "t", "o", "a") },
		"intent":    func() error { _, _, e := m.Intent(ctx, "runner-a", token, "k", "push", nil); return e },
		"resume":    func() error { return m.Resume(ctx, "runner-a", token) },
		"outcome":   func() error { _, e := m.Outcome(ctx, "runner-a", token, 1, "push", nil); return e },
		"start":     func() error { return m.Start(ctx, "runner-a", token, "sonnet") },
		"bad-owner": func() error { return m.Heartbeat(ctx, "runner-c", tokenB) },
	} {
		err := call()
		want := journal.ErrStaleToken
		if name == "bad-owner" {
			want = journal.ErrNotOwner
		}
		if !errors.Is(err, want) {
			t.Errorf("%s with a stale token: err = %v, want %v", name, err, want)
		}
	}

	after, err := m.State(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if after.EventCount != before.EventCount {
		t.Fatalf("refused writes added events: %d -> %d", before.EventCount, after.EventCount)
	}

	// The new owner works normally, and the journal records the takeover.
	if err := m.Stint(ctx, "runner-b", tokenB, "wave 2"); err != nil {
		t.Fatalf("new owner Stint: %v", err)
	}
	st, err := m.State(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if st.Owner != "runner-b" || st.Token != tokenB {
		t.Fatalf("state owner/token = %q/%d", st.Owner, st.Token)
	}
	if st.LeaseTakeovers != 1 {
		t.Fatalf("takeovers = %d, want 1", st.LeaseTakeovers)
	}
}

func mustHeartbeat(t *testing.T, runID, owner string, token int64) journal.Event {
	t.Helper()
	ev, err := journal.NewEvent(runID, journal.KindHeartbeat,
		journal.HeartbeatPayload{Owner: owner, Token: token})
	if err != nil {
		t.Fatal(err)
	}
	return ev
}

// AC6: each named halt state carries a reason and a retry budget, and a resume
// spends one.
func TestHaltStatesAndRetryBudget(t *testing.T) {
	m, _, clk := newTestMachine(t, "CDT-643", "sonnet")
	ctx := context.Background()

	token, err := m.Claim(ctx, "runner-a", "CDT-643", "orchestrate", "sonnet")
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Start(ctx, "runner-a", token, "sonnet"); err != nil {
		t.Fatal(err)
	}
	if err := m.Stint(ctx, "runner-a", token, "wave 1"); err != nil {
		t.Fatal(err)
	}

	// Watchdog: inside the limit, nothing; past it, halted:stalled.
	halted, err := m.Watchdog(ctx, "runner-a", token)
	if err != nil {
		t.Fatal(err)
	}
	if halted {
		t.Fatal("watchdog halted inside the stall limit")
	}
	limit, _, _ := ResolveStallLimit("sonnet", m.Getenv)
	clk.advance(limit + time.Minute)
	if halted, err = m.Watchdog(ctx, "runner-a", token); err != nil || !halted {
		t.Fatalf("watchdog past the limit: halted=%v err=%v", halted, err)
	}

	st, err := m.State(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if st.Name() != "halted:stalled" {
		t.Fatalf("state = %s, want halted:stalled", st.Name())
	}
	budget, err := RetryBudget(ReasonStalled)
	if err != nil {
		t.Fatal(err)
	}
	if st.Halt == nil || st.Halt.Budget != budget || st.Halt.Remaining != budget {
		t.Fatalf("halt = %+v, want budget %d remaining %d", st.Halt, budget, budget)
	}
	if st.Halt.Detail == "" {
		t.Error("halt carries no reason detail")
	}

	// Spend the budget one resume at a time.
	for i := budget; i > 0; i-- {
		if err := m.Resume(ctx, "runner-a", token); err != nil {
			t.Fatalf("resume %d: %v", budget-i+1, err)
		}
		if err := m.Halt(ctx, "runner-a", token, ReasonStalled, "again"); err != nil {
			t.Fatalf("halt %d: %v", budget-i+1, err)
		}
		st, err := m.State(ctx)
		if err != nil {
			t.Fatal(err)
		}
		want := i - 1
		if st.Halt.Remaining != want {
			t.Fatalf("after halt %d: remaining = %d, want %d", budget-i+1, st.Halt.Remaining, want)
		}
	}

	// Budget spent: a resume is refused, and the refusal writes nothing.
	before, err := m.State(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Resume(ctx, "runner-a", token); !errors.Is(err, journal.ErrBudgetExhausted) {
		t.Fatalf("resume on a spent budget: err = %v, want ErrBudgetExhausted", err)
	}
	if err := m.Halt(ctx, "runner-a", token, ReasonStalled, "one more"); !errors.Is(err, journal.ErrBudgetExhausted) {
		t.Fatalf("halt on a spent budget: err = %v, want ErrBudgetExhausted", err)
	}
	after, err := m.State(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if after.EventCount != before.EventCount {
		t.Fatalf("refused resume/halt wrote events: %d -> %d", before.EventCount, after.EventCount)
	}

	// A halt state with a zero budget: operator_halt is not resumable by the
	// machine.
	if err := m.Fail(ctx, "runner-a", token, "stall budget exhausted"); err != nil {
		t.Fatalf("Fail after exhausted budget: %v", err)
	}
	st, err = m.State(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if st.Name() != "failed" || !st.IsTerminal() || st.Failure == nil {
		t.Fatalf("state = %+v, want failed with a failure record", st)
	}
	if _, err := m.ReadLease(ctx); !errors.Is(err, journal.ErrNoLease) {
		t.Fatalf("lease after terminal: err = %v, want ErrNoLease", err)
	}
}

// AC6: the watchdog takes the halt inside the halt transaction. Liveness that
// lands after the liveness read cancels the stall, so a run that was
// heartbeating does not lose a retry budget to a spurious halted:stalled.
func TestWatchdogCancelsWhenLivenessLandsFirst(t *testing.T) {
	// land stands in for the heartbeat that wins the race against the halt.
	run := func(t *testing.T,
		land func(t *testing.T, eng *journal.Engine, clk *clock, token int64)) {
		t.Helper()
		m, eng, clk := newTestMachine(t, "CDT-643", "sonnet")
		ctx := context.Background()
		token, err := m.Claim(ctx, "runner-a", "CDT-643", "orchestrate", "sonnet")
		if err != nil {
			t.Fatalf("Claim: %v", err)
		}
		if err := m.Start(ctx, "runner-a", token, "sonnet"); err != nil {
			t.Fatalf("Start: %v", err)
		}
		limit, _, err := ResolveStallLimit("sonnet", m.Getenv)
		if err != nil {
			t.Fatal(err)
		}
		clk.advance(limit + time.Minute)
		land(t, eng, clk, token)

		if halted, err := m.Watchdog(ctx, "runner-a", token); err != nil || halted {
			t.Fatalf("watchdog with fresh liveness: halted=%v err=%v, want false, nil", halted, err)
		}
		st, err := m.State(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if st.Name() != "running" {
			t.Fatalf("state = %s, want running: the cancelled stall spent a budget", st.Name())
		}

		// The cancel is per reading, not a permanent exemption: a run that stays
		// quiet past the limit is halted after all.
		clk.advance(limit + time.Minute)
		if halted, err := m.Watchdog(ctx, "runner-a", token); err != nil || !halted {
			t.Fatalf("watchdog after a second stall: halted=%v err=%v, want true, nil", halted, err)
		}
		if st, err = m.State(ctx); err != nil {
			t.Fatal(err)
		}
		if st.Name() != "halted:stalled" {
			t.Fatalf("state = %s, want halted:stalled", st.Name())
		}
	}

	t.Run("lease heartbeat lands first", func(t *testing.T) {
		run(t, func(t *testing.T, eng *journal.Engine, clk *clock, _ int64) {
			if _, err := eng.ExecContext(context.Background(),
				`UPDATE lease SET last_heartbeat_ts = ? WHERE run_id = ?`,
				journal.FormatTS(clk.now()), "CDT-643"); err != nil {
				t.Fatalf("lease heartbeat: %v", err)
			}
		})
	})

	t.Run("journal heartbeat lands first", func(t *testing.T) {
		run(t, func(t *testing.T, eng *journal.Engine, clk *clock, token int64) {
			ev := mustHeartbeat(t, "CDT-643", "runner-a", token)
			ev.TS = journal.FormatTS(clk.now())
			if _, _, err := eng.AppendChecked(context.Background(), ev); err != nil {
				t.Fatalf("journal heartbeat: %v", err)
			}
		})
	})
}

// AC3: an idempotency key survives a crash, so a replay repeats no effect.
func TestIdempotencyKeySurvivesReopen(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "run.db")
	eng, err := journal.OpenPath(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	c := &clock{t: time.Date(2026, 11, 16, 12, 0, 0, 0, time.UTC)}
	m := New(eng, "CDT-643")
	m.Now = c.now
	m.Getenv = func(string) string { return "" }

	token, err := m.Claim(ctx, "runner-a", "CDT-643", "orchestrate", "sonnet")
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Start(ctx, "runner-a", token, "sonnet"); err != nil {
		t.Fatal(err)
	}

	key := "CDT-643:push:abc123"
	seq, created, err := m.Intent(ctx, "runner-a", token, key, "push",
		map[string]string{"sha": "abc123"})
	if err != nil || !created {
		t.Fatalf("Intent: seq=%d created=%v err=%v", seq, created, err)
	}

	// Crash: the process dies with the intent recorded and no outcome.
	_ = eng.Close()
	m2, eng2 := reopen(t, path, "CDT-643", "sonnet")
	if err := eng2.Transact(ctx, func(tx *journal.Tx) error { return nil }); err != nil {
		t.Fatal(err)
	}
	st, err := m2.State(ctx)
	if err != nil {
		t.Fatal(err)
	}
	pending := st.PendingEffects()
	if len(pending) != 1 || pending[0].Key != key || pending[0].Seq != seq {
		t.Fatalf("after reopen, pending effects = %+v, want the one open intent at seq %d",
			pending, seq)
	}

	// A new owner takes the expired lease and replays the same effect step.
	m2.Now = func() time.Time {
		return c.now().Add(10 * time.Minute)
	}
	tokenB, err := m2.Claim(ctx, "runner-b", "CDT-643", "orchestrate", "sonnet")
	if err != nil {
		t.Fatalf("takeover: %v", err)
	}
	if _, created, err := m2.Intent(ctx, "runner-b", tokenB, key, "push",
		map[string]string{"sha": "abc123"}); err != nil || created {
		t.Fatalf("replayed Intent: created=%v err=%v, want created=false (the effect already ran)",
			created, err)
	}
	rows, err := eng2.Events(ctx, "CDT-643")
	if err != nil {
		t.Fatal(err)
	}
	var intents int
	for _, r := range rows {
		if r.IdempotencyKey == key {
			intents++
		}
	}
	if intents != 1 {
		t.Fatalf("rows for key %s = %d, want 1", key, intents)
	}

	// The reconciler closes it with the outcome (AC5 seam).
	if _, err := m2.Outcome(ctx, "runner-b", tokenB, seq, "push",
		map[string]any{"pushed": true}); err != nil {
		t.Fatalf("Outcome: %v", err)
	}
	st, err = m2.State(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(st.PendingEffects()) != 0 {
		t.Fatalf("pending after outcome = %+v", st.PendingEffects())
	}
	eff, ok := st.EffectByKey(key)
	if !ok || eff.OutcomeSeq == 0 {
		t.Fatalf("effect = %+v, want a closed outcome", eff)
	}
}

// AC5 + AC7 groundwork: the reconciler's comparison data, and exactly-once
// completion across a crash at every lifecycle phase boundary.
func TestKillAtEachPhaseBoundaryCompletesOnce(t *testing.T) {
	// phaseBoundaries are the points a kill -9 can land between journal writes.
	phases := []string{"claimed", "running", "stint1", "intent", "outcome", "halted", "resumed"}
	dir := t.TempDir()

	for _, phase := range phases {
		t.Run(phase, func(t *testing.T) {
			path := filepath.Join(dir, phase, "run.db")
			eng, err := journal.OpenPath(context.Background(), path)
			if err != nil {
				t.Fatal(err)
			}
			ctx := context.Background()
			c := &clock{t: time.Date(2026, 11, 16, 12, 0, 0, 0, time.UTC)}
			m := New(eng, "CDT-643")
			m.Now = c.now
			m.Getenv = func(string) string { return "" }

			token, err := m.Claim(ctx, "runner-a", "CDT-643", "orchestrate", "sonnet")
			if err != nil {
				t.Fatal(err)
			}
			stop := map[string]bool{}
			mark := func(name string) { stop[name] = true }
			mark("claimed")
			if stop[phase] {
				_ = eng.Close()
				finishAfterKill(t, path, phase)
				return
			}
			if err := m.Start(ctx, "runner-a", token, "sonnet"); err != nil {
				t.Fatal(err)
			}
			mark("running")
			if stop[phase] {
				_ = eng.Close()
				finishAfterKill(t, path, phase)
				return
			}
			if err := m.Stint(ctx, "runner-a", token, "wave 1"); err != nil {
				t.Fatal(err)
			}
			mark("stint1")
			if stop[phase] {
				_ = eng.Close()
				finishAfterKill(t, path, phase)
				return
			}
			seq, _, err := m.Intent(ctx, "runner-a", token, "CDT-643:release:1", "release",
				map[string]string{"version": "2.0.0-pre.4"})
			if err != nil {
				t.Fatal(err)
			}
			mark("intent")
			if stop[phase] {
				_ = eng.Close()
				finishAfterKill(t, path, phase)
				return
			}
			if _, err := m.Outcome(ctx, "runner-a", token, seq, "release",
				map[string]any{"tag": "v2.0.0-pre.4"}); err != nil {
				t.Fatal(err)
			}
			mark("outcome")
			if stop[phase] {
				_ = eng.Close()
				finishAfterKill(t, path, phase)
				return
			}
			if err := m.Halt(ctx, "runner-a", token, ReasonStalled, "simulated"); err != nil {
				t.Fatal(err)
			}
			mark("halted")
			if stop[phase] {
				_ = eng.Close()
				finishAfterKill(t, path, phase)
				return
			}
			if err := m.Resume(ctx, "runner-a", token); err != nil {
				t.Fatal(err)
			}
			_ = eng.Close()
			finishAfterKill(t, path, phase)
		})
	}
}

// finishAfterKill reopens the journal as a fresh process, takes the expired
// lease, and drives the run to completion. It asserts the run completes exactly
// once, and that a second completion is refused.
func finishAfterKill(t *testing.T, path, phase string) {
	t.Helper()
	ctx := context.Background()
	eng, err := journal.OpenPath(context.Background(), path)
	if err != nil {
		t.Fatalf("reopen after kill at %s: %v", phase, err)
	}
	defer eng.Close()

	c := &clock{t: time.Date(2026, 11, 16, 13, 0, 0, 0, time.UTC)} // past any stall limit
	m := New(eng, "CDT-643")
	m.Now = c.now
	m.Getenv = func(string) string { return "" }

	st, err := m.State(ctx)
	if err != nil {
		t.Fatalf("state after kill: %v", err)
	}
	token, err := m.Claim(ctx, "runner-recovery", "CDT-643", "orchestrate", st.Model)
	if err != nil {
		t.Fatalf("recovery claim: %v", err)
	}
	// A run killed while halted stays halted: the resume spends its retry, and
	// a run killed before Start is started first.
	switch st.Status {
	case journal.StatusHalted:
		if err := m.Resume(ctx, "runner-recovery", token); err != nil {
			t.Fatalf("recovery resume: %v", err)
		}
	case journal.StatusClaimed:
		if err := m.Start(ctx, "runner-recovery", token, st.Model); err != nil {
			t.Fatalf("recovery start: %v", err)
		}
	}
	if err := m.Complete(ctx, "runner-recovery", token,
		map[string]string{"phase": phase}, nil); err != nil {
		t.Fatalf("recovery complete: %v", err)
	}

	// Exactly one completion, from any observer's replay of the file.
	final, err := m.State(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if final.Name() != "completed" {
		t.Fatalf("state after recovery = %s, want completed", final.Name())
	}
	rows, err := eng.Events(ctx, "CDT-643")
	if err != nil {
		t.Fatal(err)
	}
	var completions int
	for _, r := range rows {
		if r.Kind == journal.KindRunCompleted {
			completions++
		}
	}
	if completions != 1 {
		t.Fatalf("completed events = %d, want exactly 1", completions)
	}
	// A second attempt is refused and writes nothing.
	if err := m.Complete(ctx, "runner-recovery", token, nil, nil); !errors.Is(err, journal.ErrTerminalState) {
		t.Fatalf("second Complete err = %v, want ErrTerminalState", err)
	}
	after, err := eng.Events(ctx, "CDT-643")
	if err != nil {
		t.Fatal(err)
	}
	if len(after) != len(rows) {
		t.Fatalf("refused Complete wrote rows: %d -> %d", len(rows), len(after))
	}
}

// AC4: one owner per run, proven under contention. Eight would-be owners claim
// the same run at once; exactly one gets a token and the rest are refused.
func TestOneOwnerPerRunUnderContention(t *testing.T) {
	m, eng, _ := newTestMachine(t, "CDT-643", "sonnet")
	ctx := context.Background()

	const racers = 8
	type result struct {
		owner string
		token int64
		err   error
	}
	done := make(chan result, racers)
	start := make(chan struct{})
	for i := 0; i < racers; i++ {
		owner := fmt.Sprintf("runner-%d", i)
		go func() {
			<-start
			tok, err := m.Claim(ctx, owner, "CDT-643", "orchestrate", "sonnet")
			done <- result{owner: owner, token: tok, err: err}
		}()
	}
	close(start)

	won, held := 0, 0
	for i := 0; i < racers; i++ {
		r := <-done
		switch {
		case r.err == nil:
			won++
			if r.token != 1 {
				t.Errorf("winner %s token = %d, want 1", r.owner, r.token)
			}
		case errors.Is(r.err, journal.ErrLeaseHeld) || errors.Is(r.err, journal.ErrBusy):
			held++
		default:
			t.Errorf("Claim for %s err = %v, want the token or ErrLeaseHeld", r.owner, r.err)
		}
	}
	if won != 1 {
		t.Fatalf("winners = %d, want exactly 1 (refused: %d)", won, held)
	}

	// One claim row, one lease row, one owner.
	st, err := m.State(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if st.ClaimCount != 1 {
		t.Fatalf("claims = %d, want 1", st.ClaimCount)
	}
	lease, err := m.ReadLease(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if lease.Owner != st.Owner || lease.Token != st.Token {
		t.Fatalf("lease %+v does not match state owner %q token %d", lease, st.Owner, st.Token)
	}
	rows, err := eng.Events(ctx, "CDT-643")
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 {
		t.Fatalf("journal rows = %d, want 1", len(rows))
	}
}

// AC6: every named halt state has a reason and a retry budget, and the closed
// set is shared with the journal's.
func TestEveryHaltStateHasARetryBudget(t *testing.T) {
	if len(RetryBudgets) != len(journal.HaltReasons) {
		t.Fatalf("budgets %d, halt reasons %d", len(RetryBudgets), len(journal.HaltReasons))
	}
	for _, reason := range journal.HaltReasons {
		budget, err := RetryBudget(reason)
		if err != nil {
			t.Errorf("%s: %v", reason, err)
			continue
		}
		if budget < 0 {
			t.Errorf("%s: budget %d is negative", reason, budget)
		}
		if !journal.ValidHaltReason(reason) {
			t.Errorf("%s is not in the journal's closed halt-reason set", reason)
		}
	}
	for _, reason := range []string{"stalled", "lease_lost", "reconcile_failed"} {
		budget, err := RetryBudget(reason)
		if err != nil || budget < 1 {
			t.Errorf("%s: budget = %d err = %v, want a resumable budget", reason, budget, err)
		}
	}
	// An unknown reason is a configuration error, never a silent zero.
	if _, err := RetryBudget("exploded"); !errors.Is(err, ErrConfig) {
		t.Fatalf("RetryBudget(unknown) err = %v, want ErrConfig", err)
	}
}

// AC6: the stall limit scales with the model, from the run-budget map, and env
// wins over it. No number is tuned here: CDT-610 is the precondition (AC9).
func TestStallLimitPrecedence(t *testing.T) {
	t.Run("env beats the map", func(t *testing.T) {
		env := func(k string) string {
			if k == EnvStallLimit {
				return "30"
			}
			return ""
		}
		d, source, err := ResolveStallLimit("opus", env)
		if err != nil {
			t.Fatal(err)
		}
		if d != 30*time.Second || source != "env" {
			t.Fatalf("stall = %s from %s, want 30s from env", d, source)
		}
	})

	t.Run("map scales with the model", func(t *testing.T) {
		empty := func(string) string { return "" }
		opus, srcOpus, err := ResolveStallLimit("opus", empty)
		if err != nil {
			t.Fatal(err)
		}
		sonnet, srcSonnet, err := ResolveStallLimit("sonnet", empty)
		if err != nil {
			t.Fatal(err)
		}
		if srcOpus != "map" || srcSonnet != "map" {
			t.Fatalf("sources = %s/%s, want map/map", srcOpus, srcSonnet)
		}
		if opus <= sonnet {
			t.Fatalf("opus stall %s must exceed sonnet stall %s: a deep-stint model needs a longer limit",
				opus, sonnet)
		}
	})

	t.Run("an unmapped model takes the tier default", func(t *testing.T) {
		empty := func(string) string { return "" }
		for _, model := range []string{"", "haiku", "gpt-5.1-codex", "opus-4.1-2026"} {
			d, source, err := ResolveStallLimit(model, empty)
			if err != nil {
				t.Fatalf("model %q: %v", model, err)
			}
			want := TierDefault.StallLimit()
			if source != "tier" || d != want {
				t.Fatalf("model %q: stall = %s from %s, want %s from tier", model, d, source, want)
			}
		}
	})

	t.Run("a bad env value is a configuration error", func(t *testing.T) {
		for _, raw := range []string{"abc", "0", "-5", "12s"} {
			env := func(k string) string {
				if k == EnvStallLimit {
					return raw
				}
				return ""
			}
			if _, _, err := ResolveStallLimit("opus", env); !errors.Is(err, ErrConfig) {
				t.Fatalf("%s=%q err = %v, want ErrConfig", EnvStallLimit, raw, err)
			}
		}
	})

	t.Run("the map rows are the SPEC-033 cells, undivided by tuning", func(t *testing.T) {
		// The stall limit is wall-clock cap / iteration cap of the same row, so
		// it introduces no number SPEC-033 does not already carry (AC9).
		for _, row := range RunBudgetMap {
			want := time.Duration(row.WallClockCapS/row.IterationCap) * time.Second
			if got := row.StallLimit(); got != want {
				t.Errorf("%s stall = %s, want %s (%d/%d)", row.Model, got, want,
					row.WallClockCapS, row.IterationCap)
			}
		}
	})
}

// AC1: an invalid transition writes nothing, and the journal is the only state.
func TestInvalidTransitionWritesNothing(t *testing.T) {
	m, eng, _ := newTestMachine(t, "CDT-643", "sonnet")
	ctx := context.Background()

	token, err := m.Claim(ctx, "runner-a", "CDT-643", "orchestrate", "sonnet")
	if err != nil {
		t.Fatal(err)
	}

	// From claimed, these are all illegal.
	for name, call := range map[string]func() error{
		"stint":     func() error { return m.Stint(ctx, "runner-a", token, "early") },
		"complete":  func() error { return m.Complete(ctx, "runner-a", token, nil, nil) },
		"intent":    func() error { _, _, e := m.Intent(ctx, "runner-a", token, "k", "push", nil); return e },
		"resume":    func() error { return m.Resume(ctx, "runner-a", token) },
		"heartbeat": func() error { return m.Heartbeat(ctx, "runner-a", token) },
	} {
		if err := call(); err == nil {
			t.Errorf("%s from claimed succeeded", name)
		}
	}
	rows, err := eng.Events(ctx, "CDT-643")
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].Kind != journal.KindRunClaimed {
		t.Fatalf("journal = %+v, want only the claim row", rows)
	}

	// Starting twice is illegal the second time.
	if err := m.Start(ctx, "runner-a", token, "sonnet"); err != nil {
		t.Fatal(err)
	}
	if err := m.Start(ctx, "runner-a", token, "sonnet"); !errors.Is(err, journal.ErrTransition) {
		t.Fatalf("second Start err = %v, want ErrTransition", err)
	}
	st, err := m.State(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if st.EventCount != 2 {
		t.Fatalf("events = %d, want 2", st.EventCount)
	}

	// A claim of a terminal run is refused.
	if err := m.Stint(ctx, "runner-a", token, "wave 1"); err != nil {
		t.Fatal(err)
	}
	if err := m.Complete(ctx, "runner-a", token, map[string]string{"ok": "yes"},
		&journal.CardRef{Path: ".claude/autopilot/CDT-643.jsonl",
			TS: "2026-11-16T12:00:00Z", RunID: "CDT-643"}); err != nil {
		t.Fatal(err)
	}
	if _, err := m.Claim(ctx, "runner-b", "CDT-643", "orchestrate", "sonnet"); !errors.Is(err, journal.ErrTerminalState) {
		t.Fatalf("claim of a completed run err = %v, want ErrTerminalState", err)
	}
	final, err := m.State(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if final.Name() != "completed" || final.Result == nil {
		t.Fatalf("final state = %+v", final)
	}
	if _, err := m.ReadLease(ctx); !errors.Is(err, journal.ErrNoLease) {
		t.Fatalf("lease after completion: %v", err)
	}
}

// AC5: the reconciler's read-only comparison of journal, lease, and clock.
func TestRecoveryPlanReportsTheDifference(t *testing.T) {
	m, _, clk := newTestMachine(t, "CDT-643", "sonnet")
	ctx := context.Background()

	plan, err := m.RecoveryPlan(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if plan.State != "new" || plan.LeaseLive || len(plan.Actions) != 0 {
		t.Fatalf("plan for an untouched run = %+v", plan)
	}

	token, err := m.Claim(ctx, "runner-a", "CDT-643", "orchestrate", "sonnet")
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Start(ctx, "runner-a", token, "sonnet"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := m.Intent(ctx, "runner-a", token, "CDT-643:ticket:1", "ticket",
		map[string]string{"title": "CDT-643"}); err != nil {
		t.Fatal(err)
	}

	plan, err = m.RecoveryPlan(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if plan.State != "running" || !plan.LeaseLive || plan.LeaseExpired || plan.Stalled {
		t.Fatalf("plan on a live run = %+v", plan)
	}
	if len(plan.PendingEffects) != 1 || plan.PendingEffects[0].Effect != "ticket" {
		t.Fatalf("pending effects = %+v", plan.PendingEffects)
	}
	if len(plan.Actions) != 1 || plan.Actions[0] != "resolve-effect:CDT-643:ticket:1" {
		t.Fatalf("actions = %v, want the one open effect", plan.Actions)
	}

	// The owner dies: the lease expires and the run is stalled.
	limit, _, _ := ResolveStallLimit("sonnet", m.Getenv)
	clk.advance(limit + 2*time.Minute)
	plan, err = m.RecoveryPlan(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if !plan.LeaseExpired || !plan.Stalled {
		t.Fatalf("plan after the owner died = %+v", plan)
	}
	want := []string{"take-over-lease", "resolve-effect:CDT-643:ticket:1", "halt:stalled"}
	if len(plan.Actions) != len(want) {
		t.Fatalf("actions = %v, want %v", plan.Actions, want)
	}
	for i := range want {
		if plan.Actions[i] != want[i] {
			t.Fatalf("actions = %v, want %v", plan.Actions, want)
		}
	}

	// A plan writes nothing.
	st, err := m.State(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if st.EventCount != 3 {
		t.Fatalf("events = %d, want 3 (claim, start, intent)", st.EventCount)
	}
}

// SPEC-046 M7: the caps a run starts with ride its own run_started payload —
// no new event kind — so a retry and a takeover re-spawn read them back from
// the journal. Start alone keeps the payload bare: 0 means the run carries no
// operator cap.
func TestStartWithCapsJournalsTheCapsOnRunStarted(t *testing.T) {
	ctx := context.Background()
	m, eng, _ := newTestMachine(t, "CDT-677", "sonnet")
	token, err := m.Claim(ctx, "runner-a", "CDT-677", "orchestrate", "sonnet")
	if err != nil {
		t.Fatalf("Claim: %v", err)
	}
	if err := m.StartWithCaps(ctx, "runner-a", token, "sonnet", 7200, 40); err != nil {
		t.Fatalf("StartWithCaps: %v", err)
	}
	st, err := m.State(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if st.WallclockCapS != 7200 || st.IterationCapS != 40 {
		t.Errorf("caps = %d/%d, want 7200/40", st.WallclockCapS, st.IterationCapS)
	}
	if n := countKind(t, eng, "CDT-677", journal.KindRunStarted); n != 1 {
		t.Errorf("run_started rows = %d, want the one start (no new event kind)", n)
	}
}

// A start that names no caps journals none: a run the operator left alone
// keeps the budget the plugin derives for itself (SPEC-033 N14).
func TestStartCarriesNoCaps(t *testing.T) {
	ctx := context.Background()
	m, _, _ := newTestMachine(t, "CDT-677-bare", "sonnet")
	token, err := m.Claim(ctx, "runner-a", "CDT-677-bare", "orchestrate", "sonnet")
	if err != nil {
		t.Fatalf("Claim: %v", err)
	}
	if err := m.Start(ctx, "runner-a", token, "sonnet"); err != nil {
		t.Fatalf("Start: %v", err)
	}
	st, err := m.State(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if st.WallclockCapS != 0 || st.IterationCapS != 0 {
		t.Errorf("caps = %d/%d, want 0/0 (unset)", st.WallclockCapS, st.IterationCapS)
	}
}

// A negative cap is a caller defect: the replay rule of SPEC-046 M7 refuses
// the append inside the transaction, so the run stays claimed and writes
// nothing.
func TestStartWithCapsRefusesANegativeCapAndWritesNothing(t *testing.T) {
	ctx := context.Background()
	m, eng, _ := newTestMachine(t, "CDT-677-neg", "sonnet")
	token, err := m.Claim(ctx, "runner-a", "CDT-677-neg", "orchestrate", "sonnet")
	if err != nil {
		t.Fatalf("Claim: %v", err)
	}
	for _, caps := range [2][2]int64{{-1, 0}, {0, -1}} {
		if err := m.StartWithCaps(ctx, "runner-a", token, "sonnet",
			caps[0], caps[1]); !errors.Is(err, journal.ErrReplayInconsistent) {
			t.Fatalf("StartWithCaps(%d,%d) err = %v, want ErrReplayInconsistent",
				caps[0], caps[1], err)
		}
	}
	st, err := m.State(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if st.Status != journal.StatusClaimed {
		t.Errorf("state = %s, want claimed (the refused start wrote nothing)", st.Name())
	}
	if n := countKind(t, eng, "CDT-677-neg", journal.KindRunStarted); n != 0 {
		t.Errorf("run_started rows = %d, want none", n)
	}
}

// countKind counts one run's rows of one event kind.
func countKind(t *testing.T, eng *journal.Engine, runID string, kind journal.Kind) int {
	t.Helper()
	events, err := eng.Events(context.Background(), runID)
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, ev := range events {
		if ev.Kind == kind {
			n++
		}
	}
	return n
}
