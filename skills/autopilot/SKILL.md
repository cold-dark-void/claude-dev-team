---
name: autopilot
description: |
    Shared autopilot policy — the one operational copy of SPEC-033. Auto-answers
    orchestration gates (scope-confirm / plan-approve / ship-choice) so a workflow
    runs unattended, and halts + escalates to a human on 7 of 8 blocking conditions
    (BC5 instead reroutes to /epic decompose and continues autonomously). Never
    removes a gate; only changes who answers it and records why (append-only
    decision cards). Cited by /orchestrate, /kickoff, /epic when wired (later
    CDT-111 children); those MUST cite, never restate.
---

# Autopilot

> **Contract home (SPEC-002 D1 cite-not-copy).** This SKILL is the **one operational
> copy** of the shared autopilot policy. `specs/core/SPEC-033-autopilot-policy.md`
> *defines* the contract; this file *carries* it; `/orchestrate`, `/kickoff`, and
> `/epic` (when wired by later CDT-111 children) MUST **cite** SPEC-033 / this SKILL
> and MUST NOT restate or fork the checklists, conditions, budget, or schema.

Autopilot is the opt-in mode in which a workflow's human-interactive **gates** — the
points that print a summary and *wait for user input* — are answered by the agent
instead of a human, so the run proceeds unattended. It is a **pure superset**: when
autopilot is inactive (default), every gate stays fully human-interactive with **no
behavior change** (SPEC-033 M1).

## The one framing (SPEC-033)

> Autopilot replaces every "**Wait for user**" with "**auto-answer the gate, unless a
> blocking condition fires**." It **never removes a gate**; it changes **who answers
> it and records why**.

If a blocking condition fires, autopilot **halts and escalates to the human** rather
than guessing (SPEC-033 M6/M7). It never proceeds past a hard block on its own.

## Mode activation (SPEC-033 M1–M2)

- **Opt-in, default off.** Inactive unless requested via the `--autopilot` argument
  or `AUTOPILOT=1` in the environment. Inactive ⇒ gates fully human-interactive.
- **Ship-intent tokens: borrowed release bumps + one land-no-release sentinel (M2 /
  CDT-195).** `--autopilot=<token>` MAY carry either:
  1. a `/release` bump token (`patch` | `minor` | `major`) — **release** ship intent; or
  2. the non-release ship-intent sentinel `master` — **land-no-release** (squash-land onto
     the worktree baseline with **no** `/release`).
  For (1), autopilot treats the token as a *reference* to the `/release` vocabulary and
  MUST NOT redefine those bump semantics. For (2), `master` is a **flag-only ship-intent
  sentinel**, not a `/release` version: the decision-card records `bump:"master"`; the CLI
  spelling remains `=master`; and autopilot MUST NOT pass `master` to `/release`. Land git
  target under `master` is the worktree **baseline** (typically `origin/HEAD`), **not** a
  hard-coded ref literally named `master`. Env (`AUTOPILOT=1`) enables autopilot only and
  MUST NEVER carry a bump or sentinel — tokens are **flag-only**. Absent a token, autopilot
  MUST NOT auto-release and MUST NOT auto land-no-release; the default ship action is
  bounded by the `ship-choice` checklist below (SPEC-033 M2 — cite, do not fork).

---

## Per-gate answering checklists (SPEC-033 M3–M4) — `/orchestrate` only

The `scope-confirm` / `plan-approve` / `ship-choice` triad describes **`/orchestrate`'s
structure specifically** — the one workflow this triad fully fits. `/kickoff` and
`/epic` are handled per command below (M5); do not force a false 3×3 mapping.

At each gate, evaluate the checklist **in order**; only if **no** blocking condition
(M6) fires, emit the stated default answer.

### `scope-confirm` — default answer: `proceed`
*(orchestrate Step 2, "first escalation gate"; the flow otherwise waits on "Proceed with this scope?")*

