# Review slice 02: specs (`specs/TDD.md` + `specs/core/SPEC-001..037`)

Reviewer scope: all 38 files listed in `slices/02-specs.txt`. Every file was read in full. Large files were read in chunks: SPEC-002, 009, 013, 018, 025, 031, 033, 036 and 037.
Evidence was gathered with read-only greps and path checks, and by running every `*test*.sh` under `skills/` and `tools/`: 75 suites, of which 8 exited non-zero. No repo file was modified.

## Slice summary

- **Overall health: C.** The specs are detailed and mostly accurate about behavior. The shipped code usually matches the MUSTs: 67 of 75 test suites pass, and `plugin-dir-test.sh` (189), `autopilot/test.sh` (311), `epic/test.sh` (745), skill-lint and docs-drift are all green. The spec corpus itself has drifted a lot. Status, Covers, stale references and self-contradictions are all out of date, and no mechanical gate enforces any of the rules SPEC-008 sets for spec files.
- **Risk 1: two spec gates are already violated and nothing blocks it.**
  - SPEC-018 M19 says `commands/handoff.md` must be ≤12000 bytes. It is 12096 bytes, pushed over by the v1.18.14 stanza change, and `detached-stub-test.sh` now fails.
  - SPEC-009's `--tier` T10 check (`router-static-test.sh`) has failed since v1.17.0.
  - Neither suite runs in CI or `/release`, even though SPEC-018 claims "CI enforces" the byte cap.
- **Risk 2: spec status no longer reflects reality.**
  - Five specs are DRAFT but shipped and cited as MUST by ACTIVE specs: SPEC-031, 033, 034, 036 and 037.
  - SPEC-028 is DEPRECATED but is still the "authoritative" protocol for the live `/debug ticket` pipeline.
  - SPEC-035's index row says DRAFT while the file says ACTIVE.
  - SPEC-012, 014 and 015 are APPROVED with 0 Validation boxes checked, which contradicts SPEC-008's definition of APPROVED.
- **Risk 3: specs mandate files that no longer exist.** Examples include deprecation-stub MUSTs for `commands/init-team.md` and `commands/fix-ticket.md`, a garbled `commands/council --blind.md`, `commands/setup team.md`, `skills/demo/SKILL.md` and `freshness-gate.sh`. There are about 30 such stale references in the spec bodies and 9 more in the TDD index Coverage column.
- **Risk 4: contradictions between specs and code.**
  - SPEC-009:197 requires `INSERT OR REPLACE`. SPEC-004 and the wrap-ticket skill require append-only writes.
  - SPEC-037 declares its effort half superseded but keeps it as MUST, and `/adjust-agent --effort` still ships as a control that does nothing.
  - SPEC-033's `--autopilot=master` lands on master without a release. AGENTS.md says master moves only at epic seal or through one `/release` fold.
- **Risk 5: nothing checks spec format or index integrity.** `skills/spec-tooling/check-format.sh` exists but is not wired into CI or `/release`, and SPEC-033 fails it (no Test or Validation section). Version History tables are unsorted in 20 of 38 files, and the TDD Version History is missing roughly 10 recent ticket rows.
- **What is good:**
  - Numbering runs SPEC-001..037 with no gaps or duplicates.
  - An index exists (`specs/TDD.md`), every spec file is listed in it, and there are no orphan files.
  - Every current spec passes `check-format.sh` except SPEC-033.
  - The model/effort tier table in SPEC-003 matches all 12 agents' frontmatter exactly.
  - SPEC-002's stanza byte-identity gate (C5) and harness pass.

## Per-file review

