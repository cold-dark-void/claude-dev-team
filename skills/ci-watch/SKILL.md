---
name: ci-watch
description: Autonomous CI/test watcher — durable cron polls a ticket's PR checks (or local tests) every 7 min, spawns a fixer agent on failure (max 3), self-cleans when green.
---

# CI Watch

**Not user-invoked — armed by `/orchestrate`** after the first push.

Autonomous CI/test polling and recovery for a single ticket. Once armed by
`/orchestrate` after the first push, a durable cron drives a self-contained
poll loop until the ticket's PR is green, merged, closed, or the retry cap
is hit. No human intervention is required for transient failures.

## Modes

`detect-mode.sh <worktree>` selects exactly one of:

| Mode         | Trigger                                                              | Poll mechanism                              |
|--------------|----------------------------------------------------------------------|---------------------------------------------|
| `ci`         | `.github/workflows/` + `gh` available                                | `gh pr checks <PR> --json name,state,bucket` |
| `local-test` | `package.json scripts.test` / `Makefile test:` / `go.mod` / `pytest` | `timeout 120 bash -c "<cmd>"` in worktree   |
| `none`       | Neither                                                              | Watch is **not armed** (skipped silently)   |

## Components

```
skills/ci-watch/
├── SKILL.md          (this file)
├── detect-mode.sh    detect ci|local-test|none + test command
├── sidecar.sh        per-ticket JSON state CLI
└── poll.sh           one poll cycle — invoked by durable cron
```

State lives at `$MROOT/.claude/ci-watch/<TICKET>.json` plus optional
`<TICKET>.last_failure.txt` (4 KiB cap) and `<TICKET>.log`.

## Sidecar schema

See `sidecar.sh` (single source of truth). Fields managed by this skill:

| Field              | Type            | Owner                                 |
|--------------------|-----------------|---------------------------------------|
| `ticket_id`        | string          | sidecar.sh init                       |
| `mode`             | `ci`/`local-test` | sidecar.sh init                     |
| `pr_number`        | string          | sidecar.sh init (orchestrate)         |
| `branch`           | string          | sidecar.sh init (from `git -C "$WT_PATH" rev-parse --abbrev-ref HEAD` in orchestrate Step 8.5) |
| `retry_count`      | integer         | cron prompt (inc on `fail`)           |
| `poll_error_count` | integer         | poll.sh (inc on transient errors)     |
| `fixer_active`     | boolean         | cron prompt (set true on fail-spawn); fixer agent + wrap-ticket clear |
| `cron_job_id`      | string \| null  | orchestrate sets after CronCreate     |

## poll.sh interface

```
poll.sh <TICKET_ID>
```

- **Exit code:** always `0`. The cron body must not branch on exit status.
- **Stdout:** exactly one word from `{done, fail, cap, wait}`.
- **Side effects:**
  - Atomic sidecar reads via `sidecar.sh`.
  - On transient poll failure: increments `poll_error_count`; emits `wait`; logs `poll_error`.
    Transient = non-array (or unparseable) `gh pr checks` stdout that is a real error
    (network/auth/etc.), worktree missing, or detect-mode none. **Not** transient:
    `gh` exit 1 or 8 with a parseable JSON array (`jq type == "array"`, incl. `[]`) —
    those are check-state signals (fail / pending). Exit 8 with non-array body is
    pending-with-no-JSON → `wait` without `poll_error_count++`.
  - On real test/check failure with `retry_count < 3`: writes `<TICKET>.last_failure.txt` (head -c 4096 of captured output); emits `fail`.
  - On `retry_count >= 3` with a real failure: emits `cap` (does **not** rewrite last_failure.txt).
  - On `fixer_active == true`: emits `wait` immediately (guard — never spawn a second fixer concurrently).
  - On missing sidecar: emits `wait`.
  - Appends `<ISO-8601> <TICKET> outcome=<word>` to `<TICKET>.log` for every non-silent outcome.

### Decision matrix

```
sidecar missing         → wait (silent)
fixer_active=true       → wait (silent)
mode=ci:
  PR MERGED|CLOSED      → done
  gh stdout not array (jq type == "array" fails):
    rc==8              → wait (no poll_error_count++)
    else               → wait (poll_error_count++)
  parseable array:
    total==0           → done
    any fail|cancel    → fail|cap via handle_failure
    all pass|skipping  → done
    else (pending)     → wait (no poll_error_count++)
mode=local-test:
  worktree missing      → wait (poll_error_count++)
  detect-mode = none    → wait (poll_error_count++)
  test rc == 0          → done
  test rc != 0:
      retry_count >= 3  → cap
      else              → fail (write last_failure.txt)
mode unknown            → wait
```

## Cron prompt template

