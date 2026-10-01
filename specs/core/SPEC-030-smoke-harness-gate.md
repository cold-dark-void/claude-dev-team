# SPEC-030: Smoke Harness and All-Suites Gate

**Status**: ACTIVE
**Category**: core
**Created**: 2026-07-21

**Covers**: `tools/smoke/run.sh`, `tools/smoke/smoke.py`, `tools/smoke/test.sh`, `tools/smoke/fixtures/`, `tools/smoke/README.md`, `tools/run-all-tests.sh`, `tools/run-all-tests-test.sh`, `tools/test-quarantine.txt`, `tools/ci-workflow-test.sh`, `tools/fence-exec/run.sh`, `tools/fence-exec/fence-check.awk`, `tools/fence-exec/manifest.tsv`, `tools/fence-exec/test.sh`, `tools/fence-exec/fixtures/`, `skills/refactor/test-fences.sh`, `skills/retro-gate/test-retro-fences.sh`, `tests/lib/skip.sh`, `tests/lib/hermetic.sh`, `tests/lib/trailing-flag.sh`, `tests/lib/test.sh`, `skills/skill-lint/test-command-fences.sh`, `.github/workflows/smoke.yml`, `skills/release/SKILL.md` (Steps 4.10 and 4.13 only)

## Overview

This plugin is prompts-as-code: every user-invocable Surface is a markdown file with
YAML frontmatter (`commands/*.md`, `skills/*/SKILL.md`) whose executable logic lives in
fenced ```bash blocks, plus standalone engine `.sh` scripts under `skills/**`. Today there
is no deterministic behavioral gate for any of these: `/release` runs lint-level structural
gates (SPEC-021 skill-bash, SPEC-010 docs-drift) that catch defect *classes* and structural
drift, but nothing asserts that a Surface still *loads* — that its frontmatter parses, that
its bash fences are syntactically valid, and that its engine scripts parse. As the v1.0
program (CDT-46) cuts and merges Surfaces, an accidental frontmatter break or a bash syntax
error introduced during a merge would ship undetected until a user invoked the broken
command. This spec defines a deterministic, LLM-free smoke harness (`tools/smoke/run.sh`)
that dynamically discovers the Surface set and asserts each one loads without error, wires
it into `/release` as a pre-commit gate (Step 4.10, after docs-drift), and runs it in CI on
every push and pull request targeting master.

The harness lives under `tools/` — deliberately **outside** `commands/` and `skills/` — so
it is not itself a loaded Surface (both loaded dirs ship to all users; a test harness must
not). This mirrors the v1 relocation of `scout-plugins` to `tools/`. Gate ownership follows
the SPEC-021 (skill-bash), SPEC-013 (template-vars) and SPEC-002 (hook-template) precedent:
the gate contract lives here; `/release` hosts the invocation step.

"Loads without error" is defined narrowly and deterministically (see MUST → Check set). It is
**static** — the harness never executes a discovered Surface's bash blocks or an engine
script's body (beyond an explicit opt-in `--help`/`--check` invocation where a script declares
support). It is not runtime/behavioral verification of what a command *does*.

**All-suites runner (WP 1-01, CDT-269).** The repo carries ~76 bash test suites
(`test.sh`, `test-*.sh`, `*-test.sh`), but CI ran only the few wired as dedicated
`smoke.yml` jobs. This spec also owns `tools/run-all-tests.sh`: one discovering runner that
executes every suite, a reasoned quarantine file for the suites that are red in CI today,
a `smoke.yml` `all-tests` job, and `/release` Step 4.13. The contract home is this spec
(not SPEC-010) because this spec already owns `smoke.yml`, the `tools/` test harnesses and
the "gate contract here, `/release` hosts the step" pattern. SPEC-010 carries a one-line
Step 4.13 pointer only. Smoke *parses* test scripts; the runner *runs* them.

**Skip protocol and hermetic suites (WP 1-02, CDT-270, CDT-419, W1-34, W1-35).** WP 1-01
seeded the quarantine with six suites that were red in CI. WP 1-02 fixed them and emptied
the file. This spec also owns the suite-side contract that keeps the file empty: one
exit-77 skip protocol for environment causes (`tests/lib/skip.sh`, R18-R20), and hermetic
suites that do not touch the real `$MROOT/.claude/`, the caller's `TMPDIR` or the real
`HOME` (`tests/lib/hermetic.sh`, R16). A skip is for a missing tool or a root uid only. A
repo-state cause (a missing generated file, a stale grep, a live-repo write) is a defect
to fix, never a skip.

**Fence-exec harness (WP 2-01, CDT-272, CDT-356).** The largest defect class in this
plugin sits in fenced bash inside LLM-facing markdown, and each fence runs in a fresh
shell. A function, a trap or a variable from an earlier fence does not exist in the next
one. Smoke checks that a fence parses (`bash -n`) and skill-lint (SPEC-021) checks
variable scope. Neither checks function scope, a `trap ... EXIT` that must outlive its
fence, a top-level `return` or a path literal, and neither runs a fence. This spec also
owns `tools/fence-exec/run.sh` (R23-R30): per-fence static checks F1-F5, a manifest that
ties fences to the suites that run them against fixtures, reasoned exclusions for known
defects that other work packages own, and the `fence-exec` CI job. It runs on the skill-lint
fence parser and scan set (SPEC-021). The two "static only" rules below bind the smoke
harness; the fence-exec harness runs a fence only through a manifest suite.

## MUST

### CLI contract

- MUST ship `tools/smoke/run.sh` as a pure-subprocess CLI (bash + python3 only, no LLM, no network), invoked from any cwd, that `exec`s `tools/smoke/smoke.py`
- MUST exit `0` when every discovered target passes its check set, `1` when at least one fails, `64` on usage error (invalid flag; or an explicit target list where every named path is missing/unreadable)
- MUST NOT modify any discovered or scanned file
- The smoke harness MUST NOT execute a discovered `.md` file's bash blocks (frontmatter parse + `bash -n` syntax check only); MUST NOT execute a script's body except the explicit opt-in `--help`/`--check` invocation permitted below. The fence-exec harness (R23-R30) runs a fence only through a manifest suite
- MUST print one `PASS <path>` or `FAIL <path>: <reason>` line per checked target, and a final one-line summary (`N checked, M failed`)
- MUST skip an unreadable path with a `warn:` line on stderr and continue (a mix of readable + unreadable targets is not a usage error)

### Discovery

- MUST, in the no-argument form, dynamically discover four target kinds under the repo root — never a hardcoded list (the kept set changes across releases; discovery MUST reflect the live tree):
  - **Surface**: every `commands/*.md` and every `skills/<name>/SKILL.md`
  - **Agent**: every `agents/*.md`
  - **Sub-doc**: every other `*.md` under `skills/**` (for example `skills/orchestrate/steps/*.md`, `skills/autopilot/end-state.md`)
  - **Script**: every `*.sh` anywhere in the repo, test scripts included (`test.sh`, `test-*.sh`, `*-test.sh`, root `install*.sh`, `tools/**/*.sh`), plus every file under `githooks/`
- MUST, when the root is a git work tree, take the Script set from `git ls-files --cached --others --exclude-standard` (tracked plus untracked-not-ignored), skipping listed paths absent on disk; when the root is not a git work tree (fixture trees under `--root`), MUST fall back to a sorted filesystem walk with the same exclusions
- MUST exclude from every kind any path with a `fixtures`, `.worktrees` or `node_modules` path segment (the harness's own fixtures live under `tools/smoke/fixtures/` and must not self-fail the gate)
- MUST support an explicit target-list form (`run.sh <path>...`) that checks only the named paths. Each path is classified by its repo-relative path shape (relative to the resolved root — never the raw absolute path, whose ancestry above the root could itself contain a `skills`, `agents` or `githooks` segment and false-match): a `.sh` file or a file whose parent directory is `githooks` → Script; a `.md` whose parent directory is `agents` → Agent; a `.md` below a `skills` segment that is not `skills/<name>/SKILL.md` → Sub-doc; any other `.md` → Surface. No-arg discovery MUST use the same classifier on the same repo-relative shape
- MUST resolve the repo root for no-arg discovery from `git rev-parse --show-toplevel`, falling back to cwd when that fails (mirrors `skills/skill-lint/lint.py` discovery), and accept a `--root DIR` override
- MUST emit targets in a deterministic order (sorted within each kind)

### Frontmatter parser

- MUST parse the frontmatter subset the plugin uses: flat `key: value`, quoted scalars, block scalars (`key: |` / `key: >`), and YAML block sequences (`key:` followed by `- item` lines, at column 0 or indented). A block-sequence value is non-empty iff at least one item has content
- MUST report any other structural defect (no opening `---`, no closing `---`, an unparseable top-level line) as a FAIL naming the line

### Check set — Surface (`.md`)

- MUST verify the file begins with a YAML frontmatter block delimited by `---` lines and that the block parses as a mapping — FAIL if absent or unparseable
- MUST verify the frontmatter contains a non-empty `name` field and a non-empty `description` field — FAIL if either is missing or empty (these are the two fields Claude Code requires to load a command/skill; every current Surface has both)
- MUST extract every fenced ```bash block (using the SPEC-021 fence semantics: a fence is bash iff the first whitespace-delimited info-string token is exactly `bash`; only depth-0 fences; a backticked line with an info string inside an open fence is content) and run each through `bash -n` (parse-only, no execution) — FAIL naming the block's source line range on any `bash -n` non-zero
- MUST skip the `bash -n` syntax check (only) for a fence whose info string is `bash template` — i.e. the second whitespace-delimited info-string token is exactly `template`. Documentation-shape fences (angle-bracket `<placeholder>` fill-ins, elided-body pseudocode) that intentionally are not valid bash carry this marker. The fence's first token stays `bash`, so it remains bash-classified: SPEC-021 `skill-lint` still lints it for the C1–C4 defect classes (coverage unaffected). Frontmatter checks are unaffected by the marker. A bare `bash` fence that fails `bash -n` is still a FAIL — the marker is an explicit author opt-out, never inferred
- MUST treat a Surface with valid frontmatter and zero bash blocks as PASS (many command `.md` files are pure prompt text — absence of bash is not a failure)

