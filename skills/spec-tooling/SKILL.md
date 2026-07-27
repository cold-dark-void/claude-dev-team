---
name: spec-tooling
description: |
    Spec lifecycle tooling for /spec generate|tests|reflect. Reverse-engineer
    behavioral specs from source (generate), emit unit/integration tests from
    MUST requirements (tests), and run full-system health reflection across all
    specs/skills/code (reflect). Also hosts shared partials (spec-skeleton.md,
    source-exclude.md) and check-format.sh used by the broader /spec surface.
---

# Spec Tooling

Backing skill for `/spec generate`, `/spec tests`, and `/spec reflect`
(commands/spec.md routes those three subs here). Absorbs the former
`generate-specs`, `generate-tests`, and `reflect-specs` skill bodies.

Governing contract: `specs/core/SPEC-008-spec-management.md`.

## Shared assets (this directory)

| Asset | Role |
|-------|------|
| `spec-skeleton.md` | Canonical 9-section emitter partial (SPEC-008). Include via `<!-- include: skills/spec-tooling/spec-skeleton.md agent=spec -->`. |
| `source-exclude.md` | Canonical code-alignment exclude set (SPEC-008 § Source Exclusions). Include via `<!-- include: skills/spec-tooling/source-exclude.md agent=spec -->`. |
| `check-format.sh` | Mechanized Phase-1 format check (9 required sections). Exit 0 = OK. |
| `fixtures/` | check-format fixtures (pre/post-fix). |

Do NOT hand-edit include regions; refresh with:
```bash
python3 skills/agent-memory/sync-includes.py apply skills/spec-tooling/SKILL.md
```

## Dispatch

| Invocation | Mode |
|------------|------|
| `/spec generate [path]` | **generate** — code → INFERRED specs |
| `/spec tests [SPEC-NNN] [--dry-run]` | **tests** — specs → tagged test files |
| `/spec reflect [--report] [--phase N]` | **reflect** — full-system health audit |

Unknown sub → refuse; list the three modes above.

Every fenced bash block re-resolves `$MROOT` (skill-lint C1 — fresh shell each fence):

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
```

All paths below are relative to `$MROOT` unless noted.

---

# Mode: generate

Reverse-engineer behavioral specs from existing source. Groups the public
surface by domain, writes MUST/SHOULD/MUST NOT specs from what the code
actually does. All output is marked `INFERRED` and requires human review.
Designed for legacy projects with no existing specs. Run once to establish a
baseline, then use `/spec reflect` to keep them current.

## Arguments

- `/spec generate` — full codebase scan, Tech Lead decides domain grouping
- `/spec generate <path>` — limit scan to a specific package or directory

## G0. Detect project root and language

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
```

Detect language by checking for the canonical 5-marker set (SPEC-008
`### Project-Language Markers`):

| Marker file | Language | Source extensions | Exclude |
|-------------|----------|-------------------|---------|
| `go.mod` | Go | `**/*.go` | `*_test.go`, `vendor/` |
| `package.json` | TypeScript/JavaScript | `**/*.ts`, `**/*.tsx`, `**/*.js` | `node_modules/`, `dist/` |
| `pyproject.toml` (fallback `setup.py`) | Python | `**/*.py` | `__pycache__/`, `.venv/` |
| `Cargo.toml` | Rust | `**/*.rs` | `target/` |
| `*.csproj` | C# | `**/*.cs` | `bin/`, `obj/` |

The marker set is canonical (SPEC-008); the extension/exclude columns above are
generate-mode scan-scope additions and are legitimately richer than the
bare-presence detection used by check-specs/reflect.

Exclude always: `.claude/`, `specs/`, `skills/`, `commands/`, `*.md`, `*.json`,
`*.yaml`, `*.lock`, `*.sum`, generated files (`*.pb.go`, `*_gen.*`, `*_generated.*`).

Note: this generation-scope source-scan exclude is intentionally distinct from
the code-alignment exclude set defined in SPEC-008 `### Source Exclusions
(code alignment)`. When reverse-engineering product specs from code, generate
rightly skips the plugin's own tooling dirs (`skills/`, `commands/`); the
alignment consumers do NOT exclude those dirs (see SPEC-008 for rationale).

If no language detected: ask the user what language/extensions to scan.

## G1. Check for existing specs

The directory-existence check below follows SPEC-008 `### Spec Discovery`
(canonical enumeration anchored on `$MROOT`). The `ls` here is a presence
guard only — full spec enumeration uses `Glob $MROOT/specs/**/*.md` in later
steps.

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
ls $MROOT/specs/ 2>/dev/null
```

If specs already exist, warn:

```
specs/ already contains N files. /spec generate is designed for projects with no
existing specs.

Options:
  a) Continue — generate specs for areas NOT already covered (safe)
  b) Abort — use /spec reflect to check alignment of existing specs instead

