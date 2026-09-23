# Backlog coverage map

Generated from `backlog.json` (169 items). Every proposal row and every per-file finding with an issue in the eleven review files maps to at least one item id below. Anchors: `#N` = Enhancement-proposal row N (03 uses E0–E13 plus finding ids C/M/R/S, 06 adds bug ids B1–B9); `#F:<file>(n)` = per-file table finding (n = numbered sub-finding in that row); `#cross-N` = cross-cutting finding N; other anchors name a headline, test-results row or README section.

Items whose id starts with `W1-` but whose milestone is **Wave 0** are the small P1 fixes promoted into Wave 0 (the id schema has no W0 prefix).

## README.md

| Anchor | Item ids |
|---|---|
| `#1-exec-1` | W1-33 |
| `#1-exec-2` | W2-01 |
| `#1-exec-3` | W1-36 |
| `#1-exec-5` | W1-47 |
| `#1-exec-6` | W2-11 |
| `#1-exec-7` | W2-09 |
| `#1-exec-8` | W1-42 |
| `#3-red-env` | W1-34 |
| `#3-red-real` | W1-01 |
| `#3-writes-live-repo` | W1-35 |
| `#4.1` | W1-33 |
| `#4.1-sqlite-skip` | W1-34 |
| `#4.2` | W1-08, W1-17, W1-27, W1-36, W1-51, W2-22, W2-33, W2-44 |
| `#4.3` | W1-02, W1-04, W1-06, W1-32, W2-35 |
| `#4.4` | W1-27, W1-29, W1-47, W2-13, W2-17, W2-25 |
| `#4.4-loadPrompt` | W2-14 |
| `#4.5` | W1-38, W1-40, W2-21 |
| `#4.6` | W2-01, W2-02, W2-05, W2-09 |
| `#4.6-audit` | W2-37 |
| `#4.7` | W3-01, W3-06 |
| `#4.7-args` | W1-46 |
| `#4.7-stale` | W3-02, W3-03 |
| `#4.8` | W1-12, W1-42, W1-43, W1-45, W2-26 |
| `#6-T2` | W1-32 |
| `#6-T4` | W1-51 |
| `#6-T5` | W1-14, W1-15 |
| `#6-T5-argloops` | W1-46 |
| `#6-T6` | W1-54 |
| `#6-T7` | W1-26 |
| `#P0-1` | P0-01 |
| `#P0-10` | P0-10 |
| `#P0-11` | P0-11 |
| `#P0-12` | P0-12 |
| `#P0-13` | P0-13 |
| `#P0-14` | P0-14 |
| `#P0-15` | P0-15 |
| `#P0-16` | P0-16 |
| `#P0-17` | P0-17 |
| `#P0-18` | P0-18 |
| `#P0-19` | P0-19 |
| `#P0-2` | P0-02 |
| `#P0-20` | P0-20 |
| `#P0-3` | P0-03 |
| `#P0-4` | P0-04 |
| `#P0-5` | P0-05 |
| `#P0-6` | P0-06 |
| `#P0-7` | P0-07 |
| `#P0-8` | P0-08 |
| `#P0-9` | P0-09 |
| `#P1-backlog` | W1-50 |
| `#P1-bash-star` | W1-31 |
| `#P1-bump-class` | W1-03 |
| `#P1-end-state` | W1-06 |
| `#P1-migrate-md` | W1-48 |
| `#P1-seed-pack` | W2-17 |
| `#P1-tags` | W1-05 |
| `#P1-worktree-lib` | W1-02 |
| `#wave0-red-suites` | W1-01 |
| `#wave1-ci` | W1-33 |
| `#wave1-git-safety` | W1-32 |
| `#wave1-input-safety` | W1-47 |
| `#wave1-input-safety-nonce` | W2-25 |
| `#wave1-lint` | W1-36 |
| `#wave1-platform-floor` | W1-42 |
| `#wave1-smoke` | W1-37 |
| `#wave1-spec-lint` | W1-38 |
| `#wave2-agent-preamble` | W2-10 |
| `#wave2-council` | W2-11, W2-12, W2-13, W2-14 |
| `#wave2-deterministic` | W2-01, W2-07 |
| `#wave2-memory` | W2-16, W2-17, W2-19, W2-21, W2-23 |
| `#wave2-orchestration` | W1-53 |
| `#wave2-pdh` | W2-09 |
| `#wave2-router` | W2-02, W2-03, W2-04, W2-05, W2-06 |
| `#wave2-transcript` | W2-26, W2-28 |
| `#wave3-ci-watch` | W2-36 |
| `#wave3-craft-loop` | W3-28 |
| `#wave3-cwd-runbooks` | W3-04 |
| `#wave3-descriptions` | W3-07 |
| `#wave3-docs` | W3-01 |
| `#wave3-docs-internal` | W3-05 |
| `#wave3-doctor-split` | W3-39 |
| `#wave3-external-reviewer` | W3-17 |
| `#wave3-invocable` | W3-06 |
| `#wave3-probe` | W3-21 |
| `#wave3-release-train` | W2-35 |
| `#wave3-security-md` | W3-22 |
| `#wave3-security-scan` | W1-59 |
| `#wave3-strip-prose` | W3-10 |
| `#wave3-worktree-ux` | W3-08 |

## 01-agents-infra.md

