package agent

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// testContainer is a Container wired for hermetic planning: a fake lookup
// that resolves every command to a stable host path, a fixed user and home,
// and a state-mount row that needs no host CLI login.
func testContainer(t *testing.T) Container {
	t.Helper()
	home := t.TempDir()
	state := filepath.Join(home, ".claude")
	if err := os.MkdirAll(state, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, ".claude.json"), []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}
	cli := filepath.Join(t.TempDir(), "claude")
	if err := os.WriteFile(cli, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return Container{
		lookPath: func(cmd string) (string, error) { return cli, nil },
		user:     "1000:1000",
		home:     home,
	}
}

// planOf builds the invocation of one spec, with the test harness above.
func planOf(t *testing.T, c Container, spec Spec) containerPlan {
	t.Helper()
	plan, err := c.plan(spec)
	if err != nil {
		t.Fatalf("plan: %v", err)
	}
	return plan
}

// AC: the session image is named and digest-pinned — never a tag, never an
// unpinned reference (CDT-647 AC5).
func TestSessionImageIsNamedAndDigestPinned(t *testing.T) {
	if !digestPinned(SessionImage) {
		t.Fatalf("session image %q is not a name@sha256 pin", SessionImage)
	}
	if !strings.HasPrefix(SessionImage, "docker.io/library/") {
		t.Errorf("session image %q is not an official-library reference", SessionImage)
	}
}

// AC: the invocation is one container per run, named after the run, with the
// worktree and the main repo root mounted at their host paths (Fact 3), the
// host session state mounted read-write (Fact 2), and the host CLI binary
// mounted read-only (Fact 4).
func TestContainerPlanBuildsTheSessionInvocation(t *testing.T) {
	c := testContainer(t)
	wt := t.TempDir()
	root := filepath.Join(wt, "..", "main-repo")
	if err := os.WriteFile(filepath.Join(wt, ".git"),
		[]byte("gitdir: "+root+"/.git/worktrees/CDT-647\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	plan := planOf(t, c, Spec{
		Command: "claude", Args: []string{"-p", "--resume", "s1"},
		Env: []string{"OMP_PROVIDER_KEY=dummy"}, Name: containerName("run-1"),
		Dir: wt,
	})

	argv := plan.argv
	if argv[0] != "run" {
		t.Fatalf("argv[0] = %q, want run", argv[0])
	}
	if got := strings.Join(argv, " "); !strings.Contains(got, "--name "+containerName("run-1")) {
		t.Errorf("argv does not name the run's container: %s", got)
	}
	// One container per run carries the worktree and the main repo root at
	// their host paths, so resume state survives over the mounted paths.
	for _, want := range []string{
		"-v " + wt + ":" + wt,
		"-v " + root + ":" + root,
		"-v " + c.home + "/.claude:" + c.home + "/.claude",
		"-v " + c.home + "/.claude.json:" + c.home + "/.claude.json",
		"-w " + wt,
		"-e HOME=" + c.home,
		"-e OMP_PROVIDER_KEY=dummy",
	} {
		if !strings.Contains(strings.Join(argv, " "), want) {
			t.Errorf("argv lacks %q: %s", want, strings.Join(argv, " "))
		}
	}
	// The host CLI binary rides read-only (Fact 4).
	if !strings.Contains(strings.Join(argv, " "), ":ro") {
		t.Errorf("argv carries no read-only mount: %s", strings.Join(argv, " "))
	}
	// The image rides before the command argv, pinned; the session command
	// rides after the prelude's exec tail, as argv (never inside the shell
	// string).
	idx := -1
	for i, tok := range argv {
		if tok == SessionImage {
			idx = i
		}
	}
	if idx < 0 {
		t.Fatalf("argv does not carry the pinned session image: %s", strings.Join(argv, " "))
	}
	if argv[idx+1] != "sh" || argv[idx+4] != "session" || argv[idx+5] != "claude" {
		t.Errorf("session argv after the image = %v, want the prelude + exec tail carrying claude", argv[idx+1:])
	}
	if !strings.Contains(sessionPreludeFmt, `exec setpriv --reuid=%d --regid=%d --clear-groups "$@"`) {
		t.Errorf("the prelude must exec the session from argv under the host uid: %q", sessionPreludeFmt)
	}
	// The session drops to the host uid after the prelude (AC-5 item-4
	// hygiene; Fact 3).
	if !strings.Contains(strings.Join(argv, " "), "--reuid=1000 --regid=1000") {
		t.Errorf("argv does not drop the session to the host uid: %s", strings.Join(argv, " "))
	}
}

