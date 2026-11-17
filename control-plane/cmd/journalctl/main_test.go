package main

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
)

// cli is one journalctl invocation: argv in, the two streams out, the exit code
// back. No test shells out, so the contract under test is the binary's own code
// path.
type cli struct {
	t      *testing.T
	db     string
	stdout bytes.Buffer
	stderr bytes.Buffer
	code   int
}

func newCLI(t *testing.T) *cli {
	t.Helper()
	return &cli{t: t, db: filepath.Join(t.TempDir(), "run.db")}
}

// call runs the CLI with --db pointed at the test journal.
func (c *cli) call(a ...string) int {
	c.t.Helper()
	c.stdout.Reset()
	c.stderr.Reset()
	withDB := append(append([]string{}, a...), "--db", c.db)
	c.code = run(withDB, &c.stdout, &c.stderr)
	return c.code
}

// callRaw runs the CLI with exactly these argv (no --db injected).
func (c *cli) callRaw(a ...string) int {
	c.t.Helper()
	c.stdout.Reset()
	c.stderr.Reset()
	c.code = run(a, &c.stdout, &c.stderr)
	return c.code
}

func (c *cli) wantCode(code int) {
	c.t.Helper()
	if c.code != code {
		c.t.Fatalf("exit code = %d, want %d\nstdout: %s\nstderr: %s",
			c.code, code, c.stdout.String(), c.stderr.String())
	}
}

func (c *cli) events(runID string) []journal.Event {
	c.t.Helper()
	eng, err := journal.OpenPath(context.Background(), c.db)
	if err != nil {
		c.t.Fatal(err)
	}
	defer func() { _ = eng.Close() }()
	list, err := eng.Events(context.Background(), runID)
	if err != nil {
		c.t.Fatal(err)
	}
	return list
}

// The append contract: exit 0, one "ok SEQ" line on stdout and nothing else.
func TestAppendSuccess(t *testing.T) {
	c := newCLI(t)
	code := c.call("append", "--run-id", "CDT-643", "--kind", "run_claimed",
		"--payload", `{"owner":"runner-a:pid=123","token":1,"ticket":"CDT-643"}`)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0; stderr %s", code, c.stderr.String())
	}
	if got := c.stdout.String(); got != "ok 1\n" {
		t.Fatalf("stdout = %q, want %q", got, "ok 1\n")
	}
	if c.stderr.Len() != 0 {
		t.Fatalf("stderr = %q, want empty", c.stderr.String())
	}
	list := c.events("CDT-643")
	if len(list) != 1 || list[0].Kind != journal.KindRunClaimed {
		t.Fatalf("events = %+v", list)
	}
}

// A missing payload is the empty object, not a usage error.
func TestAppendDefaultPayload(t *testing.T) {
	c := newCLI(t)
	if code := c.call("append", "--run-id", "R", "--kind", "heartbeat"); code != exitOK {
		t.Fatalf("exit = %d, want 0; stderr %s", code, c.stderr.String())
	}
	list := c.events("R")
	if string(list[0].Payload) != "{}" {
		t.Fatalf("payload = %s, want {}", list[0].Payload)
	}
}

// AC3 through the CLI: a second append on a recorded idempotency key writes
// nothing and exits 1, because the effect behind the key already happened.
func TestAppendDuplicateKeyExitsOne(t *testing.T) {
	c := newCLI(t)
	payload := `{"effect":"push","intent":{"ref":"refs/heads/feat"}}`
	if code := c.call("append", "--run-id", "R", "--kind", "side_effect",
		"--payload", payload, "--idempotency-key", "R:push:1"); code != exitOK {
		t.Fatalf("first append exit = %d, want 0; stderr %s", code, c.stderr.String())
	}
	code := c.call("append", "--run-id", "R", "--kind", "side_effect",
		"--payload", payload, "--idempotency-key", "R:push:1")
	if code != exitFailure {
		t.Fatalf("second append exit = %d, want 1; stderr %s", code, c.stderr.String())
	}
	if !strings.Contains(c.stderr.String(), "already recorded") {
		t.Fatalf("stderr = %q, want the duplicate-key reason", c.stderr.String())
	}
	if c.stdout.Len() != 0 {
		t.Fatalf("stdout = %q, want empty on a refused append", c.stdout.String())
	}
	if got := len(c.events("R")); got != 1 {
		t.Fatalf("events = %d, want 1: the replay wrote nothing", got)
	}
}

