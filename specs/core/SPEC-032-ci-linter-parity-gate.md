# SPEC-032: CI Linter Parity Gate

**Status**: ACTIVE
**Category**: core
**Created**: 2026-08-03

**Covers**: `.github/workflows/smoke.yml` (linter jobs only), `skills/skill-lint/SKILL.md` (CI-caller note only), `skills/docs-drift/SKILL.md` (CI-caller note only), `skills/release/SKILL.md` (referenced, unchanged)

---

## Overview

Two deterministic, LLM-free structural linters — skill-lint (SPEC-021, checks C1–C5)
and docs-drift (SPEC-010, checks D1–D8) — today run only as `/release` pre-commit gates
(`skills/release/SKILL.md` Steps 4.8 and 4.9). A contributor working outside the release
flow (any push or pull request) gets no automated signal from either linter; a C1–C5
skill-bash defect or a D1–D8 docs-drift regression ships to `master` undetected until the
next `/release`, where it blocks the release instead of the PR that introduced it.
SPEC-030 already added `.github/workflows/smoke.yml` and wired the smoke harness into CI,
but deliberately scoped itself to the smoke harness only. This spec governs the missing
piece: both linters MUST run in CI on every push and pull request to `master`, with
invocation parity to `/release` Steps 4.8/4.9, so the PR that introduces a violation is the
check that fails. It owns only the CI wiring and structural properties (fail-the-build,
always-run, distinguishable); the check definitions and exit-code contracts remain owned by
SPEC-021 and SPEC-010 respectively, and `/release` behavior is untouched.

## MUST

- CI MUST invoke `bash skills/skill-lint/check-skill-bash.sh` with no flags, from the repo
  root, on every `push` and `pull_request` targeting `master` — byte-identical invocation to
  `skills/release/SKILL.md` Step 4.8.
- CI MUST invoke `bash skills/docs-drift/check-docs-drift.sh` with no flags, from the repo
  root, on every `push` and `pull_request` targeting `master` — byte-identical invocation to
  `skills/release/SKILL.md` Step 4.9.
- A non-zero exit from either linter MUST produce a failing CI check on the pull request
  (build fails). Exit `0` MUST pass; the linters' own exit contract (`0` clean, `1` findings,
  `64` usage — SPEC-021 / SPEC-010) MUST be surfaced unchanged, not remapped.
- Both linters MUST always run in the same CI trigger: one linter failing MUST NOT skip or
  short-circuit the other. (A short-circuiting sequence of steps in a single job does not
  satisfy this; separate jobs, or steps guarded to always execute, do.)
- skill-lint and docs-drift MUST surface as separately named CI jobs/steps, distinguishable
  from each other and from the existing `tools/smoke/run.sh` step — not merged into the smoke
  step or into one another.
- Waivers MUST be honored in CI identically to `/release`: an inline `# lint-ok: <id>`
  (skill-lint) or `<!-- drift-ok: <check-id> -->` (docs-drift) that suppresses a finding under
  `/release` MUST suppress the same finding in CI. (This is inherent to invoking the same
  script with the same no-arg discovery; the spec forbids any CI-only flag or env that would
  alter waiver handling.)
- `skills/skill-lint/SKILL.md` and `skills/docs-drift/SKILL.md` MUST each document CI
  (`.github/workflows/smoke.yml`) as a caller alongside `/release` Step 4.8 / 4.9.

## MUST NOT

- MUST NOT modify `skills/release/SKILL.md` Steps 4.8/4.9, nor the behavior, arguments, or
  exit codes of `check-skill-bash.sh` / `check-docs-drift.sh` / their `.py` backends.
- MUST NOT pass any flag or `--root` override to either linter in CI (no-arg discovery only,
  preserving parity with `/release`).
- MUST NOT alter the workflow's existing smoke job or its trigger.

## SHOULD

- SHOULD implement the two linters as sibling jobs (parallel, independent) to satisfy
  always-run + distinguishable with the least workflow logic, keeping the smoke job a third
  sibling.
- SHOULD use stable, human-legible job names (e.g. `skill-lint`, `docs-drift`) because those
  names become the identifiers a maintainer selects when marking required status checks in
  branch protection.

## Test

- [ ] With a seeded C1–C5 skill-bash violation on a branch, the `skill-lint` CI job exits
      non-zero and reports a failing check; the `docs-drift` job still runs.
- [ ] With a seeded D1–D8 docs-drift violation, the `docs-drift` CI job exits non-zero; the
      `skill-lint` job still runs.
- [ ] On a clean tree, both linter jobs and the smoke job pass (exit 0), and appear as three
      distinct checks.
- [ ] A finding suppressed by a valid `# lint-ok:` / `<!-- drift-ok: -->` waiver does not fail
      the corresponding CI job (parity with `/release`).
- [ ] `git diff` shows `skills/release/SKILL.md` and both linter scripts/`.py` backends
      unchanged.

## Validation

- [x] Spec reviewed and promoted to ACTIVE

## Open Questions

- Branch-protection required-status-check registration is a GitHub repo-settings action
  (`gh api` / branch-protection UI), not a file in this repo; no workflow YAML can mark a
  check "required". Resolved for this ticket as a documented manual follow-up (ship notes),
  not an automated step — see plan.

## Cross-references

- SPEC-021 (skill-lint) — owns C1–C5 check definitions and the linter exit contract.
- SPEC-010 (docs-drift) — owns D1–D8 check definitions and the linter exit contract.
- SPEC-030 (smoke harness gate) — owns `.github/workflows/smoke.yml` creation and the smoke
  job; this spec adds sibling linter jobs to the same file.

## Version History

| Date | Change |
|------|--------|
| 2026-08-03 | Initial version |
