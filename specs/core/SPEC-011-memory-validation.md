# SPEC-011: Memory Validation

**Status**: APPROVED
**Category**: core
**Created**: 2026-03-23

**Covers**: `commands/validate-memory.md`, `skills/validate-memory/SKILL.md`, `/memory-distill` integration (pre-distill hook), `skills/memory-store/migrate-v3.sh`

---

## Overview

Cross-references agent memories against the live codebase to detect and resolve stale references — dead files, renamed functions, shifted line numbers, outdated factual claims. Uses a multi-stage pipeline (validator proposes → tech-lead reviewer confirms → user decides ambiguous cases) with confidence scoring to minimize false positives. Runs standalone via `/validate-memory` or as an automatic pre-distill step in `/memory-distill`. Deep mode (`--deep`) rebuilds digests whose source material has gone stale.

---

## MUST

### Validation Engine
- MUST extract checkable claims from memory content via LLM-based claim extraction (Task subagent), producing structured claims with `claim_type` and `code_refs`
- MUST classify claims into one of six types: `file_reference`, `symbol_reference`, `line_content`, `behavioral`, `architectural`, `configuration`
- MUST verify `file_reference` and `symbol_reference` claims via deterministic bash checks (Tier A): file-scoped symbol lookup (check the specific file the memory claims, not global grep) and rename detection (glob for basename in nearby directories when file missing)
- MUST verify `line_content`, `behavioral`, `architectural`, and `configuration` claims via read-only LLM investigation (Tier B): investigator subagent with Read/Grep/Glob tools checks claim against actual code
- MUST produce per-claim verdicts using the four-term taxonomy: `VALID` (claim matches code), `STALE` (code changed, claim was probably true once), `CONTRADICTED` (claim is demonstrably false), `AMBIGUOUS` (cannot determine)
- MUST attach a confidence score (0-100) to each per-claim verdict
- MUST compute a composite staleness score (0-100) per memory as weighted average of per-claim verdict points: `CONTRADICTED`=40pts, `STALE`=25pts, `AMBIGUOUS`=10pts, `VALID`=0pts, each weighted by `confidence/100`, then averaged across claims, plus age modifier (0-5pts) and tier modifier (-5pts for tier-2)
- MUST resolve file paths relative to the project root (`WTROOT`)
- MUST skip memories with zero extractable checkable claims (not marked as validated)
- MUST use Opus model for the reviewer agent (judgment-heavy confirmation of medium-confidence entries); claim extraction and investigation subagents may use any available model
- MUST work via sqlite3 CLI for all DB operations (consistent with SPEC-004)
- MUST set `PRAGMA busy_timeout=5000` on every write operation
- MUST SQL-escape all content (single quotes → double single quotes)

### Action Thresholds (Multi-Stage Pipeline)
- MUST mark memories with stale confidence = 0 as clean pass: set `validated_at`, log action `'pass'` (enables idempotency — next run skips these)
- MUST surface memories with stale confidence 1-39 to the user as a non-blocking flagged list — command does NOT wait for user input; `validated_at` is NOT set on these entries
- MUST route memories with stale confidence 40-80 to tech-lead agent (Opus, per SPEC-003) for confirmation before acting (score of exactly 80 routes to reviewer, NOT auto-archive)
- MUST auto-archive memories with stale confidence >80 (strictly greater than)
- MUST present each flagged entry with: the memory content, per-claim verdicts with evidence, composite score breakdown, current codebase state for CONTRADICTED/STALE claims, and recommended action (archive / rewrite / keep)
- MUST accept reviewer agent responses as structured output: `ARCHIVE`, `REWRITE: <new content>`, or `KEEP`
- MUST batch reviewer invocations (max 20 entries per call, max 5 batches per run; remainder flagged for user)
- MUST batch claim extraction: up to 10 memories per extraction call, up to 10 batches per run (100 memories max); enforce via SQL LIMIT, overflow deferred to next run
- MUST batch Tier B investigation: up to 15 claims per investigation call, up to 5 batches per run (75 claims max); overflow claims skipped, parent memory deferred to next run
- MUST canonicalize and containment-check all file paths from extracted claims before any file operations (reject paths that escape `WTROOT`)
- MUST exclude `.claude/` directory from global symbol grep to prevent false positives from memory files
- MUST assign per-claim verdicts before computing per-memory composite scores
- MUST include per-claim verdict breakdown in the DETAIL report output

### Rewriting
- MUST append `\n\n[validated: YYYY-MM-DD]` to the end of rewritten memory content; replace existing `[validated:]` tag if present (no duplicates)
- MUST preserve the memory's original tier, type, and `distilled_from` when rewriting
- MUST UPDATE existing rows in-place when rewriting (same pattern as SPEC-007 tier promotion)
- MUST archive only, never delete memories (existing system invariant per SPEC-007)
- MUST execute rewrite SQL via the host command script (not by any agent directly)

