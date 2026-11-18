package agent

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// SessionImage is the session image of the container runner: one container
// per run, built from this exact reference — a name@sha256 digest pin, never
// a tag. The reference is the image every host-CLI container probe ran on
// (docs/internal/control-plane/container-runner.md § AC-6 and § AC-9 — the
// G-02 row-1 approval, official Docker Library debian, trixie-slim), so the
// probe facts are the probe facts for this image and no other. Its promotion
// from the probe record to this product reference is presented to the
// maintainer at the G-02 gate with the same evidence: source repo
// (debuerreotype/docker-debian-artifacts), official-library status, active
// maintenance, root inside the container — the runner starts it --user
// matched to the node's own uid. No unpinned, unverified, or probe-only
// image is referenced here.
const SessionImage = "docker.io/library/debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2"

// sessionPreludeFmt is the fixed prelude a session runs before the host CLI
// execs, with the host uid and gid substituted. The package set is the one
// the G-02 row-1 record pre-approved for this image (container-runner.md §
// gate state — apt-get install git curl ca-certificates): the repo toolchain
// the session's work needs (Fact 4: git), nothing more. Root installs it —
// apt is root-only — and then setpriv drops the session to the host uid, so
// the container writes the mounted host paths as the host user (the AC-5
// item-4 hygiene) and git's safe.directory guard never fires (Fact 3). The
// session argv travels as argv after the script (the `exec "$@"` tail), so
// no untrusted text is ever assembled into the shell string (the AGENTS.md
// trust rule): the prelude is a constant plus the node's own uid, the
// session command is data.
const sessionPreludeFmt = "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git curl ca-certificates && exec setpriv --reuid=%d --regid=%d --clear-groups \"$@\""

// sessionImagePin checks the pin shape of SessionImage at init: an image
// reference without an explicit digest refuses to load, so a hand edit that
// drops the pin fails at build time, not at first pull.
func init() {
	if !digestPinned(SessionImage) {
		panic(fmt.Sprintf("agent: session image %q is not a name@sha256 digest pin", SessionImage))
	}
}

// digestPinned reports whether ref carries an explicit sha256 digest.
func digestPinned(ref string) bool {
	_, digest, ok := strings.Cut(ref, "@sha256:")
	if !ok {
		return false
	}
	return regexp.MustCompile(`^[0-9a-f]{64}$`).MatchString(digest)
}

// containerName is the Docker container name of one run: one container per
// run, named after it. The run id is validated against runIDRE, which is
// also the Docker name shape, so the derived name is always legal.
func containerName(runID string) string { return "devteam-run-" + runID }

// containerStopper is the capability a runner carries when it supervises
// containers: the agent's adoption policy and stop verb need a container
// stop by name, because a container outlives the client process that
// created it and cannot be signalled through a host PID.
type containerStopper interface {
	// ContainerRunning reports Docker's own liveness reading for the named
	// container.
	ContainerRunning(name string) (bool, error)
	// StopContainer stops the named container: SIGTERM to its init, SIGKILL
	// after the grace — the stop contract at the container boundary.
	StopContainer(name string, grace time.Duration) error
}

// hostStateDirs is the per-host session-state mount table, keyed by the host
// CLI basename. It is sourced from container-runner.md — the AC-9 container
// rows name each host's state directory, and Fact 2 fixes the writability
// rule: token refresh targets the same file, so the state mount is
// read-write (the B6 conservative contract for the unprobed forced-refresh
// case). A host CLI outside this table has no probed container facts and is
// refused fail-closed — the matrix rows are the source
// (docs/internal/control-plane/host-capability-matrix.md § AC-1).
var hostStateDirs = map[string]string{
	"claude": ".claude",
	"grok":   ".grok",
	"omp":    ".omp",
}

// Container is the container runner: one container per run, the run's
// worktree bind-mounted at its host path (container-runner.md Fact 3), the
// host CLI binary mounted read-only into the container (Fact 4), and the
// host's session state mounted read-write so resume and a token refresh
// survive a container death over the mounted paths (Fact 2 — the AC-9
// restart rows).
//
// The node agent is the only holder of the Docker socket. The invocation
// never mounts it into the session container, never adds a Docker group,
// and never grants privileged or host-namespace access: guardSessionArgv
// enforces that on every argv this runner builds, and the tests hold the
// guard against each case.
type Container struct {
	// Stdout and Stderr are the session's output sinks, nil meaning the
	// agent's own.
	Stdout io.Writer
	Stderr io.Writer
	// DockerBin names the Docker CLI binary on the node; empty means PATH.
	// The runner execs the CLI — it never opens the socket itself.
	DockerBin string

	// Test hooks, nil in production.
	lookPath    func(string) (string, error)
	user        string // "uid:gid"; empty means the agent process's own
	home        string // the host home dir; empty means the agent's own
	stateMounts func(cmd string) []containerMount
	getwd       func() (string, error)
}

