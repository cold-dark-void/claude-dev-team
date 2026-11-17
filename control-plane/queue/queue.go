package queue

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
	"github.com/cold-dark-void/claude-dev-team/control-plane/run"
)

// Effect names of the queue's journal-first verbs, namespaced under
// run.RoleQueue. Each intent row lands inside one fencing-token-checked
// transaction; each outcome row closes it (AC6). The wait pair is the one
// pair that stays open on purpose: its pending intent IS the waiting state,
// and its outcome lands when the wait ends — granted true when a later
// grant admits the runner, granted false and released true when a release
// ends the wait first.
const (
	EffectGrant   = "slot.grant"
	EffectWait    = "slot.wait"
	EffectRelease = "slot.release"
)

// AllEffects is the closed effect set of the queue, in contract order.
var AllEffects = []string{EffectGrant, EffectWait, EffectRelease}

// slotEventsSQL is the one ledger read: every side-effect row in the
// journal, in seq order. It runs inside the grant transaction (read-your-
// writes on the same connection), so the accounting and the append commit
// together.
const slotEventsSQL = `SELECT seq, ts, run_id, kind, payload_json, idempotency_key
    FROM events WHERE kind = 'side_effect' ORDER BY seq ASC`

// mroot resolves the Model-map root, overridable so a test can point the
// layer scan at a fixture directory instead of the real $MROOT.
type mrootFunc func() (string, error)

func defaultMroot() (string, error) { return journal.MROOT() }

// layer paths, relative to the root. The same three layers, in the same
// precedence order, skills/model-map/resolve-model.sh reads (SPEC-037 M11):
// local > repo > global. First hit wins per key.
var layerRelPaths = []struct {
	rel  string
	name string
}{
	{".claude/dev-team/models.local.json", "local"},
	{".claude/dev-team/models.json", "repo"},
}

// globalRelPath is the global layer, under $HOME.
const globalRelPath = ".claude/dev-team/models.json"

// Queue is the run queue over one journal (CDT-649). It reuses the C2 run
// machine for every write — the lease, the fencing token, and the replay
// check are the machine's — and adds no state of its own: the slot ledger
// is the replay of the journal's slot effects (AC6).
type Queue struct {
	eng *journal.Engine
	// mroot resolves the Model-map root. Tests inject a fixture directory.
	mroot mrootFunc
	// home resolves the global layer. Tests inject a fixture directory.
	home func() string
	// getenv resolves COUNCIL_CONCURRENCY. Defaults to os.Getenv.
	getenv func(string) string
}

// New returns a queue over eng.
func New(eng *journal.Engine) *Queue {
	return &Queue{
		eng:    eng,
		mroot:  defaultMroot,
		home:   func() string { return os.Getenv("HOME") },
		getenv: os.Getenv,
	}
}

// GrantKey is the idempotency key of one grant attempt, derived inside the
// grant transaction: one per release count, because a release is the only
// thing that separates two grants of one runner. A replay re-derives the
// same key from the same ledger and finds the row it recorded, so a
// kill-and-replay grants a slot exactly once (AC6).
func GrantKey(runID, runner string, releases int) string {
	return key("slot.grant", runID, runner, fmt.Sprint(releases))
}

// WaitKey is the idempotency key of one wait attempt, derived inside the
// transaction: one per wait count, because each refused grant records one
// wait and the grant that ends the wait closes it.
func WaitKey(runID, runner string, waits int) string {
	return key("slot.wait", runID, runner, fmt.Sprint(waits))
}

// ReleaseKey is the idempotency key of one release attempt, derived inside
// the transaction: one per release count, because a release→re-grant→release
// cycle is two releases, not one — without the count the second release
// reuses the first release's key, the append reads it as a replay, and the
// runner never leaves SlotHeld. A replay re-derives the key it recorded, so
// a release lands exactly once (AC6).
func ReleaseKey(runID, runner string, releases int) string {
	return key("slot.release", runID, runner, fmt.Sprint(releases))
}