Proceed? (a/b)
```

If user chooses (b): stop and suggest `/spec reflect`.
If user chooses (a): note which spec files already exist and skip those domains later.

## G2. Read all source files and build a surface map

Read every source file. For each file:

1. **Identify the module's responsibility** — 1–2 sentence summary of what it owns
2. **Collect the public surface**: all exported/public symbols:
   - Go: exported functions, types, interfaces, methods on exported types
   - TypeScript: exported functions, classes, interfaces, React components, API route handlers
   - Python: public functions, classes, methods (no leading `_`)
   - Rust: `pub fn`, `pub struct`, `pub trait`, `pub impl`
3. **Read the implementation** (not just the signature) — infer:
   - What inputs does it validate or reject?
   - What invariants does it enforce?
   - What side effects does it have (DB write, file I/O, network call, cache update)?
   - What does it return or mutate?
   - What error conditions does it handle?

**MUST** cap per-file reading at 300 lines (SPEC-008 § Spec Generation). If a
file exceeds this, read the first 300 lines and note it was truncated — flag
truncated files for manual review.

**MUST** skip test files and generated files — tests inform specs but are not
the source of truth.

Build a surface map:
```
Module: internal/cache/responses.go
  Purpose: SQLite-backed response cache keyed by (file_hash, model, prompt)
  Public surface:
    - GetResponse(hash, model, prompt) → (string, bool)      [read, cache hit/miss]
    - SetResponse(hash, model, prompt, response)              [write, upsert]
    - GetAllForFolder(folderPath) → []CachedAnalysis          [read, folder-scoped query]
    - CachedAnalysis{FilePath, Model, Prompt, Description, CachedAt}
  Inferred invariants:
    - MUST key on (hash, model, prompt) tuple — same image with different model = different entry
    - MUST NOT return partial responses (atomically written)
    - SHOULD handle concurrent reads without locking (SQLite WAL mode assumed)
```

## G3. Tech Lead groups surface into domains

```
@tech-lead You have a surface map of N modules across this codebase.
Group them into 8–15 domain-level feature areas suitable for one spec each.

Rules:
- One spec per cohesive domain (e.g. "Response Caching", "File Browser", "Analysis Queue")
- Avoid micro-specs (one function = one spec) and mega-specs (everything in one)
- If two modules share a tight contract, they belong in the same spec
- Name each domain clearly — the spec filename will be SPEC-NNN-<domain-slug>.md

Surface map:
<paste full surface map from G2>

Output: ordered list of domains, each with:
- Domain name
- Modules it covers
- 1-sentence scope description
```

Present Tech Lead's grouping to the user:

```
Tech Lead proposes N spec domains:

  1. Response Caching          — internal/cache/responses.go, cache/common.go
  2. Analysis Queue            — ui/fyne/analysis_queue.go, app/queue.go
  3. File Browser              — ui/fyne/filebrowser.go, services/directory/
  ...

Approve this grouping, or edit before we write specs? (approve / edit)
```

If user edits: apply their changes before proceeding.

## G4. Determine SPEC numbering

Check existing specs for the highest SPEC number (SPEC-008 `### Spec Discovery`):
```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
ls $MROOT/specs/core/ 2>/dev/null | grep -oP 'SPEC-\K\d+' | sort -n | tail -1
```

**MUST** start from that number + 1 (or SPEC-001 if none exist) — numbering
within the relevant category after highest existing number.

Create `specs/core/` if it doesn't exist:
```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
mkdir -p $MROOT/specs/core
```

## G5. Write one spec per domain

For each domain (in order), write `specs/core/SPEC-NNN-<domain-slug>.md`.

### Spec format

The 9 required sections come from the canonical, drift-gated partial
`skills/spec-tooling/spec-skeleton.md` (single-sourced via the `<!-- include -->`
region below — SPEC-008). Do NOT hand-edit the region between the markers; run
`python3 skills/agent-memory/sync-includes.py apply skills/spec-tooling/SKILL.md`
to refresh it. The emitter EXTRAS (`**Covers**:`, `## SHOULD`, `## Open Questions`,
`## Cross-references`) follow the region as normal content.

When producing a real spec file:
- Render the literal `<STATUS>` token in the template as:
  `INFERRED — generated by /spec generate on <YYYY-MM-DD>. Requires human review.`
  (Use today's date. INFERRED is the emit-time lifecycle status per SPEC-008's taxonomy.)
- Fill `<PREFIX>-<NNN>` (e.g. `SPEC-007`), `<Title>`, `<YYYY-MM-DD>` (generation date),
  and replace each `<…>` placeholder with inferred content.
