package journal

import (
	"context"
	"strings"
	"testing"
)

// The schema's own constraints, reached raw: the timestamp shape and the lease
// invariants are DDL rules, not Go rules.
func TestSchemaConstraints(t *testing.T) {
	e := openTestEngine(t)
	ctx := context.Background()

	good := `INSERT INTO events (ts, run_id, kind, payload_json)
	        VALUES ('2026-11-16T12:00:00Z', 'CDT-643', 'heartbeat', '{}')`
	if _, err := e.db.ExecContext(ctx, good); err != nil {
		t.Fatalf("the canonical row was refused: %v", err)
	}

	for name, q := range map[string]string{
		"space-separated ts": `INSERT INTO events (ts, run_id, kind) VALUES ('2026-11-16 12:00:00', 'r', 'heartbeat')`,
		"fractional ts":      `INSERT INTO events (ts, run_id, kind) VALUES ('2026-11-16T12:00:00.500Z', 'r', 'heartbeat')`,
		"offset ts":          `INSERT INTO events (ts, run_id, kind) VALUES ('2026-11-16T12:00:00+01:00', 'r', 'heartbeat')`,
		"not a date":         `INSERT INTO events (ts, run_id, kind) VALUES ('yesterday', 'r', 'heartbeat')`,
		"empty run_id":       `INSERT INTO events (ts, run_id, kind) VALUES ('2026-11-16T12:00:00Z', '', 'heartbeat')`,
		"kind outside set":   `INSERT INTO events (ts, run_id, kind) VALUES ('2026-11-16T12:00:00Z', 'r', 'made_up')`,
		"half a card ref":    `INSERT INTO events (ts, run_id, kind, card_path) VALUES ('2026-11-16T12:00:00Z', 'r', 'heartbeat', 'p')`,
		"bad lease token":    `INSERT INTO lease (run_id, owner, token, acquired_at, last_heartbeat_ts, stall_limit_s) VALUES ('r', 'o', 0, '2026-11-16T12:00:00Z', '2026-11-16T12:00:00Z', 60)`,
		"bad lease limit":    `INSERT INTO lease (run_id, owner, token, acquired_at, last_heartbeat_ts, stall_limit_s) VALUES ('r', 'o', 1, '2026-11-16T12:00:00Z', '2026-11-16T12:00:00Z', 0)`,
	} {
		if _, err := e.db.ExecContext(ctx, q); err == nil {
			t.Errorf("%s: the schema accepted it", name)
		} else if !strings.Contains(err.Error(), "constraint") {
			t.Errorf("%s: err = %v, want a constraint failure", name, err)
		}
	}

	// seq is monotonic and never reused: AUTOINCREMENT survives a reopen.
	path := e.Path()
	if err := e.Close(); err != nil {
		t.Fatal(err)
	}
	e2, err := OpenPath(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = e2.Close() })
	rows, err := e2.AllEvents(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].Seq != 1 {
		t.Fatalf("rows after reopen = %+v", rows)
	}
}

// Every kind in the closed set is appendable: schema and Go agree on the set.
func TestKindSetMatchesSchema(t *testing.T) {
	e := openTestEngine(t)
	ctx := context.Background()

	var inSet int
	row, err := e.QueryRow(ctx, `SELECT count(*) FROM events`)
	if err != nil {
		t.Fatal(err)
	}
	if err := row.Scan(&inSet); err != nil {
		t.Fatal(err)
	}

	// The schema's CHECK list, read back from the DDL, is the closed set.
	ddl, err := e.QueryRow(ctx,
		`SELECT sql FROM sqlite_master WHERE type='table' AND name='events'`)
	if err != nil {
		t.Fatal(err)
	}
	var text string
	if err := ddl.Scan(&text); err != nil {
		t.Fatal(err)
	}
	for _, k := range AllKinds {
		if !strings.Contains(text, "'"+string(k)+"'") {
			t.Errorf("kind %q is not in the schema CHECK set", k)
		}
	}
	if n := strings.Count(text, "kind IN"); n != 1 {
		t.Fatalf("kind CHECK count = %d, want 1", n)
	}
	for _, extra := range []string{"made_up", "run_cancelled", "side_effects"} {
		if strings.Contains(text, "'"+extra+"'") {
			t.Errorf("schema accepts the undefined kind %q", extra)
		}
	}
}
