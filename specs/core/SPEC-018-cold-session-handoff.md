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

Design: deterministic LLM-free **pre-pass** (fork-tree assembly + `toolUseResult` strip + dedup) produces a size-adaptive **spine**. **Spine-mine** runs one merged LLM miner (single spine read) writing through_line + state event files over the spine (or reduced spine after chunk map), plus **deterministic git** for appendix code-state. **Assemble** (LLM-free) emits the STM packet: **State now → Through-line → appendix**, with **single-section** event render (CDT-201). Warm may add **annotation** that can only reference existing event IDs (labels/rank — never invent evidence).

**Glossary terms** (see `CONTEXT.md`): STM packet, Through-line, Compact seed, Spine-mine, State now, Product surfaces, Open ship gaps.

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
- **M3 — Size-adaptive spine.** If stripped spine fits target context window, mine directly; if not, chunk at message boundaries, summarize chunks in parallel (**preserving** hypotheses, corrections, decisions, facts, opens for the through-line), then mine the reduced spine. MUST complete on oversized (≥ 60 MB) transcripts without context overflow. **Chunked map is in-session only (M19):** parent MUST run the parallel N haiku chunk-summarizers; the detached agent MUST NOT run or serialize the map.
- **M3b — Spine-mine (shared engine).** Warm and cold MUST share one spine-mine pipeline: prepass → (optional chunk map) → **one LLM miner (merged)** + **deterministic git** → **assemble**. MUST NOT leave a freeform warm essay path as a dual source of truth.
  - **Merged miner:** one LLM actor MUST read the miner spine **once** and emit **both** event files:
    - `through_line.json` — events of kinds ⊆ {`hypothesis`, `killed`, `ruling`, `decision`, `fact`} only.
    - `state.json` — events of kinds ⊆ {`open`, `conflict`} only (incl. M5 stated-intent-vs-git as `conflict` and/or `open`).
  - **Actor (CDT-204 / M19):** on the detached path (`plan.mode=direct`) the background orchestrator agent **IS** the miner (INLINE; writes both files; MUST NOT nest a miner Task). On in-session fallback (`plan.mode=chunked` or host cannot spawn a background agent) the actor is **one** miner Task as before.
  - MUST NOT spawn two full-spine LLM miners for the same capture (duplicate spine read is a defect). INLINE plus a miner Task on the same capture is the same defect.
  - **Delta spine (CDT-88):** Miner input MAY be a **delta spine** (messages after a prior leaf only — see M8b). Event files remain `through_line.json` + `state.json` over that spine. Assemble is the sole merge SoT for prior cumulative events + delta miner output. Still **one** merged miner actor (no second full-spine read, no dual miner for prior vs delta).
  - **Code-state:** git log/diff/status only — **no LLM miner**.
  - Miner emits **schema-validated event JSON only** (no freeform brief sections). Optional wrapper `summary` (M3c) is the only non-event string on those files.
  - Kind ceiling remains **seven** (M3c); file-level kind ceilings unchanged.
  - **Miner prompt (CDT-201):** `skills/handoff/SKILL.md` and `skills/handoff/LIGHT.md` merged-miner templates MUST both include: (d) ruling-context — a bare pick (`1`, `y`, `B Y`) MUST NOT be the sole ruling body; `text` MUST carry the question plus the pick; `quote` MAY stay the verbatim pick (M6); static negative + positive examples; (e) `facet: product_surface` negatives — constraints and ticket IDs are not Product surfaces; constraints → `fact`/`decision` without that facet; ticket IDs → `open`/`decision`/`ship_gap` as appropriate; positives are named UX. Assemble MUST NOT add NLP/ticket-id facet filters.
  - MUST NOT split kinds across two Tasks (or two INLINE passes) that each re-read the full spine.
  - Assemble input contract unchanged for the delta files (directory of `*.json`, typically `through_line.json` + `state.json`); when prior events are supplied (M8b), assemble MUST merge prior + delta before State now / Through-line selection.
  - MUST NOT change user-facing `/handoff` CLI or packet section order (internal `--since-leaf` and `--full` / `HANDOFF_FULL` are M8b).
