---
name: skill-lint
description: |
    Deterministic, LLM-free linter for fenced bash blocks in plugin .md files
    (SPEC-021). Checks: C1 cross-block variable scope, C2 zsh history-expansion
    hazard, C3 zsh-fatal unguarded glob, C4 captured inline-PRAGMA sqlite poison,
    C5 PDH bootstrap-stanza drift, C6 root variable read before it is assigned in
    the same block, C10 comment or waiver that changes the command (after a
    `\` continuation, inside an open quote).
    Run by /release as a pre-commit gate (Step 4.8), and also by CI
    (.github/workflows/smoke.yml, job `skill-lint`) on every push/PR to master —
    same invocation, same exit contract. Not user-invoked directly; run manually
    via: bash skills/skill-lint/check-skill-bash.sh [FILE...]
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
| C5 | A `PDH=$(` line that is not byte-identical (after leading-whitespace strip) to SPEC-002's canonical bootstrap stanza | Copy the stanza verbatim from SPEC-002 "Locating `plugin-dir.sh` itself" |
| C6 | `$MROOT`, `$WTROOT`, `$MEMDB`, `$PLUGIN_DIR`, `$PDH` or `$EXT_DIR` read in a block before the first assignment of that name in the same block (every block is a separate shell, so the read is empty and `MEMDB` becomes `/.claude/memory/memory.db`) | Assign in this order inside the block: `_gc`/`MROOT`, then `WTROOT`, then `MEMDB`, then `USE_DB` |
| C10 | A `\` followed by blanks (an escaped space, not a continuation); a `#` comment line right after a `\` continuation; `# lint-ok:` inside an open quote; a `#` that starts a word inside an open quote while a `sqlite3` command runs | Put the comment or waiver on its own line above the command, or remove the need for it (assign the variable in the block) |

C6 and C10 run in `fence-state.awk` (bash + awk only). `check-skill-bash.sh` runs `lint.py`
first, then `fence-state.awk` over the same file set, and prints one merged report: finding
lines, one `N findings, M waived` summary, one `--json` array and one exit code. If the awk
engine fails, the run exits 1 — it never reads as clean. C6 reports the first read of each
name per block and only when that block assigns the name later; a block that never assigns the
name is C1's job. Reads in comments, in single quotes and in quoted heredoc bodies are not reads.
C10 does not scan heredoc bodies.

`fence-scan.awk` is the one awk fence parser: `fence-state.awk` and the fence-exec harness
(`tools/fence-exec/`) both run on it, and `scan-set.sh` is the one no-argument file list for
`check-skill-bash.sh` and the harness. Do not write a second fence-opener match in an engine.

C5 reads its canonical text from `specs/core/SPEC-002-plugin-infrastructure.md` at
runtime, anchored on that section heading — SPEC-002 holds more than one fenced bash
block, so a "first block in the file" anchor would compare every emission against the
wrong text and still exit 0. If the canonical block cannot be located or parsed while a
`PDH=$(` line exists in the scan set, the run exits non-zero with `error: [C5] canonical
stanza not resolvable — …` on stderr. That error is unwaivable by design: a waiver there
would re-hide the vacuity the guard exists to expose. `skills/plugin-dir.sh` (cannot
bootstrap itself) and `skills/plugin-dir-test.sh` (holds no stanza copy at all — it
extracts the canonical text from SPEC-002 at runtime, per CDT-232; the exclusion is
retained as a no-op) are exempt.

## Waivers

Add `# lint-ok: C3` (comma-separate multiple IDs) on the offending line or the
line directly above it. Waived findings are counted in the summary line — never
silent. Waive only after confirming the flagged line is genuinely safe.

A waiver must never sit where it changes the command:

- After a `\` continuation the waiver ends the command. Put it on its own comment line above
  the command, or remove the finding at its source.
- Inside an open quote, for example a multi-line `sqlite3` SQL string, the waiver becomes part
  of the string. Fix the cause instead: assign the variable in the block so the finding goes away.
- C10 cannot be waived at all. A waiver there would hide the defect it reports.

## Bite-tests

    bash skills/skill-lint/test.sh

Fixtures under `fixtures/` include one defect fixture per check class and a clean
fixture; the harness asserts each defect produces exit 1 naming its check-id.
