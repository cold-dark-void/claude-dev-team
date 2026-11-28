package journal

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

// seed builds a full lifecycle through the engine and returns the rows back, so
// every replay test runs on real journal rows.
func seed(t *testing.T, runID string) []Event {
	t.Helper()
	e, err := OpenPath(context.Background(), filepath.Join(t.TempDir(), "run.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = e.Close() })

	add := func(kind Kind, payload any) {
		t.Helper()
		if _, _, err := e.AppendChecked(context.Background(), mustEvent(t, runID, kind, payload)); err != nil {
			t.Fatalf("append %s: %v", kind, err)
		}
	}
	addKey := func(kind Kind, payload any, key string) {
		t.Helper()
		ev := mustEvent(t, runID, kind, payload)
		ev.IdempotencyKey = key
		if _, _, err := e.AppendChecked(context.Background(), ev); err != nil {
			t.Fatalf("append %s: %v", kind, err)
		}
	}

	add(KindRunClaimed, ClaimPayload{Owner: "w1", Token: 1, Ticket: runID,
		Workflow: "orchestrate", Model: "opus"})
	add(KindRunStarted, StartPayload{StallLimitS: 270, Model: "opus",
		WallclockCapS: 3600, IterationCapS: 7200})
	add(KindStintStarted, StintPayload{Stint: 1, Label: "wave 1"})
	add(KindHeartbeat, HeartbeatPayload{Owner: "w1", Token: 1})

	// A side effect that closed, and one that did not (the crash window).
	intent := mustEvent(t, runID, KindSideEffect, Effect{Effect: "push",
		Intent: json.RawMessage(`{"sha":"abc123"}`)})
	intent.IdempotencyKey = runID + ":push:abc123"
	if _, _, err := e.AppendChecked(context.Background(), intent); err != nil {
		t.Fatalf("append intent: %v", err)
	}
	pushSeq := intent.Seq
	outcome := mustEvent(t, runID, KindSideEffect, Effect{Effect: "push",
		Outcome:   json.RawMessage(`{"pushed":true}`),
		IntentSeq: pushSeq})
	// AppendChecked fills nothing in: read the seq back from the journal.
	rows, err := e.Events(context.Background(), runID)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range rows {
		if r.IdempotencyKey == intent.IdempotencyKey {
			outcome.Payload = mustJSON(t, Effect{Effect: "push",
				Outcome: json.RawMessage(`{"pushed":true}`), IntentSeq: r.Seq})
		}
	}
	if _, _, err := e.AppendChecked(context.Background(), outcome); err != nil {
		t.Fatalf("append outcome: %v", err)
	}
	addKey(KindSideEffect, Effect{Effect: "pr",
		Intent: json.RawMessage(`{"title":"ship"}`)}, runID+":pr:ship")

	add(KindStintStarted, StintPayload{Stint: 2, Label: "wave 2"})
	add(KindRepair, RepairPayload{Target: "branch feat/x",
		Observation: "branch ahead of the journal", Action: "reset worktree to HEAD"})

	// Two halts of the same reason, each resumed inside the budget.
	add(KindRunHalted, HaltPayload{Reason: "stalled", RetryBudget: 2, RetryRemaining: 2})
	add(KindRunResumed, ResumePayload{Reason: "stalled"})
	add(KindRunHalted, HaltPayload{Reason: "stalled", RetryBudget: 2, RetryRemaining: 1})
	add(KindRunResumed, ResumePayload{Reason: "stalled"})

	// A takeover, then completion with a card reference.
	add(KindLeaseAcquire, LeasePayload{Owner: "w2", Token: 2, Reason: "takeover"})
	done := mustEvent(t, runID, KindRunCompleted, CompletePayload{
		Result: json.RawMessage(`{"sha":"abc123"}`)})
	done.Card = &CardRef{Path: ".claude/autopilot/" + runID + ".jsonl",
		TS: "2026-11-16T00:00:00Z", RunID: runID}
	if _, _, err := e.AppendChecked(context.Background(), done); err != nil {
		t.Fatalf("append completed: %v", err)
	}

	events, err := e.Events(context.Background(), runID)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) == 0 {
		t.Fatal("seed wrote no rows")
	}
	return events
}

func mustEvent(t *testing.T, runID string, kind Kind, payload any) Event {
	t.Helper()
	ev, err := NewEvent(runID, kind, payload)
	if err != nil {
		t.Fatalf("NewEvent(%s): %v", kind, err)
	}
	return ev
}

func mustJSON(t *testing.T, v any) json.RawMessage {
	t.Helper()
	raw, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

// AC1: state is pure replay, and a mid-replay snapshot replays forward to the
// same state as the full log.
func TestReplayDeterminism(t *testing.T) {
	events := seed(t, "CDT-643")

	first, err := Replay(events)
	if err != nil {
		t.Fatalf("Replay: %v", err)
	}
	second, err := Replay(events)
	if err != nil {
		t.Fatalf("Replay (second): %v", err)
	}
	if !reflect.DeepEqual(first, second) {
		t.Fatalf("two replays of one journal differ:\n%+v\n%+v", first, second)
	}
	if a, b := mustJSON(t, first), mustJSON(t, second); string(a) != string(b) {
		t.Fatalf("state JSON differs:\n%s\n%s", a, b)
	}

	// Mutating the input order must not produce a state at all: replay is
	// seq-ordered, and a log out of order is a corrupt journal.
	reversed := append([]Event(nil), events...)
	for i, j := 0, len(reversed)-1; i < j; i, j = i+1, j-1 {
		reversed[i], reversed[j] = reversed[j], reversed[i]
	}
	if _, err := Replay(reversed); err == nil {
		t.Fatal("Replay accepted a reversed log")
	}

	// Snapshot property: replay(prefix), then replay the rest forward, equals
	// the full replay — at every split point.
	for k := 0; k <= len(events); k++ {
		base, err := Replay(events[:k])
		if err != nil {
			t.Fatalf("Replay(prefix %d): %v", k, err)
		}
		// base must not be modified by the continuation.
		before := string(mustJSON(t, base))
		got, err := ReplayFrom(base, events[k:])
		if err != nil {
			t.Fatalf("ReplayFrom(from %d): %v", k, err)
		}
		if after := string(mustJSON(t, base)); after != before {
			t.Fatalf("ReplayFrom mutated the snapshot at split %d:\nbefore %s\nafter  %s", k, before, after)
		}
		if !reflect.DeepEqual(got, first) {
			t.Fatalf("ReplayFrom from split %d != full replay:\n%+v", k, got)
		}
	}
}

// AC1, AC3, AC5, AC6 in one state: the projection is complete and total over
// every kind the schema allows.
func TestReplayProjectsEveryKind(t *testing.T) {
	events := seed(t, "CDT-643")
	st, err := Replay(events)
	if err != nil {
		t.Fatal(err)
	}

	if st.RunID != "CDT-643" || st.Name() != "completed" || !st.IsTerminal() {
		t.Fatalf("state = %+v name %s", st, st.Name())
	}
	if st.Owner != "w2" || st.Token != 2 {
		t.Fatalf("owner/token = %q/%d, want w2/2", st.Owner, st.Token)
	}
	if st.Ticket != "CDT-643" || st.Workflow != "orchestrate" || st.Model != "opus" {
		t.Fatalf("identity = %+v", st)
	}
	if st.Stint != 2 {
		t.Errorf("stint = %d, want 2", st.Stint)
	}
	if st.StallLimitS != 270 {
		t.Errorf("stall limit = %d, want 270", st.StallLimitS)
	}
	if st.WallclockCapS != 3600 || st.IterationCapS != 7200 {
		t.Errorf("caps = %d/%d, want 3600/7200", st.WallclockCapS, st.IterationCapS)
	}
	if len(st.Halts) != 2 || st.Halt != nil {
		t.Errorf("halts = %+v, halt = %+v", st.Halts, st.Halt)
	}
	if len(st.Repairs) != 1 {
		t.Errorf("repairs = %+v, want 1", st.Repairs)
	}
	if st.LeaseTakeovers != 1 {
		t.Errorf("takeovers = %d, want 1", st.LeaseTakeovers)
	}
	if st.EventCount != int64(len(seed(t, "CDT-643"))) {
		t.Errorf("event count = %d, want %d", st.EventCount, len(seed(t, "CDT-643")))
	}
	if st.Result == nil || string(st.Result) != `{"sha":"abc123"}` {
		t.Errorf("result = %s", st.Result)
	}

	// The resolved effect and the pending effect (AC3 + AC5).
	if len(st.Effects) != 2 {
		t.Fatalf("effects = %+v, want 2", st.Effects)
	}
	if st.Effects[0].Pending() {
		t.Errorf("the push effect must be resolved: %+v", st.Effects[0])
	}
	if st.Effects[0].OutcomeSeq == 0 || st.Effects[0].OutcomeTS == "" {
		t.Errorf("push outcome not recorded: %+v", st.Effects[0])
	}
	pending := st.PendingEffects()
	if len(pending) != 1 || pending[0].Effect != "pr" {
		t.Fatalf("pending effects = %+v, want the open pr intent", pending)
	}
	if _, ok := st.EffectByKey("CDT-643:pr:ship"); !ok {
		t.Error("EffectByKey missed the pr intent")
	}

	// The card reference rode through the round trip.
	if st.Effects[1].Card != nil {
		t.Error("a card reference appeared on an event that carried none")
	}
}

func TestReplayRefusesIllegalJournals(t *testing.T) {
	base := seed(t, "CDT-643")

	cases := []struct {
		name  string
		event Event
		want  error
	}{
		{"event after terminal", Event{
			TS: "2026-11-16T00:00:00Z", RunID: "CDT-643", Kind: KindHeartbeat,
			Payload: mustJSON(t, HeartbeatPayload{Owner: "w2", Token: 2}),
		}, ErrTerminalState},
		{"second completion", Event{
			TS: "2026-11-16T00:00:00Z", RunID: "CDT-643", Kind: KindRunCompleted,
			Payload: mustJSON(t, CompletePayload{}),
		}, ErrTerminalState},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			events := append(append([]Event(nil), base...), tc.event)
			_, err := Replay(events)
			if !errors.Is(err, tc.want) {
				t.Fatalf("Replay err = %v, want %v", err, tc.want)
			}
		})
	}
}

