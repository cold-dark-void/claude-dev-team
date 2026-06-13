# Bootstrap skills — single-root anchoring (subdir-invocation hardening)

**Status**: PENDING — DEFERRED (surfaced by AUDIT-P1-2; not a path-consolidation concern, deferred from the doc-only patch to avoid a coordinated-refactor regression surface)

## Problem
`scaffold-project` and `init-orchestration` Step 7 are cwd-relative for ALL their `.claude/`/`specs/` ops (mkdir, MEMDB, settings.json, plans.md, TDD.md, AGENTS.md, .gitignore). This is correct when the skill is invoked from the target project root (the normal case), but if invoked from a **subdirectory** of an existing project — scaffold explicitly supports "Adding TDD workflow to an existing project" — every op lands in the subdir instead of the project root.

A naive partial fix (anchor only MEMDB on an absolute root while siblings stay relative) is WORSE: it splits the scaffold across two roots and makes `sqlite3` fail (`unable to open database file`) because the DB's parent dir was created relative. See AUDIT-P1-2 rework finding 1.

Separately, `init-orchestration` reads inconsistently: its emitted-hook MEMDB (`:365`, `git-common-dir`) vs its own Step-7 seed MEMDB (`:664`, relative) look contradictory, though they execute in different contexts (the `:365` value is hook-template text written into the target project's `memory-capture.sh`, where `git-common-dir` is correct for that hook's runtime). Readability debt.

## Proper fix (the deferred Option B)
At the top of each bootstrap skill, resolve ONE project root: `PROJ_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)` and anchor **every** `.claude/`/`specs/` op on it — consistent single-root rooting that fixes the subdir case for real. Add a one-line comment at `init-orchestration:365`/`:308` clarifying those are *emitted hook templates* (target-runtime `git-common-dir` is correct there) so the in-file inconsistency reads as intentional.

## Constraint
MUST be all-or-nothing per skill — never mix an absolute-one-op with relative-siblings (that splits the scaffold). MUST NOT use `--git-common-dir` to anchor a fresh project (it resolves a parent worktree's shared root, not the project being created). Authoritative formulas are declared in SPEC-002 → "Project-root resolution — authoritative formulas" (added in AUDIT-P1-2).

## Affects
- skills/scaffold-project/SKILL.md (~15 relative ops)
- skills/init-orchestration/SKILL.md (~6 relative ops + 2 emitted-hook comments)

## Effort
Medium — touches ~21 ops across two skills; needs a subdir + root + non-git + worktree test matrix.

---

*Added: 2026-06-13*
