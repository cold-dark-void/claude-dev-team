// Command helper is the supervising process of the CDT-660 restart kill test:
// the chiefd-class process the harness kills, and the chiefd that restarts.
//
// It is a real process, so the crash the test measures is a real one: the
// harness SIGKILLs this binary, with the journal open, the WAL in place, and
// the lease its own — the shape SPEC-044 P1 names (a run left `running` with a
// stale lease and no halt row).
//
// CDT660_RESTART_MODE=supervise starts one run through the host adapter's
// Start — the one spawn path SPEC-044 M3 names — so a real runner child is
// alive under a real supervisor, heartbeating its lease. It signals readiness
// once the journal carries the run running with its spawn outcome and its
// stint, then lives until the harness kills it.
//
// CDT660_RESTART_MODE=restart is the restarted chiefd: it opens the same
// journal and runs chief.TakeoverScan — the takeover's one entry point — then
// stays alive so the run it took over runs to its end on the chief's base
// context, and reports the state it finished in.
//
// Neither mode owns a spawn path: both reach the runner only through
// hostadapter.Adapter.Start → the node agent's Supervise (SPEC-044 M3). The
// journal is located at $DEVTEAM_RUN_DB and the state root at $DEVTEAM_MROOT,
// both pointed at the harness's t.TempDir().
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/cold-dark-void/claude-dev-team/control-plane/agent"
	"github.com/cold-dark-void/claude-dev-team/control-plane/chief"
	"github.com/cold-dark-void/claude-dev-team/control-plane/hostadapter"
	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
	"github.com/cold-dark-void/claude-dev-team/control-plane/killtest"
	"github.com/cold-dark-void/claude-dev-team/control-plane/run"
)

func main() {
	if err := mainRun(); err != nil {
		fmt.Fprintln(os.Stderr, "restart-helper:", err)
		os.Exit(1)
	}
}

func mainRun() error {
	runID := os.Getenv(killtest.EnvRestartRunID)
	if runID == "" {
		runID = killtest.RestartRunID
	}
	ctx := context.Background()
	eng, err := journal.Open(ctx)
	if err != nil {
		return fmt.Errorf("open journal: %w", err)
	}
	defer eng.Close()

	a, err := agent.New()
	if err != nil {
		return err
	}

	switch mode := os.Getenv(killtest.EnvRestartMode); mode {
	case killtest.ModeSupervise:
		return superviseRun(ctx, eng, a, runID)
	case killtest.ModeRestart:
		return restartChief(ctx, eng, a, runID)
	default:
		return fmt.Errorf("%s=%q is not %q or %q", killtest.EnvRestartMode, mode,
			killtest.ModeSupervise, killtest.ModeRestart)
	}
}

// superviseRun is the pre-crash half: the run starts on the adapter's Start,
// the same call chief.startRun makes, and this process holds the supervision
// until the harness kills it.
func superviseRun(ctx context.Context, eng *journal.Engine, a *agent.Agent,
	runID string) error {
	ad := hostadapter.New(a)
	errc := make(chan error, 1)
	go func() {
		_, err := ad.Start(ctx, eng, hostadapter.StartRequest{
			RunID: runID, Ticket: killtest.RestartTicket,
			Workflow: killtest.RestartWorkflow, Model: killtest.RestartModel,
			Host: killtest.RestartHost,
		})
		errc <- err
	}()

	m := run.New(eng, runID)
	if err := waitMidRun(ctx, m, errc); err != nil {
		return err
	}

	pid := os.Getpid()
	if path := os.Getenv(killtest.EnvRestartReady); path != "" {
		raw := []byte(strconv.Itoa(pid) + "\n")
		if err := os.WriteFile(path, raw, 0o644); err != nil {
			return fmt.Errorf("write ready file: %w", err)
		}
	}
	fmt.Printf("restart-helper: supervising %s as pid %d, waiting for SIGKILL\n", runID, pid)

	select {
	case err := <-errc:
		// The runner exited on its own: the harness killed nothing mid-run, so
		// the case it is driving did not happen.
		return fmt.Errorf("the run ended before the harness killed the supervisor: %v", err)
	case <-time.After(killtest.RestartSupervisorLife):
		return fmt.Errorf("the supervisor lived out %s without being killed",
			killtest.RestartSupervisorLife)
	}
}