| Anchor | Item ids |
|---|---|
| `#1` | P0-10 |
| `#2` | P0-10 |
| `#3` | P0-20 |
| `#4` | W1-51 |
| `#5` | W1-33 |
| `#6` | W1-37 |
| `#6-C1` | W1-36 |
| `#7` | W1-31 |
| `#8` | W1-30 |
| `#9` | W2-10 |
| `#10` | W2-10 |
| `#11` | W3-18 |
| `#12` | W3-19 |
| `#13` | W3-20 |
| `#14` | W1-57 |
| `#15` | W3-21 |
| `#16` | W3-22 |
| `#17` | W3-21 |
| `#F:.claude-plugin/marketplace.json` | W3-20 |
| `#F:.github/workflows/smoke.yml` | W1-33 |
| `#F:.gitignore` | W3-22 |
| `#F:AGENTS.md` | W3-19 |
| `#F:CONTEXT.md` | W3-22 |
| `#F:README.md` | W3-20 |
| `#F:SECURITY.md` | W3-22 |
| `#F:agents/council-judge.md` | W3-18 |
| `#F:agents/debugger.md` | W3-18 |
| `#F:agents/distiller.md` | W1-51 |
| `#F:agents/distiller.md(4)` | W1-19 |
| `#F:agents/finder.md` | W3-18 |
| `#F:agents/ic4.md` | W3-18 |
| `#F:agents/ic5.md(commit)` | W3-18 |
| `#F:agents/ic5.md(resolver)` | W2-10 |
| `#F:agents/pm.md` | W3-18 |
| `#F:agents/pm.md(block)` | W2-10 |
| `#F:agents/project-init.md` | P0-10 |
| `#F:agents/project-init.md(5)` | W1-31 |
| `#F:agents/tech-lead.md` | W3-18 |
| `#F:githooks/pre-commit` | W3-22 |
| `#F:install-test.sh` | W1-57 |
| `#F:install-test.sh(sha)` | W1-45 |
| `#F:install.sh(1)` | P0-20 |
| `#F:install.sh(2-5,7)` | W1-30 |
| `#F:install.sh(6)` | P0-20 |
| `#F:tools/permission-matrix-cc-version` | W3-21 |
| `#F:tools/permission-matrix-probe.sh` | W3-21 |
| `#F:tools/permission-matrix-probe.sh(rg-c)` | W1-20 |
| `#F:tools/permission-matrix-probe.sh(timeout)` | W1-45 |
| `#F:tools/scout-plugins/README.md` | W3-22 |
| `#F:tools/smoke/run.sh` | W1-37 |
| `#F:tools/smoke/test.sh` | W1-33 |
| `#F:tools/smoke/test.sh(comment)` | W3-22 |
| `#F:uninstall.sh` | W1-30 |
| `#cross-1` | P0-20 |
| `#cross-1-pm` | W3-18 |
| `#cross-2` | W2-10 |
| `#cross-3` | W1-36, W1-37, W1-51 |
| `#cross-5` | W1-31 |
| `#cross-5-readonly` | W3-18 |
| `#cross-6` | W2-10 |
| `#cross-7` | W1-01 |
| `#cross-7-env` | W1-34 |
| `#cross-8` | W1-45 |
| `#cross-9` | W3-20 |

## 02-commands-docs.md

| Anchor | Item ids |
|---|---|
| `#1` | P0-09 |
| `#2` | P0-11 |
| `#3` | W1-46 |
| `#4` | W1-27 |
| `#5` | W1-28 |
| `#6` | W1-29 |
| `#7` | W3-08 |
| `#8` | W3-01 |
| `#9` | W3-06 |
| `#10` | W3-04 |
| `#11` | W3-02, W3-03 |
| `#12` | W2-09 |
| `#13` | W1-20 |
| `#14` | W1-36 |
| `#15` | W3-05 |
| `#16` | W3-01 |
| `#P0-1` | P0-09 |
| `#P0-2` | P0-11 |
| `#F:commands/adjust-agent.md(1)` | W1-20 |
| `#F:commands/adjust-agent.md(2)` | W2-44 |
| `#F:commands/adjust-agent.md(3)` | W1-20 |
| `#F:commands/adjust-agent.md(4)` | W2-09 |
| `#F:commands/adjust-agent.md(5)` | W3-09 |
| `#F:commands/audit.md` | W1-46 |
| `#F:commands/audit.md(file)` | W2-37 |
| `#F:commands/audit.md(pdh)` | W2-09 |
| `#F:commands/audit.md(pdh-twice)` | W3-09 |
| `#F:commands/bug-hunt.md` | W3-10 |
| `#F:commands/compact-transcript.md` | W1-46 |
| `#F:commands/craft-loop.md` | W3-09 |
| `#F:commands/debug.md` | W3-09 |
| `#F:commands/doctor.md` | W1-46 |
| `#F:commands/doctor.md(groups)` | W3-01 |
| `#F:commands/epic.md` | P0-11 |
| `#F:commands/handoff.md` | W1-27 |
| `#F:commands/mode.md(read)` | W3-09 |
| `#F:commands/mode.md(stub)` | W3-06 |
| `#F:commands/recall.md` | W1-29 |
| `#F:commands/release-train.md` | W3-09 |
| `#F:commands/release-train.md(dry-run)` | W2-35 |
| `#F:commands/setup.md` | P0-09 |
| `#F:commands/setup.md(10)` | W2-09 |
| `#F:commands/setup.md(5)` | W1-46 |
| `#F:commands/status.md` | W1-46, W2-09 |
| `#F:commands/tdd-gate.md` | W1-28 |
| `#F:commands/worktree.md` | W3-08 |
| `#F:docs/README.md(1,3,4)` | W3-01 |
| `#F:docs/README.md(2)` | W3-03 |
| `#F:docs/commands/audit.md` | W3-01 |
| `#F:docs/commands/brainstorm.md` | W3-02 |
| `#F:docs/commands/bug-hunt.md` | W3-05 |
| `#F:docs/commands/council.md` | W3-01 |
| `#F:docs/commands/debug.md` | W3-02 |
| `#F:docs/commands/epic.md` | P0-11 |
| `#F:docs/commands/handoff.md(length)` | W3-05 |
| `#F:docs/commands/handoff.md(strings)` | W1-27 |
| `#F:docs/commands/kickoff.md` | W3-43 |
| `#F:docs/commands/memory.md` | W3-02 |
| `#F:docs/commands/mode.md` | W3-02 |
| `#F:docs/commands/orchestrate.md(12)` | W3-02 |
| `#F:docs/commands/orchestrate.md(usage)` | W3-01 |
| `#F:docs/commands/recall.md` | W1-29 |
| `#F:docs/commands/retro.md` | W3-02 |
| `#F:docs/commands/review-and-commit.md` | W3-02 |
| `#F:docs/commands/setup.md` | W3-02 |
| `#F:docs/commands/spec.md(flags)` | W3-01 |
| `#F:docs/commands/spec.md(stale)` | W3-02 |
| `#F:docs/commands/transcript-mirror.md(devlog)` | W3-02 |
| `#F:docs/commands/transcript-mirror.md(invocable)` | W3-06 |
| `#F:docs/commands/transcript-mirror.md(paths)` | W3-04 |
| `#F:docs/commands/worktree.md` | W3-08 |
| `#F:docs/commands/wrap-ticket.md` | W3-08 |
| `#F:docs/runbooks/handoff-stm-dogfood.md` | W3-05 |
| `#F:docs/runbooks/handoff-stm-dogfood.md(paths)` | W3-04 |
| `#F:docs/runbooks/idea-to-plan.md` | W3-43 |
| `#F:docs/runbooks/manual.md(misc)` | W3-03 |
| `#F:docs/runbooks/manual.md(paths)` | W3-04 |
| `#F:docs/runbooks/memory.md` | W3-03 |
| `#F:docs/runbooks/migrate-to-v1.md` | W3-03 |
| `#F:docs/runbooks/onboarding.md` | W3-03 |
| `#F:docs/runbooks/orchestrate.md` | W3-03 |
| `#F:docs/runbooks/permission-posture-matrix.md` | W3-05 |
| `#F:docs/runbooks/scheduled-retro.md(misc)` | W3-03 |
| `#F:docs/runbooks/scheduled-retro.md(paths)` | W3-04 |
| `#F:docs/setup.md` | W3-03 |
| `#coverage-matrix` | W3-01 |
| `#coverage-matrix-internal` | W3-06 |
| `#cross-1` | W1-46 |
| `#cross-2` | W1-36 |
| `#cross-3` | W2-09 |
| `#cross-4` | W3-02 |
| `#cross-5` | W3-02 |
| `#cross-6` | W3-04 |
| `#cross-7` | W3-06 |
| `#cross-8` | W1-02, W3-08 |
| `#cross-9` | W3-02 |

