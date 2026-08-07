# SPEC-034: Bug-Hunt Workflow

**Status**: DRAFT
**Category**: core
**Created**: 2026-08-06

**See also**: SPEC-013, SPEC-009, SPEC-014, SPEC-025, SPEC-017

**Covers**: `commands/bug-hunt.md`, `skills/bug-hunt/*` (stages 1–2 discover→refute runtime —
CDT-136; stage-3 findings plan + backlog materialize runtime — CDT-138; stage-4 phased handoff
runtime — CDT-139; Status DRAFT)

---

## Overview

`/bug-hunt` is a multi-stage product workflow for **unknown-defect discovery** across a path
scope: discover candidates → refute or confirm with evidence → materialize only confirmed
findings into a findings plan and backlog → hand off phased fix work through existing
orchestration surfaces.

Framing vs neighboring surfaces:

| Surface | Job |
|---------|-----|
| `/bug-hunt` | Multi-stage hunt: discover → refute/confirm → materialize → phased fix handoff |
| `/debug` / `/debug ticket` | Fix a **known** bug (premise → implement → refute); not a discovery pipeline |
| `/council --blind` | One-shot blind investigation (SPEC-013 finders); not materialize or fix phases |

**Surface class:** Advanced Live (product note only — not a C1 ship bar for this DRAFT).

**Stage diagram (1–4) and user locks:**

```
(1) discover ──► (2) refute/confirm ──► (3) findings plan + backlog materialize ──► (4) phased handoff
     └──── single run; no user lock ────┘         ▲ lock: explicit proceed              ▲ locks:
                                                   before materialize                    start fix-phase 0;
                                                                                         between fix phases
```

**Ownership:** CDT-140 froze the product contract (DRAFT). CDT-136 (C2) owns the **stages 1–2
runtime** under `commands/bug-hunt.md` and `skills/bug-hunt/*` (discover → continuous
refute/confirm → user-visible report). CDT-138 (C3) owns the **stage 3 runtime** (load findings
→ findings plan → proceed lock → SPEC-009 materialize + linkage → phase-done) on the same
command/skill surface. CDT-139 (C4) owns the **stage 4 runtime** (load findings plan → severity
bands → phase-plan + handoff templates → M9 locks → emit-only route print → M23 phase-done) on
the same command/skill surface. Status remains DRAFT until a later promote.

**Composition (not ownership of composed surfaces):** discover/refute reuse SPEC-013
council/blind finder patterns; materialize reuses SPEC-009 `/backlog` dual-write; handoff
**emits** templates that route to `/orchestrate` (SPEC-017) by default or `/epic` (SPEC-025)
when M18's multi-wave multi-ticket rule matches (operationalized by M45). Bug-hunt MUST compose
these surfaces and MUST NOT invent a parallel ticket lifecycle. Stage 4 is **emit-only** — it
MUST NOT invoke `/orchestrate`, `/epic`, spawn ICs, or edit product code to fix (N12).

---

## MUST

### Surface & invocation (AC2)

- **M1 — Command name.** The user-facing surface MUST be the slash command `/bug-hunt`.
- **M2 — Path scope.** Path scope is optional. When omitted, scope MUST default to the project
  root. When provided, it MUST bound discover (and downstream stages) to that path.
- **M3 — Severity floor flag.** Invocation MUST accept `--severity-floor` with enum
  `critical|warning|nitpick`. When the flag is **omitted**, the active floor MUST default to
  `nitpick` (lowest floor — all severities eligible unless raised).
- **M4 — Loud fail on invalid input.** Invalid severity enum values and unusable/non-existent
  path arguments MUST fail loudly (non-zero exit and/or clear user-visible error). Silent
  coercion or silent ignore of invalid args MUST NOT occur.
- **M5 — Invocation shape.** Canonical form:
  `/bug-hunt [path] [--severity-floor <critical|warning|nitpick>]`.

### Stages & user locks (AC3)

- **M6 — Ordered stages.** A hunt MUST proceed in this order only:
  1. **discover** — produce candidate findings in scope
  2. **refute/confirm** — disposition every candidate to `confirmed` or `refuted`
  3. **findings plan + backlog materialize** — emit plan; create backlog items only after proceed
  4. **phased handoff** — emit phase templates and route to fix orchestration
- **M7 — Discover↔refute continuous.** Stages 1 and 2 MUST run as a single continuous run with
  **no** inter-stage user lock between discover and refute/confirm.
