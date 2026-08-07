# /bug-hunt

Unknown-defect discovery: multi-perspective discover → continuous refute/confirm →
user-visible **confirmed-actionable** report → findings plan + proceed-gated
**bh-quality** backlog materialize → severity-band **phase handoff emit-only**.
Stages **1–4** (CDT-136 / C2 + CDT-138 / C3 + CDT-139 / C4). Composes the
SPEC-013 blind-review path, investigator pattern, and SPEC-009 programmatic
write-back — does **not** fix code or **invoke** `/orchestrate` / `/epic`
(stage 4 prints route hints only).

Use `/bug-hunt` when you do **not** already have a bug premise. Prefer
[`/debug`](./debug.md) / `/debug ticket` for a known defect, and
[`/council --blind`](./council.md) for a one-shot blind review without a hunt
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
| `path` (continuous) | project root (`$WTROOT`) | Scope of discover. Must exist and sit under the project/worktree root. Non-existent / unreadable / out-of-root → loud fail (exit 64). |
| `materialize <path>` | — | Resume entry: `.json` preferred, `.md` report, or existing `-plan.md`. Missing both findings.json + report → exit 64. **No** re-discover / re-refute. |
| `handoff <plan-path>` | — | Resume S4: path ending in `-plan.md` (or sibling plan resolve). Missing/unreadable / not a findings plan → exit 64. **No** re-S1–S3 invent. |
| `--severity-floor` | continuous: `nitpick`; materialize resume: artifact then `nitpick` | Keep findings at or above this floor. Re-applied at S3 filter. Order: `critical` > `warning` > `nitpick`. Invalid value → loud fail (exit 64). **Ignored for S4 banding** (floor already applied at S3; bands use full severity order). |
| `--proceed` | off | Satisfies M8 materialize lock (no interactive token). Enables backlog create after the findings plan. |
| `--start-phase <n>` | off | Satisfies M9 for phase `n` (no interactive token). Arms print-only `invocation_hint` after templates are on disk. |

```
/bug-hunt
/bug-hunt skills/bug-hunt
/bug-hunt skills --severity-floor warning
/bug-hunt --severity-floor=critical
/bug-hunt --proceed
/bug-hunt materialize .claude/bug-hunt/2026-08-07-skills.json
/bug-hunt materialize .claude/bug-hunt/2026-08-07-skills-plan.md --proceed
/bug-hunt handoff .claude/bug-hunt/2026-08-07-skills-plan.md
/bug-hunt handoff .claude/bug-hunt/2026-08-07-skills-plan.md --start-phase 0
```

## When to use

| Surface | Job |
|---------|-----|
| **`/bug-hunt`** | Unknown defects; continuous discover → refute → plan + proceed-gated materialize → phase handoff emit-only (stages 1–4) |
| `/debug` / `/debug ticket` | Known bug premise → fix (not discovery) |
| `/council --blind` | One-shot blind peer review; no hunt floor / refute wave / hunt report / materialize / handoff |
| `/backlog` | Interactive backlog; S3 cites programmatic write-back only |
| `/orchestrate` / `/epic` | Downstream fix engines — **print-only** hints from S4; never invoked by `/bug-hunt` |
| `/review-and-commit` | Review staged/modified diffs before commit |

## Stages 1–4 (shipped)

Continuous S1→S2→REPORT — **no user lock between S1 and S2**. S3 after REPORT
(continuous) or via `materialize` resume. S4 after S3g (continuous) or via
`handoff` resume. **Locks:** proceed at S3d (M8); phase start at S4e (M9).

