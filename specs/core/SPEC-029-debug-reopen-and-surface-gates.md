# SPEC-029: Debug Reopen Detector & Multi-Surface Done Gates

**Status**: ACTIVE  
**Category**: core  
**Created**: 2026-07-15  
**Extends**: SPEC-014 (Debug Workflow), SPEC-015 (Refactor Workflow), SPEC-026 (outcomes)  
**Evidence**: `.claude/plans/2026-07-15-plugin-bug-refactor-performance-eval.md`,  
`.claude/plans/2026-07-15-may-refine-autopsy.md` (describer May 2026 refine/isolation thrash)

---

## Overview

Closes the gap between SPEC-014's *judgment* gates (refactor-first, escalate,
done-language ban) and lived failure: multi-week reopen of the same bug theme
while agents kept applying targeted patches; single-surface "done"; `/refactor`
unused.

**Attribution honesty:** May `/debug` JSONLs are missing. Failures may have been
**adherence** (gates never run) *or* **wrong scope under judgment**. SPEC-029's
theory is to convert the critical signal into **mechanical output** (helper prints
`Forced redesign: yes`) that is harder to rationalize past. Dogfood must confirm
agents actually execute S.1 — nothing hook-enforces it yet.

**FM coverage (from May autopsy):**

| FM | Mode | SPEC-029? |
|----|------|-----------|
| FM-1 | Same theme reopen without redesign | **Yes** — day-based reopen force |
| FM-2 | Single-surface fix | **Yes** — surface matrix |
| FM-3 | Patch after user said isolation | **Yes** — keyword force + override |
| FM-4 | Tests without concurrent scenario | **Yes** — interleaved scenario |
| FM-5 | Architecture epic under-scoped until presentation | **No** — design-review lesson, not gateable |
| FM-6 | `/refactor` unused | **Partial** — handoff context only |
| FM-7 | Done language vs user oracle | **Yes** — matrix + checklist |

---

## MUST

### Theme key & reopen detection (full + patch + arch)

- MUST derive a **bug theme key** after mode parse from `$DESC`: normalize tokens;
  strip stopwords; join first 3–6 content tokens with `-`; if empty after strip,
  MUST fall back to a truncated slug or `unthemed` (never empty filename)
- MUST scan prior work on the theme before scope decision via
  `.claude/debug/themes/<theme-key>.jsonl` and/or history fallback
- MUST set `REOPEN_COUNT` to the number of **distinct calendar days (UTC)** in the
  last **14 days** that already contain a prior `/debug` (or theme-log entry) for
  this theme — **not** raw line count of the log
- MUST set `FORCED_REDESIGN=true` when **any** of:
  1. `REOPEN_COUNT >= 2` (third distinct day on the theme within 14 days)
  2. `$DESC` matches isolation/architecture signals (case-insensitive). Prefer
     multi-word phrases: `no isolation`, `missing isolation`, `wrong abstraction`,
     `same fix everywhere`, `every backend`, `all three backends`; also
     `state machine`, `architecture`, `redesign`
  3. Investigation finds the same fix pattern needed in **>1** top-level UI backend
- MUST emit a written Theme status block before root-cause/scope work

### Human override

- MUST allow an **explicit user override** when `FORCED_REDESIGN` is true: ask one
  yes/no question whether to allow `targeted-patch` anyway
- On user **yes**: MUST set force inactive for this run, log theme entry with
  `outcome=override` and `forced_redesign=overridden`, and MAY choose
  `targeted-patch`
- On user **no** or no answer: MUST keep force active
- MUST NOT invent override without an explicit affirmative user message in-session

### Forced redesign behavior

- When force is active (no override): MUST NOT choose `targeted-patch`; MUST choose
  `refactor-first` or `escalate-to-kickoff`
- When mode is `patch` and force is active (no override): MUST abort without fix;
  instruct full or arch re-run (or override)
- Prefer `escalate-to-kickoff` when REOPEN_COUNT ≥ 3 or new abstraction required

### Multi-surface matrix (full mode)

- MUST detect UI-surface-sensitive bugs (multi-backend product + UI-visible symptom)
- MUST emit a Surface matrix with every known product surface as
  `verified` | `not-applicable (reason)` | `blocked (reason)` before completion language
- MUST NOT claim done while any surface is unmarked or `blocked`
- Symmetry-by-code-reading is NOT verification

### Concurrent scenarios (full mode test-first)