## 03-large-commands.md

| Anchor | Item ids |
|---|---|
| `#C1` | W3-11 |
| `#C2` | P0-04 |
| `#C3` | W1-22 |
| `#C4` | W2-04 |
| `#C5` | W2-45 |
| `#C6` | W2-44 |
| `#C7` | W2-44 |
| `#C8` | W1-45 |
| `#C9` | W3-11 |
| `#C10` | W3-11 |
| `#C11` | W3-11 |
| `#C12` | W1-22 |
| `#C13` | W3-11 |
| `#C14` | W3-11 |
| `#C15` | W2-09 |
| `#C16` | W2-04 |
| `#E0` | P0-05, P0-06, P0-07, P0-08 |
| `#E1` | W2-04 |
| `#E2` | W2-04 |
| `#E3` | W2-02 |
| `#E4` | W2-01 |
| `#E5` | W2-09 |
| `#E6` | W2-03 |
| `#E7` | W3-10 |
| `#E8` | W1-36 |
| `#E9` | W1-17 |
| `#E10` | W1-47 |
| `#E11` | W1-20, W1-45 |
| `#E12` | W1-22 |
| `#E13` | W2-45 |
| `#M1` | P0-05 |
| `#M2` | P0-06 |
| `#M3` | P0-07 |
| `#M4` | W1-47 |
| `#M5` | W1-17 |
| `#M6` | W1-17 |
| `#M7` | W1-18 |
| `#M8` | W1-18 |
| `#M9` | W2-45 |
| `#M10` | W2-45 |
| `#M11` | W2-24 |
| `#M12` | W2-24 |
| `#M13` | W2-24 |
| `#M14` | W1-46 |
| `#M15` | P0-18 |
| `#M16` | W2-24 |
| `#M17` | W2-24 |
| `#M18` | W3-10 |
| `#M19` | W2-02, W2-09 |
| `#R1` | P0-08 |
| `#R2` | P0-08 |
| `#R3` | W1-20 |
| `#R4` | W1-55 |
| `#R5` | W1-21 |
| `#R6` | W1-55 |
| `#R7` | W2-01 |
| `#R8` | W1-21 |
| `#R9` | W1-21 |
| `#R10` | W2-01 |
| `#R11` | W1-21 |
| `#R12` | W1-45 |
| `#R13` | W1-46 |
| `#R14` | W1-21 |
| `#R15` | W1-21 |
| `#R16` | W1-47 |
| `#R17` | W1-21 |
| `#R18` | W2-01 |
| `#S1` | W3-10 |
| `#S2` | W2-45 |
| `#S3` | W3-12 |
| `#S4` | W3-12 |
| `#S5` | W3-12 |
| `#S6` | W3-12 |
| `#S7` | W3-12 |
| `#S8` | W3-12 |
| `#S9` | W2-03 |
| `#F:commands/council.md:30` | W2-43 |
| `#cross-1` | W2-01 |
| `#cross-3` | W1-17 |
| `#cross-4` | W2-09 |
| `#cross-5` | W3-10 |
| `#cross-6` | W1-18 |
| `#cross-7` | W1-45 |
| `#cross-8` | W1-47 |

## 04-council.md

