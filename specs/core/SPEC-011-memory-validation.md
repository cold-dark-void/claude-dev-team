# SPEC-011: Memory Validation

**Status**: ACTIVE
**Category**: core
**Created**: 2026-03-23

**Covers**: `commands/validate-memory.md`, `skills/validate-memory/SKILL.md`, `skills/validate-memory/reconcile-lib.sh`, `/memory-distill` integration (pre-distill hook), `skills/memory-store/migrate-v3.sh`, `skills/memory-store/migrate-v4.sh`

---

## Overview

Cross-references agent memories against the live codebase to detect and resolve stale references — dead files, renamed functions, shifted line numbers, outdated factual claims. Uses a multi-stage pipeline (validator proposes → tech-lead reviewer confirms → user decides ambiguous cases) with confidence scoring to minimize false positives. Runs standalone via `/validate-memory` or as an automatic pre-distill step in `/memory-distill`. Deep mode (`--deep`) rebuilds digests whose source material has gone stale. Cross-agent reconciliation (`--reconcile`) detects contradictory claims across agents' memories (not against code).

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
- MUST follow the SPEC-004 write-path contract on every write operation (incl. `PRAGMA busy_timeout=5000`) — SPEC-004 is the single source
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
- MUST add `archive_reason TEXT DEFAULT NULL` column to memories table — values: `'distilled'` (set by distiller), `'stale'` (set by validator), `'reconciled'` (set by cross-agent reconcile), `NULL` (legacy/unset)
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
- MUST support `--reconcile` flag (cross-agent contradiction detection; see Cross-Agent Memory Reconciliation)
- MUST support `--report-only` flag only meaningful with `--reconcile` (zero DB writes)
- MUST require SQLite DB (error with helpful message including path and init command reference)
- MUST output TLDR summary header followed by per-decision commentary
- MUST output format: `TLDR: @<agent>: N checked, M archived, K rewritten, J flagged for review` per agent, then detailed per-entry reasoning with per-claim verdict breakdown (memory ID, first 80 chars, score, action, then indented per-claim lines with verdict tag, confidence, and evidence)
- MUST exit 0 and output `TLDR: all memories validated within the last N days. Nothing to do. Use --force to re-validate.` when zero memories are eligible (non-reconcile path)

### Idempotency
- MUST produce identical outcomes when run twice on an unchanged codebase (second run skips all validated entries, net changes = 0)

### Concurrency
- MUST exit with error if `/memory-distill` holds the `distilling_lock` (do not silently skip)
- MUST NOT hold its own lock (validation is read-heavy with targeted writes; distillation lock is sufficient for mutual exclusion)


### Schema Migration (v3 → v4) — Cross-Agent Reconcile
- MUST create `reconcile_log` table via `migrate-v4.sh`: `id INTEGER PRIMARY KEY AUTOINCREMENT`, `memory_id_a INTEGER NOT NULL REFERENCES memories(id)`, `memory_id_b INTEGER NOT NULL REFERENCES memories(id)`, `agent_a TEXT NOT NULL`, `agent_b TEXT NOT NULL`, `verdict TEXT NOT NULL CHECK(verdict IN ('contradictory','consistent','unrelated'))`, `claim_a TEXT`, `claim_b TEXT`, `confidence INTEGER NOT NULL`, `action TEXT NOT NULL CHECK(action IN ('none','report','pick-survivor','merge','both-stale','skip','deep-audit'))`, `winner_id INTEGER`, `loser_id INTEGER`, `reason TEXT`, `created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))`
- MUST create index `idx_reconcile_pair` on `(memory_id_a, memory_id_b)`
- MUST add default config key `reconcile_pair_cap` (default: `'50'`)
- MUST check `schema_version = '3'` before migrating (exit 0 if already v4, exit 1 if not v3)
- MUST update `schema_version` to `'4'` only after all steps complete
- MUST be idempotent (safe to re-run)
- MUST ship matching DDL in `skills/memory-store/schema.sql` for fresh DBs (`schema_version='4'`)

