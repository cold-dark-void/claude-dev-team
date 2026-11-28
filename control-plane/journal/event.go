package journal

import (
	"bytes"
	"encoding/json"
	"fmt"
	"time"
)

// Kind is an event type. The set is closed and CHECK-constrained in schema.sql:
// a kind outside it cannot be written.
type Kind string

// The closed event-kind set. Replay handles every one of them (AC1).
const (
	KindRunClaimed   Kind = "run_claimed"    // an owner takes the run (lease + token in payload)
	KindLeaseAcquire Kind = "lease_acquired" // lease taken over from an expired owner
	KindRunStarted   Kind = "run_started"    // claimed -> running
	KindStintStarted Kind = "stint_started"  // one stint of the workflow begins
	KindHeartbeat    Kind = "heartbeat"      // the owner is alive (watchdog input)
	KindRunProgress  Kind = "run_progress"   // the session's last output time (liveness is not the point)
	KindSideEffect   Kind = "side_effect"    // intent row, then outcome row (AC3)
	KindRunHalted    Kind = "run_halted"     // running -> halted:<reason> (AC6)
	KindRunResumed   Kind = "run_resumed"    // halted:<reason> -> running (spends retry budget)
	KindRepair       Kind = "repair"         // reconciler journal of one repair (AC5)
	KindRunCompleted Kind = "run_completed"  // terminal success
	KindRunFailed    Kind = "run_failed"     // terminal failure
)

// AllKinds is the closed set, in schema order.
var AllKinds = []Kind{
	KindRunClaimed, KindLeaseAcquire, KindRunStarted, KindStintStarted,
	KindHeartbeat, KindRunProgress, KindSideEffect, KindRunHalted, KindRunResumed,
	KindRepair, KindRunCompleted, KindRunFailed,
}

func (k Kind) valid() bool {
	for _, v := range AllKinds {
		if v == k {
			return true
		}
	}
	return false
}

// CardRef is a reference to a decision-card: path, ts, run_id, and nothing else
// (AC2; docs/adr/0001-journal-engine.md § "The journal references
// decision-cards"). The struct is the compile-time half of the frozen-schema
// rule: it is the only type that fills the card_* columns, it carries no card
// field, and it has no JSON marshaller, so a card object cannot be built from
// it, copied through it, or extended by it. SPEC-033 AC6/M13 keeps the card
// schema_version at 1 and skills/autopilot/append-card.sh stays the only card
// writer; this package never opens a card path for writing.
type CardRef struct {
	Path  string `json:"path"`
	TS    string `json:"ts"`
	RunID string `json:"run_id"`
}

// cardColumns is the compile-time statement of what the journal carries about a
// card: three reference columns, no more. engine.go binds exactly these.
var cardColumns = [3]string{"card_path", "card_ts", "card_run_id"}

// cardRefShape is the frozen card-reference record. The conversion below
// compiles only while CardRef is exactly these three string fields with no
// struct tags: a fourth field, a rename, a retag, or a type change breaks the
// build. That is the compile-time half of the card-reference rule
// (SPEC-033 AC6/M13; docs/adr/0001-journal-engine.md § "The journal references
// decision-cards") — the journal cannot grow a card copy into a row.
type cardRefShape struct {
	Path  string
	TS    string
	RunID string
}

var _ = cardRefShape(CardRef{})

// cardSchemaVersion is a read-only citation, not a knob. SPEC-033 AC6/M13 keeps
// every decision-card at schema_version 1; the journal writes no card and never
// bumps a card version.
const cardSchemaVersion = 1

var _ = cardSchemaVersion

// cardBindArgs returns the three reference values in cardColumns order.
func (c CardRef) cardBindArgs() [cardArgCount]any {
	return [cardArgCount]any{c.Path, c.TS, c.RunID}
}

// cardBindArgs returns NULL for all three columns when the event carries no
// card reference.
func (e Event) cardBindArgs() []any {
	if e.Card == nil {
		out := make([]any, cardArgCount)
		for i := range out {
			out[i] = any(nil)
		}
		return out
	}
	args := e.Card.cardBindArgs()
	return args[:]
}

func (c CardRef) valid() error {
	if c.Path == "" || c.TS == "" || c.RunID == "" {
		return fmt.Errorf("%w: card reference needs path, ts, and run_id, got %+v", ErrInvalid, c)
	}
	return nil
}

// Effect is the side-effect payload (AC3, intent-then-outcome after the
// SPEC-040 AC11 pattern). The intent row sets Intent and leaves Outcome nil;
// the outcome row carries IntentSeq, the seq of the intent row it closes.
type Effect struct {
	// Effect names the external action: push, pr, ticket, release, …
	Effect string `json:"effect"`
	// Intent is what the writer asked for. It is recorded before the effect runs.
	Intent json.RawMessage `json:"intent,omitempty"`
	// Outcome is the observed result. Nil on an intent row = the effect is pending.
	Outcome json.RawMessage `json:"outcome,omitempty"`
	// IntentSeq points an outcome row at its intent row. 0 on an intent row.
	IntentSeq int64 `json:"intent_seq,omitempty"`
}

