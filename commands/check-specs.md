---
name: check-specs
description: Audit spec format + code alignment (Phase 1 format/index, Phase 2
  MATCH/MISSING/DIFFERS per requirement; opt-in Phase 3 MUST→test matrix with
  --tests). Run with a spec ID to validate a single spec against source code.
  Usage /check-specs, /check-specs SPEC-012, /check-specs --tests
agent: build
---

# Audit & Validate Specs

You are helping the user verify spec quality and implementation status.

## Two Modes

### Mode 1: Audit (Default)
Run format, completeness, and code alignment checks across all specs.
With `--tests`, also run Phase 3 (MUST→test coverage matrix) after Phase 2.

### Mode 2: Validate (with spec ID argument)
Run implementation validation for a specific spec against actual source code.
With `--tests`, also run Phase 3 for that single spec after the validation report.

### Flags (both modes)

| Flag | Effect |
|------|--------|
| *(none)* | Phase 1 + Phase 2 only. Output MUST be identical to pre-Phase-3 behavior — no Phase 3 section. |
| `--tests` | After Phase 2 / validation report, append Phase 3 MUST→test matrix. Report-only: exit 0 even if rows are MISSING. |
| `--tests --gate[=N]` | Same as `--tests`, then fail closed if total MISSING > N (default N=0). Print `GATE FAIL: Y MISSING exceeds threshold N` and exit non-zero. **Not wired into `/release`** — available for optional preflight only. |

Parse flags from the invocation; strip them before treating remaining tokens as a spec ID.

---

## Audit Mode

### Phase 1: Format & Index Checks

Run these checks on all spec files in `specs/`:

#### Format Compliance
These 9 checks enforce the **SPEC-008 Spec Format contract** (see `specs/core/SPEC-008-spec-management.md § Spec Format`). For each spec file, verify:
- [ ] Has `# <ID>: <Title>` header
- [ ] Has `**Status**:` line — value MUST be one of the lifecycle states: `INFERRED`, `DRAFT`, `ACTIVE`, `APPROVED`, or `DEPRECATED` (or `INFERRED — …` prefix form)
- [ ] Has `**Category**:` line
- [ ] Has `**Created**:` date line
- [ ] Has `## Overview` section
- [ ] Has `## MUST` section with bullet points
- [ ] Has `## Test` section with concrete steps
- [ ] Has `## Validation` section with checkboxes
- [ ] Has `## Version History` table

#### Content Quality
- [ ] MUST requirements are concrete (not vague)
- [ ] Test cases are actionable (not placeholders like "TBD")
- [ ] Validation checkboxes exist

#### Index Integrity (TDD.md)
- [ ] All spec files are listed in the `## Spec Index` table (canonical columns: `| ID | Title | Status | Coverage |`)
- [ ] All links in TDD.md point to existing files
- [ ] No orphaned spec files (files not in TDD.md)
- [ ] Status values in TDD.md `Status` column match the spec file's `**Status**:` line

---

### Phase 2: Code Alignment Audit

1. `Glob specs/**/*.md` (the category-agnostic enumerator, per SPEC-008 § Spec Discovery; TDD.md is the index, not a governed spec) — if no results, print "No spec files found — skipping code alignment" and stop Phase 2
2. Select the **3–5 most recently modified specs** by examining the most recent date in each spec's Version History table; note at the top of Phase 2 output: "Sampled N specs (most recently updated)"
3. For each sampled spec:
   a. Extract all MUST requirements as a list
   b. Derive **search keywords**: specific nouns (feature names, data types, identifiers), verbs (operations), numeric constraints — prefer unique identifiers over generic words
   c. `Grep` source files using those keywords, excluding non-product sources — the canonical alignment exclude set (per SPEC-008 § Source Exclusions):

<!-- include: skills/spec-tooling/source-exclude.md agent=spec -->
```text
Exclude paths:      specs/  .claude/  node_modules/  dist/  build/  target/  vendor/  .git/
Exclude extensions: *.md  *.txt  *.json  *.yaml  *.yml  *.toml  *.lock  *.sum  *.pb.go  *_gen.*  *_generated.*
```
<!-- /include -->

   d. Read relevant files with `-C 10` context around keyword matches
