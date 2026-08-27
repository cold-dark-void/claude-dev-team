# SPEC-033: Shared Autopilot Policy Contract

**Status**: DRAFT
**Category**: core
**Created**: 2026-08-04

**Covers**: `skills/autopilot/SKILL.md` (contract home), `skills/autopilot/parse-flags.sh`, `skills/autopilot/loc-exclude.sh`, `skills/autopilot/append-card.sh`, `skills/autopilot/read-cards.sh`, `skills/autopilot/self-answer.md`, `skills/autopilot/self-answer-scenarios.md`. Citers: `skills/orchestrate/SKILL.md`, `skills/orchestrate/steps/00-resolve.md`, `skills/kickoff/SKILL.md`, `skills/epic/SKILL.md`, `skills/scaffold-project/SKILL.md` (`.gitattributes` seed, CDT-223).

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
the complexity-overflow → `/epic` reroute criteria (AC4), the contract-home rule (AC5),
the decision-card audit schema (AC6), the council ship-gate pass (AC7), and the LOC
exclusion plus `--max-loc` override (AC8 / CDT-223).

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
  **version bumps**. Autopilot's `--autopilot=<token>` and the decision-card `bump` field
  **reference** that vocabulary for release tokens and **extend** it with exactly one
  non-release ship-intent sentinel `master` (CDT-195; land-no-release). Autopilot MUST NOT invent
  further tokens or redefine `/release` semantics for `patch`/`minor`/`major`. The sentinel
  `master` MUST NOT be passed to `/release`.
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
- **M2 — Ship-intent tokens: borrowed release bumps + one land-no-release sentinel (CDT-195).**
  `--autopilot=<token>` MAY carry either:
  1. a `/release` bump token (`patch` | `minor` | `major`) — **release ship intent**; or
  2. the non-release ship-intent sentinel `master` — **land-no-release** (squash-land onto the
     worktree baseline with **no** `/release`).

  For (1), autopilot MUST treat the token as a reference to the `/release` vocabulary and MUST
  NOT redefine those bump semantics. For (2), `master` is a **flag-only ship-intent sentinel**,
  not a `/release` version: the decision-card records `bump:"master"`; the CLI spelling remains
  `=master`; and autopilot MUST NOT pass `master` to `/release`. Land git target under `master`
  is the worktree **baseline** (typically the branch named by `origin/HEAD`), **not** a
  hard-coded ref literally named `master`.

  Env (`AUTOPILOT=1`) enables autopilot only and MUST NEVER carry a bump or sentinel (including
  `master`) — ship-intent tokens are **flag-only**. Absent a token, autopilot MUST NOT
  auto-release and MUST NOT auto land-no-release; its default ship action is bounded by the
  ship-choice checklist (M4). Pure superset of existing bare and `=patch|minor|major` behavior.

  **Resume (ship mode):** bare `--resume-ship` re-reads the recorded mode (`autopilot_bump` /
  prior ship-choice card); an explicit `=master|patch|minor|major` on the resume invocation
  **overrides** the recorded mode.

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
    3. Is the projected **counted** (non-excluded, M15) change within the per-PR hard cap
       and the per-file size cap? → BC4. The ~1000 LOC soft cap is non-halting discipline
       (SPEC-009); it MUST NOT trip BC4.
    4. Does the plan's task graph exceed the single-ticket bound? → BC5 reroute (AC4).
    5. Budget (BC6) and confidence (BC7).
  - **`ship-choice`** (orchestrate Step 11; waits on *"Options: 1 Create PR / 2 Show diff /
    3 Review manually"*). Default answer: **`pr`** (Create PR — the reviewable, reversible option).
    A squash-merge (`merge`) MUST NOT be auto-selected unless `--autopilot=<token>` was supplied
    with a **non-null** ship-intent token (`patch` | `minor` | `major` | `master`) — explicit ship
    intent. **Non-null token ⇒ `decision=merge`** (including `master`). Release vs land-no-release
    is an **end-state branch on token class**, not a different ship-choice `decision`:
    - `bump ∈ {patch, minor, major}` → **release** end-state (N3a → squash-stage → `/release`);
    - `bump = master` → **land-no-release** end-state (N3a → squash → interactive-shape `git commit`
      on the baseline → non-force `git push` of the baseline → **no** `/release` → ship-history → Done).
    The `merge` decision-card value corresponds to `/orchestrate`'s separate **"If squash merge
    requested"** branch (Step 11's later squash path), **not** a numbered option in the Step-11
    menu (which offers only Create PR / Show diff / Review manually).
    Checklist (evaluated in canonical BC1→BC8 ordinal order, first-match-wins):
    1. Did Step-10b spec-alignment pass (else BC1 — a code/AC mismatch is a now-provably-unresolved
       scope/plan question) **and** did QA reach PASS (BC2 not already tripped)? → else halt.
    2. Is the ship action more irreversible than a PR (direct merge to a protected branch,
       force-push)? → BC3. **BC3 is evaluated unconditionally, even when `--autopilot=<token>` was
       supplied** — the token only satisfies "explicit ship intent" for `decision=merge`; it
       never exempts BC3 (force-push still BC3; intentional baseline land under `=master` is
       authorized only when the N3a mechanical check passes — same safety as release land).
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
  4. **LOC hard-cap / file-size breach** — the projected or actual **counted** change (M15)
     exceeds the per-PR hard cap or the per-file size cap. Default per-PR hard cap is **2000
     LOC**. Per-file cap is **1000 lines** on any counted file. The ~1000 LOC soft cap is
     **not** a BC4 halt. `--max-loc` (M16) may raise, tighten, or disable these as specified.
     BC4 fires **only** at `plan-approve`. → **halt**.
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
  1. Projected total **counted** change (M15) exceeds the per-PR hard cap across the ticket
     (default **> 2000 LOC**; `--max-loc=<n>` uses **n**; `--max-loc=unbound` **disables this
     criterion**). Evaluated at `scope-confirm` and `plan-approve`; or
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
    `--autopilot[=<bump>]` (or set `AUTOPILOT=1`). When `<bump>` ∈ {patch,minor,major},
    the caller MUST also pass `--worktree --release <bump>` (seal-intent). `/epic`
    **Step 0.5** resolves its own autopilot state **independently** from its own args/env
    and does **not** inherit the caller's session state; it MUST persist a release
    token as `release_bump` + `worktree_enabled` so children cannot land on master
    (CDT-196). Absent the explicit flag/env, `/epic` falls back to interactive human
    gates, silently breaking the unattended run. Carrying the state forward is the
    **caller's** (the wiring's) responsibility, **not** the `self-answer.md` engine's —
    the engine writes the `reroute-epic` card and returns (self-answer.md §5). Applies
    to **every** reroute-epic hand-off site.

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
    "bump": "patch | minor | major | master | null",
    "confidence": 0,
    "blocking_condition": null,
    "council_tier": null,
    "grading_reason": null,
    "max_loc": null,
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
  - `bump` is non-null **only** on a `ship-choice` card. Allowed non-null values are the
    `/release` tokens (`patch` | `minor` | `major`) **or** the land-no-release sentinel `master`
    (M2 / CDT-195). `master` is **not** a release version and MUST NOT be passed to `/release`.
    The field MUST NOT introduce values outside that set.
  - `confidence` (0–100) backs BC7; a card with `decision:"halt"` and `blocking_condition:7` MUST
    carry `confidence` below the threshold. Threshold default 80 mirrors the council convention.
  - `blocking_condition` is `null` for a clean answer, or the M6 ordinal (1–8) for a halt/reroute.
  - `council_tier` (**CDT-126**) records which council pipeline the M14 ship-gate pass was run
    at — `skip | light | full`, the vocabulary SPEC-013's **Council tiering** section owns. It is
    non-null **only** on the M14 council card (the second `ship-choice` card, M14(c)) and MUST be
    `null` on every other card, including the original `ship-choice` card #1. This spec MUST NOT
    define a second tier vocabulary (N4) — the values are SPEC-013's.
  - `grading_reason` (**CDT-126**) is a one-line record of *why* that tier was selected (band hit,
    triage-call reason, DRI flag, or the fail-closed cause). Same nullability rule as
    `council_tier`, and the same redaction obligation as `rationale`.
  - Both CDT-126 fields are **additive and nullable**, so `schema_version` stays `1`: the `type` +
    `schema_version` discriminator envelope is unchanged, readers that pin `schema_version == 1`
    keep parsing, and cards written before this amendment remain valid (absent key ≡ `null`).
    `skills/autopilot/append-card.sh`'s cross-field invariants need extending to cover them
    (`council_tier`/`grading_reason` non-null ⟹ `gate == "ship-choice"`); that writer change is a
    wiring child's work, not this contract's.
  - `max_loc` (**CDT-223**) records the `--max-loc` override for the run that wrote the card.
    Values: JSON `null` (omit / no override), JSON number `n` (positive integer), or JSON string
    `"unbound"`. It is **additive and nullable**; `schema_version` stays `1`; absent key ≡ `null`.
    `read-cards.sh` MUST backfill a missing `max_loc` as explicit `null` in frozen key order
    (immediately after `grading_reason`, before `rationale`). Legal on **every** gate (unlike
    `council_tier`). User provenance of the cap **is** the non-null `max_loc` field —
    `decided_by` stays `auto` on self-answer cards. When `max_loc` is non-null, `rationale`
    MUST mention the override. Every gate answer on a run with a non-null parse MUST record
    the parsed value; a run with omit MUST write `max_loc: null` on every card of that run.
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
    **unbound** — **no** `--plan`, **no** `--task-id`). The **sole** permitted flag is
    `--council-tier=<tier>`, required by **(e)**: it selects which council pipeline runs and
    does **not** bind the run to a task, a plan, or any other scope, so it leaves this bullet's
    unbound-and-locators-only intent intact. No other flag may be passed. The claim string carries
    **locators only**: `ticket_id`, the decision-card ledger path (for
    `skills/autopilot/read-cards.sh`), the spec/AC path(s), and a one-line **technical** ship
    claim (**CDT-185** — see process-stamp / narrow-claim rules below). Investigators pull all
    evidence themselves via their own tool calls; autopilot MUST NOT render, pre-digest, or pass
    a materialized evidence file, MUST NOT add any render-helper script, and MUST NOT inject
    RAW_ARTIFACTS or any other claim-body evidence payload. Locators-only is unchanged by the
    stamp split.

    - **Process stamps + narrow claim (CDT-185; Option 3).** Root failure mode: a compound
      ship claim that re-asserted process outcomes (e.g. `QA PASS`, `Step-10b … PASS`) for the
      council to re-prove produced systematic `PARTIALLY_VERIFIED` ~sub-80 → BC7, because those
      process facts live in the self-answer trail, not in code/spec evidence the investigators
      can re-derive. Fix: **pre-clear process via card #1 stamps; council audits technical
      readiness only.** Scope is **M14 ship-gate only** — no other `/council` caller inherits
      this stamp/claim rule.

      1. **Stamp set = clean ship-choice card #1.** The sole process stamp is the original
         self-answered `ship-choice` card in `$MROOT/.claude/autopilot/<ticket_id>.jsonl`,
         read via `skills/autopilot/read-cards.sh <ticket_id>`. QA PASS and Step-10b
         spec-alignment PASS are **implied by** the self-answer engine having written that
         clean card (M4 ship-choice checklist already ran). **No** Tech-Lead APPROVE token
         and **no** second process artifact is required or permitted as a stamp.

      2. **Stamp shape (normative).** Autopilot MUST treat card #1 as stamped iff **all** hold:
         - `gate == "ship-choice"`
         - `decision ∈ {pr, merge}`
         - `blocking_condition == null`
         - `decided_by == "auto"`
         - `council_tier == null` **and** `grading_reason == null` (M13: those fields are
           non-null only on the M14 council card #2)
         - it is the **first** `ship-choice` card for this attempt's `run_id` in ledger order
           (the original self-answer card that triggered M14 firing — M14(c))

      3. **Stamp pre-flight (MUST, fail-closed).** Before invoking `/council` and before any
         agree path, autopilot MUST re-read the ledger with `read-cards.sh` and verify the
         stamp shape above. On stamp fail (missing/empty ledger, `read-cards.sh` exit ≠ 0,
         no matching card #1, or any shape field mismatch): autopilot MUST **not** invoke
         `/council`, MUST **not** take the agree path, and MUST append card #2 as
         `decision = halt`, `blocking_condition = 7`, `confidence = 0`, `bump = null`, with
         `rationale` naming the stamp failure. This **reuses BC7** (M14(c)) — missing process
         evidence is self-uncertainty about the ship answer — and MUST NOT introduce a ninth
         BC. Autopilot MUST NOT rubber-stamp a missing process trail by running council on a
         process-compound claim or by agreeing without stamps.

      4. **Narrow claim (when stamps pass).** The one-line ship claim under audit MUST be
         **technical-only**: whether the branch diff (the merge-base range named in **(e)**)
         implements the cited ACs/spec. The claim MUST NOT assert process outcomes
         (`QA PASS`, `Step-10b … PASS`, TL approve, or equivalent process language). Process
         is pre-cleared by the stamp; the council audits technical readiness only. Locators
         (`ticket_id`, ledger path, spec/AC paths) remain in the claim envelope as before —
         they are locators, not process assertions.

      5. **Technical still blocks.** Stamp success does **not** pre-clear the council. A
         technical disagree / `UNVERIFIED` / `CONTRADICTED` / `FABRICATED` / sub-80 confidence
         still maps through **(b)** to BC7 halt. **(d)** (degraded / self-verified) is
         **unchanged**.

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

  - **(e) Tier selection at the ship gate (CDT-126).** Before invoking the M14 pass, autopilot
    MUST select a council tier per SPEC-013's **Council tiering** section and pass it on the
    invocation (`--council-tier=<tier>`). Grading MUST run immediately before the `/council`
    call, never earlier.

    - **Grading input.** The graded diff MUST be
      `git diff --numstat $(git merge-base <default> HEAD)..HEAD`, where `<default>` is resolved
      with `git symbolic-ref refs/remotes/origin/HEAD` — **the exact mechanism N3a already
      mandates at this same step**. Autopilot MUST reuse that resolution and MUST NOT invent a
      second diff-resolution or default-branch-resolution path. M14 has **no** pre-existing
      staged diff and no diff computation of its own (see the correction note below), which is
      why the graded input is named here.
    - **Bands live in SPEC-013.** The band thresholds (`files`/`loc` clear-low → `light`,
      clear-high → `full`, ambiguous middle → one triage call) and the five structural
      critical-area signals are **normative in SPEC-013's Council tiering section**. This bullet
      MUST NOT restate them (SPEC-002 D1 / M12 / N4); the only M14-specific element is the
      graded diff above.
    - **Fail closed.** SPEC-013's **Fail-closed contract** governs; this bullet adds only the
      M14-specific input failure: an **unresolvable `origin/HEAD`** counts as a grading failure
      and therefore resolves the tier to `full`, consistent with N3a's own fail-closed stance on
      the same resolution. Note the two differ in consequence and must not be conflated — N3a's
      unresolvable `origin/HEAD` **halts the ship** under BC3; here it merely **grades the
      council pass to `full`**. Grading failure MUST NOT skip, defer, or downgrade the council
      pass itself.
    - **`skip` is unreachable here.** Per SPEC-013's Tier vocabulary, grading cannot return
      `skip`. The M14-specific consequence: autopilot has no DRI, so at this gate `skip` can
      only arrive from an explicit human-supplied `--council-tier=skip` on the run — and MUST
      then be recorded verbatim on the card rather than normalized away.
    - **Recording.** The selected tier and its reason MUST be written to the M14 council card's
      `council_tier` / `grading_reason` fields (M13).
    - **The firing rule is unchanged.** (e) changes *which* council pipeline runs, never
      *whether* the pass runs: M14's "only at `ship-choice`, only on a clean `pr`/`merge`
      answer, exactly once per attempt, exactly two cards" all stand.

    > **Latent-doc correction for the wiring child.** `skills/autopilot/ship-gate-council.md` §3
    > currently instructs council investigators to pull "the staged diff" themselves. At M14
    > firing time **nothing is staged**: the `git merge --squash` staging happens *after* the
    > gate (N3a; `/orchestrate` Step 11). The child that edits that file MUST correct the §3
    > claim-string wording to the merge-base diff named above. The correction is to the
    > *locator* wording only — M14(a)'s locators-only rule (no materialized evidence file, no
    > render-helper script) is unchanged.
    >
    > The same §3 also states "Pass **no** `--plan`, **no** `--task-id`, **no other flag**",
    > which the M14(a) amendment above supersedes: `--council-tier=<tier>` is now the one
    > permitted flag and (e) requires it. The wiring child MUST correct that sentence in the
    > same pass, or the procedure will forbid the flag its own contract mandates.

  - **(f) Tier-aware BC7 halt (CDT-126).** When the M14 pass produces a BC7 halt (per (b) or
    (d)), the halt card MUST carry the run's `council_tier`, and the halt `rationale` MUST name
    it. The escalation surfaced to the human (S1) MUST offer a full-council re-run — *"this ran
    light and came back under threshold — re-run at full?"* — **only** when the halt came from a
    `light` run; a `full`-run halt MUST NOT make that offer, because no escalation remains.

    - This introduces **no ninth blocking condition and no new halt path** — M6's set of eight
      is still complete. It is one recorded field plus one line of rationale text on the
      **existing** card, and (b), (c), and (d) are unchanged: the verdict→confidence mapping,
      the reuse-BC7 ruling, and the degraded-run rule apply identically at both tiers.
    - A **degraded `light`** run still takes (d)'s path (`halt`, BC7, `confidence = 0`, rationale
      citing `self-verified — refuters unavailable`); its tier is still `light`, so the re-offer
      is still available. The tier and the degradation state are orthogonal — SPEC-013's Council
      tiering section is the home of that orthogonality ruling.
    - The re-offer is an **escalation affordance, not an auto-action**. Autopilot MUST NOT
      self-answer it, auto-re-run the council at `full`, or otherwise proceed past the halt (N2 /
      M7) — a BC7 halt still requires a human.