// AC: the main checkout's .git is a directory — the repo-root mount must not
// duplicate the worktree mount (Fact 3 P-CON-B).
func TestContainerPlanDoesNotDuplicateTheMainCheckoutMount(t *testing.T) {
	c := testContainer(t)
	wt := t.TempDir()
	if err := os.MkdirAll(filepath.Join(wt, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	plan := planOf(t, c, Spec{Command: "claude", Name: containerName("run-1"), Dir: wt})
	mounts := 0
	for _, tok := range plan.argv {
		if tok == wt+":"+wt {
			mounts++
		}
	}
	if mounts != 1 {
		t.Errorf("worktree mounted %d times, want once", mounts)
	}
}

// AC: only the node agent holds the Docker socket — the invocation never
// mounts it, never adds a Docker group, and never widens the container with
// privileged or host-namespace access (CDT-647 AC2). The guard rejects every
// such argv, and a plan that would build one never reaches Docker.
func TestGuardSessionArgvRejectsTheSocketAndTheWidenings(t *testing.T) {
	cases := []struct {
		name string
		argv []string
	}{
		{"socket mount", []string{"run", "-v", "/var/run/docker.sock:/var/run/docker.sock"}},
		{"socket inside a wider mount", []string{"run", "-v", "/var/run:/var/run"}},
		{"socket mount long form", []string{"run", "--volume", "/var/run/docker.sock:/var/run/docker.sock"}},
		{"socket inside a wider mount long form", []string{"run", "--volume", "/var/run:/var/run"}},
		{"docker group", []string{"run", "--group-add", "999"}},
		{"privileged", []string{"run", "--privileged"}},
		{"host pid namespace", []string{"run", "--pid=host"}},
		{"host user namespace", []string{"run", "--userns=host"}},
		{"host network", []string{"run", "--network=host"}},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			if err := guardSessionArgv(tc.argv); err == nil {
				t.Fatalf("guard accepted %v", tc.argv)
			} else if !errors.Is(err, ErrSocketLeak) {
				t.Fatalf("guard error = %v, want ErrSocketLeak", err)
			}
		})
	}
}

// The plan of a real invocation passes the guard.
func TestContainerPlanPassesItsOwnGuard(t *testing.T) {
	c := testContainer(t)
	wt := t.TempDir()
	plan := planOf(t, c, Spec{Command: "claude", Name: containerName("run-1"), Dir: wt})
	if err := guardSessionArgv(plan.argv); err != nil {
		t.Fatalf("guard rejected the plan's own argv: %v", err)
	}
}

// Fail-closed refuses, before Docker is exec'd and before any journal row.
func TestContainerPlanRefusesFailClosed(t *testing.T) {
	t.Run("no docker CLI", func(t *testing.T) {
		c := testContainer(t)
		c.lookPath = func(cmd string) (string, error) {
			if cmd == "docker" {
				return "", exec.ErrNotFound
			}
			return "/usr/bin/" + cmd, nil
		}
		_, err := c.plan(Spec{Command: "claude", Name: containerName("run-1")})
		if !errors.Is(err, ErrNoDocker) {
			t.Fatalf("err = %v, want ErrNoDocker", err)
		}
	})
	t.Run("host CLI without container probe facts", func(t *testing.T) {
		c := testContainer(t)
		_, err := c.plan(Spec{Command: "mini-swe", Name: containerName("run-1")})
		if !errors.Is(err, ErrUnknownSessionHost) {
			t.Fatalf("err = %v, want ErrUnknownSessionHost", err)
		}
	})
	t.Run("missing host session state", func(t *testing.T) {
		c := testContainer(t)
		c.home = t.TempDir()
		_, err := c.plan(Spec{Command: "claude", Name: containerName("run-1")})
		if !errors.Is(err, ErrHostStateMissing) {
			t.Fatalf("err = %v, want ErrHostStateMissing", err)
		}
	})
	t.Run("container name outside the run namespace", func(t *testing.T) {
		c := testContainer(t)
		if _, err := c.plan(Spec{Command: "claude", Name: "someone-elses-container"}); !errors.Is(err, ErrRunID) {
			t.Fatalf("err = %v, want ErrRunID", err)
		}
	})
	t.Run("start without a name", func(t *testing.T) {
		c := testContainer(t)
		if _, err := c.Start(Spec{Command: "claude"}); !errors.Is(err, ErrNoContainerName) {
			t.Fatalf("err = %v, want ErrNoContainerName", err)
		}
	})
	t.Run("start without a command", func(t *testing.T) {
		c := testContainer(t)
		if _, err := c.Start(Spec{Name: containerName("run-1")}); !errors.Is(err, ErrNoCommand) {
			t.Fatalf("err = %v, want ErrNoCommand", err)
		}
	})
}

