package chief

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/cold-dark-void/claude-dev-team/control-plane/hostadapter"
)

// The bounds of the output tail (SPEC-045 M7): the line bound defaults to 200
// and never exceeds 1000, and the read never carries more than 64 KiB.
const (
	DefaultOutputLines = 200
	MaxOutputLines     = 1000
	OutputByteCap      = 64 << 10
)

// OutputTail is one bounded tail of a run's host transcript (SPEC-045 AC3).
// An absent or unreadable transcript is an explicit empty result: Lines is
// empty and Reason names why. It is never an error — the detail view polls
// this read, and a session that has not written its first line is normal.
type OutputTail struct {
	Host string `json:"host"`
	// SessionID is the journaled host session id the tail is read by.
	SessionID string `json:"session_id,omitempty"`
	// Source is the transcript file the tail came from. Empty when there is
	// no file to read.
	Source string `json:"source,omitempty"`
	// Truncated is true when the answer is not the whole transcript: the
	// line bound, the byte cap, or both cut content.
	Truncated bool     `json:"truncated"`
	Lines     []string `json:"lines"`
	Reason    string   `json:"reason,omitempty"`
}

// transcriptRoots locates the host transcript trees: the user's home (where
// every host writes its session state) and the working directory the node's
// host sessions run in (the transcript trees are keyed by it). Package seams:
// the tests point them at a fixture home, and the service reads the real ones.
type transcriptRoots struct {
	home func() (string, error)
	cwd  func() (string, error)
}

var outputRoots = transcriptRoots{home: os.UserHomeDir, cwd: os.Getwd}

// RunOutput reads the tail of one run's host transcript, read-only
// (SPEC-045 M7). The host comes from the run's recorded start argv and the
// session id from its journaled agent.session rows — never from the
// in-memory capture, which a restart loses. lines <= 0 takes
// DefaultOutputLines; the bound never exceeds MaxOutputLines, and the read
// never exceeds OutputByteCap bytes. An unknown run is the typed error; an
// absent transcript is the empty result.
func (c *Chief) RunOutput(ctx context.Context, runID string, lines int) (OutputTail, error) {
	events, err := c.eng.Events(ctx, runID)
	if err != nil {
		return OutputTail{}, err
	}
	if len(events) == 0 {
		return OutputTail{}, fmt.Errorf("%w: %s", ErrUnknownRun, runID)
	}
	host, _ := detailFold(events)
	// The session-id fold is takeover.go's — the newest agent.session row,
	// its outcome payload first and its intent payload after. One extra
	// journal read on a loopback poll is cheaper than a second copy of it.
	sessionID, err := c.takeoverSessionID(ctx, runID)
	if err != nil {
		return OutputTail{}, err
	}

	bound := boundOutputLines(lines)
	if host == "" {
		return emptyTail(host, sessionID,
			"the run's start record names no known host command: there is no transcript layout to read"), nil
	}
	if sessionID == "" {
		return emptyTail(host, sessionID,
			"the journal names no host session id for the run"), nil
	}
	path, reason := transcriptLocate(host, sessionID)
	if path == "" {
		return emptyTail(host, sessionID, reason), nil
	}
	got, truncated, err := tailFile(path, bound)
	if err != nil {
		return emptyTail(host, sessionID,
			fmt.Sprintf("the transcript at %s is unreadable: %v", path, err)), nil
	}
	return OutputTail{
		Host: string(host), SessionID: sessionID, Source: path,
		Truncated: truncated, Lines: got,
	}, nil
}

// boundOutputLines clamps a requested line count to the tail's bounds.
func boundOutputLines(lines int) int {
	if lines <= 0 {
		return DefaultOutputLines
	}
	if lines > MaxOutputLines {
		return MaxOutputLines
	}
	return lines
}

// emptyTail is the explicit empty result of SPEC-045 M7.
func emptyTail(host hostadapter.Host, sessionID, reason string) OutputTail {
	return OutputTail{Host: string(host), SessionID: sessionID,
		Lines: []string{}, Reason: reason}
}

// transcriptLocate resolves the transcript file of one host session and
// answers the reason there is none. The layouts are the ones the capability
// matrix's probe records pin (SPEC-045 M7):
//
//	claude-code  ~/.claude/projects/<cwd with non-alphanumerics as ->/<id>.jsonl
//	grok         ~/.grok/sessions/<url-encoded cwd>/<id>/chat_history.jsonl
//	omp          ~/.omp/agent/sessions/<cwd slug>/<ts>_<id>.jsonl
//
// The omp layout is the one the probe record P-OMP-C-A pins: the transcript
// filename is the session's start timestamp and the session id joined by "_",
// so the id is the filename's suffix, not its stem — the glob is "*_<id>.jsonl".
// The same stem appears as a sibling directory (the session's side files), so
// the glob stays restricted to the .jsonl file.
func transcriptLocate(host hostadapter.Host, sessionID string) (string, string) {
	id := sanitizeSessionID(sessionID)
	if id == "" {
		return "", fmt.Sprintf("the journaled session id %q is not a usable path segment", sessionID)
	}
	home, err := outputRoots.home()
	if err != nil {
		return "", fmt.Sprintf("the host home directory is unreadable: %v", err)
	}
	cwd, err := outputRoots.cwd()
	if err != nil {
		return "", fmt.Sprintf("the working directory is unreadable: %v", err)
	}

	var root, path string
	switch host {
	case hostadapter.HostClaudeCode:
		root = filepath.Join(home, ".claude", "projects")
		path = filepath.Join(root, claudeProjectSlug(cwd), id+".jsonl")
	case hostadapter.HostGrok:
		root = filepath.Join(home, ".grok", "sessions")
		path = filepath.Join(root, urlPathEscape(cwd), id, "chat_history.jsonl")
	case hostadapter.HostOmp:
		root = filepath.Join(home, ".omp", "agent", "sessions")
		dir := filepath.Join(root, ompSessionSlug(home, cwd))
		path = newestOmpTranscript(dir, id)
		if path == "" {
			return "", fmt.Sprintf("no omp transcript for session %s under %s", id, dir)
		}
	default:
		return "", fmt.Sprintf("%s names no transcript layout in the capability matrix", host)
	}

	if !within(root, path) {
		return "", fmt.Sprintf("the resolved transcript path %s escapes %s", path, root)
	}
	info, err := os.Stat(path)
	if err != nil {
		return "", fmt.Sprintf("no transcript at %s: %v", path, err)
	}
	if info.IsDir() {
		return "", fmt.Sprintf("the transcript path %s is a directory", path)
	}
	return path, ""
}

