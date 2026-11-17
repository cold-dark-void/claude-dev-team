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
package main

import (
	"context"
	"fmt"
	"os"

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

	ctx := context.Background()
	eng, err := journal.OpenPath(ctx, dbPath)
	if err != nil {
		return fmt.Errorf("open journal: %w", err)
	}
	defer eng.Close()

	m := run.New(eng, runID)
	d := &killtest.Driver{
		Machine:  m,
		Owner:    owner,
		Ticket:   killtest.Ticket,
		Workflow: killtest.Workflow,
		Model:    killtest.Model,
		Effects:  killtest.NewEffectLog(os.Getenv(killtest.EnvEffects)),
		KillAt:   killAt,
		Kill:     func(phase string) { selfKill(phase) },
	}

	rep, err := d.Run(ctx)
	if err != nil {
		return err
	}
	return rep.WriteReport(os.Getenv(killtest.EnvReport))
}