| Anchor | Item ids |
|---|---|
| `#1` | P0-12 |
| `#2` | P0-13 |
| `#3` | P0-15 |
| `#4` | P0-14 |
| `#5` | W2-11 |
| `#6` | W2-12 |
| `#7` | W2-13 |
| `#8` | W2-14 |
| `#9` | W1-33, W1-56 |
| `#9-hermetic` | W1-34 |
| `#10` | W1-23 |
| `#11` | W1-14 |
| `#12` | W2-15 |
| `#13-bash4` | W1-44 |
| `#13-flock` | W1-43 |
| `#13-sed` | W1-45 |
| `#14` | W3-17 |
| `#15` | W2-30 |
| `#16` | P0-16 |
| `#17` | W3-13 |
| `#18` | W3-14 |
| `#19` | W3-15 |
| `#20` | W1-40 |
| `#21` | W2-25 |
| `#F:council/SKILL.md(1,2,4)` | W3-13 |
| `#F:council/SKILL.md(3)` | W2-11 |
| `#F:council/check-template-vars.sh` | W3-14 |
| `#F:council/engine.sh(1,2,4,5)` | W2-11 |
| `#F:council/engine.sh(11)` | W2-40 |
| `#F:council/engine.sh(14)` | W2-30 |
| `#F:council/engine.sh(3)` | P0-15 |
| `#F:council/engine.sh(6)` | W1-14 |
| `#F:council/engine.sh(7)` | W1-45 |
| `#F:council/engine.sh(8-15)` | W2-15 |
| `#F:council/external-reviewer.sh(1,2,4-6)` | W3-17 |
| `#F:council/external-reviewer.sh(3)` | W1-45 |
| `#F:council/flavors/jaded-senior.md` | W2-12 |
| `#F:council/index-writer.sh` | W1-43 |
| `#F:council/index-writer.sh(TASK_ID)` | W2-15 |
| `#F:council/index-writer.sh(local-n)` | W1-44 |
| `#F:council/tier-grade.sh(1)` | P0-12 |
| `#F:council/tier-grade.sh(2,3,4,6)` | W3-16 |
| `#F:council/tier-grade.sh(5)` | W1-44 |
| `#F:council/workflow-schemas.js` | P0-16 |
| `#F:council/workflow-schemas.js(required)` | W2-11 |
| `#F:council/workflow.js(1)` | P0-13 |
| `#F:council/workflow.js(2,3,5-11)` | W2-14 |
| `#F:council/workflow.js(4)` | P0-14 |
| `#F:fix-ticket/SKILL.md(1)` | W1-23 |
| `#F:fix-ticket/SKILL.md(2-5)` | W3-15 |
| `#F:fix-ticket/prompts/*.md` | W2-25 |
| `#F:fix-ticket/templates/report.md` | W3-15 |
| `#F:fix-ticket/workflow.js` | W3-15 |
| `#F:fixtures/` | P0-15 |
| `#F:flavors/logic,security,compliance,quality,simplification(1-4,6)` | W3-13 |
| `#F:flavors/logic,security,compliance,quality,simplification(5)` | P0-16 |
| `#F:flavors/paranoid-ic,yolo-ic,external,diff-mode.md` | W2-11 |
| `#F:flavors/paranoid-ic,yolo-ic,external,diff-mode.md(roles)` | W3-13 |
| `#F:prompts/claim-extractor,plan-extractor,topic-classifier,tier-triage` | W2-25 |
| `#F:prompts/investigator.md` | W2-13 |
| `#F:prompts/judge.md,phase4-brief.md,cross-reviewer.md` | W2-11 |
| `#F:prompts/judge.md,phase4-brief.md,cross-reviewer.md(RANKING)` | W2-14 |
| `#F:prompts/unconstrained-reviewer,lens-reviewer,quorum-analyst` | W2-25 |
| `#F:specs/core/SPEC-028` | W1-40 |
| `#F:templates/report-finding.md(111)` | W2-11 |
| `#F:templates/report-finding.md(115)` | W2-15 |
| `#F:test-tier-grade.sh` | P0-12 |
| `#F:test-tier-grade.sh,test-tier-engine.sh,test-finalize-missing-tid.sh` | W1-56 |
| `#F:test-workflow-static.sh` | W1-34 |
| `#F:test-workflow-static.sh(2)` | W1-35 |
| `#cross-1` | W2-11 |
| `#cross-2` | W2-14 |
| `#cross-4` | W2-30 |
| `#cross-5` | W2-12, W3-13 |
| `#cross-6` | W1-56 |
| `#test-results` | W1-01 |
| `#test-side-effects` | W1-33, W1-35 |

## 05-orchestration.md