- **M8 — Materialize lock.** Stage 3 MUST require an **explicit user proceed** (typed proceed
  token and/or proceed flag — either form is acceptable) before any backlog materialization.
  Auto-materialize without proceed MUST NOT occur.
- **M9 — Fix-phase locks.** Stage 4 MUST require explicit user action to **start fix-phase 0**
  and explicit user action **between fix phases**. Auto-advance across fix-phase boundaries
  MUST NOT occur.

### Finding model (AC4)

- **M10 — Status set.** Each finding's lifecycle status MUST be one of:
  `candidate` | `refuted` | `confirmed`.
- **M11 — Confirmed required fields.** A finding with `status=confirmed` MUST carry all of:
  - `locator` — concrete location (path, symbol, test, or equivalent pointer)
  - `severity` — `critical` | `warning` | `nitpick`
  - `description` — what is wrong
  - `evidence` — why it is real (repro, code cite, failing check, etc.)
  - `status` — exactly `confirmed`
- **M12 — Pre-materialize statuses.** Before materialize, findings MAY be `candidate` or
  `refuted`. Only findings with `status=confirmed` MAY materialize into backlog items or the
  findings plan's actionable set.
- **M13 — Severity enum (product lock).** Canonical severity values are
  `critical|warning|nitpick` (council-aligned). July playbook mapping for display/migration
  only: HIGH→`critical`, MEDIUM→`warning`, LOW→`nitpick`. HIGH/MEDIUM/LOW MUST NOT be
  canonical product values.

### Severity floor (AC11)

- **M14 — Floor filter on materialize.** Findings with severity **below** the active
  `--severity-floor` MUST NOT materialize by default (not into backlog items; not as
  actionable materialize targets).
- **M15 — Discover dropped list.** Stage 1 (discover) MAY list below-floor findings as
  **dropped** (informational). Dropped/below-floor items MUST still not materialize unless a
  future product option explicitly overrides default floor behavior (out of scope for this DRAFT;
  default remains never materialize).

### Composition boundaries (AC6)

- **M16 — Discover/refute via SPEC-013.** Discover and refute/confirm MUST reuse SPEC-013
  council / blind-finder patterns (compose; do not fork a second blind-hunt protocol).
- **M17 — Materialize via SPEC-009.** Backlog materialization MUST reuse SPEC-009 `/backlog`
  dual-write. Bug-hunt MUST NOT invent a second backlog SoT or dual-write path.
- **M18 — Handoff routing (product lock).** Stage 4 handoff MUST select a route of:
  - **`/orchestrate` by default** (SPEC-017), or
  - **`/epic` when** the fix work is a **multi-wave multi-ticket DAG** (SPEC-025).
  Operational rule for the stage-4 runtime is **M45** (`phase_count ≥ 2` ∧ `item_count ≥ 2` →
  `/epic`; else `/orchestrate`). Route is recorded on templates and printed as
  `invocation_hint` only — stage 4 MUST NOT invoke either engine (N12).
- **M19 — Compose only.** Bug-hunt MUST compose the surfaces above and MUST NOT implement a
  parallel ticket lifecycle, alternate orchestrator, or shadow epic/backlog system.

### Exit metrics / phase-done (AC7)

Each stage MUST expose a product-checkable **phase done** signal (not an implementation
telemetry schema — a user- or gate-visible completion condition):

- **M20 — discover phase done:** scoped candidate set produced for the path scope; optional
  dropped-below-floor list present when floor filtering applied during discover.
- **M21 — refute phase done:** every candidate dispositioned to `confirmed` or `refuted` with
  evidence recorded for the disposition.
- **M22 — materialize phase done:** explicit user proceed recorded; only `confirmed` findings
  at or above the severity floor materialized as **bh-quality** backlog items plus a findings
  plan.
- **M23 — handoff phase done:** hunt **resume identity** established; fix-phase-0 handoff
  template emitted (when phaseable items exist); route selected per M18/M45
  (`/orchestrate` default or `/epic` multi-wave DAG). Concrete stage-4 line form + zero path
  are **M48**.

### User-visible outputs (AC9)

- **M24 — User-visible artifacts.** A hunt MUST produce, as user-visible outputs:
  - findings plan
  - bh-quality backlog items (post-materialize only; confirmed ≥ floor)
  - phase handoff templates
  - hunt resume identity
- **M25 — Process artifacts.** Process/state under `.claude/` MUST remain **uncommitted**
  (process tracker hygiene; not product delivery).

