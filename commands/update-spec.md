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

### Step 4: Update Spec File
Make the requested changes to the spec file:
- Update MUST requirements as needed
- Update Test section if test steps change
- Update Validation checkboxes if needed
- **Always add a Version History entry** with today's date and change description

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
