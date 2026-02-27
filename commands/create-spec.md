# Create New Specification

You are helping the user create a new TDD specification through an interactive interview process.

## Workflow

### Step 1: Interview
Ask the user about their feature idea:
- What is the feature/behavior being specified?
- What problem does it solve?
- What are the key requirements (MUST behaviors)?
- What are the edge cases to handle?
- Are there any related existing specs?

### Step 2: Determine Category
Based on the feature, suggest and confirm the appropriate category:
- **core** (SPEC-XXX): Main application features and behaviors
- **performance** (PERF-XXX): Performance requirements and optimizations
- **safety** (SAFE-XXX): Concurrency, data integrity, crash prevention
- **compatibility** (COMPAT-XXX): Cross-platform, version compatibility
- **architecture** (ARCH-XXX): System design and structural decisions

### Step 2.5: Conflict Scan
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
   - [U] Update conflicting existing spec after creation (use `/update-spec` once created)
   - [P] Proceed anyway — conflict documented as known issue in new spec's Overview
   ```
   Wait for user decision before continuing.
5. If no conflicts found, proceed silently to Step 3

### Step 3: Generate ID
Find the next available ID by scanning existing specs in `specs/<category>/`:
- For core: Find highest SPEC-XXX number, increment
- For performance: Find highest PERF-XXX number, increment
- For safety: Find highest SAFE-XXX number, increment
- For compatibility: Find highest COMPAT-XXX number, increment
- For architecture: Find highest ARCH-XXX number, increment

### Step 4: Create Spec File
Create the spec file at `specs/<category>/<ID>-<kebab-case-title>.md` with this format:

```markdown
# <ID>: <Title>

**Status**: 🚧 NEW
**Category**: <Category>
**Created**: <YYYY-MM-DD>

---

## Overview

<Brief description of what this spec covers>

---

## MUST

<Bulleted list of required behaviors - these are the contract>

---

## Test

<Concrete test steps to verify the MUST requirements>

---

## Validation

<Checkbox list for manual verification>
- [ ] <Validation item 1>
- [ ] <Validation item 2>

---

## Version History

| Date | Change |
|------|--------|
| <YYYY-MM-DD> | Initial spec created |
```

### Step 5: Update TDD.md Index
Add the new spec to `specs/TDD.md`:
1. Add row to Quick Status Table (alphabetically by ID within category)
2. Add to appropriate Navigation by Category section
3. Add entry to Version History table at bottom

## Important Notes

- Keep MUST requirements concrete and testable
- Avoid vague language like "should be fast" - use measurable criteria
- Test cases should be specific enough for anyone to follow
- Ask clarifying questions before finalizing the spec
