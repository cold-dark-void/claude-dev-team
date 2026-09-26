# Smoke harness

This directory holds two related, but separate, tools:

- `run.sh` (with `smoke.py`) — a load-only smoke check. It proves that every
  plugin Surface still parses. It never runs a Surface.
- `../run-all-tests.sh` — an all-suites runner. It runs every `test.sh`,
  `test-*.sh` and `*-test.sh` suite in the repo.

Both tools are deterministic and LLM-free. Contract: SPEC-030
(`specs/core/SPEC-030-smoke-harness-gate.md`).

## Smoke check (`run.sh`)

Run:

```bash
bash tools/smoke/run.sh
```

`run.sh` execs `smoke.py`. It checks four target kinds:

| Kind | Path shape | What it checks |
|------|------------|-----------------|
| Surface | `commands/*.md`, `skills/<name>/SKILL.md` | Frontmatter parses and has `name` and `description`. Every top-level ` ```bash ` fence passes `bash -n`. |
| Agent | `agents/*.md` | Frontmatter parses and has `name`, `description`, `tools`, `model`, `effort`. `model` and `effort` must hold an approved value. Bash fences parse. |
| Sub-doc | every other `skills/**/*.md` | Bash fences parse. |
| Script | every `*.sh` file, and every file under `githooks/` | The script parses (`bash -n`). |

The check is static. It never runs a fence body or a script's mutating logic.
An engine script that declares `--help` or `--check` in its own text can opt
in to an invocation check under `--invoke-flags`; a non-zero exit from that
invocation is a FAIL. This opt-in never applies to a test script (`test.sh`,
`test-*.sh`, `*-test.sh`) or a githook.

### The `bash template` opt-out

A fence that shows documentation shape, not runnable bash (for example a
fence with angle-bracket placeholders), can opt out of the `bash -n` check.
Add `template` as the second word of the fence's info string, for example a
fence opened with three backticks followed by `bash template`. Use this
opt-out only for fences that are not meant to parse as bash. Do not use it
to hide a broken fence — fix the fence instead.

### Usage

```bash
bash tools/smoke/run.sh                  # no-arg: discover and check the whole tree
bash tools/smoke/run.sh path/to/file.md  # explicit target list: check only these paths
bash tools/smoke/run.sh --invoke-flags    # also invoke declared --help/--check
```

No-arg discovery finds the Surface (`commands/*.md`,
`skills/<name>/SKILL.md`) and Agent (`agents/*.md`) sets with a
directory listing, and the Sub-doc set with a filesystem walk of
`skills/`. Only the Script set (every `*.sh` anywhere, plus every
file under `githooks/`) walks `git ls-files --cached --others
--exclude-standard` (tracked plus untracked-not-ignored files); when
the root is not a git work tree (for example a `--root` fixture
tree), Script discovery falls back to a sorted filesystem walk with
the same exclusions instead. Every kind excludes any path with a
`fixtures`, `.worktrees` or `node_modules` segment. Fixture files
under `tools/smoke/fixtures/` exist to prove the check bites; they
are never part of a real scan.

### Exit codes

- `0` — every checked target passed.
- `1` — at least one target failed.
- `64` — usage error (for example, an explicit target that does not exist).

### Fixtures

`tools/smoke/fixtures/` holds one clean and one broken example of each target
kind (frontmatter, bash fence, agent field, script, githook, test script).
The bite-tests in `test.sh` assert each broken fixture fails with a named
reason and each clean fixture passes. Fixtures are excluded from real scans
(see above) so they never pollute a live-tree result.

## All-suites runner (`../run-all-tests.sh`)

Run:

```bash
bash tools/run-all-tests.sh
```

The smoke check proves a Surface or script *parses*. The all-suites runner
goes one step further: it *runs* every test suite in the repository and
reports pass, fail, timeout, quarantine and skip.

### Usage

```bash
bash tools/run-all-tests.sh              # discover and run every suite
bash tools/run-all-tests.sh --root DIR   # scan and run from DIR instead of the cwd's repo root
bash tools/run-all-tests.sh --list       # print discovered suite paths, one per line; run nothing
bash tools/run-all-tests.sh -h           # usage
```

Discovery finds every path whose basename matches `test.sh`, `test-*.sh` or
`*-test.sh` via `git ls-files --cached --others --exclude-standard`. It
excludes any path with a `fixtures`, `.worktrees` or `node_modules` segment,
and the runner itself.

Each suite runs serially, in sorted order, as `bash <repo-relative-path>`
with the repository root as its working directory.

### `RUN_ALL_TESTS_TIMEOUT`

Set this environment variable to change the per-suite wall-clock timeout in
seconds (a positive integer). Default: `300`. On expiry, the runner sends
`TERM` to the suite's whole process group, then `KILL` after a 5-second
grace period, and reports `TIMEOUT`.

### Output

One line per suite:

```
PASS|FAIL|TIMEOUT|QUARANTINED|SKIP <path> [(<detail>)]
```

After a `FAIL`, `TIMEOUT` or `QUARANTINED` line, the runner prints the last
20 lines of the suite's combined output, each prefixed `    | `. The final
line is a summary: `N suites: P passed, F failed, T timed out, Q
quarantined, S skipped`. Warnings go to stderr with a `warn:` prefix.

### Quarantine format

The quarantine file is `tools/test-quarantine.txt` (repo-relative to
`--root`). An absent file means an empty quarantine. Blank lines and lines
whose first non-blank character is `#` are comments. Every other line is:

```
<repo-relative suite path><whitespace><reason>
```

Each reason must name the failing assertion or missing dependency, with a
file:line or tool name. List only a suite measured red in CI — never copy an
entry from a seed list, and never list a suite that a dedicated
`smoke.yml` job already runs.

A quarantined suite still runs. A FAIL, TIMEOUT, or working-tree-modified
outcome is reported as `QUARANTINED` and does not affect the exit code. A
quarantined suite that passes is reported as `PASS` plus a stderr `warn:`
line, telling the operator to remove the stale entry.

### Exit codes

- `0` — no non-quarantined suite failed or timed out.
- `1` — at least one non-quarantined suite failed or timed out.
- `64` — usage error: an unknown argument, a `--root` that is not a git work
  tree, an invalid `RUN_ALL_TESTS_TIMEOUT`, or a malformed quarantine file.
- `77` (per suite, not for the runner as a whole) — the autotools skip
  convention. A suite that exits `77` is reported `SKIP` and never blocks.

### Suite hygiene

A discovered suite must not leave tracked or untracked-not-ignored changes
in the checkout it runs from. The runner snapshots `git status --porcelain
--untracked-files=all` before and after each suite; a difference is a FAIL,
even on exit 0. A suite that needs a "live tree" to test against must inject
into a scratch copy of the checkout, never into the checkout itself.

A suite must also leave these unchanged. The runner cannot see them, so the
suite design must keep them clean:

- The real `$MROOT/.claude/` directory. It is gitignored. Run an engine that
  resolves `$MROOT` from a `mktemp -d` git repo.
- The caller's `TMPDIR`.
- The real `HOME`.

To isolate `TMPDIR` and `HOME`, source `tests/lib/hermetic.sh` and call
`hermetic_init` before any other work:

```bash
. "$ROOT/tests/lib/hermetic.sh"
hermetic_init
```

`hermetic_init` makes one temp root. It points `TMPDIR` and `HOME` into that
root and sets a fixed git identity. It removes the root on exit. If your suite
sets its own `EXIT` trap, call `hermetic_cleanup` from that trap.

### Skip protocol

A suite exits `77` when its environment lacks a precondition. The runner
reports `SKIP` and does not block. Use a skip for two causes only:

- A required command is not on `PATH`.
- The uid is root, and the suite depends on permission bits.

Any other cause is a defect. A missing repo file, a generated file that a
clean checkout does not have, or a failed assertion is a `FAIL`. Do not add
a quarantine entry for an environment cause.

Source `tests/lib/skip.sh` to get the two helpers. Each prints one `SKIP:`
line on stderr and exits `77`:

```bash
. "$ROOT/tests/lib/skip.sh"
require_cmd sqlite3 jq          # whole-suite skip; call it first
if ( skip_if_root "case 4 chmod" ); then
  : # this case runs only when the uid is not root
fi
```

Run a helper in a subshell to skip one case. The suite then continues.

Full contract: `specs/core/SPEC-030-smoke-harness-gate.md`, sections "All-suites
runner — CLI" through "All-suites runner — skip protocol and hermetic helpers"
(R1-R21).