*(Evaluate in the canonical BC1→BC8 ordinal order, first-match-wins — dropping BCs
that don't apply to this gate — so it agrees with the "8 blocking conditions" section.)*

1. Is the issue text sufficient to fix scope without guessing? → else **BC1** (ambiguity).
2. Does the scope imply any destructive / irreversible operation? → **BC3**.
3. Does assessed complexity fit one ticket, or is it an overflow? → **BC5** reroute (AC4).
4. Is the run within budget? → **BC6**.
5. Am I confident in `proceed`? → else **BC7**.

### `plan-approve` — default answer: `approve`
*(orchestrate Step 6, "second escalation gate"; waits on "Approve this plan?")*

*(Evaluate in the canonical BC1→BC8 ordinal order, first-match-wins — dropping BCs
that don't apply to this gate — so it agrees with the "8 blocking conditions" section.)*

1. Does every plan task carry concrete file paths **and** a verification step? → else **BC1**.
2. Does any task perform a destructive / irreversible operation? → **BC3**.
3. Is the projected change within the LOC soft-cap and per-file size cap? → **BC4**.
4. Does the plan's task graph exceed the single-ticket bound? → **BC5** reroute (AC4).
5. Budget (**BC6**) and confidence (**BC7**).

### `ship-choice` — default answer: `pr`
*(orchestrate Step 11; waits on "Options: 1 Create PR / 2 Show diff / 3 Review manually")*

`pr` (Create PR) is the reviewable, reversible option. A squash-merge (`merge`) MUST
NOT be auto-selected unless `--autopilot=<token>` was supplied with a **non-null**
ship-intent token (`patch` | `minor` | `major` | `master`) — explicit ship intent
(SPEC-033 M4). **Non-null token ⇒ `decision=merge`** (including `master`). Release vs
land-no-release is an **end-state branch on token class**, not a different ship-choice
`decision` — three terminals after a clean ship-choice:

| Terminal | Trigger | End path |
|---|---|---|
| **pr** | `autopilot_bump = null` → `decision=pr` | Create PR; stop (no land) |
| **land-no-release** | `decision=merge` + `bump=master` | N3a → squash → interactive-shape `git commit` on baseline → non-force `git push` baseline → **no** `/release` (no version/tag/CHANGELOG) → ship-history → Done |
| **release** | `decision=merge` + `bump ∈ {patch, minor, major}` | N3a → squash-stage → `/release <bump>` → ship-history → Done |

Self-answer / ship-choice records only `pr` or `merge` (+ card `bump`); dual land path
lives in `skills/autopilot/end-state.md` (SPEC-033 N3a). The `merge` decision-card value
maps to `/orchestrate`'s separate **"If squash merge requested"** branch (Step 11's later
squash path), **not** a numbered option in the Step-11 menu (which offers only Create PR /
Show diff / Review manually).

*(Evaluate in the canonical BC1→BC8 ordinal order, first-match-wins — dropping BCs
that don't apply to this gate — so it agrees with the "8 blocking conditions" section.)*

1. Did Step-10b spec-alignment pass (else **BC1** — a code/AC mismatch is a now-provably-
   unresolved scope/plan question) **and** did QA reach PASS (**BC2** not already tripped)? → else halt.
2. Is the ship action more irreversible than a PR (direct merge to a protected branch,
   force-push)? → **BC3**. **BC3 is evaluated UNCONDITIONALLY, even when `--autopilot=<token>`
   was supplied** — the token only satisfies "explicit ship intent" for `decision=merge`;
   it **never** exempts BC3. Force-push still BC3. Intentional baseline land under
   `=master` or a release token is authorized only when the N3a mechanical check passes
   (same safety as release land — not a false halt merely because default is protected).
3. Budget (**BC6**) and confidence (**BC7**).

See `skills/autopilot/ship-gate-council.md` for the mandatory council pass that gates every
clean ship-choice answer (SPEC-033 M14).

See `skills/autopilot/end-state.md` for the dual land end-state sequences (BC3
deterministic push-target check + squash-stage, then **release** via `/release` **or**
**land-no-release** without `/release`), gated behind `--autopilot=<token>` (N3/N3a).

---

## The three-gate scheme fits `/orchestrate` only — `/kickoff` & `/epic` per command (SPEC-033 M5)

`/kickoff` and `/epic` do **not** map one-to-one onto the three gate names. The policy
records, per command, which real checkpoints autopilot answers, which are
**content-bearing** (halt — not self-answerable), and which have **no analog**. Verified
against `skills/kickoff/SKILL.md` and `skills/epic/SKILL.md`:

| Canonical gate | `/orchestrate` | `/kickoff` | `/epic` |
|---|---|---|---|
| `scope-confirm` | Step 2 (first escalation gate) — self-answerable | **No approval-gate analog.** Step 3 "resolve open questions" is the nearest pause but is **content-bearing** (needs answers, not yes/no) → blocking condition (**BC1**), never self-answer | A.5 approval gate, **scope half** (problem + ACs) — evaluated; **and** B.3 per-child handoff confirm, which **is** a repeated scope-confirm (per child, before any work) |
| `plan-approve` | Step 6 (second escalation gate) — self-answerable | **Does not exist.** Step 6 (TL plan) flows straight into Step 7 (TaskCreate); no "approve this plan?" prompt. Adding one is a **new gate** — a design decision **out of scope** here | A.5 approval gate, **plan half** (estimate / agent / depends_on / waves) — evaluated jointly with the scope half; **single atomic verdict** |
| `ship-choice` | Step 11 (ship options) — self-answerable, defaults to PR | **N/A** — `/kickoff` ends at the task graph and never ships | **N/A** — `/epic` never ships (M11: no code, no worktrees, no IC spawns); each child's real ship-choice lives **inside its own delegated `/orchestrate` Step 11** |

Notes the policy records:

- **(a) `/orchestrate` is the only workflow the three-gate scheme fully fits.** State
  this outright; do not paper over the gaps with an invented mapping.
- **(b) `/kickoff` has no self-answerable approval gate.** Its Step 3 open-questions
  pause is content-bearing — autopilot cannot answer it without **fabricating
  requirements**, so it is a blocking condition (**BC1** / M8), not a gate autopilot
  proceeds through. Its Step 4b **"GATE 1 (API verification)"** is its own blocking
  condition (**BC8** — M6.8). `/kickoff` has neither a `plan-approve` nor a
  `ship-choice` gate; autopilot MUST NOT synthesize either.
- **(c) `/epic` A.5's verdict is atomic.** The scope half and plan half are separable
  **for evaluation** (autopilot runs both checklists), but the source verdict is atomic:
  **decline = zero writes; approve = both scope and plan persisted.** There is no
  source-legal "approve scope, reject plan" outcome. Under autopilot the single answer
  is `approve` iff **both** halves pass every check; any half's blocking condition halts
  the whole gate. Autopilot also **forfeits** A.5's interactive "user may edit / merge /
  remove children" affordance — it can only approve-as-presented or halt; it MUST NOT
  silently drop or rewrite a proposed child.
- **(d) `/epic` A.6 execution-mode default = `orchestrate`.** A.6 persists a once-chosen
  execution mode (`kickoff` | `orchestrate`) to `state.json`. Under autopilot the default
  MUST be **`orchestrate`**, because `kickoff` mode dead-ends every child at B.5's
  human-only completion attestation (note f) — choosing it would guarantee an immediate
  halt at each child, defeating unattended execution.
- **(e) `/epic` B.3 is a repeated scope-confirm, not a ship-choice.** B.2 takes `head -1`
  of the ready set, so B.3 fires **per child**, and prints the same content shape as
  orchestrate Step 2 (title / problem / ACs / estimate / agent / deps) **before any work
  starts**; answering `y` starts planning and ships nothing. Autopilot answers it with the
  `scope-confirm` checklist. Mapping it to `ship-choice` would make autopilot block at
  **every** child, defeating the point.
- **(f) `/epic` B.5 kickoff-mode completion is a truth attestation — never self-answered.**
  In `kickoff` mode a child is marked `completed` only when the user confirms real
  completion ("never auto on plan file alone"). This is an **attestation of fact**, not an
  approval; autopilot MUST NOT self-answer it under any circumstances (N8). With the A.6
  `orchestrate` default this rarely arises, but the prohibition is absolute.
- **(g) Out of scope:** `/epic` Mode E `--redecompose` confirm is an explicitly
  user-invoked flag; autopilot does not spontaneously redecompose, so it is out of scope
  for this contract.

---

## Blocking conditions — 8, in evaluation order (SPEC-033 M6)

At every gate, **before** emitting the default answer, evaluate these **in this order**
and act on the **first** that matches. Seven are **hard-blocking** (halt + escalate);
**BC5** is the **only non-blocking** condition (self-reroute). This is the complete set —
autopilot MUST NOT invent additional auto-halt conditions.

1. **BC1 — Genuine ambiguity.** A scope/plan question still unresolved *after* an honest
   resolution attempt against the repo, the specs, and project memory. Ambiguity that
   memory or specs *do* answer is **not** a blocker. → **halt**.
2. **BC2 — QA failure past 3 bounces.** A **new autopilot-specific** threshold: when
   SPEC-026's `qa_bounces` for any task reaches **3**, autopilot halts. This counter is
   **separate from and additive to** `/orchestrate`'s pre-existing interactive triggers
   (Step 8 "stuck after 2 genuine attempts", Step 9 "3+ review-round deadloop"); it does
   **not** replace them, and those continue to fire independently (N7). → **halt**.
3. **BC3 — Destructive / irreversible operation.** The gated action would delete/overwrite
   user data, force-push, merge to a protected branch, drop a table, `rm -rf` outside the
   worktree, rewrite shared history, or otherwise be non-trivially reversible. → **halt**.
4. **BC4 — LOC soft-cap / file-size breach.** The projected or actual change exceeds the
   SPEC-009 change-discipline bounds (~1000 LOC soft / 2000 LOC hard per PR; no single
   file > 1000 lines). → **halt**.
5. **BC5 — Complexity overflow.** The work meets the AC4 overflow criteria (below). This
   is the **only non-blocking** condition: autopilot MUST NOT halt for a human; it MUST
   **reroute to `/epic`** decompose (recording a `reroute-epic` decision card) and continue
   autonomously. → **reroute**.
6. **BC6 — Run-budget breach.** The run exceeds a budget cap (iteration or wall-clock).
   → **halt**.
7. **BC7 — Self-uncertainty.** In the gate-answering step itself, autopilot's confidence in
   the default answer is below the threshold (`confidence` < **80**, mirroring the council
   default). An honest "I'm not sure" MUST halt rather than proceed. → **halt**.
8. **BC8 — Unverified external dependency.** The `/kickoff` Step 4b **"GATE 1 (API
   verification)"** analog: an external API parameter, SDK/library flag, model capability,
   endpoint behavior, or config flag that a **confirmed AC depends on** verifies `IGNORED`,
   `DECORATIVE`, or `UNKNOWN`. Source forbids auto-proceeding: *"Do NOT silently design
   around an unproven capability."* This is **distinct from BC1**, not a variant: a
   `DECORATIVE`/`IGNORED` verdict is a **resolved-negative** (the capability was proven
   *not* to work), not unresolved ambiguity — so BC1, whose own text says specs/memory-
   answered ambiguity "is not a blocker," would mis-classify a resolved-negative as
   "resolved → proceed," the exact wrong outcome. The required human decision — drop/rework
   the AC, or proceed explicitly-marked-unverified — is a **product decision** autopilot
   MUST NOT self-answer. Fires only in `/kickoff`'s pre-spec phase (a phase-scoped condition,
   like BC2 which fires only in the IC/QA loop). → **halt**.

