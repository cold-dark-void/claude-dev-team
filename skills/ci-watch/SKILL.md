---
name: ci-watch
description: Use when a ticket's PR checks or local tests should be watched without a human polling — autonomous CI/test watcher that cron-polls every 7 min, spawns a fixer agent on failure (max 3), and self-cleans when green. Prefers durable CronCreate; falls back to session-only when the harness denies durable.
---

# CI Watch

**Not user-invoked — armed by `/orchestrate`** after the first push.

Autonomous CI/test polling and recovery for a single ticket. Once armed by
`/orchestrate` after the first push, a cron drives a self-contained poll
loop until the ticket's PR is green, merged, closed, or the retry cap is
hit. Prefer durable CronCreate when the harness supports it; session-only
is fine while the orchestrator session stays alive.

## Modes

`detect-mode.sh <worktree>` selects exactly one of:

| Mode         | Trigger                                                              | Poll mechanism                              |
|--------------|----------------------------------------------------------------------|---------------------------------------------|
| `ci`         | `.github/workflows/` + `gh auth status` + `gh pr checks`             | `gh pr checks <PR> --json name,state,bucket` |
| `local-test` | `package.json scripts.test` / `Makefile test:` / `go.mod` / `pytest` | `timeout 120 bash -c "<cmd>"` in worktree   |
| `none`       | Neither                                                              | Watch is **not armed** (skipped silently)   |

## Components

```
skills/ci-watch/
├── SKILL.md          (this file)
├── detect-mode.sh    detect ci|local-test|none + test command
├── sidecar.sh        per-ticket JSON state CLI
└── poll.sh           one poll cycle — invoked by the armed cron
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
| `fixer_started_at` | string (epoch)  | cron prompt, set in the same step as `fixer_active` true |
| `empty_poll_count` | integer         | poll.sh (consecutive empty `[]` while workflows exist) |
| `cron_job_id`      | string \| null  | orchestrate sets after CronCreate     |

## poll.sh interface

```
poll.sh <TICKET_ID>
```

- **Exit code:** always `0`. The cron body must not branch on exit status.
- **Stdout:** exactly one word from `{done, fail, cap, wait}`.
- **Side effects:**
  - Atomic sidecar reads via `sidecar.sh`.
  - On transient poll failure: increments `poll_error_count`; emits `wait` while the count is under 10; emits `cap` when the count reaches 10; logs `poll_error`.
    Transient = non-array (or unparseable) `gh pr checks` stdout that is a real error
    (network/auth/etc.), worktree missing, or detect-mode none. **Not** transient:
    `gh` exit 1 or 8 with a parseable JSON array (`jq type == "array"`, incl. `[]`) —
    those are check-state signals (fail / pending). Exit 8 with non-array body is
    pending-with-no-JSON → `wait` without `poll_error_count++`.
  - On real test/check failure with `retry_count < 3`: writes `<TICKET>.last_failure.txt` (head -c 4096 of captured output); emits `fail`.
  - On `retry_count >= 3` with a real failure: emits `cap` (does **not** rewrite last_failure.txt).
  - On `fixer_active == true` with `fixer_started_at` inside `CI_WATCH_FIXER_TTL` seconds (default 1800): emits `wait` (guard — never spawn a second fixer concurrently).
  - On `fixer_active == true` with a missing or older `fixer_started_at`: logs `fixer_stale`, sets `fixer_active` false, increments `retry_count`, writes a stderr notice, and continues the poll.
  - On missing sidecar: emits `wait`.
  - On missing `timeout`, `gtimeout` and `perl` (mode `local-test`, checked before the worktree check): increments `poll_error_count`; emits `wait`; logs `timeout_missing`; writes a stderr hint naming `timeout`, `gtimeout` and `perl`. Otherwise the test runs under `portable_with_timeout` (CDT-284): `timeout`, then `gtimeout`, then a perl supervisor.
  - Appends `<ISO-8601> <TICKET> outcome=<word>` to `<TICKET>.log` for every non-silent outcome.

### Decision matrix

```
sidecar missing         → wait (silent)
fixer_active=true
  fixer_started_at fresh → wait (silent)
  missing or older than CI_WATCH_FIXER_TTL → log fixer_stale, clear the flag,
                         increment retry_count, continue this poll
