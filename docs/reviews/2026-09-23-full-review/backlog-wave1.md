Backlog items for milestone **Wave 1 — Safety nets** of project P-CDT-30, generated from `docs/reviews/2026-09-23-full-review/backlog.json` (branch `claude/craft-loop-review-enhancement-4jq3wb`). These are written as a document because the workspace is at its free-plan issue limit; each item has everything needed to become an issue later.

29 items · High 23 · Medium 6

## Checklist

- [ ] `W1-32` [git] Add shared `skills/lib/git-safety.sh` (is-clean / is-merged / is-pushed) — High, S
- [ ] `W1-33` [ci] Run every test script in CI and /release; harden the workflow — High, M
- [ ] `W1-34` [tests] Make tests root/env-hermetic with a uniform skip protocol — High, S
- [ ] `W1-36` [lint] skill-lint C6–C9: pragma placement, brace defaults, cwd paths, destructive git — High, M
- [ ] `W1-37` [smoke] Extend smoke harness to agents/, githooks, root and tools scripts — High, S
- [ ] `W1-38` [specs] Spec lint: harden check-format, add check-index, gate CI and /release — High, S
- [ ] `W1-39` [specs] Enforce status lifecycle and fix drifted spec statuses — High, S
- [ ] `W1-40` [specs] Prune dead specs and retired-surface MUSTs; fold SPEC-028 into SPEC-014 — High, S
- [ ] `W1-42` [platform] Document platform floor; /doctor probes; shared portability helpers — High, M
- [ ] `W1-43` [platform] Replace bare `flock` with portable lock_run in all lock sites — High, M
- [ ] `W1-45` [platform] Replace GNU-only coreutils usages (timeout, sha256sum, sed, find, mktemp) — High, M
- [ ] `W1-46` [commands] One argument pass-through convention: heredoc `$ARGUMENTS`, ban `"$@"` — High, M
- [ ] `W1-47` [security] Untrusted-input-to-code convention: argv/env, `?` params, roster regex — High, S
- [ ] `W1-48` [memory] migrate-md: stop lossy migration and unsafe vector-table drop — High, M
- [ ] `W1-49` [memory] Reconcile: keyword fallback, O(n) Jaccard, k=5, transactional resolvers — High, M
- [ ] `W1-50` [backlog] reconcile.sh must preserve non-row index content — High, M
- [ ] `W1-51` [agents] Make distiller atomic: one transaction, argv inputs, no double-escaping — High, M
- [ ] `W1-52` [init-orchestration] TaskCompleted hook: filter candidates by status and ticket — High, M
- [ ] `W1-53` [autopilot] Close state-machine holes: Step 5 branch, bounded QA loop, ITER — High, M
- [ ] `W1-54` [transcript-mirror] Crash-safe rebuild, per-sid lock, bounded hook input — High, M
- [ ] `W1-55` [retro] Fix `--all` repeat filtering order and implement the TIGHTEN merge — High, M
- [ ] `W1-56` [council] Add engine.sh test coverage for untested paths — High, M
- [ ] `W1-59` [security-scan] Scan staged + untracked files from repo root; report truncation — High, M
- [ ] `W1-35` [tests] Stop tests mutating the live repo or leaking temp files — Medium, S
- [ ] `W1-41` [specs] Machine-checkable AC↔test traceability — Medium, M
- [ ] `W1-44` [platform] Remove bash-4-only constructs or fail loudly with a reason — Medium, M
- [ ] `W1-57` [install] Harden install-test.sh: set +e captures, cleanup, portability, coverage — Medium, S
- [ ] `W1-58` [autopilot] Shared flag-edge test matrix for autopilot and epic parsers — Medium, S
- [ ] `W1-60` [docs-drift] Broaden skill-ref to skills/agents/specs; add skill-name check — Medium, M

## Items

### W1-32 · [git] Add shared `skills/lib/git-safety.sh` (is-clean / is-merged / is-pushed)
**Priority** High · **Effort** S · **Labels** Improvement, Tech Debt · **Ticket group** T2 git-safety

**Problem**
Destructive git operations each carry their own guard or none: `epic-lib.sh` seal (`clean -fd`), `worktree-lib.sh release` (`branch -D`, `--force`), wrap-ticket legacy path (prefix match → `branch -D`), `prune-remote.sh` (wrong ref), `train-lib.sh restore` and `autopilot/end-state.md` (`reset --hard` without branch/clean checks). Only prune-remote has an ancestor/cherry check, and it checks the wrong ref. There is no shared primitive, so every new call site reinvents (or forgets) the check.

**Fix**
- Add `skills/lib/git-safety.sh` with `is-clean [--include-untracked]`, `is-merged <ref> <base>` (ancestor or patch-id/cherry clean), `is-pushed <ref>`.
- Adopt it in seal, worktree release, wrap-ticket, prune-remote, end-state and train restore (the per-site P0/P1 items can land first, then switch to the helper).

**Acceptance**
- `skills/lib/git-safety-test.sh` covers squash-merged, cherry-picked, unmerged, unpushed and untracked cases.
- All six call sites use the helper (grep).
- Skill-lint C9 (destructive git without guard) accepts helper-guarded sites.

**Source**
- [README.md](README.md) #wave1-git-safety
- [README.md](README.md) #4.3
- [09-release-tooling.md](09-release-tooling.md) #cross-1
- [05-orchestration.md](05-orchestration.md) #cross-5
- [README.md](README.md) #6-T2

Sources: `README.md#wave1-git-safety`, `README.md#4.3`, `09-release-tooling.md#cross-1`, `05-orchestration.md#cross-5`, `README.md#6-T2`

### W1-33 · [ci] Run every test script in CI and /release; harden the workflow
**Priority** High · **Effort** M · **Labels** Improvement, Tech Debt · **Ticket group** T8 ci-all-tests

**Problem**
`.github/workflows/smoke.yml` runs ~9 of 76 `*test*.sh`; `/release` adds only plugin-dir, bump-class and ship-history. Ungated: council ×4, orchestrate ×2, epic, autopilot, init-orchestration ×6 (~1,350 assertions), handoff ×19, transcript-mirror ×4, transcript-parse ×3, retro-gate ×7, model-map ×5, memory-store/test-migrate, validate-memory/test-reconcile, metrics, notify, doctor, audit, backlog ×2, ci-watch, release-train ×2, worktree-lib, release/test*.sh, and the linters' own bite tests (`skill-lint/test.sh`, `docs-drift/test.sh`, `tools/smoke/test.sh`, `install-test.sh`); `/release` Steps 4.6 (template vars) and 4.7 (hook templates) also aren't in CI. Five suites went red unnoticed. The workflow lacks `permissions:`, SHA-pinned actions, `concurrency`, triggers for `stable`/epic branches, a macOS job and shellcheck.

**Fix**
- Add `tools/run-all-tests.sh`: glob `**/*test*.sh`, explicit env-skip list, uniform exit 77 = skip, summary table.
- CI matrix job (ubuntu + macOS) calling it, plus Steps 4.6/4.7; `/release` calls it pre-tag.
- Add `permissions: contents: read`, SHA-pinned actions, `concurrency`, `stable`/`epic/**` triggers, shellcheck job.

**Acceptance**
- CI lists every test script as pass or explicit skip.
- A deliberately failing test fails the workflow.
- Workflow has permissions/concurrency blocks and pinned SHAs.

**Source**
- [README.md](README.md) #1-exec-1
- [README.md](README.md) #4.1
- [README.md](README.md) #wave1-ci
- [01-agents-infra.md](01-agents-infra.md) #5
- [01-agents-infra.md](01-agents-infra.md) #F:.github/workflows/smoke.yml
- [01-agents-infra.md](01-agents-infra.md) #F:tools/smoke/test.sh
- [04-council.md](04-council.md) #9
- [04-council.md](04-council.md) #test-side-effects
- [05-orchestration.md](05-orchestration.md) #2
- [05-orchestration.md](05-orchestration.md) #cross-1
- [06-handoff-transcript.md](06-handoff-transcript.md) #test-results
- [07-memory.md](07-memory.md) #10
- [07-memory.md](07-memory.md) #ci-gap
- [09-release-tooling.md](09-release-tooling.md) #8
- [09-release-tooling.md](09-release-tooling.md) #cross-3
- [10-specs.md](10-specs.md) #2
- [10-specs.md](10-specs.md) #headline-6
- [10-specs.md](10-specs.md) #AC-gates

