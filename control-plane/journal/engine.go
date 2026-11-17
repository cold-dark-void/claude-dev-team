package journal

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"regexp"
	"strings"
)

// Engine is an open journal: one file, one writer at a time.
type Engine struct {
	db   *sql.DB
	path string
}

// Doer is the narrow write/read surface. *Engine (autocommit) and *Tx (inside
// one IMMEDIATE transaction) both satisfy it, so a caller writes its SQL once
// and the transaction boundary stays the caller's choice.
//
// Every Exec/Query method passes the statement through execGuard first. Values
// bind as ? parameters (the skills/lib/sqlq.sh convention); no caller
// interpolates a value into SQL text.
type Doer interface {
	Append(ctx context.Context, ev Event) (int64, error)
	AppendIdempotent(ctx context.Context, ev Event) (seq int64, created bool, err error)
	AppendChecked(ctx context.Context, ev Event) (int64, bool, error)
	Events(ctx context.Context, runID string) ([]Event, error)
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	QueryRow(ctx context.Context, query string, args ...any) (*sql.Row, error)
}

var (
	_ Doer = (*Engine)(nil)
	_ Doer = (*Tx)(nil)
)

// Append adds one event and returns its seq. It is the only write path for the
// events table: this package exposes no update, no delete, and no replace.
//
// A side effect goes through AppendIdempotent, not Append, so a replay can find
// the intent it already recorded.
func (e *Engine) Append(ctx context.Context, ev Event) (int64, error) {
	seq, _, err := e.AppendIdempotent(ctx, ev)
	return seq, err
}

// AppendIdempotent appends ev. When ev.IdempotencyKey is already recorded it
// returns that row's seq with created=false and writes nothing (AC3): the
// effect behind the key already happened, so a replay does not repeat it.
//
// The key check and the insert share one IMMEDIATE transaction, so two writers
// cannot both see "absent". The partial unique index idx_events_idem in
// schema.sql is the backstop if that guarantee is ever broken.
func (e *Engine) AppendIdempotent(ctx context.Context, ev Event) (int64, bool, error) {
	var (
		seq     int64
		created bool
	)
	err := e.Transact(ctx, func(tx *Tx) error {
		var err error
		seq, created, err = tx.AppendIdempotent(ctx, ev)
		return err
	})
	return seq, created, err
}

// Events returns every row of one run in seq order.
func (e *Engine) Events(ctx context.Context, runID string) ([]Event, error) {
	return eventsQuery{e.db}.get(ctx, runID)
}

// AllEvents returns every row in the journal in seq order, across runs.
func (e *Engine) AllEvents(ctx context.Context) ([]Event, error) {
	return eventsQuery{e.db}.all(ctx)
}

// RunState replays one run's journal into its current state.
func (e *Engine) RunState(ctx context.Context, runID string) (*State, error) {
	events, err := e.Events(ctx, runID)
	if err != nil {
		return nil, err
	}
	return Replay(events)
}

// ExecContext runs a guarded statement outside a transaction.
func (e *Engine) ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error) {
	if err := execGuard(query); err != nil {
		return nil, err
	}
	res, err := e.db.ExecContext(ctx, query, args...)
	return res, wrapBusy(err)
}

// QueryContext runs a guarded query.
func (e *Engine) QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error) {
	if err := execGuard(query); err != nil {
		return nil, err
	}
	rows, err := e.db.QueryContext(ctx, query, args...)
	return rows, wrapBusy(err)
}

// QueryRow runs a guarded single-row query.
func (e *Engine) QueryRow(ctx context.Context, query string, args ...any) (*sql.Row, error) {
	if err := execGuard(query); err != nil {
		return nil, err
	}
	return e.db.QueryRowContext(ctx, query, args...), nil
}

