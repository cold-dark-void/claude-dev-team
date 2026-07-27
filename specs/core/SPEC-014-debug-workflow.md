# SPEC-014: Debug Workflow

**Status**: APPROVED
**Category**: core
**Created**: 2026-04-25
**See also**: SPEC-029 (reopen detector, multi-surface done gates, concurrent scenario rule); SPEC-028 (`ticket` mode protocol — fold OOS until W5)

**Covers**: `commands/debug.md` (CDT-46-C4), `skills/debug/SKILL.md`, `skills/debug/theme-status.sh` (SPEC-029 gates); `commands/fix-ticket.md` + `skills/fix-ticket/` (Deprecation stubs → `/debug ticket`, CDT-46-C4)

---

## Overview

Defines the `/debug` skill — the bug-handling equivalent of `/brainstorm`. Owns the full investigation → root-cause → fix → verify cycle autonomously. Enforces phase-gated discipline to prevent shallow diagnosis, premature "done" claims, and tech debt from un-refactored patches. Entry: `/debug [patch|arch|ticket] …`. Default mode is `full`.

**SPEC-029** adds hard gates that were missing in the first ship: same-theme reopen → forced redesign; multi-UI surface matrix before done; interleaved regression for concurrency bugs; theme log + optional outcomes.

**CDT-46-C4:** thin host `commands/debug.md` ships; mode `ticket` absorbs the former `/fix-ticket` entry (SPEC-028 protocol retained; full SPEC-028→014 fold is W5 out of scope).

---

## MUST

### Entry & Mode Selection

- MUST ship thin user-invocable host `commands/debug.md` that resolves and follows `skills/debug/SKILL.md` (plugin-dir aware)
- MUST support four first-token modes (case-sensitive exact match on first arg token):
  - `/debug <description>` → mode `full` (default; entire arg string is the description)
  - `/debug patch <description>` → fast path
  - `/debug arch <description>` → design-first
  - `/debug ticket <ticket-id> "<bug/premise>" [flags…]` → premise→implement→adversarial-refuters (SPEC-028 pipeline)
- MUST parse mode as: if first token is exactly `patch`, `arch`, or `ticket`, that token is the mode and the remainder is mode-specific args; otherwise mode is `full` and the entire argument string is the description
- MUST load AGENTS.md, relevant specs, recent git log, and existing tests for the affected area before beginning any investigation — all before outputting any root cause analysis (`full`/`patch`/`arch` only; `ticket` follows SPEC-028 phase order)
- MUST read any `.claude/plans/` file for the affected area if one exists
- MUST proceed without error if AGENTS.md does not exist

### `ticket` mode (CDT-46-C4; protocol home SPEC-028)

- MUST accept: `/debug ticket <ticket-id> "<bug/premise>" [--fix "…"] [--agent ic4|ic5] [--lenses a,b] [--worktree <path>]`
- Missing ticket-id or premise MUST produce a usage error and MUST NOT spawn agents
- MUST execute the SPEC-028 pipeline with full behavioral parity (premise verify → implement in worktree → N qa refuters → report under `.claude/fix-ticket/`)
- MUST NOT commit, version-bump, or run `/release` (`ticket` mode; caller owns ship)
- `full` / `patch` / `arch` gates in this spec and SPEC-029 MUST remain unchanged for non-`ticket` modes
- `commands/fix-ticket.md` and `skills/fix-ticket/SKILL.md` MUST be one-cycle Deprecation stubs pointing to `/debug ticket` (removed at v1.1). Protocol body MAY live under `skills/debug/` or remain reachable from the debug skill; stub files remain for discovery

### Investigation (all modes)

- MUST state the root cause explicitly in writing before modifying any file; the statement must identify: (1) what specifically fails, (2) why it fails (not just what fails), and (3) the originating layer — not the symptom layer
- MUST NOT edit, create, or delete any file until the root cause statement exists in the session output
- MUST trace the full execution path holistically — not stop at the first grep match
- MUST identify whether the same root cause or pattern exists elsewhere in the codebase
- MUST state the scope decision explicitly in written output before any fix code is written: targeted patch, refactor-first, or `/update-spec` handoff

### Spec Alignment Check (`full` mode only)

- MUST read all specs in `specs/` related to the affected area before concluding root cause analysis
- MUST classify the deviation as one of: (a) code bug — spec is correct, (b) spec gap — `/update-spec` handoff required, or (c) intentional divergence — document and proceed
- MUST hand off to `/update-spec` if classification is (b), outputting: the relevant spec file, the specific requirement missing or contradicted, and a proposed addition
- MUST NOT ask the user to make the spec-vs-bug determination unless classification is genuinely ambiguous after full investigation

