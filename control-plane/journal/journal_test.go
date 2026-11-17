package journal

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func openTestEngine(t *testing.T) *Engine {
	t.Helper()
	e, err := OpenPath(context.Background(), filepath.Join(t.TempDir(), "run.db"))
	if err != nil {
		t.Fatalf("OpenPath: %v", err)
	}
	t.Cleanup(func() { _ = e.Close() })
	return e
}

func appendEvent(t *testing.T, e *Engine, runID string, kind Kind, payload any) Event {
	t.Helper()
	ev, err := NewEvent(runID, kind, payload)
	if err != nil {
		t.Fatalf("NewEvent(%s): %v", kind, err)
	}
	seq, err := e.Append(context.Background(), ev)
	if err != nil {
		t.Fatalf("Append(%s): %v", kind, err)
	}
	ev.Seq = seq
	return ev
}

// AC2: the path contract, and the rule that the journal is never memory.db.
func TestOpenPathContract(t *testing.T) {
	t.Run("default under MROOT", func(t *testing.T) {
		root := t.TempDir()
		t.Setenv(EnvMROOT, root)
		t.Setenv(EnvRunDB, "")
		got, err := Resolve()
		if err != nil {
			t.Fatalf("Resolve: %v", err)
		}
		want := filepath.Join(root, ".claude", "runs", "run.db")
		if got != want {
			t.Fatalf("Resolve() = %q, want %q", got, want)
		}
	})

	t.Run("DEVTEAM_RUN_DB wins", func(t *testing.T) {
		dir := t.TempDir()
		custom := filepath.Join(dir, "elsewhere.db")
		t.Setenv(EnvRunDB, custom)
		got, err := Resolve()
		if err != nil {
			t.Fatalf("Resolve: %v", err)
		}
		if got != custom {
			t.Fatalf("Resolve() = %q, want %q", got, custom)
		}
	})

	t.Run("parent directory is created on first open", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "a", "b", "run.db")
		e, err := OpenPath(context.Background(), path)
		if err != nil {
			t.Fatalf("OpenPath: %v", err)
		}
		_ = e.Close()
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("journal file not created: %v", err)
		}
	})

	t.Run("memory.db is refused", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), ".claude", "memory", "memory.db")
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if _, err := OpenPath(context.Background(), path); !errors.Is(err, ErrMemoryDB) {
			t.Fatalf("OpenPath(memory.db) err = %v, want ErrMemoryDB", err)
		}
	})

	t.Run("relative path opens at the working directory", func(t *testing.T) {
		root := t.TempDir()
		t.Chdir(root)
		e, err := OpenPath(context.Background(), filepath.Join("nested", "run.db"))
		if err != nil {
			t.Fatalf("OpenPath: %v", err)
		}
		_ = e.Close()
		if want := filepath.Join(root, "nested", "run.db"); e.Path() != want {
			t.Fatalf("Path() = %q, want %q", e.Path(), want)
		}
	})

	t.Run("relative path under .claude/memory is refused", func(t *testing.T) {
		root := t.TempDir()
		if err := os.MkdirAll(filepath.Join(root, ".claude", "memory"), 0o755); err != nil {
			t.Fatal(err)
		}
		t.Chdir(root)
		// The guard sees the raw string first; the path is made absolute before
		// the components are compared, so this is the memory store, not a journal.
		if _, err := OpenPath(context.Background(), ".claude/memory/run.db"); !errors.Is(err, ErrMemoryDB) {
			t.Fatalf(`OpenPath(".claude/memory/run.db") err = %v, want ErrMemoryDB`, err)
		}
		if _, err := os.Stat(filepath.Join(root, ".claude", "runs")); !os.IsNotExist(err) {
			t.Fatalf("refused open created state under %s: %v", root, err)
		}
	})

	t.Run("busy timeout is set on the open", func(t *testing.T) {
		e := openTestEngine(t)
		var ms int
		if err := e.db.QueryRow(`PRAGMA busy_timeout`).Scan(&ms); err != nil {
			t.Fatalf("PRAGMA busy_timeout: %v", err)
		}
		if ms != BusyTimeoutMS {
			t.Fatalf("busy_timeout = %d, want %d", ms, BusyTimeoutMS)
		}
	})
}

