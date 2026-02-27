# Update Existing Specification

You are helping the user modify an existing TDD specification.

## Workflow

### Step 1: Identify Target Spec
If the user hasn't specified which spec:
1. Ask what spec they want to update (by ID, title, or keyword)
2. Search `specs/` directory to find matching specs
3. Confirm the target spec with the user

### Step 2: Read Current Spec
Read the full content of the target spec file to understand:
- Current MUST requirements
- Existing test cases
- Version history

### Step 3: Interview About Changes
Ask the user:
- What needs to change?
- Are you adding, modifying, or removing requirements?
- Do any test cases need updating?
- Is this a breaking change to existing behavior?

### Step 3.5: Cross-Spec Conflict Check
1. `Glob specs/**/*.md` — filter out the target spec's own path. If no other spec files remain, print "No other specs — skipping conflict check" and proceed to Step 4
2. Summarize the proposed changes from Step 3 as three lists:
   - **ADDED**: new requirements being introduced
   - **MODIFIED**: existing requirements being changed (old → new)
   - **REMOVED**: requirements being deleted
3. Read all other spec files; for each changed or added requirement, check semantically:
   - **BLOCKER** = direct contradiction with another spec's MUST requirement
   - **WARNING** = scope overlap with another spec's domain
4. Special case for REMOVED requirements: check if any other spec references or depends on the behavior being removed — flag as WARNING if so
5. If any conflicts found, present report (same format as create-spec Step 2.5) and wait for user decision:
   - **[R]** Revise proposed changes → return to Step 3 interview
   - **[U]** Also update conflicting spec (note which spec to update after this one)
   - **[P]** Proceed anyway — conflict documented
6. If no conflicts, proceed silently to Step 4

### Step 4: Update Spec File
Make the requested changes to the spec file:
- Update MUST requirements as needed
- Update Test section if test steps change
- Update Validation checkboxes if needed
- **Always add a Version History entry** with today's date and change description

### Step 4.5: Code Alignment Warning
Only applies to **ADDED** or **MODIFIED** requirements (not removals).

1. Extract keywords from changed requirements (same technique as `check-specs` Validate Step 2: specific nouns, verbs, numeric constraints, named identifiers)
2. `Grep` source files using those keywords (exclude `specs/`, `.claude/`, `node_modules/`, `dist/`, `vendor/`, `*.md`)
3. For each ADDED or MODIFIED requirement, classify current code behavior:
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

### Step 5: Update TDD.md
Update `specs/TDD.md`:
1. Change status in Quick Status Table to `🔄 UPDATED` if not already
2. Add entry to Version History table at bottom with affected spec IDs

## Version History Entry Format

Add to the spec's Version History table:
```markdown
| <YYYY-MM-DD> | <Brief description of change> |
```

Add to TDD.md Version History:
```markdown
| <YYYY-MM-DD> | <Brief description> | <SPEC-ID> |
```

## Important Notes

- Confirm changes with user before writing
- Preserve existing behaviors unless explicitly changing them
- Breaking changes require explicit user approval
- Always document the reason for the change
