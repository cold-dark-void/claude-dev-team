---
name: find-spec
description: Search specs by keyword across titles, MUST requirements, overview,
  and test sections. Usage /find-spec <keyword>
agent: build
---

# Find Specs by Keyword

You are helping the user search for specifications by keyword.

## Workflow

### Step 1: Get Search Terms
If the user provided search terms with the command, use those.
Otherwise, ask what they're looking for.

### Step 2: Search Specs
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

### Step 3: Present Results
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

### Step 4: Offer Next Actions
After showing results, offer:
- Read full spec details for any result
- Update a spec (`/update-spec`)
- Create a new related spec (`/create-spec`)

## Tips

- Search is case-insensitive
- Multiple search terms are ANDed together
- If no results, suggest broader search terms
- Show up to 10 most relevant results