// The pidfile of a container run records the container name and the runner
// type; a pre-CDT-647 record reads back as a native run.
func TestPidRecordCarriesTheRunner(t *testing.T) {
	t.Run("container record", func(t *testing.T) {
		dir := t.TempDir()
		t.Setenv("DEVTEAM_MROOT", dir)
		rec := pidRecord{RunnerPID: 4242, SupervisorPID: 8484, StartedTS: 1,
			RunnerType: RunnerContainer, Container: containerName("run-1")}
		if err := writePIDRecord("run-1", rec); err != nil {
			t.Fatal(err)
		}
		got, err := readPIDFile("run-1")
		if err != nil {
			t.Fatal(err)
		}
		if got.Container != containerName("run-1") || got.RunnerType != RunnerContainer {
			t.Fatalf("record = %+v", got)
		}
	})
	t.Run("pre-CDT-647 record reads native", func(t *testing.T) {
		dir := t.TempDir()
		t.Setenv("DEVTEAM_MROOT", dir)
		if err := writePIDFile("run-1", 4242, 8484); err != nil {
			t.Fatal(err)
		}
		got, err := readPIDFile("run-1")
		if err != nil {
			t.Fatal(err)
		}
		if got.Container != "" || got.RunnerType != "" {
			t.Fatalf("record = %+v, want the native zero record", got)
		}
	})
}

// --- Live container tests -------------------------------------------------
//
// These exercise the real runner against the pinned session image and skip
// wherever Docker is unavailable — the G-02 test container has no Docker
// socket, so the CI lane runs the hermetic half above only. The image is the
// G-02 row-1 approved reference (container-runner.md); no unapproved image is
// pulled or run by these tests.

func liveDocker(t *testing.T) string {
	t.Helper()
	bin, err := exec.LookPath("docker")
	if err != nil {
		t.Skip("docker CLI not on PATH")
	}
	if err := exec.Command(bin, "info", "--format", "ok").Run(); err != nil {
		t.Skip("docker daemon unreachable")
	}
	return bin
}

// liveContainer is a Container whose session mounts a scratch state file, so
// the live tests need no host CLI login. The session interpreter is the
// image's own dash, extracted from the approved image: a host shell carries
// host-only libraries (the Fact 4 lesson — the probed CLIs themselves are
// glibc-only, the test's convenience shell is not).
func liveContainer(t *testing.T) Container {
	t.Helper()
	bin := liveDocker(t)
	sh := extractImageShell(t, bin)
	home := t.TempDir()
	state := filepath.Join(home, ".claude")
	if err := os.MkdirAll(state, 0o755); err != nil {
		t.Fatal(err)
	}
	return Container{
		DockerBin: bin,
		home:      home,
		lookPath: func(cmd string) (string, error) {
			if cmd == bin || cmd == "docker" {
				return bin, nil
			}
			if cmd == "sh" {
				return sh, nil
			}
			return "", exec.ErrNotFound
		},
		stateMounts: func(cmd string) []containerMount {
			return []containerMount{{source: state, target: state}}
		},
	}
}

// extractImageShell copies the approved image's own /bin/sh onto the host, so
// the live sessions run an interpreter the image is known to serve.
func extractImageShell(t *testing.T, docker string) string {
	t.Helper()
	out := filepath.Join(t.TempDir(), "sh")
	out, err := filepath.Abs(out)
	if err != nil {
		t.Fatal(err)
	}
	cid, err := exec.Command(docker, "create", SessionImage).Output()
	if err != nil {
		t.Fatalf("create scratch container: %v", err)
	}
	id := strings.TrimSpace(string(cid))
	defer exec.Command(docker, "rm", "-f", id).Run()
	// /bin/sh in the image is a symlink to dash; copy the real binary.
	if err := exec.Command(docker, "cp", id+":/bin/dash", out).Run(); err != nil {
		t.Fatalf("copy the image shell: %v", err)
	}
	return out
}

