// Command journalctl is the control-plane journal CLI: one append, one read.
//
// It is the only way a plugin surface (or a human) touches run state. A plugin
// surface calls this binary with argv and env and reads its stdout: it never
// imports a Go package, never opens the journal database with its own SQL, and
// never shares a process with the control plane
// (docs/adr/0001-journal-engine.md § "The narrow-interface boundary").
//
// Inputs come from argv and the environment only. Every value reaches SQLite as
// a bound ? parameter inside the journal package; nothing is interpolated into
// code (AGENTS.md § Code Conventions).
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
)

// Exit codes. 64 is EX_USAGE, the code ADR 0001 fixes for a usage error.
const (
	exitOK      = 0
	exitFailure = 1
	exitUsage   = 64
)

const usage = `control-plane journalctl — the run journal: one append, one read

Usage:
  journalctl append --run-id ID --kind KIND [--payload JSON]
                    [--idempotency-key KEY]
                    [--card-path PATH --card-ts TS --card-run-id RID]
  journalctl read   --run-id ID [--state] [--events] [--db PATH]

Commands:
  append  Appends one event. Prints "ok SEQ" on stdout and nothing else.
          An idempotency key that is already recorded writes nothing and exits 1:
          the effect behind that key already happened (do not repeat it).
  read    --state prints the replayed run state as one JSON object on stdout.
          --events prints the run's events as NDJSON on stdout, one JSON object
          per line, in seq order. Both flags print state first, then events.

Options:
  --db PATH   Journal file. Default: $DEVTEAM_RUN_DB, else
              $DEVTEAM_MROOT/.claude/runs/run.db. The busy timeout (5000 ms) is
              set on every open.
  --help      Prints this text.

Kinds (the closed set; any other kind is refused):
  KINDS

Exit codes:
  0   success
  1   journal failure (append refused, duplicate idempotency key, unknown run,
      a journal that cannot be replayed)
  64  usage error (unknown flag, missing --run-id, a kind outside the closed
      set, a payload that is not a JSON object, a partial card reference,
      --read with neither --state nor --events)

This command is the whole interface: a plugin surface calls it and never imports
a Go package. Values travel as argv only.
`

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

// run is the CLI. args is argv[1:]; nothing is read from stdin, so the code
// path has one input channel. stdout and stderr are separated: stdout carries
// the NDJSON a caller parses, stderr carries the error a caller logs.
func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprint(stderr, usageText())
		return exitUsage
	}
	switch args[0] {
	case "append":
		return appendCmd(args[1:], stdout, stderr)
	case "read":
		return readCmd(args[1:], stdout, stderr)
	case "-h", "--help", "help":
		fmt.Fprint(stdout, usageText())
		return exitOK
	default:
		fmt.Fprintf(stderr, "journalctl: unknown command %q\n", args[0])
		fmt.Fprint(stderr, usageText())
		return exitUsage
	}
}

// usageText fills the kind line, so the closed set is stated once, in the
// journal package that owns it.
func usageText() string {
	kinds := make([]string, 0, len(journal.AllKinds))
	for _, k := range journal.AllKinds {
		kinds = append(kinds, string(k))
	}
	return strings.Replace(usage, "  KINDS\n", "  "+strings.Join(kinds, " | ")+"\n", 1)
}

// appendCmd implements `journalctl append`.
func appendCmd(args []string, stdout, stderr io.Writer) int {
	fs := newFlagSet("append", stderr)
	var (
		runID   = fs.String("run-id", "", "run id (required)")
		kind    = fs.String("kind", "", "event kind (required)")
		payload = fs.String("payload", "{}", "event payload: one JSON object")
		key     = fs.String("idempotency-key", "", "idempotency key of a side effect")
		cardP   = fs.String("card-path", "", "decision-card path (reference only)")
		cardTS  = fs.String("card-ts", "", "decision-card ts (reference only)")
		cardR   = fs.String("card-run-id", "", "decision-card run_id (reference only)")
		db      = fs.String("db", "", "journal file (default $DEVTEAM_RUN_DB)")
	)
	if !parseFlags(fs, args, stderr) {
		return exitUsage
	}
	if *runID == "" {
		fmt.Fprintln(stderr, "journalctl append: --run-id is required")
		return exitUsage
	}
	k := journal.Kind(*kind)
	if !kindValid(k) {
		fmt.Fprintf(stderr, "journalctl append: unknown kind %q; the closed set is: %s\n",
			*kind, kindSet())
		return exitUsage
	}
	card, code := cardRef(*cardP, *cardTS, *cardR, stderr)
	if code != exitOK {
		return code
	}

	ev, err := journal.NewEvent(*runID, k, json.RawMessage(payloadJSON(*payload)))
	if err != nil {
		fmt.Fprintf(stderr, "journalctl append: %v\n", err)
		return exitUsage
	}
	ev.IdempotencyKey = *key
	ev.Card = card

	eng, err := open(*db)
	if err != nil {
		fmt.Fprintf(stderr, "journalctl append: %v\n", err)
		return exitFailure
	}
	defer func() { _ = eng.Close() }()

	seq, created, err := eng.AppendIdempotent(context.Background(), ev)
	if err != nil {
		fmt.Fprintf(stderr, "journalctl append: %v\n", err)
		// The journal's own validator refused the row: a bad argument, not a
		// journal fault (an intent row with no key, a payload that is not an
		// object).
		if errors.Is(err, journal.ErrInvalid) {
			return exitUsage
		}
		return exitFailure
	}
	if !created {
		fmt.Fprintf(stderr, "journalctl append: idempotency key %q is already recorded at seq %d; "+
			"the effect behind it already happened and was not repeated\n", *key, seq)
		return exitFailure
	}
	fmt.Fprintf(stdout, "ok %d\n", seq)
	return exitOK
}

