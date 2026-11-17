package killtest

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
	"github.com/cold-dark-void/claude-dev-team/control-plane/run"
)

// EffectLog is the external world: one append-only line per side effect that
// actually ran. The journal records the intent and the outcome; this file is
// what happened outside SQLite, and it is what the exactly-once property is
// measured on. A recovery that replays an intent row must consult it, not the
// journal alone, because the kill can land between the effect and its outcome
// row, where the effect ran and the journal does not know it.
//
// Line shape: <idempotency key>\t<effect>\t<ts>.
type EffectLog struct{ path string }

// NewEffectLog points at an effect log path. The file need not exist.
func NewEffectLog(path string) *EffectLog { return &EffectLog{path: path} }

// Path is the file this log writes.
func (l *EffectLog) Path() string { return l.path }

// Keys returns the keys recorded so far, in file order. A missing file is an
// empty log, not an error: the first attempt may have died before any effect.
func (l *EffectLog) Keys() ([]string, error) {
	f, err := os.Open(l.path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("killtest: open effect log: %w", err)
	}
	defer f.Close()

	var out []string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		key, _, _ := strings.Cut(line, "\t")
		out = append(out, key)
	}
	return out, sc.Err()
}

// Has reports whether the effect behind key already ran.
func (l *EffectLog) Has(key string) (bool, error) {
	keys, err := l.Keys()
	if err != nil {
		return false, err
	}
	for _, k := range keys {
		if k == key {
			return true, nil
		}
	}
	return false, nil
}

// Perform runs the effect behind key unless the log already records it, and
// returns whether this call performed it. The record is flushed before the call
// returns, so a SIGKILL cannot lose an effect that happened: a lost record
// would let a replay run the effect twice, which is the failure AC7 forbids.
func (l *EffectLog) Perform(key, effect string) (bool, error) {
	done, err := l.Has(key)
	if err != nil {
		return false, err
	}
	if done {
		return false, nil
	}
	if dir := filepath.Dir(l.path); dir != "" && dir != "/" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return false, fmt.Errorf("killtest: create effect log dir: %w", err)
		}
	}
	f, err := os.OpenFile(l.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return false, fmt.Errorf("killtest: open effect log: %w", err)
	}
	defer f.Close()

	if _, err := fmt.Fprintf(f, "%s\t%s\t%s\n", key, effect, journal.NowUTC()); err != nil {
		return false, fmt.Errorf("killtest: append effect log: %w", err)
	}
	if err := f.Sync(); err != nil {
		return false, fmt.Errorf("killtest: sync effect log: %w", err)
	}
	return true, nil
}

// RunEffect performs one labelled side effect exactly once, across a crash.
//
// The order is the intent-then-outcome pair of SPEC-040 AC11:
//
//  1. Intent: append the intent row under the idempotency key. A replay of a
//     key the journal already recorded returns the existing row and writes
//     nothing (journal.AppendChecked), so the intent itself is not repeated.
//  2. Effect: perform it against the EffectLog, which refuses a second record
//     for the same key.
//  3. Outcome: close the intent row, only if replay says it is still pending.
//
// The three kill boundaries PhaseIntent, PhaseEffect, PhaseOutcome are the
// windows between those steps, so every crash window of the pair is tested.
//
// kill is the harness's self-kill hook (nil disables it, which is what the
// in-process tests do). It fires only in the process that crossed the step.
func RunEffect(ctx context.Context, m *run.Machine, owner string, token int64,
	effect, key string, log *EffectLog, kill func(phase string)) (bool, error) {
	if _, _, err := m.Intent(ctx, owner, token, key, effect,
		map[string]string{"effect": effect, "key": key}); err != nil {
		return false, fmt.Errorf("killtest: intent %s: %w", key, err)
	}
	if kill != nil {
		kill(PhaseIntent)
	}

	// The intent row is on disk: read the position back, so the outcome closes
	// the row this run recorded, whenever it was recorded.
	st, err := m.State(ctx)
	if err != nil {
		return false, err
	}
	eff, ok := st.EffectByKey(key)
	if !ok {
		return false, fmt.Errorf("%w: killtest: intent row %s is not in the replay",
			journal.ErrReplayInconsistent, key)
	}

	performed, err := log.Perform(key, effect)
	if err != nil {
		return false, err
	}
	if kill != nil {
		kill(PhaseEffect)
	}

	if eff.Pending() {
		outcome := map[string]any{
			"performed": performed,
			"log":       log.Path(),
			"ts":        journal.NowUTC(),
		}
		if _, err := m.Outcome(ctx, owner, token, eff.Seq, effect, outcome); err != nil {
			return false, fmt.Errorf("killtest: outcome %s: %w", key, err)
		}
	}
	if kill != nil {
		kill(PhaseOutcome)
	}
	return performed, nil
}

// Report is what one attempt writes before it exits. A process that is killed
// writes nothing, which is the point: the harness reads a report only from an
// attempt that ran to completion.
type Report struct {
	Owner     string   `json:"owner"`
	Token     int64    `json:"token"`
	State     string   `json:"state"`
	KilledAt  string   `json:"killed_at,omitempty"`
	Performed []string `json:"performed,omitempty"`
	Halts     []string `json:"halts,omitempty"`
	// Resumed lists the resume this attempt performed.
	Resumed []string `json:"resumed,omitempty"`
	// SecondCompleteRefused is the error text of the completion this attempt
	// attempted on a run a previous attempt already completed (AC7: never twice).
	SecondCompleteRefused string `json:"second_complete_refused,omitempty"`
}

// WriteReport renders the report to path and to stdout.
func (r Report) WriteReport(path string) error {
	raw, err := json.Marshal(r)
	if err != nil {
		return fmt.Errorf("killtest: marshal report: %w", err)
	}
	if path != "" {
		if err := os.WriteFile(path, append(raw, '\n'), 0o644); err != nil {
			return fmt.Errorf("killtest: write report: %w", err)
		}
	}
	fmt.Println(string(raw))
	return nil
}

// SleepPastStallLimit goes quiet long enough for the watchdog to be honest.
func SleepPastStallLimit() { time.Sleep(StallSleep) }
