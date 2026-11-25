package chief

import (
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

// notifyRelPath is the phone-channel record of the chief: one line per page
// intent and outcome, so a restart never pages a halt twice and a crash
// between the intent and the page re-pages once (at-least-once — the
// operator phone channel prefers a repeat over a lost page). It lives under
// the git-ignored run-state tree .claude/runs/, next to the journal, and
// enters record-ownership.md as its own row.
const notifyRelPath = ".claude/runs/chief/notified.jsonl"

// notifyRecord is one line of the phone-channel record.
type notifyRecord struct {
	// Kind is "intent" — written before the page — or "outcome", written
	// after it.
	Kind  string `json:"kind"`
	TS    string `json:"ts"`
	RunID string `json:"run_id"`
	// HaltSeq is the seq of the run_halted row the page answers; the key
	// the re-scan dedupes on.
	HaltSeq int64  `json:"halt_seq"`
	Reason  string `json:"reason,omitempty"`
	// Delivered and Error close the intent with what the channel did.
	Delivered bool   `json:"delivered,omitempty"`
	Error     string `json:"error,omitempty"`
}

// notifyKey names one halt: the run and the run_halted row's seq.
type notifyKey struct {
	RunID string
	Seq   int64
}

// suppressedByTakeover is the outcome error that closes the intent row of a
// page the pre-page re-read suppressed (CDT-664): the takeover answered the
// halt between the scan's two reads, so the page never went out.
const suppressedByTakeover = "suppressed: the takeover answered the halt"

func (h HaltReport) key() notifyKey { return notifyKey{RunID: h.RunID, Seq: h.Seq} }

// notifyPath is the phone-channel record path under the record root.
func (c *Chief) notifyPath() (string, error) {
	root, err := c.mroot()
	if err != nil {
		return "", err
	}
	return filepath.Join(root, filepath.FromSlash(notifyRelPath)), nil
}

// deliveredKeys reads the record: only a halt whose page closed with a
// `delivered: true` outcome counts as answered. A pending intent — a page
// that never went out, or one that failed — re-pages on the next scan
// (at-least-once; the channel prefers a repeat over a lost page).
func (c *Chief) deliveredKeys() (map[notifyKey]bool, error) {
	out := map[notifyKey]bool{}
	path, err := c.notifyPath()
	if err != nil {
		return nil, err
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return out, nil
		}
		return nil, fmt.Errorf("chief: read %s: %w", notifyRelPath, err)
	}
	for _, line := range strings.Split(string(raw), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		var rec notifyRecord
		if err := jsonUnmarshal([]byte(line), &rec); err != nil {
			// A torn last line is the crash window the record's design
			// tolerates: one unreadable line never widens into a refusal.
			continue
		}
		if rec.Kind == "outcome" && rec.Delivered {
			out[notifyKey{RunID: rec.RunID, Seq: rec.HaltSeq}] = true
		}
	}
	return out, nil
}

// appendNotify writes one record line. O_APPEND and one write keep
// concurrent scans line-atomic.
func (c *Chief) appendNotify(rec notifyRecord) error {
	path, err := c.notifyPath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("chief: create %s: %w", filepath.Dir(path), err)
	}
	rec.TS = journal.FormatTS(c.now())
	raw, err := json.Marshal(rec)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return fmt.Errorf("chief: open %s: %w", path, err)
	}
	defer f.Close()
	if _, err := f.Write(append(raw, '\n')); err != nil {
		return fmt.Errorf("chief: notify append: %w", err)
	}
	return f.Sync()
}

// takeoverAnswered reports whether the takeover scan answered one halt row
// (SPEC-044 M9/AC9). The scan answers exactly one shape: the watchdog's
// stalled finding on a run whose replayed state has moved past
// `halted:stalled` — the re-spawn landed and the run runs again, so the
// stall is behind it and the phone stays silent.
//
// Every other answer is false, so the page stands: a halt the scan refused
// (the spent stalled budget, a foreign-node runner, a matrix refusal) leaves
// the run in `halted:stalled`, a skipped run has no host to re-spawn, and a
// halt of any other reason is outside the M1 selection set (AC8).
func (c *Chief) takeoverAnswered(ctx context.Context, h HaltReport) (bool, error) {
	if h.Reason != run.ReasonStalled {
		return false, nil
	}
	st, err := c.eng.RunState(ctx, h.RunID)
	if err != nil {
		return false, err
	}
	return st.Name() != stalledState, nil
}

