# Audit & Validate Specs

You are helping the user verify spec quality and implementation status.

## Two Modes

### Mode 1: Audit (Default)
Run format and completeness checks across all specs.

### Mode 2: Validate (with spec ID argument)
Run implementation validation for a specific spec.

---

## Audit Mode

Run these checks on all spec files in `specs/`:

### Format Compliance
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

### Content Quality
- [ ] MUST requirements are concrete (not vague)
- [ ] Test cases are actionable (not placeholders like "TBD")
- [ ] Validation checkboxes exist

### Index Integrity (TDD.md)
- [ ] All spec files are listed in Quick Status Table
- [ ] All links in TDD.md point to existing files
- [ ] No orphaned spec files (files not in TDD.md)
- [ ] Status badges match between TDD.md and spec files

### Report Format
```
## Spec Audit Report

### Summary
- Total specs: XX
- Passing: XX
- Issues found: XX

### Issues

#### SPEC-XXX: Missing Version History section
#### SPEC-YYY: Test section contains "TBD"
#### TDD.md: Broken link to SPEC-ZZZ

### Recommendations
- <actionable suggestions>
```

---

## Validate Mode

When user provides a spec ID (e.g., `/check-specs SPEC-012`):

### Step 1: Read the Spec
Load the full spec file content.

### Step 2: Verify MUST Requirements
For each MUST requirement:
1. Search codebase for implementation
2. Verify the code matches the requirement
3. Note any gaps or discrepancies

### Step 3: Run Test Cases
For each test case in the Test section:
1. Identify what code/behavior is being tested
2. Check if automated tests exist
3. If manual test, provide steps to execute

### Step 4: Report
```
## Validation Report: SPEC-XXX

### MUST Requirements
- [x] Requirement 1: Implemented in `file.go:123`
- [ ] Requirement 2: NOT FOUND in codebase
- [x] Requirement 3: Implemented in `other.go:456`

### Test Coverage
- Test case 1: Covered by `file_test.go:TestXxx`
- Test case 2: Manual test required

### Gaps
- <list any missing implementations>
- <list any failing tests>

### Recommendations
- <specific actions to fix gaps>
```

---

## Usage Examples

```
/check-specs           # Run audit on all specs
/check-specs SPEC-012  # Validate specific spec
/check-specs audit     # Explicit audit mode
```
