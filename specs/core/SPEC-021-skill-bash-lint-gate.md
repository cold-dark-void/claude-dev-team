# SPEC-021: Skill-Bash Lint Gate

**Status**: DRAFT
**Category**: core
**Created**: 2026-07-03

**Covers**: `skills/skill-lint/check-skill-bash.sh`, `skills/skill-lint/SKILL.md`, `skills/skill-lint/fixtures/`, `skills/release/SKILL.md` (gate step only)

## Overview

This plugin is prompts-as-code: its executable logic lives inside fenced ```bash blocks
in `commands/*.md`, `skills/**/*.md`, and `agents/*.md`. The 2026-06 consolidation-audit
arcs showed that a small set of bash-block defect classes recurred **despite each being
individually documented as a lesson after it first bit**: variables used in a block but
defined only in a different block (blocks run as separate shells), zsh history-expansion
mangling of `!`/`<!--` in executed text, zsh-fatal unguarded globs that match nothing,
and command substitution capturing a `sqlite3` call whose SQL opens with an inline
`PRAGMA` assignment (emits a value row on sqlite ≥3.51.2, poisoning the captured read).
Every one of these is mechanically detectable by static inspection. This spec defines a
deterministic, LLM-free linter (`check-skill-bash.sh`) that scans fenced bash blocks for
these classes, and wires it into `/release` as a pre-commit gate — converting one-off
lessons into permanent enforcement. Gate ownership follows the SPEC-013 (template-vars)
and SPEC-002 (hook-templates) precedent: the gate contract lives here; `/release` hosts
the invocation step. Known scope overlap with SPEC-008 is resolved by exclusion — see
Out of Scope.

## MUST

### CLI contract

- MUST ship `skills/skill-lint/check-skill-bash.sh` as a pure-subprocess CLI (bash + python3 only, no LLM, no network), invoked from any cwd
- MUST exit `0` when no unwaived findings exist, `1` when at least one unwaived finding exists, `64` on usage error
- MUST NOT execute any scanned code (static analysis only) and MUST NOT modify any scanned file
- MUST print each finding as one line in the form `<file>:<line>: [<check-id>] <message>` where `<line>` is the line number in the source `.md` file (not the offset within the extracted block)

### Scan coverage

- MUST, in the no-argument form, scan every fenced ```bash block in `commands/**/*.md`, `skills/**/*.md`, `agents/**/*.md`, and `AGENTS.md` under the repo root
- MUST support an explicit file-list argument form (`check-skill-bash.sh <file>...`) that scans only the named files
- MUST ignore fenced blocks whose info string is not `bash` (e.g. ```sql, ```json, ```markdown) and text outside fenced blocks

### Check classes

- MUST flag **C1 (cross-block variable scope)**: a variable expanded in a fenced bash block (`$VAR` / `${VAR}`) that is defined in a *different* bash block of the same file but not in the expanding block. Definitions include assignment, `for` loop variables, `read` targets, function parameters, and `export`. An allowlist exempts environment-provided variables (at minimum `HOME`, `PATH`, `PWD`, `TMPDIR`, `OLDPWD`, `CLAUDE_PROJECT_DIR`, shell specials `$?`, `$!`, `$$`, `$@`, `$*`, `$#`, `$0`-`$9`, `$_`)
- MUST flag **C2 (zsh history-expansion hazard)**: a `!` immediately followed by a word character inside a heredoc body or quoted string within a bash block, and any `<!--` literal anywhere in a bash block — excluding `!=` comparisons, `[ ! ` / `if ! ` / `while ! ` negations, `#!` shebangs, and `$!`. The finding message MUST name the remedy (author the content via the Write tool, or build `!` as `chr(33)`)
- MUST flag **C3 (zsh-fatal unguarded glob)**: an unquoted glob pattern used as a `for`-loop word list or command argument with no surrounding no-match guard, where an empty match aborts the block under zsh. The finding message MUST name the remedy (`find -maxdepth 1 -name` iteration or an explicit existence check)
- MUST flag **C4 (captured inline-PRAGMA sqlite poison)**: command substitution `$( sqlite3 ... )` where the SQL string begins with `PRAGMA <name>=<value>;` followed by further statements. The finding message MUST name the remedy (`sqlite3 -cmd ".timeout N"` or a plain statement without the inline PRAGMA). Uncaptured heredoc/multi-line sqlite3 invocations MUST NOT be flagged

