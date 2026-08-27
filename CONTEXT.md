# Domain Glossary

Project ubiquitous language. Prefer these terms in code, specs, tickets, and
agent output. Do not reintroduce avoided aliases.

## Terms

| Term | Definition | Avoid (aliases) |
|------|------------|-----------------|
| Surface | Any user-invocable command or skill; the unit of the v1 stability contract | command (when skills are included), feature |
| Deprecation stub | A one-cycle command file whose only behavior is printing its replacement, shipped because marketplace auto-latest makes silent removal user-visible breakage | alias, shim |
| STM packet | Short-term `/handoff` artifact: jury-style evidence for days–months session continuity (compact seed after fork/compact `@file`) | summary, status brief, executive handoff |
| Through-line | Ordered believed→tried→killed→decided→open (plus verified facts) without tool dumps | chronological tool narrative |
| Compact seed | File intended as primary context after fork/compact `@file` | inject brief, cold-only dump |
| Spine-mine | Extract through-line events from session JSONL on disk (warm or cold shared engine) | memory rewrite, freeform warm summary |
| State now | Deterministic packet header from tail of event log: optional provenance-constrained `### Where we are`; Product surfaces, Open ship gaps, latest decisions, unkilled hypotheses, opens | freeform Convergence essay |
| Product surfaces | Named primary UX plus unfinished / do-not-treat-as-product; required STM State now field | UI notes, implied surface |
| Open ship gaps | Unshipped product work called out in STM State now (not every open question) | leftover TODOs (as a substitute for the section) |
| Escalation gate | Enforced checkpoint before any implementation-capable skill edits a file, deciding ticket/worktree/PR weight | escalation ladder (as synonym once gate lands) |
| Workstream split | A chosen approach decomposing into 2+ independently shippable ideas, routing to /epic child tickets instead of a single /kickoff ticket | bundled ticket, mega-PR |
| Autopilot mode | Opt-in `--autopilot[=<bump>]` on /orchestrate, /kickoff, /epic: gates self-answered per checklist, decision recorded as a decision-card; halts to human on any blocking condition (SPEC-033) | automagic, unattended mode |
| decision-card | Append-only JSONL record of one gate answer, halt, or reroute; schema frozen in SPEC-033 AC6 | audit entry, log line |
| blocking-condition | One of 8 ordered checks (BC1-BC8) evaluated before a gate answer; 7 halt, BC5 (complexity-overflow) reroutes instead (SPEC-033 AC2) | blocker, guard rail |
| run-budget | Per-run caps — 25 stints / 45 min wall-clock by default — that trip BC6 when exceeded (SPEC-033 AC3) | rate limit, timeout |
| complexity-overflow | LOC/workstream/task-graph/spec/subsystem/wall-clock criteria that non-blockingly reroute a run to /epic decompose (BC5, SPEC-033 AC4) | scope creep, ticket bloat |
| Instruction stack | Ordered CLAUDE.md / AGENTS.md / directives layers hosts inject (user-global → parents → project) | prompt files, rules soup |
| Context audit | Read-only inventory of the instruction stack plus skill-size WARN; writes are a separate approve-then-apply step | doctor alone |
| Approve-then-apply | Explicit user approval before any instruction-stack write; never silent rewrite | auto-fix, silent rewrite |
| Mechanical evidence | Two cited passages plus counts and a date/mtime-vs-tag or spec quote | I-know-best, feels stale |
| Transcript mirror | Live per-session compressed record (`main.md` + channel sidecars) | live log, shadow transcript |
| Meaning channel | User + assistant text; retained spine of the transcript mirror | clean text |
| Channel sidecar | Per-kind cold-storage file referenced from `main.md` via `@ref` | attachment |
| Meaning tail | Bounded sibling file `<store-root>/<sid>.meaning-tail.md`: stripped Meaning-channel turn-blocks, UTF-8 `wc -c` ≤ 32768, produced by `/compact-transcript` for the operator to `@` | Compact seed, STM packet, compact transcript (as a glossary alias for `main.md`) |
| Verbatim original | Cold copy of a Meaning-channel turn body replaced by an on-demand LLM overlay; file `<sid>/verbatim/<turn-id>.txt`; `@ref` from `main.md`. Not a Channel sidecar. | Channel sidecar, Meaning tail, Compact seed, STM packet |
| Model map | Layered per-agent agent→model-string mapping; precedence local > repo > global > tier | model config, model overrides |
| Tier default | Shipped frontmatter alias (`opus`/`sonnet`/`haiku`) encoding role capability intent; final fallback of the Model map | hardcoded model |

## Decisions

- 2026-08-23: Transcript-mirror storage root is global `~/.claude/transcript/<sid>/`, not `$MROOT` — identity is the session, not the repo.
- 2026-08-23: Compact seed MUST NOT extend to `main.md` — that term stays with STM packet / `/handoff`.
- 2026-08-23: Transcript-mirror enablement is hook registration itself (default off; never in default `/setup orchestration`).
- 2026-08-26: Meaning tail is the `/compact-transcript` sibling file. Compact seed stays STM packet / `/handoff`. Do not map Compact seed onto `main.md` or the meaning-tail file.
- 2026-08-26: Verbatim originals live in `<sid>/verbatim/` (optional extra dir). Overlay is on-demand `summarize-transcript` only. Channel sidecar taxonomy stays three kinds.
- 2026-08-26: Model map is layered per-agent routing only. Tiers remain the SoT for role capability intent. Shipped `agents/*.md` defaults stay unchanged.
- 2026-08-26: CDT-222 phase 1 reads only `$MROOT/.claude/dev-team/models.local.json`. Repo/global layers are specified, not read.
