package hostadapter

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/cold-dark-void/claude-dev-team/control-plane/agent"
	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
)

// ---------------------------------------------------------------------------
// SPEC-046 CDT-677 M5/AC3 — the run-scoped non-credential environment channel
// ---------------------------------------------------------------------------

// AC3/M5: the channel's allowlist is exactly the two cap names. The caps are
// not credentials, so no allowlist name is a B7 proven name, and every other
// name refuses fail-closed — no guess, no fallback.
func TestRunEnvChannelAllowlistIsExactlyTheTwoCaps(t *testing.T) {
	want := []string{"AUTOPILOT_WALLCLOCK_CAP", "AUTOPILOT_ITERATION_CAP"}
	got := RunEnvAllowlist()
	if len(got) != len(want) {
		t.Fatalf("allowlist = %q, want %q", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("allowlist[%d] = %q, want %q", i, got[i], want[i])
		}
	}
	got[0] = "PATH"
	if RunEnvAllowlist()[0] != want[0] {
		t.Error("RunEnvAllowlist leaks the package's backing slice")
	}

	// M5: the caps never touch the proven-name table — in either direction.
	for _, n := range want {
		for _, p := range ProvenNames() {
			if p.EnvVar == n {
				t.Errorf("%s is both a cap name and the B7 proven name for %s", n, p.Provider)
			}
		}
	}

	// Any other name refuses: foreign names, near-misses, and the lowercase
	// spelling the channel does not carry.
	for _, name := range []string{"PATH", "HOME", "OPENAI_API_KEY", "DEVTEAM_RUNNER",
		"AUTOPILOT_WALLCLOCK_CAP_X", "AUTOPILOT_WALLCLOCK", "AUTOPILOT_ITERATION_CAPS",
		"autoPilot_wallclock_cap", "AUTOPILOT_ITERATION_cap", "", "PATH=1",
		"AUTOPILOT_WALLCLOCK_CAP ", "AUTOPILOT_ITERATION_CAP=x"} {
		if _, err := runEnvEntry(name, "90"); !errors.Is(err, ErrRunEnvNameNotAllowed) {
			t.Errorf("runEnvEntry(%q) err = %v, want %v", name, err, ErrRunEnvNameNotAllowed)
		}
	}
	for _, name := range want {
		entry, err := runEnvEntry(name, "90")
		if err != nil {
			t.Errorf("runEnvEntry(%q): %v", name, err)
		}
		if entry != name+"=90" {
			t.Errorf("entry = %q, want %q", entry, name+"=90")
		}
		if _, err := runEnvEntry(name, "  "); !errors.Is(err, ErrRunEnvNameNotAllowed) {
			t.Errorf("runEnvEntry(%q, empty) err = %v, want %v", name, err, ErrRunEnvNameNotAllowed)
		}
	}

	// RunCaps renders the channel in allowlist order; 0 is unset (M7: the
	// journal carries 0 = unset); a non-positive set value refuses.
	cases := []struct {
		name string
		caps RunCaps
		want []string
	}{
		{"no caps composes nothing", RunCaps{}, nil},
		{"wallclock only", RunCaps{WallclockCapS: 7200},
			[]string{"AUTOPILOT_WALLCLOCK_CAP=7200"}},
		{"iteration only", RunCaps{IterationCapS: 40},
			[]string{"AUTOPILOT_ITERATION_CAP=40"}},
		{"both ride in allowlist order",
			RunCaps{WallclockCapS: 7200, IterationCapS: 40},
			[]string{"AUTOPILOT_WALLCLOCK_CAP=7200", "AUTOPILOT_ITERATION_CAP=40"}},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			got, err := tc.caps.EnvEntries()
			if err != nil {
				t.Fatalf("EnvEntries: %v", err)
			}
			if len(got) != len(tc.want) {
				t.Fatalf("entries = %q, want %q", got, tc.want)
			}
			for i := range tc.want {
				if got[i] != tc.want[i] {
					t.Errorf("entries[%d] = %q, want %q", i, got[i], tc.want[i])
				}
			}
		})
	}
	for _, tc := range []RunCaps{{WallclockCapS: -1}, {IterationCapS: -1},
		{WallclockCapS: -7200, IterationCapS: 40}} {
		if _, err := tc.EnvEntries(); !errors.Is(err, ErrRunCapsInvalid) {
			t.Errorf("EnvEntries(%+v) err = %v, want %v", tc, err, ErrRunCapsInvalid)
		}
	}

	// A start whose channel refuses never reaches the node agent and writes
	// no journal row (the fail-closed shape of the credential gate).
	f := &fakeAgent{}
	a := newFakeAdapter(f)
	_, err := a.Start(context.Background(), nil, StartRequest{
		RunID: "run-1", Host: HostOmp, RunCaps: RunCaps{IterationCapS: -5},
	})
	if !errors.Is(err, ErrRunCapsInvalid) {
		t.Fatalf("start err = %v, want %v", err, ErrRunCapsInvalid)
	}
	if f.startCount() != 0 {
		t.Error("a refused start reached the node agent")
	}
}