### When-to-use matrix (AC10)

- **M26 — Matrix.** Operators MUST treat surface selection as follows:

| Use… | When… |
|------|--------|
| `/bug-hunt` | Unknown defects; multi-stage discover → refute → materialize → phased fix handoff |
| `/debug` / `/debug ticket` | Known bug with a fix premise; implement + adversarial refute (SPEC-014 / SPEC-028 family) |
| `/council --blind` | One-shot blind investigation / evidence hunt without materialize or fix phases (SPEC-013) |
| `/backlog` | Create/update backlog items without a hunt pipeline (SPEC-009) |
| `/epic` | Multi-wave multi-ticket DAG / umbrella decomposition (SPEC-025); also bug-hunt handoff target when M18 epic rule matches |
| `/orchestrate` | Single-ticket (or non-epic) plan→implement→ship loop (SPEC-017); default bug-hunt handoff target |

### Stages 1–2 runtime — discover → refute report (AC stages 1–2 / CDT-136)

Additive contract for continuous discover→refute (no inter-stage lock; M7). Does **not**
redesign stages 3–4.

- **M31 — Stage 1–2 user-visible report.** A continuous stages 1–2 run MUST emit a
  user-visible report under `.claude/bug-hunt/` (canonical path pattern:
  `$MROOT/.claude/bug-hunt/<YYYY-MM-DD>-<slug>.md`). Process artifacts under `.claude/bug-hunt/`
  MUST remain **uncommitted** (M25 process-tracker hygiene).
- **M32 — Confirmed-actionable filter (stage 1–2 exit).** At stages 1–2 exit,
  `confirmed_actionable` MUST equal findings with `status=confirmed` **and** severity at or
  above the active `--severity-floor`. The stage 1–2 report MUST list that set (and MUST NOT
  present below-floor findings as actionable). Distinct from **M14** (materialize floor filter,
  stage 3) but severity-order aligned (`critical` > `warning` > `nitpick`).
- **M33 — Discover compose (SPEC-013 blind path).** Stage 1 (discover) MUST compose the
  SPEC-013 blind-review path with defaults and `--target` bound to the hunt path scope (M2).
  Bug-hunt MUST NOT fork a second finder protocol (aligns with M16).
- **M34 — Refute compose (SPEC-013 investigators).** Stage 2 (refute/confirm) MUST disposition
  **every** candidate via **≥2** SPEC-013 investigator-pattern agents with **distinct** council
  flavors. At stage-2 exit, no finding may remain `status=candidate` (aligns with M21).

### Stage 3 runtime — findings plan + backlog materialize (AC stage 3 / CDT-138)

Additive contract for stage 3 (plan write, proceed-gated materialize, linkage, phase-done).
Does **not** redesign stages 1–2 or stage 4; does **not** change product locks M8 / M12 / M14 /
M17 / M22 (those remain authoritative). Stage 3 MUST NOT re-run discover or refute, MUST NOT
start fix work, and MUST NOT enter stage 4.

- **M38 — Stage-3 load.** Stage 3 MUST load hunt findings from process artifacts under
  `.claude/bug-hunt/`: prefer `findings.json` (or a resume path ending in `.json`); fall back to
  the sibling stages 1–2 `report.md` (or a resume path ending in `.md` that is not `-plan.md`).
  When both preferred inputs are missing/unreadable, stage 3 MUST **loud fail** (non-zero exit
  and a clear user-visible error naming the stem / usage). A resume path ending in `-plan.md`
  MUST load that findings plan for re-materialize (idempotent path; M41). Stage 3 MUST NOT
  re-enter stages 1–2 to regenerate findings.
- **M39 — Findings plan path.** Stage 3 MUST write (or update) the findings plan at
  `$MROOT/.claude/bug-hunt/<YYYY-MM-DD>-<slug>-plan.md` (locks S2 naming preference as the
  runtime path). The plan MUST be written **before** any backlog create (review artifact ahead of
  M8 proceed). Process artifacts under `.claude/bug-hunt/` remain **uncommitted** (M25).
