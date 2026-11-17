package spool

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
)

func newSpool(t *testing.T) *Spool {
	t.Helper()
	s, err := Open(filepath.Join(t.TempDir(), "spool", "spool.ndjson"))
	if err != nil {
		t.Fatalf("open spool: %v", err)
	}
	return s
}

func sample() Record {
	return Record{
		TS:     "2026-11-17T09:00:00Z",
		RunID:  "CDT-642",
		Phase:  "plan",
		Kind:   KindGate,
		Detail: "plan-approve: approved",
	}
}

// AC3: the record shape is the documented one — these keys, in this order, one
// JSON object per line.
func TestAppendWritesTheDocumentedLine(t *testing.T) {
	s := newSpool(t)
	line, err := s.Append(sample())
	if err != nil {
		t.Fatalf("Append: %v", err)
	}
	if line != 1 {
		t.Errorf("line = %d, want 1", line)
	}
	raw, err := os.ReadFile(s.Path())
	if err != nil {
		t.Fatal(err)
	}
	want := `{"ts":"2026-11-17T09:00:00Z","run_id":"CDT-642","phase":"plan",` +
		`"kind":"gate","detail":"plan-approve: approved"}` + "\n"
	if string(raw) != want {
		t.Errorf("spool file = %q, want %q", raw, want)
	}
	var keys map[string]json.RawMessage
	if err := json.Unmarshal([]byte(strings.TrimSpace(string(raw))), &keys); err != nil {
		t.Fatalf("the line is not a JSON object: %v", err)
	}
	if len(keys) != 5 {
		t.Errorf("record keys = %d %v, want the 5 documented keys", len(keys), keys)
	}
	for _, k := range []string{"ts", "run_id", "phase", "kind", "detail"} {
		if _, ok := keys[k]; !ok {
			t.Errorf("record is missing the documented key %q", k)
		}
	}
}

func TestDetailIsOmittedWhenEmpty(t *testing.T) {
	s := newSpool(t)
	rec := sample()
	rec.Detail = ""
	if _, err := s.Append(rec); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(s.Path())
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "detail") {
		t.Errorf("empty detail was written: %s", raw)
	}
}

func TestKindSetIsClosed(t *testing.T) {
	want := []Kind{KindStart, KindEnd, KindGate, KindHalt}
	if len(AllKinds) != len(want) {
		t.Fatalf("AllKinds = %v, want %v", AllKinds, want)
	}
	for i, k := range want {
		if AllKinds[i] != k {
			t.Errorf("AllKinds[%d] = %s, want %s", i, AllKinds[i], k)
		}
		if !ValidKind(k) {
			t.Errorf("ValidKind(%s) = false", k)
		}
	}
	for _, bad := range []Kind{"", "begin", "start ", "GATE", "complete", "phase_end"} {
		if ValidKind(bad) {
			t.Errorf("ValidKind(%q) = true", bad)
		}
	}
}

func TestAppendRejectsMalformedRecords(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(r *Record)
	}{
		{"no ts", func(r *Record) { r.TS = "" }},
		{"ts is not canonical", func(r *Record) { r.TS = "2026-11-17 09:00:00" }},
		{"ts is not UTC", func(r *Record) { r.TS = "2026-11-17T09:00:00+02:00" }},
		{"no run_id", func(r *Record) { r.RunID = "" }},
		{"no phase", func(r *Record) { r.Phase = "" }},
		{"kind is empty", func(r *Record) { r.Kind = "" }},
		{"kind is outside the set", func(r *Record) { r.Kind = "phase_end" }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := newSpool(t)
			rec := sample()
			tc.mutate(&rec)
			if _, err := s.Append(rec); !errors.Is(err, ErrInvalid) {
				t.Fatalf("err = %v, want ErrInvalid", err)
			}
			if _, err := os.Stat(s.Path()); !os.IsNotExist(err) {
				t.Errorf("an invalid record created %s", s.Path())
			}
		})
	}
}

// AC4: the (run_id, phase, kind) key is idempotent. The second append is refused
// with the typed error and writes nothing.
func TestAppendIsIdempotentOnRunPhaseKind(t *testing.T) {
	s := newSpool(t)
	if _, err := s.Append(sample()); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(s.Path())
	if err != nil {
		t.Fatal(err)
	}

	// Same key, later ts, new detail: still the same event.
	again := sample()
	again.TS = "2026-11-17T09:05:00Z"
	again.Detail = "replayed"
	line, err := s.Append(again)
	if !errors.Is(err, ErrDuplicate) {
		t.Fatalf("second Append err = %v, want ErrDuplicate", err)
	}
	if line != 1 {
		t.Errorf("duplicate reported line %d, want the existing line 1", line)
	}
	after, err := os.ReadFile(s.Path())
	if err != nil {
		t.Fatal(err)
	}
	if string(after) != string(before) {
		t.Errorf("the duplicate wrote to the spool:\nbefore %q\nafter  %q", before, after)
	}

	// A different kind on the same phase is a different event.
	next := sample()
	next.Kind = KindEnd
	if line, err := s.Append(next); err != nil || line != 2 {
		t.Errorf("Append(end) = line %d, err %v; want line 2, no error", line, err)
	}

	// A different run, same phase and kind, is a different event.
	other := sample()
	other.RunID = "CDT-643"
	if line, err := s.Append(other); err != nil || line != 3 {
		t.Errorf("Append(other run) = line %d, err %v; want line 3, no error", line, err)
	}
}

