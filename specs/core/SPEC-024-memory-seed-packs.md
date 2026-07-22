# SPEC-024: Memory Seed Packs — Committable Team-Knowledge Export/Import

**Status**: ACTIVE
**Category**: core
**Created**: 2026-07-03

---

## Overview

Team memory is machine-local: a fresh clone or a new collaborator starts with cold agents, and `/init-team`'s project scan rediscovers only what code inspection can infer — not the hard-won decisions, gotchas, and domain vocabulary already distilled on another machine. Copying `memory.db` between machines is unsafe (absolute paths, machine config, possible secrets) and unreviewable. This spec defines **memory seed packs**: `/memory export` writes a sanitized, provenance-tagged, deterministic pack of per-agent seed files under `.claude/memory/seed/` from each agent's distilled tier-2/core memories (plus cortex highlights in fallback mode), sized and scrubbed for human review in a PR and committed to the repo so team knowledge ships with the code. On a fresh clone, `/init-team` detects the pack and imports it as provenance-tagged tier-1 memories BEFORE the project-init scan runs, so a new machine or user starts with a warm team. Re-import is idempotent (content-hash dedupe), and seeded memories flow through the normal SPEC-011 validation pipeline, so stale seeded claims are caught against the current codebase rather than trusted forever.

The pack is a **transport format, not a second memory system**. Everything about how memories are stored, tiered, retrieved, and validated stays owned by the existing memory specs; this spec owns only the export sanitization/serialization, the committable artifact layout, and the one import step wired into bootstrap.

**Boundaries & related specs (conflict scan, 2026-07-03):**
- **SPEC-004 (memory storage)** owns the write path end-to-end: dual-mode detection (SQLite vs .md fallback), append-only INSERT discipline, SQL escaping, `busy_timeout`/retry, read-back verification, best-effort embedding, fallback line limits, and all schema migrations. Import MUST write ONLY via the memory-store protocol (`skills/memory-store/SKILL.md`) — never bespoke raw INSERTs — and this spec introduces NO schema change: the `memories.type` CHECK constraint (`cortex|memory|lessons|digest|core`) is left untouched; seeded rows reuse `type='digest'`, and provenance rides in a content trailer plus `metadata_json` (both existing surfaces).
- **SPEC-007 (distillation)** owns tier semantics and tier access control ("only @distiller may set tier > 0"). This spec does not redefine tiers or promotion criteria. The tier-1 seed write is a single, narrow, documented carve-out executed by the `/init-team` host command script — never by a behavioral agent — mirroring SPEC-011's "rewrite SQL via the host command script" precedent (see M5). Distillation may later archive or re-distill seeded digests exactly like locally produced ones.
- **SPEC-005 (team bootstrap)** owns the `/init-team` sequence, project-init scan, idempotency guarantees, and the `.gitignore` update step. This spec adds exactly one step at a defined point in that sequence (after DB init + extensions, before the project-init agent is spawned) and one coordination rule for the gitignore step (the seed-dir carve-out, M9). It does not alter the scan, cortex generation, or permission sync.
- **SPEC-011 (memory validation)** owns staleness detection, verdicts, thresholds, and archival. Imported memories are fully subject to it — not exempt, not down-weighted, not pre-marked `validated_at` (M7). This spec MUST NOT reimplement any claim extraction, investigation, or scoring; a stale seeded claim dies by SPEC-011's normal pipeline.
- **SPEC-006 (memory retrieval)** owns session-start loading and search. Seeded rows load as ordinary tier-1 digests with no retrieval change; embeddings for seeded rows are the normal SPEC-004 best-effort path.

**Out of scope:** cross-project or multi-repo seed sync; a global seed marketplace or registry; per-user/selective packs; automatic re-export on distill or release; merging packs from multiple divergent sources; pack signing/encryption; exporting embeddings or any `memory.db` binary content.

---

## MUST

