Backlog items for milestone **Wave 3 — Quality & UX** of project P-CDT-30, generated from `docs/reviews/2026-09-23-full-review/backlog.json` (branch `claude/craft-loop-review-enhancement-4jq3wb`). These are written as a document because the workspace is at its free-plan issue limit; each item has everything needed to become an issue later.

43 items · High 2 · Medium 14 · Low 27

## Checklist

- [ ] `W3-01` [docs] Add the 7 missing surface pages, fix docs/README index, complete flag docs — High, M
- [ ] `W3-06` [skills] Mark internal skills non-invocable; resolve name collisions; rename code-simplify — High, S
- [ ] `W3-02` [docs] Stale wording pass: docs/commands/* — Medium, S
- [ ] `W3-03` [docs] Stale wording pass: docs/README, docs/setup.md and runbooks — Medium, S
- [ ] `W3-04` [docs] Replace cwd-relative `bash skills/…` snippets with PDH + plugin-dir.sh — Medium, S
- [ ] `W3-07` [skills] Rewrite skill descriptions to lead with “Use when …” — Medium, S
- [ ] `W3-08` [worktree] Release UX: show unmerged/unpushed count, require typing the slug — Medium, S
- [ ] `W3-11` [council] commands/council.md stale text and small logic nits — Medium, S
- [ ] `W3-12` [spec] commands/spec.md content fixes: category token, status vocabulary, gate flag — Medium, S
- [ ] `W3-17` [council] external-reviewer hardening: timeout, gemini sandbox, nit regex, staged diff — Medium, S
- [ ] `W3-18` [agents] Internal agent prompt cleanup: contradictions, routing markers, tool grants — Medium, S
- [ ] `W3-19` [docs] Fix AGENTS.md memory sample and agent rules — Medium, S
- [ ] `W3-20` [docs] README/opencode corrections: strip claims, channels, marketplace key, CC minimum — Medium, S
- [ ] `W3-27` [brainstorm] Single plans root, commit confirmation, respect “just build it” — Medium, S
- [ ] `W3-28` [craft-loop] Program validator, `retire` mode, journal compaction — Medium, M
- [ ] `W3-29` [craft-loop] Fix backlog-burn status drift; add a `target: goal` example; MROOT library — Medium, S
- [ ] `W3-05` [docs] Move maintainer evidence to docs/internal/; trim oversized user pages — Low, M
- [ ] `W3-09` [commands] Small-command cleanup: hints, relative reads, release-train verbs — Low, S
- [ ] `W3-10` [instructions] Strip changelog/ticket-history prose from instruction files — Low, S
- [ ] `W3-13` [council] Make flavors consistent: severity vs confidence, output contract, repo rules — Low, S
- [ ] `W3-14` [council] check-template-vars: digit class, max status, cover workflow.js and fix-ticket — Low, S
- [ ] `W3-15` [fix-ticket] Validate TICKET, enforce worktree check, fail-closed reference workflow — Low, S
- [ ] `W3-16` [council] tier-grade.sh robustness: ERR trap, test glob, fan-in heuristic — Low, S
- [ ] `W3-21` [tools] Make the permission probe's worktree check real; re-probe current CC — Low, S
- [ ] `W3-22` [docs] Refresh SECURITY.md, scout-plugins README, smoke test comment, .gitignore dupe — Low, S
- [ ] `W3-23` [memory] Memory doc cleanups: heredoc claim, command names, UPDATE protocol, compress — Low, S
- [ ] `W3-24` [metrics] Validate numeric/string inputs in emit-outcome, rollup and resolve-model — Low, S
- [ ] `W3-25` [tooling] sync-includes.py: path containment, missing partial, unclosed region — Low, S
- [ ] `W3-26` [memory] domain-glossary: load WTROOT/CONTEXT.md before MROOT — Low, S
- [ ] `W3-30` [refactor] Create worktree only on the bounded route; tidy refactor SKILL — Low, S
- [ ] `W3-31` [standup] Read the task's worktree context; guard jq; fix staleness author check — Low, S
- [ ] `W3-32` [scaffold-project] Stop creating a non-roster `claude` memory dir; SPEC-008 TDD skeleton — Low, S
- [ ] `W3-33` [spec-tooling] Refresh stale consumer lists, examples and fixture text — Low, S
- [ ] `W3-34` [transcript] Linear `bound_tail`; prune dead code and soft-detect probes — Low, S
- [ ] `W3-35` [handoff] Validate numeric/env inputs; atomic packet write; safe webhook JSON — Low, S
- [ ] `W3-36` [autopilot] Cap card rationale; batch loc-exclude via check-attr --stdin — Low, S
- [ ] `W3-37` [epic] epic-lib hardening: test-hook eval, env bypass, parent lookup, mark-done, waves — Low, S
- [ ] `W3-38` [kickoff] Cleanup: Task Map printf, requires_council in template, flag handling — Low, S
- [ ] `W3-39` [doctor] Split doctor.sh into checks/<group>.sh; single stale-lock TTL logic — Low, L
- [ ] `W3-40` [worktree] Move `.wt-lock` out of the worktree; base `ensure -b` on default branch — Low, M
- [ ] `W3-41` [release] check-ship-history: remove dead paths, O(T) prev lookup — Low, S
- [ ] `W3-42` [specs] Normalize spec headers, slim the TDD index, fix per-spec text drift — Low, S
- [ ] `W3-43` [docs] Use obviously fake spec IDs in docs examples — Low, S

## Items

### W3-01 · [docs] Add the 7 missing surface pages, fix docs/README index, complete flag docs
**Priority** High · **Effort** M · **Labels** Improvement · **Ticket group** —

**Problem**
adjust-agent, doctor, release-train, tdd-gate, backlog, ci-watch and release have no `docs/commands/` page; `docs/README.md` labels `/doctor`, `/adjust-agent`, `/release-train`, `/tdd-gate` as "skill" (`:41,63,69,74`), omits handoff-stm-dogfood from Guides, and never says skill entries are namespaced `/dev-team:…`. Undocumented flags: council `--external[=codex|gemini]`, `--council-tier=`, `--why`; spec `reflect --phase N`, `--report`; doctor groups `version, memory, settings, hooks, worktree, deps, plugin` (commands/doctor.md:27 lists only transcript/config); audit `-h` and how to produce the apply FILE (`--json > FILE`); `docs/commands/audit.md:51` links /doctor to README; orchestrate usage omits flag forms.

**Fix**
- Write the 7 pages; fix the Docs column; add namespacing note.
- Document the missing flags and doctor groups; add the audit FILE example.
- Extend docs-drift `cmd-index` to check docs/README rows and page existence.

**Acceptance**
- docs-drift fails if a surface lacks a page.
- Every argument-hint flag appears in its page (check).
- Link checker passes.

**Source**
- [02-commands-docs.md](02-commands-docs.md) #8
- [02-commands-docs.md](02-commands-docs.md) #16
- [02-commands-docs.md](02-commands-docs.md) #coverage-matrix
- [02-commands-docs.md](02-commands-docs.md) #F:docs/README.md(1,3,4)
- [02-commands-docs.md](02-commands-docs.md) #F:docs/commands/council.md
- [02-commands-docs.md](02-commands-docs.md) #F:docs/commands/spec.md(flags)
- [02-commands-docs.md](02-commands-docs.md) #F:commands/doctor.md(groups)
- [02-commands-docs.md](02-commands-docs.md) #F:docs/commands/audit.md
- [02-commands-docs.md](02-commands-docs.md) #F:docs/commands/orchestrate.md(usage)
- [README.md](README.md) #4.7
- [README.md](README.md) #wave3-docs

Sources: `02-commands-docs.md#8`, `02-commands-docs.md#16`, `02-commands-docs.md#coverage-matrix`, `02-commands-docs.md#F:docs/README.md(1,3,4)`, `02-commands-docs.md#F:docs/commands/council.md`, `02-commands-docs.md#F:docs/commands/spec.md(flags)`, `02-commands-docs.md#F:commands/doctor.md(groups)`, `02-commands-docs.md#F:docs/commands/audit.md`, `02-commands-docs.md#F:docs/commands/orchestrate.md(usage)`, `README.md#4.7`, `README.md#wave3-docs`

### W3-06 · [skills] Mark internal skills non-invocable; resolve name collisions; rename code-simplify
**Priority** High · **Effort** S · **Labels** Improvement · **Ticket group** —

**Problem**
~20 internal/backend skills (fix-ticket, init-orchestration, scaffold-project, standup, security-scan, code-simplify, blunt, focus, domain-glossary, memory-*, metrics, model-map, retro-*, skill-lint, spec-tooling, transcript-parse, transcript-mirror, validate-memory, autopilot, docs-drift) lack `user-invocable: false` and appear as `/dev-team:*`; several describe themselves as "not a user entry". Nine commands share a `name:` with a skill (audit, bug-hunt, council, craft-loop, debug, doctor, epic, handoff, release-train) — if the skill wins, `/doctor` could load the check table. blunt/focus (`:6-7,13`) and `commands/mode.md:177` still say "deprecation stub" (none exist). `code-simplify` clashes with built-in `/simplify`.

**Fix**
- Add `user-invocable: false` (and `disable-model-invocation: true` where auto-trigger is harmful).
- Rename backend skill names or make them non-invocable for the 9 collisions; verify resolution.
- Delete stub wording; rename code-simplify (e.g. `post-approve-polish`) and update callers.

**Acceptance**
- Smoke asserts internal skills carry the flag.
- No duplicate `name:` between commands and invocable skills.
- grep `deprecation stub` returns only history.

**Source**
- [02-commands-docs.md](02-commands-docs.md) #9
- [02-commands-docs.md](02-commands-docs.md) #cross-7
- [02-commands-docs.md](02-commands-docs.md) #coverage-matrix-internal
- [02-commands-docs.md](02-commands-docs.md) #F:docs/commands/transcript-mirror.md(invocable)
- [08-workflow-skills.md](08-workflow-skills.md) #14
- [08-workflow-skills.md](08-workflow-skills.md) #F:blunt/SKILL.md
- [08-workflow-skills.md](08-workflow-skills.md) #F:focus/SKILL.md
- [08-workflow-skills.md](08-workflow-skills.md) #F:standup/SKILL.md(menu)
- [08-workflow-skills.md](08-workflow-skills.md) #overlap-internal
- [08-workflow-skills.md](08-workflow-skills.md) #overlap-code-simplify-name
- [02-commands-docs.md](02-commands-docs.md) #F:commands/mode.md(stub)
- [README.md](README.md) #4.7
- [README.md](README.md) #wave3-invocable

Sources: `02-commands-docs.md#9`, `02-commands-docs.md#cross-7`, `02-commands-docs.md#coverage-matrix-internal`, `02-commands-docs.md#F:docs/commands/transcript-mirror.md(invocable)`, `08-workflow-skills.md#14`, `08-workflow-skills.md#F:blunt/SKILL.md`, `08-workflow-skills.md#F:focus/SKILL.md`, `08-workflow-skills.md#F:standup/SKILL.md(menu)`, `08-workflow-skills.md#overlap-internal`, `08-workflow-skills.md#overlap-code-simplify-name`, `02-commands-docs.md#F:commands/mode.md(stub)`, `README.md#4.7`, `README.md#wave3-invocable`

### W3-02 · [docs] Stale wording pass: docs/commands/*
**Priority** Medium · **Effort** S · **Labels** Tech Debt · **Ticket group** —

**Problem**
Stale or contradictory text in `docs/commands/`: brainstorm.md:94 "All four rounds run even if 'just build it'" vs :79 and the skill's "Round 4 (if still ambiguous)"; debug.md:10 "removed at v1.0.0" vs :104 "deleted at v1.1.0"; memory.md:5 "v1.0.0" and broken anchor `../setup.md#memory-configuration-memory-config` (real: `…configuration--memory-config`); mode.md:15 "removed at v1.0.0" vs :72 "Legacy stubs"; orchestrate.md duplicate step "12." (:67/68); retro.md:272 "/kickoff (Step 9)" (skill 8b, kickoff doc 10); review-and-commit.md examples use `/tmp/review.md` (use `${TMPDIR:-/tmp}`); setup.md:9 `dontAsk` vs :49 `auto`, `--refresh` "re-seed cortex" vs no-rescan, missing `--skip-doctor`, ":69 8 mappable agents" (10); spec.md "Removed at v1.0.0", "9-section skeleton" shows 5; transcript-mirror.md:122 dev-log text.

**Fix**
- Apply: "deleted in v1.1.0"; `auto` posture; 10 mappable agents; correct `--refresh` semantics; add `--skip-doctor`; fix anchors, step numbers, skeleton, round rule, TMPDIR examples; delete dev-log text.

**Acceptance**
- Link/anchor checker passes over docs/.
- grep for `v1.0.0` removal wording and `dontAsk` default returns no hits in docs/commands.
- docs-drift passes.

**Source**
- [02-commands-docs.md](02-commands-docs.md) #11
- [02-commands-docs.md](02-commands-docs.md) #cross-4
- [02-commands-docs.md](02-commands-docs.md) #cross-5
- [02-commands-docs.md](02-commands-docs.md) #cross-9
- [02-commands-docs.md](02-commands-docs.md) #F:docs/commands/brainstorm.md
- [02-commands-docs.md](02-commands-docs.md) #F:docs/commands/debug.md
- [02-commands-docs.md](02-commands-docs.md) #F:docs/commands/memory.md
- [02-commands-docs.md](02-commands-docs.md) #F:docs/commands/mode.md
- [02-commands-docs.md](02-commands-docs.md) #F:docs/commands/orchestrate.md(12)
- [02-commands-docs.md](02-commands-docs.md) #F:docs/commands/retro.md
- [02-commands-docs.md](02-commands-docs.md) #F:docs/commands/review-and-commit.md
- [02-commands-docs.md](02-commands-docs.md) #F:docs/commands/setup.md
- [02-commands-docs.md](02-commands-docs.md) #F:docs/commands/spec.md(stale)
- [02-commands-docs.md](02-commands-docs.md) #F:docs/commands/transcript-mirror.md(devlog)
- [README.md](README.md) #4.7-stale

Sources: `02-commands-docs.md#11`, `02-commands-docs.md#cross-4`, `02-commands-docs.md#cross-5`, `02-commands-docs.md#cross-9`, `02-commands-docs.md#F:docs/commands/brainstorm.md`, `02-commands-docs.md#F:docs/commands/debug.md`, `02-commands-docs.md#F:docs/commands/memory.md`, `02-commands-docs.md#F:docs/commands/mode.md`, `02-commands-docs.md#F:docs/commands/orchestrate.md(12)`, `02-commands-docs.md#F:docs/commands/retro.md`, `02-commands-docs.md#F:docs/commands/review-and-commit.md`, `02-commands-docs.md#F:docs/commands/setup.md`, `02-commands-docs.md#F:docs/commands/spec.md(stale)`, `02-commands-docs.md#F:docs/commands/transcript-mirror.md(devlog)`, `README.md#4.7-stale`

### W3-03 · [docs] Stale wording pass: docs/README, docs/setup.md and runbooks
**Priority** Medium · **Effort** S · **Labels** Tech Debt · **Ticket group** —

**Problem**
`docs/README.md:24` "`dontAsk` ship default" (now `auto`). `docs/setup.md`: `:5` calls deleted `/init-team` "legacy"; `:78` "Migrates v1→v2 schema" (now v4); `:130-133` and the orchestration section list 2 approvals (3 incl. escalation-gate, SPEC-031) and omit the escalation-gate hook; `:85` "Safe to re-run — updates cortex" conflicts with `--refresh`. Runbooks: manual.md `cat .claude/memory/*/cortex.md` works only in fallback mode, `echo "\n…" >>` writes a literal `\n`, `go test ./...` is project-specific, broken setup anchor; memory.md troubleshooting "delete and re-bootstrap" destroys data (point to `/memory validate`/`export`) and omits `/memory validate` from hygiene; migrate-to-v1 CDT-68 lists 2 approvals; onboarding lacks `/doctor` and `/setup project` steps; orchestrate.md uses an undocumented inline-text form, "Step 11" vs 12, broken anchor; scheduled-retro.md "SlashCommand" naming, literal `&lt;` (`:110`).

**Fix**
- Fix each item above; use `printf` in manual.md; make examples project-neutral; add missing onboarding steps.

**Acceptance**
- Anchor checker passes.
- No destructive advice without a backup step.
- Approval count is 3 everywhere (grep).

**Source**
- [02-commands-docs.md](02-commands-docs.md) #11
- [02-commands-docs.md](02-commands-docs.md) #F:docs/README.md(2)
- [02-commands-docs.md](02-commands-docs.md) #F:docs/setup.md
- [02-commands-docs.md](02-commands-docs.md) #F:docs/runbooks/manual.md(misc)
- [02-commands-docs.md](02-commands-docs.md) #F:docs/runbooks/memory.md
- [02-commands-docs.md](02-commands-docs.md) #F:docs/runbooks/migrate-to-v1.md
- [02-commands-docs.md](02-commands-docs.md) #F:docs/runbooks/onboarding.md
- [02-commands-docs.md](02-commands-docs.md) #F:docs/runbooks/orchestrate.md
- [02-commands-docs.md](02-commands-docs.md) #F:docs/runbooks/scheduled-retro.md(misc)
- [README.md](README.md) #4.7-stale

Sources: `02-commands-docs.md#11`, `02-commands-docs.md#F:docs/README.md(2)`, `02-commands-docs.md#F:docs/setup.md`, `02-commands-docs.md#F:docs/runbooks/manual.md(misc)`, `02-commands-docs.md#F:docs/runbooks/memory.md`, `02-commands-docs.md#F:docs/runbooks/migrate-to-v1.md`, `02-commands-docs.md#F:docs/runbooks/onboarding.md`, `02-commands-docs.md#F:docs/runbooks/orchestrate.md`, `02-commands-docs.md#F:docs/runbooks/scheduled-retro.md(misc)`, `README.md#4.7-stale`

