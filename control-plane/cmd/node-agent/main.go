// Command node-agent is the node agent of control plane Option C+ (CDT-626;
// CDT-644): one binary, four verbs — start, stop, status, steer. The control
// plane talks only to this agent. The agent is the only holder of the Docker
// socket, and only through the container runner of CDT-647: it execs the
// Docker CLI and never hands the socket to a session container.
//
// Every state-changing verb writes its journal intent before it acts and its
// outcome after (the SPEC-040 AC11 intent-then-outcome pattern). The run
// state, the lease, and the heartbeats are the C2 machine's
// (control-plane/run), reused, never forked.
//
// Inputs come from argv and the environment only. The runner selection is
// per-node: $DEVTEAM_RUNNER, else the runner key of
// $MROOT/.claude/dev-team/node.json. A node with no selection starts no run.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/cold-dark-void/claude-dev-team/control-plane/agent"
	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
)

// Exit codes. 64 is EX_USAGE, the code ADR 0001 fixes for a usage error.
const (
	exitOK      = 0
	exitFailure = 1
	exitUsage   = 64
)

const usage = `node-agent — the node agent of the control plane: start, stop, status, steer.

Usage:
  node-agent start  --run-id ID [--ticket T] [--workflow W] [--model M]
                    [--command CMD [--arg A]...] [--grace DUR] [--db PATH]
  node-agent stop   --run-id ID [--grace DUR] [--db PATH]
  node-agent status --run-id ID [--db PATH]
  node-agent steer  --run-id ID --message TEXT [--db PATH]
  node-agent status-node

Verbs:
  start        Drives one run: claims or takes over the lease, journals the
               spawn intent, spawns the host CLI of the selected runner,
               records the PID, and supervises — heartbeats inside the
               journaled stall limit, steers delivered at step boundaries,
               a clean exit completed, a failing exit failed. Runs in the
               foreground; the machine supervisor (the systemd user unit,
               docs/internal/control-plane/native-runner.md) owns its
               lifetime.
  stop         Stops a run: intent row, then SIGTERM, then SIGKILL after the
               grace, then the outcome row and the named halt
               halted:operator_halt.
  status       Prints one status reading as JSON on stdout. On a running run
               the reading is itself journaled (intent, then outcome).
  steer        Records a control message for the run and hands it to the
               supervising agent, which delivers it to the runner process at
               its next step boundary.
  status-node  Prints the node's runner selection as JSON on stdout and
               exits. A node with no selection starts no run.

Runner selection (fail-closed):
  1. the runner key of $MROOT/.claude/dev-team/node.json
  2. $DEVTEAM_RUNNER — the per-invocation override
  3. no selection: start refuses, no run begins
The closed set is native and container (CDT-647); native is the first built
and the default once selected. A container node needs the Docker CLI on the
agent's PATH and a host CLI whose container probe facts exist
(docs/internal/control-plane/container-runner.md); the session container
never sees the Docker socket.

Exit codes:
  0   success
  1   verb failure (no runner selected, no live process, journal refusal)
  64  usage error (unknown verb, missing --run-id, a negative --grace)

This binary is the whole interface: the control plane calls it with argv and
environment and reads its stdout.
`

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

// run is the CLI. args is argv[1:]; nothing is read from stdin, so the code
// path has one input channel. stdout carries the JSON a caller parses; stderr
// carries the error a caller logs.
func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprint(stderr, usage)
		return exitUsage
	}
	verb, rest := args[0], args[1:]
	switch verb {
	case "start":
		return startCmd(rest, stdout, stderr)
	case "stop":
		return stopCmd(rest, stdout, stderr)
	case "status":
		return statusCmd(rest, stdout, stderr)
	case "steer":
		return steerCmd(rest, stdout, stderr)
	case "status-node":
		return statusNodeCmd(stdout, stderr)
	case "-h", "--help", "help":
		fmt.Fprint(stdout, usage)
		return exitOK
	default:
		fmt.Fprintf(stderr, "node-agent: unknown verb %q\n", verb)
		fmt.Fprint(stderr, usage)
		return exitUsage
	}
}