| Anchor | Item ids |
|---|---|
| `#1` | P0-02 |
| `#2` | W1-01, W1-33 |
| `#3` | W1-08 |
| `#4` | W1-09 |
| `#5` | W1-10 |
| `#6` | W1-52 |
| `#7` | W1-53 |
| `#8` | W1-06 |
| `#9` | W1-11 |
| `#10` | W2-34 |
| `#11` | W2-33 |
| `#12` | W2-09 |
| `#13-epic-kickoff` | W2-05 |
| `#13-init` | W2-06 |
| `#14` | W1-43 |
| `#15` | W1-58 |
| `#16` | W3-36 |
| `#17` | W3-37 |
| `#18` | W3-37 |
| `#19` | W3-38 |
| `#20` | W2-33 |
| `#F:autopilot/append-card.sh` | W3-36 |
| `#F:autopilot/end-state.md` | W1-06 |
| `#F:autopilot/loc-exclude.sh` | W3-36 |
| `#F:autopilot/parse-flags.sh` | W1-58 |
| `#F:autopilot/resume-state.sh` | W1-11 |
| `#F:epic/SKILL.md(0.4)` | W3-37 |
| `#F:epic/SKILL.md(resume)` | W2-34 |
| `#F:epic/epic-lib.sh` | P0-02 |
| `#F:epic/epic-lib.sh(bash4)` | W1-44 |
| `#F:epic/epic-lib.sh(init-parse)` | W1-58 |
| `#F:epic/epic-lib.sh(misc)` | W3-37 |
| `#F:epic/test.sh` | W3-37 |
| `#F:init-orchestration/*.sh` | W2-06 |
| `#F:init-orchestration/SKILL.md(hook)` | W1-52 |
| `#F:init-orchestration/SKILL.md(python)` | W1-47 |
| `#F:kickoff/SKILL.md(dag)` | W1-08 |
| `#F:kickoff/SKILL.md(misc)` | W3-38 |
| `#F:orchestrate/dag-lib.sh` | W1-09 |
| `#F:orchestrate/task-store.sh` | W1-09 |
| `#F:orchestrate/task-store.sh(flock)` | W1-43 |
| `#F:steps/00-resolve.md(ITER)` | W1-53 |
| `#F:steps/00-resolve.md(memdb)` | W2-33 |
| `#F:steps/00-resolve.md(pdh)` | W2-09 |
| `#F:steps/02-scope.md` | W1-01 |
| `#F:steps/03-worktree.md` | W2-33 |
| `#F:steps/04-kickoff.md` | W2-09 |
| `#F:steps/05-questions.md` | W1-53 |
| `#F:steps/06-design.md` | W2-33 |
| `#F:steps/07-tasks.md` | W1-08 |
| `#F:steps/07-tasks.md(halt)` | W2-33 |
| `#F:steps/08-execute.md` | W1-10 |
| `#F:steps/09-review.md` | W2-33 |
| `#F:steps/09-review.md(pdh)` | W2-09 |
| `#F:steps/10-qa.md` | W1-53 |
| `#F:steps/11-ship.md` | W2-33 |
| `#F:steps/12-wrap.md` | W2-33 |
| `#F:task-store-test.sh` | W1-09 |
| `#cross-1` | W1-33 |
| `#cross-2` | W2-09 |
| `#cross-3` | W1-09, W1-52 |
| `#cross-4` | W1-08 |
| `#cross-5` | W1-32 |
| `#cross-6` | W1-53 |
| `#cross-7` | W1-43 |
| `#cross-8` | W1-58 |

## 06-handoff-transcript.md

| Anchor | Item ids |
|---|---|
| `#1` | P0-19 |
| `#2` | W1-54 |
| `#3` | W1-12 |
| `#4` | W1-13 |
| `#5` | W1-14 |
| `#6` | W1-15 |
| `#7` | W2-26 |
| `#8` | W1-16 |
| `#9` | W1-01, W1-34 |
| `#10` | W1-45 |
| `#11` | W2-27 |
| `#12` | W1-54 |
| `#13` | W2-28 |
| `#14` | W2-29 |
| `#15` | W3-34 |
| `#16` | W3-35 |
| `#17` | W3-34 |
| `#18` | W2-30 |
| `#B1` | P0-19 |
| `#B2` | W1-54 |
| `#B3` | W1-12 |
| `#B4` | W1-14 |
| `#B5` | W1-13 |
| `#B6` | W3-35 |
| `#B7` | W1-15 |
| `#B8` | W1-45 |
| `#B8-cleanup` | W2-30 |
| `#B9` | W3-34 |
| `#F:handoff/SKILL.md` | W3-34 |
| `#F:handoff/assemble.py` | W3-35 |
| `#F:handoff/discover-warm.sh` | W2-32 |
| `#F:handoff/precompact-capture.sh` | W2-31 |
| `#F:handoff/precompact-capture.sh(gitignored)` | W2-26 |
| `#F:handoff/precompact-capture.sh(timeout)` | W1-45 |
| `#F:handoff/prepass.sh(a)` | W1-13 |
| `#F:handoff/prepass.sh(b)` | W1-13 |
| `#F:handoff/prepass.sh(c)` | W1-16 |
| `#F:handoff/prepass.sh(d)` | W3-34 |
| `#F:handoff/prepass.sh(e)` | W2-30 |
| `#F:handoff/prepass.sh(f,g,h)` | W3-35 |
| `#F:handoff/resolve-root.sh` | W1-13 |
| `#F:retro-gate/friction-capture-test` | W1-34 |
| `#F:retro-gate/gate.sh` | W2-29 |
| `#F:retro-gate/gate.sh(threshold)` | W3-35 |
| `#F:retro-gate/hint.sh` | W3-35 |
| `#F:retro-gate/scheduled-lock.sh` | W1-15 |
| `#F:retro-gate/trial-meta.sh` | W1-14 |
| `#F:retro-gate/trial-review.sh` | W1-12 |
| `#F:retro-gate/write-scheduled-report.sh` | W3-35 |
| `#F:transcript-mirror/SKILL.md` | P0-19 |
| `#F:transcript-mirror/hook-shim.sh` | W1-16 |
| `#F:transcript-mirror/reapply-overlay.sh` | W2-27 |
| `#F:transcript-mirror/strip_main.py` | W2-27 |
| `#F:transcript-mirror/summarize-transcript.py` | W2-27 |
| `#F:transcript-mirror/summarize-transcript.py(lock)` | W1-54 |
| `#F:transcript-mirror/test.sh(M4)` | W1-34 |
| `#F:transcript-mirror/transcript-mirror.sh` | W1-54 |
| `#F:transcript-mirror/transcript-mirror.sh(gnu)` | W1-45 |
| `#F:transcript-mirror/transcript-mirror.sh(perm)` | W2-26 |
| `#F:transcript-mirror/transcript-sync.py` | W1-16, W2-28 |
| `#F:transcript-parse/SKILL.md` | W3-34 |
| `#F:transcript-parse/assemble.py` | W1-13 |
| `#F:transcript-parse/discover-host.sh` | W2-32 |
| `#F:transcript-parse/freshness.sh` | W2-32 |
| `#F:transcript-parse/grok_normalize.py` | W2-32 |
| `#F:transcript-parse/grok_normalize.py(mapping)` | W2-28 |
| `#F:transcript-parse/hosts.py` | W1-12 |
| `#F:transcript-parse/hosts.py(monkeypatch)` | W2-32 |
| `#F:transcript-parse/parselib.py` | W3-34 |
| `#cross-1` | W1-12, W2-28 |
| `#cross-1-pdh` | W2-09 |
| `#cross-2` | W2-26 |
| `#cross-3` | W2-31 |
| `#cross-4` | W2-32 |
| `#test-leaks` | W1-35 |
| `#test-results` | W1-01, W1-33 |

