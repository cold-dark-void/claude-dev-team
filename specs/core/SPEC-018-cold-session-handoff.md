# SPEC-018: Session Handoff (Cold + Warm)

**Status**: ACTIVE
**Category**: core
**Created**: 2026-06-04

---

## Overview

A cold, retroactive session-handoff command — `/handoff <session-uuid>` — that reconstructs the hard-won state of a past session into a dense brief injected into a fresh session, so the user never restarts from scratch or re-explains basics after `/compact`, multiday, or multi-fork sessions.

The command has **two modes**: **cold** (`/handoff <uuid>`, primary) reconstructs a past session after the fact from disk — including 70 MB+ multi-fork "monster" transcripts; **warm** (bare `/handoff`) captures the *current* live session before it dies. The warm path supersedes and replaces the former personal `~/.claude/skills/handoff` skill, which is removed as part of this work. The core value is transferring **convergence**: not just *what changed* (git has that), but the *root cause reached* and — critically — the **rejected hypotheses and user corrections**, so the new session does not re-propose dead ends and re-waste context ("anti-gaslighting").

Design: a deterministic, LLM-free pre-pass (fork-tree assembly + `toolUseResult` stripping + dedup) feeds a size-adaptive spine, over which **specialized extractor subagents** run in parallel (Convergence / Dead-ends / Code-state / Open-threads / Basics) and merge into a thin, pointer-bearing brief. Because the extractors are subagents, the command also models the "offload tool I/O to subagents" discipline it exists to support.

**Boundaries & related specs (conflict scan, 2026-06-04):**
- **SPEC-012 (`/retro`)** also parses `~/.claude/projects/*.jsonl`. Transcript location + fork-tree traversal + the deterministic pre-pass MUST be a shared, read-only parsing module consumed by both — not duplicated. This spec also adopts SPEC-012's in-progress freshness guard (skip transcripts modified < 60 s ago).
- **SPEC-006 (`/recall`)** is the discovery counterpart (cross-session search → `claude --resume`); this spec is single-session *distillation*. `/handoff` may be invoked on a uuid surfaced by `/recall`.
- **SPEC-013 (`/council`)** owns adversarial claim verification. This spec MUST NOT reimplement that pipeline; M5 is a lightweight stated-intent-vs-git flag only, and deep auditing is delegated to `/council`.
- **Memory (SPEC-004/006/007/011)**: when reading agent memory as a source, use SPEC-006 retrieval. The result cache MUST live outside `memory.db` so it does not intersect the memory write-path or staleness scans.

**Out of scope (future phases):** smarter chunk-boundary heuristics, cache-eviction policy beyond growth-invalidation, and the Prong-1 tool-offload `AGENTS.md` convention.

---

## MUST

