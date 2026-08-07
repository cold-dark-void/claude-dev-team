# SPEC-013: Adversarial Council Tribunal

**Status**: ACTIVE
**Category**: core
**Created**: 2026-04-09
**Covers**: `commands/council.md`, `skills/council/`, `agents/council-judge.md`, `skills/review-and-commit/SKILL.md` (diff-mode preset consumer), `commands/council --blind.md` (DEPRECATED stub — use `/council --blind`, CDT-46-C3)

---

## Overview

`/council` is an on-demand adversarial tribunal that reality-checks Claude's claims with material evidence. It addresses a recurring failure mode where the model produces confident narrative without touching reality — fabricating config failures, green-lighting deploys without correlating logs/metrics with the actual change, or asserting facts about code it never read.

The council is structured as a court: a **Prosecutor** (jaded senior) demands receipts, **Investigators** (paranoid ICs, blind and read-only) collect evidence with real tool calls, a **Devil's Advocate** (yolo IC) argues the claim is true to prevent prosecutor monoculture, a dynamic **Domain Specialist** is pulled per topic (devops/ds/etc.), and a dedicated `council-judge` agent (with an empty tool allowlist, optionally calibrated by `tech-lead`'s project cortex) serves as **Judge** — forbidden from running tools, issuing verdicts only from collected evidence.

Core architecture is an engine skill (`skills/council/`) with thin command wrappers. `/council` is the generic entry. `/review-and-commit` is refactored to call the same engine with a diff-mode preset, eliminating drift between the two adversarial systems. `/council --blind` absorbs the former `/council --blind` multi-team peer-review engine (N unconstrained + M lens reviewers → semantic clustering → confidence-tiered findings) as a first-class scope path — Tier-1 consensus clusters emit directly as council findings with no recursive `/council` reverse-validation call. Integration updates have been applied to SPEC-002, SPEC-009, SPEC-010, and SPEC-012.

Source brainstorm: `.claude/plans/2026-04-09-brainstorm-council.md`

---

## MUST

### Command Shape & Scope
- MUST support `/council "<claim text>"` — audit a single pasted claim
- MUST support `/council --session` — audit a slice of the current session transcript
- MUST support `/council --session --last N` — audit last N turns only
- MUST support `/council --plan <path>` — audit a plan file for unverified assumptions
- MUST support `/council --diff` — audit staged diff (equivalent to `/review-and-commit` invocation path)
- MUST support `/council --from-retro <anchor-id>` — audit a fabrication anchor surfaced by `/retro`
- MUST support `/council --blind` — multi-team blind peer review over a codebase/path (absorbs former `/council --blind`; see Blind-review path)
- MUST treat scope flags as mutually exclusive: exactly one of `"<claim text>"`, `--session`, `--diff`, `--plan`, `--from-retro`, or `--blind` MUST be supplied
- MUST refuse to run with no scope argument and no prior context (must fail loudly, not guess)
- MUST accept optional `/council --workflow` (or `COUNCIL_WORKFLOW=1`) as an execution-path selector orthogonal to tribunal scope flags (`"<claim>"|--session|--diff|--plan|--from-retro`) — does not replace scope exclusivity rules; default remains engine.sh; MUST NOT apply `--workflow` to the `--blind` path (blind uses its own execution path)
- MUST accept blind-path parity flags only with `--blind`: `--teams N` (unconstrained reviewer count; default 3), `--lenses L1,L2,...` (lens-differentiated reviewers; default `security,contributor,spec`), `--target <path>` (narrow file scope; default full project)
- MUST NOT accept, document, or implement a `--no-council` flag — the former blind-review reverse-validation self-call is removed (see Blind-review path)

### Engine Architecture
- MUST implement core logic as a skill at `skills/council/` (NOT duplicated inline in commands)
- MUST expose `commands/council.md` as a thin wrapper over the engine skill
- MUST refactor `skills/review-and-commit/SKILL.md` to call the same engine with a `preset: diff-mode` — MUST NOT maintain a parallel adversarial pipeline
- MUST define flavor presets as files in `skills/council/flavors/<name>.md` — each containing name, system-prompt delta, and tool allowlist
- For every council prompt template under `skills/council/prompts/`, that file's own `## Variables` table is the authoritative declaration of its `{{TEMPLATE_VARIABLE}}` contract; `commands/council.md` substitution blocks and `skills/council/SKILL.md`'s documented-variables table MUST name exactly the variables declared in each prompt's Variables table — no more (no dead substitutions), no fewer (no unsubstituted placeholders leaking into spawned subagents)
- MUST NOT register Prosecutor, Investigator, Devil's Advocate, or Domain Specialist as persistent team agents (no entries in `agents/`, no cortex, no `init-team` bootstrap) — `council-judge` is the sole exception, as it requires a persistent agent definition to enforce the empty-tool-allowlist invariant structurally

### Output Shapes
- MUST declare two first-class engine output shapes; every preset MUST declare which shape it emits:
  - `verdict[]` — schema: `{claim, verdict, confidence, evidence_blob}` where `verdict` is drawn from `VERIFIED | PARTIALLY_VERIFIED | UNVERIFIED | CONTRADICTED | FABRICATED`
  - `finding[]` — schema: `{file, line, severity, category, description, suggestion, confidence, tool_use_id}` where `severity` is drawn from `critical | warning | nitpick`
- MUST require every `finding` to carry a `tool_use_id` citing the Read/Grep that observed the cited `file:line` — evidence-or-silence applied to findings as to verdicts
- MUST treat confidence as a single 0–100 scale across both shapes; threshold semantics are declared per shape (diff-mode findings filter <80 at emission; verdicts carry confidence for downstream feedback-memory and TaskCompleted gates)

### Council tiering *(CDT-126)*

Tiering selects **which pipeline runs** for a council invocation — never **whether** a gate
fires. `requires_council` semantics (Integration Hooks / Task-ID Plumbing) are unchanged, and
tier selection MUST run immediately before the gated call, never at TaskCreate time. It applies
to the two *gated* call sites — the orchestrated task gate (`requires_council: true`, claim
scope) and SPEC-033 M14's autopilot ship gate. Of those two, only the ship gate grades
automatically; the task gate takes its tier from the explicit `--council-tier` override and
otherwise runs `full` (see Grading). Manual `/council` invocations at any scope are unaffected
and run `full` unless given that same override.

#### Tier vocabulary

- MUST define exactly three tiers: `council_tier ∈ skip | light | full`
- MUST NOT auto-select `skip` — grading MUST NOT be capable of returning it. `skip` is reachable
  only through an explicit per-run DRI flag
- **The `--council-tier` flag does NOT carry the same legal vocabulary on every surface.**
  `council_tier` has exactly three *logical* values, but `skip` is a **resolution the caller
  performs**, never an instruction the council engine executes — so it is not legal everywhere
  the flag is accepted. The three surfaces MUST be:

  | Surface | Legal values | `skip` behavior |
  |---|---|---|
  | `/orchestrate --council-tier=` | `skip \| light \| full` | short-circuits: **no `/council` invocation, no engine run, no report** |
  | `/council --council-tier=` | `light \| full` **only** | MUST hard-fail loudly at argument parse — `skip` is never legal here |
  | `engine.sh --tier` | `light \| full` (absent → `full`) | MUST refuse and exit non-zero — a `skip` run must never reach preflight |

  A caller wanting `skip` MUST short-circuit **before ever invoking `/council`**, and its own
  orchestrating procedure MUST record the audit trail directly (see Recording the tier). The
  `/council` hard-fail is the earlier, louder rejection point; the engine's refusal is the
  independent backstop if that is ever bypassed. Neither MUST silently coerce `skip` to another
  tier — a coerced `skip` would run a council the DRI explicitly declined
- MUST define `full` as today's pipeline with **no behavioral change**: same phases, same flavor
  sets, same prompts, same investigator and Judge behavior, same stdout summary. A `full` run
  after this section spawns exactly the roles, in exactly the order, that it spawned before it.
  The guarantee is over **behavior**, not over serialized artifacts: report frontmatter and the
  `index.json` row **do** gain the two additive `council_tier` / `grading_reason` keys on
  *every* run including `full`, per Recording the tier below. An ungraded `full` run records
  `council_tier: full` with a `grading_reason` naming it as the default rather than a graded
  result, so a defaulted `full` stays distinguishable from a graded one — the same
  distinguishability the Fail-closed contract requires
- MUST define `light` as **exactly 2 investigators with distinct flavor presets (Phase 2) plus
  the Phase 5 Judge**; Phase 3 (Dynamic Domain Specialist) and Phase 4 (Prosecution & Defense)
  MUST be skipped, and the report MUST record the skip and its reason (`council_tier: light`)
  as a visible audit trail, in the same manner as Phase 2.5's documented bypass note
- MUST select light flavor subsets per preset:

  | Preset | `full` flavors | `light` flavors |
  |---|---|---|
  | `generic` | `paranoid-ic`, `jaded-senior` | `paranoid-ic`, `jaded-senior` (unchanged — already exactly 2) |
  | `diff-mode` | `logic`, `security`, `compliance`, `quality`, `simplification` | `logic`, `security` |

  Light `diff-mode` keeps the two correctness/safety axes and drops the three polish axes. It is
  reachable only via an explicit `--council-tier=light` on a `--diff` invocation, since no call
  site grades `--diff` automatically (see Grading).

> **Naming note.** Command Shape & Scope MUST NOT "accept, document, or implement a
> `--no-council` flag". `--council-tier=skip` is a single uniform tier vocabulary and does not
> resurrect that forbidden token.

> **`diff-mode` flavor clarification (not a new violation).** Phase 2's "paranoid-ic + at least
> one other" parenthetical is generic-preset-specific; `diff-mode` already carries none of the
> `paranoid-ic` flavor today. The operative requirement — ≥ 2 investigators with distinct
> flavors — is what light `diff-mode` satisfies.

