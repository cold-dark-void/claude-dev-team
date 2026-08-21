# SPEC-009: Ticket Workflow

**Status**: ACTIVE
**Category**: core
**Created**: 2026-03-22

**Covers**: `skills/kickoff/SKILL.md`, `skills/orchestrate/SKILL.md`, `skills/orchestrate/steps/00-resolve.md`, `skills/orchestrate/steps/02-scope.md` (auto-size, CDT-210), `skills/orchestrate/steps/{04-kickoff,05-questions,06-design,07-tasks,08-execute,09-review,10-qa,12-wrap}.md` (light path, CDT-207–209), `skills/autopilot/parse-flags.sh` (`/orchestrate --tier`, CDT-206), `skills/brainstorm/SKILL.md`, `commands/status.md` (`/status` + `/status standup`, CDT-46-C4), `skills/standup/SKILL.md` (internal skill-delegate backend for `/status standup`), `skills/wrap-ticket/SKILL.md`, `skills/backlog/SKILL.md`

## Overview

The main delivery pipeline from idea to shipped code. Covers Socratic design refinement (brainstorm), parallel PM + Tech Lead kickoff with spec-first planning, end-to-end orchestration with agent dispatch and review loops, status monitoring (standup), ticket wrap-up with learnings extraction, and backlog management for deferred work.

**Backlog posture (CDT-54 / CDT-46-C8):** when the Linear MCP is available, backlog add/list/close are **Linear-first** (Linear preferred SoT for open work); local `.claude/backlog*` files are a **mandatory write-through cache** on every path (always dual-write when MCP up; local-only + one-line notice when MCP down). Process trackers under `.claude/` are never committed as product.

## MUST

### Brainstorm
- MUST NOT propose solutions during the questioning phase (questions only)
- MUST NOT skip rounds even if user says "just build it"
- MUST present questions in batches of 3-5 (not all at once)
- MUST wait for user answers before advancing to next round (4 rounds total)
- MUST be opinionated in recommendation (not neutral between design options)
- MUST save results to `.claude/plans/<date>-brainstorm-<slug>.md`
- MUST offer backlog/Linear write-back once the user accepts the synthesis,
  unless `/kickoff` runs immediately in the same session, per
  `skills/backlog/SKILL.md` § Programmatic write-back protocol — accepted
  scope MUST NOT evaporate into a plan file with no tracked-work visibility

### Kickoff
- MUST create or reuse a worktree via `worktree-lib.sh ensure <TICKET-ID>` (SPEC-016 caller-integration form) **after context load and before spawning the PM/Tech Lead/Explorer agents**, capturing `$WT_PATH` — mirroring `/orchestrate`'s Step 3→4 ordering. The slug MUST be the bare `<TICKET-ID>`. Exit-code handling MUST match `/orchestrate` Step 3 (`0` proceed, `1`/`2`/`64` HALT); MUST NOT silently proceed without a worktree
- MUST perform **all** spec creation/commit, plan-file writes, and domain-glossary (CONTEXT.md) write-back inside `$WT_PATH` — on branch `feat/<TICKET-ID>` — never on the invoking session's current branch and never at `$MROOT`. The spec commit MUST target `$WT_PATH/specs` (`git -C "$WT_PATH"`), closing the origin defect where `/kickoff` committed the spec straight to master (CDT-104, CDT-99)
- MUST leave the worktree **in place** as documented resumable state at kickoff exit; MUST NOT call `worktree-lib.sh release`. The kickoff worktree is the planning handoff artifact — a later `/orchestrate <TICKET-ID>` reuses the same-slug tree, or a human resumes from it. This is the deliberate exception to SPEC-031's bounded-exit "never leave a worktree as final state", which is scoped to implementation-capable skills that ship code; `/kickoff` ships spec+plan only
- MUST print `$WT_PATH` and the branch name in the kickoff summary, plus an explicit resume line (e.g. "Resume with `/orchestrate <TICKET-ID>` to implement, or `cd` into the worktree")
- The TaskCreate task graph and `task-store.sh` writes stay `$MROOT`-anchored (`.claude/tasks/…`) — shared cross-worktree bookkeeping by design (SPEC-017), unaffected by the worktree-scoped spec/plan commit
- A ticket spec committed only on `feat/<TICKET-ID>` is not visible to `/spec check` on master until the branch merges — this is the intended trade of worktree isolation, not a regression, and the kickoff summary SHOULD state it once
- MUST spawn three agents in parallel: PM, Tech Lead, Codebase Explorer (no sequential waiting)
- MUST collect all three outputs before proceeding to planning
- MUST include the line `Output mode: terse` in every agent-spawn prompt template (kickoff and orchestrate own the spawn templates) — mirrors SPEC-003 MC-4; `/spec reflect` flags any spawn template missing it
- MUST pause kickoff and present unresolved questions to user if PM found >4 open questions (do not plan against vague ticket)
- MUST escalate if Tech Lead identifies breaking schema change
- MUST write or update spec BEFORE creating task graph (spec-first principle)
- MUST tag each task with recommended agent (ic4 for extending patterns, ic5 for novel work)
- MUST increment SPEC numbers within the relevant category after highest existing number