```
S0  parse/validate  (continuous | materialize <path> | handoff <plan>)
     │
     ├─ continuous ──────────────────────────────────────────┐
     │                                                       ▼
     │  S1  DISCOVER  — compose SPEC-013 blind path (defaults: 3 unconstrained
     │       │            teams + security/contributor/spec lenses; --target = path)
     │       │            → candidates[] (status=candidate); below-floor / OOS /
     │       │            malformed → dropped[]
     │       │
     │       ▼  (no user lock)
     │  S2  REFUTE    — ≥2 SPEC-013 investigators per candidate (distinct flavors);
     │       │            every candidate → confirmed | refuted
     │       │            confirmed_actionable = confirmed ∧ severity ≥ floor
     │       │
     │       ▼
     │  REPORT        — write .claude/bug-hunt/<YYYY-MM-DD>-<slug>.md  (SHOULD .json)
     │
     ├─ resume: materialize <path> ── loads artifacts only (no re-S1/S2)
     │
     ▼
S3a LOAD           json preferred → report.md fallback → loud fail both missing
     │
     ▼
S3b FILTER         actionable[] = confirmed ∧ severity ≥ floor (re-apply floor)
     │
     ▼
S3c PLAN WRITE     .claude/bug-hunt/<YYYY-MM-DD>-<slug>-plan.md
     │               linkage columns empty until materialize
     │
     ▼
S3d PROCEED LOCK   if A==0 → skip lock + zero creates
     │               else: require --proceed OR typed `proceed`
     │               neither → STOP after plan; 0 backlog creates (exit 0)
     ▼
S3e MATERIALIZE    unlinked actionable[] via backlog Programmatic write-back
     │               (SPEC-009 dual-write; Linear-first fail-open)
     │
     ▼
S3f LINK BACK      plan rows: backlog_slug + linear_id
     │
     ▼
S3g PHASE-DONE     M22 line + counts; continuous → S4a (plan-only stop never reaches S4)
     │
     ├─ resume: handoff <plan-path> [--start-phase n] ── S4a only (no re-S1–S3 invent)
     │
     ▼
S4a LOAD           findings plan → phaseable[] (materialized|skipped_linked + slug)
     │               loud fail unreadable (exit 64)
     │
     ▼
S4b BAND           critical→warning→nitpick; omit empty; renumber 0..N
     │               phase_count==0 → S4g zero; no S4e lock
     ▼
S4c ROUTE          phase_count≥2 AND item_count≥2 → /epic else /orchestrate
     │
     ▼
S4d WRITE          <stem>-phase-plan.md + <stem>-handoff-phase-<n>.md
     │               emit-only Write; locks gate arming, not file write
     ▼
S4e LOCK           phase n: --start-phase n OR typed start-phase-n
     │               without lock: print how-to; templates on disk; exit 0
     ▼
S4f ARM            print invocation_hint only; MUST NOT spawn engines
     │
     ▼
S4g PHASE-DONE     M23 line + paths + route + counts; stop
```

| Stage | What happens | Compose from |
|-------|--------------|--------------|
| **S1 Discover** | Parallel unconstrained + lens reviewers → quorum clustering → map to `candidates[]` | `skills/council` blind-review path (SPEC-013) |
| **S2 Refute** | Parallel investigator pairs disposition every candidate; fail-closed on thin evidence | SPEC-013 investigator pattern + existing flavors |
| **REPORT** | User-visible confirmed-actionable report (+ SHOULD findings JSON) | `skills/bug-hunt/templates/report.md` |
| **S3 Plan + materialize** | Findings plan → M8 proceed → bh-quality backlog items → link plan↔items | `skills/backlog` § Programmatic write-back (SPEC-009) |
| **S4 Phase handoff** | Load plan → severity bands → phase-plan + handoff templates → M9 arm → print route hint | `templates/phase-plan.md` + `handoff-phase.md` (emit-only) |

Phase-done lines:

1. `phase-done: discover — candidate set produced (M20)`
2. `phase-done: refute — every candidate dispositioned (M21)`
3. `phase-done: materialize — findings plan + bh-quality backlog (M22)`  
   (or `phase-done: materialize — 0 creates (M22)` when zero actionable)
4. `phase-done: handoff — resume identity + phase templates (M23)`  
   (or `phase-done: handoff — 0 phases (M23)` when zero phaseable)

### Severity model

Only `critical` | `warning` | `nitpick`. Floor filter drops strictly-below-floor
items into informational `dropped[]` (never candidates). Actionable list is
**confirmed ∧ ≥ floor** only — re-applied at S3 even when loading prior
`confirmed_actionable`. S4 bands use full severity order on phaseable rows;
`--severity-floor` does **not** re-filter at stage 4.

### Proceed lock (M8)