## 07-memory.md

| Anchor | Item ids |
|---|---|
| `#1` | P0-01 |
| `#2` | P0-04 |
| `#2-lint` | W1-36 |
| `#3` | P0-18 |
| `#4` | W2-16 |
| `#5` | W1-48 |
| `#6` | W2-17 |
| `#7` | W1-19 |
| `#7-lint` | W1-36 |
| `#8` | W1-49 |
| `#9-flock` | W1-43 |
| `#9-gitignore` | W2-26 |
| `#10` | W1-33, W1-34 |
| `#11` | W2-18 |
| `#12` | W2-18 |
| `#13` | W2-19 |
| `#14` | W2-20 |
| `#15` | W2-21 |
| `#16` | W2-22 |
| `#17` | W2-23 |
| `#18` | W2-25 |
| `#19` | W3-26 |
| `#20` | W1-16, W3-23 |
| `#21` | W3-24 |
| `#P0-bug-1` | P0-01 |
| `#P0-bug-2` | P0-04 |
| `#P0-bug-3` | P0-18 |
| `#F:agent-memory/cortex-load.md` | W1-19 |
| `#F:agent-memory/cortex-load.md(select)` | W2-16 |
| `#F:agent-memory/protocol.md(embed)` | W1-16 |
| `#F:agent-memory/protocol.md(tier,readback)` | W2-16 |
| `#F:agent-memory/sync-includes.py` | W3-25 |
| `#F:domain-glossary/SKILL.md` | W3-26 |
| `#F:memory-compress/SKILL.md` | W3-23 |
| `#F:memory-recall/SKILL.md(curl)` | W2-20 |
| `#F:memory-recall/SKILL.md(score)` | W2-21 |
| `#F:memory-recall/SKILL.md(step5,step4,like)` | W2-22 |
| `#F:memory-store/SKILL.md(:161)` | W1-19 |
| `#F:memory-store/SKILL.md(:59)` | W1-47 |
| `#F:memory-store/SKILL.md(docs)` | W3-23 |
| `#F:memory-store/download-extensions.sh` | W2-19 |
| `#F:memory-store/download-extensions.sh(DIMS)` | W1-47 |
| `#F:memory-store/embed-one.sh(curl,key)` | W2-20 |
| `#F:memory-store/embed-one.sh(load)` | W2-19 |
| `#F:memory-store/embed-one.sh(timeout)` | W1-19 |
| `#F:memory-store/export-seed-pack.sh` | W2-18 |
| `#F:memory-store/import-seed-pack.sh(cap,dedupe,sanitized)` | W2-18 |
| `#F:memory-store/import-seed-pack.sh(eclipse)` | W2-16 |
| `#F:memory-store/import-seed-pack.sh(trust)` | W2-17 |
| `#F:memory-store/migrate-md.sh` | W1-48 |
| `#F:memory-store/migrate-v2.sh` | W2-23 |
| `#F:memory-store/migrate.sh` | W2-23 |
| `#F:memory-store/schema.sql` | W2-23 |
| `#F:memory-store/seed-common.sh` | W2-18 |
| `#F:memory-store/seed-common.sh(0600)` | W2-40 |
| `#F:memory-store/seed-common.sh(sha)` | W1-45 |
| `#F:memory-store/test-migrate.sh` | W1-34, W2-23 |
| `#F:memory-store/test-seed-pack.sh` | W2-18 |
| `#F:metrics/emit-outcome.sh` | W3-24 |
| `#F:metrics/outcome-rates.sh` | W3-24 |
| `#F:metrics/rollup.sh` | W3-24 |
| `#F:metrics/test.sh` | W1-34 |
| `#F:model-map/SKILL.md` | W2-26 |
| `#F:model-map/SKILL.md(gitignored-claim)` | W3-23 |
| `#F:model-map/resolve-model.sh` | W3-24 |
| `#F:model-map/write-model.sh` | W1-43 |
| `#F:notify/webhook.sh` | W2-20 |
| `#F:validate-memory/SKILL.md` | P0-18 |
| `#F:validate-memory/SKILL.md(cosine)` | W2-21 |
| `#F:validate-memory/SKILL.md(delimiters)` | W2-25 |
| `#F:validate-memory/reconcile-lib.sh` | P0-01 |
| `#F:validate-memory/reconcile-lib.sh(fallback)` | W1-49 |
| `#F:validate-memory/test-reconcile.sh` | W1-34, W1-49 |
| `#ci-gap` | W1-33 |
| `#cross-concurrency` | W1-19 |
| `#cross-native` | W2-19 |
| `#cross-spec-drift-agents` | W3-19 |
| `#cross-sql` | W1-47 |
| `#cross-tier-eclipse` | W2-16 |
| `#test-results` | W1-34 |

## 08-workflow-skills.md