#### `light` rescopes no Phase-2 or Phase-2.5 MUST

`light`'s investigator count of **2** is forced by two existing requirements rather than chosen
freely, and it threads both without amendment:

- Phase 2's "MUST spawn at least 2 investigators per claim with distinct flavor presets
  (paranoid-ic + at least one other) to defeat monoculture" is satisfied **verbatim** at 2. No
  Phase-2 MUST is rescoped and the monoculture defense is not weakened.
- Phase 2.5's "MUST skip Phase 2.5 when fewer than 3 investigators participate" is **not**
  tripped at 2, so blind cross-review self-skips with no new logic and no new bypass reason.

At 1 investigator a live MUST would have to be rescoped; at 3 Phase 2.5 would fire and spawn a
cross-review round that erases the saving.

**Skipping Phase 4 does require scoping, and that scoping is done in place.** `light` is the
first `verdict[]`-shape run with no Phase 4 — diff-mode's Phase-4 skip existed only in
`engine.sh` preflight and `skills/review-and-commit/SKILL.md`, never in this contract — so three
requirements are scoped at their own homes rather than restated here:

- Phase 4's "MUST spawn exactly one Prosecutor and one Devil's Advocate" now reads *per council
  run **in which Phase 4 runs***, with the run/skip condition stated in the Phase 4 preamble
- Phase 5's "MUST pass the Judge: original claims, evidence bundles, Prosecutor brief, Devil's
  Advocate brief" now makes the two **brief inputs Phase-4-conditional**: at `light` the Judge
  receives claims + evidence bundles only, and the engine MUST NOT synthesize or stub an absent
  brief
- Phase 2.5's bypass destination now reads *the next phase that runs* — Phase 5 when Phase 4 is
  itself skipped — instead of an unconditional "proceed directly to Phase 4"
- Phase 6's report-contents requirement makes the two briefs Phase-4-conditional on the same
  terms, recording the skip and its reason in their place rather than an empty brief section

No other MUST anywhere in this spec changes, and the Phase-4 skip introduces no new violation.

#### `council_tier` is orthogonal to `verification_mode`

- MUST keep `verification_mode` a strict two-value enum (`full | self-verified`) meaning exactly
  what Spawn-failure degradation (CDV-199) defines today
- MUST NOT fold `council_tier` into `verification_mode`, widen that enum with a tier value, or
  derive either field from the other — they answer different questions:

  | Field | Question | Values |
  |---|---|---|
  | `council_tier` | Which roles did the run *intend* to run? | `skip \| light \| full` |
  | `verification_mode` | Did the intended roles *actually* run? | `full \| self-verified` |

  The fields are genuinely orthogonal: a **light run whose Judge spawn fails** is *both* `light`
  **and** `self-verified`. A single widened enum cannot express that state, so widening would be
  a type error — the same conflation SPEC-033 M13 already refuses when it keeps the gate
  `decision` separate from the council `verdict`.

- Consequently a *healthy* `light` run MUST NOT set `verification_mode: self-verified` and MUST
  NOT emit the marker `self-verified — refuters unavailable`; a *degraded* `light` run still MUST
  set both, exactly as a degraded `full` run does. Downstream consumers keying on
  `verification_mode` (SPEC-033 M14(d), both report templates, `workflow.js`) need no change

#### Grading

Grading bands a diff the call site already resolves. It introduces **no new diff-resolution
concept**: the grader is fed the `--numstat` of a diff whose resolution mechanism is already
specified elsewhere.

**Exactly one call site grades automatically.** Tier selection reaches every other site through
the explicit `--council-tier` override, which short-circuits grading entirely. Note the two
override values behave differently: `light`/`full` pass straight through to the engine as the
run's tier, whereas `skip` never reaches `/council` or the engine at all (Tier vocabulary) — it
is resolved by the caller, which records the index row itself with no council run:

| Call site | Tier source | Diff the grader bands |
|---|---|---|
| Autopilot ship gate (SPEC-033 M14(e)) | **automatic grading** | `git diff --numstat $(git merge-base <default> HEAD)..HEAD`, with `<default>` from SPEC-033 N3a's `git symbolic-ref refs/remotes/origin/HEAD` resolution, reused at the same step |
| Orchestrated task gate (`requires_council: true`) | `--council-tier` override only; **`full`** when absent | n/a — this gate runs **claim scope**, not `--diff` |
| Manual `/council` (any scope, including `--diff`) | `--council-tier` override only; **`full`** when absent | n/a — no grading |

Two consequences worth stating so they are not mistaken for oversights:

- The **task gate runs claim scope by product policy, never `--diff`.** Orchestrated
  `requires_council: true` gates audit model-authored claims (`verdict[]`-shape, real Judge
  confidence). `--diff` resolves `preset: diff-mode` (`finding[]`-shape, writes
  `max_finding_confidence` with `max_verdict_confidence: null`). The SPEC-002 TaskCompleted
  hook is dual-shape and **would** accept a qualifying finding-confidence row, but product
  policy forbids `--diff` at the task gate because that gate is a claim audit, not code
  review. Tiering applies on the claim path unchanged, sourced from the override rather than
  grading.
- **Manual `/council --diff` runs `full` unconditionally.** This is the "manual invocations are
  unaffected and run `full`" rule at the top of this section, not a special case: automatic
  grading is scoped to the one gate above. A manual `/council --diff --task-id X` that writes a
  qualifying `max_finding_confidence` **can** satisfy the dual-shape hook (CDT-122); orchestrate
  still instructs claim scope.

Grader inputs are `files` (changed-file count) and `loc` (added + deleted). Bands — **normative
here; SPEC-033 M14(e) cites this table rather than restating it**:

- **clear-low → `light`** — `files ≤ 5` **AND** `loc ≤ 100` **AND** no critical-area signal
- **clear-high → `full`** — `files > 20` **OR** `loc > 600` **OR** any critical-area signal
- **ambiguous middle** — MUST resolve via exactly one haiku-tier triage call returning
  `{tier, reason, risk_signals[]}` with `tier ∈ {light, full}`

The bands are deliberately conservative (narrow `light` band); expect one tuning pass once
`council_tier` telemetry accumulates.

**Critical-area signals** MUST be computed structurally — MUST NOT be a hardcoded literal path
list:

1. **Spec / contract file** — path contains a `specs/` segment, **or** basename matches
   `SPEC-*.md`, **or** the file carries YAML frontmatter with a `status:` key
2. **Executable** — the post-image begins with `#!`, or `git diff --raw` reports mode `100755`
3. **High fan-in** — the changed file's basename is referenced by ≥ 5 other tracked files
   (`git grep -l -F <basename> | wc -l`) — computed per run, never hardcoded
4. **Deletion-heavy executable** — more than 30 deleted lines in a file matching signal 2
5. **Test removal** — net-negative LOC in a file matching `*test*`, `*_test.*`, or `test_*`

Signal 3 is the only costly probe, so its scope is capped per band. It MUST run in **both** the
clear-low and the ambiguous-middle band:

- **clear-low candidates** — MUST run, capped at **5 files**. The clear-low band is `files ≤ 5`
  by definition, so this costs at most 5 `git grep`s — cheaper than the middle band's cap, which
  this section already accepts as reasonable cost
- **ambiguous-middle candidates** — MUST run, capped at **20 files**
- Exceeding either cap MUST be treated as a critical-area hit (fail-closed)

Running signal 3 at clear-low is **required for the band definitions to mean what they say**:
clear-low is defined as "no critical-area signal", which cannot hold if a critical-area signal
was never evaluated. Skipping the probe there would let a 3-LOC change to a high-fan-in file
grade `light` unprobed — leaving the grader blind to precisely the semantic risk the `files`/`loc`
thresholds cannot see, which is the "rules-only, blind to semantics" outcome this design rejects.

#### Fail-closed contract

- MUST resolve to `full` on **any** grading failure: missing `jq`, git failure, empty or
  unresolvable diff, unresolvable `origin/HEAD`, grader non-zero exit — and, for the triage
  call, invalid JSON, a missing `tier` key, `tier ∉ {light, full}`, timeout, or non-zero exit
- MUST record the failure in the run's `grading_reason` so a fail-closed `full` stays
  distinguishable from a graded `full`

> This deliberately **inverts** SPEC-026 M9's fail-open precedent, and the inversion is
> intentional rather than an inconsistency. M9 fails open because a metrics failure must never
> block real work. Here, failing open would silently *weaken a verification gate* — the opposite
> risk direction, hence the opposite default.

#### Recording the tier

- MUST record `council_tier` and `grading_reason` in the report frontmatter alongside the
  existing `scope` / `preset` / `output_shape` / `created_at` / `verification_mode` keys (Task
  Binding & Verdict Index) — declared in the report templates' own frontmatter block and
  substituted by finalize, never prepended as a second block. This applies to `light` and `full`
  runs; a `skip` produces **no report at all**, so there is no frontmatter to carry
- MUST record `council_tier` and `grading_reason` on the `.claude/council/index.json` row,
  extending the row shape to `{ "report_path", "max_verdict_confidence",
  "max_finding_confidence", "created_at", "council_tier", "grading_reason" }`. `index.json` is
  SPEC-013's file (SPEC-026 M10 forbids other writers), so this row is SPEC-013's to extend —
  one owner, one spec
- The index row is therefore the **only** surface carrying all three tier values. `light`/`full`
  rows are written by `engine.sh` finalize after a real run; a `skip` row is written by the
  short-circuiting caller itself through that **same** one owning writer, with an empty
  `report_path` and null confidences, and a `grading_reason` naming the DRI decision. The
  index-row `council_tier` vocabulary is thus `skip | light | full`, wider than either the
  `/council` or `engine.sh` flag surface — deliberately, because the row must be able to record
  a decision that no council run produced
