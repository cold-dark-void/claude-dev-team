# Find Specs by Keyword

You are helping the user search for specifications by keyword.

## Workflow

### Step 1: Get Search Terms
If the user provided search terms with the command, use those.
Otherwise, ask what they're looking for.

### Step 2: Search Specs
Search across all spec files in `specs/`:
1. Search spec titles (in filenames and # headers)
2. Search MUST requirements sections
3. Search Overview sections
4. Search Test sections

Use grep/ripgrep to find matches in:
- `specs/core/*.md`
- `specs/performance/*.md`
- `specs/safety/*.md`
- `specs/compatibility/*.md`
- `specs/architecture/*.md`

### Step 3: Present Results
For each matching spec, show:
- **Spec ID and Title**
- **Category** (core/performance/safety/compatibility/architecture)
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