- **M3e — Spawn model tiers (cost knobs).** Spine-mine LLM stages MUST use **tier aliases only**; MUST NOT pin dated model IDs (no `claude-*-20YY`, no `grok-4.x`, no `spark-llama`).
  - Chunk-summarizer Tasks (Step 5b) MUST set `model: haiku`. These Tasks exist **only** on the in-session chunked fallback (M19). The detached agent MUST NOT spawn them.
  - Warm annotation: in-session fallback MUST set the annotation Task `model: haiku`. Detached bare-warm annotation is **INLINE** in the same background agent as the miner (no nested Task; no separate model pin). Light/cold still skip annotation.
  - `--miner-model` MUST NOT retarget chunk-summarizer or annotation. Grok cheap-stage host mapping is **out of scope** (CDT-203); in-session tests keep the literal `model: haiku` pin on chunk (+ annotation Task when that path runs).
  - **Miner actor model:** inherit session by default (omit `model`). MAY set from env **`HANDOFF_MINER_MODEL`** when non-empty. Empty/unset = inherit.
    - **Detached (M19, `plan.mode=direct`):** apply the resolved alias to the **ONE background agent's** `model:` (not a nested miner Task).
    - **In-session fallback:** apply to the miner Task `model:` as before.
  - **CLI (CDT-203):** `/handoff --miner-model <alias>` and `--miner-model=<alias>` MUST parse in `commands/handoff.md` Step 1 and export `HANDOFF_MINER_MODEL` as the **alias as given** (MUST NOT resolve at parse). Valid on warm, `--light`, `--full`, and cold. Not a third mode. MUST NOT skip annotation, change M8 cache behavior, or change `HANDOFF_SPINE_TOKENS`.
  - Missing value (`--miner-model` with no following token, `--miner-model=`, `--miner-model` followed by another flag) MUST print `error: --miner-model requires a value` on stderr and exit 1. MUST NOT fall through to unknown-flag help (exit 0). MUST NOT spawn the detached agent.
  - Precedence: **flag > operator env > light preset > inherit**. M10c still sets `HANDOFF_MINER_MODEL=haiku` only when unset.
  - Canonical host-neutral aliases (exact lowercase only): `fast` | `balanced` | `max`. Resolve at **spawn of the miner actor**, using session-bridge `host: grok|claude`. Cold / missing / unknown host → **claude** table. Mapping: `fast` → Claude `haiku` / Grok `fast` (identity); `balanced` → Claude `sonnet` / Grok `balanced` (identity); `max` → inherit (omit `model`) on both hosts.
  - Grok cells MUST be identity. MUST NOT pin dated Grok slugs. Host reject of `fast`/`balanced` → existing fail-soft inherit; if the host later accepts those aliases, identity already works.
  - Any other non-empty value (including `haiku`/`sonnet`/`opus`, mixed case, unknown) MUST pass through as the miner actor `model:` as-is. Host reject → omit `model` (fail-soft inherit). Unknown alias MUST NOT be a parse error. Want opus → `--miner-model opus` (passthrough). `max` is inherit, never opus.
  - **Advisory (after successful Step 4 prepare):** MUST print exactly one stdout line from `plan.mode` + `stats.est_tokens`. Parent runs prepare on both detached and in-session paths, so the advisory prints **in the parent**.
    - `mode==direct` AND `est_tokens < 30000` → `fast tier is likely sufficient for this mine`
    - `mode==chunked` OR (`mode==direct` AND `est_tokens >= 30000`) → `keep session tier`
    MUST NOT print when prepare failed, no `plan.json`, or tokens missing / non-numeric / ≤0. MUST NOT run on cold cache-HIT (no prepare). MUST NOT mutate `HANDOFF_MINER_MODEL`. Prints even if `--miner-model` is already set.
  - Dual-home: `skills/handoff/SKILL.md` and `skills/handoff/LIGHT.md` M3e sections MUST carry the same tier table + host-resolution + fail-soft note **and** the detached-INLINE vs in-session-Task table (M19).
  - `effort` on any Task is **optional**; MUST NOT be required for correctness.
  - The **parent stub** turn MUST remain at session tier (MUST NOT force haiku on the parent loop). The background agent's model is the miner tier (above), not the parent.
  - `HANDOFF_SPINE_TOKENS` default remains **120000**; warm operators MAY lower via env to force earlier chunking (docs guidance only).
  - MUST NOT change `prepass.sh`, `assemble.py`, or `discover-warm.sh` behavior.
- **M3c — Event model.** Each event MUST include: `id`, `kind`, `text` or `quote`, `workstream` (default `"default"`), and order/timestamp when available. Optional courtesy `pointers[]` (never load-bearing). `fact` events SHOULD include `how_verified`. Kind ceiling is **seven**: `hypothesis`, `killed`, `ruling`, `decision`, `fact`, `open`, `conflict`. Optional miner tags (not kinds): `facet` ∈ {`product_surface`, `ship_gap`} and `surface_class` ∈ {`primary`, `unfinished`, `not_product`} (`not_product` ≡ unfinished / do-not-treat-as-product). Product surfaces SHOULD be emitted as `fact` + `facet=product_surface`; Open ship gaps as `open` + `facet=ship_gap`. Assemble selects by `facet` — MUST NOT add kinds. Miner JSON files MAY carry an optional wrapper string `summary` beside `events` (`{"summary":"…","events":[…]}`). `summary` is **not** an event and **not** a kind; MUST NOT be written into the M8 `events` stem map. Chunk-summarizer JSON `summary` is a different field (unchanged). Event-object shape, seven-kind ceiling, and two-file partition are unchanged. If both miner files set `summary`, assemble MUST use `through_line.json` only.
- **M3d — Assemble (LLM-free).** Assemble MUST stay LLM-free and MUST:
  - **(1) Dedup** **before** section selection (CDT-202), in this order: **(a)** exact `(kind + normalized quote/text)` first-wins (any length; first event’s original display text); **(b)** same-kind strict prefix-collapse when the shorter punct-stripped normalized body is ≥40 chars — keep the longer original display body; the survivor occupies the earliest post-order event (`id`, facet, labels, section); chains A⊂B⊂C collapse to one (longest body, earliest of the chain); **(c)** `open`/`conflict` only: if a `conflict` body equals or is a prefix/superstring of an `open` under the same ≥40 rule (exact or prefix), drop every matching `conflict`, keep the `open` (even if the conflict body is longer), and emit one `assemble:` stderr line that names both; MUST NOT generalize (c) to other kind pairs. Compare key: `event_body` (quote else text) → `normalize_text` (casefold + whitespace collapse); prefix/cross-kind then rstrip whitespace and ASCII `.?!;:,`. Prefix is a STRICT prefix of that string — MUST NOT mid-body substring or fuzzy match. Same-kind prefix-collapse MUST NOT emit stderr.
  - **(2) State now** — mechanical selection from the **tail** of the post-dedup log, **not** an LLM essay:
    - Optional `### Where we are` (M3d summary / M11b) as the **first** State now block when a valid wrapper `summary` is present; omit the heading when the summary is omitted. This block is **not** an event render (does not occupy an event `id` for single-section).
    - Required subsections **Product surfaces** (primary UX + unfinished / do-not-treat-as-product) and **Open ship gaps**.
    - Latest decisions (soft cap unchanged), surviving unkilled hypotheses, and **untagged** `open`s under **Open**.
    - **Intra-State now facet buckets (CDT-201):** `facet=ship_gap` → Open ship gaps only (MUST NOT also list under Open); `facet=product_surface` → Product surfaces only (MUST NOT also list under Decisions / Hypotheses / Open). Assemble MUST NOT add NLP or ticket-id facet filters — miner tags only.
    - Product surfaces (and other sole-render State now bullets) MUST include the same inline `↳` pointer line used elsewhere when the event has `pointers[]`.
  - **(3) Through-line remainder.** Through-line = post-dedup events whose `id` was **not** rendered in State now, chronological. Group by `workstream` only when that remainder has **>1** distinct workstream. Empty remainder: keep `## Through-line` and emit `_no events_`. Cold `extract_core` / M7 print MUST use this remainder (MUST NOT print a second copy of State now events).
  - **(4) Appendix remainder.** Kill catalog and Facts = events shown in **neither** State now nor Through-line. Git code-state unchanged. Empty Kill catalog leftover: heading + `_none not already shown above_` when ≥1 `killed` event already rendered in State now or Through-line; heading + `_none_` when the assembled set has zero `killed` events. Leftover `killed` events still list as event lines. Facts heading only when leftover `fact` events exist (MUST NOT emit `_none_` or `_none not already shown above_` under Facts; MUST NOT add a Facts heading when leftover is empty). MUST NOT dual-render “long” kills. MUST NOT emit `### Pointers (courtesy)` (inline `↳` stays). Namespaced event ids MUST NOT appear in packet body.
  - **(5) Footer** with advisory `packet_tokens / stripped_spine_tokens` when stats available.
  - **Single-section (cross-`##`).** After dedup, each event `id` renders in **exactly one** of `## State now` | `## Through-line` | `## appendix`. Precedence: State now → Through-line → appendix.
  - **Packet section order** is fixed: **State now → Through-line → appendix**. Both CDT-198 subsections MUST appear **inside State now** (before Through-line) on **every** packet (cold, warm, and M10c light). Appendix-only placement is a defect. Assemble MUST NOT emit a valid packet missing either heading (fail closed). When the miner supplied no tagged events, assemble MUST still emit both headings with explicit `_unspecified_` placeholders — MUST NOT invent surface names.
  - **Optional summary invent-guard.** Read wrapper `summary` from miner JSON (M3c). Missing / null / empty / non-string → omit the Where we are block; packet remains valid. If `len(summary.strip()) > 800` → omit entire summary + stderr. Split remaining text into sentences on `(?<=[.!?])\s+` (trailing fragment counts). Each sentence MUST contain ≥1 `{<id>}` token matching `\{[^{}\s]+\}`. Each token MUST exact-match a post-dedup assembled `id` (namespaced) **or** that event’s `_raw_id`. Any unknown token or any sentence without a valid token → omit **entire** summary + `assemble:` stderr; packet still valid (all-or-nothing). When valid: render `### Where we are` plus prose with `{id}` tokens stripped (ids MUST NOT appear in the packet body). Assemble MUST NOT invent a root cause. Prompt (not assemble): restate cited events only.