- DO NOT copy the `<!-- include: … -->` / `<!-- /include -->` marker lines into the
  produced spec file — they are build-time directives only (and sit OUTSIDE the fenced
  template, so a verbatim copy of the ```markdown block already excludes them).

<!-- include: skills/spec-tooling/spec-skeleton.md agent=spec -->
```markdown
# <PREFIX>-<NNN>: <Title>

**Status**: <STATUS>
**Category**: core
**Created**: <YYYY-MM-DD>

## Overview

<One paragraph: what behavior this spec governs and why it exists.>

## MUST

- MUST <one concrete, testable requirement>

## Test

- [ ] <one concrete check verifying a MUST requirement above>

## Validation

- [ ] Spec reviewed and promoted to ACTIVE

## Version History

| Date | Change |
|------|--------|
| <YYYY-MM-DD> | Initial version |
```
<!-- /include -->

**Covers**: <list of modules/files>

## SHOULD

- SHOULD <softer convention observed in the code>
...

## Open Questions

- [ ] <anything ambiguous — behavior that's in the code but intent is unclear>
- [ ] <edge case that's handled oddly — may be a bug or intentional>
...

## Cross-references

- <SPEC-NNN>: <why this domain interacts with that one>
...

### Rules for inferring MUST statements (SPEC-008 § Spec Generation)

**MUST** infer MUST statements only from code evidence:
- If a function validates an input and returns an error → `MUST validate <X>`
- If a function writes to a store → `MUST persist <X> on <operation>`
- If a function checks a condition before proceeding → `MUST NOT allow <X> when <Y>`
- If retry/timeout logic exists → `MUST retry up to N times` / `MUST time out after N seconds`
- If a mutex or lock is used → `MUST be safe for concurrent access`
- If an interface is implemented → `MUST implement <InterfaceName> contract`
- Numeric constants (limits, timeouts, sizes) → express as `MUST NOT exceed N` / `MUST complete within N ms`

**MUST NOT** invent requirements not evidenced in the code. When intent is
unclear, put it in **Open Questions**, not MUST.

**MUST** write all N specs before pausing — do not ask for confirmation between
each one.

## G6. Write or update specs/TDD.md index

Read existing `specs/TDD.md` if present. If not, create it.

Add all generated specs to the index table:

```markdown
## Spec Index

| ID | Title | Status | Coverage |
|----|-------|--------|----------|
| SPEC-001 | Response Caching | INFERRED | internal/cache/responses.go |
| SPEC-002 | Analysis Queue | INFERRED | internal/ui/fyne/analysis_queue.go |
...
```

Mark all new entries as `INFERRED`.

## G7. Print generation report

```
/spec generate complete

Generated N specs in specs/core/:
  SPEC-001-response-caching.md        — 8 MUSTs, 2 SHOULDs, 1 open question
  SPEC-002-analysis-queue.md          — 12 MUSTs, 3 SHOULDs, 2 open questions
  SPEC-003-file-browser.md            — 6 MUSTs, 1 SHOULD, 0 open questions
  ...

Open questions requiring human review: N total
  SPEC-002: "Timeout behavior when Ollama is unreachable — is 2min intentional?"
  SPEC-005: "Sort order of files — alphabetical or mtime? Code does both in different places."
  ...

Truncated files (read partially — verify manually):
  internal/ui/fyne/app.go (847 lines — only first 300 read)

Next steps:
  1. Review each spec — correct any misattributed MUSTs
  2. Resolve open questions (edit specs directly or run /spec update)
  3. Run /spec reflect to verify the generated specs actually match the code
  4. Commit: git add specs/ && git commit -m "spec: establish baseline specs from /spec generate"
  5. From now on: /kickoff <ticket> will find and use these specs automatically
```

## Generate error handling

- **No source files found**: ask user to confirm the language/extensions to scan
- **File read fails** (permissions, binary): skip and note in report
- **Tech Lead grouping produces >20 domains**: ask user to consolidate — too many specs defeats the purpose
- **Tech Lead grouping produces <3 domains**: warn that grouping may be too coarse
- **Existing specs cover some domains**: skip those domains, only generate for uncovered areas
- **specs/core/ already has SPEC numbers that conflict**: start numbering after the highest existing number
- **No git repo**: use `pwd` as MROOT; warn that worktree-shared memory won't apply

---

# Mode: tests

Translates behavioral specs into executable test files. Reads MUST
requirements, detects the project's test framework, generates test stubs or
full tests, and runs them to report baseline pass/fail.

## Arguments

- `/spec tests` — generate tests for all specs
- `/spec tests SPEC-NNN` — generate tests for a single spec
- `/spec tests --dry-run` — show what would be generated without writing files

## T0. Detect project root and language

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
```

Detect language and test framework. The marker column is the canonical 5-marker
set from SPEC-008 `### Project-Language Markers`; the test-runner and test-path
columns are tests-mode richer additions (legitimately different — SPEC-008
explicitly permits surrounding columns to differ by purpose):

| Marker file | Language | Default test framework | Test file pattern |
|-------------|----------|----------------------|-------------------|
| `go.mod` | Go | `go test` | `*_test.go` (same package dir) |
| `package.json` + jest/vitest | TypeScript/JS | jest or vitest | `__tests__/*.test.ts` or `*.test.ts` |
| `package.json` + mocha | TypeScript/JS | mocha | `test/*.test.ts` |
| `pyproject.toml` (fallback `setup.py`) | Python | pytest | `tests/test_*.py` |
| `Cargo.toml` | Rust | `cargo test` | `#[cfg(test)]` inline or `tests/*.rs` |
| `*.csproj` | C# | xUnit/NUnit | `*.Tests/*.cs` |

If the project already has test files, detect the **existing convention** (file
location, naming, import style, assertion library) by reading 1-2 existing test
files. **MUST** match that convention exactly (SPEC-008 § Test Generation).

If no test files exist and no framework is detected, ask the user which
framework to use.

## T1. Collect specs

### If a specific spec ID was given (`/spec tests SPEC-NNN`):
- Find the spec file: `Glob specs/**/SPEC-NNN*.md`
- If not found, check `specs/TDD.md` for inline spec with that ID
- If still not found: error and stop

### If no spec ID given (generate all):
- `Glob specs/**/*.md` — collect all spec files (SPEC-008 § Spec Discovery)
- Also parse `specs/TDD.md` for inline specs (look for `### SPEC-NNN:` headers)
- Treat `specs/TDD.md` as INDEX (not a governed spec) — exclude it from the
  governed-spec set when enumerating
- If no specs found: print `No specs found in specs/ — run /spec generate or /spec create first` and stop

## T2. Extract testable requirements

For each spec, extract requirements into a structured list.

### Supported spec formats

Specs may use either format — handle both:

**Format A** — standalone spec files (from `/spec generate`, `/spec create`):
```markdown
## MUST
- MUST validate input before processing
- MUST NOT return partial responses
## SHOULD
- SHOULD handle concurrent reads without locking
```
Parse: lines starting with `- MUST`, `- MUST NOT`, `- SHOULD` under `## MUST` / `## SHOULD` headings.

**Format B** — inline specs in `specs/TDD.md` (from `/setup project`):
```markdown
### SPEC-001: Application Launch
**MUST**: Application starts successfully and displays main interface
**Behavior**:
- Application launches within 5 seconds
- Main window appears with correct title
**Validation**:
- [ ] Application starts without errors
- [ ] Startup time < 5 seconds
```
Parse: `**MUST**:` line as the primary requirement. `**Behavior**:` bullets as sub-requirements.
`**Validation**:` checklist items as individual test assertions.

If a spec doesn't match either format, read it fully and extract any sentence containing
MUST, MUST NOT, or SHOULD as a requirement.

### What to extract

1. **MUST requirements** — these become test cases that MUST pass
2. **MUST NOT requirements** — these become negative test cases (verify rejection/error)
3. **SHOULD requirements** — these become test cases marked as advisory (non-blocking)
4. **Validation checklists** — items under `**Validation**:` or `**Test**:` sections
5. **Numeric constraints** — timeouts, limits, sizes → boundary tests

### For each requirement, determine

- **Test name / tag**: MUST follow the pattern `Test<SPEC-ID>_<Requirement>` (Go: `TestSPEC001_ValidateInput`, Python: `test_spec001_validate_input`, JS/TS: `it("SPEC-001: validates input")`) and the file header `Generated from <PREFIX>-<NNN>`. This is the P3-M2 tag convention (normative single definition: SPEC-008 § Spec-test coverage matrix) — `/spec check --tests` Phase 3 recognizes these forms; revisions MUST be additive-only. Also enables filtered runs (`-run "SPEC"`, `-k "spec"`) and `grep "SPEC-"`
- **Test type**: unit, integration, or boundary
- **What to assert**: the expected behavior described in the requirement
- **Source module**: which file(s) implement this (use the spec's `**Covers**:` field, or Grep for related code)
- **Inputs/preconditions**: inferred from requirement context
- **Expected output/side effect**: what the requirement says MUST happen

Build a test plan:
```
Spec: SPEC-001 (Response Caching)
  Covers: internal/cache/responses.go

  1. MUST key on (hash, model, prompt) tuple
     → Test: different model with same hash returns different result
     → Type: unit
     → Source: GetResponse()

  2. MUST NOT return partial responses
     → Test: verify atomicity — concurrent write + read never yields partial data
     → Type: integration
     → Source: SetResponse(), GetResponse()

  3. SHOULD handle concurrent reads without locking
     → Test: parallel GetResponse calls don't deadlock
     → Type: integration (advisory)
     → Source: GetResponse()
```

## T3. Locate source code for test targets

For each requirement's source module:

1. **Read the source file** to understand:
   - Function signatures (parameters, return types)
   - Constructor / initialization requirements
   - Dependencies that need mocking or setup
   - Error return patterns

2. **Identify test setup needs**:
   - Does the module need a database connection? → setup/teardown
   - Does it need filesystem access? → temp dir
   - Does it depend on external services? → mock/stub
   - Does it need specific config? → test fixtures

3. **Check for existing tests** for the same module:
   - `Glob` for existing test files covering this module (e.g., `*_test.go`, `*.test.ts`, `test_*.py`)
   - If test files exist, read them and check for coverage of each requirement using two methods:
     a. **Name match**: `Grep` for the spec ID in test names (e.g., `SPEC001`, `spec_001`) — tests generated by this skill will match
     b. **Behavior match**: for each MUST requirement, check if an existing test already asserts the same behavior (e.g., a test named `TestGetAllForFolder_returnsEmpty` covers `MUST show message if no completed analyses exist`)
   - For each requirement, **MUST** classify as (SPEC-008 § Test Generation):
     - **COVERED** — existing test already validates this requirement → skip generation
     - **PARTIAL** — existing test touches the area but doesn't assert the specific requirement → generate, note the existing test
     - **UNCOVERED** — no existing test found → generate
   - Print a coverage summary before generating:
     ```
     SPEC-001: 3 MUST, 1 SHOULD
       COVERED:   1 (TestGetResponse_keyTuple — covers MUST #1)
       UNCOVERED: 2 (MUST #2, MUST #3)
       PARTIAL:   1 (SHOULD #1 — TestConcurrentAccess exists but doesn't assert no-lock)
       Generating: 3 tests (skipping 1 already covered)
     ```

## T4. Generate test files

### File placement rules

| Language | Convention | Location |
|----------|-----------|----------|
| Go | Test file next to source | Same directory as source file |
| TypeScript (jest) | `__tests__` dir or co-located | `src/__tests__/cache.test.ts` or `src/cache.test.ts` |
| Python (pytest) | `tests/` mirror of src | `tests/test_cache.py` |
| Rust | Inline `#[cfg(test)]` or `tests/` | Same file or `tests/cache_test.rs` |

**Always match existing project conventions** — if the project already has tests, follow their pattern exactly.

### Test file structure

Each generated test file **MUST** include (SPEC-008 § Test Generation):

1. **Header comment** with generation metadata:
   ```
   // Generated from SPEC-NNN: <Spec Title>
   // Generated by /spec tests on <YYYY-MM-DD>
   // Review and customize — these are starting points, not final tests
   ```

2. **Imports** matching the project's test framework and source module

3. **Test setup/teardown** (if needed):
   - Database connections, temp dirs, mock servers
   - Use the project's existing test helper patterns if any

4. **One test function per MUST requirement** (**MUST** generate one test per MUST):
   - Test name includes the spec ID for traceability (**MUST** name tests with spec ID)
   - Comment links back to the requirement text
   - **MUST** use Arrange → Act → Assert structure
   - Meaningful assertion messages

5. **Negative tests for MUST NOT requirements**:
   - Verify the system rejects/prevents the prohibited behavior
   - Assert specific error types or messages where possible

6. **Advisory tests for SHOULD requirements** (**MUST** mark SHOULD as advisory):
   - Same structure as MUST tests
   - Marked with a comment: `// Advisory (SHOULD) — failure is a warning, not a blocker`
   - **Universal semantic: run the test, warn on failure, do not fail the suite**
   - In Go: wrap assertion in `if` and use `t.Logf("SHOULD warning: ...")` instead of `t.Fatal`/`t.Error`
   - In pytest: use `warnings.warn("SHOULD: ...")` instead of `assert`, or `@pytest.mark.filterwarnings`
   - In jest: use `console.warn("SHOULD: ...")` in the catch block instead of letting the assertion fail the suite

### Test quality rules

- **MUST test the behavior, not the implementation** — assert outcomes, not internal state
- **One assertion per test** where practical (multiple related assertions are OK)
- **Meaningful test data** — use realistic values, not `"test"` / `123` / `foo`
- **No mocking unless necessary** — prefer real dependencies when feasible
- **DRY setup** — use test helpers for repeated setup, but keep each test readable
- **Edge cases for numeric constraints** — test at boundary, below, and above

## T5. Write files

For each test file:

1. Check if the file already exists
   - If yes: **MUST NOT overwrite** — create a separate spec-specific test file (e.g., `responses_spec001_test.go`, `test_spec001_cache.py`). Do not append to existing test files — it risks import breakage and merge conflicts
   - If no: create the file

2. Write the test file using the Write tool

3. Track what was generated:
   ```
   Generated: pkg/cache/responses_spec_test.go
     - TestSPEC001_KeyOnHashModelPrompt (MUST)
     - TestSPEC001_NoPartialResponses (MUST NOT)
     - TestSPEC001_ConcurrentReads (SHOULD)
   ```

If `--dry-run` was specified: print the test plan and file contents but do not write any files.

## T6. Run tests and report

Run the project's test command:

| Language | Command |
|----------|---------|
| Go | `go test ./... -run "SPEC" -v` |
| TypeScript | `npx jest --testPathPattern="spec" --verbose` or `npx vitest run` |
| Python | `pytest tests/ -k "spec" -v` |
| Rust | `cargo test spec -- --nocapture` |

### Report format

```
/spec tests complete

Generated N test files from M specs:

  pkg/cache/responses_spec_test.go          — 3 tests (2 MUST, 1 SHOULD)
    ✅ TestSPEC001_KeyOnHashModelPrompt      PASS
    ✅ TestSPEC001_NoPartialResponses        PASS
    ⚠️  TestSPEC001_ConcurrentReads          SKIP (SHOULD — advisory)

  pkg/queue/worker_spec_test.go             — 5 tests (4 MUST, 1 MUST NOT)
    ✅ TestSPEC002_ProcessInOrder            PASS
    ❌ TestSPEC002_TimeoutAfter30s           FAIL — no timeout implemented
    ✅ TestSPEC002_RetryOnTransientError     PASS
    ✅ TestSPEC002_NoRetryOnPermanentError   PASS (MUST NOT)
    ❌ TestSPEC002_MaxQueueSize              FAIL — no size limit found

Summary: 8 tests generated
  ✅ 5 PASS
  ❌ 2 FAIL (spec requirements not yet implemented)
  ⚠️  1 SKIP (advisory)

Failed tests indicate spec requirements that are documented but not yet
implemented in code. Either:
  1. Implement the missing behavior to make the tests pass
  2. Update the spec if the requirement is no longer valid (/spec update)

Traceability: each test is tagged with its source spec ID.
  grep "Generated from SPEC" to find all spec-driven tests.
```

## T7. Update specs/TDD.md (optional)

If `specs/TDD.md` exists, add a `Test Coverage` column to the spec index table:

```markdown
| ID | Title | Status | Test Coverage |
|----|-------|--------|---------------|
| SPEC-001 | Response Caching | INFERRED | 3/3 generated |
| SPEC-002 | Analysis Queue | INFERRED | 5/5 generated |
```

## Tests error handling

- **No specs found**: suggest `/spec generate` or `/spec create`
- **No test framework detected**: ask user which framework to use
- **Source module not found for a requirement**: generate a stub test with `// TODO: locate source module` and skip assertions
- **Test file already exists with same test names**: skip duplicates, only add new tests
- **Tests fail to compile**: fix syntax issues immediately; if the fix isn't obvious, leave a `// TODO` comment and move on
- **Test run times out**: cap test execution at 60 seconds; report timed-out tests separately

---

# Mode: reflect

A deep, interactive health check of the spec/skill/code system. Goes beyond
`/spec check` by covering all specs (not a sample), detecting inter-spec
contradictions, auditing skill documentation against reality, and pausing for
user confirmation at each conflict class.

## Arguments

- `/spec reflect` — full reflection — all phases, interactive
- `/spec reflect --report` — report only — skip Phase 6 interactive loop
- `/spec reflect --phase 2` — run only Phase 2 (cross-spec conflicts)
- `/spec reflect --phase 4` — run only Phase 4 (full code alignment)

## Phases overview

1. **Inventory** — collect all specs, skills, commands
2. **Cross-spec conflicts** — find specs that contradict each other
3. **Skill/command consistency** — skill docs describe what the code actually does
4. **Full code alignment** — every MUST in every spec checked against source
5. **Coverage gaps** — code areas with no spec, requirements with no code
6. **Interactive confirmation** — present findings, pause for user decisions

## R0. Detect project root

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && MROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || MROOT=$(pwd)
```

All paths below are relative to `$MROOT`.

## Phase 1: Inventory

Collect everything that will be inspected:

### 1a. Spec files
- `Glob specs/**/*.md` — collect all spec files (the category-agnostic enumerator, per SPEC-008 § Spec Discovery)
- Also check `specs/TDD.md` as an index (the index, not a governed spec — excluded from the spec set; cross-check it against the glob to flag orphans)
- If no spec files found: print `No specs found in specs/ — nothing to reflect` and stop

### 1b. Skills and commands
- `Glob skills/*/SKILL.md` — skill definition files
- `Glob commands/*.md` — command definition files
- Note: skills/commands are only checked if they exist; skip gracefully if `skills/` or `commands/` don't exist

### 1c. Source files
Detect project language (the canonical 5-marker map, per SPEC-008 § Project-Language Markers):
- Check for `go.mod`, `package.json`, `Cargo.toml`, `pyproject.toml` (fallback `setup.py`), `*.csproj`
- Glob the corresponding extensions (e.g., `**/*.go`, `**/*.ts`, `**/*.py`, `**/*.rs`)
- Exclude non-product sources — the canonical alignment exclude set (per SPEC-008 § Source Exclusions):

<!-- include: skills/spec-tooling/source-exclude.md agent=spec -->
```text
Exclude paths:      specs/  .claude/  node_modules/  dist/  build/  target/  vendor/  .git/
Exclude extensions: *.md  *.txt  *.json  *.yaml  *.yml  *.toml  *.lock  *.sum  *.pb.go  *_gen.*  *_generated.*
```
<!-- /include -->

Print inventory summary:
```
Inventory: N specs, M skills/commands, K source files
```

## Phase 2: Cross-Spec Conflict Detection

Read all spec files. For each pair of specs, look for contradictions in their MUST requirements.

### What to look for

The base BLOCKER/WARNING taxonomy is per SPEC-008 § Spec Conflict Scan; TERMINOLOGY is reflect's named extension (this mode only).

**BLOCKER** — direct contradiction:
- Spec A: `MUST store data in-memory only`
- Spec B: `MUST persist all data to disk`

**WARNING** — overlapping scope with potentially incompatible assumptions:
- Spec A: `MUST process requests synchronously`
- Spec B: `MUST handle concurrent requests`

**TERMINOLOGY** — same concept named differently (may indicate drift):
- Spec A uses "user session", Spec B uses "auth token" for what appears to be the same thing

### How to check
1. For each spec, extract all MUST requirements as a flat list
2. For each other spec, compare requirements — look for logical contradictions or incompatible constraints
3. Flag terminology inconsistency: same domain terms (user, session, request, data, limit, timeout) appearing with different names for what seems to be the same concept

### Phase 2 Report Format
```
## Phase 2: Cross-Spec Conflicts

### BLOCKERs (direct contradictions)
| Spec A | Requirement A | Spec B | Requirement B | Conflict |
|--------|--------------|--------|--------------|---------|
| SPEC-001 | MUST store in-memory | SPEC-005 | MUST persist to disk | Contradicts storage model |

### WARNINGs (scope overlap)
| Spec A | Spec B | Overlap description |
...

### Terminology Drift
| Term in Spec A | Term in Spec B | Likely same concept? |
...

Phase 2 summary: X BLOCKERs, Y WARNINGs, Z terminology issues
```

**PAUSE** (**MUST** pause and escalate on BLOCKER contradictions — SPEC-008 § Full Reflection): If BLOCKERs > 0, stop and ask the user:

> "Found [N] direct contradictions between specs. These must be resolved before code alignment
> is meaningful. For each BLOCKER above:
> - Which spec is correct?
> - Should the other spec be updated?
> - Or is the conflict intentional (e.g., different modes/configurations)?
>
> Please confirm how to proceed."

Wait for user response. If user resolves or confirms, continue. If user says "stop" or "fix first", stop and summarize what needs to be done.

## Phase 3: Skill/Command Consistency

For each skill/command file found in Phase 1:

### What to check

**Description accuracy**: Does the frontmatter `description` field match what the skill
actually does? Read the full SKILL.md body and compare — are there steps described that
aren't mentioned in the description?

**Referenced paths**: Does the skill reference specific file paths, directories, or commands
that don't exist in the project?
- Extract paths like `specs/TDD.md`, `.claude/backlog.md`, `commands/*.md`, specific filenames
- **MUST** `Glob` each to verify it exists (SPEC-008 § Full Reflection)

**Tool references**: Does the skill call tools (Grep, Glob, Read, Bash) with commands that
make sense for the current project structure?

**Inter-skill dependencies**: Does any skill reference another skill (e.g., "runs init first")?
If so, verify the referenced skill exists.

### Phase 3 Report Format
```
## Phase 3: Skill/Command Consistency

### SPEC-001 (create-spec.md)
- ✅ Description matches body
- ⚠️ References `specs/core/` but no such directory found

### review-and-commit SKILL.md
- ✅ All referenced paths exist
- ✅ No inter-skill dependency issues

Phase 3 summary: X issues found across Y skills/commands
```

**PAUSE if issues > 0**: Ask user:

> "Found [N] skill/command consistency issues. Should we update the skill docs to match
> reality, or are these paths/references planned (not yet created)?"

## Phase 4: Full Code Alignment

Unlike `/spec check` which samples 3–5 recent specs, this phase **MUST** check
**every spec** exhaustively (SPEC-008 § Full Reflection).

For each spec:

### 4a. Extract all MUST requirements
Parse the spec file for all bullet points under `## MUST` sections, or lines starting with
`MUST` anywhere in the spec body.

### 4b. Derive search keywords
From each MUST requirement, extract:
- Specific **nouns**: feature names, data types, identifiers, module names
- **Verbs**: operations the system must perform
- **Numeric constraints**: timeouts, limits, counts, thresholds
- **Named identifiers**: function names, config keys, API endpoints

### 4c. Search source files
`Grep` source files using keywords, excluding non-product sources — the canonical alignment
exclude set (per SPEC-008 § Source Exclusions):

<!-- include: skills/spec-tooling/source-exclude.md agent=spec -->
```text
Exclude paths:      specs/  .claude/  node_modules/  dist/  build/  target/  vendor/  .git/
Exclude extensions: *.md  *.txt  *.json  *.yaml  *.yml  *.toml  *.lock  *.sum  *.pb.go  *_gen.*  *_generated.*
```
<!-- /include -->

### 4d. Classify each MUST requirement
**MUST** classify every MUST requirement using the post-hoc alignment verdicts (SPEC-008 § Code-Alignment Verdicts):
- **MATCH** — code clearly satisfies requirement; cite `file:~line`
- **MISSING** — no code found implementing this behavior
- **DIFFERS** — code exists but contradicts requirement; cite `file:~line` and explain

### 4e. Detect drift
**MUST** scan code in each feature area for behavior **not mentioned in the spec** → flag **UNDOCUMENTED**.

### Phase 4 Report Format
```
## Phase 4: Full Code Alignment

| Spec | Requirement (truncated) | Status | Evidence |
|------|------------------------|--------|----------|
| SPEC-001 | MUST validate input... | MATCH | handler.go:~42 |
| SPEC-002 | MUST limit to 100ms... | DIFFERS | worker.go:~88 (no timeout) |
| SPEC-003 | MUST log all errors... | MISSING | — |

### Undocumented Behavior (Drift)
- SPEC-001: `cache.go:~210` implements retry logic not mentioned in spec

Phase 4 summary: X MATCH / Y MISSING / Z DIFFERS / N undocumented
```

If no source files exist (pure spec/docs project): skip Phase 4, note that.

## Phase 5: Coverage Gaps

Identify what is NOT covered by any spec by **reading every source file independently** —
not just checking keyword hits from Phase 4.

### 5a. Read all source files

For each source file collected in Phase 1:

1. **Read the file** (use the Read tool — full file, not grep)
2. **Summarize what it does**: in 1–3 sentences, describe the module's responsibility —
   what it exports, what operations it performs, what data it owns
3. **Collect public surface**: list all exported/public functions, types, structs, classes,
   API routes, CLI commands, event handlers, and background workers found in the file

**MUST** cap per-file reading at 300 lines (SPEC-008 § Full Reflection); if a file exceeds this, read the first 300 lines and
note it was truncated. Skip generated files (`*.pb.go`, `*.gen.ts`, `*_generated.*`,
`vendor/**`, `dist/**`, `node_modules/**`).

### 5b. Map public surface to specs

For each item in the public surface collected above:
- Search all spec MUST requirements for any that describe this behavior
- Match on: function/type name, the operation it performs, the data it handles
- Classify each surface item as:
  - **COVERED** — at least one spec MUST describes or implies this behavior
  - **UNCOVERED** — no spec touches this behavior at all

### 5c. Dead requirements
Compile all MISSING items from Phase 4 into a single list — MUST requirements that have
no code evidence.

### 5d. Module summary table

Produce a table of every source file read, its one-sentence purpose, and coverage status:

```
## Phase 5: Coverage Gaps

### Module Summary

| File | Purpose (1-sentence) | Coverage |
|------|----------------------|----------|
| auth/middleware.go | JWT validation and request authentication | ⚠️ UNCOVERED |
| storage/store.go | Key-value persistence backed by BoltDB | ✅ COVERED (SPEC-003) |
| utils/retry.go | Exponential backoff retry helper | ⚠️ UNCOVERED |
| api/handler.go | HTTP handlers for /api/v1/* routes | ✅ COVERED (SPEC-001, SPEC-002) |

### Uncovered public surface

| File | Symbol | Type | Description |
|------|--------|------|-------------|
| auth/middleware.go | ValidateToken | func | Validates JWT and sets user context |
| auth/middleware.go | RefreshHandler | http.Handler | Handles token refresh requests |
| utils/retry.go | WithBackoff | func | Retries fn up to N times with exponential backoff |

### Dead requirements (MUST with no code):
- SPEC-003: MUST log all errors to structured logger
- SPEC-007: MUST enforce rate limit of 100 req/s

Phase 5 summary: X files read, Y modules COVERED, Z UNCOVERED, N dead requirements,
M unspecified public symbols
```

If no source files exist (pure spec/docs project): skip Phase 5, note that.

## Phase 6: Interactive Confirmation

After all phases complete, present a consolidated summary and ask the user to confirm or take action.
Skip this phase entirely when `--report` was passed.

```
## Reflection Summary

| Phase | Finding | Count |
|-------|---------|-------|
| Cross-spec BLOCKERs | Direct contradictions | X |
| Cross-spec WARNINGs | Scope overlap | Y |
| Terminology drift | Inconsistent naming | Z |
| Skill/command issues | Path/description mismatches | A |
| Code alignment MATCH | Requirements satisfied | B |
| Code alignment MISSING | No implementation found | C |
| Code alignment DIFFERS | Implementation contradicts spec | D |
| Undocumented behavior | Drift detected | E |
| Coverage gaps | Uncovered files/features | F |
```

Then ask:

> "What would you like to do with these findings?
>
> **Suggested actions:**
> 1. Fix DIFFERS items (code contradicts spec) — update code or spec?
> 2. Address MISSING items — implement or remove from spec?
> 3. Document UNDOCUMENTED behavior — add to spec or remove from code?
> 4. Resolve BLOCKER conflicts — which spec wins?
> 5. Update skill docs for consistency issues
>
> You can also say 'fix all' to address everything, 'skip X' to skip a category,
> or 'just the report' if you want findings without action."

Act on user's response:
- For each selected category, work through items one at a time
- For each item: propose the fix, confirm with user, apply it
- Update specs, skills, or note code changes needed
- After applying fixes, confirm: "Fixed: [item]. Continue?"

---

# Cross-mode relationship

| Mode / command | Direction | Purpose |
|----------------|-----------|---------|
| `/spec generate` | Code → Specs | Reverse-engineer specs from code |
| `/spec tests` | Specs → Tests | Generate tests from specs |
| `/spec reflect` | Specs ↔ Code | Full-system audit (all specs, interactive) |
| `/spec check` | Specs → Code (+ opt-in Specs → Tests) | Format + alignment (sampled); `--tests` Phase 3 COVERED/MISSING matrix via P3-M2 tags |
| `/spec create` | User → Spec | Guided spec authoring |
| `/spec update` | User → Spec edit | Modify existing requirements |
| `/spec find` / `/spec list` | Query | Search / inventory |

Together, generate + tests form a full loop:
```
Code → /spec generate → Specs → /spec tests → Tests → verify → Code
```

Reflect keeps the loop honest after baseline establishment.