### AC8 — LOC exclusion + `--max-loc` override (CDT-223)

A gate is **never** removed. This AC changes **what LOC counts** and **which numeric bound**
BC4 / M10.1 use. It MUST NOT add a ninth blocking condition. It MUST NOT add `--skip-bcN`.

- **M15 — Counted LOC (one definition).** BC4 per-PR LOC, BC4 per-file size, and BC5 criterion
  **M10.1** MUST count only **non-excluded** paths. Interactive SPEC-009 change-discipline MUST
  use this same definition (cite; do not fork). Exclusion is the **union** of:

  1. **`.gitattributes` `linguist-generated`.** A path is excluded when `git check-attr
     linguist-generated -- <path>` reports `set` or `true`. `false` and `unspecified` do
     **not** exclude via this arm. The attribute form `linguist-generated` (no `=`) and
     `linguist-generated=true` both exclude.
  2. **Built-in mechanical list** (even when `.gitattributes` is absent):
     - **Lockfile basenames (exact):** `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`,
       `bun.lock`, `bun.lockb`, `Cargo.lock`, `composer.lock`, `Gemfile.lock`, `poetry.lock`,
       `Pipfile.lock`, `uv.lock`, `flake.lock`, `go.sum`.
     - **Snap glob:** basename matches `*.snap`.
     - **Vendored prefixes** (after stripping a leading `./`): path equals `vendor`,
       `third_party`, or `node_modules`, **or** starts with `vendor/`, `third_party/`, or
       `node_modules/`. Mid-path components (e.g. `src/vendor/x`) do **not** match.
  3. **SPEC-009 specs/tests exemption** (additive; M15 MUST NOT drop it). Specs and test
     files stay exempt. This spec MUST NOT redefine "test file".

  Project-specific codegen (`*.pb.go`, `*_gen.*`, `*_generated.*`) is **not** in the built-in
  list. Mark those paths `linguist-generated` in `.gitattributes` to exclude them. MUST NOT
  reuse the SPEC-008 product-source exclude set as this list.

  Missing or malformed `.gitattributes` → arm (1) empty; use arms (2)+(3) only. MUST NOT halt
  the run for a missing or unreadable attributes file.

  **Operational helper (subprocess CLI, never sourced):** `skills/autopilot/loc-exclude.sh`.
  Canonical invocation:

  ```
  loc-exclude.sh is-excluded <path>
  ```

  Exit `0` = excluded (do not count). Exit `1` = count. Exit `64` = usage. The helper MUST
  never exit `2` to kill an orchestrate run. Callers apply M15 and then apply M6.4 / M10.1
  bounds to the remaining LOC. BC4 stays **judgment-in-context** (not a budget-check-style
  scripted BC).

