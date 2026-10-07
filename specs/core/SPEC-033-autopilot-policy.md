# SPEC-033: Shared Autopilot Policy Contract

**Status**: ACTIVE
**Category**: core
**Created**: 2026-08-04

**Covers**: `skills/autopilot/SKILL.md` (contract home), `skills/autopilot/parse-flags.sh`, `skills/autopilot/loc-exclude.sh`, `skills/autopilot/budget-check.sh`, `skills/autopilot/append-card.sh`, `skills/autopilot/read-cards.sh`, `skills/autopilot/self-answer.md`, `skills/autopilot/fixtures/self-answer-scenarios.json` (05 E5 machine-readable gate fixtures), `skills/autopilot/ship-gate-council.md`, `skills/autopilot/ship-gate-verdict.sh` (M14(i), WP 1-14). Citers: `skills/orchestrate/SKILL.md`, `skills/orchestrate/steps/00-resolve.md`, `skills/kickoff/SKILL.md`, `skills/epic/SKILL.md`, `skills/scaffold-project/SKILL.md` (`.gitattributes` seed, CDT-223). N3a clean-tree precondition (WP 1-05): `skills/autopilot/end-state.md` §4 and §6.5, `skills/autopilot/test-end-state-safety.sh`. WP 1-08: `skills/autopilot/resume-state.sh` and `skills/lib/plan-resolve.sh` (M9a plan lookup, ITER restore, approval wait), `skills/autopilot/end-state.md` §3, §3.5 and §5.5 (N3a fetch-first, tag snapshot).

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
the decision-card audit schema (AC6), the council ship-gate pass (AC7), the LOC
exclusion plus `--max-loc` override (AC8 / CDT-223), and `/orchestrate` run-budget
auto-tune (AC9 / M9b / CDT-224).

This spec is the contract. `skills/autopilot/SKILL.md` is the operational copy.
`/orchestrate`, `/kickoff`, and `/epic` consult it. The "no workflow file edited here"
sentence was the CDT-111-C1 authoring note. It is not the current tree.

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

  AGENTS.md scopes "master moves only at epic seal / one `/release` fold" to epic children.
  This `master` sentinel is the non-epic land-no-release path. The flag is not refused.
  SPEC-010 H1–H12 check `/release` tags. An untagged land-no-release commit is not a
  ship-history failure.

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
    1. Does every plan task carry concrete file paths **and** a verification step? Does the
       plan's `process_acs:` line equal the `[process]` tags in the `### <ticket_id>` AC
       subsection of the spec (M14(h) guard 2)? → else BC1.
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
  | `ship-choice` | Step 11 (ship options) — self-answerable, defaults to PR | **N/A** — `/kickoff` ends at the task graph and never ships | **N/A** at a gate — `/epic` ships only via B.7 seal (M14); it writes no code and spawns no IC; each child's real ship-choice lives **inside its own delegated `/orchestrate` Step 11** |

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
  - **(h) `reroute-epic` at an `/epic` gate (WP 1-09; CDT-322).** `/epic` is the target of a
    `reroute-epic` decision, so the decision cannot hand off to `/epic` from inside it. At **A.5**
    it never passes silently: with more than 8 proposed children (the `/epic` A.1 soft-warn rule)
    it prints `scope-confirm reroute-epic (soft warn): <rationale> — card: <card-path>` and
    continues to A.6; otherwise it runs as `halt`. At **B.3** it runs as `halt` (child unchanged,
    `task_blocked` notice, one-line message): splitting one child needs `--redecompose`, which
    autopilot never starts (note (g)). **A nested epic for a child is not allowed:** an epic holds
    one flat child list (SPEC-025 M6), and a nested epic needs cross-epic dependencies, which
    SPEC-025 lists as out of scope. Any other decision value at an `/epic` gate runs as `halt`
    (fail closed). `skills/epic/SKILL.md` defines this map itself; it does not cite a "shared" map.
    The M5 table above reads the same way for `ship-choice`: `/epic` ships only via the B.7 seal
    (M14), and `/epic` has no ship-choice gate of its own.

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
  unchanged for `/kickoff` and `/epic` Mode A. `/orchestrate` MAY auto-tune those same two
  caps per **M9b** (AC9). Auto-tune MUST NOT apply to `/kickoff` or `/epic` Mode A.

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
  introduces no new persistence field and does not modify or duplicate M11a. On resume, M9b
  frozen caps come from the plan-approve card (AC9); M9a still supplies only the synthetic
  epoch. `resume-state.sh` MUST NOT grow a frontmatter seed for caps.

  **Approval wait (WP 1-08; user decision 2026-09-28).** Time that a live `/orchestrate`
  autopilot run spends blocked on a human approval (a refused tool call, a permission prompt,
  or any other "wait for the user" inside the run) MUST NOT count toward BC6. Such a wait is
  already an M8 halt: before it blocks, the orchestrator MUST write a `halt` card through the
  `self-answer.md` §3f freeze recipe with `blocking_condition` 1 (3 when the refused action is
  destructive, M6.3), `decided_by` `auto`, `gate` = the last gate this run answered
  (`scope-confirm` or `plan-approve`; `scope-confirm` before the first gate; never
  `ship-choice`), the current `run_id` and ITER, and a
  `rationale` that starts with `approval-wait:`. Its `budget.wall_clock_s` is the active time up to
  the wait. When the human replies in the same session, the orchestrator MUST re-mint
  `run_start_epoch` by the resume rule above (`now − resume-state.sh --accumulated`) before its
  next `budget-check.sh` call. The re-mint changes `run_start_epoch` only; `run_id` stays. If the
  `budget-check.sh` call for the wait card already reports a breach, the card is a BC6 halt
  instead and no re-mint follows (resuming past BC6 stays a human decision). No wait card is
  needed after ship-choice card #1: BC6 is not evaluated after it. `/kickoff` and `/epic` Mode A
  are unchanged. This loosens BC6 for human wait time only: BC6 stays a hard stop for active
  time, and a run that does not wait for a human keeps the old measure. It adds no card field,
  no gate value, no `type` and no ninth BC.

  **Plan lookup and ITER restore (WP 1-08).** `resume-state.sh` finds the plan through
  `skills/lib/plan-resolve.sh`: the plan whose `## Tracking` section has `ticket_id:` exactly
  equal to the ticket id, searched in `<show-toplevel>/.claude/plans` and then
  `$MROOT/.claude/plans`; the newest mtime wins a tie; no exact match (including a legacy plan
  with no `ticket_id:` line) → `{"found":false}`, never a prefix guess. `autopilot_on` and
  `autopilot_bump` are read only inside that `## Tracking` section. `--accumulated` always prints
  one non-negative integer (`0` when there are no cards or `read-cards.sh` fails). On resume, ITER
  restarts at `resume-state.sh --iteration <ticket_id>`: `max(.budget.iteration)` over the
  ticket's cards, or `0`. ITER is incremented once per M9 stint, at each agent spawn site.

### AC4 — Complexity-overflow → `/epic` reroute criteria

