# /handoff

Session handoff (SPEC-018, CDT-79). Produces one **STM packet** (short-term
working memory / **compact seed**): a noise-stripped, jury-style evidence
artifact so a fresh or post-compact session continues from outcomes, kills, and
user rulings without re-litigating dead ends.

Packet section order is fixed: **State now → Through-line → appendix**.

**Primary consumer loop:**

```
long session → /handoff → /branch|/fork → /compact @packet-file
```

This is a **compact seed**, not a replacement for `/compact`. Not a Linear
dual-write.

## Usage

```
/handoff <session-uuid> [slug]
/handoff [--slug <slug>]
/handoff --full [--slug <slug>]
/handoff --light [--slug <slug>]
/handoff --miner-model <fast|balanced|max|alias>
/handoff --help
```

Slug is optional (second positional or `--slug`); sanitized to `[a-z0-9-]+`;
default `stm`.

**`--full`** (warm): force a full spine re-mine, ignoring the M8 cache delta path.
Equivalent to `HANDOFF_FULL=1`. Use when you want a clean full capture after a
suspect packet or cache corruption. Cold already re-mines on cache miss; `--full`
is primarily a warm re-capture control.

**`--light`** (warm-only, M10c): reduced-cost mid-session snapshot over the **same**
spine-mine pipeline (prepare → miner → assemble) — not freeform live-context.
Cold + `--light` is a usage error. Packet stays `mode: warm` with meta
`light: true`; filename gets a `-draft` suffix; **no** M8 cache write (so a light
capture cannot poison the next full delta). Honesty line (exact):
`light preset: reduced-cost mine, no annotation; not AC-16-scored.`
Host-agnostic: same dual-host discover as bare warm (Claude + Grok). See
[Light preset](#light-preset-m10c) and [cost knobs](#spawn-model-tiers-m3e--cdt-90).

**`--miner-model`** (M3e / CDT-203 / CDT-204): pin the miner actor to a
host-neutral tier or a passthrough alias. On default `plan.mode=direct` this
is the **one background agent's** `model:`. On in-session fallback it is the
miner Task. Combine with `--light`, `--full`, or a cold uuid. Not a third
mode. Does not skip annotation, change M8 cache, or change
`HANDOFF_SPINE_TOKENS`. No new detach flag — detach is the default when the
spine fits. See [Spawn model tiers](#spawn-model-tiers-m3e--cdt-90).

## Modes

| Mode | Invocation | What it does |
|------|------------|--------------|
| **Cold** | `/handoff <session-uuid> [slug]` | Spine-mines that past session; writes the full STM packet; **prints State now + Through-line** and **cites the packet path** for appendix (M7). Cache hit serves core + path without re-mine (M8). |
| **Warm** | bare `/handoff` or `/handoff --slug <s>` | Spine-mines **this** session's live JSONL via the same engine; **writes packet file only** (M10). Packet header includes `mode: warm` + `session: <id>` (CDT-85 / CDT-92 bridge). Not printed as primary product — you are still in the session. Works on **Claude Code and Grok** (dual-host discover). Neither host resolvable → clear fail (no freeform live-context dual path). **Re-capture** delta-mines since the last cached leaf when cumulative events exist (M8b) — miner tokens scale with growth since last capture, not full session length. |
| **Warm full** | `/handoff --full` | Same as warm, but force full re-mine (no delta). Also `HANDOFF_FULL=1`. |
| **Warm light** | `/handoff --light` | **Light preset (M10c):** warm-only cost sugar on the shared spine-mine (still mines). When `--miner-model` and operator env are unset: miner `haiku`, skip annotation, spine budget `40000`. Writes `*-draft.md` with `light: true`; **no** M8 cache write; not AC-16-scored. Host-agnostic (Claude + Grok via existing discover). Run bare `/handoff` before session end for a full tip + delta chain. |
| **Help** | `/handoff --help` | Prints usage and exits. Any unknown flag prints usage too. |

### Detached orchestrator (M19)

Parent stub: parse → (warm) `discover-warm.sh` → resolve-root → cheap gates →
**prepare** → read `plan.mode` **then** branch. **No new CLI flag.**

| `plan.mode` / host | Path | Parent skill Read | Miner |
|--------------------|------|-------------------|-------|
| `direct` + can spawn | **Detach** (default) | MUST NOT | One background agent IS the miner (INLINE). `--miner-model` is this agent's `model:`. |
| `chunked` | **In-session fallback** | MAY | Parallel N haiku chunks + one miner Task |
| host cannot spawn | same in-session fallback | MAY | Same pipeline; MUST NOT fail the capture |

Detach is **one-turn lag:** the mined JSONL is as written at parent
prepare/spawn time. The `/handoff` turn itself is absent — same as
`--allow-in-progress`.

**Cold HIT:** serve State now + Through-line + path **in-session** (no spawn).
**Cold MISS:** the background agent's final report contains the M7 core + path;
the parent **relays** that report into the invoking session.

The parent stub stays at **session tier**. On `mode=direct` the parent does not
load `SKILL.md` / `LIGHT.md`; the detached agent Reads the skill from disk.

The `<session-uuid>` is a UUID like `00000000-0000-4000-8000-000000000004` — one
surfaced by [`/recall`](./recall.md) or visible in a transcript filename.

### Warm discover — Grok vs Claude (CDT-92)

Bare `/handoff` resolves the live host via `skills/handoff/discover-warm.sh`
(command fence stays thin — no host branch after discover):

| Host | Session id | Transcript for prepare | Bridge `host` |
|------|------------|------------------------|---------------|
| **Grok** | Grok session id | Claude-shaped **adapted** JSONL under `${TMPDIR}` (from raw `chat_history.jsonl`) | `grok` (bridge stores **source** `chat_history` path) |
| **Claude** | Claude session id | live `*.jsonl` under projects dir | `claude` |

**Host selection:**

1. **Explicit Grok env** wins over Claude.
2. **Grok cwd-newest** wins over a *stale* Claude bridge, but **yields** when
   live Claude env is set (`CLAUDE_CODE_SESSION_ID` / `CLAUDE_SESSION_ID` /
   non-Grok `*_TRANSCRIPT_PATH`) — so dual-host repos do not mine the wrong
   session.
3. Else **Claude** (CDT-85 env → bridge → stem → cwd-newest).
4. Else **fail hard** (clear diagnostic; no freeform warm STM).

**Grok env** (optional; defaults: cwd + `~/.grok/sessions`):
`GROK_SESSION_ID`, `GROK_TRANSCRIPT_PATH`, `GROK_SESSIONS_DIR`, `GROK_CWD`.

Shared spine-mine after prepare is unchanged (M3b). Packet still lands under
the **target** project MROOT (CDT-80).

### The STM packet

Both modes produce the same packet shape, fixed order:

| Section | Contents |
|---------|----------|
| **State now** | May lead with optional provenance-constrained `### Where we are` (omit when the miner `summary` is missing or invalid). Then mechanical selection from the **tail** of the event log: **Product surfaces** (primary UX + unfinished / do-not-treat-as-product), **Open ship gaps**, latest decisions, surviving unkilled hypotheses, all opens. Not a freeform essay. Both Product surfaces and Open ship gaps are required in this core (appendix-only is a defect). |
| **Through-line** | Remainder after State now occupancy (hypothesis / killed / ruling / decision / fact). Group by `workstream` only when that remainder has more than one workstream. Empty remainder keeps the heading and emits `_no events_`. Short-verbatim user rulings and kill reasons inline (M6). |
| **appendix** | Leftover kill catalog and facts (events shown in neither State now nor Through-line), deterministic git code-state. No `### Pointers (courtesy)` heading. Inline `↳` stays. |

Product success is measured by post-`/compact @packet` continuity — not by how
much text is dumped into a blank session.

- Quotes and kill reasons are **load-bearing** when short; raw tool dumps are
  defects (M6).
- Pointers (`transcript:L*`, `commit:`, `file:`) are **courtesy** drill-downs
  (inline `↳` on event bullets). Never required to understand a claim.
- Stated-intent vs git mismatches surface as lightweight `conflict`/`open`
  events (M5) — deep audit is [`/council`](./council.md).

Packet files live under the **target session project's** `.claude/handoff/`
(not the invoker's cwd — CDT-80):

```
<target-MROOT>/.claude/handoff/<YYYYMMDD-HHmm>-<session-id>-<slug>.md
```

- **Cold** `/handoff <uuid>` resolves the project from the located transcript
  (session `cwd`, then git-common-dir). Invoking from `~/.claude` or `/tmp`
  still writes under the target repo (e.g. `…/claude-dev-team/.claude/handoff/`),
  never `~/.claude/.claude/handoff/`.
- **Warm** bare `/handoff` uses this live session's project MROOT.
- Worktree sessions share the main repo MROOT via `git-common-dir`.
- Non-git target: `HANDOFF_DIR = <project-dir>/.claude/handoff/`; git appendix
  may be empty. If the target root cannot be determined → fail hard (no invoker
  write).

Re-capturing the same session writes a **new** file with `Supersedes: <prior>`
(M11). Cache for cold re-invokes and warm delta-mine lives under
`$MROOT/.claude/handoff/cache/` (outside `memory.db`). Printed packet path must
match the actual write path.

### Warm re-capture cost (M8b)

Without delta-mine, every warm re-capture re-mines the **full** session spine
(~session-length tokens × capture count). With M8b:

- Cache stores cumulative `events` (stem-grouped) alongside `leaf_uuid`.
- Next warm bare `/handoff` auto spine-mines **only messages after** that leaf
  when `events` are present; assemble merges prior + delta (prior survives
  verbatim).
- Miner / map cost tracks **delta size**, not full history.
- Old caches without `events`, missing leaf, or `/handoff --full` → full re-mine
  (safe fallback). Cold path is unchanged (no auto delta; may still **write**
  `events` so the next warm can delta).
- **Light** (`--light`) may **read** a prior full cache for delta-mine but
  **never writes** `cache/$SID.json`, so it cannot poison the next full warm's
  leaf. Mid-session cheap snapshots: `/handoff --light`; end-of-session tip:
  bare `/handoff`.

### Light preset (M10c)

`/handoff --light [--slug <s>]` is **preset sugar only** over the shared
spine-mine pipeline — same stages as bare warm, retuned cost knobs. It is
**not** a freeform live-context path and does **not** add a third `mode` enum
value (`mode` stays `warm`; lightness is `light: true` only).

| Knob | Light (when env unset) | Bare warm default |
|------|------------------------|-------------------|
| `HANDOFF_MINER_MODEL` | `haiku` | empty → session inherit |
| Annotation (bare warm) | **skipped** | INLINE on detach; haiku Task on fallback |
| `HANDOFF_SPINE_TOKENS` | `40000` | `120000` |
| M8 cache write | **skipped** | write `cache/$SID.json` |
| Packet path | `…-<slug>-draft.md` | `…-<slug>.md` |

The light miner default stays `haiku`. `--miner-model` overrides it (flag
exports into `HANDOFF_MINER_MODEL` before the preset fills). Precedence:
**flag > operator env > light preset > inherit**. Honesty wording is
exact: `light preset: reduced-cost mine, no annotation; not AC-16-scored.`
Do not treat light packets as AC-16-scored product (see the
[dogfood runbook](../runbooks/handoff-stm-dogfood.md)). Host-agnostic — Claude
and Grok both resolve via existing warm discover; no host-specific light path.

### How the pipeline works

Cold and warm share one **spine-mine** engine after prepare (they differ only
in entry, exit, warm-only annotation, and M8b warm delta). Parent always does
parse + (warm) discover + resolve-root + cheap gates + prepare, then branches
on `plan.mode`:

1. **Cache check (cold)** — unchanged session → serve cached core + path
   **in-session** (M8). No spawn.
2. **Pre-pass** — deterministic, LLM-free: locate canonical transcript via
   shared [transcript-parse](../../skills/transcript-parse/SKILL.md), dedup
   fork copies, strip raw tool output, size-decide (M1, M2). Cold declines
   transcripts modified < 60 s ago (M9). Warm may read mid-write via a
   warm-only carve-out (M14). Warm re-capture may cut the spine after the
   cached leaf (M8b; internal `--since-leaf` — not a user flag).
3. **`plan.mode=direct` (default, host can spawn)** — one background agent.
   Parent MUST NOT Read SKILL/LIGHT. Agent IS the miner (INLINE, one spine
   read) and IS annotation on bare warm. Agent MUST NOT nest Task.
   `--miner-model` applies to this agent. Cold MISS: agent reports M7 core +
   path; parent relays it. Warm: path only (+ light nudge).
4. **`plan.mode=chunked` or spawn unavailable** — in-session fallback.
   Parent MAY Read the skill. Parallel N haiku chunk-summarizers (one
   tool-use block) + one miner Task + annotation Task if bare warm +
   finalize. MUST NOT fail the capture because detach was unavailable.
5. **Assemble (LLM-free)** — merge prior + delta events into **State now →
   Through-line → appendix**; write packet + cache `events` for next warm.
   Cold prints core + path (HIT in-session; MISS via agent relay); warm
   prints path only.

Code-state is **git only** — no LLM miner (M3b). Delta path mines only
post-leaf messages.

### Transcript mirror (M3f)

When `transcript-sync --check --sid` reports `status=ok`, prepare MAY mine
stripped `main.md`. `main.md` is not a compact seed. See
[Transcript mirror](./transcript-mirror.md). Fork, applied delta, `--full`,
and lag (or missing / in-progress) use JSONL. No new `/handoff` flags.

### Spawn model tiers (M3e / CDT-90)

LLM fan-out uses **tier aliases only** (`haiku` / `sonnet` / `opus` style) — never
dated model IDs. Parent stub stays at **session tier**.

| Stage | Model | Notes |
|-------|-------|--------|
| Chunk-summarizer (map step) | **`haiku`** | **In-session fallback only** (`mode=chunked` or spawn unavailable). N Tasks in one block. Detached agent never runs this. |
| Merged miner (in-session fallback) | **inherit session** | Omit `model` by default (one Task, one spine read). `--miner-model` applies here on this path. |
| Annotation (in-session, bare warm) | **`haiku`** | Labels/rank only; no new evidence. Light/cold skip. |
| Parent stub | **session** | Parse / discover / prepare / branch. Never force haiku. MUST NOT Read SKILL on `mode=direct`. |
| Detached orchestrator agent | miner tier (`HANDOFF_MINER_MODEL`) | Default `mode=direct`. IS miner (+ annotation if bare warm). `--miner-model` is this agent's `model:`. |

**Miner opt-in (CDT-203 / CDT-204):** `/handoff --miner-model <fast|balanced|max|alias>`
exports the alias as given into `HANDOFF_MINER_MODEL`. On `mode=direct` this
pins the **one background agent's** `model:`. On in-session fallback it pins
the miner Task. You may still set the env directly. Empty/unset with no flag →
inherit the session model. The flag does not retarget chunk-summarizer or
annotation (those stay `haiku` on fallback).

**Precedence:** **flag > operator env > light preset > inherit**.

Canonical aliases are exact lowercase only. Resolve at spawn from session-bridge
`host: grok|claude`. Cold / missing / unknown host uses the Claude column.

| Canonical | Claude | Grok |
|-----------|--------|------|
| `fast` | `haiku` | `fast` (identity) |
| `balanced` | `sonnet` | `balanced` (identity) |
| `max` | inherit (omit `model`) | inherit (omit `model`) |

`max` is inherit, never opus. Want opus → `--miner-model opus` (passthrough).
Any other non-empty value (`haiku`/`sonnet`/`opus`, mixed case, unknown) passes
through as Task `model:` as-is. Host reject → omit `model` (fail-soft inherit).
Unknown alias is not a parse error. Do **not** pin dated IDs (`claude-*-20YY`,
`grok-4.x`, `spark-llama`).

**Advisory (print-only):** after a successful prepare, the command prints one
stdout line from `plan.mode` + `stats.est_tokens`. It does not mutate
`HANDOFF_MINER_MODEL`. Exact lines:

- `fast tier is likely sufficient for this mine` when `mode==direct` AND
  `est_tokens` < 30000
- `keep session tier` when chunked OR (`mode==direct` AND `est_tokens` >= 30000)

No line when: prepare fail / no `plan.json` / missing, non-numeric, or ≤0
tokens / cold cache-HIT (no prepare). Prints even if `--miner-model` is already
set.

### Spine budget (`HANDOFF_SPINE_TOKENS`)

`prepass.sh prepare` size-decides against `HANDOFF_SPINE_TOKENS` (default
**120000**). Over budget → `mode=chunked` (**in-session fallback**: map step +
reduced spine for the miner). Under budget → `mode=direct` (**detach**: one
background agent mines the raw spine).

| Env | Default | Role |
|-----|---------|------|
| `HANDOFF_SPINE_TOKENS` | `120000` | Token budget for a single spine before chunking |
| `HANDOFF_MINER_MODEL` | *(empty)* | Opt-in miner tier; empty = session inherit; `--miner-model` exports into it |

**Cost knobs summary:** bare warm inherits the table above. **`--light`** is the
opt-in reduced-cost preset ([Light preset](#light-preset-m10c)): sets
`HANDOFF_MINER_MODEL=haiku` and `HANDOFF_SPINE_TOKENS=40000` when those env vars
are unset and `--miner-model` is omitted, skips annotation, writes a `-draft`
packet, and skips M8 cache write.
Bare-warm defaults are unchanged when `--light` is omitted.

**Tradeoff:** lowering `HANDOFF_SPINE_TOKENS` compounds cost savings with the
cheap (`haiku`) chunk-summarizers — more sessions go map/reduce instead of one
full-spine miner read. That also raises **recall risk** (map step can drop
load-bearing hyp/kill/ruling material). **Measure packet quality before adopting
a lower budget** (dogfood anti-relitigation / kill catalog completeness). The
shipped code default stays **120000** — do not lower it in-repo without evidence.
Light's optional `40000` is preset-only (operator env honored; bare warm stays
120k).

## Examples

**Reconstruct a past session (cold):**
```
/handoff 00000000-0000-4000-8000-000000000004
```
On cache MISS the parent relays M7 (State now + Through-line + path) from
the background agent. Expected shape (abridged):
```
## State now
### Product surfaces
- **primary**: cache CLI
- **unfinished / do-not-treat-as-product**: _unspecified_
### Open ship gaps
- **open**: confirm pool stats under load
### Decisions
- **decision**: Fix TOCTOU race in `cache.go:Get` (not the mutex)
### Open
- **open**: confirm pool stats under load

## Through-line
- hypothesis: lock contention in the pool
- killed: pprof showed no blocking — "no, it's not the mutex, we already ruled that out"
- decision: race is TOCTOU in Get; fix landed

Full packet: .claude/handoff/20260723-1410-00000000-0000-4000-8000-000000000004-stm.md
```

**Serve from cache (re-invoking on an unchanged session):** cache HIT is
in-session (no background agent).
```
/handoff 00000000-0000-4000-8000-000000000004
```
```
(served from cache — session unchanged since last handoff)
## State now
...
```

**Capture the current live session (warm):**

```
/handoff
```

**Warm re-capture (delta when cache has events):** bare `/handoff` again after
more work — miner sees only growth since last capture. Force full:

```
/handoff --full
```

**Cheap mid-session snapshot (warm light):**

```
/handoff --light
```
```
Light handoff written → /home/you/project/.claude/handoff/20260723-1422-abcd1234-stm-draft.md
Note: light preset (not AC-16-scored). Run bare /handoff before session end for a full tip + delta chain.
```

**Pin the merged miner (any mode):**

```
/handoff --miner-model fast
/handoff --light --miner-model balanced
/handoff --full --miner-model max
/handoff 00000000-0000-4000-8000-000000000004 --miner-model fast
```

`--miner-model max` inherits the session model (omit `model`). Other aliases
passthrough as given. Combine with `--light`, `--full`, or a cold uuid.

**Capture the current live session with a slug (warm):**
```
/handoff --slug cache-race-fix
```
```
Warm handoff written → /home/you/project/.claude/handoff/20260723-1422-abcd1234-cache-race-fix.md
```

Typical next step after warm:
```
/branch
/compact @.claude/handoff/20260723-1422-abcd1234-cache-race-fix.md
```

**In-progress session is declined (cold freshness guard):**
```
/handoff 00000000-0000-4000-8000-000000000004
```
```
That session looks in-progress (its transcript was modified < 60 s ago). To avoid
producing a partial handoff, /handoff declines to parse it mid-write. Try again
once the session has settled (≥ 60 s idle).
```

## Rescue artifacts (PreCompact)

Before any compaction (manual `/compact` or auto), a `PreCompact` hook can capture a
deterministic, LLM-free **rescue artifact** so context loss is not permanent
(SPEC-018 M12–M18).

| What | Detail |
|------|--------|
| **When** | `PreCompact` fires for both manual and auto compaction (matcher-less registration) |
| **Writes** | `<repo>/.claude/handoff/<session-id>-precompact-<seq>.md` — spine snapshot + `[L<n>]` drill-down pointers |
| **Not** | An STM packet (State now / Through-line / appendix quality needs spine-mine; cold `/handoff <uuid>` remains the quality path) |
| **Surfacing** | `PostCompact` / `SessionStart` print a one-line pointer (path + `/handoff <uuid>` suggestion); SessionStart consumes the marker; body is never dumped into context |
| **Retention** | Keep newest N per session (default 3, env `HANDOFF_PRECOMPACT_MAX_PER_SESSION`); only `*-precompact-*.md` — STM packets and M8 cache are untouched |
| **Fail-open** | Capture failure → one stderr line + exit 0; never blocks compaction (never exit 2) |
| **Timeout** | Soft prepare timeout default 30 s (`HANDOFF_PRECOMPACT_TIMEOUT`); spine tail-cap default 2 MB (`HANDOFF_PRECOMPACT_SPINE_BYTES`) |

**Recovery:** after compaction (or on the next session start) follow the pointer and run
`/handoff <session-id>` for the full STM packet. Artifacts are machine-local (gitignored under
`.claude/handoff/`). If hooks are unregistered or the Claude Code version lacks
`PreCompact`/`PostCompact`, cold + warm `/handoff` behave exactly as before (graceful
absence). Wire hooks via `/setup orchestration` (init-orch templates are SoT;
`check-hook-templates` is template-hygiene only — dual-copy retired CDT-54;
live `settings.json` is machine-local).

## See Also

- [`/recall`](./recall.md) — find a past session's uuid to hand off (cross-session discovery)
- [Transcript mirror](./transcript-mirror.md) — opt-in `main.md`; `/handoff` MAY consume it when `--check` is `ok` (M3f)
- [`/retro`](./retro.md) — shares the same read-only transcript parsing seam (SPEC-012)
- [`/council`](./council.md) — owns deep adversarial claim verification; handoff's intent-vs-git flag is only a lightweight heuristic
- [`/orchestrate`](./orchestrate.md) — long-running flow whose session you might later hand off
