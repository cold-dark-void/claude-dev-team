# SPEC-018: Session Handoff (STM Packet)

**Status**: ACTIVE  
**Category**: core  
**Created**: 2026-06-04  
**Rework**: 2026-07-23 (CDT-79) — STM packet / compact seed (replaces prior inject-brief M4)

---

## Overview

A session-handoff Surface — `/handoff` — that produces a **STM packet** (short-term working memory): a noise-stripped, jury-style **evidence** artifact so a fresh or post-compact session continues from outcomes, kills, and user rulings without re-litigating dead ends or dumping noise into Linear.

**Primary consumer loop (compact seed):**

```
long session → /handoff → /branch|/fork → /compact @packet-file
```

**Modes:**

| Mode | Invocation | Behavior |
|------|------------|----------|
| **Cold** | `/handoff <session-uuid>` | Spine-mine past session JSONL; write STM packet file; **print State now + Through-line** into the invoking session and **cite the file path for appendix** (M7). |
| **Warm** | bare `/handoff` | Spine-mine **this** session's live JSONL (cold-on-self) + optional annotation; **file-only** write (M10). |
| **Help** | `/handoff --help` | Usage; exit. |

Design: deterministic LLM-free **pre-pass** (fork-tree assembly + `toolUseResult` strip + dedup) produces a size-adaptive **spine**. **Spine-mine** runs one merged LLM miner (single spine read) writing through_line + state event files over the spine (or reduced spine after chunk map), plus **deterministic git** for appendix code-state. **Assemble** (LLM-free) emits the STM packet: **State now → Through-line → appendix**. Warm may add **annotation** that can only reference existing event IDs (labels/rank — never invent evidence).

**Glossary terms** (see `CONTEXT.md`): STM packet, Through-line, Compact seed, Spine-mine, State now.

**Boundaries & related specs:**

- **SPEC-012 (`/retro`)** — shared `transcript-parse` for locate/assemble/freshness; no private re-parse.
- **SPEC-006 (`/recall`)** — discovery peer (uuid search); not dual SoT for packet content.
- **SPEC-013 (`/council`)** — M5 is lightweight intent-vs-git flag only; no adversarial pipeline.
- **Memory (SPEC-004/006/007/011)** — packet cache and files live under `.claude/handoff/`, **outside** `memory.db`.

**Out of scope (v1 / CDT-79):** PreCompact emitting full STM packet (rescue remains spine snapshot); auto-handoff-before-every-compact; `/recall` ranking of packets; option C deterministic cue-prepass as primary mine; lifetime archive / memory-distill validation; harness `/compact` replacement claim; Linear dual-write of packet content.

---

## MUST

### Pipeline (shared)

