---
name: generate-tests
description: Generate unit/integration tests from behavioral specs. Reads MUST/SHOULD
  requirements from specs/core/ or specs/TDD.md, detects the project's test framework,
  and writes test files with one test case per requirement. Each test is tagged with
  its source spec for traceability. Run after /generate-specs or /create-spec to close
  the spec-to-test gap.
---

# Generate Tests from Specs

Translates behavioral specs into executable test files. Reads MUST requirements,
detects the project's test framework, generates test stubs or full tests, and runs
them to report baseline pass/fail.

## Arguments

- `/generate-tests` — generate tests for all specs
- `/generate-tests SPEC-NNN` — generate tests for a single spec
- `/generate-tests --dry-run` — show what would be generated without writing files

---

## Step 0: Detect project root and language

```bash
_gc=$(git rev-parse --git-common-dir 2>/dev/null) \
  && PROOT=$(cd "$(dirname "$_gc")" && pwd) \
  || PROOT=$(pwd)
```

Detect language and test framework:

| Indicator | Language | Default test framework | Test file pattern |
|-----------|----------|----------------------|-------------------|
| `go.mod` | Go | `go test` | `*_test.go` (same package dir) |
| `package.json` + jest/vitest | TypeScript/JS | jest or vitest | `__tests__/*.test.ts` or `*.test.ts` |
| `package.json` + mocha | TypeScript/JS | mocha | `test/*.test.ts` |
| `pyproject.toml` / `setup.py` | Python | pytest | `tests/test_*.py` |
| `Cargo.toml` | Rust | `cargo test` | `#[cfg(test)]` inline or `tests/*.rs` |
| `*.csproj` | C# | xUnit/NUnit | `*.Tests/*.cs` |

If the project already has test files, detect the **existing convention** (file
location, naming, import style, assertion library) by reading 1-2 existing test
files. Match that convention exactly.

If no test files exist and no framework is detected, ask the user which framework
to use.

---

## Step 1: Collect specs

### If a specific spec ID was given (`/generate-tests SPEC-NNN`):
- Find the spec file: `Glob specs/**/SPEC-NNN*.md`
- If not found, check `specs/TDD.md` for inline spec with that ID
- If still not found: error and stop

### If no spec ID given (generate all):
- `Glob specs/**/*.md` — collect all spec files
- Also parse `specs/TDD.md` for inline specs (look for `### SPEC-NNN:` headers)
- If no specs found: print `No specs found in specs/ — run /generate-specs or /create-spec first` and stop

---

## Step 2: Extract testable requirements

For each spec, extract requirements into a structured list:

### What to extract:

1. **MUST requirements** — these become test cases that MUST pass
2. **MUST NOT requirements** — these become negative test cases (verify rejection/error)
3. **SHOULD requirements** — these become test cases marked as advisory (non-blocking)
4. **Validation checklists** — items under `**Validation**:` or `**Test**:` sections
5. **Numeric constraints** — timeouts, limits, sizes → boundary tests

### For each requirement, determine:

- **Test name**: MUST follow the pattern `Test<SPEC-ID>_<Requirement>` (Go: `TestSPEC001_ValidateInput`, Python: `test_spec001_validate_input`, JS/TS: `it("SPEC-001: validates input")`). This naming convention is required — it enables filtered test runs (`-run "SPEC"`, `-k "spec"`) and traceability via `grep "SPEC-"`
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

---

## Step 3: Locate source code for test targets

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
   - `Glob` for existing test files covering this module
   - If tests already exist: read them to understand the test style and avoid duplicates
   - Skip requirements that already have corresponding test cases

---

## Step 4: Generate test files

### File placement rules:

| Language | Convention | Location |
|----------|-----------|----------|
| Go | Test file next to source | Same directory as source file |
| TypeScript (jest) | `__tests__` dir or co-located | `src/__tests__/cache.test.ts` or `src/cache.test.ts` |
| Python (pytest) | `tests/` mirror of src | `tests/test_cache.py` |
| Rust | Inline `#[cfg(test)]` or `tests/` | Same file or `tests/cache_test.rs` |

**Always match existing project conventions** — if the project already has tests, follow their pattern exactly.

### Test file structure:

Each generated test file MUST include:

