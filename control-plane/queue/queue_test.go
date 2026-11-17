package queue

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
	"github.com/cold-dark-void/claude-dev-team/control-plane/run"
)

// newTestQueue returns a queue over a fresh journal in a temp directory,
// with the Model-map layers pointed at a fixture root and no env layer, so
// every cap a test asserts is one the test wrote down.
func newTestQueue(t *testing.T) (*Queue, *journal.Engine, string) {
	t.Helper()
	root := t.TempDir()
	path := filepath.Join(t.TempDir(), "run.db")
	eng, err := journal.OpenPath(context.Background(), path)
	if err != nil {
		t.Fatalf("OpenPath: %v", err)
	}
	t.Cleanup(func() { _ = eng.Close() })
	q := New(eng)
	q.mroot = func() (string, error) { return root, nil }
	q.home = func() string { return "" } // no global layer unless a test sets one
	q.getenv = func(string) string { return "" }
	return q, eng, root
}

// writeMap plants one Model-map layer.
func writeMap(t *testing.T, root, rel, body string) {
	t.Helper()
	path := filepath.Join(root, rel)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

// claim takes the lease of one run and starts it — the queue's verbs land
// on a running run, the state the C2 replay accepts side-effect rows in.
func claim(t *testing.T, eng *journal.Engine, runID string) int64 {
	t.Helper()
	ctx := context.Background()
	m := run.New(eng, runID)
	token, err := m.Claim(ctx, "runner-a", "T-"+runID, "orchestrate", "sonnet")
	if err != nil {
		t.Fatalf("Claim %s: %v", runID, err)
	}
	if err := m.Start(ctx, "runner-a", token, "sonnet"); err != nil {
		t.Fatalf("Start %s: %v", runID, err)
	}
	return token
}

func request(runID, runner, model string) Request {
	return Request{RunID: runID, Runner: runner, Model: model}
}

// stateOf is the status-surface state of one runner.
func stateOf(t *testing.T, q *Queue, runID, runner string) string {
	t.Helper()
	slots, err := q.Slots(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range slots {
		if s.RunID == runID && s.Runner == runner {
			return s.State
		}
	}
	return ""
}

// AC1: one slot is one runner, and the queue counts runners — a grant
// holds one slot, a release gives it back, and the count follows.
func TestSlotCountsRunners(t *testing.T) {
	q, eng, _ := newTestQueue(t)
	ctx := context.Background()
	token := claim(t, eng, "R1")

	// Two runners, two slots.
	for _, r := range []string{"a", "b"} {
		granted, err := q.Grant(ctx, "runner-a", token, request("R1", r, "sonnet"))
		if err != nil {
			t.Fatalf("Grant %s: %v", r, err)
		}
		if !granted {
			t.Fatalf("Grant %s: want granted", r)
		}
		if got := stateOf(t, q, "R1", r); got != SlotHeld {
			t.Fatalf("runner %s state = %q, want held", r, got)
		}
	}

	// The release frees exactly one slot: the runner leaves the count and
	// the other runner keeps its slot.
	if err := q.Release(ctx, "runner-a", token, request("R1", "a", "sonnet")); err != nil {
		t.Fatalf("Release: %v", err)
	}
	if got := stateOf(t, q, "R1", "a"); got != SlotReleased {
		t.Fatalf("runner a state = %q, want released", got)
	}
	if got := stateOf(t, q, "R1", "b"); got != SlotHeld {
		t.Fatalf("runner b state = %q, want held", got)
	}

	// A second release is a replay of the first: nothing moves.
	if err := q.Release(ctx, "runner-a", token, request("R1", "a", "sonnet")); err != nil {
		t.Fatalf("second Release: %v", err)
	}
	if got := stateOf(t, q, "R1", "a"); got != SlotReleased {
		t.Fatalf("runner a state after re-release = %q, want released", got)
	}
}

// AC2: the node concurrency setting and the per-model-endpoint cap are
// separate caps the queue enforces independently — the node cap can admit
// what the model cap refuses, and one model's cap never binds another's.
func TestCapsAreIndependent(t *testing.T) {
	q, eng, root := newTestQueue(t)
	ctx := context.Background()
	writeMap(t, root, ".claude/dev-team/models.local.json",
		`{"version":1,"concurrency":2,"model_slots":{"sonnet":1}}`)
	token := claim(t, eng, "R1")

	// The first sonnet runner is admitted by both caps.
	granted, err := q.Grant(ctx, "runner-a", token, request("R1", "s1", "sonnet"))
	if err != nil || !granted {
		t.Fatalf("Grant s1: granted=%v err=%v, want granted", granted, err)
	}
	// The second sonnet runner fits the node cap of 2 but trips the model
	// cap of 1: the model cap holds, independently.
	granted, err = q.Grant(ctx, "runner-a", token, request("R1", "s2", "sonnet"))
	if err != nil {
		t.Fatalf("Grant s2: %v", err)
	}
	if granted {
		t.Fatal("Grant s2: want refused by the model cap")
	}
	if got := stateOf(t, q, "R1", "s2"); got != SlotWaiting {
		t.Fatalf("runner s2 state = %q, want waiting", got)
	}
	// An opus runner takes the node cap's free place: one model's cap never
	// binds another's.
	granted, err = q.Grant(ctx, "runner-a", token, request("R1", "o1", "opus"))
	if err != nil || !granted {
		t.Fatalf("Grant o1: granted=%v err=%v, want granted", granted, err)
	}
}

// AC2: overflow waits and shows as waiting — the status surface sees the
// waiting state without re-deriving it from raw journal rows.
func TestOverflowWaitsAndShowsAsWaiting(t *testing.T) {
	q, eng, root := newTestQueue(t)
	ctx := context.Background()
	writeMap(t, root, ".claude/dev-team/models.local.json",
		`{"version":1,"concurrency":1}`)
	token := claim(t, eng, "R1")

	granted, err := q.Grant(ctx, "runner-a", token, request("R1", "a", "sonnet"))
	if err != nil || !granted {
		t.Fatalf("Grant a: granted=%v err=%v, want granted", granted, err)
	}
	granted, err = q.Grant(ctx, "runner-a", token, request("R1", "b", "sonnet"))
	if err != nil {
		t.Fatalf("Grant b: %v", err)
	}
	if granted {
		t.Fatal("Grant b: want refused by the node cap")
	}

	// The status surface carries the waiting row, with the runner, the
	// model, and the state.
	slots, err := q.Slots(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var found *Slot
	for i := range slots {
		if slots[i].Runner == "b" {
			found = &slots[i]
		}
	}
	if found == nil {
		t.Fatalf("Slots() = %+v, want a waiting row for runner b", slots)
	}
	if found.State != SlotWaiting || found.RunID != "R1" || found.Model != "sonnet" {
		t.Fatalf("waiting row = %+v, want R1/b/sonnet waiting", *found)
	}
}

// AC6: a kill-and-replay never grants a slot twice — the grant is an
// intent-then-outcome pair keyed on the run id, the runner, and the release
// count, so a replay of the intent alone re-derives the grant it recorded
// and counts one slot, not two.
func TestKillAndReplayNeverGrantsTwice(t *testing.T) {
	q, eng, _ := newTestQueue(t)
	ctx := context.Background()
	token := claim(t, eng, "R1")

	granted, err := q.Grant(ctx, "runner-a", token, request("R1", "a", "sonnet"))
	if err != nil || !granted {
		t.Fatalf("Grant: granted=%v err=%v, want granted", granted, err)
	}

	// The kill-and-replay: the same grant call re-issued against the same
	// journal — the intent is already recorded, so nothing new lands.
	granted2, err := q.Grant(ctx, "runner-a", token, request("R1", "a", "sonnet"))
	if err != nil {
		t.Fatalf("replayed Grant: %v", err)
	}
	if !granted2 {
		t.Fatal("replayed Grant: the runner still holds its slot, want granted")
	}

	// Exactly one grant intent is recorded for the runner: the replay found
	// the row it recorded and appended nothing.
	events, err := eng.Events(ctx, "R1")
	if err != nil {
		t.Fatal(err)
	}
	grants := 0
	for _, ev := range events {
		if ev.Kind != journal.KindSideEffect {
			continue
		}
		var ef journal.Effect
		if err := jsonUnmarshal(ev.Payload, &ef); err != nil {
			t.Fatal(err)
		}
		if ef.Effect == EffectGrant && ef.IntentSeq == 0 {
			grants++
		}
	}
	if grants != 1 {
		t.Fatalf("%d grant intents recorded, want exactly 1", grants)
	}
	// The status surface counts one slot, not two.
	slots, err := q.Slots(ctx)
	if err != nil {
		t.Fatal(err)
	}
	held := 0
	for _, s := range slots {
		if s.State == SlotHeld {
			held++
		}
	}
	if held != 1 {
		t.Fatalf("%d held slots after the replay, want 1", held)
	}
}

// The wait-close rule, granted side: a later grant closes the open wait
// pair with granted true, so the runner that waited shows held and the
// journal carries no pending wait.
func TestWaitResolvedByLaterGrant(t *testing.T) {
	q, eng, root := newTestQueue(t)
	ctx := context.Background()
	writeMap(t, root, ".claude/dev-team/models.local.json",
		`{"version":1,"concurrency":1}`)
	token := claim(t, eng, "R1")

	if granted, err := q.Grant(ctx, "runner-a", token, request("R1", "a", "sonnet")); err != nil || !granted {
		t.Fatalf("Grant a: granted=%v err=%v, want granted", granted, err)
	}
	if granted, err := q.Grant(ctx, "runner-a", token, request("R1", "b", "sonnet")); err != nil || granted {
		t.Fatalf("Grant b: granted=%v err=%v, want refused", granted, err)
	}
	// The runner a releases; the waiting runner b is admitted by the next
	// grant call.
	if err := q.Release(ctx, "runner-a", token, request("R1", "a", "sonnet")); err != nil {
		t.Fatalf("Release a: %v", err)
	}
	granted, err := q.Grant(ctx, "runner-a", token, request("R1", "b", "sonnet"))
	if err != nil || !granted {
		t.Fatalf("Grant b after release: granted=%v err=%v, want granted", granted, err)
	}
	if got := stateOf(t, q, "R1", "b"); got != SlotHeld {
		t.Fatalf("runner b state = %q, want held", got)
	}

	// The wait pair closed with granted true: no pending effect remains.
	events, err := eng.Events(ctx, "R1")
	if err != nil {
		t.Fatal(err)
	}
	st, err := journal.Replay(events)
	if err != nil {
		t.Fatal(err)
	}
	if pending := st.PendingEffects(); len(pending) != 0 {
		t.Fatalf("pending effects after the grant: %+v, want none", pending)
	}
}

// The wait-close rule, released side: a release while the runner still
// waits closes the open wait pair with granted false and released true, so
// the package never leaves a pending effect behind.
func TestReleaseClosesTheWaitGrantedFalse(t *testing.T) {
	q, eng, root := newTestQueue(t)
	ctx := context.Background()
	writeMap(t, root, ".claude/dev-team/models.local.json",
		`{"version":1,"concurrency":1}`)
	token := claim(t, eng, "R1")

	if granted, err := q.Grant(ctx, "runner-a", token, request("R1", "a", "sonnet")); err != nil || !granted {
		t.Fatalf("Grant a: granted=%v err=%v, want granted", granted, err)
	}
	if granted, err := q.Grant(ctx, "runner-a", token, request("R1", "b", "sonnet")); err != nil || granted {
		t.Fatalf("Grant b: granted=%v err=%v, want refused", granted, err)
	}
	// The waiting runner leaves the queue before it was granted.
	if err := q.Release(ctx, "runner-a", token, request("R1", "b", "sonnet")); err != nil {
		t.Fatalf("Release b: %v", err)
	}
	if got := stateOf(t, q, "R1", "b"); got != SlotReleased {
		t.Fatalf("runner b state = %q, want released", got)
	}
	// No pending effect: the wait pair closed with granted false.
	events, err := eng.Events(ctx, "R1")
	if err != nil {
		t.Fatal(err)
	}
	st, err := journal.Replay(events)
	if err != nil {
		t.Fatal(err)
	}
	if pending := st.PendingEffects(); len(pending) != 0 {
		t.Fatalf("pending effects after the release: %+v, want none", pending)
	}
	// The freed slot is real: the node cap admits a new runner again once
	// the holding runner releases too — b's release closed a wait, and a
	// waiting runner never held a slot to free.
	if err := q.Release(ctx, "runner-a", token, request("R1", "a", "sonnet")); err != nil {
		t.Fatalf("Release a: %v", err)
	}
	granted, err := q.Grant(ctx, "runner-a", token, request("R1", "c", "sonnet"))
	if err != nil || !granted {
		t.Fatalf("Grant c: granted=%v err=%v, want granted", granted, err)
	}
}

// AC1: a release closes the grant it names — the runner's re-grant after a
// release is a fresh decision, not a resurrection of the old one.
func TestReleaseClosesTheGrant(t *testing.T) {
	q, eng, _ := newTestQueue(t)
	ctx := context.Background()
	token := claim(t, eng, "R1")

	if granted, err := q.Grant(ctx, "runner-a", token, request("R1", "a", "sonnet")); err != nil || !granted {
		t.Fatalf("Grant: granted=%v err=%v, want granted", granted, err)
	}
	if err := q.Release(ctx, "runner-a", token, request("R1", "a", "sonnet")); err != nil {
		t.Fatalf("Release: %v", err)
	}
	// The re-grant is a fresh attempt: a distinct intent row, admitted
	// again (nothing else holds a slot).
	if granted, err := q.Grant(ctx, "runner-a", token, request("R1", "a", "sonnet")); err != nil || !granted {
		t.Fatalf("re-Grant: granted=%v err=%v, want granted", granted, err)
	}
	events, err := eng.Events(ctx, "R1")
	if err != nil {
		t.Fatal(err)
	}
	grants := 0
	for _, ev := range events {
		if ev.Kind != journal.KindSideEffect {
			continue
		}
		var ef journal.Effect
		if err := jsonUnmarshal(ev.Payload, &ef); err != nil {
			t.Fatal(err)
		}
		if ef.Effect == EffectGrant && ef.IntentSeq == 0 {
			grants++
		}
	}
	if grants != 2 {
		t.Fatalf("%d grant intents after the re-grant, want 2 (one per attempt)", grants)
	}
}

// AC6: a release→re-grant→release cycle is two releases — the second
// release derives its own idempotency key from the release count, lands a
// fresh intent row, and the fold returns to released instead of sticking
// in held (the slot leak the per-runner key caused).
func TestReleaseReGrantReleaseIsTwoReleases(t *testing.T) {
	q, eng, _ := newTestQueue(t)
	ctx := context.Background()
	token := claim(t, eng, "R1")

	if granted, err := q.Grant(ctx, "runner-a", token, request("R1", "a", "sonnet")); err != nil || !granted {
		t.Fatalf("Grant: granted=%v err=%v, want granted", granted, err)
	}
	if err := q.Release(ctx, "runner-a", token, request("R1", "a", "sonnet")); err != nil {
		t.Fatalf("first Release: %v", err)
	}
	if granted, err := q.Grant(ctx, "runner-a", token, request("R1", "a", "sonnet")); err != nil || !granted {
		t.Fatalf("re-Grant: granted=%v err=%v, want granted", granted, err)
	}
	if err := q.Release(ctx, "runner-a", token, request("R1", "a", "sonnet")); err != nil {
		t.Fatalf("second Release: %v", err)
	}
	if got := stateOf(t, q, "R1", "a"); got != SlotReleased {
		t.Fatalf("runner a state after the second release = %q, want released", got)
	}

	// The second release landed its own intent row: two release intents,
	// one per attempt.
	events, err := eng.Events(ctx, "R1")
	if err != nil {
		t.Fatal(err)
	}
	releases := 0
	for _, ev := range events {
		if ev.Kind != journal.KindSideEffect {
			continue
		}
		var ef journal.Effect
		if err := jsonUnmarshal(ev.Payload, &ef); err != nil {
			t.Fatal(err)
		}
		if ef.Effect == EffectRelease && ef.IntentSeq == 0 {
			releases++
		}
	}
	if releases != 2 {
		t.Fatalf("%d release intents after the cycle, want 2 (one per attempt)", releases)
	}
}

// AC6: a release intent recorded with its outcome missing — the fold
// derives released from the intent alone — replays to the same release: the
// re-issued release re-derives the release it recorded and never records a
// second slot.
func TestReleaseReplayReDerivesTheSameRelease(t *testing.T) {
	q, eng, _ := newTestQueue(t)
	ctx := context.Background()
	token := claim(t, eng, "R1")

	// The crash-window state: a release intent lands, its outcome does not.
	// The queue writes the pair in one transaction, so the test plants the
	// intent alone through the machine's keyed seam.
	m := run.New(eng, "R1")
	if _, _, err := m.IntentWhenKeyed(ctx, "runner-a", token,
		func(st *journal.State, d journal.Doer) (string, string, any, bool, error) {
			return EffectRelease, ReleaseKey("R1", "a", 0),
				releaseIntent{Runner: "a", Model: "sonnet"}, true, nil
		}, nil); err != nil {
		t.Fatalf("plant the dangling release intent: %v", err)
	}
	if got := stateOf(t, q, "R1", "a"); got != SlotReleased {
		t.Fatalf("runner a state = %q, want released (the fold counts the intent alone)", got)
	}

	// The replay: the re-issued release re-derives the recorded release —
	// exactly one release intent row, one slot, never two.
	if err := q.Release(ctx, "runner-a", token, request("R1", "a", "sonnet")); err != nil {
		t.Fatalf("replayed Release: %v", err)
	}
	events, err := eng.Events(ctx, "R1")
	if err != nil {
		t.Fatal(err)
	}
	releases := 0
	for _, ev := range events {
		if ev.Kind != journal.KindSideEffect {
			continue
		}
		var ef journal.Effect
		if err := jsonUnmarshal(ev.Payload, &ef); err != nil {
			t.Fatal(err)
		}
		if ef.Effect == EffectRelease && ef.IntentSeq == 0 {
			releases++
		}
	}
	if releases != 1 {
		t.Fatalf("%d release intents after the replay, want exactly 1", releases)
	}
	slots, err := q.Slots(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if n := len(slots); n != 1 {
		t.Fatalf("%d slot rows after the replay, want 1", n)
	}
}

// The match key survives full vendor model slugs (AC4, the CDT-603 related
// input): the tier tokens keep their token keys, a vendor slug keeps its
// full slug key, and an unnamed model falls back to the tier-default key.
func TestMatchKeySurvivesFullVendorSlugs(t *testing.T) {
	cases := []struct {
		model string
		want  string
	}{
		{"sonnet", "sonnet"},                     // tier token
		{"opus", "opus"},                         // tier token
		{"haiku", "haiku"},                       // tier token
		{"grok-code-fast-1", "grok-code-fast-1"}, // full vendor slug, never truncated
		{"studio-mlx/qwen3-32b", "studio-mlx/qwen3-32b"},
		{"", "tier-default"}, // empty resolution: the Tier default row
	}
	for _, c := range cases {
		if got := MatchKey(c.model); got != c.want {
			t.Fatalf("MatchKey(%q) = %q, want %q", c.model, got, c.want)
		}
	}
}

// The per-model-endpoint cap reads the Model map without forking it: the
// map layers keep their precedence (local > repo > global), a full-slug key
// beats the tier token of the same layer, and a named model with no cap row
// is unbounded.
func TestModelCapReadsTheMapLayers(t *testing.T) {
	t.Run("layer precedence", func(t *testing.T) {
		q, _, root := newTestQueue(t)
		writeMap(t, root, ".claude/dev-team/models.local.json",
			`{"version":1,"model_slots":{"sonnet":2}}`)
		writeMap(t, root, ".claude/dev-team/models.json",
			`{"version":1,"model_slots":{"sonnet":7}}`)
		c, err := q.resolveCaps(request("R1", "a", "sonnet"))
		if err != nil {
			t.Fatal(err)
		}
		if c.ModelCap != 2 {
			t.Fatalf("model cap = %d, want 2 (local beats repo)", c.ModelCap)
		}
		if c.Concurrency != 0 {
			t.Fatalf("concurrency = %d, want unbounded", c.Concurrency)
		}
	})
	t.Run("full slug beats tier token", func(t *testing.T) {
		q, _, root := newTestQueue(t)
		writeMap(t, root, ".claude/dev-team/models.local.json",
			`{"version":1,"model_slots":{"sonnet":9,"grok-code-fast-1":3}}`)
		c, err := q.resolveCaps(request("R1", "a", "grok-code-fast-1"))
		if err != nil {
			t.Fatal(err)
		}
		if c.ModelCap != 3 {
			t.Fatalf("model cap = %d, want 3 (the slug row)", c.ModelCap)
		}
	})
	t.Run("unnamed model is unbounded", func(t *testing.T) {
		q, _, root := newTestQueue(t)
		writeMap(t, root, ".claude/dev-team/models.local.json",
			`{"version":1,"model_slots":{"sonnet":2}}`)
		c, err := q.resolveCaps(request("R1", "a", "grok-4"))
		if err != nil {
			t.Fatal(err)
		}
		if c.ModelCap != 0 {
			t.Fatalf("model cap = %d, want unbounded (no row, no fallback)", c.ModelCap)
		}
	})
	t.Run("invalid stored cap fails closed", func(t *testing.T) {
		q, _, root := newTestQueue(t)
		writeMap(t, root, ".claude/dev-team/models.local.json",
			`{"version":1,"model_slots":{"sonnet":0}}`)
		if _, err := q.resolveCaps(request("R1", "a", "sonnet")); !errors.Is(err, ErrConfig) {
			t.Fatalf("err = %v, want ErrConfig", err)
		}
	})
	t.Run("env concurrency layer", func(t *testing.T) {
		q, _, _ := newTestQueue(t)
		q.getenv = func(k string) string {
			if k == "COUNCIL_CONCURRENCY" {
				return "3"
			}
			return ""
		}
		c, err := q.resolveCaps(request("R1", "a", "sonnet"))
		if err != nil {
			t.Fatal(err)
		}
		if c.Concurrency != 3 {
			t.Fatalf("concurrency = %d, want 3 (the env layer)", c.Concurrency)
		}
	})
	t.Run("junk env concurrency fails closed", func(t *testing.T) {
		q, _, _ := newTestQueue(t)
		q.getenv = func(k string) string {
			if k == "COUNCIL_CONCURRENCY" {
				return "zero"
			}
			return ""
		}
		if _, err := q.resolveCaps(request("R1", "a", "sonnet")); !errors.Is(err, ErrConfig) {
			t.Fatalf("err = %v, want ErrConfig", err)
		}
	})
}

// A malformed request is refused before any journal write.
func TestRequestValidation(t *testing.T) {
	q, eng, _ := newTestQueue(t)
	ctx := context.Background()
	token := claim(t, eng, "R1")
	cases := []struct {
		name string
		req  Request
	}{
		{"no run id", Request{Runner: "a", Model: "sonnet"}},
		{"no runner", Request{RunID: "R1", Model: "sonnet"}},
		{"no model", Request{RunID: "R1", Runner: "a"}},
	}
	for _, c := range cases {
		if _, err := q.Grant(ctx, "runner-a", token, c.req); !errors.Is(err, ErrInvalid) {
			t.Fatalf("%s: err = %v, want ErrInvalid", c.name, err)
		}
		if err := q.Release(ctx, "runner-a", token, c.req); !errors.Is(err, ErrInvalid) {
			t.Fatalf("%s release: err = %v, want ErrInvalid", c.name, err)
		}
	}
}

// A stale fencing token is refused through the C2 machine: the queue writes
// nothing and passes journal.ErrStaleToken through.
func TestStaleTokenIsRefused(t *testing.T) {
	q, eng, _ := newTestQueue(t)
	ctx := context.Background()
	token := claim(t, eng, "R1")
	if _, err := q.Grant(ctx, "runner-a", token+1, request("R1", "a", "sonnet")); !errors.Is(err, journal.ErrStaleToken) {
		t.Fatalf("err = %v, want journal.ErrStaleToken", err)
	}
	events, err := eng.Events(ctx, "R1")
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 2 { // the claim and the start rows only
		t.Fatalf("%d events after a stale grant, want 2 (the claim and the start)", len(events))
	}
}

// jsonUnmarshal decodes a journal payload in the tests.
func jsonUnmarshal(raw []byte, v any) error {
	return json.Unmarshal(raw, v)
}
