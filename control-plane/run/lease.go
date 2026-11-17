package run

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/cold-dark-void/claude-dev-team/control-plane/journal"
)

// Lease is one owner per run, with a monotonic fencing token (AC4). The row
// lives in the journal file (journal/schema.sql § lease): the lock record and
// the journal commit together, so an owner cannot append an event it is not
// fenced for.
//
// The lease table is the mutable lock record of the `single-writer-lease`
// conflict rule (docs/internal/control-plane/record-ownership.md § The closed
// conflict-rule set). It is not the journal: every acquisition of it is journaled.
type Lease struct {
	RunID           string
	Owner           string
	Token           int64
	AcquiredAt      string
	LastHeartbeatTS string
	StallLimitS     int64
}

// Expired reports whether the lease's own stall limit has passed since its last
// heartbeat, measured at now.
func (l Lease) Expired(now time.Time) bool {
	t, err := journal.ParseTS(l.LastHeartbeatTS)
	if err != nil {
		// A lease with an unreadable heartbeat is treated as expired: an owner
		// that cannot prove liveness must not block a takeover.
		return true
	}
	return now.UTC().Sub(t) > time.Duration(l.StallLimitS)*time.Second
}

const (
	selectLeaseSQL = `SELECT owner, token, acquired_at, last_heartbeat_ts, stall_limit_s
                        FROM lease WHERE run_id = ?`
	insertLeaseSQL = `INSERT INTO lease
	    (run_id, owner, token, acquired_at, last_heartbeat_ts, stall_limit_s)
	    VALUES (?, ?, ?, ?, ?, ?)`
	// takeLeaseSQL is the compare-and-set: it moves the token forward by one and
	// lands only if the row still carries the token the reader saw, the row's
	// owner is not the caller, and that owner's heartbeat is older than its own
	// stall limit.
	takeLeaseSQL = `UPDATE lease
	      SET owner = ?, token = token + 1, acquired_at = ?, last_heartbeat_ts = ?, stall_limit_s = ?
	    WHERE run_id = ? AND token = ? AND owner <> ? AND last_heartbeat_ts <= ?`
	// beatLeaseSQL is the heartbeat compare-and-set on (owner, token).
	beatLeaseSQL = `UPDATE lease SET last_heartbeat_ts = ?
	     WHERE run_id = ? AND owner = ? AND token = ? AND token >= 1`
	releaseLeaseSQL = `DELETE FROM lease WHERE run_id = ?`
)

// Lease acquisition reasons, journaled in lease_acquired.
const (
	leaseNew      = "claim"
	leaseTakeover = "takeover"
	leaseSelf     = "self"
)

// acquireLease takes the lease for owner and returns its token and how it was
// obtained. It must run inside a journal transaction: the append that records
// the acquisition commits with it.
func acquireLease(ctx context.Context, d journal.Doer, runID, owner string,
	stall time.Duration, now time.Time) (int64, string, error) {
	if owner == "" {
		return 0, "", fmt.Errorf("%w: owner is required", journal.ErrInvalid)
	}
	if stall <= 0 {
		return 0, "", fmt.Errorf("%w: stall limit must be positive, got %s", journal.ErrInvalid, stall)
	}
	ts := journal.FormatTS(now)

	cur, err := readLease(ctx, d, runID)
	if errors.Is(err, journal.ErrNoLease) {
		res, err := d.ExecContext(ctx, insertLeaseSQL, runID, owner, int64(1), ts, ts,
			int64(stall/time.Second))
		if err != nil {
			return 0, "", err
		}
		n, err := res.RowsAffected()
		if err != nil {
			return 0, "", fmt.Errorf("run: lease insert: %w", err)
		}
		if n != 1 {
			return 0, "", fmt.Errorf("%w: %s", journal.ErrLeaseHeld, runID)
		}
		return 1, leaseNew, nil
	}
	if err != nil {
		return 0, "", err
	}

	if cur.Owner == owner {
		// Same owner: keep the token, so work already in flight stays fenced.
		return cur.Token, leaseSelf, nil
	}
	if !cur.Expired(now) {
		return 0, "", fmt.Errorf("%w: run %s is owned by %q (token %d, heartbeat %s, limit %ds)",
			journal.ErrLeaseHeld, runID, cur.Owner, cur.Token, cur.LastHeartbeatTS, cur.StallLimitS)
	}

	cutoff := journal.FormatTS(now.Add(-time.Duration(cur.StallLimitS) * time.Second))
	res, err := d.ExecContext(ctx, takeLeaseSQL, owner, ts, ts, int64(stall/time.Second),
		runID, cur.Token, owner, cutoff)
	if err != nil {
		return 0, "", err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, "", err
	}
	if n != 1 {
		// Another owner landed the same takeover first.
		return 0, "", fmt.Errorf("%w: run %s, token %d moved during takeover",
			journal.ErrLeaseHeld, runID, cur.Token)
	}
	return cur.Token + 1, leaseTakeover, nil
}