- **M40 — Materialize compose + linkage.** After M8 proceed, backlog materialization MUST use
  SPEC-009 `/backlog` **programmatic write-back** only (aligns with M17). Bug-hunt MUST NOT
  reimplement dual-write, index format, or a second backlog SoT. Each materialized item MUST be
  **bh-quality** and **self-contained** (severity, locator, evidence substance in the item body —
  bare plan pointers forbidden). Plan ↔ item linkage MUST be **bidirectional**: plan rows record
  backlog slug / Linear id (when present); item notes/frontmatter record hunt stem, plan path, and
  finding id. Phase-done for stage 3 remains **M22** (proceed recorded; confirmed ≥ floor only;
  findings plan + counts).
- **M41 — Proceed forms, idempotent re-materialize, zero path.** Explicit proceed (M8) MUST be
  satisfied by either a **`--proceed` flag** or a typed **`proceed` token** (case-insensitive);
  either form is acceptable. Without proceed and with at least one actionable finding, stage 3
  MUST stop after plan write with **zero** backlog creates (plan-only success). Re-materialize
  MUST be **idempotent**: skip findings already linked in the plan when the backlog item still
  exists (no second create for the same finding id). When actionable count is **zero** (no
  confirmed findings at or above the severity floor after re-applying M14), stage 3 MUST perform
  **zero** backlog creates and still emit a clean materialize phase-done (M22 / AC10 zero path)
  without requiring proceed.

### Stage 4 runtime — phased handoff + locks (AC stage 4 / CDT-139)

Additive contract for stage 4 (load findings plan → severity bands → phase-plan + handoff
templates → M9 locks → emit-only route print → M23 phase-done). Does **not** redesign stages
1–3; does **not** change product locks M9 / M18 / M23 / M36 (those remain authoritative —
stage 4 operationalizes them). Stage 4 MUST NOT re-run discover, refute, or materialize, MUST
NOT invent findings, and MUST NOT invoke fix engines or edit product code (N12–N13).

- **M42 — Stage-4 load.** Stage 4 MUST load the stage-3 findings plan at a path ending in
  `-plan.md` (continuous session binding or resume `/bug-hunt handoff <plan-path>`). Phaseable
  inputs are plan rows with status `materialized` or `skipped_linked` **and** a non-empty
  `backlog_slug` (failed/pending/planned rows excluded). When the plan is missing/unreadable or
  the path does not resolve to a findings plan, stage 4 MUST **loud fail** (non-zero exit and a
  clear user-visible error). Stage 4 MUST NOT re-enter stages 1–3 to regenerate findings (N13).
- **M43 — Severity banding.** Stage 4 MUST group phaseable items into severity bands in order
  **`critical` → `warning` → `nitpick` only** (no custom priority mix). Empty bands MUST be
  **omitted**; remaining phases MUST be renumbered contiguous `0..N` in emission order.
  `phase_id` form is `BH-PHASE-<n>`. Intra-band order preserves plan-table order (stable).
  `--severity-floor` does not re-filter at stage 4 (floor already applied at stage 3).
- **M44 — Phase artifacts.** Stage 4 MUST write under `$MROOT/.claude/bug-hunt/`:
  - `<stem>-phase-plan.md` — index of all phases (n, band, item count, handoff path, route,
    arm status)
  - `<stem>-handoff-phase-<n>.md` — one handoff template per non-empty phase
  Every phase handoff template MUST carry fields: `phase_id`, `hunt_stem`, `plan_path`,
  `route`, `items[]` (slug and optional linear_id), `goal`, `exit_metrics`, `lock`,
  `invocation_hint`. Every phase-plan and handoff artifact MUST name `hunt_stem` and
  `plan_path` (cross-session resume). Process artifacts under `.claude/bug-hunt/` remain
  **uncommitted** (M25). Template field contracts live in skill templates; skill fills them.
  All phase files for a run MUST be emitted together (locks gate **arming**, not file write).
- **M45 — Route rule (operational M18).** Stage 4 MUST select route as:
  - **`/epic`** when `phase_count ≥ 2` **and** `item_count ≥ 2`
  - **`/orchestrate`** otherwise (default)
  where `item_count` is the count of phaseable items and `phase_count` is the count of
  non-empty severity bands after M43. Single phase with many items remains `/orchestrate`.
  Route is identical across all phase templates for a given run.
- **M46 — Phase lock forms (operational M9).** Explicit user action to **start fix-phase 0**
  and **between fix phases** MUST be satisfied by either a **`--start-phase <n>`** flag or a
  typed **`start-phase-<n>`** token (case-insensitive); either form is acceptable. Without the
  lock for phase `n`, stage 4 MUST leave templates on disk, print how to arm, and MUST NOT
  auto-advance (aligns with M9 / M36). Completing a fix phase MUST NOT auto-start the next.