// AC: the contract is unchanged — start tracks the container, steer delivers
// through the client's stdin, and stop is SIGTERM then SIGKILL after the
// grace, here observed as the trap handler firing inside the session.
func TestContainerRunnerStartSteersAndStopsLive(t *testing.T) {
	c := liveContainer(t)
	wt := t.TempDir()
	steered := filepath.Join(wt, "steered.txt")
	p, err := c.Start(Spec{
		Command: "sh",
		Args: []string{"-c",
			// The wait loop is the trap-interruptible wait: a foreground
			// sleep would defer the TERM trap past the stop grace.
			`read l; printf '%s' "$l" > ` + steered + `; trap 'touch ` + wt + `/termed; exit 0' TERM; while :; do sleep 1 & wait $!; done`},
		Name: containerName("live-steer"),
		Dir:  wt,
	})
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	if p.PID() <= 0 {
		t.Fatalf("pid = %d, want the tracked client pid", p.PID())
	}
	msg := "steer-me-at-the-boundary"
	if err := p.Steer(msg); err != nil {
		t.Fatalf("steer: %v", err)
	}
	// The session writes the steered message into the mounted worktree, so
	// the host observes the delivery without the container's own streams.
	// The window rides out the prelude's package install (~15 s observed).
	waitForMount(t, 90*time.Second, func() bool {
		raw, err := os.ReadFile(steered)
		return err == nil && string(raw) == msg
	})
	if err := p.Stop(5 * time.Second); err != nil {
		t.Fatalf("stop: %v", err)
	}
	waitForMount(t, 5*time.Second, func() bool {
		_, err := os.Stat(filepath.Join(wt, "termed"))
		return err == nil
	})
	if live, _ := c.ContainerRunning(containerName("live-steer")); live {
		t.Error("container still running after the stop")
	}
}

