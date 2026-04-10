# COUNCIL-002 — Template `{{TASK_ID}}` placeholder polish

**Status**: PENDING

## Problem

QA smoke test (Task 15, PASS WITH NOTES) flagged that `skills/council/templates/report-verdict.md` and `report-finding.md` place the `{{TASK_ID}}` placeholder in a `[//]: #` markdown comment line **immediately below** the YAML frontmatter `---` delimiter, rather than strictly inside the YAML block. Functionally equivalent for the substitution render path (engine.sh just does string replacement), but cosmetically inconsistent with the spec's intent that `task_id` is a YAML frontmatter field.

## Goal

Move `{{TASK_ID}}` into the YAML block proper, so the frontmatter looks like:

```yaml
---
task_id: {{TASK_ID}}
scope: {{SCOPE}}
preset: {{PRESET}}
created_at: {{TIMESTAMP}}
output_shape: verdict[]
---
```

Engine.sh `finalize` already handles the conditional `task_id` line — when the run is unbound, it replaces the entire `task_id: {{TASK_ID}}` line with empty string so the line vanishes. The same substitution logic works whether the placeholder is in YAML or in a markdown comment, so the move is cosmetic.

## Implementation Notes

- Edit both template files in `skills/council/templates/`
- Run a smoke test with both task-bound and unbound council runs after the move, confirm the report frontmatter renders correctly
- Verify the TaskCompleted hook still parses the YAML frontmatter on rendered reports (it doesn't actually read frontmatter today — it queries the index — but future tools might)
- Trivially small change; could be paired with any other COUNCIL-002 ticket as a drive-by

## Notes

Source: QA smoke test PASS WITH NOTES from Task 15 (`.claude/plans/2026-04-09-COUNCIL-001-smoke-test.md`). Non-blocking, cosmetic, low priority.

---

*Added: 2026-04-09*
