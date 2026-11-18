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

// ScanHalts reports every halt (AC5) and pages the operator through the
// Intercom for each halt whose page has not closed delivered: the reason
// and the remaining retry budget are the page's content. The page is one
// intent row in the record, then the channel call, then one outcome row —
// and a page that failed re-pages on the next scan, so a transiently
// failing channel loses no halt.
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
		if err := c.appendNotify(notifyRecord{
			Kind: "intent", RunID: h.RunID, HaltSeq: h.Seq, Reason: h.Reason,
		}); err != nil {
			return nil, err
		}
		page := fmt.Sprintf("run %s halted: %s — %s (retry budget %d, %d remaining)",
			h.RunID, h.Reason, orNone(h.Detail), h.Budget, h.Remaining)
		err := c.phone.Page(ctx, h.RunID, page)
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

// Watch pages every new halt as the journal names it (AC5), every interval,
// until ctx ends. It is the background loop the service runs; the API's
// Halts report stays a pure read.
func (c *Chief) Watch(ctx context.Context, interval time.Duration) {
	if interval <= 0 {
		interval = DefaultWatchInterval
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		// A failed pass must not stop the watch: the next tick retries, and
		// the record's delivered outcomes keep the page at-least-once.
		_, _ = c.ScanHalts(ctx)
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// DefaultWatchInterval is the halt watch's cadence.
const DefaultWatchInterval = 5 * time.Second

// orNone names an empty detail, so a page never carries a dangling dash.
func orNone(detail string) string {
	if strings.TrimSpace(detail) == "" {
		return "no detail"
	}
	return detail
}
