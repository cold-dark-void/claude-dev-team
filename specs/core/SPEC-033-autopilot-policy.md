# SPEC-033: Shared Autopilot Policy Contract

**Status**: DRAFT
**Category**: core
**Created**: 2026-08-04

**Covers**: `skills/autopilot/SKILL.md` (contract home). Future citers (wired by later CDT-111 children, NOT this ticket): `skills/orchestrate/SKILL.md`, `skills/kickoff/SKILL.md`, `skills/epic/SKILL.md`.

---

## Overview

Every orchestration workflow in this plugin halts at human-interactive **gates** — points
where the flow prints a summary and *waits for user input* before proceeding.
`/orchestrate` has three such gates (scope-confirm, plan-approve, ship-choice); **this triad
is `/orchestrate`'s structure specifically.** `/kickoff` and `/epic` have differently-shaped
checkpoints that do **not** map one-to-one onto those three names — the policy handles each
per command rather than forcing a false 3×3 mapping (AC1 / M5). **Autopilot** is the opt-in mode in
which those waits are replaced by an agent that **auto-answers each gate** so a workflow can
run unattended — *unless* a defined blocking condition fires, at which point autopilot
**halts and escalates to the human** rather than guessing.

The single most important framing:

> Autopilot replaces every "**Wait for user**" with "**auto-answer the gate, unless a
> blocking condition fires**." It never removes a gate; it changes who answers it and
> records why.

This spec defines the **shared policy** so that all three workflows obey one contract
instead of each inventing its own auto-answer rules. It specifies: the per-gate answering
checklists plus per-command checkpoint handling (AC1), the ordered set of blocking conditions
(AC2), run-budget defaults (AC3),
the complexity-overflow → `/epic` reroute criteria (AC4), the contract-home rule (AC5), and
the decision-card audit schema (AC6), and the council ship-gate pass (AC7).

This ticket (CDT-111-C1) writes **only the contract** — the spec plus its operational copy
in `skills/autopilot/SKILL.md`. Wiring the workflows to consult it, and building the
decision-card writer script, happen in later CDT-111 children (C2–C10). No workflow file is
edited here.

**Contract-home rule (SPEC-002 D1).** This SPEC *defines* the policy; `skills/autopilot/SKILL.md`
*carries the one operational copy*; `/orchestrate`, `/kickoff`, and `/epic` (when later wired)
MUST **cite** SPEC-033 / the autopilot SKILL and MUST NOT restate or fork the policy. There is
no literal anchor edit inside SPEC-002 — "SPEC-002 D1" is this codebase's citation-convention
shorthand (as used by SPEC-015 / SPEC-009 / SPEC-031-DRAFT), not a physical section.