- **M1 — Locate & assemble.** Given a session uuid, select the **canonical transcript file** — the descendant whose copied prefix is most complete (greatest max-`timestamp` among files under `~/.claude/projects/` containing that uuid) — then produce one chronologically ordered timeline by **de-duplicating copied messages on `uuid` (keep-last)** and ordering by **`(timestamp, file-position)`**. `forkedFrom` is **provenance** (`{sessionId, messageUuid}`; `messageUuid` is self-referential), NOT a cross-file pointer. Ordering MUST use timestamps, not the `parentUuid` DAG. Location + parsing MUST use the shared module (SPEC-012). *(Mechanism corrected by CDV-10 Task-1 spike.)*
- **M2 — Deterministic pre-pass (no LLM).** Before mine: strip `toolUseResult` payloads, dedup repeated reads of the same path (retain last), collapse each `isSidechain` segment. Default: one-line outcome + optional courtesy pointer. **When signal-bearing** (cue list in `parselib.SIDECHAIN_SIGNAL_CUES`), emit condensed multi-line reconstruction (span + `hypothesis` / `killed` / `notes`, hard cap ~400 chars) — still no raw `toolUseResult`. Stats: `sidechain_runs_collapsed` + `sidechain_runs_signal`.
- **M3 — Size-adaptive spine.** If stripped spine fits target context window, mine directly; if not, chunk at message boundaries, summarize chunks in parallel (**preserving** hypotheses, corrections, decisions, facts, opens for the through-line), then mine the reduced spine. MUST complete on oversized (≥ 60 MB) transcripts without context overflow.
- **M3b — Spine-mine (shared engine).** Warm and cold MUST share one spine-mine pipeline: prepass → (optional chunk map) → **one LLM miner (merged)** + **deterministic git** → **assemble**. MUST NOT leave a freeform warm essay path as a dual source of truth.
  - **Merged miner:** one Task MUST read the miner spine **once** and emit **both** event files:
    - `through_line.json` — events of kinds ⊆ {`hypothesis`, `killed`, `ruling`, `decision`, `fact`} only.
    - `state.json` — events of kinds ⊆ {`open`, `conflict`} only (incl. M5 stated-intent-vs-git as `conflict` and/or `open`).
  - MUST NOT spawn two full-spine LLM miners for the same capture (duplicate spine read is a defect).
  - **Delta spine (CDT-88):** Miner input MAY be a **delta spine** (messages after a prior leaf only — see M8b). Event files remain `through_line.json` + `state.json` over that spine. Assemble is the sole merge SoT for prior cumulative events + delta miner output. Still **one** merged miner Task (no second full-spine read, no dual miner for prior vs delta).
  - **Code-state:** git log/diff/status only — **no LLM miner**.
  - Miner emits **schema-validated event JSON only** (no freeform brief sections).
  - Kind ceiling remains **seven** (M3c); file-level kind ceilings unchanged.
  - MUST NOT split kinds across two Tasks that each re-read the full spine.
  - Assemble input contract unchanged for the delta files (directory of `*.json`, typically `through_line.json` + `state.json`); when prior events are supplied (M8b), assemble MUST merge prior + delta before State now / Through-line selection.
  - MUST NOT change user-facing `/handoff` CLI or packet section order (internal `--since-leaf` and `--full` / `HANDOFF_FULL` are M8b).
- **M3e — Spawn model tiers (cost knobs).** Orchestrator Task spawns for spine-mine LLM stages MUST use **tier aliases only** (`haiku` / `sonnet` / `opus` style); MUST NOT pin dated model IDs.
  - Chunk-summarizer Tasks (Step 5b) MUST set `model: haiku`.
  - Warm annotation Task (Step 7) MUST set `model: haiku`.
  - Merged miner Task (Step 6) MUST **inherit session model** by default (omit `model`, or document inherit). MAY set model from env **`HANDOFF_MINER_MODEL`** when non-empty (tier alias). Empty/unset = inherit.
  - `effort` on any of these Tasks is **optional**; MUST NOT be required for correctness.
  - The **parent/orchestrator** turn MUST remain at session tier (MUST NOT force haiku on the parent loop).
  - `HANDOFF_SPINE_TOKENS` default remains **120000**; warm operators MAY lower via env to force earlier chunking (docs guidance only).