### Orchestrate
- MUST NOT write code directly (orchestrator is observer/navigator only)
- MUST enforce two escalation gates: scope confirmation (Gate 1) and plan approval (Gate 2)
- MUST track task state and only spawn agents for unblocked tasks
- MUST escalate on: agent stuck after 2 attempts, scope creep, ambiguous requirement, breaking change, deadloop (3+ review rounds)
- MUST NOT escalate on: test failures, lint/format, routine implementation decisions, file organization
- MUST enforce LOC caps on implementation code: ~1k LOC soft cap, 2k hard cap total, no single file >1k lines changed
- MUST exempt generated code (specs, tests) from LOC caps
- MUST separate refactoring from feature work (ship refactor first, feature on top)
- MUST never silently absorb discovered work (create new ticket)
- MUST replan when approach changes materially
- MUST track review round count per task (flag deadloop at 3+)
- MUST support an optional `requires_council: true` metadata field on orchestrated tasks (opt-in per task; MUST NOT be required by default on any task)
- When `requires_council: true` is set, the TaskCompleted quality-gate hook MUST block task completion until a `/council` verdict exists for the task's deliverable with confidence at or above the configured threshold (`council.taskgate.min_confidence`, default 80)
- MUST export `CLAUDE_TASK_ID=<task_id>` in the subprocess environment whenever the orchestrator invokes `/council` as part of a task's orchestration steps — ambient task-id transport required by SPEC-013 Phase 6 Task Binding & Verdict Index for correct verdict-to-task binding
- MUST surface the blocked state clearly when the council gate fails — naming the blocked task, the missing-or-below-threshold verdict, and the required minimum confidence
- MUST write per-task metadata to `$MROOT/.claude/tasks/<ISSUE-ID>-<task_id>.json` at TaskCreate time for every orchestrated task (e.g. `CDV-QF-FILTER-1.json`), using a compound key `<ISSUE-ID>-<task_id>` to prevent collisions when a new Claude process reuses integer task IDs; the orchestrator MUST create `.claude/tasks/` if absent. The task-file schema is owned by SPEC-017 (canonical 6-field schema incl `depends_on`) — see SPEC-017 "Task store schema".
- MUST update the `status` field in the compound-key file on every TaskUpdate transition (pending → in_progress → completed | blocked), preserving other fields. Orchestrators MUST pass the same compound key used at `create` to `task-store.sh update-status` (e.g. `CDV-QF-FILTER-1`) — bare integer ids are a non-native edge path; see SPEC-017 invent policy
- MUST NOT delete task store files after completion — they are the source of truth for the TaskCompleted gate and must survive the task being marked done
- MUST use atomic write-to-tmp + rename when updating task store files (prevents the TaskCompleted hook from reading a partial write)
- The TaskCompleted hook MUST support both legacy flat-key (`<task_id>.json`) and compound-key (`*-<task_id>.json`) formats. **Shadow-safe resolution (CDT-167, contract home SPEC-002):** the hook MUST NOT let a flat file with `requires_council: false`/absent/stub suppress a compound match with `requires_council: true`; effective gate = any candidate true. Pure-missing candidates remain silent-pass. (Supersedes the 2026-04-28 "flat-first / mtime-only when flat missing" read order for the council opt-in decision.)
- MUST resolve `$MROOT` with the worktree-aware formula: `_gc=$(git rev-parse --git-common-dir 2>/dev/null) && MROOT=$(cd "$(dirname "$_gc")" && pwd) || MROOT=$(pwd)` — task metadata is shared across worktrees
- MUST resolve ticket source at intake when possible: `linear` (MCP hit), `backlog` (`.claude/backlog/<slug>.md` or index match), or `freeform` (paste)
- MUST record a plan Tracking section with `source`, `ticket_id`, and `closes:` (zero or more `backlog/<slug>.md` and/or `linear:<ID>` entries); many-to-one closes allowed
- MUST close every plan `closes:` backlog item (item file Status + index line via write-through) as part of ship on the feature worktree — local status flip only; MUST NOT stage or commit `.claude/backlog*` into the product delivery commit (CDT-54)
- MUST close local backlog write-through for plan `closes:` backlog entries at ship (item Status + index via `close.sh`); fail-open Linear separately
- **Linear lifecycle (status truth = code location):**
  - **In Progress** when work starts (orchestrate worktree)
  - **In Review** when a PR is opened or ship is PR-stop / not yet on master — MUST NOT mark **Done** while changes exist only on a feature/integration branch
  - **Done** (or team Released) only when work is on **master/main** (successful squash/merge/`/release`) **or** at `/wrap-ticket` after merge (idempotent re-Done safety net)
- MUST attempt Linear **In Review** (not Done) on PR-stop when `closes:` lists `linear:<ID>` or source is linear and MCP is available; fail-open with a warning if MCP is unavailable
- MUST attempt Linear **Done** on master-land ship paths and on wrap-ticket when MCP is available; fail-open with a warning if MCP is unavailable
- MUST NOT block ship on empty `closes:` (freeform); MUST block ship if a non-empty backlog close fails verify on local write-through
- MUST use worktree root (`git rev-parse --show-toplevel` or explicit `--root`) when editing local backlog write-through files for close-out — not `git-common-dir` alone

#### Orchestrate `--tier` (CDT-206)

Pipeline cost tier for `/orchestrate`. This subsection is the contract home.
`--tier` is independent of SPEC-013 `--council-tier`.

- MUST accept `--tier=light|standard|full` on `/orchestrate` in any argument position
- MUST use the `=` form only (`--tier=<value>`)
- MUST parse `--tier` in `skills/autopilot/parse-flags.sh`
- MUST print JSON key `tier`. MUST NOT reuse key `council_tier` for this flag
- MUST print exactly five JSON keys on success: `enabled`, `bump`, `source`, `council_tier`, `tier`
- MUST set `"tier": null` when `--tier` is absent. MUST NOT coerce omit to `"standard"` or `"full"`
- MUST set `"tier"` to `"light"`, `"standard"`, or `"full"` when the flag is well-formed
- MUST exit 64, write the error to stderr, and print no success JSON when `--tier` is malformed
- MUST NOT start the `/orchestrate` pipeline after that parse failure. Step 0 MUST halt before fetch, worktree, or spawns (`parse-flags.sh || exit 64` in `steps/00-resolve.md`)
- Malformed includes: unknown values (`skip`, `bogus`, `std`, `max`); empty `--tier=`; bare `--tier`; space form `--tier light`; case variants (`LIGHT`, `Full`); any second `--tier` or `--tier=*` token, even when values match
- MUST parse `--tier` independently of `--council-tier`. `--tier=light` MUST NOT set `council_tier`. `--council-tier=light` MUST NOT set `tier`. Both flags MAY appear on one invocation. `--council-tier` vocabulary and errors stay unchanged
- MUST bind `.tier` once in `skills/orchestrate/steps/00-resolve.md` from the same `parse-flags.sh` call as `--council-tier`. MUST carry the resolved value for the run
- MUST NOT add an environment variable for `--tier`
- MUST NOT persist `--tier` in `resume-state.sh`. A resume without `--tier` MUST re-resolve `"tier": null`
- MUST NOT add `commands/orchestrate.md` (skill-only Surface; router-static T7)
- MUST NOT document `--tier` on `/kickoff`. Kickoff MAY parse the token because it shares `parse-flags.sh`. Kickoff MUST ignore a present unused `.tier`. A malformed `--tier` on kickoff MUST still exit 64
- MUST NOT extend `skills/epic/parse-flags.sh`. MUST NOT change `skills/council/engine.sh --tier` vocabulary (`light|full`)
- MUST list `--tier=light|standard|full` in `skills/orchestrate/SKILL.md` and include a per-tier router table. `standard` and `full` rows = current steps 0–12. `light` row = scoper-planner, skip DAG, one IC4, single-pass TL, no council default, wrap-lite. The file MUST stay ≤80 lines
- MUST document `--tier` in `docs/commands/orchestrate.md` Flags table. The row states: pipeline cost tier; `standard`/`full` = current pipeline; `light` step map; no `--tier` auto-sizes at Step 2; explicit `--tier` wins; independent of `--council-tier`
- **Identity (`standard` / `full`).** MUST run today's Step 0–12 sequence, the same step files, the same spawn sites, and the same SPEC-033 gates and gate actors when `--tier=standard` or `--tier=full`. Those two cases have identical behavior. `full` is identical to `standard`
- **Identity (omit).** MUST NOT coerce omit to `"standard"` at parse time (`"tier": null`). Step 2 MUST auto-size when `[ "$ORCH_TIER" = "null" ]` (CDT-210). After the gate, the selected tier is the run's pipeline
- Light-path step branches MUST test exactly `[ "$ORCH_TIER" = "light" ]`. MUST NOT use `!= "null"` or `!= "full"` (that would cut omit and standard)
- MUST NOT change SPEC-033 gate ownership, checklists, or BC halt/escalate. MUST NOT edit SPEC-033

