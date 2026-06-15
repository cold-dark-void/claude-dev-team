# SPEC-015: Refactor Workflow

**Status**: APPROVED
**Category**: core
**Created**: 2026-04-26

---

## Overview

Defines the `/refactor` skill — standalone proactive design improvement workflow. Owns the full understand → state-problem → characterize → implement → verify cycle for structural code changes that preserve behavior. Enforces: design problem written before any code is touched, characterization tests written when coverage is thin, and strict separation from feature and bug-fix work. Entry: `/refactor <description>` (default) or `/refactor inline <description>` (approach pre-decided by `/debug` or `/orchestrate`).

---

## MUST

### Entry & Mode Selection

- MUST support two invocation forms: `/refactor <description>` (default) and `/refactor inline <description>` (approach pre-decided — skips design proposal and approval gate)
- MUST output the approach being implemented (one sentence) before modifying any file in inline mode — even though no design problem gate or approval gate applies.
- MUST load AGENTS.md, relevant specs, recent git log, and all code in the affected area before outputting any design analysis
- MUST read any `.claude/plans/` file for the affected area if one exists
- MUST proceed without error if AGENTS.md does not exist

### Design Problem Statement (default mode only) [GATE]

- MUST state the design problem in writing before modifying any file; the statement must identify: (1) what the current design does, (2) why it is problematic (coupling, duplication, fragility, illegibility), and (3) what the refactored design achieves
- MUST NOT edit, create, or delete any file until the design problem statement exists in the session output

### Approach Decision (default mode only)

- MUST proceed without presenting options or requesting user input when there is exactly one approach that satisfies: (a) scope is bounded to the stated affected area, and (b) no two valid structural patterns (e.g., extract-function vs. introduce-abstraction) would both apply. MUST state the chosen approach in one sentence in the session output before implementing.
- MUST present 2-3 options and wait for user approval when: (a) multiple valid refactoring approaches exist, or (b) the depth or scope of the refactor is genuinely ambiguous (e.g. extract one function vs. restructure the whole module)
- MUST NOT ask the user for a decision when there is one clear, unambiguous approach

### Coverage Check (all modes) [GATE]

- MUST assess test coverage for the affected area before implementing anything
- MUST assess whether existing tests exercise the specific functions/methods being structurally changed — not merely that tests exist in the file or module. Adequate coverage means: existing tests would fail if the observable behavior of those functions changed. If this bar is not met, characterization tests are required. A file-existence check (glob for `*test*` near affected path) is an acceptable proxy when behavioral analysis is impractical.
- MUST confirm characterization tests pass on the current code before proceeding — this is the behavioral baseline (applies when branch (b) thin-coverage is taken; branches (a)/(c)/(d) have no characterization tests to confirm)
- MUST proceed without writing new tests when existing tests already adequately cover the affected behavior; note which tests serve as the baseline
- MUST complete the approach decision before beginning the coverage check. MUST NOT begin implementation until both the approach decision output and the coverage check output (or characterization tests passing) exist in the session.
- If characterization tests cannot be written (no test harness exists, behavior is entirely side-effectful, or affected code is non-deterministic), MUST emit an explicit warning documenting why tests were skipped and require explicit user acknowledgment before proceeding.
- If the affected code has no existing behavior to preserve (greenfield — new unshipped code), characterization tests are not required; MUST note this explicitly in session output and proceed.

### Implementation (all modes)

- MUST implement only structural changes — behavior must be identical before and after
- MUST NOT introduce new features, fix bugs, or change observable behavior as part of a refactor
- MUST NOT mix refactor changes with feature or bug-fix changes in the same commit or PR
- This rule applies at the commit level — a commit containing both structural refactor changes and feature or bug-fix changes is rejected regardless of which files are touched.

### Validation (all modes)

- MUST run the full test suite after implementing the refactor
- MUST confirm all characterization tests (written in the coverage check phase) still pass
- MUST confirm all pre-existing tests still pass
- MUST explicitly confirm in session output that no observable behavior was intentionally changed as part of the refactor. If any behavioral difference is detected during validation (e.g., a test that required updating its expected output), MUST stop, classify the change as a bug or feature, and refuse to proceed under the refactor workflow.
- MUST emit the self-calibration checklist with each item confirmed before any completion language:
  ```
  Self-calibration checklist:
    [ ] Design problem written before any file was edited (default mode)
    [ ] Characterization tests written and passing on original code (if coverage was thin)
    [ ] All tests pass after refactor
    [ ] No feature or bug-fix changes mixed into this refactor
  ```
- MUST NOT output any language implying completion ("done", "complete", "refactored") until the checklist passes
- In inline mode, the 'Design problem written' item MUST be marked `[N/A — inline mode]`. All other items apply in both modes.

### Blockers (all modes)

- MUST surface genuine blockers as exactly one specific question stating precisely what information is missing
- MUST NOT fabricate or guess when blocked
- MUST NOT ask multiple back-and-forth questions when one specific question covers the blocker

### Escalation (all modes)

