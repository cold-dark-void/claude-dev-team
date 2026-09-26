# SPEC-030: Smoke Harness and All-Suites Gate

**Status**: ACTIVE
**Category**: core
**Created**: 2026-07-21

**Covers**: `tools/smoke/run.sh`, `tools/smoke/smoke.py`, `tools/smoke/test.sh`, `tools/smoke/fixtures/`, `tools/smoke/README.md`, `tools/run-all-tests.sh`, `tools/run-all-tests-test.sh`, `tools/test-quarantine.txt`, `.github/workflows/smoke.yml`, `skills/release/SKILL.md` (Steps 4.10 and 4.13 only)

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

## MUST

### CLI contract

- MUST ship `tools/smoke/run.sh` as a pure-subprocess CLI (bash + python3 only, no LLM, no network), invoked from any cwd, that `exec`s `tools/smoke/smoke.py`
- MUST exit `0` when every discovered target passes its check set, `1` when at least one fails, `64` on usage error (invalid flag; or an explicit target list where every named path is missing/unreadable)
- MUST NOT modify any discovered or scanned file
- MUST NOT execute a discovered `.md` file's bash blocks (frontmatter parse + `bash -n` syntax check only); MUST NOT execute a script's body except the explicit opt-in `--help`/`--check` invocation permitted below
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
- R13. Each entry MUST carry one concrete reason: the failing assertion or the missing dependency, with a `file:line` or tool name. The file MUST list only suites measured red in CI (re-measured, never copied from a seed list). It MUST NOT list a suite that a dedicated `smoke.yml` job runs. WP 1-02 empties the file; the runner MUST NOT edit it

### All-suites runner — CI and release wiring

- R14. `.github/workflows/smoke.yml` MUST add a job `all-tests` (`runs-on: ubuntu-latest`, `actions/checkout`, `bash tools/run-all-tests.sh`) that fails iff the runner exits non-zero. Existing job ids MUST stay unchanged (branch-protection check names)
- R15. `/release` MUST run `bash tools/run-all-tests.sh` as Step 4.13 "All-suites gate", after Step 4.12, in the release checkout. A non-zero exit MUST block commit and tag (the Step 4.10 contract). The wiring change MUST land with the live tree exiting 0 under the seeded quarantine

### All-suites runner — suite hygiene

- R16. A discovered suite MUST NOT leave tracked or untracked-not-ignored changes in the checkout it runs from. A bite-test that needs a "live tree" MUST inject into a scratch copy of the checkout (for example `skills/docs-drift/test.sh` T6/T7), never into the checkout itself — an interrupted or timed-out run would leave the release tree mutated
- R17. `tools/run-all-tests-test.sh` MUST prove, on mktemp git trees via `--root`: a new `*-test.sh` is run (tracked and untracked-not-ignored); `test.sh` and `test-*.sh` are run; `fixtures/`, `.worktrees/`, `node_modules/` and non-matching names are not; sorted order; PASS-only → exit 0; FAIL → exit 1; TIMEOUT with a small `RUN_ALL_TESTS_TIMEOUT` → exit 1, fast, no surviving grandchild process; exit 77 → SKIP, exit 0; quarantined FAIL → exit 0; quarantined PASS → `warn:`; each R11 malformed case → exit 64; each R3 usage case → exit 64; an R9 dirtying suite → FAIL. On the live repo it MUST assert that no `tools/test-quarantine.txt` entry is run by a dedicated `smoke.yml` job

## SHOULD

- SHOULD complete a full no-argument smoke scan of this repo in under 15 seconds
- SHOULD emit `FAIL` reasons specific enough to locate the defect without opening the file (e.g. the `bash -n` line number, the missing frontmatter field name)
- SHOULD support a `--json` flag emitting per-target results as a JSON array for future tooling
- SHOULD keep a full `tools/run-all-tests.sh` run under 10 minutes on the CI runner (measured 2026-09-25: ~120 s on the host, ~100 s in a CI-like environment)

## MUST NOT

- MUST NOT execute a discovered Surface's bash blocks or a script's mutating body — static parse only, except the declared `--help`/`--check` opt-in
- MUST NOT hardcode the kept-Surface list — discovery is dynamic against the live tree
- MUST NOT auto-fix a failing Surface (report-only; fixes are authored and reviewed like any change)
- The runner MUST NOT run suites in parallel (suites share `$MROOT/.claude/` state), MUST NOT retry a failed suite, and MUST NOT count a quarantined outcome as passed in its summary

## Out of Scope