#### Orchestrate `--tier` light path (CDT-207 / CDT-208 / CDT-209)

When `[ "$ORCH_TIER" = "light" ]` (explicit `--tier=light` or auto-size S):

- MUST spawn exactly one scoper-planner at Steps 4–6 (confirms ACs and writes a short plan). MUST NOT parallel-spawn PM+TL. MUST NOT spawn a separate TL design pass (CDT-207)
- MUST still surface open questions at Step 5. MUST still fire SPEC-033 `plan-approve` at Step 6. MUST still write the plan artifact with Tracking (CDT-207)
- MUST skip DAG/task-store at Step 7. MUST create one task. MUST spawn exactly one ic4 at low effort at Step 8. That task MUST NOT set `requires_council` (CDT-208)
- MUST run a single-pass TL diff review at Step 9 with max one rework, then APPROVE or escalate. MUST NOT use the 3-round deadloop as the default (CDT-209)
- MUST default to no council spawn on light. MUST skip simplify 9.5. MUST NOT spawn a separate `@qa` — the IC runs tests and pastes output (CDT-209)
- `--council-tier=skip|light|full` MUST override the tier's council default when both flags are given: EFFECTIVE = `COUNCIL_TIER_OVERRIDE` when that value is not the string `"null"`; else if `[ "$ORCH_TIER" = "light" ]` then skip council; else today's behavior (CDT-209)
- MUST skip Step 12b friction/retro on light. MUST still print orchestration complete and suggest `/wrap-ticket` (CDT-209)
- MUST NOT change Steps 3 and 11 (worktree + ship, including M14 ship-gate) (CDT-209)
- MUST keep SPEC-033 gates (`scope-confirm`, `plan-approve`, `ship-choice`) and gate actors (CDT-209)

#### Orchestrate auto-size at scope-confirm (CDT-210)

When `[ "$ORCH_TIER" = "null" ]` (no `--tier`):

- MUST classify S/M/L at the existing Step 2 `scope-confirm` gate from cheap signals (AC count, estimated files touched, bugfix-vs-feature shape, diff-size guess) with NO extra agent spawn
- MUST show proposed tier + one-line rationale in that same gate (not a new gate)
- Mapping MUST be S → light, M → standard, L → full
- Explicit `--tier` MUST skip classification and win
- Autopilot `proceed` MUST use the proposed tier unless overridden. Decision-card MUST record proposed + selected
- Classification failure or missing signals MUST propose `standard`

### Standup / `/status` (CDT-46-C4 entry)
- User entry for the standup snapshot is `/status` (bare) and `/status standup [TICKET-ID]` via `commands/status.md`. There is no `commands/standup.md`.
- bare `/status` MUST render, in order: standup view → metrics rollup (all sections) → worktree list/status (read-only; SPEC-016 `/status worktree`)
- `/status` and all its subs MUST be **read-only** — MUST NOT mutate worktrees, ledgers, DBs, or tasks
- MUST read agent context files from `.claude/memory/<owner>/context.md`
- MUST check file mtime to detect staleness (not updated in 30 minutes)
- MUST check recent git commits (grep for agent name in Co-Authored-By, last 1 hour)
- MUST flag as STALE if: context.md outdated OR no recent commits OR blocked/waiting without SendMessage to Tech Lead
- MUST detect ready-to-claim tasks by checking depends_on list (all completed = READY) — readiness computed per SPEC-017 "/standup — READY computation"
- MUST auto-escalate (surface for engineer, not send automatically) if: task stale without Tech Lead message, 2+ tasks blocked on same dependency, completed task output unconsumed 30+ minutes
- Metrics sub (`/status metrics`) MUST preserve former `/metrics` flag parity: `--json`, `--section all|council|outcomes|worktree` (engine: `skills/metrics/rollup.sh`)

### Wrap-Ticket
- MUST block wrap if any tasks are in-progress or pending (unless user force-closes)
- MUST extract learnings from agent context files (limit to 3-8 specific bullets)
- MUST append learnings to existing memory (never overwrite)
- MUST warn if any memory file exceeds its SPEC-004 line limit (cortex 100/memory 50/lessons 80/context 60), suggesting consolidation
- MUST check if distillation should auto-trigger based on config and raw memory count
- MUST skip plan update silently if plans.md doesn't exist
- MUST NOT remove worktree if it has uncommitted changes — worktree teardown safety per SPEC-016
- MUST use `INSERT OR REPLACE` when writing back to DB memory
- MUST preserve SQL escaping for single quotes in DB writes
- MUST idempotently re-close source tracking from the plan `closes:` list (or ticket-id backlog slug fallback) via `skills/backlog/close.sh` — safety net when ship close-out was skipped
- MUST attempt Linear **Done** when MCP is available and a Linear id is known (plan `linear:<ID>`, ticket id, or backlog `linear_id`) — this is the primary terminal for PR-stop tickets left In Review; fail-open if MCP unavailable