1. **Header comment** with generation metadata:
   ```
   // Generated from SPEC-NNN: <Spec Title>
   // Generated by /generate-tests on <YYYY-MM-DD>
   // Review and customize — these are starting points, not final tests
   ```

2. **Imports** matching the project's test framework and source module

3. **Test setup/teardown** (if needed):
   - Database connections, temp dirs, mock servers
   - Use the project's existing test helper patterns if any

4. **One test function per MUST requirement**:
   - Test name includes the spec ID for traceability
   - Comment links back to the requirement text
   - Arrange → Act → Assert structure
   - Meaningful assertion messages

5. **Negative tests for MUST NOT requirements**:
   - Verify the system rejects/prevents the prohibited behavior
   - Assert specific error types or messages where possible

6. **Advisory tests for SHOULD requirements**:
   - Same structure as MUST tests
   - Marked with a comment: `// Advisory (SHOULD) — failure is a warning, not a blocker`
   - **Universal semantic: run the test, warn on failure, do not fail the suite**
   - In Go: wrap assertion in `if` and use `t.Logf("SHOULD warning: ...")` instead of `t.Fatal`/`t.Error`
   - In pytest: use `warnings.warn("SHOULD: ...")` instead of `assert`, or `@pytest.mark.filterwarnings`
   - In jest: use `console.warn("SHOULD: ...")` in the catch block instead of letting the assertion fail the suite

### Test quality rules:

- **Test the behavior, not the implementation** — assert outcomes, not internal state
- **One assertion per test** where practical (multiple related assertions are OK)
- **Meaningful test data** — use realistic values, not `"test"` / `123` / `foo`
- **No mocking unless necessary** — prefer real dependencies when feasible
- **DRY setup** — use test helpers for repeated setup, but keep each test readable
- **Edge cases for numeric constraints** — test at boundary, below, and above

---

## Step 5: Write files

For each test file:

1. Check if the file already exists
   - If yes: **do not overwrite** — create a separate spec-specific test file (e.g., `responses_spec001_test.go`, `test_spec001_cache.py`). Do not append to existing test files — it risks import breakage and merge conflicts
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

---

## Step 6: Run tests and report

Run the project's test command:

| Language | Command |
|----------|---------|
| Go | `go test ./... -run "SPEC" -v` |
| TypeScript | `npx jest --testPathPattern="spec" --verbose` or `npx vitest run` |
| Python | `pytest tests/ -k "spec" -v` |
| Rust | `cargo test spec -- --nocapture` |

### Report format:

```
/generate-tests complete

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
  2. Update the spec if the requirement is no longer valid (/update-spec)

Traceability: each test is tagged with its source spec ID.
  grep "Generated from SPEC" to find all spec-driven tests.
```

---

## Step 7: Update specs/TDD.md (optional)

If `specs/TDD.md` exists, add a `Test Coverage` column to the spec index table:

```markdown
| ID | Title | Status | Test Coverage |
|----|-------|--------|---------------|
| SPEC-001 | Response Caching | INFERRED | 3/3 generated |
| SPEC-002 | Analysis Queue | INFERRED | 5/5 generated |
```

---

## Error Handling

- **No specs found**: suggest `/generate-specs` or `/create-spec`
- **No test framework detected**: ask user which framework to use
- **Source module not found for a requirement**: generate a stub test with `// TODO: locate source module` and skip assertions
- **Test file already exists with same test names**: skip duplicates, only add new tests
- **Tests fail to compile**: fix syntax issues immediately; if the fix isn't obvious, leave a `// TODO` comment and move on
- **Test run times out**: cap test execution at 60 seconds; report timed-out tests separately

---

## Relationship to Other Commands

| Command | Direction | Purpose |
|---------|-----------|---------|
| `/generate-specs` | Code → Specs | Reverse-engineer specs from code |
| `/generate-tests` | **Specs → Tests** | Generate tests from specs |
| `/reflect-specs` | Specs ↔ Code | Audit alignment (no test generation) |
| `/check-specs` | Specs → Code | Lightweight alignment check |
| `/create-spec` | User → Spec | Guided spec authoring |

Together, `/generate-specs` + `/generate-tests` form a full loop:
```
Code → /generate-specs → Specs → /generate-tests → Tests → verify → Code
```