- **M3c — Event model.** Each event MUST include: `id`, `kind`, `text` or `quote`, `workstream` (default `"default"`), and order/timestamp when available. Optional courtesy `pointers[]` (never load-bearing). `fact` events SHOULD include `how_verified`. Kind ceiling is **seven**: `hypothesis`, `killed`, `ruling`, `decision`, `fact`, `open`, `conflict`.
- **M3d — Assemble (LLM-free).** Assemble MUST: (1) **dedup** on `(kind + normalized quote/text)`; (2) emit **State now** by mechanical selection from the **tail** of the event log (latest decisions, surviving unkilled hypotheses, all opens) — **not** an LLM essay; (3) emit **Through-line** chronological events grouped by `workstream` when multiple; (4) emit **appendix** (long kill catalog if needed, git code-state, dense basics); (5) footer with advisory `packet_tokens / stripped_spine_tokens` when stats available. Packet section order is fixed: **State now → Through-line → appendix**.
- **M4 — STM packet shape.** The artifact MUST be an **STM packet** / **compact seed** with the fixed order in M3d. Product success is measured by post-`compact @packet` continuity, not inject-density into a blank session. Freeform essay sections and slogan-thin packets (no kills/rulings/facts when thrash existed) are defects. Raw tool dumps in the packet are defects equal to slogan thinness.
- **M5 — Stated-intent vs git flag (lightweight).** The packet MUST flag mismatches between intentions stated in the transcript and actual git state (as `conflict`/`open` events). Heuristic only — MUST NOT implement adversarial verification; deep audit is `/council` (SPEC-013).
- **M6 — Quotes admissible, dumps not (partial inversion of prior M6).** User `ruling` and `killed` reasons MUST appear **short-verbatim inline** in the packet (≤ ~200 chars; longer → load-bearing clause + summary). A claim that is only true if a `transcript:L*` pointer resolves is a **defect** (pointers rot on the days–months STM horizon). Pointers (`transcript:L`, `commit:`, `file:`) are **courtesy** drill-downs, never load-bearing. MUST NOT inline raw tool output / `toolUseResult`.
- **M7 — Cold output (inject core, file full).** In cold mode the command MUST: (a) write the full STM packet to `<target-MROOT>/.claude/handoff/<YYYYMMDD-HHmm>-<session-id>-<slug>.md`; (b) print **State now + Through-line** into the invoking session; (c) **cite the file path** for appendix (do not dump full appendix into the live window). The cited path MUST equal the actual write path.
- **M7b — Target-session write root (CDT-80).** Packet path, M8 cache, and git appendix MUST resolve from the **target session's project**, never from the invoker's cwd. Cold: after the uuid is located, derive project from transcript `cwd` (preferred) via `skills/handoff/resolve-root.sh`, then `MROOT` via `git rev-parse --git-common-dir` from that cwd (worktree → shared main repo). Warm: same helper on this session's transcript. Non-git target: `HANDOFF_DIR = <project-dir>/.claude/handoff/`; git sections may be empty. If the target root cannot be determined after locate → **fail hard** (no write under invoker cwd). Invoker in repo A with target session in repo B → all artifacts under B. MUST NOT write under `$HOME/.claude/.claude/` when the target project is not `$HOME/.claude`.
- **M8 — Result cache.** Distilled STM packet MUST be cached keyed by `(session uuid + last-message uuid)` and reused until the session grows. Cache MUST live outside `memory.db` under the target `$MROOT/.claude/handoff/cache/`.
- **M8b — Delta-mine re-capture (CDT-88).** Warm re-capture MUST NOT re-mine the full session when a usable prior event set is available from the M8 cache.
  - **Cache `events`:** Cache payload MAY/MUST store a cumulative **`events` stem map** after successful assemble (keys = miner stems such as `through_line`, `state`; values = post-dedup event objects with **raw miner ids**, no stem / no `prior:` prefix). Dual-read soft: absent / null / empty / unreadable `events` → treat as no prior (same soft pattern as `packet`/`brief` dual-read). Cold and full paths SHOULD still **write** `events` on finalize so the next warm re-capture can delta.
  - **Warm delta path:** When warm re-capture finds cache `leaf_uuid` + non-empty `events` and is not full-forced, prepare MUST spine-mine **since** that cached leaf (`--since-leaf` internal/debug only — not user-facing CLI help). Stats (`est_tokens` / spine size) MUST reflect the **delta**, not the full transcript.
  - **Assemble merge:** Assemble MUST merge prior cache events + delta miner files with generation-aware order (prior before delta) and existing `(kind, normalized body)` dedup (first wins → prior verbatim survives). Cross-gen ids: prior → `prior:{stem}:{raw_id}`; fresh → `{stem}:{raw_id}` (extends CDT-93 invent-guard). Step 7 annotation summary MUST see the **merged** namespaced event set. Prior events MUST be taken **verbatim** from cache — no re-paraphrase.
  - **No packet parse:** MUST NOT recover events by re-parsing packet/brief markdown; events come only from the cache `events` field (or full re-mine).
  - **Full force / fallback:** `/handoff --full` or `HANDOFF_FULL=1` MUST force full prepare/mine (ignore cache events / since-leaf). Any miss (no events, since-leaf not in timeline, prepare fail, empty unusable prior) MUST fall back to full re-mine without crash.
  - **Cold HIT unchanged:** Cold cache-check HIT (leaf match → serve core) MUST remain byte-identical; cold MISS does not auto-apply since-leaf. M8b does not introduce M10c (reserved).