- When concurrency / interleaving / multi-enqueue / completion-during-nav is in
  scope: MUST include a multi-step interleaved regression artifact (≥2 ops)
- Helper-only unit tests are insufficient alone for concurrent bugs

### Theme log

- MUST append one JSON line per debug run end (full/patch/arch), fail-open:
  `ts`, `theme`, `mode`, `reopen_count`, `forced_redesign`, `scope`, `outcome`
  (`fixed|escalated|aborted|not_fixed|override`)
- Skill prose bash for append MUST NOT rely on shell variables from other fenced
  blocks (skill-lint C1): use in-block placeholders the model fills

### Outcomes (SPEC-026)

- SHOULD emit outcomes when helpers exist; MUST NOT block on metrics failure

### Refactor integration

- MUST pass theme key and reopen count into `/refactor` handoff context when
  scope is refactor-first

---

## SHOULD

- SHOULD use AGENTS.md surface list when present
- SHOULD suggest project-local debug harness skills when one exists
- SHOULD make threshold configurable via `.claude/debug/config.json`
  `reopen_force_threshold` (default 2 prior days)
- SHOULD suggest `/handoff` when REOPEN_COUNT ≥ 1 or force/override fired
- SHOULD treat history messages without `/debug` as dogfood watch-items for
  theme matching (plain "still broken" is high-signal but not yet counted)

---

## MUST NOT

- MUST NOT claim multi-surface parity by code-reading alone
- MUST NOT stay in patch mode under force without override
- MUST NOT use raw theme-log line count as REOPEN_COUNT
- MUST NOT invent user override
- MUST NOT treat "tests pass on one UI tag" as all surfaces verified

---

## Test

### T1: Reopen forces redesign
1. Seed theme log with entries on two distinct prior UTC days for theme `refine-source`
2. Run `/debug refine source always rev 1` on a third day
3. Verify Theme status shows Prior ≥ 2 and Forced redesign: yes
4. Verify scope is not `targeted-patch` without override

### T2: Patch aborts on force
1. Same seed as T1
2. Run `/debug patch refine source…`
3. Verify no fix commits; abort message; optional override path

### T3: Surface matrix blocks done
1. UI-surface-sensitive bug; only one surface verified
2. Verify done language refused

### T4: Concurrent scenario required
1. DESC includes “while refine in progress”
2. Verify interleaved regression artifact or explicit gap

### T5: Isolation keywords force redesign
1. Fresh theme, DESC contains “we have no isolation”
2. Verify Forced redesign: yes without prior reopen days

### T6: User override
1. Force active via keyword
2. User answers yes to override question
3. Verify targeted-patch allowed and theme log `outcome=override`

### T7: Empty / stopword-only DESC
1. derive on description that strips to empty
2. Verify theme key is non-empty (`unthemed` or slug fallback)

### T8: skill-lint C1
1. Run `check-skill-bash.sh skills/debug/SKILL.md`
2. Verify zero C1 findings on SPEC-029 blocks

---

## Validation

- [ ] SPEC-008 format: Overview, MUST/SHOULD/MUST NOT, Test, Validation, Version History
- [ ] skill-lint clean on `skills/debug/SKILL.md` (C1–C4)
- [ ] `theme-status.sh derive` never empty; force-check isolation keyword works
- [ ] `count-prior` uses distinct days, not `wc -l`
- [ ] User override path documented in skill S.1b and logged
- [ ] TDD.md index row after SPEC-028 (numeric order)
- [x] Dogfooded on describer via Grok `/dev-team:debug` (2026-07-16): Generate queue source-hash fix `d866c54`; queue thumb identity-reuse `8dfd578`; S.1 theme status exercised (force/override paths still residual)
- [ ] check-format passes for this file
- [ ] FM-5 explicitly out of scope (not gateable)

---

## Covers

- `skills/debug/SKILL.md` (SPEC-029 section)
- `skills/debug/theme-status.sh`
- `skills/refactor/SKILL.md` (theme context note)
- `.claude/debug/themes/` convention
- SPEC-014 checklist extension

---

## Version History

| Date | Change |
|------|--------|
| 2026-07-15 | DRAFT from plugin eval + May autopsy |
| 2026-07-15 | Review fixes: Validation section; REOPEN_COUNT = distinct days; human override; C1-safe S.6 placeholders; empty-key fallback; FM coverage table; arch S.6 |
| 2026-07-16 | Status DRAFT→ACTIVE after describer dogfood (Grok `/debug` sessions; happy-path + S.1; force/override residual) |