- **M47 — Exit metrics on template.** Each phase handoff template MUST expose checkable exit
  metrics for the **downstream** fix run: `closed_count` target equal to `|items|` for that
  phase, `residual_criticals == 0` required, and `signoff` field (`pending` at emit; recorded
  when the phase lock arms). Stage 4 does **not** wait for post-orchestrate close — metrics are
  the template contract, not a live gate inside bug-hunt.
- **M48 — Handoff phase-done (operational M23) + zero path + emit-only.** Stage 4 MUST end with
  a user-visible **phase-done** signal that includes resume identity (`hunt_stem`), `plan_path`,
  phase-plan path, phase-0 handoff path (when phases exist), selected `route`, `phase_count`,
  `item_count`, and `armed_phase` (`n` or `none`). When phaseable count is **zero** (no
  non-empty bands after M43), stage 4 MUST emit **zero** handoff-phase files, still emit a clean
  M23 zero path (`phase_count: 0`, `item_count: 0`), and MUST NOT require a phase lock.
  Stage 4 is **emit-only**: it MUST write templates/paths and MAY print `invocation_hint` after
  lock arm; it MUST NOT invoke `/orchestrate`, `/epic`, spawn implementers, or edit product code
  to fix defects (N12).

### Non-goals & OOS (AC5, AC12)

- **M27 — Not a `/debug` replacement.** `/bug-hunt` MUST NOT replace `/debug` or
  `/debug ticket`. Known-bug fix remains those surfaces.
- **M28 — No auto-fix / auto-advance across locks.** Bug-hunt MUST NOT auto-fix defects and
  MUST NOT auto-advance past materialize proceed, start fix-phase 0, or between-fix-phase locks.
- **M29 — No parallel ticket lifecycle.** MUST NOT create a second ticket/orchestration lifecycle
  beside `/backlog` + `/orchestrate` + `/epic`.
- **M30 — OOS inside discover–refute.** Implement and fix work MUST NOT run inside stages 1–2
  (discover / refute-confirm). Those stages are discovery and evidence only.
- **M35 — No silent mass-create.** MUST NOT silently mass-create backlog items or tickets
  without M8 proceed and M12 confirmed-only rules.
- **M36 — No auto-start next fix phase.** Completing a fix phase MUST NOT auto-start the next;
  M9 requires explicit between-phase action.
- **M37 — No replace `/debug ticket`.** Protocol and entry for known-bug ticket fix remain
  owned by debug surfaces (SPEC-014 / related); bug-hunt MUST NOT subsume them.

---

## SHOULD

- **S1 — Resume identity.** Prefer a stable, human-readable hunt resume identity (slug or id)
  that round-trips across sessions without relying on chat history alone.
- **S2 — Findings plan naming.** Prefer a consistent findings-plan name/path convention so
  operators can locate the plan after materialize. **Runtime lock:** M39 requires
  `$MROOT/.claude/bug-hunt/<YYYY-MM-DD>-<slug>-plan.md`.
- **S3 — July severity map display.** When presenting findings that originated under the July
  HIGH/MEDIUM/LOW labels, SHOULD show the mapped `critical|warning|nitpick` value (M13) so
  operators are not left with dual taxonomies.
- **S4 — Advanced Live disclosure.** Surface docs (later ticket) SHOULD note Advanced Live
  class; this DRAFT only records the product lock (OQ5 closed as note-only).

---

## MUST NOT

- **N1** — MUST NOT auto-fix defects as part of `/bug-hunt` discover–refute.
- **N2** — MUST NOT auto-advance across materialize proceed, start fix-phase 0, or between
  fix-phase locks.
- **N3** — MUST NOT materialize findings that are not `status=confirmed`.
- **N4** — MUST NOT materialize below-floor findings by default (M14).
- **N5** — MUST NOT invent a parallel ticket lifecycle or dual backlog SoT.
- **N6** — MUST NOT silently mass-create backlog items or tickets.
- **N7** — MUST NOT replace `/debug` or `/debug ticket`.
- **N8** — MUST NOT place a user lock between discover and refute/confirm in a single run.
- **N9** — MUST NOT treat HIGH/MEDIUM/LOW as canonical severity (map only; M13).
- **N10** — MUST NOT materialize / create backlog items **without** M8 proceed (flag or typed
  token). Plan write before proceed remains allowed (M39).
