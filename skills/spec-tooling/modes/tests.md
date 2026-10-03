<!-- /spec-tooling mode body — load via SKILL.md router; read only the current mode. -->

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