4. For each MUST requirement, classify (the post-hoc alignment verdicts, per SPEC-008 § Code-Alignment Verdicts):
   - **MATCH** — code clearly satisfies the requirement; cite `file:~line`
   - **MISSING** — no code found implementing this behavior
   - **DIFFERS** — code exists but behavior contradicts the requirement; cite `file:~line`
5. Scan code in the feature area for behavior **not mentioned in the spec** → flag as **UNDOCUMENTED** (drift)
6. If Grep returns no source files for any spec, print "No source files found for <SPEC-ID> — code alignment skipped for this spec"

#### Phase 2 Report Format
```
### Code Alignment Summary
Sampled N specs (most recently updated): SPEC-XXX, SPEC-YYY, ...

| Spec | Requirement (truncated) | Status | Evidence |
|------|------------------------|--------|----------|
| SPEC-XXX | MUST store user data... | MATCH | storage.go:~42 |
| SPEC-XXX | MUST validate on write... | MISSING | — |
| SPEC-YYY | MUST limit to 100ms... | DIFFERS | handler.go:~88 (no timeout enforced) |

### Undocumented Behavior (Drift)
- SPEC-XXX: `cache.go:~210` implements retry logic not mentioned in spec
- SPEC-YYY: No undocumented behavior found

### Phase 2 Summary
- X MATCH / Y MISSING / Z DIFFERS / N undocumented behaviors
```

---

### Phase 3: Spec→Test Coverage Matrix (opt-in `--tests` only)

**Skip this entire section unless `--tests` is present.** Without the flag, do not emit a Phase 3 heading, table, or summary — Phase 1 + Phase 2 output stays byte-identical to a run without `--tests` (P3-M1, P3-M5).

Phase 3 answers "does each MUST have a test?" — **not** "does code implement the MUST?" (that is Phase 2). Do **not** re-run Phase 2 greps, do **not** search product source for implementation evidence, and do **not** emit MATCH / DIFFERS / UNDOCUMENTED (P3-M7). A requirement may be Phase-2 MATCH and Phase-3 MISSING at the same time; the `Coverage` column disambiguates the shared word "MISSING".

#### Scope (P3-M1)

- **Audit mode:** same 3–5 specs Phase 2 sampled — do not define a third scope.
- **Validate mode:** the single named spec only.
- Matrix rows = MUST / MUST NOT bullets only. Exclude SHOULD (advisory).

#### Step 1: Detect mapping path

Check the canonical 5 language markers (per SPEC-008 § Project-Language Markers): `go.mod`, `package.json`, `Cargo.toml`, `pyproject.toml` (fallback `setup.py`), `*.csproj`.

- **Any marker present → framework path (P3-M3)**
- **No marker → frameworkless path (P3-M4)** — this plugin (pure markdown/JSON/bash)

#### Step 2a: Framework path (P3-M3)

1. Locate TEST files only using the per-language patterns `/generate-tests` uses (`*_test.go`, `*.test.ts` / `__tests__/`, `tests/test_*.py`, `tests/*.rs`, `*.Tests/*.cs`, etc.). Do **not** grep product source.
2. A test is **TAGGED** to spec `<PREFIX>-<NNN>` (prefix ∈ SPEC|PERF|SAFE|COMPAT|ARCH) when EITHER (P3-M2 — single normative definition; cite SPEC-008, do not fork):
   - **(a) Name/description match** — test name contains the spec ID with hyphen removed or replaced by `_`, case-insensitive (forms `/generate-tests` already emits: Go `TestSPEC001_...`, Python `test_spec001_...` / `spec_001`), **or** test description contains the literal ID (JS/TS `it("SPEC-001: ...")`); OR
   - **(b) File header** — file carries `Generated from <PREFIX>-<NNN>` (the `/generate-tests` metadata header).