// Transact runs fn inside one BEGIN IMMEDIATE transaction on a single
// connection: the write lock is taken at BEGIN, so a state check and the event
// that changes that state are atomic against every other writer.
//
// fn must not call the Engine that opened the transaction: the pool is one
// connection wide (single-writer discipline), so a nested call would wait on
// the busy timeout instead of joining the transaction. fn returns an error to
// roll back, which is what makes "invalid transition, nothing written" true.
func (e *Engine) Transact(ctx context.Context, fn func(tx *Tx) error) error {
	conn, err := e.db.Conn(ctx)
	if err != nil {
		return wrapBusy(err)
	}
	defer conn.Close()

	if _, err := conn.ExecContext(ctx, "BEGIN IMMEDIATE"); err != nil {
		return wrapBusy(err)
	}
	committed := false
	defer func() {
		if !committed {
			// Best effort: a failed COMMIT or a fn error already left a dead
			// transaction, and closing the connection drops it.
			_, _ = conn.ExecContext(context.Background(), "ROLLBACK")
		}
	}()

	if err := fn(&Tx{conn: conn}); err != nil {
		return err
	}
	if _, err := conn.ExecContext(ctx, "COMMIT"); err != nil {
		return wrapBusy(err)
	}
	committed = true
	return nil
}

// Tx is a journal transaction. It is a Doer: appends and lease writes inside it
// commit together, or not at all.
type Tx struct {
	conn *sql.Conn
}

// Append adds one event inside the transaction.
func (t *Tx) Append(ctx context.Context, ev Event) (int64, error) {
	seq, _, err := t.AppendIdempotent(ctx, ev)
	return seq, err
}

// AppendIdempotent appends inside the transaction, with the same key rule as
// Engine.AppendIdempotent.
func (t *Tx) AppendIdempotent(ctx context.Context, ev Event) (int64, bool, error) {
	if err := ev.Validate(); err != nil {
		return 0, false, err
	}

	if ev.IdempotencyKey != "" {
		var seq int64
		row := t.conn.QueryRowContext(ctx,
			`SELECT seq FROM events WHERE idempotency_key = ?`, ev.IdempotencyKey)
		switch err := row.Scan(&seq); {
		case err == nil:
			return seq, false, nil
		case !errors.Is(err, sql.ErrNoRows):
			return 0, false, wrapBusy(err)
		}
	}

	card := ev.cardBindArgs()
	if len(card) != cardArgCount {
		return 0, false, fmt.Errorf("%w: card reference carries %d values, schema binds %d",
			ErrInvalid, len(card), cardArgCount)
	}
	args := make([]any, 0, eventBindCount)
	args = append(args, ev.TS, ev.RunID, string(ev.Kind), string(ev.Payload), nil)
	if ev.IdempotencyKey != "" {
		args[keyIndex] = ev.IdempotencyKey
	}
	args = append(args, card...)
	if len(args) != eventBindCount {
		return 0, false, fmt.Errorf("%w: %d bind values, statement binds %d",
			ErrInvalid, len(args), eventBindCount)
	}

	res, err := t.conn.ExecContext(ctx, insertEventSQL, args...)
	if err != nil {
		if isUniqueIndex(err) {
			return 0, false, fmt.Errorf("%w: %s", ErrDuplicateKey, ev.IdempotencyKey)
		}
		return 0, false, wrapBusy(err)
	}
	seq, err := res.LastInsertId()
	if err != nil {
		return 0, false, wrapBusy(err)
	}
	return seq, true, nil
}

// insertEventSQL binds ts, run_id, kind, payload_json, idempotency_key, then
// exactly the cardColumns, in order.
const insertEventSQL = `INSERT INTO events
    (ts, run_id, kind, payload_json, idempotency_key, card_path, card_ts, card_run_id)
  VALUES (?, ?, ?, ?, ?, ?, ?, ?)`

// cardArgCount is the compile-time statement that a row carries exactly the
// three card reference columns and nothing else.
const cardArgCount = len(cardColumns)

// eventBindCount is the width of one event row: four required columns, one key,
// and the card reference.
const eventBindCount = 5 + cardArgCount

// keyIndex is the position of idempotency_key in the bind list: NULL when the
// event carries no external effect.
const keyIndex = 4

// Events returns one run's rows inside the transaction (read-your-writes).
func (t *Tx) Events(ctx context.Context, runID string) ([]Event, error) {
	return eventsQuery{t.conn}.get(ctx, runID)
}

