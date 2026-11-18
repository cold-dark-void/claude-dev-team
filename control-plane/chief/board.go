package chief

import (
	"context"
	"strings"

	"github.com/cold-dark-void/claude-dev-team/control-plane/agent"
	"github.com/cold-dark-void/claude-dev-team/control-plane/queue"
	"github.com/cold-dark-void/claude-dev-team/control-plane/spool"
)

// spoolPhases is the default phase-event read: the C3 phase-event spool
// (control-plane/spool) — the phase-event contract that names the lifecycle
// vertex a run occupies. The chief reads it; it never writes it: the
// spool's one writer is the run's lease owner (control-plane/run,
// CDT-642 AC4).
type spoolPhases struct{}

// PhaseEvents reads one run's phase events, in spool order.
func (spoolPhases) PhaseEvents(_ context.Context, runID string) ([]spool.Record, error) {
	sp, err := spool.OpenDefault()
	if err != nil {
		return nil, err
	}
	recs, err := sp.Records()
	if err != nil {
		return nil, err
	}
	var out []spool.Record
	for _, r := range recs {
		if r.RunID == runID {
			out = append(out, r)
		}
	}
	return out, nil
}

// currentPhase folds one run's phase events into the phase the board
// reports (AC2): the phase the run's latest phase event names — the
// lifecycle vertex the run occupies on the /orchestrate ladder. The fold
// fails closed: no phase event, no phase — the state field still says
// where the machine is, and a broken spool never breaks the board.
func (c *Chief) currentPhase(ctx context.Context, runID string) string {
	read := c.phaseEvents
	if read == nil {
		read = spoolPhases{}.PhaseEvents
	}
	recs, err := read(ctx, runID)
	if err != nil {
		return ""
	}
	phase := ""
	for _, r := range recs {
		if p := strings.TrimSpace(r.Phase); p != "" {
			phase = p
		}
	}
	return phase
}

// runnerType resolves the node's runner selection through the C4 loader —
// agent.Load, the node config's single reader — so the board names the
// runner every run on this node rides (AC2). A node with no selection runs
// nothing; the board reports an empty runner type, never a guess.
func (c *Chief) runnerType() string {
	c.runnerOnce.Do(func() {
		cfg, err := agent.Load(nil)
		if err != nil {
			return
		}
		c.runner = string(cfg.Runner)
	})
	return c.runner
}

// queuePosition ranks a run's waiting runner in the queue (AC2): the
// 1-based position among the waiting slots, in ledger order. A run whose
// runner holds its slot — or holds none — queues no one: the position is 0.
func queuePosition(slots []queue.Slot, runID string) int {
	pos := 0
	for _, s := range slots {
		if s.State != queue.SlotWaiting {
			continue
		}
		pos++
		if s.RunID == runID {
			return pos
		}
	}
	return 0
}
