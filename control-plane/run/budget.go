package run

import (
	"fmt"
	"os"
	"strconv"
	"time"
)

// EnvStallLimit overrides the watchdog stall limit, in seconds. It is the top of
// the run-budget precedence chain (env > map > tier), which
// docs/internal/control-plane/run-budget.md § Precedence owns.
const EnvStallLimit = "DEVTEAM_STALL_LIMIT"

// EnvNoProgressLimit overrides the no-progress bound, in seconds: the quiet
// window past which the checks reading flags a running run's session as making
// no progress (SPEC-044 CDT-671 AC3). It is the top of this knob's chain, the
// same shape EnvStallLimit has for the watchdog.
const EnvNoProgressLimit = "DEVTEAM_NO_PROGRESS_LIMIT"

// DefaultNoProgressLimit is the bound a run journals when the env layer names
// none: ten minutes with nothing on the host's output stream. It sits above
// every stall limit in the run-budget map (the widest is opus at 270 s), so the
// flag reads a session that stopped, not one mid-stint. The flag halts nothing
// and spends no retry budget, so this number is not a halt trigger and CDT-610's
// hold on wall-clock tuning does not reach it — the heartbeat stall limit stays
// the only halt trigger for a silent session.
const DefaultNoProgressLimit = 10 * time.Minute

// ResolveNoProgressLimit returns the bound and the layer it came from
// ("env" | "default"). The chain is env over a default, so the number is
// journaled per run and no reading surface carries a constant of its own
// (SPEC-044 CDT-671 AC3).
func ResolveNoProgressLimit(getenv func(string) string) (time.Duration, string, error) {
	if getenv == nil {
		getenv = os.Getenv
	}
	if raw := getenv(EnvNoProgressLimit); raw != "" {
		secs, err := strconv.Atoi(raw)
		if err != nil || secs <= 0 {
			return 0, "", fmt.Errorf("%w: %s=%q is not a positive integer number of seconds",
				ErrConfig, EnvNoProgressLimit, raw)
		}
		return time.Duration(secs) * time.Second, "env", nil
	}
	return DefaultNoProgressLimit, "default", nil
}

// NoProgressSeconds is the journaled form of ResolveNoProgressLimit (whole
// seconds, as journal.StartPayload carries it).
func NoProgressSeconds(getenv func(string) string) (int64, string, error) {
	d, source, err := ResolveNoProgressLimit(getenv)
	if err != nil {
		return 0, "", err
	}
	return int64(d / time.Second), source, nil
}

// BudgetRow is one row of the run-budget map: the two SPEC-033 caps a model
// tier is proposed to run under.
//
// CDT-610 is the precondition of tuning any wall-clock number.
// docs/internal/control-plane/run-budget.md § "Open BC6 item" states it in
// those words ("Do not tune a per-model wall-clock before CDT-610 lands and is
// measured"), and CDT-643 AC9 repeats it for phase 1. Every cell below is a
// verbatim SPEC-033 cell — § AC3 M9 static defaults and § AC9 M9b tier rows —
// and nothing below is tuned.
type BudgetRow struct {
	// Model is the resolved model token (SPEC-037 M12 tier tokens).
	Model string
	// IterationCap and WallClockCapS are the SPEC-033 cells, in stints and seconds.
	IterationCap  int
	WallClockCapS int
	// Source names the SPEC-033 row this cell is copied from.
	Source string
}

// RunBudgetMap is the per-model proposal table of
// docs/internal/control-plane/run-budget.md § "Per-model proposal table".
// Phase 1 reads it for one thing: the stall limit.
var RunBudgetMap = []BudgetRow{
	{Model: "opus", IterationCap: 10, WallClockCapS: 2700,
		Source: "SPEC-033 § AC9 M9b S row (iteration), § AC3 M9 (wall-clock)"},
	{Model: "sonnet", IterationCap: 25, WallClockCapS: 2700,
		Source: "SPEC-033 § AC3 M9 static defaults = § AC9 M9b M row"},
}