| File | Lines | Purpose (short) | Status | Verdict | Findings |
|---|---|---|---|---|---|
| specs/TDD.md | 119 | Spec index + global version history | n/a (index) | Issue | :41 SPEC-035 listed DRAFT but the file says ACTIVE, which violates SPEC-008:79. Coverage cells cite deleted or renamed files: :11 `commands/init-team.md (stub)`, demo; :12 memory-recall "(stub)", which was restored per CDT-52; :17 `skills/memory validate (stub)` (a broken path; the real path is `skills/validate-memory`); :25/:33 local-agent and incident files; :30 init-team; :34 fix-ticket stubs. :9 SPEC-003 coverage omits finder, debugger and council-judge. Version History (:47-119) is not in date order, and there are no rows after 2026-08-27 (CDT-213/230/232-234/242-245, v1.18.14). 12 index titles are abbreviated relative to the file titles (cosmetic). |
| SPEC-001-per-agent-directives.md | 130 | Directives + retro A/B trial loop | ACTIVE | Minor | :18 "MUST NOT load directives for project-init or distiller" omits finder, debugger and council-judge (SPEC-003:19 covers them). The same omission is in AGENTS.md. :95-101 Validation boxes unchecked for shipped behavior. Trial-loop helpers and tests exist and are consistent. |
| SPEC-002-plugin-infrastructure.md | 383 | Manifest, hooks, PDH stanza, plugin-dir.sh | ACTIVE | Issue | :139 describes the stanza as 4 tiers, but the canonical block (:136, changed in v1.18.14) has 5 arms (new `_pr='${CLAUDE_PLUGIN_ROOT}'` token arm), and there is no Version History row for v1.18.14. :268 row 1 cites a non-existent `skills/transcript-parse/freshness-gate.sh`. :377 says "bumps all three version files", which contradicts :17 (version pair). :21/:325 Validation runs a `.claude/hooks/task-completed.sh` that is untracked since CDT-54. :329 Open question from 2026-03 still open. Version History unsorted (:343-373). About 40% of the file is ticket forensics (CDT-233/234 narratives, :141-226), which hurts readability. The stanza gate itself is verified (plugin-dir-test PASS=189). |
| SPEC-003-agent-role-system.md | 151 | 12-agent roster, tier table, role boundaries | ACTIVE | Minor | Tier table (:26-39) matches all 12 `agents/*.md` frontmatter. The tools rule for finder and debugger matches. :7 Covers omits council-judge, distiller and project-init despite the "12-file roster". :112 "git diff … commands/ (empty)" is a ticket-scoped check, not a durable test. Version History unsorted. |
| SPEC-004-memory-storage.md | 119 | Memory write path, migrations | ACTIVE | Minor | :11 Overview says "(v1→v2 tiered distillation)", but the schema is now v4 (schema.sql:30). :82 "no .sh test harness exists in this repo" is false (`skills/memory-store/test-migrate.sh`, `test-seed-pack.sh`). :7 Covers omits the test scripts. Version History unsorted. |
| SPEC-005-team-bootstrap.md | 212 | /setup dispatcher, team/project/orch bootstrap | ACTIVE | Issue | :24 MUST that `commands/init-team.md` is a deprecation stub "removed at v1.1": the file is gone, so the MUST is dead. :7/:137/:193 Covers `skills/demo/SKILL.md` (does not exist). :136-144/:152/:161/:176 struck-out demo MUSTs kept "one cycle" long after expiry. :60 says TDD.md seeds "EXAMPLE status", but scaffold emits DRAFT (`skills/scaffold-project/SKILL.md:282-284`), and EXAMPLE is not in SPEC-008's taxonomy. |
| SPEC-006-memory-retrieval.md | 104 | Memory search, tiered read, /recall | ACTIVE | OK | Limits (20/10/200 chars, `(1-distance)*100`) match `skills/memory-recall/SKILL.md`. Version History unsorted. Minor: :88-89 open questions are old. |
| SPEC-007-memory-distillation.md | 107 | Distiller, /memory distill/config/stats | ACTIVE | OK | `--force`, `--status`, protected keys and the 1-9999 threshold all verified in `commands/memory.md:105-221`. Version History unsorted. |
| SPEC-008-spec-management.md | 385 | Spec format, taxonomy, /spec tooling | ACTIVE | Issue | The normative rules at :78-79 (index Status must match the file; all specs listed) and :31/:61 (APPROVED = Validation complete) are violated in-repo and not mechanically enforced: `check-format.sh` is not in CI or `/release`. :120 `/spec list` "highlight NEW" uses a retired status. Version History unsorted. |
| SPEC-009-ticket-workflow.md | 491 | brainstorm/kickoff/orchestrate/status/wrap/backlog | ACTIVE | Issue | :197 "MUST use `INSERT OR REPLACE`" contradicts SPEC-004:20 (append-only) and `skills/wrap-ticket/SKILL.md:224-226`, which explicitly rejects it. :405/:433 require `router-static-test.sh` to pass, but it fails (T10, `steps/02-scope.md:6` bare `ORCH_TIER`, introduced by 11da8af / v1.17.0). :158 cites SPEC-037 M27 effort map, which SPEC-037 declares superseded (the host has no effort param). :489 "cross-spec follow-up required" is stale. The six-key JSON (:99) and `--max-loc` are verified (autopilot test 311/0). Version History unsorted. |
| SPEC-010-code-review-release.md | 221 | review-and-commit, /release gates | ACTIVE | Minor | :11 "all three required files" (it is a pair). :48 "Implementation … is Task 2 of CDT-54" is stale. :137 "review spawns 5 sub-agents" dates from before the council refactor. :7 Covers omits `skills/docs-drift/*` although D1-D10 are specified here. Release Steps 4.6 and 4.12 are not described. release/bump-class/docs-drift tests all pass. |
| SPEC-011-memory-validation.md | 276 | /memory validate + --reconcile | ACTIVE | OK | Covers is accurate (`skills/validate-memory/{SKILL.md,reconcile-lib.sh}` exist). :211 Validation still expects schema_version "3" alongside :218 "4" (both historical checks; minor). Version History unsorted. |
| SPEC-012-session-retrospective.md | 348 | /retro gate, ledger, trial loop, scheduled | APPROVED | Issue | APPROVED with 0 of ~20 Validation boxes checked, which violates SPEC-008:61. The M1 ledger test `skills/retro-gate/friction-capture-test.sh:8` hardcodes a tracked `.claude/hooks/friction-capture.sh`, which CDT-54 made generated and gitignored, so it fails on a clean clone. `scheduled-retro-test.sh` #4 (the S4 Filter-2 check) uses a regex that cannot match the literal in `commands/retro.md:575`, so it false-fails. Cites local-only `.claude/backlog/...` (:155) and a `.claude/plans/...` design doc. Version History unsorted. |
| SPEC-013-adversarial-council-tribunal.md | 727 | /council engine, tiering, blind path, workflow | ACTIVE | Issue | :6/:460/:653/:687 "`commands/council --blind.md` DEPRECATED stub" is a garbled global rename of `commands/blind-review.md`, and no stub exists (README:153 says deleted), so the MUST is unsatisfiable. :16 is also garbled ("absorbs the former `/council --blind`"). :714 says finder is shared with `/debug ticket`, which contradicts SPEC-003:46 (refuters stay qa). :719 claims Version History was reordered ascending, but it is unsorted (:701-727). Council tests pass except `test-workflow-static.sh`, which exits 1 in this env because `workflow-probe.sh` fails (environment-dependent, unverified). |
| SPEC-014-debug-workflow.md | 272 | /debug modes incl. ticket | APPROVED | Issue | :8/:44/:206/:253 MUST that `commands/fix-ticket.md` and `skills/fix-ticket/SKILL.md` are one-cycle stubs. The command is gone, and the skill (355 lines) is the full live protocol and says the command was "removed at v1.1". :6/:18 "full fold … deferred to v1.1" never happened (now v1.18.14). :64/:69/:70/:176/:244 name `/update-spec` (now `/spec update`). APPROVED with no Validation boxes checked. |
| SPEC-015-refactor-workflow.md | 231 | /refactor workflow | APPROVED | Minor | No `**Covers**` line and no Cross-references section. Delegates normatively to SPEC-031, which is DRAFT ("SPEC-031 governs where they conflict", :40). Tests are ordered T1-T7, T10-T12, T8, T9. APPROVED with no Validation boxes checked. |
| SPEC-016-worktree-isolation.md | 233 | worktree-lib.sh contract | ACTIVE | Minor | :140 "MUST NOT run parallel `git worktree` operations — already documented in AGENTS.md" is false: AGENTS.md has no such rule (grep "parallel" finds nothing). SPEC-023 inherits the rule too. :7/:92/:201 demo Covers and struck MUSTs. :96-124 an embedded DRAFT block inside an ACTIVE spec. Lib verified (`worktree-lib-test.sh` 60/0; git_retry, TTL and live-task guard present). |
| SPEC-017-autonomous-ci-watch-task-dag.md | 259 | CI watch loop + task DAG store | ACTIVE | OK | `*/7` cron, bucket parsing and the task-store invent policy are all verified (test-poll 7/0, task-store-test 33/0). :7 Covers omits `router-static-test.sh`, `test-poll.sh` and `task-store-test.sh`, which the TDD index lists. |
| SPEC-018-cold-session-handoff.md | 331 | /handoff STM packet pipeline | ACTIVE | Issue | M19 (:201/:228) caps `commands/handoff.md` at ≤12000 bytes "CI wc -c". It is actually 12096 bytes after v1.18.14, `detached-stub-test.sh` fails AC1, and the test is not in CI. No `**Covers**` line in the body (Covers lives only in a huge TDD index cell). Version History unsorted. Otherwise very precise, and most suites pass (assemble-quality 52/0, mirror-spine 86/0, spawn-model 21/0). |
| SPEC-019-local-agent-offload-via-opencode.md | 382 | Opencode offload (removed) | DEPRECATED | Minor | Full 382-line body retained "for one deprecation cycle" (:373), but v1.0.0 was 18 minors ago. It is written as live MUSTs with no top-of-file banner. :7 Covers deleted files, and the "one-cycle stubs" it mentions don't exist. Archive or delete. |
| SPEC-020-craft-loop-prompt-architect.md | 146 | /craft-loop program designer | ACTIVE | OK | Command, skill, template and 2 examples exist. No SHOULD or Cross-references section (optional). |
| SPEC-021-skill-bash-lint-gate.md | 132 | skill-lint C1-C5 | ACTIVE | Minor | :197/:238 "110 emissions across 26 files" (now 210 across 54). :248/:260 "exercised by one real release" still unchecked after dozens of releases. :228 Out of Scope says table monotonicity "belongs to SPEC-008's check-format.sh", but check-format.sh does not check order and SPEC-008:319-322 says order is not validated. Linter verified (0 unwaived; test 56/0). |
| SPEC-022-doctor-install-diagnostics.md | 143 | /doctor battery | ACTIVE | Minor | M4 (:35) mandates cwd-relative fix-its (`bash skills/worktree-lib.sh release <slug>`, `bash skills/transcript-mirror/transcript-sync.sh`), and `doctor.sh:733,1347,1462` implements them. In consumer projects these paths don't exist, which contradicts SPEC-016:86, SPEC-031:114 and AGENTS.md. :16/:124 "stubs until v1.1" is stale. Covers is at the bottom of the file (:132). Check id `version.triplet` is kept deliberately. doctor test 102/0. |
| SPEC-023-release-train-queue.md | 127 | Multi-branch release queue | ACTIVE | Minor | :27 cites the removed `.claude/local-agent/` as precedent. :17/M11 inherit SPEC-016's nonexistent AGENTS.md rule. M5(b) says Version History unions are "sorted by date", but most existing tables are unsorted, so a re-sort would rewrite master rows, contradicting "byte-preserving". Validation live-train boxes unchecked. `test-integration.sh` 2 FAIL ("restore dirty"), unverified, possibly env. |
| SPEC-024-memory-seed-packs.md | 127 | /memory export + seed import | ACTIVE | Minor | :118 Covers "`commands/setup team.md`" (garbled rename of `commands/init-team.md`; should be `commands/setup.md`). :89-91 CDT-194 Validation unchecked although tests exist (`test-seed-pack.sh:787+`). Version History unsorted. |
| SPEC-025-epic-umbrella-decomposition.md | 342 | /epic decomposition, seal, sync | ACTIVE | Minor | M-numbering out of order (M1-M9, M15, M10-M14, M16). L5 (:268) "No auto-chain" conflicts in wording with M7 (:48) autopilot same-run continuation; the scope needs stating. :342 cites the PM-mandatory lesson in `skills/orchestrate/SKILL.md`, but it now lives in `steps/08-execute.md:140`. epic test 745/0. |
| SPEC-026-adaptive-agent-routing.md | 153 | Outcome ledger + advisory routing | ACTIVE | Minor | M3 task_class taxonomy has no class for the SPEC-009:48 "measurement/ML → ds" route, so ds stints can't be classified for advisory (unverified impact). SPEC-019 is still the "format exemplar" for a deleted file. metrics test 24/1: T4 "unwritable" fails, likely because the review ran as root (unverified). |
| SPEC-027-incident-war-room.md | 111 | /incident (removed) | DEPRECATED | Minor | Orphan: cited by 0 non-spec files. Covers 6 deleted files. `.gitignore` still carries `.claude/incidents/`. Validation says "promoted to ACTIVE" (unchecked). Delete or archive. |
| SPEC-028-fix-ticket-workflow.md | 137 | /debug ticket premise→implement→refute | DEPRECATED | Major | DEPRECATED yet :10 "protocol MUSTs below remain authoritative … until v1.1 full merge", and v1.1 has long passed. M6 (:43) mandates an ic5 premise agent, which contradicts SPEC-014:48, SPEC-003:47 and code (debugger). M1/T9/T11/T12 require `commands/fix-ticket.md`, `docs/commands/fix-ticket.md` and README listing of `/fix-ticket`, which contradicts README:153 ("deleted stubs"). M11 bans "README version/changelog sections" (the changelog moved to CHANGELOG.md). This is the live contract for a shipped pipeline and it is wrong. |
| SPEC-029-debug-reopen-and-surface-gates.md | 203 | Debug reopen detector, surface matrix | ACTIVE | Minor | Uses a `## Covers` section instead of the header line. The `theme-status.sh` helper has no automated test (`skills/debug/` has none). Validation items like "check-format passes" are unchecked though the check passes. Evidence points to local `.claude/plans`. |
| SPEC-030-smoke-harness-gate.md | 145 | tools/smoke harness gate | ACTIVE | Minor | Status ACTIVE, but Version History has only the DRAFT row, and the Validation "promoted DRAFT→ACTIVE" box plus all Test boxes are unchecked. :103 cites "docs-drift's D1 check" for cmd-index (it is D2). :70 cites worktree-lib-test hardcoded /tmp (possibly stale). |
| SPEC-031-escalation-gate.md | 576 | Escalation gate + PreToolUse hook | DRAFT | Issue | Shipped: 24 references in the init-orchestration template, `escalation-gate-test.sh` exists, and the `.gitignore` entry is present. SPEC-015/014/009/016 cite it normatively, yet it is DRAFT with 0 of 24 Validation boxes checked and no promotion row. :123 says AGENTS.md shows the cwd-relative form, but that was already fixed. Version History is placed after Cross-references. |
| SPEC-032-ci-linter-parity-gate.md | 104 | CI jobs for skill-lint/docs-drift | ACTIVE | Minor | :14/:73 "D1–D8" (docs-drift is now D1-D10). Not cited by any non-spec file. Implementation matches (`smoke.yml` separate jobs; both SKILL.md files mention smoke.yml). |
| SPEC-033-autopilot-policy.md | 1019 | Shared autopilot policy (gates/BCs/cards) | DRAFT | Major | Fails `check-format.sh` (missing `## Test` and `## Validation`). DRAFT while fully implemented (autopilot test 311/0) and MUST-cited by ACTIVE SPEC-009:54-56. :38-41 "writes only the contract; no workflow file is edited" is stale. :628-639 "latent-doc correction … currently instructs" was already applied (`ship-gate-council.md:148-151`). M2/N3a land-no-release (`--autopilot=master`: commit and push to baseline, no `/release`) conflicts with AGENTS.md Release Rules ("Master moves only at epic seal / one /release fold"). Version History unsorted. At 1019 lines it is the largest spec. |
| SPEC-034-bug-hunt-workflow.md | 487 | /bug-hunt 4-stage workflow | DRAFT | Issue | DRAFT though stages 1-4 shipped. T1 (:350) and `skills/bug-hunt/test.sh` assert the literal `Status: DRAFT`, so promoting the spec would break a test. Tests T1-T26 are greps of the spec's own text (self-referential), not behavior. M18/:171 attribute `/orchestrate` to SPEC-017, but the owner is SPEC-009. All Validation boxes unchecked. |
| SPEC-035-context-audit.md | 107 | /audit instruction-stack inventory | ACTIVE | Minor | The file says ACTIVE and the index says DRAFT (mismatch). Covers and SHOULD are placed after Version History. The 30KB SKILL WARN (M8) would fire on 8 plugin SKILLs (up to 135KB: bug-hunt, init-orch, epic, council), which is an observation rather than a defect. |
| SPEC-036-transcript-mirror.md | 882 | Transcript mirror recorder/sync/tail/overlay | DRAFT | Issue | DRAFT but shipped (v1.13.0+ minors), and ACTIVE SPEC-018 M3f and SPEC-022 M2h depend on it. Validation "Status promoted to ACTIVE after land" is unchecked. The `transcript-mirror/test.sh` M4 append-fail cases (3) fail in this environment, probably because root ignores chmod (unverified). Otherwise internally consistent. |
| SPEC-037-per-agent-model-map.md | 596 | Model map resolver + (superseded) effort map | DRAFT | Major | Self-contradictory. The effort half is declared superseded (:22-24, F1), yet M17/M18/M20/M21/M27/M29 still MUST it. M27 is not marked superseded, SPEC-009:158 still relies on it, and `/adjust-agent --effort` ships (19 mentions in `commands/adjust-agent.md`), which is the "control that silently does nothing" its own Option A (:82-87) forbids. M18 says `list` prints "the 8 M8 names" (:300/:318/:526), but M8 is 10 names (:143-157, test :557, `write-model.sh:124`). Validation :567 insists it stay DRAFT. |

