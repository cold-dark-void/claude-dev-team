## Slice: specs

I stayed read-only. To check the specs I ran every `*test*.sh` in a scratch copy of the repo, 75 scripts in all, skipping install-test.sh; the only file I wrote was a helper script in reviewer scratch space. I checked every backticked path and every bare path in all 37 specs and in `specs/TDD.md` against the filesystem. Plugin version is 1.18.14.

**Headline findings**
1. **The index doesn't match the files.**
   - `specs/TDD.md:40` lists SPEC-035 as DRAFT, but `SPEC-035:3` says ACTIVE (promoted 2026-08-16 at `SPEC-035:90`). This breaks SPEC-008:78, which says the index status must match the file status.
   - The TDD Version History stops at 2026-08-27. Six specs changed after that: SPEC-002 (09-02), SPEC-003, SPEC-009 and SPEC-037 (09-08), SPEC-013 and SPEC-014 (08-30). Tickets CDT-230…245 appear in the specs but not in the index.
   - The history rows are out of date order: 07-31 sits after 08-06 (`TDD.md:61`), 08-16 after that, 07-23 before 07-14 (`:109`), and 08-22 is last (`:119`).
2. **The deprecated and removed-at-v1.1 surfaces are still written as live requirements.** CHANGELOG `:537/:576` says the v1.1 stubs were deleted, but these lines still require them:
   - `SPEC-005:24`: `commands/init-team.md` MUST be a deprecation stub.
   - `SPEC-014:44`: `commands/fix-ticket.md` and `skills/fix-ticket/SKILL.md` MUST be deprecation stubs. The command file is gone, and the skill file is a 355-line live backend.
   - SPEC-028 M1 (`:35`) and Tests 9, 11, 12 (`:106-109`) require `commands/fix-ticket.md` and `docs/commands/fix-ticket.md`, and README listing `/fix-ticket`. None of these exist, and `SPEC-028:8` itself says "removed at v1.1".
3. **Status is stale in both directions.**
   - DRAFT but fully implemented, with passing test suites: SPEC-031 (escalation-gate-test 40/40), SPEC-033 (autopilot 311/311), SPEC-034 (bug-hunt 206/206), SPEC-036 (transcript-mirror suites), SPEC-037 (model-map suites, all passing). ACTIVE or APPROVED specs cite them as normative: SPEC-015 depends on SPEC-031, and SPEC-003:22 depends on SPEC-037 F3/F6.
   - APPROVED but 0 of their Validation boxes checked: SPEC-012 (0/19), SPEC-014 (0/21), SPEC-015 (0/16). SPEC-008:66 defines APPROVED as "Validation checkboxes complete".
   - `SPEC-001:3` has status "ACTIVE — implemented in v0.15.0", which breaks the one-plain-word rule at SPEC-008:55.
   - SPEC-028 is DEPRECATED but says its "MUSTs remain authoritative" (`:12`). That is not what SPEC-008 means by DEPRECATED ("superseded; retained for history").
4. **SPEC-033 fails the spec format check.** It has no `## Test` and no `## Validation` section. `bash skills/spec-tooling/check-format.sh specs/core/SPEC-033-autopilot-policy.md` exits 1; it is the only one of the 37 that fails. Neither CI nor `/release` runs check-format over `specs/core/*`. Only bug-hunt/test.sh and audit/test.sh call it, each for its own spec.
5. **Some spec acceptance criteria are failing right now.** None of these tests run in CI.
   - SPEC-018 Test 39: `commands/handoff.md` must be ≤ 12000 bytes. It is 12096 bytes, so `detached-stub-test.sh` fails on AC1.
   - SPEC-009/017 `router-static-test.sh` T10 fails: `skills/orchestrate/steps/02-scope.md:6` mentions `ORCH_TIER` in prose.
   - SPEC-012 `scheduled-retro-test.sh` fails: it greps `commands/retro.md` for a "command-name" pattern the file no longer contains.
   - These failures probably come from the environment (running as root, or no generated hooks), not the code: `metrics/test.sh` #4 "unwritable", the transcript-mirror M4 append-fail cases, 2 cases in release-train `test-integration.sh`, `friction-capture-test.sh` (needs a generated `.claude/hooks`), and `council/test-workflow-static.sh`, which exits 1 at `workflow-probe.sh` even though every check prints OK.
