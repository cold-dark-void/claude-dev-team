# SPEC-017: Autonomous CI Watch + Task DAG

**Status**: ACTIVE
**Category**: core
**Created**: 2026-04-30

**Covers**: `skills/orchestrate/SKILL.md` (router) + `skills/orchestrate/steps/*.md` (CDT-199), `skills/orchestrate/task-graph.md` (WP 1-07), `skills/kickoff/SKILL.md`, `skills/standup/SKILL.md`, `skills/wrap-ticket/SKILL.md`, `skills/orchestrate/task-store.sh`, `skills/orchestrate/dag-lib.sh`, `skills/ci-watch/SKILL.md`, `skills/ci-watch/poll.sh`, `skills/ci-watch/sidecar.sh`, `skills/ci-watch/detect-mode.sh`

---

## Overview

Two coupled features that close the autonomy gap between /orchestrate opening a PR and a
ticket actually being done.

**CI Watch** — after /orchestrate pushes work, a background CronCreate loop monitors
quality checks and auto-spawns a fixer agent on failure, eliminating the manual
"CI is red, go look" cycle. Adapts to the project's actual setup: GitHub Actions CI,
a local test command, or neither.

**Task DAG** — formalizes the `depends_on` field that SPEC-009 standup already
references but which was never defined in the task store schema. Structured dependency
metadata lets /orchestrate fan out unblocked tasks in parallel automatically and lets
/standup compute READY status without parsing prose.

---

## MUST

### Quality-check mode detection

- Before scheduling the CI watch loop, /orchestrate MUST detect the project's quality-check
  mode in this priority order:
  1. `ci` — `.github/workflows/` directory exists **and** `gh pr checks` is available
  2. `local-test` — a test command is detectable: `package.json` has a `test` script,
     or a `Makefile` has a `test` target, or `pytest.ini` / `setup.py` is present,
     or a `pyproject.toml` declares a pytest config (a `[tool.pytest.ini_options]`
     section — bare presence alone does not trigger detection, to avoid false
     positives on non-test pyprojects), or `go.mod` is present (use `go test ./...`)
  3. `none` — skip the watch loop silently; do not notify the user
- MUST re-detect mode per ticket run (mode is not cached globally)

### CI watch loop — scheduling

- In `ci` or `local-test` mode, /orchestrate MUST schedule a CronCreate job immediately
  after the first push of implementation work (not at PR open, since PRs may not exist)
- Poll interval MUST be approximately 7 minutes (`*/7 * * * *`) — an off-minute value per project convention to avoid thundering-herd at :00/:30 boundaries
- The cron job MUST store the detected mode, PR number or branch name (as fallback), and
  retry count in its metadata so it is self-contained across restarts
- **CronCreate `durable` is harness-aware.** MUST prefer `durable: true` when the
  harness supports durable jobs (native Claude Code persists to
  `.claude/scheduled_tasks.json` and survives session restart). MUST NOT hard-fail
  when the harness rejects durable (e.g. cmux denies `durable: true` instead of
  silently downgrading). MUST arm with `durable: false` (session-only) when the
  tool schema/description documents durable as unavailable, or after a single
  durable reject — then notify that the watch ends when the session ends. MUST NOT
  require an external scheduler for the normal live-orchestrator window.

### CI watch loop — ci mode

- Each poll MUST run `gh pr checks <PR-number> --json name,state,bucket` (PR open/closed state is checked separately via `gh pr view --json state`). Pass/fail decisions MUST key off `bucket` — gh's version-stable normalization (`pass`/`skipping`/`fail`/`cancel`/`pending`); `gh pr checks --json` exposes no `conclusion` field
- **`gh pr checks` exit codes are signals, not poll errors.** Documented non-zero exits include `1` (one or more checks failed) and `8` (checks pending). poll.sh MUST capture stdout even when the exit status is non-zero and MUST NOT treat non-zero exit alone as a transient poll error
- **Parseability gate:** stdout is parseable iff `jq` reports `type == "array"` (including the empty array `[]`). Only a non-array (or unparseable) body may increment `poll_error_count` and log `poll_error` — except when exit status is `8` and the body is not a parseable array: MUST emit `wait` **without** incrementing `poll_error_count` (pending with no usable JSON yet)
- Classification after a parseable array (order):
  1. empty array `[]` → treat as no checks configured → green path (`done`)
  2. any element with bucket `fail` or `cancel` → fixer logic (below)
  3. every element bucket `pass` or `skipping` → green path (`done`)
  4. otherwise (pending present, no fail/cancel) → `wait` **without** incrementing `poll_error_count`
