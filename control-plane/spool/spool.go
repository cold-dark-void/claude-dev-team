package spool

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
)

// EnvSpool overrides the spool path outright, the $DEVTEAM_RUN_DB pattern of
// control-plane/journal/open.go.
const EnvSpool = "DEVTEAM_SPOOL"

// spoolRelPath is the default location under $MROOT. .gitignore carries the same
// pattern: the spool is process state, never committed.
const spoolRelPath = ".claude/runs/spool/spool.ndjson"

// Kind is a phase-event kind. The set is closed (CDT-642 AC3).
type Kind string

// The closed event-kind set: a phase starts, a phase ends, a gate is answered,
// a run halts.
const (
	KindStart Kind = "start"
	KindEnd   Kind = "end"
	KindGate  Kind = "gate"
	KindHalt  Kind = "halt"
)

// AllKinds is the closed set, in contract order.
var AllKinds = []Kind{KindStart, KindEnd, KindGate, KindHalt}

// ValidKind reports whether k is one of the four kinds.
func ValidKind(k Kind) bool {
	for _, v := range AllKinds {
		if v == k {
			return true
		}
	}
	return false
}

// Typed errors. Callers branch on these with errors.Is.
var (
	// ErrInvalid is a malformed record, path, or argument.
	ErrInvalid = errors.New("spool: invalid input")

	// ErrDuplicate is the idempotency answer (AC4): the (run_id, phase, kind)
	// key is already in the spool. Nothing was written.
	ErrDuplicate = errors.New("spool: phase event already spooled")

	// ErrBadLine is a spool line that is not a valid record: the file is not
	// NDJSON of the documented shape.
	ErrBadLine = errors.New("spool: spool line is not a valid record")

	// ErrMemoryDB refuses to put the spool inside the agent memory tree
	// (docs/adr/0001-journal-engine.md: run state is not agent memory).
	ErrMemoryDB = errors.New("spool: refusing to write inside .claude/memory")
)

// Record is one phase event.
type Record struct {
	// TS is the canonical journal timestamp (UTC, second precision).
	TS string `json:"ts"`
	// RunID is the run the event belongs to.
	RunID string `json:"run_id"`
	// Phase names the lifecycle graph vertex the event is about.
	Phase string `json:"phase"`
	// Kind is one of start, end, gate, halt.
	Kind Kind `json:"kind"`
	// Detail is optional free text: a gate name, a halt reason, a one-line note.
	Detail string `json:"detail,omitempty"`
}

// key is the idempotency key of the contract (AC4).
func (r Record) key() string { return r.RunID + "\x00" + r.Phase + "\x00" + string(r.Kind) }

// Now stamps a record with the canonical journal timestamp.
func Now() string { return journal.NowUTC() }

// Validate reports whether the record is legal to spool. encoding/json escapes a
// newline, so a valid record always occupies exactly one line.
func (r Record) Validate() error {
	if r.RunID == "" {
		return fmt.Errorf("%w: run_id is required", ErrInvalid)
	}
	if r.Phase == "" {
		return fmt.Errorf("%w: phase is required", ErrInvalid)
	}
	if !ValidKind(r.Kind) {
		return fmt.Errorf("%w: kind %q is not one of %s",
			ErrInvalid, string(r.Kind), kindList())
	}
	if _, err := journal.ParseTS(r.TS); err != nil {
		return fmt.Errorf("%w: ts: %v", ErrInvalid, err)
	}
	return nil
}

func kindList() string {
	parts := make([]string, 0, len(AllKinds))
	for _, k := range AllKinds {
		parts = append(parts, string(k))
	}
	return strings.Join(parts, ", ")
}

// Spool is one NDJSON phase-event file.
//
// The writer opens the file per append with O_APPEND, flushes, and closes it, so
// a process that is killed leaves every event it wrote. One run has one writer:
// the lease owner (control-plane/run, AC4), which is what makes the read-then-
// append of Append safe for that run.
type Spool struct{ path string }

// Resolve returns the spool path: $DEVTEAM_SPOOL, else
// $MROOT/.claude/runs/spool/spool.ndjson.
func Resolve() (string, error) {
	if p := strings.TrimSpace(os.Getenv(EnvSpool)); p != "" {
		return abs(p)
	}
	mroot, err := journal.MROOT()
	if err != nil {
		return "", err
	}
	return abs(filepath.Join(mroot, spoolRelPath))
}

// Open returns the spool at path, creating the parent directory. An empty path
// resolves from the environment.
func Open(path string) (*Spool, error) {
	if strings.TrimSpace(path) == "" {
		return OpenDefault()
	}
	p, err := abs(path)
	if err != nil {
		return nil, err
	}
	if err := refuseMemory(p); err != nil {
		return nil, err
	}
	if dir := filepath.Dir(p); dir != "" && dir != "/" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, fmt.Errorf("spool: create %s: %w", dir, err)
		}
	}
	return &Spool{path: p}, nil
}

