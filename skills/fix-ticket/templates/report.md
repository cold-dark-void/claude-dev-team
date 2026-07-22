---
ticket: {{TICKET}}
worktree: {{WORKTREE}}
premise_holds: {{PREMISE_HOLDS}}
all_hold: {{ALL_HOLD}}
verification_mode: {{VERIFICATION_MODE}}
created_at: {{CREATED_AT}}
---

# Fix-ticket report — {{TICKET}}

{{DEGRADED_BANNER}}

## Premise

- **holds:** {{PREMISE_HOLDS}}
- **evidence:** {{PREMISE_EVIDENCE}}
- **current_locations:** {{PREMISE_LOCATIONS}}
- **siblings:** {{PREMISE_SIBLINGS}}
- **scope_notes:** {{PREMISE_SCOPE}}
- **reference_impl:** {{PREMISE_REF}}

## Implementation

{{IMPL_SECTION}}

## Verdicts

{{VERDICTS_SECTION}}

## Summary

- **all_hold:** {{ALL_HOLD}}
- **verification_mode:** {{VERIFICATION_MODE}}

## Next steps (caller owns)

1. Review the worktree diff: `cd {{WORKTREE}} && git diff`
2. Address any failed lenses, then re-run `/debug ticket` or fix manually
3. When satisfied: `/review-and-commit` (optional) then commit
4. Version/release when ready: `/release` (skill does **not** bump versions)

---

<!-- Placeholder notes for orchestrator fill-in:
  {{DEGRADED_BANNER}} — when verification_mode=self-verified, set to:
    > **self-verified — refuters unavailable**
    otherwise empty
  {{IMPL_SECTION}} — skip or "n/a (premise failed)" when premise_holds=false
  {{VERDICTS_SECTION}} — per-lens holds/issues; empty when premise failed
-->