### W3-04 · [docs] Replace cwd-relative `bash skills/…` snippets with PDH + plugin-dir.sh
**Priority** Medium · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
Docs use cwd-relative paths that don't exist in a user project on an installed plugin (AGENTS.md forbids this): `docs/commands/transcript-mirror.md:20,192-222,240` (`skills/transcript-mirror/hook-shim.sh`, cron `cd <PROJECT> && bash skills/…`), `docs/runbooks/manual.md` (`bash skills/worktree-lib.sh ensure/release`), `docs/runbooks/scheduled-retro.md:135-139`, `docs/runbooks/handoff-stm-dogfood.md:70,137-141,166`.

**Fix**
- Use the PDH + `plugin-dir.sh file …` pattern already shown in migrate-to-v1.
- docs-drift check: flag `bash skills/` in docs outside a maintainer-only section.

**Acceptance**
- grep finds no cwd-relative `bash skills/` in user docs.
- Snippets run from a temp project with the plugin installed in cache layout.
- docs-drift rule has a bite fixture.

**Source**
- [02-commands-docs.md](02-commands-docs.md) #10
- [02-commands-docs.md](02-commands-docs.md) #cross-6
- [02-commands-docs.md](02-commands-docs.md) #F:docs/commands/transcript-mirror.md(paths)
- [02-commands-docs.md](02-commands-docs.md) #F:docs/runbooks/manual.md(paths)
- [02-commands-docs.md](02-commands-docs.md) #F:docs/runbooks/scheduled-retro.md(paths)
- [02-commands-docs.md](02-commands-docs.md) #F:docs/runbooks/handoff-stm-dogfood.md(paths)
- [README.md](README.md) #wave3-cwd-runbooks

Sources: `02-commands-docs.md#10`, `02-commands-docs.md#cross-6`, `02-commands-docs.md#F:docs/commands/transcript-mirror.md(paths)`, `02-commands-docs.md#F:docs/runbooks/manual.md(paths)`, `02-commands-docs.md#F:docs/runbooks/scheduled-retro.md(paths)`, `02-commands-docs.md#F:docs/runbooks/handoff-stm-dogfood.md(paths)`, `README.md#wave3-cwd-runbooks`

### W3-07 · [skills] Rewrite skill descriptions to lead with “Use when …”
**Priority** Medium · **Effort** S · **Labels** Improvement · **Ticket group** —

**Problem**
Skill descriptions are ticket jargon rather than triggers: `skills/bug-hunt/SKILL.md:3-13` ("CDT-138/C3", "SPEC-013 blind") with no plain "use when…"; review-and-commit lacks "use when about to commit". Weak descriptions hurt skill discovery and routing.

**Fix**
- Lead every user-facing skill description with "Use when …" (e.g. bug-hunt: "Use when asked to find/audit unknown bugs in a path…"); move CDT/SPEC ids into the body.
- Add a smoke/skill-lint check that user-invocable descriptions start with "Use when" (warning).

**Acceptance**
- All user-invocable skills start with 'Use when' (check).
- No CDT-/SPEC- ids in description fields.
- Smoke passes.