// key builds one idempotency key, namespaced under run.RoleQueue.
func key(parts ...string) string {
	return strings.Join(append([]string{run.RoleQueue}, parts...), ":")
}

// Grant decides a runner's slot request (AC1, AC2): both caps must admit it.
//
// The ledger is the journal's slot effects, folded inside the same
// BEGIN IMMEDIATE transaction the intent commits in, so the accounting and
// the grant are one atomic step: two queues cannot both grant past a cap,
// and a kill-and-replay re-derives the grant it recorded — a slot is never
// granted twice (AC6).
//
// When the runner waits (granted=false), the pending slot.wait intent is
// the waiting state (AC2); a later grant closes it with granted true, and a
// release closes it with granted false and released true (§ the wait-close
// rule in the package doc).
func (q *Queue) Grant(ctx context.Context, owner string, token int64, req Request) (granted bool, err error) {
	if err := req.validate(); err != nil {
		return false, err
	}
	// The caps are resolved outside the transaction: the Model map is a
	// config read (SPEC-037 M11), not a journal read, and the resolved pair
	// is what the intent records.
	c, err := q.resolveCaps(req)
	if err != nil {
		return false, err
	}
	gk := MatchKey(req.Model)

	// pendingWait carries the open wait the grant will close, when the
	// runner waited first (§ the wait-close rule). landed names the effect
	// the decision chose: a landed wait stays pending by design.
	var pendingWait *journal.RecordedEffect
	var landed string

	_, _, err = run.New(q.eng, req.RunID).IntentWhenKeyed(ctx, owner, token,
		func(st *journal.State, d journal.Doer) (string, string, any, bool, error) {
			l, err := nodeLedger(ctx, d)
			if err != nil {
				return "", "", nil, false, err
			}
			id := req.RunID + "\x00" + req.Runner
			if h, held := l[id]; held && h.state == SlotHeld {
				// The runner holds the slot: the replay case re-derives the
				// grant it recorded and records nothing.
				granted = true
				return "", "", nil, false, nil
			}

			// Both caps must admit the grant; either alone makes the runner
			// wait (AC2). The node cap counts every held runner on the node;
			// the model cap counts the held runners whose grant key matches
			// this request's.
			var heldCount, modelCount int
			for _, id := range sortedHolds(l) {
				h := l[id]
				if h.state != SlotHeld {
					continue
				}
				heldCount++
				if h.grantKey == gk {
					modelCount++
				}
			}
			admit := true
			if c.Concurrency > 0 && heldCount >= c.Concurrency {
				admit = false
			}
			if c.ModelCap > 0 && modelCount >= c.ModelCap {
				admit = false
			}
			granted = admit
			if !admit {
				// The runner waits — but one pending wait is enough: a
				// re-issued grant while the runner already waits re-derives
				// the refusal and records nothing.
				if h, present := l[id]; present && h.state == SlotWaiting {
					return "", "", nil, false, nil
				}
				// A fresh wait attempt. The idempotency key is one per wait
				// count, so two waits never share a key.
				waits := countIntents(l, id, EffectWait)
				landed = EffectWait
				return EffectWait, WaitKey(req.RunID, req.Runner, waits),
					waitIntent{Runner: req.Runner, Model: req.Model, GrantKey: gk}, true, nil
			}

			// The grant lands. A pending wait for this runner closes with it.
			if h, present := l[id]; present && h.state == SlotWaiting {
				for _, e := range l[id].waits {
					if e.Pending() {
						pendingWait = &e
						break
					}
				}
			}
			releases := countIntents(l, id, EffectRelease)
			landed = EffectGrant
			return EffectGrant, GrantKey(req.RunID, req.Runner, releases),
				grantIntent{Runner: req.Runner, Model: req.Model, GrantKey: gk,
					ModelCap: c.ModelCap}, true, nil
		},
		func(ctx context.Context, tx *journal.Tx, seq int64, created bool) error {
			// A landed wait stays pending on purpose: its outcome is the
			// waiting end — granted true when a later grant admits the
			// runner, granted false and released true when a release ends
			// the wait first (§ the wait-close rule).
			if landed == EffectWait {
				return nil
			}
			// The grant's outcome closes its own intent in the same
			// transaction, so no grant pair ever dangles pending across a
			// kill (AC6). On a replay (created=false) the recorded rows
			// already carry both writes.
			if !created {
				return nil
			}
			if err := appendOutcome(ctx, tx, req.RunID, seq, EffectGrant,
				grantOutcome{Runner: req.Runner}); err != nil {
				return err
			}
			if pendingWait != nil {
				// Close the open wait pair with granted true (§ the
				// wait-close rule).
				return appendOutcome(ctx, tx, req.RunID, pendingWait.Seq, EffectWait,
					waitOutcome{Runner: req.Runner, Granted: true})
			}
			return nil
		})
	return granted, err
}

