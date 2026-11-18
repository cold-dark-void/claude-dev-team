package chief

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// argvRecorder is a stub script the seams exec: it records its argv as one
// line, so a test can hold the exact call the seam made, and prints one
// canned stdout line.
func argvStub(stdout string) string {
	return `#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CHIEF_SEAM_LOG"
printf '%s\n' ` + stdout + `
`
}

// plantSeam writes the stub script at a fixture plugin root and returns the
// root and the log path.
func plantSeam(t *testing.T, rel, stdout string) (string, string) {
	t.Helper()
	root := t.TempDir()
	path := filepath.Join(root, rel)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(argvStub(stdout)), 0o755); err != nil {
		t.Fatal(err)
	}
	log := filepath.Join(t.TempDir(), "argv.log")
	t.Setenv("CHIEF_SEAM_LOG", log)
	return root, log
}

// The ticket seam execs the plugin's own ticket verbs as argv — one call per
// record, the store root the backlog rule names, the slug from the verbs'
// own output.
func TestTicketCLIExecsThePluginVerbs(t *testing.T) {
	root, log := plantSeam(t, "skills/backlog/ticket.sh", "'Added: /store/dark-launch.md'")
	store := t.TempDir()
	seat := &ticketCLI{
		root:  func() (string, error) { return root, nil },
		store: func() (string, error) { return store, nil },
	}
	rec, err := seat.Create(context.Background(), TicketRequest{
		Kind: "ticket", Title: "Dark launch", Problem: "the premise"})
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if rec.Slug != "dark-launch" || rec.Path != "/store/dark-launch.md" {
		t.Errorf("record = %+v, want the slug from the verbs' output", rec)
	}
	raw, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	argv := string(raw)
	for _, want := range []string{
		"create", "--root " + store, "--title Dark launch", "--problem the premise",
	} {
		if !strings.Contains(argv, want) {
			t.Errorf("argv %q lacks %q", argv, want)
		}
	}
	if strings.Contains(argv, "--kind") {
		t.Errorf("a plain ticket record passes no kind: %q", argv)
	}

	// A child record rides the epic frontmatter of the store's own shape.
	if _, err := seat.Create(context.Background(), TicketRequest{
		Kind: "child", Title: "Child one", Problem: "p",
		EpicParent: "dark-launch", ChildID: "C1"}); err != nil {
		t.Fatal(err)
	}
	raw, _ = os.ReadFile(log)
	argv = strings.Split(string(raw), "\n")[1]
	for _, want := range []string{"--kind child", "--epic-parent dark-launch", "--child-id C1"} {
		if !strings.Contains(argv, want) {
			t.Errorf("child argv %q lacks %q", argv, want)
		}
	}
}

// The real ticket verbs write the store: the seam is the plugin's own CLI,
// not a reimplementation of it.
func TestTicketCLIRunsTheRealVerbs(t *testing.T) {
	root, err := os.MkdirTemp("", "chief-store-*")
	if err != nil {
		t.Fatal(err)
	}
	// The store's lock dir sits under .claude/, which a real $MROOT carries.
	if err := os.MkdirAll(filepath.Join(root, ".claude"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DEVTEAM_MROOT", root)
	seat := &ticketCLI{
		root:  func() (string, error) { return "../..", nil },
		store: func() (string, error) { return root, nil },
	}
	rec, err := seat.Create(context.Background(), TicketRequest{
		Kind: "ticket", Title: "Chief Seams Test", Problem: "the premise"})
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, ".claude", "backlog", rec.Slug+".md")); err != nil {
		t.Fatalf("the store holds no record: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, ".claude", "backlog.md")); err != nil {
		t.Fatalf("the store index is missing: %v", err)
	}
}

// The Model map seam resolves through resolve-model.sh: a map hit is the
// script's own output, an empty resolution is the Tier default, and an
// unnamed agent never execs the script.
func TestModelMapResolution(t *testing.T) {
	t.Run("a map hit is the script output", func(t *testing.T) {
		root, log := plantSeam(t, "skills/model-map/resolve-model.sh", "'sonnet'")
		m := &bashModelMap{root: func() (string, error) { return root, nil }}
		model, source, err := m.Resolve(context.Background(), "ic5")
		if err != nil {
			t.Fatal(err)
		}
		if model != "sonnet" || source != "map" {
			t.Errorf("model = %q/%q, want sonnet/map", model, source)
		}
		raw, _ := os.ReadFile(log)
		if !strings.Contains(string(raw), "ic5") {
			t.Errorf("argv %q lacks the agent", raw)
		}
	})
	t.Run("an empty resolution is the tier default", func(t *testing.T) {
		root, _ := plantSeam(t, "skills/model-map/resolve-model.sh", "''")
		m := &bashModelMap{root: func() (string, error) { return root, nil }}
		model, source, err := m.Resolve(context.Background(), "ic5")
		if err != nil {
			t.Fatal(err)
		}
		if model != tierDefaultModel() || source != "tier-default" {
			t.Errorf("model = %q/%q, want the tier default", model, source)
		}
	})
	t.Run("an unnamed agent never execs the script", func(t *testing.T) {
		root, log := plantSeam(t, "skills/model-map/resolve-model.sh", "''")
		m := &bashModelMap{root: func() (string, error) { return root, nil }}
		model, source, err := m.Resolve(context.Background(), "")
		if err != nil {
			t.Fatal(err)
		}
		if model != tierDefaultModel() || source != "tier-default" {
			t.Errorf("model = %q/%q, want the tier default", model, source)
		}
		if _, err := os.Stat(log); err == nil {
			t.Error("the script ran for an unnamed agent")
		}
	})
	t.Run("the real script falls back to the tier default with no layers", func(t *testing.T) {
		// The worktree's checkout carries no Model map layer, so the real
		// script resolves empty: the Tier default (AC3). The script's own
		// suite owns the map-hit cases; the seam only execs it.
		m := &bashModelMap{root: func() (string, error) { return "../..", nil }}
		model, source, err := m.Resolve(context.Background(), "ic5")
		if err != nil {
			t.Fatalf("resolve-model.sh: %v", err)
		}
		if model != tierDefaultModel() || source != "tier-default" {
			t.Errorf("model = %q/%q, want the tier default", model, source)
		}
	})
}

// The phone seam pages through the intercom CLI's own send verb — one argv
// value, the sid pinned when the chief carries one.
func TestIntercomPageExecsTheSendVerb(t *testing.T) {
	root, log := plantSeam(t, "skills/intercom/intercom.sh", "'/state/outbox/q1.json'")
	p := &intercomPhone{root: func() (string, error) { return root, nil },
		sid: "ops-session"}
	if err := p.Page(context.Background(), "r1",
		"run r1 halted: stalled — no heartbeat for 2s (retry budget 2, 2 remaining)"); err != nil {
		t.Fatalf("page: %v", err)
	}
	raw, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	argv := string(raw)
	for _, want := range []string{"send", "--sid ops-session",
		"run r1 halted: stalled — no heartbeat for 2s (retry budget 2, 2 remaining)"} {
		if !strings.Contains(argv, want) {
			t.Errorf("argv %q lacks %q", argv, want)
		}
	}
	// The message is one argv value, never an assembled shell string.
	if !strings.Contains(argv, "\n") {
		t.Error("the recorder should hold one line per call")
	}
}