6. **CI runs only 9 of about 75 test scripts** (`.github/workflows/smoke.yml:14-72`). `/release` runs only `plugin-dir-test.sh` (`skills/release/SKILL.md:341`). So most spec "Test" sections are not enforced by anything.

### Spec inventory
"Impl" means the implementation is present. Wherever a finding names a missing path, I confirmed it with ls.

| Spec | Purpose | Declared status | Impl | Verdict | Findings |
|---|---|---|---|---|---|
| 001 | Per-agent directives + `/adjust-agent` | ACTIVE — implemented in v0.15.0 | Yes | Minor drift | Status format breaks SPEC-008 (`:3`). `:18/:76/:89` exclude only project-init and distiller from directives; SPEC-003:19 also excludes finder, debugger and council-judge, so this list is incomplete. `:129` still says "init-team". |
| 002 | Plugin manifest, settings, hooks, plugin-dir.sh | ACTIVE | Yes | Drift | `:268` resolution-site table cites `skills/transcript-parse/freshness-gate.sh`, which never existed (CHANGELOG:378 fixed the code, not the spec). |
| 003 | 12-agent roster, model/effort tier table (the SoT) | ACTIVE | Yes | OK | Tier table (`:26-39`) matches every `agents/*.md` `model:`/`effort:`, and finder/debugger tools match `:104`. `:19` "init-team bootstrap entry" uses a retired name. TDD row omits finder, debugger and council-judge from coverage. |
| 004 | SQLite memory store and migrations | ACTIVE | Yes | OK | `test-migrate.sh` passes 38/38 but is not in CI. |
| 005 | `/setup` bootstrap | ACTIVE | Yes | Stale | `:24` requires the `commands/init-team.md` stub, which is gone. `:7/:137` still say `skills/demo/SKILL.md` "is now a deprecation stub"; it is gone. `:13` still names `/init-team`. The TDD row has the same stale paths. |
| 006 | Memory search, `/recall` | ACTIVE | Yes | Untested | No test script. TDD row calls memory-recall "(stub)", but SPEC-006:7 says it is live again. |
| 007 | Distiller, `/memory distill/config/stats` | ACTIVE | Yes | Untested | No test script. |
| 008 | Spec format/taxonomy, `/spec` | ACTIVE | Yes | Not enforced | Its own index rules (`:76-79`) and format rules are violated elsewhere (SPEC-033, SPEC-035, SPEC-001). check-format is not gated across the spec set. The category dirs at `:22` (`specs/performance/` etc.) don't exist; they are optional. |
| 009 | Kickoff, orchestrate, brainstorm, standup, wrap, backlog | ACTIVE | Yes | Failing test | router-static T10 fails. Shares ownership of `autopilot/parse-flags.sh` and `loc-exclude.sh` with SPEC-033 (both Covers lines). `:490` names `/fix-ticket`. |
| 010 | review-and-commit, `/release` gates, docs-drift | ACTIVE | Yes | OK | Missing paths at `:128/:164/:171` are deliberate negative or fixture examples. |
| 011 | `/memory validate` + reconcile | ACTIVE | Yes | Gap | `:29` "MUST use Opus for the reviewer agent", but neither `skills/validate-memory/SKILL.md` nor `commands/memory.md` pins a model. |
| 012 | `/retro` friction gate | APPROVED | Yes | Stale status, failing test | 0/19 Validation boxes checked. `scheduled-retro-test` fails. Claims `skills/transcript-parse/` alongside SPEC-018 and SPEC-036. |
| 013 | `/council` tribunal | ACTIVE | Yes | Drift | `:6` Covers the nonexistent `commands/council --blind.md`. Static test exits 1. |
| 014 | `/debug` workflow | APPROVED | Yes | Stale | `:44/:206` require the `commands/fix-ticket.md` stub (gone) and a fix-ticket skill stub (it is a live backend). `:64/:69/:70/:176/:244` require `/update-spec`, which is now `/spec update` in `skills/debug/SKILL.md:511`. 0/21 Validation boxes checked. |
| 015 | `/refactor` | APPROVED | Yes (prose skill) | Stale status | No Covers line. 0/16 Validation boxes checked. APPROVED yet depends on SPEC-031, which is DRAFT. No executable test. |
| 016 | `.worktrees/<slug>` + worktree-lib | ACTIVE | Yes | Minor | `:7/:92/:223` cite `skills/demo` as a stub; it is gone. `worktree-lib-test` 60/60 passes but is not in CI. |
| 017 | CI watch + task DAG | ACTIVE | Yes | Failing test | Shares router-static T10. Five specs claim `orchestrate/steps/*` (009, 017, 026, 037, and 019 though deprecated). |
| 018 | `/handoff` STM packet | ACTIVE | Yes | Failing AC | Test 39 byte cap is exceeded. No Covers line in the file; the TDD row (`:24`) has grown into a running changelog. No Cross-references section. |
| **019** | OpenCode local offload | DEPRECATED | **None** | Prune | No offload code anywhere: `skills/local-agent/` and `commands/local-do.md` were deleted at v1.1 (CHANGELOG:583). The only `opencode` hits are `install.sh`'s install target. Covers (`:7`) and the TDD row list 4 missing files. `:369` says the references in AGENTS.md were excised, but `AGENTS.md:271` still cites SPEC-019. The `skills/release/SKILL.md:155/171` worked example also cites it. Its history doesn't record the v1.1 deletion. |
| 020 | `/craft-loop` | ACTIVE | Yes | Untested | No test script. 1/1 Validation box checked. |
| 021 | Skill-bash lint C1–C5 | ACTIVE | Yes | OK | Covers uses bare relative names (`lint.py`), which a script can't check. |
| 022 | `/doctor` | ACTIVE | Yes | OK | doctor/test passes 102/102 but is not in CI. Covers is at line 132, the bottom of the file. |
| 023 | Release-train queue | ACTIVE | Yes | Env-flaky | `test-integration.sh` fails 2 cases. |
| 024 | Seed packs | ACTIVE | Yes | Drift | Covers (`:118`) has the bogus path `commands/setup team.md`. TDD row cites `commands/init-team.md`, which is gone. |
| 025 | `/epic` | ACTIVE | Yes | Minor | `:11/:61/:203/:233` say `/standup`; the live form is `/status standup`. |
| 026 | Outcome ledger + advisory routing | ACTIVE | Yes | Minor | Covers (`:143`) still says "planned/landing with CDV-185". Uses `/metrics` (`:25/:79/:128/:153`); the live form is `/status metrics`. A `local` enum is kept with no producer. |
| **027** | `/incident` war room | DEPRECATED | **None** | Prune | All 6 covered files are absent. The only residue is `.gitignore:26-27` (`.claude/incidents/`) and the devops incident posture (`agents/devops.md:61`). History `:98` says "replaced by stubs"; they were deleted at v1.1 and that isn't recorded. |
| 028 | `/debug ticket` pipeline | DEPRECATED | Yes (`skills/fix-ticket`) | Contradictory | DEPRECATED yet authoritative. Required stubs/docs are missing (see headline 2). The protocol should be folded into SPEC-014, which `:12` says happens "until v1.1"; v1.1 has passed. |
| 029 | Debug reopen + surface gates | ACTIVE | Yes | Untested | No test script for `theme-status.sh`. |
| 030 | Smoke harness | ACTIVE | Yes | OK | Runs in CI. |
| 031 | Escalation gate + universal worktree + PreToolUse hook | DRAFT | Yes | Stale status | Implemented and tested but not promoted. |
| 032 | CI linter parity | ACTIVE | Yes | Stale text | `:69-78` expects "three distinct checks" (CI now has 9 jobs) and "D1–D8" (docs-drift now has D1–D10). |
| 033 | Autopilot policy | DRAFT | Yes | Format failure | No Test or Validation section. Covers omits `end-state.md`, `resume-state.sh`, `ship-gate-council.md`, `test.sh`. |
| 034 | `/bug-hunt` | DRAFT | Yes (stages 1–4) | Stale status | Tests 206/206 pass. |
| 035 | `/audit` | ACTIVE | Yes | Index mismatch | TDD says DRAFT. Version History sits mid-file, before SHOULD (`:85`). |
| 036 | Transcript mirror | DRAFT | Yes | Stale status | Claims `transcript-parse/hosts.py` (overlaps SPEC-012). Env-flaky M4 test. |
| 037 | Model map | DRAFT | Yes | Stale status | Tests all pass. It is the de facto SoT for runtime routing. |