| Form | Effect |
|------|--------|
| `--proceed` on the invocation | Record proceed; materialize after plan |
| Typed token `proceed` (case-insensitive) at the S3d prompt | Same |
| Neither, and actionable > 0 | **Plan-only stop** — plan written; **0** backlog creates; exit 0. Resume with `materialize <path> --proceed` |
| Actionable == 0 | Skip lock; 0 creates; clean M22 zero path |

Plan write (S3c) is allowed **without** proceed. Backlog create (S3e) is not.

### Phase lock (M9)

| Form | Effect |
|------|--------|
| `--start-phase <n>` on continuous or `handoff` | Record arm for phase `n`; S4f prints `invocation_hint` |
| Typed token `start-phase-<n>` (case-insensitive) at the S4e prompt | Same |
| Neither, and phase_count > 0 | **Emit-only stop** — phase-plan + handoff files on disk; `armed_phase: none`; exit 0. Resume with `handoff <plan> --start-phase <n>` |
| phase_count == 0 | Skip lock; 0 handoff-phase files; clean M23 zero path |

Phase templates write (S4d) is allowed **without** arm. Completing a fix phase
**outside** bug-hunt MUST NOT auto-start the next — re-enter with
`--start-phase <n>` for each phase (M36).

### Stage 4 — phase templates + route

**Phaseable** plan rows only: status `materialized` or `skipped_linked` **and**
non-empty `backlog_slug` (failed/pending/planned excluded).

**Banding (M43):** group by `critical` → `warning` → `nitpick`; **omit empty**
bands; renumber contiguous `0..N`; `phase_id` = `BH-PHASE-<n>`; intra-band order
preserves plan-table order.

**Route (M45 / M18):**

| Condition | Route |
|-----------|-------|
| `phase_count ≥ 2` **and** `item_count ≥ 2` | `/epic` |
| otherwise (including single phase with many items) | `/orchestrate` |

Route is identical across all phase templates for a run. Stage 4 **never
invokes** the selected engine.

**Artifacts (M44)** under `$MROOT/.claude/bug-hunt/`:

| File | Role |
|------|------|
| `<stem>-phase-plan.md` | Index of all phases (n, band, item count, handoff path, route, arm status) |
| `<stem>-handoff-phase-<n>.md` | One handoff per non-empty phase |

Every handoff carries: `phase_id`, `hunt_stem`, `plan_path`, `route`, `items[]`
(slug + optional linear_id), `goal`, `exit_metrics` (`closed_count` target =
`|items|`, `residual_criticals == 0`, `signoff`), `lock`, `invocation_hint`.
All phase files for a run are emitted **together** — locks gate **arming**, not
file write.

**Zero path:** no phaseable rows → minimal phase-plan only (`phase_count: 0`);
**zero** handoff-phase files; no M9 lock; clean M23.

**After arm (S4f):** print pasteable `invocation_hint` only
(`/orchestrate <ISSUE-ID>` or `/epic <ISSUE-ID>`). Operator pastes elsewhere —
skill/orchestrator **MUST NOT** Task-spawn engines.

### Degradation

If investigator/refuter spawns are unusable, the orchestrator self-verifies with
read-only tools and emits the exact marker
**`self-verified — refuters unavailable`** (CDV-199). Never invent confirmed findings.

## Outputs

| Artifact | Path | Required |
|----------|------|----------|
| User-visible report | `$MROOT/.claude/bug-hunt/<YYYY-MM-DD>-<slug>.md` | MUST |
| Machine findings JSON | same dir, `.json` sibling | SHOULD (preferred S3 load) |
| Findings plan | same dir, `<stem>-plan.md` | MUST (S3c; before any backlog create) |
| Backlog items | `$MROOT/.claude/backlog/<slug>.md` (+ Linear when MCP up) | After M8 proceed only |
| Phase plan | same dir, `<stem>-phase-plan.md` | MUST (S4d; resume identity even when 0 phases) |
| Phase handoffs | same dir, `<stem>-handoff-phase-<n>.md` | One per non-empty band (zero when no phaseable) |

Report lists **confirmed-actionable** findings only (full AC8 fields: locator,
severity, description, evidence, status). Zero actionable is a **clean success**:
terminal line `0 confirmed-actionable` (exit 0) — not an error. S3 still writes
a minimal plan and emits M22 zero creates. S4 still writes a minimal phase-plan
and emits M23 zero phases when nothing is phaseable.

