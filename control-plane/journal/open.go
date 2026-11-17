package journal

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// Environment contract (CDT-643 AC2).
const (
	// EnvRunDB overrides the journal path outright.
	EnvRunDB = "DEVTEAM_RUN_DB"
	// EnvMROOT overrides the $MROOT resolution, for containers and tests.
	EnvMROOT = "DEVTEAM_MROOT"
	// journalRelPath is the default location under $MROOT. .gitignore carries
	// the same pattern: the journal is process state, never committed
	// (docs/adr/0001-journal-engine.md § "The journal references decision-cards").
	journalRelPath = ".claude/runs/run.db"
)

// BusyTimeoutMS is the busy timeout set on every open — the
// skills/memory-store/memdb.sh:35 pattern (`.timeout 5000`). SQLite serializes
// writers with a timeout, not a queue (ADR 0001 § Cost 3), so every open sets it.
const BusyTimeoutMS = 5000

// Resolve returns the journal path: $DEVTEAM_RUN_DB, else
// $MROOT/.claude/runs/run.db. MROOT is $DEVTEAM_MROOT, else the parent of
// `git rev-parse --git-common-dir` (the AGENTS.md § Path resolution pattern),
// else the working directory.
func Resolve() (string, error) {
	if p := strings.TrimSpace(os.Getenv(EnvRunDB)); p != "" {
		return abs(p)
	}
	mroot, err := MROOT()
	if err != nil {
		return "", err
	}
	return abs(filepath.Join(mroot, journalRelPath))
}

// MROOT returns the repository root that anchors every plugin state record
// (docs/internal/control-plane/record-ownership.md § Ownership table).
func MROOT() (string, error) {
	if p := strings.TrimSpace(os.Getenv(EnvMROOT)); p != "" {
		return abs(p)
	}
	out, err := exec.Command("git", "rev-parse", "--git-common-dir").Output()
	if err == nil {
		if gc := strings.TrimSpace(string(out)); gc != "" {
			return abs(filepath.Dir(gc))
		}
	}
	return abs(".")
}

func abs(p string) (string, error) {
	a, err := filepath.Abs(p)
	if err != nil {
		return "", fmt.Errorf("%w: %v", ErrInvalid, err)
	}
	return filepath.Clean(a), nil
}

// refuseMemoryDB enforces "never in memory.db" at the only place it can be
// enforced: the open. Run state is not agent memory (ADR 0001 § Decision), so
// this engine will not touch the memory store under any name.
func refuseMemoryDB(path string) error {
	base := filepath.Base(path)
	if strings.EqualFold(base, "memory.db") {
		return fmt.Errorf("%w: %s", ErrMemoryDB, path)
	}
	clean := filepath.ToSlash(path)
	if strings.Contains(clean, "/.claude/memory/") {
		return fmt.Errorf("%w: the journal lives outside .claude/memory: %s", ErrMemoryDB, path)
	}
	return nil
}

// Open resolves the path from the environment and opens the journal.
func Open(ctx context.Context) (*Engine, error) {
	p, err := Resolve()
	if err != nil {
		return nil, err
	}
	return OpenPath(ctx, p)
}

// OpenPath opens the journal at path, creating the parent directory on first
// open (mkdir -p) and applying schema.sql if the file is new.
func OpenPath(ctx context.Context, path string) (*Engine, error) {
	if path == "" {
		return nil, fmt.Errorf("%w: empty path", ErrInvalid)
	}
	// Make the path absolute before the memory guard reads it. The guard
	// compares path components, so a relative ".claude/memory/run.db" is the
	// memory store and the raw string does not say so.
	path, err := abs(path)
	if err != nil {
		return nil, err
	}
	if err := refuseMemoryDB(path); err != nil {
		return nil, err
	}
	if dir := filepath.Dir(path); dir != "" && dir != "/" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, fmt.Errorf("journal: create %s: %w", dir, err)
		}
	}

	// One writer per open: the pool is capped at one connection, so a write
	// transaction and its reads are the same connection, and a second writer
	// waits on the busy timeout instead of interleaving (ADR 0001 § Cost 3).
	dsn := dsnFor(path)
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("journal: open %s: %w", path, err)
	}
	db.SetMaxOpenConns(1)
	e := &Engine{db: db, path: path}
	if err := e.init(ctx); err != nil {
		db.Close()
		return nil, err
	}
	return e, nil
}

// dsnFor builds the connection string. The pragmas are part of the open, not an
// option: busy_timeout (memdb.sh:35), WAL + synchronous=FULL for the kill test
// (a SIGKILL and a forced reboot must not lose a committed row), foreign_keys.
func dsnFor(path string) string {
	q := url.Values{}
	q.Add("_pragma", fmt.Sprintf("busy_timeout(%d)", BusyTimeoutMS))
	q.Add("_pragma", "journal_mode(WAL)")
	q.Add("_pragma", "synchronous(FULL)")
	q.Add("_pragma", "foreign_keys(1)")
	u := url.URL{Scheme: "file", Path: filepath.ToSlash(path), RawQuery: q.Encode()}
	return u.String()
}

func (e *Engine) init(ctx context.Context) error {
	// The schema is our own embedded DDL, applied as one script: it is trusted
	// text, so it does not pass through execGuard (which guards caller SQL). The
	// driver runs the statements in order and stops at the first failure, which
	// is what -bail does for the plugin's memdb.sh:35 pattern.
	if _, err := e.db.ExecContext(ctx, schemaSQL); err != nil {
		return fmt.Errorf("journal: apply schema: %w", err)
	}
	var version string
	row := e.db.QueryRowContext(ctx, `SELECT value FROM journal_meta WHERE key = 'schema_version'`)
	if err := row.Scan(&version); err != nil && !errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("journal: read schema_version: %w", err)
	}
	if version != "" && version != SchemaVersion {
		return fmt.Errorf("%w: journal is %s, this build writes %s",
			ErrSchemaVersion, version, SchemaVersion)
	}
	return nil
}

// SchemaVersion is the journal's own schema version. It is not a card's:
// SPEC-033 AC6/M13 keeps every decision-card at schema_version 1 and the
// journal never reads, writes, or bumps one.
const SchemaVersion = "1"

// Path returns the journal file this engine writes.
func (e *Engine) Path() string { return e.path }

// Close closes the pool. Safe to call once.
func (e *Engine) Close() error {
	if e.db == nil {
		return nil
	}
	return e.db.Close()
}
