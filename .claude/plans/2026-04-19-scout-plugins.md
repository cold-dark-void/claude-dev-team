# Plugin Scout Report

```
Time window: 2026-04-05 → 2026-04-19
Current version: dev-team v0.19.6
Candidates scanned: 21
```

---

## STEAL (borrow ideas, not the whole plugin)

### token-optimizer by alexgreensh — 453 stars
What: Full-stack token intelligence — per-turn token breakdown, cost tracking across 4 pricing tiers, 7-signal quality score, loop detection, active compression (delta mode, bash summarization), and a local HTML dashboard. Zero context tokens consumed, fully local SQLite storage.
Idea to steal: **Session cost tracking + quality scoring + loop detection**. dev-team has zero visibility into token/cost burn during orchestration runs. A lightweight PostToolUse hook that accumulates input/output/cache tokens per turn, flags runaway loops (retry spirals), and surfaces a cost summary at session end would close a real gap — especially for `/orchestrate` which can spawn 10+ subagents.
How to apply: New `cost-tracker` hook in `/init-orchestration`; summary in `/standup` and `/wrap-ticket` output; quality score as a field in `/memory-stats`.
Effort: medium
License: PolyForm Noncommercial — cannot adopt wholesale, ideas only.
Source: https://github.com/alexgreensh/token-optimizer

### claude-review-loop by hamelsmu — 648 stars
What: Two-phase review lifecycle — Claude implements a task, then a Stop hook intercepts exit, spawns up to 4 parallel Codex sub-agents for independent review (diff, holistic, framework-specific, UX), then Claude addresses findings before completing. State tracked in `.claude/review-loop.local.md`.
Idea to steal: **Cross-tool adversarial review via stop hook**. dev-team's `/review-commit` uses 5 Claude-only reviewers. The pattern of using an *external* AI (Codex, Gemini, etc.) as an independent reviewer adds genuine diversity of perspective — same-model review has blind-spot correlation. Could be an optional `--external` flag on `/council` or `/review-commit`.
How to apply: Optional external-reviewer step in council engine; new investigator flavor that delegates to an external tool when available.
Effort: medium (needs Codex or similar CLI installed)
Source: https://github.com/hamelsmu/claude-review-loop

### barkain/claude-code-workflow-orchestration — stars N/A
What: Hook-based orchestration with 6 events, 14 scripts, 8 specialized agents, wave-based parallel/sequential execution, and soft enforcement nudges (silent → hint → warning → strong reminder) instead of hard blocks.
Idea to steal: **Soft enforcement nudges + lean startup injection**. dev-team's orchestrate loads full context upfront; this plugin injects a ~1.1KB stub at SessionStart and loads the full orchestrator on-demand, saving ~6.6K tokens on startup. The graduated nudge system is more ergonomic than hard blocks — agents stay productive while being steered toward delegation.
How to apply: Refactor `/orchestrate` SessionStart injection to stub+lazy-load pattern; consider graduated nudges for TDD gate instead of hard PreToolUse blocks.
Effort: low-medium
Source: https://github.com/barkain/claude-code-workflow-orchestration

### RTK (Rust Token Killer) by rtk-ai — 30.1K stars
What: PreToolUse hook intercepts Bash calls, compresses terminal output (smart filtering, grouping, truncation, dedup) before it hits context. 100+ commands, 60-90% reduction.
Idea to steal: **Bash output compression via PostToolUse hook — built in-house, no external binary**. dev-team has zero terminal output compression. A pure-shell or python3 PostToolUse hook that truncates/summarizes test runner output, build logs, and git output would close the gap without trusting a third-party binary in the Bash path. Simpler than RTK (handle the top 10 noisiest commands, not 100+), but owned and auditable.
How to apply: New `bash-compress.sh` PostToolUse hook in `/init-orchestration`. Pattern-match on command prefix (cargo test, npm test, go test, git log, etc.), truncate to summary + first/last N lines of failures. No external deps.
Effort: medium
License: N/A (build our own inspired by the concept)
Source: https://github.com/rtk-ai/rtk