3. For each MUST requirement, classify exactly one of:
   - **COVERED** — ≥1 tagged test asserts the behavior; evidence = test name + `file:~line`
   - **MISSING** — no tagged test asserts it; evidence = `—`

#### Step 2b: Frameworkless path (P3-M4)

Used when no language marker matches (including this plugin).

1. Read the spec's `## Test` section. Map each MUST to Test entries that address it (keyword/behavior match — same judgment as a human reading the Test list, not Phase-2 code search).
2. For every script/fixture a Test entry names (e.g. `skills/spec-tooling/check-format.sh`, `sync-includes.py`, `skills/docs-drift/test.sh`), **Glob** that path and confirm it exists.
3. Classify each MUST:
   - **COVERED** — ≥1 Test entry addresses the MUST **and** every script that entry names exists. Evidence = `Test #k` + script path(s) (or `Test #k (prose only)` if no script named).
   - **MISSING** — no Test entry addresses it, **or** every candidate entry names a script that does not exist (a nonexistent script MUST NOT count as COVERED).

#### Step 3: Emit report (P3-M5)

Append **after** Phase 2 (audit) or after the validation report (validate). Phase 1/2 sections above MUST remain unchanged by this step.

```
### Phase 3: Spec→Test Coverage
Mode: framework | frameworkless
Scope: SPEC-XXX, SPEC-YYY, ...

#### SPEC-XXX
| # | Requirement (truncated) | Coverage | Evidence |
|---|------------------------|----------|----------|
| 1 | MUST store user data... | COVERED | TestSPEC001_StoreEncrypted + crypto_test.go:~12 |
| 2 | MUST reject over 1MB... | MISSING | — |

#### SPEC-YYY
| # | Requirement (truncated) | Coverage | Evidence |
|---|------------------------|----------|----------|
| 1 | MUST validate format... | COVERED | Test #3 + skills/spec-tooling/check-format.sh |

Phase 3 Summary: X COVERED / Y MISSING across N specs
```

Frameworkless evidence example: `Test #7 + skills/spec-tooling/check-format.sh` (not a test-function name).

#### Step 4: Gate (P3-M6) — only with `--gate`

- `--tests` alone → always continue / exit 0 even if Y > 0 (report-only).
- `--tests --gate` or `--tests --gate=N` → if total MISSING `Y` > threshold `N` (default `N=0` when `--gate` has no value):
  ```
  GATE FAIL: Y MISSING exceeds threshold N
  ```
  Exit non-zero. Do **not** invoke this from `/release` or any other command by default — document only; callers opt in explicitly.

#### Tag convention note (generate-tests compatibility)

P3-M2 is the single normative tag definition (SPEC-008 § Spec-test coverage matrix). `/generate-tests` emits matching forms; Phase 3 only *recognizes* them. Revisions are additive-only so previously generated tests stay tagged without edits. Do not maintain a divergent copy of the tag rules here or in generate-tests.

---

### Full Audit Report Format
```
## Spec Audit Report

### Phase 1 Summary
- Total specs: XX
- Passing: XX
- Issues found: XX

### Phase 1 Issues

#### SPEC-XXX: Missing Version History section
#### SPEC-YYY: Test section contains "TBD"
#### TDD.md: Broken link to SPEC-ZZZ

### Phase 1 Recommendations
- <actionable suggestions>

---

### Phase 2: Code Alignment
<Phase 2 output as above>

---

### Phase 3: Spec→Test Coverage   ← only when --tests
<Phase 3 output as above; omit this entire section without --tests>
```

---

## Validate Mode

When user provides a spec ID (e.g., `/check-specs SPEC-012` or `/check-specs SPEC-012 --tests`):

### Step 1: Read the Spec
Load the full spec file content.

### Step 2: Extract Search Keywords
From the spec's title, Overview, and each MUST bullet, extract:
- Specific **nouns**: feature names, data types, named identifiers, module names
- **Verbs**: operations the system must perform
- **Numeric constraints**: timeouts, limits, counts, thresholds
- **Named identifiers**: function names, config keys, API endpoints mentioned