`/orchestrate` Step 8.5 calls `CronCreate` with `durable: true`,
`schedule: "*/7 * * * *"`, and the following self-contained prompt
(`<PLUGIN>`, `<MROOT>`, `<TICKET>`, `<PR>`, `<BRANCH>`, `<WT>` are substituted at
arming time). `<PLUGIN>` is the install-aware plugin root resolved via
`plugin-dir.sh` — the cron runs detached with the user's repo as cwd, so the
helper scripts (which live in the plugin, not the repo) MUST be addressed by
their resolved absolute path, never `<MROOT>/skills/…`:

```
You are the CI-watch poller for <TICKET>. Self-contained: do not assume
session context. Available tools: Bash, Task, CronDelete.

1. Run: bash <PLUGIN>/skills/ci-watch/poll.sh <TICKET>
   Capture stdout — one word from {done, fail, cap, wait}.

2. outcome == "wait" → exit silently.

3. outcome == "done":
   a. CRON_ID=$(bash <PLUGIN>/skills/ci-watch/sidecar.sh get <TICKET> cron_job_id)
   b. Call CronDelete with $CRON_ID.
   c. Run: bash <PLUGIN>/skills/ci-watch/sidecar.sh delete <TICKET>
   d. Notify user: "CI watch: <TICKET> green on <BRANCH>. Cron deleted."

4. outcome == "cap":
   a. CRON_ID=$(bash <PLUGIN>/skills/ci-watch/sidecar.sh get <TICKET> cron_job_id)
   b. Call CronDelete with $CRON_ID.
   c. Notify user: "CI watch: <TICKET> hit 3-retry cap on <BRANCH>. Manual intervention needed."
      (Sidecar is intentionally NOT deleted on cap — preserves last_failure.txt for inspection.)

5. outcome == "fail":
   a. bash <PLUGIN>/skills/ci-watch/sidecar.sh set <TICKET> fixer_active true
   b. bash <PLUGIN>/skills/ci-watch/sidecar.sh inc <TICKET> retry_count
   c. FAIL=$(cat <MROOT>/.claude/ci-watch/<TICKET>.last_failure.txt)
   5a. Before spawning fixer:
       bash <PLUGIN>/skills/orchestrate/task-store.sh create "<TICKET>-ci-fixer" "<TICKET> CI-watch hot-fix attempt <retry_count+1>" false ""
       Note the returned task entry — this tracks the fixer in the task store so the orchestrator
       can detect "a fixer is already running" via task store, and so defensive cleanup fires.
   d. Spawn dev-team:ic5 via Task tool with prompt:
        "Hot-fix only — do not refactor, do not add tests beyond the
         failing one. Push to existing branch <BRANCH>. Worktree: <WT>.
         Output mode: terse.
         Failing output:
         <FAIL>
         When done, run:
           bash <PLUGIN>/skills/ci-watch/sidecar.sh set <TICKET> fixer_active false"
   5c. After fixer completes:
       bash <PLUGIN>/skills/orchestrate/task-store.sh update-status "<TICKET>-ci-fixer" completed
       bash <PLUGIN>/skills/ci-watch/sidecar.sh set <TICKET> fixer_active false
```

The cron body never re-arms itself; it is armed exactly once at setup, and
wrap-ticket tears it down. CronCreate prompts must stay under 4 KiB — the template above
is well within that.

## Cleanup contract

`wrap-ticket` Step 6.5 is the canonical teardown:

```bash
PDH=$( [ -f skills/plugin-dir.sh ] && pwd || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | sort -V | tail -1 | xargs -r dirname | xargs -r dirname )
SIDECAR_CLI=$(bash "$PDH/skills/plugin-dir.sh" file skills/ci-watch/sidecar.sh)
SIDECAR=$(bash "$SIDECAR_CLI" path "$TICKET_ID")
if [ -f "$SIDECAR" ]; then
  CRON_ID=$(jq -r '.cron_job_id // empty' "$SIDECAR")
  # Call the CronDelete tool with $CRON_ID  (tool, not bash)
  bash "$SIDECAR_CLI" delete "$TICKET_ID"
fi
```

Defensive `fixer_active=false` reset also happens inside `wrap-ticket` so a
crashed fixer cannot leave the guard latched if the ticket is wrapped
manually.

## Re-arming

`sidecar.sh init` refuses to overwrite a sidecar whose `cron_job_id` is
non-null — preventing duplicate crons if `/orchestrate` Step 8.5 is
re-entered. To re-arm intentionally, run `wrap-ticket` (or `sidecar.sh
delete <TICKET>`) first.

## Out of scope (v1)

- Cycling fixer agent identity (ic5 → tech-lead on 3rd attempt) — see SPEC-017 Open Question 3.
- Escalation after N consecutive `poll_error` events — for now they accumulate in the counter only.
- Concurrent multi-PR watch on a single ticket.

## AC-12 note (CDV-170)

Repo-wide scan for `if ! …=$(gh ` traps that swallow gh exit 1/8: **only**
`skills/ci-watch/poll.sh` (`poll_ci`) had the pattern. Report-only — no other
scripts needed parallel fixes. The poll.sh fix is Task 1 of CDV-170.
