package main

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
	runmachine "github.com/cold-dark-void/claude-dev-team/control-plane/run"
)

// helperArgsEnv is the sentinel that turns this test binary into chiefd: its
// value is the argv list, one entry per line. The shutdown test re-execs
// os.Args[0] with it, so the process that takes SIGTERM is a real chiefd —
// no build step, no simulated signal.
const helperArgsEnv = "CDT660_CHIEFD_ARGS"

// TestMain doubles as the helper entry point: with helperArgsEnv set, this
// binary is chiefd, running the argv list that variable carries, and it exits
// with chiefd's exit code.
func TestMain(m *testing.M) {
	if raw := os.Getenv(helperArgsEnv); raw != "" {
		args := strings.Split(strings.TrimSuffix(raw, "\n"), "\n")
		os.Exit(run(args, os.Stdout, os.Stderr))
	}
	os.Exit(m.Run())
}

// AC6: the web UI is loopback-only. A non-loopback --addr is refused with
// the typed error before anything binds — no exposed port, no access layer;
// remote access is CDT-630's phase-3 scope.
func TestNonLoopbackBindIsRefused(t *testing.T) {
	for _, addr := range []string{"0.0.0.0:8090", ":8090", "192.168.1.9:8090", "example.com:8090", "8090"} {
		err := loopbackOnly(addr)
		if err == nil || !errors.Is(err, errNotLoopback) {
			t.Errorf("loopbackOnly(%q) = %v, want the typed loopback refusal", addr, err)
		}
	}
	if !errors.Is(loopbackOnly("0.0.0.0:8090"), errNotLoopback) {
		t.Error("the refusal does not carry the typed cause")
	}
	for _, addr := range []string{"127.0.0.1:8090", "localhost:8090", "[::1]:8090"} {
		if err := loopbackOnly(addr); err != nil {
			t.Errorf("loopbackOnly(%q) = %v, want nil", addr, err)
		}
	}
}

// The loopback refusal exits with the usage code and names the address.
func TestRunRefusesANonLoopbackAddr(t *testing.T) {
	var stderr strings.Builder
	code := run([]string{"--addr", "0.0.0.0:8090"}, io.Discard, &stderr)
	if code != exitUsage {
		t.Errorf("exit code = %d, want %d", code, exitUsage)
	}
	if !strings.Contains(stderr.String(), "must be loopback") ||
		!strings.Contains(stderr.String(), "0.0.0.0:8090") {
		t.Errorf("stderr = %q, want the typed loopback refusal naming the address", stderr.String())
	}
}

// AC1: the web UI rides the same process and the same port as the API —
// the page is delivery, not data. The page and its assets serve from the
// embedded files, and every other path answers through the API surface,
// which 404s on unknown routes.
func TestTheUIRidesTheAPISPort(t *testing.T) {
	api := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/runs" {
			_, _ = w.Write([]byte(`{"runs":[]}`))
			return
		}
		http.NotFound(w, r)
	})
	srv := httptest.NewServer(withUI(api))
	t.Cleanup(srv.Close)

	res, err := http.Get(srv.URL + "/")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK ||
		!strings.Contains(res.Header.Get("Content-Type"), "text/html") {
		t.Fatalf("GET / = %d %s, want the page", res.StatusCode, res.Header.Get("Content-Type"))
	}
	page := readAll(t, res)
	for _, marker := range []string{"Run board", "Chat with the Chief", "Lifecycle"} {
		if !strings.Contains(page, marker) {
			t.Errorf("the page lacks the %q section", marker)
		}
	}

	// The assets: the CSS and the JS serve with their content types, and an
	// unknown static name 404s.
	for name, contentType := range map[string]string{
		"/static/style.css": "text/css",
		"/static/app.js":    "text/javascript",
	} {
		res, err := http.Get(srv.URL + name)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		if res.StatusCode != http.StatusOK ||
			!strings.Contains(res.Header.Get("Content-Type"), contentType) {
			t.Errorf("GET %s = %d %s, want %s", name, res.StatusCode,
				res.Header.Get("Content-Type"), contentType)
		}
	}
	if res, err := http.Get(srv.URL + "/static/nope.css"); err != nil {
		t.Fatal(err)
	} else {
		res.Body.Close()
		if res.StatusCode != http.StatusNotFound {
			t.Errorf("GET /static/nope.css = %d, want 404", res.StatusCode)
		}
	}

	// The API surface rides the same port, untouched.
	res, err = http.Get(srv.URL + "/v1/runs")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if body := readAll(t, res); body != `{"runs":[]}` {
		t.Errorf("GET /v1/runs = %q, want the API's own answer", body)
	}
	if res, err := http.Get(srv.URL + "/v1/nope"); err != nil {
		t.Fatal(err)
	} else {
		res.Body.Close()
		if res.StatusCode != http.StatusNotFound {
			t.Errorf("GET /v1/nope = %d, want the API's 404", res.StatusCode)
		}
	}
}