Write these as a flat keyword list before proceeding. Prefer specific, discriminating terms over generic words like "data" or "handle".

### Step 3: Find Relevant Source Files
1. **Detect project language** (the canonical 5-marker map, per SPEC-008 § Project-Language Markers): check for `go.mod`, `package.json`, `Cargo.toml`, `pyproject.toml` (fallback `setup.py`), `*.csproj` — note which was found
2. **Glob for relevant extensions**: e.g., `**/*.go`, `**/*.ts`, `**/*.py`, `**/*.rs`, excluding non-product sources — the canonical alignment exclude set (per SPEC-008 § Source Exclusions):

<!-- include: skills/spec-tooling/source-exclude.md agent=spec -->
```text
Exclude paths:      specs/  .claude/  node_modules/  dist/  build/  target/  vendor/  .git/
Exclude extensions: *.md  *.txt  *.json  *.yaml  *.yml  *.toml  *.lock  *.sum  *.pb.go  *_gen.*  *_generated.*
```
<!-- /include -->

3. **Grep with most discriminating keywords** from Step 2; use `output_mode: "content"` with `-C 10` to read context around matches
4. If >8 files match, narrow by combining two specific keywords (AND search via two sequential Greps, intersect results)
5. Read the most relevant files (at minimum: functions/methods within 10 lines of keyword matches)
6. **Graceful fallback**: if no source files found after Glob + Grep, print "No source files found — code alignment skipped" and proceed to Step 6 with only spec-level observations

### Step 4: Reason Per MUST Requirement
For each MUST requirement (verdicts per SPEC-008 § Code-Alignment Verdicts):
- State the requirement verbatim
- State what the code does in the relevant area
- Assign verdict:
  - **MATCH** — code satisfies requirement; cite `file:~line`
  - **MISSING** — no implementation found
  - **DIFFERS** — implementation contradicts requirement; cite `file:~line` and explain discrepancy

### Step 5: Detect Drift
Scan the code areas found in Step 3 for behavior in the same feature domain that the spec does **not** mention. Flag each as **UNDOCUMENTED**. If nothing found, write "No undocumented behavior detected."

### Step 6: Report
```
## Validation Report: SPEC-XXX

### Requirements

| # | Requirement (truncated) | Status | Evidence |
|---|------------------------|--------|----------|
| 1 | MUST store user data encrypted... | MATCH | crypto.go:~34 |
| 2 | MUST reject requests over 1MB... | MISSING | — |
| 3 | MUST complete within 200ms... | DIFFERS | handler.go:~88 (no timeout set) |

### Undocumented Behavior
- `cache.go:~210`: implements a 3-retry loop not mentioned in spec

### Summary
- X MATCH / Y MISSING / Z DIFFERS / N undocumented

### Recommended Actions
- <specific file:line actions to fix MISSING/DIFFERS items>
- <whether to update spec to document undocumented behavior>
```

### Step 7: Phase 3 (only with `--tests`)
If `--tests` was passed, run **Phase 3** for this single spec (same procedure as Audit Mode Phase 3 — framework or frameworkless mapping, COVERED/MISSING matrix, summary). Append after Step 6. Without `--tests`, stop after Step 6 — no Phase 3 section.

If `--tests --gate[=N]` was passed, apply the gate after the matrix (print `GATE FAIL: …` and exit non-zero when MISSING exceeds N).

---

## Usage Examples

```
/check-specs                      # Audit: Phase 1 + Phase 2 only
/check-specs SPEC-012             # Validate one spec against source code
/check-specs audit                # Explicit audit mode
/check-specs --tests              # Audit + Phase 3 matrix (same 3–5 specs as Phase 2)
/check-specs SPEC-012 --tests     # Validate one spec + Phase 3 matrix for it
/check-specs --tests --gate       # Phase 3; fail if any MISSING (threshold 0)
/check-specs --tests --gate=5     # Phase 3; fail only if MISSING > 5
```