// Name is the runner's selection token.
func (Container) Name() RunnerType { return RunnerContainer }

// containerMount is one bind mount of the session container.
type containerMount struct {
	source string
	target string
	ro     bool
}

// containerPlan is one fully-built invocation: the docker argv, the binary
// that execs it, and the container name. The plan is built before any
// journal row is written, so a refuse happens with nothing recorded.
type containerPlan struct {
	bin  string
	argv []string
	name string
}

// Start spawns one session container for spec and returns it as a Process.
// The supervised process is the Docker client that owns the container:
// its stdin is the container's stdin (steer rides it unchanged), its exit
// is the container's exit, and its streams carry the container's output.
// A refuse never reaches Docker: the plan is built and guarded first.
func (c Container) Start(spec Spec) (Process, error) {
	if spec.Command == "" {
		return nil, ErrNoCommand
	}
	if spec.Name == "" {
		return nil, ErrNoContainerName
	}
	plan, err := c.plan(spec)
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(plan.bin, plan.argv...)
	cmd.Dir = spec.Dir
	if len(spec.Env) > 0 {
		// The host-side docker client needs no extra environment; the spec's
		// env entries ride the argv into the container (the plan carries
		// them as -e flags). The client inherits the agent's environment
		// only for its own work — none of it crosses into the container.
		cmd.Env = append(os.Environ(), spec.Env...)
	}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, fmt.Errorf("agent: stdin pipe: %w", err)
	}
	outR, outW, err := os.Pipe()
	if err != nil {
		return nil, fmt.Errorf("agent: stdout pipe: %w", err)
	}
	errR, errW, err := os.Pipe()
	if err != nil {
		return nil, fmt.Errorf("agent: stderr pipe: %w", err)
	}
	cmd.Stdout, cmd.Stderr = outW, errW
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("agent: docker run %s: %w", spec.Name, err)
	}
	// The agent holds no write end: the client owns the stream. Wait is done
	// the moment the client's own process exits.
	_ = outW.Close()
	_ = errW.Close()
	go drain(outR, sink(c.Stdout, os.Stdout))
	go drain(errR, sink(c.Stderr, os.Stderr))

	p := &containerProcess{
		cmd: cmd, stdin: stdin, done: make(chan error, 1),
		bin: plan.bin, name: plan.name,
	}
	go func() {
		p.doneOnce.Do(func() { p.waitErr = cmd.Wait() })
		close(p.done)
	}()
	return p, nil
}

// plan builds and guards the full docker run invocation. The mount set, in
// order: the worktree at its host path (Fact 3), the main repo root at its
// host path (the worktree's .git file points into it — Fact 3 P-GK-CTR-8b),
// the host's session state read-write (Fact 2), and the host CLI binary
// read-only (Fact 4).
func (c Container) plan(spec Spec) (containerPlan, error) {
	bin, err := c.resolveDocker()
	if err != nil {
		return containerPlan{}, err
	}
	if !validContainerName(spec.Name) {
		return containerPlan{}, fmt.Errorf("%w: %q is not a Docker-safe container name",
			ErrRunID, spec.Name)
	}
	cliPath, err := c.resolveCLI(spec.Command)
	if err != nil {
		return containerPlan{}, err
	}
	wt := spec.Dir
	if wt == "" {
		// The native runner inherits the agent's working directory; the
		// container runner mounts it at the same host path instead.
		wt, err = c.workdir()
		if err != nil {
			return containerPlan{}, err
		}
	}

	var mounts []containerMount
	mounts = append(mounts, containerMount{source: wt, target: wt})
	if root, ok := c.repoRoot(wt); ok && root != wt {
		mounts = append(mounts, containerMount{source: root, target: root})
	}
	stateMounts, err := c.sessionStateMounts(spec.Command)
	if err != nil {
		return containerPlan{}, err
	}
	mounts = append(mounts, stateMounts...)
	mounts = append(mounts, containerMount{
		source: cliPath,
		target: filepath.Join("/usr/local/bin", filepath.Base(cliPath)),
		ro:     true,
	})

	home, err := c.homeDir()
	if err != nil {
		return containerPlan{}, err
	}
	prelude, err := c.sessionPrelude()
	if err != nil {
		return containerPlan{}, err
	}
	argv := []string{"run", "--rm", "-i", "--init", "--name", spec.Name}
	for _, m := range mounts {
		argv = append(argv, "-v", m.source+":"+m.target+roSuffix(m))
	}
	// The host home path is the container HOME, so every host-relative
	// credential and state path the CLI reads resolves identically (the
	// AC-9 container rows).
	argv = append(argv, "-e", "HOME="+home)
	for _, e := range spec.Env {
		argv = append(argv, "-e", e)
	}
	// The prelude runs before the session; the session command rides as argv
	// ($0 is a placeholder, the CLI basename and its args are the exec tail).
	argv = append(argv, "-w", wt, SessionImage,
		"sh", "-c", prelude, "session", filepath.Base(cliPath))
	argv = append(argv, spec.Args...)

	if err := guardSessionArgv(argv); err != nil {
		return containerPlan{}, err
	}
	return containerPlan{bin: bin, argv: argv, name: spec.Name}, nil
}