| Anchor | Item ids |
|---|---|
| `#1` | P0-04 |
| `#2` | W1-36 |
| `#3` | P0-16 |
| `#4` | P0-17 |
| `#5` | P0-17 |
| `#6` | W1-26 |
| `#7` | W1-59 |
| `#8` | W1-24 |
| `#9` | W2-07 |
| `#10` | W2-08 |
| `#11` | W1-25 |
| `#12` | W2-41 |
| `#13` | W1-31 |
| `#14` | W3-06 |
| `#15` | W3-07 |
| `#16` | W1-38 |
| `#17` | W3-33 |
| `#18` | W3-28 |
| `#19` | W3-28 |
| `#20` | W3-29 |
| `#21` | W3-27 |
| `#22` | W2-42 |
| `#23` | W2-09 |
| `#24` | W3-30 |
| `#25` | W3-31 |
| `#F:blunt/SKILL.md` | W3-06 |
| `#F:brainstorm/SKILL.md` | W3-27 |
| `#F:bug-hunt/SKILL.md(bash)` | W1-25 |
| `#F:bug-hunt/SKILL.md(frontmatter)` | W3-07 |
| `#F:bug-hunt/SKILL.md(size)` | W2-07 |
| `#F:bug-hunt/SKILL.md(spec)` | W1-39 |
| `#F:bug-hunt/test.sh` | W2-07 |
| `#F:code-simplify/SKILL.md` | W2-42 |
| `#F:craft-loop/SKILL.md` | W3-28 |
| `#F:craft-loop/SKILL.md(list-root)` | W3-29 |
| `#F:craft-loop/examples/backlog-burn.md` | W3-29 |
| `#F:craft-loop/examples/spec-sync.md` | W3-28 |
| `#F:debug/SKILL.md(0c)` | W1-26 |
| `#F:debug/SKILL.md(contradictions,lifecycle)` | W2-41 |
| `#F:debug/SKILL.md(helper)` | P0-17 |
| `#F:debug/SKILL.md(model-map-dup)` | W2-09 |
| `#F:debug/theme-status.sh` | P0-17 |
| `#F:focus/SKILL.md` | W3-06 |
| `#F:refactor/SKILL.md(1b)` | W1-26 |
| `#F:refactor/SKILL.md(\s)` | W1-45 |
| `#F:refactor/SKILL.md(misc)` | W3-30 |
| `#F:review-and-commit/SKILL.md` | P0-04 |
| `#F:review-and-commit/SKILL.md(description)` | W3-07 |
| `#F:review-and-commit/SKILL.md(scope)` | W1-24 |
| `#F:scaffold-project/SKILL.md` | W1-31 |
| `#F:scaffold-project/SKILL.md(roster,tdd)` | W3-32 |
| `#F:security-scan/SKILL.md+scan.sh` | W1-59 |
| `#F:spec-tooling/SKILL.md` | W3-33 |
| `#F:spec-tooling/check-format.sh` | W1-38 |
| `#F:spec-tooling/spec-skeleton.md,source-exclude.md` | W3-33 |
| `#F:standup/SKILL.md` | W3-31 |
| `#F:standup/SKILL.md(menu)` | W3-06 |
| `#overlap-SPEC-014` | W1-40 |
| `#overlap-code-simplify-name` | W3-06 |
| `#overlap-internal` | W3-06 |
| `#overlap-refactor-simplify` | W2-42 |
| `#overlap-review-and-commit` | W2-43 |
| `#test-results` | W1-25 |
| `#test-results-bh` | W2-08 |
| `#test-results-check-format` | W1-38 |
| `#test-results-lint` | W1-36 |
| `#test-results-scan` | W1-59 |

## 09-release-tooling.md

| Anchor | Item ids |
|---|---|
| `#1` | P0-03 |
| `#2` | W1-02 |
| `#3` | W1-03 |
| `#4` | W1-04 |
| `#5` | W1-50 |
| `#6` | W1-07 |
| `#7` | W1-05 |
| `#8` | W1-01, W1-33 |
| `#9` | W1-42 |
| `#10` | W2-35 |
| `#11` | W2-36 |
| `#12` | W1-60 |
| `#13` | W1-36 |
| `#14` | W1-35 |
| `#15` | W2-37 |
| `#16` | W1-16 |
| `#17` | W3-39 |
| `#18` | W3-40 |
| `#19` | W3-41 |
| `#F:audit/SKILL.md` | W2-37 |
| `#F:audit/apply.py` | W2-37 |
| `#F:audit/audit.sh` | W2-37 |
| `#F:backlog/close.sh` | W1-07 |
| `#F:backlog/close.sh(3)` | W2-40 |
| `#F:backlog/reconcile.sh(1,2,4)` | W1-50 |
| `#F:backlog/reconcile.sh(3)` | W1-44 |
| `#F:ci-watch/SKILL.md` | W2-36 |
| `#F:ci-watch/detect-mode.sh` | W2-36 |
| `#F:ci-watch/poll.sh(1)` | W1-45 |
| `#F:ci-watch/poll.sh(2-4)` | W2-36 |
| `#F:ci-watch/sidecar.sh` | W1-43 |
| `#F:ci-watch/test-poll.sh` | W2-36 |
| `#F:docs-drift(skill-ref-partials)` | W3-33 |
| `#F:docs-drift/check-docs-drift.sh,check.py` | W1-60 |
| `#F:docs-drift/test.sh` | W1-35 |
| `#F:doctor/doctor.sh(1)` | W3-39 |
| `#F:doctor/doctor.sh(2-5,7)` | W2-38 |
| `#F:doctor/doctor.sh(6)` | W1-42 |
| `#F:plugin-dir.sh` | W1-16 |
| `#F:plugin-dir.sh(sort-V)` | W1-45 |
| `#F:release-train/SKILL.md` | W2-35 |
| `#F:release-train/train-lib.sh(1,2,4)` | W2-35 |
| `#F:release-train/train-lib.sh(3)` | W2-40 |
| `#F:release/SKILL.md(1)` | W1-05 |
| `#F:release/SKILL.md(2-6)` | W2-39 |
| `#F:release/SKILL.md(7)` | W1-05 |
| `#F:release/check-bump-class.sh` | W1-03 |
| `#F:release/check-ship-history.sh(1)` | W1-44 |
| `#F:release/check-ship-history.sh(2-5)` | W3-41 |
| `#F:release/check-staged-paths.sh` | W2-39 |
| `#F:release/install-git-hooks.sh` | W2-39 |
| `#F:release/test*.sh` | W1-03 |
| `#F:skill-lint/lint.py` | W1-36 |
| `#F:worktree-lib-test.sh` | W1-02 |
| `#F:worktree-lib.sh(1-3)` | W1-02 |
| `#F:worktree-lib.sh(4-7)` | W3-40 |
| `#F:wrap-ticket/SKILL.md` | W1-04 |
| `#F:wrap-ticket/prune-remote-test.sh` | P0-03 |
| `#F:wrap-ticket/prune-remote.sh` | P0-03 |
| `#cross-1` | W1-32 |
| `#cross-2` | W1-42, W1-44 |
| `#cross-3` | W1-33 |
| `#cross-4` | W2-40 |
| `#cross-5` | W1-02, W1-60 |
| `#test-results` | W1-01 |
| `#test-results-release-train-env` | W1-34 |