## Findings

1. **P1: Two spec gates are violated by shipped code, and nothing runs the tests that would catch it.**
   - **Evidence:**
     - `wc -c commands/handoff.md` gives 12096. SPEC-018:201 requires ≤12000, and :228 claims "CI enforces the 12000-byte command cap". `skills/handoff/detached-stub-test.sh` prints `FAIL: AC1 commands/handoff.md is 12096B (cap 12000)`. The regression came from v1.18.14 (60777e7, stanza +1 arm).
     - `skills/orchestrate/router-static-test.sh` prints `FAIL: T10 02-scope.md bad-form`, caused by the bare `ORCH_TIER` mention at `skills/orchestrate/steps/02-scope.md:6` (from 11da8af, v1.17.0). SPEC-009:405 and :433 require the test to pass.
     - Neither suite is in `.github/workflows/smoke.yml` (9 jobs) or in `/release`.
   - **Fix:** Trim `commands/handoff.md` below 12000 bytes, for example by dropping the stanza comment line per SPEC-002 Q3's retention rule. Reword `02-scope.md:6` so it does not name `ORCH_TIER`. Add a CI job that runs every `*-test.sh` / `test*.sh` that a spec cites, or at least the handoff and orchestrate static suites.

2. **P1: SPEC-028 is DEPRECATED but is still the authoritative and incorrect contract for the live `/debug ticket` pipeline.**
   - **Evidence:**
     - SPEC-028:10 says "protocol MUSTs below remain authoritative … until v1.1 full merge into SPEC-014" (the repo is at v1.18.14).
     - M6 (:43) requires an ic5 premise agent, but SPEC-014:48, SPEC-003:47 and the code (`skills/fix-ticket/SKILL.md` "premise verify (debugger)") use `debugger`.
     - M1, T9, T11 and T12 require `commands/fix-ticket.md` and `docs/commands/fix-ticket.md`, which do not exist. README:153 lists `fix-ticket` among the "deleted stubs".
   - **Fix:** Fold the M6-M30 protocol into SPEC-014 § ticket mode, correcting the premise agent to debugger and dropping the stub MUSTs. Then mark SPEC-028 superseded-by-014, or delete it.