**Boundaries & related specs:**
- **SPEC-009 (ticket workflow) / `skills/orchestrate/SKILL.md`** own the interactive gate
  *definitions* and the pre-existing interactive escalation triggers (Step 8 "stuck after 2
  genuine attempts", Step 9 "3+ review-round deadloop", scope-creep). Autopilot is **additive**:
  it does not modify, replace, or renumber any of those. It layers an auto-answer + halt policy
  on top of the same gates.
- **SPEC-026 (outcomes / stint counters)** owns the session-local `review_cycles` and
  `qa_bounces` counters. Autopilot **reads** those counters; the autopilot QA counter (blocking
  condition 2) is a **new, separate** threshold check over `qa_bounces`, not a change to how the
  counter is incremented.
- **SPEC-025 (`/epic`)** owns umbrella decomposition. Autopilot's complexity-overflow condition
  **reroutes into** `/epic` decompose; it does not re-implement decomposition.
- **`/release` bump vocabulary** (`patch`/`minor`/`major`) is the single source of truth for
  version bumps. Autopilot's `--autopilot=<bump>` and the decision-card `bump` field **reference**
  that vocabulary; they MUST NOT define a second bump taxonomy.
- **SPEC-031 (escalation gate hook, DRAFT)** is a `PreToolUse` edit-gate. Autopilot does **not**
  edit any SPEC-031 file. The decision-card schema (AC6) is only *forward-compat*: it carries a
  stable discriminator so a future SPEC-031-family hook could recognize and parse it.

**Out of scope (this ticket):** any workflow wiring, the `--autopilot` argument parser, the
escalation/notify sink, and any SPEC-031 hook change. All are later CDT-111 children. The
decision-card *writer/reader* now ship as `skills/autopilot/append-card.sh` /
`skills/autopilot/read-cards.sh` (**CDT-111-C2**). This ticket freezes the *contract surface*
(checklists, conditions, budget numbers, schema, paths) so those children build against a fixed
target.

---

## MUST

### Mode activation

- **M1 — Opt-in, default off.** Autopilot MUST be inactive unless explicitly requested via the
  `--autopilot` argument or `AUTOPILOT=1` in the environment. When inactive, every gate MUST
  remain fully human-interactive with **no behavior change** — this contract is a pure superset.
- **M2 — Bump vocabulary is borrowed, not owned.** `--autopilot=<bump>` MAY carry a `/release`
  bump token (`patch` | `minor` | `major`). Autopilot MUST treat that token as a reference to the
  `/release` vocabulary and MUST NOT define, extend, or reinterpret bump semantics. Absent a
  token, autopilot MUST NOT auto-release; its default ship action is bounded by the ship-choice
  checklist (M4).

### AC1 — Per-gate answering checklist

- **M3 — Gate coverage.** The policy MUST define an answering checklist for each of
  `/orchestrate`'s three gates, identified by these canonical gate names:
  `scope-confirm`, `plan-approve`, `ship-choice`. These three names describe **`/orchestrate`'s
  structure** — the one workflow the triad fully fits. `/kickoff` and `/epic` are covered by M5,
  which maps their real checkpoints honestly rather than pretending they share this structure.
- **M4 — Per-gate checklists.** For each gate, autopilot MUST evaluate the checklist below **in
  order** and, only if no blocking condition (M6) fires, emit the stated default answer:

  - **`scope-confirm`** (orchestrate Step 2 "first escalation gate"; the flow otherwise waits on
    *"Proceed with this scope?"*). Default answer: **`proceed`**. Checklist:
    (Evaluated in the canonical BC1→BC8 ordinal order, first-match-wins, dropping BCs that
    don't apply to this gate — matching M6's global evaluation order.)
    1. Is the issue text sufficient to fix scope without guessing? → else BC1 (ambiguity).
    2. Does the scope imply any destructive/irreversible operation? → BC3.
    3. Does assessed complexity fit one ticket, or is it an overflow? → BC5 reroute (AC4).
    4. Is the run within budget? → BC6.
    5. Am I confident in `proceed`? → else BC7.
  - **`plan-approve`** (orchestrate Step 6 "second escalation gate"; waits on *"Approve this
    plan?"*). Default answer: **`approve`**. Checklist:
    (Evaluated in the canonical BC1→BC8 ordinal order, first-match-wins, dropping BCs that
    don't apply to this gate — matching M6's global evaluation order.)
    1. Does every plan task carry concrete file paths **and** a verification step? → else BC1.
    2. Does any task perform a destructive/irreversible operation? → BC3.
    3. Is the projected change within the LOC soft-cap and per-file size cap? → BC4.
    4. Does the plan's task graph exceed the single-ticket bound? → BC5 reroute (AC4).
    5. Budget (BC6) and confidence (BC7).
  - **`ship-choice`** (orchestrate Step 11; waits on *"Options: 1 Create PR / 2 Show diff /
    3 Review manually"*). Default answer: **`pr`** (Create PR — the reviewable, reversible option).
    A squash-merge (`merge`) MUST NOT be auto-selected unless `--autopilot=<bump>` was supplied
    (explicit ship intent). The `merge` decision-card value corresponds to `/orchestrate`'s
    separate **"If squash merge requested"** branch (Step 11's later squash path), **not** a
    numbered option in the Step-11 menu (which offers only Create PR / Show diff / Review manually).
    Checklist (evaluated in canonical BC1→BC8 ordinal order, first-match-wins):
    1. Did Step-10b spec-alignment pass (else BC1 — a code/AC mismatch is a now-provably-unresolved
       scope/plan question) **and** did QA reach PASS (BC2 not already tripped)? → else halt.
    2. Is the ship action more irreversible than a PR (direct merge to a protected branch,
       force-push)? → BC3. **BC3 is evaluated unconditionally, even when `--autopilot=<bump>` was
       supplied** — the bump flag only satisfies "explicit ship intent" for `decision=merge`; it
       never exempts BC3.
    3. Budget (BC6) and confidence (BC7).

- **M5 — The three-gate scheme fits `/orchestrate` only; `/kickoff` and `/epic` are handled per
  command.** The `scope-confirm` / `plan-approve` / `ship-choice` triad (M3/M4) describes
  **`/orchestrate`'s structure specifically**. `/kickoff` and `/epic` do **not** have a clean
  one-to-one mapping onto those three names, and the policy MUST NOT force a false 3×3 mapping.
  Instead the policy records, per command, which real checkpoints autopilot answers, which are
  **content-bearing** (halt — not self-answerable), and which have **no analog**. The honest
  mapping (verified against `skills/kickoff/SKILL.md` and `skills/epic/SKILL.md`):

  | Canonical gate | `/orchestrate` | `/kickoff` | `/epic` |
  |---|---|---|---|
  | `scope-confirm` | Step 2 (first escalation gate) — self-answerable | **No approval-gate analog.** Step 3 "resolve open questions" is the nearest pause but is **content-bearing** (needs answers, not yes/no) → blocking condition (BC1), never self-answer | A.5 approval gate, **scope half** (problem + ACs) — evaluated; **and** B.3 per-child handoff confirm, which **is** a repeated scope-confirm (per child, before any work) |
  | `plan-approve` | Step 6 (second escalation gate) — self-answerable | **Does not exist.** Step 6 (TL plan) flows straight into Step 7 (TaskCreate); no "approve this plan?" prompt. Adding one is a **new gate** — a design decision **out of scope** here | A.5 approval gate, **plan half** (estimate / agent / depends_on / waves) — evaluated jointly with the scope half; **single atomic verdict** |
  | `ship-choice` | Step 11 (ship options) — self-answerable, defaults to PR | **N/A** — `/kickoff` ends at the task graph and never ships | **N/A** — `/epic` never ships (M11: no code, no worktrees, no IC spawns); each child's real ship-choice lives **inside its own delegated `/orchestrate` Step 11** |

  Notes the policy MUST record:

  - **(a) `/orchestrate` is the only workflow the three-gate scheme fully fits.** State this
    outright; do not paper over the gaps with an invented mapping.
  - **(b) `/kickoff` has no self-answerable approval gate.** Its Step 3 open-questions pause is
    content-bearing — autopilot cannot answer it without **fabricating requirements**, so it is a
    blocking condition (BC1 / M8), not a gate autopilot proceeds through. Its Step 4b
    **"GATE 1 (API verification)"** is its own blocking condition (**BC8** — M6.8). `/kickoff` has
    neither a `plan-approve` nor a `ship-choice` gate; autopilot MUST NOT synthesize either.
  - **(c) `/epic` A.5's verdict is atomic.** The scope half and plan half are separable **for
    evaluation** (autopilot runs both checklists), but the source verdict is atomic:
    **decline = zero writes; approve = both scope and plan persisted.** There is no source-legal
    "approve scope, reject plan" outcome. Under autopilot the single answer is `approve` iff
    **both** halves pass every check; any half's blocking condition halts the whole gate. Autopilot
    also **forfeits** A.5's interactive "user may edit / merge / remove children" affordance — it
    can only approve-as-presented or halt; it MUST NOT silently drop or rewrite a proposed child.
  - **(d) `/epic` A.6 execution-mode default = `orchestrate`.** A.6 persists a once-chosen
    execution mode (`kickoff` | `orchestrate`) to `state.json`. Under autopilot the default MUST be
    **`orchestrate`**, because `kickoff` mode dead-ends every child at B.5's human-only completion
    attestation (note f) — choosing it would guarantee an immediate halt at each child, defeating
    unattended execution.
  - **(e) `/epic` B.3 is a repeated scope-confirm, not a ship-choice.** B.2 takes `head -1` of the
    ready set, so B.3 fires **per child**, and prints the same content shape as orchestrate Step 2
    (title / problem / ACs / estimate / agent / deps) **before any work starts**; answering `y`
    starts planning and ships nothing. Autopilot answers it with the `scope-confirm` checklist.
    Mapping it to `ship-choice` would make autopilot block at **every** child, defeating the point.
  - **(f) `/epic` B.5 kickoff-mode completion is a truth attestation — never self-answered.** In
    `kickoff` mode a child is marked `completed` only when the user confirms real completion
    ("never auto on plan file alone"). This is an **attestation of fact**, not an approval;
    autopilot MUST NOT self-answer it under any circumstances (N8). With the A.6 `orchestrate`
    default this rarely arises, but the prohibition is absolute.
  - **(g) Out of scope:** `/epic` Mode E `--redecompose` confirm is an explicitly user-invoked
    flag; autopilot does not spontaneously redecompose, so it is out of scope for this contract.

### AC2 — Blocking conditions

- **M6 — Eight blocking conditions, in evaluation order.** At every gate, before emitting the
  default answer, autopilot MUST evaluate these conditions **in this order** and act on the first
  that matches. Seven are **hard-blocking** (halt + escalate to human); one (BC5) is
  **non-blocking** (self-reroute). This list is the complete set — autopilot MUST NOT invent
  additional auto-halt conditions.

  1. **Genuine ambiguity** — a scope/plan question that remains unresolved *after* an honest
     resolution attempt against the repo, the specs, and project memory. Ambiguity that memory or
     specs *do* answer is not a blocker. → **halt**.
  2. **QA failure past 3 bounces** — a **new autopilot-specific** threshold: when SPEC-026's
     `qa_bounces` for any task reaches **3**, autopilot halts. This counter is **separate from and
     additive to** `/orchestrate`'s pre-existing interactive triggers (Step 8 "stuck after 2
     genuine attempts", Step 9 "3+ review-round deadloop"); it does **not** replace them, and
     those continue to fire independently. → **halt**.
  3. **Destructive / irreversible operation** — the gated action would delete/overwrite user data,
     force-push, merge to a protected branch, drop a table, `rm -rf` outside the worktree, rewrite
     shared history, or otherwise be non-trivially reversible. → **halt**.
  4. **LOC soft-cap / file-size breach** — the projected or actual change exceeds the SPEC-009
     change-discipline bounds (~1000 LOC soft / 2000 LOC hard per PR; no single file > 1000 lines).
     → **halt**.
  5. **Complexity overflow** — the work meets the AC4 overflow criteria. This is the **only
     non-blocking** condition: autopilot MUST NOT halt for a human; it MUST **reroute to `/epic`**
     decompose (recording a `reroute-epic` decision-card) and continue autonomously. → **reroute**.
  6. **Run-budget breach** — the run exceeds an AC3 budget cap (iteration or wall-clock). → **halt**.
  7. **Self-uncertainty** — in the gate-answering step itself, autopilot's confidence in the
     default answer is below the confidence threshold (AC6 `confidence` < 80, mirroring the council
     default). An honest "I'm not sure" MUST halt rather than proceed. → **halt**.
  8. **Unverified external dependency** — the `/kickoff` Step 4b **"GATE 1 (API verification)"**
     analog: an external API parameter, SDK/library flag, model capability, endpoint behavior, or
     config flag that a **confirmed AC depends on** verifies `IGNORED`, `DECORATIVE`, or `UNKNOWN`.
     Source forbids auto-proceeding: *"Do NOT silently design around an unproven capability."* This
     is **distinct from BC1**, not a variant of it: a `DECORATIVE`/`IGNORED` verdict is a
     **resolved-negative** (the capability was proven *not* to work), not unresolved ambiguity — so
     BC1, whose own text says ambiguity that specs/memory *do* answer "is not a blocker," would
     mis-classify a resolved-negative as "resolved → proceed," the exact wrong outcome. The required
     human decision — drop/rework the AC, or proceed explicitly-marked-unverified — is a **product
     decision** autopilot MUST NOT self-answer. Fires only in `/kickoff`'s pre-spec phase (like BC2,
     which fires only in the IC/QA loop, a phase-scoped condition is consistent with M6). → **halt**.

- **M7 — Halt semantics.** On any hard-blocking condition, autopilot MUST: (a) stop before taking
  the gated action, (b) write a `halt` decision-card (M13) naming the ordinal blocking condition,
  and (c) surface the halt to the human via the workflow's escalation path. Autopilot MUST NOT
  proceed past a hard block on its own. Halts MUST be **non-destructive**: no partial ship, no
  merge, no irreversible side effect is performed at or after a halt.
- **M8 — Interactive-trigger mapping.** Under autopilot, any point where the underlying workflow
  would interactively "wait for user" for a reason **not** in M6 (e.g. Step 8 stuck-after-2,
  Step 9 deadloop, scope-creep) MUST also resolve via the closest M6 condition (it cannot wait on
  an absent human) — **halt-and-escalate for the hard-blocking mappings, or reroute for the BC5
  branch** — recording that ordinal in the decision-card (`stuck` → BC1 halt; `deadloop` → BC1
  halt; scope-creep → **BC5 reroute** if it is an overflow, else BC1 halt). `/kickoff`'s own interactive pauses
  map likewise: **Step 3 open-questions** and the **>4-open-questions pause** → BC1 (content-bearing;
  autopilot cannot answer without fabricating requirements); a **breaking-schema-change pause** →
  BC3 (irreversible-change class). (`/kickoff` Step 4b "GATE 1" is *not* an M8 mapping — it is its
  own first-class BC8.) This mapping preserves the additive contract with M6.2: the autopilot QA
  counter is a distinct third counter, not a merge of the Step-8/Step-9 triggers.

### AC3 — Run-budget defaults

- **M9 — Two budget caps with concrete defaults.** The policy MUST define a per-run budget with
  two caps and these default values (env-overridable):

  | Cap | Default | Env override | Counts |
  |---|---|---|---|
  | `iteration_cap` | **25 stints** | `AUTOPILOT_ITERATION_CAP` | one **stint** per agent spawn inside the run: each IC task attempt, each Tech-Lead review round, each QA run, and the PM/TL kickoff spawns |
  | `wall_clock_cap` | **45 minutes** (2700 s) | `AUTOPILOT_WALLCLOCK_CAP` | elapsed time from autopilot run start |

  Rationale (recorded normatively so later tuning has a baseline): a healthy L-sized ticket runs
  ~10–15 stints and 10–25 min under parallel agents; the defaults give ~2× headroom before
  declaring a runaway, balancing "autopilot stalls constantly" against "unattended runaway".
  **Scope of a run:** `/orchestrate` = one ticket. `/epic` = per-child budget applies to each
  child's own `/orchestrate` run; the epic-level walker adds its own decompose iteration budget
  and MUST NOT let a single child's breach silently consume the whole epic (each child's BC6 halt
  is child-scoped). Breaching either cap trips **BC6** (M6.6). A single shared default suffices
  across workflows — no per-command budget override is needed: `/kickoff` and `/epic` Mode A are
  short flows (~2–6 stints: PM/TL/explorer/verify spawns) that sit far under the cap, and per-child
  `/orchestrate` carries the orchestrate budget. Note that `/kickoff` and `/epic` have *fewer*
  self-answerable gates (M5), so autopilot tends to **halt earlier** on a blocking condition there —
  which lowers, not raises, budget pressure. The 25-stint / 45-min defaults therefore stand
  unchanged for all three workflows.

- **M9a — Wall-clock budget basis on resume (CDT-111-C8).** M9's `wall_clock_cap` counts elapsed
  time from run start; on a **resumed** paused/interrupted run that start is measured
  **synthetically**, not literally. When CDT-111-C8's `resume-state.sh` resumes a run, the
  `run_start_epoch` fed to `budget-check.sh` is `now − accumulated_active_seconds`, where
  `accumulated_active_seconds` is derived from prior decision cards' `budget.wall_clock_s` for that
  ticket (via `read-cards.sh`) — **not** the literal original wall-clock start. This basis closes
  two failure modes: **(a)** resetting the epoch fresh on every resume would let repeated
  pause/resume cycling bypass BC6's 45-min anti-runaway cap entirely; **(b)** carrying the raw
  original epoch forward unmodified would immediately trip BC6 the instant a legitimate multi-hour
  human-review pause (the exact scenario C6's escalation and C7's notify exist to enable) resumes —
  punishing the human for taking time to respond. Refines M9's `wall_clock_cap` measurement only;
  introduces no new persistence field and does not modify or duplicate M11a.

### AC4 — Complexity-overflow → `/epic` reroute criteria

- **M10 — Overflow criteria.** Complexity **overflow** (the BC5 trigger's underlying definition)
  is met when **any** of the following holds at `scope-confirm` or `plan-approve`:
  1. Projected total change exceeds the SPEC-009 **hard** cap (> 2000 LOC) across the ticket; or
  2. The work naturally decomposes into **3 or more independently shippable workstreams**
     (distinct PR-able units with no shared change surface); or
  3. The plan's task graph would exceed **~8 tasks across multiple parallel waves** (mirrors
     `/epic`'s ">8 children → probably two epics" soft-warn); or
  4. The work requires **more than one distinct spec / contract home** (a signal of multiple
     independent concerns); or
  5. It touches **3 or more independent subsystems** with no common change surface; or
  6. The estimated single-run wall-clock would exceed the AC3 `wall_clock_cap` even with full
     parallelism.
- **M11 — Reroute is non-blocking and reversible.** On overflow, autopilot MUST record a
  `reroute-epic` decision-card and hand the ticket to `/epic` decompose **autonomously** (no human
  halt), because at scope/plan time no code has shipped — the reroute is fully reversible. The
  distinction M6.5 draws is deliberate: BC5 *references* this overflow condition as its trigger;
  M10 *defines* what overflow is. The `/epic` decompose it hands to then runs under this same
  autopilot contract (its A.5 gate auto-answered per M4/M5).

- **M11a — Mid-execution reroute safety + autopilot-state carry-forward (CDT-111-C6).** M11's
  "fully reversible" rationale assumes the reroute fires at `scope-confirm` / `plan-approve`, where
  no code has shipped. CDT-111-C6 wires a `/orchestrate` **Step-8 scope-creep** BC5 trigger that can
  fire **after** code has already shipped for one or more completed tasks. Two additive rules govern
  every `reroute-epic`:

  - **(a) Autopilot-state carry-forward (caller's obligation).** On any `reroute-epic`, the hand-off
    to `/epic` decompose MUST propagate autopilot enablement — the invocation MUST carry
    `--autopilot[=<bump>]` (or set `AUTOPILOT=1`). `/epic` **Step 0.5** resolves its own autopilot
    state **independently** from its own args/env and does **not** inherit the caller's session
    state; absent the explicit flag/env, `/epic` falls back to interactive human gates, silently
    breaking the unattended run. Carrying the state forward is the **caller's** (the wiring's)
    responsibility, **not** the `self-answer.md` engine's — the engine writes the `reroute-epic`
    card and returns (self-answer.md §5). Applies to **every** reroute-epic hand-off site.

  - **(b) Mid-execution reroute is delta-only — no rollback.** When BC5 fires at a checkpoint
    reached **after** code has already shipped for one or more completed tasks (the Step-8
    scope-creep trigger, as distinct from the pre-ship scope-confirm/plan-approve reroutes M11
    covers), the reroute MUST NOT discard, revert, or roll back already-completed task state:
    completed commits stay committed and their outputs are treated as **fixed prior art**. Autopilot
    hands **only the remaining and newly-discovered scope** — the delta that overflowed the
    single-ticket bound (M10) — to `/epic` decompose; the already-shipped work becomes a completed
    dependency/input to the decomposed epic, **never** part of the scope handed to decompose. This
    narrows M11's "reversible" claim for the mid-execution case: it is reversible in that no
    *further* work is forced and no completed work is destroyed — a **forward-decomposition of the
    residual scope**, not an unwind. The reroute stays non-blocking and autonomous (M11).

### AC5 — Contract home

- **M12 — New dedicated spec, single operational home.** This contract MUST live in this new
  dedicated spec (SPEC-033) and MUST NOT be added as prose inside SPEC-002. The **contract home**
  (the one operational copy) MUST be `skills/autopilot/SKILL.md`. `/orchestrate`, `/kickoff`, and
  `/epic` — when wired by later children — MUST cite SPEC-033 / the autopilot SKILL and MUST NOT
  define their own copy of the checklists, conditions, budget, or schema.

### AC6 — Decision-card schema

- **M13 — Decision-card schema.** Every gate answer, halt, and reroute MUST be recordable as a
  **decision card**: one append-only JSONL object per event at
  `$MROOT/.claude/autopilot/<TICKET-ID>.jsonl`. Mirroring the SPEC-001 M7 invariant for its own
  NDJSON ledger, this file is **append-only, local-only state**: NOT committed to git
  (`.claude/autopilot/` is git-ignored) and NEVER stored in `memory.db`. The schema is frozen here
  (C1 fixes the shape; the *writer/reader* ship as `skills/autopilot/append-card.sh` /
  `skills/autopilot/read-cards.sh` in **CDT-111-C2**):

  ```json
  {
    "schema_version": 1,
    "type": "autopilot_decision",
    "ts": "2026-08-04T12:00:00Z",
    "run_id": "<autopilot run id>",
    "workflow": "orchestrate | kickoff | epic",
    "ticket_id": "CDT-111-C1",
    "gate": "scope-confirm | plan-approve | ship-choice",
    "decision": "proceed | approve | pr | merge | reroute-epic | halt",
    "decided_by": "auto | user",
    "bump": "patch | minor | major | null",
    "confidence": 0,
    "blocking_condition": null,
    "rationale": "<one-line why>",
    "budget": { "iteration": 0, "iteration_cap": 25, "wall_clock_s": 0, "wall_clock_cap_s": 2700 },
    "actor": "orchestrator"
  }
  ```

  Field contract:
  - `type` (const `"autopilot_decision"`) **+** `schema_version` are the **stable discriminator
    envelope** a future SPEC-031-family hook keys on. Both MUST be present on every card. This is
    the sole AC6 forward-compat obligation — no SPEC-031 file is touched.
  - `gate` records the canonical gate name. Off-triad halt points (e.g. `/kickoff` Step 3/4b,
    `/orchestrate` Step 8/9 via M8, `/epic` A.5) have no gate of their own and MUST record the
    **closest** canonical gate name per the M5 mapping table / M8 mapping — e.g. a `/kickoff`
    Step-3 BC1 halt records `gate:"scope-confirm"` (M5 maps kickoff's nearest checkpoint to
    scope-confirm). The enum stays the frozen 3-value set; no fourth value is invented.
  - `decision` is the gate's **actual answer** and is deliberately a **distinct field** from any
    council `verdict`. Reusing council-judge's verdict taxonomy (`VERIFIED | PARTIALLY_VERIFIED |
    UNVERIFIED | CONTRADICTED | FABRICATED`) for a gate answer would be a type error: a gate answers
    `proceed` / `approve` / `bump=patch`, not "verified". The card MAY carry council-style fields
    (`confidence`, `rationale`) but MUST keep `decision` separate so the answer is never conflated
    with a verification verdict.
  - `decided_by` records **who answered this gate**: `auto` when autopilot self-answered per its
    checklist with no blocking condition firing, or `user` when the card records a human's
    resolution after a halt (the human answered the question that triggered a
    BC1/BC3/BC4/BC6/BC7/BC8 halt, and this card captures their answer). It is orthogonal to
    `decision` (the answer itself) and to `actor` (which component *wrote* the card) — all three
    coexist. This matches the SPEC-001 M7 precedent, whose `directive-history.jsonl` already uses
    `decided_by ∈ user | auto` for exactly this user-vs-auto provenance.
  - `bump` is non-null **only** on a `ship-choice` card and MUST hold a `/release` token (M2);
    it MUST NOT introduce a bump value outside that vocabulary.
  - `confidence` (0–100) backs BC7; a card with `decision:"halt"` and `blocking_condition:7` MUST
    carry `confidence` below the threshold. Threshold default 80 mirrors the council convention.
  - `blocking_condition` is `null` for a clean answer, or the M6 ordinal (1–8) for a halt/reroute.
  - `rationale` is a one-line summary and MUST NOT contain secrets, credentials, tokens, keys, or
    PII. Any evidence quoted from the repo, specs, or memory (e.g. the S2 resolution attempt) MUST
    be **redacted or summarized**, never copied verbatim into the card.
  - `budget` snapshots the AC3 counters at decision time.
  - `actor` names the writer (e.g. `orchestrator`).

### AC7 — Council ship-gate pass (CDT-111-C5)

- **M14 — One adversarial council pass gates every auto-answered ship.** When autopilot's
  `ship-choice` checklist (M4) reaches a **clean, non-halt** answer (`decision ∈ {pr, merge}`,
  `blocking_condition = null`), autopilot MUST run **exactly one** adversarial council pass
  before the ship action is taken and record its outcome as **one additional** `ship-choice`
  decision card. It fires **only** at `ship-choice`, **only** on a clean `pr`/`merge` answer,
  and **exactly once** per ship-choice attempt — never at `scope-confirm` or `plan-approve`.
  The normative contract lives here and in the autopilot SKILL; the operational procedure
  lives in the new companion file `skills/autopilot/ship-gate-council.md` (peer to
  `self-answer.md`), which MUST NOT restate or fork this contract (SPEC-002 D1 / M12 / N4).

  - **(a) OQ3 resolved for `ship-choice` — council-derived confidence.** OQ3 asked whether
    `confidence` is self-reported or council-derived. For the `ship-choice` gate it is now
    **council-derived**; `scope-confirm` and `plan-approve` keep OQ3's original self-reported
    latitude. Autopilot MUST invoke bare `/council "<claim>"` (scope `claim`, preset `generic`,
    **unbound** — **no** `--plan`, **no** `--task-id`, no other flag). The claim string carries
    **locators only**: `ticket_id`, the decision-card ledger path (for
    `skills/autopilot/read-cards.sh`), the spec/AC path(s), and a one-line ship claim.
    Investigators pull all evidence themselves via their own tool calls; autopilot MUST NOT
    render, pre-digest, or pass a materialized evidence file, and MUST NOT add any
    render-helper script.

  - **(b) Verdict → confidence → BC mapping (normative).** The council's per-claim verdict
    maps to the second `ship-choice` card as follows. First set `confidence`:
    `VERIFIED` / `PARTIALLY_VERIFIED` → `confidence` = the council's reported confidence
    (0–100); `UNVERIFIED` / `CONTRADICTED` / `FABRICATED` → `confidence = 0`. Then decide on
    that `confidence`:
    - `confidence ≥ 80` (**agree**) → `decision` = the **original** ship-choice card's decision
      (`pr` or `merge`), `bump` copied from that original card, `blocking_condition = null`.
    - `confidence < 80` (**disagree**) → `decision = halt`, `blocking_condition = 7`,
      `bump = null`.
    This confidence feeds **BC7 only — never BC1.** A disagreeing / `UNVERIFIED` council verdict
    is a **resolved-negative** (the ship claim was investigated and *not* upheld), which BC1 —
    whose own text (M6.1) says ambiguity that specs or memory *do* answer "is not a blocker" —
    would mis-classify as "resolved → proceed", the exact wrong outcome. This is the same
    resolved-negative precedent M6.8 (BC8) invokes to stay distinct from BC1. A sub-80 council
    confidence **is** autopilot's confidence in the ship answer falling below the M6/M13
    threshold, so BC7 (self-uncertainty) is its correct home.

  - **(c) Not a ninth blocking condition.** This pass MUST NOT introduce a 9th blocking
    condition; M6's set of eight is complete. The council pass **reuses BC7** with an alternate,
    **council-derived** confidence source **for the `ship-choice` gate only** — every other
    gate's BC7 keeps its self-reported source. The council outcome is recorded as a **second**
    `ship-choice` card sharing the **same `run_id`** as the original; the original card is
    **never revised** (M13 append-only). A ship-choice attempt therefore records **exactly two**
    cards.

  - **(d) Degraded-run rule (normative).** If the council's own SPEC-013 spawn-failure
    degradation yields a **fully self-verified** run — no independent peer investigator/refuter
    survived, surfaced by report frontmatter `verification_mode: self-verified` and the exact
    body marker `self-verified — refuters unavailable` — autopilot MUST treat the outcome
    **identically to a `confidence < 80` disagreement** (`decision = halt`,
    `blocking_condition = 7`, `bump = null`) **regardless of that self-verified run's own
    reported confidence.** Because this is a BC7 card, `confidence` MUST be written **below the
    M13 threshold**: autopilot MUST write `confidence = 0` (not the self-verified run's reported
    value, which may be ≥ 80 and would violate `append-card.sh` cross-field invariant (b), a
    hard exit-64). The card's `rationale` MUST cite `self-verified — refuters unavailable` as
    the halt reason. A **total council spawn failure** (no usable report at all) is treated the
    same: `halt`, BC7, `confidence = 0`, rationale naming the spawn failure. An adversarial
    ship-gate whose adversaries never ran provides **no** independent assurance; the council
    verdict can only push a ship **down** to a BC7 halt, **never** raise it above BC7.

---

## SHOULD

- **S1** — The escalation surfaced on a halt SHOULD include the decision-card `rationale` and the
  named blocking condition so the human can resolve it without re-deriving state.
- **S2** — Autopilot SHOULD attempt genuine ambiguity resolution (repo → specs → memory) and
  record the attempt in `rationale` before declaring BC1; a bare "unclear" is insufficient.
- **S3** — The `run_id` SHOULD be stable for the lifetime of one autopilot invocation so all cards
  for a run correlate, and SHOULD be derivable without external state (e.g. start-epoch).
- **S4** — When `--autopilot=<bump>` is supplied, the `ship-choice` card SHOULD record the bump
  even when the chosen `decision` is `pr` (the bump travels with the eventual release).

---

## MUST NOT

- **N1** — MUST NOT remove, skip, or renumber any existing interactive gate or escalation trigger;
  autopilot only changes *who answers* and *records why*.
- **N2** — MUST NOT proceed past a hard-blocking condition (M6.1–4, 6–8) without a human.
- **N3** — MUST NOT auto-select a destructive ship action (squash-merge, force-push, protected-branch
  merge) — `ship-choice` defaults to PR; `merge` requires explicit `--autopilot=<bump>`. The bump
  flag only satisfies "explicit ship intent" for `decision=merge`; it **never** exempts BC3, which is
  evaluated **unconditionally** even when `--autopilot=<bump>` is supplied. A protected-branch merge or
  force-push still halts under BC3 regardless of the bump flag.
- **N3a — Deterministic BC3 push-target check for the autopilot release action (CDT-111-C9).**
  N3's "protected-branch merge / force-push still halts under BC3, evaluated unconditionally"
  governs autopilot performing a **raw, self-selected destructive git operation** against a
  protected ref — a direct `git push` / force-push to a protected branch, a history rewrite, or
  a merge that mutates a protected ref outside the release contract. It does **not** describe the
  `decision=merge` release action, which (i) is authorized by an explicit `--autopilot=<bump>`
  ship token, (ii) is gated by the M14 council pass, (iii) stages via `git merge --squash` —
  which moves **no** ref and creates **no** commit, fully reversible with `git reset` /
  `git merge --abort` — and (iv) delegates the sole ref-mutating step (commit + tag + push) to
  `/release`, the repo's single ship-of-record with its own pre-commit gates.

  For that action BC3 is **still evaluated unconditionally** (N3 unchanged), but its evaluation
  is **mechanical, not judgment**: before invoking `/release`, autopilot MUST resolve the push
  target deterministically via `git symbolic-ref refs/remotes/origin/HEAD` (or equivalent) and
  confirm it equals the branch `/release` will push. BC3 **halts** iff that check fails —
  `origin/HEAD` is unresolvable, the resolved default branch does not match the release target,
  the ship would require a force-push, or the target is a protected branch **other than** the
  verified origin default. A passing mechanical check is a **deterministic BC3-clear, not a
  bump-based exemption**: BC3 ran, unconditionally, and returned a negative — fully consistent
  with N3's "the bump flag never exempts BC3." The bump token supplies ship *intent*, the
  mechanical check supplies ship *safety*, the M14 council pass supplies ship *assurance*; all
  three MUST hold for the release action to proceed. Fail-closed: an unresolvable `origin/HEAD`
  halts under BC3 (autopilot MUST NOT fall back to a network guess to proceed).

  The operational sequence lives in the companion procedure `skills/autopilot/end-state.md`
  (peer to `self-answer.md` / `ship-gate-council.md`), which MUST NOT restate or fork this
  contract (SPEC-002 D1 / M12 / N4).
- **N4** — MUST NOT define a second bump vocabulary or a second copy of any checklist/condition/
  budget/schema outside the contract home (M12).
- **N5** — MUST NOT edit SPEC-002 prose or any SPEC-031 file to satisfy this contract.
- **N6** — MUST NOT reuse the council `verdict` field as the gate answer; `decision` is distinct (M13).
- **N7** — MUST NOT fold the autopilot QA counter (BC2) into the Step-8/Step-9 interactive triggers;
  it is a separate, additive third counter.
- **N8** — MUST NOT self-answer `/epic` B.5's kickoff-mode completion confirmation; it is a truth
  attestation of *real* completion, not an approval, and MUST be left for the human (M5 note f). Nor
  may autopilot mark a child `completed` merely because `/kickoff` produced a plan file.

---

## Open questions (non-blocking; deferred to wiring children)

- OQ1 — Exact escalation/notify transport on halt (webhook vs. inline print) — owned by the wiring
  child, not this contract. **Resolved by CDT-111-C7:** halt escalations emit `task_blocked` and
  autopilot end-states (`pr`/`merge` success) emit `task_complete`, both via `/orchestrate`'s
  **Passive notifications → Tier B** helper (`skills/notify/webhook.sh`, fail-open); reuses the
  existing CDV-210 event enum — no new event, no new transport (AC3).
- OQ2 — Whether the epic-level walker gets its own aggregate budget distinct from the sum of child
  budgets — deferred until `/epic` autopilot wiring.
- OQ3 — Whether `confidence` is self-reported by the answering agent or derived from a council
  micro-check — the schema accommodates either. **Resolved for `ship-choice` by M14
  (council-derived); remains self-reported for `scope-confirm` / `plan-approve`.**