- **M16 — `--max-loc=<n|unbound>` DRI flag.** Flag-only per-run override. Council-tier
  precedent: `=` form, no env, junk → 64, last-wins on duplicate, not resume-seeded.

  **Parse** (`skills/autopilot/parse-flags.sh`, same argv scan as `--autopilot` /
  `--council-tier` / `--tier`):

  | Input | JSON `max_loc` | Exit |
  |---|---|---|
  | omit | `null` | 0 |
  | `--max-loc=<n>` with `n` matching `^[1-9][0-9]*$` | JSON **number** `n` | 0 |
  | `--max-loc=unbound` | JSON **string** `"unbound"` (case-sensitive) | 0 |

  MUST print **six** success keys: `enabled`, `bump`, `source`, `council_tier`, `tier`,
  `max_loc`. Independent of `--autopilot`, `--council-tier`, and `--tier` (no key writes
  another). Duplicate `--max-loc` **last-wins** (same-value and different-value repeats
  both succeed — unlike `--tier`, which 64s a duplicate).

  MUST exit **64**, write the error to stderr, and print **no** success JSON for: junk;
  `0`; negative; `UNBOUND` / `off` / `none` / `unlimited` / `inf`; empty `--max-loc=`;
  bare `--max-loc`; space form `--max-loc n`. Step 0 MUST halt before fetch, worktree, or
  spawns.

  MUST NOT read `MAX_LOC`, `AUTOPILOT_MAX_LOC`, or any env for this cap. MUST NOT persist
  in `resume-state.sh`. MUST NOT auto-propagate on `reroute-epic` (the `/epic` child
  re-parses its own argv).

  **Consumption:** the value is used only when autopilot is **active**. Autopilot off:
  still parse (junk → 64); the value is unused. `/kickoff` and `/epic` share the parser;
  an unused `.max_loc` MUST NOT change those workflows. MUST NOT document `--max-loc` on
  `/kickoff`. `/orchestrate` Step 0 MUST bind `.max_loc` from the **same** `parse-flags.sh`
  call as the other keys.

  **Effects** (counted LOC, M15; BC4 = `plan-approve` only; M10.1 = `scope-confirm` and
  `plan-approve`):

  | `max_loc` | BC4 per-PR | BC4 per-file (1000) | M10.1 |
  |---|---|---|---|
  | `null` (default) | halt if counted > 2000 | halt if any counted file > 1000 | reroute if counted > 2000 |
  | number `n` | halt if counted > **n** | **unchanged** (still 1000) | reroute if counted > **n** |
  | `"unbound"` | **does not fire** | **does not fire** | **does not fire** |

  `n` MAY be `< 2000` (tighten) or `> 2000` (raise). Soft ~1000 stays non-halting
  discipline. M10.2–6, BC6, BC3, and BC7 are **unchanged**. `unbound` disables BC4
  (per-PR **and** per-file) **and** M10.1; it does **not** disable M10.2–6.

  **Writer argc** (`append-card.sh`; additive on the CDT-126 13/15 contract):

  | argc | Meaning |
  |---|---|
  | 13 | `council_tier`, `grading_reason`, `max_loc` all null |
  | 14 | `<max_loc>` (`null` / `unbound` / decimal `^[1-9][0-9]*$`); council pair null |
  | 15 | `<council_tier> <grading_reason>`; `max_loc` null |
  | 16 | `<council_tier> <grading_reason> <max_loc>` |

  Any other argc → 64. Self-answer cards keep `decided_by: auto`.

  **Fixtures** (`skills/autopilot/self-answer-scenarios.md`): rewrite **F4** so the 1400-line
  file is **hand-written implementation** (generated/lockfile/snap at 1400 MUST NOT halt
  BC4 after M15). Add **F4-gen**, **F4-file**, **F4-n-ok**, **F4-n-file**, **F4-n-tight**,
  **F4-unbound**, **F4-unbound-m10**:

  | Fixture | Signal | Expected |
  |---|---|---|
  | F4 (rewritten) | one counted file 1400 lines; total under hard cap | BC4 halt (per-file) |
  | F4-gen | lockfile/snap/linguist-generated file 1400 lines | **no** BC4 |
  | F4-file | `--max-loc=<n>` with `n>2000`; one counted file >1000 | BC4 halt (per-file unchanged) |
  | F4-n-ok | `--max-loc=<n>`; counted LOC in `(2000, n]` | clean `approve` (no BC4, no M10.1) |
  | F4-n-file | `--max-loc=<n>`; one counted file >1000 | BC4 halt (per-file) |
  | F4-n-tight | `--max-loc=<n>` with `n<2000`; counted LOC in `(n, 2000)` | plan-approve BC4 halt; scope-confirm M10.1 reroute |
  | F4-unbound | `--max-loc=unbound`; counted >2000 **and** file >1000 | **no** BC4, **no** M10.1 |
  | F4-unbound-m10 | `--max-loc=unbound`; M10.2 workstream overflow | BC5 `reroute-epic` (M10.2 still live) |

  `/setup project` (`skills/scaffold-project/SKILL.md`) MUST seed `.gitattributes` with
  `linguist-generated` markers for the M15 built-in paths. Create the file if absent. If
  present, append **missing** markers only (idempotent; never clobber other attributes).
  Re-run MUST seed without overwriting `AGENTS.md` or other scaffold files.