- **M4 — STM packet shape.** The artifact MUST be an **STM packet** / **compact seed** with the fixed order in M3d. Product success is measured by post-`compact @packet` continuity, not inject-density into a blank session. Freeform essay sections and slogan-thin packets (no kills/rulings/facts when thrash existed) are defects. Raw tool dumps in the packet are defects equal to slogan thinness. Omitting **Product surfaces** or **Open ship gaps** from State now is a defect equal to slogan thinness (CDT-198). Dual-rendering the same event `id` across `##` sections is a defect equal to slogan thinness (CDT-201). Emitting `### Pointers (courtesy)` is a defect. `### Where we are` is optional provenance-constrained prose (M3d / M11b), **not** a freeform Convergence essay — omitting it when the summary is invalid or absent is correct, not thinness.
- **M5 — Stated-intent vs git flag (lightweight).** The packet MUST flag mismatches between intentions stated in the transcript and actual git state (as `conflict`/`open` events). Heuristic only — MUST NOT implement adversarial verification; deep audit is `/council` (SPEC-013).
- **M6 — Quotes admissible, dumps not (partial inversion of prior M6).** User `ruling` and `killed` reasons MUST appear **short-verbatim inline** in the packet (≤ ~200 chars; longer → load-bearing clause + summary). For `kind=ruling`, assemble MUST render `text` when non-empty, else `quote` (so a bare pick in `quote` is not the sole body when `text` carries the question). Assemble MUST NOT fail-closed on short or historical rulings. A claim that is only true if a `transcript:L*` pointer resolves is a **defect** (pointers rot on the days–months STM horizon). Pointers (`transcript:L`, `commit:`, `file:`) are **courtesy** drill-downs, never load-bearing. MUST NOT inline raw tool output / `toolUseResult`. MUST NOT emit an appendix pointer **index**; inline `↳` lines remain courtesy.
- **M7 — Cold output (inject core, file full).** In cold mode the command MUST: (a) write the full STM packet to `<target-MROOT>/.claude/handoff/<YYYYMMDD-HHmm>-<session-id>-<slug>.md`; (b) print **State now + Through-line** into the invoking session; (c) **cite the file path** for appendix (do not dump full appendix into the live window). The cited path MUST equal the actual write path. Cold cache-HIT serves (b)+(c) **in-session** (no spawn). Cold MISS on the detached path (M19): the background agent's final report MUST contain the M7 core + path, and the parent MUST relay that report into the invoking session.
- **M7b — Target-session write root (CDT-80).** Packet path, M8 cache, and git appendix MUST resolve from the **target session's project**, never from the invoker's cwd. Cold: after the uuid is located, derive project from transcript `cwd` (preferred) via `skills/handoff/resolve-root.sh`, then `MROOT` via `git rev-parse --git-common-dir` from that cwd (worktree → shared main repo). Warm: same helper on this session's transcript. Non-git target: `HANDOFF_DIR = <project-dir>/.claude/handoff/`; git sections may be empty. If the target root cannot be determined after locate → **fail hard** (no write under invoker cwd). Invoker in repo A with target session in repo B → all artifacts under B. MUST NOT write under `$HOME/.claude/.claude/` when the target project is not `$HOME/.claude`.
- **M8 — Result cache.** Distilled STM packet MUST be cached keyed by `(session uuid + last-message uuid)` and reused until the session grows. Cache MUST live outside `memory.db` under the target `$MROOT/.claude/handoff/cache/`.
- **M8b — Delta-mine re-capture (CDT-88).** Warm re-capture MUST NOT re-mine the full session when a usable prior event set is available from the M8 cache.
  - **Cache `events`:** Cache payload MAY/MUST store a cumulative **`events` stem map** after successful assemble (keys = miner stems such as `through_line`, `state`; values = post-dedup event objects with **raw miner ids**, no stem / no `prior:` prefix). Dual-read soft: absent / null / empty / unreadable `events` → treat as no prior (same soft pattern as `packet`/`brief` dual-read). Cold and full paths SHOULD still **write** `events` on finalize so the next warm re-capture can delta.
  - **Warm delta path:** When warm re-capture finds cache `leaf_uuid` + non-empty `events` and is not full-forced, prepare MUST spine-mine **since** that cached leaf (`--since-leaf` internal/debug only — not user-facing CLI help). Stats (`est_tokens` / spine size) MUST reflect the **delta**, not the full transcript.
  - **Assemble merge:** Assemble MUST merge prior cache events + delta miner files with generation-aware order (prior before delta) and M3d (1) dedup (identical `(kind, normalized body)` first-wins → prior verbatim survives; same-kind prefix across prior+delta keep-longer at the earliest/prior position). Cross-gen ids: prior → `prior:{stem}:{raw_id}`; fresh → `{stem}:{raw_id}` (extends CDT-93 invent-guard). Step 7 annotation summary MUST see the **merged** namespaced event set. Prior events MUST be taken **verbatim** from cache on identical-body matches — no re-paraphrase; prefix-near-dups MAY copy the longer delta body onto the prior event object.
  - **Gen-3 load uniqueness (CDT-94):** `load_prior_events` MUST ensure unique ids within a load. When re-namespacing would yield a duplicate `prior:{stem}:{raw}`, the first event keeps that id; subsequent collisions MUST take `prior:{stem}:{raw}#2`, `#3`, … (suffix on the raw half). MUST emit a non-empty `assemble:` stderr diagnostic per reassignment. Cache `events` schema unchanged; `events_for_cache` MAY still write duplicate raw ids (write-time uniquify OOS).
  - **No packet parse:** MUST NOT recover events by re-parsing packet/brief markdown; events come only from the cache `events` field (or full re-mine).
  - **Full force / fallback:** `/handoff --full` or `HANDOFF_FULL=1` MUST force full prepare/mine (ignore cache events / since-leaf). Any miss (no events, since-leaf not in timeline, prepare fail, empty unusable prior) MUST fall back to full re-mine without crash.
  - **Cold HIT unchanged:** Cold cache-check HIT (leaf match → serve core) MUST remain byte-identical; cold MISS does not auto-apply since-leaf. M10c light preset: see M10c (CDT-91). M8b full path unchanged for bare warm.