### Halt semantics (SPEC-033 M7–M8)

- On any hard-blocking condition, autopilot MUST: **(a)** stop before taking the gated
  action, **(b)** write a `halt` decision card (below) naming the ordinal blocking
  condition, **(c)** surface the halt to the human via the workflow's escalation path.
  Autopilot MUST NOT proceed past a hard block on its own. Halts MUST be **non-destructive**:
  no partial ship, no merge, no irreversible side effect at or after a halt.
- **Interactive-trigger mapping (M8).** Any point where the underlying workflow would
  interactively "wait for user" for a reason **not** in M6 (Step 8 stuck-after-2, Step 9
  deadloop, scope-creep) MUST also resolve via the closest M6 condition (it cannot wait
  on an absent human) — **halt-and-escalate for the hard-blocking mappings, or reroute
  for the BC5 branch** — recording that ordinal in the card: `stuck` → BC1 (halt);
  `deadloop` → BC1 (halt); scope-creep → **BC5 reroute** if it is an overflow, else BC1
  (halt). `/kickoff`'s own pauses map likewise:
  **Step 3 open-questions** and the **>4-open-questions pause** → BC1 (content-bearing);
  a **breaking-schema-change pause** → BC3 (irreversible-change class). (`/kickoff` Step 4b
  "GATE 1" is **not** an M8 mapping — it is its own first-class **BC8**.)