- **M1 — Locate & assemble.** Given a session uuid, select the **canonical transcript file** — the descendant whose copied prefix is most complete (greatest max-`timestamp` among files under `~/.claude/projects/` containing that uuid) — then produce one chronologically ordered timeline by **de-duplicating copied messages on `uuid` (keep-last)** and ordering by **`(timestamp, file-position)`**. `forkedFrom` is **provenance** (`{sessionId, messageUuid}`; `messageUuid` is self-referential), NOT a cross-file pointer: the fork's chosen-path prefix is already copied into the file, so no cross-file message-walk is required, and ancestor-only branches (paths forked away from) are intentionally excluded. Ordering MUST use timestamps, not the `parentUuid` DAG (multi-root/branchy due to copy duplication). Location + parsing MUST use the shared module (see SPEC-012), not a private re-implementation. *(Mechanism corrected by CDV-10 Task-1 spike against real 72 MB transcripts.)*
- **M2 — Deterministic pre-pass (no LLM).** Before any distillation: strip `toolUseResult` payloads, dedup repeated reads of the same path (retain the last), and collapse each `isSidechain` segment. Default: one-line outcome plus a `transcript:L<n>` pointer. **When signal-bearing** (any single case-insensitive substring hit from the closed cue list in `parselib.SIDECHAIN_SIGNAL_CUES` over withheld sidechain `msg_text`), emit a condensed multi-line reconstruction (span header + `hypothesis` / `killed` / `notes`, hard cap ~400 chars) instead of the one-liner — still no raw `toolUseResult`. Stats: `sidechain_runs_collapsed` (noise) + `sidechain_runs_signal`. Defensive until production schemas emit `isSidechain:true`; synthetic fixtures gate the path.
- **M3 — Size-adaptive distillation.** If the stripped spine fits the target context window, distill directly; if it exceeds it, chunk at message boundaries, summarize chunks in parallel (preserving hypotheses, corrections, and decisions), then distill the reduced spine. MUST complete on oversized (≥ 60 MB) transcripts without context overflow.
- **M4 — Required brief sections.** The brief MUST contain, clearly delineated: (a) **Convergence** — the current correct mental model / root cause; (b) **Dead-ends** — rejected hypotheses, why each was killed, and user corrections quoted **verbatim**; (c) **Code-state** — derived from `git` (diff/log); (d) **Open-threads & conflicts**; (e) **Basics** — established context, vocabulary, and constraints.
- **M5 — Stated-intent vs git flag (lightweight).** The brief MUST flag mismatches between intentions stated in the transcript (e.g. "will extract X", "TODO X") and the actual git state. This is a heuristic flag only — it MUST NOT implement an adversarial verification pipeline; deep claim auditing is delegated to `/council` (SPEC-013).
- **M6 — Pointers, not dumps.** Every non-trivial claim in the brief MUST carry a drill-down pointer (`transcript:L<n>`, `commit:<hash>`, or `file:symbol`). The brief MUST NOT inline raw tool output.
- **M7 — Inject into current session (cold mode).** In cold mode the brief MUST be emitted into the invoking session's context (output), not solely written to a file the user must separately open. (Warm mode persists a file instead — see M10.)
- **M8 — Result cache.** The distilled brief MUST be cached keyed by (session uuid + last-message uuid) and reused on re-invocation until the underlying session has grown (new messages appended). The cache MUST be stored outside `memory.db` (e.g. under `.claude/handoff/`), isolated from the memory write-path.
- **M9 — Freshness guard.** If the target transcript was modified < 60 s ago (in-progress), the command MUST warn and decline to parse mid-write rather than produce a partial brief (consistent with SPEC-012).
- **M10 — Warm mode (live capture).** A bare `/handoff` (no uuid) MUST capture the *current* live session into the same five-section brief (M4) from live context — no transcript parsing or fork-walk. In warm mode the brief MUST be written to `<repo>/.claude/handoff/<session-id>-<slug>.md` for a future session to consume (the user is still in the live session), NOT injected.
- **M11 — Consolidation.** The plugin `/handoff` MUST supersede the personal `~/.claude/skills/handoff` skill; that skill MUST be removed (leaving a one-line deprecation pointer to the plugin command). Warm mode MUST preserve that skill's density rules and anti-patterns (no chronological narration; link by `file:symbol`; quote user constraints verbatim).
- **MUST NOT** require any action to have been taken during the original session — it operates **retroactively** on existing transcripts.

### Extension — PreCompact auto-handoff

Goal: make context loss structurally impossible — capture a rescue artifact BEFORE any compaction (auto or manual) via the harness `PreCompact` hook, whose stdin JSON carries `session_id`, `transcript_path`, and `hook_event_name`. Hooks run shell commands, not model turns, so this path is deterministic by construction.