// startCmd implements `node-agent start`.
func startCmd(args []string, stdout, stderr io.Writer) int {
	fs := newFlagSet("start", stderr)
	var (
		runID    = fs.String("run-id", "", "run id (required)")
		ticket   = fs.String("ticket", "", "ticket the run works")
		workflow = fs.String("workflow", "", "workflow of the run")
		model    = fs.String("model", "", "model tier of the run (the budget map's fallback is the tier default)")
		command  = fs.String("command", "", "host CLI to spawn; overrides the node config")
		grace    = fs.Duration("grace", agent.DefaultGrace, "stop grace of the agent's own signal path")
		db       = fs.String("db", "", "journal file (default $DEVTEAM_RUN_DB)")
	)
	var ags multiFlag
	fs.Var(&ags, "arg", "argv entry of the host CLI (repeatable)")
	if !parseFlags(fs, args, stderr) {
		return exitUsage
	}
	if *runID == "" {
		fmt.Fprintln(stderr, "node-agent start: --run-id is required")
		return exitUsage
	}
	if *grace < 0 {
		fmt.Fprintln(stderr, "node-agent start: --grace is negative")
		return exitUsage
	}

	a, err := agent.New()
	if err != nil {
		fmt.Fprintf(stderr, "node-agent start: %v\n", err)
		return exitFailure
	}
	if a.Runner == nil {
		fmt.Fprintf(stderr, "node-agent start: %v (set $%s or the runner key of the node config)\n",
			agent.ErrNoRunnerSelected, agent.EnvRunner)
		return exitFailure
	}

	eng, err := open(*db)
	if err != nil {
		fmt.Fprintf(stderr, "node-agent start: %v\n", err)
		return exitFailure
	}
	defer func() { _ = eng.Close() }()

	err = a.Supervise(context.Background(), eng, agent.StartRequest{
		RunID: *runID, Ticket: *ticket, Workflow: *workflow, Model: *model,
		Command: *command, Args: ags,
	})
	if err != nil {
		fmt.Fprintf(stderr, "node-agent start: %v\n", err)
		return exitFailure
	}
	fmt.Fprintln(stdout, "ok")
	return exitOK
}

// stopCmd implements `node-agent stop`.
func stopCmd(args []string, stdout, stderr io.Writer) int {
	fs := newFlagSet("stop", stderr)
	var (
		runID = fs.String("run-id", "", "run id (required)")
		grace = fs.Duration("grace", agent.DefaultGrace, "SIGTERM grace before SIGKILL")
		db    = fs.String("db", "", "journal file (default $DEVTEAM_RUN_DB)")
	)
	if !parseFlags(fs, args, stderr) {
		return exitUsage
	}
	if *runID == "" {
		fmt.Fprintln(stderr, "node-agent stop: --run-id is required")
		return exitUsage
	}

	a, err := agent.New()
	if err != nil {
		fmt.Fprintf(stderr, "node-agent stop: %v\n", err)
		return exitFailure
	}
	eng, err := open(*db)
	if err != nil {
		fmt.Fprintf(stderr, "node-agent stop: %v\n", err)
		return exitFailure
	}
	defer func() { _ = eng.Close() }()

	if err := a.Stop(context.Background(), eng, *runID, *grace); err != nil {
		fmt.Fprintf(stderr, "node-agent stop: %v\n", err)
		return exitFailure
	}
	fmt.Fprintln(stdout, "ok")
	return exitOK
}

// statusCmd implements `node-agent status`.
func statusCmd(args []string, stdout, stderr io.Writer) int {
	fs := newFlagSet("status", stderr)
	var (
		runID = fs.String("run-id", "", "run id (required)")
		db    = fs.String("db", "", "journal file (default $DEVTEAM_RUN_DB)")
	)
	if !parseFlags(fs, args, stderr) {
		return exitUsage
	}
	if *runID == "" {
		fmt.Fprintln(stderr, "node-agent status: --run-id is required")
		return exitUsage
	}

	a, err := agent.New()
	if err != nil {
		fmt.Fprintf(stderr, "node-agent status: %v\n", err)
		return exitFailure
	}
	eng, err := open(*db)
	if err != nil {
		fmt.Fprintf(stderr, "node-agent status: %v\n", err)
		return exitFailure
	}
	defer func() { _ = eng.Close() }()

	rep, err := a.Status(context.Background(), eng, *runID)
	if err != nil {
		fmt.Fprintf(stderr, "node-agent status: %v\n", err)
		return exitFailure
	}
	if err := printJSON(stdout, rep); err != nil {
		fmt.Fprintf(stderr, "node-agent status: %v\n", err)
		return exitFailure
	}
	return exitOK
}

