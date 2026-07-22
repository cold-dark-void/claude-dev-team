---
epic_parent: CDT-46
child_id: CDT-46-C4
depends_on: [CDT-46-C3]
estimate: L
agent: ic5
linear_id: CDT-50
---

# v1.0-W3: /mode /status /setup /debug-ticket merges with 6 deprecation stubs

**Status**: COMPLETED (CDT-46-C4)
## Problem

/focus and /blunt are separate commands for the same session-toggle pattern. /standup, /metrics, and the worktree views are three separate read-only snapshots that belong together. scaffold-project, init-orchestration, and /init-team are three separate onboarding entry points - an enterprise install smell. /fix-ticket duplicates the premise-refuters flow /debug already hosts and overlaps /debug patch.

## Acceptance Criteria

- /mode <focus|blunt|off|status> single session-tone entry; /focus and /blunt stubs print replacements
- /status single read-only snapshot entry; /standup, /metrics, /worktree stubs print replacements
- /setup <project|orchestration|team> single onboarding entry; scaffold-project, init-orchestration, /init-team redirect
- /debug ticket <id> absorbs /fix-ticket; stub prints replacement
- All 6 command stubs (focus, blunt, metrics, worktree, fix-ticket, init-team) pass smoke harness; absorbed skills get tombstones
- OQ resolved and documented before close: home for mutating worktree release action
- W0 smoke harness passes for /mode, /status, /setup, /debug

## Goal

Ship child of epic CDT-46.

## Effort

L

---

*Added: 2026-07-21*

*Closed: 2026-07-21 CDT-46-C4*