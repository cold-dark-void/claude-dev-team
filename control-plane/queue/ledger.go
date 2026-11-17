package queue

import (
	"context"
	"database/sql"
	"encoding/json"
	"sort"

	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
)

// Slot states, the status-surface vocabulary (AC2). SlotHeld is a runner
// that occupies its slot; SlotWaiting is a live runner both caps refused —
// a queue-level status, not a run state (CDT-642); SlotReleased is a runner
// that gave its slot back.
const (
	SlotHeld     = "held"
	SlotWaiting  = "waiting"
	SlotReleased = "released"
)

// Slot is the status-surface row for one runner (AC2): what the runner
// holds, and the model cap its grant named.
type Slot struct {
	// RunID is the run the runner works on.
	RunID string `json:"run_id"`
	// Runner is the runner identity: one slot is one runner (AC1).
	Runner string `json:"runner"`
	// State is one of the Slot* states.
	State string `json:"state"`
	// Model is the resolved model string the request carried.
	Model string `json:"model,omitempty"`
	// GrantKey is the match key the caps resolved (§ the match key).
	GrantKey string `json:"grant_key,omitempty"`
	// ModelCap is the per-model-endpoint cap the grant named. 0 means
	// unbounded: no map row for the match key and no "tier-default" row.
	ModelCap int `json:"model_cap,omitempty"`
}

// hold is the ledger's record of one (run, runner) pair. It is derived from
// the journal's slot effects alone (AC6: the intent is the record), so the
// accounting and the grant decision cannot disagree — they are the same fold
// of the same rows.
type hold struct {
	state string
	// model, grantKey, and modelCap ride the grant that set the state.
	model    string
	grantKey string
	modelCap int
	// waits and releases carry the runner's wait and release intent rows in
	// seq order. The counts name the attempt an idempotency key belongs to;
	// the pending wait is the open pair a later grant or release closes.
	waits    []journal.RecordedEffect
	releases int
}

// fold projects the journal's slot effects into one hold per (run, runner),
// keyed runID + "\x00" + runner. Every write the queue makes is an intent
// row first, so the fold counts on the intent alone: a grant intent without
// its outcome already holds the slot, which is what makes a kill-and-replay
// never grant a slot twice (AC6). An intent row carries IntentSeq 0; an
// outcome row points at its intent and carries no intent payload of its own.
func fold(events []journal.Event) map[string]*hold {
	out := map[string]*hold{}
	for _, ev := range events {
		if ev.Kind != journal.KindSideEffect {
			continue
		}
		var ef journal.Effect
		if err := json.Unmarshal(ev.Payload, &ef); err != nil {
			// The CHECK constraint and the closed kind set bound what the
			// table can carry; a row that does not decode is refused at the
			// replay, never folded.
			continue
		}
		switch ef.Effect {
		case EffectGrant:
			if ef.IntentSeq != 0 {
				continue // the outcome row changes no state
			}
			var gi grantIntent
			if err := json.Unmarshal(ef.Intent, &gi); err != nil || gi.Runner == "" {
				continue
			}
			h := touch(out, ev.RunID+"\x00"+gi.Runner)
			h.state = SlotHeld
			h.model = gi.Model
			h.grantKey = gi.GrantKey
			h.modelCap = gi.ModelCap
		case EffectWait:
			if ef.IntentSeq == 0 {
				// The intent row: the pending intent IS the waiting state
				// (AC2), and it is the open pair a later grant or release
				// closes.
				var wi waitIntent
				if err := json.Unmarshal(ef.Intent, &wi); err != nil || wi.Runner == "" {
					continue
				}
				h := touch(out, ev.RunID+"\x00"+wi.Runner)
				h.waits = append(h.waits, recorded(ev, ef))
				h.state = SlotWaiting
				h.model = wi.Model
				h.grantKey = wi.GrantKey
				continue
			}
			// The outcome row: the closed pair names the state the runner
			// went on to.
			o := waitOutcomeOf(ev)
			if o == nil || o.Runner == "" {
				continue
			}
			h := touch(out, ev.RunID+"\x00"+o.Runner)
			if o.Granted {
				h.state = SlotHeld
			} else if o.Released {
				h.state = SlotReleased
			}
		case EffectRelease:
			if ef.IntentSeq != 0 {
				continue // the outcome row changes no state
			}
			var ri releaseIntent
			if err := json.Unmarshal(ef.Intent, &ri); err != nil || ri.Runner == "" {
				continue
			}
			h := touch(out, ev.RunID+"\x00"+ri.Runner)
			h.state = SlotReleased
			h.model = ri.Model
			h.releases++
		}
	}
	return out
}