### Backlog
- MUST auto-initialize local backlog structure if missing (silently for add/close) — local files are a **mandatory write-through cache**, not optional
- MUST generate slug from title: lowercase, hyphen-joined, stripped punctuation, max ~50 chars
- MUST append -2, -3 etc. on slug collision
- MUST use format: `.claude/backlog.md` (index) + `.claude/backlog/<slug>.md` (items) for local write-through
- MUST track status: PENDING or COMPLETED
- MUST include Problem, Goal, Notes sections in item files
- MUST search case-insensitive for close target (slug or title)
- MUST ask user to clarify if multiple matches on close
- MUST provide a deterministic subprocess CLI `skills/backlog/close.sh` for close + verify (idempotent; no git commit inside the script)
- MUST resolve close/verify root as `--root` if set, else `git rev-parse --show-toplevel`, else `pwd`
- **Linear-first when MCP reachable (CDT-54).** `/backlog add` MUST create (or link) a Linear issue first when the Linear MCP is available, then **always** dual-write the local index + item with Linear id linkage. `/backlog list` MUST prefer Linear open issues as the preferred SoT for open work when MCP is up, presenting local files as write-through. `/backlog close` MUST mark the Linear issue terminal when MCP is up **and** always flip local item + index to COMPLETED.
- **MCP-down fail-open.** When Linear MCP is absent or errors, add/list/close MUST degrade to local-only semantics, emit a single one-line notice, and MUST NOT block, retry-loop, or hard-fail the Surface.
- **MUST NOT commit process trackers.** Skills/commands MUST NOT stage or commit `.claude/backlog*`, `.claude/plans*`, or other process state under `.claude/` as product delivery (v1.0 invariant: `.claude` process state never upstream). Local write-through remains on disk only.
- **MUST inline self-contained content in Linear descriptions.** `/backlog add` MUST inline the actual problem/goal substance in the Linear description — never a bare pointer to a local-only file path (a worktree-relative path, `.claude/plans/**`, `.claude/backlog/**`). Linear is read by teammates and agents with no access to the authoring checkout's disk. A local path MAY be added as a supplementary cross-reference after the inlined substance, never as a substitute for it (origin: CDT-111 — a Linear issue was created pointing solely at a local `.claude/plans/**` file).
- **MUST provide a non-interactive write-back path (contract home).** `skills/backlog/SKILL.md` § Programmatic write-back protocol is the contract home (SPEC-002 D1) for any skill that needs to write a backlog item without a user turn: content pre-supplied (skipping the interactive ask), dedup guard fixed to suffix (the abort branch is unavailable non-interactively), and MCP mode either Linear-first (default) or a caller-declared `--local-only`. Citing callers MUST NOT reimplement this logic independently. Known callers: `skills/brainstorm/SKILL.md` Step 4c, `skills/refactor/SKILL.md` § 2.2a.5 (`--local-only`, SPEC-031), `commands/retro.md` `--auto` mode (SPEC-012).

#### Backlog terminal status classification (CDT-160)

Shared closed/open classification for local item-file `**Status**` values and for
`--linear-verdicts` state strings consumed by reconcile. Contract home for the
matcher is `skills/backlog/terminal-status.sh` (SPEC-002 D1); `close.sh` and
`reconcile.sh` MUST use that single definition — MUST NOT maintain a second
inline copy.

- **MUST** classify a status string as **closed** (terminal) iff, after
  case-fold to uppercase and trim of leading/trailing whitespace, it **token-matches**
  one of:
  - `COMPLETED`
  - `DONE`
  - `FIXED/CLOSED` | `FIXED-CLOSED` | `FIXED CLOSED`
  - `CLOSED`
  - `CANCELLED` | `CANCELED`
- **Token-match (normative).** The status MUST begin with a terminal token above;
  the token boundary is end-of-string **or** a character that is not
  `[A-Z0-9]` (so trailing noise such as ` (CDT-99)`, ` — note`, or a parenthetical
  is allowed). Unanchored substring match is **forbidden** (e.g. `UNDONE` MUST
  stay open; it must not match `DONE`).
- **MUST** treat the following as **open** (not closed): `PENDING`, `DEFERRED`,
  empty/blank item-file status, and any unrecognized string. (Reconcile's
  separate rule that a **blank state in `--linear-verdicts`** means terminal
  remains unchanged — that short-circuit lives in `reconcile.sh` **before** the
  shared matcher is consulted.)
- **Parity (MUST).** For any non-blank status string, `close.sh` (verify +
  re-close idempotency path) and `reconcile.sh` (local prune + verdicts
  classification) MUST return the same closed/open boolean.
- **Write surface (MUST NOT expand).** `close.sh --status` remains
  `COMPLETED|FIXED/CLOSED` only. Classification of `DONE` / `CANCELLED` /
  `CANCELED` / bare `CLOSED` is read-side only (verify, Already-closed, prune) —
  close MUST NOT emit those tokens as the written `**Status**` line.
- **Idempotency (MUST).** When item `**Status**` is already closed per the
  shared matcher, `close.sh` MUST print `Already closed:` and exit 0 without
  rewriting; `close.sh verify` MUST exit 0.

#### Backlog add dedup guard

- MUST NOT write a silent duplicate index row for an existing slug on `/backlog add`. When the
  generated slug already has an index row (or item file), `/backlog add` MUST either (a) append a
  numeric suffix (`-2`, `-3`, …) to create a distinct new slug per the slug-collision rule above,
  or (b) abort with a message naming the pre-existing slug — it MUST NOT append a second row keyed
  to the same slug. This makes duplicate rows for one slug an invariant the index never carries by
  construction, complementing the reconcile collapse step below (which repairs indexes that
  predate this guard).

#### Backlog reconcile (`/backlog reconcile`)

The reconcile subcommand is an **idempotent** repair pass that brings the `.claude/backlog.md`
index into agreement with the `.claude/backlog/<slug>.md` item files (and, when reachable, with
Linear). It is a hygiene operation — it removes dead/duplicate index rows and **prunes** terminal
items, but MUST NOT invent new backlog items. The local write-through is a disposable cache, not
an archive: Linear (when linked) or git/commit history is the durable record for done work, so
reconcile never retains a `## Completed` archive on disk — terminal items are deleted, not moved.