### agent-skills by addyosmani — 17.9K stars
What: 20 lifecycle skills with anti-rationalization tables (excuses + rebuttals that actively counter agent shortcuts), mandatory verification gates, and Google engineering practices (Hyrum's Law, Chesterton's Fence). v0.5.0, April 2026.
Idea to steal: **Anti-rationalization pattern for agent directives**. dev-team agents can rationalize skipping steps ("tests aren't needed for this config change"). agent-skills embeds a table of common excuses and rebuttals per skill. Incorporating this into agent `.md` files or `/adjust-agent` directive templates would harden compliance without adding hard blocks.
How to apply: Add anti-rationalization sections to ic5, ic4, qa agent definitions for their highest-skip-risk behaviors (TDD, spec compliance, review). Template available in `/adjust-agent`.
Effort: low
License: MIT
Source: https://github.com/addyosmani/agent-skills

### Code Review Graph by tirth8205 — 11.4K stars
What: Tree-sitter AST → SQLite knowledge graph → blast radius analysis. MCP server with 28 tools. Only sends structurally *affected* code to reviewers. 8.2x average token reduction, up to 27x on monorepos. 23+ languages, incremental updates.
Idea to steal: **Blast radius pre-filtering before review**. dev-team's `/review-commit` sends full diffs to all 5 reviewers. On large PRs, reviewers read code they don't need. A pre-review step that graph-walks from changed functions to find affected callers/tests, then filters the diff to only include structurally relevant code, would dramatically cut review cost on big repos.
How to apply: Optional `--graph` flag on `/review-commit` that runs a lightweight impact analysis (even without full Tree-sitter — `grep -r` for callers of changed function names) before spawning reviewers with a focused diff.
Effort: medium
License: MIT
Source: https://github.com/tirth8205/code-review-graph

### claude-mem by thedotmack — 46.1K stars
What: Persistent session memory with SQLite + Chroma vector DB, progressive disclosure (3-layer MCP workflow for ~10x token savings), real-time observation feeds to Slack/Discord/Telegram, web viewer UI, Endless Mode for extended sessions.
Idea to steal: **Real-time observation feeds to external channels**. dev-team's memory-capture hook logs observations silently to SQLite. Streaming a filtered subset of observations (task completions, errors, review findings) to a webhook/Slack/Discord channel would give teams passive visibility into agent progress without checking `/standup`. Useful for long `/orchestrate` runs.
How to apply: Optional webhook sink in `memory-capture.sh` (env var `AGENT_WEBHOOK_URL`); fire on task-complete and error events only to avoid noise.
Effort: low
License: AGPL-3.0 — cannot adopt (incompatible with MIT). Ideas only.
Source: https://github.com/thedotmack/claude-mem

---

## WATCH (revisit next scan)

### codex-plugin-cc by OpenAI — v1.0.4 (April 18, 2026)
Cross-tool delegation: `/codex:review`, `/codex:adversarial-review`, `/codex:rescue` (task delegation), `/codex:status`, `/codex:result`. Apache 2.0. Interesting as a signal that cross-tool orchestration is maturing — OpenAI building *into* Claude Code rather than competing. Revisit when dev-team considers multi-model review diversity.
Source: https://github.com/openai/codex-plugin-cc

### MCP Channels (Anthropic, research preview)
MCP servers can now push messages into Claude sessions — Telegram, Discord, webhooks, other services. Still research preview as of April 2026. When stable, this could replace custom webhook implementations for agent-to-human notifications. Monitor for GA.

### Auto Dream (Anthropic built-in)
Built-in feature that addresses memory decay over time in Claude Code's auto-memory. May eventually make some memory plugin features (including parts of dev-team's distillation) redundant. Monitor whether it subsumes tier-based distillation or complements it.

