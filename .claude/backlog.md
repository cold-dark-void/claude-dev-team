# claude-dev-team - Backlog Index

## Pending

## Completed

- [External reviewer option](backlog/external-reviewer-option.md) - Optional cross-tool review step in council engine (Codex, Gemini) [COMPLETED]
- [COUNCIL-002 — Investigator tool-call caching](backlog/council-002-tool-call-caching.md) - Avoid redundant file reads across investigators in one run [COMPLETED]
- [COUNCIL-002 — Phase 3 dynamic domain specialist](backlog/council-002-phase3-domain-specialist.md) - Pull devops/ds/qa/pm based on claim topic [COMPLETED]
- [COUNCIL-002 — `/council --from-retro <anchor-id>` scope](backlog/council-002-from-retro-scope.md) - Consume fabrication anchor IDs that /retro already prints [COMPLETED]
- [COUNCIL-002 — `/council --plan <path>` scope](backlog/council-002-plan-scope.md) - Audit a plan file for unverified assumptions [COMPLETED]
- [COUNCIL-002 — Per-phase token usage reporting](backlog/council-002-token-usage-reporting.md) - Cost visibility in council stdout summary [COMPLETED]
- [COUNCIL-002 — `/council --why` flag](backlog/council-002-why-flag.md) - Print flavor presets used + reasoning [COMPLETED]
- [Agent notification sink (tiered)](backlog/agent-notification-sink.md) - Passive agent progress notifications via MCP tools or raw webhook [COMPLETED]
- [Handoff — deeper sidechain reconstruction](backlog/handoff-sidechain-reconstruction.md) - Preserve signal-bearing subagent sidechains (currently no-op) [COMPLETED]
- [COUNCIL-002 — Template `{{TASK_ID}}` placeholder polish](backlog/council-002-task-id-frontmatter-polish.md) - Move {{TASK_ID}} into YAML block proper [COMPLETED]
- [Worktree Skill — User-Invocable `/worktree` Command](backlog/worktree-skill-user-invocable.md) - `/worktree status|list|release` — user-facing worktree management; prerequisite: worktree-lib.sh [COMPLETED]
- [Bootstrap skills — single-root anchoring](backlog/bootstrap-single-root-anchoring.md) - Anchor all .claude/ ops on one resolved project root; fixes subdir-invocation split in scaffold-project / init-orchestration (surfaced by AUDIT-P1-2) [COMPLETED]
- [Handoff — smarter chunk-boundary heuristics](backlog/handoff-chunk-boundary-heuristics.md) - User-turn-boundary chunk cutting in prepass.sh (HANDOFF_CHUNK_SOFT_RATIO, default 0.8) [COMPLETED]
- [Handoff — Prong-1 tool-offload convention](backlog/handoff-prong1-tool-offload-convention.md) - Prevention prong shipped in the /init-orchestration AGENTS.md template (v0.30.2) [COMPLETED]
- [Handoff — cache-eviction policy](backlog/handoff-cache-eviction-policy.md) - Count-cap retention in prepass.sh (HANDOFF_CACHE_MAX_ENTRIES, default 50) [COMPLETED]
- [Bash output compression hook](backlog/bash-output-compression.md) - Implemented via PreToolUse + updatedInput [COMPLETED]
- [Session cost tracking](backlog/session-cost-tracking.md) - DEFERRED — hook payloads lack token data (the v0.23.0 attempt was abandoned) [DEFERRED]
