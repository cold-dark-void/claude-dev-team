package chief

import (
	"context"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/cold-dark-void/claude-dev-team/control-plane/agent"
	"github.com/cold-dark-void/claude-dev-team/control-plane/hostadapter"
	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
)

// RunDetail is one board row: the replayed RunStatus plus the fields the run
// detail view renders (SPEC-045 M7, SPEC-046 M9). Every one of them folds from
// the journal — the premise from the run's agent.premise rows, the host from
// the recorded start argv, the attempt from the run id (M2/M6), the resume
// capability from the host matrix's CapResume cell, and the budget caps from
// the run's run_started row. The in-memory run capture is never a source: a
// chiefd restart loses it, and the detail view is what an operator reads after
// that restart.
type RunDetail struct {
	RunStatus
	// Premise is the work premise the run was sent — the newest
	// agent.premise row's text. Empty when the run carries none. For a
	// ticket route it is the composed command (SPEC-046 M9): the command
	// line the run executes.
	Premise string `json:"premise,omitempty"`
	// Host is the matrix host the run's start record names
	// (claude-code / grok / omp). Empty when no start row names a known
	// host command.
	Host string `json:"host,omitempty"`
	// Attempt is the attempt number the run id names (M2): 1 for a plain
	// ticket slug, N for "<ticket>-r<N>".
	Attempt int `json:"attempt,omitempty"`
	// ResumeSupported is the matrix's CapResume cell for the run's host —
	// the one copy of the verdict (SPEC-045 AC2/AC7). The UI hides the
	// Resume button when it is false.
	ResumeSupported bool `json:"resume_supported"`
	// WallclockCapS and IterationCapS are the budget caps in effect
	// (SPEC-046 M9): the operator's per-run caps the run's run_started row
	// journals, in seconds and stints. 0 means unset — the run keeps the
	// plugin's own budget — and renders absent, the shape every unset state
	// field takes.
	WallclockCapS int64 `json:"wallclock_cap_s,omitempty"`
	IterationCapS int64 `json:"iteration_cap_s,omitempty"`
}

// Details reports every run with its detail fields (SPEC-045 AC3): the board
// rows the run detail view and the ticket grouping read.
func (c *Chief) Details(ctx context.Context) ([]RunDetail, error) {
	runs, err := c.Runs(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]RunDetail, 0, len(runs))
	for _, rs := range runs {
		out = append(out, c.detailOf(ctx, rs))
	}
	return out, nil
}

// Detail reports one run with its detail fields (SPEC-045 AC3).
func (c *Chief) Detail(ctx context.Context, runID string) (RunDetail, error) {
	rs, err := c.Run(ctx, runID)
	if err != nil {
		return RunDetail{}, err
	}
	return c.detailOf(ctx, rs), nil
}

// detailOf folds the detail fields onto one replayed status. A run with no
// readable rows keeps its status row and gains empty detail fields: the
// detail view never fails because one fold came up empty.
func (c *Chief) detailOf(ctx context.Context, rs RunStatus) RunDetail {
	d := RunDetail{RunStatus: rs, Attempt: attemptFromRunID(rs.RunID)}
	events, err := c.eng.Events(ctx, rs.RunID)
	if err != nil {
		return d
	}
	host, premise := detailFold(events)
	d.Premise = premise
	d.Host = string(host)
	d.WallclockCapS, d.IterationCapS = capsFromJournal(events)
	if host != "" {
		d.ResumeSupported = hostadapter.ResumeRoute(host)
	}
	return d
}

// detailFold folds a run's journal rows into the host its start record names
// and the premise its newest agent.premise row carries. The newest row wins
// on both: a taken-over run carries one start row per attempt, and a resumed
// attempt's premise supersedes its predecessor.
func detailFold(events []journal.Event) (hostadapter.Host, string) {
	var (
		host    hostadapter.Host
		premise string
	)
	for _, ev := range events {
		if ev.Kind != journal.KindSideEffect {
			continue
		}
		var ef journal.Effect
		if err := jsonUnmarshal(ev.Payload, &ef); err != nil {
			continue
		}
		switch ef.Effect {
		case agent.EffectStart:
			// The spawn intent carries the command; the host fold is the
			// same one a correction rides (chief.hostFromJournal).
			if ef.IntentSeq != 0 {
				continue
			}
			var intent struct {
				Command string `json:"command"`
			}
			if jsonUnmarshal(ef.Intent, &intent) != nil {
				continue
			}
			if h, ok := hostByCommand(filepath.Base(intent.Command)); ok {
				host = h
			}
		case agent.EffectPremise:
			// The outcome payload first, the intent payload after: a pending
			// intent is the crash window the recovery performs (takeover.go).
			raw := ef.Outcome
			if len(raw) == 0 {
				raw = ef.Intent
			}
			var payload struct {
				Premise string `json:"premise"`
			}
			if jsonUnmarshal(raw, &payload) == nil && payload.Premise != "" {
				premise = payload.Premise
			}
		}
	}
	return host, premise
}

// capsFromJournal reads the budget caps the newest run_started row journals
// (SPEC-046 M7/M9). The newest row wins, as in detailFold: a taken-over run
// carries one start row per attempt and each re-spawn journals the caps it
// re-injected. An absent payload, an undecodable row, and an unset cap all
// answer 0 — the run keeps the plugin's own budget (SPEC-033 N14).
func capsFromJournal(events []journal.Event) (wallclockCapS, iterationCapS int64) {
	for _, ev := range events {
		if ev.Kind != journal.KindRunStarted {
			continue
		}
		var p journal.StartPayload
		if jsonUnmarshal(ev.Payload, &p) != nil {
			continue
		}
		wallclockCapS, iterationCapS = p.WallclockCapS, p.IterationCapS
	}
	return wallclockCapS, iterationCapS
}

// attemptSuffix is the attempt marker of the M2 run-id allocation: a ticket's
// further runs are "<slug>-r<N>".
const attemptSuffix = "-r"

// attemptFromTail reads the attempt number one attempt suffix's tail names:
// the canonical digits the run-id allocator writes (`%s-r%d`). 0 is a tail
// that names no attempt above the first. The attempt ladder (chief.attemptOf)
// and the detail view read the grammar through here — one copy of the rule.
func attemptFromTail(tail string) int {
	n, err := strconv.Atoi(tail)
	if err != nil || n < 2 || strconv.Itoa(n) != tail {
		return 0
	}
	return n
}

// attemptFromRunID reads the attempt number the run id names (SPEC-045 M2/M6):
// 1 for a plain slug, N for "<slug>-r<N>". An id with no attempt marker — or
// a marker that names no attempt above 1 — is the ticket's first run.
func attemptFromRunID(runID string) int {
	i := strings.LastIndex(runID, attemptSuffix)
	if i < 0 {
		return 1
	}
	if n := attemptFromTail(runID[i+len(attemptSuffix):]); n > 0 {
		return n
	}
	return 1
}