mode=ci:
  PR MERGED|CLOSED      → done
  gh stdout not array (jq type == "array" fails):
    rc==8              → wait (no poll_error_count++)
    else               → wait (poll_error_count++); cap when the count reaches 10
  parseable array:
    total==0, no .github/workflows → done
    total==0, workflows present    → wait until 3 consecutive empty polls, then done
                         (CI_WATCH_EMPTY_POLLS; a non-empty poll resets the count)
    any fail|cancel    → fail|cap via handle_failure
    all pass|skipping  → done
    else (pending)     → wait (no poll_error_count++)
mode=local-test:
  timeout/gtimeout/perl missing → wait (poll_error_count++, log timeout_missing)
  worktree missing      → wait (poll_error_count++)
  detect-mode = none    → wait (poll_error_count++)
  test rc == 0          → done
  test rc != 0:
      retry_count >= 3  → cap
      else              → fail (write last_failure.txt)
mode unknown            → wait
```

## Cron prompt template

`/orchestrate` Step 8.5 calls `CronCreate` with schedule `"*/7 * * * *"` and
the self-contained prompt below (`<PLUGIN>`, `<MROOT>`, `<TICKET>`, `<PR>`,
`<BRANCH>`, `<WT>` are substituted at arming time). `<PLUGIN>` is the
install-aware plugin root resolved via `plugin-dir.sh` — the cron runs
detached with the user's repo as cwd, so the helper scripts (which live in
the plugin, not the repo) MUST be addressed by their resolved absolute path,
never `<MROOT>/skills/…`.

### Durable flag (harness-aware)

CronCreate `durable` is **not** always available:

| Harness | Behavior |
|---------|----------|
| Claude Code (native) | `durable: true` persists to `.claude/scheduled_tasks.json` and survives session restart |
| cmux (and similar) | `durable: true` is **denied** (not silently downgraded). Session-only crons only |

**Arming rule** (canonical — also restated in orchestrate Step 8.5):

1. If the CronCreate tool schema/description says durable persistence is
   unavailable, or that all jobs are session-only → call once with
   `durable: false`.
2. Otherwise call with `durable: true` first.
3. If that call is rejected with a durable-not-supported / deny message
   (e.g. cmux: *"does not support durable Claude Code cron jobs"*) →
   **immediately retry once** with `durable: false`. Do not treat as fatal.
4. Notify which mode armed:
   - durable: `CI watch armed for <TICKET> in <MODE> mode (cron job: <id>, durable).`
   - session-only: `CI watch armed for <TICKET> in <MODE> mode (cron job: <id>, session-only — ends when this session ends).`

Session-only is still the useful window while the orchestrator is live.
For unattended overnight watching on a harness that lacks durable cron,
use an external scheduler or re-arm after resume — out of scope for v1.

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
   b. bash <PLUGIN>/skills/ci-watch/sidecar.sh set <TICKET> fixer_started_at "$(date +%s)"
   c. bash <PLUGIN>/skills/ci-watch/sidecar.sh inc <TICKET> retry_count
   d. FAIL=$(cat <MROOT>/.claude/ci-watch/<TICKET>.last_failure.txt)
   e. Before spawning the fixer, create the task-store entry:
       bash <PLUGIN>/skills/orchestrate/task-store.sh create "<TICKET>-ci-fixer" "<TICKET> CI-watch hot-fix attempt <retry_count+1>" false ""
       Note the returned task entry — this tracks the fixer in the task store so the orchestrator
       can detect "a fixer is already running" via task store, and so defensive cleanup fires.
   MODEL=$(bash <PLUGIN>/skills/model-map/resolve-model.sh ic5)
   printf '%s\n' "$MODEL"
   EFFORT=$(bash <PLUGIN>/skills/model-map/resolve-model.sh --effort ic5)
   printf '%s\n' "$EFFORT"
   Surface stderr to the user. Bash stdout = model string; empty → omit model. MUST NOT pass "".
   Then `resolve-model.sh --effort` ic5. Non-empty EFFORT → pass as the Task `effort` param; empty → omit (MUST NOT pass `""`).
   Host-reject (invalid/unknown/unsupported model): retry once omitting model;
   warn `model-map: host rejected model '<string>' for ic5; retrying with Tier default`.
   Host-reject (invalid/unknown/unsupported effort): retry once omitting effort;
   warn `model-map: host rejected effort '<token>' for ic5; retrying with inherited effort`.
   Model host-reject stays independent. Ambiguous failure: do not guess; do not combinatorial-retry both params.
   f. Spawn dev-team:ic5 via the Task tool with prompt:
        "Hot-fix only — do not refactor, do not add tests beyond the
         failing one. Push to existing branch <BRANCH>. Worktree: <WT>.
         Output mode: terse.
         Failing output:
         <FAIL>
         When done, run:
           bash <PLUGIN>/skills/ci-watch/sidecar.sh set <TICKET> fixer_active false"
   g. After the fixer completes:
       bash <PLUGIN>/skills/orchestrate/task-store.sh update-status "<TICKET>-ci-fixer" completed
       bash <PLUGIN>/skills/ci-watch/sidecar.sh set <TICKET> fixer_active false
```