- **M10 — Overflow criteria.** Complexity **overflow** (the BC5 trigger's underlying definition)
  is met when **any** of the following holds at `scope-confirm` or `plan-approve`:
  1. Projected total **counted** change (M15) exceeds the per-PR hard cap across the ticket
     (default **> 2000 LOC**; `--max-loc=<n>` uses **n**; `--max-loc=unbound` **disables this
     criterion**). Evaluated at `scope-confirm` only. At `plan-approve` a counted-LOC overflow is
     BC4, which comes first in M6 order, so M10.1 never reroutes there (WP 1-08, CDT-331); or
  2. The work naturally decomposes into **3 or more independently shippable workstreams**
     (distinct PR-able units with no shared change surface); or
  3. The plan's task graph would exceed **~8 tasks across multiple parallel waves** (mirrors
     `/epic`'s ">8 children → probably two epics" soft-warn); or
  4. The work requires **more than one distinct spec / contract home** (a signal of multiple
     independent concerns); or
  5. It touches **3 or more independent subsystems** with no common change surface; or
  6. The estimated single-run wall-clock would exceed the **effective** `wall_clock_cap`
     even with full parallelism (M9b). At **unfrozen** `scope-confirm`, compare the
     estimate to **4500 s** unless `AUTOPILOT_WALLCLOCK_CAP` is set (then use that value).
     At `plan-approve` and later, compare the estimate to the **frozen**
     `budget.wall_clock_cap_s`. This criterion MUST NOT suppress M10.1–5.
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
    (CDT-196). The persist happens at `init`, so it applies to a **new** decompose. On a
    **resume** of an epic whose durable `release_bump` is null, `/epic` MUST exit **64** and
    MUST NOT set the bump on the session alone (WP 1-09; SPEC-025 M14 item 10). Absent the explicit flag/env, `/epic` falls back to interactive human
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
    "budget": { "iteration": 0, "iteration_cap": 25, "wall_clock_s": 0, "wall_clock_cap_s": 2700, "tier": null, "source": null, "signals": null },
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
    `council_tier`, and the same redaction obligation and 1000-character cap as `rationale`.
    The writer exits 64 when `grading_reason` is longer than 1000 characters.
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
  - `rationale` is a one-line summary of at most 1000 characters and MUST NOT contain secrets,
    credentials, tokens, keys, or PII. Any evidence quoted from the repo, specs, or memory
    (e.g. the S2 resolution attempt) MUST be **redacted or summarized**, never copied verbatim
    into the card. The writer exits 64 when `rationale` is longer than 1000 characters.
  - `budget` snapshots the AC3 counters at decision time. The object keeps four numeric
    keys (`iteration`, `iteration_cap`, `wall_clock_s`, `wall_clock_cap_s`). **CDT-224 /
    M9b** adds three nested keys, **additive and nullable**, inside `budget` only:
    `tier` (`S|M|L|null`), `source` (`auto|env|default|mixed|null`), and `signals`
    (`{tasks, projected_loc, waves}|null`). Top-level key count stays **18**. Gate enum
    stays the frozen 3-value set. `type` stays `autopilot_decision`. `schema_version`
    stays `1`. MUST NOT add a fourth `gate` value. MUST NOT add a new `type`.
    `read-cards.sh` MUST backfill absent nested keys as explicit `null` (absent ≡ null).
    Pre-CDT-224 cards remain valid. Pre-freeze, `/kickoff`, and `/epic` Mode A cards
    MUST write the three nested keys as `null`. Plan-approve freeze and later
    `/orchestrate` cards MUST copy the freeze (AC9). `rationale` MUST mention
    `budget_tier` when `source` is `auto` or `mixed`. `rationale` MUST mention env when
    `source` is `env` or `mixed`.
  - `actor` names the writer (e.g. `orchestrator`).
    **Ship-choice card #1 vs card #2 (WP 1-08, CDT-281).** `actor` is the discriminator; no
    field is added. Card #2 (the M14 council card, including the §2a stamp-fail halt) MUST
    carry `actor: "ship-gate-council"`. Card #1 carries the component that ran the self-answer
    engine (`orchestrator`, or `epic-orchestrator` for an `/epic`-driven child) and MUST NOT
    carry `ship-gate-council`. `council_tier` is not a discriminator: a stamp-fail card #2 has
    `council_tier: null`. Cards written before this revision may carry `orchestrator` on card #2;
    a reader of an old ledger falls back to append order within the `run_id`. When card #1 is
    unreadable, the fresh §2a halt card uses `run_id` `orchestrate-<ISSUE-ID>-<RUN_START_EPOCH>`
    (the `/orchestrate` Step 0 formula, with the run's current `RUN_START_EPOCH`).

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
    `skills/autopilot/read-cards.sh`), the AC source (`ac-source=<path>`, **(g)**), and a one-line **technical** ship
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

    - **Per-AC claims in one invocation (WP 1-14).** The claim envelope MUST name exactly one
      AC source with the locator token `ac-source=<path>` (format, trigger and split:
      **(g)**). The council MUST audit each technical AC of the ticket as its own falsifiable
      claim, with its AC id, in the **same** `/council` invocation. Autopilot MUST NOT run
      one `/council` invocation per AC. The firing rule stays "exactly once per attempt".
      Each per-AC claim carries the AC id and a `<path>:<line>` locator only. It MUST NOT
      carry the AC text. Locators-only is unchanged.
    - **Independent evidence stays inside M14(a) (WP 1-14).** Autopilot MUST NOT pass a QA
      evidence file, a test-runner log, an AC→evidence map, or any other file that a
      pipeline step wrote for the council to read. These designs are rejected: they are
      pre-digested evidence, which this bullet and CDT-185 forbid. The card #1 stamp clears
      a `[process]` AC **(h)**. A runner log never clears an AC.
    - **A `Verify:` command is a locator (WP 1-15).** A technical AC MAY name one `Verify:`
      command in the AC source **(g)**. The command string is a locator, like
      `<path>:<line>`. It names one test that the council's own per-AC investigator runs
      through its own tool call, during the council pass. The output of that run is the
      investigator's own Phase 2 evidence (SPEC-013 Phase 2). It is not a "test-runner log"
      in the sense of the bullet above, because no pipeline step wrote it for the council.
      Autopilot MUST NOT run the command for the council. Autopilot MUST NOT pass its
      output, a log of it, or a summary of it. A passing run does not clear an AC by
      itself. The clearing rule **(b)** and the degraded-run rule **(d)** are unchanged.

  - **(b) Per-AC aggregation → confidence → BC mapping (normative; WP 1-14).** The council
    returns one verdict per technical AC claim **(g)**. Autopilot MUST map them to the second
    `ship-choice` card with these steps, in this order. The verdict mapper **(i)** is the
    only implementation of these steps.
    1. **No usable report, or a degraded run** → **(d)**: `decision = halt`,
       `blocking_condition = 7`, `confidence = 0`, `bump = null`. This includes a split that
       failed closed **(g)**.
    2. **Match verdicts to ACs.** A verdict belongs to AC `<id>` if and only if it is
       unstruck and its `claim` text starts with the tag `[AC-<id>]`. If more than one
       verdict belongs to one AC, use the worst verdict and the lowest confidence. The
       order from worst to best is `FABRICATED`, `CONTRADICTED`, `UNVERIFIED`,
       `PARTIALLY_VERIFIED`, `VERIFIED`. A verdict that belongs to no technical AC is
       ignored.
    3. **Missing evidence halts (AC E).** A technical AC with no verdict is **unaudited**. This covers a
       dropped claim, a struck verdict, an empty bundle set, and a verdict outside the taxonomy. One or
       more unaudited ACs → `decision = halt`, `blocking_condition = 7`, `confidence = 0`, `bump =
       null`. The `rationale` MUST name every unaudited AC id. An AC over the budget is not "unaudited"
       -- it fails the split closed at step 1, case 9 of **(g)**, before any claim exists.
    4. **A failed AC halts.** One or more ACs with `UNVERIFIED`, `CONTRADICTED` or
       `FABRICATED` → `decision = halt`, `blocking_condition = 7`, `confidence = 0`,
       `bump = null`. The `rationale` MUST name every failed AC id and its verdict.
    5. **Confidence is the minimum.** Otherwise every technical AC is `VERIFIED` or
       `PARTIALLY_VERIFIED`. Set `confidence` to the **lowest** confidence of those
       verdicts, floored to an integer (CDT-181 floor semantics).
    6. **Decide.** `confidence ≥ 80` (**agree**) → `decision` = the **original** ship-choice
       card's decision (`pr` or `merge`), `bump` copied from that original card,
       `blocking_condition = null`. `confidence < 80` (**disagree**) → `decision = halt`,
       `blocking_condition = 7`, `bump = null`, and `confidence` stays the minimum. The
       `rationale` MUST name every AC id below 80.

    The gate MUST NOT use `max_verdict_confidence`, a mean, a vote, or any single "overall"
    verdict. A run that has no AC-bound claims MUST halt as in step 1: the gate fails
    closed when the per-AC split did not run.

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

    > **Landed.** `skills/autopilot/ship-gate-council.md` §3 names the merge-base diff.
    > It does not tell investigators to pull a staged diff. `--council-tier=<tier>` is
    > the one permitted flag. Do not treat that wording as open work.

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

  - **(g) AC source and per-AC split (normative; WP 1-14).** The AC source is the committed
    spec that the claim envelope names with `ac-source=<path>`.
    - **Path.** `<path>` is relative to the worktree top level
      (`git rev-parse --show-toplevel`). The split MUST read the file content at `HEAD`
      (`git show HEAD:<path>`), not the working tree. `<path>` MUST be relative and MUST NOT
      hold a `..` segment; else the split fails closed (case 1 below).
    - **Not an AC source.** Gitignored kickoff plans, backlog carriers, and spec checkbox
      sections (for example a `## Validation` list) MUST NOT be used as the AC source.
    - **Checkboxes are not evidence (WP 1-15).** A `- [ ]` or `- [x]` line in a spec is
      checklist syntax. Its state MUST NOT count as evidence for or against a claim. The
      Phase 4 brief and judge prompts of the council state this rule on every run; the
      investigator prompt states it for a claim with a `Verify:` command (SPEC-013).
    - **Format.** The spec MUST hold one `## Acceptance criteria` section. The section MUST
      hold one `### <ticket_id>` subsection for the ticket that ships. Each AC is one
      bullet at column 0:

      ```
      ## Acceptance criteria

      ### <ticket_id>

      - **A.** <text>
      - **B.** [process] <text>
        - <optional continuation, indented by two or more spaces>
      ```

      - The section runs from the `## Acceptance criteria` line to the next `## ` heading or
        the end of file. The subsection runs from the line `### <ticket_id>` (exact text)
        to the next `### ` or `## ` heading, the next `---` line, or the end of file.
      - An AC bullet matches `^- \*\*([A-Z][A-Z0-9]{0,3})\.\*\* (\[process\] )?\S`. Group 1
        is the AC id. The optional `[process]` tag comes directly after the id.
      - In the subsection, a line MUST be blank, an AC bullet, or a continuation line
        (indented by two or more spaces).
      - The `### <ticket_id>` subsection binds the ACs to one ticket. A spec that many
        tickets amend keeps one subsection per ticket, so a later ticket cannot ship on the
        ACs of an earlier ticket.
      - **Verify line (WP 1-15).** A technical AC MAY hold one continuation line of this
        form: two spaces, then `Verify: bash <path>`, then zero or more ` <arg>` tokens.
        - `<path>` is relative to the worktree top level. It MUST NOT hold a `..` segment.
          It MUST be present at `HEAD`.
        - The file name of `<path>` MUST be a suite name that `tools/run-all-tests.sh`
          discovers: `test.sh`, `test-*.sh` or `*-test.sh`. The command names one test
          file. It MUST NOT name `tools/run-all-tests.sh`.
        - `<path>` and each `<arg>` hold only these characters: `A-Z`, `a-z`, `0-9` and
          `. _ / = : @ % + , -`. So no shell metacharacter can reach the investigator.
        - The split copies the command into the claim record (SPEC-013 Phase 1). An AC
          with no `Verify:` line is audited as before.
    - **Trigger.** The split MUST fire if and only if the scope is `claim`, the claim text
      starts with `Ship-gate audit for <ticket_id>.`, and the claim text holds one or more
      `ac-source=` tokens. The token value is the non-space text after `ac-source=`. Every
      other `/council` claim keeps the one-element claim path, and its investigation-plan
      JSON MUST NOT change (AC G). An M14 envelope with no `ac-source=` token does not
      split; the mapper then halts it, because the run has no AC-bound claims **(b)**.
    - **Split.** The council preflight MUST emit one claim per technical AC, in document
      order, in `plan.claims[]`, with no LLM step. SPEC-013 Phase 1 owns the claim record
      and the claim text template. A `[process]` AC gets no claim; its id goes to
      `plan.process_acs[]`.
    - **Fail closed.** The split MUST refuse to emit a plan, and the run MUST end with no
      report, when one or more of these is true:
      1. `<path>` is absent at `HEAD`, or the envelope holds two or more
         `ac-source=` tokens.
      2. The `## Acceptance criteria` heading is missing.
      3. The `### <ticket_id>` subsection is missing.
      4. The subsection holds zero AC bullets.
      5. A line in the subsection is not blank, not an AC bullet, and not a continuation
         line.
      6. Two AC bullets have the same id.
      7. Zero technical ACs remain after the `[process]` ACs are removed **(h)**.
      8. A `[process]` AC fails guard 1 **(h)**.
      9. The technical AC count is more than the M14 claim budget **(j)**.
      10. A `Verify:` line breaks the Verify line rule, one AC holds two or more `Verify:`
          lines, or a `[process]` AC holds a `Verify:` line (WP 1-15).
      11. One or more ACs hold a `Verify:` line, and the worktree has uncommitted changes
          to tracked files. The split reads `HEAD`, but a verify run reads the worktree
          (WP 1-15).

      The stderr line MUST name the cause and, for cases 6, 9 and 10, the AC ids. Autopilot then
      takes step 1 of **(b)** (`halt`, BC7, `confidence = 0`), and the `rationale` MUST
      name the cause.
    - **Writers.** The ticket's ACs MUST reach the spec before ship. `/orchestrate` Step 6
      (and the Step 4 scoper at the `light` tier) and `/kickoff` Step 5 MUST write the
      confirmed ACs into the `### <ticket_id>` subsection. Step 10b MUST confirm that the
      subsection exists and holds every confirmed AC. A missing subsection at Step 10b MUST
      go back to the Tech Lead before ship.
      The writers MUST add a `Verify:` line to each technical AC that one test file proves
      (WP 1-15). Step 10b MUST list each technical AC with no `Verify:` line, and each
      `Verify:` file that does not call `hermetic_init`. This list is a report. It does
      not block the ship.
    - **Finder recipe (WP 1-16).** For a claim with a `Verify:` command, the per-AC
      investigator MUST follow a fixed recipe, in this order. The investigator prompt
      (`skills/council/prompts/investigator.md`, verify section) owns the exact commands.
      1. Quote the AC. One read anchored on the `<path>:<line>` locator prints the AC
         bullet and its continuation lines, with line numbers. A search for the bullet id
         alone is not enough, because each `### <ticket_id>` subsection reuses the ids.
      2. Run the `Verify:` command (M14(a)). Then run one filter over its saved output
         that keeps every line with the AC label, every FAIL and SKIP line, the suite
         summary lines and the `VERIFY exit=` line. The filter output is its own bundle.
      3. Find the named tokens in the step 1 quote: backtick spans, `path:N` locators,
         `Case N` and `AC X` references, and numbered sub-clauses such as `(2)`. By default,
         one bounded grep covers every backtick-span, `Case N` and `AC X` token against the
         Verify test file; a `path:N` token gets its own `awk 'NR==<N>{...}'` call, because
         grep never matches a locator string against file content. Only when that default
         call finds no line for a token does the investigator fall back to one scoped,
         multi-`-e` `git grep` call against a path it already read for this claim; it MUST
         NOT run an unscoped `git grep`. Numbered sub-clauses are advisory evidence only.
      - **No elision.** In this mode a `raw_blob` is the complete output of its own
        `reproducible_command`. It MUST NOT hold an inserted `...`, `[...]` or `…` line, and
        MUST NOT hold text that the investigator added after the output. Use a narrow
        command, not a cut of a long output. The step 2 verify bundle is the one exemption:
        its `raw_blob` is the complete stdout of the step 2 call (the wrapper that also
        records the exit code), not a bare re-run of `reproducible_command`, which still
        equals the claim's own `Verify:` command.
      - **Tokens come from the finder.** The investigator takes the tokens from its own
        quote. The split, the engine and the claim record MUST NOT carry the AC text or
        its tokens (M14(a) locators-only).
      - **Judge caps.** The judge MUST keep the confidence at 79 or lower when no bundle
        quotes the AC, when a token of class backtick span, `path:N`, `Case N` or `AC X`
        named in that quote has no bundle, other than the step 1 quote bundle, with a
        matching line, or when a bundle holds an elision line (SPEC-013 Phase 5). A numbered
        sub-clause named in that quote is advisory evidence only and carries no cap, because
        no oracle can check a finder-chosen key phrase. These caps can only lower a
        confidence. They add no clear path and change nothing in **(b)**, **(d)** or the
        mapper **(i)**.
      - A claim with no `Verify:` command keeps the render it had before WP 1-16.

  - **(h) `[process]` ACs (normative; WP 1-14).** A `[process]` AC asserts only test, gate
    or CI execution (for example, "the full test runner exits 0"). The council MUST NOT
    audit it. The card #1 process stamp (M14(a) CDT-185) clears it. Three guards apply:
    1. **Guard 1 (deterministic, at split time).** The text of a `[process]` AC MUST hold at
       least one of these whole words, in any letter case: `test`, `tests`, `suite`,
       `suites`, `runner`, `gate`, `gates`, `CI`, `release`. Else the split fails closed
       **(g)**. This guard proves execution vocabulary only. It cannot prove that the AC
       asserts no diff content; guard 2 covers that gap.
    2. **Guard 2 (plan-approve).** The Tech Lead MUST list the `[process]` AC ids in the
       plan on one line, `process_acs: <ids|none>`. The plan-approve answer (human or
       autopilot) MUST confirm that this list equals the tags in the spec. An AC that
       asserts diff content MUST NOT carry the tag.
    3. **Guard 3 (deterministic, fail closed).** The split fails closed when zero technical
       ACs remain **(g)**. The verdict mapper **(i)** MUST halt (`halt`, BC7,
       `confidence = 0`) when `plan.process_acs[]` is not empty and card #1 does not match
       the M14(a) stamp shape.

    An AC that mixes execution and diff content MUST be split into two ACs, or written
    without the tag.

  - **(i) Verdict mapper (normative; WP 1-14).** `skills/autopilot/ship-gate-verdict.sh` is
    the only implementation of **(b)**. It is a pure `jq` mapper over the council's own
    verdict output.
    - **Inputs.** The `.finalize-meta.json` sidecar of this run's report (SPEC-013
      Phase 6), card #1 as JSON, and the resolved `council_tier`. Or, when there is no
      usable report, one `--no-report <cause>` argument.
    - **Output.** One JSON object on stdout with `decision`, `blocking_condition`,
      `confidence`, `bump` and `rationale` for card #2. The `rationale` names the tier
      **(f)**.
    - **Limits.** It MUST run after the verdict. It MUST NOT read evidence, spawn an agent,
      call `/council`, or write a file. It MUST NOT feed anything to the council.
    - **Not a render helper.** M14(a) bans a render-helper script that feeds the council.
      The mapper reads the verdict after the council ends, so the ban does not apply. The
      ban stays in force for every other script.

  - **(j) M14 claim budget (normative; WP 1-14).** One setting sets the maximum technical AC
    count for an M14 split: the constant `M14_AC_BUDGET` in `skills/council/engine.sh`.
    - The default is `16`. The hard ceiling is `M14_AC_BUDGET_CEILING=20`. A value above
      the ceiling MUST make the split fail closed.
    - Only the Tech Lead can raise the value, with a committed change and a new row in this
      spec's Version History.
    - The split MUST NOT read an environment variable, a flag, a plan field, or a spec
      field to change the value. A per-WP override MUST NOT exist.
    - The budget applies to M14 split runs only. Every other `/council` caller keeps the
      SPEC-013 claim budget of 10 and the 5-call investigator budget
      (`skills/council/prompts/investigator.md`).
    - An M14 per-AC claim with a `Verify:` command gets an 8-call investigator budget. An
      M14 claim with no `Verify:` command keeps 5 calls (SPEC-013 Phase 2; WP 1-15).
      The finder recipe **(g)** fits in 8 calls: one quote, one verify run, one filter and
      the token greps, grouped by file (WP 1-16). The budget does not change.

  - **(k) Tests (WP 1-14).** These tests MUST run in `tools/run-all-tests.sh`. They MUST
    start no live council and MUST write only under `TMPDIR`.
    - **Gate outcome fixtures.** For each fixture, assert card #2 `decision`,
      `blocking_condition`, `confidence` and `bump`: (i) all 7 ACs `VERIFIED` at 80 or
      higher → agree, `bump` copied; (ii) one `CONTRADICTED` → halt, 0; (iii) one AC
      missing → halt, 0; (iv) one AC at 79 → halt; (v) self-verified with all ACs at 95 →
      halt, 0. Add the `[process]` fail-closed cases: zero technical ACs, a guard 1 miss,
      and a stamp-shape miss with a `[process]` AC.
    - **Static guardrails.** Assert in this spec and in `skills/autopilot/ship-gate-council.md`:
      M14 fires once per attempt with exactly two cards; BC7 is reused and no ninth BC
      exists; no auto-clear, no self-answer past BC7 and no auto re-run; the **(d)**
      degraded rule is unchanged; `--council-tier` is the only flag.
    - **Non-M14 unchanged.** Assert that the preflight plan JSON of a non-M14 claim is
      unchanged, with `claim_budget` 10, and that the investigator budget stays 5 calls.
    - **Verify evidence (WP 1-15).** Assert the Verify line rule and cases 10-11 of
      **(g)**; the `verify` and `tool_budget` fields of each M14 claim; the M14 investigator
      render (budget 8, the verify section) and the non-M14 render (byte-identical to its
      form before WP 1-15); a fixture chain from a spec with 7 or more technical ACs to the
      rendered prompts; and mapper fixtures where every AC is at 80 or higher (agree), and
      where one AC has a verdict from a failing verify (BC7). The mapper **(i)** stays
      byte-identical.
    - **Finder recipe (WP 1-16).** Assert the recipe steps and the no-elision rule in the
      M14 render; run the render's quote and filter commands on fixtures; assert the judge
      caps; and run a pass and fail bundle-conformance fixture pair to the mapper. These
      tests prove the prompt text and the wiring. They do not prove what a live judge
      scores. The first live proof is the next ship gate after WP 1-16.

  - **(l) Grok nest deferral (normative; CDT-512-C6).** Grok nested `/orchestrate`
    (already `nest_depth>=1`) cannot spawn `/council`. That is a harness adapter,
    not an away-flag bug, and not a ninth BC. There is **no resident daemon**.
    - A child on Grok MUST NOT spawn `/council`. After tests on `feat/*` it
      returns `needs-parent-M14 SHA=<sha> branch=<branch>`. It MUST NOT write
      card #2 as a BC7 spawn-fail halt. It MUST NOT print resume-ship y.
    - The parent walker at `nest_depth` 0 runs M14 (`ship-gate-council.md`)
      then Stage 3. B.4 exports `DEVTEAM_NEST_DEPTH=1`. Helper:
      `skills/autopilot/nest-host.sh`.
    - `resume-ship` y remains only for real council disagree
      (`conf<80 / CONTRADICTED`). Depth-0 M14(d) self-verified / total-fail
      stays BC7. Away+autopilot MUST NOT require a Telegram y solely because
      of nest depth.
    - Decision enum stays frozen. `needs-parent-M14` is a procedure outcome,
      not a new card `decision`. Do not claim Grok nested spawn works unless
      proven. **(d)** / ship-gate §5 goldens and blob-pinned scripts stay
      unchanged.

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
  loc-exclude.sh filter
  ```

  Exit `0` = excluded (do not count). Exit `1` = count. Exit `64` = usage. The helper MUST
  never exit `2` to kill an orchestrate run. `filter` reads one path per line on stdin and
  prints `<path><TAB>0|1`. Arm 1 for that batch is one
  `git -C <worktree-root> check-attr --stdin` against the worktree that contains the cwd.
  Callers apply M15 and then apply M6.4 / M10.1
  bounds to the remaining LOC. BC4 stays **judgment-in-context** (not a budget-check-style
  scripted BC).

- **M16 — `--max-loc=<n|unbound>` DRI flag.** Flag-only per-run override. Council-tier
  precedent: `=` form, no env, junk → 64, duplicate → 64 (WP 1-08), not resume-seeded.

  **Parse** (`skills/autopilot/parse-flags.sh`, same argv scan as `--autopilot` /
  `--council-tier` / `--tier`):

  | Input | JSON `max_loc` | Exit |
  |---|---|---|
  | omit | `null` | 0 |
  | `--max-loc=<n>` with `n` matching `^[1-9][0-9]*$` | JSON **number** `n` | 0 |
  | `--max-loc=unbound` | JSON **string** `"unbound"` (case-sensitive) | 0 |

  MUST print **six** success keys: `enabled`, `bump`, `source`, `council_tier`, `tier`,
  `max_loc`. Independent of `--autopilot`, `--council-tier`, and `--tier` (no key writes
  another). A duplicate `--max-loc` exits **64** (same-value and different-value repeats alike,
  as `--tier` does; WP 1-08).

  MUST exit **64**, write the error to stderr, and print **no** success JSON for: junk;
  `0`; negative; `UNBOUND` / `off` / `none` / `unlimited` / `inf`; empty `--max-loc=`;
  bare `--max-loc`; space form `--max-loc n`. Step 0 MUST halt before fetch, worktree, or
  spawns.

  **Duplicates and near-misses (all four `parse-flags.sh` flags; WP 1-08, CDT-281).** A second
  occurrence of `--autopilot` (bare or `=` form, in any order), `--council-tier`, `--tier` or
  `--max-loc` MUST exit **64**. An argument that starts with `--auto`, `--council`, `--tier` or
  `--max` and is not one of these four flags, bare or with `=<value>` (for example `--autopliot`,
  `--max-locs=5`), MUST exit **64**.
  Every other `--*` argument still passes through untouched: the other parser families
  (`/orchestrate` `--resume-ship`, `/kickoff` `--effort` / `--worktree`, `/epic` flags) are not
  this parser's to judge (SPEC-025 M14 item 6). `skills/autopilot/loc-exclude.sh` moves to the repo
  top level itself, so a caller in a subdirectory gets the same answer for a repo-relative path.

  MUST NOT read `MAX_LOC`, `AUTOPILOT_MAX_LOC`, or any env for this cap. MUST NOT persist
  in `resume-state.sh`. MUST NOT auto-propagate on `reroute-epic` (the `/epic` child
  re-parses its own argv).

  **Consumption:** the value is used only when autopilot is **active**. Autopilot off:
  still parse (junk → 64); the value is unused. `/kickoff` and `/epic` share the parser;
  an unused `.max_loc` MUST NOT change those workflows. MUST NOT document `--max-loc` on
  `/kickoff`. `/orchestrate` Step 0 MUST bind `.max_loc` from the **same** `parse-flags.sh`
  call as the other keys.

  **Effects** (counted LOC, M15; BC4 = `plan-approve` only; M10.1 = `scope-confirm`
  only, WP 1-08):

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

  **Fixtures** (`skills/autopilot/fixtures/self-answer-scenarios.json`): rewrite **F4** so the 1400-line
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

### AC9 — `/orchestrate` run-budget auto-tune (CDT-224 / M9b)

A gate is **never** removed. This AC changes **which numbers** BC6 and M10.6 use on
`/orchestrate`. It MUST NOT add a ninth blocking condition. It MUST NOT add `--skip-bcN`.
It MUST NOT add a budget-cap flag. `parse-flags.sh` stays six-key.

- **M9b — Complexity-derived caps, `/orchestrate` only.** Auto-tune MUST run only when
  `workflow=orchestrate`. `/kickoff` and `/epic` Mode A MUST keep static 25 / 2700 unless
  env is set. An epic child's `/orchestrate` MUST derive its own tier. It MUST NOT inherit
  a parent freeze. Autopilot off MUST keep M1 (no behavior change).

  **Signals** (caller-supplied at `plan-approve`; NOT disk-read by the engine):
  - `tasks` — plan task count (non-negative integer).
  - `projected_loc` — projected **counted** LOC (M15). Run `loc-exclude.sh is-excluded`
    on plan paths. Do not reimplement CDT-223. `--max-loc=unbound` MUST NOT zero this
    signal.
  - `waves` — parallel-wave count. A plan with no `depends_on` and no wave labels MUST
    report `waves=1`. Else count topological ranks in the task graph (independent tasks
    at the same depth share one rank).

  Missing signals MUST fall back to `tasks=0`, `projected_loc=0`, `waves=1` (tier **S**).

  **Tier table** (L first, then S, else M). One tier drives both caps:

  | Match (first wins) | `tier` | `iteration_cap` | `wall_clock_cap_s` |
  |---|---|---|---|
  | `tasks≥6` OR `projected_loc>1000` OR `waves≥3` | **L** | 40 | 4500 |
  | `tasks≤3` AND `projected_loc≤300` AND `waves=1` | **S** | 10 | 1200 |
  | else | **M** | 25 | 2700 |

  Auto-tune MUST NOT grant more than 40 stints or 4500 s. Env MAY exceed that ceiling.

  Normative boundary rows:

  | tasks | loc | waves | tier | caps |
  |---|---|---|---|---|
  | 3 | 300 | 1 | S | 10 / 1200 |
  | 4 | 300 | 1 | M | 25 / 2700 |
  | 3 | 301 | 1 | M | 25 / 2700 |
  | 3 | 300 | 2 | M | 25 / 2700 |
  | 5 | 1000 | 2 | M | 25 / 2700 |
  | 6 | 100 | 1 | L | 40 / 4500 |
  | 2 | 1001 | 1 | L | 40 / 4500 |
  | 2 | 200 | 3 | L | 40 / 4500 |
  | 100 | 5000 | 5 | L | 40 / 4500 |

  `budget.tier` is **not** `--tier` and is **not** `council_tier`.

  **Precedence** (per cap, independently). Env is set when the variable is **non-empty**.
  Empty or unset is not set. Junk (not a non-negative integer) MUST exit 64.
  The env caps are **external input** (WP 1-08, CDT-310). `budget-check.sh` and
  `append-card.sh` MUST validate them whenever they read them: a set value MUST be a
  non-negative decimal integer of at most 15 digits with no leading zero (`0` itself is legal).
  Otherwise the script exits 64, names the variable on stderr, and writes no card. The same
  15-digit rule applies to every numeric argument of both scripts (`iteration`,
  `run_start_epoch`, `wall_clock_s`, caps, derive signals); `confidence` MUST match `0..100`
  and `blocking_condition` `1..8` by pattern, before any `-gt` / `-lt` / `-ge` test, so an
  overflowing value can never skip a range check or the BC7 `< 80` invariant.

  1. Env (`AUTOPILOT_ITERATION_CAP` / `AUTOPILOT_WALLCLOCK_CAP`) if set.
  2. Else auto-tune (table above) after freeze.
  3. Else static M (25 / 2700).

  Mixed = one cap from env and one from auto-tune. MUST NOT write
  `AUTOPILOT_ITERATION_CAP` or `AUTOPILOT_WALLCLOCK_CAP` to apply auto-tune.

  Pre-freeze `scope-confirm`: env or static M. S-tighter caps are **not** in force.

  **Freeze.** At `plan-approve`, derive and mix env **before** the BC4/5/6 walk.
  Write the freeze on that card. Later `/orchestrate` gates (including `ship-choice`)
  MUST copy it. The freeze is immutable for the run, including resume. Mid-run env
  mutation MUST NOT retune a frozen run. `reroute-epic` MUST NOT propagate frozen
  caps. `resume-state.sh` MUST NOT seed caps from plan frontmatter. Pre-CDT-224 cards
  (nested keys absent) resume as static M unless env is set.

  **BC6** keeps the same compare (`iteration >= iteration_cap` OR
  `wall_clock_s >= wall_clock_cap_s`) against **effective** numbers. Fixtures:

  | Case | Expected |
  |---|---|
  | S freeze; `iteration=10` or `wall_clock_s≥1200` | BC6 halt |
  | S freeze; `iteration=9` and `wall_clock_s=1199` | no BC6 |
  | M freeze; `iteration=25` | BC6 halt |
  | L freeze; `iteration=26` and `wall_clock_s=2701` | no BC6 |
  | L freeze; `iteration=40` or `wall_clock_s≥4500` | BC6 halt |
  | L table + env `AUTOPILOT_ITERATION_CAP=25` | BC6 halt at 25 (mixed/env) |
  | `/kickoff` would-be S; `iteration=10` | no BC6 (static 25) |

  **M10.6** is judgment against the effective wall-clock cap (AC4). MUST NOT suppress
  M10.1–5.

  **Helper argv** (`skills/autopilot/budget-check.sh`; extend; no second helper):

  | Invocation | Caps | Env |
  |---|---|---|
  | `budget-check.sh <iteration> <run_start_epoch>` (argc=2) | env or static M | read `AUTOPILOT_*_CAP` as today |
  | `budget-check.sh <iteration> <run_start_epoch> <iteration_cap> <wall_clock_cap_s>` (argc=4) | verbatim frozen caps | MUST NOT re-read `AUTOPILOT_*_CAP` |
  | `budget-check.sh derive <tasks> <projected_loc> <waves>` | raw table only | MUST NOT read env |

  Argc=3 MUST still exit 64 (existing test s3). Other argc MUST exit 64. `derive`
  stdout is compact JSON `{tier, iteration_cap, wall_clock_cap_s, signals}`. Check
  stdout keeps the existing **7 keys** with effective numbers. Kickoff/epic/scope-confirm
  keep argc=2.

  **Writer snapshot.** `append-card.sh` argc stays 13\|14\|15\|16. Effective caps and
  nested `budget.*` come from process-local `AUTOPILOT_BUDGET_META` (compact JSON:
  `iteration_cap`, `wall_clock_cap_s`, `tier`, `source`, `signals`). This name is
  **not** `AUTOPILOT_ITERATION_CAP` or `AUTOPILOT_WALLCLOCK_CAP`. Unset META → current
  env-or-default numerics and nested keys `null`. Set META → write those fields
  verbatim; MUST NOT also apply `AUTOPILOT_*_CAP`. MUST NOT export META to a child
  `/epic` or `/orchestrate`.

  **Engine.** `self-answer.md` envelope MUST gain `tasks`, `projected_loc`, `waves`
  at `plan-approve`. Derive then freeze before the BC walk. Later gates pass argc=4
  from the freeze. F6 MUST pin M signals. Add S/L variants per the table above.

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
- **S5** — A freeze card SHOULD name the three signals (`tasks`, `projected_loc`, `waves`)
  in `rationale` when `source` is `auto` or `mixed`.

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
  `git merge --squash` — which moves **no** ref and creates **no** commit. **Clean-tree
  precondition (WP 1-05; CDT-260 `[05 F2]`):** before the squash, autopilot MUST run
  `git-safety.sh is-clean --tracked-only` (SPEC-025 M17) on the main-repo checkout. When tracked
  edits exist, autopilot MUST write a halt card, exit ≠0 and change nothing. Untracked files do
  not block: `merge --squash` refuses to overwrite them, and a reset never touches them. Every
  undo of the squash stage — the squash-conflict path (`end-state.md` §4) and both land-abort
  paths (§6.5) — MUST call `git-safety.sh safe-reset --clean-at <sha>`, where `<sha>` is the HEAD
  at which that gate passed, and MUST NOT run a bare `git reset --hard`. When HEAD has moved (a
  delivery commit exists), `safe-reset` refuses and autopilot halts for a human.

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

  **Fetch first (WP 1-08, CDT-340).** The force-push clause needs a current `origin/<default>`:
  before the ancestry test, autopilot MUST run `git fetch --no-tags origin <default>` on the
  main-repo checkout. A failed fetch is a BC3 halt (fail-closed), never a pass on a stale ref.
  `--no-tags` keeps the fetch from adding tags inside the ship window (SPEC-010 D4). On the
  land-no-release path, autopilot takes the SPEC-010 H2 tag snapshot (`skills/release/ship-start.sh`)
  when it records `SHIP_START_SHA`, passes it as `--tag-snapshot` to the post-land
  `check-ship-history.sh` run (a missing snapshot fails closed), and clears it after a clean
  check. On the release path, `/release` Step 5.5 and Step 6 own the ship-history checks,
  including the snapshot half.

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
- **N12** — MUST NOT write `AUTOPILOT_ITERATION_CAP` or `AUTOPILOT_WALLCLOCK_CAP` to apply
  auto-tune. MUST NOT add a budget-cap flag or a seventh `parse-flags.sh` key.
- **N13** — MUST NOT auto-tune `/kickoff` or `/epic` Mode A. MUST NOT inherit frozen caps
  across `reroute-epic` or onto an epic child `/orchestrate`. MUST NOT resume-seed caps
  via `resume-state.sh` plan frontmatter.
- **N14** — MUST NOT add a fourth `gate` value, a new card `type`, or a ninth BC for
  budget-tier. Nested `budget.tier` is **not** `--tier` and is **not** `council_tier`.
  MUST NOT raise the auto-tune L ceiling above 40 / 4500. MUST NOT add a `/setup`
  budget store. MUST NOT reimplement `loc-exclude.sh`.
- **N15** — MUST NOT use `max_verdict_confidence`, a mean, or one "overall" verdict to
  decide the M14 gate (M14(b), WP 1-14). MUST NOT audit all ACs in one claim.
- **N16** — MUST NOT read an environment variable, a flag, or a plan or spec field for the
  M14 claim budget. MUST NOT set it above `M14_AC_BUDGET_CEILING` (M14(j)). MUST NOT
  truncate, merge, or drop AC claims to fit the budget.
- **N17** — MUST NOT clear an AC with a runner log, a QA evidence file, or an AC→evidence
  map (M14(a), M14(h)). MUST NOT tag an AC `[process]` when it asserts diff content.
  An investigator's own run of a `Verify:` command during the council pass is evidence, not
  a runner log (M14(a), WP 1-15). It does not clear an AC by itself.
- **N18** — MUST NOT BC7-halt a Grok nested child because `/council` cannot spawn
  (M14(l)). MUST NOT print resume-ship y or ping intercom for nest depth.
  MUST NOT add a ninth BC or a resident daemon. MUST NOT treat Grok nest
  spawn-fail as `--resume-ship` y.

---

## Open questions (non-blocking; deferred to wiring children)

- OQ1 — Exact escalation/notify transport on halt (webhook vs. inline print) — owned by the wiring
  child, not this contract. **Resolved by CDT-111-C7:** halt escalations emit `task_blocked` and
  autopilot end-states (`pr` / release-merge / land-no-release success) emit `task_complete`, both
  via `/orchestrate`'s **Passive notifications → Tier B** helper (`skills/notify/webhook.sh`,
  fail-open); reuses the existing CDV-210 event enum — no new event, no new transport (AC3).
- OQ2 — Whether the epic-level walker gets its own aggregate budget distinct from the sum of child
  budgets — deferred until `/epic` autopilot wiring. **CDT-224 does not resolve OQ2** (AC9.10).
- OQ3 — Whether `confidence` is self-reported by the answering agent or derived from a council
  micro-check — the schema accommodates either. **Resolved for `ship-choice` by M14
  (council-derived); remains self-reported for `scope-confirm` / `plan-approve`.**

---

## Acceptance criteria

Format and rules: M14(g) and M14(h). Each ticket that ships through M14 has one
`### <ticket_id>` subsection below.