// An intent row with no idempotency key is refused by the journal's validator:
// that is a bad argument, so 64.
func TestAppendIntentWithoutKeyIsUsage(t *testing.T) {
	c := newCLI(t)
	code := c.call("append", "--run-id", "R", "--kind", "side_effect",
		"--payload", `{"effect":"push"}`)
	if code != exitUsage {
		t.Fatalf("exit = %d, want 64; stderr %s", code, c.stderr.String())
	}
	if !strings.Contains(c.stderr.String(), "idempotency key") {
		t.Fatalf("stderr = %q, want the key requirement", c.stderr.String())
	}
}

// A kind outside the closed set is a usage error, and the message names the set.
func TestAppendBadKindNamesTheClosedSet(t *testing.T) {
	c := newCLI(t)
	code := c.call("append", "--run-id", "R", "--kind", "run_finished", "--payload", `{}`)
	if code != exitUsage {
		t.Fatalf("exit = %d, want 64; stderr %s", code, c.stderr.String())
	}
	msg := c.stderr.String()
	for _, want := range []string{"closed set", "run_claimed", "run_completed", "repair"} {
		if !strings.Contains(msg, want) {
			t.Errorf("stderr %q does not name %q", msg, want)
		}
	}
}

func TestAppendUsageErrors(t *testing.T) {
	cases := []struct {
		name string
		args []string
		want string
	}{
		{"missing run id", []string{"append", "--kind", "heartbeat"}, "--run-id is required"},
		{"missing kind", []string{"append", "--run-id", "R"}, "unknown kind"},
		{"unknown flag", []string{"append", "--run-id", "R", "--kind", "heartbeat", "--nope"},
			"flag provided but not defined: -nope"},
		{"payload is not JSON", []string{"append", "--run-id", "R", "--kind", "heartbeat",
			"--payload", "not json"}, "payload"},
		{"payload is a scalar", []string{"append", "--run-id", "R", "--kind", "heartbeat",
			"--payload", "5"}, "payload"},
		{"partial card", []string{"append", "--run-id", "R", "--kind", "heartbeat",
			"--card-path", "/p.jsonl"}, "--card-ts"},
		{"extra argument", []string{"append", "--run-id", "R", "--kind", "heartbeat", "surplus"},
			"unexpected argument"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := newCLI(t)
			if code := c.call(tc.args...); code != exitUsage {
				t.Fatalf("exit = %d, want 64; stderr %s", code, c.stderr.String())
			}
			if c.stdout.Len() != 0 {
				t.Fatalf("stdout = %q, want empty", c.stdout.String())
			}
			if !strings.Contains(c.stderr.String(), tc.want) {
				t.Fatalf("stderr = %q, want %q", c.stderr.String(), tc.want)
			}
		})
	}
}

// A full card reference is three columns and nothing else (ADR 0001).
func TestAppendCardReference(t *testing.T) {
	c := newCLI(t)
	code := c.call("append", "--run-id", "R", "--kind", "run_completed", "--payload", `{}`,
		"--card-path", "/m/.claude/autopilot/R.jsonl",
		"--card-ts", "2026-11-16T12:00:00Z", "--card-run-id", "R")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0; stderr %s", code, c.stderr.String())
	}
	list := c.events("R")
	if list[0].Card == nil {
		t.Fatal("the card reference was not recorded")
	}
	if list[0].Card.Path != "/m/.claude/autopilot/R.jsonl" || list[0].Card.TS != "2026-11-16T12:00:00Z" {
		t.Fatalf("card = %+v", list[0].Card)
	}
}