// SPEC-044 CDT-671 AC2: the last session output time is its own row, never a
// heartbeat row. Replay carries it on the state and leaves the liveness
// reading alone, so the watchdog cannot ride on it.
func TestReplayCarriesTheProgressTime(t *testing.T) {
	claim := mustSeq(t, mustEvent(t, "A", KindRunClaimed,
		ClaimPayload{Owner: "w", Token: 1}), 1)
	start := mustSeq(t, mustEvent(t, "A", KindRunStarted, StartPayload{StallLimitS: 60}), 2)
	beat := Event{Seq: 3, TS: "2026-11-16T00:01:00Z", RunID: "A", Kind: KindHeartbeat,
		Payload: mustJSON(t, HeartbeatPayload{Owner: "w", Token: 1})}
	prog := Event{Seq: 4, TS: "2026-11-16T00:02:00Z", RunID: "A", Kind: KindRunProgress,
		Payload: mustJSON(t, ProgressPayload{LastOutputTS: "2026-11-16T00:01:30Z"})}

	st, err := Replay([]Event{claim, start, beat, prog})
	if err != nil {
		t.Fatalf("Replay: %v", err)
	}
	if st.ProgressTS != "2026-11-16T00:01:30Z" {
		t.Errorf("progress time = %q, want the captured output time", st.ProgressTS)
	}
	if st.HeartbeatTS != "2026-11-16T00:01:00Z" {
		t.Errorf("heartbeat time = %q, want the beat's own row: a progress row is "+
			"never liveness", st.HeartbeatTS)
	}
	now := time.Date(2026, 11, 16, 0, 3, 0, 0, time.UTC)
	if got := st.SinceProgress(now); got != 90*time.Second {
		t.Errorf("SinceProgress = %s, want 90s", got)
	}
	if got := st.SinceHeartbeat(now); got != 120*time.Second {
		t.Errorf("SinceHeartbeat = %s, want 120s — unchanged by the progress row", got)
	}

	// The row is progress from running only: a claimed run has no session.
	early := Event{Seq: 2, TS: "2026-11-16T00:01:00Z", RunID: "A", Kind: KindRunProgress,
		Payload: mustJSON(t, ProgressPayload{LastOutputTS: "2026-11-16T00:01:00Z"})}
	if _, err := Replay([]Event{claim, early}); !errors.Is(err, ErrTransition) {
		t.Errorf("run_progress from claimed: err = %v, want %v", err, ErrTransition)
	}
	// A timestamp outside the canonical shape is refused, never guessed at.
	bad := Event{Seq: 3, TS: "2026-11-16T00:02:00Z", RunID: "A", Kind: KindRunProgress,
		Payload: mustJSON(t, ProgressPayload{LastOutputTS: "2026-11-16 00:01:30"})}
	if _, err := Replay([]Event{claim, start, bad}); !errors.Is(err, ErrReplayInconsistent) {
		t.Errorf("run_progress with a loose ts: err = %v, want %v",
			err, ErrReplayInconsistent)
	}
	// A journal written before CDT-671 carries no progress row and replays with
	// no progress time — the reading names the absence, never a guess.
	old, err := Replay([]Event{claim, start, beat})
	if err != nil {
		t.Fatalf("Replay of a pre-CDT-671 log: %v", err)
	}
	if old.ProgressTS != "" {
		t.Errorf("progress time = %q, want empty for a run that carries none",
			old.ProgressTS)
	}
	if d := old.SinceProgress(now); d != 0 {
		t.Errorf("SinceProgress of a run with no progress time = %s, want 0", d)
	}
}

