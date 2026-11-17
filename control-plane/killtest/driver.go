package killtest

import (
	"context"
	"fmt"

	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
	"github.com/cold-dark-void/claude-dev-team/control-plane/run"
)

// Driver runs the lifecycle script once against a machine.
//
// It is the same script for the first attempt and for the attempt after a kill,
// and that is the whole point: the machine holds no state, so Driver derives
// its position from the journal replay (Machine.State) and performs only what
// the journal has not got yet. A restarted process that needs a script of its
// own is a process that lost the run.
type Driver struct {
	Machine  *run.Machine
	Owner    string
	Ticket   string
	Workflow string
	Model    string
	Effects  *EffectLog

	// KillAt names the phase boundary this attempt must die at. Empty means
	// this attempt runs to completion.
	KillAt string
	// Kill performs the death of this process. It never returns. Nil disables
	// the kill, which is what the in-process tests use.
	Kill func(phase string)
}

// Run drives the run to completion and returns the attempt report.
func (d *Driver) Run(ctx context.Context) (Report, error) {
	rep := Report{Owner: d.Owner, KilledAt: d.KillAt}
	if d.Machine == nil || d.Effects == nil {
		return rep, fmt.Errorf("%w: killtest: Driver needs a Machine and an EffectLog",
			journal.ErrInvalid)
	}

	st, err := d.position(ctx)
	if err != nil {
		return rep, err
	}

	// A run a previous process finished is finished. The recovery reads it from
	// replay, attempts the completion anyway, and must be refused: AC7 says the
	// run completes exactly once, so the second completion is the test.
	if st.IsTerminal() {
		rep.State = st.Name()
		err := d.Machine.Complete(ctx, st.Owner, st.Token, d.result(), nil)
		if err == nil {
			return rep, fmt.Errorf("killtest: second Complete on a %s run was accepted", st.Name())
		}
		rep.SecondCompleteRefused = err.Error()
		return rep, nil
	}

	token, err := d.Machine.Claim(ctx, d.Owner, d.Ticket, d.Workflow, d.Model)
	if err != nil {
		return rep, fmt.Errorf("killtest: claim: %w", err)
	}
	rep.Token = token
	d.killHook(PhaseClaimed)

	// Every step below asks the journal where the run is, so the position is the
	// one this process just wrote, not the one it opened with.
	st, err = d.position(ctx)
	if err != nil {
		return rep, err
	}
	if st.Status == journal.StatusClaimed {
		if err := d.Machine.Start(ctx, d.Owner, token, d.Model); err != nil {
			return rep, fmt.Errorf("killtest: start: %w", err)
		}
		d.killHook(PhaseRunning)
	}

	st, err = d.position(ctx)
	if err != nil {
		return rep, err
	}
	if st.Status == journal.StatusRunning && st.Stint < 1 {
		if err := d.Machine.Stint(ctx, d.Owner, token, "stint 1"); err != nil {
			return rep, fmt.Errorf("killtest: stint: %w", err)
		}
		d.killHook(PhaseStint)
	}
	if st.Status == journal.StatusRunning {
		if err := d.Machine.Heartbeat(ctx, d.Owner, token); err != nil {
			return rep, fmt.Errorf("killtest: heartbeat: %w", err)
		}
		d.killHook(PhaseHeartbeat)
	}

	performed, err := RunEffect(ctx, d.Machine, d.Owner, token, EffectA, KeyA, d.Effects, d.killHook)
	if err != nil {
		return rep, err
	}
	if performed {
		rep.Performed = append(rep.Performed, KeyA)
	}

	// Go quiet, and let the watchdog name the halt state for real (AC6). The
	// restart of a killed run is quiet by construction, so a recovery attempt
	// passes through halted:stalled and out the other side.
	st, err = d.position(ctx)
	if err != nil {
		return rep, err
	}
	if st.Status == journal.StatusRunning {
		SleepPastStallLimit()
		halted, err := d.Machine.Watchdog(ctx, d.Owner, token)
		if err != nil {
			return rep, fmt.Errorf("killtest: watchdog: %w", err)
		}
		if halted {
			rep.Halts = append(rep.Halts, run.ReasonStalled)
			d.killHook(PhaseHalted)
		}
	}

	st, err = d.position(ctx)
	if err != nil {
		return rep, err
	}
	if st.Status == journal.StatusHalted {
		if err := d.Machine.Resume(ctx, d.Owner, token); err != nil {
			return rep, fmt.Errorf("killtest: resume: %w", err)
		}
		rep.Resumed = append(rep.Resumed, PhaseResumed)
		d.killHook(PhaseResumed)
	}

	performed, err = RunEffect(ctx, d.Machine, d.Owner, token, EffectB, KeyB, d.Effects, d.killHook)
	if err != nil {
		return rep, err
	}
	if performed {
		rep.Performed = append(rep.Performed, KeyB)
	}

	if err := d.Machine.Complete(ctx, d.Owner, token, d.result(), nil); err != nil {
		return rep, fmt.Errorf("killtest: complete: %w", err)
	}
	d.killHook(PhaseCompleted)

	st, err = d.position(ctx)
	if err != nil {
		return rep, err
	}
	rep.State = st.Name()
	return rep, nil
}

// position is the run's position, read from the journal and nowhere else. The
// driver asks for it before every step, which is what lets the first attempt and
// the attempt after a kill run the same script.
func (d *Driver) position(ctx context.Context) (*journal.State, error) {
	return d.Machine.State(ctx)
}

// result is the completion payload.
func (d *Driver) result() map[string]string {
	return map[string]string{"owner": d.Owner, "ticket": d.Ticket, "workflow": d.Workflow}
}

// killHook is the nil-safe view of the kill hook. It fires only in the process
// that crossed the boundary (killAt is this attempt's own death point), and only
// for the boundary it was given. d.Kill never returns.
func (d *Driver) killHook(phase string) {
	if d.Kill == nil || phase != d.KillAt {
		return
	}
	d.Kill(phase)
}
