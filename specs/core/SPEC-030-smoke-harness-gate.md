# SPEC-030: Smoke Harness Gate

**Status**: ACTIVE
**Category**: core
**Created**: 2026-07-21

**Covers**: `tools/smoke/run.sh`, `tools/smoke/smoke.py`, `tools/smoke/test.sh`, `tools/smoke/fixtures/`, `.github/workflows/smoke.yml`, `skills/release/SKILL.md` (Step 4.10 only)

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
the SPEC-021 (skill-bash), SPEC-013 (template-vars) and SPEC-002 (hook-templates) precedent:
the gate contract lives here; `/release` hosts the invocation step.

"Loads without error" is defined narrowly and deterministically (see MUST → Check set). It is
**static** — the harness never executes a discovered Surface's bash blocks or an engine
script's body (beyond an explicit opt-in `--help`/`--check` invocation where a script declares
support). It is not runtime/behavioral verification of what a command *does*.

## MUST

### CLI contract

- MUST ship `tools/smoke/run.sh` as a pure-subprocess CLI (bash + python3 only, no LLM, no network), invoked from any cwd, that `exec`s `tools/smoke/smoke.py`
- MUST exit `0` when every discovered Surface and engine script passes its check set, `1` when at least one fails, `64` on usage error (invalid flag; or an explicit target list where every named path is missing/unreadable)
- MUST NOT modify any discovered or scanned file
- MUST NOT execute a discovered `.md` Surface's bash blocks (frontmatter parse + `bash -n` syntax check only); MUST NOT execute an engine script's body except the explicit opt-in `--help`/`--check` invocation permitted below
- MUST print one `PASS <surface>` or `FAIL <surface>: <reason>` line per checked target (Surface path or engine-script path), and a final one-line summary (`N checked, M failed`)
- MUST skip an unreadable path with a `warn:` line on stderr and continue (a mix of readable + unreadable targets is not a usage error)

### Discovery