- **M9 — Freshness guard (cold).** If the target transcript was modified < 60 s ago, cold `/handoff` MUST warn and decline to parse mid-write (SPEC-012). Default cold path MUST NOT use the mid-write carve-out.
- **M10 — Warm mode (spine-mine self).** Bare `/handoff` MUST spine-mine **this** session's JSONL via the shared engine (not freeform rewrite from live model memory). Warm MAY run an **annotation** pass whose output schema can only reference existing event IDs (`{ event_id, labels[], rank? }`) — MUST NOT invent evidence. Event IDs for invent-guard are the **namespaced** form from assemble `load_events` (`{stem}:{raw_id}`, e.g. `through_line:tl-e1`); bare miner ids MUST NOT match (CDT-93). Warm MUST write the packet **file-only** (not print core into the still-live session as primary product). Mid-write read of **this session's** transcript is allowed via a **warm-only** carve-out (M14 pattern): drop truncated last line; fail soft; carve-out MUST NOT be reachable from cold user path.
- **M10b — Session-id bridge + honesty (CDT-85 / CDT-92).** Warm discovery MUST resolve a live session id + transcript path for the **host in use** via `skills/handoff/discover-warm.sh`.

  **Host selection:** Explicit Grok env (steps 1–2) wins. Grok cwd-newest (step 3) MUST win over a *stale* Claude bridge or Claude projects-dir tip (CDT-92) but MUST NOT fire when a definitive live-Claude env signal is present (`CLAUDE_SESSION_ID`, or `CLAUDE_TRANSCRIPT_PATH` / `TRANSCRIPT_PATH` pointing at a real non-Grok file) — otherwise dual-host repos silently mine the wrong session. When only Claude is resolvable, Claude path (CDT-85) is unchanged. When neither resolves → fail clear; MUST NOT freeform-write live-context as warm STM.

  **Grok discovery precedence (when Grok path active):**
  (1) Grok/session env (`GROK_SESSION_ID` / `GROK_TRANSCRIPT_PATH` / non-empty `SESSION_ID` that names a dir under `GROK_SESSIONS_DIR`);
  (2) `CLAUDE_SESSION_ID` / `CLAUDE_TRANSCRIPT_PATH` / `TRANSCRIPT_PATH` **only if** the path is a Grok `chat_history.jsonl` **under** `${GROK_SESSIONS_DIR:-~/.grok/sessions}` (basename alone is insufficient; sid from parent dir of that file);
  (3) newest-mtime `chat_history.jsonl` under `${GROK_SESSIONS_DIR:-~/.grok/sessions}/<urlencode(cwd)>/*/` — **skipped** when live Claude env signal is set;
  (4) else Grok miss (fall through to Claude discovery or hard fail).

  **Claude discovery precedence:** unchanged from CDT-85 (env → bridge → stem → cwd-newest under `CLAUDE_PROJECTS_DIR`) but **skipped** when Grok already resolved via steps 1–2 or ungated step 3.

  **Grok normalize:** Before prepare, Grok `chat_history` MUST be adapted to Claude-shaped JSONL (user/assistant `message.role`, synthetic `uuid`, injected `cwd` for M7b resolve-root). Shared spine-mine after prepare is unchanged (M3b).

  On success, warm MUST: (a) write/update a session-id bridge (`.live-session.json` under target handoff dir when resolvable) with the resolved host session id + **source** transcript path (Grok `chat_history` or Claude jsonl) and `host: grok|claude`; (b) emit packet header/footer `mode: warm` and `session: <id>`; (c) use that id in the filename so later cold/re-capture can `Supersedes:` the same session tip. AC-16 human 3/3 MUST NOT be claimed from cold-only dogfood, Grok-only dogfood, or unit fixtures alone; warm thesis still requires Claude Code bare-`/handoff` anti-relitigation (see dogfood runbook).