- MUST operate over both stores: the index (`.claude/backlog.md`) and the per-item files
  (`.claude/backlog/<slug>.md`), **including item files with no corresponding index row**
  (orphans — never dual-written via `add`, or predating this convention). It MUST resolve the
  root with the same rule as close/verify (`--root` if set, else `git rev-parse --show-toplevel`,
  else `pwd`) so it edits the local write-through / on-disk process state on the correct worktree
  (not `git-common-dir` alone).

- **Precedence (normative).** For each index entry, the source of truth is determined as follows:
  - **Linear reachable (primary).** When the Linear MCP is reachable AND the index entry has a
    Linear counterpart, Linear issue state is authoritative. An index entry whose Linear issue is
    `Done` / `Cancelled` / `Completed` (or the team's equivalent terminal state) MUST be **pruned**
    — item file deleted, index row dropped.
  - **Linear unreachable, or no Linear counterpart (fallback).** When the Linear MCP is
    unreachable, OR an item has no Linear counterpart, local item-file status is authoritative:
    - Rows whose item file `Status` is **closed** per §"Backlog terminal status
      classification" (including `COMPLETED` / `DONE` / `FIXED-CLOSED` /
      `FIXED/CLOSED` / `CLOSED` / `CANCELLED` / `CANCELED`, case-insensitive,
      token-match) MUST be **pruned** (item file deleted, index row dropped).
    - Index rows with **no** corresponding item file MUST be removed (dead references).
    - Duplicate rows for one slug MUST collapse to a single row (repairs pre-guard indexes; see
      the add dedup guard above).

- **Slug charset validation (normative).** A slug parsed out of an index row (or otherwise used to
  build a path under `.claude/backlog/`) is untrusted input — it is a substring of a file the repo
  (or a synced/imported index) controls. Before a slug is used to construct any path, and therefore
  before any existence check, item-file read, write, or delete, both `reconcile.sh` and `close.sh`
  MUST validate it against `^[A-Za-z0-9_-]+$` — the same charset `skills/worktree-lib.sh`
  `validate_slug()` enforces for worktree slugs. A slug that fails MUST NOT reach the filesystem:
  no `-f` test, no read, no write, no `rm`/`mv`.
  For **reconcile**: its row MUST survive in the rebuilt index and MUST be reported in the run's
  action list, in the style of the `ORPHAN not pruned` notice. An invalid row is specifically
  **not** a dead reference: reconcile never looked for its item file, so it has no evidence either
  way, and dropping the row would discard a possibly-real item on the strength of data it just
  rejected. This closes a path escape — `../../../../etc/foo` is a syntactically valid index-row
  slug that would otherwise resolve outside `.claude/backlog/` and be passed to `rm`.
  For **close.sh**: the same charset MUST be enforced at every site that builds
  `.claude/backlog/<slug>.md` (direct QUERY basename match, index-link resolution in `find_slugs`,
  verify path, close main path, and `update_index` item-file read). Free-text QUERY used only for
  title/substring search may contain spaces and is not itself a slug — guard the *resolved* slug
  before path use. When no path-safe match exists (including when the only index hit is a traversal
  slug), close/verify MUST fail closed with a non-zero exit and an error naming the rejection (or
  "no backlog item matching"); they MUST NOT open, write, or otherwise touch paths outside
  `.claude/backlog/`.
  The guard belongs only where a slug becomes a path. Index bookkeeping over the raw string
  (duplicate detection, first-seen row text, re-emission) touches no filesystem and stays unguarded.
  Slugs read from `--linear-verdicts` need no guard either — they are lookup keys that can mark an
  already-indexed slug terminal but can never introduce a path — and orphan-scan slugs are derived
  from real directory entries, so they cannot escape by construction.