### Waivers

- MUST suppress a finding when the offending line, or the line immediately above it within the same block, carries a waiver comment `# lint-ok: <check-id>[,<check-id>...]` naming that check
- MUST count waived findings and print a one-line summary (`N findings, M waived`) — waivers are visible, never silent
- A waiver naming one check-id MUST NOT suppress findings of a different check on the same line

### Release gate wiring

- `/release` MUST run `check-skill-bash.sh` (no-argument form) as a pre-commit gate step alongside the existing include/template-var/hook-template gates; a non-zero exit MUST block commit and tag until the finding is fixed or explicitly waived
- The change that first wires the gate MUST land with the existing tree scanning clean (every pre-existing finding fixed or waived in the same change) — the gate lands green, never red

### Bite-tests

- MUST ship fixtures under `skills/skill-lint/fixtures/`: one clean fixture and, per check class, at least one defect fixture
- MUST verify, before the gate is wired into `/release`, that each defect fixture produces exit 1 with a finding naming its check-id, and that the clean fixture produces exit 0 (a gate that merely runs clean on the live tree is not proven — it must be shown to bite)

## SHOULD

- SHOULD flag use-before-define *within* a single block (same C1 machinery, weaker signal) at warning level without affecting the exit code
- SHOULD support a `--json` flag emitting findings as a JSON array for tooling
- SHOULD complete a full no-argument scan of this repo in under 10 seconds

## MUST NOT

- MUST NOT enforce checks the lesson corpus does not evidence (no generic shellcheck ambitions — scope is the recurring prompts-as-code defect classes above)
- MUST NOT auto-fix findings (report-only; fixes are authored and reviewed like any change)

## Out of Scope

- Ordered-table monotonicity (Version History date order, line-number-ordered traceability tables) — belongs to SPEC-008's `check-format.sh`, not this linter
- Linting of standalone `.sh` files (`skills/*.sh`) — real shells with real linters; candidates for shellcheck, not this tool
- Runtime/behavioral verification of bash blocks — this is static inspection only

## Test

- [ ] Defect fixture per check class (C1, C2, C3, C4) → exit 1, finding line names the correct check-id and source line number
- [ ] Clean fixture → exit 0, no findings
- [ ] Fixture with a `# lint-ok: C3` waiver on the offending line → exit 0, summary reports 1 waived
- [ ] Waiver for C3 on a line that also trips C2 → C2 finding still reported (exit 1)
- [ ] No-argument form discovers a defect planted in each of `commands/`, `skills/`, `agents/`, and `AGENTS.md` (coverage bite-test — every globbed dir proven, per the P1-5B default-files lesson)
- [ ] Explicit file-list form scans only the named files
- [ ] `!=` comparison, `if ! cmd`, `[ ! -f ]`, and `#!` shebang inside a bash block → no C2 finding (false-positive guard)
- [ ] Uncaptured heredoc sqlite3 with leading PRAGMA → no C4 finding; captured `$(sqlite3 "PRAGMA busy_timeout=5000; SELECT ...")` → C4 finding
- [ ] Full no-arg run on this repo exits 0 after the initial fix/waive pass
- [ ] `/release` dry run with an injected C1 defect → release blocked at the gate step

## Validation

- [ ] All bite-tests above pass (each gate class proven to bite, not just run clean)
- [ ] Initial adoption pass complete: live tree scans clean; every waiver reviewed as genuinely safe
- [ ] Gate step added to `skills/release/SKILL.md` and exercised by one real release
- [ ] Spec reviewed and promoted to ACTIVE

## Version History

| Date | Change |
|------|--------|
| 2026-07-03 | Initial version (DRAFT). ID 021: SPEC-020 is allocated to /craft-loop on its own feature branch. |

## Cross-references

- SPEC-002 — plugin infrastructure; hook-template drift gate precedent (gate owned by domain spec, hosted by /release)
- SPEC-008 — spec format contract; owns `check-format.sh` and any table/format checks (see Out of Scope)
- SPEC-010 — code review & release; `/release` is the host of this gate's invocation step
- SPEC-013 — council template-var drift gate precedent
- Lesson corpus: AUDIT-P0/P1 project memory — cross-block scope (retro.md $PDH incident), zsh `!` mangling (v0.32.0 release), empty-glob fatality (P0.5), inline-PRAGMA poison (P0.8/P0.15/P0.16)