// readCmd implements `journalctl read`.
func readCmd(args []string, stdout, stderr io.Writer) int {
	fs := newFlagSet("read", stderr)
	var (
		runID  = fs.String("run-id", "", "run id (required)")
		state  = fs.Bool("state", false, "print the replayed state as one JSON object")
		events = fs.Bool("events", false, "print the run's events as NDJSON")
		db     = fs.String("db", "", "journal file (default $DEVTEAM_RUN_DB)")
	)
	if !parseFlags(fs, args, stderr) {
		return exitUsage
	}
	if *runID == "" {
		fmt.Fprintln(stderr, "journalctl read: --run-id is required")
		return exitUsage
	}
	if !*state && !*events {
		fmt.Fprintln(stderr, "journalctl read: name what to print: --state, --events, or both")
		return exitUsage
	}

	eng, err := open(*db)
	if err != nil {
		fmt.Fprintf(stderr, "journalctl read: %v\n", err)
		return exitFailure
	}
	defer func() { _ = eng.Close() }()
	ctx := context.Background()

	list, err := eng.Events(ctx, *runID)
	if err != nil {
		fmt.Fprintf(stderr, "journalctl read: %v\n", err)
		return exitFailure
	}
	if len(list) == 0 {
		fmt.Fprintf(stderr, "journalctl read: no events for run %q in %s\n", *runID, eng.Path())
		return exitFailure
	}

	if *state {
		st, err := journal.Replay(list)
		if err != nil {
			fmt.Fprintf(stderr, "journalctl read: %v\n", err)
			return exitFailure
		}
		st.RunID = *runID
		raw, err := json.Marshal(st)
		if err != nil {
			fmt.Fprintf(stderr, "journalctl read: %v\n", err)
			return exitFailure
		}
		fmt.Fprintln(stdout, string(raw))
	}
	if *events {
		enc := json.NewEncoder(stdout)
		for _, ev := range list {
			if err := enc.Encode(ev); err != nil {
				fmt.Fprintf(stderr, "journalctl read: %v\n", err)
				return exitFailure
			}
		}
	}
	return exitOK
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
		fmt.Fprintf(stderr, "journalctl %s:\n", name)
		fs.PrintDefaults()
	}
	return fs
}

func parseFlags(fs *flag.FlagSet, args []string, stderr io.Writer) bool {
	if err := fs.Parse(args); err != nil {
		return false
	}
	if fs.NArg() > 0 {
		fmt.Fprintf(stderr, "journalctl %s: unexpected argument %q\n", fs.Name(), fs.Arg(0))
		return false
	}
	return true
}

// kindValid reports a kind inside the closed set the schema CHECK enforces.
func kindValid(k journal.Kind) bool {
	for _, v := range journal.AllKinds {
		if v == k {
			return true
		}
	}
	return false
}

func kindSet() string {
	kinds := make([]string, 0, len(journal.AllKinds))
	for _, k := range journal.AllKinds {
		kinds = append(kinds, string(k))
	}
	return strings.Join(kinds, ", ")
}

// cardRef takes the card reference only as a whole: path, ts, and run_id
// together, or none (journal/schema.sql § CARD REFERENCE RULE). It carries no
// card field.
func cardRef(path, ts, runID string, stderr io.Writer) (*journal.CardRef, int) {
	given := 0
	for _, v := range []string{path, ts, runID} {
		if v != "" {
			given++
		}
	}
	switch given {
	case 0:
		return nil, exitOK
	case 3:
		return &journal.CardRef{Path: path, TS: ts, RunID: runID}, exitOK
	default:
		fmt.Fprintln(stderr, "journalctl append: a card reference needs --card-path, --card-ts, "+
			"and --card-run-id together")
		return nil, exitUsage
	}
}

// payloadJSON normalises an empty payload to the empty object.
func payloadJSON(raw string) string {
	if strings.TrimSpace(raw) == "" {
		return "{}"
	}
	return raw
}