### shinpr/claude-code-workflows — 314 stars, MIT
Stage-based agent specialization (planning → execution → verification → diagnostic). Clean architecture with `design-sync` cross-layer conflict detection and diagnostic phase (investigator → verifier → solver). Different philosophy from dev-team's role-based agents. Worth studying the diagnostic phase pattern.
Source: https://github.com/shinpr/claude-code-workflows

### RTK by rtk-ai — 30.1K stars, MIT
Third-party Rust binary that proxies all Bash output. Impressive token savings but significant trust surface — an opaque binary intercepting every tool call is a security/privacy concern. The *idea* (bash output compression) is stolen above as a build-our-own enhancement. Revisit only if RTK open-sources an auditable build pipeline or if Claude Code ships native output compression.
Source: https://github.com/rtk-ai/rtk

### Context Mode by mksglu — 8K stars, ELv2
MCP server that sandboxes tool output into SQLite with FTS5 instead of dumping into context. 315KB → 5.4KB (98% reduction). Agents generate analysis scripts instead of reading raw data. Interesting paradigm ("LLMs as code generators, not data processors") but ELv2 license is restrictive and it's an MCP server layer, not a plugin. Monitor for MIT alternatives or native Claude Code support.
Source: https://github.com/mksglu/context-mode

### julep-ai/memory-store-plugin
Queue-based producer-consumer memory with team-wide shared context and CLAUDE.md anchor synchronization. Requires external service (beta.memory.store) which limits adoption. The CLAUDE.md sync concept is interesting for multi-developer scenarios.
Source: https://github.com/julep-ai/memory-store-plugin

---

## SKIP (already covered or not relevant)

- **Anthropic official code-review** — 4 parallel agents + confidence scoring. dev-team's `/review-commit` already has 5 specialists with identical confidence threshold (80). Covered.
- **Anthropic official "Remember" plugin** — Daily logs + Haiku compression. dev-team's 3-tier distillation with semantic search is more sophisticated. Covered.
- **claude-mem** (adoption) — AGPL-3.0 license incompatible with MIT. Ideas stolen above.
- **token-optimizer** (adoption) — PolyForm Noncommercial license incompatible with MIT. Ideas stolen above.
- **Superpowers** — Already inspired dev-team features (v0.11.0 brainstorm, v0.19.0 tdd-gate). Covered.
- **Ultraship / TDD Guard** — TDD enforcement. dev-team's `/tdd-gate` already covers this. Covered.
- **skill-creator** (Anthropic official) — Meta-skill for building skills. Not in dev-team's mission scope.
- **agent-observability** (nexus-labs) — 5 stars, 2 commits. Too early, mostly guidance docs.
- **Manifest** — OpenClaw-focused cost tracking. Different ecosystem.
- **Claude Token Optimizer** (nadimtuhin, 111 stars) — Documentation restructuring templates. dev-team's tiered memory already does selective loading. Very simple approach.
- **Token Optimizer** (alexgreensh, adoption) — PolyForm Noncommercial license. Ideas stolen above.

---

## Proposed Enhancements — Disposition

All items resolved. Summary:

| Enhancement | Disposition | Version |
|-------------|------------|---------|
| Bash output compression hook | **SHIPPED** (unblocked via PreToolUse + updatedInput after /council audit) | v0.22.0 |
| Session cost tracking | **DEFERRED** (v0.23.0 attempt abandoned — hook payloads lack token data; tracked in `.claude/backlog/session-cost-tracking.md`) | — |
| Anti-rationalization directives | **SHIPPED** | v0.19.7 |
| Blast radius pre-filter (`--impact`) | **SHIPPED** | v0.20.0 |
| Agent notification sink (tiered) | **BACKLOG** | — |
| External reviewer option | **BACKLOG** | — |
| Lazy orchestrator injection | **SHIPPED** | v0.19.8 |
| Graduated TDD nudges | **SHIPPED** | v0.21.0 |