**Source**
- [08-workflow-skills.md](08-workflow-skills.md) #15
- [08-workflow-skills.md](08-workflow-skills.md) #F:bug-hunt/SKILL.md(frontmatter)
- [08-workflow-skills.md](08-workflow-skills.md) #F:review-and-commit/SKILL.md(description)
- [README.md](README.md) #wave3-descriptions

Sources: `08-workflow-skills.md#15`, `08-workflow-skills.md#F:bug-hunt/SKILL.md(frontmatter)`, `08-workflow-skills.md#F:review-and-commit/SKILL.md(description)`, `README.md#wave3-descriptions`

### W3-08 · [worktree] Release UX: show unmerged/unpushed count, require typing the slug
**Priority** Medium · **Effort** S · **Labels** Improvement · **Ticket group** —

**Problem**
`commands/worktree.md:75-77` confirms "removes the worktree and feat/<slug> branch if clean", understating that the lib force-deletes branches (`branch -D`) and falls back to `--force`. `docs/commands/worktree.md` doesn't warn about this; `docs/commands/wrap-ticket.md` Step 9 claims `git worktree remove` without force, while the skill calls `worktree-lib.sh release` (SKILL:437-440).

**Fix**
- Before confirming, print `git log --oneline <base>..feat/<slug>` count and ahead-of-upstream count; require typing the slug when non-zero (both /worktree release and /wrap-ticket).
- Update both doc pages to describe the (now guarded) behavior.

**Acceptance**
- Prompt text shows counts (static test).
- Docs match lib behavior (docs-drift or grep test).
- Non-zero count path requires slug.

**Source**
- [02-commands-docs.md](02-commands-docs.md) #7
- [02-commands-docs.md](02-commands-docs.md) #F:commands/worktree.md
- [02-commands-docs.md](02-commands-docs.md) #F:docs/commands/worktree.md
- [02-commands-docs.md](02-commands-docs.md) #F:docs/commands/wrap-ticket.md
- [02-commands-docs.md](02-commands-docs.md) #cross-8
- [README.md](README.md) #wave3-worktree-ux

Sources: `02-commands-docs.md#7`, `02-commands-docs.md#F:commands/worktree.md`, `02-commands-docs.md#F:docs/commands/worktree.md`, `02-commands-docs.md#F:docs/commands/wrap-ticket.md`, `02-commands-docs.md#cross-8`, `README.md#wave3-worktree-ux`

### W3-11 · [council] commands/council.md stale text and small logic nits
**Priority** Medium · **Effort** S · **Labels** Tech Debt · **Ticket group** —

**Problem**
`commands/council.md:463-470` model-map intro says "`ic5` investigators, `ic4` cross-reviewers… fallback `ic5`→`ic4`", but the spawns (`:583,805`) and SKILL.md (`:99-105,386-388,679-684`) use `dev-team:finder` with fallback `finder`→`ic5` (C1, P1). Phase 3 `--why` list and Rules (`:663-667,744-748,1377-1379`) omit `skipped (council_tier: light)` (C9). The Phase 2.5 "fewer than 3 investigators" bypass (`:758-760`) doesn't say per claim or per run (C10). `TOKENS_FILE=…-$$.json` (`:1039`) is predictable and never cleaned (C11). "Phase 7 (feedback memory)" appears only in Rules (`:1380`) (C13). WEAK_EVIDENCE "≤ 25th percentile" (`:835-839`) always flags ≥1 bundle even when all are strong (C14).

**Fix**
- Update the model-map intro to finder/fallback ic5; add the light-tier why string; state per-claim bypass; `mktemp` + cleanup for TOKENS_FILE; introduce or drop Phase 6/7 references; add an absolute floor to WEAK_EVIDENCE.

**Acceptance**
- check-template-vars passes.
- grep: no `ic5` investigator wording.
- Council tests pass.

**Source**
- [03-large-commands.md](03-large-commands.md) #C1
- [03-large-commands.md](03-large-commands.md) #C9
- [03-large-commands.md](03-large-commands.md) #C10
- [03-large-commands.md](03-large-commands.md) #C11
- [03-large-commands.md](03-large-commands.md) #C13
- [03-large-commands.md](03-large-commands.md) #C14

Sources: `03-large-commands.md#C1`, `03-large-commands.md#C9`, `03-large-commands.md#C10`, `03-large-commands.md#C11`, `03-large-commands.md#C13`, `03-large-commands.md#C14`

### W3-12 · [spec] commands/spec.md content fixes: category token, status vocabulary, gate flag
**Priority** Medium · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
`commands/spec.md` skeleton include (`:416`, source `skills/spec-tooling/spec-skeleton.md`) hard-codes `**Category**: core` though Step 2 offers PERF/SAFE/COMPAT/ARCH (S3). The `find` example (`:490-503`) shows `**Status**: ✅`/`🔄 UPDATED`, contradicting the lifecycle vocabulary enforced at `:81,580-585` (S4). The canonical exclude set (`:110-117`, SPEC-008:178-181) drops `*.md`/`*.json`, so on markdown/bash repos (this plugin) Phase 2 finds no source and always skips code alignment (S5, spec-level). `--gate` without `--tests` is undefined (`:32,66`, S6). Example `AUTH-003` uses a disallowed prefix (`:386`, S7). "Categories (derived from ID prefix or Coverage column)" (`:532`) — Coverage has no category (S8).

**Fix**
- Add a `<CATEGORY>` token to spec-skeleton.md and sync; fix the find example; make `--gate` imply `--tests` or hard-fail; use an allowed prefix; derive category from prefix/directory.
- Raise S5 with SPEC-008's owner (allow-list markdown/bash sources for Phase 2 when no framework is detected).

**Acceptance**
- sync-includes check clean.
- Created non-core spec has the right category (test).
- SPEC-008 decision recorded.

**Source**
- [03-large-commands.md](03-large-commands.md) #S3
- [03-large-commands.md](03-large-commands.md) #S4
- [03-large-commands.md](03-large-commands.md) #S5
- [03-large-commands.md](03-large-commands.md) #S6
- [03-large-commands.md](03-large-commands.md) #S7
- [03-large-commands.md](03-large-commands.md) #S8

Sources: `03-large-commands.md#S3`, `03-large-commands.md#S4`, `03-large-commands.md#S5`, `03-large-commands.md#S6`, `03-large-commands.md#S7`, `03-large-commands.md#S8`

### W3-17 · [council] external-reviewer hardening: timeout, gemini sandbox, nit regex, staged diff
**Priority** Medium · **Effort** S · **Labels** Bug, Security · **Ticket group** —

**Problem**
`skills/council/external-reviewer.sh` has no timeout on the codex/gemini call (`:278-295`), so it can hang the council; gemini runs with `-p` and no sandbox/approval flag (`:292`) while codex correctly uses `-s read-only`; the severity heuristic `test("(?i)nit|…")` (`:162`) matches "unit"/"init" ("missing unit tests" → nitpick); `codex review --uncommitted` reviews unstaged+untracked, not the staged diff diff-mode audits; confidence is hardcoded to 80, exactly on the threshold.

**Fix**
- Wrap CLI calls in `_timeout` (default 300 s, `emit_error` on expiry).
- Add gemini sandbox/approval flags; word-boundary `\bnit(pick)?\b`; use `git diff --cached` context for finding[]; set confidence below/above threshold deliberately (document).

**Acceptance**
- Test with a stub CLI that sleeps: times out cleanly.
- 'missing unit tests' classified correctly.
- Gemini command line includes sandbox flag.

**Source**
- [04-council.md](04-council.md) #14
- [04-council.md](04-council.md) #F:council/external-reviewer.sh(1,2,4-6)
- [README.md](README.md) #wave3-external-reviewer

Sources: `04-council.md#14`, `04-council.md#F:council/external-reviewer.sh(1,2,4-6)`, `README.md#wave3-external-reviewer`

### W3-18 · [agents] Internal agent prompt cleanup: contradictions, routing markers, tool grants
**Priority** Medium · **Effort** S · **Labels** Tech Debt · **Ticket group** —

**Problem**
`agents/pm.md:60` asks to escalate "to an Opus-tier model" though pm already runs on opus. `tech-lead.md:65` "Think out loud" conflicts with terse/ultra (`:24`); `:69` "alternatives only if asked" vs the Technical Spec format's "Alternatives considered" (`:74`). `ic5.md:71`/`ic4.md:55` "Commit after each GREEN phase" conflicts with gated flows and the single-folded-commit rule; `ic4.md:98` "Merge without QA sign-off" is noise. finder/debugger grant `SendMessage` (SPEC-003:104) while saying "stay blind" and AGENTS.md:218 says no addressable parent; "read-only" is prompt-enforced only (Bash can mutate); descriptions lack an "internal — do not route" marker, and debugger's description packs ticket jargon. council-judge `:26` "MUST NOT recommend fixes" vs `suggestion` field (`:42`); dead cortex-injection text at `:16,49`; `tools: ""` semantics unverified.

**Fix**
- Reword pm escalation; reconcile tech-lead terse mode; "commit only when the caller owns commits"; drop the ic4 merge line.
- Prefix finder/debugger descriptions "Internal — spawned by X only"; reconsider SendMessage in SPEC-003; document read-only limits.
- council-judge: allow or drop `suggestion`; remove dead text; verify `tools: ""` yields no tools (test with CC loader or document).

**Acceptance**
- smoke passes; grep shows no contradictory lines.
- SPEC-003 decision on SendMessage recorded.
- council-judge tools behavior verified.

**Source**
- [01-agents-infra.md](01-agents-infra.md) #11
- [01-agents-infra.md](01-agents-infra.md) #F:agents/pm.md
- [01-agents-infra.md](01-agents-infra.md) #F:agents/tech-lead.md
- [01-agents-infra.md](01-agents-infra.md) #F:agents/ic5.md(commit)
- [01-agents-infra.md](01-agents-infra.md) #F:agents/ic4.md
- [01-agents-infra.md](01-agents-infra.md) #F:agents/finder.md
- [01-agents-infra.md](01-agents-infra.md) #F:agents/debugger.md
- [01-agents-infra.md](01-agents-infra.md) #F:agents/council-judge.md
- [01-agents-infra.md](01-agents-infra.md) #cross-5-readonly
- [01-agents-infra.md](01-agents-infra.md) #cross-1-pm

Sources: `01-agents-infra.md#11`, `01-agents-infra.md#F:agents/pm.md`, `01-agents-infra.md#F:agents/tech-lead.md`, `01-agents-infra.md#F:agents/ic5.md(commit)`, `01-agents-infra.md#F:agents/ic4.md`, `01-agents-infra.md#F:agents/finder.md`, `01-agents-infra.md#F:agents/debugger.md`, `01-agents-infra.md#F:agents/council-judge.md`, `01-agents-infra.md#cross-5-readonly`, `01-agents-infra.md#cross-1-pm`

