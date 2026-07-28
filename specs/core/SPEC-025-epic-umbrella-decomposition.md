# SPEC-025: /epic — Umbrella Decomposition & Sequenced Orchestration

**Status**: ACTIVE
**Category**: core
**Created**: 2026-07-03

---

## Overview

Umbrella tickets ("build feature X across N surfaces") have no first-class path today: `/kickoff` and `/orchestrate` assume one ticket-sized unit of work, so users decompose epics by hand, lose the cross-ticket dependency picture, and re-derive sequencing every session. `/epic <EPIC-ID> "<epic text>"` closes that gap: PM and Tech Lead jointly decompose the epic into child tickets — each carrying a problem statement, acceptance criteria, size estimate, and recommended agent — and the Tech Lead adds a cross-ticket dependency DAG whose topological levels form execution **waves**. Approved children are persisted per SPEC-009 dual-write rules (Linear preferred when MCP is available; local backlog write-through always; MCP-down fail-open to local only). When Linear is reachable, `/epic` also best-effort creates or links **one Linear Project per epic** (name = epic title), attaches dual-written children to it, and records `linear_project_id` in state — without blocking the local path on project failure (CDT-64 / F10). A durable epic state file under `.claude/epics/` makes multi-day epics resumable and visible to `/standup`.

Execution mode walks the DAG: each ready child (all dependencies completed) is handed off to the existing single-ticket pipeline — `/kickoff` for plan-only, `/orchestrate` for full lifecycle. `/epic` is a **composition layer**: it sequences and hands off; it never re-implements the ticket lifecycle beneath it. The standing lesson from umbrella orchestrations — *PM kickoff is mandatory for every child ticket; skipping PM for "obvious" tickets misses false premises* (session fc046db3; `skills/orchestrate/SKILL.md` "PM kickoff is mandatory for every ticket") — is promoted to a MUST here.

**Boundaries & related specs (conflict scan, 2026-07-03):**
- **SPEC-009 (ticket workflow)** owns the single-ticket lifecycle end to end — brainstorm, kickoff, orchestrate gates, LOC caps, escalation rules, wrap-ticket, and the backlog file format (`.claude/backlog.md` index + `.claude/backlog/<slug>.md` items). `/epic` COMPOSES that lifecycle — one full SPEC-009 pass per child — and MUST NOT fork or re-implement any of it. Children are persisted through SPEC-009's backlog conventions; per-child gates (>4-open-questions pause, 2-attempt escalation, LOC caps) apply unchanged inside each child's run.
- **SPEC-017 (task DAG)** owns WITHIN-ticket DAGs: the `.claude/tasks/` store schema, the `depends_on` field semantics, `dag-lib.sh` primitives, and standup READY computation for tasks. The epic DAG is ACROSS tickets and lives in a separate store (`.claude/epics/<EPIC-ID>/state.json`). This spec MUST reuse `dag-lib.sh` conventions where sane — the store-independent `check-cycle` subcommand is invoked literally; `depends_on` naming and ready-set semantics (ready ⟺ every dependency `completed`) are mirrored — and MUST NOT write epic children into `.claude/tasks/` or extend the SPEC-017 task-store schema.
- **SPEC-003 (agent roles)** owns role boundaries and model tiers: PM owns the what/why per child (problem statements, acceptance criteria — never technical decisions); Tech Lead owns architecture, decomposition mechanics, estimates, and the dependency DAG. Decomposition spawns follow MC-4 (`Output mode: terse`). This spec adds no agent and modifies no agent definition.
- **SPEC-016 (worktree isolation)** owns worktree creation/teardown, which happens inside each child's own `/orchestrate` run via `worktree-lib.sh`. `/epic` itself MUST NOT create or remove worktrees.

**Out of scope:** cross-epic dependencies; parallel (concurrent) orchestration of multiple children within a wave (default is sequential); automatic DAG re-planning on child failure; Linear→local sync-back (webhooks), including project-id sync-back; retrofill of `linear_project_id` for epics created before project support; Linear milestones/initiatives/project health updates; delete/archive of Linear projects; placing an epic parent/umbrella Linear issue on the project (children only); a Workflow-tool deterministic wave-walker (deferred — prompt-driven walker is the MVP).

