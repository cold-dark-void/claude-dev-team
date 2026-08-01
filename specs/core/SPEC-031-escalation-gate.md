# SPEC-031: Escalation Gate & Universal Worktree Isolation

**Status**: DRAFT
**Category**: core
**Created**: 2026-07-31

**Covers**: `skills/refactor/SKILL.md` (contract home), `skills/debug/SKILL.md`, `skills/review-and-commit/SKILL.md`, `skills/code-simplify/SKILL.md`, `skills/init-orchestration/SKILL.md` (hook template), `skills/init-orchestration/check-hook-templates.sh`, `commands/setup.md`, `AGENTS.md` (Worktree Protocol drift fix)

---

## Overview

Defines the **Escalation gate** — the enforced checkpoint every implementation-capable
skill MUST pass before it edits any file — and the **universal worktree isolation** rule
that removes the current-branch direct-edit path from those skills. Replaces the
descriptive "escalation ladder" appendix pattern, which was prose-only, self-satisfiable,
and structurally unable to fire: a run could self-diagnose "architectural decision" and
still land the work as a direct commit on the current branch with no ticket, no worktree,
and no PR (origin incident: `lora_tester` commit `f5afea2`).

The gate has three parts: an always-required edit go-ahead (never auto-satisfied), a
ticket-weight routing decision driven by the existing `WHY INLINE REJECTED` vocabulary,
and a workstream-split check that routes multi-idea work to `/epic`. Mechanical backing
is a graduated `PreToolUse` hook. The hook is a **drift detector inside a compliant run,
not a tamper-proof control** — its honest limits are specified normatively below so that
neither implementers nor users over-trust it.

Contract home is `skills/refactor/SKILL.md` (SPEC-002 D1: SPEC defines, one SKILL carries
the operational copy, all other surfaces cite). Sibling skills MUST cite that text and
MUST NOT restate it.

---

## MUST

### Gate placement and mandatory execution

- MUST place the Escalation gate as a **numbered inline step in the sequential flow** of
  each implementation-capable skill — not as a trailing appendix, reference section, or
  "## Escalation ladder" heading. In `skills/refactor/SKILL.md` the gate MUST sit between
  the approach decision (2.2) and the coverage check (2.3) in default mode, and
  immediately after the approach preamble (3.1) in inline mode.
- MUST NOT edit, create, or delete any file until the gate's outcome (go-ahead granted +
  routing decision + worktree path) appears in the session output. Reading and
  investigation are permitted before the gate; modification is not.
- MUST run the gate on **every** invocation of a covered skill, including runs whose scope
  is trivially bounded. There is no size threshold below which the gate is skipped.
- MUST retire the term "escalation ladder" from covered skills once this spec ships;
  "Escalation gate" is the canonical term (domain glossary, CONTEXT.md).

### Edit go-ahead (always ask)

- MUST obtain an explicit user go-ahead before the first file modification of a run. This
  ask is unconditional and has no auto-satisfied branch.
- MUST treat the **approach decision** and the **edit go-ahead** as two distinct
  questions. The approach decision retains its existing auto-pick behavior (SPEC-015: do
  not ask when exactly one approach applies) — it selects *how* to change the code and
  MUST NOT be read as authorization to begin editing. The edit go-ahead authorizes
  *whether to begin editing at all* and is always asked.
- MUST NOT accept a prior go-ahead from an earlier run, an earlier ticket, or an upstream
  command as satisfying this run's go-ahead.
- In `inline` mode (approach pre-decided by `/debug` scope=refactor-first or
  `/orchestrate`), MUST skip **only** the approach re-decision. The edit go-ahead and the
  ticket-weight routing below still run in full.

### Ticket-weight routing

- MUST decide routing using the canonical `WHY INLINE REJECTED` vocabulary single-sourced
  in `skills/kickoff/SKILL.md` § Accepted escalation handoff (per SPEC-014 and SPEC-015):
  `cross-subsystem or multi-directory refactor required` | `architectural decision
  required` | `tech-lead design review required` | `arch mode — design decision required`
  (`/debug` arch mode only) | `callsite count exceeded threshold`.