// AC3: the caps reach the runner environment of that run only — through the
// launch env the adapter hands the node agent, which the native runner
// appends to the child environment (agent/runner.go) and the container runner
// carries as docker -e flags (agent/container.go).
func TestCapsReachTheRunnerEnvironmentPerRun(t *testing.T) {
	const credEnv = "OPENAI_API_KEY=sk-probe-value-not-a-secret"

	t.Run("the launch env carries the caps beside the credentials", func(t *testing.T) {
		f := &fakeAgent{}
		a := newFakeAdapter(f)
		_, err := a.Start(context.Background(), nil, StartRequest{
			RunID: "run-1", Host: HostOmp,
			Credentials: []InjectCredential{{ProviderOpenAI, "sk-probe-value-not-a-secret"}},
			RunCaps:     RunCaps{WallclockCapS: 7200, IterationCapS: 40},
		})
		if err != nil {
			t.Fatalf("start: %v", err)
		}
		want := []string{credEnv, "AUTOPILOT_WALLCLOCK_CAP=7200", "AUTOPILOT_ITERATION_CAP=40"}
		got := f.lastStart().Env
		if len(got) != len(want) {
			t.Fatalf("env = %q, want %q", got, want)
		}
		for i := range want {
			if got[i] != want[i] {
				t.Errorf("env[%d] = %q, want %q", i, got[i], want[i])
			}
		}
	})

	// A real native child reads its own environment: the caps of the run
	// that set them are present, and a second run with no caps inherits
	// nothing — the channel is per run, never process-wide.
	t.Run("the native runner gives them to that run's child only", func(t *testing.T) {
		eng := newEngine(t)
		dir := t.TempDir()
		a := &Adapter{Agent: &capsProbeAgent{A: agentNative(io.Discard)}}

		capsFile := filepath.Join(dir, "with-caps.txt")
		t.Setenv("CDT677_TEST_ENV_OUT", capsFile)
		_, err := a.Start(context.Background(), eng, StartRequest{
			RunID: "run-caps", Host: HostOmp, Ticket: "CDT-677",
			Workflow: "orchestrate", Model: "sonnet",
			Credentials: []InjectCredential{{ProviderOpenAI, "sk-probe-value-not-a-secret"}},
			RunCaps:     RunCaps{WallclockCapS: 7200, IterationCapS: 40},
		})
		if err != nil {
			t.Fatalf("start: %v", err)
		}
		// The child writes and exits, so the file lands whole; the wait is
		// the deadline, not an assumption.
		probeFileHas(t, capsFile, "W=[7200] I=[40] K=[sk-probe-value-not-a-secret]")

		bareFile := filepath.Join(dir, "bare.txt")
		t.Setenv("CDT677_TEST_ENV_OUT", bareFile)
		_, err = a.Start(context.Background(), eng, StartRequest{
			RunID: "run-bare", Host: HostOmp, Ticket: "CDT-677",
			Workflow: "orchestrate", Model: "sonnet",
		})
		if err != nil {
			t.Fatalf("start: %v", err)
		}
		probeFileHas(t, bareFile, "W=[unset] I=[unset] K=[unset]")
	})

	// The container runner consumes the same Spec.Env channel and carries
	// each entry as a docker -e flag, so the caps cross into the session
	// container. Docker itself is not execed: the fake CLI records argv.
	t.Run("the container runner carries them as -e flags", func(t *testing.T) {
		home := t.TempDir()
		if err := os.MkdirAll(filepath.Join(home, ".claude"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(home, ".claude.json"), []byte("{}"), 0o644); err != nil {
			t.Fatal(err)
		}
		t.Setenv("HOME", home)

		bin := t.TempDir()
		cli := filepath.Join(bin, "claude")
		if err := os.WriteFile(cli, []byte("#!/bin/sh\n"), 0o755); err != nil {
			t.Fatal(err)
		}
		argvFile := filepath.Join(t.TempDir(), "docker-argv.txt")
		docker := filepath.Join(bin, "docker")
		// The fake client records its argv space-joined, written to a
		// temporary file and renamed so a reader never sees a partial list.
		script := "#!/bin/sh\ntmp=\"$CDT677_TEST_DOCKER_ARGV.tmp\"\n" +
			"printf '%s ' \"$@\" > \"$tmp\"\nprintf '\\n' >> \"$tmp\"\n" +
			"mv \"$tmp\" \"$CDT677_TEST_DOCKER_ARGV\"\n"
		if err := os.WriteFile(docker, []byte(script), 0o755); err != nil {
			t.Fatal(err)
		}
		t.Setenv("CDT677_TEST_DOCKER_ARGV", argvFile)
		t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))

		entries, err := RunCaps{WallclockCapS: 7200, IterationCapS: 40}.EnvEntries()
		if err != nil {
			t.Fatal(err)
		}
		proc, err := agent.Container{DockerBin: docker}.Start(agent.Spec{
			Command: "claude", Args: []string{"-p"}, Env: entries,
			Name: "devteam-run-caps", Dir: t.TempDir(),
		})
		if err != nil {
			t.Fatalf("container start: %v", err)
		}
		if err := proc.Wait(); err != nil {
			t.Fatalf("docker client: %v", err)
		}
		argv := probeFileHas(t, argvFile, "-e HOME="+home,
			"-e AUTOPILOT_WALLCLOCK_CAP=7200", "-e AUTOPILOT_ITERATION_CAP=40")
		// The caps ride docker -e flags: the image token ends the docker
		// arguments, so the session command tail must carry none of them
		// (SPEC-046 MUST NOT: no cap in the command line).
		if i := strings.Index(argv, agent.SessionImage); i >= 0 {
			if tail := argv[i:]; strings.Contains(tail, "AUTOPILOT_") {
				t.Errorf("a cap rode the session command: %s", tail)
			}
		} else {
			t.Errorf("docker argv carries no session image: %s", argv)
		}
	})
}