// readLease returns the live lease for a run.
func readLease(ctx context.Context, d journal.Doer, runID string) (Lease, error) {
	var l Lease
	row, err := d.QueryRow(ctx, selectLeaseSQL, runID)
	if err != nil {
		return Lease{}, err
	}
	err = row.Scan(&l.Owner, &l.Token, &l.AcquiredAt, &l.LastHeartbeatTS, &l.StallLimitS)
	if errors.Is(err, sql.ErrNoRows) {
		return Lease{}, fmt.Errorf("%w: %s", journal.ErrNoLease, runID)
	}
	if err != nil {
		return Lease{}, err
	}
	l.RunID = runID
	return l, nil
}

// ReadLease returns the live lease for the run, for a status surface.
func (m *Machine) ReadLease(ctx context.Context) (Lease, error) {
	return readLease(ctx, m.eng, m.runID)
}

// verifyLease is the fencing gate every mutating call passes. A token at or
// below the current one is refused with journal.ErrStaleToken (AC4): the caller
// is the zombie of an earlier owner, and its write would land after the new
// owner's.
func verifyLease(ctx context.Context, d journal.Doer, runID, owner string, token int64) (Lease, error) {
	l, err := readLease(ctx, d, runID)
	if err != nil {
		return Lease{}, err
	}
	if token != l.Token {
		return Lease{}, fmt.Errorf("%w: run %s presents token %d, current is %d (owner %q)",
			journal.ErrStaleToken, runID, token, l.Token, l.Owner)
	}
	if owner != l.Owner {
		return Lease{}, fmt.Errorf("%w: run %s is owned by %q, caller is %q",
			journal.ErrNotOwner, runID, l.Owner, owner)
	}
	return l, nil
}

// beatLease stamps the heartbeat. It is a compare-and-set on (owner, token), so
// a token that moved between the read and the write lands nowhere.
func beatLease(ctx context.Context, d journal.Doer, runID, owner string, token int64,
	now time.Time) error {
	res, err := d.ExecContext(ctx, beatLeaseSQL, journal.FormatTS(now), runID, owner, token)
	if err != nil {
		return err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 1 {
		return nil
	}
	// The compare-and-set missed: name the reason the caller can act on.
	if _, err := verifyLease(ctx, d, runID, owner, token); err != nil {
		return err
	}
	return fmt.Errorf("%w: run %s heartbeat landed on no row", journal.ErrNoLease, runID)
}

// releaseLease drops the lease when the run reaches a terminal state.
func releaseLease(ctx context.Context, d journal.Doer, runID string) error {
	_, err := d.ExecContext(ctx, releaseLeaseSQL, runID)
	return err
}

// ReleaseStaleLease drops a lease row whose own stall limit has passed. It is
// the state-machine path for the reconciler's release-stale-lease repair
// (CDT-643 AC5): the fencing check runs first, and a lease inside its limit is
// refused with journal.ErrLeaseHeld, so a live owner's lock is never taken. The
// lease record has no event of its own — the caller journals the repair
// (Machine.Repair) around it, which is what keeps the audit trail complete.
func (m *Machine) ReleaseStaleLease(ctx context.Context, owner string, token int64) error {
	return m.eng.Transact(ctx, func(tx *journal.Tx) error {
		l, err := verifyLease(ctx, tx, m.runID, owner, token)
		if err != nil {
			return err
		}
		if !l.Expired(m.now()) {
			return fmt.Errorf("%w: run %s lease owner %q heartbeat %s is inside its %ds stall limit",
				journal.ErrLeaseHeld, m.runID, l.Owner, l.LastHeartbeatTS, l.StallLimitS)
		}
		return releaseLease(ctx, tx, m.runID)
	})
}
