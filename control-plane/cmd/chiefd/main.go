// Command chiefd serves the Chief (CDT-650, CDT-628 C9): the single point of
// contact of control plane Option C+ (CDT-626). Its one interface is the
// HTTP API the web UI consumes (control-plane/chief.Handler) — there is no
// CLI verb and no second interface. Since CDT-652 (C10) the same process
// serves the web UI's static page on the same loopback port; the page gains
// no endpoint of its own, and the bind is loopback-only (remote access is
// CDT-630's phase-3 scope).
//
// The chief serves one project's journal ($DEVTEAM_RUN_DB, else
// $MROOT/.claude/runs/run.db), routes work to the plugin's existing Surfaces
// through files and CLI calls only (the ADR 0001 boundary), and pages the
// operator through the Intercom when a run halts.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/cold-dark-void/claude-dev-team/control-plane/agent"
	"github.com/cold-dark-void/claude-dev-team/control-plane/chief"
	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
)

// Exit codes. 64 is EX_USAGE, the code ADR 0001 fixes for a usage error.
const (
	exitOK      = 0
	exitFailure = 1
	exitUsage   = 64
)

const usage = `chiefd — the Chief of the control plane: one API, one web UI, no second interface.

Usage:
  chiefd [--addr ADDR] [--db PATH]

The API (the only interface; the web UI consumes it):
  POST /v1/route                      route work to a Surface
  POST /v1/runs/{run}/corrections     a correction at the next step boundary
  POST /v1/runs/{run}/stop            the operator halt
  POST /v1/runs/{run}/resume          the same-run continuation
  POST /v1/runs/{run}/retry           a new attempt of the ticket
  GET  /v1/runs, /v1/runs/{run}       run status, from the journal
  GET  /v1/runs/{run}/events          the run's journal rows
  GET  /v1/runs/{run}/output          the bounded transcript tail
  GET  /v1/model?agent=<agent>        the Model map preflight
  GET  /v1/queue                      the slot ledger
  GET  /v1/checks                     the per-run integrity reading
  GET  /v1/standup                    the stand-up report
  GET  /v1/halts                      named halts, reason + retry budget
  GET  /v1/graph                      the C3 lifecycle graph

The web UI (CDT-652) rides the same port: http://127.0.0.1:8090/ serves the
run board, the run detail pane with the operator actions (CDT-672), and the
chat with the Chief. The bind is loopback-only — a non-loopback address is
refused (remote access is CDT-630's phase-3 scope).

Flags:
  --addr ADDR    the loopback listen address (default 127.0.0.1:8090)
  --db PATH      the journal file (default $DEVTEAM_RUN_DB)

Routing starts runs through the node agent's four-verb contract (the C6 host
adapter), writes ticket records through the plugin's own ticket verbs, and
resolves the model through the Model map (skills/model-map/resolve-model.sh;
an empty resolution is the Tier default — no flag exists for the model).
`

// errNotLoopback refuses a listen address that leaves the loopback
// interface: the web UI is loopback-only (CDT-652) — no exposed port, no
// access layer; remote access is CDT-630's phase-3 scope.
var errNotLoopback = errors.New("chiefd: the listen address must be loopback (127.0.0.1, ::1, or localhost)")

// loopbackOnly checks a listen address before the server binds it (AC6):
// the host must name a loopback interface. A bare port (":8090") binds
// every interface, so it is refused too.
func loopbackOnly(addr string) error {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return fmt.Errorf("%w: %s is not host:port", errNotLoopback, addr)
	}
	if host == "localhost" {
		return nil
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return fmt.Errorf("%w: %s", errNotLoopback, addr)
	}
	return nil
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("chiefd", flag.ContinueOnError)
	fs.SetOutput(stderr)
	addr := fs.String("addr", "127.0.0.1:8090", "loopback listen address of the API and the web UI")
	db := fs.String("db", "", "journal file (default $DEVTEAM_RUN_DB)")
	if err := fs.Parse(args); err != nil {
		return exitUsage
	}
	if fs.NArg() > 0 {
		fmt.Fprintf(stderr, "chiefd: unexpected argument %q\n", fs.Arg(0))
		fmt.Fprint(stderr, usage)
		return exitUsage
	}
	if err := loopbackOnly(*addr); err != nil {
		fmt.Fprintf(stderr, "%v\n", err)
		return exitUsage
	}

	path := strings.TrimSpace(*db)
	if path == "" {
		resolved, err := journal.Resolve()
		if err != nil {
			fmt.Fprintf(stderr, "chiefd: %v\n", err)
			return exitFailure
		}
		path = resolved
	}
	eng, err := journal.OpenPath(context.Background(), path)
	if err != nil {
		fmt.Fprintf(stderr, "chiefd: %v\n", err)
		return exitFailure
	}
	defer func() { _ = eng.Close() }()

	a, err := agent.New()
	if err != nil {
		fmt.Fprintf(stderr, "chiefd: %v\n", err)
		return exitFailure
	}
	// The signal context is the chief's base context (SPEC-044 M8/AC15): a
	// shutdown cancels every supervised run's context, which is the quiet
	// path agent.Supervise takes — the runner child stops, the pidfile and
	// the lease stay, and the journal gains no halt row. chiefd registers no
	// stop intent of its own; the operator halt belongs to the stop verb.
	ctx, stop := signal.NotifyContext(context.Background(),
		syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	ch := chief.New(eng, a, chief.WithBaseContext(ctx))
	go ch.Watch(ctx, chief.DefaultWatchInterval)

	srv := &http.Server{Addr: *addr, Handler: withUI(ch.Handler())}
	errc := make(chan error, 1)
	go func() { errc <- srv.ListenAndServe() }()

	fmt.Fprintf(stdout, "chief: serving the API and the web UI on http://%s (journal %s)\n", *addr, path)
	select {
	case err := <-errc:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			fmt.Fprintf(stderr, "chiefd: %v\n", err)
			return exitFailure
		}
	case <-ctx.Done():
	}
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdownCtx)
	return exitOK
}