// The read contract: --state is one JSON object, --events is NDJSON.
func TestReadStateAndEvents(t *testing.T) {
	c := newCLI(t)
	if code := c.call("append", "--run-id", "CDT-643", "--kind", "run_claimed",
		"--payload", `{"owner":"runner-a","token":1,"ticket":"CDT-643"}`); code != exitOK {
		t.Fatalf("append exit = %d; stderr %s", code, c.stderr.String())
	}
	if code := c.call("append", "--run-id", "CDT-643", "--kind", "run_started",
		"--payload", `{"stall_limit_s":108}`); code != exitOK {
		t.Fatalf("append exit = %d; stderr %s", code, c.stderr.String())
	}

	code := c.call("read", "--run-id", "CDT-643", "--state")
	if code != exitOK {
		t.Fatalf("read --state exit = %d, want 0; stderr %s", code, c.stderr.String())
	}
	stateOut := c.stdout.String()
	lines := strings.Split(strings.TrimRight(stateOut, "\n"), "\n")
	if len(lines) != 1 {
		t.Fatalf("--state printed %d lines, want one JSON object:\n%s", len(lines), stateOut)
	}
	var state map[string]any
	if err := json.Unmarshal([]byte(lines[0]), &state); err != nil {
		t.Fatalf("--state is not one JSON object: %v\n%s", err, lines[0])
	}
	if state["run_id"] != "CDT-643" || state["status"] != "running" {
		t.Fatalf("state = %+v", state)
	}
	if v, ok := state["stall_limit_s"].(float64); !ok || v != 108 {
		t.Fatalf("state stall_limit_s = %v, want 108", state["stall_limit_s"])
	}

	code = c.call("read", "--run-id", "CDT-643", "--events")
	if code != exitOK {
		t.Fatalf("read --events exit = %d, want 0; stderr %s", code, c.stderr.String())
	}
	ndjson := strings.Split(strings.TrimRight(c.stdout.String(), "\n"), "\n")
	if len(ndjson) != 2 {
		t.Fatalf("NDJSON lines = %d, want 2\n%s", len(ndjson), c.stdout.String())
	}
	var last int64 = -1
	for i, line := range ndjson {
		var ev map[string]any
		if err := json.Unmarshal([]byte(line), &ev); err != nil {
			t.Fatalf("line %d is not a JSON object: %v\n%s", i+1, err, line)
		}
		seq, ok := ev["seq"].(float64)
		if !ok || int64(seq) <= last {
			t.Fatalf("line %d has seq %v after %d: NDJSON must be one object per line in seq order",
				i+1, ev["seq"], last)
		}
		last = int64(seq)
		if ev["run_id"] != "CDT-643" {
			t.Fatalf("line %d run_id = %v", i+1, ev["run_id"])
		}
	}

	// Both flags: state first, then events.
	code = c.call("read", "--run-id", "CDT-643", "--state", "--events")
	if code != exitOK {
		t.Fatalf("read --state --events exit = %d; stderr %s", code, c.stderr.String())
	}
	both := strings.Split(strings.TrimRight(c.stdout.String(), "\n"), "\n")
	if len(both) != 3 {
		t.Fatalf("lines = %d, want 3 (state + 2 events)\n%s", len(both), c.stdout.String())
	}
	var stateAgain map[string]any
	if err := json.Unmarshal([]byte(both[0]), &stateAgain); err != nil {
		t.Fatalf("the first line is not the state: %v", err)
	}
	if stateAgain["status"] != "running" {
		t.Fatalf("first line = %s, want the state", both[0])
	}
}

func TestReadUsageAndFailures(t *testing.T) {
	t.Run("unknown run exits 1 on stderr", func(t *testing.T) {
		c := newCLI(t)
		if code := c.call("append", "--run-id", "R", "--kind", "heartbeat"); code != exitOK {
			t.Fatalf("append exit = %d", code)
		}
		if code := c.call("read", "--run-id", "OTHER", "--state"); code != exitFailure {
			t.Fatalf("exit = %d, want 1; stderr %s", code, c.stderr.String())
		}
		if !strings.Contains(c.stderr.String(), "no events for run") {
			t.Fatalf("stderr = %q", c.stderr.String())
		}
		if c.stdout.Len() != 0 {
			t.Fatalf("stdout = %q, want empty", c.stdout.String())
		}
	})

	t.Run("missing run id is usage", func(t *testing.T) {
		c := newCLI(t)
		if code := c.call("read", "--state"); code != exitUsage {
			t.Fatalf("exit = %d, want 64", code)
		}
	})

	t.Run("no output flag is usage", func(t *testing.T) {
		c := newCLI(t)
		if code := c.call("read", "--run-id", "R"); code != exitUsage {
			t.Fatalf("exit = %d, want 64", code)
		}
		if !strings.Contains(c.stderr.String(), "--state") {
			t.Fatalf("stderr = %q, want the flag names", c.stderr.String())
		}
	})

	t.Run("unknown flag is usage", func(t *testing.T) {
		c := newCLI(t)
		if code := c.call("read", "--run-id", "R", "--json"); code != exitUsage {
			t.Fatalf("exit = %d, want 64", code)
		}
	})

	t.Run("a journal that cannot be replayed exits 1", func(t *testing.T) {
		c := newCLI(t)
		// A heartbeat with no claim: appendable, not replayable.
		if code := c.call("append", "--run-id", "R", "--kind", "heartbeat",
			"--payload", `{"owner":"x","token":3}`); code != exitOK {
			t.Fatalf("append exit = %d, want 0: the append path is the journal, "+
				"legality is the state machine's; stderr %s", code, c.stderr.String())
		}
		if code := c.call("read", "--run-id", "R", "--state"); code != exitFailure {
			t.Fatalf("exit = %d, want 1; stderr %s", code, c.stderr.String())
		}
		if !strings.Contains(c.stderr.String(), "replay") {
			t.Fatalf("stderr = %q, want the replay failure", c.stderr.String())
		}
		// The rows are still readable.
		if code := c.call("read", "--run-id", "R", "--events"); code != exitOK {
			t.Fatalf("read --events exit = %d, want 0", code)
		}
	})
}