### W3-19 · [docs] Fix AGENTS.md memory sample and agent rules
**Priority** Medium · **Effort** S · **Labels** Bug, Tech Debt · **Ticket group** —

**Problem**
`AGENTS.md:151-160` tests `USE_DB` before `MEMDB` is assigned, so the sample always yields `USE_DB=false` in a fresh shell; the sample SQL (`:163-178`) drifted from `skills/agent-memory/protocol.md` (no `.timeout`, selects `content` not `type, content`). `:195-196` lists only project-init and distiller as directive-exempt (SPEC-003:19 also exempts finder, debugger, council-judge; SPEC-001:18,76,89 has the same incomplete list). `:255` lists required agent fields without `effort` (SPEC-003:20; `mode:` undocumented). `:220` "send a status update to the team lead" vs `:218` (no addressable parent). `:36` relies on `core.hooksPath githooks` with no contributor doc for `install-git-hooks.sh`.

**Fix**
- Replace the sample with a pointer to protocol.md; extend the exempt list in AGENTS.md and SPEC-001; add `effort`/`mode` to required fields; fix `:220`; document `bash skills/release/install-git-hooks.sh`.

**Acceptance**
- docs-drift passes; SPEC-001 and AGENTS.md lists match SPEC-003.
- No runnable memory sample with ordering bug remains.
- Contributor hook setup documented.

**Source**
- [01-agents-infra.md](01-agents-infra.md) #12
- [01-agents-infra.md](01-agents-infra.md) #F:AGENTS.md
- [07-memory.md](07-memory.md) #cross-spec-drift-agents
- [10-specs.md](10-specs.md) #cross-directive-exclusions
- [10-specs.md](10-specs.md) #SPEC-001

Sources: `01-agents-infra.md#12`, `01-agents-infra.md#F:AGENTS.md`, `07-memory.md#cross-spec-drift-agents`, `10-specs.md#cross-directive-exclusions`, `10-specs.md#SPEC-001`

