# SPEC-025: /epic — Umbrella Decomposition & Sequenced Orchestration

**Status**: ACTIVE
**Category**: core
**Created**: 2026-07-03

---

## Overview

Umbrella tickets ("build feature X across N surfaces") have no first-class path today: `/kickoff` and `/orchestrate` assume one ticket-sized unit of work, so users decompose epics by hand, lose the cross-ticket dependency picture, and re-derive sequencing every session. `/epic <EPIC-ID> "<epic text>"` closes that gap: PM and Tech Lead jointly decompose the epic into child tickets — each carrying a problem statement, acceptance criteria, size estimate, and recommended agent — and the Tech Lead adds a cross-ticket dependency DAG whose topological levels form execution **waves**. Approved children are persisted per SPEC-009 dual-write rules (Linear preferred when MCP is available; local backlog write-through always; MCP-down fail-open to local only). When Linear is reachable, `/epic` also best-effort creates or links **one Linear Project per epic** (name = epic title), attaches dual-written children to it, and records `linear_project_id` in state — without blocking the local path on project failure (CDT-64 / F10). A durable epic state file under `.claude/epics/` makes multi-day epics resumable and visible to `/standup`.

Execution mode walks the DAG: each ready child (all dependencies completed) is handed off to the existing single-ticket pipeline — `/kickoff` for plan-only, `/orchestrate` for full lifecycle. `/epic` is a **composition layer**: it sequences and hands off; it never re-implements the ticket lifecycle beneath it. The standing lesson from umbrella orchestrations — *PM kickoff is mandatory for every child ticket; skipping PM for "obvious" tickets misses false premises* (session fc046db3; `skills/orchestrate/SKILL.md` "PM kickoff is mandatory for every ticket") — is promoted to a MUST here.

**Context discipline (CDT-127):** Multi-child Mode B MUST NOT grow live context with the full history of every prior child's plan/review/QA/TL. Primary mechanism is **per-child session isolation** (hard context cut between children) with an epic seed built as a **SPEC-018 STM-shaped packet** (mechanical strict subset from `state.json` is the MVP path). A secondary **between-children context guardrail** warns and forces the same boundary when estimated context crosses a threshold. Mid-child spikes, council tiering (CDT-126), concurrent waves, and wall-clock/stint budgets (SPEC-033 OQ2) are out of scope.

**Boundaries & related specs (conflict scan, 2026-07-03; CDT-127 addendum 2026-08-06):**
- **SPEC-009 (ticket workflow)** owns the single-ticket lifecycle end to end — brainstorm, kickoff, orchestrate gates, LOC caps, escalation rules, wrap-ticket, and the backlog file format (`.claude/backlog.md` index + `.claude/backlog/<slug>.md` items). `/epic` COMPOSES that lifecycle — one full SPEC-009 pass per child — and MUST NOT fork or re-implement any of it. Children are persisted through SPEC-009's backlog conventions; per-child gates (>4-open-questions pause, 2-attempt escalation, LOC caps) apply unchanged inside each child's run.
- **SPEC-017 (task DAG)** owns WITHIN-ticket DAGs: the `.claude/tasks/` store schema, the `depends_on` field semantics, `dag-lib.sh` primitives, and standup READY computation for tasks. The epic DAG is ACROSS tickets and lives in a separate store (`.claude/epics/<EPIC-ID>/state.json`). This spec MUST reuse `dag-lib.sh` conventions where sane — the store-independent `check-cycle` subcommand is invoked literally; `depends_on` naming and ready-set semantics (ready ⟺ every dependency `completed`) are mirrored — and MUST NOT write epic children into `.claude/tasks/` or extend the SPEC-017 task-store schema.
- **SPEC-003 (agent roles)** owns role boundaries and model tiers: PM owns the what/why per child (problem statements, acceptance criteria — never technical decisions); Tech Lead owns architecture, decomposition mechanics, estimates, and the dependency DAG. Decomposition spawns follow MC-4 (`Output mode: terse`). This spec adds no agent and modifies no agent definition.
- **SPEC-016 (worktree isolation)** owns worktree creation/teardown. Default: each child's own `/orchestrate`/`/kickoff` run via `worktree-lib.sh`. **CDT-141-C3 / M14:** when epic `worktree_enabled` and an integration path is set, children MUST reuse that single integration worktree (via `epic-lib ensure-ticket-worktree`) and MUST NOT open per-child trees. `/epic` itself MUST NOT create per-child worktrees or remove the integration tree on child wrap.
- **SPEC-018 (cold-session handoff)** owns STM packet shape (State now → Through-line → appendix), warm/cold/light mine paths, and PreCompact rescues. Epic between-child seeds MUST reuse that shape (or a documented strict subset assembled mechanically from `state.json`) — no parallel freeform "epic brief" format. Epic context discipline does **not** claim full harness `/compact` replacement (SPEC-018 M11d).
- **SPEC-033 (autopilot)** owns scope-confirm self-answer at A.5/B.3. Context boundary is **not** a new gate enum; under autopilot it is silent mechanical. Failures surface a decision card only when seed/handoff fails (fail-closed). Wall-clock/stint budget (SPEC-033 OQ2) remains deferred and distinct.

**Out of scope:** cross-epic dependencies; parallel (concurrent) orchestration of multiple children within a wave (default is sequential); automatic DAG re-planning on child failure; **webhook** Linear→local push (continuous sync); auto-add orphan Linear children into `state.json` without approve/`--redecompose`; Linear milestones/initiatives/project health updates; delete/archive of Linear projects; placing an epic parent/umbrella Linear issue on the project (children only); a Workflow-tool deterministic wave-walker (deferred — prompt-driven walker is the MVP); **within-child** context budgets during a single `/orchestrate` run; council tiering (CDT-126 — complementary cost control at council layer only); dollar savings SLAs; mid-child forced boundaries; replacing SPEC-018 packet format. **In scope (M15):** explicit `/epic sync` pull of status / null `linear_id` / null `linear_project_id` from Linear into existing state.

---

## MUST

- **M1 — Joint decomposition.** `/epic <EPIC-ID> "<epic text>"` in decompose mode MUST spawn PM and Tech Lead in parallel (both prompts carrying `Output mode: terse` per SPEC-003 MC-4). PM produces, per child: problem statement + acceptance criteria. Tech Lead produces, per child: size estimate (S/M/L) + recommended agent (per SPEC-009 tagging: ic4 for extending patterns, ic5 for novel work) + the cross-ticket `depends_on` list. Every child MUST carry all five fields before the approval gate; a child missing any field blocks approval.
- **M2 — Cross-ticket DAG with cycle gate.** The Tech Lead's `depends_on` lists reference child IDs only (no within-ticket task IDs). Before anything is persisted, the child list MUST be validated with the store-independent `skills/orchestrate/dag-lib.sh check-cycle` (input: JSON array of `{"task_id","depends_on"}` objects); on a detected cycle, `/epic` MUST halt with an error naming the back-edge and persist nothing. Waves are the topological levels of the acyclic DAG; a child is **ready** when every ID in its `depends_on` has `status=completed` — identical semantics to SPEC-017's ready-set.
- **M3 — Approval gate before persistence.** The full decomposition (children with all five fields, the DAG, and the wave plan) MUST be presented to the user for approval before any write occurs (no backlog file, no Linear issue, no Linear project, no state file). The user may edit, merge, or remove children at this gate; on decline, `/epic` exits with zero side effects — including zero Linear project create/link attempts.
- **M4 — Dual-write persistence (Linear preferred + local write-through).** On approval, each child MUST be persisted per SPEC-009 backlog dual-write rules: when the Linear MCP is available, create (or link) the Linear issue first and **always** write the local write-through (`.claude/backlog/<slug>.md` item + `.claude/backlog.md` index row) carrying the five M1 fields plus epic parent ID, `depends_on`, and Linear linkage; when MCP is down, write local only with a one-line notice. Child IDs MUST use the form `<EPIC-ID>-C<n>` (e.g. `CDV-30-C2`) — the `C` infix prevents collision with SPEC-017's within-ticket compound task keys (`<ISSUE-ID>-<task_id>`, e.g. `CDV-30-2`). Process trackers MUST NOT be committed to git (v1.0 invariant: `.claude` process state never upstream).

  **M4.1 — Link-before-create for child issues (no duplicate Linear children).** When MCP is up, **before any** child `save_issue` **create** on a new approved decompose (and for new/changed children under approved `--redecompose`), the session MUST inventory existing Linear issues under the epic parent:

  1. **Inventory:** `list_issues` with `parentId=<EPIC-ID>` (page until exhausted). Survivors = issues whose `statusType` is not `canceled` (include completed/done; exclude canceled). Inventory is **read-only** — does not require writing parent edges on new creates (parent-child *create* linking remains deferred; see Deferred).
  2. **Zero survivors → create path** (existing M4/M5 create + project attach + label).
  3. **≥1 survivor → adopt path:** session MUST **NOT** create a second set of child issues. Match each proposed local child to at most one survivor: (a) description embeds local `child_id` / `<EPIC-ID>-C<n>`; else (b) unique exact match on normalized title (lowercase; strip leading `[<EPIC-ID>]`, `E<n>:`, `C<n>:`, `<EPIC-ID>-C<n>` prefixes); else (c) if `|survivors| == |proposed|` and a collision-free case-insensitive unique title map exists, use it. On a **full unique map:** record each survivor's id as `linear_id`, best-effort project attach + `epic:<EPIC-ID>` label, local write-through + `add-child … --linear-id` — **zero** `save_issue` creates.
  4. **Ambiguous / partial map:** print exactly  
     `HALT: Linear already has N child issue(s) under <EPIC-ID> — adopt or confirm force-create; refusing duplicate create`  
     list survivors (id + title) and proposed children; **zero** Linear child creates. Human may then: adopt (supply map), force-create (explicit override only), or abort. **Autopilot:** full unique map → adopt silently; ambiguous → halt (`task_blocked`); MUST NOT force-create under autopilot.
  5. **Inventory failure:** treat as M5 fail-open (single notice line) and **skip Linear child creates** for this approve path (local write-through continues) — prefer missing Linear links over silent duplicates.
  6. **M9 alignment:** resume with existing `state.json` still forbids re-create; M4.1 closes the gap when local state is empty but Linear already has parented children (e.g. pre-seeded E1…En or a prior partial dual-write).
