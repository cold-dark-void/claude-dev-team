---
name: create-spec
description: Guided interview to create a new behavioral spec in specs/ — includes
  conflict scan against existing specs, category selection, and TDD.md index update.
  Usage /create-spec
---

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

### Step 5: Update TDD.md Index
Add the new spec to `specs/TDD.md`:
1. Add a row to the `## Spec Index` table (keep IDs in ascending order within category). Use columns `| ID | Title | Status | Coverage |` — set Status to `DRAFT` for a newly-created spec.
2. Add an entry to the `## Version History` table at bottom (`| Date | Change |` format).

## Important Notes

- Keep MUST requirements concrete and testable
- Avoid vague language like "should be fast" - use measurable criteria
- Test cases should be specific enough for anyone to follow
- Ask clarifying questions before finalizing the spec
