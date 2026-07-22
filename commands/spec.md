---
name: spec
description: Unified spec management entry — audit/validate, create, find, list,
  update, reverse-generate from code, generate tests, and full-system reflect.
  Usage /spec <check|create|find|list|update|generate|tests|reflect> [args...]
argument-hint: "<check|create|find|list|update|generate|tests|reflect> [args...]"
agent: build
---

# /spec — Unified Spec Management

Single entry point for all spec lifecycle operations (SPEC-008).

## Dispatch

Parse the first positional argument as `<sub>`. If absent or unknown, print the
sub list below and stop. Remaining args (including flags) pass through unchanged
to the routed sub-behavior.

| Sub | Strategy | Source / target |
|-----|----------|-----------------|
| `check` | **inline** | transplanted from `commands/check-specs.md` |
| `create` | **inline** | transplanted from `commands/create-spec.md` |
| `find` | **inline** | transplanted from `commands/find-spec.md` |
| `list` | **inline** | transplanted from `commands/list-specs.md` |
| `update` | **inline** | transplanted from `commands/update-spec.md` |
| `generate` | **skill-delegate** | `skills/spec-tooling/SKILL.md` sub=`generate` |
| `tests` | **skill-delegate** | `skills/spec-tooling/SKILL.md` sub=`tests` |
| `reflect` | **skill-delegate** | `skills/spec-tooling/SKILL.md` sub=`reflect` |

```
/spec check [--tests] [--gate[=N]] [SPEC-ID]
/spec create
/spec find <keyword>
/spec list
/spec update [SPEC-ID]
/spec generate [<path>]
/spec tests [SPEC-NNN] [--dry-run]
/spec reflect
```

Unknown/missing sub → print this table and stop. Do not guess a default sub.

---

## Sub: `check`

You are helping the user verify spec quality and implementation status.

### Two Modes

#### Mode 1: Audit (Default)
Run format, completeness, and code alignment checks across all specs.
With `--tests`, also run Phase 3 (MUST→test coverage matrix) after Phase 2.

#### Mode 2: Validate (with spec ID argument)
Run implementation validation for a specific spec against actual source code.
With `--tests`, also run Phase 3 for that single spec after the validation report.

#### Flags (both modes)

| Flag | Effect |
|------|--------|
| *(none)* | Phase 1 + Phase 2 only. Output MUST be identical to pre-Phase-3 behavior — no Phase 3 section. |
| `--tests` | After Phase 2 / validation report, append Phase 3 MUST→test matrix. Report-only: exit 0 even if rows are MISSING. |
| `--tests --gate[=N]` | Same as `--tests`, then fail closed if total MISSING > N (default N=0). Print `GATE FAIL: Y MISSING exceeds threshold N` and exit non-zero. **Not wired into `/release`** — available for optional preflight only. |

Parse flags from the invocation; strip them before treating remaining tokens as a spec ID.

---

### Audit Mode

#### Phase 1: Format & Index Checks

Run these checks on all spec files in `specs/`:

##### Format Compliance
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

##### Content Quality
- [ ] MUST requirements are concrete (not vague)
- [ ] Test cases are actionable (not placeholders like "TBD")
- [ ] Validation checkboxes exist

##### Index Integrity (TDD.md)
- [ ] All spec files are listed in the `## Spec Index` table (canonical columns: `| ID | Title | Status | Coverage |`)
- [ ] All links in TDD.md point to existing files
- [ ] No orphaned spec files (files not in TDD.md)
- [ ] Status values in TDD.md `Status` column match the spec file's `**Status**:` line

---

#### Phase 2: Code Alignment Audit

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

##### Phase 2 Report Format
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

#### Phase 3: Spec→Test Coverage Matrix (opt-in `--tests` only)

**Skip this entire section unless `--tests` is present.** Without the flag, do not emit a Phase 3 heading, table, or summary — Phase 1 + Phase 2 output stays byte-identical to a run without `--tests` (P3-M1, P3-M5).

