package reconcile

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
)

// Worktree is one entry of `git worktree list --porcelain`.
type Worktree struct {
	Path   string `json:"path"`
	Branch string `json:"branch,omitempty"` // short branch name; empty when detached
	HEAD   string `json:"head,omitempty"`
}

// Reality is the host state the journal is compared against (AC5).
type Reality struct {
	MROOT     string     `json:"mroot"`
	Worktrees []Worktree `json:"worktrees,omitempty"`
	Branches  []string   `json:"branches,omitempty"`
}

// git lists the worktrees under mroot and the local branches through argv lists
// with no shell and no interpolated value (AGENTS.md § Code Conventions:
// untrusted input never becomes code).

// Scan reads reality: the worktrees git lists under mroot and the local
// branches. A missing git, or a directory that is not a repository, is an error
// the caller records as a deferred finding: the journal-side repairs still run.
func Scan(ctx context.Context, gitBin, mroot string) (Reality, error) {
	if gitBin == "" {
		gitBin = "git"
	}
	if mroot == "" {
		return Reality{}, fmt.Errorf("%w: mroot is required", ErrReality)
	}
	worktrees, err := listWorktrees(ctx, gitBin, mroot)
	if err != nil {
		return Reality{}, err
	}
	branches, err := listBranches(ctx, gitBin, mroot)
	if err != nil {
		return Reality{}, err
	}
	return Reality{MROOT: mroot, Worktrees: worktrees, Branches: branches}, nil
}

// gitRun runs one read-only git command in mroot.
func gitRun(ctx context.Context, gitBin, mroot string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, gitBin, args...)
	cmd.Dir = mroot
	out, err := cmd.Output()
	if err != nil {
		msg := err.Error()
		var ee *exec.ExitError
		if errors.As(err, &ee) && len(ee.Stderr) > 0 {
			msg = strings.TrimSpace(string(ee.Stderr))
		}
		return "", fmt.Errorf("%w: %s %s: %s", ErrReality, gitBin, strings.Join(args, " "), msg)
	}
	return string(out), nil
}

func listWorktrees(ctx context.Context, gitBin, mroot string) ([]Worktree, error) {
	out, err := gitRun(ctx, gitBin, mroot, "worktree", "list", "--porcelain")
	if err != nil {
		return nil, err
	}
	var (
		list []Worktree
		cur  *Worktree
	)
	flush := func() {
		if cur != nil && cur.Path != "" {
			list = append(list, *cur)
		}
		cur = nil
	}
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimRight(line, "\r")
		switch {
		case strings.HasPrefix(line, "worktree "):
			flush()
			cur = &Worktree{Path: strings.TrimPrefix(line, "worktree ")}
		case strings.HasPrefix(line, "HEAD "):
			if cur != nil {
				cur.HEAD = strings.TrimPrefix(line, "HEAD ")
			}
		case strings.HasPrefix(line, "branch "):
			if cur != nil {
				cur.Branch = shortRef(strings.TrimPrefix(line, "branch "))
			}
		case line == "detached", line == "bare":
			if cur != nil {
				cur.Branch = ""
			}
		}
	}
	flush()
	return list, nil
}

func listBranches(ctx context.Context, gitBin, mroot string) ([]string, error) {
	out, err := gitRun(ctx, gitBin, mroot, "branch", "--format=%(refname:short)")
	if err != nil {
		return nil, err
	}
	var list []string
	for _, line := range strings.Split(out, "\n") {
		if b := strings.TrimSpace(line); b != "" {
			list = append(list, b)
		}
	}
	return list, nil
}

// shortRef turns refs/heads/main into main.
func shortRef(ref string) string {
	return strings.TrimPrefix(strings.TrimSpace(ref), "refs/heads/")
}

// ProcessState is what the lease-record probe proves about a pid. Dead is the
// only state that authorises a destructive repair: an unknown owner is treated
// as alive, so a probe that cannot see the process never fails a run.
type ProcessState string

const (
	ProcessAlive   ProcessState = "alive"
	ProcessDead    ProcessState = "dead"
	ProcessUnknown ProcessState = "unknown"
)