- **N11** — MUST NOT re-run stage 1 discover or stage 2 refute as part of stage 3 resume/load
  (M38); MUST NOT start stage-4 handoff, `/orchestrate`, `/epic`, or fix/implement work from
  stage 3 (AC12). Stage 4 entry is a separate continuous continue or resume `handoff` path
  (M42), not an auto-start from stage 3 without skill pipeline reach.
- **N12** — MUST NOT invoke `/orchestrate`, `/epic`, spawn fix implementers, or edit product
  code to fix as part of stage 4; handoff is **emit-only** (templates + `invocation_hint`
  print). Aligns with M48.
- **N13** — MUST NOT re-enter stages 1–3 during handoff to invent or regenerate findings,
  plans, or backlog items (M42). Stage 4 consumes the stage-3 findings plan only.

---

## Test

Static contract checks (spec text + Covers path presence when runtime lands). From
repo/worktree root:

1. **T1 — File + lifecycle.** `test -f specs/core/SPEC-034-bug-hunt-workflow.md` and
   `rg -n '^\*\*Status\*\*: DRAFT$' specs/core/SPEC-034-bug-hunt-workflow.md` matches.
2. **T2 — Category/created.** File contains `**Category**: core` and `**Created**: 2026-08-06`.
3. **T3 — See also.** File cites SPEC-013, SPEC-009, SPEC-014, SPEC-025, SPEC-017.
4. **T4 — Surface.** File contains `/bug-hunt` and `--severity-floor` and enum literals
   `critical`, `warning`, `nitpick`.
5. **T5 — Stages.** File names stages discover, refute/confirm (or refute), materialize, and
   phased handoff (or handoff).
6. **T6 — Locks.** File states explicit proceed before materialize; start fix-phase 0; between
   fix phases; and that discover↔refute has no inter-stage user lock.
7. **T7 — Finding model.** File requires `locator`, `severity`, `description`, `evidence`, and
   `status=confirmed`; statuses include `candidate`, `refuted`, `confirmed`.
8. **T8 — Floor.** File states below-floor never materialize by default; discover MAY list
   dropped. M3 states default when omitted is `nitpick`.
9. **T9 — Composition.** File cites SPEC-013, SPEC-009, `/orchestrate` default, `/epic` for
   multi-wave multi-ticket DAG.
10. **T10 — Matrix + non-goals.** File includes when-to-use rows for `/bug-hunt`, `/debug`,
    `/council --blind`, `/backlog`, `/epic`, `/orchestrate`; and forbids auto-fix, silent
    mass-create, parallel ticket lifecycle, replace `/debug ticket`.
11. **T11 — Format.** `bash skills/spec-tooling/check-format.sh specs/core/SPEC-034-bug-hunt-workflow.md`
    exits 0.
12. **T12 — M31 report path.** File requires a stages 1–2 user-visible report under
    `.claude/bug-hunt/` and that process artifacts there stay uncommitted:
    `rg -n 'M31|\.claude/bug-hunt' specs/core/SPEC-034-bug-hunt-workflow.md` matches.
13. **T13 — M32 confirmed-actionable.** File defines `confirmed_actionable` as
    confirmed ∧ severity ≥ floor at stage 1–2 exit:
    `rg -n 'M32|confirmed_actionable' specs/core/SPEC-034-bug-hunt-workflow.md` matches.
14. **T14 — M33 discover compose.** File requires Stage 1 compose of SPEC-013 blind-path
    defaults with `--target` = hunt path; forbids forking a second finder protocol:
    `rg -n 'M33|blind' specs/core/SPEC-034-bug-hunt-workflow.md` matches.
15. **T15 — M34 refute compose.** File requires Stage 2 disposition of every candidate via
    ≥2 SPEC-013 investigator-pattern agents (distinct flavors); no leftover `candidate`:
    `rg -n 'M34|investigator' specs/core/SPEC-034-bug-hunt-workflow.md` matches.
16. **T16 — Covers surface presence (when runtime landed).** When Covers claims them:
    `test -f commands/bug-hunt.md` and `test -f skills/bug-hunt/SKILL.md` (or equivalent under
    `skills/bug-hunt/*`). Until those files exist, T16 is N/A / deferred to CDT-136 skill+command
    tasks; Covers still names the intended ownership paths.
17. **T17 — Index.** `specs/TDD.md` Spec Index lists SPEC-034 with Status DRAFT matching this
    file; Coverage cites `commands/bug-hunt.md` and/or `skills/bug-hunt/*` when present
    (stages 1–4 after CDT-139; Status remains DRAFT).