- MUST NOT extend the `task-store.sh` task record with the tier: that schema is read by the
  SPEC-002 TaskCompleted hook, so extending it would drag SPEC-002 into scope for a field the
  index row already carries at the correct moment — immediately before the gated call
- The autopilot ship gate additionally records the tier on its decision card (SPEC-033 M13 /
  M14(e)); that surface is SPEC-033's, not this spec's

#### Execution-path scope

- The Council-on-Workflow execution path (CDV-196) is **`full`-only**. When `--workflow` /
  `COUNCIL_WORKFLOW=1` is set **and** the resolved tier is `light`, the run MUST fall back to
  `engine.sh` through the **existing** transparent-fallback seam rather than silently upgrading
  the run to `full` or forking tiering behavior into `workflow.js`. This preserves strict output
  parity — a consumer must never be able to tell which path produced a run — without a second
  tiering implementation
- The tier-driven fallback MUST emit its own one-line stderr notice,
  `council: council_tier=light unsupported on the Workflow path; falling back to engine.sh`, and
  MUST NOT reuse CDV-196's availability notice (`council: Workflow unavailable; falling back to
  engine.sh`), which would be **false** here: the Workflow tool *is* available; only the tier is
  unsupported. A distinct string is required rather than forbidden — CDV-196's "never invent a
  parallel string" rule scopes the CDV-199 self-verified degradation marker, not this seam

#### Cross-reference — CDT-122 (resolved)

**CDT-122 is resolved.** The SPEC-002 TaskCompleted hook accepts either confidence shape
(non-null `max_verdict_confidence` **or** null verdict conf + non-null `max_finding_confidence`;
full algorithm deferred to SPEC-002). `finding[]`-shape / diff-mode runs still write
`max_verdict_confidence: null` and a real `max_finding_confidence` — those rows are no longer
structurally ignored. Tiering **neither invents nor reverts** that dual-shape contract:
`light` and `full` diff-mode runs write the same confidence columns as before; only the hook
acceptance rule changed (CDT-122), not tier selection. Product task-gate policy still prefers
claim scope (see Council tiering consequences above).

### Phase 1 — Claim Extraction
- MUST run a claim-extraction pass before investigation when scope is `--session`, `--plan`, or transcript-derived
- MUST enrich diff-mode raw input with the applicable-specs grep output (from diff-mode intake) before claim extraction runs; diff-mode claim extraction extracts candidate findings from the diff, not claims-as-assertions
- MUST produce a structured list of load-bearing assertions with: claim text, source locator (turn ID / file:line), claim type (factual / causal / recommendation)
- MUST skip the extraction pass when scope is a single pasted claim or `--from-retro <anchor-id>` (claim already isolated)
- MUST enforce a per-run claim budget (default: 10 claims) to prevent runaway cost
- MUST rank claims by load-bearing weight when the budget is exceeded (highest-stakes first)

### Phase 2 — Parallel Investigation
- MUST spawn investigators in parallel, one task per claim (up to the claim budget)
- MUST pass each investigator the raw artifacts (files, logs, diffs, plan text) required for the claim — MUST NOT pass the model's prior narrative or prior verdicts
- MUST forbid investigators from any write operation (read-only tool allowlist: Read, Grep, Glob, Bash for read commands, MCP query tools)
- MUST require each investigator to return an **evidence bundle** containing: tool_use_id, raw tool output blob, file:line citation, reproducible command
- MUST reject evidence bundles that lack a tool_use_id — the engine MUST treat such bundles as "no evidence collected"
- MUST spawn at least 2 investigators per claim with distinct flavor presets (paranoid-ic + at least one other) to defeat monoculture

### Spawn-failure degradation *(CDV-199)*

When a required Task spawn for an investigator, cross-reviewer, prosecutor,
advocate, specialist, or judge fails or returns unusable output (rate-limit,
refusal, empty/malformed return — any unusable spawn, not rate-limit-only):

- MUST have the **orchestrator** (the session driving `/council` or
  `/review-and-commit`) perform that role's work with real tools — MUST NOT
  treat the implementer's self-assertion as verification
- MUST set report frontmatter `verification_mode: self-verified` and include
  the exact marker string `self-verified — refuters unavailable` in the
  report body (via finalize `--verification-mode self-verified`)
- MUST continue finalize when self-verify yields ≥1 usable evidence bundle
  (or equivalent role output for non-investigator phases)
- MUST keep exit 5 when evidence is empty **and** self-verify was not
  attempted or still produced zero bundles
- MUST NOT invent local-agent routing for investigators (deferred; out of
  scope for this degradation path)
- Self-verified runs still satisfy `requires_council` when a task-bound
  index row is written — the marker is for audit visibility, not a gate block

Default (all spawns succeed): `verification_mode: full` and no banner.

### Phase 3 — Dynamic Domain Specialist *(CDV-209)*

Active. Topic classification via `skills/council/prompts/topic-classifier.md`;
dispatch in `commands/council.md`; plan fields from `engine.sh` preflight
(`phases.3_domain_specialist.deferred: false`). Runs after Phase 2 and
**before** Phase 2.5. Diff-mode (`finding[]`) MUST skip Phase 3 (flavor
investigators already cover specialist axes).

- MUST inspect each claim's topic and pull a domain specialist when a match exists:
  - Deploy / infra / CI / Docker / K8s claims → `devops` agent
  - Metrics / statistics / ML / data-pipeline claims → `ds` agent
  - Test / coverage / regression claims → `qa` agent
  - Product / requirements / scope claims → `pm` agent
- MUST NOT pull a specialist when no confident topic match is found
  (confidence threshold ≥ 0.75; weak signal → skip)
- MUST cap at most one specialist spawn per council run
- MUST treat the specialist as an additional investigator (blind to prior narrative, read-only, returns an evidence bundle)
- MUST NOT pull a specialist in diff-mode (`finding[]` / `--diff`)

### Phase 2.5 — Blind Cross-Review *(COUNCIL-002)*
- MUST anonymize evidence bundles before cross-review: strip investigator identity, assign random labels (A, B, C…), and shuffle label order independently per reviewer to defeat position bias
- MUST exclude each investigator from ranking their own bundle (self-exclusion)
- MUST forbid cross-reviewers from running any tools — evaluation is over submitted bundles only, not raw artifacts
- MUST aggregate per-reviewer rankings via Borda count into a consensus quality score per bundle
- MUST pass evidence bundles to Phase 4 (Prosecution & Defense) and Phase 5 (Judgment) ordered by Borda consensus rank, not submission order
- MUST flag bundles in the bottom Borda quartile as `WEAK_EVIDENCE` in the report
- MUST skip Phase 2.5 when fewer than 3 investigators participate (minimum for meaningful cross-ranking); proceed directly to the next phase that runs — Phase 4 normally, or **Phase 5 when Phase 4 is itself skipped** (`finding[]`-shape presets, or `council_tier: light`) — and note the bypass reason in the report
- SHOULD record each reviewer's per-bundle rankings in the report as a visible audit trail

### Phase 4 — Prosecution & Defense

Phase 4 runs for `verdict[]`-shape presets at `council_tier: full`. It is **skipped** for
`finding[]`-shape presets (diff-mode — the flavor investigators already cover both roles' axes;
this skip was previously implementation-only in `engine.sh` preflight and
`skills/review-and-commit/SKILL.md`, and is stated at spec level here) and at `council_tier: light`
(Council tiering). The requirements below govern Phase 4 **whenever it runs**.

- MUST spawn exactly one Prosecutor and one Devil's Advocate per council run in which Phase 4 runs
- MUST pass both the evidence bundles from investigators, NOT the original claims — the Prosecutor and Devil's Advocate are BLIND to the original claim list and operate on evidence alone; each role groups bundles by the `claim_id` carried inside the bundles, never by a separately supplied claims list (the Judge in Phase 5 still receives the original claims — that seam is unchanged)
- MUST require Prosecutor to produce a brief listing each claim (by the `claim_id` in the bundles), the evidence against it, and a requested verdict
- MUST require Devil's Advocate to produce a brief listing each claim (by the `claim_id` in the bundles), the evidence supporting it, and a requested verdict
- MUST forbid Prosecutor and Devil's Advocate from making factual assertions not backed by an investigator tool_use_id — such lines MUST be struck by the engine

### Phase 5 — Judgment
- MUST route judgment to a dedicated `council-judge` agent defined at `agents/council-judge.md`; the `council-judge` agent MUST declare an empty tool allowlist in its YAML frontmatter. The Judge's authority is the evidence bundle plus its standing behavioral rules. The engine MAY prepend `tech-lead`'s project cortex to the Judge invocation for plausibility calibration, but this is OPTIONAL — the Judge is by-design evidence-only (empty tool allowlist, cannot run a recall/cortex-load path itself), so it MUST function correctly with no cortex injected
- MUST forbid the Judge from running any tool (Read, Grep, Bash, MCP, Write, Edit) — enforced structurally via tool allowlist
- MUST pass the Judge: original claims and evidence bundles **always**; the Prosecutor brief and Devil's Advocate brief **whenever Phase 4 ran**. The two brief inputs are **Phase-4-conditional**: when Phase 4 is skipped (`finding[]`-shape presets, or `council_tier: light`) the Judge receives claims + evidence bundles only, and the report MUST record the absent briefs as part of the Phase-4 skip note. The engine MUST NOT synthesize, stub, or empty-string a brief the run never produced
- MUST require, for `verdict[]`-shape presets, the Judge to produce a per-claim verdict from the fixed taxonomy: `VERIFIED | PARTIALLY_VERIFIED | UNVERIFIED | CONTRADICTED | FABRICATED`
- MUST require, for `finding[]`-shape presets, the Judge to emit findings from the fixed severity taxonomy `critical | warning | nitpick` — the Judge's job in diff-mode is to dedupe, cross-check citations, and strike unsupported findings, not to verdict-ify claims
- MUST require a 0–100 confidence score on each verdict or finding
- MUST require inline raw tool output blobs in the verdict (not paraphrased) — if the blob is missing or does not contain the quoted citation, the verdict line MUST be struck as unsupported
- MUST preserve the empty tool allowlist for the Judge across both output shapes

### Phase 6 — Report & Persistence
- MUST write a report to `.claude/council/<YYYY-MM-DD>-<slug>.md` (create parent dir if absent)
- MUST include in the report: scope, extracted claims, investigator flavors used, evidence bundles, per-claim verdict or per-finding entry with confidence and raw evidence — plus the Prosecutor brief and Devil's Advocate brief **whenever Phase 4 ran**. Like the Phase 5 Judge inputs, the two briefs are **Phase-4-conditional**: when Phase 4 is skipped (`finding[]`-shape presets, or `council_tier: light`) the report MUST record the skip and its reason in their place, and MUST NOT emit an empty or synthesized brief section
- MUST branch the report template on output shape: `verdict[]` presets emit a verdict summary by taxonomy (session/plan/claim scopes); `finding[]` presets emit a findings summary by severity (diff scope)
- MUST print a summary to stdout with verdict counts by taxonomy (or finding counts by severity for `finding[]`-shape presets) and a path to the full report
- MUST resolve the project root with the worktree-aware formula: `_gc=$(git rev-parse --git-common-dir 2>/dev/null) && MROOT=$(cd "$(dirname "$_gc")" && pwd) || MROOT=$(pwd)`

#### Task Binding & Verdict Index
- Report templates (`skills/council/templates/report-verdict.md`, `report-finding.md`) MUST carry a single YAML frontmatter block that includes `task_id: "{{TASK_ID}}"` (plus `scope`, `preset`, hard-coded `output_shape`, `created_at`, `verification_mode`); finalize substitutes `{{…}}` placeholders and MUST NOT prepend a second synthetic frontmatter block
- When a council run is associated with an orchestrated task (resolved via the fallback chain: `--task-id` flag → `CLAUDE_TASK_ID` env var → none), the report MUST include a `task_id` field in its frontmatter/header section and MUST write the report to `.claude/council/<YYYY-MM-DD>-<slug>--<task_id>.md`
- When no task id is resolved, finalize MUST strip the unbound `task_id` key entirely (not null, not empty string) so the field is absent from the report frontmatter, and the filename MUST NOT carry a `--<task_id>` suffix
- The engine MUST maintain a lightweight verdict index at `.claude/council/index.json` — a single JSON document shaped as `{ "<task_id>": [ { "report_path": string, "max_verdict_confidence": int, "max_finding_confidence": int, "created_at": ISO-8601 }, … ], … }`; entries are append-only per task_id (newest first), never mutated in place
- The engine MUST append a new index entry at the end of every task-bound council run, after the report file is written
- The verdict index MUST be the single source of truth queried by the SPEC-002 TaskCompleted hook — the hook MUST NOT scan `.claude/council/*.md` report files directly
- The engine MUST update the index atomically via write-to-tmp + rename (`.claude/council/index.json.tmp` → `.claude/council/index.json`) so a concurrent hook read never observes a partial write
- `finding[]`-shape runs MUST still populate `max_finding_confidence` in the index row but MUST leave `max_verdict_confidence` as `null`; the SPEC-002 TaskCompleted hook accepts **either** shape (verdict conf **or** finding conf) — full dual-shape algorithm deferred to SPEC-002

### Phase 7 — Learning Loop (Feedback Memory)
- MUST scope Phase 7 to `verdict[]`-shape presets only; `finding[]`-shape presets (e.g., diff-mode) MUST NOT trigger feedback memory writes — a code bug is not a fabrication
- MUST auto-write a feedback memory when any verdict is `FABRICATED` with confidence ≥ 70
- MUST auto-write a feedback memory when any verdict is `UNVERIFIED` with confidence ≥ 85
- MUST structure each feedback memory with: the false claim, the contradicting evidence, the tool that should have been run before asserting it, a **Why:** line, a **How to apply:** line
- MUST write feedback memories to the plain-Claude lessons file (`$MROOT/.claude/memory/claude/lessons.md`) when the audited subject is a plain Claude session
- MUST route feedback memories for team-agent-authored claims through `/adjust-agent <agent> --apply` (consistent with SPEC-012 routing convention, preserves SPEC-001 conflict detection)
- MUST make the confidence thresholds configurable via `.claude/settings.json` (`council.feedback.fabricated_min`, `council.feedback.unverified_min`)

### Integration Hooks
- MUST add a `/retro` hint: when the retrospective detects a fabrication-pattern anchor, MUST print `Consider: /council --from-retro <anchor-id>` — MUST NOT auto-run council (SPEC-012 update required)
- MUST support an opt-in `requires_council: true` metadata field on orchestrated tasks; when present, the TaskCompleted hook MUST block completion until a council verdict exists with confidence ≥ threshold (SPEC-009 update required)
- MUST NOT enable any integration hook globally — all council invocations MUST be explicit (user-typed or opt-in task metadata)

#### Task-ID Plumbing
- `/council` MUST accept an optional `--task-id <id>` flag to explicitly bind a run to a specific orchestrated task
- The engine MUST resolve the active task id via the fallback chain: `--task-id <id>` flag → `CLAUDE_TASK_ID` environment variable → unbound
- Orchestrated-task council invocations MUST set `CLAUDE_TASK_ID=<id>` in the spawned council subprocess environment so ambient detection works even when the flag is omitted
- `task-completed.sh` MUST look up the completing task's id in `.claude/council/index.json` and apply `council.taskgate.min_confidence` to the dual-shape effective score (non-null `max_verdict_confidence` **or** null-verdict + non-null `max_finding_confidence` across that task's entries) — full algorithm deferred to SPEC-002; this bullet exists only to name the index as the lookup surface
- When `requires_council: true` is declared on a task but no entry exists in `.claude/council/index.json` for that task id, the index miss is the canonical "no verdict exists" signal the SPEC-002 hook MUST fail on
- The engine MUST NOT fall back to filename pattern scanning when the index is missing or unreadable — a missing index is a hard miss, never a soft miss
- The `/council` command task-id fallback chain (`--task-id` flag → `CLAUDE_TASK_ID` env → unbound) applies only to direct command invocations; the SPEC-002 TaskCompleted hook uses its own stdin-based task-id resolution per SPEC-002 hook contract and does NOT participate in this fallback chain — the two paths are independent

### Scope Exclusions
- MUST NOT grant write access to any council role (Prosecutor, Investigator, Devil's Advocate, Domain Specialist, Judge)
- MUST NOT propose fixes in the verdict report — council is a pure auditor
- MUST NOT audit the user's claims — only model-authored output
- MUST NOT run council automatically on every session, commit, or retro
- MUST NOT replace `/retro` or `/orchestrate` — council composes with them
- MUST NOT register council members in `init-team` bootstrap
- MUST NOT persist investigator state between runs (ephemeral only, no cortex)
- The TaskCompleted council gate is **dual-shape** per SPEC-002 (accepts non-null `max_verdict_confidence` **or** null-verdict + non-null `max_finding_confidence`). Product orchestrated-task gate policy still uses **claim** scope (`verdict[]` / `generic`) by default — not because finding conf is unusable, but because that gate is a claim audit. Blind-path runs remain gate-ignored (prefer unbound / no qualifying index row; both-null conf fails)
- MUST NOT invoke `/council` (or any second council engine run) from inside a `--blind` run for reverse validation of its own clusters — the reverse-validation seam is removed (CDT-46-C3)


### Blind-review path (`--blind`) *(CDT-46-C3)*

Absorbs the former `/council --blind` multi-team peer-review engine into `/council` as a first-class **scope flag** (not an orthogonal path selector like `--workflow`). The blind path is a distinct execution path: it does **not** run tribunal Phases 1–5 (claim extraction → investigation → prosecution → judgment). Clustering + confidence tiering **is** the council verdict for this path.

- MUST implement the `--blind` execution path inside `skills/council/` (engine skill) — MUST NOT maintain a parallel blind-review pipeline outside the council skill after absorption
- MUST expose `commands/council.md` as the user entry for `/council --blind` (with parity flags); `commands/council --blind.md` remains only as a DEPRECATED one-cycle stub pointing at `/council --blind`
- MUST spawn **N unconstrained** reviewer agents + **M lens-differentiated** reviewer agents in a **single parallel wave** (never sequential fan-out)
  - N from `--teams` (default 3); team IDs `U1..UN`
  - M from `--lenses` (default `security,contributor,spec`); team IDs `L-<lens>`; available lenses: `security`, `contributor`, `spec`, `architecture`, `logic`
  - Reviewer file list from `--target <path>` when set, else full project tracked files (excluding lockfiles/generated assets)
- MUST namespace each finding with its team ID, discard malformed findings (missing Category/Severity/Files/Claim/Evidence — drop, do not repair), then run a **quorum analyst** that clusters findings by **semantic similarity**
- MUST assign confidence tiers to clusters:
  - **Tier 1** — cross-cohort (at least one unconstrained AND at least one lens team) AND ≥2 distinct teams (highest confidence)
  - **Tier 2** — same-cohort consensus (≥2 distinct teams, not cross-cohort)
  - **Tier 3** — single-team minority findings
- MUST emit **Tier-1 consensus clusters directly as council findings** in the blind-path report — the clustering + tiering step **is** the verdict; MUST NOT call `/council` (or re-enter the tribunal pipeline) on Tier-1 clusters for reverse validation
- MUST include Tier 2 and Tier 3 clusters in the report (sorted Tier 1 → 2 → 3) without escalating them through a second council pass
- MUST write the blind-path report under `.claude/council/<YYYY-MM-DD>-<slug>.md` (worktree-aware `MROOT`; create parent if absent) with: scope/target, team manifest, tiered clusters (claim, evidence, severity, category, team count, source finding IDs), quorum summary, per-team summaries, and count of dropped malformed findings
- MUST treat blind-path output as **gate-ignored** for TaskCompleted purposes: blind runs prefer unbound reports (no `task_id` / no qualifying index row for the completing task). A skip-style row with both confidences null still fails the dual-shape gate if bound; blind review is multi-perspective code review, not a fabrication audit
- MUST fail loudly (exit non-zero with usage) when `--teams` / `--lenses` / `--target` are supplied without `--blind`, or when `--blind` is combined with another scope flag
- When `--blind` adds or reuses prompt templates under `skills/council/prompts/`, each template's `## Variables` table remains the authoritative `{{TEMPLATE_VARIABLE}}` contract (Engine Architecture MUST) — prefer reusing existing investigator/lens variable names over inventing a parallel set


### Council-on-Workflow execution path *(CDV-196)*

Optional Workflow-tool execution path for the tribunal. **Strict output parity**
with the default `engine.sh` + Task path: same verdict/finding schemas, same
`.claude/council/index.json` rows, same report files/naming. Judge stays tool-less
on both paths. Transparent fallback when Workflow unavailable. Reuse CDV-199
degradation marker — never invent a second string. Distinct from CDV-197
(`/debug ticket` workflow promotion; former `/fix-ticket`) — share authoring conventions only
(args-as-JSON-string guard).

- MUST keep `skills/council/engine.sh` as the canonical default execution path — the Workflow path activates only on explicit opt-in (`/council --workflow` flag or `COUNCIL_WORKFLOW=1` environment variable); with neither set, behavior is byte-for-byte today's engine.sh path
- MUST detect Workflow availability before relying on it (capability probe or attempt-and-fallback): when the Workflow tool is unavailable (free plan, or a Claude Code version below the Workflow minimum), the run MUST fall back transparently to engine.sh with a one-line stderr notice — never a hard failure, never a degraded report
- MUST preserve strict output parity with engine.sh: identical `verdict[]`/`finding[]` JSON schemas and taxonomies, identical `.claude/council/index.json` writes (same row shape, append-only, atomic tmp+rename), and identical report shape and naming at `.claude/council/<YYYY-MM-DD>-<slug>[--<task_id>].md` — downstream consumers (the SPEC-002 TaskCompleted gate, `/retro`) MUST NOT be able to tell which path produced a run
- MUST keep the Judge tool-less on the Workflow path: the judgment step MUST use agentType `council-judge` (plugin-qualified as installed, e.g. `dev-team:council-judge`) with an empty tool allowlist (Phase 5 invariant unchanged) — schema-forced output changes the transport, not the evidence-only design
- MUST use `agent()` schema-forced structured output for the investigator, Prosecutor, Devil's Advocate, and Judge steps; the Workflow path MUST NOT port the engine.sh JSON-repair layers forward — a schema violation on this path is a step failure, not a repair candidate
- MUST handle investigator/refuter spawn failures on the Workflow path with the same explicit self-verified-marker degradation as Spawn-failure degradation (CDV-199): pass `engine.sh finalize --verification-mode self-verified` so the report carries the exact marker `self-verified — refuters unavailable` — never silent role omission; never invent a parallel degradation string
- MUST single-source prompt and flavor bodies: the Workflow path reads the same `skills/council/prompts/*` and `skills/council/flavors/*` assets as the Task path, honoring each prompt's `## Variables` table contract — MUST NOT fork or inline-duplicate prompt content between the two paths
- MUST share Workflow authoring conventions with CDV-197 / fix-ticket workflow (adjacent, distinct): notably the args-may-arrive-as-JSON-string guard (`typeof args === 'string' ? JSON.parse(args) : args`)
- MUST implement the Workflow driver at `skills/council/workflow.js` and hand off plan + evidence + judge JSON files to **existing** `engine.sh finalize` (shared finalize — no dual report renderers)
- MUST document opt-in + fallback in `commands/council.md` and `skills/council/SKILL.md`; `/review-and-commit` MUST honor the same opt-in (`--workflow` or `COUNCIL_WORKFLOW=1`) and cite the council dual-path protocol (no parallel pipeline)


---

## SHOULD

- SHOULD rank claims in extraction phase by load-bearing weight (high-stakes claims audited first when budget is tight)
- SHOULD cache investigator tool calls within a single council run to avoid redundant file reads across claims (CDV-211: preflight creates `${TMPDIR:-/tmp}/council-cache-<run_id>/` with `reads/` + `greps/` keyed by sha256; plan emits `cache_dir` + `run_id`; investigator.md cache-first protocol via `{{CACHE_DIR}}`; optional orchestrator seed from claim locators; finalize best-effort rm; empty cache is correctness-neutral)
- SHOULD report per-phase token usage in the summary to make cost visible (CDV-204: finalize `--tokens-file` with phase→int map; optional report frontmatter `tokens_total` / `tokens_by_phase`; graceful omit when harness has no tokens — never invent `0` as measured usage; does not alter `index.json` schema)
- SHOULD support `--why` flag to print the flavor presets used and the reasoning behind domain specialist selection
- SHOULD support an optional `--external[=codex|gemini]` investigator slot that shells out to an installed external CLI (detection order: codex then gemini; first available wins) as **one additive** investigator, normalizes CLI stdout into the engine `evidence_bundle` / `finding[]` shape via `skills/council/external-reviewer.sh`, and **gracefully skips** (one-line stderr notice; continue with internal investigators only) when no CLI is present or invoke fails — MUST NOT hard-fail solely for an external miss; MUST keep ≥1 internal investigator (never replace the full internal set) (CDV-207)
- SHOULD surface struck verdict lines (evidence-less claims by Judge/Prosecutor/Advocate) in the report as a visible audit trail, not silently dropped
- SHOULD print a concise stdout summary by default and reserve the full report for the file

---

## Test

### Test 1 — Single claim audit with fabrication
1. Paste a known-false claim: `/council "the retry logic in commands/retro.md uses exponential backoff with jitter"`
2. Observe: investigators spawn, read `commands/retro.md`, return evidence bundles
3. Verify: Judge verdict is `FABRICATED` with confidence ≥ 70
4. Verify: report written to `.claude/council/<date>-*.md`
5. Verify: feedback memory written to `.claude/memory/claude/lessons.md` with Why/How-to-apply lines
6. Verify: raw file content appears inline in the report, not paraphrased

### Test 2 — Blind investigator guarantee
1. Invoke `/council --session --last 20` after a session where the model made a shaky claim
2. Inspect the spawned investigator task prompts (via task output)
3. Verify: investigator prompts contain raw artifacts (file contents, logs) but NOT prior narrative claims or assistant turn text
4. Verify: investigator tool_use_ids match the tool calls recorded in the evidence bundles

### Test 3 — Judge cannot run tools
1. Inspect the Judge invocation in the council engine
2. Verify: Judge's tool allowlist is empty of Read, Grep, Bash, Write, Edit, MCP query tools
3. Attempt to run council with a Judge that tries to call a tool (via test harness)
4. Verify: the attempt is blocked and the verdict is marked invalid

### Test 4 — Evidence-or-silence enforcement
1. Run a council where the Judge paraphrases a tool output instead of including the raw blob
2. Verify: the paraphrased verdict line is struck from the report
3. Verify: the struck line is visible in the report's audit trail (not silently dropped)

### Test 5 — `/review-and-commit` engine share
1. Run `/review-and-commit` on a staged diff after SPEC-013 implementation
2. Verify: it dispatches to the council engine with `preset: diff-mode`
3. Verify: the 5 original specialists (Logic, Security, Compliance, Quality, Simplification) are loaded as flavor presets from `skills/council/flavors/`
4. Verify: the verdict schema matches `/council` output (same taxonomy, same confidence score format)

### Test 6 — `/retro` integration hint
1. Run a session containing a fabricated claim, then `/retro`
2. Verify: `/retro` detects the fabrication anchor and prints `Consider: /council --from-retro <anchor-id>`
3. Verify: `/retro` does NOT auto-invoke `/council`

### Test 7 — Budget enforcement
1. Run `/council --session` on a large session with 50+ extractable claims
2. Verify: only the top N (default 10) claims are investigated
3. Verify: the report notes the budget cap and lists the un-audited claims

### Test 8 — Domain specialist selection (CDV-209)
1. Run `/council "the k8s rollout is healthy"`
2. Verify: topic classifier maps claim to deploy/devops with confidence ≥ 0.75
3. Verify: the `devops` agent is pulled as a domain specialist (blind investigator bundle)
4. Run `/council "the a/b test shows statistical significance at p<0.05"`
5. Verify: the `ds` agent is pulled
6. Run `/council "users love the new onboarding flow"` (no topic match)
7. Verify: no domain specialist is pulled, only default investigators
8. Run `/council --diff` (or any finding[] preset): Verify Phase 3 is skipped
9. Static: `engine.sh preflight` → `.phases["3_domain_specialist"].deferred == false`

### Test 9 — Task-bound council gate
1. Declare an orchestrated task with metadata `requires_council: true` and capture its id as `$TID`
2. Run `/council --task-id $TID --session --last 10` against a session containing a verifiable claim
3. Verify: report file is written to `.claude/council/<date>-<slug>--$TID.md` (task-id suffix present)
4. Verify: report frontmatter includes a `task_id: $TID` line
5. Verify: `.claude/council/index.json` exists and contains a `"$TID"` key whose newest entry points to the report written in step 3 with a populated `max_verdict_confidence`
6. Verify: `.claude/council/index.json` was written via tmp+rename (no partial-read window — `index.json.tmp` is absent post-run)
7. Set `council.taskgate.min_confidence` below the run's `max_verdict_confidence`, invoke `task-completed.sh` with `CLAUDE_TASK_ID=$TID`, verify exit code 0
8. Set `council.taskgate.min_confidence` above the run's `max_verdict_confidence`, invoke `task-completed.sh` with `CLAUDE_TASK_ID=$TID`, verify exit code 2 and stderr naming the blocked task id
9. Invoke `task-completed.sh` with `CLAUDE_TASK_ID=unknown-task`, verify the index-miss path fails with a clear "no verdict exists" stderr message
10. Run `/council --diff` (findings shape) bound to a separate task id; verify the index row has `max_verdict_confidence: null` and non-null `max_finding_confidence`. With finding conf ≥ `council.taskgate.min_confidence`, `task-completed.sh` exits 0; with finding conf below threshold, exit 2. (Product orchestrated-task gate still scopes to claim/`verdict[]` by policy — orthogonal to dual-shape acceptance.)
11. Unset `--task-id` and rerun with `CLAUDE_TASK_ID=$TID` exported — verify the env fallback produces the same task-bound report path and index entry as step 3
12. Run plain `/council "<claim>"` with no flag and no env var — verify the report filename has no `--<task_id>` suffix and the index is not updated

### Test 10 — Blind Cross-Review ordering
1. Run `/council` with ≥ 3 investigators on a session containing a contested claim
2. Verify: cross-review prompts contain anonymized bundle labels (A/B/C) with no investigator identity present
3. Verify: each cross-reviewer's prompt omits their own bundle
4. Verify: label ordering differs between at least two reviewers' prompts (position-bias mitigation)
5. Verify: when bundles have unequal evidence quality, the Borda-ranked order in the report differs from submission order
6. Verify: Phase 4 Prosecution brief references bundles in Borda-ranked order
7. Run with exactly 2 investigators — verify Phase 2.5 is skipped and the report notes the bypass reason
8. Verify: any bundle in the bottom Borda quartile is labelled `WEAK_EVIDENCE` in the report

### Test 11 — Spawn-failure self-verified mode
1. Static: `skills/council/SKILL.md` and `commands/council.md` document spawn-failure degradation with marker `self-verified — refuters unavailable`
2. Run `engine.sh finalize` with fixtures and `--verification-mode self-verified` — report body contains the marker and frontmatter has `verification_mode: "self-verified"`
3. Run finalize without the flag (or with `full`) — report has no marker banner and `verification_mode: "full"`
4. Empty evidence still exits 5 when no self-verify path supplied usable bundles


### Test 12 — Council-on-Workflow opt-in default
1. With neither `--workflow` nor `COUNCIL_WORKFLOW=1` set, run `/council "<claim>"`
2. Verify the Workflow tool is never invoked and behavior matches today's engine.sh path

### Test 13 — Council-on-Workflow output parity
1. With opt-in set on a Workflow-capable install, run the same fixture claim set through both paths
2. Diff the verdict JSON, the `.claude/council/index.json` rows, and the report bodies (modulo timestamps/slug)
3. Verify no consumer-visible differences (strict parity)

### Test 14 — Council-on-Workflow transparent fallback
1. With opt-in set but Workflow unavailable (free plan, pre-Workflow CC, or `COUNCIL_WORKFLOW_FORCE_FALLBACK=1`)
2. Verify the run falls back to engine.sh with stderr notice `council: Workflow unavailable; falling back to engine.sh`
3. Verify successful non-degraded report (`verification_mode: full`) — no hard failure solely for missing Workflow

### Test 15 — Council-on-Workflow judge tool-less
1. Inspect `skills/council/workflow.js` judgment step
2. Verify it uses agentType `council-judge` (plugin-qualified) and `agents/council-judge.md` still has `tools: ""`
3. Verify a tool-call attempt by the Judge is blocked (Test 3 invariant holds on this path)

### Test 16 — Council-on-Workflow resume
1. Kill a Workflow-path tribunal mid-run and resume it
2. Verify the run continues from the last completed Workflow phase (not full restart from claim extraction)
3. Verify final artifacts still pass Test 13 parity (manual QA if CI cannot kill/resume)

### Test 17 — Council-on-Workflow spawn-failure degradation
1. Simulate an investigator/refuter spawn failure on the Workflow path
2. Verify the report and frontmatter carry exact marker `self-verified — refuters unavailable` via finalize `--verification-mode self-verified`
3. Verify no silent role omission; actor is the workflow driver/orchestrator, never implementer-of-subject

### Test 18 — Council-on-Workflow single-source prompts + args guard
1. Grep `skills/council/workflow.js` — verify it loads `prompts/*` and `flavors/*` at runtime with no forked prompt bodies
2. Verify args-as-JSON-string guard (`typeof args === 'string'`) is present
3. Verify marker string `self-verified — refuters unavailable` is NOT present in workflow.js (only via finalize flag)

### Test 19 — Council-on-Workflow no repair layers + token summary
1. Grep workflow.js for `PYREPAIR` / `repair_json` — expect zero hits
2. When Workflow budget API / Task envelope tokens are available, verify per-run (ideally per-phase) token usage appears in stdout summary via finalize `--tokens-file` (`Tokens:` block; optional FM `tokens_total` / `tokens_by_phase`)
3. When tokens file is missing, `source: unavailable`, or all null/≤0 — omit Tokens block and FM keys (exit 0; never invent `0` as real); partial phases print known rows under `Tokens (partial):`

### Test 20 — Plan-file scope (`--plan <path>`, CDV-208)
1. Static: `bash skills/council/engine.sh preflight --scope plan --scope-arg /nonexistent.md` exits **2** (not 3) with stderr naming the path
2. Static: preflight `--scope plan --scope-arg skills/council/fixtures/plan-scope-sample.md` exits **0**; JSON has `scope=plan`, `preset=generic`, `phases.1_claim_extraction.skip=false`, `phases.1_claim_extraction.prompt` ending in `plan-extractor.md`
3. Static: `skills/council/prompts/plan-extractor.md` exists; documents locator format `file:heading-path:line` and claim schema `{claim, source_locator, claim_type}`
4. Static: fixture `skills/council/fixtures/plan-scope-sample.md` contains one true claim (SQLite memory path) and one fabricated claim (Rust council crate)
5. Live (optional): `/council --plan skills/council/fixtures/plan-scope-sample.md` extracts ≥1 claim; investigators produce bundles; pipeline completes with verdicts

### Test 21 — From-retro scope (`--from-retro <anchor-id>`, CDV-212)
1. Static: preflight `--scope from-retro --scope-arg missing-id` exits **2** with stderr naming missing anchor path under `$MROOT/.claude/retro/anchors/`
2. Static: stage fixture `skills/council/fixtures/from-retro-anchor.json` to `$MROOT/.claude/retro/anchors/<anchor_id>.json`; preflight exits **0**; JSON has `scope=from-retro`, `preset=generic`, `phases.1_claim_extraction.skip=true`, `resolved_claim` matching fixture `fabricated_claim_text`, `scope_arg` = anchor id
3. Static: `/retro` single-writer contract — `commands/retro.md` persists anchors after validation; subagent emits JSON only
4. Live (optional): `/council --from-retro <id>` skips Phase 1 and runs Phase 2–5 against the isolated claim

### Test 22 — Blind-review scope (`--blind`, CDT-46-C3)
1. Static: `commands/council.md` documents `--blind` as a scope flag mutually exclusive with `"<claim>"|--session|--diff|--plan|--from-retro`, with parity flags `--teams|--lenses|--target`; no `--no-council` flag appears in council or blind-review surfaces
2. Static: `commands/council --blind.md` is a DEPRECATED stub pointing at `/council --blind` (listed in Covers)
3. Static: SPEC-013 Blind-review path requires Tier-1 clusters emit as findings with **no** recursive `/council` invocation; grep of the `--blind` engine path shows zero self-calls to `/council` or a second tribunal pipeline for reverse validation
4. Static: combining `--blind` with another scope flag, or supplying `--teams`/`--lenses`/`--target` without `--blind`, fails loudly
5. Live (optional): `/council --blind --teams 2 --lenses security --target skills/council/` spawns unconstrained + lens reviewers in one wave, produces a tiered report under `.claude/council/`, and does not spawn a nested tribunal run

---

## Validation

- [ ] `skills/council/` skill exists with engine protocol documented
- [ ] `commands/council.md` exists as a thin wrapper calling the engine
- [ ] `skills/review-and-commit/SKILL.md` refactored to call the engine with `preset: diff-mode` (SPEC-010 updated via `/spec update`)
- [ ] `skills/council/flavors/` directory contains: paranoid-ic, jaded-senior, yolo-ic, plus the 5 review-and-commit specialists
- [ ] `agents/council-judge.md` exists with `tools: ""` and judges evidence-only (no self-loaded cortex/memory; any `tech-lead` cortex calibration is optional engine-prepended context, not a required load path); engine invokes `council-judge` (not `tech-lead`) for Phase 5
- [ ] Verdict taxonomy enforced structurally (not free-form)
- [ ] Feedback memory auto-write verified on `FABRICATED ≥70` and `UNVERIFIED ≥85`
- [ ] `.claude/council/` directory added to `.gitignore` conventions
- [ ] SPEC-012 updated with `/retro` → `/council` integration hint
- [ ] SPEC-009 updated with `requires_council: true` TaskCompleted gate flag
- [ ] SPEC-010 updated to reflect `/review-and-commit` delegation to council engine
- [ ] Settings keys `council.feedback.fabricated_min` and `council.feedback.unverified_min` documented in `/memory config` or equivalent
- [ ] `.claude/council/index.json` exists after any task-bound run and is written atomically (tmp + rename)
- [ ] `task_id` field appears in report frontmatter and `--<task_id>` suffix appears in filename when a run is task-bound
- [ ] `CLAUDE_TASK_ID` env var fallback produces the same binding as the `--task-id` flag
- [ ] TaskCompleted gate queries `index.json` only (no filename scans) and applies the dual-shape confidence rule (SPEC-002 / CDT-122)
- [ ] `skills/council/prompts/cross-reviewer.md` exists; council.md Phase 2.5 block describes N cross-reviewers spawned with per-reviewer shuffled labels, self-exclusion, Borda-ranked bundle output to Phase 4 and Phase 5, bottom-quartile WEAK_EVIDENCE flagging, and bypass recorded when < 3 investigators
- [ ] Spawn-failure degradation: `engine.sh finalize --verification-mode self-verified` writes marker `self-verified — refuters unavailable` + frontmatter `verification_mode`; default/full omits banner; protocol in SKILL.md + commands
- [ ] `--why` (CDV-206): preflight with `--why` emits `why: true` + `why_detail` (`preset`, `flavors`, `phase3_specialist`, `claim_budget`, `preset_source`); without flag `why` is not true and no debug section; `commands/council.md` Step 5 prints short labeled block after summary; no verdict impact, no raw prompt dumps
- [ ] Phase 3 domain specialist (CDV-209): `phases.3_domain_specialist.deferred==false`; `topic-classifier.md` present; council.md classifies → pull devops/ds/qa/pm at conf ≥ 0.75, cap 1/run, skip weak match + diff-mode; before Phase 2.5; `why_detail.phase3_specialist` runtime strings; Test 8
- [ ] Token usage (CDV-204): finalize `--tokens-file` prints `Tokens:` (or `Tokens (partial):`) when usable; omits when missing/unavailable/zeros; optional FM `tokens_total`/`tokens_by_phase`; `commands/council.md` best-effort collect + pass-through; index.json unchanged
- [x] Plan scope (CDV-208): `--plan <path>` preflight path-check exit 2 / live exit 0; `plan-extractor.md` + fixture; Test 20
- [x] From-retro scope (CDV-212): anchor files at `$MROOT/.claude/retro/anchors/<id>.json`; missing → exit 2; present → Phase 1 skip + `resolved_claim`; exit 3 deferred removed; Test 21
- [ ] Council tiering (CDT-126): `council_tier ∈ skip|light|full` with `skip` never auto-selected (DRI flag only) and **per-surface** legal vocabularies stated explicitly — `/orchestrate` accepts all three (`skip` short-circuits: no `/council`, no engine run, no report), `/council` and `engine.sh` accept only `light|full` and MUST hard-fail on `skip` rather than coerce it, and the `index.json` row is the one surface carrying all three (a `skip` row written by the short-circuiting caller through the same owning writer, empty `report_path`, null confidences); `light` = exactly 2 distinct-flavor investigators + Phase 5 Judge, Phase 3/Phase 4 skipped; Phase 4 spawn MUST scoped to runs in which Phase 4 runs, Phase 5 brief inputs and Phase 6 report briefs Phase-4-conditional (no synthesized/stubbed briefs), Phase 2.5 bypass targets the next phase that runs; `full` behaviorally unchanged (same phases/flavors/prompts/stdout — *not* byte-identical artifacts: frontmatter + index rows gain the two additive keys on every run, ungraded `full` recording a default `grading_reason`); `verification_mode` still a two-value enum (not folded); bands + 5 structural critical-area signals with the fan-in probe running in both the clear-low (cap 5) and middle (cap 20) bands; grading fails closed to `full` with the failure in `grading_reason`; `council_tier`/`grading_reason` in report frontmatter and `index.json` rows; Workflow path `full`-only via existing fallback seam
- [ ] Blind-review scope (CDT-46-C3): `/council --blind` as mutually exclusive scope; parity `--teams|--lenses|--target`; N unconstrained + M lens parallel fan-out → semantic clustering → Tier 1/2/3; Tier-1 emit as findings with **no** recursive `/council`; `--no-council` removed; `commands/council --blind.md` DEPRECATED stub in Covers; Test 22
- [ ] Test 1–11 pass against the implementation
- [x] Proposed extension 'Council-on-Workflow execution path' implemented and promoted (CDV-196; Tests 12–19)
- [ ] Test 12–19 (Council-on-Workflow) pass against the implementation
- [ ] Test 20 (plan scope) pass against the implementation
- [ ] Test 21 (from-retro scope) pass against the implementation
- [ ] Test 22 (blind-review scope) pass against the implementation

---

## Version History

| Date | Change |
|------|--------|
| 2026-08-07 | CDT-183: Align TaskCompleted gate contract with dual-shape CDT-122 (SPEC-002 SoT + live hook). Council tiering: task gate claim scope is **policy**, not structural impossibility of finding conf; drop "can never accept / deadlock forever". CDT-122 cross-ref marked **resolved**. Phase 6 / Task-ID Plumbing: hook accepts either confidence shape (algorithm deferred to SPEC-002). Scope Exclusions: remove "MUST NOT gate on finding[]" / verdict[]-only; dual-shape + claim policy + blind still gate-ignored. Blind-path: gate-ignored via unbound / no qualifying index row (not "same as ignoring finding[]"). Validation checkbox updated. Historical Version History rows left intact. Status stays ACTIVE. |
| 2026-07-21 | CDT-46-C3 (SPEC-013): `/council --blind` scope absorbs former `/blind-review` engine — N unconstrained + M lens-differentiated reviewers (parallel), semantic clustering, confidence tiers (Tier 1 cross-cohort ≥2 / Tier 2 same-cohort ≥2 / Tier 3 single-team); Tier-1 consensus clusters emit directly as council findings (reverse-validation self-call removed; no `--no-council`); parity flags `--teams|--lenses|--target`; scope mutually exclusive with `"<claim>"|--session|--diff|--plan|--from-retro`; `--workflow` does not apply; Covers adds `commands/blind-review.md` DEPRECATED stub; Test 22. Status stays ACTIVE. |
| 2026-07-14 | CDV-209: Phase 3 dynamic domain specialist live — topic-classifier.md; engine `3_domain_specialist.deferred=false` (skip finding[]/diff-mode); classify → at most one of devops/ds/qa/pm when confidence ≥ 0.75; before Phase 2.5; why_detail runtime specialist strings; Test 8 active. |
| 2026-07-14 | CDV-212: `/council --from-retro <anchor-id>` live — preflight loads `$MROOT/.claude/retro/anchors/<id>.json` (exit 2 if missing); preset `generic`; Phase 1 skip; `resolved_claim` in investigation plan; `/retro` single-writer after validation; exit 3 deferred residual removed. Test 21. |
| 2026-07-14 | CDV-208: `/council --plan <path>` live — preflight requires readable path (exit 2 if missing, not exit 3); preset `generic`; Phase 1 via `skills/council/prompts/plan-extractor.md` with locator `file:heading-path:line`; fixture `skills/council/fixtures/plan-scope-sample.md`; `--from-retro` remains deferred exit 3 until CDV-212. Test 20. |
| 2026-04-09 | Initial spec created from brainstorm `.claude/plans/2026-04-09-brainstorm-council.md` |
| 2026-04-09 | Taxonomy resolution: added Output Shapes section declaring `verdict[]` and `finding[]` as first-class engine outputs; Phase 1 enriches diff-mode input with applicable-specs bundle; Phase 5 Judge emits the shape declared by the preset (empty tool allowlist unchanged); Phase 6 report template branches on shape; Phase 7 feedback memory scoped to `verdict[]` only; findings require `tool_use_id` citations; confidence unified as 0–100 with per-shape thresholds. |
| 2026-04-09 | Task binding closure: Phase 6 adds a verdict index at `.claude/council/index.json` (atomic tmp+rename writes) as the single source of truth for the SPEC-002 TaskCompleted gate; reports gain a `task_id` frontmatter field and `--<task_id>` filename suffix when task-bound; `/council` accepts `--task-id` with a `CLAUDE_TASK_ID` env fallback; the gate is scoped to `verdict[]`-shape rows only (findings-shape runs excluded); Test 9 and validation checkboxes added for the new plumbing. |
| 2026-04-09 | Path drift fix: corrected engine path from `skills/dev-team:council/` to `skills/council/` (the `dev-team:` prefix is invocation-time namespace, not filesystem); corrected refactor target from `commands/review-and-commit.md` to `skills/review-and-commit/SKILL.md` (review-and-commit is skill-only, no command shim exists). No behavioral change. |
| 2026-04-09 | Judge agent split: Phase 5 now routes judgment to a dedicated `council-judge` agent at `agents/council-judge.md` (inherits `tech-lead`'s cortex/memory/directives load path, declares empty tool allowlist in frontmatter) instead of reusing the `tech-lead` agent directly — no per-invocation tool-allowlist override mechanism exists, so the empty allowlist invariant is enforced structurally via a distinct agent file. Overview and validation checkbox updated accordingly. |
| 2026-04-09 | Task-ID path separation (post-Task-1 spike): clarified in Task-ID Plumbing that the `/council` command fallback chain (`--task-id` → `CLAUDE_TASK_ID` → unbound) governs direct command invocations only; the SPEC-002 TaskCompleted hook resolves its task id from stdin JSON (primary) per the verified Claude Code contract and does NOT share this fallback chain. Prevents the hook IC from reusing command-side plumbing. No change to the command path itself. |
| 2026-04-26 | Clarified "no entries in agents/" MUST NOT: scoped to Prosecutor/Investigator/DA/Specialist only; `council-judge` is explicitly excluded because its empty-tool-allowlist invariant requires a persistent agent file. |
| 2026-04-28 | Phase 3 deferral formalised: added blockquote deferral notice to Phase 3 section marking COUNCIL-002 as the delivery milestone; status promoted to ACTIVE; closes spec-code compliance gap flagged in v0.25.2 plugin review. |
| 2026-04-29 | Added Phase 2.5 — Blind Cross-Review (COUNCIL-002): anonymized peer-review round between Phase 2 and Phase 4, Borda-count aggregation of investigator rankings, self-exclusion, position-bias mitigation via per-reviewer label shuffling, WEAK_EVIDENCE flagging for bottom-quartile bundles, bypass when fewer than 3 investigators. Inspired by Karpathy's llm-council anonymized peer-review pattern. Added Test 10. Purely additive — no existing phase behavior changes. |
| 2026-06-14 | v0.34.0 (AUDIT-P1-4A): added Engine Architecture MUST naming each `skills/council/prompts/*` file's own `## Variables` table as the authoritative `{{TEMPLATE_VARIABLE}}` contract, with `commands/council.md` substitution blocks and `skills/council/SKILL.md`'s documented-variables table required to name exactly those variables — no dead substitutions, no unsubstituted placeholders leaking into spawned subagents. Fixes the 3-way contract disagreement (council.md named 3 variables absent from the prompt bodies). Contract MUST only; verdict/finding/evidence schema and taxonomy unchanged. |
| 2026-06-14 | v0.35.0 (AUDIT-P1-4C-1): merged the Phase-4 `prompts/prosecutor.md` + `prompts/advocate.md` templates into one role-parameterized `prompts/phase4-brief.md` (vars: `{{ROLE}}`, `{{ROLE_BIAS}}`, `{{EVIDENCE_FIELD}}`, `{{EVIDENCE_BUNDLES}}`, `{{FLAVOR_DELTA}}`). Made the Phase-4 claim-blindness invariant explicit (line 91): both roles are BLIND to the original claim list and group evidence by the `claim_id` carried inside the bundles — fixes the v0.34.0-class literal leak where the prompt bodies declared/used `{{ORIGINAL_CLAIMS}}` that council.md never substituted, leaking the literal placeholder into the spawned subagent. Judge (Phase 5) still receives original claims — unchanged. Brief output schema (`evidence_against`/`evidence_for` + `struck_lines`) preserved byte-for-byte. |
| 2026-06-15 | Editorial hygiene (AUDIT-P3.5b): Status `✅ ACTIVE`→`ACTIVE` (no emoji); reordered Version-History rows ascending by date (two stray 2026-04-09 rows were sitting after 04-26/04-28). Row content preserved verbatim. No behavioral change. |
| 2026-06-15 | Judge cortex-inheritance reconciled to reality (AUDIT-P4.4): no cortex/memory injection is implemented in `commands/council.md` Phase-5 spawn or `engine.sh`, and the evidence-only Judge (`tools: ""`) cannot run a recall/cortex-load path itself. Relaxed the Phase-5 cortex MUST (line 97) from "MUST inherit `tech-lead`'s cortex/memory/directives load path" to OPTIONAL engine-prepended calibration the Judge MUST function without; updated the Overview line and the validation checkbox accordingly so neither asserts an unimplemented load path. The Judge's authority is the evidence bundle plus its standing behavioral rules. Aligned `agents/council-judge.md` (removed the impossible "Read SPEC-013" checklist step and the false "cortex injected by the council engine" assertion) and trimmed duplicated reasoning in `skills/council/prompts/judge.md`. No engine/spawn behavior change — docs now match the shipped evidence-only design. |
| 2026-07-14 | CDV-196: Council-on-Workflow execution path promoted from DRAFT to active MUSTs — opt-in `--workflow`/`COUNCIL_WORKFLOW=1`, capability probe + transparent fallback, `skills/council/workflow.js` schema-forced agent() steps, shared `engine.sh finalize`, no PYREPAIR on Workflow path, CDV-199 marker via finalize flag only, single-source prompts/flavors, args-as-JSON-string guard (shared with CDV-197). Tests 12–19. |
| 2026-07-14 | CDV-199: Spawn-failure degradation MUST — on unusable investigator/specialist/prosecutor/advocate/judge Task spawn, orchestrator self-verifies with tools; finalize `--verification-mode self-verified` surfaces exact marker `self-verified — refuters unavailable` in report body + frontmatter; exit 5 only when evidence still empty after self-verify path; no local-agent investigator routing. Test 11 + validation checkbox. |
| 2026-07-14 | CDV-203: Report templates own YAML frontmatter (`task_id: "{{TASK_ID}}"` + scope/preset/output_shape/created_at/verification_mode); finalize substitutes template FM as single source (no dual prepend) and strips empty `task_id` when unbound so the key is absent — not null, not `""`. |
| 2026-07-14 | CDV-204: Per-phase token usage reporting (SHOULD) — finalize optional `--tokens-file` (phase→int map + source); stdout `Tokens:` / `Tokens (partial):` block; optional report FM `tokens_total` / `tokens_by_phase`; graceful omit when missing/unavailable/zeros (never invent measured `0`); Task path best-effort envelope scrape in `commands/council.md`; does not alter `index.json`. Test 19 aligned. |
| 2026-07-14 | CDV-211: Investigator tool-call caching within a run (SHOULD) — preflight creates `${TMPDIR:-/tmp}/council-cache-<run_id>/` (`reads/`, `greps/`, `manifest.json`), emits `cache_dir` + `run_id` on plan; investigator.md cache-first via `{{CACHE_DIR}}`; optional orchestrator seed from claim locators; finalize best-effort rm; empty cache correctness-neutral. |
| 2026-07-22 | CDT-53 reflect: cross-ref `/debug ticket` (former `/fix-ticket`). Status stays ACTIVE. |
| 2026-08-05 | CDT-126: added **Council tiering** — `council_tier ∈ skip \| light \| full` selected immediately before a gated call at the two gated sites (task gate, SPEC-033 M14 ship gate); `skip` never auto-selected (explicit DRI `--council-tier=` flag only, and not the forbidden `--no-council` token). The flag's legal vocabulary is stated **per surface** rather than as one flat list, because it genuinely differs: `/orchestrate --council-tier=` takes `skip\|light\|full` and resolves `skip` by short-circuiting (no `/council` invocation, no engine run, no report); `/council --council-tier=` and `engine.sh --tier` take **only** `light\|full` and MUST hard-fail loudly on `skip` rather than coerce it — a coerced `skip` would run a council the DRI explicitly declined. `skip` is a resolution the *caller* performs, never an instruction the engine executes. The `index.json` row is the single surface carrying all three values, since a `skip` row (empty `report_path`, null confidences, `grading_reason` naming the DRI decision) is written by the short-circuiting caller through that same one owning writer; `full` is **behaviorally** unchanged — same phases, flavor sets, prompts, investigator/Judge behavior and stdout — but deliberately **not** byte-identical in its serialized artifacts, since report frontmatter and the `index.json` row gain the two additive `council_tier`/`grading_reason` keys on *every* run including `full` (an ungraded `full` records a `grading_reason` naming it as the default, keeping a defaulted `full` distinguishable from a graded one); `light` = exactly 2 distinct-flavor investigators + Phase 5 Judge with Phase 3 and Phase 4 skipped — 2 satisfies Phase 2's ≥2-distinct-flavor MUST verbatim and stays under Phase 2.5's <3 skip trigger, so **no** Phase-2/2.5 MUST is rescoped; light flavor subsets per preset (`generic` unchanged; `diff-mode` → `logic`+`security`). Skipping Phase 4 **did** require scoping — done in place, not restated: Phase 4's "exactly one Prosecutor and one Devil's Advocate" is now scoped to runs in which Phase 4 runs (with a preamble stating the `finding[]`-shape and `light` skips — the diff-mode skip was previously implementation-only in `engine.sh` preflight + `review-and-commit/SKILL.md` and is now contract-level, a free drift cleanup); Phase 5's Judge inputs make the Prosecutor/Devil's-Advocate **briefs Phase-4-conditional** (at `light` the Judge gets claims + bundles only; synthesizing or stubbing an absent brief is forbidden); Phase 6's report-contents requirement makes the same two briefs conditional (skip + reason recorded in their place, never an empty brief section); Phase 2.5's bypass now proceeds to *the next phase that runs* — Phase 5 when Phase 4 is itself skipped — instead of an unconditional "directly to Phase 4". `council_tier` declared **orthogonal** to `verification_mode`, which stays a strict two-value enum (a degraded light run is both `light` and `self-verified` — a widened enum could not express it, and SPEC-033 M14(d) therefore needs no change); **automatic** grading is scoped to exactly one call site — the M14 autopilot ship gate (merge-base diff); the orchestrated task gate runs **claim scope** (not `--diff`, which is `finding[]`-shape and would deadlock `requires_council` forever on a null `max_verdict_confidence`) and takes its tier from the explicit `--council-tier` override, defaulting to `full`; manual `/council` at any scope, `--diff` included, runs `full` unless given that override. Grading bands (`files`/`loc` clear-low → light, clear-high → full, ambiguous middle → one triage call) plus 5 structural critical-area signals (no literal path list), with the costly fan-in probe (signal 3) MUST-run in **both** the clear-low band (cap 5 files — the band is `files ≤ 5` by definition) and the ambiguous-middle band (cap 20), since clear-low's own "no critical-area signal" clause cannot hold if the signal was never evaluated; fail-closed to `full` on every grading failure with the reason recorded, deliberately inverting SPEC-026 M9's fail-open precedent; `council_tier` + `grading_reason` added to report frontmatter and the `index.json` row (SPEC-013's file per SPEC-026 M10 — `task-store.sh` deliberately not extended); Council-on-Workflow path is `full`-only via the existing transparent-fallback seam, under its own distinct stderr notice (`council_tier=light unsupported on the Workflow path`) — reusing CDV-196's "Workflow unavailable" string would be false, since the tool is available and only the tier is unsupported; cross-reference recording that **CDT-122 is neither fixed nor worsened** by tiering. Status stays ACTIVE. |