3. **P1: Spec lifecycle status is unreliable across the corpus.**
   - **Evidence:**
     - SPEC-031, 033, 034, 036 and 037 are DRAFT but shipped, and ACTIVE specs rely on them normatively: SPEC-009:54 cites SPEC-033 M15, SPEC-015:40 says "SPEC-031 governs", SPEC-018 M3f depends on SPEC-036, and SPEC-022 M2i depends on SPEC-037.
     - The TDD index has SPEC-035 as DRAFT and the file has ACTIVE, which violates SPEC-008:79.
     - SPEC-012, 014 and 015 are APPROVED with no checked Validation boxes, which violates the definition at SPEC-008:61.
     - SPEC-030 is ACTIVE with no promotion row.
   - **Fix:** Do one status reconciliation pass: promote the shipped DRAFTs (or explicitly record why they stay DRAFT), fix the index, and demote APPROVED to ACTIVE where Validation is not complete. Add a mechanical check (Finding 4).

4. **P1: SPEC-008's rules for spec files are not enforced mechanically.**
   - **Evidence:**
     - `skills/spec-tooling/check-format.sh` is not referenced from `smoke.yml`, `skills/release/SKILL.md` or `tools/smoke`.
     - SPEC-033 fails it ("missing ## Test section, ## Validation section").
     - docs-drift explicitly excludes spec format (SPEC-010 D8), and index↔file status parity (SPEC-008:78-79) is only checked by the LLM-driven `/spec check`.
   - **Fix:** Add a `spec-lint` CI and `/release` step that runs `check-format.sh` over `specs/core/*.md` and a small index-parity checker. The checker should confirm every file is indexed, statuses match, Covers paths exist (with an allowlist for deprecated specs), and Version History dates are monotonic.