// steerCmd implements `node-agent steer`.
func steerCmd(args []string, stdout, stderr io.Writer) int {
	fs := newFlagSet("steer", stderr)
	var (
		runID = fs.String("run-id", "", "run id (required)")
		msg   = fs.String("message", "", "control message (required)")
		db    = fs.String("db", "", "journal file (default $DEVTEAM_RUN_DB)")
	)
	if !parseFlags(fs, args, stderr) {
		return exitUsage
	}
	if *runID == "" {
		fmt.Fprintln(stderr, "node-agent steer: --run-id is required")
		return exitUsage
	}
	if *msg == "" {
		fmt.Fprintln(stderr, "node-agent steer: --message is required")
		return exitUsage
	}

	a, err := agent.New()
	if err != nil {
		fmt.Fprintf(stderr, "node-agent steer: %v\n", err)
		return exitFailure
	}
	eng, err := open(*db)
	if err != nil {
		fmt.Fprintf(stderr, "node-agent steer: %v\n", err)
		return exitFailure
	}
	defer func() { _ = eng.Close() }()

	if err := a.Steer(context.Background(), eng, *runID, *msg); err != nil {
		fmt.Fprintf(stderr, "node-agent steer: %v\n", err)
		return exitFailure
	}
	fmt.Fprintln(stdout, "ok")
	return exitOK
}

// statusNodeCmd implements `node-agent status-node`: the node's selection,
// fail-closed posture made visible.
func statusNodeCmd(stdout, stderr io.Writer) int {
	cfg, err := agent.Load(nil)
	if err != nil {
		fmt.Fprintf(stderr, "node-agent status-node: %v\n", err)
		return exitFailure
	}
	rep := map[string]any{
		"runner":         string(cfg.Runner),
		"runner_raw":     cfg.Raw,
		"runner_source":  cfg.Source,
		"runner_command": cfg.Command,
		"config_path":    cfg.Path,
		"selected":       cfg.Selected(),
		"known":          agent.RunnerTypeList(),
	}
	if err := printJSON(stdout, rep); err != nil {
		fmt.Fprintf(stderr, "node-agent status-node: %v\n", err)
		return exitFailure
	}
	return exitOK
}

// multiFlag collects repeatable --arg values in argv order.
type multiFlag []string

func (m *multiFlag) String() string { return strings.Join(*m, " ") }
func (m *multiFlag) Set(v string) error {
	*m = append(*m, v)
	return nil
}

// printJSON writes one JSON object plus a newline.
func printJSON(w io.Writer, v any) error {
	raw, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	_, err = fmt.Fprintln(w, string(raw))
	return err
}

// open opens the journal at the named path, or the environment's default. The
// busy timeout is set inside journal.OpenPath, on every open.
func open(path string) (*journal.Engine, error) {
	if strings.TrimSpace(path) == "" {
		resolved, err := journal.Resolve()
		if err != nil {
			return nil, err
		}
		path = resolved
	}
	return journal.OpenPath(context.Background(), path)
}

// newFlagSet keeps flag's own diagnostics on stderr, where the caller reads
// them; stdout stays parseable.
func newFlagSet(name string, stderr io.Writer) *flag.FlagSet {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.Usage = func() {
		fmt.Fprintf(stderr, "node-agent %s:\n", name)
		fs.PrintDefaults()
	}
	return fs
}

func parseFlags(fs *flag.FlagSet, args []string, stderr io.Writer) bool {
	if err := fs.Parse(args); err != nil {
		return false
	}
	if fs.NArg() > 0 {
		fmt.Fprintf(stderr, "node-agent %s: unexpected argument %q\n", fs.Name(), fs.Arg(0))
		return false
	}
	return true
}