- MUST escalate to `/kickoff` when any of the following apply: (a) affected files span more than one top-level directory or named component/service, (b) the approach requires an architectural decision (new abstraction layer, interface contract change), or (c) a tech-lead design review is warranted
- MUST pass refactor context to `/kickoff` as structured issue text: (1) design problem statement, (2) affected files/modules, (3) proposed approach, (4) why inline resolution was rejected. The canonical field layout and the shared `WHY INLINE REJECTED` vocabulary are single-sourced in the `/kickoff` accepted-handoff input contract (`skills/kickoff/SKILL.md` § Accepted escalation handoff); `/debug` and `/refactor` MUST emit that vocabulary verbatim so the two producers do not diverge.
- MUST NOT continue modifying files after triggering escalation
- MUST escalate to `/orchestrate` (via `/kickoff`) when scope is large, clear, and requires multiple agents
- MUST NOT escalate directly to `/orchestrate` without `/kickoff` first unless a `.claude/plans/` file for this work already exists

### Commit discipline (all modes)

- MUST commit the refactor as a standalone commit separate from any feature or bug-fix work
- MUST use `refactor:` commit message prefix as the default; note in session output if project conventions (AGENTS.md) specify a different format.
- MUST use a separate PR when the work is escalated or when the refactor touches multiple subsystems; otherwise a single commit in the current session branch is acceptable

---

## SHOULD

- SHOULD note which design smell the refactor addresses (duplication, coupling, fragility, illegibility) in the commit message
- SHOULD update or create specs if the refactor reveals that existing behavior was undocumented
- SHOULD suggest running `/check-specs` after the refactor to catch any spec drift introduced

---

## MUST NOT

- MUST NOT touch any file before the design problem statement exists in session output (default mode)
- MUST NOT ask the user for an approach decision when one clear path exists
- MUST NOT begin refactoring before characterization tests pass on the original code (when coverage was thin)
- MUST NOT mix refactor changes with feature or bug-fix changes
- MUST NOT claim completion before the self-calibration checklist passes
- MUST NOT change observable behavior — a refactor that changes outputs is a bug, not a refactor

---

## Test

### T1: Design problem gate
1. Run `/refactor` on a code area with an obvious design smell
2. Verify: no file is modified until the design problem statement (what/why/what-achieved) appears in session output

### T2: Single obvious approach — no options surfaced
1. Run `/refactor` on a simple extract-function refactor with one clear approach
2. Verify: skill proceeds without presenting options or waiting for user input

### T3: Ambiguous scope — options presented and approval required
1. Run `/refactor` on a module where refactor depth is genuinely ambiguous (extract one function vs. full restructure)
2. Verify: skill presents 2-3 options and waits for user approval before proceeding

### T4: Thin coverage — characterization tests written first
1. Run `/refactor` on a code area with no or minimal test coverage
2. Verify: characterization tests are written and confirmed passing on the original code before any refactor changes
3. Verify: characterization tests still pass after refactor

### T5: Good coverage — no new tests written
1. Run `/refactor` on a well-tested code area
2. Verify: skill notes which existing tests serve as the baseline; does not write redundant characterization tests
3. Verify: baseline tests pass after refactor

### T6: `inline` subcommand
1. Run `/refactor inline <description>` (simulating a handoff from `/debug`)
2. Verify: no design problem statement step, no options/approval gate
3. Verify: coverage check still runs; characterization tests written if needed

### T7: Escalation path
1. Run `/refactor` on a change requiring cross-subsystem restructuring
2. Verify: skill escalates to `/kickoff` with structured context (design problem, affected files, proposed approach, why inline rejected)
3. Verify: no further file modifications after escalation

### T8: Self-calibration gate
1. Run `/refactor`, then verify the checklist is emitted verbatim before any completion language
2. If coverage was thin: confirm the "characterization tests passing on original code" item is present

### T9: No mixing
1. Run `/refactor` and attempt to include a bug fix alongside the structural change
2. Verify: skill rejects the mixed change and instructs separating it into a distinct commit

---

## Validation

- [ ] `/refactor` loads AGENTS.md and relevant specs before touching anything
- [ ] Design problem statement (what/why/what-achieved) appears before any file is modified (default mode)
- [ ] Skill proceeds without asking user when one clear approach exists
- [ ] Options presented and approval waited when scope is ambiguous
- [ ] Characterization tests written and confirmed passing on original code when coverage is thin
- [ ] All tests pass after refactor before completion language
- [ ] Self-calibration checklist emitted verbatim before any "done" claim
- [ ] `inline` subcommand skips design statement and approval gate, keeps coverage check
- [ ] Escalation to `/kickoff` includes all 4 required context fields
- [ ] No feature or bug-fix changes mixed into refactor commit

---

## Version History

| Date | Change |
|------|--------|
| 2026-04-26 | Initial spec created — design locked in conversation context (no separate brainstorm file) |
| 2026-04-26 | PM review: rewrote 4 ACs, added 6 new ACs, resolved OQ-1 (inline preamble required), OQ-2 (greenfield in scope), OQ-3 (refactor: prefix default), OQ-4 (commit level), OQ-5 (behavioral or file-existence proxy) |
