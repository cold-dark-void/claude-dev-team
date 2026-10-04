# /bug-hunt

Unknown-defect discovery: multi-perspective discover → continuous
refute/confirm → user-visible **confirmed-actionable** report → findings plan +
proceed-gated **bh-quality** backlog materialize → severity-band **phase
handoff emit-only**. Stages **1–4**. Composes the SPEC-013 blind-review path,
the investigator pattern, and SPEC-009 programmatic write-back — does **not**
fix code or **invoke** `/orchestrate` / `/epic` (stage 4 prints route hints
only).

Use `/bug-hunt` when you do **not** already have a bug premise. Prefer
[`/debug`](debug.md) / `/debug ticket` for a known defect, and
[`/council --blind`](council.md) for a one-shot blind review without a hunt
report, severity floor, materialize path, or phase handoff.

## Usage

```
# Continuous (discover → refute → report → plan → optional materialize → phase handoff):
/bug-hunt [path] [--severity-floor critical|warning|nitpick] [--proceed] [--start-phase <n>]

# Resume materialize (fresh session or re-run — no re-S1/S2):
/bug-hunt materialize <report|json|plan-path> [--severity-floor critical|warning|nitpick] [--proceed]

# Resume phase handoff (post-S3 plan; emit-only — no re-S1–S3 invent):
/bug-hunt handoff <plan-path> [--start-phase <n>]
```

## Arguments

| Arg / form | Default | Description |
|------------|---------|-------------|
| `path` (continuous) | project root (`$WTROOT`) | Scope of discover. Must exist and sit under the project/worktree root; otherwise loud fail (exit 64). |
| `materialize <path>` | — | Resume entry: `.json` preferred, `.md` report, or existing `-plan.md`. **No** re-discover / re-refute. |
| `handoff <plan-path>` | — | Resume S4: path ending in `-plan.md`. **No** re-S1–S3 invent. |
| `--severity-floor` | continuous: `nitpick` | Keep findings at or above this floor (`critical` > `warning` > `nitpick`). Invalid value → exit 64. Ignored for S4 banding. |
| `--proceed` | off | Satisfies the M8 materialize lock (no interactive token). Enables backlog create after the findings plan. |
| `--start-phase <n>` | off | Satisfies M9 for phase `n`. Arms the print-only `invocation_hint` after templates are on disk. |

## When to use

| Surface | Job |
|---------|-----|
| **`/bug-hunt`** | Unknown defects; continuous discover → refute → plan + proceed-gated materialize → phase handoff emit-only (stages 1–4) |
| [`/debug`](debug.md) / `/debug ticket` | Known bug premise → fix (not discovery) |
| [`/council --blind`](council.md) | One-shot blind peer review; no hunt floor / refute wave / report / materialize / handoff |
| [`/backlog`](backlog.md) | Interactive backlog; S3 cites programmatic write-back only |
| [`/orchestrate`](orchestrate.md) / [`/epic`](epic.md) | Downstream fix engines — **print-only** hints from S4; never invoked by `/bug-hunt` |

## Stages 1–4

1. **S1 Discover** — compose the blind path (3 unconstrained teams +
   security/contributor/spec lenses) → `candidates[]`.
2. **S2 Refute** — ≥2 investigators per candidate (distinct flavors); every
   candidate → confirmed or refuted. No user lock between S1 and S2.
3. **Report → S3 Plan/Materialize** — write the report, filter to
   `confirmed ∧ severity ≥ floor`, write the findings plan (`-plan.md`), then —
   only after `--proceed` or a typed `proceed` — materialize **bh-quality**
   backlog items via the backlog programmatic write-back (Linear-first,
   fail-open) and link them back into the plan.
4. **S4 Phase handoff (emit-only)** — band remaining findings by severity and
   write per-phase handoff templates (`handoff-phase-<n>`) plus a phase plan
   (`phase-plan`); print route hints. Never auto-advances between fix phases.

Severity is exactly `critical` | `warning` | `nitpick` — no invented taxonomy.

## Outputs

| Artifact | Path | Required |
|----------|------|----------|
| User-visible report | `$MROOT/.claude/bug-hunt/<YYYY-MM-DD>-<slug>.md` | MUST |
| Machine findings JSON | same dir, `.json` sibling | SHOULD |
| Findings plan | same dir, `<stem>-plan.md` | MUST (S3c) |
| Backlog items | `$MROOT/.claude/backlog/<slug>.md` (+ Linear when MCP up) | after M8 proceed only |
| Phase plan | same dir, `<stem>-phase-plan.md` | MUST (S4d) |
| Phase handoffs | same dir, `<stem>-handoff-phase-<n>.md` | one per non-empty band |

Zero confirmed-actionable is a **clean success**: terminal line
`0 confirmed-actionable` (exit 0). Process artifacts under `.claude/bug-hunt/`
and local backlog under `.claude/backlog/` are gitignored — never committed by
the hunt.

## Locks and hard walls

- No materialize without proceed (M8); no phase arm without M9.
- Stage 4 is emit-only — MUST NOT invoke `/orchestrate` / `/epic`, spawn fix
  ICs, or edit product code.
- Resume forms load artifacts only (`materialize`: no re-S1/S2; `handoff`:
  no re-S1–S3 invent).
- No commit / version / release; no nested `/council` UX; no dual-write fork.

## Non-goals

| Item | Status |
|------|--------|
| Auto-running fix engines / post-close verification | Forever OOS (operator pastes the hint) |
| `--teams` / `--lenses` flags | Deferred (MVP locks defaults) |
| Full tribunal per candidate; Workflow driver | Deferred |
| Replace [`/debug`](debug.md) / `/debug ticket` | Forbidden |

## Smoke (static / narrow path)

Live LLM hunt is **not** required to prove the surface. Narrow-path invocation
shape (continuous, no network):

```
/bug-hunt skills/bug-hunt
```

Hard non-products of smoke: no product-code edits, no fix-engine spawns, no
`/orchestrate` invocation, no commit. The static contract lives in
`bash skills/bug-hunt/test.sh` (includes the C5 smoke section).

## See also

- [`/debug`](debug.md) · [`/debug ticket`](debug.md) — known-premise fix pipelines
- [`/council`](council.md) — adversarial tribunal (`--blind` preset)
- [`/backlog`](backlog.md) — the write-back target
- `skills/bug-hunt/SKILL.md` + `specs/core/SPEC-034-bug-hunt-workflow.md` — full protocol, stage graph, and contract
- `bash skills/bug-hunt/test.sh` — static/narrow-path smoke