Phase 3 answers "does each MUST have a test?" — **not** "does code implement the MUST?" (that is Phase 2). Do **not** re-run Phase 2 greps, do **not** search product source for implementation evidence, and do **not** emit MATCH / DIFFERS / UNDOCUMENTED (P3-M7). A requirement may be Phase-2 MATCH and Phase-3 MISSING at the same time; the `Coverage` column disambiguates the shared word "MISSING".

##### Scope (P3-M1)

- **Audit mode:** same 3–5 specs Phase 2 sampled — do not define a third scope.
- **Validate mode:** the single named spec only.
- Matrix rows = MUST / MUST NOT bullets only. Exclude SHOULD (advisory).

##### Step 1: Detect mapping path

Check the canonical 5 language markers (per SPEC-008 § Project-Language Markers): `go.mod`, `package.json`, `Cargo.toml`, `pyproject.toml` (fallback `setup.py`), `*.csproj`.

- **Any marker present → framework path (P3-M3)**
- **No marker → frameworkless path (P3-M4)** — this plugin (pure markdown/JSON/bash)

##### Step 2a: Framework path (P3-M3)

1. Locate TEST files only using the per-language patterns `/spec tests` uses (`*_test.go`, `*.test.ts` / `__tests__/`, `tests/test_*.py`, `tests/*.rs`, `*.Tests/*.cs`, etc.). Do **not** grep product source.
2. A test is **TAGGED** to spec `<PREFIX>-<NNN>` (prefix ∈ SPEC|PERF|SAFE|COMPAT|ARCH) when EITHER (P3-M2 — single normative definition; cite SPEC-008, do not fork):
   - **(a) Name/description match** — test name contains the spec ID with hyphen removed or replaced by `_`, case-insensitive (forms `/spec tests` already emits: Go `TestSPEC001_...`, Python `test_spec001_...` / `spec_001`), **or** test description contains the literal ID (JS/TS `it("SPEC-001: ...")`); OR
   - **(b) File header** — file carries `Generated from <PREFIX>-<NNN>` (the `/spec tests` metadata header).
3. For each MUST requirement, classify exactly one of:
   - **COVERED** — ≥1 tagged test asserts the behavior; evidence = test name + `file:~line`
   - **MISSING** — no tagged test asserts it; evidence = `—`

##### Step 2b: Frameworkless path (P3-M4)

Used when no language marker matches (including this plugin).

1. Read the spec's `## Test` section. Map each MUST to Test entries that address it (keyword/behavior match — same judgment as a human reading the Test list, not Phase-2 code search).
2. For every script/fixture a Test entry names (e.g. `skills/spec-tooling/check-format.sh`, `sync-includes.py`, `skills/docs-drift/test.sh`), **Glob** that path and confirm it exists.
3. Classify each MUST:
   - **COVERED** — ≥1 Test entry addresses the MUST **and** every script that entry names exists. Evidence = `Test #k` + script path(s) (or `Test #k (prose only)` if no script named).
   - **MISSING** — no Test entry addresses it, **or** every candidate entry names a script that does not exist (a nonexistent script MUST NOT count as COVERED).

##### Step 3: Emit report (P3-M5)

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

##### Step 4: Gate (P3-M6) — only with `--gate`

- `--tests` alone → always continue / exit 0 even if Y > 0 (report-only).
- `--tests --gate` or `--tests --gate=N` → if total MISSING `Y` > threshold `N` (default `N=0` when `--gate` has no value):
  ```
  GATE FAIL: Y MISSING exceeds threshold N
  ```
  Exit non-zero. Do **not** invoke this from `/release` or any other command by default — document only; callers opt in explicitly.

##### Tag convention note (generate-tests compatibility)

P3-M2 is the single normative tag definition (SPEC-008 § Spec-test coverage matrix). `/spec tests` emits matching forms; Phase 3 only *recognizes* them. Revisions are additive-only so previously generated tests stay tagged without edits. Do not maintain a divergent copy of the tag rules here or in the tests sub.

---

#### Full Audit Report Format
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

### Validate Mode

When user provides a spec ID (e.g., `/spec check SPEC-012` or `/spec check SPEC-012 --tests`):