18. **T18 — M38 stage-3 load.** File requires json-preferred / report fallback load and loud fail
    when both missing:
    `rg -n 'M38|findings\.json|loud fail' specs/core/SPEC-034-bug-hunt-workflow.md` matches.
19. **T19 — M39 findings plan path.** File locks plan path
    `$MROOT/.claude/bug-hunt/<YYYY-MM-DD>-<slug>-plan.md` (or equivalent `-plan.md` under
    `.claude/bug-hunt/`):
    `rg -n 'M39|-plan\.md' specs/core/SPEC-034-bug-hunt-workflow.md` matches.
20. **T20 — M40 materialize compose + linkage.** File requires SPEC-009 **programmatic
    write-back**, bidirectional plan↔item linkage, and bh-quality self-contained body:
    `rg -n 'M40|programmatic write-back|bidirectional' specs/core/SPEC-034-bug-hunt-workflow.md`
    matches.
21. **T21 — M41 proceed forms + idempotent + zero path.** File requires `--proceed` and/or typed
    `proceed` token, **idempotent** re-materialize (skip already linked), and zero-create path
    when actionable count is 0:
    `rg -n 'M41|idempotent|--proceed|zero' specs/core/SPEC-034-bug-hunt-workflow.md` matches.
22. **T22 — M42 stage-4 load.** File requires load of C3 `-plan.md`, phaseable =
    `materialized`|`skipped_linked` + non-empty slug, and loud fail when plan unreadable:
    `rg -n 'M42|skipped_linked|handoff' specs/core/SPEC-034-bug-hunt-workflow.md` matches.
23. **T23 — M43 severity banding.** File requires bands `critical` → `warning` → `nitpick`,
    omit empty, renumber contiguous `0..N`:
    `rg -n 'M43|omit empty|renumber' specs/core/SPEC-034-bug-hunt-workflow.md` matches.
24. **T24 — M44/M47 phase artifacts + exit metrics.** File requires
    `-phase-plan.md` / `handoff-phase` paths, template fields including `phase_id`,
    `hunt_stem`, `plan_path`, `route`, `items`, `goal`, `exit_metrics`, `lock`,
    `invocation_hint`, and exit metrics `closed_count` / `residual_criticals` / `signoff`:
    `rg -n 'M44|M47|handoff-phase|exit_metrics|residual_criticals' specs/core/SPEC-034-bug-hunt-workflow.md`
    matches.
25. **T25 — M45/M46 route + lock forms.** File requires `/orchestrate` default,
    `/epic` when `phase_count ≥ 2` and `item_count ≥ 2`, and lock forms `--start-phase` or
    typed `start-phase-<n>`:
    `rg -n 'M45|M46|start-phase|phase_count' specs/core/SPEC-034-bug-hunt-workflow.md` matches.
26. **T26 — M48 phase-done + zero + emit-only walls.** File requires M23 concrete handoff
    phase-done (including zero path), emit-only, and N12/N13 walls:
    `rg -n 'M48|N12|N13|emit-only|phase-done' specs/core/SPEC-034-bug-hunt-workflow.md` matches.

---

## Validation

- [ ] **AC1** — Spec path `specs/core/SPEC-034-bug-hunt-workflow.md`; Status DRAFT; bug-hunt
      title; category core; See also 013/009/014/025/017
- [ ] **AC2** — `/bug-hunt`; optional path (default project root); `--severity-floor`
      `critical|warning|nitpick`; flag omitted → default `nitpick` (M3); loud fail on invalid
      (M1–M5)
- [ ] **AC3** — Stages 1–4; locks: materialize proceed, start fix-phase 0, between fix phases;
      NOT between discover↔refute (M6–M9)
- [ ] **AC4** — Confirmed fields: locator, severity, description, evidence, status=confirmed;
      candidates may be candidate|refuted; only confirmed materializes (M10–M13)
- [ ] **AC5** — Non-goals: not `/debug` replacement; no auto-fix/auto-advance across locks;
      no parallel ticket lifecycle (M27–M29, N1–N2, N5, N7)