---

## MUST

- **M1 — Joint decomposition.** `/epic <EPIC-ID> "<epic text>"` in decompose mode MUST spawn PM and Tech Lead in parallel (both prompts carrying `Output mode: terse` per SPEC-003 MC-4). PM produces, per child: problem statement + acceptance criteria. Tech Lead produces, per child: size estimate (S/M/L) + recommended agent (per SPEC-009 tagging: ic4 for extending patterns, ic5 for novel work) + the cross-ticket `depends_on` list. Every child MUST carry all five fields before the approval gate; a child missing any field blocks approval.
- **M2 — Cross-ticket DAG with cycle gate.** The Tech Lead's `depends_on` lists reference child IDs only (no within-ticket task IDs). Before anything is persisted, the child list MUST be validated with the store-independent `skills/orchestrate/dag-lib.sh check-cycle` (input: JSON array of `{"task_id","depends_on"}` objects); on a detected cycle, `/epic` MUST halt with an error naming the back-edge and persist nothing. Waves are the topological levels of the acyclic DAG; a child is **ready** when every ID in its `depends_on` has `status=completed` — identical semantics to SPEC-017's ready-set.
- **M3 — Approval gate before persistence.** The full decomposition (children with all five fields, the DAG, and the wave plan) MUST be presented to the user for approval before any write occurs (no backlog file, no Linear issue, no Linear project, no state file). The user may edit, merge, or remove children at this gate; on decline, `/epic` exits with zero side effects — including zero Linear project create/link attempts.
- **M4 — Dual-write persistence (Linear preferred + local write-through).** On approval, each child MUST be persisted per SPEC-009 backlog dual-write rules: when the Linear MCP is available, create (or link) the Linear issue first and **always** write the local write-through (`.claude/backlog/<slug>.md` item + `.claude/backlog.md` index row) carrying the five M1 fields plus epic parent ID, `depends_on`, and Linear linkage; when MCP is down, write local only with a one-line notice. Child IDs MUST use the form `<EPIC-ID>-C<n>` (e.g. `CDV-30-C2`) — the `C` infix prevents collision with SPEC-017's within-ticket compound task keys (`<ISSUE-ID>-<task_id>`, e.g. `CDV-30-2`). Process trackers MUST NOT be committed to git (v1.0 invariant: `.claude` process state never upstream).
- **M5 — Linear preferred SoT when reachable; local IDs remain canonical keys.** When the Linear MCP is available, Linear issue state is preferred for open/closed status of dual-written children (reconcile/write paths per SPEC-009); `/epic` MUST record returned Linear identifiers in the epic state file. The local `<EPIC-ID>-C<n>` ID remains the **canonical orchestration key** in `state.json` and handoffs. When the MCP is absent or any Linear call fails (issue create/link, project create/link, or child-to-project attach), `/epic` MUST emit the single existing M5 one-line notice and continue on local write-through — it MUST NOT block, retry-loop, or fail the epic on Linear unavailability. Epic labels (e.g. `epic:<EPIC-ID>`) remain best-effort on child issues; a Linear Project MUST NOT replace labels.
- **M6 — Durable epic state file.** Epic state MUST live at `$MROOT/.claude/epics/<EPIC-ID>/state.json` ($MROOT resolved with the worktree-aware formula, so state is shared across worktrees), containing at minimum: epic ID, title, created timestamp, execution mode (`kickoff` | `orchestrate`), **`linear_project_id` (nullable string — Linear Project id when known, else `null`)**, and per child: ID, backlog slug, title, estimate, recommended agent, `depends_on`, `status` (`pending` | `in_progress` | `completed` | `blocked`), and `linear_id` (nullable). Writes MUST be atomic (write-to-tmp + rename, mirroring the SPEC-009 task-store discipline), and the file MUST be updated on every child status transition and when `linear_project_id` is first recorded.
- **M7 — Execution walks the DAG by composition.** In execution mode, `/epic` MUST hand each ready child to the existing single-ticket pipeline — `/kickoff <child-id> "<child text>"` (plan-only) or `/orchestrate` (full lifecycle), chosen once per epic and recorded in state.json. It MUST NOT hand off a child whose `depends_on` contains any non-completed child. Children within a wave run sequentially by default. A child transitions to `completed` only when its own SPEC-009 lifecycle finishes (ticket wrapped / PR shipped) — never merely because its kickoff produced a plan.
- **M8 — PM kickoff is mandatory for every child.** Every child handoff MUST include the PM kickoff pass — no exceptions for "obvious" children, docs-only children, or children whose spec the Tech Lead authored during decomposition. PM validates acceptance criteria independently and regularly catches false premises that would break implementation (the fc046db3 lesson). The `/epic` handoff path MUST NOT expose any option that skips PM.
- **M9 — Resumable across sessions.** Re-invoking `/epic <EPIC-ID>` when `state.json` exists MUST resume: print the epic rollup (children by state) and continue at the next ready child — no re-decomposition and no duplicate backlog/Linear issue or Linear project writes (see M12 for project-id stability). Re-decomposition MUST require an explicit `--redecompose` flag plus user confirmation, and even then MUST NOT delete or alter the records of already-completed children.
- **M10 — Standup rollup.** While any epic with non-completed children exists under `.claude/epics/`, `/standup` MUST surface an epic rollup section: per epic, child counts by state plus the currently-ready children — computed from `state.json`, not from prose (mirroring SPEC-017's store-not-prose READY discipline).
- **M11 — Composition, not forking (MUST NOT).** `/epic` MUST NOT: write code or spawn IC agents directly; run its own review loops; re-implement kickoff/orchestrate internals; create or remove worktrees; or store epic children in SPEC-017's `.claude/tasks/` store. The epic layer ends at decomposition, sequencing, handoff, and state tracking — everything below is owned by SPEC-009/SPEC-016/SPEC-017.
- **M12 — Linear Project per epic (best-effort; CDT-64 / F10).** On **approved** new decomposition (and on approved `--redecompose` when `linear_project_id` is still null), when the Linear MCP is available, `/epic` MUST create or link **exactly one** Linear Project associated with the epic **before or with** child dual-write, subject to fail-open (M5):
  1. **Name:** project name MUST equal the epic `title` field exactly (no `EPIC-ID` prefix, no fuzzy rename).
  2. **Link-before-create:** session MUST query Linear for a project whose name equals that title exactly; on match, **link** (record its id) and MUST NOT create a second project. If multiple projects share that exact name, link the **first list hit** and emit a one-line notice; MUST NOT create.
  3. **Create:** only when no exact-name match exists. Team for create MUST be the same team used for child `save_issue` (M5 child path). If team is unknown, fail-open (M5) — no project create attempt that would hard-fail.
  4. **Attach:** every dual-written child Linear issue MUST be attached to that project (e.g. `save_issue` with `project`). Attach failure for one child is fail-open for that child only (keep `linear_project_id`, continue remaining children).
  5. **Record:** returned project id MUST be stored as `state.json` `linear_project_id` (atomic write). Local child IDs remain canonical orchestration keys.
  6. **MCP down / project path failure:** no Linear project side effects required; local write-through proceeds; one M5 notice line (reuse — do not invent a second fail-open string).
  7. **Resume:** when `state.json` already has a non-null `linear_project_id`, resume MUST NOT create a second project and MUST NOT re-attach all existing children (no attach storm). Bare resume with `linear_project_id == null` MUST NOT create a project (only new approved decompose, or approved `--redecompose` when id is still null).
  8. **Redecompose:** new/changed children dual-written under `--redecompose` MUST attach to the existing project when `linear_project_id` is set; the id MUST remain stable. Completed children are never deleted/altered (M9).
  9. **Session ownership:** Linear MCP calls (list/create project, attach issues) are session-owned — bash engines (`epic-lib.sh`) MUST NOT call Linear MCP; they only persist ids the session supplies (same bridge pattern as SPEC-009 backlog).
  10. **OOS for this MUST:** epic parent/umbrella issue on the project; retrofill of pre-existing epics; milestones/initiatives; project health; delete/archive projects; Linear→local project sync.

---

## SHOULD

- SHOULD have the Tech Lead flag likely file-overlap between children of the same wave and add a serializing `depends_on` edge between them (overlapping children sharing a wave invite merge conflicts across their worktrees).
- SHOULD suggest `/brainstorm` before decomposition when the epic text is vague (mirroring SPEC-009's <50-words heuristic) rather than decomposing against an under-specified umbrella.
- SHOULD warn at the approval gate when decomposition exceeds ~8 children — the epic is probably two epics.
- SHOULD have `/wrap-ticket` mark the corresponding child `completed` in `state.json` when the wrapped ticket is an epic child (lookup by ticket ID), so epic state stays current without a manual `/epic` invocation.
- SHOULD print a compact wave plan at approval and on resume (e.g. `Wave 1: C1, C2 → Wave 2: C3 → Wave 3: C4`).
- SHOULD update the mirrored Linear child issues at child status transitions when the MCP is available (same best-effort posture as M5).
- SHOULD surface Linear project intent at the approval gate (e.g. will create/link Linear project named exactly as the epic title) — informational only; not AC-gating and not required for approval.

---

## Test

1. **Decomposition completeness (M1):** run `/epic` on a sample umbrella → PM and Tech Lead spawned in parallel with `Output mode: terse`; every proposed child carries problem statement, acceptance criteria, estimate, recommended agent, and `depends_on`; a seeded child missing acceptance criteria blocks the approval gate.
2. **Cycle halt (M2):** seed a Tech Lead DAG with `C1→C2→C1` → `dag-lib.sh check-cycle` exits 1 and `/epic` halts naming the back-edge; assert no backlog file, no Linear call, no `state.json` was written.
3. **Approval gate (M3 / AC12):** decline the decomposition → zero side effects on disk **and** zero Linear project create/link attempts; approve → backlog items + index rows + `state.json` all appear.
4. **Backlog format + ID scheme (M4):** approved children exist as `.claude/backlog/<slug>.md` + index rows per SPEC-009 conventions; child IDs match `<EPIC-ID>-C<n>` and no child ID collides with a `.claude/tasks/` compound key.
5. **Linear degradation (M5 / AC6–AC7):** with no Linear MCP configured, the run completes with a single one-line notice and intact backlog/state (no project side effects); with the MCP present, child issues are created and their IDs recorded in `state.json`; project create/link/attach failures reuse the same notice and do not block local path.
6. **Durable state + atomic writes (M6 / AC5):** after approval, `state.json` contains all required fields including nullable `linear_project_id`; a child status transition rewrites it via tmp+rename (no partial-read window). *Schema + atomic writes covered by `skills/epic/test.sh`.*
7. **DAG-ordered handoff (M7):** a child with a non-completed dependency is never handed off; a ready child is handed to `/kickoff` or `/orchestrate` per the recorded execution mode; a child is not marked `completed` at kickoff-plan time. *Ready-set covered by `skills/epic/test.sh`.*
8. **Mandatory PM (M8):** in a full epic run, every child handoff includes the PM kickoff pass — including a child whose spec the TL wrote during decomposition; assert no skip-PM flag or prompt path exists in `commands/epic.md` / `skills/epic/SKILL.md`.
9. **Resume (M9 / AC8):** end the session after wave 1; re-invoke `/epic <EPIC-ID>` in a fresh session → rollup printed, next ready child picked up, no re-decomposition, no duplicate backlog/Linear issue or project writes; when `linear_project_id` is set, resume does not create a second project or re-attach all children; `--redecompose` without confirmation does nothing. *exists/show/init-refuse covered by `skills/epic/test.sh`.*
10. **Standup rollup (M10):** with an active epic, `/standup` shows per-epic child counts by state and the ready set, sourced from `state.json`. *rollup covered by `skills/epic/test.sh` + standup Step 5.5.*
11. **No forking (M11):** a full epic run shows `/epic` itself wrote no code, spawned no IC agents, created no worktrees, and wrote nothing under `.claude/tasks/` (entries there belong only to the children's own orchestrations).
12. **Linear Project create/link (M12 / AC1–AC4, AC11):** on approved new decompose with MCP up, exactly one project is created or linked by **exact** epic title; all dual-written children attach to it; epic labels still applied. Exact-name match → link only (no second create). *Protocol in SKILL; state field + CLI in `test.sh`; live MCP manual.*
13. **Redecompose project stability (M12 / AC9):** with non-null `linear_project_id`, approved `--redecompose` attaches only new/changed children to that project; id unchanged. Bare resume with null project id does not create a project.

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

---

## Open Questions

### Resolved (CDT-64 / F10 — Linear Project)

| ID | Resolution |
|----|------------|
| P1 / OQ1 | **Project name = epic `title` exactly** — no fuzzy match, no `EPIC-ID` prefix. |
| P2 / OQ2 | **Team for `save_project` = same team as child `save_issue`**; if team unknown → fail-open (M5), no hard-fail create. |
| P3 / OQ3 | **Multiple exact-name hits → link first list hit + notice; never create.** |
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

### Deferred

- **Within-wave concurrency:** multiplies worktrees/review/attention. Sequential-within-wave default; revisit after first real multi-wave epic.
- **Deterministic wave-walker via the Workflow tool:** GA on paid plans only. Any adoption MUST keep the prompt-driven walker as universal fallback.
- **Failed child policy:** dependents stay non-ready (current); interactive DAG edit deferred.
- **Linear issue parent-child linking:** still deferred — flat child issues + epic label; M12 Linear **Project** grouping is independent of issue hierarchy.

---

## Version History

| Date | Change |
|------|--------|
| 2026-07-03 | Initial DRAFT — ideation wave 2 |
| 2026-07-14 | ACTIVE (CDV-192): `/epic` + `epic-lib.sh` + standup/wrap-ticket hooks; L1–L10 resolved; prompt-driven walker |
| 2026-07-22 | CDT-54 / CDT-46-C8: M4/M5 + L2 — Linear preferred when MCP up; mandatory local write-through; process trackers never committed; local child IDs still canonical keys |
| 2026-07-28 | CDT-64 / F10: M12 Linear Project per epic (exact-title create/link, attach children, `linear_project_id`); M3/M5/M6/M9 extended; fail-open reuses M5 notice; P1–P8 locks; labels retained |

**Covers**: `commands/epic.md`, `skills/epic/SKILL.md`, `skills/epic/epic-lib.sh`, `skills/epic/test.sh`, `skills/orchestrate/dag-lib.sh` (reused — `check-cycle`), `skills/standup/SKILL.md` (epic rollup, M10), `skills/wrap-ticket/SKILL.md` (child-completion write-back, SHOULD).

---

## Cross-references

- **SPEC-009** — Ticket Workflow: the composed single-ticket lifecycle (one full pass per child); owner of the backlog file format, kickoff gates, LOC caps, and escalation rules.
- **SPEC-017** — Autonomous CI Watch + Task DAG: owner of within-ticket DAGs and the `.claude/tasks/` store; `check-cycle` reused literally; `depends_on`/ready-set semantics mirrored at the epic layer.
- **SPEC-003** — Agent Role System: PM owns what/why per child, Tech Lead owns decomposition + DAG; MC-4 terse-spawn rule applies to decomposition spawns.
- **SPEC-016** — Worktree Isolation: worktrees are created/removed only inside each child's own lifecycle; `/epic` never touches them.
- **Backlog item**: `.claude/backlog/epic-umbrella-decomposition.md` — the banked source of this spec.
- **Standing lesson**: `skills/orchestrate/SKILL.md` "PM kickoff is mandatory for every ticket" — promoted to M8.
