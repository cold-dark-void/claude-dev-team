# claude-dev-team - Backlog Index

## Pending

- [Promote the p0-fix-workflow into the plugin as /fix-ticket](backlog/fix-ticket-workflow-promotion.md) - Ship the proven premise→impl→refuters workflow as a first-class command [PENDING]
- [Rate-limit resilience for adversarial refuter fleets](backlog/refuter-rate-limit-resilience.md) - Formalize orchestrator self-verification fallback with explicit degraded-run marker [PENDING]
- [/metrics — observability rollup command](backlog/metrics-rollup-command.md) - Rollup of local-agent metrics.jsonl, council verdicts, retro trends [PENDING]
- [Fix retro-gate S3 false positives on draft-then-polish authoring](backlog/retro-gate-s3-draft-polish-false-positive.md) - Exclude same-session Write-then-Edit polish from the S3 edit-loop signal [PENDING]
- [Scheduled autonomous /retro --all](backlog/scheduled-autonomous-retro.md) - Weekly cron retro with passive result delivery; pairs with notification sink [PENDING]
- [Local-agent expansion: /debug + /refactor consumers, egress allowlist](backlog/local-agent-expansion.md) - Wire the two documented future consumers + bwrap network egress restriction [PENDING]

- [Bootstrap skills — single-root anchoring](backlog/bootstrap-single-root-anchoring.md) - Anchor all .claude/ ops on one resolved project root; fixes subdir-invocation split in scaffold-project / init-orchestration (surfaced by AUDIT-P1-2) [PENDING]

- [Handoff — deeper sidechain reconstruction](backlog/handoff-sidechain-reconstruction.md) - Preserve signal-bearing subagent sidechains (currently no-op) [PENDING]

- [COUNCIL-002 — `/council --plan <path>` scope](backlog/council-002-plan-scope.md) - Audit a plan file for unverified assumptions [PENDING]
- [COUNCIL-002 — `/council --from-retro <anchor-id>` scope](backlog/council-002-from-retro-scope.md) - Consume fabrication anchor IDs that /retro already prints [PENDING]
- [COUNCIL-002 — Phase 3 dynamic domain specialist](backlog/council-002-phase3-domain-specialist.md) - Pull devops/ds/qa/pm based on claim topic [PENDING]
- [COUNCIL-002 — `/council --why` flag](backlog/council-002-why-flag.md) - Print flavor presets used + reasoning [PENDING]
- [COUNCIL-002 — Per-phase token usage reporting](backlog/council-002-token-usage-reporting.md) - Cost visibility in council stdout summary [PENDING]
- [COUNCIL-002 — Investigator tool-call caching](backlog/council-002-tool-call-caching.md) - Avoid redundant file reads across investigators in one run [PENDING]
- [COUNCIL-002 — Template `{{TASK_ID}}` placeholder polish](backlog/council-002-task-id-frontmatter-polish.md) - Move {{TASK_ID}} into YAML block proper [PENDING]
- [Agent notification sink (tiered)](backlog/agent-notification-sink.md) - Passive agent progress notifications via MCP tools or raw webhook [PENDING]
- [External reviewer option](backlog/external-reviewer-option.md) - Optional cross-tool review step in council engine (Codex, Gemini) [PENDING]
- [Worktree Skill — User-Invocable `/worktree` Command](backlog/worktree-skill-user-invocable.md) - `/worktree status|list|release` — user-facing worktree management; prerequisite: worktree-lib.sh [PENDING]

## Completed

- [Handoff — smarter chunk-boundary heuristics](backlog/handoff-chunk-boundary-heuristics.md) - User-turn-boundary chunk cutting in prepass.sh (HANDOFF_CHUNK_SOFT_RATIO, default 0.8) [COMPLETED]
- [Handoff — Prong-1 tool-offload convention](backlog/handoff-prong1-tool-offload-convention.md) - Prevention prong shipped in the /init-orchestration AGENTS.md template (v0.30.2) [COMPLETED]
- [Handoff — cache-eviction policy](backlog/handoff-cache-eviction-policy.md) - Count-cap retention in prepass.sh (HANDOFF_CACHE_MAX_ENTRIES, default 50) [COMPLETED]
- [Bash output compression hook](backlog/bash-output-compression.md) - Implemented via PreToolUse + updatedInput [COMPLETED]
- [Session cost tracking](backlog/session-cost-tracking.md) - DEFERRED — hook payloads lack token data (the v0.23.0 attempt was abandoned) [DEFERRED]