5. **P2: About 30 references in spec bodies point to files that do not exist.**
   - **Evidence:**
     - SPEC-005:24 (MUST `commands/init-team.md` stub) and :7/:137 (`skills/demo/SKILL.md`).
     - SPEC-014:8/44/206/253 (`commands/fix-ticket.md` stub).
     - SPEC-013:6/460/653/687 (`commands/council --blind.md`, a garbled rename of `commands/blind-review.md`).
     - SPEC-024:118 (`commands/setup team.md`).
     - SPEC-016:7/92 (demo).
     - SPEC-002:268 (`skills/transcript-parse/freshness-gate.sh`).
     - TDD.md:11/12/17/30/34.
     - The full list is in [`evidence/spec-missing-paths.txt`](../evidence/spec-missing-paths.txt) (103 raw hits, many of them intentional examples).
   - **Fix:** Remove the expired stub MUSTs, correct the garbled renames, and re-run a path-existence check (see Enhancement E1).

6. **P2: SPEC-009 contradicts SPEC-004 and the wrap-ticket code on the memory write mode.**
   - **Evidence:** SPEC-009:197 says "MUST use `INSERT OR REPLACE` when writing back to DB memory". SPEC-004:20 says append-only. `skills/wrap-ticket/SKILL.md:224-226` says "`INSERT OR REPLACE` would just append a duplicate every time. Append-only is correct".
   - **Fix:** Replace SPEC-009:197 with "MUST append (SPEC-004 write path)".