// Release gives one held runner's slot back (AC6). A release of a waiting
// runner closes the open wait pair with granted false and released true
// before it records the release (§ the wait-close rule).
func (q *Queue) Release(ctx context.Context, owner string, token int64, req Request) error {
	if err := req.validate(); err != nil {
		return err
	}
	// pendingWait carries the open wait the release will close, when the
	// runner was still waiting (§ the wait-close rule).
	var pendingWait *journal.RecordedEffect

	_, _, err := run.New(q.eng, req.RunID).IntentWhenKeyed(ctx, owner, token,
		func(st *journal.State, d journal.Doer) (string, string, any, bool, error) {
			l, err := nodeLedger(ctx, d)
			if err != nil {
				return "", "", nil, false, err
			}
			id := req.RunID + "\x00" + req.Runner
			h, present := l[id]
			if !present {
				// Nothing to release. A replay finds its own release row and
				// stops here; a first call for an unknown runner refused.
				return "", "", nil, false, nil
			}
			if h.state == SlotWaiting {
				for _, e := range h.waits {
					if e.Pending() {
						pendingWait = &e
						break
					}
				}
			}
			if h.state == SlotReleased {
				// The runner already gave its slot back.
				return "", "", nil, false, nil
			}
			// A fresh release attempt. The idempotency key is one per
			// release count, so a release→re-grant→release cycle never
			// shares a key between its two releases.
			releases := countIntents(l, id, EffectRelease)
			return EffectRelease, ReleaseKey(req.RunID, req.Runner, releases),
				releaseIntent{Runner: req.Runner, Model: req.Model}, true, nil
		},
		func(ctx context.Context, tx *journal.Tx, seq int64, created bool) error {
			if !created {
				return nil
			}
			if pendingWait != nil {
				// Close the open wait pair with granted false and released
				// true: the runner left the queue before it was granted
				// (§ the wait-close rule).
				if err := appendOutcome(ctx, tx, req.RunID, pendingWait.Seq, EffectWait,
					waitOutcome{Runner: req.Runner, Released: true}); err != nil {
					return err
				}
			}
			// The release's outcome closes its own intent in the same
			// transaction (AC6).
			return appendOutcome(ctx, tx, req.RunID, seq, EffectRelease,
				releaseOutcome{Runner: req.Runner})
		})
	return err
}

// appendOutcome appends one outcome row inside the transaction that recorded
// the intent it closes (AC6). The row is checked against the replay, so an
// outcome for an intent that already carries one is refused before it lands.
func appendOutcome(ctx context.Context, tx *journal.Tx, runID string, intentSeq int64,
	effect string, outcome any) error {
	raw, err := jsonMarshal(outcome)
	if err != nil {
		return err
	}
	ev, err := journal.NewEvent(runID, journal.KindSideEffect,
		journal.Effect{Effect: effect, Outcome: raw, IntentSeq: intentSeq})
	if err != nil {
		return err
	}
	_, _, err = tx.AppendChecked(ctx, ev)
	return err
}