Process artifacts under `.claude/bug-hunt/` and local backlog under
`.claude/backlog/` are gitignored — never committed by the hunt.

### Backlog dual-write (S3e)

After proceed, each unlinked actionable finding becomes a **bh-quality** item via
`skills/backlog/SKILL.md` § **Programmatic write-back** only (no second dual-write /
`add.sh` fork):

- **Linear-first** (default MCP mode); fail-open to local-only if Linear is down
- Self-contained body: severity, locator, description, **full evidence** (not
  “see plan”)
- Plan ↔ item linkage: plan rows get `backlog_slug` + `linear_id`; items carry
  `hunt_stem` / `plan_path` / `finding_id`
- Idempotent re-materialize: already-linked rows with an existing item file are
  skipped (`skipped_linked`)

## Locks and hard walls

| Rule | Effect |
|------|--------|
| No inter-stage user lock (S1→S2) | Continuous run; no confirm prompt between discover and refute |
| No materialize without proceed (M8) | Plan write allowed; backlog create only after `--proceed` or typed `proceed` |
| No dual-write fork | Materialize cites backlog programmatic write-back only |
| No phase arm without M9 | Phase templates write allowed; print `invocation_hint` only after `--start-phase <n>` or typed `start-phase-<n>` |
| No auto-advance between fix phases (M36) | Completing a phase does not start the next; re-arm explicitly |
| **Emit-only stage 4 (N12 / M48)** | MUST NOT invoke `/orchestrate` / `/epic`, spawn fix ICs, or edit product code to “fix” |
| No re-S1/S2 on materialize resume | `materialize <path>` loads artifacts only |
| No re-S1–S3 invent on handoff resume | `handoff <plan>` loads C3 plan only (N13) |
| No commit / version / release | MUST NOT `git commit` or touch version files |
| No nested `/council` UX | Compose blind/investigator patterns in-skill; no second user lock before S3d |
| No invented severity taxonomy | Only `critical` \| `warning` \| `nitpick` |

## Non-goals

| Item | Status |
|------|--------|
| Auto-running fix engines / post-close verification | Forever OOS for bug-hunt (operator pastes hint) |
| `--teams` / `--lenses` flags on `/bug-hunt` | Deferred (MVP locks defaults) |
| Full tribunal per candidate; Workflow driver | Deferred |
| Replace `/debug` / `/debug ticket` | Forbidden (M27 / M37) |

## Smoke (static / narrow path)

Live LLM hunt is **not** required to prove the surface. Static contract:

```bash
bash skills/bug-hunt/test.sh   # includes C5 smoke section
```

**Invocation shape (narrow path, continuous):**

```
/bug-hunt skills/bug-hunt [--severity-floor warning]
```

Expected protocol products (skill-owned; no product-code edits):

| Product | Gate |
|---------|------|
| Report + SHOULD findings JSON | After S1→S2→REPORT |
| Findings plan (`…-plan.md`) | S3c always (even when 0 actionable) |
| Backlog items (≥0) | Only after M8 proceed; 0 without `--proceed` / typed `proceed` |
| Phase-plan + handoff stubs | S4d always (minimal phase-plan when 0 phaseable) |
| Route `invocation_hint` print | Only after M9 `--start-phase <n>` / typed token |

**Loud fails (exit 64):** missing/unreadable path; path outside project root;
invalid `--severity-floor`; materialize with neither findings JSON nor report;
handoff path unreadable / not a findings plan.

**Hard non-products of smoke:** no `git commit`, no version bump, no
`/orchestrate`/`/epic` invoke, no IC fix spawns, no product-code patches.

## See also

- Protocol: `skills/bug-hunt/SKILL.md`
- Contract: `specs/core/SPEC-034-bug-hunt-workflow.md`
- Compose: [`/council --blind`](./council.md) · SPEC-013 investigator pattern ·
  `skills/backlog/SKILL.md` § Programmatic write-back ·
  `skills/bug-hunt/templates/phase-plan.md` + `handoff-phase.md`
- Neighbors: [`/debug`](./debug.md) · [`/orchestrate`](./orchestrate.md) ·
  [`/epic`](./epic.md) · [`/review-and-commit`](./review-and-commit.md)