### wp-1-14-m14-ship-gate-evidence

- **A.** SPEC-033 M14 has a dated revision row that states the multi-AC evidence rule and names the adversarial review report. `skills/autopilot/ship-gate-council.md` cites M14 and does not restate it.
- **B.** The guardrails stay, and a static test asserts each one in SPEC-033 and in `skills/autopilot/ship-gate-council.md`:
  - M14 fires once per attempt, with exactly two cards.
  - BC7 is reused; no ninth BC is added.
  - There is no auto-clear, no self-answer past BC7 and no auto re-run.
  - The M14(d) degraded rule is unchanged (self-verified or total spawn fail → halt, confidence 0).
  - `--council-tier` is the only flag.
- **C.** Each technical AC of a WP is audited as its own falsifiable claim with its AC id, in one `/council` invocation. The claim envelope names the AC source with `ac-source=<path>`. The AC source is the `## Acceptance criteria` section of the committed spec (M14(g)). Spec checkbox sections, kickoff plans and carriers are not the AC source.
- **D.** Aggregation follows M14(b):
  - Agree only if every AC claim is `VERIFIED` or `PARTIALLY_VERIFIED` at 80 or higher.
  - Card #2 confidence is the lowest AC claim confidence.
  - Any `UNVERIFIED`, `CONTRADICTED` or `FABRICATED` claim gives confidence 0 and BC7.
  - The gate never uses `max_verdict_confidence`.