Sources: `README.md#1-exec-1`, `README.md#4.1`, `README.md#wave1-ci`, `01-agents-infra.md#5`, `01-agents-infra.md#F:.github/workflows/smoke.yml`, `01-agents-infra.md#F:tools/smoke/test.sh`, `04-council.md#9`, `04-council.md#test-side-effects`, `05-orchestration.md#2`, `05-orchestration.md#cross-1`, `06-handoff-transcript.md#test-results`, `07-memory.md#10`, `07-memory.md#ci-gap`, `09-release-tooling.md#8`, `09-release-tooling.md#cross-3`, `10-specs.md#2`, `10-specs.md#headline-6`, `10-specs.md#AC-gates`

### W1-34 · [tests] Make tests root/env-hermetic with a uniform skip protocol
**Priority** High · **Effort** S · **Labels** Tech Debt · **Ticket group** T8 ci-all-tests

**Problem**
Environment-only failures: `metrics/test.sh` #4 (`:138-150`) and `transcript-mirror/test.sh` M4 (`:303`) rely on `chmod` that root ignores; `retro-gate/friction-capture-test.sh:15` needs `/setup`-generated hooks and fails instead of skipping; sqlite3-missing behavior differs — `test-migrate.sh:87` prints SKIP and exits 0 (looks green), `test-seed-pack.sh:222` crashes rc=127, `test-reconcile.sh` reports 18 failures. `council/test-workflow-static.sh` depends on `rg` (`if rg PYREPAIR …; then FAIL` passes falsely when rg is absent) and registers its trap late (`:297`); it is also sensitive to `CLAUDE_CODE_VERSION`.

**Fix**
- Standard helper `tests/lib/skip.sh`: `skip_if_root`, `require_cmd sqlite3|node|rg`, exiting 77.
- Apply to the cases above; friction-capture extracts the heredoc from init-orchestration SKILL.md or skips.
- workflow-static: `grep` instead of `rg`, early trap, `env -u CLAUDE_CODE_VERSION`.

**Acceptance**
- Full run as root and as non-root, with and without sqlite3/node/rg: no env-caused FAIL, only 77 skips.
- run-all-tests reports skips distinctly from passes.
- test-migrate without sqlite3 exits 77, not 0.

**Source**
- [README.md](README.md) #3-red-env
- [README.md](README.md) #4.1-sqlite-skip
- [01-agents-infra.md](01-agents-infra.md) #cross-7-env
- [06-handoff-transcript.md](06-handoff-transcript.md) #9
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:retro-gate/friction-capture-test
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:transcript-mirror/test.sh(M4)
- [07-memory.md](07-memory.md) #10
- [07-memory.md](07-memory.md) #test-results
- [07-memory.md](07-memory.md) #F:memory-store/test-migrate.sh
- [07-memory.md](07-memory.md) #F:validate-memory/test-reconcile.sh
- [07-memory.md](07-memory.md) #F:metrics/test.sh
- [04-council.md](04-council.md) #9-hermetic
- [04-council.md](04-council.md) #F:test-workflow-static.sh
- [10-specs.md](10-specs.md) #headline-5-env
- [09-release-tooling.md](09-release-tooling.md) #test-results-release-train-env

Sources: `README.md#3-red-env`, `README.md#4.1-sqlite-skip`, `01-agents-infra.md#cross-7-env`, `06-handoff-transcript.md#9`, `06-handoff-transcript.md#F:retro-gate/friction-capture-test`, `06-handoff-transcript.md#F:transcript-mirror/test.sh(M4)`, `07-memory.md#10`, `07-memory.md#test-results`, `07-memory.md#F:memory-store/test-migrate.sh`, `07-memory.md#F:validate-memory/test-reconcile.sh`, `07-memory.md#F:metrics/test.sh`, `04-council.md#9-hermetic`, `04-council.md#F:test-workflow-static.sh`, `10-specs.md#headline-5-env`, `09-release-tooling.md#test-results-release-train-env`

### W1-36 · [lint] skill-lint C6–C9: pragma placement, brace defaults, cwd paths, destructive git
**Priority** High · **Effort** M · **Labels** Improvement, Tech Debt · **Ticket group** T9 lint-rules

**Problem**
skill-lint passed all three `\  # lint-ok` P0 sites and the SQL-string pragmas. Classes it does not catch, all live or recently bitten: comment after a continuation `\`; `lint-ok` inside an open quote; `${X:-{…}}` brace defaults (4 wrap-ticket sites); cwd-relative `bash|python3 skills/…` in consumer-reachable fences (`memory-store/SKILL.md:147`, `epic/SKILL.md:26`); unquoted `cd $VAR`; `branch -D`/`reset --hard`/`clean -f`/`push --force|--delete` without adjacent guard; `# Stop here` without `exit`; sqlite3 on `$MEMDB` without `.timeout`; intra-fence use-before-define (setup MEMDB). Scope gaps: only ```` ```bash ```` fences (not `sh`/`shell`/unlabelled), not `agents/*.md`; C1 ignores order and undefined-anywhere vars.

**Fix**
- `check-skill-bash.sh`/`lint.py`: C6 `\\[ \t]+#`; C7 pragma inside open quote; C8 brace default; C9 destructive git without guard/waiver; plus cwd-relative skills path (dev-only skills exempt), `# Stop here` w/o exit, sqlite3 w/o timeout, intra-fence use-before-define.
- Extend scan to `agents/*.md` and `sh`/`shell` fences.

**Acceptance**
- Fixture per rule in skill-lint/test.sh (bite + clean).
- Repo passes after the P0/W0 fixes, with any remaining waivers justified.
- SPEC-021 updated to C1–C9.

**Source**
- [README.md](README.md) #wave1-lint
- [README.md](README.md) #1-exec-3
- [07-memory.md](07-memory.md) #2-lint
- [08-workflow-skills.md](08-workflow-skills.md) #2
- [03-large-commands.md](03-large-commands.md) #E8
- [09-release-tooling.md](09-release-tooling.md) #13
- [09-release-tooling.md](09-release-tooling.md) #F:skill-lint/lint.py
- [02-commands-docs.md](02-commands-docs.md) #14
- [02-commands-docs.md](02-commands-docs.md) #cross-2
- [01-agents-infra.md](01-agents-infra.md) #6-C1
- [01-agents-infra.md](01-agents-infra.md) #cross-3
- [README.md](README.md) #4.2
- [07-memory.md](07-memory.md) #7-lint
- [08-workflow-skills.md](08-workflow-skills.md) #test-results-lint

Sources: `README.md#wave1-lint`, `README.md#1-exec-3`, `07-memory.md#2-lint`, `08-workflow-skills.md#2`, `03-large-commands.md#E8`, `09-release-tooling.md#13`, `09-release-tooling.md#F:skill-lint/lint.py`, `02-commands-docs.md#14`, `02-commands-docs.md#cross-2`, `01-agents-infra.md#6-C1`, `01-agents-infra.md#cross-3`, `README.md#4.2`, `07-memory.md#7-lint`, `08-workflow-skills.md#test-results-lint`

### W1-37 · [smoke] Extend smoke harness to agents/, githooks, root and tools scripts
**Priority** High · **Effort** S · **Labels** Improvement · **Ticket group** T9 lint-rules