// SPEC-044 CDT-671 AC3: the no-progress bound rides the run_started payload and
// replays onto the state, so the flag is judged from the journal. A row written
// before the knob exists carries no bound, and the reading says so.
func TestReplayCarriesTheNoProgressBound(t *testing.T) {
	claim := mustSeq(t, mustEvent(t, "A", KindRunClaimed,
		ClaimPayload{Owner: "w", Token: 1}), 1)
	start := mustSeq(t, mustEvent(t, "A", KindRunStarted,
		StartPayload{StallLimitS: 60, ProgressLimitS: 90}), 2)
	st, err := Replay([]Event{claim, start})
	if err != nil {
		t.Fatalf("Replay: %v", err)
	}
	if st.ProgressLimitS != 90 {
		t.Errorf("no-progress bound = %d, want 90", st.ProgressLimitS)
	}
	if st.StallLimitS != 60 {
		t.Errorf("stall limit = %d, want 60 — the two limits stay separate", st.StallLimitS)
	}

	// The knob is optional and 0 is the unset encoding, so only a negative one
	// is inconsistent, and the knob-free payload keeps its pre-CDT-671 bytes.
	if got := string(mustJSON(t, StartPayload{StallLimitS: 60, Model: "opus"})); got !=
		`{"stall_limit_s":60,"model":"opus"}` {
		t.Fatalf("bound-free payload = %s, want the pre-CDT-671 bytes", got)
	}
	old := Event{Seq: 2, TS: "2026-11-16T00:00:00Z", RunID: "A", Kind: KindRunStarted,
		Payload: json.RawMessage(`{"stall_limit_s":60,"model":"opus"}`)}
	unset, err := Replay([]Event{claim, old})
	if err != nil {
		t.Fatalf("Replay of a bound-free start: %v", err)
	}
	if unset.ProgressLimitS != 0 {
		t.Errorf("no-progress bound = %d, want unset", unset.ProgressLimitS)
	}
	neg := mustSeq(t, mustEvent(t, "A", KindRunStarted,
		StartPayload{StallLimitS: 60, ProgressLimitS: -1}), 2)
	if _, err := Replay([]Event{claim, neg}); !errors.Is(err, ErrReplayInconsistent) {
		t.Errorf("negative bound: err = %v, want %v", err, ErrReplayInconsistent)
	}
}