- **M12 — Deterministic rescue capture (LLM-free).** A `PreCompact` hook (both `manual` and `auto` matchers) MUST invoke a capture script (e.g. `skills/handoff/precompact-capture.sh`) that runs the existing deterministic pre-pass machinery (`prepass.sh` / the shared `skills/transcript-parse` module) against the live `transcript_path` from the hook's stdin JSON — no canonical-file search needed (M1's locate step is skipped; the hook names the exact live file) — and writes a rescue artifact to `<repo>/.claude/handoff/<session-id>-precompact-<seq>.md` (`<seq>` monotonically increasing per session). The artifact is a **spine snapshot + drill-down pointers** (M6 discipline), explicitly **NOT** the five-section M4 brief: M4 quality is unreachable without a model. It is raw material for a later cold `/handoff <uuid>`, which remains the canonical quality path.
- **M13 — Registration + template emission.** The hook MUST be registered in `.claude/settings.json` under `PreCompact` AND emitted by the `/init-orchestration` template set (kept byte-identical to the live hook per `skills/init-orchestration/check-hook-templates.sh`). The emitted command MUST follow the existing hook hygiene rules: `${CLAUDE_PROJECT_DIR}`-anchored path (worktree-safe), no pipe operators.
- **M14 — Scoped freshness-guard carve-out.** A PreCompact capture is by definition mid-write, so the capture path MUST bypass the M9 <60s freshness guard via an explicit, narrowly scoped mechanism (e.g. an `--allow-in-progress` flag on the shared guard/pre-pass, passed ONLY by `precompact-capture.sh`) and MUST tolerate a truncated final JSONL line by dropping it. The default guard behavior for cold `/handoff` and `/retro` MUST remain unchanged — the carve-out MUST NOT be reachable from any user-invoked path.
- **M15 — Bounded retention.** Keep at most N rescue artifacts per session (default 3, override `HANDOFF_PRECOMPACT_MAX_PER_SESSION`), pruning oldest-first on each capture — mirroring the M8 cache-eviction precedent (`HANDOFF_CACHE_MAX_ENTRIES`). Pruning MUST only ever touch `*-precompact-*.md` artifacts; warm briefs (M10) and the cold-result cache (M8) are separate namespaces and MUST NOT be pruned by this path.
- **M16 — Surfacing (pointer, not dump).** After a capture, the post-compacted session (and/or the next session, via `PostCompact` and/or `SessionStart` hook output) MUST be told a rescue artifact exists: a one-line pointer carrying the artifact path and the suggested recovery invocation (`/handoff <uuid>`). Pointer injection only — the artifact content MUST NOT be dumped into context (M6 discipline).
- **M17 — Failure isolation (never block compaction).** The hook MUST NEVER block compaction: on ANY capture failure (parse error, missing repo, missing `python3`, timeout, disk full) it logs a one-line diagnostic to stderr and exits `0`. It MUST NOT exit `2` (which blocks the operation), and its runtime MUST be bounded (soft timeout on oversized transcripts → give up, log, exit `0`).
- **M18 — MUST NOT (hard boundaries).** The hook path MUST NOT invoke any LLM; MUST NOT write into `memory.db` (artifacts live under `.claude/handoff/`, consistent with M8 isolation); MUST NOT replace cold `/handoff` — the artifact supplements it, never substitutes for the M4 brief. When `PreCompact`/`PostCompact` hooks are unsupported by the installed Claude Code version or simply not wired, the plugin MUST behave exactly as today (graceful absence — no errors, no degraded `/handoff` behavior).

---

## Test

1. **Multi-fork assembly (M1):** invoke on a known multi-fork uuid; assert the brief reflects a fact from the copied early-fork prefix (e.g. a root-session message surviving into the descendant file) — proves dedup + timestamp ordering of the canonical file.
2. **Single-file session (M1):** invoke on a session with no forks; assert success.
3. **Pre-pass strips bloat (M2, M6):** assert the brief contains none of a known large `toolUseResult` payload string from the source transcript.
4. **Monster completes (M3):** invoke on the ~72 MB (and growing) `vibes-project` session; assert it completes without context overflow and the brief is bounded (≤ ~400 lines).
5. **Required sections (M4):** assert all five sections present; assert ≥ 1 verbatim user correction appears under Dead-ends.
6. **Pointers resolve (M6):** pick 3 pointers from the brief; assert each resolves to a real transcript line / commit / symbol.
7. **Conflict flag (M5):** seed a session where a stated intent was never committed; assert it appears under Open-threads & conflicts.
8. **Cache (M8):** invoke twice → second is served from cache (no re-distill); append a message to the session → next invoke re-distills.
9. **Not-found (robustness):** invoke with an unknown uuid → clear error, no crash.
10. **Freshness guard (M9):** invoke on a transcript modified < 60 s ago → warns, does not parse.
11. **Warm mode (M10):** run bare `/handoff` in a live session → writes a five-section brief to `.claude/handoff/<session-id>-<slug>.md`; no uuid required; not injected.
12. **Consolidation (M11):** after install, `~/.claude/skills/handoff` is removed/deprecated and bare `/handoff` covers the warm path.

**Extension — PreCompact auto-handoff:**