// sessionPrelude renders the fixed prelude with the node's own uid and gid.
func (c Container) sessionPrelude() (string, error) {
	u := c.uid()
	var uid, gid int
	if _, err := fmt.Sscanf(u, "%d:%d", &uid, &gid); err != nil {
		return "", fmt.Errorf("agent: cannot derive the session uid from %q", u)
	}
	return fmt.Sprintf(sessionPreludeFmt, uid, gid), nil
}

// resolveDocker finds the Docker CLI. Its absence is a node that cannot run
// the container runner: the refuse happens before any journal row.
func (c Container) resolveDocker() (string, error) {
	bin := c.DockerBin
	if bin == "" {
		bin = "docker"
	}
	look := c.lookPath
	if look == nil {
		look = exec.LookPath
	}
	path, err := look(bin)
	if err != nil {
		return "", fmt.Errorf("%w: %s is not on PATH", ErrNoDocker, bin)
	}
	return path, nil
}

// resolveCLI finds the host CLI binary on the node: the single native binary
// the container mounts read-only (container-runner.md Fact 4).
func (c Container) resolveCLI(command string) (string, error) {
	look := c.lookPath
	if look == nil {
		look = exec.LookPath
	}
	path, err := look(command)
	if err != nil {
		return "", fmt.Errorf("%w: host CLI %q is not on PATH", ErrNoCommand, command)
	}
	return path, nil
}

// sessionStateMounts builds the read-write state mounts of one host CLI.
func (c Container) sessionStateMounts(command string) ([]containerMount, error) {
	if c.stateMounts != nil {
		return c.stateMounts(command), nil
	}
	dir, ok := hostStateDirs[filepath.Base(command)]
	if !ok {
		return nil, fmt.Errorf("%w: host CLI %q carries no container probe facts",
			ErrUnknownSessionHost, command)
	}
	home, err := c.homeDir()
	if err != nil {
		return nil, err
	}
	var mounts []containerMount
	add := func(rel string) error {
		source := filepath.Join(home, rel)
		if _, err := os.Stat(source); err != nil {
			return fmt.Errorf("%w: %s is missing — the one-time operator login of the host CLI has not happened on this node",
				ErrHostStateMissing, source)
		}
		mounts = append(mounts, containerMount{source: source, target: source})
		return nil
	}
	if err := add(dir); err != nil {
		return nil, err
	}
	// claude's project-trust state lives in a file beside the state dir (the
	// AC-9 Claude Code container row); it is part of the session state and
	// rides the same read-write rule.
	if dir == ".claude" {
		if err := add(".claude.json"); err != nil {
			return nil, err
		}
	}
	return mounts, nil
}

// repoRoot derives the main repo root of a worktree from its .git file
// (container-runner.md Fact 3: "mounting only the worktree breaks git").
// A worktree whose .git is a directory is the main checkout itself; a
// directory with neither carries no git mount, and the session fails fast
// on its own.
func (c Container) repoRoot(wt string) (string, bool) {
	data, err := os.ReadFile(filepath.Join(wt, ".git"))
	if err != nil {
		if st, statErr := os.Stat(filepath.Join(wt, ".git")); statErr == nil && st.IsDir() {
			return wt, true
		}
		return "", false
	}
	gitdir := strings.TrimSpace(strings.TrimPrefix(string(data), "gitdir:"))
	if !filepath.IsAbs(gitdir) {
		return "", false
	}
	// <main>/.git/worktrees/<slug> — three Dir steps up to the main root.
	root := filepath.Dir(filepath.Dir(filepath.Dir(gitdir)))
	if root == string(filepath.Separator) || root == "" {
		return "", false
	}
	return root, true
}