func TestReplayStateChecks(t *testing.T) {
	t.Run("unknown kind is refused by validation", func(t *testing.T) {
		ev := Event{TS: "2026-11-16T00:00:00Z", RunID: "r", Kind: "made_up",
			Payload: json.RawMessage(`{}`), Seq: 1}
		if _, err := Replay([]Event{ev}); !errors.Is(err, ErrInvalid) {
			t.Fatalf("err = %v, want ErrInvalid", err)
		}
	})

	t.Run("two runs in one log is refused", func(t *testing.T) {
		a := mustEvent(t, "A", KindRunClaimed, ClaimPayload{Owner: "w", Token: 1})
		b := mustEvent(t, "B", KindRunStarted, StartPayload{StallLimitS: 60})
		a.Seq, b.Seq = 1, 2
		if _, err := Replay([]Event{a, b}); !errors.Is(err, ErrReplayInconsistent) {
			t.Fatalf("err = %v, want ErrReplayInconsistent", err)
		}
	})

	t.Run("out-of-order seq is refused", func(t *testing.T) {
		a := mustEvent(t, "A", KindRunClaimed, ClaimPayload{Owner: "w", Token: 1})
		b := mustEvent(t, "A", KindRunStarted, StartPayload{StallLimitS: 60})
		a.Seq, b.Seq = 2, 1
		if _, err := Replay([]Event{a, b}); !errors.Is(err, ErrReplayInconsistent) {
			t.Fatalf("err = %v, want ErrReplayInconsistent", err)
		}
	})

	t.Run("start from running is refused", func(t *testing.T) {
		evs := []Event{
			mustSeq(t, mustEvent(t, "A", KindRunClaimed, ClaimPayload{Owner: "w", Token: 1}), 1),
			mustSeq(t, mustEvent(t, "A", KindRunStarted, StartPayload{StallLimitS: 60}), 2),
			mustSeq(t, mustEvent(t, "A", KindRunStarted, StartPayload{StallLimitS: 60}), 3),
		}
		if _, err := Replay(evs); !errors.Is(err, ErrTransition) {
			t.Fatalf("err = %v, want ErrTransition", err)
		}
	})

	t.Run("stint numbers must be sequential", func(t *testing.T) {
		evs := []Event{
			mustSeq(t, mustEvent(t, "A", KindRunClaimed, ClaimPayload{Owner: "w", Token: 1}), 1),
			mustSeq(t, mustEvent(t, "A", KindRunStarted, StartPayload{StallLimitS: 60}), 2),
			mustSeq(t, mustEvent(t, "A", KindStintStarted, StintPayload{Stint: 3}), 3),
		}
		if _, err := Replay(evs); !errors.Is(err, ErrReplayInconsistent) {
			t.Fatalf("err = %v, want ErrReplayInconsistent", err)
		}
	})

	t.Run("heartbeat with a stale token is refused", func(t *testing.T) {
		evs := []Event{
			mustSeq(t, mustEvent(t, "A", KindRunClaimed, ClaimPayload{Owner: "w", Token: 2}), 1),
			mustSeq(t, mustEvent(t, "A", KindRunStarted, StartPayload{StallLimitS: 60}), 2),
			mustSeq(t, mustEvent(t, "A", KindHeartbeat, HeartbeatPayload{Owner: "w", Token: 1}), 3),
		}
		if _, err := Replay(evs); !errors.Is(err, ErrStaleToken) {
			t.Fatalf("err = %v, want ErrStaleToken", err)
		}
	})

	t.Run("unknown halt reason is refused", func(t *testing.T) {
		evs := []Event{
			mustSeq(t, mustEvent(t, "A", KindRunClaimed, ClaimPayload{Owner: "w", Token: 1}), 1),
			mustSeq(t, mustEvent(t, "A", KindRunStarted, StartPayload{StallLimitS: 60}), 2),
			mustSeq(t, mustEvent(t, "A", KindRunHalted,
				HaltPayload{Reason: "exploded", RetryBudget: 1, RetryRemaining: 1}), 3),
		}
		if _, err := Replay(evs); !errors.Is(err, ErrReplayInconsistent) {
			t.Fatalf("err = %v, want ErrReplayInconsistent", err)
		}
	})

	t.Run("halt arithmetic is checked", func(t *testing.T) {
		evs := []Event{
			mustSeq(t, mustEvent(t, "A", KindRunClaimed, ClaimPayload{Owner: "w", Token: 1}), 1),
			mustSeq(t, mustEvent(t, "A", KindRunStarted, StartPayload{StallLimitS: 60}), 2),
			mustSeq(t, mustEvent(t, "A", KindRunHalted,
				HaltPayload{Reason: "stalled", RetryBudget: 2, RetryRemaining: 1}), 3),
		}
		if _, err := Replay(evs); !errors.Is(err, ErrReplayInconsistent) {
			t.Fatalf("err = %v, want ErrReplayInconsistent", err)
		}
	})

	t.Run("an outcome for an unknown intent is refused", func(t *testing.T) {
		evs := []Event{
			mustSeq(t, mustEvent(t, "A", KindRunClaimed, ClaimPayload{Owner: "w", Token: 1}), 1),
			mustSeq(t, mustEvent(t, "A", KindRunStarted, StartPayload{StallLimitS: 60}), 2),
			mustSeq(t, mustEvent(t, "A", KindSideEffect, Effect{Effect: "push",
				Outcome: json.RawMessage(`{}`), IntentSeq: 99}), 3),
		}
		if _, err := Replay(evs); !errors.Is(err, ErrReplayInconsistent) {
			t.Fatalf("err = %v, want ErrReplayInconsistent", err)
		}
	})

	t.Run("an intent row needs a key", func(t *testing.T) {
		evs := []Event{
			mustSeq(t, mustEvent(t, "A", KindRunClaimed, ClaimPayload{Owner: "w", Token: 1}), 1),
			mustSeq(t, mustEvent(t, "A", KindRunStarted, StartPayload{StallLimitS: 60}), 2),
			mustSeq(t, mustEvent(t, "A", KindSideEffect, Effect{Effect: "push"}), 3),
		}
		if _, err := Replay(evs); !errors.Is(err, ErrInvalid) {
			t.Fatalf("err = %v, want ErrInvalid", err)
		}
	})
}