// AppendChecked appends only if the event is legal for the state its
// predecessors build. The candidate is replayed against the run's rows inside
// the same IMMEDIATE transaction, so an illegal transition is refused before
// the insert and the transaction writes nothing.
//
// Replay is the state machine: this is the one place transition legality is
// checked, so the append path and the recovery path cannot disagree (AC1).
func (t *Tx) AppendChecked(ctx context.Context, ev Event) (int64, bool, error) {
	events, err := t.Events(ctx, ev.RunID)
	if err != nil {
		return 0, false, err
	}
	// A key that is already recorded is the replay case, not an error: the
	// effect behind it happened (AC3). Find the row; write nothing.
	if ev.IdempotencyKey != "" {
		for _, e := range events {
			if e.IdempotencyKey == ev.IdempotencyKey {
				return e.Seq, false, nil
			}
		}
	}
	if _, err := ReplayFrom(nil, append(append([]Event(nil), events...), ev)); err != nil {
		return 0, false, err
	}
	return t.AppendIdempotent(ctx, ev)
}

// AppendChecked is the autocommit form of Tx.AppendChecked: the replay check and
// the insert share one transaction.
func (e *Engine) AppendChecked(ctx context.Context, ev Event) (int64, bool, error) {
	var (
		seq     int64
		created bool
	)
	err := e.Transact(ctx, func(tx *Tx) error {
		var err error
		seq, created, err = tx.AppendChecked(ctx, ev)
		return err
	})
	return seq, created, err
}

// ExecContext runs a guarded statement inside the transaction.
func (t *Tx) ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error) {
	if err := execGuard(query); err != nil {
		return nil, err
	}
	res, err := t.conn.ExecContext(ctx, query, args...)
	return res, wrapBusy(err)
}

// QueryContext runs a guarded query inside the transaction.
func (t *Tx) QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error) {
	if err := execGuard(query); err != nil {
		return nil, err
	}
	rows, err := t.conn.QueryContext(ctx, query, args...)
	return rows, wrapBusy(err)
}

// QueryRow runs a guarded single-row query inside the transaction.
func (t *Tx) QueryRow(ctx context.Context, query string, args ...any) (*sql.Row, error) {
	if err := execGuard(query); err != nil {
		return nil, err
	}
	return t.conn.QueryRowContext(ctx, query, args...), nil
}

const selectEventsSQL = `SELECT seq, ts, run_id, kind, payload_json,
         idempotency_key, card_path, card_ts, card_run_id
    FROM events`

// eventsQuery reads rows over any queryer (pool or transaction connection).
type eventsQuery struct{ q queryer }

type queryer interface {
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
}

func (eq eventsQuery) scan(rows *sql.Rows) ([]Event, error) {
	var out []Event
	for rows.Next() {
		var (
			ev      Event
			kind    sql.NullString
			payload string
			key     sql.NullString
			cp      sql.NullString
			cts     sql.NullString
			crid    sql.NullString
		)
		if err := rows.Scan(&ev.Seq, &ev.TS, &ev.RunID, &kind, &payload,
			&key, &cp, &cts, &crid); err != nil {
			return nil, wrapBusy(err)
		}
		ev.Kind = Kind(kind.String)
		ev.Payload = []byte(payload)
		ev.IdempotencyKey = key.String
		if cp.Valid && cts.Valid && crid.Valid {
			ev.Card = &CardRef{Path: cp.String, TS: cts.String, RunID: crid.String}
		}
		out = append(out, ev)
	}
	return out, wrapBusy(rows.Err())
}

func (eq eventsQuery) get(ctx context.Context, runID string) ([]Event, error) {
	if runID == "" {
		return nil, fmt.Errorf("%w: run_id is required", ErrInvalid)
	}
	rows, err := eq.q.QueryContext(ctx, selectEventsSQL+` WHERE run_id = ? ORDER BY seq ASC`, runID)
	if err != nil {
		return nil, wrapBusy(err)
	}
	defer rows.Close()
	return eq.scan(rows)
}