7. **P2: SPEC-037 contradicts itself, and it ships a control that has no effect.**
   - **Evidence:**
     - :22-24 and F1 say the effort half (M22-M29) is superseded because the Agent tool has no `effort` param. Yet M17, M18, M20, M21 and M29 remain MUST, and M27 is not marked superseded.
     - SPEC-009:158 still cites M27.
     - `commands/adjust-agent.md` has 19 `--effort` mentions, and `steps/08-execute.md` has 4.
     - M18 says `list` prints "8 M8 names" (:300/:318/:526), but M8 has 10 (:143, `write-model.sh:124`).
   - **Fix:** Retire the effort surface (resolver `--effort`, `set-effort`, `/adjust-agent --effort`, spawn prose) per Option A, mark M22-M29 superseded, and update the counts from 8 to 10.

8. **P2: `--autopilot=master` (SPEC-033) conflicts with the plugin-wide ship rule in AGENTS.md.**
   - **Evidence:** SPEC-033 M2 (:87-107) and N3a (:937-944) define land-no-release: squash, commit, and non-force push the baseline, with no `/release`. AGENTS.md "Ship / land" says "Master moves only at epic seal / one `/release` fold." SPEC-010 H1-H12 only checks tags, so an untagged land passes ship-history.
   - **Fix:** Pick one rule. Either scope the AGENTS.md rule to epic children, or require `--autopilot=master` to be refused on the default branch. Then cross-reference the choice from both documents.

9. **P2: SPEC-022 M4 requires cwd-relative fix-it commands that fail in consumer projects.**
   - **Evidence:** SPEC-022:35 lists `bash skills/worktree-lib.sh release <slug>` and `bash skills/transcript-mirror/transcript-sync.sh`, and `skills/doctor/doctor.sh:733,1347,1462` emits them. SPEC-016:86, SPEC-031:114 and AGENTS.md forbid the cwd-relative form because it is "absent on a real install".
   - **Fix:** Emit install-aware fix-its (the resolved absolute path from `plugin-dir.sh`, or the `/worktree release <slug>` command), and amend M4.