- **M11 — Filename, slug, Supersedes.** Packet files MUST use `<YYYYMMDD-HHmm>-<session-id>-<slug>.md` under `.claude/handoff/`. Slug: optional user arg; else sanitized first decision/open text (≤40 chars); else `stm`. When the same session is re-captured, write a **new** file and set header `Supersedes: <prior-filename>` so the living tip is unambiguous (one-file default with versioned names).
- **M11b — Unclear landing.** If the session did not land a root cause, the packet MUST NOT invent one. Prefer evidence trail + `open` events; optional `INFERRED` **label** on an existing event via annotation only.
- **M11c — No Linear dual-write.** The handoff path MUST NOT write STM packet content into Linear. Epic/backlog work remains separate Surfaces.
- **M11d — Docs claim boundary.** v1 MUST NOT claim full harness `/compact` replacement. Position: compact-prep STM / compact seed.
- **MUST NOT** require any action during the original session for cold mode — cold operates **retroactively** on existing transcripts.

### Extension — PreCompact auto-handoff

Goal: capture a rescue artifact BEFORE compaction via harness `PreCompact` hook. Hooks run shell commands, not model turns — deterministic by construction.

- **M12 — Deterministic rescue capture (LLM-free).** A `PreCompact` hook MUST invoke capture (e.g. `skills/handoff/precompact-capture.sh`) against live `transcript_path` from hook stdin JSON and write `<session-id>-precompact-<seq>.md` under `.claude/handoff/`. The artifact is a **spine snapshot + drill-down pointers** — **explicitly NOT an STM packet** (State now / Through-line / appendix quality requires spine-mine). It is raw material for later cold `/handoff <uuid>`.
- **M13 — Registration + template emission (template SoT).** Hook registered under `PreCompact` and emitted by `/setup orchestration` template set. `${CLAUDE_PROJECT_DIR}`-anchored; no pipe operators in emitted command.
- **M14 — Scoped freshness-guard carve-out.** PreCompact capture and **warm self-mine** may bypass M9 mid-write via explicit `--allow-in-progress` (or equivalent) scoped to those paths only. MUST tolerate truncated final JSONL line (drop it). Cold user path MUST remain declined under M9. Warm carve-out applies only to reading **this session's** transcript.
- **M15 — Bounded retention.** At most N precompact artifacts per session (default 3); prune oldest-first; MUST NOT prune warm/cold STM packets or M8 cache by this path.
- **M16 — Surfacing (pointer, not dump).** Post-compact / next session: one-line pointer to rescue path + suggest `/handoff <uuid>`. MUST NOT dump rescue body into context.
- **M17 — Failure isolation.** Capture failure MUST exit `0`, never block compaction; bounded runtime; stderr diagnostic only.
- **M18 — MUST NOT.** Hook path MUST NOT invoke LLM; MUST NOT write `memory.db`; MUST NOT replace cold/warm STM packet quality. Graceful absence if hooks unsupported.

---

## Test