// AC3: one idempotency key, one row. A replay finds it and repeats nothing.
func TestIdempotencyKeyUniqueness(t *testing.T) {
	e := openTestEngine(t)
	ctx := context.Background()

	first, err := NewEvent("CDT-643", KindSideEffect, Effect{
		Effect: "push",
		Intent: []byte(`{"sha":"abc"}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	first.IdempotencyKey = "CDT-643:push:abc"
	seq, created, err := e.AppendIdempotent(ctx, first)
	if err != nil {
		t.Fatalf("first append: %v", err)
	}
	if !created {
		t.Fatal("first append reported created=false")
	}

	replay := first
	replay.Seq = 0
	seq2, created2, err := e.AppendIdempotent(ctx, replay)
	if err != nil {
		t.Fatalf("replay append must not error: %v", err)
	}
	if created2 {
		t.Fatal("replay append created a second row for the same key")
	}
	if seq2 != seq {
		t.Fatalf("replay returned seq %d, want the original %d", seq2, seq)
	}

	// A direct insert on the same key is a hard integrity failure. Raw, so the
	// partial unique index answers it and not the Go guard (which refuses any
	// INSERT into events outside Append).
	_, err = e.db.ExecContext(ctx,
		`INSERT INTO events (ts, run_id, kind, payload_json, idempotency_key)
		 VALUES ('2026-11-16T00:00:00Z', 'CDT-643', 'heartbeat', '{}', ?)`,
		first.IdempotencyKey)
	if err == nil {
		t.Fatal("duplicate idempotency_key insert succeeded")
	}
	if !isUniqueIndex(err) {
		t.Fatalf("duplicate insert err = %v, want a UNIQUE constraint failure", err)
	}
	if _, err := e.ExecContext(ctx,
		`INSERT INTO events (ts, run_id, kind, payload_json, idempotency_key)
		 VALUES ('2026-11-16T00:00:00Z', 'CDT-643', 'heartbeat', '{}', ?)`,
		first.IdempotencyKey); !errors.Is(err, ErrAppendOnly) {
		t.Fatalf("guarded insert err = %v, want ErrAppendOnly", err)
	}

	// NULL keys do not collide: most events carry no external effect.
	for i := 0; i < 3; i++ {
		appendEvent(t, e, "CDT-643", KindHeartbeat, HeartbeatPayload{Owner: "a", Token: 1})
	}
}

// AC2 + AC3 in code: Append is the only write path, at every layer.
func TestAppendOnlyEnforcement(t *testing.T) {
	e := openTestEngine(t)
	ctx := context.Background()
	appendEvent(t, e, "CDT-643", KindRunClaimed, ClaimPayload{Owner: "a", Token: 1})

	// Layer 2: the Go guard refuses the statement before SQLite sees it.
	for _, q := range []string{
		`UPDATE events SET kind = 'heartbeat' WHERE seq = 1`,
		`update main.events set payload_json = '{}'`,
		`DELETE FROM events WHERE run_id = 'CDT-643'`,
		`DELETE FROM main.events`,
		`WITH d AS (DELETE FROM events RETURNING seq) SELECT * FROM d`,
		`TRUNCATE TABLE events`,
		`REPLACE INTO events (seq, ts, run_id, kind) VALUES (1, 'x', 'y', 'z')`,
		`DROP TABLE events`,
		`ALTER TABLE events ADD COLUMN extra TEXT`,
		// Quoting is resolved before matching: a quoted identifier is the plain
		// name, so it cannot hide a write target from layer 2.
		`DROP TABLE "events"`,
		"DROP TABLE `events`",
		`ALTER TABLE "events" RENAME TO x`,
		`DELETE FROM "events"`,
		`DELETE FROM "main"."events" WHERE seq = 1`,
		`UPDATE "events" SET kind = 'heartbeat' WHERE seq = 1`,
		// Structure is append-only too: DROP/ALTER are refused on any table.
		`DROP TABLE lease`,
		`ALTER TABLE lease DROP COLUMN stall_limit_s`,
		`DROP INDEX idx_events_idem`,
		`INSERT INTO events (ts, run_id, kind) VALUES ('2026-11-16T00:00:00Z', 'r', 'heartbeat')`,
		`CREATE TRIGGER evil AFTER INSERT ON events BEGIN DELETE FROM events; END`,
	} {
		if _, err := e.ExecContext(ctx, q); !errors.Is(err, ErrAppendOnly) {
			t.Errorf("ExecContext(%q) err = %v, want ErrAppendOnly", q, err)
		}
		if _, err := e.QueryContext(ctx, q); !errors.Is(err, ErrAppendOnly) {
			t.Errorf("QueryContext(%q) err = %v, want ErrAppendOnly", q, err)
		}
		if _, err := e.QueryRow(ctx, q); !errors.Is(err, ErrAppendOnly) {
			t.Errorf("QueryRow(%q) err = %v, want ErrAppendOnly", q, err)
		}
	}

	// A read that only mentions events in a value is not a write.
	benign, err := e.QueryContext(ctx,
		`SELECT ? WHERE ? = 'update events set x = 1'`, "ok", "update events set x = 1")
	if err != nil {
		t.Errorf("guard refused a benign query: %v", err)
	} else {
		benign.Close() // the pool is one connection wide; an open read blocks the journal
	}

	// A quoted identifier in a read is the plain column, not a write target:
	// unquoting must not turn every quoted token into a refusal.
	ident, err := e.QueryContext(ctx, `SELECT "seq" FROM events WHERE run_id = ?`, "CDT-643")
	if err != nil {
		t.Errorf("guard refused a quoted-identifier read: %v", err)
	} else {
		ident.Close()
	}

	// Layer 3: the triggers, reached by bypassing the guard entirely.
	for _, q := range []string{
		`UPDATE events SET kind = 'heartbeat' WHERE seq = 1`,
		`DELETE FROM events WHERE seq = 1`,
	} {
		if _, err := e.db.ExecContext(ctx, q); err == nil {
			t.Errorf("raw %s succeeded: the append-only trigger is missing", q)
		} else if !strings.Contains(err.Error(), "append-only") {
			t.Errorf("raw %s err = %v, want the append-only trigger message", q, err)
		}
	}

	// The journal is unchanged: one row, the claim.
	rows, err := e.Events(ctx, "CDT-643")
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].Kind != KindRunClaimed {
		t.Fatalf("journal after mutation attempts = %+v, want the single claim row", rows)
	}

	// Layer 1: the package surface has no mutation call. The engine exposes
	// Append, AppendIdempotent, and AppendChecked, and nothing that updates a
	// row. This assertion fails the build if that set changes shape.
	want := []string{
		"AllEvents", "Append", "AppendChecked", "AppendIdempotent", "Close", "Events",
		"ExecContext", "Path", "QueryContext", "QueryRow", "RunState", "Transact",
	}
	if got := exportedMethods(&Engine{}); !reflect.DeepEqual(got, want) {
		t.Errorf("Engine methods = %v, want %v", got, want)
	}
}

// exportedMethods lists the exported methods of v, sorted, for the surface test.
func exportedMethods(v any) []string {
	typ := reflect.TypeOf(v)
	out := make([]string, 0, typ.NumMethod())
	for i := 0; i < typ.NumMethod(); i++ {
		m := typ.Method(i)
		if m.IsExported() {
			out = append(out, m.Name)
		}
	}
	return out
}

// AC2: the row carries a card reference, never a card copy.
func TestCardReferenceOnly(t *testing.T) {
	e := openTestEngine(t)
	ctx := context.Background()

	ev, err := NewEvent("CDT-643", KindRunCompleted, CompletePayload{})
	if err != nil {
		t.Fatal(err)
	}
	ev.Card = &CardRef{
		Path:  ".claude/autopilot/CDT-643.jsonl",
		TS:    "2026-11-16T00:00:00Z",
		RunID: "CDT-643",
	}
	if _, err := e.Append(ctx, ev); err != nil {
		t.Fatalf("append with card reference: %v", err)
	}

	rows, err := e.Events(ctx, "CDT-643")
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].Card == nil {
		t.Fatalf("rows = %+v, want one row with a card reference", rows)
	}
	if *rows[0].Card != *ev.Card {
		t.Fatalf("card reference = %+v, want %+v", *rows[0].Card, *ev.Card)
	}

	// The schema carries exactly the three reference columns and no more.
	cols, err := columnNames(e.db, "events")
	if err != nil {
		t.Fatal(err)
	}
	var cardCols []string
	for _, c := range cols {
		if strings.HasPrefix(c, "card_") {
			cardCols = append(cardCols, c)
		}
	}
	if !reflect.DeepEqual(cardCols, cardColumns[:]) {
		t.Fatalf("card columns = %v, want %v", cardCols, cardColumns[:])
	}

	// A reference missing any part is refused.
	bad := ev
	bad.Card = &CardRef{Path: "p"}
	if err := bad.Validate(); !errors.Is(err, ErrInvalid) {
		t.Fatalf("partial card reference err = %v, want ErrInvalid", err)
	}

	// The journal writes no card: it has no card writer at all.
	if _, err := os.Stat(filepath.Join(filepath.Dir(e.Path()), "card.jsonl")); err == nil {
		t.Fatal("a card file appeared in the journal directory")
	}
}

func columnNames(db *sql.DB, table string) ([]string, error) {
	rows, err := db.Query(`SELECT name FROM pragma_table_info(?) ORDER BY cid`, table)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var n string
		if err := rows.Scan(&n); err != nil {
			return nil, err
		}
		out = append(out, n)
	}
	return out, rows.Err()
}