---

## SHOULD

- **S1** — The escalation surfaced on a halt SHOULD include the decision-card `rationale` and the
  named blocking condition so the human can resolve it without re-deriving state.
- **S2** — Autopilot SHOULD attempt genuine ambiguity resolution (repo → specs → memory) and
  record the attempt in `rationale` before declaring BC1; a bare "unclear" is insufficient.
- **S3** — The `run_id` SHOULD be stable for the lifetime of one autopilot invocation so all cards
  for a run correlate, and SHOULD be derivable without external state (e.g. start-epoch).
- **S4** — When `--autopilot=<token>` is supplied, the `ship-choice` card SHOULD record the token
  in `bump` even when the chosen `decision` is `pr` (release tokens travel with the eventual
  release; `master` records land-no-release intent for audit).

---

## MUST NOT

- **N1** — MUST NOT remove, skip, or renumber any existing interactive gate or escalation trigger;
  autopilot only changes *who answers* and *records why*.
- **N2** — MUST NOT proceed past a hard-blocking condition (M6.1–4, 6–8) without a human.
- **N3** — MUST NOT auto-select a destructive ship action (squash-merge, force-push, protected-branch
  merge) — `ship-choice` defaults to PR; `merge` requires explicit `--autopilot=<token>` with a
  non-null ship-intent token (`patch` | `minor` | `major` | `master`). The token only satisfies
  "explicit ship intent" for `decision=merge`; it **never** exempts BC3, which is evaluated
  **unconditionally** even when a token is supplied. Force-push still halts under BC3 regardless of
  the token (BC3 never waived for force-push). Intentional baseline land under `=master` is not a
  raw self-selected protected-branch merge — it is authorized only via N3a when the mechanical
  check passes (same safety as release land).