// OpenDefault opens the spool Resolve names.
func OpenDefault() (*Spool, error) {
	p, err := Resolve()
	if err != nil {
		return nil, err
	}
	return Open(p)
}

// Path is the file this spool writes.
func (s *Spool) Path() string { return s.path }

// Append writes one event and returns its line number (1-based).
//
// Idempotency (AC4): the (run_id, phase, kind) key is checked first, so a replay
// of a crashed run writes nothing and is refused with ErrDuplicate. Nothing is
// written in that case: a replay causes no second event, and the caller treats
// errors.Is(err, ErrDuplicate) as "already recorded".
//
// The record is flushed before Append returns, so a SIGKILL cannot lose an event
// that was reported as written.
func (s *Spool) Append(rec Record) (int, error) {
	if err := rec.Validate(); err != nil {
		return 0, err
	}
	existing, err := s.Records()
	if err != nil {
		return 0, err
	}
	key := rec.key()
	for i, e := range existing {
		if e.key() == key {
			return i + 1, fmt.Errorf("%w: run %s phase %s kind %s (line %d)",
				ErrDuplicate, rec.RunID, rec.Phase, rec.Kind, i+1)
		}
	}
	raw, err := json.Marshal(rec)
	if err != nil {
		return 0, fmt.Errorf("%w: %v", ErrInvalid, err)
	}
	f, err := os.OpenFile(s.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return 0, fmt.Errorf("spool: open %s: %w", s.path, err)
	}
	defer f.Close()
	line := len(existing) + 1
	if _, err := f.Write(append(raw, '\n')); err != nil {
		return 0, fmt.Errorf("spool: append: %w", err)
	}
	if err := f.Sync(); err != nil {
		return 0, fmt.Errorf("spool: sync: %w", err)
	}
	return line, nil
}

// Emit stamps rec with the canonical clock when it carries no ts, and appends it.
// It returns created=false when the key was already spooled.
func (s *Spool) Emit(rec Record) (int, bool, error) {
	if rec.TS == "" {
		rec.TS = Now()
	}
	line, err := s.Append(rec)
	if errors.Is(err, ErrDuplicate) {
		return line, false, nil
	}
	if err != nil {
		return 0, false, err
	}
	return line, true, nil
}

// Has reports whether the (run_id, phase, kind) key is already spooled.
func (s *Spool) Has(runID, phase string, kind Kind) (bool, error) {
	key := Record{RunID: runID, Phase: phase, Kind: kind}.key()
	recs, err := s.Records()
	if err != nil {
		return false, err
	}
	for _, r := range recs {
		if r.key() == key {
			return true, nil
		}
	}
	return false, nil
}

// Records returns every event in file order. A missing file is an empty spool,
// not an error: the first event of a run has nothing before it.
func (s *Spool) Records() ([]Record, error) {
	f, err := os.Open(s.path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("spool: open %s: %w", s.path, err)
	}
	defer f.Close()

	var out []Record
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for n := 1; sc.Scan(); n++ {
		text := bytes.TrimSpace(sc.Bytes())
		if len(text) == 0 {
			continue
		}
		rec, err := parseLine(text)
		if err != nil {
			return nil, fmt.Errorf("%w (line %d): %v", ErrBadLine, n, err)
		}
		out = append(out, rec)
	}
	return out, sc.Err()
}

// Count is the number of events spooled.
func (s *Spool) Count() (int, error) {
	recs, err := s.Records()
	return len(recs), err
}

// parseLine decodes one NDJSON line strictly: the keys are the documented shape,
// so an extra key is a broken spool, not an extension.
func parseLine(text []byte) (Record, error) {
	dec := json.NewDecoder(bytes.NewReader(text))
	dec.DisallowUnknownFields()
	var rec Record
	if err := dec.Decode(&rec); err != nil {
		return Record{}, err
	}
	if dec.More() {
		return Record{}, fmt.Errorf("trailing data after the JSON object")
	}
	if err := rec.Validate(); err != nil {
		return Record{}, err
	}
	return rec, nil
}

// refuseMemory keeps the spool out of the agent memory tree, the guard
// journal.OpenPath applies to the journal (docs/adr/0001-journal-engine.md).
func refuseMemory(path string) error {
	clean := filepath.ToSlash(path)
	if strings.Contains(clean, "/.claude/memory/") ||
		strings.EqualFold(filepath.Base(clean), "memory.db") {
		return fmt.Errorf("%w: the spool lives at %s: %s", ErrMemoryDB, spoolRelPath, path)
	}
	return nil
}

func abs(p string) (string, error) {
	a, err := filepath.Abs(p)
	if err != nil {
		return "", fmt.Errorf("%w: %v", ErrInvalid, err)
	}
	return filepath.Clean(a), nil
}
