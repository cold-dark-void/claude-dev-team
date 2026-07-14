---
name: skill-lint
description: |
    Deterministic, LLM-free linter for fenced bash blocks in plugin .md files
    (SPEC-021). Checks: C1 cross-block variable scope, C2 zsh history-expansion
    hazard, C3 zsh-fatal unguarded glob, C4 captured inline-PRAGMA sqlite poison.
    Run by /release as a pre-commit gate (Step 4.8). Not user-invoked directly;
    run manually via: bash skills/skill-lint/check-skill-bash.sh [FILE...]
---

# skill-lint

Static analysis over fenced ```bash blocks in `commands/**/*.md`, `skills/**/*.md`,
`agents/**/*.md`, and `AGENTS.md`. Governing spec: `specs/core/SPEC-021-skill-bash-lint-gate.md`.

## Usage

    bash skills/skill-lint/check-skill-bash.sh              # no-arg: full repo scan
    bash skills/skill-lint/check-skill-bash.sh FILE.md ...  # explicit file list
    bash skills/skill-lint/check-skill-bash.sh --json       # machine-readable
    bash skills/skill-lint/check-skill-bash.sh --root DIR   # override discovery root

Exit codes: 0 clean, 1 unwaived findings, 64 usage error.

## Checks

| ID | Defect class | Remedy |
|----|--------------|--------|
| C1 | Variable used in one bash block, defined only in another (blocks run as separate shells) | Re-resolve the variable in the using block |
| C2 | History-expansion-hazardous bang sequences / HTML-comment openers in heredocs and quoted strings (zsh mangles them) | Author the content via the Write tool, or build the char as chr(33) |
| C3 | Unquoted glob that aborts the block under zsh when it matches nothing | Iterate via find -maxdepth 1 -name, or guard existence |
| C4 | Command substitution capturing sqlite3 with a leading inline PRAGMA assignment (emits a value row on sqlite >= 3.51.2) | sqlite3 -cmd ".timeout N", or drop the inline PRAGMA |

## Waivers

Add `# lint-ok: C3` (comma-separate multiple IDs) on the offending line or the
line directly above it. Waived findings are counted in the summary line — never
silent. Waive only after confirming the flagged line is genuinely safe.

## Bite-tests

    bash skills/skill-lint/test.sh

Fixtures under `fixtures/` include one defect fixture per check class and a clean
fixture; the harness asserts each defect produces exit 1 naming its check-id.