// newestOmpTranscript picks the transcript of one omp session. The filenames
// start with the session's ISO-8601 start timestamp, so the lexical maximum
// is the newest — a resumed session keeps its original transcript name.
func newestOmpTranscript(dir, id string) string {
	// The id is sanitized before it reaches the glob, so no pattern
	// metacharacter can travel in it.
	matches, err := filepath.Glob(filepath.Join(dir, "*_"+id+".jsonl"))
	if err != nil || len(matches) == 0 {
		return ""
	}
	sort.Strings(matches)
	return matches[len(matches)-1]
}

// sanitizeSessionID keeps a journaled session id usable as a path segment:
// the id comes from host output, so anything that can name a parent
// directory, a separator, or a glob pattern is refused.
func sanitizeSessionID(id string) string {
	id = strings.TrimSpace(id)
	if id == "" || id == "." || id == ".." || strings.ContainsAny(id, `/\*?[]`) {
		return ""
	}
	for _, r := range id {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' ||
			r == '.' || r == '_' || r == '-') {
			return ""
		}
	}
	return id
}

// claudeProjectSlug is Claude Code's project directory name for a cwd: every
// non-alphanumeric character becomes "-", so a dot in a path segment costs a
// second dash ("/home/u/.claude" is "-home-u--claude").
func claudeProjectSlug(cwd string) string {
	var b strings.Builder
	for _, r := range cwd {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
			b.WriteRune(r)
		default:
			b.WriteByte('-')
		}
	}
	return b.String()
}

// urlPathEscape is the Grok sessions key: the cwd percent-encoded, with every
// separator as %2F ("/home/u" is "%2Fhome%2Fu").
func urlPathEscape(cwd string) string { return strings.ReplaceAll(cwd, "/", "%2F") }

// ompSessionSlug is the omp sessions directory name for a cwd: the home
// prefix is dropped and every separator becomes "-", so a cwd inside the home
// is "-vibes-proj" and one outside it keeps its full path "-tmp-probe".
func ompSessionSlug(home, cwd string) string {
	if rel := strings.TrimPrefix(cwd, home); rel != cwd && strings.HasPrefix(rel, "/") {
		cwd = rel
	}
	return strings.ReplaceAll(cwd, "/", "-")
}

// within reports whether path sits at or under root. Both sides are made
// absolute and cleaned, so a cwd that carries a ".." segment cannot escape
// the host's transcript tree.
func within(root, path string) bool {
	absRoot, err := filepath.Abs(root)
	if err != nil {
		return false
	}
	absPath, err := filepath.Abs(path)
	if err != nil {
		return false
	}
	return absPath == absRoot ||
		strings.HasPrefix(absPath, absRoot+string(os.PathSeparator))
}

// tailFile reads the last lines of one file, bounded by the line count and by
// OutputByteCap. The file is opened read-only: the tail never writes, and a
// file that cannot be opened is the caller's empty result.
func tailFile(path string, maxLines int) ([]string, bool, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, false, err
	}
	defer func() { _ = f.Close() }()
	info, err := f.Stat()
	if err != nil {
		return nil, false, err
	}

	truncated := false
	var start int64
	if size := info.Size(); size > OutputByteCap {
		start = size - OutputByteCap
		truncated = true
	}
	buf := make([]byte, info.Size()-start)
	n, err := f.ReadAt(buf, start)
	if err != nil && !errors.Is(err, io.EOF) {
		// A file that shrank between the stat and the read answers with the
		// bytes it has (io.EOF); anything else is a real read failure the
		// caller turns into its empty result.
		return nil, false, err
	}
	buf = buf[:n]
	if start > 0 {
		// The window starts mid-line: drop the partial line it cut, so every
		// returned line is a whole record.
		if i := bytes.IndexByte(buf, '\n'); i >= 0 {
			buf = buf[i+1:]
		} else {
			buf = nil
		}
	}

	text := strings.TrimSuffix(string(buf), "\n")
	if strings.TrimSpace(text) == "" {
		return []string{}, truncated, nil
	}
	linesOut := strings.Split(text, "\n")
	if len(linesOut) > maxLines {
		linesOut = linesOut[len(linesOut)-maxLines:]
		truncated = true
	}
	return linesOut, truncated, nil
}
