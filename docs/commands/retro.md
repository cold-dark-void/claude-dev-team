# /retro

Session retrospective. Reviews past Claude Code session(s) for friction patterns and proposes targeted behavioral adjustments — either directives for team agents (routed through `/adjust-agent`) or lessons appended to project-local Claude memory.

## Usage

```
/retro
/retro <session-id>
/retro --all
/retro --auto
/retro --why
```

## Flags

| Flag / Argument | Description |
|-----------------|-------------|
| `<session-id>` | UUID basename of a specific JSONL under `~/.claude/projects/`. Default: most recently modified session in the current project. |
| `--all` | Walk every project's sessions, pre-filter singletons, surface only patterns that recurred across 2+ sessions. |
| `--auto` | Skip the per-proposal confirm UI. Apply every surviving proposal. Conflicts from `/adjust-agent --apply` are surfaced as a manual follow-up list rather than silently dropped. |
| `--why` | Print the matched signals (and which signals did NOT match) for every gated session. Used to calibrate the gate when it under- or over-triggers. |

## Examples

**Default — review the most recent session:**
```
/retro
```
Picks the newest `.jsonl` in this project, runs the friction gate, and either exits with `No sessions to retro.` or proceeds to the deep-read phase.

**Cross-session pattern mining:**
```
/retro --all
```
Walks every project's sessions, gates each one, and surfaces only patterns that show up in 2 or more flagged sessions. Singletons are dropped (with a stderr log of each drop).

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

1. **Session discovery** — finds candidate JSONL files in `~/.claude/projects/<encoded-project>/`. Default mode picks the most recently modified file. `--all` walks all projects. Explicit `<session-id>` validates the UUID shape and locates the file.
2. **Filter — in-progress** — sessions modified within the last 60 seconds are excluded. They're still being written by an active Claude session.
3. **Filter — retro-of-retros** — sessions whose JSONL contains a `<command-name>/dev-team:retro</command-name>` marker are excluded. Prevents loops where `/retro` repeatedly analyzes its own output.
4. **Phase 1: friction gate** — `skills/retro-gate/gate.sh` runs five regex/heuristic signals (S1 explicit reject, S2 consecutive tool errors, S3 edit loops, S4 assistant retry phrases, S5 terse follow-ups), scores each session, and flags those above the threshold. Smooth sessions exit immediately with `No friction detected — nothing to retro.`
5. **Phase 2: deep-read subagent** — for each flagged session, a general-purpose subagent reads the JSONL anchored at the friction message IDs, identifies root causes, and proposes concrete behavioral rules. Every proposal must cite at least one message ID with a verbatim excerpt. The subagent classifies each proposal's target as one of the 7 team agents or `claude` (plain Claude). Proposals without citations, with empty/oversized text, with control characters, or matching obvious prompt-injection patterns are rejected at ingest.
6. **Routing & dedup** — surviving proposals are classified against the existing rule corpus for their target. `NEW` (no overlap), `TIGHTEN` (partial overlap — existing rule is rewritten with the new evidence merged in), or `DUPLICATE` (existing rule already covers the pattern but didn't prevent recurrence — surfaced as advisory only). Anti-sprawl sweep: `NEW` proposals are dropped if a `TIGHTEN` exists for the same `pattern_summary`.
7. **Apply** — default mode shows each proposal with target, action, text, and cited evidence, then prompts `[a]pply / [r]eject / [e]dit / [s]kip remaining`. `--auto` mode applies everything without prompting. Team-agent proposals route through `/adjust-agent` (default mode prints the slash command for you to run; `--auto` invokes `/adjust-agent <agent> --apply`). `claude` proposals append to `$MROOT/.claude/memory/claude/lessons.md`.
8. **Summary** — count of applied / rejected / duplicate / manual-followup / observation rows, plus the new directive count for each affected agent so you can watch the pile grow.

## Integration with /kickoff and /orchestrate

`/kickoff` (Step 9) and `/orchestrate` (Step 13) run the phase-1 friction gate at completion. If the gate fires on the just-finished session, they print a one-line `Consider: /retro <session-id>` hint. They never auto-run `/retro` and never block completion — the hint is just a nudge to retro the session yourself if you found it frustrating.

## What `/retro` does NOT do

- **Does not modify `AGENTS.md` or `~/.claude/CLAUDE.md`.** Project-wide and global rules are out of scope; each eng↔Claude interaction is project-specific.
- **Does not auto-apply without `--auto`.** Default mode always confirms per proposal.
- **Does not write `directives.md` files directly.** Team-agent proposals always go through `/adjust-agent`, preserving SPEC-001's holistic-rewrite and conflict-detection guarantees.
- **Does not retro the session it was invoked in.** The retro-of-retros filter and the in-progress filter both block this. Retro a session from a fresh session if you want to analyze a session where `/retro` was invoked.
- **Does not install hooks, intercept user messages, or run in the background.** It's a one-shot command you invoke when you want to retro something.

## See Also

- [`/adjust-agent`](./adjust-agent.md) — the apply target for team-agent directive proposals; supports `--apply` non-interactive mode used by `/retro --auto`
- [`/kickoff`](./kickoff.md) — runs the friction gate at completion and suggests `/retro` if it fires
- [`/orchestrate`](./orchestrate.md) — same friction-check hook at the end of an orchestration run
- [`/recall`](./recall.md) — search past sessions, memory, and git history (broader search, no scoring or proposals)