// uid is the host identity the session drops to: the node agent's own uid
// and gid, so the container writes the mounted host paths as the host user
// (the AC-5 item-4 hygiene) and git's safe.directory guard never fires
// (Fact 3). Root never runs the session — only the prelude's package
// install does.
func (c Container) uid() string {
	if c.user != "" {
		return c.user
	}
	return fmt.Sprintf("%d:%d", os.Getuid(), os.Getgid())
}

// homeDir is the host home dir of the node agent.
func (c Container) homeDir() (string, error) {
	if c.home != "" {
		return c.home, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("agent: host home: %w", err)
	}
	return home, nil
}

// workdir is the working directory a session inherits.
func (c Container) workdir() (string, error) {
	if c.getwd != nil {
		return c.getwd()
	}
	return os.Getwd()
}

// roSuffix renders the read-only mount suffix.
func roSuffix(m containerMount) string {
	if m.ro {
		return ":ro"
	}
	return ""
}

// validContainerName checks the Docker-safe name shape.
func validContainerName(name string) bool {
	if !strings.HasPrefix(name, containerNamePrefix) {
		return false
	}
	return runIDRE.MatchString(strings.TrimPrefix(name, containerNamePrefix))
}

// containerNamePrefix is the prefix of every session container name.
const containerNamePrefix = "devteam-run-"

// guardSessionArgv enforces the socket rule on a built invocation: the
// session container never sees the Docker socket, never gains a Docker
// group, and never runs privileged or in a host namespace. Every argv the
// runner builds passes through here before Docker is exec'd, so the guard
// cannot drift from the invocation. The scan covers only the Docker-controlled
// half of the argv — everything before the session image. The half after it
// is the session's own command argv: untrusted data, never a Docker flag,
// so a message that mentions a socket path is text, not a leak.
func guardSessionArgv(argv []string) error {
	dockerArgs := argv
	for i, tok := range argv {
		if tok == SessionImage {
			dockerArgs = argv[:i]
			break
		}
	}
	for i, tok := range dockerArgs {
		if strings.Contains(tok, "docker.sock") {
			return fmt.Errorf("%w: %q would hand the Docker socket to the session container",
				ErrSocketLeak, tok)
		}
		if tok == "--group-add" || strings.HasPrefix(tok, "--group-add=") {
			return fmt.Errorf("%w: %q would give the session container the Docker group",
				ErrSocketLeak, tok)
		}
		for _, banned := range []string{"--privileged", "--pid=host", "--userns=host", "--network=host"} {
			if tok == banned || strings.HasPrefix(tok, banned+"=") {
				return fmt.Errorf("%w: %q widens the session container beyond the probed posture",
					ErrSocketLeak, tok)
			}
		}
		// Nothing under /var/run crosses the boundary, in either half of a
		// mount: the socket lives there, and a directory mount carries it.
		// Both mount spellings are checked, so a long-form drift cannot
		// bypass the guard.
		if (tok == "-v" || tok == "--volume") && i+1 < len(dockerArgs) {
			source, target, _ := strings.Cut(dockerArgs[i+1], ":")
			for _, side := range []string{source, target} {
				if side == "/var/run" || strings.HasPrefix(side, "/var/run/") {
					return fmt.Errorf("%w: mounting %q would carry the Docker socket into the session container",
						ErrSocketLeak, dockerArgs[i+1])
				}
			}
		}
	}
	return nil
}

// containerProcess is one session container, supervised through the Docker
// client process that owns it.
type containerProcess struct {
	cmd   *exec.Cmd
	stdin io.WriteCloser
	// bin and name re-resolve the container for stop and signal: the stop
	// contract targets the container, not the client process, because the
	// container outlives its client.
	bin  string
	name string

	doneOnce sync.Once
	done     chan error
	waitErr  error
}

// PID is the Docker client's OS process id. The container's own init is not
// addressable from the host PID namespace; the pidfile records the client,
// and container liveness is probed by name (ContainerRunning).
func (p *containerProcess) PID() int { return p.cmd.Process.Pid }

// Done yields the wait result once the container exits.
func (p *containerProcess) Done() <-chan error { return p.done }

// Wait blocks until the container exits, exactly once.
func (p *containerProcess) Wait() error {
	<-p.done
	return p.waitErr
}

