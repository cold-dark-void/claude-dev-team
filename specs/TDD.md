# Behavioral Specifications

## Spec Index

| ID | Title | Status | Coverage |
|----|-------|--------|----------|
| SPEC-001 | Per-Agent Directives | ACTIVE | commands/adjust-agent.md, agents/*.md (directives loading) |
| SPEC-002 | Plugin Infrastructure | INFERRED | .claude-plugin/plugin.json, marketplace.json, .claude/settings.json, hooks/task-completed.sh, tools/scout-plugins |
| SPEC-003 | Agent Role System | INFERRED | agents/pm.md, tech-lead.md, ic5.md, ic4.md, devops.md, qa.md, ds.md, commands/adjust-agent.md |
| SPEC-004 | Memory Storage & Migration | INFERRED | skills/memory-store/SKILL.md, schema.sql, migrate-md.sh, migrate-v2.sh |
| SPEC-005 | Team Bootstrap | INFERRED | agents/project-init.md, commands/setup.md (`/setup team\|project\|orchestration`), commands/init-team.md (stub), download-extensions.sh, skills/scaffold-project, init-orchestration, demo |
| SPEC-006 | Memory Retrieval & Search | INFERRED | commands/memory.md (`/memory search`), skills/memory-recall (stub), recall.md |
| SPEC-007 | Memory Distillation | INFERRED | agents/distiller.md, commands/memory.md (`/memory distill|config|stats`) |
| SPEC-008 | Spec Management | INFERRED | commands/spec.md (`/spec <sub>`), skills/spec-tooling/ |
| SPEC-009 | Ticket Workflow | INFERRED | skills/kickoff, orchestrate, brainstorm, commands/status.md (`/status` + standup), standup (tombstone), wrap-ticket, backlog |
| SPEC-010 | Code Review & Release | INFERRED | skills/review-and-commit, release |
| SPEC-011 | Memory Validation | ACTIVE | commands/memory.md (`/memory validate`), skills/memory validate (stub), `/memory distill` integration, skills/memory-store/migrate-v3.sh, skills/memory-store/migrate-v4.sh (`--reconcile` cross-agent) |
| SPEC-012 | Session Retrospective | APPROVED | commands/retro.md, skills/retro-gate (incl. trial-meta/trial-review CDV-200), skills/retro-subagent, skills/transcript-parse/, skills/kickoff + orchestrate hooks |
| SPEC-013 | Adversarial Council Tribunal | ACTIVE | skills/council/ (engine), commands/council.md, skills/review-and-commit/SKILL.md (preset refactor), /retro + TaskCompleted hooks |
| SPEC-014 | Debug Workflow | APPROVED | commands/debug.md, skills/debug/SKILL.md, skills/debug/theme-status.sh (SPEC-029 gates); fix-ticket stubs → `/debug ticket` |
| SPEC-015 | Refactor Workflow | APPROVED | skills/refactor/SKILL.md |
| SPEC-016 | Worktree Isolation | ACTIVE | skills/worktree-lib.sh, commands/worktree.md (release only), commands/status.md (`/status worktree`), skills/orchestrate, wrap-ticket, AGENTS.md |
| SPEC-017 | Autonomous CI Watch + Task DAG | ACTIVE | skills/orchestrate/SKILL.md, skills/kickoff/SKILL.md, skills/standup/SKILL.md, skills/wrap-ticket/SKILL.md, skills/orchestrate/task-store.sh, skills/orchestrate/dag-lib.sh, skills/ci-watch/SKILL.md, skills/ci-watch/poll.sh, skills/ci-watch/sidecar.sh, skills/ci-watch/detect-mode.sh |
| SPEC-018 | Session Handoff (cold + warm) | ACTIVE | skills/handoff/, commands/handoff.md, skills/transcript-parse/ (consumed; owned by SPEC-012), skills/retro-gate/gate.sh (refactor) |
| SPEC-019 | Local-Agent Offload via OpenCode | DEPRECATED | skills/local-agent/run.sh, skills/local-agent/SKILL.md, skills/local-agent/emit-orch-metric.sh, skills/orchestrate/SKILL.md, skills/standup/SKILL.md, AGENTS.md |
| SPEC-020 | Loop-Prompt Architect (/craft-loop) | ACTIVE | commands/craft-loop.md, skills/craft-loop/SKILL.md, program-template.md, examples/ |
| SPEC-021 | Skill-Bash Lint Gate | ACTIVE | skills/skill-lint/check-skill-bash.sh, lint.py, SKILL.md, test.sh, fixtures/, skills/release/SKILL.md (Step 4.8 only) |
| SPEC-022 | /doctor Install & Config Diagnostics | ACTIVE | commands/doctor.md, skills/doctor/doctor.sh, skills/doctor/SKILL.md, skills/doctor/test.sh |
| SPEC-023 | Release Train Queue | ACTIVE | commands/release-train.md, skills/release-train/SKILL.md, skills/release-train/train-lib.sh, skills/release/SKILL.md (skip-if-present), .gitignore |
| SPEC-024 | Memory Seed Packs | ACTIVE | commands/memory.md (`/memory export`), commands/init-team.md (Step 5.5), skills/memory-store/{export,import}-seed-pack.sh, seed-common.sh, test-seed-pack.sh, agents/project-init.md |
| SPEC-025 | /epic Umbrella Decomposition | ACTIVE | commands/epic.md, skills/epic/{SKILL.md,epic-lib.sh,test.sh}, skills/standup/SKILL.md (Step 5.5), skills/wrap-ticket/SKILL.md (Step 6.7), skills/orchestrate/dag-lib.sh (check-cycle reuse) |
| SPEC-026 | Review-Outcome Ledger & Adaptive Agent Routing | ACTIVE | skills/metrics/emit-outcome.sh, skills/metrics/outcome-rates.sh, skills/metrics/test.sh, skills/orchestrate/SKILL.md (scoped) |
| SPEC-027 | /incident War-Room & Postmortem | DEPRECATED | commands/incident.md, skills/incident/SKILL.md, timeline.sh, timeline-test.sh, workspace.sh |
| SPEC-028 | Premise → Implement → Adversarial Refute (`/debug ticket`) | ACTIVE | `/debug ticket` entry (SPEC-014); commands/fix-ticket.md + skills/fix-ticket (stubs CDT-46-C4); workflow.js optional |
| SPEC-029 | Debug Reopen & Multi-Surface Done Gates | ACTIVE | skills/debug/SKILL.md, skills/debug/theme-status.sh, SPEC-014 checklist, .claude/debug/themes/ |
| SPEC-030 | Smoke Harness Gate | ACTIVE | tools/smoke/run.sh, tools/smoke/smoke.py, tools/smoke/test.sh, tools/smoke/fixtures/, .github/workflows/smoke.yml, skills/release/SKILL.md (Step 4.10 only) |
## Version History

| Date | Change |
|------|--------|
| 2026-03-16 | SPEC-001 drafted and implemented (v0.15.0) |
| 2026-03-22 | Initial spec baseline generated by /generate-specs (SPEC-002 through SPEC-010) |
| 2026-03-23 | SPEC-001 reformatted for /reflect-specs compliance; all specs reviewed and updated |
| 2026-03-23 | SPEC-011 created: Memory Validation — stale reference detection, multi-stage pipeline, /memory-distill integration |
| 2026-04-07 | SPEC-012 created: Session Retrospective — /retro command, two-phase friction gate + subagent deep-read, routes through /adjust-agent |
| 2026-04-09 | SPEC-013 created: Adversarial Council Tribunal — /council engine skill, blind investigators, tech-lead judge, feedback-memory learning loop, /review-and-commit refactor |
| 2026-04-26 | SPEC-014 implemented — skills/debug/SKILL.md shipped |
| 2026-04-26 | SPEC-015 implemented — skills/refactor/SKILL.md shipped |
| 2026-04-26 | /reflect-specs fixes: SPEC-013 status NEW→ACTIVE, corrected coverage paths (dev-team:council→skills/council/, commands/review-and-commit.md→skills/review-and-commit/SKILL.md), removed spec-file self-reference from SPEC-015 coverage |
| 2026-04-28 | SPEC-016 created: Worktree Isolation — canonical `.worktrees/<slug>` path, worktree-lib.sh CLI, PID-based lock, collision recovery |
| 2026-04-29 | SPEC-013 updated: Phase 2.5 Blind Cross-Review added (COUNCIL-002) — Borda-count peer ranking, anonymized bundles, self-exclusion, WEAK_EVIDENCE flagging |
| 2026-04-30 | SPEC-017 created: Autonomous CI Watch + Task DAG — adaptive 3-mode CI watch loop, structured depends_on schema, parallel fan-out in orchestrate |
| 2026-06-04 | SPEC-018 created: Cold Session Handoff — retroactive `/handoff <uuid>`, deterministic pre-pass + size-adaptive spine + specialized fan-out extractors, anti-gaslighting dead-ends payload; conflict-scanned (shared parser w/ SPEC-012, M5 delegates to /council, cache outside memory.db) |
| 2026-06-04 | SPEC-018 updated (CDV-10): +M10 warm live-capture mode, +M11 consolidation (replaces personal handoff skill); Phase-1 includes size-adaptive chunking |
| 2026-06-05 | SPEC-018 implemented via CDV-10 (Tasks 1-14): status NEW→ACTIVE; coverage skills/transcript-parse/, skills/handoff/, commands/handoff.md, skills/retro-gate/gate.sh (refactor) |
| 2026-06-15 | SPEC-002 updated: bash-compress MUST rewritten to the shipped inline-rewrite design; vestigial bash-compress-wrapper.sh deleted (AUDIT-P3.5a) |
| 2026-06-15 | SPEC-004 updated: schema.sql added to Covers; migrate-v2/v3 log-table FK clauses (REFERENCES memories(id)) aligned to schema.sql (AUDIT-P3.5a) |
| 2026-06-15 | Editorial spec hygiene across specs/core (AUDIT-P3.5b): normalized 3 emoji-prefixed Status lines (SPEC-012/014→APPROVED, SPEC-013→ACTIVE) and SPEC-018 Category Core→core; de-duplicated SPEC-009 task-store schema→SPEC-017, SPEC-003 directives→SPEC-001, SPEC-007/011 busy_timeout→SPEC-004; refreshed SPEC-012 Covers + added the transcript-parse seam MUST; reordered SPEC-013 + this index's Version-History rows chronologically; reworded SPEC-005 + demo cleanup to SPEC-016's separate-call worktree teardown |
| 2026-06-15 | SPEC-013 Judge cortex-inheritance reconciled to reality (AUDIT-P4.4): relaxed the Phase-5 "MUST inherit tech-lead cortex" to OPTIONAL engine-prepended calibration (no injection is implemented; the `tools: ""` Judge is by-design evidence-only); updated the Overview line + validation checkbox; aligned `agents/council-judge.md` (dropped impossible Read-tool checklist step + false cortex-injection assertion) and de-duplicated `skills/council/prompts/judge.md`. Docs-only; no engine/spawn change |
| 2026-06-16 | SPEC-019 created: Local-Agent Offload via OpenCode — opt-in, default-off offload of mechanical/machine-verifiable work (ic4-class impl, discovery, docs) to a local model via `opencode run`; static per-agent routing + per-task machine-check gate; direct-write in worktree + Claude diff review; 2-attempt cap inheriting SPEC-009; sandboxed/allowlisted leash; token-savings instrumentation; conflict-scanned (no blockers; SPEC-003 model-tier coupling documented; TDD/LOC/council-gate disciplines inherited as MUSTs) |
| 2026-06-16 | SPEC-019 PR2 implemented (CDV-20): orchestrate integration (routing fork + offload-review loop), companion metrics (`emit-orch-metric.sh`), standup surface; status DRAFT→ACTIVE. |
| 2026-07-13 | SPEC-021 implemented (CDV-180): skill-bash lint gate (C1–C4) + `/release` Step 4.8; status DRAFT→ACTIVE. |
| 2026-07-13 | SPEC-023 implemented (CDV-181): release-train queue sequencer (train-lib + skill + command); `/release` skip-if-present; status DRAFT→ACTIVE. |
| 2026-07-14 | SPEC-020 implemented (CDV-183): /craft-loop craft/refine/list; status DRAFT→ACTIVE. |
| 2026-07-14 | SPEC-026 path-cherry-picked + OQ locks (CDV-185): outcomes ledger + advisory routing; status DRAFT→ACTIVE. |
| 2026-07-14 | SPEC-022 implemented (CDV-191): `/doctor` install/config diagnostics (`doctor.sh` + command); status DRAFT→ACTIVE. |
| 2026-07-14 | SPEC-024 implemented (CDV-194): memory seed packs — `/memory-export` + init-team import; status DRAFT→ACTIVE. |
| 2026-07-14 | SPEC-028 renumbered from colliding SPEC-025 (CDV-197): `/fix-ticket` workflow; CDV-192 owns SPEC-025 for `/epic`. |
| 2026-07-14 | SPEC-011 extended (CDV-195): `/validate-memory --reconcile` cross-agent contradiction detection; schema v4 reconcile_log. |
| 2026-07-14 | SPEC-025 implemented (CDV-192): `/epic` umbrella decompose + sequenced handoff (`epic-lib` + standup/wrap hooks); status DRAFT→ACTIVE. |
| 2026-07-14 | SPEC-027 implemented (CDV-193): /incident war-room + postmortem (timeline + workspace); status DRAFT→ACTIVE. |
| 2026-07-15 | SPEC-029 DRAFT: debug reopen detector + multi-surface done gates (from plugin bug/refactor eval + May refine autopsy); partial skill implementation. |
| 2026-07-16 | SPEC-029 dogfood on describer (Grok `/debug`); status DRAFT→ACTIVE. |
| 2026-07-21 | SPEC-030 implemented (CDT-46-C1): deterministic smoke-harness gate (tools/smoke/) + first CI (.github/workflows/smoke.yml) + `/release` Step 4.10; status DRAFT→ACTIVE. |
