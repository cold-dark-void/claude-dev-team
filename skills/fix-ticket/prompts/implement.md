---
name: fix-ticket-implement
description: |
  Implement phase prompt for /fix-ticket. Applies the verified fix in a
  worktree under hard constraints (no version files, no git commit). Placeholders:
  {{TICKET}} {{WORKTREE}} {{BUG}} {{FIX}} {{AGENT}} {{PREMISE_JSON}}
---

# Implement prompt template

Runtime template for the Implement phase. Orchestrator substitutes
`{{TICKET}}`, `{{WORKTREE}}`, `{{BUG}}`, `{{FIX}}`, `{{AGENT}}`,
`{{PREMISE_JSON}}` (stringified premise object) before the Task spawn.

---

## Prompt body (pasted into the Task tool)

```
You are @{{AGENT}}. Implement the fix for {{TICKET}} in the worktree: {{WORKTREE}}
Output mode: terse.

Bug (verified present): {{BUG}}
Premise (JSON): {{PREMISE_JSON}}
Fix instructions: {{FIX}}

From premise use: current_locations, scope_notes, sibling_occurrences,
reference_impl (if any).

HARD CONSTRAINTS:
- Edit ONLY code/doc files under {{WORKTREE}}. Do NOT touch
  .claude-plugin/plugin.json, .claude-plugin/marketplace.json, or README.md
  version/changelog sections — the caller does the version bump + changelog.
- Do NOT run git commit / git checkout / git reset / git add. Leave all
  changes UNCOMMITTED in the worktree.
- Author any file or script containing '!' or '<!--' via the Write tool,
  never an inline bash heredoc/awk (zsh mangles '!').
- Fix EVERY sibling occurrence listed in premise (no whack-a-mole).
- Make the SMALLEST change that fully fixes the bug. This is a patch, not a
  refactor — no scope creep, no new features.

Then validate: simulate the fixed code/command against a realistic input and
confirm it behaves correctly; if you changed a shell script, syntax-check it
(bash -n) and exercise it.

Draft ONE changelog bullet in house style for the CALLER to apply later
(do not edit CHANGELOG.md yourself):
'- **fix: <one-line summary> ({{TICKET}})** — <2-4 sentences: the bug, the fix, why this scope>.'

Return a structured object:
{
  "files_changed": ["path", ...],
  "diff_summary": "<before/after per change, file:line>",
  "changelog_md": "<one bullet>",
  "side_effects_checked": "<what was verified NOT to break>",
  "validation": "<commands run + results>"
}

files_changed, diff_summary, and changelog_md are required.
```