// AC: only the node agent holds the Docker socket — a live session observes
// the socket absent from its own mount namespace.
func TestContainerSessionNeverSeesTheDockerSocketLive(t *testing.T) {
	c := liveContainer(t)
	var out strings.Builder
	c.Stdout = &out
	p, err := c.Start(Spec{
		Command: "sh",
		Args:    []string{"-c", `if [ -e /var/run/docker.sock ]; then echo present; else echo absent; fi`},
		Name:    containerName("live-socket"),
	})
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	defer p.Stop(0)
	select {
	case err := <-p.Done():
		if err != nil {
			t.Fatalf("session exit: %v", err)
		}
	case <-time.After(30 * time.Second):
		t.Fatal("session did not exit")
	}
	// The observed output, not the exit code, is the receipt: the session
	// must have seen the socket absent from inside its own container. Done
	// can outrun the drain goroutine by a few bytes, so poll briefly.
	deadline := time.Now().Add(2 * time.Second)
	for {
		if got := out.String(); strings.Contains(got, "absent") {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("session output does not assert socket absence: %q", out.String())
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// AC: resume survives container death over the mounted paths — state the
// first container writes into the mounted worktree is the second container's
// starting state, with no host action in between (container-runner.md AC-9
// restart rows).
func TestContainerResumeSurvivesDeathOverTheMountedPathsLive(t *testing.T) {
	c := liveContainer(t)
	wt := t.TempDir()
	stateFile := filepath.Join(wt, "session-state.txt")

	first, err := c.Start(Spec{
		Command: "sh",
		Args:    []string{"-c", `printf 'resumable-state' > ` + stateFile + `; echo done`},
		Name:    containerName("live-resume"),
		Dir:     wt,
	})
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	select {
	case err := <-first.Done():
		if err != nil {
			t.Fatalf("first session exit: %v", err)
		}
	case <-time.After(30 * time.Second):
		t.Fatal("first session did not exit")
	}

	// The death of the first container is the crash; the second run resumes
	// from the mounted state.
	second, err := c.Start(Spec{
		Command: "sh",
		Args: []string{"-c",
			`cp ` + stateFile + ` ` + stateFile + `.resumed; echo resumed`},
		Name: containerName("live-resume"),
		Dir:  wt,
	})
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	defer second.Stop(0)
	select {
	case err := <-second.Done():
		if err != nil {
			t.Fatalf("second session exit: %v", err)
		}
	case <-time.After(30 * time.Second):
		t.Fatal("second session did not exit")
	}
	raw, err := os.ReadFile(stateFile + ".resumed")
	if err != nil {
		t.Fatalf("resumed state: %v", err)
	}
	if string(raw) != "resumable-state" {
		t.Errorf("resumed state = %q, want resumable-state", raw)
	}
}

// waitForMount polls cond until it holds or the timeout passes.
func waitForMount(t *testing.T, timeout time.Duration, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal("condition did not hold in time")
}

// --- Hermetic stop and probe tests -----------------------------------------
//
// A docker CLI stub stands in for the daemon, so the stop contract and the
// liveness probe are exercised where Docker cannot be reached — exactly the
// failure modes they must answer.

// stubDocker writes a docker CLI stub that prints one line and exits code,
// and returns its path.
func stubDocker(t *testing.T, code int, line string) string {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "docker")
	script := fmt.Sprintf("#!/bin/sh\nprintf '%%s\\n' %q\nexit %d\n", line, code)
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return bin
}

// stubContainer is a Container whose docker CLI is the given stub.
func stubContainer(bin string) Container {
	return Container{
		lookPath: func(cmd string) (string, error) {
			if cmd == "docker" {
				return bin, nil
			}
			return "", exec.ErrNotFound
		},
	}
}

// AC: the adoption path's StopContainer carries no client process. When the
// daemon is unreachable, it surfaces the docker error — it must not panic on
// the synthetic process's nil cmd, and must not invent a client signal.
func TestStopContainerSurfacesDaemonFailureWithoutPanic(t *testing.T) {
	bin := stubDocker(t, 1,
		"Cannot connect to the Docker daemon at unix:///var/run/docker.sock")
	c := stubContainer(bin)
	err := c.StopContainer(containerName("run-1"), time.Second)
	if err == nil {
		t.Fatal("stop against an unreachable daemon answered nil, want an error")
	}
	if !strings.Contains(err.Error(), "Cannot connect to the Docker daemon") {
		t.Fatalf("stop err = %v, want the daemon failure", err)
	}
}

// AC: a container that already exited answers "No such container" and the
// stop stays idempotent — not an error.
func TestStopContainerKeepsTheNoSuchContainerIdempotence(t *testing.T) {
	bin := stubDocker(t, 1,
		"Error response from daemon: No such container: "+containerName("run-1"))
	c := stubContainer(bin)
	if err := c.StopContainer(containerName("run-1"), time.Second); err != nil {
		t.Fatalf("stop of an already-exited container = %v, want nil", err)
	}
}

// AC: the liveness probe reports Docker's own reading. A container Docker
// does not know is not running; any other inspect failure surfaces as an
// error, so a flaky daemon never reads a live orphan as confidently dead
// and the adoption policy never silently skips its stop.
func TestContainerRunningDistinguishesMissingFromAnUnreachableDaemon(t *testing.T) {
	t.Run("docker's own true reading", func(t *testing.T) {
		c := stubContainer(stubDocker(t, 0, "true"))
		live, err := c.ContainerRunning(containerName("run-1"))
		if err != nil || !live {
			t.Fatalf("running = %v, %v, want true, nil", live, err)
		}
	})
	t.Run("docker's own false reading", func(t *testing.T) {
		c := stubContainer(stubDocker(t, 0, "false"))
		live, err := c.ContainerRunning(containerName("run-1"))
		if err != nil || live {
			t.Fatalf("running = %v, %v, want false, nil", live, err)
		}
	})
	t.Run("missing container is not running", func(t *testing.T) {
		c := stubContainer(stubDocker(t, 1,
			"Error: No such object: "+containerName("run-1")))
		live, err := c.ContainerRunning(containerName("run-1"))
		if err != nil || live {
			t.Fatalf("running = %v, %v, want false, nil", live, err)
		}
	})
	t.Run("unreachable daemon is an error", func(t *testing.T) {
		c := stubContainer(stubDocker(t, 1,
			"Cannot connect to the Docker daemon at unix:///var/run/docker.sock"))
		live, err := c.ContainerRunning(containerName("run-1"))
		if err == nil {
			t.Fatal("inspect against an unreachable daemon answered nil, want an error")
		}
		if live {
			t.Error("an unreachable daemon must not read as running")
		}
		if !strings.Contains(err.Error(), "Cannot connect to the Docker daemon") {
			t.Fatalf("inspect err = %v, want the daemon failure", err)
		}
	})
}
