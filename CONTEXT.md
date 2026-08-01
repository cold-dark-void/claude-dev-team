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
| State now | Deterministic packet header from tail of event log: latest decisions, unkilled hypotheses, opens | freeform Convergence essay |
| Escalation gate | Enforced checkpoint before any implementation-capable skill edits a file, deciding ticket/worktree/PR weight | escalation ladder (as synonym once gate lands) |
| Workstream split | A chosen approach decomposing into 2+ independently shippable ideas, routing to /epic child tickets instead of a single /kickoff ticket | bundled ticket, mega-PR |