- **M9 — Freshness guard (cold).** If the target transcript was modified < 60 s ago, cold `/handoff` MUST warn and decline to parse mid-write (SPEC-012). Default cold path MUST NOT use the mid-write carve-out.
- **M10 — Warm mode (spine-mine self).** Bare `/handoff` MUST spine-mine **this** session's JSONL via the shared engine (not freeform rewrite from live model memory). Warm MAY run an **annotation** pass whose output schema can only reference existing event IDs (`{ event_id, labels[], rank? }`) — MUST NOT invent evidence. Event IDs for invent-guard are the **namespaced** form from assemble load (`{stem}:{raw_id}`, e.g. `through_line:tl-e1`, and `prior:{stem}:{raw_id}` when M8b prior is present), including load-time disambiguation suffixes (`prior:{stem}:{raw}#N` from CDT-94); bare miner ids MUST NOT match (CDT-93). Warm MUST write the packet **file-only** (not print core into the still-live session as primary product). Mid-write read of **this session's** transcript is allowed via a **warm-only** carve-out (M14 pattern): drop truncated last line; fail soft; carve-out MUST NOT be reachable from cold user path. **One-turn lag (CDT-204):** the mined JSONL is as written at parent prepare/spawn time; the `/handoff` turn itself is absent — identical to `--allow-in-progress`. Docs/honesty MAY state this. MUST NOT change the M10c honesty line.
- **M10b — Session-id bridge + honesty (CDT-85 / CDT-92).** Warm discovery MUST resolve a live session id + transcript path for the **host in use** via `skills/handoff/discover-warm.sh`.

  **Host selection:** Explicit Grok env (steps 1–2) wins. Grok cwd-newest (step 3) MUST win over a *stale* Claude bridge or Claude projects-dir tip (CDT-92) but MUST NOT fire when a definitive live-Claude env signal is present (`CLAUDE_CODE_SESSION_ID` or `CLAUDE_SESSION_ID`, or `CLAUDE_TRANSCRIPT_PATH` / `TRANSCRIPT_PATH` pointing at a real non-Grok file) — otherwise dual-host repos silently mine the wrong session. `CLAUDE_CODE_SESSION_ID` is the variable Claude Code actually exports (CDT-104); omitting it made the gate dead in every live Claude session. When only Claude is resolvable, Claude path (CDT-85) is unchanged. When neither resolves → fail clear; MUST NOT freeform-write live-context as warm STM.

  **Grok discovery precedence (when Grok path active):**
  (1) Grok/session env (`GROK_SESSION_ID` / `GROK_TRANSCRIPT_PATH` / non-empty `SESSION_ID` that names a dir under `GROK_SESSIONS_DIR`);
  (2) `CLAUDE_SESSION_ID` / `CLAUDE_TRANSCRIPT_PATH` / `TRANSCRIPT_PATH` **only if** the path is a Grok `chat_history.jsonl` **under** `${GROK_SESSIONS_DIR:-~/.grok/sessions}` (basename alone is insufficient; sid from parent dir of that file);
  (3) newest-mtime `chat_history.jsonl` under `${GROK_SESSIONS_DIR:-~/.grok/sessions}/<urlencode(cwd)>/*/` — **skipped** when live Claude env signal is set;
  (4) else Grok miss (fall through to Claude discovery or hard fail).

  **Claude discovery precedence:** env → bridge → stem → cwd-newest under `CLAUDE_PROJECTS_DIR` (CDT-85), but **skipped** when Grok already resolved via steps 1–2 or ungated step 3. The env leg MUST read `CLAUDE_CODE_SESSION_ID` first, then `CLAUDE_SESSION_ID`, then `SESSION_ID` (CDT-104) — same order as the `ARM_SID` chain in `skills/refactor/SKILL.md`. Grok step (2) intentionally does **not** consult `CLAUDE_CODE_SESSION_ID`: it runs before the live-Claude gate, so admitting the live id there would reopen the hijack this gate closes.

  **Grok normalize:** Before prepare, Grok `chat_history` MUST be adapted to Claude-shaped JSONL (user/assistant `message.role`, synthetic `uuid`, injected `cwd` for M7b resolve-root). Shared spine-mine after prepare is unchanged (M3b).

  On success, warm MUST: (a) write/update a session-id bridge (`.live-session.json` under target handoff dir when resolvable) with the resolved host session id + **source** transcript path (Grok `chat_history` or Claude jsonl) and `host: grok|claude`; (b) emit packet header/footer `mode: warm` and `session: <id>`; (c) use that id in the filename so later cold/re-capture can `Supersedes:` the same session tip. AC-16 human 3/3 MUST NOT be claimed from cold-only dogfood, Grok-only dogfood, or unit fixtures alone; warm thesis still requires Claude Code bare-`/handoff` anti-relitigation (see dogfood runbook).