- **N3a — Deterministic BC3 push-target check for autopilot land actions (CDT-111-C9; CDT-195).**
  N3's "protected-branch merge / force-push still halts under BC3, evaluated unconditionally"
  governs autopilot performing a **raw, self-selected destructive git operation** against a
  protected ref — a direct `git push` / force-push to a protected branch, a history rewrite, or
  a merge that mutates a protected ref outside an authorized land contract. It does **not** describe
  the authorized `decision=merge` land actions, which share (i)–(iii) and then **branch by token
  class** at the ref-mutating step:

  Shared preconditions for any `decision=merge` land (release **or** land-no-release):
  (i) authorized by an explicit `--autopilot=<token>` ship-intent token
  (`patch` | `minor` | `major` | `master`), (ii) gated by the M14 council pass, (iii) stages via
  `git merge --squash` — which moves **no** ref and creates **no** commit, fully reversible with
  `git reset` / clean-up of a squash conflict.

  **End-state branch (token class):**
  - **Release** (`bump ∈ {patch, minor, major}`): (iv-R) delegates the sole ref-mutating step
    (commit + tag + push) to `/release`, the repo's single ship-of-record with its own pre-commit
    gates. Sequence: N3a clear → squash-stage (no commit) → `/release <bump>` → ship-history →
    Done.
  - **Land-no-release** (`bump = master`, CDT-195): (iv-L) performs the interactive-shape
    `git commit` on the **worktree baseline** (typically `origin/HEAD`'s default branch — **not**
    a hard-coded ref named `master`), then a **non-force** `git push` of that baseline (BC3
    already cleared force), then ship-history, then Done. **MUST NOT** invoke `/release`, touch
    version files, tag, or CHANGELOG. Sequence: N3a clear → squash → `git commit` (interactive
    shape) → non-force `git push` baseline → **no** `/release` → ship-history → Done. This is
    the **third ship terminal** alongside PR-stop (`decision=pr`) and release-merge
    (`decision=merge` + release token).

  For either land action BC3 is **still evaluated unconditionally** (N3 unchanged), but its
  evaluation is **mechanical, not judgment**: before the ref-mutating step, autopilot MUST resolve
  the land/push target deterministically via `git symbolic-ref refs/remotes/origin/HEAD` (or
  equivalent) and confirm it equals the **baseline** the action will land on (for release: the
  branch `/release` will push; for land-no-release: the worktree baseline). BC3 **halts** iff that
  check fails — `origin/HEAD` is unresolvable, the resolved default does not match the land
  target, the ship would require a force-push, or the target is a protected branch **other than**
  the verified origin default. A passing mechanical check is a **deterministic BC3-clear, not a
  token-based exemption**: BC3 ran, unconditionally, and returned a negative — fully consistent
  with N3's "the token never exempts BC3." The token supplies ship *intent*, the mechanical check
  supplies ship *safety*, the M14 council pass supplies ship *assurance*; all three MUST hold for
  either land action to proceed. Fail-closed: an unresolvable `origin/HEAD` halts under BC3
  (autopilot MUST NOT fall back to a network guess to proceed). Force-push remains BC3-never-waived
  on both branches.

  The operational sequence lives in the companion procedure `skills/autopilot/end-state.md`
  (peer to `self-answer.md` / `ship-gate-council.md`), which MUST NOT restate or fork this
  contract (SPEC-002 D1 / M12 / N4). Wiring of the land-no-release branch is a CDT-195 skill
  child — this contract freezes the policy only.