// TierDefault is the fallback row: the run-budget map Tier default
// (SPEC-033 § AC3 M9 static defaults). An empty resolution, a missing map file,
// and a model string outside the three tier tokens all land here
// (run-budget.md § Precedence, "Fallback rule").
var TierDefault = BudgetRow{
	Model: "tier-default", IterationCap: 25, WallClockCapS: 2700,
	Source: "SPEC-033 § AC3 M9 static defaults (Tier default row)",
}

// StallLimit is the watchdog's mean-stint limit for this row: the model's
// wall-clock cap divided by its iteration cap. That is the whole scaling rule —
// a model that runs few, deep stints (opus) gets a longer stall limit than one
// that runs many shallow stints (sonnet) — and it introduces no new number, so
// AC9's "no wall-clock number is tuned" holds.
func (b BudgetRow) StallLimit() time.Duration {
	if b.IterationCap <= 0 {
		return 0
	}
	return time.Duration(b.WallClockCapS/b.IterationCap) * time.Second
}

func (b BudgetRow) lookup(model string) bool { return b.Model == model }

// mapRow returns the map row for a resolved model string, and whether the model
// is in the map at all. Anything that is not an exact map key takes the Tier
// default (run-budget.md § Precedence, "Fallback rule").
func mapRow(model string) (BudgetRow, bool) {
	for _, r := range RunBudgetMap {
		if r.lookup(model) {
			return r, true
		}
	}
	return TierDefault, false
}

// ResolveStallLimit returns the stall limit and the layer it came from
// ("env" | "map" | "tier"), per AC6. precedence is env > map > tier, per cap,
// per run-budget.md § Precedence.
//
// getenv is injected so a test can prove the chain; pass os.Getenv in service.
func ResolveStallLimit(model string, getenv func(string) string) (time.Duration, string, error) {
	if getenv == nil {
		getenv = os.Getenv
	}
	if raw := getenv(EnvStallLimit); raw != "" {
		secs, err := strconv.Atoi(raw)
		if err != nil || secs <= 0 {
			return 0, "", fmt.Errorf("%w: %s=%q is not a positive integer number of seconds",
				ErrConfig, EnvStallLimit, raw)
		}
		return time.Duration(secs) * time.Second, "env", nil
	}
	row, inMap := mapRow(model)
	if inMap {
		return row.StallLimit(), "map", nil
	}
	return row.StallLimit(), "tier", nil
}

// StallLimitSeconds is the journaled form of ResolveStallLimit (whole seconds,
// as journal.StartPayload carries it).
func StallLimitSeconds(model string, getenv func(string) string) (int64, string, error) {
	d, source, err := ResolveStallLimit(model, getenv)
	if err != nil {
		return 0, "", err
	}
	return int64(d / time.Second), source, nil
}

// RetryBudgets is the per-reason retry budget of each named halt state (AC6).
// It is run policy, not a wall-clock number, so AC9 does not touch it.
//
// stalled            the owner proved it is alive again within the limit, twice
// lease_lost         one re-acquire is allowed before the run is failed
// reconcile_failed   the reconciler gets three passes (AC5 loop, wave 2 owns it)
// budget_exhausted   no budget: the budget is the thing that ran out
// operator_halt      no budget: only an operator resumes that run
// handshake_failed   one re-spawn per operator resume (CDT-679): the host may
//
//	answer the next handshake; the agent never loops on it
//
// premise_undelivered one re-spawn per operator resume (CDT-671): the premise
//
//	travels with the spawn, so the next start can deliver it; the scan never
//	re-spawns a silent host on its own
var RetryBudgets = map[string]int{
	"stalled":             2,
	"lease_lost":          1,
	"reconcile_failed":    3,
	"budget_exhausted":    0,
	"operator_halt":       0,
	"handshake_failed":    1,
	"premise_undelivered": 1,
}

// RetryBudget returns the budget for a named halt reason.
func RetryBudget(reason string) (int, error) {
	b, ok := RetryBudgets[reason]
	if !ok {
		return 0, fmt.Errorf("%w: no retry budget for halt reason %q", ErrConfig, reason)
	}
	return b, nil
}