### Scope Decision (`full` and `arch` modes)

- MUST trigger the refactor path if the same fix pattern would need to be applied in more than one place
- MUST NOT present the scope decision to the user as a question unless genuinely ambiguous after full investigation

### Test First (all modes)

- MUST write a failing regression test that captures the bug before implementing any fix
- MUST NOT begin the fix until the failing test exists and is confirmed to fail for the right reason
- MUST skip the test phase with an explicit warning if no test suite exists in the project; still require a reproduction scenario document (conditions, trigger steps, expected vs actual) as substitute
- MUST use a two-track fallback for non-reproducible bugs (race conditions, environment-specific, AI behavior): (1) write a reproduction scenario document, (2) write a best-effort characterization test covering adjacent behavior; after fix, emit an explicit verification note documenting manual confirmation

### Fix (all modes)

- MUST implement the fix after the failing test exists
- MUST keep refactor and fix as separate concerns — if a refactor is required, it is completed and committed before fix code is written
- MUST use separate PRs for refactor and fix when the work is escalated; otherwise separate commits in the same session for easy bisect/revert

### Holistic Callsite Check (`full` mode)

- MUST grep for the same root cause pattern in other parts of the codebase after applying the fix
- MUST address or explicitly document any additional instances found before claiming done

### Validation (all modes)

- MUST run the full test suite and confirm all tests pass before claiming done
- MUST confirm the regression test transitions from failing to passing
- MUST emit the self-calibration checklist with each item marked confirmed before any completion language: root cause written ✓, failing test existed before fix ✓, all tests pass ✓, callsite check completed (full mode) ✓
- MUST NOT output any language implying completion ("done", "fixed", "resolved") until the full checklist is confirmed

### Unknown Blockers (all modes)

- MUST surface genuine blockers as exactly one specific question stating precisely what information is missing
- MUST NOT fabricate or guess when blocked
- MUST NOT ask multiple back-and-forth questions when one specific question covers the blocker

### Escalation (`full` and `arch` modes)

- MUST escalate to `/kickoff` when: refactor scope spans multiple subsystems, an architectural decision is required, or the fix requires a tech-lead design review
- MUST pass investigation findings to `/kickoff` as structured issue text containing: (1) root cause statement, (2) list of affected files/modules, (3) proposed approach, (4) why inline resolution was rejected. The canonical field layout and the shared `WHY INLINE REJECTED` vocabulary are single-sourced in the `/kickoff` accepted-handoff input contract (`skills/kickoff/SKILL.md` § Accepted escalation handoff); `/debug` and `/refactor` MUST emit that vocabulary verbatim so the two producers do not diverge.
- MUST NOT continue modifying files after triggering escalation
- MUST escalate to `/orchestrate` (via `/kickoff`) when scope is large, clear, and requires multiple agents
- MUST NOT escalate directly to `/orchestrate` without `/kickoff` first unless a `.claude/plans/` file for the work already exists
- MUST escalate to `/kickoff` in `arch` mode regardless of scope — never attempt an inline fix

---

## SHOULD

- SHOULD note `// regression: SPEC-014 <short description>` in newly written regression tests for traceability
- SHOULD prefer fixing the root layer over patching callers when both are possible
- SHOULD suggest `/refactor` as a follow-up if the fix reveals broader design debt out of scope for the current bug

---

## MUST NOT

- MUST NOT modify any file before the root cause is stated in writing
- MUST NOT claim done before the self-calibration checklist passes
- MUST NOT apply the same fix in multiple places — that is always a refactor trigger
- MUST NOT skip the failing-test phase for reproducible bugs, even apparently trivial ones
- MUST NOT back-and-forth on blockers — one specific question or silence

---

## Test

### T1: Root cause gating
1. Run `/debug` on a bug where the first grep match is not the actual root cause
2. Verify: no file is modified until the root cause statement appears in the session
3. Verify: the root cause statement identifies (a) what fails, (b) why it fails, (c) originating layer — not the symptom

### T2: Multi-site pattern detection
1. Run `/debug` on a bug where the same fix is needed in 3 places
2. Verify: scope decision appears as explicit written output before any fix code
3. Verify: the skill does NOT apply identical fixes independently — chooses a shared abstraction or escalates to `/kickoff`

### T3: Failing test first
1. Run `/debug` on any reproducible bug
2. Verify: a new failing test exists and is confirmed failing before any fix code is written