10. **P2: Some spec-cited test suites fail regardless of environment.**
    - **Evidence:**
      - `skills/retro-gate/friction-capture-test.sh:8` requires `$ROOT/.claude/hooks/friction-capture.sh`, but live hooks are generated and gitignored (SPEC-002:13, SPEC-005:74-77), so it fails on a clean clone. The SPEC-012 M1-M7 ledger test is therefore not runnable.
      - `skills/retro-gate/scheduled-retro-test.sh:48` regex `command-name.*/[a-z:-]*retro` cannot match the literal `/[a-z:-]*retro` at `commands/retro.md:575`, so it false-fails (SPEC-012 S4).
      - Environment-dependent failures, not verified: `metrics/test.sh` T4, `transcript-mirror/test.sh` M4 ×3, `release-train/test-integration.sh` ×2, and `council/test-workflow-static.sh` (workflow-probe).
    - **Fix:** Have `friction-capture-test` extract the hook body from the init-orchestration template (as `plugin-dir-test` does for the stanza). Fix the scheduled-retro regex (`-F` literal match). Make the permission-based tests skip when running as root.

11. **P2: SPEC-005:60 disagrees with the scaffold code about starter spec status.**
    - **Evidence:** The spec says scaffold seeds 3 index entries "marked as EXAMPLE status". `skills/scaffold-project/SKILL.md:282-284` emits `DRAFT`. EXAMPLE is not a SPEC-008 lifecycle value.
    - **Fix:** Change the spec to DRAFT.

12. **P2: SPEC-016:140 cites an AGENTS.md rule that does not exist.**
    - **Evidence:** SPEC-016:140 says "MUST NOT run parallel `git worktree` operations — already documented in AGENTS.md", but `grep -i parallel AGENTS.md` returns nothing. SPEC-023:17 and M11 inherit the rule.
    - **Fix:** Add the rule to the AGENTS.md Worktree Protocol, or state it normatively in SPEC-016.

13. **P2: SPEC-002 describes the canonical stanza incorrectly after v1.18.14.**
    - **Evidence:** The canonical block at :136 now has 5 arms (the added `_pr='${CLAUDE_PLUGIN_ROOT}'` literal-substitution arm, CHANGELOG v1.18.14). The "Resolution order" at :139 still enumerates 4 tiers (0-3), and Version History has no v1.18.14 row. Because this spec is the C5 single source of truth, its prose now disagrees with its own canonical text.
    - **Fix:** Document tier 0b (host-substituted token), add a Version History row, and update the counts (210 emissions across 54 files).

14. **P2: Several specs carry stale ticket-era statements.**
    - **Evidence:**
      - SPEC-033:38-41 ("no workflow file edited here") and :628-639 (a "currently instructs" correction that is already applied).
      - SPEC-010:11 and SPEC-002:377 ("three version files").
      - SPEC-010:48 ("Task 2 of CDT-54") and :137 ("spawns 5 sub-agents").
      - SPEC-004:82 ("no .sh test harness exists") and :11 (v1→v2).
      - SPEC-021:197/238 (110 emissions across 26 files) and :248/:260 (unchecked "one real release").
      - SPEC-032:14 (D1-D8).
      - SPEC-030:103 (D1 should be D2).
      - SPEC-022:16/124 ("stubs until v1.1").
      - SPEC-023:27 (`.claude/local-agent/` precedent).
      - SPEC-031:123 (AGENTS.md drift already fixed).
      - SPEC-025:342 (lesson moved to `steps/08-execute.md:140`).
      - SPEC-034:18/171 (SPEC-017 named as the /orchestrate owner).
      - SPEC-014:64 and others (`/update-spec`).
    - **Fix:** Do one editorial sweep, and put a "last verified at vX.Y.Z" line in each spec header.

15. **P3: Version History tables are unsorted, and TDD.md is missing recent rows.**
    - **Evidence:** 20 of 38 files have unsorted Version History tables (per-file check), including TDD.md and SPEC-013, which at :719 claims to have been reordered ascending. TDD.md has no rows after 2026-08-27, although SPEC-002, 003, 009, 014, 018 and 037 changed on 08-30, 09-01, 09-02 and 09-08 (CDT-230/232/233/234/242/243/244/245), and CDT-213 (SPEC-012) is also absent. SPEC-023 M5(b) date-sort union assumes the tables are sorted.
    - **Fix:** Pick one ordering (newest-first matches CHANGELOG), sort once, and enforce it in spec-lint.

16. **P3: Deprecated specs have not been cleaned up.**
    - **Evidence:** SPEC-019 (382 lines) and SPEC-027 (111 lines) keep full MUST bodies "for one deprecation cycle" 18 minors after v1.0.0. SPEC-027 is cited by 0 files. `.gitignore` still has `.claude/incidents/`. SPEC-005 and SPEC-016 still carry struck-out demo MUSTs.
    - **Fix:** Move deprecated specs to `specs/archive/` (excluded from governed discovery) or delete them, and keep a one-line index row pointing at git history.

17. **P3: Structural conventions vary between specs.**
    - **Evidence:**
      - Covers placement differs: header line in most, bottom of file in SPEC-022/023/024/025/026/035/036, a `## Covers` section in SPEC-029, and missing from the body in SPEC-015 and SPEC-018.
      - Test sections mix checkbox, numbered and T-heading styles.
      - SPEC-018 and SPEC-029 have trailing double spaces on the Status line.
      - 12 index titles are abbreviated versions of the file titles.
    - **Fix:** Normalize to the SPEC-008:319 SHOULD order via the skeleton partial, and lint the Covers placement.