func (eq eventsQuery) all(ctx context.Context) ([]Event, error) {
	rows, err := eq.q.QueryContext(ctx, selectEventsSQL+` ORDER BY seq ASC`)
	if err != nil {
		return nil, wrapBusy(err)
	}
	defer rows.Close()
	return eq.scan(rows)
}

// execGuard is enforcement layer 2 of the append-only rule (layer 1 is the
// absence of any mutation call in this package; layer 3 is the SQLite triggers
// in schema.sql). It refuses every statement that writes the events table, and
// every statement that changes table structure, and it guards queries too,
// because SQLite answers
// `WITH d AS (DELETE FROM events RETURNING *) SELECT * FROM d`.
func execGuard(query string) error {
	normalized := stripQuotedText(query)
	for _, g := range []struct {
		re   *regexp.Regexp
		what string
	}{
		{eventsWriteRE, "writes events"},
		{structureRE, "changes table structure"},
	} {
		loc := g.re.FindStringIndex(normalized)
		if loc == nil {
			continue
		}
		return fmt.Errorf("%w: refused statement %s: %.60s", ErrAppendOnly, g.what,
			strings.Join(strings.Fields(normalized[loc[0]:]), " "))
	}
	return nil
}

// eventsWriteRE matches a statement that writes, replaces, drops, alters, or
// triggers the events table, in any schema. The distance bound keeps the match
// on the target of the verb.
var eventsWriteRE = regexp.MustCompile(
	`(?is)\b(update|delete\s+from|truncate\s+table|replace\s+into|insert\s+into|` +
		`drop\s+table|alter\s+table|create\s+trigger)\b[\s\S]{0,48}?\bevents\b`)

// structureRE is the blocklist for DDL: append-only covers the shape of the
// journal as well as its rows, so DROP and ALTER are refused on any table, not
// only on events. Layer 3 cannot cover them — SQLite has no DROP or ALTER
// trigger — so this pattern is the only defence, and it is unconditional.
var structureRE = regexp.MustCompile(`(?is)\b(drop|alter)\b`)

// stripQuotedText normalises quoting so the guard matches a statement's targets
// and not its text:
//
//   - a single-quoted string literal keeps its delimiters and loses its
//     contents, so a value that merely mentions "events" is not a write target;
//   - a double-quoted or backtick identifier loses its delimiters and keeps its
//     text, so DROP TABLE "events" resolves to the plain name the patterns
//     match. SQLite reads a double-quoted token as an identifier first, so a
//     value written that way is a value this guard refuses; write values in
//     single quotes.
func stripQuotedText(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	for i := 0; i < len(s); {
		switch c := s[i]; c {
		case '\'':
			b.WriteByte(c)
			for i++; i < len(s); i++ {
				b.WriteByte(' ')
				if s[i] == '\'' {
					break
				}
			}
		case '"', '`':
			for i++; i < len(s) && s[i] != c; i++ {
				b.WriteByte(s[i])
			}
			if i < len(s) {
				i++
			}
		default:
			b.WriteByte(c)
			i++
		}
	}
	return b.String()
}

// isUniqueIndex reports a UNIQUE constraint failure behind the idempotency key.
func isUniqueIndex(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "UNIQUE constraint failed") &&
		strings.Contains(msg, "idempotency_key")
}

// wrapBusy labels SQLite lock contention so a caller can retry the whole call.
func wrapBusy(err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, ErrBusy) || errors.Is(err, context.Canceled) ||
		errors.Is(err, context.DeadlineExceeded) {
		return err
	}
	if msg := err.Error(); strings.Contains(msg, "database is locked") ||
		strings.Contains(msg, "SQLITE_BUSY") {
		return fmt.Errorf("%w: %v", ErrBusy, err)
	}
	return err
}

// init asserts the bind-width contract: the statement, the row, and the card
// reference must stay the same width as the schema.
func init() {
	if n := strings.Count(insertEventSQL, "?"); n != eventBindCount {
		panic(fmt.Sprintf("journal: insert binds %d placeholders, event row is %d wide", n, eventBindCount))
	}
}