// Steer writes one control message to the container's stdin — the Docker
// client forwards it to the session, exactly the native runner's pipe
// mechanics. The message is untrusted text and travels as data.
func (p *containerProcess) Steer(message string) error {
	if _, err := io.WriteString(p.stdin, message+"\n"); err != nil {
		return fmt.Errorf("agent: steer container %s: %w", p.name, err)
	}
	return nil
}

// Stop stops the container: `docker stop -t <grace>` sends SIGTERM to the
// container's init and SIGKILL after the grace — the same TERM-then-KILL
// contract as the native runner, at the container boundary. A container that
// already exited answers "No such container" and is not an error. When
// Docker itself cannot be reached, a real client process is signalled the
// native way, so a broken daemon still ends the supervision; a synthetic
// process (StopContainer's adoption path) carries no client to signal and
// surfaces the docker error instead.
func (p *containerProcess) Stop(grace time.Duration) error {
	if grace < 0 {
		return fmt.Errorf("%w: %s", ErrGraceInvalid, grace)
	}
	// -t counts whole seconds; round up so a fraction of a second still
	// gives the session its grace before the SIGKILL.
	secs := int64((grace + time.Second - 1) / time.Second)
	out, err := exec.Command(p.bin, "stop", "-t", strconv.FormatInt(secs, 10), p.name).CombinedOutput()
	if err != nil && !strings.Contains(string(out), "No such container") {
		stopErr := fmt.Errorf("agent: docker stop %s: %v: %s", p.name, err,
			strings.TrimSpace(string(out)))
		if p.cmd == nil {
			// No client process exists (the adoption path): the docker
			// error is the whole answer — there is nothing to signal.
			return stopErr
		}
		return errors.Join(stopErr, p.signalClient(0))
	}
	return p.Wait()
}

// Signal sends one signal to the container's init.
func (p *containerProcess) Signal(sig syscall.Signal) error {
	out, err := exec.Command(p.bin, "kill", "--signal", sig.String(), p.name).CombinedOutput()
	if err != nil && !strings.Contains(string(out), "No such container") {
		return fmt.Errorf("agent: docker kill %s: %v: %s", p.name, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// signalClient signals the Docker client process itself: the fallback path
// when Docker cannot stop the container. grace zero escalates straight to
// SIGKILL. A synthetic process (cmd nil) has no client to signal; the caller
// must not take this path.
func (p *containerProcess) signalClient(grace time.Duration) error {
	if p.cmd == nil {
		return fmt.Errorf("agent: container %s has no client process to signal", p.name)
	}
	if err := p.cmd.Process.Signal(syscall.SIGTERM); err != nil && !processGone(err) {
		return fmt.Errorf("agent: signal client pid %d: %w", p.PID(), err)
	}
	if grace > 0 {
		select {
		case <-p.done:
			return nil
		case <-time.After(grace):
		}
	}
	if err := p.cmd.Process.Signal(syscall.SIGKILL); err != nil && !processGone(err) {
		return fmt.Errorf("agent: kill client pid %d: %w", p.PID(), err)
	}
	return p.Wait()
}

// ContainerRunning reports Docker's own liveness reading for the named
// container. A container Docker does not know is not running; any other
// inspect failure — an unreachable daemon, a denied socket — surfaces as an
// error, so a flaky daemon never reads a live orphan as confidently dead.
func (c Container) ContainerRunning(name string) (bool, error) {
	bin, err := c.resolveDocker()
	if err != nil {
		return false, err
	}
	out, err := exec.Command(bin, "inspect", "-f", "{{.State.Running}}", name).CombinedOutput()
	if err != nil {
		// A container that does not exist is not running.
		if strings.Contains(string(out), "No such object") ||
			strings.Contains(string(out), "No such container") {
			return false, nil
		}
		return false, fmt.Errorf("agent: docker inspect %s: %v: %s", name, err,
			strings.TrimSpace(string(out)))
	}
	return strings.TrimSpace(string(out)) == "true", nil
}

// StopContainer stops the named container with the stop contract. It is the
// adoption-policy and stop-verb entry point for a container run whose
// supervising agent died: the container outlived its client process, so no
// host PID reaches it — the name does.
func (c Container) StopContainer(name string, grace time.Duration) error {
	p := &containerProcess{bin: func() string {
		bin, err := c.resolveDocker()
		if err != nil {
			return c.DockerBin
		}
		return bin
	}(), name: name, done: make(chan error, 1)}
	close(p.done) // no client process to wait on; Wait returns immediately
	return p.Stop(grace)
}
