# Quick Spec Overview

You are providing a fast status summary of all specifications.

## Workflow

### Step 1: Gather Data
Read `specs/TDD.md` to extract:
1. All specs from Quick Status Table
2. Status badges for each spec
3. Categories
4. Version History entries

### Step 2: Generate Summary

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
| ✅ PASS | XX | SPEC-001, SPEC-002, ... |
| 🔄 UPDATED | XX | SPEC-012, SPEC-013, ... |
| 🚧 NEW | XX | SPEC-016, SPEC-017, ... |
| ❌ FAIL | XX | (none) |
| ⚠️ UNDER REVIEW | XX | (none) |

### Recent Changes (Last 5)
| Date | Change | Specs |
|------|--------|-------|
| 2026-02-10 | Added multi-GUI backend | ARCH-001, SPEC-001 |
| ... | ... | ... |

### Needs Attention
- **🚧 NEW** (not yet baseline): SPEC-016, SPEC-017, SPEC-018, ...
- **❌ FAIL** (broken): (none)
- **⚠️ UNDER REVIEW**: (none)
```

### Step 3: Offer Actions
After the summary, offer:
- View details of specific spec
- Find specs by keyword (`/find-spec`)
- Run audit (`/check-specs`)
- Create new spec (`/create-spec`)

## Tips

- Keep output concise - this is meant for quick reference
- Highlight items needing attention (FAIL, NEW, UNDER REVIEW)
- Show recent activity to give context on project momentum