// AC3/M5 + the MUST NOT list: the caps ride the launch environment and
// nothing else. They never enter the host argv, the premise, or the chiefd
// process environment, and one run's caps never reach another run's launch.
func TestCapsNeverRideTheCommandOrUnitEnv(t *testing.T) {
	unitWallclock, hadWallclock := os.LookupEnv("AUTOPILOT_WALLCLOCK_CAP")
	unitIteration, hadIteration := os.LookupEnv("AUTOPILOT_ITERATION_CAP")

	for _, h := range []Host{HostClaudeCode, HostGrok, HostOmp} {
		f := &fakeAgent{}
		a := newFakeAdapter(f)
		_, err := a.Start(context.Background(), nil, StartRequest{
			RunID: "run-1", Ticket: "CDT-677", Workflow: "orchestrate",
			Model: "sonnet", Host: h, Premise: "/orchestrate CDT-677 --autopilot=master",
			RunCaps: RunCaps{WallclockCapS: 7200, IterationCapS: 40},
		})
		if err != nil {
			t.Fatalf("start %s: %v", h, err)
		}
		req := f.lastStart()
		joined := strings.Join(append([]string{req.Command}, req.Args...), " ") +
			" " + req.Premise
		for _, banned := range []string{"AUTOPILOT_", "7200", "=40"} {
			if strings.Contains(joined, banned) {
				t.Errorf("%s: cap text %q left the environment channel: %s", h, banned, joined)
			}
		}
		want := []string{"AUTOPILOT_WALLCLOCK_CAP=7200", "AUTOPILOT_ITERATION_CAP=40"}
		if len(req.Env) != len(want) {
			t.Fatalf("%s: env = %q, want %q", h, req.Env, want)
		}
	}

	// Per-run isolation on the channel: the run that sets no caps composes
	// an env with no cap entries, on the adapter that just started a capped
	// run.
	f := &fakeAgent{}
	a := newFakeAdapter(f)
	_, err := a.Start(context.Background(), nil, StartRequest{
		RunID: "run-a", Host: HostOmp, RunCaps: RunCaps{WallclockCapS: 7200},
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = a.Start(context.Background(), nil, StartRequest{RunID: "run-b", Host: HostOmp}); err != nil {
		t.Fatal(err)
	}
	if got := f.starts[0].Env; len(got) != 1 || got[0] != "AUTOPILOT_WALLCLOCK_CAP=7200" {
		t.Errorf("capped run env = %q", got)
	}
	for _, e := range f.starts[1].Env {
		if strings.HasPrefix(e, "AUTOPILOT_") {
			t.Errorf("the uncapped run inherited a cap: %q", e)
		}
	}

	// The chiefd unit environment is process-wide and stays clean: the
	// adapter writes entries into a slice, never into the process env.
	if got, ok := os.LookupEnv("AUTOPILOT_WALLCLOCK_CAP"); got != unitWallclock || ok != hadWallclock {
		t.Errorf("unit env AUTOPILOT_WALLCLOCK_CAP = %q (present %v) after starts", got, ok)
	}
	if got, ok := os.LookupEnv("AUTOPILOT_ITERATION_CAP"); got != unitIteration || ok != hadIteration {
		t.Errorf("unit env AUTOPILOT_ITERATION_CAP = %q (present %v) after starts", got, ok)
	}
}

// capsProbeAgent is the NodeAgent seam of the environment probe: it keeps the
// adapter's launch env and swaps the host CLI for a shell that records the
// three names the run must carry into $CDT677_TEST_ENV_OUT.
type capsProbeAgent struct {
	A *agent.Agent
}

func (p *capsProbeAgent) Supervise(ctx context.Context, eng *journal.Engine,
	req agent.StartRequest, sessionOut io.Writer) error {
	req.Command, req.Args = "sh", []string{"-c",
		`printf '%s\n' '{"type":"session","version":3,"id":"01a1ddda-7a27"}'; ` +
			`printf 'W=[%s] I=[%s] K=[%s]\n' ` +
			`"${AUTOPILOT_WALLCLOCK_CAP-unset}" "${AUTOPILOT_ITERATION_CAP-unset}" ` +
			`"${OPENAI_API_KEY-unset}" > "$CDT677_TEST_ENV_OUT"`}
	p.A.Runner = agent.Native{Stdout: sessionOut, Stderr: io.Discard}
	return p.A.Supervise(ctx, eng, req)
}

func (p *capsProbeAgent) Stop(ctx context.Context, eng *journal.Engine,
	runID string, grace time.Duration) error {
	return p.A.Stop(ctx, eng, runID, grace)
}

func (p *capsProbeAgent) Steer(ctx context.Context, eng *journal.Engine,
	runID, message string) error {
	return p.A.Steer(ctx, eng, runID, message)
}

func (p *capsProbeAgent) Status(ctx context.Context, eng *journal.Engine,
	runID string) (agent.StatusReport, error) {
	return p.A.Status(ctx, eng, runID)
}

// probeFileHas waits — bounded by a deadline — until the probe file carries
// every wanted fragment, and returns its text. A probe writer appends as it
// exits, so an early read can see a partial file: the fragments are the
// condition, the deadline is the failure.
func probeFileHas(t *testing.T, path string, want ...string) string {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	var got string
	for {
		if raw, err := os.ReadFile(path); err == nil {
			got = strings.TrimRight(string(raw), "\n")
			ok := true
			for _, w := range want {
				if !strings.Contains(got, w) {
					ok = false
					break
				}
			}
			if ok {
				return got
			}
		}
		if time.Now().After(deadline) {
			t.Fatalf("probe file %s never carried %q; last text: %q", path, want, got)
		}
		time.Sleep(25 * time.Millisecond)
	}
}