### W3-20 · [docs] README/opencode corrections: strip claims, channels, marketplace key, CC minimum
**Priority** Medium · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
README: `:24,:280` say only `tools:` is stripped (install.sh:240 strips `model:` too); `:298` says agents come from "install.sh symlinks" (copied); `:282` "Both scripts auto-detect opencode" (uninstall doesn't); `:301-313` opencode `agents.paths`/`commands.paths` keys look invented and opencode config is strict — may break user config (verify); `:266-274` `extraKnownMarketplaces` key is `dev-team` but marketplace name is `cold-dark-void` (marketplace.json:2) and no `enabledPlugins`; `:139-140` lists 3 internal agents vs 5 at `:55`; `:330` "Claude Code 2.x+" understates the minimum (effort frontmatter, `auto` mode; probe 2.1.190, CHANGELOG cites 2.1.236); `:14` no warning against installing `dev-team` and `dev-team-edge` together (same agents/commands; marketplace.json:17 vs plugin.json name). marketplace.json lacks `owner.url`/`metadata.description`.

**Fix**
- Correct each claim; verify or remove the opencode snippet; fix the marketplace key and add `enabledPlugins`; state the real CC minimum; warn about dual channels; fill marketplace metadata.

**Acceptance**
- docs-drift manifest checks pass.
- opencode snippet validated against opencode schema (or removed).
- Internal-agent lists consistent.

**Source**
- [01-agents-infra.md](01-agents-infra.md) #13
- [01-agents-infra.md](01-agents-infra.md) #F:README.md
- [01-agents-infra.md](01-agents-infra.md) #F:.claude-plugin/marketplace.json
- [01-agents-infra.md](01-agents-infra.md) #cross-9

Sources: `01-agents-infra.md#13`, `01-agents-infra.md#F:README.md`, `01-agents-infra.md#F:.claude-plugin/marketplace.json`, `01-agents-infra.md#cross-9`

### W3-27 · [brainstorm] Single plans root, commit confirmation, respect “just build it”
**Priority** Medium · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
`skills/brainstorm/SKILL.md:249` saves plans under `$WTROOT/.claude/plans` while debug and refactor read `$MROOT/.claude/plans`, so a worktree brainstorm is invisible to them. Step 4b (`:270-275`) runs `git commit` without confirmation, unlike the always-ask discipline elsewhere. The Step 4 block (`:247-250`) is a comment-only no-op. "NEVER skip rounds even if user says 'just build it'" overrides the user (docs/commands/brainstorm.md has the matching contradiction).

**Fix**
- Use `$MROOT/.claude/plans` everywhere; ask before the Step 4b commit; make Step 4 real or remove it; allow skipping to Round 4 on explicit user request (align docs).

**Acceptance**
- Static test: plans path uses MROOT.
- Commit step contains a confirmation gate.
- Docs and skill agree on round skipping.

**Source**
- [08-workflow-skills.md](08-workflow-skills.md) #21
- [08-workflow-skills.md](08-workflow-skills.md) #F:brainstorm/SKILL.md

Sources: `08-workflow-skills.md#21`, `08-workflow-skills.md#F:brainstorm/SKILL.md`

### W3-28 · [craft-loop] Program validator, `retire` mode, journal compaction
**Priority** Medium · **Effort** M · **Labels** Feature, Improvement · **Ticket group** —

**Problem**
`skills/craft-loop` meets SPEC-020's MUSTs but "quality checklist passes" is model judgement only — no validator for frontmatter keys/enums, the 6 section headings, the default Never list; the checklist omits SPEC-020 "Program format" MUSTs (e.g. `# Journal entry schema`). No `retire` mode (`:42-44` "format/manual only"); list-mode open-decision count is left to the model. Journals grow without bound and every firing reads the whole file; `examples/spec-sync.md` repeats the full spec-ID list in every `State`, growing quadratically, and never defines "current sweep".

**Fix**
- `check-program.sh <file>` (frontmatter, headings, Never items, journal-read first/append last); craft mode runs it before presenting; `test.sh` runs it on examples.
- `/craft-loop retire <name>`; template compaction rule (>200 lines → `## Summary`); `journal-stats.sh`; spec-sync side ledger.

**Acceptance**
- test.sh: both examples pass the validator; a broken fixture fails.
- Retired program hidden from list unless `--all`.
- SPEC-020 updated for retire.

**Source**
- [08-workflow-skills.md](08-workflow-skills.md) #18
- [08-workflow-skills.md](08-workflow-skills.md) #19
- [08-workflow-skills.md](08-workflow-skills.md) #F:craft-loop/SKILL.md
- [08-workflow-skills.md](08-workflow-skills.md) #F:craft-loop/examples/spec-sync.md
- [README.md](README.md) #wave3-craft-loop

Sources: `08-workflow-skills.md#18`, `08-workflow-skills.md#19`, `08-workflow-skills.md#F:craft-loop/SKILL.md`, `08-workflow-skills.md#F:craft-loop/examples/spec-sync.md`, `README.md#wave3-craft-loop`

### W3-29 · [craft-loop] Fix backlog-burn status drift; add a `target: goal` example; MROOT library
**Priority** Medium · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
`skills/craft-loop/examples/backlog-burn.md` marks `[DONE]`/`[EVAPORATED]` (`:25,31`) while `backlog/SKILL.md:343` uses `[COMPLETED]` and moves entries to `## Completed`; it bypasses the SPEC-009 Linear-first dual-write (Linear stays open). No `target: goal` example ships, so the goal path is untested. List mode uses `$WTROOT/.claude/loops` (`:157`) while craft writes a relative `.claude/loops/`, giving each worktree its own library.

**Fix**
- Use `[COMPLETED]` and the section move via `skills/backlog` programmatic write-back.
- Add `examples/<x>-goal.md` with `target: goal`.
- Use `$MROOT/.claude/loops` for both craft and list.

**Acceptance**
- Validator passes all three examples.
- backlog-burn uses backlog write-back (grep).
- List and craft use the same root.

**Source**
- [08-workflow-skills.md](08-workflow-skills.md) #20
- [08-workflow-skills.md](08-workflow-skills.md) #F:craft-loop/examples/backlog-burn.md
- [08-workflow-skills.md](08-workflow-skills.md) #F:craft-loop/SKILL.md(list-root)

Sources: `08-workflow-skills.md#20`, `08-workflow-skills.md#F:craft-loop/examples/backlog-burn.md`, `08-workflow-skills.md#F:craft-loop/SKILL.md(list-root)`

### W3-05 · [docs] Move maintainer evidence to docs/internal/; trim oversized user pages
**Priority** Low · **Effort** M · **Labels** Tech Debt · **Ticket group** —

**Problem**
`docs/runbooks/handoff-stm-dogfood.md` is an internal AC-16 ship gate mixed into user docs and missing from the index; `docs/runbooks/permission-posture-matrix.md` is an evidence log whose artifact index lists `/tmp/…` scratch dirs that don't exist. `docs/commands/bug-hunt.md` (~330 lines) largely restates SPEC-034; `docs/commands/handoff.md` is 444 lines.

**Fix**
- Move both evidence docs under `docs/internal/` (or label them maintainer-only) and drop dead `/tmp` references.
- Trim bug-hunt and handoff pages to user essentials, linking to the specs.

**Acceptance**
- docs/README distinguishes user vs internal docs.
- Link checker passes.
- Each trimmed page < 150 lines.

**Source**
- [02-commands-docs.md](02-commands-docs.md) #15
- [02-commands-docs.md](02-commands-docs.md) #F:docs/runbooks/handoff-stm-dogfood.md
- [02-commands-docs.md](02-commands-docs.md) #F:docs/runbooks/permission-posture-matrix.md
- [02-commands-docs.md](02-commands-docs.md) #F:docs/commands/bug-hunt.md
- [02-commands-docs.md](02-commands-docs.md) #F:docs/commands/handoff.md(length)
- [README.md](README.md) #wave3-docs-internal

Sources: `02-commands-docs.md#15`, `02-commands-docs.md#F:docs/runbooks/handoff-stm-dogfood.md`, `02-commands-docs.md#F:docs/runbooks/permission-posture-matrix.md`, `02-commands-docs.md#F:docs/commands/bug-hunt.md`, `02-commands-docs.md#F:docs/commands/handoff.md(length)`, `README.md#wave3-docs-internal`

### W3-09 · [commands] Small-command cleanup: hints, relative reads, release-train verbs
**Priority** Low · **Effort** S · **Labels** Tech Debt · **Ticket group** —

**Problem**
Minor issues in small commands: `commands/adjust-agent.md` step order (Dashboard=3 … Model=7) but routing jumps to 7 first; `commands/craft-loop.md` has no `argument-hint` (usage only in description); `commands/debug.md:61` cites bare `SPEC-029` without a path; `commands/mode.md` says "Read skills/focus/SKILL.md" with a cwd-relative path (fails on installs; use the Skill tool or PDH); `commands/release-train.md` `dry-run` claims "zero mutation" but Step 2 always runs `init` (`:30`), the `register` example drops `--assumed` and silently defaults `--bump minor` (`:39`), and `status` maps to train-lib `list` ambiguously (`:22`); `commands/audit.md` resolves PDH twice (Steps 1 and 2).

**Fix**
- Reorder/renumber adjust-agent steps; add craft-loop hint; path for SPEC-029; Skill-tool reads in mode.md.
- release-train: skip init in dry-run (or document), show `--assumed`/`--bump`, clarify status→list.
- Resolve PDH once in audit.md.

**Acceptance**
- Smoke passes with new hints.
- Dry-run leaves the repo unchanged (test).
- No cwd-relative Read in mode.md.

**Source**
- [02-commands-docs.md](02-commands-docs.md) #F:commands/adjust-agent.md(5)
- [02-commands-docs.md](02-commands-docs.md) #F:commands/craft-loop.md
- [02-commands-docs.md](02-commands-docs.md) #F:commands/debug.md
- [02-commands-docs.md](02-commands-docs.md) #F:commands/mode.md(read)
- [02-commands-docs.md](02-commands-docs.md) #F:commands/release-train.md
- [02-commands-docs.md](02-commands-docs.md) #F:commands/audit.md(pdh-twice)

Sources: `02-commands-docs.md#F:commands/adjust-agent.md(5)`, `02-commands-docs.md#F:commands/craft-loop.md`, `02-commands-docs.md#F:commands/debug.md`, `02-commands-docs.md#F:commands/mode.md(read)`, `02-commands-docs.md#F:commands/release-train.md`, `02-commands-docs.md#F:commands/audit.md(pdh-twice)`

### W3-10 · [instructions] Strip changelog/ticket-history prose from instruction files
**Priority** Low · **Effort** S · **Labels** Tech Debt · **Ticket group** —

**Problem**
Instruction files carry history instead of current behavior: `commands/council.md:145-158` ("used to auto-grade… removed because…") and 51 ticket refs; `commands/retro.md` 25 refs; `commands/spec.md:22-26,721-722,740-741,758,767-777` ("transplanted from commands/check-specs.md", "Maps from /generate-specs", "Notes for consumers (Tasks 9/11/13)… until Task 12 stubs them" — none exist); `commands/memory.md:34-39` "former /memory-config" provenance column and settable-but-unused `distill_mode`; `commands/bug-hunt.md:50` "Shipped (CDT-…)".

**Fix**
- Remove history paragraphs and ticket-id parentheticals with no instruction value; keep ids only where a spec MUST is cited.
- Move any useful history to CHANGELOG or specs.

**Acceptance**
- Ticket-id count in the four large commands drops by ≥ 70%.
- No references to removed legacy commands in spec.md.
- docs-drift passes.

**Source**
- [03-large-commands.md](03-large-commands.md) #E7
- [03-large-commands.md](03-large-commands.md) #S1
- [03-large-commands.md](03-large-commands.md) #M18
- [03-large-commands.md](03-large-commands.md) #cross-5
- [02-commands-docs.md](02-commands-docs.md) #F:commands/bug-hunt.md
- [README.md](README.md) #wave3-strip-prose

Sources: `03-large-commands.md#E7`, `03-large-commands.md#S1`, `03-large-commands.md#M18`, `03-large-commands.md#cross-5`, `02-commands-docs.md#F:commands/bug-hunt.md`, `README.md#wave3-strip-prose`

### W3-13 · [council] Make flavors consistent: severity vs confidence, output contract, repo rules
**Priority** Low · **Effort** S · **Labels** Tech Debt · **Ticket group** —

**Problem**
Diff-mode flavors derive severity from confidence (80–94 warning, 95+ critical), making `nitpick` unreachable while simplification says "most land as nitpick". Their output contract (top-level JSON array) conflicts with investigator.md and EvidenceSchema (`{bundles}`). compliance.md hard-codes repo-specific rules ("no file > 1k lines", PR caps) in a plugin that runs on user projects while saying "MUST NOT flag a rule you invented". `loadFlavor` strips only frontmatter, so authoring prose is injected. paranoid-ic references `reason_if_empty` (not in schema) and a stale "domain specialist in diff-mode"; diff-mode.md has `role: preset` (not a schema role). SKILL.md: `:267-269` says diff-mode uses prosecution/defense though Phase 4 is skipped; Phase 0 claims spec grep and mutual-exclusion checks the engine doesn't do; flavors are "under 60 lines" but diff flavors run 90–120.

**Fix**
- Define severity by impact, confidence by certainty; unify output contract with the schema; drop repo-specific compliance rules unless AGENTS.md states them.
- Strip non-prompt sections in `loadFlavor` (marker-based); fix schema-role and field references; correct SKILL.md claims.

**Acceptance**
- check-template-vars and council tests pass.
- A nitpick is reachable in a fixture.
- Flavor injection excludes authoring notes (test).

**Source**
- [04-council.md](04-council.md) #17
- [04-council.md](04-council.md) #F:flavors/logic,security,compliance,quality,simplification(1-4,6)
- [04-council.md](04-council.md) #F:flavors/paranoid-ic,yolo-ic,external,diff-mode.md(roles)
- [04-council.md](04-council.md) #F:council/SKILL.md(1,2,4)
- [04-council.md](04-council.md) #cross-5

Sources: `04-council.md#17`, `04-council.md#F:flavors/logic,security,compliance,quality,simplification(1-4,6)`, `04-council.md#F:flavors/paranoid-ic,yolo-ic,external,diff-mode.md(roles)`, `04-council.md#F:council/SKILL.md(1,2,4)`, `04-council.md#cross-5`

### W3-14 · [council] check-template-vars: digit class, max status, cover workflow.js and fix-ticket
**Priority** Low · **Effort** S · **Labels** Tech Debt · **Ticket group** —

**Problem**
`skills/council/check-template-vars.sh` matches `[A-Z_]+` (`:72-73,97,109`), omitting digits — the same bug engine.sh:1192 fixed — so a `{{PHASE3_X}}` variable escapes the gate. `status=2` can be downgraded to 1 by a later drift. It doesn't cover `workflow.js` `loadPrompt` variable maps or the fix-ticket prompts/template.

**Fix**
- Use `[A-Z0-9_]+`; keep `max(status)`.
- Parse workflow.js `loadPrompt` maps and fix-ticket prompts/template into the comparison.

**Acceptance**
- Fixture with `{{PHASE3_X}}` drift is caught.
- Status 2 persists after a later status-1 finding.
- Runs in CI via run-all-tests.

**Source**
- [04-council.md](04-council.md) #18
- [04-council.md](04-council.md) #F:council/check-template-vars.sh

Sources: `04-council.md#18`, `04-council.md#F:council/check-template-vars.sh`

### W3-15 · [fix-ticket] Validate TICKET, enforce worktree check, fail-closed reference workflow
**Priority** Low · **Effort** S · **Labels** Bug, Security · **Ticket group** —

**Problem**
`skills/fix-ticket/SKILL.md`: `TICKET` isn't validated before building `${DATE}-${TICKET}.md` (`:267`) or calling `worktree-lib ensure`; the comment at `:118-119` promises a "must be a git worktree" check but the code only does `[ -d ]`; Step 7 uses `$TICKET` without re-resolving (SPEC-021 C1); a same-day re-run overwrites the report. The non-invoked `workflow.js` hardcodes `verification_mode:'full'` (`:214`) while `.filter(Boolean)` (`:202`) drops failed refuters, so `all_hold` can be true on a partial fleet (fails open, M23; P1 if ever wired); `premise.holds` on null throws (`:149`); `t.agent` unvalidated; prompts forked inline. `templates/report.md`: unquoted YAML `ticket:`/`worktree:`, live placeholders inside an HTML comment, PREMISE_*/IMPL_SECTION undocumented.

**Fix**
- Validate `TICKET` `^[A-Za-z0-9._-]+$`; implement the worktree check; re-resolve in Step 7; suffix same-day reports.
- workflow.js: degrade to self-verified on a null refuter, null-guard premise, validate agent ∈ {ic4, ic5}, load prompts from files.
- Quote YAML; document variables.

**Acceptance**
- Ticket `../x` rejected (test).
- node test: failed refuter → not all_hold.
- check-template-vars covers the template.

**Source**
- [04-council.md](04-council.md) #19
- [04-council.md](04-council.md) #F:fix-ticket/SKILL.md(2-5)
- [04-council.md](04-council.md) #F:fix-ticket/workflow.js
- [04-council.md](04-council.md) #F:fix-ticket/templates/report.md

Sources: `04-council.md#19`, `04-council.md#F:fix-ticket/SKILL.md(2-5)`, `04-council.md#F:fix-ticket/workflow.js`, `04-council.md#F:fix-ticket/templates/report.md`

### W3-16 · [council] tier-grade.sh robustness: ERR trap, test glob, fan-in heuristic
**Priority** Low · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
`skills/council/tier-grade.sh`: the ERR trap (`:101`) has no `set -E`, so failures inside functions or `$(…)` exit non-zero without JSON (callers fail closed, but the header promises "always exit 0"); `sed | grep -q` under pipefail (`:308`) can race to a false negative via SIGPIPE; signal 5's `*test*` glob (`:346`) is case-sensitive — misses `FooTest.java`, matches `latest.go`/`contest` — and `*_test.*|test_*` are redundant; fan-in by basename substring (`:370`) over-fires for `index.js`/`SKILL.md` (conservative direction).

**Fix**
- `set -E` (or explicit JSON on every exit path); use `grep -q` on a variable instead of a pipe.
- Case-insensitive, path-segment test matching (`(^|/)(tests?|__tests__)/|[._-]test\.|Test\.`); fan-in on full relative path.

**Acceptance**
- test-tier-grade cases for FooTest.java, latest.go, a failing subshell (JSON still emitted).
- No SIGPIPE false negative in a stress loop.
- Existing tests pass.

**Source**
- [04-council.md](04-council.md) #F:council/tier-grade.sh(2,3,4,6)

Sources: `04-council.md#F:council/tier-grade.sh(2,3,4,6)`

### W3-21 · [tools] Make the permission probe's worktree check real; re-probe current CC
**Priority** Low · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
`tools/permission-matrix-probe.sh:273-284` passes the worktree flow whenever the stream mentions "worktree"/"ensure", which the prompt's own tool_use always does — measuring an attempt, not success (weakens CDT-75 evidence). It uses `rg` unguarded (`:273-433`), `timeout`, and a hardcoded `/opt/claude-code/bin/claude` (`:354,359`); `:299` is dead; the hooks column records `$fires`, not the stream count (`:321`); `:242` prompt is garbled; it rewrites tracked `tools/permission-matrix-cc-version` by default (undocumented). That file says 2.1.190 while CHANGELOG v1.18.14 cites 2.1.236, so `/doctor` WARNs until re-probed.

**Fix**
- Assert on worktree-lib's printed `.worktrees/cdt-51-probe-wt` in the tool_result and its absence afterwards; guard `rg`/`timeout`; resolve `command -v claude`; remove dead code; fix hooks column and prompt; document the version-file rewrite.
- Re-run on current CC and commit the version.

**Acceptance**
- Probe run on a CC where worktree creation fails reports failure.
- Version file matches current CC.
- `/doctor` no longer WARNs.

**Source**
- [01-agents-infra.md](01-agents-infra.md) #15
- [01-agents-infra.md](01-agents-infra.md) #17
- [01-agents-infra.md](01-agents-infra.md) #F:tools/permission-matrix-probe.sh
- [01-agents-infra.md](01-agents-infra.md) #F:tools/permission-matrix-cc-version
- [README.md](README.md) #wave3-probe

Sources: `01-agents-infra.md#15`, `01-agents-infra.md#17`, `01-agents-infra.md#F:tools/permission-matrix-probe.sh`, `01-agents-infra.md#F:tools/permission-matrix-cc-version`, `README.md#wave3-probe`

### W3-22 · [docs] Refresh SECURITY.md, scout-plugins README, smoke test comment, .gitignore dupe
**Priority** Low · **Effort** S · **Labels** Tech Debt · **Ticket group** —

**Problem**
`SECURITY.md:7-9` lists `1.1.x` as supported while the version is 1.18.14. `tools/scout-plugins/README.md:11-14,190` documents a `/scout-plugins` command that no longer exists; Step 6 (`:178-181`) computes `WTROOT` but never writes. `tools/smoke/test.sh:68-71` comment is stale (the fixture line is at column 0; real reason "unparseable frontmatter line 3") and contains process chatter. `.gitignore` has `.worktrees` (`:1`) and `.worktrees/` duplicated. `CONTEXT.md:36` lowercase "inherited effort"; no glossary terms for finder/debugger roles or "non-behavioral roster agent" (SPEC-003:13). githooks/pre-commit fires only after `install-git-hooks.sh` (undocumented; see AGENTS.md item).

**Fix**
- Supported: 1.18.x yes, older no; rewrite scout-plugins as "paste this README as a prompt" with a real save step; fix the test comment; dedupe .gitignore; add glossary terms.

**Acceptance**
- SECURITY.md lists current minor.
- No reference to `/scout-plugins` command.
- smoke test passes.

**Source**
- [01-agents-infra.md](01-agents-infra.md) #16
- [01-agents-infra.md](01-agents-infra.md) #F:SECURITY.md
- [01-agents-infra.md](01-agents-infra.md) #F:tools/scout-plugins/README.md
- [01-agents-infra.md](01-agents-infra.md) #F:tools/smoke/test.sh(comment)
- [01-agents-infra.md](01-agents-infra.md) #F:.gitignore
- [01-agents-infra.md](01-agents-infra.md) #F:CONTEXT.md
- [01-agents-infra.md](01-agents-infra.md) #F:githooks/pre-commit
- [README.md](README.md) #wave3-security-md

Sources: `01-agents-infra.md#16`, `01-agents-infra.md#F:SECURITY.md`, `01-agents-infra.md#F:tools/scout-plugins/README.md`, `01-agents-infra.md#F:tools/smoke/test.sh(comment)`, `01-agents-infra.md#F:.gitignore`, `01-agents-infra.md#F:CONTEXT.md`, `01-agents-infra.md#F:githooks/pre-commit`, `README.md#wave3-security-md`

### W3-23 · [memory] Memory doc cleanups: heredoc claim, command names, UPDATE protocol, compress
**Priority** Low · **Effort** S · **Labels** Tech Debt · **Ticket group** —

**Problem**
`skills/memory-store/SKILL.md:236-237` claims heredocs sidestep SQL escaping (a `'` inside the literal, as in the `:70-76` example, still breaks); `:147` uses cwd-relative `bash skills/memory-store/embed-one.sh` (absent on installs — design notes admit it); the fallback heredoc breaks on a content line `EOF` and has no line-cap enforcement. `skills/memory-compress/SKILL.md` says "Companion to /memory-distill" (command is `/memory distill`), points to a nonexistent "memory-store UPDATE protocol", rewrites tier-0 rows in place against SPEC-004 append-only, and its protocol snippet (`:45-53`) does nothing. SPEC-024:89-91 validation boxes unchecked though tests exist; TDD row calls memory-recall "(stub)" though SPEC-006:7 says live.

**Fix**
- Correct the heredoc claim (use parameterized helper); resolve embed-one via plugin-dir; unique heredoc terminator + cap.
- Fix memory-compress names, remove the in-place rewrite or specify an append-only supersede; tick SPEC-024 boxes; fix TDD row.

**Acceptance**
- grep: no `/memory-distill` or UPDATE-protocol references.
- Skill-lint cwd-path rule passes for memory-store.
- check-index passes for SPEC-024.

**Source**
- [07-memory.md](07-memory.md) #20
- [07-memory.md](07-memory.md) #F:memory-store/SKILL.md(docs)
- [07-memory.md](07-memory.md) #F:memory-compress/SKILL.md
- [07-memory.md](07-memory.md) #F:model-map/SKILL.md(gitignored-claim)
- [10-specs.md](10-specs.md) #SPEC-024-boxes
- [10-specs.md](10-specs.md) #SPEC-006-tdd-row

Sources: `07-memory.md#20`, `07-memory.md#F:memory-store/SKILL.md(docs)`, `07-memory.md#F:memory-compress/SKILL.md`, `07-memory.md#F:model-map/SKILL.md(gitignored-claim)`, `10-specs.md#SPEC-024-boxes`, `10-specs.md#SPEC-006-tdd-row`

### W3-24 · [metrics] Validate numeric/string inputs in emit-outcome, rollup and resolve-model
**Priority** Low · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
`skills/metrics/emit-outcome.sh:137` `json_num_or_null` passes any JSON to `--argjson`, so objects/strings land in numeric fields; bad input reports "cannot write" (misleading). `rollup.sh:203` — one malformed task JSON makes `jq -s` zero all task counts (comment says malformed count as "other"); a non-string `.agent` zeroes the outcomes section. `outcome-rates.sh` `printf '%.1f'` is locale-dependent. `model-map/resolve-model.sh` doesn't validate the model string — an embedded newline makes output multi-line.

**Fix**
- Check `^[0-9]+$|null` and exit 64 with a clear message; per-file parse in rollup counting malformed as "other"; `LC_NUMERIC=C`; reject model strings with whitespace/control chars.

**Acceptance**
- metrics/test.sh cases for each bad input.
- model-map test for newline rejection.
- Rollup with one bad file still counts the rest.

**Source**
- [07-memory.md](07-memory.md) #21
- [07-memory.md](07-memory.md) #F:metrics/emit-outcome.sh
- [07-memory.md](07-memory.md) #F:metrics/rollup.sh
- [07-memory.md](07-memory.md) #F:metrics/outcome-rates.sh
- [07-memory.md](07-memory.md) #F:model-map/resolve-model.sh

Sources: `07-memory.md#21`, `07-memory.md#F:metrics/emit-outcome.sh`, `07-memory.md#F:metrics/rollup.sh`, `07-memory.md#F:metrics/outcome-rates.sh`, `07-memory.md#F:model-map/resolve-model.sh`

### W3-25 · [tooling] sync-includes.py: path containment, missing partial, unclosed region
**Priority** Low · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
`skills/agent-memory/sync-includes.py` joins the partial path from a marker without containment (`../`, absolute paths accepted); a missing partial produces a traceback; a region missing its `<!-- /include -->` makes the non-greedy regex swallow up to the next close marker, and `apply` then corrupts the file.

**Fix**
- Resolve partial paths under the repo root and reject escapes; friendly error for missing partials; validate open/close pairing before any rewrite (abort on mismatch).

**Acceptance**
- sync-includes-test gains cases: `../` path rejected, missing partial error, unclosed region aborts without writing.
- check on repo still clean.
- 58 existing tests pass.

**Source**
- [07-memory.md](07-memory.md) #F:agent-memory/sync-includes.py

Sources: `07-memory.md#F:agent-memory/sync-includes.py`

### W3-26 · [memory] domain-glossary: load WTROOT/CONTEXT.md before MROOT
**Priority** Low · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
`skills/domain-glossary/SKILL.md:73-83` loads only `$MROOT/CONTEXT.md` (main checkout), while updates go to the worktree branch, so a session inside a worktree loads a stale glossary.

**Fix**
- Load `$WTROOT/CONTEXT.md` first, falling back to `$MROOT/CONTEXT.md` when the worktree copy is absent; apply the same order to the glossary update check so reads and writes target one file.

**Acceptance**
- Static test asserts WTROOT-first order.
- Worktree session with an edited glossary sees the edit (scripted fence test).
- Orchestrate 3b/6b references still valid.

**Source**
- [07-memory.md](07-memory.md) #19
- [07-memory.md](07-memory.md) #F:domain-glossary/SKILL.md

Sources: `07-memory.md#19`, `07-memory.md#F:domain-glossary/SKILL.md`

### W3-30 · [refactor] Create worktree only on the bounded route; tidy refactor SKILL
**Priority** Low · **Effort** S · **Labels** Improvement · **Ticket group** —

**Problem**
`skills/refactor/SKILL.md` 2.2a.4 creates the worktree before routing is known, so escalating routes create and immediately release it (possibly hitting the collision prompt). §2.2a.5 is ~90 lines of dense prose read on every run. Step 0 loads context before Step 1 parses args. It cites "SPEC-031 D1" while SPEC-015:44 says "SPEC-002 D1".

**Fix**
- Move the 2.2a.4 `ensure` after routing = bounded; keep the "no edit before outcome block" rule.
- Condense §2.2a.5; parse args before loading context; fix the citation.

**Acceptance**
- Static test: ensure appears after the routing decision.
- SPEC-015 and skill cite the same decision id.
- Refactor escalation path creates no worktree.

**Source**
- [08-workflow-skills.md](08-workflow-skills.md) #24
- [08-workflow-skills.md](08-workflow-skills.md) #F:refactor/SKILL.md(misc)

Sources: `08-workflow-skills.md#24`, `08-workflow-skills.md#F:refactor/SKILL.md(misc)`

### W3-31 · [standup] Read the task's worktree context; guard jq; fix staleness author check
**Priority** Low · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
`skills/standup/SKILL.md` uses `jq` without a `command -v jq` guard (`:55`); `:90` `cat $WTROOT/...` is unquoted and reads the caller's worktree, not the agent's `.worktrees/<slug>`; staleness uses `--author=<agent-name>` though commits are authored by the user, so most tasks get flagged; LIKELY-DONE (`:118-122`) contradicts "prefer file store" (`:68-71`).

**Fix**
- Read `context.md` under the task JSON's worktree path; guard jq; quote paths.
- Base staleness on branch commit recency, not author; align LIKELY-DONE with the file store.

**Acceptance**
- Static test for jq guard and quoted paths.
- Scripted run with two worktrees reads the right context.
- Staleness not triggered for user-authored commits.

**Source**
- [08-workflow-skills.md](08-workflow-skills.md) #25
- [08-workflow-skills.md](08-workflow-skills.md) #F:standup/SKILL.md

Sources: `08-workflow-skills.md#25`, `08-workflow-skills.md#F:standup/SKILL.md`

### W3-32 · [scaffold-project] Stop creating a non-roster `claude` memory dir; SPEC-008 TDD skeleton
**Priority** Low · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
`skills/scaffold-project/SKILL.md` creates `.claude/memory/claude/` (`:81,168`), which is not a roster agent. The scaffolded `TDD.md` specs (`:290+`) are GUI-centric and don't follow SPEC-008's 9-section format.

**Fix**
- Create memory dirs only for roster agents.
- Scaffold specs from `skills/spec-tooling/spec-skeleton.md` (include region) so they pass check-format.

**Acceptance**
- Scaffolded project passes `check-format.sh` on generated specs.
- No `.claude/memory/claude/` created.
- sync-includes check clean.

**Source**
- [08-workflow-skills.md](08-workflow-skills.md) #F:scaffold-project/SKILL.md(roster,tdd)

Sources: `08-workflow-skills.md#F:scaffold-project/SKILL.md(roster,tdd)`

### W3-33 · [spec-tooling] Refresh stale consumer lists, examples and fixture text
**Priority** Low · **Effort** S · **Labels** Tech Debt · **Ticket group** —

**Problem**
`skills/spec-tooling/spec-skeleton.md` and `source-exclude.md` header comments name removed consumers (`commands/create-spec.md`, `skills/generate-specs/`, `commands/check-specs.md`, `commands/update-spec.md`, `skills/reflect-specs/`, "until Task-7 stub"); real consumers are `commands/spec.md` (×4) and `spec-tooling/SKILL.md` (×3). `spec-tooling/SKILL.md:826` example "SPEC-001 (create-spec.md)" and `:89` "check-specs" point to removed files; `:25` advertises `fixtures/` which say "generated by /generate-specs".

**Fix**
- Update consumer lists; fix `:89`/`:826`; fixtures "/generate-specs" → "/spec generate".

**Acceptance**
- broadened docs-drift skill-ref passes.
- grep for removed command names in spec-tooling returns nothing.
- sync-includes check clean.

**Source**
- [08-workflow-skills.md](08-workflow-skills.md) #17
- [08-workflow-skills.md](08-workflow-skills.md) #F:spec-tooling/SKILL.md
- [08-workflow-skills.md](08-workflow-skills.md) #F:spec-tooling/spec-skeleton.md,source-exclude.md
- [09-release-tooling.md](09-release-tooling.md) #F:docs-drift(skill-ref-partials)

Sources: `08-workflow-skills.md#17`, `08-workflow-skills.md#F:spec-tooling/SKILL.md`, `08-workflow-skills.md#F:spec-tooling/spec-skeleton.md,source-exclude.md`, `09-release-tooling.md#F:docs-drift(skill-ref-partials)`

### W3-34 · [transcript] Linear `bound_tail`; prune dead code and soft-detect probes
**Priority** Low · **Effort** S · **Labels** Tech Debt · **Ticket group** —

**Problem**
`transcript-mirror/compact-transcript.py:153` `bound_tail` re-joins and re-encodes `blocks[i:]` each iteration — O(n²), 1.57 s on a 6 MB main.md. `handoff/prepass.sh:709-727` `--help | grep` soft-detection of `--events-out/--prior-events/--light` is dead (assemble ships them) and costs 3 python starts. `transcript-parse/parselib.py` `iter_lines`, `sidechain_is_signal`, `is_tool_result` have no production consumer yet are documented as public in SKILL.md. `handoff/SKILL.md:119` calls `load_merged_for_summary(dir, prior=…)` but the kwarg is `prior_path=` (`assemble.py:456`; `:610` is correct); the file is 984 lines.

**Fix**
- Precompute per-block byte lengths and accumulate from the end.
- Remove soft-detect; mark or remove unused parselib API and SKILL docs; fix the kwarg.

**Acceptance**
- Benchmark: 6 MB file bound in < 0.2 s.
- handoff and transcript suites pass.
- SKILL.md examples execute.

**Source**
- [06-handoff-transcript.md](06-handoff-transcript.md) #15
- [06-handoff-transcript.md](06-handoff-transcript.md) #17
- [06-handoff-transcript.md](06-handoff-transcript.md) #B9
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:handoff/prepass.sh(d)
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:transcript-parse/parselib.py
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:handoff/SKILL.md
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:transcript-parse/SKILL.md

Sources: `06-handoff-transcript.md#15`, `06-handoff-transcript.md#17`, `06-handoff-transcript.md#B9`, `06-handoff-transcript.md#F:handoff/prepass.sh(d)`, `06-handoff-transcript.md#F:transcript-parse/parselib.py`, `06-handoff-transcript.md#F:handoff/SKILL.md`, `06-handoff-transcript.md#F:transcript-parse/SKILL.md`

### W3-35 · [handoff] Validate numeric/env inputs; atomic packet write; safe webhook JSON
**Priority** Low · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
`handoff/assemble.py` `validate_event`: `int(float('inf'))` raises OverflowError (only TypeError/ValueError caught) — verified crash; NaN is accepted and corrupts the sort; `load_events` (`:274`) doesn't catch OSError; the packet write (`:1230`) isn't atomic. `prepass.sh`: `int(HANDOFF_SPINE_TOKENS)` tracebacks on bad input; default `--out plan.json` writes into the caller's cwd; `_mirror_check_ok` subprocess has no timeout. `retro-gate/gate.sh:73` non-numeric `RETRO_THRESHOLD` → traceback and invalid JSON in early exits (`:28-47`). `write-scheduled-report.sh` (~`:190`) interpolates `$REPORT` unescaped into webhook JSON and doesn't validate counts (`--applied-count x` → invalid JSON); retention uses `ls -t` (also hint.sh).

**Fix**
- Reject non-finite `order`; catch OSError; temp+rename packet write.
- Validate env numerics with defaults; default `--out` under the handoff dir; subprocess timeout.
- Build webhook JSON with `python -c 'json.dumps'` via argv; validate counts; mtime sort via stat.

**Acceptance**
- Tests: Infinity/NaN order rejected; bad RETRO_THRESHOLD yields valid JSON error.
- Webhook body valid with quotes in report.
- Packet write atomic.

**Source**
- [06-handoff-transcript.md](06-handoff-transcript.md) #16
- [06-handoff-transcript.md](06-handoff-transcript.md) #B6
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:handoff/assemble.py
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:handoff/prepass.sh(f,g,h)
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:retro-gate/gate.sh(threshold)
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:retro-gate/write-scheduled-report.sh
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:retro-gate/hint.sh

Sources: `06-handoff-transcript.md#16`, `06-handoff-transcript.md#B6`, `06-handoff-transcript.md#F:handoff/assemble.py`, `06-handoff-transcript.md#F:handoff/prepass.sh(f,g,h)`, `06-handoff-transcript.md#F:retro-gate/gate.sh(threshold)`, `06-handoff-transcript.md#F:retro-gate/write-scheduled-report.sh`, `06-handoff-transcript.md#F:retro-gate/hint.sh`

### W3-36 · [autopilot] Cap card rationale; batch loc-exclude via check-attr --stdin
**Priority** Low · **Effort** S · **Labels** Concurrency, Improvement · **Ticket group** —

**Problem**
`skills/autopilot/append-card.sh:283-285` relies on PIPE_BUF atomicity, which applies to pipes, not regular files, and rationale has no length cap; jq may flush a large card in several `write()`s, so concurrent appends can interleave. `loc-exclude.sh` spawns one process per path and checks attributes from the cwd, not the worktree's `.gitattributes`.

**Fix**
- Reject rationale > 2000 bytes (or truncate with a marker) and fix the comment; or append under `lock_run`.
- Batch `git -C "$WT" check-attr --stdin`.

**Acceptance**
- autopilot test: 3 KB rationale rejected/truncated.
- Concurrent appends produce valid JSONL (stress test).
- loc-exclude honors worktree .gitattributes.

**Source**
- [05-orchestration.md](05-orchestration.md) #16
- [05-orchestration.md](05-orchestration.md) #F:autopilot/append-card.sh
- [05-orchestration.md](05-orchestration.md) #F:autopilot/loc-exclude.sh

Sources: `05-orchestration.md#16`, `05-orchestration.md#F:autopilot/append-card.sh`, `05-orchestration.md#F:autopilot/loc-exclude.sh`

### W3-37 · [epic] epic-lib hardening: test-hook eval, env bypass, parent lookup, mark-done, waves
**Priority** Low · **Effort** S · **Labels** Security, Tech Debt · **Ticket group** —

**Problem**
`skills/epic/epic-lib.sh` runs `eval "$EPIC_SEAL_RELEASE_HOOK"` (a test hook) in production; an `EPIC_ALLOW_SEAL_RELEASE=1` leaked into the env bypasses every C4 guard. `_find_parent_epic_for_ticket` takes the first alphabetical match, including sealed/old epics; `mark-done` marks the child completed in every epic containing it. `cmd_waves` spawns one jq per dep edge (O(N·D)); the ready-set jq expression is copied 3× (`:1287,1362`, `_seed_render`). Epic SKILL Step 0.4 maps every resolve failure to exit 64. epic/test.sh has thin `waves` (4) and `check-cycle` (5) coverage.

**Fix**
- Gate the hook behind `EPIC_TEST_MODE=1`; honor `EPIC_ALLOW_SEAL_RELEASE` only when state is seal-staged.
- Prefer active (unsealed, newest) parent; mark-done only in the resolved epic.
- One jq def file / `_ready_ids`; waves in one Kahn pass; distinct exit codes in 0.4; more waves/cycle tests.

**Acceptance**
- Tests: env bypass ignored outside seal-staged; mark-done scoped.
- waves output unchanged on fixtures, fewer processes.
- 745 existing assertions pass.

**Source**
- [05-orchestration.md](05-orchestration.md) #17
- [05-orchestration.md](05-orchestration.md) #18
- [05-orchestration.md](05-orchestration.md) #F:epic/epic-lib.sh(misc)
- [05-orchestration.md](05-orchestration.md) #F:epic/SKILL.md(0.4)
- [05-orchestration.md](05-orchestration.md) #F:epic/test.sh

Sources: `05-orchestration.md#17`, `05-orchestration.md#18`, `05-orchestration.md#F:epic/epic-lib.sh(misc)`, `05-orchestration.md#F:epic/SKILL.md(0.4)`, `05-orchestration.md#F:epic/test.sh`

### W3-38 · [kickoff] Cleanup: Task Map printf, requires_council in template, flag handling
**Priority** Low · **Effort** S · **Labels** Bug · **Ticket group** —

**Problem**
`skills/kickoff/SKILL.md`: `echo "\n## Task Map\n" >> $WT_PATH/...` writes a literal `\n` and leaves `$WT_PATH` unquoted; the TaskCreate template lacks a `requires_council` line though `task-store create` needs one; the exit-64 comment (`:89`) omits `--tier`/`--max-loc`; `/kickoff` accepts and silently ignores `--tier`/`--council-tier`.

**Fix**
- `printf '\n## Task Map\n\n' >> "$WT_PATH/…"`; add `requires_council:` to the template; fix the comment; reject or honor `--tier`/`--council-tier` explicitly.

**Acceptance**
- Static test for printf and quoting.
- Template includes requires_council.
- `/kickoff --tier` behavior documented and tested.

**Source**
- [05-orchestration.md](05-orchestration.md) #19
- [05-orchestration.md](05-orchestration.md) #F:kickoff/SKILL.md(misc)

Sources: `05-orchestration.md#19`, `05-orchestration.md#F:kickoff/SKILL.md(misc)`

### W3-39 · [doctor] Split doctor.sh into checks/<group>.sh; single stale-lock TTL logic
**Priority** Low · **Effort** L · **Labels** Tech Debt · **Ticket group** —

**Problem**
`skills/doctor/doctor.sh` is 1877 lines with 52 functions and a registry built from parallel arrays. The stale-lock TTL logic exists three times: worktree-lib, the fallback at `:1295-1310`, and `do_fix` `:1690-1712`.

**Fix**
- `skills/doctor/checks/<group>.sh` sourced by a thin runner.
- Call `worktree-lib status` for stale locks everywhere; add `worktree-lib gc --stale` for `--fix`.

**Acceptance**
- doctor/test.sh (102) passes unchanged.
- Only one TTL implementation (grep).
- Runner < 300 lines.

**Source**
- [09-release-tooling.md](09-release-tooling.md) #17
- [09-release-tooling.md](09-release-tooling.md) #F:doctor/doctor.sh(1)
- [README.md](README.md) #wave3-doctor-split

Sources: `09-release-tooling.md#17`, `09-release-tooling.md#F:doctor/doctor.sh(1)`, `README.md#wave3-doctor-split`

### W3-40 · [worktree] Move `.wt-lock` out of the worktree; base `ensure -b` on default branch
**Priority** Low · **Effort** M · **Labels** Bug · **Ticket group** —

**Problem**
`skills/worktree-lib.sh`: the `.wt-lock` file lives inside the worktree; in consumer repos without it in `.gitignore`, `git add -A` commits it. `ensure -b` branches from whatever HEAD the main checkout has, not the default branch. `slug_has_live_task` `grep -wF` matches CDT-1 inside CDT-1-2 contrary to its comment. `git_retry` produces a malformed sleep for values ≥ 1000 ms.

**Fix**
- Store the lock at `$(git -C wt rev-parse --git-dir)/wt-lock` (or add to `info/exclude` on ensure).
- Branch `ensure -b` from `origin/HEAD` or the default branch; exact slug match; fix sleep formatting.

**Acceptance**
- worktree-lib-test: `git add -A` in a worktree doesn't stage a lock.
- New branch based on default branch while main is on another branch.
- CDT-1 vs CDT-1-2 distinguished.

**Source**
- [09-release-tooling.md](09-release-tooling.md) #18
- [09-release-tooling.md](09-release-tooling.md) #F:worktree-lib.sh(4-7)

Sources: `09-release-tooling.md#18`, `09-release-tooling.md#F:worktree-lib.sh(4-7)`

### W3-41 · [release] check-ship-history: remove dead paths, O(T) prev lookup
**Priority** Low · **Effort** S · **Labels** Tech Debt · **Ticket group** —

**Problem**
`skills/release/check-ship-history.sh:373` `release_subj_seen` is dead. The D4 reflog half (`:421-435`) is effectively dead: tags get no reflog unless `core.logAllRefUpdates=always`. `prev_for_tag` rescans every tag for each tag in W (O(T²) git calls). `refname:short` becomes ambiguous if a branch shares a tag's name.

**Fix**
- Remove `release_subj_seen`; document D4 reflog requirement or drop it.
- Compute prev with `git describe --tags --abbrev=0 --match 'v[0-9]*' <tag>^`; use full refnames.

**Acceptance**
- test-ship-history (33) passes.
- Branch named like a tag doesn't confuse the check (test).
- Runtime linear on a 200-tag fixture.

**Source**
- [09-release-tooling.md](09-release-tooling.md) #19
- [09-release-tooling.md](09-release-tooling.md) #F:release/check-ship-history.sh(2-5)

Sources: `09-release-tooling.md#19`, `09-release-tooling.md#F:release/check-ship-history.sh(2-5)`

### W3-42 · [specs] Normalize spec headers, slim the TDD index, fix per-spec text drift
**Priority** Low · **Effort** S · **Labels** Tech Debt · **Ticket group** —

**Problem**
Covers lines sit at varying positions (SPEC-022:132, SPEC-023:117, SPEC-036:710); SPEC-027 uses `**Covers:**`; SPEC-015/018/029 have none. TDD index rows became changelogs (SPEC-018 row ~1.5 KB) and history lacks CDT-230…245. Text drift: SPEC-002:268 cites nonexistent `freshness-gate.sh`; SPEC-003 TDD row omits finder/debugger/council-judge; SPEC-011:29 "MUST use Opus for the reviewer" is unimplemented (pin or amend); SPEC-013:6 covers `commands/council --blind.md`; SPEC-018 lacks Cross-references; SPEC-021 Covers uses bare names (`lint.py`); SPEC-024:118 covers `commands/setup team.md`; SPEC-026:143 "planned/landing with CDV-185" and unused `local` enum; SPEC-033 Covers omits end-state.md, resume-state.sh, ship-gate-council.md, test.sh; SPEC-035 history sits mid-file (`:85`); SPEC-008:22 category dirs don't exist (optional — say so).

**Fix**
- Require `**Covers**:` after `**Created**`, one repo-relative path per item; add missing Covers.
- Keep TDD Coverage to 1–3 paths; generate TDD history from spec histories.
- Fix each drift item; decide SPEC-011 reviewer model (pin via model-map or amend spec).

**Acceptance**
- check-index validates header position/format.
- TDD.md < 50% of current size.
- Every Covers path exists.

**Source**
- [10-specs.md](10-specs.md) #7
- [10-specs.md](10-specs.md) #8
- [10-specs.md](10-specs.md) #headline-1-history
- [10-specs.md](10-specs.md) #SPEC-002
- [10-specs.md](10-specs.md) #SPEC-003-tdd
- [10-specs.md](10-specs.md) #SPEC-011
- [10-specs.md](10-specs.md) #SPEC-013
- [10-specs.md](10-specs.md) #SPEC-018
- [10-specs.md](10-specs.md) #SPEC-021
- [10-specs.md](10-specs.md) #SPEC-022
- [10-specs.md](10-specs.md) #SPEC-024
- [10-specs.md](10-specs.md) #SPEC-026
- [10-specs.md](10-specs.md) #SPEC-033
- [10-specs.md](10-specs.md) #SPEC-035
- [10-specs.md](10-specs.md) #SPEC-008-dirs

Sources: `10-specs.md#7`, `10-specs.md#8`, `10-specs.md#headline-1-history`, `10-specs.md#SPEC-002`, `10-specs.md#SPEC-003-tdd`, `10-specs.md#SPEC-011`, `10-specs.md#SPEC-013`, `10-specs.md#SPEC-018`, `10-specs.md#SPEC-021`, `10-specs.md#SPEC-022`, `10-specs.md#SPEC-024`, `10-specs.md#SPEC-026`, `10-specs.md#SPEC-033`, `10-specs.md#SPEC-035`, `10-specs.md#SPEC-008-dirs`

### W3-43 · [docs] Use obviously fake spec IDs in docs examples
**Priority** Low · **Effort** S · **Labels** Tech Debt · **Ticket group** —

**Problem**
Docs examples reuse real spec IDs for made-up consumer specs: `docs/commands/kickoff.md:38` (SPEC-007-csv-export), `docs/runbooks/orchestrate.md:102` (SPEC-026), `docs/runbooks/idea-to-plan.md:94` (SPEC-031-realtime-collab), inviting confusion with real specs.

**Fix**
- Replace with `SPEC-9xx`-style IDs; add a docs-drift check that example spec IDs in docs don't collide with real spec filenames (or are ≥ 900).

**Acceptance**
- grep finds no real SPEC-0NN used as a made-up example.
- docs-drift rule bites on a fixture.
- Link checker passes.

**Source**
- [10-specs.md](10-specs.md) #9
- [10-specs.md](10-specs.md) #numbering-examples
- [02-commands-docs.md](02-commands-docs.md) #F:docs/commands/kickoff.md
- [02-commands-docs.md](02-commands-docs.md) #F:docs/runbooks/idea-to-plan.md

Sources: `10-specs.md#9`, `10-specs.md#numbering-examples`, `02-commands-docs.md#F:docs/commands/kickoff.md`, `02-commands-docs.md#F:docs/runbooks/idea-to-plan.md`