// touch returns the hold for id, creating it in map order.
func touch(m map[string]*hold, id string) *hold {
	h, ok := m[id]
	if !ok {
		h = &hold{}
		m[id] = h
	}
	return h
}

// recorded rebuilds the effect record of one row, carrying the
// idempotency key and the outcome payload the fold needs.
func recorded(ev journal.Event, ef journal.Effect) journal.RecordedEffect {
	return journal.RecordedEffect{
		Seq:        ev.Seq,
		TS:         ev.TS,
		Effect:     ef.Effect,
		Key:        ev.IdempotencyKey,
		Intent:     ef.Intent,
		Outcome:    ef.Outcome,
		OutcomeSeq: outcomeSeq(ev),
	}
}

// outcomeSeq is the intent seq a closed outcome row points at.
func outcomeSeq(ev journal.Event) int64 {
	var ef journal.Effect
	if err := json.Unmarshal(ev.Payload, &ef); err != nil {
		return 0
	}
	return ef.IntentSeq
}

// waitOutcomeOf decodes a recorded wait outcome. A malformed outcome is a
// replay-inconsistent journal; nil there and on a pending intent is the
// replay-safe default: nothing granted yet.
func waitOutcomeOf(ev journal.Event) *waitOutcome {
	var ef journal.Effect
	if err := json.Unmarshal(ev.Payload, &ef); err != nil || ef.Outcome == nil {
		return nil
	}
	var o waitOutcome
	if err := json.Unmarshal(ef.Outcome, &o); err != nil {
		return nil
	}
	return &o
}

// nodeLedger folds every side-effect row in the journal, inside whatever
// transaction or autocommit read d carries. The grant decision runs it in
// the write transaction, so the node cap counts every held runner on the
// node under the same write lock that admits or refuses the new one.
func nodeLedger(ctx context.Context, d journal.Doer) (map[string]*hold, error) {
	rows, err := d.QueryContext(ctx, slotEventsSQL)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	events, err := scanSlotEvents(rows)
	if err != nil {
		return nil, err
	}
	return fold(events), nil
}

// scanSlotEvents reads the slot ledger query's rows.
func scanSlotEvents(rows *sql.Rows) ([]journal.Event, error) {
	var out []journal.Event
	for rows.Next() {
		var (
			ev      journal.Event
			payload string
			key     sql.NullString
		)
		if err := rows.Scan(&ev.Seq, &ev.TS, &ev.RunID, &ev.Kind, &payload, &key); err != nil {
			return nil, err
		}
		ev.Kind = journal.Kind(ev.Kind)
		ev.Payload = []byte(payload)
		ev.IdempotencyKey = key.String
		out = append(out, ev)
	}
	return out, rows.Err()
}

// sortedHolds is the (run, runner) order the status surface prints slots in.
func sortedHolds(m map[string]*hold) []string {
	out := make([]string, 0, len(m))
	for id := range m {
		out = append(out, id)
	}
	sort.Strings(out)
	return out
}

// countIntents counts one effect's intent rows for one (run, runner) id.
// The grant and wait keys derive their attempt number from these counts, so
// two attempts never share a key and a replay re-derives the key it
// recorded.
func countIntents(l map[string]*hold, id, effect string) int {
	h, ok := l[id]
	if !ok {
		return 0
	}
	switch effect {
	case EffectWait:
		return len(h.waits)
	case EffectRelease:
		return h.releases
	}
	return 0
}