### T4: Validation gate
1. Run `/debug` and intentionally leave one test failing
2. Verify: the self-calibration checklist appears and the "all tests pass" item is not confirmed
3. Verify: no "done/fixed/resolved" language appears

### T5: Spec alignment check
1. Run `/debug` on behavior that deviates from an existing spec
2. Verify: the skill reads the relevant spec and classifies as code-bug, spec-gap, or intentional-divergence
3. Verify: if spec-gap, output includes the specific requirement missing and a `/update-spec` handoff — does NOT ask the user to decide

### T6: Escalation path
1. Run `/debug` on a bug requiring cross-subsystem refactor
2. Verify: skill escalates to `/kickoff` with structured context (root cause, affected files, proposed approach, why inline rejected)
3. Verify: no further file modifications after escalation is triggered

### T7: `patch` subcommand fast path
1. Run `/debug patch <description>`
2. Verify: no spec alignment check, no escalation, no callsite scan — only root cause → failing test → fix → validate

### T8: Unknown blocker
1. Run `/debug` on a bug where a critical runtime value is unknown
2. Verify: exactly one specific question is asked, not multiple back-and-forth exchanges

### T9: No test suite
1. Run `/debug` on a project with no test infrastructure
2. Verify: test phase is skipped with explicit warning
3. Verify: a reproduction scenario document is produced as substitute

### T10: `arch` subcommand
1. Run `/debug arch <description>`
2. Verify: skill writes root cause statement, then escalates to `/kickoff` — does NOT write a failing test, does NOT apply a fix inline

### T11: `ticket` mode entry (CDT-46-C4)
1. Run `/debug ticket` with missing ticket-id or premise
2. Verify: usage error; no agent spawn
3. Run `/debug ticket <id> "<premise>"` with a known holding premise (or mock)
4. Verify: SPEC-028 pipeline phases execute (or skill-delegate reaches the same protocol); no commit/version mutation
5. Verify: `commands/debug.md` exists and is the user entry; `commands/fix-ticket.md` is a Deprecation stub naming `/debug ticket`

---

## Validation

- [ ] `/debug` loads AGENTS.md and relevant specs before touching anything
- [ ] Root cause statement identifies what/why/layer before any file is modified
- [ ] Scope decision written before any fix code
- [ ] Failing test confirmed failing before fix is implemented (reproducible bugs)
- [ ] Self-calibration checklist emitted before completion language
- [ ] All tests pass before "done" language appears
- [ ] Same-pattern detection triggers refactor path (not multi-site patch)
- [ ] Spec alignment check runs in `full` mode, skipped in `patch` mode
- [ ] Spec-gap classification produces `/update-spec` handoff without asking user
- [ ] Escalation to `/kickoff` includes structured context (4 required fields)
- [ ] `arch` subcommand always escalates to `/kickoff`, never fixes inline
- [ ] Blockers produce exactly one specific question
- [ ] No test suite → warning + reproduction scenario document
- [ ] Refactor committed before fix when refactor path chosen
- [ ] `commands/debug.md` thin host ships; first-token modes include `ticket`
- [ ] `/debug ticket` missing args → usage, no spawn; no commit/version on green path
- [ ] `/fix-ticket` command + skill are Deprecation stubs → `/debug ticket`

---

## Version History

| Date | Change |
|------|--------|
| 2026-04-25 | Initial spec created — brainstorm: `.claude/plans/2026-04-25-brainstorm-debug-skill.md` |
| 2026-04-26 | PM review: rewrote T1/T2/T5/T6, added T9/T10, added 5 missing ACs, resolved OQ-1 (free-form root cause with quality criteria), OQ-2 (grep-based callsite check), OQ-3 (skip+warn when no test suite), OQ-4 (separate PRs if escalated, commits otherwise), OQ-5 (two-track fallback for non-reproducible bugs), switched from --mode flags to subcommands |
| 2026-06-15 | Editorial hygiene (AUDIT-P3.5b): Status `🚧 NEW`→`APPROVED` (no emoji, matches TDD index). No behavioral change. |
| 2026-07-15 | SPEC-029 DRAFT + skill gates: reopen/redesign force, multi-surface matrix, concurrent scenario, theme log; checklist extended in `skills/debug/SKILL.md`. |
| 2026-07-22 | CDT-46-C4: Covers + thin `commands/debug.md` host; first-token modes add `ticket` (absorbs `/fix-ticket` entry; SPEC-028 protocol parity; full fold W5 OOS). T11 + validation checkboxes. |