- **M5 — Linear preferred SoT when reachable; local IDs remain canonical keys.** When the Linear MCP is available, Linear issue state is preferred for open/closed status of dual-written children (reconcile/write paths per SPEC-009); `/epic` MUST record returned Linear identifiers in the epic state file. The local `<EPIC-ID>-C<n>` ID remains the **canonical orchestration key** in `state.json` and handoffs. When the MCP is absent or any Linear call fails (issue create/link, project create/link, or child-to-project attach), `/epic` MUST emit the single existing M5 one-line notice and continue on local write-through — it MUST NOT block, retry-loop, or fail the epic on Linear unavailability. Epic labels (e.g. `epic:<EPIC-ID>`) remain best-effort on child issues; a Linear Project MUST NOT replace labels.
- **M6 — Durable epic state file.** Epic state MUST live at `$MROOT/.claude/epics/<EPIC-ID>/state.json` ($MROOT resolved with the worktree-aware formula, so state is shared across worktrees), containing at minimum: epic ID, title, created timestamp, execution mode (`kickoff` | `orchestrate`), **`linear_project_id` (nullable string — Linear Project id when known, else `null`)**, and per child: ID, backlog slug, title, estimate, recommended agent, `depends_on`, `status` (`pending` | `in_progress` | `completed` | `blocked`), and `linear_id` (nullable). **CDT-169 — EPIC-ID charset:** `<EPIC-ID>` (and any user-supplied id joined under `.claude/epics/`, including `assert-release-allowed`) MUST match full-string `^[A-Za-z0-9_-]+$` (non-empty); reject with exit **64** and a stderr diagnostic naming invalid id + allowlist **before** any mkdir/write/read of that path (mirror SPEC-016 `validate_slug`). Writes MUST be atomic (write-to-tmp + rename, mirroring the SPEC-009 task-store discipline), and the file MUST be updated on every child status transition and when `linear_project_id` is first recorded. Concurrent mutations MUST be serialized with an exclusive `flock` on `$MROOT/.claude/epics/.lock` (create parent dir if needed; block until acquired). The lock MUST cover the full read-modify-write of `state.json` (read current bytes → apply mutation → tmp+rename publish). The lock MUST NOT be held across Linear MCP calls, `worktree-lib` / git worktree operations, or other non-state I/O. Readers MAY observe a stale but complete JSON snapshot without taking the lock. Implementation: `skills/epic/epic-lib.sh`. **CDT-127 (optional additive fields — status remains sole status SoT):** top-level `last_seed_path` (nullable string path to the latest between-child seed under `$MROOT/.claude/epics/<EPIC-ID>/seeds/` or `.claude/handoff/`); per-child `outcome_summary` (nullable string, ≤1 line, set on `completed` / useful on `blocked`). **CDT-141-C1 / M14 (optional additive):** top-level `worktree_enabled` (bool) and `release_bump` (`null` | `patch` | `minor` | `major`) — written on init when those modes are set; omitted on the default path. Readers MUST tolerate absence of these fields (legacy states; default `worktree_enabled=false`, `release_bump=null`). **CDT-141-C4:** optional `sealed` (bool, default false) — when true, mid-epic release forbid lifts (post-seal / C5); readers tolerate absence.
- **M7 — Execution walks the DAG by composition.** In execution mode, `/epic` MUST hand each ready child to the existing single-ticket pipeline — `/kickoff <child-id> "<child text>"` (plan-only) or `/orchestrate` (full lifecycle), chosen once per epic and recorded in state.json. It MUST NOT hand off a child whose `depends_on` contains any non-completed child. Children within a wave run sequentially by default. A child transitions to `completed` only when its own SPEC-009 lifecycle finishes (ticket wrapped / PR shipped) — never merely because its kickoff produced a plan. Under `--autopilot` (`AUTOPILOT_ON`), after a child leaves the active handoff (`completed`, or `blocked` with no mid-path successor) and `epic-lib ready-set` is non-empty, `/epic` MUST start the next child in the **same run** (B.6 if M13 applies → B.1 → B.2 → B.3 self-answer per SPEC-033 M5e → B.4) — MUST NOT require a new `/epic` invocation. The walker stops only on: B.3 human `n` or autopilot `halt`; empty ready-set; all children `completed` (then B.7 iff durable `release_bump` is set); only `blocked`/`in_progress` remain; M13 `context-discipline: seed failed — <reason>`; user interrupt. B.7 MUST NOT run while ready-set is non-empty. Autopilot MUST NOT self-answer B.5 kickoff-mode completion (SPEC-033 N8) and MUST NOT mark kickoff-mode children `completed` from `AUTOPILOT_ON` alone (A.6 default remains `orchestrate`).
- **M8 — PM kickoff is mandatory for every child.** Every child handoff MUST include the PM kickoff pass — no exceptions for "obvious" children, docs-only children, or children whose spec the Tech Lead authored during decomposition. PM validates acceptance criteria independently and regularly catches false premises that would break implementation (the fc046db3 lesson). The `/epic` handoff path MUST NOT expose any option that skips PM.
- **M9 — Resumable across sessions.** Re-invoking `/epic <EPIC-ID>` when `state.json` exists MUST resume: print the epic rollup (children by state) and continue at the next ready child — no re-decomposition and no duplicate backlog/Linear issue or Linear project writes (see M12 for project-id stability). Re-decomposition MUST require an explicit `--redecompose` flag plus user confirmation, and even then MUST NOT delete or alter the records of already-completed children. Resume MUST NOT auto-mutate status from Linear (use **M15** `/epic sync` when staleness is suspected); resume MAY print a one-line tip pointing at `/epic sync`.
- **M15 — Explicit Linear→local sync for existing state.** `/epic sync <EPIC-ID> [--dry-run]` MUST refresh an **existing** `state.json` from Linear when MCP is up, without re-decomposition or creating issues:

  1. **Requires state:** if no `state.json`, stop with a clear message (nothing to sync).
  2. **Session inventory:** `list_issues(parentId=<EPIC-ID>)` (M4.1 survivors); optional M12.2 project **link-only** when `linear_project_id` is null (MUST NOT create project on sync). Map children by `linear_id` first, else M4.1 title/`child_id` match. Map Linear `statusType` → local status: completed/done→`completed`, canceled→`blocked`, started→`in_progress`, else→`pending`.
  3. **Mechanical apply:** session writes a verdicts JSON file; `epic-lib.sh sync-apply` (no MCP) applies atomically: fill null `linear_id`; fill null `linear_project_id`; set status when changed **except** never downgrade `completed` → non-`completed`; optional `outcome_summary` on terminal statuses; report orphans (Linear without local child) and unmatched local (null id, no unique match) without auto-adding children.
  4. **`--dry-run`:** report planned actions with **zero** disk write.
  5. **MCP down / inventory fail:** emit M5 notice; **zero** state mutation.
  6. **Conflicts:** `linear_id` or project id mismatch → skip field, surface in report; do not overwrite.
  7. **M11:** sync MUST NOT spawn ICs, create worktrees, hand off children, or create Linear issues.
  8. **Illegal with M14 flags:** `--worktree` / `--release` with `sync` → exit 64, zero side effects (same class as `status`/`complete`).