// ScanHalts reports every halt (AC5) and pages the operator through the
// Intercom for each halt whose page has not closed delivered: the reason
// and the remaining retry budget are the page's content. The page is one
// intent row in the record, then the channel call, then one outcome row —
// and a page that failed re-pages on the next scan, so a transiently
// failing channel loses no halt.
//
// The takeover answers a stalled halt (SPEC-044 M9/AC9): a
// `halted:stalled` row whose run the scan has taken over pages nothing —
// the re-spawn is the response. A halt the scan does not answer keeps its
// page: a refusal, a skip, a spent stalled budget, and every halt of
// another reason (AC8) all stay on the record's at-least-once rules.
//
// The scan reads the answer twice: once before the intent row and once before
// the channel call. A re-spawn that lands in that window closes the intent
// with a suppressed outcome and pages nothing (CDT-664).
func (c *Chief) ScanHalts(ctx context.Context) ([]HaltReport, error) {
	c.notifyMu.Lock()
	defer c.notifyMu.Unlock()

	halts, err := c.haltRows(ctx)
	if err != nil {
		return nil, err
	}
	delivered, err := c.deliveredKeys()
	if err != nil {
		return nil, err
	}
	out := make([]HaltReport, 0, len(halts))
	for _, h := range halts {
		if delivered[h.key()] {
			h.Notified = true
			out = append(out, h)
			continue
		}
		answered, err := c.answeredRead(ctx, h)
		if err != nil {
			return nil, err
		}
		if answered {
			// No intent row, no page, no record: the journal is the proof
			// this halt was answered, and the row stays readable.
			out = append(out, h)
			continue
		}
		if err := c.appendNotify(notifyRecord{
			Kind: "intent", RunID: h.RunID, HaltSeq: h.Seq, Reason: h.Reason,
		}); err != nil {
			return nil, err
		}
		// The one-shot page window (CDT-664): a takeover start rides the
		// chief's base context and can land after the read above. One bounded
		// re-read before the page keeps an answered stall off the phone, and
		// the intent row closes with the suppressed outcome so the record
		// shows the page never went out. The next scan's answered read skips
		// the halt — the journal is the proof, as it is for the pass above.
		answered, err = c.answeredRead(ctx, h)
		if err != nil {
			return nil, err
		}
		if answered {
			if err := c.appendNotify(notifyRecord{
				Kind: "outcome", RunID: h.RunID, HaltSeq: h.Seq,
				Error: suppressedByTakeover,
			}); err != nil {
				return nil, err
			}
			out = append(out, h)
			continue
		}
		page := fmt.Sprintf("run %s halted: %s — %s (retry budget %d, %d remaining)",
			h.RunID, h.Reason, orNone(h.Detail), h.Budget, h.Remaining)
		err = c.phone.Page(ctx, h.RunID, page)
		pageErr := ""
		if err != nil {
			pageErr = err.Error()
		}
		if err := c.appendNotify(notifyRecord{
			Kind: "outcome", RunID: h.RunID, HaltSeq: h.Seq,
			Delivered: err == nil, Error: pageErr,
		}); err != nil {
			return nil, err
		}
		h.Notified = err == nil
		out = append(out, h)
	}
	return out, nil
}

// Watch is the chief's background loop: the takeover scan, then the halt
// pages, on one cadence, until ctx ends (SPEC-044 M2/AC2, AC5). It is the
// loop the service runs; the API's Halts report stays a pure read.
//
// The takeover pass runs first on every turn — the first pass lands at
// startup and one follows every interval for the service lifetime — so the
// pages are read after the scan has had its say and a stall the scan answers
// is suppressed by the pass that answered it. A stall whose re-spawn is
// still unproven keeps its page: the page record is at-least-once and the
// channel prefers a repeat over a lost page.
func (c *Chief) Watch(ctx context.Context, interval time.Duration) {
	if interval <= 0 {
		interval = DefaultWatchInterval
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		// A failed pass must not stop the watch: the next tick retries, the
		// journal stays the record, and the record's delivered outcomes keep
		// the page at-least-once. The scan's per-run failures are report
		// lines, never an error that ends the loop.
		_, _ = c.TakeoverScan(ctx)
		_, _ = c.ScanHalts(ctx)
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// DefaultWatchInterval is the watch's cadence — the takeover scan's and the
// halt pages' (SPEC-044 M2). It is the only takeover cadence: no knob exists.
const DefaultWatchInterval = 5 * time.Second

// orNone names an empty detail, so a page never carries a dangling dash.
func orNone(detail string) string {
	if strings.TrimSpace(detail) == "" {
		return "no detail"
	}
	return detail
}