### Cross-Agent Memory Reconciliation (`--reconcile`)
- MUST support `/validate-memory --reconcile` as the sole entry surface (no standalone `/memory-reconcile` command; no pre-distill auto-reconcile hook in v1)
- MUST support optional `--report-only` (with `--reconcile`) and `--agent <name>` (pairs where at least one side is that agent)
- MUST reject combining `--deep` with `--reconcile` (error exit)
- MUST scope to non-archived rows for behavioral agents `{pm,tech-lead,ic5,ic4,devops,qa,ds}` at all tiers 0/1/2; MUST exclude same-agent pairs, `context.md`, and internal agents (`project-init`, `distiller`, `council-judge`)
- MUST generate candidate pairs without materializing the full cross-agent product: embeddings (sqlite-vec KNN, k=5, cosine similarity ≥ 0.55) when available; keyword/token Jaccard (≥ 0.15 on tokens len≥4) fallback otherwise
- MUST cap judged pairs at `reconcile_pair_cap` (default 50, configurable 1–500 via `/memory-config`); MUST report cap-hit in TLDR
- MUST sample at most 200 memories per agent (highest tier, then newest) before keyword pairwise comparison
- MUST skip pairs already resolved in `reconcile_log` with `action IN ('pick-survivor','merge','both-stale')` or where either memory is archived
- MUST run LLM pair-judge only on candidate pairs (batch ≤10 pairs/call, ≤5 batches); verdict ∈ `{contradictory, consistent, unrelated}` with verbatim `claim_a`/`claim_b` quotes and confidence 0–100
- MUST treat malformed judge JSON as `unrelated` conf 0 for affected pairs
- MUST NOT prompt for resolution on `consistent` or `unrelated` verdicts; MUST NOT mutate memories for those verdicts
- MUST NEVER auto-archive on contradiction — even max-confidence `contradictory` requires explicit interactive choice
- MUST on `--report-only`: print TLDR+DETAIL with contradictions and evidence; perform **zero** DB writes (no `UPDATE memories`, no `INSERT reconcile_log`, no archives)
- MUST on interactive default, for each `contradictory` pair, offer: `pick-survivor` | `merge` | `both-stale` | `skip` | `deep-audit`
- MUST apply host-side SQL for resolutions (SPEC-004 write-path incl. `PRAGMA busy_timeout=5000`):
  - `pick-survivor`: archive loser with `archive_reason='reconciled'`; log winner/loser
  - `merge`: UPDATE winner content (preserve tier/type/`distilled_from`); append `[reconciled: YYYY-MM-DD]`; archive loser `reconciled`
  - `both-stale`: archive both with `archive_reason='reconciled'`
  - `skip`: log only
  - `deep-audit`: log only; print exact `/council "<claim_a> vs <claim_b>"` suggestion; MUST NOT spawn tribunal phases (SPEC-013 owns adversarial ground-truth)
- MUST persist every interactive verdict+resolution to `reconcile_log` (provenance: winner, loser, action, reason, quoted claims)
- MUST exit with error if `distilling_lock` is held (same concurrency guard as validate)
- MUST output TLDR: `TLDR: reconcile: N candidates, J judged, C contradictory, R resolved, S skipped, cap=K[ HIT]`

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
- MUST NOT auto-archive cross-agent contradictions without explicit interactive resolution (`pick-survivor` / `merge` / `both-stale`)
- MUST NOT write `reconcile_log` or mutate memories under `--report-only`
- MUST NOT reimplement adversarial tribunal phases inside reconcile (deep-audit hands off to `/council` only)
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
- Verify seeded pm vs tech-lead contradiction is reported as `contradictory` with both claims quoted verbatim under `--reconcile`
- Verify keyword/token-overlap candidate generation completes when sqlite-vec/lembed are absent
- Verify pair count to judge is ≤ `reconcile_pair_cap` (default 50) and full cross-agent product is never materialized; cap-hit appears in TLDR
- Verify `consistent` / `unrelated` verdicts produce no resolution prompt and no memory mutation
- Verify interactive resolution offers pick-survivor / merge / both-stale / skip / deep-audit and records provenance
- Verify `--report-only` lists contradictions with evidence and performs zero DB writes
- Verify max-confidence `contradictory` never archives without explicit interactive choice
- Verify interactive resolutions persist in `reconcile_log`
- Verify `deep-audit` prints `/council "…"` and does not spawn tribunal phases
- Verify schema migration v3→v4: `reconcile_log` table, `reconcile_pair_cap`, `schema_version=4`; fresh `schema.sql` matches
- Verify `--reconcile` is the only entry surface (no pre-distill hook, no second command file)
- Verify distilling_lock held → error exit on reconcile path

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
- [ ] `--reconcile` with seeded cross-agent contradiction reports `contradictory` + verbatim quotes
- [ ] `--reconcile --report-only` leaves `reconcile_log` empty and no archives
- [ ] `schema_version` = "4" after migrate-v4; `reconcile_log` exists
- [ ] Interactive `pick-survivor` sets `archive_reason='reconciled'` on loser only
- [ ] `deep-audit` prints `/council` suggestion without archiving

---

## Resolved Questions

