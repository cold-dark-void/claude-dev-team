---
name: list-specs
description: Quick status overview of all specs — counts by category and status,
  recent changes, items needing attention. Usage /list-specs
---

# Quick Spec Overview

You are providing a fast status summary of all specifications.

## Workflow

### Step 1: Gather Data
Read `specs/TDD.md` to extract:
1. All specs from the `## Spec Index` table (columns: `ID | Title | Status | Coverage`)
2. Lifecycle Status for each spec
3. Categories (derived from ID prefix or Coverage column)
4. `## Version History` entries

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
```

**Status legend** — lifecycle states (from `## Spec Index` Status column):
- `INFERRED` — machine-generated, needs human review
- `DRAFT` — human-authored, not yet reviewed/activated
- `ACTIVE` — in use, enforced
- `APPROVED` — formally reviewed and signed off
- `DEPRECATED` — superseded or retired

Note: `/check-specs` produces a separate REPORT with per-spec verify-status (`PASS / FAIL / WARN`) — that is NOT the spec's lifecycle Status and is not shown here.

### Step 3: Offer Actions
After the summary, offer:
- View details of specific spec
- Find specs by keyword (`/find-spec`)
- Run audit (`/check-specs`)
- Create new spec (`/create-spec`)

## Tips

- Keep output concise - this is meant for quick reference
- Highlight items needing attention (DRAFT, INFERRED)
- Show recent activity to give context on project momentum
