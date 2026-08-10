# /retro

Session retrospective. Reviews past host session(s) (Claude Code and Grok) for friction patterns and proposes targeted behavioral adjustments — either directives for team agents (routed through `/adjust-agent`) or lessons appended to project-local Claude memory.

## Usage

```
/retro
/retro <session-id>
/retro --host claude|grok|all
/retro --host grok <session-id>
/retro --all
/retro --auto
/retro --why
```

## Flags

| Flag / Argument | Description |
|-----------------|-------------|
| `<session-id>` | Host session id. Claude: UUID basename under `~/.claude/projects/`. Grok: session dir id under the cwd bucket (`…/<sid>/chat_history.jsonl`). Default: most recently modified session for the selected host. |
| `--host claude\|grok\|all` | Transcript host adapter (CDT-156). Default: auto-detect — prefer resolvable `GROK_SESSION_ID` / `GROK_TRANSCRIPT_PATH`, else newest mtime across Claude project dir + Grok live-cwd bucket (`HOST_CWD`/`WTROOT`). Bare `--all` without `--host` ⇒ `--host all`. Explicit `--host grok` with no session → clear error (**no** Claude fallback). |
| `--all` | Walk candidate sessions for the selected host(s), pre-filter singletons, surface only patterns that recurred across 2+ sessions. Claude: every project under `~/.claude/projects/`. Grok MVP: live-cwd bucket only (`urlencode(HOST_CWD)` under `${GROK_SESSIONS_DIR:-~/.grok/sessions}/`). |
| `--auto` | Skip the per-proposal confirm UI. Apply every surviving proposal. Conflicts from `/adjust-agent --apply` are surfaced as a manual follow-up list rather than silently dropped. |
| `--why` | Print the matched signals (and which signals did NOT match) for every gated session. Used to calibrate the gate when it under- or over-triggers. |

## Examples

**Default — review the most recent session:**
```
/retro
```
Auto-detects host (Grok env pins → newest mtime across Claude project dir + Grok `HOST_CWD` bucket), runs the friction gate, and either exits with `No sessions to retro.` or proceeds to the deep-read phase. Pass `--host claude|grok` to force one adapter.

**Grok session by id:**
```
/retro --host grok <session-id>
```
Locates `…/sessions/<urlencode(HOST_CWD)>/<session-id>/chat_history.jsonl`. No Claude fallback if missing.

**Cross-session pattern mining:**
```
/retro --all
```
Bare `--all` without `--host` ⇒ `--host all`. Walks Claude projects + Grok live-cwd bucket, gates each candidate, and surfaces only patterns that show up in 2 or more flagged sessions. Singletons are dropped (with a stderr log of each drop).

**Apply everything without confirming:**
```
/retro --auto
```
Skips the confirm/reject/edit prompts. Each proposal is auto-applied: team-agent proposals route through `/adjust-agent <agent> --apply "<text>"` (which fails fast on conflict), and Claude proposals append to `$MROOT/.claude/memory/claude/lessons.md`. Conflicts are collected and printed at the end as a manual follow-up list.

**Calibrate the gate:**
```
/retro --why
```
Prints the per-session score, threshold, matched signals (with anchor IDs), and unmatched signals. Use this when `/retro` says "No sessions to retro" but you remember a session being frustrating — the `--why` output tells you which signals missed and by how much.

## How it works

`/retro` is a two-phase pipeline. Phase 1 is cheap and runs on every candidate session; phase 2 only runs on sessions that pass.