## 10-specs.md

| Anchor | Item ids |
|---|---|
| `#1` | W1-38 |
| `#2` | W1-33 |
| `#3` | W1-41 |
| `#4` | W1-39 |
| `#5` | W1-40 |
| `#6` | W2-46 |
| `#7` | W3-42 |
| `#8` | W3-42 |
| `#9` | W3-43 |
| `#AC-gates` | W1-33 |
| `#AC-traceability` | W1-41 |
| `#SPEC-001` | W1-39, W3-19 |
| `#SPEC-002` | W1-60, W3-42 |
| `#SPEC-003` | W1-40 |
| `#SPEC-003-tdd` | W3-42 |
| `#SPEC-004` | W1-19, W2-23 |
| `#SPEC-005` | W1-40 |
| `#SPEC-006` | W1-41, W2-16 |
| `#SPEC-006-tdd-row` | W3-23 |
| `#SPEC-007` | W1-41 |
| `#SPEC-008` | W1-38 |
| `#SPEC-008-dirs` | W3-42 |
| `#SPEC-009` | W1-01 |
| `#SPEC-011` | W2-21, W3-42 |
| `#SPEC-011-k` | W1-49 |
| `#SPEC-012` | W1-01, W1-39, W1-55, W2-29 |
| `#SPEC-012-claims` | W2-46 |
| `#SPEC-012-seam` | W2-28 |
| `#SPEC-013` | W1-01, W3-42 |
| `#SPEC-014` | W1-39 |
| `#SPEC-014-80` | W2-41 |
| `#SPEC-015` | W1-39, W1-41 |
| `#SPEC-016` | W1-40 |
| `#SPEC-017` | W1-01 |
| `#SPEC-017-claims` | W2-46 |
| `#SPEC-018` | W1-01, W3-42 |
| `#SPEC-019` | W1-40 |
| `#SPEC-020` | W1-41 |
| `#SPEC-021` | W3-42 |
| `#SPEC-022` | W3-42 |
| `#SPEC-023-M1` | W2-40 |
| `#SPEC-024` | W2-18, W3-42 |
| `#SPEC-024-boxes` | W3-23 |
| `#SPEC-025` | W1-40 |
| `#SPEC-026` | W1-40, W3-42 |
| `#SPEC-027` | W1-40 |
| `#SPEC-028` | W1-40 |
| `#SPEC-029` | P0-17, W1-41 |
| `#SPEC-031` | W1-39 |
| `#SPEC-032` | W1-60 |
| `#SPEC-033` | W1-38, W3-42 |
| `#SPEC-034` | W1-39 |
| `#SPEC-035` | W1-38, W3-42 |
| `#SPEC-036` | W1-39, W1-54, W2-32 |
| `#SPEC-037` | W1-39, W2-26 |
| `#cross-directive-exclusions` | W3-19 |
| `#cross-fix-ticket` | W1-40 |
| `#cross-normative-draft` | W1-39 |
| `#cross-ownership` | W2-46 |
| `#headline-1` | W1-38 |
| `#headline-1-history` | W3-42 |
| `#headline-2` | W1-40 |
| `#headline-3` | W1-39 |
| `#headline-4` | W1-38 |
| `#headline-5` | W1-01 |
| `#headline-5-env` | W1-34 |
| `#headline-6` | W1-33 |
| `#numbering-examples` | W3-43 |
| `#numbering-unspecced` | W2-46 |

## Findings deliberately not given their own action

- Rows marked OK / Good / no issue in every per-file table (e.g. 01 qa.md, devops.md, ds.md, CLAUDE.md, LICENSE, plugin.json; 04 workflow-probe.sh, report-verdict.md; 05 01-fetch.md, cross-cutting.md, budget-check.sh, read-cards.sh, SKILL.md files marked OK; 06 leafrule.py, packet_dedup/quality, grok-to-claude-jsonl.py, retro-subagent; 07 migrate-v3/v4, fixtures, metrics/SKILL.md, webhook-test; 08 templates, program-template, spec-sync (partially covered); 09 backlog/SKILL.md, terminal-status.sh, doctor/SKILL.md, from-session.sh, fixtures; 10 SPEC-003/004/010/030 OK rows) need no action.
- 06 `packet_dedup.py`/`packet_quality.py` pairwise O(n²) re-normalization: report says fine at event scale — informational only.
- 04 `workflow-probe.sh` unsanitised `maj`/`min`: report calls it harmless (guards cover it) — no action.
- 07 `resolve-model.sh` repo-layer downgrade of qa/council-judge warns by design — recorded inside the metrics item only as context, no change requested.
- 07 `schema.sql` `journal_mode=WAL` prints `wal` — callers already silence it; noted only.
- 10 SPEC-008 optional category dirs — folded into the spec-text item as a wording clarification, not a directory creation.