- **Orphan item files (normative).** A file under `.claude/backlog/` with no index row at all MUST
  be classified by its own `Status`:
  - Terminal status → pruned (deleted), same as a completed indexed row.
  - Open or unrecognized status → left untouched on disk and reported (e.g. `ORPHAN not pruned`).
    MUST NOT be deleted (would silently discard un-shipped work with no other record) and MUST NOT
    be auto-added to the index (would be inventing a new item) — resolution is a human decision
    (`/backlog add` to track it properly, or delete it manually if it's stale).

- **Idempotency (MUST).** A second consecutive `/backlog reconcile` run over an already-reconciled
  store MUST produce zero changes (no row removals, no item-file deletions, no diff) other than
  re-reporting any still-unresolved open orphans (a notice, not a state change). Reconcile MUST be
  safe to run repeatedly. A row rejected by slug charset validation re-reports its skip notice on
  every run for the same reason: like an unresolved open orphan it is a notice, not a state change,
  and does not violate this MUST — the store cannot converge until a human repairs the row.

- **Linear path is best-effort (MUST).** The Linear query is best-effort: any MCP failure
  (absent, unauthenticated, timeout, or per-issue error) MUST degrade the affected entries to the
  local item-file fallback above, emit a single one-line notice, and continue — it MUST NOT block,
  retry-loop, or fail the reconcile pass on Linear unavailability. This mirrors SPEC-025 M5's
  degradation posture (Linear preferred when reachable; local write-through always; one-line notice
  on MCP fail). A reconcile run therefore always terminates with a consistent local index even when
  Linear is wholly unavailable. Bash engines MUST retain the `--linear-verdicts` bridge (session
  builds verdicts via MCP; scripts never call MCP).

- Reconcile is a superset-safe complement to the ship-time / wrap-ticket close-out MUSTs above:
  those close specific items named by a plan `closes:` list; reconcile sweeps the whole index for
  drift (dead rows, stale `PENDING` rows for items Linear has since closed, duplicates). It does
  not replace them.

## SHOULD

- SHOULD detect deferred/follow-up items from wrap-ticket learnings and offer to add backlog entries
- SHOULD update Linear issue status at phase transitions in orchestrate (if Linear available)
- SHOULD suggest specific actions in standup (e.g., "ic5 Task 2 looks stale — check context or SendMessage")
- SHOULD group standup output by status: in_progress, pending/ready, pending/blocked, completed
- SHOULD adjust brainstorm complexity assessment based on user answers
- SHOULD add a `--council-tier` row to the `docs/commands/orchestrate.md` Flags table (CDT-206 docs backfill; `--tier` row is MUST above)

## Test

- Verify brainstorm enforces 4-round questioning (no shortcuts)
- Verify kickoff spawns 3 agents in parallel and collects all outputs
- Verify kickoff pauses on >4 open questions from PM
- Verify orchestrate enforces LOC caps on implementation code only
- Verify orchestrate exempts generated code from LOC caps
- Verify standup detects stale tasks (mtime > 30min)
- Verify wrap-ticket blocks on in-progress tasks
- Verify backlog slug generation handles collisions
- Verify `close.sh` closes item + moves index line; verify is idempotent; verify gate fails while PENDING
- Verify `close.sh verify` exits 0 for item Status DONE / CANCELLED / CANCELED / FIXED/CLOSED (with optional trailing noise); exits non-zero for PENDING / DEFERRED / UNDONE
- Verify re-close of an already-DONE (or CANCELLED) item prints `Already closed:` and does not rewrite Status
- Verify `close.sh --status` rejects values other than COMPLETED|FIXED/CLOSED (write surface unchanged)
- Verify shared matcher unit cases: each AC2 terminal token closed; UNDONE and other substring false-positives open
- Verify orchestrate plan includes Tracking/closes and ship DoD runs close on feature worktree
- Verify `/backlog add` for an existing slug never writes a second row keyed to that slug (suffixes `-2`/`-3` or aborts with a message)
- Verify `/backlog reconcile` prunes (deletes item file + drops index row) rows whose item file is closed per shared terminal classification (COMPLETED/DONE/FIXED-CLOSED/CANCELLED/…), removes index rows with no item file (dead refs), and collapses duplicate rows for one slug
- Verify `/backlog reconcile` prunes an item when the Linear issue is Done/Cancelled/Completed and the MCP is reachable (Linear-SoT precedence)
- Verify `/backlog reconcile` degrades to the local item-file fallback with a one-line notice (no block, no fail) when the Linear MCP is unreachable
- Verify `/backlog reconcile` prunes a closed-status orphan item file (no index row) and leaves an open/unrecognized-status orphan untouched and reported, never inventing an index row for it
- Verify a second consecutive `/backlog reconcile` produces zero changes (idempotency)
- Verify `/backlog reconcile` performs no filesystem operation for an index row whose slug is not `^[A-Za-z0-9_-]+$` (e.g. a `../`-traversal slug): no existence check, no read, no delete inside or outside `.claude/backlog/`; the row survives in the rebuilt index, the skip is reported, and the run still exits 0
- Verify `close.sh` (close + verify) performs no filesystem operation for a traversal-shaped or otherwise non-`^[A-Za-z0-9_-]+$` resolved slug (e.g. index row `backlog/../../../canary/pwned.md` matched by title): no path construction that escapes `.claude/backlog/`; canary outside backlog untouched; non-zero exit / clear error; valid sibling slug still closes and verifies
- Verify brainstorm offers backlog/Linear write-back after synthesis is confirmed (unless `/kickoff` runs immediately), and that a filed item's Linear description contains inlined synthesis text, not only a local plan-file path
- Verify the Programmatic write-back protocol's non-interactive callers (refactor auto-chain, retro `--auto`) never hit an interactive ask and never silently write a duplicate slug row on collision (suffix, not abort)
- Verify `parse-flags.sh` omit → `"tier": null`; `--tier=light|standard|full` → matching string; 5-key JSON (`enabled`, `bump`, `source`, `council_tier`, `tier`)
- Verify `--tier` is independent of `--council-tier` and `--autopilot` on one invocation (`--tier=light` does not set `council_tier`; reverse also holds)
- Verify malformed `--tier` exits 64 with stderr and no success JSON: unknown (`skip`, `bogus`, `std`, `max`), empty `--tier=`, bare `--tier`, space form `--tier light`, case (`LIGHT`, `Full`), duplicate `--tier` / `--tier=*` even when values match
- Verify `--tier=<value>` is accepted in any argv position mixed with `--autopilot` / `--council-tier` / `--resume-ship`
- Verify `bash skills/autopilot/test.sh` passes
- Verify `skills/orchestrate/SKILL.md` lists `--tier=light|standard|full`, includes a per-tier table (`standard`/`full` = steps 0–12; `light` = scoper-planner, skip DAG, one IC4, single-pass TL, no council default, wrap-lite), and stays ≤80 lines
- Verify `bash skills/orchestrate/router-static-test.sh` passes; T7 still requires `commands/orchestrate.md` absent; T6 MUST NOT needle bare `--tier`; T10 allows `[ "$ORCH_TIER" = "light" ]` only in 02-scope / 04–10 / 12-wrap and forbids `!=`; T11 else-branch still has PM+TL, DAG, QA spawn, 3-round deadloop
- Verify `docs/commands/orchestrate.md` Flags table documents `--tier` with `standard`/`full` = current pipeline, `light` step map, no `--tier` auto-size at Step 2, independent of `--council-tier`
- Verify Step 0 binds `.tier` from the same `parse-flags.sh` call and a parse 64 halt occurs before fetch/worktree/spawns
- Verify `skills/kickoff/SKILL.md` does not document `--tier`; kickoff still runs when `.tier` is present and unused
- Verify light path: 04 scoper-planner; 07 skip DAG; 08 one `@ic4`; 09 single-pass; 10 no `@qa` spawn; 12 skip 12b (`router-static-test.sh` T12)
- Verify Step 2 auto-size when `[ "$ORCH_TIER" = "null" ]`: S → light, M → standard, L → full; classify-fail → standard; explicit `--tier` skips classify

## Validation

- [ ] Brainstorm output saved to `.claude/plans/<date>-brainstorm-<slug>.md`
- [ ] Kickoff produces spec + task graph
- [ ] Kickoff creates/reuses a worktree (bare `<TICKET-ID>` slug) before the PM/TL spawn and commits spec/plan/CONTEXT.md inside `$WT_PATH` on `feat/<TICKET-ID>` — never on master/current branch
- [ ] Kickoff leaves the worktree in place (no `release`) and prints `$WT_PATH` + branch + resume line
- [ ] Orchestrate creates PR within LOC caps
- [ ] Standup correctly identifies READY vs WAITING tasks
- [ ] Wrap-ticket extracts 3-8 specific learnings
- [ ] Ship closes backlog write-through; Linear In Review on PR-stop / Done on master-land; wrap Done safety net; no staging `.claude/backlog*` into product commits
- [ ] `/backlog reconcile` is idempotent (second run is a no-op) and degrades cleanly with Linear absent
- [ ] `/backlog add` on an existing slug produces no silent duplicate index row
- [ ] `bash skills/backlog/test.sh` passes
- [ ] Brainstorm Step 4c offers backlog/Linear write-back; a filed Linear description is self-contained (no bare local-file pointer)
- [ ] `/orchestrate --tier` parse: omit → JSON `tier` null; `light|standard|full` accepted; malformed → exit 64 before pipeline start (`bash skills/autopilot/test.sh`)
- [ ] `--tier` identity: `standard`/`full` run today's Step 0–12; omit auto-sizes at Step 2; `light` runs the light path; SPEC-033 gates unchanged
- [ ] Orchestrate router lists `--tier` + per-tier table (light = scoper-planner / skip DAG / one IC4 / single-pass TL / no council default / wrap-lite); SKILL.md ≤80 lines; no `commands/orchestrate.md` (`bash skills/orchestrate/router-static-test.sh`)
- [ ] `docs/commands/orchestrate.md` Flags table documents `--tier` (pipeline cost tier; auto-size; independent of `--council-tier`)

## Open Questions

- [x] ~~Should orchestrate's LOC caps apply to generated code?~~ **Resolved: No** — caps apply to hand-written implementation only. Generated code (specs, tests) is exempt.
- [ ] Is the 30-minute staleness threshold for standup appropriate for all project sizes?
- [x] ~~Should wrap-ticket automatically close the Linear issue, or just suggest it?~~ **Resolved: attempt Done when MCP available (fail-open); checklist remains for manual verify. Backlog close is automatic via close.sh.**
- [x] ~~Done at PR-open?~~ **No — Linear In Review until master; Done at master-land or wrap (post-merge).**
- [ ] Should kickoff auto-invoke brainstorm when ticket text is <50 words (too vague)?

## Version History

| Date | Change |
|------|--------|
| 2026-08-21 | CDT-207–210 (epic CDT-205): light-path MUSTs (scoper-planner; skip DAG + one IC4; single-pass TL / no council default / QA-fold / wrap-lite; `--council-tier` override) and auto-size at Step 2 scope-confirm (S→light / M→standard / L→full; explicit `--tier` wins; classify-fail → standard). Branch test is exactly `[ "$ORCH_TIER" = "light" ]`. MUST NOT edit SPEC-033. |
| 2026-08-21 | CDT-206: `/orchestrate --tier=light\|standard\|full` pipeline cost tier. Parse in `skills/autopilot/parse-flags.sh` (JSON key `tier`, five-key stdout, omit → null, no env, no resume persist, duplicate/`=`-only hard-fail 64). Independent of `--council-tier`. Identity: omit/`standard`/`full` = today's Step 0–12 and SPEC-033 gate actors; `light` records only in this child (spawn cuts later). Skill-only Surface (no `commands/orchestrate.md`). MUST NOT edit SPEC-033. |
| 2026-08-03 | Backlog write-back consolidation. Added `skills/backlog/SKILL.md` § Programmatic write-back protocol as the SPEC-002 D1 contract home for non-interactive backlog writes (content pre-supply, dedup fixed to suffix, caller-declared Linear-first/`--local-only`), replacing two independent forks (`skills/refactor/SKILL.md` § 2.2a.5's bespoke inline mkdir/printf/awk, and `commands/retro.md` `--auto` mode's ambiguous direct invocation). Added brainstorm Step 4c (offer backlog/Linear write-back on accepted synthesis) and a MUST that Linear descriptions inline actual substance, never a bare local-only file path — origin: CDT-111, a Linear issue created pointing solely at a local `.claude/plans/**` file unreadable without that checkout. |
| 2026-08-02 | CDT-105: kickoff worktree isolation + resumable-state exit. `/kickoff` now `ensure`s a worktree (bare `<TICKET-ID>` slug) after context load, before the PM/TL spawn, and commits its spec/plan/CONTEXT.md inside `$WT_PATH` on `feat/<TICKET-ID>` — never on master. Fixes the origin defect (standalone `/kickoff` committing straight to master: CDT-104 a049044, CDT-99 0fdf420). Worktree left in place (no `release`) as a documented resumable handoff — the deliberate exception to SPEC-031's implementation-capable-scoped bounded-exit rule. Task graph stays `$MROOT`-anchored. Spec-visibility-until-merge is the intended trade, stated in the summary. SPEC-016 owns the caller-integration form; this spec owns the lifecycle/exit contract. |
| 2026-07-22 | CDT-52 / CDT-46-C6: human-reviewed promote INFERRED→ACTIVE; evidence: Linear CDT-52 ship comment + /spec check exit-0. |
| 2026-07-21 | reconcile subcommand + Linear-SoT precedence + add dedup guard defined (CDT-46-C2). Added `/backlog reconcile` (idempotent index↔item-file repair; Linear-reachable = source of truth for terminal states, local item-file status authoritative on fallback; dead-ref removal; duplicate collapse; best-effort Linear per SPEC-025 M5) and a `/backlog add` dedup guard (no silent duplicate rows for an existing slug). Spec-only; implementation and tests follow. |
| 2026-07-22 | CDT-46-C4: standup user entry moves to `/status` / `/status standup`; bare `/status` sequences standup→metrics→worktree views (read-only). Covers add `commands/status.md`; metrics flag parity under `/status metrics`. |
| 2026-07-14 | Tracking close-out DoD: plan `closes:`, ship-time backlog/Linear close via `close.sh`, wrap-ticket idempotent re-close; worktree `--root` for committed tracker files. |
| 2026-07-22 | CDT-54 / CDT-46-C8: Linear-first add/list/close when MCP up + mandatory local write-through; MCP-down fail-open; process trackers never committed; ship closes local+Linear without staging backlog into product commits; retain `--linear-verdicts` bridge |
| 2026-07-22 | CDT-54 TL review: Overview Linear-first + write-through; reconcile root = local on-disk write-through (not "committed trackers"); SPEC-025 cross-ref aligned to M4/M5 |
| 2026-03-22 | Initial spec generated by /generate-specs |
| 2026-03-23 | Resolved LOC cap exemption for generated code. Clarified escalation: "pause and present to user." Split LOC caps into separate implementation and generated code requirements. |
| 2026-04-09 | Added opt-in `requires_council: true` task metadata + council gate MUSTs in Orchestrate section, per SPEC-013. Gate is per-task opt-in; default min confidence 80 via `council.taskgate.min_confidence`. |
| 2026-04-09 | Added `CLAUDE_TASK_ID` export MUST in Orchestrate section — orchestrator propagates task id to spawned `/council` subprocesses via env var, per SPEC-013 Phase 6 verdict-to-task binding contract. |
| 2026-04-09 | Added per-task metadata storage contract: orchestrator MUST write/update `.claude/tasks/<task_id>.json` at TaskCreate and on every TaskUpdate (atomic write, never deleted), with `requires_council` field read by the SPEC-002 TaskCompleted hook. `$MROOT` resolved worktree-aware so task store is shared across worktrees. |
| 2026-04-28 | Changed task store key from raw integer to compound `<ISSUE-ID>-<task_id>` (e.g. `CDV-QF-FILTER-1.json`) — `TaskCreate` integers reset to 1 for each new Claude process, causing cross-run collisions via upsert. Hook updated to fall back to `*-<task_id>.json` glob (most-recently-modified) when flat-key file not found. |
| 2026-06-13 | Mirrored SPEC-003 MC-4: Kickoff/Orchestrate spawn templates MUST include `Output mode: terse`. Fixed the memory-file warn threshold — was "exceeds 150 lines", now "exceeds its SPEC-004 line limit (cortex 100/memory 50/lessons 80/context 60)", reconciling the conflict with SPEC-004:29 (AUDIT-P1-1). |
| 2026-06-15 | Editorial de-duplication (AUDIT-P3.5b): replaced the stale 5-field task-store schema literal (no `depends_on`) with a pointer to SPEC-017's canonical 6-field schema; pointed standup READY-computation and wrap-ticket uncommitted-worktree MUSTs at their owners (SPEC-017 / SPEC-016). No behavioral change. |
| 2026-07-14 | Cross-ref SPEC-028 (`/fix-ticket`); no behavioral change to orchestrate/kickoff/wrap-ticket. |
| 2026-07-22 | CDT-53 reflect: spawn-template audit names `/spec reflect` (was `/reflect-specs`). Status stays ACTIVE. |
| 2026-07-28 | Reconcile now PRUNES terminal items (deletes item file + drops index row) instead of moving them to `## Completed` — local write-through is a disposable cache, Linear/git history is the durable record. Added orphan-file scan (item files with no index row): terminal-status orphans pruned, open/unrecognized-status orphans reported and left untouched (never auto-indexed, never silently deleted). Fixes CDT-54's local backlog never actually shrinking despite Linear being SoT. |
| 2026-08-07 | Linear lifecycle: In Progress → In Review (PR-stop / off-master) → Done only on master-land or `/wrap-ticket` post-merge. PR-open MUST NOT set Done. |
| 2026-08-07 | CDT-167: TaskCompleted flat/compound meta resolution is shadow-safe (any-true gate; bare stub MUST NOT shadow compound `requires_council: true`). Orchestrate MUST keep compound keys on update-status; invent policy owned by SPEC-017. |
| 2026-08-07 | CDT-175: index-row slugs are untrusted. Reconcile MUST validate `^[A-Za-z0-9_-]+$` (mirroring `worktree-lib.sh` `validate_slug()`) before a slug becomes a path, so a `backlog/../../..` row can never reach the existence check or `rm`. Invalid rows are skipped and reported — never pruned, and never dropped as dead refs (reconcile never looked for the file, so it has no evidence). The recurring skip notice is idempotency-safe under the open-orphan precedent. `--linear-verdicts` slugs (lookup-only) and orphan-scan slugs (directory-derived) need no guard. |
| 2026-08-09 | CDT-192: close.sh path-building slugs are untrusted. The same `^[A-Za-z0-9_-]+$` charset (mirroring CDT-175 / `worktree-lib.sh` `validate_slug()`) MUST be enforced at every site that builds `.claude/backlog/<slug>.md` (find_slugs direct match, index-link resolve, verify, close, update_index). When the only resolved hit is traversal-shaped or otherwise invalid, close/verify fail closed non-zero with no filesystem ops outside the backlog dir — a canary outside backlog stays untouched. Free-text title QUERY remains allowed when it does not resolve to a path-escape slug. |
| 2026-08-07 | CDT-160: shared backlog terminal-status classification. One matcher (`skills/backlog/terminal-status.sh`) used by `close.sh` + `reconcile.sh`; token set COMPLETED/DONE/FIXED{/, -, space}CLOSED/CLOSED/CANCELLED|CANCELED; token-match (not unanchored substring); write surface `--status COMPLETED|FIXED/CLOSED` unchanged; DONE/CANCELLED parity for verify + Already-closed + prune. |

## Cross-references

- SPEC-003: Agent Role System — orchestrate spawns agents by role
- SPEC-008: Spec Management — kickoff creates specs; orchestrate enforces spec-first
- SPEC-010: Code Review & Release — orchestrate triggers review before PR
- SPEC-007: Memory Distillation — wrap-ticket checks distillation threshold
- SPEC-004: Memory Storage — wrap-ticket writes learnings through storage layer
- SPEC-013: Adversarial Council Tribunal — `requires_council: true` task metadata gates TaskCompleted on a council verdict; `--council-tier` / `engine.sh --tier` vocabulary is independent of `/orchestrate --tier`
- SPEC-033: Autopilot Policy — `/orchestrate --tier` MUST NOT change gate ownership, checklists, or BC halt/escalate; this spec MUST NOT edit SPEC-033
- SPEC-002: Plugin Infrastructure — owns the TaskCompleted hook script; council gate logic must be implemented in `task-completed.sh` (cross-spec follow-up required)
- SPEC-028: `/fix-ticket` premise→implement→adversarial-refuters — ticket-workflow family member; does not absorb orchestrate lifecycle, task store, or PR automation
- SPEC-025: Epic Umbrella Decomposition — M4/M5: Linear preferred when MCP up; mandatory local write-through always; local `<EPIC-ID>-C<n>` IDs remain canonical orchestration keys; MCP-down fail-open with one-line notice. `/backlog reconcile` mirrors that posture; reconcile MUST keep the local write-through index consistent with the item files those epics write