func mustSeq(t *testing.T, ev Event, seq int64) Event {
	t.Helper()
	ev.Seq = seq
	return ev
}

// AC6: the retry budget stops a resume once it is spent.
func TestReplayRetryBudget(t *testing.T) {
	evs := []Event{
		mustSeq(t, mustEvent(t, "A", KindRunClaimed, ClaimPayload{Owner: "w", Token: 1}), 1),
		mustSeq(t, mustEvent(t, "A", KindRunStarted, StartPayload{StallLimitS: 60}), 2),
	}
	seq := int64(3)
	halt := func(remaining int) Event {
		ev := mustEvent(t, "A", KindRunHalted,
			HaltPayload{Reason: "stalled", RetryBudget: 1, RetryRemaining: remaining})
		ev.Seq = seq
		seq++
		return ev
	}
	resume := func() Event {
		ev := mustEvent(t, "A", KindRunResumed, ResumePayload{Reason: "stalled"})
		ev.Seq = seq
		seq++
		return ev
	}

	evs = append(evs, halt(1))
	st, err := Replay(evs)
	if err != nil {
		t.Fatal(err)
	}
	if st.Name() != "halted:stalled" {
		t.Fatalf("state = %s, want halted:stalled", st.Name())
	}
	if st.Halt.Remaining != 1 || st.Halt.Budget != 1 {
		t.Fatalf("halt = %+v, want budget 1 remaining 1", st.Halt)
	}

	evs = append(evs, resume())
	if _, err := Replay(evs); err != nil {
		t.Fatal(err)
	}

	// Second halt: budget spent (remaining 0) → the resume is refused.
	evs = append(evs, halt(0))
	st, err = Replay(evs)
	if err != nil {
		t.Fatal(err)
	}
	if st.Name() != "halted:stalled" || st.Halt.Remaining != 0 {
		t.Fatalf("state = %s halt %+v", st.Name(), st.Halt)
	}
	if _, err := Replay(append(evs, resume())); !errors.Is(err, ErrBudgetExhausted) {
		t.Fatalf("resume after budget err = %v, want ErrBudgetExhausted", err)
	}

	// With the budget spent there is no resume left, so a third halt of the same
	// reason cannot be reached: it is refused as an invalid transition.
	if _, err := Replay(append(evs, halt(0))); !errors.Is(err, ErrTransition) {
		t.Fatalf("halt with no resume behind it err = %v, want ErrTransition", err)
	}
}