- **M10c — Light warm preset (CDT-91).** `/handoff --light` is a **warm-only cost preset** over the shared spine-mine pipeline (prepare → miner → assemble). It is **not** freeform live-context and MUST NOT reintroduce a dual path when discover fails (M10 / M10b still apply).

  **MUST:**
  1. Accept `--light` only on warm entry (bare `/handoff` / `--slug` / with other warm flags). Cold `/handoff <uuid> --light` MUST fail with usage.
  2. Keep packet `mode: warm` (two-value contract CDT-85). Carry lightness solely via meta **`light: true`** in header and footer. MUST NOT add a third mode enum value (e.g. `warm-light`).
  3. Run prepare → merged miner → assemble (same engine). Preset knobs:
     - merged miner: `HANDOFF_MINER_MODEL=haiku` when unset by operator **and** `--miner-model` not set (flag wins; M3e);
     - **skip** warm annotation entirely;
     - MAY lower `HANDOFF_SPINE_TOKENS` to **40000** when unset (MUST NOT change the bare-warm code default of **120000**).
  4. Write packet filename with **`-draft`** suffix: `<YYYYMMDD-HHmm>-<session-id>-<slug>-draft.md`.
  5. Emit honesty wording (exact):  
     `light preset: reduced-cost mine, no annotation; not AC-16-scored.`  
     MUST NOT say "UNMINED".
  6. On light finalize: MUST **not** write or overwrite `$HANDOFF_DIR/cache/<session-id>.json` (M8). Session bridge `.live-session.json` MAY still update (M10b).
  7. Include light drafts in `Supersedes` discovery (M11). Later full warm capture MUST be able to `Supersedes:` a prior light draft tip. PreCompact rescues remain excluded.
  8. After light write, surface a completion nudge that bare `/handoff` is needed for AC-16-quality tip + intact delta chain.
  9. Remain host-agnostic (Claude + Grok via existing discover-warm).

  **MUST NOT:**
  1. Write freeform live-context as a light STM packet.
  2. Write M8 cache from light (primary anti-poison path).
  3. Claim AC-16 scoring credit for light packets (runbook exclude).
  4. Change bare `/handoff` defaults (miner inherit, annotation on, spine 120k, cache write on).
  5. Gen-3 collision fix is **CDT-94** (load-time `#N` in `load_prior_events`) — not in M10c scope.

  **SHOULD:**
  1. Defense-in-depth: if a cache entry is ever present with `light: true` or empty events, warm delta gate treats it as no-prior (same soft path as missing events).
  2. Document light as opt-in sugar in `docs/commands/handoff.md` + dogfood runbook cost section.
- **M11 — Filename, slug, Supersedes.** Packet files MUST use `<YYYYMMDD-HHmm>-<session-id>-<slug>.md` under `.claude/handoff/`. Light warm (M10c) MUST append `-draft` before `.md` (`<YYYYMMDD-HHmm>-<session-id>-<slug>-draft.md`). Slug: optional user arg; else sanitized first decision/open text (≤40 chars); else `stm`. When the same session is re-captured, write a **new** file and set header `Supersedes: <prior-filename>` so the living tip is unambiguous (one-file default with versioned names). Light drafts are eligible Supersedes tips (M10c); PreCompact rescues remain excluded.
- **M11b — Unclear landing.** If the session did not land a root cause, the packet MUST NOT invent one. Prefer evidence trail + `open` events; optional `INFERRED` **label** on an existing event via annotation only. Optional miner wrapper `summary` (M3c/M3d) MAY render as State now `### Where we are` only after the invent-guard; invalid or missing summary MUST omit the block (packet still valid). The summary MUST NOT be used to smuggle an invented root cause; id-cite checks are mechanical — annotation remains the only `INFERRED` path. MUST NOT accept an annotation-authored summary.
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

### Detached orchestrator (CDT-204)

Goal: the slash command is a small parent stub. `mode=direct` mines off the parent context. Packet/M8/M8b/light/CDT-80 contracts stay unchanged.