1. **Multi-fork assembly (M1):** cold on multi-fork uuid; packet reflects fact from copied early-fork prefix.
2. **Single-file session (M1):** cold succeeds on no-fork session.
3. **Pre-pass strips bloat (M2, M6):** packet contains none of a known large `toolUseResult` string.
4. **Monster completes (M3):** cold on ~72 MB transcript completes without context overflow; packet has State now + Through-line leading content.
5. **STM packet sections (M4):** assert fixed order headers present: State now, Through-line, appendix (or equivalent labeled headings); assert ≥1 verbatim user `ruling` or `killed` reason inline when source session has thrash.
6. **Quotes load-bearing (M6):** pick 3 inline rulings/kills; assert claim text is present in packet body without requiring pointer resolution.
7. **Conflict flag (M5):** session with stated intent never committed → `conflict`/`open` in packet.
8. **Cache (M8):** invoke twice → second cache hit; append message → re-mine.
9. **Not-found:** unknown uuid → clear error, no crash.
10. **Freshness guard (M9):** cold on transcript modified <60s → warn, decline.
11. **Warm mode (M10):** bare `/handoff` runs spine-mine on live session file (not freeform-only); writes timestamped STM packet under `.claude/handoff/`; file-only.
11b. **Session-id bridge (M10b / CDT-85):** discover writes `.live-session.json`; packet has `mode: warm` + `session: <id>`; missing session id → clear fail (no freeform dual path); filename id enables Supersedes.
11c. **Grok warm (M10b / CDT-92):** fixture `chat_history` → adapter spine contains known phrase; discover prefers Grok over stale Claude bridge; live `CLAUDE_SESSION_ID` beats Grok cwd-newest (no dual-host hijack); prepare exit 0; packet under target MROOT; bridge `session_id` = Grok id (`host: grok`). Neither host → fail hard. Claude-only path still green when no Grok. Coverage: `skills/handoff/grok-to-claude-jsonl-test.sh`, `skills/handoff/discover-warm-test.sh` (Grok cases + dual-present).
12. **Supersedes (M11):** second warm capture same session → new filename + `Supersedes:` header pointing at prior.
13. **PreCompact rescue (M12):** capture produces spine snapshot; MUST NOT claim to be an STM packet — assert rescue is spine-form / recover pointer present.
14. **Registration (M13):** settings + template emit present after setup.
15. **Carve-out scoped (M14):** warm/precompact succeed mid-write; cold still declines.
16. **Retention (M15):** N+2 precompacts → only newest N; STM packets untouched.
17. **Surfacing (M16):** pointer only after compact.
18. **Fail-open (M17):** capture failure → exit 0.
19. **Hard boundaries (M18):** no LLM / no memory.db on hook path.
20. **Signal-bearing sidechain (M2, CDV-205):** fixtures → spine signal vs noise as today (`sidechain-test.sh`).
21. **Annotation invent-guard (M10 / CDT-93):** annotation `event_id` must exact-match a namespaced load id (`{stem}:{raw_id}`); unknown or bare miner ids are dropped; no new evidence fields in annotation schema.
22. **Cold print shape (M7):** cold stdout includes State now + Through-line and cites packet path; full appendix not required in stdout.
23. **Target write root (M7b / CDT-80):** cold from non-repo invoker cwd for a known-project session writes under that project's `.claude/handoff/`; cache under its `cache/`; git appendix is target HEAD/status; undetermined root fails with no invoker write; worktree session → shared MROOT; invoker repo A / target B → all under B.
24. **Spawn model tiers (M3e / CDT-90):** static contract — chunk + annotation spawn text includes `model: haiku`; miner default inherits (no forced haiku without env); parent not forced haiku; tier aliases only (no dated model IDs).
25. **Delta-mine stats (M8b / CDT-88):** warm re-capture with cache `events` + grown session → prepare `--since-leaf` plan stats (`est_tokens` / `spine_msgs` / `delta_msgs`) reflect delta only (`<<` full); `full_msgs` / `since_leaf` present when cut applied.
26. **Assemble prior+delta merge (M8b / M3b / CDT-88):** prior cache events + delta miner files → merged packet; prior bodies survive verbatim; cross-gen ids `prior:{stem}:{id}` and `{stem}:{id}`; generation order puts delta after prior for State now tail; dedup `(kind, norm body)` first-wins.
27. **Cache events dual-read (M8b / CDT-88):** old cache without `events` (or null/empty/unreadable) → full re-mine, no crash; cache with `events` written on finalize is readable on next warm delta path.
28. **Full force (M8b / CDT-88):** `--full` or `HANDOFF_FULL=1` forces full prepare/mine even when cache has `leaf_uuid` + `events`; cold cache-check HIT path unchanged.