- MUST, in the no-argument form, dynamically discover the Surface set as: every `commands/*.md` and every `skills/*/SKILL.md` under the repo root — never a hardcoded surface list (the kept set changes across the v1 program; discovery MUST reflect the live tree)
- MUST exclude fixture and test material from discovery: any path under a `fixtures/` directory, and `tools/smoke/**` itself (the harness's own fixtures must not self-fail the gate)
- MUST discover engine scripts as: every `*.sh` under `skills/**` whose basename does not match a test pattern (`test`-prefixed or `*-test.sh` or `test-*.sh`) — test scripts are not Surfaces and are out of scope (SPEC-021 Out of Scope precedent for standalone `.sh`)
- MUST support an explicit target-list form (`run.sh <path>...`) that checks only the named paths (each dispatched to the `.md` check set or `.sh` check set by extension), for fast local iteration and bite-testing
- MUST resolve the repo root for no-arg discovery from `git rev-parse --show-toplevel`, falling back to cwd when that fails (mirrors `skills/skill-lint/lint.py` discovery), and accept a `--root DIR` override

### Check set — `.md` Surface

- MUST verify the file begins with a YAML frontmatter block delimited by `---` lines and that the block parses as a mapping — FAIL if absent or unparseable
- MUST verify the frontmatter contains a non-empty `name` field and a non-empty `description` field — FAIL if either is missing or empty (these are the two fields Claude Code requires to load a command/skill; every current Surface has both)
- MUST extract every fenced ```bash block (using the SPEC-021 fence semantics: a fence is bash iff the first whitespace-delimited info-string token is exactly `bash`; only depth-0 fences; a backticked line with an info string inside an open fence is content) and run each through `bash -n` (parse-only, no execution) — FAIL naming the block's source line range on any `bash -n` non-zero
- MUST skip the `bash -n` syntax check (only) for a fence whose info string is `bash template` — i.e. the second whitespace-delimited info-string token is exactly `template`. Documentation-shape fences (angle-bracket `<placeholder>` fill-ins, elided-body pseudocode) that intentionally are not valid bash carry this marker. The fence's first token stays `bash`, so it remains bash-classified: SPEC-021 `skill-lint` still lints it for the C1–C4 defect classes (coverage unaffected). Frontmatter checks are unaffected by the marker. A bare `bash` fence that fails `bash -n` is still a FAIL — the marker is an explicit author opt-out, never inferred
- MUST treat a Surface with valid frontmatter and zero bash blocks as PASS (many command `.md` files are pure prompt text — absence of bash is not a failure)

### Check set — engine `.sh` script

- MUST run each discovered engine script through `bash -n` (parse-only) — FAIL on non-zero, naming the script path and the `bash -n` stderr
- MAY additionally invoke a script with `--help` or `--check` **only when** the script's own text declares support for that flag (a literal `--help`/`--check` token appears in the file); when invoked, a non-zero exit is a FAIL. Scripts that do not declare the flag MUST NOT be invoked (their bodies mutate state)

### Determinism / environment

- MUST NOT read or write outside the repo tree except via `$TMPDIR`/`mktemp -d`; MUST NOT hardcode `/tmp` (the repo's own `worktree-lib-test.sh` produced 20/32 spurious sandbox FAILs from hardcoded `/tmp` — the harness and its test must be sandbox- and CI-runner-portable)
- MUST use `bash -n` (not `zsh -n`) for syntax checks so results match the GitHub Actions Ubuntu-bash runner and the existing `/release` gates, even though fences are authored with zsh idioms
- MUST require no network, no secrets, and no Claude API — the gate is fully offline and deterministic on any bash + python3 host

### CI wiring

- `.github/workflows/smoke.yml` MUST trigger on `push` to master AND `pull_request` targeting master (this repo ships releases directly to master with no PR flow; a push trigger is required for the gate to actually run on the real release path — a pull_request-only trigger would never fire)
- The workflow MUST check out the repo and run `bash tools/smoke/run.sh` (no-arg form), and the job MUST fail (non-zero) iff the harness exits non-zero (propagate the exit code; do not swallow it)

### Release gate wiring

- `/release` MUST run `bash tools/smoke/run.sh` (no-argument form) as a pre-commit gate step (Step 4.10, after the Step 4.9 docs-drift gate); a non-zero exit MUST block commit and tag until the failing Surface/script is fixed
- The change that first wires the gate MUST land with the existing tree passing clean (every current Surface and engine script passes) — the gate lands green, never red

### Bite-tests

- MUST ship fixtures under `tools/smoke/fixtures/`: one clean Surface fixture, one broken-frontmatter fixture (missing `description`, or unparseable YAML), one broken-bash-fence fixture (a fence that fails `bash -n`), and one broken engine-script fixture (`.sh` that fails `bash -n`)
- MUST verify, before the gate is wired into `/release`, that each broken fixture produces exit 1 with a FAIL line naming it, and that the clean fixture produces exit 0 — a gate that merely runs clean on the live tree is not proven; it MUST be shown to bite (SPEC-021/SPEC-002 hook-template bite-test precedent)

## SHOULD

- SHOULD complete a full no-argument scan of this repo in under 15 seconds
- SHOULD emit `FAIL` reasons specific enough to locate the defect without opening the file (e.g. the `bash -n` line number, the missing frontmatter field name)
- SHOULD support a `--json` flag emitting per-target results as a JSON array for future tooling

## MUST NOT

- MUST NOT execute a discovered Surface's bash blocks or an engine script's mutating body — static parse only, except the declared `--help`/`--check` opt-in
- MUST NOT hardcode the kept-Surface list — discovery is dynamic against the live tree
- MUST NOT auto-fix a failing Surface (report-only; fixes are authored and reviewed like any change)

## Out of Scope

- **README command-index presence** (a Surface appearing in the README `## Commands` list) — this is `docs-drift`'s D1 check (SPEC-010, `/release` Step 4.9). Asserting index presence here would false-FAIL internal skills that are intentionally not user-facing and not in the README index. The smoke harness checks that a Surface *loads*, not that it is *documented*.
- Fenced-bash defect-class linting (cross-block scope, zsh `!` hazard, unguarded glob, inline-PRAGMA poison) — owned by SPEC-021 `skill-lint` (`/release` Step 4.8). Smoke asserts `bash -n` *parses*; skill-lint asserts the defect classes are absent. Complementary, non-overlapping.
- Runtime/behavioral verification of what a command *does* (its outputs, side effects, agent orchestration) — this harness is load-only static verification.
- Linting of test scripts (`*-test.sh`, `test-*.sh`) — excluded from discovery.

## Test

- [ ] Clean Surface fixture (valid frontmatter + a syntactically valid bash fence) → PASS, exit 0
- [ ] Broken-frontmatter fixture (missing `description`) → FAIL naming the missing field, exit 1
- [ ] Unparseable-YAML frontmatter fixture → FAIL, exit 1
- [ ] Broken-bash-fence fixture (fence fails `bash -n`) → FAIL naming the source line range, exit 1
- [ ] Broken engine-script fixture (`.sh` fails `bash -n`) → FAIL naming the script, exit 1
- [ ] Surface with valid frontmatter and zero bash blocks → PASS (pure-prompt command)
- [ ] Engine script declaring `--help` → invoked; non-zero `--help` exit is a FAIL; script not declaring the flag is bash-n-only, never invoked
- [ ] No-argument form discovers every `commands/*.md` and every `skills/*/SKILL.md`, and every non-test `skills/**/*.sh`, excluding `fixtures/` and `tools/smoke/`
- [ ] Explicit target-list form checks only the named paths
- [ ] All explicit targets missing/unreadable → exit 64; a readable + an unreadable target → warn + check the readable one
- [ ] Full no-arg run on this repo exits 0 after the initial adoption pass (live tree clean)
- [ ] Harness uses `mktemp -d`/`$TMPDIR` only — a run under the sandbox and a run on a clean-checkout CI runner produce identical PASS/FAIL sets (no `/tmp` hardcoding)
- [ ] `.github/workflows/smoke.yml` triggers on both push and pull_request to master and propagates the harness exit code
- [ ] `/release` dry run with an injected broken fixture on the tree → release blocked at Step 4.10

## Validation

- [ ] All bite-tests pass (each broken fixture proven to FAIL; clean fixture proven to PASS — the gate is shown to bite, not merely run clean)
- [ ] Initial adoption pass complete: live tree passes clean under the no-arg form
- [ ] CI workflow runs green on a push to master and on a PR (Actions enabled on origin)
- [ ] Gate step added to `skills/release/SKILL.md` (Step 4.10) and exercised by one real release
- [ ] Spec reviewed and promoted DRAFT → ACTIVE

## Version History

| Date | Change |
|------|--------|
| 2026-07-21 | Initial version (DRAFT). CDT-46-C1 (v1.0-W0). ID 030: highest allocated is SPEC-029. Lands with C1's release commit (freeze + single-folded-commit discipline). |

## Cross-references

- SPEC-021 — skill-bash lint gate; the closest precedent (LLM-free subprocess CLI, exit 0/1/64, `/release`-hosted gate, fixtures + bite-test). Reuse its `extract_blocks` fence semantics; complementary check (parse vs defect-class).
- SPEC-010 — code review & release; `/release` hosts this gate's invocation step (Step 4.10). Owns the README command-index (docs-drift D1) — see Out of Scope.
- SPEC-002 — plugin infrastructure; owns the frontmatter/manifest loading contract and the hook-template drift-gate bite-test precedent.
- SPEC-013 — council template-var drift gate precedent (gate owned by domain spec, hosted by `/release`).
- CDT-46 — v1.0 stability-contract epic; this gate is the W0 "deterministic behavioral gate / verified core" criterion. CONTEXT.md defines the Surface and Deprecation-stub glossary terms this spec relies on.
