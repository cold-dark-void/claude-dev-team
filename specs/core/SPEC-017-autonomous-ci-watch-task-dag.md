# SPEC-017: Autonomous CI Watch + Task DAG

**Status**: ACTIVE
**Category**: core
**Created**: 2026-04-30

**Covers**: `skills/orchestrate/SKILL.md`, `skills/kickoff/SKILL.md`, `skills/standup/SKILL.md`, `skills/wrap-ticket/SKILL.md`, `skills/orchestrate/task-store.sh`, `skills/orchestrate/dag-lib.sh`, `skills/ci-watch/SKILL.md`, `skills/ci-watch/poll.sh`, `skills/ci-watch/sidecar.sh`, `skills/ci-watch/detect-mode.sh`

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

### /kickoff — task graph population

- /kickoff Step 7 MUST extract dependency information from Tech Lead's plan and pass it
  to task-store.sh `create` for each task
- If Tech Lead's plan identifies no dependencies for a task, MUST pass empty `depends_on`
- MUST detect circular dependencies in the proposed task graph before calling TaskCreate;
  if a cycle is detected, MUST halt with:
  `Kickoff error: circular dependency detected: <cycle path>. Revise the task graph.`

### /orchestrate — parallel fan-out

- At orchestration start and after every task status transition to `completed`, /orchestrate
  MUST re-evaluate all `pending` tasks by reading their `depends_on` from the task store
- A task is **unblocked** when all task IDs in its `depends_on` list have `status=completed`
- MUST fan out all currently-unblocked tasks to parallel agents simultaneously (not one at
  a time)
- MUST NOT spawn an agent for a task whose `depends_on` contains any non-completed task ID

### /standup — READY computation

- /standup MUST compute task readiness by reading `depends_on` from task store files
  (not from prose in task descriptions)
- A task is READY when: `status=pending` AND all `depends_on` IDs have `status=completed`
- A task is WAITING when: `status=pending` AND any `depends_on` ID has `status != completed`

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
- Verify backward compat: task file without `depends_on` field → treated as `[]`
- Verify circular dep detection in /kickoff: A→B→A halts with error before any TaskCreate
- Verify /orchestrate fans out Task 1 and Task 2 in parallel when both have empty
  `depends_on`; Task 3 (depends on Task 1) is not spawned until Task 1 completes
- Verify /standup shows Task 3 as WAITING with dependency chain, not READY
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

---

## Cross-references

- SPEC-009: Ticket Workflow — extends orchestrate, kickoff, standup, wrap-ticket; formalizes the `depends_on` standup MUST already in SPEC-009
- SPEC-016: Worktree Isolation — CI watch fixer agent targets the ticket's `.worktrees/<slug>` path
- SPEC-002: Plugin Infrastructure — CronCreate is a Claude Code harness primitive; wrap-ticket cleanup hook lives in this layer
