# Scheduled autonomous retro

Run `/retro --all --auto` unattended on a cadence. Each run writes a
non-interactive report under `$MROOT/.claude/retro/` so success is observable
even when nothing needs fixing.

**Spec:** SPEC-012 §Scheduled autonomous retro (CDV-190)  
**Command:** [`/retro`](../commands/retro.md)  
**Opt-in only** — nothing arms a schedule by default.

---

## Purpose

- Mine cross-session friction weekly without a human at the confirm UI
- Apply safe proposals via full `--auto` semantics; conflicts land in the report
  as **Manual follow-up** (`/adjust-agent …` lines)
- Keep Filter 1 (60s in-progress) and Filter 2 (retro-of-retros) identical to
  interactive `/retro`

**Not in MVP:** CDV-210 tiered notification sink (Slack/Discord MCP). Optional
thin webhook only if `AGENT_WEBHOOK_URL` is set (fail-open).

---

## Prerequisites

| Item | Required? | Notes |
|------|-----------|--------|
| Project with Claude sessions under `~/.claude/projects/` | Yes | `--all` scans all projects |
| dev-team plugin installed / this checkout | Yes | `skills/retro-gate/*` helpers |
| `/setup orchestration` (friction ledger hooks) | Recommended | CDV-186 hybrid S2 when covered; schedule works without it |
| Network / always-on daemon | No | CronCreate or OS cron only |

---

## Cadence

**Recommended example:** weekly **Sunday 06:00 UTC** (`0 6 * * 0`).

User-configurable. Do **not** treat this as a hard-coded default arm.

---

## Arm via Claude CronCreate (primary)

Durable cron, self-contained prompt (ci-watch pattern). The lock is acquired
inside `/retro --all --auto` — do not wrap with a separate lock step.

**Prompt template (copy-paste; substitute `<MROOT>`):**

```
You are the scheduled retro runner for this project. Self-contained.
cwd: <MROOT>. Tools: Bash, SlashCommand (or invoke /retro).

1. Acquire is handled inside /retro --all --auto.
2. Run: /retro --all --auto
3. On completion, print the "Report: <path>" line from the command output.
4. Exit 0. Do not re-arm. Do not open interactive confirms.

Schedule: 0 6 * * 0  (Sun 06:00 UTC)  durable: true
```

Create with Claude Code **CronCreate** (`durable: true`, schedule `0 6 * * 0`).
Keep the prompt under ~4 KiB (same budget as ci-watch cron bodies).

**Disable:** CronDelete for that job id (or your host's equivalent teardown).

---

## OS cron fallback (template — unverified per host)

Exact Claude CLI flags vary by install. Treat this as a **template**, not a
guaranteed one-liner:

```cron
# Sun 06:00 UTC — scheduled retro (CDV-190)
0 6 * * 0 cd <MROOT> && claude -p "/retro --all --auto" >> <MROOT>/.claude/retro/cron.log 2>&1
```

Notes:

- Prefer a non-interactive / print mode if your CLI documents one
- Ensure the job's environment can reach the plugin and `~/.claude/projects/`
- Log to `$MROOT/.claude/retro/` (directory is gitignored)

**Disable:** remove the crontab line (`crontab -e`).

---

## One-shot dry run

1. Interactive confirm: `/retro --all` — review proposals, do not schedule yet
2. Once: `/retro --all --auto` — confirm apply + report path
3. Then arm CronCreate or OS cron

---

## Reports, lock, filters

| Artifact | Path |
|----------|------|
| Report | `$MROOT/.claude/retro/scheduled-YYYY-MM-DDTHHMMSSZ.md` |
| Lock | `$MROOT/.claude/retro/scheduled.lock` (TTL **2h**) |
| Ledger (optional) | `$MROOT/.claude/retro/friction.jsonl` (CDV-186; unrelated prune) |

- **Always write a report** on `--all --auto`, including empty candidate set and
  all-smooth gate exits (schedule observability)
- **Retention:** newest **12** `scheduled-*.md` kept after each successful write
- **Concurrent run:** if lock held and age &lt; 2h → print
  `scheduled retro: lock held, skipping`, exit 0, **no** report
- **Filter 1:** skip JSONL modified within 60s (`freshness.sh`)
- **Filter 2:** skip sessions containing
  `<command-name>/…retro</command-name>` (the scheduled session is skippable
  next week)
- **Stdout:** `Report: /absolute/path/to/scheduled-….md`

---

## Optional webhook (not CDV-210)

If `AGENT_WEBHOOK_URL` is set in the environment of the runner:

- Best-effort `POST` JSON:
  `event=scheduled_retro`, `report_path`, `applied`, `manual_followup`, `timestamp`
- Fail-open, no retry, no MCP

Unset the variable to disable. Full multi-channel sinks remain **CDV-210**.

---

## Helpers (for agents / debugging)

```bash
bash skills/retro-gate/scheduled-lock.sh acquire|release <MROOT>
bash skills/retro-gate/write-scheduled-report.sh --mroot <MROOT> --mode all-auto --note "probe"
bash skills/retro-gate/write-scheduled-report-test.sh
bash skills/retro-gate/scheduled-lock-test.sh
bash skills/retro-gate/scheduled-retro-test.sh
```