**Numbering and index:** SPEC-001 to SPEC-037 are contiguous with no orphans; the old SPEC-025/028 collision was resolved (`TDD.md:103`). Docs examples reuse real IDs for made-up consumer specs: `docs/commands/kickoff.md:38` (SPEC-007-csv-export), `docs/runbooks/orchestrate.md:102` (SPEC-026), `docs/runbooks/idea-to-plan.md:94` (SPEC-031). AGENTS.md and README cite no spec that doesn't exist. Two user-facing commands have no spec at all: `commands/mode.md` (with skills focus/blunt) and `commands/tdd-gate.md`; skills/domain-glossary has none either.

### Cross-spec contradictions
- **Fix-ticket:** SPEC-014:44 says the skill is a stub; SPEC-028:8 says the command was removed and the skill is a backend; SPEC-037 Covers `skills/fix-ticket/SKILL.md` as a live spawn surface; the code is a live backend.
- **Directive exclusions:** SPEC-001:18 excludes 2 agents, SPEC-003:19 excludes 5. AGENTS.md "Per-Agent Directives" also lists only 2.
- **Normative dependencies on DRAFT specs:** SPEC-015 (APPROVED) depends on SPEC-031 (DRAFT); SPEC-003 (ACTIVE) depends on SPEC-037 (DRAFT).
- **Several specs claim the same files, with no ownership map:**
  - `skills/transcript-parse/`: SPEC-012 (owner), SPEC-018, and SPEC-036 (hosts.py and its test).
  - `autopilot/parse-flags.sh` and `loc-exclude.sh`: SPEC-009 and SPEC-033.
  - `init-orchestration` hook templates: SPEC-002, SPEC-005 and SPEC-031.
  - `orchestrate/steps/*`: SPEC-009, SPEC-017, SPEC-026 and SPEC-037.