- **README command-index presence** (a Surface appearing in the README `## Commands` list) — this is `docs-drift`'s D1 check (SPEC-010, `/release` Step 4.9). Asserting index presence here would false-FAIL internal skills that are intentionally not user-facing and not in the README index. The smoke harness checks that a Surface *loads*, not that it is *documented*.
- Fenced-bash defect-class linting (cross-block scope, zsh `!` hazard, unguarded glob, inline-PRAGMA poison) — owned by SPEC-021 `skill-lint` (`/release` Step 4.8). Smoke asserts `bash -n` *parses*; skill-lint asserts the defect classes are absent. Complementary, non-overlapping.
- Runtime/behavioral verification of what a command *does* (its outputs, side effects, agent orchestration) — this harness is load-only static verification.
- Smoke does not *run* test scripts (it only parses them); the all-suites runner does.
- `.claude-plugin/*.json` schema validation — docs-drift `manifest-desc` covers the description field; a schema check is a separate item.
- A macOS CI lane (CDT-271), job-level `permissions`/`timeout-minutes` hardening (CDT-274), and root-safe skips (CDT-270).
- Fixing the quarantined suites — WP 1-02.

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
- [ ] `bash tools/run-all-tests.sh` on this repo exits 0 with the seeded quarantine; no `FAIL`/`TIMEOUT` lines
- [ ] `git status --porcelain` in the checkout is identical before and after a full runner run

## Validation

- [ ] All bite-tests pass (each broken fixture proven to FAIL; clean fixture proven to PASS — the gate is shown to bite, not merely run clean)
- [ ] Initial adoption pass complete: live tree passes clean under the no-arg form
- [ ] CI workflow runs green on a push to master and on a PR (Actions enabled on origin)
- [ ] Gate step added to `skills/release/SKILL.md` (Step 4.10) and exercised by one real release
- [ ] Spec reviewed and promoted DRAFT → ACTIVE
- [ ] `all-tests` job green on the first PR or push that carries it; its QUARANTINED set equals the `tools/test-quarantine.txt` entries (none reported `PASS` + `warn:`)
- [ ] Step 4.13 present in `skills/release/SKILL.md` and exercised by one real release

## Version History

| Date | Change |
|------|--------|
| 2026-07-21 | Initial version (DRAFT). CDT-46-C1 (v1.0-W0). ID 030: highest allocated is SPEC-029. Lands with C1's release commit (freeze + single-folded-commit discipline). |
| 2026-09-25 | WP 1-01 (CDT-269, `[10 smoke-agents]`, W1-37): smoke discovery widened to agents (five-field value-domain check), sub-doc fences, every `*.sh` incl. tests, and `githooks/`; parser accepts YAML block sequences; `tools/smoke/**` blanket exclusion narrowed to `fixtures/`. New all-suites runner sections R1–R17 (`tools/run-all-tests.sh`, reasoned quarantine, `smoke.yml` `all-tests` job, `/release` Step 4.13, suite hygiene). Title widened. |
| 2026-09-25 | WP 1-01 review fix: Discovery classifier wording amended to "repo-relative path shape" — classify() must be given a repo-relative path (never absolute), since an ancestor directory outside the root sharing a classified name (`skills`, `agents`, `githooks`) would otherwise false-match. |

## Cross-references

- SPEC-021 — skill-bash lint gate; the closest precedent (LLM-free subprocess CLI, exit 0/1/64, `/release`-hosted gate, fixtures + bite-test). Reuse its `extract_blocks` fence semantics; complementary check (parse vs defect-class).
- SPEC-010 — code review & release; `/release` hosts this spec's invocation steps (Step 4.10 smoke, Step 4.13 all-suites). Owns the README command-index (docs-drift D1) — see Out of Scope.
- SPEC-002 — plugin infrastructure; owns the frontmatter/manifest loading contract and the hook-template drift-gate bite-test precedent.
- SPEC-003 — agent role system; source of the five agent frontmatter fields and the Tier table (not enforced here).
- SPEC-013 — council template-var drift gate precedent (gate owned by domain spec, hosted by `/release`).
- CDT-46 — v1.0 stability-contract epic; this gate is the W0 "deterministic behavioral gate / verified core" criterion. CONTEXT.md defines the Surface and Deprecation-stub glossary terms this spec relies on.
- CDT-269 — one discovering runner for all suites (this spec's runner sections). CDT-270 / CDT-271 / CDT-274 — root-safe skips, macOS lane, job permissions/timeouts (out of scope).