- **M10 — Standup rollup.** While any epic with non-completed children exists under `.claude/epics/`, `/standup` MUST surface an epic rollup section: per epic, child counts by state plus the currently-ready children — computed from `state.json`, not from prose (mirroring SPEC-017's store-not-prose READY discipline).
- **M11 — Composition, not forking (MUST NOT).** `/epic` MUST NOT: write code or spawn IC agents directly; run its own review loops; re-implement kickoff/orchestrate internals; create or remove **per-child** worktrees; or store epic children in SPEC-017's `.claude/tasks/` store. The epic layer ends at decomposition, sequencing, handoff, and state tracking — everything below is owned by SPEC-009/SPEC-016/SPEC-017. **M14 carve-out (CDT-141):** when `worktree_enabled`, `/epic` MAY ensure/route **one** integration worktree (`epic-<EPIC-ID>`) and MAY compose end-of-epic seal (squash-stage + one `/release`); it MUST NOT re-implement the full orchestrate lifecycle, per-child WT create/teardown, or `/release` version/tag/push contract.
- **M12 — Linear Project per epic (best-effort; CDT-64 / F10).** On **approved** new decomposition (and on approved `--redecompose` when `linear_project_id` is still null), when the Linear MCP is available, `/epic` MUST create or link **exactly one** Linear Project associated with the epic **before or with** child dual-write, subject to fail-open (M5):
  1. **Name:** project name MUST equal the epic `title` field exactly (no `EPIC-ID` prefix, no fuzzy rename).
  2. **Link-before-create:** session MUST search Linear (e.g. `list_projects` query by title as a prefilter) and then **filter client-side for exact string equality** on project name (not substring/prefix). On ≥1 exact survivor, **link** the first and MUST NOT create a second project. If multiple exact-name survivors exist, link the first and emit a one-line multi-hit advisory; MUST NOT create. Pagination: when the list tool is capped, session MUST page until no further results or an exact match is found. Search and link MUST NOT be gated on team resolution — only project *create* requires a team.
  3. **Create:** only when no exact-name survivor exists. Before creating, session MUST **resolve the Linear team once** and use that same team for both `save_project` and every child `save_issue` in this approve path (resolved once, not per child). If team is unknown, fail-open (M5) — skip create only, leave `linear_project_id` null, and never invent a team; a project linked under M12.2 is unaffected.
  4. **Attach:** every dual-written child Linear issue MUST be attached to that project (e.g. `save_issue` with `project`). Attach failure for one child is fail-open for that child only (keep `linear_project_id`, continue remaining children).
  5. **Record:** returned project id MUST be stored as `state.json` `linear_project_id` (atomic write). Local child IDs remain canonical orchestration keys.
  6. **MCP down / project path failure:** no Linear project side effects required; local write-through proceeds; one M5 notice line (reuse — do not invent a second fail-open string).
  7. **Resume:** when `state.json` already has a non-null `linear_project_id`, resume MUST NOT create a second project and MUST NOT re-attach all existing children (no attach storm). Bare resume with `linear_project_id == null` MUST NOT create a project (only new approved decompose, or approved `--redecompose` when id is still null).
  8. **Redecompose:** new/changed children dual-written under `--redecompose` MUST attach to the existing project when `linear_project_id` is set; the id MUST remain stable. Completed children are never deleted/altered (M9).
  9. **Session ownership:** Linear MCP calls (list/create project, attach issues) are session-owned — bash engines (`epic-lib.sh`) MUST NOT call Linear MCP; they only persist ids the session supplies (same bridge pattern as SPEC-009 backlog).
  10. **OOS for this MUST:** epic parent/umbrella issue on the project; retrofill of pre-existing epics; milestones/initiatives; project health; delete/archive projects; Linear→local project sync.

- **M13 — Between-child context discipline (CDT-127).** Mode B MUST enforce a **hard context boundary** between sequential children so cost/context scales with the **current** child, not cumulative epic history.

  1. **When (default on).** Boundary applies in multi-child Mode B when the epic has **≥2 children** and the walker is about to start child **N+1** after child **N** has left the active handoff (completed, blocked-with-no-ready-successor path still OK to seed; never skip blocked deps — M7). **Single-child epics:** no mandatory boundary. Boundary is **between children only** (MVP) — not mid-`/orchestrate`. Debug opt-out: `--no-context-discipline` (or `EPIC_NO_CONTEXT_DISCIPLINE=1`) MUST be documented; default remains on.

  2. **Primary mechanism = A (per-child isolation / hard cut).** After child N's lifecycle step that returns control to the epic walker, and before B.3/B.4 for the next ready child, the walker MUST:
     - (a) Persist authoritative child status via `epic-lib` only (M6/M7 — **no dual status SoT**).
     - (b) **Build an epic seed packet** (see M13.3) and record `last_seed_path` when the optional field is implemented.
     - (c) **Hard-cut live context** so prior children's plan/review/QA/TL/council transcripts are **not** retained as live context for N+1. Allowed live inputs after the cut: compact epic seed + `state.json` rollup (`show`/`waves`/`ready-set`) + optional prior seed path. Protocol preference: new session / harness branch-fork seeded with `@<seed-path>` when available; **degrade** to same-session `/compact` (or equivalent) then load only `@seed` + state rollup when branch/new-session is unavailable. Continuing the Mode B loop **inline while still holding prior child transcripts as live context** is a MUST NOT when discipline is on.
     - (d) Resume next child only from seed + state (M9-correct: no re-decomposition, no duplicate tracking).

  3. **Seed shape (SPEC-018 reuse / strict subset).** Between-child seed MUST be an STM-shaped packet (headers in order: `## State now`, `## Through-line`, `## appendix` — SPEC-018 M4) or a documented **mechanical strict subset** of that shape. MVP production path: **deterministic assembly from `state.json`** (no requirement to spine-mine the whole multi-child transcript). Full `/handoff` warm mine MAY be used when available but MUST NOT be required for the boundary to succeed. Seed MUST include: epic id; wave/ready rollup from state; completed-child outcomes as **status + ≤1-line summary each**; next-child handoff payload (problem, ACs, estimate, agent, deps, execution mode); open epic-level blockers (`blocked` children + reasons if present). Seed MUST NOT include prior full review/council/QA transcripts or freeform parallel "epic brief" prose outside the STM shape. Packet files live under `$MROOT/.claude/epics/<EPIC-ID>/seeds/` (preferred) or project `.claude/handoff/` with epic id in the filename — process state, never committed.

  4. **Fail-closed.** If seed build or validation fails (empty, missing required sections, unreadable path), the walker MUST **not** start the next child. Emit a one-line halt (`context-discipline: seed failed — <reason>`) and leave next child `pending` (confirm-before-`in_progress` preserved — no `set-status in_progress` without a valid seed when a boundary is required). Autopilot: decision card only on this failure path; success path is silent mechanical (not a new SPEC-033 gate enum).

  5. **Secondary mechanism = C (guardrail).** Between children only, if estimated live context is **≥ ~400k tokens** or **≥ 50% of the model window** (document both; measurement may be dogfood/manual until free telemetry), the walker MUST **warn and force** the M13.2 boundary. Guardrail alone is insufficient as primary (warn-without-cut = fail). Mid-child guardrail = OOS.

  6. **Scaling target (AC2).** For an epic with ≥3 sequential children, peak per-turn context (or cache-read proxy) on child N MUST NOT grow linearly with N. Design target: child-N peak ≤ child-1 peak × (1+ε) with **ε = 0.5**. CI proves seed **shape** and protocol presence; AC2 peak metric is **dogfood/manual** until free token telemetry exists (document method + pass/fail in plan/skill measurement note).

  7. **Kickoff mode.** Boundary still applies between children; completion remains user/lifecycle attestation (`/epic complete` or resume confirm) — never auto-complete on plan alone (M7).

  8. **M11 preserved.** Boundary, seed assembly, and guardrail are epic composition concerns. They MUST NOT spawn IC agents, create worktrees, write `.claude/tasks/`, or re-implement `/kickoff`/`/orchestrate` internals. Prefer epic-owned seed CLI + existing handoff shape; do not fork orchestrate for the boundary.

  9. **Non-goals vs CDT-126.** Council `--tier light` reduces **council** cost inside a child; it does **not** replace M13 epic-walker context cuts. No shared implementation requirement.

- **M14 — Integration worktree + end-release CLI flags (CDT-141).** `/epic` MUST accept opt-in flags that record *intent* for an integration worktree and a single end-of-epic release. **C1** = parse + durable state. **C2** = ensure one `epic-<ID>` integration worktree when `worktree_enabled`. **C3** = every child `/kickoff`/`/orchestrate` MUST use that integration worktree only (`ensure-ticket-worktree` skips per-child `worktree-lib ensure`); B.4 handoff MUST carry path + no-per-child-WT instruction; `/wrap-ticket` for a child MUST NOT release the integration slug. **C4** = mid-epic `/release` + master-merge forbid while `release_bump` is set and seal is not done (`assert-release-allowed`; exit 64; message names release=end until seal). **C5** = end-of-epic seal after last child completed (`seal-ready` / `seal`): squash-stage integration onto master/main, exactly one `/release <release_bump>` with `EPIC_ALLOW_SEAL_RELEASE=1`, then `sealed=true`; failure leaves `sealed=false` and master clean. **C6** = resume reuses same integration tree/branch from state; flag-vs-state conflict policy (below). **C7** = SPEC + surface docs + regression bite-tests for the locked CLI (this section). **M11 still holds** with carve-outs only for ensure/route of the integration worktree and seal composition — no full orchestrate lifecycle reimplementation.

  #### M14 CLI table (public surface)

  | Flag | Form | Default (omit = today) |
  |------|------|------------------------|
  | `--worktree` | **boolean flag, no arg** | off → per-child worktrees off master (pre-M14) |
  | `--release` | `patch` \| `minor` \| `major` (space form canonical; `--release=<bump>` accepted alias) | omit → no epic seal; children release as today |

  #### M14 Semantics

  - `--worktree` present → create/use **one** integration worktree/branch for the epic. Path convention: `$MROOT/.worktrees/epic-<EPIC-ID>` (slug `epic-<EPIC-ID>`, branch `feat/epic-<EPIC-ID>` via worktree-lib). All children run in that tree. **Zero** per-child worktrees off master.
  - `--release <bump>` present → **release=end**: forbid mid-epic master merge and mid-epic `/release`; after last child completed, seal → squash-stage integration → **exactly one** `/release <bump>` (bump is the flag value; **no separate** `--bump`). Requires `--worktree`.
  - Both omitted → today's behavior (byte-identical defaults path).

  #### M14 Illegal combos (hard-fail exit **64**, zero side effects)

  - `--release <bump>` without `--worktree`
  - bare `--release` / empty bump / bump ∉ {patch,minor,major}
  - `--release each` or `--release end` (presence of `--release <bump>` *means* end; no mode enum)
  - `--worktree=<mode>` or `--worktree <mode>` (boolean only)
  - rejected aliases: `--bump`, `--land`, `--seal` (any form)
  - duplicate `--worktree` or `--release`
  - flags present on `status` | `complete` | `block` | `unblock`

  #### M14 Non-public API (MUST NOT document or accept as public surface)

  - `--bump` (folded into `--release <bump>`)
  - `--worktree epic|per-child` / any mode enum (boolean only)
  - `--release each|end` (presence of `--release <bump>` means end)
  - `--land`, `--seal` as public flag names (internal `epic-lib seal` / `seal-ready` subcommands are mechanical, not `/epic` flags)

  #### M14 Done when (1–7)

  1. **Master unchanged until seal** when `--release` is set (no epic delivery commits on master/main until seal succeeds).
  2. **Exactly one** versioned release commit for the epic (one `/release <release_bump>` at seal).
  3. **Zero per-child worktrees** when `--worktree` is set (shared integration tree only).
  4. Integration path uses **`epic-<EPIC-ID>`** convention under `.worktrees/`.
  5. **Resume** continues the same integration branch without pasting prior handoff strings.
  6. **Defaults** (flags omitted) byte-identical to pre-M14 behavior.
  7. Mid-epic `/release` or master merge under release=end → **halt exit 64**, no side effects.

  #### M14 Requirements (normative detail)

  1. **Flags (public surface).** As in the CLI table. Presence of bare `--worktree` → `worktree_enabled=true`; absence → `false`. Value forms MUST hard-fail. `--release <bump>` → `release_bump`; absence → `null`.
  2. **Coupling.** `--release` without `--worktree` MUST hard-fail. `--worktree` alone is legal (`release_bump=null`).
  3. **Hard-fail contract.** On any illegal combo or parse failure the invocation MUST exit **64**, emit a clear error on stderr, and perform **zero side effects** (no `state.json` write, no Linear/backlog mutation, no worktree ops). Covered failures: the illegal-combo list above.
  4. **Allowed paths only.** `--worktree` / `--release` are valid only on decompose, execute/resume, and `--redecompose` paths. Restricted subcommands in the illegal list MUST reject them.
  5. **Flag position.** Flags MAY appear anywhere among args after the command name. The epic id is the first non-flag positional.
  6. **Orthogonality.** `--autopilot[=<bump>]` remains independent (SPEC-033). Both flag families MAY coexist; neither parser owns the other. Own implementation: `skills/epic/parse-flags.sh` — MUST NOT extend `skills/autopilot/parse-flags.sh`.
  7. **Structured parse result.** The epic parser MUST emit a single JSON object: `{"worktree_enabled":bool,"release_bump":null|"patch"|"minor"|"major"}`.
  8. **State persistence (init).** On successful new decompose `init`, when either mode is set, `state.json` MUST record top-level `worktree_enabled` (bool) and `release_bump` (`null` | `patch` | `minor` | `major`). When both flags are omitted, those keys MUST NOT be required (legacy/default path stays byte-compatible; readers default missing → `false` / `null`).
  9. **Defaults = today.** With both flags omitted on a **new** decompose, `/epic` behavior MUST remain byte-identical to pre-M14 behavior (no integration tree, no end-release mode). Defaults-path resume (keys absent; flags omitted) MUST stay unchanged (`false` / `null`).
  10. **Resume modes (CDT-141-C6).** When `state.json` exists and the invocation is execute/resume (or re-invoke without `--redecompose` re-init):
      - **Flags omitted** (`--worktree` / `--release` absent from argv): effective modes MUST equal durable state (`worktree_enabled // false`, `release_bump // null`). MUST NOT clear a non-null `release_bump` (no silent downgrade of end-of-epic release intent).
      - **Flags present and equal to state:** proceed with those modes.
      - **Flags present and unequal to state:** MUST exit **64**, emit a clear error, and perform **zero side effects** (no mode rewrite, no second integration worktree).
      - With `worktree_enabled` true in state, resume MUST call `ensure-integration-worktree` and reuse the same `epic-<EPIC-ID>` path/branch recorded on state — no re-decomposition, no second integration worktree, no requirement to paste a prior handoff string for tree/branch continuity. `show` MUST surface `integration_path` when set.
  11. **MUST NOT (public surface).** Document or accept the non-public API list above. MUST NOT create worktrees solely because `--worktree` was *parsed* (ensure is a separate post-init step when mode is set). MUST NOT silently change stored M14 modes on resume.
  12. **Mid-epic release/merge forbid (C4 / CDT-141-C4).** When durable `release_bump` is non-null and `sealed` is not true, `epic-lib assert-release-allowed <ticket-or-epic>` MUST exit **64** with a user-visible message naming the epic and that it is in **release=end mode until seal (CDT-141)**. Callers MUST hard-fail with **zero** version bump/tag/push/version-file change and **zero** land onto master/main. Covered call sites: `/release` Step 0; `/orchestrate` Step 11 (autopilot `merge`, interactive squash, `--resume-ship`); `skills/autopilot/end-state.md` before squash. **Allowed** mid-epic: PR-stop and commits on the integration branch. When `release_bump` is null/absent, assert exits 0 (per-child release/merge unchanged). Guard MUST read durable state only (resume-safe). C5 seal path MAY set `EPIC_ALLOW_SEAL_RELEASE=1` or `sealed=true` to allow the end-of-epic `/release`. Optional additive state field: `sealed` (bool, default false; readers tolerate absence).
  13. **End-of-epic seal (C5 / CDT-141-C5 / CDT-170; amended WP 1-05).** When durable `release_bump` is non-null, after **all** children are `completed` and `sealed` is not true, Mode B MUST run the seal path **once**:
      - `epic-lib seal-ready <EPIC-ID>` reports readiness (`ready=true` only when `worktree_enabled`, non-null `release_bump`, all children completed, not sealed, integration branch present). Without `--release` (`release_bump` null/absent): `ready=false` / `seal` skips — **no** epic seal path.
      - `epic-lib seal <EPIC-ID>` squash-stages the integration branch onto master/main (**no** commit). Then the orchestrator invokes **exactly one** `/release <release_bump>` (bump from durable state) with `EPIC_ALLOW_SEAL_RELEASE=1`. `/release` remains the sole ship-of-record (version pair + one fold-commit + tag/push). On success: `seal --complete` sets `sealed=true` atomically.
      - **Seal excludes (WP 1-05):** the plugin state paths `.claude/epics/`, `.worktrees/` and `.wt-lock`. Every seal cleanliness check below passes these paths to `git-safety.sh is-clean` (M17) as excludes.
      - **Squash-stage dirty gate (WP 1-05):** before `git merge --squash`, seal MUST run `is-clean` (untracked paths included, seal excludes) on the main-repo checkout. On failure seal MUST exit **1** with a stderr message that names **dirty** and **refuse**, and MUST NOT squash. The untracked files, the dirty tracked files and HEAD stay unchanged. (The checkout of the default branch that runs before this gate is CDT-350, WP 1-09.)
      - **Seal manifest (WP 1-05):** after a successful `merge --squash`, seal MUST write the nullable state field `seal_stage: {base_sha, staged_tree, added_paths[]}` under `EPICS_LOCK` (M6 atomic write). `base_sha` is HEAD before the squash; `staged_tree` is `git write-tree` after it; `added_paths` lists the paths the squash added. The field is additive: readers MUST tolerate its absence. Seal MUST set it to `null` on `--complete`, on a successful hook run and on a successful `--abort`.
      - **Abort gate (CDT-170; amended WP 1-05):** the main-repo checkout is `SEAL_MAIN` (`$MROOT`, the checkout that owns master/main).
        - Bare `seal <EPIC-ID> --abort` MUST reset only when one of these is true: (a) `is-clean` passes (nothing to reset); or (b) `seal_stage` is non-null, `git write-tree` equals `seal_stage.staged_tree`, and there are no unstaged and no untracked paths outside the seal excludes (`is-clean --ignore-staged`). In case (b) it MUST run `git-safety.sh safe-reset --stage <base_sha> <staged_tree>`.
        - In every other case bare `--abort` MUST exit **1**, print a stderr message that names **dirty** and **refuse**, and change nothing: the working tree stays **byte-identical** and `sealed` stays **unchanged**. This MUST apply even when `already_sealed=true` — the gate MUST run **before** any reset.
        - On success bare `--abort` exits **0** and keeps the abort JSON shapes (`aborted` / `already_sealed`); it MUST NOT flip `sealed` to true.
        - `seal <EPIC-ID> --abort --force` MUST run `git stash push -m "epic-seal-<EPIC-ID>-<utc>"`, then `git reset --hard`, and print the stash ref on stderr. The named stash holds the tracked and staged edits; untracked files stay in place. If `git stash push` fails, `--force` MUST exit **1** and change nothing. `--force` is legal **only** with `--abort`; `--force` alone or with `--dry-run`/`--complete` MUST exit **64** (usage). Unknown flags still exit **64**.
        - After a `/release` gate failure, `/release` Step 3 has left unstaged version-pair edits on main, so bare `--abort` refuses (case (b) fails). The documented recovery is then `--abort --force` (stash then reset); nothing is lost.
        - **Same-invocation recovery (MUST):** on squash fail or release-hook fail, seal MUST call `git-safety.sh safe-reset --clean-at <base_sha>` (prior-clean attestation: the squash-stage dirty gate passed at `<base_sha>` just before the squash). The manifest form cannot run here: after a squash conflict the index holds unmerged entries, so `git write-tree` fails; and a release hook may edit the version pair, so no staged-tree fingerprint holds. If HEAD has moved (the hook committed), `safe-reset` refuses and seal exits **1** with no reset. `sealed` stays false; **no** partial release tag/push from the seal path. This recovery is **not** gated by the abort gate.
      - Re-invoke after `sealed=true` is a no-op (`already_sealed`) when clean. Mid-epic (incomplete children) MUST NOT seal (exit 64). Master MUST remain free of epic delivery commits until seal succeeds.
      - Tests MAY use `EPIC_SEAL_RELEASE_HOOK` as a stand-in for `/release` (no live tag/push required).
      - **MUST NOT:** wipe unrelated main WIP on any seal path (bare `--abort`, `--abort --force`, squash-fail or hook-fail recovery); run `git clean` anywhere in `skills/epic/epic-lib.sh`; accept `--force` except as companion to `--abort`; use exit **64** for a dirty refuse (that is exit **1**); recommend `--abort --force` as routine recovery (the handoff `on_failure` field names bare `--abort`; docs describe `--force` as "stash then reset").
  14. **Surface docs (C7).** `commands/epic.md`, `docs/commands/epic.md`, and `skills/epic/SKILL.md` MUST document both public flags, hard-fail rules, seal path, and M11 carve-outs. They MUST NOT advertise non-public names as flags.

- **M16 — Mid-epic release gap callout (CDT-158).** When `release_bump` is null/absent (per-child `/release` allowed), `epic-lib gap-callout <ticket-or-epic>` MUST print a **warn-only** stdout notice if any child **other than** the shipping ref has `status != completed`. Membership: `_find_parent_epic_for_ticket` (child `id` or `linear_id`) or epic `state.json` dir. Charset same as M6 / `assert-release-allowed` (`^[A-Za-z0-9_-]+$`; invalid → exit **64** before path join). Unknown / no epic → empty stdout, exit 0. Needles when triggered: `mid-epic ship`; `incomplete:` then one `id` + `title` per incomplete child; `includes:` one line (completed children + shipping child titles from state — shipping `in_progress`/`pending` counts as includes); `pending:` one line (incomplete excluding shipping, titles from state); `partial product:`. Titles from state only — no LLM prose. Incomplete children MUST NOT change exit (0). No confirm. All-complete or last remaining child → empty stdout, exit 0. C4 still exits **64** under `release_bump` set; MUST NOT mix this callout into that message. `/release` Step 0 MUST run `gap-callout` after `assert-release-allowed` rc 0 and print stdout as-is, before any version-file edit. Not a SPEC-033 gate. Land-no-release (`bump=master`) is out of scope. Autopilot inherits via `/release` Step 0 (`end-state.md` cites that step only — no duplicate helper).

- **M17 — Git safety primitive (WP 1-05; CDT-260, rv-w1-32).** `skills/lib/git-safety.sh` is the one shared primitive for git checks that gate a destructive step. Contract home: this spec (SPEC-009 § Backlog write integrity precedent for `skills/lib/portable.sh`). Consumers: M14 item 13 (seal), `skills/autopilot/end-state.md` §4 and §6.5 (SPEC-033 N3a). WP 1-06 consumers: `skills/worktree-lib.sh` `release`, `skills/wrap-ticket/prune-remote.sh` and the wrap-ticket legacy path (SPEC-016).
  1. **Invocation.** Subprocess CLI only: `bash git-safety.sh [-C <dir>] <subcommand> [args...]`. Callers resolve the path install-aware (`plugin-dir.sh`) or relative to their own script dir. `-C <dir>` runs every git call in `<dir>`; the default is the cwd. The script MUST unset `GIT_DIR` and `GIT_INDEX_FILE` only when `-C` is given.
  2. **Exit codes.** `0` = the predicate holds or the action completed; `1` = the predicate fails or the action refused (no change); `2` = a git error (callers MUST treat every exit ≠0 as "not safe"); `64` = usage. Diagnostics go to stderr only. Stdout is empty for every subcommand except `resolve-base` (item 9).
  3. **`is-clean [--tracked-only] [--ignore-staged] [-- <exclude-path>...]`.** Exit 0 only when `git status --porcelain` over the whole repo (`:/`) reports no staged, unstaged or untracked non-ignored path outside the excludes. Each `<exclude-path>` is a repo-root-relative path; the script wraps it as `:(top,exclude)<path>` (the `skills/release-train/train-lib.sh` preflight form). Untracked paths are listed per file (`--untracked-files=all`). `--tracked-only` ignores untracked paths. `--ignore-staged` ignores staged changes (index against HEAD) and still counts unstaged and untracked paths; seal abort case (b) uses it. Ignored paths never count.
  4. **`is-merged <ref> <base>`.** Layered and fail-closed. Exit 0 when: (L1) `git merge-base --is-ancestor <ref> <base>` holds; else (L2) `git cherry <base> <ref>` prints no `+` line; else (L3) a synthetic squash commit — `git commit-tree <ref>^{tree} -p $(git merge-base <base> <ref>)` with a fixed inline author and committer identity — has no `+` line in `git cherry <base> <synthetic>`. Every other case, including an unresolvable ref, no merge base and any git error, exits ≠0. L3 writes one loose object and no ref. It MUST NOT use `git merge-tree` (git ≥ 2.38, and a tree-equality test calls a reverted branch "merged").
  5. **`is-pushed <ref>`.** Exit 0 only when `refs/remotes/origin/HEAD` resolves and its target contains `<ref>`, or `<ref>` is a branch with an upstream that contains `<ref>`. No `origin`, no `origin/HEAD` and no upstream give exit 1. It never fetches.
  6. **`safe-delete-branch <branch> <base>`.** Runs `is-merged <branch> <base>`; on exit 0 it runs `git branch -D -- <branch>`. Otherwise it exits ≠0 and keeps the branch.
  7. **`safe-reset`.** It never runs `git clean`. Both forms remove `SQUASH_MSG` after a successful reset. Two forms:
     - **Manifest form, `safe-reset --stage <base_sha> <staged_tree>`.** The changed set is `git diff-tree -r --name-only <base_sha> <staged_tree>`. It refuses (exit 1, no change) unless HEAD equals `<base_sha>` and, for every path in the changed set, the index and the working tree both match `<staged_tree>` (a path absent from `<staged_tree>` must also be absent from the working tree, so an untracked user file at that path is never overwritten). Then it restores each changed path that exists in `<base_sha>` to its `<base_sha>` content in the index and the working tree, and removes each added path (absent in `<base_sha>`) from the index and the working tree. Every path outside the changed set stays unchanged. Paths are passed literally (`GIT_LITERAL_PATHSPECS=1`).
     - **Prior-clean attestation form, `safe-reset --clean-at <sha>`.** The caller attests that an `is-clean` check passed at `<sha>` immediately before a `merge --squash`. It refuses (exit 1, no change) unless HEAD equals `<sha>`. Then it runs `git reset --hard <sha>`, which leaves untracked and ignored paths in place. This form exists for the states where the manifest form cannot run: after a squash conflict (unmerged index entries, so `git write-tree` fails; `git merge --abort` refuses because `--squash` records no `MERGE_HEAD`) and after a later step edited tracked files (a release hook or `/release` Step 3).
  8. **Portability.** bash 3.2: no `mapfile`, `declare -A`, `${var,,}` or `local -n`. Path lists are read NUL-separated.
  9. **`resolve-base` (WP 1-06).** Prints one base ref on stdout: the first ref that resolves in this order — the target of `refs/remotes/origin/HEAD` (`git symbolic-ref`), `origin/master`, `origin/main`, `master`, `main`. Exit `0` when a ref resolves. Exit `1` with empty stdout when none resolves. It never fetches. It is the one copy of this order: `skills/wrap-ticket/prune-remote.sh` (after its own `--base` flag), `skills/worktree-lib.sh` (`release`, `release --preview`) and the wrap-ticket legacy path call it and MUST NOT restate the order.

---

## SHOULD

- SHOULD have the Tech Lead flag likely file-overlap between children of the same wave and add a serializing `depends_on` edge between them (overlapping children sharing a wave invite merge conflicts across their worktrees).
- SHOULD suggest `/brainstorm` before decomposition when the epic text is vague (mirroring SPEC-009's <50-words heuristic) rather than decomposing against an under-specified umbrella.
- SHOULD warn at the approval gate when decomposition exceeds ~8 children — the epic is probably two epics.
- SHOULD have `/wrap-ticket` mark the corresponding child `completed` in `state.json` when the wrapped ticket is an epic child (lookup by ticket ID), so epic state stays current without a manual `/epic` invocation.
- SHOULD print a compact wave plan at approval and on resume (e.g. `Wave 1: C1, C2 → Wave 2: C3 → Wave 3: C4`).
- SHOULD update the mirrored Linear child issues at child status transitions when the MCP is available (same best-effort posture as M5).
- SHOULD surface Linear project intent at the approval gate (e.g. will create/link Linear project named exactly as the epic title) — informational only; not AC-gating and not required for approval.
- SHOULD set per-child `outcome_summary` (≤1 line) when marking `completed` (and optionally `blocked`) so seeds stay informative without re-reading child sessions.
- SHOULD record `last_seed_path` after every successful between-child seed write.
- SHOULD prefer mechanical `build-seed` over full warm spine-mine for between-child boundaries (cheaper, deterministic, fail-closed friendly).
- SHOULD document measurement procedure for AC2 (what proxy, where logged, ε=0.5 pass rule) in `skills/epic/SKILL.md` Mode B.

---

## Test

1. **Decomposition completeness (M1):** run `/epic` on a sample umbrella → PM and Tech Lead spawned in parallel with `Output mode: terse`; every proposed child carries problem statement, acceptance criteria, estimate, recommended agent, and `depends_on`; a seeded child missing acceptance criteria blocks the approval gate.
2. **Cycle halt (M2):** seed a Tech Lead DAG with `C1→C2→C1` → `dag-lib.sh check-cycle` exits 1 and `/epic` halts naming the back-edge; assert no backlog file, no Linear call, no `state.json` was written.
3. **Approval gate (M3 / AC12):** decline the decomposition → zero side effects on disk **and** zero Linear project create/link attempts; approve → backlog items + index rows + `state.json` all appear.
4. **Backlog format + ID scheme (M4):** approved children exist as `.claude/backlog/<slug>.md` + index rows per SPEC-009 conventions; child IDs match `<EPIC-ID>-C<n>` and no child ID collides with a `.claude/tasks/` compound key.
5. **Linear degradation (M5 / AC6–AC7) + M4.1:** with no Linear MCP configured, the run completes with a single one-line notice and intact backlog/state (no project side effects); with the MCP present, child issues are **linked (adopt) or created** per M4.1 and their IDs recorded in `state.json` — never a blind second create set when parent already has non-canceled children; project create/link/attach failures reuse the same notice and do not block local path; inventory failure skips Linear child creates (local continues).
6. **Durable state + atomic writes (M6 / AC5):** after approval, `state.json` contains all required fields including nullable `linear_project_id`; a child status transition rewrites it via tmp+rename (no partial-read window); concurrent mutators MUST serialize via exclusive `flock` on `$MROOT/.claude/epics/.lock` covering full state RMW (not held across non-state I/O); concurrent bite-test proves no lost updates. *Schema + atomic writes + flock serialization covered by `skills/epic/test.sh`.*
7. **DAG-ordered handoff (M7):** a child with a non-completed dependency is never handed off; a ready child is handed to `/kickoff` or `/orchestrate` per the recorded execution mode; a child is not marked `completed` at kickoff-plan time. *Ready-set covered by `skills/epic/test.sh`.*
8. **Mandatory PM (M8):** in a full epic run, every child handoff includes the PM kickoff pass — including a child whose spec the TL wrote during decomposition; assert no skip-PM flag or prompt path exists in `commands/epic.md` / `skills/epic/SKILL.md`.
9. **Resume (M9 / AC8):** end the session after wave 1; re-invoke `/epic <EPIC-ID>` in a fresh session → rollup printed, next ready child picked up, no re-decomposition, no duplicate backlog/Linear issue or project writes; when `linear_project_id` is set, resume does not create a second project or re-attach all children; `--redecompose` without confirmation does nothing. *exists/show/init-refuse covered by `skills/epic/test.sh`.*
10. **Standup rollup (M10):** with an active epic, `/standup` shows per-epic child counts by state and the ready set, sourced from `state.json`. *rollup covered by `skills/epic/test.sh` + standup Step 5.5.*
11. **No forking (M11):** a full epic run shows `/epic` itself wrote no code, spawned no IC agents, created no worktrees, and wrote nothing under `.claude/tasks/` (entries there belong only to the children's own orchestrations).
12. **Linear Project create/link (M12 / AC1–AC4, AC11):** on approved new decompose with MCP up, exactly one project is created or linked by **exact** epic title; all dual-written children attach to it; epic labels still applied. Exact-name match → link only (no second create). *Protocol in SKILL; state field + CLI in `test.sh`; live MCP manual.*
13. **Redecompose project stability (M12 / AC9):** with non-null `linear_project_id`, approved `--redecompose` attaches only new/changed children to that project; id unchanged. Bare resume with null project id does not create a project.
14. **Context boundary default (M13):** multi-child Mode B (≥2 children) protocol in `skills/epic/SKILL.md` requires boundary before starting child N+1; single-child path has no mandatory boundary; `--no-context-discipline` documented as debug opt-out only.
15. **Seed shape (M13.3):** `build-seed` (or equivalent) from fixture `state.json` with ≥2 children → packet has State now / Through-line / appendix (or documented subset markers), epic id, rollup, completed outcomes (status+1-line), next handoff payload, blockers; MUST NOT embed full review/council transcript fixtures.
16. **Fail-closed (M13.4):** corrupt/empty seed → non-zero / halt line; next child not `in_progress`.
17. **No dual SoT (M13.2a):** status transitions only via `epic-lib` status commands; seed is advisory narrative, not status authority.
18. **Guardrail secondary (M13.5):** protocol documents 400k / 50%-window thresholds and forces boundary (not warn-only).
19. **M11 still holds under M13:** boundary path spawns no ICs, creates no worktrees, writes no `.claude/tasks/`.
20. **CDT-126 non-goal note:** SKILL/spec states council tiering is complementary, not a substitute for M13.
21. **M14 CLI table + hard-fail (C1/C7):** legal parse (`--worktree`, `--worktree --release <bump>`); each illegal combo exits 64 with zero side effects; defaults path omits keys / shows false/null; rejected names not documented as public flags. *Covered by `skills/epic/test.sh` (parse-flags + doc greps).*
22. **M14 integration path (C2/C3):** when `worktree_enabled`, exactly one `epic-<ID>` worktree; children share it (`ensure-ticket-worktree` skips per-child ensure). *test.sh c2/c3.*
23. **M14 mid-epic forbid (C4 / done-when 7):** `assert-release-allowed` exits 64 under release=end until seal; no version/tag side effects from the guard. *test.sh c4.*
24. **M14 seal single release (C5 / done-when 1–2):** fixture seal invokes release path once → `sealed=true`; mid-epic seal refused; no `release_bump` → no seal path. Dirty main (untracked or tracked) + seal refuses before the squash; dirty main + bare `--abort` refuses (exit 1, WIP preserved); a seal-owned stage alone + bare `--abort` resets (exit 0); `--abort --force` stashes then resets and keeps untracked files; squash/hook fail recovery resets only the seal-owned stage and never runs `git clean` (WP 1-05). *test.sh c5 + c5-abort-dirty + c5-6/c5-9 + `EPIC_SEAL_RELEASE_HOOK`; `skills/epic/test-seal-safety.sh`.*
25. **M14 resume (C6 / done-when 5):** flags omitted honor store; conflict → 64; same integration path reused. *test.sh c6.*
26. **M11 under M14:** docs state composition carve-out (ensure integration WT + seal only); no re-implement of full orchestrate lifecycle. *Protocol greps in test.sh.*
27. **M16 mid-epic gap callout (CDT-158):** `gap-callout` with C1 completed / C2 pending prints needles + C2 id/title, rc 0; all-complete / last remaining / unknown empty rc 0; `linear_id` lookup; charset 64 before path join; `/release` Step 0 greps `gap-callout`. *test.sh g1–g10.*
28. **M17 git safety primitive (WP 1-05):** squash-merged (multi-commit), cherry-picked, unmerged, unpushed, untracked and excluded-path cases; a git error makes `is-merged` fail closed; `safe-reset` keeps an untracked file and a dirty tracked file outside the changed set. *`skills/lib/git-safety-test.sh`.*

---

## Validation

- [x] Spec reviewed and promoted to ACTIVE
- [ ] Real umbrella decomposed: every child carries all five M1 fields
- [x] Cycle in the proposed DAG halts decomposition before any persistence *(lib + dag-lib bite-tests)*
- [x] Epic survives a session restart — resume at next ready child, no re-decomposition *(exists/show/init-refuse bite-tests; protocol in SKILL)*
- [ ] Linear-absent run completes cleanly with local write-through only *(protocol; manual)*
- [ ] Linear Project create/link on approve + `linear_project_id` recorded; fail-open on project failure *(CDT-64; protocol + test.sh schema; live MCP manual)*
- [x] PM kickoff observed on every child in a full epic run (no skip path exists) *(grep gate in protocol; no skip flag)*
- [x] `/standup` epic rollup reflects `state.json`, not prose *(Step 5.5 + rollup bite-tests)*
- [x] No epic-child records in `.claude/tasks/`; child IDs carry the `-C<n>` infix *(ID scheme tests)*
- [x] `dag-lib.sh check-cycle` reused literally (no duplicated cycle-detection code) *(wrapper + grep gate)*
- [ ] Between-child context boundary default-on for multi-child Mode B (M13 / CDT-127)
- [ ] Mechanical STM-shaped seed from state.json; fail-closed validation (M13.3–M13.4)
- [ ] Optional `last_seed_path` + `outcome_summary`; status remains sole SoT (M6 additive)
- [ ] Guardrail secondary documents 400k / 50% window; forces boundary (M13.5)
- [ ] AC2 ε=0.5 measurement note (dogfood/manual until free telemetry)
- [ ] CDT-126 non-goal note present; M11/M7/M8 preserved under boundary

---

## Open Questions

### Resolved (CDT-64 / F10 — Linear Project)

| ID | Resolution |
|----|------------|
| P1 / OQ1 | **Project name = epic `title` exactly** — no fuzzy match, no `EPIC-ID` prefix. |
| P2 / OQ2 | **Resolve team once** on the create branch only (search/link needs no team); same team for `save_project` and every child `save_issue`; if team unknown → fail-open (M5), skip create, no hard-fail. |
| P3 / OQ3 | **Multiple exact-name survivors → link first + multi-hit advisory; never create.** Client-side exact equality after query prefilter. |
| P4 / OQ4 | **No project create on bare resume when `linear_project_id` is null**; create/link only on new approved decompose, or approved `--redecompose` when id still null. |
| P5 / OQ5 | **Partial attach fail-open per child**; keep `linear_project_id`; continue other children. |
| P6 / OQ6 | **Epic parent/umbrella issue on the project = OOS** — children only. |
| P7 / OQ7 | **Reuse single M5 Linear fail-open notice line** — no second project-specific fail string. |
| P8 / OQ8 | **Project intent at approval = SHOULD**, not AC-gating. |

### Resolved (CDV-192 plan locks)

| ID | Resolution |
|----|------------|
| L1 | **Prompt-driven wave-walker MVP** — no Workflow-tool dependency. Universal path = orchestrator prompt loop + `epic-lib.sh` ready-set. |
| L2 | **Linear preferred when MCP up + mandatory local write-through** (CDT-54 / C8) — local IDs `<EPIC-ID>-C<n>` remain canonical orchestration keys; one-line notice on MCP fail (fail-open to local). Supersedes "backlog files alone are SoT". |
| L3 | **Reuse `dag-lib.sh check-cycle` literally** — no fork. Epic ready-set lives in `epic-lib.sh` (does **not** call task-store-bound `ready-set`). |
| L4 | **Sequential within wave** — concurrent multi-orchestrate deferred. |
| L5 | **Confirm each handoff** — print next ready child → user confirms → invoke `/kickoff` or `/orchestrate`. No auto-chain. |
| L6 | **PM kickoff mandatory per child** — no skip flag; handoff templates always include PM pass. |
| L7 | **Execution mode chosen once** at first execute: `kickoff` \| `orchestrate`, stored in `state.json`. |
| L8 | **`wrap-ticket` write-back is SHOULD, in-scope** — `mark-done` by ticket id / linear_id. |
| L9 | **No within-ticket task store pollution** — children never land in `.claude/tasks/`; `-C` infix. |
| L10 | **State at `$MROOT/.claude/epics/`** (git-common-dir root) — shared across worktrees. |
| OQ1 | Kickoff-mode completion: user confirms at next `/epic` resume, **or** `/epic complete <child-id>`. Not auto. |
| OQ6 | `status=blocked` via `/epic block\|unblock` thin wrappers over `set-status`. |

### Resolved (CDT-127 — context discipline)

| ID | Resolution |
|----|------------|
| CDT-127-OQ1 | **Primary A** (per-child hard context cut) + **secondary C** (threshold warn→force boundary). B (compact-only) not primary. |
| CDT-127-OQ2 | Prefer SPEC-018 loop: seed packet → branch/new session when available → degrade to `/compact` + `@seed`. |
| CDT-127-OQ3 | **Between children only** (MVP). Mid-child OOS. |
| CDT-127-OQ4 | **ε = 0.5** for AC2; guardrail **~400k tokens** or **50% window** (document both; dogfood/manual OK). |
| CDT-127-OQ5 | Autopilot: **silent mechanical** boundary; decision card only on seed failure. Not a new SPEC-033 gate. |
| CDT-127-OQ6 | Epic-owned boundary + seed CLI; **do not fork** `/orchestrate` unless proven required. |
| CDT-127-OQ7 | Optional `last_seed_path` + per-child `outcome_summary`; **status** remains sole SoT. |
| CDT-127-OQ8 | Default **on**; `--no-context-discipline` / `EPIC_NO_CONTEXT_DISCIPLINE=1` debug opt-out. |
| CDT-127-OQ9 | CI = seed shape fixtures; AC2 peak = dogfood/manual until free telemetry. |
| CDT-127-OQ10 | SPEC-033 OQ2 (wall-clock/stint) stays deferred — distinct from context discipline. |

### Deferred

- **Within-wave concurrency:** multiplies worktrees/review/attention. Sequential-within-wave default; revisit after first real multi-wave epic.
- **Deterministic wave-walker via the Workflow tool:** GA on paid plans only. Any adoption MUST keep the prompt-driven walker as universal fallback.
- **Failed child policy:** dependents stay non-ready (current); interactive DAG edit deferred.
- **Linear issue parent-child linking on create:** still deferred for *new* child issues (flat create + epic label + M12 project); **M4.1 inventory/adopt by `parentId` is in scope** so pre-existing parented children are never duplicated.
- **Mid-child context boundary / within-orchestrate budget:** future ticket; not M13 MVP.
- **Automated AC2 telemetry in CI:** blocked on free per-turn token/cache-read metrics from the harness.

---

## Version History

| Date | Change |
|------|--------|
| 2026-07-03 | Initial DRAFT — ideation wave 2 |
| 2026-07-14 | ACTIVE (CDV-192): `/epic` + `epic-lib.sh` + standup/wrap-ticket hooks; L1–L10 resolved; prompt-driven walker |
| 2026-07-22 | CDT-54 / CDT-46-C8: M4/M5 + L2 — Linear preferred when MCP up; mandatory local write-through; process trackers never committed; local child IDs still canonical keys |
| 2026-07-28 | CDT-64 / F10: M12 Linear Project per epic (exact-title create/link, attach children, `linear_project_id`); M3/M5/M6/M9 extended; fail-open reuses M5 notice; P1–P8 locks; labels retained |
| 2026-07-28 | CDT-64 follow-up: M12.2 client-side exact-equality filter + pagination; M12.3 resolve team once up front; set-linear-project not-found = exit 1 |
| 2026-07-28 | CDT-64 review fix: team resolution moved to the create branch only (search/link never gated on team, so an existing project still links when team is unresolvable); P2 restated |
| 2026-08-06 | **CDT-127:** M13 between-child context discipline (primary A + secondary C); M6 optional `last_seed_path` / `outcome_summary`; SPEC-018 seed shape; ε=0.5; fail-closed; CDT-126 non-goal; OQ1–OQ10 locked |
| 2026-08-07 | **CDT-141-C1:** M14 `--worktree` + `--release <bump>` parse/persist; own `skills/epic/parse-flags.sh`; optional state fields; exit 64 hard-fail; no worktree create (C2+) |
| 2026-08-07 | **CDT-141-C2:** `ensure-integration-worktree` — one `epic-<ID>` tree when `worktree_enabled` |
| 2026-08-07 | **CDT-141-C3:** children share integration tree — `resolve-child-worktree` / `ensure-ticket-worktree`; B.4 handoff + orchestrate/kickoff Step 3 skip per-child ensure; wrap-ticket MUST NOT release integration slug |
| 2026-08-07 | **CDT-141-C4:** `assert-release-allowed` mid-epic `/release` + master-merge forbid when `release_bump` set until seal; wire release Step 0 + orchestrate Step 11 + end-state; B.4 `EPIC_RELEASE_END` |
| 2026-08-07 | **CDT-141-C6:** resume same integration branch — `resolve-resume-flags` honors store when flags omitted; present flags conflicting with state → exit 64 (no silent downgrade of end-release); B.1 ensure reuses tree; `show` surfaces `integration_path` |
| 2026-08-07 | **CDT-141-C5:** end-of-epic seal — `seal-ready` / `seal` squash-stage → one `/release <bump>` (`EPIC_ALLOW_SEAL_RELEASE=1`) → `sealed=true`; failure aborts clean; no seal without `release_bump`; Mode B.7 |
| 2026-08-07 | **M4.1 link-before-create:** inventory `list_issues(parentId=EPIC)` before any child create; adopt unique map / halt on ambiguity; no second Linear child set when parent already has survivors (CDT-141 dogfood) |
| 2026-08-07 | **CDT-165:** M6 exclusive flock on `.claude/epics/.lock` around state RMW (in addition to tmp+rename) |
| 2026-08-07 | **M15 `/epic sync`:** explicit Linear→local refresh for existing `state.json` (fill null linear_id/project; status forward; no completed downgrade; orphans report-only; `sync-apply` mechanical CLI) |
| 2026-08-07 | **CDT-141-C7:** M14 formal CLI table, semantics, illegal combos, done-when 1–7, non-public API; M11 carve-out wording; surface docs + regression greps; Test 21–26 |
| 2026-08-07 | **CDT-170:** C5 abort dirty gate — bare `--abort` refuses non-empty porcelain on main (exit 1); `--abort --force` MAY reset+clean; same-invocation squash/hook recovery unchanged |
| 2026-08-08 | **CDT-169:** M6 EPIC-ID charset allowlist `^[A-Za-z0-9_-]+$`; exit 64 before FS side effects; covers `epic_paths` + `assert-release-allowed` path join |
| 2026-08-21 | **CDT-158 / M16:** `gap-callout` warn-only mid-epic incomplete-child + functional-gap notice; `/release` Step 0 prints after assert rc 0; C4 64 message unchanged |
| 2026-09-27 | **WP 1-05 (`wp-1-05-git-safety-lib`; CDT-260 `[05 F1]`, CDT-281 `[05 E6]`, rv-w1-32):** new **M17** git safety primitive `skills/lib/git-safety.sh` (`is-clean`, `is-merged`, `is-pushed`, `safe-delete-branch`, `safe-reset` with a manifest form and a prior-clean attestation form); contract home here (SPEC-009 C1 precedent). **M14 item 13** amended: seal excludes (`.claude/epics/`, `.worktrees/`, `.wt-lock`); the squash-stage gate now counts untracked paths; new nullable state field `seal_stage {base_sha, staged_tree, added_paths[]}` under `EPICS_LOCK`; bare `--abort` resets a seal-owned stage by fingerprint and refuses everything else; `--abort --force` is now "stash then reset" and never cleans (was "MAY hard-reset + clean"); squash-fail and hook-fail recovery use the attestation form; no `git clean` in `epic-lib.sh`; the former "reversible with `git reset --hard`" wording is withdrawn. Test 24 amended; Test 28 added. New `## Acceptance criteria` section holds this WP's ACs. |
| 2026-09-28 | **WP 1-06 (`wp-1-06-branch-deletion-safety`):** M17 item 9 adds `resolve-base`, the one shared base order (origin/HEAD target, `origin/master`, `origin/main`, `master`, `main`), moved from `skills/wrap-ticket/prune-remote.sh`. Item 2 amended: `resolve-base` is the only subcommand that prints on stdout. New consumers: `prune-remote.sh` (`is-merged` on the fetched remote ref), `worktree-lib.sh` `release` (`safe-delete-branch`) and `release --preview` (`is-merged`, `is-pushed`), and the wrap-ticket legacy path (`safe-delete-branch`). ACs in SPEC-016 `### wp-1-06-branch-deletion-safety`. |

**Covers**: `commands/epic.md`, `docs/commands/epic.md`, `skills/epic/SKILL.md`, `skills/epic/epic-lib.sh`, `skills/epic/parse-flags.sh`, `skills/epic/test.sh`, `skills/epic/test-seal-safety.sh`, `skills/lib/git-safety.sh` + `skills/lib/git-safety-test.sh` (M17), `skills/orchestrate/dag-lib.sh` (reused — `check-cycle`), `skills/standup/SKILL.md` (epic rollup, M10), `skills/wrap-ticket/SKILL.md` (child-completion write-back, SHOULD). CDT-127 also touches epic seed CLI under `skills/epic/` (build-seed / validate-seed) and cites SPEC-018 shape without forking handoff internals.

---

## Cross-references

- **SPEC-009** — Ticket Workflow: the composed single-ticket lifecycle (one full pass per child); owner of the backlog file format, kickoff gates, LOC caps, and escalation rules.
- **SPEC-017** — Autonomous CI Watch + Task DAG: owner of within-ticket DAGs and the `.claude/tasks/` store; `check-cycle` reused literally; `depends_on`/ready-set semantics mirrored at the epic layer.
- **SPEC-003** — Agent Role System: PM owns what/why per child, Tech Lead owns decomposition + DAG; MC-4 terse-spawn rule applies to decomposition spawns.
- **SPEC-016** — Worktree Isolation: default per-child trees via `worktree-lib`; M14 carve-out — when epic `worktree_enabled`, `/epic` ensures one `epic-<ID>` integration tree and children reuse it (no per-child ensure).
- **SPEC-018** — Cold-session handoff: STM packet shape reused (or mechanical strict subset) for between-child epic seeds; no dual freeform brief; no claim of full `/compact` replacement.
- **SPEC-033** — Autopilot policy: A.5/B.3 gates unchanged; M13 boundary is not a new gate enum.
- **CDT-126** — Council tiering: complementary child-level council cost control; not a substitute for M13.
- **Backlog item**: `.claude/backlog/epic-umbrella-decomposition.md` — the banked source of this spec.
- **Standing lesson**: `skills/orchestrate/SKILL.md` "PM kickoff is mandatory for every ticket" — promoted to M8.

---

## Acceptance criteria

Format and rules: SPEC-033 M14(g) and M14(h). Each ticket that ships through M14 has one
`### <ticket_id>` subsection below.

### wp-1-05-git-safety-lib

- **A.** Add `skills/lib/git-safety.sh`, run as a subprocess CLI (M17) with these subcommands:
  - `is-clean [--tracked-only] [-- <exclude-path>...]`: exit 0 only if there are no staged, unstaged or untracked non-ignored paths outside the excludes. `--tracked-only` ignores untracked paths.
  - `is-merged <ref> <base>`: layered and fail-closed. Exit 0 if `<ref>` is an ancestor of `<base>`. Otherwise exit 0 if `git cherry <base> <ref>` has no `+` line. Otherwise exit 0 if a synthetic squash commit (`commit-tree` of the tree of `<ref>` on `merge-base`) has no `+` line in `git cherry`. In every other case, including any git error, exit ≠0. It does not use `merge-tree`.
  - `is-pushed <ref>`: exit 0 only if `origin/<default>` or the upstream of `<ref>` contains `<ref>`.
  - `safe-delete-branch <branch> <base>`: delete the branch only when `is-merged` passes. Otherwise exit ≠0 and keep the branch.
  - `safe-reset` has two forms (M17 item 7). The manifest form `--stage <base_sha> <staged_tree>` restores only the tracked paths that a recorded squash changed and removes only its added paths; every other path is unchanged. The prior-clean attestation form `--clean-at <sha>` refuses unless HEAD equals `<sha>`, then resets the tracked tree to `<sha>`; untracked and ignored paths are unchanged. Neither form runs `git clean`.
  Verify: bash skills/lib/git-safety-test.sh
- **B.** The primitive suite covers squash-merged (multi-commit), cherry-picked, unmerged, unpushed, untracked and excluded-path cases. It also covers a git error that makes `is-merged` fail closed. It shows that `safe-reset` keeps an untracked file and a dirty tracked file outside the recorded set.
  Verify: bash skills/lib/git-safety-test.sh
- **C.** Seal squash-stage refuses (exit ≠0) when `is-clean` fails on main, with untracked paths included. The excludes are the plugin state paths `.claude/epics/`, `.worktrees/` and `.wt-lock`. After a refusal, the untracked file, the dirty tracked file and HEAD are all unchanged. Tests cover an untracked file, a dirty tracked file, and a start from a non-default branch. The non-default-branch test asserts only that the files survive and the exit is ≠0.
  Verify: bash skills/epic/test-seal-safety.sh
- **D.** After a successful `merge --squash`, seal writes the nullable field `seal_stage {base_sha, staged_tree, added_paths[]}` to the epic state JSON under `EPICS_LOCK`. The field is additive: state files without it still read correctly.
  Verify: bash skills/epic/test-seal-safety.sh
- **E.** On squash failure and hook failure, seal resets only the squash set. No code path in `skills/epic/epic-lib.sh` runs `git clean` (grep count = 0). After recovery, an untracked user file in main still exists (the file appears after the squash-stage gate passes: the test hook creates it, or the file is ignored).
  Verify: bash skills/epic/test-seal-safety.sh
- **F.** Seal abort:
  - Bare `seal --abort` resets only when one of these is true:
    - the tree is clean, or
    - `git write-tree` equals `seal_stage.staged_tree`, and there are no unstaged or untracked paths outside the excludes.
  - In every other case, bare abort exits ≠0 and changes nothing.
  - `--force` is valid only with `--abort`. It runs `git stash push -m "epic-seal-<EPIC>-<utc>"`, then `reset --hard`. It never runs `git clean`. The named stash contains the user's edits after the command.
  Verify: bash skills/epic/test-seal-safety.sh
- **G.** These three sites stop recommending `--abort --force` as routine recovery: the handoff `on_failure` field in `skills/epic/epic-lib.sh`, the B.7 recovery step in `skills/epic/SKILL.md` and the "Seal failure" row of its edge-case table. Where `--force` is documented, the docs say "stash then reset".
  Verify: bash skills/epic/test-seal-safety.sh
- **H.** `skills/autopilot/end-state.md` §4 runs `is-clean --tracked-only` on the main repo before `git merge --squash`. When tracked edits exist, it writes a halt card, exits ≠0 and changes nothing. Untracked files do not block. The behavioural test extracts the fenced §4 block from `end-state.md` and runs it against a fixture.
  Verify: bash skills/autopilot/test-end-state-safety.sh
- **I.** The §4 conflict path and both §6.5 abort paths call `safe-reset`, not a bare `git reset --hard` (structural check). The behavioural test extracts the fenced §4 and §6.5 blocks and runs them against a fixture. After recovery, an untracked file survives and HEAD is unchanged.
  Verify: bash skills/autopilot/test-end-state-safety.sh
- **J.** `skills/release-train/train-lib.sh restore <base>` decides over the range `<base>..HEAD`:

  | Range state | Result |
  |---|---|
  | Empty (HEAD == base) | Reset, exit 0 (current behaviour) |
  | Non-empty, no tag on any commit in range, no commit in range on origin | Reset to `<base>`, exit 0 |
  | Any tag on a commit in range | Halt, exit ≠0, HEAD and tag unchanged, recovery steps printed |
  | Any commit in range on origin | Halt, exit ≠0, HEAD unchanged, recovery steps printed |
  | No `origin` remote | Treat as unpushed (no halt on that ground) |

  Tests cover the empty, committed-only, committed-and-tagged, pushed and no-origin cases. The M6 halt and the Resume preflight in `skills/release-train/SKILL.md` still reset.
  Verify: bash skills/release-train/test-restore-safety.sh
- **K.** [process] These suites pass: `skills/lib/git-safety-test.sh`, `skills/epic/test-seal-safety.sh`, `skills/autopilot/test-end-state-safety.sh`, `skills/release-train/test-restore-safety.sh`, `skills/epic/test.sh`, `skills/autopilot/test.sh`, `skills/release-train/test.sh` and `skills/release-train/test-integration.sh`.
- **L.** [process] `bash tools/run-all-tests.sh` passes.
- **M.** [process] Every `/release` gate passes.