- **N4** — MUST NOT define a second `/release` bump vocabulary or a second copy of any
  checklist/condition/budget/schema outside the contract home (M12). The single land-no-release
  sentinel `master` is owned here (M2/M13) and is not a `/release` version.
- **N5** — MUST NOT edit SPEC-002 prose or any SPEC-031 file to satisfy this contract.
- **N6** — MUST NOT reuse the council `verdict` field as the gate answer; `decision` is distinct (M13).
- **N7** — MUST NOT fold the autopilot QA counter (BC2) into the Step-8/Step-9 interactive triggers;
  it is a separate, additive third counter.
- **N8** — MUST NOT self-answer `/epic` B.5's kickoff-mode completion confirmation; it is a truth
  attestation of *real* completion, not an approval, and MUST be left for the human (M5 note f). Nor
  may autopilot mark a child `completed` merely because `/kickoff` produced a plan file.
- **N9** — MUST NOT read `MAX_LOC`, `AUTOPILOT_MAX_LOC`, or any environment variable for the
  `--max-loc` cap (M16). Flag-only.
- **N10** — MUST NOT add `--skip-bcN`, `--loc-cap`, a standing `/setup` `max_loc` config, or
  any other ambient LOC-cap store. MUST NOT drop BC6. MUST NOT disable M10.2–6, BC3, or BC7
  via `--max-loc`.