// The usage line names the binary, and the missing-command paths are usage
// errors on stderr.
func TestUsageSurface(t *testing.T) {
	c := newCLI(t)
	if code := c.callRaw(); code != exitUsage {
		t.Fatalf("no args exit = %d, want 64", code)
	}
	if !strings.HasPrefix(c.stderr.String(), "control-plane journalctl") {
		t.Fatalf("stderr = %q, want the usage line to self-identify", c.stderr.String())
	}
	for _, arg := range []string{"status", "rm", ""} {
		if code := c.callRaw(arg); code != exitUsage {
			t.Fatalf("%q exit = %d, want 64; stderr %s", arg, code, c.stderr.String())
		}
	}
	if !strings.Contains(c.stderr.String(), "unknown command") {
		t.Fatalf("stderr = %q", c.stderr.String())
	}

	for _, arg := range []string{"-h", "--help", "help"} {
		if code := c.callRaw(arg); code != exitOK {
			t.Fatalf("%s exit = %d, want 0", arg, code)
		}
		out := c.stdout.String()
		if !strings.HasPrefix(out, "control-plane journalctl") {
			t.Fatalf("help output = %.60q, want the control-plane journalctl usage line", out)
		}
		for _, want := range []string{"journalctl append", "journalctl read", "--idempotency-key",
			"never imports\na Go package", "64"} {
			if !strings.Contains(out, want) {
				t.Errorf("help omits %q", want)
			}
		}
	}
}

// The env path is honoured: with --db absent, $DEVTEAM_RUN_DB is the journal.
func TestEnvJournalPath(t *testing.T) {
	dir := t.TempDir()
	db := filepath.Join(dir, "runs", "run.db")
	t.Setenv(journal.EnvRunDB, db)
	t.Setenv(journal.EnvMROOT, dir)

	c := &cli{t: t, db: db}
	if code := c.callRaw("append", "--run-id", "R", "--kind", "heartbeat"); code != exitOK {
		t.Fatalf("append exit = %d, want 0; stderr %s", code, c.stderr.String())
	}
	if _, err := os.Stat(db); err != nil {
		t.Fatalf("the journal was not created at %s: %v", db, err)
	}
	if code := c.callRaw("read", "--run-id", "R", "--events"); code != exitOK {
		t.Fatalf("read exit = %d, want 0; stderr %s", code, c.stderr.String())
	}
	if !strings.Contains(c.stdout.String(), `"kind":"heartbeat"`) {
		t.Fatalf("stdout = %s", c.stdout.String())
	}
}

// The memory database is never a journal, and the CLI says so.
func TestRefusesMemoryDB(t *testing.T) {
	c := newCLI(t)
	c.db = filepath.Join(t.TempDir(), ".claude", "memory", "memory.db")
	if code := c.call("append", "--run-id", "R", "--kind", "heartbeat"); code != exitFailure {
		t.Fatalf("exit = %d, want 1; stderr %s", code, c.stderr.String())
	}
	if !strings.Contains(c.stderr.String(), "memory.db") {
		t.Fatalf("stderr = %q, want the memory.db refusal", c.stderr.String())
	}
}

// The kind set the usage text prints is the journal's own set, in one place.
func TestUsageKindSet(t *testing.T) {
	text := usageText()
	for _, k := range journal.AllKinds {
		if !strings.Contains(text, string(k)) {
			t.Errorf("usage omits kind %q", k)
		}
	}
	if strings.Contains(text, "KINDS") {
		t.Error("usage carries the kind placeholder, not the set")
	}
}