// The budget of a repeated halt reason decrements, and the journal refuses a
// writer that reports the old number.
func TestReplayHaltBudgetDecrements(t *testing.T) {
	evs := []Event{
		mustSeq(t, mustEvent(t, "A", KindRunClaimed, ClaimPayload{Owner: "w", Token: 1}), 1),
		mustSeq(t, mustEvent(t, "A", KindRunStarted, StartPayload{StallLimitS: 60}), 2),
		mustSeq(t, mustEvent(t, "A", KindRunHalted,
			HaltPayload{Reason: "stalled", RetryBudget: 2, RetryRemaining: 2}), 3),
		mustSeq(t, mustEvent(t, "A", KindRunResumed, ResumePayload{Reason: "stalled"}), 4),
	}
	stale := mustSeq(t, mustEvent(t, "A", KindRunHalted,
		HaltPayload{Reason: "stalled", RetryBudget: 2, RetryRemaining: 2}), 5)
	if _, err := Replay(append(append([]Event(nil), evs...), stale)); !errors.Is(err, ErrReplayInconsistent) {
		t.Fatalf("second halt reporting the old budget err = %v, want ErrReplayInconsistent", err)
	}

	correct := mustSeq(t, mustEvent(t, "A", KindRunHalted,
		HaltPayload{Reason: "stalled", RetryBudget: 2, RetryRemaining: 1}), 5)
	st, err := Replay(append(append([]Event(nil), evs...), correct))
	if err != nil {
		t.Fatalf("second halt with the decremented budget: %v", err)
	}
	if st.Halt.Remaining != 1 || len(st.Halts) != 2 {
		t.Fatalf("halt = %+v halts %+v, want remaining 1 after two halts", st.Halt, st.Halts)
	}
}