- **M19 — Detached orchestrator.** After parent parse + (warm) discover + resolve-root + cheap gates + **prepare**, the parent MUST read `plan.mode` **before** any skill Read or miner/annotation/chunk spawn.

  **Detached path (`plan.mode=direct`, host can spawn):**
  1. Parent MUST spawn **exactly one** background agent. Spawn prompt MUST tell the agent to **Read** `skills/handoff/LIGHT.md` (`--light`) or `skills/handoff/SKILL.md` (bare / cold / `--full`) **from disk** and execute the remaining pipeline (git capture, miner, optional annotation, finalize).
  2. Parent MUST NOT Read `SKILL.md` or `LIGHT.md`. Parent MUST NOT spawn miner, annotation, or chunk-summarizer Tasks. Parent MUST NOT inline those templates into the stub.
  3. `commands/handoff.md` MUST be ≤ **12000** bytes (CI `wc -c`).
  4. The background agent **IS** the merged miner (INLINE; both event files; one spine read — M3b). On bare warm it **IS** the annotation pass (INLINE after miner). Light/cold skip annotation. The agent MUST NOT nest Task / spawn_subagent for miner, annotation, or chunk-summarizers.
  5. LIGHT/SKILL “command already in context / MUST NOT re-Read command” is inverted for this agent: the agent MUST Read the skill file from disk (it was not injected).
  6. Agent MUST NOT re-run `discover-warm.sh`. Parent already captured live identity.
  7. Spawn payload MUST pass as explicit values (env is not inherited): `SESSION_ID`, `TRANSCRIPT` (prepare-ready path; Grok adapted JSONL under TMPDIR MUST still exist at agent start), `host` when known, `HANDOFF_MODE`, `SLUG`, `HANDOFF_FULL`, `HANDOFF_LIGHT`, `HANDOFF_MINER_MODEL` (alias as given), `HANDOFF_SPINE_TOKENS`, `SKIP_ANNOTATION`, `UUID`, target `HANDOFF_DIR`/`MROOT`/`PROJECT_DIR`, `PLAN_JSON`/`WORK_DIR`/`SPINE`/`EVENTS_DIR`/`PRIOR_EVENTS_FILE` when parent prepared, and the absolute skill path (resolved, not Read). Flags in the payload are the parsed values, not a raw argv replay that the agent re-parses as a second CLI.
  8. `--miner-model` / `HANDOFF_MINER_MODEL` apply to this one agent's `model:` (M3e).
  9. Parent MUST NOT delete `WORK_DIR` / the Grok adapted JSONL until the agent completes (or fails).
  10. Warm completion in the parent: packet path only (plus the M10c light nudge when light). Cold MISS: relay M7 core + path from the agent final report.

  **In-session fallback (locked):** if `plan.mode=chunked` **or** the host cannot spawn a background agent, parent MUST NOT spawn the detached orchestrator. Parent MAY Read the skill file and MUST run today's pipeline: parallel N haiku chunk-summarizers (when chunked) + one miner Task + annotation Task when bare warm. Serialization of the chunk map remains a defect on this path. Fallback is **exempt** from the parent ~3k budget. MUST NOT fail the capture solely because detach was unavailable. No new CLI flag.

  **No-spawn cheap gates (parent, before detach):**
  - Discover miss (warm): script diagnostic, non-zero, no spawn, no freeform packet.
  - `--light` + cold uuid: usage, exit 1, no spawn.
  - `--miner-model` missing value: exact error, exit 1, no spawn.
  - `--slug` missing value: no spawn.
  - `--help` / unknown flag: usage, exit 0, no spawn.
  - Resolve-root fail: fail hard, no spawn, no invoker-cwd write (M7b).
  - Cold uuid-shape invalid / unknown uuid / M9 decline: existing behavior, no spawn.
  - Cold cache HIT: serve M7 in-session, no spawn.

  **Native `agent:` frontmatter:** prefer only if the parent still runs discover (or the agent inherits live session identity) **and** M19 parent-budget (no skill Read on `mode=direct`) holds. Today's `agent: build` does **not** detach. Until a host is proven to honor `agent:` that way, the stub MUST use an explicit one-agent spawn (Claude `Task` / host-equivalent background agent). Host-agnostic.

  **Failure:** agent failure MUST surface in the parent. MUST NOT write a freeform packet from live model memory. MUST NOT write under invoker cwd (M7b).

  **MUST NOT:** new user-facing flags; serial-in-agent chunk map; change packet format, M8/M8b cache, light markers/honesty line, or CDT-80 target-root; unfreeze `prepass.sh` / `assemble.py` / `discover-warm.sh` behavior unless a listed Test 39 assert cannot be met otherwise (default: do not unfreeze).

  **SHOULD:** live parent context growth on `mode=direct` ≤ ~3k tokens (stub + result). CI enforces the 12000-byte command cap, not live tokens.

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
21. **Annotation invent-guard (M10 / CDT-93):** annotation `event_id` must exact-match a namespaced load id (`{stem}:{raw_id}` or `prior:{stem}:{raw_id}`, including CDT-94 `#N` suffixes); unknown or bare miner ids are dropped; no new evidence fields in annotation schema.
22. **Cold print shape (M7):** cold stdout includes State now + Through-line and cites packet path; full appendix not required in stdout.
23. **Target write root (M7b / CDT-80):** cold from non-repo invoker cwd for a known-project session writes under that project's `.claude/handoff/`; cache under its `cache/`; git appendix is target HEAD/status; undetermined root fails with no invoker write; worktree session → shared MROOT; invoker repo A / target B → all under B.
24. **Spawn model tiers (M3e / CDT-90 / CDT-203 / CDT-204):** static contract — in-session chunk (+ annotation Task) spawn text includes `model: haiku`; miner default inherits (no forced haiku without env); **parent stub** not forced haiku; no dated model IDs. CLI `--miner-model` / `--miner-model=` export the alias as given; missing value exit 1 (`error: --miner-model requires a value`) **and no spawn**; `--light` override; flag > env > light > inherit; unknown alias passthrough (not a parse error). Spawn resolution: exact lowercase `fast|balanced|max` via bridge `host` (cold/missing → claude); Claude `fast`→`haiku`, `balanced`→`sonnet`, `max`→omit; Grok identity; else pass-through; host reject → fail-soft inherit. **Detached path:** resolution applies to the **one background agent's** `model:` (retarget Test 24 greps from command Step 6 miner Task to the stub orchestrator-spawn contract + dual-home SKILL/LIGHT). In-session fallback keeps miner Task `model:` as before. Advisory after successful prepare **in the parent**: exact `fast tier is likely sufficient for this mine` vs `keep session tier`; skip on missing/non-numeric/≤0 tokens, prepare fail, or cold cache-HIT. Coverage: `skills/handoff/spawn-model-ac-test.sh` (Test 24), `skills/handoff/light-gates-test.sh` parse cases (Test 31).
25. **Delta-mine stats (M8b / CDT-88):** warm re-capture with cache `events` + grown session → prepare `--since-leaf` plan stats (`est_tokens` / `spine_msgs` / `delta_msgs`) reflect delta only (`<<` full); `full_msgs` / `since_leaf` present when cut applied.
26. **Assemble prior+delta merge (M8b / M3b / CDT-88):** prior cache events + delta miner files → merged packet; identical bodies survive verbatim (prior); cross-gen ids `prior:{stem}:{id}` and `{stem}:{id}`; generation order puts delta after prior for State now tail; dedup identical `(kind, norm body)` first-wins; prefix-near-dups follow M3d (1) keep-longer at earliest/prior position (CDT-202).
27. **Cache events dual-read (M8b / CDT-88):** old cache without `events` (or null/empty/unreadable) → full re-mine, no crash; cache with `events` written on finalize is readable on next warm delta path.
28. **Full force (M8b / CDT-88):** `--full` or `HANDOFF_FULL=1` forces full prepare/mine even when cache has `leaf_uuid` + `events`; cold cache-check HIT path unchanged.
29. **Light warm finalize (M10c / CDT-91):** Light warm finalize writes `*-draft.md` with `mode: warm` + `light: true`; cache file absent or unchanged (byte-identical if pre-existing full entry).
30. **Light does not poison delta (M10c / CDT-91):** Full capture → light re-capture → `cache/$SID.json` byte-identical → next bare warm prepares with `--since-leaf` = full leaf (delta path).
31. **Light gates + bare defaults (M10c / CDT-91):** Cold + `--light` → usage fail; bare warm defaults unchanged when `--light` omitted.
32. **Supersedes light draft (M10c / M11 / CDT-91):** `discover_supersedes`: light draft is eligible tip; full second capture `Supersedes: <draft basename>`; precompact still skipped.
33. **Light cache defense (M10c / CDT-91):** Defense: cache with `light: true` OR empty events → `PRIOR_LEAF` empty (no `--since-leaf`) even if `leaf_uuid` present.
34. **Gen-3 prior id uniqueness (M8b / CDT-94):** cache `events` with two distinct-body rows sharing raw id under one stem → `load_prior_events` yields unique ids (`…:R`, `…:R#2`); stderr non-empty; annotation targeting both final ids applies; multi-hop second load still unique; non-collision + cold paths unchanged.
35. **`CLAUDE_CODE_SESSION_ID` honored (M10b / CDT-104):** `CLAUDE_CODE_SESSION_ID` alone resolves the Claude session; it beats `CLAUDE_SESSION_ID` when both are set; and set alone it blocks Grok cwd-newest (newer Grok tip in the same cwd does not hijack; bridge `host: claude`). Test harness MUST unset `CLAUDE_CODE_SESSION_ID` in its env isolation — the ambient live value otherwise leaks into every fixture case. Coverage: `skills/handoff/discover-warm-test.sh`.
36. **Product surfaces + Open ship gaps (M3d / M4 / CDT-198):** Every assembled packet (cold, warm, `--light`) includes `### Product surfaces` and `### Open ship gaps` inside State now (before Through-line). Fixture that names a primary UX and a non-product surface → both strings appear in State now (not appendix-only); light finalize same. Assemble rejects a packet whose State now lacks either heading. MUST NOT change `/handoff` CLI shape, `##` header order, or the M10c honesty line. Coverage: `skills/handoff/assemble-test.sh` T29–T31, `skills/handoff/light-preset-test.sh` AC4.
37. **Packet quality (M3d / M4 / M6 / M11b / CDT-201):** After M3d (1) dedup, each event `id` appears in exactly one of `## State now` | `## Through-line` | `## appendix`. Fixture: one `open`+`facet=ship_gap` body occurs once in the full packet; that sole render keeps inline `↳` when `pointers[]` exist (including Product surfaces). Through-line is the State now remainder (`_no events_` if empty). Appendix Kill catalog / Facts are leftover only; `### Pointers (courtesy)` absent; namespaced ids do not leak. Wrapper `summary` missing → no `### Where we are`; valid `{id}`-cited summary → heading first in State now with tokens stripped; any unknown token, uncited sentence, non-string, or `strip` length > 800 → omit entire summary + stderr, packet valid. `kind=ruling` renders `text` when non-empty. JSON without `summary` still assembles. CLI, `##` order, M10c honesty, light markers, M8b cache schema unchanged. SHOULD: event-rendered markdown (exclude git blob + header/footer) on a duplication fixture ≤ 50% of pre-change dual-render (advisory, not fail-closed). Coverage: `skills/handoff/assemble-quality-test.sh`; `skills/handoff/assemble-test.sh` T2 (kill-quote count 1) + T17 (no Pointers heading); SKILL.md + LIGHT.md static ruling/facet examples.
38. **Prefix-collapse + leftover Kill placeholder (M3d / M8b / CDT-202):** After exact `(kind, normalized body)` first-wins, same-kind strict prefix-collapse (≥40 punct-stripped shorter; keep longer body; earliest `id`/facet/position) then `open`/`conflict` cross-kind drop (keep open, drop matching conflict, one `assemble:` stderr). Empty Kill catalog leftover with ≥1 `killed` already shown → exactly `_none not already shown above_`; zero `killed` in the assembled set → exactly `_none_`. Facts heading still omit-when-empty (MUST NOT emit `_none_`). Coverage: `skills/handoff/assemble-quality-test.sh` (Test 38); `assemble-test.sh` T2/T12/T23 unchanged; `light-static-test.sh` T11 conflict/open dual-home (AC9). Live recapture is SHOULD (QA), not CI.
39. **Detached orchestrator (M19 / CDT-204):** `wc -c commands/handoff.md` ≤ 12000. Stub (`mode=direct`) path: no required Read of `SKILL.md`/`LIGHT.md`; no nested miner/annotation/chunk Task in the stub. Spawn payload carries `SESSION_ID`, `TRANSCRIPT`, parsed flags as explicit values (`--light`/`--full`/`--slug`/`--miner-model` alias as given). Discover miss / parse fail / resolve-root fail / `--help` / cheap gates: no spawn, no freeform. `plan.mode=chunked` or host cannot spawn → in-session fallback (parallel N haiku map; parent MAY Read skill). Detached agent IS the miner (INLINE, one spine read) and IS annotation on bare warm (INLINE); MUST NOT nest Task. Agent MUST NOT re-run discover. M3e `model:` on the one background agent. Cold HIT in-session; cold MISS relays M7 from agent report. Same miner-event fixture through detached finalize vs current finalize → byte-identical modulo timestamp/filename. Existing engine suites unweakened. Command-static tests MAY retarget to stub + skill homes; MUST NOT drop coverage. Light honesty string unchanged. Coverage: `skills/handoff/detached-stub-test.sh`; `skills/handoff/detached-packet-test.sh`; retargeted `spawn-model-ac-test.sh` (Test 24); `light-gates-test.sh` parse (Test 31). Live parent growth ≤ ~3k is SHOULD (QA), not CI.