// waitMidRun blocks until the journal proves the run is mid-flight: running,
// with the spawn outcome recorded (so a runner process exists), its first
// stint journaled, and the captured session id journaled (SPEC-044 CDT-661
// AC5 — the harness kills only after the closed agent.session row, so the
// takeover's resume rides an id the journal named before the crash). That is
// the point the harness kills at.
func waitMidRun(ctx context.Context, m *run.Machine, errc <-chan error) error {
	deadline := time.Now().Add(killtest.RestartReadyWait)
	for {
		st, err := m.State(ctx)
		if err != nil {
			return fmt.Errorf("state: %w", err)
		}
		if st.Status == journal.StatusRunning && st.Stint >= 1 {
			if e, ok := st.EffectByKey(killtest.RestartStartKey(1)); ok && !e.Pending() {
				if se, ok := st.EffectByKey(killtest.RestartSessionKey(1)); ok && !se.Pending() {
					return nil
				}
			}
		}
		select {
		case err := <-errc:
			return fmt.Errorf("the start verb refused the run: %v", err)
		default:
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("the run reached no mid-run position within %s (state %s)",
				killtest.RestartReadyWait, st.Name())
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// restartChief is the post-crash half: one takeover pass, then the wait for
// the taken-over run to finish under the chief's base context. The process has
// to stay alive — it is the supervisor the run now rides, so a runner exit is
// observed and journaled.
func restartChief(ctx context.Context, eng *journal.Engine, a *agent.Agent,
	runID string) error {
	ch := chief.New(eng, a, chief.WithBaseContext(ctx))
	rep, err := ch.TakeoverScan(ctx)
	if err != nil {
		return fmt.Errorf("takeover scan: %w", err)
	}

	m := run.New(eng, runID)
	out := restartReport{RunID: runID, Taken: rep.Taken, Skipped: rep.Skipped,
		Refused: rep.Refused, Unconfirmed: rep.Unconfirmed}
	st, werr := waitTerminal(ctx, m)
	if st != nil {
		out.State = st.Name()
	}
	if werr == nil {
		werr = out.writeTo(os.Getenv(killtest.EnvRestartReport))
	}
	return werr
}

// waitTerminal blocks until the run reaches a terminal state. The takeover's
// re-spawn is supervised by this process, so its exit closes the run.
func waitTerminal(ctx context.Context, m *run.Machine) (*journal.State, error) {
	deadline := time.Now().Add(killtest.RestartFinishWait)
	var st *journal.State
	for {
		got, err := m.State(ctx)
		if err != nil {
			return st, fmt.Errorf("state: %w", err)
		}
		st = got
		if st.IsTerminal() {
			return st, nil
		}
		if time.Now().After(deadline) {
			return st, fmt.Errorf("run %s reached no terminal state within %s (state %s)",
				m.RunID(), killtest.RestartFinishWait, st.Name())
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// restartReport is what the restarted chiefd answers with. The journal is the
// record; this is how the harness learns the scan's own report and the state
// the run finished in.
type restartReport struct {
	RunID   string              `json:"run_id"`
	State   string              `json:"state"`
	Taken   []chief.TakeoverRun `json:"taken,omitempty"`
	Skipped []chief.TakeoverRun `json:"skipped,omitempty"`
	Refused []chief.TakeoverRun `json:"refused,omitempty"`
	// Unconfirmed is the honest bucket: a start whose proof never landed.
	Unconfirmed []chief.TakeoverRun `json:"unconfirmed,omitempty"`
}

// writeTo writes the report to path and echoes it to stdout. An empty path
// echoes only.
func (r restartReport) writeTo(path string) error {
	raw, err := json.Marshal(r)
	if err != nil {
		return fmt.Errorf("marshal report: %w", err)
	}
	if path != "" {
		if err := os.WriteFile(path, append(raw, '\n'), 0o644); err != nil {
			return fmt.Errorf("write report: %w", err)
		}
	}
	fmt.Println(string(raw))
	return nil
}
