package agent

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"
)

// Spec is one runner process to spawn: the host CLI command and its argv. The
// values arrive as argv entries only — never as assembled shell text
// (AGENTS.md § Code Conventions).
type Spec struct {
	// Command is the executable on the node's own PATH.
	Command string
	// Args are the argv entries after the command.
	Args []string
	// Dir is the working directory, empty meaning inherit.
	Dir string
}

// Process is one runner process the agent supervises. The native runner
// implements it with a child process of this agent; a later runner type
// (container) implements it against its own runtime, which the contract never
// names here.
type Process interface {
	// PID is the OS process id.
	PID() int
	// Done returns a channel that yields the wait result once the process
	// exits.
	Done() <-chan error
	// Wait blocks until the process exits and returns its result.
	Wait() error
	// Steer delivers one control message to the process at a step boundary.
	Steer(message string) error
	// Stop signals the process: SIGTERM, then SIGKILL after the grace. A
	// grace of zero means SIGKILL immediately.
	Stop(grace time.Duration) error
	// Signal sends one signal without the stop sequence.
	Signal(sig syscall.Signal) error
}

// Runner starts one agent session. The native runner is the first built and
// the default once a node selects a runner.
type Runner interface {
	// Name is the selection token of this runner.
	Name() RunnerType
	// Start spawns one agent session process.
	Start(spec Spec) (Process, error)
}

// Native is the native runner: one process on the node's own OS, running the
// installed host CLI with its own logins. It has no Docker dependency — the
// runner contract never names a container runtime.
type Native struct {
	// Stdout and Stderr are the child's output sinks, nil meaning the
	// agent's own.
	Stdout io.Writer
	Stderr io.Writer
}

// Name is the runner's selection token.
func (Native) Name() RunnerType { return RunnerNative }

// Start spawns spec.Command as a child process of this agent. The child
// inherits the agent's environment — its logins, its PATH, its credential
// files (docs/internal/control-plane/credentials.md § AC-9 native rows).
//
// The child's output goes through pipes this runner drains itself, not
// through exec's copier: a grandchild that outlives its parent holds the
// write end, and exec's Wait would block on the drain — an agent session
// must be supervisable the moment its own process exits.
func (n Native) Start(spec Spec) (Process, error) {
	if spec.Command == "" {
		return nil, ErrNoCommand
	}
	cmd := exec.Command(spec.Command, spec.Args...)
	cmd.Dir = spec.Dir
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
		return nil, fmt.Errorf("agent: spawn %s: %w", spec.Command, err)
	}
	// The agent holds no write end: the child owns the stream. Wait is done
	// the moment the child's own process exits.
	_ = outW.Close()
	_ = errW.Close()
	go n.drain(outR, n.sink(n.Stdout, os.Stdout))
	go n.drain(errR, n.sink(n.Stderr, os.Stderr))

	p := &nativeProcess{cmd: cmd, stdin: stdin, done: make(chan error, 1)}
	go func() {
		p.doneOnce.Do(func() {
			p.waitErr = cmd.Wait()
		})
		close(p.done)
	}()
	return p, nil
}

// drain copies one output stream until every writer of it is gone.
func (Native) drain(r *os.File, w io.Writer) {
	_, _ = io.Copy(w, r)
	_ = r.Close()
}

// sink resolves a configured writer, nil meaning the agent's own stream: the
// runner session's output is the run's output.
func (Native) sink(w, fallback io.Writer) io.Writer {
	if w == nil {
		return fallback
	}
	return w
}

// nativeProcess is one child of this agent.
type nativeProcess struct {
	cmd   *exec.Cmd
	stdin io.WriteCloser

	doneOnce sync.Once
	done     chan error
	waitErr  error
}

// PID is the child's OS process id.
func (p *nativeProcess) PID() int { return p.cmd.Process.Pid }

// Done yields the wait result once the process exits.
func (p *nativeProcess) Done() <-chan error { return p.done }

// Wait blocks until the process exits, exactly once.
func (p *nativeProcess) Wait() error {
	<-p.done
	return p.waitErr
}

// Steer writes one control message to the child's stdin. The message is
// untrusted text: it travels as data through a pipe, never as a command line.
// A child that has exited answers the write with EPIPE, which surfaces as the
// returned error.
func (p *nativeProcess) Steer(message string) error {
	if _, err := io.WriteString(p.stdin, message+"\n"); err != nil {
		return fmt.Errorf("agent: steer pid %d: %w", p.PID(), err)
	}
	return nil
}

// Stop signals the child: SIGTERM, then SIGKILL after the grace. A grace of
// zero skips the SIGTERM and kills immediately, so a zero-grace stop is
// deterministic. Stop waits for the exit either way, so no child is left
// unreaped.
func (p *nativeProcess) Stop(grace time.Duration) error {
	if grace < 0 {
		return fmt.Errorf("%w: %s", ErrGraceInvalid, grace)
	}
	if grace == 0 {
		if err := p.Signal(syscall.SIGKILL); err != nil && !processGone(err) {
			return fmt.Errorf("agent: kill pid %d: %w", p.PID(), err)
		}
		return p.Wait()
	}
	if err := p.Signal(syscall.SIGTERM); err != nil {
		// A child that already exited cannot be signalled; report its wait
		// result instead of a signal error.
		if !processGone(err) {
			return fmt.Errorf("agent: stop pid %d: %w", p.PID(), err)
		}
		return p.Wait()
	}
	select {
	case <-p.done:
		return p.waitErr
	case <-time.After(grace):
	}
	if err := p.Signal(syscall.SIGKILL); err != nil && !processGone(err) {
		return fmt.Errorf("agent: kill pid %d: %w", p.PID(), err)
	}
	return p.Wait()
}

// Signal sends one signal to the child.
func (p *nativeProcess) Signal(sig syscall.Signal) error {
	return p.cmd.Process.Signal(sig)
}

// processGone reports whether a signal error means the process already
// exited. Such a stop is not a failure: the outcome is the wait result.
func processGone(err error) bool {
	if err == nil {
		return false
	}
	for _, cause := range []error{os.ErrProcessDone, syscall.ESRCH} {
		if errors.Is(err, cause) {
			return true
		}
	}
	return false
}