### Schema Migration (v2 → v3)
- MUST add `validated_at TEXT DEFAULT NULL` column to memories table via `ALTER TABLE`
- MUST add `archive_reason TEXT DEFAULT NULL` column to memories table — values: `'distilled'` (set by distiller), `'stale'` (set by validator), `NULL` (legacy/unset)
- MUST create `validation_log` table: `id INTEGER PRIMARY KEY AUTOINCREMENT`, `memory_id INTEGER NOT NULL`, `agent TEXT NOT NULL`, `action TEXT NOT NULL CHECK(action IN ('pass','archive','rewrite','flag_review','flag_user'))`, `confidence INTEGER NOT NULL`, `reason TEXT`, `created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))`
- MUST add default config keys: `validate_window_days` (default: `'7'`)
- MUST check `schema_version = '2'` before migrating (exit 0 if already v3, exit 1 if not v2)
- MUST update `schema_version` to `'3'` only after all steps complete
- MUST be idempotent (safe to re-run)

### Validated Timestamp
- MUST set `validated_at` to current timestamp when a memory passes validation (clean) or is rewritten
- MUST NOT set `validated_at` on archived memories or user-flagged memories
- MUST skip memories where `validated_at` is within the configured `validate_window_days` window on subsequent runs
- MUST support `--force` flag to ignore `validated_at` and re-validate everything

### Deep Mode (`--deep`)
- MUST support `--deep` flag for full digest rebuild cycle
- MUST in deep mode: read all tier-1 digests → check if source memories (from `distilled_from`) have `archive_reason='stale'` → if >50% of sources are stale, flag the digest for rebuild (threshold fixed at 50% for v1)
- MUST rebuild flagged digests by: archiving the stale digest (set `archive_reason='stale'`), then invoking distiller agent to re-distill remaining valid source memories into a new digest
- MUST NOT archive digests if distiller lock is held (exit with error, try again later)
- MUST report deep mode actions: `@<agent>: N digests checked, M rebuilt, K archived, S skipped (locked)`

### `/memory-distill` Integration
- MUST run validation as pre-distill step by default when invoked via `/memory-distill`
- MUST support `--skip-validate` flag on `/memory-distill` to bypass pre-distill validation
- MUST complete validation before distillation begins (sequential, not parallel — garbage in prevention)
- MUST abort distillation if validation fails with non-zero exit (do not fall through)
- MUST run validation inside the distillation lock window (after lock acquired, before distiller spawned)

### Standalone Command (`/validate-memory`)
- MUST support invocation with no arguments (validate current project memories)
- MUST support `--agent <name>` flag to validate only one agent's memories
- MUST support `--deep` flag (digest rebuild, see above)
- MUST support `--force` flag (ignore validated_at window)
- MUST require SQLite DB (error with helpful message including path and init command reference)
- MUST output TLDR summary header followed by per-decision commentary
- MUST output format: `TLDR: @<agent>: N checked, M archived, K rewritten, J flagged for review` per agent, then detailed per-entry reasoning with per-claim verdict breakdown (memory ID, first 80 chars, score, action, then indented per-claim lines with verdict tag, confidence, and evidence)
- MUST exit 0 and output `TLDR: all memories validated within the last N days. Nothing to do. Use --force to re-validate.` when zero memories are eligible

### Idempotency
- MUST produce identical outcomes when run twice on an unchanged codebase (second run skips all validated entries, net changes = 0)

### Concurrency
- MUST exit with error if `/memory-distill` holds the `distilling_lock` (do not silently skip)
- MUST NOT hold its own lock (validation is read-heavy with targeted writes; distillation lock is sufficient for mutual exclusion)

---

## SHOULD

- SHOULD batch file existence checks for performance (collect all paths first, check in parallel)
- SHOULD detect renamed files via basename glob in nearby directories (Tier A rename detection) — flag as STALE rather than CONTRADICTED
- SHOULD weight recently-validated-clean memories lower priority in processing order (focus effort on never-validated entries first)
- SHOULD log all actions to `validation_log` table for audit trail
- SHOULD include per-claim verdict summary in `validation_log.reason` field for traceability

---

## MUST NOT

- MUST NOT delete memories (archive only — system invariant)
- MUST NOT change memory tier (only distiller may set tier > 0 per SPEC-007)
- MUST NOT validate context.md files (per-worktree, ephemeral, never in DB)
- MUST NOT auto-archive without confidence scoring (no blanket purges)
- MUST NOT run validation and distillation in parallel (sequential only — validate first)
- MUST NOT block on user input for low-confidence entries (non-blocking flagged list)

---

## Test

