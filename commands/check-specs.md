# Audit & Validate Specs

You are helping the user verify spec quality and implementation status.

## Two Modes

### Mode 1: Audit (Default)
Run format, completeness, and code alignment checks across all specs.

### Mode 2: Validate (with spec ID argument)
Run implementation validation for a specific spec against actual source code.

---

## Audit Mode

### Phase 1: Format & Index Checks

Run these checks on all spec files in `specs/`:

#### Format Compliance
For each spec file, verify:
- [ ] Has `# <ID>: <Title>` header
- [ ] Has `**Status**:` line with valid status
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
- [ ] All spec files are listed in Quick Status Table
- [ ] All links in TDD.md point to existing files
- [ ] No orphaned spec files (files not in TDD.md)
- [ ] Status badges match between TDD.md and spec files

---

### Phase 2: Code Alignment Audit

1. `Glob specs/**/*.md` — if no results, print "No spec files found — skipping code alignment" and stop Phase 2
2. Select the **3–5 most recently modified specs** by examining the most recent date in each spec's Version History table; note at the top of Phase 2 output: "Sampled N specs (most recently updated)"
3. For each sampled spec:
   a. Extract all MUST requirements as a list
   b. Derive **search keywords**: specific nouns (feature names, data types, identifiers), verbs (operations), numeric constraints — prefer unique identifiers over generic words
   c. `Grep` source files using those keywords (exclude paths: `specs/`, `.claude/`, `node_modules/`, `dist/`, `vendor/`; exclude file extensions: `*.md`, `*.txt`, `*.json`, `*.yaml`, `*.yml`, `*.toml`, `*.lock`)
   d. Read relevant files with `-C 10` context around keyword matches
4. For each MUST requirement, classify:
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
```

---

## Validate Mode

When user provides a spec ID (e.g., `/check-specs SPEC-012`):

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
1. **Detect project language**: check for `package.json`, `go.mod`, `Cargo.toml`, `pyproject.toml`, `*.csproj` — note which was found
2. **Glob for relevant extensions**: e.g., `**/*.go`, `**/*.ts`, `**/*.py`, `**/*.rs` (exclude `specs/`, `.claude/`, `node_modules/`, `dist/`, `vendor/`, `*.md`)
3. **Grep with most discriminating keywords** from Step 2; use `output_mode: "content"` with `-C 10` to read context around matches
4. If >8 files match, narrow by combining two specific keywords (AND search via two sequential Greps, intersect results)
5. Read the most relevant files (at minimum: functions/methods within 10 lines of keyword matches)
6. **Graceful fallback**: if no source files found after Glob + Grep, print "No source files found — code alignment skipped" and proceed to Step 6 with only spec-level observations

### Step 4: Reason Per MUST Requirement
For each MUST requirement:
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

---

## Usage Examples

```
/check-specs           # Run audit on all specs (Phase 1 + Phase 2)
/check-specs SPEC-012  # Validate specific spec against source code
/check-specs audit     # Explicit audit mode
```