// AC15 (SPEC-044 M8): a chiefd shutdown journals no run event. The real
// main.run serves with a run in flight, SIGTERM stops it, and the journal
// gains no row — no halted:operator_halt, no halt row of any reason. chiefd
// passes its signal context as the chief's base context, so the shutdown is
// the quiet path agent.Supervise takes, never an operator stop; the operator
// halt belongs to the stop verb.
func TestChiefdShutdownJournalsNoRunEvent(t *testing.T) {
	dir := t.TempDir()
	db := filepath.Join(dir, "run.db")
	runID := "CDT-660"
	const owner = "chiefd-shutdown-test"

	eng, err := journal.OpenPath(context.Background(), db)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = eng.Close() })

	// One in-flight run: claimed, started, live lease. A shutdown that
	// derived a halt from its own signal adds a run_halted row to this run.
	m := runmachine.New(eng, runID)
	token, err := m.Claim(context.Background(), owner, "CDT-660", "orchestrate", "sonnet")
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Start(context.Background(), owner, token, "sonnet"); err != nil {
		t.Fatal(err)
	}
	before, err := eng.Events(context.Background(), runID)
	if err != nil {
		t.Fatal(err)
	}

	// The child binds an ephemeral loopback port, so readiness is the serving
	// line on stdout — never a probe of a port the test guessed. Its streams
	// are files: the parent reads them after the child exits, so no buffer is
	// read while the exec copier writes it.
	out, err := os.Create(filepath.Join(dir, "chiefd.out"))
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = out.Close() }()
	errLog, err := os.Create(filepath.Join(dir, "chiefd.err"))
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = errLog.Close() }()

	cmd := exec.Command(os.Args[0])
	cmd.Env = append(os.Environ(),
		helperArgsEnv+"=--addr\n127.0.0.1:0\n--db\n"+db+"\n",
		"DEVTEAM_MROOT="+dir,
		"DEVTEAM_RUN_DB="+db,
		"DEVTEAM_STALL_LIMIT=270",
	)
	cmd.Stdout, cmd.Stderr = out, errLog
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	// One goroutine owns cmd.Wait; the deadline kills the child so the wait
	// always lands and a hang is a failure, never a leak.
	waited := make(chan error, 1)
	go func() { waited <- cmd.Wait() }()

	stdout := waitForFile(t, out.Name(), "chief: serving", 20*time.Second, cmd, waited)
	if strings.Contains(stdout, "panic") {
		t.Fatalf("chiefd served with a panic: %s", stdout)
	}

	if err := cmd.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatalf("SIGTERM: %v", err)
	}
	select {
	case err := <-waited:
		if err != nil {
			t.Fatalf("chiefd after SIGTERM: %v\nstdout: %s\nstderr: %s",
				err, read(t, out.Name()), read(t, errLog.Name()))
		}
	case <-time.After(20 * time.Second):
		_ = cmd.Process.Kill()
		<-waited
		t.Fatalf("chiefd did not exit after SIGTERM\nstdout: %s\nstderr: %s",
			read(t, out.Name()), read(t, errLog.Name()))
	}

	after, err := eng.Events(context.Background(), runID)
	if err != nil {
		t.Fatal(err)
	}
	if len(after) != len(before) {
		t.Errorf("journal rows went %d → %d across the shutdown, want no write",
			len(before), len(after))
	}
	if n := countKind(t, eng, runID, journal.KindRunHalted); n != 0 {
		t.Errorf("run_halted rows = %d, want none (AC15: no halt row of any reason)", n)
	}
	if st := state(t, eng, runID); st.Status != journal.StatusRunning {
		t.Errorf("state after the shutdown = %s, want running", st.Name())
	}
	// The lease waits for expiry so the takeover scan can take the run over.
	lease, err := runmachine.New(eng, runID).ReadLease(context.Background())
	if err != nil {
		t.Fatalf("lease after the shutdown: %v", err)
	}
	if lease.Owner != owner || lease.Token == 0 {
		t.Errorf("lease after the shutdown = %q token %d, want %q and the live token",
			lease.Owner, lease.Token, owner)
	}
	// No halt, so no page intent either.
	if _, err := os.Stat(filepath.Join(dir, ".claude", "runs", "chief", "notified.jsonl")); !os.IsNotExist(err) {
		t.Errorf("the shutdown wrote the phone-channel record (stat err %v)", err)
	}
}

// waitForFile polls a child's stream for a marker and returns the whole file.
// The deadline covers every path: a marker that never lands kills the child and
// fails the test.
func waitForFile(t *testing.T, path, marker string, timeout time.Duration,
	cmd *exec.Cmd, waited chan error) string {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		raw, err := os.ReadFile(path)
		if err == nil && strings.Contains(string(raw), marker) {
			return string(raw)
		}
		if time.Now().After(deadline) {
			_ = cmd.Process.Kill()
			<-waited
			t.Fatalf("timed out waiting for %q in %s\nstdout: %s",
				marker, filepath.Base(path), string(raw))
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// read returns a file's content, "" when it is unreadable.
func read(t *testing.T, path string) string {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return string(raw)
}

// countKind counts the journal rows of one kind for a run.
func countKind(t *testing.T, eng *journal.Engine, runID string, kind journal.Kind) int {
	t.Helper()
	rows, err := eng.Events(context.Background(), runID)
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, r := range rows {
		if r.Kind == kind {
			n++
		}
	}
	return n
}

// state replays a run, failing the test on the read error.
func state(t *testing.T, eng *journal.Engine, runID string) *journal.State {
	t.Helper()
	st, err := eng.RunState(context.Background(), runID)
	if err != nil {
		t.Fatal(err)
	}
	return st
}

func readAll(t *testing.T, res *http.Response) string {
	t.Helper()
	raw, err := io.ReadAll(res.Body)
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}