- **N11** — MUST NOT resume-seed `max_loc` and MUST NOT auto-propagate it on `reroute-epic`.
  The child `/epic` / `/orchestrate` invocation re-parses its own argv.

---

## Open questions (non-blocking; deferred to wiring children)

- OQ1 — Exact escalation/notify transport on halt (webhook vs. inline print) — owned by the wiring
  child, not this contract. **Resolved by CDT-111-C7:** halt escalations emit `task_blocked` and
  autopilot end-states (`pr` / release-merge / land-no-release success) emit `task_complete`, both
  via `/orchestrate`'s **Passive notifications → Tier B** helper (`skills/notify/webhook.sh`,
  fail-open); reuses the existing CDV-210 event enum — no new event, no new transport (AC3).
- OQ2 — Whether the epic-level walker gets its own aggregate budget distinct from the sum of child
  budgets — deferred until `/epic` autopilot wiring.
- OQ3 — Whether `confidence` is self-reported by the answering agent or derived from a council
  micro-check — the schema accommodates either. **Resolved for `ship-choice` by M14
  (council-derived); remains self-reported for `scope-confirm` / `plan-approve`.**

---

## Version History

| Date | Change |
|------|--------|
| 2026-08-27 | CDT-223: **AC8 / M15 / M16** — counted-LOC exclusion (`.gitattributes linguist-generated` ∪ built-in lockfile/`*.snap`/vendored-prefix list ∪ SPEC-009 specs/tests exemption) for BC4 per-PR, BC4 per-file, and M10.1; same definition for interactive SPEC-009 change-discipline. DRI `--max-loc=<n\|unbound>` flag-only (six-key `parse-flags.sh`, no env, junk→64, last-wins, not resume-seeded, not auto-propagated on reroute-epic). `n` raises/tightens per-PR hard cap + M10.1 only (per-file 1000 unchanged); `unbound` disables BC4 (per-PR and per-file) and M10.1; M10.2–6 / BC6 / BC3 / BC7 unchanged. M13 additive nullable `max_loc` (`schema_version` stays 1; `decided_by` stays `auto` on self-answer). Helper `skills/autopilot/loc-exclude.sh`. Scaffold seeds `.gitattributes`. Status stays DRAFT. |
| 2026-08-16 | CDT-196: M11a(a) BC5 carry-forward MUST pass `--worktree --release <bump>` when bump is patch/minor/major; `/epic` persists `release_bump` so children cannot land on master. |
| 2026-08-04 | Initial contract (CDT-111-C1) — mode activation (M1–M2), per-gate checklists + per-command checkpoint mapping (M3–M5), eight blocking conditions (M6–M8), run-budget defaults (M9), complexity-overflow reroute (M10–M11), contract home (M12), decision-card schema (M13), MUST NOTs N1–N8. Amended within the same DRAFT cycle by later CDT-111 children: C2 (card writer/reader paths), C5 (AC7 / M14 council ship gate), C6 (M11a reroute safety + state carry-forward), C7 (OQ1 notify transport), C8 (M9a resume wall-clock basis), C9 (N3a deterministic BC3 push-target check). *(This table itself was added 2026-08-05 by CDT-126 — the section was missing; the rows above reconstruct the DRAFT cycle that predates it.)* |
| 2026-08-05 | CDT-126: council tiering at the autopilot ship gate. **M14(e)** — tier selection before the M14 pass: graded input is `git diff --numstat $(git merge-base <default> HEAD)..HEAD` with `<default>` from `git symbolic-ref refs/remotes/origin/HEAD`, reusing N3a's existing mechanism at the same step rather than inventing one; bands, critical-area signals, the fail-closed contract and the `skip`-unreachability rule are all cited from SPEC-013's Council tiering section, never restated (SPEC-002 D1 / M12 / N4) — (e) keeps only the M14-specific deltas: the graded diff, the fact that an unresolvable `origin/HEAD` grades to `full` here whereas N3a's own unresolvable `origin/HEAD` **halts the ship** under BC3 (same probe, different consequence — not to be conflated), and that autopilot has no DRI so `skip` can only arrive human-supplied; **M14(a)** amended to carve out `--council-tier=<tier>` as the sole permitted flag on the otherwise-unbound `/council` invocation, resolving its contradiction with (e)'s requirement to pass it; firing rule (`ship-choice` only, clean `pr`/`merge` only, exactly once, exactly two cards) unchanged. Includes a correction note for the wiring child: `skills/autopilot/ship-gate-council.md` §3's "the staged diff" is wrong — nothing is staged at M14 firing time (the `git merge --squash` happens after the gate), so M14 has no pre-existing diff of its own, and its "no other flag" sentence is superseded by the M14(a) carve-out — both to be corrected in the same pass. **M14(f)** — tier-aware BC7: the halt card carries `council_tier` and the rationale names it; the full-council re-offer is made only from a `light` halt, and is an escalation affordance autopilot MUST NOT self-answer. No ninth blocking condition, no new halt path; (b)/(c)/(d) unchanged. **M13** — decision card gains nullable `council_tier` + `grading_reason`, non-null only on the M14 council card; `schema_version` stays `1` (additive + nullable, discriminator envelope unchanged); `append-card.sh` cross-field invariants to be extended by the wiring child. Status stays DRAFT. |
| 2026-08-09 | CDT-185: M14(a) process stamps + narrow claim (Option 3). Before `/council`, autopilot MUST pre-flight **process stamps** = clean ship-choice **card #1** via `read-cards.sh` (stamp shape: `gate=ship-choice`, `decision∈{pr,merge}`, `blocking_condition=null`, `decided_by=auto`, `council_tier`/`grading_reason` null, first ship-choice card for `run_id`). QA/Step-10b implied by self-answer; **no** TL APPROVE stamp. Stamp fail → refuse agree path, no `/council`, card #2 BC7 halt `confidence=0` (reuse BC7, not a 9th BC). Stamp pass → one-line claim is **technical-only** (merge-base diff vs ACs/spec); MUST NOT re-assert process outcomes in the claim body. Locators-only / no RAW_ARTIFACTS injection preserved. M14(b)/(c)/(d)/(e)/(f) mapping and degraded-run rule unchanged; technical disagree still BC7. Scope: M14 ship-gate only. Procedure home: `skills/autopilot/ship-gate-council.md` §3b (wiring child). Status stays DRAFT. |
| 2026-08-10 | CDT-195: `--autopilot=master` land-no-release ship-intent sentinel. **M2** — ship-intent token set = `/release` tokens `patch\|minor\|major` **plus** non-release sentinel `master` (flag-only; env never carries bump/sentinel; `master` MUST NOT be passed to `/release`; land target = worktree baseline / `origin/HEAD`, not hard-coded ref `master`); resume: bare `--resume-ship` re-reads recorded mode, explicit `=master\|patch\|minor\|major` overrides. **M4 ship-choice** — non-null token (incl. `master`) ⇒ `decision=merge`; end-state branches on token class (release vs land-no-release). **M13** — `bump` enum gains `master` (ship-choice only; not a release version). **N3/N3a** — intentional baseline land under `=master` authorized when mechanical BC3-clear passes (same safety as release land); force-push still BC3-never-waived; third terminal land-no-release: N3a → squash → interactive-shape `git commit` → non-force `git push` baseline → no `/release` (no version files/tag/CHANGELOG) → ship-history → Done. Pure superset of bare and `=patch\|minor\|major`. Skill/wiring deferred; status stays DRAFT. |
