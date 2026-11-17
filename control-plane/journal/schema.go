package journal

import (
	_ "embed"
	_ "modernc.org/sqlite" // embedded driver: ADR 0001 § Consequences ("SQLite needs an embedded driver in that same binary")
)

// schemaSQL is the one DDL home for the journal, mirrored from the
// skills/memory-store/schema.sql pattern (ADR 0001 § Consequences 4). The file
// is the contract: the append-only rule, the card-reference rule, the closed
// kind set, and the partial unique index on the idempotency key all live there.
//
//go:embed schema.sql
var schemaSQL string