- Verify validation detects a memory referencing a deleted file (should score >80%, auto-archive with `archive_reason='stale'`)
- Verify validation detects a memory referencing a renamed function (should score 40-80%, route to reviewer)
- Verify validation passes a memory referencing an existing file+function (should score <40%, keep)
- Verify multi-stage pipeline: high-confidence auto-archives, medium routes to reviewer, low surfaces to user
- Verify `validated_at` timestamp is set on clean and rewritten memories, NOT on archived or flagged
- Verify subsequent run skips recently-validated memories (within configured window)
- Verify `--force` flag re-validates everything regardless of `validated_at`
- Verify `--deep` mode detects digests with >50% stale sources (by `archive_reason='stale'`) and rebuilds
- Verify `--deep` aborts if distiller lock is held
- Verify `/memory-distill` runs validation before distillation by default
- Verify `/memory-distill` aborts on validation failure
- Verify `--skip-validate` on `/memory-distill` bypasses validation
- Verify rewritten memories preserve original tier, type, and distilled_from
- Verify TLDR output format with per-agent summary
- Verify idempotency: second run on unchanged codebase produces zero changes
- Verify schema migration: validated_at, archive_reason columns, validation_log table, schema_version=3
- Verify concurrent run protection: exits with error if distilling_lock held
- Verify claim extraction produces structured claims from a memory with mixed file references and behavioral assertions
- Verify Tier A catches a symbol that exists globally but not in the claimed file (verdict: STALE, not VALID)
- Verify Tier B investigation detects a changed default value as STALE (not CONTRADICTED)
- Verify composite scoring averages across claims: 5 VALID + 1 STALE scores below 10
- Verify per-claim verdict breakdown appears in DETAIL report output

---

## Validation

- [ ] `validate-memory` with a memory referencing a deleted file archives it with `archive_reason='stale'`
- [ ] `validate-memory` with all-clean memories reports "0 archived, 0 rewritten"
- [ ] `validated_at` column exists after schema migration
- [ ] `archive_reason` column exists after schema migration
- [ ] `validation_log` table exists after schema migration
- [ ] `schema_version` = "3" after migration
- [ ] `--deep` rebuilds a digest whose sources have `archive_reason='stale'`
- [ ] `/memory-distill` output shows validation step before distillation
- [ ] Rewritten memory retains original tier value
- [ ] Second run with no codebase changes: zero archives, zero rewrites

---

## Resolved Questions

- [x] ~~7-day validated_at window configurable?~~ **Yes** — `validate_window_days` config key, default 7. Settable via `/memory-config`.
- [x] ~~50% stale-source threshold adjustable?~~ **No** — fixed at 50% for v1. Revisit if users request tuning.
- [x] ~~Cross-project (`--scope global`) discovery?~~ **Deferred** — removed from v1 scope. Will be a follow-up ticket.
- [x] ~~Validation log table?~~ **Yes** — `validation_log` table created in v3 migration, parity with `distillation_log`.
- [x] ~~Schema version after migration?~~ **"3"** — guards on v2, same pattern as v1→v2 migration.
- [x] ~~How to distinguish archive reasons?~~ **`archive_reason` column** — values: `'distilled'`, `'stale'`, `NULL` (legacy).

---

## Out of Scope (v1)

- `--scope global` cross-project validation (deferred to follow-up)
- Auto-triggering without user/distill invocation
- Validating non-code memories (process/decision notes with no checkable ground truth)
- Adjustable deep mode threshold

---

## Version History

| Date | Change |
|------|--------|
| 2026-03-23 | Initial spec created from brainstorm session |
| 2026-03-23 | Resolved all open questions per kickoff review. Added: archive_reason column, validation_log table, schema v3 migration, reviewer=tech-lead, non-blocking user flags, idempotency AC, concurrent run protection. Deferred --scope global. Status → APPROVED. |
| 2026-03-23 | Added score-0 "clean pass" bucket (sets validated_at) to fix idempotency gap for truly clean memories. Threshold buckets now: 0=pass, 1-39=flag_user, 40-80=reviewer, >80=auto-archive. |
| 2026-04-21 | Replaced regex-based reference extraction and bash-only scoring with LLM-based claim extraction + two-tier verification. Added claim types (file_reference, symbol_reference, line_content, behavioral, architectural, configuration), verdict taxonomy (VALID, STALE, CONTRADICTED, AMBIGUOUS), per-claim confidence scoring, composite weighted-average scoring. Tier A (bash) handles file/symbol refs with rename detection. Tier B (LLM investigator) handles behavioral/architectural/config/line claims. Prompt templates in skills/validate-memory/SKILL.md. |

---

## Cross-references

- SPEC-004: Memory Storage — validator reads/writes through same storage layer, uses same sqlite3 patterns; v3 migration extends v2 schema
- SPEC-006: Memory Retrieval — validated_at affects which memories load; archived entries already filtered
- SPEC-007: Memory Distillation — pre-distill integration; deep mode invokes distiller for rebuilds; tier access control respected; distiller must set `archive_reason='distilled'` when archiving
- SPEC-003: Agent Role System — validation uses Opus; reviewer is tech-lead agent (Opus)
- SPEC-009: Ticket Workflow — wrap-ticket could trigger validation check (future integration)