- If **all checks resolve green** (every bucket is `pass` or `skipping`, or zero checks): MUST delete the cron job and emit one notification line:
  `CI watch: <TICKET-ID> green on <branch>. Cron deleted.`
- If **any check fails** (bucket `fail` or `cancel`): proceed to fixer logic (see below)
- If PR is merged or closed: MUST delete the cron and exit silently

### CI watch loop — local-test mode

- Each poll MUST run the detected test command in the worktree root
- If **exit code 0**: MUST delete the cron and emit:
  `CI watch: <TICKET-ID> green on <branch>. Cron deleted.`
- If **exit code non-zero**: proceed to fixer logic (see below)

### CI watch loop — fixer logic

- MUST NOT spawn a fixer if one is already running — primary guard is `fixer_active: true` in the sidecar; the cron prompt also creates a `<TICKET>-ci-fixer` task-store entry when spawning so the orchestrator's defensive cleanup can detect stale active fixers
- MUST spawn a `dev-team:ic5` fixer agent with: the failing check names or test output
  (truncated to 4k chars), the worktree path, and the branch name
- MUST increment the retry counter in the cron metadata after each fixer spawn
- MUST cap retries at **3** total spawns; when `retry_count >= 3` and a subsequent poll still shows failure MUST:
  - Delete the cron job
  - Notify the user: `CI watch: 3 fixer attempts failed on <PR/branch>. Manual intervention needed.`
  - NOT spawn another fixer agent

### CI watch loop — cleanup

- /wrap-ticket MUST check for and delete any active CI-watcher cron for the ticket being
  wrapped, regardless of current check state

### Task store schema

- task-store.sh `create` subcommand MUST accept an optional 4th argument `depends_on`
  — a colon-separated list of task IDs (e.g. `CDV-1-2:CDV-1-3`) or empty string for none
- The task JSON schema MUST include a `depends_on` field: an array of task ID strings
  (empty array when no dependencies)
- Example schema:
  ```json
  {
    "task_id": "CDV-1-4",
    "subject": "CDV-1 Task 4 — QA validation",
    "requires_council": false,
    "depends_on": ["CDV-1-2", "CDV-1-3"],
    "created_at": "2026-04-30T10:00:00Z",
    "status": "pending"
  }
  ```
- MUST NOT break backward compatibility — existing task files without `depends_on` MUST
  be treated as `depends_on: []` (no dependencies)