// AC1: AppendChecked is the append-time form of the same rules, and it writes
// nothing when it refuses.
func TestAppendCheckedWritesNothingOnIllegalTransition(t *testing.T) {
	e, err := OpenPath(context.Background(), filepath.Join(t.TempDir(), "run.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = e.Close() })
	ctx := context.Background()

	if _, _, err := e.AppendChecked(ctx,
		mustEvent(t, "A", KindRunStarted, StartPayload{StallLimitS: 60})); err == nil {
		t.Fatal("run_started with no claim was accepted")
	}
	rows, err := e.Events(ctx, "A")
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 0 {
		t.Fatalf("refused append wrote %d rows", len(rows))
	}

	if _, _, err := e.AppendChecked(ctx,
		mustEvent(t, "A", KindRunClaimed, ClaimPayload{Owner: "w", Token: 1})); err != nil {
		t.Fatal(err)
	}
	if _, _, err := e.AppendChecked(ctx,
		mustEvent(t, "A", KindRunClaimed, ClaimPayload{Owner: "w", Token: 1})); !errors.Is(err, ErrStaleToken) {
		t.Fatalf("re-claim with the same token err = %v, want ErrStaleToken", err)
	}
	rows, _ = e.Events(ctx, "A")
	if len(rows) != 1 {
		t.Fatalf("journal = %d rows, want 1", len(rows))
	}
}

// SPEC-046 M7: the run_started payload carries the operator's budget caps and
// State carries them, so the API, retry, and takeover read them from the journal.
func TestReplayCarriesTheJournaledCaps(t *testing.T) {
	evs := []Event{
		mustSeq(t, mustEvent(t, "A", KindRunClaimed, ClaimPayload{Owner: "w", Token: 1}), 1),
		mustSeq(t, mustEvent(t, "A", KindRunStarted,
			StartPayload{StallLimitS: 60, WallclockCapS: 3600, IterationCapS: 7200}), 2),
	}
	st, err := Replay(evs)
	if err != nil {
		t.Fatalf("Replay: %v", err)
	}
	if st.WallclockCapS != 3600 || st.IterationCapS != 7200 {
		t.Fatalf("caps = %d/%d, want 3600/7200", st.WallclockCapS, st.IterationCapS)
	}
	if st.StallLimitS != 60 {
		t.Errorf("stall limit = %d, want 60", st.StallLimitS)
	}
}

// The caps are optional. A payload that carries neither key replays green and
// leaves both unset, and the payload for a caps-free start keeps its old bytes.
func TestReplayOfAnOldStartRowLeavesTheCapsUnset(t *testing.T) {
	if got := string(mustJSON(t, StartPayload{StallLimitS: 60, Model: "opus"})); got !=
		`{"stall_limit_s":60,"model":"opus"}` {
		t.Fatalf("caps-free payload = %s, want the pre-SPEC-046 bytes", got)
	}

	claim := mustSeq(t, mustEvent(t, "A", KindRunClaimed,
		ClaimPayload{Owner: "w", Token: 1, Ticket: "A", Workflow: "orchestrate"}), 1)
	// The stored row shape every journal written before SPEC-046 has.
	start := Event{Seq: 2, TS: "2026-11-16T00:00:00Z", RunID: "A", Kind: KindRunStarted,
		Payload: json.RawMessage(`{"stall_limit_s":60,"model":"opus"}`)}
	st, err := Replay([]Event{claim, start})
	if err != nil {
		t.Fatalf("Replay of an old row: %v", err)
	}
	if st.WallclockCapS != 0 || st.IterationCapS != 0 {
		t.Fatalf("caps = %d/%d, want 0/0 (unset)", st.WallclockCapS, st.IterationCapS)
	}
	// State stays JSON-stable: unset caps add no keys, so an old state reader
	// sees the same JSON as before.
	raw := string(mustJSON(t, st))
	for _, needle := range []string{`"wallclock_cap_s"`, `"iteration_cap_s"`} {
		if strings.Contains(raw, needle) {
			t.Errorf("state JSON carries %s for unset caps:\n%s", needle, raw)
		}
	}
}

// An explicit zero is the unset encoding (State: 0 = unset). The route refuses a
// zero cap before any row is written (SPEC-046 M3); replay reads it as unset.
func TestReplayTreatsAZeroCapAsUnset(t *testing.T) {
	claim := mustSeq(t, mustEvent(t, "A", KindRunClaimed, ClaimPayload{Owner: "w", Token: 1}), 1)
	start := Event{Seq: 2, TS: "2026-11-16T00:00:00Z", RunID: "A", Kind: KindRunStarted,
		Payload: json.RawMessage(`{"stall_limit_s":60,"wallclock_cap_s":0,"iteration_cap_s":0}`)}
	st, err := Replay([]Event{claim, start})
	if err != nil {
		t.Fatalf("Replay: %v", err)
	}
	if st.WallclockCapS != 0 || st.IterationCapS != 0 {
		t.Fatalf("caps = %d/%d, want 0/0", st.WallclockCapS, st.IterationCapS)
	}
}

// SPEC-046 M7: replay refuses a cap that is present and negative. A present
// zero is the unset encoding, not a refusal (SPEC-046 M7).
func TestReplayRefusesANegativeCap(t *testing.T) {
	cases := []struct {
		name    string
		payload string
	}{
		{"negative wallclock cap", `{"stall_limit_s":60,"wallclock_cap_s":-1}`},
		{"negative iteration cap", `{"stall_limit_s":60,"iteration_cap_s":-1}`},
		{"both caps negative", `{"stall_limit_s":60,"wallclock_cap_s":-3600,"iteration_cap_s":-2}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			claim := mustSeq(t, mustEvent(t, "A", KindRunClaimed,
				ClaimPayload{Owner: "w", Token: 1}), 1)
			start := Event{Seq: 2, TS: "2026-11-16T00:00:00Z", RunID: "A",
				Kind: KindRunStarted, Payload: json.RawMessage(tc.payload)}
			_, err := Replay([]Event{claim, start})
			if !errors.Is(err, ErrReplayInconsistent) {
				t.Fatalf("Replay err = %v, want ErrReplayInconsistent", err)
			}
		})
	}
}

// AppendChecked takes the extended payload through the real write path.
func TestAppendCheckedAcceptsTheJournaledCaps(t *testing.T) {
	e, err := OpenPath(context.Background(), filepath.Join(t.TempDir(), "run.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = e.Close() })
	ctx := context.Background()

	for _, ev := range []Event{
		mustEvent(t, "A", KindRunClaimed, ClaimPayload{Owner: "w", Token: 1,
			Ticket: "A", Workflow: "orchestrate"}),
		mustEvent(t, "A", KindRunStarted,
			StartPayload{StallLimitS: 60, WallclockCapS: 5400, IterationCapS: 12}),
	} {
		if _, _, err := e.AppendChecked(ctx, ev); err != nil {
			t.Fatalf("append %s: %v", ev.Kind, err)
		}
	}
	rows, err := e.Events(ctx, "A")
	if err != nil {
		t.Fatal(err)
	}
	st, err := Replay(rows)
	if err != nil {
		t.Fatalf("Replay: %v", err)
	}
	if st.WallclockCapS != 5400 || st.IterationCapS != 12 {
		t.Fatalf("caps = %d/%d, want 5400/12", st.WallclockCapS, st.IterationCapS)
	}
}

// The caps survive a takeover and a re-claim, which is how retry and takeover
// recover them (SPEC-046 M7/M10). The re-claim consistency check is unchanged:
// a re-claim that moves the ticket or the workflow is still refused.
func TestReplayCapsSurviveATakeoverReclaim(t *testing.T) {
	evs := []Event{
		mustSeq(t, mustEvent(t, "A", KindRunClaimed,
			ClaimPayload{Owner: "w1", Token: 1, Ticket: "A", Workflow: "orchestrate"}), 1),
		mustSeq(t, mustEvent(t, "A", KindRunStarted,
			StartPayload{StallLimitS: 60, WallclockCapS: 3600, IterationCapS: 4}), 2),
		mustSeq(t, mustEvent(t, "A", KindLeaseAcquire,
			LeasePayload{Owner: "w2", Token: 2, Reason: "takeover"}), 3),
	}
	st, err := Replay(evs)
	if err != nil {
		t.Fatalf("takeover: %v", err)
	}
	if st.WallclockCapS != 3600 || st.IterationCapS != 4 {
		t.Fatalf("caps after takeover = %d/%d, want 3600/4", st.WallclockCapS, st.IterationCapS)
	}

	reclaim := mustSeq(t, mustEvent(t, "A", KindRunClaimed,
		ClaimPayload{Owner: "w2", Token: 3, Ticket: "A", Workflow: "orchestrate"}), 4)
	st, err = Replay(append(append([]Event(nil), evs...), reclaim))
	if err != nil {
		t.Fatalf("re-claim: %v", err)
	}
	if st.WallclockCapS != 3600 || st.IterationCapS != 4 {
		t.Fatalf("caps after re-claim = %d/%d, want 3600/4", st.WallclockCapS, st.IterationCapS)
	}

	sameToken := mustSeq(t, mustEvent(t, "A", KindRunClaimed,
		ClaimPayload{Owner: "w2", Token: 2, Ticket: "A", Workflow: "orchestrate"}), 4)
	if _, err := Replay(append(append([]Event(nil), evs...), sameToken)); !errors.Is(err, ErrStaleToken) {
		t.Fatalf("re-claim with a stale token err = %v, want ErrStaleToken", err)
	}
	moved := mustSeq(t, mustEvent(t, "A", KindRunClaimed,
		ClaimPayload{Owner: "w2", Token: 3, Ticket: "A", Workflow: "epic"}), 4)
	if _, err := Replay(append(append([]Event(nil), evs...), moved)); !errors.Is(err, ErrReplayInconsistent) {
		t.Fatalf("re-claim that moves the workflow err = %v, want ErrReplayInconsistent", err)
	}
}
