---
name: orchestrate
description: |
    Use when a ticket should run end-to-end without the user driving each
    phase — full lifecycle orchestrator that fetches issue context, creates a
    worktree, spawns agents end-to-end, enforces tech-lead review loops, and
    optionally ships a PR. You stay as observer/navigator; agents do all the
    work. Usage: /orchestrate CDV-1 or /orchestrate
---

# Orchestrate

End-to-end issue orchestration. You (the main Claude) do NOT write code — you
observe, coordinate agents, track progress, and escalate. Implementation happens
in agent worktrees. Phase bodies live in `steps/` — this file is the router.

## Arguments

- `/orchestrate <ISSUE-ID>` — Linear or prompt for context
- `/orchestrate` — prompts for issue ID
- `[--autopilot[=<token>]]` — SPEC-033 / CDT-195; full contract: `steps/00-resolve.md`
- `[--council-tier=<skip|light|full>]` — CDT-126; `steps/00-resolve.md` + `steps/09-review.md`
- `[--resume-ship[=<patch|minor|major|master>]]` — CDT-135/195; `steps/11-ship.md`
- `[--tier=<light|standard|full>]` — CDT-206; `steps/00-resolve.md` + `steps/02-scope.md`
- `[--max-loc=<n|unbound>]` — CDT-223; `steps/00-resolve.md`
- `[--with-advisor[=<model>]]` — SPEC-039 M9/M10/M37; `steps/00-resolve.md`
- `[--concurrency N]` — SPEC-013 CDT-573; this file § Council-gate concurrency passthrough

| `--tier` | Steps | pipeline |
|----------|-------|----------|
| omit / `standard` / `full` | 0–12 | today's pipeline (`full` = `standard`) |
| `light` | 0–12 | scoper-planner; skip DAG; one IC4; single-pass TL; no council default; wrap-lite |

No `--tier`: Step 2 auto-sizes S→light / M→standard / L→full (cheap signals, no extra spawn). Explicit `--tier` wins.

## Council-gate concurrency passthrough (CDT-573)

`/orchestrate <ID> --concurrency N` (also `--concurrency=N`, any position) caps council
fleet spawns at `N` in flight per wave, `N` an integer ≥ 1, no ceiling. Step 0 stores the
user's token verbatim in `ORCH_CONCURRENCY` — empty when the flag is absent. This run
resolves and validates nothing: no resolver call, no env read, no Model map read. The
engine's preflight owns that one merge and exits 64 on a bad value — print it and stop, never retry unbounded.

Pass `--concurrency "$ORCH_CONCURRENCY"` as the last token of every `/council` and
`/review-and-commit` invocation the run makes; omit it when empty. Sites: Step 6c
`/council --plan <approved-plan-path>`, the Step 8 addendum and Step 9 task-gate
`/council "<CLAIM>" --task-id <task_id>`, and the M14 ship gate
(`skills/autopilot/ship-gate-council.md` §3b).

The cap is fleet-only: the Step 8 IC DAG spawns, the Step 4 kickoff PM/TL spawns, the
single council-judge spawn, and advisor spawns MUST NOT carry the flag, a batching
instruction, or the `Spawn contract:` line (SPEC-013 § CDT-573 AC2 — the IC DAG is not a fleet).

## Load protocol

Read **only the current phase**. Do not Read every `steps/*.md` up front.

1. Resolve plugin root with `plugin-dir.sh` (PDH stanza is in `steps/00-resolve.md`).
2. Once at start: Read `skills/orchestrate/steps/cross-cutting.md`.
3. Read `skills/orchestrate/steps/<file>` for the step you are executing.
4. After a step finishes, Read the next file. Do not keep all phases loaded.

`STEP=$(bash "$PDH/skills/plugin-dir.sh" file skills/orchestrate/steps/<file>)` then Read `$STEP`.

| Step | File | What |
|------|------|------|
| 0 | `00-resolve.md` | Roots, memory, autopilot, council-tier, tier, max-loc, advisor, resume |
| 1 | `01-fetch.md` | Linear / backlog / freeform |
| 2 | `02-scope.md` | Scope-confirm gate |
| 3 | `03-worktree.md` | Branch, worktree, glossary 3b |
| 4 | `04-kickoff.md` | Parallel PM + Tech Lead |
| 5 | `05-questions.md` | Open questions |
| 6 | `06-design.md` | TL plan, plan-approve, glossary 6b, security council 6c |
| 7 | `07-tasks.md` | DAG + task-store |
| 8 | `08-execute.md` | Spawn, monitor, CI-watch 8.5, stint-end |
| 9 | `09-review.md` | TL review, council gate, simplify 9.5 |
| 10 | `10-qa.md` | QA + spec alignment 10b |
| 11 | `11-ship.md` | Ship, Linear, tracking, worktree cleanup |
| 12 | `12-wrap.md` | Wrap + friction 12b |