1. **Session discovery** — multi-host locate via `skills/transcript-parse/hosts.py` (Claude under `~/.claude/projects/`; Grok under `${GROK_SESSIONS_DIR:-~/.grok/sessions}/<urlencode(HOST_CWD)>/` where `HOST_CWD` is the live worktree path / `WTROOT`, not the monorepo `MROOT`). Default mode picks the newest source for the selected host (auto-detect when `--host` omitted). `--all` expands candidates per host scope. Explicit `<session-id>` is host-scoped (`--host grok` never falls back to Claude).
2. **Filter — in-progress** — **source** paths modified within the last 60 seconds are excluded (`freshness.sh`; applies to Claude JSONL and Grok `chat_history.jsonl`).
3. **Normalize** — Grok sources are converted to a Claude-shaped scoring feed (TMPDIR); Claude is identity. Gate always reads the normalized path.
4. **Filter — retro-of-retros** — sessions whose source **or** gate feed contains a `<command-name>/…retro</command-name>` marker are excluded. Prevents loops where `/retro` repeatedly analyzes its own output.
5. **Phase 1: friction gate** — `skills/retro-gate/gate.sh` runs five regex/heuristic signals (S1 explicit reject, S2 consecutive tool errors, S3 edit loops, S4 assistant retry phrases, S5 terse follow-ups), scores each session, and flags those above the threshold. Smooth sessions exit immediately with `No friction detected — nothing to retro.`
6. **Phase 2: deep-read subagent** — for each flagged session, a general-purpose subagent reads the JSONL anchored at the friction message IDs, identifies root causes, and proposes concrete behavioral rules. Every proposal must cite at least one message ID with a verbatim excerpt. The subagent classifies each proposal's target as one of the 7 team agents or `claude` (plain Claude). Proposals without citations, with empty/oversized text, with control characters, or matching obvious prompt-injection patterns are rejected at ingest.
7. **Routing & dedup** — surviving proposals are classified against the existing rule corpus for their target. `NEW` (no overlap), `TIGHTEN` (partial overlap — existing rule is rewritten with the new evidence merged in), or `DUPLICATE` (existing rule already covers the pattern but didn't prevent recurrence — surfaced as advisory only). Anti-sprawl sweep: `NEW` proposals are dropped if a `TIGHTEN` exists for the same `pattern_summary`.
8. **Apply** — default mode shows each proposal with target, action, text, and cited evidence, then prompts `[a]pply / [r]eject / [e]dit / [s]kip remaining`. `--auto` mode applies everything without prompting. Team-agent proposals route through `/adjust-agent` (default mode prints the slash command for you to run; `--auto` invokes `/adjust-agent <agent> --apply`). `claude` proposals append to `$MROOT/.claude/memory/claude/lessons.md`.
9. **Summary** — count of applied / rejected / duplicate / manual-followup / observation rows, plus the new directive count for each affected agent so you can watch the pile grow.

## Integration with /kickoff and /orchestrate

`/kickoff` (Step 9) and `/orchestrate` (Step 13) run the phase-1 friction gate at completion. If the gate fires on the just-finished session, they print a one-line `Consider: /retro <session-id>` hint. They never auto-run `/retro` and never block completion — the hint is just a nudge to retro the session yourself if you found it frustrating.

## Scheduled runs (`--all --auto`)

When **both** `--all` and `--auto` are set, `/retro` is the scheduled autonomous
path (SPEC-012 / CDV-190):

- Writes `$MROOT/.claude/retro/scheduled-YYYY-MM-DDTHHMMSSZ.md` (including empty
  or all-smooth runs) and prints `Report: <absolute-path>`
- Acquires `$MROOT/.claude/retro/scheduled.lock` (2h TTL) so concurrent cron
  fires no-op cleanly
- Keeps the newest 12 `scheduled-*.md` reports
- Full `--auto` apply semantics; conflicts → manual follow-up section in the report
- Filter 1 / Filter 2 unchanged

**Arming is opt-in** (no default cron). Copy-paste CronCreate + OS cron fallback,
cadence example (weekly Sun 06:00 UTC), disable steps, and optional
`AGENT_WEBHOOK_URL`: **[Scheduled retro runbook](../runbooks/scheduled-retro.md)**.

CDV-210 tiered notification sink is **out of scope** for this path.

## What `/retro` does NOT do

- **Does not modify `AGENTS.md` or `~/.claude/CLAUDE.md`.** Project-wide and global rules are out of scope; each eng↔Claude interaction is project-specific.
- **Does not auto-apply without `--auto`.** Default mode always confirms per proposal.
- **Does not write `directives.md` files directly.** Team-agent proposals always go through `/adjust-agent`, preserving SPEC-001's holistic-rewrite and conflict-detection guarantees.
- **Does not retro the session it was invoked in.** The retro-of-retros filter and the in-progress filter both block this. Retro a session from a fresh session if you want to analyze a session where `/retro` was invoked.
- **Does not install hooks, intercept user messages, or run in the background.** It's a one-shot command you invoke when you want to retro something. (Scheduled mode is still opt-in external cron invoking the same command — not a daemon inside the plugin.)

## See Also

- `/adjust-agent` — the apply target for team-agent directive proposals; supports `--apply` non-interactive mode used by `/retro --auto`
- [Scheduled retro runbook](../runbooks/scheduled-retro.md) — CronCreate / OS cron scaffold for `/retro --all --auto`
- [`/kickoff`](./kickoff.md) — runs the friction gate at completion and suggests `/retro` if it fires
- [`/orchestrate`](./orchestrate.md) — same friction-check hook at the end of an orchestration run
- [`/recall`](./recall.md) — search past sessions, memory, and git history (broader search, no scoring or proposals)