// jsonMarshal renders a payload.
func jsonMarshal(v any) (json.RawMessage, error) {
	raw, err := json.Marshal(v)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalid, err)
	}
	return raw, nil
}

// resolveCaps reads the two caps for one request: the node concurrency
// setting (the COUNCIL_CONCURRENCY env layer, then the top-level
// "concurrency" key of the Model map, local > repo > global — the
// resolve-concurrency.sh chain), and the per-model-endpoint cap named for
// the request's match key (§ the match key).
func (q *Queue) resolveCaps(req Request) (caps, error) {
	var c caps
	// Layer 1 of the concurrency setting: the env var the Spawn concurrency
	// cap exports (CDT-573). Empty counts as unset.
	if raw := strings.TrimSpace(q.getenv("COUNCIL_CONCURRENCY")); raw != "" {
		n, err := parseCap(raw)
		if err != nil {
			return caps{}, fmt.Errorf("%w: COUNCIL_CONCURRENCY: %v", ErrConfig, err)
		}
		c.Concurrency = n
	}
	root, err := q.mroot()
	if err != nil {
		return caps{}, err
	}
	files := make([]string, 0, len(layerRelPaths)+1)
	for _, l := range layerRelPaths {
		files = append(files, filepath.Join(root, l.rel))
	}
	if h := strings.TrimSpace(q.home()); h != "" {
		files = append(files, filepath.Join(h, globalRelPath))
	}

	for _, file := range files {
		raw, err := os.ReadFile(file)
		if err != nil {
			continue // absent layer: skip, no warning (SPEC-037 M6)
		}
		var doc map[string]json.RawMessage
		if err := json.Unmarshal(raw, &doc); err != nil {
			continue // not a JSON object: the layer is skipped whole (M32)
		}
		// The node concurrency setting, layer 2: the top-level
		// "concurrency" key (CDT-573), the resolve-concurrency.sh shape.
		if c.Concurrency == 0 {
			n, err := concurrencyFromDoc(doc, file)
			if err != nil {
				return caps{}, err
			}
			c.Concurrency = n
		}
		// The per-model-endpoint cap: the first layer that carries a cap
		// for the match key wins, local > repo > global — the Model-map
		// precedence (SPEC-037 M11). The lookup is exact: the match key's
		// own row, else the "tier-default" row. The tier token of a slug's
		// family never stands in for the slug (§ the match key).
		if c.ModelCap == 0 {
			slots, err := modelSlots(raw, file)
			if err != nil {
				return caps{}, err
			}
			gk := MatchKey(req.Model)
			if n, ok := slots[gk]; ok {
				c.ModelCap = n
			} else if gk != "tier-default" {
				if n, ok := slots["tier-default"]; ok {
					c.ModelCap = n
				}
			}
		}
		if c.Concurrency != 0 && c.ModelCap != 0 {
			break // both caps resolved; later layers cannot raise them
		}
	}
	return c, nil
}

// Slots is the status-surface read (AC2): every runner in the queue, in
// (run_id, runner) order, with its state. The waiting state is a queue-level
// status on a live runner, not a run state — no lifecycle-graph vertex is
// needed (CDT-642).
func (q *Queue) Slots(ctx context.Context) ([]Slot, error) {
	events, err := q.eng.AllEvents(ctx)
	if err != nil {
		return nil, err
	}
	l := fold(events)
	out := make([]Slot, 0, len(l))
	for _, id := range sortedHolds(l) {
		h := l[id]
		runID, runner, _ := strings.Cut(id, "\x00")
		out = append(out, Slot{
			RunID: runID, Runner: runner, State: h.state,
			Model: h.model, GrantKey: h.grantKey, ModelCap: h.modelCap,
		})
	}
	return out, nil
}
