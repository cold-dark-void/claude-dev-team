# /handoff

Session handoff (SPEC-018, CDT-79). Produces one **STM packet** (short-term
working memory / **compact seed**): a noise-stripped, jury-style evidence
artifact so a fresh or post-compact session continues from outcomes, kills,
and user rulings without re-litigating dead ends.

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

| Flag | Effect |
|------|--------|
| `--full` | Warm: force a full spine re-mine, ignoring the M8 cache delta path (also `HANDOFF_FULL=1`). Use after a suspect packet or cache corruption. |
| `--light` | Warm-only reduced-cost preset: `HANDOFF_MINER_MODEL=haiku` + `HANDOFF_SPINE_TOKENS=40000` (when unset), skips annotation, writes a `-draft` packet, no M8 cache write. Cold + `--light` is a usage error. Honesty line: `light preset: reduced-cost mine, no annotation; not AC-16-scored.` |
| `--miner-model` | Pin the miner actor to a host-neutral tier or passthrough alias. Does not skip annotation, change the M8 cache, or change `HANDOFF_SPINE_TOKENS`. |

## Modes

| Mode | Invocation | What it does |
|------|------------|--------------|
| **Cold** | `/handoff <session-uuid> [slug]` | Spine-mines that past session; writes the full STM packet; **prints State now + Through-line** and cites the packet path (M7). Cache hit serves core + path without re-mine (M8) — terminal line `(served from cache — session unchanged)`. |
| **Warm** | bare `/handoff` or `/handoff --slug <s>` | Spine-mines **this** session's live JSONL via the same engine; **writes packet file only** (M10). Works on Claude Code and Grok (dual-host discover). **Re-capture** delta-mines since the last cached leaf (M8b) — miner tokens scale with growth since last capture. A session `in-progress (transcript modified < 60 s ago) — too-fresh (M9)` is refused. |

## Pipeline cost knobs

| Env | Default | Role |
|-----|---------|------|
| `HANDOFF_SPINE_TOKENS` | `120000` | Token budget for a single spine before chunking |
| `HANDOFF_MINER_MODEL` | *(empty)* | Opt-in miner tier; empty = session inherit |

Over budget → `mode=chunked` (in-session fallback: map step + reduced spine);
under budget → `mode=direct` (detach: one background agent mines the raw
spine). Lowering the budget compounds savings with cheap chunk-summarizers but
raises recall risk — the shipped default stays `120000`. The dogfooded AC-16
ship-gate evidence lives in
[docs/internal/handoff-stm-dogfood.md](../internal/handoff-stm-dogfood.md).

## Examples

**Reconstruct a past session (cold):**

```
/handoff 00000000-0000-4000-8000-000000000004
```

**Mid-session snapshot (warm, cheap):**

```
/handoff --light --slug pre-refactor
```

**Re-capture after more work (warm delta):**

```
/handoff --slug pre-refactor
```

## See also

- [`/compact-transcript`](compact-transcript.md) — bounded Meaning tail for you to `@` (separate Surface)
- [`/recall`](recall.md) — find a past session's uuid to hand off
- [Transcript mirror](transcript-mirror.md) — opt-in `main.md`; `/handoff` MAY consume it when `--check` is `ok` (M3f)
- [`/retro`](retro.md) — shares the same read-only transcript parsing seam (SPEC-012)
- [`/council`](council.md) — owns deep adversarial claim verification; handoff's intent-vs-git flag is only a lightweight heuristic
- [`/orchestrate`](orchestrate.md) — long-running flow whose session you might later hand off
- `skills/handoff/SKILL.md` + `specs/core/SPEC-018-handoff-stm-packets.md` — protocol and contract