### Check set — Agent (`agents/*.md`)

- MUST apply the Surface frontmatter parse and the Surface fence check (including the `bash template` opt-out)
- MUST verify the frontmatter carries all five SPEC-003 agent fields: `name` and `description` (non-empty), `tools` (key present; the value MAY be empty — `council-judge` ships `tools: ""`), `model` and `effort`
- MUST verify `model` ∈ {`opus`, `sonnet`, `haiku`} and `effort` ∈ {`low`, `medium`, `high`, `xhigh`} — FAIL naming the field and the bad value
- MUST NOT compare `model`/`effort` against the SPEC-003 Tier table (value domain only; the Tier table is SPEC-003's to enforce)

### Check set — Sub-doc (`skills/**/*.md`, not `SKILL.md`)

- MUST apply the Surface fence check (including the `bash template` opt-out) to every bash fence
- MUST NOT require frontmatter (a Surface loads a sub-doc by reference; Claude Code does not load it directly)

### Check set — Script (`*.sh`, `githooks/*`)

- MUST run each discovered script through `bash -n` (parse-only) — FAIL on non-zero, naming the script path and the `bash -n` stderr
- MAY additionally invoke a non-test, non-githook script with `--help` or `--check` **only when** the harness runs with `--invoke-flags` and the script's own text declares support for that flag (a literal `--help`/`--check` token appears in the file); when invoked, a non-zero exit is a FAIL. Scripts that do not declare the flag, test scripts and githooks MUST NOT be invoked (their bodies mutate state)

### Determinism / environment

- MUST NOT read or write outside the repo tree except via `$TMPDIR`/`mktemp -d`; MUST NOT hardcode `/tmp` (the repo's own `worktree-lib-test.sh` produced 20/32 spurious sandbox FAILs from hardcoded `/tmp` — the harness and its test must be sandbox- and CI-runner-portable)
- MUST use `bash -n` (not `zsh -n`) for syntax checks so results match the GitHub Actions Ubuntu-bash runner and the existing `/release` gates, even though fences are authored with zsh idioms
- MUST require no network, no secrets, and no Claude API — the gate is fully offline and deterministic on any bash + python3 host

### CI wiring

- `.github/workflows/smoke.yml` MUST trigger on `push` to master AND `pull_request` targeting master (this repo ships releases directly to master with no PR flow; a push trigger is required for the gate to actually run on the real release path — a pull_request-only trigger would never fire)
- The workflow MUST check out the repo and run `bash tools/smoke/run.sh` (no-arg form), and the job MUST fail (non-zero) iff the harness exits non-zero (propagate the exit code; do not swallow it)

### Release gate wiring

- `/release` MUST run `bash tools/smoke/run.sh` (no-argument form) as a pre-commit gate step (Step 4.10, after the Step 4.9 docs-drift gate); a non-zero exit MUST block commit and tag until the failing target is fixed
- The change that first wires the gate, and every change that widens discovery, MUST land with the existing tree passing clean — the gate lands green, never red. For the WP 1-01 widening: documentation-shape fences are marked `bash template` (`skills/autopilot/end-state.md` fences 3–5, `skills/orchestrate/steps/08-execute.md` fence 2, `skills/orchestrate/steps/09-review.md` fence 2); a fence that is broken bash (for example the indented heredoc terminator in `agents/project-init.md`) is fixed, never marked

### Bite-tests

- MUST ship fixtures under `tools/smoke/fixtures/`: one clean Surface, one broken-frontmatter Surface (missing `description`, or unparseable YAML), one broken-bash-fence Surface, one broken engine script, one clean agent, one agent missing `effort`, one agent with an out-of-domain `model`, one agent whose `tools` is a YAML block sequence (PASS), one broken githook, and one broken test script (`*-test.sh` that fails `bash -n`)
- MUST verify that each broken fixture produces exit 1 with a FAIL line naming it and the defect, and that each clean fixture produces exit 0 — a gate that merely runs clean on the live tree is not proven; it MUST be shown to bite (SPEC-021/SPEC-002 hook-template bite-test precedent)
- MUST verify no-arg discovery of the new kinds: a `--root` run on a mktemp tree that holds a broken `agents/*.md`, a broken `githooks/*` file, a broken `*-test.sh` and a broken sub-doc fence reports a FAIL for each

### All-suites runner — CLI

- R1. MUST ship `tools/run-all-tests.sh` as a pure-subprocess bash CLI (bash, git and POSIX utilities only; no python3/node in the runner itself — suites MAY need them), runnable from any cwd
- R2. MUST accept `--root DIR` (default: `git rev-parse --show-toplevel` of the cwd), `--list` (print the discovered suites, one per line, run nothing, exit 0) and `-h`/`--help` (usage on stdout, exit 0)
- R3. MUST exit `0` when no non-quarantined suite fails or times out, `1` when at least one does, and `64` on usage error: an unknown argument, a `--root` that is not a directory or not a git work tree, an invalid `RUN_ALL_TESTS_TIMEOUT`, or a malformed quarantine file (R11)

### All-suites runner — discovery

- R4. MUST discover suites from `git -C <root> ls-files --cached --others --exclude-standard` (tracked plus untracked-not-ignored, so a new suite runs before it is staged): every path whose basename matches `test.sh`, `test-*.sh` or `*-test.sh`. MUST exclude any path with a `fixtures`, `.worktrees` or `node_modules` segment, and the runner itself. MUST skip listed paths absent on disk. MUST de-duplicate and sort bytewise (`LC_ALL=C`)
- R5. MUST NOT carry a hardcoded suite list

### All-suites runner — execution

- R6. MUST run each suite as `bash <repo-relative-path>` with cwd = root and stdin from `/dev/null`, serially, in the R4 order; the suite inherits the runner's environment
- R7. MUST enforce a per-suite wall-clock timeout of `RUN_ALL_TESTS_TIMEOUT` seconds (a positive integer; default `300`). On expiry it MUST send TERM to the suite's whole process group, then KILL after a 5 s grace, and record TIMEOUT. MUST NOT depend on GNU `timeout`/`gtimeout` (macOS lane, CDT-271)
- R8. MUST map suite results: exit `0` → PASS; exit `77` → SKIP (non-blocking; the autotools skip convention); timeout → TIMEOUT; any other exit → FAIL
- R9. MUST snapshot `git status --porcelain --untracked-files=all` before and after each suite; a difference is a FAIL with reason `modified the working tree`, even on exit 0 (ignored paths are not compared). This makes the runner safe to run in the release checkout (Step 4.13)

### All-suites runner — output

- R10. MUST print one line per suite that starts with its status word and the path — `PASS|FAIL|TIMEOUT|QUARANTINED|SKIP <path>` — optionally followed by ` (<detail>)` (exit code, seconds, reason). After each FAIL, TIMEOUT or QUARANTINED line it MUST print the last 20 lines of the suite's combined output, each prefixed `    | `. The final line MUST be the summary `N suites: P passed, F failed, T timed out, Q quarantined, S skipped`. Warnings go to stderr with a `warn:` prefix

### All-suites runner — quarantine

- R11. The quarantine file is `<root>/tools/test-quarantine.txt`; an absent file is an empty quarantine. Blank lines and lines whose first non-blank character is `#` are ignored. Every other line is `<path><whitespace><reason>`, where `<path>` is a repo-relative suite path exactly as R4 discovers it. The runner MUST exit `64` naming the file and line number when a line has no reason, when `<path>` is not a discovered suite (stale or mistyped entry), or when a path is listed twice
- R12. A quarantined suite MUST still run. A FAIL, TIMEOUT or R9 outcome MUST be reported as `QUARANTINED` and MUST NOT affect the exit code. A PASS MUST be reported as `PASS` plus a stderr `warn:` line that tells the operator to remove the entry. Exit `77` stays SKIP
- R13. Each entry MUST carry one concrete reason: the failing assertion or the missing dependency, with a `file:line` or tool name. The file MUST list only suites measured red in CI (re-measured, never copied from a seed list). It MUST NOT list a suite that a dedicated `smoke.yml` job runs. WP 1-02 emptied the file (header comments only); a new entry needs a fresh CI measurement. An environment cause MUST use the R18 exit-77 skip, never an entry. The runner MUST NOT edit the file

### All-suites runner — CI and release wiring

- R14. `.github/workflows/smoke.yml` MUST add a job `all-tests` (`runs-on: ubuntu-latest`, `actions/checkout`, `bash tools/run-all-tests.sh`) that fails iff the runner exits non-zero. Existing job ids MUST stay unchanged (branch-protection check names)
- R15. `/release` MUST run `bash tools/run-all-tests.sh` as Step 4.13 "All-suites gate", after Step 4.12, in the release checkout. A non-zero exit MUST block commit and tag (the Step 4.10 contract). The wiring change MUST land with the live tree exiting 0 under the seeded quarantine

### All-suites runner — suite hygiene

- R16. A discovered suite MUST NOT leave tracked or untracked-not-ignored changes in the checkout it runs from. A bite-test that needs a "live tree" MUST inject into a scratch copy of the checkout (for example `skills/docs-drift/test.sh` T6/T7), never into the checkout itself — an interrupted or timed-out run would leave the release tree mutated. A suite MUST NOT write under the real `$MROOT/.claude/` (the main checkout's gitignored state, which R9 cannot see): a suite that exercises an engine that resolves `$MROOT` from `git rev-parse --git-common-dir` MUST run that engine from a `mktemp -d` git repo. A suite MUST NOT leave files in the caller's `TMPDIR` and MUST NOT read or write the real `HOME`; a suite that runs engines which create temp files or read HOME-rooted state MUST call `hermetic_init` (R20) before any other work. The runner does not enforce these rules (R9 compares non-ignored paths only); suite design and review do
- R17. `tools/run-all-tests-test.sh` MUST prove, on mktemp git trees via `--root`: a new `*-test.sh` is run (tracked and untracked-not-ignored); `test.sh` and `test-*.sh` are run; `fixtures/`, `.worktrees/`, `node_modules/` and non-matching names are not; sorted order; PASS-only → exit 0; FAIL → exit 1; TIMEOUT with a small `RUN_ALL_TESTS_TIMEOUT` → exit 1, fast, no surviving grandchild process; exit 77 → SKIP, exit 0; quarantined FAIL → exit 0; quarantined PASS → `warn:`; each R11 malformed case → exit 64; each R3 usage case → exit 64; an R9 dirtying suite → FAIL. On the live repo it MUST assert that no `tools/test-quarantine.txt` entry is run by a dedicated `smoke.yml` job

### All-suites runner — skip protocol and hermetic helpers

- R18. MUST ship `tests/lib/skip.sh`, source-only (sourcing it has no side effect), that defines two functions. `<suite>` below is the basename of the sourcing script's `$0`:
  - `skip_if_root [<reason>]` — when `id -u` prints `0`, print `SKIP: <suite>: root uid: <reason>` on stderr and exit 77; else return 0
  - `require_cmd <cmd>...` — when `command -v` does not find a `<cmd>`, print `SKIP: <suite>: missing command: <cmd>` on stderr and exit 77; else return 0

  A whole-suite skip calls the helper at the top of the suite, before any other work. A per-case skip runs the helper in a subshell, `if ( skip_if_root "<case>" ); then <case body>; fi`: the `SKIP:` line prints, the case does not run, and the suite continues
- R19. A suite MUST exit 77 (never 0, never another non-zero code) when an environment precondition is absent: a required command is not on `PATH`, or the uid is root and the suite depends on permission bits. A suite MUST NOT exit 77 for any other cause. A missing repo file, a generated file that a clean checkout does not have, or a failed assertion is a FAIL, never a skip
- R20. MUST ship `tests/lib/hermetic.sh`, source-only, that defines `hermetic_init` and `hermetic_cleanup`. `hermetic_init` MUST create one `mktemp -d` root under the caller's `TMPDIR` (default `/tmp`), export `HERMETIC_ROOT` (that root), `TMPDIR=$HERMETIC_ROOT/tmp` and `HOME=$HERMETIC_ROOT/home` (both created), unset `XDG_CONFIG_HOME`, export fixed `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME` and `GIT_COMMITTER_EMAIL` values, and install `trap hermetic_cleanup EXIT`. `hermetic_cleanup` MUST remove `$HERMETIC_ROOT`. A suite that sets its own EXIT trap after `hermetic_init` MUST call `hermetic_cleanup` from that trap
- R21. `tests/lib/test.sh` MUST prove, with nothing run as root and nothing installed: under a `PATH` shim whose `id` prints `0`, `skip_if_root` exits 77 with a `SKIP:` line on stderr, and under a shim that prints `1000` it returns 0; `require_cmd` exits 77 naming the missing command when `PATH` lacks it, and returns 0 when all are present; the per-case subshell form prints the `SKIP:` line and the suite continues; `hermetic_init` puts `TMPDIR` and `HOME` under one root that is gone after the sourcing shell exits, on exit 0 and on a non-zero exit; the caller's `TMPDIR` holds no new entry afterwards
- R31. MUST ship `tests/lib/trailing-flag.sh`, source-only, that defines `trailing_flag_scan <script> <want_rc> [<fn>|- [<pre-arg>...]]`. A flag that takes a value and is parsed as `X="${2:-}"; shift 2` hangs the parse loop, or exits 1 with no message under `set -e`, when it is the last argument. The function MUST find each case arm that holds `shift 2`, run `bash <script> <pre-arg>... <flag>` once per flag under a 2-second `timeout` with stdin closed, and set `TF_N` (flags run), `TF_BAD` (` <flag>=<rc>` for each exit code other than `<want_rc>`; 124 is a hang) and `TF_SKIP` (1 when neither `timeout` nor `gtimeout` is on `PATH`). `<fn>` limits the search to one function body; `TF_EXEMPT` names flags with an optional value; a flag pattern with `=` or `*` is skipped. `tests/lib/test.sh` MUST prove it on a planted hanging parser (negative control), a parser with a value check, a function filter, `TF_EXEMPT` and a call that matches nothing (`TF_N=0`), and that sourcing has no side effect. A suite that uses it MUST assert `TF_N` equals the number of value flags, so an empty match cannot pass

### CI workflow hygiene

- R22. `.github/workflows/smoke.yml` MUST set a top-level `permissions: contents: read`, and no job may widen it. Every job MUST set `timeout-minutes`: `20` for `all-tests`, `10` for each other job. Every `uses:` MUST pin a full 40-hex commit SHA and carry a `# vX.Y.Z` comment that names the exact tag of that SHA (a moving major tag such as `v4` is not a pin). The `all-tests` job MUST check out with `fetch-depth: 0`, because suites read pinned base commits with `git show <sha>:<path>`. `tools/ci-workflow-test.sh` MUST assert these four rules on the live workflow. It MUST also bite: on a mktemp copy with each rule broken in turn, it reports a FAIL. The test asserts the pin **shape** only — a 40-hex SHA plus a matching `# vX.Y.Z` comment — never that the SHA and the tag actually name the same commit; confirming that needs the network, and a hermetic test MUST NOT reach it. Check the tag-to-SHA match at pin time with a read-only `git ls-remote --tags <repo> <tag>`, and record that lookup in the ship notes. MUST NOT add a network call to the test itself

### Fence-exec harness

- R23. MUST ship `tools/fence-exec/run.sh` as a pure-subprocess bash CLI (bash, awk and POSIX utilities only; no interpreter, no network). Subcommands: `list` (one TSV row per bash fence: file, first body line, last body line, nearest heading, info string), `check` (the R25 checks and the R26 manifest rules) and `run` (`check`, then the manifest suites; the default and the CI entry). Options: `--root DIR` (the repo root that F5 and the manifest resolve against; default this checkout), `--manifest FILE|none` and file arguments that replace the scan set. Exit `0` clean, `1` findings or a failed suite, `64` usage error or a malformed manifest. A failing awk engine MUST exit `1` and MUST NOT read as clean
- R24. MUST scan the skill-lint file set (`skills/skill-lint/scan-set.sh`: `commands`, `skills` and `agents` `*.md` plus `AGENTS.md`, `skills/skill-lint/fixtures` excluded) on the skill-lint fence parser (`skills/skill-lint/fence-scan.awk`; SPEC-021). MUST NOT hold its own fence-opener match or file list
- R25. MUST run these checks on each bash fence. A fence is a fresh shell, so each rule is per fence. A `bash template` fence (pseudocode) is exempt from F2, F3 and F4; F1 skips it, as smoke does; F5 still resolves its literal paths:
  - F1: `bash -n` parses the fence. The finding names the file, the failing line and the section. Smoke (`tools/smoke/smoke.py` `check_fences`) runs the same `bash -n` for `commands`, `skills` and `agents`; F1 adds `AGENTS.md` and the section name and keeps the check in the standalone guard
  - F2: a fence calls a function that only another fence of the same file defines (`name() {`, `name () {` or `function name`)
  - F3: a `trap ... EXIT` (or `trap ... 0`) in a fence that does not start with a shebang, unless its action is a plain `rm` or `rmdir` of variables that no other fence of the file reads. `trap - EXIT`, an empty action and other signals are allowed
  - F4: a `return` at command position outside a function body. A heredoc body, a comment, quoted text and an argument are not commands. A function with a subshell body, `name() ( ... )`, is not read as a function body (known limit; write the body with braces)
  - F5: a literal `$PDH/<path>`, `${PDH}/<path>`, `$CLAUDE_PLUGIN_ROOT/<path>`, `$PLUGIN_ROOT/<path>`, `plugin-dir.sh file|dir <path>` or `$PLUGIN_DIR/<leaf>` whose path does not exist under the root. A `$PLUGIN_DIR` leaf resolves against the `plugin-dir.sh dir <path>` literal that assigns `PLUGIN_DIR` in the same fence. A path with a placeholder, a glob or an expansion is not a literal and is skipped
- R26. MUST read exclusions and suite rows from `tools/fence-exec/manifest.tsv` (tab-separated; every field holds text). An `exclude` row names a check, a file, a fixed-string needle searched in the printed finding text (message plus section), an exact count, a local backlog slug and a reason. The run prints every exclusion. A row whose count does not match, or that matches nothing, is an `M1` finding, so a fixed defect or a second defect cannot hide behind it. A `suite` row names a file, a heading needle and a suite. `check` proves that the heading still holds a bash fence, that the suite basename is one that R4 discovers, and that the suite text names the heading. `run` runs each suite once as `bash <suite>` from the root (capped by `FENCE_EXEC_TIMEOUT`, default 300 s, when `timeout` exists) and prints the last 20 lines of a failing suite. A malformed row exits `64`
- R27. MUST hold the starting set in the manifest: a `suite` row for `commands/setup.md` `` Sub: `team` ``, `commands/memory.md` Step 5 (distill) and Steps 10.1 and 10.5 (validate), `skills/memory-recall/SKILL.md` Step 4, `commands/retro.md` Step 1b (scheduled), `skills/review-and-commit/SKILL.md` Step 5 (finalize) and `skills/refactor/SKILL.md` Step 1b (CDT-356). The retro row runs `skills/retro-gate/test-retro-fences.sh` and the refactor row runs `skills/refactor/test-fences.sh`. A new fence suite that follows the `tests/lib/fence.sh` pattern gets its row in the change that adds it
- R28. MUST have a `smoke.yml` job `fence-exec` (`timeout-minutes: 10` and the pinned `actions/checkout` line of the other jobs) that runs `bash tools/fence-exec/run.sh`. `tools/ci-workflow-test.sh` MUST assert it (rule B6) and bite: a workflow without the job, and a job that runs another command, each produce B6. Existing job ids stay unchanged
- R29. `tools/fence-exec/test.sh` MUST prove each check on fixtures with planted positives and negative controls (`f1-syntax.md` to `f5-root/`, `clean.md`). It MUST show that each test depends on its rule: a private copy of the harness with one rule switched off loses exactly that rule's findings. It MUST prove that the lexer stays in sync: a `return` appended to every fence of the clean fixture, and to every non-template fence of the live tree, is found in each one. It MUST cover the manifest (exclusion count, stale row, malformed rows, suite link, `run` with a passing, a failing and a duplicated suite), no-argument discovery of `commands`, `skills`, `agents` and `AGENTS.md`, and fail-closed on a broken awk. The live tree MUST exit 0. The suite is hermetic (R16) and `tools/run-all-tests.sh` discovers it (R4)
- R30. MUST NOT hide a finding without a manifest row, MUST NOT auto-fix a fence, and MUST NOT run a fence other than through a manifest suite. The two exclusion rows at WP 2-01 (`commands/retro.md`: F2 x4 and F3 x1, backlog `wp-2-10-retro-scheduled`) each leave in the change that fixes their defect (CDT-324, WP 2-10)

## SHOULD

- SHOULD complete a full no-argument smoke scan of this repo in under 15 seconds
- SHOULD emit `FAIL` reasons specific enough to locate the defect without opening the file (e.g. the `bash -n` line number, the missing frontmatter field name)
- SHOULD support a `--json` flag emitting per-target results as a JSON array for future tooling
- SHOULD keep a full `tools/run-all-tests.sh` run under 10 minutes on the CI runner (measured 2026-09-25: ~120 s on the host, ~100 s in a CI-like environment)

## MUST NOT

- The smoke harness MUST NOT execute a discovered Surface's bash blocks or a script's mutating body — static parse only, except the declared `--help`/`--check` opt-in. Running a fence belongs to the fence-exec harness (R26, R30), and only through a manifest suite
- MUST NOT hardcode the kept-Surface list — discovery is dynamic against the live tree
- MUST NOT auto-fix a failing Surface (report-only; fixes are authored and reviewed like any change)
- The runner MUST NOT run suites in parallel (suites share `$MROOT/.claude/` state), MUST NOT retry a failed suite, and MUST NOT count a quarantined outcome as passed in its summary

## Out of Scope

- **README command-index presence** (a Surface appearing in the README `## Commands` list) — this is `docs-drift`'s D1 check (SPEC-010, `/release` Step 4.9). Asserting index presence here would false-FAIL internal skills that are intentionally not user-facing and not in the README index. The smoke harness checks that a Surface *loads*, not that it is *documented*.
- Fenced-bash defect-class linting (cross-block scope, zsh `!` hazard, unguarded glob, inline-PRAGMA poison) — owned by SPEC-021 `skill-lint` (`/release` Step 4.8). Smoke asserts `bash -n` *parses*; skill-lint asserts the defect classes are absent. Complementary, non-overlapping.  Function scope across fences, `trap ... EXIT` in a fence, a top-level `return` and path literals are per-fence checks of the fence-exec harness (R25), not of skill-lint.
- Runtime/behavioral verification of what a command *does* (its outputs, side effects, agent orchestration) — the smoke harness is load-only static verification. The fence-exec harness runs only the fences that its manifest lists, against fixtures (R26, R27).
- Smoke does not *run* test scripts (it only parses them); the all-suites runner does.
- `.claude-plugin/*.json` schema validation — docs-drift `manifest-desc` covers the description field; a schema check is a separate item.
- A macOS CI lane (CDT-271).
- A runner-level guard for writes to gitignored paths, and runner-level `TMPDIR`/`HOME` isolation. R16 is enforced by suite design and review, not by the runner (backlog).

## Test

- [ ] Clean Surface fixture (valid frontmatter + a syntactically valid bash fence) → PASS, exit 0
- [ ] Broken-frontmatter fixture (missing `description`) → FAIL naming the missing field, exit 1
- [ ] Unparseable-YAML frontmatter fixture → FAIL, exit 1
- [ ] Broken-bash-fence fixture (fence fails `bash -n`) → FAIL naming the source line range, exit 1
- [ ] Broken engine-script fixture (`.sh` fails `bash -n`) → FAIL naming the script, exit 1
- [ ] Surface with valid frontmatter and zero bash blocks → PASS (pure-prompt command)
- [ ] Engine script declaring `--help` → invoked only under `--invoke-flags`; non-zero `--help` exit is a FAIL; script not declaring the flag is bash-n-only, never invoked
- [ ] Agent fixtures: clean → PASS; missing `effort` → FAIL naming `effort`; bad `model` → FAIL naming the value; block-sequence `tools` → PASS
- [ ] Broken githook fixture and broken test-script fixture → FAIL naming the file, exit 1
- [ ] No-arg `--root` run on a mktemp tree discovers agents, sub-docs, githooks and test scripts (each broken one FAILs); `fixtures/` paths are never checked
- [ ] Explicit target-list form checks only the named paths
- [ ] All explicit targets missing/unreadable → exit 64; a readable + an unreadable target → warn + check the readable one
- [ ] Full no-arg run on this repo exits 0 after the adoption pass (live tree clean)
- [ ] Harness uses `mktemp -d`/`$TMPDIR` only — a run under the sandbox and a run on a clean-checkout CI runner produce identical PASS/FAIL sets (no `/tmp` hardcoding)
- [ ] `.github/workflows/smoke.yml` triggers on both push and pull_request to master and propagates the harness exit code
- [ ] `/release` dry run with an injected broken fixture on the tree → release blocked at Step 4.10
- [ ] `bash tools/run-all-tests-test.sh` exits 0 (every R17 case)
- [ ] `bash tools/run-all-tests.sh` on this repo exits 0 with an empty quarantine; no `FAIL`/`TIMEOUT`/`QUARANTINED` lines; a `SKIP` line only for an R19 cause
- [ ] `bash tests/lib/test.sh` exits 0 (every R21 and R31 case)
- [ ] As root (`unshare -r`, where available): `skills/metrics/test.sh` case 4 and `skills/transcript-mirror/test.sh` M4 print `SKIP:` and the suites exit 0
- [ ] With `sqlite3` absent from `PATH`: `skills/memory-store/test-migrate.sh`, `skills/memory-store/test-seed-pack.sh` and `skills/validate-memory/test-reconcile.sh` exit 77
- [ ] A full runner run leaves the caller's `TMPDIR`, the real `HOME` and `$MROOT/.claude/` unchanged (R16)
- [ ] `git status --porcelain` in the checkout is identical before and after a full runner run
- [ ] `bash tools/fence-exec/test.sh` exits 0 (every R29 case)
- [ ] `bash tools/fence-exec/run.sh` on this repo exits 0 and prints the two `commands/retro.md` exclusions with backlog `wp-2-10-retro-scheduled`
- [ ] `bash skills/refactor/test-fences.sh` and `bash skills/retro-gate/test-retro-fences.sh` exit 0 (R27)
- [ ] `bash tools/ci-workflow-test.sh` exits 0 (R28, rule B6 and its two bites)

## Validation

- [ ] All bite-tests pass (each broken fixture proven to FAIL; clean fixture proven to PASS — the gate is shown to bite, not merely run clean)
- [ ] Initial adoption pass complete: live tree passes clean under the no-arg form
- [ ] CI workflow runs green on a push to master and on a PR (Actions enabled on origin)
- [ ] Gate step added to `skills/release/SKILL.md` (Step 4.10) and exercised by one real release
- [ ] Spec reviewed and promoted DRAFT → ACTIVE
- [ ] `all-tests` job green on the first PR or push that carries it; its QUARANTINED set equals the `tools/test-quarantine.txt` entries (none reported `PASS` + `warn:`)
- [ ] Step 4.13 present in `skills/release/SKILL.md` and exercised by one real release
- [ ] `fence-exec` CI job green on the first push or pull request that carries it (R28)
- [ ] `bash tools/fence-exec/run.sh` exits 0 on the live tree: no unexcluded finding, the two `commands/retro.md` exclusions printed, six suites pass

## Acceptance criteria

### wp-2-01-fence-harness

- **A.** `bash tools/fence-exec/run.sh list` prints one TSV row per bash fence: file, first body line, last body line, nearest heading and info string. On `tools/fence-exec/fixtures/f4-return.md` it prints four rows, and the first is `tools/fence-exec/fixtures/f4-return.md`, 8, 9, `Positives`, `bash`. With no argument it scans the skill-lint file set on the skill-lint fence parser, finds a planted defect in each of `commands/`, `skills/**`, `agents/` and `AGENTS.md`, and skips `skills/skill-lint/fixtures/`.
  Verify: bash tools/fence-exec/test.sh
- **B.** F1 runs `bash -n` on each bash fence. Fixture `f1-syntax.md` exits 1 with one F1 finding at line 9, in section `Positive`. A clean fence, a `bash template` fence and a `sql` fence add no finding. A copy of the harness with the `bash -n` call switched off reports none.
  Verify: bash tools/fence-exec/test.sh
- **C.** F2 reports a call to a function that only another fence of the file defines. Fixture `f2-function-scope.md` exits 1 with 15 findings, at lines 19, 25, 26 and 71 to 79 (three on line 71 and two on line 72). A fence that defines its own copy, a function-keyword definition, a name in a string, a comment or a quoted heredoc, an undefined name and a `bash template` fence add no finding. A copy with the rule switched off reports none.
  Verify: bash tools/fence-exec/test.sh
- **D.** F3 reports `trap ... EXIT` in a fence that is not a script body. Fixture `f3-trap-exit.md` exits 1 with three findings, at lines 10 (a lock release), 16 (a named handler) and 23 (an `rm` trap whose variable a later fence reads). An `rm` trap that no other fence reads, a fence that starts with a shebang, other signals, `trap - EXIT`, an empty action and a `bash template` fence add no finding. A copy with the rule switched off reports none.
  Verify: bash tools/fence-exec/test.sh
- **E.** F4 reports a `return` at command position outside a function. Fixture `f4-return.md` exits 1 with three findings, at lines 9, 15 (inside a brace group) and 17 (inside an `if`). A `return` in a brace-bodied function (the shapes `name()`, `name ()` with the brace on the next line, `function name` and `function name()`, one-line and multi-line, in a `case` arm and in a brace group), in a heredoc body, in a comment, in a string and as an argument adds no finding. A copy with the rule switched off reports none.
  Verify: bash tools/fence-exec/test.sh
- **F.** F5 reports a literal path that does not exist under `--root`. Fixture `f5-root/commands/paths.md` exits 1 with five findings, at lines 8, 9, 10, 11 and 18 (a `$PLUGIN_DIR` leaf next to a `plugin-dir.sh dir` literal). Existing paths, a placeholder, a glob, an expansion, a comment, a heredoc body and a `$PLUGIN_DIR` leaf with no known directory add no finding. A copy with the rule switched off reports none.
  Verify: bash tools/fence-exec/test.sh
- **G.** The lexer stays in sync. Fixture `clean.md` exits 0. A `return 9` appended to each of its four fences gives four F4 findings. The same canary appended to every non-template fence of the live tree gives one F4 finding per fence, in every file. A broken `awk` makes the run exit 1 with `refusing to report a clean run`.
  Verify: bash tools/fence-exec/test.sh
- **H.** Manifest exclusions are counted and printed. A matching `exclude` row keeps its findings out of the count and prints a line with the check, the file, the number, the backlog slug and the reason. A row that matches more or fewer findings than its count, and a row that matches nothing, each give an M1 finding and exit 1. A row for another check hides nothing. An unknown check id, an empty field, a zero count, a slug with spaces, an unknown row kind and a short `suite` row each exit 64.
  Verify: bash tools/fence-exec/test.sh
- **I.** Manifest suite rows link a fence to its suite. `check` gives an M1 finding when the file is absent, when the heading no longer holds a bash fence, when the suite is absent, when its basename is not a suite name that `tools/run-all-tests.sh` discovers, or when the suite never names the heading. `run` runs each suite once, exits 1 when a suite fails, names it with its rc and shows its last output lines.
  Verify: bash tools/fence-exec/test.sh
- **J.** On the live tree `bash tools/fence-exec/run.sh check` exits 0 over at least 400 fences in at least 150 files. The committed manifest holds a `suite` row for `commands/setup.md` `team`, `commands/memory.md` Step 5, Step 10.1 and Step 10.5, `skills/memory-recall/SKILL.md` Step 4, `commands/retro.md` Step 1b, `skills/review-and-commit/SKILL.md` Step 5 and `skills/refactor/SKILL.md` Step 1b. It holds two `exclude` rows, both for `commands/retro.md` with backlog slug `wp-2-10-retro-scheduled`: F2 with count 4 and F3 with count 1.
  Verify: bash tools/fence-exec/test.sh
- **K.** `skills/retro-gate/test-retro-fences.sh` runs the `commands/retro.md` Step 1b fence, as extracted, in a fresh shell in a fixture repo against stub lock and report scripts. With `MODE=all` and `AUTO=1` and a free lock it calls `acquire` once with the repo as MROOT, writes no report, exits 0, and (labelled KNOWN DEFECT) calls `release` once when the fence ends. With a held lock (rc 2) it prints `scheduled retro: lock held, skipping`, exits 0, releases nothing and writes no report. With an acquire error (rc 1) it warns `continuing without lock` and arms no trap. With `MODE=single`, with `AUTO=0` and with the lock script absent it never acquires. A fence with the `AUTO` guard removed takes the lock when unscheduled, and a fence with the held-lock code changed loses the skip line.
  Verify: bash skills/retro-gate/test-retro-fences.sh
- **L.** CDT-356: `skills/refactor/test-fences.sh` runs the `skills/refactor/SKILL.md` Step 1b (b) and (c) fences in a fixture repo. A relative path (`src/a.txt`) is kept: `git log` lists both commits of the file and the test scan reads `src/`. An in-tree absolute path is kept. An out-of-tree path, a sibling directory that shares the root's name prefix, a `..` path and an empty path are rejected, `git log` is skipped with a message, the fence exits 0 and no `fatal` appears on stderr. The test scan never reads the out-of-tree directory. On the v1.18.32 text (`skills/refactor/fixtures/step1b-before.md`) the relative path ends in `fatal: empty string is not a valid pathspec`, so the suite fails on the old text.
  Verify: bash skills/refactor/test-fences.sh
- **M.** One fence parser and one scan set: `fence-state.awk` holds no fence-opener match, `check-skill-bash.sh` holds no `discover()`, and `scan-set.sh` defines `skill_lint_scan_set`. Skill-lint C6 also guards `$PDH` and `$EXT_DIR`: fixture `c6-resolver-names.md` gives `[C6]` at lines 6 and 15 and a counted waiver at line 23, and the live tree holds no C6 or C10 finding.
  Verify: bash skills/skill-lint/test.sh
- **N.** `.github/workflows/smoke.yml` holds a job `fence-exec` with `timeout-minutes: 10`, the pinned `actions/checkout` line and `run: bash tools/fence-exec/run.sh`. `tools/ci-workflow-test.sh` exits 0, and its rule B6 fires on a workflow without the job and on a job that runs another command.
  Verify: bash tools/ci-workflow-test.sh
- **O.** [process] The release notes record the premise check of CDT-272. Goal 2 (`bash -n`) is run for `commands`, `skills` and `agents` by `tools/smoke/smoke.py` `check_fences`, and F1 adds `AGENTS.md` and the section name. Goal 3 (assign-before-use) is skill-lint C6, which this work package widens to `$PDH` and `$EXT_DIR`. Goal 5 reuses the four existing fence suites through the manifest. `[07 P-3]` holds through C10 and the `commands/memory.md` fence suite, and `[10 E1]` is read as this harness plus its CI job, with no change to `skills/doctor`.
- **P.** [process] The release notes name CDT-324 (WP 2-10, backlog slug `wp-2-10-retro-scheduled`) as the owner of the two manifest exclusions, and they say that WP 2-10 removes the rows.
- **Q.** [process] `bash tools/run-all-tests.sh` exits 0 and every `/release` gate passes.

## Version History

| Date | Change |
|------|--------|
| 2026-07-21 | Initial version (DRAFT). CDT-46-C1 (v1.0-W0). ID 030: highest allocated is SPEC-029. Lands with C1's release commit (freeze + single-folded-commit discipline). |
| 2026-09-25 | WP 1-01 (CDT-269, `[10 smoke-agents]`, W1-37): smoke discovery widened to agents (five-field value-domain check), sub-doc fences, every `*.sh` incl. tests, and `githooks/`; parser accepts YAML block sequences; `tools/smoke/**` blanket exclusion narrowed to `fixtures/`. New all-suites runner sections R1–R17 (`tools/run-all-tests.sh`, reasoned quarantine, `smoke.yml` `all-tests` job, `/release` Step 4.13, suite hygiene). Title widened. |
| 2026-09-25 | WP 1-01 review fix: Discovery classifier wording amended to "repo-relative path shape" — classify() must be given a repo-relative path (never absolute), since an ancestor directory outside the root sharing a classified name (`skills`, `agents`, `githooks`) would otherwise false-match. |
| 2026-09-25 | WP 1-02 (CDT-270, CDT-419, W1-34, W1-35): quarantine emptied; R13 reworded (environment causes skip, never quarantine). R16 extended to the real `$MROOT/.claude/`, the caller's `TMPDIR` and the real `HOME`. New R18–R21: exit-77 skip protocol (`tests/lib/skip.sh`), hermetic helper (`tests/lib/hermetic.sh`) and their self-test. Out of Scope trimmed; Covers widened. |
| 2026-09-26 | WP 1-03 (CDT-274, `[10 smoke-pin]`): job-level `permissions`/`timeout-minutes` hardening moves from Out of Scope into MUST as R22 (CI workflow hygiene), with SHA-pinned `uses:` and the static test `tools/ci-workflow-test.sh`. |
| 2026-09-29 | Hotfix after v1.18.25: CI `all-tests` ran on a shallow clone, so `test-verify-prompts.sh` could not `git show` its pinned base commit. R22 adds `fetch-depth: 0` for `all-tests`; `ci-workflow-test.sh` asserts it (B5) and bites it. |
| 2026-09-30 | WP 2-01 (`wp-2-01-fence-harness`; CDT-272, CDT-356): new section **Fence-exec harness** (R23-R30): `tools/fence-exec/run.sh` with `list`, `check` and `run`; per-fence checks F1 (`bash -n`, adds `AGENTS.md`), F2 (function scope across fences), F3 (`trap ... EXIT` in a fence), F4 (`return` outside a function) and F5 (path literals); a manifest (`tools/fence-exec/manifest.tsv`) of counted, reasoned exclusions and of suite rows that tie fences to the suites that run them; the `fence-exec` CI job and `tools/ci-workflow-test.sh` rule B6. The two "static only" rules and the Out of Scope "runtime verification" line now bind the smoke harness; the fence-exec harness runs a fence only through a manifest suite. First manifest: the four existing fence suites, `skills/retro-gate/test-retro-fences.sh` (`commands/retro.md` Step 1b) and `skills/refactor/test-fences.sh` (CDT-356), plus two exclusions for `commands/retro.md` (F2 x4, F3 x1; backlog `wp-2-10-retro-scheduled`). New `## Acceptance criteria` with `### wp-2-01-fence-harness`. The parser and the scan set come from SPEC-021. |
| 2026-09-30 | WP 2-02 (`wp-2-02-lint-rules`; CDT-286 `[06 F23]` and `[08 F16]`, rv-w1-14): new R31, `tests/lib/trailing-flag.sh`, the probe that runs every `shift 2` flag as the last argument under a timeout (self-test in `tests/lib/test.sh`). `skills/skill-lint/test-command-fences.sh` is a new fence suite and gets twelve `suite` rows in `tools/fence-exec/manifest.tsv` (R27). SPEC-021 adds C8 and C9. |

## Cross-references

- SPEC-021 — skill-bash lint gate; the closest precedent (LLM-free subprocess CLI, exit 0/1/64, `/release`-hosted gate, fixtures + bite-test). Reuse its `extract_blocks` fence semantics; complementary check (parse vs defect-class).
- SPEC-010 — code review & release; `/release` hosts this spec's invocation steps (Step 4.10 smoke, Step 4.13 all-suites). Owns the README command-index (docs-drift D1) — see Out of Scope.
- SPEC-002 — plugin infrastructure; owns the frontmatter/manifest loading contract and the hook-template drift-gate bite-test precedent.
- SPEC-003 — agent role system; source of the five agent frontmatter fields and the Tier table (not enforced here).
- SPEC-013 — council template-var drift gate precedent (gate owned by domain spec, hosted by `/release`).
- CDT-46 — v1.0 stability-contract epic; this gate is the W0 "deterministic behavioral gate / verified core" criterion. CONTEXT.md defines the Surface and Deprecation-stub glossary terms this spec relies on.
- CDT-269 — one discovering runner for all suites (this spec's runner sections). CDT-270 / CDT-419 — skip protocol and hermetic suites (R16, R18–R21). CDT-271 / CDT-274 — macOS lane, job permissions/timeouts (out of scope).
- SPEC-021 — skill-bash lint gate; the fence-exec harness runs on its fence parser (`fence-scan.awk`) and scan set (`scan-set.sh`), and skill-lint C6 guards `PDH` and `EXT_DIR`. SPEC-021 holds C1-C6 and C8-C10 (C8 idiom hazards and C9 command-fence arguments landed in WP 2-02); C7 stays reserved for WP 6-03.
- SPEC-015 — refactor workflow; owns the Step 1b path guard that CDT-356 fixed. `skills/refactor/test-fences.sh` is the fence-exec suite for it (R27).
- CDT-272 — fence-exec harness; CDT-356 — `/refactor` Step 1b path guard. WP 2-01 (`wp-2-01-fence-harness`) ships both. `tools/fence-exec/manifest.tsv` holds the exclusions that other work packages own (CDT-324, WP 2-10, for `commands/retro.md`).