The cron body never re-arms itself; it is armed exactly once at setup, and
wrap-ticket tears it down. CronCreate prompts must stay under 4 KiB — the template above
is well within that.

## Cleanup contract

`wrap-ticket` Step 6.5 is the canonical teardown:

```bash
# lint-ok: C3 — marketplace */ for-loop + -f guarded (SPEC-021 Q2 residual, CDT-82 PDH)
PDH=$( { [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/skills/plugin-dir.sh" ] && printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; } || { [ -f skills/plugin-dir.sh ] && [ -f agents/pm.md ] && grep -qF '"name": "dev-team"' .claude-plugin/plugin.json 2>/dev/null && pwd; } || { _pr='${CLAUDE_PLUGIN_ROOT}'; [ "${_pr#\$}" = "$_pr" ] && [ -f "$_pr/skills/plugin-dir.sh" ] && printf '%s\n' "$_pr"; } || { for _mp in "$HOME"/.claude/plugins/marketplaces/*/; do [ -f "${_mp}skills/plugin-dir.sh" ] && [ -f "${_mp}agents/pm.md" ] && printf '%s\n' "${_mp%/}" && break; done; } || find ~/.claude/plugins/cache -path '*/dev-team/*/skills/plugin-dir.sh' 2>/dev/null | awk -F/ '{ver=""; for(i=1;i<=NF;i++) if($i=="dev-team"&&i<NF){ver=$(i+1);break}; if(ver=="") next; m=ver; gsub(/-pre\./,"~pre.",m); p=($0 ~ /\/cache\/cold-dark-void\/dev-team\//)?1:0; print m "\t" p "\t" $0}' | sort -t $'\t' -k1,1V -k2,2n -k3,3 | tail -1 | cut -f3 | xargs -r dirname | xargs -r dirname )
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
- Escalation after the poll-error cap — `poll_error_count` ≥ 10 already emits `cap` and the cron deletes itself.
- Concurrent multi-PR watch on a single ticket.

## AC-12 note (CDV-170)

Repo-wide scan for `if ! …=$(gh ` traps that swallow gh exit 1/8: **only**
`skills/ci-watch/poll.sh` (`poll_ci`) had the pattern. Report-only — no other
scripts needed parallel fixes. The poll.sh fix is Task 1 of CDV-170.