#### Step 1: Read the Spec
Load the full spec file content.

#### Step 2: Extract Search Keywords
From the spec's title, Overview, and each MUST bullet, extract:
- Specific **nouns**: feature names, data types, named identifiers, module names
- **Verbs**: operations the system must perform
- **Numeric constraints**: timeouts, limits, counts, thresholds
- **Named identifiers**: function names, config keys, API endpoints mentioned

Write these as a flat keyword list before proceeding. Prefer specific, discriminating terms over generic words like "data" or "handle".

#### Step 3: Find Relevant Source Files
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

#### Step 4: Reason Per MUST Requirement
For each MUST requirement (verdicts per SPEC-008 § Code-Alignment Verdicts):
- State the requirement verbatim
- State what the code does in the relevant area
- Assign verdict:
  - **MATCH** — code satisfies requirement; cite `file:~line`
  - **MISSING** — no implementation found
  - **DIFFERS** — implementation contradicts requirement; cite `file:~line` and explain discrepancy

#### Step 5: Detect Drift
Scan the code areas found in Step 3 for behavior in the same feature domain that the spec does **not** mention. Flag each as **UNDOCUMENTED**. If nothing found, write "No undocumented behavior detected."

#### Step 6: Report
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

#### Step 7: Phase 3 (only with `--tests`)
If `--tests` was passed, run **Phase 3** for this single spec (same procedure as Audit Mode Phase 3 — framework or frameworkless mapping, COVERED/MISSING matrix, summary). Append after Step 6. Without `--tests`, stop after Step 6 — no Phase 3 section.

If `--tests --gate[=N]` was passed, apply the gate after the matrix (print `GATE FAIL: …` and exit non-zero when MISSING exceeds N).

---

### Usage Examples (`check`)

```
/spec check                      # Audit: Phase 1 + Phase 2 only
/spec check SPEC-012             # Validate one spec against source code
/spec check audit                # Explicit audit mode
/spec check --tests              # Audit + Phase 3 matrix (same 3–5 specs as Phase 2)
/spec check SPEC-012 --tests     # Validate one spec + Phase 3 matrix for it
/spec check --tests --gate       # Phase 3; fail if any MISSING (threshold 0)
/spec check --tests --gate=5     # Phase 3; fail only if MISSING > 5
```

---

## Sub: `create`

You are helping the user create a new TDD specification through an interactive interview process.

### Workflow

#### Step 1: Interview
Ask the user about their feature idea:
- What is the feature/behavior being specified?
- What problem does it solve?
- What are the key requirements (MUST behaviors)?
- What are the edge cases to handle?
- Are there any related existing specs?

#### Step 2: Determine Category
Based on the feature, suggest and confirm the appropriate category:
- **core** (SPEC-XXX): Main application features and behaviors
- **performance** (PERF-XXX): Performance requirements and optimizations
- **safety** (SAFE-XXX): Concurrency, data integrity, crash prevention
- **compatibility** (COMPAT-XXX): Cross-platform, version compatibility
- **architecture** (ARCH-XXX): System design and structural decisions

#### Step 2.5: Conflict Scan
Discovery procedure: SPEC-008 `### Spec Discovery`. Conflict taxonomy: SPEC-008 `### Spec Conflict Scan` (BLOCKER / WARNING).

1. `Glob specs/**/*.md` — if no results, print "No existing specs — skipping conflict scan" and proceed to Step 3
2. Read all existing spec files; for each, note its ID and extract its MUST requirements
3. Compare the **proposed** MUST requirements (from Step 1 interview) against every existing spec semantically:
   - **BLOCKER** = direct contradiction — both requirements cannot be satisfied simultaneously (e.g., proposed "MUST store tokens as plaintext" vs. SAFE-001 "MUST encrypt all credentials at rest")
   - **WARNING** = scope overlap — same feature domain or shared resource, may create ambiguity or unintended coupling