- [ ] **AC6** — Compose SPEC-013, SPEC-009 `/backlog`, `/orchestrate` and/or `/epic` (M16–M19)
- [ ] **AC7** — Phase-done metrics for discover, refute, materialize, handoff (M20–M23)
- [ ] **AC8** — Open Questions empty or product-only residual; closed OQ1–5 live in MUST
- [ ] **AC9** — User-visible: findings plan, bh-quality backlog items, phase handoff templates,
      hunt resume identity; process under `.claude/` uncommitted (M24–M25)
- [ ] **AC10** — When-to-use matrix covers `/bug-hunt`, `/debug`, `/council --blind`,
      `/backlog`, `/epic`, `/orchestrate` (M26)
- [ ] **AC11** — Below-floor never materialize by default; discover MAY list dropped (M14–M15)
- [ ] **AC12** — OOS: implement/fix inside discover–refute; silent mass-create; auto-start next
      fix phase; replacing `/debug ticket` (M30, M35–M37, N1, N6)
- [ ] **AC13** — Stages 1–2 runtime: report under `.claude/bug-hunt/` (M31); confirmed-actionable
      = confirmed ∧ ≥floor (M32); discover = SPEC-013 blind compose (M33); refute = ≥2
      investigators per candidate, no leftover candidate (M34)
- [ ] **AC14** — Stage 3 runtime: load json preferred / report fallback, loud fail both missing
      (M38); plan path `…-plan.md` before any backlog create (M39); SPEC-009 programmatic
      write-back + bidirectional linkage + bh-quality body (M40); proceed flag or typed token;
      idempotent re-materialize; zero-actionable → 0 creates (M41); no re-S1/S2, no stage-4/fix
      (N10–N11)
- [ ] **AC15** — Stage 4 runtime: load C3 `-plan.md`; phaseable = materialized|skipped_linked +
      slug (M42); severity bands critical→warning→nitpick, omit empty, renumber 0..N (M43);
      phase-plan + handoff-phase-N with template fields + hunt_stem/plan_path (M44); route
      orchestrate default / epic iff phase_count≥2 ∧ item_count≥2 (M45); lock `--start-phase <n>`
      or typed `start-phase-<n>` (M46); exit metrics closed_count / residual_criticals=0 / signoff
      (M47); M23 full + zero path; emit-only (M48); N12–N13 walls
- [ ] **OQ1 lock** — Severity enum `critical|warning|nitpick`; July HIGH→critical,
      MEDIUM→warning, LOW→nitpick (M13)
- [ ] **OQ2 lock** — Path optional; default project root (M2)
- [ ] **OQ3 lock** — Explicit proceed before materialize (M8)
- [ ] **OQ4 lock** — Handoff `/orchestrate` default; `/epic` multi-wave multi-ticket DAG (M18)
- [ ] **OQ5 lock** — Advanced Live note only; not C1 ship bar (Overview + S4)

---

## Open Questions

None at DRAFT — all product choices for this contract are locked in MUST (OQ1–OQ5 closed).
Status remains DRAFT until a later epic promote (not a C2 ship gate).

---

## Version History

| Date | Change |
|------|--------|
| 2026-08-07 | CDT-139: additive stage-4 runtime MUSTs M42–M48 (load C3 plan + phaseable filter, severity banding omit-empty renumber, phase-plan + handoff-phase templates, M18 route rule phase_count≥2∧item_count≥2, M9 lock forms `--start-phase`/`start-phase-<n>`, exit metrics, M23 full+zero + emit-only); N12–N13 hard walls; Covers/Overview stage 4 owned by CDT-139; Tests T22–T26 + Validation AC15; Status stays DRAFT |
| 2026-08-07 | CDT-138: additive stage-3 runtime MUSTs M38–M41 (load json/report, findings plan `-plan.md` path, SPEC-009 programmatic write-back + bidirectional linkage, proceed forms + idempotent re-materialize + zero path); N10–N11 hard walls; Covers/Overview stage 3 owned by CDT-138 (stage 4 still uncovered); Tests T18–T21 + Validation AC14; Status stays DRAFT |
| 2026-08-06 | CDT-136: additive stages 1–2 runtime MUSTs M31–M34 (report path, confirmed-actionable floor filter, discover/refute SPEC-013 compose); renumber prior OOS M31–M33 → M35–M37; Covers → `commands/bug-hunt.md`, `skills/bug-hunt/*`; Tests T12–T16 + Index T17; Status stays DRAFT |
| 2026-08-06 | CDT-140: DRAFT created — bug-hunt product contract (surface, stages/locks, finding model, floor, composition, phase-done metrics, outputs, when-to-use matrix, non-goals) |