- [x] ~~7-day validated_at window configurable?~~ **Yes** — `validate_window_days` config key, default 7. Settable via `/memory-config`.
- [x] ~~50% stale-source threshold adjustable?~~ **No** — fixed at 50% for v1. Revisit if users request tuning.
- [x] ~~Cross-project (`--scope global`) discovery?~~ **Deferred** — removed from v1 scope. Will be a follow-up ticket.
- [x] ~~Validation log table?~~ **Yes** — `validation_log` table created in v3 migration, parity with `distillation_log`.
- [x] ~~Schema version after migration?~~ **"3"** — guards on v2, same pattern as v1→v2 migration.
- [x] ~~How to distinguish archive reasons?~~ **`archive_reason` column** — values: `'distilled'`, `'stale'`, `'reconciled'`, `NULL` (legacy).
- [x] ~~Cross-agent contradiction detection?~~ **`--reconcile` on `/validate-memory`** (CDV-195) — candidate pairs + LLM pair-judge; never auto-archive; pre-distill hook DEFERRED.
- [x] ~~Standalone `/memory-reconcile`?~~ **No** — flag only (feature nickname).
- [x] ~~Does report-only write reconcile_log?~~ **No** — zero writes.

---

## Out of Scope (v1)

- `--scope global` cross-project validation (deferred to follow-up)
- Auto-triggering without user/distill invocation
- Validating non-code memories (process/decision notes with no checkable ground truth)
- Adjustable deep mode threshold
- Pre-distill auto-reconcile hook (DEFER — run `/validate-memory --reconcile` before distill when wanted)
- Standalone `/memory-reconcile` command
- Auto-archive on cross-agent contradiction
- Ground-truth adjudication inside reconcile (use `/council` via deep-audit)
- Cross-project / global reconcile scope
- FTS5 / new embedding infrastructure for candidates
- Configurable similarity thresholds (hardcoded v1: embed sim ≥ 0.55, keyword Jaccard ≥ 0.15)
- `.md` fallback mode for reconcile (DB required, same as validate)

---

## Version History

| Date | Change |
|------|--------|
| 2026-03-23 | Initial spec created from brainstorm session |
| 2026-03-23 | Resolved all open questions per kickoff review. Added: archive_reason column, validation_log table, schema v3 migration, reviewer=tech-lead, non-blocking user flags, idempotency AC, concurrent run protection. Deferred --scope global. Status → APPROVED. |
| 2026-03-23 | Added score-0 "clean pass" bucket (sets validated_at) to fix idempotency gap for truly clean memories. Threshold buckets now: 0=pass, 1-39=flag_user, 40-80=reviewer, >80=auto-archive. |
| 2026-04-21 | Replaced regex-based reference extraction and bash-only scoring with LLM-based claim extraction + two-tier verification. Added claim types (file_reference, symbol_reference, line_content, behavioral, architectural, configuration), verdict taxonomy (VALID, STALE, CONTRADICTED, AMBIGUOUS), per-claim confidence scoring, composite weighted-average scoring. Tier A (bash) handles file/symbol refs with rename detection. Tier B (LLM investigator) handles behavioral/architectural/config/line claims. Prompt templates in skills/validate-memory/SKILL.md. |
| 2026-06-15 | Editorial de-duplication (AUDIT-P3.5b): trimmed the verbatim `PRAGMA busy_timeout=5000` MUST restatement to defer to SPEC-004's write-path contract (SPEC-004 is the single source). No behavioral change. |
| 2026-07-14 | CDV-195: promote cross-agent memory reconciliation to normative MUSTs. Entry: `/validate-memory --reconcile` (+ `--report-only`). Schema v4 + `reconcile_log` + `reconcile_pair_cap`. Bounded candidates (embed KNN / keyword Jaccard). LLM pair-judge; never auto-archive; deep-audit → `/council` only. Status → ACTIVE. |

---

## Cross-references

- SPEC-004: Memory Storage — validator reads/writes through same storage layer, uses same sqlite3 patterns; v3/v4 migrations extend schema; all reconcile writes follow write-path contract
- SPEC-006: Memory Retrieval — validated_at affects which memories load; archived entries already filtered; reconcile candidate search reuses embed/keyword degradation posture
- SPEC-007: Memory Distillation — pre-distill integration (codebase validate only); deep mode invokes distiller for rebuilds; tier access control respected; distiller must set `archive_reason='distilled'` when archiving; pre-distill auto-reconcile DEFERRED
- SPEC-013: Adversarial Council Tribunal — deep-audit hands off with `/council "…"`; reconcile does not reimplement tribunal phases
- SPEC-003: Agent Role System — validation uses Opus; reviewer is tech-lead agent (Opus); pair-judge uses general-purpose Task subagent
- SPEC-009: Ticket Workflow — wrap-ticket could trigger validation check (future integration)