- **Model tiers:** no conflicts. The SPEC-003 table, AGENTS.md roster and frontmatter agree. SPEC-011:29's Opus reviewer is unimplemented rather than contradicted.
- **Worktree path layout:** consistent everywhere (`.worktrees/<slug>`).

### AC traceability gaps
- **No executable test at all:** SPEC-006, 007, 015, 020, 029 (theme-status.sh), and SPEC-028 (only a `node --check` AC).
- **Tests exist but no gate runs them** (neither CI nor `/release`): 016, 017, 018 (about 20 scripts), 022, 023, 025, 026, 031, 033, 034, 035, 036, 037, council, handoff.
- **Test scripts never cite spec or AC IDs** (grep for `SPEC-0NN` across 76 scripts finds 0 hits): SPEC-006/007/008/015/016/020/028/029/032. So there is no machine-checkable link from AC to test. SPEC-018 is the only one with a numbered Test→script map, and that map lives in the TDD Coverage column.
- **Specific:** SPEC-011:29 has no implementation. SPEC-018 T39, SPEC-009/017 T10 and SPEC-012 scheduled-retro are failing now (headline 5).

### Enhancement proposals
1. **Gate spec format and index consistency (P0, effort S).** Stale status and a format failure went unnoticed because nothing enforces SPEC-008. Add a `spec-lint` job to smoke.yml and to `/release`. It runs check-format.sh on every `specs/core/*.md` and a new `check-index.sh` that asserts:
   - index status equals file status, and the status is one plain word;
   - every file is in the index;
   - every Covers path exists (expanding `{a,b}`), except paths explicitly marked historical;
   - Version History is in date order;
   - an APPROVED spec has every Validation box checked.