- The schema has two more optional fields (WP 1-07, E8): `plan_ordinal` (integer, the
  plan's "Task N") and `taskcreate_id` (string, the id TaskCreate returned). A new file
  always holds both keys; the value is `null` when the caller does not give it. A file
  without these keys is valid, and readers MUST treat a missing key as `null`.

### Task identity (WP 1-07)

- The task key is `<ISSUE-ID>-<taskcreate_id>`: the issue id, a `-`, and the id that
  TaskCreate returned. The file is `$MROOT/.claude/tasks/<ISSUE-ID>-<taskcreate_id>.json`.
  SPEC-009 (compound key) and SPEC-002 (the TaskCompleted hook finds the file by the
  TaskCreate id) fix this key. MUST NOT key task files by plan ordinal.
- A task id MUST match `^[A-Za-z0-9_-]+$` (no dots, no `/`). `task-store.sh` and
  `dag-lib.sh` MUST use this same rule.
- `depends_on` MUST hold task keys of the same issue in the form above. MUST NOT hold a
  plan ordinal, `Task N`, or `<ISSUE-ID>-N` where N is a plan ordinal. A dep key that
  names no completed task keeps the dependent out of the ready set for ever (a stall).
- `task-store.sh create <task_id> <subject> <requires_council> [depends_on]
  [--plan-ordinal <N>] [--taskcreate-id <ID>]`. The two flags are optional and come after
  the positional arguments. `<N>` MUST match `^[1-9][0-9]*$` and is stored as a number.
  `<ID>` MUST match the task id rule and is stored as a string. When `--taskcreate-id` is
  given, `<task_id>` MUST end with `-<ID>`. A bad flag value exits 2 with no write. An
  unknown flag is a usage error.
- An upsert (`create` on an existing file) sets `plan_ordinal` or `taskcreate_id` only when
  its flag is given. It MUST NOT delete either field.
- `create` MUST print exactly one line on stderr: `created: <path>` for a new file, or
  `upserted: <path> (already existed, updated)` for an existing file.

### Step 7 task-graph protocol (WP 1-07)

- The Step 7 task-graph protocol MUST live in one file, `skills/orchestrate/task-graph.md`.
  `skills/orchestrate/steps/07-tasks.md` and `skills/kickoff/SKILL.md` Step 7 MUST cite it
  by path and MUST NOT restate its fences (the cycle pre-gate or the `task-store.sh create`
  call). Each caller keeps its own TaskCreate description lines.
- Cycle pre-gate: before any TaskCreate, the caller MUST write the plan graph (node ids =
  plan ordinals as strings) to the deterministic file
  `$MROOT/.claude/tasks/dag/<ISSUE-ID>.json`. The path MUST NOT hold `$$` or another
  per-shell value, so a later fence finds the file. The directory is outside the
  `.claude/tasks/*.json` glob that `ready-set`, `/standup`, `/wrap-ticket` and the
  TaskCompleted hook read.
- The check fence MUST branch on the `check-cycle` exit code. Exit 1: print
  `<Caller> error: circular dependency detected: <cycle message>. Revise the task graph.`
  and `exit` non-zero. Any other non-zero: print
  `<Caller> error: cycle gate could not run (rc=<rc>): <stderr>` and `exit` non-zero. The
  prose MUST forbid TaskCreate after either halt, because `exit` stops only that fence's
  shell. The fence deletes the DAG file on every path.
- Phase 1: TaskCreate every plan task in plan order, and record plan Task N → TaskCreate id.
- Phase 2: after all TaskCreate calls, call `task-store.sh create` once per task, with the
  key `<ISSUE-ID>-<id>`, `depends_on` translated through the Phase 1 table, and
  `--plan-ordinal <N> --taskcreate-id <id>`. Two phases are required because a task can
  depend on a later plan task.
- The caller MUST record the table in the plan as `- Task N (id:<ID>): <title>` lines.
- Every `task-store.sh update-status` call MUST pass the same `<ISSUE-ID>-<taskcreate_id>`
  key that `create` used.

### dag-lib.sh contract (WP 1-07)

- Exit codes: `0` success; `1` only for "cycle found" (`check-cycle`); `2` input error
  (`check-cycle` file not found, input not valid JSON or not an array; `status-of`
  ambiguous id); `64` usage error (no subcommand, unknown subcommand, wrong argument count,
  unknown flag, bad `--issue` or task id value) and missing `jq`.
- Callers MUST treat exit 1 as "cycle" and every other non-zero exit as "the check could
  not run". Both MUST stop the caller.
- `check-cycle` MUST be one `jq` program: no bash graph walk, no `declare -A`. It MUST use
  only jq 1.6 builtins and MUST NOT recurse per node (an iterative peel or walk). The
  contract stays: empty array → 0; unknown dep ids are roots (no error); a self-loop is a
  cycle; on a cycle, stderr holds one line `cycle: <from> -> <to>`, where both ids are on
  the cycle.
- `ready-set [--issue <ISSUE-ID>]`. With `--issue`, it emits only tasks whose `task_id` is
  `<ISSUE-ID>-` followed by digits only. So epic-child keys (`<ISSUE-ID>-C1-2`) and
  `<ISSUE-ID>-ci-fixer` are not emitted. Without `--issue`, it emits every ready task (the
  `/standup` view). The completed set is computed over every readable task file.
  `/orchestrate` Step 8 MUST pass `--issue <ISSUE-ID>`.
- `ready-set` MUST skip a task file that is not valid JSON and print one line
  `warning: skipping unreadable task file: <path>` on stderr. It MUST skip, without output,
  valid JSON that is not an object with a string `task_id`. The exit code stays 0.
- `ready-set` MUST report each in-scope `pending` task that has a dep with
  `status == "blocked"` as `blocked-dep: <task_id> <- <dep_id>` on stderr. Stdout MUST stay
  one ready `task_id` per line and nothing else.
- `status-of <task_id>`: an id that fails the task id rule exits 64 and reads no file. The
  exact file wins. Else one `*-<task_id>.json` match is read (as `update-status` resolves
  it); two or more matches exit 2 and name the files on stderr. No match prints `pending`.
- The script MUST run on bash 3.2: no `declare -A`, negative array index, `mapfile`,
  `${var,,}` or `local -n`.

### task-store.sh invent / update-status policy (CDT-167)

Contract home for **writes** to `.claude/tasks/` (reads / TaskCompleted gate: SPEC-002).

- **`create`** invents (or upserts) `$MROOT/.claude/tasks/<task_id>.json` with the caller-supplied
  `requires_council` (`true`|`false`). Orchestrators MUST use compound keys
  `<ISSUE-ID>-<n>` (SPEC-009), where `<n>` is the TaskCreate id (§ Task identity).
- **`update-status <task_id> <status>`** when `$MROOT/.claude/tasks/<task_id>.json` **exists**:
  MUST update only `status`, preserving all other fields (including `requires_council`).
- **`update-status <task_id> <status>`** when the exact dest file is **missing** — invent rules:
  1. Let `matches` = all existing files matching `$MROOT/.claude/tasks/*-<task_id>.json`
     (literal `-` + bare id suffix before `.json`).
  2. If `|matches| == 1`: MUST update `status` on that compound file (do **not** create a bare
     `<task_id>.json`).
  3. If `|matches| > 1`: MUST fail closed (non-zero exit, stderr naming the ambiguity) —
     MUST NOT invent a bare stub and MUST NOT pick one compound arbitrarily.
  4. If `|matches| == 0`: MAY invent a bare stub at `<task_id>.json` with
     `requires_council: false`, subject `(auto-created stub)`, empty `depends_on`, and the
     requested status (session resume / pre-gate path).
- MUST NOT invent a bare `<task_id>.json` with `requires_council: false` while any
  `*-<task_id>.json` compound match exists (would shadow the council gate — AC2).

### /kickoff — task graph population

- /kickoff Step 7 MUST extract dependency information from Tech Lead's plan and pass it
  to task-store.sh `create` for each task, through the Step 7 task-graph protocol above
- If Tech Lead's plan identifies no dependencies for a task, MUST pass empty `depends_on`
- MUST detect circular dependencies in the proposed task graph before calling TaskCreate;
  if a cycle is detected, MUST halt with:
  `Kickoff error: circular dependency detected: <cycle message>. Revise the task graph.`
  The cycle message is the `cycle: <from> -> <to>` line (one edge of the cycle, not the
  full path). `/orchestrate` uses the same text with the prefix `Orchestrate error:`.

### /orchestrate — parallel fan-out

- At orchestration start and after every task status transition to `completed`, /orchestrate
  MUST re-evaluate all `pending` tasks by reading their `depends_on` from the task store
- A task is **unblocked** when all task IDs in its `depends_on` list have `status=completed`
- MUST fan out all currently-unblocked tasks to parallel agents simultaneously (not one at
  a time)
- MUST NOT spawn an agent for a task whose `depends_on` contains any non-completed task ID
- MUST compute the unblocked set with `dag-lib.sh ready-set --issue <ISSUE-ID>` (WP 1-07),
  so tasks of other issues, epic children and `<ISSUE-ID>-ci-fixer` are not fanned out
- MUST mirror every TaskUpdate status change into the task store (`task-store.sh
  update-status`) before it re-runs `ready-set`. Step 8 MUST do this itself; it MUST NOT
  rely on a block that only a later step file holds

### /standup — READY computation

- /standup MUST compute task readiness by reading `depends_on` from task store files
  (not from prose in task descriptions)
- A task is READY when: `status=pending` AND all `depends_on` IDs have `status=completed`
- A task is WAITING when: `status=pending` AND any `depends_on` ID has `status != completed`
- /standup keeps the cross-issue view: it calls `ready-set` without `--issue`

### /orchestrate — ship window record (WP 1-07)

SPEC-010 H6 and H9 own the ship-history gate. This subsection states only where the
orchestrate interactive squash path records the window start. It does not restate D1–D4.

- The squash fence in `skills/orchestrate/steps/11-ship.md` MUST run
  `SHIP_START=$(git rev-parse HEAD)` and `echo "SHIP_START=$SHIP_START"` after
  `cd <main-repo-path>` and before `git merge --squash`.
- The ship-history check fence MUST take the window start from a literal `<SHIP_START>`
  placeholder (the echoed value, or `SHIP_START_SHA` when end-state or `/release` opened
  the window). It MUST NOT read `${SHIP_START:-…}` from an earlier shell. The fence is
  tagged `bash template` and exits 64 when the placeholder was not replaced.
- Every place in `11-ship.md` that describes the `assert-release-allowed` result MUST
  state one rule: any non-zero exit blocks.

### /orchestrate — step file cross-references (WP 1-07)

The router loads only the current step file plus `cross-cutting.md`
(`skills/orchestrate/SKILL.md` Load protocol).

- A step file MUST NOT point at a section of another file with "§ below", "§ above",
  "below" or "above". It MUST name the file that holds the section.
- A block that two or more step files use MUST live in `cross-cutting.md`. This covers
  the Stint-end outcome emit block (SPEC-026 M4) and the Task-store status mirror
  (`task-store.sh update-status`).
- A step file paragraph that names one of these blocks, and is not in the file that holds
  it, MUST name that file: Stint-end outcome emit, Task-store status mirror and Passive
  notifications (`cross-cutting.md`); Linear lifecycle (`11-ship.md`).

---

## SHOULD

- SHOULD log fixer agent spawns to a per-ticket watch log at
  `.claude/ci-watch/<TICKET-ID>.log` for post-mortem review
- SHOULD include the detected quality-check mode in the kickoff summary printout
- SHOULD surface the dependency chain in /standup output next to each WAITING task
  (e.g., `WAITING on: CDV-1-2 (in_progress), CDV-1-3 (pending)`)
- SHOULD preserve existing `depends_on` prose in task descriptions alongside structured
  metadata for human readability

---

## MUST NOT

- MUST NOT run more than one CI-watcher cron per ticket simultaneously
- MUST NOT run more than one fixer agent per ticket simultaneously
- MUST NOT modify the PR description or branch name during fixer retries
- MUST NOT spawn a fixer when PR/branch is merged, closed, or in `none` mode
- MUST NOT key task files by plan ordinal, and MUST NOT put a plan ordinal in `depends_on`
  (WP 1-07; the TaskCompleted council gate would find no file and pass silently)
- MUST NOT write the DAG file, or any other non-task JSON, directly in `.claude/tasks/`

---

## Test

- Verify mode detection: project with `.github/workflows/` → `ci`; project with `go.mod`
  only → `local-test`; bare project → `none` (no cron scheduled)
- Verify `ci` mode: all checks green on first poll → cron deleted, notification emitted
- Verify `ci` mode: one failing check → fixer spawned; retry count incremented
- Verify `ci` mode poll.sh (PATH-mock `gh`, no live network): fail bucket → stdout `fail`;
  fail + `retry_count >= 3` → `cap`; pending-only → `wait` and `poll_error_count` unchanged;
  non-array stdout → `wait` + `poll_error_count++`; empty array `[]` → `done`; exit `8` with
  non-array body → `wait` without `poll_error_count++`
- Verify retry cap: after 3 fixer spawns, 4th failure → cron deleted, user notified, no
  fixer spawned
- Verify fixer guard: second poll while fixer is running → no second fixer spawned
- Verify PR-closed guard: poll detects merged PR → cron deleted silently
- Verify task-store.sh: `create CDV-1-4 "subject" false "CDV-1-2:CDV-1-3"` writes
  `depends_on: ["CDV-1-2","CDV-1-3"]`; `create CDV-1-1 "subject" false ""` writes
  `depends_on: []`
- Verify CDT-167 invent policy: with only `CDT-111-C1-7.json` present,
  `update-status 7 completed` updates that compound file and does **not** create `7.json`;
  with two `*-7.json` files present, `update-status 7 …` exits non-zero; with no matches,
  invent bare stub is allowed
- Verify CDT-167 shadow-safe gate (TaskCompleted template / extracted hook body): compound
  `requires_council: true` + bare stub `requires_council: false` + bare task_id → gate
  applies (exit 2 when index lacks qualifying verdict); pure-missing still exit 0
- Verify backward compat: task file without `depends_on` field → treated as `[]`
- Verify circular dep detection in /kickoff: A→B→A halts with error before any TaskCreate
- Verify /orchestrate fans out Task 1 and Task 2 in parallel when both have empty
  `depends_on`; Task 3 (depends on Task 1) is not spawned until Task 1 completes
- Verify /standup shows Task 3 as WAITING with dependency chain, not READY
- Verify WP 1-07 with the three suites named in `## Acceptance criteria` below:
  `skills/orchestrate/dag-lib-test.sh`, `skills/orchestrate/task-store-test.sh` and
  `skills/orchestrate/router-static-test.sh`
- Verify wrap-ticket deletes active CI-watcher cron

---

## Validation

- [ ] CI mode detection probes `.github/workflows/` first
- [ ] Local-test mode detects at least: package.json test script, Makefile test target, go.mod, pytest markers
- [ ] `none` mode produces no cron and no notification
- [ ] Fixer retry counter resets between ticket runs (stored in cron metadata, not globally)
- [ ] task-store.sh `create` accepts optional `depends_on` arg; backward compat confirmed
- [ ] /kickoff circular dep check fires before any TaskCreate call
- [ ] /orchestrate fans out ≥2 unblocked tasks simultaneously on a ticket with parallel work
- [ ] /standup READY/WAITING computed from task store, not prose

---

## Open Questions

- [x] ~~Should the CI-watcher cron survive a Claude Code session restart?~~ **Resolved:** Prefer `durable: true` on CronCreate when supported (persists to `.claude/scheduled_tasks.json`). On harnesses that deny durable (e.g. cmux), arm session-only (`durable: false`) and surface that the watch ends with the session.
- [x] ~~Should local-test mode run in the worktree or the main repo root?~~ **Resolved:** Worktree root — matches where implementation changes live.
- [ ] Should fixer retries cycle to tech-lead on 3rd attempt instead of ic5? (deferred — current impl always uses ic5)

---

## Version History

| Date | Change |
|------|--------|
| 2026-04-30 | Initial spec — CI watch (3-mode adaptive) + task DAG (depends_on schema + parallel fan-out) |
| 2026-04-30 | Implemented and aligned: poll interval → `*/7` (off-minute convention); unified done notification; fixer guard via sidecar primary + task store secondary; retry cap semantics clarified (3 total spawns); resolved OQ-1 (durable:true) and OQ-2 (worktree root); status → ACTIVE |
| 2026-06-12 | ci-mode poll: `--json name,conclusion` → `name,state,bucket` (`conclusion` was never a `gh pr checks` JSON field; the error was masked as eternal `wait` by the poll_error path). Decisions now bucket-based; skipped checks no longer block green |
| 2026-06-16 | Aligned the local-test detection MUST to `detect-mode.sh`: a `pyproject.toml` triggers `local-test` only when it declares a `[tool.pytest.ini_options]` section (bare presence alone does not), avoiding false positives on non-test pyprojects |
| 2026-07-14 | CDV-170: ci-mode poll MUST NOT treat `gh pr checks` exit 1/8 as poll errors; classification is parseable JSON array (`jq type==array`) + `bucket` only. Exit 8 + non-array → `wait` without `poll_error_count++`. Bite-tests via PATH-mock `gh` required |
| 2026-07-20 | Harness-aware CronCreate durable: prefer `durable: true`; on deny/unavailable (cmux) fall back to session-only once and notify — do not hard-fail arming |
| 2026-08-07 | CDT-167: task-store `update-status` invent policy — no bare false stub when compound `*-<id>.json` exists (single match → update compound; multi → fail closed; zero → bare stub ok). Write-side complement to SPEC-002 shadow-safe TaskCompleted reads. |
| 2026-09-28 | WP 1-07 (CDT-312, CDT-406, CDT-354, CDT-278 E7/E8/F27, rv-w1-08, rv-w1-09): one task identity (`<ISSUE-ID>-<taskcreate_id>` key, optional `plan_ordinal` / `taskcreate_id` fields, deps translated in two phases); one Step 7 task-graph protocol in `skills/orchestrate/task-graph.md` with a deterministic DAG file and real halts; dag-lib exit codes 0/1/2/64, pure-jq `check-cycle`, `ready-set --issue`, corrupt-file skip, `blocked-dep` stderr report, `status-of` id rule; 11-ship records `SHIP_START`; step files name the file of each cross-file block. |

---

## Cross-references

- SPEC-009: Ticket Workflow — extends orchestrate, kickoff, standup, wrap-ticket; formalizes the `depends_on` standup MUST already in SPEC-009
- SPEC-016: Worktree Isolation — CI watch fixer agent targets the ticket's `.worktrees/<slug>` path
- SPEC-002: Plugin Infrastructure — CronCreate is a Claude Code harness primitive; wrap-ticket cleanup hook lives in this layer
- SPEC-010: Release — H6/H9 own the ship-history gate that the 11-ship `SHIP_START` record feeds (WP 1-07)
- SPEC-033: Autopilot Policy — M14(g)/(h) define the `## Acceptance criteria` format below

---

## Acceptance criteria

Format and rules: SPEC-033 M14(g) and M14(h). Each ticket that ships through M14 has one
`### <ticket_id>` subsection below.

### wp-1-07-task-identity-dag

- **A.** `task-store.sh create` accepts optional `--plan-ordinal <N>` and `--taskcreate-id <ID>` after the positional arguments. A new file holds `plan_ordinal` (number or `null`) and `taskcreate_id` (string or `null`). Old 3- and 4-argument calls still work and write both keys as `null`. An upsert without a flag keeps the old value. A bad `<N>`, a bad `<ID>`, or an `<ID>` that is not the end of `<task_id>` exits 2 and writes nothing.
  Verify: bash skills/orchestrate/task-store-test.sh
- **B.** With TaskCreate ids 41, 42 and 43 for plan Tasks 1, 2 and 3 (Task 3 depends on Tasks 1 and 2), a store written the Step 7 way (keys `<ISSUE>-41` to `<ISSUE>-43`, Task 3 `depends_on` = `<ISSUE>-41:<ISSUE>-42`) keeps Task 3 out of `dag-lib.sh ready-set` until both deps are `completed`, and then emits it.
  Verify: bash skills/orchestrate/task-store-test.sh
- **C.** `task-store.sh create` prints exactly one stderr line: `created: <path>` for a new file, or `upserted: <path> …` for an existing file.
  Verify: bash skills/orchestrate/task-store-test.sh
- **D.** The Step 7 task-graph protocol lives only in `skills/orchestrate/task-graph.md`. `steps/07-tasks.md` and `skills/kickoff/SKILL.md` name that path and hold no `"$TASK_STORE" create` call and no `check-cycle` call. `task-graph.md` makes Phase 1 run TaskCreate for every task before Phase 2 calls `task-store.sh create` with translated deps plus `--plan-ordinal` and `--taskcreate-id`. No file of the three maps plan "Task N" to the store key `<ISSUE-ID>-N`, and none says a wrong dep key re-marks dependents as ready.
  Verify: bash skills/orchestrate/router-static-test.sh
- **E.** The DAG file path in `task-graph.md` is the literal `$MROOT/.claude/tasks/dag/<ISSUE-ID>.json` in both the write fence and the check fence, and holds no `$$`. Run in a separate shell in a temp git repo, the check fence finds the file that the write fence wrote: an acyclic graph exits 0, and a 2-cycle exits non-zero with `circular dependency detected` and `cycle:` in its output.
  Verify: bash skills/orchestrate/router-static-test.sh
- **F.** In the check fence of `task-graph.md`, the rc 1 branch prints `circular dependency detected` and runs `exit`; the other non-zero branch prints `cycle gate could not run` and runs `exit`. No `# halt` comment stands in for an `exit`. The prose forbids TaskCreate after a halt.
  Verify: bash skills/orchestrate/router-static-test.sh
- **G.** `dag-lib.sh` exits 64 with no arguments, with an unknown subcommand, with a wrong argument count, and when `jq` is not on `PATH`. It exits 1 only for a cycle, and 2 when the `check-cycle` file is missing or its input is not a JSON array.
  Verify: bash skills/orchestrate/dag-lib-test.sh
- **H.** `check-cycle` is one `jq` program: `dag-lib.sh` holds no `declare -A`, no negative array index and no `mapfile`. It exits 0 for an empty array, a diamond, and an unknown dep. It exits 1 for a self-loop, a 2-cycle and a 3-cycle, with one stderr line that matches `^cycle: [^ ]+ -> [^ ]+$`, where both ids are on the cycle. `-` reads stdin.
  Verify: bash skills/orchestrate/dag-lib-test.sh
- **I.** `ready-set --issue <ISSUE-ID>` emits only ready tasks whose id is `<ISSUE-ID>-` plus digits. It does not emit a ready task of another issue, `<ISSUE-ID>-C1-2`, or `<ISSUE-ID>-ci-fixer`. `ready-set` with no flag still emits all of them. A bad `--issue` value exits 64.
  Verify: bash skills/orchestrate/dag-lib-test.sh
- **J.** `ready-set` skips a task file that is not valid JSON, prints one `warning:` stderr line that names it, still emits the other ready tasks, and exits 0. It never emits a JSON array file or an object with no string `task_id`.
  Verify: bash skills/orchestrate/dag-lib-test.sh
- **K.** A pending task with a dep in status `blocked` gives one stderr line `blocked-dep: <task_id> <- <dep_id>` and is not on stdout. Stdout holds only task ids, one per line.
  Verify: bash skills/orchestrate/dag-lib-test.sh
- **L.** `status-of` exits 64 for `../x`, `a.b` and `a/b` and reads no file. It reads the exact file when present. A bare `7` reads the one `*-7.json` match. Two matches exit 2 and name both files. No match prints `pending`.
  Verify: bash skills/orchestrate/dag-lib-test.sh
- **M.** `steps/08-execute.md` calls `ready-set --issue <ISSUE-ID>`, and its completion steps run the Task-store status mirror before `ready-set`. The mirror fence (`"$TASK_STORE" update-status`) lives in `steps/cross-cutting.md` and not in `steps/09-review.md`. `skills/standup/SKILL.md` still calls `ready-set` with no flag.
  Verify: bash skills/orchestrate/router-static-test.sh
- **N.** In `steps/11-ship.md`, the squash fence runs `SHIP_START=$(git rev-parse HEAD)` and `echo "SHIP_START=$SHIP_START"` after `cd <main-repo-path>` and before `git merge --squash`. The ship-history check fence is tagged `bash template`, sets `SHIP_START="<SHIP_START>"`, and holds no `${SHIP_START:-`. No line that names `assert-release-allowed` says "On exit 64" or "exits 64".
  Verify: bash skills/orchestrate/router-static-test.sh
- **O.** No `steps/*.md` file holds `§ below` or `§ above`. The Stint-end outcome emit block lives in `steps/cross-cutting.md`, not in `steps/08-execute.md`. In every step file other than the home file, each paragraph that names Stint-end outcome emit, Task-store status mirror or Passive notifications also names `cross-cutting.md`, and each paragraph that names Linear lifecycle also names `11-ship.md`.
  Verify: bash skills/orchestrate/router-static-test.sh
- **P.** [process] The suites `skills/orchestrate/dag-lib-test.sh`, `skills/orchestrate/task-store-test.sh`, `skills/orchestrate/router-static-test.sh`, `skills/epic/test.sh` and `skills/model-map/spawn-site-test.sh` pass.
- **Q.** [process] `bash tools/run-all-tests.sh` (the full test runner) exits 0.
- **R.** [process] Every `/release` gate passes (skill-lint, docs-drift, spec check, smoke), with a patch bump.
