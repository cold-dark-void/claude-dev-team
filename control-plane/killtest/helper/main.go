// Command helper is the sacrificial process of the CDT-643 kill test.
//
// It opens the journal named by CDT643_KILLTEST_DB, drives one run through the
// lifecycle script (killtest.Driver), and SIGKILLs itself at the boundary named
// by CDT643_KILLTEST_KILL_AT. The harness kills nothing else and simulates
// nothing: this process dies, with the journal open, the WAL in place, and the
// lease still its own.
//
// It is the same binary for both halves of the test. With no kill boundary it
// is the recovery: the restart on the same journal that must drive the run to
// exactly one completion.
//
// CDT-644 parameterises the lane by runner type: when the node-level
// selection ($DEVTEAM_RUNNER, the agent's own C7 pattern) is set, the helper
// resolves it through the node agent's config loader and refuses an unknown
// runner fail-closed. The native runner is the first built and the default
// once selected; CDT-647 adds the container runner to the closed set. No
// Docker dependency exists anywhere in the lane: it drives the run machine
// directly and spawns no session container.
package main

import (
	"context"
	"fmt"
	"os"
	"strings"

	"github.com/cold-dark-void/claude-dev-team/control-plane/agent"
	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
	"github.com/cold-dark-void/claude-dev-team/control-plane/killtest"
	"github.com/cold-dark-void/claude-dev-team/control-plane/run"
)

func main() {
	if err := mainRun(); err != nil {
		fmt.Fprintln(os.Stderr, "helper:", err)
		os.Exit(1)
	}
}

func mainRun() error {
	dbPath := os.Getenv(killtest.EnvDB)
	if dbPath == "" {
		return fmt.Errorf("%s is required", killtest.EnvDB)
	}
	owner := os.Getenv(killtest.EnvOwner)
	if owner == "" {
		return fmt.Errorf("%s is required", killtest.EnvOwner)
	}
	killAt := os.Getenv(killtest.EnvKillAt)
	if killAt != "" && !killtest.IsPhase(killAt) {
		return fmt.Errorf("%s=%q is not a phase boundary", killtest.EnvKillAt, killAt)
	}
	runID := os.Getenv(killtest.EnvRunID)
	if runID == "" {
		runID = killtest.RunID
	}

	// The lane is a node: when it names a runner, the selection must resolve
	// fail-closed through the node agent's own loader (CDT-644).
	runnerType := ""
	if sel, err := agent.Load(nil); err != nil {
		return err
	} else if sel.Selected() {
		runnerType = string(sel.Runner)
	} else if os.Getenv(agent.EnvRunner) != "" {
		return fmt.Errorf("%w: $%s=%q is not one of %s",
			agent.ErrNoRunnerSelected, agent.EnvRunner, os.Getenv(agent.EnvRunner),
			strings.Join(agent.RunnerTypeList(), ", "))
	}

	ctx := context.Background()
	eng, err := journal.OpenPath(ctx, dbPath)
	if err != nil {
		return fmt.Errorf("open journal: %w", err)
	}
	defer eng.Close()

	m := run.New(eng, runID)
	d := &killtest.Driver{
		Machine:    m,
		Owner:      owner,
		Ticket:     killtest.Ticket,
		Workflow:   killtest.Workflow,
		Model:      killtest.Model,
		Effects:    killtest.NewEffectLog(os.Getenv(killtest.EnvEffects)),
		KillAt:     killAt,
		Kill:       func(phase string) { selfKill(phase) },
		RunnerType: runnerType,
	}

	rep, err := d.Run(ctx)
	if err != nil {
		return err
	}
	return rep.WriteReport(os.Getenv(killtest.EnvReport))
}
