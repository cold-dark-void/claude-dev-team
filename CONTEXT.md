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