// ProbePID is the process liveness probe: os.FindProcess plus a signal-0 probe.
// It parses nothing beyond that — no /proc walking.
func ProbePID(pid int) ProcessState {
	if pid <= 0 {
		return ProcessUnknown
	}
	if pid == os.Getpid() {
		return ProcessAlive
	}
	p, err := os.FindProcess(pid)
	if err != nil {
		return ProcessDead
	}
	switch err := p.Signal(syscall.Signal(0)); {
	case err == nil:
		return ProcessAlive
	case errors.Is(err, os.ErrProcessDone):
		// A child this process already reaped: Go answers without the syscall.
		return ProcessDead
	case errors.Is(err, syscall.ESRCH):
		return ProcessDead
	case errors.Is(err, syscall.EPERM):
		// The process exists and is not ours to signal.
		return ProcessAlive
	default:
		// Signal 0 is unsupported here (Windows): liveness is unprovable.
		return ProcessUnknown
	}
}

// The lease record names its owner as a free-form string (journal/schema.sql),
// so the pid travels inside it. These are the shapes the runner writes:
// "runner:pid=4321", "node-agent-4321", "4321", "runner-a:4321".
var (
	pidKeyRE    = regexp.MustCompile(`(?i)pid[=:_-]?([1-9][0-9]*)`)
	pidSuffixRE = regexp.MustCompile(`[-:]([1-9][0-9]*)$`)
	pidOnlyRE   = regexp.MustCompile(`^([1-9][0-9]*)$`)
)

// OwnerPID reads the process id out of a lease owner name. ok is false when the
// name carries none, which is ProcessUnknown: never a basis for failing a run.
func OwnerPID(owner string) (pid int, ok bool) {
	for _, re := range []*regexp.Regexp{pidKeyRE, pidSuffixRE, pidOnlyRE} {
		m := re.FindStringSubmatch(owner)
		if m == nil {
			continue
		}
		n, err := strconv.Atoi(m[1])
		if err == nil && n > 0 {
			return n, true
		}
	}
	return 0, false
}

var tokenSplitRE = regexp.MustCompile(`[^a-z0-9]+`)

// tokens splits a name into the lowercase alnum tokens a path, slug, or branch
// is built from.
func tokens(s string) []string {
	parts := tokenSplitRE.Split(strings.ToLower(s), -1)
	out := parts[:0]
	for _, p := range parts {
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

// namesRun reports whether name carries ticket as a run of consecutive tokens:
// the branch feat/CDT-643 and the path /w/.worktrees/CDT-643 both name ticket
// CDT-643; feature/643 does not.
func namesRun(name, ticket string) bool {
	nameT, ticketT := tokens(name), tokens(ticket)
	if len(ticketT) == 0 || len(ticketT) > len(nameT) {
		return false
	}
	for i := 0; i+len(ticketT) <= len(nameT); i++ {
		match := true
		for j := range ticketT {
			if nameT[i+j] != ticketT[j] {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}

// intentFields reads the string fields of an intent payload. A payload that
// carries a number, a nested object, or anything that is not an object yields
// the string fields it has, so one non-string field cannot hide a path.
func intentFields(raw json.RawMessage) map[string]string {
	var raws map[string]json.RawMessage
	if len(raw) == 0 || json.Unmarshal(raw, &raws) != nil {
		return nil
	}
	out := make(map[string]string, len(raws))
	for k, v := range raws {
		var s string
		if json.Unmarshal(v, &s) == nil && s != "" {
			out[k] = s
		}
	}
	return out
}

// firstString returns the first named field that carries a string.
func firstString(fields map[string]string, names ...string) string {
	for _, n := range names {
		if v := fields[n]; v != "" {
			return v
		}
	}
	return ""
}

// resolveIn makes an intent path absolute against mroot.
func resolveIn(mroot, path string) string {
	if filepath.IsAbs(path) {
		return filepath.Clean(path)
	}
	return filepath.Clean(filepath.Join(mroot, path))
}

// normPath resolves symlinks where it can, because git reports realpaths and a
// worktree path from an intent may not be resolved.
func normPath(p string) string {
	if real, err := filepath.EvalSymlinks(p); err == nil {
		return filepath.Clean(real)
	}
	return filepath.Clean(p)
}

// pathExists reports a path on disk. Any lstat error is reported as absent:
// reality claims come from the scan, not from a guess.
func pathExists(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}