func (e Effect) valid() error {
	if e.Effect == "" {
		return fmt.Errorf("%w: side_effect needs an effect name", ErrInvalid)
	}
	return nil
}

// Event is one journal row.
type Event struct {
	Seq            int64           `json:"seq"`
	TS             string          `json:"ts"`
	RunID          string          `json:"run_id"`
	Kind           Kind            `json:"kind"`
	Payload        json.RawMessage `json:"payload"`
	IdempotencyKey string          `json:"idempotency_key,omitempty"`
	Card           *CardRef        `json:"card,omitempty"`
}

// NewEvent builds an event with a validated payload and the canonical UTC
// timestamp shape the schema CHECK enforces.
func NewEvent(runID string, kind Kind, payload any) (Event, error) {
	if runID == "" {
		return Event{}, fmt.Errorf("%w: run_id is required", ErrInvalid)
	}
	if !kind.valid() {
		return Event{}, fmt.Errorf("%w: unknown event kind %q", ErrInvalid, kind)
	}
	raw, err := marshalPayload(payload)
	if err != nil {
		return Event{}, err
	}
	return Event{
		TS:      time.Now().UTC().Format(tsLayout),
		RunID:   runID,
		Kind:    kind,
		Payload: raw,
	}, nil
}

func marshalPayload(payload any) (json.RawMessage, error) {
	if payload == nil {
		return json.RawMessage(`{}`), nil
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		return nil, fmt.Errorf("%w: payload: %v", ErrInvalid, err)
	}
	var check any
	if err := json.Unmarshal(raw, &check); err != nil || check == nil {
		return nil, fmt.Errorf("%w: payload must be a JSON object", ErrInvalid)
	}
	return raw, nil
}

// Validate reports whether the row is legal to append.
func (e Event) Validate() error {
	if e.RunID == "" {
		return fmt.Errorf("%w: run_id is required", ErrInvalid)
	}
	if !e.Kind.valid() {
		return fmt.Errorf("%w: unknown event kind %q", ErrInvalid, e.Kind)
	}
	if !isCanonicalTS(e.TS) {
		return fmt.Errorf("%w: ts %q is not UTC RFC3339 second precision", ErrInvalid, e.TS)
	}
	if len(e.Payload) == 0 {
		return fmt.Errorf("%w: payload is required", ErrInvalid)
	}
	trimmed := bytes.TrimSpace(e.Payload)
	if len(trimmed) == 0 || trimmed[0] != '{' {
		return fmt.Errorf("%w: payload must be a JSON object", ErrInvalid)
	}
	if e.Kind == KindSideEffect {
		var ef Effect
		if err := json.Unmarshal(trimmed, &ef); err != nil {
			return fmt.Errorf("%w: side_effect payload: %v", ErrInvalid, err)
		}
		if err := ef.valid(); err != nil {
			return err
		}
		if ef.IntentSeq == 0 && ef.IdempotencyKeyRequired() && e.IdempotencyKey == "" {
			return fmt.Errorf("%w: an intent row needs an idempotency key", ErrInvalid)
		}
	}
	if e.Card != nil {
		return e.Card.valid()
	}
	return nil
}

// IntentRow reports whether this is the intent half of a side effect.
func (e Event) IntentRow() bool {
	if e.Kind != KindSideEffect {
		return false
	}
	var ef Effect
	if err := json.Unmarshal(e.Payload, &ef); err != nil {
		return false
	}
	return ef.IntentSeq == 0
}

// IdempotencyKeyRequired is true for every intent row: an effect with no key
// cannot be made replay-safe, so it is not a legal intent.
func (e Effect) IdempotencyKeyRequired() bool { return e.Outcome == nil }

const tsLayout = "2006-01-02T15:04:05Z"

func isCanonicalTS(s string) bool {
	t, err := time.Parse(tsLayout, s)
	if err != nil {
		return false
	}
	return t.UTC().Format(tsLayout) == s
}

// FormatTS renders a time in the one timestamp shape the schema accepts.
// Canonical UTC second precision sorts the same way as the epoch, which is what
// makes a lease expiry testable with a plain string compare.
func FormatTS(t time.Time) string { return t.UTC().Format(tsLayout) }

// ParseTS reads a journal timestamp.
func ParseTS(s string) (time.Time, error) {
	t, err := time.Parse(tsLayout, s)
	if err != nil {
		return time.Time{}, fmt.Errorf("%w: ts %q is not UTC RFC3339 second precision", ErrInvalid, s)
	}
	return t.UTC(), nil
}

// NowUTC is the canonical clock. Inject a replacement into Machine for tests.
func NowUTC() string { return time.Now().UTC().Format(tsLayout) }