- If **any one** reason applies: MUST route to `/kickoff` with a real ticket. A local plan
  file is not a substitute for a ticket.
- If **no** reason applies: MUST proceed with an inline confirm plus a worktree, and MUST
  NOT create a ticket. Bounded work does not acquire ticket ceremony. This bounded outcome
  is **provisional** until the workstream-split check runs — see the precedence rule under
  Workstream split.
- MUST emit the 4-field handoff wire format verbatim when routing to `/kickoff` —
  `ROOT CAUSE:` / `AFFECTED FILES:` / `PROPOSED APPROACH:` / `WHY INLINE REJECTED:` — and
  MUST emit a `WHY INLINE REJECTED` value drawn verbatim from the canonical set. The wire
  format and vocabulary are unchanged by this spec; SPEC-014's copy is untouched.

### Workstream split

- MUST check whether the chosen approach decomposes into 2+ independently shippable ideas,
  applying all three criteria: **independently shippable/testable**, **no shared file
  edits**, and **no sequencing dependency**. All three MUST hold for a split.
- MUST route a confirmed split to `/epic` (child tickets) rather than bundling the work
  into one `/kickoff` ticket.
- MUST NOT route to `/epic` when any criterion fails — partially-separable work is one
  ticket.
- MUST run the split check on **every** run, independently of the ticket-weight outcome.
  The check is not conditional on a `WHY INLINE REJECTED` reason having fired.
- **Precedence — split outranks bounded.** A confirmed split MUST route to `/epic` even
  when no `WHY INLINE REJECTED` reason applied and ticket-weight routing therefore returned
  bounded. A confirmed split is never bounded inline work. Where the ticket-weight rule
  above ("no reason applies → proceed inline, create no ticket") and this rule both address
  the same run, this rule governs. Rationale: the criteria are orthogonal — two small,
  independently shippable changes in one directory can trip no escalation reason while
  still being two workstreams, and bundling them into one inline run is the outcome `/epic`
  exists to prevent.

### Universal worktree isolation

- MUST perform all file modification inside `$MROOT/.worktrees/<slug>` in **both** default
  and inline mode, with no exception for trivial or single-line changes.
- MUST remove the current-branch direct-edit and direct-commit path from every covered
  skill. "A single commit in the current session branch is acceptable" is retired
  (SPEC-015 amendment).