**Human ship gate (CDT-79 AC-16 — not CI):** ≥3 re-captures under new contract (≥2 long-debug: multi-hypothesis thrash with kills; ≥1 multi-week: ≥2 calendar weeks or multi-child program arc); after compact `@packet`, next session does not re-propose packet-resident kills/rulings; human 3/3. Light packets (M10c) are excluded from AC-16 scoring.

---

## Validation

- [ ] Cold retroactive handoff produces STM packet file + core print
- [ ] Warm spine-mines live JSONL (no freeform dual path)
- [ ] Shared engine: 1 merged miner + git + LLM-free assemble
- [ ] State now mechanical; quotes inline; no tool dumps
- [ ] State now includes Product surfaces + Open ship gaps (cold/warm/light); assemble refuses packets missing either heading
- [ ] Single-section event render; no Pointers index; optional Where we are omit-on-invalid (CDT-201)
- [ ] Cache outside memory.db; M9 cold; warm mid-write carve-out scoped
- [ ] Supersedes on re-capture; timestamped filenames
- [ ] PreCompact still spine rescue only; fail-open
- [ ] Docs: compact seed framing; no Linear dual-write; no compact-replacement claim
- [ ] Internal legacy inject-brief / multi-extractor references swept from SPEC, skill, command, docs, tests
- [ ] Spawn model tiers (M3e): in-session chunk + annotation Task `model: haiku`; miner inherits session unless `HANDOFF_MINER_MODEL` / `--miner-model`; canonical `fast|balanced|max` resolve at miner-actor spawn (detached = background agent `model:`); parent stub session tier; `HANDOFF_SPINE_TOKENS` default 120000
- [ ] M10c light: warm-only, no cache write, markers, supersedes draft, defense gates
- [ ] Detached orchestrator (M19): stub ≤12000 bytes; parent prepare then branch on `plan.mode`; `mode=direct` one background agent Reads skill from disk, IS miner (+ annotation if bare warm), no nested Task; chunked / no-spawn-host → in-session parallel map; discover-before-delegate; no new flags; engines frozen