18. **P3: Tests are coupled to spec prose.**
    - **Evidence:** `skills/bug-hunt/test.sh` asserts SPEC-034 `Status: DRAFT` (T1), so promoting the spec breaks a test. `council/test-workflow-static.sh:246-257` greps SPEC-013 text. At least 12 suites read `specs/core/*`. SPEC-034's whole Test section (T1-T26) is greps of its own text rather than behavior.
    - **Fix:** Test behavior, not spec wording. Where a spec↔code link is needed, assert on a stable anchor ID rather than on status or phrasing.

19. **P3: SPEC-001 and AGENTS.md list only two internal agents as exempt from directives.**
    - **Evidence:** SPEC-001:18 and AGENTS.md "Per-Agent Directives" say "Does NOT apply to project-init, distiller". finder, debugger and council-judge are also non-behavioral (SPEC-003:19), and none of them load directives (verified with grep).
    - **Fix:** Reword both as "all 5 non-behavioral agents (SPEC-003)".

20. **P3: SPEC-002 is hard to read because of its size and ticket forensics.**
    - **Evidence:** 383 lines (90KB). Lines :141-226 are CDT-232/233/234 forensics, including measurement narratives and "Correcting the record", mixed in with normative MUSTs.
    - **Fix:** Move the rationale into `docs/adr/` or an appendix, and keep the normative MUSTs plus short pointers.

21. **P3: Smaller wording issues.**
    - SPEC-025 L5 ("No auto-chain") vs M7 (autopilot same-run continuation): state that L5 applies to interactive mode.
    - SPEC-003:112 has a ticket-scoped `git diff … commands/` "test".
    - SPEC-008:120 uses the retired `NEW` status.
    - SPEC-026 M3 has no task-class for ds routing (SPEC-009:48). Impact unverified.

## Enhancement proposals

- **E1: Add a `spec-lint` gate. Effort M, impact high.** It would run `check-format.sh` on every spec and confirm index↔file Status and Title parity. It would also check that every backticked `skills/|commands/|agents/|docs/|tools/` path in Covers and MUST lines exists, with an allowlist of paths quoted as examples or forbidden names. It would require Version History dates to be monotonic and the TDD Version History to contain a row for every spec Version History date. Wire it into `smoke.yml` and `/release` next to docs-drift. This mechanizes SPEC-008:78-79, which today depends only on the LLM-driven `/spec check`.
- **E2: Run every spec-cited test suite in CI. Effort S-M, impact high.** Add a `spec-tests` matrix job that runs the suites the specs name (handoff, orchestrate router-static, council, epic, autopilot, model-map, worktree-lib, ci-watch, task-store, metrics, transcript-mirror, doctor). It would have caught Finding 1 in both cases. Pair it with a root-safe skip helper for the permission-based tests.
- **E3: Do a status reconciliation pass and write down a promotion rule. Effort S, impact medium.** Promote the shipped DRAFTs (031, 033, 034, 036, 037), demote APPROVED to ACTIVE, fix SPEC-035, and add to SPEC-008 that a spec MUST be ACTIVE before an ACTIVE spec may cite it as normative.
- **E4: Archive deprecated specs. Effort S, impact medium.** Move SPEC-019, 027 and 028 (after folding 028) to `specs/archive/`. Update SPEC-008 discovery to exclude archive, and trim the TDD index rows to one line each.
- **E5: Split rationale out of the specs. Effort M, impact medium.** Move CDT forensics and dated measurements from SPEC-002, 013, 033 and 018 into `docs/adr/NNNN-*.md`, and keep specs to MUST, SHOULD, Test and Validation. This would cut the specs from about 1.1MB to an estimated 60-70% of that, and lower the token cost for agents that load specs.
- **E6: Add Covers-driven drift checks. Effort M, impact medium.** Use each spec's Covers list to flag, in `/release`, any commit that changes a covered file without touching the spec or its test. This is advisory only.
- **E7: Add a "Last verified" header field. Effort S, impact low-medium.** Add a `**Verified**: vX.Y.Z` line that `/spec check` bumps, so readers can see how stale a spec is.
- **E8: Decouple tests from spec prose. Effort S, impact low.** Replace greps of spec wording (the SPEC-034 T1-T26 style, the bug-hunt `Status: DRAFT` pin) with behavior tests or stable anchor IDs.

## Coverage attestation

- Files in `slices/02-specs.txt`: **38** (`specs/TDD.md` + `specs/core/SPEC-001` … `SPEC-037`).
- Rows in the Per-file review table: **38**. The counts match.
- Every file was read in full. Supporting evidence comes from the path-existence scan ([`evidence/spec-missing-paths.txt`](../evidence/spec-missing-paths.txt)), the `check-format.sh` run over all specs, the index↔file status and title comparison, the per-file Version History ordering check, the agent frontmatter vs SPEC-003 tier table check, and a run of all 75 `*test*.sh` suites ([`evidence/spec-cited-tests.txt`](../evidence/spec-cited-tests.txt): 67 pass, 8 fail).