---

## Run-budget defaults (SPEC-033 M9)

A per-run budget with two caps, both env-overridable:

| Cap | Default | Env override | Counts |
|---|---|---|---|
| `iteration_cap` | **25 stints** | `AUTOPILOT_ITERATION_CAP` | one **stint** per agent spawn inside the run: each IC task attempt, each Tech-Lead review round, each QA run, and the PM/TL kickoff spawns |
| `wall_clock_cap` | **45 minutes** (2700 s) | `AUTOPILOT_WALLCLOCK_CAP` | elapsed time from autopilot run start |

Rationale (normative baseline for later tuning): a healthy L-sized ticket runs ~10–15
stints and 10–25 min under parallel agents; the defaults give ~2× headroom before
declaring a runaway. **Scope of a run:** `/orchestrate` = one ticket. `/epic` = the
per-child budget applies to each child's own `/orchestrate` run; the epic-level walker
adds its own decompose iteration budget and MUST NOT let a single child's breach silently
consume the whole epic (each child's BC6 halt is child-scoped). A single shared default
suffices across workflows — `/kickoff` and `/epic` Mode A are short (~2–6 stints) and sit
far under the cap; and because they have *fewer* self-answerable gates (M5), autopilot
tends to **halt earlier** there, lowering budget pressure. The 25-stint / 45-min defaults
stand unchanged for all three workflows. Breaching either cap trips **BC6**.

---

## Complexity-overflow → `/epic` reroute criteria (SPEC-033 M10–M11)

Complexity **overflow** (the underlying definition BC5 triggers on) is met when **any** of
the following holds at `scope-confirm` or `plan-approve`:

1. Projected total change exceeds the SPEC-009 **hard** cap (> 2000 LOC) across the ticket; or
2. The work naturally decomposes into **3 or more independently shippable workstreams**
   (distinct PR-able units with no shared change surface); or
3. The plan's task graph would exceed **~8 tasks across multiple parallel waves** (mirrors
   `/epic`'s ">8 children → probably two epics" soft-warn); or
4. The work requires **more than one distinct spec / contract home** (a signal of multiple
   independent concerns); or
5. It touches **3 or more independent subsystems** with no common change surface; or
6. The estimated single-run wall-clock would exceed the `wall_clock_cap` even with full
   parallelism.

**Reroute is non-blocking and reversible (M11).** On overflow, autopilot MUST record a
`reroute-epic` decision card and hand the ticket to `/epic` decompose **autonomously** (no
human halt), because at scope/plan time no code has shipped — the reroute is fully
reversible. **BC5** *references* this overflow condition as its trigger; M10 *defines* what
overflow is. The `/epic` decompose it hands to then runs under **this same** autopilot
contract (its A.5 gate auto-answered per M4/M5).

---

## Decision-card schema (SPEC-033 M13)

Every gate answer, halt, and reroute is recordable as a **decision card**: one append-only
JSONL object per event at:

```
$MROOT/.claude/autopilot/<TICKET-ID>.jsonl
```

Mirroring the SPEC-001 M7 invariant for its own NDJSON ledger, this file is **append-only,
local-only state**: NOT committed to git (`.claude/autopilot/` is git-ignored) and NEVER stored
in `memory.db`.

The schema is **frozen** here (this SKILL fixes the shape; the *writer/reader* ship as
`skills/autopilot/append-card.sh` / `skills/autopilot/read-cards.sh` in **CDT-111-C2**):

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
  "rationale": "<one-line why>",
  "budget": { "iteration": 0, "iteration_cap": 25, "wall_clock_s": 0, "wall_clock_cap_s": 2700 },
  "actor": "orchestrator"
}
```

**Field contract:**

- `type` (const `"autopilot_decision"`) **+** `schema_version` are the **stable
  discriminator envelope** a future SPEC-031-family hook keys on. Both MUST be present on
  every card. This is the sole AC6 forward-compat obligation — no SPEC-031 file is touched.
- `gate` records the canonical gate name. Off-triad halt points (e.g. `/kickoff` Step 3/4b,
  `/orchestrate` Step 8/9 via M8, `/epic` A.5) have no gate of their own, so they record the
  **closest** canonical gate name per the M5 mapping table / M8 mapping — e.g. a `/kickoff`
  Step-3 BC1 halt records `gate:"scope-confirm"` (M5 maps kickoff's nearest checkpoint to
  scope-confirm). The enum stays the frozen 3-value set; no fourth value is invented.
- `decision` is the gate's **actual answer** and is deliberately a **distinct field** from
  any council `verdict`. Reusing council-judge's verdict taxonomy
  (`VERIFIED | PARTIALLY_VERIFIED | UNVERIFIED | CONTRADICTED | FABRICATED`) for a gate
  answer would be a type error: a gate answers `proceed` / `approve` / `bump=patch`,
  **not** "verified". The card MAY carry
  council-style fields (`confidence`, `rationale`) but MUST keep `decision` separate so the
  answer is never conflated with a verification verdict (N6).
- `decided_by` records **who answered this gate**: `auto` when autopilot self-answered per its
  checklist with no blocking condition firing, or `user` when the card records a human's
  resolution after a halt (the human answered the question that triggered a
  BC1/BC3/BC4/BC6/BC7/BC8 halt, and this card captures their answer). It is orthogonal to
  `decision` (the answer itself) and to `actor` (which component *wrote* the card) — all three
  coexist. This matches the SPEC-001 M7 precedent, whose `directive-history.jsonl` already uses
  `decided_by ∈ user | auto` for exactly this user-vs-auto provenance.
- `bump` is non-null **only** on a `ship-choice` card. Allowed non-null values are the
  `/release` tokens (`patch` | `minor` | `major`) **or** the land-no-release sentinel
  `master` (M2 / CDT-195). `master` is **not** a release version and MUST NOT be passed to
  `/release`. It MUST NOT introduce a bump value outside that vocabulary.
- `confidence` (0–100) backs **BC7**; a card with `decision:"halt"` and
  `blocking_condition:7` MUST carry `confidence` below the threshold. Threshold default 80
  mirrors the council convention.
- `blocking_condition` is `null` for a clean answer, or the M6 ordinal (**1–8**) for a
  halt/reroute.
- `council_tier` (**CDT-126**) records which council pipeline the M14 ship-gate pass ran —
  `skip | light | full`, the vocabulary SPEC-013's **Council tiering** section owns (this
  SKILL MUST NOT define a second one, N4). `grading_reason` records *why* that tier was
  selected, in one line, under the same redaction obligation as `rationale`. Both are
  non-null **only** on the M14 council card (the second `ship-choice` card, M14(c)) and
  `null` on every other card, card #1 included. Both are **additive and nullable**, so
  `schema_version` stays `1` and pre-CDT-126 cards remain valid (absent key ≡ `null`).
  `skills/autopilot/ship-gate-council.md` §3a/§6 is the procedure that populates them.
- `rationale` is a one-line summary and MUST NOT contain secrets, credentials, tokens, keys,
  or PII. Any evidence quoted from the repo, specs, or memory (e.g. the S2 resolution attempt)
  MUST be **redacted or summarized**, never copied verbatim into the card.
- `budget` snapshots the run-budget counters at decision time.
- `actor` names the writer (e.g. `orchestrator`).

---

## Writer / Reader (CDT-111-C2)

Two subprocess CLIs implement the schema above. They **carry** the M13 contract; they do
not redefine it — the schema and field semantics live only in the block above.

```
# Append ONE card (validates enums + M13 cross-field invariants; hard-fails on any
# bad arg, jq-absent, or write failure with exit 64). rationale is the free-text tail.
skills/autopilot/append-card.sh \
  <workflow> <ticket_id> <gate> <decision> <decided_by> \
  <bump|null> <confidence> <blocking_condition|null> \
  <run_id> <iteration> <wall_clock_s> <actor> <rationale> \
  [<council_tier|null> <grading_reason|null>]   # CDT-126; argc 13 or 15, never 14