**Problem**
`tools/smoke/smoke.py:272-301` discovery skips `agents/*.md` entirely (no frontmatter or fence check for 12 agents — how project-init's broken fences shipped), root `*.sh` (`install.sh`, `uninstall.sh`, `install-test.sh`), `githooks/`, `tools/*.sh`, skill sub-docs (e.g. `skills/orchestrate/steps/*.md`) and `bash -n` on test scripts. The parser rejects YAML block lists (`:124-125`). `.claude-plugin/*.json` isn't validated (docs-drift covers some).

**Fix**
- Add those paths to `discover()`; agents require `name, description, tools, model, effort` (SPEC-003:20).
- `bash -n` every `*.sh` including tests; parse sub-doc fences.
- Accept YAML block lists or report them clearly.

**Acceptance**
- tools/smoke/test.sh gains fixtures for an agent missing `effort` and a broken githook.
- Smoke passes on repo after fixes.
- SPEC-030 scope text updated.

**Source**
- [01-agents-infra.md](01-agents-infra.md) #6
- [01-agents-infra.md](01-agents-infra.md) #F:tools/smoke/run.sh
- [README.md](README.md) #wave1-smoke
- [01-agents-infra.md](01-agents-infra.md) #cross-3

Sources: `01-agents-infra.md#6`, `01-agents-infra.md#F:tools/smoke/run.sh`, `README.md#wave1-smoke`, `01-agents-infra.md#cross-3`

### W1-38 · [specs] Spec lint: harden check-format, add check-index, gate CI and /release
**Priority** High · **Effort** S · **Labels** Improvement, Tech Debt · **Ticket group** T8 ci-all-tests

**Problem**
Nothing enforces SPEC-008. `specs/TDD.md:40` lists SPEC-035 as DRAFT while the file says ACTIVE; TDD history stops at 2026-08-27 and rows are out of date order (`:61,109,119`). `specs/core/SPEC-033-autopilot-policy.md` fails `check-format.sh` (no `## Test`/`## Validation`). `check-format.sh` itself false-passes: the Validation checkbox (`:73`) and Version History table (`:81`) aren't scoped to their sections and fenced code isn't excluded (reproduced), and it doesn't check ID vs filename. `spec-tooling/fixtures/*` exist but no test uses them.

**Fix**
- Scope checks with awk as for MUST; ignore fences; check ID = filename.
- New `check-index.sh`: index status = file status (one plain word), every file indexed, Covers paths exist (brace-expanded, historical waiver), history date order, APPROVED ⇒ all boxes checked.
- `spec-tooling/test.sh` using fixtures; fix SPEC-033 sections and SPEC-035 index row; wire into smoke.yml and `/release`.

**Acceptance**
- CI job fails on a synthetic status mismatch.
- All 37 specs pass check-format.
- Fixture pre fails, post passes.

**Source**
- [10-specs.md](10-specs.md) #1
- [10-specs.md](10-specs.md) #headline-1
- [10-specs.md](10-specs.md) #headline-4
- [08-workflow-skills.md](08-workflow-skills.md) #16
- [08-workflow-skills.md](08-workflow-skills.md) #F:spec-tooling/check-format.sh
- [08-workflow-skills.md](08-workflow-skills.md) #test-results-check-format
- [README.md](README.md) #wave1-spec-lint
- [README.md](README.md) #4.5
- [10-specs.md](10-specs.md) #SPEC-008
- [10-specs.md](10-specs.md) #SPEC-033
- [10-specs.md](10-specs.md) #SPEC-035

Sources: `10-specs.md#1`, `10-specs.md#headline-1`, `10-specs.md#headline-4`, `08-workflow-skills.md#16`, `08-workflow-skills.md#F:spec-tooling/check-format.sh`, `08-workflow-skills.md#test-results-check-format`, `README.md#wave1-spec-lint`, `README.md#4.5`, `10-specs.md#SPEC-008`, `10-specs.md#SPEC-033`, `10-specs.md#SPEC-035`

### W1-39 · [specs] Enforce status lifecycle and fix drifted spec statuses
**Priority** High · **Effort** S · **Labels** Tech Debt · **Ticket group** —

**Problem**
Status is stale both ways. DRAFT but implemented and tested: SPEC-031 (40/40), SPEC-033 (311/311), SPEC-034 (206/206), SPEC-036, SPEC-037 — while ACTIVE/APPROVED specs cite them normatively (SPEC-015 → SPEC-031, SPEC-003:22 → SPEC-037 F3/F6). APPROVED with 0 Validation boxes: SPEC-012 (0/19), SPEC-014 (0/21), SPEC-015 (0/16), against SPEC-008:66. SPEC-001:3 status "ACTIVE — implemented in v0.15.0" breaks the one-word rule (SPEC-008:55).

**Fix**
- Define transitions DRAFT→ACTIVE→APPROVED→DEPRECATED→delete in SPEC-008; add to check-index: flag DRAFT with all Covers present + passing tests ("promote?"), forbid ACTIVE/APPROVED citing DRAFT normatively.
- Promote SPEC-031/033/034/036/037; demote SPEC-012/014/015 to ACTIVE or tick verified boxes; fix SPEC-001 status.

**Acceptance**
- check-index reports no lifecycle violations.
- TDD.md index updated with a dated history row.
- No APPROVED spec with unchecked boxes.

**Source**
- [10-specs.md](10-specs.md) #4
- [10-specs.md](10-specs.md) #headline-3
- [10-specs.md](10-specs.md) #cross-normative-draft
- [10-specs.md](10-specs.md) #SPEC-001
- [10-specs.md](10-specs.md) #SPEC-012
- [10-specs.md](10-specs.md) #SPEC-014
- [10-specs.md](10-specs.md) #SPEC-015
- [10-specs.md](10-specs.md) #SPEC-031
- [10-specs.md](10-specs.md) #SPEC-034
- [10-specs.md](10-specs.md) #SPEC-036
- [10-specs.md](10-specs.md) #SPEC-037
- [08-workflow-skills.md](08-workflow-skills.md) #F:bug-hunt/SKILL.md(spec)

Sources: `10-specs.md#4`, `10-specs.md#headline-3`, `10-specs.md#cross-normative-draft`, `10-specs.md#SPEC-001`, `10-specs.md#SPEC-012`, `10-specs.md#SPEC-014`, `10-specs.md#SPEC-015`, `10-specs.md#SPEC-031`, `10-specs.md#SPEC-034`, `10-specs.md#SPEC-036`, `10-specs.md#SPEC-037`, `08-workflow-skills.md#F:bug-hunt/SKILL.md(spec)`

### W1-40 · [specs] Prune dead specs and retired-surface MUSTs; fold SPEC-028 into SPEC-014
**Priority** High · **Effort** S · **Labels** Tech Debt · **Ticket group** —

**Problem**
Removed-at-v1.1 surfaces are still live requirements: SPEC-005:24 (`commands/init-team.md` stub; `:7/:137` `skills/demo` stub), SPEC-014:44/:206 (fix-ticket command and skill stubs; the skill is a 355-line live backend), SPEC-016:7/92/223 (`skills/demo`), SPEC-028 M1 `:35`, M6 (ic5 vs debugger) and Tests 9/11/12 (`:106-109`). SPEC-028 is DEPRECATED yet "MUSTs remain authoritative" (`:12`). SPEC-019 and SPEC-027 have no implementation (Covers list missing files); AGENTS.md:271 and `release/SKILL.md:155,171` still cite SPEC-019; `.gitignore:26-27` keeps `.claude/incidents/`. Retired names: `/update-spec` (SPEC-014:64,69,70,176,244), `/standup` (SPEC-025:11,61,203,233), `/metrics` (SPEC-026), `/init-team` (SPEC-001:129, SPEC-003:19, SPEC-005:13, SPEC-022), `/fix-ticket` (SPEC-009:490). SPEC-014:80 "test-first all modes" contradicts arch mode.

**Fix**
- Archive SPEC-019/027 to `specs/archive/` (tombstone with deletion history); drop `.gitignore` incidents entry; replace AGENTS.md:271 and release SKILL citations.
- Strip stub MUSTs; fold live SPEC-028 protocol (debugger, `/debug ticket`) into SPEC-014; sweep retired names; fix SPEC-014:80.

**Acceptance**
- check-index: every Covers path exists.
- grep for `/update-spec`, `/init-team`, `/fix-ticket` in specs/ returns only history rows.
- TDD index reflects archive moves.

**Source**
- [10-specs.md](10-specs.md) #5
- [10-specs.md](10-specs.md) #headline-2
- [10-specs.md](10-specs.md) #cross-fix-ticket
- [10-specs.md](10-specs.md) #SPEC-005
- [10-specs.md](10-specs.md) #SPEC-016
- [10-specs.md](10-specs.md) #SPEC-019
- [10-specs.md](10-specs.md) #SPEC-025
- [10-specs.md](10-specs.md) #SPEC-026
- [10-specs.md](10-specs.md) #SPEC-027
- [10-specs.md](10-specs.md) #SPEC-028
- [10-specs.md](10-specs.md) #SPEC-003
- [04-council.md](04-council.md) #20
- [04-council.md](04-council.md) #F:specs/core/SPEC-028
- [08-workflow-skills.md](08-workflow-skills.md) #overlap-SPEC-014
- [README.md](README.md) #4.5

Sources: `10-specs.md#5`, `10-specs.md#headline-2`, `10-specs.md#cross-fix-ticket`, `10-specs.md#SPEC-005`, `10-specs.md#SPEC-016`, `10-specs.md#SPEC-019`, `10-specs.md#SPEC-025`, `10-specs.md#SPEC-026`, `10-specs.md#SPEC-027`, `10-specs.md#SPEC-028`, `10-specs.md#SPEC-003`, `04-council.md#20`, `04-council.md#F:specs/core/SPEC-028`, `08-workflow-skills.md#overlap-SPEC-014`, `README.md#4.5`

### W1-42 · [platform] Document platform floor; /doctor probes; shared portability helpers
**Priority** High · **Effort** M · **Labels** Improvement · **Ticket group** —

**Problem**
Scripts need bash ≥ 4 (8+ scripts), `flock` (7+), GNU `timeout` (5+), `sha256sum`, GNU `sed`/`find -printf`; stock macOS has none of these (`bash X` runs `/bin/bash` 3.2). There is no documented platform floor, no macOS CI and no `/doctor` probe, so failures surface as confusing downstream errors.

**Fix**
- Document the floor (bash ≥ 4, flock or fallback, coreutils) in docs/setup.md and README, with brew fixes.
- doctor: `deps.bash4` (BASH_VERSINFO of `bash` on PATH), `deps.flock`, `deps.timeout` (accept `gtimeout`), each WARN with fix-it.
- Add `skills/lib/portable.sh` with `lock_run` (flock → mkdir fallback with retry/timeout), `sha256()` (`shasum -a 256` fallback), `_timeout()` (timeout/gtimeout/unbounded+warn). Adoption tracked in the flock, bash-4 and GNU-coreutils items.

**Acceptance**
- doctor/test.sh covers the three probes (PATH shims).
- portable.sh has its own test.
- docs/setup.md lists the floor.

**Source**
- [README.md](README.md) #1-exec-8
- [README.md](README.md) #4.8
- [README.md](README.md) #wave1-platform-floor
- [09-release-tooling.md](09-release-tooling.md) #9
- [09-release-tooling.md](09-release-tooling.md) #F:doctor/doctor.sh(6)
- [09-release-tooling.md](09-release-tooling.md) #cross-2

Sources: `README.md#1-exec-8`, `README.md#4.8`, `README.md#wave1-platform-floor`, `09-release-tooling.md#9`, `09-release-tooling.md#F:doctor/doctor.sh(6)`, `09-release-tooling.md#cross-2`

### W1-43 · [platform] Replace bare `flock` with portable lock_run in all lock sites
**Priority** High · **Effort** M · **Labels** Bug, Concurrency · **Ticket group** —

**Problem**
`flock` (util-linux) is absent on stock macOS, and callers have no guard: `orchestrate/task-store.sh:91,148`, `epic/epic-lib.sh`, `ci-watch/sidecar.sh:85,130,175` (init/set/inc exit 127 in a subshell), `council/index-writer.sh` (finalize fails exit 6), `model-map/write-model.sh:146,170,190` (every set/unset fails → `/setup models` and `/adjust-agent --model/--effort` broken on macOS). The `models.local.json.lock` file can end up committed. `sidecar.sh` also stores `pr_number` as a string in init and an int in `set`.

**Fix**
- Switch every site to `lock_run` from `skills/lib/portable.sh` (flock if present, else mkdir-lock with stale detection).
- Place lock files under a gitignored path.
- Normalize `pr_number` to int.

**Acceptance**
- Tests for each script pass with `flock` removed from PATH.
- Concurrency test (two writers) still serializes on both paths.
- No bare `flock` outside portable.sh (grep).

**Source**
- [05-orchestration.md](05-orchestration.md) #14
- [05-orchestration.md](05-orchestration.md) #cross-7
- [05-orchestration.md](05-orchestration.md) #F:orchestrate/task-store.sh(flock)
- [04-council.md](04-council.md) #13-flock
- [04-council.md](04-council.md) #F:council/index-writer.sh
- [07-memory.md](07-memory.md) #9-flock
- [07-memory.md](07-memory.md) #F:model-map/write-model.sh
- [09-release-tooling.md](09-release-tooling.md) #F:ci-watch/sidecar.sh
- [README.md](README.md) #4.8

Sources: `05-orchestration.md#14`, `05-orchestration.md#cross-7`, `05-orchestration.md#F:orchestrate/task-store.sh(flock)`, `04-council.md#13-flock`, `04-council.md#F:council/index-writer.sh`, `07-memory.md#9-flock`, `07-memory.md#F:model-map/write-model.sh`, `09-release-tooling.md#F:ci-watch/sidecar.sh`, `README.md#4.8`

### W1-45 · [platform] Replace GNU-only coreutils usages (timeout, sha256sum, sed, find, mktemp)
**Priority** High · **Effort** M · **Labels** Bug · **Ticket group** —

**Problem**
GNU-only usages fail silently or loudly on macOS: `ci-watch/poll.sh:251` `timeout` → rc 127 treated as a real test failure, so a fixer is spawned repeatedly (P1); `timeout` also in precompact-capture (unbounded without it) and the permission probe. `sha256sum` without `shasum` fallback in `commands/council.md:550` (cache seed no-ops), `council/external-reviewer.sh:135` (pipefail abort), `memory-store/seed-common.sh:53,100`, transcript-mirror, install-test. GNU `sed 's/^-\+//'` (`council/engine.sh:306`), `\s` in ERE (install.sh:240, refactor plan-exemption grep), `find -printf` (`commands/retro.md:318` — single-mode discovery returns nothing), `mktemp …XXXXXX.jsonl` suffix (`handoff/discover-warm.sh:372,376`; BSD only randomizes trailing Xs), `date -Is`/`base64 -d` in the mirror, `sort -V` in plugin-dir.

**Fix**
- Adopt `sha256()` and `_timeout()` from portable.sh; poll.sh distinguishes 127 from test failure.
- `sed -E 's/^-+//'`, `[[:space:]]`, `stat`/Python loop instead of `find -printf`, `mktemp -d` + fixed name inside, portable date/base64 forms, version compare without `sort -V`.

**Acceptance**
- macOS CI job runs the affected suites green.
- poll.sh with no timeout binary reports a tooling warning, not a failure.
- grep lint forbids `sha256sum` outside portable.sh.

**Source**
- [06-handoff-transcript.md](06-handoff-transcript.md) #10
- [06-handoff-transcript.md](06-handoff-transcript.md) #B8
- [03-large-commands.md](03-large-commands.md) #E11
- [03-large-commands.md](03-large-commands.md) #C8
- [03-large-commands.md](03-large-commands.md) #R12
- [03-large-commands.md](03-large-commands.md) #cross-7
- [09-release-tooling.md](09-release-tooling.md) #F:ci-watch/poll.sh(1)
- [04-council.md](04-council.md) #13-sed
- [04-council.md](04-council.md) #F:council/engine.sh(7)
- [04-council.md](04-council.md) #F:council/external-reviewer.sh(3)
- [07-memory.md](07-memory.md) #F:memory-store/seed-common.sh(sha)
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:transcript-mirror/transcript-mirror.sh(gnu)
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:handoff/precompact-capture.sh(timeout)
- [01-agents-infra.md](01-agents-infra.md) #cross-8
- [01-agents-infra.md](01-agents-infra.md) #F:install-test.sh(sha)
- [01-agents-infra.md](01-agents-infra.md) #F:tools/permission-matrix-probe.sh(timeout)
- [08-workflow-skills.md](08-workflow-skills.md) #F:refactor/SKILL.md(\s)
- [09-release-tooling.md](09-release-tooling.md) #F:plugin-dir.sh(sort-V)
- [README.md](README.md) #4.8

Sources: `06-handoff-transcript.md#10`, `06-handoff-transcript.md#B8`, `03-large-commands.md#E11`, `03-large-commands.md#C8`, `03-large-commands.md#R12`, `03-large-commands.md#cross-7`, `09-release-tooling.md#F:ci-watch/poll.sh(1)`, `04-council.md#13-sed`, `04-council.md#F:council/engine.sh(7)`, `04-council.md#F:council/external-reviewer.sh(3)`, `07-memory.md#F:memory-store/seed-common.sh(sha)`, `06-handoff-transcript.md#F:transcript-mirror/transcript-mirror.sh(gnu)`, `06-handoff-transcript.md#F:handoff/precompact-capture.sh(timeout)`, `01-agents-infra.md#cross-8`, `01-agents-infra.md#F:install-test.sh(sha)`, `01-agents-infra.md#F:tools/permission-matrix-probe.sh(timeout)`, `08-workflow-skills.md#F:refactor/SKILL.md(\s)`, `09-release-tooling.md#F:plugin-dir.sh(sort-V)`, `README.md#4.8`

### W1-46 · [commands] One argument pass-through convention: heredoc `$ARGUMENTS`, ban `"$@"`
**Priority** High · **Effort** M · **Labels** Bug, Security · **Ticket group** —

**Problem**
Five commands pass args with `"$@"`, which is empty in a Bash-tool shell: `commands/audit.md:57`, `compact-transcript.md:51`, `doctor.md:86`, `status.md:132`, `setup.md:187` (`--skip-doctor` scan). Others inject `$ARGUMENTS` unquoted: `commands/retro.md:53,240` `for arg in $ARGUMENTS` (word-splitting + globbing; unknown flags only warn at `:86`; the 60-line Step 1 parser is duplicated verbatim at `:234-273`), `commands/memory.md:535` `bash "$EXPORT_SH" $ARGUMENTS "$MROOT"` (includes the word `export`; works only because the trailing MROOT overwrites the positional).

**Fix**
- Standard block: `ARGS=$(cat <<'__A__'\n$ARGUMENTS\n__A__\n)` then parse with `read -ra`/python shlex.
- Apply to the seven sites; dedupe retro's parser into one fence (or script); pass explicit args to export.
- Skill-lint rule banning bare `"$@"` in `commands/*.md`.

**Acceptance**
- Each command, extracted with sample args containing spaces and `*`, receives them intact.
- Lint rule has a bite fixture.
- retro parser appears once.

**Source**
- [02-commands-docs.md](02-commands-docs.md) #3
- [02-commands-docs.md](02-commands-docs.md) #cross-1
- [02-commands-docs.md](02-commands-docs.md) #F:commands/audit.md
- [02-commands-docs.md](02-commands-docs.md) #F:commands/compact-transcript.md
- [02-commands-docs.md](02-commands-docs.md) #F:commands/doctor.md
- [02-commands-docs.md](02-commands-docs.md) #F:commands/status.md
- [02-commands-docs.md](02-commands-docs.md) #F:commands/setup.md(5)
- [03-large-commands.md](03-large-commands.md) #R13
- [03-large-commands.md](03-large-commands.md) #M14
- [README.md](README.md) #4.7-args
- [README.md](README.md) #6-T5-argloops

Sources: `02-commands-docs.md#3`, `02-commands-docs.md#cross-1`, `02-commands-docs.md#F:commands/audit.md`, `02-commands-docs.md#F:commands/compact-transcript.md`, `02-commands-docs.md#F:commands/doctor.md`, `02-commands-docs.md#F:commands/status.md`, `02-commands-docs.md#F:commands/setup.md(5)`, `03-large-commands.md#R13`, `03-large-commands.md#M14`, `README.md#4.7-args`, `README.md#6-T5-argloops`

### W1-47 · [security] Untrusted-input-to-code convention: argv/env, `?` params, roster regex
**Priority** High · **Effort** S · **Labels** Security, Tech Debt · **Ticket group** —

**Problem**
Untrusted text reaches code in several places beyond the P0 sites: `--agent <name>` interpolated unescaped into SQL and never roster-checked (`commands/memory.md:437,442,882`); `'$JSONL '` interpolated into Python source (`commands/retro.md:815-820`); `python3 -c "…open('$f')"` in the init-orchestration task-completed template (`SKILL.md:700`); `DIMS` from `EMBEDDING_DIMENSIONS` unescaped in `download-extensions.sh:346`; memory-store SKILL `:59` inserts `<AGENT>`/`<TYPE>` without escaping; memory-recall `<AGENT_FILTER>`/`<TYPE_FILTER>`/`<CURRENT_MODEL>` placeholders. No written rule exists; the correct pattern is already used at memory.md:198-204 and retro.md:1240-1245.

**Fix**
- AGENTS.md Code Conventions: argv/env for Python, `?` params (Python sqlite3) for any SQL carrying LLM or user text, roster regex `^(pm|tech-lead|ic5|ic4|devops|qa|ds)$` for `--agent`, integer validation for numeric config.
- Fix each listed site; add `skills/lib/sqlq.py` helper for parameterized one-shots.

**Acceptance**
- Probes with quote/`$()` payloads at each site execute nothing.
- `--agent 'x''; DROP'` rejected at parse time.
- Lint check for `python3 -c "…'$` pattern.

**Source**
- [README.md](README.md) #1-exec-5
- [README.md](README.md) #4.4
- [README.md](README.md) #wave1-input-safety
- [03-large-commands.md](03-large-commands.md) #E10
- [03-large-commands.md](03-large-commands.md) #M4
- [03-large-commands.md](03-large-commands.md) #R16
- [03-large-commands.md](03-large-commands.md) #cross-8
- [05-orchestration.md](05-orchestration.md) #F:init-orchestration/SKILL.md(python)
- [07-memory.md](07-memory.md) #cross-sql
- [07-memory.md](07-memory.md) #F:memory-store/download-extensions.sh(DIMS)
- [07-memory.md](07-memory.md) #F:memory-store/SKILL.md(:59)

Sources: `README.md#1-exec-5`, `README.md#4.4`, `README.md#wave1-input-safety`, `03-large-commands.md#E10`, `03-large-commands.md#M4`, `03-large-commands.md#R16`, `03-large-commands.md#cross-8`, `05-orchestration.md#F:init-orchestration/SKILL.md(python)`, `07-memory.md#cross-sql`, `07-memory.md#F:memory-store/download-extensions.sh(DIMS)`, `07-memory.md#F:memory-store/SKILL.md(:59)`

### W1-48 · [memory] migrate-md: stop lossy migration and unsafe vector-table drop
**Priority** High · **Effort** M · **Labels** Bug · **Ticket group** T1 memory-safety

**Problem**
`skills/memory-store/migrate-md.sh` pipes every chunk through `sed '/^#/d'` (`:109,119`), deleting `## Header` lines, `###` subheaders and any `#`-leading line, and `sed '/^$/d'` removes blank lines; `head -c 8000/5000` silently truncates (splitting UTF-8). The fail-closed gate ignores truncation and stripping, then **deletes the source**. At `:250-254`, if `PRAGMA table_info` fails (lock, `.load` failure) `grep -c` yields 0 and it runs `DROP TABLE vec_memories_N`, wiping vectors while `embedding_meta` rows remain (never re-embedded). `:234` `json(lembed(...))` on a BLOB likely errors (`vec_to_json`); non-JSON endpoint responses abort under `set -e` (`:221,242`); `.load $EXT_DIR/...` unquoted.

**Fix**
- Keep header lines and blank lines; split oversized sections instead of truncating; count truncation/strip as "skipped" so the source is kept.
- Guard `DROP TABLE` with an explicit load check + timeout and delete matching `embedding_meta`.
- Use `vec_to_json`; tolerate bad responses per row; quote `.load` paths.

**Acceptance**
- New test: headers and a >8000-char section survive; source retained on any loss.
- Simulated `.load` failure does not drop tables.
- No UTF-8 split in output.

**Source**
- [07-memory.md](07-memory.md) #5
- [07-memory.md](07-memory.md) #F:memory-store/migrate-md.sh
- [README.md](README.md) #P1-migrate-md

Sources: `07-memory.md#5`, `07-memory.md#F:memory-store/migrate-md.sh`, `README.md#P1-migrate-md`

### W1-49 · [memory] Reconcile: keyword fallback, O(n) Jaccard, k=5, transactional resolvers
**Priority** High · **Effort** M · **Labels** Bug, Concurrency · **Ticket group** —

**Problem**
`skills/validate-memory/reconcile-lib.sh`: `_embed_candidates` always returns 0 (`:359`), so when vec0 exists but fails to load the result is `method=embed` with 0 candidates and no keyword fallback; test T15 locks this in with a dummy vec0. The keyword path is O(n²) with mktemp/sort/comm per pair (~1M pairs, hours at the 1400-row cap). KNN uses k=6 and filters by agent after KNN, so same-agent neighbours crowd out cross-agent ones (SPEC-011:119 says k=5). Resolvers archive and log in two non-transactional calls (`:395-400,427-435`); `resolve-merge W W` archives the winner; ids aren't checked to exist/unarchived; deep-audit `printf '/council "%s vs %s"'` doesn't escape claims.

**Fix**
- Return non-zero on `.load`/KNN failure so keyword runs.
- Jaccard in one Python pass with an inverted index.
- k=5 with a larger pre-filter k; single transaction per resolve; reject winner==loser and missing/archived ids; escape council args.

**Acceptance**
- T15 rewritten: broken vec0 falls back to keyword with candidates.
- 1400-row keyword run completes in <30 s.
- Resolve failure mid-way leaves no partial state.

**Source**
- [07-memory.md](07-memory.md) #8
- [07-memory.md](07-memory.md) #F:validate-memory/reconcile-lib.sh(fallback)
- [07-memory.md](07-memory.md) #F:validate-memory/test-reconcile.sh
- [10-specs.md](10-specs.md) #SPEC-011-k

Sources: `07-memory.md#8`, `07-memory.md#F:validate-memory/reconcile-lib.sh(fallback)`, `07-memory.md#F:validate-memory/test-reconcile.sh`, `10-specs.md#SPEC-011-k`

### W1-50 · [backlog] reconcile.sh must preserve non-row index content
**Priority** High · **Effort** M · **Labels** Bug · **Ticket group** —

**Problem**
`skills/backlog/reconcile.sh:250-281` rebuilds the index from the preamble plus slug rows only; group sub-headings, indented sub-notes and other sections (e.g. `## Ideas`) are silently deleted while it prints "applied 0 action(s)" (reproduced). SKILL `:397` promises only the preamble, and close.sh's comment claims hierarchical content is preserved. Slug rows in the preamble are kept there and re-emitted under Pending (duplicates); completed items leave permanent dead refs. JSON verdicts are parsed with grep/awk, so nested objects or escaped quotes mis-parse.

**Fix**
- Rebuild in place: delete only lines of pruned/dead rows and retag survivors; keep every other line verbatim (or abort with a finding when unexpected content exists under Pending/Completed).
- De-duplicate preamble slug rows; parse verdicts with jq when present.

**Acceptance**
- reconcile-test: headings, sub-notes and `## Ideas` survive a prune.
- No duplicate row after reconcile.
- Escaped-quote verdict parses.

**Source**
- [09-release-tooling.md](09-release-tooling.md) #5
- [09-release-tooling.md](09-release-tooling.md) #F:backlog/reconcile.sh(1,2,4)
- [README.md](README.md) #P1-backlog

Sources: `09-release-tooling.md#5`, `09-release-tooling.md#F:backlog/reconcile.sh(1,2,4)`, `README.md#P1-backlog`

### W1-51 · [agents] Make distiller atomic: one transaction, argv inputs, no double-escaping
**Priority** High · **Effort** M · **Labels** Bug, Concurrency · **Ticket group** T4 setup-agents

**Problem**
`agents/distiller.md`: `:90` says to SQL-escape all content with `sed "s/'/''/g"`, but step 3 (`:33-41`) uses a parameterized Python INSERT — a literal-minded haiku doubles every `'` in digests. Steps 3/4/5 (`:30-51`) are three separate non-transactional commands; if archive fails after insert, digest and sources both stay live. `$MEMDB`, `$DIGEST`, `$NEW_ID` are never defined in any fence and `:49` assumes values carry across fences. `PRAGMA busy_timeout=5000;` via CLI prints 5000. The promotion criterion "referenced multiple times across sessions" (`:64`) is uncheckable (no reference counts).

**Fix**
- Ship `skills/memory-store/distill-commit.py` doing INSERT digest + UPDATE archived + INSERT log in one transaction, taking MEMDB, agent, digest and ids as argv.
- Distiller calls it once per group; drop the sed rule; use `-cmd ".timeout 5000"`; restate the promotion criterion with a measurable rule.

**Acceptance**
- Test: failure injected after insert rolls everything back.
- Digest containing `'` stored verbatim.
- No cross-fence variable use in distiller.md.

**Source**
- [01-agents-infra.md](01-agents-infra.md) #4
- [01-agents-infra.md](01-agents-infra.md) #F:agents/distiller.md
- [01-agents-infra.md](01-agents-infra.md) #cross-3
- [README.md](README.md) #6-T4
- [README.md](README.md) #4.2

Sources: `01-agents-infra.md#4`, `01-agents-infra.md#F:agents/distiller.md`, `01-agents-infra.md#cross-3`, `README.md#6-T4`, `README.md#4.2`

### W1-52 · [init-orchestration] TaskCompleted hook: filter candidates by status and ticket
**Priority** High · **Effort** M · **Labels** Bug · **Ticket group** —

**Problem**
The task-completed hook template (`skills/init-orchestration/SKILL.md:746-760`) takes a bare TaskCreate id `3` and collects every historical `*-3.json` across all issues; with any-true `requires_council` and no status filter, an old issue's council task can gate or block an unrelated task #3 forever.

**Fix**
- Ignore candidates with `status=="completed"`; match by `CLAUDE_TICKET`/issue prefix when available (plan-index keys from the task-key item).
- Log which candidate was chosen when several remain.

**Acceptance**
- init-orchestration test: stale completed `OLD-3.json` with requires_council does not gate `NEW-3`.
- check-hook-templates passes.
- Hook regenerated by `/setup orchestration`.

**Source**
- [05-orchestration.md](05-orchestration.md) #6
- [05-orchestration.md](05-orchestration.md) #F:init-orchestration/SKILL.md(hook)
- [05-orchestration.md](05-orchestration.md) #cross-3

Sources: `05-orchestration.md#6`, `05-orchestration.md#F:init-orchestration/SKILL.md(hook)`, `05-orchestration.md#cross-3`

### W1-53 · [autopilot] Close state-machine holes: Step 5 branch, bounded QA loop, ITER
**Priority** High · **Effort** M · **Labels** Bug · **Ticket group** —

**Problem**
`skills/orchestrate/steps/05-questions.md:17` "Wait for user answers" has no autopilot branch (kickoff maps this to BC1 halt), so autopilot `/orchestrate` stalls. `steps/10-qa.md:370` "Repeat until QA passes" has no cap and no autopilot halt; BC2 (`qa_bounces>=3`) is evaluated only at ship-choice, reachable only after a PASS — unbounded loop. `ITER=0` "++ once per stint" (`00-resolve.md:162`) is never incremented and not restored on resume, so the BC6 iteration cap never trips (SPEC-033 M9). The 10b "survives resume" check has no persisted marker.

**Fix**
- Add an autopilot BC1 branch to 05-questions.
- Cap the Step 10 loop: `qa_bounces>=3` → BC2 halt.
- `ITER=$((ITER+1))` at each spawn site; restore from `max(.budget.iteration)` on resume; persist the 10b marker in the plan.

**Acceptance**
- autopilot test scenarios: questions halt BC1; 3 QA bounces halt BC2; iteration cap trips.
- Resume restores ITER.
- router-static-test updated for new text.

**Source**
- [05-orchestration.md](05-orchestration.md) #7
- [05-orchestration.md](05-orchestration.md) #F:steps/05-questions.md
- [05-orchestration.md](05-orchestration.md) #F:steps/10-qa.md
- [05-orchestration.md](05-orchestration.md) #F:steps/00-resolve.md(ITER)
- [05-orchestration.md](05-orchestration.md) #cross-6
- [README.md](README.md) #wave2-orchestration

Sources: `05-orchestration.md#7`, `05-orchestration.md#F:steps/05-questions.md`, `05-orchestration.md#F:steps/10-qa.md`, `05-orchestration.md#F:steps/00-resolve.md(ITER)`, `05-orchestration.md#cross-6`, `README.md#wave2-orchestration`

### W1-54 · [transcript-mirror] Crash-safe rebuild, per-sid lock, bounded hook input
**Priority** High · **Effort** M · **Labels** Bug, Concurrency · **Ticket group** T6 mirror-perf

**Problem**
The rebuild (`transcript-mirror.sh:652-686`) moves `agents/` and `verbatim/` to sibling stashes, then `mv "$DIR" "$BAK"` (`:668`), then `mv NEW DIR`, with no TERM trap. A hook-timeout kill mid-swap can leave the sid dir missing and orphan `<sid>.agents.<pid>`/`.verbatim.<pid>` and the WORK dir — SPEC-036 M6 calls dropping agents/ a spec fail, and rebuild is the slow path most likely to be killed. There is no lock against concurrent Stop/SessionEnd/SubagentStop/summarize-transcript. Hook stdin `STDIN=$(cat)` is unbounded (`:517`); `jq … "$TP" | head -1` for PARENT (`:588`) fails on a malformed line under pipefail.

**Fix**
- Build NEW fully, hard-link/copy agents/verbatim into it, single rename swap; `trap … TERM INT`; recover orphaned `<sid>.{bak,agents,verbatim}.*` at startup.
- Per-sid `mkdir` lock with short wait-or-skip (fail-open).
- Bound stdin (`head -c`); tolerate malformed lines for PARENT.

**Acceptance**
- Test kills rebuild at each step; next run recovers with agents/ intact.
- Concurrent Stop + summarize produce consistent output.
- Malformed first line doesn't abort.

**Source**
- [06-handoff-transcript.md](06-handoff-transcript.md) #2
- [06-handoff-transcript.md](06-handoff-transcript.md) #12
- [06-handoff-transcript.md](06-handoff-transcript.md) #B2
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:transcript-mirror/transcript-mirror.sh
- [06-handoff-transcript.md](06-handoff-transcript.md) #F:transcript-mirror/summarize-transcript.py(lock)
- [README.md](README.md) #6-T6
- [10-specs.md](10-specs.md) #SPEC-036

Sources: `06-handoff-transcript.md#2`, `06-handoff-transcript.md#12`, `06-handoff-transcript.md#B2`, `06-handoff-transcript.md#F:transcript-mirror/transcript-mirror.sh`, `06-handoff-transcript.md#F:transcript-mirror/summarize-transcript.py(lock)`, `README.md#6-T6`, `10-specs.md#SPEC-036`

### W1-55 · [retro] Fix `--all` repeat filtering order and implement the TIGHTEN merge
**Priority** High · **Effort** M · **Labels** Bug · **Ticket group** —

**Problem**
In `commands/retro.md` the top-5 cap (4e, `:1100-1126`) runs before the `--all` repeat/singleton filter (4f/5a), so repeats are counted only among the top 5 (SPEC-012:95 wants collapse across all sessions); singletons are counted per proposal row, not per distinct session; exact-string `pattern_summary` matching across independent haiku runs almost never matches, so `--all` drops nearly everything. TIGHTEN merge (5d) is contradictory: the schema says col 4 is merged deterministically by 5d, `:1312` says the orchestrator does it at presentation, 5d says "same Python pass… or post-loop", no code exists, and Apply (`:1662`) passes `proposed_text` unchanged.

**Fix**
- Filter repeats (by distinct session, normalized/fuzzy pattern key) before the top-5 cap.
- Implement 5d merge in code (or remove the claim and document presentation-time merge) consistently in schema, 5d and Apply.
- Long-term home is `classify.py` (retro scripts item).

**Acceptance**
- Fixture with 3 sessions sharing a reworded pattern: counted as a repeat.
- TIGHTEN rows show merged text at Apply.
- SPEC-012:95 behavior covered by a test.

**Source**
- [03-large-commands.md](03-large-commands.md) #R4
- [03-large-commands.md](03-large-commands.md) #R6
- [10-specs.md](10-specs.md) #SPEC-012

Sources: `03-large-commands.md#R4`, `03-large-commands.md#R6`, `10-specs.md#SPEC-012`

### W1-56 · [council] Add engine.sh test coverage for untested paths
**Priority** High · **Effort** M · **Labels** Tech Debt · **Ticket group** T3 council-integrity

**Problem**
Many `skills/council/engine.sh` paths are untested: `repair_json_file` (fence and backslash cases), exits 4/5/7, traversal rejection, `resolve-task-id`/report-path resolution, `CLAUDE_TASK_ID`, `--last` slug, finalize cache cleanup, bare-list judge output, and index-writer concurrency. None of the 4 council test scripts runs in CI (CI wiring is in the CI item).

**Fix**
- Extend `test-tier-engine.sh`/`test-finalize-missing-tid.sh` (or a new `test-engine.sh`) with a case per path above, using mktemp roots and traps.
- Add a two-process index-writer concurrency case.

**Acceptance**
- Each listed path has ≥1 asserting case.
- Tests hermetic (no writes outside TMP).
- Included in run-all-tests.

**Source**
- [04-council.md](04-council.md) #9
- [04-council.md](04-council.md) #cross-6
- [04-council.md](04-council.md) #F:test-tier-grade.sh,test-tier-engine.sh,test-finalize-missing-tid.sh

Sources: `04-council.md#9`, `04-council.md#cross-6`, `04-council.md#F:test-tier-grade.sh,test-tier-engine.sh,test-finalize-missing-tid.sh`

### W1-59 · [security-scan] Scan staged + untracked files from repo root; report truncation
**Priority** High · **Effort** M · **Labels** Bug, Security · **Ticket group** —

**Problem**
`skills/security-scan/scan.sh` never scans staged-only or untracked files (`:26-27` lacks `diff --cached` and `ls-files --others`); from a subdirectory it passes repo-root-relative paths that don't resolve; `MAX_TARGETS=40` truncates silently (`:39-42`); on the default branch with a clean tree it falls back to `.` = cwd. `semgrep --config=auto` needs network — offline it fails but the summary still prints with no ok/fail status; CodeQL uses any existing (possibly stale) DB not filtered to the diff. `SECURITY_SCAN=0` is only honored by callers; output dirs are never cleaned; the "Dedup" comment (`:32`) is mislabelled. No secret or dependency scanning.

**Fix**
- `cd "$WTROOT"`; add `git diff --cached --name-only` + `git ls-files --others --exclude-standard`; `sort -u`; print `TRUNCATED n/N`; record semgrep exit status; honor `SECURITY_SCAN=0`; clean output dirs.
- Optional gitleaks/osv-scanner stage.

**Acceptance**
- New `security-scan/test.sh` with a stub semgrep: staged and untracked files passed; subdirectory run correct; truncation reported.
- Offline semgrep shows FAILED status.
- SECURITY_SCAN=0 short-circuits.

**Source**
- [08-workflow-skills.md](08-workflow-skills.md) #7
- [08-workflow-skills.md](08-workflow-skills.md) #F:security-scan/SKILL.md+scan.sh
- [08-workflow-skills.md](08-workflow-skills.md) #test-results-scan
- [README.md](README.md) #wave3-security-scan

Sources: `08-workflow-skills.md#7`, `08-workflow-skills.md#F:security-scan/SKILL.md+scan.sh`, `08-workflow-skills.md#test-results-scan`, `README.md#wave3-security-scan`

### W1-35 · [tests] Stop tests mutating the live repo or leaking temp files
**Priority** Medium · **Effort** S · **Labels** Tech Debt · **Ticket group** T8 ci-all-tests

**Problem**
`skills/docs-drift/test.sh` mutates README and `commands/` in the live repo and restores with `cp`, but its EXIT trap only deletes the backups — an interrupted run leaves the repo drifted and backups gone; unsafe alongside other tests. `council/test-workflow-static.sh` writes `.claude/council/<date>-claim.md`, `.finalize-meta.json` (`:356-377`) and copies an anchor into `.claude/retro/anchors/` (`:58-65`). Tests leak `handoff-grok-adapt.*.jsonl`, `grok-norm-*.jsonl`, `grok-norm.err` and council preflight `council-cache-*` dirs into TMPDIR (32 after one run).

**Fix**
- docs-drift test: copy the needed subset to a scratch root and run with `--root` (or restore before deleting backups in an EXIT/INT trap).
- workflow-static: point MROOT at a temp dir.
- Tests set `TMPDIR` to a per-test dir removed on exit.

**Acceptance**
- `git status --porcelain` is empty after running all tests (CI assertion).
- Killing docs-drift/test.sh mid-run leaves the tree clean.
- TMPDIR contains no leftovers after the suite.

**Source**
- [09-release-tooling.md](09-release-tooling.md) #14
- [09-release-tooling.md](09-release-tooling.md) #F:docs-drift/test.sh
- [README.md](README.md) #3-writes-live-repo
- [04-council.md](04-council.md) #test-side-effects
- [04-council.md](04-council.md) #F:test-workflow-static.sh(2)
- [06-handoff-transcript.md](06-handoff-transcript.md) #test-leaks

Sources: `09-release-tooling.md#14`, `09-release-tooling.md#F:docs-drift/test.sh`, `README.md#3-writes-live-repo`, `04-council.md#test-side-effects`, `04-council.md#F:test-workflow-static.sh(2)`, `06-handoff-transcript.md#test-leaks`

### W1-41 · [specs] Machine-checkable AC↔test traceability
**Priority** Medium · **Effort** M · **Labels** Improvement · **Ticket group** —

**Problem**
No test script cites a spec or AC id (0 hits across 76 scripts for SPEC-006/007/008/015/016/020/028/029/032), so there is no machine link from acceptance criteria to tests. SPEC-006, 007, 015, 020, 029 (theme-status.sh) and 028 have no executable test at all. SPEC-018 is the only spec with a numbered Test→script map, and it lives in the TDD Coverage column.

**Fix**
- Convention: every MUST/AC carries an id (`SPEC-018/T39`); test assertions print or tag it (`# covers: SPEC-018/T39`).
- `tools/check-traceability.sh` lists ACs without a covering tag (report-only first, then gate).
- Move the SPEC-018 map into a `## Traceability` table in the spec.
- Add minimal tests for SPEC-006/007/020 (theme-status covered by P0-17).

**Acceptance**
- Checker runs in CI and prints uncovered ACs.
- SPEC-018 has a Traceability section.
- SPEC-006/007/020 each have ≥1 tagged test.

**Source**
- [10-specs.md](10-specs.md) #3
- [10-specs.md](10-specs.md) #AC-traceability
- [10-specs.md](10-specs.md) #SPEC-006
- [10-specs.md](10-specs.md) #SPEC-007
- [10-specs.md](10-specs.md) #SPEC-015
- [10-specs.md](10-specs.md) #SPEC-020
- [10-specs.md](10-specs.md) #SPEC-029

Sources: `10-specs.md#3`, `10-specs.md#AC-traceability`, `10-specs.md#SPEC-006`, `10-specs.md#SPEC-007`, `10-specs.md#SPEC-015`, `10-specs.md#SPEC-020`, `10-specs.md#SPEC-029`

### W1-44 · [platform] Remove bash-4-only constructs or fail loudly with a reason
**Priority** Medium · **Effort** M · **Labels** Tech Debt · **Ticket group** —

**Problem**
`declare -A` and `local -n` abort under macOS `/bin/bash` 3.2: `council/tier-grade.sh` (`declare -A`), `council/index-writer.sh:45` (`local -n`, needs 4.3), `release/check-ship-history.sh:372` (the comment at :371 even claims portability), `backlog/reconcile.sh:112,178-181` (and on bash < 4.4, `set -u` + empty arrays at `:197,272,297` is fatal), plus epic-lib/dag-lib usages. tier-grade failing means council grading fails (callers fail closed, but with no reason).

**Fix**
- Replace associative arrays with temp files/awk/jq or `case` tables in check-ship-history and reconcile (straightforward per 09).
- Replace `local -n` with echo-return in index-writer.
- Where bash 4 stays, add an explicit `BASH_VERSINFO` guard printing the platform-floor message (tier-grade: fail closed with a reason in JSON).

**Acceptance**
- Each script's tests pass under bash 3.2 (CI macOS job) or print the floor error.
- tier-grade emits JSON with a reason on bash 3.2.
- No `${arr[@]}` unset-array failures under `set -u`.

**Source**
- [04-council.md](04-council.md) #13-bash4
- [04-council.md](04-council.md) #F:council/tier-grade.sh(5)
- [04-council.md](04-council.md) #F:council/index-writer.sh(local-n)
- [09-release-tooling.md](09-release-tooling.md) #F:release/check-ship-history.sh(1)
- [09-release-tooling.md](09-release-tooling.md) #F:backlog/reconcile.sh(3)
- [05-orchestration.md](05-orchestration.md) #F:epic/epic-lib.sh(bash4)
- [09-release-tooling.md](09-release-tooling.md) #cross-2

Sources: `04-council.md#13-bash4`, `04-council.md#F:council/tier-grade.sh(5)`, `04-council.md#F:council/index-writer.sh(local-n)`, `09-release-tooling.md#F:release/check-ship-history.sh(1)`, `09-release-tooling.md#F:backlog/reconcile.sh(3)`, `05-orchestration.md#F:epic/epic-lib.sh(bash4)`, `09-release-tooling.md#cross-2`

### W1-57 · [install] Harden install-test.sh: set +e captures, cleanup, portability, coverage
**Priority** Medium · **Effort** S · **Labels** Tech Debt · **Ticket group** —

**Problem**
`install-test.sh` captures `rc=$?` under `set -e` without `set +e` at `:49,91,93,102,131`, so a failing install aborts the harness with no FAIL line and the rc checks are dead. It uses `sha256sum` (`:21`), has no `trap` cleanup, doesn't test uninstall.sh, the `--assign-models` apply path, or that generated copies lack `tools:`/`model:`; AC numbering skips AC4. Not in CI.

**Fix**
- Wrap captured runs in `set +e … set -e`; add `trap` cleanup; use `sha256()` helper.
- Add cases: uninstall, assign-models apply, stripped frontmatter, unknown flag; renumber ACs.

**Acceptance**
- Forcing install failure yields a FAIL line, not an abort.
- New cases pass.
- Runs on macOS job.

**Source**
- [01-agents-infra.md](01-agents-infra.md) #14
- [01-agents-infra.md](01-agents-infra.md) #F:install-test.sh

Sources: `01-agents-infra.md#14`, `01-agents-infra.md#F:install-test.sh`

### W1-58 · [autopilot] Shared flag-edge test matrix for autopilot and epic parsers
**Priority** Medium · **Effort** S · **Labels** Tech Debt · **Ticket group** —

**Problem**
`skills/autopilot/parse-flags.sh` has four duplicate policies: `--tier` strict (dies), `--council-tier`/`--max-loc` last-wins, `--autopilot` mixed (`--autopilot=patch --autopilot` keeps patch via sticky `FLAG_HAS_EQ`; reverse yields minor). Typos like `--autopliot` are silently ignored → autopilot off. The epic parser uses a different loop, strict duplicates and different value forms; both ignore unknown `--flags`. `epic-lib.sh init --title --mode x` sets title to "--mode".

**Fix**
- One table-driven test covering duplicate, bare, empty, `=`, space form and unknown-flag typo for both parsers.
- Normalize `--autopilot` duplicates explicitly (last-wins or die); reject unknown `--*` flags with exit 64; reject flag-looking values for `--title`.

**Acceptance**
- Matrix test passes for both parsers.
- `--autopliot` exits 64.
- SPEC-025 AC8 parser split preserved.

**Source**
- [05-orchestration.md](05-orchestration.md) #15
- [05-orchestration.md](05-orchestration.md) #F:autopilot/parse-flags.sh
- [05-orchestration.md](05-orchestration.md) #cross-8
- [05-orchestration.md](05-orchestration.md) #F:epic/epic-lib.sh(init-parse)

Sources: `05-orchestration.md#15`, `05-orchestration.md#F:autopilot/parse-flags.sh`, `05-orchestration.md#cross-8`, `05-orchestration.md#F:epic/epic-lib.sh(init-parse)`

### W1-60 · [docs-drift] Broaden skill-ref to skills/agents/specs; add skill-name check
**Priority** Medium · **Effort** M · **Labels** Improvement · **Ticket group** —

**Problem**
`skills/docs-drift` `skill-ref` (`:524`) scans only `commands/*.md`, so dangling `skills/...` refs elsewhere go uncaught — live ones: SPEC-027 `skills/incident/{timeline,workspace}.sh`, SPEC-019 `skills/local-agent/*`, SPEC-002:268 `skills/transcript-parse/freshness-gate.sh`, and spec-tooling partials pointing at deleted generate-specs/reflect-specs. `section_lines` (`:73-114`) has convoluted duplicate-match logic and doesn't skip fences, so a `# comment` in a fence ends a section. Not checked: SKILL frontmatter `name` = directory, TDD index ↔ files. SPEC-032 says D1–D8 (and "three distinct checks", `:69-78`) while the skill has D1–D10 and CI has 9 jobs.

**Fix**
- Extend D9 to `skills/**/*.md`, `agents/*.md`, `AGENTS.md` and spec `**Covers**` lines, with `<!-- drift-ok: skill-ref -->` for historical text.
- Add `skill-name` check; skip fences in `section_lines`.
- Update SPEC-032 text.

**Acceptance**
- docs-drift/test.sh bite fixtures for each new check.
- Repo passes after spec prune item lands.
- SPEC-032 lists D1–D10.

**Source**
- [09-release-tooling.md](09-release-tooling.md) #12
- [09-release-tooling.md](09-release-tooling.md) #F:docs-drift/check-docs-drift.sh,check.py
- [09-release-tooling.md](09-release-tooling.md) #cross-5
- [10-specs.md](10-specs.md) #SPEC-032
- [10-specs.md](10-specs.md) #SPEC-002

Sources: `09-release-tooling.md#12`, `09-release-tooling.md#F:docs-drift/check-docs-drift.sh,check.py`, `09-release-tooling.md#cross-5`, `10-specs.md#SPEC-032`, `10-specs.md#SPEC-002`