- **E.** Missing evidence halts. An AC with no verdict gives BC7 and confidence 0, and the rationale names the unaudited AC ids. This covers dropped claims and empty bundles. An AC over the budget is not "unaudited": it fails the split closed at M14(g) case 9, step 1 of M14(b), before any claim exists. The `[process]` rules fail closed: zero technical ACs, a guard 1 miss, or a `[process]` AC with no matching card #1 stamp gives BC7 and confidence 0.
- **F.** A deterministic fixture test of the gate outcome (card #2 decision, blocking_condition, confidence and bump) covers these cases, plus the `[process]` fail-closed cases:
  - (i) all 7 ACs `VERIFIED` at 80 or higher → agree, bump copied;
  - (ii) one `CONTRADICTED` → halt, 0;
  - (iii) one AC missing → halt, 0;
  - (iv) one AC at 79 → halt;
  - (v) self-verified with all ACs at 95 → halt, 0.
  The test is discovered by `tools/run-all-tests.sh`, starts no live council and writes only under `TMPDIR`.
- **G.** The change is scoped to M14. Every other `/council` caller keeps 5 calls per investigator and a 10-claim budget. A test asserts that the non-M14 claim plan JSON is unchanged.
- **H.** Independent evidence stays within M14(a). No QA evidence file, runner log or AC→evidence map is passed to the council.
- **I.** [process] An attended replay of the new M14 ship gate against WP 1-02 (`2069426..fbfe91d`, 7 ACs, 37 files) reaches 80 or higher. The replay is read-only and writes no `.claude/autopilot/wp-1-02-*.jsonl` file. Its report path, verdict and council wall time go in the ship notes. A halt for a real evidence gap fails this AC.
- **J.** BC6 and the wall-clock caps are unchanged.
- **K.** A council report and its `.finalize-meta.json` sidecar are never overwritten, in any scope of `cmd_report_path`.
- **L.** With no collision, the report path is byte-identical to the path before this change. On a collision, the new path is deterministic and unique (`-<N>`, N ≥ 2). `plan.report_path`, the finalize write, the `Council report:` line and the index `report_path` agree.
- **M.** Finalize reserves the report path again at write time and never overwrites a file without a message.
- **N.** An explicit `--report-out PATH` keeps its behavior before this change, and the docs state this.
- **O.** A regression test shows that two same-day unbound claim runs give two reports and two sidecars, and that the bytes of the first report stay the same. The test is hermetic (temp MROOT) and does not depend on wall time.
- **P.** The path contract homes are updated: `skills/council/SKILL.md` (canonical report path and the blind-path report line) and SPEC-013 Phase 6, Task Binding, the blind path and the Council-on-Workflow naming.
- **Q.** [process] `bash tools/run-all-tests.sh` exits 0, and every `/release` gate passes.
- **R.** [process] The plan-approve council gate (council-full) reviewed the SPEC-033 M14 revision. Every `CONTRADICTED` or `FABRICATED` item is resolved or rejected with a reason.
- **S.** [process] The ship gate of this WP runs the old rule, because skills load from `master`. A BC7 halt and an attended `--resume-ship=patch` are expected.
- **T.** Each other defect found is recorded as a local backlog item and is not fixed in this WP.

### wp-1-15-m14-verify-evidence

- **A.** SPEC-033 has a dated WP 1-15 revision row. It amends M14(a) and M14(g): the `Verify:` line rule, the per-AC investigator runs the command itself, and the output of that run is not a "runner log". `skills/autopilot/ship-gate-council.md` cites M14(a) and M14(g) and does not restate the Verify line rule.
  Verify: bash skills/autopilot/test-ship-gate-guardrails.sh
- **B.** `skills/council/m14-ac-split.sh` reads at most one `Verify:` continuation per technical AC and adds `verify` (the command, or `null`) to each AC in its JSON. A Verify line that breaks the M14(g) rule, a second Verify line on one AC, or a Verify line on a `[process]` AC fails closed as M14(g) case 10 (exit 8, the AC ids on stderr). A Verify line with uncommitted changes to tracked files fails closed as case 11.
  Verify: bash skills/council/test-m14-ac-split.sh
- **C.** Each M14 plan claim carries `verify` (the command, or `null`) and `tool_budget` (8 with a command, else 5). The claim text and its `[AC-<id>]` prefix are unchanged. The Task path and the Workflow path pass both fields through with the claim.
  Verify: bash skills/council/test-m14-split.sh
- **D.** For a claim with a command, the rendered investigator prompt has an 8-call budget and tells the investigator to run the command first, from the worktree top level, with `TMPDIR` under `CACHE_DIR`, and to put the command, its exit line and its raw output in one bundle. That run is the only permitted mutating Bash, and it writes only under its `TMPDIR`. The judge prompt treats a non-zero exit, a skip or a timeout as evidence against (no `VERIFIED` or `PARTIALLY_VERIFIED`), keeps a claim with no verify bundle below 80, and does not accept a pass alone. `{{TOOL_BUDGET}}` and `{{VERIFY_COMMAND}}` are registered in the prompt table, `commands/council.md` and `skills/council/SKILL.md`.
  Verify: bash skills/council/test-verify-prompts.sh
- **E.** For a claim with no command, the rendered investigator prompt has a 5-call budget and no verify section. The non-M14 investigator render is byte-identical to its render at `cbee656`, and the non-M14 preflight plan JSON is unchanged.
  Verify: bash skills/council/test-non-m14-plan.sh
- **F.** A deterministic fixture test runs one spec subsection with 7 or more technical ACs (some with a Verify line, one without) through the split, the preflight plan claims and the rendered investigator prompts. Mapper fixtures show that 7 or more ACs at 80 or higher map to agree, and that one AC with a verdict from a failing verify maps to BC7 with confidence 0.
  Verify: bash skills/autopilot/test-m14-verify-chain.sh
- **G.** The clearing rule is unchanged. `skills/autopilot/ship-gate-verdict.sh` is byte-identical to `cbee656`. The SPEC-033 M14(b) and M14(d) blocks are unchanged. The `ship-gate-council.md` §5 wording stays.
  Verify: bash skills/autopilot/test-ship-gate-guardrails.sh
- **H.** Each verdict heading in a council report shows `### Claim <id>: <claim text>` and never `Claim ?`. Extracted Claims lists each claim id and its text. A single-claim run shows the claim text from the plan. A finalize fixture covers an M14 run and a single-claim run.
  Verify: bash skills/council/test-finalize-claim-ids.sh
- **I.** Phase 2.5 cross-review runs per claim on the Workflow path and in `commands/council.md`. Each reviewer gets the text of the claim that owns the bundles. `workflow.js` does not use `claims[0]` for `CLAIM_TEXT`. A claim with fewer than 3 bundles bypasses cross-review, and the report records the reason for that claim.
  Verify: bash skills/council/test-workflow-static.sh
- **J.** The Phase 4 brief and judge prompts each state that a spec checkbox line is not evidence, and the investigator prompt states it in its verify section, in words that fit the role of each prompt. SPEC-033 M14(g) holds the note.
  Verify: bash skills/council/test-prompt-checkbox-rule.sh
- **K.** The g4-bite check finds the M14(d) block by its `(d)` and `(e)` markers, with no fixed line number. It still bites, and it still bites when one line is inserted above the block.
  Verify: bash skills/autopilot/test-ship-gate-guardrails.sh
- **L.** The `/orchestrate` Step 4, Step 6 and Step 10b spec writers ask for a `Verify:` continuation on each technical AC. Step 10b lists the technical ACs with no Verify line and the Verify files that do not call `hermetic_init`.
  Verify: bash skills/autopilot/test-ship-gate-guardrails.sh
- **M.** This subsection has a Verify line on every technical AC, and each Verify line parses under the split script.
  Verify: bash skills/council/test-m14-ac-split.sh
- **N.** `tools/run-all-tests.sh` discovers every test file that a Verify line in this subsection names. None of these tests starts a live council, and each calls `hermetic_init` and writes only under `TMPDIR`.
  Verify: bash skills/council/test-m14-suite-hygiene.sh
- **O.** [process] `bash tools/run-all-tests.sh` exits 0.
- **P.** [process] Every `/release` gate passes.

### wp-1-16-m14-finder-recipe

- **A.** For a claim with a `verify` command, the rendered investigator prompt holds the M14(g) finder recipe as three numbered steps in this order: (1) one quote command anchored on the `SOURCE_LOCATOR` line; (2) the Verify run, then one filter command over its saved output; (3) one grep per named token. Step 3 names the four token classes (backtick spans, `path:N` locators, `Case N` and `AC X` references, numbered sub-clauses) and allows one `grep -nF -e` call per file. The render does not hold "cite the test lines and one diff hunk". The render of a claim with no `verify` command is byte-identical to its render at `38bc739`.
  Verify: bash skills/council/test-verify-prompts.sh
- **B.** For a claim with a `verify` command, the rendered investigator prompt does not hold "last 40 lines". It states that a `raw_blob` is the complete output of its own `reproducible_command`, that a `raw_blob` holds no `...`, `[...]` or `…` line and no text added after the output, and that this rule replaces the "3 lines of context" rule for the claim. It states that the verify bundle keeps `reproducible_command` equal to the claim's command and holds the `VERIFY exit=` line, and that the filter output is a separate bundle.
  Verify: bash skills/council/test-verify-prompts.sh
- **C.** The test takes the quote command and the filter command from the rendered prompt and runs them on fixtures. On a fixture spec with two `### <ticket_id>` subsections that both hold `- **A.**`, the quote command for AC A of the second subsection prints only that bullet and its continuation lines, each with its line number. On a fixture log that holds the AC's own lines first, then more than 40 other lines, then FAIL, SKIP, summary and `VERIFY exit=` lines, the filter prints every AC line, every FAIL and SKIP line, the summary lines and the `VERIFY exit=` line.
  Verify: bash skills/council/test-verify-prompts.sh
- **D.** The judge prompt states that for a claim with a `verify` command the confidence is 79 or lower when no bundle quotes the AC bullet at the claim's source locator, when a token of class backtick span, `path:N`, `Case N` or `AC X` named in that quote has no bundle, other than the step 1 quote bundle, with a matching line, or when a bundle holds a `...`, `[...]` or `…` line. Each of the three caps has a bite test. The five WP 1-15 verify-evidence rule bullets in `judge.md` are byte-identical to `38bc739`.
  Verify: bash skills/council/test-verify-prompts.sh
- **E.** A test-only conformance check runs on fixture bundles for a fixture WP subsection with 3 or more technical ACs, in a private git repo. It passes only when each bundle other than the verify bundle byte-equals a re-run of its `reproducible_command`, each Verify command exits 0 and its bundle holds `VERIFY exit=0`, one bundle holds the anchored AC quote, and each token of class backtick span, `path:N`, `Case N` or `AC X` named in that quote has a bundle, other than the quote bundle, with a line that holds it. The conformant set passes. A set with one Verify stub at exit 1 fails, a set with one named token absent from the repo fails, and a set with one `...` line fails. `skills/autopilot/ship-gate-verdict.sh` maps a synthetic finalize-meta with every AC at 80 or higher to `blocking_condition` null, and one with one AC at 79 to `blocking_condition` 7.
  Verify: bash skills/autopilot/test-m14-verify-chain.sh
- **F.** The clearing rule is unchanged and the docs cite the recipe. `skills/autopilot/ship-gate-verdict.sh` and `skills/autopilot/append-card.sh` are byte-identical to `38bc739`. The SPEC-033 M14(b) and M14(d) blocks match their goldens. `skills/autopilot/ship-gate-council.md` §5 is byte-identical to `38bc739`, and its §3b cites the M14(g) finder recipe. `skills/council/engine.sh` holds `M14_VERIFY_TOOL_BUDGET=8` and `INVESTIGATOR_TOOL_BUDGET=5`. SPEC-033 has a dated WP 1-16 row that names M14(g), M14(j), the no-elision rule and the judge caps, and states that the caps can only lower a confidence. SPEC-013 has a dated WP 1-16 row.
  Verify: bash skills/autopilot/test-ship-gate-guardrails.sh
- **G.** This subsection parses under `skills/council/m14-ac-split.sh` with 8 technical ACs, each with one Verify line, and the `[process]` ids I, J, K and L.
  Verify: bash skills/council/test-m14-ac-split.sh
- **H.** `tools/run-all-tests.sh --list` finds each test file that a Verify line in this subsection names. Each of these files calls `hermetic_init` and starts no live council.
  Verify: bash skills/council/test-m14-suite-hygiene.sh
- **I.** [process] `bash tools/run-all-tests.sh`, `skills/council/test-m14-ac-split.sh` and `skills/autopilot/test-ship-gate-guardrails.sh` exit 0, and every `/release` gate passes.
- **J.** [process] The release notes record that this WP's own ship gate ran the old finder prompt from `master`, and that a BC7 halt there with every Verify at exit 0 is not a code gap.
- **K.** [process] The release notes name the next WP's ship gate as the first live test of the recipe. The loop journal records its per-AC confidences, and a BC7 on an AC with no code gap gets a local backlog item.
- **L.** [process] Before the release, three local backlog items exist: judge delivery of large bundles and the classifier stop; a spec-writing lint for technical-AC clauses that no command can check; and an M14 report path that is absolute under the main repo root (the lost WP 1-07 report).

### wp-1-08-autopilot-state

- **A.** `skills/autopilot/append-card.sh` exits 64, names the field on stderr and adds no ledger line for: `confidence` `99999999999999999999999`, `abc`, `101` or `007`; `blocking_condition` `99999999999999999999999` or `9`; an `iteration` or `wall_clock_s` of 16 digits or with a letter; `AUTOPILOT_ITERATION_CAP` or `AUTOPILOT_WALLCLOCK_CAP` set to `abc` or to 16 digits while `AUTOPILOT_BUDGET_META` is unset. `blocking_condition` `7` with `confidence` `80` still exits 64. `skills/autopilot/budget-check.sh` exits 64 for a 16-digit `iteration` or `run_start_epoch` and for the same env caps, and its stderr names the variable. `skills/autopilot/self-answer.md` does not contain `never external input` and states that the env caps are external input.
  Verify: bash skills/autopilot/test-card-validation.sh
- **B.** `skills/autopilot/self-answer.md` §3f holds one bash fence that reads the freeze with `read-cards.sh`, calls `budget-check.sh` and calls `append-card.sh`. Run as extracted in a new shell with `AUTOPILOT_BUDGET_META`, `AUTOPILOT_ITERATION_CAP` and `AUTOPILOT_WALLCLOCK_CAP` unset, against a ledger with a plan-approve freeze of 40 / 10800 (tier `L`) and the same `run_id`, the fence appends a ship-choice card with `budget.iteration_cap` 40, `budget.wall_clock_cap_s` 10800 and `budget.tier` `L`. With a different `run_id` and `RESUMING=false` the card does not carry that freeze. With a different `run_id` and `RESUMING=true` it does.
  Verify: bash skills/autopilot/test-card-validation.sh
- **C.** SPEC-033 Version History has a dated WP 1-08 row. Outside its `## Acceptance criteria` section, SPEC-033 does not contain ``Evaluated at `scope-confirm` and `plan-approve` ``, and neither does `skills/autopilot/SKILL.md`; both files contain ``Evaluated at `scope-confirm` only``. The F4-n-tight plan-approve fixture row in `skills/autopilot/fixtures/self-answer-scenarios.json` still expects a BC4 halt at `plan-approve`. `skills/autopilot/ship-gate-council.md` §2a gives the fresh halt card the `run_id` `orchestrate-<ISSUE-ID>-<RUN_START_EPOCH>`, and §6 requires `actor` `ship-gate-council` on card #2. The §5 text of `ship-gate-council.md` is byte-equal to its text at `38bc739`.
  Verify: bash skills/autopilot/test-contract-prose.sh
- **D.** `skills/autopilot/test.sh` exits 0 with no FAIL line when the caller exports `AUTOPILOT_WALLCLOCK_CAP=10800`, `AUTOPILOT_ITERATION_CAP=3`, `AUTOPILOT_BUDGET_META=junk` and `AUTOPILOT=1`.
  Verify: bash skills/autopilot/test-env-hermetic.sh
- **E.** With only a plan whose `## Tracking` has `ticket_id: CDV-30-C1`, `skills/autopilot/resume-state.sh CDV-30` prints `"found":false`. With a parent plan (`ticket_id: CDV-30`) added, it prints the parent path and the parent `autopilot_on` / `autopilot_bump`. An `- autopilot_on:` line outside `## Tracking` is ignored. A plan with no `ticket_id:` line gives `"found":false`. A plan in `<worktree>/.claude/plans` is found when the script runs inside that worktree. `--accumulated` prints `0` when `read-cards.sh` fails or no card exists. `--iteration CDV-30` prints the largest `budget.iteration` of that ticket's cards, or `0` with no cards.
  Verify: bash skills/autopilot/test.sh
- **F.** No bash fence in `skills/autopilot/end-state.md` has a line whose first word is `return`. The §3 fence runs `git fetch --no-tags origin` before `merge-base --is-ancestor`. Run as extracted against fixture repos, it exits non-zero when the fetch fails and when origin is ahead of the land target after the fetch, and exits 0 when the land target contains origin. The §3.5 fence calls `ship-start.sh` on the `master` bump. The §5.5 land-no-release fence passes `--tag-snapshot` to `check-ship-history.sh`, and exits non-zero when the snapshot file is missing. The §5.5 text names `/release` Step 6 as the ship-history authority on the release path.
  Verify: bash skills/autopilot/test-end-state-safety.sh
- **G.** No bash fence in `skills/epic/SKILL.md` has a line whose first word is `return`. The build-seed fence, run as extracted with a `build-seed` stub that fails, exits non-zero and does not call `validate-seed`. `skills/epic/epic-lib.sh init X --title --mode orchestrate` exits 64 and writes no `state.json`.
  Verify: bash skills/epic/test.sh
- **H.** One table-driven test sends duplicate, bare, empty, `=`, space-form and near-miss rows through `skills/autopilot/parse-flags.sh` and `skills/epic/parse-flags.sh`. Autopilot parser: `--autopilot=patch --autopilot`, `--autopilot --autopilot=patch`, a second `--council-tier` and a second `--max-loc` exit 64; `--autopliot` and `--max-locs=5` exit 64; `--worktree` and `--resume-ship` exit 0. Epic parser: `--worktre` and `--releas patch` exit 64; `--autopilot=patch` and `--redecompose` exit 0. The `skills/autopilot/parse-flags.sh` header states the duplicate rule. `skills/autopilot/loc-exclude.sh` gives the same exit code for a repo-relative path from a subdirectory as from the top level.
  Verify: bash skills/autopilot/test-flag-matrix.sh
- **I.** `ITER=$((ITER+1))` occurs in each of `skills/orchestrate/steps/04-kickoff.md`, `06-design.md`, `08-execute.md`, `09-review.md` and `10-qa.md`. `00-resolve.md` sets ITER from `resume-state.sh --iteration` when resuming. The extracted `00-resolve.md` run-start fence, with a `resume-state.sh` stub that prints nothing, sets `RUN_START_EPOCH` to the current epoch and writes nothing to stderr.
  Verify: bash skills/orchestrate/router-static-test.sh
- **J.** `skills/orchestrate/steps/cross-cutting.md` tells the orchestrator to write the `approval-wait:` halt card before it blocks on a human approval and to run the `00-resolve.md` re-mint fence on the reply. Fixture: last card an `approval-wait:` BC1 halt with `wall_clock_s` 2000, original run start 30000 s ago, caps 40 / 10800. The re-mint fence followed by `budget-check.sh` reports no breach, and the same check from the original run start reports a `wall_clock` breach. A ledger whose last card has `wall_clock_s` 11000 and no wait card still breaches after the re-mint. The re-mint leaves `RUN_ID` unchanged.
  Verify: bash skills/autopilot/test-bc6-approval-wait.sh
- **K.** [process] The release ship notes record the evaporated part (rv-w1-58 `epic-lib.sh` unknown flags, already `die 64` at `epic-lib.sh:203-204,281`) and the parts moved to WP 5-01 (05-questions BC1 branch, 10-qa `qa_bounces` cap, 10b marker, plan writers).
- **L.** [process] `bash tools/run-all-tests.sh` exits 0 and every `/release` gate passes.
- **M.** [process] The release ship notes record the WP 1-16 merge order: whichever of WP 1-08 and WP 1-16 ships second re-pins the g8 `append-card.sh` blob fixture in `skills/autopilot/fixtures/ship-gate-guardrails/`.

### wp-1-09-epic-seal

- **A.** `skills/epic/SKILL.md` A.5 and B.3 define the `/epic` action for a `reroute-epic` decision (M5 note (h)). A.5 runs it as a soft warn line `scope-confirm reroute-epic (soft warn)` with more than 8 proposed children and as `halt` otherwise; it never runs as `proceed`. B.3 runs it as `halt` that names `--redecompose` and states that a nested epic for a child is not allowed. Any other decision value runs as `halt`. The SKILL does not contain "shared C4 Decision→action map".
  Verify: bash skills/epic/test.sh
- **B.** `skills/epic/epic-lib.sh resolve-resume-flags` exits 64 for `--autopilot=patch`, `--autopilot=minor` and `--autopilot=major` over a state with a null `release_bump`. It exits 0 for `--autopilot=master` and for a bump over a stored `release_bump` (M11a (a)).
  Verify: bash skills/epic/test.sh
- **C.** The M5 `ship-choice` row in SPEC-033 and in `skills/autopilot/SKILL.md` says `/epic` ships only via B.7 seal (M14) and does not say `/epic` never ships. The `--autopilot` row of `commands/epic.md` says seal-intent and `release_bump`, and contains neither "Unused" nor "Independent of".
  Verify: bash skills/epic/test.sh
- **D.** [process] The suites that the ACs of this subsection and of SPEC-025 `### wp-1-09-epic-seal` name pass, `bash tools/run-all-tests.sh` passes and every `/release` gate passes. SPEC-025 holds the full AC set for this WP.

### CDT-512-C6

- **A.** Child `/orchestrate` on Grok (`nest_depth>=1`) MUST NOT require the child to spawn `/council`. `nest-host.sh` reports `can_spawn_council=false`; ship-gate §2b returns `needs-parent-M14` and MUST NOT write a BC7 halt.
  Verify: bash skills/autopilot/test-nest-host.sh
- **B.** Parent walker at `nest_depth` 0 runs M14, or nested spawn is allowed (Claude). Mode B exports `DEVTEAM_NEST_DEPTH=1` and on `needs-parent-M14` the parent walker runs M14.
  Verify: bash skills/autopilot/test-nest-m14.sh
- **C.** Away+autopilot MUST NOT require a Telegram y solely because of nest depth. Step 11 MUST NOT print the resume-ship y hint on `needs-parent-M14`.
  Verify: bash skills/autopilot/test-nest-m14.sh
- **D.** SPEC/docs state the Grok nest rule. `resume-ship` y remains only for real council disagree (`conf<80 / CONTRADICTED`). Depth-0 M14(d) is unchanged.
  Verify: bash skills/autopilot/test-nest-m14.sh
- **E.** [process] There is no resident daemon. No ninth BC. Decision enum frozen.
  Suites `skills/autopilot/test-nest-host.sh` and `test-nest-m14.sh` pass.

---

## Test

- SPEC-033/T1 — `skills/autopilot/parse-flags.sh` rejects a second `--autopilot` flag.
  Verify: bash skills/autopilot/test-flag-matrix.sh

## Validation

- [x] The acceptance subsections above name the suite that covers each rule

## Version History

| Date | Change |
|------|--------|
| 2026-10-07 | CDT-512-C6: **M14(l) Grok nest deferral.** Child `/orchestrate` on Grok (`nest_depth>=1`) cannot spawn `/council`. Return `needs-parent-M14`; parent at depth 0 runs M14. `resume-ship` y remains only for real council disagree (`conf<80 / CONTRADICTED`). N18. Helper `skills/autopilot/nest-host.sh`. **(d)** / §5 goldens unchanged. New `### CDT-512-C6` AC subsection. |
| 2026-10-02 | CDT-371: the "no workflow file edited here" note is historical. `ship-gate-council.md` already names the merge-base diff, not a staged diff. |
| 2026-10-01 | WP 5-06 (CDT-304, CDT-333): Status DRAFT → ACTIVE. M2 cross-references AGENTS.md: epic children seal through `/release`; non-epic `--autopilot=master` stays land-no-release. |
| 2026-09-30 | WP 1-09 (`wp-1-09-epic-seal`; CDT-322, rv-w2-34; the rest of the WP is in SPEC-025): **M5 note (h)** — `reroute-epic` at an `/epic` gate cannot hand off to `/epic`: A.5 prints a soft warn and continues when there are more than 8 proposed children and halts otherwise (never a silent proceed), B.3 runs it as `halt` with no nested epic allowed (`--redecompose` is never autopilot-started, note (g)), any other value runs as `halt`; the `/epic` SKILL defines the map itself. **M5 table** — the `/epic` `ship-choice` cell reads "ships only via B.7 seal (M14)", not "never ships". **M11a (a)** — the `release_bump` persist happens at `init`, so a release-bump token over a null durable `release_bump` on resume exits 64 and is never set on the session alone. New `### wp-1-09-epic-seal` AC subsection. Status stays DRAFT. |
| 2026-09-28 | WP 1-16 (`wp-1-16-m14-finder-recipe`; backlog `m14-finder-evidence-recipe`): **M14 finder evidence recipe.** Premise: the WP 1-05 and WP 1-06 ship gates (`.claude/council/2026-09-28-claim-wp-1-05-m14.md`, `.claude/council/2026-09-28-claim-wp-1-06-m14.md`) halted on BC7 with every Verify at exit 0 and no code gap; the judge struck elided `raw_blob` lines, ACs with no quote of their text, and named literals that no bundle held. **M14(g)** — new "Finder recipe" bullet: an AC quote anchored on the `<path>:<line>` locator (bullet plus continuation lines); the Verify run plus one AC-label filter bundle; one grep per token class, bounded and scoped — one default call against the Verify test file for backtick spans, `Case N` and `AC X` tokens, an explicit locator command for `path:N`, and a scoped multi-token `git grep` fallback (never unscoped) only for a token the default call missed; numbered sub-clauses are grepped too, as advisory evidence. No-elision rule: a `raw_blob` is the complete output of its own `reproducible_command`, with no `...`, `[...]` or `…` line and no text added after the output; the one exception is the Verify-run bundle, whose `raw_blob` is the complete stdout of the wrapped Step 2 call (a bare re-run of `reproducible_command` alone would print the suite's unredirected log instead) — it is exempt from the raw_blob-equals-a-rerun-of-reproducible_command invariant the other recipe bundles hold. The finder takes the tokens from its own quote; the split, the engine and the claim record carry no AC text or tokens (M14(a)). Judge caps: confidence 79 or lower for a missing AC quote, an unmatched named token of class backtick span, `path:N`, `Case N` or `AC X` (matched outside the Step 1 quote bundle) or an elision line (SPEC-013 Phase 5); a numbered sub-clause named in the quote is advisory evidence only and carries no cap. The recipe and the caps can only lower a confidence: they feed nothing new to the mapper **(i)**, add no clear path, and leave **(b)**, **(d)**, the firing rule, the two cards and BC7 reuse unchanged. An engine-side strike was rejected, because it would change how the gate clears (`ship-gate-council.md` §5). **M14(j)** — the recipe fits the 8-call budget; the budget does not change. **M14(k)** — recipe tests; they prove prompt text and wiring, not a live judge score. A claim with no `Verify:` command keeps its render. This WP's own gate runs the old prompt from `master`; the next WP's gate is the first live proof. New `### wp-1-16-m14-finder-recipe` AC subsection. Status stays DRAFT. |
| 2026-09-28 | WP 1-08 (`wp-1-08-autopilot-state`; CDT-340, CDT-331, CDT-310, CDT-311, CDT-307, CDT-368, CDT-278 `[06 T-00resolve]`, CDT-281 `[05 T-parse-flags]` `[05 T-ship-gate]`, rv-w1-53, rv-w1-58): **M9a** — approval wait does not count toward BC6 (user decision 2026-09-28). A blocking human approval inside a live `/orchestrate` run is an M8 halt: an `approval-wait:` card (BC1, or BC3 for a destructive action) before the wait, then a same-session re-mint of `run_start_epoch` by the resume rule on the reply (`run_id` unchanged). This changes when BC6 fires (a safety halt) for human wait time only; BC6 stays a hard stop for active time; no new field, gate, `type` or BC. Plan lookup by exact Tracking `ticket_id:` through `skills/lib/plan-resolve.sh` (toplevel then `$MROOT`, newest mtime, legacy → not found); `--accumulated` always an integer; ITER restored from `resume-state.sh --iteration` and incremented at each spawn site. **M10.1** — evaluated at `scope-confirm` only (BC4 owns plan-approve overflow; matches fixture F4-n-tight). **M13** — ship-choice card #2 carries `actor: ship-gate-council`, card #1 never does; fresh §2a halt card `run_id` = `orchestrate-<ISSUE-ID>-<RUN_START_EPOCH>`. **M16** — duplicate `--autopilot` / `--council-tier` / `--max-loc` exit 64 (was last-wins), near-miss own-family flags exit 64, other families pass through; `loc-exclude.sh` resolves from the repo top level. **AC9** — env caps are external input: validated (canonical integers of at most 15 digits, exact in `jq`) by `budget-check.sh` and `append-card.sh`; every numeric card argument validated by pattern before arithmetic. **N3a** — fetch first (`git fetch --no-tags origin <default>`; failure → BC3); land-no-release takes, checks and clears the SPEC-010 H2 tag snapshot; `/release` owns the checks on the release path. The M14 clearing rule (**(b)**, **(d)**, the mapper, `ship-gate-verdict.sh`, `ship-gate-council.md` §5) is unchanged. New `### wp-1-08-autopilot-state` AC subsection. Status stays DRAFT. |
| 2026-09-27 | WP 1-05 (`wp-1-05-git-safety-lib`; CDT-260 `[05 F2]`): **N3a (iii)** gains a clean-tree precondition. Before the squash, autopilot runs `git-safety.sh is-clean --tracked-only` (SPEC-025 M17) on the main-repo checkout; tracked edits give a halt card, exit ≠0 and no change; untracked files do not block. Every undo of the squash stage (`end-state.md` §4 conflict path, §6.5 land-abort paths) calls `git-safety.sh safe-reset --clean-at <sha>` and never a bare `git reset --hard`; a moved HEAD makes `safe-reset` refuse and autopilot halt for a human. The former "fully reversible with `git reset`" wording is withdrawn. Behavioural suite: `skills/autopilot/test-end-state-safety.sh`. The ACs live in SPEC-025 `### wp-1-05-git-safety-lib`. |
| 2026-09-27 | WP 1-15 (`m14-per-ac-verify-command`): **M14 per-AC verify evidence.** This revision changes the evidence the per-AC investigators collect. It does not change how the gate clears: **(b)**, **(d)**, the mapper **(i)**, the firing rule, the two cards and BC7 reuse are unchanged. **M14(a)** — a `Verify:` command is a locator, like `<path>:<line>`; the council's own per-AC investigator runs it through its own tool call during the pass; that output is Phase 2 evidence, not a "test-runner log", because no pipeline step wrote it for the council; autopilot never runs it for the council and never passes its output; a pass does not clear an AC by itself. **M14(g)** — Verify line rule (two-space continuation `Verify: bash <path> [<arg> ...]`; `<path>` repo-relative, no `..`, present at `HEAD`, a suite name that `tools/run-all-tests.sh` discovers, never `tools/run-all-tests.sh`; characters `A-Z a-z 0-9 . _ / = : @ % + , -` only); new fail-closed case 10 (a malformed Verify line, two on one AC, or one on a `[process]` AC) and case 11 (a Verify line with uncommitted changes to tracked files, because the split reads `HEAD` and a verify run reads the worktree); "checkboxes are not evidence" note; Writers add a Verify line per technical AC, and Step 10b lists ACs with none and Verify files that do not call `hermetic_init` (a report, not a block). **M14(j)** — an M14 claim with a command gets 8 investigator calls, else 5; every other caller keeps 5. **M14(k)** — verify evidence tests. **N17** — an investigator's own verify run is evidence, not a runner log. The headline ACs follow reading (A) of the WP 1-15 kickoff: prompt and fixture evidence only; the live proof is the WP 1-05 ship gate. New `### wp-1-15-m14-verify-evidence` AC subsection with a Verify line on every technical AC. SPEC-013 Phases 1, 2, 2.5, 5 and 6 carry the engine side. Status stays DRAFT. |
| 2026-09-26 | WP 1-14 step 10b, TL raise (M14(j)): `M14_AC_BUDGET` raised from `10` to `16` in `skills/council/engine.sh`. Reason: this WP's own AC subsection (`### wp-1-14-m14-ship-gate-evidence`) holds 16 technical ACs, which would fail the split closed under the old budget. The hard ceiling `M14_AC_BUDGET_CEILING=20` is unchanged. |
| 2026-09-26 | WP 1-14 (`m14-investigator-budget-scales-with-scope`): **M14 per-AC evidence.** **M14(a)** — the claim envelope names one AC source (`ac-source=<path>`); the council audits each technical AC as its own claim in the same invocation; per-AC claims carry the AC id and a `<path>:<line>` locator, never AC text; a QA evidence file, runner log or AC→evidence map MUST NOT reach the council (design (c) rejected; design (b), a budget that scales, rejected because one verdict dilutes a failed AC and raises cost for every caller). **M14(b)** rewritten — per-AC aggregation: agree only if every AC is `VERIFIED`/`PARTIALLY_VERIFIED` at 80 or higher; card #2 confidence = the lowest AC confidence; any `UNVERIFIED`/`CONTRADICTED`/`FABRICATED`, missing, struck, or over-budget AC → BC7, confidence 0, rationale names the AC ids; never `max_verdict_confidence`. **M14(g)** — AC source format: committed spec at `HEAD`, `## Acceptance criteria` → `### <ticket_id>` → bullets `- **A.** <text>` with an optional `[process]` tag; split trigger (claim scope + `Ship-gate audit for <ticket_id>.` + an `ac-source=` token; two or more tokens fail closed; zero tokens do not split and the mapper halts); nine fail-closed cases; kickoff / Step 6 / Step 10b write and check the ACs. The `### <ticket_id>` subsection is a Tech Lead refinement of the advisor format: it stops a later ticket from shipping on the ACs of an earlier ticket. **M14(h)** — `[process]` ACs cleared by the card #1 stamp; guard 1 (execution vocabulary), guard 2 (`process_acs:` plan line, confirmed at plan-approve), guard 3 (zero technical ACs, or a stamp-shape miss → BC7). **M14(i)** — verdict mapper `skills/autopilot/ship-gate-verdict.sh`: pure `jq` over the finalize-meta sidecar and card #1, after the verdict; not a render helper. **M14(j)** — one M14-only budget `M14_AC_BUDGET=10` in `engine.sh`, hard ceiling 20, no env/flag/per-WP override. **M14(k)** — fixture, static-guardrail and non-M14-unchanged tests. **M4** `plan-approve` item 1 gains the guard 2 check (`process_acs:` equals the spec tags, else BC1). **N15–N17** added. Firing rule, two cards, BC7 reuse (no ninth BC), (c), (d), (e), (f), BC6 and wall-clock caps unchanged. New `## Acceptance criteria` section holds this WP's ACs. Adversarial review (AC R): `.claude/council/2026-09-26-plan-2026-09-26-wp-1-14-m14-ship-gate-evidence-plan.md` (full tier; flavors paranoid-ic, jaded-senior, security). 10 claims: 3 VERIFIED, 7 PARTIALLY_VERIFIED, 0 UNVERIFIED/CONTRADICTED/FABRICATED. Rejected: the prosecutor asked for CONTRADICTED on not-yet-implemented code (C1, C4, C5, C7, C8, C9); the judge refused, because absent code cannot contradict a plan. Accepted as residual: C6 (VERIFIED at 78) — guard 1 is lexical, so a diff-content AC mis-tagged `[process]` escapes audit; mitigations are guard 1's execution vocabulary, guard 2 (TL confirms `process_acs:` at plan-approve), and guard 3 fail-closed. Struck sub-claims move to implementation: T2 makes the report and sidecar reservation two sequential exclusive creates with a rollback, not one atomic step; T5 checks the stamp-shape field list against real cards; the budget-greater-than-ceiling branch stays unreachable while the constants are fixed. Status stays DRAFT. |
| 2026-08-27 | CDT-224: **AC9 / M9b** — `/orchestrate` BC6 auto-tune from plan-approve signals (task count, counted LOC via M15, parallel waves). Tiers L-first then S else M; L ceiling 40 / 4500; S 10 / 1200; M 25 / 2700. Precedence per cap: env (non-empty) > auto-tune > static M. No cap flags; `parse-flags.sh` stays six-key. Freeze once before BC walk; ledger SoT on resume; no `AUTOPILOT_*_CAP` export. Kickoff / epic Mode A stay static. M10.6 uses L ceiling 4500 at unfrozen scope-confirm unless wall-clock env set; frozen cap after plan-approve. M13 nested `budget.{tier,source,signals}` additive nullable; 18 top-level keys; schema_version 1. Helper argv: argc 2 unchanged, argc 4 verbatim freeze, `derive` subcommand. Writer `AUTOPILOT_BUDGET_META`. N12–N14. Status stays DRAFT. |
| 2026-08-27 | CDT-223: **AC8 / M15 / M16** — counted-LOC exclusion (`.gitattributes linguist-generated` ∪ built-in lockfile/`*.snap`/vendored-prefix list ∪ SPEC-009 specs/tests exemption) for BC4 per-PR, BC4 per-file, and M10.1; same definition for interactive SPEC-009 change-discipline. DRI `--max-loc=<n\|unbound>` flag-only (six-key `parse-flags.sh`, no env, junk→64, last-wins, not resume-seeded, not auto-propagated on reroute-epic). `n` raises/tightens per-PR hard cap + M10.1 only (per-file 1000 unchanged); `unbound` disables BC4 (per-PR and per-file) and M10.1; M10.2–6 / BC6 / BC3 / BC7 unchanged. M13 additive nullable `max_loc` (`schema_version` stays 1; `decided_by` stays `auto` on self-answer). Helper `skills/autopilot/loc-exclude.sh`. Scaffold seeds `.gitattributes`. Status stays DRAFT. |
| 2026-08-16 | CDT-196: M11a(a) BC5 carry-forward MUST pass `--worktree --release <bump>` when bump is patch/minor/major; `/epic` persists `release_bump` so children cannot land on master. |
| 2026-08-10 | CDT-195: `--autopilot=master` land-no-release ship-intent sentinel. **M2** — ship-intent token set = `/release` tokens `patch\|minor\|major` **plus** non-release sentinel `master` (flag-only; env never carries bump/sentinel; `master` MUST NOT be passed to `/release`; land target = worktree baseline / `origin/HEAD`, not hard-coded ref `master`); resume: bare `--resume-ship` re-reads recorded mode, explicit `=master\|patch\|minor\|major` overrides. **M4 ship-choice** — non-null token (incl. `master`) ⇒ `decision=merge`; end-state branches on token class (release vs land-no-release). **M13** — `bump` enum gains `master` (ship-choice only; not a release version). **N3/N3a** — intentional baseline land under `=master` authorized when mechanical BC3-clear passes (same safety as release land); force-push still BC3-never-waived; third terminal land-no-release: N3a → squash → interactive-shape `git commit` → non-force `git push` baseline → no `/release` (no version files/tag/CHANGELOG) → ship-history → Done. Pure superset of bare and `=patch\|minor\|major`. Skill/wiring deferred; status stays DRAFT. |
| 2026-08-09 | CDT-185: M14(a) process stamps + narrow claim (Option 3). Before `/council`, autopilot MUST pre-flight **process stamps** = clean ship-choice **card #1** via `read-cards.sh` (stamp shape: `gate=ship-choice`, `decision∈{pr,merge}`, `blocking_condition=null`, `decided_by=auto`, `council_tier`/`grading_reason` null, first ship-choice card for `run_id`). QA/Step-10b implied by self-answer; **no** TL APPROVE stamp. Stamp fail → refuse agree path, no `/council`, card #2 BC7 halt `confidence=0` (reuse BC7, not a 9th BC). Stamp pass → one-line claim is **technical-only** (merge-base diff vs ACs/spec); MUST NOT re-assert process outcomes in the claim body. Locators-only / no RAW_ARTIFACTS injection preserved. M14(b)/(c)/(d)/(e)/(f) mapping and degraded-run rule unchanged; technical disagree still BC7. Scope: M14 ship-gate only. Procedure home: `skills/autopilot/ship-gate-council.md` §3b (wiring child). Status stays DRAFT. |
| 2026-08-05 | CDT-126: council tiering at the autopilot ship gate. **M14(e)** — tier selection before the M14 pass: graded input is `git diff --numstat $(git merge-base <default> HEAD)..HEAD` with `<default>` from `git symbolic-ref refs/remotes/origin/HEAD`, reusing N3a's existing mechanism at the same step rather than inventing one; bands, critical-area signals, the fail-closed contract and the `skip`-unreachability rule are all cited from SPEC-013's Council tiering section, never restated (SPEC-002 D1 / M12 / N4) — (e) keeps only the M14-specific deltas: the graded diff, the fact that an unresolvable `origin/HEAD` grades to `full` here whereas N3a's own unresolvable `origin/HEAD` **halts the ship** under BC3 (same probe, different consequence — not to be conflated), and that autopilot has no DRI so `skip` can only arrive human-supplied; **M14(a)** amended to carve out `--council-tier=<tier>` as the sole permitted flag on the otherwise-unbound `/council` invocation, resolving its contradiction with (e)'s requirement to pass it; firing rule (`ship-choice` only, clean `pr`/`merge` only, exactly once, exactly two cards) unchanged. Includes a correction note for the wiring child: `skills/autopilot/ship-gate-council.md` §3's "the staged diff" is wrong — nothing is staged at M14 firing time (the `git merge --squash` happens after the gate), so M14 has no pre-existing diff of its own, and its "no other flag" sentence is superseded by the M14(a) carve-out — both to be corrected in the same pass. **M14(f)** — tier-aware BC7: the halt card carries `council_tier` and the rationale names it; the full-council re-offer is made only from a `light` halt, and is an escalation affordance autopilot MUST NOT self-answer. No ninth blocking condition, no new halt path; (b)/(c)/(d) unchanged. **M13** — decision card gains nullable `council_tier` + `grading_reason`, non-null only on the M14 council card; `schema_version` stays `1` (additive + nullable, discriminator envelope unchanged); `append-card.sh` cross-field invariants to be extended by the wiring child. Status stays DRAFT. |
| 2026-08-04 | Initial contract (CDT-111-C1) — mode activation (M1–M2), per-gate checklists + per-command checkpoint mapping (M3–M5), eight blocking conditions (M6–M8), run-budget defaults (M9), complexity-overflow reroute (M10–M11), contract home (M12), decision-card schema (M13), MUST NOTs N1–N8. Amended within the same DRAFT cycle by later CDT-111 children: C2 (card writer/reader paths), C5 (AC7 / M14 council ship gate), C6 (M11a reroute safety + state carry-forward), C7 (OQ1 notify transport), C8 (M9a resume wall-clock basis), C9 (N3a deterministic BC3 push-target check). *(This table itself was added 2026-08-05 by CDT-126 — the section was missing; the rows above reconstruct the DRAFT cycle that predates it.)* |