- **M1 — Export command & pack layout.** A new `/memory export` command MUST write one seed file per agent to `.claude/memory/seed/<agent>.md` plus a pack manifest `.claude/memory/seed/manifest.json` (fields at minimum: pack format version, source project name, export date, per-file entry counts and content hashes). Sources: in SQLite mode, tier-2 core memories (non-archived); in fallback mode, `cortex.md` and `lessons.md` highlights. Output MUST be deterministic (stable ordering, e.g. `type, updated_at DESC, id`) so re-export produces clean, reviewable diffs; an agent with nothing exportable produces no file for that agent, and a fully empty export is a friendly no-op (no empty pack written).
- **M2 — Sanitization (deny-by-default).** Before an entry is written to the pack: absolute paths under the project root MUST be rewritten repo-relative; any entry still containing an absolute filesystem path, home-directory path, hostname, username, email address, session UUID, credentialed URL, or secret-like token (common key patterns and high-entropy strings) MUST be EXCLUDED from the pack — never silently half-scrubbed — and reported in the export summary by memory id with the triggering reason. Sanitization is a floor, not a substitute for the human PR review the pack is designed for.
- **M3 — Provenance trailer.** Every exported entry MUST end with a machine-parseable provenance trailer on its own line — `[seed: project=<name> date=<YYYY-MM-DD> tier=<n> agent=<agent> hash=<sha256-12>]` — mirroring SPEC-011's `[validated: …]` trailer precedent. The hash MUST be computed over the normalized entry content EXCLUDING the trailer itself, so the trailer can be verified and used as the dedupe key (M6).
- **M4 — Import point & mechanism.** `/init-team` MUST detect `.claude/memory/seed/manifest.json` and import the pack BEFORE the project-init agent is spawned (after DB init + extension setup in the SPEC-005 sequence), so seeded knowledge already exists when the project scan runs. Each imported entry MUST be written via the memory-store protocol (SPEC-004 write path: escaping, `busy_timeout`, retry, read-back) as `tier=1`, `type='digest'`, `distilled_from='[]'`, with the provenance trailer preserved in `content` and the parsed provenance recorded in `metadata_json`. Import MUST NOT use bespoke raw INSERTs.
- **M5 — Tier-write carve-out (host script only).** The tier-1 seed write is a narrow, documented exception to SPEC-007's "only @distiller may set tier > 0": it MUST execute only in the `/init-team` host command context (script, not a model-driven agent), mirroring SPEC-011's host-script rewrite precedent. Behavioral agents remain forbidden from setting tier > 0; no agent prompt may gain a tier-write instruction from this feature. SPEC-007 receives a one-line forward reference to this carve-out on its next revision (tracked in Validation).
- **M6 — Idempotent re-import (content-hash dedupe).** Before each insert, import MUST check the entry's provenance hash against ALL existing rows — including `archived=TRUE` rows — and skip on match. Archived matches MUST NOT be resurrected: an archived seed means validation or distillation already consumed or killed it. Re-running `/init-team` or `/init-team --refresh` on a repo with a pack MUST add zero duplicate rows, and the import summary MUST report `imported / skipped-duplicate / skipped-archived / rejected` counts.
- **M7 — Subject to validation, never pre-trusted.** Imported memories are ordinary memories to SPEC-011: `validated_at` MUST NOT be set at import time; staleness scans MUST apply normal thresholds and actions to seeded rows; import MUST NOT exempt, down-weight, pin, or otherwise shield seeded rows from archival. A seeded claim that is stale against the current codebase gets caught and archived by the existing pipeline.
- **M8 — Import-side re-screen (untrusted packs).** Because packs arrive via clone or PR from arbitrary authors, import MUST re-run the M2 screen on every entry and reject failures (counted in the M6 summary). A missing/malformed manifest, an unparseable entry, or a content-vs-manifest hash mismatch MUST cause that file (or entry) to be skipped with a one-line warning — and `/init-team` MUST continue; a bad pack degrades the warm start, it never blocks bootstrap.
- **M9 — Committability & gitignore carve-out.** `.claude/memory/` is gitignored (repo `.gitignore` and SPEC-005's init-team gitignore step), and git does not descend into an excluded directory — so a bare `!.claude/memory/seed/` negation under a `.claude/memory/` exclude is inert. Export MUST make the pack actually committable: rewrite the blanket exclude to the child-glob form plus negation (`.claude/memory/*` + `!.claude/memory/seed/`), preserve all other memory ignores (`memory.db*`, extensions, models), and verify with `git check-ignore` that seed files are not ignored. `/init-team`'s gitignore step MUST NOT re-shadow the seed directory on later runs. Export MUST NOT run `git add`, `git commit`, or `git push` — the user reviews the pack and commits it deliberately.
- **M10 — Fallback mode, both directions.** With no `memory.db` or no `sqlite3`, export MUST source the fallback `.md` files, and import MUST append the highest-signal seed entries to each agent's fallback files via the SPEC-004 fallback path — respecting the line limits (cortex 100 / memory 50 / lessons 80), never overwriting existing content, and reporting what was omitted for space. The feature degrades; it never errors out bootstrap or requires SQLite.
- **M11 — MUST NOT (hard boundaries).** Export MUST NOT include tier-0 raw memories, `context.md`, `directives.md`, embedding vectors, or `memory.db` rows/schema dumps; MUST NOT write outside `.claude/memory/seed/` plus the `.gitignore` edit (M9); MUST NOT auto-commit or push. Import MUST NOT modify, archive, or delete any existing memory (append-only) and MUST NOT alter agent definitions or settings. With no pack present, `/init-team` behavior MUST be byte-for-byte today's behavior (graceful absence — no new output, no new steps).

---

## SHOULD

- SHOULD cap pack size for reviewability: a default per-agent entry cap (e.g. 40 entries, newest-first within the M1 deterministic order) with an explicit override flag, reporting how many entries were omitted by the cap.
- SHOULD support `--agent <name>` on `/memory export` for partial exports, and `--dry-run` to print what would be exported (including exclusions and reasons) without writing.
- SHOULD surface a one-line warm-start summary in the `/init-team` final report (e.g. `warm start: N memories imported for M agents from pack dated <date>; K rejected`).
- SHOULD let imported rows pick up embeddings via the normal best-effort `embed-one.sh` path so semantic search covers seeded knowledge when embeddings are configured.
- SHOULD advise (in the export summary) committing the pack via a reviewed PR rather than direct push, since sanitization is deliberately conservative but not perfect.

---

## Test

1. **Deterministic export (M1):** with tier-2 rows present for two agents, `/memory export` writes `.claude/memory/seed/<agent>.md` for each plus `manifest.json`; running it again with no memory changes produces byte-identical files.
2. **Sanitization excludes, rewrite includes (M2):** seed one memory containing `/home/<user>/…` and a fake AWS key → excluded and listed with reasons; seed another containing only a project-root-anchored path → path rewritten repo-relative and the entry included.
3. **Provenance trailer (M3):** every entry in a real pack ends with a parseable `[seed: …]` trailer; recomputing the hash over the trailer-stripped content reproduces `hash=<sha256-12>`.
4. **Import before scan, via protocol (M4):** on a fresh clone containing a pack, `/init-team` imports before project-init is spawned (seeded rows exist when the scan starts); imported rows have `tier=1`, `type='digest'`, `distilled_from='[]'`, provenance in `metadata_json`, and the write path shows SPEC-004 discipline (escaped content, read-back).
5. **Carve-out is scoped (M5):** the tier-1 writes originate from the `/init-team` host script; a behavioral agent attempting `tier>0` is still rejected/overridden per SPEC-007 — the carve-out grants nothing to agents.
6. **Idempotent re-import (M6):** run `/init-team`, then `/init-team --refresh` → zero duplicate rows and a `skipped-duplicate` count equal to the pack size; archive one seeded row, re-run → it stays archived (`skipped-archived` increments), never resurrected.
7. **Validation applies (M7):** imported rows have `validated_at IS NULL`; make one seeded claim stale against the codebase, run `/memory validate` → it scores and archives per SPEC-011's normal thresholds, `archive_reason='stale'`.
8. **Untrusted-pack screen (M8):** hand-edit a committed pack entry to contain a secret-like token → import rejects that entry (counted in `rejected`); corrupt a manifest hash → that file is skipped with a warning and `/init-team` completes normally.
9. **Committable pack (M9):** after export, `git check-ignore .claude/memory/seed/pm.md` exits non-zero (not ignored) while `git check-ignore .claude/memory/memory.db` still exits 0 (ignored); `git log` shows no commit authored by the export; a later `/init-team` run does not re-ignore the seed dir.
10. **Fallback round-trip (M10):** with `sqlite3` unavailable, export from fallback `.md` files succeeds; import appends to fallback files without exceeding the line limits and reports omissions.
11. **Graceful absence + hard boundaries (M11):** with no pack, `/init-team` output is identical to pre-feature behavior; a pack export contains no tier-0/`context.md`/`directives.md` content and no vectors; import mutates no pre-existing row.
12. **Round-trip acceptance (M1+M4+M6+M7 — headline):** export on machine A, commit the pack, clone on machine B, run `/init-team`, then ask an agent about a seeded fact (a decision not inferable from code) → the agent demonstrably knows it.

---

## Validation

- [x] Spec reviewed and promoted to ACTIVE
- [ ] Round-trip demo passes: machine-A export → machine-B clone + `/init-team` → agent answers a seeded-fact question
- [ ] A real export of this repo's memories passes human review: no absolute paths, secrets, or session UUIDs in the pack
- [x] `/init-team --refresh` on a repo with a pack adds zero duplicate rows (bite-test M6 in `skills/memory-store/test-seed-pack.sh`)
- [x] SPEC-007 carries a one-line forward reference to the M5 host-script tier-write carve-out
- [x] SPEC-005 documents the import step's position in the `/init-team` sequence

---

## Open Questions

- ~~Should tier-1 digests be exportable behind an explicit `--include-digests` flag, or is tier-2-only the permanent posture?~~ **RESOLVED (CDV-194 kickoff):** tier-2-only is the permanent v1 posture. No `--include-digests`. Digests stay out of the pack (noisier/staler; SPEC-007 promotion is the quality gate).
- ~~Pack entry format is per-agent `.md` for PR reviewability; revisit a single JSON pack only if trailer parsing proves brittle in practice.~~ **RESOLVED:** per-agent `.md` + `manifest.json` is the ship format. Single-JSON pack deferred unless trailer parsing proves brittle post-ship.
- ~~Should SPEC-011 apply a small score modifier to seeded rows?~~ **RESOLVED:** no modifier — seeds are ordinary memories (M7). Existing age/staleness pipeline is sufficient.
- High-entropy secret detection threshold: acceptable false-positive rate before maintainers start hand-overriding exclusions? **Ship conservative** (deny-by-default M2); no hand-override flag in v1. Tune from export-summary evidence in a later ticket if FP rate is painful.
- ~~Whether `/memory export` should optionally refresh/prune an existing committed pack in place.~~ **RESOLVED:** yes as default. Re-export overwrites `.claude/memory/seed/` from current non-archived tier-2 sources only — archived/removed sources disappear from the pack (deterministic M1 order makes the diff reviewable). No separate `--prune` flag.

---

## Version History

| Date | Change |
|------|--------|
| 2026-07-22 | CDT-46-C3: retarget Covers + in-body surfaces `/memory-export` → `/memory export`, `/validate-memory` → `/memory validate` (`commands/memory.md`). Status stays ACTIVE. |
| 2026-07-14 | ACTIVE — CDV-194 implementation (export/import scripts, `/memory-export`, init-team Step 5.5) |
| 2026-07-03 | Initial DRAFT — ideation wave 2 |

**Covers**: `/memory export` (`commands/memory.md`), `commands/init-team.md` (Step 5.5 import), `agents/project-init.md` (seed awareness), `skills/memory-store/{export,import}-seed-pack.sh`, `skills/memory-store/seed-common.sh`, `skills/memory-store/test-seed-pack.sh`, `skills/memory-store/SKILL.md` (M5 host-script note), `.claude/memory/seed/` (emitted pack layout: `<agent>.md` + `manifest.json`).

## Cross-references

- **SPEC-004** — Memory Storage & Migration: import writes exclusively via the memory-store protocol; no schema change (type CHECK untouched; provenance in trailer + `metadata_json`); fallback line limits govern M10.
- **SPEC-005** — Team Bootstrap: `/init-team` sequence hosts the import step (after DB/extensions, before project-init); gitignore-step coordination per M9.
- **SPEC-006** — Memory Retrieval: seeded rows load and search as ordinary tier-1 digests; no retrieval changes.
- **SPEC-007** — Memory Distillation: tier semantics and tier access control owned there; M5 is the single host-script carve-out; distiller may archive/re-distill seeded digests normally.
- **SPEC-011** — Memory Validation: seeded memories are in-scope for staleness scans (M7); this spec reimplements none of its pipeline.
- **Backlog:** `.claude/backlog/memory-seed-packs.md` — the banked ideation item this spec formalizes.