# Dump every card for a ticket as a JSON array (for downstream evidence readers).
# No cards yet -> "[]" + exit 0; bad args / jq-absent -> exit 64.
skills/autopilot/read-cards.sh <ticket_id>
```

Contract notes (writer):
- `run_id` is **caller-supplied and required** — never writer-derived (S3 is the caller's job).
- `schema_version` (const `1`), `type` (const `autopilot_decision`), and `ts`
  (`date -u +%Y-%m-%dT%H:%M:%SZ`) are writer-derived and MUST NOT be passed in.
- `iteration_cap` / `wall_clock_cap_s` are resolved from `AUTOPILOT_ITERATION_CAP` /
  `AUTOPILOT_WALLCLOCK_CAP` (defaults 25 / 2700) — the single source for the M9 defaults.
- Enforced M13 invariants: `bump` non-null **only** when `gate=ship-choice`; `confidence` < 80
  **required** when `blocking_condition=7`; `council_tier`/`grading_reason` non-null **only**
  when `gate=ship-choice` (CDT-126 — deliberately weaker than M13's prose rule, which scopes
  them to the M14 card alone; see `ship-gate-council.md` §6 for why the writer cannot tell
  the two ship-choice cards apart). `rationale` and `grading_reason` reject newlines/control
  chars (semantic secret-scrubbing remains the caller's obligation, M13).
- Reader-side (CDT-126): `read-cards.sh` backfills absent `council_tier`/`grading_reason` as
  explicit `null`s in their frozen position (M13 absent ≡ null) and re-checks the same
  ship-choice invariant, exiting 64 on a ledger that violates it.
- Path `$MROOT/.claude/autopilot/<ticket_id>.jsonl`; sequential per-ticket-file appends (no
  flock — a single JSON line is < PIPE_BUF, so concurrent same-file appends stay whole).