4. If any conflicts found, present a report before proceeding:
   ```
   ## Conflict Scan Results

   ### BLOCKERS (must resolve before creating)
   - Proposed: "MUST store tokens as plaintext"
     Conflicts with SAFE-001: "MUST encrypt all credentials at rest"

   ### WARNINGS (review recommended)
   - Proposed spec overlaps with AUTH-003 (authentication domain)

   **Decision:**
   - [R] Revise proposed spec → return to Step 1 interview with revised requirements
   - [U] Update conflicting existing spec after creation (use `/spec update` once created)
   - [P] Proceed anyway — conflict documented as known issue in new spec's Overview
   ```
   Wait for user decision before continuing.
5. If no conflicts found, proceed silently to Step 3

#### Step 3: Generate ID
Find the next available ID by scanning existing specs in `specs/<category>/`:
- For core: Find highest SPEC-XXX number, increment
- For performance: Find highest PERF-XXX number, increment
- For safety: Find highest SAFE-XXX number, increment
- For compatibility: Find highest COMPAT-XXX number, increment
- For architecture: Find highest ARCH-XXX number, increment

#### Step 4: Create Spec File
Create the spec file at `specs/<category>/<ID>-<kebab-case-title>.md` with the canonical 9-section skeleton below.

When producing a real spec file:
- Render the literal `<STATUS>` token as `DRAFT` (new specs start at DRAFT in the lifecycle: INFERRED → DRAFT → ACTIVE → APPROVED → DEPRECATED).
- Fill `<PREFIX>-<NNN>` (e.g. `SPEC-019`), `<Title>`, `<YYYY-MM-DD>` (today's date), and replace each `<…>` placeholder with content from the Step 1 interview.
- DO NOT copy the `<!-- include: … -->` / `<!-- /include -->` marker lines into the produced spec file — they are build-time directives only (and sit OUTSIDE the fenced template, so a verbatim copy of the ```markdown block already excludes them).

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

#### Step 5: Update TDD.md Index
Add the new spec to `specs/TDD.md`:
1. Add a row to the `## Spec Index` table (keep IDs in ascending order within category). Use columns `| ID | Title | Status | Coverage |` — set Status to `DRAFT` for a newly-created spec.
2. Add an entry to the `## Version History` table at bottom (`| Date | Change |` format).

### Important Notes (`create`)

- Keep MUST requirements concrete and testable
- Avoid vague language like "should be fast" - use measurable criteria
- Test cases should be specific enough for anyone to follow
- Ask clarifying questions before finalizing the spec

---

## Sub: `find`

You are helping the user search for specifications by keyword.

### Workflow

#### Step 1: Get Search Terms
If the user provided search terms with the command, use those.
Otherwise, ask what they're looking for.

#### Step 2: Search Specs
Search across all governed spec files (per SPEC-008 `### Spec Discovery`):
1. Search spec titles (in filenames and # headers)
2. Search MUST requirements sections
3. Search Overview sections
4. Search Test sections

Enumerate specs with the canonical category-agnostic glob — do NOT hardcode per-category dirs:
- `Glob $MROOT/specs/**/*.md` (where `$MROOT` is the project root resolved by the SPEC-002
  worktree-aware formula; exclude `specs/TDD.md` — that is the index, not a governed spec)

This covers every category dir (`specs/core/`, `specs/performance/`, `specs/safety/`,
`specs/compatibility/`, `specs/architecture/`) AND any new category dir without a per-category list.

#### Step 3: Present Results
For each matching spec, show:
- **Spec ID and Title**
- **Category** (derived from the spec file's subdirectory under `specs/`)
- **Status** (from the Status line in the spec)
- **Context snippet** (the matching text with surrounding context)

Format example:
```
## Search Results for "thumbnail"

### SPEC-004: Thumbnail Generation
**Category**: Core | **Status**: ✅
> Thumbnails are generated at 128x128 pixels maximum dimension...

### SPEC-012: Concurrent Thumbnail Loading
**Category**: Core | **Status**: 🔄 UPDATED
> Worker pool generates thumbnails concurrently...

### SPEC-013: Viewport-Priority Loading
**Category**: Core | **Status**: 🔄 UPDATED
> Visible thumbnails are prioritized in the loading queue...
```

#### Step 4: Offer Next Actions
After showing results, offer:
- Read full spec details for any result
- Update a spec (`/spec update`)
- Create a new related spec (`/spec create`)

### Tips (`find`)

- Search is case-insensitive
- Multiple search terms are ANDed together
- If no results, suggest broader search terms
- Show up to 10 most relevant results

---

## Sub: `list`

You are providing a fast status summary of all specifications.

### Workflow

#### Step 1: Gather Data
Gather data from two sources (per SPEC-008 `### Spec Discovery`):

**A. TDD.md index** — read `specs/TDD.md` to extract:
1. All specs from the `## Spec Index` table (columns: `ID | Title | Status | Coverage`)
2. Lifecycle Status for each spec
3. Categories (derived from ID prefix or Coverage column)
4. `## Version History` entries

**B. Orphan detection** — enumerate all governed spec files with `Glob $MROOT/specs/**/*.md`
(where `$MROOT` is the project root via the SPEC-002 worktree-aware formula; exclude `specs/TDD.md`
— that is the index, not a governed spec). Cross-reference each discovered file against the TDD.md
Spec Index; any governed spec file NOT listed in the index is an ORPHAN and MUST be flagged in the
output (see "Needs Attention" below). This aligns with check Index-Integrity and ensures
spec files that were created but never indexed are visible.

#### Step 2: Generate Summary

Output format:

```
## Spec Overview

### By Category
| Category | Count |
|----------|-------|
| Core | XX |
| Performance | XX |
| Safety | XX |
| Compatibility | XX |
| Architecture | XX |
| **Total** | **XX** |

### By Status
| Status | Count | Specs |
|--------|-------|-------|
| APPROVED | XX | SPEC-011, SPEC-012, ... |
| ACTIVE | XX | SPEC-001, SPEC-013, ... |
| DRAFT | XX | SPEC-017, ... |
| INFERRED | XX | SPEC-002, SPEC-003, ... |
| DEPRECATED | XX | (none) |

### Recent Changes (Last 5)
| Date | Change |
|------|--------|
| 2026-02-10 | Added multi-GUI backend (ARCH-001, SPEC-001) |
| ... | ... |

### Needs Attention
- **DRAFT** (not yet baseline): SPEC-017, ...
- **INFERRED** (needs human review): SPEC-002, SPEC-003, ...
- **ORPHANS** (governed file not in TDD.md Spec Index): specs/safety/SPEC-099-foo.md, ...
```

**Status legend** — lifecycle states (from `## Spec Index` Status column):
- `INFERRED` — machine-generated, needs human review
- `DRAFT` — human-authored, not yet reviewed/activated
- `ACTIVE` — in use, enforced
- `APPROVED` — formally reviewed and signed off
- `DEPRECATED` — superseded or retired

Note: `/spec check` produces a separate REPORT with per-spec verify-status (`PASS / FAIL / WARN`) — that is NOT the spec's lifecycle Status and is not shown here.

#### Step 3: Offer Actions
After the summary, offer:
- View details of specific spec
- Find specs by keyword (`/spec find`)
- Run audit (`/spec check`)
- Create new spec (`/spec create`)

### Tips (`list`)

- Keep output concise - this is meant for quick reference
- Highlight items needing attention (DRAFT, INFERRED)
- Show recent activity to give context on project momentum

---

## Sub: `update`

You are helping the user modify an existing TDD specification.

### Workflow

#### Step 1: Identify Target Spec
If the user hasn't specified which spec:
1. Ask what spec they want to update (by ID, title, or keyword)
2. Search `specs/` directory to find matching specs
3. Confirm the target spec with the user

#### Step 2: Read Current Spec
Read the full content of the target spec file to understand:
- Current MUST requirements
- Existing test cases
- Version history

#### Step 3: Interview About Changes
Ask the user:
- What needs to change?
- Are you adding, modifying, or removing requirements?
- Do any test cases need updating?
- Is this a breaking change to existing behavior?

#### Step 3.5: Cross-Spec Conflict Check
1. `Glob specs/**/*.md` — filter out the target spec's own path. If no other spec files remain, print "No other specs — skipping conflict check" and proceed to Step 4
2. Summarize the proposed changes from Step 3 as three lists:
   - **ADDED**: new requirements being introduced
   - **MODIFIED**: existing requirements being changed (old → new)
   - **REMOVED**: requirements being deleted
3. Read all other spec files; for each changed or added requirement, check semantically:
   - **BLOCKER** = direct contradiction with another spec's MUST requirement
   - **WARNING** = scope overlap with another spec's domain
4. Special case for REMOVED requirements: check if any other spec references or depends on the behavior being removed — flag as WARNING if so
5. If any conflicts found, present report (same format as create Step 2.5) and wait for user decision:
   - **[R]** Revise proposed changes → return to Step 3 interview
   - **[U]** Also update conflicting spec (note which spec to update after this one)
   - **[P]** Proceed anyway — conflict documented
6. If no conflicts, proceed silently to Step 4

#### Step 4: Update Spec File
Make the requested changes to the spec file:
- Update MUST requirements as needed
- Update Test section if test steps change
- Update Validation checkboxes if needed
- **Always add a Version History entry** with today's date and change description

#### Step 4.5: Code Alignment Warning
Only applies to **ADDED** or **MODIFIED** requirements (not removals).

1. Extract keywords from changed requirements (same technique as `check` Validate Step 2: specific nouns, verbs, numeric constraints, named identifiers)
2. `Grep` source files using those keywords, excluding non-product sources — the canonical alignment exclude set (per SPEC-008 § Source Exclusions):

<!-- include: skills/spec-tooling/source-exclude.md agent=spec -->
```text
Exclude paths:      specs/  .claude/  node_modules/  dist/  build/  target/  vendor/  .git/
Exclude extensions: *.md  *.txt  *.json  *.yaml  *.yml  *.toml  *.lock  *.sum  *.pb.go  *_gen.*  *_generated.*
```
<!-- /include -->

3. For each ADDED or MODIFIED requirement, classify current code behavior (the pre-write code-impact taxonomy, per SPEC-008 § Code-Impact Warning — distinct from the post-hoc MATCH/MISSING/DIFFERS/UNDOCUMENTED audit verdicts):
   - **CODE MATCHES** — current code already satisfies the new requirement
   - **CODE CONTRADICTS** — current code does the opposite or would need to change
   - **NO CODE FOUND** — no relevant source files found
4. Output:
   - If all results are CODE MATCHES or NO CODE FOUND: print "Code alignment OK" (or "No source files found — code alignment skipped") and continue
   - If any CODE CONTRADICTS: print a warning block before proceeding:
     ```
     ## Code Alignment Warning

     The following spec changes require code updates:

     ### Requirement: "MUST validate input length ≤ 512 bytes"
     - Current code: `parser.go:~34` accepts unlimited input (no length check)
     - Action needed: add length validation before processing

     ### Requirement: "MUST return 429 on rate limit"
     - Current code: `handler.go:~91` returns 503 on rate limit
     - Action needed: change status code to 429
     ```
     This is informational — proceed to Step 5 after displaying it.

#### Step 5: Update TDD.md
Update `specs/TDD.md`:
1. Change the Status column in the `## Spec Index` table to the appropriate lifecycle word (`DRAFT`, `ACTIVE`, `APPROVED`, or `DEPRECATED`) if the update changes the spec's lifecycle state.
2. Add an entry to the `## Version History` table at bottom with affected spec IDs (`| Date | Change |` format).

### Version History Entry Format

Add to the spec's Version History table:
```markdown
| <YYYY-MM-DD> | <Brief description of change> |
```

Add to TDD.md `## Version History` table:
```markdown
| <YYYY-MM-DD> | <Brief description> (<SPEC-ID>) |
```

### Important Notes (`update`)

- Confirm changes with user before writing
- Preserve existing behaviors unless explicitly changing them
- Breaking changes require explicit user approval
- Always document the reason for the change

---

## Sub: `generate` — skill-delegate → `skills/spec-tooling`

**Do not implement generate behavior here.** Read and follow
`skills/spec-tooling/SKILL.md` with **sub=`generate`** and remaining args
passed through unchanged.

### Routing contract (Task 6 alignment)

Task 6 absorbs `skills/generate-specs/SKILL.md` into `skills/spec-tooling` as an
invocable sub. Until that lands, if `skills/spec-tooling/SKILL.md` does not yet
document a `generate` sub, fall back by reading and following
`skills/generate-specs/SKILL.md` (pre-absorb path) with the same args.

| Invocation | Maps from | Expected behavior |
|------------|-----------|-------------------|
| `/spec generate` | `/generate-specs` | Full codebase scan; Tech Lead decides domain grouping; write INFERRED specs under `specs/core/` |
| `/spec generate <path>` | `/generate-specs <path>` | Limit scan to a package or directory |

Args: optional `<path>` only. No flags in the current surface.

Preserve every MUST from SPEC-008 that generate-specs implements (project-language
markers, source exclusions, INFERRED status, human-review requirement).

---

## Sub: `tests` — skill-delegate → `skills/spec-tooling`

**Do not implement tests-generation behavior here.** Read and follow
`skills/spec-tooling/SKILL.md` with **sub=`tests`** and remaining args
passed through unchanged.

### Routing contract (Task 6 alignment)

Task 6 absorbs `skills/generate-tests/SKILL.md` into `skills/spec-tooling` as an
invocable sub. Until that lands, if `skills/spec-tooling/SKILL.md` does not yet
document a `tests` sub, fall back by reading and following
`skills/generate-tests/SKILL.md` (pre-absorb path) with the same args.

| Invocation | Maps from | Expected behavior |
|------------|-----------|-------------------|
| `/spec tests` | `/generate-tests` | Generate tests for all specs |
| `/spec tests SPEC-NNN` | `/generate-tests SPEC-NNN` | Generate tests for a single spec |
| `/spec tests --dry-run` | `/generate-tests --dry-run` | Show what would be generated; write nothing |

Args: optional `SPEC-NNN` and/or `--dry-run`. Flag parity with generate-tests MUST hold.

Tag forms emitted MUST remain recognizable by `/spec check --tests` Phase 3 (P3-M2 /
SPEC-008 § Spec-test coverage matrix). Do not fork the tag convention.

---

## Sub: `reflect` — skill-delegate → `skills/spec-tooling`

**Do not implement reflect behavior here.** Read and follow
`skills/spec-tooling/SKILL.md` with **sub=`reflect`** and remaining args
passed through unchanged.

### Routing contract (Task 6 alignment)

Task 6 absorbs `skills/reflect-specs/SKILL.md` into `skills/spec-tooling` as an
invocable sub. Until that lands, if `skills/spec-tooling/SKILL.md` does not yet
document a `reflect` sub, fall back by reading and following
`skills/reflect-specs/SKILL.md` (pre-absorb path) with the same args.

| Invocation | Maps from | Expected behavior |
|------------|-----------|-------------------|
| `/spec reflect` | `/reflect-specs` | Full-system health check: inventory → cross-spec conflicts → skill/command consistency → exhaustive code alignment (ALL specs, not sampled) → coverage gaps → interactive confirmation |

Args: none in the current surface (no flags). Phases and interactive pause-for-decision
behavior MUST be preserved verbatim from reflect-specs.

Goes beyond `/spec check` (sampled Phase 2) — exhaustive over every governed spec.

---

## Notes for consumers (Tasks 9 / 11 / 13)

- Prefer `/spec <sub>` in new docs and in-body refs; legacy `/check-specs`,
  `/create-spec`, `/find-spec`, `/list-specs`, `/update-spec`, `/generate-specs`,
  `/generate-tests`, `/reflect-specs` remain until Task 12 stubs them.
- Flag parity examples that must keep working:
  - `/spec check --tests`
  - `/spec check SPEC-012`
  - `/spec check SPEC-012 --tests --gate=5`
  - `/spec tests --dry-run`
  - `/spec generate path/to/pkg`