---

## Version History

| Date | Change |
|------|--------|
| 2026-08-21 | **CDT-204:** M19 detached orchestrator — parent stub parse/discover/prepare then `plan.mode` branch; `mode=direct` one background agent Reads skill from disk and IS the miner (INLINE) + bare-warm annotation (INLINE); chunked / host-cannot-spawn → in-session parallel N haiku map (locked); `--miner-model` applies to the one agent `model:`; command ≤12000 bytes; one-turn lag honesty; Test 39; Test 24 retarget |
| 2026-08-21 | **CDT-203:** M3e CLI `--miner-model`; host-neutral `fast\|balanced\|max` resolve at spawn (Claude map; Grok identity; `max`→inherit); passthrough + fail-soft; advisory after prepare; flag > env > light > inherit; Test 24/31 |
| 2026-08-21 | **CDT-202:** M3d (1) exact first-wins then same-kind prefix-collapse (≥40) then open/conflict cross-kind drop; M3d (4) leftover Kill catalog `_none not already shown above_` vs `_none_`; M8b prefix keep-longer at prior position; Test 38 |
| 2026-08-20 | **CDT-201:** M3d single-section remainder assemble; drop Pointers index; optional provenance-constrained `### Where we are` (wrapper `summary` + invent-guard, M11b); M6 ruling prefers `text`; M3b miner-prompt ruling-context + product_surface negatives; Test 37 |
| 2026-08-16 | **CDT-198:** M3c optional `facet`/`surface_class` (kind ceiling stays 7); M3d/M4 require **Product surfaces** + **Open ship gaps** inside State now on every packet including M10c light; assemble fail-closed if headings missing; Test 36 |
| 2026-08-01 | **CDT-104:** M10b warm discover reads `CLAUDE_CODE_SESSION_ID` (preferred over `CLAUDE_SESSION_ID` / `SESSION_ID`) in both the live-Claude gate and the Claude session-id chain — the CDT-92 anti-hijack gate was dead in live Claude sessions. Grok step (2) unchanged by design. Test 35 |
| 2026-07-28 | **CDT-94:** gen-3 `load_prior_events` id collision — `#2`/`#3` raw-half suffix + stderr; cache schema unchanged; Test 34. Patch 1.1.8 |
| 2026-07-27 | **CDT-91:** M10c light warm preset — haiku miner + no annotation + optional spine 40k; `light: true` meta; `-draft` file; **no M8 cache write**; Supersedes includes drafts; AC-16 exclude; patch 1.1.7. Tests 29–33 |
| 2026-07-27 | **CDT-88:** M8b delta-mine re-capture — cache `events` stem map; warm spine since cached leaf when events present; assemble prior+delta merge (generation order + existing dedup); full fallback; no packet parse; `--full`/`HANDOFF_FULL`; cold HIT unchanged. M3b amend: miner MAY take delta spine; still one merged miner; assemble sole merge SoT. Tests 25–28. M10c light preset claimed under CDT-91 |
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