2. **Run every test script in CI (P0, effort S–M).** 65 or more suites never run, and 3 acceptance criteria are failing right now. Add `tools/run-all-tests.sh`, which finds `*test*.sh` files, with an explicit env-skip list for tests that need root or hooks. Make it a CI job and call it at `/release`. Fix T39, T10 and scheduled-retro first.
3. **Machine-checkable AC↔test traceability (P1, effort M).** Adopt a convention: every MUST/AC carries an ID (`SPEC-018/T39`), and each test assertion prints or tags that ID (`# covers: SPEC-018/T39`). A checker reports ACs with no tag. Move the handoff map out of the TDD Coverage column into a `## Traceability` table inside each spec.
4. **Status lifecycle transitions checked in CI (P1, effort S).**
   - Define and enforce the transitions DRAFT→ACTIVE→APPROVED→DEPRECATED→(delete).
   - A DRAFT spec whose Covers files all exist and whose tests pass gets flagged "promote?".
   - An ACTIVE or APPROVED spec may not cite a DRAFT spec as normative.
   - DEPRECATED means no MUST is authoritative; if the protocol is still live, fold it into the host spec.
   - Then promote SPEC-031/033/034/036/037, fix SPEC-035 in the index, demote SPEC-012/014/015 to ACTIVE or check their boxes, and fold SPEC-028 into SPEC-014.
5. **Prune the dead specs (P1, effort S).**
   - Move SPEC-019 and SPEC-027 to `specs/archive/`, or leave a tombstone that keeps only Overview and History with a "deleted v1.1.0" row.
   - Drop the `.gitignore:26-27` incidents entry, and replace the `AGENTS.md:271` SPEC-019 citation with a generic bwrap exemption.
   - Strip every "one-cycle stub … removed at v1.1" MUST from SPEC-005/014/016/028.
   - Sweep live retired-command names: `/update-spec` (SPEC-014), `/standup` (SPEC-025), `/metrics` (SPEC-026), `/init-team` (SPEC-001/003/005/022).
6. **A single ownership registry (P2, effort M).** Overlapping Covers are ambiguous: transcript-parse, parse-flags, orchestrate steps. Add an `owner:` vs `cites:` distinction to Covers, or a `specs/OWNERS` path-glob→spec map, and have the checker reject two owners for one path. Add specs, or mark as unspecced, for `/mode`, `/tdd-gate` and domain-glossary.
7. **Normalize the header (P2, effort S).** Covers sits at different lines (SPEC-022:132, SPEC-023:117, SPEC-036:710) and SPEC-027 uses a variant `**Covers:**`. Require `**Covers**:` right after `**Created**`, one path per list item, repo-relative. Add Covers lines to SPEC-015/018/029.
8. **Slim the TDD index (P3, effort S).** The index rows have become changelogs (the SPEC-018 row is about 1.5 KB) and the history is missing CDT-230…245. Keep Coverage to 1–3 key paths. Generate the TDD Version History by aggregating each spec's own history rather than editing it by hand.
9. **Stop reusing real IDs in docs examples (P3, effort S).** Use obviously fake IDs such as `SPEC-9xx` in `docs/commands/kickoff.md:38`, `docs/runbooks/orchestrate.md:102` and `docs/runbooks/idea-to-plan.md:94`.