13. **Rescue capture (M12):** simulate a `PreCompact` event (feed the stdin JSON with a real `transcript_path` to `precompact-capture.sh`) → a `<session-id>-precompact-<seq>.md` artifact appears under `.claude/handoff/`, contains spine pointers, contains none of the five M4 section headers, and no model was invoked (deterministic runtime only).
14. **Registration + emission (M13):** `.claude/settings.json` carries the `PreCompact` entry (both matchers covered); `check-hook-templates.sh` passes (template byte-identical to the live hook); the emitted command uses `${CLAUDE_PROJECT_DIR}` and contains no pipes.
15. **Carve-out is scoped (M14):** the capture succeeds on a transcript modified <60s ago (with a truncated final line dropped), while a plain cold `/handoff <uuid>` on the same file still declines per M9.
16. **Retention (M15):** trigger N+2 captures for one session → only the newest N artifacts remain; warm briefs and cache entries for the same session are untouched.
17. **Surfacing (M16):** after a capture + compaction, the session (or next session start) receives a one-line pointer with the artifact path and `/handoff <uuid>` suggestion — and the artifact body is NOT injected.
18. **Fail-open (M17):** force a capture failure (e.g. unreadable transcript) → hook exits `0`, compaction proceeds, one-line diagnostic on stderr; never exit `2`.
19. **Hard boundaries + graceful absence (M18):** no LLM call and no `memory.db` write occur on the hook path; with the hook unregistered (or on a Claude Code version without `PreCompact`), `/handoff` cold + warm behavior is byte-for-byte today's behavior.
20. **Signal-bearing sidechain reconstruction (M2, CDV-205):** synthetic `skills/handoff/fixtures/sidechain-signal.jsonl` → spine contains a `sidechain signal` block with `killed:` and a cue substring, no raw `toolUseResult`; synthetic `sidechain-noise.jsonl` → one-line `sidechain run collapsed` only (no `killed:`). Machine-check: `bash skills/handoff/sidechain-test.sh`.

---

## Validation

- [ ] Works retroactively on an existing session with no prior handoff
- [ ] Multi-fork timeline assembled correctly (early-fork fact present)
- [ ] 62 MB monster completes; brief bounded
- [ ] All five brief sections present; ≥1 verbatim correction captured
- [ ] Drill-down pointers resolve to real transcript lines / commits / symbols
- [ ] Stated-intent-vs-git mismatches flagged
- [ ] Cache hit on re-run; invalidated when the session grows
- [ ] No raw tool output appears in the brief
- [ ] Cache stored outside `memory.db`
- [ ] uuid-not-found and in-progress (<60s) cases handled gracefully
- [ ] Transcript parsing reuses the shared module (no duplication of SPEC-012 logic)
- [ ] Bare `/handoff` writes a warm five-section brief from live context
- [ ] Personal `~/.claude/skills/handoff` removed/deprecated; plugin `/handoff` covers cold + warm
- [x] PreCompact auto-handoff implemented and promoted (M12–M18; DRAFT marker dropped)

---

## Version History

| Date | Change |
|------|--------|
| 2026-06-04 | Initial spec created (from brainstorm `.claude/plans/2026-06-04-brainstorm-cold-session-handoff.md`; conflict-scanned vs SPEC-001..017) |
| 2026-06-04 | CDV-10 kickoff: added M10 (warm live-capture mode) + M11 (consolidation / replace personal skill) per user "full consolidation" decision; warm fold-in moved from out-of-scope to in-scope |
| 2026-06-04 | CDV-10 Task-1 spike (GATE-1): corrected M1 mechanism — `forkedFrom` is provenance, not a cross-file pointer; forks copy the prefix → assembly = locate canonical file + dedup-by-uuid keep-last + timestamp order (no cross-file walk); `isSidechain` collapse is a defensive no-op (never True in real data) |
| 2026-06-05 | Implemented via CDV-10 (Tasks 1-14): status NEW→ACTIVE |
| 2026-06-05 | Cache-eviction shipped (v0.30.1, HOFF-EVICT): `prepass.sh finalize` now bounds `.claude/handoff/cache/` — count-cap by `created_at` (HANDOFF_CACHE_MAX_ENTRIES, default 50), never evicts the just-written entry, sweeps orphan `*.tmp`; a cached brief is a derived memoization so eviction loses no recoverable context |
| 2026-06-15 | Editorial hygiene (AUDIT-P3.5b): Category `Core`→`core` (lowercase, matches SPEC-008 category list and all other specs/core). No behavioral change. |
| 2026-07-03 | Proposed extension (DRAFT): PreCompact auto-handoff — ideation wave 2 |
| 2026-07-14 | PreCompact auto-handoff implemented (M12–M18, CDV-182); DRAFT dropped |
| 2026-07-14 | CDV-205: M2 deeper sidechain reconstruction — signal-bearing runs emit condensed multi-line outcome (cue list in `parselib.SIDECHAIN_SIGNAL_CUES`); noise stays one-line; Test 20 + `sidechain-test.sh`; removed "deeper sidechain reconstruction" from out-of-scope |