- MUST create or reuse the worktree via the SPEC-016 caller-integration form: emit the
  SPEC-002 canonical bootstrap stanza byte-verbatim, then
  `WT_LIB=$(bash "$PDH/skills/plugin-dir.sh" file skills/worktree-lib.sh)`, then
  `bash "$WT_LIB" ensure "$SLUG"`. MUST NOT use the cwd-relative form
  `bash skills/worktree-lib.sh …` (absent on a real install) nor `$MROOT/skills/…`
  (resolves to the user's repo).
- MUST sanitize any slug derived from user-supplied description text before calling
  `ensure` — `worktree-lib.sh` **validates** (`^[A-Za-z0-9_-]+$`, else exit 64) and does
  not sanitize on the caller's behalf.
- MUST handle `ensure` exit codes distinctly: `0` = path on stdout, proceed; `1` = surface
  stderr and halt; `2` = user aborted the collision prompt, halt cleanly without error;
  `64` = invalid slug, a caller bug — halt and report.
- MUST correct the `AGENTS.md` Worktree Protocol section, which documents the
  SPEC-016-forbidden cwd-relative form, so that no new caller copies it.

### Bounded exit paths

- MUST end bounded (non-escalated) work at one of exactly two exits, both from the
  worktree: (a) branch → **PR** (standard), or (b) **squash merge after review** when no
  remote exists or the user prefers linear history. Exit (b) MUST remain available and
  MUST NOT be removed in favor of a PR-only rule.
- MUST end escalated work as `/kickoff` → `/orchestrate` → PR. Escalated work MUST NOT
  terminate in a direct commit.
- MUST NOT leave a worktree as the final state of a completed run — every exit path
  concludes with a PR, a squash merge, or an explicit handoff to a command that owns the
  remaining lifecycle.

### Closing the self-satisfiable plan-file exemption

- MUST NOT treat the mere existence of a `.claude/plans/` file as authorization to skip
  `/kickoff` or to jump directly to `/orchestrate`. The exemption qualifies **only** when
  the plan file contains a ticket-id reference in its Tracking section (`ticket_id:` or a
  `closes:` entry naming a `linear:<ID>` or `backlog/<slug>.md` item), per SPEC-009 plan
  Tracking.
- MUST NOT use file timestamps, mtime, or invocation-time comparison to decide whether a
  plan predates the run — timestamp checks are explicitly out of scope and MUST NOT be
  implemented.
- MUST NOT count a plan file written by the current run as satisfying the exemption,
  regardless of its contents. (`/epic` already enforces the equivalent rule — "never mark
  completed merely because kickoff produced a plan" — and is the precedent to follow.)

### Auto-chain

- On an escalating routing decision, MUST emit the 4-field handoff and invoke `/kickoff`
  **in-session**, without requiring the user to restart the workflow manually.
- After `/kickoff` completes, MUST obtain **one** user confirmation, which then authorizes
  the run to proceed through `/orchestrate` to a PR without further per-stage restarts.
- MUST NOT auto-chain past the escalation decision itself — the edit go-ahead and the
  post-kickoff confirmation are both real asks.

### Hook contract — graduated enforcement

- MUST ship a `PreToolUse` hook via `/setup orchestration`, templated in
  `skills/init-orchestration/SKILL.md` as the single source of truth (live
  `.claude/hooks/*.sh` are generated and gitignored — CDT-54).
- MUST implement two enforcement levels:
  - **WARN (exit 0)** whenever the hook is installed and a `Write`/`Edit`/`NotebookEdit`
    targets a path outside `$MROOT/.worktrees/`. Warns on stderr; never blocks.
  - **HARD BLOCK (exit 2)** only when a skill-written armed marker exists for the current
    run/slug and the target path is outside `$MROOT/.worktrees/`.
- MUST fail open (`exit 0`) on every internal error: absent `jq`, unparseable stdin,
  missing marker directory, unresolvable `$MROOT`, or any unexpected condition. The hook
  MUST NOT block on its own malfunction.
- MUST allowlist paths that are never gated at either level: `.claude/**`, `specs/**`,
  and documentation-ish targets (`*.md`, `*.txt`). The full allowlist MUST be enumerated
  explicitly in the implementation, not inferred at runtime.
- MUST read the target path as `.tool_input.notebook_path // .tool_input.file_path` —
  `NotebookEdit` supplies `notebook_path`, and reading only `file_path` lets notebook
  writes pass silently (verified on Claude Code v2.1.212).
- MUST key per-run warn-latch state on **`agent_id`**, not `session_id`. `PreToolUse`
  fires inside subagents with the **parent** `session_id`; the child is identified by
  `agent_id` / `agent_type` (verified v2.1.212). Keying on `session_id` would collapse all
  orchestrated ICs into one latch.
- MUST use `jq` for stdin parsing, matching the existing `PreToolUse` precedent
  (`bash-compress.sh`) and `memory-capture.sh`; MUST fail open when `jq` is absent.
- MUST emit the hook script with a shebang as its **first non-empty line** (
  `#!/usr/bin/env bash`), and MUST NOT place variable-resolution lines above the shebang —
  the defect present in `commands/tdd-gate.md`'s template MUST NOT be replicated.
- MUST add the new hook name to the `HOOKS` list in
  `skills/init-orchestration/check-hook-templates.sh`; a template fence absent from that
  list is silently unverified.
- MUST define and implement an append rule for merging a second entry into an existing
  non-empty `settings.json` `PreToolUse` array. `/setup orchestration` currently merges at
  the event-key level only, and `/tdd-gate on` writes into the same array; the two MUST
  coexist without either clobbering the other.
- MUST add the blocking hook to the up-front permission batch disclosure in
  `commands/setup.md` — a hook that can block tool calls is a material behavior change and
  MUST be disclosed before install.

### Hook contract — honest limits (normative)

- MUST state, in both the skill text and the `/setup orchestration` disclosure, that the
  hook is **not tamper-proof**, in these four specific respects:
  1. **Bash bypasses it entirely.** A `PreToolUse` hook matching file-editing tools does
     not observe `sed -i`, heredoc redirection, `git apply`, or `git commit` issued through
     the `Bash` tool.
  2. **The arming actor is the enforced actor.** The same agent that executes the skill
     writes the armed marker the hook reads, so the hook cannot verify
     that a user was actually asked. It detects drift within a compliant run; it does not
     defend against a non-compliant one.
  3. **Coverage is tool-name-scoped.** Only the enumerated editing tools are gated; any
     future or unlisted write path is ungated until added.
  4. **Path matching is textual, and normalization is best-effort.** Targets are compared
     as strings after `realpath -m` normalization; where `realpath` is unavailable the raw
     path is used and `..` path traversal is not normalized away, so a target such as
     `$MROOT/.worktrees/../src/a.go` reads as an in-worktree write and is not gated.
- MUST NOT describe the hook as "enforcement the model cannot regress", "tamper-proof", or
  equivalent. The prose-vs-machinery framing MUST be accurate about what machinery can and
  cannot guarantee here.

### Contract home and sibling citation (D1)

- MUST carry the operational gate text exactly once, in `skills/refactor/SKILL.md`.
- Sibling skills MUST **cite** that text by section reference and MUST NOT restate it.
  Divergent copies are the failure mode this rule exists to prevent.
- MUST write the gate text as a cleanly extractable block so that a future promotion to a
  shared front-door library (brainstorm Option C) is a move, not a rewrite.
- Sibling fixes are pre-scoped as follows and MUST NOT expand without a new decision:
  - `skills/debug/SKILL.md` — same inline-gate placement plus the plan-file exemption fix.
  - `skills/review-and-commit/SKILL.md` — worktree + ticket-weight routing + an
    unconditional commit prompt (a clean review currently commits to the current branch
    with no prompt at all).
  - `skills/code-simplify/SKILL.md` — citation-only fix on its manual invocation path.

### Sequencing

- MUST land in this order: (1) gate rewrite + spec amendments, (2) sibling skill fixes
  citing the contract-home text, (3) hook template and wiring.
- The hook workstream MUST NOT gate workstream 1. Workstream 1 is independently shippable
  and carries the majority of the behavior change; the hook is additive backing.

---

## SHOULD

- SHOULD reuse the existing `worktree-lib.sh` reuse path rather than releasing and
  recreating worktrees between stages of one run (reuse is a lock re-stamp, single-digit
  milliseconds).
- SHOULD name the worktree slug after the ticket id when one exists, and after a sanitized
  description keyword otherwise, so `/status worktree` output stays legible.
- SHOULD emit a gate outcome to the SPEC-026 outcomes ledger (routing decision, escalated
  vs bounded) so gate behavior is measurable over time.
- SHOULD keep the WARN level's stderr message short enough to remain readable when it
  fires repeatedly in a long session.

---

## MUST NOT

- MUST NOT provide any flag, mode, or environment variable that skips the edit go-ahead.
- MUST NOT provide a "trivial change" bypass for worktree isolation.
- MUST NOT reintroduce a `.claude/plans/`-existence exemption in any covered skill.
- MUST NOT wire `WorktreeCreate` or `WorktreeRemove` hooks for this gate — SPEC-016's
  CDV-189 spike established that `WorktreeCreate` replaces default worktree creation
  rather than observing it, and `WorktreeRemove` has no exit-2 decision control.
- MUST NOT block on `PreToolUse` for any reason other than the armed-marker condition
  above; every other path exits 0.
- MUST NOT restate the gate text in sibling skills (see contract home).

---

## Test

### T1: Gate is inline and blocking
1. Run `/refactor` on a bounded change.
2. Verify the gate step's output (go-ahead, routing decision, worktree path) appears before
   any file modification, and that the gate is a numbered step between 2.2 and 2.3.

### T2: Edit go-ahead always asked
1. Run `/refactor` on a change so small that 2.2 auto-picks the approach without asking.
2. Verify the approach is auto-picked AND the edit go-ahead is still asked.

### T3: Bounded routing creates no ticket
1. Run the gate with no `WHY INLINE REJECTED` reason applying.
2. Verify: inline confirm + worktree created, no `/kickoff` invocation, no ticket.

### T4: Escalating routing emits canonical handoff
1. Run the gate on cross-directory work.
2. Verify the 4-field handoff is emitted verbatim with a `WHY INLINE REJECTED` value drawn
   from the canonical set, and `/kickoff` is invoked in-session.

### T5: Workstream split routes to /epic
1. Present an approach decomposing into two independently shippable, non-overlapping,
   unordered ideas.
2. Verify routing to `/epic`; then verify that failing any one criterion routes to a single
   `/kickoff` ticket instead.
3. Present a split whose pieces trip **no** `WHY INLINE REJECTED` reason (e.g. two small,
   independently shippable changes in one directory). Verify the run routes to `/epic`, not
   to bounded inline work — split outranks bounded.

### T6: Universal worktree, both modes
1. Run `/refactor` and `/refactor inline` on one-line changes.
2. Verify both create/reuse `$MROOT/.worktrees/<slug>` and neither edits the current branch.

### T7: Plan-file exemption closed
1. Place a `.claude/plans/` file with no ticket-id reference in its Tracking section.
2. Verify the gate does NOT skip `/kickoff`.
3. Add a `ticket_id:` reference; verify the exemption now qualifies.
4. Verify a plan file written by the current run never qualifies.

### T8: Hook WARN level
1. Install the hook; do not arm.
2. `Write` to a path outside `.worktrees/`. Verify exit 0 with a stderr warning, and that
   the write proceeds.

### T9: Hook HARD BLOCK level
1. Arm the marker for a slug; `Write` outside `.worktrees/`. Verify exit 2 and a blocked
   write.
2. `Write` inside `.worktrees/<slug>`. Verify exit 0.

### T10: Hook notebook path
1. With the hook armed, issue a `NotebookEdit` outside `.worktrees/` (payload carries
   `notebook_path`, not `file_path`).
2. Verify it is gated — a hook reading only `file_path` fails this test.

### T11: Hook fail-open
1. Feed the hook malformed stdin; run it with `jq` unavailable on `PATH`; run it with the
   marker directory absent.
2. Verify exit 0 in all three cases.

### T12: Hook allowlist
1. With the hook armed, write to `.claude/foo.json`, `specs/SPEC-999-x.md`, and `README.md`
   outside `.worktrees/`. Verify all three exit 0.

### T13: agent_id keying
1. Trigger warns from two subagents in one session.
2. Verify latch state is per-`agent_id`, not collapsed by the shared parent `session_id`.

### T14: Hook coexistence with tdd-gate
1. Run `/tdd-gate on`, then `/setup orchestration` (and the reverse order).
2. Verify both `PreToolUse` entries are present and functional afterward; neither clobbers
   the other.

### T15: Template verification wiring
1. Run `bash skills/init-orchestration/check-hook-templates.sh`.
2. Verify the new hook name is in the `HOOKS` list and the check passes (marker present,
   shebang first non-empty line, `bash -n` clean).

### T16: Sibling citation, no restatement
1. Grep sibling skills for the gate's operational text.
2. Verify each cites `skills/refactor/SKILL.md` and none restates the block.

---

## Validation

- [ ] Gate is a numbered inline step in `/refactor` (both modes), not an appendix
- [ ] Edit go-ahead asked on every run; approach auto-pick behavior unchanged
- [ ] Ticket-weight routing uses the canonical `WHY INLINE REJECTED` set unmodified
- [ ] Workstream-split check applies all three glossary criteria
- [ ] Split check runs every run; a confirmed split routes to `/epic` even when bounded
- [ ] Both modes create/reuse a worktree; no current-branch edit path remains
- [ ] Worktree calls use the SPEC-016 PDH-resolved form; `AGENTS.md` drift corrected
- [ ] Squash-merge-after-review exit remains available alongside the PR exit
- [ ] Plan-file exemption requires a ticket-id reference; no timestamp logic present
- [ ] Auto-chain reaches `/kickoff` in-session; one confirm authorizes through PR
- [ ] Hook WARN/BLOCK levels behave per T8/T9; fail-open per T11
- [ ] Hook reads `notebook_path // file_path` and keys latch state on `agent_id`
- [ ] Honest-limits language present in skill text and `/setup` disclosure
- [ ] New hook added to `check-hook-templates.sh` HOOKS; shebang is first non-empty line
- [ ] `PreToolUse` array append rule defined; coexists with `/tdd-gate`
- [ ] Gate text appears exactly once (contract home); siblings cite only
- [ ] Spec reviewed and promoted to ACTIVE

---

## Cross-references

- **SPEC-015** (Refactor Workflow) — contract home for the gate text; amended by CDT-98 to
  remove the current-session-branch mandate, close the plan-file exemption, and
  disambiguate the no-user-input MUSTs.
- **SPEC-014** (Debug Workflow) — `/debug` receives the same gate placement and exemption
  fix; its 4-field handoff copy is unchanged by this spec.
- **SPEC-016** (Worktree Isolation) — owns `worktree-lib.sh`, the `.worktrees/<slug>` path
  convention, and the caller-integration form this spec requires. Its WLH DRAFT block
  records why `WorktreeCreate`/`WorktreeRemove` are unusable here.
- **SPEC-002** (Plugin Infrastructure) — canonical byte-verbatim bootstrap stanza and the
  caller-integration site table, which gains the new `worktree-lib.sh` call sites.
- **SPEC-009** (Ticket Workflow) — plan Tracking section (`source`, `ticket_id`, `closes:`)
  whose ticket-id reference closes the exemption.
- **SPEC-025** (Epic Umbrella Decomposition) — workstream-split destination; also the
  precedent for refusing to let a self-produced plan file satisfy a gate.
- **SPEC-029** (Debug Reopen & Multi-Surface Done Gates) — `/refactor inline` handoff
  context that inline mode must preserve.
- **SPEC-021** (Skill Bash Lint Gate) — C1 (file-level cross-block variable scope) and C3
  (unquoted glob) apply to every new fenced bash block, including hook-template fences.
- **SPEC-010** (Code Review & Release) — `/release` Step 4.7 runs `check-hook-templates.sh`;
  Step 4.9 runs the docs-drift checker if a new command surface is added.
- **SPEC-026** (Adaptive Agent Routing) — outcomes ledger destination for gate metrics.

---

## Version History

| Date | Change |
|------|--------|
| 2026-07-31 | Initial spec created (CDT-98) — Escalation gate contract, universal worktree isolation, graduated PreToolUse hook with normative honest-limits, sibling citation rule, sequencing. External behaviors verified live on Claude Code v2.1.212 (multi-entry PreToolUse, notebook_path, parent session_id + agent_id, transcript_path). |