**Human ship gate (CDT-79 AC-16 — not CI):** ≥3 re-captures under new contract (≥2 long-debug: multi-hypothesis thrash with kills; ≥1 multi-week: ≥2 calendar weeks or multi-child program arc); after compact `@packet`, next session does not re-propose packet-resident kills/rulings; human 3/3.

---

## Validation

- [ ] Cold retroactive handoff produces STM packet file + core print
- [ ] Warm spine-mines live JSONL (no freeform dual path)
- [ ] Shared engine: 1 merged miner + git + LLM-free assemble
- [ ] State now mechanical; quotes inline; no tool dumps
- [ ] Cache outside memory.db; M9 cold; warm mid-write carve-out scoped
- [ ] Supersedes on re-capture; timestamped filenames
- [ ] PreCompact still spine rescue only; fail-open
- [ ] Docs: compact seed framing; no Linear dual-write; no compact-replacement claim
- [ ] Internal legacy inject-brief / multi-extractor references swept from SPEC, skill, command, docs, tests
- [ ] Spawn model tiers (M3e): chunk + annotation `model: haiku`; miner inherits session unless `HANDOFF_MINER_MODEL`; parent session tier; `HANDOFF_SPINE_TOKENS` default 120000

---

## Version History

| Date | Change |
|------|--------|
| 2026-07-27 | **CDT-88:** M8b delta-mine re-capture — cache `events` stem map; warm spine since cached leaf when events present; assemble prior+delta merge (generation order + existing dedup); full fallback; no packet parse; `--full`/`HANDOFF_FULL`; cold HIT unchanged. M3b amend: miner MAY take delta spine; still one merged miner; assemble sole merge SoT. Tests 25–28. MUST NOT introduce M10c (reserved CDT-91) |
| 2026-07-27 | **CDT-90:** M3e spawn model tiers — chunk + annotation haiku; merged miner session-inherit + `HANDOFF_MINER_MODEL` opt-in; effort optional; parent stays session tier; `HANDOFF_SPINE_TOKENS` default 120000; Test 24 |
| 2026-06-04 | Initial spec (cold handoff brainstorm) |
| 2026-06-04 | M10 warm + M11 consolidation (CDV-10) |
| 2026-06-04 | M1 mechanism corrected (CDV-10 GATE-1) |
| 2026-06-05 | Implemented CDV-10; ACTIVE |
| 2026-06-05 | Cache eviction (HOFF-EVICT) |
| 2026-06-15 | Editorial hygiene AUDIT-P3.5b |
| 2026-07-03 | PreCompact extension DRAFT |
| 2026-07-14 | PreCompact M12–M18 implemented (CDV-182) |
| 2026-07-14 | CDV-205 sidechain signal reconstruction |
| 2026-07-22 | CDT-54 M13 template SoT |
| 2026-07-27 | **CDT-89:** M3b single merged miner — one Task, one spine read, both `through_line.json` + `state.json`; MUST NOT two full-spine miners; fan-out 1 Task; finalize/assemble two-file contract unchanged |
| 2026-07-27 | **CDT-92 follow-up:** Grok step-3 cwd-newest gated when live Claude env present; `is_grok_chat_history` scoped under sessions root; dual-present discover tests |
| 2026-07-27 | **CDT-92:** M10b Grok warm host + `chat_history`→Claude adapter; dual-host discover (explicit Grok / cwd-newest over stale Claude bridge); Test 11c |
| 2026-07-26 | **CDT-85:** M10b session-id bridge + AC-16 honesty — `.live-session.json`, packet `mode: warm|cold`, fail (not freeform) when session id missing; warm dogfood runbook gate explicit; no AC-16 3/3 warm claim from cold-only |
| 2026-07-26 | **CDT-80:** M7b target-session write root — packet/cache/git from target project via `resolve-root.sh`, not invoker cwd; fail hard if undetermined |
| 2026-07-23 | **CDT-79 major rework:** STM packet / compact seed; spine-mine; event assemble; State now; M4/M6/M7/M10/M11 rewrite; M14 warm carve-out; five-section brief retired; PreCompact remains spine rescue |