// Emit is the replay path: the second call reports created=false with no error.
func TestEmitFoldsTheDuplicateIntoCreatedFalse(t *testing.T) {
	s := newSpool(t)
	rec := sample()
	rec.TS = ""

	line, created, err := s.Emit(rec)
	if err != nil || !created {
		t.Fatalf("Emit = line %d created=%v err=%v; want line 1 created=true", line, created, err)
	}
	got, err := s.Records()
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 {
		t.Fatalf("records = %d, want 1", len(got))
	}
	if _, err := journal.ParseTS(got[0].TS); err != nil {
		t.Errorf("Emit did not stamp the canonical clock: %v", err)
	}

	line, created, err = s.Emit(rec)
	if err != nil {
		t.Fatalf("replay Emit err = %v, want nil (a replay must not fail)", err)
	}
	if created {
		t.Error("replay Emit reported created=true")
	}
	if line != 1 {
		t.Errorf("replay Emit line = %d, want 1", line)
	}
	if n, _ := s.Count(); n != 1 {
		t.Errorf("spool holds %d events after a replay, want 1", n)
	}
}

func TestHasReportsTheKey(t *testing.T) {
	s := newSpool(t)
	if ok, err := s.Has("CDT-642", "plan", KindGate); err != nil || ok {
		t.Errorf("Has on an empty spool = %v, %v", ok, err)
	}
	if _, err := s.Append(sample()); err != nil {
		t.Fatal(err)
	}
	if ok, err := s.Has("CDT-642", "plan", KindGate); err != nil || !ok {
		t.Errorf("Has after Append = %v, %v; want true, nil", ok, err)
	}
	if ok, err := s.Has("CDT-642", "plan", KindHalt); err != nil || ok {
		t.Errorf("Has for a kind that was not spooled = %v, %v", ok, err)
	}
}

func TestRecordsOnAMissingFileIsEmpty(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "absent", "spool.ndjson"))
	if err != nil {
		t.Fatal(err)
	}
	recs, err := s.Records()
	if err != nil || len(recs) != 0 {
		t.Errorf("Records = %v, %v; want empty, nil", recs, err)
	}
	if n, err := s.Count(); err != nil || n != 0 {
		t.Errorf("Count = %d, %v; want 0, nil", n, err)
	}
}

func TestRecordsRejectsASpoolThatBreaksTheShape(t *testing.T) {
	cases := map[string]string{
		"not JSON":        "this is not a record\n",
		"not an object":   "[1,2,3]\n",
		"unknown key":     `{"ts":"2026-11-17T09:00:00Z","run_id":"R","phase":"plan","kind":"gate","extra":1}` + "\n",
		"trailing object": `{"ts":"2026-11-17T09:00:00Z","run_id":"R","phase":"plan","kind":"gate"} {}` + "\n",
		"bad kind":        `{"ts":"2026-11-17T09:00:00Z","run_id":"R","phase":"plan","kind":"done"}` + "\n",
		"missing ts":      `{"run_id":"R","phase":"plan","kind":"gate"}` + "\n",
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "spool.ndjson")
			if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
				t.Fatal(err)
			}
			s, err := Open(path)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := s.Records(); !errors.Is(err, ErrBadLine) {
				t.Fatalf("err = %v, want ErrBadLine", err)
			}
		})
	}
}

// Untrusted text is data. A detail with shell metacharacters, a quote, and a
// newline stays one line and comes back verbatim.
func TestUntrustedDetailStaysData(t *testing.T) {
	s := newSpool(t)
	rec := sample()
	rec.Detail = "halt; rm -rf / $(whoami) `id` \"quoted\"\nsecond physical line"
	if _, err := s.Append(rec); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(s.Path())
	if err != nil {
		t.Fatal(err)
	}
	if n := strings.Count(string(raw), "\n"); n != 1 {
		t.Errorf("spool has %d lines, want 1 — a record escaped its line", n)
	}
	got, err := s.Records()
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 {
		t.Fatalf("records = %d, want 1", len(got))
	}
	if got[0].Detail != rec.Detail {
		t.Errorf("detail round-trip = %q, want %q", got[0].Detail, rec.Detail)
	}
}

func TestResolveHonoursTheEnvOverride(t *testing.T) {
	want := filepath.Join(t.TempDir(), "custom.ndjson")
	t.Setenv(EnvSpool, want)
	got, err := Resolve()
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Errorf("Resolve = %q, want %q", got, want)
	}
}

// AC3: the default path is $MROOT/.claude/runs/spool/spool.ndjson.
func TestResolveDefaultPathUnderMROOT(t *testing.T) {
	mroot := t.TempDir()
	t.Setenv(EnvSpool, "")
	t.Setenv(journal.EnvMROOT, mroot)
	got, err := Resolve()
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(mroot, ".claude", "runs", "spool", "spool.ndjson")
	if got != want {
		t.Errorf("Resolve = %q, want %q", got, want)
	}
	s, err := OpenDefault()
	if err != nil {
		t.Fatal(err)
	}
	if s.Path() != want {
		t.Errorf("OpenDefault path = %q, want %q", s.Path(), want)
	}
}

func TestOpenRefusesTheMemoryTree(t *testing.T) {
	cases := []string{
		filepath.Join(t.TempDir(), ".claude", "memory", "spool.ndjson"),
		filepath.Join(t.TempDir(), ".claude", "memory", "memory.db"),
	}
	for _, p := range cases {
		if _, err := Open(p); !errors.Is(err, ErrMemoryDB) {
			t.Errorf("Open(%s) err = %v, want ErrMemoryDB", p, err)
		}
	}
}

func TestAppendAfterOpenCreatesTheFile(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(filepath.Join(dir, "nested", "deeper", "spool.ndjson"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Append(sample()); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(s.Path()); err != nil {
		t.Errorf("spool file missing: %v", err)
	}
}
